"""Shared pieces of the ZTronSearchEngine model conversion scripts.

Used by ``convert_embedding_model.py`` and ``convert_cross_encoder.py``. The module imports
nothing heavier than the standard library at load time: PyTorch, Transformers and coremltools
are imported inside the functions that need them, so the vocabulary-pruning logic can be
imported and tested on its own (``test_vocabulary_pruning.py``).

What the Swift side expects (``ZTronSearchEngineSemantic``):

* inputs ``input_ids`` and ``attention_mask`` (and ``token_type_ids`` when the model uses
  segments), INT32, shape ``[1, 128]``;
* a ``.mlmodelc`` next to a ``<Name>.tokenizer`` directory that holds ``tokenizer.json``
  (SentencePiece unigram or WordPiece) and, for WordPiece models, ``vocab.txt``;
* at most 80 MB on disk for the embedding model and 60 MB for the cross-encoder
  (specification section 15.5).
"""

from __future__ import annotations

import copy
import hashlib
import json
import os
import shutil
import subprocess
import sys
import unicodedata
from collections import Counter
from typing import Dict, Iterable, List, Optional, Sequence, Set

SEQUENCE_LENGTH = 128
EMBEDDING_BUDGET_BYTES = 80 * 1024 * 1024
RERANKER_BUDGET_BYTES = 60 * 1024 * 1024

# Deployment targets by name, resolved against coremltools lazily.
DEPLOYMENT_TARGETS = ("iOS14", "iOS15", "iOS16", "iOS17", "iOS18")


class ConversionError(RuntimeError):
    """A condition that makes the converted model unfit to ship."""


# --------------------------------------------------------------------------------------------
# Vocabulary pruning. Pure Python over the parsed tokenizer.json.
# --------------------------------------------------------------------------------------------

def script_of(character: str) -> str:
    """The script a character belongs to, as far as the Unicode name tells.

    Letters and marks are grouped by the first word of their name (``LATIN``, ``CYRILLIC``,
    ``CJK``, ``HIRAGANA``, ...). Everything else, digits, punctuation, symbols and spaces, is
    ``COMMON``: those are shared by every language and always kept.
    """
    category = unicodedata.category(character)
    if not (category.startswith("L") or category.startswith("M")):
        return "COMMON"
    try:
        return unicodedata.name(character).split(" ")[0]
    except ValueError:
        return "UNKNOWN"


def scripts_of_text(lines: Iterable[str]) -> Set[str]:
    """Every script that occurs in a corpus."""
    scripts: Set[str] = set()
    for line in lines:
        for character in line:
            scripts.add(script_of(character))
    scripts.discard("UNKNOWN")
    return scripts


def piece_text(piece: str) -> str:
    """A vocabulary piece without the markers tokenizers add to it."""
    if piece.startswith("##"):
        piece = piece[2:]
    return piece.replace("▁", "")


def select_kept_ids(
    pieces: Sequence[str],
    counts: Dict[int, int],
    always_keep: Iterable[int],
    corpus_scripts: Optional[Set[str]] = None,
    min_count: int = 1,
    max_size: Optional[int] = None,
) -> List[int]:
    """Chooses the token ids a pruned vocabulary keeps, in ascending order.

    Kept are:

    * every id in ``always_keep`` (special and added tokens);
    * every piece of one character whose script occurs in the corpus, and the bare word
      marker, so that any word of a supported language can still be spelled out;
    * the pieces seen at least ``min_count`` times in the corpus, most frequent first, until
      ``max_size`` ids are kept.

    ``pieces[i]`` is the piece of id ``i``; ``counts`` maps an id to how often the corpus
    produced it.
    """
    kept: Set[int] = {index for index in always_keep if 0 <= index < len(pieces)}
    scripts = corpus_scripts if corpus_scripts is not None else set()
    for index, piece in enumerate(pieces):
        text = piece_text(piece)
        if len(text) == 0 and piece != "":
            kept.add(index)  # the word marker on its own
        elif len(text) == 1 and (script_of(text) == "COMMON" or script_of(text) in scripts):
            kept.add(index)
    if max_size is not None and len(kept) > max_size:
        raise ConversionError(
            f"the tokens that must be kept ({len(kept)}) already exceed --prune-vocab-size {max_size}"
        )
    frequent = sorted(
        (index for index, count in counts.items() if count >= min_count and 0 <= index < len(pieces)),
        key=lambda index: (-counts[index], index),
    )
    for index in frequent:
        if max_size is not None and len(kept) >= max_size:
            break
        kept.add(index)
    return sorted(kept)


