import hashlib
import json
import math
import unittest

import numpy as np

from felony.evaluation import (
    DEVELOPMENT,
    HELDOUT,
    Estimate,
    MatchupResult,
    SeedSchedule,
    _bootstrap_means,
    _estimate,
    classify_gain,
    compare_paired,
    compare_panel,
    cross_play,
    derive_seed,
    evaluate_matchup,
    group_statistics,
    qualify_candidate,
    qualify_runs,
    summarize_matchup,
    summarize_panel,
    summarize_runs,
)

REPLICATES = 400
SECRET = "public-unit-test-secret"


class FakePolicy:
    def __init__(self, strength):
        self.strength = strength


def fake_play(first, second, games, seed):
    deal = np.random.default_rng(seed).random(games)
    edge = 0.5 + (first.strength - second.strength) / 2
    outcome = np.where(deal < edge - 0.05, 1.0, np.where(deal < edge + 0.05, 0.5, 0.0))

    if first.strength < second.strength:
        outcome = np.where(
            1 - deal < 0.5 + (second.strength - first.strength) / 2 - 0.05,
            0.0,
            np.where(1 - deal < 0.5 + (second.strength - first.strength) / 2 + 0.05, 0.5, 1.0),
        )
    return {"outcome": outcome, "difference": np.rint(2 * outcome - 1).astype(np.int64) * 3}


def result_from(outcomes, candidate="a", opponent="b", split=DEVELOPMENT, schedule="s", label=None):
    outcomes = np.asarray(outcomes, dtype=float)
    return MatchupResult(
        candidate, opponent, split, schedule, label or opponent, 1000, outcomes, 2 * outcomes - 1
    )


def estimate(value, low, high):
    return Estimate(value, low, high, 0.01, 0.95, 100)


class SeedTests(unittest.TestCase):
    def test_seed_matches_its_published_construction(self):
        digest = hashlib.sha256()
        for tag, data in ((b"s", b"felony-evaluation-v1"), (b"s", b"bob"), (b"i", b"7")):
            digest.update(tag + len(data).to_bytes(8, "big") + data)
        self.assertEqual(derive_seed("bob", 7), int.from_bytes(digest.digest()[:8], "big") >> 1)
        self.assertLess(derive_seed("bob", 7), 1 << 63)

    def test_parts_cannot_be_joined_ambiguously(self):
        self.assertNotEqual(derive_seed("ab", "c"), derive_seed("a", "bc"))
        self.assertNotEqual(derive_seed("1"), derive_seed(1))
        with self.assertRaises(TypeError):
            derive_seed(True)

    def test_schedules_separate_splits_opponents_and_secrets(self):
        development = SeedSchedule(DEVELOPMENT)
        heldout = SeedSchedule(HELDOUT, SECRET)
        self.assertNotEqual(development.seed("x"), heldout.seed("x"))
        self.assertNotEqual(heldout.seed("x"), heldout.seed("y"))
        self.assertNotEqual(heldout.seed("x"), SeedSchedule(HELDOUT, SECRET + "2").seed("x"))
        self.assertNotIn(SECRET, heldout.fingerprint)

    def test_heldout_requires_a_secret_and_known_split(self):
        with self.assertRaises(ValueError):
            SeedSchedule(HELDOUT)
        with self.assertRaises(ValueError):
            SeedSchedule("training")


