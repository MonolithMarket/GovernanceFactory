# Feynman Auditor — Pass 1 (Revenue / Staked-GOV lane)

**Skill:** `.claude/skills/feynman-auditor/SKILL.md`, Phases 0–5, executed in full.
**Scope files (line-by-line):**

| file | lines | role |
|---|---|---|
| `[scratch]` | 189 | non-transferable ERC20Wrapper + votes + instant-accrual reward accumulator |
| `[scratch]` | 99 | permanent Lender operator; pulls reserves, splits Coin |
| `[scratch]` | 16 | reward-receiver interface |
| `[scratch]` | 8 | harvest-trigger interface |

**Cross-file context read (not interrogated):** `GovToken.sol`, `CoinDAOFactory.sol` (wiring
phases 2/5 and constants), `CoinDAOGovernor.sol`, `interfaces/IMonolith.sol`,
`test/mocks/MockMonolith.sol`, `test/RevenueRouter.t.sol`, `test/StakedGovToken.t.sol`,
`plan.md` §6–§11, `novel_code.md`.
**Not read, per instruction:** `[scratch]`, `engagements/`.

**Execution environment.** The scope tree was copied to
`…/[scratch]` (the audited tree at `[scratch]` was NOT written to; its 55/55
suite was re-run there read-only and is green). PoCs live at
`…/[scratch]`, `FeynmanPass1b.t.sol`, `Mocks.sol`.
**21/21 PoC tests pass.** Every finding below carries a verification level:

- **L1** it compiles · **L2** a check passes · **L3** the check could have failed
  (a control case is included) · **L4** executed in the real environment.

---

## Phase 0 — Attacker's Hit List (derived here, independently of the recon file)

```
LANGUAGE: Solidity 0.8.26 / via-ir / optimizer 200 / Foundry. OZ 5.6.1 (per novel_code.md).

ATTACK GOALS (Q0.1)
  1. Capture Coin revenue that another staker earned (theft between stakers).
  2. Destroy or permanently strand Coin revenue (value burn, no beneficiary).
  3. Permanently block entry to staking -> permanently freeze the delegate set, since
     stGOV is the ONLY vote token and depositFor is the ONLY mint path.
  4. Redirect the revenue stream (staker share -> treasury, or out of the system).
  5. Reach a state where the reward accumulator cannot be advanced or an account
     cannot be settled (permanent DoS of harvest / withdraw).

NOVEL CODE (Q0.2)
  - StakedGovToken reward layer: Synthetix `updateReward`/`earned` shape with the
    TIME-BASED accrual amputated and replaced by instant accrual. The deltas from
    Synthetix are the whole risk surface: `notifyRewardAmount` no longer calls
    `updateReward(address(0))`, there is no `rewardRate`/`periodFinish`/`lastUpdateTime`.
  - `harvestYield` modifier: a mandatory outbound call to a foreign contract on the
    mint path. No upstream equivalent.
  - RevenueRouter: 99 lines written for this integration; holds a privileged external role.

VALUE STORES (Q0.3)
  - StakedGovToken holds GOV (wrapper backing). Out: withdrawTo / withdraw /
    harvestAndWithdraw.
  - StakedGovToken holds Coin (reward float). Out: _payReward only (verified below).
  - RevenueRouter holds Coin in transit. Out: distribute() — permissionless.
  - The external Lender's reserves are minted to the operator on pull; the router is
    the permanent operator.

COMPLEX PATHS (Q0.4)
  depositFor -> harvestYield -> RevenueRouter.distribute -> Lender.pullLocalReserves
   -> Coin.transfer -> StakedGovToken.notifyRewardAmount (RE-ENTRY into the originating
   contract) -> Coin.transfer(treasury) -> updateReward(account) -> _mint.
  One user action, four contracts, three external calls, one re-entry, three state
  writes in the originating contract. This is the deepest path in scope and it is the
  ONLY way to obtain voting power.

PRIORITY ORDER
  1. depositFor + harvestYield + notifyRewardAmount (all four goals pass through here)
  2. RevenueRouter.distribute (goals 1, 2, 4)
  3. withdrawTo / withdraw vs harvestAndWithdraw asymmetry (goal 1)
  4. setGovStakingBps / setManager / acceptLenderOperator (goal 4)
  5. initialize on both contracts (goal 5 — everything it sets is permanent)
```

---

## Phase 1 — Function-State Matrix

State variables are named exactly as declared. **Pass 2 should key off the `Writes`
column.** `ERC20$` / `Votes$` / `Wrapper$` denote OZ ERC-7201 namespaced storage
(confirmed by `forge inspect StakedGovToken storage-layout`, which shows only the five
declared slots 0–4 — the OZ upgradeable bases contribute no plain slots, and
`ReentrancyGuard._status` is not in the layout either).

### `StakedGovToken`

| Function | Vis | Guards | Reads | Writes | External calls |
|---|---|---|---|---|---|
| `initialize` | external | `initializer` | — | `rewardsToken`, `revenueRouter`, `ERC20$.name/symbol`, `Wrapper$.underlying`, EIP712 | `govToken_.decimals()` (inside `__ERC20Wrapper_init`) |
| `decimals` | public view | — | `Wrapper$.underlying` | — | `underlying.decimals()` |
| `totalSupply` | public view | — | `ERC20$.totalSupply` | — | — |
| `depositFor` | public | `nonReentrant`, `harvestYield`, `updateReward(account)` | `revenueRouter`, `rewardPerTokenStored`, `userRewardPerTokenPaid[account]`, `rewards[account]`, `ERC20$.balances[account]` | `rewards[account]`, `userRewardPerTokenPaid[account]`, `ERC20$.balances[account]`, `ERC20$.totalSupply`, `Votes$.checkpoints` | `revenueRouter.distribute()`, `GOV.transferFrom` |
| `withdrawTo` | public | `nonReentrant`, `updateReward(msg.sender)` | same, for `msg.sender` | `rewards[msg.sender]`, `userRewardPerTokenPaid[msg.sender]`, `ERC20$.balances`, `ERC20$.totalSupply`, `Votes$.checkpoints` | `GOV.transfer` |
| `withdraw` | external | (delegates) | `ERC20$.balances[msg.sender]` | via `withdrawTo` | via `withdrawTo` |
| `harvestAndWithdraw` | external | `nonReentrant`, `harvestYield`, `updateReward(msg.sender)` | as above + `rewards[msg.sender]` | as `withdrawTo` + `rewards[msg.sender]=0` | `revenueRouter.distribute()`, `GOV.transfer`, `Coin.transfer` |
| `rewardPerToken` | public view | — | `rewardPerTokenStored` | — | — |
| `earned` | public view | — | `ERC20$.balances`, `rewardPerTokenStored`, `userRewardPerTokenPaid`, `rewards` | — | — |
| `getReward` | public | `nonReentrant`, `updateReward(msg.sender)` | as `earned` | `rewards[msg.sender]`, `userRewardPerTokenPaid[msg.sender]` | `Coin.transfer` |
| `harvestAndGetReward` | external | `nonReentrant`, `harvestYield`, `updateReward(msg.sender)` | as above | as above | `revenueRouter.distribute()`, `Coin.transfer` |
| `_payReward` | internal | — | `rewards[account]` | `rewards[account]` | `Coin.transfer` |
| `notifyRewardAmount` | external | `onlyRevenueRouter` | `ERC20$.totalSupply`, `rewardPerTokenStored` | **`rewardPerTokenStored`** | — |
| `_update` | internal | — | — | `ERC20$.balances`, `ERC20$.totalSupply`, `Votes$` | — |
| `nonces` | public view | — | `Nonces$` | — | — |
| inherited: `approve`, `permit`, `delegate`, `delegateBySig`, `transfer`, `transferFrom` | public | — | — | `ERC20$.allowances`, `Votes$.delegatee`, `Nonces$` | — |

### `RevenueRouter`

| Function | Vis | Guards | Reads | Writes | External calls |
|---|---|---|---|---|---|
| `initialize` | external | `initializer` | — | `lender`, `coin`, `treasury`, `govStaking`, `govStakingBps`, `Ownable$.owner` | — |
| `acceptLenderOperator` | external | `onlyOwner` | `lender` | none (local) | `lender.acceptOperator()` |
| `distribute` | external | **none** | `lender`, `coin`, `govStaking`, `govStakingBps`, `treasury` | none (local) | `lender.pullLocalReserves()`, `coin.balanceOf`, `govStaking.totalSupply()`, `coin.transfer` ×2, `govStaking.notifyRewardAmount()` |
| `setGovStakingBps` | external | `onlyOwner` | `govStakingBps` | **`govStakingBps`** | — |
| `setManager` | external | `onlyOwner` | `lender` | none (local) | `lender.setManager()` |
| inherited `transferOwnership` / `renounceOwnership` | public | `onlyOwner` | — | `Ownable$.owner` | — |

### Absence claims — verified at L4 by enumerating the compiled ABI

`forge inspect <c> abi` was used rather than grep, because absence claims are the
dangerous ones.

- **`StakedGovToken` has exactly one mint path: `depositFor`.** The 40-function ABI
  contains no `mint`, no `recover`, no `_recover` wrapper. `ERC20WrapperUpgradeable._recover`
  is internal and is never called.
- **The only Coin outflow from `StakedGovToken` is `_payReward`.** No `sweep`, `rescue`,
  `recover`, `skim`, or owner function exists. There is no owner at all — the contract
  is `Ownable`-free.
- **`RevenueRouter` exposes no `setPendingOperator` wrapper** (the NatSpec design claim at
  L13–15 is TRUE), and also no `setTreasury`, `setGovStaking`, `setLender`, `setCoin`, and
  no token-rescue function. `renounceOwnership` IS present.
- **Non-view surface of `StakedGovToken`:** `approve, delegate, delegateBySig, depositFor,
  getReward, harvestAndGetReward, harvestAndWithdraw, initialize, notifyRewardAmount,
  permit, transfer, transferFrom, withdraw, withdrawTo`. Nothing else can change state.

### Pairs identified for Phase 3

