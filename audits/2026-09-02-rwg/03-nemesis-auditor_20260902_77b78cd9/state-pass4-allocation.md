# NEMESIS Pass 4 — State Inconsistency Auditor — TARGETED: the allocation → voting-weight → quorum chain

**Lens:** `.claude/skills/state-inconsistency-auditor/SKILL.md`, run **narrowly** — Phases 1, 2, 3, 5
and 8 applied to **one** coupled chain rather than to the whole tree.

**This pass does not re-audit anything Pass 2 cleared.** Its entire scope is the chain Pass 3
exposed in FP3-001 and FP3-002:

```
deployerStakeBps -> deployerRecipient -> immediateAllocation -> GOV balance
  -> stGOV supply -> voting weight -> quorum base -> what governance can do
```

Pass 3 found that chain by asking a *composition* question. This pass asks the **structural** one:
what writes each link, does the write propagate, and where do the amount and the recipient stop being
governed by the same predicate.

**Code read:** `[scratch]` and `[scratch]`.
`[scratch]` and `engagements/**` were **not** read. OZ behaviour (`ERC20Votes`
checkpointing, `GovernorVotesQuorumFraction`, `VestingWalletUpgradeable`, `ERC20Wrapper`) was
established **by execution or by the compiled ABI**, never by reading the library.

---

## Execution environment and integrity

Disposable copies under the session scratchpad:
`…/[scratch]` (baseline + PoCs), `…/[scratch]` and `…/[scratch]`
(fix- and drift-evaluation mutants).

| suite | result |
|---|---|
| project baseline in the copy | **55/55 PASS** |
| project baseline + this pass's PoCs | **69/69 PASS** |
| this pass's PoCs alone (`test/audit/**`) | **14/14 PASS** |
| **MUT-A** = FP3-001 Option A applied to `_validate` | fix-eval **3/3 PASS**; client suite **54/55**, one failure |
| **MUT-B** = `VESTED_TREASURY_WEIGHT` 2_800 → 2_500 | client suite **55/55 PASS** — the mutation is invisible |

**`[scratch]` was not written to.** `git status --porcelain [scratch]` → empty;
`git diff --stat -- [scratch]` → empty; `diff -rq` of `src/` and `script/` against the copy →
**IDENTICAL**, checked after all experiments.

**forge 1.5.1-stable.** Every roll/warp goes through `vm.getBlockTimestamp()` or an absolute target
read from the Governor (`proposalSnapshot`/`proposalDeadline`/`clock()`), per SI-008.

**Verification levels:** **L1** compiles · **L2** a check passes · **L3** the check could have failed
(a control is included) · **L4** executed in a real EVM.

> **One methodology note, recorded because this pass is about checks with no resolution.**
> The first draft of SP4-004/SP4-005 read `quorum(t)` at a timepoint **before** the probe Governor's
> numerator checkpoint existed. `Checkpoints.upperLookupRecent` returned 0, quorum was 0, and
> `assertGe(votes, quorum)` **passed vacuously**. It was caught by the paired assertion in SP4-004
> failing. Every floor/numerator test below now carries `assertGt(quorum, 0)` as an explicit
> resolution control. The finding stands; the first version of the evidence did not.

---

# 1. PHASE 1 — Coupled State Dependency Map for the chain

Eight links. For each: what storage actually holds it, and what must move with it.

```
+=============================================================================================+
| L1  deployerStakeBps            uint16, CALLDATA ONLY. Never stored. Never emitted.         |
|     coupled to: every one of the five allocation amounts (sole input to allocationFor)      |
|     invariant:  the launch record must let a reader recompute the split -> BROKEN (SP4-009) |
+---------------------------------------------------------------------------------------------+
| L2  deployerRecipient           address, CALLDATA ONLY. Never stored. Never emitted.        |
|     coupled to: L1 (via _validate, ONE DIRECTION), and to TWO destinations at once:         |
|                 deployerVesting's owner (L479) and immediateRecipient (L491-492)            |
|     invariant:  the predicate that admits the recipient must be the predicate that sizes    |
|                 the payment -> BROKEN (SP4-001)                                             |
+---------------------------------------------------------------------------------------------+
| L3  immediateAllocation         uint256, MEMORY ONLY. Transferred, never stored.            |
|     amount    = f(L1)  = (10e6 - 200e3 - 10e6*bps/1e4) * 500 / 9800                         |
|     recipient = g(L2)  = L2 == 0 ? timelock : L2                                            |
|     invariant:  f and g are gated by the SAME condition -> BROKEN. f is MAXIMAL exactly     |
|                 where g is UNCHECKED (SP4-001)                                              |
+---------------------------------------------------------------------------------------------+
| L4  GovToken._balances[r]       ERC20 storage. Fixed 10,000,000e18 supply, fully liquid.    |
|     coupled to: GovToken._delegateCheckpoints (WRITTEN, READ BY NOTHING — FF-009)           |
+---------------------------------------------------------------------------------------------+
| L5  StakedGovToken._totalSupply + _totalCheckpoints   <- THE QUORUM DENOMINATOR             |
|     mint path : depositFor  ONLY   (ABI-verified, section 2)                                |
|     burn paths: withdrawTo, withdraw, harvestAndWithdraw  (all route to withdrawTo)         |
+---------------------------------------------------------------------------------------------+
| L6  StakedGovToken._delegateCheckpoints[v]            <- THE VOTE NUMERATOR                 |
|     written by: mint, burn, AND delegate()/delegateBySig                                    |
|     *** L5 and L6 have DIFFERENT mutation sets: delegate() writes L6 and not L5 ***         |
+---------------------------------------------------------------------------------------------+
| L7  quorum(t) = getPastTotalSupply(t) * numerator(t) / 1000                                 |
|     _quorumNumeratorHistory written by: constructor, updateQuorumNumerator (onlyGovernance)  |
|     *** SELF-REFERENTIAL: L7's base IS L5, which the attacker writes with their own stake ***|
+---------------------------------------------------------------------------------------------+
| L8  ProposalState  = f(quorum reached, forVotes > againstVotes, clocks)                     |
|     THE ONLY LINK IN THE CHAIN THAT IS NOT DERIVED FROM THE ATTACKER'S OWN DEPOSIT (SP4-006)|
+=============================================================================================+
```

