# N E M E S I S — Verified Findings

**Final consolidation of the iterative Feynman ↔ State Inconsistency loop.**
This document is synthesis, not discovery. Every claim below is traceable to one of the
fifteen pass files in `.audit/findings/`; nothing new was hunted here. Where two passes
described the same defect, the better-evidenced version is kept and both are cited. Where a
later pass overturned an earlier conclusion, the correction is carried forward explicitly —
never silently.

---

## Scope

- **Language:** Solidity 0.8.26 (via-ir, optimizer 200 runs). Foundry. Audited tree at
  `[scratch]`, baseline suite **55/55** green, re-verified byte-identical after every
  experiment in every pass.
- **Modules analysed (12 files in `src/` + 2 in `script/`):** `CoinDAOFactory`,
  `deployment/DeploymentLibraries`, `CoinDAOGovernor`, `GovToken`, `CoinDAOVestingWallet`,
  `StakedGovToken`, `RevenueRouter`, `StakingRewards`, `StakingRewardsFunder`,
  `interfaces/IMonolith`, `interfaces/INotifiableRewardReceiver`,
  `interfaces/IRevenueDistributor`, `script/DeployCoinDAO.s.sol`,
  `script/DeployCoinDAOFactory.s.sol`. Deployed-but-not-subclassed base classes
  (`TimelockController`, the five OZ Governor extensions, `VestingWalletUpgradeable`,
  `ERC20Wrapper`/`ERC20Votes`) were inventoried as attack surface in Pass 3.
- **Functions analysed:** ~140 declared entry points and internals across the four Pass-1
  lanes (factory 18, governance 60 incl. inherited entry points, emissions 19, revenue 43),
  plus the complete non-view ABI of all nine deployed contracts enumerated in Pass 3.
- **Coupled state pairs mapped:** **54** across the four Pass-2 lanes (emissions 12 A–L,
  revenue 14 P1–P14, registries 10, seams 18 P1–P17+P5b), plus **8** chain links and
  **24** frozen↔mutable pairs added by Pass 4.
- **Mutation paths traced:** **107** (state variable × mutating function), covering every
  declared-storage write in every scoped file.
- **Nemesis loop iterations:** **4 passes** (Feynman → State → Feynman → State), run as
  **15 blind agent runs** plus Phase 0 recon. Pass 4's delta was 11 findings, all LOW or
  MEDIUM, with **no new HIGH and no new root cause** — the yield curve flattened, which is
  the convergence signal actually observed. Discovery was run blind: no lens was shown
  another's findings before its own write-up.
- **Execution:** ≥183 explicitly named PoC tests (all passing) and **31 source mutations**,
  all on disposable copies under the session scratchpad. `git diff --stat -- [scratch]` empty
  in every pass. Nothing was executed against any external system.

**One structural caveat that bounds several findings.** The external Monolith lender is not
in this tree. Its `pullLocalReserves()` complete-drain / no-revert-on-zero behaviour was
established as a fact and used; every other external-lender behaviour is recorded as a
condition, not assumed. Five open client questions gate severities and are listed at the end.

---

## Nemesis Map (Phase 1 Cross-Reference)

The unified map, reduced to the pairs that carry findings. `✗ GAP` means at least one path
writes one side without the other and nothing reconciles them.

| Coupled pair | Writers of side A | Writers of side B | Sync status |
|---|---|---|---|
| `StakingRewards.rewardRate`/`periodFinish`/`lastUpdateTime` ↔ `_totalSupply` | `notifyRewardAmount` (never reads B) | `stake`/`withdraw`/`exit` (never read A) | **✗ GAP — NM-003.** No minimum-TVL gate anywhere in `src/` (grep: 0 hits) |
| `lastUpdateTime` ↔ `rewardPerTokenStored` | `updateReward` L70 | `updateReward` L69, gated by L95 `_totalSupply == 0` | **✗ GAP — NM-003.** Clock advances while the accumulator does not |
| `StakedGovToken.totalSupply()` ↔ `CoinDAOGovernor` quorum base | `depositFor`/`withdrawTo` (permissionless) | `quorum()` reads `getPastTotalSupply/1000` | **✗ FUSED — NM-001.** The divisor *is* the attacker's deposit |
| `_totalCheckpoints` ↔ `_delegateCheckpoints` | every mint/burn | `delegate` only | **✗ GAP — NM-015.** Quorum counts undelegated stake the tally cannot use |
| `RevenueRouter.govStakingBps` ↔ un-harvested Lender reserves | `setGovStakingBps` (timelock) | accrual inside the external lender | **✗ GAP — NM-011.** Retroactive in both directions |
| `Coin.balanceOf(StakedGovToken)` ↔ `Σ rewards[a]` | `distribute`→`notifyRewardAmount` | `getReward`/`harvestAnd*` | ✓ one-sided only (never under-collateralised, 20,480 calls) — residual is NM-018/NM-019 |
| `StakedGovToken.balanceOf(a)` ↔ `userRewardPerTokenPaid[a]` ↔ `rewards[a]` | `depositFor` | `withdrawTo`/`harvestAndWithdraw` | **✓ SYNCED** — VN-1/VN-P4-4, the strongest positive result in the engagement |
| `Governor._timelock` ↔ router owner ↔ 2 vest owners ↔ timelock role set ↔ registry | `updateTimelock` (moves 1 of 6) | nothing moves the other five | **✗ GAP — NM-004.** `RevenueRouter.treasury` has no setter at any privilege level |
| `CoinDAOFactory.monolithBeneficiary` ↔ ∀ `monolithVesting._owner` | `acceptMonolithBeneficiary` | `initialize` at L470, per-deployment snapshot | **✗ GAP — NM-009.** Rotation moves nothing already stamped |
| `deployments[i].revenueRouter` ↔ `lender.operator()` | L502 push | external `acceptOperator` at L453, never read back | **✗ GAP — NM-010.** Three caches of one external fact, no setter on any |
| `usedDeploymentKeys[key]` ↔ the 10 derived addresses | `_reserveDeploymentKey` | `predictCoinDAOAddresses` ignores it | **✗ GAP — NM-020** |
| `StakingRewardsFunder.nextTranche` ↔ `rewardsToken.balanceOf(funder)` | `fundNextTranche` (terminal at 4) | anyone, forever, by transfer | **✗ GAP — NM-014.** Absorbing state |
| `allocationFor()` outputs ↔ `GOV_TOKEN_SUPPLY` | `allocationFor` (subtraction residual) | 5 transfers in Phase 7 | **✓ EXACT** across all 2001 legal bps — VN-2/VN-C |
| `VESTED_TREASURY_WEIGHT` ↔ the treasury transfer | nothing reads the constant | residual absorbs any drift | **✗ GAP — NM-017.** 300,000 GOV divergence demonstrated with 55/55 green |
| `FOUR_YEARS` (vest deadline) ↔ `4 × COIN_STAKING_REWARD_DURATION` (emission floor) | `initialize` at L457/463/470/479 | `fundNextTranche` L73, unbounded above | **✗ GAP — NM-016.** The identity appears **0 times** in `src/`, `script/` or `test/` |

---

## Verification Summary

Severity per the skill's table. **No finding is graded above the harm that was measured** —
several passes deliberately graded real mechanisms LOW when the measured loss was dust, and
that calibration is preserved here.

