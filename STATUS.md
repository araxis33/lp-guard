# What the guard does today — checked on the network

Every line is a promise about the guard. A line is **ON CHAIN** only with a transaction or a read from Base / Reactive mainnet that shows it. Nothing is called done from tests or from a plan.

Contracts: PositionGuard `0x249f0A7145Fa806F64DdeE142b7F8453152b2f15` (Base), GuardReactive `0x339c03A3De7d128C2b04ee54A90f5bD285fBc7e8` (Reactive).

| # | Promise | Status | Proof |
|---|---------|--------|-------|
| 1 | Put USDC in, the guard opens a position in an Aero pool and stakes it for AERO | ON CHAIN | deposit + watch [0xbb487a54…c489](https://basescan.org/tx/0xbb487a54508995787231d053293c6509c33c28cc9dfa7a35267d9498149fc489), position #3562712 staked in gauge 0x46a9…89fb |
| 2 | AERO goes to the owner | ON CHAIN (accruing) | pendingAero 0.265 AERO on 19.11 19:20 |
| 3 | Reactive wakes the guard once a day without a server | ON CHAIN | daily review callback [0x3a5602ca…6a10](https://basescan.org/tx/0x3a5602ca74498fc797e995a39b654a99b338987e65a419c1c784603e80456a10) |
| 4 | Rule: leave when behind "just holding" by more than 3% | IN CONTRACT, never triggered | maxLossBps = 300 read on chain |
| 5 | Rule: leave when the pool pays less than price swings cost | ON CHAIN since 19.11 20:36 (was blind before: needed 3 price snapshots) | netPerDay = +0.81%/day, measured = true |
| 6 | Rule: close after 3 h out of range | IN CONTRACT, never triggered | graceSeconds = 10800 in the Watch event |
| 7 | On any exit, both coins and AERO go straight to the owner's wallet | IN CONTRACT, never triggered | `_close` sends to `g.owner` |
| 8 | Choose the best pool on entry | NOT BUILT (page offers the pools; v1.1 moves later if another pays more) | — |
| 9 | Move to a better pool by itself | v1.1 IN CODE, tested on a Base fork, not on chain | Move.fork + Lifecycle.fork tests |
| 10 | Unused REACT can be taken back | v1.1 IN CODE (`withdraw`), not on chain; the live contract cannot | GuardReactive.t.sol |
| 11 | New pool measured within hours | v1.1 IN CODE: hourly snapshots, net rule measured after 12 h on a fork | Lifecycle.fork test |
| 12 | REACT lasts until the submission | v1.1: timer only, ~0.04 REACT per tick, ~3.4 REACT a day; the live contract spends up to ~700 a day on swaps | measured 19.11 |
| 13 | README + video for the Reactive submission | NOT DONE | — |
