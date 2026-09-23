# NEMESIS Pass 4 — State Inconsistency Auditor — TARGETED: propagating Pass 3's root causes

**Lens:** `.claude/skills/state-inconsistency-auditor/SKILL.md`, run as a **targeted** propagation, not
a re-audit. Phase 1 (coupled-pair map), Phase 3B/5 (parallel paths), Phase 4 (ordering) and Phase 8
(verification) are the phases actually applied. Phase 2's within-contract mutation matrices belong to
the Pass-2 lane agents and were **not rebuilt**.

**Assignment.** Pass 3 produced two root-cause statements. This pass traces each through every code
path and reports the coupled pairs they affect that nobody has mapped.

> **RC-1** — *"The launch transaction spends every authority it creates… Every repair path runs through
> the timelock, whose only admin is itself."*
> **RC-2** — *"The mitigations are branch-scoped more often than the findings — … the whole deploy-script
> verification all live on the branch where the defect cannot occur."*

**Scope read:** `[scratch]` (all 12 files) and `[scratch]` (both files), in
full. **Not read, per assignment:** `[scratch]`, `engagements/**`. OpenZeppelin behaviour
below was established **by execution or by an ABI-derived interface**, never by reading library source.

**Prior work read before writing (verify-time enrichment, per `CLAUDE.md`):** `state-pass2-seams.md`
(in full), `feynman-pass3-irreversibility.md` (in full), `feynman-pass3-composition.md` (in full), plus
the finding indexes and the relevant sections of `state-pass2-emissions.md`, `state-pass2-registries.md`,
`state-pass2-revenue.md`, `feynman-pass3-masking.md`, `feynman-pass3-inherited.md`,
`feynman-pass1-governance.md`, `feynman-pass1-factory.md`. **Where a pair or a guard is already owned I
cite it and do not re-derive it**; the censuses below record it so the maps are complete, and the
Findings section contains only what is new.

> ⭐ **Two candidate findings were killed by that reading, and both are recorded rather than hidden**,
> because the corpus check is the load-bearing step of a fourth pass — see §6, K-1 and K-2.

---

## 0. Execution environment and integrity

Disposable copies under the session scratchpad: `…/[scratch]` (unmodified source + this pass's
PoCs) and six single-line mutants `…/[scratch], m429, m430, m454, m463, m488`.

| tree | contents | suite |
|---|---|---|
| `p4` | unmodified source + `test/audit/StatePass4.t.sol` (6) + `StatePass4Window.t.sol` (3) | **64/64 PASS** (55 project + 9) |
| `p4` baseline before the PoCs | unmodified | **55/55 PASS** |
| `m428 … m488` | one deleted/changed authority line each + the same PoC files | see §4, SP4-002 |

**`[scratch]` was not written to.** `git status --porcelain [scratch]` and `git diff --stat --
[scratch]` are both empty; `diff -rq` of `src/` and of `script/` against the copy is clean; the audited
tree re-verified **55/55** at the end.

PoCs preserved at `.audit/poc/StatePass4.t.sol` and `.audit/poc/StatePass4Window.t.sol`; drop them into
`test/audit/` of a copy of the tree to reproduce. They depend only on the project's own
`test/helpers/CoinDAOTestBase.sol`, `test/mocks/MockERC20.sol` and `script/DeployCoinDAO.s.sol`.

Verification levels use the workspace scale: **L1** compiles · **L2** a check passes · **L3** the check
*could have failed* (a control is included) · **L4** executed in a real EVM.

**Harness traps honoured.** Every warp target is absolute and read from the contract
(`sr.periodFinish()`) or computed from `vm.getBlockTimestamp()` captured once; no `vm.roll` is used;
no `vm.expectRevert` is followed by an argument list containing a non-reverting call (the three
`expectRevert` sites in `test_P4_003` are each followed by a single call whose arguments are locals).

---

# 1. RC-1 — THE FROZEN ↔ MUTABLE CENSUS

> *"For every piece of state that becomes immutable at launch, what OTHER state is coupled to it and
> remains mutable?"*

Every value that `_deployCoinDAO` writes once and can never write again, paired with the state it is
coupled to. **The last column is the whole point:** where the counterpart still moves, the pair
desyncs and the gap only widens. `OWNED BY` cites the finding that already owns the pair; **NEW**
marks the ones this pass adds.

### 1.1 Frozen ADDRESSES

| # | frozen value | set at | coupled counterpart | counterpart mutable? | status |
|---|---|---|---|---|---|
| F-1 | `RevenueRouter.treasury` | `:407` | `Governor._timelock` | **YES**, `updateTimelock`, 1 proposal | **FI-001 / FI-002** (Pass 3) |
| F-2 | `deployments[i].timelock` | `:502` | same | **YES** | SI-007 (seams) |
| F-3 | `monolithVesting._owner` | `:470` | `factory.monolithBeneficiary` | **YES**, `accept…`, any time | SI-004 (seams) / SI-001 (registries) |
| F-4 | `RevenueRouter.lender` | `:405` | `lender.operator` | **YES**, externally | SI-003 (seams) |
| F-5 | `RevenueRouter.lender` | `:405` | `lender.manager` | **YES**, and *inherited* on attach | FP3-003 (composition) |
| F-6 | `RevenueRouter.coin` | `:406` | `lender.coin()` | external, unverified | FF-017 (revenue) |
| F-7 | `StakedGovToken.revenueRouter` | `:400` | `RevenueRouter._owner` | **YES**, incl. renounce | SI-005 / FI-003 |
| F-8 | `StakedGovToken.rewardsToken` (Coin) | `:396` | `RevenueRouter.coin` | both frozen | **consistent** |
| F-9 | `RevenueRouter.govStaking` | `:408` | `StakedGovToken` (a clone) | no | **consistent** |
| F-10 | `StakingRewards.stakingToken` | `:441` | `deployments[i].stakingToken` | both frozen | **consistent** |
| F-11 | `StakingRewards.rewardsDistribution` | `:486`+`:488` | `StakingRewardsFunder` identity | frozen both sides, re-verified per call | **consistent** (VN-B) |
| F-12 | `StakingRewardsFunder.stakingRewards` / `.rewardsToken` | `:448` | derived from the callee | cannot disagree | **consistent** |
| F-13 | `Governor.token` (immutable) | ctor | `StakedGovToken` | address fixed; **its `revenueRouter` is F-7** | chain owned by SI-003 |
| F-14 | `CoinDAOFactory.monolithFactory` (immutable) | ctor | Monolith's live registry (`isDeployed`) | **YES**, externally, grows | I-1 (Pass 3); see G-13 below |
| F-15 | 6 `*Implementation` immutables | ctor | every existing clone | no upgrade path | I-1 (Pass 3) |
| F-16 | three `CoinDAOVestingWallet._owner` | `:463/470/479` | `release()` payee = `owner()` | **YES**, transfer **and renounce** | FF-003 / FP3-006 / FI-007 |

