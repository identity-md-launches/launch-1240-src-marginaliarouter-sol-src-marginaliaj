// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MarginaliaTypes as T} from "./MarginaliaTypes.sol";
import {MarginaliaPricer} from "./MarginaliaPricer.sol";

interface IMarginaliaHook {
    function getPoolKey() external view returns (PoolKey memory);
    function imd() external view returns (address);
    function token() external view returns (address);
    function pricer() external view returns (MarginaliaPricer);
}

interface IUniswapV3PoolSwap {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function liquidity() external view returns (uint128);
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}

interface IUniswapV3FactoryMinimal {
    function getPool(address a, address b, uint24 fee) external view returns (address);
}

interface IUniswapV2PairSwap {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface IUniswapV2FactoryMinimal {
    function getPair(address a, address b) external view returns (address);
}

/// @notice The only path that can attach a note to a MARG swap (plain buys and sells of MARG work through any
/// v4 router; the hook taxes sells wherever they come from). Funds are pulled only from msg.sender and never
/// held between transactions. Optionally trades X in the same transaction, on Uniswap v4, v3 or v2, so the
/// note's position is proven rather than claimed. Every venue — the trade's and the note's price venue — must
/// be a canonical Uniswap pool that actually contains the note's token; the hook trusts only what this
/// contract hands it.
contract MarginaliaRouter is IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager public manager;
    IMarginaliaHook public hook;

    uint8 public constant X_NONE = 0;
    uint8 public constant X_V4 = 1;
    uint8 public constant X_V3 = 2;
    uint8 public constant X_V2 = 3;

    /// @dev Ethereum mainnet canonical factories; the price venue and the trade venue are checked against them.
    address public constant UNIV3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address public constant UNIV2_FACTORY = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    /// @dev One X trade. v4 uses `key` + `zeroForOne`; v3 and v2 use `pool` + `tokenIn`.
    struct XTrade {
        uint8 kind;
        PoolKey key;
        bool zeroForOne;
        address pool;
        address tokenIn;
        uint256 amountIn;
        uint256 minOut;
    }

    struct Job {
        address payer;
        bool sellMarg; // false: buy MARG with IMD and note; true: sell MARG for IMD and note (the 1% path)
        uint256 amountIn;
        uint256 minOut;
        XTrade x;
        uint256 xResult; // set before unlock for v3/v2 legs
        address xIn;
        address xOut;
        T.NoteParams note;
    }

    bytes32 private jobHash;
    address private v3Pending;
    mapping(bytes32 => T.PriceWindow) public priceWindows;

    error UnauthorizedCallback();
    error InvalidSwap();
    error Slippage();
    error Expired();
    error NoteTokenMismatch();
    error AlreadyInitialised();
    error BadVenue();
    error OnlyHook();

    event Noted(address indexed author, bool sellMarg, uint256 spent, uint256 received);
    event XTraded(
        address indexed trader,
        uint8 kind,
        address indexed xIn,
        address indexed xOut,
        uint256 spent,
        uint256 received
    );
    event VenueCheckpointed(bytes32 indexed venue, uint64 startedAt);

    /// @dev The implementation locks itself; only clones (zero storage) can be initialised, once, by the hook.
    constructor() {
        hook = IMarginaliaHook(address(1));
    }

    function init(IPoolManager manager_, address hook_) external {
        if (address(hook) != address(0)) revert AlreadyInitialised();
        if (msg.sender != hook_) revert OnlyHook();
        require(address(manager_).code.length > 0 && hook_ != address(0), "configuration required");
        manager = manager_;
        hook = IMarginaliaHook(hook_);
    }

    // ------------------------------------------------------------------ entry points

    /// @notice Anyone may begin or extend a canonical venue's price history before posting a call.
    /// The first checkpoint must age for an hour; checkpoints expire after six hours. A live
    /// window cannot be reset, so an honest spot pins its conservative extreme until expiry.
    function checkpointVenue(T.NoteParams memory p, PoolKey memory v4Key) external nonReentrant {
        T.Venue memory v = validateVenue(p, v4Key);
        bytes32 id = keccak256(abi.encode(v));
        T.PriceWindow memory w = hook.pricer().checkpoint(manager, v, hook.imd(), priceWindows[id]);
        priceWindows[id] = w;
        emit VenueCheckpointed(id, w.startedAt);
    }

    /// @notice Read the baseline using this router's authenticated, prior venue checkpoints.
    function postPrice(T.Venue memory v, bool buy) external view returns (uint256) {
        return hook.pricer().postPrice(manager, v, hook.imd(), buy, priceWindows[keccak256(abi.encode(v))]);
    }

