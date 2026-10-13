# NEMESIS Pass 1 — Feynman Auditor: emissions pair

**Scope (line-by-line):**
- `[scratch]` (174 lines)
- `[scratch]` (96 lines)

**Read for cross-file context only:** `CoinDAOFactory.sol`, `GovToken.sol`, the test tree.
Not read: `[scratch]`, `engagements/`.

**Language:** Solidity 0.8.26 / Foundry, via-ir, optimizer 200.
**Execution:** available and used. PoC tree = a **copy** at
`%TEMP%/claude/c--RWG-CodeAudit/.../[scratch]` (12 audit tests added under
`test/audit/`). `[scratch]` was **not modified** — `git diff -- [scratch]`
is empty. Full suite in the copy: **67/67 pass** (55 original + 12 audit).

---

## PHASE 0 — ATTACKER'S HIT LIST (derived independently; recon read afterward)

```
+-----------------------------------------------------------------------+
| LANGUAGE: Solidity 0.8.26, EIP-1167 clones, Foundry                    |
|                                                                        |
| ATTACK GOALS                                                           |
|  1. Destroy or strand the 6,500,000 GOV Coin-staker allocation         |
|     (65% of the fixed 10,000,000 supply) so nobody can ever claim it.  |
|  2. Capture a disproportionate share of a tranche at negligible cost.  |
|  3. Freeze the funder or the rewards contract mid-schedule.            |
|  4. Extract more GOV than accrued / block another staker's principal.  |
|                                                                        |
| NOVEL CODE (highest expected bug density)                              |
|  - StakingRewardsFunder: bespoke. Four-tranche schedule whose FINAL    |
|    tranche is a raw balance sweep, gated on a foreign contract's       |
|    periodFinish. No analogue upstream.                                 |
|  - StakingRewards: 90% verbatim Synthetix. The DELTAS are the surface: |
|    pause / recoverERC20 / mutable setRewardsDuration all removed.      |
|    Removals cannot be found by reading what is there.                  |
|                                                                        |
| VALUE STORES                                                           |
|  - Funder holds GOV. ONLY outflow: fundNextTranche(). Permissionless.  |
|  - StakingRewards holds GOV (rewards). ONLY outflow: getReward() L134. |
|  - StakingRewards holds Coin/sCoin (principal). Outflow: withdraw/exit.|
|                                                                        |
| COMPLEX PATHS                                                          |
|  - factory deploy tx -> setRewardsDistribution -> fundNextTranche ->   |
|    notifyRewardAmount -> renounceOwnership, all in ONE transaction.    |
|                                                                        |
| PRIORITY ORDER                                                         |
|  1. The removals (recoverERC20 + owner) x the funder's timing gate --  |
|     appears in all four answers. Anything that fails to stream is      |
|     unrecoverable BY CONSTRUCTION.                                     |
|  2. fundNextTranche ordering and permissionlessness.                   |
|  3. The final-tranche balance sweep.                                   |
+-----------------------------------------------------------------------+
```

The recon's priority list ranked this pair 3rd. That was not treated as a constraint.

---

## PHASE 1 — FUNCTION-STATE MATRIX

> Pass 2 note: the "Writes" column is the coupling surface. Every SUSPECT below
> names its state variables explicitly.

### `StakingRewards` (storage slots 0-11; verified via `forge inspect ... storage`)

| # | Function | Vis | Guards | Reads | Writes | External calls |
|---|---|---|---|---|---|---|
| S1 | `initialize` | external | `initializer` | - | `stakingToken`, `rewardsToken`, `rewardsDistribution`, `rewardsDuration`, `Ownable._owner` | - |
| S2 | `updateReward(a)` *(modifier)* | - | - | `_totalSupply`, `rewardPerTokenStored`, `lastUpdateTime`, `rewardRate`, `periodFinish`, `_balances[a]`, `userRewardPerTokenPaid[a]`, `rewards[a]` | `rewardPerTokenStored`, `lastUpdateTime`, `rewards[a]`, `userRewardPerTokenPaid[a]` | - |
| S3 | `totalSupply` | ext view | - | `_totalSupply` | - | - |
| S4 | `balanceOf` | ext view | - | `_balances` | - | - |
| S5 | `lastTimeRewardApplicable` | pub view | - | `periodFinish` | - | - |
| S6 | `rewardPerToken` | pub view | - | `_totalSupply`, `rewardPerTokenStored`, `lastUpdateTime`, `rewardRate`, `periodFinish` | - | - |
| S7 | `earned` | pub view | - | `_balances`, `userRewardPerTokenPaid`, `rewards` + S6 | - | - |
| S8 | `getRewardForDuration` | ext view | - | `rewardRate`, `rewardsDuration` | - | - |
| S9 | `stake` | external | `nonReentrant`, `updateReward(msg.sender)` | S2 set | `_totalSupply`, `_balances[msg.sender]` + S2 set | `stakingToken.transferFrom` |
| S10 | `withdraw` | **public** | `nonReentrant`, `updateReward(msg.sender)` | S2 set | `_totalSupply`, `_balances[msg.sender]` + S2 set | `stakingToken.transfer` |
| S11 | `getReward` | **public** | `nonReentrant`, `updateReward(msg.sender)` | `rewards[msg.sender]` | `rewards[msg.sender]` + S2 set | `rewardsToken.transfer` |
| S12 | `exit` | external | **none of its own** | `_balances[msg.sender]` | via S10 + S11 | via S10 + S11 |
| S13 | `notifyRewardAmount` | external | `onlyRewardsDistribution`, `updateReward(address(0))` | `periodFinish`, `rewardRate`, `rewardsDuration` | `rewardRate`, `lastUpdateTime`, `periodFinish` + S2 set | `rewardsToken.balanceOf` |
| S14 | `setRewardsDistribution` | external | `onlyOwner` | - | `rewardsDistribution` | - |

### `StakingRewardsFunder`