class GroupTests(unittest.TestCase):
    def test_hand_computed_group_statistics(self):
        outcomes = np.array([[1.0, 0.0], [0.5, 1.0], [0.0, 0.0]])
        margins = np.array([[4.0, -2.0], [0.0, 6.0], [-1.0, -3.0]])
        expected = [
            [0.5, 0.5, 0.0, 0.5, 1.0],
            [0.75, 0.5, 0.5, 0.0, 3.0],
            [0.0, 0.0, 0.0, 1.0, -2.0],
        ]
        np.testing.assert_array_equal(group_statistics(outcomes, margins), expected)

    def test_tournament_tiebreak_preserves_zero_margin_and_cannot_mix_with_pvp(self):
        def policy(cards):
            cards = np.asarray(cards) - 1
            return lambda x, legal, rng: cards[x[:, 27:36].argmax(1)]

        a = policy([6, 3, 5, 2, 1, 4, 8, 7, 9])
        b = policy([8, 7, 2, 4, 3, 5, 6, 1, 9])
        schedule = SeedSchedule(DEVELOPMENT)
        pvp = evaluate_matchup(a, b, "a", "b", schedule, 8)
        tournament = evaluate_matchup(a, b, "a", "b", schedule, 8, scoring="tournament")
        np.testing.assert_array_equal(pvp.outcomes, 0.5)
        np.testing.assert_array_equal(tournament.outcomes, 1)
        np.testing.assert_array_equal(tournament.margins, 0)
        self.assertEqual(tournament.to_json(replicates=10)["scoring"], "tournament")
        self.assertEqual(summarize_matchup(tournament, replicates=10)["score"].value, 1)
        with self.assertRaisesRegex(ValueError, "scoring"):
            compare_paired(tournament, pvp, threshold=0, replicates=10)
        with self.assertRaisesRegex(ValueError, "scoring"):
            summarize_panel([pvp, tournament], replicates=10)
        with self.assertRaises(ValueError):
            group_statistics(np.array([[1.0, 0.0]]), np.array([[-1.0, 1.0]]), "tournament")

    def test_invalid_games_are_rejected(self):
        good = np.array([[1.0, 0.0]])
        with self.assertRaises(ValueError):
            group_statistics(np.array([[0.25, 0.0]]), np.array([[1.0, -1.0]]))
        with self.assertRaises(ValueError):
            group_statistics(good, np.array([[-1.0, -1.0]]))
        with self.assertRaises(ValueError):
            group_statistics(np.array([1.0, 0.0]), np.array([1.0, -1.0]))
        with self.assertRaises(ValueError):
            group_statistics(good, np.array([[1.0, -1.0], [1.0, -1.0]]))


class MatchupTests(unittest.TestCase):
    def test_seats_are_combined_from_the_candidate_perspective(self):
        calls = []

        def play(first, second, games, seed):
            calls.append((first, second, games, seed))
            if first == "candidate":
                return {"outcome": np.array([1.0, 0.5]), "difference": np.array([3, 0])}
            return {"outcome": np.array([1.0, 0.0]), "difference": np.array([2, -5])}

        result = evaluate_matchup(
            "candidate",
            "opponent",
            "c",
            "o",
            SeedSchedule(DEVELOPMENT),
            2,
            chunk_groups=2,
            play=play,
        )
        np.testing.assert_array_equal(result.outcomes, [[1.0, 0.0], [0.5, 1.0]])
        np.testing.assert_array_equal(result.margins, [[3, -2], [0, 5]])
        self.assertEqual(calls[0][:2], ("candidate", "opponent"))
        self.assertEqual(calls[1][:2], ("opponent", "candidate"))
        self.assertEqual(calls[0][3], calls[1][3])

    def test_seeds_ignore_the_candidate_and_change_with_the_opponent(self):
        seen = {}

        def play(first, second, games, seed):
            seen.setdefault((first, second), seed)
            return {"outcome": np.ones(games), "difference": np.ones(games, dtype=np.int64)}

        schedule = SeedSchedule(DEVELOPMENT)
        evaluate_matchup("a1", "o1", "a1", "o1", schedule, 1, play=play)
        evaluate_matchup("a2", "o1", "a2", "o1", schedule, 1, play=play)
        evaluate_matchup("a1", "o2", "a1", "o2", schedule, 1, play=play)
        self.assertEqual(seen[("a1", "o1")], seen[("a2", "o1")])
        self.assertNotEqual(seen[("a1", "o1")], seen[("a1", "o2")])

    def test_partial_chunks_do_not_depend_on_the_requested_groups(self):
        def batch_sensitive_play(first, second, games, seed):
            wins = np.random.default_rng([seed, games]).random(games) < 0.5
            return {"outcome": wins.astype(float), "difference": 2 * wins.astype(np.int64) - 1}

        args = "a", "b", "a", "b", SeedSchedule(DEVELOPMENT)
        small = evaluate_matchup(*args, 250, chunk_groups=100, play=batch_sensitive_play)
        large = evaluate_matchup(*args, 500, chunk_groups=100, play=batch_sensitive_play)
        np.testing.assert_array_equal(small.outcomes, large.outcomes[:250])
        np.testing.assert_array_equal(small.margins, large.margins[:250])

    def test_wrong_simulator_output_is_rejected(self):
        schedule = SeedSchedule(DEVELOPMENT)

        def short(first, second, games, seed):
            return {"outcome": np.ones(games - 1), "difference": np.ones(games - 1, dtype=np.int64)}

        def fractional(first, second, games, seed):
            return {"outcome": np.ones(games), "difference": np.ones(games)}

        for play in (short, fractional):
            with self.assertRaises(ValueError):
                evaluate_matchup("a", "b", "a", "b", schedule, 3, play=play)


