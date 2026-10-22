# NEMESIS Pass 3 — Feynman Auditor — TARGETED: the census of one-way transitions

**Lens:** `.claude/skills/feynman-auditor/SKILL.md`, run as a **targeted** re-interrogation, not a
re-audit. Category 2 (ordering) and Category 5 (first call / last call / double call) are the
question sets actually applied; Categories 1, 3 and 4 are used only where they bear on
irreversibility.

**Assignment.** Pass 2 (`SI-003`, seams) established that the governance electorate is a **ratchet**
rather than a freeze: entry (`depositFor`) is gated on an external contract, exit (`withdrawTo`) is
not, so the set can only shrink — and the contract that would need a repair setter
(`StakedGovToken`) has no owner at all. My job was to ask whether that shape is **one instance or a
pattern**, by building a complete census of one-way transitions across the whole system and
interrogating each.

**Language:** Solidity 0.8.26 / via-ir / optimizer 200 / Foundry / OpenZeppelin v5.

**Scope read:** `[scratch]` — all 12 files, 1,400 lines, in full.
**Not read, per assignment:** `[scratch]`, anything under `engagements/`. All
OpenZeppelin v5 behaviour below was established **by execution or by the compiled ABI**, never by
reading the library.

**Prior work read before starting (verify-time enrichment only, per `CLAUDE.md`):**
`state-pass2-seams.md` (SI-001…SI-008 in full) and `state-pass2-registries.md` (SI-001…SI-011 in
full). Where a transition is already owned by a Pass-1 or Pass-2 finding I **cite it and do not
re-derive it**; the census records it so the map is complete, and the Findings section contains only
what is new.

---

## 0. Execution environment

Disposable full-tree copy at
`…/[scratch]`. **`[scratch]` was never written to** —
`git status --porcelain [scratch]` and `git diff --stat -- [scratch]` are both empty, `diff -rq` of
`src/` is clean, and the audited tree's own suite re-verified **55/55** at the end.

| suite | result |
|---|---|
| project baseline in the copy | **55/55 PASS** |
| project baseline + this pass's PoCs | **65/65 PASS** |
| this pass's PoCs (`test/audit/FeynmanPass3Irreversibility.t.sol`) | **10/10 PASS** |

The PoC file is preserved at `.audit/poc/FeynmanPass3Irreversibility.t.sol`; drop it into
`test/audit/` of a copy of the tree to reproduce. It depends only on the project's own
`test/helpers/CoinDAOTestBase.sol` and `test/mocks/MockMonolith.sol`.

Verification levels use the workspace scale: **L1** compiles · **L2** a check passes · **L3** the
check *could have failed* (a control is included) · **L4** executed in a real EVM.

**Harness traps honoured.** Every roll/warp goes through `vm.getBlockTimestamp()` or an absolute
target read from the contract (forge 1.5.1 caches `NUMBER`/`TIMESTAMP` after the first roll — Pass 2
SI-008).

**A harness defect of my own, recorded because it is the same class.** My first run of
`test_F302…` reported `next call did not revert as expected`. The claim was correct; **my check was
broken**: I had written

```solidity
vm.expectRevert();
tOld.schedule(d.coin, 0, inner, bytes32(0), bytes32(uint256(4)), factory.DEFAULT_TIMELOCK_DELAY());
```

Solidity evaluates the *arguments* first, so the non-reverting `factory.DEFAULT_TIMELOCK_DELAY()`
staticcall consumed the `expectRevert`, not `schedule`. Hoisting the call into a local fixed it.
Worth one line in the report as a general trap: **`vm.expectRevert()` binds to the next call the EVM
makes, which is not necessarily the next call you wrote.**

---

## 1. The question this pass exists to answer

> Is `SI-003` one ratchet, or is the whole system built out of them?

**Answer: it is a pattern, and it has a single structural cause.** The launch transaction spends
every authority it creates. When `_deployCoinDAO` returns, **five of the nine contract types in the
system have no mutable authority of any kind, ever again** (ABI-verified and asserted at L4 in
`test_F307…`):

| contract | authority after the launch transaction ends |
|---|---|
| `CoinDAOFactory` | **none** — no `owner()`, no pause, no setter for any implementation (ABI: the only 4 mutating functions are `deploy`, `deployForExistingCoin`, `setPendingMonolithBeneficiary`, `acceptMonolithBeneficiary`) |
| `GovToken` | **none** — no owner, no mint, fixed supply |
| `StakedGovToken` | **none** — no owner (Pass 2 SI-003), no setter for `revenueRouter` or `rewardsToken` |
| `StakingRewardsFunder` | **none** — no owner, no rescue; only `fundNextTranche` |
| `StakingRewards` | **none** — `renounceOwnership()` at `CoinDAOFactory.sol:488` |
| `RevenueRouter` | owner = the timelock; **2 setters only** (`setGovStakingBps`, `setManager`) |
| `CoinDAOVestingWallet` ×3 | owner = timelock / monolithBeneficiary / deployerRecipient |
| `TimelockController` | **self-administered only** — `renounceRole(DEFAULT_ADMIN_ROLE, factory)` at `CoinDAOFactory.sol:430` |
| `CoinDAOGovernor` | `onlyGovernance` — i.e. the timelock |

So **every repair path in the entire system runs through the timelock**, and the timelock's only
admin is itself. That is the structural cause: the launch is not merely irreversible in places, it
is irreversible *by construction*, and the number of distinct one-way steps inside one transaction
is what makes a later mistake terminal rather than costly.

---

## 2. THE CENSUS — every one-way transition in `src/`

Compiled by reading all 12 files line by line and confirmed by explicit greps and the compiled ABI.
**"Intended?"** answers the question the assignment demanded: does a comment engage with the
irreversibility, or is it the incidental consequence of ordering?

### 2.1 Immutables fixed at construction

| # | transition | actor | intended? | exit |
|---|---|---|---|---|
| I-1 | `CoinDAOFactory.monolithFactory` and the six `*Implementation` addresses (`CoinDAOFactory.sol:51-57`) | factory deployer | **yes**, `immutable` is explicit | none. A buggy implementation requires a **new factory**, which changes every CREATE2 prediction. No comment engages with this. |

### 2.2 Initializers consumed (one-shot, `_disableInitializers()` on every implementation)

