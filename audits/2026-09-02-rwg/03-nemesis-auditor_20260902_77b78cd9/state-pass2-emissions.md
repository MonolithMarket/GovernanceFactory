# NEMESIS Pass 2 — State Inconsistency Auditor: emissions pair

**Methodology:** `.claude/skills/state-inconsistency-auditor/SKILL.md`, Phases 1–8, executed in full.

**Scope (line-by-line):**
- `[scratch]` (174 lines)
- `[scratch]` (96 lines)

**Read for cross-contract state only:** `CoinDAOFactory.sol` (L273–292, L420–520),
`GovToken.sol`, `RevenueRouter.sol` (to confirm it does *not* target this `StakingRewards`),
`test/` (corpus-exclusion analysis). **Not read:** `[scratch]`, `engagements/`.

**Enrichment consumed before starting:** `.audit/findings/nemesis-phase0-recon.md` (§Q0.5
rows 1, 2, 3, 7) and `.audit/findings/feynman-pass1-emissions.md` (FF-001…FF-009, A1–A7,
O1–O9, R-01…R-05). Pass 1's handoff pair — `rewardRate` × `_totalSupply` mediated by
`lastUpdateTime` — is confirmed and decomposed below into its two underlying storage pairs.

**Language:** Solidity 0.8.26, EIP-1167 clones, Foundry, via-ir, optimizer 200.

**Execution:** available and used. PoC tree = a **copy** at
`%TEMP%/claude/c--RWG-CodeAudit/.../[scratch]`, 19 audit tests in
`test/audit/StatePass2.t.sol` (16) and `test/audit/StatePass2Factory.t.sol` (3).
Full suite in the copy: **74/74 pass** (55 original + 19 audit).
`[scratch]` was **not modified** — `git diff --stat -- [scratch]` is empty.

> ⚠ **Harness artifact recorded so a later pass does not mistake it for a defect.**
> This repo builds with `via-ir`; the optimizer caches `block.timestamp` inside a test
> function across `vm.warp`. Three PoCs initially failed for this reason alone. Every
> timestamp in the PoCs is therefore read with `vm.getBlockTimestamp()`. **This is a
> property of the test harness, not of the contracts under audit** — the contracts read
> `block.timestamp` in their own call frames, where no such caching occurs. Verified by an
> instrumented debug run before any conclusion was drawn.

---

## PHASE 1 — COUPLED STATE DEPENDENCY MAP

### Storage inventory (declarations read directly; no pair assumed without a code site that reads both)

`StakingRewards` (SR): `stakingToken` L21, `rewardsToken` L22, `rewardsDistribution` L24,
`_totalSupply` L26, `_balances[a]` L27, `periodFinish` L29, `rewardRate` L30,
`rewardsDuration` L31, `lastUpdateTime` L32, `rewardPerTokenStored` L33,
`userRewardPerTokenPaid[a]` L34, `rewards[a]` L35, plus inherited `Ownable._owner`.

`StakingRewardsFunder` (F): `stakingRewards` L20, `rewardsToken` L21, `totalRewards` L22,
`nextTranche` L24.

**Implicit state** (not declared here, but coupled and mutable by third parties):
`rewardsToken.balanceOf(SR)`, `stakingToken.balanceOf(SR)`, `rewardsToken.balanceOf(F)`.

