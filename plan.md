# OSS-First Monolith CoinDAO Plan

## 1. Executive summary

The CoinDAO Factory is an optional layer for Monolith deployers. It lets a deployer launch a per-stablecoin governance and incentive system around a Monolith coin without changing the core Monolith lending design.

The design rule for v1 is strict:

- Use battle-tested open-source contracts unmodified wherever possible.
- Prefer OpenZeppelin Contracts 5.x for tokens, governance, timelock, and vesting.
- Prefer the Synthetix staking rewards pattern for reward streaming.
- Requirements that cannot be implemented through established contracts or small integration glue are excluded from v1.
- Small project contracts are acceptable only for inheritance glue, Monolith integration, or behavior that is core to the product.

The accepted bespoke core contracts are:

| Contract | Why it exists |
| :-- | :-- |
| `stGovToken` | Combines wrapped GovToken staking, non-transferable voting power, delegation, and reward streaming in one receipt token. It should be composed from OpenZeppelin token/votes/wrapper modules plus Synthetix-style reward accounting. |
| `RevenueRouter` | Monolith-specific Lender operator that splits collected Coin revenue only between the Timelock treasury and `stGovToken`. |
| Governor guardian expiry wrapper | Tiny extension around OpenZeppelin `GovernorProposalGuardian` so guardian cancel permission automatically expires after a deadline. |

Everything else should be a direct use of established contracts or a minimal concrete wrapper around an abstract OpenZeppelin module.

## 2. Product model

### 2.1 Launch model

- Each opted-in Monolith stablecoin receives its own CoinDAO stack.
- Deployers can still launch a plain Monolith coin without a CoinDAO.
- Factory-launched CoinDAOs receive first-class UI support and standardized disclosures.
- GovToken supply is fixed at deployment; no post-deployment minting in v1.
- Treasury assets are held directly by the Timelock, not by a separate treasury contract.

### 2.2 Allocation templates

There is no airdrop or points bucket in the baseline product. The primary community distribution mechanism is Coin staking: users stake the naked Monolith Coin and earn GovToken rewards from a prefunded rewards contract.

| Bucket | Fair launch | Standard launch | Team-led launch | Notes |
| :-- | --: | --: | --: | :-- |
| Coin staking rewards reserve | 68% | 53% | 48% | Funds naked Coin staking rewards. |
| Timelock treasury vested | 25% | 25% | 25% | 4-year linear vest to the Timelock. |
| Timelock immediate launch budget | 5% | 5% | 5% | Liquid on day 0 and held by the Timelock. |
| Team/deployer vesting | 0% | 15% | 20% max | 4-year vest with 1-year cliff. |
| Monolith allocation | 2% | 2% | 2% | 2-year linear vest. |

The Timelock treasury total is therefore 30%, split between a 25% vested allocation and a 5% immediate launch budget.

### 2.3 GovToken and stGovToken

`GovToken` is the transferable economic token. It has no voting rights and no direct revenue share.

`stGovToken` is the staked/wrapped governance token:

- Users deposit `GovToken` and receive `stGovToken` 1:1.
- Users burn `stGovToken` and withdraw the underlying `GovToken` 1:1.
- `stGovToken` is non-transferable except minting on stake and burning on unstake.
- `stGovToken` implements OpenZeppelin-style vote checkpoints and vote delegation.
- The Governor reads voting power from `stGovToken`, not from `GovToken`.
- `stGovToken` receives streamed reward tokens, including Monolith Coin revenue from `RevenueRouter`.
- Unstaked `GovToken` has no voting power and earns no revenue.

This makes the user's staked position the same position used for governance and revenue share.

### 2.4 Coin staking rewards

Coin staking uses an existing Synthetix-style staking rewards contract.

- Users stake the naked Monolith Coin, not the sToken.
- Stakers earn GovToken rewards from the launch-funded rewards reserve.
- The rewards contract is prefunded at launch.
- Reward duration and funding are handled through the imported rewards contract's standard behavior.

