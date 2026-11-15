#!/usr/bin/env python3
"""Tests of the vocabulary-pruning logic of ``ztron_conversion``.

They need nothing but the standard library: ``python3 Scripts/test_vocabulary_pruning.py``.
The parts of the conversion that need PyTorch, Transformers or coremltools are not covered.
"""

import unittest

import ztron_conversion as common


def unigram_tokenizer():
    """A tokenizer.json in the layout Hugging Face writes for XLM-R models."""
    vocabulary = [
        ["<s>", 0.0], ["<pad>", 0.0], ["</s>", 0.0], ["<unk>", 0.0],
        ["▁", -2.0], ["▁hello", -3.0], ["▁world", -3.5], ["a", -5.0],
        ["▁привет", -4.0], ["ж", -6.0], ["▁地図", -4.0], ["図", -6.0],
        [",", -3.0], ["▁z", -6.0], ["llo", -4.5],
    ]
    return {
        "version": "1.0",
        "padding": {"pad_id": 1, "pad_token": "<pad>"},
        "added_tokens": [
            {"id": 0, "content": "<s>", "special": True},
            {"id": 1, "content": "<pad>", "special": True},
            {"id": 2, "content": "</s>", "special": True},
            {"id": 3, "content": "<unk>", "special": True},
            {"id": 15, "content": "<mask>", "special": True},
        ],
        "post_processor": {
            "type": "TemplateProcessing",
            "single": [{"SpecialToken": {"id": "<s>", "type_id": 0}}, {"Sequence": {"id": "A", "type_id": 0}},
                       {"SpecialToken": {"id": "</s>", "type_id": 0}}],
            "pair": [],
            "special_tokens": {
                "<s>": {"id": "<s>", "ids": [0], "tokens": ["<s>"]},
                "</s>": {"id": "</s>", "ids": [2], "tokens": ["</s>"]},
            },
        },
        "model": {"type": "Unigram", "unk_id": 3, "vocab": vocabulary},
    }


def wordpiece_tokenizer():
    pieces = ["[PAD]", "[UNK]", "[CLS]", "[SEP]", "[MASK]", "the", "cat", "##s", "dog", "a", "##b", "é"]
    return {
        "added_tokens": [{"id": index, "content": pieces[index], "special": True} for index in range(5)],
        "post_processor": {"type": "BertProcessing", "sep": ["[SEP]", 3], "cls": ["[CLS]", 2]},
        "model": {"type": "WordPiece", "unk_token": "[UNK]", "continuing_subword_prefix": "##",
                  "vocab": {piece: index for index, piece in enumerate(pieces)}},
    }


class ScriptTests(unittest.TestCase):
    def test_letters_are_grouped_by_script_and_the_rest_is_common(self):
        self.assertEqual(common.script_of("a"), "LATIN")
        self.assertEqual(common.script_of("é"), "LATIN")
        self.assertEqual(common.script_of("ж"), "CYRILLIC")
        self.assertEqual(common.script_of("図"), "CJK")
        self.assertEqual(common.script_of("あ"), "HIRAGANA")
        for character in "7,. ▁":
            self.assertEqual(common.script_of(character), "COMMON")
        self.assertEqual(common.scripts_of_text(["hello, мир 7"]), {"LATIN", "CYRILLIC", "COMMON"})

    def test_pieces_are_compared_without_their_markers(self):
        self.assertEqual(common.piece_text("▁hello"), "hello")
        self.assertEqual(common.piece_text("##ing"), "ing")
        self.assertEqual(common.piece_text("▁"), "")


