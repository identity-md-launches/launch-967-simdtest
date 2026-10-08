// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

/// @notice Immutable IMD fees for exactly one SIMDTEST/IMD pool.
/// @dev IMD-specified swaps must fill completely; partial fills revert instead of overcharging.
/// @dev Deploy at an address whose low 14 bits equal HOOK_FLAGS. The beforeAddLiquidity bit enables
/// the anti-snipe liquidity gate; the PoolManager only calls callbacks whose bit is set, so an address
/// with HOOK_FLAGS_UNGATED is accepted but has no gate. Every other bit is mandatory.
contract SIMDTESTHook {
    using PoolIdLibrary for PoolKey;

    address public constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address public constant TREASURY = 0x3dD5F73dD1A4E62630fAd3909673F130aD429985;
    uint24 public constant LP_FEE = 12_500;
    int24 public constant TICK_SPACING = 60;
    int24 public constant MIN_TICK = -887_220;
    int24 public constant MAX_TICK = 887_220;
    uint256 public constant BPS = 10_000;
    uint256 public constant TREASURY_BPS = 50;
    uint256 public constant MAX_ANTI_SNIPE_BPS = 3_000;
    uint256 public constant ANTI_SNIPE_BLOCKS = 10;
    uint160 public constant HOOK_FLAGS = 0x28cc;
    uint160 public constant HOOK_FLAGS_UNGATED = 0x20cc;

    IPoolManager public immutable poolManager;
    address public immutable token;
    address public immutable initializer;
    PoolId public immutable poolId;
    bool public immutable imdIsCurrency0;

    bool public opened;
    uint256 public openingBlock;

    error OnlyPoolManager();
    error InvalidDeployment();
    error WrongPool();
    error OnlyInitializer();
    error AlreadyOpened();
    error NotOpened();
    error InvalidAmount();
    error PartialFillUnsupported();
    error OnlyFullRangeDuringAntiSnipe();

    event PoolOpened(PoolId indexed id, uint256 blockNumber);
    event FeesCharged(
        PoolId indexed id, address indexed sender, uint256 imdVolume, uint256 donation, uint256 treasuryFee
    );

    constructor(IPoolManager manager_, address token_) {
        if (
            address(manager_).code.length == 0 || token_.code.length == 0 || token_ == IMD
                || IMD.code.length == 0
        ) revert InvalidDeployment();
        poolManager = manager_;
        token = token_;
        initializer = msg.sender;
        imdIsCurrency0 = IMD < token_;
        poolId = poolKey().toId();
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    function getHookPermissions() public view returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeAddLiquidity = liquidityGateEnabled();
        p.beforeSwap = true;
        p.afterSwap = true;
        p.beforeSwapReturnDelta = true;
        p.afterSwapReturnDelta = true;
    }

    /// @notice True when this address carries the beforeAddLiquidity bit, so the PoolManager calls the gate.
    function liquidityGateEnabled() public view returns (bool) {
        return uint160(address(this)) & Hooks.BEFORE_ADD_LIQUIDITY_FLAG != 0;
    }

    function poolKey() public view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(imdIsCurrency0 ? IMD : token),
            currency1: Currency.wrap(imdIsCurrency0 ? token : IMD),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(this))
        });
    }

    function beforeInitialize(address sender, PoolKey calldata key, uint160)
        external
        onlyPoolManager
        returns (bytes4)
    {
        _checkPool(key);
        if (sender != initializer) revert OnlyInitializer();
        if (opened) revert AlreadyOpened();
        opened = true;
        openingBlock = block.number;
        emit PoolOpened(poolId, block.number);
        return IHooks.beforeInitialize.selector;
    }

    /// @notice While the anti-snipe fee is nonzero, only full-range positions can be added, except by the
    /// initializer's seeding. A narrow position at a swap's end tick would otherwise let the swapper
    /// capture its own donation; a full-range position is bounded by real capital on both sides.
    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4) {
        _checkPool(key);
        if (
            antiSnipeBps() != 0 && sender != initializer
                && (params.tickLower != MIN_TICK || params.tickUpper != MAX_TICK)
        ) revert OnlyFullRangeDuringAntiSnipe();
        return IHooks.beforeAddLiquidity.selector;
    }

    /// @notice 3000, 2700, ..., 300 bps at offsets 0..9; zero from offset 10 onward.
    function antiSnipeBps() public view returns (uint256) {
        if (!opened) return 0;
        uint256 elapsed = block.number - openingBlock;
        return elapsed >= ANTI_SNIPE_BLOCKS ? 0 : MAX_ANTI_SNIPE_BPS - elapsed * 300;
    }

    /// @notice Fees on a gross IMD volume. Aggregate rounds down; treasury rounds down separately.
    function feesOn(uint256 grossImd) public view returns (uint256 donation, uint256 treasuryFee) {
        if (grossImd > uint256(uint128(type(int128).max))) revert InvalidAmount();
        treasuryFee = grossImd * TREASURY_BPS / BPS;
        donation = grossImd * (antiSnipeBps() + TREASURY_BPS) / BPS - treasuryFee;
    }

    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        _checkSwap(key, params);
        if (!_imdSpecified(params)) return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
        (, uint256 fee) = _specifiedQuote(params);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(int256(fee)), 0), 0);
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        _checkSwap(key, params);
        int128 imdDelta = imdIsCurrency0 ? delta.amount0() : delta.amount1();
        uint256 executed = imdDelta < 0 ? uint256(-int256(imdDelta)) : uint256(int256(imdDelta));
        uint256 volume = executed;
        bool specified = _imdSpecified(params);
        if (specified) {
            (uint256 gross, uint256 fee) = _specifiedQuote(params);
            uint256 expected = params.amountSpecified < 0 ? gross - fee : gross;
            if (executed != expected) revert PartialFillUnsupported();
            volume = gross;
        } else if (imdDelta < 0) {
            // Exact-output buy: the pool's IMD input is net of the hook fee. Gross it up so the fee
            // base matches an exact-input buy of the same size.
            volume = _grossForNet(executed);
        }
        (uint256 donation, uint256 treasuryFee) = feesOn(volume);
        // Each call creates a debt for this hook. The returned hook delta credits exactly
        // donation + treasuryFee, cancelling that debt during PoolManager.swap accounting.
        if (donation != 0) {
            poolManager.donate(key, imdIsCurrency0 ? donation : 0, imdIsCurrency0 ? 0 : donation, "");
        }
        if (treasuryFee != 0) poolManager.take(Currency.wrap(IMD), TREASURY, treasuryFee);
        emit FeesCharged(poolId, sender, volume, donation, treasuryFee);
        return (IHooks.afterSwap.selector, specified ? int128(0) : int128(int256(donation + treasuryFee)));
    }

    function _specifiedQuote(IPoolManager.SwapParams calldata params)
        private
        view
        returns (uint256 gross, uint256 fee)
    {
        gross = params.amountSpecified < 0
            ? uint256(-params.amountSpecified)
            : _grossForNet(uint256(params.amountSpecified));
        (uint256 donation, uint256 treasuryFee) = feesOn(gross);
        fee = donation + treasuryFee;
    }

    /// @notice Smallest gross whose net (gross - floor(gross * rate / BPS)) equals `net`; zero for zero.
    function _grossForNet(uint256 net) private view returns (uint256) {
        if (net == 0) return 0;
        return (net - 1) * BPS / (BPS - antiSnipeBps() - TREASURY_BPS) + 1;
    }

    function _imdSpecified(IPoolManager.SwapParams calldata params) private view returns (bool) {
        return (params.amountSpecified < 0 == params.zeroForOne) == imdIsCurrency0;
    }

    function _checkPool(PoolKey calldata key) private view {
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId)) revert WrongPool();
    }

    function _checkSwap(PoolKey calldata key, IPoolManager.SwapParams calldata params) private view {
        _checkPool(key);
        if (!opened) revert NotOpened();
        if (
            params.amountSpecified == 0 || params.amountSpecified > type(int128).max
                || params.amountSpecified < -int256(type(int128).max)
        ) revert InvalidAmount();
    }
}