| # | transition | writes frozen forever | intended? | exit |
|---|---|---|---|---|
| I-2 | `GovToken.initialize` | name, symbol, the 10,000,000e18 mint | yes | none needed |
| I-3 | `StakedGovToken.initialize` | `rewardsToken`, `revenueRouter` | partly | **none, and no owner exists** → the load-bearing half of Pass 2 SI-003 |
| I-4 | `RevenueRouter.initialize` | `lender`, `coin`, **`treasury`**, `govStaking`, `govStakingBps` | see §5 FI-001 | only `govStakingBps` has a setter |
| I-5 | `StakingRewards.initialize` | `stakingToken`, `rewardsToken`, `rewardsDuration` | **yes** — `StakingRewards.sol:172-173` names the omission of `setRewardsDuration` | none |
| I-6 | `StakingRewardsFunder.initialize` | `stakingRewards`, `rewardsToken`, `totalRewards` | no comment | none, and no owner |
| I-7 | `CoinDAOVestingWallet.initialize` ×3 | owner, `start`, `duration` | no comment | owner can transfer; start/duration never |

### 2.3 Ownership / roles renounced or handed away

| # | transition | line | actor | intended? | exit |
|---|---|---|---|---|---|
| I-8 | `timelock.renounceRole(DEFAULT_ADMIN_ROLE, factory)` | `:430` | factory, at launch | **yes** — the comment says *"before permanently removing the factory as timelock admin"* | **none.** This is the step that makes every later governance mistake terminal. |
| I-9 | `coinStakingRewards.renounceOwnership()` | `:488` | factory, at launch | **yes** — Phase 7 comment says *"lock reward ownership"* | none. Also permanently disables `setRewardsDistribution`. |
| I-10 | `revenueRouter.transferOwnership(timelock)` | `:454` | factory, at launch | yes | single-step `Ownable`, so a later mis-transfer is one-way |
| I-11 | lender `operator` → the router (`setPendingOperator` + `acceptLenderOperator`) | `:452-453` | factory, at launch | **yes, and argued at length** — `RevenueRouter.sol:12-17` | **by design none.** §5 FI-003 shows the *re-acquisition* path can also be destroyed. |
| I-12 | `RevenueRouter.renounceOwnership()` | inherited | timelock, 1 proposal | **no** — no comment | none → Pass 2 SI-005, sharpened by FI-003 |
| I-13 | `CoinDAOVestingWallet.renounceOwnership()` ×3 | inherited | each wallet's owner, 1 action | **no** | none → Pass 1 FF-003; the **treasury** instance (28% of supply) is measured in FI-007 |
| I-14 | `timelock.revokeRole(PROPOSER_ROLE, governor)` | inherited | timelock, 1 proposal | **no** | none → Pass 2 SI-001e; escalated by FI-002 |

### 2.4 Monotonic counters and write-once mappings

| # | transition | direction | actor | exit |
|---|---|---|---|---|
| I-15 | `hasCoinDAO[lender] = true` (`:359`) | false→true only. Grep: `delete`/`.pop()`/`= false` — **zero hits in `src/`** | any launcher | **none.** A lender is consumable once, whether or not the launch actually acquired the operator role (Pass 2 SI-003 registries) |
| I-16 | `usedDeploymentKeys[key] = true` (`:530`) | one-way | any launcher | none → Pass 2 SI-006 registries |
| I-17 | `deployments[]`, `deploymentKeyForId[]` | push-only | launcher | none → Pass 2 SI-007 seams |
| I-18 | `StakingRewardsFunder.nextTranche` (`:82`) | `+1`, capped at 4 | **ANY unprivileged address** | none. See §3.4 |
| I-19 | `StakingRewards.periodFinish` (`:163`) | jumps to `now + 365 days` on every notify | **ANY unprivileged address**, via `fundNextTranche` | none |
| I-20 | `StakedGovToken.rewardPerTokenStored` (`:172`) | `+=` only | the router (permissionless via `distribute`) | none — correct for an accumulator |
| I-21 | `userRewardPerTokenPaid[account]` | `+=` only | per account | none — correct |

### 2.5 One-way *in effect* — settings whose undo requires the thing they broke

| # | transition | actor | exit |
|---|---|---|---|
| I-22 | `Governor.updateTimelock(T_new)` | 1 proposal | the four orphaned bindings — Pass 2 SI-001. **`RevenueRouter.treasury` is a fifth and has no exit at all** → FI-001 |
| I-23 | `GovernorSettings.setProposalThreshold(huge)` | 1 proposal | none — nobody can propose the undo |
| I-24 | `GovernorVotesQuorumFraction.updateQuorumNumerator(1000)` | 1 proposal | conditional → FI-004 |
| I-25 | `TimelockController.updateDelay(huge)` | 1 proposal | none — `schedule` reverts (`block.timestamp + delay` overflows), so the undo cannot be scheduled |
| I-26 | `GovernorSettings.setVotingPeriod` / `setVotingDelay` extremes | 1 proposal | practically none |

**Explicit negative grep, because absence claims are the dangerous ones:**
`updateTimelock`, `updateDelay`, `setProposalThreshold`, `setVotingDelay`, `setVotingPeriod` appear
**zero times in `src/`, `script/` AND `test/`.** The project has never engaged with any of them, in
code, test or comment. `updateQuorumNumerator` appears only in `test/CoinDAOGovernor.t.sol`.

### 2.6 Permanent value sinks (address-level, no owner behind them)

| # | sink | how value arrives | exit |
|---|---|---|---|
| I-27 | `CoinDAOFactory` itself | `deployerRecipient == address(factory)` (legal: `_validate` only checks non-zero when `bps != 0`) | **none, ever** → FI-005 |
| I-28 | `StakingRewards` | GOV emitted while `_totalSupply == 0` + rate truncation | **none** (owner renounced, no `recoverERC20`) → FI-006 |
| I-29 | a renounced `CoinDAOVestingWallet` | already held | none → FI-007 |
| I-30 | an orphaned `TimelockController` | `RevenueRouter.distribute()`, permissionlessly, forever | **none after FI-002's second step** |

---

## 3. Category 2 — ordering, the question that matters

> Which **pairs** of one-way transitions can be reached in an order that leaves the system in a
> state no actor can exit?

### 3.1 Inside the launch transaction — VERIFIED SAFE

The eight-phase launch contains at least three irreversible steps (I-8, I-9, I-11). I asked whether
any reordering leaves a half-configured system. **It cannot**, for two independent reasons, and I
verified the load-bearing one by mutation rather than by assumption:

**Mutation M2 — move `renounceRole(DEFAULT_ADMIN_ROLE)` (`:430`) *before* the two `grantRole` calls
(`:428-429`).**

| | project suite |
|---|---|
| original source | 55/55 pass |
| **M2 applied** | **12 tests fail with `AccessControlUnauthorizedAccount(factory, 0x00)`** — every launch reverts |