def _remap_id(value, mapping: Dict[int, int], what: str) -> int:
    if value not in mapping:
        raise ConversionError(f"{what} (id {value}) is not among the kept tokens")
    return mapping[value]


def remap_tokenizer_json(tokenizer_json: dict, kept_ids: Sequence[int]) -> dict:
    """The tokenizer.json of a vocabulary reduced to ``kept_ids``, with ids renumbered.

    ``kept_ids`` must be sorted and must contain every special and added token: the new id of
    a token is its rank among the kept ids, which is also the row of its embedding in the
    pruned embedding matrix. Supports Unigram (SentencePiece) and WordPiece models.
    """
    kept = list(kept_ids)
    if kept != sorted(set(kept)):
        raise ConversionError("kept ids must be sorted and unique")
    mapping = {old: new for new, old in enumerate(kept)}
    result = copy.deepcopy(tokenizer_json)
    model = result["model"]
    model_type = model.get("type") or ("Unigram" if isinstance(model.get("vocab"), list) else "WordPiece")

    if model_type == "Unigram":
        vocabulary = model["vocab"]
        model["vocab"] = [vocabulary[old] for old in kept if old < len(vocabulary)]
        if model.get("unk_id") is not None:
            model["unk_id"] = _remap_id(model["unk_id"], mapping, "the unknown token")
    elif model_type == "WordPiece":
        by_id = {index: piece for piece, index in model["vocab"].items()}
        model["vocab"] = {by_id[old]: mapping[old] for old in kept if old in by_id}
        if model.get("unk_token") not in model["vocab"]:
            raise ConversionError("the unknown token is not among the kept tokens")
    else:
        raise ConversionError(f"vocabulary pruning does not support '{model_type}' tokenizers")

    added = []
    for token in result.get("added_tokens") or []:
        token = dict(token)
        token["id"] = _remap_id(token["id"], mapping, f"the added token {token.get('content')!r}")
        added.append(token)
    if "added_tokens" in result:
        result["added_tokens"] = added

    def remap_processor(processor):
        if not isinstance(processor, dict):
            return
        kind = processor.get("type")
        if kind == "TemplateProcessing":
            for name, special in (processor.get("special_tokens") or {}).items():
                special["ids"] = [_remap_id(index, mapping, f"the special token {name!r}") for index in special["ids"]]
        elif kind in ("BertProcessing", "RobertaProcessing"):
            for key in ("sep", "cls"):
                if key in processor:
                    name, index = processor[key]
                    processor[key] = [name, _remap_id(index, mapping, f"the special token {name!r}")]
        elif kind == "Sequence":
            for inner in processor.get("processors") or []:
                remap_processor(inner)

    remap_processor(result.get("post_processor"))
    padding = result.get("padding")
    if isinstance(padding, dict) and padding.get("pad_id") is not None:
        padding["pad_id"] = _remap_id(padding["pad_id"], mapping, "the padding token")
    return result


def pieces_by_id(tokenizer_json: dict) -> List[str]:
    """The piece of every id of a tokenizer.json, added tokens included."""
    model = tokenizer_json["model"]
    if isinstance(model.get("vocab"), list):
        pieces = [entry[0] for entry in model["vocab"]]
    else:
        size = max(model["vocab"].values()) + 1
        pieces = [""] * size
        for piece, index in model["vocab"].items():
            pieces[index] = piece
    for token in tokenizer_json.get("added_tokens") or []:
        while len(pieces) <= token["id"]:
            pieces.append("")
        pieces[token["id"]] = token["content"]
    return pieces


