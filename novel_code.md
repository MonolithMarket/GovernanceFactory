# Novel vs. Battle-Tested Code

This document classifies the Solidity code the Monolith CoinDAO factory deploys or links
against by how much of it is original project logic versus reused library code. Test code and
`lib/forge-std` are out of scope because they are not deployed on-chain.

## Legend

| Tag | Meaning |
| :-- | :-- |
| Imported library | Unmodified third-party code imported from `lib/`. Lowest risk. |
| Adapted | Logic taken from a battle-tested source but reimplemented or modernized here. Medium risk: the pattern is proven, this transcription still needs review. |
| Standard composition | New bytecode, but primarily library inheritance, parameter choices, and compiler-required override glue. Low-medium risk. |
| Novel | Original project logic with no upstream equivalent. Highest risk. |

## Summary Table

| File | Tag | Provenance | Primary review focus |
| :-- | :-- | :-- | :-- |
| `lib/openzeppelin-contracts` | Imported library | OpenZeppelin Contracts v5.6.1 | Version pin and integration assumptions |
| `src/StakedGovToken.sol` | Adapted + standard composition | OZ ERC20Wrapper/ERC20Votes plus Synthetix reward accounting | Reward queueing, final-withdraw behavior, non-transferability |
| `src/StakingRewards.sol` | Adapted | Synthetix `StakingRewards` | Solidity 0.8 port and intentionally removed hooks |
| `src/GovToken.sol` | Standard composition | OZ ERC20 + ERC20Permit | Fixed supply and initial holder |
| `src/CoinDAOGovernor.sol` | Standard composition | OZ Governor extensions | Absolute quorum/threshold parameters |
| `src/RevenueRouter.sol` | Novel | Written for Monolith | Revenue split and Lender operator authority |
| `src/StakingRewardsFunder.sol` | Novel | Written for Monolith | Tranche schedule and final balance sweep |
| `src/CoinDAOFactory.sol` | Novel | Written for Monolith | Allocation math, deployment ordering, privilege handoff |
| `src/interfaces/IMonolith.sol` | Novel interface only | Written for Monolith | ABI match against the external Monolith contracts |
| `src/interfaces/INotifiableRewardReceiver.sol` | Interface only | Generic local interface | No runtime logic |

## Imported Libraries

### `lib/openzeppelin-contracts` v5.6.1

The repository imports OpenZeppelin contracts unmodified for ERC20, ERC20Permit, ERC20Wrapper,
ERC20Votes, Governor extensions, TimelockController, Ownable, SafeERC20, ReentrancyGuard,
VestingWallet, Nonces, RLP, and EIP712 utilities. The main review question is not the library code
itself, but whether each composition uses the right parameters and ownership handoffs.

## Adapted Code

### `src/StakedGovToken.sol`

The staked GOV token uses the OpenZeppelin wrapper approach: GOV holders deposit raw GOV into an
ERC20Wrapper and receive non-transferable `sGOV`. The governor reads votes from `sGOV`, so only
staked GOV can vote. Holders still need to delegate `sGOV` to activate vote checkpoints, matching
the default OZ `ERC20Votes` model.

The reward accounting follows the Synthetix reward-per-token pattern. Project-specific additions
are:

- An immutable `rewardsDistribution` address, set to the `RevenueRouter` at deployment.
- Coin rewards queue if no one has staked.
- If the final staker exits during an active stream, undistributed rewards are moved back into
  `queuedRewards` instead of being lost.
- `sGOV` is non-transferable except mint on deposit and burn on withdrawal.
- `withdraw()` wraps `withdrawTo()` so callers can withdraw their full balance to themselves.

These additions are the main audit focus for this file.

### `src/StakingRewards.sol`

Coin or sCoin stakers earn GOV emissions through a modernized Synthetix-style staking rewards
contract. SafeMath is replaced by Solidity 0.8 checked arithmetic. Pause, token recovery, and
mutable duration hooks are removed because the factory uses a fixed launch flow.

## Standard Composition

### `src/GovToken.sol`

The raw GOV token is a fixed-supply `ERC20 + ERC20Permit`. It deliberately does not implement
votes; governance power is created only when GOV is staked into `StakedGovToken`.

### `src/CoinDAOGovernor.sol`

The governor composes OZ Governor, GovernorSettings, GovernorCountingSimple, GovernorVotes, and
GovernorTimelockControl. The project-specific behavior is parameterization:

- Voting delay: 7,200 blocks.
- Voting period: 36,000 blocks.
- Proposal threshold: 0.1% of fixed GOV supply, supplied by the factory.
- Initial quorum: 1% of fixed GOV supply, supplied by the factory.

The quorum is an absolute `sGOV` vote amount because `sGOV.totalSupply()` may be much lower than
total GOV supply, and a fraction of staked supply would make quorum easier as participation falls.
Governance may update the absolute threshold between one wei and the full fixed GOV supply.
Updates are not checkpointed: the latest quorum applies immediately to every proposal and every
historical `quorum(timepoint)` query.

## Novel Code

### `src/CoinDAOFactory.sol`

The factory is the largest original surface area. `allocationFor()` implements fixed-supply GOV
distribution math. `deploy()` wires the Monolith market, GOV token, `sGOV`, governor, timelock,
staking rewards, revenue router, and vesting wallets, then hands authority to the timelock.
Because `StakedGovToken` stores the revenue router as an immutable rewards distributor while the
router also needs the staker address, the factory predicts its future `RevenueRouter` CREATE
address with OpenZeppelin `RLP` and tracks its own create nonce.

The main risks are misallocation, incorrect deployment ordering and address prediction, and
incomplete privilege handoff.

### `src/RevenueRouter.sol`

The router receives Coin reserves from the Lender, splits them between `sGOV` rewards and the
treasury, and notifies the reward receiver after transferring rewards. It also exposes timelock
managed Lender manager replacement. The fund-routing and cross-contract authority should be
audited closely.

### `src/StakingRewardsFunder.sol`

The funder releases GOV emissions into `StakingRewards` over four yearly tranches. The first
three tranches are fixed percentages of total rewards, and the final tranche sweeps the remaining
balance. The final balance sweep is correct for the factory path because the funder receives the
full allocation up front and has no alternate token outflow.

### `src/interfaces/IMonolith.sol`

These interfaces contain no runtime logic, but their selectors and parameter layouts must match
the external Monolith contracts exactly.

## Suggested Audit Priority

1. `CoinDAOFactory.sol`: allocation math and privilege wiring.
2. `StakedGovToken.sol`: reward queueing, non-transferability, and voting integration.
3. `RevenueRouter.sol`: revenue split and Lender manager authority.
4. `StakingRewardsFunder.sol`: tranche gating and final sweep.
5. `StakingRewards.sol`: Synthetix port and removed hooks.
6. `CoinDAOGovernor.sol` and `GovToken.sol`: parameter choices and governance assumptions.
7. `IMonolith.sol`: ABI match against the external Monolith deployment.
