import json
from pathlib import Path
import numpy as np
import torch
from torch import nn
from torch.nn import functional as F
from .inference import Model, BIAS_OFFSET
from .simulator import sample_tickets


def ste(value, rounded):
    return rounded.detach() + (value - value.detach())


class Actor(nn.Module):
    def __init__(self, seed=0, surrogate_beta=4.0):
        super().__init__()
        if not np.isfinite(surrogate_beta) or surrogate_beta <= 0:
            raise ValueError("surrogate_beta must be finite and positive")
        self.surrogate_beta = float(surrogate_beta)

        gen = torch.Generator().manual_seed(seed)
        self.weights = nn.ParameterList()
        self.biases = nn.ParameterList()
        for index, (ni, no) in enumerate(((55, 128), (128, 128), (128, 9))):
            scale = (2 / ni) ** 0.5 if index < 2 else 0.008
            self.weights.append(
                nn.Parameter(
                    (torch.randn(no, ni, generator=gen, dtype=torch.float64) * scale).clamp(
                        -0.5, 127 / 256
                    )
                )
            )
            self.biases.append(
                nn.Parameter(torch.full((no,), 0.0 if index < 2 else 0.35, dtype=torch.float64))
            )

    def forward(self, features, legal):
        x = features.to(dtype=torch.float64) / 256
        traces = {}
        for i, (w, b) in enumerate(zip(self.weights, self.biases)):
            qw = ste(w, torch.round(w * 256).clamp(-128, 127) / 256)
            qb = ste(b, torch.round(b * 65536).clamp(-(2**31), 2**31 - 1) / 65536)
            z = F.linear(x, qw, qb)
            maximum = 255 if i < 2 else 65535
            positive = z.clamp(min=0, max=maximum / 256)
            integer = torch.floor(positive * 256 + 0.5).clamp(max=maximum)
            x = ste(positive, integer / 256)
            traces[f"z{i + 1}"] = z * 65536
            traces[f"h{i + 1}"] = x * 256
        raw = x * 256
        tickets = raw * legal
        total = tickets.sum(dim=1, keepdim=True)
        fallback = total == 0
        first = F.one_hot(legal.to(torch.int64).argmax(dim=1), 9).to(torch.float64)
        tickets = torch.where(fallback, first, tickets)
        exact_probabilities = tickets / tickets.sum(dim=1, keepdim=True)

        smooth_mass = F.softplus(z, beta=self.surrogate_beta) * legal
        smooth_probabilities = smooth_mass / smooth_mass.sum(dim=1, keepdim=True).clamp(min=1e-300)
        probabilities = ste(smooth_probabilities, exact_probabilities)
        traces.update(
            raw_tickets=raw, tickets=tickets, fallback=fallback, probabilities=probabilities
        )
        return probabilities, traces

    @torch.no_grad()
    def project(self):
        for w, b in zip(self.weights, self.biases):
            w.clamp_(-128 / 256, 127 / 256)
            b.clamp_(-(2**31) / 65536, (2**31 - 1) / 65536)

    @torch.no_grad()
    def export(self):
        w = (
            torch.cat(
                [(torch.round(p * 256).clamp(-128, 127) + 128).flatten() for p in self.weights]
            )
            .to(torch.int64)
            .tolist()
        )
        b = (
            torch.cat(
                [
                    (torch.round(p * 65536).clamp(-(2**31), 2**31 - 1) + BIAS_OFFSET)
                    for p in self.biases
                ]
            )
            .to(torch.int64)
            .tolist()
        )
        return Model(tuple(w), tuple(b))

    @classmethod
    def from_model(cls, model):
        actor = cls()
        wo = bo = 0
        with torch.no_grad():
            for w, b in zip(actor.weights, actor.biases):
                n = w.numel()
                w.copy_(
                    (torch.tensor(model.w[wo : wo + n], dtype=torch.float64).reshape(w.shape) - 128)
                    / 256
                )
                b.copy_(
                    (torch.tensor(model.b[bo : bo + b.numel()], dtype=torch.float64) - BIAS_OFFSET)
                    / 65536
                )
                wo += n
                bo += b.numel()
        return actor

    @torch.no_grad()
    def __call_policy(self, features, legal, rng):
        _, trace = self(torch.as_tensor(features), torch.as_tensor(legal))
        return sample_tickets(trace["tickets"].numpy().astype(np.uint64), rng)

    def policy(self):
        return self.__call_policy

    def save_export(self, path):
        model = self.export()
        Path(path).write_text(
            json.dumps(
                {
                    "spec_version": 1,
                    "architecture": [55, 128, 128, 9],
                    "w": list(model.w),
                    "b": list(model.b),
                },
                separators=(",", ":"),
            )
            + "\n"
        )


def load_export(path):
    data = json.loads(Path(path).read_text())
    if data["spec_version"] != 1 or data["architecture"] != [55, 128, 128, 9]:
        raise ValueError("unsupported model format")
    return Actor.from_model(Model(tuple(data["w"]), tuple(data["b"])))
