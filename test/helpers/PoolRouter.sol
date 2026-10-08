// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @dev Integration harness: real manager unlock/settlement and caller-level slippage checks.
contract PoolRouter is IUnlockCallback {
    IPoolManager public immutable manager;
    error OnlyManager();
    error Slippage();

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function modify(PoolKey memory key, int24 lower, int24 upper, int256 liquidity, bytes32 salt)
        external
        returns (BalanceDelta)
    {
        return abi.decode(
            manager.unlock(
                abi.encode(
                    uint8(0),
                    msg.sender,
                    key,
                    abi.encode(IPoolManager.ModifyLiquidityParams(lower, upper, liquidity, salt))
                )
            ),
            (BalanceDelta)
        );
    }

    function swap(PoolKey memory key, IPoolManager.SwapParams memory params) external returns (BalanceDelta) {
        return _swap(key, params, 0, type(uint256).max);
    }

    function swapWithLimits(
        PoolKey memory key,
        IPoolManager.SwapParams memory params,
        uint256 minOut,
        uint256 maxIn
    ) external returns (BalanceDelta) {
        return _swap(key, params, minOut, maxIn);
    }

    function _swap(PoolKey memory key, IPoolManager.SwapParams memory params, uint256 minOut, uint256 maxIn)
        private
        returns (BalanceDelta)
    {
        return abi.decode(
            manager.unlock(abi.encode(uint8(1), msg.sender, key, abi.encode(params, minOut, maxIn))),
            (BalanceDelta)
        );
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert OnlyManager();
        (uint8 action, address payer, PoolKey memory key, bytes memory payload) =
            abi.decode(data, (uint8, address, PoolKey, bytes));
        BalanceDelta delta;
        if (action == 0) {
            (delta,) =
                manager.modifyLiquidity(key, abi.decode(payload, (IPoolManager.ModifyLiquidityParams)), "");
        } else {
            (IPoolManager.SwapParams memory params, uint256 minOut, uint256 maxIn) =
                abi.decode(payload, (IPoolManager.SwapParams, uint256, uint256));
            delta = manager.swap(key, params, "");
            int128 input = params.zeroForOne ? delta.amount0() : delta.amount1();
            int128 output = params.zeroForOne ? delta.amount1() : delta.amount0();
            if (uint256(-int256(input)) > maxIn || uint256(int256(output)) < minOut) revert Slippage();
        }
        _settle(key.currency0, delta.amount0(), payer);
        _settle(key.currency1, delta.amount1(), payer);
        return abi.encode(delta);
    }

    function _settle(Currency currency, int128 amount, address payer) private {
        if (amount < 0) {
            uint256 debt = uint256(-int256(amount));
            manager.sync(currency);
            require(IERC20Minimal(Currency.unwrap(currency)).transferFrom(payer, address(manager), debt));
            require(manager.settle() == debt);
        } else if (amount > 0) {
            manager.take(currency, payer, uint256(int256(amount)));
        }
    }
}
