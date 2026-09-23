# NEMESIS Pass 3 — Feynman Auditor — TARGETED RE-INTERROGATION: DROPPED SCOPE QUALIFIERS

**Lens:** `.claude/skills/feynman-auditor/SKILL.md`, run **narrowly** — Category 4 (assumptions) and
Category 5 (boundaries), applied to one defect class rather than to the whole tree.

**This pass does not re-audit anything Pass 1 cleared.** Its entire scope is the failure mode
Pass 2 discovered in **SI-002**:

> One lens establishes *"on entry path A, condition X holds"* and correctly scopes it to A.
> A second lens takes X as a **premise** and grades the consequence. On entry path B, X is **FALSE**;
> the consequence there is worse; and the first lens's proposed fix does not close it.
> Both inputs were correct. The **composition** was wrong, because a **scope qualifier was dropped**
> when one finding became another's premise.

**Read before starting:** `state-pass2-seams.md` (SI-002 in full), `feynman-pass1-factory.md`,
`feynman-pass1-emissions.md`. Prior findings were applied at *verify* time, which is the correct
posture for a targeted pass: this pass is deliberately **primed**, because the target is the seam
between two already-written findings, not new discovery.

**Code read:** `[scratch]` (all 12 files, ~1,400 lines) and `[scratch]`.
`[scratch]` and `engagements/**` were **not** read. Library behaviour (OpenZeppelin v5
`Ownable`, `VestingWalletUpgradeable`, `GovernorVotesQuorumFraction`) was established **by execution
or by the compiled ABI**, never by reading the library.

---

## Execution environment and integrity

Disposable copies under the session scratchpad:
`…/[scratch]` (baseline + PoCs) and `…/[scratch]` (fix-evaluation mutants).

| suite | result |
|---|---|
| project baseline in the copy | **55/55 PASS** |
| project baseline + this pass's PoCs (`test/audit/FeynmanPass3.t.sol`) | **65/65 PASS** |
| this pass's PoCs alone | **10/10 PASS** |
| fix-evaluation mutants (`pass3mut`, `test/audit/FixEvaluation.t.sol`) | **3/3 PASS** |
| the client's own 55 tests **under both proposed fixes** (M-A + M-B) | **51 pass / 4 FAIL** — the cost of the fix, measured |

**`[scratch]` was not written to.** `git status --porcelain [scratch]` → empty;
`git diff --stat -- [scratch]` → empty, checked before and after.

**forge 1.5.1-stable**, so **SI-008 applies**: every roll/warp in this pass goes through
`vm.getBlockNumber()` / `vm.getBlockTimestamp()` or an absolute target read from the Governor.

**Verification levels** (workspace scale): **L1** compiles · **L2** a check passes · **L3** the check
could have failed (a control is included) · **L4** executed in a real EVM.

---

# 1. The branch inventory — every place the same downstream machinery is reachable under two or more preconditions

The assignment named six; interrogation found **eleven**. For each: what did somebody conclude on one
branch, does the qualifier survive on the other, and what happens where it does not.

```
+=====================================================================================================+
| #   | SHARED MACHINERY                | BRANCH A vs BRANCH B                 | QUALIFIER SURVIVES?   |
+=====================================================================================================+

B1  _deployCoinDAO (L350-521)          deploy()  vs  deployForExistingCoin()      NO -> SI-002 (Pass 2)
    Also NEW on this pair: B3/B9/B10 below all reach BOTH entries.

B2  StakingRewards + funder            stakingTokenChoice.Coin vs .SCoin          partly -> FF-06
    On deploy(): both tokens are created by the EXTERNAL Monolith factory in the same tx. The
    "provably zero supply" qualifier is asserted about `deploy()` as a whole, but only the
    Coin branch was ever measured. See Q-2 in section 5 (open question to the client).

B3  safeTransfer(immediateRecipient)   deployerRecipient == 0  vs  != 0           ***NO*** -> FP3-001
    L491-492. The 5% either funds governance or funds a private address, liquid, unvested,
    uncapped. Reachable on BOTH factory entries (proved on both).

B4  Phase-6 vesting clone creation     deployerStakeBps == 0  vs  != 0            YES (FF-08 covers
    L473-481. Zero -> no wallet, registry records address(0).                     the prediction gap)

B5  StakingRewards.notifyRewardAmount  first call (factory, L487, periodFinish=0) NO -> FP3-002
    reached via fundNextTranche        vs subsequent calls (permissionless)       (the qualifier that
                                                                                  was dropped is not
                                                                                  the one anyone named)

B6  notifyRewardAmount branch select   block.timestamp >= periodFinish (live)     YES — the else side
    L151 vs L153                       vs < periodFinish (dead)                   is unreachable, FF-002

B7  RevenueRouter.distribute()         govStaking.totalSupply()==0 vs !=0         YES on the value
    L72                                                                           question (FP3-004 VN)
                                                                                  NO on the rounding
                                                                                  question -> FP3-005

B8  StakedGovToken entry vs exit       depositFor (harvests) vs withdraw (does    NO -> SI-003 (Pass 2)
                                       not)

B9  lender.manager                     set + verified on deploy()  vs  INHERITED, NO -> FP3-003
                                       unnamed, unverified, unemitted on attach

B10 CoinDAOVestingWallet machinery     beneficiary = an EOA (monolith 2%,         ***NO*** -> FP3-006
    (renounceOwnership + release)      deployer 20%) vs = the TIMELOCK (28%)      the 28% case is 14x
                                                                                  larger and reachable
                                                                                  by ONE proposal

B11 script/DeployCoinDAO.s.sol         verifies the fresh path  vs  no attach     NO -> FP3-003 note.
    _verifyDeployment                  path exists in the script at all           Every off-chain check
                                                                                  is on the branch where
                                                                                  the defect cannot occur.
```

**The meta-observation, stated once because it explains four of the six findings below:**
in this system the *mitigations* are branch-scoped more often than the *findings* are. The zero-address
checks live on the entry that cannot produce a zero (FF-06). The manager verification lives on the
entry that names a manager (FP3-003). The `_verifyDeployment` post-conditions run only on the path the
deploy script supports (B11). A check placed on the branch where the defect is impossible is not a
check; it is a **reason nobody looked at the other branch.**

---

