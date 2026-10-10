// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {Fixture} from "./helpers/Fixture.sol";
import {MarginaliaTreasury} from "../src/MarginaliaTreasury.sol";
import {MarginaliaJudge} from "../src/MarginaliaJudge.sol";
import {MarginaliaRouter} from "../src/MarginaliaRouter.sol";
import {MarginaliaTypes as T} from "../src/MarginaliaTypes.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../src/OracleAttestation.sol";
import {IIntake} from "../src/interfaces/IIntake.sol";

// ====================================================================== treasury

contract PotHookStub {
    address public imd;
    uint256 public funded;

    constructor(address imd_) {
        imd = imd_;
    }

    function fundPot(uint256 amount) external {
        require(amount > 0, "PotTooSmall");
        IERC20(imd).transferFrom(msg.sender, address(this), amount);
        funded += amount;
    }
}

contract TreasuryFailuresTest is Test {
    MarginaliaTreasury private treasury;
    MockERC20 private imd;
    PotHookStub private hook;

    function setUp() public {
        vm.warp(1_800_000_000);
        imd = new MockERC20("IMD", "IMD", 1_000_000 ether);
        hook = new PotHookStub(address(imd));
        treasury = MarginaliaTreasury(Clones.clone(address(new MarginaliaTreasury())));
        vm.prank(address(hook));
        treasury.init(address(hook));
    }

    function testDripWithNothingHeldReverts() public {
        vm.expectRevert(MarginaliaTreasury.NothingToDrip.selector);
        treasury.drip();
        assertEq(treasury.lastDripDay(), 0, "a failed drip stamped the day");
    }

    function testDripOfDustRoundsToZeroAndReverts() public {
        imd.transfer(address(treasury), 49); // 2% of 49 wei is 0
        vm.expectRevert(MarginaliaTreasury.NothingToDrip.selector);
        treasury.drip();
        imd.transfer(address(treasury), 1); // 2% of 50 wei is 1
        treasury.drip();
        assertEq(hook.funded(), 1);
        assertEq(imd.balanceOf(address(treasury)), 49);
    }

    function testSecondDripOnTheSameDayRevertsAndTheNextDayWorks() public {
        imd.transfer(address(treasury), 1000 ether);
        treasury.drip();
        assertEq(hook.funded(), 20 ether);
        vm.expectRevert(MarginaliaTreasury.AlreadyDripped.selector);
        treasury.drip();
        // a second gift the same day does not reopen the day
        imd.transfer(address(treasury), 1000 ether);
        vm.expectRevert(MarginaliaTreasury.AlreadyDripped.selector);
        treasury.drip();
        // the last second of the day is still the same day; the first second of the next is not
        uint256 nextDay = (vm.getBlockTimestamp() / 1 days + 1) * 1 days;
        vm.warp(nextDay - 1);
        vm.expectRevert(MarginaliaTreasury.AlreadyDripped.selector);
        treasury.drip();
        vm.warp(nextDay);
        treasury.drip();
        assertEq(hook.funded(), 20 ether + 1980 ether * 200 / 10_000);
    }

    function testDripIsPermissionlessAndCompounds() public {
        imd.transfer(address(treasury), 100 ether);
        uint256 held = 100 ether;
        for (uint256 i; i < 5; ++i) {
            vm.warp(vm.getBlockTimestamp() + 1 days);
            vm.prank(address(uint160(0x1000 + i)));
            treasury.drip();
            held -= held * 200 / 10_000;
            assertEq(imd.balanceOf(address(treasury)), held);
        }
        assertEq(hook.funded() + held, 100 ether);
    }

    function testTreasuryRefusesEth() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(treasury).call{value: 1}("");
        assertFalse(ok);
        (ok,) = address(treasury).call{value: 1}(abi.encodeCall(MarginaliaTreasury.drip, ()));
        assertFalse(ok, "a payable path exists");
    }

    function testNoWithdrawOrAdminSurface() public {
        imd.transfer(address(treasury), 1000 ether);
        bytes[8] memory calls = [
            abi.encodeWithSignature("withdraw()"),
            abi.encodeWithSignature("withdraw(uint256)", 1),
            abi.encodeWithSignature("withdraw(address,uint256)", address(this), 1),
            abi.encodeWithSignature("rescue(address)", address(imd)),
            abi.encodeWithSignature("sweep(address,address)", address(imd), address(this)),
            abi.encodeWithSignature("setHook(address)", address(this)),
            abi.encodeWithSignature("transferOwnership(address)", address(this)),
            abi.encodeWithSignature("pause()")
        ];
        for (uint256 i; i < calls.length; ++i) {
            (bool ok,) = address(treasury).call(calls[i]);
            assertFalse(ok, "an admin selector answered");
        }
        assertEq(imd.balanceOf(address(treasury)), 1000 ether);
    }

    function testInitRefusesTheZeroHook() public {
        MarginaliaTreasury fresh = MarginaliaTreasury(Clones.clone(address(new MarginaliaTreasury())));
        vm.prank(address(0));
        vm.expectRevert(bytes("configuration required"));
        fresh.init(address(0));
        assertEq(address(fresh.hook()), address(0), "a refused init left state behind");
    }

    function testInitOnlyByTheNamedHookAndOnlyOnce() public {
        MarginaliaTreasury fresh = MarginaliaTreasury(Clones.clone(address(new MarginaliaTreasury())));
        address other = makeAddr("other hook");
        // the named hook must be the caller, not just any contract
        vm.expectRevert(MarginaliaTreasury.OnlyHook.selector);
        fresh.init(other);
        vm.prank(other);
        fresh.init(other);
        vm.prank(other);
        vm.expectRevert(MarginaliaTreasury.AlreadyInitialised.selector);
        fresh.init(other);
    }

    function testDripFailsWhenTheHookCannotTakeTheFunds() public {
        // a hook that refuses the pull: the drip reverts whole and keeps the day open
        MarginaliaTreasury fresh = MarginaliaTreasury(Clones.clone(address(new MarginaliaTreasury())));
        address dead = makeAddr("hook with no code");
        vm.prank(dead);
        fresh.init(dead);
        imd.transfer(address(fresh), 100 ether);
        vm.expectRevert();
        fresh.drip();
        assertEq(fresh.lastDripDay(), 0);
        assertEq(imd.balanceOf(address(fresh)), 100 ether);
    }
}

