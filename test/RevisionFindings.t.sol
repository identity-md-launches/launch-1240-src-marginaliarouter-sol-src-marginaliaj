// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture, MockIntake, LiquidityHelper} from "./helpers/Fixture.sol";
import {MarginaliaHook} from "../src/MarginaliaHook.sol";
import {MarginaliaJudge} from "../src/MarginaliaJudge.sol";
import {MarginaliaRouter} from "../src/MarginaliaRouter.sol";
import {MarginaliaPricer} from "../src/MarginaliaPricer.sol";
import {MarginaliaTypes as T} from "../src/MarginaliaTypes.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @dev A token whose owner can switch balanceOf off (finding 542fd714).
contract SwitchToken is ERC20 {
    bool public paused;

    constructor() ERC20("Switch", "SW") {
        _mint(msg.sender, 1_000_000 ether);
    }

    function setPaused(bool p) external {
        paused = p;
    }

    function balanceOf(address a) public view override returns (uint256) {
        require(!paused, "paused");
        return super.balanceOf(a);
    }
}

/// @dev A canonical-looking v3 pool with no liquidity (finding 6948a02b, v3 branch).
contract EmptyV3Pool {
    address public token0;
    address public token1;
    uint24 public fee = 3000;
    uint128 public liquidity;

    constructor(address a, address b) {
        (token0, token1) = a < b ? (a, b) : (b, a);
    }

    function setLiquidity(uint128 l) external {
        liquidity = l;
    }
}

contract V3FactoryMock {
    address public pool;

    function set(address p) external {
        pool = p;
    }

    function getPool(address, address, uint24) external view returns (address) {
        return pool;
    }
}

