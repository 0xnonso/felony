import importlib.util
import json
from pathlib import Path
import unittest

from felony.keccak import keccak_words

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    "bracket_reference", ROOT / "tests/reference/bracket.py"
)
assert spec is not None and spec.loader is not None
bracket = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bracket)

VECTORS = json.loads((ROOT / "test_vectors/bracket.json").read_text())


def _build(case, vectors=VECTORS):
    return bracket.build_bracket(
        vectors["chain"],
        vectors["controller"],
        vectors["tournament"],
        vectors["seed"],
        case["count"],
        case["capacity"],
    )


class KeccakTests(unittest.TestCase):
    def test_ethereum_keccak_known_answers(self):
        self.assertEqual(
            keccak_words([]),
            int("c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470", 16),
        )
        self.assertEqual(
            keccak_words([0]),
            int("290decd9548b62a8d60345a988386fc84ba6bc95484008f6362f93160ef3e563", 16),
        )
        self.assertNotEqual(keccak_words([1]), keccak_words([0, 1]))
        self.assertNotEqual(keccak_words([1, 2]), keccak_words([2, 1]))

    def test_invalid_words_are_rejected(self):
        for value in (-1, 2**256, True, 1.5, "1", None):
            with self.subTest(value=value), self.assertRaises(ValueError):
                keccak_words([value])  # pyright: ignore[reportArgumentType]

    def test_brackets_match_independent_solidity_vectors(self):
        for case in VECTORS["cases"]:
            with self.subTest(count=case["count"]):
                result = _build(case)
                self.assertEqual(result["root"], int(case["root"], 16))
                self.assertEqual(bracket.pair_proof(result, case["proof"]["index"]), case["proof"])

    def test_swapped_leaf_order_does_not_match_recorded_root(self):
        for case in VECTORS["cases"]:
            tree = _build(case)
            index = case["capacity"] // 2
            proof = bracket.pair_proof(tree, index)
            left = keccak_words([513, tree["context"], 0, proof["slot0"]])
            right = keccak_words([513, tree["context"], 1, proof["slot1"]])
            digest = keccak_words([right, left])
            depth = case["capacity"].bit_length() - 2
            for sibling in proof["siblings"][:depth]:
                digest = keccak_words([digest, sibling])
            with self.subTest(count=case["count"]):
                self.assertNotEqual(digest, int(case["root"], 16))

    def test_every_pair_proof_reconstructs_recorded_root(self):
        for case in VECTORS["cases"]:
            tree = _build(case)
            depth = case["capacity"].bit_length() - 2
            for index in range(case["capacity"] // 2, case["capacity"]):
                proof = bracket.pair_proof(tree, index)
                position = 2 * (index - case["capacity"] // 2)
                left = keccak_words([513, tree["context"], position, proof["slot0"]])
                right = keccak_words([513, tree["context"], position + 1, proof["slot1"]])

                digest = keccak_words([left, right])
                node = index
                for sibling in proof["siblings"][:depth]:
                    pair = [sibling, digest] if node % 2 else [digest, sibling]
                    digest = keccak_words(pair)
                    node //= 2
                with self.subTest(count=case["count"], index=index):
                    self.assertEqual(digest, int(case["root"], 16))
                    self.assertEqual(proof["siblings"][depth:], [0] * (9 - depth))


if __name__ == "__main__":
    unittest.main()
