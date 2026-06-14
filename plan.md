# Monolith CoinDAO Factory

# **1\. Executive summary**

The CoinDAO Factory is an optional layer for Monolith deployers. It lets a deployer launch a per-stablecoin governance token, treasury, revenue-share staking system, and stablecoin-demand incentives around a Monolith coin. The goal is to give teams and communities a real upside/co-ordination layer without changing the core Monolith lending design.

* Optional per-stablecoin system: deployers can launch a plain Monolith coin or opt into a CoinDAO.  
* GovToken is fixed supply in v1; no post-deployment minting.  
* CoinStakingRewards is core/default: naked Coin stakers earn GovToken emissions from launch.  
* GovToken staking is core/default: GovToken stakers receive streamed Coin revenue and govern through non-transferable, delegation-enabled stGOV.  
* RevenueRouter is the Lender operator. It receives local reserves and routes them according to governance-set weights, with any unallocated remainder sent to the DAO Treasury.  
* Governance has real powers: treasury control, revenue routing, operator actions, manager actions, incentive budgets, and manager delegation.  
* The Lender manager defaults to the Timelock, but governance can delegate the manager role to a multisig for faster experimentation and can later replace it again.  
* Team allocation is optional, capped at 20%, and vested over 4 years with a 1-year cliff.  
* DAO Treasury allocation vests over time; a small immediate launch budget is available on day 0\.  
* Monolith receives a fixed 2% allocation, vesting over 2 years.  
* A temporary cancel guardian exists for the first 12 months, that can cancel itself earlier if desired.

# **2\. Product and business decisions**

## **2.1 Launch model**

* Each opted-in Monolith stablecoin receives its own GovToken and CoinDAO.  
* The system is not forced. Deployers can still launch without a gov token.  
* Factory-launched CoinDAOs receive first-class UI support and standard disclosures.  
* The design is intentionally opinionated: enough standardization to make launches credible, not so much rigidity that serious teams avoid using it.

## **2.2 Allocation templates**

There is no airdrop/points bucket in the default design. The primary community distribution mechanism is CoinStakingRewards: users stake the naked Monolith Coin and earn GovToken emissions.

| Bucket | Fair launch | Standard launch | Team-led launch | Notes |
| :---- | :---- | :---- | :---- | :---- |
| CoinStakingRewards emissions reserve | 68% | 53% | 48% | Funds naked Coin staking rewards. Funded at launch and emitted by the selected preset schedule; active emissions pause while no Coin is staked. |
| DAO Treasury \- vested | 25% | 25% | 25% | 4-year linear vest, no cliff. Long-term DAO budget. |
| DAO immediate launch budget | 5% | 5% | 5% | Liquid on day 0\. Used for launch liquidity, market-making inventory, initial incentives, or urgent bootstrapping. |
| Team/deployer vesting | 0% | 15% | 20% max | 4-year vest with 1-year cliff. No liquid team allocation at launch. |
| Monolith allocation | 2% | 2% | 2% | Fixed for official factory launches. 2-year linear vest, no cliff. |

The DAO Treasury total is therefore 30%, split between a vested long-term treasury allocation and a 5% immediate launch budget. The 5% immediate budget is still a DAO-controlled allocation; it is separated only because it is available at launch rather than vested.

## **2.3 CoinStakingRewards is mandatory in v1**

* Users stake the naked Monolith Coin, not the sToken.  
* Stakers earn GovToken emissions from the CoinStakingRewards emissions reserve.  
* Emissions start immediately at first deposit to CoinStakingRewards at a defined rate according to the selected emission schedule.  
* This is the main bootstrap mechanism for stablecoin demand: users need to acquire or mint the Coin to farm GovToken.  
* External LP/bribe/partner incentives are not hardcoded in v1. They are funded through the DAO Treasury or delegated budgets.

## **2.4 What if no Coin is staked?**

CoinStakingRewards should not use notifyRewardAmount-style arbitrary top-ups for the core emissions schedule. That pattern belongs to GovTokenStaking revenue streaming.