# 2. Findings

---

## FP3-001 — the liquid 5% escapes both limits that are documented as bounding the deployer, and by itself it is permanent unilateral control of the DAO from block zero

**Severity: HIGH by composition / MEDIUM standalone** · Module `CoinDAOFactory`
Lines **L491-493** (routing), **L556-563** (`_validate`), **L273-290** (`allocationFor`),
composed with `CoinDAOGovernor` **L64-70** and `CoinDAOFactory` **L33-34**.
**Verification: Method B — `test_FP3_001_liquidImmediateAllocationIsInstantUnilateralGovernance`,
`test_FP3_001b_immediateAllocationEscapesBothDeployerLimits`,
`test_FP3_001c_theSameLiquidFivePercentAlsoReachesTheAttachPath`, with the control
`test_FP3_001_control_zeroRecipientPutsTheSameFivePercentUnderGovernance`. All PASS. Level 4.**

### Feynman question that exposed it

> **Q4.3** — *"What does this function assume about the current state?"* asked of **FF-01**, not of the
> code. FF-01 grades governance capture at **0.1% of supply** — the proposal threshold. That number is
> an *acquisition cost*. It assumes the attacker must **buy or earn** GOV. On the
> `deployerRecipient != 0` branch the launcher is **handed 5%**, and the acquisition cost is zero.

### The two qualifiers that were dropped

Three separate places in this tree describe what the deployer may take, and **all three describe only
the vested half**:

1. `MAX_DEPLOYER_STAKE_BPS = 2_000` (L25) — "up to 20% of supply" (L279 comment).
2. `deployerVesting.initialize(deployerRecipient, vestingStart, FOUR_YEARS)` (L479) — a 4-year lock.
3. `_validate` (L560-562) — a recipient is **only required** when `deployerStakeBps != 0`.

The immediate allocation obeys **none** of them. It is governed by a different constant
(`IMMEDIATE_ALLOCATION_WEIGHT = 500` of `ALLOCATION_WEIGHT_TOTAL = 9_800`), is paid **liquid** in the
launch transaction, and is routed to `deployerRecipient` **whenever one is named — including when the
vested stake is zero**, which is precisely the case `_validate` does not police.

**Executed (L4):**

```
--- branch: deployerStakeBps = 0, deployerRecipient = launcher ---
GOV paid liquid to deployerRecipient : 500,000.000000000000000000     (5.00% of supply)
GOV held by the timelock at launch   :       0.000000000000000000     <- governance is funded with NOTHING
proposal threshold                   :  10,000.000000000000000000     <- the launcher holds 50x it
deployer vesting allocation          :       0.000000000000000000     <- no wallet, no lock, no cap engaged
d.deployerVesting                    : address(0)                     (asserted)

launcher wraps 500,000 GOV -> stGOV, self-delegates:
  launcher votes                     : 500,000.000000000000000000
  quorum at that timepoint           :     500.000000000000000000     <- getPastTotalSupply/1000
  launcher alone >= quorum           : true
  launcher alone >= threshold        : true

ONE proposal: revenueRouter.transferOwnership(launcher)
  state after voting                 : Succeeded
  RevenueRouter.owner()              : the launcher                   (asserted)
```

**The cap does not cap (L4).** At the documented maximum deployer stake:

```
bps = 2000 : vested  to deployerRecipient : 2,000,000.000000000000000000
bps = 2000 : liquid  to deployerRecipient :   397,959.183673469387755102
bps = 2000 : TOTAL   to deployerRecipient : 2,397,959.183673469387755102  = 23.98% of supply
             MAX_DEPLOYER_STAKE_BPS says  : 2,000,000                     = 20.00%
```

**It is not scoped to the fresh path (L4).** `test_FP3_001c` runs the identical launch through
`deployForExistingCoin` on a market that already has third-party users: the same 500,000 GOV reaches
the same private address and the timelock again receives zero.

**Control, so the check could have failed (L4).** `test_FP3_001_control_…`: the *identical* launch with
`deployerRecipient == address(0)` puts the same 500,000 GOV in the timelock and the same address
**cannot even call `propose()`** (reverts). The measurement discriminates the branch, not the setup.

### Engaging with the comment that exists (workspace rule)

L490 says: *"A missing deployer recipient sends only the liquid allocation to the timelock; vested
deployer stake is disallowed."* That comment is **accurate** and it means the routing is **deliberate**.
This finding is therefore **not** "the deployer should not get 5%". It is three things the comment does
not address:

1. **The 5% is described elsewhere as a system slice, not a deployer slice.** L281-282:
   *"The remainder is split using a 65:5:28 **staking/immediate/vested-treasury** ratio."* That sentence
   groups the 5% with the treasury, not with the deployer. Two comments in the same file describe the
   same number as two different parties' money. (Compounded by **FF-07**: `VESTED_TREASURY_WEIGHT` is
   dead and the 65:5:28 identity is asserted nowhere.)
2. **`_validate` polices the recipient only on the branch where the money is smaller.** A recipient is
   mandatory for the *vested* stake and optional for the *liquid* one. That is backwards with respect
   to immediacy of value.
3. **Nothing anywhere prices the governance consequence.** 5% liquid, wrapped, is not 5% of the vote —
   at genesis it is **100%** of it, because quorum is a fraction of the staked float and the staked
   float is whatever the launcher stakes.

### Why the severity is HIGH by composition

Standalone this is a launch parameter behaving as documented — **MEDIUM**. Composed with **FF-01**
(quorum = staked-stGOV/1000, which can never exceed the proposal threshold), it is a **cheaper, faster
and more certain route to total DAO capture than SI-002**:

| | SI-002 (Pass 2, HIGH) | FP3-001 |
|---|---|---|
| entry path | `deployForExistingCoin` only | **both** |
| precondition | launcher is the lender's incumbent operator | **none** |
| requires the external market to work | yes (must hold the staking token) | **no** |
| time to clear the proposal threshold | 1.73 days of emissions | **zero — same transaction** |
| visible in events | no | no |
| cost | 1 wei of Coin | **zero** |

What it buys is the same prize SI-002 buys: the Timelock, `RevenueRouter` ownership (100% of the
market's revenue split, `setManager`, and SI-005's permanent renounce), the 2,800,000 GOV treasury vest,
and every governance action in **SI-001**.