The ordering **fails safe**: the factory cannot renounce admin and then discover it needed it. And
because the whole launch is one transaction with **no `try`/`catch` anywhere in `src/`** (grep: zero
hits), any failure rolls every irreversible step back together. *Recorded as a verified negative,
not a finding.* M2 reverted; `src/CoinDAOFactory.sol` re-verified byte-identical.

The same holds for I-9: `setRewardsDistribution` (`:486`) must precede `renounceOwnership` (`:488`),
and reversing it reverts.

### 3.2 Across transactions — THE ONE THAT DOES NOT FAIL SAFE

`Governor.updateTimelock` (I-22) freezes `RevenueRouter.treasury` at the retired timelock, and
**no order of operations can move it, because no setter exists.** Then the natural *next*
housekeeping action — `revokeRole(PROPOSER_ROLE, governor)` on the retired timelock (I-14) —
removes the only remaining way to reach the value that keeps arriving there.

This is the assignment's question answered in the affirmative. Written up as **FI-001 / FI-002**.

### 3.3 The launch-time renounce as an amplifier of every later step

I-8 is taken at launch and is correct on its own terms. Its consequence is that **I-14, I-23, I-24,
I-25 and I-26 all become terminal instead of recoverable**, because there is no admin outside the
timelock to undo them. The pairing is temporal, not causal: an irreversible step taken by the
*factory* at genesis removes the exit from a class of irreversible steps taken by *governance*
years later. Neither half is a defect in isolation. Written up as **FI-008 (INFO)**.

### 3.4 Which one-way transitions can an UNPRIVILEGED actor force or front-run?

| transition | unprivileged? | can they choose the instant? |
|---|---|---|
| I-18 / I-19 `fundNextTranche()` | **YES** — no access control at all | **YES**, any time after `periodFinish`. Emissions from that instant stream to whoever is staked → Pass 1 emissions FF-003, Pass 2 SI-002 |
| `RevenueRouter.distribute()` | **YES** | **YES** — and after FI-002 this is a griefing primitive: any address can push revenue into an unreachable one |
| `VestingWallet.release(token)` | **YES** | yes — keeps paying `owner()`, including a dead timelock (Pass 2 SI-001) |
| `StakedGovToken.depositFor` / `withdrawTo` | **YES** | yes — moves the quorum base (Pass 2 SI-003) |
| `StakingRewards.stake` at a *published* predicted address | **YES** | yes, inside the launch tx (Pass 2 SI-002) |
| I-15 / I-16 (burning a lender or a key) | **NO** | blocked: `deploymentKey` binds `msg.sender`, and `deployForExistingCoin` requires `msg.sender == lender.operator()` (`:328`). Re-confirms Pass 2 R-5 by trace. |
| I-8…I-14, I-22…I-26 | **NO** | all require the factory at launch, or a passed proposal |

---

## 4. Category 3 — the asymmetric ADD/REMOVE pairs that *make* a ratchet

| pair | ADD path | REMOVE path | asymmetric in | verdict |
|---|---|---|---|---|
| the electorate | `depositFor` — **requires `revenueRouter.distribute()` to succeed** | `withdrawTo`/`withdraw` — **deliberately no harvest** (`StakedGovToken.sol:127-129`) | **external dependency** | Pass 2 **SI-003**. The archetype. |
| **router config** | `initialize` writes 5 values | **1 of the 5 has a setter** (`govStakingBps`); `treasury`, `lender`, `coin`, `govStaking` have **none** (ABI-verified) | **existence of a setter** | **NEW → FI-001** |
| lender operator | `acceptLenderOperator` (`onlyOwner`) | none, by design | deliberate | I-11; but see **FI-003** |
| timelock roles | `grantRole` — **2 hits in `src/`, both at `:428-429`, factory-only** | `revokeRole`/`renounceRole` — reachable by 1 proposal, forever | **who can call, and when** | Pass 2 SI-001e; escalated by **FI-002** |
| vesting ownership | `transferOwnership` | `renounceOwnership` — terminal | reversibility | Pass 1 FF-003; measured in **FI-007** |
| `monolithBeneficiary` | `setPending` + `accept` | **no cancel** (`:255` rejects zero) | cancellability | Pass 2 SI-011 |
| `hasCoinDAO` / `usedDeploymentKeys` | `= true` | **does not exist** | existence | Pass 2 SI-006 registries |
| rewards distributor | `setRewardsDistribution` (`onlyOwner`) | — | **the setter exists but the owner is renounced two lines later** (`:486` then `:488`) | intended; frozen and self-enforcing (Pass 2 VN-B) |
| StakingRewards stake/unstake | `stake` | `withdraw` | **symmetric** — both permissionless, both `updateReward` | sound |

The second row is the finding this pass adds: **the router reproduces `SI-003`'s exact shape in a
different contract.** One side of the pair (the owner) is movable; the other side (the treasury it
pays) is not.

---

## 5. Findings

---

### FI-001 — `RevenueRouter.treasury` is write-once with no setter, so **no complete timelock migration exists** — including the one Pass 2 proved "safe"

**Severity: MEDIUM** (trigger inherited from SI-001; the *new* content is that SI-001's recommended
remedy is unachievable) · Module `RevenueRouter` + `CoinDAOGovernor` (inherited
`GovernorTimelockControl`)
**Verification: Method B — `test_F301_completeMigrationCannotMoveTheRouterTreasury` PASS, control
`test_F301control_governanceStillWorksAfterTheCompleteMigration` PASS. Level 4. Fix resolution
measured by mutation M1.**

#### The Feynman question that exposed it

> Q3.2 / Q1.2 — *`initialize` writes five values. Which of them have an inverse operation, and why
> those and not the others?*

`RevenueRouter.initialize` (`RevenueRouter.sol:40-60`) writes `lender`, `coin`, `treasury`,
`govStaking` and `govStakingBps`. Exactly **one** of the five can ever be changed again.

**Explicit negative grep and ABI check, run because absence claims are the dangerous ones:**
`setTreasury` — **zero hits in `src/` and `script/`**. The compiled ABI's complete non-view surface
is `acceptLenderOperator, distribute, initialize, renounceOwnership, setGovStakingBps, setManager,
transferOwnership`. There is no way to change `treasury`, for anybody, ever.

#### Engaging with the comment that exists

`RevenueRouter.sol:12-17` is unusually explicit, and it must be engaged with rather than ignored:

