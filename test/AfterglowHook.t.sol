// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {AfterglowHook} from "../src/AfterglowHook.sol";

import {AfterglowSalt} from "../script/DeployAfterglow.s.sol";

contract AfterglowHookTest is Deployers {
    AfterglowHook hook;
    PoolId id;

    function setUp() public {
        vm.warp(10000);
        vm.roll(100);
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        address target = address(uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG));
        deployCodeTo("AfterglowHook.sol:AfterglowHook", abi.encode(manager), target);
        hook = AfterglowHook(target);
        (key, id) = initPoolAndAddLiquidity(
            currency0, currency1, IHooks(target), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1
        );
    }

    function trade() internal returns (BalanceDelta) {
        return swap(key, true, -1e12, "");
    }

    function wake() internal {
        vm.warp(block.timestamp + 1800);
        trade();
    }

    function testFreshPoolUsesBaseFee() public view {
        assertEq(hook.currentFee(id), 3000);
    }

    function testIdleBoundaryIsInclusive() public {
        vm.warp(11799);
        assertEq(hook.currentFee(id), 3000);
        vm.warp(11800);
        assertEq(hook.currentFee(id), 10000);
    }

    function testWakeTradeStartsRecovery() public {
        wake();
        (uint256 last, uint256 start,, bool recovering) = hook.activity(id);
        assertEq(last, 11800);
        assertEq(start, 100);
        assertTrue(recovering);
        assertEq(hook.currentFee(id), 10000);
    }

    function testDecayUsesBlocksNotTradeCount() public {
        wake();
        for (uint256 i; i < 5; ++i) {
            trade();
        }
        assertEq(hook.currentFee(id), 10000);
        vm.roll(105);
        assertEq(hook.currentFee(id), 6500);
        trade();
        assertEq(hook.currentFee(id), 6500);
        vm.roll(110);
        assertEq(hook.currentFee(id), 3000);
        vm.roll(1000);
        assertEq(hook.currentFee(id), 3000);
    }

    function testRealTradeRestartsIdleClock() public {
        vm.warp(11799);
        trade();
        vm.warp(11800);
        assertEq(hook.currentFee(id), 3000);
        vm.warp(13599);
        assertEq(hook.currentFee(id), 10000);
    }

    function testSecondIdlePeriodRestartsRecovery() public {
        wake();
        vm.roll(105);
        vm.warp(13600);
        assertEq(hook.currentFee(id), 10000);
        trade();
        (, uint256 start,,) = hook.activity(id);
        assertEq(start, 105);
        vm.roll(106);
        assertEq(hook.currentFee(id), 9300);
    }

    function testPoolStateIsIndependent() public {
        wake();
        (PoolKey memory other, PoolId otherId) =
            initPool(currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 10, SQRT_PRICE_1_1);
        assertEq(hook.currentFee(otherId), 3000);
        assertEq(hook.currentFee(id), 10000);
        assertTrue(PoolId.unwrap(other.toId()) != PoolId.unwrap(id));
    }

    function testZeroDeltaDoesNotWakeEmptyPool() public {
        (PoolKey memory emptyKey, PoolId emptyId) =
            initPool(currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 10, SQRT_PRICE_1_1);
        vm.warp(11800);
        BalanceDelta delta = swap(emptyKey, true, -1e12, "");
        assertEq(BalanceDelta.unwrap(delta), 0);
        (uint256 last,,, bool recovering) = hook.activity(emptyId);
        assertEq(last, 10000);
        assertFalse(recovering);
        assertEq(hook.currentFee(emptyId), 10000);
    }

    function testDirectCallbacksAreRejected() public {
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), key, SWAP_PARAMS, "");
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.afterSwap(address(this), key, SWAP_PARAMS, BalanceDelta.wrap(1), "");
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.afterInitialize(address(this), key, SQRT_PRICE_1_1, 0);
    }

    function testStaticFeePoolRejected() public {
        PoolKey memory fixedKey = key;
        fixedKey.fee = 3000;
        vm.expectRevert();
        manager.initialize(fixedKey, SQRT_PRICE_1_1);
    }

    function testUnknownPoolRejected() public {
        vm.expectRevert(AfterglowHook.UnknownPool.selector);
        hook.currentFee(PoolId.wrap(bytes32(uint256(42))));
    }

    function testRevertedSwapDoesNotUpdateActivity() public {
        vm.warp(11800);
        vm.expectRevert();
        swap(key, true, 0, "");
        (uint256 last,,, bool recovering) = hook.activity(id);
        assertEq(last, 10000);
        assertFalse(recovering);
    }

    function appliedFee(bool direction, int256 amount) internal returns (uint24 fee) {
        vm.recordLogs();
        swap(key, direction, amount, "");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 signature = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == signature) {
                (,,,,, fee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                return fee;
            }
        }
        revert("PoolManager Swap event missing");
    }

    function testPoolManagerActuallyAppliesOverride() public {
        assertEq(appliedFee(true, -1e12), 3000);
        vm.warp(11800);
        assertEq(appliedFee(true, -1e12), 10000);
        vm.roll(105);
        assertEq(appliedFee(true, -1e12), 6500);
        vm.roll(110);
        assertEq(appliedFee(true, -1e12), 3000);
    }

    function testExactOutputAndReverseDirection() public {
        vm.warp(11800);
        assertEq(appliedFee(false, 1e12), 10000);
        vm.roll(105);
        assertEq(appliedFee(true, 1e12), 6500);
    }

    function testFuzzFeeIsBoundedAndMonotone(uint8 elapsed) public {
        wake();
        uint256 n = bound(elapsed, 0, 100);
        vm.roll(100 + n);
        uint24 fee = hook.currentFee(id);
        assertGe(fee, 3000);
        assertLe(fee, 10000);
        assertEq(fee, n >= 10 ? 3000 : 10000 - 700 * n);
        vm.roll(101 + n);
        assertLe(hook.currentFee(id), fee);
    }

    function testCreate2DeploymentValidatesRealAddress() public {
        bytes32 initHash = keccak256(abi.encodePacked(type(AfterglowHook).creationCode, abi.encode(manager)));
        (bytes32 salt, address predicted) = AfterglowSalt.find(address(this), initHash);
        AfterglowHook deployed = new AfterglowHook{salt: salt}(manager);
        assertEq(address(deployed), predicted);
        assertEq(address(deployed.poolManager()), address(manager));
        (PoolKey memory created, PoolId createdId) = initPoolAndAddLiquidity(
            currency0, currency1, IHooks(predicted), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1
        );
        vm.warp(11800);
        swap(created, false, -1e12, "");
        assertEq(deployed.currentFee(createdId), 10000);
    }

    function testRevertingSettlementRollsBackWakeState() public {
        vm.warp(11800);
        address unfunded = makeAddr("unfunded");
        vm.expectRevert();
        vm.prank(unfunded);
        trade();
        (uint256 last,,, bool recovering) = hook.activity(id);
        assertEq(last, 10000);
        assertFalse(recovering);
    }

    function testInitializationAtTimestampZero() public {
        vm.warp(0);
        (, PoolId zeroId) =
            initPool(currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 10, SQRT_PRICE_1_1);
        assertEq(hook.currentFee(zeroId), 3000);
        vm.warp(1800);
        assertEq(hook.currentFee(zeroId), 10000);
    }

    function testDemo() public {
        console2.log("Fresh pool fee (millionths):", hook.currentFee(id));
        vm.warp(11800);
        console2.log("After 30 idle minutes:", hook.currentFee(id));
        trade();
        trade();
        console2.log("Two trades, same block:", hook.currentFee(id));
        vm.roll(105);
        console2.log("Five blocks later:", hook.currentFee(id));
        vm.roll(110);
        console2.log("Ten blocks later:", hook.currentFee(id));
        assertEq(hook.currentFee(id), 3000);
    }
}