```
+--------------------------------------------------------------------------------+
| COUPLED STATE DEPENDENCY MAP                                                     |
+--------------------------------------------------------------------------------+
|                                                                                  |
| PAIR A: _totalSupply  <->  rewardPerTokenStored                        [HELD]    |
|   Invariant: rewardPerTokenStored must be settled to lastTimeRewardApplicable()  |
|              IMMEDIATELY BEFORE _totalSupply changes, so the elapsed interval is |
|              priced at the supply actually in force during it.                   |
|   Read together at: L96-97 (rewardPerToken)                                      |
|   Mutation points for _totalSupply: stake L114, withdraw L123 - both carry       |
|              updateReward(msg.sender). No third writer exists (grep-verified).   |
|                                                                                  |
| PAIR B: lastUpdateTime  <->  rewardPerTokenStored                    [BROKEN]    |
|   Invariant: advancing the clock from t0 to t1 must add                          |
|              INTEGRAL( rewardRate * 1e18 / _totalSupply ) dt to the accumulator. |
|              Every second the clock consumes must be represented in the          |
|              accumulator, or that second's emission is unrepresented forever.    |
|   Read together at: L96 (both operands of the same expression)                   |
|   Mutation points: updateReward L69+L70 (together), notifyRewardAmount L162      |
|              (lastUpdateTime ALONE).                                             |
|   BREAKS whenever _totalSupply == 0: L95 short-circuits the accumulator while    |
|              L70 advances the clock regardless.                       -> GAP-01  |
|                                                                                  |
| PAIR C: _balances[a] <-> userRewardPerTokenPaid[a] <-> rewards[a]      [HELD]    |
|   Invariant: userRewardPerTokenPaid[a] == rewardPerTokenStored at the instant    |
|              _balances[a] last changed; rewards[a] holds all prior accrual.      |
|   Read together at: L102 (earned)                                                |
|   Mutation points for _balances[a]: stake L115, withdraw L124 - both             |
|              [msg.sender] only, both settle first. There is no transfer, no      |
|              delegation, no admin seizure, no liquidation, no batch path.        |
|                                                                                  |
| PAIR D: rewardRate  <->  _totalSupply                                [BROKEN]    |
|   Invariant (economic): rewardRate is only delivered to holders in seconds where |
|              _totalSupply > 0; it must therefore not be set, or must be paused,  |
|              while _totalSupply == 0.                                            |
|   Read together at: NOWHERE. rewardRate is written only by notifyRewardAmount,   |
|              which never reads _totalSupply. _totalSupply is written only by     |
|              stake/withdraw, neither of which reads rewardRate or periodFinish.  |
|              This is the pair Pass 1 handed over.        -> GAP-02, GAP-03       |
|                                                                                  |
| PAIR E: rewardRate/periodFinish <-> SUM(rewards[a]) <-> balanceOf(SR)  [UNGUARDED]|
|   Invariant that SHOULD hold:                                                    |
|       balanceOf(SR) >= SUM(earned(a)) + rewardRate*(periodFinish - lastTimeRA)   |
|   The only check present, L160, asserts a strictly weaker thing and omits the    |
|   SUM(rewards[a]) term entirely.                                     -> MASK-01  |
|                                                                                  |
| PAIR F: _totalSupply  <->  stakingToken.balanceOf(SR)          [ASSUMED, unenforced]|
|   Invariant: stakingToken.balanceOf(SR) >= _totalSupply.                         |
|   stake credits BEFORE transferring (L114-116): the credit is a claim about the  |
|   token, not a measurement of it. Also, a direct donation of stakingToken to SR  |
|   raises the balance with no matching _totalSupply and is unrecoverable.         |
|   (Pass 1 FF-008 lead; partially resolved below.)                                |
|                                                                                  |
| PAIR G: nextTranche <-> totalRewards <-> rewardsToken.balanceOf(F)   [BROKEN]    |
|   Invariant implied by _trancheAmount:                                           |
|       balanceOf(F) == totalRewards - SUM(amount_i, i < nextTranche)  for k <= 2  |
|   balanceOf(F) has a mutation path that neither `nextTranche` nor `totalRewards` |
|   can observe: an inbound ERC20 transfer from anyone. `totalRewards` is written  |
|   once at L46 and never again.                     -> GAP-04, GAP-05, MASK-02    |
|                                                                                  |
| PAIR H: nextTranche (TERMINAL at 4) <-> balanceOf(F) (NOT terminal)  [BROKEN]    |
|   Invariant needed: once nextTranche == 4, balanceOf(F) must be 0 forever.       |
|   Nothing enforces or restores this.                                 -> GAP-06   |
|                                                                                  |
| PAIR I: F.nextTranche  <->  SR.periodFinish  (cross-contract)          [HELD]    |
|   The funder serialises tranches on a FOREIGN contract's emission clock (L72-73).|
|   Held - but it is precisely why SR's rollover branch is dead: the funder's gate |
|   and L151's condition are the same predicate on opposite sides. (Pass 1 FF-002.)|
|                                                                                  |
| PAIR J: F.rewardsToken  <->  SR.rewardsToken  (cross-contract)          [HELD]   |
|   F caches SR's value at L45; SR's is write-once at L57. The cache cannot go     |
|   stale. (It IS read before SR is proven initialised - Pass 1 A4.)               |
|                                                                                  |
| PAIR K: F.stakingRewards <-> SR.rewardsDistribution (cross-contract)    [HELD]   |
|   Re-read on every call at L75-76 rather than cached. Correct.                   |
|                                                                                  |
| PAIR L: SR.rewardsDuration  <->  F's "yearly" 4-tranche plan          [BROKEN]   |
|   The cadence lives in SR; the plan lives in F's comment L50. No code links      |
|   them. Documentation-vs-code only. (Pass 1 A5.)                                 |
+--------------------------------------------------------------------------------+
```

**Anti-hallucination discipline applied:** every pair above names a line where the two
values are read together, or is explicitly marked as a pair that is read together
*nowhere* (PAIR D) — which is itself the finding.

---

## PHASE 2 — MUTATION MATRIX

Every write site was located by grep, not by reading function bodies alone. Absence
claims were grepped for the negative, per workspace rule.

```
grep -rn "_totalSupply" src/  -> writes at L114, L123 ONLY
grep -rn "_balances"    src/  -> writes at L115, L124 ONLY, both [msg.sender]
grep -n  "receive\|fallback" src/StakingRewards.sol src/StakingRewardsFunder.sol -> none
grep -rn "notifyRewardAmount" src/ script/ -> SR's is called from ONE site: Funder L85
     (RevenueRouter.sol:79 calls INotifiableRewardReceiver `govStaking`, which the
      factory wires to StakedGovToken, NOT to this StakingRewards. Confirmed.)
grep -rn "setRewardsDistribution" src/ script/ -> definition + ONE caller, factory L486
grep -rn "fundNextTranche" src/ script/ -> definition + ONE caller, factory L487
```

### `StakingRewards`

| State variable | Mutating site | Type of mutation | Coupled state also updated? |
|---|---|---|---|
| `_totalSupply` | `stake` L114 | `+= amount` | PAIR A settled by `updateReward` ✓ / PAIR D **never** ✗ |
| `_totalSupply` | `withdraw` L123 | `-= amount` | PAIR A settled by `updateReward` ✓ / PAIR D **never** ✗ |
| `_balances[a]` | `stake` L115 | `+= amount` (msg.sender) | PAIR C settled ✓ |
| `_balances[a]` | `withdraw` L124 | `-= amount` (msg.sender) | PAIR C settled ✓ |
| `rewardPerTokenStored` | `updateReward` L69 | `= rewardPerToken()` | **returns unchanged when `_totalSupply == 0`** ✗ |
| `lastUpdateTime` | `updateReward` L70 | `= lastTimeRewardApplicable()` | **advances even when the accumulator did not** ✗ |
| `lastUpdateTime` | `notifyRewardAmount` L162 | `= block.timestamp` | lone write to one half of PAIR B — **verified benign, see FP-1** |
| `rewards[a]` | `updateReward` L72 | `= earned(a)` (settle) | ✓ |
| `rewards[a]` | `getReward` L133 | `= 0` before transfer L134 | ✓ CEI correct |
| `userRewardPerTokenPaid[a]` | `updateReward` L73 | `= rewardPerTokenStored` | ✓ |
| `rewardRate` | `notifyRewardAmount` L152 | `= reward / rewardsDuration` | **does not read `_totalSupply`** ✗ / does not read `Σrewards[a]` ✗ |
| `rewardRate` | `notifyRewardAmount` L156 | `= (reward+leftover)/duration` | **UNREACHABLE from the funder** (PAIR I) |
| `periodFinish` | `notifyRewardAmount` L163 | `= now + rewardsDuration` | ✓ written with `rewardRate` and `lastUpdateTime` |
| `rewardsDuration` | `initialize` L59 | write-once (setter removed) | n/a |
| `rewardsDistribution` | `initialize` L58 | write-once default | n/a |
| `rewardsDistribution` | `setRewardsDistribution` L169 | `onlyOwner` | **dead**: owner renounced at factory L488 |
| `stakingToken`/`rewardsToken` | `initialize` L56/L57 | write-once | n/a |
| `Ownable._owner` | `initialize` L55 / `renounceOwnership` | → `address(0)` at factory L488 | **terminal** |
| *(implicit)* `rewardsToken.balanceOf(SR)` | Funder L84 | `+= amount` | tracked by `rewardRate` ✓ |
| *(implicit)* `rewardsToken.balanceOf(SR)` | `getReward` L134 | `-= rewards[a]` | tracked ✓ |
| *(implicit)* `rewardsToken.balanceOf(SR)` | **any external transfer** | `+= anything` | **tracked by nothing** ✗ → GAP-04 |
| *(implicit)* `stakingToken.balanceOf(SR)` | `stake` L116 / `withdraw` L125 | ±amount | PAIR F, assumed exact |
| *(implicit)* `stakingToken.balanceOf(SR)` | **any external transfer** | `+= anything` | **tracked by nothing** ✗ (stranded, benign) |