**I am not grading on the maximal claim.** A second staker dilutes the launcher's *share*, but not their
*head start*, and 500,000 stGOV is a very large float to out-stake. Flagged for adjudication with both
decompositions stated.

### Does any existing proposed fix close it? **No.**

| existing recommendation | closes FP3-001? |
|---|---|
| **FF-05** — reject `deployerRecipient == address(this)` | No — orthogonal; the launcher's own address is the *intended* value |
| **FF-01 / SI-003 Option B** — an absolute quorum floor | **No** — any floor below 500,000 stGOV is cleared by the launcher alone, and a floor above it makes the DAO unbootstrappable |
| **SI-002** — minimum-TVL gate on `fundNextTranche` | No — touches emissions, not the allocation |

### Fix — both failure modes priced

*Option A (smallest).* Extend `_validate`: require `deployerRecipient == address(0)` **whenever**
`deployerStakeBps == 0`, so the liquid 5% and the vested stake are the same decision.
- *Prevents:* the zero-stake/named-recipient combination, which is the shape where the cap and the
  vesting are both bypassed and nothing in the code hints that they were.
- *Creates:* it **removes a legitimate configuration** — a project that wants no vested stake but does
  want its launch costs reimbursed can no longer express that, and would be pushed to
  `deployerStakeBps = 1` (1,000 GOV vested) as a workaround, which is strictly worse documentation.

*Option B.* Vest the immediate allocation on the same 4-year schedule whenever it is paid to a private
recipient (reuse `deployerVesting`); keep it liquid only when it goes to the timelock.
- *Prevents:* the genesis governance capture **and** FP3-001's composition with FF-01, at the root.
- *Creates:* a launcher with no liquid GOV cannot pay for anything at launch, and the "immediate
  allocation" stops being immediate — which is the property its name asserts. It also changes the
  economics the project may have already promised to deployers. **This is a business decision, not an
  audit one.**

*Option C (do regardless).* Make the routing legible: emit `deployerRecipient` and
`immediateAllocation` in `CoinDAODeployed`, and reconcile the two comments (L281-282 vs L490) so the
5% has exactly one owner in the documentation.
- *Prevents:* nothing on its own. *Creates:* nothing. But **no integrator can currently tell from the
  chain whether a given CoinDAO shipped its 5% to governance or to a private key**, and that is the
  precondition for anyone noticing.

**Recommendation: C unconditionally; A or B is a product decision the client must make, and the report
should present it as one rather than as a patch.**

---

## FP3-002 — on the `deploy()` path the genesis emission is not burned; it is **captured, at the launcher's option**, and all three proposed fixes leave the capture intact

**Severity: HIGH by composition / MEDIUM standalone** · Modules `CoinDAOFactory` (L487) +
`StakingRewards` + `StakingRewardsFunder`
**Verification: Method B — `test_FP3_002_freshLaunchTrancheOneIsCapturedNotBurned` with the control
`test_FP3_002_control_thirtyIdleDaysBurnsTheSameGov`; fix evaluation
`test_MUT_bothFixesApplied_launcherStillCapturesTrancheOneAtomically` on a mutated tree, with two
mutation controls. All PASS. Level 4 for the mechanism; Level 2 for one substituted trigger, stated
below.**

### The exact qualifier that was dropped — and it is not the one anyone named

**FF-02 (factory lens):** *"On the `deploy()` path the staking token (Coin or sCoin) is created **in the
same transaction**, so its total supply at the moment the clock starts is provably zero: **nobody in the
world can stake**."*

**FF-001 (emissions lens):** the same premise, asserted at L4 —
`coin.totalSupply(): 0 (asserted -- nobody CAN stake)` — and the consequence graded as a **burn** of
5,787 GOV/day.

**SI-002 (Pass 2):** took that premise, found it false on `deployForExistingCoin`, and correctly wrote
up the capture **on that path only**.

**All three statements are true.** The composition is still wrong, because the premise
*"supply == 0 at the instant the clock starts"* is **not the discriminator between burn and capture**.
`rewardPerToken()` accrues on `block.timestamp`, not on transaction ordering. The real discriminator is:

> **how much time elapses between L487 and the first `stake()`** — and on the `deploy()` path the
> launcher controls that to **zero**, because nobody else can reach a `StakingRewards` clone that did
> not exist before their transaction.

"Nobody in the world can stake **at that instant**" is true. "Nobody can stake **before any time
passes**" is false, and it is the second one the burn conclusion needs.

### The emissions lens already executed the capture — and graded it as the *control*

`testControl_NoVacancyStrandsNothing` (FF-001): *"with the first stake in the same second the deploy
ends"*, the loss falls to 71,840,000 wei of division dust. That is not a control establishing a
resolution. **That is the attack, with the launcher's payout not measured.** Pass 3 measured it.

### Executed evidence (L4)

The launcher is a **contract**, so `deploy()` and `stake()` are **one transaction**:

```solidity
d = factory.deploy(salt, govParams, monolithParams, manager);   // L487 opens the clock here
MockERC20(d.stakingToken).mint(address(this), 1);               // <- SUBSTITUTED TRIGGER, see below
IERC20(d.stakingToken).approve(d.coinStakingRewards, 1);
StakingRewards(d.coinStakingRewards).stake(1);                  // 1 WEI, same transaction
```

```
StakingRewards.totalSupply() after the launch tx : 1                       (asserted)
StakingRewards.lastUpdateTime()                  : == block.timestamp      (asserted, zero elapsed)
tranche 1 size                                   : 2,112,500.000000000000000000 GOV
taken by the 1-wei launcher after 365 d          : 2,112,499.999999999968768000 GOV
GOV actually burned                              :         0.000000000031232000 GOV
```

**Control (L4)** — the *identical* launch, launcher idle for 30 days:

```
CONTROL taken after 30 idle days     : 1,938,869.863013698601472000 GOV
CONTROL destroyed by the idle window :   173,630.136986301398528000 GOV
```

That destroyed figure reproduces **FF-02's own headline number** (173,630.136986301367296) to within
dust. The two runs bracket the *same quantity*: **it is destroyed or it is taken, and the launcher
picks.** FF-001/FF-02 measured only the left column.

### The substituted trigger, stated plainly