class SelectionTests(unittest.TestCase):
    def setUp(self):
        self.tokenizer = unigram_tokenizer()
        self.pieces = common.pieces_by_id(self.tokenizer)

    def test_added_tokens_and_template_tokens_must_survive(self):
        self.assertEqual(common.added_token_ids(self.tokenizer), [0, 1, 2, 3, 15])
        self.assertEqual(common.added_token_ids(wordpiece_tokenizer()), [0, 1, 2, 3, 4])
        self.assertEqual(self.pieces[15], "<mask>")
        self.assertEqual(len(self.pieces), 16)

    def test_seen_tokens_single_characters_of_seen_scripts_and_specials_are_kept(self):
        # The corpus is Latin only and produced "hello" and "world".
        kept = common.select_kept_ids(
            self.pieces, counts={5: 10, 6: 4}, always_keep=[0, 1, 2, 3, 15], corpus_scripts={"LATIN", "COMMON"},
        )
        # specials, the bare marker, the two words, the Latin letters "a" and "z", the comma.
        self.assertEqual(kept, [0, 1, 2, 3, 4, 5, 6, 7, 12, 13, 15])
        # Cyrillic and CJK pieces are gone, single characters included.
        for dropped in (8, 9, 10, 11, 14):
            self.assertNotIn(dropped, kept)

    def test_single_characters_of_every_seen_script_are_kept(self):
        kept = common.select_kept_ids(
            self.pieces, counts={}, always_keep=[0, 1, 2, 3, 15], corpus_scripts={"CYRILLIC", "CJK"},
        )
        self.assertIn(9, kept)
        self.assertIn(11, kept)
        self.assertNotIn(7, kept)

    def test_the_most_frequent_tokens_win_when_the_size_is_capped(self):
        counts = {5: 1, 6: 9, 8: 5, 10: 7, 14: 3}
        kept = common.select_kept_ids(self.pieces, counts, always_keep=[0, 1, 2, 3, 15], corpus_scripts=set(), max_size=9)
        # Seven ids are mandatory (specials, the marker, the comma); the two most frequent join.
        self.assertEqual(kept, [0, 1, 2, 3, 4, 6, 10, 12, 15])
        with self.assertRaises(common.ConversionError):
            common.select_kept_ids(self.pieces, counts, always_keep=[0, 1, 2, 3, 15], corpus_scripts=set(), max_size=3)

    def test_rare_tokens_fall_below_the_minimum_count(self):
        kept = common.select_kept_ids(
            self.pieces, counts={5: 1, 6: 9}, always_keep=[0, 1, 2, 3, 15], corpus_scripts=set(), min_count=2,
        )
        self.assertIn(6, kept)
        self.assertNotIn(5, kept)


