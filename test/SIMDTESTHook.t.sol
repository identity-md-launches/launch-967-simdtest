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

abstract contract HookIntegration is TestBase {
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
        bytes32 initHash =
            keccak256(abi.encodePacked(type(SIMDTESTHook).creationCode, abi.encode(manager, tokenAddress)));
        for (uint256 i; i < 1_000_000; ++i) {
            bytes32 salt = bytes32(i);
            address predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initHash))))
            );
            if (uint160(predicted) & 0x3fff == 0x20cc && predicted.code.length == 0) {
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
            uint256 volume = buy && exactInput ? amount : rawVolume;
            uint256 antiRate = offset < 10 ? 3000 - 300 * offset : 0;
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
        router.modify(key, 600, 1200, 1e20, bytes32(uint256(1)));
        Observed memory o = _checkTrade(false, true, 1 ether, 0);
        uint256 imdBefore = imd.balanceOf(address(this));
        router.modify(key, 600, 1200, 0, bytes32(uint256(1)));
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
        assertEq(uint256(uint160(address(hook)) & 0x3fff), 0x20cc);
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(
            p.beforeInitialize && p.beforeSwap && p.afterSwap && p.beforeSwapReturnDelta
                && p.afterSwapReturnDelta
        );
        assertTrue(!p.afterInitialize && !p.beforeAddLiquidity && !p.beforeRemoveLiquidity && !p.beforeDonate);
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
            uint256 volume = o.rawImd < 0 ? uint256(-int256(o.rawImd)) : uint256(int256(o.rawImd));
            assertTrue(volume < 1e25);
            assertEq(o.volume, volume);
            assertEq(o.treasury, volume / 200);
            assertEq(o.donation + o.treasury, volume * 3050 / 10_000);
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
        router.modify(key, -60, 60, int256(uint256(LIQUIDITY)), 0);
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
