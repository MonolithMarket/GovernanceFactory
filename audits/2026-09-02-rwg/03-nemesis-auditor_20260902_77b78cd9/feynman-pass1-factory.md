# NEMESIS Pass 1 — Feynman Auditor — `CoinDAOFactory` + `DeploymentLibraries`

**Lens:** `feynman-auditor` (full pipeline, Phase 0 → Phase 5)
**Scope assigned:** `[scratch]` (564 L), `[scratch]` (60 L)
**Cross-file context read (not interrogated line-by-line):** `GovToken.sol`, `StakedGovToken.sol`,
`RevenueRouter.sol`, `StakingRewards.sol`, `StakingRewardsFunder.sol`, `CoinDAOGovernor.sol`,
`CoinDAOVestingWallet.sol`, `interfaces/*`, `test/**`, `plan.md`, `novel_code.md`
**Not read (per assignment):** `[scratch]` (vendored OpenZeppelin), `engagements/**`.
OpenZeppelin v5 behaviour was therefore established **by execution**, not by reading the library.
**Blindness:** I did not read `.audit/findings/feynman-pass1-emissions.md` or any other lens output.
The shared scratchpad already contained another agent's test files; I moved to an isolated working
tree (`[scratch]`) rather than read them.

**Execution environment.** Disposable copies of the tree at
`…/[scratch]` (PoCs) and `…/[scratch]` (ordering mutations).
`[scratch]` itself was **not modified**. Baseline: `forge test` → 55/55 green.
PoC suite: **9/9 green** (`test/audit/FeynmanPass1.t.sol`, `FeynmanPass1Handoff.t.sol`,
`FeynmanPass1Fix.t.sol`). Ordering mutations: 8 experiments, results in §5.

---

## 0. Phase 0 — Attacker's hit list (derived independently; recon read but not treated as a constraint)

```
LANGUAGE: Solidity 0.8.26 / Foundry / via-ir / optimizer 200

ATTACK GOALS
  1. Own the Timelock. It is the treasury, the RevenueRouter owner, and the only
     path to the Lender manager. Owning it owns everything downstream.
  2. Divert the GOV supply. 10,000,000 units are minted to the factory and moved
     out in five transfers inside one function. Any one of them is a target.
  3. Divert the Coin revenue stream, or make it unroutable.
  4. Leave a launch structurally broken in a way that cannot be repaired
     (the factory has three one-way privilege handoffs and no undo).
  5. Strand the external market's operator role somewhere unintended.

NOVEL CODE (highest expected bug density)
  - CoinDAOFactory._deployCoinDAO  — 8 phases, 3 one-way handoffs, 5 transfers,
    ~30 external calls, no reentrancy guard. Nothing upstream resembles it.
  - CoinDAOFactory.allocationFor   — bespoke fixed-supply arithmetic.
  - CoinDAOFactory.predict*        — CREATE2 + EIP-1167 address prediction that
    must agree with the deploy path field-for-field.
  - DeploymentLibraries            — CREATE2 executed through DELEGATECALL.

VALUE STORES TOUCHED BY THIS SCOPE
  - factory itself: holds 10,000,000 GOV between L367 and L498 of one call.
  - Timelock (treasury), 3 vesting wallets, StakingRewardsFunder, StakingRewards.
  - Lender operator role (external, irreversible once handed over).

COMPLEX PATHS
  deploy() -> monolithFactory.deploy -> _deployCoinDAO (8 phases)
  deployForExistingCoin() -> lender.acceptOperator -> _deployCoinDAO (8 phases)

PRIORITY ORDER I ACTUALLY USED
  1. Phase 3 + Phase 5 + Phase 7 of _deployCoinDAO (every one-way handoff lives there)
  2. The parameters the factory bakes into the Governor and the RevenueRouter
     (they are constants; a deployer cannot change them; governance can barely)
  3. allocationFor + the five transfers
  4. deployForExistingCoin's pre-conditions vs deploy()'s
  5. predict-vs-deploy agreement, DeploymentLibraries
```

Difference from the supplied recon: the recon's priority list is ordered by *appearance count*.
I re-ordered around **irreversibility**. The factory's distinguishing property is not that it
touches everything; it is that everything it does happens exactly once and can never be redone.

---

## 1. Phase 1 — Inventory and Function-State Matrix

### Entry points in scope

| # | Function | Vis. | Guard |
|---|---|---|---|
| 1 | `constructor` | — | none (permissionless deploy of the factory) |
| 2 | `implementations()` | external view | none |
| 3 | `deploymentsLength()` | external view | none |
| 4 | `deploymentKey(creator,userSalt)` | public pure | none |
| 5 | `predictCoinDAOAddresses(creator,userSalt,govParams)` | external view | none |
| 6 | `setPendingMonolithBeneficiary(addr)` | external | `msg.sender == monolithBeneficiary` |
| 7 | `acceptMonolithBeneficiary()` | external | `msg.sender == pendingMonolithBeneficiary` |
| 8 | `allocationFor(bps)` | public pure | input range only |
| 9 | `deploy(salt,govParams,monolithParams,manager)` | external | **none — fully permissionless** |
| 10 | `deployForExistingCoin(salt,govParams,lender)` | external | `msg.sender == lender.operator()` **and** `lender.pendingOperator() == this` |
| 11 | `_deployCoinDAO(...)` | internal | reachable only from 9 and 10 |
| 12 | `_reserveDeploymentKey` ×2, `_componentSalt`, `_validateImplementations`, `_validate` | internal | — |
| 13 | `CoreDeploymentLib.deployTimelock` / `.timelockInitCodeHash` | library external | none (DELEGATECALL) |
| 14 | `GovernorDeploymentLib.deployGovernor` / `.governorInitCodeHash` | library external | none (DELEGATECALL) |

### FUNCTION-STATE MATRIX

*(“Writes” = factory storage only. External-contract state is listed under “Foreign state written”,
because that is where every irreversible effect actually lands and is what Pass 2 needs.)*

| Function | Reads (factory storage) | Writes (factory storage) | Foreign state written | Guards | Calls out |
|---|---|---|---|---|---|
| `constructor` | — | all 6 impl immutables, `monolithFactory`, `monolithBeneficiary` | — | none | `impl.code.length` (6×) |
| `implementations()` | 6 impl immutables | — | — | none | — |
| `deploymentsLength()` | `deployments.length` | — | — | none | — |
| `deploymentKey()` | — | — | — | none | — |
| `predictCoinDAOAddresses()` | 6 impl immutables | — | — | none | `CoreDeploymentLib.timelockInitCodeHash`, `GovernorDeploymentLib.governorInitCodeHash` (DELEGATECALL) |
| `setPendingMonolithBeneficiary()` | `monolithBeneficiary` | `pendingMonolithBeneficiary` | — | current beneficiary | — |
| `acceptMonolithBeneficiary()` | `pendingMonolithBeneficiary`, `monolithBeneficiary` | `monolithBeneficiary`, `pendingMonolithBeneficiary` | — | pending beneficiary | — |
| `allocationFor()` | — | — | — | `bps <= 2000` | — |
| `deploy()` | `usedDeploymentKeys` | `usedDeploymentKeys[key]` | creates external Monolith market | none | `monolithFactory.deploy` → `_deployCoinDAO` |
| `deployForExistingCoin()` | `usedDeploymentKeys`, `hasCoinDAO` | `usedDeploymentKeys[key]` | **`lender.operator = factory`** | `operator` + `pendingOperator` | `monolithFactory.isDeployed`, `lender.{operator,pendingOperator,coin,vault,acceptOperator}` → `_deployCoinDAO` |
| `_deployCoinDAO()` | `hasCoinDAO`, `monolithBeneficiary`, all impls, `deployments.length` | **`hasCoinDAO[lender]=true`**, `deployments.push`, `deploymentKeyForId.push` | GovToken supply; Timelock role set; stGOV config; RevenueRouter config **+ ownership → Timelock**; Governor bytecode; StakingRewards config **+ ownership renounced**; Funder config **+ tranche 1 started**; 3 vesting wallets; **`lender.operator = RevenueRouter`**; 5 GOV transfers | inherited | ~30 |
| `_reserveDeploymentKey()` | `usedDeploymentKeys` | `usedDeploymentKeys[key]` | — | uniqueness | — |
| `_validateImplementations()` | — | — | — | `code.length != 0`, pairwise distinct | `EXTCODESIZE` ×6 |
| `_validate()` | — | — | — | bps ≤ 2000; recipient required if bps ≠ 0 | — |
| `CoreDeploymentLib.deployTimelock` | — | — | new `TimelockController` at CREATE2(factory, salt) | none | `CREATE2` |
| `GovernorDeploymentLib.deployGovernor` | — | — | new `CoinDAOGovernor` at CREATE2(factory, salt) | none | `CREATE2` |

