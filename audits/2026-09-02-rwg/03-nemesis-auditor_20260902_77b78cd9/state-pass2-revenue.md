# State Inconsistency Auditor — Pass 2 (Revenue / Staked-GOV lane)

**Skill:** `.claude/skills/state-inconsistency-auditor/SKILL.md`, Phases 1–8, executed in full.
**Language detected:** Solidity 0.8.26 / via-ir / optimizer 200 / Foundry. OZ **5.6.1**.

**Scope (line-by-line):**

| file | lines | role |
|---|---|---|
| `[scratch]` | 189 | non-transferable ERC20Wrapper + Votes + instant-accrual reward accumulator |
| `[scratch]` | 99 | permanent Lender operator; pulls reserves, splits Coin |

**Cross-file context read (not audited):** `src/interfaces/*`, `src/GovToken.sol`,
`src/CoinDAOGovernor.sol`, `src/CoinDAOFactory.sol` (wiring phases 2/5 + constants),
`test/StakedGovToken.t.sol`, `test/RevenueRouter.t.sol`, `test/mocks/*`.
OZ base implementations (`ERC20WrapperUpgradeable`, `ERC20VotesUpgradeable`,
`ReentrancyGuard`) were traced **from the scratchpad copy**, not from `[scratch]`,
solely to discharge Phase 3 step 3 ("trace internal calls for hidden updates").
**Not read, per instruction:** `[scratch]`, `engagements/`.

**Enrichment consumed before starting:** `nemesis-phase0-recon.md` §Q0.5 (14-row coupling
hypothesis) and `feynman-pass1-revenue.md` (all 19 FF findings + the handoff table).
The governance-lane Pass 1 file was consulted **only** to attribute overlap correctly.

**Given, not re-derived** (per instruction): `Lender.pullLocalReserves()` is a complete
drain that early-returns on nothing-to-pull. Every conclusion below is built on that.

