// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

/// @title Afterglow: a block-decaying LP fee after a pool has been idle.
/// @notice Educational experiment. Activity is not an oracle or a measure of fair price.
contract AfterglowHook is BaseHook {
    uint24 public constant BASE_FEE = 3000; // 0.30%, fees are in millionths
    uint24 public constant WAKE_FEE = 10000; // 1.00%
    uint256 public constant IDLE_THRESHOLD = 30 minutes;
    uint256 public constant RECOVERY_BLOCKS = 10;
    event RecoveryStarted(PoolId indexed poolId, uint256 startBlock);
    error DynamicFeeRequired();
    error UnknownPool();

    struct Activity {
        uint256 lastSwapAt;
        uint256 recoveryStartBlock;
        bool initialized;
        bool recovering;
    }
    mapping(PoolId => Activity) public activity;
    constructor(IPoolManager manager) BaseHook(manager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
        p.afterInitialize = true;
        p.beforeSwap = true;
        p.afterSwap = true;
    }

    function _afterInitialize(address, PoolKey calldata key, uint160, int24) internal override returns (bytes4) {
        if (key.fee != LPFeeLibrary.DYNAMIC_FEE_FLAG) revert DynamicFeeRequired();
        activity[key.toId()] =
            Activity({lastSwapAt: block.timestamp, recoveryStartBlock: 0, initialized: true, recovering: false});
        poolManager.updateDynamicLPFee(key, BASE_FEE);
        return IHooks.afterInitialize.selector;
    }

    /// @notice The LP fee for a swap at the current block and timestamp, before protocol fees.
    /// @dev Quotes are state-dependent; they do not replace router slippage limits.
    function currentFee(PoolId id) public view returns (uint24) {
        Activity storage state = activity[id];
        if (!state.initialized) revert UnknownPool();
        // A fresh idle interval takes priority over any previous recovery.
        if (block.timestamp - state.lastSwapAt >= IDLE_THRESHOLD) return WAKE_FEE;
        if (!state.recovering) return BASE_FEE;
        uint256 elapsed = block.number - state.recoveryStartBlock;
        if (elapsed >= RECOVERY_BLOCKS) return BASE_FEE;
        // elapsed < 10, so the discount is at most 6300 and fits in uint24.
        // forge-lint: disable-next-line(unsafe-typecast)
        return WAKE_FEE - uint24(uint256(WAKE_FEE - BASE_FEE) * elapsed / RECOVERY_BLOCKS);
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return (
            IHooks.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            currentFee(key.toId()) | LPFeeLibrary.OVERRIDE_FEE_FLAG
        );
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        // Empty-liquidity attempts can move the tick without exchanging tokens.
        // Only executed token deltas count as activity.
        if (BalanceDelta.unwrap(delta) != 0) {
            PoolId id = key.toId();
            Activity storage state = activity[id];
            if (block.timestamp - state.lastSwapAt >= IDLE_THRESHOLD) {
                state.recoveryStartBlock = block.number;
                state.recovering = true;
                emit RecoveryStarted(id, block.number);
            }
            state.lastSwapAt = block.timestamp;
        }
        return (IHooks.afterSwap.selector, 0);
    }
}
