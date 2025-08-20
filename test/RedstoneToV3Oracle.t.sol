// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "forge-std/Test.sol";

import "../src/RedstoneToV3Oracle.sol";
import "@redstone-finance/core/IRedstoneAdapter.sol";
import {TickMath} from "v3-core/libraries/TickMath.sol";
import {FullMath} from "v3-core/libraries/FullMath.sol";
import {IStateView} from "v4-periphery/src/interfaces/IStateView.sol";
import {PoolId} from "v4-core-for-periphery/src/types/PoolId.sol";

contract RedstoneToV3OracleTest is Test {
    RedstoneToV3Oracle ethOracle;
    RedstoneToV3Oracle tonOracle;
    RedstoneToV3Oracle wstethOracle;

    bytes32 ethUsdPriceFeedId = bytes32("ETH");
    bytes32 tonUsdPriceFeedId = bytes32("TON");
    bytes32 wstethEthPriceFeedId = bytes32("wstETH/ETH");

    IRedstoneAdapter redstoneAdapter = IRedstoneAdapter(
        0xFB1267A29C0aa19daae4a483ea895862A69e4AA5 // RedstoneAdapter on unichain
    );

    // https://app.uniswap.org/explore/pools/unichain/0xd10d359f50ba8d1e0b6c30974a65bf06895fba4bf2b692b2c75d987d3b6b863d
    PoolId wstETHPoolId = PoolId.wrap(0xd10d359f50ba8d1e0b6c30974a65bf06895fba4bf2b692b2c75d987d3b6b863d);
    // From: https://docs.uniswap.org/contracts/v4/deployments#unichain-130
    IStateView constant stateView = IStateView(0x86e8631A016F9068C3f085fAF484Ee3F5fDee8f2);

    // And also - this contract is upgradeable - under what circumstances might it get upgraded? Our contracts are non-upgradeable so we won't be able to handle any changes in function signature

    function setUp() public {
        uint256 forkId = vm.createFork(vm.rpcUrl("unichain"));
        vm.selectFork(forkId);
        wstethOracle = new RedstoneToV3Oracle(
           redstoneAdapter,
           wstethEthPriceFeedId,
           0,    // both wstETH and ETH have 18 decimals, so difference is 0
           true, // need to invertTokenOrder - ETH is token0 and wstETH is token1 on Uniswap, so the tick is wstETH per ETH; the redstone price is ETH per wstETH
           8     // redstoneDecimals
       );
    }

    function testSlot0ReturnsValidPrice() public {
        // Test that slot0 does not revert
        (, int24 tick,,,,,) = wstethOracle.slot0();
        console.log("wstETH Oracle tick: ", tick);
    }

    function testPriceComparisonWithV4Pool() public {
        // Get tick from our oracle
        (, int24 oracleTick,,,,,) = wstethOracle.slot0();

        // Get tick from Uniswap V4 pool using StateView singleton
        (, int24 poolTick,,) = stateView.getSlot0(wstETHPoolId);

        console.log("Oracle tick: ", oracleTick);
        console.log("V4 Pool tick: ", poolTick);


        // Convert ticks to comparable prices
        uint256 oraclePrice = convertRawWstethWeiPerEthWeiTickToPrice(oracleTick);
        uint256 poolPrice = convertRawWstethWeiPerEthWeiTickToPrice(poolTick);

        console.log("wstETH/ETH * 10^18 from Oracle: ", oraclePrice);
        console.log("wstETH/ETH * 10^18 from Pool: ", poolPrice);

        uint256 priceDiff = oraclePrice > poolPrice ? oraclePrice - poolPrice : poolPrice - oraclePrice;

        // Check if difference is within 1% (priceDiff / poolPrice < 0.01)
        // priceDiff / poolPrice < 0.01 <=> priceDiff * 100 < poolPrice
        assertLt(priceDiff * 100, poolPrice, "Oracle price should be within 1% of V4 pool price");
    }

    function convertRawWstethWeiPerEthWeiTickToPrice(int24 tick) internal pure returns (uint256) {
        uint160 sqrtPX96 = TickMath.getSqrtRatioAtTick(tick);

        // Put the scale in the denominator to avoid a*b*1e18 overflow.
        uint256 denom = (uint256(1) << 192) / 1e18; // Q192 / 1e18

        return FullMath.mulDiv(uint256(sqrtPX96), uint256(sqrtPX96), denom);
    }
}
