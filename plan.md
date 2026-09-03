# **Monolith CoinDAO Factory**

**Simplified v1 Product and Technical Spec**

This version simplifies the CoinDAO Factory design around a small number of standard modules, fixed defaults, and minimal custom governance surface. The goal is to keep the core business value \- per-coin upside, incentives, treasury, and revenue share \- while making v1 much easier to build, audit, and explain.

# **1\. Decision summary**

* **Optional per stablecoin:** deployers can launch a Monolith stablecoin with or without a CoinDAO.  
* **Single formula-based supply distribution:** no launch templates; vested deployer stake is capped and handled by the standard formula.
* **Immediate deployer allocation:** `5% * scale` is liquid at launch for a specified deployer recipient, with the DAO treasury as the fallback.
* **Optional deployer stake:** deployer may set a 0% to 20% GovToken allocation at launch, vested linearly over 4 years.  
* **Default CoinStakingRewards:** 65% of supply at 0% deployer stake, reduced pro rata as deployer stake increases; deployer chooses whether staking token is Coin or sCoin.  
* **GovStaking retained:** GovToken stakers receive Coin revenue accrued at each distribution and receive the voting receipt token.
* **Minimal governance powers:** governance controls treasury, RevenueRouter settings, and can replace the Lender manager.  
* **Operational management remains simple:** the Lender manager can be a multisig for day-to-day experimentation and management.  
* **Use off-the-shelf code where possible:** OpenZeppelin-style ERC20Votes, Governor, Timelock, and vesting primitives should be used where practical.

# **2\. Product rationale**

The original design became broader than needed for v1. The simplified design keeps the actual missing product piece: an optional per-stablecoin token and treasury layer that helps deployers bootstrap demand and gives users a reason to participate early.

The product should not be a generic ERC20 deployer. It should be a standardized, Monolith-supported CoinDAO launch path with clear disclosures, simple economics, and enough governance to manage treasury and delegate protocol management.

# **3\. Fixed supply distribution**

Every factory-launched GovToken should use the same supply distribution formula. This removes launch-template complexity while allowing a bounded, disclosed deployer allocation.

Let `D` be the deployer stake in percentage points of total GovToken supply, where `0 <= D <= 20` and `D = 20` means 20%. Monolith always receives a fixed 2%. The remaining non-Monolith, non-deployer-vesting supply is split in a 65:5:28 ratio between CoinStakingRewards, an immediate liquid allocation, and vested DAO treasury:

`scale = (98 - D) / 98`

| Bucket | Allocation | Treatment / purpose |
| :---- | :---- | :---- |
| CoinStakingRewards reserve | `65% * scale` | Funds the default staking rewards program over 4 years. |
| Immediate allocation | `5% * scale` | Issued liquid to `deployerRecipient`; sent to the DAO treasury when no recipient is specified. |
| DAO treasury vesting | `28% * scale` | Vests linearly over 4 years. |
| Monolith allocation | 2% | Fixed allocation for Monolith; recommended simple linear vesting. |
| Deployer vesting | `D%`, max 20% | Optional launch allocation set by deployer and vested linearly over 4 years. |

At `D = 0`, the distribution is 65% CoinStakingRewards, 5% immediate allocation, 28% vested DAO treasury, and 2% Monolith. At the maximum `D = 20`, CoinStakingRewards becomes 51.7347%, the immediate allocation becomes 3.9796%, vested DAO treasury becomes 22.2857%, Monolith remains 2%, and deployer vesting receives 20%.

The optional `D%` deployer stake is not liquid at genesis; it always vests over 4 years. Independently, a nonzero `deployerRecipient` opts into the liquid immediate allocation even when `D = 0`. When `deployerRecipient` is zero, `D` must also be zero and the immediate allocation remains in the DAO treasury.

# **4\. Core contract set**