    /// @notice Post a note by buying MARG. Class is Declared unless the author is a contract (Agent).
    /// @param v4Key For a v4 price venue, the full pool key (ignored otherwise).
    function note(
        T.NoteParams calldata p,
        PoolKey calldata v4Key,
        uint256 imdIn,
        uint256 minMargOut,
        uint256 deadline
    ) external nonReentrant returns (uint256) {
        XTrade memory noX;
        return _run(false, imdIn, minMargOut, deadline, noX, p, v4Key);
    }

    /// @notice Sell MARG with a note attached: 1% plus the stamp instead of the quiet 3%, and the deposit
    /// comes off the MARG sold.
    function sellWithNote(
        T.NoteParams calldata p,
        PoolKey calldata v4Key,
        uint256 margIn,
        uint256 minImdOut,
        uint256 deadline
    ) external nonReentrant returns (uint256) {
        XTrade memory noX;
        return _run(true, margIn, minImdOut, deadline, noX, p, v4Key);
    }

    /// @notice Trade X (v4, v3 or v2) and post the note about it in one transaction (class Traded).
    function tradeAndNote(
        XTrade calldata x,
        T.NoteParams calldata p,
        PoolKey calldata v4Key,
        uint256 imdIn,
        uint256 minMargOut,
        uint256 deadline
    ) external nonReentrant returns (uint256) {
        if (x.kind == X_NONE) revert InvalidSwap();
        return _run(false, imdIn, minMargOut, deadline, x, p, v4Key);
    }

    // ------------------------------------------------------------------ venue validation

    /// @notice Checks a note's price venue and fills the derived fields (`xIsToken0`, `quote`) from the pool
    /// itself. The pool must be canonical (v4: the full key recomputes the id, hookless or this hook, with
    /// liquidity; v3/v2: the factory's pool for the pair), contain X, and be quoted in IMD, WETH or native.
    function validateVenue(T.NoteParams memory p, PoolKey memory key) public view returns (T.Venue memory v) {
        v = p.venue;
        address imd = hook.imd();
        address t0;
        address t1;
        if (v.kind == T.VenueKind.UniV4) {
            if (PoolId.unwrap(key.toId()) != v.ref) revert BadVenue();
            if (address(key.hooks) != address(0) && address(key.hooks) != address(hook)) revert BadVenue();
            if (manager.getLiquidity(PoolId.wrap(v.ref)) == 0) revert BadVenue();
            t0 = Currency.unwrap(key.currency0);
            t1 = Currency.unwrap(key.currency1);
        } else if (v.kind == T.VenueKind.UniV3) {
            IUniswapV3PoolSwap pool = IUniswapV3PoolSwap(address(uint160(uint256(v.ref))));
            t0 = pool.token0();
            t1 = pool.token1();
            if (IUniswapV3FactoryMinimal(UNIV3_FACTORY).getPool(t0, t1, pool.fee()) != address(pool)) {
                revert BadVenue();
            }
            if (pool.liquidity() == 0) revert BadVenue(); // an empty v3 pool's tick moves for free
        } else if (v.kind == T.VenueKind.UniV2) {
            IUniswapV2PairSwap pair = IUniswapV2PairSwap(address(uint160(uint256(v.ref))));
            t0 = pair.token0();
            t1 = pair.token1();
            if (IUniswapV2FactoryMinimal(UNIV2_FACTORY).getPair(t0, t1) != address(pair)) revert BadVenue();
        } else {
            revert BadVenue();
        }
        if (p.x == t0) {
            v.xIsToken0 = true;
            v.quote = t1;
        } else if (p.x == t1) {
            v.xIsToken0 = false;
            v.quote = t0;
        } else {
            revert BadVenue();
        }
        if (v.quote != imd && v.quote != WETH && v.quote != address(0)) revert BadVenue();
    }

    // ------------------------------------------------------------------ core

