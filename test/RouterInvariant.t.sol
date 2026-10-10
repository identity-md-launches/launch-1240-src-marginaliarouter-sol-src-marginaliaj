// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Fixture, TestSwapRouter} from "./helpers/Fixture.sol";
import {Marginalia} from "../src/Marginalia.sol";
import {MarginaliaHook} from "../src/MarginaliaHook.sol";
import {MarginaliaRouter} from "../src/MarginaliaRouter.sol";
import {MarginaliaTypes as T} from "../src/MarginaliaTypes.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @dev Drives the router with noted buys, noted sells, theses, checkpoints, plain swaps, clock moves and
/// stray callbacks from several actors. The router must never keep anything between transactions, and the
/// hook must count exactly the notes the router delivered.
contract RouterHandler is Test {
    MarginaliaRouter public router;
    MarginaliaHook public hook;
    IPoolManager public manager;
    Marginalia public token;
    MockERC20 public imd;
    TestSwapRouter public plain;
    PoolKey public key;
    PoolId public poolId;
    bool public margIs0;

    address[] public actors;
    uint256 public ghostNotes;
    uint256 public ghostAttempts;
    uint256 public ghostRefunds;
    uint256 public ghostMargOutTotal;
    uint256 public ghostImdSpentTotal;

    constructor(
        MarginaliaRouter r,
        MarginaliaHook h,
        IPoolManager m,
        Marginalia t,
        MockERC20 i,
        TestSwapRouter p,
        PoolKey memory k,
        PoolId id,
        bool margIs0_
    ) {
        router = r;
        hook = h;
        manager = m;
        token = t;
        imd = i;
        plain = p;
        key = k;
        poolId = id;
        margIs0 = margIs0_;
    }

    function addActor(address a) external {
        actors.push(a);
        vm.startPrank(a);
        imd.approve(address(router), type(uint256).max);
        token.approve(address(router), type(uint256).max);
        imd.approve(address(plain), type(uint256).max);
        token.approve(address(plain), type(uint256).max);
        vm.stopPrank();
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[bound(seed, 0, actors.length - 1)];
    }

    function _params(bool buy, uint32 targetBps, uint16 horizon)
        private
        view
        returns (T.NoteParams memory p)
    {
        p.x = address(token);
        p.venue = T.Venue(T.VenueKind.UniV4, PoolId.unwrap(poolId), address(0), false);
        p.side = buy ? T.Side.Buy : T.Side.Sell;
        p.targetBps = targetBps;
        p.horizonDays = horizon;
        p.class = uint8(T.Class.Declared);
        p.text = "handler note";
    }

    function noteBuy(uint256 seed, uint256 imdIn, uint32 targetBps, uint16 horizon) external {
        address who = _actor(seed);
        imdIn = bound(imdIn, 1, 2_000 ether);
        targetBps = uint32(bound(targetBps, 10_000, 60_000));
        horizon = uint16(bound(horizon, 0, 100));
        T.NoteParams memory p = _params(true, targetBps, horizon);
        uint256 before = token.balanceOf(who);
        uint256 imdBefore = imd.balanceOf(who);
        uint256 count = hook.noteCount();
        ghostAttempts += 1;
        vm.prank(who);
        try router.note(p, key, imdIn, 1, vm.getBlockTimestamp()) returns (uint256 received) {
            assertEq(hook.noteCount(), count + 1, "a noted buy did not post exactly one note");
            assertGt(received, 0);
            uint256 spent = imdBefore - imd.balanceOf(who);
            assertLe(spent, imdIn, "author charged more than offered");
            if (spent < imdIn) ghostRefunds += 1;
            // the deposit is held back by the hook inside the swap; what the router reports is what arrived
            T.Note memory n = hook.noteOf(bytes32(hook.noteCount()));
            assertEq(n.author, who);
            assertGt(n.deposit, 0, "a noted buy locked no deposit");
            assertEq(token.balanceOf(who) - before, received, "author received other than reported");
            ghostNotes += 1;
            ghostMargOutTotal += received;
            ghostImdSpentTotal += spent;
        } catch {}
    }

    function noteSell(uint256 seed, uint256 margIn, uint32 targetBps, uint16 horizon) external {
        address who = _actor(seed);
        margIn = bound(margIn, 1, 2_000 ether);
        targetBps = uint32(bound(targetBps, 0, 10_000));
        horizon = uint16(bound(horizon, 1, 90));
        T.NoteParams memory p = _params(false, targetBps == 0 ? 1 : targetBps, horizon);
        uint256 margBefore = token.balanceOf(who);
        uint256 count = hook.noteCount();
        ghostAttempts += 1;
        vm.prank(who);
        try router.sellWithNote(p, key, margIn, 1, vm.getBlockTimestamp()) returns (uint256 received) {
            assertEq(hook.noteCount(), count + 1, "a noted sell did not post exactly one note");
            assertGt(received, 0);
            assertLe(margBefore - token.balanceOf(who), margIn, "seller charged more MARG than offered");
            ghostNotes += 1;
        } catch {}
    }

    function thesis(uint256 seed, uint256 imdIn) external {
        address who = _actor(seed);
        imdIn = bound(imdIn, 1, 500 ether);
        T.NoteParams memory p = _params(true, 0, 0);
        p.text = "a long-form thesis with reasoning and citations";
        uint256 count = hook.noteCount();
        ghostAttempts += 1;
        vm.prank(who);
        try router.note(p, key, imdIn, 1, vm.getBlockTimestamp()) {
            assertEq(hook.noteCount(), count + 1, "a thesis did not post exactly one note");
            ghostNotes += 1;
        } catch {}
    }

    function checkpoint(uint256 seed) external {
        vm.prank(_actor(seed));
        router.checkpointVenue(_params(true, 11_000, 1), key);
    }

    function plainBuy(uint256 seed, uint256 imdIn) external {
        imdIn = bound(imdIn, 1, 5_000 ether);
        plain.swap(key, !margIs0, imdIn, _actor(seed));
    }

    function plainSell(uint256 seed, uint256 margIn) external {
        address who = _actor(seed);
        margIn = bound(margIn, 1, token.balanceOf(who) / 4 + 1);
        try plain.swap(key, margIs0, margIn, who) {} catch {}
    }

    function advance(uint256 secs) external {
        secs = bound(secs, 0, 90 minutes);
        vm.warp(vm.getBlockTimestamp() + secs);
        vm.roll(vm.getBlockNumber() + secs / 12 + 1);
    }

    /// @dev Nobody but the manager, and only with a job the router itself encoded, may enter the callback.
    function strayCallbacks(uint256 seed, bytes calldata data) external {
        address who = _actor(seed);
        vm.prank(who);
        try router.unlockCallback(data) {
            fail("stranger entered unlockCallback");
        } catch (bytes memory err) {
            assertEq(bytes4(err), MarginaliaRouter.UnauthorizedCallback.selector);
        }
        vm.prank(address(manager));
        try router.unlockCallback(data) {
            fail("manager entered unlockCallback without a job");
        } catch (bytes memory err) {
            assertEq(bytes4(err), MarginaliaRouter.UnauthorizedCallback.selector);
        }
        vm.prank(who);
        try router.uniswapV3SwapCallback(1, 1, data) {
            fail("stranger entered the v3 callback");
        } catch (bytes memory err) {
            assertEq(bytes4(err), MarginaliaRouter.UnauthorizedCallback.selector);
        }
    }
}

