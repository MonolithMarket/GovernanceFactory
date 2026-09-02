# 🔐 Security Review — GovernanceFactory

---

## Scope

|                                  |                                                        |
| -------------------------------- | ------------------------------------------------------ |
| **Mode**                         | default (directory scan, `interfaces/` `test/` `script/` `lib/` excluded) |
| **Files reviewed**               | `CoinDAOFactory.sol` · `CoinDAOGovernor.sol` · `CoinDAOVestingWallet.sol`<br>`GovToken.sol` · `RevenueRouter.sol` · `StakedGovToken.sol`<br>`StakingRewards.sol` · `StakingRewardsFunder.sol` · `deployment/DeploymentLibraries.sol` |
| **Commit**                       | `77b78cd9ebefc8b881d0413a403386b84ecbe115` |
| **Confidence threshold (1-100)** | 80 |

---

## Findings

[95] **1. Tranche-0 emissions begin against a provably empty staking pool**

`CoinDAOFactory._deployCoinDAO` · Confidence: 95

**Description**
Phase 7 calls `fundNextTranche()` inside the launch transaction, starting a 365-day GOV stream at 5,787.67 GOV/day while `StakingRewards._totalSupply` is necessarily zero — on the `deploy()` path the staking token is created by the same transaction — so emissions before the first staker are unrecoverable (`recoverERC20` was removed and `renounceOwnership()` runs two statements later), and once a dust staker exists the accumulator resumes and credits the entire elapsed window to them.

Executed: 30 idle days strands 173,630 GOV (1.74% of total supply); 90 days strands 520,890 GOV (5.2%). A zero-gap control strands 3.1×10⁻¹¹ GOV — sixteen orders of magnitude less, so the measurement has resolution. The in-code comment at `StakingRewards.sol:147` accepts this as "the window is expected to be short", but `plan.md:78` requires the opposite: unallocated rewards must be "rolled forward by the emissions logic or recoverable by governance". Neither mechanism exists.

**Fix (Option A — validate)**

```diff
  function fundNextTranche() external nonReentrant {
      uint256 tranche = nextTranche;
      if (tranche == TRANCHE_COUNT) revert AllTranchesFunded();
+     if (stakingRewards.totalSupply() == 0) revert NoStakers();
```

**Fix (Option B — restructure)**

```diff
      coinStakingRewards.setRewardsDistribution(address(coinStakingRewardsFunder));
-     coinStakingRewardsFunder.fundNextTranche();
      coinStakingRewards.renounceOwnership();
```

**Fix (Option C — allow-and-handle)**

```diff
-     coinStakingRewards.renounceOwnership();
+     coinStakingRewards.transferOwnership(deployment.timelock);
```
plus a `recoverERC20` on `StakingRewards` restricted to `rewardsToken` in excess of `rewardRate * (periodFinish - block.timestamp)` and callable only after `periodFinish`.

> ⚠️ **These options are not interchangeable and Option A is not sufficient alone.** Gating on `totalSupply() != 0` lets a sole staker withdraw in the same block as the funding transaction and revert it, denying the tranche schedule; it needs a non-trivial minimum supply or a start delay alongside. Option B converts an unrecoverable burn into a recoverable delay but hands the emission start block to whoever calls first. Option C keeps the schedule intact but creates a new governance-reachable path to reward tokens.

---

[95] **2. Quorum is denominated in staked supply while the proposal threshold is denominated in total supply**

`CoinDAOGovernor.quorum` · Confidence: 95

**Description**
`proposalThreshold` is `GOV_TOKEN_SUPPLY / 1_000` (a fixed 10,000e18 measured against total GOV) while `quorum(t)` is `stGOV.getPastTotalSupply(t) * 1 / 1_000` (measured against staked supply); because stGOV is a 1:1 wrapper, staked supply can never exceed total supply, so `quorum <= proposalThreshold` holds identically for every reachable state and any account able to propose satisfies quorum with its own ballot.

