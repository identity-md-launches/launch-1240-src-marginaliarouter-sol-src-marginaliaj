# Marginalia — notes in the margin of every trade

A Uniswap v4 hook launch on the IMD protocol (Ethereum mainnet, paired with IMD). Buying MARG through the
router with a note attached posts a falsifiable call on any ERC-20, backed by a flat stamp and a flat
refundable deposit. Calls resolve against a manipulation-resistant settlement price built from permissionless
on-chain observations (v3/v2 TWAPs, the adverse extreme on v4); right calls get their deposit back,
everything else feeds a pot that pays the best-argued notes of the day, ranked by the IMD oracle panel.
No owner, no pause, no upgrade. Spec: `SPEC.md`.

## Contracts

| Contract | Role |
|---|---|
| `Marginalia` | The launch ERC-20: 1,000,000,000 × 1e18 minted once to its deployer (the launch factory). |
| `MarginaliaHook` | The hook (flags `0x20cc`): binds the launch pool, takes the stamp and deposit on noted buys and the 1%/3% fee on sells, holds notes, observations, records and the three pools, and pays out. Its constructor clones the three companions (EIP-1167) from audited implementations and initialises each once. |
| `MarginaliaRouter` | The only path that can attach a note; optionally trades X on Uniswap v4, v3 or v2 in the same transaction so the position is proven, and refuses a note about a token other than the one traded. Plain MARG buys and sells go through any v4 router. |
| `MarginaliaJudge` | The oracle consumer: once a week buys the panel's ranking of the week's long-form theses through the IMD Intake, verifies the EIP-712 attestation, tells the hook whom to pay. Short-form calls are never judged. |
| `MarginaliaTreasury` | Receives prizes and gifts in IMD; drips 2% of its IMD into the pools daily. No withdraw; refuses ETH. |
| `MarginaliaPricer` | Stateless, ownerless helper the hook calls by staticcall (kept out of the hook for code size): score arithmetic (log2, sqrt, difficulty), price reads and the settlement rule: post-time spot; observation reads (v3 tick cumulative, v2 price cumulative, v4 spot, the ETH→IMD hub spot); settle price = TWAP first→last on v3/v2, the observation least favourable to the call on v4 and on the hub leg. One honest observation pins the extreme, so a pump must be held for the whole ≥1 h span. |

## How the pot pays

Every IMD accrual (stamps, sell fees, converted forfeits, treasury drips) splits at accrual time:

| Share | Pool | Paid to |
|---|---|---|
| 50% | the week's leaderboard | every wallet with a positive net score from calls resolved that week, pro-rata by score, capped at 10% per wallet; `claimLeaderboard(week)` after the week ends |
| 30% | the week's thesis prize | the panel's top three long-form theses, 50/30/20, after `requestJudging(week)` and `payJudged(week)` |
| 20% | the day's writer refund | every non-retracted note of the day, equal split, capped at one stamp; `claimRefund(id)` after the day ends |

Unclaimed pools roll forward after 28 days (`sweep`). Nothing in any pool is paid for a price outcome
except through the score, which is difficulty-weighted, netted against wrong calls, and capped.

## Deployment order

1. Contracts-only launch: `MarginaliaRouter`, `MarginaliaJudge`, `MarginaliaTreasury` implementations
   (ownerless; they lock themselves in their constructors so only clones can be initialised, once, by the hook)
   plus the stateless `MarginaliaPricer`.
2. Set the four addresses in `src/MarginaliaImpls.sol`.
3. Hook launch (`launch.json`): the factory deploys the token and the hook; the hook's constructor clones
   the three implementations and initialises each with itself in the same transaction.

The hook's initcode is ~24.5 KB (EIP-3860 cap 49,152) and its runtime ~23 KB (EIP-170 cap 24,576);
`forge build --sizes` is the gate for both.

## Build and test

Solidity 0.8.26, Cancun, via-IR, optimizer 200 runs, `bytecode_hash = "none"`. All dependencies are
vendored under `lib/` (versions in `dependencies.json`); no network is needed to build or run the unit tests.

```sh
forge build --sizes
forge test --no-match-path 'test/fork/*'
```

The fork rehearsal deploys through the real IMD LaunchFactory on an Ethereum mainnet fork, impersonating
the protocol's launch wallet, and then posts a note through the router:

```sh
MAINNET_RPC_URL=https://... forge test --match-path test/fork/MainnetLaunch.t.sol -vvv
```

## Launch

`launch.json` is the factory manifest: `MarginaliaHook($poolManager, $token, $factory)`, permissions as
listed, pool paired with IMD at fee 12500 / tick spacing 60. The requester's share seeds the pool
single-sided; the swarm's 10% goes to the launch's distributor.

## Audit history

The swarm's four-specialist panel reviewed the whole repository during the first implementations launch
(job `0c08497a`, 2026-10-10) and merged 14 reproduced findings, led by a self-priced venue (any contract
answering `slot0()` could set a note's price) and a leaderboard sweep that paid twice. All are fixed in
commit `1e6388a`: every price venue and trade venue is now checked against the canonical Uniswap factories
(v3/v2) or recomputed from the full key with liquidity (v4) in the router, sweeps zero their pools, an
unanswered judging request can be retried after three days, quiet weeks' thesis pools sweep once the judge
confirms nothing is pending, implementations lock themselves against stray `init` calls, sells of pot MARG
require a whole fill with a slippage floor, and the Attested class can no longer be self-declared.

The relaunch of those fixes (launch 1217) was then parked by the audit judge on the one finding the first
round had not closed: `observe()` read spot, so a two-block pump → observe → unwind bought a settlement
for swap fees. v0.5 moved settlement into `MarginaliaPricer`: Uniswap v3 and v2 venues settle on the
time-weighted average between the first and last observation (their on-chain accumulators), v4 venues
and the ETH→IMD hub leg settle on the observation least favourable to the call, and the observations
must span at least an hour. A pump now has to be held for the whole span against every arbitrageur, and
any honest observer can pin the price. Tests: `testTwoBlockPumpObserveUnwindSettlesWrong` (local),
`testTradeAndNoteOnUniswapV3` settles LINK on the live v3 accumulator (fork), `test/Pricer.t.sol`.

## v1 scope and known limits

- Price reads assume 18-decimal assets on both sides. Quotes other than IMD, ETH or WETH are refused.
- v4 venues have no on-chain accumulator, so they settle on the adverse extreme rather than a TWAP: a
  single hostile observation can push a genuine call to WRONG only by moving the pool against it at that
  block, which costs the mover the same swap fees and arbitrage exposure as a pump.
- Sells of MARG pay 3% through any router, or 1% plus the stamp through `sellWithNote` with a note and deposit attached.
- The X trade leg supports v4 pools (including native-ETH pairs), v3 pools and v2 pairs; exact-input only.
- The implementation addresses in `MarginaliaImpls.sol` are rehearsal placeholders; tests etch code there.
- The action fee on follow trades, treasury conversion of ETH/USDC/USDT to IMD, the on-chain ERC-8004 agent
  badge (contract wallets are marked Agent), and attestation re-delivery are specified but not yet built.
- The judge binds an answer to the Intake request it paid for; it does not recompute the oracle's
  canonical question hash.