| # | Function | Vis | Guards | Reads | Writes | External calls |
|---|---|---|---|---|---|---|
| F1 | `initialize` | external | `initializer` | - | `stakingRewards`, `rewardsToken`, `totalRewards` | `stakingRewards_.rewardsToken()` |
| F2 | `trancheBps` | pub pure | - | - | - | - |
| F3 | `trancheAmount` | ext view | - | `totalRewards`, own GOV balance | - | `rewardsToken.balanceOf` |
| F4 | `fundNextTranche` | external | `nonReentrant` **only** | `nextTranche`, `totalRewards`, `sr.periodFinish()`, `sr.rewardsDistribution()`, own GOV balance | `nextTranche` | `sr.periodFinish` x2, `sr.rewardsDistribution`, `rewardsToken.balanceOf`, `rewardsToken.transfer`, `sr.notifyRewardAmount` |
| F5 | `_trancheAmount` | int view | - | `totalRewards`, own GOV balance | - | `rewardsToken.balanceOf` |

### Deployment facts that bound every finding (from `CoinDAOFactory.sol`)

| fact | line |
|---|---|
| `rewardsDuration` fixed at **365 days**, immutable (no setter survives) | `CoinDAOFactory.sol:38, 441` |
| Staking allocation = 65% of the remainder = **6,500,000 GOV** at `deployerStakeBps = 0` | `CoinDAOFactory.sol:284` |
| `setRewardsDistribution(funder)` called **exactly once**, by the factory | `CoinDAOFactory.sol:486` |
| **`fundNextTranche()` is called inside the deploy transaction** | `CoinDAOFactory.sol:487` |
| **`renounceOwnership()` immediately after** -> `owner() == address(0)` forever | `CoinDAOFactory.sol:488` |

**Absence claims, grepped explicitly (per workspace rule):**
- `grep -rn "setRewardsDistribution" src/ script/` -> exactly two hits: the definition
  and the single factory call at L486. **No other caller exists.**
- `grep -n "rewardsToken\." src/StakingRewards.sol` -> `safeTransfer` at **L134 only**
  (inside `getReward`) and `balanceOf` at L159. **There is exactly one way GOV leaves
  this contract, and it pays only `rewards[msg.sender]`.**
- `grep -rni "recover|rescue|sweep|skim" src/` -> no recovery function anywhere in
  `StakingRewards`. The only "sweep" is the funder's own final tranche.

---

## PHASE 2 — LINE-BY-LINE INTERROGATION

### `StakingRewards.sol`