Executed end-to-end by three agents: an attacker staking 10,000 GOV (0.1% of supply) proposed, voted alone, queued, waited the 2-day timelock and executed — changing the Lender manager and setting `govStakingBps` to 0. At a realistic launch state quorum is 500e18 against a proposer holding 10,000e18 — exceeded 20×. `GovernorCountingSimple._quorumReached` counts `forVotes + abstainVotes`, so even an Abstain clears it.

**Fix (Option A — rebase)**

```diff
+ function quorum(uint256) public pure override returns (uint256) {
+     return GOV_TOKEN_SUPPLY * 4 / 100;   // 4% of total supply
+ }
```

**Fix (Option B — restrict)**

```diff
- uint256 public constant GOVERNOR_QUORUM_NUMERATOR = 1;
+ uint256 public constant GOVERNOR_QUORUM_NUMERATOR = 400;   // 40% of staked supply
```

> ⚠️ Both raise a deadlock risk in the opposite direction: a quorum that actually binds can freeze a young DAO whose staked float is near zero, permanently locking the timelock that owns the router and the 28% treasury vest. Either option needs a bootstrap path — and note that `updateQuorumNumerator` is itself `onlyGovernance`, so the escape hatch is gated on the thing being blocked.

---

[95] **3. The Lender local-reserve fee is zero at launch and can never be raised**

`CoinDAOFactory._deployCoinDAO` · Confidence: 95

**Description**
Monolith's `Lender.feeBps` is never assigned (not in the constructor, not in `DeployParams`) and its only writer is `setLocalReserveFeeBps`, which is `onlyOperator`; Phase 5 hands the operator role permanently to `RevenueRouter`, which exposes no passthrough for it — so every CoinDAO is born with its protocol fee at 0 and no actor can ever change it, nullifying the revenue stream the whole design depends on.

Confirmed by read-only `eth_call` against live mainnet Lender `0xf8B349dA9244253288f6853835e6582955FD49c9` at block 25884025: `feeBps() == 0`; `setLocalReserveFeeBps(500)` reverts `Unauthorized` from the manager and from a random address, and succeeds only from the operator. A second live lender also reports `feeBps() == 0`. `enableImmutabilityNow()` is likewise `onlyOperator` and becomes permanently unreachable by the same mechanism.

**Fix**

```diff
+ function setLocalReserveFeeBps(uint256 newFeeBps) external onlyOwner {
+     lender.setLocalReserveFeeBps(newFeeBps);
+ }
```
and declare it on `IMonolithLender`, with `_deployCoinDAO` setting a non-zero launch fee before `revenueRouter.acceptLenderOperator()`.

> ⚠️ Counter-risk: this hands a governance-capturing majority the ability to raise the fee to Monolith's 1000 bps cap, shifting interest from sCoin stakers to the DAO treasury. That is bounded by Monolith's own cap and is identical to the authority any independently-operated Monolith market's operator already holds — strictly less dangerous than the current unfixable-zero state.

---

[92] **4. The launch allocation converts into permanent, token-independent control of the timelock**

`CoinDAOFactory._deployCoinDAO` · Confidence: 92

**Description**
`allocation.immediateAllocation` (500,000e18 at `deployerStakeBps = 0`) is the only unlocked GOV in existence at genesis, and combined with the non-binding quorum above its holder can pass a single proposal granting itself `PROPOSER_ROLE` and revoking the Governor's — after which it may sell every token and still drive the timelock directly, including taking ownership of the vesting wallet holding 2,800,000e18 GOV.

Executed: after the role swap the attacker's balance and votes are zero yet `timelock.schedule()` / `execute()` still succeed, while a later honest holder with the same 500,000 GOV reaches state `Succeeded` and then `queue()` **reverts** — the Governor no longer holds `PROPOSER_ROLE`. Irreversible.

**Fix**