The v1 Coin staking contract does not include:

- custom active-emission clocks,
- no-staker pause semantics,
- bespoke bootstrap curves.

Reward timing follows the selected staking rewards implementation. The CoinDAO contracts do not add a separate emission scheduler.

## 3. Open-source contract mapping

| Need | Preferred implementation | Notes |
| :-- | :-- | :-- |
| Fixed-supply token | OpenZeppelin `ERC20` / `ERC20Permit` concrete token | Mint full supply once in constructor or deployment flow, then no minter role. |
| Staked voting/revenue token | Project `stGovToken` composed from OpenZeppelin `ERC20Wrapper`, `ERC20Votes`, optional `ERC20Permit`, and Synthetix-style rewards | Core bespoke primitive. Do not fork OpenZeppelin. |
| Governor | OpenZeppelin Governor modules | Use `GovernorSettings`, `GovernorCountingSimple`, `GovernorVotes`, `GovernorVotesQuorumFraction`, `GovernorTimelockControl`, and `GovernorProposalGuardian`. |
| Timelock and treasury | OpenZeppelin `TimelockController` | The Timelock directly holds funds and executes arbitrary calls. |
| Cancel guardian expiry | Tiny Governor wrapper | Guardian cancel power is valid only while `block.timestamp < guardianExpiresAt`. |
| Coin staking rewards | Synthetix-style `StakingRewards` | Use without custom emission scheduling. |
| Team vesting | OpenZeppelin `VestingWalletCliff` via concrete wrapper | 4-year duration, 1-year cliff. |
| DAO and Monolith vesting | OpenZeppelin `VestingWallet` | Linear vesting. |
| Revenue routing | Project `RevenueRouter` | Minimal Monolith-specific splitter. |

## 4. Governance model

### 4.1 Voting asset

Governance uses active `stGovToken` voting power.

- `GovToken` balances do not vote.
- `stGovToken` balances vote only after delegation, following OpenZeppelin `ERC20Votes` behavior.
- Proposal thresholds, quorum, and vote weights use historical checkpoints.
- Burning `stGovToken` to unstake removes future voting power according to the checkpointing rules.

### 4.2 Governor stack

Use OpenZeppelin Governor modules:

- `Governor`
- `GovernorSettings`
- `GovernorCountingSimple`
- `GovernorVotes`
- `GovernorVotesQuorumFraction`
- `GovernorTimelockControl`
- `GovernorProposalGuardian`
- a tiny project wrapper for guardian expiry

Default governance parameters:

| Parameter | Default |
| :-- | :-- |
| Voting delay | 1 day |
| Voting period | 5 days |
| Timelock delay | 2 days |
| Initial quorum | 1% of `stGovToken` supply at snapshot |
| Proposal threshold | Fixed at deployment |
| Cancel guardian duration | 12 months from deployment |

### 4.3 Cancel guardian expiry

The cancel guardian is temporary. OpenZeppelin `GovernorProposalGuardian` provides the guardian mechanism, and the project Governor adds only expiry gating.

Required behavior:

- The configured guardian can cancel proposals before `guardianExpiresAt`.
- At or after `guardianExpiresAt`, the guardian has no special cancellation permission.
- No storage cleanup is required after expiry.
- Governance can still set or clear the guardian through the standard OpenZeppelin governance-controlled setter, but the expiry check remains in force.
- The UI must display `guardianExpiresAt` and whether guardian power is currently active.

This requires a small override of the guardian cancellation validation path. It does not require modifying OpenZeppelin source.

## 5. Timelock treasury

There is no `CoinTreasury` contract in v1.

The OpenZeppelin `TimelockController` is the treasury:

- It holds the immediate treasury allocation.
- It receives vested DAO treasury tokens.
- It receives the treasury share of routed Monolith Coin revenue.
- It owns or controls governance-managed contracts.
- It executes arbitrary approved governance actions.

This keeps treasury control close to the battle-tested OpenZeppelin governance model. Any incentives, grants, liquidity seeding, market-maker budgets, or partner programs are funded by Timelock proposal.

