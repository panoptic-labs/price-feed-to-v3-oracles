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

        PythToV3Oracle oracle = new PythToV3Oracle(
            pyth,
            // ETH/USD
            0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace,
            // Revert if prices >2hrs old
            7200,
            -12, // token1<=>USDC decimals (6) minus token0<=>ETH decimals (18)
            false // No need to invert - the Pyth feed returns USD per ETH, and the Uni pool is USDC (token1) / ETH (token0)
        );

        console.log("PythToV3Oracle deployed at:", address(oracle));

        vm.stopBroadcast();
    }
}