`depositFor` ↔ `withdrawTo` · `depositFor` ↔ `harvestAndWithdraw` ·
`getReward` ↔ `harvestAndGetReward` · `withdraw` ↔ `harvestAndWithdraw` ·
`initialize`(staker) ↔ `initialize`(router) · `setGovStakingBps` ↔ `distribute`.

---

## Phase 2 — Line-by-line interrogation

Verdicts: **SOUND** / **SUSPECT** / **VULNERABLE**. Only lines where a question produced a
non-trivial answer are written out; every line was passed through the framework.

### `StakedGovToken.sol`

```
L36  uint256 public constant REWARD_PRECISION = 1e18;
  Q1.1 WHY: fixed-point scale for the accumulator, inherited from the Synthetix shape.
  Q4.2 ASSUMES: that 1e18 is an appropriate scale *for the reward token*. It is a
       constant, while the quantity it scales (`reward`, denominated in Coin) has the
       Coin's decimals, and the divisor (`totalSupply`) has GOV's 18 decimals. The
       smallest creditable reward is therefore `totalSupply / 1e18` WEI OF COIN, a
       number that has nothing to do with Coin's own precision.
  -> VERDICT: SUSPECT  (see FF-001)

L38  IERC20 public rewardsToken;
L39  IRevenueDistributor public revenueRouter;
  Q1.2 DELETE: rewards stop; harvest stops.
  Q4.3 ASSUMES: both are correct forever. There is no setter for either (L4 absence
       check). A wrong value at `initialize` time is permanent and unrepairable, and the
       contract is a clone with a one-shot initializer.
  -> VERDICT: SUSPECT  (FF-008, FF-017)

L41  uint256 public rewardPerTokenStored;
  Q1.1 WHY: monotone cumulative "Coin per stGOV, scaled 1e18".
  Q5.2 EDGE: monotone and never reset, so `rewardPerTokenStored - userRewardPerTokenPaid`
       at L141 can never underflow. Confirmed: `userRewardPerTokenPaid` is only ever
       assigned `rewardPerTokenStored` (L89), and `rewardPerTokenStored` only ever `+=`
       (L172). -> SOUND (this is the one place the monotonicity is load-bearing).

L53-55  constructor { _disableInitializers(); }
  -> SOUND. The implementation cannot be initialized; the factory clones and initializes
     in the same transaction (CoinDAOFactory L387-412).

L64-66  three zero-address checks
  Q1.4 SUFFICIENT? No. Three properties the wrapper's own safety depends on are NOT
       checked:
         (a) rewardsToken_ != govToken_   -> if equal, the reward float and the wrapper
             backing are the same pool, and `_payReward` pays out other users' principal.
         (b) revenueRouter_ has code      -> an EOA router makes `harvestYield` a
             silent no-op call that always succeeds (Solidity 0.8 `extcodesize` check on
             a high-level call to a non-contract actually reverts, so this one is safe).
         (c) IRevenueDistributor(revenueRouter_).govStaking() == address(this) — nothing
             enforces the back-link.
  Q3.3 CONSISTENCY: RevenueRouter.initialize validates 5 addresses + a bps bound; this
       one validates 3 addresses and nothing else. Neither validates cross-references.
  -> VERDICT: SUSPECT  (FF-008)

L76-79  modifier onlyRevenueRouter { require(msg.sender == address(revenueRouter), "...") }
  Q1.1 WHY: only the paired router may move the accumulator.
  Q3.5 CONSISTENCY: this is the ONLY string `require` in either file; everything else uses
       custom errors (L49-51, L33-34 in the router). Cosmetic + gas. -> LOW (FF-019)
  -> VERDICT: SOUND (as a guard)

L81-84  modifier harvestYield { revenueRouter.distribute(); _; }
  Q1.1 WHY: settle pending revenue against the CURRENT supply before the body changes
       that supply. This is the anti-JIT device, and the repo's own test
       `testLaterDepositorCannotCapturePendingRevenue` is written to prove it.
  Q2.1 MOVE UP/DOWN: if `distribute()` ran AFTER the body, a depositor would mint first
       and then be credited for revenue accrued before they existed. Confirmed: the
       ordering is load-bearing and correct as written.
  Q6.1 RETURN: the two return values are discarded. A caller cannot distinguish "there
       was nothing to harvest" from "everything went to the treasury because supply was 0".
  Q4.3 ASSUMES: (i) `distribute()` never reverts, and (ii) `distribute()` moves ALL
       economically-accrued revenue. Neither is enforced, neither is checked, and there
       is no try/catch. Because `depositFor` is the only mint path and stGOV is the only
       vote token, (i) failing is a permanent freeze of the vote-holder set.
       The interface's own NatSpec (IRevenueDistributor L21) says only "synchronizing
       pending revenue" — it does not promise the sync is complete.
  -> VERDICT: SUSPECT  (FF-004, FF-005)

L86-92  modifier updateReward(address account) { if (account != address(0)) {...} }
  Q1.2 DELETE the address(0) guard: nothing breaks. `earned(address(0))` is
       `mulDiv(0, delta, 1e18) + rewards[0]` = 0, and the two writes are to slots nobody
       reads. The guard exists in Synthetix because `notifyRewardAmount` there calls
       `updateReward(address(0))`. Here (L168) it does not. The guard is vestigial —
       a visible seam where the Synthetix time-accrual was amputated.
  Q1.3 Which call site can pass address(0)? Only `depositFor(address(0), v)`, which then
       reverts inside OZ `_mint`. So the guard protects nothing reachable.
  Q2.3 ORDER: writes happen BEFORE `_;`. Correct: settle, then mutate the balance.
  -> VERDICT: SOUND but dead (FF-015)

L102-111  depositFor  — modifiers run in declaration order:
          nonReentrant.pre -> harvestYield.pre(distribute) -> updateReward.pre -> body
  Q2.1/Q2.2 The three-way order is the only correct one: harvest must precede settlement
       (so the depositor's settlement sees the new accumulator), and settlement must
       precede the mint (so the new balance is not credited retroactively). Verified by
       trace and by the repo's own test. -> SOUND
  Q7.3 What can the callee do at the moment of `revenueRouter.distribute()`? It re-enters
       `notifyRewardAmount`, which reads `totalSupply()` — still the PRE-deposit supply.
       Correct. Any other re-entry is blocked by `nonReentrant` (verified at L4, FF-006).
  Q4.1 CALLER: `account` is arbitrary. `depositFor(victim, 0)` settles the victim and
       forces a harvest — mathematically neutral, and `distribute()` is permissionless
       anyway. -> not a finding.
  Q4.6 value = 0 is permitted; it is a paid no-op. -> not a finding.
  -> VERDICT: SOUND in isolation; SUSPECT through L82 (FF-004/FF-005).

L113-121  withdrawTo  — nonReentrant, updateReward(msg.sender), NO harvestYield
  Q3.2 INVERSE PARITY: `depositFor` harvests; its inverse does not. This is the single
       largest asymmetry in the file.
  Q1.2 What breaks if `harvestYield` is ADDED here? Nothing in the accounting — it would
       settle the exiter at the true accumulator. What it would cost is the escape hatch:
       an exit that survives a broken router. The NatSpec at L129 shows the authors chose
       the escape hatch deliberately.
  Q7.6 ACROSS TRANSACTIONS: after Alice withdraws without harvesting, a later
       `distribute()` credits the revenue that accrued during Alice's stake entirely to
       whoever is still staked. `distribute()` is permissionless, so this is
       back-runnable by anyone in the same block.
  Q3.4 There is no NatSpec on `withdrawTo` (L113) or on `withdraw` (L123). The only
       warning lives on `harvestAndWithdraw` (L127-129), i.e. on the function you did
       not call.
  -> VERDICT: SUSPECT  (FF-003)

L123-125  withdraw()  — external, delegates to the public withdrawTo
  Q5.4 The guard is acquired once (in `withdrawTo`), not twice. Correct.
  -> SOUND mechanically; inherits FF-003.

L130-134  harvestAndWithdraw — calls `super.withdrawTo`, not `withdrawTo`
  Q1.1 WHY `super.`? Because the override carries `nonReentrant`, and this function
       already holds the guard. Calling the override would self-deadlock. This is a
       correct and non-obvious decision. -> SOUND
  Q5.2 Full balance only. There is no `harvestAndWithdrawTo(account, value)`. A partial,
       settling exit requires two calls (`harvestAndGetReward` then `withdrawTo`).
  Q6.2 `_payReward` is inside; if the Coin transfer fails (paused / blacklisted account)
       this function reverts and the user cannot recover PRINCIPAL through it.
       `withdraw()` remains as the escape — which is exactly what L129 says.
  -> VERDICT: SOUND, with an ergonomic gap feeding FF-003.

L136-138  rewardPerToken()
  Q1.2 DELETE: nothing internal breaks; `rewardPerTokenStored` is already public. It
       exists for Synthetix API shape. -> SOUND, dead-ish.

L140-143  earned()
  Q5.x mulDiv floors. An account whose `balance * delta < 1e18` earns 0 for that delta
       and the shortfall is NOT carried — but it is not lost either, because the
       accumulator itself is unchanged; the loss is bounded by 1 wei per settlement.
  Q5.x OVERFLOW: `Math.mulDiv` reverts if the RESULT exceeds 2^256. Reaching that would
       brick `updateReward` for the account, i.e. a permanent withdrawal DoS. Bound
       derived in FF-016 — REFUTED by magnitude.
  -> VERDICT: SOUND

L147-149  getReward()  — no harvestYield, deliberately (L145-146)
  Q3.1 GUARD PARITY with harvestAndGetReward: identical except the harvest. Consistent.
  -> SOUND

L157-164  _payReward — zeroes `rewards[account]` BEFORE the transfer
  Q2.1 Checks-effects-interactions, correct.
  Q6.2 `if (reward > 0)` means a zero-reward claim emits nothing and does not revert.
       Fine.
  -> SOUND

L168-174  notifyRewardAmount
  L169-170  supply == 0 -> revert NoStakedSupply
    Q1.1 WHY: division guard.
    Q1.4 SUFFICIENT? As a division guard, yes. But it makes the function a REVERT
         SOURCE inside `distribute()`, which is inside `harvestYield`, which is on the
         mint path. The router pre-checks `totalSupply() != 0` at RevenueRouter L72,
         with a `coin.safeTransfer` in between (L78) — a TOCTOU window that only opens
         if Coin has a transfer callback. -> see FF-007.
  L172  rewardPerTokenStored += Math.mulDiv(reward, REWARD_PRECISION, supply);
    Q1.1 WHY: convert an absolute reward into per-token terms.
    Q7.7 ACCUMULATION: the division FLOORS and the remainder is DISCARDED. It is not
         carried to the next notification, not returned to the router, and not
         recoverable (no sweep — L4 absence check). The Coin has already been
         transferred in, so it is permanently stranded in a contract with no owner.
    Q4.6 AMOUNT: if `reward * 1e18 < supply` the increment is ZERO and the ENTIRE reward
         is destroyed. The threshold is `supply / 1e18` wei of Coin.
    Q4.2 `reward` is trusted to equal the tokens actually received. Only the router can
         call this, and the router does transfer first — but it computes the amount from
         a pre-transfer balance read, so any token that delivers less than requested
         over-credits the accumulator.
    -> VERDICT: SUSPECT  (FF-001; FF-018)
  Q3.4 EVENT: `RewardAdded(reward)` logs the notified amount, not the credited amount.
       An indexer summing `RewardAdded` will not match what stakers can claim.

L176-184  _update — non-transferability
  Q1.4 SUFFICIENT? Yes for its stated purpose: mint has from==0, burn has to==0, every
       other movement reverts. Verified at L4 (FF-009): `approve` succeeds and
       `transferFrom` reverts with `NonTransferable`.
  Q1.2 DELETE: stGOV becomes transferable and the vote/stake binding is gone.
  -> SOUND. Note the consequence: `approve`/`permit`/`allowance` are live but dead
     surface (FF-009).
```

