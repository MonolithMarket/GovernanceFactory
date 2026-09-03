# Security Review — GovernanceFactory (CoinDAO launcher)

|  |  |
|---|---|
| **Protocol** | GovernanceFactory — `CoinDAOFactory` and the CoinDAO system it launches |
| **Engagement** | `monolith-governancefactory`, round 1 |
| **Commit audited** | `77b78cd9ebefc8b881d0413a403386b84ecbe115` |
| **Files in scope** | 35 (full list with hashes in Appendix A) |
| **Chain state** | Ethereum mainnet fork, block **25,884,025**, pinned. Monolith `Factory` `0x6D961c9DCF1AD73566822BA4B087892e3839B849` |
| **Toolchain** | Solidity 0.8.26, `via-ir`, optimizer 200 runs, forge 1.5.1 |
| **Review dates** | 1–2 September 2026 |
| **Methodologies** | two independent automated review methodologies, run blind to each other; an adversarial refutation pass with a default-REFUTED posture; fork-execution proving of every High; a completeness pass aimed at code nothing had looked at; mutation testing of every proposed fix; manual adjudication of all of it |
| **Report version** | 1.0 |
| **Issued** | 2026-09-02 |
| **Author** | Inverse Finance Risk Working Group |

### Revision history

| version | date | what changed |
|---|---|---|
| 1.0 | 2026-09-02 | initial issue |

A correction after delivery will be a **new version with the change stated**, never a silent edit.

---

GovernanceFactory is a permissionless launcher: a caller invokes `CoinDAOFactory` and receives a
complete governance system wired to a Monolith stablecoin market. We reviewed the twelve `src/`
contracts and the two `script/` deployment scripts at commit `77b78cd9`, and reproduced everything
of consequence against the **live deployed Monolith protocol** on a mainnet fork pinned at block
25,884,025 — no mock of the dependency is imported into any of the four High reproductions.

**The result: this review cannot certify the system as it stands.** Four findings are graded High,
each with a working reproduction that runs green against the real deployed protocol (24 tests, 24
passed, 0 failed). The four are not four separate problems to schedule independently: three of them
compose into a single chain in which the launch caller ends up holding the DAO, and **three of the
four have no fix we can offer** — every direction that keeps the genesis payment and constrains it
was applied as a real source change and failed.

---

## ⛔ Read this before you plan the work — the order is not the severity order

This is the most actionable thing in the document, so it is first.

**A severity-sorted plan increases your exposure.** Two reasons, both measured.

**1. Fixing the fee passthrough activates a group of defects that are currently dormant *because*
the fee is zero.** Six revenue-handling rows rest on there being revenue to mis-handle. State the
market condition, or this claim is refutable against our own measurements:

| market state | 30-day local reserves at the shipped `feeBps = 0` | status of the revenue group |
|---|---|---|
| the state the design targets (`totalStaked >= totalPaidDebt`) | **0 wei exactly** | inert; the passthrough is the switch that makes it live |
| the live lender we probed, as probed | **≈ 7.74–7.75 COIN** — a range, not a point: three of our own executed measurements of that quantity, taken in different measurement windows, span **0.012587 COIN** — a disagreement in the *second* decimal | **already live**, and the fee lever is worth **+7.6 %** |

So *"there is no revenue to mis-split"* is false as measured on a live market. Note also that the
fee passthrough is **not** the highest-severity item on this list — our own refutation pass graded
its impact **down**. A reader sorting on severity, or on any tool's confidence score, schedules it
early and turns the whole group live before anything in it has been decided.

> ⛔ **One member of the group it activates cannot be fixed.** A change to the revenue split
> re-prices revenue that has **already** accrued, because the split is read at harvest time and
> applied to an unattributed backlog. That defect has exactly one proposed fix in this review, and
> that fix is defeated for the price of gas by donating one wei of Coin to the router. So turning
> the fee on is not a scheduling decision. It is a choice between **a DAO with no revenue** and
> **a DAO whose accrued revenue can be re-priced, permanently, with no fix available today.**
> That choice is yours and this review does not make it for you.

**2. The only mechanism anywhere in this review that interrupts the takeover chain is a party who
can cancel a queued proposal inside the two-day timelock window — and it is not a High.** A
severity-sorted plan schedules it late or never. It is first in the order below *because* it is not
the most severe.

### ⛔ And the guardian is an open design problem, not an available step

Do not read step 1 below as a task a developer can pick up on Monday. **Five shapes are on record;
four of them now fail when they are executed, and the fifth was never built by anyone.**

| shape | what happened when it was run |
|---|---|
| grant the cancel role factory-wide, to one party across all launches | **executed.** The grant is stamped per deployment at launch, and the beneficiary rotation moves nothing already stamped — so that party gains a permanent, non-rotatable veto over every DAO the factory has ever launched, including after its key is compromised, which is the case a two-step rotation exists to handle. Your 65-test suite stayed fully green throughout |
| grant it per DAO, revocable by the DAO's own timelock | **executed, and it does not work.** The timelock is its own admin and the factory renounces admin at launch, so revocation is itself a queued timelock operation — and a party holding cancel authority over queued operations cancels its own removal. Measured: it vetoes its own revocation, the operation id disappears, and it still holds the role three days later. Resolution control present and passing — with its cancel removed, the same operation executes and the role really is revoked |
| grant it per DAO and make it rotatable | **executed.** Rotation is controlled by whoever currently holds the role, so a compromised holder is unrecoverable — which is precisely the case a rotation exists to handle |
| a guardian forbidden to cancel changes to its own permissions | **executed, and defeated by bundling.** Your Governor queues every proposal as a single batch operation, so cancellation is all-or-nothing by proposal. Put the guardian's removal and the takeover in **one** proposal and such a guardian must refuse the whole bundle; the bundle then executes on schedule and removes the guardian with the same transaction that takes the DAO. The unbundled control runs in the opposite direction and cancels the same capture, so this measures the bundling and not a broken guardian |
| a grant that expires on a clock | **not built, by us or anyone.** It is outwaited on its face — the launcher already holds 500,000 liquid GOV at launch and need only wait past the expiry — and we say that rather than claiming we tested it |

⛔ **We are not recommending a guardian design.** We are reporting three things: the takeover chain
has no interruption; a guardian is the only category of mechanism anyone has proposed that would
create one; and every shape tried so far does not work. If you want one, it needs to be designed and
tested as its own piece of work, and we would want to see the design before it ships. ⚠️ We have
not swept the space and do not claim to have: a guardian scoped to a whitelist of targets, or one
held by several parties with an independent removal path, has not been written or tested by anyone,
including us.

### The order

| step | what it is | closes | evidence for the change itself |
|---|---|---|---|
| **0** | **Answer the allocation question (Q-1 below), before any code.** Every remaining option at the allocation link is a different answer to it | nothing directly; it gates every remaining option at that link | a product decision, not code |
| **1** | **A cancel guardian** — the only interruption to the takeover chain anyone has proposed | the unreachable canceller role (`MED-2`) | ⛔ **open design problem.** Five shapes, four failing by execution, one unbuilt |
| **2** | The independent set: **an allocation event** publishing `treasuryVested`, `immediateAllocation` and both vests at launch; a `manager` argument on the attach path; a post-condition on the operator handoff; an assertion that the two four-year clocks agree | `MED-3`, `LOW-6` | mixed: 1 executed, 2 close nothing by design, 1 amended and uncompiled. ⚠️ When **we** wrote the allocation event we transposed two of its own fields and your suite stayed **65/65** — it is one of the five green changes named in the box below |
| **2b** | ⛔ **The predictor guard, on its own row because it is not independent** — returning `address(0)` from `predictCoinDAOAddresses` for a deployer vesting wallet the launch will not build | ⛔ **nothing yet.** It does **not** close `MED-10`, and it does not close the source half of `LOW-14` | ⛔ **blocked — it must not ship alone.** It is executed, and it flips your own `testH8` to failing. But on a **spent** deployment key the same guard reports `address(0)` for a live wallet holding 2,000,000 GOV, and the `code.length` re-check that `MED-10` names as its own disproof then confirms the error instead of catching it. **The companion spent-key repair has never been written, by us or by anyone.** Under the minimum-evidence rule below, the pair is a hypothesis until it exists |
| **3** | `RevenueRouter.setTreasury` **with** its zero-address check **and** the renounce-only pins on the router and the vesting wallets, **as one change** | `MED-13`, the brick half of `MED-4`, `MED-18` | ✅ **executed in both directions** |
| **4** | **Decide** the revenue group — accept it or redesign it — before step 5. Not a task; a gate | `MED-5`, `MED-6`, `MED-16`, `LOW-1`, `LOW-3`, `INFO-1` | a decision, not a patch |
| **5** | The fee passthrough, **last** among the shippable, and only after step 4 | `HIGH-4` | executed as a change; ⛔ but see the box above — it is a client decision, not a shippable step |
| **6** | Report as unremediated | `HIGH-1`, `HIGH-2`, `HIGH-3` | no working fix exists |

⚠️ Steps 2 and 3 are order-independent of each other, and both precede step 5. **Step 2b is not
schedulable**, and it is listed separately so it is not quietly folded back into step 2 — which is
where an earlier draft of this table had put it. Step 1 is independent of everything and can start
immediately. **If you work in severity order**, step 0 does not exist, you spend the first three
steps on the three findings that cannot be fixed, you ship a system that still captures and still
cannot cancel, and the one available mitigation arrives last or not at all.

### ⛔ And be clear about what our fixes are worth

Fifty-two candidate fixes were considered across this review.

| | | |
|---|---|---|
| applied as a **real source change** and re-run against the finding's own reproduction | **19** | |
| — of those 19, **killed by executing them**: written, built, run, and failed | **14** | a subset of the 19, not a separate bucket |
| **never compiled or executed by anyone**, including us | **at least 22** | each one is labelled a hypothesis wherever it appears |
| backed by execution end to end, under the rule below | ⛔ **2** | fewer than the 5 that survived execution, because three of those depend on a companion change nobody has written |

> **A fix's evidence level is the MINIMUM of the evidence levels of every fix it requires.**

Applying that rule, **the ship list is two entries**: the treasury setter with its zero-address
check, and the renounce-only pins — and those two are step 3, which ships as one change. Everything
else labelled a fix in this report is a **hypothesis**, and is labelled as one wherever it appears.
Two of the fixes that *were* tested this round turned out to make something worse, and both were
caught by running them rather than by reading them.

⚠️ *"At least 22"* is a floor, not an estimate. Our own census of the 52 leaves
eleven unaccounted for, and every error we found in that arithmetic ran in the same direction — it
made the tested fraction look larger than it is. **Read the gap as at least this wide, never
narrower.** That is a coverage gap in the evidence about fixes, and it is stated as one.

⚠️ **Please do not use "the 65-test suite still passes" as your acceptance gate.** We have produced
five separate changes — including a permanent lock-up of 2.8 million tokens, and a governance
configuration nobody could vote in — that leave it fully green. The gate to use instead is one line:
**a fix is verified when the reproduction of the finding it targets STOPS reproducing, never when an
unrelated suite stays green.** The per-change table is in *How to verify a fix*, below.

---

## Findings by severity

The **proven by execution** column matters: without it a reader sums the table and infers one
uniform standard of proof, when the evidence behind a High and a Low may differ by the whole
distance between a fork simulation and a code read.

| severity | count | proven by execution |
|---|---|---|
| Critical | 0 | — |
| High | 4 | **4** |
| Medium | 19 | 18 |
| Low | 14 | 11 |
| Informational | 3 | 1 |
| Raised and then refuted by us (no grade) | 1 | 1 |
| **total rows** | **41** | **35** |
| Descoped — outside the threat model (Appendix B) | 6 | — |

**35 of the 41 rows are proven by execution against the real deployed protocol at block 25,884,025.**
The six that are not are arithmetic or code-read only; each says so in its own entry, with the
reason. Execution was available throughout this engagement, so *not proven by execution* is never a
default here — where it appears it is a stated choice.

Read four numbers rather than one total: **35 defects · 3 observations · 2 non-defects carried with
their rulings · 1 limitation recorded before the review began.** Compressing them produces either
"41 findings", which overstates, or "31 defects" — the number every document in this review carried
until the ledger reconciled them — which is wrong.

**All 40 graded rows cluster into 18 pieces of work**, grouped by the line a developer edits. The
41st row is the finding we raised and then withdrew; it carries no grade and no work item. ⚠️ Two
cautions on that 18, and they change how you plan against it:

- The grouping is a **cover, not a partition**. `MED-18` and `MED-19` each belong to two groups —
  do each of them once.
- **Two of the groups must not be treated as single edits.** `W1` has two opposite failure modes and
  needs both branches written out. `W6` collapses five rows that share a contract while a sixth
  defect in that group sits in a **different** contract and has no working fix — finishing the group
  does not finish that defect.

### How to read these severities

Severity is assigned by **impact**, independently of how confident any tool was.

| severity | means |
|---|---|
| **Critical** | an unprivileged actor can take or permanently freeze principal |
| **High** | material loss or a brick, triggerable by an unprivileged actor in a plausible state |
| **Medium** | surplus leakage, griefing with a cost to the attacker, or loss requiring a specific but achievable state |
| **Low** | dust, non-compounding, or fails safe |
| **Informational** | no exploit path established; recorded for your awareness |

**Confidence** is reported separately and never changes severity — it describes how completely we
proved the path, not how much it would cost you.

⚠️ **A live Critical argument exists for two of the four Highs, and we declined it.** The outcome is
identical either way and nothing is bought by rounding up, so the argument is recorded in those
entries rather than acted on.

⭐ **The verdict does not depend on all four Highs standing.** It fires
on **one** High, so it survives the loss of any single row of the four; all four would have to fall
for the outcome to change. That is the reason we can afford to write each derivation out for attack
rather than defend a package. **Each of the four is written out below so it can be attacked on its
own evidence** — if one is wrong, it falls on that evidence and the verdict is recomputed, never the
reverse.

⭐ Several rows are graded **Low deliberately, because the measured harm is dust** — 0 ppm/year of
truncation residue over 8,760 harvests, 19 wei over 20 calls, 50 wei over 50 distributions. Those
measurements behind those grades are in **Appendix D**, so the grade can be checked rather than
taken.

---

## The verdict, and what it does and does not mean

Against criteria written in the scope document **before** the review ran:

> **FAIL / STOP** when any of: (a) a Critical or High survives refutation with a working fork
> reproduction; (b) a scoped unit cannot be covered; (c) the scope lock drifts mid-audit; (d) a
> scoped question cannot be answered either way.

**The verdict is `FAIL / STOP`, on clause (a) and on clause (a) alone.** Four findings graded High
survived the adversarial refutation pass, and each has a working fork reproduction that runs green
at the pinned block against the real deployed Monolith protocol, with no mock of the dependency
imported: **24 tests, 24 passed, 0 failed.**

Clauses (b), (c) and (d) are **not** triggered. All 15 units required by the scope are covered
(Appendix C). The scope lock is intact, re-checked at the start and the end of every pass — 35 of 35
files match. All ten scoped questions are answered, eight of them by execution, and the two that
split into halves are recorded as splits rather than rounded to one word.

**What it does not mean.** `FAIL / STOP` is a grade against our own pre-committed criteria. It is
not an instruction to you, and it is not a statement that a deployed system is at risk — it says
that this round cannot certify the system as it stands. Our separate halt rule, which covers
anything exploitable found in the deployed Monolith protocol itself, was **not** triggered: each of
the four Highs has its defect and its fix inside `src/`, and nothing exploitable in Monolith itself
was surfaced. `Lender.buy()` being a permissionless PSM mint is ordinary Monolith behaviour and the
reproductions use it as an environment fact.

---

## Scope

**In scope, and covered by the verdict:** the 12 `src/` contracts (~1,400 lines) and the two
`script/` deployment scripts, at the locked commit — 15 units in all, counting the eight-phase
launch sequence as a unit in its own right, because a defect in an ordering has no single vulnerable
line.

**In scope as a boundary:** every assumption GovernanceFactory makes *about* Monolith, admitted only
where the defect **and** the fix both land in GovernanceFactory code.

**Out of scope, no verdict:** Monolith's own Factory / Lender / Coin / Vault / InterestModel
internals (seven prior reviews exist); `lib/**`; `test/**`; the economic and tokenomic soundness of
the 65:5:28 allocation as a business choice; off-chain infrastructure; the front end.

### Threat model — who we treated as trusted

Quoted from the scope document, because this paragraph decides how Appendix B should be read, and it
is the paragraph you are most likely to disagree with:

