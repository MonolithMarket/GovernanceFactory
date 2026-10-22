# NEMESIS Pass 2 — State Inconsistency Auditor — THE SEAMS BETWEEN CONTRACTS

**Lens:** `.claude/skills/state-inconsistency-auditor/SKILL.md`, Phases 1–8 executed in full.
**Language:** Solidity 0.8.26 / via-ir / optimizer 200 / Foundry / OpenZeppelin v5.

**Scope — deliberately narrow.** State that is coupled **across** contract boundaries, where no
single contract owns the invariant. The three sibling Pass-2 agents each work *inside* one area;
I did not rebuild their within-contract mutation matrices. Every pair below spans at least two
contracts, and at least one of them is a contract another agent owns.

**Enrichment read before starting:** `nemesis-phase0-recon.md`, `feynman-pass1-factory.md`,
`feynman-pass1-revenue.md`, `feynman-pass1-emissions.md`, `feynman-pass1-governance.md` — all four
in full. Where a Pass-1 finding already covers a pair, I cite it and do not re-derive it. Where two
Pass-1 lenses reached conclusions that are individually correct and jointly false, that is written
up as a finding, because that composition is the whole point of this pass.

**Established fact carried in (not re-derived):** the external lender's `pullLocalReserves()` is a
**complete drain** and **early-returns rather than reverting on zero**. §7 records what this closes.

**Not read, per assignment:** `[scratch]`, `engagements/**`. All OpenZeppelin v5
behaviour below was established **by execution or by the compiled ABI**, never by reading the
library.

## Execution environment

Disposable copy of the tree at
`…/[scratch]`. **`[scratch]` was not written to**
(`git status --porcelain [scratch]` → empty; `git diff --stat -- [scratch]` → empty).

| suite | result |
|---|---|
| project baseline in the copy | **55/55 PASS** |
| project baseline + this pass's PoCs | **73/73 PASS** |
| this pass's PoCs (`test/audit/StatePass2Seams.t.sol`, `SeamHelpers.sol`) | **18/18 PASS** |

Verification levels use the workspace scale: **L1** compiles · **L2** a check passes · **L3** the
check could have failed (a control case is included) · **L4** executed in a real EVM.

### Harness defect found and worked around (recorded because it invalidates naive block tests)

`forge 1.5.1-stable` **caches `NUMBER` and `TIMESTAMP` in the test frame after the first
`vm.roll`/`vm.warp`**, so `block.number` goes stale and the idiom `vm.roll(block.number + 1)`
becomes a **silent no-op** from the second call onward. Control probe (L4):

```
a 1        <- start
vm.roll(block.number + 1)  ->  b 2   <- works
vm.roll(block.number + 1)  ->  c 2   <- NO-OP
vm.roll(block.number + 1)  ->  d 2   <- NO-OP
```

My first PoC run produced three false failures because of this. Every roll/warp in this pass
therefore goes through `vm.getBlockNumber()` / `vm.getBlockTimestamp()`.

**Checked against the client's own suite (L4).** Their governance tests overwhelmingly use
*absolute* targets read from the contracts (`governor.clock() + 1`, `proposalSnapshot + 1`,
`proposalDeadline + 1`), which are immune. Two sites use the vulnerable idiom
(`test/CoinDAOGovernor.t.sol:89`, `test/StakedGovToken.t.sol:39,45`). I patched both to the safe
form and re-ran: **4/4 and 14/14 still pass.** So there is **no false green** in the delivered
suite today. Reported as INFO (SI-008) because it is a live trap for any test they add next.

---

# 1. Phase 1 — Coupled State Dependency Map (cross-contract only)

The column that matters is the last one: *which contract is responsible for keeping the pair
consistent?* Where the answer is **NONE**, that is a finding or a stated design assumption.