**The structural statement in one line:** the chain has **eight** links and the attacker writes,
directly or by derivation, **seven** of them. The eighth — the against-tally — is the only place any
defence lives, and it is the one link no parameter controls.

---

# 2. PHASE 2 — Mutation Matrix

**"Propagates?"** answers the auditor's question: does the write to this link update its downstream
coupled link, or is the downstream recomputed lazily from a possibly-stale upstream?

| Link | Written by | Type | Propagates downstream? |
|---|---|---|---|
| L1 `deployerStakeBps` | `deploy` / `deployForExistingCoin` calldata | one-shot, ephemeral | **NO — discarded.** `allocationFor` is `pure` and its result is never stored. Nothing downstream can re-derive it. |
| L2 `deployerRecipient` | same calldata | one-shot, ephemeral | **NO — discarded.** Reaches two destinations under two different predicates and is recorded at neither. |
| L3 `immediateAllocation` | `_deployCoinDAO` L493 `safeTransfer` | one-shot | n/a (terminal transfer) |
| L4 `GovToken._balances` | `initialize` `_mint` (factory only); ERC20 `transfer`/`transferFrom` | ±delta, permissionless | writes `GovToken._delegateCheckpoints`, **read by nothing** (FF-009, confirmed: `IVotes` in `src/` never names `GovToken`) |
| L5 stGOV supply | **`depositFor`** (mint) | +delta, permissionless | yes → L6 for the *delegatee*, yes → L7 |
| L5 stGOV supply | `withdrawTo` / `withdraw` / `harvestAndWithdraw` (burn) | −delta, permissionless | yes → L6, yes → L7 |
| L5 stGOV supply | *anything else* | — | **NONE.** ABI-verified: the complete non-view surface of `StakedGovToken` is `approve, delegate, delegateBySig, depositFor, getReward, harvestAndGetReward, harvestAndWithdraw, initialize, notifyRewardAmount, permit, transfer, transferFrom, withdraw, withdrawTo`. No `mint`, no `_recover` exposure, no owner, no rescue/sweep (grep for the negative: `_mint\|_burn\|_recover\|rescue\|sweep\|Ownable` in `StakedGovToken.sol` → **zero hits**). `transfer`/`transferFrom` always revert `NonTransferable` (L180-182). |
| L6 delegate checkpoints | `delegate` / `delegateBySig` | move, permissionless | **writes L6 and NOT L5** — the asymmetry behind SP4-006 |
| L7 `_quorumNumeratorHistory` | constructor; `updateQuorumNumerator` | checkpointed | `onlyGovernance` — **repairable only through the mechanism it gates** |
| L7 quorum value | **every L5 write, by anyone** | derived, lazily, at read time | quorum is recomputed per timepoint from `getPastTotalSupply` — **it is never stored and never validated against anything** |
| L8 tally | `castVote*` | +delta | terminal |

### The three `???` cells resolved

| Question | Answer | Evidence |
|---|---|---|
| Does anything record L1/L2 so the allocation can be audited later? | **No.** The `Deployment` struct is **14 addresses and zero uints** (grep: `struct Deployment` block contains **0** `uint` fields). `CoinDAODeployed` carries 12 addresses and no amount. `CoinDAOAttached` carries 3 addresses. No event anywhere in `src/` names a recipient or an amount. | SP4-009, L4 + greps |
| Does a write to L5 update L7 consistently? | **Yes — and that is the defect.** L7 is *defined* as a fraction of L5. There is no desync; the pair is **fused**, and the attacker owns the fusing input. | SP4-003, L4 |
| Can L6 move without L5? | **Yes — `delegate()`.** So the numerator and the denominator of the governance test have different, non-overlapping writers. | SP4-006, L4 |

---

# 3. PHASE 5 — Parallel Path Comparison: the five allocation destinations

All five draw from one fixed supply. **The fixed-supply invariant is treated identically by all five.
Nothing else is.**

