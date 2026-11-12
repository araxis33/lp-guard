# LP Guard

A guard for concentrated liquidity positions on Aero (Slipstream) on Base.

You hand your position to the guard. It keeps the position staked, so it keeps earning AERO.
If the pool's price leaves your range and stays out for longer than the grace period you chose,
the position is closed automatically and everything goes back to your wallet: both tokens,
the fees and the AERO. No bot, no server, no keys: the watching is done by a contract on
[Reactive Network](https://reactive.network).

Built for the Reactive Omni Buildathon, track "Set It and Forget It".

**Status: prototype. Not audited. Not deployed on mainnet. Do not use with real funds.**

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
