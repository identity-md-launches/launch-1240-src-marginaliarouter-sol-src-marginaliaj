// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {OracleAttestation, OracleAttestationConsumer} from "./OracleAttestation.sol";
import {IIntake} from "./interfaces/IIntake.sol";

interface IHookJudge {
    function imd() external view returns (address);
    function thesisPool(uint32 week) external view returns (uint256);
    function potMarg() external view returns (uint256);
    function week() external view returns (uint32);
    function thesesOfWeek(uint32 week) external view returns (bytes32[] memory);
    function noteMeta(bytes32 id)
        external
        view
        returns (address author, uint32 week, bool thesis, bool hasChild);
    function sellPotMarg(uint256 amount) external returns (uint256);
    function drawForJudging(uint32 week, uint256 amount, bool retry) external;
    function payJudged(uint32 day, bytes32[3] calldata top) external;
    function JUDGE_PRICE() external view returns (uint256);
}

/// @notice The oracle consumer and a permissionless helper: once per week, converts forfeited MARG, draws
/// the oracle's price from the thesis pool, buys the panel's ranking of the week's long-form theses, verifies
/// the signed answer, and tells the hook whom to pay. Short-form calls are never judged: they resolve against
/// price and score the leaderboard. Deployed by the hook; no owner.
contract MarginaliaJudge is OracleAttestationConsumer, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 public constant PANEL_SIZE = 7;
    uint16 public constant QUORUM = 5;
    uint256 public constant MAX_JUDGED = 120; // keeps the oracle body under the Intake's 16 KiB
    uint256 public constant MAX_PRICE = 1 ether; // the most this helper will pay the Intake per question
    uint256 public constant ANSWER_DEADLINE = 3 days; // after this an unanswered week may be re-requested

    IHookJudge public hook;
    IIntake public intake;
    bytes32 public action;

    mapping(uint32 => bytes32) public requestOf;
    mapping(uint32 => uint64) public requestedAt;
    mapping(bytes32 => uint32) private pendingDay; // day + 1, never zero
    mapping(uint32 => bytes32[]) private rawRanked; // the requested head of three, filtered lazily in payJudged
    mapping(uint32 => bool) public judgedSet;
    mapping(uint32 => bool) public paid;

    error DayNotOver();
    error AlreadyRequested();
    error NoNotes();
    error PriceMismatch();
    error OnlyIntake();
    error UnknownRequest();
    error BadAnswer();
    error NotJudged();
    error AlreadyPaid();
    error AlreadyInitialised();
    error OnlyHook();

    event Requested(uint32 indexed day, bytes32 indexed requestId, uint256 price);
    event Judged(uint32 indexed day, bytes32[3] ids);
    event Abandoned(uint32 indexed day, bytes32 indexed requestId);

    /// @dev The implementation locks itself (placeholder hook and signer); a clone gets the real ones from `init`.
    constructor() OracleAttestationConsumer(address(1)) {
        hook = IHookJudge(address(1));
    }

    /// @dev Called once by the hook on its clone, in the hook's constructor.
    function init(address hook_, address intake_, bytes32 action_, address signer_) external {
        if (address(hook) != address(0)) revert AlreadyInitialised();
        if (msg.sender != hook_) revert OnlyHook();
        require(
            hook_ != address(0) && intake_ != address(0) && action_ != bytes32(0), "configuration required"
        );
        hook = IHookJudge(hook_);
        intake = IIntake(intake_);
        action = action_;
        _setOracleSigner(signer_);
    }

    /// @dev The whole pot is tried first, then halves of it, down to 1/256: a pot that has outgrown what the
    /// pool absorbs inside the hook's slippage floor converts in tranches instead of being stranded.
    uint256 public constant CONVERT_HALVINGS = 8;

    /// @notice Converts forfeited MARG into IMD for today's pot: the whole pot if the pool absorbs it within
    /// the hook's floor, otherwise the largest halving of it that does. Anyone, any time. Reverts with the
    /// hook's reason only when not even the smallest tranche sells (a stale window or a pushed price).
    function convertForfeits() external nonReentrant returns (uint256 imdOut) {
        uint256 marg = hook.potMarg();
        if (marg == 0) return 0;
        bytes memory reason;
        for (uint256 i = 0; i <= CONVERT_HALVINGS && marg > 0; ++i) {
            try hook.sellPotMarg(marg) returns (uint256 out) {
                return out;
            } catch (bytes memory r) {
                reason = r;
            }
            marg /= 2;
        }
        assembly ("memory-safe") {
            revert(add(reason, 32), mload(reason))
        }
    }

    /// @notice The oracle body for a day: deterministic from the day's note ids, so anyone can check it.
    /// @notice The week's theses that have at least one child call: the judged set, capped, by posting order.
    function eligibleTheses(uint32 week) public view returns (bytes32[] memory out) {
        bytes32[] memory all = hook.thesesOfWeek(week);
        bytes32[] memory tmp = new bytes32[](all.length);
        uint256 n;
        for (uint256 i = 0; i < all.length && n < MAX_JUDGED; ++i) {
            (,,, bool hasChild) = hook.noteMeta(all[i]);
            if (hasChild) tmp[n++] = all[i];
        }
        out = new bytes32[](n);
        for (uint256 i = 0; i < n; ++i) {
            out[i] = tmp[i];
        }
    }

    /// @notice The oracle body for a week: deterministic from the week's eligible thesis ids, so anyone can check it.
    function questionBody(uint32 week) public view returns (string memory) {
        bytes32[] memory ids = eligibleTheses(week);
        bytes memory allow;
        for (uint256 i = 0; i < ids.length; ++i) {
            allow =
                bytes.concat(allow, i == 0 ? bytes('"') : bytes(',"'), _hex(uint256(ids[i]), 32), bytes('"'));
        }
        return string(
            bytes.concat(
                bytes(
                    '{"v":1,"question":"Rank the three best-argued Marginalia theses among these ids by verifiable reasoning and citations (on-chain reads, named addresses, holder or liquidity facts, mechanism arguments, sourced claims). A thesis without reasoning scores zero. Ignore whether its calls proved right.","chainId":'
                ),
                _dec(block.chainid),
                bytes(
                    ',"window":{"hours":168},"answerType":"bytes32[]","evidence":"panel","head":3,"panelSize":'
                ),
                _dec(PANEL_SIZE),
                bytes(',"quorum":'),
                _dec(QUORUM),
                bytes(',"validForSeconds":86400,"guards":{"allow":['),
                allow,
                bytes(']},"consumer":{"chainId":'),
                _dec(block.chainid),
                bytes(',"verifyingContract":"'),
                _hex(uint256(uint160(address(this))), 20),
                bytes('"}}')
            )
        );
    }

    function _hex(uint256 v, uint256 len) private pure returns (bytes memory out) {
        bytes16 digits = "0123456789abcdef";
        out = new bytes(2 + len * 2);
        out[0] = "0";
        out[1] = "x";
        for (uint256 i = 2 + len * 2; i > 2; --i) {
            out[i - 1] = digits[v & 0xf];
            v >>= 4;
        }
    }

    function _dec(uint256 v) private pure returns (bytes memory) {
        if (v == 0) return "0";
        uint256 n;
        for (uint256 t = v; t > 0; t /= 10) {
            ++n;
        }
        bytes memory out = new bytes(n);
        for (uint256 i = n; i > 0; --i) {
            out[i - 1] = bytes1(uint8(48 + v % 10));
            v /= 10;
        }
        return out;
    }

    /// @notice Whether a week can never be judged again: nothing judged, no request still deliverable (none
    /// made, or the last one abandoned), and either no eligible theses or four weeks past the week's end.
    function weekClosed(uint32 week) external view returns (bool) {
        if (week >= hook.week()) return false;
        if (judgedSet[week]) return false;
        if (requestOf[week] != bytes32(0) && pendingDay[requestOf[week]] != 0) return false;
        return eligibleTheses(week).length == 0 || block.timestamp >= (uint256(week) + 1) * 7 days + 28 days;
    }

    /// @notice Anyone invalidates an unanswered request once its deadline has passed, so a late delivery can no
    /// longer land on a week whose thesis pool has been swept. A retry does the same before re-requesting.
    function abandonRequest(uint32 week) external {
        bytes32 id = requestOf[week];
        if (id == bytes32(0) || pendingDay[id] == 0) revert UnknownRequest();
        if (judgedSet[week] || block.timestamp < requestedAt[week] + ANSWER_DEADLINE) {
            revert AlreadyRequested();
        }
        delete pendingDay[id];
        emit Abandoned(week, id);
    }

    /// @notice Buys the panel's ranking for a finished week whose thesis pool clears the hook's threshold.
    /// An unanswered request may be retried after the answer deadline.
    function requestJudging(uint32 day) external nonReentrant returns (bytes32 requestId) {
        if (day >= hook.week()) revert DayNotOver();
        bool retry = requestOf[day] != bytes32(0);
        if (judgedSet[day] || (retry && block.timestamp < requestedAt[day] + ANSWER_DEADLINE)) {
            revert AlreadyRequested();
        }
        if (eligibleTheses(day).length == 0) revert NoNotes();
        address imd = hook.imd();
        uint256 price = intake.priceOf(action, imd);
        if (price == 0 || price > MAX_PRICE) revert PriceMismatch();
        if (retry) delete pendingDay[requestOf[day]];
        hook.drawForJudging(day, price, retry);
        IERC20(imd).forceApprove(address(intake), price);
        bytes memory body = bytes(questionBody(day));
        requestId = intake.request(
            action, body, IIntake.Callback(address(this), this.onOracleResult.selector), imd, price
        );
        IERC20(imd).forceApprove(address(intake), 0);
        if (pendingDay[requestId] != 0) revert AlreadyRequested();
        requestOf[day] = requestId;
        requestedAt[day] = uint64(block.timestamp);
        pendingDay[requestId] = day + 1;
        emit Requested(day, requestId, price);
    }

    /// @notice The Intake delivers the panel's ranking here. Verify and store the requested head;
    /// filter it against eligible theses later, outside the callback's gas stipend.
    function onOracleResult(
        bytes32 requestId,
        OracleAttestation.Attestation calldata a,
        bytes calldata signature
    ) external nonReentrant {
        if (msg.sender != address(intake)) revert OnlyIntake();
        uint32 stored = pendingDay[requestId];
        if (stored == 0) revert UnknownRequest();
        delete pendingDay[requestId];
        uint32 day = stored - 1;
        _verifyAttestation(a, signature);
        // The question is about this chain (questionBody pins block.chainid), so the answer must be too.
        if (
            a.chainId != block.chainid || a.agreed < a.quorum || a.quorum < QUORUM || a.panelSize < PANEL_SIZE
                || judgedSet[day]
        ) revert BadAnswer();
        bytes32[] memory ranked = decodeBytes32List(a);
        _consume(a.requestId);
        // The question requests head=3. Bound storage writes to fit the Intake's 200k callback
        // even if the panel returns its entire ranking; filtering stays in the later payment call.
        uint256 count = ranked.length < 3 ? ranked.length : 3;
        for (uint256 i; i < count; ++i) {
            rawRanked[day].push(ranked[i]);
        }
        judgedSet[day] = true;
        emit Judged(
            day,
            [
                count > 0 ? ranked[0] : bytes32(0),
                count > 1 ? ranked[1] : bytes32(0),
                count > 2 ? ranked[2] : bytes32(0)
            ]
        );
    }

    /// @notice The requested head of the panel's ranking, filtered to this week's theses and deduplicated.
    function judgedOf(uint32 day) public view returns (bytes32[3] memory top) {
        bytes32[] storage ranked = rawRanked[day];
        uint256 kept;
        for (uint256 i = 0; i < ranked.length && kept < 3; ++i) {
            (address author, uint32 noteWeek, bool thesis, bool hasChild) = hook.noteMeta(ranked[i]);
            if (author == address(0) || noteWeek != day || !thesis || !hasChild) continue;
            bool dup;
            for (uint256 k = 0; k < kept; ++k) {
                if (top[k] == ranked[i]) dup = true;
            }
            if (dup) continue;
            top[kept++] = ranked[i];
        }
    }

    /// @notice Pays a judged week. An empty eligible head rolls the full thesis pool forward.
    /// Anyone may call it once the ranking is in.
    function payJudged(uint32 day) external nonReentrant {
        if (!judgedSet[day]) revert NotJudged();
        if (paid[day]) revert AlreadyPaid();
        bytes32[3] memory top = judgedOf(day);
        paid[day] = true;
        hook.payJudged(day, top);
    }
}
