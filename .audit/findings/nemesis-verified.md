# N E M E S I S — Verified Findings

**Target:** Monolith CoinDAO factory + deployed stack
**Branch:** `feat/coindao-version2` @ `d367582`
**Date:** 2026-08-18
**Language:** Solidity 0.8.26 (OZ Contracts v5.6.x, upgradeable + non-upgradeable)
**Supersedes:** `.audit/findings/nemesis-verified.md` (run @ `9ea848c`, 2026-07-29)

Nine commits landed since the last audited tree. `src/` was substantially rewritten:

| Commit | Change | Effect on the prior report |
| :-- | :-- | :-- |
| `45ff26b` | Whole stack moved to minimal proxies (`Clones.cloneDeterministic`) | Retires **NM-014** (CREATE-nonce RLP prediction) — no CREATE-nonce path remains |
| `3991223` + `86f2355` + `e087255` | `StakedGovToken` reward queueing replaced by instant `rewardPerTokenStored` accrual; `harvestYield` added to `depositFor` only | Retires **NM-015** and **NM-002** as written; introduces **NM4-002** |
| `2b91f3a` | New 5% `immediateAllocation` weight | New allocation math, re-verified |
| `444831e` + `9ea848c` | Quorum became `GovernorVotesQuorumFraction(1/1000)` of staked supply | **NM-012** must be restated — see **NM4-004** |
| `dc7e513`/`cc826d3`/`d367582` | Test reduction, docs, cleanup | — |

## Scope

All of `src/` (1,363 lines across 12 files). Passes run: Feynman (full) → State (full, enriched)
→ Feynman (targeted) → State (targeted) → **converged at pass 4**.

- Baseline at session start: `forge build` clean, **48/48 pass**.
- New PoCs: `test/NemesisPoC4.t.sol` — 10 tests (2 fuzzed, 256 runs each), all passing.
- `src/` was modified exactly once during this session, to validate the NM4-002 fix, and restored
  (`git checkout`) before the report was written. Final state: `src/` clean, **48/48 + 10/10 pass**.

## Verification Summary

| ID | Discovery path | Severity | Verdict |
| :-- | :-- | :-- | :-- |
| NM4-001 | State (mask → root cause) → Feynman | **MEDIUM** | TRUE POSITIVE (PoC, quantified) — generalises prior NM-001 |
| NM4-002 | Feynman C2 (ordering) → State (parallel path) → Feynman C3 | **MEDIUM** | TRUE POSITIVE (PoC; **fix validated**) |
| NM4-003 | Feynman C4 (assumptions) → State (liveness coupling) | LOW | TRUE POSITIVE (PoC; reachability caveat stated) |
| NM4-004 | Feynman C3 (consistency) | LOW | TRUE POSITIVE (fuzz-proved identity) — restates prior NM-012 |
| NM4-005…009 | mixed | INFO | TRUE POSITIVE, no material impact |
| JIT deposit capture | Feynman C7 (multi-tx) | — | **FALSE POSITIVE** — `harvestYield` on `depositFor` is load-bearing and correct |
| `ReentrancyGuard` in clones | State (uninitialised storage) | — | **FALSE POSITIVE** — OZ v5.6 uses ERC-7201, `@custom:stateless` |
| sGOV reward insolvency | State (accumulator drift) | — | **FALSE POSITIVE** — fuzz-proved solvent |

**Two open MEDIUM findings. One has a validated one-line fix.**

---

## NM4-001 (MEDIUM) — Coin-staking emissions are burned irrecoverably in any zero-supply window

**Source:** State Mapper found the mask; Feynman traced it to the root mutation.
**Verification:** PoC `testH1_TrancheZeroBurnsFromDeploymentBlock`, `testH2_BurnRecursWheneverStakedSupplyHitsZero`.

This re-confirms prior **NM-001** — unchanged in `src/` — and **generalises it**: the previous
report framed it as a launch artifact. It is not. The burn recurs on *every* window where
`StakingRewards._totalSupply == 0` during an active period.

