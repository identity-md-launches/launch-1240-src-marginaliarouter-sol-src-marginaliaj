// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {MarginaliaPricer} from "../src/MarginaliaPricer.sol";
import {MarginaliaTypes as T} from "../src/MarginaliaTypes.sol";

/// @dev Storage layout read by StateLibrary: the mock controls only pool state, never pricer results.
contract SlotManagerMock {
    mapping(bytes32 => bytes32) private state;

    function setPool(bytes32 id, uint160 sqrtPrice, uint128 liquidity) external {
        bytes32 slot = keccak256(abi.encode(id, uint256(6)));
        state[slot] = bytes32(uint256(sqrtPrice));
        state[bytes32(uint256(slot) + 3)] = bytes32(uint256(liquidity));
    }

    function extsload(bytes32 slot) external view returns (bytes32) {
        return state[slot];
    }
}

/// @dev Properties of the stateless pricer at the edges of its inputs: the score arithmetic, the
/// settlement rule over random observation series, and the posting window's exact boundaries.
contract PricerPropertiesTest is Test {
    MarginaliaPricer private pricer;
    SlotManagerMock private state;
    IPoolManager private manager;
    address private imd = makeAddr("IMD");
    bytes32 private constant POOL = keccak256("pricer properties pool");

    function setUp() public {
        vm.chainId(1);
        vm.warp(1_800_000_000);
        vm.roll(1000);
        pricer = new MarginaliaPricer();
        state = new SlotManagerMock();
        manager = IPoolManager(address(state));
        state.setPool(POOL, uint160(1 << 96), 1 ether);
        state.setPool(pricer.HUB_POOL_ID(), uint160(1 << 96), 1 ether);
    }

    // ------------------------------------------------------------------ difficulty

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzBuyDifficultyGrowsWithTheTarget(uint32 a, uint32 b, uint16 h, uint256 mcap) public view {
        a = uint32(bound(a, 11_000, 10_000_000));
        b = uint32(bound(b, 11_000, 10_000_000));
        h = uint16(bound(h, 1, 90));
        mcap = bound(mcap, 0, 1e30);
        if (a > b) (a, b) = (b, a);
        assertLe(pricer.difficulty(a, true, h, mcap), pricer.difficulty(b, true, h, mcap));
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzSellDifficultyGrowsAsTheTargetFalls(uint32 a, uint32 b, uint16 h, uint256 mcap)
        public
        view
    {
        a = uint32(bound(a, 1, 9_000));
        b = uint32(bound(b, 1, 9_000));
        h = uint16(bound(h, 1, 90));
        mcap = bound(mcap, 0, 1e30);
        if (a > b) (a, b) = (b, a);
        assertGe(pricer.difficulty(a, false, h, mcap), pricer.difficulty(b, false, h, mcap));
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzDifficultyFallsWithTheHorizon(uint32 t, uint16 h1, uint16 h2, uint256 mcap) public view {
        t = uint32(bound(t, 11_000, 1_000_000));
        h1 = uint16(bound(h1, 1, 90));
        h2 = uint16(bound(h2, 1, 90));
        mcap = bound(mcap, 0, 1e30);
        if (h1 > h2) (h1, h2) = (h2, h1);
        assertGe(pricer.difficulty(t, true, h1, mcap), pricer.difficulty(t, true, h2, mcap));
    }

    function testDifficultyTiersStepExactlyAtTheThresholds() public view {
        uint256 base = pricer.difficulty(20_000, true, 30, 0);
        assertGt(base, 0);
        assertEq(pricer.difficulty(20_000, true, 30, pricer.TIER2_MCAP_IMD() - 1), base);
        assertEq(pricer.difficulty(20_000, true, 30, pricer.TIER2_MCAP_IMD()), base * 2);
        assertEq(pricer.difficulty(20_000, true, 30, pricer.TIER3_MCAP_IMD() - 1), base * 2);
        assertEq(pricer.difficulty(20_000, true, 30, pricer.TIER3_MCAP_IMD()), base * 3);
        assertEq(pricer.difficulty(20_000, true, 30, type(uint256).max), base * 3);
    }

    function testDifficultyAnchors() public view {
        // 2x over 30 days, tier 1: log2(2) = 1 -> 1e4 × sqrt(30/30) = 1e4 -> 1e4
        assertEq(pricer.difficulty(20_000, true, 30, 0), 10_000);
        // -50% over 30 days is as hard as 2x
        assertEq(pricer.difficulty(5_000, false, 30, 0), 10_000);
        // 4x over 30 days doubles it
        assertEq(pricer.difficulty(40_000, true, 30, 0), 20_000);
        // the same 2x over 1 day is worth sqrt(30) times as much
        assertApproxEqRel(pricer.difficulty(20_000, true, 1, 0), 54_772, 0.001e18);
        // a target below the post price on a BUY call is worth nothing
        assertEq(pricer.difficulty(9_999, true, 30, 0), 0);
    }

    function testDifficultyRefusesAZeroHorizon() public {
        vm.expectRevert();
        pricer.difficulty(20_000, true, 0, 0);
    }

    function testSellDifficultyRefusesAZeroTarget() public {
        vm.expectRevert();
        pricer.difficulty(0, false, 30, 0);
    }

    // ------------------------------------------------------------------ log2 / sqrt

    /// forge-config: default.fuzz.runs = 512
    function testFuzzLog2IsExactAtPowersOfTwo(uint8 k) public view {
        k = uint8(bound(k, 0, 200));
        assertEq(pricer.log2x1e4(10_000 << k), uint256(k) * 10_000);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzLog2IsBracketedAndMonotone(uint256 r1, uint256 r2) public view {
        r1 = bound(r1, 10_000, 1e40);
        r2 = bound(r2, 10_000, 1e40);
        if (r1 > r2) (r1, r2) = (r2, r1);
        uint256 l1 = pricer.log2x1e4(r1);
        uint256 l2 = pricer.log2x1e4(r2);
        assertLe(l1, l2, "log2 not monotone");
        uint256 floor;
        for (uint256 r = r1; r >= 20_000; r /= 2) {
            floor += 1;
        }
        assertGe(l1, floor * 10_000);
        assertLt(l1, (floor + 1) * 10_000);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzSqrtIsTheIntegerFloor(uint256 x) public view {
        x = bound(x, 0, type(uint256).max - 1);
        uint256 y = pricer.sqrt(x);
        assertLe(y, type(uint128).max);
        assertLe(y * y, x, "sqrt above the root");
        if (y < type(uint128).max) assertGt((y + 1) * (y + 1), x, "sqrt below the floor");
    }

    function testSqrtPins() public view {
        assertEq(pricer.sqrt(0), 0);
        assertEq(pricer.sqrt(1), 1);
        assertEq(pricer.sqrt(3), 1);
        assertEq(pricer.sqrt(4), 2);
        assertEq(pricer.sqrt(3_000_000_000), 54_772);
    }

    // ------------------------------------------------------------------ fromSqrt

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzFromSqrtIsMonotoneAndInverts(uint160 s1, uint160 s2) public view {
        s1 = uint160(bound(s1, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE));
        s2 = uint160(bound(s2, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE));
        if (s1 > s2) (s1, s2) = (s2, s1);
        uint256 p1 = pricer.fromSqrt(s1, true);
        uint256 p2 = pricer.fromSqrt(s2, true);
        assertLe(p1, p2, "token0 price not monotone in sqrtP");
        // outside [1e-6, 1e6] token1 per token0 the 1e18-scaled inverse loses its precision (the documented
        // 18-decimal limitation); inside it the two orientations must agree
        if (p1 >= 1e12 && p1 <= 1e24) {
            uint256 inv = pricer.fromSqrt(s1, false);
            assertApproxEqRel(FullMath.mulDiv(p1, inv, 1e18), 1e18, 1e9, "the two orientations do not invert");
        }
    }

    function testFromSqrtRefusesAnEmptyOrUnpriceableReading() public {
        vm.expectRevert(MarginaliaPricer.EmptyPool.selector);
        pricer.fromSqrt(0, true);
        vm.expectRevert(MarginaliaPricer.EmptyPool.selector);
        pricer.fromSqrt(0, false);
        // a sqrt price so low that token0 is worth less than 1e-18 token1 cannot be inverted
        vm.expectRevert(MarginaliaPricer.EmptyPool.selector);
        pricer.fromSqrt(TickMath.MIN_SQRT_PRICE, false);
        assertEq(pricer.fromSqrt(uint160(1 << 96), true), 1e18);
        assertEq(pricer.fromSqrt(uint160(1 << 96), false), 1e18);
        assertEq(pricer.fromSqrt(uint160(2 << 96), true), 4e18);
        assertEq(pricer.fromSqrt(uint160(2 << 96), false), 0.25e18);
    }

    // ------------------------------------------------------------------ settlement

    function _series(uint256[16] memory xs, uint256[16] memory qs, uint8 n)
        private
        pure
        returns (T.Observation[] memory obs)
    {
        obs = new T.Observation[](n);
        for (uint256 i; i < n; ++i) {
            obs[i] = T.Observation(uint64(i * 600), uint64(i * 50), xs[i], qs[i], 0);
        }
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzV4SettlesOnTheExtremeOfEveryObservation(
        uint256[16] memory xs,
        uint256[16] memory qs,
        uint8 n
    ) public view {
        n = uint8(bound(n, 1, 16));
        uint256 xMin = type(uint256).max;
        uint256 xMax;
        uint256 qMin = type(uint256).max;
        uint256 qMax;
        for (uint256 i; i < n; ++i) {
            xs[i] = bound(xs[i], 1, 1e30);
            qs[i] = bound(qs[i], 1, 1e30);
            if (xs[i] < xMin) xMin = xs[i];
            if (xs[i] > xMax) xMax = xs[i];
            if (qs[i] < qMin) qMin = qs[i];
            if (qs[i] > qMax) qMax = qs[i];
        }
        T.Observation[] memory obs = _series(xs, qs, n);
        T.Venue memory v = T.Venue(T.VenueKind.UniV4, bytes32(0), address(0), true);
        assertEq(
            pricer.settlePrice(v, true, obs), FullMath.mulDiv(xMin, qMin, 1e18), "BUY is not the minimum"
        );
        assertEq(
            pricer.settlePrice(v, false, obs), FullMath.mulDiv(xMax, qMax, 1e18), "SELL is not the maximum"
        );
    }

    /// @dev One honest observation pins the extreme whatever else is appended: the BUY price can only fall
    /// and the SELL price can only rise as the series grows.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzzAppendingAnObservationNeverHelpsTheCall(
        uint256[16] memory xs,
        uint256[16] memory qs,
        uint8 n
    ) public view {
        n = uint8(bound(n, 2, 16));
        for (uint256 i; i < n; ++i) {
            xs[i] = bound(xs[i], 1, 1e30);
            qs[i] = bound(qs[i], 1, 1e30);
        }
        T.Observation[] memory longer = _series(xs, qs, n);
        T.Observation[] memory shorter = _series(xs, qs, n - 1);
        T.Venue memory v = T.Venue(T.VenueKind.UniV4, bytes32(0), address(0), true);
        assertLe(pricer.settlePrice(v, true, longer), pricer.settlePrice(v, true, shorter));
        assertGe(pricer.settlePrice(v, false, longer), pricer.settlePrice(v, false, shorter));
    }

    /// @dev An accumulator venue settles on the first and last reading only: a pumped middle block that
    /// unwound before the next reading leaves the accumulator difference unchanged.
    /// forge-config: default.fuzz.runs = 512
    function testFuzzV3SettlementIgnoresMiddleReadings(
        int24 tick,
        uint256[16] memory middle,
        uint8 n,
        bool x0
    ) public view {
        // ticks whose price is representable in both orientations at 1e18 scale (|tick| < ~414k)
        tick = int24(bound(tick, -400_000, 400_000));
        n = uint8(bound(n, 3, 16));
        uint256[16] memory xs;
        uint256[16] memory qs;
        uint64 span = uint64(n - 1) * 600;
        xs[0] = uint256(int256(1_000_000));
        xs[n - 1] = uint256(int256(1_000_000) + int256(tick) * int256(uint256(span)));
        for (uint256 i = 1; i + 1 < n; ++i) {
            xs[i] = middle[i];
        }
        for (uint256 i; i < n; ++i) {
            qs[i] = 1e18;
        }
        T.Observation[] memory obs = _series(xs, qs, n);
        T.Venue memory v = T.Venue(T.VenueKind.UniV3, bytes32(0), address(0), x0);
        uint256 expected = pricer.fromSqrt(TickMath.getSqrtPriceAtTick(tick), x0);
        assertEq(pricer.settlePrice(v, true, obs), expected);
        assertEq(pricer.settlePrice(v, false, obs), expected);
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzzV2TwapOfAConstantRatioIsThatRatio(uint112 r0, uint112 r1, uint32 dt, bool x0)
        public
        view
    {
        r0 = uint112(bound(r0, 1, type(uint112).max));
        r1 = uint112(bound(r1, 1, type(uint112).max));
        dt = uint32(bound(dt, 1, 30 days));
        uint256 ratio = x0 ? FullMath.mulDiv(r1, 2 ** 112, r0) : FullMath.mulDiv(r0, 2 ** 112, r1);
        uint256 c1 = uint256(keccak256(abi.encode(r0, r1))); // any starting cumulative
        uint256 c2;
        unchecked {
            c2 = c1 + ratio * dt;
        }
        uint256 got = pricer.twap(T.VenueKind.UniV2, x0, c1, 100, c2, 100 + dt);
        uint256 want = x0 ? FullMath.mulDiv(r1, 1e18, r0) : FullMath.mulDiv(r0, 1e18, r1);
        assertApproxEqAbs(got, want, 1, "v2 TWAP of a flat ratio");
    }

    function testSettlementRefusesAnEmptyOrUnspannedSeries() public {
        T.Observation[] memory none;
        T.Venue memory v4 = T.Venue(T.VenueKind.UniV4, bytes32(0), address(0), true);
        vm.expectRevert(MarginaliaPricer.Unsupported.selector);
        pricer.settlePrice(v4, true, none);
        T.Observation[] memory one = new T.Observation[](1);
        one[0] = T.Observation(100, 10, 5, 1e18, 0);
        // one v4 reading is a price; one accumulator reading spans no time and is not
        assertEq(pricer.settlePrice(v4, true, one), 5);
        T.Venue memory v3 = T.Venue(T.VenueKind.UniV3, bytes32(0), address(0), true);
        vm.expectRevert(MarginaliaPricer.Unsupported.selector);
        pricer.settlePrice(v3, true, one);
        T.Venue memory none_ = T.Venue(T.VenueKind.None, bytes32(0), address(0), true);
        vm.expectRevert(MarginaliaPricer.Unsupported.selector);
        pricer.settlePrice(none_, true, one);
    }

    function testV3TwapRefusesAMeanTickOutsideTheRange() public {
        uint256 c1 = 0;
        uint256 c2 = uint256(int256(TickMath.MAX_TICK) + 1) * 10;
        vm.expectRevert(MarginaliaPricer.Unsupported.selector);
        pricer.twap(T.VenueKind.UniV3, true, c1, 0, c2, 10);
        c2 = uint256(int256(int256(TickMath.MIN_TICK) - 1) * 10);
        vm.expectRevert(MarginaliaPricer.Unsupported.selector);
        pricer.twap(T.VenueKind.UniV3, true, c1, 0, c2, 10);
        // the exact bounds are still priceable
        assertGt(pricer.twap(T.VenueKind.UniV3, true, c1, 0, uint256(int256(TickMath.MAX_TICK)) * 10, 10), 0);
    }

    function testTwapRefusesTimeRunningBackwards() public {
        vm.expectRevert(MarginaliaPricer.Unsupported.selector);
        pricer.twap(T.VenueKind.UniV2, true, 0, 20, 0, 10);
    }

    // ------------------------------------------------------------------ observations and quotes

    function testObserveRefusesUnknownVenuesAndUnpriceableQuotes() public {
        vm.expectRevert(MarginaliaPricer.Unsupported.selector);
        pricer.observe(manager, T.Venue(T.VenueKind.None, POOL, imd, true), imd);
        address other = makeAddr("some other quote");
        vm.expectRevert(MarginaliaPricer.QuoteNotPriceable.selector);
        pricer.observe(manager, T.Venue(T.VenueKind.UniV4, POOL, other, true), imd);
        // IMD quotes read 1:1; ETH and WETH quotes read the hub
        (uint256 x, uint256 q) = pricer.observe(manager, T.Venue(T.VenueKind.UniV4, POOL, imd, true), imd);
        assertEq(x, 1e18);
        assertEq(q, 1e18);
        state.setPool(pricer.HUB_POOL_ID(), uint160(3 << 96), 1 ether);
        (, q) = pricer.observe(manager, T.Venue(T.VenueKind.UniV4, POOL, address(0), true), imd);
        assertEq(q, 9e18);
        (, q) = pricer.observe(manager, T.Venue(T.VenueKind.UniV4, POOL, pricer.WETH(), true), imd);
        assertEq(q, 9e18);
    }

    function testEthQuoteIsOnlyPriceableOnMainnet() public {
        vm.chainId(8453);
        vm.expectRevert(MarginaliaPricer.QuoteNotPriceable.selector);
        pricer.observe(manager, T.Venue(T.VenueKind.UniV4, POOL, address(0), true), imd);
        // and an IMD-quoted venue still prices anywhere
        (uint256 x,) = pricer.observe(manager, T.Venue(T.VenueKind.UniV4, POOL, imd, true), imd);
        assertEq(x, 1e18);
    }

    function testEmptyPoolsAreRefusedOnBothLegs() public {
        state.setPool(POOL, uint160(1 << 96), 0);
        vm.expectRevert(MarginaliaPricer.EmptyPool.selector);
        pricer.observe(manager, T.Venue(T.VenueKind.UniV4, POOL, imd, true), imd);
        state.setPool(POOL, uint160(1 << 96), 1 ether);
        state.setPool(pricer.HUB_POOL_ID(), uint160(1 << 96), 0);
        vm.expectRevert(MarginaliaPricer.EmptyPool.selector);
        pricer.observe(manager, T.Venue(T.VenueKind.UniV4, POOL, address(0), true), imd);
    }

    // ------------------------------------------------------------------ posting window boundaries

    /// @dev A baseline is readable exactly within [start + 1h, start + 6h] and only from a later block.
    /// forge-config: default.fuzz.runs = 512
    function testFuzzPostPriceWindowBoundaries(uint256 dt, bool sameBlock) public {
        dt = bound(dt, 0, 8 hours);
        T.Venue memory v = T.Venue(T.VenueKind.UniV4, POOL, imd, true);
        T.PriceWindow memory empty;
        T.PriceWindow memory w = pricer.checkpoint(manager, v, imd, empty);
        vm.warp(uint256(w.startedAt) + dt);
        if (!sameBlock) vm.roll(uint256(w.blockNumber) + 1);
        bool open = dt >= pricer.POST_MIN_SPAN() && dt <= pricer.POST_MAX_AGE() && !sameBlock;
        if (!open) vm.expectRevert(MarginaliaPricer.PriceHistoryUnavailable.selector);
        uint256 p = pricer.postPrice(manager, v, imd, true, w);
        if (open) assertEq(p, 1e18);
    }

    function testPostPriceRefusesAnEmptyWindow() public {
        T.PriceWindow memory empty;
        vm.expectRevert(MarginaliaPricer.PriceHistoryUnavailable.selector);
        pricer.postPrice(manager, T.Venue(T.VenueKind.UniV4, POOL, imd, true), imd, true, empty);
    }

    /// @dev Checkpoints keep the start until expiry, then restart; the extremes only widen, never narrow.
    /// forge-config: default.fuzz.runs = 512
    function testFuzzCheckpointKeepsStartAndWidensExtremes(uint160 s1, uint160 s2, uint256 dt) public {
        s1 = uint160(bound(s1, uint160(1 << 90), uint160(1 << 100)));
        s2 = uint160(bound(s2, uint160(1 << 90), uint160(1 << 100)));
        dt = bound(dt, 1, 8 hours);
        T.Venue memory v = T.Venue(T.VenueKind.UniV4, POOL, imd, true);
        state.setPool(POOL, s1, 1 ether);
        T.PriceWindow memory empty;
        T.PriceWindow memory w = pricer.checkpoint(manager, v, imd, empty);
        assertEq(w.xMin, w.xMax);
        assertEq(w.xStart, w.xMin);
        vm.warp(vm.getBlockTimestamp() + dt);
        vm.roll(vm.getBlockNumber() + 1);
        state.setPool(POOL, s2, 1 ether);
        T.PriceWindow memory w2 = pricer.checkpoint(manager, v, imd, w);
        uint256 now_ = pricer.fromSqrt(s2, true);
        if (dt > pricer.POST_MAX_AGE()) {
            assertEq(w2.startedAt, vm.getBlockTimestamp(), "an expired window did not restart");
            assertEq(w2.xMin, now_);
            assertEq(w2.xMax, now_);
        } else {
            assertEq(w2.startedAt, w.startedAt, "a live window moved its start");
            assertEq(w2.blockNumber, w.blockNumber);
            assertEq(w2.xStart, w.xStart);
            assertEq(w2.xMin, now_ < w.xMin ? now_ : w.xMin);
            assertEq(w2.xMax, now_ > w.xMax ? now_ : w.xMax);
            assertLe(w2.xMin, w.xMin);
            assertGe(w2.xMax, w.xMax);
        }
    }
}
