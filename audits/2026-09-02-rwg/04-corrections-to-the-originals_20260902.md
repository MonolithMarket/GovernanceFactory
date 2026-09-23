# ⛔ DO NOT DELIVER — corrections outstanding against harvested output

**Read this before anything in `findings/raw/` is shown to the client.**

The harvested lens-1 report at
`findings/raw/20260901-182240-pashov-v3/GovernanceFactory-pashov-ai-audit-report-*.md`
is **EVIDENCE and is not edited** — that is why these corrections live here instead of in
the file. They were established *after* it was written, by the second lens and by direct
verification. Both must be applied when the client report is authored at stage 10.

⚠️ **Section 4 is a later addition and has a different target.** Sections 1-3 correct the
harvested lens-1 report under `findings/raw/`. **Section 4 corrects two of our own stage-8
documents** (`cross-family-merge.md`, `completeness-exclusions.md`), which are not evidence but
were left standing with claims that later passes overturned. They are recorded here rather than
rewritten so that no analysis is silently altered.

---

## 1. 🔴 A RECOMMENDED FIX IN THAT REPORT DOES NOT WORK

**Report finding 2 — "Quorum denominated in staked supply while threshold uses total supply".**

It offers two remedies. **Option B — raise `GOVERNOR_QUORUM_NUMERATOR` to 400 — is
ineffective and must be struck.**

Nemesis mutation-tested it:

| mutation | result |
|---|---|
| `quorumDenominator` reverted to OpenZeppelin's 100 | capture **still succeeds** |
| `GOVERNOR_QUORUM_NUMERATOR` at its **maximum legal value** (a 100% quorum) | capture **still succeeds** |

Because when the attacker *is* the entire staked supply, `forVotes >= quorum` holds at
every setting. **No governance-reachable parameter fixes this.**

⛔ **AND OPTION A IS ALSO DEAD.** Superseded 2026-09-02 by the cross-family merge. The
arithmetic is decidable from the locked source with no execution at all:

    immediateAllocation = 9,800,000 x 500 / 9,800 = 500,000 GOV

paid **liquid, to a caller-named address**, against Option A's proposed 400,000 GOV floor.
**The launcher clears the remedy alone.** Pass 4 then swept every alternative — numerators
1 to 999, and absolute floors both below and above — and none works: below 500,000 the
launcher succeeds unaided; above it the DAO deadlocks and is repairable only through the
mechanism the floor disables.

⭐ **The fix cannot live at the quorum link at all.** ~~It must cap or vest the *amount* of
liquid GOV reaching a caller-supplied address — a cap on the amount has no `bps=1`
workaround, whereas tightening the recipient predicate was defeated for 51 GOV.~~

## ⛔ THIRD AMENDMENT, 2026-09-02 — CAP AND VEST ARE **BOTH** DEAD

The surviving recommendation above — *"cap or vest the amount"* — no longer has a live half.

| half | killed by | how |
|---|---|---|
| **vest** | register **K-11** | a 4-year linear vest of the same 500,000 GOV releases **10,273.97 GOV by day 30**, past the 10,000 threshold. Buys ~29 days |
| **cap** | register **K-12** | the cap **bites at `t = 0`** and is defeated **in under one day**. The launcher stakes **1 wei** of the market's own Coin into the same launch's `StakingRewards` and holds **10,787.67 GOV after 24 h**, **16,575.34 after 48 h**, then proposes alone against a quorum of 16.58 |

⛔ **No cap value, including zero, buys more than 41.5 hours.** The measured `rewardRate` is
`5,787.671232876712243 GOV/day` against a 10,000 GOV threshold. The cap bounds the
*allocation*; the same launch transaction opens a **larger second source of GOV**.

⭐ **It is the COMPOSITION that kills it.** The cap is viable only alongside a working remedy
for the tranche-0 emission stream — and none exists. Two remedies, each sound against the
finding it was written for, are jointly defeated because one finding's fix leaves the other's
mechanism running.

**The remedy space for this finding is now swept**: quorum parameters (K-1…K-4), the
recipient predicate (K-5), the funding call (K-6), a TVL gate (K-7), vest (K-11), cap (K-12).
⛔ **The only untried direction is not paying a liquid allocation at genesis at all**, and
whether that is acceptable is a **client decision, not an audit finding** — it is open
question Q-5 and must be put to them as a question in the report, never as a recommendation.

