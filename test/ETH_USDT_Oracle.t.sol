// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {FullMath} from "v3-core/libraries/FullMath.sol";
import {PoolId} from "v4-core-for-periphery/types/PoolId.sol";
import {IStateView} from "v4-periphery/interfaces/IStateView.sol";

import "../src/PythToV3Oracle.sol";

contract PythToV3OracleTest is Test {
    PythToV3Oracle oracle;

    // From: https://docs.pyth.network/price-feeds/contract-addresses/evm
    IPyth pyth = IPyth(0x2880aB155794e7179c9eE2e38200202908C17B43);
    // From: https://docs.uniswap.org/contracts/v4/deployments#unichain-130
    IStateView constant stateView = IStateView(0x86e8631A016F9068C3f085fAF484Ee3F5fDee8f2);

    // https://app.uniswap.org/explore/pools/unichain/0x04b7dd024db64cfbe325191c818266e4776918cd9eaf021c26949a859e654b16
    PoolId ethUsdtv4PoolId = PoolId.wrap(0x04b7dd024db64cfbe325191c818266e4776918cd9eaf021c26949a859e654b16);

    // From: https://www.pyth.network/developers/price-feed-ids
    bytes32 ethUsdPriceFeedId = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;
    // Revert if the price is >7200s <=> 2hrs old, as the ETH<>USDC feed should update every hour
    uint256 maxPythPriceAge = 7200;
    // In the ETH/USDT v4 market this test is written around, token0 has 18 decimals and token1 has 6
    int8 decimalDifferenceFromToken0ToToken1 = -12;
    // Do not invert - oracle is USD per ETH and we want USDT (token1) per ETH (token0)
    bool shouldInvert = false;

    function setUp() public {
        uint256 forkId = vm.createFork(vm.rpcUrl("unichain"));
        vm.selectFork(forkId);
        oracle =
            new PythToV3Oracle(pyth, ethUsdPriceFeedId, maxPythPriceAge, decimalDifferenceFromToken0ToToken1, shouldInvert);
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
        ) = oracle.slot0();

        // Basic sanity checks
        assertLt(int256(tick), 0, "tick should be < 0, unless ETH broke $10^12");
        assertEq(feeProtocol, 0, "feeProtocol always 0");
        assertTrue(unlocked, "unlocked always true");
        assertEq(obsCard, 65535, "observationCardinality should be 8");
        assertEq(obsCardNext, 65535, "observationCardinalityNext should be 8");

        // Verify tick and sqrtPrice are consistent
        uint160 sqrtPriceFromTick = TickMath.getSqrtRatioAtTick(tick);
        assertEq(sqrtPriceX96, sqrtPriceFromTick, "tick-snapped sqrtPrice from oracle not equal to sqrtPriceFromTick");
    }

    function testObservationsReturnsValidData() public {
        for (uint256 i = 0; i < 10; i++) {
            (uint32 blockTimestamp, int56 tickCumulative, uint160 secondsPerLiquidityX128, bool initialized) =
                oracle.observations(i);

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
        (uint32 ts0, int56 cumulative0,,) = oracle.observations(0);
        (uint32 ts1, int56 cumulative1,,) = oracle.observations(1);

        // Calculate the tick from cumulative difference
        int24 derivedTick = int24((cumulative1 - cumulative0) / int56(uint56(ts1 - ts0)));

        // Should match current tick from slot0
        (, int24 currentTick,,,,,) = oracle.slot0();
        assertEq(derivedTick, currentTick, "Derived tick from observations should match slot0 tick");
    }

    function testObserveReturnsValidData() public {
        uint32[] memory secondsAgos = new uint32[](5);
        secondsAgos[0] = 0; // now
        secondsAgos[1] = 60; // 1 minute ago
        secondsAgos[2] = 300; // 5 minutes ago
        secondsAgos[3] = 600; // 10 minutes ago
        secondsAgos[4] = 1800; // 30 minutes ago

        (int56[] memory tickCumulatives, uint160[] memory liquidityCumulatives) = oracle.observe(secondsAgos);

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

        (int56[] memory tickCumulatives,) = oracle.observe(secondsAgos);

        // Calculate TWAP manually
        int24 twap = int24((tickCumulatives[0] - tickCumulatives[1]) / int56(600));

        // Should equal current tick since we use same tick for all observations
        (, int24 currentTick,,,,,) = oracle.slot0();
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

        (int56[] memory tickCumulatives,) = oracle.observe(secondsAgos);

        // Calculate TWAP manually
        uint32 timeDiff = secondsAgo2 - secondsAgo1;
        int24 twap = int24((tickCumulatives[0] - tickCumulatives[1]) / int56(uint56(timeDiff)));

        // Should equal current tick since we use same tick for all observations
        (, int24 currentTick,,,,,) = oracle.slot0();
        assertEq(twap, currentTick, "TWAP should equal current tick for any time period");
    }

    // TODO: Also fuzz test different length arrays (e.g. anywhere from 1 to max array length secondsAgos)

    function testObserveEmptyArray() public {
        uint32[] memory emptyArray = new uint32[](0);
        (int56[] memory tickCumulatives, uint160[] memory liquidityCumulatives) = oracle.observe(emptyArray);

        assertEq(tickCumulatives.length, 0, "Should return empty array");
        assertEq(liquidityCumulatives.length, 0, "Should return empty array");
    }

    function testObserveLargeArray() public {
        uint32[] memory largeArray = new uint32[](100);
        for (uint256 i = 0; i < largeArray.length; i++) {
            largeArray[i] = uint32(i * 60); // Every minute for 100 minutes
        }

        (int56[] memory tickCumulatives, uint160[] memory liquidityCumulatives) = oracle.observe(largeArray);

        assertEq(tickCumulatives.length, 100, "Should handle large arrays");
        assertEq(liquidityCumulatives.length, 100, "Should handle large arrays");
        // TODO: also test that the tickCumulative is still current Pyth price
    }

    function testIncreaseObservationCardinalityNext() public {
        // Should not revert
        oracle.increaseObservationCardinalityNext(16);
        oracle.increaseObservationCardinalityNext(1);
        oracle.increaseObservationCardinalityNext(type(uint16).max);

        // Values shouldn't change since it's a no-op
        (,,, uint16 obsCard, uint16 obsCardNext,,) = oracle.slot0();
        assertEq(obsCard, 65535, "observationCardinality unchanged");
        assertEq(obsCardNext, 65535, "observationCardinalityNext unchanged");
    }

    function testPriceConsistencyAcrossTime() public {
        // Record initial values
        (, int24 initialTick,,,,,) = oracle.slot0();

        // Fast forward time
        vm.warp(block.timestamp + 1000);

        // Values should be the same (since we use current Pyth price)
        (, int24 laterTick,,,,,) = oracle.slot0();
        assertEq(laterTick, initialTick, "Tick should be consistent across time (same Pyth round)");
    }

    function testPriceComparisonWithUniswapPool() public {
        // Get tick from our oracle
        (, int24 oracleTick,,,,,) = oracle.slot0();

        console.log(oracleTick);

        // Get tick from Uniswap V4 pool using StateView singleton
        (, int24 poolTick,,) = stateView.getSlot0(ethUsdtv4PoolId);

        console.log(poolTick);

        uint256 oraclePrice = convertRawUnitTickToWholeUnitPrice(oracleTick);
        uint256 poolPrice = convertRawUnitTickToWholeUnitPrice(poolTick);

        uint256 priceDiff = oraclePrice > poolPrice ? oraclePrice - poolPrice : poolPrice - oraclePrice;

        // Check if difference is within 1% (priceDiff / poolPrice < 0.01)
        // priceDiff / poolPrice < 0.01 <=> priceDiff * 100 < poolPrice
        assertLt(priceDiff * 100, poolPrice, "Oracle price should be within 1% of Uniswap pool price");
    }

    function convertRawUnitTickToWholeUnitPrice(int24 tick) internal view returns (uint256) {
        uint160 sqrtPX96 = TickMath.getSqrtRatioAtTick(tick);

        return FullMath.mulDiv(uint256(sqrtPX96) * uint256(sqrtPX96), uint256(10 ** uint8(-decimalDifferenceFromToken0ToToken1)), 1 << 192);
    }

    function testRevertOnStalePriceAndAcceptsAllOthers(uint256 secondsInFuture) public {
        vm.assume(secondsInFuture <= block.timestamp); // don't go more than (now - unix_origin) in the future - very large timestamps overflow the tickCumulative calculation
        // Fast forward time, possibly beyond maxPythPriceAge
        vm.warp(block.timestamp + secondsInFuture);

        PythStructs.Price memory price = pyth.getPriceUnsafe(ethUsdPriceFeedId);
        uint256 currentPriceAge = block.timestamp - price.publishTime;

        // This should revert because price is too stale
        if (currentPriceAge > maxPythPriceAge) {
            vm.expectRevert();
            oracle.slot0();
        } else {
            // Should work normally - price is fresh enough
            (uint160 sqrtPriceX96,,,,,,) = oracle.slot0();
            assertGt(uint256(sqrtPriceX96), 0, "Should return valid sqrtPrice");
        }
    }

    // Additional test to verify the ordering assumption
    function testObservationsTimestampOrdering() public {
        uint32 prevTimestamp;

        // Test that timestamps increase with index
        for (uint256 i = 0; i < 10; i++) {
            (uint32 timestamp,,,) = oracle.observations(i);

            if (i > 0) {
                assertGt(timestamp, prevTimestamp, "Timestamps should increase with index");
            }

            // Verify the exact formula
            uint32 expectedTimestamp = uint32(block.timestamp - 65534 + i);
            assertEq(timestamp, expectedTimestamp, "Timestamp should match formula");

            prevTimestamp = timestamp;
        }
    }

    // TODO: In the future, we could also test that we revert for negative Pyth price,
    // by mocking the Pyth contract. Don't feel that's necessary currently, though.
}
