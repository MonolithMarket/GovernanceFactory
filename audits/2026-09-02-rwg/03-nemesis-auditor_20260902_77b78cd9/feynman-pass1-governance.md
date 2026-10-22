# Feynman Auditor — Pass 1 (Governance Layer)

**Engagement:** NEMESIS audit of the CoinDAO launch stack
**Lens:** `.claude/skills/feynman-auditor/SKILL.md`, Phases 0–5, executed in full
**Language:** Solidity 0.8.26 / Foundry, via-ir, optimizer 200 runs
**Tree under audit:** `[local-path]` (read-only; never written to)
**PoC workspace:** `[home]\AppData\Local\Temp\claude\c--RWG-CodeAudit\[session-id]\[scratch]`
(a disposable copy; remaps `lib/` back to the audited tree so the audited bytes are unchanged)

**Scope files (interrogated line by line):**

| file | lines | role |
|---|---|---|
| `[scratch]` | 104 | OZ Governor composition, `quorumDenominator` overridden |
| `[scratch]` | 41 | fixed 10,000,000 supply ERC20Votes |
| `[scratch]` | 10 | thin wrapper over OZ `VestingWalletUpgradeable` |
| `[scratch]` | 39 | hand-written interface to an external protocol |
| `[scratch]` | 318 | per-DAO launch tooling |
| `[scratch]` | 75 | factory + implementation-set launch tooling |

**Cross-file context read (not in scope, not reported against):** `CoinDAOFactory.sol`,
`StakedGovToken.sol`, `RevenueRouter.sol`, `deployment/DeploymentLibraries.sol`,
`test/helpers/CoinDAOTestBase.sol`, `test/mocks/MockMonolith.sol`, `test/CoinDAOGovernor.t.sol`.
**Not read:** `[scratch]` (vendored OZ), anything under `engagements/`.

**Execution status: 21 PoC tests written, 21 pass, plus 3 mutation runs.**
Full tree suite after my additions: **76 passed / 0 failed** with the audited sources
byte-identical to the originals (`diff -q` clean, verified after every mutation).

```
test/audit/FeynmanGovernance.t.sol     8 passed
test/audit/FeynmanScripts.t.sol        9 passed
test/audit/FeynmanGovernorGuards.t.sol 4 passed
```

---

## PHASE 0 — ATTACKER'S HIT LIST (my own, derived before reading the scope files)

The recon note at `.audit/findings/nemesis-phase0-recon.md` was read for structural facts only.
Its priority order (Governor/Vesting/scripts last) is **rejected** for this pass: the governance
layer is the single point at which every other value store becomes reachable, so it is where I
spent my time.

```
LANGUAGE: Solidity 0.8.26 (Foundry). Terminology: contract / external fn / modifier /
          msg.sender / revert / storage / checked math by default (>=0.8).

ATTACK GOALS (Q0.1):
  1. Pass an arbitrary proposal with a minority stake, and thereby reach EVERY
     asset the Timelock controls (treasury vesting stream, liquid GOV, the
     RevenueRouter, the external Lender's manager role).
  2. Redirect or permanently strand a four-year vesting allocation.
  3. Cause a real launch to be mis-parameterised in a way the launch tooling
     reports as "verified".
  4. Point a launcher at a factory that is not the intended one.

NOVEL CODE — highest bug density (Q0.2):
  - CoinDAOGovernor: the ONLY non-boilerplate lines are `quorumDenominator() => 1_000`
    and the two hardcoded GovernorSettings constants. Everything else is `super.x()`.
    A five-line surface, three of which are parameters. Parameters are the code here.
  - The factory-supplied pair (GOVERNOR_QUORUM_NUMERATOR = 1, GOVERNOR_PROPOSAL_THRESHOLD
    = supply/1000) is novel only in its arithmetic relationship to that override.
  - CoinDAOVestingWallet: novel by SUBTRACTION. The interesting content is what the
    wrapper declines to constrain, not what it adds.
  - IMonolith.sol: hand-transcribed ABI for a protocol whose source is not in the tree.
  - Both scripts: entirely bespoke; nothing about them is battle-tested.

VALUE STORES (Q0.3):
  - Timelock: 500,000 GOV liquid at launch (when deployerRecipient == 0), owner of
    RevenueRouter, owner/beneficiary of treasuryVesting. Outflow: any executed proposal.
  - treasuryVesting: 2,800,000 GOV. Outflow: release() to owner(); owner is transferable.
  - monolithVesting: 200,000 GOV. Outflow: release() to owner(); owner is an EOA.
  - deployerVesting: 0–2,000,000 GOV. Same shape.
  - immediateRecipient: 500,000 GOV liquid, unvested, on day one.

COMPLEX PATHS (Q0.4):
  propose -> (7200 blocks) -> castVote -> (36000 blocks) -> queue -> (2 days) -> execute
  -> TimelockController.executeBatch -> arbitrary call. Four contracts, three clocks
  (block number for voting, wall clock for the timelock and for vesting), one arbitrary
  call at the end. The clock mismatch and the arbitrary tail are where I looked hardest.

PRIORITY ORDER:
  1. CoinDAOGovernor's three parameters — smallest surface, largest blast radius.
  2. CoinDAOVestingWallet's inherited-but-unconstrained surface.
  3. DeployCoinDAO.s.sol's validation and verification asymmetries.
  4. GovToken (fixed supply, little to get wrong) and IMonolith (no state).
```

---

## PHASE 1 — SCOPE, INVENTORY AND FUNCTION-STATE MATRIX

### Storage actually written by the scoped contracts

`CoinDAOGovernor` declares **no storage of its own** — every slot it touches belongs to an
OZ base. Naming them explicitly matters for Pass 2, so they are named here.

| logical state | owning base | written by |
|---|---|---|
| `_proposals[id]` (proposer, voteStart, voteDuration, executed, canceled, etaSeconds) | `Governor` | `propose`, `queue`, `execute`, `cancel` |
| `_proposalVotes[id]` (against/for/abstain, hasVoted) | `GovernorCountingSimple` | `castVote*` |
| `_votingDelay`, `_votingPeriod`, `_proposalThreshold` | `GovernorSettings` | constructor, `setVotingDelay/Period/ProposalThreshold` (onlyGovernance) |
| `_quorumNumeratorHistory` (Checkpoints.Trace208) | `GovernorVotesQuorumFraction` | constructor, `updateQuorumNumerator` (onlyGovernance) |
| `_timelock`, `_timelockIds[id]` | `GovernorTimelockControl` | constructor, `_queueOperations`, `_cancel`, `updateTimelock` |
| `_governanceCall` (DoubleEndedQueue) | `Governor` | `execute` |
| `_nonces[voter]` | `Nonces` | `castVoteBySig` |
| `_balances`, `_totalSupply`, `_allowances`, `_name`, `_symbol` | `ERC20Upgradeable` | `initialize`, transfers |
| `_delegatee`, `_delegateCheckpoints`, `_totalCheckpoints` (GovToken) | `ERC20VotesUpgradeable` | `_update`, `delegate` — **never read by anything in this system** |
| `_nameFallback`/`_versionFallback`/EIP-712 cache | `EIP712Upgradeable` | `initialize` |
| `_initialized`, `_initializing` | `Initializable` | `initialize`, `_disableInitializers` |
| `_owner` (vesting wallet) | `OwnableUpgradeable` | `initialize`, `transferOwnership`, `renounceOwnership` |
| `_released`, `_erc20Released[token]`, `_start`, `_duration` | `VestingWalletUpgradeable` | `initialize`, `release`, `release(token)` |

### Function-State Matrix

**Legend for Guards:** `—` = none. Entry points reachable by an arbitrary caller are marked ⚑.

#### `CoinDAOGovernor` (in scope; inherited entry points included because they are the real attack surface)

| Function | Reads | Writes | Guards | Calls |
|---|---|---|---|---|
| `constructor(name,token,timelock,threshold,numerator)` L25–37 | — | `_name`, `_votingDelay`, `_votingPeriod`, `_proposalThreshold`, `_quorumNumeratorHistory`, `_token`, `_timelock` | none (CREATE2 from factory only) | `quorumDenominator()` (virtual dispatch into the derived override, from a base constructor) |
| `votingDelay()` L39–41 | `_votingDelay` | — | — | `super` |
| `votingPeriod()` L43–45 | `_votingPeriod` | — | — | `super` |
| `proposalThreshold()` L47–49 | `_proposalThreshold` | — | — | `super` |
| `state(id)` L51–53 | `_proposals[id]`, `_timelockIds[id]`, timelock op state | — | — | `super`, `TimelockController.isOperationDone/Pending` |
| `proposalNeedsQueuing(id)` L55–62 | — | — | — | `super` (constant `true`) |
| `quorum(t)` L64–66 | `_quorumNumeratorHistory`, **`stGOV.getPastTotalSupply(t)`** | — | — | `StakedGovToken.getPastTotalSupply` |
| `quorumDenominator()` L68–70 | — | — | — | none (`pure`, constant 1_000) |
| `_queueOperations(...)` L72–80 | `_timelock` | `_timelockIds[id]` | internal; caller `queue()` ⚑ requires state Succeeded | `TimelockController.scheduleBatch` |
| `_executeOperations(...)` L82–90 | `_timelock` | timelock's `_timestamps` | internal; caller `execute()` ⚑ requires state Succeeded/Queued | `TimelockController.executeBatch` → **arbitrary external call** |
| `_cancel(...)` L92–99 | `_timelockIds[id]` | `_proposals[id].canceled`, `_timelockIds[id]` | internal; public `cancel()` requires `msg.sender == proposer` **and** state == Pending | `TimelockController.cancel` |
| `_executor()` L101–103 | `_timelock` | — | — | `super` |
| *(inherited)* `propose` ⚑ | `getVotes(proposer, clock()-1)`, `_proposalThreshold` | `_proposals[id]` | votes ≥ threshold | `stGOV.getPastVotes` |
| *(inherited)* `castVote` ⚑ | `getVotes(voter, snapshot)` | `_proposalVotes[id]` | state == Active, not already voted | `stGOV.getPastVotes` |
| *(inherited)* `queue` ⚑ / `execute` ⚑ | `_proposals[id]` | as above | state machine only — **no role gate** | `_queueOperations` / `_executeOperations` |
| *(inherited)* `updateQuorumNumerator`, `setVotingDelay`, `setVotingPeriod`, `setProposalThreshold`, `updateTimelock`, `relay` | — | the settings slots | `onlyGovernance` (msg.sender == timelock) | — |

#### `GovToken`

| Function | Reads | Writes | Guards | Calls |
|---|---|---|---|---|
| `constructor()` L16–18 | — | `_initialized = type(uint64).max` | — | `_disableInitializers` |
| `initialize(name,symbol,initialHolder)` L20–27 ⚑ | `initialHolder` | `_name`,`_symbol`, EIP-712 name/version, `_balances[holder]`, `_totalSupply` | `initializer`; `initialHolder != 0` | `_mint(holder, 10_000_000e18)` |
| `_update(from,to,value)` L29–34 | `_balances` | `_balances`, `_totalSupply`, `_delegateCheckpoints`, `_totalCheckpoints` | internal | `super` (ERC20 → ERC20Votes) |
| `nonces(owner)` L36–38 | `_nonces[owner]` | — | — | `super` |

#### `CoinDAOVestingWallet` — the wrapper adds one constructor; everything else is inherited and **unconstrained**

| Function | Reads | Writes | Guards | Calls |
|---|---|---|---|---|
| `constructor()` L7–9 | — | `_initialized` | — | `_disableInitializers` |
| *(inherited)* `initialize(beneficiary,start,duration)` ⚑ | — | `_owner`, `_start`, `_duration` | `initializer` — **no zero-beneficiary check, no minimum duration** | `__Ownable_init` |
| *(inherited)* `release(token)` ⚑ | `IERC20(token).balanceOf(this)`, `_erc20Released[token]`, `_start`, `_duration`, `_owner` | `_erc20Released[token]` | none — permissionless, pays `owner()` | `SafeERC20.safeTransfer` |
| *(inherited)* `release()` ⚑ | ETH balance, `_released` | `_released` | none | `Address.sendValue(owner())` |
| *(inherited)* `releasable`, `vestedAmount`, `start`, `duration`, `end` | as above | — | — | — |
| *(inherited)* `transferOwnership(addr)` | `_owner` | `_owner` | `onlyOwner` — **not overridden** | — |
| *(inherited)* `renounceOwnership()` | `_owner` | `_owner = address(0)` | `onlyOwner` — **not overridden** | — |
| *(inherited)* `receive()` ⚑ | — | ETH balance | none | — |

