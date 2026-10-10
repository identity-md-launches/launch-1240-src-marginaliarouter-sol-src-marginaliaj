// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MarginaliaTypes as T} from "./MarginaliaTypes.sol";
import {MarginaliaPricer} from "./MarginaliaPricer.sol";
import {MarginaliaTreasury} from "./MarginaliaTreasury.sol";
import {MarginaliaRouter} from "./MarginaliaRouter.sol";
import {MarginaliaJudge} from "./MarginaliaJudge.sol";
import {MarginaliaImpls} from "./MarginaliaImpls.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

/// @title Marginalia: notes in the margin of every trade
/// @notice A Uniswap v4 hook on the MARG/IMD launch pool. Buying MARG through the router with a note in
/// hookData posts a falsifiable call on any ERC-20: a flat stamp (0.1 IMD-equivalent, to the pot) and a
/// flat deposit (0.5 IMD-equivalent of the bought MARG, locked for the horizon). The call resolves against
/// a manipulation-resistant settlement price (MarginaliaPricer); a right, still-held call gets its deposit back; anything
/// else forfeits it to the pot. The pot pays the best-argued notes of the day, ranked by the IMD oracle
/// panel, which this contract verifies as the attestation's consumer. No owner, no pause, no upgrade.
contract MarginaliaHook is IUnlockCallback {
    using SafeCast for uint256;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------ constants

    uint256 public constant STAMP = 0.1 ether; // IMD-equivalent, non-refundable, to the pot
    uint256 public constant DEPOSIT = 0.5 ether; // IMD-equivalent of MARG, refundable
    uint256 public constant SELL_NOTED_BPS = 100;
    uint256 public constant SELL_QUIET_BPS = 300;
    uint32 public constant MIN_TARGET_DELTA_BPS = 1000;
    uint16 public constant MAX_HORIZON_DAYS = 90;
    uint256 public constant TEXT_MAX = 280;
    uint256 public constant THESIS_TEXT_MAX = 8192;
    uint256 public constant THESIS_GRACE = 7 days;
    uint256 public constant SETTLE_WINDOW = 6 hours;
    uint256 public constant OBS_MIN = 3;
    uint256 public constant OBS_MAX = 16;
    uint256 public constant OBS_GAP_BLOCKS = 20;
    /// @dev Observations must span at least this long, so no single block (or pair of blocks) sets the price.
    uint256 public constant OBS_MIN_SPAN = 1 hours;
    uint256 public constant KEEPER_BPS = 200;
    /// @dev A week's theses are capped at what the judge can put in front of the panel (its MAX_JUDGED), and a
    /// thesis past the cap is refused before its stamp and deposit are taken, never silently unjudgeable.
    uint256 public constant MAX_WEEK_THESES = 120;
    /// @dev Gas allowed to a note token's balanceOf during an observation; a read that fails is "not held".
    uint256 public constant BALANCE_READ_GAS = 100_000;
    uint256 public constant JUDGE_THRESHOLD = 2 ether; // IMD, in the week's thesis pot
    uint256 public constant JUDGE_PRICE = 0.5 ether; // IMD, the Intake's oracle.request price
    uint256 public constant LEADERBOARD_BPS = 5000; // of every accrual: the week's score-weighted pool
    uint256 public constant THESIS_BPS = 3000; // the week's judged thesis prize
    uint256 public constant LEADERBOARD_CAP_BPS = 1000; // no wallet takes more than 10% of a week's pool
    uint256 public constant SWEEP_AFTER = 28 days; // unclaimed pools roll forward after this
    uint256 public constant LP_FEE = 12_500;

    /// @dev The IMD oracle (Ethereum mainnet and Robinhood Chain share these addresses).
    address public constant INTAKE = 0x1397434cd35e8a9C8aC312A61D3A285EB31dea56;
    address public constant ORACLE_SIGNER = 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;
    bytes32 public constant ACTION = bytes32("oracle.request@oracle-1");
    /// @dev Ethereum mainnet ETH/IMD hub pool (1% fee, tick spacing 200, no hook): native is token0.

    // ------------------------------------------------------------------ immutables and pool state

    IPoolManager public immutable poolManager;
    address public immutable token;
    address public immutable factory;
    MarginaliaTreasury public immutable treasury;
    MarginaliaRouter public immutable router;
    MarginaliaJudge public immutable judge;

    address public imd;
    bool public initialized;
    bool private imdIs0;
    PoolKey private pool;
    PoolId public poolId;

    // ------------------------------------------------------------------ notes

    uint256 public noteCount;
    mapping(bytes32 => T.Note) private notes;
    mapping(bytes32 => T.Observation[]) private observations;

    struct Record {
        int256 score;
        uint32 posted;
        uint32 right;
        uint32 wrong;
        uint32 broken;
        uint32 retracted;
        uint32 judgedWins;
    }

    mapping(address => Record) public records;

    // ------------------------------------------------------------------ pot and judging

    /// @dev Every IMD accrual (stamps, fees, forfeits, drips) splits three ways at accrual time, all held
    /// as ERC-6909 claims: the week's leaderboard pool, the week's thesis prize, the day's writer refund.
    mapping(uint32 => uint256) public leaderboardPool; // by week
    mapping(uint32 => uint256) public thesisPool; // by week
    mapping(uint32 => uint256) public refundPool; // by day
    /// @dev Forfeited MARG held as claims, converted to IMD by the judge.
    uint256 public potMarg;
    mapping(uint32 => bool) public judgedPaid;
    /// @dev Score earned per wallet per week, and the week's sum of positive scores (the pro-rata base).
    mapping(uint32 => mapping(address => int256)) public weekScore;
    mapping(uint32 => uint256) public weekTotal;
    mapping(uint32 => mapping(address => bool)) public leaderboardClaimed;
    mapping(uint32 => uint256) public leaderboardPaid;
    mapping(uint32 => uint32) public notesPerDay;
    mapping(bytes32 => bool) public refundClaimed;
    mapping(uint32 => bytes32[]) private weekTheses;

    // ------------------------------------------------------------------ transient-ish scratch

    bytes32 private unlockHash;
    uint256 private pendingSellDeposit;

    uint8 private constant ACT_PAY = 1; // burn claims, take currency to `to`
    uint8 private constant ACT_FUND = 2; // move ERC-20 IMD into claims
    uint8 private constant ACT_SELL = 3; // swap MARG claims to IMD (to `to`, or kept as claims)

    // ------------------------------------------------------------------ errors and events

    error Unauthorized();
    error InvalidPool();
    error PartialFill();
    error BadHookData();
    error NoteNeedsExactInput();
    error NoteTooSmall();
    error InvalidNote();
    error UnknownNote();
    error NotOpen();
    error TooEarly();
    error TooLate();
    error ObservationTooSoon();
    error NothingToClaim();
    error AlreadyPaid();
    error InvalidUnlock();
    error PotTooSmall();
    error NothingToSweep();

    event PoolBound(PoolId indexed poolId, address indexed imd);
    event SwapFee(bool indexed buy, address indexed trader, uint256 poolImd, uint256 fee, uint256 stamp);
    event NotePosted(
        bytes32 indexed id,
        address indexed author,
        address indexed x,
        uint8 class,
        T.Side side,
        uint32 targetBps,
        uint16 horizonDays,
        uint256 postPrice,
        uint256 deposit,
        bytes32 parentId,
        uint256 xResult,
        string text
    );
    event Observed(bytes32 indexed id, uint64 timestamp, uint256 xRead, uint256 quoteRead, uint256 balance);
    event Settled(
        bytes32 indexed id, T.Status status, uint256 settlePrice, int256 scoreDelta, address keeper
    );
    event Retracted(bytes32 indexed id, string text);
    event DepositClaimed(bytes32 indexed id, address indexed to, bool asImd, uint256 amount);
    event ThesisReleased(bytes32 indexed id);
    event ThesisForfeited(bytes32 indexed id);
    event PotFunded(uint32 indexed day, uint256 amount, address indexed source);
    event Accrued(uint32 indexed day, uint256 amount);
    event LeaderboardClaimed(uint32 indexed week, address indexed wallet, uint256 amount);
    event RefundClaimed(bytes32 indexed id, address indexed wallet, uint256 amount);
    event Swept(uint8 kind, uint32 indexed epoch, uint256 amount);
    event PotMargSold(uint256 marg, uint256 imdOut, uint32 indexed day);
    event JudgedPaid(uint32 indexed day, uint256[3] amounts);

    // ------------------------------------------------------------------ construction

    constructor(IPoolManager poolManager_, address token_, address factory_) {
        if (address(poolManager_).code.length == 0 || token_.code.length == 0 || factory_ == address(0)) {
            revert InvalidUnlock();
        }
        poolManager = poolManager_;
        token = token_;
        factory = factory_;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
        // Companions are EIP-1167 clones of audited implementations, initialised here and never again.
        if (
            MarginaliaImpls.TREASURY_IMPL.code.length == 0 || MarginaliaImpls.ROUTER_IMPL.code.length == 0
                || MarginaliaImpls.JUDGE_IMPL.code.length == 0 || MarginaliaImpls.PRICER.code.length == 0
        ) revert InvalidUnlock();
        MarginaliaTreasury t = MarginaliaTreasury(payable(Clones.clone(MarginaliaImpls.TREASURY_IMPL)));
        t.init(address(this));
        treasury = t;
        MarginaliaRouter r = MarginaliaRouter(Clones.clone(MarginaliaImpls.ROUTER_IMPL));
        r.init(poolManager_, address(this));
        router = r;
        MarginaliaJudge j = MarginaliaJudge(Clones.clone(MarginaliaImpls.JUDGE_IMPL));
        j.init(address(this), INTAKE, ACTION, ORACLE_SIGNER);
        judge = j;
    }

    modifier onlyManager() {
        if (msg.sender != address(poolManager)) revert Unauthorized();
        _;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeSwap = true;
        p.afterSwap = true;
        p.beforeSwapReturnDelta = true;
        p.afterSwapReturnDelta = true;
    }

    // ------------------------------------------------------------------ pool binding

    function beforeInitialize(address sender, PoolKey calldata key, uint160)
        external
        onlyManager
        returns (bytes4)
    {
        if (sender != factory || initialized || key.fee != LP_FEE || address(key.hooks) != address(this)) {
            revert InvalidPool();
        }
        address a = Currency.unwrap(key.currency0);
        address b = Currency.unwrap(key.currency1);
        address pair = a == token ? b : (b == token ? a : address(0));
        if (pair == address(0) || pair.code.length == 0) revert InvalidPool();
        imd = pair;
        imdIs0 = (a == pair);
        pool = key;
        poolId = key.toId();
        initialized = true;
        emit PoolBound(poolId, pair);
        return IHooks.beforeInitialize.selector;
    }

    function getPoolKey() external view returns (PoolKey memory) {
        if (!initialized) revert InvalidPool();
        return pool;
    }

    function _checkPool(PoolKey calldata key) private view {
        if (!initialized || PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId)) revert InvalidPool();
    }

    // ------------------------------------------------------------------ swaps

    function _dataKind(address sender, bytes calldata data) private view returns (uint8 kind) {
        if (data.length == 0) return 0;
        kind = abi.decode(data, (uint8));
        if (kind == T.DATA_EXEMPT) {
            if (sender != address(this)) revert BadHookData();
        } else if (kind == T.DATA_NOTE) {
            if (sender != address(router)) revert BadHookData();
        } else {
            revert BadHookData();
        }
    }

    /// @dev Current MARG price in IMD from the bound pool, 1e18 scaled.
    function margPriceInImd() public view returns (uint256) {
        (uint160 sqrtP,,,) = poolManager.getSlot0(poolId);
        return pricer().fromSqrt(sqrtP, !imdIs0);
    }

    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata data)
        external
        onlyManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _checkPool(key);
        bool buy = params.zeroForOne == imdIs0;
        uint8 kind = _dataKind(sender, data);
        uint256 specifiedTake = 0;
        if (buy) {
            if (kind == T.DATA_NOTE) {
                // The stamp comes off the specified IMD input; the deposit comes off the MARG output in afterSwap.
                if (params.amountSpecified >= 0) revert NoteNeedsExactInput();
                if (uint256(-params.amountSpecified) <= STAMP * 2) revert NoteTooSmall();
                specifiedTake = STAMP;
            }
        } else if (kind == T.DATA_NOTE) {
            // A noted sell: the deposit is MARG taken off the specified input; the 1% fee and stamp come
            // off the IMD output in afterSwap. Exact input only.
            if (params.amountSpecified >= 0) revert NoteNeedsExactInput();
            uint256 depositMarg = FullMath.mulDiv(DEPOSIT, 1e18, margPriceInImd());
            if (uint256(-params.amountSpecified) <= depositMarg * 2) revert NoteTooSmall();
            pendingSellDeposit = depositMarg;
            specifiedTake = depositMarg;
        } else if (kind != T.DATA_EXEMPT && params.amountSpecified > 0) {
            // Exact-output IMD sell: gross the quiet fee up so the requested output is net of it.
            uint256 bps = SELL_QUIET_BPS;
            specifiedTake = (uint256(params.amountSpecified) * bps + (10_000 - bps) - 1) / (10_000 - bps);
        }
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(specifiedTake.toInt128(), 0), 0);
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata data
    ) external onlyManager returns (bytes4, int128) {
        _checkPool(key);
        bool buy = params.zeroForOne == imdIs0;
        int128 imdDelta = imdIs0 ? delta.amount0() : delta.amount1();
        int128 margDelta = imdIs0 ? delta.amount1() : delta.amount0();
        if ((buy && imdDelta >= 0) || (!buy && imdDelta <= 0)) revert PartialFill();
        uint256 poolImd = buy ? uint256(uint128(-imdDelta)) : uint256(uint128(imdDelta));
        uint8 kind = _dataKind(sender, data);

        if (buy) {
            if (kind != T.DATA_NOTE) return (IHooks.afterSwap.selector, 0);
            uint256 netIn = uint256(-params.amountSpecified) - STAMP;
            if (poolImd != netIn) revert PartialFill();
            uint256 margOut = uint256(uint128(margDelta));
            uint256 depositMarg = FullMath.mulDiv(DEPOSIT, margOut, netIn);
            if (margOut <= depositMarg + 1) revert NoteTooSmall();
            poolManager.mint(address(this), _id(imd), STAMP);
            poolManager.mint(address(this), _id(token), depositMarg);
            _accrue(STAMP);
            (T.NoteParams memory p, address author, uint256 xResult) = _decodeNote(data);
            _postNote(author, p, xResult, depositMarg, margOut - depositMarg);
            emit SwapFee(true, author, poolImd, 0, STAMP);
            return (IHooks.afterSwap.selector, depositMarg.toInt128());
        }

        if (kind == T.DATA_EXEMPT) return (IHooks.afterSwap.selector, 0);

        if (kind == T.DATA_NOTE) {
            uint256 depositMarg = pendingSellDeposit;
            delete pendingSellDeposit;
            uint256 fee = poolImd * SELL_NOTED_BPS / 10_000 + STAMP;
            if (poolImd <= fee) revert NoteTooSmall();
            poolManager.mint(address(this), _id(imd), fee);
            poolManager.mint(address(this), _id(token), depositMarg);
            _accrue(fee);
            (T.NoteParams memory p, address author, uint256 xResult) = _decodeNote(data);
            _postNote(author, p, xResult, depositMarg, 0);
            emit SwapFee(false, author, poolImd, fee - STAMP, STAMP);
            return (IHooks.afterSwap.selector, fee.toInt128());
        }

        // Quiet sell.
        uint256 quietFee;
        int128 returned = 0;
        if (params.amountSpecified > 0) {
            uint256 bps = SELL_QUIET_BPS;
            quietFee = (uint256(params.amountSpecified) * bps + (10_000 - bps) - 1) / (10_000 - bps);
            if (poolImd != uint256(params.amountSpecified) + quietFee) revert PartialFill();
        } else {
            quietFee = poolImd * SELL_QUIET_BPS / 10_000;
            returned = quietFee.toInt128();
        }
        if (quietFee > 0) {
            poolManager.mint(address(this), _id(imd), quietFee);
            _accrue(quietFee);
        }
        emit SwapFee(false, tx.origin, poolImd, quietFee, 0);
        return (IHooks.afterSwap.selector, returned);
    }

    /// @dev Splits an IMD accrual into the three pools.
    function _accrue(uint256 amount) private {
        uint32 day = _today();
        uint32 week = _week();
        uint256 lb = amount * LEADERBOARD_BPS / 10_000;
        uint256 th = amount * THESIS_BPS / 10_000;
        leaderboardPool[week] += lb;
        thesisPool[week] += th;
        refundPool[day] += amount - lb - th;
        emit Accrued(day, amount);
    }

    function _decodeNote(bytes calldata data)
        private
        pure
        returns (T.NoteParams memory p, address author, uint256 xResult)
    {
        (, p, author, xResult) = abi.decode(data, (uint8, T.NoteParams, address, uint256));
        if (author == address(0)) revert BadHookData();
    }

    // ------------------------------------------------------------------ notes

    function _postNote(
        address author,
        T.NoteParams memory p,
        uint256 xResult,
        uint256 depositMarg,
        uint256 margToAuthor
    ) private {
        bool thesis = p.targetBps == 0;
        uint256 textLen = bytes(p.text).length;
        if (thesis) {
            if (textLen == 0 || textLen > THESIS_TEXT_MAX || p.parentId != bytes32(0)) revert InvalidNote();
        } else {
            if (textLen == 0 || textLen > TEXT_MAX) revert InvalidNote();
            if (p.horizonDays == 0 || p.horizonDays > MAX_HORIZON_DAYS) revert InvalidNote();
            if (p.side == T.Side.Buy) {
                if (p.targetBps < 10_000 + MIN_TARGET_DELTA_BPS) revert InvalidNote();
            } else {
                if (p.targetBps >= 10_000 || p.targetBps + MIN_TARGET_DELTA_BPS > 10_000) {
                    revert InvalidNote();
                }
            }
            if (p.x == address(0) || p.x.code.length == 0) revert InvalidNote();
        }
        uint8 class = p.class;
        if (class >= uint8(T.Class.Attested)) revert InvalidNote(); // the panel's class is never self-declared
        if (xResult > 0) class = uint8(T.Class.Traded);
        else if (class == uint8(T.Class.Traded)) class = uint8(T.Class.Declared);
        if (author.code.length > 0) class = uint8(T.Class.Agent);

        bytes32 id = bytes32(++noteCount);
        T.Note storage n = notes[id];
        n.author = author;
        n.x = p.x;
        n.venue = p.venue;
        n.side = p.side;
        n.targetBps = p.targetBps;
        n.horizonDays = p.horizonDays;
        n.class = class;
        n.postedAt = uint64(block.timestamp);
        n.day = _today();
        n.deposit = depositMarg;
        n.parentId = p.parentId;
        n.textHash = keccak256(bytes(p.text));
        notesPerDay[n.day] += 1;
        if (thesis) {
            n.status = T.Status.ThesisOpen;
            if (weekTheses[_week()].length >= MAX_WEEK_THESES) revert InvalidNote();
            weekTheses[_week()].push(id);
        } else {
            n.postPrice = router.postPrice(p.venue, p.side == T.Side.Buy);
            if (n.postPrice == 0) revert InvalidNote(); // the pricer refuses these; never trust a zero baseline
            // The MARG this very swap delivers reaches the author after the callback; count it for a note on MARG.
            n.postBalance = IERC20(p.x).balanceOf(author) + (p.x == token ? margToAuthor : 0);
            if (p.parentId != bytes32(0)) {
                T.Note storage parent = notes[p.parentId];
                if (parent.author != author || parent.status != T.Status.ThesisOpen) revert InvalidNote();
                parent.children += 1;
            }
        }
        records[author].posted += 1;
        emit NotePosted(
            id,
            author,
            p.x,
            class,
            p.side,
            p.targetBps,
            p.horizonDays,
            n.postPrice,
            depositMarg,
            p.parentId,
            xResult,
            p.text
        );
    }

    function pricer() public pure returns (MarginaliaPricer) {
        return MarginaliaPricer(MarginaliaImpls.PRICER);
    }

    function horizonEnd(bytes32 id) public view returns (uint256) {
        T.Note storage n = _note(id);
        return uint256(n.postedAt) + uint256(n.horizonDays) * 1 days;
    }

    /// @notice Anyone records an observation inside the settlement window: the venue's accumulator (v3 / v2)
    /// or spot (v4), the quote leg's spot, and the author's balance. Series slots are spaced by blocks and
    /// capped, but a slot is never owned: while it is taken, a reading more adverse to the call than the
    /// latest one replaces it. So a pump-observe-unwind in one block is overwritten by any honest reading in
    /// the next, and the series must span OBS_MIN_SPAN: a pump has to be held for the whole span.
    function observe(bytes32 id) external {
        T.Note storage n = _note(id);
        if (n.status != T.Status.Open) revert NotOpen();
        uint256 end = horizonEnd(id);
        if (block.timestamp < end) revert TooEarly();
        if (block.timestamp > end + SETTLE_WINDOW) revert TooLate();
        T.Observation[] storage obs = observations[id];
        (uint256 xRead, uint256 quoteRead) = pricer().observe(poolManager, n.venue, imd);
        uint256 balance = _balanceOf(n.x, n.author);
        T.Observation memory o =
            T.Observation(uint64(block.timestamp), uint64(block.number), xRead, quoteRead, balance);
        uint256 len = obs.length;
        if (len > 0 && (len >= OBS_MAX || block.number < obs[len - 1].blockNumber + OBS_GAP_BLOCKS)) {
            if (!_moreAdverse(n, o, obs[len - 1])) revert ObservationTooSoon();
            obs[len - 1] = o;
        } else {
            obs.push(o);
        }
        emit Observed(id, uint64(block.timestamp), xRead, quoteRead, balance);
    }

    /// @dev The author's X balance by staticcall with bounded gas. A read that reverts, re-enters or returns
    /// nothing is recorded as unverifiable (the sentinel), which the hold rule treats as not held: a token the
    /// author can switch off is never a free option on the settlement.
    function _balanceOf(address x, address who) private view returns (uint256) {
        (bool ok, bytes memory ret) =
            x.staticcall{gas: BALANCE_READ_GAS}(abi.encodeWithSelector(IERC20.balanceOf.selector, who));
        if (!ok || ret.length < 32) return type(uint256).max;
        return abi.decode(ret, (uint256));
    }

    /// @dev Whether an observed balance breaks the hold rule: a BUY call must keep its post balance (the
    /// unverifiable sentinel counts as not held). A SELL call has no hold rule and settles on price alone: an
    /// ERC-20 balance can be raised by anyone, so any "must not grow" rule lets a stranger void a correct call
    /// with a gift (revision finding 80c42ce7).
    function _broken(T.Note storage n, uint256 balance) private view returns (bool) {
        if (n.side == T.Side.Sell) return false;
        return balance == type(uint256).max || balance < n.postBalance;
    }

    /// @dev Whether a reading is more adverse to the call than the one it would replace: a worse price (v4:
    /// the venue spot times the quote leg; v3 / v2: the quote leg, the accumulator being a TWAP input), or a
    /// hold breach the earlier reading did not show. A breach is never replaced by a non-breach.
    function _moreAdverse(T.Note storage n, T.Observation memory o, T.Observation memory last)
        private
        view
        returns (bool)
    {
        bool brokenNew = _broken(n, o.balance);
        bool brokenLast = _broken(n, last.balance);
        if (brokenLast && !brokenNew) return false;
        if (brokenNew && !brokenLast) return true;
        bool v4 = n.venue.kind == T.VenueKind.UniV4;
        uint256 pn = v4 ? FullMath.mulDiv(o.xRead, o.quoteRead, 1e18) : o.quoteRead;
        uint256 pl = v4 ? FullMath.mulDiv(last.xRead, last.quoteRead, 1e18) : last.quoteRead;
        return n.side == T.Side.Buy ? pn < pl : pn > pl;
    }

    /// @notice Anyone settles a note once its window has closed. The keeper earns 2% of a forfeited deposit.
    function settle(bytes32 id) external {
        T.Note storage n = _note(id);
        if (n.status != T.Status.Open) revert NotOpen();
        uint256 end = horizonEnd(id);
        if (block.timestamp <= end + SETTLE_WINDOW) revert TooEarly();
        T.Observation[] memory obs = observations[id];
        uint256 count = obs.length;
        T.Status outcome;
        uint256 settlePrice;
        if (count < OBS_MIN || obs[count - 1].timestamp - obs[0].timestamp < OBS_MIN_SPAN) {
            outcome = T.Status.VoidNoData;
        } else {
            bool held = true;
            for (uint256 i = 0; i < count; ++i) {
                if (_broken(n, obs[i].balance)) held = false;
            }
            // A series the pricer cannot turn into a price (a venue that died, a TWAP out of range) is no data.
            try pricer().settlePrice(n.venue, n.side == T.Side.Buy, obs) returns (uint256 price) {
                settlePrice = price;
            } catch {
                settlePrice = 0;
            }
            if (settlePrice == 0) {
                outcome = T.Status.VoidNoData;
            } else if (!held) {
                outcome = T.Status.VoidSold;
            } else if (n.side == T.Side.Buy) {
                outcome = settlePrice * 10_000 >= n.postPrice * n.targetBps ? T.Status.Right : T.Status.Wrong;
            } else {
                outcome = settlePrice * 10_000 <= n.postPrice * n.targetBps ? T.Status.Right : T.Status.Wrong;
            }
        }
        n.status = outcome;
        int256 scoreDelta = 0;
        Record storage r = records[n.author];
        if (outcome == T.Status.Right) {
            scoreDelta = int256(_difficulty(n));
            r.right += 1;
        } else if (outcome == T.Status.VoidNoData) {
            // Unproven scores as wrong (the deposit still comes back): an author cannot post both sides and
            // observe only the one the market confirmed.
            scoreDelta = -int256(_difficulty(n));
        } else if (outcome == T.Status.Wrong) {
            scoreDelta = -int256(_difficulty(n));
            r.wrong += 1;
            _forfeit(n, msg.sender);
        } else if (outcome == T.Status.VoidSold) {
            scoreDelta = -int256(_difficulty(n));
            r.broken += 1;
            _forfeit(n, msg.sender);
        }
        r.score += scoreDelta;
        _bookWeekScore(n.author, scoreDelta);
        _resolveChild(n);
        emit Settled(id, outcome, settlePrice, scoreDelta, msg.sender);
    }

    /// @notice The author withdraws a call before its horizon: the deposit goes to the pot, the reason is public.
    function retract(bytes32 id, string calldata text) external {
        T.Note storage n = _note(id);
        if (msg.sender != n.author) revert Unauthorized();
        if (n.status != T.Status.Open) revert NotOpen();
        if (block.timestamp >= horizonEnd(id)) revert TooLate();
        n.status = T.Status.Retracted;
        int256 scoreDelta = -int256(_difficulty(n) / 2);
        Record storage r = records[n.author];
        r.retracted += 1;
        r.score += scoreDelta;
        _bookWeekScore(n.author, scoreDelta);
        _forfeit(n, address(0));
        _resolveChild(n);
        emit Retracted(id, text);
        emit Settled(id, T.Status.Retracted, 0, scoreDelta, address(0));
    }

    /// @notice A thesis with no child call inside the grace period forfeits its deposit.
    function settleThesis(bytes32 id) external {
        T.Note storage n = _note(id);
        if (n.status != T.Status.ThesisOpen) revert NotOpen();
        if (n.children > 0) revert NotOpen();
        if (block.timestamp <= uint256(n.postedAt) + THESIS_GRACE) revert TooEarly();
        n.status = T.Status.ThesisForfeited;
        _forfeit(n, msg.sender);
        emit ThesisForfeited(id);
    }

    /// @notice A right (or no-data, or released thesis) deposit, returned as MARG, or swapped to IMD fee-free.
    function claimDeposit(bytes32 id, bool asImd) external {
        T.Note storage n = _note(id);
        if (msg.sender != n.author) revert Unauthorized();
        if (
            n.status != T.Status.Right && n.status != T.Status.VoidNoData && n.status != T.Status.ThesisClosed
        ) revert NothingToClaim();
        uint256 amount = n.deposit;
        if (amount == 0) revert NothingToClaim();
        n.deposit = 0;
        if (asImd) {
            _unlock(ACT_SELL, n.author, amount, _minImdOut(amount));
        } else {
            _unlock(ACT_PAY, n.author, amount, uint256(uint160(token)));
        }
        emit DepositClaimed(id, n.author, asImd, amount);
    }

    /// @dev 97% of the pre-swap spot: a bound on what one sale may lose to a sandwich, not a market guarantee.
    function _minImdOut(uint256 marg) private view returns (uint256) {
        return FullMath.mulDiv(marg, margPriceInImd(), 1e18) * 97 / 100;
    }

    function _forfeit(T.Note storage n, address keeper) private {
        uint256 amount = n.deposit;
        n.deposit = 0;
        if (amount == 0) return;
        uint256 reward = keeper == address(0) ? 0 : amount * KEEPER_BPS / 10_000;
        if (reward > 0) _unlock(ACT_PAY, keeper, reward, uint256(uint160(token)));
        potMarg += amount - reward;
    }

    function _resolveChild(T.Note storage n) private {
        if (n.parentId == bytes32(0)) return;
        T.Note storage parent = notes[n.parentId];
        parent.resolvedChildren += 1;
        if (parent.status == T.Status.ThesisOpen) {
            parent.status = T.Status.ThesisClosed;
            emit ThesisReleased(n.parentId);
        }
    }

    // ------------------------------------------------------------------ score

    /// @dev log2(claimed multiple) x sqrt(30 / horizon) x mcap tier, scaled 1e4 (MarginaliaPricer). Only a call
    /// priced on the launch pool scores: on any other canonical venue the author can be the only LP and trader,
    /// choose the price, the multiple and the supply behind the tier, and draw on the leaderboard pool for a
    /// stamp (revision finding c7331916). Such calls still return or forfeit their own deposit on price.
    function _difficulty(T.Note storage n) private view returns (uint256) {
        if (n.venue.kind != T.VenueKind.UniV4 || n.venue.ref != PoolId.unwrap(poolId)) return 0;
        uint256 mcap = FullMath.mulDiv(n.postPrice, IERC20(n.x).totalSupply(), 1e18);
        return pricer().difficulty(n.targetBps, n.side == T.Side.Buy, n.horizonDays, mcap);
    }

    // ------------------------------------------------------------------ pot and judging

    function _today() private view returns (uint32) {
        return uint32(block.timestamp / 1 days);
    }

    function _week() private view returns (uint32) {
        return uint32(block.timestamp / 7 days);
    }

    function today() external view returns (uint32) {
        return _today();
    }

    function week() external view returns (uint32) {
        return _week();
    }

    /// @notice Every thesis posted in a week, by posting order (the judge filters to those with a child call).
    function thesesOfWeek(uint32 w) external view returns (bytes32[] memory) {
        return weekTheses[w];
    }

    function _bookWeekScore(address wallet, int256 delta) private {
        uint32 w = _week();
        int256 prev = weekScore[w][wallet];
        int256 next = prev + delta;
        weekScore[w][wallet] = next;
        uint256 prevPos = prev > 0 ? uint256(prev) : 0;
        uint256 nextPos = next > 0 ? uint256(next) : 0;
        weekTotal[w] = weekTotal[w] + nextPos - prevPos;
    }

    /// @notice Moves ERC-20 IMD from the caller into the pools (the treasury's drip, or anyone's gift).
    function fundPot(uint256 amount) external {
        if (amount == 0) revert PotTooSmall();
        IERC20(imd).safeTransferFrom(msg.sender, address(this), amount);
        _unlock(ACT_FUND, address(0), amount, 0);
        _accrue(amount);
        emit PotFunded(_today(), amount, msg.sender);
    }

    /// @notice Converts forfeited MARG using the router's mature price history for the slippage floor.
    function sellPotMarg(uint256 amount) external returns (uint256 imdOut) {
        if (msg.sender != address(judge)) revert Unauthorized();
        if (amount == 0 || amount > potMarg) revert PotTooSmall();
        potMarg -= amount;
        T.Venue memory venue = T.Venue(T.VenueKind.UniV4, PoolId.unwrap(poolId), imd, !imdIs0);
        uint256 minimum = FullMath.mulDiv(amount, router.postPrice(venue, true), 1e18) * 97 / 100;
        imdOut = _unlock(ACT_SELL, address(0), amount, minimum);
        _accrue(imdOut);
        emit PotMargSold(amount, imdOut, _today());
    }

    /// @notice The judge draws the oracle's price out of a week's thesis pool. The first draw of a week needs
    /// the threshold; a retry after an unanswered request only needs the price.
    function drawForJudging(uint32 w, uint256 amount, bool retry) external {
        if (msg.sender != address(judge)) revert Unauthorized();
        uint256 need = retry ? amount : JUDGE_THRESHOLD;
        if (thesisPool[w] < need || amount > thesisPool[w]) revert PotTooSmall();
        thesisPool[w] -= amount;
        _unlock(ACT_PAY, address(judge), amount, uint256(uint160(imd)));
    }

    /// @notice Who wrote a note and in which week: what the judge needs to filter the panel's ranking.
    function noteMeta(bytes32 id)
        external
        view
        returns (address author, uint32 w, bool thesis, bool hasChild)
    {
        T.Note storage n = notes[id];
        return (n.author, uint32(uint256(n.postedAt) / 7 days), n.targetBps == 0, n.children > 0);
    }

    /// @notice Pays a judged week's thesis pool 50/30/20 to the ranked authors. The judge supplies the ranking.
    function payJudged(uint32 w, bytes32[3] calldata top) external {
        if (msg.sender != address(judge)) revert Unauthorized();
        if (judgedPaid[w]) revert AlreadyPaid();
        judgedPaid[w] = true;
        uint256 pool = thesisPool[w];
        thesisPool[w] = 0;
        uint256[3] memory shares = [pool * 50 / 100, pool * 30 / 100, pool * 20 / 100];
        uint256[3] memory paidAmounts;
        uint256 leftover = pool;
        for (uint256 k = 0; k < 3; ++k) {
            if (top[k] == bytes32(0)) continue;
            address to = notes[top[k]].author;
            records[to].judgedWins += 1;
            _unlock(ACT_PAY, to, shares[k], uint256(uint160(imd)));
            paidAmounts[k] = shares[k];
            leftover -= shares[k];
        }
        if (leftover > 0) thesisPool[_week()] += leftover; // unranked slots roll forward
        emit JudgedPaid(w, paidAmounts);
    }

    /// @notice A wallet's share of a finished week's leaderboard pool: pro-rata by positive score, capped.
    function leaderboardShare(uint32 w, address wallet) public view returns (uint256) {
        int256 s = weekScore[w][wallet];
        if (s <= 0 || weekTotal[w] == 0) return 0;
        uint256 pool = leaderboardPool[w];
        uint256 share = FullMath.mulDiv(pool, uint256(s), weekTotal[w]);
        uint256 cap = pool * LEADERBOARD_CAP_BPS / 10_000;
        return share > cap ? cap : share;
    }

    function claimLeaderboard(uint32 w) external {
        if (w >= _week()) revert TooEarly();
        if (leaderboardClaimed[w][msg.sender]) revert NothingToClaim();
        uint256 amount = leaderboardShare(w, msg.sender);
        if (amount == 0) revert NothingToClaim();
        leaderboardClaimed[w][msg.sender] = true;
        leaderboardPaid[w] += amount;
        _unlock(ACT_PAY, msg.sender, amount, uint256(uint160(imd)));
        emit LeaderboardClaimed(w, msg.sender, amount);
    }

    /// @notice A writer's refund: the day's pool split equally across its notes, at most one stamp each.
    function claimRefund(bytes32 id) external {
        T.Note storage n = _note(id);
        if (msg.sender != n.author) revert Unauthorized();
        if (n.day >= _today()) revert TooEarly();
        if (refundClaimed[id] || n.status == T.Status.Retracted) revert NothingToClaim();
        uint256 count = notesPerDay[n.day];
        uint256 amount = refundPool[n.day] / count;
        if (amount > STAMP) amount = STAMP;
        if (amount == 0) revert NothingToClaim();
        refundClaimed[id] = true;
        refundPool[n.day] -= amount;
        notesPerDay[n.day] = uint32(count - 1);
        _unlock(ACT_PAY, msg.sender, amount, uint256(uint160(imd)));
        emit RefundClaimed(id, msg.sender, amount);
    }

    /// @notice Rolls what an old pool left unclaimed into the current week's leaderboard pool, where it reaches
    /// writers. kind 0 = a day's refund pool, 1 = a week's leaderboard pool, 2 = a week's thesis pool (only once
    /// the judge confirms nothing is pending or judged for it). A swept pool is zeroed, so no claim can draw on it.
    function sweep(uint8 kind, uint32 epoch) external {
        uint256 amount;
        if (kind == 0) {
            if (block.timestamp < (uint256(epoch) + 1) * 1 days + SWEEP_AFTER) revert TooEarly();
            amount = refundPool[epoch];
            refundPool[epoch] = 0;
        } else if (kind == 1) {
            if (block.timestamp < (uint256(epoch) + 1) * 7 days + SWEEP_AFTER) revert TooEarly();
            amount = leaderboardPool[epoch] - leaderboardPaid[epoch];
            leaderboardPool[epoch] = 0;
        } else {
            if (block.timestamp < (uint256(epoch) + 1) * 7 days + SWEEP_AFTER) revert TooEarly();
            if (!judge.weekClosed(epoch)) revert NotOpen();
            amount = thesisPool[epoch];
            thesisPool[epoch] = 0;
        }
        if (amount == 0) revert NothingToSweep();
        leaderboardPool[_week()] += amount;
        emit Swept(kind, epoch, amount);
    }

    // ------------------------------------------------------------------ unlock plumbing

    function _id(address c) private pure returns (uint256) {
        return uint256(uint160(c));
    }

    function _unlock(uint8 action, address to, uint256 amount, uint256 extra)
        private
        returns (uint256 result)
    {
        bytes memory data = abi.encode(action, to, amount, extra);
        unlockHash = keccak256(data);
        bytes memory out = poolManager.unlock(data);
        if (unlockHash != bytes32(0)) revert InvalidUnlock();
        if (out.length == 32) result = abi.decode(out, (uint256));
    }

    function unlockCallback(bytes calldata data) external onlyManager returns (bytes memory) {
        if (unlockHash == bytes32(0) || keccak256(data) != unlockHash) revert InvalidUnlock();
        delete unlockHash;
        (uint8 action, address to, uint256 amount, uint256 extra) =
            abi.decode(data, (uint8, address, uint256, uint256));
        if (action == ACT_PAY) {
            address currency = address(uint160(extra));
            poolManager.burn(address(this), _id(currency), amount);
            poolManager.take(Currency.wrap(currency), to, amount);
            return "";
        }
        if (action == ACT_FUND) {
            Currency c = Currency.wrap(imd);
            poolManager.sync(c);
            IERC20(imd).safeTransfer(address(poolManager), amount);
            poolManager.settle();
            poolManager.mint(address(this), _id(imd), amount);
            return "";
        }
        if (action == ACT_SELL) {
            bool zeroForOne = !imdIs0; // MARG → IMD
            BalanceDelta delta = poolManager.swap(
                pool,
                SwapParams(
                    zeroForOne,
                    -int256(amount),
                    zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                ),
                abi.encode(T.DATA_EXEMPT)
            );
            int128 margDelta = imdIs0 ? delta.amount1() : delta.amount0();
            int128 imdDelta = imdIs0 ? delta.amount0() : delta.amount1();
            if (margDelta >= 0 || imdDelta <= 0) revert InvalidUnlock();
            // Whole fill only, and at least `extra` IMD out (the caller's slippage floor), never an orphaned claim.
            if (uint256(uint128(-margDelta)) != amount) revert InvalidUnlock();
            poolManager.burn(address(this), _id(token), amount);
            uint256 imdOut = uint256(uint128(imdDelta));
            if (imdOut < extra) revert InvalidUnlock();
            if (to == address(0)) {
                poolManager.mint(address(this), _id(imd), imdOut);
            } else {
                poolManager.take(Currency.wrap(imd), to, imdOut);
            }
            return abi.encode(imdOut);
        }
        revert InvalidUnlock();
    }

    // ------------------------------------------------------------------ views

    function _note(bytes32 id) private view returns (T.Note storage n) {
        n = notes[id];
        if (n.author == address(0)) revert UnknownNote();
    }

    function noteOf(bytes32 id) external view returns (T.Note memory) {
        return _note(id);
    }
}