// ====================================================================== judge

contract JudgeHookMock {
    struct Meta {
        address author;
        uint32 week;
        bool thesis;
        bool hasChild;
    }

    address public imd;
    uint32 public week = 100;
    uint256 public potMarg;
    uint256 public draws;
    uint256 public lastDraw;
    bool public lastRetry;
    uint256 public sells;
    uint256 public payments;
    bytes32[3] public winners;
    mapping(uint32 => bytes32[]) private theses;
    mapping(bytes32 => Meta) private metas;

    constructor(address imd_) {
        imd = imd_;
    }

    function setWeek(uint32 w) external {
        week = w;
    }

    function setPotMarg(uint256 m) external {
        potMarg = m;
    }

    function addThesis(uint32 w, bytes32 id, address author, bool hasChild) external {
        theses[w].push(id);
        metas[id] = Meta(author, w, true, hasChild);
    }

    function setMeta(bytes32 id, address author, uint32 w, bool thesis, bool hasChild) external {
        metas[id] = Meta(author, w, thesis, hasChild);
    }

    function thesesOfWeek(uint32 w) external view returns (bytes32[] memory) {
        return theses[w];
    }

    function noteMeta(bytes32 id) external view returns (address, uint32, bool, bool) {
        Meta memory m = metas[id];
        return (m.author, m.week, m.thesis, m.hasChild);
    }

    function thesisPool(uint32) external pure returns (uint256) {
        return 100 ether;
    }

    function JUDGE_PRICE() external pure returns (uint256) {
        return 0.5 ether;
    }

    function drawForJudging(uint32, uint256 amount, bool retry) external {
        draws += 1;
        lastDraw = amount;
        lastRetry = retry;
        IERC20(imd).transfer(msg.sender, amount);
    }

    /// @dev The most MARG one sale may absorb (the hook's slippage floor); zero means unlimited.
    uint256 public maxSell;

    function setMaxSell(uint256 m) external {
        maxSell = m;
    }

    function sellPotMarg(uint256 amount) external returns (uint256) {
        require(amount > 0 && amount <= potMarg, "PotTooSmall");
        if (maxSell != 0 && amount > maxSell) revert("floor");
        potMarg -= amount;
        sells += 1;
        return amount * 2;
    }

    function payJudged(uint32, bytes32[3] calldata top) external {
        winners = top;
        payments += 1;
    }
}

contract ConfigurableIntake is IIntake {
    uint256 public price = 0.5 ether;
    bytes32 public fixedId;
    uint256 public requests;
    address public target;
    bytes4 public selector;
    bytes public lastBody;
    uint256 public lastAmount;

    function setPrice(uint256 p) external {
        price = p;
    }

    function setFixedId(bytes32 id) external {
        fixedId = id;
    }

    function priceOf(bytes32, address) external view returns (uint256) {
        return price;
    }

    function request(bytes32, bytes calldata body, Callback calldata callback, address asset, uint256 amount)
        external
        payable
        returns (bytes32)
    {
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        target = callback.target;
        selector = callback.selector;
        lastBody = body;
        lastAmount = amount;
        requests += 1;
        return fixedId != bytes32(0) ? fixedId : bytes32(requests);
    }

    function deliver(bytes32 requestId, OracleAttestation.Attestation calldata a, bytes calldata signature)
        external
        returns (bool ok, bytes memory result)
    {
        return target.call(abi.encodeCall(MarginaliaJudge.onOracleResult, (requestId, a, signature)));
    }
}

