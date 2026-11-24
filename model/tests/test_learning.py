import unittest
import numpy as np
import torch
from felony.actor import Actor
from felony.fixtures import synthetic_model, legal_states
from felony.inference import State, forward, categorical
from felony.simulator import BatchGame, Heuristic, play, sample_tickets


def bits(row):
    return sum(int(v) << k for k, v in enumerate(row))


class LearningTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        torch.set_num_threads(1)

    def test_simulator_matches_reference_states(self):
        game = BatchGame(32, 991)
        for r in range(9):
            for seat in (0, 1):
                features, mask = game.observation(seat)
                for j in range(32):
                    s = State(
                        bits(game.hands[seat, j]),
                        bits(game.hands[1 - seat, j]),
                        bits(game.loot[j]),
                        int(game.order[j, r]) + 1,
                        int(game.difference[j]) * (1 if seat == 0 else -1),
                        tuple(map(int, game.history[seat, j])),
                        tuple(map(int, game.history[1 - seat, j])),
                    )
                    s.validate()
                    self.assertEqual(s.features(), features[j].tolist())
                    np.testing.assert_equal(mask[j], game.hands[seat, j])
            a = sample_tickets(game.hands[0], game.rngs[0])
            b = sample_tickets(game.hands[1], game.rngs[1])
            game.step(a, b)
        expected = sum(
            (prize + 1) * np.sign(game.history[0, :, prize] - game.history[1, :, prize])
            for prize in range(9)
        )
        np.testing.assert_array_equal(game.result()["difference"], expected)
        with self.assertRaises(ValueError):
            game.observation(0)

    def test_tournament_tiebreak_and_pvp_refund_on_legal_games(self):
        cases = [
            ([2, 9, 7, 3, 6, 4, 5, 1, 8], [2, 1, 9, 5, 4, 3, 6, 8, 7], 22, 1),
            ([6, 3, 5, 2, 1, 4, 8, 7, 9], [8, 7, 2, 4, 3, 5, 6, 1, 9], 18, 1),
            ([4, 1, 7, 6, 2, 5, 8, 3, 9], [7, 6, 1, 4, 5, 8, 2, 3, 9], 14, 1),
            (list(range(1, 10)), list(range(1, 10)), 0, 0.5),
        ]
        for a, b, score, winner in cases:
            for swapped in (False, True):
                game = BatchGame(16, 123)
                bids = [np.array(x) for x in ((b, a) if swapped else (a, b))]
                for r in range(9):
                    prize = game.order[:, r]
                    game.step(bids[0][prize] - 1, bids[1][prize] - 1)
                for seat in (0, 1):
                    captured = game.history[seat] > game.history[1 - seat]
                    np.testing.assert_array_equal((captured * np.arange(1, 10)).sum(1), score)
                np.testing.assert_array_equal(game.result()["outcome"], 0.5)
                tournament = game.result("tournament")
                np.testing.assert_array_equal(
                    tournament["outcome"], 1 - winner if swapped else winner
                )
                np.testing.assert_array_equal(tournament["difference"], 0)

        game = BatchGame(1, 4)
        a, b = np.arange(1, 10), np.array([2, 3, 4, 5, 6, 7, 8, 9, 1])
        for r in range(9):
            prize = game.order[:, r]
            game.step(a[prize] - 1, b[prize] - 1)
        self.assertEqual(game.result("tournament")["outcome"].item(), 0)
        self.assertEqual(game.result("tournament")["difference"].item(), -27)

    def test_simultaneous_observation_and_illegal_bid(self):
        seen = []

        def spy(x, mask, rng):
            current = x[:, 27:36].argmax(1)
            self.assertTrue((x[np.arange(len(x)), 37 + current] == 0).all())
            self.assertTrue((x[np.arange(len(x)), 46 + current] == 0).all())
            seen.append(x.copy())
            return Heuristic("match")(x, mask, rng)

        result = play(spy, spy, 10, 7)
        np.testing.assert_equal(result["outcome"], 0.5)
        self.assertEqual(len(seen), 18)

    def test_invalid_bid_leaves_both_seats_unchanged_and_can_be_retried(self):
        bad_actions = [
            np.array([0, 1]),
            np.array([-1, 1]),
            np.array([9, 1]),
            np.array([1.0, 2.0]),
            np.array([True, False]),
            np.array([1]),
        ]
        for seat in (0, 1):
            for bad in bad_actions:
                with self.subTest(seat=seat, action=bad):
                    game = BatchGame(2, 5)
                    game.step(np.array([0, 0]), np.array([0, 0]))
                    before = [game.observation(s) for s in (0, 1)]
                    actions = [np.array([1, 1]), np.array([1, 1])]
                    actions[seat] = bad
                    with self.assertRaisesRegex(ValueError, "invalid action|illegal action"):
                        game.step(*actions)
                    self.assertEqual(game.round, 1)
                    for s in (0, 1):
                        for actual, expected in zip(game.observation(s), before[s]):
                            np.testing.assert_array_equal(actual, expected)
                    game.step(np.array([1, 1]), np.array([1, 1]))
                    self.assertEqual(game.round, 2)

    def test_exact_actor_intermediates_and_extreme_encodings(self):
        states = legal_states(843)
        x = torch.tensor([s.features() for s in states])
        mask = x[:, :9] > 0
        for model in [
            synthetic_model(7),
            synthetic_model(mode="maximum"),
            synthetic_model(mode="minimum"),
            Actor(7).export(),
        ]:
            actor = Actor.from_model(model)
            self.assertEqual(actor.export(), model)
            with torch.no_grad():
                prob, trace = actor(x, mask)
            for j, s in enumerate(states):
                expected = forward(model, s)
                for name in ("z1", "z2", "z3", "h1", "h2", "raw_tickets", "tickets"):
                    self.assertEqual(trace[name][j].tolist(), expected[name], name)
                np.testing.assert_allclose(
                    prob[j],
                    np.array(expected["tickets"]) / sum(expected["tickets"]),
                    rtol=0,
                    atol=0,
                )

    def test_uint64_sampler_uses_integer_remainder(self):
        tickets = np.tile([0, 3, 2, 0, 0, 4, 0, 1, 0], (100, 1))
        expected_rng = np.random.default_rng(771)
        draws = expected_rng.bit_generator.random_raw(100)
        expected = np.array(
            [categorical(row.tolist(), int(r))[0] for row, r in zip(tickets, draws)]
        )
        np.testing.assert_equal(sample_tickets(tickets, np.random.default_rng(771)), expected)

    def test_backward_can_recover_a_zero_head_without_changing_forward(self):
        actor = Actor(4)
        with torch.no_grad():
            actor.biases[-1].fill_(-0.5)
        x = torch.zeros((1, 55), dtype=torch.int64)
        legal = torch.ones((1, 9), dtype=torch.bool)
        probabilities, trace = actor(x, legal)
        self.assertTrue(trace["fallback"].item())
        self.assertEqual(
            probabilities.detach().tolist(), [[1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]]
        )
        entropy = -(probabilities * probabilities.clamp(min=1e-12).log()).sum()
        (-entropy).backward()
        self.assertGreater(float(actor.biases[-1].grad.abs().sum()), 0)

    def test_all_heuristics_finish_and_rng_repeats(self):
        for name in ("uniform", "match", "shift", "sandbag", "mixed", "cyclic"):
            a = play(Heuristic(name), Heuristic("mixed"), 32, 734)
            b = play(Heuristic(name), Heuristic("mixed"), 32, 734)
            np.testing.assert_equal(a["outcome"], b["outcome"])
            self.assertTrue(np.isin(a["outcome"], [0, 0.5, 1]).all())


if __name__ == "__main__":
    unittest.main()
