# Marginalia — notes in the margin of every trade

This launch deploys four Marginalia companion implementations on Ethereum mainnet: Router, Judge, Treasury and Pricer, all with no constructor arguments. The token and Uniswap v4 hook belong to a later launch. Buying MARG through the
router with a note attached posts a falsifiable call on any ERC-20, backed by a flat stamp and a flat
refundable deposit. Calls resolve against a manipulation-resistant settlement price built from permissionless
on-chain observations (v3/v2 TWAPs, the adverse extreme on v4); right calls get their deposit back,
everything else feeds the weekly pools, including thesis prizes ranked by the IMD oracle panel.
No owner, no pause, no upgrade. Spec: `SPEC.md`.

## Contracts

| Contract | Role |
|---|---|
| `Marginalia` | The launch ERC-20: 1,000,000,000 × 1e18 minted once to its deployer (the launch factory). |
| `MarginaliaHook` | The hook (flags `0x20cc`): binds the launch pool, takes the stamp and deposit on noted buys and the 1%/3% fee on sells, holds notes, observations, records and the three pools, and pays out. Its constructor clones the three companions (EIP-1167) from audited implementations and initialises each once. |
| `MarginaliaRouter` | The only path that can attach a note; optionally trades X on Uniswap v4, v3 or v2 in the same transaction so the position is proven, and refuses a note about a token other than the one traded. Plain MARG buys and sells go through any v4 router. |
| `MarginaliaJudge` | The oracle consumer: once a week buys the panel's ranking of the week's long-form theses through the IMD Intake, verifies the EIP-712 attestation, tells the hook whom to pay. Short-form calls are never judged. |
| `MarginaliaTreasury` | Receives prizes and gifts in IMD; drips 2% of its IMD into the pools daily. No withdraw; refuses ETH. |
| `MarginaliaPricer` | Stateless, ownerless helper the hook calls by staticcall (kept out of the hook for code size): score arithmetic (log2, sqrt, difficulty), price reads and the settlement rule: a prior-window baseline (v3/v2 accumulator TWAP, conservative v4/hub extreme); observation reads (v3 tick cumulative, v2 price cumulative, v4 spot, the ETH→IMD hub spot); settle price = TWAP first→last on v3/v2, the observation least favourable to the call on v4 and on the hub leg. An honest observation pins the extreme; the series must span at least one hour. |

## How the pot pays

Every IMD accrual (stamps, sell fees, converted forfeits, treasury drips) splits at accrual time:

| Share | Pool | Paid to |
|---|---|---|
| 50% | the week's leaderboard | every wallet with a positive net score from calls resolved that week, pro-rata by score, capped at 10% per wallet; `claimLeaderboard(week)` after the week ends. Only calls priced on the launch pool book a score; a call on any other venue returns or forfeits its own deposit and scores nothing |
| 30% | the week's thesis prize | the panel's top three long-form theses, 50/30/20, after `requestJudging(week)` and `payJudged(week)` |
| 20% | the day's writer refund | every non-retracted note of the day, equal split, capped at one stamp; `claimRefund(id)` after the day ends |

Unclaimed pools roll forward after 28 days (`sweep`). Nothing in any pool is paid for a price outcome
except through the score, which is difficulty-weighted, netted against wrong calls, and capped.

## Deployment order

1. Contracts-only launch: `MarginaliaRouter`, `MarginaliaJudge`, `MarginaliaTreasury` implementations
   (ownerless; they lock themselves in their constructors so only clones can be initialised, once, by the hook)
   plus the stateless `MarginaliaPricer`.
2. Set the four addresses in `src/MarginaliaImpls.sol`.
3. Later hook launch (its manifest is produced separately): the factory deploys the token and the hook; the hook's constructor clones
   the three implementations and initialises each with itself in the same transaction.

The hook's initcode is 26,016 bytes (EIP-3860 cap 49,152) and its runtime 24,411 bytes (EIP-170 cap 24,576);
`forge build --sizes` is the gate for both.

## Build and test

Solidity 0.8.26, Cancun, via-IR, optimizer 200 runs, `bytecode_hash = "none"`. All dependencies are
vendored under `lib/` (versions in `dependencies.json`); no network is needed to build or run the unit tests.

```sh
forge build --sizes
forge test --no-match-path 'test/fork/*'
```

Without `MAINNET_RPC_URL`, the fork tests explicitly skip, including under plain `forge test`.
The fork rehearsal deploys through the real IMD LaunchFactory on an Ethereum mainnet fork, impersonating
the protocol's launch wallet, and then posts a note through the router:

```sh
MAINNET_RPC_URL=https://... forge test --match-path test/fork/MainnetLaunch.t.sol -vvv
```

## Launch

The next launch step writes the contracts-only manifest for `MarginaliaRouter`, `MarginaliaJudge`,
`MarginaliaTreasury` and `MarginaliaPricer`, with empty constructor argument lists. This repository no
longer carries the old hook-launch manifest. No token or pool is deployed by this launch. The first
three implementations are deliberately locked; only their later, atomically initialized clones hold
application state. See `ADAPTATION.md` for the reproduced findings, changes and validation.

