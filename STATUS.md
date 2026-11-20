# What the guard does today — checked on the network

Every line is a promise about the guard. A line is **ON CHAIN** only with a transaction or a read from Base / Reactive mainnet that shows it. Nothing is called done from tests or from a plan.

Contracts: v1.1 (live since 19 Nov) PositionGuard `0x426B54428325Cc674a7f97D435CB0Dff160C01Dd` (Base), GuardReactive `0xAC3987961BD8e05b707D984023014Af6F4260bac` (Reactive). v1.0, retired: PositionGuard `0x249f0A7145Fa806F64DdeE142b7F8453152b2f15`, GuardReactive `0x339c03A3De7d128C2b04ee54A90f5bD285fBc7e8`.

| # | Promise | Status | Proof |
|---|---------|--------|-------|
| 1 | Put USDC in, the guard opens a position in an Aero pool and stakes it for AERO | ON CHAIN | deposit + watch [0xbb487a54…c489](https://basescan.org/tx/0xbb487a54508995787231d053293c6509c33c28cc9dfa7a35267d9498149fc489), position #3562712 staked in gauge 0x46a9…89fb |
| 2 | AERO goes to the owner | ON CHAIN (accruing) | pendingAero 0.265 AERO on 19.11 19:20 |
| 3 | Reactive wakes the guard once a day without a server | ON CHAIN | daily review callback [0x3a5602ca…6a10](https://basescan.org/tx/0x3a5602ca74498fc797e995a39b654a99b338987e65a419c1c784603e80456a10) |
| 4 | Rule: leave when behind "just holding" by more than 3% | IN CONTRACT, never triggered | maxLossBps = 300 read on chain |
| 5 | Rule: leave when the pool pays less than price swings cost | ON CHAIN since 19.11 20:36 (was blind before: needed 3 price snapshots) | netPerDay = +0.81%/day, measured = true |
| 6 | Rule: close after 3 h out of range | **ON CHAIN, triggered by itself** (v1.1) | position #3562712 went out of range 20.11 15:30 UTC ([WentOut 0x53c85dac…b192](https://basescan.org/tx/0x53c85daca1712ef873dea072b92a69d03a32070fe97ae6e3504cd6a15361b192)); the Reactive hourly check closed it 3.5 h later, 19:01 UTC, and sent 0.011354 WETH + 0.1427 AERO to the owner ([Closed 0x2c9e109b…e97b](https://basescan.org/tx/0x2c9e109bce994c487da982138acdd593f079fe258b5dc0e8f2f9159ef641e97b)) |
| 7 | On any exit, both coins and AERO go straight to the owner's wallet | ON CHAIN (v1.1) | the close above paid WETH and AERO straight to the owner; the empty NFT went back to the owner | `_close` sends to `g.owner` |
| 8 | Choose the best pool on entry | NOT BUILT (page offers the pools; v1.1 moves later if another pays more) | — |
| 9 | Move to a better pool by itself | v1.1 IN CODE, tested on a Base fork, not on chain | Move.fork + Lifecycle.fork tests |
| 10 | Unused REACT can be taken back | v1.1 IN CODE (`withdraw`), not on chain; the live contract cannot | GuardReactive.t.sol |
| 11 | New pool measured within hours | v1.1 IN CODE: hourly snapshots, net rule measured after 12 h on a fork | Lifecycle.fork test |
| 12 | REACT lasts until the submission | v1.1: timer only, ~0.04 REACT per tick, ~3.4 REACT a day; the live contract spends up to ~700 a day on swaps | measured 19.11 |
| 13 | README + video for the Reactive submission | NOT DONE | — |