⚠️ **This document has now been wrong three times** — it recommended Option B, then Option A,
then *"cap or vest"*. Each was corrected by execution and none by review. A file written
specifically to stop an ineffective fix reaching the client has itself carried one at every
revision. That is recorded as a process finding, not quietly repaired, and it is the single
strongest argument in this engagement for the mutation gate.

⛔ Shipping Option B would have the client change a number, believe themselves fixed, and
remain fully exposed. That is worse than reporting nothing.

## 2. 📈 FINDING 1'S SCOPE IS UNDERSTATED

**Report finding 1 — "Tranche-0 emissions begin against a provably empty staking pool"** —
is written as a **launch-window** defect. It is not.

Pass 2 state analysis proved `withdraw` / `exit` can drive `StakingRewards._totalSupply` to
zero **mid-period**, reading neither `rewardRate` nor `periodFinish`. The burn therefore
**recurs on any total-exit vacancy at any point in the four-year programme** — unbounded,
repeatable, and self-reinforcing rather than one-off. Measured: a 30-day mid-period drain
burns exactly `rewardRate × 30 days`.

The finding must be restated as a permanent structural defect, not a bootstrap window.

## 3. ✅ TWO FINDINGS ALREADY REFUTED — do not carry them forward

Both were killed by direct verification against the deployed dependency
(`Lender.sol:896-903` — `pullLocalReserves()` performs a **complete** drain and
**early-returns** rather than reverting on zero):

- Pashov report **finding 13**, "Incomplete harvest lets a depositor capture pre-stake revenue" — **REFUTED**, its premise is false.
- The nemesis Pass-1 equivalent (99.9% single-transaction capture) — **REFUTED**, same premise.

⚠️ Both families built this attack independently. Convergence indicated a *shared blind
spot*, not a real bug — which is why the refute stage cannot be skipped.

Also struck: the report lead *"`setManager` may be undoable by the incumbent manager"* — a
displaced manager is no longer a manager and cannot re-set itself.

~~Also downgraded: **finding 7**'s severity is bounded — every affected Lender setter carries
`beforeDeadline`, so the inherited manager's economic control expires at
`timeUntilImmutability` rather than persisting indefinitely.~~

## ⚠️ SECOND AMENDMENT, 2026-09-02 — finding 7's cap is **RESTATED, not struck**

An earlier pass proposed striking this cap entirely. **Execution says the cap is real but the
sentence is wrong in two ways**, and the correction goes in both directions:

- ✅ **The cap exists.** All four of `setHalfLife`, `setTargetFreeDebtRatio`, `setRedeemFeeBps`
  and `setMaxBorrowDeltaBps` do revert `Deadline passed` after the deadline, verified on live
  markets. The word *"every"* is what fails, not the mechanism.
- ⛔ **`setManager` has no `beforeDeadline` and SURVIVES the deadline** — it succeeded after it.
  So the inherited manager's *economic* control expires; the **power to hand the role onward
  does not**. After the deadline the DAO's only remaining Lender power is the power to give
  that role away.
- ⚠️ **The bound is market-chosen, not a constant.** Measured across the only two live
  markets: **3.64 years** on one, **238 days** on the other. A severity that depends on a
  value an untrusted actor selects cannot be quoted as a single number.

⭐ The correct statement: *four of five inherited manager powers expire at a
deployer-chosen deadline between 238 days and 3.64 years; the fifth — reassigning the role —
does not expire at all.*

## 4. ⚠️ FOURTH AMENDMENT, 2026-09-02 — TWO STALE STAGE-8 DOCUMENTS

⭐ **Recorded here rather than rewritten in place.** Both documents' *analysis* stands; only the
specific claims below are corrected, each with its quoted basis. Neither file's reasoning is
touched.

### 4.1 `cross-family-merge.md` §2.1 — strike *"clean"*, and the replacement is not "discounted"

**The stale claim**, at `cross-family-merge.md:83`:

> *"**Two convergences are load-bearing and clean.** XF-01 and XF-02 were reached by the nemesis
> Pass-1 emissions and factory lanes **blind**…"*

