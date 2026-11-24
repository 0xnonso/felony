// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

contract RandomOracleMock {
    struct Request {
        address caller;
        bytes32 context;
        uint256 state;
        uint256 word;
    }
    mapping(uint256 => Request) public requests;
    mapping(bytes32 => bool) private used;
    uint256 public nextId;
    uint256 public quoteFee;
    bool public failRequest;
    address public reentryTarget;
    bytes public reentryData;
    bool public reentryAttempted;
    bool public reentrySucceeded;

    function setFee(uint256 fee) external {
        quoteFee = fee;
    }

    function setFailRequest(bool value) external {
        failRequest = value;
    }

    function setReentry(address target, bytes calldata data) external {
        reentryTarget = target;
        reentryData = data;
    }

    function requestRandomness(bytes32 context) external payable returns (uint256 id) {
        require(!failRequest && msg.value == quoteFee, "request rejected");
        bytes32 key = keccak256(abi.encode(msg.sender, context));
        require(!used[key], "duplicate context");
        used[key] = true;
        id = ++nextId;
        requests[id] = Request(msg.sender, context, 1, 0);
        if (reentryTarget != address(0)) {
            reentryAttempted = true;
            (reentrySucceeded,) = reentryTarget.call(reentryData);
        }
    }

    function fulfill(uint256 id, uint256 word) external {
        require(requests[id].state == 1, "not pending");
        requests[id].state = 2;
        requests[id].word = word;
    }

    function expire(uint256 id) external {
        require(requests[id].state == 1, "not pending");
        requests[id].state = 3;
    }

    function status(uint256 id) external view returns (uint256) {
        require(requests[id].state != 0, "unknown");
        return requests[id].state;
    }

    function isReady(uint256 id) external view returns (bool) {
        require(requests[id].state != 0, "unknown");
        return requests[id].state == 2;
    }

    function getRandomness(uint256 id) external view returns (uint256) {
        require(requests[id].state == 2, "not ready");
        return requests[id].word;
    }
}