| ID | Discovery path | Coupled pair / root cause | Breaking op | Severity | Verdict |
|---|---|---|---|---|---|
| NM-001 | **Cross-feed P1→P2→P4** | stGOV supply ↔ quorum base | `quorum()` / `propose()` | **HIGH** | TRUE POS |
| NM-002 | **Cross-feed P2→P3→P4** | immediate allocation ↔ `_validate` predicate | `_deployCoinDAO` L491-493 | **HIGH** | TRUE POS |
| NM-003 | **Cross-feed P1→P2→P3→P4** | `rewardRate` ↔ `_totalSupply` | `fundNextTranche()` | **HIGH** | TRUE POS |
| NM-004 | **Cross-feed P2→P3** | `Governor._timelock` ↔ 5 orphans | `updateTimelock` | MEDIUM | TRUE POS |
| NM-005 | **Cross-feed P2→P3** | 5 governance params ↔ no bounds | any one proposal | MEDIUM | TRUE POS |
| NM-006 | Feynman-only (P1+P3) | `Queued` state ↔ no cancel edge | `queue()` | MEDIUM | TRUE POS |
| NM-007 | **Cross-feed P2→P3** | `PROPOSER_ROLE` ↔ Governor's standing | `grantRole` by proposal | MEDIUM | TRUE POS |
| NM-008 | **Cross-feed P1→P2→P3** | wallet `_owner` ↔ 2,800,000 GOV | `renounceOwnership`/`transferOwnership` | MEDIUM | TRUE POS |
| NM-009 | **Cross-feed P1→P2→P4** | `monolithBeneficiary` ↔ per-deployment owners | `acceptMonolithBeneficiary` | MEDIUM | TRUE POS |
| NM-010 | **Cross-feed P1→P2→P3→P4** | 3 caches ↔ 1 external role | Phase 5 L452-453 | MEDIUM | TRUE POS (conditional) |
| NM-011 | **Cross-feed P1→P2→P3→P4** | `govStakingBps` ↔ un-harvested stock | `setGovStakingBps` / `distribute` | MEDIUM | TRUE POS |
| NM-012 | **Cross-feed P1→P2** | `rewards[exiter]` ↔ un-harvested stock | `withdraw`/`withdrawTo` | MEDIUM | TRUE POS |
| NM-013 | **Cross-feed P1→P2** | mint path ↔ external lender liveness | `depositFor` | MEDIUM (lead) | TRUE POS, trigger external |
| NM-014 | **Cross-feed P2→P3→P4** | `nextTranche` ↔ funder GOV balance | terminal `fundNextTranche` | MEDIUM | TRUE POS |
| NM-015 | **Cross-feed P1→P4** | total supply ↔ delegated votes | `depositFor` without `delegate` | MEDIUM | TRUE POS (raised from LOW) |
| NM-016 | **Cross-feed P3→P4** | vest deadline ↔ emission floor | `fundNextTranche` timing | LOW | TRUE POS |
| NM-017 | **Cross-feed P1→P4** | `VESTED_TREASURY_WEIGHT` ↔ residual | none — no reader exists | LOW | TRUE POS |
| NM-018 | **Cross-feed P1→P2** | two floor divisions in series | `distribute`→`notifyRewardAmount` | LOW | TRUE POS |
| NM-019 | State-only (P2) | held balance ↔ accounted balance | any direct transfer in | LOW | TRUE POS |
| NM-020 | **Cross-feed P1→P2** | `usedDeploymentKeys` ↔ prediction validity | `predictCoinDAOAddresses` | LOW | TRUE POS |
| NM-021 | **Cross-feed P1→P4** | allowance ↔ transferability | `approve`/`permit` | LOW | TRUE POS |
| NM-022 | **Cross-feed P2→P3→P4** | caller standing ↔ global state written | `getReward`/`depositFor(x,0)` | LOW | TRUE POS (loss re-priced) |
| NM-023 | **Cross-feed P1→P4** | `_delegateCheckpoints[S]` ↔ present exposure | `castVote` after exit | LOW | TRUE POS |
| NM-024 | **Cross-feed P1→P4** | env input ↔ launched parameters | `run()` | LOW | TRUE POS |
| NM-025 | Feynman-only (P1+P3) | declared type ↔ validated property | `_validateImplementations` | LOW | TRUE POS |

**Totals: 0 CRITICAL · 3 HIGH · 12 MEDIUM · 10 LOW.** 22 of 25 are cross-feed; 2 are
Feynman-only; 1 is State-only.

---

## Verified Findings

### NM-001 — Quorum is a fraction of the attacker's own staked supply, and no parameter value fixes it

**Severity:** HIGH
**Source:** Feynman P1 (governance FF-001, factory FF-01, convergent and blind) → State P2
(seams SI-003, revenue SI-011) → State P4 (allocation SP4-003/-004/-005/-006)
**Verification:** Hybrid — PoC + 3 mutation runs (P1) + a 7-value numerator sweep and a
mutant `FlooredQuorumGovernor` (P4). **Level 4** throughout, with controls.

**Coupled pair:** `StakedGovToken` total supply ↔ `CoinDAOGovernor` quorum base.
**Invariant that must hold and does not:** the bar a proposal must clear must not be a
function of the proposer's own contribution.

**Feynman question that exposed it:**
> Q1.4 — *"Is this check SUFFICIENT for what it is trying to prevent?"* applied to
> `quorum(t) = stGOV.getPastTotalSupply(t) * numerator / denominator`.

**State Mapper result that fused it (P4 `test_SP4_003_…`):** d(votes)/d(quorum) = **1000**;
self-sufficiency rises with the attacker's own contribution (52.63× → 100× against a
4,500,000 honest float). The pair is not merely coupled — **the defence recovers 0.1 % of
what it defends against.**

**Breaking operation:** `CoinDAOGovernor.quorum()` at `src/CoinDAOGovernor.sol:64-66`,
with `quorumDenominator()` overridden to 1000 at L68-70 and the factory's
`GOVERNOR_QUORUM_NUMERATOR`/`GOVERNOR_PROPOSAL_THRESHOLD` at `CoinDAOFactory.sol:33-34`.

**Consequence (executed):** a lone staker is always the entire electorate. Composed with
NM-002 the acquisition cost is **zero** — the launcher is handed 500,000 stGOV. Executed end
to end: propose → vote → queue → execute, seizing `RevenueRouter` ownership.

**Corrections carried forward — both material:**
1. **The `quorumDenominator` override is NOT the root cause.** This was the P1 author's own
   first write-up and was **refuted by their own mutation test**: restoring the OZ default of
   100 leaves the capture working, and even a 100 % quorum leaves it working. Reported in
   corrected form. *Had the first version shipped, the client would have "fixed" the
   denominator and remained fully exposed.*
2. **The cost basis was replaced.** P3 (FP3-001) showed "0.1 % of supply" is an *acquisition*
   cost that assumes the attacker buys in. Any fix must be priced against **500,000 stGOV,
   not 10,000**.

**Fix:** **Retire the quorum remedy entirely.** Both candidates were applied and killed
(see Killed Fixes KF-4, KF-5). The fix must be placed at the *amount of liquid GOV that may
reach a caller-supplied address at launch* — see NM-002. You cannot bound a quantity by a
fraction of itself.

---

### NM-002 — The liquid 5 % immediate allocation escapes both documented deployer limits and is unilateral control of the DAO from block zero

**Severity:** HIGH (by composition; MEDIUM standalone)
**Source:** **Feedback Loop** — P3 (composition FP3-001) asked Q4.3 of *Pass 1's finding*
rather than of the code, enriched by P2 registries SI-009 (`deployerRecipient` unvalidated)
→ P4 allocation SP4-001/-002/-009 → P4 rootcause SP4-003
**Verification:** PoC ×3 + control. **Level 4.**

**Breaking operation:** `CoinDAOFactory.sol:491-493` — the immediate allocation is routed to
`govParams.deployerRecipient` whenever one is named, **including when the vested stake is
zero**, which is exactly the case `_validate` (L560) does not police.

**The two dropped qualifiers** (independently re-verified for this consolidation —
`deployerRecipient` has exactly 4 hits in `src/`, of which **exactly one** is a guard, and
that guard fires only when `deployerStakeBps != 0`):
- `MAX_DEPLOYER_STAKE_BPS = 2_000` bounds only the *vested* half.
- `deployerVesting.initialize(..., FOUR_YEARS)` locks only the *vested* half.

**Executed evidence (L4):**
```
branch deployerStakeBps = 0, deployerRecipient = launcher
  GOV paid liquid to deployerRecipient : 500,000.000000000000000000   (5.00% of supply)
  GOV held by the timelock at launch   :       0.000000000000000000   <- governance funded with NOTHING
  proposal threshold                   :  10,000                      <- launcher holds 50x it
  quorum at that timepoint             :     500                      <- getPastTotalSupply/1000
  ONE proposal -> RevenueRouter.owner() == the launcher               (asserted)

the cap does not cap:
  bps = 2000 -> TOTAL to deployerRecipient : 2,397,959.18  = 23.98% of supply
                MAX_DEPLOYER_STAKE_BPS says : 20.00%
```
**At genesis the immediate allocation is not 5 % of supply — it is 100 % of the *free*
supply** (SP4-002): the other 9,500,000 GOV is encumbered in vests and the emission stream.

**Control (so the check could have failed):** the identical launch with
`deployerRecipient == address(0)` puts the same 500,000 GOV in the timelock and that address
**cannot even call `propose()`**. The measurement discriminates the branch, not the setup.

**Engaging with the comment that exists** (workspace rule): `CoinDAOFactory.sol:490` says
*"A missing deployer recipient sends only the liquid allocation to the timelock; vested
deployer stake is disallowed."* That comment is accurate — the routing is deliberate. The
finding is not "the deployer should not get 5 %". It is that (a) L281-282 describes the same
5 % as a *system* slice in a 65:5:28 split, so two comments in one file assign the same money
to two different parties; (b) `_validate` polices the recipient only on the branch where the
money is *smaller*; and (c) **the launch record contains 14 addresses and zero amounts**
(SP4-009), so the honest and the capturing configuration are indistinguishable on chain.

**Fix (the only surviving candidate).** Cap or vest the liquid-to-private amount at the
factory. Option A (`_validate`: reject a named recipient when `bps == 0`) was applied as a
mutation and **defeated for 51.02 GOV** — see KF-3. Ship SP4-009 Option C (emit the recipient
and the amounts) unconditionally and immediately: it costs nothing, prevents nothing, and is
the precondition for anyone outside the launch transaction observing which configuration was
used. **Open product question Q-5 gates the rest and belongs to the client, not the audit.**

---

### NM-003 — The emission clock is opened against an empty or dust pool; the unstreamed GOV is destroyed or captured at the opener's option

**Severity:** HIGH
**Source:** **The engagement's clearest cross-feed chain.** P1 Feynman (emissions FF-001,
factory FF-02) and P1 State-equivalent (P2 emissions GAP-01/GAP-02) converged **blind** on
the same two lines by different routes → P2 seams SI-002 produced a variant *neither Pass-1
lens could reach* → P3 composition FP3-002 showed the loss is **captured, not burned**, on
the fresh path too, and killed both proposed fixes → P4 permissionless P4-01 found the
recurring boundary auction.
**Verification:** PoC ×10+ across four passes, with controls and resolution measurements.
**Level 4** against factory-deployed systems.