### `StakingRewardsFunder`

| State variable | Mutating site | Type of mutation | Coupled state also updated? |
|---|---|---|---|
| `stakingRewards` | `initialize` L44 | write-once | n/a |
| `rewardsToken` | `initialize` L45 | write-once, cached from SR | PAIR J ✓ (but read before SR is proven initialised — A4) |
| `totalRewards` | `initialize` L46 | write-once | **never validated against the delivered balance** ✗ → GAP-05 |
| `nextTranche` | `fundNextTranche` L82 | `= tranche + 1`, before the external calls | correct CEI ✓ |
| *(implicit)* `rewardsToken.balanceOf(F)` | `fundNextTranche` L84 | `-= amount` | tracked by `nextTranche` ✓ |
| *(implicit)* `rewardsToken.balanceOf(F)` | factory L485 | `+= allocation` | **not validated against `totalRewards`** ✗ |
| *(implicit)* `rewardsToken.balanceOf(F)` | **any external transfer** | `+= anything` | **tracked by nothing** ✗ → GAP-04, GAP-06 |

**Primary audit targets from the matrix** (State A written with a coupled state not
updated): `_totalSupply` × PAIR D; `lastUpdateTime` × PAIR B at zero supply;
`balanceOf(F)` × `totalRewards`; `balanceOf(F)` × terminal `nextTranche`;
`balanceOf(SR)` × everything.

---

## PHASE 5 — PARALLEL PATH COMPARISON

### Group 1 — the two writers of `_totalSupply` / `_balances`

| Coupled state | `stake()` L112 | `withdraw()` L121 | (any third path) |
|---|---|---|---|
| `_totalSupply` | ✓ `+=` | ✓ `-=` | **none exists** (grep-verified) |
| `_balances[msg.sender]` | ✓ `+=` | ✓ `-=` | none |
| `rewardPerTokenStored` | ✓ via `updateReward` | ✓ via `updateReward` | — |
| `lastUpdateTime` | ✓ via `updateReward` | ✓ via `updateReward` | — |
| `rewards[msg.sender]` | ✓ settled | ✓ settled | — |
| `userRewardPerTokenPaid[.]` | ✓ settled | ✓ settled | — |
| `nonReentrant` | ✓ | ✓ | — |
| **`rewardRate` / `periodFinish`** | **✗ never consulted** | **✗ never consulted** | — |
| token movement order | credit **then** transfer | debit **then** transfer | symmetric |

**Verdict:** perfectly symmetric — and *uniformly* missing the same thing. This is the
inverse of the classic RULE 3 finding: there is no odd path out, because **both** paths
omit the `rewardRate` coupling. A one-sided omission would have been caught by review;
a two-sided one looks like consistency. Proven by `testSI_ParallelPaths_...` (positive
control: a stake → partial withdraw → full withdraw → exit journey distributes
99.99999999999936 of 100 ether, i.e. the per-account pairs are exact).

### Group 2 — the two branches of `notifyRewardAmount`

| | `if` branch L152 | `else` branch L153–157 |
|---|---|---|
| condition | `now >= periodFinish` | `now < periodFinish` |
| folds in unstreamed remainder | ✗ | ✓ |
| reachable from the funder | ✓ always | **✗ never** — funder L73 reverts on the same predicate |
| exercised by the project's own tests | ✓ | ✓ **but only by bypassing the funder** (see corpus note) |

### Group 3 — the two shapes of `_trancheAmount`

| | tranches 0–2 (L92) | tranche 3 (L94) |
|---|---|---|
| source of the amount | `totalRewards` (a stored promise) | `balanceOf(F)` (a live measurement) |
| `balance < amount` guard at L80 | can fire | **structurally cannot fire** — `amount` *is* `balance` |
| donation to F changes the amount | ✗ | ✓ 1:1 |
| `trancheBps(3) == 1_750` used | n/a | **never called** (Pass 1 FF-005) |
| behaviour at balance 0 | reverts `InsufficientBalance` | **succeeds**, notifies 0 → GAP-05 |

### Group 4 — donations of the same token to the two adjacent holders

| | GOV sent to **Funder** | GOV sent to **StakingRewards** |
|---|---|---|
| before tranche 3 | **swept and distributed** to stakers | **destroyed** — never credited |
| after tranche 3 | **destroyed** — `AllTranchesFunded` | **destroyed** |
| advertised by a view as claimable | ✓ `trancheAmount(3)` | ✗ |

Two adjacent contracts holding the same token give the same action opposite meanings,
and one of the four cells changes meaning purely with time. → GAP-04, GAP-06.

---

## PHASE 3/4/6 — GAPS

Severity uses the skill's table. **NEW / COVERED** is relative to
`feynman-pass1-emissions.md`.

