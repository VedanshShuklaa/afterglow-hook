// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {AfterglowHook} from "../src/AfterglowHook.sol";

/// @dev Shared by the deployment script and the real CREATE2 deployment test.
library AfterglowSalt {
    function find(address deployer, bytes32 initCodeHash) internal pure returns (bytes32 salt, address predicted) {
        uint160 flags = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG;
        for (uint256 i; i < 1_000_000; ++i) {
            salt = bytes32(i);
            predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
            if (uint160(predicted) & Hooks.ALL_HOOK_MASK == flags) return (salt, predicted);
        }
        revert("No hook salt found within search limit");
    }
}

contract DeployAfterglow is Script {
    // Foundry's default deterministic CREATE2 deployer. Must exist on the target chain.
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() public returns (AfterglowHook hook) {
        address managerAddress = vm.envAddress("POOL_MANAGER");
        require(managerAddress.code.length != 0, "POOL_MANAGER must contain deployed code");
        require(CREATE2_DEPLOYER.code.length != 0, "CREATE2 deployer missing on this chain");
        IPoolManager manager = IPoolManager(managerAddress);
        bytes32 initCodeHash = keccak256(abi.encodePacked(type(AfterglowHook).creationCode, abi.encode(manager)));
        (bytes32 salt, address predicted) = AfterglowSalt.find(CREATE2_DEPLOYER, initCodeHash);
        require(predicted.code.length == 0, "Hook already deployed at predicted address");
        vm.startBroadcast();
        hook = new AfterglowHook{salt: salt}(manager);
        vm.stopBroadcast();
        require(address(hook) == predicted, "Unexpected CREATE2 address");
        console2.log("Afterglow hook:", address(hook));
        console2.log("PoolManager:", managerAddress);
    }
}