**Storage the factory owns, in full:** `deployments[]`, `deploymentKeyForId[]`,
`hasCoinDAO`, `usedDeploymentKeys`, `monolithBeneficiary`, `pendingMonolithBeneficiary`.
**Never cleared, never decremented, no `delete`, no `pop`** — verified by explicit grep for the
negative (`delete `, `.pop()`, `hasCoinDAO` writes): the only write is `= true` at L359.

**Function pairs that should be symmetric:** `deploy` / `deployForExistingCoin`;
`setPendingMonolithBeneficiary` / `acceptMonolithBeneficiary`;
`predictCoinDAOAddresses` / `_deployCoinDAO`; `_reserveDeploymentKey(a,b)` / `_reserveDeploymentKey(k)`.
There is **no inverse operation for any launch step** — this is the defining asymmetry of the
contract and the source of three of the findings below.

---

## 2. Phase 2 — Line-by-line interrogation

Notation: **SOUND** / **SUSPECT** / **VULNERABLE**. Every SUSPECT carries its scenario.

---

### FUNCTION: `constructor` (L160–176)

| L | Code | Interrogation | Verdict |
|---|---|---|---|
| 165 | `if (monolithFactory_==0 \|\| monolithBeneficiary_==0) revert ZeroAddress()` | Q1.2: delete it → a factory with beneficiary 0 would burn 2% of every launch's supply into address(0) forever, and `safeTransfer(address(0))` on OZ ERC20 reverts, bricking every launch. The line protects an unrecoverable state. | SOUND |
| 166 | `_validateImplementations(implementations_)` | Q1.4 — **is this check sufficient?** It proves only *"has code"* and *"pairwise distinct"*. It does **not** prove each address is the right *type*. A transposed `stakingRewards`/`stakingRewardsFunder` pair passes here and reverts later at `initialize`; a transposed pair with compatible ABIs would not. | SUSPECT → §4 FF-12 (LOW) |
| 168–175 | assignments | Q2.3: all writes, no reads after. | SOUND |
| 175 | `monolithBeneficiary = monolithBeneficiary_` | Q4.3: assumed non-zero forever. Confirmed: the only other writer (`acceptMonolithBeneficiary`) writes `msg.sender`, and `setPendingMonolithBeneficiary` rejects zero. Invariant holds. | SOUND |

**FUNCTION VERDICT: HAS_CONCERNS** (type-blind implementation validation).

---

### FUNCTION: `predictCoinDAOAddresses` (L197–248)

| L | Interrogation | Verdict |
|---|---|---|
| 202 | `key = deploymentKey(creator,userSalt)` — Q4.1: caller supplies `creator`, so anyone can predict anyone's addresses. Is that a leak? No: `_componentSalt` is only usable by the factory itself; an attacker cannot occupy a predicted address because CREATE2/EIP-1167 both fix the deployer to the factory. **Front-running a predicted address is impossible.** | SOUND |
| 207–213 | timelock prediction args must equal L372–382 exactly. Compared field by field: `DEFAULT_TIMELOCK_DELAY`, `proposers=[]`, `executors=[address(0)]`, `admin=address(this)`. Identical. Executed check: `testPredictedDeployerVestingNeverDeployedAtZeroStake` asserts `d.timelock == pre.timelock`. | SOUND (verification level 4) |
| 222–231 | governor prediction: `governorName` built identically to L414; init-code hash from `type(CoinDAOGovernor).creationCode` in the same compilation unit as `new CoinDAOGovernor`. Executed check asserts equality. | SOUND (level 4) |
| 245–247 | `predicted.deployerVesting` computed **unconditionally**. Q2.5/Q6.1: at `deployerStakeBps == 0` the factory never deploys it (L473 guard), so the returned address is a permanent lie — a non-zero address that will never hold code. A UI that renders it, or an integrator that pre-approves it, is misled. Proven: `assertTrue(pre.deployerVesting != 0)` and `assertEq(pre.deployerVesting.code.length, 0)`. | SUSPECT → FF-08 (LOW) |
| — | Q3.3 (parameter-validation parity): `predictCoinDAOAddresses` does **not** call `_validate`. It happily predicts for `deployerStakeBps = 9999`, which `deploy()` would reject. | SUSPECT → FF-08 (LOW, same finding) |

**FUNCTION VERDICT: HAS_CONCERNS.**

---

### FUNCTION: `setPendingMonolithBeneficiary` / `acceptMonolithBeneficiary` (L250–271)

Two-step handoff, correct shape. `acceptMonolithBeneficiary` clears `pendingMonolithBeneficiary`
(L269) so a stale pending cannot be replayed. Q5.5 (self-reference): setting pending == current is
harmless. Q2.5 (ordering across users): the beneficiary can flip **between** a deployer's
`predictCoinDAOAddresses` call and their `deploy()` call, redirecting the 2% allocation — but only
the Monolith party can do that, and it is their own allocation. Recon coupling pair #14 confirmed
as a snapshot-per-deployment, which matches the test `testBeneficiaryHandoffOnlyAffectsFutureVestings`.

**FUNCTION VERDICT: SOUND.**

---

### FUNCTION: `allocationFor` (L273–290)

| L | Interrogation | Verdict |
|---|---|---|
| 274 | Q3.3: duplicates the check `_validate` already made. Redundant but the function is `public`, so it must self-guard. | SOUND |
| 278–280 | Q5.1/Q4.6 boundaries: `bps = 0` → `deployerVesting = 0`, handled by the L473/L496 guards. `bps = 2000` → 20%. Fuzzed by the project's own `testFuzzAllocationPreservesWeightsAndSupply`. | SOUND |
| 283 | `remaining = total − monolith − deployer` — Q5.2: at `bps = 2000`, remaining = 78% of supply, cannot underflow because `MONOLITH_BPS + MAX_DEPLOYER_STAKE_BPS = 2200 < 10000`. | SOUND |
| 284–287 | Two truncating divisions by `ALLOCATION_WEIGHT_TOTAL`. | SOUND |
| 289 | `treasuryVested = remaining − coinStaking − immediate`. Q1.1: **this line is the conservation invariant.** Computing treasury by subtraction (rather than by its own weight) is what guarantees `sum(parts) == GOV_TOKEN_SUPPLY` with zero dust. The comment says so. Deleting it and using `VESTED_TREASURY_WEIGHT` instead would leave up to 2 wei unallocated in the factory forever. **The line is right; the constant is the problem.** | SOUND |
| 30 | `VESTED_TREASURY_WEIGHT = 2_800` — Q1.1: *what invariant does this protect?* **None. It is read nowhere.** Verified by grep across `src/`, `script/`, `test/`: exactly one hit, the declaration. The 65:5:28 relationship it documents is enforced nowhere; `ALLOCATION_WEIGHT_TOTAL` is a hard-coded 9,800 that no assertion ties to `6500 + 500 + 2800`. | SUSPECT → FF-07 (LOW) |

**FUNCTION VERDICT: HAS_CONCERNS** (arithmetic correct; a dead constant advertises an unenforced invariant).

---

### FUNCTION: `deploy` (L292–313)

| L | Interrogation | Verdict |
|---|---|---|
| 298 | `manager == 0` rejected. Q3.3: `deployForExistingCoin` has no manager parameter at all, so no parity gap. | SOUND |
| 300 | `_reserveDeploymentKey` **before** `monolithFactory.deploy`. Q2.1 — what if moved down? A doomed launch would still create a live external market first. The current order is deliberate and the project tests it (`testReusedDeploymentKeyRevertsBeforeExternalMarketDeployment`). | SOUND — order is load-bearing |
| 303–305 | Q4.2: `monolithParams_` is entirely attacker-chosen except `operator`/`manager`. This is the permissionless design; the risk is that an arbitrary market is created bearing Monolith's factory address. Out of this scope, but recorded as an exposed assumption (§6). | SOUND-by-design |
| 307–310 | Q6.1: return values checked for zero. Contrast with L336–337. | SOUND |
| 312 | Q2.4: everything downstream reverts atomically. | SOUND |

**FUNCTION VERDICT: SOUND.**

---

### FUNCTION: `deployForExistingCoin` (L315–346)

