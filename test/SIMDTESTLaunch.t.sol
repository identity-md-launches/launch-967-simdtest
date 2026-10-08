// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TestBase} from "./helpers/TestBase.sol";
import {MockIMD} from "./helpers/MockIMD.sol";
import {SIMDTEST} from "../src/SIMDTEST.sol";
import {SIMDTESTHook} from "../src/SIMDTESTHook.sol";
import {SIMDTESTLaunch} from "../src/SIMDTESTLaunch.sol";
import {MineHook} from "../script/MineHook.s.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolRouter} from "./helpers/PoolRouter.sol";

contract SIMDTESTLaunchTest is TestBase {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    address private constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    uint160 private constant Q96 = 1 << 96;
    IPoolManager private manager;
    SIMDTESTLaunch private launcher;
    SIMDTEST private token;
    MockIMD private imd;
    bytes32 private salt;
    address private predicted;

    function setUp() public {
        vm.roll(200);
        vm.etch(IMD, address(new MockIMD()).code);
        imd = MockIMD(IMD);
        imd.mint(address(this), 1e33);
        manager = IPoolManager(address(new PoolManager(address(this))));
        launcher = new SIMDTESTLaunch(manager);
        token = launcher.token();
        (salt, predicted) = new MineHook().run(launcher, 0, 1_000_000);
        imd.approve(address(launcher), 1e33);
    }

    function test_AtomicLaunchDistributionAndRealPoolLiquidity() public {
        assertEq(token.balanceOf(token.DEAD()), 100_000_000 ether);
        assertEq(token.balanceOf(address(launcher)), 900_000_000 ether);
        SIMDTESTHook hook = launcher.launch(Q96, 800_000_001 ether, salt);
        assertEq(address(hook), predicted);
        assertEq(launcher.predictHook(salt), predicted);
        assertTrue(hook.liquidityGateEnabled());
        assertEq(uint256(uint160(address(hook)) & 0x3fff), uint256(hook.HOOK_FLAGS()));
        assertTrue(launcher.launched());
        assertEq(token.balanceOf(address(manager)), 800_000_000 ether);
        assertEq(token.balanceOf(address(this)), 100_000_000 ether);
        assertEq(token.balanceOf(address(launcher)), 0);
        assertEq(token.balanceOf(token.DEAD()), 100_000_000 ether);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(imd.balanceOf(address(launcher)), 0);
        assertTrue(imd.balanceOf(address(manager)) > 799_999_999 ether);
        assertEq(manager.getLiquidity(hook.poolId()), launcher.liquidityForSeed(Q96));
        assertEq(hook.openingBlock(), block.number);
        assertEq(hook.initializer(), address(launcher));
        assertEq(manager.currencyDelta(address(launcher), Currency.wrap(IMD)), 0);
        assertEq(manager.currencyDelta(address(launcher), Currency.wrap(address(token))), 0);
        // The launched hook really governs swaps in the seeded pool.
        PoolRouter router = new PoolRouter(manager);
        token.approve(address(router), 1 ether);
        uint256 beforeTreasury = imd.balanceOf(hook.TREASURY());
        bool zeroForOne = address(token) < IMD;
        router.swap(
            hook.poolKey(),
            IPoolManager.SwapParams(
                zeroForOne, -1 ether, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            )
        );
        assertTrue(imd.balanceOf(hook.TREASURY()) > beforeTreasury);
    }

    function testFuzz_SeedingAtDifferentPrices(int16 priceTick) public {
        uint160 price = TickMath.getSqrtPriceAtTick(int24(priceTick));
        SIMDTESTHook hook = launcher.launch(price, 1e33, salt);
        assertEq(token.balanceOf(address(manager)), 800_000_000 ether);
        assertEq(token.balanceOf(address(this)), 100_000_000 ether);
        assertTrue(manager.getLiquidity(hook.poolId()) > 0);
    }

    function test_OnlyInitiatorCanLaunchAndNoSecondLaunch() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(SIMDTESTLaunch.OnlyLaunchInitiator.selector);
        launcher.launch(Q96, 1e33, salt);
        launcher.launch(Q96, 1e33, salt);
        vm.expectRevert(SIMDTESTLaunch.AlreadyLaunched.selector);
        launcher.launch(Q96, 1e33, salt);
    }

    function test_SeedBudgetFailureRollsBackHookAndPool() public {
        vm.expectRevert(SIMDTESTLaunch.ImdBudgetExceeded.selector);
        launcher.launch(Q96, 1, salt);
        _assertUnlaunched();
        launcher.launch(Q96, 1e33, salt);
    }

    function test_TransferFailureRollsBackAndCanRetry() public {
        imd.setFail(true);
        vm.expectRevert(SIMDTESTLaunch.TransferFailed.selector);
        launcher.launch(Q96, 1e33, salt);
        _assertUnlaunched();
        imd.setFail(false);
        launcher.launch(Q96, 1e33, salt);
    }

    function test_FeeOnTransferPairRejectedDuringSeeding() public {
        imd.setTax(true);
        vm.expectRevert(SIMDTESTLaunch.SettlementMismatch.selector);
        launcher.launch(Q96, 1e33, salt);
        _assertUnlaunched();
    }

    function test_NoApprovalFailsSafely() public {
        imd.approve(address(launcher), 0);
        vm.expectRevert(SIMDTESTLaunch.TransferFailed.selector);
        launcher.launch(Q96, 1e33, salt);
        _assertUnlaunched();
    }

    function test_RejectsInvalidPricesAndBadSalt() public {
        vm.expectRevert(SIMDTESTLaunch.InvalidPriceOrLiquidity.selector);
        launcher.launch(0, 1e33, salt);
        vm.expectRevert(SIMDTESTLaunch.InvalidPriceOrLiquidity.selector);
        launcher.launch(TickMath.getSqrtPriceAtTick(887220), 1e33, salt);
        bytes32 badSalt = bytes32(uint256(salt) + 1);
        while (
            uint160(launcher.predictHook(badSalt)) & 0x3fff == 0x28cc
                || uint160(launcher.predictHook(badSalt)) & 0x3fff == 0x20cc
        ) {
            badSalt = bytes32(uint256(badSalt) + 1);
        }
        vm.expectRevert();
        launcher.launch(Q96, 1e33, badSalt);
        _assertUnlaunched();
    }

    function test_CallbackUnauthorizedOrOutsideLaunchFails() public {
        vm.expectRevert(SIMDTESTLaunch.OnlySeedingCallback.selector);
        launcher.unlockCallback("");
        vm.prank(address(manager));
        vm.expectRevert(SIMDTESTLaunch.OnlySeedingCallback.selector);
        launcher.unlockCallback("");
    }

    function test_PredictedPoolCannotBeInitializedBeforeHookDeployment() public {
        bool tokenIs0 = address(token) < IMD;
        PoolKey memory key = PoolKey(
            Currency.wrap(tokenIs0 ? address(token) : IMD),
            Currency.wrap(tokenIs0 ? IMD : address(token)),
            12_500,
            60,
            IHooks(predicted)
        );
        vm.expectRevert();
        manager.initialize(key, Q96);
        SIMDTESTHook hook = launcher.launch(Q96, 1e33, salt);
        assertTrue(hook.opened());
    }

    function test_SeedingReentryCannotReopenLaunch() public {
        imd.setReentry(address(launcher), abi.encodeCall(launcher.launch, (Q96, 1e33, salt)));
        launcher.launch(Q96, 1e33, salt);
        assertTrue(imd.reentered());
        assertTrue(!imd.reentrySucceeded());
    }

    function test_NoPositionWithdrawalOrConfigurationMethods() public {
        launcher.launch(Q96, 1e33, salt);
        (bool withdrawOk,) = address(launcher).call(abi.encodeWithSignature("withdraw()"));
        (bool ownerOk,) = address(launcher).call(abi.encodeWithSignature("owner()"));
        assertTrue(!withdrawOk && !ownerOk);
    }

    function test_DeploymentSizeWithinLimits() public view {
        assertTrue(type(SIMDTESTLaunch).creationCode.length + 32 <= 49_152);
        assertTrue(address(launcher).code.length <= 24_576);
    }

    function _assertUnlaunched() private view {
        assertTrue(!launcher.launched());
        assertEq(address(launcher.hook()), address(0));
        assertEq(predicted.code.length, 0);
        assertEq(token.balanceOf(address(launcher)), 900_000_000 ether);
        assertEq(token.balanceOf(address(manager)), 0);
        assertEq(imd.balanceOf(address(manager)), 0);
    }
}
