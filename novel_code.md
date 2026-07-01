# Novel vs. Battle-Tested Code

This document classifies every Solidity contract the Monolith CoinDAO factory deploys (or
links against) by **how much of it is original code written for this project** versus **how
much is audited, in-production code reused from elsewhere**. The goal is to focus audit and
review effort on the genuinely new surface area.

Scope: `src/**` (deployed code) and `lib/**` (dependencies). Test code (`test/**`) and
`lib/forge-std` are out of scope — they are never deployed on-chain.

## Legend

| Tag | Meaning |
| :-- | :-- |
| 🟢 **Production / vendored** | Audited upstream code, live on mainnet, used essentially as-is. Lowest risk. |
| 🟢 **Imported library** | Unmodified third-party library imported from `lib/`. Lowest risk. |
| 🟡 **Adapted** | Logic taken from a battle-tested source but reimplemented/modernized here. Medium risk — the *pattern* is proven, this *transcription* is not. |
| 🟡 **Standard composition** | New bytecode, but only library inheritance + parameter choices + compiler-mandated override stubs. No novel business logic. Low-medium risk. |
| 🔴 **Novel** | Original to this project, no upstream equivalent. Highest risk — needs primary audit attention. |

## Summary table

| File | Lines | Tag | Provenance | Novel business logic? |
| :-- | --: | :-- | :-- | :-- |
| `src/UniStaker.sol` | 879 | 🟢 Production / vendored | ScopeLift / Uniswap Foundation | None (1-line pragma relax) |
| `src/DelegationSurrogate.sol` | 29 | 🟢 Production / vendored | ScopeLift / Uniswap Foundation | None (1-line pragma relax) |
| `src/interfaces/INotifiableRewardReceiver.sol` | 14 | 🟢 Production / vendored | ScopeLift / Uniswap Foundation | None |
| `src/interfaces/IERC20Delegates.sol` | 31 | 🟢 Production / vendored | ScopeLift / Uniswap Foundation | None |
| `lib/openzeppelin-contracts` (v5.6.1) | — | 🟢 Imported library | OpenZeppelin | None |
| `src/StakingRewards.sol` | 161 | 🟡 Adapted | Synthetix `StakingRewards` | Solidity 0.8 built-in safe math port; removed pause, recovery, and mutable duration hooks |
| `src/GovToken.sol` | 29 | 🟡 Standard composition | OZ ERC20 + Permit + Votes | None (fixed-supply parameter only) |
| `src/CoinDAOGovernor.sol` | 96 | 🟡 Standard composition | OZ `Governor` + extensions | None (parameters only) |
| `src/RevenueRouter.sol` | 81 | 🔴 Novel | Written for Monolith | Yes |
| `src/StakingRewardsFunder.sol` | 83 | 🔴 Novel | Written for Monolith | Yes |
| `src/CoinDAOFactory.sol` | 245 | 🔴 Novel | Written for Monolith | Yes (most) |
| `src/interfaces/IMonolith.sol` | 33 | 🔴 Novel (interface only) | Written for Monolith | No logic; bespoke ABI |

Roughly **~410 lines of genuinely novel logic** (`CoinDAOFactory` + `RevenueRouter` +
`StakingRewardsFunder`) sit on top of **~1,240 lines of vendored, adapted, or
standard-composition code** plus the entire OpenZeppelin
library.

---

## 🟢 Production / vendored — lowest risk

### `src/UniStaker.sol`, `src/DelegationSurrogate.sol` + their interfaces
The GOV staking layer. Stakers deposit GOV, keep their governance voting power via a
per-delegatee `DelegationSurrogate`, and earn streamed Coin revenue forwarded by `RevenueRouter`.

- **Author:** ScopeLift, for the Uniswap Foundation.
- **Audit:** Code4rena competitive audit, Feb 2024 (`code4rena.com/reports/2024-02-uniswap-foundation`), plus additional reviews (Trail of Bits / OpenZeppelin).
- **Production:** deployed and verified on Ethereum mainnet as Uniswap's fee-distribution mechanism since ~March 2024.
- **Changes in this repo:** the *only* modification is relaxing the pragma in `UniStaker.sol` and `DelegationSurrogate.sol` from `pragma solidity 0.8.23;` to `pragma solidity ^0.8.23;` so the source compiles against OpenZeppelin v5.6.1 (which requires `^0.8.24`). No logic changed. See `ATTRIBUTIONS.md`.
- **Residual risk:** (a) it is compiled here against **OZ 5.6.1 + Solc 0.8.24**, not the exact dependency set / compiler of the audited deployment, so the *bytecode* is not identical to the audited artifact; (b) the reward duration is a hard-coded `30 days` constant; (c) per-deposit balances are `uint96` (max ~7.9e28 wei). These are properties of the upstream contract, not new bugs.

> The two interface files (`INotifiableRewardReceiver`, `IERC20Delegates`) are part of the same
> vendored set and contain no logic.

