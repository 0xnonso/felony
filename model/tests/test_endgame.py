from fractions import Fraction as F
import itertools
import random
import unittest

import numpy as np

from felony.endgame import (
    EndgameState,
    MAX_SCORE_DIFFERENCE,
    SCORE_FROM_FEATURE,
    decode_features,
    position_value,
    solve_endgame,
    solve_matrix,
    teacher_targets,
)
from felony.fixtures import legal_states


def mask(*cards):
    return sum(1 << (card - 1) for card in cards)


def cards_of(value):
    return [card for card in range(1, 10) if value >> (card - 1) & 1]


def terminal(difference):
    return F(1) if difference > 0 else F(1, 2) if difference == 0 else F(0)


def analytic_2x2(a, b, c, d):
    lower = max(min(a, b), min(c, d))
    upper = min(max(a, c), max(b, d))
    if lower == upper:
        return lower
    return (a * d - b * c) / (a + d - b - c)


def independent_value(own, opponent, loot, difference):
    prizes = cards_of(loot)
    if not prizes:
        return terminal(difference)
    total = F(0)
    for prize in prizes:
        cells = []
        for a in cards_of(own):
            for b in cards_of(opponent):
                sign = (a > b) - (a < b)
                cells.append(
                    independent_value(
                        own - mask(a),
                        opponent - mask(b),
                        loot - mask(prize),
                        difference + sign * prize,
                    )
                )
        total += cells[0] if len(cells) == 1 else analytic_2x2(*cells)
    return total / len(prizes)


def random_state(rng, cards):
    def deal():
        return rng.sample(range(1, 10), cards)

    loot = deal()
    return EndgameState(
        mask(*deal()), mask(*deal()), mask(*loot), rng.choice(loot), rng.randint(-12, 12)
    )


def assert_certificate(test, solution):
    own = [solution.own_policy[card - 1] for card in solution.own_cards]
    opponent = [solution.opponent_policy[card - 1] for card in solution.opponent_cards]
    test.assertEqual(sum(own), 1)
    test.assertEqual(sum(opponent), 1)
    test.assertTrue(all(p >= 0 for p in own + opponent))
    for j in range(len(opponent)):
        test.assertGreaterEqual(
            sum(p * row[j] for p, row in zip(own, solution.payoff)), solution.value
        )
    for row in solution.payoff:
        test.assertLessEqual(sum(q * cell for q, cell in zip(opponent, row)), solution.value)
    test.assertEqual(solution.duality_gap, 0)
    for policy, cards in (
        (solution.own_policy, solution.own_cards),
        (solution.opponent_policy, solution.opponent_cards),
    ):
        test.assertTrue(all(p == 0 for card, p in enumerate(policy, 1) if card not in cards))


class MatrixTests(unittest.TestCase):
    def test_matching_pennies(self):
        solution = solve_matrix([[1, 0], [0, 1]])
        self.assertEqual(solution.value, F(1, 2))
        self.assertEqual(solution.row, (F(1, 2), F(1, 2)))
        self.assertEqual(solution.column, (F(1, 2), F(1, 2)))

    def test_rock_paper_scissors(self):
        solution = solve_matrix([[0, -1, 1], [1, 0, -1], [-1, 1, 0]])
        self.assertEqual(solution.value, 0)
        self.assertEqual(solution.row, (F(1, 3),) * 3)
        self.assertEqual(solution.column, (F(1, 3),) * 3)

    def test_unbalanced_mixed_game(self):
        solution = solve_matrix([[3, 0], [1, 2]])
        self.assertEqual(solution.value, F(3, 2))
        self.assertEqual(solution.row, (F(1, 4), F(3, 4)))
        self.assertEqual(solution.column, (F(1, 2), F(1, 2)))

    def test_saddle_point(self):
        solution = solve_matrix([[4, 2], [1, 0]])
        self.assertEqual((solution.value, solution.row, solution.column), (2, (1, 0), (0, 1)))

    def test_rectangular_game(self):
        solution = solve_matrix([[1, 0, 2], [0, 1, 2]])
        self.assertEqual(solution.value, F(1, 2))
        self.assertEqual(solution.column, (F(1, 2), F(1, 2), 0))

    def test_equal_rows_average_the_optimal_set(self):
        solution = solve_matrix([[1, 0], [1, 0]])
        self.assertEqual(solution.value, 0)
        self.assertEqual(solution.row, (F(1, 2), F(1, 2)))
        self.assertEqual(solution.column, (0, 1))

    def test_constant_game(self):
        solution = solve_matrix([[F(1, 2)] * 3] * 3)
        self.assertEqual(solution.value, F(1, 2))
        self.assertEqual(solution.row, (F(1, 3),) * 3)

    def test_random_games_match_the_analytic_formula(self):
        rng = random.Random(5)
        for _ in range(300):
            cells = [F(rng.randint(-6, 6), rng.randint(1, 4)) for _ in range(4)]
            solution = solve_matrix([cells[:2], cells[2:]])
            self.assertEqual(solution.value, analytic_2x2(*cells))
            self.assertEqual(solution.duality_gap, 0)

    def test_random_three_by_three_certificates(self):
        rng = random.Random(6)
        for _ in range(100):
            matrix = [[F(rng.randint(-4, 4)) for _ in range(3)] for _ in range(3)]
            solution = solve_matrix(matrix)
            for j in range(3):
                self.assertGreaterEqual(
                    sum(p * row[j] for p, row in zip(solution.row, matrix)), solution.value
                )
            for row in matrix:
                self.assertLessEqual(
                    sum(q * c for q, c in zip(solution.column, row)), solution.value
                )

    def test_invalid_matrices_are_rejected(self):
        for matrix in ([], [[]], [[1, 2], [3]], [[0] * 5]):
            with self.assertRaises(ValueError):
                solve_matrix(matrix)
        with self.assertRaises(TypeError):
            solve_matrix([[0.5]])


