# NEMESIS Pass 3 — Feynman Auditor: TARGETED re-interrogation of defensive constructs

**Methodology:** `.claude/skills/feynman-auditor/SKILL.md`, Category 1 (Purpose) applied
exhaustively to every guard, `require`, early return, clamp, ternary, zero-check and
conditional branch in the emission and reward machinery. Categories 3 (Consistency) and 5
(Boundaries) applied where the purpose question opened onto a sibling.

**The rule under test (from the NEMESIS handoff):** *defensive code is a SIGNAL, not a
solution.* Pass 2 proved two instances — `StakingRewards.sol:160`, whose slack is composed
of the value a defect already destroyed, and `StakingRewardsFunder.sol:80`, which is
structurally dead on the final tranche because the quantity it validates is assigned from
the value it is compared against. **This pass was asked to find the rest.**

**Scope (line-by-line):** `[scratch]` —
`StakingRewards.sol` (174), `StakingRewardsFunder.sol` (96), **`StakedGovToken.sol` (189)**,
**`RevenueRouter.sol` (99)**, `GovToken.sol` (41), `CoinDAOGovernor.sol` (103),
`CoinDAOFactory.sol` (guard census + wiring only), `interfaces/`.
**Not read:** `[scratch]`, `engagements/`.

> ⭐ **Why the scope widened, and a correction to how it was justified.** The two files this
> pass was pointed at — `feynman-pass1-emissions.md` and `state-pass2-emissions.md` — both
> scope to the `StakingRewards` / `StakingRewardsFunder` pair. `StakedGovToken` ×
> `RevenueRouter` is the *other* emission and reward machine in the same deployment, so it
> received the same guard census, per the workspace rule *aim at UNCOVERED code*.
>
> ⛔ **That premise was wrong and I checked it too late.** After the census was complete I
> enumerated `.audit/findings/` and found `feynman-pass1-revenue.md` and
> `state-pass2-revenue.md` — a **dedicated Pass 1 and Pass 2 lane that audited both files
> line-by-line.** I asserted "neither prior pass read a line of it" without grepping for the
> negative, which is precisely the absence-claim failure the workspace rule names as the
> dangerous one. **Two of the findings below are therefore CONVERGENT re-derivations, not
> new discoveries, and are re-labelled as such.** See *Provenance and convergence* before
> the summary. The census itself stands; only the novelty claim was wrong.
>
> The silver lining is real and is the reason the two findings stay in this file: discovery
> here ran **genuinely blind** to those lanes, so the agreement is un-primed convergence —
> the strongest evidence this workspace recognises — and the *cross-lane* synthesis it
> enables (FP3-02's closing table) is something no single lane was positioned to state.

**Language:** Solidity 0.8.26, EIP-1167 clones, Foundry, via-ir, optimizer 200.

**Execution: level 4 for every finding below.** Two disposable copies, `[scratch]`
untouched (`git diff --stat -- [scratch]` empty).

| tree | purpose | suite |
|---|---|---|
| `%TEMP%/…/[scratch]` | unmodified source + 15 audit tests (`test/audit/FeynmanPass3.t.sol`, `FeynmanPass3Factory.t.sol`) | **70/70** (55 original + 15) |
| `%TEMP%/…/[scratch]` | **two deliberate source mutations** + 4 mutation tests (`test/audit/Pass3Mutations.t.sol`) | 58/59 — one project test fails *by design* (see FP3-04) |

> ⚠ **Harness traps encountered and handled** (both were flagged in the brief and both
> actually fired): `block.timestamp` is cached across `vm.warp` under `via-ir` — every
> timestamp is read with `vm.getBlockTimestamp()`. And `vm.roll(block.number + N)` is a
> silent no-op after the first roll — the quorum PoC initially produced a *false negative*
> (quorum apparently unchanged) until every roll was rewritten as
> `vm.roll(vm.getBlockNumber() + 1)`. Recorded so a later pass does not mistake either for
> a defect, and as evidence that the negative result was investigated rather than accepted.

---

## PHASE 0 — THE COMPLETE GUARD CENSUS

Every defensive construct in the emission and reward machinery, with the purpose question
answered for each. **Verdict key:** `LIVE` = can fire and protects a real invariant ·
`DEAD` = cannot fire from any reachable caller · `MASKING` = fires, but answers a different
question from the one it appears to answer · `SLACK-FED` = its headroom is supplied by a
defect elsewhere.

### `StakingRewards.sol`

| # | Line | Construct | Q1.2 — delete it? | Verdict |
|---|---|---|---|---|
| 1 | L50 | `require(stakingToken_ != 0)` | init with a dead token | LIVE |
| 2 | L51 | `require(rewardsToken_ != 0)` | init with a dead token | LIVE |
| 3 | L52 | `require(initialOwner != 0)` | reverts anyway inside `__Ownable_init` — changes the error string only. Note: the invariant it establishes ("an owner exists") is deliberately abolished three lines later in the factory (`CoinDAOFactory.sol:488`). | LIVE-but-cosmetic |
| 4 | L53 | `require(rewardsDuration_ > 0)` | division by zero at L152/L160 | LIVE (no *upper* bound — Pass 1 FF-009) |
| 5 | L63 | `onlyRewardsDistribution` | anyone could notify | LIVE |
| 6 | L71 | `if (account != address(0))` | `rewards[0]`/`userRewardPerTokenPaid[0]` get written with zeroes. `_balances` is written at **L115 and L124 only, both `[msg.sender]`** (re-grepped independently this pass), and `msg.sender` is never `address(0)`, so nothing observable changes. | **gas only — not a safety guard** |
| 7 | L90 | `block.timestamp < periodFinish ? … : periodFinish` | emission would run past `periodFinish` forever → insolvency | LIVE (and it is why an *inter-tranche gap* costs nothing while an *intra-period vacancy* costs `rewardRate`/s) |
| 8 | L95 | `if (_totalSupply == 0) return rewardPerTokenStored;` | division by zero | **MASKING** — Pass 2 MASK-03 / Pass 1 FF-001 |
| 9 | L113 | `require(amount > 0, "Cannot stake 0")` | `stake(0)` becomes a no-op that still settles — but `getReward()` already offers a free settle to anyone, so nothing changes | stops zero, not dust (FF-003) |
| 10 | L122 | `require(amount > 0, "Cannot withdraw 0")` | `exit()` stops reverting for reward-only accounts | LIVE-but-harmful (FF-004) |
| 11 | **L132** | **`if (reward > 0)`** | nothing — a zero-value `safeTransfer` and an extra event | **MASKING → FP3-01. Pass 2's MASK-04 clearance is corrected below.** |
| 12 | L151 | `if (block.timestamp >= periodFinish)` | the `else` half is already unreachable | `else` branch **DEAD** (FF-002) |
| 13 | L159–160 | `require(rewardRate <= balance / rewardsDuration)` | the funder can never violate it | **SLACK-FED** (Pass 2 MASK-01; extended at FP3-07) |
| 14 | L168 | `onlyOwner` on `setRewardsDistribution` | nothing — there is no owner | **DEAD** (A7) |

### `StakingRewardsFunder.sol`

| # | Line | Construct | Q1.2 — delete it? | Verdict |
|---|---|---|---|---|
| 15 | L41 | `if (address(stakingRewards_) == 0) revert ZeroAddress()` | `rewardsToken()` call on `address(0)` reverts anyway | LIVE-but-cosmetic |
| 16 | L42 | `if (totalRewards_ == 0) revert ZeroRewards()` | three tranches would notify 0 | **stops zero, not dust → FP3-06** |
| 17 | L60 | `revert InvalidTranche(tranche)` in `trancheBps` | nothing internally | **internally DEAD** — `trancheBps` has exactly one internal call site (L92) and it is guarded `tranche < 3` |
| 18 | L64 | `if (tranche >= TRANCHE_COUNT) revert InvalidTranche` | `trancheAmount(4+)` would return the live balance | LIVE (view only) |
| 19 | **L70** | **`if (tranche == TRANCHE_COUNT) revert AllTranchesFunded()`** | **the absorbing state disappears** | **the single line that makes GAP-06 terminal → FP3-04** |
| 20 | L73 | `if (block.timestamp < periodFinish) revert PreviousTrancheActive` | tranches could be funded in one block | LIVE — and it is what kills `StakingRewards.sol:153` (FF-002) |
| 21 | L76 | `if (rewardsDistribution != address(this)) revert NotRewardsDistribution` | the notify would revert one line later | LIVE-but-cosmetic (improves the error only) |
| 22 | **L80** | **`if (balance < amount) revert InsufficientBalance`** | tranches 0–2: a deficit would pass; tranche 3: **nothing** | **LIVE on 0–2, DEAD on 3 → slack table at FP3-07** |
| 23 | L92 | `if (tranche < TRANCHE_COUNT - 1)` | tranche 3 would use `trancheBps(3)` | **the one decision behind three defects → FP3-04** |

### `StakedGovToken.sol` — **not read by Pass 1 or Pass 2**

| # | Line | Construct | Q1.2 — delete it? | Verdict |
|---|---|---|---|---|
| 24 | L64–66 | three `revert ZeroAddress()` | wrapper/router misconfiguration | LIVE |
| 25 | L77 | `onlyRevenueRouter` | anyone could inflate `rewardPerTokenStored` | LIVE |
| 26 | L87 | `if (account != address(0))` | nothing observable | gas only |
| 27 | L159 | `if (reward > 0)` in `_payReward` | a zero transfer + event. Unlike SR L132 there is **no clock** here, so this one genuinely is a no-op. | LIVE-as-intended (contrast with #11) |
| 28 | **L170** | **`if (supply == 0) revert NoStakedSupply()`** | **nothing — the only caller has already decided the same predicate** | **DEAD → FP3-02** |
| 29 | L180–181 | `if (from != 0 && to != 0) revert NonTransferable()` | `_update` does **not** settle rewards, so transferable stGOV would let one account double-claim by moving its balance to a fresh address | **LIVE and load-bearing** — the strongest guard in the machinery |

### `RevenueRouter.sol` — **not read by Pass 1 or Pass 2**

| # | Line | Construct | Q1.2 — delete it? | Verdict |
|---|---|---|---|---|
| 30 | L48–51 | five-way `revert ZeroAddress()` | misconfiguration | LIVE |
| 31 | L52 / L89 | `if (bps > MAX_BPS) revert InvalidGovStakingBps` | `treasuryAmount = amount - govStakingAmount` would underflow-revert | LIVE |
| 32 | **L72** | **`if (govStaking.totalSupply() != 0)`** | `depositFor` would revert for the FIRST depositor whenever revenue is pending, because `harvestYield` runs `distribute()` before the mint and #28 would then fire | **LIVE — and it is the read that `rewardRate` × `_totalSupply` is missing (see FP3-02)** |
| 33 | L77 | `if (govStakingAmount != 0)` | a zero transfer + a notify of 0 | LIVE-as-intended |
| 34 | L81 | `if (treasuryAmount != 0)` | a zero transfer | LIVE-as-intended |
| 35 | L64/88/94 | `onlyOwner` (timelock) | governance controls | LIVE |

**Census totals:** 35 constructs. **2 structurally dead** (#28 from its only caller,
#22 on tranche 3), **1 dead by ownership** (#14), **1 dead internally** (#17), **1 dead
branch** (#12's `else`), **2 masking** (#8, #11), **1 slack-fed** (#13), **3 gas-only
constructs presenting as guards** (#6, #26, and #21/#15 by consequence),
**2 zero-guards that stop the exact-zero case while the dust case is the one that
matters** (#9, #16), and **1 guard that is the correct implementation of the very coupling
the other emission contract is missing** (#32).

---

## FINDINGS

| ID | Title | Severity | Status vs Passes 1–2 |
|---|---|---|---|
| FP3-01 | `if (reward > 0)` hides that a zero-reward `getReward()` consumes the emission clock | note (**corrects Pass 2 MASK-04**) | **CORRECTION** |
| FP3-02 | `NoStakedSupply` is structurally dead — **and the coupling it pretends to enforce is implemented correctly 100 lines away, in the contract that does not need it** | LOW | **CONVERGENT** with revenue-lane FF-011 / Pass 2 M1. **The cross-lane comparison against GAP-02 is new.** |
| FP3-03 | `depositFor` is the only mint path for the governance token and the only entry point with no harvest-free variant | MEDIUM (lead-bounded) | **CONVERGENT** — duplicates revenue-lane **FF-004**, which is better bounded. Only the proposal-threshold floor is additive. |
| FP3-04 | GAP-06's terminality hinges on exactly one line, and one design decision produces FF-005, MASK-02 and GAP-06 together | MEDIUM (structural) | **NEW analysis of a known gap** |
| FP3-05 | The implied remedy (restore `recoverERC20`) moves the mask rather than removing it | note | **NEW** |
| FP3-06 | `ZeroRewards` stops zero and not dust: a 3-wei `totalRewards` burns three full years at `rewardRate == 0` | LOW | **NEW** |
| FP3-07 | Slack table for `InsufficientBalance` across all four tranches | note | **NEW measurement** |

---

### FP3-01 — CORRECTION to Pass 2's MASK-04 — `if (reward > 0)` at `StakingRewards.sol:132` is not a no-op guard; it is what makes a state-changing call look like one

**A refutation is a claim too.** Pass 2 interrogated L132 and cleared it:

> *"MASK-04 — `if (reward > 0)` … Checked and **cleared**: `reward` is zero exactly when
> nothing accrued, `getReward()` is then a genuine no-op … Not masking anything."*

**That clearance is wrong, and Pass 2's own PoC depended on it being wrong.** Pass 2 wrote,
four pages earlier: *"Any caller can consume the clock. `getReward()` is `public` with no
minimum and no access control; calling it from an address with no stake still runs L69–70.
**The PoC uses exactly that path.**"* The two statements cannot both hold. A call that
advances `lastUpdateTime` is not a no-op.

**Feynman question that exposed it:**
> Q1.2 — *"What happens if I DELETE this line entirely?"* Answer: **nothing.** A zero-value
> `safeTransfer` and a `RewardPaid(user, 0)` event. The guard protects no invariant. So why
> does the reader believe `getReward()` did nothing? Because L132 is the only visible
> statement about whether the call had an effect — and by the time it is evaluated,
> `updateReward(msg.sender)` has already written `rewardPerTokenStored` and `lastUpdateTime`.

**The code:**
```solidity
function getReward() public nonReentrant updateReward(msg.sender) {  // L130 - already mutated
    uint256 reward = rewards[msg.sender];                            // L131
    if (reward > 0) {                                                // L132 - the "no-op" test
        …
    }
}
```

**Verification — Method B, `testP3_01_ZeroRewardGetRewardStillConsumesTheEmissionClock`**
(clone pair, tranche 0 open, nobody staked, `charlie` has never held a position):
```
clock advanced by (s)        : 864000        (lastUpdateTime moved 10 days)
accumulator delta            : 0
GOV moved to charlie (wei)   : 0
emission destroyed (wei GOV) : 890,410,958,903,808,000
```
`earned(charlie) == 0` is asserted *before* the call, so L132's branch is provably not
taken. The call transfers nothing, emits nothing, and destroys 0.89 GOV.

**Resolution of the check** (`testP3_01_Resolution_SameCallWithSupplyMovesTheAccumulator`):
the identical zero-reward call with `_totalSupply > 0` moves the accumulator by
`8,904,109,589,038,080`. The measurement therefore discriminates the vacancy, not
`getReward()` — it is not a tautology.

**Repeatability** (`testP3_01_ClockConsumptionIsFreeAndRepeatable`): 240 hourly calls from
the same never-staked address during one vacancy consume the clock in full
(`lastUpdateTime == t0 + 240 hours`, accumulator still `0`). No stake, no approval, no cost
beyond gas.

**Why it belongs in the report even though the loss is GAP-01's.** It changes *who* has to
act for GAP-01 to fire and *what the code says about it*. The report must not describe the
genesis burn as something that happens only if a staker touches the contract: **any address
can drive it, deliberately, for the price of gas, and the guard on L132 is the reason a
reader auditing `getReward()` concludes the call was inert.** It is the census's clearest
instance of a check that certifies rather than verifies — it certifies "nothing happened"
about a function that has already changed global emission state.

**Suggested fix — and both failure modes priced.** None at L132; the line is harmless in
itself and matching upstream has value. The correct repair remains at L70 (stop the clock
when `_totalSupply == 0`). *Prevents:* every second of the vacancy. *Creates:* `periodFinish`
would then no longer bound the emission — a paused clock means the tranche outlives its
period, and `StakingRewardsFunder.sol:73` serialises tranches on exactly that value, so the
schedule would stall behind a pool that once went empty. Any fix at L70 must re-derive the
funder's serialisation from a stored timestamp, which is the same constraint FF-002's fix
runs into.

---

### FP3-02 — LOW — `NoStakedSupply` cannot fire, and the coupling it appears to enforce **is** implemented correctly — in the contract that does not need it

> **Provenance.** The dead-guard half is **CONVERGENT, not new.** `feynman-pass1-revenue.md`
> already records *"notifyRewardAmount reverts (unreachable via distribute)"* and grades it
> **FF-011 / INFO**; `state-pass2-revenue.md` M1 identifies `RevenueRouter.sol:72` as a real
> mask for it and notes it *"masks a different variable's guard than the one it protects."*
> This pass reached the same two lines blind, by a different question. **What is new is the
> comparison in the closing table** — measuring this guard against GAP-02 from the emissions
> lane, which neither lane could do because both ran blind to the other.

**The code** (`StakedGovToken.sol:168–174`):
```solidity
function notifyRewardAmount(uint256 reward) external onlyRevenueRouter {
    uint256 supply = totalSupply();
    if (supply == 0) revert NoStakedSupply();          // L170
    rewardPerTokenStored += Math.mulDiv(reward, REWARD_PRECISION, supply);
```
**Its only caller** (`RevenueRouter.sol:68–80`):
```solidity
uint256 amount = coin.balanceOf(address(this));
if (govStaking.totalSupply() != 0) {                   // L72  <-- the same predicate
    govStakingAmount = (amount * govStakingBps) / MAX_BPS;
}
treasuryAmount = amount - govStakingAmount;
if (govStakingAmount != 0) {                           // L77
    coin.safeTransfer(address(govStaking), govStakingAmount);
    govStaking.notifyRewardAmount(govStakingAmount);   // L79  <-- unreachable when supply == 0
}
```

**Feynman question:**
> Q1.2/Q1.3 — *"What SPECIFIC edge case motivated this check, and what breaks if I delete
> it?"* The edge case is the empty pool. But the caller has already answered that question
> at L72 and routed around L79 entirely. Deleting L170 changes nothing that any deployed
> caller can observe.

**Absence claims, grepped explicitly this pass** (the dangerous kind): `notifyRewardAmount`
on `StakedGovToken` has exactly one call site in `src/` — `RevenueRouter.sol:79`.
`StakedGovToken.revenueRouter` is written **only** at L73 in `initialize`; there is no
setter. `RevenueRouter.govStaking` is written **only** at L58; there is no setter. Between
L72 and L79 the only intervening statement is a plain-ERC20 `safeTransfer`.

**Verification — Method B, factory-deployed,
`testP3_02_NoStakedSupplyGuardCannotFireFromItsOnlyCaller`:**
```
distribute() at supply 0 -> treasury : 1,000,000,000,000,000,000,000   (100%)
distribute() at supply 0 -> stakers  : 0
coin.balanceOf(StakedGovToken)       : 0        (the guarded contract was never called)
rewardPerTokenStored                 : 0
... repeated after draining a live supply back to zero: identical
guard reachable only by impersonating the router: confirmed
  vm.prank(router); notifyRewardAmount(1 ether) -> NoStakedSupply   (the ONLY way in)
```

**The corpus certifies the dead guard.** `test/StakedGovToken.t.sol:29–33` constructs the
staker with **`address(this)` as `revenueRouter_`**, and `testRewardNotificationGuards`
(L64–67) then asserts `NoStakedSupply` fires. The project's own suite proves the guard works
*from a caller position the deployed system can never occupy* — structurally the same
corpus defect Pass 2 recorded for `testMidPeriodNotificationRollsLeftoverForward`, now found
independently in a different file. `testP3_02_TheRealZeroSupplyPolicyIsSilentRedirection`
runs the same scenario against the **real** router and shows what actually happens:
```
same 100 coin, supply>0 -> stakers : 100,000,000,000,000,000,000
same 100 coin, supply=0 -> treasury: 100,000,000,000,000,000,000
```
No revert, no distinguishing event — the zero-supply policy in production is **silent
redirection of 100% of revenue to the treasury**, not the refusal the guard advertises.

**Why this is the most important line in the pass.** Pass 2's GAP-02 is the absence claim
*"`rewardRate` and `_totalSupply` are never read together anywhere."* That is true of
`StakingRewards`. It is **not** true of the codebase: `RevenueRouter.sol:72` is precisely
that read — *"do not price a distribution against a supply that does not exist"* — written
correctly, by the same authors, in the same deployment, roughly a hundred lines away.

| | `StakedGovToken` × `RevenueRouter` | `StakingRewards` × `StakingRewardsFunder` |
|---|---|---|
| distribution is **instantaneous** (no clock to burn) | ✓ | ✗ — streams over 365 days |
| zero-supply read **before** pricing | ✓ `RevenueRouter.sol:72` | ✗ nowhere (GAP-02) |
| zero-supply guard **inside** the receiver | ✓ `StakedGovToken.sol:170` | ✗ |
| consequence of a zero-supply notify | none — cannot happen | **the whole tranche burns** |
| harm if the guard were missing | a revert | permanent value loss |

**The contract that cannot lose anything is guarded twice. The contract that loses
6,500,000 GOV worth of emissions is guarded zero times.** This is Q3.1 — *"if functionA has
a guard and functionB doesn't, WHY?"* — answered across contracts, and it removes the last
available defence of FF-001/GAP-01/GAP-02 as a considered design trade-off: the authors
demonstrably knew the check, wrote it, and applied it to the case that did not need it.

**Severity.** The dead guard itself is LOW (no value at risk; the error is legibility and a
test that certifies nothing). Its *evidentiary* weight against FF-001 is what earns it a
place in the report.

**Suggested fix, both modes priced.** Delete L170 and document the zero-supply policy at
`RevenueRouter.sol:72` instead, or keep it and add the `RevenueDistributed` event a
distinguishing field. *Prevents:* a reader (and a test) believing an empty-pool notify is
refused when in fact it is silently rerouted. *Creates:* deleting L170 removes the last
backstop if a future caller is ever wired to `notifyRewardAmount` without L72's check — and
`Math.mulDiv` would then revert on a zero denominator anyway, so the created mode is a
worse error message, not a loss. Keeping it is defensible; **citing it as protection is
not.**

---

### FP3-03 — MEDIUM (lead-bounded) — `depositFor` is the only mint path for the governance token and the only mutating entry point with no harvest-free variant

> ⛔ **Provenance — this is a DUPLICATE, re-derived blind.** `feynman-pass1-revenue.md`
> **FF-004** ("The only mint path — and therefore the only way to acquire voting power — is
> hard-coupled to a live external Lender") states the same mechanism, the same one-sided
> reachability, the same ABI-based proof that `depositFor` is the only mint, the same
> `vm.mockCallRevert`-style PoC, and the same mock-cannot-revert corpus observation. It is
> **better bounded than this write-up**: it grades HIGH-as-a-lead and lists the three
> questions the client must answer about `pullLocalReserves()`. **The report should carry
> revenue-lane FF-004, not this section.** Retained here for two reasons only: (a) the
> convergence is un-primed and therefore evidentially valuable; (b) the proposal-threshold
> floor below is additive to it. Everything else in this section is a restatement.

**Feynman question:**
> Q1.1/Q1.3 applied to a guard's *twin* — *"why does `withdraw()` exist at all when
> `harvestAndWithdraw()` exists, and what specific scenario motivated it?"* The answer is
> written in the source. Q3.2 then asks the inverse-operation question: **does the entry
> side have the same escape hatch as the exit side?**

**The defensive constructs, and the author's own statement of why they exist:**
```solidity
/// @dev This function reverts atomically if harvesting, withdrawing, or paying rewards fails.
/// Use `withdraw` to recover the underlying GOV without harvesting or claiming rewards.   // L127-129
function harvestAndWithdraw() external nonReentrant harvestYield updateReward(msg.sender)

/// @notice Pays the caller's already-accrued rewards without harvesting pending revenue.
/// @dev This remains available if the external revenue distribution mechanism is unavailable. // L145-146
function getReward() public nonReentrant updateReward(msg.sender)
```
**`"if the external revenue distribution mechanism is unavailable"` is the author telling
us the threat model.** Two harvest-free escape hatches were built for it.

**The symmetry table** (`grep -n "harvestYield" src/StakedGovToken.sol`, verified this pass):

| entry point | mutates | `harvestYield` | harvest-free twin |
|---|---|---|---|
| `depositFor` L102 | **mints stGOV** | ✓ | **none** |
| `withdrawTo` L113 | burns stGOV | ✗ | is itself the twin |
| `harvestAndWithdraw` L130 | burns stGOV | ✓ | `withdrawTo` / `withdraw` |
| `getReward` L147 | pays rewards | ✗ | is itself the twin |
| `harvestAndGetReward` L153 | pays rewards | ✓ | `getReward` |

**`depositFor` is the only externally reachable mint path** — verified from the build
artifact, not from the library source: `forge inspect StakedGovToken methods` lists 31
functions, of which the only state-changing ones are `depositFor`, `withdrawTo`,
`withdraw`, `harvestAndWithdraw`, `getReward`, `harvestAndGetReward`, `notifyRewardAmount`,
`delegate`, `delegateBySig`, `approve`, `permit`, `transfer`, `transferFrom` and
`initialize`. There is **no `owner()`, no recovery function, and no exposed `_recover`.**

**What is downstream of the missing twin.** stGOV is the Governor's `IVotes` token
(`CoinDAOFactory.sol:419`). So the only way to acquire governance voting power in a CoinDAO
runs through a modifier that makes an unguarded external call into a contract the DAO does
not control:
```solidity
modifier harvestYield() { revenueRouter.distribute(); _; }   // L81-84
function distribute() … { lender.pullLocalReserves(); … }    // RevenueRouter.sol:68-69
```
No `try/catch`, no pause, no bypass. **`StakedGovToken.revenueRouter` and
`RevenueRouter.lender` are both write-once in `initialize` with no setter** (grepped).

**Verification — Method B, factory-deployed,
`testP3_03_DistributorFailureFreezesGovernanceMembershipOneWay`.** The lender's
`pullLocalReserves()` is made to revert (`vm.mockCallRevert`), modelling exactly the
scenario L146 names:
```
stGOV supply before outage : 2,000,000,000,000,000,000,000

ENTRY  carol.depositFor(1000)      -> revert "LENDER_DOWN"   ; balanceOf(carol) == 0
       alice.harvestAndGetReward() -> revert "LENDER_DOWN"
       alice.harvestAndWithdraw()  -> revert "LENDER_DOWN"
EXIT   alice.getReward()           -> SUCCEEDS   (the documented fallback)
       alice.withdraw()            -> SUCCEEDS   (the documented fallback)

stGOV supply after one exit: 1,000,000,000,000,000,000,000
+3650 days later, carol.depositFor -> revert "LENDER_DOWN"   (not a delay)
```
**The escape hatches work exactly as designed. That is the problem: they are one-way.** The
electorate can only shrink.

**Where it lands** (`testP3_03_ExitsConcentrateVotingPowerAndLowerQuorum`, same outage,
10,000 stGOV electorate split 1,000 / 1,000 / 8,000):
```
quorum before / after two exits : 10,000,000,000,000,000,000  ->  8,000,000,000,000,000,000
carol votes / supply after      :  8,000 stGOV  /  8,000 stGOV   (carol is 100% of the electorate)
RevenueRouter.owner()           == timelock      (recovery requires the frozen resource)

proposalThreshold / electorate  : 10,000 GOV  /  8,000 stGOV
carol.propose(...)              -> REVERTS
```
**This is the one part of FP3-03 that is additive to revenue-lane FF-004.** Two independent
mechanisms compound. `quorum` is `1/1000` of the **stGOV** past supply
(`CoinDAOGovernor.sol:64–70`), so it falls with every exit — the remaining holder faces an
ever-lower bar. But `proposalThreshold` is a **fixed** `GOV_TOKEN_SUPPLY / 1_000` =
10,000 GOV (`CoinDAOFactory.sol:292`) that does **not** scale with the electorate. Once the
stGOV supply is stuck below 10,000, **no proposal can be created by anyone, ever** — and the
`RevenueRouter` that would have to be fixed is owned by the timelock, which only the
Governor can drive.

`feynman-pass1-governance.md` already analyses this exact pair of constants and establishes
`quorum(t) <= 10_000e18 == GOVERNOR_PROPOSAL_THRESHOLD` for all `t` — but from the **capture**
direction (an attacker holding 10,000 GOV clears both bars). The **liveness** direction is
new: the same arithmetic means an electorate frozen below 10,000 stGOV cannot produce a
proposer at all, so a capture-resistant DAO and a permanently un-proposable DAO are the same
two constants read in opposite directions. **The report should join FF-004 to the governance
lane's threshold analysis; neither lane made that join.**

**Control** (`testP3_03_Control_HealthyLenderAllowsEntry`): with the lender healthy the
identical sequence lets carol join, and the `harvestYield`-before-mint ordering correctly
credits the pre-existing 50 coin of revenue to alice and **not** to carol
(`earned(carol) == 0`). The measurement is not an artefact of the mock, and the ordering it
exercises is genuinely well-designed.

**Corpus exclusion — the test that proves it and calls it success.**
`test/StakedGovToken.t.sol:229` is literally named
`testDistributorFailureRevertsHarvestingPathsButPlainWithdrawStillWorks`, and it asserts
`vm.expectRevert(DistributionFailed.selector); staker.depositFor(bob, 100 ether);`. **The
project already knows entry is closed during an outage.** Its frame is *"can existing
stakers get out?"* — a survivorship frame, in the workspace's exact sense: a test that only
checks who can leave cannot see who can no longer arrive. And `MockMonolithLender.pullLocalReserves()`
(`test/mocks/MockMonolith.sol:52–56`) **cannot revert**, so no factory-level test in the
tree can reach this state at all.

**Severity: MEDIUM, bounded as a lead on its precondition.** The *precondition* —
`pullLocalReserves()` reverting durably — is a property of the external Monolith lender and
is not verifiable inside this scope, exactly like FF-008. Per the workspace rule, the
uncertainty is stated rather than converted into a lower severity. What is established at
level 4 inside scope is: (a) the consequence, executed end-to-end against a factory-deployed
system; (b) that the author modelled this precondition explicitly and mitigated it for three
of four entry points; (c) that the un-mitigated one is the sole mint path for the governance
token; and (d) that no in-scope lever can repoint, pause, or bypass the dependency.

**Suggested fix — hypothesis, both modes priced.**
```solidity
// wrap the harvest so an unavailable distributor degrades instead of blocking:
modifier harvestYield() {
    try revenueRouter.distribute() {} catch {}
    _;
}
```
- *Prevents:* the one-way membership freeze; entry survives an outage of the external
  revenue source.
- *Creates:* a **silent** harvest failure. `harvestAndGetReward()` and
  `harvestAndWithdraw()` currently guarantee atomicity — L128 and L152 say so explicitly —
  and a staker who calls `harvestAndWithdraw` and receives no revenue would have no signal
  that the harvest was skipped. It also makes it cheap to grief a harvest by forcing the
  callee to revert. The honest minimal alternative is to add a `deposit()` twin with **no**
  `harvestYield` (mirroring `withdraw()`/`getReward()`), leaving `depositFor` atomic. That
  costs one function and creates one new mode: a depositor can then choose *not* to harvest
  first, capturing a share of revenue that accrued before they arrived — the precise
  dilution `harvestYield` was added to prevent. **Which of the two modes is worse depends on
  how large the un-harvested balance can get, which is again an external-lender property.**
  The report should say so rather than recommend one.

---

### FP3-04 — MEDIUM (structural) — GAP-06's terminality hinges on exactly one line, and one design decision produces FF-005, MASK-02 and GAP-06 together

**Assignment item 4: take the absorbing state and ask the purpose question of every line
that leads into it. Which lines make it terminal, and was any single one of them necessary?**

Candidate lines, each interrogated with Q1.2:

| line | claim | Q1.2 verdict |
|---|---|---|
| `StakingRewardsFunder.sol:70` `if (tranche == TRANCHE_COUNT) revert AllTranchesFunded()` | bounds the schedule at four tranches | **NECESSARY — this is the line** |
| `StakingRewardsFunder.sol:82` `nextTranche = tranche + 1` | monotone, never reset | supporting; harmless without L70 |
| `StakingRewardsFunder.sol:92` `if (tranche < TRANCHE_COUNT - 1)` | routes tranche 3 to the sweep | **the root design decision** (below) |
| `StakingRewards.sol:168` `onlyOwner` | freezes `rewardsDistribution` | **NOT necessary — already dead** |
| `CoinDAOFactory.sol:488` `renounceOwnership()` | "makes the loss irreversible" | **NOT necessary — see below** |
| `StakingRewards.sol:172–173` (removal of `recoverERC20`) | no recovery path | **NOT sufficient alone — see FP3-05** |

**L70 is the necessary line — proven by mutation.** In the mutation tree
(`fp3m`, M1 = L70 deleted), `testM1_DeletingTheTrancheGateMakesDonationsClaimable`:
```
after 4 tranches: nextTranche == 4, funder balance == 0
1,000 GOV top-up sent to the funder
fundNextTranche()  -> SUCCEEDS  (L92's `tranche < 3` is false, so tranche 4 sweeps)
funder balance     -> 0         ; sr.rewardRate() == 1000e18 / 365 days
one period later, alice received: 1,099,999,999,999,903,968,000 wei
```
Deleting one line converts the permanent GOV sink into a permissionless top-up conduit.
Everything else about the system — `nextTranche`'s monotonicity, the renounced owner, the
missing `recoverERC20` — is unchanged and irrelevant to that outcome.

**Both failure modes of removing it, priced by execution.**
`testM1_CreatedFailureMode_OneWeiGriefLocksAPeriod`:
```
1 wei donated -> fundNextTranche() succeeds -> rewardRate == 0  (1 wei / 365 days truncates)
a genuine 1,000 GOV top-up is then blocked for 31,536,000 s by PreviousTrancheActive
```
So L70's removal is **not** a free fix: it exposes a 1-wei grief that locks the pool out of
any real top-up for a full year. That is the created mode, and it is a direct consequence of
the same `x != 0`-instead-of-`x >= min` pattern as FP3-06.

**`renounceOwnership()` is not the line that makes it terminal.** **Two** lanes attribute
irreversibility to `CoinDAOFactory.sol:488`: emissions FF-001 (*"`recoverERC20` was removed
and `owner()` renounced, so nothing can move it"*) and the factory lane, which annotates the
line `renounceOwnership(); <-- makes it permanent`. Neither checked whether the factory
could have acted as owner had the line been absent. **The state was already terminal before that
line ran.** `forge inspect CoinDAOFactory methods` shows the factory's entire mutating
external surface is `deploy`, `deployForExistingCoin`, `setPendingMonolithBeneficiary`,
`acceptMonolithBeneficiary`. **No factory function can act as the owner of a deployed
`StakingRewards`.** Had L488 been omitted, `owner()` would be the factory and every
owner-only entry point would remain unreachable forever — the only difference is that a
block explorer would show a non-zero owner and the position would *look* recoverable.
`renounceOwnership()` is the honest line here, not the fatal one
(`testP3_05_RenounceIsNotTheLineThatMakesItTerminal`, level 3 + ABI-verified).

**One decision, three defects.** `_trancheAmount`'s L92 predicate puts the balance sweep
*inside* tranche 3 rather than in a tranche 4. That single choice produces, simultaneously:

1. **FF-005** — `trancheBps(3)`'s `1_750` becomes unreachable code (grep-verified this pass:
   `trancheBps` has exactly one internal call site, guarded `tranche < 3`), so the published
   17.5% has nothing behind it, and `trancheAmount(3)` reports a live balance instead of a
   schedule figure.
2. **MASK-02** — `if (balance < amount)` at L80 compares two reads of the same value on
   tranche 3, so the one tranche whose amount is unbounded and donation-influenceable is the
   one with no funding validation (FP3-07 measures the slack).
3. **GAP-06** — with the sweep consumed at tranche 3, L70 fires on the very next call, and
   the funder becomes a sink.

`testP3_04_OneDecisionThreeDefects` walks all three in one run:
```
trancheBps(3) implies (wei)  : 17,500,000,000,000,000,000
tranche 3 actually pays (wei): 17,500,000,000,000,000,000   <- equal ONLY because nobody donated
donate 5 GOV -> trancheAmount(3) == 22,500,000,000,000,000,000   (absorbed silently, L80 cannot object)
fund tranche 3 -> nextTranche == 4, balance == 0
donate 5 GOV again -> fundNextTranche() reverts AllTranchesFunded   (destroyed)
```
The first assertion is the one worth putting in the report: **the published schedule and the
actual final tranche agree only in the case where nothing unexpected has happened, which is
exactly the case in which no check was needed.**

**Mutation-tree side effect worth recording.** With M1 applied, the project's own
`testPermissionlessFourTrancheLifecycleAssignsFinalDust` fails — but it fails on the *error
selector* (`PreviousTrancheActive` instead of `AllTranchesFunded`), not on any value. The
only test that observes L70 observes it as a revert string.

---

### FP3-05 — note — restoring `recoverERC20` moves the mask; it does not remove it

**Assignment item 5.** Pass 1 (FF-001, A6) identifies the removal of `recoverERC20` as one
of three decisions that convert the burn from temporary into permanent, and engages the
port's comment: *"the launch flow does not INVOKE it, but the launch flow is precisely what
CREATES the stranded balance recoverERC20 would address."* Correct. But the implied remedy
does not survive its own pricing.

**Step 1 — the restored function is dead code on its own.** `testM2_RecoverIsDeadCodeWithoutAnOwner`
(mutation tree, M2 = Synthetix `recoverERC20` restored verbatim in shape): after
`renounceOwnership()`, `recoverERC20(gov, 1)` reverts `OwnableUnauthorizedAccount`. So the
remedy is not *"restore `recoverERC20`"*; it is **"keep an owner"** — and that is the
decision whose second failure mode must be priced.

**Step 2 — the second failure mode, executed.** Synthetix's `recoverERC20` excludes only the
**staking** token. `testM2_RestoredRecoverERC20SeizesRewardsAlreadyOwed`:
```
alice earned, unclaimed (wei) : 16,027,397,260,268,544,000   (180 days into tranche 0)
recoverERC20(stakingToken, 1) -> revert "Cannot withdraw the staking token"   (protected, as upstream)
recoverERC20(rewardsToken, balance) -> SUCCEEDS ; owner seized 32,500,000,000,000,000,000
alice.getReward()             -> REVERTS (ERC20InsufficientBalance)
gov.balanceOf(alice)          == 0
```
An owner able to recover the stranded emissions is, by the same function and with no
additional privilege, able to seize every reward already earned and unclaimed. **The mask
moves from "the loss is invisible" to "the loss is now discretionary."** For a system whose
whole design point is a fixed, credibly-neutral four-year emission schedule, that is a
material change in trust assumptions, and Pass 1's write-up prices only the mode the fix
prevents.

**What a fix that removes rather than moves the mask would need.** A recovery function whose
recoverable amount is bounded below by the accounting — i.e. `balance - Σ rewards[a] -
rewardRate * (periodFinish - lastTimeRewardApplicable())`. `StakingRewards` does not track
`Σ rewards[a]` and therefore **cannot compute its own uncredited surplus** — which is the
same missing quantity that makes FF-002's fix uncomputable from outside (Pass 1 stated this
for the funder side). **One missing accumulator blocks both remedies.** That, not the
absence of `recoverERC20`, is the thing to recommend adding.

---

### FP3-06 — LOW — `ZeroRewards` stops the exact-zero case; the dust case burns three years

**Feynman question:**
> Q1.4 — *"Is this check SUFFICIENT for what it is trying to prevent?"* applied to
> `if (totalRewards_ == 0) revert ZeroRewards();` (`StakingRewardsFunder.sol:42`).

The guard's purpose is to stop a funder that can never pay anything. It tests
`totalRewards_ == 0`. The quantity that must be non-trivial is
`totalRewards_ * trancheBps(k) / 10_000`, which is zero for **any** `totalRewards_` below
~4 wei and, more relevantly, for any `totalRewards_` grossly smaller than the balance
actually delivered.

**Verification — Method B, `testP3_06_ZeroRewardsGuardStopsZeroNotDust`.** A funder
initialised with `totalRewards_ = 3` (accepted) and delivered 40 GOV, with a real staker
present for the whole time:
```
tranche 0: rewardRate == 0   -> a full 365-day period at zero emission
tranche 1: rewardRate == 0   -> another
tranche 2: rewardRate == 0   -> another
earned(alice) after three years == 0     (asserted)
tranche 3 (the sweep): rewardRate == 1,268,391,679,350 wei/s   -> only now does anything stream
```
**Three full years of a four-year schedule are consumed emitting nothing, and every guard in
both contracts passes at every step.** `InsufficientBalance` cannot fire (0 required),
`ZeroRewards` already passed, `PreviousTrancheActive` is satisfied, and
`require(rewardRate <= balance/duration)` is trivially true at `rewardRate == 0`.

**Resolution of the guard** (`testP3_06_Control_ZeroRewardsGuardFiresAtExactlyZero`):
`initialize(sr, 0)` reverts `ZeroRewards`; `initialize(sr, 1)` succeeds and
`trancheAmount(0) == 0`. **The guard's resolution is exactly one wei** — it discriminates
nothing else.

**Reachability.** Not reachable through the factory, which passes
`allocation.coinStakingRewards` to both `initialize` (`CoinDAOFactory.sol:448`) and
`safeTransfer` (`CoinDAOFactory.sol:485`) as the same expression. Reachable through any
hand-rolled or scripted deployment of the clone pair — which `initialize`'s two-argument
signature invites, and which is precisely how GAP-05 is reachable. **LOW on that basis, and
it is GAP-05's mirror: GAP-05 is `totalRewards_` too high, this is `totalRewards_` too low,
and neither direction is checked against the delivered balance.**

**The family.** Three constructs in this machinery share the shape *"reject exactly zero,
say nothing about dust"*: `require(amount > 0)` at `StakingRewards.sol:113` (FF-003's dust
capture), `require(amount > 0)` at L122 (FF-004), and `if (totalRewards_ == 0)` here. In
each case the exact-zero case is a harmless no-op and the dust case is the one that costs
something. **A fourth instance was created by this pass's own mutation experiment** — M1's
1-wei grief (FP3-04) is the same shape again. The report should name the pattern once rather
than four times.

---

### FP3-07 — note — slack table for `InsufficientBalance` across all four tranches

Pass 2 proved L80 dead on tranche 3. This pass measures what it is worth on the other
three, so the report can say precisely how much validation exists rather than dismissing the
check wholesale. `testP3_07_L80SlackTablePerTranche`, 100 GOV promised and delivered:

| tranche | `amount` required (wei) | `balance` held (wei) | **slack** | what the slack IS |
|---|---|---|---|---|
| 0 | 32,500,000,000,000,000,000 | 100,000,000,000,000,000,000 | 67,500,000,000,000,000,000 | tranches 1+2+3 |
| 1 | 27,500,000,000,000,000,000 | 67,500,000,000,000,000,000 | 40,000,000,000,000,000,000 | tranches 2+3 |
| 2 | 22,500,000,000,000,000,000 | 40,000,000,000,000,000,000 | 17,500,000,000,000,000,000 | tranche 3 |
| **3** | 17,500,000,000,000,000,000 | 17,500,000,000,000,000,000 | **0** | **nothing — the same read** |

**Read this against MASK-01's table.** Pass 2 measured `require(rewardRate <= balance /
rewardsDuration)` and found its slack was **the GOV that GAP-01 had already destroyed** — a
defect feeding its own detector. L80's slack is the opposite and healthier: it is the
*future schedule*, a quantity the contract genuinely owns. So L80 on tranches 0–2 is a real
check with real resolution — it is exactly the check that catches GAP-05's deficit — and its
slack decays monotonically to zero at tranche 3, where the operands become the same value
and the check stops meaning anything.

**Resolution on tranche 3** (`testP3_07_Resolution_TrancheThreeCheckHasNoResolution`): the
funder's balance is moved to an arbitrary value (1 wei) and the sweep still succeeds,
setting `rewardRate == 0` and pushing `periodFinish` a full year forward. The check has **no
resolution at all** on the tranche where the amount is unbounded and externally
influenceable.

**Two guards, two ways of being useless, one report line:** L160's slack is made of a
defect's proceeds; L80's slack is made of the schedule and then runs out exactly where the
schedule does. Neither can fail at the moment the system is most exposed.

---

## HYPOTHESES TESTED AND REFUTED THIS PASS

*A refutation is a claim too. Each of these was pursued to a conclusion, by hand or by
execution, before being dropped.*

| # | Hypothesis | How it was killed | Verdict |
|---|---|---|---|
| P3-R1 | `RevenueRouter.sol:72`'s supply read is stale by L79 — the `safeTransfer` at L78 could let a hooked Coin burn the stGOV supply in between, making the "dead" guard live | Structurally possible **only** with a reward token that has a transfer hook, which `INotifiableRewardReceiver` (L12–13) and `RevenueRouter` (L16–17) both document as unsupported. And the consequence would be a revert, not a loss. **Precise statement for the report: FP3-02's guard is dead under the token behaviour the contract requires, and its only reachable trigger is the token behaviour the contract forbids.** | NOT A FINDING |
| P3-R2 | `depositFor`'s `harvestYield`-before-mint ordering lets a new depositor capture revenue that accrued before they arrived | Executed: `testP3_03_Control_HealthyLenderAllowsEntry` — with 50 coin pending, carol deposits and `earned(carol) == 0` while `earned(alice) == 50 ether`. The modifier order `nonReentrant harvestYield updateReward(account)` then mint is **correct and deliberate**. | NOT A FINDING (good design) |
| P3-R3 | `StakedGovToken.notifyRewardAmount` is re-entered during `depositFor`'s harvest and sees inconsistent state | It *is* re-entered — deliberately, and `notifyRewardAmount` correctly carries no `nonReentrant` so the harvest can complete. Traced: `distribute()` bumps `rewardPerTokenStored` against the **old** supply, `updateReward(account)` then settles the depositor at the new value, and only then does the mint occur. Correct at every step. | NOT A FINDING |
| P3-R4 | `rewardPerTokenStored += mulDiv(reward, 1e18, supply)` can overflow or truncate materially | Truncation is bounded by `supply / 1e18` wei per notify (≤ 1e7 wei at a 10M-token supply, i.e. 1e-11 tokens); overflow needs `reward · 1e18 / supply > 2^256`, unreachable at a 10,000,000-token fixed supply. Same magnitude conclusion as Pass 2's FP-3, reached on the sibling contract by a different route. | NOT A FINDING |
| P3-R5 | `_update`'s `NonTransferable` guard is incomplete — some mint/burn path skips `updateReward` | Build-artifact absence claim: the only state-changing entry points on `StakedGovToken` are the six listed in FP3-03 plus `notifyRewardAmount`/`delegate`/`approve`/`permit`/`initialize`. `_recover` is not exposed. Every mint and burn goes through `depositFor` or `withdrawTo`, both of which settle first. | NOT A FINDING |
| P3-R6 | `renounceOwnership()` at `CoinDAOFactory.sol:488` is the line that makes GAP-06 irreversible | Refuted by ABI inspection: the factory has no function able to act as `StakingRewards`'s owner, so the position was already unrecoverable before L488 ran. **Held by two lanes (emissions FF-001 and the factory lane's inline annotation); both should be corrected in the report.** | REFUTED — see FP3-04 |
| P3-R7 | Pass 2's MASK-04 clearance of `if (reward > 0)` is correct | **Refuted by execution** — FP3-01. Recorded here because it is the only prior-pass verdict this pass overturns, and because default-REFUTED posture cuts both ways. | REFUTED |

---

## CORPUS EXCLUSION ANALYSIS (sibling machinery — new)

Pass 2 did this for the `StakingRewards` suite. The same reading of the uncovered suite:

| Test / mock | What it excludes | Consequence |
|---|---|---|
| `test/StakedGovToken.t.sol:29–33` — the staker is constructed with **`address(this)` as `revenueRouter_`** | every test in the file drives `notifyRewardAmount` from a position the real router can never occupy | `testRewardNotificationGuards` (L64–67) **certifies a guard that is structurally dead in production** (FP3-02) |
| `test/StakedGovToken.t.sol:229` `testDistributorFailure…ButPlainWithdrawStillWorks` | asserts `depositFor` reverts during an outage, and treats that as the expected result | the project already knows entry is closed; the frame is *"can stakers get out?"* — **survivorship**: a test scoped to exits cannot see a frozen electorate (FP3-03) |
| `test/mocks/MockMonolith.sol:52–56` `pullLocalReserves()` | `if (accruedLocalReserves == 0) return;` — **it cannot revert** | no factory-level test in the tree can reach a distributor outage at all; the failure is only reachable through the hand-rolled mock in one unit file |
| `StakedGovToken.t.sol` as a whole | never deploys a `RevenueRouter` | the `L72 ↔ L170` predicate duplication — the finding — is invisible to every test that exists |

No test in the tree asserts *"a new participant can always acquire voting power"* or
*"the stGOV electorate is not monotonically shrinking."* Those are the assertions FP3-03
would have failed.

---

## PROVENANCE AND CONVERGENCE

Recorded in full because a prior-pass check was run late and changed two gradings.

**The process error.** This pass was pointed at `feynman-pass1-emissions.md` and
`state-pass2-emissions.md`. It widened scope to `StakedGovToken` / `RevenueRouter` on the
stated grounds that *"neither prior pass read a line of it."* That was an **absence claim
made without grepping for the negative** — the exact failure the workspace rule singles out.
`.audit/findings/` contains a dedicated revenue lane (`feynman-pass1-revenue.md`,
`state-pass2-revenue.md`) that audited both files line-by-line, and a governance lane
(`feynman-pass1-governance.md`) that analysed the quorum/threshold constants. The directory
was enumerated only after the census was complete. **Two findings were downgraded from NEW to
CONVERGENT as a result; nothing was withdrawn.**

**What the error cost, and what it bought.** It cost effort duplicated against
revenue-lane FF-004. It bought un-primed convergence on three independent lines of work:

| this pass | reached blind by | already held by | value |
|---|---|---|---|
| FP3-02 dead `NoStakedSupply` | Q1.2 on the guard | revenue FF-011 (INFO) + Pass 2 M1 | convergence; **the GAP-02 comparison is new** |
| FP3-03 mint-path freeze | Q3.2 inverse-parity across the four entry points | revenue **FF-004** (HIGH, lead) | convergence; **the proposal-threshold floor is new** |
| FP3-03 quorum arithmetic | executed measurement | governance lane (capture direction) | **the liveness direction is new** |

Discovery here was genuinely blind — those files were not opened until after the findings
were written — so the agreement is evidence, not an echo. **The report should cite the
revenue lane's versions of FF-004 and FF-011 and carry only the cross-lane joins from this
page.**

**Novelty, restated honestly.** Genuinely new this pass: **FP3-01** (overturns Pass 2's
MASK-04), **FP3-04** (terminality hinges on one line; one decision → three defects;
`renounceOwnership()` exonerated), **FP3-05** (the implied remedy moves the mask),
**FP3-06** (`ZeroRewards` burns three years), **FP3-07** (the slack table), and the two
cross-lane joins above. **Convergent, not new: FP3-02's and FP3-03's core mechanisms.**

---

## SUMMARY

- **Defensive constructs interrogated: 35**, across four contracts, with Q1.1/Q1.2 answered
  for every one. Two of the four (`StakedGovToken`, `RevenueRouter`) had been audited by a
  separate lane this pass was not shown — see *Provenance and convergence*.
- **Structurally dead or non-protective constructs found: 9** — `StakedGovToken.sol:170`
  (dead from its only caller), `StakingRewardsFunder.sol:80` on tranche 3 (Pass 2, slack now
  measured at exactly 0), `StakingRewards.sol:168` (`onlyOwner`, no owner),
  `StakingRewardsFunder.sol:60` (internally unreachable), `StakingRewards.sol:153–157` (dead
  `else`), and four gas-only or error-message-only constructs presenting as guards
  (`StakingRewards.sol:71`, `StakedGovToken.sol:87`, `StakingRewardsFunder.sol:76`,
  `StakingRewardsFunder.sol:41`).
- **New findings: 1** (FP3-06) · **new structural analyses of known gaps: 3** (FP3-04,
  FP3-07, and the two cross-lane joins carried by FP3-02/FP3-03) · **prior-pass
  corrections: 2** (FP3-01 overturns Pass 2's MASK-04 clearance; FP3-04/P3-R6 corrects Pass
  1's attribution of irreversibility to `renounceOwnership()`) · **remedy re-pricing: 1**
  (FP3-05) · **convergent re-derivations: 2** (FP3-02, FP3-03 — see *Provenance*).
- **Refuted this pass: 7** (P3-R1 … P3-R7), two of which were previously-accepted claims.
- **Verification level: 4 (executed in the real environment)** for every finding, including
  two source-mutation experiments answering Q1.2 directly. Controls and resolution
  measurements accompany every headline claim (FP3-01, FP3-02, FP3-03, FP3-06, FP3-07).
- **Evidence integrity:** `[scratch]` unmodified — `git diff --stat -- [scratch]`
  empty. 15 audit tests in `%TEMP%/…/[scratch]` (**70/70**), 4 mutation
  tests plus two labelled source mutations in `%TEMP%/…/[scratch]` (58/59, the single
  failure being a project test observing M1's revert selector). Nothing was executed against
  any external system.

### The answer to the question this pass was set

The pattern generalises past the two instances Pass 2 found, and it has **three distinct
shapes** in this codebase, which the report should name separately:

1. **The guard whose slack is a defect's proceeds** — `StakingRewards.sol:160`. Slack zero
   at tranche 0, and thereafter exactly the GOV that GAP-01 stranded.
2. **The guard whose operands are the same value** — `StakingRewardsFunder.sol:80` on
   tranche 3 (slack measured at 0, FP3-07) and, newly, **`StakedGovToken.sol:170`**, whose
   predicate is decided by its only caller one line earlier.
3. **The guard that certifies the wrong function's inertness** — `StakingRewards.sol:132`,
   which makes a call that has already consumed the emission clock read as a no-op (FP3-01).

And the sharpest single result of the pass is not a dead guard but a **present** one.
`RevenueRouter.sol:72` — *do not price a distribution against a supply that does not
exist* — is the exact coupling Pass 2 proved to be missing from `rewardRate` × `_totalSupply`
(GAP-02). It is written correctly, by the same authors, in the same deployment. It is
applied to the reward path that loses nothing when it is absent, and omitted from the one
that loses 6,500,000 GOV worth of emissions. **The design comment at
`StakingRewards.sol:147–149` should be read in that light: the hazard was not
unrecognised — it was recognised and guarded, in the other contract.**
