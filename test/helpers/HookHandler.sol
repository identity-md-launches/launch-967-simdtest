// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TestBase, Vm} from "./TestBase.sol";
import {MockIMD} from "./MockIMD.sol";
import {PoolRouter} from "./PoolRouter.sol";
import {SIMDTEST} from "../../src/SIMDTEST.sol";
import {SIMDTESTHook} from "../../src/SIMDTESTHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

/// @dev Invariant handler: three independent actors trade and provide liquidity against the launched
/// pool in random order while the block number advances. Every external effect is wrapped so that a
/// revert never aborts the sequence; the handler records what happened in ghost variables and the
/// invariant contract judges them. Per-swap fee rules are checked here, where the swap's own events
/// and balance deltas are still observable.
contract HookHandler is TestBase {
    using StateLibrary for IPoolManager;

    address public constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address public constant TREASURY = 0x3dD5F73dD1A4E62630fAd3909673F130aD429985;
    int24 public constant MIN_TICK = -887_220;
    int24 public constant MAX_TICK = 887_220;
    uint256 public constant MAX_SWAP = 1e24;
    uint256 public constant MAX_LIQUIDITY = 1e24;
    bytes32 private constant SWAP_TOPIC =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    bytes32 private constant DONATE_TOPIC = keccak256("Donate(bytes32,address,uint256,uint256)");
    bytes32 private constant FEES_TOPIC = keccak256("FeesCharged(bytes32,address,uint256,uint256,uint256)");

    IPoolManager public immutable manager;
    SIMDTEST public immutable token;
    MockIMD public immutable imd;
    SIMDTESTHook public immutable hook;
    PoolRouter public immutable router;
    PoolKey public key;
    uint256 public immutable openedAt;

    address[3] public actors;

    struct NarrowPosition {
        address actor;
        int24 lower;
        int24 upper;
        uint256 liquidity;
    }

    NarrowPosition[] public narrowPositions;
    mapping(address => uint256) public fullRangeLiquidity;

    // Ghost counters.
    uint256 public swaps;
    uint256 public revertedSwaps;
    uint256 public fullRangeAdds;
    uint256 public fullRangeRemoves;
    uint256 public narrowAdds;
    uint256 public narrowRejectedByGate;
    uint256 public narrowRemoves;
    uint256 public blocksAdvanced;
    uint256 public unexpectedReverts;
    uint256 public sumTreasury;
    uint256 public sumDonation;
    uint256 public sumVolume;
    uint256 public swapsInWindow;
    uint256 public swapsAfterWindow;
    uint256 public lastAntiSnipe;

    // Ghost flags: any true value is a property violation observed inside one call.
    bool public treasuryRuleBroken;
    bool public donationRuleBroken;
    bool public donationNotDelivered;
    bool public aggregateCapBroken;
    bool public swapperAccountingBroken;
    bool public narrowAddedDuringWindow;
    bool public antiSnipeIncreased;
    bool public feeEventMissing;

    constructor(
        IPoolManager manager_,
        SIMDTEST token_,
        SIMDTESTHook hook_,
        PoolRouter router_,
        address[3] memory actors_
    ) {
        manager = manager_;
        token = token_;
        imd = MockIMD(IMD);
        hook = hook_;
        router = router_;
        key = hook_.poolKey();
        openedAt = hook_.openingBlock();
        actors = actors_;
        lastAntiSnipe = hook_.antiSnipeBps();
        for (uint256 i; i < 3; ++i) {
            vm.startPrank(actors_[i]);
            token_.approve(address(router_), type(uint256).max);
            imd.approve(address(router_), type(uint256).max);
            vm.stopPrank();
        }
    }

    function actorList() external view returns (address[3] memory) {
        return actors;
    }

    function narrowPositionCount() external view returns (uint256) {
        return narrowPositions.length;
    }

    /// @dev mode bit0: buy SIMDTEST with IMD; bit1: exact input.
    function swap(uint256 actorSeed, uint8 mode, uint256 amountSeed) external {
        address actor = actors[actorSeed % 3];
        bool buy = mode & 1 == 1;
        bool exactInput = mode & 2 == 2;
        uint256 amount = _bound(amountSeed, 1, MAX_SWAP);
        if (!buy && exactInput) {
            uint256 have = token.balanceOf(actor);
            if (have == 0) return;
            if (amount > have) amount = have;
        }
        bool zeroForOne = buy == hook.imdIsCurrency0();
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams(
            zeroForOne,
            exactInput ? -int256(amount) : int256(amount),
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
        uint256 anti = hook.antiSnipeBps();
        uint256 treasuryBefore = imd.balanceOf(TREASURY);
        uint256 actorImdBefore = imd.balanceOf(actor);
        vm.recordLogs();
        vm.prank(actor);
        try router.swap(key, params) returns (BalanceDelta delta) {
            _judgeSwap(delta, anti, treasuryBefore, actorImdBefore, actor, buy, exactInput, amount);
        } catch {
            vm.getRecordedLogs();
            ++revertedSwaps;
            // Actors hold far more IMD than any bounded buy needs and exact-input sells are capped at the
            // balance, so those must never revert. An exact-output sell may legitimately run out of tokens;
            // bounded price drift keeps four times the IMD amount a safe sufficiency bound.
            if (buy || exactInput || token.balanceOf(actor) >= 4 * amount) ++unexpectedReverts;
        }
    }

    function _judgeSwap(
        BalanceDelta delta,
        uint256 anti,
        uint256 treasuryBefore,
        uint256 actorImdBefore,
        address actor,
        bool buy,
        bool exactInput,
        uint256 amount
    ) private {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 volume;
        uint256 donation;
        uint256 treasuryFee;
        uint256 donated;
        bool feesSeen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == FEES_TOPIC) {
                (volume, donation, treasuryFee) = abi.decode(logs[i].data, (uint256, uint256, uint256));
                feesSeen = true;
            } else if (logs[i].emitter == address(manager) && logs[i].topics[0] == DONATE_TOPIC) {
                (uint256 a0, uint256 a1) = abi.decode(logs[i].data, (uint256, uint256));
                donated += hook.imdIsCurrency0() ? a0 : a1;
                if ((hook.imdIsCurrency0() ? a1 : a0) != 0) donationNotDelivered = true;
            }
        }
        if (!feesSeen) feeEventMissing = true;
        ++swaps;
        if (anti != 0) ++swapsInWindow;
        else ++swapsAfterWindow;
        sumTreasury += treasuryFee;
        sumDonation += donation;
        sumVolume += volume;
        if (treasuryFee != volume * 50 / 10_000) treasuryRuleBroken = true;
        if (imd.balanceOf(TREASURY) - treasuryBefore != treasuryFee) treasuryRuleBroken = true;
        if (donation != volume * (anti + 50) / 10_000 - treasuryFee) donationRuleBroken = true;
        if (anti == 0 && donation != 0) donationRuleBroken = true;
        if (donated != donation) donationNotDelivered = true;
        if (donation + treasuryFee > volume * 3_050 / 10_000) aggregateCapBroken = true;
        int128 imdDelta = hook.imdIsCurrency0() ? delta.amount0() : delta.amount1();
        int256 actorImdChange = int256(imd.balanceOf(actor)) - int256(actorImdBefore);
        if (actorImdChange != int256(imdDelta)) swapperAccountingBroken = true;
        if (buy) {
            uint256 paid = uint256(-int256(imdDelta));
            // Buys pay the gross outlay: the fee base itself, exactly the input when it is specified.
            if (paid != volume) swapperAccountingBroken = true;
            if (exactInput && paid != amount) swapperAccountingBroken = true;
        } else {
            uint256 received = uint256(int256(imdDelta));
            if (received + donation + treasuryFee != volume) swapperAccountingBroken = true;
            if (!exactInput && received != amount) swapperAccountingBroken = true;
        }
    }

    function addFullRange(uint256 actorSeed, uint256 liquiditySeed) external {
        address actor = actors[actorSeed % 3];
        uint256 liquidity = _bound(liquiditySeed, 1, MAX_LIQUIDITY);
        bool affordable = _canAfford(actor, MIN_TICK, MAX_TICK, liquidity);
        vm.prank(actor);
        try router.modify(key, MIN_TICK, MAX_TICK, int256(liquidity), bytes32(uint256(uint160(actor)))) {
            fullRangeLiquidity[actor] += liquidity;
            ++fullRangeAdds;
        } catch {
            // Only an actor without enough tokens for the position may fail here.
            if (affordable) ++unexpectedReverts;
        }
    }

    /// @dev Whether `actor` holds the exact amounts v4 will charge for adding `liquidity` in the range.
    function _canAfford(address actor, int24 lower, int24 upper, uint256 liquidity)
        private
        view
        returns (bool)
    {
        (uint160 sqrtP,,,) = manager.getSlot0(hook.poolId());
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(lower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(upper);
        uint256 need0;
        uint256 need1;
        if (sqrtP <= sqrtLower) {
            need0 = SqrtPriceMath.getAmount0Delta(sqrtLower, sqrtUpper, uint128(liquidity), true);
        } else if (sqrtP < sqrtUpper) {
            need0 = SqrtPriceMath.getAmount0Delta(sqrtP, sqrtUpper, uint128(liquidity), true);
            need1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtP, uint128(liquidity), true);
        } else {
            need1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtUpper, uint128(liquidity), true);
        }
        (uint256 needToken, uint256 needImd) = hook.imdIsCurrency0() ? (need1, need0) : (need0, need1);
        return token.balanceOf(actor) >= needToken && imd.balanceOf(actor) >= needImd;
    }

    function removeFullRange(uint256 actorSeed, uint256 fractionSeed) external {
        address actor = actors[actorSeed % 3];
        uint256 have = fullRangeLiquidity[actor];
        if (have == 0) return;
        uint256 liquidity = _bound(fractionSeed, 1, have);
        vm.prank(actor);
        try router.modify(key, MIN_TICK, MAX_TICK, -int256(liquidity), bytes32(uint256(uint160(actor)))) {
            fullRangeLiquidity[actor] -= liquidity;
            ++fullRangeRemoves;
        } catch {
            ++unexpectedReverts;
        }
    }

    /// @dev A concentrated position one or two spacings wide near the current tick: the shape a sniper
    /// would use to capture their own donation. Must be rejected while the anti-snipe fee is nonzero.
    function addNarrow(uint256 actorSeed, uint256 liquiditySeed, uint8 widthSeed) external {
        address actor = actors[actorSeed % 3];
        uint256 liquidity = _bound(liquiditySeed, 1, MAX_LIQUIDITY);
        (, int24 tick,,) = manager.getSlot0(hook.poolId());
        int24 lower = (tick / 60) * 60;
        if (tick < 0 && tick % 60 != 0) lower -= 60;
        int24 upper = lower + 60 * int24(uint24(widthSeed % 3 + 1));
        if (upper > MAX_TICK) upper = MAX_TICK;
        if (lower <= MIN_TICK) lower = MIN_TICK + 60;
        uint256 anti = hook.antiSnipeBps();
        bool affordable = _canAfford(actor, lower, upper, liquidity);
        vm.prank(actor);
        try router.modify(key, lower, upper, int256(liquidity), bytes32(uint256(uint160(actor)) + 1)) {
            if (anti != 0) narrowAddedDuringWindow = true;
            narrowPositions.push(NarrowPosition(actor, lower, upper, liquidity));
            ++narrowAdds;
        } catch {
            if (anti != 0) ++narrowRejectedByGate;
            else if (affordable) ++unexpectedReverts;
        }
    }

    function removeNarrow(uint256 indexSeed) external {
        uint256 n = narrowPositions.length;
        if (n == 0) return;
        uint256 i = indexSeed % n;
        NarrowPosition memory p = narrowPositions[i];
        vm.prank(p.actor);
        try router.modify(
            key, p.lower, p.upper, -int256(p.liquidity), bytes32(uint256(uint160(p.actor)) + 1)
        ) {
            narrowPositions[i] = narrowPositions[n - 1];
            narrowPositions.pop();
            ++narrowRemoves;
        } catch {
            ++unexpectedReverts;
        }
    }

    function advance(uint8 blocksSeed) external {
        uint256 n = blocksSeed % 4;
        vm.roll(block.number + n);
        blocksAdvanced += n;
        uint256 anti = hook.antiSnipeBps();
        if (anti > lastAntiSnipe) antiSnipeIncreased = true;
        lastAntiSnipe = anti;
    }

    function _bound(uint256 x, uint256 min, uint256 max) private pure returns (uint256) {
        return min + x % (max - min + 1);
    }
}