**Coupled pair:** `StakingRewards.rewardRate`/`periodFinish`/`lastUpdateTime` ↔ `_totalSupply`.
`notifyRewardAmount` never reads `_totalSupply` for a gate; `stake` never reads `rewardRate`.
Independently re-verified for this consolidation: **no minimum-TVL or minimum-supply gate
exists anywhere in `src/`.**

**Masking code that hides it** (`StakingRewards.sol:95`, verified verbatim):
```solidity
function rewardPerToken() public view returns (uint256) {
    if (_totalSupply == 0) return rewardPerTokenStored;   // sufficient against div-by-zero;
    ...                                                   // silently decides the VALUE question
}
```
The line is sufficient to prevent the division by zero. It is not sufficient to prevent the
value consequence it silently decides: **the interval is discarded, not paused.**

**Engaging with the design comment** (`StakingRewards.sol:145-149`, verified verbatim):
> *"Rewards notified while `_totalSupply == 0` … are permanently locked … This is accepted by
> design — the window between tranche funding and the first staker is expected to be short.
> Do not add queueing here without also gating StakingRewardsFunder…"*

The objection is **not** to the acceptance. It is that the *caller falsifies the premise*:
`CoinDAOFactory.sol:487` calls `fundNextTranche()` in the same transaction that created the
staking token. And the comment's second sentence is correct and load-bearing — it is exactly
the constraint that killed two proposed fixes.

**Three measured trigger variants, one root cause:**

| variant | path | measured outcome |
|---|---|---|
| **Burn** (P1 FF-001 / P2 GAP-01) | `deploy()` — staking token supply provably 0 | 5,787 GOV destroyed **per idle day**; 90-day delay strands 520,890 GOV (8.01 % of the allocation) permanently |
| **Capture** (P2 seams SI-002) | `deployForExistingCoin()` — token pre-exists with live supply | launcher stakes 1 wei in the launch transaction; clears the proposal threshold in **1.73 days**; upper bound is the entire 2,112,500 GOV tranche |
| **Capture at option** (P3 FP3-002) | `deploy()` too | `test_FP3_002_…`: **2,112,499.99999999996 GOV captured atomically**; control `test_FP3_002_control_…`: **173,630.13 GOV destroyed instead over 30 idle days — same quantity, launcher's choice** |
| **Boundary auction** (P4 P4-01, MEDIUM standalone) | tranches 1–3, permissionless | 1 wei of staking token + `fundNextTranche()` in one transaction: **146,917.81 GOV in 30 days.** Resolution: identical transaction with a real staker present yields **146 wei** — 10²¹ of discrimination |

**Why the boundary auction is structural, not opportunistic:** after `periodFinish` a staked
position earns **exactly zero** until the next tranche is notified (measured: 0 yield across
45 days). The tranche boundary is therefore precisely the moment a rational pool is emptiest
— and precisely the moment `fundNextTranche()` becomes callable by anyone. `StakingRewardsFunder`
contains **zero occurrences of `msg.sender`** (independently re-verified) and no access
control of any kind; every guard in it is about *time* and *balance*, never about *who*.

**Fix — both proposed remedies were applied as mutations and killed (KF-1, KF-2).** The
honest recommendation is the one P4 states: **change nothing at L487 alone**, and state the
property — each tranche boundary is a permissionless auction whose prize is
`rewardRate × vacancy`. A real fix needs a minimum-TVL gate *with a time-based escape*, and
choosing that threshold is a business decision. **The report must not repeat "the window is
expected to be short" without saying who chooses when the window starts.**

---

### NM-004 — `updateTimelock` moves one of six bindings, and `RevenueRouter.treasury` makes a complete migration impossible

**Severity:** MEDIUM
**Source:** **Feedback Loop** — State P2 (seams SI-001, SI-001b) → Feynman P3 (inherited
F-02, F-05, F-08; irreversibility FI-001, FI-002)
**Verification:** PoC ×5 + 2 controls + mutation M1. **Level 4.**

**Coupled pair:** `Governor._timelock` ↔ `RevenueRouter._owner` ↔ `treasuryVesting._owner` ↔
`monolithVesting._owner` ↔ the timelock's role set ↔ `deployments[i].timelock` ↔
**`RevenueRouter.treasury`**.

**Breaking operation:** `Governor.updateTimelock` — inherited, `onlyGovernance`, **zero
occurrences in `src/`, `script/`, `test/` or the docs.** It moves one of six bindings.

**The correction that changed the finding (F-05, P3):** Pass 2's SI-001 stated flatly *"It is
irreversible. Every repair path runs through the timelock that just became unreachable."*
**That is true only on the branch Pass 2's own PoC exercised.** `Governor.relay` — also with
zero occurrences anywhere in the repository — recovers every orphan in **one proposal**,
*provided the destination timelock granted the Governor `PROPOSER_ROLE`*:
```
ONE recovery proposal through T_new:
  governor.relay(T_old, 0, T_old.scheduleBatch([router.transferOwnership(T_new),
                                                treasuryVesting.transferOwnership(T_new),
                                                govToken.transfer(T_new, 500_000e18)], delay))
  -> after 2 days, a bystander executes (EXECUTOR == address(0))
  router.owner() == T_new    treasuryVesting.owner() == T_new    500,000 GOV recovered
```
**Control (`test_FP309control`, PASS):** the identical migration to a destination *without*
`PROPOSER` for the Governor — `queue()` reverts, `relay` can never be called, nothing is
recoverable. **The single bit that decides between "fully recoverable" and "28 % of supply
gone forever" is whether the destination timelock's constructor listed the Governor as a
proposer.** The delivered finding is therefore **conditional, not unconditional**, and
Pass 2's Option B (a `hasRole` pre-check on `updateTimelock`) is worth *more* than Pass 2
credited it — it checks exactly that bit.

**What survives the correction and is unconditional (F-02 / FI-001):**
`RevenueRouter.treasury` is written once at `RevenueRouter.sol:57` and has **no setter at
any privilege level** — independently re-verified for this consolidation: `setTreasury`,
`setLender`, `setRewardsDuration` and `recoverERC20` return **exactly one grep hit across
all of `src/`, and it is a comment** (`StakingRewards.sol:172`). So **even the good branch is
a partial recovery**, and Pass 2's SI-001 Option A ("document the batched migration
procedure") **is not writable as stated** — no complete migration exists to document.

**Second-order (FI-002):** the natural post-migration cleanup (revoking the old timelock's
roles) converts the treasury leak into permanent loss with no actor able to exit.

**Fix.** Mutation **M1 (add `RevenueRouter.setTreasury`) SURVIVED**: 55/55 project tests still
pass and the finding closes. Ship it, plus the migration runbook *including the `relay`
payload shape* and `test_FP309` as a regression test. A repair path that exists and is
undiscoverable is close to a repair path that does not exist.

---

### NM-005 — Five of the six inherited governance parameters are unbounded, undocumented and untested; each is one proposal from a permanent end to the DAO

**Severity:** MEDIUM
**Source:** **Feedback Loop** — State P2 SI-001 exposed that the inherited surface was
unexamined → Feynman P3 (inherited F-01, irreversibility FI-004, FI-008)
**Verification:** PoC ×6 with controls, bounds read from the base classes. **Level 4.**

`GovernorSettings._setVotingPeriod` rejects only `0` (read at `GovernorSettings.sol:89-94`);
`type(uint32).max` is accepted and was executed. `updateQuorumNumerator(1000)` is terminal
whenever any staked GOV is undelegated — and the only escape is owned by the passive holder
rather than by governance (FI-004). The repair for each needs a proposal that can no longer
be created, voted or queued.

**Amplifier (FI-008):** the launch-time `renounceRole(DEFAULT_ADMIN_ROLE)` at
`CoinDAOFactory.sol:430` is **correct and deliberate** — it removes the factory as a standing
backdoor. Its consequence is that **the passed proposal is the system's single point of
failure**, and Pass 3 counted **nine** inherited, undocumented, untested one-proposal actions
that destroy it. Mutation **M2 proves the shipped ordering fails safe**: moving `renounceRole`
before the `grantRole` calls makes **12 project tests fail** — every launch reverts.

**Fix:** bound the five parameters in the Governor subclass, and document the nine
one-proposal actions in a governance runbook. Both failure modes: bounding creates a
governance action that can no longer be taken at all, so the bounds must be chosen with the
DAO's own emergency needs in mind.

---

### NM-006 — A queued proposal cannot be cancelled by anyone; `CANCELLER_ROLE` is decorative

**Severity:** MEDIUM · **Discovery path: Feynman-only** (P1 governance FF-004 → P3 inherited
F-04, both Feynman; no State pass touched it)
**Verification:** PoC + explicit negative grep. **Level 4.**

`Governor._validateCancel` requires `Pending` (`Governor.sol:787-789`), and
`GovernorTimelockControl._cancel` only touches the timelock when `_timelockIds[id] != 0`,
which is impossible while `Pending`. **The two conditions are mutually exclusive**, so the
`CANCELLER_ROLE` granted to the Governor at launch is unreachable through the Governor's own
surface. There is no guardian (factory FF-10). The 2-day timelock delay therefore buys
observation but no remedy.

---

### NM-007 — Granting `PROPOSER_ROLE` is not a subordinate permission: the grantee can evict the Governor and take everything

**Severity:** MEDIUM · **Cross-feed P2→P3** (inherited F-03)
**Verification:** PoC `test_FP306`. **Level 4.**