class BootstrapTests(unittest.TestCase):
    def test_constant_values_have_zero_width(self):
        score = summarize_matchup(result_from([[1.0, 0.0]] * 50), replicates=REPLICATES)["score"]
        self.assertEqual(
            (score.value, score.low, score.high, score.standard_error), (0.5, 0.5, 0.5, 0.0)
        )

    def test_batch_size_does_not_change_the_replicates(self):
        values = np.random.default_rng(1).random((200, 3))
        reference = _bootstrap_means(values, 50, 9, batch_size=50)
        for batch_size in (1, 7, 128):
            np.testing.assert_array_equal(
                _bootstrap_means(values, 50, 9, batch_size=batch_size), reference
            )

    def test_replicates_are_reproducible(self):
        result = result_from(np.random.default_rng(2).integers(0, 2, (100, 2)))
        self.assertEqual(
            summarize_matchup(result, replicates=REPLICATES),
            summarize_matchup(result, replicates=REPLICATES),
        )

    def test_five_thousand_correlated_seats_count_as_one_observation(self):
        wins = np.random.default_rng(3).integers(0, 2, 5000).astype(float)
        result = result_from(np.column_stack((wins, wins)))
        p = wins.mean()
        cluster_se = math.sqrt(p * (1 - p) / len(wins))
        score = summarize_matchup(result, replicates=2000)["score"]
        measured = score.standard_error
        self.assertAlmostEqual(measured / cluster_se, 1.0, delta=0.08)
        self.assertGreater(measured, 1.3 * cluster_se / math.sqrt(2))
        self.assertLess(score.high - score.low, 0.05)

    def test_hand_computed_percentiles_and_sample_standard_error(self):
        result = _estimate(0.5, np.array([0, 0.25, 0.5, 0.75, 1]), confidence=0.5)
        self.assertEqual((result.value, result.low, result.high), (0.5, 0.25, 0.75))
        self.assertAlmostEqual(result.standard_error, math.sqrt(5 / 32))
        self.assertEqual((result.confidence, result.replicates), (0.5, 5))