## 🟢 Imported library — lowest risk

### `lib/openzeppelin-contracts` v5.6.1
The most widely deployed Solidity library in production; audited and battle-tested. Imported
unmodified and relied on by nearly every contract here:

- `GovToken`: `ERC20`, `ERC20Permit`, `ERC20Votes`, `Nonces`.
- `CoinDAOGovernor`: `Governor`, `GovernorSettings`, `GovernorCountingSimple`, `GovernorVotes`, `GovernorVotesQuorumFraction`, `GovernorTimelockControl`.
- `CoinDAOFactory`: `TimelockController`, `VestingWallet` (treasury / Monolith / deployer vesting), `IVotes`, `SafeERC20`.
- `RevenueRouter`: `Ownable`, `SafeERC20`.
- `StakingRewards`: `Ownable`, `ReentrancyGuard`, `SafeERC20`.
- `StakingRewardsFunder`: `ReentrancyGuard`, `SafeERC20`.
- `UniStaker`: `Multicall`, `Nonces`, `SignatureChecker`, `EIP712`, `SafeERC20`.

All treasury/vesting behavior (`VestingWallet`), the timelock (`TimelockController`), and the
core Governor proposal/voting/queue/execute machinery are therefore **stock OpenZeppelin**, not
novel.

---

## 🟡 Adapted — medium risk

### `src/StakingRewards.sol` (the CoinStakingRewards bootstrap module)
Stakers deposit Coin or sCoin and earn GOV emissions. This is a **modern reimplementation of
Synthetix `StakingRewards`** (MIT) — the canonical, long-lived staking-rewards pattern, live on
mainnet for years (`0x8302fe9f0c509a996573d3cc5b0d5d51e4fdd5ec`).

- **Battle-tested:** the reward-rate math and core stake/withdraw/claim flow follow Synthetix `StakingRewards`.
- **Changed from Synthetix:** SafeMath calls are replaced with Solidity 0.8 built-in checked arithmetic; the reward duration is constructor-supplied/immutable (the factory uses 365 days per tranche); pause, `recoverERC20`, and mutable `setRewardsDuration` functionality are removed because the launch flow does not need them.
- **Known inherited caveat:** rewards that stream while `totalSupply == 0` accrue to nobody, matching upstream Synthetix behavior.

## 🟡 Standard composition — low/medium risk (new bytecode, no novel logic)

### `src/GovToken.sol`
The fixed-supply governance token. It is the **standard OpenZeppelin `ERC20Votes` preset**:
`ERC20 + ERC20Permit + ERC20Votes`. The only non-library code is a fixed
`10_000_000 * 1e18` supply constant, a constructor `ZeroAddress` guard + `_mint`, and the
`_update` / `nonces` overrides that are **compiler-mandated `super` disambiguation** for multiple
inheritance. No novel business logic.

### `src/CoinDAOGovernor.sol`
The governor. A thin composition of OZ `Governor` + five standard extensions. Every function in
the file (`votingDelay`, `votingPeriod`, `proposalThreshold`, `quorum`, `state`,
`proposalNeedsQueuing`, `_queueOperations`, `_executeOperations`, `_cancel`, `_executor`) is a
one-line `super.X()` override required by OZ's multiple inheritance — **no custom logic**. The
only project-specific content is parameter choices:

- `votingDelay = 7200` blocks (~1 day), `votingPeriod = 36000` blocks (~5 days), `quorumNumerator = 1` (1%), and `proposalThreshold` passed in by the factory (`GOV_TOKEN_SUPPLY / 1000`).

Risk is therefore **parameterization, not code** — e.g. quorum is now 1% of total GOV supply
(GOV is the vote token), which is worth tuning, but the Governor logic itself is stock OZ.

---

## 🔴 Novel — highest risk, primary audit targets

### `src/CoinDAOFactory.sol` (~245 lines)
The orchestration contract and the **single largest piece of original logic**. No upstream
equivalent. It contains two distinct novel concerns:

1. **`allocationFor()` — the supply-distribution math.** Uses the fixed 10M GOV supply. Monolith
   receives 2% of total supply; the deployer can receive up to 20% of total supply; 66.66% of the
   remaining supply funds CoinStakingRewards; the residual treasury allocation is split 10%
   immediately to the timelock and 90% to treasury vesting. Integer rounding is absorbed into the
   residual treasury vesting bucket so the buckets sum exactly to total supply. Pure arithmetic,
   fully novel, and the most unit-test-worthy part.