**The quoted basis for the correction** — `journal.jsonl` L25, `2026-09-01T18:06:34+00:00`,
**twenty-one hours before the merge was written** (verified: `grep -c "OVERLAP AUDIT"
journal.jsonl` → exactly **1**; negative control `grep -c "OVERLAP AUDITXYZ"` → **0**):

> *"OVERLAP AUDIT (agent 1): its two headline findings correspond to ORIENTATION D5
> (`notifyRewardAmount` at zero supply) and D8 (governor quorum/threshold params). Agent claims
> both predated its read of the file; **an agent is not a reliable narrator of its own priming.
> Both must be DISCOUNTED as independent convergence at debrief.**"*

D5 is XF-01; D8 is XF-02.

⭐ **Why the merge's sentence fails, independently of who wrote what first.** §2.1 establishes
that the **nemesis** leg was blind — *"reached by the nemesis Pass-1 emissions and factory lanes
blind"* — and then applies the adjective *clean* to the **convergence**, which is a two-legged
object. A convergence is only as clean as its dirtiest leg, and the merge never examined the
lens-1 leg at all. That is a defect in the inference.

**⛔ THE CORRECTION IS NARROWER THAN "DISCOUNT THE ROWS", and getting this wrong in the other
direction would be its own error.** Both journal entries were re-read for this correction:

```
CONVERGENCE TRACKER (3/12 back): zero-supply emission burn at deploy-time fundNextTranche
  = agents 1,5,6.  Non-binding quorum ... = agents 1,5.
FINAL CONTAMINATION TALLY: read lens-blind scope docs = agents 1, 6, 7, 12.
  ... CLEAN = agents 2, 4, 5, 8, 9, 10.
```

**Agent 5 contributed to both rows and agent 5 is in the clean six.** The journal discounted
**agent 1's** claim, not the row. So the convergence survives via a clean contributor.

⭐ **Replacement wording:** strike *"load-bearing and clean"*; write *"load-bearing, with a clean
lens-1 contributor on record for each (agent 5), and a prior-art discount that neither lens could
have avoided."*

⚠️ **What the correction must NOT do.** It must not upgrade to a per-row cleanliness claim for
anything else. The only finding→agent map in the record was written at **3 of 12 agents
returned** and was never updated. Per-row attribution is unavailable for most rows.

**⛔ AND A CLAIM MADE ABOUT THIS CORRECTION IS ITSELF WRONG — recorded because a wrong
adjudication would have propagated.** It was put to this pass that `debrief-verdict.md`
adjudicated this *"in the opposite direction to `completeness-exclusions.md`"*. **It does not.**
The two documents agree, and the sources say so verbatim:

| document | what it actually rules |
|---|---|
| `debrief-verdict.md:584` | *"⛔ **Ruling: `cross-family-merge.md` §2.1 is amended. `completeness-exclusions.md` stands.**"* |
| `completeness-exclusions.md:644` (X-3) | *"⛔ **Strike *'clean'*** from the XF-01 / XF-02 convergence claim"* — and `:525` (E-1), the same instruction |

Both strike the word *clean*; the verdict adds the **agent-5 refinement** and the reason the
merge's inference fails. There is one document to amend — the merge — and it is not
`completeness-exclusions.md`. ⭐ Verified before writing, in both directions, because a
refutation is a claim too.

### 4.2 `cross-family-merge.md` §2.1 — the convergent list omits XF-12 and counts XF-13

**The stale claim**, `cross-family-merge.md:80-81`, headed *"CONVERGENT — 20 rows"*:

> *"XF-01, 02, 04 (mechanism), 05, 06, 07, 08, 09, 10, 14, 15, 19, 20, 21, 22, 23, 25, 26, 33,
> and XF-13 (⛔ worthless — §3)."*

