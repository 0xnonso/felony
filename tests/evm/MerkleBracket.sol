// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

library MerkleBracket {
    uint256 internal constant SHUFFLE_DOMAIN = 505;
    uint256 internal constant SEED_DOMAIN = 512;
    uint256 internal constant LEAF_DOMAIN = 513;
    uint256 internal constant CONTEXT_DOMAIN = 515;
    uint256 internal constant PROOF_WORDS = 9;

    struct Tree {
        uint256 count;
        uint256 capacity;
        uint256 context;
        uint256[] leafSlots;
        uint256[] nodes;
    }

    function _word(address account) private pure returns (uint256) {
        return uint256(uint160(account));
    }

    uint256 internal constant DRAW_DOMAIN = 516;
    uint256 internal constant MATCH_SEED_DOMAIN = 517;
    uint256 internal constant FIELD = 21888242871839275222246405745257275088548364400416034343698204186575808495617;

    function seed(uint256 chainId, address controller, uint256 id, uint256 count, uint256 capacity, uint256 word)
        internal
        pure
        returns (uint256)
    {
        uint256[7] memory words = [SEED_DOMAIN, chainId, _word(controller), id, count, capacity, word];
        return uint256(keccak256(abi.encode(words)));
    }

    function drawContext(uint256 chainId, address controller, uint256 id, uint256 draw)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(DRAW_DOMAIN, chainId, _word(controller), id, draw));
    }

    function matchSeed(uint256 chainId, address controller, uint256 id, uint256 index, uint256 word)
        internal
        pure
        returns (uint256)
    {
        return uint256(keccak256(abi.encode(MATCH_SEED_DOMAIN, chainId, _word(controller), id, index, word))) % FIELD;
    }

    function context(
        uint256 chainId,
        address controller,
        uint256 id,
        uint256 bracketSeed,
        uint256 count,
        uint256 capacity
    ) internal pure returns (uint256) {
        uint256[7] memory words = [CONTEXT_DOMAIN, chainId, _word(controller), id, bracketSeed, count, capacity];
        return uint256(keccak256(abi.encode(words)));
    }

    function shuffledSlots(uint256 bracketSeed, uint256 count) internal pure returns (uint256[] memory order) {
        order = new uint256[](count);
        for (uint256 i; i < count; i++) {
            order[i] = i + 1;
        }
        for (uint256 size = count; size > 1; size--) {
            uint256 choice = uint256(keccak256(abi.encode(SHUFFLE_DOMAIN, bracketSeed, size))) % size;
            (order[size - 1], order[choice]) = (order[choice], order[size - 1]);
        }
    }

    function leafOrder(uint256 count, uint256 capacity, uint256 position) internal pure returns (uint256) {
        if (count == capacity) return position;
        return position % 2 == 0 ? position / 2 : capacity / 2 + position / 2;
    }

    function leafHash(uint256 treeContext, uint256 position, uint256 slot) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(LEAF_DOMAIN, treeContext, position, slot)));
    }

    function nodeHash(uint256 left, uint256 right) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(left, right)));
    }

    function build(
        uint256 chainId,
        address controller,
        uint256 id,
        uint256 bracketSeed,
        uint256 count,
        uint256 capacity
    ) internal pure returns (Tree memory tree) {
        tree.count = count;
        tree.capacity = capacity;
        tree.context = context(chainId, controller, id, bracketSeed, count, capacity);
        tree.leafSlots = new uint256[](capacity);
        tree.nodes = new uint256[](2 * capacity);
        _hashTree(tree, shuffledSlots(bracketSeed, count));
    }

    function _hashTree(Tree memory tree, uint256[] memory order) private pure {
        uint256 capacity = tree.capacity;
        for (uint256 position; position < capacity; position++) {
            uint256 ordered = leafOrder(tree.count, capacity, position);
            uint256 slot = ordered < tree.count ? order[ordered] : 0;
            tree.leafSlots[position] = slot;
            tree.nodes[capacity + position] = leafHash(tree.context, position, slot);
        }
        for (uint256 index = capacity - 1; index >= 1; index--) {
            tree.nodes[index] = nodeHash(tree.nodes[2 * index], tree.nodes[2 * index + 1]);
        }
    }

    function root(Tree memory tree) internal pure returns (uint256) {
        return tree.nodes[1];
    }

    function proof(Tree memory tree, uint256 index)
        internal
        pure
        returns (uint256 slot0, uint256 slot1, uint256[PROOF_WORDS] memory siblings)
    {
        uint256 pair = index - tree.capacity / 2;
        slot0 = tree.leafSlots[2 * pair];
        slot1 = tree.leafSlots[2 * pair + 1];
        uint256 level;
        for (uint256 node = index; node > 1; node /= 2) {
            siblings[level++] = tree.nodes[node ^ 1];
        }
    }

    function rootFromProof(
        uint256 treeContext,
        uint256 capacity,
        uint256 index,
        uint256 slot0,
        uint256 slot1,
        uint256[PROOF_WORDS] memory siblings
    ) internal pure returns (uint256 node) {
        uint256 position = 2 * (index - capacity / 2);
        node = nodeHash(leafHash(treeContext, position, slot0), leafHash(treeContext, position + 1, slot1));
        uint256 level;
        for (uint256 current = index; current > 1; current /= 2) {
            node = current % 2 == 0 ? nodeHash(node, siblings[level]) : nodeHash(siblings[level], node);
            level++;
        }
    }
}