| Contract / module | Purpose |
| :---- | :---- |
| CoinDAOFactory | Deploys and wires the simplified CoinDAO stack for a Monolith Lender/Coin. |
| GovToken | Fixed-supply vote-enabled ERC20 token. No post-deployment minting in v1. |
| GovStaking / stGOV | Users stake GOV, receive stGOV, earn Coin revenue, and use stGOV for governance. |
| Governor \+ Timelock | Standard proposal, voting, queueing, and execution stack. |
| RevenueRouter | Lender operator. Receives local reserves and routes Coin revenue between GovStaking and Treasury. |
| Treasury | DAO-controlled asset pool for incentives, grants, liquidity, integrations, and team funding if later approved. |
| TreasuryVesting | Releases the vested treasury allocation linearly over 4 years. |
| MonolithVesting | Holds the fixed 2% Monolith allocation. |
| DeployerVesting | Holds the optional deployer allocation and releases it linearly over 4 years. |
| CoinStakingRewards | Default bootstrap module. Users stake Coin or sCoin and earn GovToken emissions. |

# **5\. CoinStakingRewards**

CoinStakingRewards is the main bootstrap mechanism. It should be deployed by default for every factory CoinDAO.

* Rewards token: GovToken.  
* Staking token: chosen by the deployer at launch: either naked Coin or sCoin.  
* Emission allocation: `65% * scale` of total GovToken supply.  
* Emission duration: 4 years.  
* Predefined modest front-loaded curve.  
* No arbitrary recipient list or LP/bribe integrations in this module.

| Year | % of CoinStakingRewards reserve | % of total GovToken supply |
| :---- | :---- | :---- |
| Year 1 | 32.5% | `21.125% * scale` |
| Year 2 | 27.5% | `17.875% * scale` |
| Year 3 | 22.5% | `14.625% * scale` |
| Year 4 | 17.5% | `11.375% * scale` |

Implementation note: this should be a preset emissions schedule, not notifyRewardAmount-style revenue streaming. If no staking token is staked, rewards should not be allocated to any user. The simplest acceptable handling is that unallocated rewards remain in the rewards contract and are either rolled forward by the emissions logic or recoverable by governance at the end of the program.

# **6\. GovStaking / stGOV**

GovStaking is kept in v1 because direct revenue share is important for GovToken value accrual. The simplified model avoids cooldowns, withdrawal escrows, and separate voting tokens.

* Users stake GOV and receive stGOV.  
* stGOV is the voting token used by Governor. Raw unstaked GOV does not need to vote in v1.  
* stGOV earns Coin revenue accrued immediately from RevenueRouter distributions.
* stGOV should support delegation, so users can delegate voting power to another address.  
* stGOV can be non-transferable for simpler reward accounting.  
* Unstaking is instant: burn stGOV and receive the underlying GOV back.  
* No staking cooldown and no proportional withdrawal escrow in v1.

RevenueRouter sends Coin to GovStaking and notifies the new reward amount. Each notification immediately increases a reward-per-stGOV accumulator, so only the stGOV supply present at distribution time earns that revenue. Holders claim their accrued Coin from GovStaking. The router is configured as the immutable reward notifier during factory deployment.

# **7\. RevenueRouter**

RevenueRouter should be much simpler than the earlier multi-recipient design. It remains useful because the Lender mints local reserves to operator when reserves are pulled, and RevenueRouter is the standard operator for CoinDAO-enabled Lenders.

* Lender.operator \= RevenueRouter.  
* RevenueRouter.owner \= Timelock.  
* Anyone can call distribute() after revenue is available.  
* A single govStakingBps controls how much revenue goes to GovStaking.  
* The remainder goes to Treasury.  
* No arbitrary recipient list and no complex weight system.

Minimal routing logic:

`amountToGovStaking = amount * govStakingBps / 10000`  
`amountToTreasury = amount - amountToGovStaking`

If no stGOV supply exists when `distribute()` is called, `amountToGovStaking` is zero and all revenue is sent to Treasury.

Required governance-controlled functions should be limited to the essentials:

* setGovStakingBps(uint16 newBps)  
* setManager(address newManager) to replace the Lender manager if needed  
* optional setTreasury / setGovStaking address updates if not made immutable  
* optional operator handoff / recovery function if devs want a safe upgrade path

