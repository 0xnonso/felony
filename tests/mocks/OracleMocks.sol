// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {RandomOracle} from "../Interfaces.sol";

contract CoordinatorMock {
    struct RandomWordsRequest {
        bytes32 keyHash;
        uint256 subId;
        uint16 requestConfirmations;
        uint32 callbackGasLimit;
        uint32 numWords;
        bytes extraArgs;
    }
    bytes32 public keyHash;
    uint256 public subId;
    uint16 public confirmations;
    uint32 public callbackGasLimit;
    uint32 public numWords;
    bytes public extraArgs;
    uint256 public nextId = 1;
    bool public failRequest;
    bool public attackReentry;
    bool public attackCallback;
    bool public attackWorked;
    uint256 public callbackRequestId;

    function setCallbackRequestId(uint256 id) external {
        callbackRequestId = id;
    }

    function configure(uint256 id, bool fail, bool reentry, bool callback) external {
        nextId = id;
        failRequest = fail;
        attackReentry = reentry;
        attackCallback = callback;
    }

    function requestRandomWords(RandomWordsRequest calldata req) external returns (uint256 id) {
        require(!failRequest, "unavailable");
        keyHash = req.keyHash;
        subId = req.subId;
        confirmations = req.requestConfirmations;
        callbackGasLimit = req.callbackGasLimit;
        numWords = req.numWords;
        extraArgs = req.extraArgs;
        if (attackReentry) {
            (attackWorked,) = msg.sender.call(abi.encodeCall(RandomOracle.requestRandomness, (bytes32(uint256(777)))));
        }
        if (attackCallback) {
            uint256[] memory words = new uint256[](1);
            words[0] = 99;
            (attackWorked,) = msg.sender
                .call(
                    abi.encodeCall(
                        RandomOracle.rawFulfillRandomWords, (callbackRequestId == 0 ? nextId : callbackRequestId, words)
                    )
                );
        }
        id = nextId++;
    }

    function fulfill(RandomOracle oracle, uint256 id, uint256 word) external {
        uint256[] memory words = new uint256[](1);
        words[0] = word;
        oracle.rawFulfillRandomWords(id, words);
    }

    function fulfillWithGas(RandomOracle oracle, uint256 id, uint256 word, uint256 gasLimit)
        external
        returns (bool ok)
    {
        uint256[] memory words = new uint256[](1);
        words[0] = word;
        (ok,) = address(oracle).call{gas: gasLimit}(abi.encodeCall(RandomOracle.rawFulfillRandomWords, (id, words)));
    }

    function fulfillMany(RandomOracle oracle, uint256 id, uint256 count) external {
        uint256[] memory words = new uint256[](count);
        oracle.rawFulfillRandomWords(id, words);
    }
}

contract OracleAcceptingVerifier {
    function verify(bytes calldata, bytes32[] calldata) external pure returns (bool) {
        return true;
    }
}