    function _run(
        bool sellMarg,
        uint256 amountIn,
        uint256 minOut,
        uint256 deadline,
        XTrade memory x,
        T.NoteParams memory p,
        PoolKey memory v4Key
    ) private returns (uint256 received) {
        if (block.timestamp > deadline) revert Expired();
        if (amountIn == 0 || amountIn > uint256(uint128(type(int128).max))) revert InvalidSwap();
        if (p.targetBps != 0) p.venue = validateVenue(p, v4Key); // a thesis has no price venue
        address input = sellMarg ? hook.token() : hook.imd();
        uint256 got = _pull(input, amountIn);

        Job memory job;
        job.payer = msg.sender;
        job.sellMarg = sellMarg;
        job.amountIn = got;
        job.minOut = minOut;
        job.x = x;
        job.note = p;

        if (x.kind != X_NONE) {
            if (x.amountIn == 0) revert InvalidSwap();
            if (x.kind == X_V4) {
                address xIn = Currency.unwrap(x.zeroForOne ? x.key.currency0 : x.key.currency1);
                if (xIn == address(0)) revert InvalidSwap();
                x.amountIn = _pull(xIn, x.amountIn);
                job.x = x; // traded inside the unlock
            } else {
                x.amountIn = _pull(x.tokenIn, x.amountIn);
                (job.xResult, job.xIn, job.xOut) =
                    x.kind == X_V3 ? _tradeV3(msg.sender, x) : _tradeV2(msg.sender, x);
                _checkSubject(job);
            }
        }

        bytes memory data = abi.encode(job);
        jobHash = keccak256(data);
        received = abi.decode(manager.unlock(data), (uint256));
        delete jobHash;
    }

    /// @dev Pulls `amount` and returns what actually arrived (fee-on-transfer safe).
    function _pull(address token, uint256 amount) private returns (uint256 got) {
        uint256 before = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        got = IERC20(token).balanceOf(address(this)) - before;
        if (got == 0) revert InvalidSwap();
    }

