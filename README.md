# LP Guard

A guard for concentrated liquidity positions on Aero (Slipstream) on Base.

You hand your position to the guard. It keeps the position staked, so it keeps earning AERO.
If the pool's price leaves your range and stays out for longer than the grace period you chose,
the position is closed automatically and everything goes back to your wallet: both tokens,
the fees and the AERO. No bot, no server, no keys: the watching is done by a contract on
[Reactive Network](https://reactive.network).

Built for the Reactive Omni Buildathon, track "Set It and Forget It".

**Status: live on Base and Reactive mainnet since 18 Nov 2026. Not audited. Use only small amounts.**

Page: https://araxis33.github.io/lp-guard/

## Mainnet deployment (v1.1, 19 Nov 2026)

- `PositionGuard` (Base 8453): `0x426B54428325Cc674a7f97D435CB0Dff160C01Dd`
- `GuardMeter` (Base 8453, created by the guard): `0xB6eF3b5Fd211aE0e8237E4C5F55d3Ab113EaD297`
- `PoolMath` library (Base 8453): `0xE4Dab7bE03f21f576B78a1E84c4c268cC8D3dF04`
- `GuardReactive` (Reactive 1597): `0xAC3987961BD8e05b707D984023014Af6F4260bac`

Deployed with `script/live.sh deploy`. `GuardReactive` is the guard's clock: on Reactive's Cron1000
event (about every 17 minutes) it asks the guard on Base for the hourly check (price snapshots, the
out-of-range close) or, once a day, the review (against holding, the net rule, a move into a pool of
the same pair that pays more). It does not react to swaps, so a busy pool does not burn REACT.
Its deployer can stop the clock, point it at a new guard and take back the REACT it holds.
What is on chain and what is not is tracked in [STATUS.md](STATUS.md).

Known limit: an NFT sent to the guard with a plain `transferFrom` (not through `deposit`) cannot be
noticed by the guard and has no owner on record. Always use the page or `deposit`.

v1.0 (18 Nov, below) is still on chain: PositionGuard `0x249f0A7145Fa806F64DdeE142b7F8453152b2f15`,
GuardReactive `0x339c03A3De7d128C2b04ee54A90f5bD285fBc7e8` (reacts to every swap, no REACT withdraw).

### Mainnet full loop (18 Nov 2026)

Position #3562712, WETH/USDC CL50 on Aero, about $20 of USDC put in through the page.

1. Origin event on Base: deposit, `Watch` emitted:
   [`0xbb487a54…c489`](https://basescan.org/tx/0xbb487a54508995787231d053293c6509c33c28cc9dfa7a35267d9498149fc489)
2. `GuardReactive` on Reactive picks up `Watch` and subscribes to the pool's swaps
   (`watchedCount(pool) = 1`).
3. Reactive's Cron10000 tick at 21:02:37 UTC triggers the daily review; the callback lands on Base:
   [`0x3a5602ca…6a10`](https://basescan.org/tx/0x3a5602ca74498fc797e995a39b654a99b338987e65a419c1c784603e80456a10)
   `Reviewed(3562712, hold $19.7524, position $19.7516, AERO $0.0102, behind=false)`.

## How it works

```
Base                                   Reactive Network
┌───────────────────┐  Watch event    ┌──────────────────┐
│ PositionGuard     │ ──────────────► │ GuardReactive    │
│ holds the NFT,    │                 │ remembers range  │
│ stakes in gauge   │                 │ and grace period │
└───────────────────┘                 └──────────────────┘
┌───────────────────┐  Swap events             │
│ Slipstream pool   │ ────────────────────────►│ out of range
└───────────────────┘                          │ longer than grace?
┌───────────────────┐  callback                │
│ PositionGuard     │ ◄────────────────────────┘
│ closeByReactive() │ → tokens, fees and AERO to the owner
└───────────────────┘
```

1. `PositionGuard.deposit(tokenId, stake, graceSeconds)` takes the position NFT, stakes it in
   the pool's gauge and emits `Watch`.
2. `GuardReactive` sees `Watch`, stores the range and subscribes to the pool's `Swap` events.
3. On every swap it compares the pool's tick with the range. The first swap outside the range
   starts the clock; a swap back inside resets it.
4. When a swap finds the price still outside after the grace period, `GuardReactive` requests a
   callback, and `PositionGuard.closeByReactive` unstakes, removes all liquidity and sends
   everything to the owner.

## Who can do what

- **The owner** can take the position back untouched (`withdraw`) or close it (`close`) at any time.
- **The Reactive contract** can only ask for a close, and a close pays only the owner. The worst
  it can do is close a position early. It can never move funds anywhere else.
- **Nobody else** can do anything.

## Contracts

| File | Chain | What it does |
|---|---|---|
| `src/PositionGuard.sol` | Base | Holds and stakes positions, closes them for the owner |
| `src/GuardReactive.sol` | Reactive | Watches swaps, requests the close |
| `src/testnet/Probe.sol` | Sepolia | Minimal stand-ins used to prove the round trip on testnet |

## Testnet proof

The full round trip (event on the origin chain, reaction on Reactive, callback on the origin
chain) ran on 12 Nov 2026 with Ethereum Sepolia as origin and Lasna as the Reactive testnet.
The position was closed 96 seconds after the price left the range, with a 60 second grace period.

- `GuardReactive` (Lasna): `0x4c4c214e0F5Cce22bcC8845943813A6f5BFA7A78`
- `ProbeGuard` (Sepolia): `0x89e1475F89130288d34e9233EcFc4b5f82970F06`
- `ProbePool` (Sepolia): `0xEB30695d6188a4B8F8c35F975203F1D517daeE8e`
- The swap on Sepolia that triggered the close request:
  `0xb2528f6edaac91170407c87d6f7004a448ef96731bc11139c9451b8edde7822a`

The whole run cost 0.062 lREACT on the Reactive side (subscriptions and three reactions).

To repeat it, put `TEST_PRIVATE_KEY`, `TEST_ADDRESS`, `ORIGIN_RPC` and `LASNA_RPC` in `.env`, then:

```shell
script/probe.sh fund 0.03ether   # Sepolia ETH -> lREACT
script/probe.sh deploy
script/probe.sh run
```

## Tests

```shell
forge test
```

`test/GuardReactive.t.sol` covers the watching logic. `test/PositionGuard.fork.t.sol` runs
against a fork of Base with a real Slipstream position and gauge (set `BASE_RPC_URL` to use
your own RPC).

## Known limits

- A close is only checked when someone swaps in the pool. In a pool with no swaps nothing happens.
- The close removes liquidity without a minimum-amount check.
- At most 40 watched positions per pool.
- The close returns the two pool tokens as they are. It does not swap them into one token.

## License

MIT
