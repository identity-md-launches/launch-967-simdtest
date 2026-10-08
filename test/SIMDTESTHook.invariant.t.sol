// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TestBase} from "./helpers/TestBase.sol";
import {MockIMD} from "./helpers/MockIMD.sol";
import {PoolRouter} from "./helpers/PoolRouter.sol";
import {HookHandler} from "./helpers/HookHandler.sol";
import {SIMDTEST} from "../src/SIMDTEST.sol";
import {SIMDTESTHook} from "../src/SIMDTESTHook.sol";
import {SIMDTESTLaunch} from "../src/SIMDTESTLaunch.sol";
import {MineHook} from "../script/MineHook.s.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @notice Random sequences of swaps, liquidity changes and block advances against the launched pool.
/// The PoolManager holds the launch's value; these properties must hold after every sequence.
contract SIMDTESTHookInvariantTest is TestBase {
    using StateLibrary for IPoolManager;

    struct FuzzSelector {
        address addr;
        bytes4[] selectors;
    }

    address private constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address private constant TREASURY = 0x3dD5F73dD1A4E62630fAd3909673F130aD429985;
    uint160 private constant Q96 = 1 << 96;
    uint256 private constant ACTOR_IMD = 1e30;
    uint256 private constant ACTOR_TOKENS = 33_000_000 ether;

    IPoolManager private manager;
    SIMDTESTLaunch private launcher;
    SIMDTEST private token;
    MockIMD private imd;
    SIMDTESTHook private hook;
    PoolRouter private router;
    HookHandler private handler;
    address[3] private actors;
    uint256 private openedAt;
    uint128 private seedLiquidity;
    uint256 private imdMinted;

    function setUp() public {
        vm.roll(200);
        vm.etch(IMD, address(new MockIMD()).code);
        imd = MockIMD(IMD);
        manager = IPoolManager(address(new PoolManager(address(this))));
        launcher = new SIMDTESTLaunch(manager);
        token = launcher.token();
        (bytes32 salt,) = new MineHook().run(launcher, 0, 1_000_000);
        imd.mint(address(this), ACTOR_IMD);
        imdMinted += ACTOR_IMD;
        imd.approve(address(launcher), ACTOR_IMD);
        hook = launcher.launch(Q96, ACTOR_IMD, salt);
        openedAt = block.number;
        seedLiquidity = manager.getLiquidity(hook.poolId());
        router = new PoolRouter(manager);
        actors = [address(0xA11CE), address(0xB0B), address(0xCA201)];
        for (uint256 i; i < 3; ++i) {
            imd.mint(actors[i], ACTOR_IMD);
            imdMinted += ACTOR_IMD;
            token.transfer(actors[i], ACTOR_TOKENS);
        }
        handler = new HookHandler(manager, token, hook, router, actors);
    }

    function targetContracts() public view returns (address[] memory targets) {
        targets = new address[](1);
        targets[0] = address(handler);
    }

    function targetSelectors() public view returns (FuzzSelector[] memory selectors) {
        bytes4[] memory s = new bytes4[](7);
        s[0] = HookHandler.swap.selector;
        s[1] = HookHandler.addFullRange.selector;
        s[2] = HookHandler.removeFullRange.selector;
        s[3] = HookHandler.addNarrow.selector;
        s[4] = HookHandler.removeNarrow.selector;
        s[5] = HookHandler.advance.selector;
        s[6] = HookHandler.swap.selector;
        selectors = new FuzzSelector[](1);
        selectors[0] = FuzzSelector(address(handler), s);
    }

    /// forge-config: default.invariant.runs = 96
    /// forge-config: default.invariant.depth = 40
    function invariant_HookHoldsNoValue() public view {
        assertEq(imd.balanceOf(address(hook)), 0);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(manager.balanceOf(address(hook), Currency.wrap(IMD).toId()), 0);
        assertEq(manager.balanceOf(address(hook), Currency.wrap(address(token)).toId()), 0);
        assertEq(imd.balanceOf(address(launcher)), 0);
        assertEq(token.balanceOf(address(launcher)), 0);
    }

    /// forge-config: default.invariant.runs = 96
    /// forge-config: default.invariant.depth = 40
    function invariant_TreasuryReceivesExactlyHalfPercentOfVolume() public view {
        assertEq(imd.balanceOf(TREASURY), handler.sumTreasury());
        assertTrue(!handler.treasuryRuleBroken());
        assertTrue(!handler.feeEventMissing());
        assertLe(handler.sumTreasury(), handler.sumVolume() * 50 / 10_000);
    }

    /// forge-config: default.invariant.runs = 96
    /// forge-config: default.invariant.depth = 40
    function invariant_AntiSnipeDonationRulesHeld() public view {
        assertTrue(!handler.donationRuleBroken());
        assertTrue(!handler.donationNotDelivered());
        assertTrue(!handler.aggregateCapBroken());
        assertTrue(!handler.swapperAccountingBroken());
        assertLe(handler.sumDonation() + handler.sumTreasury(), handler.sumVolume() * 3_050 / 10_000);
    }

    /// forge-config: default.invariant.runs = 96
    /// forge-config: default.invariant.depth = 40
    function invariant_ImdAndTokenSupplyConserved() public view {
        uint256 imdHeld =
            imd.balanceOf(address(manager)) + imd.balanceOf(TREASURY) + imd.balanceOf(address(this));
        uint256 tokensHeld = token.balanceOf(address(manager)) + token.balanceOf(token.DEAD())
            + token.balanceOf(address(this));
        for (uint256 i; i < 3; ++i) {
            imdHeld += imd.balanceOf(actors[i]);
            tokensHeld += token.balanceOf(actors[i]);
        }
        assertEq(imdHeld, imdMinted);
        assertEq(tokensHeld, 1_000_000_000 ether);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(token.DEAD()), 100_000_000 ether);
    }

    /// forge-config: default.invariant.runs = 96
    /// forge-config: default.invariant.depth = 40
    function invariant_OpeningStateNeverReopensOrRestarts() public {
        assertTrue(hook.opened());
        assertEq(hook.openingBlock(), openedAt);
        uint256 elapsed = block.number - openedAt;
        assertEq(hook.antiSnipeBps(), elapsed >= 10 ? 0 : 3_000 - 300 * elapsed);
        assertLe(hook.antiSnipeBps(), 3_000);
        assertTrue(!handler.antiSnipeIncreased());
        assertTrue(launcher.launched());
        (bool relaunched,) =
            address(launcher).call(abi.encodeCall(launcher.launch, (Q96, ACTOR_IMD, bytes32(0))));
        assertTrue(!relaunched);
        (bool reinitialized,) =
            address(manager).call(abi.encodeCall(manager.initialize, (hook.poolKey(), Q96)));
        assertTrue(!reinitialized);
    }

    /// forge-config: default.invariant.runs = 96
    /// forge-config: default.invariant.depth = 40
    function invariant_SeedLockedAndGateHeld() public view {
        bytes32 positionKey = Position.calculatePositionKey(address(launcher), -887_220, 887_220, 0);
        assertEq(manager.getPositionLiquidity(hook.poolId(), positionKey), seedLiquidity);
        assertTrue(manager.getLiquidity(hook.poolId()) >= seedLiquidity);
        assertTrue(!handler.narrowAddedDuringWindow());
        assertEq(handler.unexpectedReverts(), 0);
    }

    /// @dev The invariants above are only meaningful if the handler's actions really execute.
    function test_HandlerActionsExecute() public {
        for (uint8 mode; mode < 4; ++mode) {
            handler.swap(mode, mode, 1e21);
        }
        assertEq(handler.swaps(), 4);
        assertEq(handler.revertedSwaps(), 0);
        assertEq(handler.swapsInWindow(), 4);
        assertTrue(handler.sumDonation() > 0 && handler.sumTreasury() > 0);
        handler.addFullRange(0, 1e22);
        handler.addNarrow(1, 1e22, 0);
        assertEq(handler.fullRangeAdds(), 1);
        assertEq(handler.narrowAdds(), 0);
        assertEq(handler.narrowRejectedByGate(), 1);
        handler.advance(3);
        handler.advance(3);
        handler.advance(3);
        handler.advance(3);
        assertEq(handler.blocksAdvanced(), 12);
        assertEq(hook.antiSnipeBps(), 0);
        handler.swap(2, 1, 1e21);
        assertEq(handler.swapsAfterWindow(), 1);
        handler.addNarrow(1, 1e22, 1);
        assertEq(handler.narrowAdds(), 1);
        handler.removeNarrow(0);
        // addFullRange bounded 1e22 to 1e22 + 1; a seed of have - 1 maps to removing the whole position.
        assertEq(handler.fullRangeLiquidity(actors[0]), 1e22 + 1);
        handler.removeFullRange(0, 1e22);
        assertEq(handler.narrowRemoves(), 1);
        assertEq(handler.fullRangeRemoves(), 1);
        assertEq(handler.narrowPositionCount(), 0);
        assertEq(handler.fullRangeLiquidity(actors[0]), 0);
        assertEq(handler.unexpectedReverts(), 0);
        assertTrue(
            !handler.treasuryRuleBroken() && !handler.donationRuleBroken() && !handler.donationNotDelivered()
                && !handler.aggregateCapBroken() && !handler.swapperAccountingBroken()
                && !handler.narrowAddedDuringWindow() && !handler.antiSnipeIncreased()
                && !handler.feeEventMissing()
        );
        assertEq(imd.balanceOf(TREASURY), handler.sumTreasury());
    }
}