```
FUNCTION: initialize (L46-60)
 L50-53  require(...) x4
   Q1.1 WHY: rejects zero addresses and a zero duration.
   Q1.4 SUFFICIENT? NO on two counts, both benign in the launch path:
        (a) no check that stakingToken_ != rewardsToken_. Synthetix guards the
            equivalent hazard inside recoverERC20 -- which this port DELETED, so
            the guard's only home is gone. Factory always passes Coin/sCoin vs GOV.
        (b) no UPPER bound on rewardsDuration_. A duration > reward would truncate
            rewardRate to 0 and stream nothing. Factory hardcodes 365 days.
   -> VERDICT: SOUND for the deployed path; see FF-007 / FF-009 (LOW).
 L58    rewardsDistribution = initialOwner;
   Q1.1 WHY: gives the deployer a usable default before handoff.
   Q2.5 ORDER: creates a window (factory L441 -> L486) in which the FACTORY is the
        distributor. It never notifies in that window; the window closes in the
        same transaction. -> SOUND.

MODIFIER: updateReward (L68-76) -- marked "Identical to Synthetix original"
   Verified identical in behaviour. Ordering L69 -> L70 -> L72/73 is load-bearing:
   rewardPerTokenStored must be refreshed BEFORE lastUpdateTime is advanced, or the
   elapsed interval would be discarded. Swapping L69/L70 loses every accrual.
   Q2.1/Q2.2 -> both moves break it. -> SOUND.

FUNCTION: rewardPerToken (L94-98)
 L95    if (_totalSupply == 0) return rewardPerTokenStored;
   Q1.1 WHY: prevents division by zero.
   Q1.2 DELETE IT: division by zero -> revert -> every stake/withdraw/notify bricks.
        So it is load-bearing.
   Q1.3 WHAT EDGE MOTIVATED IT: the empty pool.
   Q1.4 SUFFICIENT for what it is TRYING to prevent? Yes for the panic.
        NOT sufficient for the VALUE question it silently answers: it makes the
        elapsed interval vanish rather than pause. Paired with L70
        (lastUpdateTime = lastTimeRewardApplicable()), the seconds that elapse with
        zero stakers are skipped, and rewardRate keeps ticking against nothing.
   -> VERDICT: SUSPECT. Touches _totalSupply, rewardPerTokenStored, lastUpdateTime,
      rewardRate. Scenario -> FF-001.
   Note: this is NOT the classic empty-pool inflation bug. Because L70 advances
   lastUpdateTime even while supply is 0, the first staker does NOT retroactively
   capture the empty interval. Checked explicitly; REFUTED as an inflation vector.

FUNCTION: earned (L101-104)
   Q5.x UNDERFLOW? rewardPerToken() - userRewardPerTokenPaid[a] can only underflow
        if rewardPerTokenStored decreases, which it never does; and
        lastTimeRewardApplicable() - lastUpdateTime can only underflow if
        lastUpdateTime > min(now, periodFinish). lastUpdateTime is written only at
        L70 (= min(now, pf)) and L162 (= now, immediately before pf = now + D).
        Both keep lastUpdateTime <= min(now, pf). -> SOUND. No underflow reachable.
   Q7.7 DUST: rewards[a] stores the truncated product while userRewardPerTokenPaid
        jumps to the full stored value, so each settle loses < 1 wei. Bounded by
        one wei per call. -> SOUND (magnitude).

FUNCTION: stake (L112-118) -- "Diff: No pause modifier"
 L113   require(amount > 0, "Cannot stake 0")
   Q1.4 SUFFICIENT? It stops the no-op, not the dust. There is NO minimum stake and
        no minimum TVL anywhere in the contract. 1 wei is a valid position and, when
        it is the only position, it earns 100% of rewardRate.
   -> VERDICT: SUSPECT. Touches _totalSupply, _balances. Scenario -> FF-003.
 L114-116  state writes BEFORE safeTransferFrom
   Q7.1 SWAP THEM (transfer first, then credit): still correct, and it would ALSO
        make the credited amount checkable against the received amount. The current
        order commits the credit before the token has moved, so `_totalSupply` is a
        claim about the token rather than a measurement of it.
   Q4.2 ASSUMES: exact-amount transfer. Documented at L14-15 as unsupported for
        fee-on-transfer/rebasing -- but the staking token is chosen at
        CoinDAOFactory.sol:433-434 from `deployment.coin` / `deployment.vault`,
        both returned by an EXTERNAL factory, and nothing validates the assumption.
   -> VERDICT: SUSPECT (assumption on external code). -> FF-008.
   Q2.1 The missing `notPaused`: with owner renounced a pause could never have been
        called anyway, so its removal is consistent, not a gap. -> engaged, SOUND.

FUNCTION: withdraw (L121-127)
   Q3.2 INVERSE PARITY vs stake: same guard set, same require shape, state before
        transfer in both. Truly symmetric. -> SOUND.
 L122   require(amount > 0, "Cannot withdraw 0")
   Q1.2 DELETE IT: nothing breaks, and exit() stops reverting for reward-only
        accounts. The guard's only real effect is to make exit() fail in that case.
   -> VERDICT: SUSPECT (LOW). Scenario -> FF-004.

FUNCTION: getReward (L130-137)
   Q6.4 reward == 0 -> silent no-op, no event. Consistent with upstream. SOUND.
   Q7.3 CALLEE AT L134: rewards[msg.sender] is zeroed at L133 BEFORE the transfer,
        and nonReentrant is active. Correct order. -> SOUND.
   THIS IS THE ONLY LINE IN THE CONTRACT THAT SENDS GOV OUT. It can only ever pay
   what accrual placed in rewards[]. Anything that never accrues has no exit.

FUNCTION: exit (L140-143)
   Q3.1 GUARD CONSISTENCY: exit() carries no nonReentrant of its own. Its two
        callees each take and release the guard in turn, with no external call
        between them. Not a gap. -> SOUND.
   Q5.2 LAST CALL: reverts when _balances == 0. -> FF-004.

FUNCTION: notifyRewardAmount (L150-165)
 L147-149 COMMENT (read before judging, as required):
   "Rewards notified while `_totalSupply == 0` stream to nobody and are permanently
    locked ... This is accepted by design -- the window between tranche funding and
    the first staker is expected to be short."
   The finding below ENGAGES with this rather than restating it: the stated premise
   is that the window is short. The launch flow makes the window OPEN in the same
   transaction that creates the staking token, when its total supply is provably
   zero, so the premise is contradicted by the caller, not by the comment.
   The second half -- "Do not add queueing here without also gating
   StakingRewardsFunder" -- is correct and is why FF-001's fix is proposed on the
   funder side, not here.
 L151   if (block.timestamp >= periodFinish)
   Q1.1 WHY: chooses between a fresh rate and a rate that folds in the unstreamed
        remainder of a live period.
   Q1.2 WHAT IF THE ELSE BRANCH NEVER RUNS: the leftover is never recycled.
   Q2.5 CAN A CALLER CHOOSE THE BRANCH? The only caller forever is the funder, and
        the funder reverts unless block.timestamp >= periodFinish (Funder L73) --
        the SAME predicate, in the same block. The else branch at L153-157 is
        therefore UNREACHABLE in every deployed instance.
   -> VERDICT: SUSPECT. Touches rewardRate, periodFinish, lastUpdateTime.
      Scenario -> FF-002.
 L159-160 require(rewardRate <= balance / rewardsDuration)
   Q1.1 WHY: upstream comment says it bounds rewardRate against overflow.
   Q1.4 SUFFICIENT as a SOLVENCY check? NO -- `balance` includes GOV already owed to
        stakers as unclaimed rewards[]. It is an overflow bound, not a solvency
        bound. It is not relied on as one here (the funder transfers first), but it
        must not be cited as proof of solvency in the report. -> SOUND-as-intended.
   Q6.2 CAN IT BRICK THE SCHEDULE? Funder transfers `amount` BEFORE notifying, so
        balance >= amount and rewardRate = amount/duration <= balance/duration
        always. PROVEN by PoC `testFunderCannotBrickTheRateCheck`. -> REFUTED.

FUNCTION: setRewardsDistribution (L168-170)
   Q3.4 EVENT PARITY: notifyRewardAmount emits, this does not. -> FF-006 (LOW).
   Q4.3 ASSUMES an owner exists. After CoinDAOFactory.sol:488 none does. This
        function is dead in every deployment. PROVEN by PoC (OwnableUnauthorized).

L172-173 COMMENT: "pause, recoverERC20, and mutable setRewardsDuration ... omitted
   because the launch flow does not depend on them."
   ENGAGEMENT: true for pause and setRewardsDuration -- with ownership renounced
   neither could be exercised, so removing them removes nothing real. It is NOT
   true for recoverERC20: the launch flow does not INVOKE it, but the launch flow
   is precisely what CREATES the stranded balance recoverERC20 would address
   (L147's own admission). "The flow does not depend on it" and "the flow does not
   produce a condition it would fix" are different claims; only the first holds.
   -> This is why FF-001 is HIGH rather than informational.
```

### `StakingRewardsFunder.sol`