Before posting a price call, anyone calls `router.checkpointVenue(noteParams, venueKey)` for its
canonical venue. Its first checkpoint must be at least one hour old, from an earlier block, and at
most six hours old. Further checkpoints preserve the start and accumulate conservative extremes;
they cannot erase an honest reading. After expiry, checkpoint again and allow a new hour to elapse.
Theses (`targetBps == 0`) do not need price history. This warm-up uses on-chain timestamps; tests
advance the EVM clock and never wait in real time.

For v3/v2, the post baseline is the accumulator TWAP from the checkpoint to posting. For v4 and
the ETH/IMD hub leg, a BUY baseline uses the maximum of the window's readings and the current
price, and SELL uses the minimum. Settlement retains the opposite extremes and its existing
one-hour minimum span. `judge.convertForfeits()` requires the same mature history for the MARG/IMD
venue and enforces 97% of its conservative maximum as the minimum IMD output. A fall beyond the
floor defers conversion until a fresh window supports it. Calls and checkpoint reads reject a v4
venue or hub with no active liquidity.

The oracle callback stores only the requested head of three ids, then filters and deduplicates them
when paid. A signed empty or entirely ineligible head pays no winners and rolls the whole remaining
thesis pool forward. Extra ranking entries beyond the requested head are ignored.

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
must span at least an hour. Accumulator prices weight the elapsed time, and an honest observer can
pin the v4/hub extreme; sampled extremes do not measure prices between observations. Tests: `testTwoBlockPumpObserveUnwindSettlesWrong` (local),
`testTradeAndNoteOnUniswapV3` settles LINK on the live v3 accumulator (fork), `test/Pricer.t.sol`.

The second implementations review (2026-10-11) reopened the launch on eight reproduced findings; all are
answered in `.imd-responses.json` and listed in `ADAPTATION.md`. In short: a price that rounds to zero is
refused everywhere; forfeited MARG converts in tranches (`convertForfeits` sells the largest halving of the
pot the pool absorbs); a stranger's dust cannot void a SELL call (a tolerance rule, since replaced by no SELL
hold rule at all: see the third review below); an observation slot is never owned (a more adverse reading replaces the
latest entry, so a one-block pump is overwritten next block); a note token whose `balanceOf` fails is "not
held" (VoidSold, never a refundable void); an unobserved call scores as wrong though its deposit returns;
a week holds at most 120 theses and refuses the 121st before taking anything; `abandonRequest` invalidates
an unanswered judging request after its deadline so a thesis pool is never swept from under a deliverable
answer; and an attestation must be about this chain. Two findings are disputed as design: any canonical
Uniswap pool is a venue (an author can be its only participant: see the limits below), and the adverse
extreme can be moved against a call by a paid round trip, which is the cost of the rule the launch asks for.

The third review (2026-10-10) reopened the launch on the self-priced venue, now reproduced as a loss path
(a wallet that is the only LP and trader of a hookless X/IMD pool settled a 100x call RIGHT at tier 3 and took
the capped 10% of the week's leaderboard pool for one stamp), and on the residual of the SELL hold rule (a
stranger's gift of the deposit's worth of X still voided a correct SELL call). Both are fixed: only a call
priced on the launch pool books a score (a call on any other venue still returns or forfeits its own deposit
and takes the writer refund, but books nothing and draws nothing from the leaderboard), and SELL calls have no
hold rule at all (any balance-growth rule is a stranger's transfer away from voiding a correct call; the BUY
hold rule is unchanged). The advisory `sqrt(2) == 2` is also fixed. See `ADAPTATION.md` and `.imd-responses.json`.

## v1 scope and known limits

- Price reads assume 18-decimal assets on both sides. Quotes other than IMD, ETH or WETH are refused.
- v4 venues have no on-chain accumulator, so their baseline and settlement rely on sampled extremes rather than a TWAP. These require honest permissionless observations; time spacing alone cannot prove an unobserved price was held continuously. A
  single hostile observation can push a genuine call to WRONG only by moving the pool against it at that
  block, which costs the mover the same swap fees and arbitrage exposure as a pump.
- Sells of MARG pay 3% through any router, or 1% plus the stamp through `sellWithNote` with a note and deposit attached.
- The X trade leg supports v4 pools (including native-ETH pairs), v3 pools and v2 pairs; exact-input only.
- The implementation addresses in `MarginaliaImpls.sol` are rehearsal placeholders; tests etch code there.
- The action fee on follow trades, treasury conversion of ETH/USDC/USDT to IMD, the on-chain ERC-8004 agent
  badge (contract wallets are marked Agent), and attestation re-delivery are specified but not yet built.
- The judge binds an answer to the Intake request it paid for and to this chain id; it does not recompute
  the oracle's canonical question hash (the eligible set can change after the request), so the Intake is
  trusted to deliver each answer under the request it was bought for.
- Venue admission is "any canonical Uniswap pool with liquidity", and an author can be the only LP and trader
  of such a pool. A call priced there therefore books no score and draws nothing from the leaderboard; it is a
  bonded claim that returns or forfeits the author's own deposit on price. Only calls priced on the launch pool
  (MARG/IMD under this hook) score. A depth, age or counterparty policy that would let other venues score is a
  design decision for the requester (there is no owner).
- SELL calls have no hold rule: they settle on price alone. BUY calls must keep their post balance.
- The later hook launch must take the four implementation addresses as constructor arguments (verified on
  first use) rather than requiring their code at construction, so it passes the hook floor's empty chain.
