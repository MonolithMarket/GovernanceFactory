# GovernanceFactory security review — what is in this bundle

*Inverse Finance Risk Working Group · 2 September 2026 · report version 1.0*

---

## Read these in this order

Every filename carries the **tool**, the **date it ran**, and the **commit it ran against**.
All three artifacts reviewed the same commit — `77b78cd9ebefc8b881d0413a403386b84ecbe115`,
35 files, hash-locked before any tool ran and re-verified afterwards. The report is dated
later than the two originals because the day between them is the adjudication.

| # | file | tool | ran | what it is |
|---|---|---|---|---|
| **01** | `01-security-review_20260902_77b78cd9.md` | — | 2 Sep | **The report.** The work list. Everything adjudicated; every fix labelled executed or hypothesis |
| **02** | `02-pashov-solidity-auditor-v3_20260901_77b78cd9.md` | `solidity-auditor` **v3** (Pashov) | 1 Sep, 17:50–18:23 UTC | The **unedited** output of the first methodology |
| **03** | `03-nemesis-auditor_20260902_77b78cd9/` | `nemesis-auditor` (unversioned) | 1 Sep 18:35 → 2 Sep 00:29 UTC | The **unedited** output of the second, across 17 files |
| **04** | `04-corrections-to-the-originals_20260902.md` | — | 2 Sep | ⛔ **Mandatory companion to 02 and 03.** Everything in those two we later proved wrong |

The two methodologies were run **blind to each other** — neither saw the other's output, and
neither saw our scope questions or assumptions. That is what makes their agreement mean
something, and it is also why they disagree in places.

---

## ⛔ Before you act on anything in 02 or 03

**They contain recommended fixes that do not work.** We measured this: **57 claims** across
the two original reviews were later killed or refuted — a whole attack whose premise turned out
to be false, and several remedies that a developer could implement in an afternoon and be no
safer afterwards.

⭐ **That is not a criticism of the tools. It is the finding.** Fourteen proposed fixes in this
engagement were killed *by applying them as real source changes and re-running the defect's own
reproduction*. Every remedy that nobody executed turned out to be wrong. Two of the reviews'
strongest-looking remedies pass your entire 65-test suite while doing nothing at all, because
those tests never exercised the defect.

**So: file 01 is the work list. Files 02 and 03 are evidence, not instructions.**

---

## Why we are giving you the originals at all

So you can check us.

You should be able to satisfy yourself that we did not quietly drop a real finding while
consolidating two reviews into one report. Diff them against file 01 yourself. If you find
something in 02 or 03 that you think we lost, **tell us and we will answer it specifically** —
either with the reason it was dropped or with a correction to the report.

⚠️ Two honest notes about that comparison:

- **A finding missing from the report is usually a ruling, not an omission.** Some were refuted,
  some fall outside the threat model we were given (see the report's Appendix B — if your trust
  assumptions differ from ours, that appendix may be the most important page), and some were
  graded down to dust after measurement. File 04 covers the largest ones.
- **The two originals disagree with each other in places**, and the report says which way we
  ruled and why.

---

## What we changed in these files, and what we did not

⛔ **File 02 is byte-for-byte as produced. Nothing was edited.**

**File 03 has exactly one class of change: our own local filesystem paths were replaced with
`[local-path]` and `[scratch]`.** Nothing else — no wording, no findings, no severities, no
omissions. Those paths are our machine's directory layout and mean nothing to you.

We do not edit review output. That is why corrections live in file 04 instead of being folded
back into 02 and 03 — a corrected document loses the record of what it originally said, and
that record is what lets you audit our adjudication.

---

## How to verify anything in the report

Every finding graded High carries a reproduction that runs against the **live deployed
protocol** on a mainnet fork pinned at block **25,884,025**, with no mock of the dependency.
The report's *"How to verify a fix"* section gives the commands.

⭐ **One request, and it is the single most useful thing in this bundle:** when you fix
something, verify it by making **that finding's own reproduction stop reproducing**. Please do
not use "the 65-test suite still passes" as your acceptance gate. We produced five separate
changes during this review — including one that permanently locks up 2.8 million tokens and one
that leaves a governance configuration nobody can vote in — that leave your suite fully green.

---

## Questions we need answered

The report ends with four questions only you can answer. Two of them gate findings we could not
grade without you, and one of them — the purpose of the liquid genesis allocation — is a product
decision that determines whether the top finding has any remedy at all. We deliberately did not
answer it for you.

---

*Confidential. Prepared for the Monolith development team.*