| L | Interrogation | Verdict |
|---|---|---|
| 320 | key from `msg.sender`, so no cross-user key theft. Q2.5: front-running a competitor's key is impossible. | SOUND |
| 323 | `monolithFactory.isDeployed(lender)` — Q4.2: **this is the only thing making the lender trusted.** Every subsequent assumption about the lender's behaviour rests on it. | SOUND, but see §6 |
| 324 | `hasCoinDAO` pre-check (duplicated at L358) | SOUND |
| 327–328 | `msg.sender == lender.operator()` | SOUND |
| 330–331 | `lender.pendingOperator() == address(this)` — Q4.4: this reads a nomination made in an **earlier transaction**. Q7.6: does anything about the lender change between TX A and TX B that this check does not cover? It checks the nomination, not the lender's continued *ability* to migrate the operator role. See FF-03. | SUSPECT → FF-03 |
| 336–337 | `deployment.coin = lender.coin(); deployment.vault = lender.vault();` — Q3.3 vs L308–310: **`deploy()` zero-checks all three, this path zero-checks none.** Traced: `coin == 0` reverts downstream in `StakedGovToken.initialize` and `RevenueRouter.initialize`; `vault == 0` with `SCoin` reverts in `StakingRewards.initialize`; `vault == 0` with `Coin` **does not revert** and writes a zero vault into the permanent `deployments` record. | SUSPECT → FF-06 (LOW) |
| 341 | `lender.acceptOperator()` — Q2.4: if `_deployCoinDAO` later reverts, this reverts with it. The dev comment at L339–340 states exactly this and it is correct. | SOUND |
| 343–345 | `emit CoinDAOAttached(deployments.length - 1, …)` reads the length *after* the push in Phase 8. Q5.1 (first call): length ≥ 1 by then, no underflow. | SOUND |

**FUNCTION VERDICT: HAS_CONCERNS.**

---

### FUNCTION: `_deployCoinDAO` (L350–521) — the eight phases

#### Phase 1 (L357–361)

| L | Interrogation | Verdict |
|---|---|---|
| 358–359 | `hasCoinDAO` check-then-set **before any external call**. Q1.1: the comment says "reserve the lender before external calls" — i.e. it is a reentrancy guard, not a business check. Q1.2 (delete/move it): mutation **M7** moved the write to Phase 8; **the entire 19-test factory suite still passed.** So the guard is pure defence-in-depth and *nothing in the project's tests exercises what it protects*. The guard is correct; the coverage is not. | SOUND (untested guard, recorded in §5) |
| 361 | `allocationFor` re-validates. | SOUND |

#### Phase 2 (L363–425) — clone, deploy, initialise

| L | Interrogation | Verdict |
|---|---|---|
| 364–367 | Clone **then immediately** `initialize`. Q5.3/Q4.1: the classic uninitialised-clone hijack needs a gap between creation and init that another transaction can enter. There is none — both happen in one call frame with no untrusted callee between them. Every one of the six clone sites follows this. | SOUND |
| 367 | `govToken.initialize(name, symbol, address(this))` — mints 10,000,000 GOV **to the factory**. Q2.3: this is the first line that gives the factory value. The last line that spends it is L497. **Between L367 and L497 the factory holds the entire supply of a live token and makes ~25 external calls, one of which (L452) is to a contract it does not implement.** | SUSPECT → FF-11 |
| 370–385 | Timelock via `CoreDeploymentLib.deployTimelock` (DELEGATECALL ⇒ CREATE2 deployer is the factory). `proposers=[]`, `executors=[address(0)]` (open executor), `admin=address(this)`. Q1.3: why admin = factory? Because Phase 3 needs to grant roles; it is renounced 45 lines later. | SOUND |
| 387–394 | staker and router cloned **before** either is initialised, so each `initialize` can name the other. Q2.1: could they be initialised in the other order? `staker.initialize` needs the router address (L400) and `router.initialize` needs the staker address (L408) — the two-clones-then-two-inits shape is forced. | SOUND |
| 404–411 | `revenueRouter.initialize(lender, coin, timelock, staker, DEFAULT_GOV_STAKING_BPS, address(this))`. Q1.3: **why is `govStakingBps` hard-wired to 10,000 (=100%)?** The plan (§7) describes a split with the remainder going to the treasury; at 10,000 the remainder is always zero. The deployer cannot choose; only a later governance proposal can change it — and governance itself is bootstrapped from stGOV that does not yet exist. | SUSPECT → FF-04 |
| 414–424 | Governor via CREATE2. `GOVERNOR_PROPOSAL_THRESHOLD = supply/1000`, `GOVERNOR_QUORUM_NUMERATOR = 1` against `quorumDenominator() = 1000`. Q1.4 — **is the quorum check sufficient for what it is trying to prevent?** See FF-01: it is provably incapable of ever binding. | VULNERABLE → FF-01 |

#### Phase 3 (L427–430) — the first one-way handoff

```
timelock.grantRole(PROPOSER_ROLE, governor);
timelock.grantRole(CANCELLER_ROLE, governor);
timelock.renounceRole(DEFAULT_ADMIN_ROLE, address(this));
```

* Q1.2 — delete L430: the factory keeps `DEFAULT_ADMIN_ROLE` on **every timelock it has ever
  deployed**, forever, and could grant itself PROPOSER+EXECUTOR and drain every DAO. The line is
  the single most important line in the contract.
* Q2.1 — move L430 above the grants: mutation **M1** → `AccessControlUnauthorizedAccount`,
  20/19 tests fail. **Order is load-bearing and self-enforcing.**
* Q1.4 — is the *set* of grants sufficient? `CANCELLER_ROLE` goes only to the Governor, and the
  Governor's `cancel()` only lets the *proposer* cancel a still-Pending proposal. Verified by
  grep: no other `grantRole` anywhere in `src/`. So **there is no guardian.** `plan.md` §8 lists a
  cancel guardian as optional; the effect is that the 2-day timelock delay buys observation but no
  remedy. → FF-10, and it amplifies FF-01.

**Verdict: SOUND ordering, SUSPECT role set (FF-10).**

#### Phase 4 (L432–449) — staking pair

* L434: `stakingTokenChoice == Coin ? coin : vault`. Q4.2: enum decoding rejects out-of-range
  values at the ABI layer. SOUND.
* L441: `initialize(stakingToken, govToken, address(this), 365 days)` — sets
  `rewardsDistribution = factory` transiently and `rewardsDuration` **permanently**
  (the Synthetix `setRewardsDuration` hook is removed). SOUND but irreversible; recorded in §6.
* L448: `funder.initialize(coinStakingRewards, allocation.coinStakingRewards)` — the funder's
  `totalRewards` is fixed here and its tranche 4 sweeps `balanceOf(this)`. SOUND.

#### Phase 5 (L451–454) — the second one-way handoff

```
IMonolithLender(lender).setPendingOperator(revenueRouter);
revenueRouter.acceptLenderOperator();
revenueRouter.transferOwnership(timelock);
```

* Q2.1/Q2.2 — mutations **M2** (ownership transferred before accepting) → `OwnableUnauthorizedAccount`;
  **M3** (accept before nominating) → `Unauthorized()`. Both revert. The three-line order is tight.
* Q7.3 — **what can the callee do at L452?** The factory holds 10,000,000 GOV, `hasCoinDAO` and
  `usedDeploymentKeys` are already written, `deployments` is *not* yet written, and there is no
  `nonReentrant`. Mutation **M8** deferred this whole block until after Phase 7 and **all 19 tests
  still passed** — i.e. the current placement (external call while holding the full supply) is a
  free choice, not a requirement. → FF-11.
* Q6.1/Q6.3 — **`acceptLenderOperator()` returns nothing and its effect is never verified.**
  Grep for the negative: the only reads of `lender.operator()` in the whole tree are L327
  (the caller check) — there is **no post-condition assertion anywhere**. → FF-03.

**Verdict: SOUND ordering, VULNERABLE-if-external-contract-deviates (FF-03), SUSPECT placement (FF-11).**

#### Phase 6 (L456–481) — vesting wallets

* L457: one `vestingStart` shared by all three wallets. Q1.1: this is what makes the three
  schedules comparable. SOUND.
* L470: `monolithVesting.initialize(monolithBeneficiary, …)` reads live storage — snapshot
  semantics, matching the project's own test. SOUND.
* L472–481: `deployerVesting` created only when the allocation is non-zero, and `deployerRecipient`
  is guaranteed non-zero there by `_validate`. Q3.2 (guard parity with L496): the same
  `allocation.deployerVesting != 0` condition gates creation *and* funding. Consistent. SOUND.