**Execution.** The scope tree was copied to `…/[scratch]` (the audited tree at
`[scratch]` was **not** written to; `diff -r st2/src [scratch]` is empty and
the repo's own 55/55 suite is green in the copy). PoCs:

- `…/[scratch]` — **18/18 pass**
- `…/[scratch]` — **9/9 invariants, 20,480 calls, pass**

Verification levels used: **L1** compiles · **L2** a check passes · **L3** the check could
have failed (a control or a mutation is included) · **L4** executed.

---

## Phase 1 — Coupled State Dependency Map

Storage confirmed by `forge inspect … storage-layout`, not by reading declarations:

```
StakedGovToken (clone, no upgrade path)
  slot 0  rewardsToken            IERC20
  slot 1  revenueRouter           IRevenueDistributor
  slot 2  rewardPerTokenStored    uint256
  slot 3  userRewardPerTokenPaid  mapping(address=>uint256)
  slot 4  rewards                 mapping(address=>uint256)
  + ERC-7201 namespaced: ERC20$, ERC20Permit$/EIP712$, Nonces$, Votes$, ERC20Wrapper$,
                         Initializable$, ReentrancyGuard$

RevenueRouter (clone, no upgrade path)
  slot 0  lender          slot 1  coin        slot 2  treasury
  slot 3  govStaking (offset 0, 20 bytes)  +  govStakingBps (offset 20, 2 bytes)  <- packed
  + ERC-7201 namespaced: Ownable$, Initializable$
```

> Note for the map: `govStaking` and `govStakingBps` **share slot 3**. Every
> `setGovStakingBps` therefore rewrites the word that also holds the reward receiver's
> address. Solidity's read-modify-write makes this safe; recorded because the two values
> are semantically coupled *and* physically colocated, and a future non-clone upgrade path
> would make the packing load-bearing.

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│ COUPLED STATE DEPENDENCY MAP — 14 pairs                                                │
├────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                        │
│ P1  ERC20$._balances[a]  ↔  userRewardPerTokenPaid[a]  ↔  rewards[a]                    │
│     INVARIANT: a must be settled at the CURRENT rewardPerTokenStored *before* its       │
│                balance moves, or the historical delta is applied to the wrong balance.  │
│     Mutation points: depositFor, withdrawTo, withdraw, harvestAndWithdraw               │
│                                                                                        │
│ P2  ERC20$._totalSupply  ↔  rewardPerTokenStored                                        │
│     INVARIANT: the supply used as the divisor in notifyRewardAmount must be the supply  │
│                entitled to that reward.                                                 │
│     Mutation points: notifyRewardAmount (writer) vs depositFor / withdrawTo (divisor)   │
│                                                                                        │
│ P3  rewardPerTokenStored  ↔  userRewardPerTokenPaid[a]                                  │
│     INVARIANT: urptp[a] <= rPTS, always. earned() subtracts them UNCHECKED (L141).       │
│     Mutation points: notifyRewardAmount (+= only) / updateReward (snap only)            │
│                                                                                        │
│ P4  Coin.balanceOf(StakedGovToken)  ↔  Σ_a earned(a)                                    │
│     INVARIANT: held >= owed (solvency), and held - owed must be bounded (no silent      │
│                confiscation). BOTH directions matter — see SI-010.                      │
│     Mutation points: notifyRewardAmount, _payReward, ANY external Coin transfer in      │
│                                                                                        │
│ P5  underlying() GOV balance  ↔  ERC20$._totalSupply    (ERC20Wrapper 1:1 backing)      │
│     INVARIANT: GOV held == stGOV supply. _recover() is the only re-sync and is NOT      │
│                exposed (verified against the compiled ABI).                             │
│     Mutation points: depositFor, withdrawTo, + any direct GOV transfer in               │
│                                                                                        │
│ P6  RevenueRouter.govStakingBps  ↔  un-harvested reserves inside the LENDER              │
│     INVARIANT: the split in force must be the split under which the stock accrued.      │
│     ** The second half of this pair is state in a THIRD contract, never checkpointed. **│
│     Mutation points: setGovStakingBps (writes one side), time (writes the other)        │
│                                                                                        │
│ P7  RevenueRouter.govStakingBps  ↔  Coin.balanceOf(RevenueRouter)                        │
│     INVARIANT: the split is applied to the whole balance, whatever its provenance.      │
│     Mutation points: distribute (reads both), any transfer to the router                │
│                                                                                        │
│ P8  govStaking.totalSupply()  read at RevenueRouter:72  ↔  totalSupply() read at         │
│     StakedGovToken:169                                                                  │
│     INVARIANT: the two reads, separated by an external Coin transfer, must agree.       │
│     Mutation points: coin.safeTransfer between them                                     │
│                                                                                        │
│ P9  Votes$._totalCheckpoints (the Governor quorum base)  ↔  ERC20$._totalSupply          │
│     INVARIANT: equal at every block. Held by OZ _transferVotingUnits.                    │
│                                                                                        │
│ P10 Votes$._totalCheckpoints  ↔  Σ Votes$._delegateCheckpoints                           │
│     INVARIANT (implied by GovernorVotesQuorumFraction): quorum is a fraction of the      │
│     base, and the base must be votable. Diverges by the UNDELEGATED float.               │
│                                                                                        │
│ P11 RevenueRouter.owner  ↔  {setGovStakingBps, setManager, acceptLenderOperator}          │
│     INVARIANT: an owner must exist for the split to remain governable.                   │
│                                                                                        │
│ P12 RevenueRouter.treasury (no setter)  ↔  distribute() liveness  ↔  depositFor liveness │
│     INVARIANT: the treasury must be able to receive Coin whenever treasuryAmount != 0.   │
│     ** The dependency is INACTIVE at the factory default bps == 10_000. **               │
│                                                                                        │
│ P13 StakedGovToken.revenueRouter  ↔  RevenueRouter.govStaking  (mutual, both immutable)  │
│     INVARIANT: each must name the other. Never validated at either initialize.           │
│                                                                                        │
│ P14 StakedGovToken.rewardsToken  ↔  RevenueRouter.coin  ↔  lender.coin()  ↔ underlying() │
│     INVARIANT: all three equal, and none equal to the wrapper's underlying GOV.          │
│                                                                                        │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

Recon §Q0.5 rows 4, 5, 6, 8 map to P2, P1, P5, P6 respectively. Rows 1–3, 7, 9–14 are out
of this lane's scope.

---

## Phase 2 — Mutation Matrix

Every writer, established by grepping for the negative (`grep -n` for each variable across
both files) and cross-checked against the **compiled ABI**, not against source reading.

### Absence claims — verified

```
writers of rewardPerTokenStored   : L172 ONLY  (notifyRewardAmount)
writers of rewards[a]             : L88  (updateReward)  and  L160 (_payReward)  ONLY
writers of userRewardPerTokenPaid : L89  ONLY  (updateReward)
_mint / _burn / _transfer / _recover called by StakedGovToken itself : NONE
                                    (every balance change routes through the inherited
                                     ERC20Wrapper depositFor / withdrawTo)
ABI of StakedGovToken            : no recover, no sweep, no setRevenueRouter,
                                   no setRewardsToken, no pause
ABI of RevenueRouter             : no sweep, no setTreasury, no setLender,
                                   no setGovStaking, no setPendingOperator
                                   (renounceOwnership IS present)
writers of govStakingBps          : L59 (initialize), L91 (setGovStakingBps) ONLY
```

### Matrix

| # | State variable | Mutating path | Type | Settles its coupled state first? |
|---|---|---|---|---|
| 1 | `ERC20$._balances[a]`, `_totalSupply` | `depositFor(a,v)` | mint | **YES** — `harvestYield` then `updateReward(a)` |
| 2 | " | `withdrawTo(a,v)` | burn from `msg.sender` | **PARTLY** — `updateReward(msg.sender)` ✓, **no `harvestYield`** ✗ |
| 3 | " | `withdraw()` → `withdrawTo` | burn (full) | same as #2 |
| 4 | " | `harvestAndWithdraw()` | burn (full) | **YES** — harvest, settle, burn, pay |
| 5 | " | `transfer`/`transferFrom` | — | **unreachable**, `_update` reverts `NonTransferable` |
| 6 | " | `_recover` | mint | **not exposed** (ABI-verified) |
| 7 | `rewardPerTokenStored` | `notifyRewardAmount(r)` | `+=` global | n/a — moves the accumulator for **everyone**, settles **nobody** (lazy, correct) |
| 8 | `rewards[a]` | `updateReward(a)` | `= earned(a)` | ✓ paired with #9 in the same modifier |
| 9 | `userRewardPerTokenPaid[a]` | `updateReward(a)` | `= rPTS` | ✓ |
| 10 | `rewards[a]` | `_payReward(a)` | `= 0` then transfer | ✓ CEI |
| 11 | `Votes$._delegateCheckpoints` | `delegate`, `delegateBySig` | move units | ✓ OZ; **does not touch `_totalCheckpoints`** → P10 |
| 12 | `Votes$._totalCheckpoints` | every mint/burn via `_update` | ± | ✓ OZ; **not** conditional on delegation → P10 |
| 13 | `ERC20$._allowances` | `approve`, `permit` | set | writes state that `transferFrom` can never consume (FF-009) |
| 14 | `Nonces$._nonces` | `permit` | `++` | same dead surface |
| 15 | `govStakingBps` | `setGovStakingBps` | set | **NO** — does not settle P6 (FF-002; extended by SI-002) |
| 16 | `govStakingBps` | `initialize` | set | n/a |
| 17 | `Ownable$._owner` | `transferOwnership`, `renounceOwnership` | set | **NO** — `renounceOwnership` silently kills P11 (FF-010) |
| 18 | Lender `operator` | `acceptLenderOperator` | external | atomic with `setPendingOperator` in the factory (`CoinDAOFactory.sol:452-453`) |
| 19 | Lender `manager` | `setManager` | external | **NO** — does not settle P6 before changing who governs accrual |
| 20 | Lender accrued reserves → 0 | `distribute` → `pullLocalReserves` | drain | given |
| 21 | `Coin.balanceOf(RevenueRouter)` | `distribute` | full sweep | ✓ swept to zero |
| 22 | `Coin.balanceOf(StakedGovToken)` | **any direct transfer** | `+=` | **NO notify, no sweep** → SI-004 |
| 23 | `GOV.balanceOf(StakedGovToken)` | **any direct transfer** | `+=` | **NO `_recover`** → SI-005 |

Rows 2, 15, 17, 19, 22, 23 are the `???` entries that survived Phase 3.

---

## Phase 3 / Phase 4 — Cross-check and ordering

### Ordering inside each function (Phase 4)

Modifier before-code runs left to right, then the body.

| function | resolved order | verdict |
|---|---|---|
| `depositFor` | guard → **harvest** → settle(account) → mint | **correct and load-bearing.** Mutation M2 (swap harvest/settle) breaks solvency — see Phase 8. |
| `withdrawTo` | guard → settle(msg.sender) → burn → send GOV | settles P1 correctly; **omits the P6 settlement** (SI-001) |
| `harvestAndWithdraw` | guard → harvest → settle → `super.withdrawTo` → `_payReward` | correct; calls `super` deliberately to avoid self-deadlocking `nonReentrant` |
| `getReward` | guard → settle → pay | correct; no harvest by design (documented escape hatch) |
| `notifyRewardAmount` | read supply → `rPTS +=` | settles nobody, by design (lazy) |
| `distribute` | pull → read balance → **read supply #1** → transfer to staker → **read supply #2** (inside notify) → transfer to treasury | P8 spans an external call (FF-007) |

**"Can a callee observe inconsistent state?"** During `harvestYield`, `StakedGovToken` is
re-entered by `notifyRewardAmount` while its own `nonReentrant` is held and while no
account has been settled. `earned(a)` remains arithmetically correct at that instant
(the accumulator is lazy), so the window is **consistent**. Verified by trace, not assumed.

### The Phase 3 checklist, per pair

| check | result |
|---|---|
| Full removal (A → 0) resets all coupled state? | ✓ `harvestAndWithdraw` and `withdraw` both settle P1 |
| **Partial removal proportionally reduces coupled state?** | **✗ SI-001** — `withdrawTo(a, v)` reduces the balance without settling P6 |
| Increase proportionally increases coupled state? | ✓ `depositFor` harvests before minting |
| Transfer moves coupled state? | n/a — transfers revert |
| Deletion removes the paired entry? | n/a — no deletes |
| Batch updates coupled state per iteration? | n/a — no batches |

---

## Phase 5 — Parallel Path Comparison

### Group A — the four balance-changing paths

| coupled state | `depositFor` | `withdrawTo` | `withdraw()` | `harvestAndWithdraw` |
|---|---|---|---|---|
| `ERC20$._balances` / `_totalSupply` | ✓ | ✓ | ✓ | ✓ |
| `Votes$` checkpoints | ✓ (OZ) | ✓ (OZ) | ✓ (OZ) | ✓ (OZ) |
| `rewards[·]` / `userRewardPerTokenPaid[·]` | ✓ (`account`) | ✓ (`msg.sender`) | ✓ | ✓ |
| **P6 — un-harvested Lender reserves** | ✓ `harvestYield` | **✗ MISSING** | **✗ MISSING** | ✓ `harvestYield` |
| pays out `rewards[·]` | ✗ (not its job) | ✗ | ✗ | ✓ |
| `nonReentrant` | ✓ | ✓ | ✓ (via `withdrawTo`) | ✓ |

**FINDING: `withdrawTo` and `withdraw` mutate the P2 divisor without settling P6.**
Full-exit case = FF-003. **Partial-exit case = SI-001 (new).**

### Group B — the three claim paths

| coupled state | `getReward` | `harvestAndGetReward` | `harvestAndWithdraw` |
|---|---|---|---|
| settles P1 | ✓ | ✓ | ✓ |
| settles P6 | ✗ (documented) | ✓ | ✓ |
| zeroes `rewards[·]` before transfer | ✓ | ✓ | ✓ |
| changes the P2 divisor | no | no | **yes** |

Consistent. `getReward`'s missing harvest costs the caller nothing because their balance
does not move — the asymmetry is safe here and unsafe in Group A, and that is exactly the
distinction the code gets right.

### Group C — donation handling, same asset, two contracts

| Coin arrives at… | swept into the split? | accrued to `rPTS`? | recoverable? |
|---|---|---|---|
| `RevenueRouter` | **YES** — `amount = coin.balanceOf(address(this))` (L71) | yes | yes |
| `StakedGovToken` | no | **no** | **NO** — no sweep, no `_recover`, no admin |

**FINDING: SI-004.** Two contracts in the same lane, holding the same token, with exactly
opposite donation semantics and no comment explaining the difference.

### Group D — the two floor divisions on the same value

| stage | expression | rounds toward | dead-zone |
|---|---|---|---|
| router | `(amount * govStakingBps) / MAX_BPS` (L73) | **treasury** | `amount < MAX_BPS/bps` |
| staker | `mulDiv(reward, 1e18, supply)` (L172) | **stranded** (nobody) | `reward < supply/1e18` |

They compose multiplicatively. **FINDING: SI-003.**

---

## Phase 6 — Multi-step journeys

| # | sequence | result |
|---|---|---|
| J1 | deposit → accrue → **partial** withdraw → distribute → claim | **BROKEN — SI-001.** Alice 1000, Bob 1000, 100 COIN accrued (50/50). Alice `withdrawTo(500)`. Back-runner calls `distribute()`. Measured: alice **33.33**, bob **66.67**. Control (settle first): 50 / 50. |
| J2 | stake → accrue → `setGovStakingBps(↑)` → distribute | **BROKEN — SI-002.** Treasury's whole epoch re-priced to the stakers. Control: settle first → treasury keeps 100. |
| J3 | stake → accrue → full exit → supply 0 → new staker (1 wei) → huge accrual → whale enters | **SOUND.** `rPTS` reaches 1e38; the whale's `urptp` snaps to it and she earns exactly pro-rata afterwards. No overflow, no retroactive credit. (Confirms FF-016's refutation from the state side.) |
| J4 | deposit → 32 × (accrue, distribute, forced settle) vs. an identical unsettled account | **DRIFT ≤ 32 wei**, and **exactly 0** for balances that are whole multiples of 1e18 (256/256 fuzz runs each way). SI-008, INFO. |
| J5 | stake → accrue → 3rd party calls `depositFor(victim, 0)` | **Writes `rewards[victim]` and `urptp[victim]`, and forces the global harvest,** from an address with no stake, no approval, and no relationship to the victim. SI-006. |
| J6 | deploy at default bps=10000 → distribute (works) → `setGovStakingBps(9000)` → distribute | **BREAKS — SI-007.** With a Coin that refuses the treasury, the default split hides the dependency completely; the first governance change bricks `distribute()` and, through `harvestYield`, the only mint path. `withdraw()` still works. |
| J7 | 20,480 randomised calls across 4 actors incl. supply→0 epochs, 1-wei supplies, mid-flight bps changes, donations to both contracts | **9/9 invariants hold.** See Phase 8. |

