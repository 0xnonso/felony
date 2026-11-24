// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

interface Verifier {
    function verify(bytes calldata proof, bytes32[] calldata inputs) external view returns (bool);
}

contract FelonyVerifierTest is Test {
    uint256 private constant FIELD = 21888242871839275222246405745257275088548364400416034343698204186575808495617;
    uint256 private constant BASE_FIELD = 21888242871839275222246405745257275088696311157297823662689037894645226208583;
    uint256 private constant CALL_GAS = 10_000_000;
    address private fe;
    address private referenceVerifier;

    function deploy(bytes memory creation) private returns (address deployed) {
        assembly { deployed := create(0, add(creation, 32), mload(creation)) }
        require(deployed != address(0) && deployed.code.length != 0, "deployment failed");
    }

    function setUp() public {
        address relations = deploy(vm.readFileBinary("artifacts/RelationsLib.bin"));
        address transcript = deploy(vm.readFileBinary("artifacts/ZKTranscriptLib.bin"));
        vm.etch(address(0x1001), relations.code);
        vm.etch(address(0x1002), transcript.code);
        uint256 before = gasleft();
        fe = deploy(vm.readFileBinary("artifacts/fe.bin"));
        emit log_named_uint("fe.create_gas", before - gasleft());
        referenceVerifier = deploy(vm.readFileBinary("artifacts/solidity.bin"));
    }

    function count() private view returns (uint256) {
        return abi.decode(vm.readFileBinary("artifacts/case_count"), (uint256));
    }

    function fixture(uint256 index) private view returns (bytes memory proof, bytes32[] memory inputs) {
        string memory prefix = string.concat("artifacts/case_", vm.toString(index), "/");
        proof = vm.readFileBinary(string.concat(prefix, "proof"));
        bytes memory raw = vm.readFileBinary(string.concat(prefix, "public_inputs"));
        require(raw.length == 9 * 32, "wrong public ABI");
        inputs = new bytes32[](9);
        for (uint256 i; i < 9; ++i) {
            bytes32 word;
            assembly { word := mload(add(add(raw, 32), mul(i, 32))) }
            inputs[i] = word;
        }
    }

    function rejects(address target, bytes memory proof, bytes32[] memory inputs)
        private
        view
        returns (bytes memory output)
    {
        bool ok;
        (ok, output) = target.staticcall{gas: CALL_GAS}(abi.encodeCall(Verifier.verify, (proof, inputs)));
        require(!ok, "invalid proof did not revert");
    }

    function compare(bytes memory proof, bytes32[] memory inputs)
        private
        view
        returns (bytes32 feError, bool compared, bool referenceExhausted)
    {
        bytes memory feOutput = rejects(fe, proof, inputs);
        require(feOutput.length >= 4, "Fe rejection must reach an error handler, not exhaust gas");
        feError = keccak256(feOutput);
        uint256 before = gasleft();
        bytes memory referenceOutput = rejects(referenceVerifier, proof, inputs);
        uint256 used = before - gasleft();
        if (referenceOutput.length == 0) {
            return (feError, false, used >= CALL_GAS - CALL_GAS / 64);
        }
        require(feError == keccak256(referenceOutput), "Fe/Solidity rejection differs");
        return (feError, true, false);
    }

    function bothReject(bytes memory proof, bytes32[] memory inputs) private view returns (bool compared) {
        (, compared,) = compare(proof, inputs);
    }

    function proofWord(bytes memory proof, uint256 index) private pure returns (uint256 value) {
        assembly { value := mload(add(add(proof, 32), mul(index, 32))) }
    }

    function flipProofWord(bytes memory proof, uint256 index) private pure {
        assembly {
            let slot := add(add(proof, 32), mul(index, 32))
            mstore(slot, xor(mload(slot), 1))
        }
    }

    function pointOnCurve(bytes memory proof, uint256 index) private pure returns (bool) {
        uint256 x = proofWord(proof, index - index % 2);
        uint256 y = proofWord(proof, index - index % 2 + 1);
        return x < BASE_FIELD && y < BASE_FIELD
            && mulmod(y, y, BASE_FIELD) == addmod(mulmod(mulmod(x, x, BASE_FIELD), x, BASE_FIELD), 3, BASE_FIELD);
    }

    function contains(bytes32[] memory values, uint256 length, bytes32 value) private pure returns (bool) {
        for (uint256 i; i < length; ++i) {
            if (values[i] == value) return true;
        }
        return false;
    }

    function testValidProofs() public {
        for (uint256 i; i < count(); ++i) {
            (bytes memory proof, bytes32[] memory inputs) = fixture(i);
            uint256 before = gasleft();
            require(Verifier(fe).verify(proof, inputs), "Fe rejected honest proof");
            uint256 used = before - gasleft();
            emit log_named_uint(string.concat("case_", vm.toString(i), ".fe_call_gas"), used);
            before = gasleft();
            require(Verifier(referenceVerifier).verify(proof, inputs), "Solidity rejected honest proof");
            used = before - gasleft();
            emit log_named_uint(string.concat("case_", vm.toString(i), ".solidity_call_gas"), used);
        }
        emit log_named_uint("valid_proofs", count());
    }

    function testDeployedSizeAndRelationsLibrary() public {
        require(fe.code.length <= 24576, "Fe exceeds EIP170");
        require(
            fe.code.length == vm.readFileBinary("artifacts/fe.runtime.bin").length + 60 * 32, "wrong immutable key size"
        );
        address relations = address(uint160(uint256(keccak256(abi.encodePacked(bytes2(0xd694), fe, bytes1(0x01))))));
        bytes memory expected = vm.readFileBinary("artifacts/fe-relations.runtime.bin");
        require(
            keccak256(relations.code) == keccak256(expected), "constructor did not deploy expected relations library"
        );
        require(relations.code.length <= 24576, "relations exceeds EIP170");
        emit log_named_uint("fe.deployed_bytes", fe.code.length);
        emit log_named_uint("fe.relations_bytes", relations.code.length);
    }

    function testEveryPublicInputMutationRejects() public {
        for (uint256 c; c < count(); ++c) {
            (bytes memory proof, bytes32[] memory inputs) = fixture(c);
            for (uint256 i; i < inputs.length; ++i) {
                bytes32 original = inputs[i];
                inputs[i] = bytes32(addmod(uint256(original), 1, FIELD));
                require(bothReject(proof, inputs), "reference input rejection was empty");
                inputs[i] = original;
            }
        }
        emit log_named_uint("public_input_mutations", count() * 9);
    }

    function testEveryProofWordMutationRejects() public {
        (bytes memory proof, bytes32[] memory inputs) = fixture(0);
        require(proof.length % 64 == 0);
        uint256 words = proof.length / 32;
        bytes32[] memory agreedInvalidPoint = new bytes32[](words);
        bytes32[] memory uncompared = new bytes32[](words);
        uint256 agreed;
        uint256 exhausted;
        for (uint256 i; i < words; ++i) {
            bool invalidPoint = pointOnCurve(proof, i);
            flipProofWord(proof, i);
            invalidPoint = invalidPoint && !pointOnCurve(proof, i);
            (bytes32 feError, bool compared, bool referenceExhausted) = compare(proof, inputs);
            flipProofWord(proof, i);
            if (compared) {
                if (invalidPoint) agreedInvalidPoint[agreed++] = feError;
            } else {
                require(referenceExhausted, "empty reference rejection did not exhaust its gas");
                require(invalidPoint, "uncompared mutation is not an invalid curve point");
                uncompared[exhausted++] = feError;
            }
        }
        for (uint256 i; i < exhausted; ++i) {
            require(
                contains(agreedInvalidPoint, agreed, uncompared[i]),
                "uncompared Fe rejection is not an agreed invalid-point error"
            );
        }
        emit log_named_uint("proof_word_mutations", words);
        emit log_named_uint("proof_mutation_reverts_compared", words - exhausted);
        emit log_named_uint("proof_mutation_reference_exhausted", exhausted);
        emit log_named_uint("proof_mutation_agreed_invalid_points", agreed);
    }

    function testMalformedLengthsAndFieldInputsReject() public {
        (bytes memory proof, bytes32[] memory inputs) = fixture(0);
        require(bothReject(proof, new bytes32[](8)));
        require(bothReject(proof, new bytes32[](10)));
        require(bothReject(proof, new bytes32[](0)));
        require(bothReject(bytes.concat(proof, hex"00"), inputs));
        uint256 length = proof.length;
        assembly { mstore(proof, sub(length, 1)) }
        require(bothReject(proof, inputs));
        assembly { mstore(proof, length) }
        for (uint256 i; i < inputs.length; ++i) {
            bytes32 old = inputs[i];
            inputs[i] = bytes32(FIELD);
            require(bothReject(proof, inputs));
            inputs[i] = old;
        }
        emit log_named_uint("malformed_input_cases", 14);
    }

    function testProofCannotUseAnotherCasesInputs() public view {
        (bytes memory proof,) = fixture(0);
        (, bytes32[] memory inputs) = fixture(1);
        require(bothReject(proof, inputs));
    }
}