class ComparisonTests(unittest.TestCase):
    def setUp(self):
        self.schedule = SeedSchedule(DEVELOPMENT)
        self.opponent = FakePolicy(0.0)

    def play_against(self, name, strength, opponent_id="control-opponent", groups=2000):
        return evaluate_matchup(
            FakePolicy(strength),
            self.opponent,
            name,
            opponent_id,
            self.schedule,
            groups,
            play=fake_play,
        )

    def test_shared_deals_tighten_the_paired_interval(self):
        strong, weak = self.play_against("strong", 0.2), self.play_against("weak", 0.1)
        paired = compare_paired(strong, weak, 0.03, replicates=REPLICATES)["gain"]["score"]
        separate = [
            summarize_matchup(r, replicates=REPLICATES)["score"].standard_error
            for r in (strong, weak)
        ]
        self.assertLess(paired["standard_error"], math.hypot(*separate))
        self.assertGreater(paired["value"], 0.0)

    def test_candidate_equal_to_control_has_zero_gain(self):
        result = self.play_against("same", 0.1)
        comparison = compare_paired(result, result, 0.03, replicates=REPLICATES)
        self.assertEqual(comparison["gain"]["score"]["value"], 0.0)
        self.assertEqual(comparison["classification"], "below_threshold")

    def test_unpaired_results_are_rejected(self):
        strong = self.play_against("strong", 0.2)
        with self.assertRaises(ValueError):
            compare_paired(strong, self.play_against("weak", 0.1, "other-opponent"), 0.03)
        with self.assertRaises(ValueError):
            compare_paired(strong, self.play_against("weak", 0.1, groups=1000), 0.03)

    def test_classification_uses_the_whole_interval(self):
        self.assertEqual(classify_gain(estimate(0.05, 0.03, 0.07), 0.03), "meets_threshold")
        self.assertEqual(classify_gain(estimate(0.04, 0.02, 0.06), 0.03), "inconclusive")
        self.assertEqual(classify_gain(estimate(0.01, -0.01, 0.029), 0.03), "below_threshold")

    def test_panel_gain_weights_opponents_equally(self):
        def constant(value, opponent):
            return result_from(
                np.full((10 if opponent == "x" else 1000, 2), value),
                candidate="c",
                opponent=opponent,
            )

        candidate = [constant(1.0, "x"), constant(0.5, "y")]
        control = [constant(0.0, "x"), constant(0.5, "y")]
        report = compare_panel(candidate, control, 0.03, replicates=REPLICATES)
        self.assertEqual(report["panel_gain"]["score"]["value"], 0.5)
        self.assertEqual(report["per_opponent"]["y"]["gain"]["score"]["value"], 0.0)

    def test_panel_gain_needs_matching_opponents(self):
        with self.assertRaises(ValueError):
            compare_panel(
                [result_from([[1.0, 1.0]], opponent="x")],
                [result_from([[1.0, 1.0]], opponent="y")],
                0.03,
            )

    def test_panel_reports_the_weakest_matchup(self):
        results = [
            result_from([[1.0, 1.0]] * 20, opponent="easy"),
            result_from([[0.0, 0.5]] * 20, opponent="hard"),
        ]
        report = summarize_panel(results, replicates=REPLICATES)
        self.assertEqual(report["panel"]["score"]["value"], 0.625)

        self.assertAlmostEqual(report["panel"]["score"]["low"], 0.625)
        self.assertAlmostEqual(report["panel"]["score"]["high"], 0.625)
        self.assertEqual((report["worst_opponent"], report["worst_opponent_score"]), ("hard", 0.25))

    def test_splits_cannot_be_mixed(self):
        results = [
            result_from([[1.0, 1.0]], opponent="x", split=DEVELOPMENT),
            result_from([[1.0, 1.0]], opponent="y", split=HELDOUT),
        ]
        with self.assertRaises(ValueError):
            summarize_panel(results, replicates=REPLICATES)

    def test_duplicate_panel_opponents_are_rejected(self):
        result = result_from([[1.0, 1.0]], opponent="x")
        with self.assertRaises(ValueError):
            summarize_panel([result, result], replicates=REPLICATES)


class QualificationTests(unittest.TestCase):
    def results(self, hard_score=1.0, split=HELDOUT):
        return [
            result_from([[1.0, 1.0]] * 100, opponent="easy", split=split),
            result_from([[hard_score, hard_score]] * 100, opponent="hard", split=split),
        ]

    def qualify(self, results, **options):
        return qualify_candidate(results, ["easy", "hard"], 0.02, replicates=REPLICATES, **options)

    def test_candidate_must_beat_every_required_opponent(self):
        self.assertTrue(self.qualify(self.results())["passed"])
        report = self.qualify(self.results(hard_score=0.5))
        self.assertFalse(report["passed"])
        self.assertEqual(report["failed_opponents"], ["hard"])

    def test_point_estimate_alone_does_not_qualify(self):
        narrow_lead = [[1.0, 1.0]] * 22 + [[0.0, 0.0]] * 18
        results = [result_from(narrow_lead, opponent="close", split=HELDOUT)]
        report = qualify_candidate(results, ["close"], 0.02, replicates=REPLICATES)
        self.assertGreater(report["opponents"]["close"]["score"]["value"], 0.52)
        self.assertFalse(report["passed"])

    def test_development_results_cannot_qualify(self):
        with self.assertRaises(ValueError):
            self.qualify(self.results(split=DEVELOPMENT))

    def test_training_opponents_cannot_qualify(self):
        with self.assertRaises(ValueError):
            self.qualify(self.results(), training_opponents=["hard"])

    def test_missing_opponent_is_an_error(self):
        with self.assertRaises(ValueError):
            self.qualify(self.results()[:1])

    def test_runs_are_counted_against_the_declared_requirement(self):
        reports = {"r1": {"passed": True}, "r2": {"passed": False}, "r3": {"passed": True}}
        self.assertTrue(qualify_runs(reports, 2)["qualified"])
        report = qualify_runs(reports, 3)
        self.assertFalse(report["qualified"])
        self.assertEqual(report["failed_runs"], ["r2"])