### `RevenueRouter.sol`

```
L12-17  contract NatSpec: "intentionally the permanent operator ... deliberately does not
        expose a call to setPendingOperator, so neither its owner nor the timelock can
        migrate the operator role after deployment. Governance retains only the manager
        and revenue-split controls."
  ENGAGEMENT (required by the "read the comment first" rule): the first clause is TRUE
  and verified at L4 (the ABI has no setPendingOperator wrapper). The second clause is
  an ASSERTION about the external Lender that this repository cannot support: it claims
  the residual power set {setManager, pullLocalReserves} is sufficient. `IMonolith.sol`
  is a hand-written partial interface — `novel_code.md` itself lists its review focus as
  "ABI match against the external Monolith contracts". `plan.md` §7 offered an "optional
  operator handoff / recovery function if devs want a safe upgrade path"; the code
  declined it. -> see FF-017.

L40-60  initialize
  Q1.4 Five zero-address checks and a bps bound. NOT checked:
         coin_ == IMonolithLender(lender_).coin()  (the interface exposes `coin()`)
         govStaking_ != treasury_
         INotifiableRewardReceiver(govStaking_).totalSupply() is callable
       Every one of these is permanent once set (no setters — L4 absence check), on a
       contract that also permanently owns the Lender's operator role.
  -> VERDICT: SUSPECT (FF-017)

L64-66  acceptLenderOperator — onlyOwner
  Q1.1 WHY: completes the factory's handoff atomically (CoinDAOFactory L452-454).
  Q4.3 The NatSpec calls it "the one-time operator nomination", but the code enforces
       nothing one-time. Idempotence is delegated entirely to the external Lender's
       `acceptOperator` reverting when `pendingOperator != msg.sender`. That behaviour is
       assumed, not verified.
  Q3.4 EVENT: `setGovStakingBps` emits, `setManager` emits, and the single most
       consequential state change in the whole system — permanently capturing an external
       privileged role — emits NOTHING. -> FF-014
  -> VERDICT: SUSPECT (low)

L68  function distribute() external override — no guard, no reentrancy protection
  Q4.1 CALLER: anyone, by design (plan.md §7: "Anyone can call distribute()").
  Q2.5 ORDER MATTERS ACROSS CALLERS: because accrual is instantaneous, whoever calls
       this chooses the instant at which the staked-supply snapshot is taken. That is
       the lever behind FF-002, FF-003 and FF-011.

L69  lender.pullLocalReserves();
  Q1.1 WHY: realise the revenue before splitting it.
  Q4.3/Q4.5 ASSUMES, with no fallback and no try/catch:
        (a) it never reverts — including when there is nothing to pull;
        (b) it transfers/mints EVERYTHING economically accrued at this instant;
        (c) the router still holds the operator role that authorises it.
       (a) failing bricks `depositFor` (FF-004). (b) failing breaks the anti-JIT
       property that L82 exists to provide (FF-005). The repo's mock encodes (a) as
       "return early if zero" and (b) as "mint all of it" — but a mock is the
       auditee's own assumption written down, not evidence.
  -> VERDICT: SUSPECT (FF-004, FF-005)

L71  uint256 amount = coin.balanceOf(address(this));
  Q1.1 WHY: sweep whatever is here, not just what was pulled. Tolerant of donations and
       of a Lender that pushes reserves asynchronously.
  Q4.2 Any Coin sent here for any reason is distributed. Harmless (it is distributed
       pro-rata to whoever is staked), but it means `amount` is not an audited quantity.

L72-74  if (govStaking.totalSupply() != 0) { govStakingAmount = amount*bps/MAX_BPS; }
  Q1.1 WHY: avoid the `NoStakedSupply` revert at StakedGovToken L170.
  Q1.4 SUFFICIENT? As a revert guard, yes. As an economic rule it is a cliff: at supply
       == 1 wei the full `govStakingBps` share is paid to that one wei-holder; at supply
       == 0 the whole amount goes to the treasury regardless of bps. `plan.md` §7 states
       the supply==0 branch explicitly, so it is intended — but the cliff is also a
       timing lever for a permissionless caller (FF-011).
  Q7.3 TOCTOU: `totalSupply()` is read HERE, and read AGAIN inside `notifyRewardAmount`
       at L169, with `coin.safeTransfer` at L78 in between. Only a Coin with a transfer
       callback can make the two reads differ. -> FF-007.
  Q5.x OVERFLOW: `amount * govStakingBps` with bps <= 10_000 needs amount > ~1.1e73 to
       overflow. Unreachable. -> SOUND.

L75  treasuryAmount = amount - govStakingAmount;
  Q7.7 The floor-division remainder goes to the treasury, so NO value is lost here.
       Contrast with StakedGovToken L172, where the remainder is destroyed. The two
       divisions in the same value path handle their remainders differently. -> SOUND,
       but the inconsistency is the tell for FF-001.

L77-80  transfer to govStaking, THEN notify
  Q2.1 SWAP TEST: notifying first would be equivalent, because both are in the same
       atomic transaction and a failing transfer reverts everything. The ordering is
       not load-bearing.
  Q7.3 At the instant of L78, the router still holds `treasuryAmount` and the
       accumulator has NOT yet moved. A re-entrant `distribute()` from a Coin callback
       here sees a stale, half-applied state. -> FF-007.

L81-83  transfer to treasury LAST
  Q2.2 Being last puts the treasury payout at the tail of the reentrancy window: if a
       nested call has already drained the router's balance, this line reverts and takes
       the whole harvest with it. -> FF-007.

L85  emit RevenueDistributed(amount, treasuryAmount, govStakingAmount);
  Q3.4 Emitted unconditionally, including on the extremely common (0,0,0) no-op that
       every `depositFor` produces when no revenue is pending. Indexer noise. -> LOW.

L88-92  setGovStakingBps
  Q2.1 WHAT IF THIS RAN AFTER A distribute()? Then the change would apply only to
       revenue accrued afterwards. As written, there is NO settlement before the write,
       so the new split applies RETROACTIVELY to every wei of revenue that accrued under
       the old split and has not yet been harvested.
  Q3.2 PARITY with `initialize`: same bound check. Good.
  Q1.1 The event emits (old, new) in the correct order, before the write. Correct.
  -> VERDICT: SUSPECT (FF-002)

L94-98  setManager
  Q3.1 GUARD PARITY: onlyOwner, matching setGovStakingBps. Consistent.
  Q2.2 The event is emitted AFTER the external call — correct (do not log an action that
       may revert).
  Q4.3 Assumes the Lender accepts `setManager` from the operator. Same class of external
       assumption as L69, but non-critical: a failure only blocks a governance action.
  -> SOUND

INHERITED (not declared in the file, confirmed present at L4):
  renounceOwnership() — permanently removes setGovStakingBps and setManager while the
  router remains the permanent operator. -> FF-010.
```

### Interfaces

```
INotifiableRewardReceiver L8-9  `totalSupply()` inside a *reward receiver* interface.
  Q1.1 WHY: the router needs the receiver's supply to decide the treasury/staker split
       (RevenueRouter L72). This couples the router's economics to the receiver's ERC20
       shape — a receiver that is not a token cannot be used. Design smell, not a bug.

INotifiableRewardReceiver L12-14  "`amount` must equal the tokens actually received.
  Fee-on-transfer and rebasing reward tokens are unsupported."
  Q4.2 The contract that must satisfy this (RevenueRouter L71-79) computes `amount` from
       a PRE-transfer balance read. Nothing verifies the post-transfer delta. The
       requirement is documented on the interface but enforced nowhere. -> FF-018.

IRevenueDistributor L21  "Minimal interface for synchronizing pending revenue before
  staking reward state changes."
  Q4.3 Note what this does NOT say: that the synchronisation is COMPLETE. StakedGovToken
       L82 depends on completeness for its anti-JIT property. -> FF-005.
  Q6.1 Both return values are declared and are discarded by the only consumer (L82).
```

---

## Phase 3 — Cross-function analysis

### 3.1 Guard consistency (grouped by state written)

