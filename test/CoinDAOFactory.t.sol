// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {VestingWallet} from "@openzeppelin/contracts/finance/VestingWallet.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";

import {CoinDAOFactory} from "../src/CoinDAOFactory.sol";
import {CoinDAOGovernor} from "../src/CoinDAOGovernor.sol";
import {GovToken} from "../src/GovToken.sol";
import {RevenueRouter} from "../src/RevenueRouter.sol";
import {StakedGovToken} from "../src/StakedGovToken.sol";
import {StakingRewards} from "../src/StakingRewards.sol";
import {StakingRewardsFunder} from "../src/StakingRewardsFunder.sol";
import {IMonolithFactory} from "../src/interfaces/IMonolith.sol";
import {MockMonolithFactory, MockMonolithLender} from "./mocks/MockMonolith.sol";

contract CoinDAOFactoryTest is Test {
    event QuorumSet(uint256 oldQuorum, uint256 newQuorum);

    CoinDAOFactory internal factory;
    MockMonolithFactory internal monolithFactory;

    address internal manager = address(0x1001);
    address internal deployerRecipient = address(0x1002);
    address internal monolithRecipient = address(0x1003);

    function setUp() public {
        monolithFactory = new MockMonolithFactory();
        factory = new CoinDAOFactory(IMonolithFactory(address(monolithFactory)));
    }

    function testConstructorRejectsZeroMonolithFactory() public {
        vm.expectRevert(CoinDAOFactory.ZeroAddress.selector);
        new CoinDAOFactory(IMonolithFactory(address(0)));
    }

    function testAllocationForZeroDeployerStake() public view {
        uint256 supply = factory.GOV_TOKEN_SUPPLY();
        CoinDAOFactory.AllocationAmounts memory allocation = factory.allocationFor(0);
        uint256 remainingAllocation = supply - allocation.monolithVesting - allocation.deployerVesting;
        uint256 treasuryAllocation = remainingAllocation - allocation.coinStakingRewards;

        assertEq(allocation.monolithVesting, (supply * 200) / 10_000);
        assertEq(allocation.deployerVesting, 0);
        assertEq(allocation.coinStakingRewards, (remainingAllocation * 6_666) / 10_000);
        assertEq(allocation.immediateTreasuryAllocation, (treasuryAllocation * 1_000) / 10_000);
        assertEq(allocation.treasuryVested, treasuryAllocation - allocation.immediateTreasuryAllocation);
        assertEq(_sum(allocation), supply);
    }

    function testAllocationForMaxDeployerStake() public view {
        uint256 supply = factory.GOV_TOKEN_SUPPLY();
        CoinDAOFactory.AllocationAmounts memory allocation = factory.allocationFor(2_000);
        uint256 remainingAllocation = supply - allocation.monolithVesting - allocation.deployerVesting;
        uint256 treasuryAllocation = remainingAllocation - allocation.coinStakingRewards;

        assertEq(allocation.monolithVesting, (supply * 200) / 10_000);
        assertEq(allocation.deployerVesting, (supply * 2_000) / 10_000);
        assertEq(allocation.coinStakingRewards, (remainingAllocation * 6_666) / 10_000);
        assertEq(allocation.immediateTreasuryAllocation, (treasuryAllocation * 1_000) / 10_000);
        assertEq(allocation.treasuryVested, treasuryAllocation - allocation.immediateTreasuryAllocation);
        assertEq(_sum(allocation), supply);
    }

    function testAllocationRejectsTooMuchDeployerStake() public {
        vm.expectRevert(abi.encodeWithSelector(CoinDAOFactory.DeployerStakeExceedsMaximum.selector, 2_001));
        factory.allocationFor(2_001);
    }

    function testDeployWiresCoinStakingLaunch() public {
        CoinDAOFactory.Deployment memory deployment =
            factory.deploy(_params(1_000, CoinDAOFactory.StakingTokenChoice.Coin));
        CoinDAOFactory.AllocationAmounts memory allocation = factory.allocationFor(1_000);

        assertEq(factory.deploymentsLength(), 1);
        assertEq(deployment.stakingToken, deployment.coin);
        assertEq(CoinDAOGovernor(payable(deployment.governor)).name(), "Example GOV Governor");
        assertEq(MockMonolithLender(deployment.lender).operator(), deployment.revenueRouter);
        assertEq(MockMonolithLender(deployment.lender).manager(), manager);

        GovToken govToken = GovToken(deployment.govToken);
        StakingRewardsFunder rewardsFunder = StakingRewardsFunder(deployment.coinStakingRewardsFunder);
        uint256 firstTranche = rewardsFunder.trancheAmounts(0);

        assertEq(govToken.totalSupply(), factory.GOV_TOKEN_SUPPLY());
        assertEq(govToken.balanceOf(deployment.coinStakingRewards), firstTranche);
        assertEq(govToken.balanceOf(deployment.coinStakingRewardsFunder), allocation.coinStakingRewards - firstTranche);
        assertEq(govToken.balanceOf(deployment.timelock), allocation.immediateTreasuryAllocation);
        assertEq(govToken.balanceOf(deployment.treasuryVesting), allocation.treasuryVested);
        assertEq(govToken.balanceOf(deployment.monolithVesting), allocation.monolithVesting);
        assertEq(govToken.balanceOf(deployment.deployerVesting), allocation.deployerVesting);

        assertEq(Ownable(deployment.coinStakingRewards).owner(), address(0));
        assertEq(
            StakingRewards(deployment.coinStakingRewards).rewardsDistribution(), deployment.coinStakingRewardsFunder
        );
        assertEq(
            StakingRewards(deployment.coinStakingRewards).rewardsDuration(), factory.COIN_STAKING_REWARD_DURATION()
        );
        assertEq(factory.COIN_STAKING_REWARD_DURATION(), 365 days);
        assertEq(address(rewardsFunder.stakingRewards()), deployment.coinStakingRewards);
        assertEq(address(rewardsFunder.rewardsToken()), deployment.govToken);
        assertEq(rewardsFunder.totalRewards(), allocation.coinStakingRewards);
        assertEq(rewardsFunder.nextTranche(), 1);
        CoinDAOGovernor governor = CoinDAOGovernor(payable(deployment.governor));
        StakedGovToken staker = StakedGovToken(deployment.staker);

        assertEq(address(governor.token()), deployment.staker);
        assertEq(governor.quorum(block.number), factory.GOVERNOR_QUORUM());
        assertEq(staker.rewardsDistribution(), deployment.revenueRouter);
        assertEq(staker.rewardsDuration(), factory.GOV_STAKING_REWARD_DURATION());
        assertEq(Ownable(deployment.revenueRouter).owner(), deployment.timelock);
        assertEq(VestingWallet(payable(deployment.treasuryVesting)).owner(), deployment.timelock);
        assertEq(VestingWallet(payable(deployment.monolithVesting)).owner(), monolithRecipient);
        assertEq(VestingWallet(payable(deployment.deployerVesting)).owner(), deployerRecipient);
        assertEq(RevenueRouter(deployment.revenueRouter).govStakingBps(), 10_000);
        assertFalse(TimelockController(payable(deployment.timelock)).hasRole(bytes32(0), address(factory)));
    }

    function testDeployWiresSCoinStakingLaunch() public {
        CoinDAOFactory.Deployment memory deployment =
            factory.deploy(_params(0, CoinDAOFactory.StakingTokenChoice.SCoin));

        assertEq(deployment.stakingToken, deployment.vault);
        assertEq(deployment.deployerVesting, address(0));
    }

    function testGovernorSetQuorumRejectsDirectCalls() public {
        CoinDAOFactory.Deployment memory deployment = factory.deploy(_params(0, CoinDAOFactory.StakingTokenChoice.Coin));
        CoinDAOGovernor governor = CoinDAOGovernor(payable(deployment.governor));

        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorOnlyExecutor.selector, address(this)));
        governor.setQuorum(1);
    }

    function testGovernorSetsQuorumThroughGovernance() public {
        CoinDAOFactory.Deployment memory deployment = factory.deploy(_params(0, CoinDAOFactory.StakingTokenChoice.Coin));
        CoinDAOGovernor governor = CoinDAOGovernor(payable(deployment.governor));
        uint256 oldQuorum = governor.quorum(block.number);
        uint256 newQuorum = oldQuorum * 2;

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash) =
            _passAndQueueQuorumProposal(deployment, newQuorum, "Raise quorum");

        vm.warp(block.timestamp + factory.DEFAULT_TIMELOCK_DELAY());
        vm.expectEmit(false, false, false, true, address(governor));
        emit QuorumSet(oldQuorum, newQuorum);
        governor.execute(targets, values, calldatas, descriptionHash);

        assertEq(governor.quorum(0), newQuorum);
        assertEq(governor.quorum(block.number), newQuorum);
    }

    function testGovernorConstructorRejectsInvalidQuorum() public {
        CoinDAOFactory.Deployment memory deployment = factory.deploy(_params(0, CoinDAOFactory.StakingTokenChoice.Coin));
        uint256 proposalThreshold = factory.GOVERNOR_PROPOSAL_THRESHOLD();
        uint256 excessiveQuorum = factory.GOV_TOKEN_SUPPLY() + 1;

        vm.expectRevert(abi.encodeWithSelector(CoinDAOGovernor.InvalidQuorum.selector, 0));
        new CoinDAOGovernor(
            "Invalid Governor",
            StakedGovToken(deployment.staker),
            TimelockController(payable(deployment.timelock)),
            proposalThreshold,
            0
        );

        vm.expectRevert(abi.encodeWithSelector(CoinDAOGovernor.InvalidQuorum.selector, excessiveQuorum));
        new CoinDAOGovernor(
            "Invalid Governor",
            StakedGovToken(deployment.staker),
            TimelockController(payable(deployment.timelock)),
            proposalThreshold,
            excessiveQuorum
        );
    }

    function testGovernorConstructorAcceptsQuorumBoundaries() public {
        CoinDAOFactory.Deployment memory deployment = factory.deploy(_params(0, CoinDAOFactory.StakingTokenChoice.Coin));
        TimelockController timelock = TimelockController(payable(deployment.timelock));
        StakedGovToken staker = StakedGovToken(deployment.staker);

        vm.expectEmit(false, false, false, true);
        emit QuorumSet(0, 1);
        CoinDAOGovernor minimumGovernor =
            new CoinDAOGovernor("Minimum Governor", staker, timelock, factory.GOVERNOR_PROPOSAL_THRESHOLD(), 1);
        CoinDAOGovernor maximumGovernor = new CoinDAOGovernor(
            "Maximum Governor", staker, timelock, factory.GOVERNOR_PROPOSAL_THRESHOLD(), factory.GOV_TOKEN_SUPPLY()
        );

        assertEq(minimumGovernor.quorum(block.number), 1);
        assertEq(maximumGovernor.quorum(block.number), factory.GOV_TOKEN_SUPPLY());
    }

    function testDeployTwiceKeepsRevenueRouterAsRewardsDistribution() public {
        CoinDAOFactory.Deployment memory first = factory.deploy(_params(1_000, CoinDAOFactory.StakingTokenChoice.Coin));
        CoinDAOFactory.Deployment memory second = factory.deploy(_params(0, CoinDAOFactory.StakingTokenChoice.SCoin));

        assertEq(StakedGovToken(first.staker).rewardsDistribution(), first.revenueRouter);
        assertEq(StakedGovToken(second.staker).rewardsDistribution(), second.revenueRouter);
    }

    function testCoinStakingFunderReleasesSecondTranchePermissionlessly() public {
        CoinDAOFactory.Deployment memory deployment = factory.deploy(_params(0, CoinDAOFactory.StakingTokenChoice.Coin));
        GovToken govToken = GovToken(deployment.govToken);
        StakingRewards rewards = StakingRewards(deployment.coinStakingRewards);
        StakingRewardsFunder rewardsFunder = StakingRewardsFunder(deployment.coinStakingRewardsFunder);

        uint256 firstTranche = rewardsFunder.trancheAmounts(0);
        uint256 secondTranche = rewardsFunder.trancheAmounts(1);

        vm.warp(rewards.periodFinish());
        vm.prank(address(0xCA11));
        rewardsFunder.fundNextTranche();

        assertEq(rewardsFunder.nextTranche(), 2);
        assertEq(govToken.balanceOf(address(rewards)), firstTranche + secondTranche);
        assertEq(
            govToken.balanceOf(address(rewardsFunder)), rewardsFunder.totalRewards() - firstTranche - secondTranche
        );
    }

    function testRouterDistributesRevenueToStakerByDefault() public {
        CoinDAOFactory.Deployment memory deployment = factory.deploy(_params(0, CoinDAOFactory.StakingTokenChoice.Coin));
        MockMonolithLender lender = MockMonolithLender(deployment.lender);
        address newManager = address(0xBEEF);

        vm.prank(deployment.timelock);
        RevenueRouter(deployment.revenueRouter).setManager(newManager);
        assertEq(lender.manager(), newManager);

        lender.setAccruedLocalReserves(100 ether);
        RevenueRouter(deployment.revenueRouter).distribute();
        assertEq(IERC20(deployment.coin).balanceOf(deployment.staker), 100 ether);
        assertEq(IERC20(deployment.coin).balanceOf(deployment.timelock), 0);
        assertEq(lender.accruedLocalReserves(), 0);
        assertEq(StakedGovToken(deployment.staker).queuedRewards(), 100 ether);
        assertEq(StakedGovToken(deployment.staker).periodFinish(), 0);
    }

    function testStakerEarnsCoinRevenueAndPreservesVotes() public {
        CoinDAOFactory.Deployment memory deployment = factory.deploy(_params(0, CoinDAOFactory.StakingTokenChoice.Coin));
        address alice = address(0xA11CE);
        deal(deployment.govToken, alice, 100 ether, true);

        StakedGovToken staker = StakedGovToken(deployment.staker);

        vm.startPrank(alice);
        IERC20(deployment.govToken).approve(deployment.staker, 100 ether);
        staker.depositFor(alice, 100 ether);
        staker.delegate(alice);
        vm.stopPrank();

        // Staked GOV is the governor vote token; raw GOV has no voting power.
        vm.roll(block.number + 1);
        assertEq(staker.getVotes(alice), 100 ether);
        assertEq(IERC20(deployment.govToken).balanceOf(deployment.staker), 100 ether);
        assertEq(staker.balanceOf(alice), 100 ether);

        // Revenue routed to the staker streams to the sole staker over the reward duration.
        deal(deployment.coin, deployment.revenueRouter, 30 ether, true);
        RevenueRouter(deployment.revenueRouter).distribute();

        vm.warp(block.timestamp + 30 days);
        vm.prank(alice);
        staker.getReward();
        assertApproxEqAbs(IERC20(deployment.coin).balanceOf(alice), 30 ether, 1e12);
    }

    function _params(uint16 deployerStakeBps, CoinDAOFactory.StakingTokenChoice stakingTokenChoice)
        internal
        view
        returns (CoinDAOFactory.LaunchParams memory params)
    {
        params.govTokenName = "Example GOV";
        params.govTokenSymbol = "xGOV";
        params.monolithParams = IMonolithFactory.DeployParams({
            name: "Example Coin",
            symbol: "xUSD",
            collateral: address(0x2001),
            psmAsset: address(0x2002),
            psmVault: address(0x2003),
            feed: address(0x2004),
            collateralFactor: 0,
            minDebt: 0,
            timeUntilImmutability: 0,
            operator: address(0),
            manager: address(0),
            eventTriggerOperator: address(0),
            halfLife: 0,
            targetPsmDebtRatioStartBps: 0,
            targetPsmDebtRatioEndBps: 0,
            stalenessThreshold: 0,
            maxBorrowDeltaBps: 0,
            psmVaultMinTotalSupply: 0
        });
        params.deployerStakeBps = deployerStakeBps;
        params.deployerRecipient = deployerStakeBps == 0 ? address(0) : deployerRecipient;
        params.monolithRecipient = monolithRecipient;
        params.manager = manager;
        params.stakingTokenChoice = stakingTokenChoice;
    }

    function _passAndQueueQuorumProposal(
        CoinDAOFactory.Deployment memory deployment,
        uint256 newQuorum,
        string memory description
    )
        internal
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash)
    {
        CoinDAOGovernor governor = CoinDAOGovernor(payable(deployment.governor));
        StakedGovToken staker = StakedGovToken(deployment.staker);
        address voter = address(0xA11CE);
        uint256 votingPower = governor.quorum(block.number) + 1;

        deal(deployment.govToken, voter, votingPower, true);
        vm.startPrank(voter);
        IERC20(deployment.govToken).approve(deployment.staker, votingPower);
        staker.depositFor(voter, votingPower);
        staker.delegate(voter);
        vm.stopPrank();
        vm.roll(block.number + 1);

        targets = new address[](1);
        targets[0] = address(governor);
        values = new uint256[](1);
        calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(governor.setQuorum, (newQuorum));
        descriptionHash = keccak256(bytes(description));

        vm.prank(voter);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);
        vm.roll(governor.proposalSnapshot(proposalId) + 1);
        vm.prank(voter);
        governor.castVote(proposalId, 1);
        vm.roll(governor.proposalDeadline(proposalId) + 1);
        governor.queue(targets, values, calldatas, descriptionHash);
    }

    function _sum(CoinDAOFactory.AllocationAmounts memory allocation) internal pure returns (uint256) {
        return allocation.coinStakingRewards + allocation.immediateTreasuryAllocation + allocation.treasuryVested
            + allocation.monolithVesting + allocation.deployerVesting;
    }
}
