// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./helpers/Fixture.sol";
import {MarginaliaHook} from "../src/MarginaliaHook.sol";
import {MarginaliaTypes as T} from "../src/MarginaliaTypes.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

/// @title The revised hold rule and observation-replacement rule at their exact boundaries.
/// @dev The second review round made a SELL call tolerant of balance growth up to the larger of 10% of the
/// post balance and the deposit's worth of X, and let a more adverse reading replace a slot inside the block
/// gap or at the series cap. These tests pin the one-wei edges of both rules and the paths they refuse.
contract HoldRuleTest is Fixture {
    function setUp() public {
        _setup();
        vm.prank(alice);
        token.approve(address(router), type(uint256).max);
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

    /// @dev A SELL call that the market then confirms, so only the hold rule decides the outcome.
    function _sellCall() internal returns (bytes32 id) {
        vm.prank(alice);
        router.sellWithNote(_margNote(T.Side.Sell, 9000, 1, "-10%"), key, 2 ether, 1, block.timestamp + 1);
        id = bytes32(hook.noteCount());
        token.transfer(bob, 2_000_000 ether);
        _sell(bob, 1_500_000 ether);
        assertLt(hook.margPriceInImd(), 0.8e18);
    }

    /// @dev The documented tolerance: the larger of SELL_HOLD_TOLERANCE_BPS of the post balance and the
    /// deposit's worth of X at the post price.
    function _tolerance(bytes32 id) internal view returns (uint256) {
        T.Note memory n = hook.noteOf(id);
        uint256 tol = n.postBalance * hook.SELL_HOLD_TOLERANCE_BPS() / 10_000;
        uint256 worth = FullMath.mulDiv(hook.DEPOSIT(), 1e18, n.postPrice);
        return worth > tol ? worth : tol;
    }

    // ---------------------------------------------------------------- SELL tolerance edges

    function testSellCallHoldsExactlyAtTheTolerance() public {
        bytes32 id = _sellCall();
        uint256 tol = _tolerance(id);
        assertEq(tol, hook.noteOf(id).postBalance / 10, "a well-funded author is bound by the 10% rule");
        token.transfer(alice, tol);
        _observeThree(id);
        hook.settle(id);
        assertEq(uint8(hook.noteOf(id).status), uint8(T.Status.Right));
        assertEq(_rec(alice).broken, 0);
        assertGt(hook.noteOf(id).deposit, 0, "a held call keeps its deposit claimable");
    }

    function testSellCallBreaksOneWeiPastTheTolerance() public {
        bytes32 id = _sellCall();
        token.transfer(alice, _tolerance(id) + 1);
        _observeThree(id);
        hook.settle(id);
        assertEq(uint8(hook.noteOf(id).status), uint8(T.Status.VoidSold));
        assertEq(_rec(alice).broken, 1);
        assertEq(hook.noteOf(id).deposit, 0, "a broken call forfeits its deposit");
    }

    function testASingleObservationPastTheToleranceVoidsTheCall() public {
        // the balance is back under the line by the next readings; one breach in the series is enough
        bytes32 id = _sellCall();
        uint256 end = hook.horizonEnd(id);
        uint256 over = _tolerance(id) + 1;
        token.transfer(alice, over);
        vm.warp(end);
        hook.observe(id);
        vm.prank(alice);
        token.transfer(address(this), over);
        vm.warp(end + 30 minutes);
        vm.roll(vm.getBlockNumber() + 150);
        hook.observe(id);
        vm.warp(end + 61 minutes);
        vm.roll(vm.getBlockNumber() + 155);
        hook.observe(id);
        vm.warp(end + hook.SETTLE_WINDOW() + 1);
        hook.settle(id);
        assertEq(uint8(hook.noteOf(id).status), uint8(T.Status.VoidSold));
    }

    function testSmallAuthorIsBoundByTheDepositsWorthNotTenPercent() public {
        // alice keeps 3 MARG: after a 2 MARG sell her post balance is ~1 MARG, so 10% of it is below the
        // deposit's worth (0.5 IMD of MARG), and the larger bound rules
        uint256 surplus = token.balanceOf(alice) - 3 ether;
        vm.prank(alice);
        token.transfer(carol, surplus);
        bytes32 id = _sellCall();
        assertLe(hook.noteOf(id).postBalance, 1 ether);
        T.Note memory n = hook.noteOf(id);
        uint256 worth = FullMath.mulDiv(hook.DEPOSIT(), 1e18, n.postPrice);
        assertGt(worth, n.postBalance / 10, "the deposit's worth should dominate for a small holder");
        assertEq(_tolerance(id), worth);
        // a transfer past 10% of her balance but inside the deposit's worth is still held
        token.transfer(alice, worth);
        _observeThree(id);
        hook.settle(id);
        assertEq(uint8(hook.noteOf(id).status), uint8(T.Status.Right));
        assertEq(_rec(alice).broken, 0);
    }

    function testBuyCallHasNoToleranceDownwards() public {
        (bytes32 id,) = _note(alice, _margNote(T.Side.Buy, 11_000, 1, "+10%"), 10 ether);
        _buy(bob, 1_500_000 ether); // the call is right on price
        assertGt(hook.margPriceInImd(), 1.1e18);
        vm.prank(alice);
        token.transfer(carol, 1); // one wei below the post balance
        _observeThree(id);
        hook.settle(id);
        assertEq(uint8(hook.noteOf(id).status), uint8(T.Status.VoidSold));
        assertEq(_rec(alice).broken, 1);
    }

    // ---------------------------------------------------------------- replacement inside the gap

    function testABreachIsNeverReplacedByANonBreachInsideTheGap() public {
        (bytes32 id,) = _note(alice, _margNote(T.Side.Buy, 11_000, 1, "+10%"), 10 ether);
        _buy(bob, 1_500_000 ether);
        uint256 end = hook.horizonEnd(id);
        vm.warp(end);
        vm.prank(alice);
        token.transfer(carol, 1);
        hook.observe(id); // the breach is on record
        vm.prank(carol);
        token.transfer(alice, 1); // and undone a block later
        vm.roll(vm.getBlockNumber() + 1);
        vm.expectRevert(MarginaliaHook.ObservationTooSoon.selector);
        hook.observe(id);
        // past the gap the honest reading is appended, but the breach stays in the series
        vm.warp(end + 30 minutes);
        vm.roll(vm.getBlockNumber() + hook.OBS_GAP_BLOCKS());
        hook.observe(id);
        vm.warp(end + 61 minutes);
        vm.roll(vm.getBlockNumber() + hook.OBS_GAP_BLOCKS());
        hook.observe(id);
        vm.warp(end + hook.SETTLE_WINDOW() + 1);
        hook.settle(id);
        assertEq(uint8(hook.noteOf(id).status), uint8(T.Status.VoidSold));
    }

    function testABreachReplacesANonBreachInsideTheGap() public {
        (bytes32 id,) = _note(alice, _margNote(T.Side.Buy, 11_000, 1, "+10%"), 10 ether);
        _buy(bob, 1_500_000 ether);
        uint256 end = hook.horizonEnd(id);
        vm.warp(end);
        hook.observe(id); // honest, held
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(alice);
        token.transfer(carol, 1);
        vm.prank(bob);
        hook.observe(id); // a stranger catches the sale inside the gap: the slot is overwritten
        vm.prank(carol);
        token.transfer(alice, 1);
        vm.warp(end + 30 minutes);
        vm.roll(vm.getBlockNumber() + hook.OBS_GAP_BLOCKS());
        hook.observe(id);
        vm.warp(end + 61 minutes);
        vm.roll(vm.getBlockNumber() + hook.OBS_GAP_BLOCKS());
        hook.observe(id);
        vm.warp(end + hook.SETTLE_WINDOW() + 1);
        hook.settle(id);
        assertEq(uint8(hook.noteOf(id).status), uint8(T.Status.VoidSold));
    }

    function testAnEqualReadingInsideTheGapIsRefused() public {
        (bytes32 id,) = _note(alice, _margNote(T.Side.Buy, 11_000, 1, "+10%"), 10 ether);
        uint256 end = hook.horizonEnd(id);
        vm.warp(end);
        hook.observe(id);
        vm.roll(vm.getBlockNumber() + hook.OBS_GAP_BLOCKS() - 1);
        vm.expectRevert(MarginaliaHook.ObservationTooSoon.selector);
        hook.observe(id); // same price, same balance: not more adverse
        vm.roll(vm.getBlockNumber() + 1);
        hook.observe(id); // exactly the gap: appended
    }

    // ---------------------------------------------------------------- the series cap

    function testAtTheCapOnlyAMoreAdverseReadingGetsIn() public {
        (bytes32 id,) = _note(alice, _margNote(T.Side.Buy, 11_000, 1, "+10%"), 10 ether);
        _buy(bob, 1_500_000 ether);
        uint256 end = hook.horizonEnd(id);
        uint256 cap = hook.OBS_MAX();
        for (uint256 i = 0; i < cap; ++i) {
            vm.warp(end + i * 5 minutes);
            vm.roll(vm.getBlockNumber() + hook.OBS_GAP_BLOCKS());
            hook.observe(id);
        }
        vm.warp(end + cap * 5 minutes);
        vm.roll(vm.getBlockNumber() + hook.OBS_GAP_BLOCKS());
        vm.expectRevert(MarginaliaHook.ObservationTooSoon.selector);
        hook.observe(id); // full, and no worse than the last entry
        // the market falls: a lower price is more adverse to a BUY call and replaces the last slot
        _sell(bob, token.balanceOf(bob));
        hook.observe(id);
        vm.warp(end + hook.SETTLE_WINDOW() + 1);
        hook.settle(id);
        // the series ends on the fallen price: the call settles on its minimum and is wrong
        assertEq(uint8(hook.noteOf(id).status), uint8(T.Status.Wrong));
    }

    function testAtTheCapAHigherReadingCannotLiftABuyCallsMinimum() public {
        (bytes32 id,) = _note(alice, _margNote(T.Side.Buy, 11_000, 1, "+10%"), 10 ether);
        uint256 end = hook.horizonEnd(id);
        uint256 cap = hook.OBS_MAX();
        for (uint256 i = 0; i < cap; ++i) {
            vm.warp(end + i * 5 minutes);
            vm.roll(vm.getBlockNumber() + hook.OBS_GAP_BLOCKS());
            hook.observe(id); // all at the post price: below the +10% target
        }
        // a late pump cannot be recorded over a full series of honest readings
        _buy(bob, 1_500_000 ether);
        assertGt(hook.margPriceInImd(), 1.1e18);
        vm.warp(end + cap * 5 minutes);
        vm.roll(vm.getBlockNumber() + hook.OBS_GAP_BLOCKS());
        vm.expectRevert(MarginaliaHook.ObservationTooSoon.selector);
        hook.observe(id);
        vm.warp(end + hook.SETTLE_WINDOW() + 1);
        hook.settle(id);
        assertEq(uint8(hook.noteOf(id).status), uint8(T.Status.Wrong));
    }
}
