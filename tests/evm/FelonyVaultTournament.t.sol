// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IFelonyGame, ITournament} from "../Interfaces.sol";
import {BindingVerifierMock, GameFeeReceiver} from "../mocks/GameMocks.sol";
import {RandomOracleMock} from "../mocks/RandomOracleMock.sol";
import {StipendWrappedNative} from "../mocks/StipendWrappedNative.sol";
import {StandardVaultMock} from "../mocks/VaultMocks.sol";
import {MerkleBracket} from "./MerkleBracket.sol";

contract FelonyVaultTournamentTest is Test {
    uint256 private constant PRINCIPAL = 1 ether;
    IFelonyGame private game;
    ITournament private tournament;
    BindingVerifierMock private verifier;
    StipendWrappedNative private asset;
    StandardVaultMock private vault;
    RandomOracleMock private oracle;
    GameFeeReceiver private collector;
    address[] private players;
    mapping(address => uint256) private models;
    uint256 private submissions;

    function _deploy(string memory path, bytes memory args) private returns (address deployed) {
        bytes memory creation = abi.encodePacked(vm.readFileBinary(path), args);
        require(creation.length <= 49152, "EIP3860 initcode limit");
        assembly { deployed := create(0, add(creation, 32), mload(creation)) }
        require(
            deployed != address(0) && deployed.code.length > 0 && deployed.code.length <= 24576,
            "production deployment/code size"
        );
    }

    function _setup(uint256 count) private {
        vm.warp(1000);
        verifier = new BindingVerifierMock();
        oracle = new RandomOracleMock();
        collector = new GameFeeReceiver();
        game = IFelonyGame(
            _deploy(
                "artifacts/game.bin", abi.encode(address(verifier), address(oracle), address(collector), uint256(60))
            )
        );
        asset = new StipendWrappedNative();
        vault = new StandardVaultMock(address(asset));
        tournament = ITournament(
            _deploy(
                "artifacts/tournament.bin",
                abi.encode(address(game), address(vault), address(asset), address(oracle), address(collector))
            )
        );
        vm.deal(address(asset), 1000 ether);
        for (uint256 i; i < count; ++i) {
            address p = address(uint160(0x1000 + i));
            players.push(p);
            vm.deal(p, 100 ether);
            models[p] = 111 + i;
        }
    }

    function _register() private returns (uint256 id) {
        id = tournament.createTournament(players.length, PRINCIPAL, 60, 3600, 600, 60);
        for (uint256 i; i < players.length; ++i) {
            address p = players[i];
            vm.prank(p);
            tournament.join{value: PRINCIPAL}(id, models[p]);
        }
        require(tournament.accounting()[0] == players.length * PRINCIPAL, "entry liability");
        require(
            asset.balanceOf(address(tournament)) == players.length * PRINCIPAL && address(tournament).balance == 0,
            "entries not wrapped"
        );
        require(tournament.tournamentInfo(id)[0] == 2, "roster not locked");
    }

    function _enter() private returns (uint256 id) {
        id = _register();
        tournament.fund(id);
        uint256 amount = players.length * PRINCIPAL;
        require(vault.balanceOf(address(tournament)) == amount && vault.totalSupply() == amount, "deposit shares");
        require(
            vault.allowanceAtDeposit() == amount && asset.allowance(address(tournament), address(vault)) == 0,
            "exact/reset approval"
        );
        require(tournament.accounting()[0] == 0 && asset.balanceOf(address(tournament)) == 0, "principal invested");
        _draw(id);
    }

    function _draw(uint256 id) private {
        uint256 until = tournament.tournamentInfo(id)[8];
        if (block.timestamp < until) vm.warp(until);
        tournament.requestDraw(id);
        uint256 request = tournament.tournamentInfo(id)[9];
        oracle.fulfill(request, 123456 + request);
        tournament.beginRound(id);
    }

    function _tree(uint256 id) private view returns (MerkleBracket.Tree memory) {
        uint256[18] memory info = tournament.tournamentInfo(id);
        return MerkleBracket.build(block.chainid, address(tournament), id, tournament.drawWord(id, 0), info[2], info[1]);
    }

    function _match(uint256 id, uint256 node) private {
        uint256[18] memory info = tournament.tournamentInfo(id);
        if (info[6] == 1) {
            (uint256 s0, uint256 s1, uint256[9] memory sib) = MerkleBracket.proof(_tree(id), node);
            tournament.openMatch(id, node, s0, s1, sib);
        } else {
            tournament.advance(id, node);
        }
        uint256[4] memory m = tournament.bracketMatch(id, node);
        if (m[0] == 2) return;
        uint256 matchId = m[3];
        require(matchId == game.managedMatchId(address(tournament), id, node), "fixed match ID");
        uint256[18] memory state = game.matchInfo(matchId);
        address[2] memory seats = [address(uint160(state[0])), address(uint160(state[1]))];
        uint256 draw = info[6] < tournament.roundInfo(id)[6] ? info[6] : tournament.roundInfo(id)[6];
        uint256 seed =
            MerkleBracket.matchSeed(block.chainid, address(tournament), id, node, tournament.drawWord(id, draw));
        require(state[6] == 3 && state[9] == seed && state[7] == block.timestamp + 60, "managed immediate seed/window");
        _play(matchId, seats, seed);
        require(game.matchInfo(matchId)[6] == 4 && game.matchInfo(matchId)[14] == 3, "automatic last card");
        tournament.advance(id, node);
        uint256[4] memory resolved = tournament.bracketMatch(id, node);
        require(resolved[0] == 2, "Arena result not consumed");
        uint256 coin = uint256(keccak256(abi.encode(uint256(504), seed))) % 2;
        assertEq(resolved[1], tournament.slotOf(id, seats[coin]), "all-burn coin winner");
        assertEq(resolved[2], tournament.slotOf(id, seats[1 - coin]), "sporting loser retained");
    }

    function _playRound(uint256 id) private {
        uint256[18] memory info = tournament.tournamentInfo(id);
        if (info[6] == info[17]) {
            _match(id, 1);
            _match(id, 0);
            return;
        }
        uint256 first = info[1] >> info[6];
        for (uint256 i = first; i < 2 * first; ++i) {
            _match(id, i);
        }
    }

    function _finish(uint256 id) private {
        while (true) {
            uint256[18] memory info = tournament.tournamentInfo(id);
            if (info[7] == 0) _draw(id);
            else if (info[6] == info[17] && info[10] == 0) break;
            else _playRound(id);
        }
        tournament.finalize(id);
        require(tournament.tournamentInfo(id)[0] == 4, "settlement phase");
        require(
            game.liabilities() == 0 && address(game).balance == 0 && game.creditOf(address(collector)) == 0,
            "managed Arena fee/escrow"
        );
    }

    function _claimAll(uint256 id) private returns (uint256 sum) {
        for (uint256 i; i < players.length; ++i) {
            uint256 shares = tournament.entitlement(id, i);
            vm.prank(players[i]);
            tournament.claim(id);
            require(vault.balanceOf(players[i]) == shares && tournament.creditOf(players[i]) == 0, "share delivery");
            sum += shares;
        }
        vm.prank(address(collector));
        tournament.claimFees(id);
        sum += vault.balanceOf(address(collector));
        require(
            sum == players.length * PRINCIPAL && tournament.accounting()[1] == 0
                && vault.balanceOf(address(tournament)) == 0,
            "share conservation"
        );
    }

    function _prize(uint256 loot, uint256 seed, uint256 round) private pure returns (uint256) {
        uint256 count;
        for (uint256 i; i < 9; ++i) {
            if ((loot & (1 << i)) != 0) ++count;
        }
        uint256 nth = uint256(keccak256(abi.encode(uint256(204), uint256(1), seed, round))) % count;
        for (uint256 i; i < 9; ++i) {
            if ((loot & (1 << i)) != 0) {
                if (nth == 0) return i + 1;
                --nth;
            }
        }
        revert("empty prize set");
    }

    function _submit(uint256 matchId, address p, uint256 seat, uint256 seed, uint256 round, uint256 packed) private {
        uint256[9] memory words =
            [models[p], packed, block.chainid, uint256(uint160(address(game))), matchId, seat, round, seed, round];
        bytes32 expected = keccak256(abi.encode(words));
        require(
            keccak256(abi.encode(game.proofInputs(matchId, seat, round))) == expected,
            "independent proof input mismatch"
        );
        verifier.configure(expected, 0);
        vm.prank(p);
        game.submitMove(matchId, round, new bytes(9152));
        ++submissions;
    }

    function _play(uint256 matchId, address[2] memory seats, uint256 seed) private {
        uint256 hand = 511;
        uint256 loot = 511;
        uint256 history;

        for (uint256 round; round < 8; ++round) {
            uint256 prize = _prize(loot, seed, round);
            uint256 packed = hand | (hand << 9) | (loot << 18) | (prize << 27) | (uint256(45) << 31) | (history << 38)
                | (history << 74);
            for (uint256 seat; seat < 2; ++seat) {
                _submit(matchId, seats[seat], seat, seed, round, packed);
            }
            hand ^= 1 << round;
            loot ^= 1 << (prize - 1);
            history |= (round + 1) << (4 * (prize - 1));
        }
    }

    function testActualArenaTournamentSharesAndOwnerRedemption() public {
        _setup(4);
        uint256 id = _enter();
        asset.mint(address(vault), 0.4 ether);
        vault.setRate(11e17);
        _finish(id);
        require(submissions == 64 && oracle.nextId() == 1, "match and draw counts");
        uint256[18] memory info = tournament.tournamentInfo(id);
        uint256[4] memory expected;
        uint256 feeShares = uint256(0.02 ether) * 10 / 11;
        uint256 total = feeShares;
        for (uint256 i; i < 4; ++i) {
            expected[i] = PRINCIPAL * 10 / 11;
            if (i + 1 == info[13]) expected[i] += uint256(0.19 ether) * 10 / 11;
            if (i + 1 == info[14]) expected[i] += uint256(0.114 ether) * 10 / 11;
            if (i + 1 == info[15]) expected[i] += uint256(0.076 ether) * 10 / 11;
            total += expected[i];
        }
        expected[0] += 4 * PRINCIPAL - total;
        for (uint256 i; i < 4; ++i) {
            require(tournament.entitlement(id, i) == expected[i], "50/30/20 net yield allocation");
        }
        require(tournament.payoutInfo(id)[7] == feeShares, "5 percent yield fee");
        _claimAll(id);
        for (uint256 i; i < 4; ++i) {
            vm.prank(players[i]);
            uint256 received = vault.redeem(expected[i], players[i], players[i]);
            require(received == expected[i] * 11 / 10 && asset.balanceOf(players[i]) == received, "owner redemption");
        }
        vm.prank(address(collector));
        vault.redeem(feeShares, address(collector), address(collector));
        require(vault.totalSupply() == 0 && tournament.accounting()[0] == 0, "final conservation");
    }

    function testSharesCanBeClaimedWhileRedemptionIsUnavailable() public {
        _setup(4);
        uint256 id = _enter();
        vault.setRate(11e17);
        _finish(id);
        vm.prank(address(tournament));
        vm.expectRevert();
        vault.redeem(4 * PRINCIPAL, address(tournament), address(tournament));
        _claimAll(id);

        uint256 shares = vault.balanceOf(players[0]);
        asset.mint(address(vault), 1 ether);
        vault.setRate(12e17);
        vm.prank(players[0]);
        uint256 received = vault.redeem(shares, players[0], players[0]);
        require(received == shares * 12 / 10, "later direct redemption");
        require(tournament.tournamentInfo(id)[0] == 4, "redemption changed tournament");
    }

    function testRealArenaUsesUpdatedCommitmentOnlyAfterRoundWindow() public {
        _setup(16);
        uint256 id = _enter();
        _playRound(id);
        uint256 winnerSlot = tournament.bracketMatch(id, 8)[1];
        address winner = players[winnerSlot - 1];
        vm.prank(winner);
        tournament.updateModel(id, 777777);
        models[winner] = 777777;
        require(tournament.entryInfo(id, winnerSlot - 1)[4] == PRINCIPAL / 10, "update deduction");
        _finish(id);
        require(submissions == 256 && oracle.nextId() == 2, "full updated tournament");
        uint256 sum;
        for (uint256 i; i < 16; ++i) {
            sum += tournament.entryInfo(id, i)[4];
        }
        require(sum == PRINCIPAL / 10 + 12 * (PRINCIPAL / 40), "update plus twelve ordinary losses");
        _claimAll(id);
    }

    function _openPair(uint256 id, uint256 index) private {
        (uint256 s0, uint256 s1, uint256[9] memory siblings) = MerkleBracket.proof(_tree(id), index);
        tournament.openMatch(id, index, s0, s1, siblings);
    }

    function testPostDrawCounterGrindingAndOpeningOrderCannotChangeProofInputs() public {
        _setup(4);
        uint256 id = _register();
        uint256 first = game.managedMatchId(address(tournament), id, 0);
        require(first != 0 && oracle.nextId() == 0, "IDs not reserved before randomness");
        require(game.matchInfo(first + 2)[6] == 0, "reservation started a deadline");
        tournament.fund(id);
        _draw(id);
        uint256 snapshot = vm.snapshotState();
        _openPair(id, 2);
        uint256 ordinary = tournament.bracketMatch(id, 2)[3];
        uint256[9] memory expected = game.proofInputs(ordinary, 0, 0);
        require(vm.revertToState(snapshot), "snapshot restore");
        address attacker = address(0xBAD);
        vm.prank(attacker);
        game.reserveManagedMatches(999, 36);
        for (uint256 i; i < 36; ++i) {
            vm.prank(attacker);
            game.createManagedMatch(address(0xA), address(0xB), 1, 2, 999, 123, 60, i);
        }
        vm.prank(attacker);
        game.createChallenge(address(0xC), 1, 0, 60);
        _openPair(id, 3);
        _openPair(id, 2);
        uint256 selected = tournament.bracketMatch(id, 2)[3];
        require(selected == ordinary && selected == first + 2, "post-draw ID grinding");
        uint256[9] memory actual = game.proofInputs(selected, 0, 0);
        for (uint256 i; i < 9; ++i) {
            require(actual[i] == expected[i], "proof context changed");
        }
        require(game.managedMatchId(address(tournament), id, 0) == first, "playoff ID moved");
        require(game.managedMatchId(address(tournament), id, 1) == first + 1, "final ID moved");
    }

    function testUnderfilledRosterReservesActualBracketBeforeFunding() public {
        _setup(17);
        uint256 id = tournament.createTournament(1024, PRINCIPAL, 60, 3600, 600, 60);
        for (uint256 i; i < players.length; ++i) {
            vm.prank(players[i]);
            tournament.join{value: PRINCIPAL}(id, models[players[i]]);
        }
        vm.expectRevert();
        game.managedMatchId(address(tournament), id, 0);
        vm.warp(tournament.tournamentInfo(id)[4] + 1);
        tournament.start(id);
        require(tournament.tournamentInfo(id)[1] == 32 && oracle.nextId() == 0, "actual bracket lock");
        uint256 first = game.managedMatchId(address(tournament), id, 0);
        require(game.managedMatchId(address(tournament), id, 31) == first + 31, "actual reservation size");
        vm.expectRevert();
        game.managedMatchId(address(tournament), id, 32);
        vm.expectRevert();
        tournament.start(id);
        tournament.fund(id);
        _draw(id);
        require(game.managedMatchId(address(tournament), id, 31) == first + 31, "fund/draw changed IDs");
    }

    function testFundingPrecedesDrawAndUnfundedRosterRefundsNativeEth() public {
        _setup(4);
        uint256 id = _register();
        vm.expectRevert();
        tournament.requestDraw(id);
        vm.warp(tournament.tournamentInfo(id)[5] + 1);
        tournament.cancel(id);
        for (uint256 i; i < 4; ++i) {
            vm.prank(players[i]);
            tournament.claim(id);
            require(tournament.creditOf(players[i]) == PRINCIPAL, "unfunded refund");
            uint256 balance = players[i].balance;
            vm.prank(players[i]);
            tournament.withdraw(players[i]);
            require(players[i].balance == balance + PRINCIPAL, "WETH stipend delivery");
        }
        require(tournament.accounting()[0] == 0 && asset.balanceOf(address(tournament)) == 0, "refund conservation");
    }

    function testReadyOracleCannotBeAbortedAfterLongDelay() public {
        _setup(4);
        uint256 id = _register();
        tournament.fund(id);
        tournament.requestDraw(id);
        uint256 request = tournament.tournamentInfo(id)[9];
        oracle.fulfill(request, 0);
        vm.warp(block.timestamp + 30 days);
        vm.expectRevert();
        tournament.abort(id);
        tournament.beginRound(id);
        _finish(id);
        _claimAll(id);
    }

    function testOfficialWethTournamentEntryAndNativeRefund() public {
        string memory url = vm.envOr("FELONY_AAVE_RPC_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
        uint256 forkBlock = vm.envOr("FELONY_AAVE_BLOCK", uint256(26_444_402));
        if (forkBlock == 0) {
            vm.createSelectFork(url);
        } else {
            vm.createSelectFork(url, forkBlock);
        }
        emit log_named_uint("Ethereum fork block", block.number);
        address weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        address stata = 0x0bfc9d54Fc184518A81162F8fB99c2eACa081202;
        verifier = new BindingVerifierMock();
        oracle = new RandomOracleMock();
        collector = new GameFeeReceiver();
        game = IFelonyGame(
            _deploy(
                "artifacts/game.bin", abi.encode(address(verifier), address(oracle), address(collector), uint256(60))
            )
        );
        tournament = ITournament(
            _deploy(
                "artifacts/tournament.bin", abi.encode(address(game), stata, weth, address(oracle), address(collector))
            )
        );
        address player = address(0x123456);
        vm.deal(player, 10 ether);
        uint256 id = tournament.createTournament(4, PRINCIPAL, 60, 3600, 600, 60);
        vm.prank(player);
        tournament.join{value: PRINCIPAL}(id, 777);
        vm.warp(tournament.tournamentInfo(id)[4] + 1);
        vm.prank(player);
        tournament.leave(id);
        uint256 balance = player.balance;
        vm.prank(player);
        tournament.withdraw(player);
        require(
            player.balance == balance + PRINCIPAL && tournament.accounting()[0] == 0
                && StipendWrappedNative(weth).balanceOf(address(tournament)) == 0,
            "real WETH refund"
        );
    }

    function testOfficialVaultTournamentSettlementAndDirectRedemption() public {
        string memory url = vm.envOr("FELONY_AAVE_RPC_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
        uint256 forkBlock = vm.envOr("FELONY_AAVE_BLOCK", uint256(26_444_402));
        if (forkBlock == 0) {
            vm.createSelectFork(url);
        } else {
            vm.createSelectFork(url, forkBlock);
        }
        emit log_named_uint("Ethereum fork block", block.number);
        require(block.chainid == 1, "Ethereum fork");
        address weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        address stata = 0x0bfc9d54Fc184518A81162F8fB99c2eACa081202;
        verifier = new BindingVerifierMock();
        oracle = new RandomOracleMock();
        collector = new GameFeeReceiver();
        game = IFelonyGame(
            _deploy(
                "artifacts/game.bin", abi.encode(address(verifier), address(oracle), address(collector), uint256(60))
            )
        );
        asset = StipendWrappedNative(weth);
        vault = StandardVaultMock(stata);
        tournament = ITournament(
            _deploy(
                "artifacts/tournament.bin", abi.encode(address(game), stata, weth, address(oracle), address(collector))
            )
        );
        require(vault.asset() == weth, "vault underlying");
        for (uint256 i; i < 4; ++i) {
            address p = address(uint160(0x1000 + i));
            players.push(p);
            models[p] = 111 + i;
            vm.deal(p, 2 ether);
        }
        uint256 id = _register();
        tournament.fund(id);
        uint256 shares = tournament.tournamentInfo(id)[11];
        require(shares > 0 && vault.balanceOf(address(tournament)) == shares, "measured position");
        require(asset.allowance(address(tournament), stata) == 0, "approval cleared");
        _draw(id);
        vm.warp(block.timestamp + 1 days);
        _finish(id);
        uint256 assigned;
        for (uint256 i; i < 4; ++i) {
            uint256 amount = tournament.entitlement(id, i);
            vm.prank(players[i]);
            tournament.claim(id);
            require(vault.balanceOf(players[i]) == amount, "share claim");
            assigned += amount;
            uint256 quote = vault.previewRedeem(amount);
            uint256 before_ = asset.balanceOf(players[i]);
            vm.prank(players[i]);
            uint256 received = vault.redeem(amount, players[i], players[i]);
            require(received == quote && asset.balanceOf(players[i]) - before_ == received, "owner redemption");
        }
        vm.prank(address(collector));
        tournament.claimFees(id);
        assigned += vault.balanceOf(address(collector));
        require(
            assigned == shares && tournament.accounting()[1] == 0 && vault.balanceOf(address(tournament)) == 0,
            "all shares assigned and released"
        );
        require(tournament.payoutInfo(id)[7] > 0, "interest fee exercised");
    }

    function testHighestCaptureOverridesCoinAndTaxesQuarterfinalLoser() public {
        _setup(8);
        uint256 id = _enter();
        {
            (uint256 a, uint256 b, uint256[9] memory siblings) = MerkleBracket.proof(_tree(id), 4);
            tournament.openMatch(id, 4, a, b, siblings);
        }
        uint256 matchId = tournament.bracketMatch(id, 4)[3];
        uint256[18] memory info = game.matchInfo(matchId);
        uint256 seed = info[9];
        uint256 coin = uint256(keccak256(abi.encode(uint256(504), seed))) % 2;

        {
            uint256[9] memory winnerBids = [uint256(6), 3, 5, 2, 1, 4, 8, 7, 9];
            uint256[9] memory loserBids = [uint256(8), 7, 2, 4, 3, 5, 6, 1, 9];
            uint256 loot = 511;
            for (uint256 r; r < 8; ++r) {
                uint256 prize = _prize(loot, seed, r);
                for (uint256 seat; seat < 2; ++seat) {
                    uint256 action = (seat != coin ? winnerBids[prize - 1] : loserBids[prize - 1]) - 1;
                    uint256[9] memory words = game.proofInputs(matchId, seat, action);
                    verifier.configure(keccak256(abi.encode(words)), 0);
                    vm.prank(address(uint160(info[seat])));
                    game.submitMove(matchId, action, new bytes(9152));
                }
                loot ^= 1 << (prize - 1);
            }
        }
        uint256[18] memory finished = game.matchInfo(matchId);
        assertEq(finished[12], 18);
        assertEq(finished[13], 18);
        assertEq(finished[14], 2 - coin);
        tournament.advance(id, 4);
        uint256 winnerSlot = tournament.slotOf(id, address(uint160(info[1 - coin])));
        uint256 loserSlot = tournament.slotOf(id, address(uint160(info[coin])));
        assertEq(tournament.bracketMatch(id, 4)[1], winnerSlot);
        assertEq(tournament.bracketMatch(id, 4)[2], loserSlot);
        assertEq(tournament.entryInfo(id, loserSlot - 1)[4], PRINCIPAL / 40, "ordinary 2.5% loss tax");
        assertEq(game.managedInfo(matchId)[1], 0);
        for (uint256 node = 5; node < 8; ++node) {
            _match(id, node);
        }
        _finish(id);
        _claimAll(id);
    }

    function testRealArenaForfeitBecomesTournamentPrincipalForfeiture() public {
        _defaultedMatch(false);
    }

    function testRealArenaTimeoutMustBeClaimedBeforeBracketAdvancement() public {
        _defaultedMatch(true);
    }

    function testBothSemifinalConcessionsLeaveNoPlayoffEntrants() public {
        _bothSemifinalsDefault(false);
    }

    function testBothSemifinalsDoubleTimeoutStillSettle() public {
        _bothSemifinalsDefault(true);
    }

    function _bothSemifinalsDefault(bool bothSeats) private {
        _setup(4);
        uint256 id = _enter();
        for (uint256 node = 2; node <= 3; ++node) {
            (uint256 a, uint256 b, uint256[9] memory siblings) = MerkleBracket.proof(_tree(id), node);
            tournament.openMatch(id, node, a, b, siblings);
            uint256 matchId = tournament.bracketMatch(id, node)[3];
            uint256[18] memory match_ = game.matchInfo(matchId);
            if (bothSeats) {
                vm.warp(match_[7] + 1);
                game.claimTimeout(matchId);
            } else {
                vm.prank(address(uint160(match_[1])));
                game.forfeit(matchId);
            }
            tournament.advance(id, node);
            require(tournament.bracketMatch(id, node)[2] == 0, "forfeiter retained as playoff feeder");
        }
        _finish(id);
        uint256[18] memory info = tournament.tournamentInfo(id);
        require(info[0] == 4 && info[10] == 0, "settlement must complete");
        require(info[12] == (bothSeats ? 4 : 2) && info[15] == 0, "forfeits and empty third place");
        uint256[4] memory playoff = tournament.bracketMatch(id, 0);
        require(playoff[0] == 2 && playoff[1] == 0 && playoff[2] == 0 && playoff[3] == 0, "no playoff game created");
        uint256 assigned = tournament.payoutInfo(id)[7] + tournament.payoutInfo(id)[8];
        for (uint256 slot; slot < 4; ++slot) {
            uint256 amount = tournament.entitlement(id, slot);
            if (tournament.entryInfo(id, slot)[2] == 2) require(amount == 0, "forfeiter paid");
            assigned += amount;
        }
        require(assigned == 4 * PRINCIPAL, "every deposited share assigned");
    }

    function _defaultedMatch(bool timeout) private {
        _setup(4);
        uint256 id = _enter();
        (uint256 a, uint256 b, uint256[9] memory sib) = MerkleBracket.proof(_tree(id), 2);
        tournament.openMatch(id, 2, a, b, sib);
        uint256 matchId = tournament.bracketMatch(id, 2)[3];
        uint256[18] memory state = game.matchInfo(matchId);
        address winner = address(uint160(state[0]));
        address loser = address(uint160(state[1]));
        if (timeout) {
            uint256[9] memory words = game.proofInputs(matchId, 0, 0);
            verifier.configure(keccak256(abi.encode(words)), 0);
            vm.prank(winner);
            game.submitMove(matchId, 0, new bytes(9152));
            vm.warp(state[7] + 1);
            vm.expectRevert();
            tournament.advance(id, 2);
            game.claimTimeout(matchId);
        } else {
            vm.prank(loser);
            game.forfeit(matchId);
        }
        tournament.advance(id, 2);
        uint256 loserSlot = tournament.slotOf(id, loser) - 1;
        require(
            tournament.entryInfo(id, loserSlot)[2] == 2 && tournament.entryInfo(id, loserSlot)[4] == 0,
            "default status/tax"
        );
        _match(id, 3);
        _match(id, 1);
        _match(id, 0);
        tournament.finalize(id);
        require(
            tournament.entitlement(id, loserSlot) == 0 && tournament.payoutInfo(id)[7] == PRINCIPAL / 20,
            "forfeit prize fee"
        );
        vm.prank(loser);
        vm.expectRevert();
        tournament.claim(id);
        uint256 sum;
        for (uint256 i; i < 4; ++i) {
            if (players[i] == loser) continue;
            uint256 owed = tournament.entitlement(id, i);
            vm.prank(players[i]);
            tournament.claim(id);
            require(vault.balanceOf(players[i]) == owed, "default settlement claim");
            sum += owed;
        }
        vm.prank(address(collector));
        tournament.claimFees(id);
        sum += vault.balanceOf(address(collector));
        require(
            sum == 4 * PRINCIPAL && tournament.accounting()[1] == 0 && game.liabilities() == 0, "default conservation"
        );
    }
}
