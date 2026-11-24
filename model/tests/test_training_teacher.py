import tempfile
import unittest

import numpy as np
import torch

from felony.actor import Actor
from felony.fixtures import legal_states
from felony.training import Config, Trainer


class TrainingTeacherTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        torch.set_num_threads(1)

    def test_surrogate_changes_gradient_not_deployed_probabilities(self):
        states = legal_states(87)
        x = torch.tensor([s.features() for s in states])
        m = x[:, :9] > 0
        a = Actor(123, 4)
        b = Actor(123, 32)
        pa, ta = a(x, m)
        pb, tb = b(x, m)
        torch.testing.assert_close(pa, pb, rtol=0, atol=0)
        self.assertEqual(a.export(), b.export())
        pa[:, 2].sum().backward()
        pb[:, 2].sum().backward()
        self.assertFalse(torch.allclose(a.biases[-1].grad, b.biases[-1].grad))

    def test_hard_sampling_favours_losses_with_nonzero_floor(self):
        t = Trainer(Config(opponent_sampling="hard"))
        t.opponent_scores = {"population_0": 0.95, "population_1": 0.1}
        p = t.opponent_probabilities(2)
        self.assertAlmostEqual(p.sum(), 1)
        self.assertGreater(p[1], p[0])
        self.assertGreaterEqual(p.min(), 0.1)

    def test_all_won_opponents_still_form_distribution(self):
        t = Trainer(Config(opponent_sampling="hard"))
        t.opponent_scores = {"a": 1.0, "b": 1.0}
        np.testing.assert_equal(t.opponent_probabilities(2, ["a", "b"]), [0.5, 0.5])

    def test_teacher_validation_and_resume_all_training_state(self):
        states = legal_states(83)
        x = np.array([s.features() for s in states])
        m = x[:, :9] > 0
        p = m / m.sum(1, keepdims=True)
        t = Trainer(
            Config(
                seed=8,
                batch_games=8,
                snapshot_interval=1,
                surrogate_beta=32,
                opponent_sampling="hard",
                teacher_coefficient=0.2,
                teacher_batch=4,
            )
        )
        with self.assertRaises(ValueError):
            t.set_teacher(x, m, p * 0)
        t.set_teacher(x, m, p)
        t.update()
        with tempfile.TemporaryDirectory() as d:
            t.save(d)
            r = Trainer.load(d)
            t.update()
            r.update()
            self.assertEqual(t.actor.export(), r.actor.export())
            self.assertEqual(t.opponent_scores, r.opponent_scores)
            self.assertEqual(r.actor.surrogate_beta, 32)
            self.assertEqual(r.teacher_examples, 16)
            self.assertEqual(t.logs[-1]["teacher_loss"], r.logs[-1]["teacher_loss"])

    def test_teacher_moves_predictions_towards_mixed_targets(self):
        a = Actor(4)
        x = torch.zeros((1, 55), dtype=torch.int64)
        m = torch.ones((1, 9), dtype=torch.bool)
        target = torch.tensor([[0.5, 0.5, 0, 0, 0, 0, 0, 0, 0]], dtype=torch.float64)
        opt = torch.optim.Adam(a.parameters(), lr=0.001)
        before = float((a(x, m)[0] - target).square().sum().detach())
        for _ in range(20):
            p, _ = a(x, m)
            loss = (p - target).square().sum()
            opt.zero_grad()
            loss.backward()
            opt.step()
            a.project()
        self.assertLess(float((a(x, m)[0] - target).square().sum().detach()), before)


if __name__ == "__main__":
    unittest.main()
