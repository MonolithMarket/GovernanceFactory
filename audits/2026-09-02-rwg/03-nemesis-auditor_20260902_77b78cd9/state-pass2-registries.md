# NEMESIS Pass 2 — State Inconsistency Auditor — launch registries and address machinery

**Lens:** `.claude/skills/state-inconsistency-auditor/SKILL.md`, Phases 1–8 executed in full
**Language:** Solidity 0.8.26 / Foundry, via-ir, optimizer 200 runs
**Tree under audit:** `[local-path]` — **read-only, never written to**

**Scope files (mapped storage-variable by storage-variable):**

| file | lines | role |
|---|---|---|
| `[scratch]` | 564 | four registries, eight-phase launch, ten-address prediction |
| `[scratch]` | 60 | CREATE2 through DELEGATECALL |
| `[scratch]` | 10 | `VestingWalletUpgradeable` wrapper (owner ≡ beneficiary) |

**Cross-file context read for coupling only (not reported against):** `RevenueRouter.sol`,
`StakedGovToken.sol`, `StakingRewards.sol`, `GovToken.sol`, `interfaces/IMonolith.sol`,
`script/DeployCoinDAO.s.sol`, `test/**`.
**Not read (per assignment):** `[scratch]`, anything under `engagements/`.
OpenZeppelin v5 behaviour was therefore established **by execution**, not by reading the library.

