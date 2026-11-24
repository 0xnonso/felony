from collections.abc import Iterable
from functools import lru_cache
import os
import struct
import subprocess
from typing import cast

import msgpack

from .toolchain import installed_tools

FIELD_MODULUS = 21888242871839275222246405745257275088548364400416034343698204186575808495617
BARRETENBERG_VERSION = "6.0.0"


def field(value: int) -> int:
    if type(value) is not int or not 0 <= value < FIELD_MODULUS:
        raise ValueError("noncanonical field element")
    return value


@lru_cache(maxsize=4)
def _checked_binary(path: str) -> str:
    try:
        result = subprocess.run([path, "--version"], capture_output=True, timeout=10, check=True)
    except (OSError, subprocess.SubprocessError):
        raise RuntimeError(
            "Set BARRETENBERG_BIN to the Barretenberg 6.0.0 executable. "
            "The BB IDE executable is not Barretenberg."
        ) from None
    if result.stdout.strip() != BARRETENBERG_VERSION.encode():
        raise RuntimeError("Poseidon2 requires Barretenberg 6.0.0")
    return path


@lru_cache(maxsize=1)
def _default_binary():
    return str(installed_tools(("barretenberg",))["barretenberg"])


def hash_fields(values: Iterable[int]) -> int:
    inputs = [field(value).to_bytes(32, "big") for value in values]
    selected = os.environ.get("BARRETENBERG_BIN") or _default_binary()
    binary = _checked_binary(selected)
    request = cast(bytes, msgpack.packb([["Poseidon2Hash", {"inputs": inputs}]], use_bin_type=True))
    try:
        result = subprocess.run(
            [binary, "msgpack", "run"],
            input=struct.pack("<I", len(request)) + request,
            capture_output=True,
            timeout=30,
            check=True,
        )
    except (OSError, subprocess.SubprocessError):
        raise RuntimeError("Barretenberg Poseidon2 request failed") from None
    output = result.stdout
    try:
        if len(output) < 4 or struct.unpack("<I", output[:4])[0] != len(output) - 4:
            raise ValueError("invalid frame")
        response = msgpack.unpackb(output[4:], raw=False)
        if not isinstance(response, list) or len(response) != 2:
            raise ValueError("invalid response")
        tag, payload = response
        if tag != "Poseidon2HashResponse" or not isinstance(payload, dict):
            raise ValueError("unexpected response")
        digest = payload["hash"]
        if not isinstance(digest, bytes) or len(digest) != 32:
            raise ValueError("invalid digest")
        return field(int.from_bytes(digest, "big"))
    except (ValueError, TypeError, KeyError, msgpack.UnpackException):
        raise RuntimeError("Invalid Barretenberg Poseidon2 response") from None