/// forge-config: default.invariant.runs = 48
/// forge-config: default.invariant.depth = 40
contract RouterInvariantTest is Fixture {
    RouterHandler private handler;
    uint256 private notesAtStart;

    function setUp() public {
        _setup();
        handler = new RouterHandler(router, hook, manager, token, imd, plain, key, poolId, margIs0);
        address[3] memory who = [alice, bob, carol];
        for (uint256 i; i < who.length; ++i) {
            imd.transfer(who[i], 2_000_000 ether);
            token.transfer(who[i], 200_000 ether);
            handler.addActor(who[i]);
        }
        notesAtStart = hook.noteCount();
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = RouterHandler.noteBuy.selector;
        selectors[1] = RouterHandler.noteSell.selector;
        selectors[2] = RouterHandler.thesis.selector;
        selectors[3] = RouterHandler.checkpoint.selector;
        selectors[4] = RouterHandler.plainBuy.selector;
        selectors[5] = RouterHandler.plainSell.selector;
        selectors[6] = RouterHandler.advance.selector;
        selectors[7] = RouterHandler.strayCallbacks.selector;
        selectors[8] = RouterHandler.noteBuy.selector; // weighted: the noted buy is the main path
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @dev The router is a pass-through: it never keeps IMD, MARG, claims or ETH between transactions.
    function invariant_routerKeepsNothing() public view {
        assertEq(imd.balanceOf(address(router)), 0, "router kept IMD");
        assertEq(token.balanceOf(address(router)), 0, "router kept MARG");
        assertEq(_claims(address(router), address(imd)), 0, "router kept IMD claims");
        assertEq(_claims(address(router), address(token)), 0, "router kept MARG claims");
        assertEq(address(router).balance, 0, "router kept ETH");
    }

    /// @dev Exactly the notes the router delivered exist: plain swaps and failed attempts post nothing.
    function invariant_everyNoteCameThroughTheRouter() public view {
        assertEq(hook.noteCount(), notesAtStart + handler.ghostNotes());
    }

    /// @dev The one-shot init binding never moves.
    function invariant_bindingsPinned() public view {
        assertEq(address(router.hook()), address(hook));
        assertEq(address(router.manager()), address(manager));
    }

    /// @dev The manager's ERC-20 holdings always back the claims the hook holds (the deposits and pots the
    /// router's notes created) and the pool's own reserves can never be drawn below them.
    function invariant_managerBacksTheHooksClaims() public view {
        assertGe(imd.balanceOf(address(manager)), _claims(address(hook), address(imd)));
        assertGe(token.balanceOf(address(manager)), _claims(address(hook), address(token)));
    }
}
