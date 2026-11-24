// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {RealGameOracleMock, RealGameFeeReceiver} from "../mocks/RealGameMocks.sol";

interface RealArena {
    function createChallenge(address, uint256, uint256, uint256) external payable returns (uint256);
    function joinChallenge(uint256, uint256) external payable;
    function activateMatch(uint256) external;
    function randomnessRequest(uint256) external view returns (uint256);
    function submitMove(uint256, uint256, bytes calldata) external;
    function proofInputs(uint256, uint256, uint256) external view returns (uint256[9] memory);
    function matchInfo(uint256) external view returns (uint256[18] memory);
}

contract FelonyRealGameTest is Test {
    address constant GAME = address(0xFE11);
    address constant P0 = address(0xA11CE);
    address constant P1 = address(0xB0B);
    RealArena arena = RealArena(GAME);

    function deploy(bytes memory code) private returns (address a) {
        assembly { a := create(0, add(code, 32), mload(code)) }
        require(a != address(0), "deploy");
        require(a.code.length <= 24576, "EIP170");
    }

    function setupGame() private {
        vm.chainId(31337);
        address verifier = deploy(vm.readFileBinary("artifacts/verifier.bin"));
        RealGameOracleMock oracle = new RealGameOracleMock();
        address collector = address(new RealGameFeeReceiver());
        address source = deploy(
            bytes.concat(
                vm.readFileBinary("artifacts/game.bin"), abi.encode(verifier, address(oracle), collector, uint256(600))
            )
        );

        vm.etch(GAME, source.code);
        (uint256 c0, uint256 c1) = abi.decode(vm.readFileBinary("artifacts/commitments"), (uint256, uint256));
        vm.prank(P0);
        require(arena.createChallenge(P1, c0, 0, 600) == 1);
        vm.prank(P1);
        arena.joinChallenge(1, c1);
        oracle.fulfill();
        arena.activateMatch(1);
    }

    function fixture(uint256 index) private view returns (bytes memory proof, uint256[9] memory inputs) {
        string memory p = string.concat("artifacts/move_", vm.toString(index), "/");
        proof = vm.readFileBinary(string.concat(p, "proof"));
        inputs = abi.decode(vm.readFileBinary(string.concat(p, "public_inputs")), (uint256[9]));
    }

    function testMalformedProofRejectedWithoutArenaLengthGuard() public {
        setupGame();
        (bytes memory proof, uint256[9] memory inputs) = fixture(0);
        uint256 length = proof.length;
        assembly { mstore(proof, sub(length, 1)) }
        vm.prank(P0);
        (bool truncated,) = GAME.call(abi.encodeCall(RealArena.submitMove, (1, inputs[8], proof)));
        require(!truncated && arena.matchInfo(1)[11] == 0, "truncated proof accepted");
        assembly { mstore(proof, length) }
        vm.prank(P0);
        (bool extended,) = GAME.call(abi.encodeCall(RealArena.submitMove, (1, inputs[8], bytes.concat(proof, hex"00"))));
        require(!extended && arena.matchInfo(1)[11] == 0, "extended proof accepted");
        vm.prank(P0);
        (bool extraWord,) =
            GAME.call(abi.encodeCall(RealArena.submitMove, (1, inputs[8], bytes.concat(proof, new bytes(32)))));
        require(!extraWord && arena.matchInfo(1)[11] == 0, "extra proof word accepted");
        vm.prank(P0);
        arena.submitMove(1, inputs[8], proof);
        require(arena.matchInfo(1)[11] == 1, "honest proof rejected");
    }

    function testFullMatchWithSixteenRealNoirProofs() public {
        setupGame();
        for (uint256 r; r < 8; r++) {
            uint256[9] memory before0 = arena.proofInputs(1, 0, 0);
            uint256[9] memory before1 = arena.proofInputs(1, 1, 0);
            for (uint256 seat; seat < 2; seat++) {
                (bytes memory proof, uint256[9] memory expected) = fixture(2 * r + seat);
                uint256[9] memory actual = arena.proofInputs(1, seat, expected[8]);
                require(
                    keccak256(abi.encode(actual)) == keccak256(abi.encode(expected)), "oracle state/context differs"
                );

                vm.prank(seat == 0 ? P0 : P1);
                (bool ok,) = GAME.call(abi.encodeCall(RealArena.submitMove, (1, (expected[8] + 1) % 9, proof)));
                require(!ok, "wrong action accepted");
                vm.prank(seat == 0 ? P0 : P1);
                uint256 gasBefore = gasleft();
                arena.submitMove(1, expected[8], proof);
                emit log_named_uint("real_move_gas", gasBefore - gasleft());
                if (seat == 0) {
                    require(
                        arena.proofInputs(1, 0, 0)[1] == before0[1] && arena.proofInputs(1, 1, 0)[1] == before1[1],
                        "first bid changed board"
                    );
                }
            }
            (bytes memory oldProof, uint256[9] memory old) = fixture(2 * r);
            vm.prank(P0);
            (bool replay,) = GAME.call(abi.encodeCall(RealArena.submitMove, (1, old[8], oldProof)));
            require(!replay, "round replay accepted");
        }
        uint256[18] memory info = arena.matchInfo(1);
        (uint256 score0, uint256 score1, uint256 result) =
            abi.decode(vm.readFileBinary("artifacts/final"), (uint256, uint256, uint256));
        require(
            info[6] == 4 && info[10] == 9 && info[12] == score0 && info[13] == score1 && info[14] == result,
            "final settlement mismatch"
        );
        emit log_named_uint("accepted_real_proofs", 16);
    }
}
