// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./helpers/Fixture.sol";
import {MarginaliaHook} from "../src/MarginaliaHook.sol";
import {MarginaliaJudge} from "../src/MarginaliaJudge.sol";
import {MarginaliaPricer} from "../src/MarginaliaPricer.sol";
import {MarginaliaImpls} from "../src/MarginaliaImpls.sol";
import {MarginaliaTypes as T} from "../src/MarginaliaTypes.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";

contract AuditFindingsTest is Fixture {
    function setUp() public {
        _setup();
    }

    function _settle(bytes32 id) private {
        vm.warp(hook.horizonEnd(id));
        uint256 startBlock = block.number;
        uint256 startTs = block.timestamp;
        for (uint256 i; i < 3; ++i) {
            hook.observe(id);
            vm.roll(startBlock + 25 * (i + 1));
            vm.warp(startTs + 31 minutes * (i + 1));
        }
        vm.warp(hook.horizonEnd(id) + hook.SETTLE_WINDOW() + 1);
        hook.settle(id);
    }

    function testSameBlockDumpPostUnwindDoesNotWinBuy() public {
        uint256 beforePrice = hook.margPriceInImd();
        token.transfer(bob, 2_000_000 ether);
        uint256 proceeds = _sell(bob, 2_000_000 ether);
        // An attacker also cannot overwrite the earlier honest checkpoint in the posting block.
        router.checkpointVenue(_margNote(T.Side.Buy, 11_000, 1, "checkpoint"), key);
        (bytes32 id,) = _note(alice, _margNote(T.Side.Buy, 11_000, 1, "+10%"), 10 ether);
        _buy(bob, proceeds);
        assertLt(hook.margPriceInImd(), beforePrice, "market fell");
        _settle(id);
        assertEq(
            uint8(hook.noteOf(id).status),
            uint8(T.Status.Wrong),
            "a +10% call settled RIGHT on a market that fell"
        );
    }

    function testSameBlockPumpPostUnwindDoesNotWinSell() public {
        uint256 beforePrice = hook.margPriceInImd();
        uint256 received = _buy(bob, 2_000_000 ether);
        (bytes32 id,) = _note(alice, _margNote(T.Side.Sell, 9000, 1, "-10%"), 10 ether);
        _sell(bob, received);
        assertGt(hook.margPriceInImd(), beforePrice * 90 / 100);
        _settle(id);
        assertEq(uint8(hook.noteOf(id).status), uint8(T.Status.Wrong), "a -10% call won without a 10% fall");
    }

    function _request() private returns (uint32 w, bytes32 reqId, bytes32 thesis) {
        w = hook.week();
        (thesis,) = _note(alice, _margNote(T.Side.Buy, 0, 0, "thesis"), 10 ether);
        T.NoteParams memory child = _margNote(T.Side.Buy, 11_000, 1, "child");
        child.parentId = thesis;
        _note(alice, child, 10 ether);
        vm.prank(alice);
        hook.fundPot(20 ether);
        vm.warp(block.timestamp + 7 days);
        reqId = judge.requestJudging(w);
    }

    function _att(bytes32[] memory ranked) private view returns (OracleAttestation.Attestation memory a) {
        a.requestId = keccak256("audit attestation");
        a.chainId = block.chainid;
        a.answerType = 5;
        a.answer = abi.encode(ranked);
        a.panelSize = 7;
        a.quorum = 5;
        a.agreed = 6;
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 1 days);
    }

    function testUnpayableRankingRollsTheWholePoolForward() public {
        (uint32 w, bytes32 reqId,) = _request();
        bytes32[] memory ranked = new bytes32[](1);
        ranked[0] = bytes32(uint256(999));
        OracleAttestation.Attestation memory a = _att(ranked);
        vm.prank(hook.INTAKE());
        judge.onOracleResult(reqId, a, hex"01");
        uint256 pool = hook.thesisPool(w);
        uint256 current = hook.thesisPool(hook.week());
        judge.payJudged(w);
        assertTrue(judge.paid(w));
        assertEq(hook.thesisPool(w), 0);
        assertEq(hook.thesisPool(hook.week()), current + pool);
        vm.expectRevert(MarginaliaJudge.AlreadyPaid.selector);
        judge.payJudged(w);
    }

    function testLongRankingFitsIntakeStipend() public {
        (uint32 w, bytes32 reqId, bytes32 thesis) = _request();
        bytes32[] memory ranked = new bytes32[](120);
        for (uint256 i; i < ranked.length; ++i) {
            ranked[i] = bytes32(i + 1);
        }
        ranked[0] = thesis;
        OracleAttestation.Attestation memory a = _att(ranked);
        vm.prank(hook.INTAKE());
        (bool ok,) =
            address(judge).call{gas: 200_000}(abi.encodeCall(judge.onOracleResult, (reqId, a, hex"01")));
        assertTrue(ok, "ranking exhausted the Intake stipend");
        assertTrue(judge.judgedSet(w));
        assertEq(judge.judgedOf(w)[0], thesis);
    }

    function testEmptyV4ObservationIsRefused() public {
        T.NoteParams memory p = _margNote(T.Side.Buy, 11_000, 1, "empty after posting");
        (bytes32 id,) = _note(alice, p, 10 ether);
        liquidity.add(key, -6000, 6000, -int256(10_000_000 ether));
        vm.warp(hook.horizonEnd(id));
        vm.expectRevert(MarginaliaPricer.EmptyPool.selector);
        hook.observe(id);
        vm.warp(hook.horizonEnd(id) + hook.SETTLE_WINDOW() + 1);
        hook.settle(id);
        assertEq(uint8(hook.noteOf(id).status), uint8(T.Status.VoidNoData));
    }

    function testForfeitureConversionRejectsSameBlockDump() public {
        (bytes32 id,) = _note(alice, _margNote(T.Side.Buy, 11_000, 1, "retract"), 10 ether);
        vm.prank(alice);
        hook.retract(id, "retracted");
        uint256 pot = hook.potMarg();
        token.transfer(bob, 2_000_000 ether);
        _sell(bob, 2_000_000 ether);
        vm.expectRevert(MarginaliaHook.InvalidUnlock.selector);
        judge.convertForfeits();
        assertEq(hook.potMarg(), pot);
    }

    function testConversionAfterARealPriceFallNeedsAFreshMatureWindow() public {
        (bytes32 id,) = _note(alice, _margNote(T.Side.Buy, 11_000, 1, "retract"), 10 ether);
        vm.prank(alice);
        hook.retract(id, "retracted");
        token.transfer(bob, 2_000_000 ether);
        _sell(bob, 2_000_000 ether);
        uint256 nowTs = vm.getBlockTimestamp();
        uint256 nowBlock = vm.getBlockNumber();
        vm.warp(nowTs + 6 hours);
        vm.roll(nowBlock + 1800);
        vm.expectRevert(MarginaliaPricer.PriceHistoryUnavailable.selector);
        judge.convertForfeits();
        T.NoteParams memory p = _margNote(T.Side.Buy, 11_000, 1, "new market level");
        router.checkpointVenue(p, key);
        vm.expectRevert(MarginaliaPricer.PriceHistoryUnavailable.selector);
        judge.convertForfeits();
        vm.warp(nowTs + 7 hours);
        vm.roll(nowBlock + 2100);
        uint256 pot = hook.potMarg();
        uint256 floor = pot * hook.margPriceInImd() / 1e18 * 97 / 100;
        uint256 claims = _claims(address(hook), address(imd));
        uint256 out = judge.convertForfeits();
        assertGe(out, floor);
        assertEq(hook.potMarg(), 0);
        assertEq(_claims(address(hook), address(imd)), claims + out);
    }

    function testExpiredBaselineRejectsPostWithoutTakingFunds() public {
        uint256 nowTs = vm.getBlockTimestamp();
        vm.warp(nowTs + 6 hours);
        T.NoteParams memory p = _margNote(T.Side.Buy, 11_000, 1, "needs history");
        uint256 imdBefore = imd.balanceOf(alice);
        uint256 margBefore = token.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(); // PoolManager wraps the pricer error from the hook callback.
        router.note(p, key, 10 ether, 1, nowTs + 6 hours + 1);
        assertEq(imd.balanceOf(alice), imdBefore);
        assertEq(token.balanceOf(alice), margBefore);
        assertEq(hook.noteCount(), 0);
    }
}
