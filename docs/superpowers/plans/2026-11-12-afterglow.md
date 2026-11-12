# Afterglow implementation plan

Goal: complete the UHI first-hook quest with a small, explainable inactivity fee hook.

Architecture: OpenZeppelin BaseHook, Uniswap PoolManager and Foundry integration tests. Constants: base fee 3000, wake fee 10000 (millionths), idle threshold 1800 seconds, recovery 10 blocks. Per-pool state begins at initialization. beforeSwap returns the current fee override; afterSwap records only nonzero executed deltas. Recovery starts on the first executed trade after inactivity and decays by elapsed blocks, never swap count. Another idle interval restarts recovery.

- [x] Write tests against a minimal base-fee skeleton and observe the missing recovery behavior fail.
- [x] Implement src/AfterglowHook.sol and verify timing boundaries, repeated swaps, per-pool isolation, fee actually applied by PoolManager, exact output and both directions, no-liquidity swaps, access checks and fuzz bounds.
- [x] Add a CREATE2 deployment script and local demo, README with mechanism, commands, prior art, limitations and submission copy; CI uses pinned dependencies.
- [x] Run formatting, complete suite and demo; inspect tracked files, commit and publish a new public GitHub repo.

Review focus: idle boundary is inclusive; zero-delta attempts cannot postpone recovery; reverted transactions cannot update activity; same-block trades cannot accelerate decay; initial activity at timestamp zero must be distinguishable from an unknown pool.

The economic hypothesis is educational: no oracle, profitability claim or MEV guarantee. Dust trades can prevent idleness; a tiny wake trade followed by waiting can consume the recovery interval. No user identity, token issuance, owner or custody is required.