```
+=========================================================================================+
| #   | COUPLED PAIR (spans >= 2 contracts)                       | INVARIANT | OWNED BY? |
+=========================================================================================+

SEAM 1 — VOTING WEIGHT IS CHECKPOINTED IN ONE CONTRACT AND CONSUMED IN ANOTHER

P1  StakedGovToken._totalCheckpoints  <->  CoinDAOGovernor.quorum(t)
    Invariant: the quorum base is the staked supply at the snapshot block.
    Mutation points (A): depositFor, withdrawTo, withdraw, harvestAndWithdraw  [permissionless]
    Mutation points (B): none - quorum is derived, never stored
    OWNER: nobody. quorum tracks A with no floor, no cap and no absolute minimum.
           -> FF-001 (governance + factory lenses, HIGH). Extended here by SI-003.

P2  StakedGovToken._delegateCheckpoints  <->  Governor._proposalVotes[id]
    Invariant: forVotes at the snapshot reflect delegated stake at the snapshot.
    OWNER: OZ Votes, correctly. Verified consistent (see §6, VN-A).
           Undelegated stake raises quorum and supplies no votes -> FF-011 (governance, LOW).

P3  Governor._timelock  <->  TimelockController role set {PROPOSER, CANCELLER, EXECUTOR, ADMIN}
    Invariant: the Governor must hold PROPOSER on the timelock it points at.
    Mutation points (A): Governor.updateTimelock          [onlyGovernance, 1 proposal]
    Mutation points (B): Timelock.grantRole/revokeRole    [DEFAULT_ADMIN = the timelock itself,
                                                           i.e. 1 proposal]
    OWNER: ***NONE***. Both sides move independently, each in one action, neither reads the
           other, and the factory renounced DEFAULT_ADMIN at launch so no external repair exists.
           -> SI-001 (NEW).

P4  Governor._timelock  <->  RevenueRouter._owner
P5  Governor._timelock  <->  treasuryVesting._owner
P5b Governor._timelock  <->  GOV/ETH balance held by the timelock
    Invariant: the address the Governor executes through is the address that owns the router,
               owns the treasury vest, and holds the treasury.
    Mutation points (A): Governor.updateTimelock                    [1 proposal]
    Mutation points (B): Ownable.transferOwnership on each          [1 proposal EACH]
    Mutation points (C): a GOV transfer out of the timelock         [1 proposal]
    OWNER: ***NONE***. A is a single inherited call that silently invalidates B and C.
           -> SI-001 (NEW).

P6  Governor._timelockIds[id]  <->  TimelockController._timestamps[opId]
    Invariant: the Governor's view of a queued operation matches the timelock's.
    OWNER: GovernorTimelockControl.state(), which re-reads the timelock - correct while
           `_timelock` is stable. Breaks the moment P3/P4 break -> SI-001b (NEW).
           Direct execution on the open EXECUTOR role reconciles correctly (VN-D).

SEAM 2 — rewardsDistribution <-> THE FUNDER'S IDENTITY <-> THE PHASE-7 RENOUNCE

P7  StakingRewards.rewardsDistribution  <->  StakingRewardsFunder identity
                                        <->  StakingRewards._owner
    Invariant: rewardsDistribution == the funder, forever.
    Mutation points: setRewardsDistribution [onlyOwner] - and owner is renounced at
                     CoinDAOFactory.sol:488, in the same transaction that sets it.
    OWNER: the factory, once, atomically. Frozen thereafter and self-enforcing (the funder
           re-checks the identity at StakingRewardsFunder.sol:249). CONSISTENT - see VN-B.

P8  StakingRewards.{rewardRate, periodFinish, lastUpdateTime}   <->   StakingRewards._totalSupply
    Invariant (implied by the design, stated at StakingRewards.sol:147-149): the emission clock
               is opened when a staker base can exist.
    Mutation points (A): notifyRewardAmount, called by the FACTORY's fundNextTranche at L487
    Mutation points (B): stake/withdraw, callable by ANYONE, at an address that
                         predictCoinDAOAddresses publishes in advance
    OWNER: ***NONE***. The factory writes one side inside its own transaction; the other side is
           writable by an arbitrary party in that same transaction.
           -> SI-002 (NEW). FF-002 (factory) and FF-001/FF-003 (emissions) each saw one half.

P9  StakingRewardsFunder.totalRewards  <->  funder GOV balance  <->  allocation.coinStakingRewards
    Invariant: totalRewards == GOV delivered.
    OWNER: the factory, by construction (L448 sets it, L485 delivers the same number).
           Tranche 3 sweeps the live balance, absorbing any donation or mismatch silently.
           CONSISTENT on every factory path - VN-B. Assumption A3 (emissions) stands.

SEAM 3 — A ROLE LIVES IN AN EXTERNAL CONTRACT WHILE TWO OF OURS CACHE ASSUMPTIONS ABOUT IT

P10 RevenueRouter.lender  <->  lender.operator  <->  CoinDAOFactory.hasCoinDAO[lender]
    Invariant: the router IS the lender's operator, and the factory records that fact.
    Mutation points (A): none - RevenueRouter.lender has no setter (ABI-verified)
    Mutation points (B): external, outside this repository
    Mutation points (C): hasCoinDAO is write-once `= true`, never cleared (grep: no `delete`)
    OWNER: ***NONE***. Three caches of one external fact; the factory never reads the role back
           (FF-03, factory lens); the router cannot re-nominate; hasCoinDAO blocks a retry.
           -> FF-03 (factory, MEDIUM lead) + SI-003 (NEW, the ratchet consequence).

P11 RevenueRouter._owner  <->  lender.manager
    Invariant: governance can still rotate the external manager.
    Mutation points: renounceOwnership() [reachable by the timelock, i.e. 1 proposal]
    OWNER: ***NONE***. After a renounce the router permanently holds `operator` with no
           controls at all. -> SI-005 (NEW, LOW; sharpens FF-010 revenue and the governance
           lens's own REFUTATION of "the manager is permanently an EOA", which is conditional).

P12 StakedGovToken.revenueRouter  <->  RevenueRouter.govStaking   (the back-link)
P13 RevenueRouter.coin  <->  lender.coin()  <->  StakedGovToken.rewardsToken
    Invariant: each names the other / the same asset.
    Mutation points: NONE on either side. Neither initialize validates the cross-reference.
    OWNER: the factory, once, unverified. -> FF-017 (revenue, MEDIUM). Not re-derived.
           StakedGovToken has NO OWNER AT ALL (ABI-verified) - so a wrong value is unrepairable
           by any party including governance. This is the load-bearing half of SI-003.

SEAM 4 — FIXED SUPPLY <-> FIVE DESTINATIONS <-> WHAT EACH CAN ACTUALLY PAY OUT

P14 GOV_TOKEN_SUPPLY  <->  sum(5 allocations)  <->  payout capability of each destination
    Invariant (arithmetic): the five parts sum to 10,000,000e18 exactly.
    Invariant (economic, unstated): each destination can deliver what it holds.
    OWNER of the arithmetic: allocationFor(), by computing the treasury share by subtraction.
           CONSISTENT - re-measured at L4 across contracts (VN-C).
    OWNER of the payout property: ***NONE***. Measured in §5.

SEAM 5 — VESTING OWNERSHIP <-> monolithBeneficiary <-> PER-DEPLOYMENT RECORDS

P15 CoinDAOFactory.monolithBeneficiary  <->  deployments[i].monolithVesting._owner
    Invariant: none is stated. The factory lens graded this SOUND ("snapshot semantics"); the
               governance lens graded it a coupling that "nothing detects". Adjudicated in SI-004.
    Mutation points (A): acceptMonolithBeneficiary [the pending beneficiary, any time]
    Mutation points (B): VestingWallet.transferOwnership [the OLD beneficiary, per wallet]
    OWNER: ***NONE***, but the asymmetry is deliberate and the repair exists. -> SI-004 (LOW).

P16 CoinDAOFactory.deployments[i]  <->  the live state of the 14 addresses it records
    Invariant: the registry describes the system.
    Mutation points: deployments[] is push-only (grep: no `delete`, no `.pop()`); every recorded
                     component can change underneath it.
    OWNER: ***NONE***. `.timelock` is the field that actually goes stale -> SI-001 consequence 3.

P17 usedDeploymentKeys <-> deploymentKeyForId <-> deployments <-> hasCoinDAO   (recon pair #9)
    OWNER: the factory, atomically. CONSISTENT - VN-E. Cannot drift; every write path is in one
           transaction and every failure rolls all four back together.
```

---

# 2. Phase 2 — Cross-contract Mutation Matrix

Only mutations whose **effect crosses a contract boundary** are listed. `???` marks the entries I
took as primary targets; each row's resolution is in the Verdict column.

| State (contract) | Mutating call (contract) | Type | Does it update the coupled counterpart? | Verdict |
|---|---|---|---|---|
| `stGOV._totalCheckpoints` | `depositFor` (stGOV) | increment | Governor quorum is derived on read | consistent |
| `stGOV._totalCheckpoints` | `withdrawTo` / `withdraw` / `harvestAndWithdraw` (stGOV) | decrement | quorum falls with it, no floor | **SI-003** |
| `Governor._timelock` | `updateTimelock` (Governor, inherited) | full replace | `RevenueRouter._owner` ??? | **SI-001 — NO** |
| `Governor._timelock` | `updateTimelock` | full replace | `treasuryVesting._owner` ??? | **SI-001 — NO** |
| `Governor._timelock` | `updateTimelock` | full replace | timelock GOV balance ??? | **SI-001 — NO** |
| `Governor._timelock` | `updateTimelock` | full replace | new timelock's `PROPOSER_ROLE` ??? | **SI-001 — NO** |
| `Governor._timelock` | `updateTimelock` | full replace | `_timelockIds[id]` of live proposals ??? | **SI-001b — NO** |
| `Governor._timelock` | `updateTimelock` | full replace | `factory.deployments[i].timelock` ??? | **SI-001 — NO** |
| `Timelock.PROPOSER_ROLE[gov]` | `revokeRole` / `renounceRole` (Timelock, via proposal) | delete | `Governor._timelock` ??? | **SI-001e — NO** |
| `Timelock._timestamps[opId]` | `executeBatch` by a bystander (open EXECUTOR) | set DONE | `Governor._proposals[id].executed` ??? | **consistent** — `state()` re-reads the timelock (VN-D) |
| `StakingRewards.rewardRate` | `notifyRewardAmount` ← `fundNextTranche` ← **factory L487** | full replace | `_totalSupply` ??? | **SI-002 — NO** |
| `StakingRewards._totalSupply` | `stake` (anyone, at a *published* predicted address) | increment | `rewardRate` ??? | **SI-002 — NO** |
| `StakingRewards.rewardsDistribution` | `setRewardsDistribution` (factory L486) | full replace | `owner` renounced at L488 | consistent, frozen |
| `Funder.nextTranche` | `fundNextTranche` (anyone) | increment | `SR.periodFinish` — same predicate both sides | consistent (VN-B) |
| `Funder` GOV balance | `fundNextTranche` | decrement | `SR` GOV balance | conserved (VN-B) |
| `lender.operator` | `acceptOperator` ← `RevenueRouter` (factory L453) | full replace | never read back by anyone | **FF-03** (factory lens) |
| `RevenueRouter._owner` | `renounceOwnership` (timelock) | delete | `lender.manager` becomes unreachable | **SI-005** |
| `factory.monolithBeneficiary` | `acceptMonolithBeneficiary` | full replace | past `monolithVesting._owner` ??? | **SI-004 — NO (by design)** |
| `factory.monolithBeneficiary` | (read at L470, Phase 6) | read | mutable by a callee of the L452 external call | **SI-006** |
| `factory.deployments[]` | `push` (Phase 8) | append | `deploymentKeyForId[]`, `hasCoinDAO`, `usedDeploymentKeys` | consistent (VN-E) |
| GOV balance of each of 5 destinations | 5 `safeTransfer` (Phase 7) | set | sum == `GOV_TOKEN_SUPPLY` | conserved (VN-C) |

---

# 3. Phase 5 — Parallel Path Comparison (cross-contract)