contract JudgeFailuresTest is Test {
    uint256 private constant SIGNER_KEY = 0xA11CE;
    address private signer;
    MarginaliaJudge private judge;
    JudgeHookMock private hook;
    ConfigurableIntake private intake;
    MockERC20 private imd;
    address private author = makeAddr("author");

    /// @dev The stub's current week is 100; the clock sits one day into it so `weekClosed` sees a real calendar.
    uint256 private constant NOW = uint256(100) * 7 days + 1 days;

    function setUp() public {
        vm.warp(NOW);
        signer = vm.addr(SIGNER_KEY);
        imd = new MockERC20("IMD", "IMD", 100 ether);
        hook = new JudgeHookMock(address(imd));
        imd.transfer(address(hook), 100 ether);
        intake = new ConfigurableIntake();
        judge = MarginaliaJudge(Clones.clone(address(new MarginaliaJudge())));
        vm.prank(address(hook));
        judge.init(address(hook), address(intake), bytes32("oracle.request@oracle-1"), signer);
        for (uint256 i = 1; i <= 3; ++i) {
            hook.addThesis(99, bytes32(i), author, true);
        }
    }

    function _att(bytes32[] memory ids) private view returns (OracleAttestation.Attestation memory a) {
        a.requestId = keccak256(abi.encode("signed", ids.length));
        a.chainId = block.chainid;
        a.questionHash = keccak256("rank theses");
        a.answerType = OracleAttestation.ANSWER_BYTES32_LIST;
        a.answer = abi.encode(ids);
        a.panelSize = 7;
        a.quorum = 5;
        a.agreed = 5;
        a.issuedAt = uint64(vm.getBlockTimestamp());
        a.expiresAt = uint64(vm.getBlockTimestamp() + 1 days);
    }

    function _ids(uint256 n) private pure returns (bytes32[] memory ids) {
        ids = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            ids[i] = bytes32(i + 1);
        }
    }

    function _sign(OracleAttestation.Attestation memory a) private view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, judge.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }

    function _contains(bytes memory haystack, bytes memory needle) private pure returns (bool) {
        if (needle.length > haystack.length) return false;
        for (uint256 i; i + needle.length <= haystack.length; ++i) {
            bool hit = true;
            for (uint256 j; j < needle.length && hit; ++j) {
                if (haystack[i + j] != needle[j]) hit = false;
            }
            if (hit) return true;
        }
        return false;
    }

    // ---------------------------------------------------------------- init

    function testInitRequiresEveryConfigurationValue() public {
        MarginaliaJudge fresh = MarginaliaJudge(Clones.clone(address(new MarginaliaJudge())));
        vm.expectRevert(bytes("configuration required"));
        fresh.init(address(this), address(0), bytes32("a"), signer);
        vm.expectRevert(bytes("configuration required"));
        fresh.init(address(this), address(intake), bytes32(0), signer);
        vm.expectRevert(OracleAttestationConsumer.ZeroSigner.selector);
        fresh.init(address(this), address(intake), bytes32("a"), address(0));
        assertEq(address(fresh.hook()), address(0), "a refused init left state behind");
        assertEq(fresh.oracleSigner(), address(0));
    }

    function testImplementationHasAPlaceholderSignerAndCannotBeConfigured() public {
        MarginaliaJudge impl = new MarginaliaJudge();
        assertEq(address(impl.hook()), address(1));
        assertEq(impl.oracleSigner(), address(1));
        vm.prank(address(1));
        vm.expectRevert(MarginaliaJudge.AlreadyInitialised.selector);
        impl.init(address(1), address(intake), bytes32("a"), signer);
    }

    // ---------------------------------------------------------------- requestJudging

    function testCurrentAndFutureWeeksCannotBeRequested() public {
        vm.expectRevert(MarginaliaJudge.DayNotOver.selector);
        judge.requestJudging(100);
        vm.expectRevert(MarginaliaJudge.DayNotOver.selector);
        judge.requestJudging(101);
        assertEq(hook.draws(), 0);
    }

    function testWeekWithoutEligibleThesesCannotBeRequested() public {
        // 98 has no theses at all; 97 has one with no child call
        hook.addThesis(97, bytes32(uint256(77)), author, false);
        vm.expectRevert(MarginaliaJudge.NoNotes.selector);
        judge.requestJudging(98);
        vm.expectRevert(MarginaliaJudge.NoNotes.selector);
        judge.requestJudging(97);
        assertEq(hook.draws(), 0, "a refused request drew from the pool");
    }

    function testZeroAndExcessiveOraclePricesAreRefused() public {
        intake.setPrice(0);
        vm.expectRevert(MarginaliaJudge.PriceMismatch.selector);
        judge.requestJudging(99);
        intake.setPrice(judge.MAX_PRICE() + 1);
        vm.expectRevert(MarginaliaJudge.PriceMismatch.selector);
        judge.requestJudging(99);
        assertEq(hook.draws(), 0);
        intake.setPrice(judge.MAX_PRICE());
        judge.requestJudging(99);
        assertEq(hook.lastDraw(), judge.MAX_PRICE());
        assertEq(intake.lastAmount(), judge.MAX_PRICE());
        assertEq(imd.allowance(address(judge), address(intake)), 0, "allowance left after the request");
    }

    function testRequestDrawsExactlyThePriceAndKeepsNothing() public {
        judge.requestJudging(99);
        assertEq(hook.lastDraw(), 0.5 ether);
        assertFalse(hook.lastRetry());
        assertEq(imd.balanceOf(address(judge)), 0, "the judge kept IMD");
        assertEq(imd.balanceOf(address(intake)), 0.5 ether);
        assertEq(intake.target(), address(judge));
        assertEq(intake.selector(), MarginaliaJudge.onOracleResult.selector);
    }

    function testRepeatRequestBeforeTheDeadlineIsRefused() public {
        judge.requestJudging(99);
        vm.expectRevert(MarginaliaJudge.AlreadyRequested.selector);
        judge.requestJudging(99);
        vm.warp(vm.getBlockTimestamp() + judge.ANSWER_DEADLINE() - 1);
        vm.expectRevert(MarginaliaJudge.AlreadyRequested.selector);
        judge.requestJudging(99);
        vm.warp(vm.getBlockTimestamp() + 1);
        judge.requestJudging(99);
        assertTrue(hook.lastRetry(), "the retry was drawn as a first request");
        assertEq(hook.draws(), 2);
    }

    function testJudgedWeekCannotBeRequestedAgainEvenAfterTheDeadline() public {
        bytes32 req = judge.requestJudging(99);
        OracleAttestation.Attestation memory a = _att(_ids(3));
        (bool ok,) = intake.deliver(req, a, _sign(a));
        assertTrue(ok);
        vm.warp(vm.getBlockTimestamp() + judge.ANSWER_DEADLINE() + 1);
        vm.expectRevert(MarginaliaJudge.AlreadyRequested.selector);
        judge.requestJudging(99);
    }

    function testIntakeReturningAnIdAlreadyPendingIsRefused() public {
        for (uint256 i = 1; i <= 3; ++i) {
            hook.addThesis(98, bytes32(i + 10), author, true);
        }
        intake.setFixedId(keccak256("same id twice"));
        judge.requestJudging(99);
        vm.expectRevert(MarginaliaJudge.AlreadyRequested.selector);
        judge.requestJudging(98);
        assertEq(judge.requestOf(98), bytes32(0));
    }

    function testQuestionBodyNamesTheConsumerChainAndEligibleIdsOnly() public {
        hook.addThesis(99, bytes32(uint256(0xabc)), author, false); // no child: not eligible
        bytes memory body = bytes(judge.questionBody(99));
        assertTrue(
            _contains(body, bytes(vm.toString(abi.encodePacked(address(judge))))), "verifyingContract missing"
        );
        assertTrue(_contains(body, bytes('"chainId":31337')), "chain id missing");
        assertTrue(_contains(body, bytes('"panelSize":7,"quorum":5')), "panel terms missing");
        assertTrue(_contains(body, bytes('"head":3')), "head missing");
        assertTrue(_contains(body, bytes(vm.toString(bytes32(uint256(1))))), "eligible id missing");
        assertFalse(_contains(body, bytes(vm.toString(bytes32(uint256(0xabc))))), "ineligible id listed");
        assertLe(body.length, 16_384, "body over the Intake's limit");
    }

    function testEligibleThesesAreCappedAtTheJudgedMaximum() public {
        for (uint256 i; i < 130; ++i) {
            hook.addThesis(98, bytes32(uint256(1000 + i)), author, true);
        }
        bytes32[] memory out = judge.eligibleTheses(98);
        assertEq(out.length, judge.MAX_JUDGED());
        assertEq(out[0], bytes32(uint256(1000)));
        assertEq(out[119], bytes32(uint256(1119)));
        assertLe(bytes(judge.questionBody(98)).length, 16_384, "capped body still over the Intake's limit");
    }

    // ---------------------------------------------------------------- onOracleResult

    function testAnswerForAWeekAlreadyJudgedIsRefused() public {
        bytes32 req = judge.requestJudging(99);
        OracleAttestation.Attestation memory a = _att(_ids(3));
        (bool ok,) = intake.deliver(req, a, _sign(a));
        assertTrue(ok);
        // the same request again: the pending slot is gone
        (ok,) = intake.deliver(req, a, _sign(a));
        assertFalse(ok);
        // a fresh attestation for the same request id: still refused
        a.requestId = keccak256("another signed id");
        (ok,) = intake.deliver(req, a, _sign(a));
        assertFalse(ok);
    }

    function testAnswerSignedByAnotherKeyIsRefused() public {
        bytes32 req = judge.requestJudging(99);
        OracleAttestation.Attestation memory a = _att(_ids(3));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xB0B, judge.attestationDigest(a));
        (bool ok, bytes memory err) = intake.deliver(req, a, abi.encodePacked(r, s, v));
        assertFalse(ok);
        assertEq(bytes4(err), OracleAttestationConsumer.BadSignature.selector);
        assertFalse(judge.judgedSet(99));
    }

    function testAnswerSignedForAnotherConsumerIsRefused() public {
        bytes32 req = judge.requestJudging(99);
        OracleAttestation.Attestation memory a = _att(_ids(3));
        MarginaliaJudge other = MarginaliaJudge(Clones.clone(address(new MarginaliaJudge())));
        vm.prank(address(hook));
        other.init(address(hook), address(intake), bytes32("oracle.request@oracle-1"), signer);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, other.attestationDigest(a));
        (bool ok, bytes memory err) = intake.deliver(req, a, abi.encodePacked(r, s, v));
        assertFalse(ok);
        assertEq(bytes4(err), OracleAttestationConsumer.BadSignature.selector);
    }

    function testAnswerAtTheExactExpiryStillCountsAndOneSecondLaterDoesNot() public {
        bytes32 req = judge.requestJudging(99);
        OracleAttestation.Attestation memory a = _att(_ids(3));
        vm.warp(a.expiresAt + 1);
        (bool ok, bytes memory err) = intake.deliver(req, a, _sign(a));
        assertFalse(ok);
        assertEq(bytes4(err), OracleAttestationConsumer.AttestationExpired.selector);
        vm.warp(a.expiresAt);
        (ok,) = intake.deliver(req, a, _sign(a));
        assertTrue(ok);
    }

    function testMalformedAnswerBytesAreRefused() public {
        bytes32 req = judge.requestJudging(99);
        OracleAttestation.Attestation memory a = _att(_ids(3));
        a.answer = hex"deadbeef";
        (bool ok,) = intake.deliver(req, a, _sign(a));
        assertFalse(ok);
        assertFalse(judge.judgedSet(99));
    }

    function testOnlyTheHeadOfThreeIsStoredAndTheTailNeverPromotes() public {
        bytes32 req = judge.requestJudging(99);
        bytes32[] memory ids = new bytes32[](5);
        ids[0] = bytes32(uint256(55)); // not a thesis of the week
        ids[1] = bytes32(uint256(1));
        ids[2] = bytes32(uint256(1)); // duplicate
        ids[3] = bytes32(uint256(2)); // beyond the requested head
        ids[4] = bytes32(uint256(3));
        OracleAttestation.Attestation memory a = _att(ids);
        (bool ok,) = intake.deliver(req, a, _sign(a));
        assertTrue(ok);
        bytes32[3] memory top = judge.judgedOf(99);
        assertEq(top[0], bytes32(uint256(1)));
        assertEq(top[1], bytes32(0));
        assertEq(top[2], bytes32(0));
    }

    function testJudgedOfFiltersWrongWeekShortFormAndChildlessIds() public {
        bytes32 req = judge.requestJudging(99);
        hook.setMeta(bytes32(uint256(1)), author, 98, true, true); // another week
        hook.setMeta(bytes32(uint256(2)), author, 99, false, true); // a short-form call
        hook.setMeta(bytes32(uint256(3)), author, 99, true, false); // a thesis nobody acted on
        OracleAttestation.Attestation memory a = _att(_ids(3));
        (bool ok,) = intake.deliver(req, a, _sign(a));
        assertTrue(ok);
        bytes32[3] memory top = judge.judgedOf(99);
        assertEq(top[0], bytes32(0));
        assertEq(top[1], bytes32(0));
        assertEq(top[2], bytes32(0));
        judge.payJudged(99);
        assertEq(hook.winners(0), bytes32(0));
        assertEq(hook.payments(), 1);
    }

    // ---------------------------------------------------------------- payJudged / convertForfeits / weekClosed

    function testPayBeforeAnAnswerReverts() public {
        vm.expectRevert(MarginaliaJudge.NotJudged.selector);
        judge.payJudged(99);
        judge.requestJudging(99);
        vm.expectRevert(MarginaliaJudge.NotJudged.selector);
        judge.payJudged(99);
        assertEq(hook.payments(), 0);
    }

    function testPayIsPermissionlessAndOnce() public {
        bytes32 req = judge.requestJudging(99);
        OracleAttestation.Attestation memory a = _att(_ids(3));
        (bool ok,) = intake.deliver(req, a, _sign(a));
        assertTrue(ok);
        vm.prank(makeAddr("anyone"));
        judge.payJudged(99);
        assertEq(hook.winners(0), bytes32(uint256(1)));
        assertEq(hook.winners(1), bytes32(uint256(2)));
        assertEq(hook.winners(2), bytes32(uint256(3)));
        vm.expectRevert(MarginaliaJudge.AlreadyPaid.selector);
        judge.payJudged(99);
        assertEq(hook.payments(), 1);
    }

    function testConvertForfeitsWithAnEmptyPotIsANoOp() public {
        assertEq(judge.convertForfeits(), 0);
        assertEq(hook.sells(), 0);
        hook.setPotMarg(5 ether);
        assertEq(judge.convertForfeits(), 10 ether);
        assertEq(hook.sells(), 1);
        assertEq(hook.potMarg(), 0);
        assertEq(judge.convertForfeits(), 0, "a drained pot was sold again");
    }

    function testWeekClosedStates() public {
        assertFalse(judge.weekClosed(100), "the current week is never closed");
        assertFalse(judge.weekClosed(101));
        assertTrue(judge.weekClosed(98), "no eligible theses closes a week at once");
        assertFalse(judge.weekClosed(99), "an unrequested week with theses stays open");
        bytes32 req = judge.requestJudging(99);
        assertFalse(judge.weekClosed(99), "pending within the deadline");
        vm.warp(vm.getBlockTimestamp() + judge.ANSWER_DEADLINE());
        assertFalse(judge.weekClosed(99), "unanswered past the deadline but inside 28 days: still retriable");
        vm.warp(uint256(100) * 7 days + 28 days);
        // revision f0aea555: time alone never closes a week whose request the Intake could still deliver
        assertFalse(judge.weekClosed(99), "28 days on, a deliverable request still holds the week open");
        judge.abandonRequest(99);
        assertTrue(judge.weekClosed(99), "abandoned and 28 days past the week's end: closed");
        // the abandoned id can no longer land
        OracleAttestation.Attestation memory a = _att(_ids(3));
        (bool ok, bytes memory err) = intake.deliver(req, a, _sign(a));
        assertFalse(ok);
        assertEq(bytes4(err), MarginaliaJudge.UnknownRequest.selector);
        // a retry reopens it, and a judged week is never closed: it is paid instead
        bytes32 again = judge.requestJudging(99);
        assertTrue(hook.lastRetry());
        assertFalse(judge.weekClosed(99), "a fresh request reopened the week");
        a = _att(_ids(3));
        (ok,) = intake.deliver(again, a, _sign(a));
        assertTrue(ok);
        assertFalse(judge.weekClosed(99));
        assertFalse(judge.weekClosed(99), "a judged week never closes");
    }

    // ---------------------------------------------------------------- abandonRequest

    function testAbandonNeedsALiveRequestPastItsDeadline() public {
        vm.expectRevert(MarginaliaJudge.UnknownRequest.selector);
        judge.abandonRequest(99); // never requested
        vm.expectRevert(MarginaliaJudge.UnknownRequest.selector);
        judge.abandonRequest(98); // no theses, never requestable
        bytes32 req = judge.requestJudging(99);
        vm.expectRevert(MarginaliaJudge.AlreadyRequested.selector);
        judge.abandonRequest(99); // the panel still has time
        vm.warp(vm.getBlockTimestamp() + judge.ANSWER_DEADLINE() - 1);
        vm.expectRevert(MarginaliaJudge.AlreadyRequested.selector);
        judge.abandonRequest(99);
        vm.warp(vm.getBlockTimestamp() + 1); // exactly the deadline: the request may be abandoned
        vm.expectEmit(true, true, false, true, address(judge));
        emit MarginaliaJudge.Abandoned(99, req);
        vm.prank(makeAddr("anyone"));
        judge.abandonRequest(99);
        assertEq(judge.requestOf(99), req, "abandoning keeps the record of what was asked");
        vm.expectRevert(MarginaliaJudge.UnknownRequest.selector);
        judge.abandonRequest(99); // already abandoned
    }

    function testAJudgedWeekCannotBeAbandoned() public {
        bytes32 req = judge.requestJudging(99);
        OracleAttestation.Attestation memory a = _att(_ids(3));
        (bool ok,) = intake.deliver(req, a, _sign(a));
        assertTrue(ok);
        vm.warp(vm.getBlockTimestamp() + judge.ANSWER_DEADLINE() + 1);
        // the delivery consumed the pending slot, so there is nothing to abandon and the week stays judged
        vm.expectRevert(MarginaliaJudge.UnknownRequest.selector);
        judge.abandonRequest(99);
        assertTrue(judge.judgedSet(99));
        assertFalse(judge.weekClosed(99));
    }

    function testAbandonTakesNothingAndTheRetryDrawsAgain() public {
        judge.requestJudging(99);
        vm.warp(vm.getBlockTimestamp() + judge.ANSWER_DEADLINE());
        uint256 judgeImd = imd.balanceOf(address(judge));
        uint256 intakeImd = imd.balanceOf(address(intake));
        judge.abandonRequest(99);
        assertEq(imd.balanceOf(address(judge)), judgeImd, "abandoning moved IMD");
        assertEq(imd.balanceOf(address(intake)), intakeImd, "abandoning refunded the Intake's price");
        assertEq(hook.draws(), 1);
        bytes32 again = judge.requestJudging(99);
        assertEq(hook.draws(), 2, "the retry did not draw");
        assertTrue(hook.lastRetry());
        assertEq(judge.requestOf(99), again);
        // the retried request is itself abandonable only after its own deadline
        vm.expectRevert(MarginaliaJudge.AlreadyRequested.selector);
        judge.abandonRequest(99);
    }

    // ---------------------------------------------------------------- convertForfeits tranches

    function testConvertSellsTheLargestHalvingThePoolAbsorbs() public {
        hook.setPotMarg(100 ether);
        hook.setMaxSell(30 ether); // 100 and 50 are refused, 25 sells
        assertEq(judge.convertForfeits(), 50 ether);
        assertEq(hook.sells(), 1, "more than one tranche sold in one call");
        assertEq(hook.potMarg(), 75 ether, "the rest of the pot stays for the next call");
        // the next call takes the next tranche that fits, never the refused larger ones
        assertEq(judge.convertForfeits(), 37.5 ether); // 75 refused, 37.5 refused, 18.75 sells
        assertEq(hook.potMarg(), 56.25 ether);
    }

    function testConvertTriesExactlyNineTranchesDownToOneTwoHundredFiftySixth() public {
        hook.setPotMarg(256);
        hook.setMaxSell(1); // the ninth and last tranche, pot / 256, is the only one that sells
        assertEq(judge.convertForfeits(), 2);
        assertEq(hook.sells(), 1);
        assertEq(hook.potMarg(), 255);
        // one halving further would be needed: the hook's last reason surfaces and nothing is sold
        hook.setPotMarg(512);
        hook.setMaxSell(1);
        vm.expectRevert(bytes("floor"));
        judge.convertForfeits();
        assertEq(hook.potMarg(), 512);
    }

    function testConvertNeverSellsMoreThanThePot() public {
        hook.setPotMarg(7);
        hook.setMaxSell(7);
        assertEq(judge.convertForfeits(), 14);
        assertEq(hook.potMarg(), 0);
        assertEq(judge.convertForfeits(), 0, "an empty pot was sold");
        assertEq(hook.sells(), 1);
    }
}

