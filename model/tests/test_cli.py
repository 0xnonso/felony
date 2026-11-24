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
from felony.actor import load_export
from felony.training import Trainer

BASE = Path(__file__).resolve().parents[1] / "base"


def run(*argv):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        cli.main([str(a) for a in argv])
    return json.loads(out.getvalue()[out.getvalue().index("{") :])


class StarterCliTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        torch.set_num_threads(1)

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.tmp = Path(self.dir.name)

    def tearDown(self):
        self.dir.cleanup()

    def test_shipped_models_match_manifest_and_reference(self):
        manifest = json.loads((BASE / "MANIFEST.json").read_text())
        for name in ("felony-untrained.json", "felony-base.json"):
            path = BASE / name
            self.assertEqual(cli.sha256(path), manifest[name]["sha256"], name)
            data = json.loads(path.read_text())
            self.assertEqual(
                set(data), {"spec_version", "architecture", "w", "b"}, "no key or salt"
            )
            report = run("check", path)
            self.assertTrue(report["exact"])

    def test_init_is_deterministic_and_reproduces_untrained_base(self):
        out = self.tmp / "init.json"
        run("init", out, "--seed", 0)
        self.assertEqual(out.read_bytes(), (BASE / "felony-untrained.json").read_bytes())
        with self.assertRaises(FileExistsError):
            cli.init(out)

    def test_train_is_reproducible_and_resume_matches_continuous_training(self):
        base = BASE / "felony-untrained.json"
        args = ("--base", base, "--batch-games", 16, "--seed", 5)
        run("train", self.tmp / "a", "--updates", 3, *args)
        run("train", self.tmp / "b", "--updates", 3, *args)
        a = (self.tmp / "a/model.json").read_bytes()
        self.assertEqual(a, (self.tmp / "b/model.json").read_bytes())
        self.assertNotEqual(a, base.read_bytes())
        run("train", self.tmp / "c", "--updates", 2, *args)
        run("train", self.tmp / "c", "--resume", "--updates", 1)
        self.assertEqual(a, (self.tmp / "c/model.json").read_bytes())
        info = json.loads((self.tmp / "c/run.json").read_text())
        self.assertEqual((info["updates"], info["base_sha256"]), (3, cli.sha256(base)))
        with self.assertRaises(FileExistsError):
            cli.train(self.tmp / "a", 1, base=base)
        with self.assertRaises(ValueError):
            cli.train(self.tmp / "d", 1, base=base, batch_games=0)
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            cli.main(["train", str(self.tmp / "a"), "--resume", "--base", str(base)])

    def test_starter_workflow_needs_no_barretenberg(self):
        with mock.patch.dict(os.environ, {"BARRETENBERG_BIN": str(self.tmp / "missing-bb")}):
            initial = self.tmp / "initial.json"
            run("init", initial)
            report = run(
                "train", self.tmp / "trained", "--base", initial, "--updates", 1, "--batch-games", 8
            )
            self.assertTrue(report["exact"])
            self.assertNotIn("model_digest", report)
            checked = run("check", self.tmp / "trained/model.json")
            self.assertEqual(checked["sha256"], report["sha256"])
            evaluated = run(
                "evaluate", self.tmp / "trained/model.json", "--opponent", "match", "--groups", 4
            )
            self.assertIn("match", evaluated["opponents"])

    def test_tournament_training_setting_survives_resume(self):
        common = ("--batch-games", 8, "--scoring", "tournament")
        run("train", self.tmp / "whole", "--updates", 2, *common)
        run("train", self.tmp / "split", "--updates", 1, *common)
        run("train", self.tmp / "split", "--updates", 1, "--resume")
        saved = Trainer.load(self.tmp / "split")
        self.assertEqual(saved.config.scoring, "tournament")
        self.assertEqual(
            (self.tmp / "whole/model.json").read_bytes(),
            (self.tmp / "split/model.json").read_bytes(),
        )
        report = run(
            "evaluate",
            self.tmp / "split/model.json",
            "--scoring",
            "tournament",
            "--opponent",
            "match",
            "--groups",
            4,
        )
        self.assertEqual(report["scoring"], "tournament")
        with self.assertRaisesRegex(ValueError, "saved models and settings"):
            run("train", self.tmp / "split", "--resume", "--updates", 1, "--scoring", "pvp")

    def test_target_and_pool_survive_resume_without_original_files(self):
        target = self.tmp / "target-source.json"
        opponent = self.tmp / "opponent-source.json"
        target.write_bytes((BASE / "felony-base.json").read_bytes())
        opponent.write_bytes((BASE / "felony-untrained.json").read_bytes())
        args = (
            "--target",
            target,
            "--target-fraction",
            1,
            "--opponent",
            opponent,
            "--batch-games",
            8,
            "--seed",
            9,
        )
        run("train", self.tmp / "whole", "--updates", 3, *args)
        run("train", self.tmp / "split", "--updates", 2, *args)
        saved = Trainer.load(self.tmp / "split")
        self.assertEqual(saved.config.target_fraction, 1)
        self.assertEqual(saved.external_population[0].export(), load_export(opponent).export())
        target.unlink()
        opponent.unlink()
        run("train", self.tmp / "split", "--resume", "--updates", 1)
        self.assertEqual(
            (self.tmp / "whole/model.json").read_bytes(),
            (self.tmp / "split/model.json").read_bytes(),
        )
        info = json.loads((self.tmp / "split/run.json").read_text())
        self.assertEqual(info["games"], 24)
        self.assertEqual(info["target"]["sha256"], cli.sha256(self.tmp / "split/target.json"))

        run("train", self.tmp / "control", "--updates", 3, "--batch-games", 8, "--seed", 9)
        self.assertNotEqual(
            (self.tmp / "whole/model.json").read_bytes(),
            (self.tmp / "control/model.json").read_bytes(),
        )
        (self.tmp / "split/target.json").write_bytes((BASE / "felony-untrained.json").read_bytes())
        with self.assertRaisesRegex(ValueError, "saved target changed"):
            cli.train(self.tmp / "split", 1, resume=True)

    def test_target_settings_are_validated(self):
        base = BASE / "felony-base.json"
        for fraction in (-0.1, 1.1, float("nan")):
            with self.assertRaises(ValueError):
                cli.train(self.tmp / "bad", 1, base=base, target=base, target_fraction=fraction)
        with self.assertRaises(ValueError):
            cli.train(self.tmp / "bad", 1, base=base, target_fraction=0.5)
        with self.assertRaises(ValueError):
            cli.train(self.tmp / "bad", 1, resume=True, target=base)
        with self.assertRaises(ValueError):
            cli.train(self.tmp / "bad", 1, resume=True, opponents=[base])
        self.assertFalse((self.tmp / "bad").exists())

    def test_evaluation_seed_changes_schedule_reproducibly(self):
        base = BASE / "felony-base.json"
        a = run("evaluate", base, "--opponent", "uniform", "--groups", 8, "--seed", 21)
        b = run("evaluate", base, "--opponent", "uniform", "--groups", 8, "--seed", 21)
        c = run("evaluate", base, "--opponent", "uniform", "--groups", 8, "--seed", 22)
        self.assertEqual(a, b)
        self.assertNotEqual(a["schedule"], c["schedule"])

    def test_check_rejects_invalid_exports(self):
        data = json.loads((BASE / "felony-untrained.json").read_text())
        for field, index, value in (("w", 0, 256), ("w", 1, 1.0), ("b", 0, -1)):
            bad = dict(data, **{field: list(data[field])})
            bad[field][index] = value
            path = self.tmp / "bad.json"
            path.write_text(json.dumps(bad))
            with self.assertRaises(ValueError):
                cli.check(path)

    def test_evaluate_reports_scores_against_heuristics_and_models(self):
        report = run(
            "evaluate",
            BASE / "felony-base.json",
            "--opponent",
            "match",
            "--opponent",
            BASE / "felony-untrained.json",
            "--groups",
            20,
        )
        self.assertEqual(set(report["opponents"]), {"match", str(BASE / "felony-untrained.json")})
        self.assertEqual(report["games_per_opponent"], 40)
        for estimates in report["opponents"].values():
            self.assertTrue(0 <= estimates["score"]["value"] <= 1)

        for name in ("felony-base.json", "felony-untrained.json"):
            (self.tmp / name).write_bytes((BASE / name).read_bytes())
        moved = run(
            "evaluate",
            self.tmp / "felony-base.json",
            "--opponent",
            "match",
            "--opponent",
            self.tmp / "felony-untrained.json",
            "--groups",
            20,
        )
        self.assertEqual(list(report["opponents"].values()), list(moved["opponents"].values()))
        with self.assertRaises(ValueError):
            cli.evaluate(BASE / "felony-base.json", groups=0)
        with self.assertRaises(ValueError):
            cli.check(BASE / "felony-base.json", games=-1)


if __name__ == "__main__":
    unittest.main()
