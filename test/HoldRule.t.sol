// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {Fixture} from "./helpers/Fixture.sol";
import {MarginaliaHook} from "../src/MarginaliaHook.sol";
import {MarginaliaTypes as T} from "../src/MarginaliaTypes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title The hold rule and observation-replacement rule at their exact boundaries.
/// @dev After the third review round a SELL call has no hold rule at all (finding 80c42ce7: any balance-growth
/// rule lets a stranger void a correct call with a gift), so it settles on price alone and its balance is
/// never an adverse reading; a BUY call must keep its post balance to the wei, and an unreadable balance counts
/// as not held. A more adverse reading replaces a slot inside the block gap or at the series cap. These tests
/// pin the one-wei edges of both rules and the paths they refuse.
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

    // ---------------------------------------------------------------- SELL: no hold rule in either direction

    function testASellAuthorWhoBuysBackTheirWholePostBalanceIsStillRight() public {
        // the author's own buy-back, not a stranger's gift: the rule is gone for everyone, not only for gifts
        bytes32 id = _sellCall();
        uint256 post = hook.noteOf(id).postBalance;
        _buy(alice, 20_000 ether);
        assertGt(token.balanceOf(alice), post + post / 10, "the buy-back is well past the old 10% line");
        _observeThree(id);
        hook.settle(id);
        assertEq(uint8(hook.noteOf(id).status), uint8(T.Status.Right));
        assertEq(_rec(alice).broken, 0);
        assertGt(hook.noteOf(id).deposit, 0, "a SELL call that was right keeps its deposit claimable");
    }

    function testASellAuthorMayDumpTheirWholeRemainingBalance() public {
        // no rule downwards either: selling the rest of X is consistent with a SELL call
        bytes32 id = _sellCall();
        _sell(alice, token.balanceOf(alice));
        assertEq(token.balanceOf(alice), 0);
        _observeThree(id);
        hook.settle(id);
        assertEq(uint8(hook.noteOf(id).status), uint8(T.Status.Right));
        assertEq(_rec(alice).broken, 0);
    }

    function testAWrongSellCallForfeitsWhateverTheBalanceDid() public {
        // price alone decides: flat market, so -10% did not happen, and a gift changes nothing about that
        vm.prank(alice);
        router.sellWithNote(_margNote(T.Side.Sell, 9000, 1, "-10%"), key, 2 ether, 1, block.timestamp + 1);
        bytes32 id = bytes32(hook.noteCount());
        token.transfer(alice, 1_000_000 ether);
        _observeThree(id);
        hook.settle(id);
        assertEq(uint8(hook.noteOf(id).status), uint8(T.Status.Wrong));
        assertEq(_rec(alice).broken, 0, "a wrong SELL call is wrong, never broken");
        assertEq(hook.noteOf(id).deposit, 0);
    }

    function testASellCallWithAnUnreadableBalanceStillSettlesOnPrice() public {
        // the sentinel (balanceOf reverted) voids a BUY call; a SELL call has no balance to keep
        bytes32 id = _sellCall();
        vm.mockCallRevert(address(token), abi.encodeWithSelector(IERC20.balanceOf.selector, alice), "");
        uint256 end = hook.horizonEnd(id);
        vm.warp(end);
        vm.recordLogs();
        hook.observe(id);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (,,, uint256 balance) = abi.decode(logs[logs.length - 1].data, (uint64, uint256, uint256, uint256));
        assertEq(balance, type(uint256).max, "the unverifiable sentinel is on record");
        vm.warp(end + 30 minutes);
        vm.roll(vm.getBlockNumber() + 150);
        hook.observe(id);
        vm.warp(end + 61 minutes);
        vm.roll(vm.getBlockNumber() + 155);
        hook.observe(id);
        vm.warp(end + hook.SETTLE_WINDOW() + 1);
        hook.settle(id);
        vm.clearMockedCalls();
        assertEq(uint8(hook.noteOf(id).status), uint8(T.Status.Right));
        assertEq(_rec(alice).broken, 0);
    }

    function testABuyCallWithAnUnreadableBalanceIsVoidSold() public {
        // the same sentinel against a BUY call that is right on price: not held
        (bytes32 id,) = _note(alice, _margNote(T.Side.Buy, 11_000, 1, "+10%"), 10 ether);
        _buy(bob, 1_500_000 ether);
        vm.mockCallRevert(address(token), abi.encodeWithSelector(IERC20.balanceOf.selector, alice), "");
        _observeThree(id);
        hook.settle(id);
        vm.clearMockedCalls();
        assertEq(uint8(hook.noteOf(id).status), uint8(T.Status.VoidSold));
        assertEq(_rec(alice).broken, 1);
    }

    function testASellCallsBalanceIsNeverAnAdverseReading() public {
        // inside the block gap only a worse PRICE replaces the slot for a SELL call; a balance jump of any
        // size is not more adverse and is refused, where the same jump used to void the call
        bytes32 id = _sellCall();
        uint256 end = hook.horizonEnd(id);
        vm.warp(end);
        hook.observe(id);
        vm.roll(vm.getBlockNumber() + 1);
        token.transfer(alice, 1_000_000 ether);
        vm.expectRevert(MarginaliaHook.ObservationTooSoon.selector);
        hook.observe(id);
        // a higher price IS more adverse to a SELL call and gets in, in the very same block
        _buy(bob, 100_000 ether);
        vm.expectEmit(true, false, false, false, address(hook));
        emit MarginaliaHook.Observed(id, 0, 0, 0, 0);
        hook.observe(id);
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