#### `IMonolith.sol` — interface only, no state. Declared surface:

`IMonolithFactory.deploy(DeployParams)`, `.isDeployed(address)`;
`IMonolithLender.operator()`, `.pendingOperator()`, `.coin()`, `.vault()`,
`.setPendingOperator()`, `.acceptOperator()`, `.setManager()`, `.pullLocalReserves()`.
**`manager()` is absent** although `setManager()` is present — see FF-010.

#### `DeployCoinDAOScript`

| Function | Reads | Writes | Guards | Calls |
|---|---|---|---|---|
| `run()` L44–77 ⚑ | env `PRIVATE_KEY`, `COIN_DAO_FACTORY`, `COIN_DAO_SALT`, chain state | **broadcasts `factory.deploy`** | `block.chainid == 11155111`, `privateKey != 0`, factory has code | `_preflight`, `govParamsFromEnv`, `monolithParamsFromEnv`, `predictCoinDAOAddresses`, `deploy`, `_verifyDeployment`, `_verifyPredictedAddresses` |
| `govParamsFromEnv()` L79–85 | env `DEPLOYER_STAKE_BPS`, `DEPLOYER_RECIPIENT`, `STAKING_TOKEN` | — | — | `buildGovParams` |
| `buildGovParams(bps,recipient,token)` L91–115 | — | — | `bps <= 2000`; `bps == 0 \|\| recipient != 0` — **one direction only** | `SafeCast.toUint16` |
| `monolithParamsFromEnv()` L117–139 | 9 env vars | — | — | `buildMonolithParams` |
| `buildMonolithParams(...)` L155–196 | — | — | 7 requires + 1 unreachable require; **`minDebt` has none**; `stalenessThreshold` capped only at `uint32` max | `SafeCast` |
| `_preflight(factory)` L198–219 | Monolith factory code, `factory.monolithFactory()`, implementation code, WETH metadata, Chainlink round, env `STALENESS_THRESHOLD` | — | 11 requires | `IERC20Metadata`, `IChainlinkAggregatorV3`, `_preflightImplementations` |
| `_preflightImplementations(set)` L221–228 | `.code.length` × 6 | — | 6 requires — **provably unfalsifiable, FF-007** | — |
| `_verifyDeployment(...)` L230–263 | `deploymentsLength`, `hasCoinDAO`, `.code.length` × 12, `lender.operator()`, `manager()`, `stakingToken` | — | 16 requires — **zero balance checks, zero role checks, FF-006** | `_managerOf` |
| `_managerOf(lender)` L265–269 | raw `staticcall("manager()")` | — | `success && result.length == 32` | — |
| `_logDeployment` / `_logPredictedAddresses` L271–299 | — | — | — | `console.log` |
| `_verifyPredictedAddresses(...)` L301–317 | — | — | 9 requires (10th conditional) | — |

#### `DeployCoinDAOFactoryScript`

| Function | Reads | Writes | Guards | Calls |
|---|---|---|---|---|
| `run()` L19–74 ⚑ | env `PRIVATE_KEY`, `MONOLITH_BENEFICIARY` | broadcasts 6 `new X()` + `new CoinDAOFactory` | chainid, Monolith factory has code, key != 0, beneficiary != 0 | 7 constructors, 7 post-hoc requires |

### Function pairs identified for inverse-parity analysis (Phase 3)

`propose`/`cancel` · `queue`/`cancel` · `transferOwnership`/`renounceOwnership` ·
`setPendingMonolithBeneficiary`/`acceptMonolithBeneficiary` (factory, context only) ·
`predictCoinDAOAddresses`/`deploy` · `_preflight`/`_verifyDeployment` ·
`buildGovParams`(validate)/`_verifyDeployment`(verify) · `buildMonolithParams` per-parameter bounds.

---

## PHASE 2 — LINE-BY-LINE INTERROGATION

Format per the skill. Only lines whose verdict is not trivially SOUND carry full question sets;
boilerplate override lines are dispatched in a block with the reasoning that dispatches them.

---

### FUNCTION: `CoinDAOGovernor.constructor` — L25–37

```
Visibility: constructor (reachable only via GovernorDeploymentLib.deployGovernor, CREATE2 from the factory)
Guards: none
State writes: _name, _votingDelay, _votingPeriod, _proposalThreshold,
              _quorumNumeratorHistory, _token, _timelock
External calls: quorumDenominator() (self, virtual dispatch from a base constructor)
```

**L22 `uint48 public constant DEFAULT_VOTING_DELAY_BLOCKS = 7_200;`**
- Q1.1 WHY: to give holders ~24 h (at 12 s/block) between proposal and snapshot.
- Q4.4 ASSUMES: that the votes token's clock is **block number**, and that a block is ~12 s.
  Verified by execution: `governor.CLOCK_MODE() == "mode=blocknumber&from=default"`
  (`testClockModeIsBlockNumber`). The assumption holds on Ethereum L1 and Sepolia.
  It does **not** hold on any 2 s-block L2, where the same constant is 4 h.
- Q2.5 ORDER: the snapshot block is `proposalBlock + 7200` — deterministic and public
  7200 blocks in advance. That is not an incidental fact; it is the enabling condition
  for FF-002.
- **VERDICT: SUSPECT** (chain-portability + it publishes the exact block an attacker must
  be present in). Scenario in FF-002 / FF-012.

**L23 `uint32 public constant DEFAULT_VOTING_PERIOD_BLOCKS = 36_000;`**
- Q1.1 WHY: ~5 days of voting. Q1.2 DELETE: `GovernorSettings._setVotingPeriod` rejects 0,
  so a value is required. Q5.x: 36_000 fits `uint32`. **VERDICT: SOUND.**

**L33 `GovernorSettings(DEFAULT_VOTING_DELAY_BLOCKS, DEFAULT_VOTING_PERIOD_BLOCKS, proposalThreshold_)`**
- Q1.1 WHY: two hardcoded, one injected. Q3.3 CONSISTENCY: **why is the threshold
  factory-supplied while the delay and period are compile-time constants?** All three are
  the same class of governance parameter and all three are `onlyGovernance`-mutable after
  launch. No comment explains the split. I cannot explain it. **CANNOT EXPLAIN — flagged.**
- **VERDICT: SUSPECT** (inconsistent parameterisation; low direct impact, but it is the
  seam through which the threshold/quorum mismatch entered — FF-001).

**L35 `GovernorVotesQuorumFraction(quorumNumerator_)`** — factory supplies `1`.
- Q1.3 WHAT MOTIVATED: a 0.1 % quorum, given L68's denominator.
- Q1.4 IS IT SUFFICIENT: **no — and provably no at any value.** See L68 and FF-001.
- **VERDICT: VULNERABLE.**

**L34 `GovernorVotes(token_)`** — the factory passes `IVotes(staker)`, i.e. **stGOV**, the
non-transferable staked wrapper, not `GovToken`.
- Q4.3 ASSUMES: that "supply of the votes token" is a sensible quorum base. It is not: the
  stGOV supply is *participation*, and quorum-as-a-fraction-of-participation is
  self-referential — the more apathetic the electorate, the lower the bar.
- Q4.1 ASSUMES: that a voter's stake persists through the vote. It does not — `getPastVotes`
  is historical (FF-002).
- **VERDICT: VULNERABLE.** Touches `_delegateCheckpoints` / `_totalCheckpoints` of
  `StakedGovToken` — **Pass 2 note: this is the coupling to StakedGovToken's mint/burn path.**

**L36 `GovernorTimelockControl(timelock_)`** — makes `_executor()` the timelock.
- Q1.2 DELETE: without it the Governor executes calls itself and there is no delay at all.
  So it protects the "someone can look at a passed proposal for 2 days" invariant.
- Q1.4 SUFFICIENT: only if someone *can act* in those 2 days. Nobody can — FF-004.
- **VERDICT: SUSPECT.**

---

### FUNCTION: `CoinDAOGovernor.quorumDenominator` — L68–70

```
Visibility: public pure override
Guards: none
State: none
```

**L69 `return 1_000;`**
- Q1.1 WHY: to express the quorum in per-mille rather than per-cent, so a sub-1 % quorum
  is expressible. That is a legitimate motive.
- Q1.2 DELETE: the OZ default of 100 would apply and `quorumNumerator_ = 1` would mean 1 %,
  ten times stricter.
- Q1.4 **IS THE RESULTING QUORUM SUFFICIENT?** With numerator 1:
  `quorum(t) = stGOVsupply(t) / 1000`. The stGOV wrapper is 1:1 over GOV, whose supply is
  the file-level constant `10_000_000e18`. Therefore
  `quorum(t) <= 10_000_000e18 / 1000 = 10_000e18 == GOVERNOR_PROPOSAL_THRESHOLD`, **for
  every reachable state, with equality only if 100 % of GOV is staked.** Anyone who is
  permitted to propose necessarily already holds enough votes to satisfy quorum alone.
  Proven by execution (`testQuorumCanNeverExceedProposalThreshold`).
- Q2.x ORDER: `quorumDenominator()` is called from `GovernorVotesQuorumFraction`'s
  constructor *before* the derived contract's own body runs. Because the override is `pure`
  and reads no storage, the virtual dispatch is safe here. Had it been made a storage-backed
  variable, the constructor would have read zero and division would revert. Worth stating:
  **this line is safe only because it is `pure`.** VERDICT for that aspect: SOUND.
- **VERDICT: VULNERABLE.** → FF-001.

---

### FUNCTION: `CoinDAOGovernor.quorum` — L64–66

**L65 `return super.quorum(timepoint);`** → `getPastTotalSupply(t) * numerator(t) / 1000`.
- Q4.6 AMOUNTS: at `getPastTotalSupply == 0`, quorum is 0 and `_quorumReached` is
  `0 >= 0 == true`. Not independently exploitable (a For vote still requires stake) but it
  means the quorum gate is *open by default* rather than closed by default.
- Q3.x: quorum counts **undelegated** stGOV, while `forVotes` counts only **delegated**
  votes. Proven: `testNonDelegatingStakersRaiseQuorumButSupplyNoVotes` — 400,000 stGOV
  staked without delegation produced `quorum == 400 GOV` and `getVotes == 0`.
  Consequence: a non-delegating staker base raises the bar for honest proposals and does
  nothing against a self-delegated attacker.
- **VERDICT: SUSPECT** → FF-011 (LOW).

---

### FUNCTIONS: `votingDelay`, `votingPeriod`, `proposalThreshold`, `state`,
### `proposalNeedsQueuing`, `_queueOperations`, `_executeOperations`, `_cancel`, `_executor`
### — L39–62, L72–103

Every one of these is `return super.x(...)`.
- Q1.1 WHY: Solidity requires an explicit override when a function is inherited from two
  bases. Q1.2 DELETE: compile error (`TypeError: Derived contract must override`). So none
  of them is dead code, and none of them changes behaviour.
- Q1.4: I checked each `override(...)` list against the linearisation
  `Governor → GovernorSettings → GovernorCountingSimple → GovernorVotesQuorumFraction →
  GovernorTimelockControl`. `super` therefore resolves rightward: `state` and
  `_executeOperations` reach `GovernorTimelockControl` first, which is the intended target.
  **No override silently bypasses the timelock.** This was the specific thing I was looking
  for — a `super` chain that skips `GovernorTimelockControl` would make execution
  instantaneous. It does not.
- **VERDICT: SOUND** (all nine).

One absence check, run explicitly because absence claims are the dangerous ones:
`grep -n "GovernorPreventLateQuorum\|GovernorStorage\|_countVote\|COUNTING_MODE\|clock()\|CLOCK_MODE"`
over `src/CoinDAOGovernor.sol` → **no matches.** The contract adds no late-quorum
extension, no counting override, and no clock override. The clock therefore comes from
`GovernorVotes.clock()` → `token.clock()`, confirmed by execution to be block-number mode.

---

### FUNCTION: `GovToken.initialize` — L20–27

```
Visibility: external initializer
Guards: initializer; initialHolder != address(0)
State writes: _name, _symbol, EIP-712 name, _balances[initialHolder], _totalSupply
```

