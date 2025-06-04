// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {FullMath} from "v3-core/libraries/FullMath.sol";

import "../src/PythToV3Oracle.sol";

contract PythToV3OracleTest is Test {
    PythToV3Oracle oracle;
    IPyth pyth = IPyth(
        // From: https://docs.pyth.network/price-feeds/contract-addresses/evm
        0x2880aB155794e7179c9eE2e38200202908C17B43 // Pyth on unichain
    );
    // From: https://www.pyth.network/developers/price-feed-ids
    bytes32 ethUsdPriceFeedId = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;
    // https://uniscan.xyz/address/0x65081CB48d74A32e9CCfED75164b8c09972DBcF1
    IUniswapV3Pool ethUsdcPool = IUniswapV3Pool(0x65081CB48d74A32e9CCfED75164b8c09972DBcF1);

    function setUp() public {
        uint256 forkId = vm.createFork(vm.rpcUrl("unichain"));
        vm.selectFork(forkId);
        // Revert if the price is >7200s <=> 2hrs old, as the ETH<>USDC feed should update every hour
        oracle = new PythToV3Oracle(pyth, ethUsdPriceFeedId, 7200);
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
        assertGt(uint256(sqrtPriceX96), 0, "sqrtPriceX96 should be > 0");
        assertGt(int256(tick), 0, "tick should be > 0, unless ETH crashed below $1");
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

            // tickCumulative should be reasonable
            assertGt(int256(tickCumulative), 0, "tickCumulative should be positive for ETH/USD");
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

        // Tick cumulatives should be decreasing (older timestamps = smaller cumulatives)
        for (uint256 i = 0; i < tickCumulatives.length - 1; i++) {
            assertGt(tickCumulatives[i], tickCumulatives[i + 1], "Newer observations should have larger cumulatives");
        }
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
        // Get price from our oracle
        (, int24 oracleTick,,,,,) = oracle.slot0();
        uint160 oracleSqrtPriceX96 = TickMath.getSqrtRatioAtTick(oracleTick);

        // Get price from actual Uniswap V3 ETH/USDC pool
        (uint160 poolSqrtPriceX96,,,,,,) = ethUsdcPool.slot0();

        // Convert to human-readable prices for comparison
        // For ETH/USD: price = (sqrtPriceX96)^2 / 2^192
        // 1) Oracle price = USD per ETH:
        uint256 oraclePrice = FullMath.mulDiv(uint256(oracleSqrtPriceX96), uint256(oracleSqrtPriceX96), 1 << 192);
        // 2) Pool raw ratio = (token1/token0)*(10^dec0/10^dec1):
        //    token0 = USDC (6 decimals), token1 = WETH (18 decimals)
        //    so raw = (WETH/USDC)*1e12
        uint256 poolRaw = FullMath.mulDiv(uint256(poolSqrtPriceX96), uint256(poolSqrtPriceX96), 1 << 192);
        // 3) Match the decimals to Pyth's and flip token order to USD per ETH:
        //    USD/ETH = (1 / (WETH/USDC)) = 1e12 / poolRaw
        uint256 poolPrice = FullMath.mulDiv(
            1e12, // numerator
            1, // second factor
            poolRaw // denominator
        );

        uint256 diff = oraclePrice > poolPrice ? oraclePrice - poolPrice : poolPrice - oraclePrice;
        uint256 percentDiff = (diff * 10000) / poolPrice; // basis points

        // Prices should be within 1% (100 basis points) of each other
        assertLe(percentDiff, 100, "Oracle price should be within 1% of Uniswap pool price");
    }

    function testRevertOnStalePriceAndAcceptsAllOthers(uint256 secondsInFuture) public {
        vm.assume(secondsInFuture <= block.timestamp); // don't go more than (now - unix_origin) in the future - very large timestamps overflow the tickCumulative calculation
        // Fast forward time beyond maxPythPriceAge (7200 seconds)
        vm.warp(block.timestamp + secondsInFuture);

        PythStructs.Price memory price = pyth.getPriceUnsafe(ethUsdPriceFeedId);
        uint256 currentPriceAge = block.timestamp - price.publishTime;

        // This should revert because price is too stale
        if (currentPriceAge > 7200) {
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