| | 1 · staking rewards | 2 · treasury vest | 3 · **immediate** | 4 · monolith vest | 5 · deployer vest |
|---|---|---|---|---|---|
| amount | `remaining*6500/9800` | **residual** | `remaining*500/9800` | `supply*200/1e4` | `supply*bps/1e4` |
| amount from a **weight constant**? | ✓ `COIN_STAKING_REWARDS_WEIGHT` | ✗ **residual — no weight is read** | ✓ `IMMEDIATE_ALLOCATION_WEIGHT` | ✓ `MONOLITH_BPS` | ✓ (caller's bps) |
| amount bounded? | implicitly | implicitly | implicitly | fixed 2% | ✓ `MAX_DEPLOYER_STAKE_BPS` |
| recipient source | fresh clone | fresh clone | **CALLER** | factory storage | **CALLER** |
| recipient non-zero enforced? | n/a | n/a | **only when `bps != 0`** | ✓ constructor + `setPendingMonolithBeneficiary` | ✓ when `bps != 0` |
| **predicate that gates it** | — | — | **`deployerRecipient == address(0)`** (an *address* test) | — | **`allocation.deployerVesting != 0`** (an *amount* test) |
| liquid at t=0? | no (365 d stream) | no (4 y linear) | **YES** | no (4 y linear) | no (4 y linear) |
| recoverable if mis-set? | — | — | **no** | two-step rotation before launch | — |

### The two answers the brief asked for

**(a) Do all five paths treat the fixed-supply invariant identically?** **Yes — VN-2, L4.**
`_sum(allocationFor(b)) == 10,000,000e18` for **every** `b` in `[0, 2000]` (exhaustive, 2001 values),
and on real launches at `bps ∈ {0, 1, 2000}` the factory retains **exactly 0** GOV and every wei is
placed. The dust-to-treasury line (L288-289) is correct. **Record this positively.**

**(b) Where do amount and recipient get validated by different predicates?** **Path 3 vs Path 5 —
and they share the same address variable.**

```
_validate (L559-562)            tests deployerStakeBps      -> admits the recipient
L473 / L496 (wallet + transfer) tests allocation.deployerVesting != 0
L491-492    (immediate routing) tests deployerRecipient == address(0)
```

Three predicates over one pair. Pass 3's B4 established the first two can never disagree
(`bps != 0` ⟺ `deployerVesting >= 1000e18`). **The third is not equivalent to either**, and it is the
one that moves the larger, liquid, unvested amount.

---

# 4. Findings

---

## SP4-001 — **NEW** — the immediate allocation is *maximal* on exactly the branch where its recipient is unchecked

**Severity: MEDIUM standalone (structural root of FP3-001)** · `CoinDAOFactory` L286-287, L491-493, L559-562
**Verification: Method B — `test_SP4_001_immediateAllocationIsMaximalWhereTheRecipientIsUnchecked`, PASS. Level 4.**

**Coupled pair:** `immediateAllocation` (amount, a function of `deployerStakeBps`) ↔ `immediateRecipient`
(destination, a function of `deployerRecipient`).
**Invariant that must hold:** the condition that admits a caller-supplied recipient must be at least as
strict as the size of the payment it admits.

Pass 3 established that `_validate` polices the recipient only on the `bps != 0` branch. What Pass 3
did **not** establish is the *direction of the amount*. Executed over the whole legal range:

```
immediate @ bps=0    (recipient UNCHECKED) : 500,000.000000000000000000
immediate @ bps=1    (recipient REQUIRED)  : 499,948.979591836734693877
immediate @ bps=2000 (recipient REQUIRED)  : 397,959.183673469387755102
                                             (monotonically non-increasing, 2001 values asserted)
```

`immediateAllocation` is **strictly maximised at `bps == 0`** — which is precisely and only the value at
which `_validate` declines to look at `deployerRecipient` at all. The guard engages only on strictly
smaller payments, and its strictness is *inversely* correlated with the amount at risk over the entire
domain. This is not "a missing symmetric check"; it is a check whose coverage is anti-correlated with
value.

**Engaging with what exists (workspace rule).** L490 documents the routing, and the client's own test
`testLaunchVariantsCoverSCoinAndUnvestedImmediateAllocation` (`test/CoinDAOFactory.t.sol:165-171`)
**asserts this exact shape**: `balanceOf(deployerRecipient) == allocation.immediateAllocation` and
`balanceOf(timelock) == 0`. The configuration is deliberate, documented and tested. **The finding is
not that the routing is wrong.** It is that the one guard in the file that constrains a caller-supplied
recipient is placed on the strictly-cheaper half of its own domain, and nothing anywhere states that
the 5% is at its maximum precisely where nothing checks it.

---

## SP4-002 — **NEW** — at genesis the immediate allocation is not 5% of supply, it is **100% of the free supply**

**Severity: HIGH by composition** · `CoinDAOFactory` L484-499
**Verification: Method B — `test_SP4_002_immediateAllocationIsAllOfTheFreeGovAtGenesis`, PASS. Level 4.**

Every downstream fix proposal in this engagement has been priced against "5% of supply". That is the
wrong denominator. The complete GOV ledger the instant `deploy()` returns:

```
StakingRewards  (365-day emission stream, no staker exists) : 2,112,500.000000000000000000
Funder          (tranches 2-4, unopened)                    : 4,387,500.000000000000000000
treasuryVesting (4y linear -> the TIMELOCK)                 : 2,800,000.000000000000000000
monolithVesting (4y linear -> the platform EOA)             :   200,000.000000000000000000
LAUNCHER        (liquid, unvested, unconditional)           :   500,000.000000000000000000
TIMELOCK        (the DAO's own balance)                     :         0.000000000000000000
factory residue                                             :         0.000000000000000000
                                                     total  : 10,000,000.000000000000000000  (asserted)

treasuryVesting.releasable(GOV) at t=0 : 0   (asserted)
monolithVesting.releasable(GOV) at t=0 : 0   (asserted)
StakingRewards.totalSupply()   at t=0  : 0   (asserted -- no coin staker exists)
```

**9,500,000 of the 10,000,000 GOV is behind a clock or behind an emission stream.** The launcher's
500,000 is the *only* GOV any party can move, stake, or vote with at block zero. This is the premise
correction that determines whether *any* of the proposed remedies can work, and it is used by SP4-004
and SP4-005 below.

**Coupled pair:** `immediateAllocation` ↔ `stGOV totalSupply`.
**Invariant assumed by every quorum remedy:** that an honest float exists to be a fraction *of*.
**At genesis that float is empty, and the attacker is 100% of it.**

---

## SP4-003 — **NEW** — the quorum pair is *fused*, not merely coupled: the defence recovers 0.1% of what it defends against

**Severity: HIGH** · `CoinDAOGovernor` L64-70 × `StakedGovToken` L102-111
**Verification: Method B — `test_SP4_003_quorumRisesByOneThousandthOfTheAttackersOwnDeposit` and
`test_SP4_003b_selfSufficiencyRisesWithTheAttackersOwnContribution`, both PASS. Level 4.**

**Coupled pair:** `StakedGovToken._delegateCheckpoints[attacker]` (the numerator of the governance test)
↔ `StakedGovToken._totalCheckpoints` (the denominator of `quorum`).
**Both are written by the same permissionless call, `depositFor`, with the attacker's own tokens.**

The classic state-inconsistency bug is one side of a pair moving without the other. Here the pair moves
**together, by construction, at a fixed ratio of 1000:1 in the attacker's favour**:

```
attacker stakes 250,000 : votes 250,000.000  quorum 250.000  surplus 249,750.000
attacker stakes 500,000 : votes 500,000.000  quorum 500.000  surplus 499,500.000
                            d(votes)/d(quorum) = 1000        (asserted)
        d(surplus)/d(stake) = 249,750/250,000 = 0.999        (asserted)
```

**Every unit the attacker adds raises their surplus over quorum by 0.999 of a unit.** The quorum
mechanism reclaims one part in a thousand of the very thing it exists to bound. And self-sufficiency is
*increasing* in the attacker's own contribution once any honest float exists:

```
A = 250,000  H = 4,500,000  ->  votes/quorum =  52.63x
A = 500,000  H = 4,500,000  ->  votes/quorum = 100.00x     (asserted increasing)
```

**Masking pattern (SKILL Phase 7).** This is not a defensive ternary; it is worse. The self-referential
definition means the invariant *cannot be observed to be broken* — `quorum` always returns a value
consistent with its inputs. There is no state to check, no reconciliation to add, and nothing that
would ever revert. A structural check cannot find this; only asking *whose money is in the denominator*
can.

---

## SP4-004 — **NEW** — **no quorum numerator works.** FP3-001 Option A is defeated for **51.02 GOV**

**Severity: HIGH (fix evaluation)** · fix under test: FP3-001 Option A, applied to `_validate`
**Verification: Method B — `test_SP4_004_noQuorumNumeratorStopsTheGenesisAllocation`,
`test_SP4_005_control_theBindingNumeratorIsVacuousAtGenesis`, and on the MUT-A tree
`test_MUT_A_control_zeroStakeNamedRecipientIsNowRejected`,
`test_MUT_A_oneBasisPointRestoresTheEntireCapture`,
`test_MUT_A_theForcedVestingWalletHasNoCliffAndPaysOnDayOne`. All PASS. Level 4.**

### (a) The numerator, swept

Against the **maximum possible** honest participation — the entire remaining 9,500,000 supply staked
and delegated:

```
n (of 1000)   quorum required        launcher's 500,000 alone
     1           10,000                     YES
    10          100,000                     YES
    50          500,000                     YES   <- boundary: A >= (A+H)*n/1000  <=>  n <= 50
    51          510,000                     no
   100        1,000,000                     no
   500        5,000,000                     no
   999        9,990,000                     no
```

### (b) …and the control that kills the remedy

The numerators that bind above bind **only because H = 9,500,000 was staked**. Re-run at genesis, where
SP4-002 proved H = 0:

```
stGOV total supply at genesis : 500,000.000   (the launcher IS the float)
quorum @ n=51                 :  25,500.000   -> cleared alone
quorum @ n=999 (99.9%!)       : 499,500.000   -> cleared alone   (asserted)
```

**A fractional quorum can only ever require the attacker to out-stake the *participating* float. At
genesis that float is the attacker.** Raising the numerator does not raise the attacker's cost; it
raises the cost for everyone *else*, later.

### (c) FP3-001 Option A, applied and measured (MUT-A)

Option A — *"require `deployerRecipient == address(0)` whenever `deployerStakeBps == 0`"* — was applied
to `src/CoinDAOFactory.sol:_validate` on a mutant tree.

**Mutation control (L3), so the check could have failed:** `test_MUT_A_control_…` PASS — the
(bps = 0, recipient ≠ 0) shape now reverts `DeployerRecipientRequired()`, and the honest shape still
launches with 500,000 in the timelock. The fix demonstrably bites.

**Then `deployerStakeBps = 1`:**

```
liquid to launcher @ bps=1        : 499,948.979591836734693877
vested wallet      @ bps=1        :   1,000.000000000000000000  (owner == the launcher, asserted)
what bps=0 would have paid liquid : 500,000.000000000000000000
COST OF THE FIX TO THE ATTACKER   :      51.020408163265306123   <- 0.0102%
timelock GOV at launch            :       0.000000000000000000   <- unchanged: the DAO gets nothing

launcher stakes the liquid remainder, self-delegates:
  votes 499,948.979…   quorum 499.948…   threshold 10,000
ONE proposal: revenueRouter.transferOwnership(launcher)
  -> Succeeded -> queued -> executed -> RevenueRouter.owner() == the launcher   (asserted)
```

**The remedy costs the attacker 51 GOV — one part in ten thousand — and the capture is otherwise
identical.** The 1,000 GOV "lock" it forces is not a lock either: `test_MUT_A_theForced…` shows
`releasable` is **0.684931506849315068 GOV after one day** (no cliff, FF-005), and `release()` is
permissionless.

**Cost of Option A, measured (L4):** **1 of the client's 55 tests fails** —
`testLaunchVariantsCoverSCoinAndUnvestedImmediateAllocation`, the test whose *name* asserts the
unvested-immediate-allocation shape is a supported launch variant. So Option A removes a configuration
the client's own suite ratifies, and buys 51 GOV.

Pass 3 predicted the `bps = 1` workaround and priced it as *"strictly worse documentation"*. **It is
not a documentation cost. It is a complete defeat of the remedy, measured.**

---

## SP4-005 — **NEW** — **no absolute quorum floor works either**, and the failure mode above the line is a permanent deadlock

**Severity: HIGH (fix evaluation)** · fix under test: FF-01 / SI-003 Option B, an absolute quorum floor
**Verification: Method B — `test_SP4_009a_floorBelowTheGenesisAllocationIsCleared` and
`test_SP4_009b_floorAboveTheGenesisAllocationDeadlocksTheDao` against a `FlooredQuorumGovernor`
(`quorum() = max(fractional, floor)`, identical in every other respect). Both PASS. Level 4.**

Pass 3 asserted this by argument. It is now executed, and the *upper* half is worse than Pass 3 said.

**Floor ≤ 500,000 → cleared alone.** Floor 400,000e18: the launcher's genesis 500,000 proposes, votes,
and the proposal reaches **Succeeded**.

**Floor > 500,000 → the DAO deadlocks, and cannot lower the floor.** Floor 1,000,000e18:

```
day zero, launcher alone (the entire staked float)                 -> Defeated
--- warp 4 years; release BOTH vesting streams (permissionless) ---
TIMELOCK GOV after full vest                     : 2,800,000.000000000000000000
platform EOA GOV after full vest                 :   200,000.000000000000000000
max stGOV reachable WITHOUT a governance action  :   700,000.000000000000000000  (asserted)
floor                                            : 1,000,000.000000000000000000
launcher + platform, both staked, both voting For -> Defeated       (asserted)
a proposal to stake the treasury's 2,800,000      -> Defeated       (asserted)
```

**The 2,800,000 GOV that would clear the floor sits in the Timelock**, and `depositFor` pulls from
`msg.sender` — so moving it into stGOV requires the Timelock to *be* the caller, i.e. an executed
proposal, i.e. the quorum the floor has just disabled. `updateQuorumNumerator` is `onlyGovernance`
(grep-verified), the factory renounced `DEFAULT_ADMIN_ROLE` on the Timelock (L430, per SI-001), and
there is no admin anywhere. **The floor is repairable only through the mechanism it disables.**

**Honest limit, stated.** This deadlock is proven with **no Coin stakers**. In a live market the 6.5M
emission stream does eventually produce free GOV that could meet a floor — but **FP3-002 measured that
the launcher heads that stream on both entry paths**, so the launcher reaches any given floor first.
The window in which a floor binds the launcher and not the honest side is, at genesis, **empty**, and
thereafter contested in the launcher's favour.

**Conclusion on floors, stated plainly as the brief requires:**

> **No absolute quorum floor works.** Below the genesis immediate allocation it is cleared by the
> launcher alone; above it, governance is dead until an honest float that does not yet exist appears,
> and the floor cannot be lowered because lowering it requires the quorum it sets. There is no value
> in between, because at t = 0 the launcher holds **100%** of the free supply (SP4-002) — a fraction of
> which any floor must be.

---

## SP4-006 — **NEW** — the chain stops at the **tally** link, not the quorum link; undelegated honest staking is strictly counter-productive

**Severity: MEDIUM** · `StakedGovToken` L6 vs L5 mutation sets × `GovernorCountingSimple`
**Verification: Method B — `test_SP4_010_undelegatedHonestStakeRaisesQuorumAndStopsNothing` with the
control `test_SP4_010_control_delegatedAgainstVotesAreTheOnlyBrake`. Both PASS. Level 4.**

This answers the brief's *"map exactly what that permits, and at which link it stops."*

`delegate()` writes L6 and **not** L5. `depositFor` writes both. So a staker who deposits for the Coin
revenue share — which is the economically motivated behaviour, since `RevenueRouter` routes
`govStakingBps = 10_000`, i.e. **100%** of revenue to stGOV holders — raises the quorum denominator and
contributes **zero** votes. Two runs, identical except for the honest cohort's delegation:

```
                                   quorum      launcher For     result
4,500,000 honest, NOT delegated    5,000.000     500,000.000    Succeeded   <- 9x the attacker's stake, no effect
4,500,000 honest, delegated Against 5,000.000    500,000.000    Defeated    <- CONTROL
```

**The quorum is identical in both runs and is cleared 100× over in both.** The *only* thing that
changed the outcome is the against-tally. Therefore:

- **L7 (quorum) provides no defence at any parameter value** — SP4-004 and SP4-005 are the parametric
  proof; this is the behavioural one.
- **The chain stops only at L8**, which requires honest holders to be staked **and** delegated **and**
  watching for the full 36,000-block voting window.
- The design **recruits** the population that defeats this: revenue-motivated stakers who never
  delegate. Staking is required for revenue; delegating is not.

**This EXTENDS FF-011 (LOW)**, which established the mechanism on its own. The new content is the
composition: at the shipped parameters the mechanism is not a minor accounting quirk — it is the reason
the only working brake is unlikely to be armed.

---

## SP4-007 — **EXTENDS FF-002** — voting weight survives the *total* exit of the underlying

**Severity: LOW (mechanism is standard OZ; recorded for the composition)** · `CoinDAOGovernor` × `StakedGovToken`
**Verification: Method B — `test_SP4_006_voteQueueAndExecuteWithZeroRemainingStake`, PASS. Level 4.**

**Coupled pair:** `_delegateCheckpoints[voter]` (historical, immutable) ↔ the voter's *present*
economic exposure. The pair desyncs at the snapshot block and never reconciles.

FF-002 established that `getPastVotes` is historical. Executed here to the end of the chain: after the
proposal snapshot, the launcher calls `withdraw()` (burning **all** stGOV) and transfers **all** GOV
away, then:

```
stGOV balance : 0     GOV balance : 0     stGOV totalSupply : 0   (all asserted)
castVote -> Succeeded -> queue -> +2 days -> execute
RevenueRouter.owner() == the launcher                             (asserted)
```

The router is seized by an address holding nothing, with zero economic exposure across the entire
5-day vote and 2-day timelock. Combined with SP4-002, the capital requirement for genesis capture is
**500,000 GOV held at two block heights** — not held through the governance cycle.

---

## SP4-008 — **NEW** — `VESTED_TREASURY_WEIGHT` is a coupled value that nothing reads; the residual silently absorbs any drift

**Severity: LOW** · `CoinDAOFactory` L27-30, L285-289
**Verification: Method B — MUT-B on a mutant tree (`VESTED_TREASURY_WEIGHT` 2_800 → 2_500), with the
client's own suite as the resolution test. PASS. Level 4.**

**Coupled set:** `{COIN_STAKING_REWARDS_WEIGHT, IMMEDIATE_ALLOCATION_WEIGHT, VESTED_TREASURY_WEIGHT}`
↔ `ALLOCATION_WEIGHT_TOTAL`.
**Invariant:** `6500 + 500 + 2800 == 9800`. **Asserted nowhere** — not in `src/`, not in the 55 tests.

`VESTED_TREASURY_WEIGHT` has **exactly one occurrence in the whole tree: its own declaration**
(grep-verified over `src/ script/ test/`). `treasuryVested` is computed as a **residual**
(L288-289), so it absorbs any inconsistency among the other weights without a revert, a log, or a
failing test. It is a `public constant`, so it is on the factory's ABI and an integrator can read it.

```
VESTED_TREASURY_WEIGHT() (public ABI) : 2500
what that constant implies            : 2,500,000.000000000000000000
what the treasury ACTUALLY receives   : 2,800,000.000000000000000000   <- 300,000 GOV apart
client's own test suite               : 55/55 PASS                     <- the mutation is invisible
```

**Masking pattern 4/6 (SKILL Phase 7):** the residual is a `min`-shaped absorber. It guarantees the
fixed-supply invariant (correctly — VN-2) at the cost of guaranteeing that a weight error can never be
detected. The client's `_assertAllocation` helper (`test/CoinDAOFactory.t.sol:385-396`) checks
`immediateAllocation` and `coinStakingRewards` against **hardcoded literals** `500` and `6_500` rather
than the constants, and never checks `treasuryVested` against `2_800` at all.

**Fix — both modes priced.**
*Option A.* One `assert` in `allocationFor`, or a compile-time check, that the three weights sum to
`ALLOCATION_WEIGHT_TOTAL`; and assert `treasuryVested == remaining * VESTED_TREASURY_WEIGHT / TOTAL`
after the residual is computed.
- *Prevents:* the documented split and the paid split diverging silently.
- *Creates:* the residual exists to make the fixed supply exact; a strict equality would reintroduce
  dust. The correct form is `assert(weights sum)` **plus** keeping the residual — i.e. two lines and no
  behaviour change.
*Option B.* Delete `VESTED_TREASURY_WEIGHT`.
- *Prevents:* an integrator reading a number that is not connected to the money.
- *Creates:* the 65:5:28 ratio in the L281-282 comment then appears in no machine-readable form at all.

**Recommendation: A.** This is one of the few genuinely one-sided fixes in the tree.

---

## SP4-009 — **EXTENDS FP3-001 Option C** — the launch record is 14 addresses and zero amounts; the honest and the capturing configuration are indistinguishable on chain

**Severity: MEDIUM (it is the precondition for anyone noticing anything above)** · `CoinDAOFactory` L100-117, L127-143, L497-514
**Verification: Method B — `test_SP4_008_launchRecordsNoAmountAndNoImmediateRecipient`, PASS, plus
explicit greps for the negative. Level 4.**

**Coupled pair:** the allocation actually performed ↔ the registry/event record of it.
**Invariant:** a third party must be able to determine, from chain state, where the fixed supply went.
**Broken: only one side is written.**

Absence claims, each grepped for the negative:

- `struct Deployment` — **14 address fields, 0 `uint` fields.**
- `deployments[i]` is **never written after the initial `push`** (grep `deployments\[` in
  `CoinDAOFactory.sol` → **zero** hits).
- `CoinDAODeployed` carries 12 addresses; `CoinDAOAttached` carries 3. **No event in `src/` names a
  recipient or any amount** (grep over all `event` declarations for `recipient|bps|amount|allocation`
  → only two *error* declarations match, never an event).
- `immediateRecipient` exists at exactly **two** lines (L491, L493) and is a local.

Executed side by side:

```
launch A (recipient = launcher)  : deployerVesting == address(0)   timelock GOV = 0
launch B (recipient = address(0)): deployerVesting == address(0)   timelock GOV = 500,000
```

**Identical registry shape. Opposite destination for 5% of supply.** The only observable proxy —
`deployerVesting == address(0)` — is **true on both**. On the capturing branch there is *no on-chain
artifact whatsoever* naming the private recipient, other than a raw ERC-20 `Transfer` log that an
indexer must be told to look for. `deployerStakeBps` is not stored, so the split cannot be recomputed
either.

This is FP3-001's Option C, restated as a state-coupling defect and evidenced. It remains the
recommendation, unconditionally.

---

# 5. Verified negatives (recorded so no later pass re-derives them)

| ID | Hypothesis | How it was killed | Verdict |
|---|---|---|---|
| **VN-1** | The genesis position is flash-loanable: borrow GOV, stake, checkpoint, unstake, repay, all atomically. | `test_SP4_007_VN_sameBlockDepositAndWithdrawLeavesNoVotingCheckpoint`, L4. `ERC20Votes` checkpoints key on `clock()`; a mint and a burn in the same block **overwrite the same checkpoint**, so `getPastVotes(borrowBlock) == 0` and `getPastTotalSupply(borrowBlock) == 0`. **Control included:** the same amount held across a block boundary checkpoints at the full 500,000. | **SOUND** — same-block rental confers nothing. The residual (custody at two block heights ~7,200 apart, per SP4-007) is a *lead*, not this finding. |
| **VN-2** | Some `deployerStakeBps` leaves GOV stranded in the factory or breaks the fixed-supply identity across the five paths. | `test_VN2_fixedSupplyIsExactOnEveryLegalBpsAndTheFactoryRetainsNothing`, L4. `_sum(allocationFor(b)) == 10,000,000e18` for all 2001 legal values, and on real launches at `bps ∈ {0,1,2000}` the factory retains **0** and every wei is placed. | **SOUND** — the residual-to-treasury line is correct. |
| **VN-3** | Some path mints or burns stGOV without touching the quorum base. | ABI-verified. `StakedGovToken`'s complete non-view surface is `approve, delegate, delegateBySig, depositFor, getReward, harvestAndGetReward, harvestAndWithdraw, initialize, notifyRewardAmount, permit, transfer, transferFrom, withdraw, withdrawTo`. Mint = `depositFor` only; every burn routes to `withdrawTo`. `transfer`/`transferFrom` always revert `NonTransferable` (L180-182). Grep for `_mint\|_burn\|_recover\|rescue\|sweep\|Ownable` in `StakedGovToken.sol` → **zero hits**. | **SOUND** — L5 has no back door. Confirms Pass 3's FP3-004 premise on this pass's own terms. |

---

# 6. Fix survival: does anything proposed against the governance findings survive this chain?

| Proposed fix | Origin | Survives? | Evidence |
|---|---|---|---|
| Absolute quorum floor | FF-01 / SI-003 Option B | **NO** | SP4-005, L4 — cleared below 500,000; permanent deadlock above it, unrepairable |
| Raise the quorum numerator | implied by FF-01 | **NO** | SP4-004, L4 — even n = 999 is met by the sole staker at genesis |
| `_validate`: reject `recipient != 0` when `bps == 0` | **FP3-001 Option A** | **NO** | SP4-004(c), MUT-A, L4 — defeated by `bps = 1` for **51.02 GOV**; costs 1 client test |
| Reject `deployerRecipient == address(this)` | FF-05 | no (orthogonal) | the launcher's own address is the intended value |
| Minimum-TVL gate on `fundNextTranche` | FF-001 / FF-003 / SI-002 | no | already measured by Pass 3 (M-B); touches emissions, not the allocation |
| Drop `fundNextTranche()` at L487 | FF-02 | no | already measured by Pass 3 (M-A) |
| Vest the immediate allocation when paid to a private recipient | **FP3-001 Option B** | **the only surviving candidate** | not defeated by anything in this pass — see below |
| Emit the recipient and the amounts | FP3-001 Option C / **SP4-009** | survives (it prevents nothing, but it is the precondition for anything) | SP4-009, L4 |
| Override `renounceOwnership` on the vesting wallets | FP3-006 Option A / SI-005 | orthogonal, still recommended | Pass 3 |

### Where the fix must be placed instead — stated plainly

**Not at the quorum link (L7).** SP4-003 shows L7's denominator *is* the attacker's deposit; SP4-004
and SP4-005 show no parameter and no floor separates them. A fix at L7 cannot work in principle, not
merely in practice — you cannot bound a quantity by a fraction of itself.

**Not at the recipient predicate (L2).** SP4-004(c) measured that: gating the *identity* of the
recipient costs the attacker 51 GOV, because the amount is a function of a different parameter that
remains free.

**The fix must be at L3 — the *amount* of liquid, unvested GOV that may reach a caller-supplied
address at launch.** That is the only link in the chain where the value is (a) bounded, (b) known at
launch time, (c) not yet in anyone's hands, and (d) governed by the factory rather than by a
parameter the caller chooses. Concretely, either of:

- **Vest it** whenever the destination is not the Timelock (FP3-001 Option B) — the launcher's liquid
  genesis holding becomes ~0 and SP4-002's ledger reads "the launcher holds 0% of the free supply".
  *Creates:* the "immediate allocation" stops being immediate, and the economics may already have been
  promised to deployers. **A product decision, not an audit one** (Pass 3's Q-5 is still open).
- **Cap the liquid-to-private amount** at some absolute figure well below the proposal threshold
  (10,000 GOV), routing the remainder to the Timelock. *Prevents:* genesis self-sufficiency at any
  `bps`, because the cap is on the amount rather than on the parameter that produces it — so the
  `bps = 1` workaround does not exist. *Creates:* a new constant that must be justified, and it changes
  the deployer economics less than full vesting does.

**Either way, SP4-009's Option C should ship unconditionally and immediately: it costs nothing,
prevents nothing, and is the only thing that would let anyone outside the launch transaction see which
configuration was used.**

---

# 7. Re-gradings this pass recommends

Each is a **premise correction**, not a new claim.

| Finding | What should change | Why |
|---|---|---|
| **FF-01** (HIGH) | Keep HIGH. **Retire the quorum remedy entirely.** Pass 3 replaced the cost basis (10,000 → 500,000); this pass shows *no* numerator and *no* floor works at any value, and that the floor's failure mode above the line is a permanent, unrepairable deadlock. | SP4-004, SP4-005, L4 |
| **FP3-001** (HIGH by composition) | Keep. **Withdraw Option A.** Measured here at a 51.02 GOV cost to the attacker and 1 failing client test. **Promote Option C to unconditional and immediate** (it is now evidenced as SP4-009). Option B or an absolute liquid cap is the only surviving remedy. | SP4-004(c), SP4-009, L4 |
| **FF-011** (LOW) | **Raise to MEDIUM.** It is not an accounting quirk: SP4-006 shows the only working brake in the entire chain is the delegated against-vote, and the design's own revenue incentive recruits stakers who never delegate. | SP4-006, L4 |
| **FF-002** (governance) | Unchanged; add that the desync runs to the **end** of the chain — the router is seized by an address holding zero GOV and zero stGOV. | SP4-007, L4 |
| **FF-07** (dead `VESTED_TREASURY_WEIGHT`) | Keep LOW but **restate**: it is not merely dead, it is a **coupled constant with no reader**, and the residual guarantees a divergence between the ABI and the money can never fail a test. Demonstrated at a 300,000 GOV divergence with 55/55 green. | SP4-008, L4 |
| **SI-002 / FP3-002** | Unchanged. Add that they now also determine the *emission* half of SP4-005's floor analysis: the launcher heads the only GOV stream that could ever meet a floor. | composition |

---

# 8. Coverage and honesty statement

- **Links in the chain mapped:** 8 (§1), each with its owning storage named.
- **Mutation paths analysed:** 12 rows (§2), including three `???` cells resolved by ABI + grep.
- **Parallel paths compared:** the 5 allocation destinations across 8 attributes (§3).
- **New findings:** 7 (SP4-001, -002, -003, -004, -005, -006, -008) + 2 EXTENDS (SP4-007, SP4-009).
  **3 verified negatives.** **0 false positives** — every finding is executed.
- **Fixes evaluated by execution rather than by argument:** 2 (FP3-001 Option A as MUT-A; the absolute
  quorum floor as `FlooredQuorumGovernor`), each with its own mutation control proving the fix bit
  before the attack was re-run against it. A third (the quorum numerator) was swept parametrically
  across 7 values with a resolution control.
- **Verification levels:** **Level 4** for every finding and every verified negative. **No Level 2
  substitutions were needed in this pass** — unlike FP3-002, nothing here depends on external Monolith
  behaviour.
- **Controls, so the checks could have failed:** `test_SP4_005_control_…` (the binding numerator is
  vacuous at genesis), `test_SP4_010_control_…` (delegated against-votes DO defeat the proposal),
  `test_MUT_A_control_…` (the fix rejects the shape it targets), the `assertGt(quorum, 0)` resolution
  guard on every floor/numerator read, and the held-block control inside VN-1.
- **A green check that had no resolution, caught and recorded:** the first draft of SP4-004/-005 read
  `quorum()` before the probe Governor's numerator checkpoint existed and passed on `0 >= 0`. Recorded
  in the environment section because this pass's subject is exactly that failure mode.
- **What I did NOT do.** I did not re-audit anything Pass 2 cleared, did not rebuild any prior pass's
  mutation matrix, and did not re-derive FP3-001 or FP3-002 — both are taken as established and are
  cited, not re-proved. I did not read `[scratch]` or `engagements/`. I did not attempt the
  product question in Pass 3's Q-5; §6 puts the remaining decision to the client rather than answering
  it.
- **Scope honesty on SP4-005.** The deadlock is proven with no Coin stakers. With a live market the
  emission stream eventually produces free GOV; the finding's claim is bounded to genesis plus the
  observation (from FP3-002, not re-derived) that the launcher heads that stream.
- **Client code was not modified.** All experiments ran on disposable copies. `git status --porcelain
  [scratch]` and `git diff --stat -- [scratch]` are both empty, and `diff -rq` of `src/` and `script/`
  against the working copy reports **IDENTICAL**.

---

# 9. PoC index

| Test | File | Asserts |
|---|---|---|
| `test_SP4_001_immediateAllocationIsMaximalWhereTheRecipientIsUnchecked` | `…/pass4/test/audit/StatePass4.t.sol` | monotone over 2001 bps values; max 500,000 at the unchecked branch |
| `test_SP4_002_immediateAllocationIsAllOfTheFreeGovAtGenesis` | same | full 10,000,000 ledger; 9,500,000 encumbered; timelock 0 |
| `test_SP4_003_quorumRisesByOneThousandthOfTheAttackersOwnDeposit` | same | d(votes)/d(quorum) = 1000; d(surplus)/d(stake) = 0.999 |
| `test_SP4_003b_selfSufficiencyRisesWithTheAttackersOwnContribution` | same | 52.63× → 100× against a 4,500,000 honest float |
| `test_SP4_004_noQuorumNumeratorStopsTheGenesisAllocation` | same | 7-numerator sweep with a quorum-nonzero resolution control |
| `test_SP4_005_control_theBindingNumeratorIsVacuousAtGenesis` | same | **control** — n = 999 cleared by the sole staker |
| `test_SP4_006_voteQueueAndExecuteWithZeroRemainingStake` | same | router seized holding 0 GOV, 0 stGOV, supply 0 |
| `test_SP4_007_VN_sameBlockDepositAndWithdrawLeavesNoVotingCheckpoint` | same | **VN-1** + held-block control |
| `test_SP4_008_launchRecordsNoAmountAndNoImmediateRecipient` | same | identical registry shape, opposite 5% destination |
| `test_VN2_fixedSupplyIsExactOnEveryLegalBpsAndTheFactoryRetainsNothing` | `…/pass4/test/audit/StatePass4Supply.t.sol` | **VN-2** — 2001 values + 3 real launches, factory residue 0 |
| `test_SP4_009a_floorBelowTheGenesisAllocationIsCleared` | `…/pass4/test/audit/StatePass4Floor.t.sol` | floor 400,000 → Succeeded alone |
| `test_SP4_009b_floorAboveTheGenesisAllocationDeadlocksTheDao` | same | floor 1,000,000 → Defeated at genesis **and** after the full 4-year vest |
| `test_SP4_010_undelegatedHonestStakeRaisesQuorumAndStopsNothing` | `…/pass4/test/audit/StatePass4Stop.t.sol` | 4,500,000 undelegated → Succeeded |
| `test_SP4_010_control_delegatedAgainstVotesAreTheOnlyBrake` | same | **control** — same stake delegated → Defeated |
| `test_MUT_A_control_zeroStakeNamedRecipientIsNowRejected` | `…/pass4mutA/test/audit/FixEvalA.t.sol` | **mutation control** — FP3-001 Option A bites |
| `test_MUT_A_oneBasisPointRestoresTheEntireCapture` | same | **the fix costs the attacker 51.020408163265306123 GOV** |
| `test_MUT_A_theForcedVestingWalletHasNoCliffAndPaysOnDayOne` | same | 0.6849 GOV releasable after one day |
| `test_MUT_B_constantAndMoneyDisagreeSilently` | `…/pass4mutB/test/MutBProbe.t.sol` | ABI says 2,500,000; treasury gets 2,800,000; 55/55 green |

**Supporting mutant source:** `…/pass4/test/audit/FlooredQuorumGovernor.sol` (the absolute-floor
remedy), `…/pass4mutA/src/CoinDAOFactory.sol:_validate` (FP3-001 Option A),
`…/pass4mutB/src/CoinDAOFactory.sol:VESTED_TREASURY_WEIGHT` (weight drift).
