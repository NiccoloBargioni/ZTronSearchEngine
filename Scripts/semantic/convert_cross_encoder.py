#!/usr/bin/env python3
"""Converts a multilingual cross-encoder to Core ML for ZTronSearchEngineSemantic.

The result is what ``CoreMLCrossEncoder`` loads (specification section 7.4): a multilingual
cross-encoder exported with 8-bit weights, 6 layers or fewer, a 128-token window per
(query, passage) pair, that fits 60 MB on disk after vocabulary pruning.

    python3 Scripts/convert_cross_encoder.py \\
        --model <a multilingual cross-encoder with at most 6 layers> \\
        --output-dir Models --name Reranker \\
        --prune-vocab-corpus corpus.en.txt corpus.it.txt corpus.ja.txt

It writes, into ``--output-dir``:

    Reranker.mlmodelc         the compiled model (Reranker.mlmodel when xcrun is missing)
    Reranker.tokenizer/       tokenizer.json and its companions, read by the Swift tokenizers
    Reranker.json             model id and the other values the adapter is configured with

The model is exported for one pair per prediction, shape ``[1, 128]``: a fixed shape is what
the Neural Engine schedules, and ``CoreMLCrossEncoder`` submits the 16 pairs of a rerank as one
batch of such predictions. The output is ``logits``: one logit per pair, or two for a binary
classifier, which the adapter turns into a margin.

``--model`` has no default: which multilingual cross-encoder fits 60 MB with 6 layers or fewer
is an open question of the specification (section 17). The script refuses a deeper model
unless ``--allow-deep`` is given, and refuses any model that ends up over the budget.

Requirements: see Scripts/requirements.txt. The first run downloads the model from the
Hugging Face hub unless ``--model`` is a local directory or ``--local-files-only`` is given.
"""

from __future__ import annotations

import argparse
import os
import sys
import tempfile

import ztron_conversion as common

MAXIMUM_LAYERS = 6

VERIFICATION_PAIRS = [
    ("how do I download offline maps", "Maps can be downloaded in the settings and used without a connection."),
    ("how do I download offline maps", "This card game is played by two and a round takes twenty minutes."),
    ("consigli per la batteria", "Questo consiglio spiega come prolungare la durata della batteria."),
    ("consigli per la batteria", "Die Karte zeigt jede Straße der Altstadt."),
]


def build_scorer(classifier, uses_token_types: bool):
    """Wraps the classifier so that it returns its logits."""
    torch = common.require("torch")

    class PairScorer(torch.nn.Module):
        def __init__(self):
            super().__init__()
            self.classifier = classifier

        if uses_token_types:
            def forward(self, input_ids, attention_mask, token_type_ids):
                return self.classifier(input_ids=input_ids, attention_mask=attention_mask, token_type_ids=token_type_ids)[0]
        else:
            def forward(self, input_ids, attention_mask):
                return self.classifier(input_ids=input_ids, attention_mask=attention_mask)[0]

    return PairScorer().eval()


def relevance(logits):
    """One score per pair from the logits, the way the Swift adapter computes it."""
    values = logits.reshape(-1)
    return float(values[0]) if values.shape[0] == 1 else float(values[1] - values[0])


def verify(mlmodel, scorer, tokenizer, names, tolerance: float) -> None:
    """Scores a few pairs with the converted model and compares them with PyTorch."""
    torch = common.require("torch")
    numpy = common.require("numpy")
    worst = 0.0
    scores = []
    for query, passage in VERIFICATION_PAIRS:
        encoded = tokenizer(
            query, passage, padding="max_length", truncation=True, max_length=common.SEQUENCE_LENGTH, return_tensors="pt"
        )
        with torch.no_grad():
            expected = relevance(scorer(*[encoded[name] for name in names]).numpy())
        prediction = mlmodel.predict({name: encoded[name].numpy().astype(numpy.int32) for name in names})["logits"]
        actual = relevance(numpy.asarray(prediction, dtype=numpy.float32))
        scores.append((expected, actual))
        worst = max(worst, abs(expected - actual))
    print(f"converted model against PyTorch: largest score difference {worst:.4f}")
    # What matters to a reranker is the order: the relevant passage of each query must stay first.
    for first, second in ((0, 1), (2, 3)):
        if (scores[first][0] > scores[second][0]) != (scores[first][1] > scores[second][1]):
            raise common.ConversionError("the converted model orders the verification pairs differently from the original")
    if worst > tolerance:
        raise common.ConversionError(f"the converted model drifted from the original (difference {worst:.4f}, tolerance {tolerance})")