**L21 `if (initialHolder == address(0)) revert ZeroAddress();`**
- Q1.1 WHY: `_mint` to address(0) reverts anyway in OZ v5 (`ERC20InvalidReceiver`), so this
  line buys a *typed* error rather than a behaviour change.
- Q1.2 DELETE: nothing breaks except the error selector. Q1.4 SUFFICIENT: it does not check
  that `initialHolder` is the factory, which is what the whole allocation scheme depends on.
  Mitigated: the clone is created and initialised in one factory transaction (L364–367 of
  `CoinDAOFactory`), so no third party can win the race.
- **VERDICT: SOUND** (defence-in-depth, mitigated upstream).

**L23–25 the three `__X_init` calls, then L26 `_mint(initialHolder, GOV_TOKEN_SUPPLY)`**
- Q2.1 ORDER: could `_mint` run before `__ERC20Votes_init`? `__ERC20Votes_init` is an empty
  `onlyInitializing` no-op in OZ v5, so moving it would not change state — but moving
  `_mint` above `__ERC20_init` would emit a `Transfer` before name/symbol exist, which
  indexers would mis-label. Current order is correct.
- Q2.4 ABORT HALFWAY: `initializer` sets `_initialized` before the body, so a revert reverts
  the whole call and the clone stays uninitialised and re-initialisable — but only by the
  factory, in the same reverted transaction. No dirty state survives.
- Q4.6 AMOUNTS: `10_000_000e18 = 1e25 < type(uint208).max`, so `ERC20Votes._maxSupply()` is
  not breached. Checked explicitly because ERC20Votes reverts on supply over 2^208−1.
- **VERDICT: SOUND.**

**L15 `contract GovToken is ERC20Upgradeable, ERC20PermitUpgradeable, ERC20VotesUpgradeable`**
- Q1.1 WHY is `ERC20Votes` here? **CANNOT EXPLAIN.** The Governor's votes token is stGOV
  (`IVotes(address(staker))`, `CoinDAOFactory` L419). Grep over `src/` for `IVotes`
  produced four hits, none of them `GovToken`. So `GovToken`'s delegation checkpoints are
  written on every transfer and read by nothing.
- Verified by execution (`testDelegatingTheGovTokenItselfConfersNoVotingPower`): a holder of
  500,000 GOV who calls `gov.delegate(self)` gets `gov.getVotes == 500_000e18` and
  `governor.getVotes(...) == 0`.
- **VERDICT: SUSPECT** → FF-009 (LOW; a user-facing footgun plus dead gas on every transfer).

**L29–34 `_update`, L36–38 `nonces`** — required multiple-inheritance disambiguation,
behaviour-identical to `super`. Q1.2 DELETE → compile error. **VERDICT: SOUND.**

**L16–18 `constructor() { _disableInitializers(); }`** — protects the implementation from
being initialised by a third party. Q1.2 DELETE: for a *clone*-based system the impact is
cosmetic (clones have their own storage), but the line is correct and free.
**VERDICT: SOUND.**

---

### FUNCTION: `CoinDAOVestingWallet` — the whole file, L1–10

This is the file where the brief's question — *what does the base permit that the wrapper
does not constrain?* — is the entire audit.

**L6 `contract CoinDAOVestingWallet is VestingWalletUpgradeable {`**

`VestingWalletUpgradeable` is `Initializable + ContextUpgradeable + OwnableUpgradeable`.
The beneficiary **is** the owner. Every `Ownable` power therefore belongs to the
beneficiary, and the wrapper overrides none of them.

- Q1.2 / Q3.1 **`renounceOwnership()` is inherited and unconstrained.** The beneficiary can
  set `_owner = address(0)`. `release(token)` then calls
  `SafeERC20.safeTransfer(token, owner(), amount)` → `ERC20InvalidReceiver(address(0))` →
  revert. The allocation is stranded permanently, with no admin anywhere able to recover it.
  **Proven by execution** (`testVestingBeneficiaryCanRenounceAndPermanentlyBrickAllocation`):
  200,000 GOV stranded, `releasable > 0`, `release` reverts.
- Q3.1 **`transferOwnership(addr)` is inherited and unconstrained.** The beneficiary can sell
  or assign the remaining four-year stream in one transaction — including the *platform's*
  2 % wallet and the treasury wallet (whose owner is the Timelock, so a single captured
  proposal moves it). **Proven** (`testVestingBeneficiaryCanSellTheEntireStream`): the whole
  200,000 GOV allocation was redirected to a third party.
- Q1.1 **no cliff.** `VestingWallet._vestingSchedule` is linear from `start`. The factory sets
  `vestingStart = block.timestamp` (L457) and `duration = FOUR_YEARS`. **Proven**
  (`testFourYearVestHasNoCliff`): of a 2,000,000 GOV deployer allocation,
  `releasable` is non-zero **one second** after launch, 1,369 GOV after one day and
  41,095 GOV after 30 days. Whether a cliff was intended is a design question — but the
  file is named `CoinDAOVestingWallet` and adds nothing, so the absence of a cliff is an
  absence, not a decision recorded anywhere in the tree.
- Q4.2 **balance-based accounting.** `vestedAmount` uses
  `balanceOf(this) + released(token)`, so any token sent *after* the start vests at the
  already-elapsed fraction. **Proven** (`testLateDepositIsImmediatelyReleasableAtElapsed
  Fraction`): a 1,000,000 GOV top-up made one day before the schedule ends is
  999,315 GOV immediately releasable. Any "top up the treasury vest" operation late in
  the schedule is effectively an instant transfer to the owner.
- Q4.3 **no zero-beneficiary or minimum-duration guard on `initialize`.** The wrapper adds
  neither. Mitigated for the two mandatory wallets (the factory passes `deployment.timelock`
  and `monolithBeneficiary`, both non-zero by construction) and for the deployer wallet
  (`_validate` requires a recipient when the stake is non-zero). Not mitigated in the
  wrapper itself.
- Q5.5 the base's `receive() external payable` accepts ETH that nothing in this system ever
  sends. Harmless; noted for completeness.

**L7–9 `constructor() { _disableInitializers(); }`** — the wrapper's only added line.
Q1.1 WHY: the script `DeployCoinDAOFactory.s.sol` L40 deploys this contract directly as an
implementation; without the line, anyone could initialise that implementation. Q1.2 DELETE:
clones are unaffected, so the impact is cosmetic — but the line is correct.
**VERDICT: SOUND.**

**FILE VERDICT: HAS_CONCERNS** → FF-003 (renounce), FF-005 (transfer/no-cliff/late-deposit).

---

### FILE: `src/interfaces/IMonolith.sol` — L1–39

**L5–24 `struct DeployParams`** — 18 fields, hand-transcribed from a protocol whose source
is not in this tree.
- Q4.2 ASSUMES: that this struct matches the deployed Monolith factory field-for-field.
  Q6.x: a *type* or *arity* mismatch changes the function selector and reverts loudly —
  that failure mode is safe. A **semantic** mismatch does not: `operator` and `manager` are
  adjacent `address` fields, and `targetFreeDebtRatioStartBps` / `targetFreeDebtRatioEndBps`
  are adjacent `uint16` fields. Swapping either pair produces an identical selector and a
  silently mis-parameterised market.
- Q1.4: nothing anywhere in the tree pins this interface to a source revision — no NatSpec,
  no commit hash, no address comment. The only on-chain check on the Monolith factory is
  `MONOLITH_FACTORY.code.length != 0` (script L199, L21).
- **VERDICT: SUSPECT** → FF-010 (LOW; a process/verification gap, not a demonstrable bug).

**L30–39 `interface IMonolithLender`**
- Q3.3 CONSISTENCY: `setManager(address)` is declared but the matching getter `manager()`
  is **not**. `DeployCoinDAO.s.sol` L266 needs the getter and works around its absence with
  an untyped `staticcall(abi.encodeWithSignature("manager()"))`, guarded only by
  `success && result.length == 32`. A lender with a permissive fallback returning 32 bytes
  would satisfy that guard. Verified that `abi.decode(..., (address))` does validate the top
  96 bits in Solidity ≥0.8, so a dirty word reverts — the residual risk is a *clean* wrong
  word, not a malformed one.
- Q1.1: `pullLocalReserves()` is declared here but is called only from `RevenueRouter`;
  in scope it is unused. Not a defect.
- **VERDICT: SUSPECT** → FF-010.

---

### FUNCTION: `DeployCoinDAOScript.run` — L44–77

**L45 `require(block.chainid == SEPOLIA_CHAIN_ID, "Sepolia only");`**
- Q1.1 WHY: the WETH, feed, Monolith-factory addresses and the token names
  (`"Monolith Sepolia USD"`) are Sepolia literals.
- Q1.4 CONSEQUENCE: **there is no mainnet or L2 launch script in the tree.** `ls script/`
  returns exactly two files, both chainid-gated to 11155111. The brief describes this as
  "the deployment tooling that will be used to launch on a real chain"; as written it
  cannot be. **VERDICT: SUSPECT** → FF-013 (LOW/informational, but load-bearing for the
  engagement: nothing here has been exercised against production parameters).

**L47 `uint256 privateKey = vm.envUint("PRIVATE_KEY");` / L52 `vm.addr(privateKey)` /
L70 `vm.startBroadcast(privateKey)`**
- Q4.1 ASSUMES: a raw private key in the process environment. Foundry supports
  `--account` / keystore / hardware signers; this script forecloses all of them because
  `deployer` is derived from the key and is then used as the Lender's permanent `manager`.
  **VERDICT: SUSPECT** → FF-014 (LOW, operational).

**L54 `_preflight(factory);` vs L57 `monolithParamsFromEnv();`**
- Q2.1 **ORDER — what if L54 ran after L57?** `_preflight` reads
  `vm.envOr("STALENESS_THRESHOLD", ...)` at L217 and uses it as the bound for the oracle
  freshness check — but `STALENESS_THRESHOLD` is only *validated* at L172, inside
  `buildMonolithParams`, which is not called until L57. So the preflight applies an
  **unvalidated** parameter, read a second time from the environment. Two independent reads
  of the same env var, in two different functions, with the validation attached to the later
  one. Moving `_preflight` below L57 and passing the validated value would remove the
  hazard entirely.
- **VERDICT: SUSPECT** → FF-008.

**L59–61 `predictCoinDAOAddresses(deployer, userSalt, govParams)` / `deploymentsLength()`**
- Q2.5 ORDER / front-running: the deployment key is `keccak256(abi.encode(msg.sender, salt))`
  and `msg.sender == deployer` under the broadcast, so no third party can steal the key.
  Confirmed by the tree's own `testSameSaltIsNamespacedByCreator`. **SOUND.**
- Q7.6: `deploymentId` is snapshotted pre-deploy and re-checked at L237 with a strict
  equality. Under a concurrent launch the equality fails — but inside the *simulation*, so
  the run aborts before broadcast. Correct behaviour; noted only because the same equality
  makes the check useless as a post-inclusion assertion.

**L71 `deployment = factory.deploy(userSalt, govParams, monolithParams, deployer);`**
- Q1.1 WHY is the fourth argument `deployer`? It becomes the Lender's `manager`.
- Q4.1 ASSUMES: that a single EOA should hold a privileged role on the external market after
  launch. Mitigating code found on trace: `RevenueRouter.setManager` (L94–97) is `onlyOwner`
  and the router's owner is the Timelock (factory L454), so **governance can reclaim the
  manager role**. That downgrades what looked like a permanent EOA privilege to a shared
  one. Recorded as a mitigation, not a finding — but note that reclaiming it requires a
  proposal, and proposals are cheap to pass (FF-001).
- Q2.2: `predicted.timelock` is known at L60, i.e. *before* L71. The script could have
  handed the manager role straight to the DAO and chose not to. **CANNOT EXPLAIN** the
  choice from anything in the tree. Recorded as an open question for the debrief rather
  than a finding.

**L74–76** — verification and logging. Interrogated below.

---

### FUNCTION: `DeployCoinDAOScript.buildGovParams` — L91–115

**L96 `require(deployerStakeBps <= 2_000, "Deployer stake exceeds 20%");`** — mirrors
`CoinDAOFactory.MAX_DEPLOYER_STAKE_BPS`. Q3.3: consistent with the on-chain check.
**SOUND** (duplicated, but the duplicate fails first with a clearer message).