```
FUNCTION: initialize (L40-47)
 L45    rewardsToken = stakingRewards_.rewardsToken();
   Q2.5 ORDERING ACROSS CONTRACTS: reads a field of a contract that may not be
        initialized yet. If the funder is initialized first, rewardsToken becomes
        address(0) and every later fundNextTranche reverts on the balanceOf decode,
        with the GOV already sent to the funder unrecoverable (no owner, no rescue).
        No `if (address(rewardsToken) == address(0)) revert ZeroAddress();` here,
        even though ZeroAddress is declared and used one line above.
   Q4.3 ASSUMES the caller ordered the two initializes correctly. The factory does
        (L441 then L448), so this is not reachable today.
   -> VERDICT: SUSPECT (LOW, unreachable in-path). Touches rewardsToken.
 L46    totalRewards = totalRewards_;
   Q4.3 ASSUMES totalRewards_ equals the GOV actually delivered. Nothing checks it;
        the balance arrives one phase later (factory L485). If they disagree, the
        published 32.5/27.5/22.5 percentages silently stop describing the schedule
        and the sweep absorbs the difference. -> exposed assumption, see FF-005.

FUNCTION: trancheBps (L55-61) + comment L49-54 (the published schedule)
   Q3.3 CONSISTENCY: trancheBps(3) returns 1_750, but _trancheAmount NEVER calls
        trancheBps(3) -- L92's condition `tranche < TRANCHE_COUNT - 1` excludes it.
        The 17.5% figure is published, asserted in the project's own test
        (StakingRewardsFunder.t.sol:33), and never used to compute anything.
   -> VERDICT: SUSPECT (LOW). -> FF-005.

FUNCTION: trancheAmount (L63-66)
   Q6.1 WHO CONSUMES THE RETURN VALUE: no on-chain consumer; it exists for readers.
        For tranche 3 it returns a LIVE BALANCE, so before the fixed tranches fire
        it reports the entire undrained allocation. -> FF-005.

FUNCTION: fundNextTranche (L68-88)
 L68    external nonReentrant  -- and nothing else.
   Q4.1 ASSUMES ABOUT THE CALLER: nothing, deliberately. Permissionless is the right
        call for a fixed schedule (it cannot be withheld). But it means the CALLER
        chooses the block in which the next 365-day period opens, and can pair that
        choice with any other action in the same transaction.
   -> VERDICT: SUSPECT. Touches nextTranche + (via notify) rewardRate, periodFinish,
      lastUpdateTime. Scenario -> FF-003.
 L70    if (tranche == TRANCHE_COUNT) revert AllTranchesFunded();
   Q5.3 TWICE IN SUCCESSION: second call hits L73 (period active) or L70. SOUND.
 L72-73 periodFinish gate
   Q1.1 WHY: serialises the tranches.
   Q5.1 FIRST CALL: periodFinish == 0, so the gate is vacuous and tranche 0 fires
        the instant the funder is asked -- which the factory does at L487, inside
        the deploy transaction. -> FF-001.
   Q4.4 TIME: no MINIMUM interval and no absolute schedule anchor. The "yearly"
        cadence is an emergent property of rewardsDuration, not an invariant here.
        A shorter rewardsDuration would compress the whole 4-year plan; nothing in
        this contract would notice. Recorded as an exposed assumption.
 L75-76 rewardsDistribution identity check
   Q1.1 WHY: fail loudly rather than transfer GOV that notify would then reject.
   Q1.2 DELETE IT: the transfer at L84 would still happen and notify would revert,
        reverting all of it. So it only improves the error. Correct but not
        load-bearing. -> SOUND.
   Q4.3 ASSUMES the identity can change. After factory L488 it cannot. SOUND.
 L78-80 amount / balance / InsufficientBalance
   Q5.2 LAST CALL: for tranche 3, amount IS the balance, so `balance < amount` is
        always false -- the check is a no-op on the final tranche, including when
        the balance is 0 (a 0-amount notify would consume the last tranche and
        reset periodFinish for a year while streaming nothing). Not reachable via
        the factory, which funds the funder exactly. -> SOUND-with-note.
 L82    nextTranche = tranche + 1;   BEFORE the two external calls
   Q7.1/Q7.4 CEI: correct and deliberate. Swapping L82 below L85 would expose the
        increment to a reentrant call. -> SOUND.
 L84-85 transfer THEN notify
   Q2.1 SWAP THEM: notify would read a balance that does not yet include `amount`
        and L160 would revert. The current order is REQUIRED. -> SOUND.
 L87    emit ... stakingRewards.periodFinish()
   Extra external read for the event only. -> SOUND (gas).

FUNCTION: _trancheAmount (L90-95)
 L92    if (tranche < TRANCHE_COUNT - 1) return (rewards * trancheBps(tranche)) / BPS;
 L93-94 COMMENT: "The final tranche sweeps any reward dust left after the fixed
        tranches." -> ENGAGED: true, and the sweep also absorbs anything DONATED to
        the funder and any mismatch between totalRewards and the delivered balance.
        The comment describes the dust case only; the view function's behaviour
        before the fixed tranches fire is not described anywhere. -> FF-005.
```

---

## PHASE 3 — CROSS-FUNCTION ANALYSIS

**1. Guard consistency (grouped by written state)**

| state written | writers | guards | verdict |
|---|---|---|---|
| `_totalSupply`, `_balances` | `stake`, `withdraw` | both `nonReentrant` + `updateReward` | consistent |
| `rewards`, `userRewardPerTokenPaid`, `rewardPerTokenStored`, `lastUpdateTime` | `updateReward` (all four entry points) | uniform | consistent |
| `rewardRate`, `periodFinish` | `notifyRewardAmount` only | `onlyRewardsDistribution` | consistent |
| `rewardsDistribution` | `setRewardsDistribution` only | `onlyOwner` (dead post-deploy) | consistent |
| `nextTranche` | `fundNextTranche` only | `nonReentrant` only | **intentionally open — see FF-003** |

No function is missing a guard its siblings have.

**2. Inverse operation parity**

| pair | validation | state | auth | events | verdict |
|---|---|---|---|---|---|
| `stake` / `withdraw` | `amount > 0` both | exact inverse | both open | both emit | symmetric |
| `notifyRewardAmount` / *(no de-notify)* | - | **one-way** | distributor | emits | **asymmetric by construction: once notified, GOV can only leave via accrual. There is no inverse.** This asymmetry is the whole of FF-001. |
| `fundNextTranche` / *(no defund)* | - | one-way | open | emits | same shape |
| `setRewardsDistribution` | - | - | `onlyOwner` | **no event** | FF-006 |

**3. State transition integrity**

`nextTranche` 0 -> 1 -> 2 -> 3 -> 4 is monotone, non-skippable, non-repeatable;
`periodFinish` only ever advances. No transition can be triggered out of order or by
an unauthorised actor. The **timing** of each transition, however, is caller-chosen
and unbounded above — that is FF-003's opening.

**4. Value flow / conservation**

```
funder GOV --(fundNextTranche)--> StakingRewards GOV --(getReward, L134 only)--> staker
```
Conservation FAILS in the middle leg. GOV entering `StakingRewards` is credited to
stakers only through `rewardPerToken()`, which returns unchanged while
`_totalSupply == 0`. GOV that arrives during a vacancy therefore enters the contract
and is never credited to anyone. Because L134 is the **only** outflow and it pays
only `rewards[]`, and because `owner() == address(0)` with no `recoverERC20`, the
uncredited remainder is **destroyed**, not merely undistributed.

