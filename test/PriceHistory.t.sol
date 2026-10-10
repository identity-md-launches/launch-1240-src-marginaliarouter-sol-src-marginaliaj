// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {MarginaliaPricer} from "../src/MarginaliaPricer.sol";
import {MarginaliaTypes as T} from "../src/MarginaliaTypes.sol";

/// @dev Storage layout read by StateLibrary: the mock controls only pool state, not pricer results.
contract PriceManagerMock {
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

/// @dev Accumulates time at the previous reserves when a swap changes them, as a v2 pair does.
contract CumulativeV2Mock {
    uint112 private r0;
    uint112 private r1;
    uint32 private last;
    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;

    function setReserves(uint112 a, uint112 b) external {
        if (r0 != 0 && r1 != 0) {
            uint256 dt = block.timestamp - last;
            price0CumulativeLast += (uint256(r1) << 112) / r0 * dt;
            price1CumulativeLast += (uint256(r0) << 112) / r1 * dt;
        }
        r0 = a;
        r1 = b;
        last = uint32(block.timestamp);
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (r0, r1, last);
    }
}

/// @dev Accumulates the old tick up to the swap's timestamp; same-block swaps add no tick-time.
contract CumulativeV3Mock {
    int24 public tick;
    int56 private cumulative;
    uint64 private last;

    constructor() {
        last = uint64(block.timestamp);
    }

    function setTick(int24 next) external {
        cumulative += int56(tick) * int56(uint56(block.timestamp - last));
        last = uint64(block.timestamp);
        tick = next;
    }

    function observe(uint32[] calldata ago)
        external
        view
        returns (int56[] memory ticks, uint160[] memory liquidity)
    {
        require(ago.length == 1 && ago[0] == 0);
        ticks = new int56[](1);
        ticks[0] = cumulative + int56(tick) * int56(uint56(block.timestamp - last));
        liquidity = new uint160[](1);
    }
}

contract PriceHistoryTest is Test {
    MarginaliaPricer private pricer;
    PriceManagerMock private state;
    IPoolManager private manager;
    address private imd = makeAddr("price history IMD");
    bytes32 private constant POOL = keccak256("price history pool");

    function setUp() public {
        vm.chainId(1);
        vm.warp(1_800_000_000);
        vm.roll(1000);
        pricer = new MarginaliaPricer();
        state = new PriceManagerMock();
        manager = IPoolManager(address(state));
        state.setPool(POOL, uint160(1 << 96), 1 ether);
        state.setPool(pricer.HUB_POOL_ID(), uint160(1 << 96), 1 ether);
    }

    function _v4() private view returns (T.Venue memory) {
        return T.Venue(T.VenueKind.UniV4, POOL, imd, true);
    }

    function _warm(T.PriceWindow memory w) private {
        vm.warp(uint256(w.startedAt) + 1 hours);
        vm.roll(uint256(w.blockNumber) + 300);
    }

    function _window(T.Venue memory v) private view returns (T.PriceWindow memory) {
        T.PriceWindow memory empty;
        return pricer.checkpoint(manager, v, imd, empty);
    }

    function testBaselineRequiresMatureFreshHistory() public {
        T.Venue memory v = _v4();
        T.PriceWindow memory w;
        vm.expectRevert(MarginaliaPricer.PriceHistoryUnavailable.selector);
        pricer.postPrice(manager, v, imd, true, w);
        w = _window(v);
        vm.expectRevert(MarginaliaPricer.PriceHistoryUnavailable.selector);
        pricer.postPrice(manager, v, imd, true, w);
        vm.warp(uint256(w.startedAt) + 1 hours); // same block remains invalid even with a moved test clock
        vm.expectRevert(MarginaliaPricer.PriceHistoryUnavailable.selector);
        pricer.postPrice(manager, v, imd, true, w);
        vm.roll(uint256(w.blockNumber) + 300);
        assertEq(pricer.postPrice(manager, v, imd, true, w), 1e18);
        vm.warp(uint256(w.startedAt) + 6 hours);
        assertEq(pricer.postPrice(manager, v, imd, true, w), 1e18);
        vm.warp(uint256(w.startedAt) + 6 hours + 1);
        vm.expectRevert(MarginaliaPricer.PriceHistoryUnavailable.selector);
        pricer.postPrice(manager, v, imd, true, w);
        w = pricer.checkpoint(manager, v, imd, w);
        vm.expectRevert(MarginaliaPricer.PriceHistoryUnavailable.selector);
        pricer.postPrice(manager, v, imd, true, w);
        _warm(w);
        assertEq(pricer.postPrice(manager, v, imd, true, w), 1e18);
    }

    function testLiveCheckpointCannotEraseHonestExtremesOrRestartTheClock() public {
        T.Venue memory v = _v4();
        T.PriceWindow memory w = _window(v);
        uint64 start = w.startedAt;
        state.setPool(POOL, uint160(2 << 96), 1 ether);
        w = pricer.checkpoint(manager, v, imd, w);
        state.setPool(POOL, uint160(1 << 95), 1 ether);
        w = pricer.checkpoint(manager, v, imd, w);
        assertEq(w.startedAt, start);
        _warm(w);
        state.setPool(POOL, uint160(1 << 96), 1 ether);
        w = pricer.checkpoint(manager, v, imd, w);
        assertEq(pricer.postPrice(manager, v, imd, true, w), 4e18);
        assertEq(pricer.postPrice(manager, v, imd, false, w), 0.25e18);
    }

    function testFuzzV4BaselineIsNeverFavourableToTheCall(int24 tick, bool buy) public {
        tick = int24(bound(int256(tick), -100_000, 100_000));
        T.Venue memory v = _v4();
        T.PriceWindow memory w = _window(v);
        _warm(w);
        state.setPool(POOL, TickMath.getSqrtPriceAtTick(tick), 1 ether);
        w = pricer.checkpoint(manager, v, imd, w);
        uint256 baseline = pricer.postPrice(manager, v, imd, buy, w);
        if (buy) assertGe(baseline, 1e18);
        else assertLe(baseline, 1e18);
    }

    function testV2BaselineIgnoresSameBlockReservesDumpAndPumpBothOrientations() public {
        CumulativeV2Mock pair = new CumulativeV2Mock();
        pair.setReserves(100 ether, 200 ether);
        T.Venue memory v = T.Venue(T.VenueKind.UniV2, bytes32(uint256(uint160(address(pair)))), imd, true);
        T.PriceWindow memory forward = _window(v);
        v.xIsToken0 = false;
        T.PriceWindow memory inverse = _window(v);
        _warm(forward);
        pair.setReserves(400 ether, 50 ether); // change only this block's spot
        assertEq(pricer.postPrice(manager, v, imd, false, inverse), 0.5e18);
        v.xIsToken0 = true;
        assertEq(pricer.postPrice(manager, v, imd, true, forward), 2e18);
        pair.setReserves(10 ether, 2000 ether);
        assertEq(pricer.postPrice(manager, v, imd, false, forward), 2e18);
    }

    function testV3BaselineIgnoresSameBlockTickChangesBothOrientations() public {
        CumulativeV3Mock pool = new CumulativeV3Mock();
        T.Venue memory v = T.Venue(T.VenueKind.UniV3, bytes32(uint256(uint160(address(pool)))), imd, true);
        T.PriceWindow memory w = _window(v);
        _warm(w);
        pool.setTick(-10_000);
        assertEq(pricer.postPrice(manager, v, imd, true, w), 1e18);
        pool.setTick(10_000);
        v.xIsToken0 = false;
        assertEq(pricer.postPrice(manager, v, imd, false, w), 1e18);
    }

    function testV3BaselineWeightsElapsedTime() public {
        CumulativeV3Mock pool = new CumulativeV3Mock();
        T.Venue memory v = T.Venue(T.VenueKind.UniV3, bytes32(uint256(uint160(address(pool)))), imd, true);
        T.PriceWindow memory w = _window(v);
        vm.warp(uint256(w.startedAt) + 30 minutes);
        pool.setTick(10_000);
        _warm(w);
        uint256 expected = pricer.fromSqrt(TickMath.getSqrtPriceAtTick(5000), true);
        assertEq(pricer.postPrice(manager, v, imd, true, w), expected);
    }

    function testHubBaselineUsesOppositeExtremeFromSettlement() public {
        T.Venue memory v = _v4();
        v.quote = pricer.WETH();
        T.PriceWindow memory w = _window(v);
        _warm(w);
        state.setPool(pricer.HUB_POOL_ID(), uint160(1 << 95), 1 ether);
        assertEq(pricer.postPrice(manager, v, imd, true, w), 1e18, "hub dump cannot lower BUY baseline");
        state.setPool(pricer.HUB_POOL_ID(), uint160(2 << 96), 1 ether);
        assertEq(pricer.postPrice(manager, v, imd, false, w), 1e18, "hub pump cannot raise SELL baseline");
    }

    function testEmptyVenueAndHubCannotBeCheckpointedObservedOrPriced() public {
        T.Venue memory v = _v4();
        T.PriceWindow memory w = _window(v);
        _warm(w);
        state.setPool(POOL, uint160(2 << 96), 0);
        vm.expectRevert(MarginaliaPricer.EmptyPool.selector);
        pricer.observe(manager, v, imd);
        vm.expectRevert(MarginaliaPricer.EmptyPool.selector);
        pricer.checkpoint(manager, v, imd, w);
        vm.expectRevert(MarginaliaPricer.EmptyPool.selector);
        pricer.postPrice(manager, v, imd, true, w);
        state.setPool(POOL, uint160(1 << 96), 1 ether);
        state.setPool(pricer.HUB_POOL_ID(), uint160(2 << 96), 0);
        v.quote = address(0);
        vm.expectRevert(MarginaliaPricer.EmptyPool.selector);
        pricer.observe(manager, v, imd);
        vm.expectRevert(MarginaliaPricer.EmptyPool.selector);
        pricer.checkpoint(manager, v, imd, w);
        vm.expectRevert(MarginaliaPricer.EmptyPool.selector);
        pricer.postPrice(manager, v, imd, true, w);
    }
}