```
/// @dev This contract is intentionally the permanent operator of its paired Lender. It deliberately
/// does not expose a call to `setPendingOperator`, so neither its owner nor the timelock can migrate
/// the operator role after deployment. Governance retains only the manager and revenue-split controls.
```

The comment is **correct about what it claims** — the *operator* immobility is deliberate and
argued. But it also states the design's assumption in passing: *"Governance retains only the manager
and revenue-split controls."* That sentence is true only while **the treasury address is stable**.
`treasury` is set to `deployment.timelock` at `CoinDAOFactory.sol:407`, and the Governor inherits
`updateTimelock`, which moves the address the DAO governs through and leaves `treasury` behind. The
comment engages with one frozen binding and is silent about a second one that a third party
(`CoinDAOFactory`) created and that an inherited function can invalidate.

#### Executed evidence — the *complete* migration, and what it misses

I implemented Pass 2 SI-001d's proven-safe recipe exactly: construct `T_new` **with the Governor
already in `proposers`**, then in one batched proposal (1) `revenueRouter.transferOwnership(T_new)`,
(2) `treasuryVesting.transferOwnership(T_new)`, (3) `GOV.transfer(T_new, balance)`, (4)
`governor.updateTimelock(T_new)`.

```
Everything SI-001d lists DID move:
  governor.timelock()             == T_new   OK
  revenueRouter.owner()           == T_new   OK
  treasuryVesting.owner()         == T_new   OK
  GOV.balanceOf(T_old)            == 0       OK

The binding the recipe cannot move:
  revenueRouter.treasury()        == T_old   <-- FROZEN, and no setter exists

control (test_F301control): a follow-up proposal through T_new executes normally
                            (setGovStakingBps -> 5000), so governance is alive
```

#### Why this matters more than "one stale pointer"

`RevenueRouter.distribute()` is **permissionless**. After a migration, any address can push the
treasury share of revenue into the retired timelock, forever. Two regimes make that share non-zero:

- governance sets `govStakingBps < 10_000` (the whole point of that setter); or
- `govStaking.totalSupply() == 0`, in which case `RevenueRouter.sol:72-75` sends **100%** to
  `treasury` — and Pass 2 SI-003 shows the staked supply can ratchet to zero.

The value is not *lost* while the Governor still holds `PROPOSER_ROLE` on `T_old` — it is
**recoverable one governance proposal per sweep, forever**, via `governor.relay` (proven as the
control in FI-002 below). That is a permanent operational tax that nothing in the code, the tests or
the comments tells an operator to expect.

#### Fix — both failure modes priced, with the resolution measured

*Option A (code).* Add `setTreasury(address) external onlyOwner`, mirroring `setGovStakingBps`.

**Mutation M1 applied and measured — this is the evidence the recommendation needs:**

| | project suite | this pass's tests |
|---|---|---|
| original source | 55/55 pass | FI-001 reproduces |
| **M1 applied** | **55/55 still pass** | a migration batch containing `setTreasury(T_new)` moves the treasury; `test_M1_withSetTreasuryTheMigrationBecomesComplete` PASS |

- *Prevents:* the entire finding, and FI-002 with it. Compatible with **every** intended flow.
- *Creates:* one more `onlyOwner` setter, so a compromised or mistaken governance can redirect
  revenue in one action. **That is a real new failure mode and it should be stated, not waved
  away** — but it is the same exposure `setGovStakingBps` already carries (governance can already
  send 100% of revenue anywhere by setting the bps and controlling the staker side), so it does not
  widen the blast radius, it only makes an existing one symmetric. Adding a zero-address check (as
  `setManager` does) is required.

*Option B (documentation only).* Record that `updateTimelock` must never be used, and that the
timelock is effectively immutable for this system.
- *Prevents:* the finding, at zero code risk.
- *Creates:* it makes explicit that the DAO can **never** migrate its timelock — which is a much
  larger commitment than the current code communicates, and the tree contains no production runbook
  at all (Pass 1 governance FF-013).

**Recommendation: A, plus the correction to SI-001's Option A below.**

#### ⚠️ This finding corrects a Pass 2 recommendation

Pass 2 SI-001 recommends *"Option A (documentation only): record the batched migration procedure
above as the only supported way to change the timelock."* **That procedure cannot be written
correctly today** — there is no step that moves `treasury`, and no step can be invented, because the
function does not exist. Shipping SI-001 Option A without FI-001 Option A would hand the client a
runbook that leaves a permanent revenue leak and reads as complete. That is the shape `CLAUDE.md`
warns about: *"it converts 'N things are broken' into 'N-1 things are broken and you believe you are
safe.'*

---

### FI-002 — the natural post-migration cleanup converts FI-001's leak into permanent loss, and no actor can exit

**Severity: MEDIUM** (terminal case of FI-001; recorded separately because the failure mode differs
in kind — a recoverable tax becomes an unrecoverable sink)
**Verification: Method B — `test_F302_cleanupAfterMigrationStrandsAllFutureRevenuePermanently`
PASS, with an in-test CONTROL that proves recovery works before the second step. Level 4.**

#### The Feynman question

> Q2.5 — *Can the ORDER in which two irreversible operations are performed matter?*

Two one-way transitions, each individually defensible, in the order an operator would naturally
perform them:

1. **`updateTimelock(T_new)`** (I-22) — the framework's designated migration primitive. Freezes
   `revenueRouter.treasury` at `T_old` (FI-001).
2. **`revokeRole(PROPOSER_ROLE, governor)` on `T_old`** (I-14) — *"we have migrated; the retired
   timelock should no longer trust the Governor."* Plausible housekeeping. Reachable in one relayed
   proposal.

Step 2 in isolation is Pass 2 SI-001e and is already known. **Step 1 followed by step 2 is new**,
because step 1 is what guarantees that value keeps *arriving* at the address step 2 seals.

#### Executed evidence, including the control that proves the check has resolution

```
--- CONTROL (before step 2) -----------------------------------------------
governor still holds PROPOSER on T_old                    : true
bystander 0xD00D calls router.distribute()
  -> Coin pushed into the ORPHANED timelock                : 50.000000000000000000
recovery: T_new -> governor.relay(T_old, schedule(...)) -> anyone executes
  -> Coin.balanceOf(T_old)                                 : 0
CONTROL PASSED: T_old is drainable while the governor holds PROPOSER on it

--- STEP 2: the housekeeping proposal --------------------------------------
relay(T_old, schedule(T_old.revokeRole(PROPOSER_ROLE, governor)))  -> executes
  T_old.hasRole(PROPOSER_ROLE, governor)                   : false

--- STEP 3: an UNPRIVILEGED actor forces more revenue in --------------------
bystander 0xD00D calls router.distribute()
  -> Coin now permanently stranded in T_old                : 250.000000000000000000

--- STEP 4: every exit checked explicitly ----------------------------------
T_old.hasRole(DEFAULT_ADMIN_ROLE, factory)                 : false   (renounced at :430)
T_old.hasRole(DEFAULT_ADMIN_ROLE, T_old)                   : true    (and unreachable)
governor.relay(T_old, schedule(...))  from T_new           : REVERTS
T_old.schedule(...)                   from a bystander     : REVERTS
router: no setTreasury exists (ABI)
NO EXIT
```

