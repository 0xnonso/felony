// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IFelonyGame} from "../Interfaces.sol";

contract BindingVerifierMock {
    bytes32 public expectedHash;
    bool public armed;
    uint256 public mode;
    uint256 public proofBytes = 9152;
    uint256 public verificationWork;

    function configure(bytes32 expected, uint256 nextMode) external {
        expectedHash = expected;
        armed = true;
        mode = nextMode;
    }

    function configureProofLength(uint256 length) external {
        proofBytes = length;
    }

    function configureVerificationWork(uint256 gasToConsume) external {
        verificationWork = gasToConsume;
    }

    function verify(bytes calldata proof, bytes32[] calldata inputs) external view returns (bool) {
        uint256 work = verificationWork;
        uint256 startGas = gasleft();
        while (startGas - gasleft() < work) {}
        require(armed, "unconfigured mock");
        require(proof.length == proofBytes && inputs.length == 9, "wrong verifier ABI");
        uint256[9] memory words;
        for (uint256 i; i < 9; ++i) {
            words[i] = uint256(inputs[i]);
        }
        require(keccak256(abi.encode(words)) == expectedHash, "wrong public inputs");
        require(mode != 2, "configured verifier revert");
        return mode != 1;
    }
}

contract RejectGamePayout {
    receive() external payable {
        revert("recipient rejects ETH");
    }
}

contract ReentrantGamePlayer {
    IFelonyGame public immutable game;
    bool public attempted;
    bool public reentered;
    bool public crossFunctionReentered;

    constructor(IFelonyGame target) {
        game = target;
    }

    function join(uint256 id, uint256 commitment) external payable {
        game.joinChallenge{value: msg.value}(id, commitment);
    }

    function pull() external {
        game.withdraw(address(this));
    }

    receive() external payable {
        attempted = true;
        (reentered,) = address(game).call(abi.encodeCall(IFelonyGame.withdraw, (address(this))));
        (crossFunctionReentered,) = address(game).call(abi.encodeCall(IFelonyGame.reserveManagedMatches, (999, 1)));
    }
}

contract GameFeeReceiver {
    receive() external payable {}

    function collect(IFelonyGame game) external {
        game.withdraw(address(this));
    }
}
