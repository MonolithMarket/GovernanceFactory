# NEMESIS Pass 4 — State Inconsistency Auditor: TARGETED re-analysis of the permissionless class

**Methodology:** `.claude/skills/state-inconsistency-auditor/SKILL.md`. Phases 1–3 and 8 run in
full but **narrowed to one class**; Phase 4 (operation ordering) is the load-bearing phase this
pass, applied to *modifier* ordering rather than statement ordering; Phase 5 (parallel paths)
applied to the harvest/harvest-free twin pairs; Phase 7 (masking) inherited from Pass 3 rather
than re-derived.

**The class, as handed over.** FP3-01 established that `StakingRewards.getReward()` reads as
inert to a caller with no stake — `if (reward > 0)` guards every visible statement — while
`updateReward(msg.sender)` has already written two global storage slots before the guard is
evaluated. **The generalisation this pass was set to test: an address with no standing, no
stake and nothing to claim can advance, consume or freeze shared state, by calling a function
that appears to do nothing.**

**Scope.** `[scratch]` — all eight contracts plus `interfaces/`, read for
permissionless reachability. Deep line-by-line re-reading confined to `StakedGovToken.sol`,
`RevenueRouter.sol`, `StakingRewardsFunder.sol`, `StakingRewards.sol`.
**Not read:** `[scratch]`, `engagements/`. OZ 5.x base implementations
(`VotesUpgradeable`, `ERC20WrapperUpgradeable`) were traced **from the disposable copy**, not
from `[scratch]`, solely to discharge Phase 3 step 3 (*"trace internal calls for
hidden updates"*) — the same procedure the Pass 2 revenue lane used.

**Baselines extended, not re-audited:** `state-pass2-emissions.md`, `state-pass2-revenue.md`,
`feynman-pass3-masking.md`. Anything Pass 2 cleared is left cleared except where this pass
executed a contrary measurement, which happened once (see **P4-08**).

**Language:** Solidity 0.8.26, EIP-1167 clones, Foundry, via-ir, optimizer 200, OZ 5.6.1.

---

## EXECUTION — level 4 for every finding below

| tree | contents | suite |
|---|---|---|
| `%TEMP%/…/[scratch]` | unmodified `src/` + 25 audit tests in `test/audit/StatePass4.t.sol` (16) and `test/audit/StatePass4b.t.sol` (9) | **80/80** (55 project + 25 audit) |

**Evidence integrity.** `[scratch]` was **not written to**:
`git diff --stat -- [scratch]` and `git status --porcelain -- [scratch]` are both
empty, and `diff -r [scratch] <copy>/src` is empty. No source mutation was needed this
pass. Nothing was executed against any external system.

> ⚠ **Harness traps — all three from the brief were handled; a fourth fired and is recorded.**
> Every timestamp is read with `vm.getBlockTimestamp()` and every roll is
> `vm.roll(vm.getBlockNumber() + 1)`; no `vm.expectRevert` sits in front of an argument-list
> staticcall. **The new one:** the first pass at `testP4_02b` measured `quorum()` gas *cold*
> on the shallow side and *warm* on the deep side, and reported 11,210 gas at depth 2 against
> 6,744 gas at depth 201 — i.e. it appeared to show that a **deeper** checkpoint array is
> **cheaper** to read. That is a storage-warming artefact, not a property of the contract.
> `testP4_08d` re-measures with both sides warmed (4,710 → 6,999). **A green check has a
> resolution; this one had the wrong sign until the measurement was corrected.**

---

## PHASE 1 — THE PERMISSIONLESS REACHABILITY CENSUS

*Assignment item 1: every externally-callable function reachable by an address with no stake,
no balance, no role and no approval. `mallory` in every PoC is asserted to hold zero GOV, zero
stGOV, zero Coin, zero SR stake, zero allowance, zero `rewards[]` before acting
(`_assertNoStanding`).*

Surfaces enumerated from the **build artifact** (`forge inspect <C> methods`), not from source,
so nothing inherited is missed.

| contract | mutating external | reachable with **nothing**? | outcome |
|---|---|---|---|
| **StakedGovToken** | `depositFor(a,v)` | ✓ **with `v == 0`** | **succeeds** — forces `distribute()` |
| | `harvestAndGetReward()` | ✓ | **succeeds** — forces `distribute()` |
| | `harvestAndWithdraw()` | ✓ | **succeeds** — forces `distribute()` |
| | `withdraw()` / `withdrawTo(a,0)` | ✓ | succeeds, **no** harvest (control) |
| | `getReward()` | ✓ | succeeds, **no** harvest (control) |
| | `delegate`, `approve`, `permit`, `delegateBySig` | ✓ | see **P4-07** |
| | `transfer` / `transferFrom` | ✓ | reverts `NonTransferable` |
| | `notifyRewardAmount` | ✗ | `onlyRevenueRouter` |
| | `initialize` | ✗ | consumed atomically by the factory |
| **RevenueRouter** | `distribute()` | ✓ | **succeeds — no access control at all** |
| | `acceptLenderOperator`, `setGovStakingBps`, `setManager`, `transferOwnership`, `renounceOwnership` | ✗ | `onlyOwner` (timelock) |
| **StakingRewardsFunder** | `fundNextTranche()` | ✓ | **succeeds — the file contains zero occurrences of `msg.sender` and zero access modifiers** |
| | `initialize` | ✗ | consumed |
| **StakingRewards** | `getReward()` | ✓ | **succeeds** — FP3-01 |
| | `stake(0)` / `withdraw(0)` | ✓ | **revert** — modifier rolled back (control) |
| | `exit()` | ✓ | reverts via `withdraw(0)` |
| | `notifyRewardAmount` | ✗ | `onlyRewardsDistribution` |
| | `setRewardsDistribution` / ownership | ✗ | `onlyOwner`, and there is no owner |
| **CoinDAOVestingWallet** | `release()`, `release(token)` | ✓ | succeeds — pays only the beneficiary (**refuted**, R3) |
| **CoinDAOFactory** | `deploy(...)` | ✓ | succeeds — new market, no shared state consumed (below) |
| | `deployForExistingCoin(...)` | ✗ | requires `msg.sender == lender.operator()` **and** `lender.pendingOperator() == factory` |
| | `setPendingMonolithBeneficiary` / `acceptMonolithBeneficiary` | ✗ | beneficiary-gated |
| **CoinDAOGovernor** | `propose` | ✗ | 10,000 stGOV threshold |
| | `castVote*`, `queue`, `execute` | ✓ | standard OZ; `hasVoted[self]` only |

**Absence claims, grepped explicitly** (the dangerous kind):
`grep -n "harvestYield" src/*.sol` → the modifier is declared at `StakedGovToken.sol:81` and
applied at exactly **three** sites (L106, L130, L153). `grep -rn "distribute()" src/` → one
definition, one internal caller. `grep -n "onlyOwner\|msg.sender" src/StakingRewardsFunder.sol`
→ **no matches**. `forge inspect StakingRewardsFunder methods` → the only mutating externals
are `fundNextTranche()` and the consumed `initialize`.

**`CoinDAOFactory.deploy()` is permissionless but consumes nothing an attacker can deny to
others:** `usedDeploymentKeys[key]` is keyed on `keccak256(creator, userSalt)` (L193), so a
caller can only burn their own keys; `hasCoinDAO[lender]` is reachable only through
`deployForExistingCoin`, which is operator-gated; and the clones are `CREATE2`-d **from the
factory's own address**, so a predicted address cannot be squatted. The one substantive note is
that this contract imposes no gate whatever on *who* may launch a CoinDAO — that gate, if it
exists, lives in `monolithFactory.deploy`, which is outside this scope. Recorded as a lead, not
a finding.

---

## PHASE 4 — MODIFIER ORDERING IN THE STAKED-WRAPPER CONTRACT

*The brief's specific pointer. Modifiers run in declaration order, all before the body.*

| entry point | order of effects | first mutation of shared state | first guard that could reject the caller |
|---|---|---|---|
| `depositFor(a,v)` L102 | `nonReentrant` → **`harvestYield`** → `updateReward(a)` → `super.depositFor` | `revenueRouter.distribute()` — external pull + Coin transfers + `rewardPerTokenStored +=` | `safeTransferFrom(msg.sender,…,v)` in the **body** — and it **passes for `v == 0`** |
| `harvestAndWithdraw()` L130 | `nonReentrant` → **`harvestYield`** → `updateReward(sender)` → `_burn(sender, balanceOf(sender))` | same | none — `_burn(x, 0)` and `safeTransfer(…, 0)` both succeed |
| `harvestAndGetReward()` L153 | `nonReentrant` → **`harvestYield`** → `updateReward(sender)` → `_payReward` | same | `if (reward > 0)` at L159 — **the FP3-01 shape exactly** |
| `withdrawTo(a,v)` L113 | `nonReentrant` → `updateReward(sender)` → `_burn` | `rewards[sender]`, `userRewardPerTokenPaid[sender]` | none |
| `getReward()` L147 | `nonReentrant` → `updateReward(sender)` → `_payReward` | same | `if (reward > 0)` L159 |

**The answer to the pointer.** The harvest modifier does run before the settlement modifier,
and the ordering *between the two modifiers is correct* — `distribute()` credits the existing
supply, then `updateReward` settles the account at the new accumulator, then the mint or burn
happens. Pass 3's P3-R2/P3-R3 already established that and this pass re-confirms it
(`testP4_01_…` shows the supply is unchanged; the ordering is not the defect).

**The defect is that both modifiers run before anything checks that the caller has standing —
and on all three functions, nothing ever does.** `depositFor`'s only implicit standing check is
the `safeTransferFrom` in the body, and OZ's `_spendAllowance` short-circuits on
`value == 0`, so a zero-value deposit from an address with zero balance and zero allowance is a
**successful transaction**. `_mint(account, 0)` then succeeds too.

---

## SHARED-STATE INVENTORY — what the class can reach

*Assignment item 3. Time accumulators, snapshot pointers, period boundaries, nonces, one-way
flags, "we already did this" records.*

| # | state | kind | permissionlessly writable? | by |
|---|---|---|---|---|
| 1 | `StakingRewards.lastUpdateTime` | time accumulator | ✓ | `getReward()` — FP3-01, **re-priced at P4-08** |
| 2 | `StakingRewards.rewardPerTokenStored` | accumulator | ✓ | `getReward()` |
| 3 | `StakingRewards.periodFinish` | **period boundary** | ✓ **indirectly** | `fundNextTranche()` → **P4-01** |
| 4 | `StakingRewards.rewardRate` | rate | ✓ **indirectly** | `fundNextTranche()` → **P4-01** |
| 5 | `StakingRewardsFunder.nextTranche` | **one-way counter / absorbing flag** | ✓ | `fundNextTranche()` → **P4-01 / P4-02** |
| 6 | `StakedGovToken.rewardPerTokenStored` | accumulator | ✓ | three harvest paths + `distribute()` → **P4-04** |
| 7 | `StakedGovToken.userRewardPerTokenPaid[x]` | **per-account snapshot pointer, writable for ANY x** | ✓ | `depositFor(x, 0)` → **P4-05** |
| 8 | `StakedGovToken.rewards[x]` | per-account accrual, writable for ANY x | ✓ | `depositFor(x, 0)` → **P4-05** |
| 9 | `Votes._totalCheckpoints` | **append-only snapshot array** | ✓ | `depositFor(x, 0)` → **P4-06** |
| 10 | `Votes._delegateCheckpoints[x]` | append-only snapshot array | ✗ | guarded `amount > 0` — **the asymmetry** |
| 11 | `Nonces._nonces[owner]` | nonce, shared by `permit` **and** `delegateBySig` | signature-gated | **P4-07** |
| 12 | Lender local reserves (external) | drained balance | ✓ | any harvest path — out of scope, lead only |
| 13 | `RevenueRouter.govStakingBps` **applied ratio** | policy applied to accrued revenue | ✓ **by timing** | `distribute()` → **P4-03** |
| 14 | `VestingWallet._erc20Released[token]` | one-way released counter | ✓ | pays beneficiary only — **refuted, R3** |
| 15 | `CoinDAOFactory.usedDeploymentKeys` / `hasCoinDAO` | one-way flags | ✗ | creator- / operator-keyed |

---

## FINDINGS

| ID | Title | Severity | Status |
|---|---|---|---|
| **P4-01** | The tranche start is a permissionless timing choice, and one wei of the staking token taken in the same transaction captures the whole stream | **MEDIUM** | **NEW** |
| **P4-02** | Racing the terminal tranche permanently strands any top-up that is not delivered atomically | **LOW** (MEDIUM if the DAO tops up non-atomically) | **NEW** |
| **P4-03** | Whoever calls `distribute()` first decides which revenue split applies to already-accrued revenue | **LOW** | **NEW** |
| **P4-04** | Three inert-looking `StakedGovToken` entry points force a full protocol-wide revenue distribution from an address with nothing | **LOW** | **NEW** — direct generalisation of FP3-01 |
| **P4-05** | `depositFor(victim, 0)` settles a third party's reward snapshot, discarding their rounding remainder | **LOW** | **NEW** |
| **P4-06** | The total-supply checkpoint array is permissionlessly appendable — one entry per block, forever | **INFO** (attack **refuted** by pricing) | **NEW** |
| **P4-07** | `permit` on a non-transferable token grants an unspendable allowance and burns the `delegateBySig` nonce | **LOW** | **NEW** |
| **P4-08** | **Correction to FP3-01:** the consumed emission clock is real, but the loss it is credited with is not incremental | note | **EXTENDS / CORRECTS** |

---

### P4-01 — MEDIUM — NEW — `fundNextTranche()` hands an unstaked caller the choice of *when* a 365-day emission begins, and lets the same caller be its sole beneficiary

**Coupled pair:** `StakingRewardsFunder.nextTranche` ↔ (`StakingRewards.rewardRate`,
`periodFinish`, `_totalSupply`).
**Invariant the system relies on but does not state:** *a tranche is notified while there is a
supply to stream it to.* `StakingRewards.sol:147–149` says so in prose and calls the gap
"accepted by design — the window between tranche funding and the first staker is expected to be
short."

**Breaking operation:** `StakingRewardsFunder.fundNextTranche()` — `src/StakingRewardsFunder.sol:68`.
The file contains **no access control of any kind** (grepped: zero `msg.sender`, zero
modifiers beyond `nonReentrant`). Every guard inside it is about *time* and *balance*, never
about *who*.

**Why the precondition is structural, not accidental.** After `periodFinish`,
`lastTimeRewardApplicable()` clamps and a staked position earns **exactly nothing** until the
next tranche is notified. `testP4_08a_StakingEarnsNothingBetweenPeriodFinishAndTheNextTranche`:

```
earned at periodFinish       : 2,112,499,999,999,999,968,768,000
earned 45 days later         : 2,112,499,999,999,999,968,768,000
yield during the dead window : 0
```

**So the tranche boundary is precisely the moment a rational pool is emptiest** — and it is
also the exact moment `fundNextTranche()` becomes callable by anyone. The two coincide by
construction.

**Trigger sequence (executed, `testP4_05b_TheSameCallerCanCaptureTheWholeStreamWithOneWei`):**

1. Tranche 0 runs its year with a real 1,000-Coin staker.
2. At `periodFinish` the staker exits — rationally, because the pool now pays zero.
3. Mallory, holding **1 wei** of the staking token and nothing else, executes **one
   transaction**: `stake(1)` then `fundNextTranche()`.

```
mallory stake (wei)       : 1
mallory earned after 1 day: 4,897,260,273,972,602,707,200      (4,897.26 GOV)
mallory earned after 30 d : 146,917,808,219,178,081,216,000    (146,917.81 GOV)
mallory GOV claimed       : 146,917,808,219,178,081,216,000    (transferred out)
```

**Resolution of the measurement — it discriminates the vacancy, not the call**
(`testP4_08_Resolution_OneWeiCaptureDiesIfThePoolIsNotEmpty`): the identical transaction with
alice's 1,000 Coin still staked yields mallory **146 wei** over the same 30 days. The check has
~10²¹ of discrimination between the two states; it is not a tautology.

**Pricing (assignment item 4) — `testP4_08b_VacancySensitivityTable`, tranche 1
(`rewardRate` = 56,681,253,170,979,198 wei GOV/s):**

| vacancy | GOV captured by the 1-wei staker | cost to the caller |
|---|---|---|
| 12 s (one block) | 0.680 GOV | 1 wei of Coin + gas |
| 1 hour | 204.05 GOV | 1 wei of Coin + gas |
| 1 day | 4,897.26 GOV | 1 wei of Coin + gas |
| 7 days | 34,280.82 GOV | 1 wei of Coin + gas |

**Cost to everyone else, and the branch nobody documented.** The vacancy has two mutually
exclusive outcomes and the code comments describe only one of them:

- **nobody stakes** → the emission is unstreamable and permanently destroyed. This is GAP-01 /
  FF-001, and it is the branch `StakingRewards.sol:147–149` calls "accepted by design."
- **one dust-staker stakes** → the emission is not destroyed; it is **transferred in full to
  the dust-staker**, who supplied 1 wei of capital. `testP4_05_…` measures the honest-vacancy
  version of the same window: 34,280.82 GOV unstreamable across 7 empty days.

**Repeatable?** Once per tranche boundary — three further times over the four-year schedule
(tranches 1, 2, 3), and it is a race the attacker structurally wins, because they want the
emptiest possible moment and can fire in the first block where `block.timestamp >= periodFinish`,
while an honest caller wants to wait for stakers and therefore always fires later.

**What is *not* claimed.** Mallory cannot *empty* the pool; the vacancy must occur. The
finding is that the vacancy is (a) structurally likely at exactly this instant, (b)
unbounded in length, and (c) that its start time is an unstaked third party's choice.

**Masking code.** None here — this is the class's other half. `fundNextTranche()` does not look
inert; it looks like a public good. What hides the finding is the *comment*: "the window …
is expected to be short" states an expectation that no code enforces and that the permissionless
gate hands to an adversary.

**Fix — hypothesis, both modes priced.**
*Option A: require a minimum supply at notify time* (`if (stakingRewards.totalSupply() == 0)
revert EmptyPool();`). **Prevents:** both branches of the vacancy — no burn, no dust capture.
**Creates:** a liveness hazard that is strictly worse than the one it fixes. `fundNextTranche`
is serialised on `periodFinish` (L73), so a pool that stays empty would block the *entire
remaining schedule*, not just one tranche; and if the pool is empty long enough, `periodFinish`
never advances and the four-year schedule stalls indefinitely. **This is the same constraint
FP3-01's and FF-002's fixes run into and it is why the authors did not add the check.**
*Option B: cap the emission a single account may earn while it is the sole staker* —
prevents the capture, does not prevent the burn, and adds per-account accounting the contract
does not have.
*Option C (minimal, recommended as the honest one): change nothing in the code and state the
property.* The report should say that each tranche boundary is a permissionless auction whose
prize is `rewardRate × vacancy`, and that the DAO's mitigation is operational — fund each
tranche from a scheduled timelock batch that also seeds the pool, in the first block the gate
opens. **The one thing the report must not do is repeat "the window is expected to be short"
without saying who chooses when the window starts.**

---

### P4-02 — LOW (MEDIUM if the DAO tops up in a separate transaction) — NEW — racing the terminal tranche makes any later top-up permanently unreachable

**Coupled pair:** `nextTranche` ↔ `rewardsToken.balanceOf(funder)`.
**Invariant:** the funder is a conduit, never a sink. `_trancheAmount(3)` is
`rewardsToken.balanceOf(address(this))` (L94), so the final tranche is supposed to sweep
everything the funder holds.

**Breaking operation:** any address calling `fundNextTranche()` in the first block where
`block.timestamp >= periodFinish` and `nextTranche == 3`. `nextTranche` becomes 4, and
`if (tranche == TRANCHE_COUNT) revert AllTranchesFunded()` (L70) is thereafter absorbing —
Pass 3's FP3-04 proved this line is the necessary one.

**Trigger sequence, executed (`testP4_05c_TrancheThreeRaceStrandsATopUpForever`):**

```
funder balance at tranche 3        : 1,137,500 GOV      (the 17.5% sweep)
mallory (no standing) calls fundNextTranche()  -> nextTranche == 4, funder balance 0
the DAO's 1,000,000 GOV top-up lands one block later
fundNextTranche()                  -> revert AllTranchesFunded
GOV permanently stranded in funder : 1,000,000,000,000,000,000,000,000
```

**Cost to the caller:** gas. **Cost to everyone else:** the entire top-up, forever — the funder
has no owner, no recovery function, and `StakingRewards.setRewardsDistribution` is `onlyOwner`
on a contract whose ownership was renounced.

**The mitigation, verified — and it is why this is LOW and not HIGH.**
`testP4_08c_AtomicTopUpPlusFundFailsSafeAfterTheRaceIsLost`: if the DAO delivers the top-up and
the funding call in **one** atomic operation (a `TimelockController.executeBatch`, modelled here
by a helper contract), losing the race reverts the whole operation and the GOV **never leaves
the timelock**:

```
mallory wins the race first
DAO atomic (transferFrom + fundNextTranche) -> revert AllTranchesFunded
GOV still held by the timelock : 1,000,000 GOV
GOV stranded in the funder     : 0
```

**So the loss is entirely a function of whether the DAO's top-up is atomic with its funding
call.** Nothing in the code, the comments, or the test suite says this. The report should carry
it as an operational requirement with a named failure mode, not as a code defect.

**Fix.** No code change removes this without also removing the sweep semantics. State the
requirement: *any GOV added to the funder must be added in the same transaction that consumes
the tranche which sweeps it.* If a code change is wanted, the minimal one is to move the sweep
into a fifth tranche so that `trancheBps(3)`'s 17.5% becomes reachable and a donated balance is
never silently absorbed — which is FP3-04's root decision, and it prevents FF-005, MASK-02 and
GAP-06 at the same time. **Creates:** an unbounded number of sweep tranches unless the counter
still terminates, and FP3-04 already priced the 1-wei grief that a non-terminating counter
exposes.

---

### P4-03 — LOW — NEW — the revenue split applied to accrued revenue is chosen by whoever calls `distribute()` first, not by governance

**Coupled pair:** `RevenueRouter.govStakingBps` ↔ the Coin balance accrued in the Lender.
**Invariant assumed by `setGovStakingBps`:** that a governance decision about the split applies
to the revenue the DAO is deciding about.

**Breaking operation:** `RevenueRouter.distribute()` — `src/RevenueRouter.sol:68`, `external`,
**no access control** — reachable directly, and also through all three `harvestYield` paths on
`StakedGovToken` (P4-04). A `setGovStakingBps` change travels through `votingDelay`
(7,200 blocks) + `votingPeriod` (36,000 blocks) + a 2-day timelock, entirely in public. Anyone
can call `distribute()` in the block before execution.

**Trigger sequence, executed (`testP4_04_UnstakedCallerFixesTheSplitGovernanceIsAboutToChange`),
1,000 Coin accrued, policy moving 20% → 100%:**

```
front-run: stakers receive   :   200 Coin
front-run: treasury receives :   800 Coin
control  : stakers receive   : 1,000 Coin
control  : treasury receives :     0 Coin
```

**Consequence.** 800 Coin — 80% of everything accrued at that instant — is routed under the
policy governance had just decided to replace, and the routing is irreversible. It works in
both directions: a staker (or a bot) can equally front-run a *reduction* to lock in the old,
higher staker share.

**Why LOW and not MEDIUM.** Both destinations are DAO-controlled: `treasury` is
`deployment.timelock` (`CoinDAOFactory.sol:437`). Nothing leaves the organisation; the harm is
misallocation between two DAO-controlled pots plus the loss of governance's ability to make a
split decision effective retroactively. Batching `setGovStakingBps` + `distribute()` in one
timelock operation does **not** close it — the attacker simply distributes one block earlier,
because the revenue sits in the Lender and anyone may pull it at any time.

**Fix — both modes priced.** *Snapshot the bps at accrual time* is not implementable: accrual
happens inside the external Lender. The implementable option is to let governance **pause**
`distribute()` while a split change is in flight. **Prevents:** the front-run.
**Creates:** a pause on the only path by which revenue can ever reach stakers, and
`StakedGovToken.depositFor` is hard-coupled to it (FP3-03 / revenue-lane FF-004), so a pause
would freeze governance membership for its duration. **That trade is worse than the finding.**
The honest recommendation is to document the property: *bps changes take effect on revenue
accrued after the change, and the boundary is set by an unprivileged caller.*

---

### P4-04 — LOW — NEW — three `StakedGovToken` entry points force a full revenue distribution from a caller with nothing; two of them are guarded by the exact FP3-01 shape

**This is the direct generalisation the pass was set to find.** FP3-01's mechanism —
a modifier mutates shared state, then a `if (x > 0)` guard makes the call read as inert — occurs
again on the sibling contract, with a modifier whose side effect is an **external call that
drains a Lender and irrevocably splits its revenue**, rather than a clock advance.

**Breaking operations:** `depositFor(a, 0)` (L102), `harvestAndWithdraw()` (L130),
`harvestAndGetReward()` (L153). All three carry `harvestYield`, which is
`revenueRouter.distribute(); _;`.

**Executed (`testP4_01_DepositForZeroForcesAFullRevenueDistribution`), mallory asserted to hold
zero GOV / zero stGOV / zero allowance / zero Coin before the call:**

```
rewardPerTokenStored before  : 0
rewardPerTokenStored after   : 1,000,000,000,000,000,000
coin pulled out of lender    : 1,000,000,000,000,000,000,000
lender accrued reserves left : 0
stGOV supply delta           : 0
value transferred to mallory : 0
```

`testP4_01b_…` repeats it for `harvestAndGetReward()` and `harvestAndWithdraw()`: both succeed
for a zero-balance caller (`_burn(x, 0)` and `safeTransfer(…, 0)` are no-ops in OZ 5.x) and both
drain the Lender.

**Control and resolution (`testP4_01c_Control_HarvestFreeTwinsAreGenuinelyInert`):** the same
caller invoking the harvest-free twins `getReward()` and `withdraw()` moves **no** accumulator
and leaves the Lender's 500 Coin in place. **The measurement discriminates the modifier, not
the caller.**

**Parallel-path comparison (Phase 5) — and where the class does *not* bite
(`testP4_01d_…`):** `stake(0)` and `withdraw(0)` on `StakingRewards` run the same kind of
modifier first, but their `require(amount > 0)` **reverts**, so the modifier's writes are rolled
back and `lastUpdateTime` is provably unchanged. **The class needs a guard the call *survives*,
not merely a guard that runs late.** `getReward()` survives its guard; `stake(0)` does not.
That distinction is the sharpest available statement of the class and the report should carry it.

**Pricing.** Direct harm: none, measured. `testP4_10_R2_ForcedMicroHarvestsStrandOnlyRoundingDust`
runs 100 forced micro-harvests at a 1e15+999,999-wei drip against a 1,000,000-stGOV supply:

```
stranded after 100 calls : 99,999,900 wei    (999,999 wei per call)
predicted bound (100x)   : 100,000,000 wei   (100 x supply/1e18)
```

The per-call worst case is exactly `supply / 1e18` wei of Coin — the `Math.mulDiv` denominator —
permanently uncreditable inside `StakedGovToken`, which has no recovery function. At an
18-decimal Coin that is ~1e-12 Coin per call against ~150,000 gas of caller cost.
**Economically irrational by roughly nine orders of magnitude; recorded as measured, not
material.** Solvency holds throughout
(`testP4_07b_StakedGovTokenStaysSolventUnderAdversarialForcing`: 300 wei stranded over 25
adversarial harvests, and both stakers claim successfully afterwards).

**Why it is still a finding at LOW.** The value is legibility, and it is the same value FP3-01
identified: **a reader auditing `harvestAndGetReward()` sees `if (reward > 0)` at L159 and
concludes a zero-reward call did nothing, when it has already pulled a Lender's reserves and
split them.** Any future change that makes `distribute()` costly, rate-limited, or lossy
inherits an unbounded permissionless trigger that nothing in these three functions advertises.

**Refuted sub-hypothesis (recorded because the attack framing is tempting):** the zero-supply
redirect is **attacker-timed but not attacker-caused**.
`testP4_04b_ZeroSupplyRedirectIsNotIncrementalHarm` — with stGOV supply at zero and 1,000 Coin
pending, mallory's forced harvest sends 100% to the treasury; and the honest first depositor's
own `harvestYield`-before-mint produces the **identical** 1,000 Coin to the treasury. The
attacker changes nothing. FP3-02's characterisation stands.

**Fix.** None at the call sites. If the client wants the calls to read honestly, the minimal
change is to emit the harvest result (`RevenueDistributed` already exists on the router but is
not surfaced by the wrapper), so a zero-reward `harvestAndGetReward()` is not silent.
**Creates:** nothing beyond gas. Adding a standing check to `depositFor` (`require(value > 0)`)
would **not** help — it would only move the class to the other two functions, and it would
break the legitimate `depositFor(someoneElse, v)` pattern the test base itself relies on.

---

### P4-05 — LOW — NEW — `depositFor(victim, 0)` writes a third party's reward snapshot

**Coupled pair:** `rewards[x]` ↔ `userRewardPerTokenPaid[x]`.
**Breaking operation:** `updateReward(account)` in `depositFor` takes **`account`**, not
`msg.sender` — `src/StakedGovToken.sol:107`. Every other settlement in both reward contracts is
`msg.sender`-keyed. `depositFor` is the single exception, and it is externally callable with
`value == 0`.

The settlement itself is *correct* accounting — it credits the victim. The harm is the
truncation it forces: `earned()` computes `Math.mulDiv(balanceOf, Δrpt, 1e18)`, and settling
resets `Δrpt` to zero, so the discarded remainder is realised rather than carried forward.

**Executed (`testP4_03_ForcedSettlementOfAThirdPartyDiscardsRoundingDust`),** two systems
identical except that in the second, mallory calls `depositFor(alice, 0)` after each of 20
revenue drips:

```
alice earned, unforced : 46,666,666,666,659
alice earned, forced   : 46,666,666,666,640
wei of Coin destroyed  : 19
```

**Pricing.** Under 1 wei per forced settlement, against ~150,000 gas per call (the call carries
a full harvest). **Not economically rational.** Recorded because it is the only cross-account
write in either reward contract and because it is the kind of asymmetry that becomes material
if the reward token is ever low-decimal — which the contract's own header
(`fee-on-transfer and rebasing tokens are unsupported`) does not exclude.

**Fix.** `updateReward(msg.sender)` cannot replace `updateReward(account)` here — the account is
the one whose balance changes, so settling the sender would be *wrong*. The correct minimal
guard is `require(value > 0)` on `depositFor`, which also closes P4-04's first vector.
**Creates:** it forbids a legitimate zero-value deposit and adds one more member to the
"reject exactly zero, say nothing about dust" family FP3-06 already named four times.

---

### P4-06 — INFO — NEW — the total-supply checkpoint array is permissionlessly appendable, and the attack is refuted by its own pricing

**Coupled pair:** `Votes._totalCheckpoints` (append-only) ↔ every `getPastTotalSupply` /
`quorum` lookup.

**The asymmetry (Rule 3, parallel paths).** In OZ `VotesUpgradeable._transferVotingUnits`, the
delegate-vote push is guarded — `if (from != to && amount > 0)` — but the **total-supply push
is not**:

```solidity
if (from == address(0)) { _push($._totalCheckpoints, _add, SafeCast.toUint208(amount)); }
```

So `_mint(x, 0)` appends a total-supply checkpoint while moving no votes.

**Executed (`testP4_02_TotalSupplyCheckpointArrayIsAppendableByAnyone`):**

```
checkpoints before         : 1
checkpoints after 10 calls : 11        (one per block; same-block calls overwrite, not append)
gas per appended entry     : 41,706
numCheckpoints(mallory)    : 0         (delegate checkpoints did NOT grow - the guard works)
```

**Refuted as an attack, by measurement** (`testP4_08d_QuorumCostIsLogarithmicNotLinear`, both
sides warmed):

```
checkpoints                   : 501
warm quorum() gas @ depth 2   : 4,710
warm quorum() gas @ depth 500 : 6,999
```

500 entries cost the attacker 500 × 41,706 = **20,853,000 gas** and cost every future
`quorum()` reader **2,289 gas**. A ratio of roughly **9,100 : 1 against the attacker**, and the
lookup is `O(log n)`, so the ratio worsens without bound. **This is not a denial of service and
should not be reported as one.** It is recorded as an instance of the class — permanently
consumable shared state, reachable with nothing — whose pricing kills it, and because the
guard asymmetry two lines apart is worth one line in the report.

---

### P4-07 — LOW — NEW — `permit` on a non-transferable token grants an unspendable allowance and consumes the nonce `delegateBySig` needs

`StakedGovToken` inherits `ERC20PermitUpgradeable` and exposes `approve`, `permit`,
`transfer` and `transferFrom`, all of which are dead: `_update` reverts `NonTransferable`
whenever `from != 0 && to != 0`. But `permit` and `delegateBySig` share **one** counter —
`nonces(address)` is overridden once, over `ERC20PermitUpgradeable` and `NoncesUpgradeable`
(L186–188).

**Executed (`testP4_09_PermitAndDelegateBySigShareOneNonceOnANonTransferableToken`):**

```
nonces(signer) before                : 0
mallory submits the signer's permit  -> succeeds
nonces(signer) after                 : 1        (the delegateBySig nonce is consumed)
allowance(signer, bob)               : 1 ether
bob.transferFrom(signer, bob, 1e18)  -> revert NonTransferable   (the allowance is unspendable)
```

**Consequence.** A third party holding a broadcast `permit` signature can invalidate a
concurrently-signed `delegateBySig` by front-running it — a griefing of a governance action
using a signature for an operation that can never succeed. The caller needs a signature, so
this is *not* strictly "no standing"; it is recorded here because the shared nonce is item 11
of the inventory and because the underlying oddity — a live `permit`/`approve` surface on a
token that can never be transferred — is worth one report line on its own.

**Fix.** Override `approve` and `permit` to revert. **Prevents:** the nonce grief and a class of
integrator confusion (an allowance that reads as valid on-chain and can never be spent).
**Creates:** a divergence from the ERC-20 interface that some integrators check for, and
`ERC20PermitUpgradeable`'s `DOMAIN_SEPARATOR`/`eip712Domain` must stay for `delegateBySig`.
Low-cost, low-benefit; the report should present it as an option, not a requirement.

---

### P4-08 — note — **CORRECTION to FP3-01** — the consumed clock is real; the loss attributed to it is not incremental

**A refutation is a claim too, and default-REFUTED cuts both ways.** FP3-01 correctly overturned
Pass 2's MASK-04 clearance: `getReward()` from a never-staked address *does* write
`lastUpdateTime` and *does* read as inert. This pass re-derives that (`testP4_01d_…`) and
confirms it. **What this pass could not confirm is the priced figure.** FP3-01 reports
`emission destroyed (wei GOV): 890,410,958,903,808,000` against a 10-day zero-supply window and
argues that "any address can drive it, deliberately, for the price of gas."

**The arithmetic does not support the word *drive*.** During a vacancy, `rewardPerToken()`
returns `rewardPerTokenStored` unchanged (`_totalSupply == 0`, L95), and `updateReward` sets
`lastUpdateTime = lastTimeRewardApplicable()`. **`stake()` carries `updateReward(msg.sender)`
and runs it *before* `_totalSupply += amount`** (L112–114), so at modifier time the supply is
still zero, the early return still fires, and the entire vacancy is skipped **whether or not
anyone touched the contract during it**. The outsider's calls realise the loss earlier; they do
not add to it.

**Executed (`testP4_06_ClockConsumptionRealisesButDoesNotAddLoss`)** — two identical systems,
one with 24 hourly `getReward()` calls from a never-staked address through the genesis vacancy,
one untouched, then an identical 1,000-Coin stake and 30 days:

```
A: 24 hammered hours, earned after 30d : 173,630,136,986,301,367,296,000
B: untouched vacancy,  earned after 30d : 173,630,136,986,301,367,296,000
rewardRate (identical in both)          : 66,986,935,565,702,688
```

**Exactly equal.** The GOV lost to the vacancy is lost to GAP-01 regardless of who calls what.

**What survives of FP3-01, and it is the important half.** The *legibility* finding is
untouched and this pass extends it to three more functions (P4-04): `if (reward > 0)` certifies
that nothing happened about a call that has already changed global state. **What the report must
not say is that an attacker can burn 0.89 GOV by calling `getReward()`** — that GOV is burnt by
the design at the first staker's `stake()` either way. Attributing it to the caller would be a
false positive, and the workspace rule is explicit that a false positive costs more than a
missed LOW.

**Where an attacker genuinely *can* choose the loss is P4-01** — not by consuming the clock,
but by choosing the moment the clock is *started*.

---

## PHASE 5 (INVERSE) — CAN A CALLER WITH NOTHING MAKE SOMETHING REVERT FOR EVERYONE ELSE?

*Assignment item 5. Every candidate was pursued to a conclusion.*

| # | candidate | result |
|---|---|---|
| I1 | Push `lastUpdateTime` past `lastTimeRewardApplicable()` so `rewardPerToken()` underflows and every entry point reverts | **REFUTED, executed.** `testP4_07_NoStandingCallerCannotPoisonRewardPerTokenIntoUnderflow` — 40 adversarial `getReward()` calls at 11-day strides, then 100 days past `periodFinish`. `lastUpdateTime <= periodFinish` asserted at every step, `rewardPerToken()` never reverts, `exit()` still works. Structurally: `updateReward` writes `min(now, periodFinish)`, `notifyRewardAmount` writes `now` and simultaneously sets `periodFinish = now + duration`, and `rewardsDuration` is immutable, so `periodFinish` is monotone and the subtraction can never invert. |
| I2 | Donate reward tokens to `StakingRewards` to break `require(rewardRate <= balance / rewardsDuration)` and block a tranche | **REFUTED, executed.** `testP4_07c_NoStandingCallerCannotBlockATranche` — a 5,000,000 GOV donation only *relaxes* the check; `fundNextTranche()` still succeeds. An outsider can raise `balance` and cannot lower it. |
| I3 | Make `StakedGovToken.notifyRewardAmount` revert `NoStakedSupply` for the router by moving the supply between L72 and L79 | **REFUTED, executed.** `testP4_10_R1_NoStakedSupplyStillUnreachableUnderAdversarialTiming` — zero-supply distributions succeed (silent redirection), a drained-to-zero supply is re-tested, and the guard is reachable **only** by impersonating the router. Confirms FP3-02 and Pass 2 M1 under adversarial timing rather than by trace alone. |
| I4 | Make `_payReward` revert by driving `StakedGovToken` insolvent through forced settlements | **REFUTED, executed.** `testP4_07b_…` — after 25 adversarial forced harvests, held Coin ≥ owed Coin with 300 wei to spare, and both stakers claim. Structurally: `Δrpt = floor(reward·1e18/supply)` and `Σ_a mulDiv(bal_a, Δrpt, 1e18) ≤ mulDiv(supply, Δrpt, 1e18) ≤ reward`, so payouts can never exceed deposits. |
| I5 | Squat a predicted clone address to make `CoinDAOFactory.deploy` revert for a specific salt | **REFUTED by construction.** Clones are `CREATE2`-d from the factory's own address; no external account can occupy the address. `usedDeploymentKeys` is keyed on `keccak256(creator, salt)`, so only the creator can burn their own key. |
| I6 | `VestingWallet.release` is permissionless and advances a one-way released counter | **NOT A FINDING, executed.** `testP4_10_R3_PermissionlessVestingReleaseIsNotAGrief` — mallory releases 700,000 GOV; every wei goes to the beneficiary (the timelock). Standard OZ; the only effect is to pay the beneficiary earlier. |
| I7 | **The one that is real:** consume `nextTranche` so the honest caller's transaction reverts | **CONFIRMED — P4-01 and P4-02.** This is the only place in the codebase where a no-standing caller can make a *specific, valuable* transaction of someone else's revert, and the revert (`AllTranchesFunded`) is permanent. |

---

## CORPUS EXCLUSION — what the suite cannot see about this class

| test / mock | what it excludes | consequence |
|---|---|---|
| `test/StakingRewardsFunder.t.sol` — every `fundNextTranche()` call is made by the test contract itself | there is no test in which a *stranger* funds a tranche, and none in which the pool is empty at the boundary | P4-01 is invisible to the whole suite; so is the fact that the funder contains no `msg.sender` |
| `testPermissionlessFourTrancheLifecycleAssignsFinalDust` | names the property "permissionless" and then exercises it only from the privileged position | **the one test whose title states the finding's premise is the one that never varies the caller** |
| `test/StakedGovToken.t.sol` — the staker is built with `address(this)` as `revenueRouter_` | no test drives `depositFor`/`harvestAnd*` through a real `RevenueRouter` | the three forced-harvest paths (P4-04) cannot be observed anywhere in the tree |
| every deposit test passes a non-zero `value` | `depositFor(x, 0)` is never exercised | P4-04's and P4-05's entry vector is untested |
| `MockMonolithLender.pullLocalReserves()` early-returns and cannot revert | no test can reach a distributor outage from the factory path | already recorded by FP3-03; re-confirmed |

**No test in the tree asserts "a tranche cannot be started against an empty pool", "the funder
is never a sink", or "a caller with no position cannot change global state".** Those are the
three assertions this pass's findings would have failed.

---

## SUMMARY

- **Externally-callable functions enumerated: 5 contracts, full ABI surfaces**, with
  reachability from a zero-standing caller determined for each. **Nine** succeed from an address
  with no stake, no balance, no role and no approval: `StakedGovToken.depositFor(x,0)`,
  `harvestAndGetReward`, `harvestAndWithdraw`, `withdraw`, `getReward`, `delegate`;
  `RevenueRouter.distribute`; `StakingRewardsFunder.fundNextTranche`;
  `StakingRewards.getReward` (plus `CoinDAOVestingWallet.release` and `CoinDAOFactory.deploy`,
  both cleared).
- **New findings: 7** (P4-01 … P4-07). **Prior-pass corrections: 1** (P4-08 re-prices FP3-01's
  loss figure while upholding its mechanism). **Refuted: 7** (I1–I6 plus the zero-supply-redirect
  attack framing inside P4-04).
- **The class generalises, but it splits in two.** The `StakedGovToken` instances (P4-04, P4-05)
  are the *same shape* as FP3-01 and, like FP3-01, their measured harm is dust — the honest
  result is a legibility finding, not a loss. **The one instance with real value at stake is
  the opposite shape:** `fundNextTranche()` does not look inert at all, and it is the only
  permissionless call in the codebase that lets a caller with 1 wei of capital take, or destroy,
  thousands of GOV per day of a window whose start time they choose.
- **The distinction that makes the class precise** — and the single line this pass would put in
  the report: *the modifier's writes only survive if the call survives.* `stake(0)` and
  `withdraw(0)` run `updateReward` first and then revert, so nothing persists.
  `getReward()`, `depositFor(x,0)`, `harvestAndGetReward()` and `harvestAndWithdraw()` run
  their modifier first and then **succeed**, so everything persists. The bug class is not
  "modifier before guard"; it is **"modifier before a guard the caller passes trivially."**
- **Verification level 4 for every finding**, with a control or a resolution measurement
  attached to each headline claim (P4-01's 10²¹ discrimination; P4-04's harvest-free twins;
  P4-06's re-measured gas; P4-08's two-system equality). 25 audit tests, **80/80** in the
  disposable copy. `[scratch]` byte-identical.