---

## PHASE 4/5 — FINDINGS (verified)

| ID | Raw severity | Verification | Verdict | Final |
|---|---|---|---|---|
| FF-001 | CRITICAL | PoC x4 (Method B) | TRUE POSITIVE, downgraded | **HIGH** |
| FF-002 | MEDIUM | PoC (Method B) | TRUE POSITIVE | **MEDIUM** |
| FF-003 | HIGH | PoC (Method B) | TRUE POSITIVE, downgraded | **MEDIUM** |
| FF-004 | LOW | PoC | TRUE POSITIVE | **LOW** |
| FF-005 | LOW | PoC | TRUE POSITIVE | **LOW** |
| FF-006 | LOW | inspection | TRUE POSITIVE | **LOW** |
| FF-007 | MEDIUM | code trace | not reachable in-path | **LOW** |
| FF-008 | HIGH | PoC of consequence only | **LEAD** (precondition external) | lead |
| FF-009 | LOW | code trace | not reachable in-path | **LOW** |
| R-01..R-05 | - | see Refutations | **NOT FINDINGS** | - |

PoC file paths (in the scratchpad copy, not in the evidence tree):
`test/audit/FeynmanPass1.t.sol`, `FeynmanPass1b.t.sol`, `FeynmanPass1c.t.sol`.

---

### FF-001 — HIGH — Emission begins with a provably empty pool, and every
### unstreamed second is destroyed with no recovery path

**Module/Functions:** `StakingRewards.rewardPerToken` (L94-98),
`StakingRewards.notifyRewardAmount` (L150-165), `StakingRewardsFunder.fundNextTranche`
(L68-88), called from `CoinDAOFactory.sol:487`.

**State touched (for Pass 2):** `rewardRate`, `periodFinish`, `lastUpdateTime`,
`rewardPerTokenStored`, `_totalSupply`, and the GOV balance of `StakingRewards`.
The broken coupling is **`rewardRate` x `_totalSupply`**: the rate is set without
reference to whether any supply exists to receive it, and no later state re-links them.

**Feynman question that exposed it:**
> Q1.4 — "Is this check SUFFICIENT for what it is trying to prevent?" applied to
> `if (_totalSupply == 0) return rewardPerTokenStored;`. It is sufficient to prevent
> the division by zero. It is not sufficient to prevent the *value* consequence,
> which the line silently decides: the interval is discarded, not paused.

**Engagement with the design comment (L147-149).** The comment says this is accepted
because "the window between tranche funding and the first staker is expected to be
short." The audit's objection is not to the acceptance — it is that the *caller*
falsifies the premise. `CoinDAOFactory.sol:487` calls `fundNextTranche()` in the same
transaction that created the staking token, so the window opens at a moment when
`MockERC20(coin).totalSupply() == 0` — nobody can stake, however willing. The window
is not "expected to be short"; at genesis its minimum is bounded below by however long
the external market takes to mint its first Coin and for a holder to find the pool.

**Verification (Method B, four passing PoCs):**

`testFF001_StreamStartsAtGenesisWithZeroStakers` — immediately after `factory.deploy`:
```
tranche0 amount   : 2,112,500 GOV      (32.5% of the 6,500,000 allocation)
rewardRate wei/s  : 66,986,935,565,702,688
burn per day GOV  : 5,787
totalSupply()     : 0        (asserted)
coin.totalSupply(): 0        (asserted -- nobody CAN stake)
periodFinish      : now + 365 days (asserted)
```

`testFF001_LaunchDelayBurnIsPermanent` — 90-day launch delay, then a single staker
holds through all four tranches to the end:
```
staking allocation: 6,500,000 GOV
sole staker got   : 5,979,109.58 GOV
stranded in SR    :   520,890.41 GOV   == rewardRate * 90 days  (assertApproxEqRel 1e12)
                                        = 8.01% of the allocation, 5.2% of total supply
owner()                      == address(0)                       (asserted)
setRewardsDistribution(...)  reverts OwnableUnauthorizedAccount   (asserted)
funder GOV balance           == 0, nextTranche == 4               (asserted)
funder.fundNextTranche()     reverts AllTranchesFunded            (asserted)
```

`testVacancyCompoundsAcrossTranches` — a 30-day vacancy at genesis *and* at each of
the three tranche boundaries (the boundaries are the natural moment for stakers to
leave, since the stream has visibly stopped):
```
stranded forever  : 534,246.57 GOV  = 8.21% of the allocation
analytic check    : 534,246.57 GOV  = (6,500,000 * 30 days) / 365 days
```
The loss is exactly `vacancy_fraction x whole allocation`, because every tranche loses
the same fraction of itself.

**Resolution of the green check** (`testControl_NoVacancyStrandsNothing`): with the
first stake in the same second the deploy ends, the identical measurement returns
**71,840,000 wei** (7.2e-11 GOV) of pure integer-division dust. The measurement
therefore discriminates a vacancy of roughly one second (~6.7e16 wei); it is not a
tautology.

**Why the code fails.** Three independently reasonable decisions compose into a
one-way valve:
1. `rewardPerToken()` freezes accrual at zero supply but `updateReward` still advances
   `lastUpdateTime`, so the empty interval is skipped rather than deferred.
2. `notifyRewardAmount`'s leftover-rollover branch cannot recycle it (FF-002).
3. `recoverERC20` was removed and `owner()` renounced, so nothing can move it.
Any **one** of the three being different would make the loss temporary.

**Impact.** A launch-day GOV burn of 5,787 GOV/day (0.058% of total supply per day),
recurring at each tranche boundary, with no ceiling other than the tranche size and
no operator, governance, or timelock action able to reverse it. At 90 days it is
520,890 GOV of the community-incentive allocation, permanently removed from
circulation without ever reaching a staker.

**Suggested fix — and BOTH failure modes priced (this is a hypothesis, not a patch):**

