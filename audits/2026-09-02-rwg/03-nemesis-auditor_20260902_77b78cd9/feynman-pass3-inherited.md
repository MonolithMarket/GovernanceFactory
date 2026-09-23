# NEMESIS Pass 3 — Feynman re-interrogation: THE INHERITED-BUT-UNENGAGED SURFACE

**Lens:** `.claude/skills/feynman-auditor/SKILL.md` — Category 1 (purpose: *why does this line exist,
what breaks if I delete it*) and Category 3 (consistency: *why does A have a guard and B does not*),
applied not to the lines the project wrote but to **the lines it inherited and never looked at**.

**Language:** Solidity 0.8.26 / via-ir / optimizer 200 / Foundry / OpenZeppelin **v5.6.1**
(version read from `lib/openzeppelin-contracts/package.json`).

**Scope, per assignment:** `[scratch]` and `[scratch]`. `[scratch]`
was opened **only** to establish what a base class exposes and whether a setter is bounded — six
files, each cited at the line I read. Nothing under `engagements/` was read.

**The pattern I was sent to hunt.** Pass 2 found that `Governor.updateTimelock` — inherited,
`onlyGovernance`, **zero occurrences in `src/` and `script/`** — moves one of five bindings and
orphans the rest (SI-001, SI-001b, SI-001e). The question for this pass was: *is that one
oversight, or the visible corner of a class?*

**It is a class.** The project's own review guide states the thesis and then does not follow it:

> `novel_code.md:35-37` — *"The main review question is **not the library code itself**, but whether
> each composition uses the right parameters and ownership handoffs."*

`novel_code.md` then enumerates the governor's four parameters as **values**
(`novel_code.md:80-83`) and acknowledges exactly **one** of them as mutable after launch
(`novel_code.md:85` — *"Governance may update the numerator between 0 and 1,000"*). OpenZeppelin
hands this composition **six** mutable governance parameters and two arbitrary-authority
primitives. Five of the six, and both primitives, appear **nowhere** in `src/`, `script/`, `test/`
or the project's own `plan.md` / `novel_code.md`.

---

## 0. Execution environment

Disposable full-tree copy at `…/[scratch]`. **`[scratch]` was not written to** —
`git status --porcelain [scratch]` empty, `git diff --stat -- [scratch]` empty,
`diff -rq [scratch] …/p3/src` clean at the end of the pass.

| suite | result |
|---|---|
| project baseline in the copy (`--no-match-path "test/audit/*"`) | **55 / 55 PASS** |
| baseline + this pass's PoCs | **69 / 69 PASS** |
| this pass's PoCs (`test/audit/P3Bricking.t.sol`, `P3Bindings.t.sol`, `P3Base.sol`) | **14 / 14 PASS** |

Verification levels use the workspace scale: **L1** compiles · **L2** a check passes · **L3** the
check could have failed (a control is included) · **L4** executed in a real EVM.

**Harness discipline carried over from Pass 2 (SI-008):** every roll and warp in this pass goes
through `vm.getBlockNumber()` / `vm.getBlockTimestamp()`.

**One harness trap found and worked around, recorded because it silently produces a false green:**
`vm.prank` is consumed by the **next external call**, including a `view` call evaluated as an
*argument*. `tl.schedule(…, tl.getMinDelay())` under a prank sends the prank to `getMinDelay()` and
the `schedule` goes out under the test contract's own address. My first `test_FP306` run failed with
`AccessControlUnauthorizedAccount(<test contract>, PROPOSER_ROLE)` for exactly this reason. Hoisting
the argument fixed it. The client's suite does not use this idiom (checked), so there is no false
green in the delivered tests today.

---

## 1. The complete inherited-surface inventory

Method: the **compiled ABI** of every deployed contract (`forge inspect <C> abi`) minus every name
that appears in `src/`, `script/`, `test/`, `plan.md` or `novel_code.md`. Counts are literal grep
hits over those five locations, `lib/` and `out/` excluded. **This is the answer to the assignment's
question 1.**

### 1.1 `CoinDAOGovernor` — Governor · GovernorSettings · GovernorCountingSimple · GovernorVotesQuorumFraction · GovernorTimelockControl

| inherited entry point | guard | src | script | test | docs | mutates a binding? |
|---|---|---|---|---|---|---|
| `updateTimelock(TimelockController)` | onlyGovernance | 0 | 0 | 0 | 0 | **YES — 6 bindings** (SI-001, + F-02) |
| `relay(address,uint256,bytes)` | onlyGovernance | 0 | 0 | 0 | 0 | **YES — arbitrary call as the Governor** (F-05, and F-01(f)) |
| `setProposalThreshold(uint256)` | onlyGovernance | 0 | 0 | 0 | 0 | **YES — unbounded** (F-01) |
| `setVotingDelay(uint48)` | onlyGovernance | 0 | 0 | 0 | 0 | **YES — unbounded** (F-01) |
| `setVotingPeriod(uint32)` | onlyGovernance | 0 | 0 | 0 | 0 | **YES — only 0 rejected** (F-01) |
| `cancel(address[],uint256[],bytes[],bytes32)` | proposer, **Pending only** | 0 | 0 | 0 | 0 | no — and unreachable when it matters (F-04) |
| `castVoteBySig`, `castVoteWithReason`, `castVoteWithReasonAndParams`, `castVoteWithReasonAndParamsBySig` | signature / open | 0 | 0 | 0 | 0 | no — untested vote surface |
| `onERC721Received`, `onERC1155Received`, `onERC1155BatchReceived` | reverts here | 0 | 0 | 0 | 0 | no — **checked negative**, F-08 |
| `receive()` | reverts here | 0 | 0 | 0 | 0 | no — **checked negative**, F-08 |
| views: `proposalProposer`, `proposalEta`, `getProposalId`, `hashProposal`, `proposalVotes`, `hasVoted`, `getVotesWithParams`, `COUNTING_MODE`, `CLOCK_MODE`, `version`, `supportsInterface`, `nonces`, `eip712Domain`, `timelock()`, `token()` | — | 0–1 | 0 | 0–1 | 0 | — |
| **engaged:** `propose`, `castVote`, `queue`, `execute`, `updateQuorumNumerator` | | | | ✓ | ✓ (quorum only) | |

`updateQuorumNumerator` is the **only** parameter mutator the project engaged with. It has three
tests and a documented range. That is the control case: it proves the team knows how to engage with
a governance parameter, and did so exactly once.

### 1.2 `TimelockController` — deployed verbatim by the factory, never subclassed

| inherited entry point | guard | src | script | test | docs |
|---|---|---|---|---|---|
| `updateDelay(uint256)` | the timelock itself | 0 | 0 | 0 | 0 | **unbounded** (F-01(e)) |
| `revokeRole(bytes32,address)` | DEFAULT_ADMIN = the timelock | **0** | 0 | 0 | 0 | SI-001e, F-03 |
| `grantRole(bytes32,address)` | DEFAULT_ADMIN = the timelock | 2 (`CoinDAOFactory.sol:428-429`, launch only) | 0 | 0 | 0 | **F-03** |
| `renounceRole(bytes32,address)` | self-confirmation | 1 (`CoinDAOFactory.sol:430`, the *factory* dropping admin) | 0 | 0 | 0 | the *timelock* renouncing its own admin is unconsidered |
| `schedule`, `scheduleBatch` | PROPOSER | 0 | 0 | 0 | 0 | **F-03** |
| `execute`, `executeBatch` | **open — `EXECUTOR = address(0)`** | 0 | 0 | 0 | 0 | SI-001b; used by F-03 / F-05 |
| `cancel(bytes32)` | CANCELLER = the Governor | 0 | 0 | 0 | 1 (`plan.md:131`, "optional") | **F-04** |
| `receive()` payable, `onERC721Received`, `onERC1155*Received` | open | 0 | 0 | 0 | 0 | F-08 |
| views: `getMinDelay`, `getOperationState`, `getTimestamp`, `getRoleAdmin`, `isOperation*`, `hashOperation*` | — | 0 | 0 | 0 | 0 | |
| `hasRole` | — | 0 | 0 | 1 (`test/CoinDAOFactory.t.sol:148`) | 0 | the single role assertion in the suite |

