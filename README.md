# Monolith CoinDAO

Foundry implementation of the optional CoinDAO stack described in `plan.md`.

## Contracts

- `GovToken`: fixed-supply ERC20/Permit token minted once at deployment.
- `StGovToken`: 1:1 wrapped GovToken staking receipt with non-transferable ERC20Votes voting power and Synthetix-style multi-reward streaming.
- `CoinDAOGovernor`: OpenZeppelin Governor stack with Timelock execution and an expiring proposal guardian.
- `RevenueRouter`: Monolith Lender operator and Coin revenue splitter for Timelock treasury and `StGovToken` rewards.
- `StakingRewards`: Synthetix-style naked Coin staking rewards funded with GovToken.
- `CoinDAOFactory`: deployment helper that calls the Monolith factory, deploys the Monolith coin/lender/vault, and wires the standard CoinDAO stack.
- `CliffVestingWallet`: concrete OpenZeppelin `VestingWalletCliff` wrapper for team/deployer vesting.

## Verification

```sh
forge build
forge test
```