The control is the important half. It establishes that the check **could have failed** — recovery
genuinely works before step 2 — so the post-step-2 reverts are the finding and not a broken harness.

#### Why this is a Feynman ordering finding rather than "governance can harm itself"

Three things, and they are the same three that made Pass 2 SI-001 a finding:

1. **Both operations look complete.** `updateTimelock` is the framework's migration primitive;
   revoking a retired contract's roles is textbook hygiene.
2. **Nothing anywhere connects them.** The router does not know the Governor exists. The Governor
   does not know the router exists. `RevenueRouter.sol:12-17` reasons about the *operator* role and
   never mentions `treasury`.
3. **The damage accrues afterwards, permissionlessly.** Unlike SI-001's snapshot of stranded value,
   this one keeps growing, and **any address on earth can grow it** by calling `distribute()`.

**Honest limit on reachability.** Both steps need passed proposals; under a healthy DAO this is a
two-step mistake, not an attack. I have graded on the mistake case. Under Pass 1 FF-001 (quorum ≤
proposal threshold, so ~0.1% of supply captures governance) it is also an available *denial* action.

#### Fix

FI-001 Option A (`setTreasury`) closes this completely — measured at L4 under mutation M1. No
separate fix is needed. If `setTreasury` is rejected, the *only* remaining mitigation is procedural:
never call `updateTimelock`, and never revoke roles on a retired timelock — which must be written
down, because nothing in the code prevents either.

---

### FI-003 — renouncing the router does not merely freeze the split; it destroys the only path back to the operator role

**Severity: LOW** · **EXTENDS Pass 2 SI-005**
**Verification: Method B — `test_F303_routerRenounceAlsoKillsTheOperatorReacquisitionPath` PASS,
with an in-test control. Level 4.**

Pass 2 SI-005 established that `RevenueRouter.renounceOwnership()` freezes `govStakingBps` and
`setManager` forever. The census surfaces a third door that closes with them, and it is the one that
matters most:

`acceptLenderOperator()` (`RevenueRouter.sol:64-66`) is `onlyOwner`. It is **not** one-shot — the
NatSpec calls it *"the one-time operator nomination used while wiring the CoinDAO deployment"*, but
the function itself has no such guard. That makes it the system's **only** way to re-acquire the
lender's `operator` role if it is ever lost or re-nominated out of band — precisely the scenario
Pass 2 SI-003 lists as an open question for the client.

**Executed:**

```
CONTROL: with an owner, a re-nomination CAN be re-accepted
  lender.setPendingOperator(router); proposal -> router.acceptLenderOperator()
  lender.operator() == router                          <- recovery path works

then: one proposal -> router.renounceOwnership()
  router.owner()                    == 0x0
  router.acceptLenderOperator()  from a bystander      -> REVERTS
  router.acceptLenderOperator()  from the timelock     -> REVERTS
  router.setManager(...)         from the timelock     -> REVERTS
```

**Why it matters.** The NatSpec's framing (*"one-time"*) understates what the function is. Read as
one-time, renouncing looks like it costs only the two config setters SI-005 names. Read correctly,
renouncing also throws away the system's sole recovery mechanism for its most important external
binding.

**Fix.** Pass 2 SI-005 already recommends overriding `renounceOwnership()` to revert, and prices it
as near-costless. **I concur and this finding strengthens the case** — the option being given up is
not merely "no owner", it is "no way back". Additionally: correct the NatSpec at
`RevenueRouter.sol:62`, since "one-time" describes the intended usage and not the code.
*Creates:* nothing.

---

### FI-004 — `updateQuorumNumerator(1000)` is terminal whenever any staked GOV is undelegated, and the only escape is owned by the passive holder rather than by governance

**Severity: LOW** · **NEW** (composes Pass 1 governance FF-011 with I-24)
**Verification: Method B — `test_F304_maxQuorumPlusUndelegatedStakeIsTerminal` PASS. Level 4.**

#### The Feynman question

> Q5.2 / Q1.4 — *`updateQuorumNumerator` is bounded at `quorumDenominator()`. Is that bound
> sufficient? What happens exactly AT the bound?*

`CoinDAOGovernor.quorumDenominator()` is overridden to `1_000` (`:68-70`). So the numerator's legal
maximum is 1,000, at which `quorum(t) == getPastTotalSupply(t)` — **the entire staked supply**.

The bound is not sufficient, because the two sides are measured differently: `quorum` counts
`getPastTotalSupply` (all stGOV), while votes count **delegated** stGOV. Pass 1 FF-011 recorded that
asymmetry as LOW on its own. At numerator 1,000 it becomes terminal.

**Executed:**

```
VOTER   stakes 10,000e18 and self-delegates
passive stakes  5,000e18 and NEVER delegates      (FF-011's shape)

one proposal -> updateQuorumNumerator(1000)   [passes under the OLD quorum of supply/1000]

quorum now         : 15,000.000000000000000000 stGOV   == the entire staked supply
delegated votes    : 10,000.000000000000000000 stGOV
=> quorum is unreachable

the undo proposal (updateQuorumNumerator(1)) is itself subject to the new quorum:
  governor.state(id) == Defeated
```

**Stated honestly — the escape, and who owns it.** Governance is not *unconditionally* dead. It
recovers if the passive holder either delegates or exits, which shrinks the gap:

```
passive.delegate(passive)  ->  quorum == total delegated votes   (reachable again)
```

That is asserted in the same test. So the correct claim is: **at numerator 1,000 the DAO's ability
to govern is transferred from the electorate to whichever addresses hold undelegated stake**, and if
any such address is a lost key, a contract that cannot call `delegate`, or simply an unresponsive
holder, governance is permanently dead with no exit. The 100%-turnout requirement also has to hold
on *every* subsequent proposal, forever.

**Fix.** Cap the numerator well below the denominator — e.g. `require(newQuorumNumerator <= 500)` in
an override.
- *Prevents:* the terminal state, and the whole class of "governance votes itself into an
  unreachable quorum".
