# Personal staking helpers for CoinDAOs

This ports the personal-helper design from
[Monolith PR #60](https://github.com/MonolithMarket/Monolith/pull/60) into the
governance repository. The original PR preserves the earlier design discussion.

Users can deposit a Monolith Token into its Vault and stake the resulting
sToken in its DAO's existing GOV rewards pool in one transaction, after
approving Token. The sToken continues to earn vault yield while staked; GOV
accrues according to the pool's funded reward schedule.

One helper factory serves the eligible DAOs registered by one fixed
CoinDAOFactory on that chain. It deploys one shared implementation and creates
one EIP-1167 helper clone per owner and DAO on first use. No helper-factory
redeployment or manual coin registration is needed for new eligible DAOs.

## Deployment and registry

Deploy `PersonalStakingHelperFactory(coinDAOFactory)` once, using a verified
CoinDAOFactory v2 deployment. The constructor deploys the shared helper
implementation automatically. It checks that the registry address contains
code; the deployer must verify that it is the intended authentic factory.

The factory reads the registry's `deployments(daoId)` record to select the
vault and rewards pool. Only entries whose `stakingToken` equals the nonzero
`vault` are accepted. DAOs that stake Token directly are rejected. Unknown
IDs revert through the registry lookup. Each helper reads Token from its
vault and GOV from its pool during initialization.

Use the ID emitted by **CoinDAOFactory's** `CoinDAODeployed` event, or the
index in its `deployments` array. This is not the Monolith market factory's
separate deployment index.

The adapter matches the fourteen-address public getter in
[CoinDAOFactory v2](https://github.com/MonolithMarket/GovernanceFactory/blob/be1b426577d17edba960ce28363d39dde3acbcb4/src/CoinDAOFactory.sol#L107),
commit `be1b426577d17edba960ce28363d39dde3acbcb4`. It requires no changes to that
factory. A different governance factory or incompatible registry layout
requires a separate helper-factory deployment.

## Ownership and market binding

Existing StakingRewards pools credit `stake(amount)` to `msg.sender`. Each
personal helper therefore holds its owner's separate pool position. A user
who enters two DAOs has two helpers, both created by the same shared factory.

Each clone's owner, vault, pool, Token and GOV are configured once during
atomic creation and initialization. Only the factory can initialize a clone,
and reinitialization is blocked. The shared implementation is locked against
initialization. Later deposits reuse the helper's stored market configuration.

The registry and implementation addresses in the helper factory are immutable.
There is no administrator, registry setter, upgrade path, ownership transfer
or arbitrary-call function. All withdrawals, rewards and recovered tokens go
to the helper's fixed owner, which may be an EOA or a smart account.

## User flow

1. Approve the DAO's Token to the shared helper factory. Each Token has its own
   allowance. Approval is a separate transaction unless the user's account
   can batch calls; this version does not add permit support.
2. Call `factory.depositAndStake(daoId, assets, minShares)`. The factory creates
   the user's helper if necessary and pulls Token directly from the caller to
   that helper. The helper deposits exactly that amount and stakes the shares
   returned by the Vault.
3. Read `factory.helperOf(daoId, owner)` to find the user's helper. Use its
   `stakedShares()` and `earned()` to display the position and claimable GOV.

Owner actions on the helper require no DAO argument because its market is
already fixed:

| Function | Result |
| --- | --- |
| `claim()` | Claims GOV and transfers its entire loose GOV balance to the owner. |
| `withdraw(shares, claimRewards)` | Unstakes sToken to the owner, retaining vault exposure; optionally claims GOV. |
| `withdrawAndRedeem(shares, minAssets, claimRewards)` | Unstakes and redeems to Token for the owner; optionally claims GOV. |
| `recoverToken(token)` | Returns loose tokens to the owner without touching the staked position. |

With `claimRewards=true`, either withdrawal route also claims all accrued GOV
and forwards its entire loose GOV balance to the owner in the same transaction.
If the pool claim or GOV forwarding fails, the whole transaction reverts,
including the withdrawal or redemption. Users can retry with `claimRewards=false`:
that path never calls `getReward()`, so a failing GOV claim cannot block the exit.
Unclaimed GOV remains available through `claim()`, including after a full exit.
Standalone and combined claims use the same internal logic under the helper's
reentrancy guard. The helper does not bypass failures in the vault, staking pool
or Token.

Vault yield is already reflected in sToken's redemption value and requires no
separate harvest. Withdrawing sToken retains that vault exposure; redeeming
returns its underlying Token value.

## Minimum outputs and supported contracts

Use the Vault's `previewDeposit` and `previewRedeem` to quote minimum outputs.
Monolith burns `1e16` shares on a vault's first deposit; the helper checks the
actual shares returned by the Vault. A failed minimum, transfer or stake
reverts the whole entry, including helper creation on the first deposit.

Transactions have no expiry. A pending deposit can execute later, including
after a GOV reward period ends. Minimum outputs protect vault conversion
amounts; they do not guarantee a GOV reward rate or execution time.

The helper relies on the registered Monolith Token, Vault and StakingRewards
contracts' transfer and accounting behaviour. Token and GOV must transfer
exact amounts and maintain stable balances; fee-on-transfer and rebasing
tokens are unsupported. The helper does not add balance assertions for
arbitrary implementations.

Token and sToken approvals from the helper are exact and cleared after use.
Factory and helper entry points use reentrancy guards. Pre-existing Token or
sToken donations remain loose and can be recovered only by the helper's owner.
There is no shared user balance ledger or caller-selected payer/beneficiary.

Existing stakes held directly by a user's wallet remain separate. Moving
such a position requires withdrawing it first; this version provides the
Token-to-vault-to-pool entry route. The helper does not fund rewards, change
their rate or compound GOV.

## Tests and dependencies

Initialize the repository submodules, then build the pinned Monolith contracts
before running the helper tests:

```sh
forge build --root integration/monolith --use 0.8.24
FOUNDRY_PROFILE=personal-staking forge test --use 0.8.26 -vv
(cd integration/monolith && forge test --use 0.8.24 -vv)
```

On PowerShell, set `$env:FOUNDRY_PROFILE = 'personal-staking'` for the focused
helper suite and reset it to `default` before the integration command. The
profile runs 512 cases per fuzz test and 128 invariant runs of 64 calls across
three owners and two DAOs. Both flag values, partial/full exits, empty rewards,
claim/forwarding failures, atomic rollback, retries without claiming, minimum
outputs, initialization, ownership and reentrancy are covered.

The helper suite uses this repository's actual StakingRewards implementation,
compiled natively with Solidity 0.8.26. Its Vault fixture is the actual Monolith
Vault bytecode, compiled unchanged with Solidity 0.8.24. Only lender interest,
Token/GOV assets and the append-only registry are simulated for these focused
tests. The independent registry fixture checks the fourteen-address public
getter against the struct-returning adapter. No staking or vault source is copied
or given a different compiler pragma.

### Full integration

The four integration scenarios launch the actual Monolith Factory, Lender,
Coin, InterestModel and Vault, plus this repository's actual CoinDAOFactory,
eight implementations and funded staking-rewards pools. They deploy the native
0.8.26 helper factory from the governance build artifacts. Only external
collateral and its price feed are simulated. Users obtain Token by borrowing;
vault yield comes from real debt interest, and GOV rewards come from the actual
factory/funder launch flow.

Coverage includes two owners, partial and full exits with optional claiming,
helper reuse, future DAOs, direct-Token-staking rejection and an existing-market
attachment whose Monolith index differs from its CoinDAO ID.

`lib/monolith` is pinned to commit
`5579b654e68db2a53beb6e5ec99ec677d325cfc2`. The dedicated
`integration/monolith` project preserves Monolith's exact Solidity 0.8.24
compiler. The governance contracts and helper use Solidity 0.8.26. The test-only
`CoinDAOTestDeployer` constructs launch arguments using the actual native
factory types; artifact reads provide the bridge between compiler versions.

The root project permits reads only from the Monolith fixture artifact folder;
the integration project permits reads only from the governance artifact folder.
Build-info output ensures all deployable artifacts are emitted for the cross-
compiler tests. Dynamic test linking is disabled for the focused helper and
integration suites for expected-constructor-revert compatibility with Foundry
v1.8.5.

CI runs the 84 existing governance tests, the 40 helper tests and the four real
integration scenarios without an RPC dependency. A complete root test run can
also be performed after building the Monolith fixtures; the focused profile
provides the specified fuzz and invariant settings.

These are local integration tests, not live-state or mainnet-fork checks. This
change does not deploy any contracts onchain.