The fix belongs in the funder, exactly as L149 instructs. Add a first-staker gate to
`fundNextTranche` for tranche 0 only:
```solidity
// in fundNextTranche, before computing amount:
if (tranche == 0 && stakingRewards.totalSupply() == 0) revert NoStakersYet();
```
and remove the `fundNextTranche()` call from `CoinDAOFactory.sol:487`, leaving the
first tranche to be opened permissionlessly once real TVL exists.

- *Failure mode this prevents:* the genesis burn above.
- *Failure mode this CREATES:* the emission start becomes dependent on someone
  bothering to call `fundNextTranche()`, and on a first staker existing. A pool with
  a 1-wei staker satisfies the gate, which hands that staker the opening seconds at
  100% weight — this fix does not solve FF-003 and slightly sharpens it, because the
  first staker now provably front-runs the notify. It also removes the property that
  a deployment is fully "live" when `deploy()` returns, which the factory's
  single-transaction design otherwise guarantees; off-chain consumers reading
  `periodFinish != 0` as "launched" would break. A minimum-TVL threshold instead of
  `> 0` prices both, at the cost of a governance parameter this contract deliberately
  does not have.

---

### FF-002 — MEDIUM — The leftover-rollover branch of `notifyRewardAmount` is
### unreachable, so undistributed emissions are never recycled

**Lines:** `StakingRewards.sol:151-157` (the `else` branch) x
`StakingRewardsFunder.sol:72-73` (the gate).

**State touched (for Pass 2):** `rewardRate`, `periodFinish`. Coupling broken:
`rewardRate` x `rewardsToken.balanceOf(StakingRewards)` — the rate is derived only
from the newly delivered amount, never from the balance actually sitting undistributed.

**Feynman question:**
> Q2.5 — "Can the ORDER in which users call this function matter? Does the function
> behave differently based on prior state?" Asked of the branch predicate, it becomes:
> *can any caller ever reach the `else` side?*

**Why it is unreachable.** `notifyRewardAmount` takes the `else` branch only when
`block.timestamp < periodFinish`. Its only permitted caller forever is the funder
(absence claim grepped above: `setRewardsDistribution` has exactly one call site, and
`renounceOwnership()` runs on the next line). The funder reverts with
`PreviousTrancheActive` unless `block.timestamp >= periodFinish` — the **same
predicate**, evaluated in the same block, one call earlier. So the `if` branch is
taken on every notify of every deployment, and `rewardRate = reward / rewardsDuration`
always.

**Verification (Method B):** `testFF002_LeftoverBranchUnreachableFromFunder` — nobody
stakes during tranche 0, then tranche 1 is funded at `periodFinish`:
```
dead tranche0     : 2,112,500 GOV  (sitting in StakingRewards, credited to nobody)
tranche1 amount   : 1,787,500 GOV
assertEq(rewardRate, tranche1 / 365 days)          <- PASSES: no leftover folded in
sole staker for all of tranche 1 receives          : 1,787,500 GOV (only tranche 1)
StakingRewards still holds >= 2,112,500 GOV afterwards
```
Resolution: had the rollover fired, `rewardRate` would have been
`(1,787,500 + 2,112,500)/365d` — a 118% difference. The check could not be more able
to fail.

**Why this matters separately from FF-001.** Synthetix's rollover is the upstream
safety valve for exactly the situation L147 admits to. The port keeps the code but
the funder's gating condition disables it, so the port has the *appearance* of the
mitigation without the mitigation. This is what turns FF-001 from "delayed" into
"destroyed".

**Suggested fix (hypothesis, both modes priced):** have the funder pass
`amount + rewardsToken.balanceOf(address(stakingRewards))`'s uncredited portion — but
`StakingRewards` exposes no "uncredited" quantity, so this cannot be computed
correctly from outside. The honest minimal alternative is to allow the funder to
notify slightly *before* `periodFinish` so the `else` branch is live.
- *Prevents:* permanent loss of unstreamed emissions.
- *Creates:* the funder would then be able to notify repeatedly within a period, and
  `nextTranche` would no longer be serialised by `periodFinish` — the exact hazard
  L149 warns about. Any fix here must re-derive the serialisation from a stored
  timestamp rather than from `periodFinish`.

---

### FF-003 — MEDIUM — No minimum TVL plus a permissionless opener lets one address
### atomically open a tranche and take it

**Lines:** `StakingRewardsFunder.fundNextTranche` (L68, no access guard) x
`StakingRewards.stake` (L113, `amount > 0` is the only size condition).

**State touched (for Pass 2):** `nextTranche`, `periodFinish`, `rewardRate`,
`lastUpdateTime`, `_totalSupply`, `_balances[attacker]`, `userRewardPerTokenPaid`.
Coupling broken: **`rewardRate` x `_totalSupply`** again, from the other side —
the per-token rate is unbounded below in the denominator.

**Feynman question:**
> Q4.6 — "What if amount = 1 (dust / minimum unit)?" combined with Q2.5 —
> "does calling first give an advantage?"

**Verification (Method B):** `testFF003_OneWeiCapturesWholeTranche` — a contract calls
`fundNextTranche()` and `stake(1)` **in one transaction** at `periodFinish`:
```
tranche1 amount   : 1,787,500.000000 GOV
captured by 1 wei : 1,787,499.999999 GOV     (sole staker for the period)
sr.totalSupply()  : 1                        (asserted)
```
The capture is not theft — anyone may stake and dilute — but the attacker chooses the
block, so no one can be staked *before* the notify, and the cost of the position is
1 wei of Coin.

**Why the severity is MEDIUM, not HIGH.** The exploit's payoff is entirely contingent
on nobody else staking for the period; any other staker dilutes pro rata from the
moment they arrive. It is a real, cheap, atomic head start on a 1,787,500 GOV stream,
and the mirror image of FF-001 (the same missing TVL condition produces either total
burn at TVL=0 or total capture at TVL=1 wei), but it is not a drain.

**Suggested fix (hypothesis, both modes priced):** require a minimum
`stakingRewards.totalSupply()` before a tranche may be opened.
- *Prevents:* both the empty-pool burn and the dust capture.
- *Creates:* a liveness hazard — if TVL ever falls below the threshold at a tranche
  boundary, the schedule stalls, and with no owner nobody can lower it. A stalled
  tranche is recoverable (it is only delayed) whereas a burned one is not, so this
  trade is probably worth making, but the threshold becomes an unchangeable constant
  chosen before the market exists.