For CoinStakingRewards, the GovToken allocation is funded at launch and emitted according to the selected preset schedule: either linear 4-year emissions or the predefined modest bootstrap curve.

The emissions schedule should be treated as an active-emission schedule, not a mechanism that blindly awards tokens when nobody is staking. If total Coin staked is zero, no user accrues rewards and the active-emission clock should pause.

When total Coin staked becomes non-zero again, the active-emission clock resumes and rewards accrue from that point forward at the scheduled rate. This prevents emissions from being wasted and prevents the first staker from capturing rewards for time when nobody was staking.

Unused emissions remain in the CoinStakingRewards reserve. They are not burned, awarded to nobody, or instantly handed to the next staker.

Implementation detail: the rewards contract or EmissionScheduler should update rewardPerToken only for elapsed time during which totalStaked \> 0\. A public checkpoint/poke function is fine, but it should only apply the preset schedule; it should not be an arbitrary admin-controlled reward notification flow.

## **2.5 CoinStakingRewards emission curve**

At deployment, the deployer should choose one of two standard emission curves. Custom curves should not be part of v1.

The selected curve is fixed at launch and should be clearly visible in the UI. Governance can still fund additional campaigns from the DAO Treasury, but the default CoinStakingRewards allocation should follow the chosen preset schedule.

The bootstrap curve is intentionally modest rather than aggressive: year 1 is 1.4x the linear schedule, not a large cliff-style front-load.

Rates are constant within each emission year/epoch. If no Coin is staked, the active-emission clock pauses; when staking resumes, the schedule continues from the same active-emission point rather than skipping ahead.

| Option | Year 1 | Year 2 | Year 3 | Year 4 | Notes |
| :---- | :---- | :---- | :---- | :---- | :---- |
| Linear 4-year | 25% | 25% | 25% | 25% | Simple and neutral default. Same emission rate throughout. |
| Modest bootstrap curve | 35% | 30% | 22.5% | 12.5% | Front-loads demand bootstrapping without extreme early inflation. Constant rate within each year. |

## **2.6 GovToken staking and revenue share**

* Users stake GovToken into GovTokenStaking and receive stGOV.  
* stGOV is non-transferable in v1. Transfers are disabled except mint on stake and burn on unstake/cooldown.  
* stGOV represents governance voting power, claim on streamed Coin revenue, and withdrawal claim on underlying GovToken.  
* stGOV supports vote delegation. A staker can delegate voting power to themselves, a team multisig, a public delegate, or any other address.  
* Non-transferability keeps unclaimed reward accounting simple: rewards stay with the staking account and there is no secondary-market ambiguity around accrued but unclaimed revenue.  
* Users should not have to choose between revenue and governance. The staked position is the governance position.

## **2.7 GovToken staking withdrawal delay**

GovTokenStaking should include a withdrawal cooldown to reduce temporary voting-power acquisition and fast-exit governance attacks. The default cooldown should be 14 days and governance should be able to change the cooldown for future withdrawals.

* Default withdrawal cooldown: 14 days.  
* Minimum withdrawal cooldown: 1 day.  
* Maximum withdrawal cooldown: XX days.  
* Governance can change the cooldown duration by normal proposal/timelock process. The new duration should apply to future cooldowns, not retroactively to existing cooldown positions.  
* A separate escrow contract is not required. GovTokenStaking can internally track active stake, cooling-down balances, and withdrawn amounts. A separate WithdrawalEscrow is acceptable if devs prefer separation, but it is not conceptually necessary.  
* When a user starts cooldown, their stGOV for that amount is burned or removed from active staking balance immediately.  
* Cooling-down balances should not earn revenue and should not have governance voting power.  
* Rewards accrued before cooldown starts should remain claimable by the user after checkpointing.  
* Withdrawals should unlock linearly over the cooldown period, similar in spirit to stYFI: users can withdraw a proportional amount as time passes rather than waiting until the end for all-or-nothing liquidity.

`availableToWithdraw = cooldownAmount * elapsed / cooldownDuration - alreadyWithdrawn`

`elapsed = min(block.timestamp, cooldownEnd) - cooldownStart`