```diff
- govTokenErc20.safeTransfer(immediateRecipient, allocation.immediateAllocation);
+ CoinDAOVestingWallet immediateVesting = /* clone + initialize(immediateRecipient, vestingStart, LOCKUP) */;
+ govTokenErc20.safeTransfer(address(immediateVesting), allocation.immediateAllocation);
```

> ⚠️ **Do not ship this fix alone.** Locking the immediate allocation removes the only genesis voting power and directly causes finding 6 (bootstrap deadlock). The two defects trade off against each other and the correct remedy addresses both at once — seed a bounded, votable genesis stake rather than either extreme.

---

[90] **5. No address can cancel a queued timelock operation**

`CoinDAOFactory._deployCoinDAO` · Confidence: 90

**Description**
`CANCELLER_ROLE` is granted only to the Governor, and `Governor.cancel` → `_validateCancel` requires the proposal to be `Pending` *and* the caller to be the original proposer — so once an operation is `Queued` the role is unreachable by anyone, making the 2-day delay a notice period with no remedy behind it.

Verified by execution and by explicit absence check, not assumed: `hasRole(CANCELLER_ROLE, x)` returns true only for the Governor (false for the timelock itself, `address(0)`, and the factory). OZ v5.6.1 `TimelockController`'s only other grant site loops over `proposers`, which the factory passes as an **empty array**, so it never fires. This is what makes finding 4 unstoppable.

**Fix**

```diff
  timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
  timelock.grantRole(timelock.CANCELLER_ROLE(), address(governor));
+ timelock.grantRole(timelock.CANCELLER_ROLE(), monolithBeneficiary);
  timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), address(this));
```

> ⚠️ Counter-risk: a guardian canceller can censor legitimate proposals indefinitely — a real cost, and plausibly why the current design omits it. If the omission is deliberate it should be documented, because finding 4 is irreversible *only* because of it.

---

[90] **6. The shipped default launch parameters strand the entire token supply**

`CoinDAOFactory._deployCoinDAO` · Confidence: 90

**Description**
`_validate` rejects `deployerStakeBps != 0` with a zero recipient but permits `deployerStakeBps == 0` with a zero recipient — the deploy script's default — which routes the immediate allocation to the timelock and leaves 100% of GOV held by contracts that cannot stake, so no address can reach the 10,000e18 proposal threshold and no proposal can ever be created.

Executed: post-deploy balances are timelock 500,000e18, treasuryVesting 2,800,000e18, monolithVesting 200,000e18, funder 4,387,500e18, StakingRewards 2,112,500e18, factory 0, EOAs 0. `propose()` reverts for every party. The DAO's only two levers — `setGovStakingBps` and `setManager` — are frozen while the lending market runs live. Earliest recovery from the monolith beneficiary's vesting stream alone is 73.05 days.

**Fix**

```diff
  function _validate(GovLaunchParams calldata params) internal pure {
      if (params.deployerStakeBps > MAX_DEPLOYER_STAKE_BPS) revert DeployerStakeExceedsMaximum(params.deployerStakeBps);
-     if (params.deployerStakeBps != 0 && params.deployerRecipient == address(0)) revert DeployerRecipientRequired();
+     if (params.deployerRecipient == address(0)) revert DeployerRecipientRequired();
  }
```

> ⚠️ **Do not ship this fix alone** — forcing a non-zero recipient hands that party the genesis monopoly of finding 4. See the combined remedy noted there.

---

[88] **7. The attach path inherits the outgoing operator's manager**

`CoinDAOFactory.deployForExistingCoin` · Confidence: 88

**Description**
`deployForExistingCoin` transfers only the operator role and never reads, validates, or replaces the lender's existing manager, so the previous operator's appointee retains every `onlyOperatorOrManager` power on a market now presented as DAO-controlled.

Executed and confirmed live: after attachment `lender.operator() == revenueRouter` but `lender.manager() == existingManager`, and that incumbent successfully calls `setManager(0xBADBAD)`. On mainnet, `setHalfLife`, `setTargetFreeDebtRatio`, `setRedeemFeeBps` and `setMaxBorrowDeltaBps` all carry the same modifier, so this is real economic control. `deploy()` rejects a zero manager; `deployForExistingCoin` has no manager parameter at all. The DAO's only remedy is a full governance cycle — roughly 8 days on mainnet. `plan.md` step 10 requires setting the manager; only the `deploy()` path does.