| ID | Coupled pair | Breaking operation | Severity | Status vs Pass 1 |
|---|---|---|---|---|
| GAP-01 | PAIR B `lastUpdateTime` ↔ `rewardPerTokenStored` | `updateReward` L69–70 at zero supply | HIGH | **COVERED** (root cause of FF-001; state-level proof is new) |
| GAP-02 | PAIR D `rewardRate` ↔ `_totalSupply` (open side) | `notifyRewardAmount` L152 | HIGH | **COVERED** (FF-001 / FF-003) |
| GAP-03 | PAIR D `rewardRate` ↔ `_totalSupply` (drain side) | `withdraw` L123 / `exit` L140 **mid-period** | MEDIUM | **NEW PATH** under a covered pair |
| GAP-04 | PAIR G `balanceOf` ↔ `totalRewards` / nothing | any external transfer to F or SR | LOW | **NEW** (FF-005 saw the view; not the SR side or the asymmetry) |
| GAP-05 | PAIR G deficit direction | `fundNextTranche` L78–80 | LOW | **NEW** (A3 priced only the excess direction) |
| GAP-06 | PAIR H `nextTranche` terminal ↔ balance not terminal | `fundNextTranche` L70 after exhaustion | MEDIUM | **NEW** |
| MASK-01 | PAIR E solvency triple | `require` L159–160 | masking | **COVERED-as-note**, now executed |
| MASK-02 | PAIR G final tranche | `if (balance < amount)` L80 | masking | **COVERED-as-note**, now executed |
| MASK-03 | PAIR B | `if (_totalSupply == 0) return ...` L95 | masking | **COVERED** (FF-001) |

---

### GAP-01 — HIGH — The accumulator's clock advances without the accumulator
### **COVERED by Pass 1 FF-001** (this is its state-level root cause, proven directly)

**Coupled pair:** `lastUpdateTime` ↔ `rewardPerTokenStored` (PAIR B).
**Invariant:** every second the clock consumes must be represented in the accumulator.

**Breaking operation:** `updateReward` — `StakingRewards.sol:68–76`.

```solidity
modifier updateReward(address account) {
    rewardPerTokenStored = rewardPerToken();     // L69  returns UNCHANGED when _totalSupply == 0
    lastUpdateTime = lastTimeRewardApplicable(); // L70  advances ANYWAY
    ...
}
```

The two lines disagree about whether the interval happened. L69 says no, L70 says yes.
Because `rewardPerTokenStored` is monotone and `lastUpdateTime` only advances, the
disagreement is never revisited.

**Verification — Method B, `testSI01_ClockAdvancesWithoutAccumulator`.** This asserts the
*state* directly rather than inferring it from a payout:

```
seconds consumed by the clock : 864000        (lastUpdateTime advanced 10 days)
accumulator delta             : 0             (rewardPerTokenStored did not move)
emission consumed (wei GOV)   : 9,999,999,999,999,936,000
alice received                : 89,999,999,999,999,424,000
stranded in StakingRewards    : 10,000,000,000,000,576,000
```

**Resolution of the check** (mandatory, per workspace rule):
- `testSI01_Control_NoVacancyStrandsOnlyDust` → stranded **640,000 wei** (pure truncation).
- `testSI01_Resolution_OneSecondVacancyIsVisible` → a **one-second** vacancy strands
  **11,574,074,714,074 wei**, matching `rewardRate × 1s`.

The measurement therefore discriminates at ~1 second — it is not a tautology, and it is
not merely a ±10% instrument.

**Any caller can consume the clock.** `getReward()` is `public` with no minimum and no
access control; calling it from an address with no stake still runs L69–70. The PoC uses
exactly that path. Nothing about the burn requires a staker to act.

**Masking code (MASK-03):** `StakingRewards.sol:95`
```solidity
if (_totalSupply == 0) return rewardPerTokenStored;
```
*What invariant is it covering for?* Division by zero at L97 — which it does prevent. But
it is placed inside the function that L69 uses to *decide whether the interval happened*,
so it silently converts "cannot price this interval" into "this interval did not occur."
The guard needed to answer a division question and was made to answer a value question.
Removing it reverts; the correct repair is to stop the clock (do not advance
`lastUpdateTime` when `_totalSupply == 0`), which is a change at L70, not L95.

---

### GAP-02 — HIGH — `rewardRate` and `_totalSupply` are never read together anywhere
### **COVERED by Pass 1 FF-001 / FF-003**

**Coupled pair:** PAIR D. **Absence claim, grepped explicitly** (the dangerous kind, per
workspace rule): `rewardRate` appears at L30 (decl), L96 (read by `rewardPerToken`),
L108, L152, L155, L156, L160. `_totalSupply` appears at L26, L80, L95, L97, L114, L123.
**The only line where both appear is L96–97 — inside the accumulator, where the
`_totalSupply == 0` case has already been short-circuited one line earlier at L95.**
There is no write site of either variable that reads the other.

**Verification — `testSI08_BothEntryPointsOpenTrancheZeroAtZeroSupply`** (factory-deployed,
both entry points):

```
deploy():                 totalSupply() == 0, staking token totalSupply() == 0, rewardRate > 0
deployForExistingCoin():  totalSupply() == 0,                                   rewardRate > 0
rewardRate wei/s   : 66,986,935,565,702,688
burn per day (wei) : 5,787,671,232,876,712,243,200      (5,787.67 GOV/day)
burn per 30d (wei) : 173,630,136,986,301,367,296,000    (173,630.14 GOV)
```

Both entry points funnel through `_deployCoinDAO` (`CoinDAOFactory.sol:350`), so
L485–488 is universal — the vacancy is structural, not a property of one path.

**Verification of the mirror case — `testSI09_OneWeiDenominatorAtTrancheOpen`**
(factory-deployed, one transaction opens tranche 1 and stakes 1 wei):
```
tranche 1 size    : 1,787,500,000,000,000,000,000,000
captured by 1 wei : 1,787,499,999,999,999,988,128,000
sr.totalSupply()  : 1
assertEq(rewardRate, trancheOne / rewardsDuration)  <- rate set with no reference to supply
```
Same missing coupling, opposite sign: at supply 0 the tranche burns; at supply 1 wei it
concentrates.

---

### GAP-03 — MEDIUM — **NEW MUTATION PATH** — `withdraw()`/`exit()` can drive
### `_totalSupply` to zero mid-period, and neither reads the rate it is orphaning

