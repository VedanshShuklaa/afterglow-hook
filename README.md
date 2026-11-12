# Afterglow

**A Uniswap v4 pool that wakes up gently.**

Afterglow temporarily raises a pool's LP fee when swaps resume after inactivity, then returns it to normal over ten blocks. **Ten swaps in one block do not count as ten blocks of recovery.**

## The idea

An inactive pool may have an outdated price. Afterglow explores charging a temporary higher LP fee when activity resumes. It uses executed swaps and chain time: no oracle, points token, keeper, allowlist or owner.

This is an educational mechanism, not a demonstrated improvement in LP returns. Dynamic fees and time-decaying fees already exist; the contribution is a small, testable combination of an idle trigger, elapsed-block recovery and nonzero-execution tracking. No claim of global novelty is made.

| Moment | LP fee |
| --- | ---: |
| New or continuously active pool | 0.30% |
| At least 30 minutes since initialization or last executed swap | 1.00% |
| First real swap after inactivity | 1.00%; starts recovery |
| More swaps in that same block | 1.00% |
| Five blocks after the wake trade | 0.65% |
| Ten or more blocks after the wake trade | 0.30% |
| Another full idle interval | 1.00%; next real swap restarts recovery |

Recovery advances even without intermediate swaps. A new 30-minute idle interval takes priority.

## Run it

Requires [Foundry](https://getfoundry.sh/) (tested with v1.5.0). Solidity 0.8.26, Cancun EVM; dependencies are pinned Git submodules.

```sh
git clone --recurse-submodules https://github.com/VedanshShuklaa/afterglow-hook.git
cd afterglow-hook
forge build
forge test -vv
forge fmt --check
```

If already cloned, run `git submodule update --init --recursive` first. The first build may download the compiler.

### One-command demo

```sh
forge test --match-test testDemo -vv
```

Deploys a local PoolManager, two mock tokens, a permission-valid hook and a funded pool. Executes real swaps and advances test-chain time and blocks. No RPC, wallet or funds needed.

Expected fees in millionths:

```text
Fresh pool fee (millionths): 3000
After 30 idle minutes: 10000
Two trades, same block: 10000
Five blocks later: 6500
Ten blocks later: 3000
```

## How it works

- `afterInitialize`: rejects static-fee pools, records the initial activity time and sets the stored base LP fee.
- `beforeSwap`: returns `currentFee(poolId) | OVERRIDE_FEE_FLAG` with zero custom-accounting delta.
- `afterSwap`: records activity only for a nonzero executed balance delta. Starts recovery if the pool was idle. Returns no hook fee or token delta.

Fees are millionths: 3,000 = 0.30%; 10,000 = 1.00%. During recovery, for elapsed blocks `b < 10`:

```text
LP fee = 10,000 - (7,000 × b / 10)
```

Each PoolId has independent state. Initialization starts the activity timer. `currentFee(PoolId)` returns the next LP fee; unknown pools revert. The stored PoolManager LP fee stays at the base value while the hook overrides each swap. Integrators must use hook-aware quoting, not the stored base fee alone.

The hook collects nothing for itself. Standard v4 fee accounting applies, including separately configured protocol fees. No admin setter or custody function exists.

## Tests

- Fresh pricing, exact 1,800-second boundary and repeated idle periods.
- Real wake trade, same-block trades and linear decay by elapsed blocks.
- Independent pools, timestamp-zero initialization and unknown pool rejection.
- Both swap directions and exact-output swaps.
- Applied fees decoded from PoolManager's Swap events.
- Empty-liquidity swaps with zero executed token deltas.
- Unauthorized callbacks, static-fee rejection and settlement-failure rollback.
- Fuzzed fee bounds and monotonic recovery.
- Real CREATE2 deployment with correct callback address bits.

CI runs formatting, build and the full suite.

## Deployment

A testnet deployment script is included; a funded on-chain deployment is not required.

Export `POOL_MANAGER` with the official deployed PoolManager for your target chain and `RPC_URL` with its RPC. Verify the address in [Uniswap's deployment documentation](https://developers.uniswap.org/docs/protocols/v4/deployments). The chain must support Cancun and Foundry's default CREATE2 deployer at `0x4e59b44847b379578588920cA78FbF26c0B4956C`.

Simulation:

```sh
forge script script/DeployAfterglow.s.sol:DeployAfterglow --rpc-url "$RPC_URL"
```

To deliberately deploy using a configured Foundry keystore account:

```sh
forge script script/DeployAfterglow.s.sol:DeployAfterglow --rpc-url "$RPC_URL" --account deployer --broadcast
```

The script mines a salt for the callback flags and validates the address. It deploys only the hook. Create a pool separately with `fee = 0x800000` (dynamic fee), correctly sorted currencies and this hook address. The mined salt depends on compiler, bytecode, manager and deployer. Re-running against an existing predicted deployment intentionally fails.

## Limitations

- Inactivity does not prove a stale price. A higher fee can discourage useful price discovery.
- Tiny executed trades can keep a pool active. A tiny wake trade followed by waiting ten blocks can exhaust recovery before a larger trade. Elapsed-block decay prevents same-block acceleration, not these strategies.
- Block durations vary by chain; the idle trigger uses timestamps.
- Zero-delta swaps do not update activity, although Uniswap can still move the tick through empty liquidity.
- Quotes may change before inclusion. Use router slippage controls.
- Constants are demonstration choices, not calibrated economic parameters. This is unaudited educational code.

## References and attribution

- [Uniswap first-hook guide](https://developers.uniswap.org/docs/protocols/v4/guides/hooks/your-first-hook).
- [Uniswap dynamic fees](https://developers.uniswap.org/docs/protocols/v4/concepts/dynamic-fees): fee overrides and existing strategies.
- [OpenZeppelin Uniswap Hooks](https://github.com/OpenZeppelin/uniswap-hooks): BaseHook permissions and access control.
- [Uniswap v4 core](https://github.com/Uniswap/v4-core): PoolManager, test routers and helpers.

Afterglow source is MIT licensed. Dependencies retain their own licenses, including v4-core's license; this repository does not relicense them.
