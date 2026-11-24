// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {RandomOracle} from "../Interfaces.sol";
import {CoordinatorMock, OracleAcceptingVerifier} from "../mocks/OracleMocks.sol";

contract RandomOracleTest is Test {
    event RandomnessReady(uint256 indexed request_id, uint256 random_word);
    CoordinatorMock coordinator;
    RandomOracle oracle;
    bytes32 constant KEY = keccak256("configured coordinator key hash");
    uint256 constant SUB = 42;
    uint16 constant CONFIRMATIONS = 12;
    uint32 constant CALLBACK_GAS = 200_000;
    uint256 constant TIMEOUT = 1 hours;
    address constant ALICE = address(0xa11ce);

    function _deploy(
        address coord,
        address sponsor,
        bytes32 key,
        uint256 sub,
        uint16 conf,
        uint32 gasLimit,
        uint256 timeout,
        bool nativePayment,
        uint256 fee
    ) internal returns (RandomOracle result) {
        bytes memory creation = abi.encodePacked(
            vm.readFileBinary("artifacts/random_oracle.bin"),
            abi.encode(coord, sponsor, key, sub, conf, gasLimit, timeout, nativePayment, fee)
        );
        address deployed;
        assembly { deployed := create(0, add(creation, 32), mload(creation)) }
        require(deployed != address(0), "oracle deployment");
        require(deployed.code.length <= 24_576, "runtime size");
        result = RandomOracle(deployed);
    }

    function setUp() public {
        vm.warp(1000);
        coordinator = new CoordinatorMock();
        oracle = _deploy(address(coordinator), address(this), KEY, SUB, CONFIRMATIONS, CALLBACK_GAS, TIMEOUT, true, 0);
        oracle.setConsumer(address(this), true);
    }

    function testOfficialCoordinatorAbiAndNativeExtraArgs() public {
        uint256 id = oracle.requestRandomness(bytes32(uint256(1)));
        require(id == 1 && oracle.quoteFee() == 0, "request / fee");
        require(coordinator.keyHash() == KEY && coordinator.subId() == SUB, "key / subscription");
        require(
            coordinator.confirmations() == CONFIRMATIONS && coordinator.callbackGasLimit() == CALLBACK_GAS,
            "confirmation / gas"
        );
        require(coordinator.numWords() == 1, "word count");
        require(
            keccak256(coordinator.extraArgs())
                == keccak256(abi.encodeWithSelector(bytes4(keccak256("VRF ExtraArgsV1")), true)),
            "native extra args"
        );
        uint256[3] memory info = oracle.requestInfo(id);
        require(info[0] == uint160(address(this)) && info[1] == 1000 + TIMEOUT && info[2] == 1, "request info");
        uint256[9] memory config = oracle.settings();
        require(config[0] == uint160(address(coordinator)) && config[1] == uint160(address(this)), "addresses");
        require(config[2] == uint256(KEY) && config[3] == SUB && config[4] == CONFIRMATIONS, "key config");
        require(config[5] == CALLBACK_GAS && config[6] == TIMEOUT && config[7] == 1, "gas config");
    }

    function testLinkPaymentExtraArgs() public {
        RandomOracle linkOracle =
            _deploy(address(coordinator), address(this), KEY, SUB, CONFIRMATIONS, CALLBACK_GAS, TIMEOUT, false, 0);
        linkOracle.setConsumer(address(this), true);
        linkOracle.requestRandomness(bytes32(uint256(2)));
        require(
            keccak256(coordinator.extraArgs())
                == keccak256(abi.encodeWithSelector(bytes4(keccak256("VRF ExtraArgsV1")), false)),
            "LINK extra args"
        );
    }

    function testZeroWordBecomesReadyAndNeverExpires() public {
        uint256 id = oracle.requestRandomness(bytes32(uint256(3)));
        require(!oracle.isReady(id) && oracle.status(id) == 1, "pending");
        vm.expectRevert(bytes("Randomness not ready"));
        oracle.getRandomness(id);
        vm.expectEmit(true, false, false, true, address(oracle));
        emit RandomnessReady(id, 0);
        coordinator.fulfill(oracle, id, 0);
        require(oracle.isReady(id) && oracle.status(id) == 2 && oracle.getRandomness(id) == 0, "ready zero");
        vm.warp(1000 + TIMEOUT + 100);
        require(oracle.status(id) == 2 && oracle.getRandomness(id) == 0, "ready forever");
    }

    function testCallbackFitsMinimumConfiguredGas() public {
        RandomOracle small =
            _deploy(address(coordinator), address(this), KEY, SUB, CONFIRMATIONS, 100_000, TIMEOUT, true, 0);
        small.setConsumer(address(this), true);
        uint256 id = small.requestRandomness(bytes32(uint256(100)));
        require(coordinator.fulfillWithGas(small, id, 42, 100_000), "callback gas");
        require(small.getRandomness(id) == 42, "fulfilled");
    }

    function testUnknownRequestsAlwaysRejectIncludingZero() public {
        vm.expectRevert();
        oracle.status(0);
        vm.expectRevert();
        oracle.isReady(0);
        vm.expectRevert();
        oracle.getRandomness(0);
        vm.expectRevert();
        oracle.requestInfo(1);
        vm.expectRevert();
        coordinator.fulfill(oracle, 1, 5);
    }

    function testOnlyCoordinatorCanFulfillAndOnlyOnce() public {
        uint256 id = oracle.requestRandomness(bytes32(uint256(4)));
        uint256[] memory words = new uint256[](1);
        words[0] = 5;
        vm.expectRevert();
        oracle.rawFulfillRandomWords(id, words);
        coordinator.fulfill(oracle, id, 5);
        vm.expectRevert();
        coordinator.fulfill(oracle, id, 6);
        require(oracle.getRandomness(id) == 5, "immutable");
    }

    function testExactlyOneWordRequiredAndFailureDoesNotConsume() public {
        uint256 id = oracle.requestRandomness(bytes32(uint256(5)));
        vm.expectRevert();
        coordinator.fulfillMany(oracle, id, 0);
        vm.expectRevert();
        coordinator.fulfillMany(oracle, id, 2);
        require(oracle.status(id) == 1, "pending after malformed callback");
        coordinator.fulfill(oracle, id, type(uint256).max);
        require(oracle.getRandomness(id) == type(uint256).max, "full width word");
    }

    function testDeadlineInclusiveAndExpiryTerminal() public {
        uint256 a = oracle.requestRandomness(bytes32(uint256(6)));
        uint256 b = oracle.requestRandomness(bytes32(uint256(7)));
        vm.warp(1000 + TIMEOUT);
        require(oracle.status(a) == 1, "at deadline pending");
        coordinator.fulfill(oracle, a, 7);
        vm.warp(1001 + TIMEOUT);
        require(oracle.status(b) == 3 && !oracle.isReady(b), "expired");
        vm.expectRevert();
        coordinator.fulfill(oracle, b, 8);
        vm.expectRevert(bytes("Randomness not ready"));
        oracle.getRandomness(b);
        vm.expectRevert(bytes("Context already used"));
        oracle.requestRandomness(bytes32(uint256(7)));
        require(oracle.getRandomness(a) == 7, "ready request unaffected");
    }

    function testOutOfOrderFulfillmentKeepsResultsSeparate() public {
        uint256 a = oracle.requestRandomness(bytes32(uint256(8)));
        uint256 b = oracle.requestRandomness(bytes32(uint256(9)));
        coordinator.fulfill(oracle, b, 222);
        require(oracle.status(a) == 1 && oracle.getRandomness(b) == 222, "out of order");
        coordinator.fulfill(oracle, a, 111);
        require(oracle.getRandomness(a) == 111 && oracle.getRandomness(b) == 222, "separate");
    }

    function testContextCannotBeRerolledButIsNamespacedByConsumer() public {
        oracle.requestRandomness(bytes32(uint256(10)));
        vm.expectRevert(bytes("Context already used"));
        oracle.requestRandomness(bytes32(uint256(10)));
        oracle.setConsumer(ALICE, true);
        vm.prank(ALICE);
        uint256 id = oracle.requestRandomness(bytes32(uint256(10)));
        require(id == 2, "consumer namespace");
    }

    function testSponsorControlsAllowlistAndRevocationKeepsCallbacksValid() public {
        vm.prank(ALICE);
        vm.expectRevert();
        oracle.setConsumer(ALICE, true);
        vm.prank(ALICE);
        vm.expectRevert();
        oracle.requestRandomness(bytes32(uint256(11)));
        vm.expectRevert();
        oracle.setConsumer(address(0), true);
        oracle.setConsumer(ALICE, true);
        require(oracle.isConsumer(ALICE), "allowed");
        vm.prank(ALICE);
        uint256 id = oracle.requestRandomness(bytes32(uint256(11)));
        oracle.setConsumer(ALICE, false);
        require(!oracle.isConsumer(ALICE), "revoked");
        vm.prank(ALICE);
        vm.expectRevert();
        oracle.requestRandomness(bytes32(uint256(12)));
        coordinator.fulfill(oracle, id, 17);
        require(oracle.getRandomness(id) == 17, "existing callback survives revocation");
    }

    function testZeroCoordinatorIdRejectedAtomically() public {
        coordinator.configure(0, false, false, false);
        vm.expectRevert();
        oracle.requestRandomness(bytes32(uint256(14)));
        coordinator.configure(1, false, false, false);
        require(oracle.requestRandomness(bytes32(uint256(14))) == 1, "retry after invalid ID");
    }

    function testReusedCoordinatorIdCannotOverwriteRequest() public {
        uint256 id = oracle.requestRandomness(bytes32(uint256(15)));
        coordinator.fulfill(oracle, id, 99);
        coordinator.configure(1, false, false, false);
        vm.expectRevert();
        oracle.requestRandomness(bytes32(uint256(16)));
        require(oracle.getRandomness(id) == 99, "first result preserved");
        coordinator.configure(2, false, false, false);
        require(oracle.requestRandomness(bytes32(uint256(16))) == 2, "context rolled back");
    }

    function testReentrantRequestFailsEvenFromAllowedCoordinator() public {
        oracle.setConsumer(address(coordinator), true);
        coordinator.configure(1, false, true, false);
        oracle.requestRandomness(bytes32(uint256(17)));
        require(!coordinator.attackWorked(), "reentry blocked");
        require(oracle.status(1) == 1, "outer request valid");
    }

    function testRequestGuardBlocksFulfillmentOfExistingRequestUntilReturn() public {
        uint256 pending = oracle.requestRandomness(bytes32(uint256(180)));
        coordinator.setCallbackRequestId(pending);
        coordinator.configure(2, false, false, true);
        uint256 next = oracle.requestRandomness(bytes32(uint256(181)));
        require(!coordinator.attackWorked(), "coordinator fulfilled during another request");
        require(oracle.status(pending) == 1 && oracle.status(next) == 1, "callback changed pending state");
        coordinator.fulfill(oracle, pending, 23);
        coordinator.fulfill(oracle, next, 24);
        require(oracle.getRandomness(pending) == 23 && oracle.getRandomness(next) == 24, "guard not released");
    }

    function testSynchronousCallbackCannotFrontRunRequestRegistration() public {
        coordinator.configure(1, false, false, true);
        uint256 id = oracle.requestRandomness(bytes32(uint256(18)));
        require(!coordinator.attackWorked() && oracle.status(id) == 1, "synchronous callback blocked");
        coordinator.fulfill(oracle, id, 23);
        require(oracle.getRandomness(id) == 23, "async callback works");
    }

    function testRequestRejectsEther() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) =
            address(oracle).call{value: 1}(abi.encodeCall(RandomOracle.requestRandomness, (bytes32(uint256(19)))));
        require(!ok && address(oracle).balance == 0, "no fee collected");
    }
    bool private rejectPayment;
    bool private tryReentry;
    bool private withdrawalReentered;

    receive() external payable {
        require(!rejectPayment, "recipient refuses");
        if (tryReentry) {
            (withdrawalReentered,) = msg.sender.call(abi.encodeCall(RandomOracle.withdrawFees, (address(this))));
        }
    }

    function _paidOracle() internal returns (RandomOracle paid) {
        paid = _deploy(address(coordinator), address(this), KEY, SUB, CONFIRMATIONS, CALLBACK_GAS, TIMEOUT, true, 12345);
        paid.setConsumer(address(this), true);
        vm.deal(address(this), 1 ether);
    }

    function testExactFeeCollectedAndOwnerWithdraws() public {
        RandomOracle paid = _paidOracle();
        require(paid.quoteFee() == 12345, "fee quote");
        vm.expectRevert();
        paid.requestRandomness(bytes32(uint256(20)));
        vm.expectRevert();
        paid.requestRandomness{value: 12344}(bytes32(uint256(20)));
        vm.expectRevert();
        paid.requestRandomness{value: 12346}(bytes32(uint256(20)));
        uint256 id = paid.requestRandomness{value: 12345}(bytes32(uint256(20)));
        require(paid.fees() == 12345 && address(paid).balance == 12345, "fee accrued");
        require(address(coordinator).balance == 0, "subscription paid separately");
        vm.prank(ALICE);
        vm.expectRevert();
        paid.withdrawFees(ALICE);
        vm.expectRevert();
        paid.withdrawFees(address(0));
        uint256 beforeBalance = ALICE.balance;
        paid.withdrawFees(ALICE);
        require(ALICE.balance - beforeBalance == 12345 && paid.fees() == 0 && address(paid).balance == 0, "withdraw");
        coordinator.fulfill(paid, id, 77);
        require(paid.getRandomness(id) == 77, "withdraw does not affect delivery");
        vm.expectRevert();
        paid.withdrawFees(ALICE);
    }

    function testRequestFailureRollsBackContextLockAndFees() public {
        for (uint256 i; i < 2; ++i) {
            RandomOracle target = i == 0 ? oracle : _paidOracle();
            uint256 fee = target.quoteFee();
            uint256 beforeBalance = address(this).balance;
            bytes32 context = bytes32(uint256(21));
            coordinator.configure(1, true, false, false);
            vm.expectRevert();
            target.requestRandomness{value: fee}(context);
            assertEq(address(this).balance, beforeBalance, "failed request refund");
            assertEq(target.fees(), 0);
            assertEq(address(target).balance, 0);
            coordinator.configure(1, false, false, false);
            uint256 id = target.requestRandomness{value: fee}(context);
            assertEq(id, 1, "context and lock released for retry");
            assertEq(target.status(id), 1, "retry registered pending request");
            assertEq(coordinator.nextId(), 2);
            vm.expectRevert();
            target.requestRandomness{value: fee}(context);
            assertEq(coordinator.nextId(), 2, "duplicate reached coordinator");
            assertEq(address(this).balance, beforeBalance - fee, "duplicate refunded");
            assertEq(target.fees(), fee);
            assertEq(address(target).balance, fee);
        }
    }

    function testRejectedWithdrawalPreservesFeesAndReentryCannotWithdrawTwice() public {
        RandomOracle paid = _paidOracle();
        paid.requestRandomness{value: 12345}(bytes32(uint256(22)));
        rejectPayment = true;
        vm.expectRevert();
        paid.withdrawFees(address(this));
        require(paid.fees() == 12345 && address(paid).balance == 12345, "failed withdrawal preserved");
        rejectPayment = false;
        tryReentry = true;
        paid.withdrawFees(address(this));
        require(!withdrawalReentered && paid.fees() == 0 && address(paid).balance == 0, "no double withdrawal");
    }

    function testInvalidDeploymentConfigurationRejected() public {
        vm.expectRevert();
        this.deployInvalid(0);
        vm.expectRevert();
        this.deployInvalid(1);
        vm.expectRevert();
        this.deployInvalid(2);
        vm.expectRevert();
        this.deployInvalid(3);
        vm.expectRevert();
        this.deployInvalid(4);
        vm.expectRevert();
        this.deployInvalid(5);
        vm.expectRevert();
        this.deployInvalid(6);
        vm.expectRevert();
        this.deployInvalid(7);
    }

    function deployInvalid(uint256 field) external {
        _deploy(
            field == 0 ? ALICE : address(coordinator),
            field == 1 ? address(0) : address(this),
            field == 2 ? bytes32(0) : KEY,
            field == 3 ? 0 : SUB,
            field == 4 ? 0 : field == 5 ? 201 : CONFIRMATIONS,
            field == 6 ? 99_999 : CALLBACK_GAS,
            field == 7 ? 0 : TIMEOUT,
            true,
            0
        );
    }
}