This reduces the economic punishment for users who want to exit while still preventing instant stake-vote-unstake behavior. If a user starts multiple cooldowns, the implementation can either store multiple cooldown lots or use a consolidated queue. The preferred behavior is not to reset an existing partially elapsed cooldown when a user starts cooling additional tokens.

## **2.8 Team, DAO Treasury, and Monolith vesting**

* Team allocation: optional, capped at 20%, 4-year vest with 1-year cliff. The team has a real economic claim from launch but no liquid unlock on day 0\.  
* Teams can accumulate liquid GovToken from day 0 by staking Coin into CoinStakingRewards like everyone else. As deployers, they are naturally advantaged in early farming because they are motivated to bootstrap the Coin.  
* DAO Treasury vested allocation: 25%, 4-year linear vest, no cliff. There is no need for the full long-term treasury to be liquid on day 0\.  
* DAO immediate launch budget: 5%, liquid from launch and controlled by the DAO/Treasury for initial liquidity, incentives, market-maker inventory, or urgent bootstrap needs.  
* Monolith allocation: fixed 2%, 2-year linear vest, no cliff, to the Monolith/Inverse ecosystem treasury or designated vesting recipient.

## **2.9 External incentives**

* Do not hardcode LP/bribe integrations in v1.  
* The correct primitive is treasury control plus delegated budgets.  
* Governance can transfer assets to an incentives multisig or budget vault.  
* That delegated address can handle Curve bribes, LP incentives, partner integrations, merkle campaigns, market-maker arrangements, or any other external incentive strategy.  
* Governance can top up, replace, or revoke the delegated budget manager.

# **3\. Governance model**

## **3.1 Voting asset and delegation**

* Governance should use active stGOV voting power.  
* stGOV is non-transferable but delegation-enabled.  
* Delegation should be standard and visible in the UI.  
* Cooling-down GovToken should not count as voting power.  
* Proposal thresholds and vote weights must use historical checkpoints, not current balances.

* Allow “cancel guardian” to submit proposals despite not meeting proposal threshold.

## **3.2 Standard governance cadence**

| Parameter | Default | Notes |
| :---- | :---- | :---- |
| Voting delay | 1 day | Gives time between proposal creation and voting snapshot/start. |
| Voting period | 5 days | Standard period for discussion and voting. |
| Timelock delay | 2 days | Execution delay after a successful vote. |
| Initial quorum | 0.5-1.0% of total supply or stGOV supply | Needs to be practical while circulation/delegation is low. Can be raised later. |
| Proposal threshold | 0.1-0.25% | Low enough for early governance, high enough to reduce spam. |
| Cancel guardian | 12 months | Temporary only. Cancels malicious/broken proposals; cannot execute anything. |

## **3.3 Governance attack resistance**

* A simple same-transaction flash-loan attack should not work if proposal threshold and voting power use checkpointed prior votes with a non-zero voting delay.  
* The larger risk is temporary acquisition of voting power around the snapshot. The stGOV cooldown helps because users cannot instantly unstake and exit after using voting power.  
* Cooling-down balances have no votes and earn no revenue.  
* The 12-month cancel guardian adds early protection during the most fragile distribution period.  
* These controls do not make governance impossible to attack, but they materially reduce cheap stake-vote-exit behavior.

## **3.4 Temporary cancel guardian**

* Default duration: 12 months from CoinDAO deployment.  
* Guardian can cancel malicious, obviously broken, compromised, or governance-attack proposals.  
* Guardian cannot execute proposals, spend funds, change parameters, route revenue, or bypass governance.  
* Guardian expires automatically and must be displayed in the UI.  
* If the team wants a shorter guardian period, this can be configurable at deployment, but the default should be 12 months.

## **3.5 Treasury control**

* Treasury control should be Compound-style arbitrary execution, not a fixed list of approved treasury functions.  
* The CoinDAO needs to fund incentives, seed liquidity, interact with external protocols, pay grants, deploy helper contracts, and manage budgets without new hardcoded modules each time.  
* Timelock is the effective controller of treasury assets.  
* Treasury can be the Timelock itself or a separate CoinTreasury contract controlled by Timelock.  
* If separate, CoinTreasury should expose execute(target, value, data) callable only by Timelock.