**The mask** (`StakingRewards.sol:95`):
```solidity
if (_totalSupply == 0) return rewardPerTokenStored;
```
Feynman's question — *why would this ever divide by zero?* — exposes the broken invariant:
**"every second of an active reward period is credited to someone."** It is not. The mask does not
defer the elapsed emission, it discards it: `rewardPerToken()` freezes while supply is zero, and the
next `updateReward` pre-hook writes `lastUpdateTime = lastTimeRewardApplicable()`, jumping the clock
forward over the gap (`StakingRewards.sol:70`).

**Root cause mutation:** `notifyRewardAmount` starts a period unconditionally
(`StakingRewards.sol:162-163`), and `StakingRewardsFunder.fundNextTranche` has no live-supply gate.

**Trigger sequence — guaranteed at launch on the `deploy()` path:**
1. `CoinDAOFactory._deployCoinDAO:487` calls `fundNextTranche()`, starting a 365-day stream.
2. `:488` calls `renounceOwnership()` — the escape hatch closes in the same transaction.
3. The Coin market was minted in *this same transaction*, so `coin.totalSupply() == 0` and no staker
   can exist. The PoC asserts this directly.

| | Value |
| :-- | --: |
| Tranche 0 (`deployerStakeBps = 0`) | 2,112,500 GOV |
| Burn rate | **5,787.67 GOV / idle day** |
| Burned by a 7-day launch gap | **40,513.70 GOV** (1.92% of the tranche) |
| Reachable afterwards | 2,071,986.30 GOV |

**Unrecoverable:** `recoverERC20` was intentionally omitted, `owner() == address(0)` after `:488`,
and `rewardsDistribution` is frozen on the funder. The PoC asserts all three.

**Why the existing comment does not cover it.** `StakingRewards.sol:147-149` accepts the behaviour
on the stated grounds that *"the window between tranche funding and the first staker is expected to
be short."* Two problems: on the `deploy()` path the window is bounded below by however long it takes
the first borrower to mint Coin and stake it — provably non-zero — and the comment says nothing about
the recurring case (`testH2`), where existing stakers all exit mid-period and 30 idle days vanish the
same way.

**Fix** (unchanged from the prior report; still one line):
```solidity
// StakingRewardsFunder.fundNextTranche()
if (stakingRewards.totalSupply() == 0) revert NoStakersYet();
```
The tranche schedule is already permissionless and self-pacing, so tranche 0 simply starts when the
market is live. This does not address the recurring mid-period case; if that matters, the emission
must be carried forward rather than discarded (i.e. do not advance `lastUpdateTime` across a
zero-supply gap), which is a larger change.

---

## NM4-002 (MEDIUM) — Exiting sGOV stakers forfeit all unharvested revenue

**Source:** Feynman C2 (ordering) flagged the missing `harvestYield`; State's parallel-path
comparison confirmed the asymmetry; Feynman C3 then showed the stated tradeoff is a false dilemma.
**Verification:** PoC `testH3_BackRunningAWithdrawalCapturesTheWithdrawersRevenue`,
`testH4_LastStakerExitDivertsPendingRevenueToTreasury`. **Fix validated against the real contracts.**

**Coupled pair:** `StakedGovToken.totalSupply()` ↔ unharvested Coin revenue sitting in the Lender.
**Invariant:** revenue that accrues while an account is staked belongs to that account.

**Parallel path comparison:**

| Path | Mutates staked supply | Harvests first |
| :-- | :--: | :--: |
| `depositFor` (`StakedGovToken.sol:102-111`) | ✓ mint | ✓ `harvestYield` |
| `withdrawTo` (`:113-121`) | ✓ burn | ✗ **GAP** |
| `getReward` (`:136`) | — | ✗ |

`notifyRewardAmount` (`:147-153`) credits revenue **instantly, against the supply present at
`distribute()` time**. Because `withdrawTo` burns without harvesting, the exiting account's
checkpoint closes at the pre-harvest index and the revenue accrued during its tenure is credited to
whoever remains.

**Trigger sequence (PoC `testH3`):**
1. Alice and Bob each stake 1,000 GOV.
2. 100,000 Coin of protocol revenue accrues in the Lender, unharvested.
3. Bob calls `withdraw()`. No harvest runs; `earned(bob) == 0`.
4. Anyone calls the permissionless `distribute()`.