class StateTests(unittest.TestCase):
    def test_invalid_states_are_rejected(self):
        for arguments in (
            (0, 1, 1, 1, 0),
            (1, 1, 512, 1, 0),
            (mask(1, 2), 1, 1, 1, 0),
            (1, mask(1, 2), 1, 1, 0),
            (1, 1, 1, 2, 0),
            (1, 1, 1, 0, 0),
        ):
            with self.assertRaises(ValueError):
                EndgameState(*arguments)
        with self.assertRaises(TypeError):
            EndgameState(1, 1, 1, 1, 0.0)  # pyright: ignore[reportArgumentType] -- test rejects a float

    def test_four_cards_are_outside_the_teacher(self):
        four = mask(1, 2, 3, 4)
        with self.assertRaises(ValueError):
            solve_endgame(EndgameState(four, four, four, 1, 0))
        with self.assertRaises(ValueError):
            position_value(four, four, four, 0)


class EndgameTests(unittest.TestCase):
    def test_forced_last_card_scores_by_final_difference(self):
        for difference, expected in ((-8, 0), (-7, F(1, 2)), (-6, 1)):
            solution = solve_endgame(EndgameState(mask(5), mask(3), mask(7), 7, difference))
            self.assertEqual(solution.value, expected)
            self.assertEqual(solution.own_policy[4], 1)
            self.assertEqual(solution.opponent_policy[2], 1)

    def test_last_card_tie_burns_the_prize(self):
        for difference, expected in ((-1, 0), (0, F(1, 2)), (1, 1)):
            state = EndgameState(mask(4), mask(4), mask(9), 9, difference)
            self.assertEqual(solve_endgame(state).value, expected)

    def test_hand_computed_mixed_position(self):
        solution = solve_endgame(EndgameState(mask(1, 3), mask(2, 4), mask(1, 2), 1, 1))
        self.assertEqual(solution.payoff, ((0, 1), (F(1, 2), 0)))
        self.assertEqual(solution.value, F(1, 3))
        self.assertEqual((solution.own_policy[0], solution.own_policy[2]), (F(1, 3), F(2, 3)))
        self.assertEqual(
            (solution.opponent_policy[1], solution.opponent_policy[3]), (F(2, 3), F(1, 3))
        )
        assert_certificate(self, solution)

    def test_future_prize_is_averaged_uniformly(self):
        self.assertEqual(
            solve_endgame(EndgameState(mask(1, 3), mask(2, 4), mask(1, 2), 2, 1)).value, F(1, 3)
        )
        self.assertEqual(position_value(mask(1, 3), mask(2, 4), mask(1, 2), 1), F(1, 3))

    def test_known_pure_choice(self):
        solution = solve_endgame(EndgameState(mask(1, 9), mask(2, 3), mask(4, 6), 6, 0))
        self.assertEqual(solution.value, 1)
        self.assertEqual(solution.own_policy[8], 1)

    def test_negative_score_changes_the_decision_value(self):
        state = EndgameState(mask(1, 9), mask(2, 3), mask(4, 6), 6, -2)
        self.assertEqual(solve_endgame(state).value, F(1, 2))
        self.assertEqual(
            solve_endgame(EndgameState(mask(1, 9), mask(2, 3), mask(4, 6), 6, -3)).value, 0
        )

    def test_identical_hands_level_score_are_even(self):
        rng = random.Random(1)
        for cards in (1, 2, 3):
            for _ in range(20):
                hand = mask(*rng.sample(range(1, 10), cards))
                loot = rng.sample(range(1, 10), cards)
                state = EndgameState(hand, hand, mask(*loot), rng.choice(loot), 0)
                self.assertEqual(solve_endgame(state).value, F(1, 2))

    def test_seat_swap_mirrors_value_and_policies(self):
        rng = random.Random(2)
        for cards in (1, 2, 3):
            for _ in range(30):
                state = random_state(rng, cards)
                solution = solve_endgame(state)
                swapped = solve_endgame(state.swapped())
                self.assertEqual(solution.value + swapped.value, 1)
                self.assertEqual(solution.own_policy, swapped.opponent_policy)
                self.assertEqual(solution.opponent_policy, swapped.own_policy)

    def test_certificates_hold_on_random_positions(self):
        rng = random.Random(3)
        for cards in (1, 2, 3):
            for _ in range(40):
                solution = solve_endgame(random_state(rng, cards))
                assert_certificate(self, solution)
                self.assertTrue(0 <= solution.value <= 1)
                self.assertLess(solution.float_residual(), 1e-12)

    def test_two_card_values_match_an_independent_recursion(self):
        rng = random.Random(7)
        for _ in range(200):
            state = random_state(rng, 2)
            self.assertEqual(
                position_value(state.own_hand, state.opponent_hand, state.loot, state.difference),
                independent_value(
                    state.own_hand, state.opponent_hand, state.loot, state.difference
                ),
            )

    def test_three_card_payoffs_expand_the_game_rules(self):
        rng = random.Random(8)
        for _ in range(20):
            state = random_state(rng, 3)
            solution = solve_endgame(state)
            rest = state.loot - mask(state.current)
            for (i, a), (j, b) in itertools.product(
                enumerate(solution.own_cards), enumerate(solution.opponent_cards)
            ):
                sign = (a > b) - (a < b)
                total = F(0)
                for prize in cards_of(rest):
                    total += solve_endgame(
                        EndgameState(
                            state.own_hand - mask(a),
                            state.opponent_hand - mask(b),
                            rest,
                            prize,
                            state.difference + sign * state.current,
                        )
                    ).value
                self.assertEqual(solution.payoff[i][j], total / 2)