`MockERC20.mint` stands in for *"the launcher can obtain one unit of their own brand-new market's Coin
or sCoin in the same block."* That is **external Monolith behaviour and I did not verify it** — Level 2
for the trigger, Level 4 for everything downstream of it. Two things make it strong rather than
speculative, and one makes it weaker:

- `deploy()` has **no access control** (grep-verified: `function deploy(` at L292, `external`, no
  modifier). Anyone may launch.
- `monolithParams` is **entirely caller-supplied** except `.operator` and `.manager`, which the factory
  overwrites (L304-305). `collateral`, `feed`, `collateralFactor`, `minDebt`, `psmAsset`, `psmVault`
  are the launcher's choice, so the launcher can construct a market they can immediately borrow from.
- **Weaker:** on the `deploy()` path the launcher also *owns* the market, so this is self-dealing with
  the project's own community-incentive allocation rather than theft from a third party. That is why I
  grade the standalone case MEDIUM and not HIGH.

**Question for the client (Q-1, section 5):** can the party who calls `MonolithFactory.deploy` obtain
any non-zero balance of the resulting Coin or sCoin **within the same block**?

### The fix evaluation — this is the part that matters

Three fixes have been proposed for the burn. I applied the two code-level ones **simultaneously** to a
mutated tree and re-ran the attack.

- **M-A** = **FF-02's** fix: delete `coinStakingRewardsFunder.fundNextTranche();` from `CoinDAOFactory.sol:487`.
  Control `test_MUT_A_launchNoLongerOpensTheTranche` PASS: `periodFinish == 0` and `nextTranche == 0`
  after a launch, so the mutation really took effect.
- **M-B** = **FF-001 / FF-003 / SI-002's** fix: a minimum-TVL gate inside `fundNextTranche`
  (`if (stakingRewards.totalSupply() < MIN_TVL) revert InsufficientTvl(...)`, `MIN_TVL = 1_000e18`).
  Control `test_MUT_B_gateBlocksAnEmptyPool` PASS: an empty pool now reverts `InsufficientTvl(0)`.

With **both** applied, one transaction:

```solidity
d = factory.deploy(...);                                      // clock NOT opened (M-A)
mint + approve + StakingRewards.stake(1_000e18);              // satisfies the gate (M-B) with the
                                                              // launcher's OWN units of its OWN market
StakingRewardsFunder(d.coinStakingRewardsFunder).fundNextTranche();   // launcher opens the tranche
```

```
minimum-TVL gate value                : 1,000.000000000000000000
StakingRewards.totalSupply()          : 1,000e18   == the gate, held ENTIRELY by the launcher (asserted)
funder.nextTranche()                  : 1          (opened inside the launch tx, asserted)
lastUpdateTime                        : == block.timestamp   (zero elapsed, asserted)
taken by the launcher WITH BOTH FIXES : 2,112,499.999999999968768000 GOV
```

**Identical to the unfixed capture, to the wei.** Both fixes are aimed at the burn; the burn and the
capture are the same missing coupling seen from opposite sides, and **a `totalSupply >= X` gate cannot
distinguish "the market has TVL" from "the launcher posted X of a token they can mint."** The gate's
cost is not the launcher's cost.

**Cost of those fixes, measured (L4):** under M-A + M-B, **4 of the client's 55 tests fail** —
`testCannotFundBeforePreviousTrancheFinishes`, `testCannotFundWithInsufficientBalance`,
`testPermissionlessFourTrancheLifecycleAssignsFinalDust`, and
`testFreshLaunchPredictsProxiesAndWiresCanonicalDeployment`. So the fixes are not free even in the
client's own terms, and they buy nothing against this branch.

**SI-002's own "minimum viable mitigation"** — *"on the `deployForExistingCoin` path only, do not call
`fundNextTranche()` at L487"* — is by construction silent about `deploy()`, and `test_FP3_002` shows
`deploy()` is exposed with L487 fully intact.

### What would actually close it

Nothing in the emission machinery, because the machinery is not what is broken. The property the design
wants is *"the first tranche streams to a market, not to its launcher"*, and that is a statement about
**who** is staked, not **how much**. Candidates, both modes priced:

*Option A.* A start delay: `fundNextTranche` for tranche 0 may only be called `N` days after
`deployments[i]` was recorded.
- *Prevents:* the atomic and same-block capture on both entry paths — the launcher loses exclusivity
  because the address is public for N days before the clock can open.
- *Creates:* N days of guaranteed dead time; the `deploy()`-returns-live property disappears; and it
  hands tranche 0 to a **public race** at a known instant, which is FF-003 at the boundary. It converts
  a certain private capture into an uncertain public one. That is an improvement, not a solution.

*Option B.* Require more than one distinct staker (or a staker that is not the launcher/deployment
creator) before tranche 0 opens.
- *Prevents:* the exact shape proven here.
- *Creates:* trivially Sybil-able (two addresses, one owner), so it buys **appearance** rather than
  safety — the worst outcome for an operator who trusts the guard. **Do not ship B.**

*Option C (the honest one).* Accept that the launcher gets the head start, and **make it visible**:
emit the staking-token total supply at L487 in `CoinDAODeployed`, and state in the documentation that
tranche 1 accrues from the launch block. Combine with FP3-001 Option C.
- *Prevents:* nothing mechanically. *Creates:* nothing.
- But it converts an invisible capture into a disclosed one, which is the only thing that reliably
  changes behaviour here.

**Recommendation: C, plus a decision on A. Explicitly not B. And do not ship M-A or M-B believing they
address this — they are measured above and they do not.**

---

## FP3-003 — the attach path inherits its lender `manager` silently, and every check that would have caught it lives on the branch where it cannot happen

**Severity: MEDIUM (lead — the power of `manager` is external and unverified)** ·
`CoinDAOFactory` L292-313 vs L315-346, `script/DeployCoinDAO.s.sol` L230-269
**Verification: Method B — `test_FP3_003_attachedMarketSilentlyKeepsItsIncumbentManager`, PASS, plus
explicit negative greps. Level 4 for the mechanism, Level 2 for the impact.**

### Feynman question

