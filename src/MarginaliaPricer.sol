// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {MarginaliaTypes as T} from "./MarginaliaTypes.sol";

interface IUniswapV3PoolOracle {
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool);
}

interface IUniswapV2PairOracle {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function price0CumulativeLast() external view returns (uint256);
    function price1CumulativeLast() external view returns (uint256);
}

/// @notice Stateless price reads for Marginalia. Every price is "IMD per 1e18 of X", 1e18 scaled, 18-decimal
/// assets assumed on both sides (a documented v1 limitation). No state, no owner: the pool is the only input.
///
/// Settlement never trusts a single block. Venues with an on-chain accumulator (Uniswap v3 tick cumulatives,
/// Uniswap v2 price cumulatives) settle on the time-weighted average between the first and last observation,
/// which a manipulator can only move by holding the pumped price for the whole span against every arbitrageur.
/// Venues with no accumulator (Uniswap v4 pools, and the ETH->IMD hub leg) settle on the observation least
/// favourable to the call: the lowest price for a BUY call, the highest for a SELL call. Because anyone may
/// observe, one honest observation at an unmanipulated block pins that extreme, so a pump must again be held
/// for the whole span. A two-block pump-observe-unwind moves neither rule.
contract MarginaliaPricer {
    using StateLibrary for IPoolManager;

    uint256 internal constant Q96 = 2 ** 96;
    uint256 internal constant Q112 = 2 ** 112;

    /// @dev The hookless ETH/IMD v4 pool on Ethereum mainnet: the only ETH->IMD leg.
    bytes32 public constant HUB_POOL_ID = 0xb07d640fd9e2eb9dc81b953c8e4fd006bdfeaf276010fb5418eb763ca15abfb3;
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    error EmptyPool();
    error Unsupported();
    error QuoteNotPriceable();

    // ------------------------------------------------------------------ post time

    /// @notice Spot price of X in IMD at post time (context for the call; settlement never reuses it alone).
    function postPrice(IPoolManager manager, T.Venue memory v, address imd) external view returns (uint256) {
        return FullMath.mulDiv(_spotInQuote(manager, v), _quoteSpot(manager, v.quote, imd), 1e18);
    }

    // ------------------------------------------------------------------ observations

    /// @notice What one observation records: the venue's accumulator (v3 tick cumulative as int256 bits, v2
    /// price cumulative) or its spot (v4), and the quote leg's spot in IMD.
    function observe(IPoolManager manager, T.Venue memory v, address imd)
        external
        view
        returns (uint256 xRead, uint256 quoteRead)
    {
        address ref = address(uint160(uint256(v.ref)));
        if (v.kind == T.VenueKind.UniV4) xRead = _spotInQuote(manager, v);
        else if (v.kind == T.VenueKind.UniV3) xRead = uint256(_v3Cumulative(ref));
        else if (v.kind == T.VenueKind.UniV2) xRead = _v2Cumulative(ref, v.xIsToken0);
        else revert Unsupported();
        quoteRead = _quoteSpot(manager, v.quote, imd);
    }

    /// @notice The settlement price from a call's observations (at least one, in posting order).
    /// @param buy true for a BUY call: the adverse extreme is then the minimum, else the maximum
    function settlePrice(T.Venue memory v, bool buy, T.Observation[] memory obs) external pure returns (uint256) {
        uint256 n = obs.length;
        if (n == 0) revert Unsupported();
        uint256 x;
        if (v.kind == T.VenueKind.UniV4) {
            x = obs[0].xRead;
            for (uint256 i = 1; i < n; ++i) x = _adverse(x, obs[i].xRead, buy);
        } else {
            x = twap(v.kind, v.xIsToken0, obs[0].xRead, obs[0].timestamp, obs[n - 1].xRead, obs[n - 1].timestamp);
        }
        uint256 q = obs[0].quoteRead;
        for (uint256 i = 1; i < n; ++i) q = _adverse(q, obs[i].quoteRead, buy);
        return FullMath.mulDiv(x, q, 1e18);
    }

    /// @notice Time-weighted average price of X between two readings of the same accumulator.
    /// @param c1 reading at t1, `c2` reading at t2 (t2 > t1); v3 readings are int256 cumulatives cast to uint256
    function twap(T.VenueKind kind, bool xIsToken0, uint256 c1, uint64 t1, uint256 c2, uint64 t2)
        public
        pure
        returns (uint256)
    {
        if (t2 <= t1) revert Unsupported();
        uint256 dt = uint256(t2 - t1);
        if (kind == T.VenueKind.UniV3) {
            int256 delta = int256(c2) - int256(c1);
            int256 mean = delta / int256(dt);
            if (delta < 0 && delta % int256(dt) != 0) mean -= 1; // round toward negative infinity, as v3 does
            if (mean < TickMath.MIN_TICK || mean > TickMath.MAX_TICK) revert Unsupported();
            return fromSqrt(TickMath.getSqrtPriceAtTick(int24(mean)), xIsToken0);
        }
        if (kind == T.VenueKind.UniV2) {
            uint256 avg;
            unchecked {
                avg = (c2 - c1) / dt; // the v2 accumulator wraps by design; the difference does not
            }
            return FullMath.mulDiv(avg, 1e18, Q112); // UQ112x112 -> 1e18
        }
        revert Unsupported();
    }

    // ------------------------------------------------------------------ reads

    function _spotInQuote(IPoolManager manager, T.Venue memory v) private view returns (uint256) {
        address ref = address(uint160(uint256(v.ref)));
        if (v.kind == T.VenueKind.UniV4) {
            (uint160 sqrtP,,,) = manager.getSlot0(PoolId.wrap(v.ref));
            return fromSqrt(sqrtP, v.xIsToken0);
        }
        if (v.kind == T.VenueKind.UniV3) {
            (uint160 sqrtP,,,,,,) = IUniswapV3PoolOracle(ref).slot0();
            return fromSqrt(sqrtP, v.xIsToken0);
        }
        if (v.kind == T.VenueKind.UniV2) {
            (uint112 r0, uint112 r1,) = IUniswapV2PairOracle(ref).getReserves();
            if (r0 == 0 || r1 == 0) revert EmptyPool();
            return v.xIsToken0 ? FullMath.mulDiv(r1, 1e18, r0) : FullMath.mulDiv(r0, 1e18, r1);
        }
        revert Unsupported();
    }

    /// @dev IMD per 1e18 of the quote asset: 1 for IMD itself, the hub spot for ETH / WETH, nothing else.
    function _quoteSpot(IPoolManager manager, address quote, address imd) private view returns (uint256) {
        if (quote == imd) return 1e18;
        if (quote == address(0) || quote == WETH) {
            if (block.chainid != 1) revert QuoteNotPriceable();
            (uint160 sqrtP,,,) = manager.getSlot0(PoolId.wrap(HUB_POOL_ID));
            return fromSqrt(sqrtP, true); // native ETH is token0 of the hub
        }
        revert QuoteNotPriceable();
    }

    /// @dev A v3 pool's tick cumulative now; `observe([0])` works at any observation cardinality.
    function _v3Cumulative(address pool) private view returns (int256) {
        uint32[] memory ago = new uint32[](1);
        (int56[] memory cum,) = IUniswapV3PoolOracle(pool).observe(ago);
        return int256(cum[0]);
    }

    /// @dev A v2 pair's price cumulative for X, extrapolated to now (UniswapV2OracleLibrary semantics).
    function _v2Cumulative(address pair, bool xIsToken0) private view returns (uint256 cumulative) {
        IUniswapV2PairOracle p = IUniswapV2PairOracle(pair);
        (uint112 r0, uint112 r1, uint32 tsLast) = p.getReserves();
        if (r0 == 0 || r1 == 0) revert EmptyPool();
        cumulative = xIsToken0 ? p.price0CumulativeLast() : p.price1CumulativeLast();
        uint32 nowTs = uint32(block.timestamp);
        if (nowTs != tsLast) {
            uint256 ratio = xIsToken0 ? FullMath.mulDiv(r1, Q112, r0) : FullMath.mulDiv(r0, Q112, r1);
            unchecked {
                cumulative += ratio * uint256(nowTs - tsLast);
            }
        }
    }

    function _adverse(uint256 a, uint256 b, bool buy) private pure returns (uint256) {
        return buy ? (b < a ? b : a) : (b > a ? b : a);
    }

    /// @dev price of token0 in token1 = sqrtP^2 / 2^192; inverted when X is token1.
    function fromSqrt(uint160 sqrtP, bool xIsToken0) public pure returns (uint256) {
        if (sqrtP == 0) revert EmptyPool();
        uint256 p = FullMath.mulDiv(uint256(sqrtP), uint256(sqrtP), Q96);
        p = FullMath.mulDiv(p, 1e18, Q96);
        if (xIsToken0) return p;
        if (p == 0) revert EmptyPool();
        return FullMath.mulDiv(1e18, 1e18, p);
    }
}
