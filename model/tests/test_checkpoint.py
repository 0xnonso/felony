import contextlib
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import torch

from felony import cli
from felony.training import Trainer

BASE = Path(__file__).resolve().parents[1] / "base/felony-untrained.json"


class CheckpointTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.output = self.root / "run"

    def tearDown(self):
        self.directory.cleanup()

    def train(self, directory=None, updates=1, resume=False):
        with contextlib.redirect_stdout(io.StringIO()):
            return cli.train(
                self.output if directory is None else directory,
                updates,
                base=None if resume else BASE,
                resume=resume,
                batch_games=8,
                seed=7,
                target=None if resume else BASE,
            )

    def assert_consistent(self, updates):
        trainer = Trainer.load(self.output)
        info = json.loads((self.output / "run.json").read_text())
        self.assertEqual(trainer.iteration, updates)
        self.assertEqual(info, trainer.run_info)
        self.assertEqual(info["updates"], updates)
        self.assertEqual(info["model_sha256"], cli.sha256(self.output / "model.json"))
        self.assertEqual(cli.check(self.output / "model.json", games=0)["exact"], True)
        self.assertEqual(list(self.output.glob(".*")), [])

    @staticmethod
    def partial_save(_saved, path):
        Path(path).write_bytes(b"interrupted checkpoint")
        raise OSError("disk write failed")

    def test_failed_first_save_can_restart(self):
        with mock.patch("felony.training.torch.save", side_effect=self.partial_save):
            with self.assertRaisesRegex(OSError, "disk write failed"):
                self.train()
        self.assertFalse((self.output / "training.pt").exists())
        self.assertFalse((self.output / "model.json").exists())
        self.assertFalse((self.output / "run.json").exists())
        self.assertEqual(list(self.output.glob(".*")), [])
        self.train()
        self.assert_consistent(1)

    def test_partial_resumed_save_preserves_previous_checkpoint(self):
        self.train()
        before = {
            name: (self.output / name).read_bytes()
            for name in ("training.pt", "model.json", "run.json")
        }
        with mock.patch("felony.training.torch.save", side_effect=self.partial_save):
            with self.assertRaisesRegex(OSError, "disk write failed"):
                self.train(resume=True)
        for name, data in before.items():
            self.assertEqual((self.output / name).read_bytes(), data, name)
        self.assert_consistent(1)
        self.train(resume=True)
        whole = self.train(self.root / "whole", updates=2)
        self.assertEqual((self.output / "model.json").read_bytes(), whole.read_bytes())
        self.assert_consistent(2)

    def test_replacement_interruptions_recover_old_or_new_checkpoint(self):
        replace = os.replace
        for failed_name in ("training.pt", "model.json", "run.json"):
            for fresh in (True, False):
                with self.subTest(file=failed_name, first_save=fresh):
                    self.output = self.root / f"{failed_name}-{fresh}"
                    if not fresh:
                        self.train()

                    def interrupt(source, destination):
                        if Path(destination).name == failed_name:
                            raise KeyboardInterrupt("simulated interruption")
                        replace(source, destination)

                    with mock.patch("felony.training.os.replace", side_effect=interrupt):
                        with self.assertRaises(KeyboardInterrupt):
                            self.train(resume=not fresh)
                    if failed_name == "training.pt":
                        if fresh:
                            self.assertFalse((self.output / "training.pt").exists())
                            self.train()
                            self.assert_consistent(1)
                        else:
                            self.assert_consistent(1)
                    else:
                        committed = 1 if fresh else 2
                        self.assertEqual(Trainer.load(self.output).iteration, committed)

                        (self.output / "run.json").unlink(missing_ok=True)
                        self.train(resume=True)
                        self.assert_consistent(committed + 1)
                        whole = self.train(
                            self.root / f"whole-{failed_name}-{fresh}", updates=committed + 1
                        )
                        self.assertEqual(
                            (self.output / "model.json").read_bytes(), whole.read_bytes()
                        )

    def test_legacy_checkpoint_uses_existing_metadata_then_upgrades(self):
        self.train()
        path = self.output / "training.pt"
        saved = torch.load(path, weights_only=True)
        del saved["run_info"]
        torch.save(saved, path)
        self.assertIsNone(Trainer.load(self.output).run_info)
        self.train(resume=True)
        self.assert_consistent(2)


if __name__ == "__main__":
    unittest.main()
