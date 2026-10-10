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
    function getReserves()
        external
        view
        returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function price0CumulativeLast() external view returns (uint256);
    function price1CumulativeLast() external view returns (uint256);
}

/// @notice Stateless price reads and score arithmetic for Marginalia. Every price is "IMD per 1e18 of X", 1e18 scaled, 18-decimal
/// assets assumed on both sides (a documented v1 limitation). No state or owner: pool reads and caller-supplied
/// history are the inputs; the router authenticates and stores the posting history.
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
    error PriceHistoryUnavailable();

    uint256 public constant POST_MIN_SPAN = 1 hours;
    uint256 public constant POST_MAX_AGE = 6 hours;

    // ------------------------------------------------------------------ score arithmetic

    /// @dev IMD-denominated market-cap tiers for the difficulty score (~$1M / ~$10M at IMD ≈ $9).
    uint256 public constant TIER2_MCAP_IMD = 111_000 ether;
    uint256 public constant TIER3_MCAP_IMD = 1_110_000 ether;

    /// @notice log2(claimed multiple) × sqrt(30 / horizon) × mcap tier, scaled 1e4.
    /// @param targetBps the claimed price as a multiple of the post price in basis points
    /// @param buy true for a BUY call (target > 1), false for a SELL call (target < 1)
    /// @param horizonDays 1..90
    /// @param mcapImd the token's market cap at post time, in IMD (1e18)
    function difficulty(uint32 targetBps, bool buy, uint16 horizonDays, uint256 mcapImd)
        external
        pure
        returns (uint256)
    {
        uint256 ratio = buy ? targetBps : FullMath.mulDiv(10_000, 10_000, targetBps);
        uint256 l2 = log2x1e4(ratio);
        uint256 s = sqrt(FullMath.mulDiv(30, 1e8, horizonDays)); // sqrt(30/h) × 1e4
        uint256 tier = mcapImd >= TIER3_MCAP_IMD ? 3 : (mcapImd >= TIER2_MCAP_IMD ? 2 : 1);
        return FullMath.mulDiv(l2, s, 1e4) * tier;
    }

    /// @dev log2 of a ratio given ×1e4 (ratio ≥ 1e4), returned ×1e4 with 1/16 precision.
    function log2x1e4(uint256 r) public pure returns (uint256 result) {
        uint256 n;
        while (r >= 20_000) {
            r /= 2;
            n += 1;
        }
        result = n * 1e4;
        uint256 frac = 5000;
        for (uint256 i = 0; i < 4; ++i) {
            r = r * r / 1e4;
            if (r >= 20_000) {
                result += frac;
                r /= 2;
            }
            frac /= 2;
        }
    }

    function sqrt(uint256 x) public pure returns (uint256 y) {
        if (x == 0) return 0;
        if (x < 4) return 1; // the seed below equals x at x == 2, so the loop would not run (finding 4e3977e5)
        uint256 z = x / 2 + 1; // (x + 1) / 2 overflows at type(uint256).max
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    // ------------------------------------------------------------------ post time

    /// @notice Extend a router-held window without replacing its start or its conservative extremes.
    /// An expired window starts again and must mature for an hour before it can price a post.
    function checkpoint(IPoolManager manager, T.Venue memory v, address imd, T.PriceWindow memory w)
        external
        view
        returns (T.PriceWindow memory)
    {
        (uint256 x, uint256 q) = observe(manager, v, imd);
        if (w.startedAt == 0 || block.timestamp > uint256(w.startedAt) + POST_MAX_AGE) {
            return T.PriceWindow(uint64(block.timestamp), uint64(block.number), x, x, x, q, q);
        }
        if (v.kind == T.VenueKind.UniV4) {
            w.xMin = _adverse(w.xMin, x, true);
            w.xMax = _adverse(w.xMax, x, false);
        }
        w.quoteMin = _adverse(w.quoteMin, q, true);
        w.quoteMax = _adverse(w.quoteMax, q, false);
        return w;
    }

    /// @notice A baseline adverse to the call: TWAP since the checkpoint on v3/v2; the maximum
    /// for BUY / minimum for SELL on v4 and the hub leg, including the current reading.
    /// This reverses settlement's extreme because the baseline is the target's denominator.
    function postPrice(IPoolManager manager, T.Venue memory v, address imd, bool buy, T.PriceWindow memory w)
        external
        view
        returns (uint256)
    {
        if (
            w.startedAt == 0 || block.number <= w.blockNumber
                || block.timestamp < uint256(w.startedAt) + POST_MIN_SPAN
                || block.timestamp > uint256(w.startedAt) + POST_MAX_AGE
        ) revert PriceHistoryUnavailable();
        (uint256 x, uint256 q) = observe(manager, v, imd);
        if (v.kind == T.VenueKind.UniV4) {
            x = _adverse(buy ? w.xMax : w.xMin, x, !buy);
        } else {
            x = twap(v.kind, v.xIsToken0, w.xStart, w.startedAt, x, uint64(block.timestamp));
        }
        q = _adverse(buy ? w.quoteMax : w.quoteMin, q, !buy);
        uint256 p = FullMath.mulDiv(x, q, 1e18);
        if (p == 0) revert EmptyPool();
        return p;
    }

    // ------------------------------------------------------------------ observations

    /// @notice What one observation records: the venue's accumulator (v3 tick cumulative as int256 bits, v2
    /// price cumulative) or its spot (v4), and the quote leg's spot in IMD.
    function observe(IPoolManager manager, T.Venue memory v, address imd)
        public
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
    function settlePrice(T.Venue memory v, bool buy, T.Observation[] memory obs)
        external
        pure
        returns (uint256)
    {
        uint256 n = obs.length;
        if (n == 0) revert Unsupported();
        uint256 x;
        if (v.kind == T.VenueKind.UniV4) {
            x = obs[0].xRead;
            for (uint256 i = 1; i < n; ++i) {
                x = _adverse(x, obs[i].xRead, buy);
            }
        } else {
            x = twap(
                v.kind, v.xIsToken0, obs[0].xRead, obs[0].timestamp, obs[n - 1].xRead, obs[n - 1].timestamp
            );
        }
        uint256 q = obs[0].quoteRead;
        for (uint256 i = 1; i < n; ++i) {
            q = _adverse(q, obs[i].quoteRead, buy);
        }
        uint256 p = FullMath.mulDiv(x, q, 1e18);
        if (p == 0) revert EmptyPool();
        return p;
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
            uint256 p = FullMath.mulDiv(avg, 1e18, Q112); // UQ112x112 -> 1e18
            if (p == 0) revert EmptyPool();
            return p;
        }
        revert Unsupported();
    }

    // ------------------------------------------------------------------ reads

    function _spotInQuote(IPoolManager manager, T.Venue memory v) private view returns (uint256) {
        address ref = address(uint160(uint256(v.ref)));
        if (v.kind == T.VenueKind.UniV4) {
            if (manager.getLiquidity(PoolId.wrap(v.ref)) == 0) revert EmptyPool();
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
            uint256 p = v.xIsToken0 ? FullMath.mulDiv(r1, 1e18, r0) : FullMath.mulDiv(r0, 1e18, r1);
            if (p == 0) revert EmptyPool();
            return p;
        }
        revert Unsupported();
    }

    /// @dev IMD per 1e18 of the quote asset: 1 for IMD itself, the hub spot for ETH / WETH, nothing else.
    function _quoteSpot(IPoolManager manager, address quote, address imd) private view returns (uint256) {
        if (quote == imd) return 1e18;
        if (quote == address(0) || quote == WETH) {
            if (block.chainid != 1) revert QuoteNotPriceable();
            if (manager.getLiquidity(PoolId.wrap(HUB_POOL_ID)) == 0) revert EmptyPool();
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

    /// @dev price of token0 in token1 = sqrtP^2 / 2^192; inverted when X is token1. A price that rounds to
    /// zero in either orientation (below 1e-18 of the quote) is refused: a zero baseline would make every
    /// BUY call on the venue vacuously right, and a zero settlement every SELL call.
    function fromSqrt(uint160 sqrtP, bool xIsToken0) public pure returns (uint256) {
        if (sqrtP == 0) revert EmptyPool();
        uint256 p = FullMath.mulDiv(uint256(sqrtP), uint256(sqrtP), Q96);
        p = FullMath.mulDiv(p, 1e18, Q96);
        if (p == 0) revert EmptyPool();
        if (xIsToken0) return p;
        p = FullMath.mulDiv(1e18, 1e18, p);
        if (p == 0) revert EmptyPool();
        return p;
    }
}
