// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

contract FeeToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract FeeArenaMock {
    mapping(address => uint256) public credits;

    function fund(address recipient) external payable {
        credits[recipient] += msg.value;
    }

    function withdraw(address to) external {
        uint256 amount = credits[msg.sender];
        require(amount > 0);
        credits[msg.sender] = 0;
        (bool ok,) = to.call{value: amount}("");
        require(ok);
    }
}

contract FeeTournamentMock {
    address public immutable recipient;
    FeeToken public immutable token;
    bool public claimed;

    constructor(address recipient_, FeeToken token_) {
        recipient = recipient_;
        token = token_;
    }

    function claimFees(uint256 id) external {
        require(msg.sender == recipient && id == 7 && !claimed);
        claimed = true;
        token.transfer(recipient, 25);
    }
}

contract FeeReject {
    receive() external payable {
        revert();
    }
}