# **4\. Revenue collection, routing, and streaming**

## **4.1 Lender reserve behavior**

* In the current Lender, pullLocalReserves() is permissionless.  
* Calling pullLocalReserves() accrues interest/PSM profit and mints accrued local reserves to the Lender operator.  
* Governance does not need to control who triggers reserve collection. Governance needs to control the operator address that receives the reserves and the module that routes them.

## **4.2 RevenueRouter role**

* RevenueRouter should be the Lender operator.  
* Anyone can call Lender.pullLocalReserves(), which mints Coin revenue to RevenueRouter.  
* RevenueRouter routes received Coin according to governance-set recipient weights.  
* Recipients can include DAO Treasury, GovTokenStaking, buyback contracts, incentive budget vaults, external reward contracts, or any other address approved by governance.  
* RevenueRouter must expose the full operator and operator-or-manager surface to governance, including setManager().

`Borrower interest / PSM profit`  
    `-> Lender local reserves`  
    `-> pullLocalReserves() [permissionless]`  
    `-> RevenueRouter as operator`  
    `-> governance-defined routing`

## **4.3 Revenue routing weights**

Active recipient weights do not need to sum to exactly 100%. This makes adding, removing, and updating recipients simpler.

* Each recipient has a weight in bps.  
* sum(activeWeights) must be \<= 10,000 bps.  
* If sum(activeWeights) \< 10,000 bps, the unallocated remainder is sent to the DAO Treasury.  
* If sum(activeWeights) \== 0, all revenue goes to the DAO Treasury.  
* If sum(activeWeights) \> 10,000 bps, the update reverts.  
* This gives governance flexibility while ensuring revenue never gets stuck due to incomplete routing configuration.

`routedAmount = revenue * recipientWeightBps / 10_000`  
`residual = revenue - sum(routedAmounts)`  
`transfer residual to DAO Treasury`

## **4.4 GovTokenStaking revenue streaming**

GovTokenStaking should use a standard Synthetix-style reward streaming model. This matches the desired behavior: when new revenue is notified, the new amount plus any unstreamed remainder from the current stream is streamed over a fresh duration.

* Default rewardDuration: 14 days.  
* Governance can change rewardDuration for future streams by normal proposal/timelock process.  
* When RevenueRouter routes Coin to GovTokenStaking, it calls notifyRewardAmount(amount).  
* If the previous stream has finished, rewardRate \= amount / rewardDuration.  
* If the previous stream is still active, remaining \= (periodFinish \- now) \* rewardRate; new rewardRate \= (amount \+ remaining) / rewardDuration; periodFinish \= now \+ rewardDuration.  
* If revenue is collected again shortly after, the same calculation runs again. The unstreamed remainder is rolled into the next stream.  
* If revenue is collected at least once every y duration where y \< rewardDuration, stGOV holders will experience continuous revenue streaming.

`if block.timestamp >= periodFinish:`  
    `rewardRate = newReward / rewardDuration`  
`else:`  
    `remaining = (periodFinish - block.timestamp) * rewardRate`  
    `rewardRate = (newReward + remaining) / rewardDuration`  
`periodFinish = block.timestamp + rewardDuration`

## **4.5 What happens when a staker claims revenue?**

* GovTokenStaking maintains rewardPerToken accounting.  
* Each account tracks userRewardPerTokenPaid and rewards\[account\].  
* When a user claims, the contract updates global rewardPerToken, updates the user's accrued reward, transfers accrued Coin to that user, and resets their accrued balance to zero.  
* If another user claims immediately after, they receive only their own accrued amount based on their active stGOV and time-weighted share.  
* One user claiming does not reduce another user's accounting entitlement.  
* New revenue distributions affect future streaming from the notification timestamp onward. They do not retroactively change rewards already accrued by stakers.

# **5\. Technical architecture**

## **5.1 Contract set**