| state written | writers | guards | verdict |
|---|---|---|---|
| `rewardPerTokenStored` | `notifyRewardAmount` | `onlyRevenueRouter` | consistent — single writer |
| `rewards[a]`, `userRewardPerTokenPaid[a]` | `depositFor`, `withdrawTo`, `harvestAndWithdraw`, `getReward`, `harvestAndGetReward`, `_payReward` | every one carries `updateReward` + `nonReentrant` | **consistent — no writer is missing a guard** |
| `ERC20$.balances` / `totalSupply` | `depositFor`, `withdrawTo`, `harvestAndWithdraw` | all three settle before mutating | **consistent** |
| `govStakingBps` | `initialize`, `setGovStakingBps` | `initializer` / `onlyOwner`, same bound check | consistent |
| `Ownable$.owner` | `transferOwnership`, `renounceOwnership` | `onlyOwner` | consistent (FF-010 is about the *existence* of renounce, not its guard) |

**No missing guard was found.** The access-control layer is the strongest part of this
code. Every finding below is about ordering, arithmetic, or an external assumption.

### 3.2 Inverse-operation parity

| pair | parameter validation | state changes truly inverse? | harvest? | events | verdict |
|---|---|---|---|---|---|
| `depositFor` / `withdrawTo` | both settle the right account; neither validates the address (both fail downstream in OZ) | yes, 1:1 | **deposit YES, withdraw NO** | ERC20 `Transfer` both ways | **ASYMMETRIC — FF-003** |
| `getReward` / `harvestAndGetReward` | identical | identical | no / yes | identical | symmetric by design |
| `withdraw` / `harvestAndWithdraw` | both full-balance-to-self | identical burn | no / yes | identical | symmetric by design |
| `setGovStakingBps` / `distribute` | bound-checked / none needed | — | **bps change does not settle first** | both emit | **ASYMMETRIC — FF-002** |
| `initialize`(staker) / `initialize`(router) | 3 checks / 5 checks + bound; **neither validates the cross-references that bind the two contracts together** | — | — | none / `OwnershipTransferred` | **ASYMMETRIC — FF-017** |

### 3.3 State transition integrity

The stGOV supply has three regimes and the system behaves differently in each:

```
  supply == 0        -> distribute() sends 100% to treasury regardless of govStakingBps
                        notifyRewardAmount reverts (unreachable via distribute)
  supply == 1 wei    -> that single holder receives the entire govStakingBps share
                        the minimum creditable reward drops to 0 wei (no destruction)
  supply == 1e25     -> the minimum creditable reward rises to 1e7 wei of Coin
```

