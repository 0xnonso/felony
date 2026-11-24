import numpy as np


class BatchGame:
    def __init__(self, games, seed):
        if games < 1:
            raise ValueError("games must be positive")
        streams = np.random.SeedSequence(seed).spawn(3)
        env = np.random.default_rng(streams[0])
        self.rngs = [np.random.default_rng(s) for s in streams[1:]]
        self.order = np.argsort(env.random((games, 9)), axis=1)
        self.hands = np.ones((2, games, 9), dtype=bool)
        self.loot = np.ones((games, 9), dtype=bool)
        self.history = np.zeros((2, games, 9), dtype=np.int64)
        self.difference = np.zeros(games, dtype=np.int64)
        self.round = 0
        self.rows = np.arange(games)

    def observation(self, seat):
        if self.round >= 9 or seat not in (0, 1):
            raise ValueError("invalid observation")
        current = np.zeros_like(self.loot, dtype=np.int64)
        current[self.rows, self.order[:, self.round]] = 255
        diff = self.difference * (1 if seat == 0 else -1)
        score = np.sign(diff) * ((np.abs(diff) * 255 + 22) // 45)
        features = np.concatenate(
            (
                self.hands[seat] * 255,
                self.hands[1 - seat] * 255,
                self.loot * 255,
                current,
                score[:, None],
                (self.history[seat] * 255 + 4) // 9,
                (self.history[1 - seat] * 255 + 4) // 9,
            ),
            axis=1,
        ).astype(np.int64)
        return features, self.hands[seat].copy()

    def step(self, a, b):
        if self.round >= 9:
            raise ValueError("game finished")
        actions = [np.asarray(a), np.asarray(b)]
        for seat, action in enumerate(actions):
            if action.shape != self.rows.shape or action.dtype.kind not in "iu":
                raise ValueError("invalid action shape/type")
            if np.any((action < 0) | (action > 8)) or not self.hands[seat, self.rows, action].all():
                raise ValueError("illegal action")
        prize = self.order[:, self.round]
        self.difference += (prize + 1) * (
            (actions[0] > actions[1]).astype(int) - (actions[0] < actions[1])
        )
        for seat, action in enumerate(actions):
            self.hands[seat, self.rows, action] = False
            self.history[seat, self.rows, prize] = action + 1
        self.loot[self.rows, prize] = False
        self.round += 1

    def result(self, scoring="pvp"):
        if self.round != 9:
            raise ValueError("unfinished game")
        if scoring not in ("pvp", "tournament"):
            raise ValueError("unknown scoring rule")
        winner = np.sign(self.difference)
        if scoring == "tournament":
            capture = np.zeros_like(winner)
            for prize in range(9):
                bids = np.sign(self.history[0, :, prize] - self.history[1, :, prize])
                capture = np.where(bids != 0, bids, capture)
            winner = np.where(winner == 0, capture, winner)

        return {"outcome": (winner + 1) / 2, "difference": self.difference.copy()}


def sample_tickets(tickets, rng):
    tickets = np.asarray(tickets, dtype=np.uint64)
    total = tickets.sum(axis=1)
    if (total == 0).any():
        raise ValueError("empty distribution")
    draw = rng.bit_generator.random_raw(len(total)) % total
    return (np.cumsum(tickets, axis=1) <= draw[:, None]).sum(axis=1).astype(np.int64)


def heuristic_tickets(name, features, legal):
    batch = len(features)
    if name == "uniform":
        return legal.astype(np.int64)
    loot = features[:, 18:27] > 0
    current = features[:, 27:36].argmax(axis=1)
    rank = (loot & (np.arange(9)[None, :] < current[:, None])).sum(axis=1)
    count = legal.sum(axis=1)
    cards = np.sort(np.where(legal, np.arange(9), 99), axis=1)
    if name == "match":
        chosen_rank = rank
    elif name == "shift":
        chosen_rank = np.minimum(rank + 1, count - 1)
    elif name == "cyclic":
        chosen_rank = (rank + 1) % count
    elif name == "sandbag":
        chosen_rank = np.where(
            rank >= count // 2,
            np.where(rank == count - 1, count - 1, np.minimum(count // 2 + (count > 2), count - 1)),
            0,
        )
    elif name == "mixed":
        return (
            heuristic_tickets("match", features, legal) * 3
            + heuristic_tickets("shift", features, legal) * 3
            + heuristic_tickets("sandbag", features, legal) * 2
            + legal
        )
    else:
        raise ValueError(f"unknown heuristic: {name}")
    out = np.zeros((batch, 9), dtype=np.int64)
    out[np.arange(batch), cards[np.arange(batch), chosen_rank]] = 1
    return out


class Heuristic:
    def __init__(self, name):
        self.name = name

    def __call__(self, features, legal, rng):
        return sample_tickets(heuristic_tickets(self.name, features, legal), rng)


def play(policy_a, policy_b, games, seed, record=False, scoring="pvp"):
    game = BatchGame(games, seed)
    trajectory = []
    for _ in range(9):
        xa, ma = game.observation(0)
        xb, mb = game.observation(1)
        a = policy_a(xa, ma, game.rngs[0])
        b = policy_b(xb, mb, game.rngs[1])
        if record:
            trajectory.append(
                {"features": (xa, xb), "legal": (ma, mb), "actions": (a.copy(), b.copy())}
            )
        game.step(a, b)
    result = game.result(scoring)
    if record:
        result["trajectory"] = trajectory
    return result
