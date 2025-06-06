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

contract DeployETH_USDT_5bpsPanopticPool is Script {
    // Deployed Pyth->UniOracle contract: https://uniscan.xyz/address/0xc4d0e75EfDbF39509858cB00809d7A59Bf667a71
    // (Note its being reused - was also used earlier to deploy ETH_USDC_5bps)
    address constant ORACLE_CONTRACT = 0xc4d0e75EfDbF39509858cB00809d7A59Bf667a71;

    // PanopticFactory address: https://panoptic.xyz/docs/contracts/deployment-addresses
    address constant PANOPTIC_FACTORY = 0x0000000000000CF008e9bf9D01f8306029724c80;

    // ETH/USDT pool details for Unichain
    address constant ETH = 0x0000000000000000000000000000000000000000; // Unichain ETH
    address constant USDT = 0x9151434b16b9763660705744891fA906F660EcC5; // Unichain USDT0
    uint24 constant FEE = 500; // 0.05% fee tier
    int24 constant TICK_SPACING = 10; // For 0.05% fee tier

    function run() external {
        require(PANOPTIC_FACTORY != address(0), "Update PANOPTIC_FACTORY address");

        vm.startBroadcast();

        // Create the PoolKey struct
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(ETH < USDT ? ETH : USDT), // Ensure currency0 < currency1
            currency1: Currency.wrap(ETH < USDT ? USDT : ETH),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0)) // No hooks for basic pool
        });

        PanopticFactory factory = PanopticFactory(PANOPTIC_FACTORY);

        // Salt retrieved using ./MineETH_USDT_5bpsPanopticPoolDeploymentSalt.s.sol
        uint96 salt = 2025285;

        // Calculate and log the Pool ID
        PoolId poolId = poolKey.toId();

        console.log("Deploying Panoptic Pool with:");
        console.log("Oracle:", ORACLE_CONTRACT);
        console.log("Currency0:", Currency.unwrap(poolKey.currency0));
        console.log("Currency1:", Currency.unwrap(poolKey.currency1));
        console.log("Fee:", poolKey.fee);
        console.log("Tick Spacing:", poolKey.tickSpacing);
        console.log("");
        // Confirm this matches what you find in the Uni explorer - e.g.: https://app.uniswap.org/explore/pools/unichain/0x04b7dd024db64cfbe325191c818266e4776918cd9eaf021c26949a859e654b16
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