Transitions between regimes are **permissionless, instant, and reversible in a single
transaction** (`plan.md` §6: "No staking cooldown and no proportional withdrawal escrow in
v1"). Every regime boundary is therefore attacker-selectable. FF-011 and FF-012 are the
two consequences that matter.

### 3.4 Value-flow conservation — verified by fuzz at L4

`testFuzz_accumulatorStaysSolventAndConserves` (256 runs × 24 randomised operations across
4 users, mixing deposit / withdraw / harvest / claim / harvestAndWithdraw) asserts after
**every single step**:

- `Σ earned(user) <= Coin.balanceOf(staker)` — the contract never promises Coin it does
  not hold;
- `GOV.balanceOf(staker) >= stGOV.totalSupply()` — the 1:1 wrapper backing holds;

and at the end, `totalHarvested == totalPaid + stillOwed + stranded`. **All 256 runs pass.**

This is a strong verified negative: the core accumulator does not leak, double-credit, or
under-collateralise under adversarial interleaving. The `stranded` term is FF-001 and is
the only value that leaves the system.

---

## Phase 4 / Phase 5 — Findings, with verification

Verification method per the skill: **A** = deep code trace, **B** = PoC test, **C** = hybrid.

| ID | Raw severity | Verdict | Final | Method |
|---|---|---|---|---|
| FF-001 | HIGH | TRUE POSITIVE — DOWNGRADE (conditional) | **LOW**, escalating to **HIGH** if Coin has ≤ 8 decimals | C |
| FF-002 | MEDIUM | TRUE POSITIVE | **MEDIUM** | C |
| FF-003 | HIGH | TRUE POSITIVE — DOWNGRADE | **MEDIUM** | C |
| FF-004 | CRITICAL | TRUE POSITIVE — mechanism proven, trigger unverifiable here | **HIGH (lead)** | C |
| FF-005 | CRITICAL | TRUE POSITIVE — mechanism proven, trigger unverifiable here | **HIGH (lead)** | C |
| FF-006 | MEDIUM | **FALSE POSITIVE** | — | B |
| FF-007 | MEDIUM | TRUE POSITIVE — DOWNGRADE | **LOW** | B |
| FF-008 | HIGH | TRUE POSITIVE — DOWNGRADE (unreachable via the factory) | **LOW** | C |
| FF-009 | LOW | TRUE POSITIVE | **LOW** | B |
| FF-010 | LOW | TRUE POSITIVE | **LOW** | B |
| FF-011 | MEDIUM | TRUE POSITIVE — matches the written spec | **INFO** | B |
| FF-012 | HIGH | PARTIAL — flash variant REFUTED, residual is a Pass-2 lead | **LEAD** | B |
| FF-013 | LOW | TRUE POSITIVE | **LOW** | A |
| FF-014 | LOW | TRUE POSITIVE | **LOW** | A |
| FF-015 | LOW | TRUE POSITIVE | **INFO** | A |
| FF-016 | HIGH | **FALSE POSITIVE** (refuted by magnitude) | — | A |
| FF-017 | HIGH | TRUE POSITIVE — assumption, not a defect | **MEDIUM** | A |
| FF-018 | MEDIUM | TRUE POSITIVE — DOWNGRADE (documented unsupported) | **INFO** | B |
| FF-019 | LOW | TRUE POSITIVE | **INFO** | A |

---

### FF-001 — `notifyRewardAmount` discards the division remainder; small harvests are destroyed outright

**Severity:** LOW as written *for an 18-decimal Coin*; **HIGH** if Coin has ≤ 8 decimals.
**Module/function:** `StakedGovToken.notifyRewardAmount`
**Lines:** `StakedGovToken.sol:168-174`, specifically **L172**
**State touched (for Pass 2):** writes `rewardPerTokenStored`; reads `ERC20$.totalSupply`.
Downstream: `earned()` (L141), `rewards[]`, and `Coin.balanceOf(StakedGovToken)`.
**Verification:** C — trace + 4 PoCs (`test_FF001_*`, `test_driftOverAYearOfHourlyHarvests`).

**Feynman question that exposed it**
> Q7.7 — "Rounding errors that compound: each call loses precision. Does the accumulator
> rebase, or does it treat every unit as equal?"
> and Q4.6 — "What if amount = 1 (dust / minimum unit)?"

**The code**
```solidity
rewardPerTokenStored += Math.mulDiv(reward, REWARD_PRECISION, supply);
emit RewardAdded(reward);
```

**Why this is wrong.** The Coin has already been moved into `StakedGovToken` by the router
(RevenueRouter L78) before this line runs. This line converts that absolute amount into
per-token terms by dividing, and the division floors. The floored-off part is not carried
into a `remainder` variable, not returned to the router, and not credited to anyone. The
contract has no owner and no sweep function (verified at L4 by enumerating its 40-function
ABI), so that Coin can never be moved again. The router does the *same* division four lines
earlier (RevenueRouter L73) and correctly gives its remainder to the treasury via
`treasuryAmount = amount - govStakingAmount` — so the codebase knows how to handle a
remainder, and simply does not here.

The pathological case is not "some dust is lost": it is that when
`reward * 1e18 < supply`, the increment is **exactly zero** and the *entire* harvest is
destroyed. The threshold is `totalSupply / 1e18` **wei of Coin** — a quantity determined by
GOV's 18 decimals and the staked supply, with no relationship to the Coin's own precision.

**Verification evidence (L4, executed)**

```
test_FF001_wholeRewardDestroyedBelowThreshold_18dec
  supply                     10000000000000000000000000   (full 10M GOV staked)
  min creditable reward wei  10000000
  harvest of 9,999,999 wei ->
  rewardPerTokenStored       0
  alice earned               0
  coin stranded in staker    9999999          <- unowned, unrecoverable

test_FF001_repeatedHarvestsDestroyEverything_6dec   (Coin with 6 decimals)
  min creditable reward      10000000 wei = 10.000000 COIN
  200 harvests x 9.00 COIN = 1800 COIN harvested
  alice earned            (COIN) 0             <- 100% destroyed
  stranded in staker      (COIN) 1800

test_FF001_partialRemainderLostOnOrdinaryReward     (18 decimals)
  reward notified  12345678901234567890
  credited         12345678901230000000
  lost this call             4567890

test_driftOverAYearOfHourlyHarvests                 (18 dec, 1M GOV staked, 8760 harvests)
  total received  438000000008759991240
  total credited  438000000000000000000
  stranded          8759991240   =  0 ppm of revenue
```

The control case that makes the check meaningful (skill Q: "a green check has a
resolution"): the same harness with an 18-decimal Coin credits the staker correctly and
loses 0 ppm/year, so the 6-decimal failure is attributable to the decimals, not to the
harness.

**Attack / failure scenario**
1. Coin is deployed with `d` decimals. The minimum creditable harvest is `S / 1e18` wei,
   i.e. `S / 1e(18+d)` Coin, where `S` is the staked stGOV supply.
2. With `S = 1e25` (full supply staked): `d=18` → 1e-11 Coin (irrelevant);
   `d=8` → 0.1 Coin; `d=6` → 10 Coin.
3. `distribute()` is permissionless and unbounded in frequency. An attacker calls it every
   block. Each call harvests one block's worth of revenue. If per-block revenue is below
   the threshold, **every block's revenue is destroyed** at a cost of gas only.
4. At `d = 6` and a market earning $1M/year, per-block revenue is ≈ $0.38, far below the
   $10 threshold — 100 % of protocol revenue is burned.

**Impact.** At 18 decimals: negligible (measured 0 ppm/year), but the stranded Coin
accumulates permanently and makes `Coin.balanceOf(StakedGovToken)` diverge from
`Σ rewards` forever. At ≤ 8 decimals: total, permissionless destruction of the revenue
stream that is the entire economic purpose of stGOV.

**What I could not verify.** The deployed Monolith Coin's `decimals()`. It is created by the
external `IMonolithFactory.deploy`, not by this repository. `MockERC20` in the test suite
inherits OZ's default 18. **The client must state Coin's decimals**; the severity of this
finding is a function of that number.

**Suggested fix** (a hypothesis — both failure modes priced below)
```solidity
uint256 public undistributed;

function notifyRewardAmount(uint256 reward) external onlyRevenueRouter {
    uint256 supply = totalSupply();
    if (supply == 0) revert NoStakedSupply();
    uint256 pending = reward + undistributed;
    uint256 delta = Math.mulDiv(pending, REWARD_PRECISION, supply);
    rewardPerTokenStored += delta;
    undistributed = pending - Math.mulDiv(delta, supply, REWARD_PRECISION);
    emit RewardAdded(reward);
}
```
*What the fix prevents:* permanent destruction of sub-threshold harvests; the remainder is
carried and credited on the next notification.
*What the fix creates:* one extra SSTORE per notification (on the mint path, so every
deposit pays it); a second `mulDiv`; and a new coupled pair — `undistributed` must now stay
consistent with the Coin balance, which is exactly the class of bug Pass 2 hunts. It also
means the carried remainder is credited to whoever is staked *later*, which is a small
transfer of value from present to future stakers. A cheaper alternative that prevents only
the catastrophic case is a minimum-harvest floor, but that reintroduces a griefable
threshold. **Neither should be adopted without the client stating Coin's decimals.**

---

### FF-002 — `setGovStakingBps` retroactively re-prices revenue that has already accrued

**Severity:** MEDIUM
**Module/function:** `RevenueRouter.setGovStakingBps`
**Lines:** `RevenueRouter.sol:88-92` (the missing call), interacting with `L68-86`
**State touched (for Pass 2):** writes `govStakingBps`. The state it fails to settle first
is `StakedGovToken.rewardPerTokenStored` — a variable in a *different contract*, which is
why this asymmetry is invisible from either file alone.
**Verification:** C — trace + PoC pair with a control (`test_FF002_*`).

**Feynman question that exposed it**
> Q2.1 — "What if this line executes BEFORE the line above it?" applied across functions:
> what if `distribute()` ran before the write instead of after it?

**The code**
```solidity
function setGovStakingBps(uint16 newGovStakingBps) external onlyOwner {
    if (newGovStakingBps > MAX_BPS) revert InvalidGovStakingBps(newGovStakingBps);
    emit GovStakingBpsUpdated(govStakingBps, newGovStakingBps);
    govStakingBps = newGovStakingBps;
}
```

**Why this is wrong.** Revenue accrues continuously inside the external Lender but is only
*priced* at the instant `distribute()` runs. `govStakingBps` is read at that instant
(L73) and applied to the entire un-harvested stock. Because this setter does not settle the
outstanding stock first, a bps change reaches backwards in time: a month of revenue earned
while the split was 100 % to stakers is paid out under whatever split is in force when
someone finally calls `distribute()`. The staker's entitlement is never checkpointed — it
exists only as an un-pulled balance inside a third contract.

The same transaction can do both: the timelock executes `setGovStakingBps(0)` and
`distribute()` as two calls in one proposal, and no staker can interpose.

**Verification evidence (L4, executed)**
```
test_FF002_bpsChangeRetroactivelyStripsAccruedRevenue
  alice is the sole staker; 100 COIN accrues at bps = 10000
  owner calls setGovStakingBps(0), then distribute()
  alice earned after bps flip  0
  treasury coin                100000000000000000000    (100 COIN)

test_FF002_controlHarvestFirstPreservesIt              <- the control case
  identical setup; distribute() first, then setGovStakingBps(0)
  alice earned when settled first 100000000000000000000
  treasury coin                   0
```
The control is what gives the check resolution: the *only* difference between the two runs
is the order of two calls, and it moves 100 % of a month's revenue.

**Attack scenario**
1. Stakers stake under an advertised 100 % revenue share.
2. Revenue accrues for a month; nobody calls `distribute()` (there is no incentive to —
   `getReward` works on already-harvested rewards, and harvesting costs gas).
3. A governance proposal executes `setGovStakingBps(0)` followed by `distribute()`.
4. The entire month's revenue lands in the treasury. Stakers earned nothing for a period
   during which the split was 100 % in their favour.

**Impact.** Governance can expropriate already-accrued staker revenue without any staker
being able to react — the accrual is not checkpointed, so there is no "earned before the
change" quantity to defend. This is a governance-privileged action, which is why it is
MEDIUM rather than HIGH; but note that the affected stakers are precisely the voters who
would have to approve it, and the 2-day timelock gives them a window only if they know to
call `distribute()` themselves — which they can, permissionlessly. **That self-defence
exists and is the reason this is not HIGH.**

**Suggested fix**
```solidity
function setGovStakingBps(uint16 newGovStakingBps) external onlyOwner {
    if (newGovStakingBps > MAX_BPS) revert InvalidGovStakingBps(newGovStakingBps);
    _distribute();                     // settle the outstanding stock at the OLD split
    emit GovStakingBpsUpdated(govStakingBps, newGovStakingBps);
    govStakingBps = newGovStakingBps;
}
```
*What the fix prevents:* retroactive re-pricing.
*What the fix creates:* `setGovStakingBps` now depends on the external Lender being
responsive — it inherits every failure mode in FF-004. A Lender that reverts on
`pullLocalReserves` would make the revenue split permanently unchangeable. That is a real
cost and the client must choose which failure they prefer; a `try/catch` around the
settlement, or a separate "settle then change" governance runbook, may be the better
trade.

---

### FF-003 — `withdraw()` / `withdrawTo()` forfeit un-harvested revenue to the remaining stakers, and the forfeiture is back-runnable

**Severity:** MEDIUM
**Module/function:** `StakedGovToken.withdrawTo` / `withdraw`
**Lines:** `StakedGovToken.sol:113-125` (absent `harvestYield`), vs `L102-111` and `L130-134`
**State touched (for Pass 2):** writes `rewards[msg.sender]`,
`userRewardPerTokenPaid[msg.sender]`, `ERC20$.balances`, `ERC20$.totalSupply`,
`Votes$.checkpoints`. Does **not** read or advance `rewardPerTokenStored`, which is the
whole point.
**Verification:** C — trace + PoC with a fair-path control (`test_FF003_*`).

**Feynman question that exposed it**
> Q3.2 — "If deposit() checks X, does withdraw() also check X? The inverse operation must
> validate at least as strictly."

**The code**
```solidity
function depositFor(address account, uint256 value)
    public override nonReentrant harvestYield updateReward(account) returns (bool)

function withdrawTo(address account, uint256 value)
    public override nonReentrant updateReward(msg.sender) returns (bool)
//                              ^^^ no harvestYield
```

**Engagement with the comment** (required — the code may be refusing a shape someone
already tried). `StakedGovToken.sol:127-129` says:

> "Harvests pending revenue, withdraws the caller's full stake, and pays their rewards. …
> Use `withdraw` to recover the underlying GOV without harvesting or claiming rewards."

So the authors knew, and the escape hatch is deliberate — an exit that survives a broken
router is genuinely valuable (and FF-004 shows it is genuinely needed). **This finding is
therefore not "you forgot the harvest".** It is that (a) the warning is written on
`harvestAndWithdraw`, the function you did *not* call, and there is no NatSpec at all on
`withdrawTo` (L113) or `withdraw` (L123); (b) `withdrawTo` is the OZ `ERC20Wrapper` standard
entry point that integrators will reach for by name; and (c) because accrual is instant and
`distribute()` is permissionless, the forfeited value does not vanish — it is transferred
to whoever is still staked, and a searcher can take it deterministically by back-running.

**Verification evidence (L4, executed)**
```
test_FF003_backrunAWithdrawToStealTheExiterShare
  alice 1000 stGOV, attacker 1000 stGOV, 100 COIN accrued (50/50 entitlement)
  alice calls withdraw();  attacker back-runs with distribute()
  alice earned      0
  attacker earned   100000000000000000000     (100 COIN -- all of it)

test_FF003_controlHarvestAndWithdrawIsFair             <- the control case
  identical setup; alice calls harvestAndWithdraw() instead
  alice coin paid   50000000000000000000
  attacker earned   50000000000000000000

test_FF003_withdrawToHasNoHarvestingVariant
  partial exit via withdrawTo(bob, 400e18):
  alice earned 0; the 100 COIN is still sitting unpulled in the lender
```

**Attack scenario**
1. A searcher watches the mempool for `withdraw()` / `withdrawTo()` on stGOV.
2. On seeing one, it computes the un-harvested revenue (readable from the Lender).
3. It back-runs the withdrawal with `RevenueRouter.distribute()` in the same block.
4. The exiter's entire share of that revenue is credited to the remaining stakers,
   proportional to their stake. A searcher holding stGOV captures its share for free; a
   searcher holding most of the stake captures nearly all of it.
5. Repeatable against every exit, forever.

**Impact.** Systematic, cost-free extraction from exiting stakers. Not theft in the
protocol's own terms (the spec says only the supply present at distribution time earns),
but it is a value transfer the user did not consent to, triggered by the most
natural-looking function name in the ABI.

**Suggested fix.** Do not add `harvestYield` to `withdrawTo` — that would destroy the
escape hatch FF-004 makes necessary. Instead:
```solidity
/// @notice Burns stGOV and returns the underlying GOV WITHOUT harvesting pending revenue.
/// @dev Your share of revenue that has accrued but not yet been distributed is forfeited
/// to the remaining stakers. Use `harvestAndWithdraw` unless the revenue router is
/// unavailable.
function withdrawTo(address account, uint256 value) public override ...
```
plus a `harvestAndWithdrawTo(address account, uint256 value)` so that a *partial*, settling
exit is one call rather than two.
*What the fix prevents:* users silently choosing the lossy exit.
*What the fix creates:* nothing in the accounting; the cost is a larger ABI and one more
function to reason about in Pass 2.

---

### FF-004 — The only mint path (and therefore the only way to acquire voting power) is hard-coupled to a live external Lender

**Severity:** HIGH — **stated as a lead**: the mechanism and the consequence are proven by
execution; the trigger depends on the deployed Monolith Lender's behaviour, which this
repository does not contain.
**Module/function:** `StakedGovToken.harvestYield` → `RevenueRouter.distribute`
**Lines:** `StakedGovToken.sol:81-84` and `102-111`; `RevenueRouter.sol:68-69`
**State touched (for Pass 2):** the failure blocks all writes to `ERC20$.balances`,
`ERC20$.totalSupply` and `Votes$.checkpoints` on the mint side, while leaving the burn side
writable. That one-sided reachability is the finding.
**Verification:** C — ABI absence check (L4) + PoC (`test_FF004_*`).

**Feynman question that exposed it**
> Q4.3 — "'This will never be called when paused' — but IS it enforced?" and
> Q6.3 — "What if an EXTERNAL CALL in this function fails?"

**The code**
```solidity
modifier harvestYield() {
    revenueRouter.distribute();      // no try/catch, no fallback
    _;
}

function depositFor(...) public override nonReentrant harvestYield updateReward(account)

// RevenueRouter.distribute():
lender.pullLocalReserves();          // the load-bearing external call
```

**Why this is wrong.** `depositFor` is the **only** function that can mint stGOV — verified
at L4 by enumerating the compiled 40-function ABI: there is no `mint`, no `recover`, and
`ERC20WrapperUpgradeable._recover` is internal and never called. stGOV is the Governor's
`IVotes` token (`CoinDAOFactory.sol:419`, `IVotes(address(staker))`). Therefore *the only
way anyone can ever acquire voting power in this DAO is to make a successful outbound call
into a foreign lending market.* There is no `try/catch`, no cached-failure path, and no
governance override — and there cannot be a governance override, because acquiring the
governance power to add one requires the very function that is blocked.

The burn side is asymmetric: `withdraw`, `withdrawTo` and `getReward` have no
`harvestYield` and keep working. So a failure freezes the delegate set at whoever happened
to be staked, while letting them leave — which *shrinks* the electorate monotonically
toward zero and cannot be reversed.

**Verification evidence (L4, executed)**
```
test_FF004_lenderFailureBricksStakingAndVotingPowerEntry
  alice stakes 1000 while the lender is healthy
  lender then rejects pullLocalReserves:
    bob   depositFor(...)        -> revert NothingToPull      (cannot ever stake or vote)
    alice harvestAndWithdraw()   -> revert NothingToPull
    alice harvestAndGetReward()  -> revert NothingToPull
    alice getReward()            -> OK
    alice withdraw()             -> OK, 1000 GOV returned
  "exit works, entry is permanently blocked"

test_FF004_strictLenderRevertsWheneverNoRevenueIsPending
  a lender that reverts when reserves == 0 makes the FIRST deposit revert,
  i.e. staking is unavailable in the ordinary no-revenue-pending state.
```

**What I could not verify, and why.** The repository contains only
`test/mocks/MockMonolith.sol`, whose `pullLocalReserves` does `if (accruedLocalReserves == 0)
return;`. That is the auditee's own assumption written down as a mock, not evidence about
the deployed contract. `novel_code.md` itself lists the review focus for
`src/interfaces/IMonolith.sol` as *"ABI match against the external Monolith contracts"* —
the project knows this is unverified. `plan.md` §7 says only that "the Lender mints local
reserves to operator when reserves are pulled"; it says nothing about the zero case, about
pausability, or about whether the call can revert.

**Questions the client must answer before this can be graded:**
1. Does `Lender.pullLocalReserves()` revert when there are no reserves to pull?
2. Can it revert for any other reason — pause, oracle staleness, debt-ratio bounds,
   `timeUntilImmutability` state, insufficient mint headroom?
3. Can the Coin transfer to the Timelock treasury or to `StakedGovToken` ever fail
   (pausable Coin, blocklist)?

If the answer to (1) is *yes*, this is CRITICAL and staking is unavailable in the ordinary
case. If all three are *no* for all time, the finding reduces to a resilience concern.

**Suggested fix**
```solidity
modifier harvestYield() {
    try revenueRouter.distribute() {} catch {}
    _;
}
```
*What the fix prevents:* a foreign contract's liveness becoming this DAO's liveness.
*What the fix creates:* this is the dangerous half. Swallowing the failure means a deposit
can now mint **without** the anti-JIT harvest, which is precisely the hole FF-005
describes — a depositor could grief `distribute()` into reverting (e.g. FF-007's hooked-Coin
path, or by any Lender-side condition they control) and then mint into un-harvested revenue.
A safe version must either (a) keep the revert but add a governance-controlled
`emergencyDisableHarvest` flag — which reintroduces a trusted role and a chicken-and-egg
problem if governance is already frozen — or (b) catch the failure *and* refuse to credit
the depositor for any revenue realised in the same block. **This recommendation is a
hypothesis and the trade is genuinely two-sided; it should not be applied as written.**

---

### FF-005 — The anti-JIT property rests entirely on `pullLocalReserves()` being a complete drain of accrued revenue

**Severity:** HIGH — **stated as a lead**, same standing as FF-004: mechanism proven by
execution, trigger depends on the external Lender.
**Module/function:** `StakedGovToken.harvestYield` / `RevenueRouter.distribute`
**Lines:** `StakedGovToken.sol:81-84`; `RevenueRouter.sol:69-71`
**State touched (for Pass 2):** `rewardPerTokenStored`, `userRewardPerTokenPaid[attacker]`,
`ERC20$.totalSupply` — the attack is a same-transaction interleaving of exactly the
supply/accumulator pair the recon file lists as coupled pair #4.
**Verification:** C — PoC (`test_FF005_jitCaptureWhenReservesAreRealizedSeparately`).

**Feynman question that exposed it**
> Q7.8 — "Can an attacker craft a SEQUENCE of transactions to reach a state that no single
> normal transaction path would produce?" combined with Q4.5 — "Can the value be
> manipulated within the same transaction?"

**Why this matters.** The reward model is deliberately instantaneous: `plan.md` §6 says
"only the stGOV supply present at distribution time earns that revenue", and there is no
cooldown ("No staking cooldown and no proportional withdrawal escrow in v1"). Under that
model, being staked for one block at the moment of a harvest pays exactly the same as being
staked for the whole accrual period. The **only** thing preventing a flash-staker from
capturing a month of revenue is that `depositFor` harvests *before* it mints — and that
defence works only if the harvest actually empties the pot.

If the deployed Lender realises reserves in two steps — accrue to an index, then book on
a state-touching operation — then an attacker can interleave:

**Verification evidence (L4, executed).** `TwoPhaseLender` models exactly that: `accrue()`
adds to a pending index, `realize()` books it (a dust borrow/repay does this on a real
market), `pullLocalReserves()` mints only what is booked.

```
test_FF005_jitCaptureWhenReservesAreRealizedSeparately
  alice: honest staker, 1000 stGOV.  100 COIN of interest accrued over a month, unbooked.
  attacker, ONE atomic transaction, flash-loanable GOV:
      depositFor(attacker, 1_000_000e18)   // harvest pulls booked == 0
      lender.realize()                     // poke the market
      router.distribute()                  // 100 COIN credited to the CURRENT supply
      getReward()
      withdraw()
  attacker COIN profit  99900099900099000000   (99.90 COIN, 99.9% of a month of revenue)
  alice earned                99900099900099000   (0.0999 COIN)
  attacker GOV returned  1000000000000000000000000  (principal fully returned, same tx)
```

**What I could not verify.** Whether the real `Lender.pullLocalReserves()` is a complete
drain. `IRevenueDistributor`'s own NatSpec promises only "synchronizing pending revenue" —
it never claims completeness, and `StakedGovToken` L82 depends on completeness.
**Question for the client:** at the instant `pullLocalReserves()` returns, is it guaranteed
that zero economically-accrued protocol revenue remains realisable by any subsequent call
in the same block? If interest accrues to an index and reserves are booked lazily on
borrow / repay / redeem / liquidate, the answer is no and this is CRITICAL.

**Impact if the assumption fails.** A flash-loaned deposit captures effectively 100 % of
accumulated protocol revenue in a single atomic transaction, repeatedly, at no risk. Honest
long-term stakers receive dust. This is the highest-value outcome available anywhere in the
scope.

**Suggested fix.** Do not rely on the harvest for the anti-JIT property. Either make the
accrual time-weighted (restore a Synthetix-style `rewardRate` / `periodFinish` stream, so
that a one-block stake earns one block of revenue), or add a minimum stake duration before
reward eligibility.
*What the fix prevents:* JIT capture regardless of the Lender's internals.
*What the fix creates:* a streaming model reintroduces `lastUpdateTime` / `periodFinish`
and their coupling to `totalSupply` — the exact state-pair class this project already has
to manage in `StakingRewards.sol`, and it makes late-arriving revenue accrue to stakers who
were not present. A minimum duration adds a per-account timestamp that must stay consistent
with balance changes. Both are real, and both are new coupled pairs for Pass 2.

---

### FF-017 — Every parameter of `RevenueRouter` is permanent, on a contract that permanently holds an external privileged role

**Severity:** MEDIUM (design / assumption, not a code defect)
**Module:** `RevenueRouter`
**Lines:** `RevenueRouter.sol:12-17` (the NatSpec claim), `40-60`, `64-66`
**Verification:** A — code trace + L4 ABI enumeration.

**Feynman question that exposed it**
> Q1.2 — "What happens if I DELETE this line?" applied to the *absent* lines:
> what is missing, and what did the spec say should be here?

**The facts, verified at L4.** The compiled `RevenueRouter` ABI is exactly:
`MAX_BPS, acceptLenderOperator, coin, distribute, govStaking, govStakingBps, initialize,
lender, owner, renounceOwnership, setGovStakingBps, setManager, transferOwnership, treasury`.
There is no `setPendingOperator` wrapper — **the NatSpec's permanence claim is TRUE.** There
is also no `setTreasury`, no `setGovStaking`, no `setLender`, no `setCoin`, and no rescue.

`initialize` (L40-60) checks five addresses for zero and bounds `govStakingBps`. It does
**not** check `coin_ == IMonolithLender(lender_).coin()`, even though the interface exposes
`coin()` and the factory itself reads it (`CoinDAOFactory.sol:336`). It does not check that
`govStaking_` points back at this router. Any of these being wrong is unrecoverable: the
router is a clone with a one-shot initializer, it cannot be replaced (it permanently holds
the operator role and cannot nominate a successor), and none of its fields can be corrected.

**Engagement with the comment.** L13-15 asserts "Governance retains only the manager and
revenue-split controls." That is a claim about the *external* Lender: it asserts that
`{setManager, pullLocalReserves}` is a sufficient residual power set. This repository
cannot support that claim. `IMonolithFactory.DeployParams` (`IMonolith.sol:29-48`) shows the
Lender carries `collateralFactor, minDebt, timeUntilImmutability, halfLife,
targetFreeDebtRatioStartBps/EndBps, redeemFeeBps, stalenessThreshold, maxBorrowDeltaBps,
psmVaultMinTotalSupply` and a `feed` — a substantial parameter surface. `IMonolithLender`
is a hand-written 8-function partial interface. **If any of those parameters, or the price
feed, is gated on `operator` rather than `manager`, it becomes permanently unreachable the
moment `acceptLenderOperator()` succeeds.** `plan.md` §7 explicitly offered an "optional
operator handoff / recovery function if devs want a safe upgrade path"; the implementation
declined it.

**Questions for the client:** (1) the complete list of `operator`-gated functions on the
deployed Lender; (2) confirmation that every one of them is either exposed by
`RevenueRouter` or genuinely never needed again; (3) whether the Lender has any admin
capable of reassigning `operator` out of band.

**Impact.** A misconfiguration or an unforeseen need for an operator-only Lender function is
unrecoverable by any party, including governance. Nothing is stolen; capability is
permanently destroyed.

**Suggested fix.** Add `coin_ == IMonolithLender(lender_).coin()` to `initialize` — that one
is free and catches the most likely misconfiguration. On the operator question, the trade is
genuinely two-sided and the authors have already reasoned about it: a recovery function is
also a governance-capturable path to hand the Lender's operator role to an attacker in a
single proposal. **Recommend documenting the analysis rather than changing the code**, and
raising it with the client as a decision to confirm, not a defect to fix.

---

### FF-007 — `distribute()` is re-entrant; a Coin with a transfer callback bricks every harvest

**Severity:** LOW (requires a non-standard Coin; griefing only, no theft)
**Lines:** `RevenueRouter.sol:68-86`, specifically the interleaving of L78/L79/L82
**State touched:** none in the router (all locals); reads `coin.balanceOf(this)` twice
across the re-entry, and `StakedGovToken.rewardPerTokenStored` is advanced by the inner
call before the outer call advances it again.
**Verification:** B — PoC (`test_FF007_nestedDistributeViaCoinHook`).

**Feynman question**
> Q7.3 — "What can the CALLEE do with the current state at THIS exact moment?"

`distribute()` has no reentrancy guard and is permissionless. At L78, the Coin has moved to
`StakedGovToken` but `notifyRewardAmount` has **not** yet run, and the router still holds
`treasuryAmount`. A re-entrant `distribute()` from a Coin transfer callback at that moment
reads a fresh `coin.balanceOf(this)`, distributes the treasury portion, and returns; the
outer frame then credits the accumulator for its transfer and attempts L82 against a
balance that is now zero — and reverts, taking the whole harvest with it.

**Evidence (L4):** with `govStakingBps = 2500` and a `HookCoin` armed to re-enter
`distribute()` when tokens land on the staker, `router.distribute()` reverts. Because
`distribute()` sits inside `harvestYield`, this also bricks `depositFor` — so it chains
into FF-004.

Note the guard interaction: when `depositFor` is the entry point, `nonReentrant` on
`StakedGovToken` blocks re-entry into the staker but does **not** block re-entry into
`RevenueRouter`, which has no guard of its own.

The contract NatSpec (L16-17) excludes "fee-on-transfer and rebasing" tokens. A
callback-on-transfer token is neither, so this case is **not** covered by the existing
disclaimer. If Monolith Coin is a plain ERC-20 with no hooks, this is unreachable.

**Fix:** add `nonReentrant` to `distribute()`, or move the treasury transfer above the
staker transfer + notify so that the last external call is the one whose failure is
harmless. The former is cheaper to reason about.

---

### FF-008 — `initialize` never rejects `rewardsToken == underlying`, and the wrapper's backing is what pays rewards

**Severity:** LOW — unreachable through `CoinDAOFactory`, which always passes a fresh
`GovToken` clone and the Lender's `coin()`. Raised as defence-in-depth on a one-shot,
unrepairable initializer.
**Lines:** `StakedGovToken.sol:57-74`
**State touched:** `rewardsToken`, `Wrapper$.underlying`.
**Verification:** C — trace of the factory call site + PoC
(`test_FF008_rewardTokenEqualsUnderlyingDrainsWrapperBacking`).

If the two tokens are the same, `_payReward`'s `rewardsToken.safeTransfer` (L161) pays out
of the same pool that backs `totalSupply()`, and the ERC20Wrapper 1:1 invariant — which
nothing else in the contract checks — silently breaks.

**Evidence (L4):** alice and bob each wrap 1000 GOV; a 2000-unit notification credits alice
1000; alice claims; the wrapper now holds 1000 GOV against 2000 stGOV; bob withdraws the
remaining 1000; alice is left holding 1000 stGOV backed by **zero** GOV and her `withdraw()`
reverts. Redemption becomes first-come-first-served.

`ERC20WrapperUpgradeable` rejects `underlying == address(this)` but knows nothing about a
reward token. **Fix:** one line —
`if (address(rewardsToken_) == address(govToken_)) revert ZeroAddress();` (or a dedicated
error).

---

### FF-012 — `totalSupply()` carries three unrelated meanings and is freely movable — flash variant REFUTED, residual is a Pass-2 lead

**Severity:** LEAD (not a finding as it stands)
**State touched (for Pass 2):** `ERC20$.totalSupply` and `Votes$._totalCheckpoints`.
**Verification:** B — PoC (`test_FF012_quorumBaseIsFreelyMovableInOneTransaction`).

`StakedGovToken.totalSupply()` is simultaneously:
1. the reward-accrual denominator (`notifyRewardAmount` L169-172);
2. the treasury-vs-stakers switch (`RevenueRouter` L72);
3. the **Governor quorum base** — `CoinDAOGovernor` is `GovernorVotesQuorumFraction` with
   `quorumDenominator() = 1_000` (L68-70) and `CoinDAOFactory.GOVERNOR_QUORUM_NUMERATOR = 1`,
   so **quorum = 0.1 % of the staked supply at the snapshot block**, not of GOV supply.

Any GOV holder moves all three at will, in one transaction, with no cooldown.

**What I tested and REFUTED.** A same-transaction stake-and-unstake does **not** move
`getPastTotalSupply`: ERC20Votes checkpoints are keyed on block number, so two operations in
one block collapse to the end-of-block value. Measured: base before = base after =
1000e18, despite the supply reaching 5,001,000e18 mid-transaction. **A flash-loan attack on
quorum does not work.** I am recording the refutation because a refutation is a claim too
and this one was worth being wrong about.

**The residual, for Pass 2.** Quorum is 0.1 % of *staked* supply, and the proposal threshold
is an absolute 10,000 stGOV (`GOV_TOKEN_SUPPLY / 1_000`). If total staking participation is
low — which it will be at launch, since the factory stakes nothing and `depositFor` requires
a live Lender (FF-004) — then quorum is a trivially small absolute number. An actor holding
10,000 stGOV can both propose and self-satisfy quorum whenever the staked float is under
~10M stGOV. This crosses `StakedGovToken` (in my scope) and `CoinDAOGovernor` /
`CoinDAOFactory` (not in my scope), so it belongs to the fusion stage, not to this pass.

---

### LOW / INFO findings (verified by inspection or single-assertion PoC)

| ID | Location | Finding | Verdict |
|---|---|---|---|
| FF-009 | `StakedGovToken.sol:176-184` + inherited | `approve`/`permit`/`allowance` are live on a token whose `transferFrom` can never succeed. PoC: `approve` returns true, allowance is stored, `transferFrom` reverts `NonTransferable`. Dead, misleading surface; wallets will show a "spending cap" that means nothing. | LOW |
| FF-010 | `RevenueRouter` inherited | `renounceOwnership()` is reachable by the timelock and permanently removes `setGovStakingBps`, `setManager` and `acceptLenderOperator`, while the router remains the Lender's permanent operator and `distribute()` keeps running at the frozen split. PoC confirms both setters revert afterwards and `distribute()` still pays. | LOW |
| FF-011 | `RevenueRouter.sol:72-74` | With `govStakingBps = 10_000`, a `distribute()` called while `totalSupply() == 0` sends 100 % to the treasury. `plan.md` §7 states this explicitly, so it is intended — but the caller is unprivileged and chooses the moment. PoC: alice withdraws, an attacker calls `distribute()`, the treasury takes 100 COIN. | INFO |
| FF-013 | `RevenueRouter.sol:62-66` | NatSpec calls `acceptLenderOperator` "the one-time operator nomination"; the code enforces nothing one-time and delegates idempotence entirely to the external Lender's `acceptOperator`. | LOW |
| FF-014 | `RevenueRouter.sol:64-66` | `acceptLenderOperator` emits **no event**, while `setGovStakingBps` and `setManager` both do. The permanent capture of an external privileged role is the least observable state change in the contract. (Q3.4) | LOW |
| FF-015 | `StakedGovToken.sol:86-92` | The `account != address(0)` branch in `updateReward` is vestigial: it exists in Synthetix because `notifyRewardAmount` calls `updateReward(address(0))` there, and this `notifyRewardAmount` (L168) does not. No reachable call site passes zero. Harmless, but it is the visible seam where the time-based accrual was removed — worth pointing at in the report as evidence the port was partial. | INFO |
| FF-018 | `RevenueRouter.sol:71-79` + `INotifiableRewardReceiver.sol:12-14` | The interface *requires* `amount` to equal tokens actually received; the router computes it from a pre-transfer `balanceOf` and never checks the delta. PoC shows the consequence is worse than "stakers are short": once the accumulator over-credits, `getReward()` **reverts** on insufficient balance, so rewards are stuck, not merely reduced. Documented as unsupported in three places, hence INFO — but the failure mode should be stated as DoS, not shortfall. | INFO |
| FF-019 | `StakedGovToken.sol:77` | The only string `require` in either contract; everything else uses custom errors. Cosmetic + gas. | INFO |

---

## False positives eliminated

**FF-006 — "the non-upgradeable `ReentrancyGuard` in a clone leaves the guard disarmed."**
`StakedGovToken` inherits OZ's **non-upgradeable** `ReentrancyGuard` (L17) but is deployed
as a minimal-proxy clone (`CoinDAOFactory.sol:387`), so the guard's constructor never runs
against the clone's storage. Hypothesis: the guard is inert.

**REFUTED by execution.** `test_FF006_reentrancyGuardStillBlocksOnAClone` arms a malicious
router that re-enters `getReward()` from inside `harvestYield`, and `depositFor` reverts
with `ReentrancyGuardReentrantCall()`. The guard works, because the check is
`if (_status == ENTERED) revert` — an uninitialised zero is not `ENTERED`, so it passes and
is then set correctly. Additionally, `forge inspect StakedGovToken storage-layout` shows
only the five declared variables at slots 0–4 and no `_status`, so there is no storage
collision with `rewardsToken` (slot 0) either. The only residual is a marginally higher
first-call gas cost. **Not a finding.**

**FF-016 — "an attacker can overflow `rewardPerTokenStored` and permanently brick the
system."** `rewardPerTokenStored += mulDiv(reward, 1e18, supply)` (L172) reverts on
overflow, and `earned()` (L141) reverts if `balance * delta / 1e18` exceeds 2²⁵⁶ — either
would permanently DoS harvests or a victim's withdrawal. The attacker appears to have a
free amplifier: become the sole 1-wei staker, then recycle the same Coin through
`distribute()` → `getReward()` repeatedly, since `distribute()` is permissionless.

**REFUTED by magnitude.** To brick an account holding `B` stGOV you need
`delta >= 2^256 * 1e18 / B`. The pump rate per unit of recycled Coin is `1e18 / supply`, and
`supply >= B` by definition (the victim's balance is part of the supply). Cumulative Coin
recycled must therefore satisfy `(2^256 * 1e18 / B) * (B / 1e18) = 2^256 ≈ 1.16e77` wei —
**independent of `B`**. Even with a 1e26-wei flash loan every cycle, that is ~1.16e51
cycles. Economically unreachable by any margin. Recorded because the derivation, not the
intuition, is what closes it.

---

## Exposed assumptions — consolidated (Category 4)

Ordered by how much of the design rests on them. Items 1–4 are about the external market and
**cannot be resolved from this repository**; they are the questions to put to the client.

| # | Assumption | Where it is relied on | Documented? | Consequence if false |
|---|---|---|---|---|
| 1 | `Lender.pullLocalReserves()` never reverts, including when reserves are zero | `RevenueRouter:69`, reached from `StakedGovToken:82` on the only mint path | no | permanent freeze of staking entry and of the vote-holder set (FF-004) |
| 2 | `pullLocalReserves()` realises **all** economically-accrued revenue at that instant | the anti-JIT property of `StakedGovToken:82` | no — `IRevenueDistributor` says only "synchronizing" | flash-staked capture of ~100 % of accumulated revenue (FF-005) |
| 3 | Every Lender capability that will ever be needed is either `manager`-gated or is `pullLocalReserves`/`setManager` | `RevenueRouter:12-15`, `64-66` | asserted in NatSpec, unevidenced | permanent, unrecoverable loss of Lender capability (FF-017) |
| 4 | The Lender's `acceptOperator()` reverts unless the caller is `pendingOperator` | `RevenueRouter:64-66` "one-time" claim | NatSpec claims one-time; code enforces nothing | operator role could be re-taken/handed unexpectedly (FF-013) |
| 5 | Coin has ~18 decimals | `REWARD_PRECISION = 1e18` at `StakedGovToken:36`, used at `:172` | no | sub-threshold harvests destroyed outright (FF-001) |
| 6 | Coin has no transfer callback | `RevenueRouter:77-83` ordering | NatSpec excludes fee-on-transfer and rebasing only — **a callback token is neither** | every harvest revertible; `depositFor` bricked (FF-007) |
| 7 | Coin delivers exactly the requested amount | `RevenueRouter:71-79` → `notifyRewardAmount` | yes, in three places | over-credit makes `getReward()` revert; rewards stuck (FF-018) |
| 8 | Coin is not pausable and does not blocklist the Timelock, `StakedGovToken`, or any staker | `RevenueRouter:78,82`; `_payReward:161` | no | harvest DoS (chains into FF-004); blocklisted users lose `harvestAndWithdraw` but keep `withdraw` |
| 9 | `rewardsToken != underlying` | assumed by the whole reward layer | no | wrapper backing pays rewards; redemption becomes first-come-first-served (FF-008) |
| 10 | `govStaking.revenueRouter == this` and `coin == lender.coin()` | both `initialize` functions | no | permanently misrouted revenue on an unrepairable clone (FF-017) |
| 11 | GOV is a plain 18-decimal ERC-20 with no hooks | `ERC20Wrapper` 1:1 backing | yes (`StakedGovToken:25-26`) | wrapper accounting breaks — correctly excluded |

---

## Ordering concerns — consolidated (Category 7)

**Part A — within a transaction**

| # | Ordering | Swap test | Verdict |
|---|---|---|---|
| 1 | `depositFor`: harvest → settle → mint | moving the harvest after the mint lets the depositor capture pre-existing revenue | **correct as written and load-bearing**; the repo's own test asserts it |
| 2 | `harvestAndWithdraw`: harvest → settle → burn → pay | the burn must follow the settlement, and the settlement must follow the harvest | correct |
| 3 | `_payReward`: zero `rewards[a]` → transfer | swapping enables re-entrant double-claim | correct (CEI) |
| 4 | `distribute`: pull → read supply → transfer to staker → notify → transfer to treasury | the treasury transfer is the **last** external call, so it is the one that fails when a nested call has drained the balance; and `totalSupply()` is read twice across a transfer | **fragile — FF-007** |
| 5 | `harvestAndWithdraw` calls `super.withdrawTo`, not the override | calling the override would self-deadlock `nonReentrant` | correct, and non-obvious |
| 6 | `setManager`: external call → emit | correct (do not log an action that may revert) | correct |

**Part B — across transactions**

| # | Accumulation | Verdict |
|---|---|---|
| 7 | Remainder discarded on every `notifyRewardAmount` (Q7.7) | FF-001 — measured 0 ppm/yr at 18 decimals, 100 % at 6 |
| 8 | `govStakingBps` read at harvest time applies to the whole un-harvested stock (Q7.5/7.6) | FF-002 |
| 9 | Exits do not settle; the forfeited share is redistributed to stayers at the next harvest (Q7.6) | FF-003 |
| 10 | `rewardPerTokenStored` monotone and never reset (Q7.7) | SOUND — makes the L141 subtraction underflow-free |
| 11 | Repeated `depositFor` by the same account across harvests | SOUND — 256-run fuzz, solvency and conservation hold at every step |
| 12 | Cross-user pollution (T1 from a different user) | SOUND — same fuzz, 4 users, randomised interleaving |
| 13 | Attacker-chosen sequence deposit→realize→distribute→claim→withdraw in one tx (Q7.8) | FF-005 |

---

## Summary

- Functions analysed: **21** state-changing entry points (14 on `StakedGovToken`, 7 on
  `RevenueRouter`, enumerated from the compiled ABI) + 19 view functions + 3 modifiers +
  2 internals, across 2 contracts and 2 interfaces; 312 lines interrogated.
- Raw findings (pre-verification): 4 CRITICAL/HIGH, 6 MEDIUM, 9 LOW/INFO.
- After verification: **17 TRUE POSITIVE · 2 FALSE POSITIVE · 4 DOWNGRADED · 1 split into a
  refuted half and a lead.**
- Final: **2 HIGH (both stated as leads pending client answers about the external Lender) ·
  2 MEDIUM + 1 MEDIUM design · 6 LOW · 5 INFO · 1 Pass-2 lead.**
- Verification: 21/21 PoC tests pass; 256-run conservation fuzz passes; all absence claims
  checked against the compiled ABI rather than by grep.
- The audited tree at `[scratch]` was not modified; its 55/55 suite was re-run and is
  green.

**The strongest thing found:** the reward layer's own arithmetic is sound (fuzz-verified
solvent and conserving under adversarial interleaving), and its access control is complete.
Every material risk in this lane is either an **ordering gap between the two contracts**
(FF-002, FF-003) or an **unverifiable assumption about the external lending market**
(FF-004, FF-005, FF-017). The two leads are not gradable from this repository and must be
put to the client as questions.

**Handoff to Pass 2 — the coupled pairs this pass exercised, and where they were left:**

| coupled pair | status after Pass 1 |
|---|---|
| `rewardPerTokenStored` ↔ `ERC20$.totalSupply` | remainder discarded (FF-001); JIT-exposed if the harvest is incomplete (FF-005) |
| `rewards[a]` ↔ `userRewardPerTokenPaid[a]` ↔ `ERC20$.balances[a]` | fuzz-verified consistent; every writer settles before mutating |
| `RevenueRouter.govStakingBps` ↔ un-harvested Lender reserves | **not settled on change (FF-002)** — the un-harvested stock is state in a third contract |
| `StakedGovToken` GOV backing ↔ `ERC20$.totalSupply` | holds, unless `rewardsToken == underlying` (FF-008) |
| `Coin.balanceOf(StakedGovToken)` ↔ `Σ rewards` | diverges monotonically by the discarded remainder (FF-001); never under-collateralised (fuzz) |
| `ERC20$.totalSupply` ↔ Governor quorum base | flash manipulation REFUTED; low-float quorum is a live lead (FF-012) |
| `RevenueRouter.lender/coin/treasury/govStaking` ↔ deployed reality | unvalidated and permanently unrepairable (FF-017) |
