// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import "../src/PythToV3Oracle.sol";

contract Deploy is Script {
    function run() external {
        vm.startBroadcast();

        IPyth pyth = IPyth(
            // From: https://docs.pyth.network/price-feeds/contract-addresses/evm
            0x2880aB155794e7179c9eE2e38200202908C17B43 // Pyth on unichain
        );

        // From: https://www.pyth.network/developers/price-feed-ids
        bytes32 btcUsdPriceFeedId = 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43;
        // Revert if the price is >7200s <=> 2hrs old, as the BTC<>USD feed should update every hour
        uint256 maxPythPriceAge = 7200;
        // In the USDC/WBTC v4 market this test is written around, token0 has 6 decimals and token1 has 8
        // And we're shouldInvert, so it should be 6-8 rather than 8-6
        int8 decimalDifferenceFromToken0ToToken1 = -2;
        // Do invert - oracle is USD per BTC and we want BTC (token1) per USD (token0)
        bool shouldInvert = true;

        PythToV3Oracle oracle = new PythToV3Oracle(
            pyth,
            btcUsdPriceFeedId,
            maxPythPriceAge,
            decimalDifferenceFromToken0ToToken1,
            shouldInvert
        );

        console.log("PythToV3Oracle deployed at:", address(oracle));

        vm.stopBroadcast();
    }
}
