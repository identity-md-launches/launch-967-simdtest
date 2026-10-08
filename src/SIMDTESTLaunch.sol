// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SIMDTEST} from "./SIMDTEST.sol";
import {SIMDTESTHook} from "./SIMDTESTHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @notice One-shot launch: 80% to full-range liquidity, 10% dead, 10% to the launch initiator.
/// @dev This helper permanently locks the seed position AND its accrued fees. No withdrawal methods exist.
contract SIMDTESTLaunch is IUnlockCallback {
    uint256 public constant POOL_ALLOCATION = 800_000_000 ether;
    uint256 public constant RESERVE_ALLOCATION = 100_000_000 ether;
    address public constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    int24 public constant LOWER_TICK = -887220;
    int24 public constant UPPER_TICK = 887220;

    IPoolManager public immutable poolManager;
    SIMDTEST public immutable token;
    address public immutable launchInitiator;
    SIMDTESTHook public hook;
    bool public launched;
    bool private seeding;

    error InvalidManager();
    error OnlyLaunchInitiator();
    error AlreadyLaunched();
    error InvalidPriceOrLiquidity();
    error OnlySeedingCallback();
    error ImdBudgetExceeded();
    error TransferFailed();
    error SettlementMismatch();

    event Launched(address indexed token, address indexed hook, uint256 imdSeed, uint128 liquidity);

    constructor(IPoolManager manager_) {
        if (address(manager_).code.length == 0 || IMD.code.length == 0) revert InvalidManager();
        poolManager = manager_;
        launchInitiator = msg.sender;
        token = new SIMDTEST();
    }

    /// @notice Caller supplies initial price, maximum IMD funding, and a mined CREATE2 hook salt.
    /// @dev Funding uses an exact transferFrom during seeding; approve this helper first.
    function launch(uint160 sqrtPriceX96, uint256 maxImd, bytes32 hookSalt) external returns (SIMDTESTHook) {
        if (msg.sender != launchInitiator) revert OnlyLaunchInitiator();
        if (launched) revert AlreadyLaunched();
        launched = true;
        hook = new SIMDTESTHook{salt: hookSalt}(poolManager, address(token));
        PoolKey memory key = hook.poolKey();
        uint128 liquidity = liquidityForSeed(sqrtPriceX96);
        poolManager.initialize(key, sqrtPriceX96);
        seeding = true;
        uint256 imdSeed = abi.decode(poolManager.unlock(abi.encode(key, liquidity, maxImd)), (uint256));
        seeding = false;
        if (!token.transfer(launchInitiator, RESERVE_ALLOCATION)) revert TransferFailed();
        emit Launched(address(token), address(hook), imdSeed, liquidity);
        return hook;
    }

    function liquidityForSeed(uint160 sqrtPriceX96) public view returns (uint128) {
        uint160 lower = TickMath.getSqrtPriceAtTick(LOWER_TICK);
        uint160 upper = TickMath.getSqrtPriceAtTick(UPPER_TICK);
        if (sqrtPriceX96 <= lower || sqrtPriceX96 >= upper) revert InvalidPriceOrLiquidity();
        uint256 liquidity;
        if (address(token) < IMD) {
            uint256 intermediate = FullMath.mulDiv(sqrtPriceX96, upper, 1 << 96);
            liquidity = FullMath.mulDiv(POOL_ALLOCATION, intermediate, upper - sqrtPriceX96);
        } else {
            liquidity = FullMath.mulDiv(POOL_ALLOCATION, 1 << 96, sqrtPriceX96 - lower);
        }
        if (liquidity == 0 || liquidity > uint256(uint128(type(int128).max))) {
            revert InvalidPriceOrLiquidity();
        }
        return uint128(liquidity);
    }

    function hookInitCodeHash() public view returns (bytes32) {
        return
            keccak256(
                abi.encodePacked(type(SIMDTESTHook).creationCode, abi.encode(poolManager, address(token)))
            );
    }

    function predictHook(bytes32 salt) public view returns (address) {
        return address(
            uint160(
                uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, hookInitCodeHash())))
            )
        );
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager) || !seeding) revert OnlySeedingCallback();
        // Consume the one-shot callback before interacting with IMD.
        seeding = false;
        (PoolKey memory key, uint128 liquidity, uint256 maxImd) =
            abi.decode(data, (PoolKey, uint128, uint256));
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key, IPoolManager.ModifyLiquidityParams(LOWER_TICK, UPPER_TICK, int256(uint256(liquidity)), 0), ""
        );
        bool tokenIs0 = address(token) < IMD;
        uint256 tokenUsed = uint256(-int256(tokenIs0 ? delta.amount0() : delta.amount1()));
        uint256 imdUsed = uint256(-int256(tokenIs0 ? delta.amount1() : delta.amount0()));
        if (imdUsed > maxImd) revert ImdBudgetExceeded();
        // Donate rounding dust so exactly 800m tokens are credited to this pool.
        uint256 dust = POOL_ALLOCATION - tokenUsed;
        if (dust != 0) poolManager.donate(key, tokenIs0 ? dust : 0, tokenIs0 ? 0 : dust, "");
        _settle(Currency.wrap(address(token)), POOL_ALLOCATION, false);
        _settle(Currency.wrap(IMD), imdUsed, true);
        return abi.encode(imdUsed);
    }

    function _settle(Currency currency, uint256 amount, bool fromInitiator) private {
        poolManager.sync(currency);
        if (fromInitiator) {
            (bool ok, bytes memory result) = Currency.unwrap(currency)
                .call(
                    abi.encodeCall(
                        IERC20Minimal.transferFrom, (launchInitiator, address(poolManager), amount)
                    )
                );
            if (!ok || (result.length != 0 && (result.length != 32 || !abi.decode(result, (bool))))) {
                revert TransferFailed();
            }
        } else {
            currency.transfer(address(poolManager), amount);
        }
        if (poolManager.settle() != amount) revert SettlementMismatch();
    }
}
