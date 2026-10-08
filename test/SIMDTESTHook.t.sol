// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TestBase, Vm} from "./helpers/TestBase.sol";
import {MockIMD} from "./helpers/MockIMD.sol";
import {PoolRouter} from "./helpers/PoolRouter.sol";
import {SIMDTEST} from "../src/SIMDTEST.sol";
import {SIMDTESTHook} from "../src/SIMDTESTHook.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";

abstract contract HookIntegration is TestBase, IUnlockCallback {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using BeforeSwapDeltaLibrary for *;

    address internal constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address internal constant TREASURY = 0x3dD5F73dD1A4E62630fAd3909673F130aD429985;
    uint160 internal constant Q96 = 1 << 96;
    uint128 internal constant LIQUIDITY = 1e24;
    bytes32 internal constant SWAP_TOPIC =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    bytes32 internal constant DONATE_TOPIC = keccak256("Donate(bytes32,address,uint256,uint256)");
    bytes32 internal constant FEES_TOPIC = keccak256("FeesCharged(bytes32,address,uint256,uint256,uint256)");

    IPoolManager internal manager;
    SIMDTEST internal token;
    MockIMD internal imd;
    SIMDTESTHook internal hook;
    PoolRouter internal router;
    PoolKey internal key;
    uint256 internal openedAt;

    function tokenHigher() internal pure virtual returns (bool);

    function setUp() public {
        vm.roll(100);
        MockIMD implementation = new MockIMD();
        vm.etch(IMD, address(implementation).code);
        imd = MockIMD(IMD);
        imd.mint(address(this), 1e32);
        manager = IPoolManager(address(new PoolManager(address(this))));
        do {
            token = new SIMDTEST();
        } while ((address(token) > IMD) != tokenHigher());
        hook = _deployHook(address(token));
        key = hook.poolKey();
        manager.initialize(key, Q96);
        openedAt = block.number;
        router = new PoolRouter(manager);
        token.approve(address(router), 900_000_000 ether);
        imd.approve(address(router), 1e32);
        router.modify(key, -887220, 887220, int256(uint256(LIQUIDITY)), 0);
    }

    function _deployHook(address tokenAddress) internal returns (SIMDTESTHook result) {
        return _deployHookWithFlags(tokenAddress, 0x28cc);
    }

    function _deployHookWithFlags(address tokenAddress, uint160 flags)
        internal
        returns (SIMDTESTHook result)
    {
        bytes32 initHash = keccak256(
            abi.encodePacked(type(SIMDTESTHook).creationCode, abi.encode(manager, tokenAddress))
        );
        for (uint256 i; i < 1_000_000; ++i) {
            bytes32 salt = bytes32(i);
            address predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initHash))))
            );
            if (uint160(predicted) & 0x3fff == flags && predicted.code.length == 0) {
                result = new SIMDTESTHook{salt: salt}(manager, tokenAddress);
                assertEq(address(result), predicted);
                return result;
            }
        }
        revert("salt search failed");
    }

    function _params(bool buy, bool exactInput, uint256 amount)
        internal
        view
        returns (IPoolManager.SwapParams memory)
    {
        bool zeroForOne = buy == hook.imdIsCurrency0();
        return IPoolManager.SwapParams(
            zeroForOne,
            exactInput ? -int256(amount) : int256(amount),
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
    }

    struct Observed {
        int128 rawImd;
        uint256 volume;
        uint256 donation;
        uint256 treasury;
        uint256 donated;
        uint256 donations;
    }

    function _observe() internal returns (Observed memory o) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool swapFound;
        bool feesFound;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == SWAP_TOPIC) {
                (int128 amount0, int128 amount1,,,,) =
                    abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                o.rawImd = hook.imdIsCurrency0() ? amount0 : amount1;
                swapFound = true;
            } else if (logs[i].emitter == address(manager) && logs[i].topics[0] == DONATE_TOPIC) {
                assertEq(logs[i].topics[1], PoolId.unwrap(hook.poolId()));
                assertEq(address(uint160(uint256(logs[i].topics[2]))), address(hook));
                (uint256 amount0, uint256 amount1) = abi.decode(logs[i].data, (uint256, uint256));
                o.donated = hook.imdIsCurrency0() ? amount0 : amount1;
                assertEq(hook.imdIsCurrency0() ? amount1 : amount0, 0);
                ++o.donations;
            } else if (logs[i].emitter == address(hook) && logs[i].topics[0] == FEES_TOPIC) {
                (o.volume, o.donation, o.treasury) = abi.decode(logs[i].data, (uint256, uint256, uint256));
                feesFound = true;
            }
        }
        assertTrue(swapFound && feesFound);
    }

    struct Before {
        uint256 trader;
        uint256 managerBalance;
        uint256 treasury;
        uint256 growth;
    }

    function _imdGrowth() private view returns (uint256) {
        (uint256 g0, uint256 g1) = manager.getFeeGrowthGlobals(hook.poolId());
        return hook.imdIsCurrency0() ? g0 : g1;
    }

    function _checkTrade(bool buy, bool exactInput, uint256 amount, uint256 offset)
        internal
        returns (Observed memory o)
    {
        vm.roll(openedAt + offset);
        Before memory b = Before(
            imd.balanceOf(address(this)),
            imd.balanceOf(address(manager)),
            imd.balanceOf(TREASURY),
            _imdGrowth()
        );
        vm.recordLogs();
        BalanceDelta result = router.swap(key, _params(buy, exactInput, amount));
        o = _observe();
        {
            uint256 rawVolume = o.rawImd < 0 ? uint256(-int256(o.rawImd)) : uint256(int256(o.rawImd));
            uint256 antiRate = offset < 10 ? 3000 - 300 * offset : 0;
            // Buys use the gross IMD outlay as the base in both modes; sells use the gross pool output.
            uint256 volume = buy ? (exactInput ? amount : _grossForNet(rawVolume, antiRate + 50)) : rawVolume;
            if (buy && !exactInput) assertEq(volume - volume * (antiRate + 50) / 10_000, rawVolume);
            uint256 expectedTreasury = volume * 50 / 10_000;
            uint256 expectedDonation = volume * (antiRate + 50) / 10_000 - expectedTreasury;
            assertEq(o.volume, volume);
            assertEq(o.treasury, expectedTreasury);
            assertEq(o.donation, expectedDonation);
            assertEq(o.donated, expectedDonation);
            assertEq(o.donations, expectedDonation == 0 ? 0 : 1);
            assertEq(imd.balanceOf(TREASURY) - b.treasury, expectedTreasury);
            int128 finalImd = hook.imdIsCurrency0() ? result.amount0() : result.amount1();
            assertEq(int256(finalImd), int256(o.rawImd) - int256(expectedTreasury + expectedDonation));
            assertEq(int256(imd.balanceOf(address(this))) - int256(b.trader), int256(finalImd));
            assertEq(
                imd.balanceOf(address(manager)) + imd.balanceOf(address(this)) + imd.balanceOf(TREASURY),
                b.managerBalance + b.trader + b.treasury
            );
            assertEq(imd.balanceOf(address(hook)), 0);
            assertEq(token.balanceOf(address(hook)), 0);
            assertEq(manager.currencyDelta(address(hook), Currency.wrap(IMD)), 0);
            assertEq(manager.currencyDelta(address(router), Currency.wrap(IMD)), 0);
            assertEq(manager.currencyDelta(address(hook), Currency.wrap(address(token))), 0);
            uint256 donatedGrowth = (expectedDonation << 128) / LIQUIDITY;
            uint256 actualGrowth = _imdGrowth() - b.growth;
            if (buy) assertTrue(actualGrowth >= donatedGrowth); // Includes the independent LP fee on IMD input.
            else assertEq(actualGrowth, donatedGrowth); // LP fee is in SIMDTEST on sells.
        }
        int128 output = buy == hook.imdIsCurrency0() ? result.amount1() : result.amount0();
        int128 input = buy == hook.imdIsCurrency0() ? result.amount0() : result.amount1();
        if (exactInput) assertEq(uint256(-int256(input)), amount);
        else assertEq(uint256(int256(output)), amount);
    }

    function _grossForNet(uint256 net, uint256 rate) internal pure returns (uint256) {
        return net == 0 ? 0 : (net - 1) * 10_000 / (10_000 - rate) + 1;
    }

    function test_AllTenBlocksAndBoundary_AllSwapModes() public {
        for (uint256 offset; offset <= 11; ++offset) {
            uint256 snapshot = vm.snapshotState();
            for (uint256 mode; mode < 4; ++mode) {
                _checkTrade(mode < 2, mode % 2 == 0, 1 ether, offset);
            }
            assertTrue(vm.revertToState(snapshot));
        }
    }

    function testFuzz_FeeConservation(bool buy, bool exactInput, uint96 amountSeed, uint16 elapsed) public {
        _checkTrade(buy, exactInput, uint256(amountSeed) % 1e21 + 10_000, uint256(elapsed) % 100);
    }

    function testFuzz_ExactOutputGrossUpRounding(uint64 amountSeed, uint8 elapsed) public {
        _checkTrade(false, false, uint256(amountSeed) + 2, uint256(elapsed) % 12);
    }

    function test_DonationAccruesOnlyToInRangeLiquidity() public {
        // Narrow out-of-range liquidity seeded through the initializer path, as a factory could.
        _initializerModify(600, 1200, 1e20);
        Observed memory o = _checkTrade(false, true, 1 ether, 0);
        uint256 imdBefore = imd.balanceOf(address(this));
        _initializerModify(600, 1200, 0);
        assertEq(imd.balanceOf(address(this)), imdBefore);
        router.modify(key, -887220, 887220, 0, 0);
        uint256 collected = imd.balanceOf(address(this)) - imdBefore;
        assertLe(collected, o.donation);
        assertLe(o.donation - collected, 2);
    }

    function test_AfterTenBlocksNeverRestarts() public {
        _checkTrade(true, true, 1 ether, 10);
        _checkTrade(false, true, 1 ether, 1_000_000);
        assertEq(hook.openingBlock(), openedAt);
        assertEq(hook.antiSnipeBps(), 0);
    }

    function test_OneWeiSwapHasNoRoundedFee() public {
        _checkTrade(true, true, 1, 0);
    }

    function test_InitializationAndPermissions() public view {
        assertTrue(hook.opened());
        assertEq(hook.openingBlock(), openedAt);
        assertEq(uint256(uint160(address(hook)) & 0x3fff), 0x28cc);
        assertEq(uint256(hook.HOOK_FLAGS()), 0x28cc);
        assertTrue(hook.liquidityGateEnabled());
        assertEq(int256(hook.MIN_TICK()), int256(TickMath.minUsableTick(hook.TICK_SPACING())));
        assertEq(int256(hook.MAX_TICK()), int256(TickMath.maxUsableTick(hook.TICK_SPACING())));
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(
            p.beforeInitialize && p.beforeAddLiquidity && p.beforeSwap && p.afterSwap
                && p.beforeSwapReturnDelta && p.afterSwapReturnDelta
        );
        assertTrue(!p.afterInitialize && !p.afterAddLiquidity && !p.beforeRemoveLiquidity && !p.beforeDonate);
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(hook.initializer(), address(this));
        assertEq(hook.token(), address(token));
    }

    function test_OnlyManagerCallbacks() public {
        IPoolManager.SwapParams memory params = _params(true, true, 1 ether);
        vm.expectRevert(SIMDTESTHook.OnlyPoolManager.selector);
        hook.beforeInitialize(address(this), key, Q96);
        vm.expectRevert(SIMDTESTHook.OnlyPoolManager.selector);
        hook.beforeSwap(address(this), key, params, "");
        vm.expectRevert(SIMDTESTHook.OnlyPoolManager.selector);
        hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), "");
        vm.expectRevert(SIMDTESTHook.OnlyPoolManager.selector);
        hook.beforeAddLiquidity(address(this), key, _liquidityParams(-887220, 887220, 1), "");
    }

    function _liquidityParams(int24 lower, int24 upper, int256 delta)
        internal
        pure
        returns (IPoolManager.ModifyLiquidityParams memory)
    {
        return IPoolManager.ModifyLiquidityParams(lower, upper, delta, 0);
    }

    function _gateRevert() internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            IHooks.beforeAddLiquidity.selector,
            abi.encodeWithSelector(SIMDTESTHook.OnlyFullRangeDuringAntiSnipe.selector),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    function test_SameBuyPaysSameFeesInBothModes() public {
        for (uint256 offset; offset <= 10; offset += 5) {
            uint256 snapshot = vm.snapshotState();
            vm.roll(openedAt + offset);
            vm.recordLogs();
            BalanceDelta exactIn = router.swap(key, _params(true, true, 100 ether));
            Observed memory a = _observe();
            uint256 received = uint256(int256(hook.imdIsCurrency0() ? exactIn.amount1() : exactIn.amount0()));
            assertTrue(vm.revertToState(snapshot));
            snapshot = vm.snapshotState();
            vm.roll(openedAt + offset);
            vm.recordLogs();
            BalanceDelta exactOut = router.swap(key, _params(true, false, received));
            Observed memory b = _observe();
            uint256 paid = uint256(-int256(hook.imdIsCurrency0() ? exactOut.amount0() : exactOut.amount1()));
            assertLe(paid, 100 ether);
            assertLe(100 ether - paid, 2);
            assertLe(a.treasury > b.treasury ? a.treasury - b.treasury : b.treasury - a.treasury, 2);
            assertLe(a.donation > b.donation ? a.donation - b.donation : b.donation - a.donation, 2);
            assertLe(a.volume > b.volume ? a.volume - b.volume : b.volume - a.volume, 2);
            assertTrue(vm.revertToState(snapshot));
        }
    }

    function test_LiquidityGateOnlyFullRangeDuringAntiSnipe() public {
        for (uint256 offset; offset < 10; ++offset) {
            vm.roll(openedAt + offset);
            assertTrue(hook.antiSnipeBps() != 0);
            vm.expectRevert(_gateRevert());
            router.modify(key, -60, 60, 1e18, 0);
            vm.expectRevert(_gateRevert());
            router.modify(key, -887220, 887160, 1e18, 0);
            vm.expectRevert(_gateRevert());
            router.modify(key, -887160, 887220, 1e18, 0);
            router.modify(key, -887220, 887220, 1e18, bytes32(uint256(offset + 1)));
            router.modify(key, -887220, 887220, -1e18, bytes32(uint256(offset + 1)));
        }
        vm.roll(openedAt + 10);
        assertEq(hook.antiSnipeBps(), 0);
        router.modify(key, -60, 60, 1e18, 0);
        router.modify(key, -60, 60, -1e18, 0);
    }

    function test_LiquidityGateIgnoresOtherPools() public {
        PoolKey memory wrong = key;
        wrong.fee = 3000;
        vm.prank(address(manager));
        vm.expectRevert(SIMDTESTHook.WrongPool.selector);
        hook.beforeAddLiquidity(address(this), wrong, _liquidityParams(-887220, 887220, 1), "");
    }

    function test_InitializerMaySeedAnyRangeDuringAntiSnipe() public {
        assertEq(hook.initializer(), address(this));
        _initializerModify(-60, 60, 1e18);
        vm.expectRevert(_gateRevert());
        router.modify(key, -60, 60, 1e18, 0);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        assertEq(msg.sender, address(manager));
        (int24 lower, int24 upper, int256 delta) = abi.decode(data, (int24, int24, int256));
        (BalanceDelta d,) = manager.modifyLiquidity(key, _liquidityParams(lower, upper, delta), "");
        _pay(key.currency0, d.amount0());
        _pay(key.currency1, d.amount1());
        return "";
    }

    function _pay(Currency currency, int128 amount) private {
        if (amount > 0) {
            manager.take(currency, address(this), uint256(int256(amount)));
        } else if (amount < 0) {
            manager.sync(currency);
            MockIMD(Currency.unwrap(currency)).transfer(address(manager), uint256(-int256(amount)));
            manager.settle();
        }
    }

    /// @dev Adds or collects a position as the initializer, which the gate exempts (factory seeding).
    function _initializerModify(int24 lower, int24 upper, int256 delta) internal {
        manager.unlock(abi.encode(lower, upper, delta));
    }

    struct Attack {
        uint256 baselineSpent;
        uint256 baselineGot;
        int24 endTick;
        uint256 jitSpent;
        uint256 jitGot;
    }

    function _buyNet(uint256 amount) private returns (uint256 spent, uint256 got) {
        uint256 i0 = imd.balanceOf(address(this));
        uint256 t0 = token.balanceOf(address(this));
        router.swap(key, _params(true, true, amount));
        spent = i0 - imd.balanceOf(address(this));
        got = token.balanceOf(address(this)) - t0;
    }

    /// @dev The reviewer's attack: single-sided SIMDTEST liquidity at the buy's end tick, buy, remove.
    function test_JitAtEndTickCannotRecoverOwnAntiSnipeFee() public {
        router.modify(key, -887220, 887220, int256(8e26 - uint256(LIQUIDITY)), 0);
        Attack memory a;
        uint256 snapshot = vm.snapshotState();
        (a.baselineSpent, a.baselineGot) = _buyNet(100_000_000 ether);
        (, a.endTick,,) = manager.getSlot0(hook.poolId());
        assertTrue(vm.revertToState(snapshot));
        int24 lower = (a.endTick / 60) * 60;
        if (a.endTick < 0 && a.endTick % 60 != 0) lower -= 60;
        vm.expectRevert(_gateRevert());
        router.modify(key, lower, lower + 60, 9 * 8e26, bytes32(uint256(7)));
        (a.jitSpent, a.jitGot) = _buyNet(100_000_000 ether);
        assertEq(a.jitSpent, a.baselineSpent);
        assertEq(a.jitGot, a.baselineGot);
        // Once the window closes, the same position is allowed but there is no donation to capture.
        vm.roll(openedAt + 10);
        router.modify(key, lower, lower + 60, 1e24, bytes32(uint256(7)));
        router.modify(key, lower, lower + 60, -1e24, bytes32(uint256(7)));
    }

    /// @dev A full-range JIT is still possible but bounded by real two-sided capital: with 100M SIMDTEST
    /// (the entire non-pool, non-dead supply) against an 800M seed the recovery is about 1/9 of the donation.
    function test_FullRangeJitRecoveryIsBoundedByCapital() public {
        router.modify(key, -887220, 887220, int256(8e26 - uint256(LIQUIDITY)), 0);
        Attack memory a;
        uint256 snapshot = vm.snapshotState();
        (a.baselineSpent, a.baselineGot) = _buyNet(100_000_000 ether);
        assertTrue(vm.revertToState(snapshot));
        uint256 i0 = imd.balanceOf(address(this));
        uint256 t0 = token.balanceOf(address(this));
        router.modify(key, -887220, 887220, 1e26, bytes32(uint256(7)));
        assertLe(t0 - token.balanceOf(address(this)), 100_000_000 ether);
        _buyNet(100_000_000 ether);
        router.modify(key, -887220, 887220, -1e26, bytes32(uint256(7)));
        uint256 netSpent = i0 - imd.balanceOf(address(this));
        uint256 netGot = token.balanceOf(address(this)) - t0;
        uint256 baselinePrice = a.baselineSpent * 1e18 / a.baselineGot;
        uint256 jitPrice = netSpent * 1e18 / netGot;
        // Measured locally: about 0.8% off the baseline price, versus 27% for the end-tick attack.
        assertLe(baselinePrice - jitPrice, baselinePrice * 2 / 100);
        uint256 recovered = baselinePrice * netGot / 1e18 - netSpent;
        assertLe(recovered, uint256(30_000_000 ether) / 9);
    }

    function test_UngatedAddressValidatesButHasNoGate() public {
        SIMDTESTHook ungated = _deployHookWithFlags(address(token), 0x20cc);
        assertTrue(!ungated.liquidityGateEnabled());
        assertTrue(!ungated.getHookPermissions().beforeAddLiquidity);
        assertEq(uint256(uint160(address(ungated)) & 0x3fff), uint256(ungated.HOOK_FLAGS_UNGATED()));
        PoolKey memory ungatedKey = ungated.poolKey();
        manager.initialize(ungatedKey, Q96);
        assertTrue(ungated.antiSnipeBps() != 0);
        router.modify(ungatedKey, -60, 60, 1e18, 0);
        // Direct calls still enforce the rule; the manager simply never makes them at this address.
        vm.prank(address(manager));
        vm.expectRevert(SIMDTESTHook.OnlyFullRangeDuringAntiSnipe.selector);
        ungated.beforeAddLiquidity(address(router), ungatedKey, _liquidityParams(-60, 60, 1), "");
    }

    function test_OnlyInitializerCanOpen() public {
        SIMDTESTHook fresh = _deployHook(address(token));
        PoolKey memory freshKey = fresh.poolKey();
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        manager.initialize(freshKey, Q96);
        assertTrue(!fresh.opened());
        assertEq(fresh.antiSnipeBps(), 0);
        manager.initialize(freshKey, Q96);
        assertTrue(fresh.opened());
    }

    function test_SwapBeforeOpenRejected() public {
        SIMDTESTHook fresh = _deployHook(address(token));
        PoolKey memory freshKey = fresh.poolKey();
        IPoolManager.SwapParams memory params = _params(true, true, 1 ether);
        vm.prank(address(manager));
        vm.expectRevert(SIMDTESTHook.NotOpened.selector);
        fresh.beforeSwap(address(this), freshKey, params, "");
    }

    function test_SecondInitializationRejected() public {
        vm.expectRevert();
        manager.initialize(key, Q96);
        assertEq(hook.openingBlock(), openedAt);
    }

    function test_WrongFeeSpacingTokenAndHookRejected() public {
        PoolKey memory wrong = key;
        wrong.fee = 3000;
        _rejectKey(wrong);
        wrong = hook.poolKey();
        wrong.tickSpacing = 10;
        _rejectKey(wrong);
        wrong = hook.poolKey();
        wrong.currency0 = Currency.wrap(address(0));
        _rejectKey(wrong);
        wrong = hook.poolKey();
        wrong.hooks = IHooks(address(0));
        _rejectKey(wrong);
    }

    function _rejectKey(PoolKey memory wrong) private {
        IPoolManager.SwapParams memory params = _params(true, true, 1 ether);
        vm.prank(address(manager));
        vm.expectRevert(SIMDTESTHook.WrongPool.selector);
        hook.beforeInitialize(address(this), wrong, Q96);
        vm.prank(address(manager));
        vm.expectRevert(SIMDTESTHook.WrongPool.selector);
        hook.beforeSwap(address(this), wrong, params, "");
        vm.prank(address(manager));
        vm.expectRevert(SIMDTESTHook.WrongPool.selector);
        hook.afterSwap(address(this), wrong, params, BalanceDelta.wrap(0), "");
    }

    function test_InvalidAmountsRejected() public {
        IPoolManager.SwapParams memory params = _params(true, true, 1 ether);
        int256[4] memory invalid =
            [int256(0), type(int256).min, type(int256).max, -int256(type(int128).max) - 1];
        for (uint256 i; i < invalid.length; ++i) {
            params.amountSpecified = invalid[i];
            vm.prank(address(manager));
            vm.expectRevert(SIMDTESTHook.InvalidAmount.selector);
            hook.beforeSwap(address(this), key, params, "");
        }
    }

    function test_SpecifiedImdPartialFillsRevertAtomically() public {
        for (uint256 mode; mode < 2; ++mode) {
            bool buy = mode == 0;
            IPoolManager.SwapParams memory params = _params(buy, buy, 1e25);
            params.sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(params.zeroForOne ? int24(-1) : int24(1));
            (uint160 priceBefore,,,) = manager.getSlot0(hook.poolId());
            uint256 treasuryBefore = imd.balanceOf(TREASURY);
            vm.expectRevert();
            router.swap(key, params);
            (uint160 priceAfter,,,) = manager.getSlot0(hook.poolId());
            assertEq(uint256(priceAfter), uint256(priceBefore));
            assertEq(imd.balanceOf(TREASURY), treasuryBefore);
        }
    }

    function test_UnspecifiedImdPartialFillChargesActualVolume() public {
        for (uint256 mode; mode < 2; ++mode) {
            uint256 snapshot = vm.snapshotState();
            bool buy = mode == 0;
            IPoolManager.SwapParams memory params = _params(buy, !buy, 1e25);
            params.sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(params.zeroForOne ? int24(-1) : int24(1));
            vm.recordLogs();
            router.swap(key, params);
            Observed memory o = _observe();
            uint256 raw = o.rawImd < 0 ? uint256(-int256(o.rawImd)) : uint256(int256(o.rawImd));
            assertTrue(raw < 1e25);
            uint256 volume = buy ? _grossForNet(raw, 3050) : raw;
            assertEq(o.volume, volume);
            assertEq(o.treasury, volume / 200);
            assertEq(o.donation + o.treasury, volume * 3050 / 10_000);
            if (buy) assertEq(volume - o.donation - o.treasury, raw);
            assertTrue(vm.revertToState(snapshot));
        }
    }

    function test_FailedTreasuryTransferRollsBackSwapAndDonation() public {
        (uint160 beforePrice,,,) = manager.getSlot0(hook.poolId());
        (uint256 before0, uint256 before1) = manager.getFeeGrowthGlobals(hook.poolId());
        imd.setFail(true);
        IPoolManager.SwapParams memory params = _params(false, true, 1 ether);
        vm.expectRevert();
        router.swap(key, params);
        (uint160 afterPrice,,,) = manager.getSlot0(hook.poolId());
        (uint256 after0, uint256 after1) = manager.getFeeGrowthGlobals(hook.poolId());
        assertEq(uint256(beforePrice), uint256(afterPrice));
        assertEq(before0, after0);
        assertEq(before1, after1);
        assertEq(imd.balanceOf(TREASURY), 0);
    }

    function test_TokenCannotReenterHookCallbacks() public {
        imd.setReentry(address(hook), abi.encodeCall(hook.beforeInitialize, (address(this), key, Q96)));
        _checkTrade(false, true, 1 ether, 0);
        assertTrue(imd.reentered());
        assertTrue(!imd.reentrySucceeded());
    }

    function test_SlippageFailureRollsBackTreasury() public {
        IPoolManager.SwapParams memory params = _params(true, true, 1 ether);
        vm.expectRevert(PoolRouter.Slippage.selector);
        router.swapWithLimits(key, params, 1 ether, 1 ether);
        assertEq(imd.balanceOf(TREASURY), 0);
    }

    function test_NoActiveLiquidityFailsCleanly() public {
        router.modify(key, -887220, 887220, -int256(uint256(LIQUIDITY)), 0);
        IPoolManager.SwapParams memory params = _params(true, true, 1 ether);
        vm.expectRevert();
        router.swap(key, params);
        assertEq(imd.balanceOf(TREASURY), 0);
    }

    function test_DonationCannotBeDivertedWhenSwapExhaustsActiveLiquidity() public {
        router.modify(key, -887220, 887220, -int256(uint256(LIQUIDITY)), 0);
        _initializerModify(-60, 60, int256(uint256(LIQUIDITY)));
        IPoolManager.SwapParams memory params = _params(false, true, 1e25);
        (uint160 beforePrice,,,) = manager.getSlot0(hook.poolId());
        vm.expectRevert();
        router.swap(key, params);
        (uint160 afterPrice,,,) = manager.getSlot0(hook.poolId());
        assertEq(uint256(afterPrice), uint256(beforePrice));
        assertEq(imd.balanceOf(TREASURY), 0);
    }

    function test_HookHasNoAdminOrUpgradeSelectors() public {
        (bool ownerOk,) = address(hook).call(abi.encodeWithSignature("owner()"));
        (bool pauseOk,) = address(hook).call(abi.encodeWithSignature("pause()"));
        (bool upgradeOk,) = address(hook).call(abi.encodeWithSignature("upgradeTo(address)", address(this)));
        (bool setterOk,) = address(hook).call(abi.encodeWithSignature("setTreasury(address)", address(this)));
        assertTrue(!ownerOk && !pauseOk && !upgradeOk && !setterOk);
    }

    function test_InvalidConstructors() public {
        vm.expectRevert(SIMDTESTHook.InvalidDeployment.selector);
        new SIMDTESTHook(IPoolManager(address(0)), address(token));
        vm.expectRevert(SIMDTESTHook.InvalidDeployment.selector);
        new SIMDTESTHook(manager, address(0));
        vm.expectRevert(SIMDTESTHook.InvalidDeployment.selector);
        new SIMDTESTHook(manager, IMD);
    }

    function test_BytecodeSizeLimits() public view {
        assertTrue(type(SIMDTESTHook).creationCode.length + 64 <= 49_152);
        assertTrue(address(hook).code.length <= 24_576);
    }
}

contract SIMDTESTHookImdCurrency0Test is HookIntegration {
    function tokenHigher() internal pure override returns (bool) {
        return true;
    }
}

contract SIMDTESTHookImdCurrency1Test is HookIntegration {
    function tokenHigher() internal pure override returns (bool) {
        return false;
    }
}