**Coupled pair:** PAIR D. **NEW relative to Pass 1:** FF-001 measured the vacancy at
*genesis* and at *tranche boundaries* — both timing properties of the funder. The Mutation
Matrix surfaces a third mutation path that has nothing to do with the funder: the
decrement site at `StakingRewards.sol:123`, reachable by any staker at any second of a
live period, repeatable, and with no last-staker handling anywhere in the contract.

**Breaking operation:** `withdraw` L121–127 (and `exit` L140–143, which is the one-call
form). The function writes `_totalSupply` and never reads `rewardRate`, `periodFinish`, or
any measure of whether it is leaving the pool empty.

**Trigger sequence:** (1) a period is live with `rewardRate > 0`; (2) the last staker
calls `exit()`; (3) `_totalSupply == 0` while `rewardRate` and `periodFinish` are
untouched; (4) every subsequent second is consumed by GAP-01 until someone stakes again.

**Verification — Method B, `testSI02_MidPeriodDrainBurnsAtRewardRate`:**
```
assertEq(rewardRate,   rateBefore)   <- withdraw did not adjust rewardRate
assertEq(periodFinish, pfBefore)     <- withdraw did not adjust periodFinish
alice (staked 0-30d)  : 29,999,999,999,999,808,000
bob   (staked 60-100d): 39,999,999,999,999,744,000
total paid to stakers : 69,999,999,999,999,552,000
stranded              : 30,000,000,000,000,448,000   == rewardRate * 30 days
```

**Consequence, and why it is not merely a restatement of FF-001.** The genesis vacancy is
bounded by how quickly a market forms — a one-off. This path has **no bound at all** and
is *self-reinforcing*: the moment at which the last staker rationally leaves is exactly
the moment the pool has become unattractive, and their departure makes it strictly worse
by destroying the emissions that would otherwise have accrued to the next entrant. The
same missing coupling produces a *recurring* loss with no ceiling other than the tranche.

**Contrast worth stating in the report.** A *delay* between tranches costs nothing:
`lastTimeRewardApplicable()` caps at `periodFinish`, so an unfunded gap accrues no rate
and burns nothing. A *vacancy inside* a period costs `rewardRate` per second. The system
is therefore safe to leave uncalled and unsafe to call promptly — and
`CoinDAOFactory.sol:487` calls it at the single worst moment available.

---

### GAP-04 — LOW — **NEW** — The same token donated to the two adjacent holders has
### opposite fates, and one of them changes meaning with time

**Coupled pair:** PAIR G. **Invariant broken:** `balanceOf(F)` has a mutation path
(inbound transfer, permissionless, from anyone) that neither `totalRewards` (written once
at L46) nor `nextTranche` can observe. `balanceOf(SR)` has the same path with no tracker
at all.

**Verification — Method B, two tests:**

`testSI03a_DonationToFunderIsSweptAndDistributed`
```
totalRewards()      : 100 ether  (never observes the donation - asserted)
trancheAmount(3)    : 37.5 ether (17.5 fixed remainder + 20 donated)
staker finally gets : 119,999,999,999,983,680,000   -> the donation WAS distributed
```

`testSI03b_DonationToStakingRewardsIsDestroyed`
```
staker finally gets : 99,999,999,999,982,080,000    -> only the notified tranches
left in SR forever  : 20,000,000,000,017,920,000    -> the donation, destroyed
earned(bob) == 0 afterwards; a further getReward() is a no-op; the balance does not move
```

**Consequence.** `_trancheAmount`'s sweep is the *only* reconciliation between the
funder's promise and its real balance, it happens exactly once, it is silent, and it
covers the wrong contract. An integrator, a grant, a governance top-up, or a mistaken
transfer lands in one of two adjacent contracts holding the same GOV; one distributes it
and one destroys it, and nothing in either contract's interface says which.

---

### GAP-05 — LOW — **NEW** — The deficit direction of `totalRewards` bricks the funder
### permanently; only the excess direction is absorbed

**Coupled pair:** PAIR G. Pass 1's A3 recorded that `totalRewards_` is never validated
against the delivered balance and that "the sweep absorbs the difference." **The sweep
absorbs an excess. A deficit is terminal.** The two directions are not symmetric and the
asymmetry was not priced.

**Breaking operation:** `fundNextTranche` L78–80. `amount` for tranches 0–2 comes from the
stored promise; `balance` is the reality; the mismatch reverts and `nextTranche` (L82)
never advances. The gate is time-independent, so retrying can never help.

**Verification — Method B, `testSI04_TotalRewardsDeficitBricksTheFunderForever`:**
```
promised totalRewards : 100 ether     delivered : 70 ether
tranche 0 (32.5) OK -> 37.5 left
tranche 1 (27.5) OK -> 10   left
tranche 2 needs 22.5 -> InsufficientBalance(10, 22.5)
+10,000 days later   -> InsufficientBalance(10, 22.5)   (identical; not a delay)
nextTranche stays 2 forever; 10 GOV stranded in a contract with no owner and no rescue
```
Control (`testSI04_Control_ExcessIsAbsorbedSilently`): over-delivering 130 against a
promise of 100 completes all four tranches and leaves the funder at 0 — **absorbed with no
event, no signal, and no way for an observer to tell it happened.**

**Reachability.** Not reachable through the factory: `allocation.coinStakingRewards` is
passed to `initialize` (`CoinDAOFactory.sol:448`) and to `safeTransfer`
(`CoinDAOFactory.sol:485`) as the same expression. Reachable through any hand-rolled or
scripted deployment of the clone pair, which `initialize`'s signature invites. LOW on that
basis, recorded because the consequence is unrecoverable rather than merely wrong.

**Related, same root — a zero final sweep.** `testSI05_ZeroSweepAdvancesPeriodFinishWithZeroRate`:
delivering exactly 82.5% exhausts the funder on the three fixed tranches, then tranche 3
sweeps **0** — `L80` cannot fire (MASK-02) — and the system emits
`TrancheFunded(3, 0, now + 365 days)` while setting `rewardRate = 0`:
```
rewardRate after zero sweep : 0
periodFinish - sweepTime    : 8,640,000     (a full duration pushed forward)
staker earns nothing for the entire final period (asserted)
subsequent fundNextTranche() -> AllTranchesFunded
```
An off-chain consumer reading `TrancheFunded` and `periodFinish` sees a funded, running
final year. `rewardRate` says otherwise. Nothing reconciles the two.

