// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import {TickMath} from "v3-core/libraries/TickMath.sol";
import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";

/// @title PythToV3Oracle
/// @notice Contract that provides a Uniswap V3-compatible oracle interface on Pyth-sourced price data.
contract PythToV3Oracle {
    /// @notice The Pyth contract this adapter interacts with.
    IPyth public immutable pyth;

    /// @notice The Pyth price feed ID for the trading pair
    bytes32 public immutable priceFeedId;

    /// @notice The max age we permit for a Pyth price before price reads revert
    uint256 public immutable maxPythPriceAge;

    /// @notice In the target market this oracle is supposed to imitate, token1.decimals - token0.decimals
    int8 public immutable decimalDifferenceFromToken0ToToken1;

    /// @notice Whether to invert the token0/token1 ordering (negate the tick)
    bool public immutable invertTokenOrder;

    /// @notice Initializes the adapter with the Pyth contract and price feed ID.
    /// @param _pyth The Pyth contract to read price data from
    /// @param _priceFeedId The Pyth price feed ID for the desired trading pair
    /// @param _maxPythPriceAge The max age we permit for a Pyth price before price reads revert
    /// @param _decimalDifferenceFromToken0ToToken1 In the target market, token1.decimals - token0.decimals
    /// @param _invertTokenOrder Whether to invert the token0/token1 ordering
    constructor(
        IPyth _pyth,
        bytes32 _priceFeedId,
        uint256 _maxPythPriceAge,
        int8 _decimalDifferenceFromToken0ToToken1,
        bool _invertTokenOrder
    ) {
        pyth = _pyth;
        priceFeedId = _priceFeedId;
        maxPythPriceAge = _maxPythPriceAge;
        decimalDifferenceFromToken0ToToken1 = _decimalDifferenceFromToken0ToToken1;
        invertTokenOrder = _invertTokenOrder;
    }

    /// @notice Emulates the behavior of the exposed zeroth slot of a Uniswap V3 pool.
    /// @return sqrtPriceX96 A tick-snapped sqrt price of the oracle, as a sqrt(currency1/currency0) Q64.96 value
    /// @return tick The current tick of the oracle
    /// @return observationIndex The index of the last oracle observation that was written
    /// @return observationCardinality The current maximum number of observations stored in the oracle
    /// @return observationCardinalityNext The next maximum number of observations that can be stored in the oracle
    /// @return feeProtocol The protocol fee for this pool (not used in V4, always 0)
    /// @return unlocked Whether the pool is currently unlocked (always true for V4)
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        )
    {
        unchecked {
            tick = getPythPriceAsTick();
            // NOTE: that this is tick-snapped and less precise - the opposite of typical
            // slot0 responses, where `tick` loses some of `sqrtPrice`'s precision
            sqrtPriceX96 = TickMath.getSqrtRatioAtTick(tick);

            // Always return the max index
            observationIndex = 65534;
            // Always return the length of the observations array, so that callers always roll over
            observationCardinality = 65535;
            // This value shouldn't be used by callers given the above, but: return 65535, which matches
            // what Uniswap pools return when all the observations are filled
            observationCardinalityNext = 65535;

            // not used in v4, so always 0
            feeProtocol = 0;
            // always true in v4
            unlocked = true;
        }
    }

    /// @notice Returns data about a specific observation index.
    /// @param index The element of the observations array to fetch
    /// @return blockTimestamp The timestamp of the observation
    /// @return tickCumulative The tick multiplied by seconds elapsed for the life of the pool as of the observation timestamp.
    /// @return secondsPerLiquidityCumulativeX128 The seconds per in range liquidity for the life of the pool (always 0 in V4)
    /// @return initialized Whether the observation has been initialized and the values are safe to use
    function observations(uint256 index)
        external
        view
        returns (
            uint32 blockTimestamp,
            int56 tickCumulative,
            uint160 secondsPerLiquidityCumulativeX128,
            bool initialized
        )
    {
        unchecked {
            // Use a blockTimestamp close to now, but unique per-observation
            // Index 0 was 65534 seconds ago, and the max index was now
            blockTimestamp = uint32(block.timestamp - 65534 + index);
            tickCumulative = int56(getPythPriceAsTick()) * int56(int32(blockTimestamp));

            // Always 0 in v4
            secondsPerLiquidityCumulativeX128 = 0;
            // These values are always safe to use - they're just stubbed based on the chainlink price
            initialized = true;
        }
    }

    /// @notice Returns the cumulative tick and liquidity as of each timestamp `secondsAgo` from the current block timestamp.
    /// @param secondsAgos From how long ago each cumulative tick and liquidity value should be returned
    /// @return tickCumulatives Cumulative tick values as of each `secondsAgos` from the current block timestamp
    /// @return secondsPerLiquidityCumulativeX128s Cumulative seconds per liquidity-in-range value (always empty in V4)
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        unchecked {
            tickCumulatives = new int56[](secondsAgos.length);

            int24 currentTick = getPythPriceAsTick();

            for (uint256 i = 0; i < secondsAgos.length; i++) {
                // Use the same current tick for all observations
                // The cumulative = tick * timestamp at that point in time
                // This ensures TWAP calculations will always result in the current tick
                tickCumulatives[i] = int56(currentTick) * int56(int256(block.timestamp - secondsAgos[i]));
            }

            return (tickCumulatives, new uint160[](secondsAgos.length));
        }
    }

    /// @notice Get the current price from Pyth with adjustable variation.
    /// @return The current price from Pyth, converted to a tick
    function getPythPriceAsTick() internal view returns (int24) {
        // getPriceNoOlderThan will revert if the price is >maxPythPriceAge seconds old
        PythStructs.Price memory price = pyth.getPriceNoOlderThan(priceFeedId, maxPythPriceAge);

        // Revert if price is negative - we don't handle negative prices
        if (price.price <= 0) {
            revert("Invalid price: negative or zero price from Pyth");
        }

        return pythPriceToTick(price.price, price.expo);
    }

    /// @notice Convert Pyth price directly to tick
    /// @param price Raw Pyth price (8 decimals, cannot be negative - we required against it in getPythPriceAsTick)
    /// @param decimals Decimal adjustment to get whole-unit price
    /// @return tick The corresponding Uniswap V3 tick
    function pythPriceToTick(int64 price, int32 decimals) internal view returns (int24) {
        unchecked {
            // Pyth prices are returned in two components, raw units and decimals, so we need to scale to get the actual price
            // Convert to Q128.128 format: (price * 2^128) / 10^decimals
            uint256 priceX128 = decimals < 0
                ? (uint256(uint64(price)) << 128) / uint256(10 ** uint32(-decimals))
                : (uint256(uint64(price)) << 128) * uint256(10 ** uint32(decimals));

            // Adjust for token decimals difference
            // V3 prices are token1/token0 in raw units (wei), not whole tokens
            // So we need to scale by 10^(token1Decimals - token0Decimals)
            if (decimalDifferenceFromToken0ToToken1 > 0) {
                // token1 has more decimals, multiply price
                priceX128 = priceX128 * (10 ** uint256(uint8(decimalDifferenceFromToken0ToToken1)));
            } else if (decimalDifferenceFromToken0ToToken1 < 0) {
                // token0 has more decimals, divide price
                priceX128 = priceX128 / (10 ** uint256(uint8(-decimalDifferenceFromToken0ToToken1)));
            }
            // If decimalDifferenceFromToken0ToToken1 == 0, no adjustment needed

            // Precision of 13 keeps the err <= 0.846169235035 tick - e.g., we're within 1 tick
            int256 tick = log_1p0001(priceX128, 13);

            // Invert the tick if needed (equivalent to taking reciprocal of price)
            if (invertTokenOrder) {
                tick = -tick;
            }

            return int24(tick);
        }
    }

    /// @notice Approximates the absolute value of log base `1.0001` for a number in (0, 2**128) (`argX128/2^128`) with `precision` bits of precision.
    /// @param argX128 The Q128.128 fixed-point number in the range (0, 2**128) to calculate the log of
    /// @param precision The bits of precision with which to compute the result, max 63 (`err <≈ 2^-precision * log₂(1.0001)⁻¹`)
    /// @return The absolute value of log with base `1.0001` for `argX128/2^128`
    function log_1p0001(uint256 argX128, uint256 precision) internal pure returns (int256) {
        unchecked {
            // =[log₂(x)] =MSB(x)
            int256 log2_res = int256(FixedPointMathLib.log2(argX128));
            // Normalize argX128 to [1, 2)
            // x_normal = x / 2^[log₂(x)]
            // = 1.a₁a₂a₃... = 2^(0.b₁b₂b₃...)
            // log₂(x_normal) = log₂(x / 2^⌊log₂(x)⌋)
            // log₂(x_normal) = log₂(x) - log₂(2^⌊log₂(x)⌋)
            // log₂(x_normal) = log₂(x) - ⌊log₂(x)⌋
            // log₂(x) = log₂(x_normal) + ⌊log₂(x)⌋
            if (log2_res >= 128) argX128 = argX128 >> (uint256(log2_res) - 127);
            else argX128 <<= (127 - uint256(log2_res));

            // =[log₂(x)] * 2^64
            log2_res = (log2_res - 128) << 64;

            // log₂(x_normal) = 0.b₁b₂b₃...
            // x_normal = (1.a₁a₂a₃...) = 2^(0.b₁b₂b₃...)
            // x_normal² = (1.a₁a₂a₃...)² = (2^(0.b₁b₂b₃...))²
            // = 2^(0.b₁b₂b₃... * 2)
            // = 2^(b₁ + 0.b₂b₃...)
            // if bᵢ = 1, renormalize x_normal² to [1, 2):
            // 2^(b₁ + 0.b₂b₃...) / 2^b₁ = 2^((b₁ - 1).b₂b₃...)
            // = 2^(0.b₂b₃...)
            // error = [0, 2⁻ⁿ)
            uint256 iterBound = 63 - precision;
            for (uint256 i = 63; i > iterBound; i--) {
                argX128 = (argX128 ** 2) >> 127;
                uint256 bit = argX128 >> 128;
                log2_res = log2_res | int256(bit << i);
                argX128 >>= bit;
            }

            // log₁.₀₀₀₁(x) = log₂(x) / log₂(1.0001)
            // 2^64 / log₂(1.0001) ≈ 127869479499815993737216
            return (log2_res * 127869479499815993737216) / 2 ** 128;
        }
    }

    /// @notice This method is typically used to increase the maximum number of price observations, but we just no-op.
    /// @dev PanopticFactory relies on this method, so we wanted to expose it, even if it does nothing.
    /// @param observationCardinalityNext The desired minimum number of observations for the oracle to store
    function increaseObservationCardinalityNext(uint16 observationCardinalityNext) external {}
}
