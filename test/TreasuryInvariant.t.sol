// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MarginaliaTreasury} from "../src/MarginaliaTreasury.sol";

/// @dev The hook's pot, reduced to what the treasury relies on: `imd()` and a `fundPot` that pulls exactly
/// what it is told from the caller (the real hook does the same before moving the IMD into claims).
contract PotHookMock {
    address public imd;
    uint256 public funded;
    uint256 public calls;

    constructor(address imd_) {
        imd = imd_;
    }

    function fundPot(uint256 amount) external {
        require(amount > 0, "PotTooSmall");
        IERC20(imd).transferFrom(msg.sender, address(this), amount);
        funded += amount;
        calls += 1;
    }
}

/// @dev Drives a treasury clone with gifts, clock moves, drips, re-initialisation and ETH, in random order.
/// Every success or failure of `drip` is checked against the rule on the spot; the invariants below check
/// the custody that must hold after any sequence.
contract TreasuryHandler is Test {
    MarginaliaTreasury public treasury;
    MockERC20 public imd;
    PotHookMock public hook;

    uint256 public ghostGifted;
    uint256 public ghostDripped;
    uint256 public ghostDrips;
    uint32 public ghostLastDay;
    uint256 public ghostLargestDripBps; // the largest drip as a share of the balance before it, in bps
    mapping(uint32 => bool) public dayDripped;

    constructor(MarginaliaTreasury t, MockERC20 token, PotHookMock h) {
        treasury = t;
        imd = token;
        hook = h;
    }

    function gift(uint256 amount) external {
        amount = bound(amount, 0, 1_000_000 ether);
        imd.mint(address(treasury), amount);
        ghostGifted += amount;
    }

    function advance(uint256 secs) external {
        secs = bound(secs, 0, 3 days);
        vm.warp(vm.getBlockTimestamp() + secs);
    }

    function drip(uint256 callerSeed) external {
        address caller = address(uint160(bound(callerSeed, 1, type(uint160).max)));
        uint32 day = uint32(vm.getBlockTimestamp() / 1 days);
        uint32 lastBefore = treasury.lastDripDay();
        uint256 balanceBefore = imd.balanceOf(address(treasury));
        uint256 hookBefore = imd.balanceOf(address(hook));
        uint256 expected = balanceBefore * treasury.DRIP_BPS() / 10_000;
        vm.prank(caller);
        try treasury.drip() {
            assertNotEq(day, lastBefore, "a second drip on the same day went through");
            assertFalse(dayDripped[day], "a day dripped twice");
            assertGt(expected, 0, "a zero drip went through");
            assertEq(
                imd.balanceOf(address(treasury)), balanceBefore - expected, "drip moved the wrong amount"
            );
            assertEq(imd.balanceOf(address(hook)) - hookBefore, expected, "the hook did not receive the drip");
            assertEq(treasury.lastDripDay(), day, "lastDripDay not stamped");
            assertEq(imd.allowance(address(treasury), address(hook)), 0, "allowance left dangling");
            uint256 bps = expected * 10_000 / balanceBefore;
            if (bps > ghostLargestDripBps) ghostLargestDripBps = bps;
            dayDripped[day] = true;
            ghostDripped += expected;
            ghostDrips += 1;
            ghostLastDay = day;
        } catch (bytes memory err) {
            bytes4 sel = bytes4(err);
            if (day == lastBefore) {
                assertEq(
                    sel, MarginaliaTreasury.AlreadyDripped.selector, "same-day drip failed for another reason"
                );
            } else {
                assertEq(
                    sel, MarginaliaTreasury.NothingToDrip.selector, "fresh-day drip failed for another reason"
                );
                assertEq(expected, 0, "a drip with something to drip was refused");
            }
            assertEq(imd.balanceOf(address(treasury)), balanceBefore, "a failed drip moved funds");
        }
    }

    function initAgain(address who, address newHook) external {
        vm.prank(who);
        try treasury.init(newHook) {
            fail("a live treasury accepted a second init");
        } catch (bytes memory err) {
            assertEq(bytes4(err), MarginaliaTreasury.AlreadyInitialised.selector);
        }
    }

    function sendEth(uint256 amount) external {
        amount = bound(amount, 1, 10 ether);
        vm.deal(address(this), amount);
        (bool ok,) = address(treasury).call{value: amount}("");
        assertFalse(ok, "the treasury accepted ETH");
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 48
contract TreasuryInvariantTest is Test {
    MarginaliaTreasury private treasury;
    MockERC20 private imd;
    PotHookMock private hook;
    TreasuryHandler private handler;

    function setUp() public {
        vm.warp(1_800_000_000);
        imd = new MockERC20("Identity.md", "IMD", 0);
        hook = new PotHookMock(address(imd));
        treasury = MarginaliaTreasury(Clones.clone(address(new MarginaliaTreasury())));
        vm.prank(address(hook));
        treasury.init(address(hook));
        handler = new TreasuryHandler(treasury, imd, hook);
        targetContract(address(handler));
    }

    /// @dev What the treasury holds is exactly what it was given less what it dripped: no other exit exists.
    function invariant_balanceIsGiftsMinusDrips() public view {
        assertEq(imd.balanceOf(address(treasury)), handler.ghostGifted() - handler.ghostDripped());
    }

    /// @dev Every dripped wei reached the hook's pot and nothing else did.
    function invariant_hookHoldsExactlyTheDrips() public view {
        assertEq(hook.funded(), handler.ghostDripped());
        assertEq(imd.balanceOf(address(hook)), handler.ghostDripped());
        assertEq(hook.calls(), handler.ghostDrips());
    }

    /// @dev No single drip ever exceeded 2% of the balance it was taken from.
    function invariant_dripNeverExceedsTwoPercent() public view {
        assertLe(handler.ghostLargestDripBps(), treasury.DRIP_BPS());
    }

    /// @dev The day stamp only moves forward, and only on a drip.
    function invariant_lastDripDayMatchesTheLastSuccessfulDrip() public view {
        assertEq(treasury.lastDripDay(), handler.ghostLastDay());
    }

    /// @dev The hook binding set by the one-shot init never changes; nobody can re-point the drip.
    function invariant_hookIsPinned() public view {
        assertEq(address(treasury.hook()), address(hook));
    }

    function invariant_holdsNoEth() public view {
        assertEq(address(treasury).balance, 0);
    }
}
