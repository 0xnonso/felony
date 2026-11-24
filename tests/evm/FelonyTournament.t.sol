// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ITournament} from "../Interfaces.sol";
import {RandomOracleMock} from "../mocks/RandomOracleMock.sol";
import {MockArena, MockWETH, MockVault} from "../mocks/TournamentMocks.sol";
import {MerkleBracket} from "./MerkleBracket.sol";

contract FelonyTournamentTest is Test {
    uint256 private constant P = 1 ether;
    uint256 private constant ENTRY = 3600;
    uint256 private constant FUND = 3600;
    uint256 private constant WINDOW = 600;
    uint256 private constant TURN = 3600;
    address private constant COLLECTOR = address(0xFEE);

    uint256 private constant PHASE = 0;
    uint256 private constant CAPACITY = 1;
    uint256 private constant COUNT = 2;
    uint256 private constant ENTRY_END = 4;
    uint256 private constant FUND_BY = 5;
    uint256 private constant ROUND = 6;
    uint256 private constant STAGE = 7;
    uint256 private constant UNTIL = 8;
    uint256 private constant REQUEST = 9;
    uint256 private constant PENDING = 10;
    uint256 private constant SHARES = 11;
    uint256 private constant FORFEITS = 12;
    uint256 private constant FIRST = 13;
    uint256 private constant SECOND = 14;
    uint256 private constant THIRD = 15;
    uint256 private constant REMAINDER_SLOT = 16;
    uint256 private constant ROUNDS = 17;

    uint256 private constant OPEN = 1;
    uint256 private constant AWAITING_FUNDING = 2;
    uint256 private constant RUNNING = 3;
    uint256 private constant SETTLED = 4;
    uint256 private constant ABORTED = 5;
    uint256 private constant CANCELLED = 6;

    uint256 private constant WINDOW_STAGE = 0;
    uint256 private constant DRAWING = 1;
    uint256 private constant ACTIVE = 2;

    uint256 private constant ELIGIBLE = 1;
    uint256 private constant FORFEITED = 2;

    struct Spec {
        uint256 result;
        bool defaulted;
        bool set;
    }

    MockArena private arena;
    MockWETH private weth;
    MockVault private vault;
    RandomOracleMock private oracle;
    ITournament private t;
    mapping(uint256 => Spec) private specs;
    uint256 private randomState;
    bool private randomOutcomes;
    uint256 private nextWord = 1;

    receive() external payable {}

    function setUp() public {
        vm.warp(1_000_000);
        arena = new MockArena();
        weth = new MockWETH();
        vault = new MockVault(weth);
        oracle = new RandomOracleMock();
        vm.deal(address(this), 1000 ether);
        weth.deposit{value: 500 ether}();
        weth.transfer(address(vault), 500 ether);
        t = _deploy(address(arena), address(oracle));
    }

    function _deploy(address a, address o) private returns (ITournament deployed) {
        bytes memory creation = abi.encodePacked(
            vm.readFileBinary("artifacts/tournament.bin"), abi.encode(a, address(vault), address(weth), o, COLLECTOR)
        );
        address out;
        assembly { out := create(0, add(creation, 32), mload(creation)) }
        require(out != address(0), "deploy failed");
        require(creation.length <= 49152, "initcode above EIP-3860 limit");
        require(out.code.length <= 24576, "runtime above EIP-170 limit");
        deployed = ITournament(out);
    }

    function _player(uint256 i) private pure returns (address) {
        return address(uint160(0x1000 + i));
    }

    function _commitment(uint256 i) private pure returns (uint256) {
        return 5000 + i;
    }

    function _create(uint256 capacity, uint256 principal) private returns (uint256) {
        return t.createTournament(capacity, principal, ENTRY, FUND, WINDOW, TURN);
    }

    function _joinOne(uint256 id, uint256 i, uint256 amount) private {
        vm.deal(_player(i), amount);
        vm.prank(_player(i));
        t.join{value: amount}(id, _commitment(i));
    }

    function _fill(uint256 id, uint256 n, uint256 principal) private {
        for (uint256 i; i < n; i++) {
            _joinOne(id, i, principal);
        }
    }

    function _ready(uint256 capacity, uint256 principal) private returns (uint256 id) {
        id = _create(capacity, principal);
        _fill(id, capacity, principal);
        if (principal > 0) t.fund(id);
    }

    function _info(uint256 id) private view returns (uint256[18] memory) {
        return t.tournamentInfo(id);
    }

    function _word() private returns (uint256) {
        nextWord = uint256(keccak256(abi.encode("word", nextWord)));
        return nextWord;
    }

    function _draw(uint256 id) private {
        uint256 until = _info(id)[UNTIL];
        if (block.timestamp < until) vm.warp(until);
        t.requestDraw{value: oracle.quoteFee()}(id);
        oracle.fulfill(oracle.nextId(), _word());
        bool measure = _info(id)[CAPACITY] == 1024 && _info(id)[ROUND] == 0;
        if (measure) {
            vm.cool(address(t));
            vm.cool(address(oracle));
        }
        uint256 before = gasleft();
        t.beginRound(id);
        if (measure) emit log_named_uint("cold beginRound 1024 entrants", before - gasleft());
    }

    function _tree(uint256 id) private view returns (MerkleBracket.Tree memory) {
        uint256[18] memory info = _info(id);
        return MerkleBracket.build(block.chainid, address(t), id, t.drawWord(id, 0), info[COUNT], info[CAPACITY]);
    }

    function _nextRandom() private returns (uint256) {
        randomState = uint256(keccak256(abi.encode(randomState)));
        return randomState;
    }

    function _spec(uint256 index, uint256 result, bool defaulted) private {
        specs[index] = Spec(result, defaulted, true);
    }

    function _finishArena(uint256 id, uint256 index) private {
        uint256[4] memory m = t.bracketMatch(id, index);
        if (m[0] != 1) return;
        Spec memory s = specs[index];
        if (randomOutcomes) {
            uint256 r = _nextRandom();
            s.result = (r % 4) + 1;
            s.defaulted = s.result == 4 || (s.result < 3 && (r >> 8) % 3 == 0);
        } else if (!s.set) {
            s.result = 1;
        }
        arena.finish(m[3], s.result, s.defaulted);
        t.advance(id, index);
    }

    function _playRound(uint256 id, MerkleBracket.Tree memory tree) private {
        uint256[18] memory info = _info(id);
        uint256 round = info[ROUND];
        uint256 capacity = info[CAPACITY];
        if (round == info[ROUNDS]) {
            t.advance(id, 1);
            t.advance(id, 0);
            _finishArena(id, 1);
            _finishArena(id, 0);
            return;
        }
        uint256 first = capacity >> round;
        for (uint256 index = first; index < 2 * first; index++) {
            if (round == 1) {
                (uint256 s0, uint256 s1, uint256[9] memory sib) = MerkleBracket.proof(tree, index);
                t.openMatch(id, index, s0, s1, sib);
            } else {
                t.advance(id, index);
            }
        }
        for (uint256 index = first; index < 2 * first; index++) {
            _finishArena(id, index);
        }
    }

    function _playAll(uint256 id) private {
        MerkleBracket.Tree memory tree;
        while (_info(id)[PHASE] == RUNNING) {
            uint256[18] memory info = _info(id);
            if (info[STAGE] == WINDOW_STAGE) {
                _draw(id);
                if (_info(id)[ROUND] == 1) tree = _tree(id);
            } else if (info[ROUND] == info[ROUNDS] && info[PENDING] == 0) {
                t.finalize(id);
            } else {
                _playRound(id, tree);
            }
        }
    }

    function _claimAll(uint256 id, uint256 count) private {
        for (uint256 i; i < count; i++) {
            uint256 slot = t.slotOf(id, _player(i));
            if (slot == 0 || t.entryInfo(id, slot - 1)[2] == FORFEITED) continue;
            vm.prank(_player(i));
            t.claim(id);
        }
    }

    function _sharesPaid(uint256 count) private view returns (uint256 total) {
        for (uint256 i; i < count; i++) {
            total += vault.balanceOf(_player(i));
        }
    }

    struct Ref {
        uint256 count;
        uint256 shares;
        uint256 principal;
        uint256 value;
        uint256 scale;
        uint256 kept;
        uint256 eligible;
        uint256 assigned;
        uint256 rest;
    }

    function _reference(uint256 id) private view returns (uint256[] memory owed, uint256 fee, uint256 unowned) {
        uint256[18] memory info = _info(id);
        Ref memory r;
        r.count = info[COUNT];
        r.shares = info[SHARES];
        r.principal = info[3];
        owed = new uint256[](r.count);
        if (r.principal == 0) return (owed, 0, 0);
        if (info[PHASE] == ABORTED && info[ROUND] == 0) {
            for (uint256 s; s < r.count; s++) {
                owed[s] = r.shares / r.count;
            }
            owed[0] += r.shares % r.count;
            return (owed, 0, 0);
        }
        (r.value, r.scale) = _valuation(r.shares, r.count * r.principal);
        for (uint256 s; s < r.count; s++) {
            uint256[6] memory e = t.entryInfo(id, s);
            if (e[2] != ELIGIBLE) continue;
            uint256 base = (e[4] >= r.principal ? 0 : r.principal - e[4]) * r.scale / (r.count * r.principal);
            r.kept += base;
            owed[s] = base * r.shares / r.value;
            r.assigned += owed[s];
            if (info[PHASE] != ABORTED || e[5] > info[ROUND]) r.eligible++;
        }
        if (r.eligible == 0) return (owed, 0, r.shares - r.assigned);
        uint256 pool = r.value - r.kept;
        fee = pool * 500 / 10000;
        r.rest = pool - fee;
        fee = fee * r.shares / r.value;
        r.assigned += fee;
        r.assigned += _referencePrizes(id, info, r, owed);
        owed[info[REMAINDER_SLOT] - 1] += r.shares - r.assigned;
    }

    function _referencePrizes(uint256 id, uint256[18] memory info, Ref memory r, uint256[] memory owed)
        private
        view
        returns (uint256 assigned)
    {
        uint256[3] memory places = [info[FIRST], info[SECOND], info[THIRD]];
        uint256[3] memory weights = [uint256(50), 30, 20];
        uint256 totalWeight;
        for (uint256 i; i < 3; i++) {
            if (places[i] != 0) totalWeight += weights[i];
        }
        if (totalWeight == 0) {
            uint256 bonus = (r.rest / r.eligible) * r.shares / r.value;
            for (uint256 s; s < r.count; s++) {
                uint256[6] memory e = t.entryInfo(id, s);
                if (e[2] == ELIGIBLE && (info[PHASE] != ABORTED || e[5] > info[ROUND])) {
                    owed[s] += bonus;
                    assigned += bonus;
                }
            }
            return assigned;
        }
        uint256[3] memory prizes;
        uint256 sum;
        for (uint256 i; i < 3; i++) {
            if (places[i] != 0) prizes[i] = r.rest * weights[i] / totalWeight;
            sum += prizes[i];
        }
        for (uint256 i; i < 3; i++) {
            if (places[i] != 0) {
                prizes[i] += r.rest - sum;
                break;
            }
        }
        for (uint256 i; i < 3; i++) {
            if (places[i] == 0) continue;
            uint256 p = prizes[i] * r.shares / r.value;
            owed[places[i] - 1] += p;
            assigned += p;
        }
    }

    function _valuation(uint256 shares, uint256 total) private view returns (uint256 value, uint256 scale) {
        try vault.previewRedeem(shares) returns (uint256 q) {
            if (q > 0 && q < 1 << 128 && shares < 1 << 128) return (q, q < total ? q : total);
        } catch {}
        return (shares, shares);
    }

    function _assertMatchesReference(uint256 id) private view {
        (uint256[] memory owed, uint256 fee, uint256 unowned) = _reference(id);
        uint256 sum;
        for (uint256 s; s < owed.length; s++) {
            assertEq(t.entitlement(id, s), owed[s], "entitlement differs from reference");
            sum += owed[s];
        }
        uint256[9] memory p = t.payoutInfo(id);
        assertEq(p[7], fee, "fee differs");
        assertEq(p[8], unowned, "unowned shares differ");
        assertEq(sum + fee + unowned, _info(id)[SHARES], "every share assigned");
    }

    function _assertHoldingsCoverDebts() private view {
        uint256[2] memory a = t.accounting();
        require(weth.balanceOf(address(t)) == a[0], "wrapped balance equals cash debts");
        require(vault.balanceOf(address(t)) >= a[1], "shares cover share debts");
        require(address(t).balance == 0, "no idle ETH");
    }

    function testSixteenEntrantsDrawTwiceAndSettleInShares() public {
        uint256 id = _ready(16, P);
        uint256[7] memory r = t.roundInfo(id);
        require(r[5] == 4 && r[6] == 2, "four rounds, two draws");
        require(_info(id)[PHASE] == RUNNING && _info(id)[STAGE] == WINDOW_STAGE, "ready to draw at once");
        vault.setRate(110, 100);
        _playAll(id);
        uint256[18] memory info = _info(id);
        require(info[PHASE] == SETTLED && oracle.nextId() == 2, "settled after two draws");
        require(info[FIRST] != 0 && info[SECOND] != 0 && info[THIRD] != 0, "three places");
        _assertMatchesReference(id);
        _claimAll(id, 16);
        vm.prank(COLLECTOR);
        t.claimFees(id);
        require(_sharesPaid(16) + vault.balanceOf(COLLECTOR) == info[SHARES], "every share paid");
        require(t.accounting()[1] == 0 && vault.balanceOf(address(t)) == 0, "nothing left");
        _assertHoldingsCoverDebts();
    }

    function testFourEntrantsUseOneDrawAndNoWindow() public {
        uint256 id = _ready(4, P);
        require(t.roundInfo(id)[6] == 1, "one draw");
        _draw(id);
        MerkleBracket.Tree memory tree = _tree(id);
        _playRound(id, tree);
        require(_info(id)[ROUND] == 2 && _info(id)[STAGE] == ACTIVE, "final round follows without a window");
        _playRound(id, tree);
        t.finalize(id);
        require(oracle.nextId() == 1 && _info(id)[PHASE] == SETTLED, "one request");
        _assertMatchesReference(id);
    }

    function testBracketAndMatchSeedsFollowTheOracleWords() public {
        uint256 id = _ready(16, 0);
        _draw(id);
        uint256 word1 = t.drawWord(id, 1);
        require(t.drawWord(id, 0) == MerkleBracket.seed(block.chainid, address(t), id, 16, 16, word1), "bracket seed");
        MerkleBracket.Tree memory tree = _tree(id);
        require(t.bracketRoot(id) == MerkleBracket.root(tree), "root");
        (uint256 s0, uint256 s1, uint256[9] memory sib) = MerkleBracket.proof(tree, 8);
        t.openMatch(id, 8, s0, s1, sib);
        (,,,,, uint256 seed,,,,) = arena.games(t.bracketMatch(id, 8)[3]);
        require(seed == MerkleBracket.matchSeed(block.chainid, address(t), id, 8, word1), "first-round seed");
        (,, bytes32 context,,) = _request(1);
        require(context == MerkleBracket.drawContext(block.chainid, address(t), id, 1), "draw context");
    }

    function _request(uint256 rid) private view returns (address, uint256, bytes32, uint256, uint256) {
        (address caller, bytes32 context, uint256 state, uint256 word) = oracle.requests(rid);
        return (caller, rid, context, state, word);
    }

    function testLaterRoundsUseTheQuarterfinalDrawForEverything() public {
        uint256 id = _ready(16, 0);
        _draw(id);
        MerkleBracket.Tree memory tree = _tree(id);
        _playRound(id, tree);
        require(_info(id)[STAGE] == WINDOW_STAGE && _info(id)[UNTIL] == block.timestamp + WINDOW, "window");
        _draw(id);
        uint256 word2 = t.drawWord(id, 2);
        _playRound(id, tree);
        require(_info(id)[ROUND] == 3 && _info(id)[STAGE] == ACTIVE, "semifinals need no draw");
        t.advance(id, 2);
        (,,,,, uint256 seed,,,,) = arena.games(t.bracketMatch(id, 2)[3]);
        require(seed == MerkleBracket.matchSeed(block.chainid, address(t), id, 2, word2), "semifinal seed");
    }

    function _toFirstWindow(uint256 capacity) private returns (uint256 id) {
        id = _ready(capacity, P);
        _draw(id);
        _playRound(id, _tree(id));
        require(_info(id)[STAGE] == WINDOW_STAGE, "in the update window");
    }

    function _winnerAndLoser(uint256 id, uint256 index) private view returns (address w, address l) {
        uint256[4] memory m = t.bracketMatch(id, index);
        w = address(uint160(t.entryInfo(id, m[1] - 1)[0]));
        l = address(uint160(t.entryInfo(id, m[2] - 1)[0]));
    }

    function testUpdateModelOnlyForAdvancingEntrantsOncePerWindow() public {
        uint256 id = _toFirstWindow(16);
        (address winner, address loser) = _winnerAndLoser(id, 8);
        uint256 slot = t.slotOf(id, winner) - 1;
        vm.prank(loser);
        vm.expectRevert();
        t.updateModel(id, 777);
        vm.prank(winner);
        vm.expectRevert();
        t.updateModel(id, 0);
        vm.prank(winner);
        t.updateModel(id, 777);
        uint256[6] memory e = t.entryInfo(id, slot);
        require(e[1] == 777 && e[4] == P / 10 && e[5] == 2, "commitment, charge and round");
        vm.prank(winner);
        vm.expectRevert();
        t.updateModel(id, 778);
        vm.warp(_info(id)[UNTIL]);
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        t.updateModel(id, 1);
        vm.prank(_player(15));
        vm.expectRevert();
        t.updateModel(id, 779);
    }

    function testUpdatedCommitmentIsCopiedWhenTheNextMatchOpens() public {
        uint256 id = _toFirstWindow(16);
        (address winner,) = _winnerAndLoser(id, 8);
        vm.prank(winner);
        t.updateModel(id, 4242);
        _draw(id);
        t.advance(id, 4);
        (address p0,, uint256 c0, uint256 c1,,,,,,) = arena.games(t.bracketMatch(id, 4)[3]);
        require((p0 == winner ? c0 : c1) == 4242, "new commitment in the Arena");
    }

    function testNoUpdatesBeforeTheFirstRoundOrAfterTheQuarterfinalDraw() public {
        uint256 id = _ready(16, P);
        vm.prank(_player(0));
        vm.expectRevert();
        t.updateModel(id, 1);
        _draw(id);
        _playRound(id, _tree(id));
        _draw(id);
        _playRound(id, _tree(id));
        require(_info(id)[STAGE] == ACTIVE, "no window after the quarterfinal");
        vm.prank(_player(0));
        vm.expectRevert();
        t.updateModel(id, 1);
    }

    function testLossTaxThroughTheQuarterfinalOnly() public {
        uint256 id = _ready(16, P);
        _draw(id);
        MerkleBracket.Tree memory tree = _tree(id);
        _playRound(id, tree);
        (, address r16Loser) = _winnerAndLoser(id, 8);
        require(t.entryInfo(id, t.slotOf(id, r16Loser) - 1)[4] == P / 40, "first-round loss taxed");
        _draw(id);
        _playRound(id, tree);
        (, address qfLoser) = _winnerAndLoser(id, 4);
        require(t.entryInfo(id, t.slotOf(id, qfLoser) - 1)[4] == P / 40, "quarterfinal loss taxed");
        _playRound(id, tree);
        (, address sfLoser) = _winnerAndLoser(id, 2);
        require(t.entryInfo(id, t.slotOf(id, sfLoser) - 1)[4] == 0, "semifinal loss untaxed");
        _playRound(id, tree);
        t.finalize(id);
        uint256[18] memory info = _info(id);
        require(t.entryInfo(id, info[SECOND] - 1)[4] == 0, "final loss untaxed");
        _assertMatchesReference(id);
    }

    function testDefaultsForfeitWithoutTaxAndCannotClaim() public {
        uint256 id = _ready(16, P);
        _spec(8, 2, true);
        _spec(9, 4, true);
        _playAll(id);
        require(_info(id)[FORFEITS] == 3, "three forfeits");
        uint256[6] memory loser = t.entryInfo(id, _tree(id).leafSlots[0] - 1);
        require(loser[2] == FORFEITED && loser[4] == 0, "defaulter forfeited, not taxed");
        vm.prank(address(uint160(loser[0])));
        vm.expectRevert();
        t.claim(id);
        _assertMatchesReference(id);
    }

    function testDefaultedSemifinalLoserIsNotReseatedAndPlayoffIsAWalkover() public {
        uint256 id = _ready(16, P);
        _spec(2, 2, true);
        _playAll(id);
        uint256[18] memory info = _info(id);
        require(info[PHASE] == SETTLED, "walkover playoff settles");
        require(info[FORFEITS] == 1, "one forfeited entry");
        require(info[FIRST] != 0 && info[SECOND] != 0 && info[THIRD] != 0, "third from played loss");
        require(t.bracketMatch(id, 2)[0] == 2 && t.bracketMatch(id, 2)[2] == 0, "no loser recorded");
        require(t.bracketMatch(id, 0)[0] == 2, "playoff resolved as a walkover");
        (, address otherLoser) = _winnerAndLoser(id, 3);
        require(info[THIRD] == t.slotOf(id, otherLoser), "played loser takes third");
        _assertMatchesReference(id);
        _claimAll(id, 16);
        vm.prank(COLLECTOR);
        t.claimFees(id);
        require(_sharesPaid(16) + vault.balanceOf(COLLECTOR) == info[SHARES], "every share paid");
        _assertHoldingsCoverDebts();
    }

    function testPlayoffDoubleDefaultForfeitsBothPlayedLossLosersAndSettles() public {
        uint256 id = _ready(16, P);
        _spec(0, 4, true);
        _playAll(id);
        uint256[18] memory info = _info(id);
        require(info[PHASE] == SETTLED, "double default settles");
        require(info[FORFEITS] == 2, "two forfeited entries");
        require(info[THIRD] == 0, "no third place");
        (, address loserLeft) = _winnerAndLoser(id, 2);
        (, address loserRight) = _winnerAndLoser(id, 3);
        require(t.entryInfo(id, t.slotOf(id, loserLeft) - 1)[2] == FORFEITED, "left loser forfeited");
        require(t.entryInfo(id, t.slotOf(id, loserRight) - 1)[2] == FORFEITED, "right loser forfeited");
        _assertMatchesReference(id);
        _claimAll(id, 16);
        vm.prank(COLLECTOR);
        t.claimFees(id);
        require(_sharesPaid(16) + vault.balanceOf(COLLECTOR) == info[SHARES], "every share paid");
        _assertHoldingsCoverDebts();
    }

    function testRequestDrawPaysTheExactFeeAndNeverPrincipal() public {
        oracle.setFee(0.01 ether);
        uint256 id = _ready(4, P);
        uint256 shares = vault.balanceOf(address(t));
        vm.expectRevert();
        t.requestDraw{value: 0}(id);
        vm.expectRevert();
        t.requestDraw{value: 0.02 ether}(id);
        t.requestDraw{value: 0.01 ether}(id);
        require(address(oracle).balance == 0.01 ether && address(t).balance == 0, "fee forwarded");
        require(vault.balanceOf(address(t)) == shares && t.accounting()[0] == 0, "principal untouched");
        require(_info(id)[STAGE] == DRAWING, "drawing");
        vm.expectRevert();
        t.requestDraw{value: 0.01 ether}(id);
        vm.expectRevert();
        t.beginRound(id);
    }

    function testOracleReentryDuringRequestIsBlocked() public {
        uint256 id = _ready(4, 0);
        oracle.setReentry(address(t), abi.encodeCall(ITournament.createTournament, (4, 0, ENTRY, FUND, WINDOW, TURN)));
        t.requestDraw(id);
        require(oracle.reentryAttempted() && !oracle.reentrySucceeded(), "locked during the request");
        require(_create(4, 0) == id + 1, "guard not released after request");
    }

    function testExpiredDrawAbortsWithoutReroll() public {
        uint256 id = _ready(8, P);
        vault.setRate(104, 100);
        t.requestDraw(id);
        vm.expectRevert();
        t.abort(id);
        oracle.expire(1);
        vm.expectRevert();
        t.beginRound(id);
        t.abort(id);
        uint256[18] memory info = _info(id);
        require(info[PHASE] == ABORTED && info[FIRST] == 0 && oracle.nextId() == 1, "aborted, no places");
        vm.expectRevert();
        t.requestDraw(id);
        _assertMatchesReference(id);
        _claimAll(id, 8);
        vm.prank(COLLECTOR);
        t.claimFees(id);
        require(_sharesPaid(8) + vault.balanceOf(COLLECTOR) == info[SHARES], "everything paid");
    }

    function testUnpaidDrawCanBeAbortedAfterTheGrace() public {
        uint256 id = _toFirstWindow(16);
        uint256 until = _info(id)[UNTIL];
        vm.warp(until - 1);
        vm.expectRevert();
        t.requestDraw(id);
        vm.warp(until + FUND);
        vm.expectRevert();
        t.abort(id);
        vm.warp(until + FUND + 1);
        vm.expectRevert();
        t.requestDraw(id);
        t.abort(id);
        require(_info(id)[PHASE] == ABORTED, "aborted");
        _assertMatchesReference(id);
    }

    function testAbortAfterPlayPreservesUpdateDeductionAndForfeiture() public {
        uint256 id = _ready(16, P);
        _spec(8, 2, true);
        _draw(id);
        MerkleBracket.Tree memory tree = _tree(id);
        (uint256 forfeitedSlot,,) = MerkleBracket.proof(tree, 8);
        _playRound(id, tree);
        (address winner,) = _winnerAndLoser(id, 9);
        vm.prank(winner);
        t.updateModel(id, 99);
        _playAbort(id);
        uint256[6] memory updated = t.entryInfo(id, t.slotOf(id, winner) - 1);
        assertEq(updated[1], 99, "abort restored old commitment");
        assertEq(updated[4], P / 10, "abort erased update deduction");
        assertEq(t.entryInfo(id, forfeitedSlot - 1)[2], FORFEITED);
        assertEq(t.entitlement(id, forfeitedSlot - 1), 0, "abort restored forfeited principal");
        assertEq(_info(id)[FORFEITS], 1);
        uint256[9] memory p = t.payoutInfo(id);
        require(p[2] == 0 && p[3] == 0 && p[4] == 0 && p[5] > 0, "bonus, no prizes");
        _assertMatchesReference(id);
    }

    function testAbortSurvivorsGetPoolAndEliminatedGetOnlyPrincipal() public {
        uint256 id = _toFirstWindow(16);
        _playAbort(id);
        assertEq(t.payoutInfo(id)[5], 0.02375 ether, "eight survivors split 0.19 ETH");
        assertEq(t.payoutInfo(id)[7], 0.01 ether, "fee only on 0.2 ETH pool");
        for (uint256 i = 8; i < 16; i++) {
            (address winner, address loser) = _winnerAndLoser(id, i);
            assertEq(t.entitlement(id, t.slotOf(id, winner) - 1), 1.02375 ether);
            assertEq(t.entitlement(id, t.slotOf(id, loser) - 1), 0.975 ether);
        }
        _claimAll(id, 16);
        vm.prank(_player(0));
        vm.expectRevert();
        t.claim(id);
        vm.prank(COLLECTOR);
        t.claimFees(id);
        assertEq(_sharesPaid(16) + vault.balanceOf(COLLECTOR), 16 ether);
        assertEq(t.accounting()[1], 0);
    }

    function testFuzzAbortBeforePlayReturnsAllSharesWithoutQuoteOrFee(uint96 issued, bool loss) public {
        uint256 shares = bound(uint256(issued), 1, 1e26);
        vault.setMintedShares(shares);
        uint256 id = _ready(8, P);
        vault.setRate(loss ? 1 : 2, loss ? 2 : 1);
        vault.setPreview(true, false, 0);
        vm.expectCall(address(vault), abi.encodeCall(MockVault.previewRedeem, (shares)), uint64(0));
        _playAbort(id);
        for (uint256 i; i < 8; i++) {
            assertEq(t.entitlement(id, i), shares / 8 + (i == 0 ? shares % 8 : 0));
        }
        assertEq(t.payoutInfo(id)[7], 0);
        assertEq(t.payoutInfo(id)[8], 0);
        _claimAll(id, 8);
        assertEq(_sharesPaid(8), shares);
        assertEq(t.accounting()[1], 0);
        _assertMatchesReference(id);
    }

    function testAbortDustGoesToFirstSurvivorNotFirstEligibleEntrant() public {
        vault.setMintedShares(16 ether + 7);
        uint256 id = _ready(16, P);
        _draw(id);
        MerkleBracket.Tree memory tree = _tree(id);
        for (uint256 i = 8; i < 16; i++) {
            (uint256 s0, uint256 s1,) = MerkleBracket.proof(tree, i);
            if (s0 == 1) _spec(i, 2, false);
            if (s1 == 1) _spec(i, 1, false);
        }
        _playRound(id, tree);
        _playAbort(id);
        uint256 firstSurvivor;
        for (uint256 i; i < 16; i++) {
            uint256[6] memory e = t.entryInfo(id, i);
            if (e[5] == 2 && firstSurvivor == 0) firstSurvivor = i + 1;
        }
        assertGt(firstSurvivor, 1);
        assertEq(_info(id)[REMAINDER_SLOT], firstSurvivor);
        assertEq(t.payoutInfo(id)[6], 7);
        assertEq(t.entitlement(id, 0), 0.975 ether);
        assertEq(t.entitlement(id, firstSurvivor - 1), 1.02375 ether + 7);
        _assertMatchesReference(id);
    }

    function testAbortBeforeFirstDrawGraceRefundsWithoutFee() public {
        uint256 id = _ready(8, P);
        vault.setRate(2, 1);
        vm.warp(_info(id)[UNTIL] + FUND);
        vm.expectRevert();
        t.abort(id);
        vm.warp(block.timestamp + 1);
        t.abort(id);
        assertEq(t.payoutInfo(id)[7], 0);
        for (uint256 i; i < 8; i++) {
            assertEq(t.entitlement(id, i), P);
        }
        _assertMatchesReference(id);
    }

    function testAbortWithNoSurvivorsPreservesEliminatedPrincipalWithoutRewardingThem() public {
        uint256 id = _ready(32, P);
        _draw(id);
        MerkleBracket.Tree memory tree = _tree(id);
        _playRound(id, tree);
        for (uint256 i = 8; i < 16; i++) {
            _spec(i, 4, true);
        }
        _draw(id);
        _playRound(id, tree);
        _playAbort(id);
        uint256 eligibleCount;
        for (uint256 i; i < 32; i++) {
            if (t.entryInfo(id, i)[2] == ELIGIBLE) {
                eligibleCount++;
                assertEq(t.entitlement(id, i), 0.975 ether);
            } else {
                assertEq(t.entitlement(id, i), 0);
                vm.prank(_player(i));
                vm.expectRevert();
                t.claim(id);
            }
        }
        assertEq(eligibleCount, 16);
        assertEq(t.payoutInfo(id)[5], 0);
        assertEq(t.payoutInfo(id)[7], 0);
        assertEq(t.payoutInfo(id)[8], 16.4 ether);
        assertEq(_info(id)[REMAINDER_SLOT], 0);
        _assertMatchesReference(id);
        _claimAll(id, 32);
        assertEq(_sharesPaid(32) + t.payoutInfo(id)[8], 32 ether);
        assertEq(t.accounting()[1], 0);
    }

    function testAbortWithVaultLossPreservesDeductions() public {
        uint256 id = _toFirstWindow(16);
        vault.setRate(1, 2);
        _playAbort(id);
        assertEq(t.payoutInfo(id)[5], 0.02375 ether);
        assertEq(t.payoutInfo(id)[7], 0.01 ether);
        _assertMatchesReference(id);
    }

    function _playAbort(uint256 id) private {
        uint256 until = _info(id)[UNTIL];
        if (block.timestamp < until) vm.warp(until);
        t.requestDraw(id);
        oracle.expire(oracle.nextId());
        t.abort(id);
    }

    function testFeeOnlyWhenSomeoneCanBePaidAndCollectorClaimsOnce() public {
        uint256 id = _ready(4, P);
        _spec(2, 4, true);
        _spec(3, 4, true);
        _playAll(id);
        uint256[9] memory p = t.payoutInfo(id);
        require(p[7] == 0 && p[8] == _info(id)[SHARES], "no fee; everything unowned");
        delete specs[2];
        delete specs[3];
        vault.setRate(110, 100);
        uint256 other = _ready(4, P);
        _playAll(other);
        vm.expectRevert();
        t.claimFees(other);
        vm.prank(COLLECTOR);
        t.claimFees(other);
        require(vault.balanceOf(COLLECTOR) == t.payoutInfo(other)[7] && t.payoutInfo(other)[7] > 0, "fee paid");
        vm.prank(COLLECTOR);
        vm.expectRevert();
        t.claimFees(other);
    }

    function testVaultLossScalesTheUpdatedQuarterfinalLoserRefund() public {
        uint256 id = _toFirstWindow(16);
        (address winner, address firstLoser) = _winnerAndLoser(id, 8);
        vm.prank(winner);
        t.updateModel(id, 5);
        _spec(4, 2, false);
        vault.setRate(1, 2);
        _playAll(id);
        uint256 slot = t.slotOf(id, winner) - 1;
        require(t.bracketMatch(id, 4)[2] == slot + 1, "updated entrant must lose");
        require(t.entryInfo(id, slot)[4] == P / 10 + P / 40, "update and loss deductions");
        require(t.entitlement(id, slot) == 7 * P / 8, "deductions in shares");
        require(vault.previewRedeem(t.entitlement(id, slot)) == 7 * P / 16, "vault loss in assets");
        require(t.entitlement(id, t.slotOf(id, firstLoser) - 1) == 39 * P / 40, "no update charged to other loser");
        _assertMatchesReference(id);
    }

    function testZeroPrincipalTournamentPaysNothingAndNeedsNoVault() public {
        vault.setFailDeposit(true);
        uint256 id = _ready(8, 0);
        _playAll(id);
        require(_info(id)[PHASE] == SETTLED && t.entitlement(id, 0) == 0, "settled with nothing to pay");
        _claimAll(id, 8);
        vm.prank(COLLECTOR);
        t.claimFees(id);
    }

    function testFuzzBracketSettlementAndClaims(uint256 seed, uint8 roster, uint96 stake, uint16 rate) public {
        uint256 choice = bound(roster, 0, 18);
        uint256 count = choice == 0 ? 4 : choice == 1 ? 8 : choice + 14;
        uint256 capacity = 4;
        while (capacity < count) capacity *= 2;
        uint256 principal = bound(stake, 0, 1_000_000 ether);
        randomOutcomes = true;
        randomState = seed;
        nextWord = seed;
        uint256 id = _create(capacity, principal);
        _fill(id, count, principal);
        if (count < capacity) {
            vm.warp(_info(id)[ENTRY_END] + 1);
            t.start(id);
        }
        if (principal > 0) t.fund(id);

        vault.setRate(bound(rate, 0, 200), 100);
        _playAll(id);
        assertEq(_info(id)[PHASE], SETTLED, "tournament did not finish");
        _assertMatchesReference(id);
        for (uint256 slot; slot < count; ++slot) {
            uint256 owed = t.entitlement(id, slot);
            if (t.entryInfo(id, slot)[2] == FORFEITED) {
                assertEq(owed, 0, "forfeiter paid");
                continue;
            }
            address player = _player(slot);
            vm.prank(player);
            t.claim(id);
            assertEq(vault.balanceOf(player), owed, "claim differs from entitlement");
            vm.prank(player);
            vm.expectRevert();
            t.claim(id);
        }
        vm.prank(COLLECTOR);
        t.claimFees(id);
        assertEq(vault.balanceOf(COLLECTOR), t.payoutInfo(id)[7], "wrong fee paid");
        assertEq(vault.balanceOf(address(t)), t.payoutInfo(id)[8], "unclaimed player shares");
        _assertHoldingsCoverDebts();
    }

    function testGasFinalizeAndBeginRoundWith1024Entrants() public {
        uint256 id = _ready(1024, P);
        uint256 before;
        uint256 updates;
        address updated;
        MerkleBracket.Tree memory tree;
        while (true) {
            uint256[18] memory info = _info(id);
            if (info[STAGE] == WINDOW_STAGE) {
                if (info[ROUND] > 0) {
                    uint256 winnerSlot = t.bracketMatch(id, info[CAPACITY] >> info[ROUND])[1];
                    address winner = address(uint160(t.entryInfo(id, winnerSlot - 1)[0]));
                    if (updated == address(0)) updated = winner;
                    require(winner == updated, "deterministic winner changed");
                    vm.prank(winner);
                    t.updateModel(id, 70000 + updates);
                    ++updates;
                    require(t.entryInfo(id, winnerSlot - 1)[4] == updates * (P / 10), "cumulative update charge");
                }
                _draw(id);
                if (_info(id)[ROUND] == 1) tree = _tree(id);
            } else if (info[ROUND] == info[ROUNDS] && info[PENDING] == 0) {
                vm.cool(address(t));
                vm.cool(address(vault));
                before = gasleft();
                t.finalize(id);
                emit log_named_uint("cold finalize 1024 entrants", before - gasleft());
                break;
            } else {
                _playRound(id, tree);
            }
        }
        require(updates == 7 && t.entryInfo(id, t.slotOf(id, updated) - 1)[4] == 7 * (P / 10), "seven update windows");
        require(oracle.nextId() == 8, "eight draws at 1024");
        require(before - gasleft() < 16_000_000, "fits a block");
        _assertMatchesReference(id);
    }

    function testPrincipalArithmeticBoundaryAndLargePrincipalClaims() public {
        for (uint256 capacity = 4; capacity <= 1024; capacity *= 2) {
            uint256 principal = type(uint256).max / capacity;
            vm.expectRevert();
            _create(capacity, principal + 1);
            uint256 boundaryId = _create(capacity, principal);
            assertEq(_info(boundaryId)[CAPACITY], capacity);
            assertEq(_info(boundaryId)[COUNT], 0);
        }
        uint256 id = _ready(4, 1_000_000 ether + 1);
        _playAll(id);
        assertEq(_info(id)[PHASE], SETTLED);
        _assertMatchesReference(id);
        _claimAll(id, 4);
        vm.prank(COLLECTOR);
        t.claimFees(id);
        assertEq(_sharesPaid(4) + vault.balanceOf(COLLECTOR), _info(id)[SHARES]);
        assertEq(t.accounting()[1], 0);
        assertEq(vault.balanceOf(address(t)), 0);
    }

    function testCreationRejectsInvalidSettings() public {
        vm.expectRevert();
        t.createTournament(2, 0, ENTRY, FUND, WINDOW, TURN);
        vm.expectRevert();
        t.createTournament(4, 0, ENTRY, FUND, 59, TURN);
        vm.expectRevert();
        t.createTournament(4, 0, ENTRY, FUND, 86401, TURN);
        uint256[5] memory settings = t.settings();
        require(
            keccak256(abi.encode(settings))
                == keccak256(
                    abi.encode(
                        [
                            uint256(uint160(address(arena))),
                            uint256(uint160(address(vault))),
                            uint256(uint160(address(weth))),
                            uint256(uint160(address(oracle))),
                            uint256(uint160(COLLECTOR))
                        ]
                    )
                ),
            "controller dependencies"
        );
        uint256 id = _create(4, P);
        uint256[5] memory c = t.tournamentConfig(id);
        require(c[3] == WINDOW && c[2] == FUND, "config");
    }

    function testEntryMustPayExactlyAndRosterLocksWhenFull() public {
        uint256 id = _create(4, P);
        vm.deal(_player(0), 10 ether);
        vm.prank(_player(0));
        vm.expectRevert(bytes("Wrong payment"));
        t.join{value: P + 1}(id, _commitment(0));
        weth.setSkipMint(true);
        vm.prank(_player(0));
        vm.expectRevert();
        t.join{value: P}(id, _commitment(0));
        weth.setSkipMint(false);
        _fill(id, 4, P);
        require(_info(id)[PHASE] == AWAITING_FUNDING, "locked for funding");
        vm.expectRevert();
        t.requestDraw(id);
        t.fund(id);
        require(_info(id)[PHASE] == RUNNING && vault.balanceOf(address(t)) == 4 * P, "funded");
        _assertHoldingsCoverDebts();
    }

    function testUnfundedRosterCancelsAndRefundsCash() public {
        uint256 id = _create(4, P);
        _fill(id, 4, P);
        vm.warp(_info(id)[FUND_BY] + 1);
        vm.expectRevert();
        t.fund(id);
        t.cancel(id);
        _claimAll(id, 4);
        for (uint256 i; i < 4; i++) {
            require(t.creditOf(_player(i)) == P, "refund");
            vm.prank(_player(i));
            t.withdraw(_player(i));
        }
        require(t.accounting()[0] == 0, "no cash debts");
        _assertHoldingsCoverDebts();
    }

    function testCreatorStartsOrCancelsUnderfilledRosterAfterAdmissions() public {
        uint256 id = _create(1024, 0);
        _fill(id, 16, 0);
        vm.expectRevert();
        t.start(id);
        vm.warp(_info(id)[ENTRY_END] + 1);
        vm.prank(_player(0));
        vm.expectRevert();
        t.start(id);
        t.start(id);
        require(_info(id)[CAPACITY] == 16 && _info(id)[PHASE] == RUNNING, "locked at 16");
        uint256 small = _create(8, P);
        _fill(small, 3, P);
        vm.warp(_info(small)[ENTRY_END] + 1);
        t.cancel(small);
        _claimAll(small, 3);
        require(t.creditOf(_player(2)) == P, "refund");
    }

    function testEntryInfoIsEmptyOutsideTheRoster() public {
        uint256 id = _create(4, P);
        _fill(id, 3, P);
        vm.prank(_player(0));
        t.leave(id);
        require(t.entryInfo(id, 0)[0] == uint160(_player(2)), "moved");
        uint256[6] memory empty;
        assertEq(abi.encode(t.entryInfo(id, 2)), abi.encode(empty), "vacated tail reads empty");
        assertEq(abi.encode(t.entryInfo(id, type(uint256).max)), abi.encode(empty), "huge slot reads empty");
        require(t.creditOf(_player(0)) == P, "refund");
    }

    function testDepositFailureCanRetryAndReleaseGuardInSameTransaction() public {
        uint256 id = _create(4, P);
        _fill(id, 4, P);
        vault.setFailDeposit(true);
        vm.expectRevert();
        t.fund(id);
        require(_info(id)[PHASE] == AWAITING_FUNDING, "failed deposit changed phase");
        require(t.accounting()[0] == 4 * P && vault.balanceOf(address(t)) == 0, "failed deposit changed funds");
        vault.setFailDeposit(false);
        t.fund(id);
        require(t.accounting()[0] == 0 && vault.balanceOf(address(t)) == 4 * P, "retry did not deposit once");
        t.requestDraw(id);
        require(_info(id)[STAGE] == DRAWING, "guard not released after successful deposit");
    }

    function testVaultCannotReenterDuringDeposit() public {
        vault.setAttack(t);
        _ready(4, P);
        require(vault.attackAttempts() == 1 && !vault.attackSucceeded(), "deposit callback must run and fail");
    }

    function testPlainEthIsAcceptedOnlyFromWrappedEth() public {
        (bool ok,) = address(t).call{value: 1}("");
        require(!ok, "plain ETH refused");
    }

    function testReadyResultCannotAbortAndRoundBarrierWaitsForEveryMatch() public {
        uint256 id = _ready(16, P);
        t.requestDraw(id);
        oracle.fulfill(oracle.nextId(), 0);
        vm.warp(block.timestamp + 30 days);
        vm.expectRevert();
        t.abort(id);
        t.beginRound(id);
        MerkleBracket.Tree memory tree = _tree(id);
        for (uint256 i = 8; i < 16; ++i) {
            (uint256 a, uint256 b, uint256[9] memory sib) = MerkleBracket.proof(tree, i);
            t.openMatch(id, i, a, b, sib);
            if (i < 15) _finishArena(id, i);
        }
        require(_info(id)[ROUND] == 1 && _info(id)[PENDING] == 1 && _info(id)[STAGE] == ACTIVE, "barrier passed early");
        vm.expectRevert();
        t.advance(id, 4);
        vm.expectRevert();
        t.requestDraw(id);
        _finishArena(id, 15);
        require(
            _info(id)[STAGE] == WINDOW_STAGE && _info(id)[UNTIL] == block.timestamp + WINDOW,
            "last result did not open window"
        );
        (address winner,) = _winnerAndLoser(id, 8);
        vm.warp(_info(id)[UNTIL]);
        vm.prank(winner);
        vm.expectRevert();
        t.updateModel(id, 9876);
        t.requestDraw(id);
        vm.prank(winner);
        vm.expectRevert();
        t.updateModel(id, 9876);
    }

    function testMerkleTamperingAtFullDepthAndReplayAreRejected() public {
        uint256 id = _ready(1024, 0);
        _draw(id);
        MerkleBracket.Tree memory tree = _tree(id);
        uint256 index = 987;
        (uint256 a, uint256 b, uint256[9] memory good) = MerkleBracket.proof(tree, index);
        for (uint256 j; j < 9; ++j) {
            uint256[9] memory bad = good;
            bad[j] ^= 1;
            vm.expectRevert();
            t.openMatch(id, index, a, b, bad);
            bad[j] ^= 1;
        }
        vm.expectRevert();
        t.openMatch(id, index, b, a, good);
        vm.expectRevert();
        t.openMatch(id, index, a, a, good);
        vm.expectRevert();
        t.openMatch(id, index, 1025, b, good);
        vm.expectRevert();
        t.openMatch(id, index + 1, a, b, good);
        vm.expectRevert();
        t.openMatch(id, 511, a, b, good);
        vm.expectRevert();
        t.openMatch(id, 1024, a, b, good);
        uint256 other = _ready(1024, 0);
        _draw(other);
        vm.expectRevert();
        t.openMatch(other, index, a, b, good);
        t.openMatch(id, index, a, b, good);
        vm.expectRevert();
        t.openMatch(id, index, a, b, good);
        require(_info(id)[PENDING] == 512, "bad proof changed pending count");
    }

    function testMerklePaddingAndVacanciesAreBound() public {
        uint256 id = _create(32, 0);
        _fill(id, 17, 0);
        vm.warp(_info(id)[ENTRY_END] + 1);
        t.start(id);
        _draw(id);
        MerkleBracket.Tree memory tree = _tree(id);
        for (uint256 index = 16; index < 32; ++index) {
            (uint256 a, uint256 b, uint256[9] memory good) = MerkleBracket.proof(tree, index);
            uint256[9] memory bad = good;
            bad[4] = 1;
            vm.expectRevert();
            t.openMatch(id, index, a, b, bad);
            bad[4] = 0;
            if (a == 0 || b == 0) {
                vm.expectRevert();
                t.openMatch(id, index, a == 0 ? 1 : a, b == 0 ? 1 : b, good);
            }
            t.openMatch(id, index, a, b, good);
        }
    }

    function _assertClaimEvent(uint256 id, uint256 slot) private view {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(t)) continue;
            assertEq(logs[i].topics.length, 2);
            assertEq(logs[i].topics[0], keccak256("EntryClaimed(uint256,uint256)"));
            assertEq(logs[i].topics[1], bytes32(id));
            assertEq(logs[i].data, abi.encode(slot));
            assertEq(i, logs.length - 1, "claim event must follow external transfer logs");
            ++count;
        }
        assertEq(count, 1, "exactly one claim event");
    }

    function _assertNoClaimEvent() private view {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertFalse(
                logs[i].emitter == address(t) && logs[i].topics[0] == keccak256("EntryClaimed(uint256,uint256)"),
                "failed claim emitted claim event"
            );
        }
    }

    function testEntryClaimedEventsForShareAndZeroEntitlements() public {
        for (uint256 principal; principal <= P; principal += P) {
            uint256 id = _ready(4, principal);
            _playAll(id);
            for (uint256 i; i < 4; ++i) {
                uint256 storedSlot = t.slotOf(id, _player(i));
                uint256 amount = t.entitlement(id, storedSlot - 1);
                uint256 before = vault.balanceOf(_player(i));
                vm.recordLogs();
                vm.prank(_player(i));
                t.claim(id);
                _assertClaimEvent(id, storedSlot - 1);
                assertEq(t.entryInfo(id, storedSlot - 1)[3], 1);
                assertEq(vault.balanceOf(_player(i)) - before, amount);
                vm.recordLogs();
                vm.prank(_player(i));
                vm.expectRevert(bytes("Already claimed"));
                t.claim(id);
                _assertNoClaimEvent();
            }
        }
    }

    function testEntryClaimedEventsForCancelledCashRefunds() public {
        uint256 id = _create(4, P);
        _fill(id, 4, P);
        vm.warp(_info(id)[FUND_BY] + 1);
        t.cancel(id);
        for (uint256 i; i < 4; ++i) {
            uint256 storedSlot = t.slotOf(id, _player(i));
            vm.recordLogs();
            vm.prank(_player(i));
            t.claim(id);
            _assertClaimEvent(id, storedSlot - 1);
            assertEq(t.creditOf(_player(i)), P);
            assertEq(t.entryInfo(id, storedSlot - 1)[3], 1);
        }
    }

    function testShareClaimFailurePreservesEntitlementAndFeeClaim() public {
        uint256 id = _ready(4, P);
        vault.setRate(110, 100);
        _playAll(id);
        uint256 owed = t.accounting()[1];
        uint256 playerShares = t.entitlement(id, 0);
        vault.setFakeTransfers(true);
        vm.recordLogs();
        vm.prank(_player(0));
        vm.expectRevert();
        t.claim(id);
        _assertNoClaimEvent();
        require(
            t.entryInfo(id, 0)[3] == 0 && t.accounting()[1] == owed && vault.balanceOf(_player(0)) == 0,
            "failed claim consumed entitlement"
        );
        vm.prank(COLLECTOR);
        vm.expectRevert();
        t.claimFees(id);
        require(t.accounting()[1] == owed && vault.balanceOf(COLLECTOR) == 0, "failed fee consumed entitlement");
        vault.setFakeTransfers(false);
        vm.recordLogs();
        vm.prank(_player(0));
        t.claim(id);
        _assertClaimEvent(id, 0);
        require(vault.balanceOf(_player(0)) == playerShares && t.accounting()[1] == owed - playerShares, "claim retry");
        vm.prank(_player(0));
        vm.expectRevert(bytes("Already claimed"));
        t.claim(id);
        vm.prank(COLLECTOR);
        t.claimFees(id);
    }

    function testUnusableQuotesPreserveShareClaims() public {
        for (uint256 kind; kind < 4; ++kind) {
            uint256 id = _ready(4, P);
            if (kind == 3) vault.setPreview(true, false, 0);
            else if (kind == 0) vault.setMalformedPreview(true);
            else vault.setPreview(false, true, kind == 1 ? 0 : 1 << 128);
            _playAll(id);
            require(t.payoutInfo(id)[0] == 4 * P && t.payoutInfo(id)[7] == 0, "unusable quote invented yield");
            for (uint256 i; i < 4; ++i) {
                require(t.entitlement(id, i) == P, "pro rata fallback");
            }
            _claimAll(id, 4);
            vm.prank(COLLECTOR);
            t.claimFees(id);
            vault.setMalformedPreview(false);
            vault.setPreview(false, false, 0);
        }
        _assertHoldingsCoverDebts();
    }

    function testTournamentLossAndClaimsNeverSpendAnotherTournamentShares() public {
        uint256 first = _ready(16, P);
        uint256 second = _ready(4, P);
        vault.setRate(1, 2);
        _playAll(first);
        require(vault.balanceOf(address(t)) == 20 * P, "holdings changed by settlement");
        uint256[] memory frozen = new uint256[](16);
        for (uint256 i; i < 16; ++i) {
            frozen[i] = t.entitlement(first, i);
        }
        _claimAll(first, 16);
        vm.prank(COLLECTOR);
        t.claimFees(first);
        require(vault.balanceOf(address(t)) == 4 * P, "first consumed second shares");
        vault.setRate(110, 100);
        _playAll(second);
        uint256 beforeFee = vault.balanceOf(COLLECTOR);
        for (uint256 i; i < 4; ++i) {
            uint256 before = vault.balanceOf(_player(i));
            uint256 entitlement = t.entitlement(second, i);
            vm.prank(_player(i));
            t.claim(second);
            require(vault.balanceOf(_player(i)) == before + entitlement, "second wrong amount");
        }
        uint256 secondFee = t.payoutInfo(second)[7];
        assertGt(secondFee, 0, "second fee must exercise collection");
        vm.prank(COLLECTOR);
        t.claimFees(second);
        require(
            vault.balanceOf(COLLECTOR) == beforeFee + secondFee && t.accounting()[1] == 0
                && vault.balanceOf(address(t)) == 0,
            "cross tournament conservation"
        );
        for (uint256 i; i < 16; ++i) {
            require(t.entitlement(first, i) == frozen[i], "later valuation changed earlier allocation");
        }
    }

    function testVeryLargeVaultSharesAreFullyAssignedWithoutOverflow() public {
        uint256 shares = type(uint256).max;
        vault.setMintedShares(shares);
        uint256 id = _ready(4, P);
        _spec(2, 2, true);
        _playAll(id);
        require(_info(id)[SHARES] == shares && _info(id)[FORFEITS] == 1, "large shares recorded");
        uint256 sum = t.payoutInfo(id)[7] + t.payoutInfo(id)[8];
        for (uint256 i; i < 4; ++i) {
            sum += t.entitlement(id, i);
        }
        require(sum == shares && t.payoutInfo(id)[7] > 0, "large share allocation");
        _claimAll(id, 4);
        vm.prank(COLLECTOR);
        t.claimFees(id);
        require(vault.balanceOf(address(t)) == 0 && t.accounting()[1] == 0, "large share claims");
    }

    function testUnderfilledSeventeenEntrantsFinishWithByesAndNoFalseForfeits() public {
        uint256 id = _create(1024, P);
        _fill(id, 17, P);
        vm.warp(_info(id)[ENTRY_END] + 1);
        t.start(id);
        t.fund(id);
        require(_info(id)[CAPACITY] == 32, "effective bracket size");
        _playAll(id);
        require(_info(id)[PHASE] == SETTLED && _info(id)[FORFEITS] == 0 && arena.next() == 32, "bye lifecycle");
        _assertMatchesReference(id);
        _claimAll(id, 17);
        vm.prank(COLLECTOR);
        t.claimFees(id);
        require(vault.balanceOf(address(t)) == 0 && t.accounting()[1] == 0, "underfilled conservation");
    }
}
