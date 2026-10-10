// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MarginaliaJudge} from "../src/MarginaliaJudge.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../src/OracleAttestation.sol";
import {IIntake} from "../src/interfaces/IIntake.sol";

contract JudgeHookStub {
    address public imd;
    uint32 public constant week = 100;
    bytes32[3] public winners;
    uint256 public payments;

    constructor(address imd_) {
        imd = imd_;
    }

    function thesesOfWeek(uint32 w) external pure returns (bytes32[] memory ids) {
        ids = new bytes32[](w == 99 ? 4 : 0);
        for (uint256 i; i < ids.length; ++i) {
            ids[i] = bytes32(i + 1);
        }
    }

    function noteMeta(bytes32 id) external view returns (address, uint32, bool, bool) {
        return (uint256(id) >= 1 && uint256(id) <= 4 ? address(this) : address(0), 99, true, true);
    }

    function drawForJudging(uint32, uint256 amount, bool) external {
        IERC20(imd).transfer(msg.sender, amount);
    }

    function payJudged(uint32, bytes32[3] calldata top) external {
        winners = top;
        ++payments;
    }
}

contract StipendIntake is IIntake {
    uint256 private requests;
    address public target;

    function priceOf(bytes32, address) external pure returns (uint256) {
        return 0.5 ether;
    }

    function request(bytes32, bytes calldata, Callback calldata callback, address asset, uint256 amount)
        external
        payable
        returns (bytes32)
    {
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        target = callback.target;
        return bytes32(++requests);
    }

    function deliver(bytes32 requestId, OracleAttestation.Attestation calldata a, bytes calldata signature)
        external
        returns (bool ok, bytes memory result)
    {
        return
            target.call{gas: 200_000}(
                abi.encodeCall(MarginaliaJudge.onOracleResult, (requestId, a, signature))
            );
    }
}

/// @dev Exposes only signature verification for the pinned protocol vector, whose 5/4 panel
/// deliberately differs from this application's 7/5 panel. The deployed judge keeps its quorum.
contract JudgeSignatureHarness is MarginaliaJudge {
    function verify(OracleAttestation.Attestation calldata a, bytes calldata signature) external view {
        _verifyAttestation(a, signature);
    }
}