**A. Entry vs exit on the vote token.** The asymmetry is the mechanism behind SI-003.

| coupled state | `depositFor` (entry) | `withdrawTo` / `withdraw` (exit) |
|---|---|---|
| `stGOV` balance / totalSupply | ✓ mint | ✓ burn |
| Votes checkpoints | ✓ | ✓ |
| reward settlement (`updateReward`) | ✓ | ✓ |
| **harvest of external revenue** | ✓ **required** | ✗ **deliberately absent** |
| **depends on the external lender being alive** | ✓ **YES** | ✗ **NO** |
| Governor quorum base | ✓ raises | ✓ lowers |

The last two rows together are the finding: **entry is gated on an external contract, exit is
not.** The set of vote holders can therefore only shrink once that external path breaks, and the
quorum denominator shrinks with it.

**B. Timelock migration — the four things a migration must move.**

| what must move | `updateTimelock` alone | correctly batched proposal (SI-001d) |
|---|---|---|
| `Governor._timelock` | ✓ | ✓ |
| `RevenueRouter._owner` | ✗ | ✓ |
| `treasuryVesting._owner` | ✗ | ✓ |
| assets held by the timelock | ✗ | ✓ |
| `PROPOSER_ROLE` on the destination | ✗ | ✓ (constructed with it) |
| live queued proposals | ✗ (become ghosts) | must be drained first |

Both were executed. The safe form works; **nothing in any contract requires it.**

**C. The two launch entry points, at the moment the emission clock starts (L487).**

| property at L487 | `deploy()` | `deployForExistingCoin()` |
|---|---|---|
| staking token created in this tx | yes | **no — it pre-exists** |
| staking token total supply | provably **0** | **arbitrary; the caller may hold it** |
| caller can hold the staking token | no | **yes** |
| `StakingRewards` clone address knowable in advance | yes (`predictCoinDAOAddresses`) | yes |
| result of `fundNextTranche()` at L487 | emissions **burn** | emissions **are captured** |

The factory lens graded this row for `deploy()` and was right. The emissions lens graded the
mechanism and was right. **Their composition is false on the second column.** → SI-002.

---

# 4. Phase 8 — Verification Summary

| ID | Coupled pair | Breaking operation | Method | Verdict | Severity |
|---|---|---|---|---|---|
| **SI-001** | `Governor._timelock` ↔ router owner ↔ vest owner ↔ timelock role set ↔ registry | `Governor.updateTimelock` (inherited, `onlyGovernance`) | B — PoC ×3 + control ×2, L4 | TRUE POSITIVE | **MEDIUM** |
| **SI-001b** | `Governor._timelockIds[id]` ↔ `Timelock._timestamps[opId]` | same | B — PoC + control, L4 | TRUE POSITIVE | **MEDIUM** (consequence of SI-001) |
| **SI-002** | `StakingRewards.rewardRate` ↔ `_totalSupply` across the factory boundary | `fundNextTranche()` at `CoinDAOFactory.sol:487` on the `deployForExistingCoin` path | B — PoC ×2 + control, L4 | TRUE POSITIVE | **HIGH by composition / MEDIUM standalone** |
| **SI-003** | `stGOV.revenueRouter` ↔ `RevenueRouter.lender` ↔ `lender.operator`, and the quorum base | any break in `distribute()` | C — trace + PoC, L4 (trigger substituted) | TRUE POSITIVE, **trigger external** | **MEDIUM (lead)** |
| **SI-004** | `factory.monolithBeneficiary` ↔ per-deployment `monolithVesting._owner` | `acceptMonolithBeneficiary` | B — PoC, L4 | TRUE POSITIVE, **designed asymmetry** | **LOW** |
| **SI-005** | `RevenueRouter._owner` ↔ `lender.manager` | `renounceOwnership()` | B — PoC, L4 | TRUE POSITIVE | **LOW** |
| **SI-006** | `factory.monolithBeneficiary` read in Phase 6 ↔ the Phase-5 external call | reentrancy at `CoinDAOFactory.sol:452` | A — line trace, L2 + explicit negative grep | TRUE POSITIVE (structural) | **LOW / INFO** |
| **SI-007** | `factory.deployments[i]` ↔ live component state | any component-level ownership change | A — trace + L4 assertion inside SI-001 | TRUE POSITIVE | **INFO** |
| **SI-008** | (harness) `vm.roll(block.number + N)` is a no-op after the first roll | forge 1.5.1 | B — control probe + client-suite re-run, L4 | TRUE POSITIVE, **no false green today** | **INFO** |

Five hypotheses were tested and **REFUTED** (§6). Two Pass-1 HIGH leads are **closed** by the
established `pullLocalReserves()` fact (§7).

---

# 5. Findings

---

## SI-001 — `updateTimelock` moves one of five things that name the timelock, and the other four are orphaned irreversibly

**Severity: MEDIUM** · Modules `CoinDAOGovernor` (inherited `GovernorTimelockControl`),
`RevenueRouter`, `CoinDAOVestingWallet`, `TimelockController`, `CoinDAOFactory`
**Verification: Method B — `test_SI001_updateTimelockOrphansEveryDownstreamOwnership`,
`test_SI001b_ghostProposalExecutesWhileGovernorReportsCanceled`,
`test_SI001e_revokingProposerFromTheOtherSideIsEquallyUnguarded`, with two controls
(`test_SI001c`, `test_SI001d`). All PASS. Level 4.**

### The coupled pair

```
Governor._timelock  ==  T
   |
   +--> T holds DEFAULT_ADMIN_ROLE over itself, PROPOSER+CANCELLER granted to the Governor,
   |    EXECUTOR granted to address(0) (open to everyone)     [CoinDAOFactory.sol:428-430]
   +--> RevenueRouter._owner == T                             [CoinDAOFactory.sol:454]
   +--> treasuryVesting._owner == T                           [CoinDAOFactory.sol:463]
   +--> T holds the released treasury GOV and any other DAO asset
   +--> deployments[i].timelock == T                          [CoinDAOFactory.sol:502]
```

**Invariant:** the address the Governor executes through must be the address that owns the router,
owns the treasury vest, holds the treasury, and grants the Governor `PROPOSER_ROLE`.

### The breaking operation

`CoinDAOGovernor` inherits `GovernorTimelockControl.updateTimelock(TimelockController)`. It is
**`onlyGovernance`**, present in the compiled ABI (verified by `forge inspect CoinDAOGovernor abi`
— the non-view surface is `cancel, castVote…, execute, propose, queue, relay, setProposalThreshold,
setVotingDelay, setVotingPeriod, updateQuorumNumerator, updateTimelock`), and **the wrapper
overrides nothing around it.** Explicit negative grep: `updateTimelock` appears **zero times** in
`src/` and `script/` — the project has never engaged with it in code, test, or comment.

It writes exactly one storage slot. It does not, and cannot, move the other four bindings.

### Engaging with the comment that exists

OpenZeppelin's own NatSpec on `updateTimelock` carries a CAUTION — but only about *queued
proposals*. It says nothing about downstream contracts that were made to point at the old timelock
by a third party, which is precisely what `CoinDAOFactory` Phase 3/5/6 does three times. The
existing warning is correct and insufficient for this system.

### Executed evidence

```
before: router.owner == treasuryVesting.owner == governor.timelock() == T_old
one proposal: governor.updateTimelock(T_new)         <- passes, executes, no revert
after:  governor.timelock()            == T_new
        router.owner()                 == T_old      <- ORPHANED
        treasuryVesting.owner()         == T_old      <- ORPHANED
        T_old.hasRole(PROPOSER, gov)    == true       <- old still trusts a Governor that left
        T_new.hasRole(PROPOSER, gov)    == false      <- new does not trust it
        factory.deployments(0).timelock == T_old      <- registry now lies

GOV now sitting in the orphaned timelock:    560,195.712383126766688410
GOV still to be paid into it (vest balance): 1,668,375.716188301804740162
GOV permanently unspendable:                 2,228,571.428571428571428572   (28% of supply)

a follow-up proposal to reclaim the router:  gov.queue(...) REVERTS
                                             (AccessControlUnauthorizedAccount: no PROPOSER on T_new)
```