| Contract | Purpose |
| :---- | :---- |
| CoinDAOFactory | Deploys the optional CoinDAO stack for a Monolith coin. |
| GovToken | Fixed-supply governance token. No post-deployment minting in v1. |
| Governor | Proposal, voting, quorum, and execution interface. Uses stGOV checkpoints. |
| Timelock | Executes successful governance actions after delay. Controls treasury and RevenueRouter. |
| CoinTreasury | DAO treasury. Either holds assets directly or is controlled by Timelock. Supports arbitrary execution. |
| RevenueRouter | Lender operator. Receives local reserves, routes revenue, and exposes operator/operator-or-manager wrappers. |
| CoinStakingRewards | Naked Coin staking contract. Distributes GovToken emissions from launch. |
| EmissionScheduler / rewards reserve | Implements selected preset 4-year linear or modest bootstrap emission curve. Tracks active-emission time so no-staker periods do not waste emissions or reward the first staker retroactively. |
| GovTokenStaking / stGOV | GovToken staking, revenue streaming, voting power, delegation, and withdrawal cooldown. |
| TeamVesting | Optional team allocation. 4-year vest, 1-year cliff. |
| TreasuryVesting | DAO vested treasury allocation. 4-year linear vest, no cliff. |
| MonolithVesting | Fixed 2% Monolith allocation. 2-year linear vest, no cliff. |

## **5.2 Recommended role wiring**

| Role / control surface | Default holder | Notes |
| :---- | :---- | :---- |
| Lender operator | RevenueRouter | Receives local reserves and exposes operator wrappers. |
| Lender manager | Timelock | Governance can later delegate manager to a multisig and replace it again. |
| RevenueRouter owner/controller | Timelock | Only governance can change routing or call operator wrappers. |
| CoinTreasury controller | Timelock | Compound-style arbitrary execution. |
| GovTokenStaking admin | Timelock | Can change rewardDuration and withdrawal cooldown for future periods. |
| CoinStakingRewards admin | Timelock / EmissionScheduler | Controls emission schedule according to selected factory template. |
| Cancel guardian | Temporary guardian address | Cancel-only power, expires after 12 months. |

## **5.3 RevenueRouter function surface**

RevenueRouter should not be a narrow revenue-only contract. Because it is the Lender operator, it must expose every operator and operator-or-manager action that governance may need.

`// Revenue routing`  
`function distribute() external;`  
`function setRevenueRecipientWeight(address recipient, uint16 weightBps) external onlyTimelock;`  
`function removeRevenueRecipient(address recipient) external onlyTimelock;`  
`function setDefaultTreasury(address treasury) external onlyTimelock;`

`// Operator wrappers`  
`function setLocalReserveFeeBps(uint feeBps) external onlyTimelock;`  
`function setPendingOperator(address pendingOperator) external onlyTimelock;`  
`function enableImmutabilityNow() external onlyTimelock;`

`// Operator-or-manager wrappers`  
`function setManager(address manager) external onlyTimelock;`  
`function setHalfLife(uint64 halfLife) external onlyTimelock;`  
`function setTargetFreeDebtRatio(uint16 startBps, uint16 endBps) external onlyTimelock;`  
`function setRedeemFeeBps(uint16 redeemFeeBps) external onlyTimelock;`  
`function setMaxBorrowDeltaBps(uint16 maxBorrowDeltaBps) external onlyTimelock;`

# **6\. Deployment flow**

1. Deployer creates a Monolith stablecoin as normal.  
2. If opted in, CoinDAOFactory deploys GovToken, Governor, Timelock, RevenueRouter, CoinTreasury, CoinStakingRewards, EmissionScheduler/rewards reserve, GovTokenStaking/stGOV, TeamVesting if applicable, TreasuryVesting, and MonolithVesting.  
3. GovToken supply is minted at genesis into the configured allocation contracts.  
4. CoinStakingRewards is funded at launch and emissions follow the selected preset curve. Rewards accrue only while Coin is staked; no-staker periods pause the active-emission clock.  
5. GovTokenStaking is deployed and ready to receive staked GovToken. Revenue begins once local reserves are collected and routed.  
6. Lender.operator is set to RevenueRouter.  
7. Lender.manager defaults to Timelock, unless governance later delegates manager to a multisig.  
8. UI surfaces all roles, allocations, vesting, emission rates, revenue routing, staking cooldowns, governance settings, and guardian expiry.

