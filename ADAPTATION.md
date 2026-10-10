# Marginalia companion implementations

This is the Ethereum mainnet contracts-only launch. Deploy exactly these existing application
contracts, each with an empty constructor argument list:

| Contract | Constructor behavior | Runtime / creation bytecode (bytes) |
| --- | --- | --- |
| `MarginaliaRouter` | Locks its own `hook` to `address(1)` | 17,616 / 17,667 |
| `MarginaliaJudge` | Locks its own `hook` and initializes its EIP-712 implementation domain | 11,194 / 12,362 |
| `MarginaliaTreasury` | Locks its own `hook` to `address(1)` | 1,449 / 1,493 |
| `MarginaliaPricer` | Implicit nonpayable, zero-argument constructor; stateless | 7,748 / 7,774 |

These constructors were already suitable for an empty-chain factory deployment and required no
argument changes. They make no external calls. All library calls are internally linked. There is
no owner, pause, upgrade, action fee, token deployment, pool creation or deployment-time initializer
in this launch. Router, Judge and Treasury are implementations, not operational instances: the
later hook creates immutable EIP-1167 clones and initializes them atomically. The implementation
lock is the explicitly requested sentinel, not an invented recipient or dependency address.

The worker prepared and rehearsed the deployment bytecodes; it did not broadcast transactions or
read wallet keys. The manifest/deployment service supplies confirmed addresses. The existing
`MarginaliaImpls.sol` rehearsal constants belong to the later hook launch and must be replaced with
those confirmed addresses at that step. None is used by the four implementation constructors.

## Reproduced imported findings and changes

All six imported findings reproduced. None was dismissed.

1. **`a4534c56…`: posting used a manipulable same-block spot.** On the original code, selling
   2,000,000 MARG, posting a BUY +10% call and buying back caused a falling market to settle RIGHT.
   The mirror SELL attack also settled RIGHT. `test/AuditFindings.t.sol` reproduces both with real
   local v4 swaps and checks that both now settle WRONG. Changes:
   - `src/MarginaliaTypes.sol` adds `PriceWindow`, holding a first accumulator reading and sampled
     price extremes.
   - `src/MarginaliaRouter.sol` adds permissionless `checkpointVenue`, using the existing canonical
     venue validation and deriving orientation/quote before storing history. The mapping is keyed
     by the derived venue, not caller-supplied orientation. `postPrice` passes that history to the
     stateless pricer. A live checkpoint cannot be replaced or have its start reset.
   - `src/MarginaliaPricer.sol` replaces the spot-only posting API with one that requires a prior
     window: at least one hour, an earlier block, and at most six hours since its start. V3/v2 use
     the accumulator TWAP from that start through posting. V4 and the hub use the maximum sampled
     price for a BUY baseline, minimum for SELL, including the current price. The baseline's
     conservative direction is opposite settlement's because it multiplies the target.
   - `src/MarginaliaHook.sol` reads the baseline through its router and exposes its existing pricer
     reference so the router also makes stateless price calls. Settlement and score formulas stay
     unchanged. Hook runtime remains below EIP-170 at 23,864 bytes; creation code is 25,469 bytes.
   - `test/PriceHistory.t.sol` covers accumulator timing, both price orientations, hub manipulation,
     fresh/missing/expired history, window preservation and fuzzed conservative v4 baselines.

2. **`c697391d…`: a fully ineligible ranking permanently trapped a thesis pool.** The original
   `payJudged` reverted `BadAnswer` for a signed ranking containing only id 999. In
   `src/MarginaliaJudge.sol`, an empty filtered head now reaches the hook's existing unranked-slot
   rollover instead of reverting. Signed empty arrays are also accepted as a no-winner result.
   Payment remains one-shot. `test/AuditFindings.t.sol` verifies the entire remaining IMD pool
   rolls to the current week, the old pool is zero, and a second payment fails.

3. **`e454c18b…`: the root manifest described the wrong launch.** The supplied `launch.json`
   contained `kind: univ4_hook`, token/pool entries and no contracts array. It was removed. No
   replacement manifest was written: that is the next launch step's responsibility. `README.md`
   now distinguishes these four implementations from the later token/hook launch.

4. **`58380615…`: unbounded callback storage exhausted the Intake stipend.** The original clone
   ran out of the 200,000-gas stipend when storing a full 120-id ranking. In
   `src/MarginaliaJudge.sol`, only the requested first three ids are stored. Filtering and
   deduplication still occur at payment; entries after the requested head are ignored, including
   when the head contains ineligible ids. Tests cover 5 and 120 ids, EOA and ERC-1271 signatures,
   no-winner answers, duplicate/invalid ids, replay, sender checks, signature tampering, validity
   windows, quorum and retry. `test/JudgeOracle.t.sol` also pins the supplied protocol digest,
   signature and callback selector on a clone. The vector's 5/4 panel is verified by a test-only
   signature harness and is correctly rejected by the application's unchanged 7/5 quorum.