Note the second line: `treasuryVesting.release(GOV)` stays **permissionless** and keeps paying
`owner()`, which is still the dead timelock. **The vesting stream continues to pour value into an
address from which nothing can ever move.** Anyone can keep it flowing; nobody can stop it.

### The same break from the other side (`test_SI001e`, PASS)

One proposal executing `timelock.revokeRole(PROPOSER_ROLE, governor)` — a plausible-looking
housekeeping action — produces the mirror state: `Governor._timelock` still names the timelock,
the timelock no longer accepts the Governor, and **no admin exists outside the timelock** because
`CoinDAOFactory.sol:430` renounced `DEFAULT_ADMIN_ROLE` at launch. Asserted at L4:
`hasRole(DEFAULT_ADMIN_ROLE, factory) == false`, `hasRole(DEFAULT_ADMIN_ROLE, timelock) == true`
— and the timelock is now unreachable. Governance is permanently dead.

Explicit negative grep, run because absence claims are the dangerous ones: **`revokeRole` appears
zero times in `src/`**, and `grantRole` appears exactly twice (`CoinDAOFactory.sol:428-429`). There
is no code anywhere in the system that re-establishes a role relationship.

### Consequence 3 — the registry

`deployments[i].timelock` is push-only and never updated (grep: no `delete`, no `.pop()` anywhere
in the factory). After a migration the factory — the address integrators and the deploy script
trust as the source of truth — reports the orphaned timelock forever.

### What makes this a state-inconsistency finding rather than "governance can harm itself"

Three things:

1. **The operation looks complete.** `updateTimelock` is the framework's designated migration
   primitive. An operator who executes it has done the documented thing.
2. **No contract checks the other side.** Not the Governor, not the router, not the vesting
   wallet, not the factory. `RevenueRouter` has no `owner()`-vs-`governor.timelock()` assertion; it
   cannot, because it does not know the Governor exists.
3. **It is irreversible.** Every repair path runs through the timelock that just became
   unreachable.

**Honest limit on reachability.** This requires a passed proposal. Under a healthy DAO that means
a mistake, not an attack. Under **FF-001** (governance + factory lenses, HIGH — quorum can never
exceed the proposal threshold, so 0.1% of supply captures governance), "requires a passed proposal"
is a weak barrier, and a deliberate `updateTimelock` becomes an available *denial* action that
destroys 28% of supply without the attacker having to hold it. I have graded on the mistake case.

### The safe form exists — proven (`test_SI001d`, PASS)

A single batched proposal that (1) constructs the destination timelock **with the Governor already
in `proposers`**, then in one batch (2) `revenueRouter.transferOwnership(T_new)`,
(3) `treasuryVesting.transferOwnership(T_new)`, (4) `GOV.transfer(T_new, balance)`, and only then
(5) `governor.updateTimelock(T_new)` — leaves every binding consistent, and a follow-up proposal
executes normally (`setGovStakingBps(5_000)` succeeded end to end).

### Fix — both failure modes priced

*Option A (documentation only).* Record the batched migration procedure above as the only
supported way to change the timelock, and add the drain-the-queue precondition.
- *Prevents:* the whole finding, at zero code risk.
- *Creates:* nothing on-chain; it relies entirely on operator discipline, and the tree contains
  no production runbook at all (FF-013, governance lens).

*Option B (code).* Override `updateTimelock` in `CoinDAOGovernor` to revert unless the destination
already grants `PROPOSER_ROLE` to `address(this)`.
- *Prevents:* the single most damaging half — the Governor stranding itself with no proposer.
- *Creates:* a **new bricking mode**. If the destination timelock is misconfigured in some other
  way, or if `hasRole` is ever unavailable, the DAO now cannot migrate at all; and the check does
  **not** cover the router, the vest, the assets, or the queued proposals, so it converts "four
  things are broken" into "three things are broken and you believe you are safe." **That is worse
  than the current state for an operator who trusts the guard.** Do not ship B alone.

*Option C.* Emit a `TimelockMigrated(old, new)` event from the override and leave the semantics
alone, so indexers and the factory registry can be reconciled off-chain.
- *Prevents:* the silent-registry half only. *Creates:* nothing.

**Recommendation: A + C. Explicitly not B on its own.**

---

## SI-001b — a proposal the Governor reports as `Canceled` remains executable by any bystander

**Severity: MEDIUM** (consequence of SI-001; recorded separately because the failure mode is
different in kind) · **Verification: Method B — `test_SI001b…` PASS, control `test_SI001c…` PASS.
Level 4.**

**Coupled pair:** `Governor._timelockIds[proposalId]` ↔ `TimelockController._timestamps[opId]`.

`GovernorTimelockControl.state()` resolves a `Queued` proposal by asking **the timelock the
Governor currently points at**. After `updateTimelock`, proposals queued on the *old* timelock are
looked up on the *new* one, where they are neither pending nor done — so the Governor returns
**`ProposalState.Canceled`**. The operation on the old timelock is untouched, still `Ready`, and
the old timelock's `EXECUTOR_ROLE` is held by `address(0)` — **open to everyone**
(`CoinDAOFactory.sol:374` passes `executors = [address(0)]`; asserted at L4).

**Executed:**

```
A queued on T_old  ->  governor.state(A) == Queued        (control: stays Queued, then Executed)
B executes updateTimelock(T_new)
                   ->  governor.state(A) == Canceled      <- the Governor says it is dead
                       T_old.isOperationReady(opId(A)) == true
                       T_old.hasRole(EXECUTOR_ROLE, address(0)) == true
a random address 0xD00D calls T_old.executeBatch(A...)
                   ->  router.govStakingBps: 10000 -> 1234   <- IT EXECUTED
                   ->  governor.state(A) STILL == Canceled
```

**Consequence.** Every front end, indexer, and human reading `governor.state()` is told the
proposal is cancelled. It is not. It executes against every contract the old timelock still owns —
which, per SI-001, is the RevenueRouter, the treasury vest, and the treasury balance. Nobody can
cancel it: `Governor._cancel` now routes `timelock.cancel` to the **new** timelock, and reaching
the old one needs `relay`, which needs a proposal, which needs `PROPOSER_ROLE` on the new
timelock. This is a state desync that *reads as safety* — the worst shape.

**Masking pattern (SKILL Phase 7, pattern 6 — fallback to default).** `state()`'s `else` branch
treats "the timelock I am asking does not know this operation" as `Canceled`. In OZ's intended
usage that branch means "cancelled directly on the timelock", which is correct. Here the same
default silently absorbs "I am asking the wrong timelock."

**Fix.** Covered by SI-001's Option A: drain the queue before migrating. A code-level guard would
have to snapshot per-proposal which timelock scheduled it, which is a change to OZ's storage shape
and is not worth it — the procedural fix is the right one, and it must be written down.

---

## SI-002 — the launch transaction opens the emission clock against a staking token that already has holders, and the launcher can be the sole staker inside that same transaction

**Severity: HIGH by composition, MEDIUM standalone** · Modules `CoinDAOFactory` (L487, the
`deployForExistingCoin` path) + `StakingRewards` + `StakingRewardsFunder`
**Verification: Method B — `test_SI002_existingMarketLaunchLetsTheLauncherTakeTheWholeFirstTranche`,
`test_SI002b_soleStakerClearsTheProposalThresholdInUnderTwoDays`, control
`test_SI002_controlIdleWindowDestroysTheSameGov`. All PASS. Level 4.**

### Why neither Pass-1 lens could reach this

- **Factory lens, FF-02:** *"On the `deploy()` path the staking token (Coin or sCoin) is created
  in the same transaction, so its total supply at the moment the clock starts is provably zero:
  nobody in the world can stake."* Correct — and explicitly scoped to `deploy()`.
