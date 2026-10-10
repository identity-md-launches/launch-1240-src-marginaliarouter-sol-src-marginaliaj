// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Marginalia} from "src/Marginalia.sol";
import {MarginaliaHook} from "src/MarginaliaHook.sol";
import {MarginaliaRouter} from "src/MarginaliaRouter.sol";
import {MarginaliaJudge} from "src/MarginaliaJudge.sol";
import {MarginaliaTreasury} from "src/MarginaliaTreasury.sol";
import {MarginaliaPricer} from "src/MarginaliaPricer.sol";
import {MarginaliaImpls} from "src/MarginaliaImpls.sol";
import {MarginaliaTypes as T} from "src/MarginaliaTypes.sol";
import {HookFlags} from "src/HookFlags.sol";

contract PotToken is ERC20 {
    constructor(string memory n, uint256 supply) ERC20(n, n) {
        _mint(msg.sender, supply);
    }
}

contract PotLiquidity is IUnlockCallback {
    IPoolManager public immutable manager;

    constructor(IPoolManager m) {
        manager = m;
    }

    function add(PoolKey memory key, int24 lower, int24 upper, int256 amount) external {
        manager.unlock(abi.encode(key, ModifyLiquidityParams(lower, upper, amount, bytes32(0))));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (PoolKey memory key, ModifyLiquidityParams memory p) =
            abi.decode(data, (PoolKey, ModifyLiquidityParams));
        (BalanceDelta d,) = manager.modifyLiquidity(key, p, "");
        _pay(key.currency0, d.amount0());
        _pay(key.currency1, d.amount1());
        return "";
    }

    function _pay(Currency c, int128 d) private {
        if (d < 0) {
            manager.sync(c);
            IERC20(Currency.unwrap(c)).transfer(address(manager), uint256(uint128(-d)));
            manager.settle();
        }
    }
}