**Two defects, both quotable.** The list **omits XF-12 entirely**, although XF-12's own
relationship column reads CONVERGENT; and it reaches its count of 20 only by **counting XF-13**,
which the same document's §3 calls *"⛔ **WORTHLESS CONVERGENCE — both REFUTED**"* (register
**R-1**/**R-2**: `Lender.sol:896-903` disproves the shared premise). A list cannot both call a
row worthless and spend it to reach a total.

**Correct partition, one primary relationship per row, summing to 34:**

```
CONVERGENT (primary)   20   XF-01,02,04,05,06,07,08,09,10,12,14,15,19,20,21,22,23,25,26,33
CONVERGENT-WORTHLESS    1   XF-13
UNIQUE                 11   XF-03,16,17,18,27,28,29,30,31,32,34
CONTRADICTORY (primary) 2   XF-11, XF-24
                       ──
                       34   ✓
```

### 4.3 `completeness-exclusions.md` §5.1 — the heading says 20, the table has 22

**The stale claim**, at `completeness-exclusions.md:425` and its heading at `:428`:

> *"Below is every one of its **20 CONVERGENT rows**, scored."* / *"### 5.1 The 20 convergent
> rows, scored"*

**Counted from the table itself** (rows at `:432-453`; `grep -c "^|"` over that range → **22**):

```
XF-01 02 04 05 06 07 08 09 10 11 12 13 14 15 19 20 21 22 23 25 26 33   =  22 rows
```

**The two extra rows are `XF-11` and `XF-12`**, neither of which appears in the merge's own
20-row list that §5.1 says it is scoring. ⭐ The table is the more correct artifact — XF-12
*should* be there (see §4.2) — so the fix is to the **heading and the framing sentence**, not to
the table: it scores **22** rows, being the merge's 20 plus XF-11 and XF-12.

⚠️ **Knock-on that must be corrected with it.** The tally sentence at `:455-456` reads *"6 of 20
convergences stand unqualified…"*. With 22 rows tabled, the denominator is **22**, not 20. The
same sentence's closing clause — *"The remainder carry U-6 or U-2"* — is also imprecise: of the
nine remaining rows, **XF-14**'s only discount is §5.3 prior art, and **XF-11** carries U-1
(partial) plus T-1 plus prior art. Neither is a U-6/U-2 row.

⛔ **None of this changes a severity, a verdict, or a finding.** All three corrections are to
counting and to one adjective.

---

---

## 5. ⛔ FIFTH AMENDMENT, 2026-09-02 — THE "~73-DAY GOVERNANCE OUTAGE" IS **1.728 DAYS**

**Raised at stage 9c.** `findings/debrief-1.md` and `findings/debrief-ledger.md` have been
corrected in place. The artefacts below **may not be edited** — `repro/` is the archived
reproduction set the verdict's *"24 tests, 24 passed"* rests on, and the stage-8 findings documents
are inputs the debrief adjudicates rather than rewrites. Their corrections live here and must be
applied when the client report is authored.

**The result, re-executed this pass at level 4** in a private tree whose 14 `src/` and `script/`
files were sha256-verified byte-identical to `code/` before and after. On the shipped
zero-recipient default the earliest a proposal can exist is **149,283 s = 1.728 days**, not 73 —
the published figure is **42.24x too large**. Boundary pinned to the second:

```
rewardRate                : 66,986,935,565,702,688 wei/s = 5,787.671232876712243 GOV/day
earned at 149,282 s       :  9,999.943715119228670016    <- below
earned at 149,283 s       : 10,000.010702054794372704    <- at or above
proposal threshold        : 10,000.000000000000000000
```

⭐ **Resolution, shown by asserting the PUBLISHED claim instead of the corrected one:** a test
asserting *"nothing can propose before day 73"* **FAILS** — at 73 d − 1 s the staker holds
**422,499.933013064428050912 GOV**, 42x the threshold. Second control: a non-staker earns **0** at
any elapsed time, so the measurement is a property of staking and not of the time warp.

⭐ **The underlying error, stated once.** The premise was correctly scoped — *at `t = 0`, every wei
of GOV sits in a contract that cannot stake* — and that is a statement about **balances at one
instant**. The conclusion drawn from it is a statement about **all future time**. The launch opens
a second GOV source with **no balance at `t = 0`** to be enumerated: the tranche-0 emission stream,
funded inside the launch transaction at `CoinDAOFactory.sol:487`, paying whoever stakes 1 wei of
the market's Coin.

| artefact | where | what it says | what must be said instead |
|---|---|---|---|
| `repro/PASHOV-06-default-params-strand-supply.fork.t.sol` | `:154` | assertion message *"73.0 days is the earliest any proposal can exist"* | ⛔ **The TEST IS CORRECT and must not be changed.** It measures the **vesting** route exactly — re-run this pass it logs *"releasable to the Monolith beneficiary at 73 days - 1s: 9,999.998414510400811770"* and *"releasable at exactly 73 days: 10,000.000000000000000000"*. Only the **message** over-claims: 73.0 days is the earliest bootstrap **requiring no interaction with the market**, not the earliest proposal |
| same | `:10`, `:138`, `:156` | *"the earliest possible unlock"*, *"the true floor"* | the earliest **vesting** unlock; not a floor on proposals |
| `findings/refutation.md` | §3, §7 row 10 | *"governance can only be bootstrapped by a factory-global third party (the monolith beneficiary), **not by the DAO's own stakeholders**"* | ⛔ **STRIKE.** The bootstrapper is **whoever holds 1 wei of the market's staking token first** — on `deployForExistingCoin()` the launcher **by construction** (`CoinDAOFactory.sol:328` requires `msg.sender == lender.operator()`); on `deploy()` whoever calls `Lender.buy()` in the launch block. Verified level 4 on the pinned fork: a **stranger** holding no role minted Coin and staked in the launch block |
| `findings/redteam-remediation.md` | `:268`, `:586` | RX-10's *Prevents:* clause priced *"for ~73 days"* | ⛔ **Re-argue RX-10; do not re-quote it.** The numerator is 42.24x too large, **and** RX-10 touches only `deployForExistingCoin`, where the outage is ~1.7 days — or **zero** when a `deployerRecipient` is named (`test_P6_control_namedRecipientCanProposeImmediately` passes, verified this pass). Restated: RX-10 buys an eviction window of about 1.7 days and hands the launch caller the manager appointment permanently |
| `findings/verify-severity-corrections.md` | `:520` | XF-07's MEDIUM derived on the 73-day interval | derivation rewritten in `debrief-ledger.md` §4.2. The binding interval is *create (1.728 d) + vote (6.0 d) + timelock (2 d)* = **approximately 9.7 days**. ⭐ **Grade unchanged - MEDIUM**; the severity never rested on the interval |
| `findings/verify-severity-corrections.md` | `:748` | D-3's MEDIUM on the same interval | ⭐ **D-3 and XF-37 are the SAME ROW** (the ledger's own heading says so). Derivation rewritten in `debrief-ledger.md` §4.3; the defect is the **shipped default**, not the window's length. ⭐ **Grade unchanged - MEDIUM** |

⚠️ **The permitted sentence, which names both routes and may be quoted as-is:** *"the earliest a
proposal can exist is 1.728 days, by staking the market's own Coin into the launch's own reward
stream; the earliest route that requires no market interaction at all is 73.0 days."*

⭐ **Why no pass caught it — and it is a process finding, not a code one.** Five adjudication
documents carried `73 days`; four lens-2 raw artefacts carried `1.73 days`; **the intersection is
empty.** Each family measured its own qualifier correctly and the two numbers never met. Adjudication
inherited one side of a quantity both lenses had measured.

⚠️ **The grep that finds this must be adversarial.** The naive pattern `73 days` matches **inside**
`1.73 days`, producing a **FALSE PRESENCE** — the failure direction that makes a correct result look
already-known and get abandoned. The boundary-correct form used here is:

```
grep -rEn '(^|[^0-9.])~?73(\.0)?[ .-]?days?'
    negative control: no match on "1.73 days", "8.73-day", "173 days"
    positive control: 4 matches on "~73 days", "73-day", "73.0 days", "73 day"
```

✅ **`findings/raw/` carries none of the stale figure** — and that absence is proved, not assumed:
the same grep reaches all 22 files there (positive control: it finds `1.73 days` in exactly four of
them, the lens-2 artefacts).

## Status

| | |
|---|---|
| Corrections raised | 2026-09-01 (lens 2, sections 1-3); 2026-09-02 (sections 4.1-4.3, stage-9 appendix pass; section 5, stage-9c corrections pass) |
| Applied to a client report | ⛔ **NO** — no client report has been authored yet |
| Where they get applied | stage 9 debrief → stage 10 report |