**Fix**

```diff
- function deployForExistingCoin(bytes32 userSalt, GovLaunchParams calldata govParams, address lenderAddress)
+ function deployForExistingCoin(bytes32 userSalt, GovLaunchParams calldata govParams, address lenderAddress, address manager)
      external returns (Deployment memory deployment)
  {
+     if (manager == address(0)) revert ZeroAddress();
      ...
      lender.acceptOperator();
+     lender.setManager(manager);
```

---

[85] **8. The vesting schedule constrains when tokens leave but not who owns the wallet**

`CoinDAOVestingWallet.transferOwnership` · Confidence: 85

**Description**
`CoinDAOVestingWallet` adds nothing to OpenZeppelin's `VestingWalletUpgradeable`, which is `Ownable` with the beneficiary as owner — so any beneficiary can move the entire *unvested* remainder in one call, which OZ's own NatSpec states plainly: *"Since the wallet is {Ownable}, and ownership can be transferred, it is possible to sell unvested tokens."*

At 30 days into the schedule, a release-and-forward moves 5.75e22 GOV from the treasury wallet while `transferOwnership` moves the full 2.8e24 remaining — a 48× amplification, largest exactly when the vest is meant to be most protective. `renounceOwnership()` is the mirror failure: it sets the owner to `address(0)`, after which `release()` reverts and the entire balance is permanently bricked.

**Fix**

```diff
+ function transferOwnership(address) public pure override { revert NonTransferable(); }
+ function renounceOwnership() public pure override { revert NonTransferable(); }
```

> ⚠️ Counter-risk: pinning strands the stream for four years if a beneficiary loses its key, and the timelock is self-administered and immutable so this is not hypothetical. A middle option prices both — permit transfer but force a release of all currently-vested tokens to the outgoing owner first, so only the genuinely unvested remainder can move.

---

[85] **9. `setGovStakingBps` re-prices revenue accrued under the previous split**

`RevenueRouter.setGovStakingBps` · Confidence: 85

**Description**
The setter writes the new split without settling revenue already accrued under the old one, while every user-side path (`depositFor`, `harvestAndWithdraw`, `harvestAndGetReward`) is forced through `harvestYield` first — so an unbounded, unattributed backlog is retroactively priced at whichever rate the caller of the permissionless `distribute()` arranges to be in force.

The unprivileged amplifier is concrete: OZ v5 `Governor.execute()` is permissionless *and* the timelock was constructed with `executors[0] = address(0)`, so one transaction can bundle `execute(raise-bps)` + `distribute()` atomically with no chance to interleave. Worked trace: 90 days of accrual at 3,000 bps, treasury owed 70,000 Coin, receives 0. The mirror case is equally live — timelock ops are publicly queued two days ahead, so an observer can pick the side by front- or back-running with a bare `distribute()`.

**Fix**

```diff
  function setGovStakingBps(uint16 newGovStakingBps) external onlyOwner {
      if (newGovStakingBps > MAX_BPS) revert InvalidGovStakingBps(newGovStakingBps);
+     if (coin.balanceOf(address(this)) != 0 || lender.accruedLocalReserves() != 0) revert UnsettledRevenue();
      emit GovStakingBpsUpdated(govStakingBps, newGovStakingBps);
```

> ⚠️ Counter-risk: calling `distribute()` inside the setter makes it inherit every revert path of `pullLocalReserves()`, so a distressed Lender would block governance from changing the split exactly when it most needs to. The guard form above avoids that by requiring the backlog be *provably* empty rather than settling it inline.

---

[82] **10. A sole staker captures an entire revenue batch regardless of stake size**

`StakedGovToken.notifyRewardAmount` · Confidence: 82