> ⭐ **ZERO TRUST, by client direction.** No actor is assumed honest. This is expressed as a
> **capability matrix**, not a trust binary, so that "actor did what they are permitted to do" stays
> separable from "actor did something they should not have been able to do."
>
> | actor | trusted? | capabilities by design | consequence |
> |---|---|---|---|
> | unprivileged caller | **never** | call `deploy()`, `deployForExistingCoin()`, stake, withdraw, `fundNextTranche()`, `distribute()` | always in scope |
> | CoinDAO deployer (the launch caller) | **no** | chooses `userSalt`, gov token name/symbol, `deployerStakeBps` ≤ 20%, `deployerRecipient`, staking-token choice, Monolith `DeployParams`, `manager` | a hostile deployer is in scope |
> | `monolithBeneficiary` | **no** | receives 2% of every launch, vesting 4y; may rotate itself (2-step) | in scope |
> | Timelock / Governor (post-launch DAO) | **no** | owns `RevenueRouter`; sets `govStakingBps` 0–100%; rotates Lender `manager`; treasury vesting recipient | ⭐ see the DESCOPED rule below |
> | Monolith Lender `operator` (= `RevenueRouter`, permanent) | **no** | `pullLocalReserves`, `setManager` — and nothing else the router exposes | in scope where our code is the fix |
> | Monolith protocol itself | **assumed correct** | — | ⛔ not re-derived; seven prior audits |
> | `CoinDAOFactory` deployer / implementation supplier | **no** | supplies six implementation addresses at construction | in scope |
>
> ⛔ **What a DESCOPED finding still gets.** Nothing is silently dropped. A capability that is
> *documented, intended, and correctly gated* is reported as a **centralization risk** in its own
> report appendix — with the capability, its holder, and its worst-case stated plainly. It is
> **not** promoted to a bug severity. A capability reachable by someone who should not hold it, or
> exceeding what is documented, **is** a bug.

That last rule is the one that put six items in Appendix B. **If your trust assumptions differ from
the ones we were given, Appendix B may be the most important page in this report.**

### ⭐ What this review does NOT claim

A clean result here does **not** prove:

- that the **Monolith protocol** is correct — it was never audited by us;
- that GovernanceFactory is safe against a **future** Monolith change — this review is fixed to
  Monolith's behaviour at block 25,884,025;