5. **`9129914f…`: v4 reads accepted a pool with no active liquidity.** Removing all fixture
   liquidity still allowed an observation on the original code. `src/MarginaliaPricer.sol` now
   rejects empty v4 venues and the v4 ETH/IMD hub with `EmptyPool`, including observation,
   checkpoint and posting reads. The integration regression verifies the failed observation
   leaves the call to resolve `VoidNoData`; unit tests cover an empty hub too.

6. **`71bebb06…`: forfeiture conversion used a floor derived from the caller's manipulated spot.**
   The original conversion succeeded immediately after a 2,000,000-MARG dump. In
   `src/MarginaliaHook.sol`, the pot sale's 97% floor now uses the router's mature MARG/IMD window
   and its conservative maximum, including the current price. The dump now reverts without
   consuming the pot. Full-fill accounting and the 97% factor remain unchanged. Tests also
   demonstrate conversion resumes after a genuine price decline once a fresh window matures,
   and verify the IMD claims received. The author's optional deposit conversion is unchanged.

## Other launch adaptation

- `src/MarginaliaRouter.sol`, `src/MarginaliaJudge.sol`, `src/MarginaliaTreasury.sol`: each one-shot
  initializer additionally checks `msg.sender == hook_`, matching the explicit requirement that
  the hook initializes its clones. The constructor locks and nonzero configuration checks remain.
  `test/Implementations.t.sol` checks all implementation locks, refusal of another caller, one
  successful initialization and refusal of every repeat.
- `test/helpers/Fixture.sol` seeds a real checkpoint and advances the EVM clock by an hour before
  price-call tests. Existing economic assertions are preserved. `test/fork/MainnetLaunch.t.sol`
  does the same for the selected live venue and explicitly skips when `MAINNET_RPC_URL` is absent,
  allowing the whole suite to run with an empty environment. A skip is not a fork pass.
- `README.md` documents the launch scope, changed posting/conversion preparation, no-winner
  rollover, head-of-three semantics and oracle limitations. This file records every adaptation.
- No build configuration, dependency, environment file, submodule, repository metadata or CI file
  was changed. No dependencies were installed. All delivered regression tests are outside scratch.

## Operational consequences and preserved behavior

Anyone may checkpoint a canonical venue. Price calls and pot conversions need a window between
one and six hours old; an expired window must be restarted and mature again. Theses need no price
history. A stale baseline causes an atomic revert, with the user's funds unchanged. The six-hour
expiry prevents indefinitely stale references; preserving live extrema prevents an attacker from
erasing an honest checkpoint immediately before posting. This is a deliberate, tested behavior
change required by the two reproduced spot-price findings. Tests use `vm.warp` and `vm.roll`, not
real-time waiting.

V4 and hub histories remain sampled price extremes, not accumulators. They rely on honest
permissionless observations, as does the pre-existing settlement design. Spacing alone cannot
prove a price was held at unobserved times; hostile extreme readings can defer conversion or make
a call harder to win until expiry. V3/v2 averages use elapsed accumulator time. The existing
18-decimal assumption, oracle signer trust and canonical venue policy are unchanged.

The judge threshold remains 2 IMD, the configured oracle price 0.5 IMD, the prize split 50/30/20,
and the treasury drip 2% per UTC day. No 0.25% action fee was added. Canonical venue validation,
fee-on-transfer pulls, weekly pools, retry deadlines, sweep accounting, full-fill sales and the
one-hour settlement observation span remain in place.

## Validation

- Original baseline: 33 tests passed before changes. Added regressions failed against the original
  source for the findings described above, then passed against the fixes.
- `forge build --sizes`: passed with the repository's existing Solidity 0.8.26 / Cancun / via-IR /
  optimizer settings. All four implementations and the later hook fit runtime/initcode limits.
- The **unchanged** supplied `Contracts.protected.t.sol` was copied to scratch and run against all
  four compiled creation bytecodes with no constructor arguments on chain id 1. It passed factory
  CREATE2 deployment, predicted-address checks, runtime limits and forbidden-opcode scanning.
- `test/Implementations.t.sol` independently rehearses all four deployments without dependencies
  present on chain, checks linked bytecode behavior, and exercises clone initialization.
- Final `forge build`: passed (compiler/lint warnings, no errors).
- Final `forge test --no-match-path 'test/fork/*'`: **59 passed, 0 failed**; the fuzz test ran the
  configured 256 cases.
- Final plain `forge test`: **59 passed, 0 failed, 1 skipped suite setup**. The mainnet fork suite
  explicitly skipped because no RPC URL was supplied.
- The four local CREATE2 implementation deployments used **8,694,125 gas**, excluding the test's
  opcode-scanning loop and any production factory overhead.
- No live mainnet fork, Slither, Mythril, explorer verification or broadcast is claimed.