| | Value |
| :-- | --: |
| Bob's stake-weighted fair share | 50,000 Coin |
| **Bob actually earns** | **0** |
| Alice captures | 100,000 Coin (200% of her share) |

The loss is **unconditional the moment Bob withdraws** — the next `depositFor` by anyone triggers the
harvest regardless. A searcher who also holds sGOV can guarantee and immediately realise it by
back-running the withdrawal with `distribute()`; that only removes the chance that Bob front-runs
himself. When the exiting account is the *last* staker (PoC `testH4`), `distribute()` sees
`totalSupply() == 0` and routes **100% of the pending revenue to the treasury** instead.

**Why the gap exists.** Commit `e087255` ("Only harvest yield on deposits to prevent DoS on upstream
failure") removed `harvestYield` from the exit paths so an upstream `pullLocalReserves()` revert
cannot trap funds. That concern is real and correct. **But the tradeoff is a false dilemma** — the
harvest can be made best-effort:

```solidity
modifier tryHarvestYield() {
    try revenueRouter.distribute() {} catch {}
    _;
}

function withdrawTo(address account, uint256 value)
    public override nonReentrant tryHarvestYield updateReward(msg.sender) returns (bool) { ... }

function getReward() public nonReentrant tryHarvestYield updateReward(msg.sender) { ... }
```

**Fix validated.** This patch was applied to `src/StakedGovToken.sol`, measured, and reverted:

| Property | Result |
| :-- | :-- |
| NM4-002 closed | `testH3` / `testH4` now **fail** — Bob earns his full 50,000; nothing is diverted to the treasury |
| Withdrawal DoS-immunity preserved | `testH5` still **passes** — exits and claims work while `distribute()` reverts |
| Regression surface | 46/48 existing tests pass; the only two failures are `testOnlyDepositsHarvestYield` and `testWithdrawAndClaimDoNotHarvestPendingReward`, the characterization tests that pin the current behaviour |

**Keep the hard `harvestYield` on `depositFor`.** It is load-bearing, and the asymmetry is correct in
that direction: it is precisely what blocks just-in-time capture (see *Verified sound*, below).
Relaxing the entry-side harvest to `try/catch` would let anyone who can make `distribute()` revert
deposit without harvesting, repair the condition, and capture the accumulated pot.

---

## NM4-003 (LOW) — A reverting `distribute()` permanently freezes the governance electorate

**Source:** Feynman C4 (assumptions) → State (liveness coupling).
**Verification:** PoC `testH5_DistributeFailureFreezesTheElectorate`.

`depositFor` is the **only** mint path for sGOV (`_recover` is never exposed, transfers revert
`NonTransferable`), and it hard-depends on `revenueRouter.distribute()` succeeding
(`StakedGovToken.sol:81-84, 102-111`). `revenueRouter` has no setter, and `RevenueRouter.lender` has
no setter, so there is no administrative repair path — not even via the timelock.

Since sGOV is the governor's `IVotes` token, a persistent revert inside `distribute()` means:

- incumbent sGOV holders keep full voting power and can still exit (after `e087255`);
- **no new participant can ever join the electorate.**

The PoC confirms all three under a reverting `pullLocalReserves()`.

**Reachability caveat — why this is LOW and not HIGH.** I could not establish that Monolith's
`pullLocalReserves()` is reachably revertible; the local mock returns early on zero reserves, which
suggests the real implementation is also non-reverting on the common path. **This finding becomes
HIGH if any of the following holds**, and each is worth confirming against the Monolith source:

1. `pullLocalReserves()` reverts when reserves are zero, when the lender is paused, or after
   `timeUntilImmutability` elapses;
2. the lender `manager` — chosen by the `deploy()` caller, not by governance, and per the local mock
   able to reassign itself — can put the lender into such a state. That would make electorate
   freezing an entrenchment lever available to a party governance cannot remove.

If (1) or (2) is possible, `depositFor` needs a bounded fallback. Note this cannot be `try/catch`
for the reason given under NM4-002; a `deadline`-style opt-out or an explicit
"harvest-then-deposit" two-call flow would be needed instead.

---

## NM4-004 (LOW) — Quorum can never exceed the proposal threshold

**Source:** Feynman C3 (consistency).
**Verification:** fuzz `testFuzzH9_QuorumCanNeverExceedTheProposalThreshold` (256 runs over the full
staked-supply range), `testH9b_LoneProposerAtThresholdClearsQuorumTenfold`.

Prior **NM-012** was accepted on the grounds that quorum *equalled* the proposal threshold by
parameter coincidence, so an unopposed threshold-sized holder wins — ordinary majority rule. Since
`444831e`/`9ea848c` the relationship is no longer a coincidence, and no longer an equality:

```
quorum(t)         = sGOV.getPastTotalSupply(t) / 1_000     // fraction of *staked* supply
proposalThreshold = GOV_TOKEN_SUPPLY / 1_000               // fraction of *fixed* supply, absolute
```

`getPastTotalSupply(t) <= GOV_TOKEN_SUPPLY` always, so **`quorum(t) <= proposalThreshold` is an
identity**, with equality only at 100% of GOV staked. At a realistic 10% staked:

| | Value |
| :-- | --: |
| Proposal threshold | 10,000 GOV |
| Quorum @ 1,000,000 sGOV staked | 1,000 GOV |
| Proposer's own votes as a multiple of quorum | **10×** |

Quorum therefore provides no protection that the proposal threshold does not already provide: any
address able to `propose()` clears quorum by voting For with its own votes. This is the same
conclusion the author accepted for NM-012, so it is reported as LOW — but the prior acceptance was
for a weaker, coincidental version of the property, and it is now structural and strictly worse.
If quorum is meant to bind, it must be denominated in fixed GOV supply rather than staked supply, or
the numerator raised above `1`.

---

## INFO

- **NM4-005** — the quorum base counts sGOV that cannot vote. `ERC20Votes` checkpoints total supply
  on mint regardless of delegation, so `getPastTotalSupply` includes every staker who never called
  `delegate()`. PoC `testH7`: 1,000,000 sGOV staked, 10,000 votable. sGOV is a *staking receipt* —
  most holders stake for Coin revenue and will never delegate — so the votable electorate is
  structurally a small fraction of the quorum base. Inherent to OZ; compounds NM4-004.
- **NM4-006** — `predictCoinDAOAddresses` always returns a `deployerVesting` address, but
  `_deployCoinDAO:473` skips that clone when `deployerStakeBps == 0`. PoC `testH8`: the predicted
  address holds no code after deployment and `Deployment.deployerVesting` is `address(0)`. Integrators
  reading the prediction will index a phantom contract.
- **NM4-007** — `deployForExistingCoin` omits `deploy()`'s zero-address check on `coin`/`vault`
  (`:336-337` vs `:308-310`). Re-confirms prior **NM-008**; still fail-safe (a zero `coin` reverts in
  `StakedGovToken.initialize`, a zero `vault` in `StakingRewards.initialize`).
- **NM4-008** — `StakedGovToken.initialize` does not reject `govToken_ == rewardsToken_`, and
  `StakingRewards.initialize` does not reject `stakingToken_ == rewardsToken_`. Unreachable through
  the factory (GOV is a fresh clone, Coin comes from Monolith), but both implementations are generic
  and the collision would let `getReward` drain the wrapper's backing.
- **NM4-009** — `setPendingMonolithBeneficiary` rejects `address(0)` (`:255`), so a pending nomination
  cannot be cancelled, only overwritten. Re-nominating the incumbent is the only way to neutralise it,
  and that still requires an `acceptMonolithBeneficiary()` call.

---

## Verified sound (actively challenged this pass, no finding)

- **Just-in-time deposit capture is blocked, and the mechanism is correct.** The `harvestYield` on
  `depositFor` runs *inside* `nonReentrant` but *before* `updateReward(account)` and before the mint,
  so a depositor's harvest credits the pre-deposit supply. A flash-loaned or whale deposit placed in
  front of a large accrual pays that accrual to the incumbents and earns nothing. Every entry path
  was enumerated: `depositFor` is the only mint (`_recover` unexposed, `_update` reverts on transfer),
  and it always harvests. **This is the single most important property in the reward design** — see
  the warning in NM4-002 against relaxing it.
- **sGOV reward accounting stays solvent.** Fuzz `testFuzzH6_StakedGovRewardsStaySolvent` (256 runs)
  drives 8 rounds of interleaved deposits, revenue distributions and partial exits across 3 accounts,
  and asserts `Σ earned <= coin.balanceOf(staker)`, that every notified wei arrives, and that all
  three accounts can fully claim. `Math.mulDiv` floors in both `notifyRewardAmount` and `earned`, so
  the residual is always in the contract's favour.
- **`rewardPerTokenStored - userRewardPerTokenPaid[a]` cannot underflow.** `rewardPerTokenStored` is
  written only by `+=` in `notifyRewardAmount`, and `userRewardPerTokenPaid[a]` is only ever assigned
  the then-current value. Monotonicity holds across all four mutation sites.
- **`ReentrancyGuard` in minimal proxies is safe.** All three clone targets inherit the
  *non-upgradeable* `ReentrancyGuard`, whose constructor never runs on a proxy. In OZ v5.6 the guard
  stores its status at the ERC-7201 slot `0x9b779b…5f00` and is tagged `@custom:stateless`: no
  regular storage slot is claimed, so there is no collision with `rewardsToken`/`revenueRouter`/
  `rewardPerTokenStored` or with `StakingRewards`' own variables, and an initial value of `0`
  (≠ `ENTERED`) is handled correctly by `_nonReentrantBeforeView`.
- **The tranche schedule cannot be desynchronised.** `notifyRewardAmount` is reachable only through
  `fundNextTranche` (`rewardsDistribution` is frozen by `renounceOwnership()`), which gates on
  `block.timestamp >= periodFinish`, so the mid-period `else` branch is unreachable and no leftover is
  ever rolled forward. `require(rewardRate <= balance / rewardsDuration)` cannot spuriously revert,
  because the tranche is transferred before it is notified. `nextTranche` is incremented before the
  transfer (CEI). The final sweep is provably non-zero on the factory path: tranches 0–2 consume
  exactly 82.5% of a balance funded to exactly `totalRewards`.
- **`RevenueRouter.distribute()` handles the empty case.** `amount == 0` produces no transfers and no
  notify, so `harvestYield` is a no-op rather than a revert when there is no revenue — this is what
  keeps `depositFor` usable in the common case.
- **`notifyRewardAmount`'s `NoStakedSupply` guard cannot fire from the router.** `distribute()` checks
  `govStaking.totalSupply() != 0` before computing a non-zero share, and nothing between the check and
  the notify can change the supply (Coin is a plain ERC20 with no transfer hooks).
- **Allocation math and privilege handoff re-verified** against the new `immediateAllocation` weight:
  the five allocations sum to `GOV_TOKEN_SUPPLY` for every `deployerStakeBps` in range, the factory
  retains nothing, and the timelock/router/rewards ownership handoffs in Phases 3, 5 and 7 leave no
  residual factory authority. CREATE2 salts are namespaced by `keccak256(creator, userSalt)` and
  `usedDeploymentKeys` makes reuse impossible, so no component address is squattable.

## Methodology notes

- The `via-ir` timestamp trap recorded by the previous three runs still applies; all time arithmetic
  in `NemesisPoC4` derives from the compile-time constant `T0`.
- Two hypotheses were falsified before reaching the report — JIT deposit capture and the
  `ReentrancyGuard`-in-clones storage claim — both by reading the mechanism rather than by testing.
  The lesson the previous run wrote down ("run the symmetric case before writing it up") was applied
  to NM4-002: the fix was implemented against the real contracts and measured in both directions
  before the finding was written, which is what turned a known-and-accepted tradeoff into an
  actionable one.

## Summary

- **2 open MEDIUM findings.** NM4-001 (~5,788 GOV per idle day, unrecoverable) carries over unfixed
  from the previous report and is broader than that report stated. NM4-002 is new to this rewrite and
  has a **validated** one-modifier fix that closes the leak without reintroducing the DoS that
  `e087255` was written to avoid.
- **1 LOW with a reachability caveat** (NM4-003) that needs a Monolith-side answer to close.
- **NM4-004 restates the accepted NM-012** under the new fractional quorum: the relationship is now an
  identity rather than a parameter coincidence, and strictly weaker.
- **3 hypotheses falsified**, 5 informational items.
- Test suite: **48/48 existing + 10/10 new** passing; `src/` unmodified.