> **Q3.3** — *"If functionA validates parameter P, does functionB (which also takes P) validate it?"*
> Here the sharper form: **functionB does not take P at all.** `deploy()` has a `manager` parameter,
> requires it non-zero (L298), writes it (L305), and the deploy script asserts it afterwards.
> `deployForExistingCoin` has **no manager parameter, no check, no event, and no script**.

### Executed evidence (L4)

```
fresh   path: lender.manager() == the named `manager` argument           (asserted)
attach  path: lender.operator() == deployment.revenueRouter              (asserted -- the operator DID move)
attach  path: lender.manager()  == 0x…1005 (the market's incumbent)      (asserted -- INHERITED)
```

**Absence claims, each grepped for the negative:**
- `manager` in `src/`: **six hits**, all on the `deploy()` path or in the interface
  (`CoinDAOFactory.sol:296, 298, 305`; `IMonolith.sol:16, 37`) plus one comment in `RevenueRouter.sol:15`.
  `deployForExistingCoin` and `_deployCoinDAO` **never mention it**.
- `CoinDAOAttached` (L140) emits `id`, `lender`, `previousOperator` — **not the manager**. There is no
  on-chain record of who holds `manager` on an attached market.
- `script/DeployCoinDAO.s.sol` has **no `deployForExistingCoin` call path at all**; its
  `_verifyDeployment` requires `_managerOf(lender) == expectedManager` (L258) and
  `deployment.vault.code.length != 0` (L242) — **both of which are the checks the attach path needs and
  neither of which ever runs on it.**

### Why this is the same pattern

`RevenueRouter`'s own NatSpec (L13-15) says: *"Governance retains only the **manager** and revenue-split
controls."* That sentence is the qualifier. It is true on the fresh path, where governance chose the
manager. On the attach path governance **inherited** a manager it never chose, from the party who was
the market's operator immediately before the handoff — i.e. **the launcher**. The governance lens's
refutation of *"the Lender's manager is permanently an EOA"* rested on `RevenueRouter.setManager` being
reachable; **SI-005** already conditioned that on an owner existing. This is the second, independent
condition: **the manager governance is being asked to rotate may be the launcher's own address**, and
under FP3-001 or SI-002 the launcher also controls the Governor that would do the rotating.

### Honest limit

What `manager` can *do* is defined outside this repository. I did not verify it and I am not grading
impact. The defect I am grading is structural and fully in scope: **one entry path names, validates,
records and verifies a privileged external role; the sibling entry path does none of the four.**

### Fix — both modes priced

*Option A.* Give `deployForExistingCoin` a `manager` parameter and call `lender.setManager(manager)`
inside Phase 5, while the factory still holds `operator`.
- *Prevents:* the silent inheritance; makes the two entries symmetric.
- *Creates:* an extra external call whose failure now reverts an otherwise-valid attachment, and it
  **takes a decision away from the incumbent market's existing users**, who may have chosen that manager
  deliberately. On a mature market that is a real change of control, which is exactly what the current
  code avoids doing. Not obviously correct.

*Option B (cheaper, and the one I would ship).* Emit the manager in `CoinDAOAttached`, and add
`_managerOf` to a documented post-attachment checklist.
- *Prevents:* the invisibility, which is the half this repository can actually control.
- *Creates:* nothing.

*Option C (regardless).* The deploy script should support `deployForExistingCoin` and run the same
`_verifyDeployment`. Today the attach path — the higher-risk one, per SI-002 — has **zero** post-flight
verification.

---

## FP3-004 (VERIFIED NEGATIVE) — the anti-JIT defence also holds on the attach path, where the accrued reserve is largest

**Verification: Method B — `test_FP3_004_VN_firstHarvestOnAnAttachedMarketPaysTheTreasuryNotTheLauncher`,
PASS. Level 4.** Recorded because a refutation is a claim too, and because SI-002 established the attach
path is the dangerous one **without** checking this pair on it.

The suspicion: `deployForExistingCoin` attaches to a market that may hold years of accrued reserves. The
first `RevenueRouter.distribute()` pulls **all** of it. If the launcher can be staked at that instant,
they take it.

**They cannot, and the reason is structural.** `depositFor` is the **only** mint path for stGOV
(ABI-verified in Pass 2; re-checked here: `StakedGovToken` has no `mint`, no `_recover`, no owner —
grep for `ownable|owner|recover|rescue|sweep` in `StakedGovToken.sol` returns only `nonces(address owner)`
and one comment). `depositFor` carries `harvestYield`, which runs **before** the mint. Therefore
**the first harvest always observes `totalSupply() == 0`**, `distribute()` evaluates
`govStaking.totalSupply() != 0` as false, and the whole reserve goes to the treasury.

```
lender accrued reserves            : 1,000,000.000000000000000000 COIN
launcher deposits 1,000 GOV first  ->
  historical reserve -> timelock   : 1,000,000.000000000000000000   (asserted)
  historical reserve -> stGOV      :         0.000000000000000000   (asserted)
```

This **extends VN-6 / the FF-005 refutation to the branch they were not tested on**, and it is the one
place in this pass where the unqualified case is *not* worse. Worth stating positively in the report:
the modifier ordering on `depositFor` is load-bearing and correct, and it is the strongest piece of
defensive design in the tree.

---

## FP3-005 — the permissionless revenue lever redistributes at small stGOV supply and **destroys** at large supply

**Severity: LOW (mechanism proven; the economic precondition is a small or dormant market)** ·
`RevenueRouter.distribute()` L68-86 × `StakedGovToken.notifyRewardAmount` L168-174
**Verification: Method B — `test_FP3_005_permissionlessDistributeRoundsRevenueToZeroAtLargeSupply`,
PASS. Level 4.**

### Feynman question

> **Q4.6** — *"What if amount = 1 (dust)?"* asked of **FF-04 / FF-011**, which concluded that
> `distribute()` being permissionless is a **timing lever**: any party may force the accrued revenue to
> be credited to whoever is staked at that instant. That is a **redistribution** — bounded, and someone
> receives the value. The qualifier is *"the amount is large relative to the supply."*

At the other end, `rewardPerTokenStored += Math.mulDiv(reward, 1e18, supply)` truncates to **zero**
whenever `reward < supply / 1e18`. The Coin has already been transferred by then (L78 precedes L79), so
it lands in `StakedGovToken` **credited to nobody**, and the sole Coin outflow from that contract is
`_payReward` (grep-verified: `rewardsToken.safeTransfer` appears **once**, at L161). There is no owner
and no recovery. The lever stops redistributing and starts **destroying**.