---

## Phase 7 — Masking code

Every defensive construct in scope, and what it hides.

| # | location | pattern | what it masks | verdict |
|---|---|---|---|---|
| M1 | `RevenueRouter.sol:72` `if (govStaking.totalSupply() != 0)` | **Early exit on zero** | The `NoStakedSupply()` revert at `StakedGovToken:170`. Converts "this revenue has no owner" into a **silent 100 %-to-treasury reroute**, chosen by an unprivileged caller. | **Real mask.** Documented in `plan.md §7`, so intended (FF-011, INFO) — but note it masks a *different* variable's guard than the one it protects. |
| M2 | `RevenueRouter.sol:77` `if (govStakingAmount != 0)` | **Early exit on zero** | The floor division at L73 producing 0. Skips `notifyRewardAmount` entirely, so a sub-threshold harvest passes silently to the treasury with **no event distinguishing it** from a legitimate 0-bps split. | **Real mask — SI-003.** |
| M3 | `RevenueRouter.sol:81` `if (treasuryAmount != 0)` | **Early exit on zero** | At the factory default `bps == 10_000` this branch is **never taken**, so the treasury-transfer dependency (P12) is never exercised in production until governance changes the split. | **Real mask — SI-007.** |
| M4 | `StakedGovToken.sol:159` `if (reward > 0)` | **Early exit on zero** | Nothing harmful — but it is why `harvestAndWithdraw` succeeds for a zero-balance account, and why SI-004's stranded Coin cannot be reached by `getReward`. | Benign; recorded. |
| M5 | `StakedGovToken.sol:87` `if (account != address(0))` | **Fallback to default** | Vestigial Synthetix branch; **no reachable call site passes zero** (FF-015). Confirmed here: `depositFor(address(0), v)` reverts inside OZ `_mint` **before** reaching `updateReward`'s body (L4 PoC `test_SIJ`). | Dead code; the seam where time-based accrual was removed. |
| M6 | `StakedGovToken.sol:180` `if (from != address(0) && to != address(0)) revert` | **Permissive guard** | Permits `from == 0 && to == 0`, a nonsensical state. Unreachable only because OZ's `_mint`/`_burn` reject the zero address first — i.e. **the safety is entirely in a library the contract does not control.** | INFO — SI-009. |
| M7 | `StakedGovToken.sol:141` `rewardPerTokenStored - userRewardPerTokenPaid[account]` | **Unchecked subtraction** (0.8.x reverts) | Not a mask, but it is the load-bearing consequence of P3. Verified by invariant across 20,480 calls: `urptp[a] <= rPTS` always. | Sound. |
| M8 | `Math.mulDiv` at L141 and L172 | full-precision, floors | Hides both truncations under a function name that reads as "exact". | See SI-003 / SI-008. |
| M9 | absent `nonReentrant` on `notifyRewardAmount` and `distribute` | **omission** | Required: `distribute` re-enters `StakedGovToken` while its guard is held. | Correct and non-obvious. |

