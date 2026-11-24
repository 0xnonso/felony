// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {RandomOracle} from "../Interfaces.sol";

interface SubscriptionCoordinator {
    function createSubscription() external returns (uint256);
    function fundSubscriptionWithNative(uint256) external payable;
    function addConsumer(uint256, address) external;
    function pendingRequestExists(uint256) external view returns (bool);
}

contract RandomOracleForkTest is Test {
    function testSepoliaCoordinatorAcceptsFeRequest() public {
        string memory url = vm.envOr("FELONY_SEPOLIA_RPC_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(url);
        require(block.chainid == 11155111, "Sepolia only");
        emit log_named_uint("Sepolia fork block", block.number);
        SubscriptionCoordinator coordinator = SubscriptionCoordinator(0x9DdfaCa8183c41ad55329BdeeD9F6A8d53168B1B);
        require(address(coordinator).code.length > 0, "coordinator code missing");
        uint256 subscription = coordinator.createSubscription();
        vm.deal(address(this), 2 ether);
        coordinator.fundSubscriptionWithNative{value: 1 ether}(subscription);
        bytes memory code = abi.encodePacked(
            vm.readFileBinary("artifacts/random_oracle.bin"),
            abi.encode(
                address(coordinator),
                address(this),
                bytes32(0x787d74caea10b2b357790d5b5247c2f63d1d91572a9846f780606e4d953677ae),
                subscription,
                uint16(3),
                uint32(200000),
                uint256(3600),
                true,
                uint256(0)
            )
        );
        address deployed;
        assembly { deployed := create(0, add(code, 32), mload(code)) }
        require(deployed != address(0), "adapter deployment");
        RandomOracle oracle = RandomOracle(deployed);
        coordinator.addConsumer(subscription, deployed);
        oracle.setConsumer(address(this), true);
        uint256 request = oracle.requestRandomness(keccak256("local fork request"));
        require(
            request != 0 && oracle.status(request) == 1 && coordinator.pendingRequestExists(subscription),
            "official coordinator did not accept request"
        );
        require(oracle.requestInfo(request)[0] == uint160(address(this)), "consumer binding");
        emit log_named_uint("request ID (fork only)", request);
    }
}
