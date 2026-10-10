// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {MarginaliaPricer} from "../src/MarginaliaPricer.sol";
import {MarginaliaTypes as T} from "../src/MarginaliaTypes.sol";

/// @dev The settlement rule in isolation: accumulator TWAPs for v3 / v2, the adverse extreme for v4 and the quote leg.
contract PricerTest is Test {
    MarginaliaPricer pricer;

    function setUp() public {
        pricer = new MarginaliaPricer();
    }

    function _obs(uint64 ts, uint256 x, uint256 q) private pure returns (T.Observation memory o) {
        o.timestamp = ts;
        o.blockNumber = ts / 12;
        o.xRead = x;
        o.quoteRead = q;
    }

    function testV3TwapOfAConstantTickIsThatTick() public view {
        int256 tick = 6931; // ~2x
        uint256 c1 = uint256(int256(1000) * tick);
        uint256 c2 = uint256(int256(4600) * tick);
        uint256 p = pricer.twap(T.VenueKind.UniV3, true, c1, 1000, c2, 4600);
        assertEq(p, pricer.fromSqrt(TickMath.getSqrtPriceAtTick(int24(tick)), true));
        assertApproxEqRel(p, 2e18, 0.001e18);
    }

    function testV3TwapRoundsNegativeMeansDown() public view {
        // cumulative falls by 7 over 2 seconds: mean -3.5 -> tick -4, as v3 rounds
        uint256 c1 = uint256(int256(-100));
        uint256 c2 = uint256(int256(-107));
        uint256 p = pricer.twap(T.VenueKind.UniV3, true, c1, 10, c2, 12);
        assertEq(p, pricer.fromSqrt(TickMath.getSqrtPriceAtTick(-4), true));
    }

    function testV3TwapWeightsByTime() public view {
        // tick 0 for 3000s then tick 10_000 for 600s: mean tick 1666 (rounded down)
        uint256 c1 = 0;
        uint256 c2 = uint256(int256(10_000) * 600);
        uint256 p = pricer.twap(T.VenueKind.UniV3, true, c1, 0, c2, 3600);
        assertEq(p, pricer.fromSqrt(TickMath.getSqrtPriceAtTick(1666), true));
    }

    function testV2TwapFromWrappingCumulative() public view {
        uint256 ratio = FullMath.mulDiv(3e18, 2 ** 112, 1e18); // X worth 3 quote, UQ112x112
        uint256 c1 = type(uint256).max - ratio * 100; // about to wrap
        uint256 c2;
        unchecked {
            c2 = c1 + ratio * 3600;
        }
        uint256 p = pricer.twap(T.VenueKind.UniV2, true, c1, 100, c2, 3700);
        assertApproxEqAbs(p, 3e18, 1e6);
    }

    function testTwapRefusesZeroSpanAndV4() public {
        vm.expectRevert(MarginaliaPricer.Unsupported.selector);
        pricer.twap(T.VenueKind.UniV3, true, 0, 10, 0, 10);
        vm.expectRevert(MarginaliaPricer.Unsupported.selector);
        pricer.twap(T.VenueKind.UniV4, true, 0, 10, 0, 20);
    }

    function testV4SettlesOnTheAdverseExtreme() public view {
        T.Observation[] memory obs = new T.Observation[](3);
        obs[0] = _obs(0, 1e18, 1e18);
        obs[1] = _obs(1800, 5e18, 1e18); // the pumped block
        obs[2] = _obs(3600, 1.1e18, 1e18);
        T.Venue memory v = T.Venue(T.VenueKind.UniV4, bytes32(0), address(0), true);
        assertEq(pricer.settlePrice(v, true, obs), 1e18, "a BUY call gets the minimum");
        assertEq(pricer.settlePrice(v, false, obs), 5e18, "a SELL call gets the maximum");
    }

    function testQuoteLegIsAdverseEvenUnderAV3Twap() public view {
        // X flat at tick 0 (1 quote per X); the hub leg prints 10, 50, 12 IMD per quote across the window
        T.Observation[] memory obs = new T.Observation[](3);
        obs[0] = _obs(0, 0, 10e18);
        obs[1] = _obs(1800, 0, 50e18);
        obs[2] = _obs(3600, 0, 12e18);
        T.Venue memory v = T.Venue(T.VenueKind.UniV3, bytes32(0), address(0), true);
        assertEq(pricer.settlePrice(v, true, obs), 10e18);
        assertEq(pricer.settlePrice(v, false, obs), 50e18);
    }
}