## 6. RevenueRouter

`RevenueRouter` is the Lender operator and a minimal two-destination splitter.

### 6.1 Purpose

- The Monolith Lender mints local reserves to its operator.
- `RevenueRouter` is the operator address.
- Anyone may trigger reserve collection if the Lender allows permissionless reserve pulls.
- When `distribute()` is called, the router splits its Coin balance between the Timelock treasury and `stGovToken`.

### 6.2 State

The router stores only what it needs:

- `coin`: Monolith Coin token.
- `treasury`: Timelock address.
- `stGovToken`: reward recipient.
- `revShareBps`: share of Coin revenue sent to `stGovToken`.

Default `revShareBps` is `5_000`, meaning 50% to `stGovToken` and 50% to Timelock.

### 6.3 Functions

`distribute()`:

- Reads the router's full Coin balance.
- Computes `stGovAmount = balance * revShareBps / 10_000`.
- Computes `treasuryAmount = balance - stGovAmount`.
- Transfers `treasuryAmount` to Timelock.
- Transfers or approves `stGovAmount` to `stGovToken`.
- Calls the `stGovToken` reward notification function atomically.

`setRevShareBps(uint16 newRevShareBps)`:

- Callable only by Timelock governance.
- Reverts if `newRevShareBps > 10_000`.
- Updates the `stGovToken` revenue share.

The router must not support:

- arbitrary recipient lists,
- arbitrary routing weights,
- external incentive routing,
- treasury execution,
- custody of unrelated assets,
- non-Coin revenue in v1.

## 7. stGovToken design

`stGovToken` is the main composed contract in the system.

### 7.1 Inheritance and composition

Use OpenZeppelin modules directly, without forking:

- ERC20-compatible token surface.
- `ERC20Wrapper`-style 1:1 backing by `GovToken`.
- `ERC20Votes` for delegation and historical checkpoints.
- Optional `ERC20Permit` if useful for delegation or approvals.

Add project logic only where needed:

- non-transferability,
- stake/unstake entry points if the OpenZeppelin wrapper names are not the desired public API,
- Synthetix-style multi-reward accounting,
- reward notification access control.

### 7.2 Reward streaming

`stGovToken` should use Synthetix-style reward accounting:

- Each reward token has `rewardRate`, `periodFinish`, `lastUpdateTime`, and `rewardPerTokenStored`.
- Each user has `userRewardPerTokenPaid` and accrued rewards per reward token.
- New rewards are streamed over `rewardDuration`.
- If a previous stream is active, the unstreamed remainder rolls into the next stream.

The Timelock can configure reward tokens and durations. `RevenueRouter` can notify Coin rewards.

If GovToken is ever configured as a reward token, the implementation must preserve the invariant that the underlying GovToken backing all outstanding `stGovToken` is never paid out as rewards.

### 7.3 Transfers and exits

- Direct `transfer` and `transferFrom` of `stGovToken` revert.
- Mint on stake and burn on unstake remain valid.
- Unstaking is immediate in v1.
- There is no withdrawal cooldown.

## 8. Deployment flow

1. Deployer creates a Monolith stablecoin as normal.
2. If opted in, the CoinDAO deployment creates or wires:
   - `GovToken`,
   - `stGovToken`,
   - Governor,
   - Timelock,
   - `RevenueRouter`,
   - Coin staking rewards contract if enabled,
   - OpenZeppelin vesting wallets.
3. GovToken supply is minted once and allocated to rewards, vesting wallets, Timelock, and any immediate recipients.
4. Timelock is configured as treasury and governance executor.
5. Governor is configured to use `stGovToken` votes and Timelock execution.
6. `RevenueRouter` is configured as the Lender operator.
7. Lender manager defaults to Timelock unless the deployment intentionally delegates manager control to another address.
8. Timelock-controlled roles are transferred to the Timelock, and any temporary deployment admin roles are renounced.

