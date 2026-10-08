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
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice Launch helper edge cases: seeding at any admissible price is either exact or fully rolled
/// back, the seed position is locked, and the fee clock starts in the launch block.
contract SIMDTESTLaunchEdgeTest is TestBase {
    using StateLibrary for IPoolManager;

    address private constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    uint160 private constant Q96 = 1 << 96;
    uint256 private constant FUNDING = 1e40;

    IPoolManager private manager;
    SIMDTESTLaunch private launcher;
    SIMDTEST private token;
    MockIMD private imd;
    bytes32 private salt;
    address private predicted;

    function setUp() public {
        vm.roll(400);
        vm.etch(IMD, address(new MockIMD()).code);
        imd = MockIMD(IMD);
        imd.mint(address(this), FUNDING);
        manager = IPoolManager(address(new PoolManager(address(this))));
        launcher = new SIMDTESTLaunch(manager);
        token = launcher.token();
        (salt, predicted) = new MineHook().run(launcher, 0, 1_000_000);
        imd.approve(address(launcher), FUNDING);
    }

    /// @dev Every price strictly inside the full range either seeds exactly 800M SIMDTEST at the quoted
    /// liquidity or reverts atomically and leaves the helper retryable. Extreme prices do revert: the
    /// quoted liquidity or the IMD leg can exceed what the pool accepts (see the findings report).
    /// forge-config: default.fuzz.runs = 600
    function testFuzz_AnyPriceSeedsExactlyOrRollsBack(int24 tickSeed) public {
        int24 tick = int24(int256(tickSeed) % 887_219);
        uint160 price = TickMath.getSqrtPriceAtTick(tick);
        (bool quoted, bytes memory quote) =
            address(launcher).call(abi.encodeCall(launcher.liquidityForSeed, (price)));
        if (!quoted) {
            vm.expectRevert(SIMDTESTLaunch.InvalidPriceOrLiquidity.selector);
            launcher.launch(price, FUNDING, salt);
            _assertUnlaunched();
            launcher.launch(Q96, FUNDING, salt);
            return;
        }
        uint128 liquidity = abi.decode(quote, (uint128));
        (bool launched,) = address(launcher).call(abi.encodeCall(launcher.launch, (price, FUNDING, salt)));
        if (!launched) {
            _assertUnlaunched();
            launcher.launch(Q96, FUNDING, salt);
            return;
        }
        SIMDTESTHook hook = launcher.hook();
        assertEq(address(hook), predicted);
        assertEq(token.balanceOf(address(manager)), 800_000_000 ether);
        assertEq(token.balanceOf(address(this)), 100_000_000 ether);
        assertEq(token.balanceOf(token.DEAD()), 100_000_000 ether);
        assertEq(token.balanceOf(address(launcher)), 0);
        assertEq(manager.getLiquidity(hook.poolId()), liquidity);
        assertEq(imd.balanceOf(address(launcher)), 0);
        assertEq(FUNDING - imd.balanceOf(address(this)), imd.balanceOf(address(manager)));
        (uint160 poolPrice,,,) = manager.getSlot0(hook.poolId());
        assertEq(uint256(poolPrice), uint256(price));
    }

    function test_SeedPositionIsLockedUnderTheHelper() public {
        SIMDTESTHook hook = launcher.launch(Q96, FUNDING, salt);
        uint128 seed = launcher.liquidityForSeed(Q96);
        bytes32 positionKey = Position.calculatePositionKey(address(launcher), -887_220, 887_220, 0);
        assertEq(manager.getPositionLiquidity(hook.poolId(), positionKey), seed);
        assertEq(manager.getLiquidity(hook.poolId()), seed);
        // The only path that could touch the position is the sealed callback.
        PoolKey memory key = hook.poolKey();
        bytes memory payload = abi.encode(key, seed, FUNDING);
        vm.prank(address(manager));
        vm.expectRevert(SIMDTESTLaunch.OnlySeedingCallback.selector);
        launcher.unlockCallback(payload);
        vm.expectRevert(SIMDTESTLaunch.OnlySeedingCallback.selector);
        launcher.unlockCallback(payload);
        assertEq(manager.getPositionLiquidity(hook.poolId(), positionKey), seed);
    }

    function test_FeeClockStartsInTheLaunchBlock() public {
        vm.roll(1234);
        SIMDTESTHook hook = launcher.launch(Q96, FUNDING, salt);
        assertEq(hook.openingBlock(), 1234);
        assertEq(hook.antiSnipeBps(), 3_000);
        vm.roll(1243);
        assertEq(hook.antiSnipeBps(), 300);
        vm.roll(1244);
        assertEq(hook.antiSnipeBps(), 0);
    }

    function test_SaltMinerOnlyReturnsGatedAddresses() public {
        assertEq(uint256(uint160(predicted) & 0x3fff), 0x28cc);
        (bytes32 other, address otherPredicted) = new MineHook().run(launcher, uint256(salt) + 1, 1_000_000);
        assertTrue(other != salt);
        assertEq(uint256(uint160(otherPredicted) & 0x3fff), 0x28cc);
    }

    function _assertUnlaunched() private view {
        assertTrue(!launcher.launched());
        assertEq(address(launcher.hook()), address(0));
        assertEq(predicted.code.length, 0);
        assertEq(token.balanceOf(address(launcher)), 900_000_000 ether);
        assertEq(token.balanceOf(address(manager)), 0);
        assertEq(imd.balanceOf(address(manager)), 0);
        assertEq(imd.balanceOf(address(this)), FUNDING);
    }
}
