"""Independent bracket reference for cross-language test vectors."""

from felony.keccak import keccak_words


def build_bracket(chain, controller, tournament, seed, count, capacity, hash_words=keccak_words):
    if capacity < 4 or capacity > 1024 or capacity & (capacity - 1):
        raise ValueError("capacity must be a power of two from 4 to 1024")
    if not 4 <= count <= capacity or (count < capacity and count <= capacity // 2):
        raise ValueError("capacity must be the smallest supported bracket for count")
    context = hash_words([515, chain, controller, tournament, seed, count, capacity])
    order = list(range(1, count + 1))
    for size in range(count, 1, -1):
        choice = hash_words([505, seed, size]) % size
        order[size - 1], order[choice] = order[choice], order[size - 1]
    slots = []
    for position in range(capacity):
        source = (
            position
            if count == capacity
            else (position // 2 if position % 2 == 0 else capacity // 2 + position // 2)
        )
        slots.append(order[source] if source < count else 0)
    levels = [[hash_words([513, context, i, slot]) for i, slot in enumerate(slots)]]
    while len(levels[-1]) > 1:
        current = levels[-1]
        levels.append([hash_words([current[i], current[i + 1]]) for i in range(0, len(current), 2)])
    return {"context": context, "root": levels[-1][0], "slots": slots, "levels": levels}


def pair_proof(bracket, index):
    capacity = len(bracket["slots"])
    if not capacity // 2 <= index < capacity:
        raise ValueError("index must identify a first-round match")
    position = 2 * (index - capacity // 2)
    cursor = position // 2
    siblings = []
    for level in bracket["levels"][1:-1]:
        siblings.append(level[cursor ^ 1])
        cursor //= 2
    siblings += [0] * (9 - len(siblings))
    return {
        "index": index,
        "slot0": bracket["slots"][position],
        "slot1": bracket["slots"][position + 1],
        "siblings": siblings,
    }