# **8\. Governance model**

Governance should be standard and minimal. The goal is not for token holders to manage every Lender parameter. The goal is for token holders to control the treasury and retain the ability to replace the operational manager.

| Governance area | Simplified v1 design |
| :---- | :---- |
| Voting token | stGOV |
| Execution | Timelock-controlled arbitrary execution |
| Treasury control | Governor \-\> Timelock controls Treasury |
| Revenue control | Governance can update govStakingBps |
| Protocol control | Governance can change the Lender manager |
| Day-to-day Lender management | Manager multisig |
| Cancel guardian | Optional 12-month cancel guardian if simple to implement |

Recommended cadence can remain simple: 1-day voting delay, 5-day voting period, 2-day timelock, an initial quorum of 0.1% of fixed GOV supply, and a 0.1% proposal threshold. Use standard checkpoint-based vote accounting.

# **9\. Role wiring**

| Role / relationship | Recommended wiring |
| :---- | :---- |
| Lender.operator | RevenueRouter |
| Lender.manager | Manager multisig by default; replaceable by governance through RevenueRouter |
| RevenueRouter.owner | Timelock |
| Treasury controller | Timelock |
| Governor voting token | stGOV |
| CoinStakingRewards staking token | Deployer-selected Coin or sCoin |
| Immediate allocation recipient | `deployerRecipient` when nonzero; otherwise Timelock treasury |
| DeployerVesting beneficiary | Deployer-designated recipient, subject to 4-year linear vesting |

# **10\. Deployment flow**

1. Read deployer stake `D`, enforce `0 <= D <= 20`, and compute `scale = (98 - D) / 98`.  
2. Deploy GovToken with fixed supply.  
3. Deploy CoinStakingRewards and fund it with `65% * scale` of supply.  
4. Deploy GovStaking / stGOV.  
5. Deploy Governor \+ Timelock using stGOV as the voting token.  
6. Send the liquid `5% * scale` allocation to `deployerRecipient`, or to the Timelock treasury when the recipient is zero; fund `28% * scale` to TreasuryVesting.
7. Fund Monolith allocation contract with 2%.  
8. If `D > 0`, deploy DeployerVesting and fund it with `D%` of supply for the deployer-designated recipient.  
9. Deploy RevenueRouter and set it as Lender operator.  
10. Set initial Lender manager to the deployer/manager multisig.  
11. Transfer RevenueRouter and Treasury control to Timelock.  
12. UI disclosures: allocation, deployer stake and vesting, staking token choice, revenue share bps, manager, treasury, vesting, and governance settings.

# **11\. What has been removed vs the previous design**

* No launch templates.  
* No additional unrestricted team/deployer allocation beyond the standard scaled liquid allocation and optional capped 4-year deployer vesting.
* No stGOV withdrawal cooldown.  
* No proportional withdrawal escrow.  
* No dynamic revenue recipient list.  
* No arbitrary revenue routing weights.  
* No full Lender operator/manager wrapper surface.  
* No requirement for governance to manage every Lender parameter.  
* No separate LP/bribe module.  
* No multiple governance tokens or separate voting receipts beyond stGOV.

# **12\. Recommended v1 scope**

* Ship the formula-based supply distribution: optional 0% to 20% deployer vesting, fixed 2% Monolith stake, and the remaining supply split 65:5:28 between CoinStakingRewards, the immediate deployer-or-treasury allocation, and vested Treasury.
* Use the predefined 4-year front-loaded CoinStakingRewards curve.  
* Allow deployer to choose Coin or sCoin as the staking token.  
* Include GovStaking with stGOV, instant unstake, revenue share, and delegation.  
* Use a simple RevenueRouter with govStakingBps and Treasury fallback.  
* Use standard OpenZeppelin-style governance and vesting primitives wherever possible.  
* Keep Lender management with a manager multisig, but allow governance to replace it.  
* Keep the UI disclosure-focused: supply split, deployer stake, staking token, manager, revenue bps, vesting, and governance parameters.
