from collections.abc import Iterable

from Crypto.Hash import keccak


def keccak_words(words: Iterable[int]) -> int:
    encoded = bytearray()
    for value in words:
        if type(value) is not int or not 0 <= value < 2**256:
            raise ValueError("hash words must be uint256")
        encoded.extend(value.to_bytes(32, "big"))
    return int.from_bytes(keccak.new(digest_bits=256, data=bytes(encoded)).digest(), "big")