**Description**
`rewardPerTokenStored += mulDiv(reward, 1e18, supply)` accrues a whole notification instantly to the supply present at that instant with no time weighting, so 1 wei of stGOV takes 100% of revenue that accumulated over an arbitrary prior window, and `DEFAULT_GOV_STAKING_BPS = 10_000` routes 100% of Coin revenue to stGOV.

Executed: with 10,000 Coin/day of lender revenue, a 1-wei staker claims 100.0000% at 1, 7 and 30 days; the honest depositor accrues 0 and the treasury receives 0. Note the naive just-in-time sandwich is correctly *defended* — `harvestYield` runs before `updateReward` and before the mint, so a new depositor's own harvest flushes the pending pot to incumbents. It is the sole-occupant case that survives, and at launch it coincides with the zero-circulating-GOV condition of finding 6.

**Fix**

```diff
  function initialize(...) external initializer {
      ...
+     _mint(address(0xdead), 1e18);   // non-redeemable dead share
  }
```

---

[80] **11. The only path that mints voting power is hard-coupled to an external call**

`StakedGovToken.depositFor` · Confidence: 80

**Description**
`depositFor` is the sole mint path for stGOV and carries `harvestYield` unconditionally, which calls `revenueRouter.distribute()` → `lender.pullLocalReserves()` with no `try/catch` and no fallback — so a persistent Lender revert permanently freezes governance membership while exits and reward claims keep working.

The asymmetry is self-evidencing: the authors gave `getReward()` and `withdraw()` explicit escape hatches and documented them ("This remains available if the external revenue distribution mechanism is unavailable"), and left the one function that mints voting power with none. Executed with `vm.mockCallRevert` on `pullLocalReserves()`: `depositFor`, `harvestAndGetReward` and `harvestAndWithdraw` revert while `getReward` and `withdraw` succeed, and stGOV supply drains to zero with no path to increase it. `revenueRouter` has no setter, and `RevenueRouter` exposes no operator migration — governance has zero power over this path.

**Fix**

```diff
- modifier harvestYield() { revenueRouter.distribute(); _; }
+ modifier harvestYield() {
+     try revenueRouter.distribute() {} catch { emit HarvestFailed(); }
+     _;
+ }
```

> ⚠️ Counter-risk: a swallowed harvest lets a depositor enter before pending revenue is distributed, diluting incumbents' claim on it. That dilution is bounded, transient and self-correcting on the next successful harvest; the freeze is permanent. The mandatory event is what keeps the degraded state observable.

---

[80] **12. `updateQuorumNumerator` can set an unreachable quorum, irreversibly**

`CoinDAOGovernor.updateQuorumNumerator` · Confidence: 80

**Description**
`quorumDenominator()` is overridden to `1_000` and OZ bounds only the upper edge (`newQuorumNumerator <= denominator`), so numerator 1000 sets quorum to 100% of *staked* supply while only *delegated* stGOV can vote — and since `StakedGovToken` never auto-delegates, one wei of undelegated stGOV makes quorum arithmetically unreachable at any turnout.

The loop closes on itself: `updateQuorumNumerator` is `onlyGovernance`, reaching governance requires a successful proposal, and a successful proposal requires quorum. `againstVotes` do not count toward quorum, so opposition cannot rescue the tally. The frozen timelock owns `RevenueRouter`, is `RevenueRouter.treasury`, and is beneficiary of the 2.8e24 GOV treasury vest — where `release()` is permissionless, so GOV keeps arriving and can never leave. Reachable by a 10,000 GOV holder via finding 2, or with no attacker at all by an ordinary "raise quorum to 20%" housekeeping vote.

**Fix**

```diff
+ function updateQuorumNumerator(uint256 newQuorumNumerator) external override onlyGovernance {
+     require(newQuorumNumerator <= 200, "quorum ceiling");   // 20% of quorumDenominator
+     _updateQuorumNumerator(newQuorumNumerator);
+ }
```