2. **`deploy()` — the wiring and privilege handoff.** Deploys the whole stack and performs the
   critical role transfers: uses the immutable Monolith factory set in the constructor; deploys a
   derived-name Governor (`<GOV token name> Governor`); grants the Governor `PROPOSER`/`CANCELLER`
   on the timelock and renounces the factory's `DEFAULT_ADMIN_ROLE`; registers `RevenueRouter` as a
   UniStaker reward notifier then hands UniStaker admin to the timelock; sets `RevenueRouter` as the
   Lender operator and transfers its ownership to the timelock; deploys `StakingRewardsFunder`,
   transfers the full CoinStakingRewards GOV allocation to it, sets it as the rewards distribution,
   immediately funds tranche 0, and renounces `StakingRewards` ownership; funds treasury
   immediate/vesting, Monolith vesting, and optional deployer vesting.
   A bug here is a **misconfiguration / privilege-escalation** risk rather than a math bug — the
   ordering and completeness of these handoffs is the thing to audit.

It holds no funds after `deploy()` returns, but it is the trust root for how every deployed DAO
is wired.

### `src/StakingRewardsFunder.sol` (~83 lines)
Small, fully novel GOV-emissions scheduler for CoinStakingRewards. The factory gives it the full
CoinStakingRewards allocation up front, installs it as `StakingRewards.rewardsDistribution`, and
uses it to start the first reward period during deployment.

- **`fundNextTranche()`** — permissionless release function. It can only run when the previous
  reward period has finished, verifies this contract is still the `rewardsDistribution`, advances
  `nextTranche`, transfers the tranche amount to `StakingRewards`, and calls
  `notifyRewardAmount`.
- **Tranche schedule** — four yearly tranches: 32.5%, 27.5%, 22.5%, then final balance sweep.
  The first three tranches are calculated from immutable `totalRewards`; the final tranche is the
  funder's remaining reward-token balance so rounding dust is paid out.
- **State model** — there is no separate `fundedRewards` counter. Progress is represented by
  `nextTranche`; funded/unfunded amounts are observable from token balances and events.
- **Assumption to audit** — the final balance sweep is correct for the factory path because the
  funder receives the full allocation up front and has no alternate token outflow. If reused
  outside that path, direct token transfers into the funder or incomplete prefunding would change
  the final tranche amount.

### `src/RevenueRouter.sol` (~81 lines)
Small but fully novel, and it touches money and privileged Lender control:

- **`distribute()`** — splits Coin revenue between the gov staker and the treasury by
  `govStakingBps`, transfers, and calls `notifyRewardAmount`. Permissionless to call.
- **`setManager()`** — lets the owner (timelock) replace the Lender's operational manager. This
  is a privileged cross-contract call into the external Monolith Lender.
- **`setGovStakingBps()` / `acceptLenderOperator()`** — owner-gated config + operator handoff.

Built on OZ `Ownable` + `SafeERC20` (battle-tested primitives), but the routing/authority logic
is original and should be audited closely — especially the interaction contract (`govStaking`,
typed as the vendored `INotifiableRewardReceiver`) and the manager-replacement path.

### `src/interfaces/IMonolith.sol` (~33 lines, interface only — no runtime logic)
Bespoke `IMonolithFactory` / `IMonolithLender` interfaces describing the **external, pre-existing
Monolith protocol** that this factory integrates with. There is no logic to audit, but the risk
is real and specific: **these signatures must exactly match the deployed Monolith contracts.** A
mismatched selector or parameter layout would cause silent miswiring at deploy time. Verify
against the canonical Monolith ABI, not just compilation.

---

## Cross-cutting notes

- **Shared reward-streaming lineage.** Both `StakingRewards.sol` (Synthetix, adapted) and
  `UniStaker.sol` (Synthetix-derived, vendored + audited) implement the same Synthetix
  reward-per-token streaming pattern. Reviewers familiar with one will recognize the other; the
  difference is that UniStaker's version is audited-and-deployed while StakingRewards' is a local
  transcription.
- **License provenance.** The whole project is AGPL-3.0-only because it incorporates UniStaker;
  see `ATTRIBUTIONS.md` for per-component licenses (OZ and Synthetix are MIT, one-way compatible
  into AGPL).
- **Compiler.** Pinned to Solc 0.8.24 (`foundry.toml`) — the minimum that satisfies OZ 5.6.1 and
  the closest to UniStaker's audited 0.8.23.

## Suggested audit priority

1. **`CoinDAOFactory.sol`** — novel math (`allocationFor`) + novel privilege wiring (`deploy`).
2. **`RevenueRouter.sol`** — novel fund-routing + privileged Lender manager replacement.
3. **`StakingRewardsFunder.sol`** — novel tranche gating + final balance-sweep emission schedule.
4. **`StakingRewards.sol`** — adapted Synthetix contract; verify the built-in safe math port and intentionally removed hooks.
5. **`IMonolith.sol`** — confirm the interface matches the live Monolith ABI exactly.
6. **`CoinDAOGovernor.sol` / `GovToken.sol`** — review *parameters* (quorum, thresholds, periods), not logic.
7. **UniStaker set + OpenZeppelin** — confirm versions/pins and the single pragma change; rely on upstream audits otherwise.