interface OracleArena {
    function createChallenge(address opponent, uint256 commitment, uint256 stake, uint256 joinSeconds)
        external
        payable
        returns (uint256);
    function joinChallenge(uint256 id, uint256 commitment) external payable;
    function activateMatch(uint256 id) external;
    function randomnessRequest(uint256 id) external view returns (uint256);
    function forfeit(uint256 id) external;
    function claimTimeout(uint256 id) external;
    function matchInfo(uint256 id) external view returns (uint256[18] memory);
    function creditOf(address player) external view returns (uint256);
    function busy(address player) external view returns (uint256);
    function liabilities() external view returns (uint256);
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
}

contract ArenaRandomOracleIntegrationTest is Test {
    CoordinatorMock coordinator;
    RandomOracle oracle;
    OracleArena arena;
    address constant ALICE = address(0xa11ce);
    address constant BOB = address(0xb0b);
    uint256 constant FEE = 12345;
    uint256 constant FIELD = 21888242871839275222246405745257275088548364400416034343698204186575808495617;

    function _deploy(string memory artifact, bytes memory args) internal returns (address result) {
        bytes memory creation = abi.encodePacked(vm.readFileBinary(artifact), args);
        assembly { result := create(0, add(creation, 32), mload(creation)) }
        require(result != address(0), "deployment");
    }

    function setUp() public {
        vm.warp(1000);
        vm.deal(ALICE, 10 ether);
        vm.deal(BOB, 10 ether);
        coordinator = new CoordinatorMock();
        oracle = RandomOracle(
            _deploy(
                "artifacts/random_oracle.bin",
                abi.encode(
                    address(coordinator),
                    address(this),
                    keccak256("key"),
                    uint256(42),
                    uint16(12),
                    uint32(200_000),
                    uint256(1 hours),
                    true,
                    FEE
                )
            )
        );
        arena = OracleArena(
            _deploy(
                "artifacts/game.bin",
                abi.encode(address(new OracleAcceptingVerifier()), address(oracle), address(this), uint256(60))
            )
        );
        oracle.setConsumer(address(arena), true);
    }

    function _create() internal returns (uint256 id) {
        vm.prank(ALICE);
        id = arena.createChallenge{value: 1 ether}(BOB, 123, 1 ether, 60);
    }

    function _join(uint256 id) internal returns (uint256 requestId) {
        vm.prank(BOB);
        arena.joinChallenge{value: 1 ether + FEE}(id, 456);
        requestId = arena.randomnessRequest(id);
    }

    function testRealAdapterGameLifecycleAndSeparateFees() public {
        uint256 id = _create();
        uint256 requestId = _join(id);
        require(requestId != 0 && oracle.status(requestId) == 1, "issued pending request");
        require(address(arena).balance == 2 ether && arena.liabilities() == 2 ether, "stake accounting");
        require(address(oracle).balance == FEE && oracle.fees() == FEE, "separate request fee");
        vm.expectRevert();
        arena.activateMatch(id);
        coordinator.fulfill(oracle, requestId, 0);
        vm.warp(1000 + 1 hours + 1);
        arena.activateMatch(id);
        uint256[18] memory game = arena.matchInfo(id);
        uint256 seed =
            uint256(keccak256(abi.encode(uint256(521), block.chainid, address(arena), id, uint256(0)))) % FIELD;
        require(game[6] == 3 && game[9] == seed && game[7] == block.timestamp + 60, "seed and activation deadline");
        vm.prank(BOB);
        arena.forfeit(id);
        require(arena.creditOf(ALICE) == 1.95 ether && arena.creditOf(address(this)) == 0.05 ether, "winner fee");
        require(arena.busy(ALICE) == 0 && arena.busy(BOB) == 0, "busy cleared");
        require(arena.liabilities() == 2 ether && oracle.fees() == FEE, "separate payout and randomness fees");
    }

    function testRealAdapterExpiredRequestRefundsBothStakesWithoutWinningsFee() public {
        uint256 id = _create();
        uint256 requestId = _join(id);
        vm.warp(1001 + 1 hours);
        require(oracle.status(requestId) == 3, "expired");
        vm.expectRevert();
        coordinator.fulfill(oracle, requestId, 3);
        vm.expectRevert();
        arena.activateMatch(id);
        arena.claimTimeout(id);
        require(arena.matchInfo(id)[6] == 5, "cancelled");
        require(arena.creditOf(ALICE) == 1 ether && arena.creditOf(BOB) == 1 ether, "refunds");
        require(arena.creditOf(address(this)) == 0 && arena.liabilities() == 2 ether, "no winnings fee");
        require(arena.busy(ALICE) == 0 && arena.busy(BOB) == 0 && oracle.fees() == FEE, "expiry accounting");
        vm.expectRevert();
        arena.claimTimeout(id);
    }

    function testRealCoordinatorFailureRollsBackJoinAndPermitsRetry() public {
        uint256 id = _create();
        coordinator.configure(1, true, false, false);
        vm.prank(BOB);
        vm.expectRevert();
        arena.joinChallenge{value: 1 ether + FEE}(id, 456);
        require(arena.matchInfo(id)[6] == 1 && arena.busy(BOB) == 0, "join rollback");
        require(
            arena.liabilities() == 1 ether && address(arena).balance == 1 ether && oracle.fees() == 0, "fee rollback"
        );
        coordinator.configure(1, false, false, false);
        require(_join(id) == 1, "retry");
    }

    function testManagedMatchHasFixedSeedAndDoesNotRequestOrChargeOracle() public {
        arena.reserveManagedMatches(1, 1);
        uint256 id = arena.createManagedMatch(ALICE, BOB, 123, 456, 1, type(uint256).max, 60, 0);
        uint256[18] memory game = arena.matchInfo(id);
        require(game[6] == 3 && game[9] == type(uint256).max % FIELD && game[4] == 0, "managed seed");
        require(coordinator.nextId() == 1 && oracle.fees() == 0 && arena.liabilities() == 0, "no randomness fee");
        vm.prank(BOB);
        arena.forfeit(id);
        require(arena.creditOf(ALICE) == 0 && arena.creditOf(address(this)) == 0, "managed settlement elsewhere");
    }
}