---

### FF-004 — LOW — `exit()` reverts for an account with rewards but no stake

**Lines:** `StakingRewards.sol:140-143` x `L122`.
**State touched:** `_balances[a]`, `rewards[a]`.
**Verification:** `testFF004_ExitRevertsForRewardOnlyAccount` — after a full
`withdraw`, `earned(alice) > 0` and `exit()` reverts with `Cannot withdraw 0`;
`getReward()` succeeds. Behaviour is identical to upstream Synthetix; UX only, no
value at risk (`getReward()` is always available).

### FF-005 — LOW — `trancheBps(3)` is dead and `trancheAmount(3)` reports a live balance

**Lines:** `StakingRewardsFunder.sol:59`, `L63-66`, `L90-95`; schedule comment L49-54.
**State touched:** `totalRewards`, funder GOV balance.
**Verification:** `testFF005_FinalTrancheViewIsNotThePublishedSchedule`
```
totalRewards       : 6,500,000 GOV
published 17.5%    : 1,137,500 GOV   (what trancheBps(3) implies, and what the
                                      project's own test asserts at line 33)
trancheAmount(3)   : 4,387,500 GOV   (what the view actually returns pre-tranches)
```
3.86x overstated before the fixed tranches fire, and a 1,000 GOV donation to the
funder moves it 1:1 (asserted). `_trancheAmount` never calls `trancheBps(3)`, so the
published 17.5% is documentation with no code behind it. No value at risk; an
integrator or dashboard reading `trancheAmount(3)` gets a number that means something
different from every other tranche index.

### FF-006 — LOW — `setRewardsDistribution` emits no event
`StakingRewards.sol:168-170`. `notifyRewardAmount` emits `RewardAdded`; the function
that decides *who may notify* emits nothing (Q3.4). Matches upstream. Moot after
`renounceOwnership()`, but the omission is in the port's own surface.

### FF-007 — LOW — `initialize` does not reject `stakingToken_ == rewardsToken_`
`StakingRewards.sol:50-53`. If they were equal, `notifyRewardAmount`'s L159 balance
check would count staked principal as fundable rewards. **Not reachable**: the factory
always passes Coin/sCoin vs GOV (`CoinDAOFactory.sol:433-434, 441`). Worth recording
because Synthetix's only guard against this class lives inside `recoverERC20`, which
this port removed — the port removed a guard and did not replace it, even though the
removal is described as consequence-free.

### FF-009 — LOW — no upper bound on `rewardsDuration_`; `getRewardForDuration` under-reports
`StakingRewards.sol:53` and `L107-109`. A `rewardsDuration_` exceeding the reward
truncates `rewardRate` to 0 and streams nothing, permanently (no setter survives).
Factory hardcodes 365 days, so not reachable. Separately,
`getRewardForDuration()` = `rewardRate * rewardsDuration` under-reports the notified
amount by up to `rewardsDuration - 1` wei because of L152's truncation.

---

## FF-008 — LEAD (not a finding) — the staking token's transfer semantics are
## assumed, never verified, and the consequence is unrecoverable

**Why a lead and not a finding.** The precondition — that the external market's Coin
or sCoin shrinks balances on transfer or rebases — is a property of code outside this
audit's scope. The test tree substitutes a plain `MockERC20`, so it can neither
confirm nor refute it. Per the workspace rule, this is delivered as a lead with the
uncertainty stated rather than as a lower-severity finding.

**What IS established.** `StakingRewards.sol:14-15` documents the assumption. Nothing
enforces it: `CoinDAOFactory.sol:433-434` selects `stakingToken` from
`deployment.coin` / `deployment.vault`, both returned by the external monolith
factory, and `_validate` (`CoinDAOFactory.sol:556-565`) checks only
`deployerStakeBps` and `deployerRecipient`. `stake` credits `_totalSupply` and
`_balances` **before** the transfer (L114-116), so the credit is a claim about the
token rather than a measurement of it.

**Consequence, proven by execution** (`testDriftingStakingTokenStrandsPrincipalWithNoRecovery`,
1% fee-on-transfer mock, a fresh `StakingRewards` clone):
```
credited _totalSupply : 200.0 tokens
actual token held     : 198.0 tokens
alice withdraws 100   -> paid in full
bob withdraws 100     -> REVERTS (contract is short)
bob credited          : 100.0     bob recoverable : 98.0
```
Last-out is permanently blocked, and with `recoverERC20` removed and `owner()`
renounced there is no way to true up the books or release the remainder. Note the
sCoin option specifically: the deployment's own naming (`Staked <Coin>`) describes a
yield-bearing wrapper, and whether that wrapper grows by share price (safe here) or by
balance (unsafe here) is the whole question. **Pass 2 should resolve which.**

---

## REFUTATIONS — claims tested and found FALSE (a refutation is a claim too)

| ID | Hypothesis | How it was killed | Verdict |
|---|---|---|---|
| R-01 | Non-upgradeable `ReentrancyGuard` inherited into an EIP-1167 clone leaves `_status` uninitialised, so `nonReentrant` never fires | `testReentrancyGuardStillFiresOnAClone` — a hook-token staking asset re-enters `stake` on a real clone; the call reverts with `ReentrancyGuardReentrantCall`, and a clean stake afterwards still succeeds. Guard works. | **NOT A FINDING** |
| R-02 | First staker into an empty pool retroactively captures the whole elapsed interval (classic empty-pool inflation) | `updateReward` L70 advances `lastUpdateTime` to `lastTimeRewardApplicable()` even while `_totalSupply == 0`, so the interval is skipped, not banked. Confirmed by FF-001's numbers: the sole staker's take is exactly the allocation minus the vacancy, never more. | **NOT A FINDING** |
| R-03 | The funder can brick the schedule by making `require(rewardRate <= balance / rewardsDuration)` fail | `testFunderCannotBrickTheRateCheck` — all four tranches complete. Structurally: the funder transfers `amount` **before** notifying (L84 then L85), so `balance >= amount` and `amount/duration <= balance/duration` always. | **NOT A FINDING** |
| R-04 | `earned()` / `rewardPerToken()` can underflow | `rewardPerTokenStored` is monotone non-decreasing and `userRewardPerTokenPaid` is only ever set to it; `lastUpdateTime` is written only at L70 (`= min(now, pf)`) and L162 (`= now`, immediately before `pf = now + D`), so `lastUpdateTime <= lastTimeRewardApplicable()` always. Both subtractions are safe. Level 3 (reasoned, could have failed). | **NOT A FINDING** |
| R-05 | `rewardPerToken()`'s `1e18` scaling loses precision at realistic supply | With `rewardRate ~= 6.7e16` wei/s, the numerator is ~6.7e34 per second. Truncation needs `_totalSupply` of that order — ~6.7e16 whole Coin at 18 decimals. Not reachable. | **NOT A FINDING** |