---

### GAP-06 — MEDIUM — **NEW** — The system reaches an absorbing state in which no actor
### can ever add, redirect, or recover rewards, while both GOV balances stay increasable

**Coupled pair:** PAIR H — `nextTranche` (terminal at 4), `rewardsDistribution` (frozen),
`Ownable._owner` (`address(0)`) on one side; `rewardsToken.balanceOf(F)` and
`rewardsToken.balanceOf(SR)` (both freely increasable by anyone, forever) on the other.
**Invariant needed:** once the schedule is terminal, either the balances must be terminal
too, or a path must exist to move them. Neither holds.

**Verification — Method B, `testSI07_TerminalStateWithNoReEntry`, factory-deployed, real
allocation, 30-day launch delay, staker holds to the end:**
```
allocation                    : 6,500,000 GOV
alice received                : 6,326,369.86 GOV
stranded in SR                :   173,630.14 GOV  == rewardRate(tranche 0) x 30 days
                                                     (asserted to 1e-4 %)

then, every re-entry is closed - each asserted:
  sr.owner()                        == address(0)
  sr.notifyRewardAmount(...)        -> "Caller is not RewardsDistribution contract"
  sr.setRewardsDistribution(...)    -> OwnableUnauthorizedAccount
  funder.fundNextTranche()          -> AllTranchesFunded    (and again 10 years later)

yet both balances still accept anything, and both sink it:
  sunk in funder (top-up) : 3,163,184.93 GOV
  sunk in SR     (top-up) : 3,336,815.07 GOV
```
And `testSI06_ExhaustedFunderIsAPermanentGovSink` isolates the trap: after exhaustion,
`trancheAmount(3)` reports a 1,000 GOV top-up as tranche 3's amount — the view still
advertises it as claimable — while `fundNextTranche()` reverts forever.

**Why this is graded MEDIUM.** The *loss* is conditional on someone sending GOV after
exhaustion, so it is not an unconditional CRITICAL. But two things make it more than
cosmetic: (a) `trancheAmount(3)` actively invites the mistake by reporting the balance as
a tranche amount; (b) the *irreversibility* is unconditional and is what converts every
other gap on this page from "delayed" into "destroyed." `GovToken` has a fixed supply with
no mint after `initialize` (`GovToken.sol:26`), so even a governance remediation must move
existing GOV — into contracts that will sink it. A reader could reasonably grade the
donation-loss half LOW; the structural half is not gradeable as LOW.

---

## PHASE 7 — MASKING CODE

Every instance below was interrogated with the required question: **what invariant is this
covering for, and would that invariant have held?**

### MASK-01 — `require(rewardRate <= balance / rewardsDuration)` — `StakingRewards.sol:159–160`

```solidity
uint256 balance = rewardsToken.balanceOf(address(this));
require(rewardRate <= balance / rewardsDuration, "Provided reward too high");
```

**What it is covering for.** Upstream Synthetix uses it as an overflow bound on the
notified amount. Read as a solvency check it asserts `newScheduled <= balance` — and
**omits the `Σ rewards[a]` term entirely**. `balance` is `owed + scheduled + stranded`;
the guard treats all three as free.

**Executed proof that it is not a solvency bound —
`testM1_L160IsNotASolvencyBound`:**
```
balance held    : 100,000,000,000,000,000,000
already owed    :  99,999,999,999,999,360,000   <- to alice, unclaimed
newly scheduled :  99,999,999,999,999,360,000
assertLe(rewardRate, balance/duration)              -> the guard PASSES
assertGt(owed + scheduled, balance)                 -> the contract is insolvent
one period later: owed 199,999,999,999,998,720,000 against a 100 balance
alice.getReward()                                   -> REVERTS (ERC20InsufficientBalance)
```
The only outflow in the contract is bricked, and the guard that was supposed to be the
safety net signed off on it.

**Resolution of the green check against the caller that actually exists —
`testM1_L160HasNoResolutionAgainstTheFunder`:**
```
tranche 0: rewardRate 3,761,574,074,074   ceiling 3,761,574,074,074   slack 0
tranche 1: rewardRate 3,182,870,370,370   ceiling 6,944,444,444,444   slack 3,761,574,074,074
tranche 2: rewardRate 2,604,166,666,666   ceiling 9,548,611,111,111   slack 6,944,444,444,445
tranche 3: rewardRate 2,025,462,962,962   ceiling 11,574,074,074,074  slack 9,548,611,111,112
```
At tranche 0 the slack is **exactly zero** — the guard sits on its boundary. From tranche 1
onward the slack is exactly the emission already owed to the unclaimed staker. **The
headroom this guard runs on is made of GOV that belongs to somebody else.** Structurally
it can never fail via the funder, because L84 transfers `amount` before L85 notifies
`amount`, so `floor(amount/D) <= floor(balance/D)` always. Its resolution against the only
caller the deployed system has is **zero**.

**Report instruction:** L160 must not be cited as evidence of solvency. It is an overflow
bound, and the stranded GOV from GAP-01/02/03 is what keeps it comfortably satisfied — the
burn feeds the check that would otherwise be the burn's detector.

### MASK-02 — `if (balance < amount) revert InsufficientBalance(...)` — `StakingRewardsFunder.sol:80`, on the final tranche

```solidity
uint256 amount  = _trancheAmount(tranche);            // L78 -> tranche 3 returns balanceOf(this)
uint256 balance = rewardsToken.balanceOf(address(this)); // L79 -> the same value
if (balance < amount) revert InsufficientBalance(balance, amount); // L80 -> can never fire
```