def parse_arguments(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--model", required=True, help="Hugging Face model id or local directory of a sequence classifier")
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--name", default="Reranker", help="base name of the files written")
    parser.add_argument("--allow-deep", action="store_true", help=f"accept a model with more than {MAXIMUM_LAYERS} layers")
    parser.add_argument("--format", choices=("neuralnetwork", "mlprogram"), default="neuralnetwork", dest="model_format")
    parser.add_argument("--deployment-target", choices=common.DEPLOYMENT_TARGETS, default="iOS15")
    parser.add_argument("--prune-vocab-corpus", nargs="+", metavar="FILE",
                        help="text files, one sentence per line, in every language the app supports")
    parser.add_argument("--prune-vocab-size", type=int, default=None, help="keep at most this many tokens")
    parser.add_argument("--prune-min-count", type=int, default=1, help="keep tokens seen at least this often in the corpus")
    parser.add_argument("--budget-mb", type=float, default=common.RERANKER_BUDGET_BYTES / (1024 * 1024))
    parser.add_argument("--verification-tolerance", type=float, default=0.5)
    parser.add_argument("--skip-verification", action="store_true")
    parser.add_argument("--local-files-only", action="store_true", help="never contact the Hugging Face hub")
    return parser.parse_args(argv)


def main(argv=None) -> int:
    arguments = parse_arguments(argv)
    torch = common.require("torch")
    transformers = common.require("transformers")

    tokenizer = transformers.AutoTokenizer.from_pretrained(
        arguments.model, use_fast=True, local_files_only=arguments.local_files_only
    )
    classifier = transformers.AutoModelForSequenceClassification.from_pretrained(
        arguments.model, torchscript=True, local_files_only=arguments.local_files_only
    ).eval()

    layers = int(classifier.config.num_hidden_layers)
    if layers > MAXIMUM_LAYERS and not arguments.allow_deep:
        raise common.ConversionError(
            f"the model has {layers} layers; the rerank stage takes {MAXIMUM_LAYERS} or fewer (--allow-deep overrides)"
        )
    labels = int(classifier.config.num_labels)
    if labels not in (1, 2):
        raise common.ConversionError(f"the model has {labels} labels; a cross-encoder has one logit, or two")
    uses_token_types = "token_type_ids" in tokenizer.model_input_names and getattr(classifier.config, "type_vocab_size", 1) > 1

    kept = None
    with tempfile.TemporaryDirectory() as work_directory:
        if arguments.prune_vocab_corpus:
            tokenizer, kept = common.prune_vocabulary(
                classifier, tokenizer, arguments.prune_vocab_corpus,
                max_size=arguments.prune_vocab_size, min_count=arguments.prune_min_count,
                work_directory=work_directory,
            )

        scorer = build_scorer(classifier, uses_token_types)
        names, example = common.example_inputs(tokenizer, uses_token_types=uses_token_types, pair=True)
        with torch.no_grad():
            traced = torch.jit.trace(scorer, example, strict=False)
        mlmodel, extension = common.convert_traced_model(
            traced, names, "logits", arguments.model_format, arguments.deployment_target
        )

        if arguments.skip_verification or sys.platform != "darwin":
            print("verification skipped: running the converted model needs macOS")
        else:
            verify(mlmodel, scorer, tokenizer, names, arguments.verification_tolerance)

        artifact = common.save_and_compile(mlmodel, extension, arguments.output_dir, arguments.name)
        size = common.enforce_budget(artifact, int(arguments.budget_mb * 1024 * 1024), "the cross-encoder")
        tokenizer_directory = common.write_tokenizer(tokenizer, arguments.output_dir, arguments.name)

    parameters = {
        "source": arguments.model,
        "format": arguments.model_format,
        "weights": "int8-linear",
        "sequence_length": common.SEQUENCE_LENGTH,
        "layers": layers,
        "labels": labels,
        "vocabulary_size": int(classifier.config.vocab_size),
        "kept_token_digest": None if kept is None else common.hashlib.sha256(repr(kept).encode("utf-8")).hexdigest()[:16],
    }
    manifest = dict(parameters)
    manifest.update({
        "model_id": common.model_identity(arguments.model, parameters),
        "output_feature": "logits",
        "uses_token_type_ids": uses_token_types,
        "model": os.path.basename(artifact),
        "tokenizer": os.path.basename(tokenizer_directory),
        "bytes": size,
    })
    path = common.write_manifest(arguments.output_dir, arguments.name, manifest)
    print(f"wrote {artifact}, {tokenizer_directory} and {path}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except common.ConversionError as error:
        sys.exit(f"error: {error}")