> ⚠️ Counter-risk: a hard ceiling means the DAO can never raise the bar above it even when maturity warrants, locking in a cheap-capture regime. The two failure modes are in direct tension; only a two-sided bound resolves them — an upper bound on the numerator plus an absolute floor expressed in GOV. Note the floor has a third failure mode of its own: set above the launch float, it bricks governance from block zero.

---

[75] **13. An incomplete harvest lets a new depositor capture revenue earned before their stake**

`StakedGovToken.depositFor` · Confidence: 75

**Description**
The anti-sandwich property of `depositFor` rests entirely on an unstated assumption — that `pullLocalReserves()` transfers every outstanding wei in a single call — and if the Lender caps, rate-limits or partially pulls, an attacker deposits after revenue accrues, lets the partial harvest pay incumbents, then calls the permissionless `distribute()` repeatedly to take the remainder.

Executed against a slice-releasing Lender: Alice is sole staker with 1,000 stGOV when 100,000 Coin accrues; the attacker deposits 99,000 GOV, the harvest pulls one 10,000 slice (correctly all Alice's), and nine further `distribute()` calls hand the attacker 89,100 Coin — 89.1% of revenue that accrued entirely before their stake existed. Alice receives 10,900 instead of 100,000. Whether this is live or theoretical is decided by one fact about the deployed Lender's pull semantics.

---

[75] **14. The address predictor advertises a vesting wallet that is never deployed**

`CoinDAOFactory.predictCoinDAOAddresses` · Confidence: 75

**Description**
`predictCoinDAOAddresses` computes `predicted.deployerVesting` unconditionally while `_deployCoinDAO` clones it only when `allocation.deployerVesting != 0`, so under the script's default (`deployerStakeBps = 0`) the returned address never receives code and anything sent there is unrecoverable — only the factory can `cloneDeterministic` to it, and the deployment key is permanently consumed.

Executed: at `deployerStakeBps = 0` the predicted address `0xEec16244207EdFb81DC044f239113d66ed34CAA3` has `code.length == 0` while `deployment.deployerVesting == address(0)`; a control at 1000 bps matches deployment and has code, isolating the divergence to the zero boundary. The prediction already receives `govParams` and simply ignores `deployerStakeBps`.

---

[70] **15. `trancheAmount(3)` reports a live balance instead of its scheduled share**

`StakingRewardsFunder.trancheAmount` · Confidence: 70

**Description**
`_trancheAmount` returns `rewardsToken.balanceOf(address(this))` for the final tranche rather than `totalRewards * trancheBps(3) / BPS`, so before the earlier tranches are drawn the view reports nearly the whole pot — 4,387,500 GOV against a documented 1,137,500 GOV, a 3.86× overstatement — and the four views sum to 9,750,000 GOV against a 6,500,000 GOV programme. `trancheBps(3)` returns the correct 1,750 and is never read by any funding path.

---

[70] **16. `deploy()` forwards caller-supplied market parameters unvalidated**

`CoinDAOFactory.deploy` · Confidence: 70

**Description**
`deploy()` copies `monolithParams_` and overrides only `.operator` and `.manager`, passing `collateral`, `psmAsset`, `psmVault`, `feed`, `collateralFactor`, `minDebt`, `timeUntilImmutability`, `redeemFeeBps`, `stalenessThreshold` and `maxBorrowDeltaBps` through untouched — the sanity bounds exist only in the deploy *script*, not the contract. `timeUntilImmutability = 0` hands the resulting DAO a market its own governance can never adjust, while the launch still mints the full 10,000,000 GOV and presents as governed; a hostile `psmVault` is also the concrete trigger for finding 11.

---

Findings List

| # | Confidence | Title |
|---|---|---|
| 1 | [95] | Tranche-0 emissions begin against a provably empty staking pool |
| 2 | [95] | Quorum denominated in staked supply while threshold uses total supply |
| 3 | [95] | Lender local-reserve fee is zero at launch and can never be raised |
| 4 | [92] | Launch allocation converts into permanent timelock control |
| 5 | [90] | No address can cancel a queued timelock operation |
| 6 | [90] | Shipped default launch parameters strand the entire token supply |
| 7 | [88] | Attach path inherits the outgoing operator's manager |
| 8 | [85] | Vesting constrains when tokens leave but not who owns the wallet |
| 9 | [85] | `setGovStakingBps` re-prices revenue accrued under the previous split |
| 10 | [82] | A sole staker captures an entire revenue batch regardless of size |
| 11 | [80] | The only path that mints voting power is hard-coupled to an external call |
| 12 | [80] | `updateQuorumNumerator` can set an unreachable quorum, irreversibly |
| 13 | [75] | Incomplete harvest lets a depositor capture pre-stake revenue |
| 14 | [75] | Address predictor advertises a vesting wallet that is never deployed |
| 15 | [70] | `trancheAmount(3)` reports a live balance instead of its scheduled share |
| 16 | [70] | `deploy()` forwards caller-supplied market parameters unvalidated |

---

## Leads

_Vulnerability trails with concrete code smells where the full exploit path could not be completed in one analysis pass. These are not false positives — they are high-signal leads for manual review. Not scored._

- **Operator powers beyond `setManager` are permanently forfeited** — `RevenueRouter` (no function) — Code smells: the router captures the Lender operator role irrevocably and re-exposes only `pullLocalReserves` and `setManager`; `IMonolith.sol` declares just four operator-gated functions and the team has not asserted the list is exhaustive — any other operator-gated Lender function becomes permanently unreachable for every CoinDAO, with no migration path.
- **`renounceOwnership` / single-step `transferOwnership` left exposed on the permanent operator** — `RevenueRouter.renounceOwnership` — Code smells: one passed proposal, malicious or mis-encoded, permanently removes `setGovStakingBps` and `setManager` — the DAO's only remaining levers over a lender whose operator role can never be reassigned.
- **stGOV has no unbonding period, making voting weight rentable** — `StakedGovToken.withdrawTo` — Code smells: non-transferability signals committed stake but `withdrawTo` burns immediately; OZ Governor reads weight at only two timepoints (`clock()-1` and the snapshot), so weight need be held across ~4 block boundaries rather than the 43,200 blocks the parameters imply. A same-block flash loan yields 0 votes, but a 2-block borrow suffices. Composes directly with finding 2.
- **`withdraw()` silently forfeits undistributed revenue** — `StakedGovToken.withdrawTo` — Code smells: the deposit side is JIT-hardened and the withdraw side is not, so the obviously-named exit donates accrued-but-unharvested revenue to whoever remains; `harvestAndWithdraw` is the correct exit. Documented, but a foot-gun with no attacker-forced path.
- **`distribute()` is permissionless with no reentrancy guard** — `RevenueRouter.distribute` — Code smells: `amount` is snapshotted, then two external transfers follow before the stale `treasuryAmount` is spent; `RevenueRouter` is the only stateful contract here that does not inherit `ReentrancyGuard`. The contract header declares hooked tokens unsupported, so this is hardening rather than a live path.
- **Treasury receives no revenue at the shipped default** — `RevenueRouter.initialize` — Code smells: `DEFAULT_GOV_STAKING_BPS = 10_000` sends 100% to stakers and 0% to treasury, while `plan.md` §7 describes a split where "the remainder goes to Treasury" — at the default there is never a remainder, and the only party who can change it is the stakers voting to cut their own income.
- **Beneficiary rotation does not migrate existing vesting wallets** — `CoinDAOFactory.acceptMonolithBeneficiary` — Code smells: the two-step transfer reads as a full handover but `monolithVesting.initialize` snapshots the beneficiary per deployment; proven behaviourally that after rotation, earlier deployments' wallets stay with the old beneficiary. Correct for a cooperative handover, wrong for a compromised-key rotation.
- **`setManager` may be undoable by the incumbent manager** — `RevenueRouter.setManager` — Code smells: the in-repo mock permits `msg.sender == operator || msg.sender == manager`; if the real Lender does the same, governance's 2-day timelocked replacement can be immediately reverted by the manager, making the control nominal.
- **Vendored OpenZeppelin is unpinned** — build — Code smells: `foundry.lock` and `.gitmodules` pin only `forge-std` v1.16.1; OpenZeppelin supplies Governor, TimelockController, ERC20Votes, ERC20Wrapper, VestingWallet, Ownable and SafeERC20 — most of the deployed bytecode — with no submodule entry, lock entry, or version constraint anywhere in the repo. Only prose in `novel_code.md` names v5.6.1.
- **Governor timing constants are block-based on a chain-agnostic factory** — `CoinDAOGovernor.votingDelay` — Code smells: 7,200 and 36,000 blocks are compile-time constants matching 1 day / 5 days at 12s blocks; the token supplies no `clock()` override. On a 2s chain these silently become a 4h delay and a 20h vote.
- **Reward truncation with no residual carry** — `StakedGovToken.notifyRewardAmount` — Code smells: `mulDiv` floors with no accumulator, stranding up to `supply / 1e18` wei per call and the whole reward when `reward * 1e18 < supply`. Genuine dust at 18 decimals; at 6 decimals the threshold becomes ~0.40 Coin per call and permissionless `distribute()` could be spammed to zero out revenue at gas cost only.
- **`StakingRewardsFunder.initialize` stores an unvalidated collaborator value** — `StakingRewardsFunder.initialize` — Code smells: `rewardsToken = stakingRewards_.rewardsToken()` with no zero-check, unlike every sibling initializer; if the collaborator is uninitialized the funder is permanently bricked. The factory's ordering happens to make the live path safe.
- **Non-upgradeable `ReentrancyGuard` used in cloned contracts** — `StakedGovToken.constructor` — Code smells: three contracts deployed exclusively as clones inherit the constructor-initialized guard, so `_status` starts at 0 rather than `NOT_ENTERED`. Safe under OZ v5 semantics (`== ENTERED` is the only test) but a latent dependency on sentinel encoding rather than documented behaviour.
- **The leftover-carry branch of `notifyRewardAmount` is unreachable** — `StakingRewards.notifyRewardAmount` — Code smells: the funder's `periodFinish` gate means the `if` branch is always taken, so no reward is ever rolled forward. Not a defect itself — the reason finding 1 has no self-healing path.
- **No recovery for non-`coin` assets** — `RevenueRouter.distribute` — Code smells: the router's entire asset-moving surface is two `coin.safeTransfer` calls, with no sweep, no `receive()`, and no upgrade path, while being the Lender's permanent operator. Any other token that arrives is locked forever. The strongest trigger was checked and discharged — `pullLocalReserves()` mints only `coin` to the operator — leaving only donation and airdrop paths.
- **`deployForExistingCoin` omits the zero-address checks `deploy()` performs** — `CoinDAOFactory.deployForExistingCoin` — Code smells: `lender.coin()` and `lender.vault()` are stored unchecked; a zero coin is caught downstream by the initializers, but with `stakingTokenChoice == Coin` a zero vault is silently written into the `Deployment` struct and emitted in `CoinDAODeployed` as the market's canonical vault.
- **`CoinDAOFactory` may be a confused deputy for market creation** — `CoinDAOFactory.deploy` — Code smells: `deploy()` is fully permissionless and calls `monolithFactory.deploy()` under the factory's own identity; if the real Monolith factory gates deployment by caller, this is an open bypass letting anyone mint arbitrary markets under a whitelisted identity.

---

> ⚠️ This review was performed by an AI assistant. AI analysis can never verify the complete absence of vulnerabilities and no guarantee of security is given. Team security reviews, bug bounty programs, and on-chain monitoring are strongly recommended. For a consultation regarding your projects' security, visit [https://www.pashov.com](https://www.pashov.com)
