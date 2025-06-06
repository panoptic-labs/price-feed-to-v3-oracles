// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {PanopticFactory} from "@contracts/PanopticFactory.sol";
import {PanopticPool} from "@contracts/PanopticPool.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IV3CompatibleOracle} from "@interfaces/IV3CompatibleOracle.sol";

contract DeployUSDC_WBTC_30bpsPanopticPool is Script {
    // Deployed Pyth->UniOracle contract: https://uniscan.xyz/address/0x79B9f997752D2371790A7CF48d51b3E97a115e4F
    address constant ORACLE_CONTRACT = 0x79B9f997752D2371790A7CF48d51b3E97a115e4F;

    // PanopticFactory address: https://panoptic.xyz/docs/contracts/deployment-addresses
    address constant PANOPTIC_FACTORY = 0x0000000000000CF008e9bf9D01f8306029724c80;

    // USDC/WBTC pool details for Unichain
    address constant USDC = 0x078D782b760474a361dDA0AF3839290b0EF57AD6; // Unichain USDC
    address constant WBTC = 0x927B51f251480a681271180DA4de28D44EC4AfB8; // Unichain WBTC
    uint24 constant FEE = 3000; // 0.3% fee tier
    int24 constant TICK_SPACING = 60; // For 0.3% fee tier

    function run() external {
        require(PANOPTIC_FACTORY != address(0), "Update PANOPTIC_FACTORY address");

        vm.startBroadcast();

        // Create the PoolKey struct
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(USDC < WBTC ? USDC : WBTC),
            currency1: Currency.wrap(USDC < WBTC ? WBTC : USDC),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0)) // No hooks for basic pool
        });

        PanopticFactory factory = PanopticFactory(PANOPTIC_FACTORY);

        // Salt retrieved using ./MineUSDC_WBTC_3bpsPanopticPoolDeploymentSalt
        uint96 salt = 2054895;

        // Calculate and log the Pool ID
        PoolId poolId = poolKey.toId();

        console.log("Deploying Panoptic Pool with:");
        console.log("Oracle:", ORACLE_CONTRACT);
        console.log("Currency0:", Currency.unwrap(poolKey.currency0));
        console.log("Currency1:", Currency.unwrap(poolKey.currency1));
        console.log("Fee:", poolKey.fee);
        console.log("Tick Spacing:", poolKey.tickSpacing);
        console.log("");
        // Confirm this matches what you find in the Uni explorer - e.g.: https://app.uniswap.org/explore/pools/unichain/0x764afe9ab22a5c80882918bb4e59b954912b17a22c3524c68a8cf08f7386e08f
        console.log("Calculated Pool ID:");
        console.logBytes32(PoolId.unwrap(poolId));
        console.log("Salt:", salt);

        // Check if pool already exists
        PanopticPool existingPool = factory.getPanopticPool(poolKey, IV3CompatibleOracle(ORACLE_CONTRACT));
        if (address(existingPool) != address(0)) {
            console.log("Pool already exists at:", address(existingPool));
            vm.stopBroadcast();
            return;
        }

        // Deploy the new Panoptic Pool
        PanopticPool newPool = factory.deployNewPool(
            IV3CompatibleOracle(ORACLE_CONTRACT),
            poolKey,
            salt
        );

        console.log("New Panoptic Pool deployed at:", address(newPool));

        vm.stopBroadcast();
    }
}