    function _checkSubject(Job memory job) private pure {
        address subject = job.note.side == T.Side.Buy ? job.xOut : job.xIn;
        if (subject != job.note.x) revert NoteTokenMismatch();
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager) || jobHash == bytes32(0) || keccak256(data) != jobHash) {
            revert UnauthorizedCallback();
        }
        delete jobHash;
        Job memory job = abi.decode(data, (Job));
        if (job.x.kind == X_V4) {
            (job.xResult, job.xIn, job.xOut) = _tradeV4(job.payer, job.x);
            _checkSubject(job);
        }

        PoolKey memory key = hook.getPoolKey();
        address imd = hook.imd();
        bool imd0 = Currency.unwrap(key.currency0) == imd;
        bool zeroForOne = job.sellMarg ? !imd0 : imd0; // IMD in / MARG out, or the reverse
        bytes memory hookData = abi.encode(T.DATA_NOTE, job.note, job.payer, job.xResult);

        BalanceDelta delta = manager.swap(
            key,
            SwapParams(
                zeroForOne,
                -int256(job.amountIn),
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            hookData
        );
        int128 inputDelta = zeroForOne ? delta.amount0() : delta.amount1();
        int128 outputDelta = zeroForOne ? delta.amount1() : delta.amount0();
        if (inputDelta >= 0 || outputDelta <= 0) revert InvalidSwap();
        uint256 spent = uint256(uint128(-inputDelta));
        uint256 received = uint256(uint128(outputDelta));
        if (spent > job.amountIn || received < job.minOut) revert Slippage();
        Currency payCurrency = zeroForOne ? key.currency0 : key.currency1;
        Currency receiveCurrency = zeroForOne ? key.currency1 : key.currency0;
        _pay(payCurrency, spent);
        manager.take(receiveCurrency, job.payer, received);
        if (spent < job.amountIn) {
            IERC20(Currency.unwrap(payCurrency)).safeTransfer(job.payer, job.amountIn - spent);
        }
        emit Noted(job.payer, job.sellMarg, spent, received);
        return abi.encode(received);
    }

    // ------------------------------------------------------------------ X legs

    function _tradeV4(address payer, XTrade memory x)
        private
        returns (uint256 received, address xIn, address xOut)
    {
        // A v4 trade venue must be a real pool: liquidity and a hookless or Marginalia-hooked key.
        if (address(x.key.hooks) != address(0) && address(x.key.hooks) != address(hook)) revert BadVenue();
        if (manager.getLiquidity(x.key.toId()) == 0) revert BadVenue();
        BalanceDelta delta = manager.swap(
            x.key,
            SwapParams(
                x.zeroForOne,
                -int256(x.amountIn),
                x.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            ""
        );
        int128 inputDelta = x.zeroForOne ? delta.amount0() : delta.amount1();
        int128 outputDelta = x.zeroForOne ? delta.amount1() : delta.amount0();
        if (inputDelta >= 0 || outputDelta <= 0) revert InvalidSwap();
        uint256 spent = uint256(uint128(-inputDelta));
        received = uint256(uint128(outputDelta));
        if (spent > x.amountIn || received < x.minOut) revert Slippage();
        Currency payCurrency = x.zeroForOne ? x.key.currency0 : x.key.currency1;
        Currency receiveCurrency = x.zeroForOne ? x.key.currency1 : x.key.currency0;
        _pay(payCurrency, spent);
        manager.take(receiveCurrency, payer, received);
        if (spent < x.amountIn) IERC20(Currency.unwrap(payCurrency)).safeTransfer(payer, x.amountIn - spent);
        xIn = Currency.unwrap(payCurrency);
        xOut = Currency.unwrap(receiveCurrency);
        emit XTraded(payer, X_V4, xIn, xOut, spent, received);
    }

    /// @dev Exact-input swap against a canonical v3 pool; the pool pays the recipient, we pay in the callback.
    function _tradeV3(address payer, XTrade memory x)
        private
        returns (uint256 received, address xIn, address xOut)
    {
        IUniswapV3PoolSwap pool = IUniswapV3PoolSwap(x.pool);
        address t0 = pool.token0();
        address t1 = pool.token1();
        if (IUniswapV3FactoryMinimal(UNIV3_FACTORY).getPool(t0, t1, pool.fee()) != x.pool) revert BadVenue();
        bool zeroForOne = x.tokenIn == t0;
        if (!zeroForOne && x.tokenIn != t1) revert InvalidSwap();
        xIn = x.tokenIn;
        xOut = zeroForOne ? t1 : t0;
        uint256 before = IERC20(xOut).balanceOf(payer);
        v3Pending = x.pool;
        (int256 a0, int256 a1) = pool.swap(
            payer,
            zeroForOne,
            int256(x.amountIn),
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
            ""
        );
        delete v3Pending;
        uint256 spent = uint256(zeroForOne ? a0 : a1);
        received = IERC20(xOut).balanceOf(payer) - before;
        if (received < x.minOut || received == 0 || spent > x.amountIn) revert Slippage();
        if (spent < x.amountIn) IERC20(xIn).safeTransfer(payer, x.amountIn - spent);
        emit XTraded(payer, X_V3, xIn, xOut, spent, received);
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        if (msg.sender != v3Pending || v3Pending == address(0)) revert UnauthorizedCallback();
        IUniswapV3PoolSwap pool = IUniswapV3PoolSwap(msg.sender);
        if (amount0Delta > 0) IERC20(pool.token0()).safeTransfer(msg.sender, uint256(amount0Delta));
        if (amount1Delta > 0) IERC20(pool.token1()).safeTransfer(msg.sender, uint256(amount1Delta));
    }

    /// @dev Exact-input swap against a canonical v2 pair: send the input, take the constant-product output.
    function _tradeV2(address payer, XTrade memory x)
        private
        returns (uint256 received, address xIn, address xOut)
    {
        IUniswapV2PairSwap pair = IUniswapV2PairSwap(x.pool);
        address t0 = pair.token0();
        address t1 = pair.token1();
        if (IUniswapV2FactoryMinimal(UNIV2_FACTORY).getPair(t0, t1) != x.pool) revert BadVenue();
        bool zeroForOne = x.tokenIn == t0;
        if (!zeroForOne && x.tokenIn != t1) revert InvalidSwap();
        xIn = x.tokenIn;
        xOut = zeroForOne ? t1 : t0;
        (uint112 r0, uint112 r1,) = pair.getReserves();
        (uint256 rIn, uint256 rOut) = zeroForOne ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        uint256 pairBefore = IERC20(xIn).balanceOf(x.pool);
        IERC20(xIn).safeTransfer(x.pool, x.amountIn);
        uint256 actualIn = IERC20(xIn).balanceOf(x.pool) - pairBefore; // fee-on-transfer safe
        uint256 inWithFee = actualIn * 997;
        uint256 out = inWithFee * rOut / (rIn * 1000 + inWithFee);
        if (out == 0) revert Slippage();
        uint256 before = IERC20(xOut).balanceOf(payer);
        pair.swap(zeroForOne ? 0 : out, zeroForOne ? out : 0, payer, "");
        received = IERC20(xOut).balanceOf(payer) - before;
        if (received < x.minOut || received == 0) revert Slippage();
        emit XTraded(payer, X_V2, xIn, xOut, actualIn, received);
    }

    function _pay(Currency c, uint256 amount) private {
        manager.sync(c);
        IERC20(Currency.unwrap(c)).safeTransfer(address(manager), amount);
        if (manager.settle() != amount) revert InvalidSwap();
    }
}