- **Emissions lens, FF-001 / A1:** *"the caller (`CoinDAOFactory.sol:487`) opens it at genesis"*,
  graded as a **burn**, on the premise that no staker can exist.
- **Emissions lens, FF-003:** the atomic open-and-take pattern, but reasoned about the
  *permissionless* `fundNextTranche()` — i.e. tranches 2–4.

On `deployForExistingCoin` **the staking token pre-exists with a live supply**, so the premise both
lenses relied on is false, and the burn becomes a capture. Each conclusion is right about its own
contract; their composition is wrong.

### The coupled pair and the breaking operation

`StakingRewards.rewardRate / periodFinish / lastUpdateTime` ↔ `StakingRewards._totalSupply`.

- **Side A** is written by `CoinDAOFactory.sol:487` → `Funder.fundNextTranche()` →
  `StakingRewards.notifyRewardAmount()`, inside the launch transaction, and then made permanent by
  `renounceOwnership()` at L488.
- **Side B** is written by `StakingRewards.stake()`, which is **permissionless**, at an address
  that `CoinDAOFactory.predictCoinDAOAddresses()` **publishes in advance**.
- **Nothing reconciles them.** `notifyRewardAmount` never reads `_totalSupply` for a gate;
  `stake` never reads `rewardRate`. There is no minimum-TVL check anywhere.

### Executed evidence

Attacker = the lender's incumbent operator, implemented as a contract so the launch and the stake
are **one transaction**:

```solidity
lender.setPendingOperator(address(factory));
d = factory.deployForExistingCoin(salt, params, lender);   // Phase 7 starts the emission clock
IERC20(d.stakingToken).approve(d.coinStakingRewards, ~0);
StakingRewards(d.coinStakingRewards).stake(1);             // 1 WEI, same transaction
```

```
staking token total supply at launch      : > 0        <- the premise both lenses relied on is FALSE
StakingRewards.totalSupply() after launch : 1          <- sole staker, inside the launch tx
tranche 1 size                            : 2,112,500.000000000000000000 GOV
taken by the 1-wei staker after 365 d     : 2,112,499.999999999968768000 GOV   (99.9999999985%)

proposal threshold (GOV_TOKEN_SUPPLY/1000):    10,000.000000000000000000 GOV
GOV after 2 days as the sole staker       :    11,575.342465753424486400 GOV
GOV emitted per idle day                  :     5,787.671232876712243200 GOV
```

**Control (`test_SI002_controlIdleWindowDestroysTheSameGov`, PASS)** — the same launch without the
atomic stake, staking 30 days later instead:

```
GOV destroyed by the 30-day idle window : 173,630.136986301367296000
GOV the late staker still took          : 1,938,869.863013698601472000
                                          --------------------------- sums to tranche 1 exactly
```

The control establishes the check's resolution: the same GOV is either destroyed (idle) or taken
(atomic stake). It is the *same quantity*, and the launcher chooses which.

### Impact

1. **The realistic claim, and the severity driver.** The launcher is **guaranteed** to be the only
   party earning GOV emissions from second zero, because no one else can reach a contract that did
   not exist before their transaction. In **1.73 days** they hold more than
   `GOVERNOR_PROPOSAL_THRESHOLD`. Nobody else can be first. Composed with **FF-001** (quorum =
   staked-stGOV/1000 ≤ proposal threshold, always), the launcher owns the DAO — the Timelock, the
   2,800,000 GOV treasury vest, and `RevenueRouter` ownership — before any community exists.
2. **The maximal claim.** If no second staker ever arrives, the launcher takes the entire
   2,112,500 GOV tranche (21.1% of total supply) for 1 wei of Coin. Later stakers dilute them pro
   rata, so this is an upper bound, not an expectation. **I am not grading on the upper bound.**
3. **It is invisible.** Nothing in the launch events, the `deployments[]` record, or
   `_verifyDeployment` reveals that the launcher took a genesis stake.

### Why HIGH by composition

Standalone, this is the launcher advantaging themselves on their own launch — MEDIUM. Composed
with FF-001, it is the *cheapest and most certain* route to capturing a DAO that is supposed to
belong to its community, and both halves are already-confirmed true positives. **The composition
is the finding, and Pass 2 is where it becomes visible.** Flagged for adjudication with both
decompositions stated so the debrief can grade it on the criteria in `SCOPE.md §10` rather than on
my framing.

### Fix — both failure modes priced

The factory lens already proposed dropping `CoinDAOFactory.sol:487` (mutation M6: only 2 of 19
project tests fail, both merely asserting the tranche was funded). **That fix does not close this
finding** — it hands the same advantage to whoever calls the now-deferred `fundNextTranche()`
first, which the emissions lens measured at 5,787 GOV/day for a 1-wei staker (their
`testDeferredFundingLetsAWhaleOfOneWeiFrontRunTheStart`).

The coupling has to be closed on the side that is actually missing: **a minimum `_totalSupply`
gate**, checked inside `fundNextTranche()` (not inside `notifyRewardAmount` — `StakingRewards.sol`
L149 says so itself, and it is right).

- *Prevents:* a tranche can never be opened against a supply small enough for one party to be the
  whole pool, on any path, at genesis or later.
