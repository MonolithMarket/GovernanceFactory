# NEMESIS — Phase 0 Recon

> ⛔ **Orchestrator discipline note.** The orchestrator has prior exposure to another
> lens's output on this same code. This recon is therefore restricted to **structural
> facts derivable from the architecture alone** — what exists, what holds value, what is
> coupled by data shape. It deliberately contains **no defect claims, no priority ordering
> derived from prior findings, and no hypotheses about what is wrong.** Pass 1 must reach
> its own conclusions.

**LANGUAGE:** Solidity 0.8.26, via-ir, optimizer 200 runs. Foundry. Builds and tests green
(55/55) at `[scratch]`.

---

## Q0.1 ATTACK GOALS — worst achievable outcomes

1. Take or permanently freeze the fixed 10,000,000 GOV supply, or any allocation of it.
2. Take or misdirect the Coin revenue stream flowing from the external lender.
3. Acquire, freeze, or permanently deny control of the governance system (Governor + Timelock).
4. Corrupt the launch so a deployed CoinDAO is misconfigured in a way nobody can repair.
5. Cause the external market's privileged roles to end up somewhere unintended.

## Q0.2 NOVEL CODE — highest expected bug density

| unit | why novel |
|---|---|
| `CoinDAOFactory` | bespoke 8-phase launch orchestration; allocation arithmetic; two entry paths; CREATE2 + clone address prediction |
| `StakedGovToken` | non-transferable ERC20Wrapper carrying both votes and an instant-accrual reward accumulator — an unusual combination |
| `RevenueRouter` | written for this integration; holds a privileged external role |
| `StakingRewardsFunder` | bespoke four-tranche schedule with a balance-sweep final tranche |
| `StakingRewards` | Synthetix port with hooks deliberately removed — deltas from the original are the interesting part |
| `CoinDAOGovernor` | OZ composition, but with an overridden `quorumDenominator` and factory-supplied parameters |

## Q0.3 VALUE STORES — where value sits, and what moves it out

| holder | asset | outflow paths | authorisation |
|---|---|---|---|
| `StakingRewardsFunder` | GOV (staking allocation) | `fundNextTranche()` | permissionless, gated on tranche index + `periodFinish` + `rewardsDistribution` identity |
| `StakingRewards` | GOV (streamed) | `getReward()`, `exit()` | per-account accrual |
| `StakingRewards` | Coin/sCoin (staked principal) | `withdraw()`, `exit()` | per-account balance |
| `StakedGovToken` | GOV (wrapped) | `withdrawTo()`, `withdraw()`, `harvestAndWithdraw()` | per-account balance |
| `StakedGovToken` | Coin (rewards) | `getReward()`, `harvestAndGetReward()`, `harvestAndWithdraw()` | per-account accrual |
| `RevenueRouter` | Coin (in transit) | `distribute()` | permissionless |
| 3 × `CoinDAOVestingWallet` | GOV | `release()` | permissionless call, pays the owner |
| `TimelockController` | GOV + any asset | queued operations | `PROPOSER` / `EXECUTOR` roles |
| external Lender | Coin reserves | `pullLocalReserves()` | operator role |

## Q0.4 COMPLEX PATHS — most interaction surface

1. `CoinDAOFactory.deploy()` → external factory → 8 internal phases → 6 clones + 2 CREATE2 deployments + 3 role handoffs + 5 token transfers, all in one transaction.
2. `CoinDAOFactory.deployForExistingCoin()` → the same 8 phases, but entered against pre-existing external state.
3. `StakedGovToken.depositFor()` → `harvestYield` → `RevenueRouter.distribute()` → external lender → back into `StakedGovToken.notifyRewardAmount()` → then the wrapper mint. One user action, four contracts, re-entering the originating contract.
4. `StakingRewardsFunder.fundNextTranche()` → `StakingRewards.notifyRewardAmount()` → reward-rate recomputation.

## Q0.5 COUPLED VALUE — initial coupling hypothesis (from data shape, not from findings)

Pairs where one value's meaning depends on another staying in step. Derived by reading
declarations only.

| # | coupled pair | invariant implied by the data shape |
|---|---|---|
| 1 | `StakingRewards._totalSupply` ↔ `rewardPerTokenStored` / `lastUpdateTime` | accrual per token depends on how many tokens exist at each instant |
| 2 | `StakingRewards._balances[a]` ↔ `userRewardPerTokenPaid[a]` ↔ `rewards[a]` | a balance change must settle the account first |
| 3 | `StakingRewards.rewardRate` ↔ `periodFinish` ↔ `rewardsToken.balanceOf(this)` | the rate must remain payable from the held balance |
| 4 | `StakedGovToken.totalSupply()` ↔ `rewardPerTokenStored` | same shape as pair 1, different accrual model |
| 5 | `StakedGovToken.balanceOf(a)` ↔ `userRewardPerTokenPaid[a]` ↔ `rewards[a]` | same shape as pair 2 |
| 6 | `StakedGovToken` wrapped supply ↔ underlying GOV held | ERC20Wrapper 1:1 backing |
| 7 | `StakingRewardsFunder.nextTranche` ↔ `rewardsToken.balanceOf(funder)` ↔ `totalRewards` | the schedule's remaining claim vs the balance backing it |
| 8 | `RevenueRouter.govStakingBps` ↔ Coin balance in transit | the split applied vs the stock it is applied to |
| 9 | `CoinDAOFactory.deployments[]` ↔ `deploymentKeyForId[]` ↔ `hasCoinDAO[]` ↔ `usedDeploymentKeys[]` | four registries indexed differently for the same launch |
| 10 | predicted addresses ↔ deployed addresses | prediction must equal deployment for every component |
| 11 | Timelock role set ↔ Governor identity | the Governor must retain the roles the design assumes |
| 12 | Lender `operator` ↔ `RevenueRouter` identity ↔ Lender `manager` | who holds which external role after handoff |
| 13 | `allocationFor()` outputs ↔ `GOV_TOKEN_SUPPLY` | the parts must sum to the whole |
| 14 | `monolithBeneficiary` ↔ each deployment's `monolithVesting` owner | rotation vs per-deployment snapshot |

## PRIORITY ORDER (by appearance count across Q0.1–Q0.5, not by suspicion)

1. `CoinDAOFactory` — appears in all five answers
2. `StakedGovToken` — value store, novel, complex path, two coupled pairs
3. `StakingRewards` + `StakingRewardsFunder` — value stores, three coupled pairs
4. `RevenueRouter` — value in transit, holds an external privileged role
5. `CoinDAOGovernor` + `CoinDAOVestingWallet` + `DeploymentLibraries` + `script/`