#### Phase 7 (L483–498) — allocation and the third one-way handoff

```
safeTransfer(funder, allocation.coinStakingRewards);
coinStakingRewards.setRewardsDistribution(funder);
coinStakingRewardsFunder.fundNextTranche();      <-- starts the emission clock
coinStakingRewards.renounceOwnership();          <-- makes it permanent
... 4 more transfers
```

* Q2.1/Q2.2 — mutation **M4** (fund before transferring) → `InsufficientBalance(0, 2.1125e24)`;
  mutation **M5** (renounce before setting the distributor) → `OwnableUnauthorizedAccount`.
  Both revert. Order load-bearing.
* Q1.2 — **delete `fundNextTranche()` (mutation M6)**: only **2 of 19** tests fail, and both
  merely assert that tranche 1 was funded. Nothing structural depends on it. The call is therefore
  a *choice*, and it is the choice that creates FF-02.
* Q4.3 — **what does L487 assume about the current state?** It assumes someone can stake. On the
  `deploy()` path the staking token was created **in this same transaction**; its total supply is
  provably zero. Executed: `assertEq(MockERC20(d.stakingToken).totalSupply(), 0)` immediately after
  `deploy()` returns. → **FF-02 (VULNERABLE).**
* L491–493 — `immediateRecipient = deployerRecipient == 0 ? timelock : deployerRecipient`.
  Q4.1/Q5.5 — **what if the recipient is the factory, or one of the system contracts?**
  `_validate` checks only *non-zero when bps ≠ 0*. Nothing rejects `address(this)`.
  Executed: 500,000 GOV lands in the factory, which has **no token entry point at all**
  (grep for the negative: no `receive`, no `fallback`, no `.call(`, no `delegatecall`, and the only
  `safeTransfer` sites are the five fixed ones inside this function). → FF-05.
* L485/493/494/495/497 — Q3.5 / value conservation: the five amounts sum to exactly
  `GOV_TOKEN_SUPPLY` by construction of `allocationFor` (§3.4). SOUND.

#### Phase 8 (L500–520)

* `deploymentId = deployments.length` used for both pushes and both events — consistent.
  Q7.7: the two arrays are pushed in lockstep and never popped, so `deployments[i]` and
  `deploymentKeyForId[i]` cannot drift. SOUND.
* Q3.4 (event parity): `deploy()` emits `DeploymentKeyUsed` + `CoinDAODeployed`;
  `deployForExistingCoin()` emits those **plus** `CoinDAOAttached`. Deliberate and consistent.

**FUNCTION VERDICT for `_deployCoinDAO`: VULNERABLE** (FF-01 parameterisation, FF-02 emission burn),
with additional concerns FF-03, FF-04, FF-05, FF-11.

---

### FILE: `deployment/DeploymentLibraries.sol` (60 L)

| L | Interrogation | Verdict |
|---|---|---|
| 9–10 | Comment: "External library calls execute with DELEGATECALL, so CREATE2 uses the calling CoinDAOFactory as the deployer." Q1.1 — is the comment true and is it load-bearing? Both yes: `forge build --sizes` shows `CoreDeploymentLib` (7,620 B) and `GovernorDeploymentLib` (18,640 B) as **separately deployed, linked** contracts, and the executed prediction test proves the CREATE2 deployer resolves to the factory. Without DELEGATECALL every predicted address would be wrong. | SOUND |
| 19 | `new TimelockController{salt: salt}(…)` — Q6.4: Solidity ≥0.8 reverts on CREATE2 collision, so a zero address can never be returned. Salts are `keccak256(key, component)` with `key = keccak256(creator, userSalt)`; collision requires a keccak break. | SOUND |
| 28–31 | `timelockInitCodeHash` — Q3.3 (parameter parity with `deployTimelock`): argument list and order identical; both use the same `type(...).creationCode` from the same compilation unit. Verified by execution. | SOUND |
| 43 / 53–57 | Same for the Governor. `abi.encode` of the five constructor args matches the `new` site. | SOUND |
| — | Q4.1 — **who can call these?** Both libraries are `external` and unguarded. Anyone can DELEGATECALL… no: a library cannot be called with DELEGATECALL by an arbitrary contract in a way that harms the factory, because the *caller's* storage is the only storage touched, and these functions touch none. A third party calling `CoreDeploymentLib.deployTimelock` directly (CALL, not DELEGATECALL) would deploy a timelock owned by *the library*, harming nobody. | SOUND |
| — | Q4.2 — **linking assumption.** The factory's runtime bytecode embeds the two library addresses at link time. A deployment that links against a substituted library would silently receive attacker-chosen timelocks/governors. This is a deployment-integrity property, not a runtime one; recorded in §6. | SOUND-with-assumption |

**FILE VERDICT: SOUND.**

---

## 3. Phase 3 — Cross-function analysis

### 3.1 Guard consistency (grouped by state written)

| State written | Writers | Guards | Flag |
|---|---|---|---|
| `usedDeploymentKeys` | `deploy`, `deployForExistingCoin` (via `_reserveDeploymentKey` ×2) | uniqueness; key is always derived from `msg.sender` | consistent ✓ |
| `hasCoinDAO` | `_deployCoinDAO` only | check-then-set | consistent ✓ (never cleared — see FF-03) |
| `deployments` / `deploymentKeyForId` | `_deployCoinDAO` only | — | consistent ✓ |
| `monolithBeneficiary` | `constructor`, `acceptMonolithBeneficiary` | two-step | consistent ✓ |
| **Foreign: `lender.operator`** | `deployForExistingCoin` (L341), `_deployCoinDAO` (L452) | operator + pendingOperator checks | **no post-condition on either** → FF-03 |

No function is missing a guard that a sibling has. The one asymmetry is in *validation*, not
authorisation: `deploy` zero-checks `lender/coin/vault`, `deployForExistingCoin` does not (FF-06).

### 3.2 Inverse-operation parity