/// @title Revision finding 70ce87bf: a pot that outgrows one sale converts in tranches (the reviewer's proof,
/// kept as the regression). On a modest launch pool (1000e18 liquidity on [-6000, 6000]) the whole 36.9 MARG pot
/// fails the 97%-of-window-maximum floor, so convertForfeits now sells the largest halving the pool absorbs and
/// keeps going on later calls until the pot is empty.
contract PotTrancheTest is Test {
    using PoolIdLibrary for PoolKey;

    IPoolManager manager;
    Marginalia token;
    PotToken imd;
    MarginaliaHook hook;
    MarginaliaRouter router;
    MarginaliaJudge judge;
    PoolKey key;
    address alice = makeAddr("alice");

    function setUp() public {
        vm.warp(1_800_000_000);
        vm.roll(20_000_000);
        manager = IPoolManager(address(new PoolManager(address(this))));
        token = new Marginalia();
        imd = new PotToken("IMD", 1_000_000_000 ether);
        vm.etch(MarginaliaImpls.ROUTER_IMPL, address(new MarginaliaRouter()).code);
        vm.etch(MarginaliaImpls.JUDGE_IMPL, address(new MarginaliaJudge()).code);
        vm.etch(MarginaliaImpls.TREASURY_IMPL, address(new MarginaliaTreasury()).code);
        vm.etch(MarginaliaImpls.PRICER, address(new MarginaliaPricer()).code);
        bytes memory code = abi.encodePacked(
            type(MarginaliaHook).creationCode, abi.encode(manager, address(token), address(this))
        );
        bytes32 h = keccak256(code);
        for (uint256 i = 0; i < 300_000; ++i) {
            address predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(i), h))))
            );
            if (!HookFlags.matches(predicted, HookFlags.MARGINALIA)) continue;
            bytes32 salt = bytes32(i);
            address deployed;
            assembly ("memory-safe") {
                deployed := create2(0, add(code, 32), mload(code), salt)
            }
            require(deployed == predicted, "deploy");
            hook = MarginaliaHook(deployed);
            break;
        }
        router = hook.router();
        judge = hook.judge();
        bool margIs0 = address(token) < address(imd);
        (address c0, address c1) = margIs0 ? (address(token), address(imd)) : (address(imd), address(token));
        key = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 12500, 60, IHooks(address(hook)));
        manager.initialize(key, uint160(1 << 96));
        PotLiquidity liq = new PotLiquidity(manager);
        token.transfer(address(liq), 10_000 ether);
        imd.transfer(address(liq), 10_000 ether);
        // A modest launch pool: 1000e18 of liquidity on [-6000, 6000] at 1 MARG = 1 IMD (~260 MARG in range).
        liq.add(key, -6000, 6000, 1000 ether);
        imd.transfer(alice, 10_000 ether);
        vm.prank(alice);
        imd.approve(address(router), type(uint256).max);
        router.checkpointVenue(_margNote(), key);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.roll(vm.getBlockNumber() + 300);
    }

    function _margNote() internal view returns (T.NoteParams memory p) {
        p.x = address(token);
        p.venue = T.Venue(T.VenueKind.UniV4, PoolId.unwrap(key.toId()), address(0), false);
        p.side = T.Side.Buy;
        p.targetBps = 20_000;
        p.horizonDays = 7;
        p.class = uint8(T.Class.Declared);
        p.text = "2x";
    }

    function testForfeitedPotCanStillBeConvertedOnceItOutgrowsOneSale() public {
        // 80 posted-and-retracted calls: each forfeits its ~0.49 MARG deposit to the pot.
        for (uint256 i = 0; i < 80; ++i) {
            vm.prank(alice);
            router.note(_margNote(), key, 1 ether, 1, vm.getBlockTimestamp() + 1);
            bytes32 id = bytes32(hook.noteCount());
            vm.prank(alice);
            hook.retract(id, "out");
        }
        uint256 pot = hook.potMarg();
        emit log_named_uint("potMarg", pot);
        assertGt(pot, 30 ether);

        // A fresh, honest, mature price window (the old one expired), so the floor is 97% of the current price.
        vm.warp(vm.getBlockTimestamp() + 7 hours);
        vm.roll(vm.getBlockNumber() + 2100);
        router.checkpointVenue(_margNote(), key);
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        vm.roll(vm.getBlockNumber() + 600);

        // Expected: at least part of the pot converts. Actual: the whole-pot sale reverts and the pot never shrinks.
        try judge.convertForfeits() returns (uint256 imdOut) {
            emit log_named_uint("imdOut", imdOut);
        } catch (bytes memory reason) {
            emit log_named_bytes("convertForfeits reverted", reason);
        }
        assertLt(hook.potMarg(), pot, "forfeited MARG is stranded in the pot: nothing converts");
        uint256 remaining = hook.potMarg();
        assertGt(remaining, 0); // a tranche, not the whole pot
        // Each sale lowers the price under the 97%-of-window-maximum floor, so the rest converts, tranche by
        // tranche, once a fresh window has matured at the new level: the pot drains, nothing is stranded.
        for (uint256 i = 0; i < 12 && hook.potMarg() > 0; ++i) {
            vm.warp(vm.getBlockTimestamp() + 7 hours);
            vm.roll(vm.getBlockNumber() + 2100);
            router.checkpointVenue(_margNote(), key);
            vm.warp(vm.getBlockTimestamp() + 2 hours);
            vm.roll(vm.getBlockNumber() + 600);
            uint256 before = hook.potMarg();
            judge.convertForfeits();
            assertLt(hook.potMarg(), before);
        }
        assertEq(hook.potMarg(), 0);
    }

    function testWhenNoTrancheSellsTheHookReasonSurfaces() public {
        vm.prank(alice);
        router.note(_margNote(), key, 1 ether, 1, vm.getBlockTimestamp() + 1);
        bytes32 id = bytes32(hook.noteCount());
        vm.prank(alice);
        hook.retract(id, "out");
        vm.warp(vm.getBlockTimestamp() + 7 hours); // the window expired and nothing replaced it
        vm.expectRevert(MarginaliaPricer.PriceHistoryUnavailable.selector);
        judge.convertForfeits();
    }
}