class RemappingTests(unittest.TestCase):
    def test_a_unigram_tokenizer_is_renumbered_consistently(self):
        tokenizer = unigram_tokenizer()
        kept = [0, 1, 2, 3, 4, 5, 6, 7, 12, 13, 15]
        pruned = common.remap_tokenizer_json(tokenizer, kept)
        self.assertEqual(
            [entry[0] for entry in pruned["model"]["vocab"]],
            ["<s>", "<pad>", "</s>", "<unk>", "▁", "▁hello", "▁world", "a", ",", "▁z"],
        )
        # Scores travel with their pieces.
        self.assertEqual(pruned["model"]["vocab"][8], [",", -3.0])
        self.assertEqual(pruned["model"]["unk_id"], 3)
        # The added token past the end of the vocabulary lands right after it.
        self.assertEqual([token["id"] for token in pruned["added_tokens"]], [0, 1, 2, 3, 10])
        self.assertEqual(pruned["post_processor"]["special_tokens"]["</s>"]["ids"], [2])
        self.assertEqual(pruned["padding"]["pad_id"], 1)
        # New ids are the ranks among the kept ids: the row of each token in the pruned matrix.
        self.assertEqual(common.pieces_by_id(pruned), [common.pieces_by_id(tokenizer)[old] for old in kept])
        # The original is untouched.
        self.assertEqual(len(tokenizer["model"]["vocab"]), 15)

    def test_ids_move_when_earlier_tokens_are_dropped(self):
        tokenizer = unigram_tokenizer()
        # Drop the padding token's neighbours but keep every special: ids shift down.
        kept = [0, 1, 2, 3, 6, 15]
        pruned = common.remap_tokenizer_json(tokenizer, kept)
        self.assertEqual([entry[0] for entry in pruned["model"]["vocab"]], ["<s>", "<pad>", "</s>", "<unk>", "▁world"])
        self.assertEqual([token["id"] for token in pruned["added_tokens"]], [0, 1, 2, 3, 5])

    def test_a_wordpiece_tokenizer_is_renumbered_consistently(self):
        pruned = common.remap_tokenizer_json(wordpiece_tokenizer(), [0, 1, 2, 3, 4, 6, 7, 9])
        self.assertEqual(pruned["model"]["vocab"], {
            "[PAD]": 0, "[UNK]": 1, "[CLS]": 2, "[SEP]": 3, "[MASK]": 4, "cat": 5, "##s": 6, "a": 7,
        })
        self.assertEqual(pruned["post_processor"]["sep"], ["[SEP]", 3])
        self.assertEqual(pruned["post_processor"]["cls"], ["[CLS]", 2])

    def test_dropping_a_token_the_tokenizer_needs_is_an_error(self):
        with self.assertRaises(common.ConversionError):
            common.remap_tokenizer_json(unigram_tokenizer(), [0, 1, 2, 4, 5, 15])       # the unknown token
        with self.assertRaises(common.ConversionError):
            common.remap_tokenizer_json(unigram_tokenizer(), [0, 1, 2, 3, 4, 5])        # the added <mask>
        with self.assertRaises(common.ConversionError):
            common.remap_tokenizer_json(unigram_tokenizer(), [1, 2, 3, 4, 15])          # <s>, used by the template
        with self.assertRaises(common.ConversionError):
            common.remap_tokenizer_json(wordpiece_tokenizer(), [0, 2, 3, 4, 5])         # [UNK]
        with self.assertRaises(common.ConversionError):
            common.remap_tokenizer_json(unigram_tokenizer(), [3, 2, 1, 0])              # not sorted
        with self.assertRaises(common.ConversionError):
            common.remap_tokenizer_json({"model": {"type": "BPE", "vocab": {}}}, [0])

    def test_selection_and_remapping_compose(self):
        tokenizer = unigram_tokenizer()
        kept = common.select_kept_ids(
            common.pieces_by_id(tokenizer), counts={5: 3, 8: 2},
            always_keep=common.added_token_ids(tokenizer), corpus_scripts={"LATIN", "CYRILLIC", "COMMON"},
        )
        pruned = common.remap_tokenizer_json(tokenizer, kept)
        pieces = [entry[0] for entry in pruned["model"]["vocab"]]
        self.assertIn("▁hello", pieces)
        self.assertIn("▁привет", pieces)
        self.assertNotIn("▁地図", pieces)
        self.assertEqual(common.added_token_ids(pruned), sorted(common.added_token_ids(pruned)))
        self.assertEqual(len(common.pieces_by_id(pruned)), len(kept))


class MiscellaneousTests(unittest.TestCase):
    def test_the_model_identity_depends_on_how_the_model_was_converted(self):
        first = common.model_identity("org/some-model", {"weights": "int8-linear", "vocabulary_size": 1000})
        again = common.model_identity("org/some-model", {"vocabulary_size": 1000, "weights": "int8-linear"})
        other = common.model_identity("org/some-model", {"weights": "int8-linear", "vocabulary_size": 999})
        self.assertEqual(first, again)
        self.assertNotEqual(first, other)
        self.assertTrue(first.startswith("some-model@"))

    def test_budgets_match_the_specification(self):
        self.assertEqual(common.SEQUENCE_LENGTH, 128)
        self.assertEqual(common.EMBEDDING_BUDGET_BYTES, 80 * 1024 * 1024)
        self.assertEqual(common.RERANKER_BUDGET_BYTES, 60 * 1024 * 1024)


if __name__ == "__main__":
    unittest.main()