**Executed (L4)** — stGOV supply 10,000,000e18, so the truncation floor is 1e7 wei; 20 harvests of
9,000,000 wei each:

```
coin wei pushed through distribute() : 180,000,000
coin wei now sitting in stGOV        : 180,000,000    <- transferred, stranded
rewardPerTokenStored delta           :           0    (asserted -- the index never moved)
earned(the only holder)              :           0    (asserted)
```

`RevenueRouter` has **no `nonReentrant` and no access control on `distribute()`** (grep-verified), so
the caller chooses the cadence. Anyone willing to pay gas can force every harvest to be small.

**Why LOW and not higher, said plainly.** For a market earning a realistic amount, the per-block accrual
far exceeds `supply/1e18` and no truncation occurs. The griefer needs a market whose accrual rate is
below roughly 1e-11 Coin per call at full stGOV participation — a dormant or very small market, or a
period of no borrowing. It is a real, permanent, permissionless loss with no floor, but it is not a
drain and it is not cheap to make material. **I am reporting it as a lead with the precondition stated,
not as a finding with an inflated severity.**

**Fix.** Accumulate the truncation remainder rather than discarding it: transfer only the value the
index actually credits and keep the residual in `RevenueRouter`, or track a residual in `StakedGovToken`.
- *Prevents:* the destruction; the dust simply rolls into the next harvest.
- *Creates:* a second accumulator in a contract that currently has exactly one, and a new invariant
  (`residual <= coin.balanceOf(this) - unpaid rewards`) that nothing would own. For a LOW, that may not
  be worth it — **the honest alternative is to document the floor and leave the code alone.** Say which
  was chosen.

---

## FP3-006 — the "a beneficiary can renounce and brick the allocation" finding was scoped to the 2% wallet; the same machinery on the 28% wallet is 14× larger and reachable by one proposal

**Severity: MEDIUM** · `CoinDAOVestingWallet` (all three clones) · `CoinDAOFactory` L456-481
**Verification: Method B — `test_FP3_006_oneProposalBricksTheTwentyEightPercentTreasuryVest`, PASS,
plus ABI verification. Level 4.**

### The dropped qualifier

The governance lens's **FF-003** established that a vesting-wallet beneficiary can call
`renounceOwnership()` and brick the allocation permanently. **SI-004** amplified it, and both did so in
the context of **`monolithVesting`** — beneficiary an EOA, allocation **200,000 GOV (2%)**, and the
implicit qualifier *"an EOA might lose or misuse a key."*

The **same three lines of machinery** back the `treasuryVesting` clone, whose beneficiary is the
**Timelock** and whose allocation is **2,800,000 GOV (28% of total supply)**. There the trigger is not a
lost key — it is **one passed proposal calling a function that reads as routine housekeeping**.

**ABI-verified (L4):** `CoinDAOVestingWallet`'s complete non-view surface is
`['initialize', 'release', 'renounceOwnership', 'transferOwnership']`. Grep for the negative:
`renounceOwnership` appears **exactly once** in `src/` — `CoinDAOFactory.sol:488`, on `StakingRewards` —
and there is **no override of `renounceOwnership` or `transferOwnership` anywhere in `src/`**. It is
live on all three vesting wallets and on `RevenueRouter` (that half is **SI-005**).

### Executed evidence (L4)

```
treasuryVesting balance at launch     : 2,800,000 GOV      (28% of supply, asserted)
treasuryVesting.owner()               : the Timelock       (asserted)
release(GOV) after 30 days            : SUCCEEDS           (permissionless, pays the timelock)
timelock GOV balance at that point    : 557,534.246575342465753424
                                        (= 500,000 immediate + 57,534.246575342465753424 vested)

one proposal: treasuryVesting.renounceOwnership()   <- passes, queues, executes, no revert
  treasuryVesting.owner()             : 0x0                (asserted)
  release(GOV) 365 days later         : REVERTS FOREVER    (asserted -- it would pay address(0))
  GOV frozen in the treasury vest     : 2,742,465.753424657534246576
  compare: the wallet FF-003 was scoped to : 200,000
```

**The failure mode is different in kind, not only in size.** On the 2% wallet the beneficiary renounces
and *that beneficiary* loses their money. On the 28% wallet the DAO renounces and **`release()` stops
being a payment and becomes a permanent revert** — the vesting stream does not merely stop, the function
that anyone could previously call to keep it flowing now reverts for everyone, forever, with 27.4% of
supply behind it. There is no admin outside the timelock (`CoinDAOFactory.sol:430` renounced
`DEFAULT_ADMIN_ROLE`, per SI-001), and `transferOwnership` is gone with the owner.

**Composition with SI-001, stated for the debrief:** SI-001's damage figure was *"2,228,571 GOV
permanently unspendable (28% of supply)"* after a botched `updateTimelock`, and it relied on the
vesting stream continuing to pour into a dead timelock. FP3-006 is the *other* way to reach a
comparable number, in **one call instead of a five-step migration**, and it is available to exactly the
attacker FP3-001 and SI-002 create.

### Fix — both modes priced

