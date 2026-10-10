// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./helpers/Fixture.sol";
import {MarginaliaHook} from "../src/MarginaliaHook.sol";
import {MarginaliaPricer} from "../src/MarginaliaPricer.sol";
import {MarginaliaTypes as T} from "../src/MarginaliaTypes.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

/// @title Regressions for the third review round, on the repository fixture.
contract Round3FindingsTest is Fixture {
    using PoolIdLibrary for PoolKey;

    address internal dave = makeAddr("dave");
    address internal attacker = makeAddr("attacker");

    function setUp() public {
        _setup();
        imd.transfer(dave, 100 ether);
        imd.transfer(attacker, 2000 ether);
        vm.prank(dave);
        imd.approve(address(router), type(uint256).max);
        vm.startPrank(attacker);
        imd.approve(address(router), type(uint256).max);
        imd.approve(address(plain), type(uint256).max);
        imd.approve(address(hook), type(uint256).max);
        vm.stopPrank();
    }

    function _observeThree(bytes32 id) internal {
        uint256 end = hook.horizonEnd(id);
        vm.warp(end);
        hook.observe(id);
        vm.warp(end + 30 minutes);
        vm.roll(vm.getBlockNumber() + 150);
        hook.observe(id);
        vm.warp(end + 61 minutes);
        vm.roll(vm.getBlockNumber() + 155);
        hook.observe(id);
        vm.warp(end + hook.SETTLE_WINDOW() + 1);
    }

    // ---------------------------------------------------------------- c7331916: a self-priced venue earns no score

    /// @dev The attacker's own hookless X/IMD pool, with the attacker as its only LP; a 100x BUY call on it.
    function _selfVenueCall(uint32 targetBps)
        internal
        returns (bytes32 id, PoolKey memory xKey, MockERC20 x, bool x0)
    {
        vm.startPrank(attacker);
        x = new MockERC20("X", "X", 1e27);
        x0 = address(x) < address(imd);
        (address c0, address c1) = x0 ? (address(x), address(imd)) : (address(imd), address(x));
        xKey = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 3000, 60, IHooks(address(0)));
        manager.initialize(xKey, uint160(1 << 96));
        x.transfer(address(liquidity), 10 ether);
        imd.transfer(address(liquidity), 10 ether);
        liquidity.add(xKey, -887_220, 887_220, 1e18);
        T.NoteParams memory p = _margNote(T.Side.Buy, targetBps, 1, "100x");
        p.x = address(x);
        p.venue = T.Venue(T.VenueKind.UniV4, PoolId.unwrap(xKey.toId()), address(0), false);
        router.checkpointVenue(p, xKey);
        vm.warp(block.timestamp + 1 hours);
        vm.roll(block.number + 300);
        router.note(p, xKey, 1 ether, 1, block.timestamp + 1);
        vm.stopPrank();
        id = bytes32(hook.noteCount());
        assertEq(hook.noteOf(id).postPrice, 1e18);
    }

    function testASelfPricedVenueDrawsNothingFromTheLeaderboard() public {
        (bytes32 id, PoolKey memory xKey,, bool x0) = _selfVenueCall(1_000_000);
        uint32 w = hook.week();
        vm.warp(hook.horizonEnd(id));
        vm.prank(attacker);
        plain.swap(xKey, !x0, 11 ether, attacker); // pump X ~144x; nobody else holds X to sell it back
        _observeThree(id);
        hook.settle(id);
        vm.prank(attacker);
        hook.fundPot(1000 ether);
        // The call is "right" on its own pool: the deposit comes back, but it scores nothing anywhere.
        assertEq(uint8(hook.noteOf(id).status), uint8(T.Status.Right));
        assertGt(hook.noteOf(id).deposit, 0);
        assertEq(_rec(attacker).right, 1);
        assertEq(_rec(attacker).score, 0);
        assertEq(hook.weekScore(w, attacker), 0);
        assertEq(hook.weekTotal(w), 0);
        assertGt(hook.leaderboardPool(w), 500 ether);
        assertEq(hook.leaderboardShare(w, attacker), 0, "self-priced venue pays the leaderboard");
        vm.warp((uint256(w) + 1) * 7 days + 1);
        vm.prank(attacker);
        vm.expectRevert(MarginaliaHook.NothingToClaim.selector);
        hook.claimLeaderboard(w);
    }

    function testAWrongCallOnAnotherVenueStillForfeitsButBooksNoScore() public {
        (bytes32 id,,,) = _selfVenueCall(20_000);
        uint256 deposit = hook.noteOf(id).deposit;
        _observeThree(id); // X never moved: a 2x call is wrong
        uint256 potBefore = hook.potMarg();
        vm.prank(carol);
        hook.settle(id);
        assertEq(uint8(hook.noteOf(id).status), uint8(T.Status.Wrong));
        assertEq(hook.noteOf(id).deposit, 0);
        assertEq(hook.potMarg() - potBefore, deposit - deposit * hook.KEEPER_BPS() / 10_000);
        assertEq(_rec(attacker).wrong, 1);
        assertEq(_rec(attacker).score, 0);
        assertEq(hook.weekScore(hook.week(), attacker), 0);
    }

    function testRetractingACallOnAnotherVenueBooksNoScore() public {
        (bytes32 id,,,) = _selfVenueCall(20_000);
        vm.prank(attacker);
        hook.retract(id, "never mind");
        assertEq(_rec(attacker).retracted, 1);
        assertEq(_rec(attacker).score, 0);
    }

    function testALaunchPoolCallStillScoresAndPaysTheLeaderboard() public {
        uint32 w = hook.week();
        (bytes32 id,) = _note(alice, _margNote(T.Side.Buy, 11_000, 1, "+10%"), 10 ether);
        _buy(bob, 1_500_000 ether);
        _observeThree(id);
        hook.settle(id);
        assertEq(uint8(hook.noteOf(id).status), uint8(T.Status.Right));
        assertEq(_rec(alice).score, 20_538);
        assertEq(hook.weekScore(w, alice), 20_538);
        assertGt(hook.leaderboardShare(w, alice), 0);
    }

    // ---------------------------------------------------------------- 80c42ce7: a stranger's gift cannot void a SELL call

    /// @dev dave holds no MARG; his SELL call on MARG is posted through a 1 IMD buy (post balance ~0.4 MARG).
    function _daveSellCall() internal returns (bytes32 id) {
        vm.prank(dave);
        router.note(_margNote(T.Side.Sell, 9000, 1, "-10%"), key, 1 ether, 1, block.timestamp + 1);
        id = bytes32(hook.noteCount());
        token.transfer(bob, 2_000_000 ether);
        _sell(bob, 1_500_000 ether); // the market falls: the call is right
        assertLt(hook.margPriceInImd(), 0.8e18);
    }

    function testAGiftWorthTheDepositDoesNotVoidACorrectSellCall() public {
        bytes32 id = _daveSellCall();
        uint256 deposit = hook.noteOf(id).deposit;
        token.transfer(dave, 0.5e18 + 1); // carol's gift: just over the deposit's worth of MARG
        _observeThree(id);
        vm.prank(carol);
        hook.settle(id);
        assertEq(uint8(hook.noteOf(id).status), uint8(T.Status.Right));
        assertEq(hook.noteOf(id).deposit, deposit);
        assertEq(_rec(dave).broken, 0);
        assertGt(_rec(dave).score, 0);
        assertEq(token.balanceOf(carol), 0, "the gifter earned no keeper reward");
    }

    function testAGiftOfAnySizeDoesNotVoidACorrectSellCall() public {
        bytes32 id = _daveSellCall();
        token.transfer(dave, 1_000_000 ether);
        _observeThree(id);
        hook.settle(id);
        assertEq(uint8(hook.noteOf(id).status), uint8(T.Status.Right));
        assertEq(_rec(dave).broken, 0);
    }

    function testAWrongSellCallStillForfeits() public {
        vm.prank(dave);
        router.note(_margNote(T.Side.Sell, 9000, 1, "-10%"), key, 1 ether, 1, block.timestamp + 1);
        bytes32 id = bytes32(hook.noteCount());
        _observeThree(id); // flat market: -10% did not happen
        hook.settle(id);
        assertEq(uint8(hook.noteOf(id).status), uint8(T.Status.Wrong));
        assertEq(hook.noteOf(id).deposit, 0);
        assertLt(_rec(dave).score, 0);
    }

    function testABuyCallStillBreaksWhenTheAuthorSells() public {
        (bytes32 id,) = _note(alice, _margNote(T.Side.Buy, 11_000, 1, "+10%"), 10 ether);
        _buy(bob, 1_500_000 ether);
        _sell(alice, token.balanceOf(alice) / 2);
        _observeThree(id);
        hook.settle(id);
        assertEq(uint8(hook.noteOf(id).status), uint8(T.Status.VoidSold));
        assertEq(_rec(alice).broken, 1);
    }

    // ---------------------------------------------------------------- 4e3977e5: sqrt floors everywhere

    function testSqrtFloorsSmallInputs() public view {
        MarginaliaPricer pricer = hook.pricer();
        assertEq(pricer.sqrt(0), 0);
        assertEq(pricer.sqrt(1), 1);
        assertEq(pricer.sqrt(2), 1, "sqrt(2) must floor to 1");
        assertEq(pricer.sqrt(3), 1);
        assertEq(pricer.sqrt(4), 2);
        for (uint256 i = 0; i < 1024; ++i) {
            uint256 r = pricer.sqrt(i);
            assertLe(r * r, i, "sqrt above the root");
            assertGt((r + 1) * (r + 1), i, "sqrt below the root");
        }
        assertEq(pricer.sqrt(type(uint256).max), 340282366920938463463374607431768211455);
    }

    function testFuzzSqrtIsTheIntegerFloor(uint256 x) public view {
        uint256 r = hook.pricer().sqrt(x);
        assertLe(r, type(uint128).max);
        assertLe(r * r, x);
        if (r < type(uint128).max) assertGt((r + 1) * (r + 1), x);
    }
}
