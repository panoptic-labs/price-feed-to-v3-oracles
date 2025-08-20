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
    RedstoneToV3Oracle wstethOracle;

    bytes32 ethUsdPriceFeedId = bytes32("ETH");
    bytes32 wstethEthPriceFeedId = bytes32("wstETH/ETH");

    IRedstoneAdapter redstoneAdapter = IRedstoneAdapter(
        0xFB1267A29C0aa19daae4a483ea895862A69e4AA5 // RedstoneAdapter on unichain
    );

    // https://app.uniswap.org/explore/pools/unichain/0xd10d359f50ba8d1e0b6c30974a65bf06895fba4bf2b692b2c75d987d3b6b863d
    PoolId wstETHPoolId = PoolId.wrap(0xd10d359f50ba8d1e0b6c30974a65bf06895fba4bf2b692b2c75d987d3b6b863d);
    // From: https://docs.uniswap.org/contracts/v4/deployments#unichain-130
    IStateView constant stateView = IStateView(0x86e8631A016F9068C3f085fAF484Ee3F5fDee8f2);

    function setUp() public {
        uint256 forkId = vm.createFork(vm.rpcUrl("unichain"));
        vm.selectFork(forkId);
        wstethOracle = new RedstoneToV3Oracle(
            redstoneAdapter,
            wstethEthPriceFeedId,
            0, // both wstETH and ETH have 18 decimals, so difference is 0
            true, // need to invertTokenOrder - ETH is token0 and wstETH is token1 on Uniswap, so the tick is wstETH per ETH; the redstone price is ETH per wstETH
            8 // redstoneDecimals
        );

        // Create additional oracles for comprehensive testing
        ethOracle = new RedstoneToV3Oracle(
            redstoneAdapter,
            ethUsdPriceFeedId,
            -12, // ETH has 18 decimals, USDC has 6, so difference is -12
            false, // no inversion needed - ETH is token0, USDC is token1, and redstone gives USDC per ETH
            8 // redstoneDecimals
        );
    }

    function testSlot0ReturnsValidPrice() public {
        (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 obsIdx,
            uint16 obsCard,
            uint16 obsCardNext,
            uint8 feeProtocol,
            bool unlocked
        ) = wstethOracle.slot0();

        // Basic sanity checks
        assertTrue(tick < 0, "wstETH/ETH tick should be < 0, as it takes <1 wstETH to get an ETH");
        assertEq(feeProtocol, 0, "feeProtocol always 0");
        assertTrue(unlocked, "unlocked always true");
        assertEq(obsCard, 65535, "observationCardinality should be max uint16");
        assertEq(obsCardNext, 65535, "observationCardinalityNext should be max uint16");

        // Verify tick and sqrtPrice are consistent
        uint160 sqrtPriceFromTick = TickMath.getSqrtRatioAtTick(tick);
        assertEq(sqrtPriceX96, sqrtPriceFromTick, "tick-snapped sqrtPrice from oracle not equal to sqrtPriceFromTick");

        console.log("wstETH Oracle tick: ", tick);
    }

    function testSlot0ReturnsValidPriceForETH() public {
        (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 obsIdx,
            uint16 obsCard,
            uint16 obsCardNext,
            uint8 feeProtocol,
            bool unlocked
        ) = ethOracle.slot0();

        // Basic sanity checks for ETH/USD
        assertLt(int256(tick), 0, "ETH/USD tick should be < 0, unless ETH broke $10^12");
        assertEq(feeProtocol, 0, "feeProtocol always 0");
        assertTrue(unlocked, "unlocked always true");
        assertEq(obsCard, 65535, "observationCardinality should be max uint16");
        assertEq(obsCardNext, 65535, "observationCardinalityNext should be max uint16");

        // Verify tick and sqrtPrice are consistent
        uint160 sqrtPriceFromTick = TickMath.getSqrtRatioAtTick(tick);
        assertEq(sqrtPriceX96, sqrtPriceFromTick, "tick-snapped sqrtPrice from oracle not equal to sqrtPriceFromTick");

        console.log("ETH Oracle tick: ", tick);
    }

    function testObservationsReturnsValidData() public {
        for (uint256 i = 0; i < 10; i++) {
            (uint32 blockTimestamp, int56 tickCumulative, uint160 secondsPerLiquidityX128, bool initialized) =
                wstethOracle.observations(i);

            // Basic checks
            assertTrue(initialized, "All observations should be initialized");
            assertEq(secondsPerLiquidityX128, 0, "secondsPerLiquidity always 0 in V4");
            assertLe(blockTimestamp, block.timestamp, "blockTimestamp shouldn't be in future");
            assertEq(
                blockTimestamp, uint32(block.timestamp - 65534 + i), "blockTimestamp should be now - 65534 + index"
            );
        }
    }

    function testObservationsConsistency() public {
        // Get two consecutive observations
        (uint32 ts0, int56 cumulative0,,) = wstethOracle.observations(0);
        (uint32 ts1, int56 cumulative1,,) = wstethOracle.observations(1);

        // Calculate the tick from cumulative difference
        int24 derivedTick = int24((cumulative1 - cumulative0) / int56(uint56(ts1 - ts0)));

        // Should match current tick from slot0
        (, int24 currentTick,,,,,) = wstethOracle.slot0();
        assertEq(derivedTick, currentTick, "Derived tick from observations should match slot0 tick");
    }

    function testObserveReturnsValidData() public {
        uint32[] memory secondsAgos = new uint32[](5);
        secondsAgos[0] = 0; // now
        secondsAgos[1] = 60; // 1 minute ago
        secondsAgos[2] = 300; // 5 minutes ago
        secondsAgos[3] = 600; // 10 minutes ago
        secondsAgos[4] = 1800; // 30 minutes ago

        (int56[] memory tickCumulatives, uint160[] memory liquidityCumulatives) = wstethOracle.observe(secondsAgos);

        assertEq(tickCumulatives.length, secondsAgos.length, "Should return same length arrays");
        assertEq(liquidityCumulatives.length, secondsAgos.length, "Should return same length arrays");

        // All liquidity cumulatives should be 0
        for (uint256 i = 0; i < liquidityCumulatives.length; i++) {
            assertEq(liquidityCumulatives[i], 0, "liquidityCumulatives always 0");
        }

        // Tick cumulatives should be increasing in absolute value (older timestamps = smaller factor to multiply tick by)
        for (uint256 i = 0; i < tickCumulatives.length - 1; i++) {
            assertGt(
                abs(tickCumulatives[i]),
                abs(tickCumulatives[i + 1]),
                "Newer observations should have larger absolute-value cumulatives"
            );
        }
    }

    function abs(int56 num) internal pure returns (uint56) {
        if (num < 0) return uint56(-num);
        return uint56(num);
    }

    function testObserveTWAPCalculation() public {
        uint32[] memory secondsAgos = new uint32[](2);
        // TODO: Fuzz this - all possible combinations of secondsAgos should still result in TWAP equaling current price.
        secondsAgos[0] = 0; // now
        secondsAgos[1] = 600; // 10 minutes ago

        (int56[] memory tickCumulatives,) = wstethOracle.observe(secondsAgos);

        // Calculate TWAP manually
        int24 twap = int24((tickCumulatives[0] - tickCumulatives[1]) / int56(600));

        // Should equal current tick since we use same tick for all observations
        (, int24 currentTick,,,,,) = wstethOracle.slot0();
        assertEq(twap, currentTick, "TWAP should equal current tick");
    }

    function testFuzzObserveTWAPCalculation(uint32 secondsAgo1, uint32 secondsAgo2) public {
        // Ensure reasonable bounds and ordering
        vm.assume(secondsAgo1 <= 86400); // max 1 day
        vm.assume(secondsAgo2 <= 86400);
        vm.assume(secondsAgo1 != secondsAgo2); // must be different

        // Ensure proper ordering (secondsAgo2 > secondsAgo1)
        if (secondsAgo1 > secondsAgo2) {
            (secondsAgo1, secondsAgo2) = (secondsAgo2, secondsAgo1);
        }

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = secondsAgo1;
        secondsAgos[1] = secondsAgo2;

        (int56[] memory tickCumulatives,) = wstethOracle.observe(secondsAgos);

        // Calculate TWAP manually
        uint32 timeDiff = secondsAgo2 - secondsAgo1;
        int24 twap = int24((tickCumulatives[0] - tickCumulatives[1]) / int56(uint56(timeDiff)));

        // Should equal current tick since we use same tick for all observations
        (, int24 currentTick,,,,,) = wstethOracle.slot0();
        assertEq(twap, currentTick, "TWAP should equal current tick for any time period");
    }

    // TODO: Also fuzz test different length arrays (e.g. anywhere from 1 to max array length secondsAgos)

    function testObserveEmptyArray() public {
        uint32[] memory emptyArray = new uint32[](0);
        (int56[] memory tickCumulatives, uint160[] memory liquidityCumulatives) = wstethOracle.observe(emptyArray);

        assertEq(tickCumulatives.length, 0, "Should return empty array");
        assertEq(liquidityCumulatives.length, 0, "Should return empty array");
    }

    function testObserveLargeArray() public {
        uint32[] memory largeArray = new uint32[](100);
        for (uint256 i = 0; i < largeArray.length; i++) {
            largeArray[i] = uint32(i * 60); // Every minute for 100 minutes
        }

        (int56[] memory tickCumulatives, uint160[] memory liquidityCumulatives) = wstethOracle.observe(largeArray);

        assertEq(tickCumulatives.length, 100, "Should handle large arrays");
        assertEq(liquidityCumulatives.length, 100, "Should handle large arrays");
    }

    function testIncreaseObservationCardinalityNext() public {
        // Should not revert
        wstethOracle.increaseObservationCardinalityNext(16);
        wstethOracle.increaseObservationCardinalityNext(1);
        wstethOracle.increaseObservationCardinalityNext(type(uint16).max);

        // Values shouldn't change since it's a no-op
        (,,, uint16 obsCard, uint16 obsCardNext,,) = wstethOracle.slot0();
        assertEq(obsCard, 65535, "observationCardinality unchanged");
        assertEq(obsCardNext, 65535, "observationCardinalityNext unchanged");
    }

    function testPriceConsistencyAcrossTime() public {
        // Record initial values
        (, int24 initialTick,,,,,) = wstethOracle.slot0();

        // Fast forward time
        vm.warp(block.timestamp + 1000);

        // Values should be the same (since we use current Redstone price from same round)
        (, int24 laterTick,,,,,) = wstethOracle.slot0();
        assertEq(laterTick, initialTick, "Tick should be consistent across time (same Redstone round)");
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

    // Additional test to verify the ordering assumption
    function testObservationsTimestampOrdering() public {
        uint32 prevTimestamp;

        // Test that timestamps increase with index
        for (uint256 i = 0; i < 10; i++) {
            (uint32 timestamp,,,) = wstethOracle.observations(i);

            if (i > 0) {
                assertGt(timestamp, prevTimestamp, "Timestamps should increase with index");
            }

            // Verify the exact formula
            uint32 expectedTimestamp = uint32(block.timestamp - 65534 + i);
            assertEq(timestamp, expectedTimestamp, "Timestamp should match formula");

            prevTimestamp = timestamp;
        }
    }

    // Test multiple oracles to ensure they work with different price feeds
    function testMultipleOracles() public {
        // Test ETH oracle
        (, int24 ethTick,,,,,) = ethOracle.slot0();
        assertLt(ethTick, 0, "ETH/USD tick should be negative, unless ETH crashed below 1 dollar");

        // Test TON oracle
        (, int24 wstethTick,,,,,) = wstethOracle.slot0();
        // TON price varies, so just check it doesn't revert and returns a valid tick
        assertLt(wstethTick, 0, "wstETH per ETH tick should be negative, unless wstETH depegged and is worth <1 ETH");

        console.log("ETH tick: ", ethTick);
        console.log("wstETH tick: ", wstethTick);
    }

    // Test that different oracles have independent observations
    function testIndependentObservations() public {
        // Get observations from different oracles
        (uint32 wstethTs0, int56 wstethCumulative0,,) = wstethOracle.observations(0);
        (uint32 ethTs0, int56 ethCumulative0,,) = ethOracle.observations(0);

        // Timestamps should be the same (based on block.timestamp)
        assertEq(wstethTs0, ethTs0, "Timestamps should be the same across oracles");

        // But cumulatives should be different (different ticks)
        if (wstethCumulative0 != 0 || ethCumulative0 != 0) {
            // Only assert if at least one is non-zero to avoid false negatives
            assertTrue(wstethCumulative0 != ethCumulative0, "Cumulatives should be different for different price feeds");
        }
    }

    // Test edge cases with observe function
    function testObserveEdgeCases() public {
        // Test with single element array
        uint32[] memory singleElement = new uint32[](1);
        singleElement[0] = 0;

        (int56[] memory tickCumulatives, uint160[] memory liquidityCumulatives) = wstethOracle.observe(singleElement);

        assertEq(tickCumulatives.length, 1, "Should return array of length 1");
        assertEq(liquidityCumulatives.length, 1, "Should return array of length 1");
        assertEq(liquidityCumulatives[0], 0, "Liquidity cumulative should be 0");
    }

    // Test that the oracle handles the invertTokenOrder correctly
    function testTokenOrderInversion() public {
        // wstethOracle has invertTokenOrder = true
        (, int24 wstethTick,,,,,) = wstethOracle.slot0();

        // Create another oracle without inversion to compare
        RedstoneToV3Oracle wstethOracleNoInvert = new RedstoneToV3Oracle(
            redstoneAdapter,
            wstethEthPriceFeedId,
            0,
            false, // no inversion
            8
        );

        (, int24 noInvertTick,,,,,) = wstethOracleNoInvert.slot0();

        // The ticks should be negatives of each other
        assertEq(wstethTick, -noInvertTick, "Inverted tick should be negative of non-inverted tick");
    }

    // Test behavior with different decimal configurations
    function testDecimalDifferences() public {
        // Test that oracles with different decimal differences work correctly
        RedstoneToV3Oracle testOracle = new RedstoneToV3Oracle(
            redstoneAdapter,
            ethUsdPriceFeedId,
            -6, // Different decimal difference
            false,
            8
        );

        // Should not revert
        (, int24 tick,,,,,) = testOracle.slot0();
        assertTrue(tick > TickMath.MIN_TICK && tick < TickMath.MAX_TICK, "Tick should be within valid range");
    }
}