- *Creates:* a **liveness dependency**. If the market never reaches the threshold, the tranche
  never opens; if `rewardsDuration` has already elapsed the schedule stalls with GOV sitting in a
  funder that has **no owner and no rescue** (ABI-verified: the funder's only outflow is
  `fundNextTranche`). That is a permanent lock, which is worse than the burn it replaces. Any such
  gate therefore needs a **time-based escape** ("minimum TVL *or* N days after the previous
  period finished"), and choosing that threshold is a business decision, not an audit one.
- *Also creates:* a new coupled pair — the threshold constant vs. the market's realistic TVL — that
  is itself unowned. Say so in the report rather than pretending the fix is free.

**Minimum viable mitigation, if the above is too invasive:** on the `deployForExistingCoin` path
only, do not call `fundNextTranche()` at L487. That single change removes the *guaranteed* head
start (the launcher would then have to win a public race), costs nothing on the `deploy()` path,
and does not introduce a liveness gate.

---

## SI-003 — the electorate is a one-way ratchet: entry depends on an external contract, exit does not, and quorum follows the survivors down

**Severity: MEDIUM (lead — the trigger lives outside this repository)** · Modules
`StakedGovToken` + `RevenueRouter` + `CoinDAOGovernor` + the external Lender
**Verification: Method C — trace + `test_SI003_brokenRevenuePathRatchetsTheElectorateDownAndQuorumWithIt`
(PASS, trigger substituted with `vm.mockCallRevert`). Level 4 for the mechanism, level 2 for the
trigger.**

### The chain, and who owns it

```
StakedGovToken.depositFor            <- the ONLY mint path (ABI-verified: no mint, no _recover)
  modifier harvestYield -> revenueRouter.distribute()          [no try/catch, return discarded]
        RevenueRouter.distribute -> lender.pullLocalReserves()  [no try/catch]
                                 -> coin.safeTransfer x2
```

- `StakedGovToken.revenueRouter` — **no setter**; and `StakedGovToken` **has no owner at all**
  (compiled ABI: `approve, delegate, delegateBySig, depositFor, getReward, harvestAndGetReward,
  harvestAndWithdraw, initialize, notifyRewardAmount, permit, transfer, transferFrom, withdraw,
  withdrawTo` — nothing else can change state; no `Ownable` import in the file).
- `RevenueRouter.lender` — **no setter** (FF-017, revenue lens).
- `lender.operator` — external, and the router deliberately cannot re-nominate.

**Who is responsible for keeping this chain alive? NOBODY. And the one contract that would need a
setter is the one with no owner.**

### What is new here (the part no Pass-1 lens stated)

The revenue lens (FF-004) called a broken `distribute()` a *"permanent freeze of the vote-holder
set."* **It is not a freeze. It is a ratchet.** `withdrawTo` / `withdraw` deliberately omit
`harvestYield` (the NatSpec at `StakedGovToken.sol:127-129` says so, and the choice is correct on
its own terms — it is the escape hatch). So the set can still **shrink**. And `quorum` is
`getPastTotalSupply(t)/1000`, so the bar falls with the electorate while each survivor's absolute
weight is unchanged.

### Executed evidence

```
3 stakers x 90,000 stGOV, all self-delegated.  quorum = 270.000000000000000000 stGOV
lender's pullLocalReserves() begins reverting  (vm.mockCallRevert "MARKET_HALTED")

  dave.depositFor(90,000)  -> REVERTS         <- entry closed forever, for everyone
  alice.withdraw()         -> succeeds        <- exit still open
  bob.withdraw()           -> succeeds

quorum after the exits     = 90.000000000000000000 stGOV     (fell 3x)
carol's votes              = 90,000.000000000000000000 stGOV (unchanged)
  carol alone >= proposalThreshold  : true
  carol alone >= quorum             : true

carol proposes, votes, queues, executes, and takes the released treasury:
  GOV taken by the last staker: 557,142.857142857142857143
```

Carol needed no attack. She only had to **not leave.**

### Consequence

Any event that breaks `distribute()` converts governance into a race to be last out. The last
staker standing satisfies both gates alone and owns the Timelock, the `RevenueRouter`, and every
future vested release. There is no floor under quorum and no way to re-open entry.

### What I could not verify, stated plainly

The trigger is external. Given the established fact that `pullLocalReserves()` **early-returns on
zero rather than reverting**, the most likely benign trigger is closed — and I confirmed it at L4
(`test_VN5…`: a launch with zero accrued reserves still admits deposits). The remaining triggers
are all outside this repository: the market pausing, crossing `timeUntilImmutability`, an
operator-role change, an upgrade, or the Coin reverting on `safeTransfer` to `StakedGovToken` or
the Timelock. **This is a lead, not a confirmed exploit.**

**Questions for the client.** (1) Can `pullLocalReserves()` revert under any market state — paused,
insolvent, immutable, mid-upgrade? (2) Can `operator` be reassigned out of band by any Monolith
admin? (3) Does Coin have a pause or blocklist?

### Fix — both failure modes priced

*Option A.* Wrap the harvest in `try/catch` so a broken lender degrades entry instead of closing it.
- *Prevents:* the ratchet, entirely. Entry stays open, the electorate can dilute a holdout.
- *Creates:* it **removes the anti-JIT defence exactly when it matters** — a depositor who enters
  during a lender outage would be minted without a settlement, and would then share in the first
  successful harvest afterwards. Unless the catch branch *also* refuses to credit the depositor for
  any revenue realised later in the same block, this trades a governance risk for a theft risk.
  The revenue lens reached the same conclusion independently (FF-004) and explicitly said the
  recommendation should not be applied as written. **I agree, and I am repeating the caveat rather
  than softening it.**

*Option B.* Give `quorum()` an absolute floor as well as a fractional one.
- *Prevents:* the "last staker is the whole electorate" outcome, and it also blunts FF-001.
- *Creates:* if the staked float never reaches the floor, governance is permanently unreachable —
  including the proposal that would lower it. The factory lens priced this exact trade under FF-01
  and reached the same warning. Any floor needs a bootstrapping escape hatch.

*Option C (cheapest, and the one I would ship).* Add the cross-reference checks that both
`initialize` functions omit: `StakedGovToken.initialize` should assert
`IRevenueDistributor(revenueRouter_).govStaking() == address(this)`, and
`RevenueRouter.initialize` should assert `coin_ == IMonolithLender(lender_).coin()`.
- *Prevents:* the *misconfiguration* class of trigger, which is the one this repository can
  actually control, on clones whose initializers are one-shot and unrepairable.
- *Creates:* one extra external call each at launch; a lender with a non-standard `coin()` getter
  now fails loudly at deploy time instead of silently later. That is the right direction.
- Does **not** close the external-outage class. Say so.

---

## SI-004 — beneficiary rotation does not propagate, and nothing on-chain records which beneficiary a deployment used

**Severity: LOW** · `CoinDAOFactory.monolithBeneficiary` ↔ `deployments[i].monolithVesting._owner`
**Verification: Method B — `test_SI004_beneficiaryRotationDoesNotPropagateAndNothingRecordsIt`, PASS. Level 4.**

**Adjudicating a Pass-1 disagreement.** The factory lens graded this **SOUND** ("snapshot
semantics, matching the project's own test"); the governance lens listed it as a coupling where
"rotation does not propagate, and nothing detects it". **Both are right about different things.**

- The *snapshot* is correct and deliberate: `monolithVesting.initialize(monolithBeneficiary, …)` at
  `CoinDAOFactory.sol:470` reads live storage, the project has a test asserting that rotation
  affects only future launches, and a per-wallet owner is the only sane shape.
- What is **not** designed is the consequence: after a rotation, the old beneficiary is the **only**
  party who can move each historical wallet, and the repair is one `transferOwnership` call **per
  historical deployment**. The factory offers no batch and records nothing.

**Executed:** launch #1 → wallet owner = B_old. Rotate the factory to B_new. Launch #2 → wallet
owner = B_new. **Wallet #1 still owns B_old.** `factory.monolithBeneficiary() == B_new` — so the
factory's public view now disagrees with every wallet it created before the rotation. The repair
works (`vm.prank(B_old); wallet1.transferOwnership(B_new)`), but only while B_old's key is live.

**Impact.** If the rotation happened *because* B_old was compromised or lost, every historical 2%
allocation is stranded or attacker-controlled, and the rotation gives false assurance that it was
handled. Amplified by the governance lens's FF-003: the beneficiary can also `renounceOwnership()`
on any of those wallets and brick the allocation permanently.

**Fix.** Emit the beneficiary in `CoinDAODeployed`, or add it to the `Deployment` struct, so the
binding is recoverable from events without scanning every wallet. *Prevents:* the "which wallets do
I still need to migrate" problem. *Creates:* one more `address` in a struct that is already 14
fields; no behavioural risk.

---

## SI-005 — renouncing the router freezes an external privileged role chain permanently

**Severity: LOW** · `RevenueRouter._owner` ↔ `lender.manager` ↔ `lender.operator`
**Verification: Method B — `test_SEAM3_renouncingTheRouterFreezesTheExternalRoleChainForever`, PASS. Level 4.**

Sharpens **FF-010** (revenue lens, LOW) and **conditions the governance lens's REFUTATION** of
"the Lender's `manager` is permanently an EOA". That refutation rests on
`RevenueRouter.setManager` being `onlyOwner` with the timelock as owner — true, **but only while an
owner exists.**

**Executed:**

```
lender.operator() == revenueRouter                     <- permanent by design
timelock calls router.renounceOwnership()              <- one proposal, no guard
  router.owner()          == 0x0
  router.setManager(...)  -> REVERTS
  router.setGovStakingBps -> REVERTS
  lender.operator()       == revenueRouter             <- STILL the operator, now uncontrolled
  router.govStakingBps()  == 10000                     <- split frozen at 100% to stGOV, forever
  router.distribute()     -> still works, permissionlessly
```

The end state is a contract that permanently holds an external market's `operator` role with **no
controls of any kind**, still routing 100% of revenue at a split nobody can change, while the
market's `manager` is whatever the deploy script's EOA set it to (`DeployCoinDAO.s.sol` L71 —
governance lens FF-014). Three contracts each cache a piece of an authority chain whose end is now
unreachable from any of them.

**Fix.** Override `renounceOwnership()` in `RevenueRouter` to revert. *Prevents:* the accidental
permanent freeze. *Creates:* almost nothing — the router's owner is a timelock, not a key that can
be lost, and there is no scenario in the design where "no owner" is the desired end state. This is
the rare case where the fix is genuinely one-sided; the only cost is 2 lines and the loss of an
option nobody has articulated a use for.

---

## SI-006 — Phase 6 reads mutable factory storage after Phase 5's call into an address the factory does not control

**Severity: LOW / INFO (structural; the exploit precondition is contrived)** ·
`CoinDAOFactory.sol:452` → `CoinDAOFactory.sol:470`
**Verification: Method A — exhaustive line trace of every factory-storage read inside
`_deployCoinDAO`, plus explicit negative greps. Level 2.**

SKILL Phase 4 asks: *"If an external call happens between step N and step N+1, can the callee
observe — or change — state that step N+1 depends on?"* I enumerated **every** read of mutable
factory storage inside `_deployCoinDAO` (L350–521):

| relative line | absolute | read | mutable during the call? |
|---|---|---|---|
| 9–10 | L358–359 | `hasCoinDAO[lender]` | written in Phase 1, never re-read |
| **121** | **L470** | **`monolithBeneficiary`** | **YES — `acceptMonolithBeneficiary()` is external and unguarded except by identity** |
| 152 | L501 | `deployments.length` | yes, but read **fresh** at the push, so a nested launch stays consistent |

`monolithBeneficiary` is the **only** mutable factory storage value read after the untrusted
external call at L452 (`IMonolithLender(lender).setPendingOperator(...)`). A callee that happens to
be `pendingMonolithBeneficiary` can call `acceptMonolithBeneficiary()` re-entrantly and redirect
that launch's 2% allocation. The factory has no `ReentrancyGuard` (grep: no import).

**I am grading this LOW/INFO, not higher, and saying why:** the reentering party must already be
the nominated Monolith beneficiary, which makes this Monolith self-dealing against Monolith — no
outside attacker gains anything. The *structural* defect is real regardless: a value that
determines a permanent 200,000 GOV allocation is read after an arbitrary external call, in a
function with no reentrancy guard.

**Fix.** Snapshot `address beneficiary = monolithBeneficiary;` in Phase 1 next to
`allocationFor(...)` and use the local at L470. *Prevents:* the entire class, including the
non-reentrant same-block race the factory lens noted between `predictCoinDAOAddresses` and
`deploy()`. *Creates:* nothing — it is strictly a read hoist, and it also makes the snapshot
semantics the factory lens correctly identified **explicit in the code** rather than incidental.

This also composes with the factory lens's **FF-11** (a free-choice external call placed while the
factory holds 10,000,000 GOV, with mutation M8 proving Phase 5 can be deferred past Phase 7 with
all 19 tests still passing). Doing both — hoist the read *and* move Phase 5 after Phase 7 — closes
the window entirely at zero functional cost.

---

## SI-007 — `deployments[]` is push-only and describes a system that can move underneath it

**Severity: INFO** · **Verification: trace + an L4 assertion inside `test_SI001…`.**

`deployments[i]` records 14 addresses permanently (grep: no `delete`, no `.pop()`, no update path
anywhere in the factory). Of those, `.timelock` is the field with a live mutation path
(`Governor.updateTimelock`) — asserted stale at L4 in SI-001. `.revenueRouter`, `.governor`,
`.staker`, `.coinStakingRewards` are all clone/CREATE2 addresses that genuinely cannot move, so the
registry is correct for those. `.vault` can be written as `address(0)` on the
`deployForExistingCoin` path (factory lens FF-06).

Consumers — including the client's own `_verifyDeployment` (governance lens FF-006) — treat the
registry as the source of truth. It is a launch-time snapshot. Worth one line in the report so
integrators do not build on it.

---

## SI-008 — (harness, INFO) `vm.roll(block.number + N)` is a silent no-op after the first roll in forge 1.5.1

**Verification: Method B — control probe + re-run of the client's own suite with the safe idiom.
Level 4.**

Documented in the Execution Environment section above. **No false green exists in the delivered
suite today** — I patched both affected sites to `vm.roll(vm.getBlockNumber() + N)` and re-ran:
`CoinDAOGovernor.t.sol` 4/4 PASS, `StakedGovToken.t.sol` 14/14 PASS. Raised because it is a live
trap: any future test that relies on a *second* relative roll to move a snapshot will pass
vacuously. Recommend standardising on absolute targets read from the contracts (which is already
the dominant idiom in their suite) or on `vm.getBlockNumber()`.

---

# 6. Refuted hypotheses (a refutation is a claim too) and verified negatives

Each of these was a live suspicion that I killed. Recorded so no later pass re-derives them.

| ID | Hypothesis | How it was killed | Verdict |
|---|---|---|---|
| **R-1** | The open `EXECUTOR_ROLE` (`address(0)`) lets a bystander execute a queued proposal directly on the timelock and permanently desync `Governor._proposals[id].executed` from `Timelock._timestamps[opId]` | `test_VN4…` (L4): a bystander executed a non-Governor-targeting proposal directly; `GovernorTimelockControl.state()` re-reads the timelock and correctly reports `Executed`. OZ handles this deliberately. | **NOT A FINDING** |
| **R-2** | A proposal targeting the Governor itself, executed directly on the timelock, permanently bricks that proposal (the `_governanceCall` authorisation deque is empty) | `test_VN4…` (L4): the direct call **does** revert — but the timelock operation survives, and the normal `governor.execute()` path then succeeds (`votingDelay` became 100). Recoverable, no permanent desync. | **NOT A FINDING** (worth one INFO line: a griefer can waste gas, nothing more) |
| **R-3** | The four factory registries (`usedDeploymentKeys`, `deploymentKeyForId`, `deployments`, `hasCoinDAO`) can drift, including via a reentrant nested launch | `test_VN1…` (L4) across all three entry paths; plus a trace: every write path is inside one transaction and any failure rolls all four back together, and `deploymentId` is read **fresh** at the push so a nested launch cannot corrupt the index. Confirms the factory lens. | **NOT A FINDING** |
| **R-4** | The funder ↔ StakingRewards pair can desync so that `StakingRewards` promises more GOV than it holds, especially with the zero-supply surplus from FF-001 making the `rewardRate <= balance/duration` guard *easier* to pass (the factory lens's open question #3) | `test_VN2…` (L4): all four tranches funded, asserting `rewardRate * rewardsDuration <= GOV balance` after **every** notify. The guard is indeed only an overflow bound, but the funder transfers **before** notifying, so `rewardRate = amount/duration <= balance/duration` unconditionally. Funder fully drained (0 GOV left); sole staker received 6,499,999.99999999992816 of 6,500,000 GOV; **71,840,000 wei** (7.2e-11 GOV) stranded as rate-truncation dust. **`StakingRewards` is solvent on every reachable path.** | **NOT A FINDING** — answers the factory lens's handoff question #3 |
| **R-5** | A third party can burn a lender or a deployment key belonging to someone else (`hasCoinDAO` / `usedDeploymentKeys` are write-once and never cleared, so a griefing DoS would be permanent) | Trace: `deploymentKey` always binds `msg.sender`; `deployForExistingCoin` requires `msg.sender == lender.operator()`; `deploy()` gets a fresh lender from the immutable Monolith factory. **No third party can write either mapping for an address they do not control.** | **NOT A FINDING** |

**Verified negatives (pairs that stay consistent, worth stating positively in the report):**

- **VN-A** — `stGOV` balances, ERC20 `totalSupply`, `_totalCheckpoints` and `_delegateCheckpoints`
  move together on every mint and burn; the non-transferability override does not bypass
  `ERC20Votes._update`. (Confirmed at L4 inside SI-003: live supply, `getPastTotalSupply`, and
  `getVotes` all agreed at every step.)
- **VN-B** — the funder → `StakingRewards` → staker chain conserves GOV to within truncation dust.
- **VN-C** — the five allocation destinations sum to exactly `10,000,000e18` with **zero** left in
  the factory on the canonical path (measured at L4, `test_SEAM4…`).
- **VN-D** — the Governor/Timelock proposal-state pair reconciles correctly under direct execution.
- **VN-E** — the four factory registries cannot drift.
- **VN-F** — `RevenueRouter.distribute()` never strands Coin: the staker transfer and the notify are
  in the same branch, and the division remainder goes to the treasury.

---

# 7. What the established `pullLocalReserves()` fact closes

The brief established, and I did not re-derive, that the external lender's `pullLocalReserves()`
is a **complete drain** that **early-returns rather than reverting on zero**. Applied to the
open Pass-1 leads, this is the single highest-value thing this pass can hand the debrief:

| Pass-1 lead | Its premise | Status after the established fact |
|---|---|---|
| **FF-004** (revenue, HIGH lead) — *"`pullLocalReserves()` may revert when there is nothing to pull, bricking `depositFor`, the only mint path"* | assumption #1: "never reverts, including when reserves are zero" | **The zero-reserve half is CLOSED.** Confirmed at L4 (`test_VN5…`): a launch with no accrued revenue admits deposits normally. The residual — a revert for some *other* market reason — is now **unevidenced** and folds into SI-003 as a conditional lead. **Recommend downgrading FF-004 from HIGH to a stated assumption.** |
| **FF-005** (revenue, HIGH lead) — *"the anti-JIT property fails if the harvest is incomplete; a flash-staker captures ~100% of accumulated revenue"* | assumption #2: reserves are realised in two phases, so the harvest is partial | **REFUTED by the established fact.** A complete drain means `harvestYield` empties the pot before the mint, which is exactly what the defence needs. Confirmed at L4 (`test_VN6…`): with 100 COIN of accrued revenue and a 300,000-stGOV whale depositing after a 1,000-stGOV honest staker, `earned(whale) == 0` and `earned(alice) == 100e18`. **Recommend closing FF-005.** |

Both were correctly written up as leads with the uncertainty stated. The fact resolves them, and
the resolution should reach the client — a closed lead is a deliverable.

**One residual worth stating.** The complete-drain property makes the *timing lever* total: any
party may, at any moment, force the entire accrued revenue to be credited to whoever is staked at
that instant, and with `DEFAULT_GOV_STAKING_BPS = 10_000` the treasury receives nothing whenever
any stGOV exists. That is **FF-04** (factory lens) and **FF-011** (revenue lens); it is unchanged,
and it belongs to the revenue Pass-2 agent, not to me.

---

# 8. Answering the question that defined this pass

> *For each seam, which contract is responsible for keeping the pair consistent — and is there any
> case where the answer is "none of them"?*

| seam | responsible contract | verdict |
|---|---|---|
| 1. stGOV checkpoints ↔ Governor quorum base | **none** — quorum is a fraction of a freely-movable number with no floor | FF-001 (existing HIGH); extended by **SI-003** |
| 1b. Governor ↔ Timelock role set / ownership / assets / registry | **NONE.** Five bindings, one migration primitive that moves one of them, both directions independently breakable in a single action, no external admin because the factory renounced it | **SI-001, SI-001b, SI-001e** |
| 2. `rewardsDistribution` ↔ funder ↔ Phase-7 renounce | **the factory**, once, atomically, and it is self-enforcing thereafter | **consistent** (VN-B) — the *identity* half of this seam is one of the better-built parts of the system |
| 2b. `rewardRate` ↔ `_totalSupply` across that same boundary | **NONE** — the factory writes one side inside its own transaction, an arbitrary party writes the other at a published address in that same transaction | **SI-002** |
| 3. lender `operator`/`manager` ↔ router's `lender` ↔ `hasCoinDAO` | **NONE.** Three caches of one external fact, never read back, no setter on any of them, and the contract that would need one (`StakedGovToken`) has no owner at all | FF-03 + FF-017 (existing); **SI-003, SI-005** |
| 4. fixed supply ↔ five destinations ↔ payout capability | **`allocationFor()` owns the arithmetic** and does it exactly (zero dust, verified). **Nobody owns the payout property.** | arithmetic **consistent** (VN-C); payout measured below |
| 5. vesting ownership ↔ `monolithBeneficiary` ↔ per-deployment records | **none, but the asymmetry is deliberate and a repair exists** — the gap is the missing record, not the missing propagation | **SI-004** |

**Seam 4, measured at L4** (`deployerStakeBps = 0`, `deployerRecipient = 0`):

```
funder (tranches 2-4, unfired)  4,387,500 GOV   pays out only via 3 more notify cycles, each of
                                                which can be opened against an empty pool
StakingRewards (tranche 1)      2,112,500 GOV   pays out ONLY in proportion to time-with-stakers;
                                                5,787.67 GOV destroyed per idle day, no recovery
                                                (owner renounced, no recoverERC20)
timelock (immediate 5%)           500,000 GOV   spendable only by a passed proposal
treasuryVesting (28%)           2,800,000 GOV   release() is permissionless but pays the TIMELOCK
                                                -> same governance gate
monolithVesting (2%)              200,000 GOV   release() is permissionless and pays a plain
                                                address
left in the factory                     0 GOV
                               ------------
                               10,000,000 GOV   conserved exactly
```

**The structural consequence, which no single-contract lens can see:** at genesis, the *only* GOV
that reaches a party without either (a) staking Coin in a market that may not have depth yet, or
(b) passing a governance proposal that requires GOV you do not have, is the **Monolith 2%**. The
DAO's bootstrap therefore runs entirely through the emissions program — which is exactly the
contract **SI-002** shows the launcher can corner in the launch transaction, and exactly the
threshold **FF-001** shows is cheap to clear. Seam 2b and seam 1 are the same attack surface viewed
from two contracts.

---

# 9. Coverage and honesty statement

- **Coupled cross-contract pairs mapped:** 18 (P1–P17 plus P5b), spanning 9 contracts and 1
  external interface.
- **Cross-contract mutation paths analysed:** 21 (matrix, §2). Every `???` resolved.
- **Raw findings:** 9. **After verification: 9 TRUE POSITIVE, 0 FALSE POSITIVE**, of which 1 is a
  designed asymmetry graded LOW and 1 is a harness note. **5 hypotheses REFUTED.**
- **Final: 0 CRITICAL · 1 HIGH-by-composition · 3 MEDIUM · 3 LOW · 2 INFO.**
- **Two Pass-1 HIGH leads closed** by the established external fact (§7).
- **Verification levels:** level 4 (executed in a real EVM) for SI-001, SI-001b, SI-001e, SI-002,
  SI-003, SI-004, SI-005, SI-008 and all six verified negatives. Level 2 with an exhaustive line
  trace and explicit negative greps for SI-006 and SI-007.
- **Controls included** (so the checks could have failed): `test_SI001c` (state tracks the timelock
  without the migration), `test_SI001d` (the safe migration works), `test_SI002_control…` (the same
  GOV is destroyed instead of captured), `test_VN5`/`test_VN6` (the mint path and anti-JIT defence
  hold under the established fact), and the forge-1.5.1 roll probe.
- **Absence claims, each checked by an explicit grep for the negative or the compiled ABI:**
  `revokeRole` — 0 hits in `src/`; `grantRole` — exactly 2 (`CoinDAOFactory.sol:428-429`);
  `updateTimelock` — 0 hits in `src/` and `script/`; `delete` — 0; `.pop()` — 0;
  `recover`/`rescue`/`sweep`/`skim` — 0 functions; `StakedGovToken` is not `Ownable` and its
  compiled ABI contains no owner, mint, or rescue function; `RevenueRouter` has no setter for
  `lender`, `coin`, `treasury`, or `govStaking`; `monolithBeneficiary` is the only mutable factory
  storage read after L452.
- **What I did NOT do:** I did not rebuild the within-contract mutation matrices for
  `StakedGovToken`/`RevenueRouter` (revenue agent), `StakingRewards`/`StakingRewardsFunder`
  (emissions agent), or `CoinDAOFactory` internals (factory agent). I did not read
  `[scratch]` or `engagements/`. I did not verify any external Monolith behaviour beyond
  the fact I was given.
- **Client code was not modified.** All experiments ran on a disposable copy under the session
  scratchpad. `git status --porcelain [scratch]` and `git diff --stat -- [scratch]` are both empty;
  the 55/55 baseline was re-verified in the copy before and after.