- that the vendored OpenZeppelin trees will **remain** the v5.6.1 release. The OpenZeppelin source
  files compiled into the in-scope artifacts were verified byte-identical to the upstream v5.6.1 tag
  at the locked commit (**64 of 64**, counted from the compiler's own `metadata.sources` and
  cross-checked against the build cache's import closure); but the repository records **no submodule,
  tag or lockfile entry** for either tree — `.gitmodules` and `foundry.lock` pin `lib/forge-std`
  **only** — so nothing in the repository prevents them moving silently after this date. *Identical
  today* is proved; *pinned* is false, and that gap is carried as a live observation (`LOW-8`), not
  as a discharged assumption;
- that `IMonolith.sol` is a **complete** description of the deployed Lender. All **ten** declared
  selectors and the eighteen-field `DeployParams` layout were verified against the deployed
  contracts at block 25,884,025, by round-tripping every field through the real Factory and reading
  each back off the resulting Lender, with a same-width field-swap mutation as the control — the
  real Factory rejects the permuted layout. But **at least eight further Lender selectors exist that
  the interface does not declare**, and this review says nothing about them. The correct summary is
  *incomplete, not incorrect*; never *"the ABI is verified"*;
- that the **economic design** (the 65:5:28 split, the four-tranche emission schedule, the 0.1 %
  quorum) is sound — explicitly out of scope;
- that findings **previously reported** to you by third parties are absent. Five prior third-party
  reports were excluded from our corpus by your own direction, to protect the independence of the
  two review methodologies. The consequence is accepted knowingly and stated here: **we cannot tell
  you "this was already reported to you and you declined it"**;
- that any **deployed instance** is safe. This review covers source at one commit, not any
  deployment — and see Q-4 below;
- **absence of vulnerabilities.** An audit cannot prove a negative. Every finding below carries a
  disproof condition; the coverage claim in Appendix C is the honest boundary of what was examined.

### Limits on verification

| limit | what it means for these findings |
|---|---|
| Six of the 41 rows are arithmetic or code-read only | they are marked in their own entries with the reason. Execution was available; these six are choices, not capability gaps |
| Every invariant harness we built is **instantaneous and single-finding** | none is quantified over time or over a whole fix set. With the allocation bounded *and* the funding call deferred — the strongest combination we built — two invariants read PASS while the identical capture completed one day later. ⛔ **An invariant result in this review has resolution against a single defect and none against a composition.** Do not read one as blessing a fix |
| No Sepolia RPC was available | the deploy script's constants were not cross-checked on a testnet. Mainnet proving is unaffected |
| The current Monolith re-audit is pre-publication and confidential | we could not cross-check against that prior art. Irrelevant to the in-scope verdict, and stated so you know it was not consulted |
| `script/**` was reviewed by **one** of the two methodologies | a scope-document line excluded it from the other's brief. Under our coverage rule it counts as covered; under the two-methodology design it does not. `MED-19` and `LOW-14` therefore have **no independent corroboration** |
| Five prior third-party reports were excluded by your direction | recorded as a decision, not a gap. See above |
| Every unit and all 115 declarations carry a disposition, but **nobody re-read all 115 individual citations** | a wrong citation inside a covered unit would survive our completeness check. A silently dropped unit, or a mis-stated total, would not |
| **At least 22 of 52 candidate fixes were never compiled by anyone** | the evidence about *fixes* is much thinner than the evidence about *defects*. Every untested fix is labelled a hypothesis where it appears |
| That GovernanceFactory is not deployed anywhere rests on **your statement alone** | no independent check was performed. See Q-4 |

> An audit is evidence about the code that was read, in the time that was available, under the
> threat model above. It is not a guarantee of absence.

---

## Four questions only you can answer

These are **not** findings. They are decisions that belong to you, surfaced because we could not
make them on your behalf without inventing a trust assumption we were not given. Each one changes
what the rest of this report can offer.

**Q-1 — Is the 5 % immediate allocation the deployer's compensation, or the DAO's liquid treasury?**

As shipped it is paid liquid, in one transfer, in the launch transaction, to an address the caller
names — and on the default branch nothing validates that address. **Your own two comments in the
file already disagree about which it is.** `CoinDAOFactory.sol:281-282` describes the 5 % as a
*system* slice in a 65:5:28 split:

```solidity
// The remainder is split using a 65:5:28 staking/immediate/vested-treasury ratio.
// Increasing the deployer stake proportionally reduces all three of those allocations.
```

while the comment above the payout at `:490` describes it as the deployer's:

```solidity
// A missing deployer recipient sends only the liquid allocation to the timelock; vested deployer stake is disallowed.
```

Every remaining option at that link is a different answer to this one question, and the answer is a
product decision. ⛔ It is not an audit finding and we do not make it. The only direction nobody has
tried is **not making a liquid payment to a private address at launch at all** — routing it to the
timelock, or to a wallet the DAO controls. Whether that is acceptable depends on what was promised
to deployers, which is yours to answer. Tell us the answer and we will tell you what it costs.

**Q-2 — Are the Governor's parameters what you intended, and are their absent bounds deliberate?**

Voting delay 7,200 blocks, voting period 36,000 blocks, proposal threshold `supply / 1_000`, quorum
numerator `1` against a `quorumDenominator()` of `1_000`. Five inherited setters —
`setVotingDelay`, `setVotingPeriod`, `setProposalThreshold`, `updateQuorumNumerator`,
`updateTimelock` — are reachable through a passed proposal and are overridden nowhere in `src/`;
OpenZeppelin's own `_setVotingPeriod` rejects only zero. The right to use them is the DAO's by
design and is in Appendix B. **The absence of any floor or ceiling on five of them is documented
nowhere**, which is why `MED-9` is a finding and not an appendix entry. ⚠️ Do not read a proposed
bound out of this: every specific number that appeared during this review was our own arbitrary
placeholder, explicitly labelled as such, and your suite has zero resolution on them.

**Q-3 — Is the four-year horizon a public commitment or an internal target?**

Two four-year clocks exist and are equal by arithmetic — `FOUR_YEARS = 365 days * 4`, and
`TRANCHE_COUNT × COIN_STAKING_REWARD_DURATION = 4 × 365 days` — and **that identity is asserted
nowhere in `src/`, `script/` or `test/`**. One clock is an enforced deadline, the other only a floor:
each tranche funding is permissionless and can be delayed, and every delay pushes the emission span
out. The overrun is the sum of accumulated delays and has **no upper bound**; measured examples of
two and three 180-day delays give 360 and 540 days of overrun respectively, and neither figure is a
constant. Whether that matters depends on what you have published. The identity half survives as
`LOW-7` regardless.

**Q-4 — Is GovernanceFactory deployed anywhere, on any chain or testnet?**

Our scope records *"not deployed"* as a **client statement with no independent check performed**.
Every conclusion in this report about urgency rests on it. If it is wrong, the halt rule that
governs live systems applies and this report should be read under different time pressure. Please
confirm.

---

## Findings

Findings are presented as a **work list clustered by root cause**: one design decision producing
three defects is one work item, and the work item is what a developer picks up. The four Highs are
written out in full because they carry the verdict. Every entry answers four questions and stops:
*what is wrong · where · what happens if it is not fixed · how do I verify my fix.*

### Work-item index

40 graded rows, 18 work items, grouped by the line a developer edits. ⛔ This is a **cover, not a
partition**: the table below holds **42 id cells for 40 distinct rows**, because `MED-18` and
`MED-19` each appear twice. Both overlaps are real.

| # | the one decision | rows | contract a developer opens |
|---|---|---|---|
| **W1** | `_validate` polices exactly one of four `(bps, recipient)` cells — the one that *costs* the deployer — while the liquid allocation is paid to a caller-named address | `HIGH-1`, `MED-19` | `CoinDAOFactory.sol` |
| **W2** | The governance system can rewrite its own constitution with one proposal, and nothing outside it can intervene | `MED-1`, `MED-2`, `MED-8`, `MED-9` | `CoinDAOGovernor.sol`, launch phase 3 |
| **W3** | Quorum's base is the staked supply, the tally's base is the *delegated* staked supply, the threshold's base is total supply — three bases, one vote | `HIGH-2`, `MED-15` | `CoinDAOFactory.sol`, `CoinDAOGovernor.sol` |
| **W4** | The emission clock advances on wall time and never reads `_totalSupply` | `HIGH-3`, `LOW-2`, `LOW-13`, `INFO-3` | `StakingRewards.sol` |
| **W5** | `StakingRewardsFunder` computes a tranche from a **live balance** and duplicates the four-year schedule instead of deriving it | `MED-11`, `LOW-7`, `LOW-11`, `INFO-2` | `StakingRewardsFunder.sol` |
| **W6** | `StakedGovToken` attributes a whole notification to the supply present at that instant — no time weighting, no residual carry, no harvest on exit | `MED-6`, `MED-16`, `LOW-1`, `LOW-3`, `INFO-1`, and ⛔ `MED-5` **as a separate edit** | `StakedGovToken.sol`; `RevenueRouter.sol` for `MED-5` |
| **W7** | `deployForExistingCoin` re-implements a **subset** of `deploy()`'s validation instead of sharing it | `MED-3`, `LOW-6` | `CoinDAOFactory.sol` |
| **W8** | `predictCoinDAOAddresses` is a second implementation of the launch, and it has drifted from the first | `MED-10`, `LOW-14` | `CoinDAOFactory.sol`, `script/DeployCoinDAO.s.sol` |
| **W9** | A mutable global is stamped into an immutable binding, and the movers move one binding of many | `MED-13`, `MED-12`, `MED-18` | `RevenueRouter.sol`, `CoinDAOFactory.sol` |
| **W10** | Vesting constrains *when* tokens leave, never *who owns the wallet* | `MED-4` (ships with `MED-18`) | `CoinDAOVestingWallet.sol` |
| **W11** | Voting weight is a per-block checkpoint on a token with free entry and exit | `MED-14` | `StakedGovToken.sol` |
| **W12** | Surface that exists but cannot function: `approve` / `permit` on a non-transferable token | `LOW-4` | `StakedGovToken.sol` |
| **W13** | `deploy()` forwards caller-supplied `DeployParams` with only `.operator` and `.manager` overridden | `LOW-5`, `MED-7` | `CoinDAOFactory.sol` |
| **W14** | The one irreversible external handoff has no post-condition | `LOW-12` | `CoinDAOFactory.sol:452-453` |
| **W15** | The dependency's revenue lever is unreachable after launch | `HIGH-4`, `MED-17` | `RevenueRouter.sol` |
| **W16** | The dependency tree is unpinned | `LOW-8` (+ the version half of `LOW-9`) | `foundry.lock`, `.gitmodules` |
| **W17** | The deploy script's env handling defaults silently and its preflight gate cannot fail | `MED-19` | `script/DeployCoinDAO.s.sol` |
| **W18** | Block-count governance timings on a chain-agnostic factory, with no `clock()` override | `LOW-10` | `CoinDAOGovernor.sol` |

⛔ **Two places this clustering must not be applied.**

1. **`W1` has two opposite failure modes and needs both branches written out.** The two branches are
   not variants of one bug: naming a recipient pays 500,000 liquid GOV
   to a private address; omitting one pays it to the timelock and produces a different,
   non-equivalent state. A change written against either branch leaves the other intact.
2. **`W6` is one accounting decision, not five defects — but `MED-5`'s line is in a different
   contract.** Four of the rows are an accounting model inside `StakedGovToken`; `MED-5` is *when
   the split is read* inside `RevenueRouter`. A developer who finishes `W6` will not have fixed
   `MED-5`, whose only proposed fix was killed by a mechanism the other four do not share.

⭐ One useful result from the clustering: seven rows that no earlier stage of this review had tabled
all land in existing groups. **They add zero new work items.** The work list did not grow; the
honesty of the count did.

---

## HIGH-1 — the liquid genesis allocation is paid to a caller-named address, on the one branch `_validate` does not police

**Severity:** HIGH · **Confidence:** high · **Status:** **proven by execution** · **Work item:** W1

**Location** — `CoinDAOFactory.sol:490-493`, against `_validate` at `:556-563`

```solidity
// CoinDAOFactory.sol:490-493
// A missing deployer recipient sends only the liquid allocation to the timelock; vested deployer stake is disallowed.
address immediateRecipient =
    govParams.deployerRecipient == address(0) ? deployment.timelock : govParams.deployerRecipient;
govTokenErc20.safeTransfer(immediateRecipient, allocation.immediateAllocation);
```

```solidity
// CoinDAOFactory.sol:556-563
function _validate(GovLaunchParams calldata params) internal pure {
    if (params.deployerStakeBps > MAX_DEPLOYER_STAKE_BPS) {
        revert DeployerStakeExceedsMaximum(params.deployerStakeBps);
    }
    if (params.deployerStakeBps != 0 && params.deployerRecipient == address(0)) {
        revert DeployerRecipientRequired();
    }
}
```

**Description.** The invariant that breaks is: *the amount of liquid governance power a launch may
put in one unvalidated hand is bounded.* It is not. `_validate` has two clauses, and both of them
police the branch on which the deployer takes a **vesting** stake — the branch that costs the
deployer something. The shipped default, `deployerStakeBps = 0`, is the branch neither clause
reaches, and it is the branch on which the liquid payment is made.

⭐ **The comment at `:490` engages with exactly half of this, and the half it engages with is the
safe one.** It says a missing recipient sends the liquid allocation to the timelock, and that is
true and correct. What it does not cover is the other side of the same ternary: when a recipient
**is** supplied on the zero-bps branch, nothing validates it, and the payment is liquid, immediate,
and to an address of the caller's choosing.

**Attack path.**

1. Anyone calls `deploy()`. It is `external` with no caller gate, no allowlist and no fee — and we
   confirmed on the fork that a bare EOA can drive a launch through the real Monolith Factory.
2. They set `deployerStakeBps = 0` (the shipped default) and `deployerRecipient` to themselves.
   `_validate` passes: its first clause needs `bps > 2_000`, its second needs `bps != 0`.
3. Phase 7 transfers `immediateAllocation` liquid to that address. From `allocationFor` at
   `:273-290` with `deployerStakeBps = 0`: `10,000,000 − 200,000 = 9,800,000`, and
   `9,800,000 × 500 / 9,800 = **500,000 GOV**.
4. That is **50×** the proposal threshold (`GOV_TOKEN_SUPPLY / 1_000 = 10,000 GOV`) and **1000×**
   the genesis quorum. In the reproduction the caller proposes, votes and passes alone, and changes
   a **real mainnet Lender's** manager.

**Impact.** The launch caller ends up in unilateral control of the DAO the launch created, from
genesis, at no cost beyond gas. **The capture survives selling every token**, because the proposal
that matters can be created and passed before any sale. Anyone who joins the DAO afterwards joins a
system that is already controlled.

**⭐ A second, independent defect in the same predicate: the documented cap does not cap the total.**
`MAX_DEPLOYER_STAKE_BPS = 2_000` bounds one of **two** channels to the same address. At the stated
20 % maximum: `deployerVesting = 2,000,000`, `remaining = 7,800,000`,
`immediateAllocation = 7,800,000 × 500 / 9,800 = 397,959.18`, total to one caller-named recipient
**2,397,959.18 GOV = 23.98 % of supply**. Derived by hand from your constants.

**Why HIGH and not CRITICAL.** At the moment of capture no third party's principal exists — the DAO
is created in the same transaction and the state is publicly inspectable before anyone joins. The
attach path reaches an existing market's users but requires the incumbent operator
(`CoinDAOFactory.sol:328`). ⚠️ The Critical argument is recorded rather than suppressed; the outcome
is identical either way.

**What would disprove this finding.** A caller gate on `deploy()`; a `_validate` clause that reaches
the zero-`deployerStakeBps` branch; or a demonstration that 500,000 liquid GOV cannot constitute a
proposal — refuted both by the executed reproduction and by arithmetic on your own constants.

**⛔ Suggested fix: none. The space is swept, and the last direction is not ours to take.** Every
direction below was applied as a **real source change** and re-run against this finding's own
reproduction:

| direction tried | what killed it |
|---|---|
| tighten the recipient predicate so the default branch is policed | **killed** — defeated for 51.02 GOV: setting `deployerStakeBps = 1` satisfies the tightened clause and still pays 499,948.98 GOV liquid, 0.0102 % short of the full capture |
| require a non-zero recipient unconditionally | **killed alone** — it makes the shipped default unlaunchable and makes the capture mandatory rather than optional; 26 of your 65 tests fail |
| release the genesis payment over four years instead of paying it liquid | **killed** — a 4-year linear release puts 10,273.97 GOV past the 10,000 threshold by **day 30**, and the identical exploit script reaches `Pending` again. It buys about 29 days |
| bound the liquid share below the proposal threshold | **killed** — it bites at `t = 0` and is **defeated in under one day** by this same launch's own reward stream. We applied the cap at **5,000 GOV** as a source mutation; one day later the launcher **holds 10,787.67 GOV** against a 10,000 threshold — the 5,000 capped allocation *plus* the 5,787.67 earned by staking 1 wei of the market's own Coin into this same launch's emission. At that measured **5,787.67 GOV/day**, **no cap value, including zero, buys more than 41.5 hours** |
| the last two together | **killed** — same composition, same result |

⛔ **The reason they fail together is the important part**, and it is why this finding and `HIGH-3`
are one problem: bounding the payment does not help, because **the same launch transaction opens a
second and larger source of governance tokens** — the emission stream — which reaches the proposal
threshold in **1.728 days** on the shipped defaults.

**The only untried direction is Q-1, and it is a product decision.** Not paying a liquid genesis
allocation to a private address at all — routing it to the timelock, or to a wallet the DAO
controls — has never been evaluated by anyone, because whether it is acceptable depends on what was
promised to deployers. It reaches you as a question, never as a recommendation from us.

**How you verify any change here**

```
forge test --match-path repro/NM-002-genesis-allocation-capture.fork.t.sol
```

5 of 5 green today **because the defect is present**, on a real mainnet Lender. Its control
`test_NM002_controlA_zeroRecipient_sameMoneyNoCapture` is the resolution — the other branch of the
same predicate, the same money, no capture. When a change lands, the capture tests must stop
reproducing **and the control must still pass**.

---

## HIGH-2 — quorum's base is the staked supply while the threshold's is total supply, so at the shipped quorum numerator the quorum can never exceed the threshold

**Severity:** HIGH · **Confidence:** high · **Status:** **proven by execution** · **Work item:** W3

**Location** — `CoinDAOFactory.sol:33-34` against `CoinDAOGovernor.sol:64-70`

```solidity
// CoinDAOFactory.sol:33-34
uint256 public constant GOVERNOR_PROPOSAL_THRESHOLD = GOV_TOKEN_SUPPLY / 1_000;
uint256 public constant GOVERNOR_QUORUM_NUMERATOR = 1;
```

```solidity
// CoinDAOGovernor.sol:64-70
function quorum(uint256 timepoint) public view override(Governor, GovernorVotesQuorumFraction) returns (uint256) {
    return super.quorum(timepoint);
}

function quorumDenominator() public pure override returns (uint256) {
    return 1_000;
}
```

**Description.** The invariant that breaks is: *the quorum is a brake on the proposer.* Here it is
denominated in a quantity the proposer controls. `quorum(t) = stakedSupply(t) / 1000`, while
`threshold = 10,000,000 / 1000 = 10,000 GOV` and is fixed. stGOV is a 1:1 wrapper, so
`stakedSupply <= totalSupply` in every reachable state, and therefore — **at the shipped numerator of
1** — `quorum <= threshold` in every reachable state. Anyone who can propose can constitute the
quorum alone.

⚠️ **That inequality is a property of the shipped numerator, not of the design, and we qualify it
because your own file disproves the unqualified form.** `updateQuorumNumerator` is reachable through
a passed proposal, and `CoinDAOGovernor.t.sol` shows `1_001` reverting with
`GovernorInvalidQuorumFraction(1001, 1000)` — so numerators up to `1_000` are intended. At `1_000`,
`quorum = stakedSupply`, which exceeds the 10,000 GOV threshold for any staked supply above 10,000
GOV. **This does not rescue the finding, and the kill table below is why:** we mutated to that
maximum setting and the capture still succeeded. The inequality is what the shipped configuration
guarantees; the capture holds at *every* setting.

**Attack path.** Unprivileged, at 0.1 % of supply. Hold the threshold; propose; vote for your own
proposal; `_quorumReached` uses `>=` and is satisfied by your own weight. In the reproduction the
quorum computes to **10.0 GOV** against **10,000 GOV** of votes cast.

**Impact.** Material brick of the only supply-side brake on a system holding 9.5M GOV. No principal
moves on this row by itself — the taking is `HIGH-1`'s — but this is what makes that taking
sufficient rather than merely large.

**Why HIGH and not CRITICAL.** Nothing is taken or frozen by this row alone; a brake is removed.
Composition with `HIGH-1` is a remediation-order fact, not a severity bump.

**What would disprove this finding.** Any reachable state where `stakedSupply > totalSupply` — a
mint back door on stGOV, which we ABI-verified absent — or a quorum denominated on something other
than the staked wrapper, or an against-vote counting toward quorum.

**⛔ Suggested fix: none exists at this link, and the parameter space is swept.**

| direction tried | what killed it |
|---|---|
| any numerator from 1 to 999 | **killed** — swept. At genesis even 999 is cleared by the sole staker |
| the maximum legal setting, a 100 % quorum | **killed** — mutated to it, and the capture still succeeded. When the attacker *is* the staked supply, `forVotes >= quorum` at every setting |
| a base of 4 % of **total** supply | **killed against this attacker, and it is citable only with the attacker named.** It stops the *acquisition* attacker who buys in — a 10,000 GOV holder cannot clear a 400,000 GOV floor. It fails against the *gift* attacker: the launcher is handed 500,000 GOV at genesis and clears the floor unaided. A fix is killed by the attacker it fails against, not rescued by the one it stops |
| any absolute floor, above or below | **killed** — swept. Below 500,000 the launcher succeeds unaided; above it the DAO deadlocks, repairable only through the mechanism the floor disables |

⭐ *You cannot bound a quantity by a fraction of itself.* Any fix has to live at the **amount of
liquid GOV a launch creates**, which is `HIGH-1` — where the space is also swept, and where the one
remaining direction is Q-1.

**How you verify any change here**

```
forge test --match-path repro/NM-001-quorum-self-sufficiency.fork.t.sol
```

4 of 4 green today because the defect is present. Its two controls are its resolution and they run
in opposite directions.

**Prior art in your own repository.** `testFuzzH9_QuorumCanNeverExceedTheProposalThreshold` and
`testH9b_LoneProposerAtThresholdClearsQuorumTenfold` — you fuzzed the identical property.

---

## HIGH-3 — the emission stream opens against a provably empty pool, and the clock never reads `_totalSupply`

**Severity:** HIGH · **Confidence:** high · **Status:** **proven by execution** · **Work item:** W4

**Location** — `StakingRewards.sol:94-97` and `:145-158`, driven from `CoinDAOFactory.sol:487`

```solidity
// StakingRewards.sol:94-97
function rewardPerToken() public view returns (uint256) {
    if (_totalSupply == 0) return rewardPerTokenStored;
    return rewardPerTokenStored + ((lastTimeRewardApplicable() - lastUpdateTime) * rewardRate * REWARD_PRECISION)
        / _totalSupply;
}
```

```solidity
// CoinDAOFactory.sol:485-488  (phase 7, inside the launch transaction)
govTokenErc20.safeTransfer(address(coinStakingRewardsFunder), allocation.coinStakingRewards);
coinStakingRewards.setRewardsDistribution(address(coinStakingRewardsFunder));
coinStakingRewardsFunder.fundNextTranche();
coinStakingRewards.renounceOwnership();
```

**Description.** The invariant that breaks is: *a notified reward interval must be paid to someone.*
The clock advances on wall time and never reads `_totalSupply`, so an interval that elapses against
an empty pool is neither carried nor queued — it is discarded. On `deploy()` the staking token is
created by the same transaction that funds the stream, so `_totalSupply == 0` is not a state an
attacker has to reach; it is entailed by the launch.

**⭐ Your comment at `StakingRewards.sol:147-149` states this decision, and the finding has to
engage with it rather than around it:**

```solidity
// Rewards notified while `_totalSupply == 0` stream to nobody and are permanently locked, because `rewardPerToken()` does not accrue without stakers
// This is accepted by design — the window between tranche funding and the first staker is expected to be short
// Do not add queueing here without also gating StakingRewardsFunder as its tranche schedule relies on `periodFinish` advancing on notify
```

Two things it does not cover:

- **The failure mode it accepts is the burn. The measured failure mode is the *capture*.** "Streams
  to nobody and is permanently locked" describes the case where nobody stakes. The case that
  actually happens is the opposite: the **first** staker of any size takes the accrued stream whole.
  We executed it — **1 wei of real invUSD takes 2,112,499.99999999996 GOV**.
- **"The window is expected to be short" is a statement about intent, not a constraint in the
  code.** `fundNextTranche()` contains **zero** occurrences of `msg.sender` (positive control: the
  same pattern returns **9 matching lines, 10 occurrences** in `CoinDAOFactory.sol`), so the
  window's length is chosen by whoever calls it — and on the launch path it is opened inside the
  launch itself, when the pool is empty by construction rather than by timing.

The third clause — do not add queueing without also gating the funder — is a genuine constraint on
any fix, and it is why none of the candidates below is a one-line change.

**Attack path.**

1. A launch runs. Phase 7 funds tranche 0 into `StakingRewards` while `_totalSupply == 0`. Tranche 0
   is `9,800,000 × 6,500 / 9,800 = 6,500,000` total rewards × `trancheBps(0) = 3_250` bps =
   **2,112,500 GOV**, at `rewardRate = 66,986,935,565,702,688 wei/s = 5,787.67 GOV/day`.
2. **Inside the launch block**, any third party mints Coin from the fresh market's PSM — we verified
   `Lender.buy()` is a permissionless mint, live from the market's first block — and stakes 1 wei.
   We executed this with a **stranger**, asserted in the test to be neither the launcher, nor the
   manager, nor the lender's operator, with `block.number` asserted unchanged three times. Control:
   the same call from an address holding no PSM asset **reverts**, so the assertion is not vacuous.
3. That staker accrues the entire live stream. If nobody stakes, the same tokens are destroyed
   instead. **There is no recovery function in existence.**

**Impact.** **2,112,500 GOV per tranche**, either burned or taken whole by the first staker of any
size. It also feeds `HIGH-1`: the stream reaches the 10,000 GOV proposal threshold at
`t = 149,283 s` — **1.728 days** — which is why bounding the genesis allocation cannot work.

**Why HIGH and not CRITICAL.** Our Critical test requires principal *taken or frozen*. On **tranche
0** — the one funded inside the launch — the victim DAO is created in the same transaction and no
third party's principal exists yet. **Tranches 1–3** do reach third-party principal, but need an
empty pool at a tranche boundary: achievable and rational, but a specific state.

> ⚠️ **The indexing here is the contract's, not ours.** `StakingRewardsFunder.sol` is 0-indexed with
> `TRANCHE_COUNT = 4`, so the tranches are 0, 1, 2, 3, and both `trancheBps(4)` and
> `trancheAmount(4)` revert `InvalidTranche(4)` (`:55-64`). The line comments above `trancheBps` (`:49-54`)
> label the same four *"Tranche 1–4"* in prose. That is where our own drafts drifted, so it is stated once
> here: the reproduction `test_NM003_boundaryAuction_tranche1IsPermissionless` is **correct under the
> code's own indexing** and should not be "fixed" to match the prose.

**What would disprove this finding.** A path by which a notified interval survives a zero-supply
window — a residual carry, a queue, or a `periodFinish` that does not advance on notify. ⭐ Any
disproof has to engage with your own comment at `:149`, which refuses a queue for a stated reason.

**⛔ Suggested fix: none survives.**

| direction tried | what killed it |
|---|---|
| revert the launch when the pool is empty | **killed** — 27 of your 65 tests fail, including all ten `NemesisPoC4` tests, and it removes the product's only construction path |
| take the in-launch funding call out of `_deployCoinDAO` | **killed as a capture fix** — the launcher still took **2,112,499.99999999996 GOV**, identical to the wei. ⚠️ It *does* close the burn variant, and the two halves must not be conflated |
| restore a capped `recoverERC20` on `StakingRewards` | **killed** — the owner is renounced during the launch, so it is dead code without an owner; and with one, the upstream version excludes only the staking token, so the owner seizes rewards already earned. A working version needs a sum of per-account rewards this contract does not maintain. ⭐ Your comment at `:172-173` says these Synthetix hooks are *"intentionally omitted because the launch flow does not depend on them"* — correct about the launch flow, and exactly why restoring one is not a small change: the hook needs an owner that the launch deliberately destroys three lines later |
| gate on a minimum market size — a TVL floor | **killed** — it cannot distinguish market TVL from the launcher posting the floor in a token they can mint. Applied together with dropping the funding call: same result, to the wei |

⛔ The time-escaped variant of the last one — a gate that expires — **has never been written by
anyone**, so neither of its failure modes can be priced. That is the honest statement here, and it
is why this row goes to step 6 rather than to a developer.

**How you verify any change here**

```
forge test --match-path repro/NM-003-emissions-empty-pool.fork.t.sol
```

8 of 8 green today, including `test_NM003_capture_oneWeiTakesTheEntireTranche`, with two named
resolution controls.

**Prior art in your own repository.** `testH1_TrancheZeroBurnsFromDeploymentBlock` and
`testH2_BurnRecursWheneverStakedSupplyHitsZero` already assert this, and both pass at this commit.
We re-ran your ten `NemesisPoC4` tests ourselves at the locked commit — 10 passed, 0 failed — in a
tree whose nine client test files and entire `src/` are sha256-identical to the audited bytes.
`testH2` also asserts the permanent, structural form rather than a launch-window one, which is the
correct framing. **What this review adds is the reproduction against a live market, and the capture
— your tests assert the burn.**

---

## HIGH-4 — the DAO's entire designed revenue stream is zero, and no party to the launch can raise it

**Severity:** HIGH · **Confidence:** high for the mechanism, **medium for the magnitude** ·
**Status:** **proven by execution** · **Work item:** W15

**Location** — `RevenueRouter.sol:68` (`distribute()`). The defect is the **absence** of a
passthrough to the Lender's `setLocalReserveFeeBps`: `grep -n "setLocalReserveFeeBps" src/` returns
nothing, and `IMonolithLender` (`IMonolith.sol:30-38`) declares eight functions, none of them it.

**Description.** The invariant that breaks is: *a system that exists to route a fee must be able to
reach the fee.* `StakedGovToken` exists to distribute Coin revenue to stakers and `RevenueRouter`
exists to route it; the lever that creates that revenue sits on the dependency, and the router
exposes no path to it. There is no post-deployment repair: the router is not upgradeable, `treasury`
is written once inside `initialize` at `:57` with **no setter at any privilege level**
(`grep -rn setTreasury src script test` → 0 hits; positive control:
`grep -n treasury src/RevenueRouter.sol` → 11 hits, none of them a setter), and the operator role is
deliberately frozen.

**⭐ Your NatSpec at `RevenueRouter.sol:12-15` states that freeze, and this finding engages with it
rather than contradicting it:**

```solidity
/// @dev This contract is intentionally the permanent operator of its paired Lender. It deliberately
/// does not expose a call to `setPendingOperator`, so neither its owner nor the timelock can migrate
/// the operator role after deployment. Governance retains only the manager and revenue-split controls.
```

The freeze is deliberate and we are not arguing with it. The case the comment does not cover is that
the two things governance *does* retain — the manager and the revenue split — do not include the one
lever that makes the revenue exist. The freeze is what turns that omission from fixable into
permanent.

**⛔ The permitted statement, and it is stronger than a hedge.** At block 25,884,025, on both live
lenders, no party to the launch — previous operator, manager, timelock, Governor, launcher,
stranger, or the Monolith Factory itself — can raise the fee, and the `RevenueRouter`'s deployed
bytecode contains no selector that could. **This review makes no claim about a future change to
Monolith.**

**Trigger.** None needed. It is the shipped state.

**Impact.** Permanent brick of the entire designed value flow. ⚠️ **The magnitude carries a
mandatory market-state qualifier:** in the state the design targets (`totalStaked >= totalPaidDebt`)
thirty days of local reserves at `feeBps = 0` are **0 wei exactly**; on the live lender we probed
they are **≈ 7.74–7.75 COIN** — a range, not a point, because three of our own executed measurements
of that quantity, taken in differing measurement windows, span **0.012587 COIN** — a disagreement in
the *second* decimal — and the fee lever is worth **+7.6 %**. State the market condition, or the
claim is refutable against our own measurements.

**Why HIGH.** The grade rests on the **structural** loss, not on any measured amount: 100 % of a
CoinDAO's designed revenue path, permanently unreachable after launch, on a non-upgradeable router
whose `treasury` has no setter at any privilege level. That is a brick in the sense our scale uses.
⚠️ Confidence in the *magnitude* is medium and is reported separately; it does not change the grade.

**What would disprove this finding.** Any caller on any live market raising `feeBps` after a launch;
a selector in the router's deployed bytecode that reaches it; or a market state in which the DAO
earns non-zero revenue at `feeBps = 0` **and the design intends that**. ⭐ The second half has
already half-happened — we measured revenue flowing at zero on a live market — which is why the
magnitude carries a state qualifier and the mechanism does not.

**Suggested change: the passthrough — and it is a client decision, not a shippable step.**

⛔ **Both failure modes priced.** *Prevents:* permanent loss of the DAO's own protocol fee.
*Creates:* a governance-reachable lever up to Monolith's 1000 bps cap, in a system whose genesis
capture has no working fix — so the lever is reachable by the capturing party — **and it activates
the dormant revenue group**. The created mode is sharper than "a lever on a rate": at
`stGOV totalSupply == 0` the entire proceeds route to `treasury`, that is to the timelock, which
`HIGH-1` and `HIGH-3` together put 1.728 days from being the launcher's. ⚠️ It also breaks the
compilation of its own reproduction file until that file's control declares `override`.

⛔ **And the sentence this entry owes you: one member of the group it activates cannot be fixed.**
`MED-5` — a change to the revenue split re-prices revenue that has **already** accrued, because the
split is read at harvest time and applied to an unattributed backlog — has exactly one proposed fix
in this review, and that fix is **killed**: defeated for the price of gas by donating one wei of Coin
to the router. Measured: `setGovStakingBps` then reverts, while your 65 tests stay fully green under
the change, so the denial of service is invisible to the suite. So turning the fee on is **not a
scheduling decision.** It is a choice between **a DAO with no revenue** and **a DAO whose accrued
revenue can be re-priced, permanently, with no fix available today.** ⭐ That choice is yours and
this review does not make it for you.

⚠️ Under the minimum-evidence rule, this change is a **HYPOTHESIS**, because it is sound only
alongside a fix that does not exist.

**How you verify any change here**

```
forge test --match-path repro/PASHOV-03-lender-feebps-unreachable.fork.t.sol
```

7 of 7 green today, including an executed bytecode absence scan, with
`test_P3_control_theSetterWorksFromTheRealOperator` as the resolution.

---

## Medium findings, by work item

Every entry below is **proven by execution** at block 25,884,025 except `MED-13`, which is marked
and says why. Where a row carries a condition, the condition is in the row and not in a footnote.

### W2 — the governance system can rewrite its own constitution, and nothing outside it can intervene

Phase 3 grants `PROPOSER_ROLE` and `CANCELLER_ROLE` to the Governor and then renounces
`DEFAULT_ADMIN_ROLE`; the timelock is deployed with `executors = [address(0)]`, so execution is
permissionless. Four rows share that one decision.

**MED-1 — `PROPOSER_ROLE` is not a subordinate permission; the grantee evicts the Governor**
· MEDIUM · CONDITIONAL · confidence medium · proven by execution

*Where:* `TimelockController.grantRole`, reachable by one passed proposal; launch phase 3.
*What happens:* after such a grant the grantee schedules and executes while holding **zero votes**,
and an honest 500,000-GOV holder's `queue()` reverts. The Governor is permanently evicted and 28 %
of supply is stranded behind it. *Why in scope:* the documented capability list for the post-launch
DAO is a closed list — owns `RevenueRouter`, sets `govStakingBps`, rotates the Lender `manager`,
treasury vesting recipient. Granting `PROPOSER_ROLE` is not on it. *Disproof:* a subordination check
in the vendored `TimelockController` at this version, or a path by which the Governor recovers the
role after losing it. **⛔ No fix was proposed by anyone**, and we re-ran the search with a control:
a grep for fix language against this role across all our own artifacts returns nothing, while the
identical pipeline over `quorum` and `renounceOwnership` returns fix lines. This is tabled as
unremediated, with that absence stated rather than left implicit.

**MED-2 — no address can cancel a queued operation; the canceller role is unreachable**
· MEDIUM · confidence high · proven by execution

*Where:* Governor / timelock role wiring, phase 3. *What happens:* `hasRole(CANCELLER_ROLE, x)` is
true only for the Governor, and the two preconditions are mutually exclusive — `_validateCancel`
requires `Pending`, while the timelock leg is touched only once queued. So the role is unreachable
*period*, not merely once queued, and an irreversible captured proposal executes with no possible
interruption. *Disproof:* any address holding the canceller role, or a state in which both
preconditions hold at once. *Fix:* this is step 1 of the order and it is an **open design problem** —
see the guardian table at the top of this report. Granting the role to a factory-wide party flips the
invariant green and recreates `MED-12` inside itself; your suite stays 65/65 the whole time.
*Verify:* `repro/PASHOV-05-uncancellable-timelock.fork.t.sol`, 3 of 3 green today, with
`test_P5_control_invariantRestored_aGuardianStopsIt` as the resolution.

**MED-8 — `quorumDenominator()` returns `1_000` and the base class bounds only the upper edge**
· MEDIUM · confidence medium · proven by execution

*Where:* `CoinDAOGovernor.sol:68`, reached by `updateQuorumNumerator`. *What happens:* one proposal
reaches a terminal governance state from which the escape needs a proposal that can no longer be
created. *Disproof:* a lower bound in the OpenZeppelin version actually vendored, or a recovery path
after the setting. *Fix:* **killed twice.** `require(newQuorumNumerator <= 200)` does not compile and
does not touch the tally; the same clause at 500 is killed by the same disproof one number apart —
at 85 % undelegated, maximum turnout is 150,000 against a quorum of 500,000. ⭐ And your own
Governor test documents that numerators up to 1000 are intended, so a ceiling here is a product
change rather than a repair.

**MED-9 — five inherited governance parameters are unbounded and undocumented**
· MEDIUM (+ descoped half, see Appendix B) · confidence medium · proven by execution

*Where:* the `GovernorSettings` and `GovernorVotesQuorumFraction` base classes; overridden nowhere
in `src/`. The DAO's *right* to set its own parameters is documented and is in Appendix B; the
**absence of any floor or ceiling** on five of them is documented nowhere, and that is this row.
*Disproof:* a bound in the vendored base classes at the version actually compiled. *Fix:*
**HYPOTHESIS.** A bounds change compiles and your suite stays 65/65 — ⛔ and the suite has **zero
resolution** on it, so the green tells you nothing. ⚠️ Every specific bound that appeared during
this review was our own arbitrary placeholder, explicitly labelled as such. **The numbers are Q-2,
not a recommendation.**

### W3 — three bases, one vote

**MED-15 — the quorum counts undelegated stake that the tally cannot use**
· MEDIUM · confidence high · proven by execution

*Where:* `StakedGovToken` delegation against `CoinDAOGovernor.quorum`. *What happens, and this is
control-inverting rather than merely quantitative:* with 4,500,000 of honest stake **undelegated**
the capturing proposal **Succeeded**; the *same* stake **delegated**, it was **Defeated**. The
quorum was cleared 100× in both runs — **it was never the binding constraint.** The delegated
against-vote is the only working brake in the system, and the design pays people to stake without
delegating. *Disproof:* a quorum base restricted to delegated supply, or evidence that default
delegation is on. *Fix:* **killed.** Both candidates aim at the numerator and neither touches the
tally; a ceiling would have to sit below the DAO's delegation rate, which is unknown at deployment
and drifts. *Prior art in your repository:* `testH7_QuorumCountsUndelegatedSupplyThatCannotVote` —
your test is the finding.

### W5 — the funder computes a tranche from a live balance and duplicates the four-year schedule

**MED-11 — the balance sweep sits inside the last tranche instead of a tranche of its own**
· MEDIUM · confidence medium (single methodology on one leg) · proven by execution

*Where:* `StakingRewardsFunder.sol:90-95`. At `:92`,
`if (tranche < TRANCHE_COUNT - 1) return (rewards * trancheBps(tranche)) / BPS;` — so the final
tranche returns `rewardsToken.balanceOf(address(this))`, a **live balance, not a schedule**. And
`:79-80` therefore compares two reads of the same value on that branch.

⭐ **Your comment at `:93` is why this is a design rather than an accident, and the finding is what
the design has outgrown.** It reads *"The final tranche sweeps any reward dust left after the fixed
tranches."* We agree a sweep has to exist: `3_250 + 2_750 + 2_250 + 1_750 = 10_000` bps, so integer
division leaves a residue and something must collect it. **The case the comment does not cover is
that the sweep does not *top up* the final tranche — it *replaces* it.** `_trancheAmount(3)` never
evaluates `rewards × 1_750 / 10_000` at all; it returns the whole held balance. So the mechanism
collects whatever happens to be present rather than dust, it does so in a **public view** anyone can
read before the tranche is funded, and it has an absorbing state that a dust sweep cannot reach.
*What happens:* **in the state the launch itself leaves behind — immediately after tranche 0 is
funded —** the last tranche's public view reports **3.86× its scheduled share** (`4,387,500 /
1,137,500`), because it returns whatever the funder happens to hold rather than `rewards × 1_750 /
10_000`; read in that same state the four views sum to **9,750,000** (`2,112,500 + 1,787,500 +
1,462,500 + 4,387,500`) against a **6,500,000** programme. There is also a measured absorbing state
(3,163,184.93 + 3,336,815.07 GOV sunk). *Disproof:* a schedule-based reader of the last tranche, or
a demonstration that the absorbing state is unreachable. *Fix:* **HYPOTHESIS, and the best-value
untested candidate in the funder** — moving the sweep into a tranche of its own would close the
absorbing state and the overstatement in one change. **Nobody has compiled it.** ⚠️ Confidence note
we owe you: this row's second methodology leg does not survive scrutiny — the two contributors on
record were both exposed to a document naming this exact surface — so treat it as
single-methodology. That is a doubt, not a disproof; the row stands.

### W6 — `StakedGovToken` attributes a whole notification to the supply present at that instant

⛔ **`MED-5` is in this group by root cause but is a different edit, in a different contract, and its
only proposed fix is killed. Finishing the rest of this group does not finish it.**

**MED-5 — the split is read at harvest time and applied to an unattributed backlog**
· MEDIUM · CONDITIONAL · confidence medium · proven by execution

*Where:* `RevenueRouter.sol:68-75` — `distribute()` is `external`, unguarded, and reads the whole
accumulated balance and the split at call time — against `:88` (`setGovStakingBps`, `onlyOwner`).
*Why this is not simply a documented admin action:* an **unprivileged amplifier** exists.
`Governor.execute()` is permissionless because `executors[0] == address(0)`
(`CoinDAOFactory.sol:373-374`), so raising the bps and sweeping bundle **atomically** in one
transaction. That is a retroactive sweep, and it is what puts the row in scope rather than in
Appendix B. *Condition, with the market state named:* on the live lender we probed, revenue accrues
at `feeBps = 0`, so a backlog exists to sweep today; in the state the design targets the backlog is
0 wei until the fee passthrough ships. *Disproof:* a guard stopping a bps change from applying to
already-accrued value. *Fix:* ⛔ **killed** — the proposed guard (revert while unsettled revenue
exists) is defeated by donating **1 wei** of Coin to the router, which blocks the DAO's only revenue
lever indefinitely for the price of gas. Under that change your suite stays 65/65 while the denial of
service is live.

**MED-6 — a whole notification accrues to the supply present at that instant, with no time
weighting** · MEDIUM · CONDITIONAL · confidence medium · proven by execution

*Where:* `StakedGovToken.notifyRewardAmount`. *What happens:* 1 wei of stGOV claims **100.0000 %** of
a notification at 1, 7 and 30 days. *Disproof:* a time-weighted accumulator, or a demonstration that
a 1-wei holder's share is bounded. *Fix:* **none proposed** — tabled as unremediated.
⭐ **Read this row against the verified negative below:** the just-in-time *deposit* defence works,
and works on both entry paths. This row is about how a notification is divided among those already
present, not about a late entrant diluting them.

**MED-16 — exits forfeit un-harvested revenue, and the partial exit silently re-prices the exiter**
· MEDIUM (partial) / LOW (full) · confidence high · proven by execution

*Where:* `StakedGovToken.withdrawTo` (`:113-121`) carries `updateReward(msg.sender)` but not
`harvestYield`; `harvestAndWithdraw` (`:130`) carries both.

⭐ **Your comment at `:127-129` is the reason the split matters, and the finding is the half it does
not cover:**

```solidity
/// @notice Harvests pending revenue, withdraws the caller's full stake, and pays their rewards.
/// @dev This function reverts atomically if harvesting, withdrawing, or paying rewards fails.
/// Use `withdraw` to recover the underlying GOV without harvesting or claiming rewards.
```

That comment documents the **full** exit: two doors, the choice is the staker's, and the alternative
is one function away in the same ABI. We agree, and the full-exit half is graded LOW and sits in
Appendix B as a foot-gun. **The partial withdrawal is worse in kind and the comment does not reach
it.** It does not remove the exiter; it silently **re-prices** her at a lower weight — measured
33.33 / 66.67 where the entitlement was 50/50, against a harvest-first control that gives 50/50 —
and **no *atomic* harvesting partial exit exists anywhere in the ABI.** There is an alternative, but
it is a *sequence* rather than a door: call `harvestAndGetReward()` (`:153`) first, then
`withdrawTo`. Nothing in the ABI and nothing in your comments tells the staker that the order
decides her price — which is exactly what separates this from `D-6`, where the alternative is one
named function away and the comment at `:127-129` names it. A surplus leak against an actor who did
nothing wrong and was never told the order mattered is not a foot-gun.

*Disproof:* a harvesting partial-exit entry point in the ABI, or a demonstration that the re-pricing
is bounded by the exiter's own share. *Fix:* **none proposed.** ⚠️ And one direction we considered
and rejected **ourselves**, so you have it: adding the harvest to `withdrawTo` would destroy the
anti-just-in-time property that is this design's strongest correct behaviour. That is our own
analysis, not a comment in your code, and it is why this row is tabled rather than patched.

*Prior art in your repository:* `testH3_BackRunningAWithdrawalCapturesTheWithdrawersRevenue` and
`testH4_LastStakerExitDivertsPendingRevenueToTreasury`.

### W7 — the attach path re-implements a subset of `deploy()`'s validation

**MED-3 — the attach path never reads, validates or replaces the incumbent `manager`**
· MEDIUM · confidence high · proven by execution

*Where:* `CoinDAOFactory.deployForExistingCoin`, `:315-346`. It writes `deployment.lender`, `.coin`
and `.vault`, and never touches `manager`. *What happens:* an actor the DAO did not choose keeps
four `onlyOperatorOrManager` economic setters on a market presented as DAO-controlled, and the DAO's
own displacement path (`RevenueRouter.setManager`, `onlyOwner` at `:94`) needs a **passed proposal**.
Read from your constants, the binding interval is **≈ 9.7 days**: 1.728 days before a proposal can
be created, plus `7_200 + 36_000 = 43,200` blocks of voting at 12 s = 6.0 days, plus
`DEFAULT_TIMELOCK_DELAY = 2 days`.

⚠️ **The severity does not rest on that interval** — the defect is that an actor the DAO did not
choose holds the setters; the interval only sets how long the DAO cannot *begin* to displace him.

> ⛔ **A cap on this exists and it is real, but it must be stated in three parts or it is wrong.**
> (1) `setHalfLife`, `setTargetFreeDebtRatio`, `setRedeemFeeBps` and `setMaxBorrowDeltaBps` all do
> revert `Deadline passed` after the market's immutability deadline — verified on live markets.
> (2) ⛔ **`setManager` carries no deadline check and succeeds after it.** So the inherited manager's
> *economic* control expires; **the power to hand the role onward does not**, and after the deadline
> the DAO's only remaining Lender power is the power to give that role away. (3) The bound is
> market-chosen, not a constant: measured **3.64 years** on one live market and **238 days** on the
> other, a 5.6× spread across the only two that exist — and on the `deploy()` path the untrusted
> launcher chooses it, via `timeUntilImmutability` in `DeployParams`. The correct sentence is:
> *four of five inherited manager powers expire at a deployer-chosen deadline between 238 days and
> 3.64 years; the fifth — reassigning the role — does not expire at all.*

*Disproof:* a read or write of `manager` on the attach path; or a demonstration that the incumbent
cannot call those four setters before the deadline. *Fix:* **ship with amendment — and it is
uncompiled in its amended form.** The eviction is durable on the live lender at level 4. ⛔ It has to
be a **replacement signature, not an overload** — as an overload the old three-argument entry point
stays reachable and it fixes nothing. That breaks **7 call sites, and all seven are in your test
tree** (six in `test/CoinDAOFactory.t.sol`, one in `test/helpers/CoinDAOTestBase.sol`); the
production tree and the deploy scripts contain none. **Both failure modes:** it *creates* a transfer
of the capability, not its removal — the launcher now names the manager, and the launcher who
captures governance also names the manager. Priced qualitatively, not measured. ⚠️ And its stated
*benefit* had to be re-argued this round, for two separate reasons that must not be read as one. The
original benefit clause priced the eviction window at **~73 days** where the binding interval is
**1.728 days** — `6,307,200 s / 149,283 s = 42×`, the largest single correction this review made.
And **separately**, on the branch where a `deployerRecipient` **is** named the window is **zero**,
verified by a passing control. **Re-argue it before shipping it; do not re-quote the old argument.**
*Verify:* `repro/remediation/RT9B2.fork.t.sol --match-test
test_RT9B_M6a_managerArgumentEvictsTheIncumbent` (the lender's manager is the DAO's nominee and the
evicted incumbent's `setManager` reverts), and `repro/boundary/BOUNDARY-C.fork.t.sol --match-test
test_C7_setManagerSurvivesTheImmutabilityDeadline` plus
`test_C7_managerEconomicPowersExpireAtTheDeadline` must be **unchanged**.

### W8 — the predictor is a second implementation of the launch, and it has drifted

**MED-10 — the predictor's contract set diverges from what `_deployCoinDAO` builds**
· MEDIUM · confidence high · proven by execution

*Where:* `CoinDAOFactory.sol:245` assigns `predicted.deployerVesting` **unconditionally**, against
`:473`, where the deployment site is inside `if (allocation.deployerVesting != 0) {`. Both sites read
directly. *What happens:* a third party acting on the advertised addresses sends value to a contract
that never receives code, and the deployment key is permanently consumed, so nothing can ever be
deployed there. Two further cases: the predictor **skips `_validate` entirely**, and on an already
spent key it returns **nine live addresses belonging to a different launch**. *Disproof:* a
conditional in the predictor matching `:473`, or a consumer that re-checks `code.length` before
sending. *Fix:* ⛔ **HYPOTHESIS, and it must not ship alone.** Returning `address(0)` for a wallet
the launch will not build is executed and flips your own `testH8` to failing, which is the right kind
of evidence — but on a **spent** key that same guard returns `address(0)` for a **live wallet holding
2,000,000 GOV**, and the `code.length` re-check this finding names as its own disproof then confirms
the error instead of catching it. We verified that twice, independently, one of them by applying the
change to the source and restoring it. The companion repair for the spent-key case **has never been
written**, so under the minimum-evidence rule the pair is a hypothesis.
*Prior art in your repository:* `testH8_PredictionReturnsADeployerVestingThatIsNeverDeployed`.

### W9 — a mutable global stamped into an immutable binding, and movers that move one binding of many

**MED-13 — `updateTimelock` moves one of six bindings; `treasury` is write-once**
· MEDIUM · CONDITIONAL · confidence high · ⛔ **arithmetic and read only — not proven by execution**

*Where:* `RevenueRouter.sol:57` — `treasury = treasury_;` — the **single** write. Greps, with their
controls: `setTreasury` → **0 hits** across `src/`, `script/` and `test/`; `treasury` → 11 hits in
that one file, so the pattern has resolution. *What happens:* a passed `updateTimelock` proposal
reaches a state in which **100 % of the treasury share pays an abandoned address forever**, with no
setter at any privilege level. `Governor.relay` recovers every *other* orphan, but only if the
destination timelock granted the Governor `PROPOSER_ROLE`. *Condition:* unconditional for the
mechanism; the *amount* depends on the market state, because the treasury share is zero at the
shipped default — see `MED-17`. ⛔ **Stated plainly: this finding has no exploit reproduction.** The
*fix* is executed; the finding is arithmetic and read only. That is the fix's gap, not the finding's,
and it is why the row says so. *Disproof:* any setter reaching `treasury`, or a `relay` path that
reaches it. *Fix:* ✅ **ship — one of the two entries on the ship list** — a `setTreasury` **with**
its zero-address check, paired with the renounce-only pins of `MED-18`, as **one** change. Level 3
partial: the naive version's own kill now reverts `ZeroAddress()`, so the brick is closed; we can show
the change does not brick, we **cannot** show it completes a migration. *Creates:* a new `onlyOwner`
lever on the destination of the treasury share, reachable by one proposal — it hands a captured
governance the ability to redirect the treasury stream. Unpriced in magnitude, and deliberately not
guessed. ⚠️ One neighbouring idea was already **killed** earlier in this review, by execution: a
batched procedure that moves the timelock and re-points everything at the new one. It migrates
everything **except** `treasury`, which is the one binding with no mover at any privilege level, so
100 % of the treasury share keeps paying the abandoned address afterwards. It is recorded as dead
rather than left available.

**MED-12 — a mutable global is stamped into an immutable per-deployment owner**
· MEDIUM (+ descoped half, Appendix B) · confidence high · proven by execution

*Where:* `CoinDAOFactory.sol:470` —
`monolithVesting.initialize(monolithBeneficiary, vestingStart, FOUR_YEARS);` — reads the global at
launch time, per deployment. *What is descoped:* the rotation right itself, which is documented.
*What is not:* that rotation binds only **future** launches. After five launches and a rotation,
1,000,000 GOV of already-stamped wallets keeps the old beneficiary as owner forever, and **there is
no migration path for a compromised key** — precisely the case a two-step rotation exists to handle.
⚠️ That figure is **earned entitlement, not loss**; it must not be read as a drain. The defect is the
absence of a migration. *Disproof:* a migration path for already-stamped wallets, or a beneficiary
read at release time rather than at launch time. *Fix:* ⛔ **none that works.** Two candidates exist —
letting the incumbent clear a pending nomination, and hoisting the global into a local in phase 1 —
and **neither fixes it**; the second is strictly a read hoist and already-stamped wallets keep the old
owner either way. Effectively unremediated.

**MED-18 — `renounceOwnership` and single-step `transferOwnership` are exposed on the permanent
operator** · MEDIUM · confidence high · proven by execution · *also in W10*

*Where:* `RevenueRouter.sol:18` — `contract RevenueRouter is OwnableUpgradeable, IRevenueDistributor`
— so both are inherited and `onlyOwner`, which after `CoinDAOFactory.sol:454` is the timelock.
`grep -n "renounceOwnership" src/RevenueRouter.sol` → **no matches**, i.e. no override; control: the
same pattern returns `src/CoinDAOFactory.sol:488`, so it finds overrides and calls where they exist.

⭐ **Your NatSpec at `RevenueRouter.sol:12-15` states the stakes better than we could**: the contract
is intentionally the permanent operator and deliberately exposes no `setPendingOperator`. That
deliberate freeze is exactly what makes losing the owner unrecoverable — one passed proposal,
malicious or mis-encoded, permanently removes `setGovStakingBps` (`:88`) and `setManager` (`:94`),
the DAO's **only** remaining levers over that lender. *Why in scope rather than in Appendix B:*
**owning** the router is documented; **destroying the ownership** is not. *Disproof:* an override on
the router, or a recovery path after renunciation. *Fix:* ✅ **ship, paired with `MED-13`** — override
`renounceOwnership` **only**, on both the router and the vesting wallets. Verified in both
directions at level 4: the brick closes, and `treasuryVesting.transferOwnership(...)` still works, so
`MED-13`'s only recovery path survives. ⛔ Overriding **both** is **killed** — it destroys that
recovery path.

### W10 — vesting constrains when tokens leave, never who owns the wallet

**MED-4 — vesting constrains *when* tokens leave, not *who owns the wallet***
· MEDIUM (brick half) + descoped half (Appendix B) · confidence high · proven by execution

*Where:* `CoinDAOVestingWallet` — ten lines, `is VestingWalletUpgradeable` with no overrides, so it
carries `OwnableUpgradeable` and its owner holds the whole ownership surface. *What is descoped:*
the DAO changing its own treasury vesting recipient, which is documented. *What is not:*
`renounceOwnership()` sets the owner to `address(0)`, after which `release()` can never be called
again. Destroying the wallet is not a documented capability.

⚠️ **Three quantities have been travelling together in our own drafts and we separate them here so
you are not handed a wrong one:** the treasury vest holds **2,800,000 GOV** at `t = 0`; its
**unvested remainder at day 30 is 2,742,465 GOV**; and it releases **1,917.81 GOV per day**
(`2,800,000 / 1,460`). The **48× amplification at day 30** is the scale-independent fact worth
carrying: `transferOwnership` moves the whole unvested remainder in one call, against 30 days of
linear release.

⛔ **This applies to all three vesting wallets**, not only the treasury one, for the general reason:
renouncing ownership of a vesting wallet makes `release()` revert forever, whoever the owner is.
*Disproof:* an override of either function, or a recovery path after renunciation. *Fix:* ✅ the
renounce-only pin of `MED-18` closes the **brick** — ⛔ **and it must not be presented as closing this
finding.** `transferOwnership` still sells the unvested remainder, and **no pass in this review has
written a fix for that half.** The natural successor — permit the transfer but force a release to the
outgoing owner first — has never been written by anyone.

### W11 — voting weight is a per-block checkpoint on a token with free entry and exit

**MED-14 — voting weight need only be held at two block heights, not through the cycle**
· MEDIUM · confidence high · proven by execution

*Where:* `StakedGovToken.withdrawTo` against the `ERC20Votes` checkpoints. *What happens:* 400,000
GOV borrowed, staked in the publicly-known snapshot block, unwound the next block — **a proposal was
defeated while the attacker held zero of either token.** A governance outcome is purchasable for one
block's rental cost. ⛔ **Read the scope of this precisely:** the *within-one-block* version of this
claim is **refuted** — the checkpoints collapse per block and a round trip inside one block yields
zero votes, and we have a held-block control that shows it. The **cross-block** form is a different
claim, and it is the one that stands. *Disproof:* an unbonding period, or a snapshot that samples
across the voting window rather than at one height. *Fix:* **none proposed.** The cure is an
unbonding period, which changes the product. Tabled.

### W13 — `deploy()` forwards caller-supplied `DeployParams` with only two fields overridden

**MED-7 — the only mint path for voting power is hard-coupled to an uncaught external call**
· MEDIUM · confidence high · proven by execution

*Where:* `StakedGovToken.sol:81-84` (`modifier harvestYield() { revenueRouter.distribute(); _; }`)
and `:102-110` (`depositFor(...) nonReentrant harvestYield updateReward(account)`). ⭐ **The trigger
is not in this file.** It is `psmVault`, a `DeployParams` field the factory never reads — which is
why this row belongs with `LOW-5`, and why the edit that closes it is in
`CoinDAOFactory.sol` rather than `StakedGovToken.sol`. *What happens:* a launcher-chosen `psmVault`
that satisfies the Lender constructor's two checks
and then reverts on `balanceOf` makes every `depositFor` revert, while `withdrawTo` still works and
drains stGOV supply toward zero. **Entry to the electorate becomes permanently closable, incumbents
keep their votes, and challengers cannot enter.** *Disproof:* a `try/catch` on the harvest, a
`psmVault` validation, or a second mint path for voting power that does not run `harvestYield`.
*Fix:* ⛔ **killed — and it is the only killed fix in this review that demonstrably closes its own
finding.** Wrapping the harvest in `try/catch` closes the freeze at level 4 **and opens a 99.67 %
just-in-time capture window** for as long as the Lender is down, which is a publicly observable
condition: of 100,000 COIN accrued before the entrant existed, the entrant took 99,667.77 and the
incumbent who earned it kept 332.23. Your suite went 63 pass / 2 fail under that change. ⚠️ The
counter-risk as originally written called the dilution *"bounded, transient and self-correcting on
the next successful harvest"*; measured, it is 99.67 % of the pot, permanent, and **realised** by the
next harvest rather than undone by it. ⭐ **One fix closes this row and `LOW-5` together, and it is
in a third file:** validating the `DeployParams` the factory forwards.

*Prior art in your repository:* `testH5_DistributeFailureFreezesTheElectorate`.

### W15 — the dependency's revenue lever is unreachable after launch

**MED-17 — the treasury receives no revenue at the shipped default**
· MEDIUM · confidence high · proven by execution

*Where:* `CoinDAOFactory.sol:31` (`DEFAULT_GOV_STAKING_BPS = 10_000`), passed at `:409` into
`revenueRouter.initialize(...)`, consumed at `RevenueRouter.sol:71-75`:

```solidity
uint256 amount = coin.balanceOf(address(this));
if (govStaking.totalSupply() != 0) {
    govStakingAmount = (amount * govStakingBps) / MAX_BPS;
}
treasuryAmount = amount - govStakingAmount;
```

At 10,000 bps with a non-zero staked supply the treasury receives **exactly nothing**. ⛔ **And the
switch is the staked supply, not the bps** — do not read the two clauses as complements. Measured on
1,000 COIN distributed, all four states: at the shipped 10,000 bps with zero staked supply the
treasury takes **all** 1,000; at 10,000 bps with a non-zero supply it takes **0**; at 5,000 bps with
zero supply it takes 1,000; at 5,000 bps with a non-zero supply **both** clauses are live on the same
money, 500 each. The split has **two** inputs.

*What happens:* one of the system's two designed revenue recipients receives zero at the shipped
default, and the only party who can change it (`setGovStakingBps`, `onlyOwner`) cannot be constituted
until a full governance cycle completes — **≈ 9.7 days**. ⭐ **The defect is the default, not the
window.** *Condition, with the market state named:* on the live lender we probed the exposure is live
now and all of it goes to stakers; in the state the design targets it is zero until the fee
passthrough ships. *Disproof:* a path by which the treasury is paid at 10,000 bps. *Fix:* **none
proposed.** ⭐ And the shape of the problem is worth naming, because it decides whether a fix is even
a governance question: the only party who can change this setting is the stakers, voting to cut their
own income.

### W17 — the deploy script's env handling defaults silently and its preflight gate cannot fail

**MED-19 — all 13 `vm.envOr` reads fall back silently and every default passes every check; the
preflight gate cannot fail;
verification runs after `stopBroadcast`** · MEDIUM · confidence medium (**single methodology**) ·
proven by execution · *also in W1*

*Where:* `script/DeployCoinDAO.s.sol`, which reads **15 distinct environment variables across 16
call sites** (`STALENESS_THRESHOLD` twice, at `:125` and `:217`). **Two have no default and revert
if unset** — `PRIVATE_KEY` (`:47`) and `COIN_DAO_FACTORY` (`:48`). **The remaining 13 use
`vm.envOr`** (e.g. `:80`, `vm.envOr("DEPLOYER_STAKE_BPS", uint256(0))`), and **every one of those 13
defaults satisfies every `require` in the file** — executed: `defaultMonolithParams()` and
`defaultGovParams()` both return without reverting, against a control in which an out-of-range value
*does* revert. So a variable whose **name** is misspelt is caught by nothing at all, and only
`STAKING_TOKEN` rejects a wrong *value* outright (`:105`). Also `_preflightImplementations`, and
`_verifyDeployment` running after `stopBroadcast`. *What happens:* a misspelt `COLLATERAL_FACTOR`
launches a market at 50 % without a word in the log; and a factory whose six "implementations" were
six unrelated ERC20s was **accepted** by the preflight. This is operator tooling rather than
deployed bytecode, which is exactly what holds it at Medium rather than higher. ⚠️ **It has no
independent corroboration** — one of our two methodologies had `script/` excluded from its brief by
a line in our own scope document. That is our limitation and it is disclosed rather than papered
over. *Disproof:* a preflight assertion that can fail, or a verification step inside the broadcast.
*Fix:* **none proposed.**

⚠️ **Its allocation-predicate half is the same defect as `HIGH-1`, in a second place.** That is why
this row appears in two work items and why fixing the script does not fix the factory.

---

## Low and informational findings

Rows whose measured harm is dust are in **Appendix D** with their measurements; the rest are here.
All are proven by execution except where the *E* column says otherwise (**A** = arithmetic or code
read only, with the reason).

| # | claim | where | sev | E | disproof condition | fix status |
|---|---|---|---|---|---|---|
| `LOW-1` | two floor divisions in series with no residual carry | `StakedGovToken.notifyRewardAmount` + `RevenueRouter.distribute` | LOW · COND | 4 | a residual carry, or a decimals constraint in `src/` | ⛔ correctly **not shipped** — the candidate adds a worse pair. Appendix D |
| `LOW-2` | `updateReward` runs before a guard the caller passes trivially | `StakingRewards.getReward`, `depositFor(x, 0)` | LOW | 4 | a path where a caller with no position changes another's realised reward | ⚠️ hypothesis, against 19 wei. Appendix D |
| `LOW-3` | donated assets are swept at one contract and permanently stranded at the adjacent one | `RevenueRouter.sol:71` vs `StakedGovToken` | LOW | 4 | a sweep path on `StakedGovToken` | ⛔ **killed in effect** — the candidate weakens the router-only guard. Appendix D |
| `LOW-4` | dead approval surface on a non-transferable token; `permit` burns the shared nonce | `StakedGovToken.approve` / `permit` | LOW | 4 | a `transferFrom` path a non-zero allowance enables | ⚠️ hypothesis, *"an option, not a requirement"*. Appendix D |
| `LOW-5` | `deploy()` forwards caller-supplied `DeployParams` with only `.operator` and `.manager` overridden | `CoinDAOFactory.sol:303-307`, `IMonolith.sol:5-24` | descoped + **LOW** residual | **A** | a `_validate` clause reading any `DeployParams` field | ⛔ **none — and the descope became the gap.** No fix was written *because* the row was descoped, and it is the in-corpus trigger for `MED-7`, whose only working fix lives here |
| `LOW-6` | the attach path omits the zero-address checks `deploy()` performs | `CoinDAOFactory.sol:315-346` | LOW | 4 | a downstream consumer that re-derives `vault` | folded into the attach-path rework (`MED-3`) |
| `LOW-7` | two four-year clocks: one an enforced deadline, one only a floor | `CoinDAOFactory.sol:36` vs the funder schedule | LOW | 4 | any code tying the vesting clock to the emission schedule | ⛔ **unremediated.** The candidate was re-filed as a regression guard, not a fix — it asserts an identity that already holds and closes nothing. See Q-3 |
| `LOW-8` | the vendored dependency trees are unpinned by the repository | `foundry.lock`, `.gitmodules` | LOW — carried scope limit | **A** | a pin in either file | build hygiene; no code fix |
| `LOW-9` | reentrancy guard in cloned contracts — **verdict SOUND**, with a residual dependency | the three clone targets | LOW residual | 4 | n/a — no defect to fix | n/a. See the note below |
| `LOW-10` | block-count governance timings on a chain-agnostic factory | `CoinDAOGovernor.sol:22-23` | LOW | **A** | a `clock()` / `CLOCK_MODE` override | **none proposed** |
| `LOW-11` | a coupled constant with no reader, against an allocation computed as a residual | `CoinDAOFactory.sol:30` vs `:289` | LOW | 4 | any reader of the constant | ⚠️ hypothesis. See the allocation note in *What we checked and found sound* |
| `LOW-12` | the one irreversible external handoff has no post-condition | `CoinDAOFactory.sol:452-453` | LOW (regraded **down**) | 4 | a reachable state where `acceptOperator` fails silently | **ship, defensive only** — it guards a case nobody has reached |
| `LOW-13` | a fee-on-transfer staking token permanently blocks the last withdrawer | the staking-token choice reaching `StakingRewards` | LOW · COND | 4 | an accounting model reconciling to actual balances | **none proposed.** ⭐ Your own header declares fee-on-transfer and rebasing tokens unsupported, so this is the documented boundary being reachable from a caller-chosen parameter, not a contradiction of it |
| `LOW-14` | the launch script's prediction cross-check is off on exactly the branch where the prediction is wrong | `script/DeployCoinDAO.s.sol:314-316`, `:253`, `:298` | LOW | 4 | a default-branch launch where predicted and deployed agree | source half is `MED-10`'s hypothesis; the script half (deleting two now-redundant checks) is untested. ⚠️ single methodology |
| `INFO-1` | `distribute()` is permissionless with no reentrancy guard | `RevenueRouter.sol:68` | INFO | 4 | a path by which a caller-chosen or hooked token reaches `RevenueRouter.coin` | ⚠️ hypothesis. ⭐ Your contract header declares hooked tokens unsupported in three places; this is hardening, not a live path — and it is recorded because it is `LOW-12`'s premise |
| `INFO-2` | `StakingRewardsFunder.initialize` stores an unvalidated collaborator | `StakingRewardsFunder.sol:45` | INFO | **A** | a second call site, or a reordering | **none proposed.** The factory's ordering makes the live path safe; it is a robustness gap, not a reachable bug |
| `INFO-3` | the leftover-carry branch of `notifyRewardAmount` is unreachable | `StakingRewards.sol:150`+ | INFO — **not a defect** | **A** | n/a | n/a — recorded as an observation, and it must not be inflated |

⭐ **`LOW-9` deserves one sentence in its own right, because the verdict is *sound* and the residual
is narrow.** The reentrancy guard behaves correctly in EIP-1167 clones at the OpenZeppelin version
you vendor, and three attacks on it were refuted. The residual is that the guard is safe on this path
only because its test is against the *entered* sentinel; the base class's own inline comment about
what an uninitialised slot holds is not true on a clone path. There is no defect to fix — but the
behaviour is version-dependent, which is why it is tied to `LOW-8`.

**`LOW-13`'s condition, stated in the row:** the loss requires a staking token that does not transfer
the exact requested amount, and the staking-token choice is the launcher's.

---

## What we checked and found sound

A review that reports only failures is not telling you what it examined. Each of the five below is
paired with the control that could have failed — a check we never observed failing is not evidence.

**1. The just-in-time deposit defence works.** A 300,000-stGOV whale depositing after 100 COIN has
accrued earns **0**; the 1,000-stGOV honest staker keeps all 100. *The control:* it holds on **both**
entry paths, not just the one we happened to test first. ⭐ This is carried onto `MED-6` deliberately,
so that finding cannot be read as "deposits are unprotected".

**2. The eight-phase launch ordering is load-bearing and fails safe.** Five of the eight reorderings
revert immediately, and reordering phase 3 **fails twelve of your own tests**. *The control:* the
reorderings that do *not* revert are the resolution — the check discriminates ordering, not
compilation.

**3. The allocation arithmetic conserves the full ten million tokens** across all five recipients,
with no remainder, on every legal deployer setting and on all five paths.

> ⚠️ **One qualification we owe you, and we have removed the word "exact" from our own claim.**
> Conservation here is an **identity, not a check**: `CoinDAOFactory.sol:289` computes
> `treasuryVested` as the **residual**, under your own comment at `:288` that says so —
> *"Assign all division dust to the vested treasury so the fixed supply is fully allocated."*
> Measured resolution, on **both** weights the code actually reads as numerators — a change of
> **one unit**, which is `1/9_800` of the remainder, or **1.0204 bps**, since the weights are
> denominated in `ALLOCATION_WEIGHT_TOTAL = 9_800` and not in ten thousand:
> `COIN_STAKING_REWARDS_WEIGHT` 6_500 → 6_499 **fails 1 of 65**, and `IMMEDIATE_ALLOCATION_WEIGHT`
> 500 → 499 **fails 1 of 65**. Changing `VESTED_TREASURY_WEIGHT` from 2_800 to 2_799 is
> **invisible — 65 of 65 still pass**, and the reason is stronger than "a weak test": that constant
> has **exactly one reference in the entire codebase, its own declaration** (re-grepped by hand).
> ⛔ The correct claim is therefore: **the two weights the allocation reads are resolved to one
> unit, 1.02 bps; `treasuryVested` is a residual and is not independently checked by anything; and
> the fourth constant is unreferenced and unverifiable by any test.** That constant is `LOW-11`.
>
> ⚠️ We are showing you the second correction to this paragraph. Our first version said "1 bps"
> and "the three weights that are read" — both wrong, and both ours. We are leaving the trail
> visible because a resolution claim you cannot re-run is worth nothing, and these two you can:
> the commands are in the verification table.

**4. Address prediction is safe.** The deployment key namespaces by caller —
`deploymentKey = keccak256(abi.encode(creator, userSalt))` — so the CREATE2 deployer is fixed to the
factory, predicted addresses cannot be squatted, and they survive an unrelated third party launching
in between. *The control:* three separate attacks on it were built and all three are refuted.

**5. The staked-token supply never over-commits, and there is no mint back door** (ABI-verified).

> ⚠️ **And a caution about how we know, because it is the more useful half.** We have replaced our own
> phrase *"provably solvent"* with **"never over-commits"**, because we measured the limit of our own
> instrument. Deleting `updateReward(msg.sender)` from `StakedGovToken.withdrawTo` — *the exact
> coupled-state defect class this review was looking for* — leaves the aggregate fuzz invariant we chose
> to lean on **PASSING over 256 runs**. ⚠️ **That invariant is one of your own tests:**
> `testFuzzH6_StakedGovRewardsStaySolvent`, `test/NemesisPoC4.t.sol:190`. Your
> `testWithdrawnStakeRetainsEarlierButNotLaterRewards` (`test/StakedGovToken.t.sol:106`) **fails
> immediately** on that same mutation (`10e18 != 15e18`). ⭐ **So one of your own tests is blind
> here and another is not — and the instrument we picked to lean on was the blind one.** A fuzz invariant
> over aggregate solvency cannot see a per-account settlement bug; a targeted assertion can. **Cite
> `testWithdrawnStakeRetainsEarlierButNotLaterRewards`, not `testFuzzH6`.**

**6. And we built and verified the vendored dependency.** **64 of 64** OpenZeppelin source files
compiled into the in-scope artifacts are byte-identical to the upstream v5.6.1 release, verified
three ways — build tree, your mirror, and the upstream tag — with a one-character mutation as the
control. ⚠️ They are committed as plain directories with no submodule, tag or lockfile entry, so
nothing in the repository stops them moving after today (`LOW-8`).

---

## One finding we raised and then withdrew

**Both review methodologies independently built an attack premised on the reserve pull being
partial.** It is not: `pullLocalReserves()` mints all accrued reserves and then zeroes the
accumulator, and it early-returns rather than reverting on zero. The premise is false and both forms
of the claim are **refuted**.

We report it for two reasons. First, two independent methods agreeing meant only that neither could
check the premise from inside your repository — convergence between two blind observers is worth
nothing when they are blind in the same place, and this is our own clearest example of it. Second,
you should know which of our claims we killed ourselves. ⭐ **This is one of ten claims we raised and
then killed ourselves;** the other nine are named in the detail of this review, each with the line of
your code, or of the deployed dependency, that disproves it. Two of the ten are about us rather than
about your code: one is two independent methodologies reaching the same wrong root cause on one line,
and one is our own refusal to answer a question we could have answered from a fork and initially
recorded as *"only the client can answer this"*.

---

## How to verify a fix

⭐ **The rule is one line: a fix is verified when the reproduction of the finding it targets STOPS
reproducing — never when an unrelated suite stays green.**

Every reproduction named below ships with this report under `repro/`, and every one of them passes
today **because the defect is present**. When your fix lands, the named test must fail. The file
names are the reproduction file names as shipped, so the commands can be copied as written.
⚠️ Three of the rows below are **local, non-fork** tests and need no endpoint at all:
`repro/refutation/MutRemedies.t.sol`, `repro/refutation/MutConflict.t.sol` and
`repro/composition/MUT-RX31-predictor.t.sol`.

```
# The fork block is pinned INSIDE the reproductions, not on the command line:
# repro/ForkBase.sol:93-95 calls vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), 25_884_025)
# and then asserts block.number == 25_884_025, so a run at any other block fails that assertion.
export MAINNET_RPC_URL=<your endpoint>
forge test --match-path <file> --match-test <test> -vv
```

| the change | run this | what must happen |
|---|---|---|
| **`setTreasury` + the renounce-only pins**, as one change | `--match-path repro/refutation/MutRemedies.t.sol --match-test test_VestingDoesNotLockValue` | **FAILS** with `OwnershipCannotBeRenounced()` — the 2.8M lock-up is closed |
| " | `--match-path repro/refutation/MutConflict.t.sol --match-test test_pinningOwnershipDestroysTheTimelockMigrationPath` | **FAILS** — i.e. `treasuryVesting.transferOwnership(...)` still works. ⛔ If this one **passes**, you pinned both functions and destroyed the only recovery path you have |
| " | `--match-path repro/refutation/MutRemedies.t.sol --match-test test_MUT_NM4_setTreasuryZeroBricksTheElectorate` | **FAILS** with `ZeroAddress()` — the zero-address form of the new setter is refused |
| **the fee passthrough** (only after the decision above) | `--match-path repro/PASHOV-03-lender-feebps-unreachable.fork.t.sol` | `test_P3_afterLaunch_noActorCanEverRaiseTheFee` and `test_P3_evenAPassedProposalCannotRaiseTheFee` both **FAIL** |
| " | `--match-path repro/INVARIANTS-expected-to-fail.fork.t.sol --match-test test_INV4_theDaoCanSetTheLenderFee` | **PASSES** — and the other five invariants **unchanged and still failing**, so exactly one moved. ⚠️ Also expect your own reproduction file to stop compiling until its control declares `override` |
| **the predictor guard** (only together with the spent-key repair) | `--match-path test/NemesisPoC4.t.sol --match-test testH8_PredictionReturnsADeployerVestingThatIsNeverDeployed` (**your own file**) | **FAILS** — your test asserts the defect is present, so when the defect is gone it must stop passing |
| " | `--match-path repro/composition/MUT-RX31-predictor.t.sol` | ⛔ **the guard alone makes this reproduce a *new* defect** — a live wallet holding 2,000,000 GOV reported as `address(0)`. It must not reproduce after the spent-key repair, and that repair does not exist yet |
| **the attach-path signature** | `--match-path repro/remediation/RT9B2.fork.t.sol --match-test test_RT9B_M6a_managerArgumentEvictsTheIncumbent` | the lender's manager is the DAO's nominee, and the evicted incumbent's `setManager` reverts |
| " | `--match-path repro/boundary/BOUNDARY-C.fork.t.sol --match-test test_C7_setManagerSurvivesTheImmutabilityDeadline` and `test_C7_managerEconomicPowersExpireAtTheDeadline` | **unchanged** — the deadline behaviour must not move |
| **a cancel guardian**, if you ever build one | `--match-path repro/PASHOV-05-uncancellable-timelock.fork.t.sol --match-test test_P5_queuedOperationCannotBeCancelledByAnyone` | **FAILS** |
| " | `--match-path repro/INVARIANTS-expected-to-fail.fork.t.sol --match-test test_INV5_aQueuedOperationIsCancellableBySomeone` | **PASSES** |
| " | `--match-path repro/refutation/MutRemedies.t.sol --match-test test_MUT_P5_cancellerGrantIsStampedAndNeverRotates` | ⛔ **must also FAIL** — this is the row nobody has ever been able to run, because no guardian shape that satisfies it has been built |
| **the three unremediated Highs** | `repro/NM-001-…`, `repro/NM-002-…`, `repro/NM-003-…` | all three still reproduce. They are the measurement of what is left |

⚠️ **Two changes have no such gate and we will not pretend otherwise.** The defensive post-condition
on the operator handoff cannot be shown to close anything — there is no reachable state to reproduce,
so the only honest check is that your suite and every reproduction above are unchanged. The
constructor-time clock assertion is compile-time only; its sole check with any resolution is to move
one of the two constants and confirm construction now reverts.

⛔ **And one caution about the six named invariants.** Each is instantaneous and single-finding. With
the allocation bounded *and* the funding call deferred — the strongest combination anyone built —
two of them read **PASS** while the identical capture completed one day later. **An invariant going
green tells you a single defect moved. It does not tell you a composition is closed.**

---

## Leads — unverified, worth your attention

Trails where something looks wrong but no complete attack path was established. These are **not**
findings and carry no severity.

| # | location | what looks wrong | what remains unproven |
|---|---|---|---|
| L-1 | the timelock's own role administration | OpenZeppelin's `TimelockController` grants `DEFAULT_ADMIN_ROLE` to itself in its constructor under its own *"self administration"* comment, so once the factory renounces, the timelock remains its own admin: through a passed proposal it can change its own delay and grant or revoke proposer, canceller and executor for any address. **This power is not on the capability list we were given for the post-launch DAO.** We treated it as implied by *"post-launch DAO"* and therefore did not grade it | whether you intended it. If not, it is a finding rather than a lead — see `MED-1`, which is the same surface at one remove |
| L-2 | `src/interfaces/IMonolith.sol` | the interface is a strict **subset** of the deployed Lender. All ten declared selectors verified; **at least eight further Lender selectors exist that it does not declare**, and we derived nothing about them | whether any of the undeclared selectors is reachable in a way that matters to a CoinDAO. Not examined |
| L-3 | `StakedGovToken.notifyRewardAmount` + `RevenueRouter.distribute` | the truncation residue measured at **0 ppm/year** rests on the Coin having 18 decimals, which we verified on chain for the live market. On a market whose Coin has **8 decimals or fewer**, the same two divisions in series have a different order of magnitude | the escalation is a stated *condition*, not a measurement — we will not claim a result about a market that does not exist |
| L-4 | the cancel guardian, time-bounded shape | a grant that simply expires is the one shape nobody has written. It is outwaited on its face, because the launcher holds 500,000 liquid GOV from the launch block | nothing was built, so neither failure mode can be priced. Recorded so the shape is not rediscovered as though it were new |
| L-5 | `CoinDAOVestingWallet` transfer half | the renounce-only pin closes the brick and leaves `transferOwnership` able to move the entire unvested remainder in one call. The natural successor — permit the transfer but force a release to the outgoing owner first — **has never been written by anyone in this review** | both failure modes of an unwritten change cannot be priced, and we do not price them |

---

## Appendix A — files reviewed

Generated from the scope lock, so this report cannot disagree with the bytes actually reviewed.
Re-checked at the start and the end of every pass: **35 of 35 files match**, no drift.

| file | sha256 |
|---|---|
| `.env.example` | `3c5bb4c961efdf4723408134bd7d42c24818686184b6bb43ee641b494d892be4` |
| `.gitignore` | `c0267a6bb5ec02664e536eab8de433be17b6df0717dd351e2739d046a945e42c` |
| `.gitmodules` | `172e0d1d79e557e903f2d87805acade91d1186b07f54ff9992100d296e2c3117` |
| `foundry.lock` | `29e35181302416466d3d3a56b71493c28554f41af659e9207a1f2ba8769a2d46` |
| `foundry.toml` | `f3462f7e4bb794ea1689dbe6500cc61c6c8162a5d84b0e59612cef32cfefd9a5` |
| `novel_code.md` | `f80c88036ffa340739c13fafd902c6bf86164460b9b7b5967d24f39ad4b44621` |
| `plan.md` | `f20b3e40a327aa9e89fdbe4e9c1bb5466b1cd0545a6bcce0e5c3e6faec5c561c` |
| `remappings.txt` | `9fa91919df8a4d7f28d497011a7df27b9cfbd74244da5457f6be46967f5d4212` |
| `script/DeployCoinDAO.s.sol` | `f65ee6f39034e1283997dca9c4c14e3acfcecf556c74d5bf8bbb27c70be2e3df` |
| `script/DeployCoinDAOFactory.s.sol` | `b109a0add8531203fb25545acdaea1066c7a94e53525e1f5f7b8725d9302113c` |
| `src/CoinDAOFactory.sol` | `9d91d5c6f2032cfb46d814f0df65bef939b5846a32eb46e1d6e1d3a8a20b0daa` |
| `src/CoinDAOGovernor.sol` | `fdc6927618e906f55dce3658d916261a633c7757f86500a7ab72a4c2d5b4f2f2` |
| `src/CoinDAOVestingWallet.sol` | `c9ee916ab6cd147e5a4daae46a00b4dbdac620785a7dce280145642f2a55b0b3` |
| `src/GovToken.sol` | `0902a5d50d66cae1d3ec7878f9be070762fd6b59a28471816bcf283e94408225` |
| `src/RevenueRouter.sol` | `da04fc0e17d719eac0cef01f75d9f74290f2ed98b98df4659fba7cf0c70a4bea` |
| `src/StakedGovToken.sol` | `2793f8bc954f62ae4676d2010047bd038a3a3a0f1702d56bf1695c67e7e23509` |
| `src/StakingRewards.sol` | `e232fac84e71764b704308ab67837182f86b39d0ff26ff4fcbca8bde313ff3e2` |
| `src/StakingRewardsFunder.sol` | `33c1fa5a175b4ef84a7ae7404d57b3adb146538256b65a997782afb6f4d45292` |
| `src/deployment/DeploymentLibraries.sol` | `bc234a1cbe35383986633419ea6219bf5a6f4e76dfaa8e6845c32755a2cd4a04` |
| `src/interfaces/IMonolith.sol` | `b4d9b148ca8c7e8c14577c60db08632e4c0a42485df77aedc06016cb98426627` |
| `src/interfaces/INotifiableRewardReceiver.sol` | `90a41670e9fcbba619ed1871e443e41d84cf4df0f0653b7d70726e655fbf78f2` |
| `src/interfaces/IRevenueDistributor.sol` | `419e239f261ccb3c8401962faa4ed2085e07693f15c77d6599b662332d289f99` |
| `test/CoinDAOFactory.t.sol` | `c3668e3d6ff79b2b6e130d5422ff41e8b6d3b99a362835a95e6ed7557964d9d5` |
| `test/CoinDAOGovernor.t.sol` | `391eba8770fbfc5cd0859b0325ab18a2669286d718925b2635c5338518d26d48` |
| `test/DeploymentScripts.t.sol` | `d9bdb9adbc2eb8b87edfc02a4d3ec12faf5cad8379fd377f5ecc3be5ffccde96` |
| `test/GovToken.t.sol` | `55d6d634c2068b26704573aaa243885ea032a9049a365c257fbd0d0ab51ba6a3` |
| `test/NemesisPoC4.t.sol` | `021e917b6e2a745650822b5b984546a0396d8c2a95cbc2da8fad68adcdce1b69` |
| `test/RevenueRouter.t.sol` | `8f3100d6f95c1f72d76bd4bfa7794009cf1eed50df5150c5d7f45357b7849ae5` |
| `test/StakedGovToken.t.sol` | `9a7dca0cdf46d40a4ff15604180b241195b21fa52070991963e9580866c13120` |
| `test/StakingRewards.t.sol` | `cff4cde5b324430776ee705473b7d53295e5f52578323b01b6b1c5acbd40dfd9` |
| `test/StakingRewardsFunder.t.sol` | `d0834dec256b804110677f7ff7722dab6c49cc7a2fcf0598a35cb6bd028ef83f` |
| `test/helpers/CloneTestUtils.sol` | `10a8292f97ee4aa4b42e455adee4f99aac3269c81fad5806e221bde269bb0192` |
| `test/helpers/CoinDAOTestBase.sol` | `7c709dba7efee597fc6fb9599ef580c8970ca16fa2e02d3ec468f464ae5960f7` |
| `test/mocks/MockERC20.sol` | `7f18b8dae6a91a9b752b03e8ad2a05f2343ad231e7c7b86b94c797edb21b6607` |
| `test/mocks/MockMonolith.sol` | `a2cb5c94d980a1909c2bd39f745648159f1acff6f360ad1a763e2bec1e0e1778` |

⚠️ **Note on scope, recorded rather than resolved silently.** Our scope document placed `script/**`
in the audited tier and simultaneously listed it under a do-not-read heading, and the second line is
what one of our two review briefs was assembled from. The audited tier governs — findings against the
deploy scripts stand — but the measured cost of the contradiction is real and is disclosed in the
limitations table and in `MED-19`: `script/` finished this round with single-methodology coverage.

---

## Appendix B — findings outside the threat model (DESCOPED)

These were identified and then filed here because they fall outside the trust assumptions quoted in
*Scope*. **They are real observations.** If your trust assumptions differ from the ones we were
given, this appendix may be the most important page in this report — and Q-1 is precisely a question
about whether the first entry belongs here at all.

The test for admission was applied and it rejected two candidates, which are named at the end so the
appendix cannot be read as a filing cabinet.

| # | observation | holder | worst case, plainly | the assumption that descoped it, quoted |
|---|---|---|---|---|
| **D-1** | **The launch caller names the address that receives 500,000 liquid GOV.** `allocationFor` (`:273-290`) pays a fixed `IMMEDIATE_ALLOCATION_WEIGHT = 500` share of the post-Monolith remainder; at the default `deployerStakeBps = 0` that is `9,800,000 × 500 / 9,800 = 500,000 GOV`, sent liquid in the launch transaction (`:490-493`). Separately, `deployerStakeBps` up to `MAX_DEPLOYER_STAKE_BPS = 2_000` vests up to **2,000,000 GOV** over four years to the same caller-named address — ⚠️ **not in addition to the 500,000.** The liquid share is computed from the remainder left *after* the deployer vest, so raising `deployerStakeBps` shrinks it: at the 20 % maximum it falls to **397,959.18 GOV** | the launch caller, for its own launch | a launcher names itself and walks away from a launch it paid nothing for. ⛔ **The two maxima are mutually exclusive by construction and must not be added:** `allocationFor` derives the liquid share from the remainder left after the deployer vest. The reachable worst case is the 20 % setting — **2,000,000 GOV vesting plus 397,959.18 GOV liquid = 2,397,959.18 GOV, 23.98 % of a fixed 10,000,000 supply** — through two channels to one caller-named address, and it is the same figure `HIGH-1` derives. At the shipped default the liquid share is instead at *its* own maximum, **500,000 GOV**, and the vest is zero. Nothing in the contract distinguishes either configuration from an honest one | *"**Also out of scope:** … economic/tokenomic soundness of the 65:5:28 allocation as a **business** choice…"*, and *"CoinDAO deployer … chooses … **`deployerRecipient`**"* |
| **D-2** | **The launch caller supplies every Monolith market parameter, unread.** `deploy()` copies the caller's eighteen-field `DeployParams` and overrides exactly two — `.operator` and `.manager` (`:303-307`). The remaining sixteen reach the live Monolith Factory exactly as supplied: `collateral`, `psmAsset`, `psmVault`, `feed`, `collateralFactor`, `minDebt`, `timeUntilImmutability`, `halfLife`, the two target free-debt ratios, `redeemFeeBps`, `stalenessThreshold`, `maxBorrowDeltaBps`, `psmVaultMinTotalSupply`, and the token name/symbol. Absence claim with its control: a grep for five of those field names across `CoinDAOFactory.sol` returns **nothing**, while the same pattern over the two fields the factory *does* police returns 12 lines | the launch caller | any market GovernanceFactory launches carries parameters nobody validated, including the oracle feed and the immutability deadline. ⛔ Two in-scope findings hang off this: `MED-7`'s live trigger is the caller-chosen `psmVault`, and `LOW-5` is the residual | the deployer's `DeployParams` are listed among that actor's capabilities. **See Q-5 below** |
| **D-3** | **The timelock owns the treasury vesting wallet, and owning a vesting wallet is not the same as being paid by one.** `treasuryVesting.initialize(deployment.timelock, vestingStart, FOUR_YEARS)` (`:463`); `CoinDAOVestingWallet` is a bare upgradeable vesting wallet with no overrides, so its owner holds the whole ownership surface. A vesting schedule constrains **when** tokens leave, not **who owns the wallet** | the timelock, through a passed proposal | one passed proposal moves ownership of the treasury vesting wallet — **2,742,465 GOV** of unvested remainder at day 30 — to any address. The DAO changing its own treasury vesting recipient is exactly what the threat model says the DAO may do | *"Timelock / Governor (post-launch DAO) … **treasury vesting recipient**"* |
| **D-4** | **The Governor sets its own parameters, and the parameters have no floors or ceilings.** The `onlyGovernance` setters on the inherited base classes are reachable through a passed proposal and are overridden nowhere in `src/` | the timelock, through the governor, through a passed proposal | a DAO can re-parameterise itself into a state it cannot leave, because the repair needs a proposal that can no longer be created. The capability is intended; **the absence of a return path** is what makes it consequential | *"Timelock / Governor (post-launch DAO) … sets `govStakingBps` 0–100 %…"* — a documented, intended, correctly-gated capability |
| **D-5** | **`monolithBeneficiary` may rotate itself, and the rotation is not retroactive.** A mutable global on the factory is stamped into an immutable per-deployment owner at `:470`. Rotation is two-step and self-driven (`:250-271`). Absence claim with its control: two writes to the global exist in the whole corpus — the constructor and the gated accept — and the factory has no owner at all, `contract CoinDAOFactory {` at `:21` inheriting nothing (control: a grep for `Ownable` across `src/` returns `RevenueRouter.sol` and `StakingRewards.sol`, so the pattern finds ownership where it exists) | whoever holds the beneficiary key | the beneficiary receives `MONOLITH_BPS = 200` — **200,000 GOV per launch**, vesting four years — from every CoinDAO ever launched, with no cap on the number of launches and no consent from launchers, and may hand that stream to any successor. All of that is documented and intended | *"`monolithBeneficiary` … receives 2 % of every launch, vesting 4y; **may rotate itself (2-step)**"* |
| **D-6** | **Exiting a stake in full forfeits un-harvested revenue.** `withdrawTo` and its wrapper `withdraw()` carry `updateReward(msg.sender)` but not `harvestYield` (`:113-125`); `harvestAndWithdraw` (`:130`) carries both | any staker, on their own position | a staker who calls `withdraw()` instead of `harvestAndWithdraw()` forfeits accrued revenue to the remaining stakers. It is a **foot-gun**: the harm is self-inflicted, the alternative exists one function away in the same ABI, and your comment at `:127-129` documents the choice explicitly | *"unprivileged caller … **stake, withdraw**…"* |

**⛔ What is NOT descoped in each of those, so the two halves are never confused**

| # | the in-scope half, and where it is graded |
|---|---|
| D-1 | *"The deployer should not receive 5 %"* is your business decision. *"The 5 % arrives liquid, unvalidated, and at 50× the Governor's own proposal threshold, on the branch `_validate` does not police"* is ours — **`HIGH-1`**. ⭐ **This is the descoped half of a High, and it is the entry to read first.** Your answer to *"is the deployer permitted to name the recipient of 500,000 liquid GOV?"* is what decides whether this half is a finding |
| D-2 | the unvalidated forwarding as a **residual** is `LOW-5`, and its consequence through the caller-chosen `psmVault` is **`MED-7`** |
| D-3 | `renounceOwnership()` sets the owner to `address(0)`, after which `release()` can never be called again and the wallet is permanently bricked. Destroying the wallet is not a documented capability — **`MED-4`** |
| D-4 | the **absence of bounds** on five parameters is documented nowhere — **`MED-9`**. `GovernorSettings._setVotingPeriod` rejects only `0`, read verbatim from the vendored source. ⚠️ Do not read a proposed bound out of this entry; see Q-2 |
| D-5 | that rotation binds only **future** launches, with **no migration path for a compromised key** — **`MED-12`** |
| D-6 | the **partial** withdrawal, which silently re-prices the exiter and has no *atomic* harvesting alternative anywhere in the ABI — **`MED-16`**. The split is the finding |

**The two candidates the test rejected.** Recorded so the admission test can be checked against
cases it refused as well as cases it accepted. In both, a documented capability was present and the
entry was still graded as a bug.

| candidate | the documented capability that was present | why it is **not** descoped |
|---|---|---|
| `MED-5` — the revenue split is read at harvest time and applied to an unattributed backlog | *"Timelock / Governor … sets `govStakingBps` 0–100 %"* | an **unprivileged amplifier** is named, which is what our admin-action rule requires. `distribute()` is `external` and unguarded and reads the whole balance and the split at call time; `Governor.execute()` is permissionless because `executors[0] == address(0)`. So raise-then-sweep bundles **atomically** — a retroactive sweep. **Stays MEDIUM** |
| `MED-18` — `renounceOwnership` and single-step `transferOwnership` left exposed on the permanent Lender operator | *"Timelock / Governor … **owns** `RevenueRouter`"* | **owning** is documented; **destroying the ownership** is not. Your own NatSpec at `RevenueRouter.sol:12-15` states why it matters — the operator role was deliberately frozen, so after renunciation `setGovStakingBps` and `setManager` are gone and cannot come back. **Stays MEDIUM** |

### B.1 — the four untrusted actors, and what each can actually do

Enumerated from the locked source so you can compare each against your own intent. The criterion is
stated so the count is checkable: these are the four actors named in the capability quotations behind
D-1 to D-6. The other no-trust rows — the Lender `operator`, which is permanently the `RevenueRouter`
*contract* rather than a party, and the factory deployer / implementation supplier — carry no
descoped entry and are covered as in-scope findings above.

**The five stages of a deployment's life**, used consistently below: **S0** before any launch ·
**S1** inside the launch transaction · **S2** after launch, before a proposal can pass · **S3**
steady state · **S4** terminal, one-way transitions no later stage can undo.

> ⚠️ **On the length of S2, because a single number here is wrong.** The governance cycle from your
> constants is `7_200 + 36_000 = 43,200` blocks (`CoinDAOGovernor.sol:22-23`), ≈6.0 days at 12 s,
> plus `DEFAULT_TIMELOCK_DELAY = 2 days` — **≈8 days** before any proposal can execute. ⛔ Do not
> quote a single outage figure without naming the route it belongs to. The binding route for a
> launcher who interacts with the market is **1.728 days** to a proposal existing, by staking the
> market's own Coin into the launch's own reward stream. The earliest route that requires **no**
> market interaction at all is **73.0 days**, via the beneficiary's vest. Both numbers are real; the
> smaller one binds; and on the branch where a `deployerRecipient` **is** named the window to a
> proposal existing is **zero** — verified by a passing control.

**Actor 1 — the unprivileged caller** (trusted *never*)

| stage | what this actor can actually do | where |
|---|---|---|
| S0 | read everything: `implementations()`, `deploymentsLength()`, `deployments`, `hasCoinDAO`, `usedDeploymentKeys`, `deploymentKey()`, `allocationFor()`, `predictCoinDAOAddresses()` — all `view`/`pure`, no gate | `:178-248`, `:273` |
| S0→S1 | **call `deploy()` and become the launch caller.** No allowlist, no fee, no caller gate; the only checks are `manager != address(0)`, `_validate(govParams)` and salt reservation | `:292-313` |
| S0→S1 | call `deployForExistingCoin()` — but only if already the Lender's `operator` and having nominated the factory as `pendingOperator`. Gated on the external market, not on identity in your code | `:315-346`, `:328`, `:331` |
| S2, S3 | `StakingRewardsFunder.fundNextTranche()` — **permissionless.** `nonReentrant` is its only modifier; it reverts on **timing** and on **wiring**, never on authority | `StakingRewardsFunder.sol:68-88` |
| S2, S3 | `RevenueRouter.distribute()` — **permissionless**, no modifier at all | `RevenueRouter.sol:68-86` |
| S2, S3 | `StakedGovToken`: `depositFor`, `withdrawTo`, `withdraw`, `harvestAndWithdraw`, `getReward`, `harvestAndGetReward`; `StakingRewards`: `stake`, `withdraw`, `getReward`, `exit` | `StakedGovToken.sol:102-155`, `StakingRewards.sol:112-148` |
| S3 | **execute any queued proposal.** The timelock is deployed with `executors = [address(0)]`, the open-role sentinel, so execution is permissionless. This is what lets a parameter change and a sweep bundle atomically | `CoinDAOFactory.sol:373-374` |
| S3 | propose and vote — gated by **stake, not identity**: 10,000 GOV of delegated voting weight | `:33` |
| **cannot** | `StakedGovToken.notifyRewardAmount` (router-gated); `StakingRewards.notifyRewardAmount` (distribution-gated); `setGovStakingBps`, `setManager`, `acceptLenderOperator` (all `onlyOwner` = the timelock); `StakingRewards.setRewardsDistribution` — its owner was renounced during the launch at `:488`, **and** no address in the system can act as that contract's owner, so **that position is unreachable by anyone**. ⚠️ The two clauses are independent, and the renounce is **not** the cause: of the factory's nine externally reachable functions none can call that setter on an already-deployed clone, and the factory holds no arbitrary-call forwarder, so the position was already unreachable **before** `:488` ran | — |

⭐ **Nine functions across the system succeed for a caller holding nothing.** The measured
consequence of that whole class is bounded at **999,999 wei** worst case (Appendix D), and it stays
at that grade. **Only one of the nine matters**, and it is `distribute()`, for the reason in the
rejected-candidates table above.

**Actor 2 — the CoinDAO deployer** (trusted *no*)

| stage | what this actor can actually do | where |
|---|---|---|
| S0 | choose `userSalt` freely. Salts are namespaced by caller, so a salt cannot be squatted and a third party burning the same salt does not block the victim | `:193-194` |
| S1 | choose the gov token `name`/`symbol`; the staked wrapper's are derived | `:367`, `:398-399` |
| S1 | choose `deployerStakeBps`, 0 … 2,000 → up to **2,000,000 GOV** vesting four years to a caller-named address. One bps above the cap reverts | `:25`, `:274`, `:280` |
| S1 | choose `deployerRecipient` — the address receiving **500,000 GOV liquid** at the default. ⚠️ `_validate` requires a non-zero recipient **only** when `deployerStakeBps != 0` | `:490-493`, `:556-563` |
| S1 | choose **all sixteen unread market parameters** (D-2) | `:303-307` |
| S1 | choose the Lender `manager` outright, as a named argument the factory writes in and never reads back | `:296`, `:305` |
| S1 | choose whether the incentivised token is the market's Coin or its vault share | `:433-435` |
| S2 | hold 500,000 liquid GOV against a 10,000 GOV threshold — **50×** — from the launch block. This is the in-scope half of D-1 and it is a High | `:33`, `:493` |
| S3, S4 | ⭐ **nothing.** The launch caller retains **no role in the deployed CoinDAO.** Absence claim with its control: `creator` appears in `CoinDAOFactory.sol` only as a salt input, an event field and internal parameters, and is never compared against `msg.sender` after the launch or written into a role — while the same file's three genuine identity gates *are* findable by the corresponding pattern | — |

**The deployer's power is entirely front-loaded into S1**, which is exactly why the launch
transaction is where this review's Highs live.

**Actor 3 — `monolithBeneficiary`** (trusted *no*)

| stage | what this actor can actually do | where |
|---|---|---|
| S0 | exists from factory construction; a zero address is rejected. Set once, by the factory deployer | `:165`, `:175` |
| S1 | receive **200,000 GOV** of every launch into a fresh vesting wallet whose owner is the beneficiary value read at that instant. No consent from the launcher, no cap on launches | `:26`, `:278`, `:470`, `:495` |
| S2, S3 | rotate itself, two-step, self-driven, unblockable by anyone else | `:250-271` |
| S2, S3 | on each **already-created** vesting wallet, as its owner: `release()`, `transferOwnership()` (moves the entire unvested remainder in one call), `renounceOwnership()` (bricks it) | `CoinDAOVestingWallet.sol` |
| S4 | ⛔ rotation is **not retroactive and there is no migration**. Wallets stamped before a rotation keep the old owner forever (D-5 / `MED-12`). A compromised key cannot be recovered from — only stopped from earning more | `:470` |
| **cannot** | be replaced by anyone else. There is no factory owner and no override | `:175`, `:268` |

**Actor 4 — the Timelock / Governor** (trusted *no*)

| stage | what this actor can actually do | where |
|---|---|---|
| S1 | created with **no proposers** and `executors = [address(0)]`; phase 3 grants proposer and canceller to the Governor, then the factory renounces admin | `:372-374`, `:428-430` |
| S1 | becomes owner of `RevenueRouter` at the end of phase 5, and of the treasury vesting wallet in phase 6 | `:454`, `:463` |
| S2 | ⭐ **nothing at all.** No proposal can execute for ≈8 days from launch. Every capability below is unavailable for that window — which is why the launch transaction's own allocations, not the DAO's powers, are where this review's Highs live | `CoinDAOGovernor.sol:22-23`, `CoinDAOFactory.sol:37` |
| S3 | `setGovStakingBps(0…10_000)` — the staker/treasury split anywhere in the full range | `RevenueRouter.sol:88-92` |
| S3 | `setManager(newManager)` — rotate the Lender `manager`. The only remaining lever over the Lender, and it does not expire | `RevenueRouter.sol:94-98` |
| S3 | `treasuryVesting.release()` / `transferOwnership()` (D-3) | `:463` |
| S3 | **administer itself** — change its own delay, and grant or revoke proposer, canceller and executor for any address, through a passed proposal. ⚠️ **This is not on the capability list we were given.** See lead L-1 | the vendored `TimelockController` constructor |
| S3 | re-parameterise the Governor — five setters, **none of them bounded** (D-4 / `MED-9`) | `CoinDAOGovernor.sol:15-21` and its base classes |
| S4 | `RevenueRouter.renounceOwnership()` — terminal. One passed proposal, malicious or mis-encoded, permanently removes both remaining levers from a Lender whose operator cannot be reassigned. **Not descoped** | `RevenueRouter.sol:18` (inherited) |
| S4 | `treasuryVesting.renounceOwnership()` — terminal, bricks the treasury vest (D-3, in-scope half) | `CoinDAOVestingWallet.sol` |
| **cannot** | **change `RevenueRouter.treasury`.** Written once inside `initialize` at `:57`, with no setter at any privilege level. Grep: `treasury` → 11 hits in that file, **zero of them a `set*` function**; control — the sibling levers `govStakingBps` and the manager *do* have `onlyOwner` setters at `:88` and `:94`, so the pattern finds a setter where one exists | `RevenueRouter.sol:57` |
| **cannot** | **reach `StakingRewards.setRewardsDistribution`.** Its owner was renounced during phase 7 and no address in the system can act as that contract's owner | `:488` |
| **cannot** | **migrate the Lender `operator` role.** `RevenueRouter` exposes no `setPendingOperator`; a grep across `src/` finds the selector only at the factory's phase-5 call site (`:452`), in the interface declaration (`IMonolith.sol:35`), and in the NatSpec sentence saying the omission is deliberate. Control: the same grep for the sibling `acceptOperator` returns three call sites, so the pattern finds an exercised selector. ⚠️ **Conditional, and the wording matters:** this establishes that **your code** offers no such path. It is **not** a claim that no path exists on the deployed Lender | `RevenueRouter.sol:13-15`, `:64-66` |
| **cannot** | mint GOV. The supply is fixed at initialization and no mint path survives the launch | `GovToken.sol` |

### B.2 — three further questions this appendix hands back to you

Beyond Q-1 to Q-4 in the body:

| # | question | why it is yours, not ours |
|---|---|---|
| **Q-5** | Do you intend `DeployParams` to reach the live Monolith Factory unread, from an arbitrary caller? | if yes, D-2 is correctly filed here; if no, it is a graded finding we filed as a capability on your instruction |
| **Q-6** | Should the timelock be able to administer its own roles and its own delay? | the capability list we were given for the DAO is a **closed list** and this power is not on it. We treated it as implied by *"post-launch DAO"*. If it was not intended, it becomes a finding — lead L-1 |
| **Q-7** | Is the beneficiary's per-launch 2 % intended to be perpetual and uncapped across an unbounded number of launches? | the entitlement is documented; its unbounded accumulation across launches is discussed nowhere in the code or its comments |

---

## Appendix C — coverage

Every unit in scope, and what was applied to it. A unit with no coverage is disclosed here rather
than omitted.

**15 units required, 15 covered.** 13 carry a finding; 4 carry an explicit *examined, nothing found*
line with the examination described. 115 of 115 declarations are dispositioned.

| # | unit (declarations) | methodologies applied | result |
|---|---|---|---|
| 1 | `src/CoinDAOFactory.sol` (16) | both | findings — `HIGH-1`, `MED-10`, `MED-12`, `LOW-6`, `LOW-11`, `LOW-12`, `MED-17` |
| 2 | `src/StakedGovToken.sol` (19) | both | findings — `MED-6`, `MED-7`, `MED-16`, `LOW-1`, `MED-14`, `LOW-3`, `LOW-4` |
| 3 | `src/StakingRewards.sol` (16) | both | findings — `HIGH-3`, `LOW-2`, `INFO-3`, `LOW-13` |
| 4 | `src/CoinDAOGovernor.sol` (12) | both | findings — `HIGH-2`, `MED-8`, `MED-9`, `LOW-10`, `MED-15` |
| 5 | `src/RevenueRouter.sol` (6) | both | findings — `HIGH-4`, `MED-5`, `MED-13`, `MED-18`, `INFO-1` |
| 6 | `src/StakingRewardsFunder.sol` (6) | both | findings — `MED-11`, `LOW-7`, `INFO-2` |
| 7 | `src/deployment/DeploymentLibraries.sol` (4) | both | **examined, nothing found** |
| 8 | `src/GovToken.sol` (4) | both | **examined** — fixed supply, no mint path; this is what the stGOV supply-integrity result rests on |
| 9 | `src/interfaces/IMonolith.sol` (10) | both, plus a dedicated boundary pass | finding — `LOW-5`; and all ten declared selectors and the 18-field `DeployParams` layout verified against the deployed contracts |
| 10 | `src/interfaces/INotifiableRewardReceiver.sol` (2) | both | **examined, nothing found** |
| 11 | `src/CoinDAOVestingWallet.sol` (1) | both | finding — `MED-4` |
| 12 | `src/interfaces/IRevenueDistributor.sol` (1) | both | **examined, nothing found** |
| 13 | `script/DeployCoinDAO.s.sol` (17) | ⚠️ **one methodology only** | findings — `MED-19`, `LOW-14` |
| 14 | `script/DeployCoinDAOFactory.s.sol` (1) | ⚠️ **one methodology only** | **examined, nothing found** |
| 15 | the eight-phase launch sequence | both | findings — `MED-1`, `MED-2`, `MED-3`, `MED-12`, `LOW-12`; and the verified negative that the ordering is load-bearing and fails safe |

⚠️ Two rows are not properties of any single unit and so do not appear above: `LOW-8` (the vendored
trees are unpinned) and `LOW-9` (the clone-pattern reentrancy-guard residual, verdict **sound**).
Both belong to the build-hygiene work item, `W16`.

⛔ **Stated honestly: what was checked, and what was not.** The declaration denominator reconciles
exactly, unit by unit, and every unit carries a disposition heading. **Nobody re-read all 115
individual citations.** A wrong citation inside a covered unit would survive this check; a silently
dropped unit, or a mis-stated total, would not.

**Boundary call sites.** All **eight** boundary call sites our scope enumerated carry an explicit
disposition. ⚠️ **Your own grep will return a different number and we would rather say so than have
a correct claim look like a miscount:** `src/` contains **11** external calls into Monolith across
**10 distinct selectors** — eight in `CoinDAOFactory.sol` (`:307`, `:323`, `:327`, `:330`, `:336`,
`:337`, `:341`, `:452`) and three in `RevenueRouter.sol` (`:65`, `:69`, `:96`). The eight is our
scope's clustering of those eleven, not a count of call sites, and all eleven are inside it. **The
assumptions we wrote down before the review ran:** ten in total; **nine are discharged**, several of
them by fork execution against the deployed protocol, and the tenth — that GovernanceFactory is not
deployed anywhere — rests on your statement alone and is Q-4.

### The gaps, stated as gaps

| gap | what it is |
|---|---|
| **single-methodology coverage of `script/`** | one of our two briefs had `script/` excluded by a line in our own scope document. `MED-19` and `LOW-14` therefore have no independent corroboration. Under our coverage rule the unit is covered; under the two-methodology design it is not. Disclosed rather than papered over |
| **the evidence about fixes** | **at least 22 of 52 candidate fixes were never compiled by anyone.** Not a coverage gap in the *code*; a coverage gap in the evidence about *fixes* — and the more dangerous kind here, because two changes were blessed in this engagement before they were run and both were later killed by running them |
| **no invariant is quantified over time or over a whole fix set** | every invariant here is instantaneous and single-finding. The attack that defeats a composition is neither. ⛔ Anything this report says about an invariant says this too |
| **one Medium has no exploit reproduction** | `MED-13` is arithmetic and code-read only. Its *fix* is executed; the finding is not. That is the fix's gap rather than the finding's, and the row says so |
| **the prior third-party reports** | five were excluded from our corpus by your direction, to protect independence. We cannot tell you which of these findings you have already seen and declined |

### What the passing suite does and does not certify

There are **zero fork tests** in `test/` — no `createSelectFork`, no `rollFork`, no `createFork`,
anywhere — so no test in your suite touches a live market. **36 of the 65 reach a lending market at
all, and what they reach is a 2,853-byte mock**: `test/mocks/MockMonolith.sol`, entered from
`CoinDAOFactory.t.sol` (19 tests), `NemesisPoC4.t.sol` (10), `CoinDAOGovernor.t.sol` (4) and
`RevenueRouter.t.sol` (3). The other 29 exercise the token, staking and script units in isolation —
including the four in `DeploymentScripts.t.sol`, which use a five-line `MonolithFactoryStub`
declared inside that file rather than the mock. The suite therefore certifies the mock's behaviour
and the units' behaviour, not the integration. That is why every boundary assumption in this review
was discharged by fork execution rather than by a passing test.

⚠️ **And one sharper observation about what any test corpus can and cannot show.** A test corpus is
a filtered corpus: every test in it describes a path that works. All
four funder tests run with `_totalSupply == 0`, and **one of your own tests asserts the fully-stranded
state as a success condition.** The suite does not merely miss `HIGH-3`; on that path it certifies
it. ⭐ The other side of the same coin is the reason we cite your tests so often: **ten** of your 65
tests assert these defects as present, and repairing `HIGH-3` by reverting the launch on an empty
pool fails **27 of 65**, all ten of them included. Your suite is not blind. It is scoped to a
different question.

---

## Appendix D — measured dust and rounding

These are graded **Low deliberately, because the measured harm is dust.** They are here so a
999,999-wei rounding note does not compete for attention with a governance capture, and the
measurements are given so you can check the grade rather than take it.

| # | mechanism | measured harm | grade basis |
|---|---|---|---|
| `LOW-1` | two floor divisions in series with no residual carry — one in the notification, one in the distribution | **0 ppm/year** over 8,760 harvests at 18 decimals. The Coin is 18 decimals, verified on chain, and the live accrual is roughly seven orders of magnitude above the rounding-to-zero threshold. The distribution's own rounding toward the treasury measures **50 wei over 50 distributions** | dust, non-compounding. ⚠️ The condition stays live and is stated rather than buried: on a market whose Coin has **8 decimals or fewer** the arithmetic is a different order of magnitude — lead L-3. We refuse the claim about a market that does not exist |
| `LOW-2` | `updateReward` runs before a guard the caller passes trivially, so a caller with no position writes global reward state | **19 wei over 20 calls** | dust. ⚠️ A stronger form of this claim — that an attacker can *burn* extra emissions by calling `getReward()` during a vacancy — is **refuted**: `stake()` runs the update **before** the supply increases, so the zero-supply early return fires either way. Two systems, one hammered for 24 hours and one untouched, produced **byte-identical** results (`173,630.136986301367296 GOV` each) |
| `LOW-3` | donated assets are swept at one contract and permanently stranded at the adjacent one | **unbounded in principle** — a donor who sends 1,000,000 COIN to `StakedGovToken` strands 1,000,000 COIN. ⛔ We are explicit that the 999,999-wei bound below does **not** bound this mechanism; it bounds a different quantity | Low on the **self-harm-adjacent** clause: the stranded asset is one its owner chose to send to a contract that documents no sweep, and no protocol-held value is at risk. ⭐ The reportable content is the **asymmetry** — the same donation to `RevenueRouter` is swept by the full-balance read at `:71`, and to `StakedGovToken` it is stranded forever. Opposite fates for one token at adjacent contracts |
| `LOW-4` | dead approval surface on a non-transferable token; `permit` burns the nonce shared with `delegateBySig` | no value at risk; the allowance enables no transfer path | Low. ⚠️ The fix is *an option, not a requirement*, and it is untested |
| — | the permissionless *no standing* call class as a whole: **nine** functions across the system succeed for a caller holding nothing | **999,999 wei worst case**, bounded at `supply / 1e18` | ⭐ **Only one of the nine matters**, and it is `distribute()` — because it is the unprivileged amplifier that keeps `MED-5` in scope. The other eight are the dust |

⛔ **This calibration is deliberate.** The measurement is printed beside each row so the grade can be
checked; if a measurement is wrong, the row moves on the measurement.

---

## Closing note

Two things are worth repeating because they are the easiest to lose between this document and a
sprint board.

**The order is not the severity order.** Fixing the fee passthrough activates a group of defects that
are inert only while the fee is zero, and one member of that group has no working fix. The one
mechanism that would interrupt the takeover chain is not a High, so a severity-sorted plan schedules
it late or never — and it is an open design problem in any case.

**And our fixes are evidence of very different strengths.** Two changes in this review are backed by
execution end to end. Fourteen were killed by running them. At least twenty-two were never compiled
by anyone, and each of those is labelled a hypothesis wherever it appears. **Please treat the
distinction as load-bearing** — the two changes that were tested and turned out to make things worse
were both caught by running them, not by reading them.

We would rather be corrected cheaply than be believed wrongly. Every finding above carries the
condition under which we would withdraw it; if one of them is wrong, tell us which line disproves it
and we will withdraw it in a numbered revision.
