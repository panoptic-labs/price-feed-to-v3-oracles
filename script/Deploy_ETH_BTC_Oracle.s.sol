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
        bytes32 ethBtcPriceFeedId = 0xc96458d393fe9deb7a7d63a0ac41e2898a67a7750dbd166673279e06c868df0a; // BTC/ETH
        // Revert if the price is >7200s <=> 2hrs old, as the BTC<>ETH feed should update every hour
        uint256 maxPythPriceAge = 7200;
        // In the ETH/WBTC v4 market this test is written around, token0 has 18 decimals and token1 has 8
        int8 decimalDifferenceFromToken0ToToken1 = -10; // token1<=>WBTC decimals (8) minus token0<=>ETH decimals (18)
        // Do not invert - oracle is BTC per ETH and we want BTC (token1) per ETH (token0)
        bool shouldInvert = false;

        PythToV3Oracle oracle = new PythToV3Oracle(
            pyth,
            ethBtcPriceFeedId,
            maxPythPriceAge,
            decimalDifferenceFromToken0ToToken1,
            shouldInvert
        );

        console.log("PythToV3Oracle deployed at:", address(oracle));

        vm.stopBroadcast();
    }
}
