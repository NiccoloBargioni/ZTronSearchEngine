#!/usr/bin/env python3
"""Converts a multilingual sentence-embedding model to Core ML for ZTronSearchEngineSemantic.

The result is what ``CoreMLEmbeddingProvider`` loads (specification section 7.3): a shared
multilingual space exported with 8-bit weights, at most 384 dimensions and a 128-token input
window, that fits 80 MB on disk.

    python3 Scripts/convert_embedding_model.py \\
        --model sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2 \\
        --output-dir Models --name Embedding \\
        --prune-vocab-corpus corpus.en.txt corpus.it.txt corpus.ja.txt

It writes, into ``--output-dir``:

    Embedding.mlmodelc        the compiled model (Embedding.mlmodel when xcrun is missing)
    Embedding.tokenizer/      tokenizer.json and its companions, read by the Swift tokenizers
    Embedding.json            model id, dimensions and the other values the adapter is configured with

Vocabulary pruning is what makes an XLM-R-based model fit the budget: its embedding matrix
holds 250,002 rows, 96 MB at 8 bits, most of them for languages an app does not ship.
``--prune-vocab-corpus`` keeps the rows the given text needs (one sentence per line, in every
language the app supports) and renumbers the tokenizer to match.

Requirements: see Scripts/requirements.txt. The first run downloads the model from the
Hugging Face hub unless ``--model`` is a local directory or ``--local-files-only`` is given.
"""

from __future__ import annotations

import argparse
import os
import sys
import tempfile

import ztron_conversion as common

MAXIMUM_DIMENSIONS = 384

VERIFICATION_SENTENCES = [
    "offline maps of the old town",
    "consigli per risparmiare la batteria",
    "Werkzeug zum Messen von Entfernungen",
    "comment télécharger une carte",
    "как сбросить настройки приложения",
]


def build_encoder(transformer, pooling: str, output: str):
    """Wraps the transformer so that it returns what the Swift adapter reads."""
    torch = common.require("torch")

    class SentenceEncoder(torch.nn.Module):
        def __init__(self):
            super().__init__()
            self.transformer = transformer

        def forward(self, input_ids, attention_mask):
            hidden = self.transformer(input_ids=input_ids, attention_mask=attention_mask)[0]
            if output == "token_embeddings":
                # One vector per token; CoreMLEmbeddingProvider mean-pools under the mask.
                return hidden
            if pooling == "cls":
                pooled = hidden[:, 0]
            else:
                mask = attention_mask.unsqueeze(-1).to(hidden.dtype)
                pooled = (hidden * mask).sum(dim=1) / mask.sum(dim=1).clamp(min=1e-9)
            return torch.nn.functional.normalize(pooled, p=2, dim=1)

    return SentenceEncoder().eval()


def reference_vectors(encoder, tokenizer, sentences):
    """Unit-length sentence vectors computed by PyTorch, the yardstick for the converted model."""
    torch = common.require("torch")
    vectors = []
    with torch.no_grad():
        for sentence in sentences:
            encoded = tokenizer(
                sentence, padding="max_length", truncation=True, max_length=common.SEQUENCE_LENGTH, return_tensors="pt"
            )
            result = encoder(encoded["input_ids"], encoded["attention_mask"])
            if result.dim() == 3:
                mask = encoded["attention_mask"].unsqueeze(-1).to(result.dtype)
                result = torch.nn.functional.normalize((result * mask).sum(dim=1) / mask.sum(dim=1), p=2, dim=1)
            vectors.append(result[0].numpy())
    return vectors


def verify(mlmodel, encoder, tokenizer, output_name: str, threshold: float) -> None:
    """Runs the converted model on a few sentences and compares it with PyTorch."""
    numpy = common.require("numpy")
    expected = reference_vectors(encoder, tokenizer, VERIFICATION_SENTENCES)
    worst = 1.0
    for sentence, reference in zip(VERIFICATION_SENTENCES, expected):
        encoded = tokenizer(sentence, padding="max_length", truncation=True, max_length=common.SEQUENCE_LENGTH, return_tensors="np")
        prediction = mlmodel.predict({
            "input_ids": encoded["input_ids"].astype(numpy.int32),
            "attention_mask": encoded["attention_mask"].astype(numpy.int32),
        })[output_name]
        vector = numpy.asarray(prediction, dtype=numpy.float32)
        if vector.ndim == 3:
            mask = encoded["attention_mask"][..., None].astype(numpy.float32)
            vector = (vector * mask).sum(axis=1) / mask.sum(axis=1)
        vector = vector.reshape(-1)
        vector = vector / max(float(numpy.linalg.norm(vector)), 1e-12)
        worst = min(worst, float(numpy.dot(vector, reference)))
    print(f"converted model against PyTorch: lowest cosine similarity {worst:.4f}")
    if worst < threshold:
        raise common.ConversionError(
            f"the converted model drifted from the original (cosine {worst:.4f}, threshold {threshold})"
        )