**Absent where you would expect it:** there is no `try/catch` anywhere in either contract,
no `min()` cap, and no SafeMath-style clamp. The masking in this lane is entirely of the
**early-exit-on-zero** family, and all three instances live in `RevenueRouter.distribute`.

---

## Phase 8 — Verification Gate

### Verification summary

| ID | Coupled pair | Breaking op | Raw | Verdict | Final | Method | vs Pass 1 |
|---|---|---|---|---|---|---|---|
| SI-001 | P1 / P6 | `withdrawTo(a,v)` partial | HIGH | TRUE POSITIVE — downgrade | **MEDIUM** | C | **extends FF-003** (partial case is new) |
| SI-002 | P6 | `setGovStakingBps` ↑ | MEDIUM | TRUE POSITIVE | **MEDIUM** | C | **extends FF-002** (reverse direction is new) |
| SI-003 | P7 / P2 | `distribute` two floors | MEDIUM | TRUE POSITIVE — downgrade | **LOW** | C | **NEW** (FF-001 measured only the notify side) |
| SI-004 | P4 | any direct Coin transfer in | MEDIUM | TRUE POSITIVE | **LOW** | C | **NEW** |
| SI-005 | P5 | any direct GOV transfer in | MEDIUM | TRUE POSITIVE — downgrade | **LOW** | C | **NEW** |
| SI-006 | P1 | `depositFor(victim, 0)` | MEDIUM | TRUE POSITIVE — downgrade | **LOW** | B | **NEW** |
| SI-007 | P12 | `setGovStakingBps` off 10 000 | MEDIUM | TRUE POSITIVE — **stated as a lead** | **LOW (lead)** | C | **NEW** (extends Pass 1 assumption #8) |
| SI-008 | P1 | repeated `updateReward` | LOW | TRUE POSITIVE | **INFO** | B | **NEW** |
| SI-009 | — | `_update` zero/zero branch | LOW | TRUE POSITIVE | **INFO** | B | **NEW** |
| SI-010 | P4 | *(methodology)* | — | TRUE POSITIVE | **INFO** | B | **NEW** |
| SI-011 | P10 | mint without delegation | HIGH | TRUE POSITIVE | — | — | **ALREADY COVERED** by governance-lane FF-011 — mapped, not re-claimed |

### Invariant suite — the verified negatives, with their resolution

`StatePass2Invariant.t.sol`, 256 runs × 80 calls = **20,480 handler calls**, 9 invariants,
**0 reverts, 0 failures**. The handler drives every path in the Mutation Matrix *including*
the ones Pass 1's fuzz did not reach: `depositFor(victim,0)` force-settles, supply→0 epochs,
1-wei supplies, mid-flight `setGovStakingBps`, and direct donations of both Coin and GOV to
both contracts.

| invariant | statement |
|---|---|
| `invariant_solvent` | `Σ earned(a) <= Coin.balanceOf(staker)` |
| `invariant_strandedIsBounded` | `Coin.balanceOf(staker) - Σ earned(a) <= donations + 1e12` |
| `invariant_potConservation` | `pot == notified + donated - paid`, exactly |
| `invariant_backed` | `GOV.balanceOf(staker) >= totalSupply()` |
| `invariant_snapshotNeverAheadOfAccumulator` | `urptp[a] <= rPTS` for every actor (P3) |
| `invariant_supplyIsSumOfBalances` | `Σ balanceOf(a) == totalSupply()` |
| `invariant_votesNeverExceedQuorumBase` | `Σ getVotes(a) <= totalSupply()` (P10) |
| `invariant_neverOverCommitted` | held >= owed |
| `invariant_callSummary` | reporting only |

**Resolution (mandatory — a green check has a resolution).** Two source mutations were
applied to the **scratchpad copy only**, run, and reverted; `diff -r st2/src
[scratch]` is empty afterwards and the repo's 55/55 suite is green.

| mutation | what it models | caught by |
|---|---|---|
| **M1** — delete `updateReward(msg.sender)` from `withdrawTo` | a forgotten settlement on the burn path | **`invariant_strandedIsBounded` FAILS** (`257.8e18 > 178.8e18`). `invariant_solvent` **passes** — see SI-010. |
| **M2** — swap `harvestYield` and `updateReward` on `depositFor` (settle before harvest) | the ordering FF-003/§7 says is load-bearing | **`invariant_solvent`, `invariant_neverOverCommitted` and `invariant_strandedIsBounded` all FAIL**, the last with an arithmetic overflow |

The suite therefore has resolution in **both** directions — over-commitment *and* silent
confiscation. That distinction is itself SI-010.

---

## Findings

### SI-001 — A *partial* `withdrawTo` re-prices the exiter's un-harvested revenue to the other stakers

**Severity:** MEDIUM
**Verification:** C (trace + PoC with a fair-path control). **L4.**
**Coupled pair:** P1 (`_balances[a]`) and **P6** (`govStakingBps` ↔ un-harvested Lender reserves).
**Invariant:** an account's claim on revenue that has already economically accrued must not
change when it reduces its own stake.

**Breaking operation:** `StakedGovToken.withdrawTo` — `StakedGovToken.sol:113-121`.

```solidity
function withdrawTo(address account, uint256 value)
    public override nonReentrant updateReward(msg.sender) returns (bool)
//                              ^^^ settles P1 correctly, and never touches P6
```

**Why this is not simply FF-003.** FF-003 tested the **full** exit and concluded the exiter
forfeits everything. Skill RULE 2 says partial operations are the #1 source, and the partial
case behaves differently and worse in one respect: the exiter is **not** removed from the
distribution — she stays in it at a *reduced* weight, so the loss is a silent, continuous
re-pricing rather than an all-or-nothing forfeiture, and it recurs on **every** partial
withdrawal she ever makes. `harvestAndWithdraw` is full-exit-only, so **no harvesting
partial exit exists in the ABI** (verified against the compiled ABI, not by grep).

**Trigger sequence**
1. Alice 1,000 stGOV, Bob 1,000 stGOV. 100 COIN accrues in the Lender. Entitlement 50 / 50.
2. Alice calls `withdrawTo(alice, 500e18)` — the standard OZ `ERC20Wrapper` entry point, the
   one an integrator reaches for by name, and the one with **no NatSpec at all**.
3. Anyone (a back-runner, or Bob) calls the permissionless `RevenueRouter.distribute()`.

**Measured (L4, `test_SIH_partialExitForfeitsProRataToTheOtherStakers`)**
```
alice earned  33.333333333333333333 COIN   (entitlement was 50)
bob   earned  66.666666666666666666 COIN   (entitlement was 50)
```
**Control (`test_SIH_controlPartialExitAfterAHarvestIsFair`)** — identical setup, one call
reordered (`distribute()` first): alice 50, bob 50. The control is what gives the check its
resolution: the only difference is call order, and it moves a third of Alice's claim.

**Consequence.** Deterministic, repeatable, cost-free extraction from any staker who reduces
their position. Not theft in the protocol's own terms — the spec says only the supply present
at distribution time earns — but it is unconsented value transfer triggered by the most
natural-looking function in the ABI, and unlike the full-exit case the user has no signal
that they left anything behind.

**Fix — and the price of the fix.**
```solidity
/// @notice Burns stGOV and returns the underlying GOV WITHOUT harvesting pending revenue.
/// @dev Your share of revenue accrued but not yet distributed is forfeited to the
/// remaining stakers, in proportion to the stake you give up. Use harvestAndWithdrawTo.
function withdrawTo(address account, uint256 value) public override ...

function harvestAndWithdrawTo(address account, uint256 value)
    external nonReentrant harvestYield updateReward(msg.sender) returns (bool)
{ return super.withdrawTo(account, value); }
```
*What it prevents:* silent re-pricing on the partial path.
*What it creates:* a fourth exit function and a larger ABI, and — critically — it must **not**
be done by adding `harvestYield` to `withdrawTo` itself, because that destroys the escape
hatch FF-004 shows is genuinely needed (and which `test_SIK` re-confirms independently: the
plain exit survives a dead router). The cost of the *correct* fix is ABI surface; the cost of
the tempting fix is a permanent freeze of the exit.

---

### SI-002 — `govStakingBps` is retroactive in **both** directions; the treasury is exposed too

**Severity:** MEDIUM
**Verification:** C (PoC pair with control). **L4.**
**Coupled pair:** P6.
**Invariant:** the split under which revenue is paid must be the split under which it accrued.

FF-002 proved that **lowering** bps strips stakers. The State Mapper's question is different:
*is the pair unsettled, or is one direction protected?* It is unsettled, full stop.

**Measured (L4, `test_SID_raisingBpsRetroactivelyTakesRevenueFromTheTreasury`)**
```
alice sole staker; bps = 0 for the whole accrual epoch; 100 COIN accrues for the TREASURY
owner calls setGovStakingBps(10_000), then distribute()
  treasury received      0
  alice earned         100 COIN
control (distribute first, then raise): treasury 100, alice 0
```

**Why this matters beyond FF-002.** FF-002 frames the defect as *governance can expropriate
stakers*, mitigated by stakers being able to self-defend with a permissionless `distribute()`.
The reverse direction removes that framing: the **treasury has no defence at all**, because
the treasury is the Timelock, and the actor who would raise the split *is* the Timelock's
constituency. A staker majority that wants the treasury's accrued revenue proposes
`setGovStakingBps(10_000)` and takes an epoch of treasury income that was never theirs. The
correct statement of the defect is therefore not "governance can expropriate stakers" but
**"the split is a retroactive, unsettled cross-contract write, and whichever side controls
the setter can take the other side's accrued epoch."**

**Fix.** As FF-002: settle before writing. Same trade-off (the setter inherits every Lender
failure mode), plus one FF-002 did not price: with `renounceOwnership` reachable (FF-010),
a settle-on-set fix means a Lender outage makes the split permanently unchangeable **and**
there is a one-way door that makes that state permanent by accident.

---

### SI-003 — Two floor divisions in series; the composed dead-zone is 4× the notify-side one and rounds toward the treasury on every distribution

**Severity:** LOW (escalating with the Coin's decimals, as FF-001)
**Verification:** C. **L4** (threshold found by binary search over live state, not derived).
**Coupled pair:** P7 then P2.

```solidity
govStakingAmount = (amount * govStakingBps) / MAX_BPS;              // RevenueRouter:73  floor -> treasury
rewardPerTokenStored += Math.mulDiv(reward, REWARD_PRECISION, supply); // StakedGovToken:172 floor -> nobody
```

FF-001 measured the second. The first is a separate, earlier filter that FF-001's model
does not contain, and the `if (govStakingAmount != 0)` guard at L77 turns its output into a
**silent skip of the entire notification**.

**Measured (L4)**
```
test_SIA3  bps = 2500, supply = 1000e18
  dead-zone from the notify-side floor alone   : harvests < 1,000 wei
  dead-zone with BOTH floors composed          : harvests < 4,000 wei     <- binary-searched
test_SIA   bps = 2500, harvest = 3 wei -> rPTS unchanged, treasury +3 (100 %)
test_SIA2  bps = 3333, 50 distributions of 10,000,009 wei
  treasury surplus over the exact split        : 50 wei  (exactly 1 wei per distribution)
```

**Consequence.** Two effects, both directional. (a) The dead-zone below which stakers receive
nothing scales as `MAX_BPS / govStakingBps` **times** `supply / 1e18` — at the factory default
`bps = 10_000` the first factor is 1, so *the defect is invisible until governance changes the
split*, which is the same masking structure as SI-007. (b) The router's floor rounds toward
the **treasury**, deterministically, on every single distribution — and `distribute()` runs on
every `depositFor`, so the number of roundings is unbounded and attacker-influenced.

At 18-decimal Coin the magnitude is negligible (1 wei per distribution). At ≤ 8 decimals it
composes with FF-001's escalation and both should be graded together.

**Fix.** Compute the treasury side as the residual of the staker side *after* the
`REWARD_PRECISION` rounding, or carry the remainder forward in a `uint256 dust` accumulator
in the router. *What the fix creates:* a new state variable in a contract that currently has
none of its own accounting state, and therefore a new coupled pair (`dust ↔ balance`) to
maintain — which is exactly the class of bug this pass is looking for. The cheaper option is
to document the dead-zone and require `govStakingBps` changes to be paired with a settlement.

---

### SI-004 — Coin that reaches `StakedGovToken` outside `distribute()` is permanently stranded, while the same donation to `RevenueRouter` is swept

**Severity:** LOW
**Verification:** C (PoC + control + the opposite-contract comparison). **L4.**
**Coupled pair:** P4 (`Coin.balanceOf(staker)` ↔ `Σ earned`).
**Invariant:** every Coin the staker holds should be owed to someone.

`rewardPerTokenStored` is written at **L172 only** (grep-verified), reachable **only** through
`notifyRewardAmount`, which is `onlyRevenueRouter`. There is no `sweep`, no `skim`, no
`_recover`, no admin, and no owner on `StakedGovToken` — verified against the **compiled ABI**.

**Measured (L4, `test_SIB_*`)**
```
100 COIN minted directly to StakedGovToken
  rewardPerTokenStored : 0        (unchanged)
  earned(alice)        : 0        (unchanged)
  after getReward()    : 100 COIN still sitting in the contract
control: the same 100 COIN routed through distribute() -> earned(alice) = 100 COIN, claimable
comparison: the same 100 COIN donated to the ROUTER is swept into the split (L71 reads the
            router's WHOLE balance, not the pulled delta) and reaches alice in full
```

**Consequence.** Permanent, unrecoverable loss of any Coin that arrives by a route other than
`distribute()`: a user paying the staker directly, a misconfigured integrator, an airdrop of
the Coin, or a future Lender path that pays the receiver rather than the operator. The amount
is arbitrary. The realistic frequency is low, which is why this is LOW and not MEDIUM — but
the asymmetry with the router is undocumented and is the kind of difference an integrator
reads as intentional.

**Fix.** Either give `StakedGovToken` a permissionless `skim()` that notifies the surplus
(`balanceOf(this) - Σ unpaid` is not tracked, so this requires a `totalUnpaid` accumulator —
again, a new coupled pair), or document that direct transfers are lost. *What a `skim` fix
creates:* a permissionless way to move `rewardPerTokenStored` outside the router's control,
which weakens the `onlyRevenueRouter` guarantee that FF-018 relies on.

---

### SI-005 — GOV donated to `StakedGovToken` breaks the wrapper's exact backing and cannot be re-synchronised

**Severity:** LOW
**Verification:** C. **L4.**
**Coupled pair:** P5 (`underlying().balanceOf(staker)` ↔ `totalSupply()`).
**Invariant:** ERC20Wrapper's 1:1 backing — `GOV held == stGOV supply`.

OZ provides exactly one reconciler, `ERC20WrapperUpgradeable._recover(address)`, and
documents it as *"Internal function that can be exposed with access control if desired."*
It is **not** exposed — verified against the compiled ABI, not by grep.

**Measured (L4, `test_SIC_*`)**
```
alice stakes 1,000 GOV        -> GOV held == totalSupply  (exact)
bob transfers 500 GOV in      -> GOV held == totalSupply + 500 ether
alice withdraws everything    -> totalSupply == 0, GOV held == 500 ether  (stranded)
```
The invariant suite confirms the direction can only ever be `>=`, never `<`
(`invariant_backed`, 20,480 calls).

**Consequence.** Stranded GOV out of a **fixed 10,000,000 supply** — it is permanently
removed from circulation and from the Governor's reachable voting float. Low likelihood,
permanent effect, and worth one line of NatSpec at minimum. Note this is the *safe* half of
FF-008: when `rewardsToken == underlying` the same slot is what pays rewards and the backing
inverts to under-collateralised. Here it only over-collateralises.

---

### SI-006 — `depositFor(victim, 0)` lets any address write another account's reward state and force a global harvest

**Severity:** LOW
**Verification:** B (PoC). **L4.**
**Coupled pair:** P1.

`depositFor(address account, uint256 value)` settles **`account`**, not `msg.sender`
(`StakedGovToken.sol:107`). With `value == 0` the OZ body pulls nothing and mints nothing,
so the call needs no GOV, no allowance, and no relationship to the victim.

**Measured (L4, `test_SIE_anyoneCanForceSettleAnyAccountWithZeroValue`)**
```
attacker (no stake, no approval) calls depositFor(alice, 0)
  rewards[alice]                : 0 -> non-zero          (written by the attacker)
  userRewardPerTokenPaid[alice] : 0 -> rewardPerTokenStored
  lender.accruedLocalReserves() : 100 ether -> 0         (global harvest forced)
```

**Consequence.** Three things, all small individually. (a) An unprivileged party writes two
storage slots belonging to a third party. The write is value-neutral up to the truncation in
SI-008, so this is not theft. (b) It is a second, non-obvious permissionless trigger for
`RevenueRouter.distribute()` — which matters because the back-running in SI-001 and FF-003 can
now be performed through `StakedGovToken` rather than the router, so mempool defences that
watch only `distribute()` miss it. (c) It makes `rewards[victim]` non-zero, which means a
victim who is blocklisted by the Coin now has a `_payReward` that reverts on paths that
previously would have been no-ops.

**Fix.** `if (value == 0) revert ZeroValue();`, or settle `msg.sender` in addition to
`account`. *What the fix creates:* nothing in the accounting; it removes a (currently
undocumented) permissionless harvest trigger that some integrator may come to rely on.

---

### SI-007 — The factory default `govStakingBps = 10_000` masks the treasury-transfer dependency; the first split change arms it against the only mint path

**Severity:** LOW — **stated as a lead.** The mechanism and the consequence are proven by
execution; whether the trigger can occur depends on the deployed Coin, which this repository
does not contain.
**Verification:** C. **L4.**
**Coupled pair:** P12 (`treasury` ↔ `distribute()` liveness ↔ `depositFor` liveness).

```solidity
if (treasuryAmount != 0) {          // RevenueRouter.sol:81
    coin.safeTransfer(treasury, treasuryAmount);
}
```
`CoinDAOFactory.DEFAULT_GOV_STAKING_BPS = 10_000` (`CoinDAOFactory.sol:31`) and
`treasury = deployment.timelock` (`CoinDAOFactory.sol:404-411`). At the default split
`treasuryAmount` is **always** 0, so this branch is **never executed** on a freshly launched
CoinDAO. `treasury` has no setter (ABI-verified).

**Measured (L4, `test_SIK_defaultBpsMasksADeadTreasuryUntilTheSplitIsChanged`)** — with a
Coin that blocklists the treasury address (the shape of every pausable/blocklisting
stablecoin):
```
bps = 10_000 : distribute() succeeds, alice earns 100 COIN   <- the defect is invisible
setGovStakingBps(9_000)
bps =  9_000 : distribute() REVERTS
               depositFor(bob, 1) REVERTS      <- the only mint path, hence the only way
                                                  to acquire voting power (FF-004)
               withdraw() still works          <- the escape hatch holds
```

**Consequence.** A latent, untested code path in a contract with no setter for the address it
depends on. The state-audit point is not the blocklist — it is that **the default
configuration exercises only one of the two transfer branches**, so any failure mode of the
treasury branch is guaranteed to first appear in production, after a governance action, on a
clone that cannot be repaired (FF-017). Governance can recover by restoring `bps = 10_000`
(existing stakers keep their stGOV and can still vote), so this is not a permanent freeze —
which is why it is LOW rather than HIGH.

**Question for the client** (this is not gradable from the repository): does the deployed Coin
have a pause, a blocklist, or any transfer precondition that a Timelock address could ever
fail? Pass 1's assumption #8 asks the same question; this finding shows the answer is
*deferred*, not *no*, because the default split hides the branch that would reveal it.

---

### SI-008 — Settlement truncation drift: settling more often earns strictly less

**Severity:** INFO
**Verification:** B — fuzz, 256 runs each way, with a control that establishes resolution. **L4.**
**Coupled pair:** P1.

`earned()` floors once per settlement (`Math.mulDiv`, `StakedGovToken.sol:141`), and
`updateReward` snaps `urptp[a]` to `rPTS` immediately after, so the truncated remainder is
**discarded permanently** rather than carried. `Σ floor(B·Δᵢ/1e18) <= floor(B·ΣΔᵢ/1e18)`.

**Measured (L4)**
```
testFuzz_SIE2  two identical balances of 333e18 + 7, third staker at 777e18 + 31 so the
               floors are non-trivial; 32 harvests; one account force-settled each round
  drift > 0 in 256/256 runs, and <= 32 wei (one wei of Coin per settlement) in 256/256
testFuzz_SIE3  CONTROL - the same run with balances that are whole multiples of 1e18
  drift == 0 in 256/256 runs
```

**Resolution note.** An earlier version of this check reported drift = 0 and would have been
recorded as a verified negative. It was wrong: the balances happened to make
`B mod 1e18 = 7`, and `7·Δ` summed over 32 rounds never reached 1e18. The check only acquired
resolution once the accrual magnitudes were raised. Recorded because the first, greener answer
was the false one.

**Consequence.** Bounded by 1 wei of Coin per settlement and **exactly zero** for any balance
that is a whole multiple of `REWARD_PRECISION`, which is what almost every real position will
be. INFO, not LOW. It matters only as the mechanism by which SI-006's force-settle could in
principle grief — at ~50k gas per wei destroyed, it never will.

---

### SI-009 — `_update` permits `from == 0 && to == 0`

**Severity:** INFO
**Verification:** B. **L4.**

```solidity
if (from != address(0) && to != address(0)) revert NonTransferable();   // L180-182
```
The non-transferability guard permits the mint-and-burn-simultaneously case. It is
unreachable **only** because OZ's `_mint` and `_burn` reject the zero address before
`_update` is called — verified at L4 (`test_SIJ_zeroToZeroUpdateIsUnreachable`:
`depositFor(address(0), v)` reverts inside OZ). The safety of the project's own
non-transferability invariant is therefore delegated entirely to a library precondition the
contract does not state. `if (from != address(0) || to == address(0)) …` — or simply
`require(from == address(0) || to == address(0))` — says what is meant.

---

### SI-010 — The one-sided solvency invariant cannot see confiscation, and both this repository's tests and Pass 1's fuzz are one-sided

**Severity:** INFO (methodology — it changes how much the green checks in this lane are worth)
**Verification:** B — demonstrated by source mutation. **L4.**

Pass 1 reports a 256-run conservation fuzz asserting `Σ earned(user) <= Coin.balanceOf(staker)`
and calls it "a strong verified negative: the core accumulator does not leak, double-credit, or
under-collateralise." That statement is accurate but **one-sided**: every bug that *destroys*
user value makes the contract **more** solvent, so this family of assertion is structurally
incapable of detecting it.

**Demonstrated (L4).** Mutation **M1** — delete `updateReward(msg.sender)` from `withdrawTo`,
i.e. exactly the omission this whole audit class exists to find:

```
invariant_solvent                 PASS   (3,840 calls)   <- the Pass 1 shape of the check
invariant_neverOverCommitted      PASS
invariant_potConservation         PASS
invariant_strandedIsBounded       FAIL   257.8e18 > 178.8e18
```

Only the two-sided bound catches it. The control in the other direction is mutation **M2**
(settle before harvest in `depositFor`), which fails `invariant_solvent`,
`invariant_neverOverCommitted` **and** `invariant_strandedIsBounded` — so the suite is
calibrated in both directions, and the pair of mutations is what gives the nine green
invariants their resolution.

**Recommendation for the report.** Pass 1's fuzz result should be restated as *"the accumulator
never over-commits"* rather than *"the accumulator does not leak."* The leak direction is
covered by SI-001 through SI-005, and the invariant that covers it is
`stranded <= donations + dust_bound`, not `owed <= held`.

---

### SI-011 — Quorum base ↔ delegated votes (P10): mapped here, **already covered** by the governance lane

`Votes$._totalCheckpoints` is incremented by every `depositFor` regardless of delegation, while
`Votes$._delegateCheckpoints` is credited only when `delegates(account) != address(0)`, and
`CoinDAOGovernor` is `GovernorVotesQuorumFraction` over `stGOV` with
`quorumDenominator() = 1_000` and numerator 1. Nothing in `StakedGovToken`'s mint path
delegates. Confirmed as an invariant here (`invariant_votesNeverExceedQuorumBase`, 20,480
calls) and as a PoC in the **governance** Pass 1 (`FF-011`:
`testNonDelegatingStakersRaiseQuorumButSupplyNoVotes`, 400,000 stGOV → quorum 400 GOV, votes 0).

**This is not claimed as a new finding.** It is recorded in the map because the parent asked
for the pair, and because it is the reason `totalSupply()` carries three unrelated meanings
(FF-012): reward divisor, treasury-vs-stakers switch, and quorum base. The revenue-lane
contribution is only the confirmation that the divisor and the quorum base are the *same*
storage value moved by the *same* two functions, with no cooldown between them.

---

## False positives eliminated / verified negatives

| # | Hypothesis | Outcome |
|---|---|---|
| VN-1 | *"Some balance-changing path fails to settle the affected account."* | **REFUTED.** The Mutation Matrix has no surviving `???` on P1: `depositFor` settles `account`, `withdrawTo`/`withdraw`/`harvestAndWithdraw` settle `msg.sender`, transfers revert, `_recover` is not exposed. Every writer grep-verified; ABI checked, not assumed. This is the strongest positive result in the lane. |
| VN-2 | *"`rewardPerTokenStored` is mis-priced after a `totalSupply == 0` epoch or a 1-wei-supply pump."* | **REFUTED at L4** (`test_SIF`). `rPTS` reaches > 1e38 and a 500,000-stGOV newcomer's `urptp` snaps to it; she earns exactly pro-rata afterwards with no overflow and no retroactive credit. Confirms FF-016's magnitude refutation from the state side. |
| VN-3 | *"`urptp[a]` can exceed `rPTS`, making the unchecked subtraction at L141 revert."* | **REFUTED.** `rPTS` is `+=`-only and `urptp` is only ever assigned `rPTS`. Held across 20,480 adversarial calls. |
| VN-4 | *"The non-upgradeable `ReentrancyGuard` collides with `rewardsToken` at slot 0 in a clone."* | **REFUTED — and for a different reason than Pass 1 gave.** OZ **5.6.1**'s `ReentrancyGuard` uses ERC-7201 namespaced storage (`REENTRANCY_GUARD_STORAGE = 0x9b779b17…`), so it occupies no sequential slot at all. Pass 1's FF-006 conclusion is correct; its stated reason ("`forge inspect` shows no `_status`") was the symptom, not the cause. `rewardsToken` is genuinely at slot 0. |
| VN-5 | *"Donations pollute the accumulator."* | **REFUTED for the router, CONFIRMED for the staker.** The router's full-balance read (L71) makes donations to it *correctly* distributable; donations to the staker are stranded (SI-004). Both directions driven by the invariant handler. |
| VN-6 | *"Partial and full exits handle the coupled state differently."* | **REFUTED for P1** (both settle identically), **CONFIRMED for P6** (SI-001). Recorded because the two halves of the same skill-checklist row give opposite answers. |

---

## Summary

- Coupled state pairs mapped: **14** (P1–P14); storage layout dumped from the compiler, not read.
- Mutation paths analysed: **23**; six survived to Phase 3 as `???`.
- Raw findings: 1 HIGH, 6 MEDIUM, 3 LOW/INFO.
- After verification: **10 TRUE POSITIVE · 0 FALSE POSITIVE · 4 DOWNGRADED · 1 attributed to another lane (SI-011).**
- **Final: 2 MEDIUM · 4 LOW (one stated as a lead) · 4 INFO.**
- **NEW vs Pass 1: 8 new (SI-003…SI-010), 2 extensions of existing findings (SI-001 extends FF-003, SI-002 extends FF-002), 1 already covered elsewhere (SI-011).**
- Execution: **18/18 PoCs · 9/9 invariants over 20,480 handler calls · 2 source mutations
  confirming resolution in both directions · repo's own 55/55 suite green on the restored copy.**
- The audited tree at `[scratch]` was **not modified**; `diff -r` against the scratchpad
  copy is empty.

**The strongest thing found.** The per-account accumulator (P1, P3) is structurally complete —
every one of the four balance-changing paths settles the account it touches, no writer was
missed, and 20,480 adversarial calls found no desync. **Every defect in this lane lives at a
boundary the accumulator does not span:** the un-harvested stock inside the Lender (SI-001,
SI-002), the two floor divisions between the router and the accumulator (SI-003), and the
tokens that reach either contract without passing through `distribute()` (SI-004, SI-005).

**The most useful thing found.** SI-010: the invariant this repository and Pass 1 both rely on
(`owed <= held`) is structurally blind to the exact bug class this pass exists to find, and a
one-line source mutation proves it. Anything downstream that cites the Pass 1 fuzz as evidence
of correctness should cite it only for the over-commitment direction.

**Handoff to Stage 3 (fusion).**

| coupled pair | state after Pass 2 |
|---|---|
| P6 `govStakingBps` ↔ un-harvested Lender reserves | **unsettled in both directions** (FF-002 + SI-002) and unsettled on the burn path (FF-003 + SI-001). This one pair is the root of four findings. |
| P4 `Coin.balanceOf(staker)` ↔ `Σ rewards` | diverges upward only; bounded by SI-003's dust plus SI-004's donations; never under-collateralised (20,480 calls) |
| P12 `treasury` ↔ `distribute` ↔ `depositFor` liveness | latent, armed by the first `setGovStakingBps` away from 10 000 — **needs a client answer about the Coin** |
| P2/P10 `totalSupply` as divisor, switch and quorum base | mapped; the quorum half belongs to the governance lane (FF-011 there, FF-012 here) |
| P13/P14 mutual-reference and token-identity pairs | never validated at either `initialize`, permanently unrepairable (FF-017) — unchanged by this pass |
