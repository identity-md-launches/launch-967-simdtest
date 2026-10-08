// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TestBase, Vm} from "./helpers/TestBase.sol";
import {MockIMD} from "./helpers/MockIMD.sol";
import {PoolRouter} from "./helpers/PoolRouter.sol";
import {SIMDTEST} from "../src/SIMDTEST.sol";
import {SIMDTESTHook} from "../src/SIMDTESTHook.sol";
import {SIMDTESTLaunch} from "../src/SIMDTESTLaunch.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

/// @notice Adversarial edge cases for the hook that the integration suite does not already pin down:
/// the brief's fixed values, deployment at a wrong flag set, fee arithmetic at its bounds, direct
/// callback misuse, the opening event, and the absence of delegatecall/selfdestruct in runtime code.
contract SIMDTESTHookEdgeTest is TestBase {
    address private constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address private constant TREASURY = 0x3dD5F73dD1A4E62630fAd3909673F130aD429985;
    uint160 private constant Q96 = 1 << 96;
    uint128 private constant LIQUIDITY = 1e24;
    bytes32 private constant DONATE_TOPIC = keccak256("Donate(bytes32,address,uint256,uint256)");
    bytes32 private constant FEES_TOPIC = keccak256("FeesCharged(bytes32,address,uint256,uint256,uint256)");
    bytes32 private constant OPENED_TOPIC = keccak256("PoolOpened(bytes32,uint256)");

    IPoolManager private manager;
    SIMDTEST private token;
    MockIMD private imd;
    SIMDTESTHook private hook;
    PoolRouter private router;
    PoolKey private key;
    uint256 private openedAt;

    function setUp() public {
        vm.roll(300);
        vm.etch(IMD, address(new MockIMD()).code);
        imd = MockIMD(IMD);
        imd.mint(address(this), 1e32);
        manager = IPoolManager(address(new PoolManager(address(this))));
        token = new SIMDTEST();
        hook = _deployHookWithFlags(0x28cc);
        key = hook.poolKey();
        manager.initialize(key, Q96);
        openedAt = block.number;
        router = new PoolRouter(manager);
        token.approve(address(router), type(uint256).max);
        imd.approve(address(router), type(uint256).max);
        router.modify(key, -887_220, 887_220, int256(uint256(LIQUIDITY)), 0);
    }

    function _mineSalt(uint160 flags) private view returns (bytes32 salt, address predicted) {
        bytes32 initHash =
            keccak256(abi.encodePacked(type(SIMDTESTHook).creationCode, abi.encode(manager, address(token))));
        for (uint256 i; i < 2_000_000; ++i) {
            salt = bytes32(i);
            predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initHash))))
            );
            if (uint160(predicted) & 0x3fff == flags && predicted.code.length == 0) return (salt, predicted);
        }
        revert("salt search failed");
    }

    function _deployHookWithFlags(uint160 flags) private returns (SIMDTESTHook) {
        (bytes32 salt, address predicted) = _mineSalt(flags);
        SIMDTESTHook deployed = new SIMDTESTHook{salt: salt}(manager, address(token));
        assertEq(address(deployed), predicted);
        return deployed;
    }

    function _params(bool buy, bool exactInput, uint256 amount)
        private
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

    function test_BriefValuesAreFixedInSource() public view {
        // The brief's addresses, compared numerically so the comparison does not depend on checksum casing.
        assertEq(uint256(uint160(hook.IMD())), uint256(0x00d34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7));
        assertEq(uint256(uint160(hook.TREASURY())), uint256(0x003dd5f73dd1a4e62630fad3909673f130ad429985));
        assertEq(hook.TREASURY_BPS(), 50);
        assertEq(hook.MAX_ANTI_SNIPE_BPS(), 3_000);
        assertEq(hook.ANTI_SNIPE_BLOCKS(), 10);
        assertEq(hook.BPS(), 10_000);
        assertEq(uint256(hook.HOOK_FLAGS()), 0x28cc);
        assertEq(uint256(hook.HOOK_FLAGS_UNGATED()), 0x20cc);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.decimals(), 18);
        assertEq(MockIMD(IMD).decimals(), 18);
    }

    /// @dev Any flag set other than the two documented ones is rejected by the constructor, so a
    /// mis-mined salt cannot produce a hook the PoolManager calls with a different callback set.
    function test_HookAddressWithExtraOrMissingFlagBitRejected() public {
        uint160[4] memory wrong =
            [uint160(0x28cc | 0x0010), 0x28cc | 0x1000, 0x28cc ^ 0x0080, 0x28cc ^ 0x0004];
        for (uint256 i; i < wrong.length; ++i) {
            (bytes32 salt, address predicted) = _mineSalt(wrong[i]);
            vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
            new SIMDTESTHook{salt: salt}(manager, address(token));
        }
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_FeesOnNeverExceedsScheduleAndTreasuryIsExact(uint128 gross, uint8 offsetSeed) public {
        uint256 offset = offsetSeed % 16;
        vm.roll(openedAt + offset);
        uint256 rate = offset < 10 ? 3_000 - 300 * offset : 0;
        assertEq(hook.antiSnipeBps(), rate);
        if (gross > uint128(type(int128).max)) {
            vm.expectRevert(SIMDTESTHook.InvalidAmount.selector);
            hook.feesOn(gross);
            return;
        }
        (uint256 donation, uint256 treasuryFee) = hook.feesOn(gross);
        assertEq(treasuryFee, uint256(gross) * 50 / 10_000);
        assertEq(donation + treasuryFee, uint256(gross) * (rate + 50) / 10_000);
        assertLe(donation + treasuryFee, uint256(gross) * 3_050 / 10_000);
        if (offset >= 10) assertEq(donation, 0);
        assertLe(donation + treasuryFee, gross);
    }

    function test_FeesOnBoundary() public {
        (uint256 donation, uint256 treasuryFee) = hook.feesOn(uint256(uint128(type(int128).max)));
        assertEq(treasuryFee, uint256(uint128(type(int128).max)) * 50 / 10_000);
        assertEq(donation + treasuryFee, uint256(uint128(type(int128).max)) * 3_050 / 10_000);
        vm.expectRevert(SIMDTESTHook.InvalidAmount.selector);
        hook.feesOn(uint256(uint128(type(int128).max)) + 1);
        (donation, treasuryFee) = hook.feesOn(0);
        assertEq(donation + treasuryFee, 0);
        // Sub-unit treasury fee rounds to zero; the aggregate is floored once, so the residual stays in the donation.
        (donation, treasuryFee) = hook.feesOn(199);
        assertEq(treasuryFee, 0);
        assertEq(donation, uint256(199) * 3_050 / 10_000);
        (donation, treasuryFee) = hook.feesOn(200);
        assertEq(treasuryFee, 1);
        assertEq(donation, 60);
    }

    /// @dev An exact-output sell asks for a net IMD amount; grossing up the maximum int128 would overflow
    /// the specified-delta domain, so the quote reverts instead of wrapping.
    function test_ExactOutputSellTooLargeToGrossUpRejected() public {
        IPoolManager.SwapParams memory params = _params(false, false, uint256(uint128(type(int128).max)));
        vm.prank(address(manager));
        vm.expectRevert(SIMDTESTHook.InvalidAmount.selector);
        hook.beforeSwap(address(router), key, params, "");
        // One below the limit is still representable after the fee at the opening rate.
        params = _params(false, false, uint256(uint128(type(int128).max)) * 6_950 / 10_000 - 10);
        vm.prank(address(manager));
        hook.beforeSwap(address(router), key, params, "");
    }

    /// @dev Direct afterSwap calls reporting an executed IMD amount that differs from the quote revert,
    /// in both IMD-specified modes, at every nonzero and zero anti-snipe rate.
    function test_AfterSwapExecutedDeltaMismatchRejected() public {
        for (uint256 offset; offset <= 10; offset += 5) {
            vm.roll(openedAt + offset);
            uint256 rate = offset < 10 ? 3_000 - 300 * offset : 0;
            // Exact-input buy of 1 ether: the pool must have consumed exactly 1 ether minus the fee.
            IPoolManager.SwapParams memory params = _params(true, true, 1 ether);
            uint256 fee = 1 ether * (rate + 50) / 10_000;
            int128[3] memory executed = [int128(-1 ether), -int128(int256(1 ether - fee)) - 1, int128(0)];
            for (uint256 i; i < executed.length; ++i) {
                BalanceDelta delta = _imdDelta(executed[i]);
                vm.prank(address(manager));
                vm.expectRevert(SIMDTESTHook.PartialFillUnsupported.selector);
                hook.afterSwap(address(router), key, params, delta, "");
            }
            // Exact-output sell of 1 ether net: the pool must have produced the grossed-up amount.
            params = _params(false, false, 1 ether);
            uint256 gross = (1 ether - 1) * 10_000 / (10_000 - rate - 50) + 1;
            executed = [int128(1 ether), int128(int256(gross)) + 1, int128(int256(gross)) - 1];
            for (uint256 i; i < executed.length; ++i) {
                BalanceDelta delta = _imdDelta(executed[i]);
                vm.prank(address(manager));
                vm.expectRevert(SIMDTESTHook.PartialFillUnsupported.selector);
                hook.afterSwap(address(router), key, params, delta, "");
            }
        }
    }

    function _imdDelta(int128 imdAmount) private view returns (BalanceDelta) {
        return hook.imdIsCurrency0() ? toBalanceDelta(imdAmount, 0) : toBalanceDelta(0, imdAmount);
    }

    function test_PoolOpenedEventRecordsTheOpeningBlock() public {
        SIMDTESTHook fresh = _deployHookWithFlags(0x28cc);
        vm.roll(777);
        vm.recordLogs();
        manager.initialize(fresh.poolKey(), Q96);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(fresh) && logs[i].topics[0] == OPENED_TOPIC) {
                assertEq(logs[i].topics[1], PoolId.unwrap(fresh.poolId()));
                assertEq(abi.decode(logs[i].data, (uint256)), 777);
                seen = true;
            }
        }
        assertTrue(seen);
        assertEq(fresh.openingBlock(), 777);
        assertEq(fresh.antiSnipeBps(), 3_000);
        vm.roll(787);
        assertEq(fresh.antiSnipeBps(), 0);
    }

    /// @dev The gate rejects only non-initializer, non-full-range adds while the rate is nonzero.
    function test_GateDirectCallsAcceptFullRangeInitializerAndClosedWindow() public {
        IPoolManager.ModifyLiquidityParams memory narrow = IPoolManager.ModifyLiquidityParams(-60, 60, 1, 0);
        IPoolManager.ModifyLiquidityParams memory full =
            IPoolManager.ModifyLiquidityParams(-887_220, 887_220, 1, 0);
        for (uint256 offset; offset < 10; ++offset) {
            vm.roll(openedAt + offset);
            vm.prank(address(manager));
            assertSelector(
                hook.beforeAddLiquidity(address(router), key, full, ""),
                SIMDTESTHook.beforeAddLiquidity.selector
            );
            vm.prank(address(manager));
            assertSelector(
                hook.beforeAddLiquidity(address(this), key, narrow, ""),
                SIMDTESTHook.beforeAddLiquidity.selector
            );
            vm.prank(address(manager));
            vm.expectRevert(SIMDTESTHook.OnlyFullRangeDuringAntiSnipe.selector);
            hook.beforeAddLiquidity(address(router), key, narrow, "");
        }
        vm.roll(openedAt + 10);
        vm.prank(address(manager));
        assertSelector(
            hook.beforeAddLiquidity(address(router), key, narrow, ""),
            SIMDTESTHook.beforeAddLiquidity.selector
        );
        // Removals are never gated: a narrow position opened after the window can be withdrawn at once.
        router.modify(key, -60, 60, 1e18, 0);
        router.modify(key, -60, 60, -1e18, 0);
    }

    function assertSelector(bytes4 a, bytes4 b) internal pure {
        require(a == b, "assertSelector");
    }

    /// @dev After the window only the treasury fee applies: over a mixed sequence the treasury receives
    /// exactly the sum of floor(volume / 200) and the pool receives no donation at all.
    function test_OnlyTreasuryFeeAfterWindowOverMixedSequence() public {
        vm.roll(openedAt + 10);
        uint256 expected;
        for (uint256 i; i < 16; ++i) {
            vm.recordLogs();
            router.swap(key, _params(i % 2 == 0, i % 4 < 2, (i + 1) * 123_456_789_012_345_678));
            Vm.Log[] memory logs = vm.getRecordedLogs();
            for (uint256 j; j < logs.length; ++j) {
                assertTrue(!(logs[j].emitter == address(manager) && logs[j].topics[0] == DONATE_TOPIC));
                if (logs[j].emitter == address(hook) && logs[j].topics[0] == FEES_TOPIC) {
                    (uint256 volume, uint256 donation, uint256 treasuryFee) =
                        abi.decode(logs[j].data, (uint256, uint256, uint256));
                    assertEq(donation, 0);
                    assertEq(treasuryFee, volume / 200);
                    expected += treasuryFee;
                }
            }
            if (i == 7) vm.roll(openedAt + 1_000);
        }
        assertEq(imd.balanceOf(TREASURY), expected);
        assertTrue(expected > 0);
        assertEq(imd.balanceOf(address(hook)), 0);
    }

    /// @dev Walks the runtime bytecode skipping PUSH immediates and the CBOR trailer; no DELEGATECALL (0xf4)
    /// or SELFDESTRUCT (0xff) may appear in any launch artifact.
    function test_RuntimeCodeHasNoDelegatecallOrSelfdestruct() public {
        assertTrue(!_containsOpcode(address(hook).code, 0xf4));
        assertTrue(!_containsOpcode(address(hook).code, 0xff));
        assertTrue(!_containsOpcode(address(token).code, 0xf4));
        assertTrue(!_containsOpcode(address(token).code, 0xff));
        SIMDTESTLaunch launcher = new SIMDTESTLaunch(manager);
        assertTrue(!_containsOpcode(address(launcher).code, 0xf4));
        assertTrue(!_containsOpcode(address(launcher).code, 0xff));
        // The walker itself recognises the opcodes it looks for.
        assertTrue(_containsOpcode(hex"6000f4", 0xf4));
        assertTrue(_containsOpcode(hex"60ff", 0xff) == false);
        assertTrue(_containsOpcode(hex"3000ff", 0xff));
    }

    function _containsOpcode(bytes memory code, uint8 target) private pure returns (bool) {
        uint256 end = code.length;
        if (end >= 2) {
            uint256 cbor = (uint256(uint8(code[end - 2])) << 8) | uint8(code[end - 1]);
            if (cbor + 2 <= end) end -= cbor + 2;
        }
        for (uint256 i; i < end;) {
            uint8 op = uint8(code[i]);
            if (op == target) return true;
            if (op >= 0x60 && op <= 0x7f) i += op - 0x5f;
            ++i;
        }
        return false;
    }
}
