// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {FeeToken, FeeArenaMock, FeeTournamentMock, FeeReject} from "../mocks/FeeMocks.sol";

interface IFeeCollector {
    function collectArena(address arena) external;
    function collectTournament(address tournament, uint256 id) external;
    function withdrawETH(address to, uint256 amount) external;
    function withdrawToken(address token, address to, uint256 amount) external;
    function owner() external view returns (address);
}

contract FeeCollectorTest is Test {
    IFeeCollector collector;
    address constant USER = address(123);

    function setUp() public {
        bytes memory code = abi.encodePacked(vm.readFileBinary("artifacts/fees.bin"), abi.encode(address(this)));
        address deployed;
        assembly { deployed := create(0, add(code, 32), mload(code)) }
        require(deployed != address(0) && deployed.code.length <= 24576 && code.length <= 49152);
        collector = IFeeCollector(deployed);
        vm.deal(address(this), 10 ether);
    }

    function testAnyoneCanCollectButOnlyOwnerCanWithdrawETH() public {
        FeeArenaMock arena = new FeeArenaMock();
        arena.fund{value: 1 ether}(address(collector));
        vm.prank(USER);
        collector.collectArena(address(arena));
        require(address(collector).balance == 1 ether && arena.credits(address(collector)) == 0);
        vm.prank(USER);
        vm.expectRevert();
        collector.withdrawETH(USER, 1 ether);
        collector.withdrawETH(USER, 1 ether);
        require(USER.balance == 1 ether && address(collector).balance == 0);
        vm.expectRevert();
        collector.collectArena(address(arena));
    }

    function testShareFeeCollectionAndTokenWithdrawal() public {
        FeeToken token = new FeeToken();
        FeeTournamentMock tournament = new FeeTournamentMock(address(collector), token);
        token.mint(address(tournament), 1000);
        vm.prank(USER);
        collector.collectTournament(address(tournament), 7);
        require(token.balanceOf(address(collector)) == 25 && token.balanceOf(address(tournament)) == 975);
        vm.prank(USER);
        vm.expectRevert();
        collector.withdrawToken(address(token), USER, 25);
        collector.withdrawToken(address(token), USER, 25);
        require(token.balanceOf(USER) == 25);
        vm.expectRevert();
        collector.collectTournament(address(tournament), 7);
    }

    function testRejectedWithdrawalLeavesAssetsAvailable() public {
        vm.deal(address(collector), 1 ether);
        address recipient = address(new FeeReject());
        vm.expectRevert();
        collector.withdrawETH(recipient, 1 ether);
        require(address(collector).balance == 1 ether);
        collector.withdrawETH(USER, 1 ether);
        require(USER.balance == 1 ether);
    }

    function testZeroOwnerAndZeroWithdrawalRecipientRejected() public {
        require(collector.owner() == address(this));
        vm.deal(address(collector), 1 ether);
        vm.expectRevert();
        collector.withdrawETH(address(0), 1 ether);
        assertEq(address(collector).balance, 1 ether, "rejected recipient consumed ETH");
        collector.withdrawETH(USER, 1 ether);
        assertEq(USER.balance, 1 ether);
        FeeToken token = new FeeToken();
        token.mint(address(collector), 100);
        vm.expectRevert();
        collector.withdrawToken(address(token), address(0), 100);
        assertEq(token.balanceOf(address(collector)), 100, "rejected recipient consumed tokens");
        assertEq(token.balanceOf(address(0)), 0);
        collector.withdrawToken(address(token), USER, 100);
        assertEq(token.balanceOf(USER), 100);
        bytes memory code = abi.encodePacked(vm.readFileBinary("artifacts/fees.bin"), abi.encode(address(0)));
        address deployed;
        assembly { deployed := create(0, add(code, 32), mload(code)) }
        require(deployed == address(0));
    }
}
