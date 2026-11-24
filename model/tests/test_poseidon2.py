import os
from pathlib import Path
import stat
import struct
import sys
import tempfile
import unittest
from unittest import mock

import msgpack

from felony.poseidon2 import FIELD_MODULUS, field, hash_fields


NOIR_KNOWN_ANSWERS = (
    ([1000], 0x16433A80E26A23547E25D61DD95FD5793D1CA2DCD78AE64CD146D3B99A35FA7C),
    ([1000, 2000], 0x118D5A5ECB25DAFE99EB45CB196604A23D0B7C0CBD0C2BE29E0787E59B7A1D8A),
    ([1000, 2000, 3000], 0x0F1BADCD0D52CED816FB6E6826FDF66ADA038135D53CBB993F320CA6529223CD),
)


FAKE_BB = """\
#!{python}
import struct, sys
import msgpack

if sys.argv[1:] == ["--version"]:
    print({version!r})
    sys.exit(0)
assert sys.argv[1:] == ["msgpack", "run"], sys.argv
data = sys.stdin.buffer.read()
open({record!r}, "wb").write(data)
mode = {mode!r}
def frame(obj):
    body = msgpack.packb(obj, use_bin_type=True)
    return struct.pack("<I", len(body)) + body
out = {{
    "ok": frame(["Poseidon2HashResponse", {{"hash": (5).to_bytes(32, "big")}}]),
    "error": frame(["ErrorResponse", {{"message": "rejected"}}]),
    "wrong_tag": frame(["Poseidon2PermutationResponse", {{"outputs": []}}]),
    "out_of_field": frame(["Poseidon2HashResponse", {{"hash": ({modulus}).to_bytes(32, "big")}}]),
    "short_hash": frame(["Poseidon2HashResponse", {{"hash": bytes(31)}}]),
    "truncated": frame(["Poseidon2HashResponse", {{"hash": bytes(32)}}])[:-5],
    "garbage": struct.pack("<I", 3) + b"\\xc1\\xc1\\xc1",
    "extra": frame(["Poseidon2HashResponse", {{"hash": bytes(32)}}]) * 2,
    "empty": b"",
    "exit": b"",
}}[mode]
sys.stdout.buffer.write(out)
sys.stderr.write("Scheme is: ultra_honk\\n")
sys.exit(3 if mode == "exit" else 0)
"""


def real_binary():
    configured = os.environ.get("BARRETENBERG_BIN")
    if configured:
        return Path(configured)
    return Path(__file__).resolve().parents[2].parent / "barretenberg_fe/.tools/barretenberg/bb"


class FieldTests(unittest.TestCase):
    def test_canonical_values_only(self):
        self.assertEqual(field(0), 0)
        self.assertEqual(field(FIELD_MODULUS - 1), FIELD_MODULUS - 1)
        for bad in (-1, FIELD_MODULUS, 2**256, True, False, 1.0, "1", None):
            with self.assertRaises(ValueError):
                field(bad)  # pyright: ignore[reportArgumentType] -- test rejects non-integers

    def test_noncanonical_input_is_rejected_before_any_backend_call(self):
        with mock.patch("subprocess.run", side_effect=AssertionError("backend called")):
            for bad in (-1, FIELD_MODULUS, True):
                with self.assertRaises(ValueError):
                    hash_fields([1, bad])


class FakeBackendTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.tmp = Path(self.dir.name)
        self.count = 0

    def tearDown(self):
        self.dir.cleanup()

    def fake(self, mode="ok", version="6.0.0"):
        self.count += 1
        path = self.tmp / f"bb{self.count}"
        record = self.tmp / f"request{self.count}"
        path.write_text(
            FAKE_BB.format(
                python=sys.executable,
                version=version,
                record=str(record),
                mode=mode,
                modulus=FIELD_MODULUS,
            )
        )
        path.chmod(path.stat().st_mode | stat.S_IXUSR)
        return path, record

    def hash_with(self, path, values=(1, 2, 3)):
        with mock.patch.dict(os.environ, {"BARRETENBERG_BIN": str(path)}):
            return hash_fields(list(values))

    def test_request_frame_and_field_encoding(self):
        path, record = self.fake()
        values = [0, 1, FIELD_MODULUS - 1, 2**200]
        self.assertEqual(self.hash_with(path, values), 5)
        data = record.read_bytes()
        (length,) = struct.unpack("<I", data[:4])
        self.assertEqual(length, len(data) - 4, "one little-endian length-prefixed frame")
        request = msgpack.unpackb(data[4:], raw=False)
        self.assertEqual(len(request), 1, "the command is wrapped in a one-element array")
        name, body = request[0]
        self.assertEqual((name, list(body)), ("Poseidon2Hash", ["inputs"]))

        self.assertEqual(body["inputs"], [v.to_bytes(32, "big") for v in values])

    def test_empty_message_is_sent_as_empty_input(self):
        path, record = self.fake()
        self.hash_with(path, [])
        request = msgpack.unpackb(record.read_bytes()[4:], raw=False)
        self.assertEqual(request[0][1]["inputs"], [])

    def test_backend_failures_raise(self):
        for mode in (
            "error",
            "wrong_tag",
            "out_of_field",
            "short_hash",
            "truncated",
            "garbage",
            "extra",
            "empty",
            "exit",
        ):
            path, record = self.fake(mode)
            with self.subTest(mode=mode):
                with self.assertRaises(RuntimeError):
                    self.hash_with(path)

                self.assertTrue(record.exists())

    def test_wrong_version_and_missing_binary_raise(self):
        for version in ("5.3.0", "6.0.0-nightly.20260831", "BB IDE"):
            path, record = self.fake(version=version)
            with self.subTest(version=version):
                with self.assertRaises(RuntimeError):
                    self.hash_with(path)
                self.assertFalse(record.exists(), "no hash request to an unverified binary")
        with self.assertRaises(RuntimeError):
            self.hash_with(self.tmp / "missing-bb")

    def test_path_bb_is_never_used(self):
        path, record = self.fake()
        (self.tmp / "bb").write_bytes(path.read_bytes())
        (self.tmp / "bb").chmod(0o755)
        env = {"PATH": str(self.tmp), "BARRETENBERG_BIN": str(self.tmp / "missing-bb")}
        with mock.patch.dict(os.environ, env), self.assertRaises(RuntimeError):
            hash_fields([1])
        self.assertFalse(record.exists())


@unittest.skipUnless(real_binary().is_file(), "pinned Barretenberg 6.0.0 binary not installed")
class NativeKnownAnswerTests(unittest.TestCase):
    def test_noir_known_answers(self):
        for message, expected in NOIR_KNOWN_ANSWERS:
            self.assertEqual(hash_fields(message), expected)

    def test_edge_lengths_and_values_are_canonical_and_distinct(self):
        messages = [[0] * n for n in range(8)] + [[FIELD_MODULUS - 1] * n for n in (1, 3, 4, 7)]
        hashes = [hash_fields(m) for m in messages]
        self.assertEqual(len(set(hashes)), len(hashes), "length separation")
        for value in hashes:
            self.assertEqual(field(value), value)

    def test_long_message_matches_recorded_model_digest(self):
        import json

        from felony.inference import Model

        data = json.loads(
            (Path(__file__).resolve().parents[2] / "test_vectors/inference.json").read_text()
        )
        case = data["cases"][0]
        spec = data["models"][case["model"]]
        model = Model(tuple(int(x) for x in spec["w"]), tuple(int(x) for x in spec["b"]))
        self.assertEqual(model.digest, int(case["expected"]["model_digest"], 0))


if __name__ == "__main__":
    unittest.main()