Nothing in the code, tests or docs says so. Once the grantee evicts the Governor, the Governor
is the only proposer, so **there is nobody left to propose the repair** — irreversible
immediately, unilaterally, in 2 days.

---

### NM-008 — The vesting wallets' inherited `Ownable` and payout surface is reachable by one proposal on the wallet holding 28 % of supply

**Severity:** MEDIUM
**Source:** **Cross-feed P1→P2→P3** — P1 governance FF-003/FF-005 (the 2 % wallet) → P2
registries SI-010 + seams SI-004 → P3 composition FP3-006 and inherited F-06 **raised the
ceiling 14×**; P3 irreversibility FI-007
**Verification:** PoC ×4. **Level 4.**

`CoinDAOVestingWallet` is a 10-line wrapper; its entire non-view ABI is
`initialize, release, renounceOwnership, transferOwnership` (ABI-verified). Consequences,
each executed:
- `renounceOwnership()` permanently bricks the allocation — **2,742,465 GOV** on the treasury
  wallet, reachable by one proposal, versus the 200,000 GOV the original finding priced.
- `transferOwnership` is unconstrained and single-step; `_erc20Released` is not per-owner.
- There is no cliff: a "four-year allocation" is sellable and starts paying in the next second.
- A self-owned wallet inflates `_erc20Released` without bound while its balance never moves
  (SI-010).

**Fix:** override `renounceOwnership` on the wallets. Ship it together with the identical
one-sided fix for `RevenueRouter` (SI-005) — cheaper than either alone.

---

### NM-009 — `monolithBeneficiary` rotation is a partial operation, and no launch record can detect it

**Severity:** MEDIUM
**Source:** **Cross-feed P1→P2→P4** — P1 governance FF-006 (the script verifies twelve
contracts exist and nothing about where the money or the roles went) → P2 registries
SI-001/SI-002/SI-011 measured it → P4 rootcause SP4-002 measured the **verification
resolution at zero**
**Verification:** PoC + 6 single-line authority mutations. **Level 4.**

`CoinDAOFactory.sol:470` reads a **mutable global** into an **immutable per-deployment
owner**. Rotation moves nothing already stamped: with 5 launches before a rotation,
**1,000,000 GOV** stays under the old beneficiary's control, growing linearly with launch
count with no ceiling — and chained with NM-008, the rotated-out party can destroy what they
kept. Nor can any caller pin the value they simulated against (SI-002).

**The Pass-4 addition that makes it worse:** six single-line mutations of the six one-way
authority steps were each re-run against the project suite **and against the deploy script's
own `_verifyDeployment`**. Measured verification resolution: **zero in the script, one test
in the suite** — and that one assertion is written `hasRole(bytes32(0), …)`, which the Pass-4
author found only *because a mutation failed and disproved their own absence claim*. That
self-correction is recorded in the source file.

---

### NM-010 — The one-way external-role handoffs are never verified and cannot be retried