// ====================================================================== router

contract RouterFailuresTest is Fixture {
    using PoolIdLibrary for PoolKey;

    function setUp() public {
        _setup();
    }

    function testExpiredDeadlineTakesNothing() public {
        T.NoteParams memory p = _margNote(T.Side.Buy, 20_000, 7, "late");
        uint256 before = imd.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(MarginaliaRouter.Expired.selector);
        router.note(p, key, 10 ether, 1, vm.getBlockTimestamp() - 1);
        assertEq(imd.balanceOf(alice), before);
        // the deadline itself is still good
        vm.prank(alice);
        router.note(p, key, 10 ether, 1, vm.getBlockTimestamp());
    }

    function testZeroAndOversizedAmountsAreRefused() public {
        T.NoteParams memory p = _margNote(T.Side.Buy, 20_000, 7, "sizes");
        vm.startPrank(alice);
        vm.expectRevert(MarginaliaRouter.InvalidSwap.selector);
        router.note(p, key, 0, 1, vm.getBlockTimestamp());
        vm.expectRevert(MarginaliaRouter.InvalidSwap.selector);
        router.note(p, key, uint256(uint128(type(int128).max)) + 1, 1, vm.getBlockTimestamp());
        vm.expectRevert(MarginaliaRouter.InvalidSwap.selector);
        router.sellWithNote(p, key, 0, 1, vm.getBlockTimestamp());
        vm.stopPrank();
    }

    function testSlippageFloorRefundsEverything() public {
        T.NoteParams memory p = _margNote(T.Side.Buy, 20_000, 7, "floor");
        uint256 before = imd.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(MarginaliaRouter.Slippage.selector);
        router.note(p, key, 10 ether, 100 ether, vm.getBlockTimestamp());
        assertEq(imd.balanceOf(alice), before);
        assertEq(imd.balanceOf(address(router)), 0);
    }

    function testUnapprovedOrUnfundedAuthorIsRefused() public {
        T.NoteParams memory p = _margNote(T.Side.Buy, 20_000, 7, "poor");
        vm.prank(carol); // never approved or funded
        vm.expectRevert();
        router.note(p, key, 10 ether, 1, vm.getBlockTimestamp());
        imd.transfer(carol, 100 ether);
        vm.prank(carol);
        vm.expectRevert();
        router.note(p, key, 10 ether, 1, vm.getBlockTimestamp());
        assertEq(hook.noteCount(), 0);
    }

    function testVenueKindNoneIsRefusedForAPricedCall() public {
        T.NoteParams memory p = _margNote(T.Side.Buy, 20_000, 7, "no venue");
        p.venue.kind = T.VenueKind.None;
        vm.prank(alice);
        vm.expectRevert(MarginaliaRouter.BadVenue.selector);
        router.note(p, key, 10 ether, 1, vm.getBlockTimestamp());
        vm.expectRevert(MarginaliaRouter.BadVenue.selector);
        router.checkpointVenue(p, key);
    }

    function testV4VenueUnderAForeignHookIsRefused() public {
        PoolKey memory foreign = key;
        foreign.hooks = IHooks(address(0x00000000000000000000000000000000000020C0));
        T.NoteParams memory p = _margNote(T.Side.Buy, 20_000, 7, "foreign hook");
        p.venue.ref = PoolId.unwrap(foreign.toId());
        vm.prank(alice);
        vm.expectRevert(MarginaliaRouter.BadVenue.selector);
        router.note(p, foreign, 10 ether, 1, vm.getBlockTimestamp());
    }

    function testV4VenueWithoutLiquidityIsRefused() public {
        PoolKey memory empty = key;
        empty.fee = 3000;
        empty.hooks = IHooks(address(0));
        manager.initialize(empty, uint160(1 << 96));
        T.NoteParams memory p = _margNote(T.Side.Buy, 20_000, 7, "empty pool");
        p.venue.ref = PoolId.unwrap(empty.toId());
        vm.prank(alice);
        vm.expectRevert(MarginaliaRouter.BadVenue.selector);
        router.note(p, empty, 10 ether, 1, vm.getBlockTimestamp());
    }

    function testVenueFieldsAreDerivedFromThePoolNotTheCaller() public view {
        T.NoteParams memory p = _margNote(T.Side.Buy, 20_000, 7, "derived");
        p.venue.quote = address(0xBAD);
        p.venue.xIsToken0 = !margIs0; // the wrong orientation on purpose
        T.Venue memory v = router.validateVenue(p, key);
        assertEq(v.quote, address(imd));
        assertEq(v.xIsToken0, margIs0);
    }

    function testStrangersCannotEnterTheCallbacks() public {
        vm.prank(alice);
        vm.expectRevert(MarginaliaRouter.UnauthorizedCallback.selector);
        router.unlockCallback("");
        vm.prank(address(manager));
        vm.expectRevert(MarginaliaRouter.UnauthorizedCallback.selector);
        router.unlockCallback(abi.encode(uint256(1)));
        vm.prank(alice);
        vm.expectRevert(MarginaliaRouter.UnauthorizedCallback.selector);
        router.uniswapV3SwapCallback(1, 0, "");
        vm.prank(address(0));
        vm.expectRevert(MarginaliaRouter.UnauthorizedCallback.selector);
        router.uniswapV3SwapCallback(1, 0, "");
    }

    function testTradeAndNoteRefusesNoTradeZeroTradeAndNativeInput() public {
        T.NoteParams memory p = _margNote(T.Side.Buy, 20_000, 7, "traded");
        MarginaliaRouter.XTrade memory x;
        vm.startPrank(alice);
        vm.expectRevert(MarginaliaRouter.InvalidSwap.selector);
        router.tradeAndNote(x, p, key, 10 ether, 1, vm.getBlockTimestamp());
        x.kind = router.X_V4();
        x.key = key;
        x.zeroForOne = !margIs0;
        vm.expectRevert(MarginaliaRouter.InvalidSwap.selector);
        router.tradeAndNote(x, p, key, 10 ether, 1, vm.getBlockTimestamp());
        x.amountIn = 5 ether;
        x.key.currency0 = Currency.wrap(address(0));
        x.zeroForOne = true;
        vm.expectRevert(MarginaliaRouter.InvalidSwap.selector);
        router.tradeAndNote(x, p, key, 10 ether, 1, vm.getBlockTimestamp());
        vm.stopPrank();
        assertEq(hook.noteCount(), 0);
    }

    function testTradedNoteMustBeAboutTheTokenTraded() public {
        MarginaliaRouter.XTrade memory x;
        x.kind = router.X_V4();
        x.key = key;
        x.zeroForOne = !margIs0; // IMD in, MARG out
        x.amountIn = 5 ether;
        x.minOut = 1;
        // a BUY call on MARG after buying MARG: the subject is the output
        T.NoteParams memory p = _margNote(T.Side.Buy, 20_000, 7, "bought MARG");
        uint256 margBefore = token.balanceOf(alice);
        vm.prank(alice);
        uint256 received = router.tradeAndNote(x, p, key, 10 ether, 1, vm.getBlockTimestamp());
        T.Note memory n = hook.noteOf(bytes32(hook.noteCount()));
        assertEq(uint8(n.class), uint8(T.Class.Traded));
        assertGt(token.balanceOf(alice) - margBefore, received, "the X leg's MARG did not reach the author");
        assertEq(imd.balanceOf(address(router)), 0);
        assertEq(token.balanceOf(address(router)), 0);
        // a SELL call on MARG after buying MARG: the subject would be the input, IMD, so it is refused
        p = _margNote(T.Side.Sell, 7000, 7, "sell call after a buy");
        vm.prank(alice);
        vm.expectRevert(MarginaliaRouter.NoteTokenMismatch.selector);
        router.tradeAndNote(x, p, key, 10 ether, 1, vm.getBlockTimestamp());
        assertEq(imd.balanceOf(address(router)), 0);
    }

    function testTradedV4LegUnderAForeignHookOrEmptyPoolIsRefused() public {
        MarginaliaRouter.XTrade memory x;
        x.kind = router.X_V4();
        x.key = key;
        x.key.hooks = IHooks(address(0x00000000000000000000000000000000000020C0));
        x.zeroForOne = !margIs0;
        x.amountIn = 5 ether;
        T.NoteParams memory p = _margNote(T.Side.Buy, 20_000, 7, "foreign leg");
        uint256 before = imd.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(MarginaliaRouter.BadVenue.selector);
        router.tradeAndNote(x, p, key, 10 ether, 1, vm.getBlockTimestamp());
        x.key.hooks = IHooks(address(0));
        x.key.fee = 3000;
        manager.initialize(x.key, uint160(1 << 96));
        vm.prank(alice);
        vm.expectRevert(MarginaliaRouter.BadVenue.selector);
        router.tradeAndNote(x, p, key, 10 ether, 1, vm.getBlockTimestamp());
        assertEq(imd.balanceOf(alice), before, "a refused trade kept funds");
    }

    function testInitRequiresAManagerWithCode() public {
        MarginaliaRouter fresh = MarginaliaRouter(Clones.clone(address(new MarginaliaRouter())));
        vm.expectRevert(bytes("configuration required"));
        fresh.init(IPoolManager(makeAddr("no code")), address(this));
        vm.prank(address(0));
        vm.expectRevert(bytes("configuration required"));
        fresh.init(manager, address(0));
        assertEq(address(fresh.hook()), address(0));
        assertEq(address(fresh.manager()), address(0));
    }

    function testExpiredWindowRefusesPostsUntilAFreshCheckpointMatures() public {
        T.NoteParams memory p = _margNote(T.Side.Buy, 20_000, 7, "stale");
        vm.warp(vm.getBlockTimestamp() + 6 hours);
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(alice);
        vm.expectRevert();
        router.note(p, key, 10 ether, 1, vm.getBlockTimestamp());
        router.checkpointVenue(p, key);
        vm.warp(vm.getBlockTimestamp() + 1 hours - 1);
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(alice);
        vm.expectRevert();
        router.note(p, key, 10 ether, 1, vm.getBlockTimestamp());
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(alice);
        router.note(p, key, 10 ether, 1, vm.getBlockTimestamp());
        assertEq(hook.noteCount(), 1);
    }
}
