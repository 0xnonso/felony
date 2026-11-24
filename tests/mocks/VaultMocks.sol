// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IVaultToken} from "../Interfaces.sol";

contract VaultAssetMock {
    string public name = "Mock wrapped asset";
    string public symbol = "MWA";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    bool public falseReturn;
    bool public emptyReturn;
    uint256 public fee;

    function fault(bool false_, bool empty_, uint256 fee_) external {
        falseReturn = false_;
        emptyReturn = empty_;
        fee = fee_;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address to, uint256 amount) external returns (bool) {
        if (falseReturn) return false;
        require(amount == 0 || allowance[msg.sender][to] == 0, "reset first");
        allowance[msg.sender][to] = amount;
        if (emptyReturn) assembly { return(0, 0) }
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        return _move(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (falseReturn) return false;
        allowance[from][msg.sender] -= amount;
        return _move(from, to, amount);
    }

    function _move(address from, address to, uint256 amount) private returns (bool) {
        if (falseReturn) return false;
        balanceOf[from] -= amount;
        balanceOf[to] += amount - fee;
        totalSupply -= fee;
        if (emptyReturn) assembly { return(0, 0) }
        return true;
    }

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
        totalSupply += msg.value;
    }

    function withdraw(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "unwrap callback");
    }
}

contract StandardVaultMock {
    string public name = "Mock vault share";
    string public symbol = "MVS";
    uint8 public decimals = 18;
    address public immutable asset;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public rate = 1e18;
    uint256 public allowanceAtDeposit;
    bool public paused;
    bool public noMint;
    bool public falseTransfer;
    uint256 public reportExtra;
    uint256 public burnExtra;
    uint256 public transferFee;

    constructor(address a) {
        asset = a;
    }

    function setRate(uint256 r) external {
        rate = r;
    }

    function setPaused(bool p) external {
        paused = p;
    }

    function faults(bool n, bool f, uint256 reported, uint256 burn, uint256 fee_) external {
        noMint = n;
        falseTransfer = f;
        reportExtra = reported;
        burnExtra = burn;
        transferFee = fee_;
    }

    function totalAssets() external view returns (uint256) {
        return convertToAssets(totalSupply);
    }

    function convertToAssets(uint256 s) public view returns (uint256) {
        return s * rate / 1e18;
    }

    function convertToShares(uint256 a) public view returns (uint256) {
        return a * 1e18 / rate;
    }

    function previewDeposit(uint256 a) public view returns (uint256) {
        return convertToShares(a);
    }

    function previewMint(uint256 s) public view returns (uint256) {
        return (s * rate + 1e18 - 1) / 1e18;
    }

    function previewWithdraw(uint256 a) public view returns (uint256) {
        return (a * 1e18 + rate - 1) / rate;
    }

    function previewRedeem(uint256 s) public view returns (uint256) {
        return convertToAssets(s);
    }

    function maxDeposit(address) external view returns (uint256) {
        return paused ? 0 : type(uint256).max;
    }

    function maxMint(address) external view returns (uint256) {
        return paused ? 0 : type(uint256).max;
    }

    function maxRedeem(address o) external view returns (uint256) {
        return paused ? 0 : balanceOf[o];
    }

    function maxWithdraw(address o) external view returns (uint256) {
        return paused ? 0 : previewRedeem(balanceOf[o]);
    }

    function _token(bytes memory data) private {
        (bool ok, bytes memory ret) = asset.call(data);
        require(ok && (ret.length == 0 || abi.decode(ret, (bool))), "token failed");
    }

    function deposit(uint256 a, address to) external returns (uint256) {
        uint256 s = previewDeposit(a);
        _deposit(a, s, to);
        return s + reportExtra;
    }

    function mint(uint256 s, address to) external returns (uint256) {
        uint256 a = previewMint(s);
        _deposit(a, s, to);
        return a;
    }

    function _deposit(uint256 a, uint256 s, address to) private {
        require(!paused, "paused");
        allowanceAtDeposit = IVaultToken(asset).allowance(msg.sender, address(this));
        _token(abi.encodeWithSignature("transferFrom(address,address,uint256)", msg.sender, address(this), a));
        if (!noMint) {
            balanceOf[to] += s;
            totalSupply += s;
        }
    }

    function redeem(uint256 s, address to, address owner) external returns (uint256) {
        uint256 a = previewRedeem(s);
        _withdraw(a, s, to, owner);
        return a + reportExtra;
    }

    function withdraw(uint256 a, address to, address owner) external returns (uint256) {
        uint256 s = previewWithdraw(a);
        _withdraw(a, s, to, owner);
        return s;
    }

    function _withdraw(uint256 a, uint256 s, address to, address owner) private {
        require(!paused, "paused");
        if (msg.sender != owner) allowance[owner][msg.sender] -= s;
        balanceOf[owner] -= s + burnExtra;
        totalSupply -= s + burnExtra;
        _token(abi.encodeWithSignature("transfer(address,uint256)", to, a));
    }

    function approve(address to, uint256 a) external returns (bool) {
        allowance[msg.sender][to] = a;
        return true;
    }

    function transfer(address to, uint256 s) external returns (bool) {
        return _transfer(msg.sender, to, s);
    }

    function transferFrom(address from, address to, uint256 s) external returns (bool) {
        allowance[from][msg.sender] -= s;
        return _transfer(from, to, s);
    }

    function _transfer(address from, address to, uint256 s) private returns (bool) {
        require(!paused, "paused");
        if (falseTransfer) return false;
        balanceOf[from] -= s;
        balanceOf[to] += s - transferFee;
        totalSupply -= transferFee;
        return true;
    }
}
