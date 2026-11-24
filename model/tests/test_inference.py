from dataclasses import replace
import unittest

from felony.fixtures import legal_states, synthetic_model
from felony.inference import (
    BIAS_OFFSET,
    Context,
    Model,
    State,
    categorical,
    forward,
    infer,
    requantize,
    sampling_hash,
)


class StateTests(unittest.TestCase):
    def test_9000_independently_generated_states(self):
        for seed in range(1000):
            for round_index, state in enumerate(legal_states(seed)):
                self.assertEqual(State.unpack(state.pack()), state)
                self.assertEqual(state.round, round_index)
                features = state.features()
                self.assertEqual(len(features), 55)
                self.assertTrue(all(0 <= x <= 255 for i, x in enumerate(features) if i != 36))
                self.assertTrue(-255 <= features[36] <= 255)

    def test_hand_computed_features(self):
        state = State(509, 510, 510, 5, 1, (2, 0, 0, 0, 0, 0, 0, 0, 0), (1, 0, 0, 0, 0, 0, 0, 0, 0))
        x = state.features()
        self.assertEqual(x[:3], [255, 0, 255])
        self.assertEqual(x[9:12], [0, 255, 255])
        self.assertEqual(x[18:21], [0, 255, 255])
        self.assertEqual(x[27:36], [0, 0, 0, 0, 255, 0, 0, 0, 0])
        self.assertEqual((x[36], x[37], x[46]), (6, 57, 28))
        opposite = replace(
            state,
            own_hand=510,
            opponent_hand=509,
            difference=-1,
            own_history=state.opponent_history,
            opponent_history=state.own_history,
        )
        self.assertEqual(opposite.features()[36], -6)

    def test_malformed_states(self):
        original = legal_states()[3]
        mutations = [
            replace(original, difference=original.difference + 1),
            replace(original, current=0),
            replace(original, own_hand=0),
            replace(original, own_hand=511),
            replace(original, own_history=(10,) * 9),
            replace(original, own_history=(0,) * 9),
        ]
        for state in mutations:
            with self.assertRaises(ValueError):
                state.pack()
        with self.assertRaises(ValueError):
            State.unpack(original.pack() | (1 << 110))


class NetworkTests(unittest.TestCase):
    def test_rounding_and_saturation_boundaries(self):
        for value, expected in (
            (-1, 0),
            (0, 0),
            (127, 0),
            (128, 1),
            (383, 1),
            (384, 2),
            (65151, 254),
            (65152, 255),
            (1000000, 255),
        ):
            self.assertEqual(requantize(value, 255), expected)
        self.assertEqual(requantize(16777088, 65535), 65535)
        for value in (-(1 << 40) - 1, 1 << 40):
            with self.assertRaises(ValueError):
                requantize(value, 255)

    def test_sparse_network_manual_calculation(self):
        model = synthetic_model(mode="zero")
        w, b = list(model.w), list(model.b)

        w[0], b[0] = 129, BIAS_OFFSET + 129
        w[7040], b[128] = 255, BIAS_OFFSET + 130
        w[23424], b[256] = 255, BIAS_OFFSET + 130
        trace = forward(Model(tuple(w), tuple(b)), legal_states()[0])
        self.assertEqual(
            (trace["z1"][0], trace["h1"][0], trace["z2"][0], trace["h2"][0], trace["z3"][0]),
            (384, 2, 384, 2, 384),
        )
        self.assertEqual(trace["tickets"], [2] + [0] * 8)

    def test_zero_fallback_and_parameter_extremes(self):
        state = legal_states()[3]
        lowest = (state.own_hand & -state.own_hand).bit_length() - 1
        for mode in ("zero", "minimum"):
            trace = forward(synthetic_model(mode=mode), state)
            self.assertEqual(trace["tickets"], [int(i == lowest) for i in range(9)])
        trace = forward(synthetic_model(mode="maximum"), state)
        self.assertEqual(trace["h1"], [255] * 128)
        self.assertEqual(trace["raw_tickets"], [65535] * 9)

    def test_weight_packing_and_mutation_binding(self):
        model = synthetic_model()
        packed = model.packed_weights()
        self.assertEqual(len(packed), 793)
        restored = b"".join(p.to_bytes(31, "little") for p in packed)
        self.assertEqual(restored[: len(model.w)], bytes(model.w))
        self.assertEqual(restored[len(model.w) :], b"\x00" * (len(restored) - len(model.w)))
        commitment = model.commitment(1, 2)
        w = list(model.w)
        w[-1] ^= 1
        self.assertNotEqual(Model(tuple(w), model.b).commitment(1, 2), commitment)
        b = list(model.b)
        b[-1] ^= 1
        self.assertNotEqual(Model(model.w, tuple(b)).commitment(1, 2), commitment)
        self.assertNotEqual(model.commitment(2, 2), commitment)
        self.assertNotEqual(model.commitment(1, 3), commitment)
        with self.assertRaises(ValueError):
            model.commitment(0, 2)

    def test_parameter_ranges(self):
        model = synthetic_model(mode="zero")
        for bad in (-1, 256):
            with self.assertRaises(ValueError):
                Model((bad,) + model.w[1:], model.b)
        with self.assertRaises(ValueError):
            Model(model.w, ((1 << 32),) + model.b[1:])


class SamplingTests(unittest.TestCase):
    def test_every_cdf_boundary(self):
        tickets = [0, 10, 0, 0, 60, 0, 0, 30, 0]
        for r in range(100):
            expected = 1 if r < 10 else 4 if r < 70 else 7
            self.assertEqual(categorical(tickets, r), (expected, r, 100))
        self.assertEqual(categorical(tickets, (1 << 64) - 1), (4, 15, 100))
        with self.assertRaises(ValueError):
            categorical([0] * 9, 3)

    def test_context_hash_binds_each_field(self):
        ctx = Context(31337, 123, 42, 0, 3, 456)
        expected = sampling_hash(12345, ctx)
        for name in ("chain_id", "contract_address", "match_id", "player_id", "round", "seed"):
            changed = replace(ctx, **{name: getattr(ctx, name) + 1})
            self.assertNotEqual(sampling_hash(12345, changed), expected)
        self.assertNotEqual(sampling_hash(12346, ctx), expected)

    def test_full_inference_determinism_and_legality(self):
        model = synthetic_model()
        for state in legal_states():
            ctx = Context(31337, 123, 42, 0, state.round, 456)
            result = infer(model, state, ctx, 12345, 9876)
            self.assertEqual(result, infer(model, state, ctx, 12345, 9876))
            self.assertTrue(state.own_hand & (1 << result["action"]))
            self.assertGreater(result["tickets"][result["action"]], 0)
        with self.assertRaises(ValueError):
            infer(model, legal_states()[0], ctx, 12345, 9876)


if __name__ == "__main__":
    unittest.main()