def added_token_ids(tokenizer_json: dict) -> List[int]:
    """The ids that must survive pruning: added tokens and whatever the templates place."""
    ids = {token["id"] for token in tokenizer_json.get("added_tokens") or []}
    model = tokenizer_json["model"]
    if model.get("unk_id") is not None:
        ids.add(model["unk_id"])
    if isinstance(model.get("vocab"), dict) and model.get("unk_token") in model["vocab"]:
        ids.add(model["vocab"][model["unk_token"]])

    def collect(processor):
        if not isinstance(processor, dict):
            return
        kind = processor.get("type")
        if kind == "TemplateProcessing":
            for special in (processor.get("special_tokens") or {}).values():
                ids.update(special["ids"])
        elif kind in ("BertProcessing", "RobertaProcessing"):
            for key in ("sep", "cls"):
                if key in processor:
                    ids.add(processor[key][1])
        elif kind == "Sequence":
            for inner in processor.get("processors") or []:
                collect(inner)

    collect(tokenizer_json.get("post_processor"))
    padding = tokenizer_json.get("padding")
    if isinstance(padding, dict) and padding.get("pad_id") is not None:
        ids.add(padding["pad_id"])
    return sorted(ids)


def read_corpus(paths: Sequence[str], limit: Optional[int] = None) -> List[str]:
    """The non-empty lines of the corpus files, at most ``limit`` of them."""
    lines: List[str] = []
    for path in paths:
        with open(path, "r", encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if line:
                    lines.append(line)
                    if limit is not None and len(lines) >= limit:
                        return lines
    return lines


# --------------------------------------------------------------------------------------------
# Everything below needs PyTorch, Transformers or coremltools.
# --------------------------------------------------------------------------------------------

def require(module: str):
    """Imports a third-party module, or exits with what to install."""
    try:
        return __import__(module)
    except ImportError as error:
        sys.exit(f"{module} is required: pip install -r Scripts/requirements.txt ({error})")


def count_token_ids(tokenizer, lines: Sequence[str], batch_size: int = 256) -> Dict[int, int]:
    """How often each token id occurs when the tokenizer encodes the corpus."""
    counts: Counter = Counter()
    for start in range(0, len(lines), batch_size):
        encoded = tokenizer(list(lines[start:start + batch_size]), add_special_tokens=False)
        for ids in encoded["input_ids"]:
            counts.update(ids)
    return dict(counts)


def prune_vocabulary(model, tokenizer, corpus_paths: Sequence[str], max_size: Optional[int], min_count: int, work_directory: str):
    """Reduces the vocabulary of ``model`` and ``tokenizer`` to what the corpus needs.

    The embedding matrix is the largest tensor of a multilingual model (250,002 x 384 for the
    XLM-R family, 96 MB at 8 bits), most of it for languages an app does not ship. Rows of
    tokens the corpus never produces are dropped and the tokenizer renumbered to match.

    Returns the pruned tokenizer (a fast tokenizer) and the kept ids. ``model`` is changed in
    place.
    """
    torch = require("torch")
    transformers = require("transformers")

    if not getattr(tokenizer, "is_fast", False):
        raise ConversionError("vocabulary pruning needs a fast tokenizer (one that has a tokenizer.json)")
    tokenizer_json = json.loads(tokenizer.backend_tokenizer.to_str())
    lines = read_corpus(corpus_paths)
    if not lines:
        raise ConversionError("the pruning corpus is empty")

    pieces = pieces_by_id(tokenizer_json)
    counts = count_token_ids(tokenizer, lines)
    kept = select_kept_ids(
        pieces,
        counts,
        always_keep=added_token_ids(tokenizer_json),
        corpus_scripts=scripts_of_text(lines),
        min_count=min_count,
        max_size=max_size,
    )
    pruned_json = remap_tokenizer_json(tokenizer_json, kept)
    mapping = {old: new for new, old in enumerate(kept)}

    # The embedding matrix: keep the rows of the kept ids, in their new order.
    embeddings = model.get_input_embeddings()
    if embeddings.weight.shape[0] < len(pieces):
        raise ConversionError("the tokenizer knows more ids than the model has embeddings")
    index = torch.tensor(kept, dtype=torch.long)
    pad = getattr(model.config, "pad_token_id", None)
    pruned = torch.nn.Embedding(len(kept), embeddings.weight.shape[1], padding_idx=mapping.get(pad) if pad is not None else None)
    with torch.no_grad():
        pruned.weight.copy_(embeddings.weight.index_select(0, index))
    model.set_input_embeddings(pruned)
    model.config.vocab_size = len(kept)
    for name in ("pad_token_id", "bos_token_id", "eos_token_id", "sep_token_id", "cls_token_id", "unk_token_id", "mask_token_id"):
        value = getattr(model.config, name, None)
        if isinstance(value, int):
            setattr(model.config, name, mapping.get(value))

    # The tokenizer: reload it from the renumbered description.
    tokenizer.save_pretrained(work_directory)
    with open(os.path.join(work_directory, "tokenizer.json"), "w", encoding="utf-8") as handle:
        json.dump(pruned_json, handle, ensure_ascii=False)
    for stale in ("sentencepiece.bpe.model", "spiece.model", "vocab.txt"):
        path = os.path.join(work_directory, stale)
        if os.path.exists(path):
            os.remove(path)
    pruned_tokenizer = transformers.PreTrainedTokenizerFast(
        tokenizer_file=os.path.join(work_directory, "tokenizer.json"),
        **{key: value for key, value in tokenizer.special_tokens_map.items() if isinstance(value, str)},
    )
    pruned_tokenizer.model_max_length = tokenizer.model_max_length

    # Self-check: wherever every token of a line survived, the pruned tokenizer must produce
    # exactly the renumbered ids of the original.
    checked = 0
    for line in lines[:2000]:
        original = tokenizer(line, add_special_tokens=True)["input_ids"]
        if all(token in mapping for token in original):
            expected = [mapping[token] for token in original]
            actual = pruned_tokenizer(line, add_special_tokens=True)["input_ids"]
            if expected != actual:
                raise ConversionError(f"the pruned tokenizer disagrees with the original on {line!r}")
            checked += 1
    print(f"vocabulary pruned from {len(pieces)} to {len(kept)} tokens; {checked} corpus lines re-tokenize identically")
    return pruned_tokenizer, kept


def example_inputs(tokenizer, uses_token_types: bool, pair: bool):
    """A tokenized example of the 128-token window, as int32 tensors for tracing."""
    torch = require("torch")
    if pair:
        encoded = tokenizer(
            "how do I download offline maps", "Maps can be downloaded in the settings and used without a connection.",
            padding="max_length", truncation=True, max_length=SEQUENCE_LENGTH, return_tensors="pt",
        )
    else:
        encoded = tokenizer(
            "offline maps of the old town",
            padding="max_length", truncation=True, max_length=SEQUENCE_LENGTH, return_tensors="pt",
        )
    names = ["input_ids", "attention_mask"] + (["token_type_ids"] if uses_token_types else [])
    return names, tuple(encoded[name].to(torch.int32) for name in names)


def convert_traced_model(traced, input_names: Sequence[str], output_name: str, model_format: str, deployment_target: str):
    """Converts a traced PyTorch module to Core ML with 8-bit weights.

    Two routes, because the 8-bit weight formats differ by Core ML generation:

    * ``neuralnetwork`` (the default): runs on iOS 13 and later, so it covers the iOS 15.8
      reference device. Weights are stored as 8-bit linear and expanded when the model loads.
    * ``mlprogram``: ML Programs exist from iOS 15, but their compressed weight operations
      (``constexpr_affine_dequantize``) need iOS 16, so this route is refused below iOS 16.
    """
    ct = require("coremltools")
    numpy = require("numpy")

    if deployment_target not in DEPLOYMENT_TARGETS:
        raise ConversionError(f"unknown deployment target {deployment_target}")
    inputs = [ct.TensorType(name=name, shape=(1, SEQUENCE_LENGTH), dtype=numpy.int32) for name in input_names]
    outputs = [ct.TensorType(name=output_name)]

    if model_format == "neuralnetwork":
        # The neural-network backend is selected by a deployment target below iOS 15; the
        # resulting model loads on every later system.
        model = ct.convert(
            traced, inputs=inputs, outputs=outputs, convert_to="neuralnetwork",
            minimum_deployment_target=ct.target.iOS14,
        )
        from coremltools.models.neural_network import quantization_utils
        quantized = quantization_utils.quantize_weights(model, nbits=8, quantization_mode="linear")
        if not isinstance(quantized, ct.models.MLModel):
            # Off macOS the utility returns the specification instead of a model.
            quantized = ct.models.MLModel(quantized)
        return quantized, ".mlmodel"

    if model_format == "mlprogram":
        if DEPLOYMENT_TARGETS.index(deployment_target) < DEPLOYMENT_TARGETS.index("iOS16"):
            raise ConversionError(
                "8-bit weights in an ML Program need iOS 16; use --format neuralnetwork for the iOS 15 floor"
            )
        model = ct.convert(
            traced, inputs=inputs, outputs=outputs, convert_to="mlprogram",
            minimum_deployment_target=getattr(ct.target, deployment_target),
            compute_precision=ct.precision.FLOAT32,
        )
        import coremltools.optimize.coreml as cto
        config = cto.OptimizationConfig(global_config=cto.OpLinearQuantizerConfig(mode="linear_symmetric", dtype=numpy.int8))
        return cto.linear_quantize_weights(model, config=config), ".mlpackage"

    raise ConversionError(f"unknown format {model_format}")


def directory_size(path: str) -> int:
    """Bytes a file, or everything under a directory, takes on disk."""
    if os.path.isfile(path):
        return os.path.getsize(path)
    total = 0
    for root, _, files in os.walk(path):
        for name in files:
            total += os.path.getsize(os.path.join(root, name))
    return total


def save_and_compile(model, extension: str, output_directory: str, name: str) -> str:
    """Saves the Core ML model and compiles it to ``<name>.mlmodelc`` when Xcode is at hand.

    Returns the path of the artifact that ships: the compiled model when it could be
    compiled, else the saved model, which Xcode compiles when it is added to a target.
    """
    os.makedirs(output_directory, exist_ok=True)
    saved = os.path.join(output_directory, name + extension)
    if os.path.isdir(saved):
        shutil.rmtree(saved)
    elif os.path.exists(saved):
        os.remove(saved)
    model.save(saved)

    compiler = shutil.which("xcrun")
    if compiler is None:
        print(f"xcrun not found: {saved} was not compiled; add it to an Xcode target or compile it on a Mac")
        return saved
    compiled = os.path.join(output_directory, name + ".mlmodelc")
    if os.path.isdir(compiled):
        shutil.rmtree(compiled)
    subprocess.run([compiler, "coremlcompiler", "compile", saved, output_directory], check=True)
    if not os.path.isdir(compiled):
        raise ConversionError(f"coremlcompiler did not produce {compiled}")
    return compiled


def enforce_budget(path: str, budget: int, what: str) -> int:
    """Fails when the shipped artifact is over its on-disk budget."""
    size = directory_size(path)
    megabytes = size / (1024 * 1024)
    print(f"{what}: {megabytes:.1f} MB on disk, budget {budget / (1024 * 1024):.0f} MB")
    if size > budget:
        raise ConversionError(
            f"{what} takes {megabytes:.1f} MB, over its budget: it must not ship. "
            "Prune the vocabulary further or choose a smaller model."
        )
    return size


def write_tokenizer(tokenizer, output_directory: str, name: str) -> str:
    """Writes the tokenizer files into ``<name>.tokenizer`` next to the model."""
    directory = os.path.join(output_directory, name + ".tokenizer")
    if os.path.isdir(directory):
        shutil.rmtree(directory)
    os.makedirs(directory)
    tokenizer.save_pretrained(directory)
    if not os.path.exists(os.path.join(directory, "tokenizer.json")):
        raise ConversionError("the tokenizer has no tokenizer.json; the Swift tokenizers read that file")
    with open(os.path.join(directory, "tokenizer.json"), "r", encoding="utf-8") as handle:
        kind = json.load(handle)["model"].get("type")
    if kind not in ("Unigram", "WordPiece"):
        raise ConversionError(f"the Swift side tokenizes Unigram and WordPiece models, not {kind}")
    return directory


def model_identity(source: str, parameters: dict) -> str:
    """A stable id for the converted model: its source and a digest of how it was converted.

    The Swift side records it in vector files and graph files, so vectors computed with one
    conversion are never searched with another.
    """
    digest = hashlib.sha256(json.dumps(parameters, sort_keys=True).encode("utf-8")).hexdigest()[:12]
    return f"{os.path.basename(source.rstrip('/'))}@{digest}"


def write_manifest(output_directory: str, name: str, manifest: dict) -> str:
    """Writes ``<name>.json``: what the host needs to configure the Swift adapter."""
    path = os.path.join(output_directory, name + ".json")
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(manifest, handle, indent=2, sort_keys=True)
        handle.write("\n")
    return path