*Option A (the same shape as SI-005's).* Override `renounceOwnership()` in `CoinDAOVestingWallet` to
revert.
- *Prevents:* all three wallets bricking, including FF-003's original 2% case, which the governance
  lens raised and nothing has closed.
- *Creates:* almost nothing. There is no articulated scenario in this design where "a vesting wallet with
  no beneficiary" is a desired end state, and `transferOwnership` remains available for every legitimate
  rotation, including SI-001d's safe migration. **Like SI-005, this is a genuinely one-sided fix** — two
  lines, and the only loss is an option nobody has named a use for.
- *Caveat, because a one-sided fix is suspicious:* it is a change to a shared clone implementation, so it
  affects the deployer and Monolith wallets too. That is the intent, and FF-003 wanted it there anyway.

*Option B.* Leave the code and write the prohibition into the governance runbook.
- *Prevents:* it only if the runbook is read. **FF-013 (governance lens) already records that the tree
  contains no production runbook at all**, so today this option prevents nothing.

**Recommendation: A. And note that A also closes FF-003, which is currently open.**

---

# 3. Re-gradings this pass recommends for existing findings

Each is a **premise correction**, not a new claim. The originals were right about their own branch.

| finding | what should change | why |
|---|---|---|
| **FF-01** (factory + governance, HIGH) | keep HIGH; **replace the cost basis**. "0.1% of supply captures governance" is an acquisition cost that assumes the attacker buys in. Under FP3-001 the launcher is handed 5% for free, on both entry paths. Any quorum-floor fix must be priced against 500,000 stGOV, not against 10,000. | FP3-001, L4 |
| **FF-02** (factory, MEDIUM) | keep MEDIUM but **re-state the mechanism**: the loss is not "burned"; it is *burned or captured at the launcher's option*, same quantity. Its proposed fix (drop L487) is measured here as **not closing** the capture. | FP3-002 + M-A, L4 |
| **FF-001** (emissions, HIGH) | keep HIGH; **retire the premise** "nobody CAN stake" as the reason the emission is lost — it is true and not load-bearing. `testControl_NoVacancyStrandsNothing` is the attack, not a control. The proposed first-staker gate is measured here as **not closing** it. | FP3-002 + M-B, L4 |
| **FF-003** (emissions, MEDIUM) | unchanged, but note it applies to **tranche 0 on the `deploy()` path too**, not only tranches 2-4, once any of the proposed fixes defers tranche 0. | FP3-002 mutant, L4 |
| **FF-05** (factory, LOW) | keep LOW, but the sentence *"self-inflicted, no attacker gain"* is branch-scoped: it holds when `deployerRecipient` is a **mistaken** address and inverts when it is the launcher's **intended** address. | FP3-001 |
| **FF-06** (factory, LOW) | unchanged; add that the deploy script's `require(deployment.vault.code.length != 0)` — the check that would catch it — exists only on the branch where `vault` cannot be zero. | grep + script trace, L2 |
| **FF-003** (governance) / **SI-004** (LOW) | **raise the ceiling**: the renounce-bricks case was priced on a 200,000 GOV wallet. On `treasuryVesting` it is 2,742,465 GOV and reachable by one proposal. | FP3-006, L4 |
| **FF-04 / FF-011** (revenue) | unchanged; add that the permissionless `distribute()` lever **destroys** rather than redistributes once stGOV supply exceeds ~1e18 × the per-harvest amount. | FP3-005, L4 |
| **SI-002** (Pass 2, HIGH) | **unchanged and confirmed.** Its "minimum viable mitigation" should be re-worded: it removes the guaranteed head start *on the attach path only*, and `deploy()` is exposed with L487 intact. | FP3-002, L4 |
| **SI-005** (Pass 2, LOW) | unchanged; note that the identical one-sided fix applies to `CoinDAOVestingWallet`, and shipping both together is cheaper than either alone. | FP3-006 |

---

# 4. Branch pairs interrogated and found SOUND (recorded so no later pass re-derives them)

| pair | hypothesis tested | how it was killed | verdict |
|---|---|---|---|
| B4 `deployerStakeBps` 0 vs ≠0 | a bps ≠ 0 could still yield `allocation.deployerVesting == 0`, skipping the wallet while paying the allocation | `deployerVesting = 10_000_000e18 × bps / 10_000`; the smallest non-zero bps gives 1,000e18. The two branch predicates (`bps != 0` in `_validate`, `allocation.deployerVesting != 0` at L473 and L496) can never disagree. | **SOUND** |
| B6 `notifyRewardAmount` if/else | the else side could be reached and blow the `rewardRate <= balance/duration` guard | the funder gates on the **same predicate** one call earlier (FF-002). Confirmed by trace; `rewardsDistribution` is frozen to the funder at L486-488 and `setRewardsDistribution` is grep-verified to have exactly one call site. | **SOUND** (unreachable) |
| B7 first vs later `distribute()`, value | the launcher could be staked when the first harvest fires on an attached market | **FP3-004**, L4 — `depositFor` is the only mint path and it harvests first, so the first harvest always sees supply 0 | **SOUND** — verified negative |
| B2 Coin vs SCoin, token identity | `stakingToken == rewardsToken` (emissions FF-007) could become reachable | `stakingToken ∈ {lender.coin(), lender.vault()}`, `rewardsToken` is a fresh GovToken clone deployed in the same tx; and `deployForExistingCoin` gates the lender through `monolithFactory.isDeployed`. Not reachable. | **SOUND** |
| B1 key reservation ordering | the attach path reserves the key **after** external calls, so a reentrant launch could double-spend a key | `lender.operator()` / `pendingOperator()` are `external view` (staticcalls, cannot reenter); `_reserveDeploymentKey(key)` at L333 precedes the only state-changing external call, `acceptOperator()` at L341. Confirms Pass 2's R-3/R-5. | **SOUND** |
| B9 `CoinDAOAttached(deployments.length - 1)` | underflow if `deployments` were empty | `_deployCoinDAO` pushes before returning, so length ≥ 1 at L345 | **SOUND** |

---

# 5. Open questions for the client (each gates a severity, not a fix)

**Q-1 (gates FP3-002's severity).** Can the party who calls `MonolithFactory.deploy` obtain **any**
non-zero balance of the resulting Coin or sCoin **within the same block** — by borrowing against
collateral they chose, by a PSM mint, or by any seeding the factory performs? If **yes**, FP3-002 is
confirmed at Level 4 end to end. If **no**, FP3-002 degrades to a same-day rather than same-block head
start, which is still exclusive to the launcher but no longer atomic.

**Q-2 (gates a residual on B2).** Does `MonolithFactory.deploy` mint any initial supply of the returned
`vault` (sCoin) — dead shares, a seed, or anything satisfying `psmVaultMinTotalSupply`? If yes, the
"provably zero supply" premise fails on the **`deploy()` + SCoin** sub-branch for a second, independent
reason, and in favour of whoever receives those shares.

**Q-3 (gates FP3-003's severity).** What can the Lender's `manager` do? Specifically: can it change
rates, pause, seize, or alter the reserve split? The attach path inherits it unexamined.

**Q-4 (gates FP3-005).** What is the realistic per-block local-reserve accrual for a target market?
Below roughly `stGOV_supply / 1e18` Coin wei per harvest, revenue is destroyed rather than distributed.

**Q-5 (product, gates FP3-001 Option B).** Is the 5% "immediate allocation" intended as the deployer's
compensation or as the DAO's liquid treasury? `CoinDAOFactory.sol:281-282` says one thing and
`CoinDAOFactory.sol:490` does the other.

---

# 6. Coverage and honesty statement

- **Branch pairs enumerated:** 11 (§1). The assignment named six; five more were found by asking the
  same question of the vesting wallets, the lender manager, the router's rounding, the notify branch
  selector, and the deploy script.
- **Branch pairs where a qualifier does NOT survive:** 6 → FP3-001, FP3-002, FP3-003, FP3-005, FP3-006,
  plus SI-002 and SI-003 (Pass 2, not re-derived).
- **Branch pairs interrogated and found SOUND:** 6 (§4), each killed by trace or execution, recorded so
  they are not re-derived.
- **New findings:** 5 (2 HIGH-by-composition, 2 MEDIUM, 1 LOW) + 1 verified negative.
  **0 false positives** — every finding is executed.
- **Re-gradings recommended for existing findings:** 10 (§3), all premise corrections rather than new
  claims.
- **Fixes evaluated by execution rather than by argument:** 2 (FF-02's M-A and
  FF-001/FF-003/SI-002's M-B), applied **simultaneously** to a mutated tree. Both were confirmed to take
  effect by their own controls, and both were then measured to leave the capture **identical to the
  wei**. Their cost was also measured: 4 of the client's 55 tests fail.
- **Verification levels:** **Level 4** (executed in a real EVM) for FP3-001, FP3-001b, FP3-001c,
  FP3-002 + control, FP3-003, FP3-004, FP3-005, FP3-006 and all three mutation tests. **Level 2** for
  exactly one link — FP3-002's substituted trigger (the launcher obtaining one unit of a brand-new
  market's staking token), which is external Monolith behaviour, stated in the finding and raised as Q-1.
- **Controls, so the checks could have failed:** `test_FP3_001_control_…` (the other branch of the same
  launch cannot even propose), `test_FP3_002_control_…` (the same GOV is destroyed rather than taken, at
  FF-02's own headline number), `test_MUT_A_…` and `test_MUT_B_…` (each mutation demonstrably bites
  before the attack is re-run against it).
- **Absence claims, each checked by an explicit grep for the negative or by the compiled ABI:**
  `renounceOwnership` — **1** hit in `src/` (`CoinDAOFactory.sol:488`), **no override anywhere**;
  `transferOwnership` — **1** hit (L454), no override; `deployerRecipient` — **4** hits in `src/`, none
  of them a bound or an identity check; `manager` — **0** hits in `deployForExistingCoin` or
  `_deployCoinDAO`; minimum-TVL / minimum-supply gate — **0** hits anywhere in `src/`; `distribute()` —
  `external`, no modifier, and `RevenueRouter` imports no `ReentrancyGuard`; `rewardsToken.safeTransfer`
  in `StakedGovToken` — **exactly one** call site (L161); `StakedGovToken` is not `Ownable` and has no
  recover/rescue/sweep; `CoinDAOVestingWallet`'s non-view ABI is exactly
  `initialize, release, renounceOwnership, transferOwnership`; `deploy` and `deployForExistingCoin` carry
  **no access modifier**.
- **What I did NOT do.** I did not re-audit anything Pass 1 cleared, and I did not rebuild any Pass-2
  agent's mutation matrix. I did not read `[scratch]` or `engagements/`. I did not verify any
  external Monolith behaviour — Q-1 through Q-4 are the places that matters, and each is marked in the
  finding it gates. I did not attempt to answer the *product* question in FP3-001 (Q-5); the report
  should put it to the client rather than answer it.
- **Client code was not modified.** All experiments ran on disposable copies under the session
  scratchpad. `git status --porcelain [scratch]` and `git diff --stat -- [scratch]` are both empty; the
  55/55 baseline was re-verified in the copy before and after.

---

# 7. PoC index

| test | file | asserts |
|---|---|---|
| `test_FP3_001_liquidImmediateAllocationIsInstantUnilateralGovernance` | `…/pass3/test/audit/FeynmanPass3.t.sol` | 500,000 GOV liquid; timelock 0; launcher ≥ quorum and ≥ threshold alone; router seized by one proposal |
| `test_FP3_001_control_zeroRecipientPutsTheSameFivePercentUnderGovernance` | same | the other branch: timelock holds the 5%, the launcher cannot `propose()` |
| `test_FP3_001b_immediateAllocationEscapesBothDeployerLimits` | same | 2,397,959 GOV to the deployer at the "20% cap" |
| `test_FP3_001c_theSameLiquidFivePercentAlsoReachesTheAttachPath` | same | identical routing through `deployForExistingCoin` |
| `test_FP3_002_freshLaunchTrancheOneIsCapturedNotBurned` | same | 2,112,499.99999999996 GOV captured atomically on `deploy()` |
| `test_FP3_002_control_thirtyIdleDaysBurnsTheSameGov` | same | 173,630.13 GOV destroyed instead — same quantity, launcher's choice |
| `test_FP3_003_attachedMarketSilentlyKeepsItsIncumbentManager` | same | manager inherited on attach, named on fresh |
| `test_FP3_004_VN_firstHarvestOnAnAttachedMarketPaysTheTreasuryNotTheLauncher` | same | 1,000,000 COIN historical reserve → treasury, 0 → stGOV |
| `test_FP3_005_permissionlessDistributeRoundsRevenueToZeroAtLargeSupply` | same | 180,000,000 wei stranded, index delta 0 |
| `test_FP3_006_oneProposalBricksTheTwentyEightPercentTreasuryVest` | same | 2,742,465 GOV frozen, `release()` reverts forever |
| `test_MUT_A_launchNoLongerOpensTheTranche` | `…/pass3mut/test/audit/FixEvaluation.t.sol` | mutation control: FF-02's fix took effect |
| `test_MUT_B_gateBlocksAnEmptyPool` | same | mutation control: the min-TVL gate bites |
| `test_MUT_bothFixesApplied_launcherStillCapturesTrancheOneAtomically` | same | **both fixes applied, capture unchanged to the wei** |