**The whole role model of this system is asserted once, in one line of one test**, and it asserts
only that the factory no longer holds `bytes32(0)`.

### 1.3 `CoinDAOVestingWallet` — `VestingWalletUpgradeable` + `OwnableUpgradeable` (a 10-line wrapper)

| inherited entry point | guard | src | script | test | docs |
|---|---|---|---|---|---|
| `release()` / `release(address token)` | **permissionless** | **0** | **0** | **0** | **0** |
| `releasable()`, `releasable(address)`, `released()`, `released(address)`, `vestedAmount(uint64)`, `vestedAmount(address,uint64)`, `start()`, `duration()`, `end()` | — | 0 | 0 | 0 | 0 |
| `transferOwnership(address)` | owner — **single-step** | 0 | 0 | 0 | 0 | F-06 |
| `renounceOwnership()` | owner | 0 | 0 | 0 | 0 | F-06 |
| `receive()` payable | open | 0 | 0 | 0 | 0 |

**`release` is the only payout path for 3,000,000–4,428,571 GOV (30 % of the fixed supply at
`deployerStakeBps = 0`, 44.3 % at the 2,000 bps maximum — arithmetic re-derived from `allocationFor`) and
it appears zero times in the entire repository — no call, no test, no comment, no line in the deploy
script's `_verifyDeployment`.** The wrapper's whole body is `constructor() { _disableInitializers(); }`.

### 1.4 `RevenueRouter` — `OwnableUpgradeable`

| inherited entry point | guard | src | script | test | docs |
|---|---|---|---|---|---|
| `renounceOwnership()` | owner (the timelock) | 0 | 0 | 0 | 0 | Pass 2 SI-005 |
| `transferOwnership(address)` | owner — **single-step** | 1 (`CoinDAOFactory.sol:454`, launch only) | 0 | 0 | 0 |

…and the **absent** member of the family: `plan.md:116` lists *"optional setTreasury / setGovStaking
address updates **if not made immutable**"*. They were not shipped. See F-02 — the decision is
defensible in isolation and is falsified by `updateTimelock`.

### 1.5 `StakedGovToken` — ERC20Wrapper · ERC20Permit · ERC20Votes · ReentrancyGuard

| inherited entry point | src | script | test | docs | note |
|---|---|---|---|---|---|
| `permit`, `DOMAIN_SEPARATOR`, `eip712Domain` | 0 | 0 | 0 | 0 | **dead — the token is non-transferable** (F-07) |
| `approve`, `allowance`, `transferFrom` | 0 | 0 | 8 / 0 / 0 | 0 | `approve` succeeds, `transferFrom` always reverts (F-07) |
| `delegateBySig` | 0 | 0 | 0 | 0 | live, untested |
| `checkpoints`, `numCheckpoints`, `underlying`, `CLOCK_MODE` | 0 | 0 | 0 | 0 | |
| `_recover` | — | — | — | — | **internal, not exposed** (Pass 2 SI-009b; re-confirmed by ABI) |

### 1.6 `GovToken`, `StakingRewards`, `StakingRewardsFunder`, `Initializable`, `ReentrancyGuard`