class RunSummaryTests(unittest.TestCase):
    def test_hand_computed_run_variation(self):
        report = summarize_runs({"a": 0.01, "b": 0.03, "c": 0.05}, threshold=0.03)
        self.assertAlmostEqual(report["mean"], 0.03)
        self.assertAlmostEqual(report["standard_deviation"], 0.02)
        self.assertEqual((report["minimum"], report["maximum"]), (0.01, 0.05))
        self.assertEqual(report["runs_at_or_above_threshold"], 2)

    def test_interval_counts_use_lower_bounds(self):
        report = summarize_runs(
            {"a": estimate(0.05, 0.04, 0.06), "b": estimate(0.05, 0.01, 0.09)}, threshold=0.03
        )
        self.assertEqual(report["runs_with_interval_above_threshold"], 1)

    def test_single_run_has_no_spread(self):
        self.assertIsNone(summarize_runs({"a": 0.1})["standard_deviation"])


class CrossPlayTests(unittest.TestCase):
    def test_matrix_is_antisymmetric_around_one_half(self):
        policies = {name: FakePolicy(value) for name, value in (("a", 0.3), ("b", 0.1), ("c", 0.0))}
        matrix = cross_play(policies, SeedSchedule(DEVELOPMENT), 200, play=fake_play).score_matrix()
        self.assertTrue(np.isnan(np.diag(matrix)).all())
        off_diagonal = ~np.eye(3, dtype=bool)
        np.testing.assert_allclose((matrix + matrix.T)[off_diagonal], 1.0)
        self.assertGreater(matrix[0, 2], 0.5)

    def test_rock_paper_scissors_is_reported_once(self):
        beats = {("rock", "scissors"), ("scissors", "paper"), ("paper", "rock")}

        def play(first, second, games, seed):
            sign = 1 if (first, second) in beats else -1
            return {"outcome": np.full(games, float(sign > 0)), "difference": np.full(games, sign)}

        policies = {name: name for name in ("rock", "paper", "scissors")}
        result = cross_play(policies, SeedSchedule(DEVELOPMENT), 20, play=play)
        self.assertEqual(
            result.three_cycles(replicates=REPLICATES), [("paper", "rock", "scissors")]
        )

    def test_transitive_field_has_no_cycle(self):
        policies = {name: FakePolicy(value) for name, value in (("a", 0.4), ("b", 0.2), ("c", 0.0))}
        result = cross_play(policies, SeedSchedule(DEVELOPMENT), 300, play=fake_play)
        self.assertEqual(result.three_cycles(replicates=REPLICATES), [])

    def test_needs_two_policies(self):
        with self.assertRaises(ValueError):
            cross_play({"a": FakePolicy(0.0)}, SeedSchedule(DEVELOPMENT), 1, play=fake_play)


class ReportTests(unittest.TestCase):
    def test_json_report_omits_group_arrays_unless_requested(self):
        result = result_from([[1.0, 0.5], [0.0, 1.0]])
        report = json.loads(json.dumps(result.to_json(replicates=REPLICATES)))
        self.assertEqual(report["groups"], 2)
        self.assertNotIn("outcomes", report)
        self.assertNotIn("margins", report)
        expanded = json.loads(
            json.dumps(result.to_json(include_groups=True, replicates=REPLICATES))
        )
        self.assertEqual(expanded.pop("outcomes"), [[1.0, 0.5], [0.0, 1.0]])
        self.assertEqual(expanded.pop("margins"), [[1, 0], [-1, 1]])
        self.assertEqual(expanded, report)

    def test_cross_play_report_is_json_serializable(self):
        policies = {"a": FakePolicy(0.1), "b": FakePolicy(0.0)}
        result = cross_play(policies, SeedSchedule(DEVELOPMENT), 20, play=fake_play)
        report = json.loads(json.dumps(result.to_json(replicates=REPLICATES)))
        self.assertIsNone(report["score_matrix"][0][0])
        self.assertEqual(len(report["matchups"]), 1)


if __name__ == "__main__":
    unittest.main()
