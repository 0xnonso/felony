// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IVaultToken} from "../Interfaces.sol";
import {VaultAssetMock, StandardVaultMock} from "../mocks/VaultMocks.sol";

interface IVaultHarness {
    function enter(uint256) external returns (uint256);
    function enterNative() external payable returns (uint256);
    function exit(uint256) external returns (uint256);
    function exitNative(uint256) external returns (uint256);
    function sendShares(address, uint256) external;
}

interface IStandardVault {
    function asset() external view returns (address);
    function deposit(uint256, address) external returns (uint256);
    function redeem(uint256, address, address) external returns (uint256);
    function previewRedeem(uint256) external view returns (uint256);
    function convertToAssets(uint256) external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

abstract contract VaultTestDeploy is Test {
    function _deploy(address vault) internal returns (IVaultHarness h) {
        bytes memory code = abi.encodePacked(vm.readFileBinary("artifacts/vault_harness.bin"), abi.encode(vault));
        require(code.length <= 49152, "fixture initcode limit");
        address a;
        assembly { a := create(0, add(code, 32), mload(code)) }
        require(a != address(0) && a.code.length > 0 && a.code.length <= 24576, "fixture deployment");
        h = IVaultHarness(a);
    }
}

contract VaultIntegrationTest is VaultTestDeploy {
    VaultAssetMock private asset;
    StandardVaultMock private vault;
    IVaultHarness private h;
    bool private rejectETH;
    bool private reenter;
    bool private attempted;
    bool private reentered;

    function setUp() public {
        vm.deal(address(this), 100 ether);
        asset = new VaultAssetMock();
        vault = new StandardVaultMock(address(asset));
        h = _deploy(address(vault));
        asset.mint(address(vault), 100 ether);
        vm.deal(address(asset), 1000 ether);
    }

    function testVaultConstructorRequiresDecodableAsset() public {
        vm.expectRevert();
        this.deployVaultHarness(address(0xdead));
        vm.expectRevert();
        this.deployVaultHarness(address(asset));
    }

    function deployVaultHarness(address target) external returns (IVaultHarness) {
        return _deploy(target);
    }

    receive() external payable {
        require(!rejectETH, "reject receive");
        if (reenter) {
            attempted = true;
            (reentered,) = address(h).call(abi.encodeCall(IVaultHarness.exitNative, (uint256(1))));
        }
    }

    function _reject(bytes memory data) private {
        (bool ok,) = address(h).call(data);
        require(!ok, "bad operation accepted");
    }

    function testNativeWrapDepositGrowthRedeemExactApprovals() public {
        uint256 s = h.enterNative{value: 1 ether}();
        require(s == 1 ether, "minted shares");
        require(
            vault.allowanceAtDeposit() == 1 ether && asset.allowance(address(h), address(vault)) == 0,
            "exact/reset allowance"
        );
        vault.setRate(11e17);
        uint256 before_ = address(this).balance;
        require(h.exitNative(s) == 1.1 ether && address(this).balance - before_ == 1.1 ether, "native actual receipt");
        require(
            vault.balanceOf(address(h)) == 0 && asset.balanceOf(address(h)) == 0 && address(h).balance == 0,
            "stranded position"
        );
    }

    function testGenericERC20AndNoReturnToken() public {
        asset.mint(address(this), 101);
        asset.approve(address(h), 101);
        asset.fault(false, true, 0);
        require(h.enter(101) == 101, "no-return deposit");
        vault.setRate(15e17);
        require(h.exit(101) == 151 && asset.balanceOf(address(this)) == 151, "ERC20 measured return");
        require(asset.allowance(address(h), address(vault)) == 0, "approval cleanup");
    }

    function testIndependentOwnersShareTransferAndRounding() public {
        IVaultHarness other = _deploy(address(vault));
        uint256 a = h.enterNative{value: 101}();
        vault.setRate(11e17);
        uint256 b = other.enterNative{value: 103}();
        require(b == 93, "floor deposit rounding");
        h.sendShares(address(other), 17);
        require(vault.balanceOf(address(h)) == 84 && vault.balanceOf(address(other)) == b + 17, "share transfer");
        vault.setRate(15e17);
        require(h.exitNative(a - 17) == 126, "first owner redemption");
        require(other.exitNative(b + 17) == 165 && vault.totalSupply() == 0, "second owner redemption");
    }

    function testDepositRejectsFalseFeeAndMissingOrMisreportedShares() public {
        asset.mint(address(this), 100);
        asset.approve(address(h), 100);
        asset.fault(true, false, 0);
        _reject(abi.encodeCall(IVaultHarness.enter, (uint256(100))));
        asset.fault(false, false, 1);
        _reject(abi.encodeCall(IVaultHarness.enter, (uint256(100))));
        asset.fault(false, false, 0);
        vault.faults(true, false, 0, 0, 0);
        _reject(abi.encodeCall(IVaultHarness.enter, (uint256(100))));
        vault.faults(false, false, 1, 0, 0);
        _reject(abi.encodeCall(IVaultHarness.enter, (uint256(100))));
        require(
            asset.balanceOf(address(this)) == 100 && vault.balanceOf(address(h)) == 0
                && asset.allowance(address(h), address(vault)) == 0,
            "failed deposit persisted"
        );
    }

    function testRedeemRejectsWrongBurnOrReportedAssetsAndCanRetry() public {
        h.enterNative{value: 100}();
        vault.faults(false, false, 0, 1, 0);
        _reject(abi.encodeCall(IVaultHarness.exit, (uint256(50))));
        vault.faults(false, false, 1, 0, 0);
        _reject(abi.encodeCall(IVaultHarness.exit, (uint256(50))));
        vault.faults(false, false, 0, 0, 0);
        vault.setPaused(true);
        _reject(abi.encodeCall(IVaultHarness.exit, (uint256(50))));
        require(vault.balanceOf(address(h)) == 100, "failed redemption burned position");
        vault.setPaused(false);
        require(h.exitNative(100) == 100, "retry redemption");
    }

    function testShareTransferRejectsFalseFeePauseAndInvalidRecipients() public {
        h.enterNative{value: 100}();
        address to = address(0xbeef);
        vault.faults(false, true, 0, 0, 0);
        _reject(abi.encodeCall(IVaultHarness.sendShares, (to, uint256(10))));
        vault.faults(false, false, 0, 0, 1);
        _reject(abi.encodeCall(IVaultHarness.sendShares, (to, uint256(10))));
        vault.faults(false, false, 0, 0, 0);
        vault.setPaused(true);
        _reject(abi.encodeCall(IVaultHarness.sendShares, (to, uint256(10))));
        vault.setPaused(false);
        _reject(abi.encodeCall(IVaultHarness.sendShares, (address(h), uint256(10))));
        _reject(abi.encodeCall(IVaultHarness.sendShares, (address(0), uint256(10))));
        require(vault.balanceOf(address(h)) == 100 && vault.balanceOf(to) == 0, "failed transfer persisted");
        h.sendShares(to, 100);
        require(vault.balanceOf(to) == 100, "standard ERC20 share claim");
    }

    function testNativeReceiverFailureRollsBackAndCallerLockStopsReentry() public {
        h.enterNative{value: 100}();
        rejectETH = true;
        _reject(abi.encodeCall(IVaultHarness.exitNative, (uint256(100))));
        require(vault.balanceOf(address(h)) == 100, "receiver rejection burned shares");
        rejectETH = false;
        reenter = true;
        require(h.exitNative(100) == 100 && attempted && !reentered, "caller lock failed");
    }

    function testZeroRecoveryCanSettleTotalLoss() public {
        h.enterNative{value: 100}();
        vault.setRate(0);
        require(h.exit(100) == 0 && vault.balanceOf(address(h)) == 0, "zero recovery blocked");
    }
}

contract VaultStataForkTest is VaultTestDeploy {
    address private constant STATA = 0x0bfc9d54Fc184518A81162F8fB99c2eACa081202;
    address private constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    receive() external payable {}

    function testOfficialWethStataDepositGrowthTransferRedeem() public {
        string memory url = vm.envOr("FELONY_AAVE_RPC_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
        }
        uint256 forkBlock = vm.envOr("FELONY_AAVE_BLOCK", uint256(26_444_402));
        if (forkBlock == 0) {
            vm.createSelectFork(url);
        } else {
            vm.createSelectFork(url, forkBlock);
        }
        emit log_named_uint("Ethereum fork block", block.number);
        require(block.chainid == 1 && (forkBlock == 0 || block.number == forkBlock), "fork context");
        IStandardVault v = IStandardVault(STATA);
        require(v.asset() == WETH, "official stata asset not WETH");
        IVaultHarness a = _deploy(STATA);
        IVaultHarness b = _deploy(STATA);
        vm.deal(address(this), 10 ether);
        uint256 sa = a.enterNative{value: 0.11 ether + 3}();
        uint256 sb = b.enterNative{value: 0.17 ether + 7}();
        require(
            sa > 0 && sb > 0 && v.balanceOf(address(a)) == sa && v.balanceOf(address(b)) == sb, "live share deposits"
        );
        require(
            IVaultToken(WETH).allowance(address(a), STATA) == 0 && IVaultToken(WETH).allowance(address(b), STATA) == 0,
            "live residual allowance"
        );
        uint256 initial = v.previewRedeem(sa);
        vm.warp(block.timestamp + 1 days);
        uint256 grown = v.previewRedeem(sa);
        require(grown > initial, "pinned reserve did not accrue");
        uint256 moved = sa / 3;
        a.sendShares(address(b), moved);
        require(v.balanceOf(address(b)) == sb + moved, "live share transfer");
        uint256 quoteA = v.previewRedeem(sa - moved);
        uint256 before_ = address(this).balance;
        uint256 actualA = a.exitNative(sa - moved);
        require(actualA == quoteA && address(this).balance - before_ == actualA, "live actual redemption A");
        uint256 quoteB = v.previewRedeem(sb + moved);
        uint256 actualB = b.exitNative(sb + moved);
        require(
            actualB == quoteB && v.balanceOf(address(a)) == 0 && v.balanceOf(address(b)) == 0, "live owner isolation B"
        );
        emit log_named_uint("initial A shares", sa);
        emit log_named_uint("initial B shares", sb);
        emit log_named_uint("A redemption", actualA);
        emit log_named_uint("B redemption", actualB);
    }
}
