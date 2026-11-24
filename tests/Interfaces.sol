// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IFelonyGame {
    function createChallenge(address opponent, uint256 commitment, uint256 stake, uint256 joinSeconds)
        external
        payable
        returns (uint256);
    function joinChallenge(uint256 id, uint256 commitment) external payable;
    function joinQueue(uint256 commitment, uint256 stake) external payable returns (uint256);
    function activateMatch(uint256 id) external;
    function randomnessRequest(uint256 id) external view returns (uint256);
    function queueHead(uint256 stake) external view returns (uint256);
    function settings() external view returns (uint256[5] memory);
    function reserveManagedMatches(uint256 tournament, uint256 count) external returns (uint256);
    function managedMatchId(address manager, uint256 tournament, uint256 index) external view returns (uint256);
    function createManagedMatch(
        address player0,
        address player1,
        uint256 commitment0,
        uint256 commitment1,
        uint256 tournament,
        uint256 seed,
        uint256 turnSeconds,
        uint256 index
    ) external returns (uint256);
    function managedInfo(uint256 id) external view returns (uint256[4] memory);
    function cancelChallenge(uint256 id) external;
    function submitMove(uint256 id, uint256 action, bytes calldata proof) external;
    function forfeit(uint256 id) external;
    function claimTimeout(uint256 id) external;
    function withdraw(address to) external;
    function creditOf(address player) external view returns (uint256);
    function busy(address player) external view returns (uint256);
    function burned() external view returns (uint256);
    function liabilities() external view returns (uint256);
    function matchInfo(uint256 id) external view returns (uint256[18] memory);
    function proofInputs(uint256 id, uint256 player, uint256 action) external view returns (uint256[9] memory);
}

interface ITournament {
    function createTournament(
        uint256 capacity,
        uint256 principal,
        uint256 entrySeconds,
        uint256 fundSeconds,
        uint256 windowSeconds,
        uint256 turnSeconds
    ) external returns (uint256);
    function join(uint256 id, uint256 commitment) external payable;
    function leave(uint256 id) external;
    function cancel(uint256 id) external;
    function start(uint256 id) external;
    function fund(uint256 id) external;
    function requestDraw(uint256 id) external payable;
    function beginRound(uint256 id) external;
    function abort(uint256 id) external;
    function openMatch(uint256 id, uint256 index, uint256 slot0, uint256 slot1, uint256[9] calldata siblings) external;
    function advance(uint256 id, uint256 index) external;
    function updateModel(uint256 id, uint256 commitment) external;
    function finalize(uint256 id) external;
    function claim(uint256 id) external;
    function claimFees(uint256 id) external;
    function withdraw(address to) external;
    function tournamentInfo(uint256 id) external view returns (uint256[18] memory);
    function roundInfo(uint256 id) external view returns (uint256[7] memory);
    function entryInfo(uint256 id, uint256 slot) external view returns (uint256[6] memory);
    function entitlement(uint256 id, uint256 slot) external view returns (uint256);
    function payoutInfo(uint256 id) external view returns (uint256[9] memory);
    function slotOf(uint256 id, address player) external view returns (uint256);
    function bracketRoot(uint256 id) external view returns (uint256);
    function bracketMatch(uint256 id, uint256 index) external view returns (uint256[4] memory);
    function drawWord(uint256 id, uint256 draw) external view returns (uint256);
    function creditOf(address player) external view returns (uint256);
    function accounting() external view returns (uint256[2] memory);
    function settings() external view returns (uint256[5] memory);
    function tournamentConfig(uint256 id) external view returns (uint256[5] memory);
}

interface RandomOracle {
    function quoteFee() external view returns (uint256);
    function requestRandomness(bytes32 context) external payable returns (uint256);
    function isReady(uint256 id) external view returns (bool);
    function getRandomness(uint256 id) external view returns (uint256);
    function status(uint256 id) external view returns (uint256);
    function rawFulfillRandomWords(uint256 id, uint256[] calldata words) external;
    function setConsumer(address consumer, bool allowed) external;
    function isConsumer(address consumer) external view returns (bool);
    function requestInfo(uint256 id) external view returns (uint256[3] memory);
    function settings() external view returns (uint256[9] memory);
    function fees() external view returns (uint256);
    function withdrawFees(address to) external;
}

interface IVaultToken {
    function balanceOf(address) external view returns (uint256);
    function allowance(address, address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}
