// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CoinDAOFactory} from "../src/CoinDAOFactory.sol";
import {CoinDAOGovernor} from "../src/CoinDAOGovernor.sol";
import {RevenueRouter} from "../src/RevenueRouter.sol";
import {StakedGovToken} from "../src/StakedGovToken.sol";
import {StakingRewards} from "../src/StakingRewards.sol";
import {StakingRewardsFunder} from "../src/StakingRewardsFunder.sol";
import {CoinDAOTestBase} from "./helpers/CoinDAOTestBase.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockMonolithLender} from "./mocks/MockMonolith.sol";

/// @dev All time arithmetic derives from the compile-time constant T0 — see the
/// `via-ir` timestamp trap recorded in .audit/findings/nemesis-verified.md.
contract NemesisPoC4 is CoinDAOTestBase {
    uint256 internal constant T0 = 1_700_000_000;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal carol = address(0xCAF0);

    function setUp() public override {
        vm.warp(T0);
        super.setUp();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // H1 — tranche 0 emissions burn from the block of deployment (NM-001 recheck)
    // ─────────────────────────────────────────────────────────────────────────
    function testH1_TrancheZeroBurnsFromDeploymentBlock() public {
        CoinDAOFactory.Deployment memory d = _deploy(0, CoinDAOFactory.StakingTokenChoice.Coin);
        StakingRewards sr = StakingRewards(d.coinStakingRewards);
        StakingRewardsFunder funder = StakingRewardsFunder(d.coinStakingRewardsFunder);

        uint256 tranche0 = funder.totalRewards() * 3250 / 10000;
        assertEq(IERC20(d.govToken).balanceOf(address(sr)), tranche0, "tranche 0 funded at deploy");
        assertEq(sr.totalSupply(), 0, "no stakers at deploy");
        assertEq(sr.periodFinish(), T0 + 365 days, "period already running");

        // The Coin market was minted in this same transaction: nobody can hold Coin yet.
        assertEq(MockERC20(d.coin).totalSupply(), 0, "coin supply provably zero at launch");

        // 7 idle days, then the first staker arrives.
        vm.warp(T0 + 7 days);
        deal(d.coin, alice, 1_000 ether, true);
        vm.startPrank(alice);
        IERC20(d.coin).approve(address(sr), 1_000 ether);
        sr.stake(1_000 ether);
        vm.stopPrank();

        // Run the rest of the period out and claim everything reachable.
        vm.warp(T0 + 365 days);
        vm.prank(alice);
        sr.getReward();

        uint256 claimed = IERC20(d.govToken).balanceOf(alice);
        uint256 stranded = IERC20(d.govToken).balanceOf(address(sr));

        emit log_named_decimal_uint("tranche 0 GOV        ", tranche0, 18);
        emit log_named_decimal_uint("claimed by 1st staker", claimed, 18);
        emit log_named_decimal_uint("stranded in rewards  ", stranded, 18);
        emit log_named_decimal_uint("burn per idle day    ", tranche0 / 365, 18);

        assertApproxEqRel(stranded, tranche0 * 7 / 365, 1e15, "7 idle days burn 7/365 of the tranche");

        // Unrecoverable: no owner, no recoverERC20, rewardsDistribution frozen on the funder.
        assertEq(sr.owner(), address(0), "ownership renounced at deploy");
        assertEq(sr.rewardsDistribution(), d.coinStakingRewardsFunder, "distribution frozen");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // H2 — the same burn recurs any time staked supply returns to zero
    // ─────────────────────────────────────────────────────────────────────────
    function testH2_BurnRecursWheneverStakedSupplyHitsZero() public {
        CoinDAOFactory.Deployment memory d = _deploy(0, CoinDAOFactory.StakingTokenChoice.Coin);
        StakingRewards sr = StakingRewards(d.coinStakingRewards);

        deal(d.coin, alice, 1_000 ether, true);
        vm.startPrank(alice);
        IERC20(d.coin).approve(address(sr), 1_000 ether);
        sr.stake(1_000 ether);
        vm.stopPrank();

        // Alice exits entirely at T0 + 100d, leaving supply at zero for 30 days.
        vm.warp(T0 + 100 days);
        vm.prank(alice);
        sr.withdraw(1_000 ether);
        assertEq(sr.totalSupply(), 0);

        uint256 rptAtExit = sr.rewardPerToken();
        vm.warp(T0 + 130 days);
        assertEq(sr.rewardPerToken(), rptAtExit, "no accrual while supply is zero");

        // Carol stakes: the 30 idle days are discarded, not carried forward.
        deal(d.coin, carol, 1_000 ether, true);
        vm.startPrank(carol);
        IERC20(d.coin).approve(address(sr), 1_000 ether);
        sr.stake(1_000 ether);
        vm.stopPrank();
        assertEq(sr.lastUpdateTime(), T0 + 130 days, "lastUpdateTime jumps forward, gap discarded");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // H3 — a withdrawing sGOV staker forfeits unharvested revenue; anyone can
    //      back-run the withdrawal with the permissionless distribute() to take it
    // ─────────────────────────────────────────────────────────────────────────
    function testH3_BackRunningAWithdrawalCapturesTheWithdrawersRevenue() public {
        CoinDAOFactory.Deployment memory d = _deploy(0, CoinDAOFactory.StakingTokenChoice.Coin);
        StakedGovToken staker = StakedGovToken(d.staker);
        RevenueRouter router = RevenueRouter(d.revenueRouter);
        MockMonolithLender lender = MockMonolithLender(d.lender);

        _stakeGov(d, alice, 1_000 ether);
        _stakeGov(d, bob, 1_000 ether);

        // One week of protocol revenue accrues in the lender, unharvested.
        lender.setAccruedLocalReserves(100_000 ether);

        // Bob exits. withdrawTo carries no harvestYield, so the pending week is
        // still sitting in the lender and Bob's checkpoint closes without it.
        vm.prank(bob);
        staker.withdraw();
        assertEq(staker.earned(bob), 0, "Bob's accrual closes at the pre-harvest index");

        // Anyone can back-run with the permissionless distribute().
        vm.prank(carol);
        router.distribute();

        assertEq(staker.earned(bob), 0, "Bob gets nothing");
        assertEq(staker.earned(alice), 100_000 ether, "Alice takes the whole week");

        emit log_named_decimal_uint("Bob's fair share  ", uint256(50_000 ether), 18);
        emit log_named_decimal_uint("Bob actually earns", staker.earned(bob), 18);
        emit log_named_decimal_uint("Alice captures    ", staker.earned(alice), 18);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // H4 — the same leak sends revenue to the treasury when the last staker exits
    // ─────────────────────────────────────────────────────────────────────────
    function testH4_LastStakerExitDivertsPendingRevenueToTreasury() public {
        CoinDAOFactory.Deployment memory d = _deploy(0, CoinDAOFactory.StakingTokenChoice.Coin);
        StakedGovToken staker = StakedGovToken(d.staker);
        RevenueRouter router = RevenueRouter(d.revenueRouter);
        MockMonolithLender lender = MockMonolithLender(d.lender);

        _stakeGov(d, alice, 1_000 ether);
        lender.setAccruedLocalReserves(100_000 ether);

        vm.prank(alice);
        staker.withdraw();
        assertEq(staker.totalSupply(), 0);

        router.distribute();
        assertEq(IERC20(d.coin).balanceOf(d.timelock), 100_000 ether, "all revenue diverted to treasury");
        assertEq(staker.earned(alice), 0, "sole staker forfeits a full period of revenue");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // H5 — a reverting distribute() bricks every path into the electorate
    // ─────────────────────────────────────────────────────────────────────────
    function testH5_DistributeFailureFreezesTheElectorate() public {
        CoinDAOFactory.Deployment memory d = _deploy(0, CoinDAOFactory.StakingTokenChoice.Coin);
        StakedGovToken staker = StakedGovToken(d.staker);

        _stakeGov(d, alice, 1_000 ether);

        // Any upstream revert inside distribute() — here modelled on the lender call.
        vm.mockCallRevert(d.lender, abi.encodeWithSignature("pullLocalReserves()"), "UPSTREAM");

        deal(d.govToken, bob, 1_000 ether, true);
        vm.startPrank(bob);
        IERC20(d.govToken).approve(d.staker, 1_000 ether);
        vm.expectRevert();
        staker.depositFor(bob, 1_000 ether);
        vm.stopPrank();

        // Incumbents keep full voting power and can still exit; challengers cannot enter.
        assertEq(staker.getVotes(alice), 1_000 ether);
        vm.prank(alice);
        staker.withdrawTo(alice, 1 ether);
        assertEq(staker.balanceOf(bob), 0, "no path into sGOV while distribute() reverts");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // H6 — sGOV reward solvency under an adversarial multi-user sequence
    // ─────────────────────────────────────────────────────────────────────────
    function testFuzzH6_StakedGovRewardsStaySolvent(uint96[8] memory stakes, uint96[8] memory revenues) public {
        CoinDAOFactory.Deployment memory d = _deploy(0, CoinDAOFactory.StakingTokenChoice.Coin);
        StakedGovToken staker = StakedGovToken(d.staker);
        RevenueRouter router = RevenueRouter(d.revenueRouter);
        MockMonolithLender lender = MockMonolithLender(d.lender);

        address[3] memory users = [alice, bob, carol];
        uint256 totalNotified;

        for (uint256 i; i < 8; ++i) {
            address u = users[i % 3];
            uint256 amt = uint256(stakes[i]) % 1_000 ether;
            if (amt != 0) {
                deal(d.govToken, u, amt, true);
                vm.startPrank(u);
                IERC20(d.govToken).approve(d.staker, amt);
                staker.depositFor(u, amt);
                vm.stopPrank();
            }
            uint256 rev = uint256(revenues[i]) % 100_000 ether;
            if (rev != 0) {
                lender.setAccruedLocalReserves(rev);
                (, uint256 toStakers) = router.distribute();
                totalNotified += toStakers;
            }
            // partial exit for a different user
            address v = users[(i + 1) % 3];
            uint256 bal = staker.balanceOf(v);
            if (bal > 1) {
                vm.prank(v);
                staker.withdrawTo(v, bal / 2);
            }
        }

        uint256 owed = staker.earned(alice) + staker.earned(bob) + staker.earned(carol);
        uint256 held = IERC20(d.coin).balanceOf(d.staker);
        assertLe(owed, held, "accrued rewards must never exceed Coin held");
        assertEq(held, totalNotified, "every notified wei landed in the staker");

        // everyone can actually claim
        for (uint256 i; i < 3; ++i) {
            vm.prank(users[i]);
            staker.getReward();
        }
        assertEq(staker.earned(alice) + staker.earned(bob) + staker.earned(carol), 0);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // H7 — quorum is measured against staked supply, but only delegated supply votes
    // ─────────────────────────────────────────────────────────────────────────
    function testH7_QuorumCountsUndelegatedSupplyThatCannotVote() public {
        CoinDAOFactory.Deployment memory d = _deploy(0, CoinDAOFactory.StakingTokenChoice.Coin);
        StakedGovToken staker = StakedGovToken(d.staker);

        // Alice stakes and delegates. Bob stakes and never delegates (the default).
        _stakeGov(d, alice, 10_000 ether);
        deal(d.govToken, bob, 990_000 ether, true);
        vm.startPrank(bob);
        IERC20(d.govToken).approve(d.staker, 990_000 ether);
        staker.depositFor(bob, 990_000 ether);
        vm.stopPrank();

        vm.roll(block.number + 1);
        uint256 tp = block.number - 1;

        assertEq(staker.getPastTotalSupply(tp), 1_000_000 ether, "quorum base counts all staked sGOV");
        assertEq(staker.getPastVotes(alice, tp), 10_000 ether);
        assertEq(staker.getPastVotes(bob, tp), 0, "undelegated stake has no voting power");

        emit log_named_decimal_uint("quorum base (staked) ", staker.getPastTotalSupply(tp), 18);
        emit log_named_decimal_uint("actually votable     ", staker.getPastVotes(alice, tp), 18);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // H8 — predicted deployerVesting address is returned even when none is deployed
    // ─────────────────────────────────────────────────────────────────────────
    function testH8_PredictionReturnsADeployerVestingThatIsNeverDeployed() public {
        bytes32 salt = _nextSalt();
        CoinDAOFactory.GovLaunchParams memory p = _govParams(0, CoinDAOFactory.StakingTokenChoice.Coin);
        CoinDAOFactory.PredictedAddresses memory pred = factory.predictCoinDAOAddresses(address(this), salt, p);
        CoinDAOFactory.Deployment memory d = factory.deploy(salt, p, _monolithParams(), manager);

        assertTrue(pred.deployerVesting != address(0), "prediction returns an address");
        assertEq(d.deployerVesting, address(0), "deployment records none");
        assertEq(pred.deployerVesting.code.length, 0, "nothing was ever deployed there");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // H9 — quorum is structurally <= the proposal threshold, for every possible
    //      staked supply, so it can never bind on a proposer who can propose
    // ─────────────────────────────────────────────────────────────────────────
    function testFuzzH9_QuorumCanNeverExceedTheProposalThreshold(uint256 stakedSupply) public {
        CoinDAOFactory.Deployment memory d = _deploy(0, CoinDAOFactory.StakingTokenChoice.Coin);
        StakedGovToken staker = StakedGovToken(d.staker);
        CoinDAOGovernor gov = CoinDAOGovernor(payable(d.governor));

        stakedSupply = bound(stakedSupply, 1 ether, factory.GOV_TOKEN_SUPPLY());
        deal(d.govToken, alice, stakedSupply, true);
        vm.startPrank(alice);
        IERC20(d.govToken).approve(d.staker, stakedSupply);
        staker.depositFor(alice, stakedSupply);
        staker.delegate(alice);
        vm.stopPrank();

        vm.roll(block.number + 1);
        uint256 q = gov.quorum(block.number - 1);
        assertLe(q, gov.proposalThreshold(), "quorum never exceeds the bar to propose");
        assertEq(q, staker.getPastTotalSupply(block.number - 1) / 1_000);
    }

    function testH9b_LoneProposerAtThresholdClearsQuorumTenfold() public {
        CoinDAOFactory.Deployment memory d = _deploy(0, CoinDAOFactory.StakingTokenChoice.Coin);
        StakedGovToken staker = StakedGovToken(d.staker);
        CoinDAOGovernor gov = CoinDAOGovernor(payable(d.governor));

        // 10% of GOV staked; the proposer holds exactly the proposal threshold.
        _stakeGov(d, alice, gov.proposalThreshold());
        deal(d.govToken, bob, 990_000 ether, true);
        vm.startPrank(bob);
        IERC20(d.govToken).approve(d.staker, 990_000 ether);
        staker.depositFor(bob, 990_000 ether);
        staker.delegate(bob);
        vm.stopPrank();

        vm.roll(block.number + 1);
        uint256 tp = block.number - 1;
        emit log_named_decimal_uint("proposal threshold", gov.proposalThreshold(), 18);
        emit log_named_decimal_uint("quorum @1M staked ", gov.quorum(tp), 18);
        assertEq(gov.quorum(tp), 1_000 ether);
        assertEq(gov.proposalThreshold(), 10_000 ether);
        assertGe(staker.getPastVotes(alice, tp), gov.quorum(tp) * 10, "proposer alone is 10x quorum");
    }
}