contract JudgeOracleTest is Test {
    uint256 private constant SIGNER_KEY = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    address private constant SIGNER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address private constant VECTOR_CONSUMER = 0x0000000000000000000000000000000000002748;
    bytes32 private constant VECTOR_DIGEST =
        0x95fefa8b7c529852f4e2b6aec888930eb2bf5078e6443a85808e36df19e1325c;
    bytes private constant VECTOR_SIGNATURE =
        hex"a26b14918607eb565af126beb54d3c5d19e923c41506def500b3521a4f9aa6d603ab44fd22f15dd2191732961a7131e4641244add8b0f09f20e6ae64381be8481b";
    MarginaliaJudge private judge;
    JudgeHookStub private hook;
    StipendIntake private intake;
    bytes32 private requestId;

    function setUp() public {
        vm.warp(1_800_000_000);
        MockERC20 imd = new MockERC20("IMD", "IMD", 100 ether);
        hook = new JudgeHookStub(address(imd));
        imd.transfer(address(hook), 100 ether);
        intake = new StipendIntake();
        judge = MarginaliaJudge(Clones.clone(address(new MarginaliaJudge())));
        vm.prank(address(hook));
        judge.init(address(hook), address(intake), bytes32("oracle.request@oracle-1"), SIGNER);
        requestId = judge.requestJudging(99);
    }

    function _att(uint256 count) private view returns (OracleAttestation.Attestation memory a) {
        bytes32[] memory ids = new bytes32[](count);
        for (uint256 i; i < count; ++i) {
            ids[i] = bytes32(i + 1);
        }
        a.requestId = keccak256("signed judge request");
        a.chainId = block.chainid;
        a.questionHash = keccak256("rank theses");
        a.answerType = 5;
        a.answer = abi.encode(ids);
        a.panelSize = 7;
        a.quorum = 5;
        a.agreed = 6;
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 1 days);
    }

    function _sign(OracleAttestation.Attestation memory a) private view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, judge.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }

    function testFiveIdsWithEoaSignatureFitStipend() public {
        _deliverLong(5);
    }

    function testFullRankingWithEoaSignatureFitsStipend() public {
        _deliverLong(120);
    }

    function _deliverLong(uint256 count) private {
        OracleAttestation.Attestation memory a = _att(count);
        (bool ok,) = intake.deliver(requestId, a, _sign(a));
        assertTrue(ok, "cold clone callback must fit 200k gas");
        assertTrue(judge.judgedSet(99));
        assertTrue(judge.consumed(a.requestId));
        bytes32[3] memory top = judge.judgedOf(99);
        assertEq(top[0], bytes32(uint256(1)));
        assertEq(top[1], bytes32(uint256(2)));
        assertEq(top[2], bytes32(uint256(3)));
        judge.payJudged(99);
        assertEq(hook.payments(), 1);
        vm.expectRevert(MarginaliaJudge.AlreadyPaid.selector);
        judge.payJudged(99);
        (ok,) = intake.deliver(requestId, a, _sign(a));
        assertFalse(ok, "callback replay");
    }

    function testEmptySignedRankingIsAnExecutableNoWinnerResult() public {
        OracleAttestation.Attestation memory a = _att(0);
        (bool ok,) = intake.deliver(requestId, a, _sign(a));
        assertTrue(ok);
        judge.payJudged(99);
        assertEq(hook.winners(0), bytes32(0));
        assertEq(hook.payments(), 1);
        assertTrue(judge.paid(99));
    }

    function testRequestedHeadIsFilteredAndDeduplicatedWithoutPromotingTheTail() public {
        OracleAttestation.Attestation memory a = _att(4);
        bytes32[] memory ids = new bytes32[](4);
        ids[0] = bytes32(uint256(1));
        ids[1] = ids[0];
        ids[2] = bytes32(uint256(999));
        ids[3] = bytes32(uint256(2));
        a.answer = abi.encode(ids);
        (bool ok,) = intake.deliver(requestId, a, _sign(a));
        assertTrue(ok);
        bytes32[3] memory top = judge.judgedOf(99);
        assertEq(top[0], ids[0]);
        assertEq(top[1], bytes32(0));
        assertEq(top[2], bytes32(0));
    }

    function testRejectedAnswersDoNotConsumeThePendingRequest() public {
        OracleAttestation.Attestation memory a = _att(3);
        bytes memory sig = _sign(a);
        vm.expectRevert(MarginaliaJudge.OnlyIntake.selector);
        judge.onOracleResult(requestId, a, sig);
        (bool ok,) = intake.deliver(keccak256("unknown"), a, sig);
        assertFalse(ok);
        a.figure = 1; // unsigned tampering
        (ok,) = intake.deliver(requestId, a, sig);
        assertFalse(ok);
        a.figure = 0;
        a.agreed = 4;
        (ok,) = intake.deliver(requestId, a, _sign(a));
        assertFalse(ok);
        a.agreed = 6;
        a.quorum = 4;
        (ok,) = intake.deliver(requestId, a, _sign(a));
        assertFalse(ok);
        a.quorum = 5;
        a.panelSize = 6;
        (ok,) = intake.deliver(requestId, a, _sign(a));
        assertFalse(ok);
        a.panelSize = 7;
        a.answerType = 3;
        (ok,) = intake.deliver(requestId, a, _sign(a));
        assertFalse(ok);
        a.answerType = 5;
        a.expiresAt = uint64(block.timestamp - 1);
        (ok,) = intake.deliver(requestId, a, _sign(a));
        assertFalse(ok);
        a.expiresAt = uint64(block.timestamp + 1 days);
        a.issuedAt = uint64(block.timestamp + 6 minutes);
        (ok,) = intake.deliver(requestId, a, _sign(a));
        assertFalse(ok);
        assertFalse(judge.judgedSet(99));
        assertFalse(judge.consumed(a.requestId));
        a.issuedAt = uint64(block.timestamp);
        (ok,) = intake.deliver(requestId, a, _sign(a));
        assertTrue(ok, "valid answer still deliverable");
    }

    function testTimeoutRetryInvalidatesOldIntakeRequest() public {
        vm.warp(block.timestamp + 3 days);
        bytes32 next = judge.requestJudging(99);
        assertNotEq(next, requestId);
        OracleAttestation.Attestation memory a = _att(3);
        (bool ok,) = intake.deliver(requestId, a, _sign(a));
        assertFalse(ok);
        (ok,) = intake.deliver(next, a, _sign(a));
        assertTrue(ok);
    }

    function _vector() private pure returns (OracleAttestation.Attestation memory a) {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = bytes32(uint256(1));
        a = OracleAttestation.Attestation({
            requestId: 0x0000000000004000800000000000000100000000000000000000000000000000,
            chainId: 1,
            questionHash: 0x2117f4362ebfa37aa8a8c0fed548604fe09ac46faf8ae7559cd64780f26a46fb,
            answerType: 5,
            answer: abi.encode(ids),
            figure: 12345,
            fromBlock: 100,
            toBlock: 200,
            blockHash: bytes32(uint256(7)),
            panelJobId: 0x0000000000004000800000000000000200000000000000000000000000000000,
            panelSize: 5,
            quorum: 4,
            agreed: 5,
            issuedAt: 1800000000,
            expiresAt: 1800003600
        });
    }

    function testProtocolDigestSignatureAndSelectorConformanceOnClone() public {
        vm.chainId(11155111);
        address implementation = address(new JudgeSignatureHarness());
        address clone = Clones.clone(implementation);
        vm.etch(VECTOR_CONSUMER, clone.code);
        JudgeSignatureHarness consumer = JudgeSignatureHarness(VECTOR_CONSUMER);
        vm.prank(address(hook));
        consumer.init(address(hook), address(intake), bytes32("oracle.request@oracle-1"), SIGNER);
        assertEq(consumer.attestationDigest(_vector()), VECTOR_DIGEST);
        consumer.verify(_vector(), VECTOR_SIGNATURE);
        assertEq(consumer.onOracleResult.selector, bytes4(0x510379c7));
        // The application must still reject the vector's smaller panel after signature verification.
        bytes32 req = consumer.requestJudging(99);
        (bool ok, bytes memory result) = intake.deliver(req, _vector(), VECTOR_SIGNATURE);
        assertFalse(ok);
        assertEq(result, abi.encodeWithSelector(MarginaliaJudge.BadAnswer.selector));
    }
}