| Operation | Inverse | Present? |
|---|---|---|
| `setPendingMonolithBeneficiary` | `acceptMonolithBeneficiary` | ✓ complete |
| `_reserveDeploymentKey` | *release key* | ✗ — correct (keys must be one-shot) |
| `hasCoinDAO[l] = true` | *clear* | ✗ — **the load-bearing asymmetry.** A launch that completes in a broken state can never be retried (FF-03) |
| `timelock.grantRole(admin, factory)` (constructor) | `renounceRole` | ✓ and mandatory |
| `revenueRouter` ownership → timelock | migrate back | ✗ — deliberate, documented in `RevenueRouter` L13–15 |
| `lender.operator` → router | migrate | ✗ — deliberate, documented, and **verified by grep**: no `setPendingOperator` passthrough exists |
| `coinStakingRewards` ownership | — | ✗ renounced; no rescue (FF-02's amplifier) |
| GOV transferred out of the factory | recover | ✗ — no entry point exists (FF-05) |

### 3.3 State-transition integrity

The launch is a linear 8-state machine executed atomically. Every transition was probed by
mutation (§5). Findings: transitions **cannot** be skipped, reordered, or run by an unauthorised
actor — five of eight reorderings revert outright, and the two that do not (M7, M8) are
defence-in-depth placements rather than functional dependencies. The machine has **no terminal
repair state**: once Phase 1 writes `hasCoinDAO`, the lender is consumed regardless of whether
Phases 3/5/7 achieved their intended effect.

### 3.4 Value-flow conservation

```
mint     : 10,000,000 GOV -> factory                                        (L367)
out      : allocation.coinStakingRewards -> funder                          (L485)
           allocation.immediateAllocation -> deployerRecipient | timelock   (L493)
           allocation.treasuryVested      -> treasuryVesting                (L494)
           allocation.monolithVesting     -> monolithVesting                (L495)
           allocation.deployerVesting     -> deployerVesting  (iff != 0)    (L497)
```
`monolithVesting + deployerVesting + remaining == totalSupply` by construction, and
`coinStakingRewards + immediateAllocation + treasuryVested == remaining` because `treasuryVested`
is computed by subtraction. **Conservation holds exactly, with zero dust, for all
`deployerStakeBps ∈ [0, 2000]`.** The project's own fuzz test agrees. Value can leave the intended
set of recipients only through the caller's own choice of `deployerRecipient` (FF-05).

---

## 4. Findings

### FF-01 — Quorum can never exceed the proposal threshold, so it can never bind

**Severity: HIGH** · Module `CoinDAOFactory` (+ `CoinDAOGovernor`) · Lines **L33–34, L421–422**
**Verification: PoC (Method B) — `testQuorumCanNeverExceedProposalThreshold`, `testLoneProposerWithThresholdStakeCapturesTimelockTreasury`, both PASS**

**Feynman question that exposed it:** *Q1.4 — is this check SUFFICIENT for what it is trying to prevent?*

```solidity
uint256 public constant GOVERNOR_PROPOSAL_THRESHOLD = GOV_TOKEN_SUPPLY / 1_000;  // L33 = 10,000e18
uint256 public constant GOVERNOR_QUORUM_NUMERATOR   = 1;                          // L34
// CoinDAOGovernor.quorumDenominator() == 1_000
```

**Why this is wrong.** Two gates guard a proposal: you need `proposalThreshold` votes to *file*
one, and `quorum` votes must be cast for it to *pass*. They are denominated in different things.
The threshold is a fraction of the **fixed total GOV supply** — a constant 10,000e18. Quorum is a
fraction of the **staked (stGOV) supply** at the vote snapshot. stGOV is a 1:1 wrapper of GOV, so
its supply can never exceed 10,000,000e18; therefore

```
quorum = stGOVsupply/1000  ≤  10,000,000e18/1000  =  10,000e18  =  proposalThreshold
```

for **every reachable state**, with equality only if 100% of GOV were staked — impossible, since
65% sits in the emissions program and the vesting wallets cannot stake. Anyone who clears the
threshold therefore satisfies quorum *by voting for their own proposal*. The quorum parameter is
not merely low; it is **structurally incapable of ever being the binding constraint.**

`novel_code.md` does state "the absolute vote requirement falls when less GOV is staked". That
engages with the *magnitude*. It does not state the structural fact that quorum ≤ threshold
always, which is what removes the safeguard entirely.

**Evidence (executed):**
```
proposalThreshold (GOV)         : 10000.000000000000000000
quorum at 100 pct of GOV staked : 10000.000000000000000000   <- the ceiling equals the threshold
stGOV supply                    : 10000.000000000000000000
live quorum                     : 10.000000000000000000      <- 1000x below the threshold
```

**Attack scenario (executed end to end):**
1. Launch with `deployerStakeBps = 0`, `deployerRecipient = W`. W receives 500,000 GOV liquid.
2. Attacker acquires 10,000 GOV — 0.1% of supply; obtainable on the open market, from the
   immediate allocation, or from ~2 days of CoinStakingRewards emissions.
3. Attacker deposits into `StakedGovToken` and self-delegates. stGOV supply = 10,000e18,
   so `quorum = 10e18`.
4. Year 1: `treasuryVesting.release(GOV)` (permissionless) pushes **700,000 GOV** to the timelock.
5. Attacker proposes `GOV.transfer(attacker, 700_000e18)`, casts one For vote, waits out the
   36,000-block period and the 2-day timelock, executes.
6. Result: `attacker GOV after capture: 700000.0`, `timelock balance: 0`.

**Impact.** A holder of 0.1% of supply takes the treasury, the `RevenueRouter` ownership
(hence `setGovStakingBps` and the Lender `setManager` power), and every future vested release —
provided no one casts more Against votes. There is no guardian to cancel (FF-10) and the timelock
delay provides no remedy. The window is widest exactly at launch, when turnout is near zero.

**Adjudication note for the debrief.** `plan.md` §8 asks for "low initial quorum suitable for early
circulation", so a *low* quorum is intended. What is almost certainly not intended is that quorum
can never exceed the proposal threshold and therefore contributes nothing. I graded on the
structural property, not on the intent.

**Suggested fix (both failure modes priced).** Make quorum a fraction of the **fixed GOV supply**
rather than of staked supply, e.g. override `quorum(uint256)` to
`GOV_TOKEN_SUPPLY * quorumNumerator(t) / quorumDenominator()`, with the numerator set well above
`GOVERNOR_QUORUM_NUMERATOR`.
*Failure mode this prevents:* capture by a lone proposer at minimal cost.
*Failure mode this creates:* if the staked float never reaches the fixed quorum, **governance
becomes permanently unreachable** — no proposal can ever pass, including one to lower the quorum.
That is a worse failure than the current one. Any fix must therefore either (a) keep a
staked-supply floor with an absolute minimum, or (b) ship with a bootstrapping escape hatch. Do
not apply the naive fix.

**State touched (for Pass 2):** `StakedGovToken` `_totalSupply` checkpoints, `_delegateCheckpoints`;
`CoinDAOGovernor` `_quorumNumeratorHistory`; `TimelockController` role set and queued-operation
timestamps; `CoinDAOVestingWallet._erc20Released`.

---

### FF-02 — The launch starts the GOV emission clock before any staking token can exist

**Severity: MEDIUM** · Module `CoinDAOFactory` · Line **L487** (`coinStakingRewardsFunder.fundNextTranche()`)
**Verification: PoC (Method B) — `testGenesisTrancheStreamsToNobodyAndIsUnrecoverable`, PASS; plus mutation M6**

**Feynman question that exposed it:** *Q1.2 — what happens if I DELETE this line entirely?*

**Why this is wrong.** `StakingRewards` streams at a constant `rewardRate` from the moment
`notifyRewardAmount` sets `periodFinish`. While `_totalSupply == 0`, `rewardPerToken()` returns
`rewardPerTokenStored` unchanged and the next `stake()` simply advances `lastUpdateTime` to *now*.
The elapsed emission is not queued, not rolled forward, and not refundable — it is skipped. On the
`deploy()` path the staking token (Coin or sCoin) is created **in the same transaction**, so its
total supply at the moment the clock starts is provably zero: nobody in the world can stake. The
window is not "expected to be short"; it is bounded below by however long it takes to seed and
draw debt from a brand-new lending market.

**Engaging with the existing comment.** `StakingRewards.sol` L147–149 already says rewards notified
at zero supply "stream to nobody and are permanently locked" and that "this is accepted by design —
the window between tranche funding and the first staker is expected to be short." That premise is
true for tranches 2–4 (funded permissionlessly against a live market) and **false for tranche 1 on
the `deploy()` path**, because the factory forces the funding to occur before the market exists.
The finding is not "zero-supply emission is unhandled"; it is "the factory manufactures the worst
case the comment assumes away."

**Evidence (executed, `deployerStakeBps = 0`):**
```
rewardRate GOV/day                          : 5787.671232876712243200
GOV stranded by 30 idle days                : 173630.136986301367296000
GOV permanently locked in StakingRewards    : 173630.136986301439136000  (after all 4 tranches
                                                                          and a full exit)
StakingRewards.owner()                      : 0x0        (renounced at L488)
setRewardsDistribution(...)                 : reverts
```
No recovery path exists — grep for the negative over `src/` returns no `recover`, `sweep`,
`rescue`, or `withdraw`-to-owner function anywhere. At the 20% deployer stake the rate is
~4,604 GOV/day; the loss scales linearly with the idle window.

**Mutation evidence that the line is not required.** M6 removed L487 entirely; only **2 of 19**
project tests failed, both asserting the tranche had been funded. No wiring, no ownership, no
allocation depends on it.

**Suggested fix (both failure modes priced).** Drop L487 and let the already-permissionless
`fundNextTranche()` start the schedule after the market has stakers.
*Failure mode this prevents:* ~5,788 GOV/day burned from genesis (executed:
`testFirstTrancheCanBeFundedLaterByAnyone` shows a deferred first tranche loses nothing).
*Failure mode this creates:* (a) a launch can ship with emissions never started if nobody calls
the funder, so the front end must prompt it; (b) whoever calls first chooses the start instant, so
a lone dust staker can front-run it and take the full rate until others arrive — executed:
`testDeferredFundingLetsAWhaleOfOneWeiFrontRunTheStart` gives a 1-wei staker **5,787 GOV in one
day**. Note that (b) is *already* true of tranches 2–4 today, so the fix widens an existing
property rather than introducing a new one. If (b) is unacceptable, the alternative is a minimum
`_totalSupply` gate inside `fundNextTranche()`, which trades the burn for a liveness dependency.

**State touched (for Pass 2):** `StakingRewards.{rewardRate, periodFinish, lastUpdateTime,
rewardPerTokenStored, _totalSupply}`; `StakingRewardsFunder.{nextTranche, totalRewards}`;
GOV balance of `StakingRewards`. Recon coupling pairs #1, #3, #7.

---

### FF-03 — The irreversible operator handoff is never verified, and `hasCoinDAO` makes it unrepeatable

**Severity: MEDIUM** *(lead — depends on external-contract behaviour I could not verify)*
Module `CoinDAOFactory` · Lines **L358–359, L452–453**
**Verification: PoC (Method C) — `testOperatorHandoffPostconditionIsNeverAsserted`, PASS**

**Feynman question that exposed it:** *Q6.3 — what if an external call fails silently?* and
*Q6.1 — who consumes the return value?* (`acceptLenderOperator()` returns nothing.)

**Why this is wrong.** Phase 5 hands the Lender's `operator` role to the `RevenueRouter` and this
is the point of no return: `RevenueRouter` deliberately exposes no `setPendingOperator`
(verified — the only `acceptOperator` call site is `RevenueRouter` L65, and grep finds no
passthrough), so the role can never be moved again. The factory nevertheless makes the call and
proceeds without ever reading `lender.operator()` back. Grep for the negative: the **only**
`lender.operator()` read in the entire tree is L327, the caller check. Meanwhile Phase 1 has
already written `hasCoinDAO[lender] = true`, which is **never cleared** (no `delete`, no setter),
so the same lender can never be attached again.

The `IMonolithLender` interface is flagged in `novel_code.md` as "novel interface only — selectors
and parameter layouts must match the external Monolith contracts exactly". The real Monolith
contracts are not in this tree, so the assumption that `setPendingOperator`/`acceptOperator`
either succeed or revert is exactly the kind of unverified external assumption the audit should
not carry silently.

**Scenario (executed with a lender that no-ops instead of reverting once its market is immutable
— `DeployParams.timeUntilImmutability` is a real field of the interface):**
1. TX A: the incumbent operator nominates the factory while the market is mutable.
2. The market crosses its immutability deadline.
3. TX B: `deployForExistingCoin` — pre-conditions pass (the stale nomination is still recorded),
   `acceptOperator()` still works, so `operator = factory`.
4. Phase 5: `setPendingOperator(router)` is silently ignored; `acceptLenderOperator()` finds
   nothing to accept and returns.
5. **The launch reports success.** `lender.operator()` is the factory, not the router.

**Impact (all three executed):**
* `RevenueRouter.distribute()` calls `pullLocalReserves()`, which mints Coin to the *operator* —
  the factory. The factory has no token entry point, so **every unit of protocol revenue is
  permanently destroyed**. PoC: 1,000 Coin into the factory, 0 to the router, 0 to the treasury.
* Governance can never replace the Lender manager: `RevenueRouter.setManager` reverts `Unauthorized()`.
* No retry: a second `deployForExistingCoin` reverts `CoinDAOAlreadyExists`.

**Uncertainty, stated plainly.** I could not verify the real Monolith lender's behaviour — it is
not in this tree. If it reverts on every failed nomination, the transaction rolls back and this is
unreachable. The finding I am confident in regardless is the *structural* one: **the single most
irreversible step in the system has no post-condition assertion, and the state that would allow a
retry is already burned before the step runs.** Deliver as a lead, not a confirmed exploit.

**Suggested fix (both failure modes priced).** After L453 add
`if (IMonolithLender(deployment.lender).operator() != deployment.revenueRouter) revert OperatorHandoffFailed();`
The factory has 10,882 bytes of EIP-170 headroom (`forge build --sizes`), so size is not a constraint.
*Failure mode this prevents:* a silently broken launch that burns all revenue and cannot be redone.
*Failure mode this creates:* one extra external `STATICCALL` to the lender inside an already
~7.8M-gas transaction, and a launch that now reverts on a lender whose `operator()` getter is
non-standard — turning a silent success into a hard failure. That is the right trade here, but it
does make the factory strictly less tolerant of ABI drift, so it should be paired with confirming
the real Monolith ABI.

**State touched (for Pass 2):** `hasCoinDAO`; foreign `lender.{operator, pendingOperator, manager}`;
`RevenueRouter.{lender, coin}` and its Coin balance. Recon coupling pair #12.

---

### FF-04 — `DEFAULT_GOV_STAKING_BPS = 10_000` routes 100% of revenue to stGOV, and a 1-wei stake takes all of it

**Severity: MEDIUM** · Module `CoinDAOFactory` · Line **L31, L409**
**Verification: PoC (Method B) — `testDustStakerCapturesEntireRevenueAtDefaultBps`, PASS**

**Feynman question that exposed it:** *Q1.3 — what specific case motivated this value?* and
*Q4.6 — what if the amount is 1 (dust)?*

**Why this is wrong.** Every launch is hard-wired with `govStakingBps = 10_000`, so
`RevenueRouter.distribute()` computes `treasuryAmount = amount - amount = 0` whenever any stGOV
exists. `plan.md` §7 describes a *split* with the remainder going to the treasury; at 100% the
treasury never receives revenue. Only a governance proposal can change it — and governance is
bootstrapped from the same stGOV supply, so the first party to stake controls both the revenue and
the vote to redirect it.

Combined with `StakedGovToken.notifyRewardAmount`'s immediate accrual
(`rewardPerTokenStored += mulDiv(reward, 1e18, totalSupply())`), a **single wei** of stGOV present
at a distribution instant absorbs the entire distribution.

**Evidence (executed):**
```
Coin to 1-wei staker      : 1000.000000000000000000   (100% of the distribution)
Coin to timelock treasury : 0.000000000000000000
```

**Impact.** Whoever is the only stGOV holder when revenue is distributed takes all of it, at a
capital cost of 1 wei. `RevenueRouter.distribute()` is permissionless and `StakedGovToken`'s
harvest paths call it, so the attacker chooses the instant. The deployer cannot select a different
split at launch, so every CoinDAO ships in this configuration.

**Boundary of this finding.** The *mechanism* (instant accrual against the live supply) lives in
`StakedGovToken` and `RevenueRouter` and belongs to Pass 2. What belongs to the factory is that it
(a) fixes the split at the maximum, (b) offers no per-launch parameter, and (c) creates the
bootstrap ordering in which the first staker is unopposed. I have deliberately not graded the
`StakedGovToken` accrual model here.

**Suggested fix.** Make `govStakingBps` a validated launch parameter (`<= MAX_BPS`) with a default
strictly below 10,000 so the treasury is funded from day one.
*Failure mode prevented:* total revenue capture by a dust staker; a permanently unfunded treasury.
*Failure mode created:* another attacker-chosen field on a permissionless entry point, and
deployers who set it to 0 ship a stGOV token with no yield — which would make FF-01's capture
cheaper still, since nobody would stake. Bound it on both sides, not just the top.

**State touched (for Pass 2):** `RevenueRouter.govStakingBps` and its Coin balance in transit;
`StakedGovToken.{rewardPerTokenStored, userRewardPerTokenPaid, rewards, totalSupply}`.
Recon coupling pairs #4, #5, #8. **Hand to Pass 2.**

---

### FF-05 — `deployerRecipient` is never validated, and 5% of supply can be stranded in the factory

**Severity: LOW** · Module `CoinDAOFactory` · Lines **L491–493**, `_validate` **L556–563**
**Verification: PoC (Method B) — `testImmediateAllocationCanBeStrandedInTheFactory`, PASS**

**Feynman question:** *Q5.5 — what if the function is called with the system itself as a parameter?*

`_validate` checks only that `deployerRecipient != 0` when `deployerStakeBps != 0`. Nothing rejects
`address(this)` or any predicted component address. Executed with `deployerRecipient = factory`:
**500,000 GOV** lands in the factory and stays there. Verified by grep that the factory has no
`receive`, no `fallback`, no `.call(`, no `delegatecall`, and only five fixed `safeTransfer`
destinations — there is no way out, ever, for anyone. The same one-shot mistake sends the
allocation into `treasuryVesting`, `staker`, or the funder if those predicted addresses are used.

Self-inflicted, no attacker gain, hence LOW — but it is a permissionless, unsimulated, irreversible
entry point where a single bad field costs 5% of a token's supply.

**Suggested fix.** Reject `deployerRecipient == address(this)` in `_validate`.
*Prevented:* the most likely stranding case. *Created:* nothing meaningful; note that it cannot
catch the predicted-component cases, since those addresses are not known until Phase 6.

---

### FF-06 — `deployForExistingCoin` omits the zero-address checks `deploy` performs

**Severity: LOW** · Lines **L336–337** vs **L308–310**
**Verification: code trace (Method A)**

*Q3.3 — same parameters, different validation ⇒ one of them is wrong.* Traced every consequence:
`coin == 0` reverts in `StakedGovToken.initialize` and `RevenueRouter.initialize`;
`vault == 0` with `SCoin` reverts in `StakingRewards.initialize` ("Staking token cannot be 0");
`vault == 0` with `Coin` **does not revert** and writes a zero `vault` into the permanent
`deployments` record that indexers and front ends read. Mitigated downstream in two of three cases,
hence LOW, but the mitigations live in three different contracts and none of them is the check the
sibling path performs locally.

---

### FF-07 — `VESTED_TREASURY_WEIGHT` is dead, and the 65:5:28 invariant is asserted nowhere

**Severity: LOW** · Line **L30**
**Verification: grep for the negative — one hit in `src/`, `script/`, `test/`: the declaration.**

*Q1.1 — what invariant does this line protect?* None. `allocationFor` derives the treasury share by
subtraction (correctly — that is what makes the supply fully allocated), so the constant is never
read. Nothing ties `ALLOCATION_WEIGHT_TOTAL = 9_800` to
`COIN_STAKING_REWARDS_WEIGHT + IMMEDIATE_ALLOCATION_WEIGHT + VESTED_TREASURY_WEIGHT`. A future edit
to any one weight would silently shift the difference into the treasury with no test failing.
Add `assert`/`require` or a compile-time check tying the four constants together, or delete the
unused one.

---

### FF-08 — `predictCoinDAOAddresses` predicts a `deployerVesting` that is never deployed, and skips `_validate`

**Severity: LOW** · Lines **L197–247**, esp. **L245–247**
**Verification: PoC — `testPredictedDeployerVestingNeverDeployedAtZeroStake`, PASS**

At `deployerStakeBps == 0` the prediction returns a non-zero address with no code, because L473
skips creating that clone. Executed: `d.deployerVesting == address(0)` while
`pre.deployerVesting != address(0)` and `pre.deployerVesting.code.length == 0`. The function also
never calls `_validate`, so it happily predicts for parameter sets `deploy()` would reject.
Return `address(0)` when the allocation is zero, and mirror `_validate`.

---

### FF-09 — Governance timings are block counts; they are wrong on any chain that is not ~12s

**Severity: LOW (informational)** · `CoinDAOGovernor` L22–23, consumed via the factory's Governor deployment
**Verification: code inspection + grep for the negative**

`DEFAULT_VOTING_DELAY_BLOCKS = 7_200` and `DEFAULT_VOTING_PERIOD_BLOCKS = 36_000` equal 1 day and
5 days *only at 12s/block*, matching `plan.md` §8. Neither `StakedGovToken` nor `GovToken`
overrides `clock()`/`CLOCK_MODE()` — verified by grep, zero hits in `src/` — so the Governor
counts block numbers. On a 2s L2 the same constants give a 4-hour delay and a 20-hour vote, while
`DEFAULT_TIMELOCK_DELAY` stays at a wall-clock 2 days. This shortens the very window in which
opposition to an FF-01 capture would have to organise. Either override `clock()` to timestamps or
make the block counts a constructor parameter.

---

### FF-10 — No cancel guardian; the timelock delay buys observation but no remedy

**Severity: LOW (amplifier for FF-01)** · Line **L429**
**Verification: grep for the negative — `grantRole` appears exactly twice in `src/`, both at L428–429.**

`CANCELLER_ROLE` is granted only to the Governor, and `Governor.cancel()` lets only the *proposer*
cancel a still-Pending proposal. So a malicious queued operation can be cancelled by nobody but its
author. `plan.md` §8 lists a 12-month cancel guardian as optional; the consequence of omitting it is
that the 2-day `DEFAULT_TIMELOCK_DELAY` provides visibility with no available action. Consider
granting `CANCELLER_ROLE` to a launch-time guardian address that expires by governance vote.

---

### FF-11 — The lender call in Phase 5 happens while the factory holds the entire GOV supply, with no reentrancy guard

**Severity: LOW (informational — no exploit found)** · Lines **L452**, `deploy`/`deployForExistingCoin` signatures
**Verification: mutation M8 (level 4) + code trace for the exploit search (level 2)**

*Q7.3 — what can the callee do with the current state at this exact moment?* At L452 the factory
holds 10,000,000 GOV, `hasCoinDAO` and `usedDeploymentKeys` are written, `deployments` is not, and
neither entry point is `nonReentrant` (verified by grep: no `ReentrancyGuard` import in the
factory). Mutation **M8** deferred the whole Phase-5 block until after Phase 7 and all 19 tests
passed, proving the current placement is a free choice rather than a dependency.

I searched for an exploit and did not find one: the factory exposes no token entry point, so a
reentrant lender cannot move the held GOV; a nested `deploy()` would run under the lender's own
`msg.sender` and produce an independent, harmless launch; and the ID/array pushes stay consistent
because the nested push completes before the outer one. **This is an absence claim and I am
stating its strength honestly: I traced the reachable surface, I did not exhaustively prove
unreachability.** The whole vector also requires a malicious `monolithFactory`, which is immutable
and trusted at construction. Recommendation: move Phase 5 after Phase 7 (free, per M8) and/or add
`nonReentrant`, purely to shrink the window.

---

### FF-12 — Implementation validation is type-blind

**Severity: LOW** · Line **L166, L537–554**
**Verification: code inspection**

`_validateImplementations` proves only "has code" and "pairwise distinct". A mis-ordered
`Implementations` struct passes the constructor and fails much later at a clone's `initialize`,
or — for two implementations with compatible initialisers — does not fail at all. Since the factory
address is what integrators trust, consider a cheap type assertion (e.g. calling a known
`view` selector on each implementation) at construction.

---

## 5. Ordering experiments (Feynman Category 2 / Category 7 Part A)

Every phase boundary was probed by rewriting a **disposable copy** of the factory and re-running
the project's own 19-test factory suite. `[scratch]` was not touched; the original was
restored and re-verified ALL PASS at the end.

| # | Mutation | Result | What it proves |
|---|---|---|---|
| M1 | Phase 3: renounce timelock admin **before** granting Governor roles | `AccessControlUnauthorizedAccount` | The admin-renounce must be last. Order is load-bearing. |
| M2 | Phase 5: `transferOwnership(timelock)` **before** `acceptLenderOperator()` | `OwnableUnauthorizedAccount` | The factory must still own the router when it accepts. Load-bearing. |
| M3 | Phase 5: accept operator **before** nominating the router | `Unauthorized()` | Nomination must precede acceptance. Load-bearing. |
| M4 | Phase 7: `fundNextTranche()` **before** the GOV transfer to the funder | `InsufficientBalance(0, 2.1125e24)` | Funding must follow the transfer. Load-bearing. |
| M5 | Phase 7: `renounceOwnership()` **before** `setRewardsDistribution` | `OwnableUnauthorizedAccount` | The distributor must be set while still owner. Load-bearing. |
| M6 | Phase 7: **delete** `fundNextTranche()` | only 2/19 fail, both asserting the tranche was funded | **The launch-time emission start is not required.** Basis for FF-02's fix. |
| M7 | Phase 1: move `hasCoinDAO[lender] = true` after every external call | **ALL PASS** | The reentrancy reservation is pure defence-in-depth and **the project's tests never exercise what it protects.** |
| M8 | Phase 5: defer the whole operator handoff until after Phase 7 | **ALL PASS** | The external lender call's position — while the factory holds 10M GOV — is a free choice, not a dependency. Basis for FF-11. |

**Conclusion.** The eight-phase sequence is unusually well constructed: five of eight reorderings
revert immediately, which means the ordering is enforced by the code itself rather than by comment
discipline. The two that do not revert are both *placements* rather than dependencies, and both
turned into findings. The single ordering defect that survives is not a swap at all — it is the
presence of L487 at a point in time when its precondition (a staking token that anyone can hold)
is provably unsatisfiable.

---

## 6. Exposed assumptions (Category 4)

| # | Assumption | Held by | Enforced? | Consequence if false |
|---|---|---|---|---|
| A1 | `monolithFactory` returns fresh, distinct, non-zero `lender/coin/vault` | `deploy` | zero-checked (L308) but distinctness only implicitly via `hasCoinDAO` | duplicate lender reverts; identical coin/vault would produce a StakingRewards whose staking and reward tokens differ only by luck |
| A2 | `isDeployed(lender) == true` implies the lender implements `IMonolithLender` exactly | `deployForExistingCoin` | **not enforced** | FF-03 |
| A3 | `setPendingOperator` / `acceptOperator` either succeed or revert — never silently no-op | Phase 5 | **not enforced** | FF-03 |
| A4 | The staking token has holders shortly after launch | Phase 7 (L487) | **false by construction on the `deploy()` path** | FF-02 |
| A5 | stGOV supply will be large enough for quorum to mean something | Governor params | **structurally impossible** | FF-01 |
| A6 | `deployerRecipient` is an externally owned wallet the deployer controls | Phase 7 | **not enforced** | FF-05 |
| A7 | The chain produces ~12s blocks | Governor block constants | not enforced | FF-09 |
| A8 | GOV / Coin / sCoin are exact-transfer, non-rebasing ERC20s | everywhere | documented in three NatSpec blocks, not enforced | accounting drift (Pass 2 territory) |
| A9 | The six implementations are the intended contract types | constructor | only "has code" + distinct | FF-12 |
| A10 | The factory is linked against the intended `CoreDeploymentLib` / `GovernorDeploymentLib` | `DeploymentLibraries` | link-time only; both are separately deployed (7,620 B / 18,640 B) | substituted libraries would yield attacker-chosen timelocks and governors, invisibly |
| A11 | `rewardsDuration` (365 d) and the 4-tranche schedule are right forever | Phase 4 | irreversible after `renounceOwnership` | the Synthetix `setRewardsDuration` hook was removed, so no correction is possible |
| A12 | Governance can repair a bad launch | overall design | **false for `hasCoinDAO`, the operator role, and rewards ownership** | FF-02, FF-03 |

---

## 7. Verification summary

| ID | Title | Severity | Method | Verdict |
|---|---|---|---|---|
| FF-01 | Quorum can never exceed the proposal threshold | HIGH | PoC ×2 | TRUE POSITIVE |
| FF-02 | Emission clock starts before any staking token exists | MEDIUM | PoC + mutation M6 | TRUE POSITIVE |
| FF-03 | Irreversible operator handoff unverified; `hasCoinDAO` blocks retry | MEDIUM (lead) | PoC (conditional mock) + trace | TRUE POSITIVE, **conditional on external lender behaviour** |
| FF-04 | 100% default revenue split; 1 wei captures all | MEDIUM | PoC | TRUE POSITIVE (mechanism → Pass 2) |
| FF-05 | `deployerRecipient` unvalidated; 5% strandable | LOW | PoC | TRUE POSITIVE |
| FF-06 | Missing zero-checks in `deployForExistingCoin` | LOW | code trace | TRUE POSITIVE (mitigated 2 of 3 cases) |
| FF-07 | `VESTED_TREASURY_WEIGHT` dead; invariant unasserted | LOW | grep | TRUE POSITIVE |
| FF-08 | Prediction returns a never-deployed address; skips `_validate` | LOW | PoC | TRUE POSITIVE |
| FF-09 | Block-count governance timings | LOW | inspection + grep | TRUE POSITIVE |
| FF-10 | No cancel guardian | LOW | grep | TRUE POSITIVE (amplifier) |
| FF-11 | External call while holding 10M GOV; no reentrancy guard | LOW / info | mutation M8 + trace | TRUE POSITIVE as a *placement*; **no exploit found** |
| FF-12 | Type-blind implementation validation | LOW | inspection | TRUE POSITIVE |

### Hypotheses tested and REJECTED (recorded so Pass 2 does not re-derive them)

| Hypothesis | Why rejected |
|---|---|
| Predicted clone/CREATE2 addresses can be front-run and occupied | Both EIP-1167 `cloneDeterministic` and `new{salt:}` fix the deployer to the factory; an attacker cannot deploy there. Verified by execution — prediction equals deployment. |
| Deployment keys can be stolen or squatted across users | `deploymentKey` always binds `msg.sender`. The project's own `testSameSaltIsNamespacedByCreator` agrees. |
| A clone can be initialised by an attacker before the factory does | Every clone is initialised in the same call frame it is created in, with no untrusted callee between. All six sites checked. |
| `allocationFor` leaves dust or over-allocates | Treasury is computed by subtraction; the five transfers sum to exactly `GOV_TOKEN_SUPPLY` for all `bps ∈ [0,2000]`. |
| The factory retains timelock admin after a launch | L430 renounces it, and M1 proves the ordering is enforced. |
| `deployments[]` and `deploymentKeyForId[]` can drift apart | Pushed in lockstep; no `delete`, no `pop` anywhere (grep). |
| `deployForExistingCoin` can be called by a non-operator, or a dangling `pendingOperator == factory` can be seized by a third party | L328 restricts to the current operator; the factory has no other path that calls `acceptOperator`. |
| The `else` branch of `StakingRewards.notifyRewardAmount` (leftover roll-forward) is reachable from the factory flow | `fundNextTranche` refuses while `block.timestamp < periodFinish`, so every factory-driven notify takes the `>=` branch. |
| `mulDiv` overflow can brick `StakedGovToken.earned` after a dust-supply distribution | Reaching the uint256 ceiling needs ~1e53 Coin of revenue. Not claimed. |

---

## 8. Hand-off to Pass 2 — state variables each SUSPECT touches

| Finding | Factory storage | Foreign state | Recon coupling pairs |
|---|---|---|---|
| FF-01 | — (constants L33–34) | `StakedGovToken` supply + delegate checkpoints; `CoinDAOGovernor._quorumNumeratorHistory`; `TimelockController` roles + `_timestamps`; `CoinDAOVestingWallet._erc20Released` | #11 |
| FF-02 | — | `StakingRewards.{rewardRate, periodFinish, lastUpdateTime, rewardPerTokenStored, _totalSupply}`; `StakingRewardsFunder.{nextTranche, totalRewards}`; GOV balance of `StakingRewards` | #1, #3, #7 |
| FF-03 | **`hasCoinDAO`** | `lender.{operator, pendingOperator, manager}`; `RevenueRouter` Coin balance | #12 |
| FF-04 | — (constant L31) | `RevenueRouter.govStakingBps` + Coin in transit; `StakedGovToken.{rewardPerTokenStored, userRewardPerTokenPaid, rewards, totalSupply}` | #4, #5, #8 |
| FF-05 | — | GOV balance of the factory (permanently) | #13 |
| FF-06 | `deployments[i].vault` | — | #9 |
| FF-11 | `hasCoinDAO`, `usedDeploymentKeys` written; `deployments` **not yet** written at the external-call instant | `lender` | #9, #10 |

**The three questions I most want Pass 2 to answer:**
1. Can a state inconsistency be *created* during the window in FF-11 (factory holds 10M GOV,
   `deployments` not yet pushed) by any path other than a malicious lender?
2. Does `StakedGovToken`'s instant-accrual accumulator have an orphan case where an account holds a
   balance while `userRewardPerTokenPaid` is stale? I found none (every mint/burn routes through
   `updateReward`, and the token is non-transferable) — but that is an absence claim I proved only
   by reading, and FF-04 makes any such orphan enormously valuable.
3. Does the `StakingRewards` reward-rate ↔ `periodFinish` ↔ balance triple stay payable across all
   four tranches when the zero-supply windows of FF-02 have left an unclaimable surplus in the
   contract? The surplus makes the `rewardRate <= balance/duration` guard *easier* to pass, which
   is the wrong direction for a solvency check.

---

## 9. Coverage statement

* **Functions interrogated:** 14 of 14 in scope (6 external/public + 2 launch entry points +
  1 internal orchestrator + 5 internal helpers), plus 4 library functions. **100%.**
* **Lines interrogated:** all 564 of `CoinDAOFactory.sol` and all 60 of `DeploymentLibraries.sol`.
* **Verification levels reached** (per `CLAUDE.md`): level 4 (executed in a real EVM) for FF-01,
  FF-02, FF-04, FF-05, FF-08 and all eight ordering mutations; level 4 with a **substituted external
  contract** for FF-03; level 3 (a check that could have failed) for FF-06 and FF-12; level 2 with
  explicit negative greps for FF-07, FF-09, FF-10, and the absence claims in FF-03, FF-05, FF-11.
* **Absence claims, each verified by an explicit grep for the negative:** no `recover`/`sweep`/
  `rescue` in `src/`; no `delete`/`.pop()` in the factory; `hasCoinDAO` written only as `= true`;
  no `receive`/`fallback`/`.call(`/`delegatecall` in the factory; no `ReentrancyGuard` in the
  factory; `grantRole` appears exactly twice; `VESTED_TREASURY_WEIGHT` appears exactly once; no
  `clock()`/`CLOCK_MODE()` override in `src/`; the only `lender.operator()` read is L327.
* **Client code was not modified.** All experiments ran on disposable copies under the session
  scratchpad. `[scratch]` bytes are unchanged; baseline 55/55 re-verified.