- *Creates:* a hard ceiling on how conservative the DAO may ever choose to be, chosen by the
  developer rather than by the DAO. That is a genuine loss of sovereignty and the number is a
  business decision, not an audit one. **A cheaper alternative that creates nothing:** leave the
  bound alone and document it, since one proposal at the bound is a deliberate act, not a slip.
- Note the interaction: **any absolute quorum floor proposed for FF-001 or SI-003 must not also be
  raisable to the same trap.** Pricing these two together is the right move, and neither Pass-2
  write-up could see the other.

---

### FI-005 — GOV that lands in the factory is permanently gone, for every launch, forever

**Severity: LOW** · **EXTENDS Pass 1 factory FF-05** (which proved the strand; the *permanence*,
proven at the ABI level rather than per-launch, is new)
**Verification: Method B — `test_F305_govSentToTheFactoryIsPermanentlyUnrecoverable` PASS. Level 4.**

> Q5.5 — *What if this function is called with THE SYSTEM ITSELF as a parameter?*

`_validate` (`:556-563`) requires `deployerRecipient != address(0)` **only when
`deployerStakeBps != 0`**. With `deployerStakeBps == 0` and `deployerRecipient == address(factory)`,
line `:492` resolves `immediateRecipient` to the factory and line `:493` pays it 5% of supply.

**Executed:**

```
GOV permanently stuck inside the factory : 500,000.000000000000000000   (5% of supply)
GOV received by the timelock             : 0
factory.owner()                          -> function does not exist
factory.transfer(...)                    -> function does not exist
factory.rescue(...)                      -> function does not exist
```

**What is new versus FF-05.** FF-05 proved one launch can strand value. The census proves the
*permanence* structurally: `CoinDAOFactory`'s complete mutating ABI is
`{deploy, deployForExistingCoin, setPendingMonolithBeneficiary, acceptMonolithBeneficiary}`. There
is no owner, no rescue and no token-moving function of any kind — and the factory is **shared across
every launch**, so this is not a per-DAO defect the affected party can be told to avoid; it is a
permanent property of the deployment. Note also that the factory legitimately holds the **entire
10,000,000 GOV supply** in the middle of every launch transaction (`:367` → `:485`), so it is
already an address the design routes value through.

**Fix.** Pass 2 registries SI-009 already proposes rejecting system addresses as `deployerRecipient`
and prices the trade (a guard split across two places drifts). The minimal, self-contained half is
one line in the `pure` `_validate`: `if (params.deployerRecipient == address(this)) revert;`.
- *Prevents:* the one variant that is unrecoverable for everyone rather than self-inflicted by one
  launcher.
- *Creates:* nothing — `_validate` is already `pure` over exactly this parameter and needs no new
  inputs. (The broader "reject any predicted component address" check does need them; that is
  SI-009's call, not this one's.)

---

### FI-006 — unstreamed GOV in `StakingRewards` is a permanent sink, and the comment that justifies the missing recovery hook is scoped to the launch, not to the four-year emission

**Severity: LOW** · **EXTENDS Pass 1 emissions FF-001 / Pass 2 SI-002** (the mechanism is theirs; the
*absence claim about the leftover branch* and the terminal framing are new)
**Verification: Method B — `test_F306_unstreamedGovInStakingRewardsIsAPermanentSink` PASS, with
control `test_F306control_withAStakerFromGenesisOnlyDustIsStranded` PASS. Level 4.**

#### The Feynman question

> Q1.2 — *What happens if I delete `notifyRewardAmount`'s leftover branch? If nothing breaks, it is
> dead code.*

`StakingRewards.notifyRewardAmount` (`:150-165`) has two branches. The `else` branch folds unspent
rewards (`remaining * rewardRate`) into the new rate — the standard Synthetix top-up path. It is
taken iff `block.timestamp < periodFinish`.

**Absence claim, and I asserted it rather than assuming it.** The **only** caller of
`notifyRewardAmount` after launch is `StakingRewardsFunder.fundNextTranche`, because
`setRewardsDistribution` was called at `:486` and the owner renounced at `:488` (I-9). And
`fundNextTranche` reverts unless `block.timestamp >= periodFinish` (`StakingRewardsFunder.sol:73`).
**Therefore the leftover branch is structurally unreachable in this system.** Asserted at L4 after
every tranche:

```solidity
assertEq(sr.rewardRate(), amount / sr.rewardsDuration(), "leftover branch never taken");
```

Consequence: GOV that was notified but never streamed (because `_totalSupply == 0`) is **never
recomputed into a later rate**. It stays in the contract, and the contract has no owner and no
`recoverERC20`.

**Executed — 90-day idle window before the first staker, then all four tranches:**

```
GOV held by StakingRewards after all 4 tranches finished : 6,500,000.000000000000000000
GOV the only staker can ever claim                       : 5,979,109.589041095826272000
GOV PERMANENTLY STRANDED (no owner, no recover)          :   520,890.410958904173728000   (5.2% of supply)
funder GOV balance                                       : 0   (fully drained)
```

**Control — the same machinery with a staker present from block zero:**

```
CONTROL: GOV stranded with no idle window : 71,840,000 wei   (7.2e-11 GOV)
```

