// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IFelonyGame} from "../Interfaces.sol";
import {BindingVerifierMock, RejectGamePayout, ReentrantGamePlayer, GameFeeReceiver} from "../mocks/GameMocks.sol";
import {RandomOracleMock} from "../mocks/RandomOracleMock.sol";

contract FelonyGameTest is Test {
    uint256 private constant FIELD = 21888242871839275222246405745257275088548364400416034343698204186575808495617;
    uint256 private constant STAKE = 1 ether;
    uint256 private constant DEPOSIT = STAKE;
    address private constant ALICE = address(0xa11ce);
    address private constant BOB = address(0xb0b);
    address private constant EVE = address(0xe1e);
    IFelonyGame private game;
    BindingVerifierMock private verifier;
    RandomOracleMock private oracle;
    GameFeeReceiver private collector;
    uint256 private constant WIN = 2 * STAKE - STAKE / 20;

    struct Board {
        uint256 h0;
        uint256 h1;
        uint256 loot;
        uint256 prize;
        uint256 s0;
        uint256 s1;
        uint256 hist0;
        uint256 hist1;
        uint256 round;
    }

    function setUp() public {
        vm.warp(1000);
        vm.roll(100);
        vm.deal(address(this), 100 ether);
        vm.deal(ALICE, 100 ether);
        vm.deal(BOB, 100 ether);
        vm.deal(EVE, 100 ether);
        verifier = new BindingVerifierMock();
        oracle = new RandomOracleMock();
        collector = new GameFeeReceiver();
        address deployed = _deployGame(address(verifier), address(collector));
        require(deployed != address(0) && deployed.code.length != 0, "Fe game deployment failed");
        game = IFelonyGame(deployed);
    }

    function _deployGame(address verifierAddress, address feeRecipient) private returns (address deployed) {
        bytes memory creation = abi.encodePacked(
            vm.readFileBinary("artifacts/game.bin"),
            abi.encode(verifierAddress, address(oracle), feeRecipient, uint256(60))
        );
        require(creation.length <= 49152, "game initcode exceeds EIP3860");
        assembly { deployed := create(0, add(creation, 32), mload(creation)) }
        require(deployed.code.length <= 24576, "game exceeds EIP170");
    }

    function testDeploymentAcceptsLargestSupportedChainIdAndRejectsInvalidDependencies() public {
        assertEq(_deployGame(address(0xdead), address(collector)), address(0), "empty verifier accepted");
        assertEq(_deployGame(address(verifier), address(0)), address(0), "zero fee recipient accepted");
        vm.chainId(type(uint64).max);
        address deployed = _deployGame(address(verifier), address(collector));
        assertTrue(deployed != address(0), "largest circuit chain ID rejected");
        game = IFelonyGame(deployed);
        uint256 id = _joined();
        _activate(id);
        assertEq(game.proofInputs(id, 0, 0)[2], type(uint64).max);
    }

    function testFeeRecipientWithoutCodeCanWithdrawOnlyItsFees() public {
        address deployed = _deployGame(address(verifier), EVE);
        assertTrue(deployed != address(0));
        game = IFelonyGame(deployed);
        uint256 id = _joined();
        vm.prank(BOB);
        game.forfeit(id);
        assertEq(game.creditOf(ALICE), WIN);
        assertEq(game.creditOf(EVE), STAKE / 20);
        assertEq(game.liabilities(), 2 * STAKE);
        uint256 before = EVE.balance;
        vm.prank(EVE);
        game.withdraw(EVE);
        assertEq(EVE.balance - before, STAKE / 20);
        assertEq(game.creditOf(EVE), 0);
        assertEq(game.creditOf(ALICE), WIN);
        assertEq(game.liabilities(), WIN);
        _reject(EVE, 0, abi.encodeCall(IFelonyGame.withdraw, (EVE)));
        vm.prank(ALICE);
        game.withdraw(ALICE);
        assertEq(game.liabilities(), 0);
        assertEq(address(game).balance, 0);
    }

    function _reject(address sender, uint256 value, bytes memory data) private {
        vm.prank(sender);
        (bool ok,) = address(game).call{value: value}(data);
        require(!ok, "invalid transition accepted");
    }

    function _reject(address sender, uint256 value, bytes memory data, string memory reason) private {
        vm.prank(sender);
        (bool ok, bytes memory result) = address(game).call{value: value}(data);
        require(!ok, "invalid transition accepted");
        assertEq(result, abi.encodeWithSignature("Error(string)", reason));
    }

    function _create(address opponent) private returns (uint256 id) {
        vm.prank(ALICE);
        id = game.createChallenge{value: DEPOSIT}(opponent, 111, STAKE, 60);
    }

    function _join(uint256 id) private {
        uint256 fee = oracle.quoteFee();
        vm.prank(BOB);
        game.joinChallenge{value: DEPOSIT + fee}(id, 222);
    }

    function _joined() private returns (uint256 id) {
        id = _create(BOB);
        _join(id);
        require(game.liabilities() == 2 * DEPOSIT, "joined liability");
    }

    function _activate(uint256 id) private returns (uint256 seed) {
        uint256 word = 10101 + id;
        oracle.fulfill(game.randomnessRequest(id), word);
        game.activateMatch(id);
        seed = uint256(keccak256(abi.encode(uint256(521), block.chainid, address(game), id, word))) % FIELD;
        uint256[18] memory info = game.matchInfo(id);
        require(info[6] == 3 && info[9] == seed && info[7] == block.timestamp + 60, "activation context");
    }

    function _prize(uint256 loot, uint256 seed, uint256 round) private pure returns (uint256) {
        uint256 count;
        for (uint256 c; c < 9; ++c) {
            if ((loot & (1 << c)) != 0) ++count;
        }
        uint256 n = uint256(keccak256(abi.encode(uint256(204), uint256(1), seed, round))) % count;
        for (uint256 c; c < 9; ++c) {
            if ((loot & (1 << c)) != 0) {
                if (n == 0) return c + 1;
                --n;
            }
        }
        revert("empty reference loot");
    }

    function _initial(uint256 seed) private pure returns (Board memory b) {
        b.h0 = 511;
        b.h1 = 511;
        b.loot = 511;
        b.prize = _prize(511, seed, 0);
    }

    function _packed(Board memory b, uint256 seat) private pure returns (uint256) {
        bool own = seat == 0;
        uint256 score = 45 + (own ? b.s0 : b.s1) - (own ? b.s1 : b.s0);
        return (own ? b.h0 : b.h1) | ((own ? b.h1 : b.h0) << 9) | (b.loot << 18) | (b.prize << 27) | (score << 31)
            | ((own ? b.hist0 : b.hist1) << 38) | ((own ? b.hist1 : b.hist0) << 74);
    }

    function _words(uint256 id, Board memory b, uint256 seed, uint256 seat, uint256 action)
        private
        view
        returns (uint256[9] memory)
    {
        return [
            seat == 0 ? uint256(111) : uint256(222),
            _packed(b, seat),
            block.chainid,
            uint256(uint160(address(game))),
            id,
            seat,
            b.round,
            seed,
            action
        ];
    }

    function _arm(uint256 id, Board memory b, uint256 seed, uint256 seat, uint256 action) private {
        uint256[9] memory expected = _words(id, b, seed, seat, action);
        require(
            keccak256(abi.encode(game.proofInputs(id, seat, action))) == keccak256(abi.encode(expected)),
            "proofInputs/reference mismatch"
        );
        verifier.configure(keccak256(abi.encode(expected)), 0);
    }

    function _submit(uint256 id, Board memory b, uint256 seed, uint256 seat, uint256 action) private {
        _arm(id, b, seed, seat, action);
        vm.prank(seat == 0 ? ALICE : BOB);
        game.submitMove(id, action, new bytes(9152));
    }

    function _resolve(Board memory b, uint256 a, uint256 c, uint256 seed) private pure {
        if (a > c) b.s0 += b.prize;
        if (c > a) b.s1 += b.prize;
        b.h0 ^= 1 << (a - 1);
        b.h1 ^= 1 << (c - 1);
        b.hist0 |= a << (4 * (b.prize - 1));
        b.hist1 |= c << (4 * (b.prize - 1));
        b.loot ^= 1 << (b.prize - 1);
        ++b.round;
        b.prize = b.round < 9 ? _prize(b.loot, seed, b.round) : 0;
    }

    function _credits(uint256 a, uint256 b, uint256 p) private view {
        require(game.creditOf(ALICE) == a && game.creditOf(BOB) == b && game.burned() == p, "settlement credits");
        require(game.creditOf(address(collector)) == ((a == WIN || b == WIN) ? STAKE / 20 : 0), "fee allocation");
        require(game.liabilities() == a + b + game.creditOf(address(collector)), "settlement liability conservation");
        require(address(game).balance >= game.liabilities() + game.burned(), "insolvent");
    }

    function _assertMoveEvent(uint256 id, uint256 round, uint256 seat, uint256 action) private view {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 2, "one accepted move followed by one state update");
        assertEq(logs[0].emitter, address(game));
        assertEq(logs[0].topics.length, 2);
        assertEq(logs[0].topics[0], keccak256("MoveAccepted(uint256,uint256,uint256,uint256)"));
        assertEq(logs[0].topics[1], bytes32(id));
        assertEq(logs[0].data, abi.encode(round, seat, action));
        assertEq(logs[1].topics[0], keccak256("GameChanged(uint256,uint256,uint256,uint256,uint256)"));
    }

    function testMoveAcceptedEventsKeepPreTransitionRoundAndExcludeForcedCards() public {
        uint256 id = _joined();
        uint256 seed = _activate(id);
        Board memory board = _initial(seed);
        for (uint256 round; round < 8; ++round) {
            uint256 firstSeat = round % 2;
            vm.recordLogs();
            _submit(id, board, seed, firstSeat, round);
            _assertMoveEvent(id, round, firstSeat, round);
            vm.recordLogs();
            _submit(id, board, seed, 1 - firstSeat, round);
            _assertMoveEvent(id, round, 1 - firstSeat, round);
            _resolve(board, round + 1, round + 1, seed);
        }
        assertEq(game.matchInfo(id)[6], 4, "game finished");
        assertEq(game.matchInfo(id)[10], 9, "forced final round resolved without extra move events");
    }

    function testRejectedProofsAndUsedCardsEmitNoMoveAccepted() public {
        uint256 id = _joined();
        uint256 seed = _activate(id);
        Board memory board = _initial(seed);
        for (uint256 mode = 1; mode <= 2; ++mode) {
            verifier.configure(keccak256(abi.encode(_words(id, board, seed, 0, 0))), mode);
            vm.recordLogs();
            _reject(ALICE, 0, abi.encodeCall(IFelonyGame.submitMove, (id, 0, new bytes(9152))));
            assertEq(vm.getRecordedLogs().length, 0, "rejected proof emitted an event");
            assertEq(game.matchInfo(id)[11], 0, "rejected proof changed submissions");
        }
        _submit(id, board, seed, 0, 0);
        _submit(id, board, seed, 1, 0);
        _resolve(board, 1, 1, seed);
        _arm(id, board, seed, 0, 0);
        vm.recordLogs();
        _reject(ALICE, 0, abi.encodeCall(IFelonyGame.submitMove, (id, 0, new bytes(9152))), "Card already used");
        assertEq(vm.getRecordedLogs().length, 0, "used card emitted an event");
        assertEq(game.matchInfo(id)[11], 0);
    }

    function testUnknownGameHasEmptyViewsAndRejectsTransitions() public {
        uint256 id = 123456;
        uint256[18] memory emptyInfo;
        uint256[4] memory emptyManaged;
        require(keccak256(abi.encode(game.matchInfo(id))) == keccak256(abi.encode(emptyInfo)), "unknown game");
        require(
            keccak256(abi.encode(game.managedInfo(id))) == keccak256(abi.encode(emptyManaged)), "unknown managed game"
        );
        _reject(ALICE, 0, abi.encodeCall(IFelonyGame.claimTimeout, (id)));
        _reject(ALICE, 0, abi.encodeCall(IFelonyGame.forfeit, (id)));
        _reject(ALICE, 0, abi.encodeCall(IFelonyGame.cancelChallenge, (id)));
    }

    function testExactPaymentsInvitationAuthorizationAndBusy() public {
        bytes memory create = abi.encodeCall(IFelonyGame.createChallenge, (BOB, 111, STAKE, 60));
        _reject(ALICE, DEPOSIT - 1, create, "Wrong payment");
        _reject(ALICE, DEPOSIT + 1, create);
        _reject(ALICE, DEPOSIT, abi.encodeCall(IFelonyGame.createChallenge, (ALICE, 111, STAKE, 60)));
        _reject(ALICE, DEPOSIT, abi.encodeCall(IFelonyGame.createChallenge, (address(0), 111, STAKE, 60)));
        uint256 id = _create(BOB);
        require(game.busy(ALICE) != 0 && game.busy(BOB) == 0, "invitation busy state");
        _reject(ALICE, DEPOSIT, create, "Player busy");
        bytes memory join = abi.encodeCall(IFelonyGame.joinChallenge, (id, 222));
        _reject(EVE, DEPOSIT, join);
        _reject(ALICE, DEPOSIT, join);
        _reject(BOB, DEPOSIT - 1, join);
        _reject(BOB, DEPOSIT + 1, join);
        vm.prank(BOB);
        game.joinChallenge{value: DEPOSIT}(id, 222);
        _reject(BOB, DEPOSIT, join);
        require(game.busy(BOB) != 0 && game.liabilities() == 2 * DEPOSIT, "joined escrow");
        _reject(ALICE, 0, abi.encodeCall(IFelonyGame.cancelChallenge, (id)));
    }

    function testBusyInviteeCannotAcceptUntilItsOwnInvitationCancelled() public {
        vm.prank(BOB);
        uint256 other = game.createChallenge{value: DEPOSIT}(EVE, 333, STAKE, 60);
        vm.warp(block.timestamp + 30);
        uint256 id = _create(BOB);
        _reject(BOB, DEPOSIT, abi.encodeCall(IFelonyGame.joinChallenge, (id, 222)));
        vm.prank(BOB);
        game.cancelChallenge(other);
        _join(id);
        require(game.creditOf(BOB) == DEPOSIT && game.liabilities() == 3 * DEPOSIT, "separate cancelled escrow");
    }

    function testStakeArithmeticBoundarySettlesAndWithdraws() public {
        uint256 stake = type(uint256).max / 2;
        vm.deal(ALICE, stake + 1);
        _reject(ALICE, stake + 1, abi.encodeCall(IFelonyGame.createChallenge, (BOB, 111, stake + 1, 60)));
        _reject(ALICE, stake + 1, abi.encodeCall(IFelonyGame.joinQueue, (111, stake + 1)));
        assertEq(game.busy(ALICE), 0);
        assertEq(game.liabilities(), 0);
        assertEq(address(game).balance, 0);
        // Cover both entry paths, including a practical amount above the removed cap.
        for (uint256 i; i < 2; ++i) {
            uint256 amount = i == 0 ? stake : 1_000_000 ether + 1;
            vm.deal(ALICE, amount);
            vm.deal(BOB, amount);
            vm.prank(ALICE);
            uint256 id = i == 0
                ? game.createChallenge{value: amount}(BOB, 111, amount, 60)
                : game.joinQueue{value: amount}(111, amount);
            vm.prank(BOB);
            if (i == 0) game.joinChallenge{value: amount}(id, 222);
            else assertEq(game.joinQueue{value: amount}(222, amount), id);
            vm.prank(BOB);
            game.forfeit(id);
            uint256 fee = amount / 20;
            assertEq(game.creditOf(ALICE), 2 * amount - fee);
            assertEq(game.creditOf(address(collector)), fee);
            assertEq(game.busy(ALICE), 0);
            assertEq(game.busy(BOB), 0);
            vm.prank(ALICE);
            game.withdraw(ALICE);
            vm.prank(address(collector));
            game.withdraw(EVE);
            assertEq(ALICE.balance, 2 * amount - fee);
            assertEq(game.liabilities(), 0);
            assertEq(address(game).balance, 0);
        }
    }

    function testCommitmentAndWindowBounds() public {
        _reject(ALICE, DEPOSIT, abi.encodeCall(IFelonyGame.createChallenge, (BOB, 0, STAKE, 60)));
        _reject(ALICE, DEPOSIT, abi.encodeCall(IFelonyGame.createChallenge, (BOB, FIELD, STAKE, 60)));
        _reject(ALICE, DEPOSIT, abi.encodeCall(IFelonyGame.createChallenge, (BOB, 111, STAKE, 59)));
        uint256 id = _create(BOB);
        _reject(BOB, DEPOSIT, abi.encodeCall(IFelonyGame.joinChallenge, (id, FIELD)));
        require(game.liabilities() == DEPOSIT, "failed join mutated escrow");
    }

    function testCancellationAndJoinDeadlineBoundary() public {
        uint256 id = _create(BOB);
        _reject(EVE, 0, abi.encodeCall(IFelonyGame.cancelChallenge, (id)));
        vm.warp(game.matchInfo(id)[7]);
        _reject(EVE, 0, abi.encodeCall(IFelonyGame.cancelChallenge, (id)));
        vm.prank(BOB);
        game.joinChallenge{value: DEPOSIT}(id, 222);
        require(game.matchInfo(id)[6] == 2, "exact deadline join");
    }

    function testExpiredInvitationPermissionlessCancelAndWithdraw() public {
        uint256 id = _create(BOB);
        vm.warp(game.matchInfo(id)[7] + 1);
        _reject(BOB, DEPOSIT, abi.encodeCall(IFelonyGame.joinChallenge, (id, 222)));
        vm.prank(EVE);
        game.cancelChallenge(id);
        require(game.matchInfo(id)[6] == 5 && game.busy(ALICE) == 0, "cancelled state");
        _reject(EVE, 0, abi.encodeCall(IFelonyGame.cancelChallenge, (id)));
        _credits(DEPOSIT, 0, 0);
        uint256 balance = EVE.balance;
        vm.prank(ALICE);
        game.withdraw(EVE);
        require(EVE.balance == balance + DEPOSIT && game.liabilities() == 0, "cancel refund");
        _reject(ALICE, 0, abi.encodeCall(IFelonyGame.withdraw, (EVE)));
    }

    function testFuzzCreatorCancelsUnacceptedMatch(uint256 elapsed, bool queued, bool zeroStake) public {
        uint256 stake = zeroStake ? 0 : STAKE;
        uint256 before = ALICE.balance;
        vm.prank(ALICE);
        uint256 id =
            queued ? game.joinQueue{value: stake}(111, stake) : game.createChallenge{value: stake}(BOB, 111, stake, 60);
        vm.warp(block.timestamp + bound(elapsed, 0, game.matchInfo(id)[7] - block.timestamp));
        _reject(BOB, 0, abi.encodeCall(IFelonyGame.cancelChallenge, (id)));
        _reject(EVE, 0, abi.encodeCall(IFelonyGame.cancelChallenge, (id)));
        vm.prank(ALICE);
        game.cancelChallenge(id);
        assertEq(game.matchInfo(id)[6], 5);
        assertEq(game.busy(ALICE), 0);
        assertEq(game.busy(BOB), 0);
        assertEq(game.creditOf(ALICE), stake);
        assertEq(game.liabilities(), stake);
        assertEq(oracle.nextId(), 0, "cancelled invitation requested randomness");
        if (queued) assertEq(game.queueHead(stake), 0);
        _reject(ALICE, 0, abi.encodeCall(IFelonyGame.cancelChallenge, (id)));
        _reject(BOB, stake, abi.encodeCall(IFelonyGame.joinChallenge, (id, 222)));
        if (stake != 0) {
            vm.prank(ALICE);
            game.withdraw(ALICE);
        }
        assertEq(ALICE.balance, before);
        assertEq(game.creditOf(ALICE), 0);
        assertEq(game.liabilities(), 0);
        require(_create(EVE) > id, "cancelled ID reused");
    }

    function testCreatorCancelsAtExactInvitationDeadline() public {
        uint256 id = _create(BOB);
        vm.warp(game.matchInfo(id)[7]);
        vm.prank(ALICE);
        game.cancelChallenge(id);
        _reject(BOB, DEPOSIT, abi.encodeCall(IFelonyGame.joinChallenge, (id, 222)));
        _credits(DEPOSIT, 0, 0);
    }

    function testAcceptedMatchCannotBeCancelledByCreator() public {
        uint256 id = _joined();
        _reject(ALICE, 0, abi.encodeCall(IFelonyGame.cancelChallenge, (id)));
        assertEq(game.matchInfo(id)[6], 2);
        assertEq(oracle.nextId(), 1);
        assertEq(game.creditOf(ALICE), 0);
        assertEq(game.liabilities(), 2 * STAKE);
        assertEq(game.busy(ALICE), 1);
        assertEq(game.busy(BOB), 1);
        _activate(id);
        _reject(ALICE, 0, abi.encodeCall(IFelonyGame.cancelChallenge, (id)));
        assertEq(game.matchInfo(id)[6], 3);
    }

    function testCancellingDirectInvitationPreservesAnotherPlayersQueue() public {
        vm.prank(EVE);
        uint256 queued = game.joinQueue{value: STAKE}(333, STAKE);
        uint256 invited = _create(BOB);
        vm.prank(ALICE);
        game.cancelChallenge(invited);
        assertEq(game.queueHead(STAKE), queued);
        vm.prank(BOB);
        assertEq(game.joinQueue{value: STAKE}(222, STAKE), queued);
        assertEq(game.creditOf(ALICE), STAKE);
        assertEq(game.liabilities(), 3 * STAKE);
    }

    function testCancelledQueueCannotMatchAndCreatorCanRequeueImmediately() public {
        vm.prank(ALICE);
        uint256 first = game.joinQueue{value: STAKE}(111, STAKE);
        vm.prank(ALICE);
        game.cancelChallenge(first);
        vm.prank(ALICE);
        uint256 next = game.joinQueue{value: STAKE}(444, STAKE);
        assertGt(next, first);
        vm.prank(BOB);
        assertEq(game.joinQueue{value: STAKE}(222, STAKE), next);
        assertEq(game.matchInfo(first)[6], 5);
        assertEq(game.creditOf(ALICE), STAKE);
        assertEq(game.liabilities(), 3 * STAKE);
        assertEq(oracle.nextId(), 1);
    }

    function testQueueAutomaticallyMatchesAndRequestsRandomness() public {
        vm.prank(ALICE);
        uint256 id = game.joinQueue{value: DEPOSIT}(111, STAKE);
        require(game.queueHead(STAKE) == id && oracle.nextId() == 0, "premature request");
        _reject(ALICE, 0, abi.encodeCall(IFelonyGame.activateMatch, (id)));
        _reject(ALICE, DEPOSIT, abi.encodeCall(IFelonyGame.joinQueue, (111, STAKE)));
        _reject(EVE, 0, abi.encodeCall(IFelonyGame.cancelChallenge, (id)));
        vm.prank(BOB);
        uint256 matched = game.joinQueue{value: DEPOSIT}(222, STAKE);
        require(matched == id && game.queueHead(STAKE) == 0, "queue pairing");
        require(oracle.nextId() == 1 && game.liabilities() == 2 * STAKE, "request or escrow");
        uint256[18] memory info = game.matchInfo(id);
        require(info[0] == uint256(uint160(ALICE)) && info[1] == uint256(uint160(BOB)), "seats");
        require(info[2] == 111 && info[3] == 222 && info[6] == 2, "commitments");
        uint256 seed = _activate(id);
        Board memory b = _initial(seed);
        _submit(id, b, seed, 0, 0);
        _submit(id, b, seed, 1, 0);
        require(game.matchInfo(id)[10] == 1, "queued match not playable");
    }

    function testQueueExactPaymentAndSeparateStakeBuckets() public {
        bytes memory enqueue = abi.encodeCall(IFelonyGame.joinQueue, (111, STAKE));
        _reject(ALICE, DEPOSIT - 1, enqueue);
        _reject(ALICE, DEPOSIT + 1, enqueue);
        vm.prank(ALICE);
        uint256 first = game.joinQueue{value: DEPOSIT}(111, STAKE);

        vm.prank(BOB);
        uint256 second = game.joinQueue{value: STAKE + 1}(222, STAKE + 1);
        require(second != first, "queue matched incompatible terms");
        vm.prank(EVE);
        uint256 matched = game.joinQueue{value: DEPOSIT}(333, STAKE);
        require(matched == first && game.matchInfo(first)[1] == uint256(uint160(EVE)), "wrong queue bucket selected");
        require(game.matchInfo(second)[6] != 2 && game.liabilities() == 3 * DEPOSIT + 1, "unmatched escrow corrupted");
    }

    function testQueueTimeoutCancellationReleasesEscrowAndSlot() public {
        vm.prank(ALICE);
        uint256 id = game.joinQueue{value: DEPOSIT}(111, STAKE);
        uint256 deadline = game.matchInfo(id)[7];
        require(deadline > block.timestamp, "queue has no cancellation deadline");
        vm.warp(deadline);
        _reject(EVE, 0, abi.encodeCall(IFelonyGame.cancelChallenge, (id)));
        vm.warp(deadline + 1);
        vm.prank(EVE);
        game.cancelChallenge(id);
        require(game.busy(ALICE) == 0 && game.matchInfo(id)[6] == 5, "queue cancellation state");
        _credits(DEPOSIT, 0, 0);
        vm.prank(BOB);
        uint256 next = game.joinQueue{value: DEPOSIT}(222, STAKE);
        require(next != id, "cancelled queue slot reused");
        require(game.liabilities() == 2 * DEPOSIT && game.creditOf(ALICE) == DEPOSIT, "new queue overwrote refund");
    }

    function testQueueAutomaticallyRefundsExpiredHeadBeforeNewAdmission() public {
        vm.prank(ALICE);
        uint256 old = game.joinQueue{value: DEPOSIT}(111, STAKE);
        vm.warp(game.matchInfo(old)[7] + 1);
        vm.prank(BOB);
        uint256 next = game.joinQueue{value: DEPOSIT}(222, STAKE);
        require(next != old && game.matchInfo(old)[6] == 5, "expired head matched");
        require(game.creditOf(ALICE) == DEPOSIT && game.busy(ALICE) == 0, "expired entrant not released");
        require(game.liabilities() == 2 * DEPOSIT, "auto-refund liability");
        vm.prank(EVE);
        uint256 matched = game.joinQueue{value: DEPOSIT}(333, STAKE);
        require(matched == next && game.matchInfo(next)[0] == uint256(uint160(BOB)), "replacement queue not matchable");
        require(game.liabilities() == 3 * DEPOSIT, "replacement escrow");
    }

    function testPermissionlessManagedMatchCannotReleasePvPEscrowOrBusyFlags() public {
        uint256 real = _joined();
        vm.prank(EVE);
        game.reserveManagedMatches(123, 1);
        vm.prank(EVE);
        uint256 fake = game.createManagedMatch(ALICE, BOB, 111, 222, 123, 456, 60, 0);
        require(fake != real && game.managedInfo(fake)[0] == uint256(uint160(EVE)), "managed provenance");
        vm.warp(game.matchInfo(fake)[7] + 1);
        game.claimTimeout(fake);
        require(game.busy(ALICE) != 0 && game.busy(BOB) != 0, "managed cleared PvP busy");
        require(
            game.liabilities() == 2 * DEPOSIT && game.creditOf(ALICE) == 0 && game.creditOf(BOB) == 0
                && game.burned() == 0,
            "managed changed escrow"
        );
        require(game.matchInfo(real)[6] == 2, "managed overwrote PvP");
        oracle.expire(game.randomnessRequest(real));
        game.claimTimeout(real);
        _credits(STAKE, STAKE, 0);
    }

    function testFrozenRoundMirroredStateAndDuplicateSubmission() public {
        uint256 id = _joined();
        uint256 seed = _activate(id);
        Board memory b = _initial(seed);
        uint256 deadline = game.matchInfo(id)[7];
        _submit(id, b, seed, 0, 0);
        uint256[18] memory pending = game.matchInfo(id);
        require(
            pending[10] == 0 && pending[11] == 1 && pending[12] == 0 && pending[13] == 0 && pending[16] == 1,
            "first move changed board"
        );
        require(pending[7] == deadline, "first move extended deadline");
        _reject(ALICE, 0, abi.encodeCall(IFelonyGame.submitMove, (id, 0, new bytes(9152))), "Move already submitted");
        _submit(id, b, seed, 1, 8);
        _resolve(b, 1, 9, seed);
        _arm(id, b, seed, 0, 1);
        _arm(id, b, seed, 1, 7);
        require(game.matchInfo(id)[13] == b.s1 && b.s1 > 0, "negative-seat score missing");
        _submit(id, b, seed, 1, 7);
        _submit(id, b, seed, 0, 1);
        _resolve(b, 2, 8, seed);
        _arm(id, b, seed, 0, 2);
        _arm(id, b, seed, 1, 6);
        require(game.matchInfo(id)[11] == 0, "pending mask not reset");
    }

    function testProofEncodingIsOwnedByVerifier() public {
        uint256 id = _joined();
        uint256 seed = _activate(id);
        Board memory b = _initial(seed);
        _arm(id, b, seed, 0, 0);
        verifier.configureProofLength(64);
        _reject(ALICE, 0, abi.encodeCall(IFelonyGame.submitMove, (id, 0, new bytes(63))));
        require(game.matchInfo(id)[11] == 0, "invalid encoding consumed turn");
        vm.prank(ALICE);
        game.submitMove(id, 0, new bytes(64));
        require(game.matchInfo(id)[11] == 1, "verifier-accepted encoding rejected");
    }

    function testExpensiveVerificationAndOutOfGasRetry() public {
        uint256 id = _joined();
        uint256 seed = _activate(id);
        Board memory b = _initial(seed);
        _arm(id, b, seed, 0, 0);
        verifier.configureVerificationWork(2_100_000);
        bytes memory proof = new bytes(9152);
        bytes32 beforeState = keccak256(abi.encode(game.matchInfo(id)));
        vm.prank(ALICE);
        (bool ok,) = address(game).call{gas: 2_000_000}(abi.encodeCall(IFelonyGame.submitMove, (id, 0, proof)));
        assertFalse(ok, "insufficient gas accepted");
        assertEq(keccak256(abi.encode(game.matchInfo(id))), beforeState, "failed verification changed match");

        verifier.configure(keccak256(abi.encode(_words(id, b, seed, 0, 0))), 1);
        vm.prank(ALICE);
        (bool invalidOk, bytes memory reason) =
            address(game).call{gas: 3_000_000}(abi.encodeCall(IFelonyGame.submitMove, (id, 0, proof)));
        assertEq(reason, abi.encodeWithSignature("Error(string)", "Invalid proof"));
        assertFalse(invalidOk, "expensive invalid proof accepted");
        assertEq(keccak256(abi.encode(game.matchInfo(id))), beforeState, "invalid proof changed match");

        _arm(id, b, seed, 0, 0);
        uint256 startGas = gasleft();
        vm.prank(ALICE);
        game.submitMove{gas: 3_000_000}(id, 0, proof);
        assertGt(startGas - gasleft(), 2_000_000, "did not exercise expensive verification");
        assertEq(game.matchInfo(id)[11], 1, "retry did not submit first move");
        _arm(id, b, seed, 1, 1);
        vm.prank(BOB);
        game.submitMove{gas: 3_000_000}(id, 1, proof);
        assertEq(game.matchInfo(id)[10], 1, "second expensive proof did not advance round");
        assertEq(game.matchInfo(id)[11], 0, "round did not clear submitted moves");
        assertEq(game.liabilities(), 2 * STAKE);
    }

    function testProofInputsValidatesExternalArguments() public {
        uint256 id = _joined();
        _reject(ALICE, 0, abi.encodeCall(IFelonyGame.proofInputs, (id, 0, 0)));
        uint256 seed = _activate(id);
        Board memory b = _initial(seed);
        _reject(ALICE, 0, abi.encodeCall(IFelonyGame.proofInputs, (id, 2, 0)));
        _reject(ALICE, 0, abi.encodeCall(IFelonyGame.proofInputs, (id, 0, 9)));
        _arm(id, b, seed, 0, 0);
        _arm(id, b, seed, 1, 8);
    }

    function testAllNineVerifierWordsBoundAndFailureAtomic() public {
        uint256 id = _joined();
        uint256 seed = _activate(id);
        Board memory b = _initial(seed);
        uint256[9] memory good = _words(id, b, seed, 0, 0);
        for (uint256 i; i < 9; ++i) {
            uint256[9] memory bad = _words(id, b, seed, 0, 0);
            ++bad[i];
            verifier.configure(keccak256(abi.encode(bad)), 0);
            _reject(ALICE, 0, abi.encodeCall(IFelonyGame.submitMove, (id, 0, new bytes(9152))));
            require(game.matchInfo(id)[11] == 0, "rejected proof changed state");
        }
        for (uint256 mode = 1; mode <= 2; ++mode) {
            verifier.configure(keccak256(abi.encode(good)), mode);
            _reject(ALICE, 0, abi.encodeCall(IFelonyGame.submitMove, (id, 0, new bytes(9152))));
        }
        verifier.configure(keccak256(abi.encode(good)), 0);
        _reject(ALICE, 0, abi.encodeCall(IFelonyGame.submitMove, (id, 1, new bytes(9152))));
        _reject(EVE, 0, abi.encodeCall(IFelonyGame.submitMove, (id, 0, new bytes(9152))));
        _reject(ALICE, 0, abi.encodeCall(IFelonyGame.submitMove, (id, 9, new bytes(9152))));
        _reject(ALICE, 0, abi.encodeCall(IFelonyGame.submitMove, (id, 0, new bytes(9151))));
        _reject(ALICE, 0, abi.encodeCall(IFelonyGame.submitMove, (id, 0, new bytes(9153))));
        _submit(id, b, seed, 0, 0);
        verifier.configure(keccak256(abi.encode(_words(id, b, seed, 1, 1))), 1);
        _reject(BOB, 0, abi.encodeCall(IFelonyGame.submitMove, (id, 1, new bytes(9152))));
        require(game.matchInfo(id)[11] == 1 && game.matchInfo(id)[10] == 0, "bad second proof consumed first");
        _submit(id, b, seed, 1, 1);
        _resolve(b, 1, 2, seed);
        _arm(id, b, seed, 0, 0);
        _reject(ALICE, 0, abi.encodeCall(IFelonyGame.submitMove, (id, 0, new bytes(9152))), "Card already used");
    }

    function _complete(bool draw) private {
        uint256 id = _joined();
        uint256 seed = _activate(id);
        Board memory b = _initial(seed);
        for (uint256 round; round < 8; ++round) {
            uint256 other = draw ? round : 8 - round;
            _submit(id, b, seed, 0, round);
            _submit(id, b, seed, 1, other);
            _resolve(b, round + 1, other + 1, seed);
        }
        _resolve(b, 9, draw ? 9 : 1, seed);
        uint256 result = b.s0 > b.s1 ? 1 : b.s1 > b.s0 ? 2 : 3;
        uint256[18] memory info = game.matchInfo(id);
        require(info[6] == 4 && info[10] == 9 && info[11] == 0 && info[14] == result, "16-proof terminal state");
        require(info[12] == b.s0 && info[13] == b.s1, "automatic ninth round scoring");
        if (result == 1) _credits(WIN, 0, 0);
        else if (result == 2) _credits(0, WIN, 0);
        else _credits(DEPOSIT, DEPOSIT, 0);
        require(game.busy(ALICE) == 0 && game.busy(BOB) == 0, "finish busy leak");
        _reject(ALICE, 0, abi.encodeCall(IFelonyGame.submitMove, (id, 8, new bytes(9152))));
        _reject(ALICE, 0, abi.encodeCall(IFelonyGame.forfeit, (id)));
        _reject(EVE, 0, abi.encodeCall(IFelonyGame.claimTimeout, (id)));
    }

    function testSixteenProofsAutomaticallyResolveLastCards() public {
        _complete(false);
    }

    function _playByPrize(uint256 id, uint256 seed, uint256[9] memory a, uint256[9] memory c)
        private
        returns (uint256[18] memory info)
    {
        Board memory b = _initial(seed);
        for (uint256 r; r < 8; ++r) {
            uint256 x = a[b.prize - 1];
            uint256 y = c[b.prize - 1];
            _submit(id, b, seed, 0, x - 1);
            _submit(id, b, seed, 1, y - 1);
            _resolve(b, x, y, seed);
        }
        _resolve(b, a[b.prize - 1], c[b.prize - 1], seed);
        info = game.matchInfo(id);
        assertEq(info[6], 4);
        assertEq(info[10], 9);
        assertEq(info[12], b.s0);
        assertEq(info[13], b.s1);
    }

    function testFuzzTournamentTiebreakSkipsBurnedPrizes(uint256 seed, bool swapSeats, uint8 fixture) public {
        uint256[9] memory a = [uint256(6), 3, 5, 2, 1, 4, 8, 7, 9];
        uint256[9] memory b = [uint256(8), 7, 2, 4, 3, 5, 6, 1, 9];
        uint256 score = 18;
        if (fixture % 3 == 1) {
            a = [uint256(2), 9, 7, 3, 6, 4, 5, 1, 8];
            b = [uint256(2), 1, 9, 5, 4, 3, 6, 8, 7];
            score = 22;
        } else if (fixture % 3 == 2) {
            a = [uint256(4), 1, 7, 6, 2, 5, 8, 3, 9];
            b = [uint256(7), 6, 1, 4, 5, 8, 2, 3, 9];
            score = 14;
        }
        seed %= FIELD;
        game.reserveManagedMatches(123, 1);
        uint256 id = game.createManagedMatch(ALICE, BOB, 111, 222, 123, seed, 60, 0);
        uint256[18] memory info = _playByPrize(id, seed, swapSeats ? b : a, swapSeats ? a : b);
        assertEq(info[12], score);
        assertEq(info[13], score);
        assertEq(info[14], swapSeats ? 2 : 1);
        assertEq(game.managedInfo(id)[1], 0, "sporting result, not default");
        _credits(0, 0, 0);
    }

    function testScoreTiedPvPWithCapturedPrizesRefundsBothStakes() public {
        uint256 id = _joined();
        uint256 seed = _activate(id);
        uint256[18] memory info =
            _playByPrize(id, seed, [uint256(6), 3, 5, 2, 1, 4, 8, 7, 9], [uint256(8), 7, 2, 4, 3, 5, 6, 1, 9]);
        assertEq(info[12], 18);
        assertEq(info[13], 18);
        assertEq(info[14], 3);
        _credits(STAKE, STAKE, 0);
    }

    function testAllTiesBurnPrizesAndRefundDraw() public {
        _complete(true);
    }

    function testFirstMoveDoesNotExtendDeadlineAndTimeoutCannotStealReadyPlayer() public {
        uint256 id = _joined();
        uint256 seed = _activate(id);
        Board memory b = _initial(seed);
        uint256 deadline = game.matchInfo(id)[7];
        vm.warp(deadline - 1);
        _submit(id, b, seed, 0, 0);
        require(game.matchInfo(id)[7] == deadline, "deadline extended");
        vm.warp(deadline);
        _reject(EVE, 0, abi.encodeCall(IFelonyGame.claimTimeout, (id)));
        vm.warp(deadline + 1);
        _reject(BOB, 0, abi.encodeCall(IFelonyGame.submitMove, (id, 0, new bytes(9152))));
        _reject(ALICE, 0, abi.encodeCall(IFelonyGame.forfeit, (id)));
        game.claimTimeout(id);
        _credits(WIN, 0, 0);
        _reject(EVE, 0, abi.encodeCall(IFelonyGame.claimTimeout, (id)));
    }

    function testSecondMoveAcceptedExactlyAtDeadlineAndNextRoundGetsFreshWindow() public {
        uint256 id = _joined();
        uint256 seed = _activate(id);
        Board memory b = _initial(seed);
        uint256 deadline = game.matchInfo(id)[7];
        _submit(id, b, seed, 0, 0);
        vm.warp(deadline);
        _submit(id, b, seed, 1, 0);
        require(game.matchInfo(id)[10] == 1 && game.matchInfo(id)[7] == deadline + 60, "deadline transition");
    }

    function testNeitherPlayerSubmitsTimeoutForfeitsBothStakes() public {
        uint256 id = _joined();
        _activate(id);
        vm.warp(game.matchInfo(id)[7] + 1);
        game.claimTimeout(id);
        require(game.matchInfo(id)[14] == 4, "double default result");
        _credits(0, 0, 2 * STAKE);
        _reject(ALICE, 0, abi.encodeCall(IFelonyGame.withdraw, (ALICE)));
        _reject(BOB, 0, abi.encodeCall(IFelonyGame.withdraw, (BOB)));
        _reject(EVE, 0, abi.encodeCall(IFelonyGame.claimTimeout, (id)));
    }

    function testSeatOneReadyWinsTimeout() public {
        uint256 id = _joined();
        uint256 seed = _activate(id);
        Board memory b = _initial(seed);
        _submit(id, b, seed, 1, 0);
        vm.warp(game.matchInfo(id)[7] + 1);
        game.claimTimeout(id);
        _credits(0, WIN, 0);
    }

    function testForfeitAwaitingRandomnessAndDuringPlay() public {
        uint256 id = _joined();
        _reject(EVE, 0, abi.encodeCall(IFelonyGame.forfeit, (id)));
        vm.prank(ALICE);
        game.forfeit(id);
        _credits(0, WIN, 0);
        vm.prank(BOB);
        game.withdraw(BOB);
        collector.collect(game);
        id = _joined();
        _activate(id);
        vm.prank(BOB);
        game.forfeit(id);
        _credits(WIN, 0, 0);
    }

    function testRejectedWithdrawalRestoresCreditAndLiability() public {
        uint256 id = _joined();
        vm.prank(BOB);
        game.forfeit(id);
        RejectGamePayout recipient = new RejectGamePayout();
        _reject(ALICE, 0, abi.encodeCall(IFelonyGame.withdraw, (address(recipient))), "ETH transfer failed");
        _reject(ALICE, 0, abi.encodeCall(IFelonyGame.withdraw, (address(0))));
        _credits(WIN, 0, 0);
        uint256 before = ALICE.balance;
        vm.prank(ALICE);
        game.withdraw(ALICE);
        require(
            ALICE.balance == before + WIN && game.liabilities() == STAKE / 20 && address(game).balance == STAKE / 20,
            "withdraw accounting"
        );
    }

    function testReentrantWithdrawalCannotSpendCreditTwice() public {
        ReentrantGamePlayer attacker = new ReentrantGamePlayer(game);
        uint256 id = _create(address(attacker));
        attacker.join{value: DEPOSIT}(id, 222);
        vm.prank(ALICE);
        game.forfeit(id);
        attacker.pull();
        require(attacker.attempted() && !attacker.reentered(), "reentrant duplicate withdrawal");
        require(!attacker.crossFunctionReentered(), "withdrawal callback mutated another Arena entry point");
        vm.prank(address(attacker));
        require(game.reserveManagedMatches(999, 1) == id + 1, "guard not released after withdrawal");
        require(address(attacker).balance == WIN && game.creditOf(address(attacker)) == 0, "attacker overpaid");
        require(
            game.liabilities() == STAKE / 20 && address(game).balance == STAKE / 20, "reentrant liability corruption"
        );
    }

    function testUnsolicitedBalanceDoesNotBecomePlayerCredit() public {
        uint256 id = _joined();
        vm.deal(address(game), address(game).balance + 7 ether);
        vm.prank(BOB);
        game.forfeit(id);
        _credits(WIN, 0, 0);
        vm.prank(ALICE);
        game.withdraw(ALICE);
        require(
            game.liabilities() == STAKE / 20 && address(game).balance == 7 ether + STAKE / 20,
            "forced ETH counted as escrow"
        );
    }

    function testManagedMatchUsesItsOwnSeedAndMoveWindows() public {
        game.reserveManagedMatches(123, 1);
        uint256 id = game.createManagedMatch(ALICE, BOB, 111, 222, 123, FIELD + 20202, 180, 0);
        require(game.matchInfo(id)[6] == 3 && game.matchInfo(id)[7] == block.timestamp + 180, "custom turn deadline");
        uint256 seed = game.matchInfo(id)[9];
        require(seed == 20202 && oracle.nextId() == 0, "managed seed or unexpected request");
        Board memory b = _initial(seed);
        vm.warp(block.timestamp + 100);
        _submit(id, b, seed, 0, 0);
        _submit(id, b, seed, 1, 1);
        require(game.matchInfo(id)[7] == block.timestamp + 180, "custom subsequent turn");
        vm.prank(ALICE);
        game.forfeit(id);
        require(game.liabilities() == 0 && game.creditOf(address(collector)) == 0, "managed fee");
    }

    function testManagedReservationsAreOwnedBoundedAndCannotBeReused() public {
        _reject(EVE, 0, abi.encodeCall(IFelonyGame.reserveManagedMatches, (0, 4)));
        _reject(EVE, 0, abi.encodeCall(IFelonyGame.reserveManagedMatches, (1, 0)));
        _reject(EVE, 0, abi.encodeCall(IFelonyGame.reserveManagedMatches, (1, 1025)));
        _reject(EVE, 0, abi.encodeCall(IFelonyGame.createManagedMatch, (ALICE, BOB, 111, 222, 1, 7, 60, 0)));
        uint256 first = game.reserveManagedMatches(1, 1024);
        require(first == 1, "first reservation");
        for (uint256 i; i < 1024; ++i) {
            require(game.managedMatchId(address(this), 1, i) == first + i, "reserved range");
        }
        _reject(address(this), 0, abi.encodeCall(IFelonyGame.reserveManagedMatches, (1, 4)));
        _reject(
            address(this), 0, abi.encodeCall(IFelonyGame.createManagedMatch, (ALICE, BOB, 111, 222, 1, 7, 60, 1024))
        );
        _reject(EVE, 0, abi.encodeCall(IFelonyGame.createManagedMatch, (ALICE, BOB, 111, 222, 1, 7, 60, 0)));
        vm.prank(EVE);
        uint256 other = game.reserveManagedMatches(1, 4);
        require(other == first + 1024, "manager namespace overlaps");
        uint256 nextTournament = game.reserveManagedMatches(2, 4);
        require(nextTournament == other + 4, "tournament namespace overlaps");
        uint256 pvp = _create(BOB);
        require(pvp == nextTournament + 4, "PvP overlaps reserved IDs");
        uint256 id = game.createManagedMatch(ALICE, BOB, 111, 222, 1, 7, 60, 1023);
        require(id == first + 1023, "later allocation moved reservation");
        _reject(
            address(this), 0, abi.encodeCall(IFelonyGame.createManagedMatch, (ALICE, BOB, 111, 222, 1, 8, 60, 1023))
        );
        vm.prank(ALICE);
        game.forfeit(id);
        _reject(
            address(this), 0, abi.encodeCall(IFelonyGame.createManagedMatch, (ALICE, BOB, 111, 222, 1, 8, 60, 1023))
        );
        require(game.matchInfo(id)[9] == 7 && game.matchInfo(id)[6] == 4, "finished reservation overwritten");
    }

    function testManagedMatchRejectsInvalidWindows() public {
        vm.prank(EVE);
        game.reserveManagedMatches(123, 1);
        _reject(EVE, 0, abi.encodeCall(IFelonyGame.createManagedMatch, (ALICE, BOB, 111, 222, 123, 1, 59, 0)));
        _reject(EVE, 0, abi.encodeCall(IFelonyGame.createManagedMatch, (ALICE, BOB, 111, 222, 123, 1, 86401, 0)));
    }

    function testOracleRequestBindsContextAndDoesNotActivateUntilReady() public {
        uint256 id = _create(BOB);
        require(oracle.nextId() == 0, "request before commitments locked");
        _reject(EVE, 0, abi.encodeCall(IFelonyGame.activateMatch, (id)));
        _join(id);
        uint256 request = game.randomnessRequest(id);
        (address caller, bytes32 context, uint256 state,) = oracle.requests(request);
        require(caller == address(game) && state == 1, "wrong request caller or status");
        require(
            context
                == keccak256(abi.encode(uint256(520), block.chainid, address(game), id, uint256(111), uint256(222))),
            "context binding"
        );
        require(game.matchInfo(id)[7] == 0 && game.matchInfo(id)[9] == 0, "premature seed or deadline");
        _reject(EVE, 0, abi.encodeCall(IFelonyGame.activateMatch, (id)));
        _reject(EVE, 0, abi.encodeCall(IFelonyGame.claimTimeout, (id)));
        _reject(ALICE, 0, abi.encodeCall(IFelonyGame.cancelChallenge, (id)));
        _reject(BOB, DEPOSIT, abi.encodeCall(IFelonyGame.joinChallenge, (id, 333)));
        require(game.matchInfo(id)[3] == 222 && game.randomnessRequest(id) == request, "pending request changed");
        oracle.fulfill(request, 0);
        vm.prank(EVE);
        game.activateMatch(id);
        uint256 expected =
            uint256(keccak256(abi.encode(uint256(521), block.chainid, address(game), id, uint256(0)))) % FIELD;
        require(game.matchInfo(id)[9] == expected && game.matchInfo(id)[6] == 3, "zero oracle word rejected");
        _reject(EVE, 0, abi.encodeCall(IFelonyGame.activateMatch, (id)));
        (bool repeated,) = address(oracle).call(abi.encodeCall(RandomOracleMock.fulfill, (request, 1)));
        require(!repeated && game.matchInfo(id)[9] == expected, "result not immutable");
        _arm(id, _initial(expected), expected, 0, 0);
    }

    function testOracleExpiryRefundsBothStakesWithoutFeeAndCannotRevive() public {
        oracle.setFee(12345);
        uint256 id = _joined();
        uint256 request = game.randomnessRequest(id);
        vm.warp(block.timestamp + 1 days);
        _reject(EVE, 0, abi.encodeCall(IFelonyGame.claimTimeout, (id)));
        oracle.expire(request);
        vm.prank(EVE);
        game.claimTimeout(id);
        require(
            game.matchInfo(id)[6] == 5 && game.busy(ALICE) == 0 && game.busy(BOB) == 0, "expired match not cancelled"
        );
        _credits(STAKE, STAKE, 0);
        require(game.creditOf(address(collector)) == 0 && address(oracle).balance == 12345, "expiry fee accounting");
        _reject(EVE, 0, abi.encodeCall(IFelonyGame.activateMatch, (id)));
        _reject(EVE, 0, abi.encodeCall(IFelonyGame.claimTimeout, (id)));
        (bool revived,) = address(oracle).call(abi.encodeCall(RandomOracleMock.fulfill, (request, 99)));
        require(!revived, "expired request revived");
    }

    function testReadyResultCannotExpireOrRefundEvenWhenActivationIsDelayed() public {
        uint256 id = _joined();
        uint256 request = game.randomnessRequest(id);
        oracle.fulfill(request, 42);
        vm.warp(block.timestamp + 30 days);
        (bool expired,) = address(oracle).call(abi.encodeCall(RandomOracleMock.expire, (request)));
        require(!expired, "ready result expired");
        _reject(EVE, 0, abi.encodeCall(IFelonyGame.claimTimeout, (id)));
        game.activateMatch(id);
        require(game.matchInfo(id)[7] == block.timestamp + 60, "turn starts before activation");
    }

    function testPaidOracleFeeIsExactAndExcludedFromEscrow() public {
        oracle.setFee(12345);
        uint256 id = _create(BOB);
        bytes memory join = abi.encodeCall(IFelonyGame.joinChallenge, (id, 222));
        _reject(BOB, STAKE, join);
        _reject(BOB, STAKE + 12344, join);
        _reject(BOB, STAKE + 12346, join);
        require(game.liabilities() == STAKE && oracle.nextId() == 0, "rejected fee changed state");
        _join(id);
        require(address(oracle).balance == 12345 && address(game).balance == 2 * STAKE, "fee held as stake");
        vm.prank(BOB);
        game.forfeit(id);
        _credits(WIN, 0, 0);
        require(game.creditOf(address(collector)) == STAKE / 20, "winnings fee");
        collector.collect(game);
        require(address(collector).balance == STAKE / 20 && game.liabilities() == WIN, "fee withdrawal");
        vm.prank(ALICE);
        game.withdraw(ALICE);
        require(game.liabilities() == 0 && address(game).balance == 0, "escrow not emptied");
    }

    function testPaidQueueOnlyMatchingPlayerPaysOracleFee() public {
        oracle.setFee(12345);
        _reject(ALICE, STAKE + 12345, abi.encodeCall(IFelonyGame.joinQueue, (111, STAKE)));
        vm.prank(ALICE);
        uint256 id = game.joinQueue{value: STAKE}(111, STAKE);
        require(oracle.nextId() == 0, "waiting entrant paid oracle");
        _reject(BOB, STAKE, abi.encodeCall(IFelonyGame.joinQueue, (222, STAKE)));
        _reject(BOB, STAKE + 12346, abi.encodeCall(IFelonyGame.joinQueue, (222, STAKE)));
        require(game.queueHead(STAKE) == id && game.busy(BOB) == 0, "failed join destroyed queue head");
        vm.prank(BOB);
        uint256 matched = game.joinQueue{value: STAKE + 12345}(222, STAKE);
        require(
            matched == id && game.liabilities() == 2 * STAKE && address(oracle).balance == 12345,
            "paid queue accounting"
        );
    }

    function testOracleFailureRollsBackChallengeAndQueueJoins() public {
        oracle.setFee(12345);
        oracle.setFailRequest(true);
        uint256 id = _create(BOB);
        _reject(BOB, STAKE + 12345, abi.encodeCall(IFelonyGame.joinChallenge, (id, 222)));
        require(
            game.matchInfo(id)[6] == 1 && game.matchInfo(id)[3] == 0 && game.busy(BOB) == 0,
            "failed request consumed challenge"
        );
        require(
            game.liabilities() == STAKE && address(game).balance == STAKE && oracle.nextId() == 0,
            "failed request escrow"
        );
        oracle.setFailRequest(false);
        _join(id);
        vm.prank(BOB);
        game.forfeit(id);
        vm.prank(ALICE);
        game.withdraw(ALICE);
        collector.collect(game);
        vm.prank(ALICE);
        uint256 queued = game.joinQueue{value: STAKE}(111, STAKE);
        oracle.setFailRequest(true);
        _reject(BOB, STAKE + 12345, abi.encodeCall(IFelonyGame.joinQueue, (222, STAKE)));
        require(
            game.queueHead(STAKE) == queued && game.matchInfo(queued)[1] == 0 && game.busy(BOB) == 0,
            "failed queue request consumed entry"
        );
        require(game.liabilities() == STAKE && address(game).balance == STAKE, "failed queue escrow");
        oracle.setFailRequest(false);
        vm.prank(BOB);
        require(game.joinQueue{value: STAKE + 12345}(222, STAKE) == queued, "retry not usable");
    }

    function testOracleCallbackCannotMutateArenaDuringRequest() public {
        oracle.setReentry(address(game), abi.encodeCall(IFelonyGame.reserveManagedMatches, (1, 1)));
        uint256 id = _joined();
        require(oracle.reentryAttempted() && !oracle.reentrySucceeded(), "oracle callback entered Arena");
        require(
            game.matchInfo(id)[6] == 2 && game.liabilities() == 2 * STAKE && oracle.nextId() == 1,
            "callback corrupted state"
        );
        game.reserveManagedMatches(1, 1);
        uint256 next = game.createManagedMatch(ALICE, BOB, 111, 222, 1, 8, 60, 0);
        require(next == id + 1, "callback consumed match id");
    }

    function testInterleavedMatchesKeepTheirOwnRequestAndSeed() public {
        uint256 first = _joined();
        address dave = address(0xda7e);
        vm.deal(dave, 100 ether);
        vm.prank(EVE);
        uint256 second = game.createChallenge{value: STAKE}(dave, 333, STAKE, 60);
        vm.prank(dave);
        game.joinChallenge{value: STAKE}(second, 444);
        uint256 req0 = game.randomnessRequest(first);
        uint256 req1 = game.randomnessRequest(second);
        require(req0 != req1, "requests reused");
        oracle.fulfill(req1, 77);
        game.activateMatch(second);
        _reject(EVE, 0, abi.encodeCall(IFelonyGame.activateMatch, (first)));
        oracle.fulfill(req0, 77);
        game.activateMatch(first);
        uint256 seed0 =
            uint256(keccak256(abi.encode(uint256(521), block.chainid, address(game), first, uint256(77)))) % FIELD;
        uint256 seed1 =
            uint256(keccak256(abi.encode(uint256(521), block.chainid, address(game), second, uint256(77)))) % FIELD;
        require(
            seed0 != seed1 && game.matchInfo(first)[9] == seed0 && game.matchInfo(second)[9] == seed1,
            "cross-match seed confusion"
        );
        require(game.matchInfo(first)[2] == 111 && game.matchInfo(second)[2] == 333, "cross-match commitments");
    }

    function testSettingsAndTinyStakeFeeRounding() public {
        uint256[5] memory config = game.settings();
        require(
            config[0] == uint256(uint160(address(verifier))) && config[1] == uint256(address(verifier).codehash)
                && config[2] == 60 && config[3] == uint256(uint160(address(oracle)))
                && config[4] == uint256(uint160(address(collector))),
            "settings ABI"
        );
        vm.prank(ALICE);
        uint256 id = game.createChallenge{value: 19}(BOB, 111, 19, 60);
        vm.prank(BOB);
        game.joinChallenge{value: 19}(id, 222);
        vm.prank(BOB);
        game.forfeit(id);
        require(
            game.creditOf(ALICE) == 38 && game.creditOf(address(collector)) == 0 && game.liabilities() == 38,
            "fee rounding"
        );
    }
}