**What it is covering for.** For tranches 0–2 it covers a real invariant
(`balanceOf(F) == totalRewards - Σ paid`), and it is the check that catches GAP-05. On
tranche 3 the two operands are the **same read one line apart**, so the final tranche —
the only one whose amount is unbounded and attacker-influenceable — is the one with **no
funding validation at all**, including the zero case (GAP-05's second half).
Proven by `testM2_FinalTrancheBalanceCheckIsStructurallyDead`: the balance is moved to an
arbitrary value and the sweep still succeeds.

### MASK-03 — `if (_totalSupply == 0) return rewardPerTokenStored;` — `StakingRewards.sol:95`

Interrogated in full under GAP-01. Covering for division by zero; silently answering a
value question. The comment at L147–149 acknowledges the value consequence, which is why
this is reported as masking rather than as an unknown.

### MASK-04 — `if (reward > 0)` — `StakingRewards.sol:132` (skill pattern 3, early exit on zero)

Checked and **cleared**: `reward` is zero exactly when nothing accrued, `getReward()` is
then a genuine no-op, and no coupled state is skipped (`updateReward` has already run in
the modifier). Matches upstream. Not masking anything.

---

## PHASE 8 — VERIFICATION GATE

| ID | Coupled pair | Breaking op | Raw sev | Method | Verdict | Final |
|---|---|---|---|---|---|---|
| GAP-01 | `lastUpdateTime` ↔ `rewardPerTokenStored` | `updateReward` L69–70 | HIGH | B (3 PoCs + control + resolution) | TRUE POSITIVE | **HIGH** (= FF-001) |
| GAP-02 | `rewardRate` ↔ `_totalSupply` | `notifyRewardAmount` L152 | HIGH | B (factory, both entry points) | TRUE POSITIVE | **HIGH** (= FF-001/003) |
| GAP-03 | `rewardRate` ↔ `_totalSupply` | `withdraw` L123 / `exit` mid-period | MEDIUM | B | TRUE POSITIVE | **MEDIUM** (new path) |
| GAP-04 | PAIR G / untracked balance | external transfer to F or SR | LOW | B (2 PoCs) | TRUE POSITIVE | **LOW** |
| GAP-05 | PAIR G deficit | `fundNextTranche` L78–80 | MEDIUM | B (+ control) | TRUE POSITIVE, downgraded (unreachable in-path) | **LOW** |
| GAP-06 | PAIR H | terminal `nextTranche` | HIGH | B (factory) | TRUE POSITIVE, downgraded (loss needs a user action) | **MEDIUM** |
| MASK-01 | PAIR E | `require` L159–160 | — | B (+ resolution table) | masking, confirmed not a solvency bound | **note** |
| MASK-02 | PAIR G | `if` L80 | — | B | masking, confirmed dead on tranche 3 | **note** |
| MASK-03 | PAIR B | `if` L95 | — | B | masking, root of GAP-01 | **note** |

**Verification level reached (workspace scale): level 4 — executed in the real
environment** for GAP-01 through GAP-06 and all three masking claims, against
factory-deployed systems for GAP-02/GAP-06 and against clone pairs for the rest, with
controls and a resolution measurement for the headline claim.

---

## FALSE POSITIVES ELIMINATED

**FP-1 — `notifyRewardAmount` L162 writes `lastUpdateTime` without writing
`rewardPerTokenStored`.** The Mutation Matrix flags this as a lone write to one half of
PAIR B, which is exactly the shape of the bug class. **Refuted by trace, and a refutation
is a claim too, so here is the reasoning in full.** The `updateReward(address(0))` modifier
has already set `lastUpdateTime = lastTimeRewardApplicable() = min(now, periodFinish_old)`.
L162 then advances it to `now`, discarding the interval `[min(now, pf_old), now]`. In the
`if` branch that interval is `[pf_old, now]`, which lies entirely beyond the old period, so
`rewardRate` owed nothing there. In the `else` branch `min(now, pf_old) == now`, so the
interval is empty. **Benign in both branches.** Verified against `earned()` values across
a double-notify sequence in the instrumented debug run.

**FP-2 — a returning first staker retroactively captures the empty interval.** The classic
empty-pool inflation shape. **Refuted independently of Pass 1's R-02**, by state trace and
by execution: `testR_EmptyIntervalIsSkippedNotBanked` warps 50 days with nobody touching
the contract at all, then stakes:
```
earned(alice) immediately after staking : 0
lastUpdateTime                          : t0 + 50 days   (the stake itself jumped the clock)
alice's final take                      : 49,999,999,999,999,680,000  (exactly her 50 days)
stranded                                : 50,000,000,000,000,320,000
```
L70 runs *before* the body of `stake`, so the vacancy is consumed by the staker's own
transaction. The interval is **skipped, not banked** — which is precisely why GAP-01 is a
burn and not an inflation. Convergent with Pass 1 R-02, derived by a different route.

**FP-3 — repeated free `updateReward` calls grief accrual through truncation.**
`rewardPerToken()` truncates `(dt · rate · 1e18) / _totalSupply` on every settle, and
`getReward()` is public, free of access control, and callable by anyone at any frequency.
**Refuted by execution**, `testR_TruncationGriefingIsNegligible`: 240 forced settles
(hourly for 10 days) against a 1e24 supply cost **0 ppb** of the interval's emission
(measured against the analytic `rewardRate × 240h`). The per-settle loss is bounded by
`_totalSupply / 1e18` wei. Convergent with Pass 1 R-05 by a different measurement.

**FP-4 — `_balances` is mutated by some path that skips `updateReward`.** RULE 1 requires
checking every mutation path; RULE 3 requires comparing them. **Grep-refuted**: `_balances`
is written at exactly two lines, L115 and L124, both `[msg.sender]`, both behind
`updateReward(msg.sender)`. No transfer, no delegation, no admin seizure, no liquidation,
no batch, no hook, no `receive`/`fallback`. There is no odd path out because there is no
third path.

**FP-5 — `updateReward(address(0))` on notify leaves accounts unsettled.** This is the
skill's own FP pattern #2 (lazy evaluation). `userRewardPerTokenPaid[a]` is only ever
compared against the monotone `rewardPerTokenStored`, so an account settles correctly
whenever it is next touched. Verified by the `testSI_ParallelPaths_...` journey, where a
never-settled account's final payout is exact to 6.4e-13 of the total.

**FP-6 — `ReentrancyGuard` is inherited non-upgradeably into an EIP-1167 clone, so
`_status` starts at 0 instead of `NOT_ENTERED`.** A coupled-state question about a
constructor-set value in a constructor-less deployment. Cleared by construction (OZ v5
tests `_status == ENTERED`, and `0 != 2`) and convergent with Pass 1's executed R-01.

---

## CORPUS EXCLUSION ANALYSIS

Per workspace rule — *read what the corpus excludes*. The project's own tests are scoped to
a different question than the one the coupled pairs ask, and every exclusion below points
at exactly the pair that is broken.

| Test | What it excludes | Consequence |
|---|---|---|
| `StakingRewardsFunder.t.sol` — **all four tests** | **every one runs with `_totalSupply == 0`.** No test in the funder suite ever stakes. | PAIR D is untestable by construction in the suite that owns the funder. |
| `testPermissionlessFourTrancheLifecycleAssignsFinalDust` (L44) | asserts `rewardsToken.balanceOf(address(rewards)) == 101` at the end | the project's own test **asserts the state in which 100% of the reward is stranded**, and calls it success. It is checking the funder's bookkeeping; the coupled pair is out of frame. |
| `StakingRewards.t.sol::testMidPeriodNotificationRollsLeftoverForward` | makes the **test contract itself** the `rewardsDistribution` | the `else` rollover branch is proven to work — by the one caller the deployed system will never have. The corpus demonstrates the mitigation that the funder's gate disables (Pass 1 FF-002). |
| `testLinearRewardsAndEmptyPeriodBehavior` | asserts only the staker's 10 ether after a 10-day vacancy; never asserts conservation | the burn is invisible to the assertion. **Survivorship:** a test that only checks what a staker received cannot see what no staker received. |

No test in the tree asserts a conservation property of the form
`Σ paid + Σ owed + held == Σ notified`. That is the assertion that every gap on this page
would have failed.

---

## RESOLUTION OF PASS 1's OPEN QUESTION (FF-008 / assumption A2)

Pass 1 asked Pass 2 to resolve the staking/reward token transfer semantics. **Half is
resolvable in scope; half is not, and is reported as such.**

**Reward token — RESOLVED SAFE.** `GovToken` (`src/GovToken.sol`) is a plain
`ERC20Upgradeable` + `ERC20PermitUpgradeable` + `ERC20VotesUpgradeable`. `_update` (L29–34)
does nothing but `super._update`. Fixed supply, minted once at `initialize` L26, no fee, no
rebase, no transfer hook, no mint or burn thereafter. PAIR E's arithmetic and the funder's
`transfer`-then-`notify` ordering are therefore sound against the reward token, and no
reentrancy reaches `fundNextTranche` through it. Verification level 3 (read in full, could
have failed).

**Staking token — NOT RESOLVABLE IN SCOPE, and the reason is structural.**
`deployment.coin` and `deployment.vault` are returned by the external monolith factory
(`CoinDAOFactory.sol:307`) or read from the external lender (`CoinDAOFactory.sol:337`), and
`stakingToken` is chosen between them at `CoinDAOFactory.sol:433–434`. `_validate` does not
look at either. The test tree substitutes a plain `MockERC20` for both — including for the
sCoin, which the mock creates as `"Staked <Coin>"` with no share mechanics at all
(`test/mocks/MockMonolith.sol:69`). **The corpus therefore cannot distinguish a
share-price-growing vault (safe for PAIR F) from a balance-growing one (unsafe), because
its mock is neither.** FF-008 stands as a lead; this pass narrows it to the staking token
only and identifies the corpus's blind spot as the reason it cannot be closed here.

---

## SUMMARY

- Coupled state pairs mapped: **12** (A–L), of which **5 BROKEN**, 5 HELD, 1 assumed-unenforced, 1 documentation-only.
- Mutation sites enumerated: **30 rows** in the Mutation Matrix — 22 declared-storage writes plus 8 implicit-balance paths.
- Parallel path groups compared: **4**.
- Raw gaps: 6. **After verification: 6 TRUE POSITIVE, 0 FALSE POSITIVE from the gap set**, plus **6 hypotheses refuted** (FP-1…FP-6) and 4 masking sites interrogated (3 confirmed masking, 1 cleared).
- Final: **2 HIGH** (GAP-01, GAP-02 — both the state view of Pass 1's FF-001/FF-003), **2 MEDIUM** (GAP-03 new path, GAP-06 new), **2 LOW** (GAP-04, GAP-05 — both new), **3 masking notes**.
- **NEW this pass:** GAP-03 (new mutation path), GAP-04, GAP-05, GAP-06, plus executed proofs for MASK-01 and MASK-02 that Pass 1 recorded only as notes, plus the corpus-exclusion analysis and the partial resolution of FF-008.
- Verification level: **4 (executed)** for all six gaps and all three masking claims.
- Evidence integrity: `[scratch]` unmodified (`git diff --stat -- [scratch]` empty); all 19 PoCs live in a disposable copy at
  `%TEMP%/claude/c--RWG-CodeAudit/.../[scratch]`; suite there is 74/74; nothing was executed against any external system.

**Convergence with Pass 1 (blind-lens value).** Pass 1 reached FF-001 by asking whether a
guard was *sufficient for what it is trying to prevent*. This pass reached the identical
line by building the Mutation Matrix and finding a lone write to one half of PAIR B. Two
methodologies, two routes, same two lines (L69–70 and L95). Pass 1's R-02 and R-05 were
independently re-derived and re-refuted here as FP-2 and FP-3. That convergence is the
strongest evidence on this page, and it was not obtained by priming — this pass built its
map from the declarations before reading Pass 1's verdicts.

**Handoff to Pass 3 (fusion).** The intersection worth pressing: GAP-06's absorbing state
is what makes GAP-01/02/03 permanent, and MASK-01's headroom is *composed of* the GOV that
GAP-01 stranded. That is a closed loop — the defect supplies the slack that keeps its own
detector satisfied. No single lens is positioned to state that; it needs both the
first-principles reading of L160's intent and the state reading of where its slack comes
from.