### 1.2 Frozen NUMBERS AND TIMES — the axis Pass 3's census did not cover

Pass 3's 30-transition census (`feynman-pass3-irreversibility.md` §2) enumerates *authority*. These
rows enumerate *quantities and clocks* frozen at launch. Five are owned; **one is not**.

| # | frozen value | set at | coupled counterpart | counterpart mutable? | status |
|---|---|---|---|---|---|
| N-1 | `GovToken` supply `10,000,000e18` | `:367` | `stGOV.totalSupply()` (the quorum base) | **YES**, permissionless, both ways | FF-001 / SI-003 |
| N-2 | `GOVERNOR_PROPOSAL_THRESHOLD` = supply/1000 | ctor | same | **YES** | FF-001 |
| N-3 | `govStakingBps` = `10_000` | `:409` | `RevenueRouter.treasury`'s share | **YES**, `setGovStakingBps` | revenue SI-007; arms F-1 |
| N-4 | `StakingRewards.rewardsDuration` = 365 d | `:441` | `StakingRewardsFunder.TRANCHE_COUNT` = 4 | both frozen, **in different contracts** | emissions A5 (one direction only) |
| N-5 | `StakingRewardsFunder.totalRewards` | `:448` | funder GOV balance (donatable) | **YES** | emissions GAP-04 / GAP-06 |
| N-6 | **`vestingStart + FOUR_YEARS`** ×3 | `:457/463/470/479` | **the emission program's realised horizon** | **YES — unbounded above, set by unprivileged callers** | ⭐ **NEW → SP4-001** |
| N-7 | `DEFAULT_TIMELOCK_DELAY` = 2 d (in the timelock's CREATE2 initcode) | `:376` | `timelock.minDelay` live value | **YES**, `updateDelay` | FI-008; address binding is **consistent** |
| N-8 | `MONOLITH_BPS` = 200 | pure | `monolithBeneficiary` | **YES** | SI-004 |

### 1.3 What the census says

Sixteen frozen addresses and eight frozen quantities. **Twelve of the twenty-four have a counterpart
that still moves.** Eleven of those twelve are already owned by Passes 1–3. The twelfth is **N-6**, and
it is the only one where *both* sides are times rather than addresses — which is why an authority-shaped
census could not see it.

**The shape RC-1 predicts, stated once:** in every one of the twelve, the frozen side is the side the
launch wrote and the moving side is the side a *later* actor controls. There is no pair in this system
where the mutable side was frozen and the frozen side kept moving — because the launch is the only
event that freezes anything.

---

# 2. RC-2 — THE GUARD-BY-BRANCH CENSUS

> *"Enumerate every validation, guard and verification, and map which branch each one is on. Then ask
> which branch actually needed it."*

`feynman-pass3-masking.md` already censused 35 defensive constructs across `StakingRewards`,
`StakingRewardsFunder`, `StakedGovToken` and `RevenueRouter`, on the **liveness** axis (*"delete it —
what breaks?"*). **This census is on a different axis (which branch) and covers the files that census
did not tabulate:** `CoinDAOFactory`, `CoinDAOGovernor`, `CoinDAOVestingWallet`, `GovToken`, and both
**scripts**. Rows from the four censused contracts appear only where the branch question adds something.

### 2.1 `CoinDAOFactory` — 17 guards

| # | guard | line | on which branch | which branch needed it | verdict |
|---|---|---|---|---|---|
| G-1 | `monolithFactory_ != 0 \|\| beneficiary_ != 0` | 165 | constructor | both | LIVE |
| G-2 | `implementation.code.length != 0` ×6 | 548 | constructor | — | **unfalsifiable after construction** — FF-007 |
| G-3 | pairwise-distinct implementations | 551 | constructor | a transposition reverts at `initialize` anyway | LIVE-but-cosmetic (FF-12) |
| G-4 | **`monolithFactory` gets NO `.code.length` check** | — | — | **the same branch as G-2** | ⭐ **7 constructor addresses, 6 checked**; the 7th is checked only in `script/` L199/L21 (INFO, see §4 note) |
| G-5 | `manager != address(0)` | 298 | **`deploy()` only** | attach inherits a manager unchecked | **FP3-003** |
| G-6 | `lender/coin/vault != 0` | 308 | **`deploy()` only** | attach reads both from the lender unchecked | **FF-06** |
| G-7 | `lenderAddress != 0` | 322 | attach only | `deploy()` has G-6 | consistent |
| G-8 | `monolithFactory.isDeployed(lender)` | 323 | attach only | `deploy()` has provenance | consistent by design |
| G-9 | `hasCoinDAO[lender]` pre-check | 324 | attach only | **duplicate of G-12** | belt-and-braces |
| G-10 | `msg.sender == lender.operator()` | 328 | attach only | n/a on `deploy()` | LIVE (kills R-5) |
| G-11 | `pendingOperator == address(this)` | 331 | attach only | n/a | LIVE |
| G-12 | `hasCoinDAO[deployment.lender]` | 358 | **both** | both | LIVE |
| G-13 | `usedDeploymentKeys[key]` | 529 | **both** | both | LIVE |
| G-14 | `deployerStakeBps <= MAX` | 274 **and** 557 | **both, twice** | once would do | **double-guarded** |
| G-15 | **`deployerStakeBps != 0 && deployerRecipient == 0`** | 560 | **the vested branch only** | **the liquid branch** | **FP3-001; and see SP4-003** |
| G-16 | `allocation.deployerVesting != 0` | 473 **and** 496 | same predicate twice | cannot disagree | SOUND (FP3 §4 B4) |
| G-17 | `pendingBeneficiary != 0` on set, none on accept | 255 / 263 | set only | accept cannot receive 0 | consistent (SI-011) |

**The row that matters is G-14 vs G-15.** The parameter with a hard numeric cap is validated **twice on
every path**. The parameter that decides who receives 5 % of total supply, liquid and unvested, is
validated **on the one branch where the money is smaller and skipped on the branch where it is larger**.
That is FP3-001 seen from the census rather than from the money.

### 2.2 The other `src/` files, branch axis only

| # | guard | on which branch | which branch needed it | verdict |
|---|---|---|---|---|
| G-18 | `RevenueRouter.setManager`: `newManager != 0` | the **rotation** branch | ✓ | LIVE |
| G-19 | `RevenueRouter.renounceOwnership()`: **no guard** | the **irreversible** branch | **this one** | ⭐ the contract rejects `address(0)` for a role it does *not* own and accepts `address(0)` for the owner it *does* — SI-005 / FI-003 |
| G-20 | `CoinDAOVestingWallet`: **no guard of any kind** (10-line wrapper) | — | `renounceOwnership` on a 28 %-of-supply wallet | FP3-006 / FI-007 |
| G-21 | `StakingRewards.setRewardsDistribution`: **no zero-check** | owner-only, called once at `:486` | would be catastrophic if reachable | ⭐ **unreachable — because RC-1's renounce at `:488` removed the owner.** The one missing zero-check in the system is neutralised by the very irreversibility that causes the other findings. Recorded as a verified negative, not a finding. |
| G-22 | `distribute()`: `govStaking.totalSupply() != 0` vs `StakingRewards`: nothing | the receiver that cannot lose value | the receiver that can | **already owned — FP3-02 (masking pass)**; see §6 K-1 |
| G-23 | `CoinDAOGovernor`: `quorumDenominator()` = 1000, no cap on `updateQuorumNumerator` | — | the numerator's own bound | FI-004 |
| G-24 | vesting `initialize(beneficiary)` reverts on `address(0)` (OZ `Ownable`) | reached **only** when `bps != 0`, i.e. only where G-15 has already guaranteed non-zero | the liquid path, which never reaches it | ⭐ **`deployerRecipient` is zero-policed twice on the branch where it is already implied and zero times on the branch where it is the only thing that matters** — see SP4-003 |

### 2.3 `script/` — 73 `require`s, and where they point

| group | count | branch | resolution |
|---|---|---|---|
| `DeployCoinDAOFactory.s.sol` preconditions (chain, Monolith code, key, beneficiary) | 4 | factory deployment | LIVE |
| `DeployCoinDAOFactory.s.sol` post-construction getters | 8 | factory deployment | reads back what it just passed in |
| `DeployCoinDAO.s.sol` chain / key / factory-code preconditions | 3 | `deploy()` | LIVE |
| `_preflight` external-dependency checks (WETH, feed, staleness, Monolith factory pin) | 12 | `deploy()` | **LIVE and good** — the pinned-constant pattern at L200 is the right shape |
| `_preflightImplementations` | 6 | `deploy()` | **cannot fail** — FF-007 |
| `buildGovParams` | 2 | `deploy()` | **replicates `_validate`'s branch scope verbatim** → SP4-003 |
| `buildMonolithParams` | 9 | `deploy()` | LIVE (bounds the external market's parameters) |
| `_verifyDeployment` (+ `_managerOf`) | 18 + 1 | `deploy()` | **16 cannot fail; 2 test the external lender; 0 test the authority model** → SP4-002 |
| `_verifyPredictedAddresses` | 10 | `deploy()` | LIVE (catches a factory/prediction mismatch) |
| **`deployForExistingCoin`** | **0** | — | **the script has no attach path at all** — FP3-003 Option C / B11 |

**Independently re-grepped (the negative, because absence claims are the dangerous ones):**
`hasRole`, `.owner()`, `balanceOf`, `PROPOSER`, `CANCELLER`, `DEFAULT_ADMIN`, `quorum`, `renounce` —
**zero hits in `script/`.** This confirms `feynman-pass1-governance.md` FF-006's grep independently.

### 2.4 What the census says

RC-2 holds on every branch pair it was tested against, and the census adds a **second regularity that
RC-2 does not state**:

> Where a parameter is guarded at all, it tends to be guarded **twice** (G-14, G-16, G-9, G-24, and
> `deployerStakeBps` across `_validate`/`allocationFor`/`buildGovParams`), and the duplication sits on
> the branch that was already safe. **The system's redundancy and its blind spots are on the same
> branch.** That is why counting guards does not detect the gap: the guarded branch looks *more*
> defended than average, not less.

---

# 3. RC-1 × RC-2 APPLIED TO PAIRS THE EARLIER PASSES MARKED **CONSISTENT**

> *"A pair that is consistent within one contract can still desync when a root cause acts across the
> boundary."* Each pair below was re-opened with both root causes in hand. Only one moved.

| pair | prior verdict | re-tested under | result |
|---|---|---|---|
| **VN-B / P7** `rewardsDistribution` ↔ funder identity ↔ owner | CONSISTENT, "frozen and self-enforcing" | RC-1 | **holds.** Both sides are frozen and the funder re-verifies the back-link on every call (`:76`). ⭐ Note for the report: this is the **only** per-call cross-contract re-verification in the system, and RC-1 has already made the mutation it guards impossible. The link that *can* still move (F-7, the router's owner) is re-verified nowhere. |
| **VN-B / P9** `totalRewards` ↔ funder balance ↔ allocation | CONSISTENT | RC-2 | **holds.** `allocation.coinStakingRewards` reaches `initialize` (`:448`) and `safeTransfer` (`:485`) as the *same expression*; no branch separates them. |
| **VN-C / P14** five allocations sum to `10,000,000e18` | CONSISTENT | RC-1 + RC-2 | **holds, and is exact on every branch.** `treasuryVested` is computed by subtraction and the `deployerVesting` transfer is gated on the identical predicate as its creation (G-16). Re-measured at L4 in `test_P4_003` for the `bps = 0, recipient ≠ 0` cell that FP3-001 identified. |
| **VN-E / P17** the four registries | CONSISTENT | RC-2 | **holds.** Every write path is in one transaction; `hasCoinDAO` is checked on both branches (G-12). |
| **VN-A / P2** stGOV checkpoints | CONSISTENT | RC-1 | **holds.** `_update` blocks transfers, so the only balance-creating path is `depositFor`, which runs `updateReward(account)` before the mint — every holder's `userRewardPerTokenPaid` is therefore synced by construction. |
| **VN-D / R-1** Governor ↔ Timelock proposal state under direct execution | CONSISTENT | RC-1 | **holds** while `_timelock` is stable; already broken by SI-001b when it is not. |
| **B4 / B6 / B1 / B9** (FP3 §4) | SOUND | RC-2 | **hold.** Re-checked by trace; no new branch found. |
| **VN-F** "`distribute()` never strands Coin" | CONSISTENT | RC-1 + RC-2 | **already broken twice** — by FP3-005 (notify-side truncation) and now, a third way, by **SP4-004**: inside the Phase-5 window the router's harvest is paid to the *factory*, not the router, and the factory has no outflow. |
| **P8** `govStaking.totalSupply()` read at `RevenueRouter:72` ↔ `StakedGovToken:170` | CONSISTENT + masking | RC-2 | **holds**; the branch comparison is FP3-02's, not this pass's (§6 K-1). |

**One pair moved: VN-F.** Everything else survived. That is worth stating positively in the report —
the pairs the Pass-2 agents cleared were cleared correctly.

---

# 4. FINDINGS

---

## SP4-001 — **NEW** — the system has two four-year clocks; one is a deadline and the other is only a floor, and no contract can compare them

**Severity: LOW** · Modules `CoinDAOFactory` (`:36`, `:38`, `:457`, `:463`, `:470`, `:479`) ×
`StakingRewardsFunder` × `StakingRewards`
**Verification: Method B — `test_P4_001_bothFourYearClocksStartTogetherAndOnlyOneIsEnforced` PASS,
`test_P4_001b_atTheVestingDeadlineTheEmissionProgramCanStillBeUndelivered` PASS, with the control
`test_P4_001control_atTheEarliestCadenceTheTwoClocksCoincideToTheSecond` PASS. Level 4.**

### The coupled pair

```
FROZEN   : vestingStart = uint64(block.timestamp)        CoinDAOFactory.sol:457
           duration     = FOUR_YEARS = 365 days * 4      CoinDAOFactory.sol:36
           applied to all THREE vesting wallets          :463, :470, :479

MOVING   : the emission program's realised horizon
           = 4 x COIN_STAKING_REWARD_DURATION            CoinDAOFactory.sol:38
             + the three inter-tranche delays chosen by whoever calls fundNextTranche()
```

**Invariant the design plainly intends:** the two describe the same four-year distribution.
`4 x 365 days == FOUR_YEARS` **exactly**, and the first tranche is opened inside the launch
transaction (`:487`), so both clocks provably start on the same second.

**Asserted at L4:**

```
launch timestamp                 : 1
treasuryVesting.start()          : 1     == monolithVesting.start() == deployerVesting.start()
StakingRewards.lastUpdateTime()  : 1     <- the emission clock opened in the same second
vesting deadline (all 3 wallets) : 126144001      (launch + FOUR_YEARS)
earliest emission completion     : 126144001      (launch + 4 x rewardsDuration)   <- IDENTICAL
```

### The break

`fundNextTranche()` requires only `block.timestamp >= periodFinish` (`StakingRewardsFunder.sol:73`).
There is **no deadline, no expiry and no incentive**: `FOUR_YEARS` is therefore an *upper bound* on the
insiders' vesting (they are fully paid at 1,460 days, by a permissionless `release()` nobody can stop)
and only a *lower bound* on the community emission.

**Control first, so the check has resolution (L4).** With every tranche opened at the earliest legal
instant:

```
CONTROL emission end             : 126144001
CONTROL vest deadline            : 126144001        <- the two clocks coincide to the second
```

**Then the same launch with each tranche opened 180 days late — a delay nothing forbids (L4):**

```
--- at launch + FOUR_YEARS ---------------------------------
tranches funded                          : 3 of 4
insider GOV released (treasury)          : 2,514,285.714285714285714286
insider GOV released (monolith)          :   200,000.000000000000000000
insider GOV released (deployer)          : 1,000,000.000000000000000000
                                           ------------------------------
                                           3,714,285.71  = 37.1% of supply, fully delivered
GOV still sitting in the funder          : 1,021,428.571428571428571431   (the whole 4th tranche)
actual emission completion               : 157248001
vest deadline                            : 126144001
overrun                                  : 31,104,000 s  =  360 days
```

### Why this is a state finding and not a scheduling opinion

The skill's Phase 1 asks for *"anything stored at time T that is later used with a value from time
T+1."* `vestingStart` is stored at T; the emission's progress is determined at T+n by an unprivileged
caller; and **no contract can evaluate the identity that binds them.** `FOUR_YEARS` and
`COIN_STAKING_REWARD_DURATION` live in `CoinDAOFactory`; `TRANCHE_COUNT` lives in
`StakingRewardsFunder`. The factory never reads `TRANCHE_COUNT`, and the funder never sees
`FOUR_YEARS`.

**Absence claim, grepped explicitly:** `FOUR_YEARS` — 4 hits, all in `CoinDAOFactory`;
`COIN_STAKING_REWARD_DURATION` — 2 hits in `src/` (declaration + `:441`) and one test that only checks
it was passed through; `TRANCHE_COUNT` — 4 hits, all in `StakingRewardsFunder` plus one test asserting
it equals 4. **The identity `FOUR_YEARS == TRANCHE_COUNT * COIN_STAKING_REWARD_DURATION` appears in no
constant, no comment, no `require`, no event and no test.** No test anywhere relates a vesting schedule
to a tranche schedule.

### Engaging with the prior work that touches this

`feynman-pass1-emissions.md` **A5** records the *within-lane* half: *"tranches are 'yearly'… cadence is
`rewardsDuration`, owned by `StakingRewards`… the funder cannot tell."* That is the same blindness
one contract inward. This finding is the **cross-lane** half: neither the funder nor the vesting
wallets can see each other, and the constant that would reconcile them is split across two contracts
that never speak.

### Honest limits, stated plainly

- **The drift is not purely harmful.** Opening a tranche into an empty pool destroys GOV (FI-006), so
  *delaying* a tranche while the pool is empty preserves value. A rational staker funds promptly. The
  defect is that nothing makes promptness anyone's job, and the schedule the documentation implies is
  the one nobody enforces.
- **This is not a value-loss finding.** No GOV is destroyed by the delay itself; it is *deferred*. What
  desyncs is the relative delivery of the insider allocations (37.1 % of supply, on a clock nobody can
  stop) against the community allocation (58.4 % of supply, on a clock anybody can stall).
- **The governance consequence is where it bites.** stGOV voting weight derived from emissions is gated
  by the stallable clock; GOV in the deployer's wallet is not. Under **FP3-001** (the launcher's liquid
  5 %) and **FF-001** (quorum = staked stGOV / 1000) the party best positioned by a slow emission is
  the one that already holds a head start.

### Fix — both failure modes priced

*Option A (assert the identity).* One `require` in the factory constructor or in `_deployCoinDAO`:
`FOUR_YEARS == TRANCHE_COUNT * COIN_STAKING_REWARD_DURATION`.
- *Prevents:* a future change to any one of the three constants silently decoupling the two programs —
  which is the failure this pair is actually exposed to, since all three are compile-time constants
  today and correct today.
- *Creates:* nothing. It costs one comparison of constants and adds no runtime behaviour. **This is the
  half I would ship.**

*Option B (bound the cadence).* Give `fundNextTranche` a deadline — e.g. tranche *n* must be opened
within *K* days of the previous `periodFinish`, after which it opens automatically or the remainder is
redirected.
- *Prevents:* the drift itself.
- *Creates:* a new terminal state. Any deadline needs a destination for GOV that misses it, and the
  funder has **no owner and no rescue** (emissions GAP-06), so a missed deadline would strand exactly
  what it was meant to protect. It also removes the "delay while the pool is empty" behaviour that
  currently *saves* GOV. **Do not ship B without solving GAP-06 first.**

*Option C (documentation).* State that the four-year emission is a *minimum* duration, not a schedule,
and that its completion depends on unincentivised third-party calls.
- *Prevents:* nothing mechanically; it stops the client asserting a four-year program they do not
  control. *Creates:* nothing.

**Recommendation: A + C.** Explicitly not B on its own.

---

## SP4-002 — **EXTENDS** `feynman-pass1-governance.md` FF-006/FF-007 — the six one-way authority steps have a measured verification resolution of zero in the script and one test in the suite

**Severity: LOW (process/verification)** · `script/DeployCoinDAO.s.sol` L230-263 × `CoinDAOFactory`
L428-430, L454, L463, L488
**Verification: Method B — `test_P4_002_scriptVerificationSignsOffRegardlessOfTheAuthorityModel` PASS
in **all seven trees**, with the control `test_P4_002control_allSixOneWayAuthorityFactsHoldOnTheUnmutatedTree`
PASS on the clean tree and FAIL — naming the specific broken fact — in each mutant. Level 4.**

### What is already owned, and what is new

FF-006 established by grep and by three PoCs that `_verifyDeployment` *"never asks a single outcome
question"*, and FF-007 that `_preflightImplementations` *"is a check that cannot fail."* **Both are
correct and neither is re-derived here.** What is new is the **measurement**: RC-1 names six specific
one-way steps, and this pass deletes each one and measures what notices.

### The mutation-resolution table (L4, six single-line mutant trees)

| # | one-way authority step | line | project suite (55) | caught by | `_verifyDeployment` |
|---|---|---|---|---|---|
| A1 | `timelock.grantRole(PROPOSER_ROLE, governor)` | 428 | **53/55** | 2 tests, **indirectly** (a governance flow reverts) | **passes** |
| A2 | `timelock.grantRole(CANCELLER_ROLE, governor)` | 429 | **55/55** | **nothing at all** | **passes** |
| A3 | `timelock.renounceRole(DEFAULT_ADMIN_ROLE, factory)` | 430 | **54/55** | 1 assertion, in 1 test | **passes** |
| A4 | `revenueRouter.transferOwnership(timelock)` | 454 | **53/55** | 2 assertions, in 2 tests | **passes** |
| A5 | `treasuryVesting.initialize(timelock, …)` → factory owns 28 % of supply | 463 | **54/55** | 1 assertion, in 1 test | **passes** |
| A6 | `coinStakingRewards.renounceOwnership()` | 488 | **54/55** | 1 assertion, in 1 test | **passes** |

**In every one of the six, the deploy script's post-flight verification returned without reverting**
while the authority fact was broken — asserted directly, in each mutant tree, by running the *same*
PoC file:

```
m430:  A3 factory still ADMIN      : true          <- the factory retains permanent admin over the
       ... and _verifyDeployment returned without reverting     timelock of every DAO it launches
m463:  A5 28% vest owner           : 0xA4AD…828c   <- the FACTORY, not the timelock
       ... and _verifyDeployment returned without reverting
```

### Three observations the table supports and the prior findings do not

1. **Four of the six are held up by a single test function.** A3, A5 and A6 are each caught by exactly
   one `assertEq`/`assertFalse`, and A4 by two — all inside
   `testFreshLaunchPredictsProxiesAndWiresCanonicalDeployment`. Delete that one function and **five of
   the six one-way steps become unobserved**.
2. **A2 is unobserved today.** `grantRole(CANCELLER_ROLE, governor)` can be deleted with the suite
   fully green. This **converges independently** with `feynman-pass1-governance.md` **FF-004** and
   `feynman-pass3-inherited.md` **F-04**, which established by reasoning that the role is unreachable
   through the Governor's own surface. The suite agrees: an irreversible grant that nothing uses and
   nothing checks.
3. **Role names are searched-for under two spellings.** `DEFAULT_ADMIN_ROLE`, `PROPOSER_ROLE`,
   `CANCELLER_ROLE` and `EXECUTOR_ROLE` appear **zero times** in `test/`; the single role assertion that
   exists is written `hasRole(bytes32(0), address(factory))`. **⚠ I initially wrote the absence claim
   from the first grep and it was wrong**; the m430 mutation caught me. Recorded because it is exactly
   the failure `CLAUDE.md` warns about, and because a client grepping for role coverage will make the
   same mistake.

### Why this composes with RC-1 rather than restating FF-006

FF-006's point is that the checks that exist are shape checks. RC-1's point is that these six steps are
the ones that **cannot be undone**. Composed: **the verification effort in this repository is
concentrated on the facts a failed launch would have reverted anyway, and absent from the facts a
successful launch makes permanent.** Sixteen of `_verifyDeployment`'s eighteen post-conditions restate
things `_deployCoinDAO` already guarantees; the two live ones (`lender.operator()`, `_managerOf`) test
the *external* lender's honesty, which is the right instinct pointed at the wrong risk — the external
handoff is recoverable in principle, the six internal steps are not.

### Fix

FF-006 already proposes the correct extension (role, owner and balance assertions in
`_verifyDeployment`) and prices it correctly. **I concur and add only the priority argument**: of the
assertions FF-006 lists, the six above should come first, because they are the only ones whose failure
cannot be repaired afterwards. Additionally, add A1–A6 as explicit assertions to
`test/CoinDAOFactory.t.sol` **as separate test functions**, so that no single test's deletion removes
the whole authority model from coverage.
- *Prevents:* a silent launch-wiring regression, on-chain and in CI.
- *Creates:* more `require`s in a broadcast script means more ways for a legitimate launch to abort
  after inclusion — but every one of the six is a pure `staticcall` against a contract the same
  transaction just created, so the failure modes are the launch being wrong, which is the point.

---

## SP4-003 — **EXTENDS** FP3-001 and registries SI-009 — the only rejected deployer configuration is the one that costs the deployer, and the off-chain layer replicates the on-chain blind spot verbatim

**Severity: LOW as a mitigation-layer finding** (the value consequence is FP3-001's and is not
re-graded here) · `CoinDAOFactory` L556-563 × `script/DeployCoinDAO.s.sol` L80-97
**Verification: Method B — `test_P4_003_onlyTheConfigurationThatCostsTheDeployerIsRejected` PASS,
covering all four cells at both layers. Level 4.**

### The 2×2, executed at both layers

| | `deployerRecipient == 0` | `deployerRecipient != 0` |
|---|---|---|
| **`deployerStakeBps == 0`** | ✅ accepted — 5 % liquid to the **timelock** (the canonical launch, and the script's default) | ✅ **accepted by both layers** — 5 % liquid to a private address; **no vesting wallet, so `MAX_DEPLOYER_STAKE_BPS`, the four-year lock and the OZ zero-owner guard (G-24) are all bypassed** |
| **`deployerStakeBps != 0`** | ❌ **rejected** by `_validate` L560 **and** by `buildGovParams` L97 | ✅ accepted — vested, capped, locked |

**Exactly one cell is rejected, and it is the one in which the deployer receives nothing.** Asserted at
L4 at both layers; the accepted-dangerous cell puts **500,000 GOV** in a private address and **0** in
the timelock (`d.deployerVesting == address(0)` asserted).

### The new half: the mitigation layer copied the condition, including its scope

`script/DeployCoinDAO.s.sol:97` is
`require(deployerStakeBps == 0 || deployerRecipient != address(0), "Deployer recipient required")` —
**character-for-character the same predicate as `_validate` L560.** The off-chain layer had a free
opportunity to police the cell the on-chain layer cannot (a script may hold policy the contract must
not) and instead reproduced the contract's branch scope.

**And the environment defaults make that cell the easy mistake:**
`vm.envOr("DEPLOYER_STAKE_BPS", 0)` (L80) and `vm.envOr("DEPLOYER_RECIPIENT", address(0))` (L81). An
operator who sets `DEPLOYER_RECIPIENT` and forgets `DEPLOYER_STAKE_BPS` — or who sets the recipient
first while drafting a `.env` — ships the dangerous cell. Every one of the script's 73 `require`s
passes, `_verifyDeployment` passes (SP4-002), and `deployments[i]` has **no field that could record
where the 5 % went** (registries SI-008).

**Compounded by G-24, which the guard census surfaced:** OZ's `Ownable` rejects a zero beneficiary
inside `CoinDAOVestingWallet.initialize` — but that call is reached **only** when `bps != 0`, i.e. only
where `_validate` L560 has already guaranteed non-zero. So `deployerRecipient` is zero-policed **twice
on the branch where it cannot be zero and zero times on the branch where it is the only thing that
matters.**

### Fix

FP3-001 Option C (emit `deployerRecipient` and `immediateAllocation` in `CoinDAODeployed`) and
registries SI-009 already own the on-chain remedies and price them. **The addition this finding makes
is one line in the script, which is free and which nobody has proposed:**

```solidity
// script/DeployCoinDAO.s.sol, buildGovParams
require(deployerStakeBps != 0 || deployerRecipient == address(0), "Set DEPLOYER_STAKE_BPS to route the liquid 5% to a private address");
```
- *Prevents:* the accidental version of the cell — an operator who set one environment variable and not
  the other — without changing what the factory permits.
- *Creates:* a deliberate launcher who genuinely wants the liquid 5 % and no vested stake must now set
  the flag explicitly. That is the entire intent; it is not a loss.
- *Does not close:* the deliberate case, which reaches the factory directly and never sees the script.
  **Say so** — this is a mitigation for the mistake, not for the decision, and the decision is FP3-001
  Q-5's product question.

---

## SP4-004 — **EXTENDS** seams SI-006 — Phase 5 nominates the router while the factory is still the lender's operator, so a harvest inside that window is paid to a contract with no outflow

**Severity: LOW (lead — the trigger is external and unverified)** · `CoinDAOFactory.sol:452-453`
**Verification: Method B — `test_P4_004_harvestInsideThePhase5WindowIsPaidToTheFactoryAndIsUnrecoverable`
PASS, with the control `test_P4_004control_withoutReentryTheLaunchStrandsNoCoinInTheFactory` PASS.
Level 4 for the mechanism; Level 2 for the trigger, stated below.**

### The coupled pair

```
CoinDAOFactory.sol:452   IMonolithLender(lender).setPendingOperator(revenueRouter);   <-- untrusted call
                         ^ at this instant lender.operator() is STILL address(this)
CoinDAOFactory.sol:453   revenueRouter.acceptLenderOperator();                        <-- role moves here
```

`lender.pullLocalReserves()` pays **whoever is operator at the moment it runs** (the established
external fact: a complete drain). `RevenueRouter.distribute()` is **permissionless and has no
`nonReentrant`**. Therefore any harvest that occurs between `:452` and `:453` is delivered to the
**factory**, whose complete mutating ABI is `{deploy, deployForExistingCoin,
setPendingMonolithBeneficiary, acceptMonolithBeneficiary}` — no owner, no rescue, no token-moving
function of any kind (FI-005, ABI-verified there).

### Executed (L4)

A lender that calls out during `setPendingOperator` — modelling any hook, callback or notifier on
operator nomination — re-enters `distribute()` at the predicted router address:

```
CONTROL (no re-entry):
  Coin stranded in the factory                  : 0
  lender.operator()                             : the router
  lender.accruedLocalReserves()                 : 1,000,000e18  (untouched)

WITH the re-entry at :452:
  Coin paid to the FACTORY inside the launch tx : 1,000,000.000000000000000000
  Coin held by the router                       : 0
  Coin held by the timelock (treasury)          : 0
  Coin held by the staker                       : 0
  lender.operator()                             : the router     <- and the launch still SUCCEEDED
```

The control is the load-bearing half: without the callback the identical launch strands nothing, so the
measurement discriminates the window and not the setup.

### Why it is a state finding and where it stops

SI-006 enumerated every **factory-storage** read after `:452` and correctly found exactly one
(`monolithBeneficiary`). This pass asks the other half of the SKILL's Phase 4 question — *"can the
callee observe or change state that step N+1 depends on?"* — about a value that is not factory storage
at all: **the lender's `operator` role, which the factory holds for exactly two instructions.** The
consequence is different in kind from SI-006's: not a redirected 2 % allocation but the market's entire
accrued reserve, delivered to an address with no outflow, on the very path (`deployForExistingCoin`)
where that reserve is largest (FP3-004's premise).

**Honest limits.**
- **The trigger is external and I did not verify it.** The lender is gated by
  `monolithFactory.isDeployed`, so it is a real Monolith lender, not an attacker's contract. This is
  reachable only if the real lender calls out during `setPendingOperator`, or if any other contract in
  that call graph does. That is Level 2 and it is a **question for the client**, not a claim.
- **Nobody gains.** The Coin is destroyed, not stolen. This is a durability defect, not an attack.
- It is a **third** counter-example to VN-F ("`distribute()` never strands Coin"), after FP3-005.

### Fix — both failure modes priced

*Option A.* Swap the order so the role never rests with the factory: not possible — `acceptOperator`
requires a prior nomination. The minimal equivalent is to make the window unobservable by moving both
lines: `feynman-pass1-factory.md` **FF-11** already proved by mutation (M8) that **Phase 5 can be
deferred past Phase 7 with the whole suite green**. Deferring it to the very end of `_deployCoinDAO`
shrinks the window to two adjacent instructions with nothing after them.
- *Prevents:* this finding, SI-006, and the factory-lens FF-11 window, together.
- *Creates:* nothing functional — measured by FF-11. It does mean the router briefly exists without the
  operator role, which is already true today.

*Option B.* Add a post-condition inside `_deployCoinDAO`: `require(coin.balanceOf(address(this)) == 0)`
before Phase 8.
- *Prevents:* the strand becoming permanent — the launch reverts instead.
- *Creates:* a launch that reverts because a *third party* donated 1 wei of Coin to the factory. That is
  a cheap, permanent, permissionless denial of every future launch, since the factory is shared.
  **Do not ship B.** Stated because the obvious guard here is worse than the defect.

**Recommendation: A, adjudicated together with SI-006 and FF-11 as one decision about Phase 5's
position — not as three patches.**

---

# 5. VERIFIED NEGATIVES (worth stating positively in the report)

- **VN-P4-1 — no party can hold GOV or stGOV inside the launch transaction.** Trace: the only untrusted
  external calls in `_deployCoinDAO` are `:452` and `:453`; every other call is to a clone or library
  the same transaction created, or to the timelock. GOV first moves in Phase 7 (`:485`–`:498`), which
  contains no untrusted call. Asserted at L4 under re-entry
  (`test_P4_005VN_noStGovIsMintedDuringTheLaunchEvenUnderReentry`): `stGOV.totalSupply() == 0` and the
  re-entrant party holds 0 GOV after the launch. **This is the premise FP3-001 and SI-002 rely on and
  it holds.**
- **VN-P4-2 — `StakingRewards.setRewardsDistribution` has no zero-address check, and it does not
  matter**, because `:488` renounces the only owner two lines after `:486` uses it (G-21). The single
  missing zero-guard in the system is neutralised by RC-1. Worth one line, because a future decision to
  *keep* an owner (as some proposed fixes imply) would arm it.
- **VN-P4-3 — the five-allocation arithmetic is exact on the FP3-001 branch too.** Re-measured at L4 in
  `test_P4_003`: `bps = 0, recipient ≠ 0` still conserves the fixed supply exactly and leaves nothing in
  the factory. VN-C survives RC-2.
- **VN-P4-4 — every stGOV holder's `userRewardPerTokenPaid` is synced by construction.** `_update`
  makes `depositFor` the only balance-creating path, and its modifier order runs `harvestYield` then
  `updateReward(account)` before the mint. There is no path by which an account acquires stGOV without
  a settlement. (Convergent with FP3-004; recorded because it is the reason VN-A survives RC-1.)
- **VN-P4-5 — the funder ↔ `StakingRewards` back-link is the only per-call cross-contract
  re-verification in the system** (`StakingRewardsFunder.sol:76`) and it is correct. Its counterpart on
  the revenue side does not exist: nothing re-checks `StakedGovToken.revenueRouter` against
  `RevenueRouter.govStaking`, and SI-003 Option C already proposes the initialize-time version.

---

# 6. HYPOTHESES TESTED AND KILLED — including two killed by the corpus

**A refutation is a claim too.** Recorded so no later pass re-derives them, and so the debrief can see
what a fourth pass costs.

| ID | hypothesis | how it was killed | verdict |
|---|---|---|---|
| **K-1** | *The empty-pool guard is on the revenue path and absent from the emissions path — one receiver refuses and its caller redirects the value, the other accepts and destroys it.* Reached independently from the RC-2 branch census. | **Already owned in full by `feynman-pass3-masking.md` FP3-02**, including the identical cross-lane comparison table. Convergent, not new. | **NOT NEW — do not report twice** |
| **K-2** | *The predicted Governor address depends on `govParams.govTokenName`, which the deployment key does not bind, so 9 of 10 predictions are key-determined and the 10th is not.* | **Already owned by `state-pass2-registries.md` SI-007**, which states the 9-vs-1 split exactly. | **NOT NEW** |
| K-3 | The non-upgradeable `ReentrancyGuard` in an EIP-1167 clone leaves `_status` at 0 and disarms `nonReentrant` | Owned and refuted three times over: emissions R-01, revenue FF-006, inherited R-1 (executed). | **NOT A FINDING** |
| K-4 | `_validateImplementations` accepts wrong-type implementations | Owned: factory FF-12 and governance FF-007. | **NOT A FINDING** |
| K-5 | Donations to `StakingRewardsFunder` after the final tranche are a new permanent sink | Owned: emissions GAP-04 and GAP-06. | **NOT A FINDING** |
| K-6 | `deployerRecipient` set to the predicted `StakedGovToken` strands 5 % and breaks the wrapper's exact backing | Mechanism confirmed by trace, but owned: revenue SI-005 (the wrapper break) and registries SI-009 (the missing recipient validation). Recorded as a **data point for SI-009**, not a finding. | **NOT NEW** |
| K-7 | The five-allocation sum can be non-exact on some branch, leaving GOV in the ownerless factory | Arithmetic + L4: `treasuryVested` is a subtraction remainder and the `deployerVesting` transfer shares a predicate with its creation. Exact on every branch. | **NOT A FINDING** |
| K-8 | `notifyRewardAmount` can be reached with `periodFinish` advanced but `nextTranche` not, or vice versa | Trace: `nextTranche` is incremented and the notify issued in the same function, and `onlyRewardsDistribution` admits only the funder, whose sole call site is `fundNextTranche`. They cannot separate. | **NOT A FINDING** |
| K-9 | `StakedGovToken` can become insolvent in Coin (credited rewards exceed its balance) | `mulDiv` floors on the notify and `earned` floors again per account, and the router transfers *before* notifying. Credits are always ≤ transferred. The error is one-sided and is FP3-005's stranding, not a shortfall. | **NOT A FINDING** |
| K-10 | `Governor.token` being immutable while `_timelock` is mutable creates a pair beyond SI-001 | Trace: nothing reads the two together except `_executor()`, which reads only the timelock. No new pair. | **NOT A FINDING** |

---

# 7. COVERAGE AND HONESTY STATEMENT

- **Frozen ↔ mutable pairs mapped: 24** (16 addresses, 8 quantities/clocks). **12 have a still-moving
  counterpart; 11 of those are owned by Passes 1–3 and cited; 1 is new (N-6 → SP4-001).**
- **Guards censused by branch: 24 in `src/`** (17 in `CoinDAOFactory`, 7 elsewhere on the branch axis)
  **plus all 73 `require`s in `script/`**, grouped into 10 branch-classified sets. The four contracts
  already censused on the *liveness* axis by `feynman-pass3-masking.md` are not re-censused.
- **Pairs previously marked CONSISTENT and re-opened under both root causes: 9. Eight survived; one
  (VN-F) broke, for a third independent reason (SP4-004).**
- **New findings: 4** — 0 CRITICAL, 0 HIGH, 0 MEDIUM, **4 LOW**. One is genuinely new (SP4-001); three
  are labelled EXTENDS and each names the finding it extends and what it adds.
- **Findings that are re-derivations: 0 reported.** Two candidates (K-1, K-2) were killed by reading the
  corpus and are recorded in §6 rather than silently dropped. K-1 in particular was this pass's
  intended headline; it is FP3-02's.
- **Verification levels:** **L4** for SP4-001 (+control), SP4-002 (across 7 trees, +control),
  SP4-003, SP4-004 (+control), and VN-P4-1/-3. **L2 with exhaustive line trace and explicit negative
  greps** for the two censuses, VN-P4-2, VN-P4-4 and VN-P4-5. **The only Level-2 link inside a finding**
  is SP4-004's trigger (whether the real lender calls out during `setPendingOperator`), stated in the
  finding and raised as Q-1 below.
- **Controls included, so the checks could have failed (L3):** `test_P4_001control` (at the earliest
  cadence the two clocks coincide to the second — this is what proves they were designed equal),
  `test_P4_002control` (all six authority facts hold on the clean tree, and it fails in each mutant
  naming the broken fact), `test_P4_004control` (the identical launch strands nothing without the
  callback), and the four accepted cells in `test_P4_003` against the one rejected cell.
- **Fix resolution measured, not asserted:** six single-line mutations of the six one-way authority
  steps, each re-run against the full project suite **and** against the deploy script's own
  `_verifyDeployment`.
- **An error of my own, recorded because it is the class `CLAUDE.md` names.** I grepped `test/` for
  `DEFAULT_ADMIN_ROLE|PROPOSER_ROLE|CANCELLER_ROLE`, got zero hits, and began writing *"the launch's
  role wiring is asserted by no test at all."* The m430 mutation failed a test and disproved it: the one
  assertion that exists is written `hasRole(bytes32(0), …)`. **The absence claim was wrong and the
  execution caught it.** Corrected in SP4-002 §3.
- **Absence claims, each checked by explicit grep:** the identity
  `FOUR_YEARS == TRANCHE_COUNT * COIN_STAKING_REWARD_DURATION` — **0** occurrences in `src/`, `script/`
  or `test/`; no test relates a vesting schedule to a tranche schedule — **0**;
  `hasRole`/`.owner()`/`balanceOf`/`PROPOSER`/`CANCELLER`/`DEFAULT_ADMIN`/`quorum`/`renounce` in
  `script/` — **0** (independent re-confirmation of FF-006); `deployerRecipient` — 4 hits in `src/`,
  exactly one of which is a guard, and 5 in `script/`, exactly one of which is a guard, and the two
  guards are the same predicate; `monolithFactory` in the factory constructor — zero-checked, **not**
  code-checked, unlike the six implementations.
- **What I did NOT do.** I did not re-audit anything Pass 2 cleared and did not rebuild any lane
  agent's within-contract mutation matrix. I did not read `[scratch]` or `engagements/`. I did
  not verify any external Monolith behaviour. I did not re-grade any existing finding.
- **Client code was not modified.** All experiments ran on disposable copies under the session
  scratchpad. `git status --porcelain [scratch]` and `git diff --stat -- [scratch]` are empty; `diff -rq`
  of `src/` and `script/` against the copy is clean; the audited tree re-verified **55/55**.

---

# 8. HAND-OFF

**The single most important line in this pass:** `CoinDAOFactory.sol:36` — `uint64 public constant
FOUR_YEARS = 365 days * 4;` — sitting two lines above `COIN_STAKING_REWARD_DURATION = 365 days`, with
the factor of 4 that binds them living in a different contract and asserted nowhere. RC-1's census was
built out of *authority*; this is the same root cause expressed in *time*, and it is the axis an
authority census cannot see.

**For the debrief.**
- **SP4-002 should be adjudicated together with `feynman-pass1-governance.md` FF-006 and FF-007**, not
  beside them: it is the same recommendation with a measured priority order attached.
- **SP4-003 should be adjudicated with FP3-001** and with FP3-001's Q-5 (is the 5 % the deployer's
  compensation or the DAO's treasury?). The one-line script guard is worth shipping regardless of how
  Q-5 is answered, because it separates the mistake from the decision.
- **SP4-004 should be adjudicated with seams SI-006 and factory FF-11 as a single decision about where
  Phase 5 sits**, exactly as Pass 3 recommended treating the vesting-wrapper override surface as one
  decision rather than three findings.
- **SP4-001 Option A is the cheapest fix in this entire engagement**: one comparison of three
  compile-time constants, no runtime behaviour, no new failure mode.

**Open questions this pass could not answer** (each gates a severity, not a fix):

- **Q-1 (gates SP4-004).** Does the real Monolith lender — or anything in its `setPendingOperator` call
  graph — make an external call? If yes, SP4-004 is confirmed end-to-end at Level 4 and the Phase-5
  reposition (Option A) becomes urgent. If no, SP4-004 is a structural note like SI-006.
- **Q-2 (gates SP4-001's framing, not its severity).** Is the four-year emission a *commitment* the
  project has made publicly, or an internal target? If it is a commitment, the gap between an enforced
  insider deadline and an unenforced community floor is a disclosure question as well as a code one.