class FeatureTests(unittest.TestCase):
    def test_score_encoding_is_injective(self):
        self.assertEqual(len(SCORE_FROM_FEATURE), 2 * MAX_SCORE_DIFFERENCE + 1)
        self.assertEqual(SCORE_FROM_FEATURE[0], 0)
        self.assertEqual(SCORE_FROM_FEATURE[6], 1)
        self.assertEqual(SCORE_FROM_FEATURE[-23], -4)
        self.assertEqual(SCORE_FROM_FEATURE[255], 45)
        self.assertEqual(SCORE_FROM_FEATURE[-255], -45)

    def test_decoding_matches_the_reference_features(self):
        for seed in range(30):
            for state in legal_states(seed):
                decoded = decode_features(np.array(state.features(), dtype=np.int64))
                self.assertEqual(
                    (
                        decoded.own_hand,
                        decoded.opponent_hand,
                        decoded.loot,
                        decoded.current,
                        decoded.difference,
                    ),
                    (
                        state.own_hand,
                        state.opponent_hand,
                        state.loot,
                        state.current,
                        state.difference,
                    ),
                )

    def test_malformed_features_are_rejected(self):
        good = np.array(legal_states(1)[6].features(), dtype=np.int64)
        for index, value in ((0, 7), (27, 255), (36, 1)):
            bad = good.copy()
            if index == 27:
                bad[27:36] = 255
            else:
                bad[index] = value
            with self.assertRaises(ValueError):
                decode_features(bad)
        with self.assertRaises(ValueError):
            decode_features(good[:-1])
        with self.assertRaises(ValueError):
            decode_features(good.astype(float))

    def test_batch_targets_cover_only_the_endgame(self):
        states = legal_states(9)
        features = np.array([state.features() for state in states], dtype=np.int64)
        legal = np.array([[bool(s.own_hand >> i & 1) for i in range(9)] for s in states])
        targets = teacher_targets(features, legal)
        np.testing.assert_array_equal(targets["covered"], [False] * 6 + [True] * 3)
        self.assertTrue((targets["policy"][:6] == 0).all())
        np.testing.assert_allclose(targets["policy"][6:].sum(axis=1), 1.0)
        self.assertTrue((targets["policy"][~legal] == 0).all())
        self.assertLess(targets["residual"].max(), 1e-12)
        last = solve_endgame(decode_features(features[-1]))
        self.assertEqual(targets["value"][-1], float(last.value))

    def test_history_features_do_not_change_the_target(self):
        original = np.array(legal_states(10)[7].features(), dtype=np.int64)
        changed = original.copy()
        changed[37:55] = 0
        targets = teacher_targets(np.stack((original, changed)))
        self.assertTrue(targets["covered"].all())
        np.testing.assert_array_equal(targets["policy"][0], targets["policy"][1])

    def test_mismatched_legal_mask_is_rejected(self):
        state = legal_states(11)[8]
        features = np.array([state.features()], dtype=np.int64)
        with self.assertRaises(ValueError):
            teacher_targets(features, np.zeros((1, 9), dtype=bool))
        with self.assertRaises(ValueError):
            teacher_targets(features[0])


if __name__ == "__main__":
    unittest.main()
