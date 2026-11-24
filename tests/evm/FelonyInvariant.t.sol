// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {CommonBase} from "forge-std/Base.sol";
import {Test} from "forge-std/Test.sol";
import {ITournament, IFelonyGame, RandomOracle} from "../Interfaces.sol";
import {BindingVerifierMock} from "../mocks/GameMocks.sol";
import {CoordinatorMock} from "../mocks/OracleMocks.sol";
import {MockWETH, MockVault} from "../mocks/TournamentMocks.sol";
import {MerkleBracket} from "./MerkleBracket.sol";

contract FelonyHandler is CommonBase {
    uint256 constant P = 1 ether + 43;
    address public collector;
    ITournament public tournament;
    IFelonyGame public arena;
    RandomOracle public oracle;
    CoordinatorMock public coordinator;
    BindingVerifierMock public verifier;
    MockWETH public weth;
    MockVault public vault;
    uint256[] public ids;
    uint256[] public games;
    mapping(uint256 => bytes32) public snapshots;
    mapping(uint256 => bytes32) public allocations;
    mapping(uint256 => uint256) public paid;
    mapping(uint256 => bool) public feePaid;
    mapping(uint256 => uint256) public delivered;
    mapping(uint256 => bool) public hasDelivery;
    uint256 public minted;
    uint256 public completed;
    uint256 public aborted;
    uint256 public updates;
    uint256 public moves;
    uint256 public rejected;
    uint256 public claims;
    uint256 public ordinary;
    uint256 public defaults;

    receive() external payable {}

    constructor() {
        vm.warp(1_000_000);
        vm.deal(address(this), 100 ether);
        coordinator = new CoordinatorMock();
        verifier = new BindingVerifierMock();
        weth = new MockWETH();
        vault = new MockVault(weth);
        oracle = RandomOracle(
            _deploy(
                "random_oracle",
                abi.encode(
                    address(coordinator),
                    address(this),
                    keccak256("invariant key"),
                    uint256(42),
                    uint16(3),
                    uint32(200000),
                    uint256(3600),
                    true,
                    uint256(0)
                )
            )
        );
        collector = _deploy("fees", abi.encode(address(this)));
        arena = IFelonyGame(_deploy("game", abi.encode(address(verifier), address(oracle), collector, uint256(60))));
        tournament = ITournament(
            _deploy("tournament", abi.encode(address(arena), address(vault), address(weth), address(oracle), collector))
        );
        oracle.setConsumer(address(tournament), true);
        _register(4, 4);
        _register(16, 16);
        _register(32, 17);

        uint256 id = tournament.createTournament(4, P, 60, 3600, 600, 60);
        ids.push(id);
        for (uint256 slot; slot < 3; ++slot) {
            _join(id, slot);
        }
        vm.prank(player(id, 2));
        tournament.leave(id);
    }

    function _deploy(string memory name, bytes memory args) private returns (address deployed) {
        bytes memory code = abi.encodePacked(vm.readFileBinary(string.concat("artifacts/", name, ".bin")), args);
        assembly { deployed := create(0, add(code, 32), mload(code)) }
        require(deployed != address(0), "deployment");
    }

    function player(uint256 id, uint256 slot) public pure returns (address) {
        return address(uint160(0x10000 + id * 100 + slot));
    }

    function _join(uint256 id, uint256 slot) private {
        address p = player(id, slot);
        vm.deal(p, P);
        vm.prank(p);
        tournament.join{value: P}(id, 1000 + slot);
    }

    function _register(uint256 capacity, uint256 count) private {
        uint256 id = tournament.createTournament(capacity, P, 60, 3600, 600, 60);
        ids.push(id);
        for (uint256 i; i < count; ++i) {
            _join(id, i);
        }
        if (count < capacity) {
            vm.warp(block.timestamp + 61);
            tournament.start(id);
        }
        tournament.fund(id);
        minted += count * P;
    }

    function elapse(uint256 seconds_) external {
        vm.warp(block.timestamp + seconds_ % 401);
    }

    function quote(uint256 rate, uint256 fault) external {
        vault.setRate(50 + rate % 101, 100);
        vault.setPreview(fault % 4 == 1, fault % 4 == 2, 0);
        vault.setMalformedPreview(fault % 4 == 3);
    }

    function _freeze(uint256 id) private {
        allocations[id] = allocationHash(id);
    }

    function allocationHash(uint256 id) public view returns (bytes32 h) {
        h = keccak256(abi.encode(tournament.payoutInfo(id)));
        uint256 count = tournament.tournamentInfo(id)[2];
        for (uint256 i; i < count; ++i) {
            h = keccak256(abi.encode(h, tournament.entitlement(id, i)));
        }
    }

    function progress(uint256 which, uint256 choice) public {
        uint256 id = ids[which % ids.length];
        uint256[18] memory t = tournament.tournamentInfo(id);
        if (t[0] == 1) {
            if (block.timestamp > t[4]) tournament.cancel(id);
        } else if (t[0] == 3 && t[7] == 0) {
            if (block.timestamp > t[8] + 3600) {
                tournament.abort(id);
                ++aborted;
                _freeze(id);
            } else if (block.timestamp >= t[8]) {
                tournament.requestDraw(id);
            }
        } else if (t[0] == 3 && t[7] == 1) {
            uint256 status = oracle.status(t[9]);
            if (status == 2) {
                tournament.beginRound(id);
            } else if (status == 3) {
                tournament.abort(id);
                ++aborted;
                _freeze(id);
            }
        } else if (t[0] == 3 && t[7] == 2) {
            if (t[6] == t[17] && t[10] == 0) {
                tournament.finalize(id);
                ++completed;
                _freeze(id);
                return;
            }
            uint256 first = t[6] == t[17] ? 0 : t[1] >> t[6];
            uint256 size = t[6] == t[17] ? 2 : first;
            for (uint256 j; j < size; ++j) {
                uint256 index = first + (choice % size + j) % size;
                uint256[4] memory m = tournament.bracketMatch(id, index);
                if (m[0] == 2) continue;
                if (m[0] == 1) {
                    if (arena.matchInfo(m[3])[6] == 4) {
                        tournament.advance(id, index);
                        return;
                    }
                    continue;
                }
                if (t[6] == 1) {
                    MerkleBracket.Tree memory tree = MerkleBracket.build(
                        block.chainid, address(tournament), id, tournament.drawWord(id, 0), t[2], t[1]
                    );
                    (uint256 a, uint256 b, uint256[9] memory sib) = MerkleBracket.proof(tree, index);
                    tournament.openMatch(id, index, a, b, sib);
                } else {
                    tournament.advance(id, index);
                }
                m = tournament.bracketMatch(id, index);
                if (m[0] == 1) _recordGame(id, index, m[3]);
                return;
            }
        }
    }

    function _recordGame(uint256 id, uint256 index, uint256 game) private {
        games.push(game);
        snapshots[game] = snapshot(game);
        uint256[18] memory t = tournament.tournamentInfo(id);
        uint256[18] memory g = arena.matchInfo(game);
        uint256 d = t[17] > 3 ? t[17] - 2 : 1;
        uint256 draw = t[6] < d ? t[6] : d;
        require(
            g[9]
                == MerkleBracket.matchSeed(
                    block.chainid, address(tournament), id, index, tournament.drawWord(id, draw)
                ),
            "wrong match seed"
        );
        for (uint256 seat; seat < 2; ++seat) {
            uint256 slot = tournament.slotOf(id, address(uint160(g[seat])));
            uint256[6] memory entry = tournament.entryInfo(id, slot - 1);
            require(entry[1] == g[seat + 2] && entry[2] == 1, "wrong commitment or forfeited seat");
        }
    }

    function deliver(uint256 which, uint256 word) public {
        uint256 id = ids[which % ids.length];
        uint256[18] memory t = tournament.tournamentInfo(id);
        if (t[0] != 3 || t[7] != 1 || oracle.status(t[9]) != 1) return;
        coordinator.fulfill(oracle, t[9], word);
        delivered[t[9]] = word;
        hasDelivery[t[9]] = true;
    }

    function snapshot(uint256 game) public view returns (bytes32) {
        uint256[18] memory g = arena.matchInfo(game);
        return keccak256(abi.encode(g[0], g[1], g[2], g[3], g[9], g[15]));
    }

    function _submit(uint256 game, uint256 seat, uint256 choice) private {
        uint256[9] memory words = arena.proofInputs(game, seat, 0);
        uint256 hand = words[1] & 511;
        uint256 action = choice % 9;
        for (uint256 i; i < 9; ++i) {
            if (hand & (1 << action) != 0) break;
            action = (action + 1) % 9;
        }
        words = arena.proofInputs(game, seat, action);
        verifier.configure(keccak256(abi.encode(words)), 0);
        vm.prank(address(uint160(arena.matchInfo(game)[seat])));
        arena.submitMove(game, action, new bytes(9152));
        ++moves;
    }

    function play(uint256 which, uint256 mode, uint256 choice) public {
        if (games.length == 0) return;
        uint256 game = games[which % games.length];
        uint256[18] memory g = arena.matchInfo(game);
        if (g[6] != 3) return;
        if (block.timestamp > g[7]) {
            arena.claimTimeout(game);
            ++defaults;
            return;
        }
        if (mode % 3 == 1) {
            vm.prank(address(uint160(g[choice % 2])));
            arena.forfeit(game);
            ++defaults;
        } else if (mode % 3 == 2) {
            if (g[11] & 1 == 0) _submit(game, 0, choice);
        } else {
            for (uint256 round; round < 8; ++round) {
                g = arena.matchInfo(game);
                if (g[6] != 3) break;
                if (g[11] & 1 == 0) _submit(game, 0, choice);
                if (g[11] & 2 == 0) _submit(game, 1, choice >> 8);
            }
            require(arena.matchInfo(game)[6] == 4, "normal game unfinished");
            ++ordinary;
        }
    }

    function update(uint256 which, uint256 slot, uint256 commitment) public {
        uint256 id = ids[which % ids.length];
        uint256[18] memory t = tournament.tournamentInfo(id);
        slot %= t[2];
        uint256[6] memory before_ = tournament.entryInfo(id, slot);
        bytes32 stable = keccak256(abi.encode(before_));
        vm.prank(address(uint160(before_[0])));
        (bool ok,) = address(tournament).call(abi.encodeCall(ITournament.updateModel, (id, 1 + commitment % 1000000)));
        if (ok) {
            require(
                t[0] == 3 && t[7] == 0 && t[6] > 0 && t[6] + 2 < t[17] && block.timestamp < t[8],
                "update outside window"
            );
            require(tournament.entryInfo(id, slot)[4] == before_[4] + P / 10, "wrong update deduction");
            ++updates;
        } else {
            require(keccak256(abi.encode(tournament.entryInfo(id, slot))) == stable, "failed update mutated entry");
            ++rejected;
        }
    }

    function claim(uint256 which, uint256 slot, bool fail) public {
        uint256 id = ids[which % ids.length];
        uint256[18] memory t = tournament.tournamentInfo(id);
        slot %= t[2];
        uint256[6] memory e = tournament.entryInfo(id, slot);
        if (e[3] != 0 || (t[0] != 4 && t[0] != 5 && t[0] != 6) || e[2] != 1) return;
        uint256 before_ = vault.balanceOf(address(tournament));
        uint256 amount = tournament.entitlement(id, slot);
        vault.setFakeTransfers(fail);
        vm.prank(address(uint160(e[0])));
        (bool ok,) = address(tournament).call(abi.encodeCall(ITournament.claim, (id)));
        vault.setFakeTransfers(false);
        if (fail && amount > 0) {
            require(!ok && tournament.entryInfo(id, slot)[3] == 0, "failed share transfer consumed claim");
            require(vault.balanceOf(address(tournament)) == before_, "failed transfer changed holdings");
        } else {
            require(ok, "valid claim failed");
            paid[id] += amount;
            ++claims;
        }
    }

    function fees(uint256 which) public {
        uint256 id = ids[which % ids.length];
        uint256 phase = tournament.tournamentInfo(id)[0];
        if ((phase != 4 && phase != 5) || feePaid[id]) return;
        vm.prank(collector);
        tournament.claimFees(id);
        feePaid[id] = true;
        paid[id] += tournament.payoutInfo(id)[7];
    }

    function withdraw(uint256 which, uint256 slot) public {
        uint256 id = ids[which % ids.length];
        address p = player(id, slot % 18);
        uint256 credit = tournament.creditOf(p);
        if (credit == 0) return;
        uint256 before_ = p.balance;
        vm.prank(p);
        tournament.withdraw(p);
        require(p.balance == before_ + credit, "cash withdrawal");
    }

    function assertInvariants() public view {
        uint256 unclaimed;
        uint256 holdings;
        uint256 cash;
        uint256 totalPaid;
        for (uint256 k; k < ids.length; ++k) {
            uint256 id = ids[k];
            uint256[18] memory t = tournament.tournamentInfo(id);
            holdings += t[11] - paid[id];
            totalPaid += paid[id];
            uint256 forfeits;
            uint256 partition = tournament.payoutInfo(id)[7] + tournament.payoutInfo(id)[8];
            for (uint256 slot; slot < t[2]; ++slot) {
                uint256[6] memory e = tournament.entryInfo(id, slot);
                require(tournament.slotOf(id, address(uint160(e[0]))) == slot + 1, "roster inverse");
                require(e[4] <= 7 * (P / 10) + P / 40, "deduction cap");
                if (e[2] == 2) ++forfeits;
                if (t[0] == 4 || t[0] == 5) {
                    uint256 amount = tournament.entitlement(id, slot);
                    partition += amount;
                    if (e[2] == 2) require(amount == 0, "forfeiter paid");
                    if (e[3] == 0) unclaimed += amount;
                } else if (t[0] == 1 || t[0] == 2 || (t[0] == 6 && e[3] == 0)) {
                    cash += P;
                }
            }
            for (uint256 slot; slot < 18; ++slot) {
                cash += tournament.creditOf(player(id, slot));
            }
            require(forfeits == t[12], "forfeit count");
            if (t[0] == 4 || t[0] == 5) {
                require(partition == t[11], "share partition");
                require(allocations[id] == allocationHash(id), "settlement changed");
                if (!feePaid[id]) unclaimed += tournament.payoutInfo(id)[7];
            }
            if (t[0] == 3 && t[7] == 2) {
                uint256 first = t[6] == t[17] ? 0 : t[1] >> t[6];
                uint256 size = t[6] == t[17] ? 2 : first;
                uint256 pending;
                for (uint256 j; j < size; ++j) {
                    if (tournament.bracketMatch(id, first + j)[0] != 2) ++pending;
                }
                require(pending == t[10], "round barrier pending");
            }
        }
        require(
            holdings + totalPaid == minted && vault.balanceOf(address(tournament)) == holdings, "cross event custody"
        );
        require(tournament.accounting()[1] == unclaimed, "owed shares");
        require(tournament.accounting()[0] == cash && weth.balanceOf(address(tournament)) == cash, "cash liabilities");
        require(arena.liabilities() == 0 && address(arena).balance == 0, "managed game took funds");
        for (uint256 j; j < games.length; ++j) {
            require(snapshots[games[j]] == snapshot(games[j]), "match snapshot changed");
        }
        for (uint256 request = 1; request < coordinator.nextId(); ++request) {
            if (hasDelivery[request]) {
                require(
                    oracle.status(request) == 2 && oracle.getRandomness(request) == delivered[request], "ready changed"
                );
            }
        }
    }

    function gameCount() public view returns (uint256) {
        return games.length;
    }
}