---

## EXPOSED ASSUMPTIONS (input to Pass 2)

| # | Assumption | Where | Enforced? | Consequence if false |
|---|---|---|---|---|
| A1 | "The window between tranche funding and the first staker is expected to be short" | `StakingRewards.sol:148` | **NO** — the caller (`CoinDAOFactory.sol:487`) opens it at genesis | FF-001 |
| A2 | The staking token transfers exact amounts and holds balances stable | `StakingRewards.sol:14-15` | **NO** — token comes from an external factory; `_validate` does not look at it | FF-008 |
| A3 | `totalRewards_` equals the GOV actually delivered to the funder | `StakingRewardsFunder.sol:46` | **NO** — balance arrives a phase later, at `CoinDAOFactory.sol:485` | published percentages stop describing the schedule; sweep absorbs the difference |
| A4 | `StakingRewards` is initialised **before** the funder | `StakingRewardsFunder.sol:45` | **NO** in the contract; **YES** by the factory (L441 before L448) | `rewardsToken == address(0)`, funder permanently unable to fund, GOV inside it unrecoverable |
| A5 | Tranches are "yearly" | `StakingRewardsFunder.sol:50` | **NO** — cadence is `rewardsDuration`, owned by `StakingRewards` and set by the factory | a different duration silently rescales the whole 4-year plan; the funder cannot tell |
| A6 | Removing `recoverERC20` is consequence-free because "the launch flow does not depend on it" | `StakingRewards.sol:172-173` | n/a | the launch flow does not *invoke* it but does *create* the condition it would fix (`L147`) |
| A7 | An owner exists to call `setRewardsDistribution` | `StakingRewards.sol:168` | **NO** — renounced at `CoinDAOFactory.sol:488` | the function is dead in every deployment (proven) |

---

## ORDERING CONCERNS (input to Pass 2)

| # | Ordering | Verdict |
|---|---|---|
| O1 | `updateReward` L69 (`rewardPerTokenStored`) **before** L70 (`lastUpdateTime`) | **REQUIRED.** Swapping discards every accrual interval. |
| O2 | `notifyRewardAmount` modifier `updateReward(0)` **before** the body's `lastUpdateTime = now` | **REQUIRED.** The modifier settles the old period; the body opens the new one. |
| O3 | `fundNextTranche` L82 (`nextTranche++`) **before** L84/L85 (external calls) | **CORRECT CEI.** Moving it below L85 would expose the increment. |
| O4 | `fundNextTranche` L84 (transfer) **before** L85 (notify) | **REQUIRED.** Reversed, L160's balance check reverts. |
| O5 | `stake` L114-115 (credit) **before** L116 (`transferFrom`) | **WORKS but is a claim, not a measurement.** Reversing it would permit a received-amount check. Root of FF-008. |
| O6 | `getReward` L133 (zero `rewards`) **before** L134 (transfer) | **CORRECT CEI.** |
| O7 | Factory: `setRewardsDistribution` (486) -> `fundNextTranche` (487) -> `renounceOwnership` (488), all one tx | **The load-bearing ordering of the whole system.** 487 before any staker can exist is FF-001; 488 makes it irreversible. Moving 487 out of the deploy transaction is the FF-001 fix. |
| O8 | Factory: `StakingRewards.initialize` (441) **before** `Funder.initialize` (448) | **REQUIRED and unenforced** (A4). |
| O9 | Caller-chosen: `fundNextTranche()` and `stake()` in the same transaction | **EXPLOITABLE ordering** — FF-003. No contract-level ordering constraint exists between them. |

---

## SUMMARY

- Functions analysed: **19** (14 in `StakingRewards`, 5 in `StakingRewardsFunder`), plus
  1 modifier and 1 constructor each. 270 lines interrogated.
- Raw: 1 CRITICAL, 2 HIGH, 2 MEDIUM, 5 LOW.
- After verification: **8 TRUE POSITIVE, 0 FALSE POSITIVE, 3 DOWNGRADED, 5 REFUTED
  hypotheses, 1 LEAD.**
- Final: **1 HIGH (FF-001), 2 MEDIUM (FF-002, FF-003), 5 LOW, 1 LEAD (FF-008).**
- Verification level reached (workspace scale): **level 4 — executed in the real
  environment** for FF-001/002/003/004/005 and R-01/R-03, against a factory-deployed
  system, with a control run establishing the checks' resolution. FF-006/007/009 are
  level 2-3 (code trace, could have failed). FF-008's *consequence* is level 4; its
  *precondition* is unverifiable within scope and is recorded as such.
- Evidence integrity: `[scratch]` unmodified (`git diff -- [scratch]` empty);
  all PoCs live in a disposable copy; nothing was executed against any external system.

**Handoff to Pass 2.** The single coupled pair that carries FF-001, FF-002 and FF-003
is **`rewardRate` x `_totalSupply`**, mediated by `lastUpdateTime`. `rewardRate` is
written only by `notifyRewardAmount` and never consults `_totalSupply`; `_totalSupply`
is written only by `stake`/`withdraw` and never consults `rewardRate`. Nothing in the
system reconciles them, and the one-way nature of the GOV flow (single outflow at
`StakingRewards.sol:134`, no owner, no recovery) converts every moment of
inconsistency into permanent loss. The secondary pair to examine is
`StakingRewardsFunder.totalRewards` x the funder's actual GOV balance (A3), which the
final tranche's balance sweep silently reconciles without anyone being told.