**Severity:** MEDIUM (conditional on external lender behaviour)
**Source:** **Cross-feed P1→P2→P3→P4** — P1 factory FF-03 + revenue FF-017 → P2 registries
SI-003 (with the fix's resolution measured) + seams SI-005/SI-006 → P3 composition FP3-003 +
irreversibility FI-003 → P4 rootcause SP4-004
**Verification:** Hybrid — trace + PoC with a substituted external contract. **Level 4 with
a substituted lender**, stated as conditional.

Phase 5 (`CoinDAOFactory.sol:452-453`) nominates and accepts the lender `operator` role and
**never reads it back**; `hasCoinDAO[lender]` then makes the launch unrepeatable. Three
contracts cache one external fact and none has a setter. Additions from later passes:
- **FP3-003:** the *attach* path inherits its lender `manager` silently, and every check that
  would have caught it lives on the branch where it cannot happen.
- **SP4-004:** Phase 5 nominates the router while the factory is still the lender's operator,
  so a harvest inside that window is paid to a contract with no outflow.
- **FI-003:** renouncing the router does not merely freeze the split — it destroys the only
  path back to the operator role. (The refutation that `acceptLenderOperator` is one-shot
  *strengthened* this finding rather than killing it: the recovery path exists, which is why
  destroying it costs something.)

**Fix — SURVIVED mutation.** M-S2 (`if (lender.operator() != revenueRouter) revert` after
L453): **19/19 project tests still pass** and the target case is caught. Compatible with
every intended flow.

---

### NM-011 — `govStakingBps` retroactively re-prices already-accrued revenue in both directions, and `distribute()` is permissionless

**Severity:** MEDIUM
**Source:** **Cross-feed P1→P2→P3→P4** — P1 revenue FF-002 (one direction) + factory FF-04 →
P2 revenue SI-002 (**both** directions, treasury exposed too) + SI-007 → P3 composition
FP3-005 → P4 permissionless P4-03
**Verification:** Hybrid + invariant fuzz. **Level 4.**

The split is read at harvest time and applied to the whole un-harvested stock sitting inside
the external lender. `DEFAULT_GOV_STAKING_BPS = 10_000` routes 100 % to stGOV, so a 1-wei
stake takes all of it; and whoever calls `distribute()` first decides which split applies.

**The P3 addition that inverts the impact:** above roughly `stGOV_supply / 1e18` Coin wei per
harvest, the permissionless lever **destroys** revenue rather than redistributing it —
measured at 180,000,000 wei stranded with an index delta of 0. Open client question Q-4 gates
this.

---

### NM-012 — Exits forfeit un-harvested revenue to the remaining stakers, and the forfeiture is back-runnable

**Severity:** MEDIUM · **Cross-feed P1→P2** (revenue FF-003 full exit → P2 revenue SI-001,
partial `withdrawTo` case new)
**Verification:** Hybrid + 20,480-call invariant suite. **Level 4.**

The exiter's share of revenue accrued-but-not-yet-harvested is re-priced to the stayers, and
the moment is chooseable by anyone because `distribute()` is permissionless.

---

### NM-013 — The only mint path is hard-coupled to a live external Lender; the electorate is a one-way ratchet

**Severity:** MEDIUM, **stated as a lead** (was HIGH)
**Source:** **Cross-feed P1→P2** — P1 revenue FF-004 → P2 seams §7 closed half of it → P3
masking FP3-03 converged blind on the same mechanism
**Verification:** Hybrid; the trigger is external and unverifiable in scope.

`depositFor` is the only mint path, and it harvests through `RevenueRouter` → the external
lender before minting. Entry to the electorate depends on an external contract; exit does
not; quorum follows the survivors down.

**Correction carried forward — this finding was materially downgraded.** The established
`pullLocalReserves()` fact (complete drain, early-returns rather than reverting on zero)
**closes the zero-reserve half** — confirmed at L4: a launch with no accrued revenue admits
deposits normally. The residual is a revert for some *other* market reason, which is now
**unevidenced**. See also the companion refutation of FF-005 under False Positives.

---

### NM-014 — The funder reaches an absorbing state; GOV that arrives afterwards is permanently sunk

**Severity:** MEDIUM
**Source:** **Cross-feed P2→P3→P4** — P2 emissions GAP-06 (NEW, State) → P3 masking FP3-04
root-caused it to **one line** and **exonerated `renounceOwnership()`** → P4 permissionless
P4-02
**Verification:** PoC + mutation M1 with its created failure mode priced. **Level 4.**

After four tranches, `nextTranche == 4` is terminal, `rewardsDistribution` is frozen, and
`owner()` is `address(0)` — while both GOV balances remain freely increasable by anyone,
forever. Executed: 3,163,184.93 GOV sunk in the funder and 3,336,815.07 GOV sunk in
`StakingRewards`, with `trancheAmount(3)` **actively advertising the top-up as claimable**
while `fundNextTranche()` reverts forever.

**One decision, three defects (FP3-04).** `_trancheAmount`'s `if (tranche < TRANCHE_COUNT - 1)`
puts the balance sweep *inside* tranche 3 rather than in a tranche 4 (verified verbatim). That
single choice produces simultaneously: `trancheBps(3)`'s published 17.5 % becoming unreachable
code; `if (balance < amount)` at L80 comparing **two reads of the same value** on the one
tranche whose amount is unbounded and donation-influenceable; and the absorbing state itself.
Measured: donate 5 GOV and `trancheAmount(3)` absorbs it silently — *the published schedule
and the actual final tranche agree only in the case where nothing unexpected has happened,
which is exactly the case in which no check was needed.*

**Correction carried forward — `renounceOwnership()` is EXONERATED.** Two lanes attributed the
irreversibility to `CoinDAOFactory.sol:488` (emissions FF-001 and the factory lane's inline
annotation `renounceOwnership(); <-- makes it permanent`). **Neither checked whether the
factory could have acted as owner had the line been absent.** `forge inspect CoinDAOFactory
methods` shows the factory's entire mutating external surface is `deploy`,
`deployForExistingCoin`, `setPendingMonolithBeneficiary`, `acceptMonolithBeneficiary` — **no
factory function can act as the owner of a deployed `StakingRewards`.** The position was
**already unrecoverable before L488 ran**; omitting it would only have made a block explorer
show a non-zero owner and the position *look* recoverable. `renounceOwnership()` is the honest
line here, not the fatal one. **Both lanes' write-ups must be corrected in the report.**

---

### NM-015 — Quorum counts undelegated stGOV while the tally counts only delegated votes; honest staking is counter-productive

**Severity:** MEDIUM (**raised from LOW** by P4)
**Source:** **Cross-feed P1→P4** — P1 governance FF-011 (graded LOW) → P4 allocation SP4-006
**Verification:** PoC + control. **Level 4.**

Executed: 4,500,000 undelegated honest stake → the capturing proposal still **Succeeded**.
Control: the *same* stake delegated → **Defeated**. **The only working brake in the entire
chain is the delegated against-vote**, and the design's own revenue incentive recruits stakers
who never delegate. The re-grade is the P4 author's own recommendation and is carried here:
it is not an accounting quirk.

---

### NM-016 — The system has two four-year clocks; one is an enforced deadline and the other only a floor

**Severity:** LOW · **Cross-feed P3→P4** (rootcause SP4-001, NEW — the time axis an authority
census cannot see)
**Verification:** PoC ×2 + control. **Level 4.**

`fundNextTranche()` requires only `block.timestamp >= periodFinish` (verified verbatim). There
is no deadline, no expiry and no incentive. `FOUR_YEARS` is an *upper bound* on insider
vesting (paid by a permissionless `release()` nobody can stop) and only a *lower bound* on the
community emission.

**Control first (so the check has resolution):** at the earliest legal cadence, emission end
and vest deadline coincide **to the second** — proving they were designed equal. Then, with
each tranche opened 180 days late (which nothing forbids):
```
at launch + FOUR_YEARS: 3,714,285.71 GOV (37.1% of supply) fully delivered to insiders
                        1,021,428.57 GOV still sitting in the funder (the whole 4th tranche)
                        overrun: 31,104,000 s = 360 days
```
The identity `FOUR_YEARS == TRANCHE_COUNT * COIN_STAKING_REWARD_DURATION` appears **0 times**
in `src/`, `script/` or `test/`. **Fix Option A is the cheapest in the engagement**: one
compile-time comparison of three constants, no runtime behaviour, no new failure mode.

---

### NM-017 — `VESTED_TREASURY_WEIGHT` is a coupled constant that nothing reads; the residual absorbs any drift silently

**Severity:** LOW · **Cross-feed P1→P4** (factory FF-07 → allocation SP4-008)
**Verification:** mutation MUT-B. **Level 4.**

Restated by P4: it is not merely dead code. It is a coupled value with no reader, and because
the treasury allocation is computed as a *subtraction residual*, a divergence between the ABI
and the money **can never fail a test**. Demonstrated at a **300,000 GOV divergence with
55/55 green** — the ABI says 2,500,000 and the treasury receives 2,800,000.

---

### NM-018 — Two floor divisions in series; the composed dead-zone is 4× the notify-side one

**Severity:** LOW (escalating to HIGH if Coin has ≤ 8 decimals)
**Cross-feed P1→P2** (revenue FF-001 measured only the notify side → P2 revenue SI-003
measured the composition; SI-008 settlement-truncation drift)
**Verification:** Hybrid + fuzz. **Level 4.** Measured **0 ppm/yr at 18 decimals, 100 % at 6.**
Rounding is toward the treasury on every distribution. Graded LOW because the measured harm at
the documented decimals is dust — the calibration is deliberate and is preserved.

---

### NM-019 — Tokens that reach either reward contract outside the designed path are stranded or permanently sunk

**Severity:** LOW · **Discovery path: State-only** (P2 revenue SI-004/SI-005; P2 emissions
GAP-04/GAP-05)
**Verification:** PoC ×4 + invariant handler. **Level 4.**

Coin sent directly to `StakedGovToken` is permanently stranded while the *same* donation to
`RevenueRouter` is correctly swept (the router's full-balance read at L71 makes donations to
it distributable). GOV donated to `StakedGovToken` breaks the wrapper's exact backing and
cannot be re-synchronised. The same token donated to the two adjacent emission holders has
**opposite fates**, and one of them changes meaning with time.

---

### NM-020 — Registry and prediction defects: no reverse index, spent keys reserve addresses forever, and a spent key predicts a different launch's live addresses

**Severity:** LOW · **Cross-feed P1→P2** (factory FF-08 → registries SI-004…SI-007;
seams SI-007)
**Verification:** PoC + explicit negative greps + mutation M-S3. **Level 4 / Level 2.**

`deploymentKeyForId` is write-only and no reverse index exists, so **no contract can check any
of the four registry pairs**. `predictCoinDAOAddresses` ignores `usedDeploymentKeys`, so on a
spent key it returns **nine live addresses belonging to a different launch** (the tenth, the
Governor, depends on `govTokenName`, which the key does not bind). Mutation M-S3 shows
registry 2 has **one assertion in the entire project**, on id 0 of the `deploy()` path only.
`deployments[]` is push-only and describes a system that can move underneath it.

---

### NM-021 — Dead approval surface on a non-transferable token; `permit` burns the `delegateBySig` nonce

**Severity:** LOW · **Cross-feed P1→P4** (revenue FF-009 → P3 inherited F-07 → P4
permissionless P4-07)
**Verification:** PoC. **Level 4.**

`approve` returns true and stores an allowance that `transferFrom` can never spend — wallets
will display a meaningless spending cap. `permit` additionally consumes the shared nonce that
`delegateBySig` needs.

---

### NM-022 — A caller with no position can write a third party's reward state and force a protocol-wide distribution

**Severity:** LOW
**Source:** **Cross-feed P2→P3→P4, and the engagement's clearest correction chain** — P2
revenue SI-006 → P3 masking FP3-01 (overturned P2 emissions' MASK-04 clearance) → P4
permissionless P4-04/P4-05, and **P4-08 corrected FP3-01's own pricing**
**Verification:** PoC + two-system control. **Level 4.**

**The mechanism (upheld).** `getReward()` is `public` with no minimum and no access control.
Its modifier `updateReward(msg.sender)` writes `rewardPerTokenStored` and `lastUpdateTime`
*before* `if (reward > 0)` is evaluated (verified verbatim). So the only visible statement
about whether the call had an effect is evaluated **after** the call has already changed
global emission state. Deleting L132 changes nothing: a zero-value transfer and a
`RewardPaid(user, 0)` event. **The guard protects no invariant; it certifies rather than
verifies.** Pass 2 had cleared this line, and Pass 2's own PoC depended on the clearance being
wrong — the two statements could not both hold. The same shape holds on three more
`StakedGovToken` entry points, plus `depositFor(victim, 0)`, which settles a third party's
snapshot and discards their rounding remainder.

**The priced loss (REFUTED — and this correction must be carried).** FP3-01 reported
`890,410,958,903,808,000` wei of GOV destroyed by the call and argued *"any address can drive
it, deliberately, for the price of gas."* **P4-08 refuted the word *drive* by execution.**
`stake()` also carries `updateReward(msg.sender)` and runs it **before** `_totalSupply +=
amount`, so at modifier time the supply is still zero, the L95 early return still fires, and
the entire vacancy is skipped **whether or not anyone touched the contract during it.** Two
identical systems, one hammered with 24 hourly `getReward()` calls through the genesis vacancy
and one untouched:
```
A: 24 hammered hours, earned after 30d : 173,630,136,986,301,367,296,000
B: untouched vacancy,  earned after 30d : 173,630,136,986,301,367,296,000
```
**Byte-identical.** The outsider's calls realise the loss earlier; they do not add to it. The
GOV is lost to NM-003 regardless of who calls what.

**What the report must not say:** that an attacker can burn 0.89 GOV by calling `getReward()`.
Attributing it to the caller would be a false positive, and a false positive costs more than a
missed LOW. **What survives is the legibility finding**, and it is the important half: the bug
class is not "modifier before guard" — it is **"modifier before a guard the caller passes
trivially."** `stake(0)` and `withdraw(0)` run their modifier and then revert, so nothing
persists; `getReward()`, `depositFor(x,0)`, `harvestAndGetReward()` and `harvestAndWithdraw()`
run their modifier and then **succeed**, so everything persists.

---

### NM-023 — Voting weight survives the total exit of the underlying, and the snapshot block is published 7,200 blocks in advance

**Severity:** LOW · **Cross-feed P1→P4** (governance FF-012 → allocation SP4-007)
**Verification:** PoC + held-block control. **Level 4.**

Executed to the end of the chain: after the snapshot the launcher burns **all** stGOV and
transfers **all** GOV away, then votes, queues, and executes — seizing `RevenueRouter` while
holding **zero GOV, zero stGOV, with stGOV total supply at zero**. The capital requirement for
genesis capture is 500,000 GOV *held at two block heights*, not held through the governance
cycle. **Same-block rental is refuted** (VN-1) — a mint and a burn in one block overwrite the
same checkpoint.

---

### NM-024 — Deployment script and environment handling

**Severity:** LOW · **Cross-feed P1→P4** (governance FF-010, FF-013…FF-016 → rootcause SP4-003)
**Verification:** inspection + PoC + explicit negative greps. **Level 2–4.**

Eleven of twelve environment variables use `vm.envOr` and fall back **silently** on a typo
(only `STAKING_TOKEN` reverts): a mistyped `COLLATERAL_FACTOR` launches a market at 50 %
without a word in the log. `run()` requires a raw `PRIVATE_KEY` in the process environment and
derives the Lender's permanent `manager` from it, foreclosing keystore and hardware signers.
Both scripts are hard-gated to Sepolia; **there is no production deployment tooling in the
tree.** `IMonolith.sol` is a hand-transcribed ABI with no recorded source revision — arity
mismatches fail loudly, adjacent same-type field swaps do not. `_verifyDeployment` runs
*after* `vm.stopBroadcast()`, so its assertions bind the simulation, not the mined chain.

**The P4 addition:** the off-chain mitigation layer **replicates the on-chain blind spot
verbatim** — the deploy script's `deployerRecipient` guard is the *same predicate* with the
*same scope* as the factory's, so the only rejected configuration is again the one that costs
the deployer. The 2×2 was executed at both layers.

---

### NM-025 — Validation gaps: type-blind implementations, missing zero-checks on the attach path, block-count timings, and GOV stranded in the factory

**Severity:** LOW · **Discovery path: Feynman-only** (factory FF-06/FF-09/FF-12,
governance FF-007; P3 irreversibility FI-005 — both Feynman lenses)
**Verification:** inspection, code trace, explicit negative greps. **Level 2–3.**

`_validateImplementations` checks only "has code" and "distinct" — it cannot tell a Governor
implementation from a vesting wallet. `_preflightImplementations` in the script is a check
that **cannot fail**, and it is the only gate on an environment-supplied factory address.
`deployForExistingCoin` omits the zero-address checks `deploy` performs (2 of 3 cases
mitigated). Governance timings are block counts and are wrong on any chain that is not ~12 s.
GOV that lands in the factory is permanently gone, for every launch, forever.

---

## Feedback Loop Discoveries

**22 of 25 findings are cross-feed.** That figure needs an honest caveat rather than a
flourish: Passes 3 and 4 were *scoped from the previous pass's deltas by construction*, so a
Pass-3 or Pass-4 finding is cross-feed almost by definition. The number that actually
justifies the loop is smaller and sharper: **the ten discoveries below changed a finding's
severity, its mechanism, or its remedy** — meaning the single-lens version would have been
shipped wrong, not merely shipped thin.

| # | Discovery | Handoff | What the loop changed |
|---|---|---|---|
| **L-1** | Burn → **capture** on the attach path (seams SI-002) | P1(F)+P1(F) → **P2(S)** | Both Pass-1 lenses were *correct about their own contract* and their composition was wrong. The factory lens scoped its claim to `deploy()` ("supply is provably zero"); the emissions lens graded a **burn** on that same premise. On `deployForExistingCoin` the staking token pre-exists, so the premise is false and the burn becomes a **capture**. Neither lens could reach it alone; the state lens at the *seam* could. |
| **L-2** | The 5 % is **free**, not bought (FP3-001) | P1(F)+P2(S) → **P3(F)** | Pass 3 asked Q4.3 *of Pass 1's finding rather than of the code*: FF-01's "0.1 % of supply" is an **acquisition cost**. Combined with registries SI-009 (recipient unvalidated), the launcher is *handed* 5 %. Cost basis replaced 10,000 → 500,000 stGOV; every quorum remedy must now be priced against the larger number. |
| **L-3** | The quorum pair is **fused**, and no fix at that link can work (SP4-003/-004/-005) | P3(F) → **P4(S)** | Measured d(votes)/d(quorum) = 1000. Then the two obvious remedies were built and executed: no numerator works (even 999), and no absolute floor works (below → cleared; above → **permanent unrepairable deadlock**). The loop turned "raise quorum" from a recommendation into a **retired** one. |
| **L-4** | SI-001's irreversibility is **conditional** (F-05) | P2(S) → **P3(F)** | Pass 2 wrote "It is irreversible. Every repair path runs through the timelock that just became unreachable." Pass 3 found `Governor.relay` — zero occurrences anywhere in the repo — and recovered every orphan in one proposal, with a control proving the deciding bit. A delivered finding's central claim was corrected before it reached the client. |
| **L-5** | …and SI-001's **remedy is unwritable** (FI-001) | P2(S) → **P3(F)** | The same handoff, opposite direction: `RevenueRouter.treasury` is write-once with no setter at any privilege level, so the "documented batched migration" Pass 2 recommended **does not exist to document**. A remedy failing is a finding about the remedy. |
| **L-6** | `renounceOwnership()` **exonerated**; one decision → three defects (FP3-04) | P2(S) → **P3(F)** | Two independent lanes attributed the irreversibility to `CoinDAOFactory.sol:488`. Neither checked whether the factory could have acted as owner. It could not — the state was already terminal. Mutation then identified the *actual* necessary line (`StakingRewardsFunder.sol:70`) and priced its removal's created failure mode. |
| **L-7** | MASK-04 overturned, then **re-priced** (FP3-01 → P4-08) | P2(S) → P3(F) → **P4(S)** | The loop cutting both ways in three moves: Pass 2 cleared a guard; Pass 3 overturned the clearance by execution; Pass 4 upheld the mechanism and **refuted the priced loss** with a two-system byte-equality control. Default-REFUTED posture applied to a refutation. |
| **L-8** | The **time** axis an authority census cannot see (SP4-001) | P3(F) → **P4(S)** | Pass 3's census was built out of *authority* (who can undo what). Pass 4 re-ran the same root cause on the *time* axis and found two four-year clocks — one an enforced insider deadline, one an unenforced community floor, with the binding identity written nowhere. |
| **L-9** | The permissionless lever **destroys** rather than redistributes (FP3-005) | P1(F)+P2(S) → **P3(F)** | Both revenue lanes had the lever as a redistribution. Pass 3 measured the large-supply regime and found the sign flips: 180,000,000 wei stranded with an index delta of 0. |
| **L-10** | The established external fact **closed two HIGH leads** (seams §7) | P1(F) → **P2(S)** | `pullLocalReserves()`'s complete-drain behaviour closed FF-004's zero-reserve half and **refuted FF-005 entirely** (anti-JIT holds: whale earns 0, honest staker earns the full 100e18). Two HIGHs removed from the report. **A closed lead is a deliverable.** |

**The single strongest piece of evidence in the engagement is convergence, not a finding.**
Pass 1 (emissions) reached `StakingRewards.sol:69-70` and `:95` by asking whether a guard was
*sufficient for what it is trying to prevent*. Pass 2 reached the identical two lines by
building a Mutation Matrix and finding a lone write to one half of a coupled pair. Two
methodologies, two routes, same two lines — and Pass 2 built its map from the declarations
*before* reading Pass 1's verdicts. The same convergence occurred four separate times on the
`ReentrancyGuard`-in-a-clone hypothesis, and three times on the empty-pool inflation
hypothesis. **Blind discovery is what made that evidence, and priming would have destroyed it.**

**The sharpest single result is a *present* guard, not a missing one.**
`RevenueRouter.sol:72` — *do not price a distribution against a supply that does not exist* —
is exactly the coupling Pass 2 proved missing from `rewardRate` × `_totalSupply`. It is
written correctly, by the same authors, in the same deployment. It is applied to the reward
path that loses nothing when it is absent, and omitted from the one that loses 6,500,000 GOV
worth of emissions. The comment at `StakingRewards.sol:145-149` should be read in that light:
**the hazard was not unrecognised — it was recognised and guarded, in the other contract.**

---

## Killed Fixes

**A remedy that fails is a finding about the remedy.** Each of the following was applied as a
source mutation to a disposable tree, confirmed to *take effect* by its own control, and then
measured against the attack it was supposed to prevent.

| # | Proposed fix | Origin | Control (did it bite?) | Result | Cost |
|---|---|---|---|---|---|
| **KF-1** | Drop `fundNextTranche()` at `CoinDAOFactory.sol:487` | factory FF-02 | `test_MUT_A_launchNoLongerOpensTheTranche` — **yes** | **KILLED.** With both KF-1 and KF-2 applied simultaneously, `test_MUT_bothFixesApplied_…` shows the launcher **still captures tranche one atomically — identical to the wei.** It also hands the same advantage to whoever calls the deferred `fundNextTranche()` first, measured at 5,787 GOV/day for a 1-wei staker | 4 of 55 client tests fail |
| **KF-2** | Minimum-TVL gate on `fundNextTranche` | emissions FF-001/FF-003, seams SI-002 | `test_MUT_B_gateBlocksAnEmptyPool` — **yes** | **KILLED** (same combined run). Independently, P4-01 priced its *created* mode: `fundNextTranche` is serialised on `periodFinish`, so an empty pool blocks the **entire remaining schedule** and the four-year plan stalls indefinitely — strictly worse than the burn it fixes. This is the constraint `StakingRewards.sol:149` warns about, and it is why the authors did not add the check | (as above) |
| **KF-3** | `_validate`: reject `deployerRecipient != 0` when `deployerStakeBps == 0` | **FP3-001 Option A** | `test_MUT_A_control_zeroStakeNamedRecipientIsNowRejected` — **yes** | **KILLED.** `test_MUT_A_oneBasisPointRestoresTheEntireCapture`: `bps = 1` restores the entire capture for **51.020408163265306123 GOV**. Worse, the forced vesting wallet **has no cliff** — 0.6849 GOV releasable after one day | 1 client test fails |
| **KF-4** | Absolute quorum floor (`FlooredQuorumGovernor`) | FF-01 / SI-003 Option B | `assertGt(quorum, 0)` resolution guard on every read — **yes** | **KILLED, in both directions.** Floor 400,000 → the sole staker clears it. Floor 1,000,000 → the DAO is **Defeated at genesis and still Defeated after the full four-year vest** — a permanent, unrepairable deadlock | — |
| **KF-5** | Raise the quorum numerator | implied by FF-01 | 7-value parametric sweep with a resolution control | **KILLED.** `test_SP4_005_control_…`: even **n = 999** is met by the sole staker at genesis | — |
| **KF-6** | Restore Synthetix's `recoverERC20` | implied by emissions FF-001 / assumption A6 | `testM2_RecoverIsDeadCodeWithoutAnOwner` — the restored function reverts `OwnableUnauthorizedAccount` | **KILLED, twice.** (1) It is dead code without an owner, so the real remedy is *"keep an owner"*. (2) With an owner: `recoverERC20(rewardsToken, balance)` **seizes 32.5 GOV of already-earned, unclaimed rewards** and alice's `getReward()` then reverts. **The mask moves from "the loss is invisible" to "the loss is discretionary."** Pass 1 priced only the mode the fix prevents | material change in trust assumptions for a credibly-neutral emission |
| **KF-7** | Delete `StakingRewardsFunder.sol:70`'s `AllTranchesFunded` gate | implied by GAP-06 | `testM1_DeletingTheTrancheGateMakesDonationsClaimable` — the sink becomes a top-up conduit | **NOT FREE.** It works, but `testM1_CreatedFailureMode_OneWeiGriefLocksAPeriod`: **1 wei donated → `rewardRate == 0` → a genuine 1,000 GOV top-up is blocked for 31,536,000 s.** The same `x != 0`-instead-of-`x >= min` pattern the fix was meant to remove | 1 client test fails, on the error selector only |

**Fixes that SURVIVED mutation — stated explicitly, with what was measured:**

| Fix | Mutation | Measured |
|---|---|---|
| **Add `RevenueRouter.setTreasury`** (closes NM-004) | irreversibility **M1** | **55/55 project tests still pass** and the finding closes. No new failure mode found |
| **`if (lender.operator() != revenueRouter) revert` after `CoinDAOFactory.sol:453`** (closes NM-010) | registries **M-S2** | **19/19 project tests pass**; `test_GAP1b_…` flips to revert. Compatible with every intended flow and catches the case it is for |
| **Cap or vest the liquid-to-private allocation** (FP3-001 Option B / the absolute cap) | not defeated by any Pass-4 experiment | **The only surviving candidate** against NM-002. Gated on client question Q-5 (is the 5 % deployer compensation or DAO treasury?) — a product decision, not an audit one |
| **Emit the recipient and the amounts** (SP4-009 / FP3-001 Option C) | — | Prevents nothing; it is the **precondition for anything**. Ship unconditionally |
| **Assert `FOUR_YEARS == TRANCHE_COUNT * COIN_STAKING_REWARD_DURATION`** (SP4-001 Option A) | — | One comparison of three compile-time constants. **The cheapest fix in the engagement**: no runtime behaviour, no new failure mode |
| **Override `renounceOwnership` on the vesting wallets and the router** | — | One-sided and identical in both places; shipping them together is cheaper than either alone |

---

## Verified Negatives

Proved SOUND with controls that could have failed. These belong in the report: several of them
are the parts of this system that are well built, and two of them close HIGH leads.

| ID | Property proved sound | Evidence and resolution |
|---|---|---|
| **VN-1** | **The per-account reward accumulator is structurally complete.** Every one of the four balance-changing paths settles the account it touches; no writer was missed | 9 invariants × **20,480 adversarial handler calls**, 0 failures. **Resolution proved in both directions by two source mutations**: deleting `updateReward` from `withdrawTo` fails `invariant_strandedIsBounded`; swapping `harvestYield`/`updateReward` on `depositFor` fails three invariants. The strongest positive result in the engagement |
| **VN-2** | **The anti-JIT defence holds, including on the attach path where the accrued reserve is largest** | With 100 COIN accrued and a 300,000-stGOV whale depositing after a 1,000-stGOV honest staker: `earned(whale) == 0`, `earned(alice) == 100e18`. **Closes P1 revenue FF-005 (was HIGH)** |
| **VN-3** | **The mint path is not bricked by zero reserves** | A launch with no accrued revenue admits deposits normally. **Closes half of P1 revenue FF-004 (was HIGH)** |
| **VN-4** | **The five-allocation arithmetic is exact.** All 2001 legal bps values sum to exactly 10,000,000e18; the factory retains **0** | L4 across 3 real launches + exhaustive sweep. Survives the FP3-001 branch too |
| **VN-5** | **The launch transaction is atomic and its irreversible ordering fails safe** | Zero `try`/`catch` in `src/`. Mutation M2 (reorder Phase 3) makes **12 project tests fail** — the grant-before-renounce order cannot be got wrong silently |
| **VN-6** | **`StakingRewards` is solvent on every reachable path** | All four tranches funded, `rewardRate * duration <= balance` asserted after **every** notify; funder fully drained; 71,840,000 wei (7.2e-11 GOV) of truncation dust. Answers the factory lens's open question #3 |
| **VN-7** | **The reentrancy guards on the three EIP-1167 clones are effective despite the un-run constructor** | Executed on real clones (a hook token re-enters and reverts `ReentrancyGuardReentrantCall`). Refuted **four independent times** by four blind lanes. **OZ 5.6.1's guard uses an ERC-7201 namespaced slot** — Pass 1's conclusion was right and its stated reason was the symptom, not the cause. Version-dependent: a downgrade below the namespacing change reintroduces it |
| **VN-8** | **The four factory registries cannot drift**, including under a reentrant nested launch | L4 across all three entry paths + trace. But see the caveat: mutation **M-S1** shows the *only* thing preventing a duplicated launch by a malicious lender is the L359 write order, and **19/19 project tests pass with that ordering broken** |
| **VN-9** | **No implementation or clone can be re-initialized**, and the Governor cannot receive ETH or NFTs | `_disableInitializers()` in all six implementation constructors, read individually; `GovernorDisabledDeposit` executed at L4 |
| **VN-10** | **Same-block vote rental confers nothing** | A mint and a burn in the same block overwrite the same checkpoint: `getPastVotes(borrowBlock) == 0`. **Control included** — the same amount held across a block boundary checkpoints at the full 500,000 |
| **VN-11** | **`depositFor`'s harvest-before-mint ordering is correct and load-bearing** | With 50 coin pending, a new depositor's `earned == 0` while the incumbent's is the full 50 ether. The modifier order is deliberate and the repo's own test asserts it |
| **VN-12** | **`stake`/`withdraw` on `StakingRewards` are a genuinely symmetric pair**, and the accumulator's monotonicity is the right shape, not a defect | Census found no asymmetry; the monotone accumulator is what makes the L141 subtraction underflow-free |

---

## False Positives Eliminated

Roughly **90 hypotheses were pursued to a conclusion and killed** across the fifteen pass
files; deduplicated, about **60 are distinct**. The ones that matter for the report:

**Killed because the mechanism does not exist:**
- *Predicted clone/CREATE2 addresses can be front-run and occupied.* Both `cloneDeterministic`
  and `new{salt:}` fix the deployer to the factory. Verified by execution — prediction equals
  deployment. (Re-confirmed independently in three passes.)
- *Deployment keys can be stolen, squatted, or burned for a third party.* `deploymentKey`
  always binds `msg.sender`; `deployForExistingCoin` requires `msg.sender == lender.operator()`.
- *A clone can be initialised by an attacker before the factory does.* Every clone is
  initialised in the same call frame it is created in, with no untrusted callee between. All
  six sites checked.
- *`_balances` is mutated by some path that skips `updateReward`.* Grep-refuted: exactly two
  write sites, both behind the modifier. **There is no odd path out because there is no third
  path.**
- *`Governor.cancel` can reach `TimelockController.cancel` for a queued proposal.* The two
  preconditions are mutually exclusive — which is *why* NM-006 exists.

**Killed on magnitude or cost (the derivation, not the intuition, is what closes these):**
- *An attacker can overflow `rewardPerTokenStored` and permanently brick the system.* The
  cumulative Coin required is `2^256 ≈ 1.16e77` wei — **independent of the victim's balance**.
  ~1.16e51 flash-loan cycles. Economically unreachable by any margin.
- *Repeated free `updateReward` calls grief accrual through truncation.* 240 forced settles
  against a 1e24 supply cost **0 ppb** of the interval's emission.
- *An unprivileged actor can permanently raise the quorum floor via `depositFor(dead, x)`.*
  Blocking `V` delegated votes needs `> 999·V` locked GOV the attacker can never withdraw —
  ~9,990,000 GOV at genesis. Refuted on cost, not on mechanism.
- *A no-standing caller can poison `lastUpdateTime` past `lastTimeRewardApplicable()` and make
  every entry point revert.* 40 adversarial calls at 11-day strides; `periodFinish` is monotone
  and the subtraction can never invert.
- *Donating reward tokens can block a tranche by breaking the balance check.* A 5,000,000 GOV
  donation only **relaxes** the check. An outsider can raise `balance` and cannot lower it.

**Killed because the code is right (skill FP patterns 1, 2, 4):**
- *`notifyRewardAmount` L162 writes `lastUpdateTime` without `rewardPerTokenStored`.* Benign in
  both branches — the discarded interval is either beyond the old period or empty.
- *`updateReward(address(0))` on notify leaves accounts unsettled.* Lazy evaluation by design;
  `userRewardPerTokenPaid` is only ever compared against a monotone accumulator.
- *A returning first staker retroactively captures the empty interval* (classic empty-pool
  inflation). L70 runs before `stake`'s body, so the vacancy is **skipped, not banked** — which
  is precisely why NM-003 is a burn and not an inflation. Refuted independently in two passes.
- *`GovToken`'s unused `ERC20Votes` surface is an oversight.* It is engaged **in a comment**
  (`novel_code.md:71-73`) which states the decoy explicitly and gives the reason. **Per the
  workspace rule, a finding must engage with the comment; this one does not survive it.**

**Killed by the corpus — recorded because they were a later pass's intended headline:**
- *The empty-pool guard is on the revenue path and absent from the emissions path.* Already
  owned in full by FP3-02, including the identical comparison table. **Convergent, not new.**
- *The predicted Governor address is not key-determined while the other nine are.* Already
  owned by registries SI-007, which states the 9-vs-1 split exactly.

**Two raised-then-withdrawn within a single pass** (revenue P1 FF-006 and FF-016), both
refuted by that pass's own execution before write-up.

---

## Downgraded Findings

Every re-grade below was made by the pass that owned the finding or by a later pass with
executed evidence. **None was graded to fit a result.**

| Finding | From → To | Justification |
|---|---|---|
| NM-001 (governance FF-001) | CRITICAL → **HIGH** | Success still requires that no larger opposing stake shows up to vote — a real if weak condition |
| governance FF-002 | HIGH → **MEDIUM** | The destination is intended; the defect is a missing guard, not a misdirection |
| NM-013 (revenue FF-004) | HIGH → **MEDIUM (lead)** | The zero-reserve half is **CLOSED** by the established `pullLocalReserves()` fact; the residual is unevidenced |
| revenue **FF-005** | HIGH → **CLOSED / not a finding** | **REFUTED** by the same fact: a complete drain is exactly what the anti-JIT defence needs. Executed: whale earns 0, honest staker earns the full amount |
| NM-018 (revenue FF-001) | HIGH → **LOW** | Measured **0 ppm/yr at 18 decimals**. Escalates to HIGH only at ≤ 8 decimals — stated as the condition |
| NM-012 (revenue FF-003) | HIGH → **MEDIUM** | Redistribution among stakers, not extraction from the system |
| revenue FF-007 (re-entrant `distribute`) | MEDIUM → **LOW** | Requires a callback token, which the interface documents as unsupported in three places |
| revenue FF-008 (`rewardsToken == underlying`) | HIGH → **LOW** | Unreachable via the factory |
| revenue FF-018 | MEDIUM → **INFO** | Documented as unsupported — but the failure mode should be restated as **DoS, not shortfall** |
| P2 emissions GAP-05 | MEDIUM → **LOW** | Unreachable in-path |
| P2 emissions GAP-06 | HIGH → **MEDIUM** | The *loss* is conditional on someone sending GOV after exhaustion; the *irreversibility* is unconditional |
| P2 revenue SI-003 / SI-004 / SI-005 / SI-006 | MEDIUM → **LOW** | Measured harm is dust or requires an out-of-band donation |
| NM-022 (FP3-01) | **priced loss REFUTED, mechanism upheld** | P4-08's two-system control: the vacancy loss is byte-identical whether or not anyone touches the contract. The finding is re-stated as **legibility**, not loss |
| P2 emissions **MASK-04** | cleared → **CLEARANCE OVERTURNED** | FP3-01, by execution. The only prior-pass verdict overturned in this direction |
| NM-014 attribution | **`renounceOwnership()` EXONERATED** | Two lanes attributed terminality to `CoinDAOFactory.sol:488`; ABI inspection shows no factory function could ever have acted as owner. **The state was already terminal.** Both write-ups corrected |
| NM-004 (seams SI-001) | irreversible → **CONDITIONAL** | `Governor.relay` recovers every orphan when the destination timelock granted the Governor `PROPOSER_ROLE`. Control proves the deciding bit |
| NM-015 (governance FF-011) | LOW → **MEDIUM** | **Raised**, on P4's evidence: the delegated against-vote is the only working brake in the chain, and the revenue incentive recruits non-delegators |
| FP3-02, FP3-03 | NEW → **CONVERGENT re-derivations** | Demoted **by their own author** after enumerating `.audit/findings/` and finding the revenue and governance lanes already owned the core mechanisms. Nothing withdrawn; only the cross-lane joins are carried |
| K-1, K-2 (P4 rootcause) | intended headline → **NOT NEW** | Demoted **by their own author**: already owned in full by FP3-02 and SI-007 respectively |
| P2 revenue SI-011 | HIGH → **attributed elsewhere** | Mapped, not re-claimed; belongs to the governance lane |
| factory FF-11 | LOW → **placement note, no exploit found** | Stated as a placement rather than a vulnerability |

**Two process corrections recorded by the authors themselves**, kept here because they are the
failure mode `CLAUDE.md` names:
1. The masking pass made an **absence claim without grepping for the negative** ("neither prior
   pass read a line of `StakedGovToken`/`RevenueRouter`") and widened its scope on that basis.
   The directory was enumerated only after the census was complete. Cost: duplicated effort.
   Bought: genuinely blind convergence on three lines of independent work.
2. The rootcause pass grepped `test/` for role constants, got zero hits, and began writing *"the
   launch's role wiring is asserted by no test at all."* A mutation failed a test and disproved
   it — the one assertion that exists is written `hasRole(bytes32(0), …)`. **The absence claim
   was wrong and the execution caught it.**

---

## Open Questions for the Client

Each gates a severity, not a fix. None is answerable from this repository.

| # | Question | Gates |
|---|---|---|
| Q-1 | Can the party who calls `MonolithFactory.deploy` obtain any non-zero balance of the resulting Coin or sCoin **within the same block**? | NM-003's atomic-capture variant on the `deploy()` path (Level 2 link) |
| Q-2 | Does `MonolithFactory.deploy` mint any initial supply of the returned vault (sCoin)? | a second, independent route to the same capture |
| Q-3 | What can the Lender's `manager` do — change rates, pause, seize, alter the reserve split? | NM-010's severity (the attach path inherits it unexamined) |
| Q-4 | What is the realistic per-block local-reserve accrual for a target market? | NM-011 — below ~`stGOV_supply / 1e18` Coin wei per harvest, revenue is **destroyed** |
| Q-5 | Is the 5 % immediate allocation the deployer's compensation or the DAO's liquid treasury? `CoinDAOFactory.sol:281-282` says one thing and `:490` does the other | NM-002's only surviving remedy |
| Q-6 | Can the real Monolith lender re-nominate an operator out of band, and does anything in `setPendingOperator`'s call graph make an external call? | NM-010 (whether `acceptLenderOperator` is a live recovery path or dead code) |
| Q-7 | Is the four-year emission a public commitment or an internal target? | NM-016's framing (a disclosure question as well as a code one) |

---

## Summary

- **Functions analysed:** ~140 declared entry points and internals, plus the complete non-view
  ABI of all nine deployed contracts.
- **Coupled state pairs mapped:** 54 (Pass 2) + 8 chain links + 24 frozen↔mutable pairs (Pass 4).
- **Mutation paths traced:** 107.
- **Nemesis loop iterations:** 4 passes (Feynman → State → Feynman → State) across 15 blind
  agent runs. Pass 4's delta was 11 findings, all LOW/MEDIUM, with no new HIGH and no new root
  cause.
- **Raw findings (pre-consolidation):** 147 distinct pass-level IDs across the fifteen files.
- **Feedback loop discoveries:** **22 of 25 findings are cross-feed**, of which **10 are
  loop-critical** — the loop changed their severity, mechanism, or remedy, so the single-lens
  version would have shipped wrong.
- **After verification and merge: 25 TRUE POSITIVE · ~60 distinct hypotheses refuted ·
  22 findings downgraded, re-scoped, or corrected · 2 delivered claims overturned ·
  1 attribution exonerated.**
- **Fixes killed by execution: 7** (6 outright, 1 that works but creates a worse failure mode).
  **Fixes that survived mutation: 6**, two of them with the project suite measured green.
- **Verification levels reached:** Level 4 (executed in a real EVM) for every CRITICAL/HIGH/
  MEDIUM finding except NM-010 and NM-013, whose triggers are external and which are stated as
  conditional. Level 2–3 with explicit negative greps for the LOW inspection findings
  (NM-024, NM-025) and for all absence claims. **31 source mutations**; every headline claim
  carries a control or a resolution measurement, so no green check is cited without knowing
  what it could have caught.
- **Final: 0 CRITICAL · 3 HIGH · 12 MEDIUM · 10 LOW.**

**Evidence integrity.** The audited tree at `[scratch]` was never modified. Every pass
re-verified `git diff --stat -- [scratch]` empty and the 55/55 baseline green before and after
its experiments. All PoCs and mutations ran on disposable copies under the session scratchpad.
Nothing was executed against any external system, and no protocol system was written to.

**The single most important sentence in this audit.** The DAO's bootstrap runs entirely
through two channels — the launch-time allocation and the emission program — and the same
party controls both from block zero, on both entry paths, for free, with the launch record
unable to show that it happened. **Every HIGH in this report is one of the three faces of that
one fact**, and the two obvious remedies for it were built, executed, and killed.