contract FelonyInvariantTest is Test {
    FelonyHandler public handler;

    function setUp() public {
        handler = new FelonyHandler();
        targetContract(address(handler));
    }

    function invariant_accountingAndRoundSafety() public view {
        handler.assertInvariants();
    }

    function testHandlerRecoversExpiredOracleAndMoveTimeout() public {
        handler.progress(0, 0);
        handler.deliver(0, 0);
        handler.progress(1, 0);
        for (uint256 i; i < 10; ++i) {
            handler.elapse(400);
        }
        handler.progress(1, 0);
        handler.progress(2, 0);
        require(handler.aborted() == 2, "expired and unpaid draws did not abort");
        handler.progress(0, 0);
        handler.progress(0, 0);
        handler.play(0, 2, 0);
        handler.elapse(61);
        handler.play(0, 0, 0);
        handler.progress(0, 0);
        require(handler.defaults() == 1, "timeout path not reached");
        handler.assertInvariants();
    }

    function testHandlerCompletesRoundsUpdatesAndInterleavedClaims() public {
        for (uint256 step; step < 100; ++step) {
            for (uint256 id; id < 3; ++id) {
                handler.progress(id, step);
                handler.deliver(id, step);
                handler.progress(id, step);
                for (uint256 slot; slot < 18; ++slot) {
                    handler.update(id, slot, step);
                }
            }
            for (uint256 game; game < handler.gameCount(); ++game) {
                handler.play(game, 0, step);
            }
            handler.elapse(60);
            handler.assertInvariants();
        }
        require(handler.completed() == 3 && handler.updates() > 0 && handler.ordinary() > 0, "deep paths not reached");
        for (uint256 id; id < 4; ++id) {
            handler.progress(id, 0);
            for (uint256 slot; slot < 18; ++slot) {
                handler.claim(id, slot, true);
                handler.claim(id, slot, false);
                handler.withdraw(id, slot);
                handler.assertInvariants();
            }
            handler.fees(id);
            handler.assertInvariants();
        }
        require(handler.tournament().accounting()[1] == 0 && handler.claims() > 0, "claims not drained");
    }
}