- **`GovToken`'s entire `ERC20Votes` surface is unused by this system** — the Governor is wired to
  `StakedGovToken`. This one **is** engaged in a comment (`novel_code.md:71-73`: *"historical
  checkpoints support future governance integrations, but the CoinDAO governor remains wired
  exclusively to `StakedGovToken`"*), so it is a deliberate decoy, not an oversight. **Not a
  finding.** `GovToken.permit` is unmentioned but harmless.
- **`StakingRewards.transferOwnership`** — 0 mentions; reachable only inside the launch transaction,
  because L488 renounces. Dead surface, no consequence.
- **`Initializable`** — `_disableInitializers()` is present in all six implementation constructors
  (verified by reading each). No `reinitializer`, no exposed `_getInitializedVersion`. **Checked
  negative.**
- **`ReentrancyGuard`** — the *non-upgradeable* variant is inherited by three clones
  (`StakedGovToken`, `StakingRewards`, `StakingRewardsFunder`), so its constructor never runs. In
  OZ **5.6.1** the guard lives in an ERC-7201 **namespaced** slot
  (`lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol:50-59,95-105`) and the check is
  `_status == ENTERED(2)`, so an uninitialised `0` behaves exactly like `NOT_ENTERED`. **No
  collision, no bypass. Checked negative — but it is version-dependent, and a downgrade to a
  pre-namespaced OZ would put `_status` in slot 0 of these clones.**

---

## 2. The Feynman interrogation — WHO / WHAT / WHAT ELSE / REVERSIBLE

Applied to every unengaged function that **mutates state**. This is the assignment's question 2,
and the last column is question 3.

| function | WHO can reach it | WHAT it changes | WHAT ELSE assumed the old value | REVERSIBLE, and by whom |
|---|---|---|---|---|
| `Governor.updateTimelock` | 1 proposal | `Governor._timelock` | router `_owner`, **router `treasury`**, vest `_owner`, timelock GOV+ETH+NFTs, `PROPOSER` on the destination, `_timelockIds` of live proposals, `deployments[i].timelock` | **conditional** — see F-05. Yes via `relay` **iff** the destination grants the Governor `PROPOSER`; otherwise **never**. `treasury` is **never**, on either branch. |
| `Governor.setProposalThreshold` | 1 proposal | the threshold to propose | nothing caches it — but `propose` gates on it | **NO.** Undoing it needs a proposal that cannot be created. |
| `Governor.setVotingDelay` | 1 proposal | `_votingDelay` (uint48) | `propose` downcasts `clock()+delay` to uint48 | **NO.** |
| `Governor.setVotingPeriod` | 1 proposal | `_votingPeriod` (uint32) | `proposalDeadline` | **NO** in any practical sense (max = ~1,634 years). |
| `Governor.updateQuorumNumerator` | 1 proposal | the quorum fraction | — | **NO at the maximum the guard permits** (numerator = denominator = 1,000). |
| `Governor.relay` | 1 proposal | anything, as `address(governor)` — which holds `PROPOSER` + `CANCELLER` on the timelock | the entire role model | direction-dependent: it is the **only** repair primitive (F-05) **and** a one-proposal suicide (F-01(f)). |
| `Timelock.updateDelay` | 1 proposal | `_minDelay` | `_schedule` computes `block.timestamp + delay` | **NO.** Any value near `type(uint256).max` makes every future `queue()` revert. |
| `Timelock.grantRole` | 1 proposal | the role set | the DAO's belief that the Governor is the sole authority | **grantee-dependent** — the grantee can evict the Governor first (F-03). |
| `Timelock.revokeRole` / `renounceRole` | 1 proposal | the role set | `Governor._timelock` still names it | **NO** once `PROPOSER` leaves the Governor (SI-001e). |
| `VestingWallet.transferOwnership` | the wallet's owner | who receives 2–28 % of supply | `factory.monolithBeneficiary`, `deployments[i]` | single-step; a wrong address is **final**. |
| `VestingWallet.renounceOwnership` | the wallet's owner | owner → `address(0)` | `release()` then reverts forever | **NO** (F-06). |
| `VestingWallet.release` | **anyone** | moves vested GOV to `owner()` | keeps paying an abandoned timelock (SI-001) | n/a |
| `RevenueRouter.renounceOwnership` | 1 proposal | router `_owner` → 0 | `lender.manager` chain | **NO** (Pass 2 SI-005). |

**The structural result.** Every repair in this system routes through exactly one primitive: *a
passed proposal*. This pass counts **nine distinct single-proposal actions that destroy the ability
to pass a proposal.** Pass 2 found two of them (`updateTimelock`, `revokeRole`). Seven are new, and
all nine are inherited functions the project has never named.

---

## 3. Findings

**Finding ID → PoC map** (finding IDs are `F-0n`; test names are `test_FP3nn`, numbered
independently in execution order):

| finding | PoCs |
|---|---|
| **F-01** unbounded governance parameters | `test_FP301` `test_FP302` `test_FP303` `test_FP304` `test_FP305` `test_FP313` |
| **F-02** `RevenueRouter.treasury` orphan | `test_FP308` |
| **F-03** `PROPOSER_ROLE` escalation | `test_FP306` |
| **F-04** decorative `CANCELLER_ROLE` | `test_FP307` |
| **F-05** `relay` recovery (refines SI-001) | `test_FP309` + `test_FP309control` |
| **F-06** vesting-wallet `Ownable` surface | `test_FP310` |
| **F-07** stGOV dead approval surface | `test_FP311` |
| **F-08** where value can arrive | `test_FP312` |

---

### F-01 — Five of the six governance parameters are unbounded, undocumented, untested, and each is a one-proposal permanent end to the DAO

**Severity: MEDIUM** (MEDIUM standalone; **HIGH by composition with FF-001**, stated below and left
for the debrief to grade against `SCOPE.md §10`) · **NEW**
**Modules:** `CoinDAOGovernor` (inherited `GovernorSettings`, `GovernorVotesQuorumFraction`),
`TimelockController`
**Verification: Method B — `test_FP301…`, `test_FP302…`, `test_FP303…`, `test_FP304…`,
`test_FP305…`, `test_FP313…`, all PASS, Level 4.** Bounds established by reading the base classes.

#### The Feynman question that exposed it

> **Q1.2 — What happens if I DELETE this line entirely?**
> Applied to `CoinDAOGovernor.sol:22-23`:
> ```solidity
> uint48 public constant DEFAULT_VOTING_DELAY_BLOCKS = 7_200;
> uint32 public constant DEFAULT_VOTING_PERIOD_BLOCKS = 36_000;
> ```
> Deleting them changes nothing after block 1. They are **constructor arguments wearing the word
> `constant`**. The same is true of `CoinDAOFactory.GOVERNOR_PROPOSAL_THRESHOLD` and
> `DEFAULT_TIMELOCK_DELAY`. Four `public constant` declarations name four values that any single
> proposal can overwrite, through setters the project has never written down.

#### The bounds, read from the base classes

| setter | bound in OZ 5.6.1 | file:line |
|---|---|---|
| `_setVotingDelay(uint48)` | **none** | `GovernorSettings.sol:79-81` |
| `_setVotingPeriod(uint32)` | **only `!= 0`** | `GovernorSettings.sol:89-94` |
| `_setProposalThreshold(uint256)` | **none** | `GovernorSettings.sol:102-104` |
| `TimelockController.updateDelay(uint256)` | **none** | `TimelockController.sol:447-453` |
| `_updateQuorumNumerator` | `<= quorumDenominator()` = **1,000** | (the guard permits the bricking value) |

#### Executed evidence

**(a) `setProposalThreshold(type(uint256).max)` — `test_FP301`, PASS.**
```
one proposal executes setProposalThreshold(2**256-1)          <- no revert, no bound
then the richest possible proposer is handed the ENTIRE electorate:
  votes held by the whole electorate: 9,010,000.000000000000000000 stGOV
  getPastTotalSupply == getVotes(VOTER)                       <- 100% of the vote
  propose(...) -> GovernorInsufficientProposerVotes(VOTER, 9_010_000e18, 2**256-1)
```
No proposal can ever be created again. The factory renounced `DEFAULT_ADMIN_ROLE`
(`CoinDAOFactory.sol:430`), so there is no authority outside the timelock, and the timelock is
reachable only through the Governor.

**(b) `setVotingDelay(type(uint48).max)` — `test_FP302`, PASS.** `propose` computes
`clock() + votingDelay()` and downcasts to `uint48` (`Governor.sol:320,325`); the downcast reverts
for every caller, forever.

**(c) `setVotingPeriod` — `test_FP303`, PASS, and it is the sharpest of the five because it shows
the guard is *present and useless*.** The one value OZ rejects is `0`:
```
proposal setVotingPeriod(0)              -> execute REVERTS GovernorInvalidVotingPeriod(0)   <- guarded
proposal setVotingPeriod(type(uint32).max) -> ACCEPTED
  votingPeriod (blocks)        : 4,294,967,295
  approx years at 12s per block: 1,634
  an "undo" proposal is created, voted on, and its state is Active
  deadline block of the undo proposal: 4,295,060,899
```
A guard that rejects `0` and accepts 1,634 years is a guard that answers the wrong question. **This
is a Category-1 finding about somebody else's code that this project adopted unread.**

**(d) `updateQuorumNumerator(1_000)` — `test_FP304`, PASS.** The documented range
(`novel_code.md:85`: *"between 0 and 1,000"*) **includes** the value that ends governance. With one
wei of undelegated stGOV in existence — which FF-011 (governance lens) already established is the
normal state, since delegation is opt-in:
```
quorum required at snapshot: 10,000.000000000000000001 stGOV
total votes castable       : 10,000.000000000000000000 stGOV
undelegated stGOV          : 1 wei
undo proposal state        : Defeated                <- by the rule it is trying to repeal
```

**(e) `TimelockController.updateDelay(type(uint256).max)` — `test_FP305`, PASS.**
`_schedule` computes `block.timestamp + delay` (`TimelockController.sol:322`) and
`GovernorTimelockControl._queueOperations` reads `_timelock.getMinDelay()` live
(`GovernorTimelockControl.sol:84`). Every future `queue()` reverts with an arithmetic panic. The
DAO can still *propose* and *vote*; it can never again *execute*. That is the worst shape of the
five, because governance appears to work right up to the last step.

**(f) `relay` → `renounceRole(PROPOSER_ROLE, governor)` — `test_FP313`, PASS.** A proposal
described as "clean up stale roles" makes the Governor renounce its own proposer role. Same end
state as SI-001e, reached from the Governor's side rather than the timelock's.

#### Engaging with what the project did write

`novel_code.md:78-88` is the only place these parameters are discussed. It describes them as
*"parameterization"*, lists four numbers, and says governance may move exactly one of them. It does
not say the other three are mutable. `plan.md:133` recommends the cadence as if it were fixed. The
deploy script asserts none of them post-launch, and the suite asserts all of them **once, at
launch** (`test/CoinDAOGovernor.t.sol:24-26`) — which reinforces the reading that they are settled.

**None of this is wrong about the code. All of it is silent about the surface.** That silence is the
finding: an operator reading this repository has no way to learn that five one-proposal actions can
permanently end the DAO, because the repository never mentions that the functions exist.

#### Impact

Permanent DoS of a DAO holding, at genesis, 500,000 GOV liquid in the timelock, a 2,800,000 GOV
treasury vest that keeps paying into it, and ownership of `RevenueRouter` — i.e. the same
~33 % of supply Pass 2 priced under SI-001, plus all future protocol revenue.

**Honest limit on reachability, stated the way Pass 2 stated it for SI-001.** Each of these needs a
passed proposal. Under a healthy DAO that is an operator mistake, not an attack — and (c) and (d)
are *plausible* mistakes, because "lengthen the voting period" and "raise the quorum" are things
DAOs routinely do. Under **FF-001** (governance + factory lenses, HIGH: quorum can never exceed the
proposal threshold, so ~0.1 % of supply captures governance) and **SI-002** (Pass 2: the launcher is
guaranteed to clear the proposal threshold in 1.73 days), "requires a passed proposal" is a weak
barrier and these become **available denial actions that an attacker can take without holding the
supply they destroy**. I have graded on the mistake case.

#### Fix — both failure modes priced

*Option A (code, narrow).* Override the three `GovernorSettings` setters in `CoinDAOGovernor` with
sane bounds — e.g. `votingPeriod` in `[7_200, 216_000]`, `votingDelay <= 100_000`,
`proposalThreshold <= GOV_TOKEN_SUPPLY / 10`.
- *Prevents:* (a), (b), (c) — the three purely-numeric bricks — at the cost of ~12 lines.
- *Creates:* a **new bricking mode of its own**. If the chosen band turns out to be wrong for a
  chain with different block times, the DAO cannot leave it, because widening the band needs a
  proposal that the band itself constrains. The band must therefore be generous, and a generous band
  still permits values that are practically fatal (a 6-month voting period is inside any reasonable
  bound). **Bounds reduce this finding; they do not close it.**
- *Also creates:* it does **not** touch (d) `updateQuorumNumerator` (that guard is OZ's and already
  permits the fatal value) or (e) `Timelock.updateDelay` (which lives in a contract the project
  deploys verbatim and would have to subclass to guard).

*Option B (procedure).* Write a governance runbook that (1) enumerates the six mutable parameters
and their fatal ranges, (2) requires a simulated fork execution of every parameter proposal before
it is queued, and (3) requires a "can we still pass a proposal afterwards?" check as an explicit
review item.
- *Prevents:* the mistake case, which is the case I graded on, for **all six** including the two
  Option A cannot reach.
- *Creates:* nothing on-chain. It relies entirely on operator discipline, and the tree contains **no
  production runbook at all** (FF-013, governance lens) — so this is net-new documentation, not an
  edit.

*Option C (defence in depth).* Grant `PROPOSER_ROLE` on the timelock to a second, independent
address at launch — a founding multisig — so that a Governor that bricks itself does not brick the
timelock.
- *Prevents:* every finding in F-01 **and** SI-001, SI-001e and F-01(f), because a live proposer
  survives the Governor.
- *Creates:* **exactly F-06 below** — a second proposer can evict the first. This is not a free
  fix; it is a trade of "one authority that can kill itself" for "two authorities that can kill each
  other". Ship it only with the guard described in F-06.

**Recommendation: B + A, in that order. Option C only with F-06's guard, and only as a deliberate
governance decision — not as a security patch.**

---

### F-02 — `RevenueRouter.treasury` is a sixth thing that names the timelock, and it is the one nobody can ever move

**Severity: MEDIUM** · **EXTENDS Pass 2 SI-001** (which enumerated five bindings; this is the sixth,
and it is the only one that survives a *perfect* migration) · **NEW**
**Verification: Method B — `test_FP308_routerTreasuryIsASixthOrphanWithNoSetterAtAnyPrivilegeLevel`,
PASS. Level 4.**

#### The coupled pair

```
Governor._timelock == T
   |
   +--> RevenueRouter._owner    == T   [CoinDAOFactory.sol:454]   -- movable by the old owner
   +--> RevenueRouter.treasury  == T   [CoinDAOFactory.sol:407]   -- *** NO SETTER, ANYWHERE ***
   +--> treasuryVesting._owner  == T   [CoinDAOFactory.sol:463]   -- movable by the old owner
   +--> T's GOV / ETH / NFT balances                              -- movable by the old timelock
   +--> T grants PROPOSER+CANCELLER to the Governor [L428-429]    -- movable by the timelock
   +--> deployments[i].timelock == T   [CoinDAOFactory.sol:502]   -- never movable (push-only)
```

#### Executed evidence — the migration done *correctly* and it still fails

`test_FP308` performs Pass 2's own recommended safe migration (SI-001d): a destination timelock
constructed **with the Governor already in `proposers`**, then one batched proposal that moves
router ownership, vest ownership and the timelock's GOV, with `updateTimelock` last.

```
after the textbook migration:
  governor.timelock()      == T_new    OK
  router.owner()           == T_new    OK
  treasuryVesting.owner()  == T_new    OK
  GOV moved to T_new       == 500,000.000000000000000000   OK
  router.treasury()        == T_OLD    <-- STILL THE ABANDONED ADDRESS

governance is fully alive and owns the router; it passes one more proposal,
setGovStakingBps(5_000), and then anyone calls distribute():

  Coin delivered to the ABANDONED timelock: 500.000000000000000000
  Coin delivered to the LIVE timelock     :   0.000000000000000000
```

Every future treasury share of protocol revenue is paid to an address the DAO has abandoned, and
**there is no privilege level at which this can be changed** — not the owner, not the timelock, not
a proposal. Probed on-chain: `setTreasury(address)` does not exist. Grep for the negative across
`src/`, `script/`, `test/`: **zero** function declarations matching `setTreasury`.

Note the second, larger case: `RevenueRouter.distribute()` sends **100 %** of revenue to `treasury`
whenever `govStaking.totalSupply() == 0` (`RevenueRouter.sol:72-75`). Every window with no stakers —
including the whole period before the first deposit — pays the abandoned address in full.

#### Engaging with the comment that exists

This is the case `CLAUDE.md` warns about: **code that looks wrong is often refusing a shape someone
already tried.** The project considered this setter and declined it:

> `plan.md:116` — *"optional setTreasury / setGovStaking address updates **if not made immutable**"*

The decision is defensible on its own terms — fewer levers, smaller attack surface, and
`RevenueRouter.sol:12-15` makes the same argument explicitly for the operator role. **The decision
is falsified by a function in a different contract.** "Make `treasury` immutable" is sound if and
only if the timelock address is also immutable. `Governor.updateTimelock` makes it not, and the two
decisions were taken in two places by two lines that do not know about each other. Neither is wrong;
their composition is.

#### Fix — both failure modes priced

*Option A.* Do **not** add `setTreasury`. Instead, make `RevenueRouter.treasury` a *derived* value:
read `IGovernor(governor).timelock()` at distribution time.
- *Prevents:* the orphan entirely, and it stays correct across every future migration.
- *Creates:* a permanent runtime dependency of the revenue path on the Governor being alive and
  well-formed, plus a new coupling (`router.governor`) that has the same no-setter problem one level
  up. It also makes `distribute()` — currently permissionless and dependency-free — revert if the
  Governor ever becomes uncallable. **This trades an accounting orphan for a liveness risk on the
  only revenue path. I would not ship it.**

*Option B.* Add `setTreasury(address) onlyOwner`, reversing the `plan.md:116` decision.
- *Prevents:* the orphan, repairably, at the same privilege level that already controls
  `govStakingBps` and `setManager` — so it adds no new authority, only a new target for an authority
  that already exists.
- *Creates:* one more lever a captured governance can pull (redirect the treasury stream to
  themselves). Under FF-001 that capture is cheap — but a captured governance already owns the
  timelock the treasury pays into, so **the marginal power granted is close to zero**. This is the
  rare fix where the created failure mode is genuinely dominated by the existing one.

*Option C (cheapest, and the one I would ship alongside B).* Record the migration procedure from
Pass 2 SI-001 Option A, and add "`RevenueRouter.treasury` cannot be migrated — it must be
re-deployed, which is impossible because the router permanently holds the lender's `operator` role
and deliberately cannot re-nominate (`RevenueRouter.sol:13-15`)" as an explicit precondition on any
timelock migration.
- *Prevents:* an operator believing SI-001d's batch is complete. It is not.
- *Creates:* nothing.

**Recommendation: B + C. Explicitly not A.**

---

### F-03 — Granting `PROPOSER_ROLE` is not a subordinate permission: the grantee can evict the Governor and take everything, and nothing in the code, tests or docs says so

**Severity: MEDIUM** (MEDIUM standalone; **HIGH read as privilege escalation** — the gap between
what the DAO believes it granted and what it actually granted) · **NEW**
**Verification: Method B — `test_FP306_grantingProposerLetsTheGranteeEvictTheGovernorAndTakeEverything`,
PASS. Level 4.**

#### The Feynman question that exposed it

> **Q3.1 — If function A has an access guard and function B does not, why?**
> Applied across the role model: `CoinDAOFactory.sol:428-429` grants two roles and
> `CoinDAOFactory.sol:430` renounces admin. **After that line, the only holder of
> `DEFAULT_ADMIN_ROLE` is the timelock itself.** So the role set is administered by the very
> contract whose authority the roles define. Q: is `PROPOSER` *below* `DEFAULT_ADMIN` in this
> arrangement, the way the naming implies? A: **no** — a proposer can schedule a call to the
> timelock's own `revokeRole`, which executes as the timelock, which is `DEFAULT_ADMIN`.
> `PROPOSER` and `DEFAULT_ADMIN` are the same authority, separated only by a two-day delay.

#### Executed evidence

```
launch state (asserted at L4):
  timelock.hasRole(PROPOSER, governor)              == true
  timelock.hasRole(DEFAULT_ADMIN_ROLE, factory)     == false   <- renounced at L430
  timelock.hasRole(DEFAULT_ADMIN_ROLE, timelock)    == true    <- the only admin

ONE proposal, of a kind DAOs pass routinely -- "add an emergency multisig as a second proposer":
  timelock.grantRole(PROPOSER_ROLE, MALLORY)                   -> executes normally

MALLORY now acts ALONE. No vote, no quorum, no threshold, no tokens:
  MALLORY: timelock.schedule(timelock, revokeRole(PROPOSER, governor), delay=2 days)
  2 days pass; a random bystander executes it (EXECUTOR_ROLE == address(0), open)
    timelock.hasRole(PROPOSER, governor) == false
    timelock.hasRole(PROPOSER, MALLORY)  == true    <- sole proposer

the DAO tries to undo it: propose -> vote -> queue  ->  REVERTS
  (AccessControlUnauthorizedAccount: the Governor is no longer a proposer)

MALLORY: timelock.schedule(revenueRouter.transferOwnership(MALLORY)); 2 days; bystander executes
    revenueRouter.owner() == MALLORY                <- privately owned
```

Everything the timelock owns follows: the `RevenueRouter`, the 2,800,000 GOV treasury vest, the
liquid treasury, and every future proposal.

#### Why this is a finding and not "governance can harm itself"

Three reasons, the same three Pass 2 used to justify SI-001:

1. **The operation looks subordinate.** "Grant PROPOSER" reads as "let this address *also* propose,
   subject to the Governor". It is not. It is "let this address remove the Governor."
2. **Nothing in the system says otherwise.** `grantRole` appears twice in the entire repository,
   both at launch; `revokeRole` appears **zero** times; the role model has **one** assertion in the
   whole test suite (`test/CoinDAOFactory.t.sol:148`), and that assertion is about the factory. The
   docs (`plan.md:126-131`, `plan.md:141-142`) describe the timelock as "Timelock-controlled
   arbitrary execution" and never mention roles at all.
3. **The two-day delay is the only defence, and it is not one.** The Governor cannot cancel the
   eviction — see F-04 — and any counter-proposal takes votingDelay (7,200 blocks ≈ 24 h) +
   votingPeriod (36,000 blocks ≈ 5 days) + minDelay (2 days) ≈ **8 days** to land, against the
   attacker's 2. The delay is a formality.

#### Fix — both failure modes priced

*Option A.* Never grant `PROPOSER_ROLE` to anything but the Governor, and say so in the runbook as
a hard rule with the reason (this finding) attached.
- *Prevents:* the escalation.
- *Creates:* it forecloses Option C of F-01 — the second-proposer safety net that would survive a
  self-bricked Governor. **These two findings pull in opposite directions and the client has to
  choose; that tension is the honest deliverable here, not a recommendation.**

*Option B.* If a second proposer is wanted, make it a contract that can only schedule a
**whitelisted** set of calls (never `grantRole`/`revokeRole`/`updateDelay` on the timelock, never
`updateTimelock`/`setVoting*`/`setProposalThreshold` on the Governor).
- *Prevents:* both this finding and F-01's self-brick, simultaneously — it is the only shape that
  does.
- *Creates:* a new bespoke contract on the trust path, which is novel code in a system whose stated
  design principle is *"use off-the-shelf code where possible"* (`plan.md:17`). Novel code is where
  bugs live; the audit cost of that contract is real and should be priced before it is written.

---

### F-04 — `CANCELLER_ROLE` is granted at launch and is unreachable through the Governor's own surface

**Severity: LOW** (a guard that does nothing, not a loss) · **NEW**
**Verification: Method B — `test_FP307_cancellerRoleIsUnreachableThroughTheGovernorsOwnSurface`,
PASS, Level 4; plus a base-class trace.**

#### The Feynman question

> **Q1.1 — Why does this line exist? What invariant does it protect?**
> `CoinDAOFactory.sol:429`: `timelock.grantRole(timelock.CANCELLER_ROLE(), address(governor));`
> I could not name the invariant, so I traced every path that reaches `TimelockController.cancel`.

`GovernorTimelockControl._cancel` calls `_timelock.cancel(timelockId)` **only when
`_timelockIds[proposalId] != 0`** (`GovernorTimelockControl.sol:125-131`) — i.e. only for a proposal
that has been queued. But `Governor.cancel` is gated by `_validateCancel`
(`Governor.sol:460, 787-789`):

```solidity
return (state(proposalId) == ProposalState.Pending) && caller == proposalProposer(proposalId);
```

**Pending, and proposer only.** A Pending proposal has never been queued, so `_timelockIds` is zero
and the timelock branch never runs. The two conditions are mutually exclusive.

#### Executed evidence

```
timelock.hasRole(CANCELLER_ROLE, governor) == true     <- granted at CoinDAOFactory.sol:429
a proposal is proposed, voted, and queued: state == Queued
  proposer  calls governor.cancel(...)  -> GovernorUnableToCancel(id, proposer)
  bystander calls governor.cancel(...)  -> GovernorUnableToCancel(id, bystander)
```

The role is reachable **only** through `Governor.relay` — which needs a whole new proposal, i.e.
~8 days against the 2-day window it would have to beat. It is decorative.

#### Engaging with what the project asked for

> `plan.md:131` — | Cancel guardian | *Optional 12-month cancel guardian if simple to implement* |

The shipped artifact **looks like** that guardian was implemented — a role named `CANCELLER` granted
to the DAO's own Governor. It was not. An operator auditing the role set will see `CANCELLER_ROLE`
held by the Governor and reasonably conclude the DAO can cancel a queued proposal. It cannot. That
false assurance is the whole of this finding, and it is exactly the shape Pass 2 called *"a state
desync that reads as safety."*

#### Fix — both failure modes priced

*Option A.* Override `_validateCancel` in `CoinDAOGovernor` — OZ marks it `virtual` for precisely
this purpose — to also allow cancellation of a `Queued` proposal by a named guardian address, or by
the proposer, within a bounded window.
- *Prevents:* the false assurance, and delivers the capability `plan.md:131` asked for, in ~8 lines
  against an extension point the library provides.
- *Creates:* a **new censorship vector**. Whoever can cancel a queued proposal can veto governance.
  If that is the Governor itself via `relay`, nothing changes (still 8 days). If it is a guardian
  address, that address can block every proposal indefinitely and the DAO's only recourse is a
  proposal the guardian can cancel. **A cancel guardian is a governance decision with a real cost,
  not a safety feature — which is presumably why `plan.md` marked it optional.**

*Option B (minimum, and the one I would ship if the capability is not wanted).* Drop
`CoinDAOFactory.sol:429`, or keep it and document in one line that the role exists only for
`relay`-mediated cancellation and cannot beat a 2-day operation.
- *Prevents:* the false assurance.
- *Creates:* nothing — dropping the grant removes a capability that is already unusable. **Verify
  before dropping:** the grant is also what would make Option A cheap later, so keeping-and-documenting
  is the lower-regret choice.

---

### F-05 — REFINEMENT of Pass 2 SI-001: `relay` makes the timelock migration recoverable, and it is the *only* thing that does

**Severity: INFO as a defect; HIGH as a correction to a delivered finding** · **REFINES SI-001**
**Verification: Method B — `test_FP309_relayRecoversEverySI001OrphanWhenTheDestinationTrustsTheGovernor`
(PASS) with control `test_FP309control_noProposerOnTheDestinationMeansNoRelayAndNoRecovery` (PASS).
Level 4.**

**A refutation is a claim too.** Pass 2's SI-001 states flatly: *"It is irreversible. Every repair
path runs through the timelock that just became unreachable."* Pass 2's own PoC migrated to a
destination that does **not** grant the Governor `PROPOSER_ROLE`, which is the branch where that
sentence is true. On the other branch it is false, and the difference is `Governor.relay` — a
function with **zero occurrences** in `src/`, `script/`, `test/` and the project docs.

#### Executed evidence — full recovery in one proposal

```
naive migration: governor.updateTimelock(T_new), where T_new was constructed with the Governor
                 in `proposers` but NOTHING else was moved
  router.owner()          == T_old      ORPHANED
  treasuryVesting.owner() == T_old      ORPHANED
  GOV stranded in T_old   == 500,000.000000000000000000

ONE recovery proposal, executed through T_new:
  governor.relay(T_old, 0, T_old.scheduleBatch([router.transferOwnership(T_new),
                                                treasuryVesting.transferOwnership(T_new),
                                                govToken.transfer(T_new, 500_000e18)], delay))
    -> T_old.isOperationPending(...) == true        <- the Governor still holds PROPOSER on T_old

2 days pass; a random bystander calls T_old.executeBatch(...)   (EXECUTOR == address(0))
  router.owner()          == T_new      RECOVERED
  treasuryVesting.owner() == T_new      RECOVERED
  GOV recovered           == 500,000.000000000000000000
```

**Control (`test_FP309control`, PASS).** The identical migration to a destination **without**
`PROPOSER` for the Governor: `governor.queue(...)` reverts
`AccessControlUnauthorizedAccount(governor, PROPOSER_ROLE)`. No proposal can be queued, so `relay`
can never be called, so nothing is recoverable. The control is what gives the finding its
resolution: **the single bit that decides between "fully recoverable" and "28 % of supply gone
forever" is whether the destination timelock's constructor listed the Governor as a proposer.**

#### Why this matters more as a correction than as a defect

1. **SI-001's severity and its Option-B warning both change.** Pass 2 warned that a `hasRole`
   pre-check on `updateTimelock` would convert "four things are broken" into "three things are
   broken and you believe you are safe." That is still right — but the executed result here shows
   the pre-check is checking **exactly the bit that determines recoverability**. Option B is
   therefore worth more than Pass 2 credited it, provided it is shipped with A + C and documented as
   "this makes the mistake *repairable*, not *prevented*."
2. **`RevenueRouter.treasury` is unrecoverable on both branches** (F-02). So even the good branch
   is a partial recovery, and the migration runbook must say which parts come back.
3. **The repair primitive is itself unengaged.** An operator who has just discovered SI-001 in
   production has to find `relay`, understand that the Governor still holds `PROPOSER` on the
   abandoned timelock, and construct a nested `scheduleBatch` payload — with no documentation, no
   test, and no mention anywhere in the repository. Under time pressure, on a live DAO. **A repair
   path that exists and is undiscoverable is close to a repair path that does not exist.**

#### Fix — both failure modes priced

*Option A.* Add the recovery procedure — verbatim, with the `scheduleBatch` payload shape — to the
migration runbook that SI-001 Option A already calls for.
- *Prevents:* the discoverability half, which is the half that actually costs money.
- *Creates:* nothing. It is documentation of an existing capability.

*Option B.* Add a test. `test_FP309` is 40 lines and demonstrates the entire recovery.
- *Prevents:* the procedure being wrong when it is first needed.
- *Creates:* nothing.

---

### F-06 — The vesting wallets' inherited `Ownable` surface is reachable by one proposal on the wallet holding 28 % of supply

**Severity: MEDIUM** · **EXTENDS FF-003 (governance lens) and Pass 2 SI-001 (registries)**, which
found `renounceOwnership` on the *monolith* wallet; the treasury wallet — 14× larger and reachable
by governance rather than by a single external beneficiary — is new
**Verification: Method B — `test_FP310_renouncingTheTreasuryVestBricks28PercentOfSupply`, PASS.
Level 4.**

`CoinDAOVestingWallet` is ten lines. Everything it does is inherited, and **not one inherited
function appears anywhere in `src/`, `script/`, `test/` or the docs** — including `release`, the
only way any of that value ever moves.

```
treasuryVesting GOV principal                : 2,800,000.000000000000000000   (28% of supply)
after 1 year, release(GOV) works (permissionless, pays owner() == the timelock)

ONE proposal: treasuryVesting.renounceOwnership()          <- "tidy up the vesting wallet"
  vest.owner() == address(0)
after another year:
  vest.releasable(GOV) > 0                                 <- tokens are still vesting
  vest.release(GOV)    -> ERC20InvalidReceiver(address(0)) <- and can never leave
GOV permanently bricked in the treasury vest : 2,100,000.000000000000000000
```

Two properties make this worse than the monolith-wallet case FF-003 covered:

1. **`OwnableUpgradeable` is single-step.** `transferOwnership(address)` to a typo, a contract that
   cannot call `release`, or an address whose key is lost is equally final, and there is no
   `Ownable2Step` acceptance to catch it. The factory applies a two-step handshake to
   `monolithBeneficiary` (`CoinDAOFactory.sol:261-271`) — it knows the pattern — and then installs
   the timelock as a vesting-wallet owner with no such protection anywhere downstream.
2. **`release` is permissionless and pays `owner()`.** Combined with SI-001, the stream keeps
   pouring value into an abandoned timelock and anyone can keep it flowing. Combined with this
   finding, the stream stops permanently. The wallet has no state that distinguishes the two.

#### Fix — both failure modes priced

*Option A.* Override `renounceOwnership()` in `CoinDAOVestingWallet` to revert.
- *Prevents:* the permanent brick, for all three wallets, in two lines.
- *Creates:* almost nothing — the owners are a timelock and a nominated beneficiary, and no scenario
  in the design wants "no owner". This is the same one-sided trade Pass 2 identified for
  `RevenueRouter.renounceOwnership` (SI-005), and the two should be fixed together as one decision
  about the wrapper's override surface — which is precisely the fusion question Pass 2's registry
  agent handed to Stage 3.

*Option B.* Also override `transferOwnership` to two-step.
- *Prevents:* the wrong-address case.
- *Creates:* a wallet that behaves differently from every other `VestingWallet` an integrator has
  seen, and a second state (`pendingOwner`) that the factory registry does not record — which is the
  same shape as SI-011 (Pass 2: a pending nomination that cannot be cancelled). **Lower value than
  A, and it introduces the coupling A does not. Ship A first and decide B separately.**

---

### F-07 — `StakedGovToken` inherits a live approval surface on a token that can never be transferred

**Severity: LOW / INFO** · **NEW**
**Verification: Method B — `test_FP311_stGovKeepsALiveApprovalSurfaceOnANonTransferableToken`, PASS.
Level 4.**

`StakedGovToken._update` reverts `NonTransferable` for any transfer between two non-zero addresses
(`StakedGovToken.sol:176-184`). `approve`, `allowance`, `permit`, `DOMAIN_SEPARATOR` and
`eip712Domain` are all inherited unchanged and all work.

```
staker.approve(spender, 1_000e18)   -> true, and allowance(VOTER, spender) == 1_000e18
staker.transferFrom(...)            -> NonTransferable
staker.transfer(...)                -> NonTransferable
```

No value is at risk: `withdrawTo` burns from `_msgSender()` only, so no allowance path exists into
the wrapper (checked). The cost is integrator-facing — a front end or router that performs the
standard approve-then-pull dance will succeed at approve, sign a `permit`, and fail at the transfer.
`permit`, `DOMAIN_SEPARATOR` and `eip712Domain` appear **zero** times in the repository, so nothing
in the project relies on them either.

**Fix.** Override `approve`, `permit` (and optionally `transferFrom`) to revert `NonTransferable`,
matching `_update`.
- *Prevents:* a signature or allowance that can never be used.
- *Creates:* `permit` reverting is a deviation from ERC-2612 for a token that already deviates from
  ERC-20; some tooling probes `DOMAIN_SEPARATOR` to decide whether a token is permit-capable and
  would now see a capable token that refuses. **Marginal either way — this is a documentation
  candidate at least as much as a code change.**

---

### F-08 — Where value can arrive, and what `updateTimelock` therefore orphans

**Severity: INFO** · **EXTENDS SI-001's orphan list** · **Verification: Method B —
`test_FP312_governorRefusesValueButTheTimelockAcceptsItAndUpdateTimelockOrphansIt`, PASS. Level 4.**

A **checked negative** and one addition:

```
send 1 ETH to the Governor  -> REVERTS (Governor.receive requires _executor() == address(this);
                                        Governor.sol:83-85. Same for onERC721Received and
                                        onERC1155*Received, Governor.sol:675/686/703.)
send 1 ETH to the Timelock  -> ACCEPTED (TimelockController.sol:155, receive() payable {})
one proposal: governor.updateTimelock(T_new)
  T_old.balance == 1 ether        <- stays behind
  T_new.balance == 0
```

So the Governor is correctly sealed against stray value — worth stating positively — while the
timelock accepts ETH and, via `ERC721Holder`/`ERC1155Holder`, NFTs. SI-001's "assets held by the
timelock" therefore includes native currency and tokens the DAO may have been airdropped or sent,
none of which appear in `deployments[i]` and none of which any migration path enumerates.

---

## 4. What can and cannot be repaired after launch, and by whom

The assignment's question 4. Every row was established either by execution at L4 or by an explicit
grep for the negative; the method is named in the last column.

| broken thing | who can repair it | how | when it becomes impossible | evidence |
|---|---|---|---|---|
| Governor lost `PROPOSER` on its timelock | the timelock (its own `DEFAULT_ADMIN`) | proposal → `grantRole` | **immediately** — the only proposer is the Governor, so there is nobody left to propose | L4, `test_FP306` / SI-001e |
| the DAO wants an external admin back | the timelock | proposal → `grantRole(DEFAULT_ADMIN_ROLE, X)` | **as soon as governance stops working** — this is a *repair-in-advance* only | trace + L4 role assertions |
| a hostile second proposer | the timelock | proposal → `revokeRole` | as soon as the grantee evicts the Governor (2 days, unilaterally) | **L4, `test_FP306`** |
| `RevenueRouter._owner` after `updateTimelock` | the old timelock, driven by `relay` | proposal → `relay` → `schedule` → open-`EXECUTOR` execute | when the destination timelock does not grant the Governor `PROPOSER` | **L4, `test_FP309` + control** |
| `RevenueRouter.treasury` | **NOBODY, at any privilege level** | — | **always** | **L4 + negative grep, `test_FP308`** |
| the lender's `operator` role | **NOBODY** — the router deliberately cannot re-nominate (`RevenueRouter.sol:13-15`) | — | **always** | Pass 2 SI-003/SI-005; ABI |
| `StakedGovToken.revenueRouter` | **NOBODY** — no setter and the contract has no owner | — | **always** | Pass 2 SI-003 (ABI-verified) |
| `StakingRewards.rewardsDistribution` | **NOBODY** — owner renounced at `CoinDAOFactory.sol:488` | — | **always** | Pass 2 VN-B |
| a vesting wallet's owner | the current owner, single-step | `transferOwnership` | after `renounceOwnership`, or if the owner cannot transact | **L4, `test_FP310`** |
| `factory.deployments[i]` | **NOBODY** — push-only, no `delete`, no `.pop()` | — | **always** | Pass 2 SI-007, re-grepped |
| votingDelay / votingPeriod / proposalThreshold / quorumNumerator / minDelay set to a fatal value | **NOBODY** | the repair needs a proposal that can no longer be created, voted, or queued | **always** | **L4, `test_FP301`–`FP305`** |

**The one-line summary.** The factory's `renounceRole` at `CoinDAOFactory.sol:430` is correct and
deliberate — it removes the factory as a standing backdoor over every DAO it launches. Its
consequence is that **the passed proposal is the system's single point of failure**, and this pass
counts nine inherited, undocumented, untested one-proposal actions that destroy it.

---

## 5. Hypotheses tested and REFUTED, and checked negatives

Recorded so no later pass re-derives them. **A refutation is a claim too**, so each was checked by
hand or by execution rather than by assumption.

| # | hypothesis | how it was killed | verdict |
|---|---|---|---|
| R-1 | The clones inherit the **non-upgradeable** `ReentrancyGuard`, whose constructor never runs, so `_status` starts at `0` and may collide with a namespaced-storage variable or leave the guard disabled | Read `lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol:50-59,95-113`. In **5.6.1** the guard uses an **ERC-7201 namespaced slot**, not slot 0, and the entry check is `_status == ENTERED(2)`, so `0` behaves as `NOT_ENTERED`. No collision, no bypass. | **NOT A FINDING** — but version-dependent; a downgrade below the namespacing change would reintroduce it |
| R-2 | The Governor can be sent ETH or NFTs and then has no way to move them without `relay` | `Governor.receive`, `onERC721Received`, `onERC1155Received`, `onERC1155BatchReceived` all revert `GovernorDisabledDeposit` while `_executor() != address(this)` (`Governor.sol:83-85, 675, 686, 703`). Executed at L4 in `test_FP312`. | **NOT A FINDING** — a correctly sealed surface, worth stating positively |
| R-3 | `ERC20Wrapper.depositFor` can be called with `account == address(this)` or from the wrapper itself, breaking 1:1 backing | Both guarded in OZ v5's `depositFor` (`ERC20InvalidSender` / `ERC20InvalidReceiver`). The unbacked-GOV route that *does* exist is the factory-side one Pass 2 already found (SI-009b), not this one. | **NOT A FINDING** |
| R-4 | An implementation contract can be initialized directly, or a clone re-initialized | `_disableInitializers()` is present in all six implementation constructors (read individually); every clone is cloned and initialized with **no external call in between** (traced `CoinDAOFactory.sol:364-481` line by line); no `reinitializer` anywhere. | **NOT A FINDING** |
| R-5 | `GovToken`'s unused `ERC20Votes` surface is an oversight that could bind a future governance module to the wrong token | It is engaged **in a comment** — `novel_code.md:71-73` states the decoy explicitly and gives the reason. Per the workspace rule, a finding must engage with the comment; this one does not survive it. | **NOT A FINDING** |
| R-6 | `Governor.cancel` can reach `TimelockController.cancel` for a queued proposal, so `CANCELLER_ROLE` is live | `_validateCancel` requires `Pending` (`Governor.sol:787-789`) and `GovernorTimelockControl._cancel` only touches the timelock when `_timelockIds[id] != 0`, which is impossible while Pending. Mutually exclusive. Executed at L4. | **CONFIRMED — became F-04** |
| R-7 | `_setVotingPeriod` has an upper bound that makes F-01(c) unreachable | Read `GovernorSettings.sol:89-94`: the only rejected value is `0`. `type(uint32).max` accepted and executed at L4. | **CONFIRMED — became F-01(c)** |

**Verified negatives worth stating positively in the report:**

- **VN-P3-A** — the Governor cannot receive ETH or NFTs (R-2).
- **VN-P3-B** — no implementation or clone can be re-initialized (R-4).
- **VN-P3-C** — the reentrancy guards on the three clones are effective despite the un-run
  constructor, on this OZ version (R-1).
- **VN-P3-D** — the `updateQuorumNumerator` path is the one governance parameter with tests, a
  documented range, and a working historical-checkpoint model; `test_FP304` confirms the checkpoint
  behaviour is correct and the defect is only the range's upper end.

---

## 6. Coverage and honesty statement

- **Inherited entry points enumerated:** the full non-view ABI of all nine deployed contracts
  (`forge inspect … abi`), plus the view surface, cross-referenced against literal greps of `src/`,
  `script/`, `test/`, `plan.md` and `novel_code.md`. **§1 is the complete inventory** and is the
  direct answer to assignment question 1.
- **Unengaged state-mutating functions interrogated with the four questions:** 13 (§2), every one
  resolved.
- **Findings:** 8 raised, **8 TRUE POSITIVE, 0 FALSE POSITIVE**, 7 hypotheses refuted before
  write-up (§5). **Final: 0 CRITICAL · 4 MEDIUM · 2 LOW · 2 INFO**, plus one **refinement of a
  delivered Pass-2 finding** (F-05) that changes SI-001's reversibility claim.
- **NEW vs Pass 2:** F-01, F-02, F-03, F-04 are NEW. F-06 EXTENDS FF-003/SI-001.
  F-07, F-08 are NEW (LOW/INFO). F-05 REFINES SI-001.
- **Execution:** 14 PoC tests written, **14 PASS**; project baseline **55/55** before and after;
  full tree **69/69**. Every C/M finding is Level 4. Controls are included so the checks could have
  failed: `test_FP309control` (no PROPOSER → no recovery, the branch that makes SI-001 permanent),
  the `setVotingPeriod(0)` revert inside `test_FP303` (the guard that *does* fire), and the
  1-wei-undelegated construction in `test_FP304` (without it, quorum at 100 % is reachable and the
  finding would be false).
- **Absence claims, each by an explicit grep for the negative, never by assumption** (§1, run over
  `src/`, `script/`, `test/`, `plan.md`, `novel_code.md`): `updateTimelock`, `relay`,
  `setProposalThreshold`, `setVotingDelay`, `setVotingPeriod`, `updateDelay`, `revokeRole`,
  `getRoleAdmin`, `EXECUTOR_ROLE`, `release`, `releasable`, `vestedAmount`, `permit`,
  `delegateBySig`, `castVoteBySig`, `executeBatch`, `scheduleBatch`, `onERC721Received`,
  `supportsInterface`, `rescue`, `skim` — **all zero**. `renounceRole`, `hasRole`,
  `DEFAULT_ADMIN_ROLE`, `PROPOSER_ROLE`, `CANCELLER_ROLE`, `renounceOwnership`, `transferOwnership`
  — **exactly one hit each**, all cited inline.
- **`lib/` was read only to establish base-class surface and bounds**, at these six files:
  `governance/Governor.sol`, `governance/TimelockController.sol`,
  `governance/extensions/GovernorSettings.sol`, `governance/extensions/GovernorTimelockControl.sol`,
  `access/AccessControl.sol`, `utils/ReentrancyGuard.sol`, and
  `contracts-upgradeable/finance/VestingWalletUpgradeable.sol`. Every claim about them is cited to a
  line. Nothing under `engagements/` was read.
- **What I did NOT do.** I did not re-audit anything Pass 1 cleared. I did not rebuild the
  within-contract mutation matrices (Pass 2's agents own those). I did not verify any external
  Monolith behaviour. I did not test the vote-by-signature surface (`castVoteBySig`,
  `delegateBySig`) beyond confirming it is unengaged — it is live, permissionless and untested, and
  I am recording that as an **open lead** rather than a finding because I have no evidence of a
  defect in it.
- **Client code was not modified.** All experiments ran on a disposable copy under the session
  scratchpad. `git status --porcelain [scratch]` and `git diff --stat -- [scratch]` are both empty and
  `diff -rq [scratch] …/p3/src` is clean.

**The single most important sentence in this pass.** `novel_code.md:35-37` says the review question
is *"not the library code itself, but whether each composition uses the right parameters and
ownership handoffs."* That is exactly right — and the composition includes **every function the
library hands you that you did not think about.** This project engaged with one of six mutable
governance parameters, zero of two arbitrary-authority primitives, and none of the vesting wallets'
payout or ownership surface. `Governor.updateTimelock` was not an oversight. It was the first one
anybody looked at.