**L97 `require(deployerStakeBps == 0 || deployerRecipient != address(0), "Deployer recipient required");`**
- Q1.1 WHY: prevents a vesting allocation with nowhere to send it.
- Q3.2 **INVERSE PARITY — is the converse checked?** No. `(bps = 0, recipient != 0)` is
  accepted. And that shape is not neutral: `CoinDAOFactory` L491–492 routes the *immediate*
  allocation to `deployerRecipient` whenever it is set, and only to the Timelock when it is
  zero. So the accepted shape pays **500,000 GOV — 5 % of the entire fixed supply — liquid,
  unvested, on day one** to whatever address `DEPLOYER_RECIPIENT` names, and creates no
  vesting wallet at all.
  **Proven by execution** (`testGovParamsAcceptRecipientWithZeroStakeAndPayFivePercent
  Liquid`): `deployerVesting == address(0)`, `balanceOf(recipient) == 500_000e18`,
  `balanceOf(timelock) == 0`.
- The factory carries a comment at L490 ("A missing deployer recipient sends only the liquid
  allocation to the timelock; vested deployer stake is disallowed"), so the *destination*
  is deliberate. What is not addressed anywhere is that the guard is one-directional and
  that the script neither warns nor verifies. Per the working rule on reading the comment
  before judging the line: the comment explains where the money goes, and my finding is
  about the missing symmetric guard and the missing verification, not about the routing.
- **VERDICT: SUSPECT** → FF-002.

**L100–106 the `keccak256(bytes(stakingToken))` comparison chain** — Q4.2: exact-match,
case-sensitive, with an explicit `revert` on anything else. `"coin"` and `"sCoin"` both
revert (`testStakingTokenChoiceIsCaseSensitiveAndReverts`). This is the **only** env var in
the script that fails loudly on a typo; the other eleven use `vm.envOr` and silently fall
back to a default. Q3.3 asymmetry noted; the loud one is the correct pattern.
**VERDICT: SOUND** (and the model the others should follow).

---

### FUNCTION: `DeployCoinDAOScript.buildMonolithParams` — L155–196

Eight `require`s, interrogated one at a time against Q1.4 ("is this check sufficient") and
Q3.3 ("same parameter class, different rigour").

| line | check | lower bound | upper bound | verdict |
|---|---|---|---|---|
| 166 | `collateralFactor <= 8_500` | **none** — 0 accepted | 85 % | SUSPECT: `0` builds a market nobody can borrow from |
| 167 | `timeUntilImmutability <= 1_460 days` | **none** — 0 accepted | 4 y | SUSPECT: `0` freezes the market's parameters at birth |
| 168 | `halfLife >= 12 hours && <= 30 days` | 12 h | 30 d | SOUND |
| 169 | `targetStart >= 500 && targetStart <= targetEnd` | 5 % | ordered | SOUND |
| 170 | `targetEnd <= 9_500` | via L169 | 95 % | SOUND |
| 171 | `redeemFeeBps <= 500` | none (0 = free) | 5 % | SOUND (0 is a plausible policy) |
| 172 | `stalenessThreshold != 0 && <= type(uint32).max` | 1 s | **~136 years** | **VULNERABLE** |
| 173 | `maxBorrowDeltaBps >= 50 && <= 200` | 0.5 % | 2 % | SOUND |
| 174 | `halfLife <= type(uint64).max` | — | — | **DEAD** |
| — | `minDebt` | **no check at all** | **no check at all** | SUSPECT |

**L172 `require(stalenessThreshold != 0 && stalenessThreshold <= type(uint32).max, ...)`**
- Q1.1 WHY: to bound the oracle-freshness tolerance the market will enforce.
- Q1.4 **SUFFICIENT?** No. `type(uint32).max` seconds is 136 years. Every *other* numeric
  parameter in this function carries a tight, domain-meaningful bound; this one carries
  only the type's own limit, which is not a bound at all. A launch with
  `STALENESS_THRESHOLD=4294967295` produces a lending market that accepts a price of any
  age. **Proven** (`testMonolithParamsAcceptAbsurdOracleStalenessAndDebtFloor`).
- Q1.4 on the *other* consumer: `_preflight` L218 uses the same value as
  `require(block.timestamp - updatedAt <= stalenessThreshold)`. **That check can only ever
  catch a threshold that is too SMALL** — a huge threshold makes it vacuously true. So the
  one runtime check that touches this parameter is structurally incapable of catching the
  dangerous direction. That is a green check with no resolution in the direction that
  matters.
- **VERDICT: VULNERABLE** → FF-008.

**`minDebt` — no `require` anywhere**
- Q3.3: every sibling parameter is validated; this one is not, and it is the one with the
  widest legal range (`uint256`). `0` permits dust positions; `type(uint256).max` permits a
  market nobody can borrow from. Both build cleanly
  (`testMonolithParamsAcceptAbsurdOracleStalenessAndDebtFloor`).
- **VERDICT: SUSPECT** → FF-008.

**L174 `require(halfLife <= type(uint64).max, "Half life overflow");`**
- Q1.2 **DELETE IT — what breaks?** Nothing. L168 already caps `halfLife` at
  `30 days == 2_592_000`, which is 12 orders of magnitude below `type(uint64).max`. No input
  can reach L174 without failing L168 first. **Proven** — feeding
  `type(uint64).max + 1` reverts with `"Invalid half life"`, never `"Half life overflow"`
  (`testHalfLifeOverflowGuardIsUnreachable`).
- **VERDICT: SUSPECT — dead code.** Reported as LOW because unreachable defensive code
  reads as protection that is not there.

**L180–181 `psmAsset: address(0), psmVault: address(0)` with L194 `psmVaultMinTotalSupply: 1`**
- Q1.1 WHY is the minimum supply `1` for a vault that is `address(0)`? **CANNOT EXPLAIN.**
  Either the PSM is disabled (in which case `0` is the honest value) or it is not (in which
  case the two zero addresses are wrong). Nothing in the tree resolves it.
- **VERDICT: SUSPECT** → FF-015 (LOW; a contradiction the script asserts nothing about).

**L186–187 `operator: address(0), manager: address(0)`**
- Q4.3 ASSUMES: that `CoinDAOFactory.deploy` overwrites both (it does, L304–305).
  `buildMonolithParams` is `public` and returns a struct that is only safe because of that
  overwrite. Documented here as a coupling for Pass 2; not a finding on its own.

---

### FUNCTION: `DeployCoinDAOScript._preflightImplementations` — L221–228

**L222–227 — six `require(x.code.length != 0)`**
- Q1.2 **DELETE THEM — what breaks?** Nothing, ever.
- Q1.4 **CAN THIS CHECK FAIL?** `CoinDAOFactory`'s constructor already calls
  `_validateImplementations`, which reverts unless all six have code (factory L546–548).
  Code cannot subsequently be removed: post-Cancun `SELFDESTRUCT` only deletes code in the
  same transaction as creation. Therefore **no `CoinDAOFactory` that exists can fail this
  check.** It is a green light that is soldered on.
- Q1.4 WHAT IT WAS PRESUMABLY MEANT TO DO: reassure the launcher that the
  `COIN_DAO_FACTORY` address from the environment is the real one. It cannot: the factory
  itself validates only `code.length != 0` and pairwise distinctness — never that an
  implementation is of the expected *type*. **Proven** by constructing a `CoinDAOFactory`
  whose six "implementations" are six unrelated `MockERC20`s and feeding it to the script's
  own preflight, which raises no objection
  (`testPreflightImplementationsPassesForSixUnrelatedContracts`).
- Compounding: `DeployCoinDAOFactory.s.sol` deploys the factory with plain `new` (nonce-
  based `CREATE`), so its address is not reproducible and cannot be pinned in the launch
  script as a constant the way `MONOLITH_FACTORY` is.
- **VERDICT: VULNERABLE** (as a control) → FF-007.

---

### FUNCTION: `DeployCoinDAOScript._verifyDeployment` — L230–263

Sixteen `require`s. Grouped by what they actually assert:

- L237–238: the launch was recorded (`deploymentsLength`, `hasCoinDAO`).
- L240–254: twelve `.code.length != 0` checks — i.e. "the factory did deploy twelve things".
- L256–258: `lender.operator() == revenueRouter` and `manager() == deployer`.
- L260–262: the staking token matches the requested choice.

Q1.4 **WHAT IS NOT ASSERTED?** Grepped explicitly for the negatives, because absence claims
are the dangerous ones:

```
$ grep -rn "balanceOf\|hasRole\|\.owner()\|PROPOSER_ROLE\|quorum\|votingDelay" script/
(no output)
```

So the launch tooling verifies **no token balance, no role assignment, no ownership, and no
governance parameter**. Specifically unverified:

| fact the whole design rests on | verified? |
|---|---|
| the Timelock granted `PROPOSER_ROLE` / `CANCELLER_ROLE` to the Governor | no |
| the factory renounced `DEFAULT_ADMIN_ROLE` on the Timelock | no |
| `EXECUTOR_ROLE` is open (`address(0)`) — deliberate, but unstated | no |
| `RevenueRouter.owner() == timelock` | no |
| the Governor's votes token is the staker and its timelock is the timelock | no |
| where the 10,000,000 GOV went (any of the five allocations) | no |
| each vesting wallet's owner, start and duration | no |
| `StakingRewards` ownership was renounced / the first tranche funded | no |
| the Governor's quorum, threshold, delay and period | no |

**Proven by execution:**
- `testVerifyDeploymentSignsOffOnAFivePercentGiveaway` — `_verifyDeployment` returns
  cleanly on a launch in which 500,000 GOV sits in an arbitrary EOA and the Timelock holds
  none.
- `testBeneficiaryRotationBetweenSimulationAndInclusionIsUnverified` — the factory's
  `monolithBeneficiary` is rotated (two-step, by the incumbent) between the launcher's
  simulation and inclusion; the 200,000 GOV platform wallet is created for the **new**
  beneficiary and `_verifyDeployment` still returns cleanly. Nothing in `_preflight`
  pins `factory.monolithBeneficiary()` either.
- `testVerifyDeploymentChecksNoRolesOwnersOrParameters` — the role facts happen to hold,
  but the script asks about none of them; `EXECUTOR_ROLE` is confirmed held by
  `address(0)`, i.e. anyone may execute a queued operation.

**VERDICT: VULNERABLE** (as a control) → FF-006.

---

### FUNCTION: `DeployCoinDAOScript._preflight` — L198–219

**L200 `require(address(factory.monolithFactory()) == MONOLITH_FACTORY);`** — pins the
external factory to a compile-time constant. Q1.4: this is the **right** pattern, and it is
exactly what is missing for `monolithBeneficiary` and for the implementation set.
**SOUND, and cited as the counter-example.**

**L205–210** — WETH decimals and symbol, feed decimals and `description() == "ETH / USD"`.
Q1.4: a genuinely resolving check (a wrong feed fails). **SOUND.**

**L212–215 `answer > 0`, `updatedAt != 0 && <= block.timestamp`, `answeredInRound >= roundId`**
- Q4.5 ASSUMES: a Chainlink-shaped feed. `answeredInRound` is deprecated but harmless.
- Q1.4: does not check that the feed's aggregator has not been swapped, and cannot — this
  is the sensible limit of a preflight. **SOUND.**

**L217–218** — the staleness bound, interrogated above. **VULNERABLE** → FF-008.

**Absence:** `_preflight` never calls a single read-only Monolith function (e.g.
`isDeployed(address(0))`) to sanity-check that the hand-written ABI in `IMonolith.sol`
matches the deployed contract. **SUSPECT** → FF-010.

---

### FUNCTION: `DeployCoinDAOFactoryScript.run` — L19–74

**L34–41** — six `new X()` implementations inside the broadcast, then L42 `new CoinDAOFactory`.
- Q1.1 WHY fresh implementations per factory: they are immutable on the factory, so a bug
  in any of the six is unfixable for every DAO that factory ever launches. Q1.2 DELETE: not
  applicable. The design consequence (no upgrade path, by choice) is correct to note but is
  not a defect in this file.
- Q4.3 ASSUMES: each of the six has `_disableInitializers()` in its constructor, otherwise
  the deployed implementation is a live, initialisable contract. **Verified by grep, not
  assumed** — all six hits present:
  `CoinDAOVestingWallet:8, GovToken:17, RevenueRouter:37, StakedGovToken:54,
  StakingRewards:43, StakingRewardsFunder:37`. **SOUND.**
- Q2.5: nonce-based `CREATE` means the factory address is not predictable or reproducible;
  a redeploy lands somewhere new and every downstream `COIN_DAO_FACTORY` env value must be
  updated by hand. Feeds FF-007.

**L45–65 — seven post-broadcast `require`s** comparing each getter to the value just passed
in. Q1.4: these are real (a constructor that dropped an argument would be caught), but they
compare the factory against **this script's own inputs**, not against any independent
expectation. Combined with L24's `vm.envAddress("MONOLITH_BENEFICIARY")`, the strongest
statement the script can make is "the beneficiary is whatever the environment said".
**SOUND but weak.**

**L20 `require(block.chainid == SEPOLIA_CHAIN_ID)`** — same testnet gate. → FF-013.

---

## PHASE 3 — CROSS-FUNCTION ANALYSIS

### 3.1 Guard consistency

Grouping by the state each function writes:

| state group | writers | guards | flag |
|---|---|---|---|
| `_quorumNumeratorHistory` | constructor, `updateQuorumNumerator` | none / `onlyGovernance` | consistent |
| `_votingDelay/_votingPeriod/_proposalThreshold` | constructor, three setters | none / `onlyGovernance` | consistent |
| `_timelockIds[id]` | `_queueOperations`, `_cancel` | state machine / proposer+Pending | **asymmetric — FF-004** |
| `_owner` (vesting) | `initialize`, `transferOwnership`, `renounceOwnership` | `initializer` / `onlyOwner` / `onlyOwner` | consistent *within* Ownable, but the wrapper constrains none of the three — **FF-003, FF-005** |
| `_erc20Released[token]` | `release(token)` | **none — permissionless** | intended (it pays `owner()`); sound |
| script-side "validate" | `buildGovParams`, `buildMonolithParams` | 2 + 8 requires | **FF-002, FF-008** |
| script-side "verify" | `_preflight`, `_preflightImplementations`, `_verifyDeployment` | 11 + 6 + 16 requires | **FF-006, FF-007** |

The single most important guard asymmetry: **`queue()` and `execute()` carry no role gate at
all** (the Timelock's `EXECUTOR_ROLE` is `address(0)`), while `cancel()` carries two
(proposer identity **and** `ProposalState.Pending`). The cheap operation is the destructive
one; the expensive guard is on the defensive one.

### 3.2 Inverse-operation parity

| pair | validation parity | state parity | access parity | events |
|---|---|---|---|---|
| `propose` / `cancel` | propose: votes ≥ threshold. cancel: proposer **and** Pending-only | not inverse — cancel cannot undo a Queued proposal | asymmetric | both |
| `queue` / `cancel` | queue: anyone, state Succeeded. cancel: unreachable once Queued | **no inverse exists** | **FF-004** | both |
| `transferOwnership` / `renounceOwnership` | neither constrained by the wrapper | renounce is irreversible and bricks `release` | equal | both |
| `buildGovParams` guard | `bps != 0 ⇒ recipient != 0` enforced; `recipient != 0 ⇒ bps != 0` **not** enforced | — | — | **FF-002** |
| `predictCoinDAOAddresses` / `deploy` | prediction takes `creator`; deploy uses `msg.sender` — equal under broadcast | — | — | sound |
| `_preflight` / `_verifyDeployment` | preflight validates the *inputs*; verify validates the *shape*. **Neither validates the outcome.** | — | — | **FF-006** |

### 3.3 State-transition integrity (proposal lifecycle)

```
Pending --(7200 blocks)--> Active --(36000 blocks)--> Succeeded --queue--> Queued
   |                                                                          |
 cancel (proposer only)                                          (2 days) --execute--> Executed
   |                                                                          |
   +--> Canceled                                              ARBITRARY EXTERNAL CALL
```

- **Can a transition be triggered out of order?** No — OZ's `_validateStateBitmap` is intact
  and no override bypasses it.
- **Can a transition be skipped?** `proposalNeedsQueuing` returns constant `true`, so the
  Timelock cannot be bypassed. Confirmed by reading the `super` chain.
- **Can a transition be triggered by an unauthorised actor?** `queue` and `execute` — yes,
  by anyone, by design. Proven: a bystander executed the capture in
  `testQueuedMaliciousProposalCannotBeCancelledByAnyone`.
- **Is there an exit from `Queued` other than `Executed`?** **No.** `Governor.cancel` is
  `Pending`-only; `TimelockController.cancel` requires `CANCELLER_ROLE`, held solely by the
  Governor; the Governor's only route to `timelock.cancel` is `relay`, which is
  `onlyGovernance` and therefore needs a *second* proposal taking ~8 days — four times the
  2-day window. **The `CANCELLER_ROLE` granted at `CoinDAOFactory` L429 has no reachable
  emergency use.** Proven end-to-end. → FF-004.

### 3.4 Value-flow tracking

Conservation of the fixed 10,000,000 GOV at launch (`deployerStakeBps = 0`,
`deployerRecipient` set), measured by execution:

```
monolithVesting          200,000  (2 %)   owner = monolithBeneficiary (EOA, rotatable, renounceable)
coinStakingRewardsFunder 6,500,000 (65 %) streamed over four tranches
immediateRecipient         500,000  (5 %) LIQUID, UNVESTED, day one   <-- FF-002
treasuryVesting          2,800,000 (28 %) owner = Timelock            <-- reachable by FF-001
deployerVesting                  0
                        ----------
                        10,000,000        conserved
```

Two observations that matter for Pass 2:

1. **Only the 500,000 GOV immediate allocation is liquid at launch.** The 6,500,000 staking
   allocation enters circulation gradually and the remaining 3,000,000 is locked in vesting
   wallets that cannot stake (a `VestingWallet` has no arbitrary-call capability). So in the
   opening weeks the entire float that can become voting power is ~500,000 GOV — while the
   proposal threshold is 10,000 GOV (2 % of that float) and quorum is 0.1 % of whatever
   fraction of it is staked.
2. **Value can leave via a path that creates no vesting wallet at all** (FF-002), and the
   launch tooling reports that launch as verified (FF-006).

---

## PHASE 4 / PHASE 5 — FINDINGS, WITH VERIFICATION

Every C/H/M finding below carries a PoC. Verification verdicts follow Phase 5's rules;
one finding was **materially reframed by its own mutation test** and is reported in its
corrected form.

### Verification summary

| ID | Raw severity | Verdict | Final | Method |
|---|---|---|---|---|
| FF-001 | CRITICAL | TRUE POSITIVE — mechanism corrected, severity held | **HIGH** | PoC + 3 mutations |
| FF-002 | HIGH | TRUE POSITIVE — DOWNGRADE (intended destination, missing guard) | **MEDIUM** | PoC |
| FF-003 | MEDIUM | TRUE POSITIVE | **MEDIUM** | PoC |
| FF-004 | MEDIUM | TRUE POSITIVE | **MEDIUM** | PoC |
| FF-005 | MEDIUM | TRUE POSITIVE | **MEDIUM** | PoC |
| FF-006 | MEDIUM | TRUE POSITIVE | **MEDIUM** | PoC + explicit negative grep |
| FF-007 | MEDIUM | TRUE POSITIVE | **MEDIUM** | PoC |
| FF-008 | MEDIUM | TRUE POSITIVE | **MEDIUM** | PoC |
| FF-009 | LOW | TRUE POSITIVE | **LOW** | PoC |
| FF-010 | LOW | TRUE POSITIVE (process) | **LOW** | inspection + grep |
| FF-011 | LOW | TRUE POSITIVE | **LOW** | PoC |
| FF-012 | LOW | TRUE POSITIVE | **LOW** | PoC |
| FF-013 | LOW | TRUE POSITIVE | **LOW** | inspection |
| FF-014 | LOW | TRUE POSITIVE | **LOW** | inspection |
| FF-015 | LOW | TRUE POSITIVE | **LOW** | inspection |
| — | — | one hypothesis **REFUTED**, see "Refuted" below | — | code trace |

---

### FF-001 — Quorum is a fraction of the *staked* supply, so a lone staker is always the entire electorate; no parameter value can fix it

**Severity: HIGH** (raw: CRITICAL — held at HIGH because success still requires that no
larger opposing stake shows up to vote, which is a real if weak condition)
**Module:** `CoinDAOGovernor`
**Lines:** `src/CoinDAOGovernor.sol` L34–35, L64–70; parameters at `CoinDAOFactory.sol` L33–34
**Verification:** Hybrid — PoC + three mutation runs
**State touched (for Pass 2):** `StakedGovToken._totalCheckpoints`,
`StakedGovToken._delegateCheckpoints`, `Governor._quorumNumeratorHistory`,
`GovernorSettings._proposalThreshold`, `GovernorCountingSimple._proposalVotes`

**Feynman question that exposed it:**
> Q1.4 — *Is this check SUFFICIENT for what it is trying to prevent?*
> and Q1.2 — *What happens if I delete this line entirely?*

**The code:**
```solidity
// CoinDAOGovernor.sol
    function quorum(uint256 timepoint) public view override(Governor, GovernorVotesQuorumFraction) returns (uint256) {
        return super.quorum(timepoint);            // = stGOV.getPastTotalSupply(t) * numerator / denominator
    }

    function quorumDenominator() public pure override returns (uint256) {
        return 1_000;                              // OZ default is 100
    }

// CoinDAOFactory.sol
    uint256 public constant GOVERNOR_PROPOSAL_THRESHOLD = GOV_TOKEN_SUPPLY / 1_000;  // 10,000 GOV
    uint256 public constant GOVERNOR_QUORUM_NUMERATOR   = 1;                          // 0.1 %
```

**Why this is wrong — from first principles.**

A quorum exists to answer one question: *did enough of the electorate show up?* That only
works if "the electorate" is measured against something an attacker cannot shrink. Here it
is measured against `stGOV.getPastTotalSupply()` — the amount of GOV that happens to be
staked at the snapshot. But staking is what *creates* voting power. So the denominator of
the participation test is the set of participants, and a lone participant is, tautologically,
100 % of it.

Two separate consequences, and I verified them independently because they have different
fixes:

1. **The arithmetic consequence.** `quorum(t) = stakedSupply(t) / 1000`, and the wrapper is
   1:1 over a fixed 10,000,000 GOV supply, so `stakedSupply <= 10_000_000e18` always, so
   `quorum(t) <= 10_000e18` always — which is *exactly* `GOVERNOR_PROPOSAL_THRESHOLD`. The
   quorum can therefore never exceed the bar a proposer has already cleared. Executed at
   the theoretical maximum (100 % of GOV staked): quorum **equals** the threshold, to the wei.

2. **The structural consequence — this is the part the mutation testing corrected.** My
   first hypothesis was that the `quorumDenominator` override from 100 to 1000 was the root
   cause. **It is not.** I mutated the denominator back to the OZ default of 100 and re-ran
   the capture PoC: it still succeeded (quorum rose from 10 GOV to 100 GOV; the attacker had
   10,000). I then mutated `GOVERNOR_QUORUM_NUMERATOR` to its **maximum legal value, 1000 —
   a 100 % quorum — and the capture still succeeded**, because 100 % of a staked supply that
   consists solely of the attacker's own stake is the attacker's own stake, and
   `GovernorCountingSimple._quorumReached` tests `forVotes + abstainVotes >= quorum`.
   **No governance-reachable parameter setting makes this quorum bind against a lone
   staker.** The denominator override is real and it matters (it moves the point at which
   quorum could bind from "10 % of supply staked" to "never"), but it is an aggravating
   factor, not the cause. The cause is the choice of quorum base.

**Verification evidence:**

```
test/audit/FeynmanGovernance.t.sol
[PASS] testQuorumCanNeverExceedProposalThreshold
  proposalThreshold          : 10000000000000000000000
  quorum at 100% staked (MAX): 10000000000000000000000     <- equal, at the maximum
  quorum if denominator were 100: 100000000000000000000000

[PASS] testSingleTenthOfAPercentHolderCapturesTreasury
  quorum at snapshot           : 10000000000000000000       (10 GOV)
  attacker votes               : 10000000000000000000000    (10,000 GOV)
  attacker GOV after 1y release: 703835616438356164383561   (703,835 GOV)

MUTATION 1 — quorumDenominator() 1_000 -> 100 (OZ default):
  quorum at snapshot 100 GOV; capture still succeeds.
MUTATION 2 — GOVERNOR_QUORUM_NUMERATOR 1 -> 1_000 (a 100% quorum):
  quorum at snapshot 10,000 GOV == attacker stake; `>=` is satisfied; capture still succeeds.
MUTATION 3 — sources restored; `diff -q` against [scratch] clean; full suite 76/76.
```

**Attack scenario (executed end to end):**
1. A CoinDAO launches. Only the 500,000 GOV immediate allocation is liquid; the Timelock
   holds the 2,800,000 GOV treasury vesting wallet and owns the `RevenueRouter`.
2. The attacker buys **10,000 GOV — 0.1 % of total supply** — on the open market.
3. Wrap into stGOV, self-delegate, wait one block.
4. `propose([treasuryVesting], [0], [transferOwnership(attacker)], "Routine treasury administration")`.
5. Wait 7,200 blocks (~24 h) to the snapshot, cast one For vote. Quorum at the snapshot is
   **10 GOV**; the attacker supplies 10,000. `forVotes > againstVotes` holds unopposed.
6. Wait 36,000 blocks (~5 days), `queue()`, wait the 2-day timelock delay, `execute()` —
   `execute` is open to any address.
7. The attacker owns the treasury vesting wallet. After one further year they released
   **703,835 GOV** in the PoC and retain the remaining ~2.1 M stream, plus (via the same
   route) `RevenueRouter.setGovStakingBps`, `RevenueRouter.setManager`, and every other
   Timelock power.
8. One further proposal removes the remaining safeguards permanently — verified:
   `updateQuorumNumerator(0)`, `setProposalThreshold(0)`, `setVotingDelay(1)` all execute
   (`testCapturedGovernorCanZeroQuorumDelayPeriodAndThreshold`).

**Impact:** ~70× return on the attacker's stake in the first year, permanent control of the
DAO's governance, treasury and revenue split. The only thing standing in the way is a larger
opposing stake voting Against within the 5-day window — which the project's own test helper
`_passAndQueueQuorumProposal` (test/CoinDAOGovernor.t.sol L119–146) already demonstrates is
not required: it passes and queues proposals with a single voter holding exactly the
threshold.

**Suggested fix — as a hypothesis, with both failure modes priced:**

The natural fix is to measure quorum against the *total GOV supply* rather than the staked
supply, e.g. by overriding `quorum(uint256)` to return
`GOV_TOKEN_SUPPLY * quorumNumerator(t) / quorumDenominator()`, and to set the numerator well
above the proposal threshold's 1/1000 (say 40/1000 = 4 %).

- **The failure it prevents:** minority capture. A 4 %-of-supply quorum requires 400,000 GOV
  of For+Abstain — 80 % of the entire launch-day float — which a 10,000 GOV attacker cannot
  reach alone.
- **The failure it creates, which must be priced:** *governance deadlock.* At launch only
  ~500,000 GOV is liquid and staking is voluntary; a 4 % absolute quorum may be unreachable
  for months, during which **no proposal can pass at all** — including the proposal that
  would lower the quorum. That is a permanent-DoS risk with the same blast radius as the
  capture it prevents. Any absolute quorum therefore needs either a bootstrap period, a
  time-decaying quorum, or a guardian able to act while quorum is unreachable. I do not
  recommend a specific number without a circulating-supply model; the recommendation is the
  *base*, not the value.

A second, independent mitigation that does not carry the deadlock risk: give someone the
ability to cancel a queued proposal (FF-004). Capture then requires beating a live defender
rather than an empty room.

---

### FF-002 — `buildGovParams` validates one direction only; the accepted reverse shape pays 5 % of supply liquid on day one

**Severity: MEDIUM** (raw HIGH, downgraded: the *destination* is deliberate per the factory
comment at L490; the defect is the missing symmetric guard plus the absent verification)
**Module:** `DeployCoinDAOScript`
**Lines:** `script/DeployCoinDAO.s.sol` L96–97 (with `CoinDAOFactory.sol` L490–493)
**Verification:** PoC — `testGovParamsAcceptRecipientWithZeroStakeAndPayFivePercentLiquid`
**State touched (Pass 2):** `GovToken._balances[deployerRecipient]`,
`GovToken._balances[timelock]`, `CoinDAOFactory.deployments[id].deployerVesting`

**Feynman question:**
> Q3.2 — *If functionA validates parameter P, does the inverse relationship get validated too?*

**The code:**
```solidity
        require(deployerStakeBps <= 2_000, "Deployer stake exceeds 20%");
        require(deployerStakeBps == 0 || deployerRecipient != address(0), "Deployer recipient required");
```
```solidity
        // CoinDAOFactory L490-493
        // A missing deployer recipient sends only the liquid allocation to the timelock; vested deployer stake is disallowed.
        address immediateRecipient =
            govParams.deployerRecipient == address(0) ? deployment.timelock : govParams.deployerRecipient;
        govTokenErc20.safeTransfer(immediateRecipient, allocation.immediateAllocation);
```

**Why this is wrong:** the guard reads "a stake needs a recipient". The unguarded converse
is "a recipient needs a stake" — and `DEPLOYER_RECIPIENT` is an environment variable that
defaults to `address(0)` while `DEPLOYER_STAKE_BPS` defaults to `0`. Setting the first
without the second is a one-line difference in a `.env` file that moves 500,000 GOV — 5 % of
the entire fixed supply, **50× the proposal threshold** — into a liquid, unvested EOA, and
creates no vesting wallet at all (`deployerVesting == address(0)`). The factory's comment
documents where the money goes; nothing documents that the amount is unrelated to the
"deployer stake" the operator thinks they are setting, and nothing verifies the result
(FF-006).

**Verification evidence:**
```
[PASS] testGovParamsAcceptRecipientWithZeroStakeAndPayFivePercentLiquid
  liquid GOV to DEPLOYER_RECIPIENT: 500000000000000000000000
  deployerVesting == address(0); balanceOf(timelock) == 0
  buildGovParams(100, address(0), "COIN") correctly reverts "Deployer recipient required"
```

**Impact:** 5 % of supply leaves the DAO liquid at launch through a shape the tooling
accepts silently, and that holder can immediately execute FF-001 fifty times over.

**Suggested fix (hypothesis, both directions priced):** add the symmetric guard
`require(deployerRecipient == address(0) || deployerStakeBps != 0, "Deployer stake required")`
**and** log the immediate allocation's destination and amount before broadcasting.
- Prevents: an unintended 5 % giveaway from a `.env` typo.
- Creates: it forecloses the legitimate configuration "pay the launcher the liquid slice
  without a vesting stream", if that is intended. If it is, the fix belongs in the logging
  and verification instead of the guard — which is why FF-006 is the more robust remedy.

---

### FF-003 — The vesting wrapper leaves `renounceOwnership()` reachable; the beneficiary can strand the allocation permanently

**Severity: MEDIUM**
**Module:** `CoinDAOVestingWallet`
**Lines:** `src/CoinDAOVestingWallet.sol` L6–9 (the whole file — by omission)
**Verification:** PoC — `testVestingBeneficiaryCanRenounceAndPermanentlyBrickAllocation`
**State touched (Pass 2):** `OwnableUpgradeable._owner`, `VestingWallet._erc20Released[GOV]`,
`GovToken._balances[vestingWallet]`

**Feynman question:**
> Q1.2/Q3.1 — *What does the base contract permit that the wrapper does not constrain?*

**Why this is wrong:** in OZ's `VestingWallet` the beneficiary **is** the `Ownable` owner, so
the beneficiary inherits `renounceOwnership()`. Setting `_owner = address(0)` does not pause
the wallet — `release(token)` still computes a non-zero releasable amount and then calls
`safeTransfer(token, address(0), amount)`, which reverts. The tokens are neither released nor
recoverable, by anyone, ever. There is no admin on a `VestingWallet` clone.

This is reachable three ways: the platform beneficiary EOA (200,000 GOV), the deployer
recipient EOA (up to 2,000,000 GOV), and — via one captured proposal — the Timelock's own
treasury wallet (2,800,000 GOV).

**Verification evidence:**
```
[PASS] testVestingBeneficiaryCanRenounceAndPermanentlyBrickAllocation
  owner() == address(0) after renounce; releasable(GOV) > 0; release(GOV) reverts
  GOV stranded forever: 200000000000000000000000
```

**Suggested fix (hypothesis, both directions priced):**
```solidity
contract CoinDAOVestingWallet is VestingWalletUpgradeable {
    error OwnershipCannotBeRenounced();
    constructor() { _disableInitializers(); }
    function renounceOwnership() public pure override { revert OwnershipCannotBeRenounced(); }
}
```
- Prevents: an irreversible strand from a mis-clicked "renounce" or a compromised key whose
  attacker prefers destruction to theft.
- Creates: a beneficiary who genuinely wants to disclaim the allocation must instead
  `transferOwnership` to a burn-like address — which, given `release` to `address(0)` also
  reverts, is the same outcome by a different route. The cost is therefore near zero; this
  is the rare fix whose second failure mode is not material. Note that it does **not**
  address `transferOwnership` (FF-005), which is a separate decision.

---

### FF-004 — A queued malicious proposal cannot be cancelled by anyone; the `CANCELLER_ROLE` granted to the Governor is unreachable in an emergency

**Severity: MEDIUM**
**Module:** `CoinDAOGovernor` + the Timelock wiring at `CoinDAOFactory` L428–430
**Lines:** `src/CoinDAOGovernor.sol` L92–99, L36
**Verification:** PoC — `testQueuedMaliciousProposalCannotBeCancelledByAnyone`
**State touched (Pass 2):** `GovernorTimelockControl._timelockIds[id]`,
`TimelockController._timestamps[opId]`, `TimelockController` role set

**Feynman question:**
> Q1.1 — *Why does this line exist? What invariant does it protect?*
> (asked of `timelock.grantRole(CANCELLER_ROLE, governor)`)

**Why this is wrong:** the 2-day timelock delay is the design's last line of defence — its
whole purpose is to give humans time to react to a bad proposal. But there is no reaction
available:

- `Governor.cancel(...)` requires `msg.sender == proposalProposer(id)` **and**
  `state == Pending`. A queued proposal is `Queued`, so this path is closed even to the
  proposer.
- `TimelockController.cancel(opId)` requires `CANCELLER_ROLE`, held **only** by the Governor
  (`CoinDAOFactory` L429). No EOA, multisig or guardian holds it.
- The Governor's only route to `timelock.cancel` is `relay(...)`, which is `onlyGovernance`
  — i.e. it requires a *second* proposal running the full 7,200 + 36,000 block + 2-day
  cycle, roughly 8 days. Four times longer than the window it is meant to fit inside.

So the `CANCELLER_ROLE` grant protects no reachable invariant. Meanwhile `EXECUTOR_ROLE` is
`address(0)` — execution is open to every address on the chain.

**Verification evidence:**
```
[PASS] testQueuedMaliciousProposalCannotBeCancelledByAnyone
  state == Queued; isOperationPending(opId) == true; hasRole(CANCELLER, governor) == true
  timelock.cancel(opId) from a bystander -> AccessControlUnauthorizedAccount
  governor.cancel(...) from the proposer  -> reverts (Pending-only)
  after the 2-day delay a bystander called execute() and the capture landed
```

**Impact:** every finding that ends in "a proposal executes" becomes irreversible the moment
it is queued. This is the multiplier on FF-001.

**Suggested fix (hypothesis, both directions priced):** grant `CANCELLER_ROLE` to a
guardian — a multisig, or the platform beneficiary — at `CoinDAOFactory` L429, in addition
to the Governor.
- Prevents: an executed capture, by giving the 2-day window an actor.
- Creates: a censorship vector. A guardian that can cancel any queued proposal can veto
  legitimate governance indefinitely, which is a different centralisation failure with its
  own blast radius (it can, for instance, block the proposal that would remove the
  guardian). The honest framing is that the current design has chosen "no veto, no
  emergency stop"; if that is deliberate it should be stated, because the `CANCELLER_ROLE`
  grant at L429 currently *reads* as though an emergency stop exists.

---

### FF-005 — The vesting wrapper leaves `transferOwnership` unconstrained and adds no cliff; a "four-year allocation" is sellable and starts paying in the next second

**Severity: MEDIUM**
**Module:** `CoinDAOVestingWallet`
**Lines:** `src/CoinDAOVestingWallet.sol` L6–9 (by omission); schedule set at
`CoinDAOFactory` L457, L463, L470, L479
**Verification:** PoC — `testVestingBeneficiaryCanSellTheEntireStream`,
`testFourYearVestHasNoCliff`, `testLateDepositIsImmediatelyReleasableAtElapsedFraction`
**State touched (Pass 2):** `OwnableUpgradeable._owner`, `VestingWallet._start`,
`VestingWallet._duration`, `VestingWallet._erc20Released[GOV]`

**Three distinct properties of the base that the wrapper does not constrain:**

1. **The stream is transferable.** `transferOwnership` redirects all future releases in one
   transaction — the whole 200,000 GOV platform allocation went to a third party in the PoC.
   A four-year lock-up whose beneficiary can sell the position on day one is not a lock-up;
   it is a four-year *delivery schedule* for whoever holds the wallet.
2. **There is no cliff.** OZ's `_vestingSchedule` is linear from `start`, and the factory
   sets `start = block.timestamp`. Measured on the 2,000,000 GOV deployer allocation:
   **15,854,895,991,882,293 wei releasable one second after launch**, 1,369 GOV after one
   day, 41,095 GOV after 30 days. The industry norm for a founder/platform allocation is a
   one-year cliff; nothing in the tree records a decision to omit it.
3. **Late deposits vest instantly.** `vestedAmount` is computed from
   `balanceOf(this) + released`, so a top-up made one day before the end of the schedule is
   **99.93 % immediately releasable** — 999,315 GOV of a 1,000,000 GOV deposit in the PoC.
   Any future "add to the treasury vest" governance action is, in practice, a transfer to
   the wallet's owner.

**Suggested fix (hypothesis, both directions priced):** override `_vestingSchedule` to add a
cliff, and consider overriding `transferOwnership` to a two-step or to `revert` for the
platform and deployer wallets.
- Prevents: instant liquidity on allocations that were sold to the market as four-year
  locked, and a late top-up being drained.
- Creates: a cliff makes the schedule non-linear, which breaks the "release() any time"
  UX and, more seriously, makes the treasury wallet unable to fund anything in year one —
  which a DAO that expects to pay contributors from the treasury vest would experience as a
  self-inflicted freeze. And a non-transferable beneficiary means a lost key is
  unrecoverable (which interacts badly with FF-003's fix). These are genuine trade-offs, not
  formalities: the correct output of this finding is a *decision*, recorded, not a patch.

---

### FF-006 — The launch script verifies that twelve contracts exist and nothing about where the money or the roles went

**Severity: MEDIUM**
**Module:** `DeployCoinDAOScript`
**Lines:** `script/DeployCoinDAO.s.sol` L230–263 (and L198–219)
**Verification:** PoC × 3 + an explicit negative grep
**State touched (Pass 2):** none written — this is a control gap, and it is the reason
FF-002 and the beneficiary rotation are undetectable in practice

**Feynman question:**
> Q1.4 — *Is this check sufficient for what it is trying to prevent?*
> and the working rule: *absence claims are the dangerous ones — grep for the negative.*

**The negative, grepped explicitly:**
```
$ grep -rn "balanceOf\|hasRole\|\.owner()\|PROPOSER_ROLE\|quorum\|votingDelay" script/
(no output)
```

**Why this is wrong:** `_verifyDeployment` asks "did twelve addresses get code, is the
lender's operator the router, is the manager the deployer, is the staking token the one I
chose". Those are shape questions. It never asks a single *outcome* question. The entire
security model of the launch — who can propose, who admins the Timelock, who owns the
router, and where 10,000,000 GOV went — is unverified by the tool whose job is to verify the
launch.

**Verification evidence (all three PoCs return cleanly from `_verifyDeployment`):**
```
[PASS] testVerifyDeploymentSignsOffOnAFivePercentGiveaway
       500,000 GOV in an arbitrary EOA, timelock holds 0 — verification passes
[PASS] testBeneficiaryRotationBetweenSimulationAndInclusionIsUnverified
       monolithBeneficiary rotated between simulation and inclusion;
       the 200,000 GOV wallet is created for the NEW beneficiary — verification passes
[PASS] testVerifyDeploymentChecksNoRolesOwnersOrParameters
       PROPOSER/CANCELLER/DEFAULT_ADMIN/EXECUTOR facts all hold — and none is asserted
```

The beneficiary-rotation case deserves emphasis because it is a live front-running window,
not a hypothetical: `CoinDAOFactory.acceptMonolithBeneficiary()` is a one-transaction
completion of a two-step rotation, and a launcher who simulates against beneficiary A can
have their launch included in a block after beneficiary B accepted. `_preflight` pins
`monolithFactory` to a constant (L200) — the correct pattern — and pins nothing about the
beneficiary.

**Suggested fix (hypothesis):** extend `_preflight` with
`require(factory.monolithBeneficiary() == expectedBeneficiary)` read from the environment,
and extend `_verifyDeployment` with balance assertions for all five allocations against
`factory.allocationFor(bps)`, ownership assertions for the three vesting wallets and the
router, and the four Timelock role assertions.
- Prevents: silent mis-allocation and a rotated beneficiary.
- Creates: more `require`s in a simulated run means more ways for a legitimate launch to
  abort late; and a pinned beneficiary means every legitimate rotation requires a
  coordinated `.env` update. Both are cheap compared with an unverified launch.

---

### FF-007 — `_preflightImplementations` is a check that cannot fail, and it is the only gate on an environment-supplied factory address

**Severity: MEDIUM**
**Module:** `DeployCoinDAOScript`
**Lines:** `script/DeployCoinDAO.s.sol` L221–228, reached from L48/L50/L201
**Verification:** PoC — `testPreflightImplementationsPassesForSixUnrelatedContracts`
**State touched (Pass 2):** none — control gap

**Feynman question:**
> Q1.2 — *What happens if I delete this line entirely?* (Answer: nothing, ever.)
> and the working rule: *a green check has a resolution — mutate the prediction and find the
> smallest error it still catches.* This one catches nothing.

**Why this is wrong:** `CoinDAOFactory`'s constructor already requires all six
implementations to have code (`_validateImplementations`, L546–548), and post-Cancun code
cannot be removed from a deployed address. So for **any** `CoinDAOFactory` that exists,
these six `require`s pass by construction. The check has zero resolution.

What it looks like it is for — reassuring the launcher that the `COIN_DAO_FACTORY`
environment value is the intended factory — it cannot do, because neither the factory nor
the script ever checks that an implementation is of the expected *type*. I constructed a
`CoinDAOFactory` whose six implementations are six unrelated `MockERC20`s; the constructor
accepted it and the script's preflight raised no objection.

This is compounded by `DeployCoinDAOFactory.s.sol` L42 deploying the factory with plain
`new` (nonce-based `CREATE`), so unlike `MONOLITH_FACTORY`, `WETH` and `ETH_USD_FEED` — all
of which are pinned as compile-time constants and checked — the CoinDAO factory address
arrives from `vm.envAddress` with only `code.length != 0` behind it (L50).

**Verification evidence:**
```
[PASS] testPreflightImplementationsPassesForSixUnrelatedContracts
  preflightImplementations() accepted six unrelated ERC20s as the implementation set
```

**Suggested fix (hypothesis):** either pin the factory address as a constant the way the
other three addresses are pinned, or make the preflight resolving — e.g. probe each
implementation for a type-identifying call (`GovToken(impl).decimals()`,
`VestingWalletUpgradeable(impl).duration()`), and assert the factory's own constants
(`GOV_TOKEN_SUPPLY`, `GOVERNOR_PROPOSAL_THRESHOLD`, `MONOLITH_BPS`, `FOUR_YEARS`).
- Prevents: a launcher pointing at a substituted factory.
- Creates: type probes on an implementation are themselves spoofable by a contract that
  implements the probe — so this raises the cost of substitution without closing it. The
  only closing fix is pinning the address, which costs a code change per redeployment.

---

### FF-008 — Oracle staleness is bounded only by `uint32`, `minDebt` is not bounded at all, and the preflight consumes the value before it is validated

**Severity: MEDIUM**
**Module:** `DeployCoinDAOScript`
**Lines:** `script/DeployCoinDAO.s.sol` L166–174 (validation), L217–218 (consumption),
L54 vs L57 (ordering)
**Verification:** PoC — `testMonolithParamsAcceptAbsurdOracleStalenessAndDebtFloor`,
`testMonolithParamsRejectEveryOtherOutOfRangeValue`, `testHalfLifeOverflowGuardIsUnreachable`
**State touched (Pass 2):** none in this tree — the value is handed to the external Monolith
market, so this is a hand-off finding

Three related defects in one function, kept together because they share a root cause: the
validation block is *per-parameter ad hoc* rather than derived from any documented range.

**(a) `stalenessThreshold` — the only bound is the type.**
```solidity
require(stalenessThreshold != 0 && stalenessThreshold <= type(uint32).max, "Invalid staleness threshold");
```
`type(uint32).max` seconds is **136 years**. Every sibling parameter carries a tight,
domain-meaningful bound (`collateralFactor <= 8_500`, `halfLife` 12 h–30 d,
`redeemFeeBps <= 500`, `maxBorrowDeltaBps` 50–200); this one carries none. A launch with
`STALENESS_THRESHOLD` set high produces a lending market that will accept a price of any age.

Worse, the *runtime* check that consumes the same value —
`require(block.timestamp - updatedAt <= stalenessThreshold)` at L218 — **can only ever catch
a threshold that is too small.** A huge threshold makes it vacuously true. The one place the
parameter is exercised against reality is structurally blind to the dangerous direction.

**(b) `minDebt` has no `require` at all.** `0` and `type(uint256).max` both build cleanly.
It is the only numeric parameter in the function with no validation and the widest legal
range.

**(c) Ordering — the preflight uses the value before it is validated.** `run()` calls
`_preflight(factory)` at **L54**; `_preflight` reads `STALENESS_THRESHOLD` from the
environment at **L217**. `monolithParamsFromEnv()` — which is where L172 validates that same
variable — is not called until **L57**. Two independent `vm.envOr` reads of one variable, and
the validation is attached to the later one. Q2.1 asked "what if this line executed before
the line above it"; here the answer is that it already does.

Also in this function: **L174 `require(halfLife <= type(uint64).max)` is unreachable** —
L168 caps `halfLife` at 30 days first. Proven: `type(uint64).max + 1` reverts with
`"Invalid half life"`, never with `"Half life overflow"`.

Also unbounded below and worth recording: `collateralFactor` accepts `0` (a market nobody can
borrow from) and `timeUntilImmutability` accepts `0` (a market immutable at birth) — both
verified.

**Suggested fix (hypothesis):** bound `stalenessThreshold` to a multiple of the feed's actual
heartbeat (the Sepolia ETH/USD feed's is 1 hour, so e.g. `>= 1 hours && <= 24 hours`); give
`minDebt` a range; move `_preflight` below `monolithParamsFromEnv()` and pass the validated
struct in rather than re-reading the environment; delete L174.
- Prevents: a market launched against a dead oracle, and a preflight that validates nothing.
- Creates: a tight staleness bound couples the script to a specific feed's heartbeat, so
  changing collateral (already hardcoded to WETH) would require changing the bound too. That
  is the right coupling to have explicit rather than absent.

---

### LOW findings (verified by inspection or a supporting PoC)

| ID | Finding | Evidence |
|---|---|---|
| **FF-009** | `GovToken` inherits the full `ERC20Votes` machinery, but the Governor's votes token is `stGOV`. Delegating GOV confers nothing, and every GOV transfer pays for checkpoint writes nothing reads. A user-facing footgun (a holder who delegates on the obvious token silently has no vote) plus permanent dead gas. `grep -rn "IVotes" src/` → four hits, none `GovToken`. | PoC `testDelegatingTheGovTokenItselfConfersNoVotingPower`: `gov.getVotes == 500_000e18`, `governor.getVotes == 0` |
| **FF-010** | `IMonolith.sol` is a hand-transcribed ABI for an off-tree protocol, with no recorded source revision. Type/arity mismatches fail loudly (selector change) but **semantic** mismatches do not — `operator`/`manager` are adjacent `address` fields and `targetFreeDebtRatioStartBps`/`EndBps` are adjacent `uint16` fields. `IMonolithLender` declares `setManager` but omits `manager()`, forcing the script into an untyped `staticcall` at L266 guarded only by `success && result.length == 32`. `_preflight` never calls a single read-only Monolith function to sanity-check the ABI. | inspection + grep |
| **FF-011** | Quorum counts **undelegated** stGOV while `forVotes` counts only **delegated** votes. A large non-delegating staker base raises the bar for honest proposals and does nothing against a self-delegated attacker. | PoC `testNonDelegatingStakersRaiseQuorumButSupplyNoVotes`: 400,000 stGOV staked → quorum 400 GOV, votes 0 |
| **FF-012** | `stGOV` is non-transferable — but voting power is snapshot-based, so a voter needs the stake for exactly **one block**, the publicly-known `proposalBlock + 7200`. The non-transferability buys none of the stakeholder alignment it appears to. | PoC `testVoterCanUnstakeImmediatelyAfterSnapshotAndKeepFullWeight`: 400,000 GOV borrowed, staked in the snapshot block, unwound in the next, retained full weight and defeated the proposal while holding zero GOV and zero stGOV |
| **FF-013** | Both scripts are hard-gated to `block.chainid == 11155111` with Sepolia addresses and `"Monolith Sepolia USD"` token names. **There is no production deployment tooling in the tree** — `ls script/` returns exactly two files. Nothing here has been exercised against production parameters. | inspection |
| **FF-014** | `run()` requires a raw `PRIVATE_KEY` in the process environment (L47) and derives the Lender's permanent `manager` from it (L52, L71), foreclosing Foundry's keystore/hardware-signer paths for a launch that hands out a privileged external role. | inspection |
| **FF-015** | `psmAsset` and `psmVault` are hardcoded `address(0)` (L180–181) while `psmVaultMinTotalSupply` is hardcoded `1` (L194). Either the PSM is disabled — in which case `0` is the honest value — or it is not, in which case the two zero addresses are wrong. Nothing in the tree resolves the contradiction and nothing asserts against it. | inspection |
| **FF-016** | Eleven of the twelve environment variables use `vm.envOr` and fall back silently to a default on a typo; only `STAKING_TOKEN` reverts (L105). A mistyped `COLLATERAL_FACTOR` launches a market at 50 % without a word in the log. | inspection + PoC `testStakingTokenChoiceIsCaseSensitiveAndReverts` |

---

## REFUTED HYPOTHESES (recorded because a refutation is a claim too)

**"The Lender's `manager` role is permanently an EOA and the DAO can never reclaim it."**
Raised from `DeployCoinDAO.s.sol` L71 (`manager = deployer`) and L258. **REFUTED** by code
trace: `RevenueRouter.setManager(address)` at `src/RevenueRouter.sol` L94–97 is `onlyOwner`,
and the router's owner is set to the Timelock at `CoinDAOFactory` L454. Governance can
therefore reclaim the manager role by proposal. Recorded as a mitigation, with the caveat
that "by proposal" is not much of a barrier given FF-001. The residual open question — *why*
the script passes `deployer` when `predicted.timelock` is already known at L60 — is carried
to the debrief as a question, not a finding.

**"The `quorumDenominator` override from 100 to 1000 is the root cause of the capture."**
This was my initial FF-001 write-up. **REFUTED by mutation testing**: restoring the OZ
default of 100 leaves the capture working, and even the maximum legal numerator (a 100 %
quorum) leaves it working. The override is an aggravating factor — it moves the crossover
point from "10 % of supply staked" to "never" — but the cause is the quorum *base*. FF-001
is reported in its corrected form. This is exactly the failure the working rule warns about:
had I shipped the first version, the client would have "fixed" the denominator and remained
fully exposed.

**"`quorumDenominator()` being called from a base constructor reads uninitialised state."**
**REFUTED** by inspection: the override is `pure` and returns a literal, so the virtual
dispatch is safe. Recorded because it would *not* be safe if the value were ever moved into
storage or made configurable — a latent trap for a future change.

---

## EXPOSED ASSUMPTIONS (consolidated — the implicit contracts this layer relies on)

| # | assumption | held by | enforced? | if false |
|---|---|---|---|---|
| A1 | the votes token's clock is block-number, and a block is ~12 s | `CoinDAOGovernor` L22–23 | verified true on this chain; **not enforced** for any other | every timing constant is wrong by the block-time ratio |
| A2 | "staked supply" is a meaningful proxy for "the electorate" | L34, L64 | **no** | FF-001 |
| A3 | a voter's stake persists through the vote | the use of a non-transferable wrapper | **no** — `getPastVotes` is historical | FF-012 |
| A4 | someone can act inside the 2-day timelock window | L36, factory L429 | **no** | FF-004 |
| A5 | the beneficiary of a vesting wallet is a permanent, careful, non-renouncing party | `CoinDAOVestingWallet` (by omission) | **no** | FF-003, FF-005 |
| A6 | a four-year duration implies a lock-up | factory L457/L463/L470/L479 | **no** — linear, no cliff, transferable | FF-005 |
| A7 | the vesting wallet's balance only ever changes by design | `vestedAmount` is balance-based | **no** — anyone can send tokens in | FF-005(3) |
| A8 | `COIN_DAO_FACTORY` from the environment is the intended factory | script L48/L50/L201 | **no** — only `code.length != 0` | FF-007 |
| A9 | `factory.monolithBeneficiary()` at inclusion equals the value at simulation | script `_preflight` | **no** | FF-006 |
| A10 | `DEPLOYER_RECIPIENT` is only set when a deployer stake is intended | script L97 | **no** — one direction only | FF-002 |
| A11 | `STALENESS_THRESHOLD` is sane by the time `_preflight` uses it | script L54 vs L57 | **no** — validated later, and only against `uint32` | FF-008 |
| A12 | `IMonolith.DeployParams` matches the deployed Monolith factory field-for-field | `IMonolith.sol` | **no** — nothing pins a revision, nothing probes the ABI | FF-010 |
| A13 | `CoinDAOFactory.deploy` overwrites the `operator`/`manager` zeros the script leaves | script L186–187 | true (factory L304–305), but the script relies on it silently | a direct caller of `buildMonolithParams` gets a market with no operator |
| A14 | the six implementations are of the expected types | factory `_validateImplementations`, script `_preflightImplementations` | **no** — only code presence and distinctness | FF-007 |

---

## ORDERING CONCERNS (consolidated — Q2 and Q7)

| # | ordering | question | verdict |
|---|---|---|---|
| O1 | `_preflight` (L54) runs **before** `monolithParamsFromEnv` (L57) | Q2.1 — the preflight consumes `STALENESS_THRESHOLD` before L172 validates it, re-reading it from the environment | **SUSPECT** → FF-008(c) |
| O2 | `quorumDenominator()` is dispatched from a base constructor before the derived body runs | Q2.1 | SOUND **only because** the override is `pure` — latent trap if ever made stateful |
| O3 | `predictCoinDAOAddresses` (L59) runs before `deploy` (L71); `deploymentsLength` (L61) is snapshotted pre-broadcast | Q2.5 / Q7.6 — a concurrent launch breaks the strict equality at L237, aborting the *simulation*, not a mined transaction | SOUND (correct behaviour); the check is useless post-inclusion |
| O4 | `_verifyDeployment` (L74) runs **after** `vm.stopBroadcast()` (L72) | Q2.4 — these assertions execute in the simulated run; forge does not re-run them against the mined chain, so they bind the simulation, not reality | **SUSPECT** — compounds FF-006; a rotation or a race between simulation and inclusion is unverified by construction |
| O5 | the snapshot block is `proposalBlock + 7200`, published 7,200 blocks in advance | Q2.5 — an attacker chooses to be present in exactly one known block | **SUSPECT** → FF-012 |
| O6 | `GovToken.initialize` mints (L26) after the three `__X_init` calls (L23–25) | Q2.1/Q2.2 — moving the mint above `__ERC20_init` would emit `Transfer` before name/symbol exist | SOUND as written |
| O7 | vesting wallets are created (factory Phase 6) before GOV is transferred to them (Phase 7), all with `start = block.timestamp` from Phase 6 | Q2.3 — the gap is within one transaction, so the schedules are consistent | SOUND |
| O8 | queue → 2-day delay → execute, with no cancel transition available from `Queued` | Q2.4 — the "abort" path does not exist | **VULNERABLE** → FF-004 |
| O9 | `renounceOwnership` before `release` | Q7.5 — the first call makes the second permanently revert | **VULNERABLE** → FF-003 |
| O10 | a late token deposit after `start` | Q7.7 — accumulated elapsed time re-values the new deposit at the current vested fraction; the accumulator is not rebased against the deposit's own arrival time | **SUSPECT** → FF-005(3). This is the Q7.7 accumulator pattern: `vestedAmount` uses a schedule snapshot (`_start`, `_duration`) that goes stale relative to a balance that can change at any time |

---

## HAND-OFF TO PASS 2 — state variables each SUSPECT touches

The State Inconsistency lens should treat these as the coupled pairs this pass surfaced.

| finding | writes / depends on | coupled counterpart that is NOT updated in step |
|---|---|---|
| FF-001 | `Governor._quorumNumeratorHistory`, `GovernorSettings._proposalThreshold` | `StakedGovToken._totalCheckpoints` — the quorum base moves with staking activity while the threshold is a fixed absolute; the two are never reconciled |
| FF-001 | `GovernorCountingSimple._proposalVotes[id]` | `StakedGovToken._delegateCheckpoints` at the snapshot |
| FF-002 | `GovToken._balances[deployerRecipient]` | `CoinDAOFactory.deployments[id].deployerVesting` stays `address(0)` while a 5 % payment occurred — the registry records no trace of the recipient |
| FF-003 | `OwnableUpgradeable._owner = 0` | `VestingWallet._erc20Released[GOV]` frozen; `GovToken._balances[wallet]` becomes unreachable — a live balance with a dead claimant |
| FF-004 | `GovernorTimelockControl._timelockIds[id]` | `TimelockController._timestamps[opId]` — the Governor's view and the Timelock's view can only ever move forward together |
| FF-005 | `OwnableUpgradeable._owner` (transfer) | `VestingWallet._erc20Released[GOV]` carries over to the new owner; the released-to-date figure is not per-owner |
| FF-005(3) | `GovToken._balances[wallet]` (arbitrary inbound) | `VestingWallet._start` / `_duration` — the schedule is not rebased when the principal changes |
| FF-006 | none written | `CoinDAOFactory.monolithBeneficiary` ↔ each deployment's `monolithVesting._owner` (recon coupling #14 — confirmed by execution: rotation does not propagate, and nothing detects it) |
| FF-011 | `StakedGovToken._totalCheckpoints` | `StakedGovToken._delegateCheckpoints` — total supply and delegated votes diverge whenever a staker does not delegate |
| FF-012 | `StakedGovToken._delegateCheckpoints` at block `S` | `StakedGovToken._balances` at block `S+1` — the historical vote and the live balance are permitted to disagree |

---

## SUMMARY

- **Functions analysed:** 12 in `CoinDAOGovernor` (+ 10 inherited entry points), 4 in
  `GovToken`, 1 declared + 9 inherited in `CoinDAOVestingWallet`, 10 interface members in
  `IMonolith.sol`, 13 in `DeployCoinDAO.s.sol`, 1 in `DeployCoinDAOFactory.s.sol`.
  **60 functions.**
- **Lines interrogated:** 587 across the six scoped files.
- **Raw findings (pre-verification):** 1 CRITICAL, 1 HIGH, 6 MEDIUM, 8 LOW.
- **After verification:** 16 TRUE POSITIVE, 0 FALSE POSITIVE, 2 DOWNGRADED
  (FF-001 CRITICAL→HIGH, FF-002 HIGH→MEDIUM), 3 hypotheses REFUTED and recorded.
- **Final:** **1 HIGH, 7 MEDIUM, 8 LOW.**
- **Execution:** 21 PoC tests, all passing; 3 mutation runs, one of which materially
  corrected the headline finding's mechanism. Audited sources verified byte-identical after
  every mutation; full tree suite 76/76.
- **Nothing in this pass is "not proven by execution"** except FF-010, FF-013, FF-014 and
  FF-015, which are inspection findings about ABI provenance, the absence of a production
  script, key handling and a parameter contradiction — none of which has a runtime behaviour
  to execute. Reason recorded.

**The single most important line in this pass:** `CoinDAOGovernor.sol` L64–65 —
`quorum()` measured against `StakedGovToken.getPastTotalSupply()`. It is boilerplate. It
compiles, it is covered by the project's own tests, and it makes the DAO's quorum
unenforceable at every parameter setting the code permits.