def parse_arguments(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--model", default="sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2",
                        help="Hugging Face model id or local directory")
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--name", default="Embedding", help="base name of the files written")
    parser.add_argument("--pooling", choices=("mean", "cls"), default="mean")
    parser.add_argument("--output", choices=("sentence_embedding", "token_embeddings"), default="sentence_embedding",
                        help="export the pooled, normalized vector (default) or one vector per token")
    parser.add_argument("--query-prefix", default="", help='text the model expects in front of queries, e.g. "query: "')
    parser.add_argument("--format", choices=("neuralnetwork", "mlprogram"), default="neuralnetwork", dest="model_format")
    parser.add_argument("--deployment-target", choices=common.DEPLOYMENT_TARGETS, default="iOS15")
    parser.add_argument("--prune-vocab-corpus", nargs="+", metavar="FILE",
                        help="text files, one sentence per line, in every language the app supports")
    parser.add_argument("--prune-vocab-size", type=int, default=None, help="keep at most this many tokens")
    parser.add_argument("--prune-min-count", type=int, default=1, help="keep tokens seen at least this often in the corpus")
    parser.add_argument("--budget-mb", type=float, default=common.EMBEDDING_BUDGET_BYTES / (1024 * 1024))
    parser.add_argument("--verification-threshold", type=float, default=0.99)
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
    transformer = transformers.AutoModel.from_pretrained(
        arguments.model, torchscript=True, local_files_only=arguments.local_files_only
    ).eval()
    dimensions = int(transformer.config.hidden_size)
    if dimensions > MAXIMUM_DIMENSIONS:
        raise common.ConversionError(
            f"the model has {dimensions} dimensions; the vector store holds at most {MAXIMUM_DIMENSIONS}"
        )
    if "token_type_ids" in tokenizer.model_input_names and getattr(transformer.config, "type_vocab_size", 1) > 1:
        print("note: the model has segment embeddings; single texts use segment 0, which is what it is exported with")

    kept = None
    with tempfile.TemporaryDirectory() as work_directory:
        if arguments.prune_vocab_corpus:
            tokenizer, kept = common.prune_vocabulary(
                transformer, tokenizer, arguments.prune_vocab_corpus,
                max_size=arguments.prune_vocab_size, min_count=arguments.prune_min_count,
                work_directory=work_directory,
            )

        encoder = build_encoder(transformer, arguments.pooling, arguments.output)
        names, example = common.example_inputs(tokenizer, uses_token_types=False, pair=False)
        with torch.no_grad():
            traced = torch.jit.trace(encoder, example, strict=False)
        mlmodel, extension = common.convert_traced_model(
            traced, names, arguments.output, arguments.model_format, arguments.deployment_target
        )

        if arguments.skip_verification or sys.platform != "darwin":
            print("verification skipped: running the converted model needs macOS")
        else:
            verify(mlmodel, encoder, tokenizer, arguments.output, arguments.verification_threshold)

        artifact = common.save_and_compile(mlmodel, extension, arguments.output_dir, arguments.name)
        size = common.enforce_budget(artifact, int(arguments.budget_mb * 1024 * 1024), "the embedding model")
        tokenizer_directory = common.write_tokenizer(tokenizer, arguments.output_dir, arguments.name)

    parameters = {
        "source": arguments.model,
        "pooling": arguments.pooling,
        "output": arguments.output,
        "format": arguments.model_format,
        "weights": "int8-linear",
        "sequence_length": common.SEQUENCE_LENGTH,
        "vocabulary_size": int(transformer.config.vocab_size),
        "kept_token_digest": None if kept is None else common.hashlib.sha256(repr(kept).encode("utf-8")).hexdigest()[:16],
    }
    manifest = dict(parameters)
    manifest.update({
        "model_id": common.model_identity(arguments.model, parameters),
        "dimensions": dimensions,
        "query_prefix": arguments.query_prefix,
        "output_feature": arguments.output,
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
