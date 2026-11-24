#!/usr/bin/env python3
"""Regenerate or check PUBLIC SYNTHETIC cross-language fixtures."""

import argparse
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "model"))
from felony.fixtures import build_vectors  # noqa: E402


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    destination = ROOT / "test_vectors/inference.json"
    generated = build_vectors()
    if args.check:
        if json.loads(destination.read_text()) != generated:
            raise SystemExit("inference vectors are stale")
        print(f"Verified {len(generated['cases'])} independent reference fixtures")
    else:
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(json.dumps(generated, separators=(",", ":")) + "\n")
        print(destination)


if __name__ == "__main__":
    main()
