// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {PanopticFactory} from "@contracts/PanopticFactory.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IV3CompatibleOracle} from "@interfaces/IV3CompatibleOracle.sol";

contract MineUSDT_WBTC_5bpsPanopticPoolDeploymentSalt is Script {
    // Deployed Pyth->UniOracle contract: https://uniscan.xyz/address/0x79B9f997752D2371790A7CF48d51b3E97a115e4F
    address constant ORACLE_CONTRACT = 0x79B9f997752D2371790A7CF48d51b3E97a115e4F;

    // PanopticFactory address: https://panoptic.xyz/docs/contracts/deployment-addresses
    address constant PANOPTIC_FACTORY = 0x0000000000000CF008e9bf9D01f8306029724c80;

    // USDT/WBTC pool details for Unichain
    address constant USDT = 0x9151434b16b9763660705744891fA906F660EcC5; // Unichain USDT
    address constant WBTC = 0x927B51f251480a681271180DA4de28D44EC4AfB8; // Unichain WBTC
    uint24 constant FEE = 500; // 0.05% fee tier
    int24 constant TICK_SPACING = 10; // For 0.05% fee tier

    function run() external {
        require(PANOPTIC_FACTORY != address(0), "Update PANOPTIC_FACTORY address");

        // Create the PoolKey struct
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(USDT < WBTC ? USDT : WBTC),
            currency1: Currency.wrap(USDT < WBTC ? WBTC : USDT),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });

        PanopticFactory factory = PanopticFactory(PANOPTIC_FACTORY);

        // Mining parameters
        address deployerAddress = msg.sender; // The address that will deploy the pool
        uint96 startSalt = 3000000; // Starting salt value
        uint256 loops = 1000000; // Number of iterations to try
        uint256 minTargetRarity = 4; // Stop when we find at least 3 leading zeros

        // Calculate and log the Pool ID
        PoolId poolId = poolKey.toId();

        console.log("Mining salt for deployer:", deployerAddress);
        console.log("Target rarity (leading zeros):", minTargetRarity);
        console.log("Max iterations:", loops);
        console.log("");
        console.log("Pool Key Details:");
        console.log("Currency0:", Currency.unwrap(poolKey.currency0));
        console.log("Currency1:", Currency.unwrap(poolKey.currency1));
        console.log("Fee:", poolKey.fee);
        console.log("Tick Spacing:", poolKey.tickSpacing);
        console.log("Hooks:", address(poolKey.hooks));
        console.log("");
        console.log("Calculated Pool ID:");
        console.logBytes32(PoolId.unwrap(poolId));
        console.log("");

        // Mine for the best salt
        (uint96 bestSalt, uint256 highestRarity) = factory.minePoolAddress(
            deployerAddress,
            ORACLE_CONTRACT,
            poolKey,
            startSalt,
            loops,
            minTargetRarity
        );

        console.log("=== MINING RESULTS ===");
        console.log("Best salt found:", bestSalt);
        console.log("Leading zeros:", highestRarity);

        // Show what the resulting pool address would be
        bytes32 finalSalt = bytes32(
            abi.encodePacked(
                uint80(uint160(deployerAddress) >> 80),
                uint80(uint256(keccak256(abi.encode(poolKey, ORACLE_CONTRACT)))),
                bestSalt
            )
        );

        // Note: You'd need to import ClonesWithImmutableArgs to get the exact address
        console.log("Final salt (bytes32):");
        console.logBytes32(finalSalt);

        console.log("");
        console.log("To deploy with this salt, update your deploy script:");
        console.log("uint96 salt =", bestSalt, ";");
    }
}