# **7\. UI and disclosure requirements**

* GovToken address, total supply, allocation table, and all vesting schedules.  
* CoinStakingRewards emission curve, active-emission time, current scheduled emission rate, remaining emissions reserve, and staking contract address.  
* Behavior when no Coin is staked: no rewards accrue, the active-emission clock pauses, and unallocated emissions remain in the reserve.  
* GovTokenStaking/stGOV address, rewardDuration, active rewardRate, unstreamed rewards, delegation status, withdrawal cooldown, and withdrawable amount.  
* Team allocation, 4-year vest, 1-year cliff, and vesting recipient.  
* DAO Treasury vested allocation and immediate launch budget.  
* Fixed 2% Monolith allocation and 2-year vesting schedule.  
* Governor, Timelock, voting delay, voting period, proposal threshold, quorum, timelock delay, and cancel guardian expiry.  
* Lender operator and whether it is the standard RevenueRouter.  
* Lender manager and whether it is Timelock or a delegated multisig.  
* Current local reserve fee and revenue routing recipients/weights, including any residual routed to treasury.  
* Queued proposals affecting treasury, revenue routing, operator, manager, parameters, immutability, rewardDuration, staking cooldown, or guardian settings.  
* Immutability deadline and whether immutability has been enabled.

# **8\. Recommended v1 scope**

* Build the full CoinDAO stack, not just a token deployer.  
* CoinStakingRewards and GovTokenStaking are both core/default modules.  
* Use fixed GovToken supply with no post-deployment minting.  
* Use the allocation templates in this document; no default airdrop/points bucket.  
* Use either linear 4-year emissions or the predefined modest bootstrap curve, implemented as a preset schedule rather than arbitrary reward notifications.  
* Do not lose emissions when no Coin is staked; pause the active-emission clock and keep unused emissions in the reserve.  
* Treasury allocation vests over 4 years; Monolith allocation vests over 2 years; team allocation vests over 4 years with 1-year cliff.  
* Use RevenueRouter as Lender operator, with governance-controlled revenue routing and full operator/operator-or-manager wrappers.  
* Allow revenue routing weights to sum below 100%, with residual revenue routed to DAO Treasury.  
* Use Synthetix-style 14-day reward streaming for GovTokenStaking revenue share, with rewardDuration changeable by governance for future streams.  
* Use non-transferable stGOV with vote delegation.  
* Use a 14-day stGOV withdrawal cooldown with linear/proportional withdrawals as time passes. Cooldown duration should be governance-changeable for future cooldowns.  
* Cooling-down balances should not earn revenue and should not have voting power.  
* Use 1-day voting delay, 5-day voting period, 2-day timelock, practical early quorum, checkpointed voting power, and 12-month cancel guardian.  
* Do not hardcode LP/bribe integrations. Use treasury and delegated budgets instead.  
* Official UI support requires verifiable factory deployment, standard role wiring, allocation disclosures, vesting disclosures, staking/revenue disclosures, and governance-risk disclosures.

# **9\. Implementation notes to resolve during development**

* Choose whether cooldown accounting is implemented directly in GovTokenStaking or in a small WithdrawalEscrow. Direct implementation is sufficient; a separate escrow is only an engineering separation choice.  
* Choose whether multiple cooldown positions are stored as lots or consolidated. Preferred UX: existing partially elapsed cooldowns should not be reset when a user cools additional tokens.  
* Define exact governance bounds, if any, for rewardDuration and withdrawal cooldown changes.  
* Choose whether the Treasury is the Timelock itself or a separate CoinTreasury controlled by Timelock.  
* Confirm the fixed Monolith vesting recipient address.  
* Confirm the default initial quorum formula: low fixed threshold, percentage of stGOV supply at snapshot, or hybrid with a minimum floor.
