// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

contract RealGameOracleMock {
    bool public ready;

    function quoteFee() external pure returns (uint256) {
        return 0;
    }

    function requestRandomness(bytes32) external payable returns (uint256) {
        return 1;
    }

    function fulfill() external {
        ready = true;
    }

    function getRandomness(uint256 id) external view returns (uint256) {
        require(ready && id == 1);
        return 777;
    }

    function status(uint256 id) external view returns (uint256) {
        require(id == 1);
        return ready ? 2 : 1;
    }
}

contract RealGameFeeReceiver {}