## 9. UI and disclosure requirements

The UI must show:

- GovToken address, total supply, and allocation table.
- stGovToken address, total staked GovToken, delegation state, voting power, reward tokens, reward rates, and claimable rewards.
- Coin staking rewards contract, reward duration, funded rewards, and remaining rewards.
- Timelock address, treasury balances, queued operations, and executed operations.
- Governor address, voting delay, voting period, proposal threshold, quorum, and proposal states.
- Cancel guardian address, `guardianExpiresAt`, and whether guardian power is active.
- RevenueRouter address, Coin balance, current `revShareBps`, Timelock share, and stGovToken share.
- Lender operator and manager addresses.
- Vesting wallet addresses, recipients, start times, durations, cliffs, released amounts, and releasable amounts.

## 10. Recommended v1 scope

Build the CoinDAO stack around battle-tested primitives:

- fixed-supply GovToken,
- stGovToken voting/revenue wrapper,
- OpenZeppelin Governor and Timelock,
- Timelock-as-treasury,
- RevenueRouter,
- optional Synthetix-style Coin staking rewards,
- OpenZeppelin vesting wallets,
- temporary cancel guardian with automatic permission expiry.

Excluded from v1:

- CoinTreasury,
- broad revenue routing,
- arbitrary recipient weights,
- active-emission scheduler,
- no-staker emission pause,
- custom emission curves,
- withdrawal cooldowns,
- hardcoded LP/bribe integrations,
- custom treasury execution surfaces.

Governance can still fund incentives, grants, partner integrations, and external reward programs through normal Timelock proposals.

## 11. Test plan

### 11.1 Governance and Timelock

- Governor reads voting power from `stGovToken`, not `GovToken`.
- Unstaked GovToken has zero votes.
- Delegation and historical checkpoints work through OpenZeppelin `ERC20Votes`.
- Successful proposals queue and execute through Timelock.
- Timelock can hold and transfer treasury assets.
- Temporary deployment admin roles are renounced.

### 11.2 Guardian

- Guardian can cancel proposals before `guardianExpiresAt`.
- Guardian cannot cancel proposals at or after `guardianExpiresAt`.
- Governance-controlled guardian updates still respect the expiry check.
- UI-readable expiry data is exposed.

### 11.3 stGovToken

- Staking GovToken mints equal stGovToken.
- Unstaking burns stGovToken and returns equal GovToken.
- Direct stGovToken transfers revert.
- Vote checkpoints update on stake, unstake, and delegation.
- Rewards accrue only to current stGovToken holders according to reward-per-token accounting.
- Claims do not affect other users' accrued rewards.
- Reward notifications roll unstreamed rewards into the next stream.
- Underlying GovToken backing cannot be paid out as rewards.

### 11.4 RevenueRouter

- Only Timelock can call `setRevShareBps`.
- Values above `10_000` revert.
- `distribute()` handles 0%, 50%, and 100% stGovToken share.
- Treasury share is sent to Timelock.
- stGovToken share is notified as streamed rewards.
- Router cannot route to arbitrary recipients.

### 11.5 Vesting and allocations

- Allocation templates sum to 100%.
- Team allocation cannot exceed 20%.
- Team vesting has 4-year duration and 1-year cliff.
- Timelock treasury vesting has 4-year linear vesting.
- Monolith vesting has 2-year linear vesting.
- Immediate Timelock budget is liquid on day 0.

## 12. References

- OpenZeppelin governance: https://docs.openzeppelin.com/contracts/5.x/governance
- OpenZeppelin governance API: https://docs.openzeppelin.com/contracts/5.x/api/governance
- OpenZeppelin ERC20Votes and ERC20Wrapper: https://docs.openzeppelin.com/contracts/5.x/api/token/erc20
- OpenZeppelin vesting: https://docs.openzeppelin.com/contracts/5.x/api/finance
- Synthetix StakingRewards pattern: https://github.com/Synthetixio/synthetix/blob/develop/contracts/StakingRewards.sol