/// @title Regressions for the second review round, on the repository fixture.
contract RevisionFindingsTest is Fixture {
    using PoolIdLibrary for PoolKey;

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

    // ---------------------------------------------------------------- 4772e72b: zero prices are refused

    function testPricerRefusesAPriceThatRoundsToZeroInBothOrientations() public {
        MarginaliaPricer pricer = hook.pricer();
        vm.expectRevert(MarginaliaPricer.EmptyPool.selector);
        pricer.fromSqrt(TickMath.getSqrtPriceAtTick(-500_000), true);
        vm.expectRevert(MarginaliaPricer.EmptyPool.selector);
        pricer.fromSqrt(TickMath.getSqrtPriceAtTick(500_000), false);
        assertGt(pricer.fromSqrt(TickMath.getSqrtPriceAtTick(-400_000), true), 0);
        // 272fbe0d: sqrt no longer overflows at the top of the range.
        assertEq(pricer.sqrt(type(uint256).max), 340282366920938463463374607431768211455);
    }

    function testADustPricedV4VenueCannotBePostedOn() public {
        MockERC20 dust = new MockERC20("Dust", "DUST", 1e40);
        bool dust0 = address(dust) < address(imd);
        int24 tick = dust0 ? int24(-420_000) : int24(420_000);
        (address c0, address c1) = dust0 ? (address(dust), address(imd)) : (address(imd), address(dust));
        PoolKey memory k = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 3000, 60, IHooks(address(0)));
        manager.initialize(k, TickMath.getSqrtPriceAtTick(tick));
        dust.transfer(address(liquidity), 1e39);
        imd.transfer(address(liquidity), 1_000_000 ether);
        liquidity.add(k, tick - 6000, tick + 6000, 1e18);
        T.NoteParams memory p = _margNote(T.Side.Buy, 50_000, 1, "5x on dust");
        p.x = address(dust);
        p.venue = T.Venue(T.VenueKind.UniV4, PoolId.unwrap(k.toId()), address(0), false);
        vm.expectRevert(MarginaliaPricer.EmptyPool.selector);
        router.checkpointVenue(p, k);
        vm.prank(alice);
        vm.expectRevert();
        router.note(p, k, 1 ether, 1, block.timestamp + 1);
    }

    // ---------------------------------------------------------------- ce3d30ae: dust cannot void a SELL call

    function _sellCall() internal returns (bytes32 id) {
        vm.prank(alice);
        router.sellWithNote(_margNote(T.Side.Sell, 9000, 1, "-10%"), key, 2 ether, 1, block.timestamp + 1);
        id = bytes32(hook.noteCount());
        token.transfer(bob, 2_000_000 ether);
        _sell(bob, 1_500_000 ether); // the market falls: the call is right
        assertLt(hook.margPriceInImd(), 0.8e18);
    }

    function testAStrangersDustTransferDoesNotVoidASellCall() public {
        bytes32 id = _sellCall();
        token.transfer(alice, 1); // carol's wei
        _observeThree(id);
        hook.settle(id);
        assertEq(uint8(hook.noteOf(id).status), uint8(T.Status.Right));
        assertGt(_rec(alice).score, 0);
        assertEq(_rec(alice).broken, 0);
    }

    /// @dev Round 3 (finding 80c42ce7): the SELL hold rule is gone, because any balance-growth rule can be
    /// triggered by a stranger's transfer. A buy-back no longer voids a SELL call; it settles on price alone.
    function testABuyBackNoLongerVoidsASellCallItSettlesOnPrice() public {
        bytes32 id = _sellCall();
        uint256 postBalance = hook.noteOf(id).postBalance;
        token.transfer(alice, postBalance / 5 + 10 ether); // formerly "well past 10% and the deposit's worth"
        _observeThree(id);
        hook.settle(id);
        assertEq(uint8(hook.noteOf(id).status), uint8(T.Status.Right));
        assertEq(_rec(alice).broken, 0);
        assertGt(hook.noteOf(id).deposit, 0);
    }

    // ---------------------------------------------------------------- 7fa6bcfb: a squatter cannot own the series

    function testHonestObserverOverwritesAPumpObserveUnwindInTheNextBlock() public {
        (bytes32 id,) = _note(alice, _margNote(T.Side.Buy, 11_000, 1, "+10%"), 10 ether);
        uint256 end = hook.horizonEnd(id);
        for (uint256 i = 0; i < 3; ++i) {
            vm.warp(end + i * 40 minutes);
            vm.roll(vm.getBlockNumber() + 200);
            // alice, first in the block: pump, observe, unwind.
            uint256 got = _buy(alice, 600_000 ether);
            assertGt(hook.margPriceInImd(), 1.1e18);
            hook.observe(id);
            _sell(alice, got);
            assertLt(hook.margPriceInImd(), 1.1e18);
            // bob, next block, inside alice's 20-block gap: the honest reading replaces hers.
            vm.roll(vm.getBlockNumber() + 1);
            vm.prank(bob);
            hook.observe(id);
            // a second pump reading in the gap is less adverse than bob's and is refused.
            got = _buy(alice, 600_000 ether);
            vm.expectRevert(MarginaliaHook.ObservationTooSoon.selector);
            hook.observe(id);
            _sell(alice, got);
        }
        vm.warp(end + hook.SETTLE_WINDOW() + 1);
        hook.settle(id);
        assertEq(uint8(hook.noteOf(id).status), uint8(T.Status.Wrong));
    }

    // ---------------------------------------------------------------- 542fd714: a switched-off balanceOf is not held

    function testARevertingBalanceOfVoidsTheCallAsSoldNotAsNoData() public {
        SwitchToken sw = new SwitchToken();
        bool sw0 = address(sw) < address(imd);
        (address c0, address c1) = sw0 ? (address(sw), address(imd)) : (address(imd), address(sw));
        PoolKey memory k = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 3000, 60, IHooks(address(0)));
        manager.initialize(k, uint160(1 << 96));
        sw.transfer(address(liquidity), 1000 ether);
        imd.transfer(address(liquidity), 1000 ether);
        liquidity.add(k, -887_220, 887_220, 1e18);
        T.NoteParams memory p = _margNote(T.Side.Buy, 20_000, 1, "2x");
        p.x = address(sw);
        p.venue = T.Venue(T.VenueKind.UniV4, PoolId.unwrap(k.toId()), address(0), false);
        router.checkpointVenue(p, k);
        vm.warp(block.timestamp + 1 hours);
        vm.roll(block.number + 300);
        vm.prank(alice);
        router.note(p, k, 1 ether, 1, block.timestamp + 1);
        bytes32 id = bytes32(hook.noteCount());
        sw.setPaused(true); // the author switches the read off at the horizon
        _observeThree(id); // observers are not blocked
        hook.settle(id);
        assertEq(uint8(hook.noteOf(id).status), uint8(T.Status.VoidSold));
        assertEq(hook.noteOf(id).deposit, 0);
        assertEq(_rec(alice).broken, 1);
        // Round 3 (finding c7331916): a call priced off the launch pool books no score in either direction.
        assertEq(_rec(alice).score, 0);
    }

    // ---------------------------------------------------------------- 7539406d: theses past the judged cap are refused

    function testTheHundredAndTwentyFirstThesisOfAWeekIsRefusedBeforePayment() public {
        uint32 w = hook.week();
        T.NoteParams memory p = _margNote(T.Side.Buy, 0, 0, "thesis");
        for (uint256 i = 0; i < hook.MAX_WEEK_THESES(); ++i) {
            _note(bob, p, 1 ether);
        }
        assertEq(hook.thesesOfWeek(w).length, hook.MAX_WEEK_THESES());
        assertEq(hook.MAX_WEEK_THESES(), judge.MAX_JUDGED());
        uint256 before = imd.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert();
        router.note(p, key, 1 ether, 1, block.timestamp + 1);
        assertEq(imd.balanceOf(alice), before);
        assertEq(hook.thesesOfWeek(w).length, hook.MAX_WEEK_THESES());
    }

    // ---------------------------------------------------------------- f0aea555 / b5fc440f: judge request hygiene

    function _att(bytes32[] memory ranked) internal view returns (OracleAttestation.Attestation memory att) {
        att = OracleAttestation.Attestation({
            requestId: bytes32(uint256(0xabc)),
            chainId: block.chainid,
            questionHash: keccak256("q"),
            answerType: 5,
            answer: abi.encode(ranked),
            figure: 0,
            fromBlock: uint64(block.number - 100),
            toBlock: uint64(block.number),
            blockHash: bytes32(0),
            panelJobId: bytes32(uint256(0xdef)),
            panelSize: 7,
            quorum: 5,
            agreed: 6,
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp + 1 days)
        });
    }

    function _judgedWeek() internal returns (uint32 w, bytes32 tid, bytes32 reqId) {
        w = hook.week();
        (tid,) = _note(alice, _margNote(T.Side.Buy, 0, 0, "thesis"), 10 ether);
        T.NoteParams memory child = _margNote(T.Side.Buy, 11_000, 1, "child");
        child.parentId = tid;
        _note(alice, child, 10 ether);
        vm.prank(alice);
        hook.fundPot(20 ether);
        vm.warp((uint256(w) + 1) * 7 days + 1);
        reqId = judge.requestJudging(w);
    }

    function testSweepNeedsTheStaleRequestAbandonedAndALateAnswerIsThenRefused() public {
        (uint32 w, bytes32 tid, bytes32 reqId) = _judgedWeek();
        vm.expectRevert(MarginaliaJudge.AlreadyRequested.selector);
        judge.abandonRequest(w); // the panel still has time to answer
        vm.warp((uint256(w) + 1) * 7 days + hook.SWEEP_AFTER() + 1);
        assertFalse(judge.weekClosed(w)); // still deliverable: the pool must not be swept from under it
        vm.expectRevert(MarginaliaHook.NotOpen.selector);
        hook.sweep(2, w);
        judge.abandonRequest(w);
        assertTrue(judge.weekClosed(w));
        uint256 pool = hook.thesisPool(w);
        hook.sweep(2, w);
        assertEq(hook.thesisPool(w), 0);
        assertEq(hook.leaderboardPool(hook.week()), pool);
        bytes32[] memory ranked = new bytes32[](1);
        ranked[0] = tid;
        vm.prank(hook.INTAKE());
        vm.expectRevert(MarginaliaJudge.UnknownRequest.selector);
        judge.onOracleResult(reqId, _att(ranked), hex"01");
        assertFalse(judge.judgedSet(w));
    }

    function testAnAttestationAboutAnotherChainIsRefused() public {
        (uint32 w, bytes32 tid, bytes32 reqId) = _judgedWeek();
        bytes32[] memory ranked = new bytes32[](1);
        ranked[0] = tid;
        OracleAttestation.Attestation memory att = _att(ranked);
        att.chainId = block.chainid + 1;
        vm.prank(hook.INTAKE());
        vm.expectRevert(MarginaliaJudge.BadAnswer.selector);
        judge.onOracleResult(reqId, att, hex"01");
        att.chainId = block.chainid;
        vm.prank(hook.INTAKE());
        judge.onOracleResult(reqId, att, hex"01");
        assertTrue(judge.judgedSet(w));
    }

    // ---------------------------------------------------------------- 6948a02b (v3 branch): an empty v3 pool is no venue

    function testAnEmptyCanonicalV3PoolIsRefusedAsAVenue() public {
        EmptyV3Pool pool = new EmptyV3Pool(address(token), address(imd));
        V3FactoryMock factory = new V3FactoryMock();
        vm.etch(router.UNIV3_FACTORY(), address(factory).code);
        V3FactoryMock(router.UNIV3_FACTORY()).set(address(pool));
        T.NoteParams memory p = _margNote(T.Side.Buy, 20_000, 7, "v3");
        p.venue = T.Venue(T.VenueKind.UniV3, bytes32(uint256(uint160(address(pool)))), address(0), false);
        vm.expectRevert(MarginaliaRouter.BadVenue.selector);
        router.validateVenue(p, key);
        pool.setLiquidity(1);
        T.Venue memory v = router.validateVenue(p, key);
        assertEq(uint8(v.kind), uint8(T.VenueKind.UniV3));
    }
}
