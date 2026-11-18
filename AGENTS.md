# Rules for reviewers (Codex and others)

This repo exists to give its owner a tool he uses with real money on Base: put USDC into an Aero pool,
keep earning AERO, and get out automatically when the pool stops beating simply holding.

**Only working tools. No filler.** Code that cannot run on the real network, or that no user can reach,
has no value here, however well it is tested.

Every review must answer, before anything else:

1. **Will it work on the real network?** Contract size under 24,576 bytes (`forge build --sizes`),
   gas within limits (callbacks, reviews, wallet estimates), correct mainnet addresses, a deploy path
   that has actually been rehearsed (`script/live.sh` on forks of Base and Reactive).
2. **Can the user reach it?** Every feature must be usable from `web/index.html` with a wallet, or run
   by itself onchain (Reactive). Flag code that nothing calls and that a user cannot trigger.
3. **Does it move money correctly and safely?** Approvals, spenders, minimum outputs, who can close,
   where funds go, what happens when the price moves.
4. **Is it needed before launch?** Name anything that adds scope without getting the tool closer to
   running with the owner's money. It waits until what exists works live.

Then the usual: concrete bugs with file and line, ranked, and say plainly when there are none.