The control fixes the check's **resolution**: it measures the idle window, not an accounting
artefact. (It also reproduces Pass 2 R-4's truncation-dust figure to the wei, independently.)

#### Engaging with the comment

Two comments bear on this and both must be answered:

- `StakingRewards.sol:147-149` — *"Rewards notified while `_totalSupply == 0` stream to nobody and
  are permanently locked… **This is accepted by design — the window between tranche funding and the
  first staker is expected to be short.**"* This is an explicit, honest design acceptance and my
  finding does not contradict it. What it does is **price the assumption**: the window is chosen by
  an unprivileged caller (I-18), and it is short only if someone chooses to make it short.
- `StakingRewards.sol:172-173` — *"Synthetix's pause, recoverERC20, and mutable
  `setRewardsDuration` hooks are intentionally omitted **because the launch flow does not depend on
  them**."* This justification is **correctly reasoned about the wrong interval.** It is true of the
  launch flow. `recoverERC20`'s purpose in Synthetix is not the launch — it is the four years
  afterwards, which is exactly when the 520,890 GOV above accumulates and becomes unreachable.

**Fix.** This is genuinely a trade with no free side, and I am not going to pretend otherwise.
- *Restoring `recoverERC20` behind an owner* would recover the sink — but the owner is renounced by
  design (I-9), and keeping an owner alive re-opens `setRewardsDistribution`, which is one of the
  better-built parts of the system (Pass 2 VN-B). **Do not recommend this.**
- *A minimum-`_totalSupply` gate in `fundNextTranche`* is Pass 2 SI-002's proposal and is already
  priced there (it creates a liveness lock needing a time-based escape). It shortens the window; it
  does not recover what is already stranded.
- **What I would actually ship: nothing in the code, and one paragraph in the report.** Extend the
  `:172-173` comment to say the omission is accepted *for the whole four-year emission and not only
  the launch*, and state the measured cost so the client is choosing it knowingly. The defect here
  is a justification narrower than its consequence, and the honest repair is to the justification.

---

### FI-007 — one proposal permanently bricks the 2,800,000 GOV treasury vest

**Severity: LOW** · **EXTENDS Pass 1 governance FF-003** (which found the reachable
`renounceOwnership` on the wrapper; the *treasury* instance and its size are measured here)
**Verification: Method B — `test_F308_oneProposalBricksTheTreasuryVestPermanently` PASS, with an
in-test control. Level 4.**

`CoinDAOVestingWallet` is a bare `VestingWalletUpgradeable` wrapper (10 lines, no overrides), so it
inherits `renounceOwnership`. `treasuryVesting`'s owner is the timelock (`:463`), so one passed
proposal reaches it. `VestingWallet.release(token)` pays `owner()`; at `address(0)` the ERC-20
transfer reverts.

```
CONTROL: before the renounce, a bystander calls release(GOV) -> the timelock is paid
one proposal -> treasuryVesting.renounceOwnership()   ->  owner() == 0x0
one year later, release(GOV) from anyone              ->  REVERTS
GOV permanently bricked in the treasury vest          :  2,100,000.000000000000000000
```

Pass 1 FF-003 and Pass 2 registries SI-001 both reached the wrapper from the *monolith* wallet
(200,000 GOV). The **treasury** wallet holds 28% of supply and is reachable by the same one action.

**Fix.** Pass 2 registries §9 already flags that `CoinDAOVestingWallet`'s override surface should be
closed as **one decision** rather than three findings, and I agree — this is a third data point for
that decision, not a fourth separate patch. If the decision is to override, `renounceOwnership()`
reverting is the minimal form. *Creates:* the loss of an option nobody has articulated a use for;
the owners here are a timelock and a handshake-verified beneficiary, not keys that can be lost.

---

### FI-008 — the launch-time admin renounce is what makes five later governance settings terminal

**Severity: INFO** · **NEW as a composition; both halves are known**
**Verification: Method A — line trace + explicit negative greps (level 2), plus the L4 assertions in
`test_F307…` and `test_F302…`.**

`CoinDAOFactory.sol:430` renounces `DEFAULT_ADMIN_ROLE`, and its comment says so plainly
(*"permanently removing the factory as timelock admin"*). Considered alone it is correct: leaving a
factory permanently able to grant roles on every DAO it ever created would be far worse.

Its consequence, which no comment anywhere engages with, is that **there is no admin outside the
timelock**, so each of the following becomes terminal rather than recoverable:

| setting | one action away | why terminal |
|---|---|---|
| `timelock.revokeRole(PROPOSER_ROLE, governor)` | 1 proposal | Pass 2 SI-001e; escalated by FI-002 |
| `timelock.updateDelay(huge)` | 1 proposal | `schedule` then reverts (`block.timestamp + delay` overflows), so the undo cannot be scheduled |
| `governor.setProposalThreshold(huge)` | 1 proposal | nobody can propose the undo |
| `governor.updateQuorumNumerator(1000)` | 1 proposal | FI-004 |
| `governor.updateTimelock(...)` | 1 proposal | Pass 2 SI-001; FI-001/FI-002 |

**Explicit negative grep:** none of `updateTimelock`, `updateDelay`, `setProposalThreshold`,
`setVotingDelay`, `setVotingPeriod` appears anywhere in `src/`, `script/` **or `test/`**. The
project has never written a line of code, test or comment about the inherited functions that can end
it. `grantRole` appears exactly twice, both at `:428-429`; `revokeRole` appears **zero** times.

**Fix.** There is no code fix that is not worse than the problem — guarding each setting
individually creates exactly the "three things are broken and you believe you are safe" shape Pass 2
SI-001 warned about for `updateTimelock`. **This belongs in the report as a governance-operations
note, not as a patch:** the inherited `onlyGovernance` surface is part of the deployed system, five
of its members are terminal, and the client should decide deliberately which (if any) to override
as a single decision — the same recommendation Pass 2 made for the vesting wrapper.

---

## 6. Hypotheses tested and REFUTED

Recorded so no later pass re-derives them. **A refutation is a claim too**, so each was checked by
hand or by execution rather than assumed.

| hypothesis | how it was killed | verdict |
|---|---|---|
| An ordering of the launch's three irreversible steps leaves a half-configured system | **Mutation M2** (L4): moving `renounceRole` before the `grantRole` calls makes **12 project tests fail** — every launch reverts. Plus: the launch is one transaction with **zero `try`/`catch` in `src/`**, so any failure rolls all steps back together. | **NOT A FINDING** — the ordering fails safe |
| An unprivileged actor can permanently raise the quorum floor by minting stGOV to an address that can never vote (`depositFor(dead, x)` — the `account` parameter is attacker-chosen and stGOV is non-transferable) | Arithmetic, checked by hand: quorum is `supply/1000`, so blocking a proposal backed by `V` delegated votes needs `X > 999·V` locked GOV that the attacker can never withdraw (`withdrawTo` burns from `msg.sender`, and the stGOV is in the victim's balance). At genesis that is ~9,990,000 GOV — essentially the whole supply. | **NOT A FINDING** — refuted on cost, not on mechanism |
| A third party can burn someone else's `hasCoinDAO[lender]` or `usedDeploymentKeys[key]` (both write-once, never cleared — a griefing DoS would be permanent) | Trace: `deploymentKey` always binds `msg.sender` (`:193-195`); `deployForExistingCoin` requires `msg.sender == lender.operator()` (`:328`); `deploy()` gets a fresh lender from the immutable Monolith factory. Confirms Pass 2 R-5 independently. | **NOT A FINDING** |
| `acceptLenderOperator` is one-shot (as its NatSpec says), so the operator role can never be re-acquired even with an owner | **Executed control inside `test_F303…`** (L4): after a fresh `setPendingOperator(router)`, a proposal calling `acceptLenderOperator()` succeeds. The function is **not** one-shot. This *strengthened* FI-003 rather than killing it — the recovery path exists, which is why destroying it costs something. | **REFUTED — and it made the finding sharper** |
| `RevenueRouter.acceptLenderOperator` being re-callable is itself a risk (a hostile re-nomination could be accepted) | It is `onlyOwner`, i.e. one proposal, and accepting a role the DAO already holds is a no-op. No privilege is gained. | **NOT A FINDING** |
| A vesting wallet's `start`/`duration` can be changed after the fact, or `initialize` re-run | `_disableInitializers()` in the wrapper constructor (`CoinDAOVestingWallet.sol:8`) plus the `initializer` modifier on the clone. ABI shows no setter. | **NOT A FINDING** — confirms the intended one-shot |
| `monolithBeneficiary` could become an address that cannot act, orphaning the 2% permanently | `acceptMonolithBeneficiary` (`:263`) requires the incoming address to transact. Re-confirms Pass 2 registries §6. | **NOT A FINDING** |

---

## 7. Verified negatives (worth stating positively in the report)

- **VN-1 — the launch's irreversible ordering is load-bearing and fails safe.** M2, above. The
  grant-before-renounce order at `:428-430` cannot be got wrong silently.
- **VN-2 — the launch transaction is atomic across every one-way step.** Zero `try`/`catch` in
  `src/`; a failure at any phase reverts the key reservation, the lender flag, the role grants and
  the operator handoff together. The comment at `:348-349` states exactly this and is correct.
- **VN-3 — `setRewardsDistribution` (`:486`) before `renounceOwnership` (`:488`) is the only
  workable order** and reversing it reverts.
- **VN-4 — `stake`/`withdraw` on `StakingRewards` are a genuinely symmetric pair**: same
  permissionlessness, same `updateReward` modifier, same accounting. The census found no asymmetry.
- **VN-5 — the accumulator monotonicity (I-20, I-21) is correct**, not a defect: an accumulator that
  only rises is the right shape for `rewardPerTokenStored`.

---

## 8. Coverage and honesty statement

- **One-way transitions enumerated:** **30** (I-1 … I-30), across all 12 files in `src/`, covering
  immutables (7), consumed initializers (6), renounced/handed-away authority (7), monotonic
  counters and write-once mappings (7), effectively-one-way governance settings (5), and permanent
  value sinks (4). Every write to every storage variable in `src/` was classified.
- **Of the 30: 11 are deliberate and a comment says so** (I-1, I-2, I-5, I-8, I-9, I-10, I-11, and
  the four accumulators). Each finding above engages with the relevant comment rather than ignoring
  it — twice concluding the comment is **right about what it claims and silent about a second
  consequence** (FI-001, FI-006).
- **New findings: 8** — 2 MEDIUM (FI-001, FI-002), 5 LOW (FI-003 … FI-007), 1 INFO (FI-008).
  0 CRITICAL, 0 HIGH.
- **Findings that are re-derivations of Pass 1 / Pass 2 work: 0.** Every prior-owned transition
  appears in the census with a citation and is not re-graded.
- **This pass corrects one prior recommendation:** Pass 2 SI-001's Option A ("document the batched
  migration procedure") is **not writable as stated** — see FI-001.
- **Hypotheses refuted: 7**, one of which (`acceptLenderOperator` is one-shot) improved a finding
  instead of killing it.
- **Verification levels:** **L4** (executed in a real EVM) for FI-001, FI-002, FI-003, FI-004,
  FI-005, FI-006, FI-007 and both mutations. **L2 with exhaustive line trace + explicit negative
  greps** for FI-008 and for every absence claim in §2.
- **Controls included, so the checks could have failed** (L3): `test_F301control` (governance is
  alive after the migration), the in-test recovery control in `test_F302` (T_old is drainable before
  the revoke), the re-acceptance control in `test_F303`, `test_F306control` (dust-only with no idle
  window), and the release control in `test_F308`.
- **Fix resolution measured, not asserted:** mutation **M1** (add `setTreasury`) — **55/55 project
  tests still pass** and the finding closes. Mutation **M2** (reorder Phase 3) — **12 project tests
  fail**, proving the shipped order is load-bearing.
- **Nothing in this pass is "not proven by execution"** except FI-008 and the §2 absence claims,
  which are statements about the code's shape with no runtime behaviour to execute; verified by
  explicit negative greps and the compiled ABI instead, reason recorded.
- **Absence claims, each checked by explicit grep or the compiled ABI:** `setTreasury`/`setLender`/
  `setGovStaking`/`setCoin`/`setRewardsDuration` — **0 hits**; `recover`/`rescue`/`sweep`/
  `emergency` — **0 function definitions**; `delete`/`.pop()` — **0 hits**; `try`/`catch` — **0
  hits**; `pause`/`upgradeTo`/`UUPS` — **0 hits**; `renounce` — exactly 2 (`:430`, `:488`);
  `grantRole` — exactly 2 (`:428-429`); `revokeRole` — **0**; `transferOwnership` in `src/` —
  exactly 1 (`:454`); `updateTimelock`/`updateDelay`/`setProposalThreshold`/`setVotingDelay`/
  `setVotingPeriod` — **0 in `src/`, `script/` and `test/`**.
- **Client code was not modified.** All experiments ran on a disposable copy under the session
  scratchpad. `git status --porcelain [scratch]` and `git diff --stat -- [scratch]` are empty,
  `diff -rq` of `src/` is clean, and the audited tree re-verified **55/55**.

---

## 9. Hand-off

**The single most important line in this pass:** `RevenueRouter.sol:57` — `treasury = treasury_;`
— the one write in `initialize` that names a *mutable* external address and gives it no setter.
`SI-003` is that same shape in `StakedGovToken`. The pattern is now confirmed twice, and both times
the frozen side is a pointer to a contract that the rest of the system can legitimately move.

**For the debrief.** FI-001 and FI-002 should be adjudicated **together with Pass 2 SI-001**, not
beside it: they share a trigger, and FI-001 changes what SI-001's remedy can say. FI-004 should be
adjudicated **together with any absolute-quorum-floor recommendation** arising from FF-001 or
SI-003, because a floor and a ceiling are the same lever.

**Open question this pass could not answer.** Whether the real Monolith lender can ever re-nominate
an operator out of band. If it can, FI-003's recovery path is load-bearing and the SI-005 fix
becomes more urgent; if it cannot, `acceptLenderOperator` is dead code after the launch and should
be deleted rather than guarded. This is the same external unknown Pass 2 recorded, and it is one
question for the client.