**Enrichment consumed before starting:** `.audit/findings/nemesis-phase0-recon.md` (§Q0.5 pairs
#9, #10, #12, #13, #14), `.audit/findings/feynman-pass1-factory.md` (FF-01…FF-12),
`.audit/findings/feynman-pass1-governance.md` (FF-002, FF-003, FF-005, FF-006).

**Execution environment.** Disposable copy at
`…/[scratch]` (full tree, own `lib/`). **`[scratch]` was not modified** —
`diff -rq` against the audited `src/` is clean after every mutation, and the audited tree's own
suite re-verified **55/55 green** at the end.

```
test/audit/StatePass2Registries.t.sol   13 passed
test/audit/StatePass2Coupling.t.sol      5 passed
test/audit/StatePass2Mutation.t.sol      1 passed
full tree after my additions            74 passed / 0 failed
```

**3 source mutations run** (M-S1, M-S2, M-S3), each reverted and re-verified byte-identical.

---

## 0. What this pass was asked, and what it found

Pass 1 asked *"can the eight orderings be reordered?"* and answered: five of eight revert.
This pass asks a different question — **where do two registries disagree about the same launch?**

The answer is that the factory's four registries are written in **three different phases** of one
transaction and are **never cross-checked by any code, anywhere**. Three of the four are
monotone booleans/arrays with no delete, no pop, and no reverse index. The one genuinely
*mutable* pointer in the contract — `monolithBeneficiary` — is a **partial operation**: rotating
it moves the pointer and leaves every wallet it has already stamped behind. That is
SKILL RULE 2 ("partial operations are the #1 source") landing exactly on recon coupling pair #14.

---

## 1. Phase 1 — Coupled State Dependency Map

```
┌──────────────────────────────────────────────────────────────────────────────────┐
│ COUPLED STATE DEPENDENCY MAP — CoinDAOFactory + CoinDAOVestingWallet              │
├──────────────────────────────────────────────────────────────────────────────────┤
│                                                                                   │
│ PAIR 1: hasCoinDAO[lender]  <->  ∃i : deployments[i].lender == lender             │
│   Invariant: a lender flagged as launched must appear in the record array         │
│   Written at:  L359 (Phase 1)          L502 (Phase 8)                            │
│   Distance:    143 lines, 7 phases, ~30 external calls, 3 irreversible handoffs   │
│   Reverse index: NONE. Only an O(n) scan of `deployments` can test this pair.     │
│                                                                                   │
│ PAIR 2: usedDeploymentKeys[key]  <->  ∃i : deploymentKeyForId[i] == key           │
│   Invariant: a consumed key corresponds to exactly one recorded launch            │
│   Written at:  L530 via L300 (deploy, PRE-external) or L333 (attach)              │
│                L503 (Phase 8)                                                     │
│   Reverse index: NONE. `deploymentKeyForId` is a one-way hash and is read by      │
│                  NO contract in src/ (grep: 1 declaration, 1 push, 0 reads).      │
│                                                                                   │
│ PAIR 3: deployments[i]  <->  deploymentKeyForId[i]                                │
│   Invariant: same index describes the same launch                                 │
│   Written at:  L502, L503 — adjacent, no external call between. HOLDS.            │
│                                                                                   │
│ PAIR 4: monolithBeneficiary  <->  ∀i : owner(deployments[i].monolithVesting)      │
│   Invariant implied by the two-step handoff + `MonolithBeneficiaryTransferred`:   │
│              "the monolith beneficiary" is one position                           │
│   Written at:  L175 / L268 (pointer)   L470 (per-deployment snapshot)             │
│   ***BROKEN BY DESIGN OF THE ROTATION.*** N wallets, no migration, no index.      │
│                                                                                   │
│ PAIR 5: PredictedAddresses (10 fields)  <->  Deployment (10 matching fields)      │
│   Invariant: prediction must equal deployment for every component                 │
│   9 of 10 unconditional and exact. `deployerVesting` is predicted unconditionally │
│   (L245) and deployed only when allocation.deployerVesting != 0 (L473).           │
│   Prediction does not consult `usedDeploymentKeys`, `_validate`, or               │
│   `stakingTokenChoice`.                                                           │
│                                                                                   │
│ PAIR 6: allocationFor(bps) (declared split)  <->  GOV balances of the 5 recipients│
│   Invariant: each declared amount lands at its named recipient                    │
│   Holds exactly when `deployerRecipient` is an outside address; diverges silently │
│   whenever it is one of the system's own (predicted) addresses.                   │
│                                                                                   │
│ PAIR 7: deployments[i].lender  <->  lender.operator()                             │
│   Invariant: after Phase 5, operator == deployments[i].revenueRouter              │
│   Established at L452-453 (Phase 5), recorded at L502 (Phase 8), NEVER re-read.   │
│   Grep for the negative: the only `lender.operator()` read in src/ is L327.       │
│                                                                                   │
│ PAIR 8: vesting `_owner`  <->  `_erc20Released[GOV]`  <->  balanceOf(wallet)      │
│   Invariant: released tokens have left the wallet; the schedule is computed       │
│              against `balanceOf(this) + released(token)`                          │
│   Breaks when owner == the wallet itself (reachable via `deployerRecipient`).     │
│                                                                                   │
│ PAIR 9: monolithBeneficiary  <->  pendingMonolithBeneficiary                      │
│   `accept` clears pending (L269). `set` rejects zero (L255), so a nomination can  │
│   be replaced but never cancelled outright.                                       │
│                                                                                   │
│ PAIR 10: deployments[i].stakingToken  <->  .coin / .vault                         │
│   Written in one expression (L433-435). HOLDS. `.vault` itself may be zero on     │
│   the attach path (Pass 1 FF-06).                                                 │
└──────────────────────────────────────────────────────────────────────────────────┘
```

### Absence claims, each verified by an explicit grep for the negative

| claim | evidence |
|---|---|
| no registry is ever cleared | `delete `, `.pop()`, `= false` — **zero hits** in all three scope files |
| `hasCoinDAO` is written exactly once | L359, `= true`. Reads at L324, L358 only |
| `usedDeploymentKeys` is written exactly once | L530, `= true`. Read at L529 only |
| `deploymentKeyForId` is never read by any contract | 1 declaration (L122), 1 push (L503), 0 reads in `src/` or `script/`; one read in `test/CoinDAOFactory.t.sol:109` |
| there is no reverse index | the only two mappings are `address=>bool` and `bytes32=>bool` (L123-124). No `key=>id`, no `lender=>id` |
| there is no migration/sweep/recover in scope | `migrate\|sweep\|recover\|rescue\|transferBeneficiary` — zero hits in the three scope files |
| no exception swallowing or arithmetic suppression in scope | `try `, `catch`, `unchecked`, `assembly` — **zero hits** in all three scope files |
| `Deployment` has no field for the creator or the immediate recipient | 14 fields, enumerated and asserted in `test_GAP2_...` |

---

## 2. Phase 2 — Mutation Matrix

`???` marks (operation, state) pairs where the coupled counterpart is **not** updated in the same
step; `[GAP-n]` marks the ones that survived Phase 3 cross-checking.

| State variable | Mutating function | Type of mutation | Coupled state updated in the same step? |
|---|---|---|---|
| `usedDeploymentKeys[key]` | `deploy` L300 → `_reserveDeploymentKey` L530 | set `true` (BEFORE the first external call) | `deploymentKeyForId` ✗ — pushed 200 lines later **[GAP-1]** |
| `usedDeploymentKeys[key]` | `deployForExistingCoin` L333 → L530 | set `true` (AFTER 4 view calls, BEFORE `acceptOperator`) | `deploymentKeyForId` ✗ **[GAP-1]** |
| `usedDeploymentKeys[key]` | *(any release/clear)* | — | **does not exist** — monotone |
| `hasCoinDAO[lender]` | `_deployCoinDAO` L359 (Phase 1) | set `true` | `deployments` ✗ — pushed at Phase 8 **[GAP-1]** |
| `hasCoinDAO[lender]` | *(any clear)* | — | **does not exist** — a consumed lender is consumed forever (Pass 1 FF-03) |
| `deployments[]` | `_deployCoinDAO` L502 (Phase 8) | push | `deploymentKeyForId` ✓ (L503, adjacent) |
| `deploymentKeyForId[]` | `_deployCoinDAO` L503 (Phase 8) | push | `deployments` ✓ |
| `deployments[i].deployerVesting` | L480, gated by L473 | set, **conditionally** | `PredictedAddresses.deployerVesting` ✗ — predicted unconditionally **[GAP-3]** |
| `deployments[i].deployerVesting` | *(bps == 0 path)* | left `address(0)` | the 5 % immediate recipient ✗ — no field can record it **[GAP-2]** |
| `deployments[i].vault` | `deployForExistingCoin` L337 | set from `lender.vault()` | zero-check ✗ (Pass 1 FF-06) |
| `deployments[i].revenueRouter` | L412 / recorded L502 | set | `lender.operator()` ✗ — established Phase 5, never re-read **[GAP-5]** |
| `monolithBeneficiary` | `constructor` L175 | set | — (no wallets exist yet) ✓ |
| `monolithBeneficiary` | `acceptMonolithBeneficiary` L268 | **replace pointer** | `owner()` of every prior `monolithVesting` ✗ **[GAP-6 — headline]** |
| `pendingMonolithBeneficiary` | `setPendingMonolithBeneficiary` L257 | set (zero rejected) | — |
| `pendingMonolithBeneficiary` | `acceptMonolithBeneficiary` L269 | clear | `monolithBeneficiary` ✓ (same function) |
| `monolithVesting._owner` | L470 `initialize(monolithBeneficiary, …)` | **snapshot of a mutable global** | nothing pins it for the caller **[GAP-7]** |
| `monolithVesting._owner` | `transferOwnership` / `renounceOwnership` (inherited) | replace / zero | `factory.monolithBeneficiary` ✗ — the factory never learns **[GAP-6]** |
| `vesting._erc20Released[GOV]` | `release(token)` (inherited) | `+= releasable` | `balanceOf(this)` ✗ **when `owner() == address(this)`** **[GAP-9]** |
| `vesting._start` / `_duration` | `initialize` only | set once | `balanceOf(this)` may change later (Pass 1 FF-005(3)) |
| GOV balance of `treasuryVesting` / `monolithVesting` / `staker` | L493 `safeTransfer(immediateRecipient, …)` | `+= immediateAllocation` when the caller names a system address | `allocationFor()` (the declared split) ✗ **[GAP-8]** |

---

## 3. Phase 5 — Parallel Path Comparison

### 3.1 The two launch entry points, per registry

| coupled state | `deploy()` | `deployForExistingCoin()` | verdict |
|---|---|---|---|
| `usedDeploymentKeys[key]` | set at L300, **before any external call** | set at L333, **after 4 view calls, before `acceptOperator()`** | asymmetric placement; both atomic, so no permanent orphan |
| `hasCoinDAO[lender]` | L359 | L359 (+ duplicate pre-check L324) | consistent |
| `deployments` / `deploymentKeyForId` | L502-503 | L502-503 | consistent |
| zero-check on `lender` / `coin` / `vault` | ✓ all three (L308) | ✗ none (L336-337) | **asymmetric** — Pass 1 FF-06 |
| `isDeployed(lender)` check | ✗ (implied by provenance) | ✓ L323 | asymmetric by design |
| id used in the event | `deployments.length` snapshot pre-push (L501) | same, **plus** `deployments.length - 1` post-push (L345) | both correct, incl. under a reentrant nested launch (executed) |
| post-condition on the operator handoff | ✗ | ✗ | consistent — and consistently absent **[GAP-5]** |

### 3.2 The three vesting-wallet owners — how each address is qualified

This is the sharpest parallel-path result in the scope. Three addresses become the owner of a
four-year GOV stream. They are qualified by three completely different standards.

| owner-to-be | source | validation | can it be a contract that cannot act? | can it be a system address? |
|---|---|---|---|---|
| `treasuryVesting._owner` | `deployment.timelock` | deployed by the factory in this transaction | no | n/a |
| `monolithVesting._owner` | `monolithBeneficiary` | **must have completed an accept-handshake** (L263) — so it is provably an address that can transact | **no** — a passive contract can never become it | no |
| `deployerVesting._owner` | `govParams.deployerRecipient` | `!= address(0)` **only when `bps != 0`** (L560) | **yes** | **yes — including the wallet itself** |

`monolithBeneficiary` is protected by exactly the property `deployerRecipient` lacks. The
two-step accept makes it impossible to hand the platform's 2 % to an address that cannot claim
it. Nothing does the same for the deployer's 0–20 %, or for the 5 % immediate allocation.
**[GAP-8, GAP-9]**

### 3.3 Rotation vs. snapshot — the two ways the beneficiary can move

| operation | effect on `factory.monolithBeneficiary` | effect on existing `monolithVesting` wallets | detectable? |
|---|---|---|---|
| `setPending` + `accept` (the designed path) | ✓ replaced | ✗ **none** | event only; no getter compares them |
| `monolithVesting.transferOwnership` (inherited) | ✗ none | ✓ that one wallet | the factory never learns |
| `monolithVesting.renounceOwnership` (inherited) | ✗ none | ✓ that one wallet, permanently bricked | the factory never learns |

Both directions of the pair have a mutation path that does not touch the other. This is the
textbook shape of RULE 1 + RULE 2.

---

## 4. Phase 7 — Masking code found

The three scope files contain **no** try/catch, no `unchecked`, no `assembly`, no `min()` cap and
no clamping ternary. That is unusual and worth saying plainly: the scope has essentially none of
masking patterns 1, 2, 4 and 5. What it does have is **patterns 3 and 6** — and they are exactly
what makes the registry gaps silent rather than loud.

**MASK-1 — pattern 6, fallback to default (`CoinDAOFactory.sol` L491-492):**
```solidity
address immediateRecipient =
    govParams.deployerRecipient == address(0) ? deployment.timelock : govParams.deployerRecipient;
```
This converts "the caller supplied no recipient" into "the treasury gets 5 %" without recording
which of the two happened. Combined with MASK-2, `deployments[i].deployerVesting == address(0)`
means **two different things** — *no deployer allocation at all* and *the deployer took 500,000
GOV liquid* — and the registry cannot distinguish them. Proven: `test_GAP2_…`. **[GAP-2]**

**MASK-2 — pattern 3, early exit on zero (`CoinDAOFactory.sol` L473 and L496):**
```solidity
if (allocation.deployerVesting != 0) { …clone + initialize… }   // L473
if (allocation.deployerVesting != 0) { …safeTransfer…       }   // L496
```
The two guards use the same predicate, so creation and funding never disagree — that half is
correct. What they do produce is a `Deployment` field whose zero is a sentinel with no meaning,
and a predicted address (L245, computed with no such guard) that the deploy path skips. **[GAP-3]**

**MASK-3 — pattern 6, default-zero struct read.** `deployments[i].vault` on the attach path is
written from an unchecked `lender.vault()` (L337). A zero there is indistinguishable from
"not applicable". Pass 1 FF-06; recorded here because it is the same mechanism as MASK-1.

**MASK-4 — pattern 6 in the base contract.** `VestingWallet.vestedAmount` reads
`balanceOf(this) + released(token)`. When `owner() == address(this)` the transfer inside
`release` is a no-op, so `released` grows while `balanceOf` does not, and the *sum* — the thing
the schedule is computed against — grows with it. The accumulator's meaning ("these tokens have
left") is silently false, and nothing reverts. Proven with numbers in **[GAP-9]**.

---

## 5. Findings

Every finding below is annotated **NEW** (this pass), **EXTENDS** (Pass 1 found part of it) or
**CONFIRMS** (Pass 1 found it; recorded here for the map, not re-graded).

---

### SI-001 — Rotating `monolithBeneficiary` is a partial operation: every wallet it has already stamped keeps the old owner

**Severity: MEDIUM** · **EXTENDS Pass 1 FF-006** (which found the *detection* half; the state half
and its unbounded growth are new) · Recon coupling pair **#14**
**Verification: PoC (Method B) — `test_GAP4_rotationLeavesEveryPriorWalletOwnedByTheOldBeneficiary`,
`test_GAP4_staleBeneficiaryExposureGrowsLinearlyWithLaunches`,
`test_GAP4_oldBeneficiaryCanStrandThePriorAllocationAfterBeingRotatedOut` — all PASS**

**Coupled pair:** `CoinDAOFactory.monolithBeneficiary` ↔ `owner()` of every
`deployments[i].monolithVesting`.

**Invariant the code advertises.** `setPendingMonolithBeneficiary` / `acceptMonolithBeneficiary`
is a complete two-step ownership handoff, and it emits
`MonolithBeneficiaryTransferred(previousBeneficiary, newBeneficiary)`. The naming, the events and
the shape all say: *the monolith beneficiary is one position, and this transfers it.*

**Breaking operation.** `acceptMonolithBeneficiary()` — `CoinDAOFactory.sol` L261-271.
- Modifies `monolithBeneficiary` (L268) and clears `pendingMonolithBeneficiary` (L269).
- Does **not** touch `owner()` on any existing `monolithVesting`. There is no loop, no migration
  function, no index of the wallets, and no event that ties them together.

The other side of the pair is written once, at L470, as a snapshot:
```solidity
monolithVesting.initialize(monolithBeneficiary, vestingStart, FOUR_YEARS);   // L470
```

**Trigger sequence (executed):**
1. Launch DAO #0. `monolithVesting_0.owner() == B1`; it holds 200,000 GOV (2 % of supply).
2. `B1.setPendingMonolithBeneficiary(B2)`; `B2.acceptMonolithBeneficiary()`.
3. `factory.monolithBeneficiary() == B2`. Launch DAO #1, #2 — their wallets are owned by B2.
4. `monolithVesting_0.owner()` is still B1, and B1 has no standing with the factory any more.

**Consequence (all executed):**
```
factory.monolithBeneficiary()      : 0x…B2B2
deployments[0].monolithVesting own : 0x…1003     <- the rotated-out party
GOV still payable to the OLD party : 200000000000000000000000
```
Scaled: with 5 launches before the rotation, **1,000,000 GOV** remains under the old
beneficiary's control, and the number grows linearly with launch count with no ceiling.

The rotation exists precisely for the case where the incumbent must be replaced — a key
compromise, a change of counterparty, an org change. In exactly that case it moves **nothing that
already exists**. Worse, chained with Pass 1 FF-003 (`renounceOwnership` is reachable on the
wrapper), the rotated-out party can destroy what it kept:
```
[PASS] test_GAP4_oldBeneficiaryCanStrandThePriorAllocationAfterBeingRotatedOut
  b1 can no longer call setPendingMonolithBeneficiary  -> reverts
  b1 can still call monolithVesting_0.renounceOwnership -> owner() == 0
  release(GOV) after that                              -> reverts
  GOV stranded by the rotated-out beneficiary: 200,000e18
```

**Why nothing detects it.** There is no `key => id` or `lender => id` index and
`deploymentKeyForId` is read by no contract (§1). The only way to enumerate the stale wallets is
an O(n) scan of `deployments` off-chain, and nothing in `src/` or `script/` performs it. The
script's `_verifyDeployment` checks twelve `code.length != 0` conditions and no owner
(Pass 1 FF-006).

**Fix (hypothesis — both failure modes priced).**
The honest first step is a **decision, not a patch**: is `monolithBeneficiary` a *position* (in
which case the rotation is incomplete) or a *default for future launches* (in which case the name
and the `Transferred` event are wrong)?
- If it is a position: give the factory a `migrateMonolithVesting(uint256 id)` that the current
  beneficiary can call, which calls `transferOwnership` on `deployments[id].monolithVesting`.
  *Prevents:* value stranded with a replaced counterparty.
  *Creates:* the factory would need to hold, or be granted, ownership of every monolith wallet —
  which means a single factory compromise reaches every platform allocation ever issued. That is
  a strictly larger blast radius than the problem it solves. A safer variant is to make the
  wallet's owner a small forwarder that reads `factory.monolithBeneficiary()` live, which trades
  the strand for a permanent runtime dependency on the factory being correct.
- If it is a default: rename to `defaultMonolithBeneficiary`, change the event to
  `…DefaultUpdated`, and say so in NatSpec. Costs nothing, and removes the false expectation that
  is the actual defect here.

---

### SI-002 — `monolithBeneficiary` is consumed mid-transaction, and no caller can pin the value they simulated against

**Severity: MEDIUM** · **EXTENDS Pass 1 FF-006** (Pass 1 proved the simulation-vs-inclusion race
and put the fix in the script; the in-transaction rotation and the factory-side framing are new)
**Verification: PoC (Method B) — `test_GAP7_rotationBetweenPredictionAndInclusionRedirectsTwoPercent`,
`test_GAP7b_beneficiaryCanBeRotatedMidLaunchBeforePhase6ReadsIt`,
`test_GAP11b_nomineeChoosesTheFlipInstantAndTakesTheNextLaunch` — all PASS**

**Coupled pair:** `monolithBeneficiary` (a mutable global) ↔ the launch parameters the caller
supplied.

**Why this is a state problem and not just a script problem.** `deploy()` and
`deployForExistingCoin()` are permissionless and take a full parameter set — but the parameter
that decides where 2 % of the new token's supply goes is **not in the parameter set**. It is read
from storage at L470, in Phase 6, roughly 110 lines and ~25 external calls after the transaction
began. `predictCoinDAOAddresses` returns the wallet *address* (which is a function of the key
only, so it is stable) and says nothing about its *owner*. Executed:

```
[PASS] test_GAP7_rotationBetweenPredictionAndInclusionRedirectsTwoPercent
  predicted monolithVesting address == deployed address   (the prediction was right)
  owner() == B2, not the B1 the launcher simulated against
  200,000 GOV redirected
```

Two independent ways the value can move under the caller:

1. **Between blocks.** `acceptMonolithBeneficiary()` is a one-transaction completion of a handoff
   whose first step is *public* (`pendingMonolithBeneficiary` is a public getter and
   `MonolithBeneficiaryTransferStarted` is emitted). The nominee alone chooses the instant, with
   no delay and no notice to anyone with a launch in flight. Executed in
   `test_GAP11b_…`: B1 launches DAO A and keeps it, B2 accepts, DAO B pays B2.
2. **Inside the launch transaction.** The lender is called at L452 (Phase 5) — *before* Phase 6
   reads the beneficiary. A lender that is also the pending beneficiary can flip the pointer from
   inside the callback. Executed:
   ```
   [PASS] test_GAP7b_beneficiaryCanBeRotatedMidLaunchBeforePhase6ReadsIt
     factory.monolithBeneficiary() before deployForExistingCoin : 0x…1003
     factory.monolithBeneficiary() after                        : the lender
     monolithVesting.owner()                                    : the lender
     2 pct redirected mid-transaction: 200,000e18
   ```
   *Stated honestly:* path 2 requires a lender contract that `monolithFactory.isDeployed()`
   accepts and that reenters — the same unverifiable external assumption as Pass 1 FF-03. Path 1
   requires nothing but the two parties the design already gives this power to. **Path 1 alone
   carries the finding.**

**Fix (hypothesis — both failure modes priced).** Add an optional expected-beneficiary parameter
to both entry points: `if (expected != address(0) && monolithBeneficiary != expected) revert;`
*Prevents:* a launcher paying 2 % to a counterparty they never agreed to.
*Creates:* every legitimate rotation now aborts in-flight launches that pinned the old value, so
the platform must coordinate rotations with launchers — a liveness cost paid by the honest path.
Making the parameter optional (zero = "don't care") keeps that cost opt-in, at the price of most
callers never using it. A timelock on `acceptMonolithBeneficiary` is the alternative; it fixes
path 1 and not path 2.
*Note:* Pass 1 FF-006 proposes the check in `_preflight`. That binds the **simulation**, which
forge does not re-run against the mined chain (Pass 1 O4). The check has to be on-chain to bind.

---

### SI-003 — `deployments[i]` records a wiring that was established three phases earlier and never verified; the lender's own registry can disagree forever

**Severity: MEDIUM (lead — conditional on external lender behaviour)** · **CONFIRMS Pass 1 FF-03**,
re-derived in registry terms; the fix-resolution measurement (M-S2) is new
· Recon coupling pair **#12**
**Verification: PoC (Method C) — `test_GAP1b_registryRecordsARouterThatDoesNotHoldTheOperatorRole`, PASS;
mutation M-S2**

**Coupled pair:** `deployments[i].revenueRouter` ↔ `IMonolithLender(deployments[i].lender).operator()`.

Phase 5 (L452-453) moves the operator role; Phase 8 (L502) writes the record. Nothing between
them, or after, reads the role back. Grep for the negative: the only `lender.operator()` read in
the entire tree is L327, the caller check. The record is therefore a statement of *intent*, not
of *outcome*.

**Executed with a lender whose operator machinery is frozen** (a real field of the interface —
`DeployParams.timeUntilImmutability` — makes this shape plausible):
```
[PASS] test_GAP1b_registryRecordsARouterThatDoesNotHoldTheOperatorRole
  factory.hasCoinDAO(lender)            : true
  deployments[0].revenueRouter          : 0x…  (the router)
  lender.operator()                     : the original EOA — never moved
  the two registries disagree, permanently
  retry: deployForExistingCoin -> CoinDAOAlreadyExists
```

**Resolution measurement (new).** I applied Pass 1's proposed post-condition as mutation **M-S2**:
```solidity
if (IMonolithLender(deployment.lender).operator() != deployment.revenueRouter) revert …;
```
- All **19** project factory tests still pass → the fix is compatible with every intended flow.
- `test_GAP1b_…` flips from PASS to `revert` → the fix has resolution on exactly this case.

That is the missing evidence for Pass 1 FF-03's recommendation: it costs one STATICCALL, breaks
nothing, and catches the case. The residual cost is that the factory becomes intolerant of a
lender whose `operator()` getter is non-standard — turning a silent success into a hard failure,
which is the right trade but must be paired with confirming the real Monolith ABI.

---

### SI-004 — The four registries are written in three phases; two of them are true seven phases before the other two record the launch

**Severity: LOW (informational — the current write order is the correct one)** · **NEW**
· Recon coupling pair **#9** · relates to Pass 1 FF-11
**Verification: PoC (Method B) — `test_GAP1_inFlightObserverSeesHasCoinDAOTrueAndAnEmptyRegistry`, PASS;
mutations M-S1 (with a purpose-built attack) and M-S3**

**Coupled pairs 1 and 2.** Executed from inside the launch, at the L452 callback:
```
[PASS] test_GAP1_inFlightObserverSeesHasCoinDAOTrueAndAnEmptyRegistry
  in-flight hasCoinDAO[lender] : true
  in-flight usedKeys[key]      : true
  in-flight deploymentsLength  : 0        <- registries 1 and 2 have no record of it
  after the transaction        : 1
```
Any contract the factory calls during the launch — and every contract *they* call — observes a
lender that "has a CoinDAO" and a key that is "spent" for a launch that does not exist in the
record array. Because there is no reverse index (SI-005), such an observer cannot even discover
that the record is merely pending rather than missing.

**Both failure modes priced by execution — this is the important part.**
The obvious "fix" is to move the `hasCoinDAO` write to Phase 8 so the registries agree at every
observable instant. I applied it as mutation **M-S1** and measured both sides:

| | project factory suite | double-attach attack |
|---|---|---|
| original source | 19/19 pass | reverts `CoinDAOAlreadyExists`, `deploymentsLength == 0` |
| **M-S1 applied** | **19/19 still pass** | **succeeds** |

Under M-S1 a lender that reenters `deployForExistingCoin` for *itself* during Phase 5 produces:
```
[PASS] test_MS1_priceOfMovingTheHasCoinDAOWriteToPhase8   (mutation build)
  deploymentsLength    : 2
  deployments[0].lender: 0x3381…440f
  deployments[1].lender: 0x3381…440f      <- TWO registry entries for ONE lender
  GOV minted           : 20,000,000       <- two full supplies for one revenue stream
```
Pass 1's mutation M7 established that moving this write leaves all 19 tests green and concluded
"the project's tests never exercise what it protects". **This pass built the test that does.**
The L357 comment ("reserve the lender before external calls") is exactly right, the write order is
correct as shipped, and the registry window is the *price* of that correctness rather than a
defect to be fixed by reordering.

**What is actually worth changing** is therefore not the order but the observability: a
`nonReentrant` on both entry points would close the window without moving any write (Pass 1 FF-11
showed via M8 that the Phase-5 placement is a free choice), and the registry gap would become
unobservable rather than merely harmless.

**Coverage note (mutation M-S3).** Corrupting the value pushed into `deploymentKeyForId` fails
exactly **1 of 19** project tests — `testFreshLaunchPredictsProxiesAndWiresCanonicalDeployment`,
which checks index 0 on the `deploy()` path only. The `deployForExistingCoin` path's key recording
is asserted nowhere.

---

### SI-005 — `deploymentKeyForId` is write-only, and no reverse index exists, so none of the registry pairs can be checked by any contract

**Severity: LOW** · **NEW**
**Verification: grep for the negative (level 2) + the mutation-resolution measurement above**

`bytes32[] public deploymentKeyForId` (L122) is pushed at L503 and read by **no contract** in
`src/` or `script/`. Its contents are `keccak256(abi.encode(creator, userSalt))` — a one-way hash,
so `id → creator` is not recoverable from it either. The two mappings are `address => bool` and
`bytes32 => bool`. There is no `mapping(bytes32 => uint256) keyToId` and no
`mapping(address => uint256) lenderToId`.

The consequences compose with every other finding in this pass:

| question a contract might ask | answerable on-chain? |
|---|---|
| "which deployment belongs to lender L?" | only by an O(n) scan of `deployments` |
| "which deployment consumed key K?" | only by an O(n) scan of `deploymentKeyForId` |
| "who created deployment i?" | **no** — the `Deployment` struct has no `creator` field and the key is a hash |
| "does `hasCoinDAO[L]` agree with `deployments`?" | only by an O(n) scan |
| "which `monolithVesting` wallets still have the old owner?" (SI-001) | only by an O(n) scan plus 1 external call each |

Every one of those is answerable from events. None is answerable from state, which is what an
integrating contract has. This is the reason SI-001 through SI-004 are all *silent*.

**Fix.** Add `mapping(address lender => uint256 id)` and `mapping(bytes32 key => uint256 id)`
alongside the booleans (with an explicit `+1` offset or a separate existence flag so that
"id 0" and "absent" are distinguishable), or add a `creator` field to `Deployment`.
*Prevents:* an integrator having to trust an off-chain index.
*Creates:* two extra `SSTORE`s per launch in an already ~7.8 M-gas transaction (negligible), and
a second copy of the "does this lender have a DAO" fact that can itself drift from `hasCoinDAO`
if only one is ever written — the fix must replace `hasCoinDAO`, not sit beside it.

---

### SI-006 — A consumed deployment key permanently reserves a component address that is never occupied

**Severity: LOW** · **EXTENDS Pass 1 FF-08** (which found the prediction lie; the permanence,
caused by key consumption, is new) · Recon coupling pair **#10**
**Verification: PoC (Method B) — `test_GAP3_consumedKeyPermanentlyReservesAVacantPredictedAddress`, PASS**

**Coupled pair:** `usedDeploymentKeys[key]` ↔ the ten CREATE2/EIP-1167 addresses derived from
that key.

`predictCoinDAOAddresses` computes `predicted.deployerVesting` unconditionally (L245-247);
`_deployCoinDAO` clones it only when `allocation.deployerVesting != 0` (L473). At
`deployerStakeBps == 0`, nine of the ten addresses receive code and the tenth never does — and
because `usedDeploymentKeys[key]` is set and never cleared, the factory's **only** code path that
could ever `cloneDeterministic` at that salt is permanently closed. Since both `cloneDeterministic`
and `new{salt:}` fix the deployer to the factory, no other party can occupy it either.

```
[PASS] test_GAP3_consumedKeyPermanentlyReservesAVacantPredictedAddress
  predicted deployerVesting : 0x12a8265B1b2149d1Ea2170330659Fd8B07A2265f
  code.length               : 0
  deployments[0].deployerVesting : 0x0
  usedDeploymentKeys[key]        : true
  re-deploy with the same salt   : DeploymentKeyAlreadyUsed
```

**Consequence.** An integrator that pre-approves, whitelists or monitors the ten predicted
addresses is left holding one that will never exist. A UI that renders them shows a link to
nothing. There is no on-chain way to learn that the tenth is dead other than checking
`code.length` after the fact — and `deployments[i].deployerVesting == address(0)` is
indistinguishable from the "deployer took it liquid" case (MASK-1).

**Fix.** Return `address(0)` from `predictCoinDAOAddresses` when
`allocationFor(govParams.deployerStakeBps).deployerVesting == 0`, mirroring the deploy path's own
guard. *Prevents:* the dead address. *Creates:* nothing — the two guards then use the same
predicate, which is what makes them impossible to drift apart.

---

### SI-007 — `predictCoinDAOAddresses` ignores `usedDeploymentKeys`, so on a spent key it returns nine live addresses belonging to a different launch

**Severity: LOW** · **NEW**
**Verification: PoC (Method B) — `test_GAP6_predictionForAConsumedKeyReturnsLiveForeignAddresses`, PASS**

**Coupled pair:** `usedDeploymentKeys[key]` ↔ the meaning of a prediction made for that key.

Nine of the ten predicted addresses depend only on `key = keccak256(creator, userSalt)`. The
tenth — the governor — additionally depends on `govParams.govTokenName`. `predictCoinDAOAddresses`
consults neither `usedDeploymentKeys` (so it will predict for a key that can never be used again)
nor `_validate` (Pass 1 FF-08, so it will predict for parameter sets `deploy()` would reject).

```
[PASS] test_GAP6_predictionForAConsumedKeyReturnsLiveForeignAddresses
  launch A with salt S, name "Alpha GOV"
  predict(creator, S, name "Beta GOV") ->
    govToken, staker, timelock, revenueRouter, coinStakingRewards,
    coinStakingRewardsFunder, treasuryVesting, monolithVesting
      == Alpha's LIVE contracts (code.length > 0)
    governor
      == a different address with no code
```

A caller who checks "does the predicted govToken have code?" as a liveness test gets `true` for a
launch that will never happen, wired to another DAO's contracts. The single field that would have
warned them is the one that silently differs.

**Fix.** `if (usedDeploymentKeys[key]) revert DeploymentKeyAlreadyUsed(key);` in
`predictCoinDAOAddresses`, and call `_validate(govParams)`.
*Prevents:* a prediction that describes somebody else's DAO.
*Creates:* the function stops being usable as an *address lookup* for an existing launch — which
some integrator may already rely on, since it is currently the only way to get a deployment's
component addresses without an O(n) scan (SI-005). Ship the reverse index (SI-005) first, or the
fix removes a capability before its replacement exists.

---

### SI-008 — The registry has no field that can record where the 5 % immediate allocation went

**Severity: LOW** · **EXTENDS Pass 1 FF-002 (governance)**, which found the symptom; the
struct-completeness proof is new
**Verification: PoC (Method B) — `test_GAP2_registryHasNoFieldThatCanRecordTheImmediateRecipient`, PASS**

**Coupled pair:** `GovToken._balances[immediateRecipient]` ↔ `deployments[i]`.

`_validate` requires `deployerRecipient != 0` only when `deployerStakeBps != 0` (L560). It does
not reject a non-zero recipient when the stake is zero. In that configuration L473 skips the
wallet, L491-493 pays the recipient 500,000 GOV, and the record stores `deployerVesting == 0`.

```
[PASS] test_GAP2_registryHasNoFieldThatCanRecordTheImmediateRecipient
  balanceOf(0x…Beef01)              : 500,000e18   (5 % of supply)
  deployments[0].deployerVesting    : 0x0
  all 14 struct fields checked      : none names the recipient
  balanceOf(timelock)               : 0            (the treasury got none of it)
```

The `Deployment` struct has 14 fields and **none of them is a party**: no `creator`, no
`deployerRecipient`, no `immediateRecipient`. `deploymentKeyForId[i]` is a hash of the creator, so
it cannot be inverted (SI-005). The only on-chain trace of who received 5 % of a launch's supply is
the ERC20 `Transfer` log.

**Fix.** Add `address creator` and `address immediateRecipient` to `Deployment`.
*Prevents:* a launch whose largest liquid payment has no on-chain record.
*Creates:* two more storage slots per launch, and a struct-layout change that breaks any indexer
already decoding the 14-field getter — which is a real migration cost for a system that is meant
to be permissionless and integrated against.

---

### SI-009 — `deployerRecipient` becomes a vesting-wallet owner and a GOV destination with no handshake and no validation, unlike every other privileged address the factory writes

**Severity: LOW** · **EXTENDS Pass 1 FF-05** (which proved the "stranded in the factory" case; the
three *silent* variants below are new, and they are worse than a strand because nothing looks wrong)
**Verification: PoC (Method B) — `test_GAP9_deployerRecipientEqualToTreasuryVestingRestatesTheSplit`,
`test_GAP9b_immediateAllocationIntoTheWrapperBreaksOneToOneBacking`,
`test_GAP9c_immediateAllocationCanBeAddedToThePlatformVestingWallet`,
plus the baseline `test_baseline_declaredSplitEqualsActualBalancesForEveryRecipient` — all PASS**

**Coupled pair:** `allocationFor(bps)` — the public, `pure`, canonical description of the split —
↔ the actual GOV balances of the five recipients.

The baseline test confirms the pair holds exactly for a well-formed launch (all five recipients,
`bps = 1500`, factory retains zero, sum equals `totalSupply`). Pass 1 already proved the *sum* is
conserved. What is not conserved is the *mapping*, and the factory lets the caller break it with
one unvalidated field. Three executed variants:

**(a) `deployerRecipient = predicted.treasuryVesting`.** The 5 % "immediate" allocation is paid
into the treasury's four-year wallet, created one phase earlier with `start = block.timestamp`:
```
allocationFor().treasuryVested : 2,800,000e18
actual treasuryVesting balance : 3,300,000e18
```
The declared split and the on-chain reality disagree by 500,000 GOV, and the tokens described as
*immediate* are now on a four-year schedule. No revert, no event, no registry field records it.

**(b) `deployerRecipient = predicted.staker`.** 500,000 GOV lands inside the `StakedGovToken`
ERC20 wrapper with no stGOV minted against it, breaking recon coupling pair **#6** (1:1 backing)
from block zero:
```
GOV held by the wrapper : 500,000e18
stGOV total supply      : 0
recover(address) call   : reverts (OZ's ERC20Wrapper._recover is internal; StakedGovToken does
                                   not expose it — verified by call and by grep)
```

**(c) `deployerRecipient = predicted.monolithVesting`.** The deployer's 5 % is added to the
platform's 2 % wallet: `200,000 → 700,000e18`, owner unchanged.

**Contrast — the parallel path that got this right.** `monolithBeneficiary`, the other address the
factory installs as a vesting-wallet owner, can only be set by an address that has itself called
`acceptMonolithBeneficiary()` (L263). That handshake makes it *provably* an address that can
transact, and therefore *provably* not one of the predicted component addresses. Nothing imposes
the same standard on `deployerRecipient`, which is written into `deployerVesting.initialize` at
L479 and used as a `safeTransfer` destination at L493.

**Fix.** In `_validate`, reject `deployerRecipient == address(this)`; and in `_deployCoinDAO`,
after Phase 6, reject a recipient equal to any of the addresses the launch just created.
*Prevents:* all four variants (Pass 1 FF-05's strand plus (a), (b), (c)).
*Creates:* the second check needs the component addresses, so it cannot live in the `pure`
`_validate` and must be duplicated where the addresses exist — a guard split across two places is
exactly the shape that drifts. A cleaner alternative is to compute the ten predicted addresses
once at the top of `_deployCoinDAO` and validate against that array, which costs gas but keeps
one guard.

---

### SI-010 — A self-owned vesting wallet inflates `_erc20Released` without bound while its balance never moves

**Severity: LOW (self-inflicted; recorded because it is the purest coupled-accumulator break in scope)**
· **NEW** — sub-case of SI-009
**Verification: PoC (Method B) — `test_GAP10_selfOwnedVestingWalletInflatesTheReleasedAccumulator`, PASS**

**Coupled pair:** `VestingWallet._erc20Released[token]` ↔ `IERC20(token).balanceOf(wallet)`.
**Invariant:** `released` counts tokens that have *left* the wallet; the schedule is computed
against `balanceOf(this) + released(token)`, which is meant to be the constant principal.

Setting `deployerRecipient = predicted.deployerVesting` (legal — `_validate` only checks non-zero)
makes the wallet its own owner. `release(token)` then increments `_erc20Released` and performs a
self-transfer, so the *balance* is unchanged while the accumulator grows — and because the
schedule's base is `balance + released`, the base grows too, on every call, for ever. Executed at
the half-way point of the four-year schedule:

```
principal held by the wallet : 2,397,959.183673469387755102 GOV
  after release 1: balance 2,397,959.18…  released 1,198,979.59…
  after release 2: balance 2,397,959.18…  released 1,798,469.38…
  after release 3: balance 2,397,959.18…  released 2,098,214.28…
  after release 4: balance 2,397,959.18…  released 2,248,086.73…
  after release 5: balance 2,397,959.18…  released 2,323,022.95…
not one token left the wallet, and the accumulator converges upward on the principal
```
Algebraically, with `f = elapsed/duration`, `R` converges to `P·f/(1−f)` — unbounded as the
schedule matures. Every GOV in the wallet is permanently unreachable, and the wallet's own
`released()` getter reports a number that is entirely fictitious.

**Fix.** Covered by SI-009's fix (reject system addresses as `deployerRecipient`). A defence in
depth in the wrapper — `if (owner() == address(this)) revert;` in an overridden `release` — would
also close it, but `CoinDAOVestingWallet` overriding `release` is a larger change than the problem
warrants, and Pass 1 FF-003/FF-005 already argue the wrapper's override surface is a decision to
be made deliberately rather than piecemeal.

---

### SI-011 — A pending beneficiary nomination cannot be cancelled, only replaced

**Severity: LOW (informational)** · **NEW**
**Verification: PoC (Method B) — `test_GAP11_pendingBeneficiaryCannotBeSetBackToZero`, PASS**

**Coupled pair:** `pendingMonolithBeneficiary` ↔ `monolithBeneficiary` (recon pair #14's other half).

`setPendingMonolithBeneficiary` rejects `address(0)` (L255), and there is no `cancel`. Once B1 has
nominated B2, B1 cannot withdraw the nomination — it can only overwrite it with another address.
The only way to clear the slot is a **self-nomination round trip**: `setPending(B1)` then
`accept()` from B1, which sets `monolithBeneficiary = B1` and `pending = 0`. That is two
transactions, and B2 can accept at any point during either of them.

```
[PASS] test_GAP11_pendingBeneficiaryCannotBeSetBackToZero
  setPendingMonolithBeneficiary(address(0)) -> ZeroAddress()
  setPending(b1) + accept() from b1         -> pending cleared, beneficiary unchanged
```

Combined with SI-002, an incumbent who nominates and then changes their mind is exposed for as
long as it takes them to notice and execute the round trip — during which the nominee can take
the next launch's 2 %.

**Fix.** Allow the incumbent to clear the slot: `if (pendingBeneficiary == address(0)) { delete
pendingMonolithBeneficiary; emit …; return; }` before the zero-check, or add an explicit
`cancelPendingMonolithBeneficiary()`.
*Prevents:* a nomination the incumbent can no longer retract in one transaction.
*Creates:* nothing material — the zero-check at L255 exists to stop `monolithBeneficiary` from
ever becoming zero, and clearing the *pending* slot cannot do that (`accept` requires
`msg.sender == pending`, and `msg.sender` is never `address(0)` on-chain).

---

## 6. Hypotheses tested and REFUTED

Recorded so Stage 3 does not re-derive them.

| hypothesis | how it was killed |
|---|---|
| `deployments[]` and `deploymentKeyForId[]` can drift apart under reentrancy | Pushed at L502/L503 with no external call between. Executed a nested launch inside the outer launch's Phase 5: `deploymentsLength == 2`, nested key at id 0, outer key at id 1, `deployments(1).lender` == the outer lender. `test_arraysStayInLockstepAcrossAReentrantNestedLaunch` PASS. Confirms Pass 1's refutation with an adversarial rather than a happy-path test. |
| `emit CoinDAOAttached(deployments.length - 1, …)` (L345) can name the wrong id when a nested launch pushes first | The outer push is always the last one before the emit, because Phase 8 follows every reentrancy-capable call. Verified by the same executed nested-launch test. |
| A key can be reserved without a matching `deployments` entry surviving the transaction | Both reservation sites are followed by `_deployCoinDAO` in the same call frame, and every failure between them reverts the whole transaction. `deploy()`: L300 → L307-310 (can revert) → L312. `deployForExistingCoin()`: L333 → L341 → L343. Traced (level 3); no `try`/`catch` anywhere in scope to break atomicity. |
| A third party can seize a lender during the L341/L452 windows by reentering `deployForExistingCoin` for the same lender | Blocked in both directions: the reentrant caller's `msg.sender` is the lender contract, which never equals `lender.operator()` at either instant (the operator is the original EOA before `acceptOperator`, the factory after). Confirmed by the `DoubleAttachLender` experiment, which only succeeds once the mock *forges* `operator = address(this)` — and even then reverts `CoinDAOAlreadyExists` under the original source. |
| `hasCoinDAO` can hold `true` for two different `deployments` entries | Guarded by the check-then-set at L358-359 *before* any external call. Proven load-bearing by mutation M-S1 (removing that placement produces exactly this corruption). |
| `monolithBeneficiary` could be set to a vesting wallet or other passive contract, orphaning the 2 % | Impossible: `acceptMonolithBeneficiary` (L263) requires the incoming address to transact. This is the one place the codebase gets the qualification right — and the contrast is what produced SI-009. |
| `acceptMonolithBeneficiary` can be hijacked when `pendingMonolithBeneficiary == address(0)` | Requires `msg.sender == address(0)`, unreachable on-chain. |
| Predicted addresses can be front-run and occupied by a third party | Re-confirmed, not re-derived: CREATE2 and EIP-1167 both fix the deployer to the factory. Every predicted-vs-deployed equality in this pass's tests held. |
| The `stakingToken` field can disagree with `coin`/`vault` | Written in one expression (L433-435); no other writer. |

---

## 7. Verification summary

| ID | Coupled pair | Breaking operation | Verdict | Severity | vs Pass 1 |
|---|---|---|---|---|---|
| SI-001 | `monolithBeneficiary` ↔ ∀ `monolithVesting._owner` | `acceptMonolithBeneficiary` L268 | TRUE POSITIVE | **MEDIUM** | **EXTENDS** FF-006 |
| SI-002 | `monolithBeneficiary` ↔ the caller's parameter set | read at L470 with no pin | TRUE POSITIVE | **MEDIUM** | **EXTENDS** FF-006 |
| SI-003 | `deployments[i].revenueRouter` ↔ `lender.operator()` | L452-453 unverified, recorded L502 | TRUE POSITIVE (conditional on external lender) | **MEDIUM** | **CONFIRMS** FF-03 (+ fix resolution measured) |
| SI-004 | `hasCoinDAO`/`usedDeploymentKeys` ↔ `deployments`/`deploymentKeyForId` | write order across Phases 1/8 | TRUE POSITIVE (informational) | LOW | **NEW** (relates to FF-11; M7 gap closed) |
| SI-005 | all four registries ↔ each other | no reverse index exists | TRUE POSITIVE | LOW | **NEW** |
| SI-006 | `usedDeploymentKeys[key]` ↔ the 10 derived addresses | L473 guard vs L245 prediction | TRUE POSITIVE | LOW | **EXTENDS** FF-08 |
| SI-007 | `usedDeploymentKeys[key]` ↔ prediction validity | `predictCoinDAOAddresses` L197 | TRUE POSITIVE | LOW | **NEW** |
| SI-008 | `GovToken._balances[recipient]` ↔ `deployments[i]` | L491-493 + struct shape | TRUE POSITIVE | LOW | **EXTENDS** FF-002 |
| SI-009 | `allocationFor(bps)` ↔ actual recipient balances | `deployerRecipient` unvalidated | TRUE POSITIVE | LOW | **EXTENDS** FF-05 |
| SI-010 | `_erc20Released[GOV]` ↔ `balanceOf(wallet)` | `release()` on a self-owned wallet | TRUE POSITIVE | LOW | **NEW** |
| SI-011 | `pendingMonolithBeneficiary` ↔ `monolithBeneficiary` | no cancel path | TRUE POSITIVE | LOW | **NEW** |

**False positives eliminated:** 0 raised-then-withdrawn; 8 hypotheses refuted before write-up (§6).

**Verification levels reached** (per `CLAUDE.md`):
- **Level 4** (executed in a real EVM): SI-001, SI-002, SI-004, SI-006, SI-007, SI-008, SI-009, SI-010, SI-011, and all three mutations.
- **Level 4 with a substituted external contract**: SI-003, and path 2 of SI-002 — both stated as conditional.
- **Level 2 with explicit negative greps**: SI-005, and every absence claim in §1.
- **Resolution checked** (mutate the prediction, confirm the check can fail): M-S1 flips
  `test_GAP1_…`; M-S2 flips `test_GAP1b_…`; M-S3 flips exactly 1 of 19 project tests.

---

## 8. Mutation log

| # | mutation | project suite | effect on this pass's tests | what it proves |
|---|---|---|---|---|
| M-S1 | move `hasCoinDAO[lender] = true` from Phase 1 (L359) to Phase 8 | **19/19 pass** | `test_GAP1_…` flips to FAIL; `test_MS1_…` double-attach **succeeds** — 2 records for 1 lender, 20 M GOV | the Phase-1 reservation is load-bearing against a malicious lender, and the project's own tests cannot see it. Closes the open question left by Pass 1's M7. |
| M-S2 | add `if (lender.operator() != revenueRouter) revert` after L453 | **19/19 pass** | `test_GAP1b_…` flips to revert | Pass 1 FF-03's proposed fix is compatible with every intended flow and catches the case it is for |
| M-S3 | push a wrong value into `deploymentKeyForId` (L503) | **1/19 fail** | — | registry 2 has one assertion in the whole project, on id 0 of the `deploy()` path only |

All three reverted; `src/CoinDAOFactory.sol` verified byte-identical to the audited tree after
each, and the audited tree re-verified 55/55.

---

## 9. Hand-off to Stage 3 (fusion)

**The three intersections most likely to produce something neither lens found alone:**

1. **SI-001 × FF-003 × FF-001.** SI-001 leaves N platform wallets under a rotated-out owner;
   FF-003 lets any such owner brick its wallet permanently; FF-001 lets a 0.1 %-supply attacker
   capture the Timelock, which owns `treasuryVesting`. All three converge on the same object —
   `CoinDAOVestingWallet` — whose entire attack surface is *inherited and unconstrained*. The
   fused question is whether the wrapper's override surface should be closed as one decision
   rather than three findings.
2. **SI-009(b) × FF-04.** SI-009(b) puts 500,000 unbacked GOV inside `StakedGovToken` at launch;
   FF-04 shows a 1-wei stGOV holder absorbs 100 % of a revenue distribution. The fused question:
   does unbacked underlying in the wrapper change who the "first staker" is, or what
   `rewardPerTokenStored` is measured against? That is Pass 1's open question #2 and it now has a
   concrete way to reach a non-canonical wrapper state from the factory.
3. **SI-004/M-S1 × FF-11.** Pass 1 found the Phase-5 external call is a free placement (M8) and
   found no exploit. This pass built the reentrancy harness and showed the *only* thing standing
   between a malicious lender and a duplicated launch is the L359 write order. The fused question
   is whether `nonReentrant` plus M8's reordering makes the L359 placement free again — and
   whether anything else in the eight phases is protected only by write order.

**Open question this pass could not answer.** SI-003 and SI-002-path-2 both turn on whether the
real Monolith lender can silently no-op or reenter. That contract is not in this tree. Both are
delivered as leads with the condition stated, per `CLAUDE.md` ("a false positive costs more than
a missed LOW").

---

## 10. Coverage statement

- **Coupled state pairs mapped:** 10 (recon pairs #9, #10, #12, #13, #14 all resolved; #6 touched
  via SI-009(b)).
- **Mutation paths analysed:** 21 (state variable × mutating function), covering **every** write
  to every storage variable in the three scope files — verified by grep that no write was missed.
- **Functions in scope covered:** 14 of 14 in `CoinDAOFactory` (all six external/public, both
  launch entry points, the orchestrator, all five internal helpers), 4 of 4 library functions,
  and the full inherited surface of `CoinDAOVestingWallet` reachable from the factory's usage.
- **Raw findings (pre-verification):** 11. **After verification:** 11 TRUE POSITIVE,
  0 FALSE POSITIVE, 8 hypotheses refuted.
- **Final: 0 CRITICAL · 3 MEDIUM · 8 LOW.**
- **NEW vs Pass 1:** 5 NEW (SI-004, SI-005, SI-007, SI-010, SI-011), 5 EXTENDS
  (SI-001, SI-002, SI-006, SI-008, SI-009), 1 CONFIRMS (SI-003).
- **Execution:** 19 PoC tests written, 19 pass; 3 source mutations. Full tree 74/74 with the
  audited sources byte-identical.
- **Nothing in this pass is "not proven by execution"** except SI-005, which is an absence claim
  about the code's shape and has no runtime behaviour to execute — verified by explicit negative
  greps instead, reason recorded.
- **Client code was not modified.** All experiments ran on a disposable copy under the session
  scratchpad; `diff -rq` against `[scratch]` is clean and the audited tree's own suite is
  55/55.

**The single most important line in this pass:** `CoinDAOFactory.sol` L470 —
`monolithVesting.initialize(monolithBeneficiary, vestingStart, FOUR_YEARS);`
It reads a mutable global into an immutable per-deployment owner. Every one of SI-001, SI-002 and
SI-011 is a consequence of that one dereference having no counterpart anywhere in the contract.
