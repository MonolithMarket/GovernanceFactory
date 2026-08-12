pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {GovToken} from "../src/GovToken.sol";
import {StakedGovToken} from "../src/StakedGovToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract StakedGovTokenTest is Test {
    event RewardsDistributionFinalized(
        address indexed initialRewardsDistribution, address indexed finalRewardsDistribution
    );

    uint256 internal constant REWARDS_DURATION = 7 days;

    GovToken internal gov;
    MockERC20 internal reward;
    StakedGovToken internal staker;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public {
        gov = new GovToken("Governance", "GOV", address(this));
        reward = new MockERC20("Coin", "COIN");
        staker = new StakedGovToken(
            IERC20(address(gov)), IERC20(address(reward)), "Staked Governance", "sGOV", address(this), REWARDS_DURATION
        );

        gov.transfer(alice, 1_000 ether);
    }

    function testDepositDelegatesVotesAndWithdrawsUnderlying() public {
        vm.startPrank(alice);
        gov.approve(address(staker), 100 ether);
        staker.depositFor(alice, 100 ether);
        staker.delegate(alice);
        vm.stopPrank();

        vm.roll(block.number + 1);
        assertEq(staker.getVotes(alice), 100 ether);
        assertEq(gov.balanceOf(address(staker)), 100 ether);

        vm.prank(alice);
        staker.withdrawTo(alice, 40 ether);

        vm.roll(block.number + 1);
        assertEq(staker.getVotes(alice), 60 ether);
        assertEq(gov.balanceOf(alice), 940 ether);
    }

    function testReceiptTokenIsNonTransferable() public {
        _stakeAlice(100 ether);

        vm.prank(alice);
        vm.expectRevert(StakedGovToken.NonTransferable.selector);
        staker.transfer(bob, 1 ether);
    }

    function testWithdrawFullyToSender() public {
        _stakeAlice(100 ether);

        vm.prank(alice);
        staker.withdraw();

        assertEq(staker.balanceOf(alice), 0);
        assertEq(staker.totalSupply(), 0);
        assertEq(gov.balanceOf(alice), 1_000 ether);
        assertEq(gov.balanceOf(address(staker)), 0);
    }

    function testOnlyRewardsDistributionCanNotifyRewards() public {
        reward.mint(address(staker), 30 ether);

        vm.prank(alice);
        vm.expectRevert(bytes("Caller is not RewardsDistribution contract"));
        staker.notifyRewardAmount(30 ether);
    }

    function testRewardsDistributionCanBeFinalizedOnce() public {
        vm.expectEmit(true, true, false, true, address(staker));
        emit RewardsDistributionFinalized(address(this), bob);
        staker.finalizeRewardsDistribution(bob);

        assertEq(staker.rewardsDistribution(), bob);

        reward.mint(address(staker), 30 ether);
        vm.expectRevert(bytes("Caller is not RewardsDistribution contract"));
        staker.notifyRewardAmount(30 ether);

        vm.prank(bob);
        staker.notifyRewardAmount(30 ether);
        assertEq(staker.queuedRewards(), 30 ether);

        vm.expectRevert(StakedGovToken.RewardsDistributionAlreadyFinalized.selector);
        vm.prank(bob);
        staker.finalizeRewardsDistribution(alice);
    }

    function testOnlyCurrentRewardsDistributionCanFinalize() public {
        vm.expectRevert(bytes("Caller is not RewardsDistribution contract"));
        vm.prank(alice);
        staker.finalizeRewardsDistribution(bob);
    }

    function testFinalRewardsDistributionMustBeNewAndNonzero() public {
        vm.expectRevert(StakedGovToken.ZeroAddress.selector);
        staker.finalizeRewardsDistribution(address(0));

        address currentRewardsDistribution = staker.rewardsDistribution();
        vm.expectRevert(
            abi.encodeWithSelector(StakedGovToken.InvalidRewardsDistribution.selector, currentRewardsDistribution)
        );
        staker.finalizeRewardsDistribution(currentRewardsDistribution);
    }

    function testRewardsQueueUntilFirstStake() public {
        reward.mint(address(staker), 30 ether);
        staker.notifyRewardAmount(30 ether);

        assertEq(staker.queuedRewards(), 30 ether);
        assertEq(staker.periodFinish(), 0);

        _stakeAlice(100 ether);

        assertEq(staker.queuedRewards(), 0);
        assertEq(staker.periodFinish(), block.timestamp + REWARDS_DURATION);

        vm.warp(block.timestamp + REWARDS_DURATION);
        vm.prank(alice);
        staker.getReward();

        assertApproxEqAbs(reward.balanceOf(alice), 30 ether, 1e12);
    }

    function testUnderfundedQueuedRewardsDoNotBlockStaking() public {
        staker.notifyRewardAmount(30 ether);

        _stakeAlice(100 ether);

        assertEq(staker.balanceOf(alice), 100 ether);
        assertEq(gov.balanceOf(address(staker)), 100 ether);
        assertEq(staker.queuedRewards(), 30 ether);
        assertEq(staker.rewardRate(), 0);
        assertEq(staker.periodFinish(), 0);

        reward.mint(address(staker), 30 ether);
        staker.notifyRewardAmount(0);

        assertEq(staker.queuedRewards(), 0);
        assertEq(staker.periodFinish(), block.timestamp + REWARDS_DURATION);
    }

    function testMidPeriodRewardsQueueWithoutChangingActivePeriod() public {
        _stakeAlice(100 ether);
        reward.mint(address(staker), 21 ether);
        staker.notifyRewardAmount(14 ether);

        uint256 finish = staker.periodFinish();
        uint256 rate = staker.rewardRate();

        vm.warp(block.timestamp + 2 days);
        staker.notifyRewardAmount(7 ether);

        assertEq(staker.periodFinish(), finish);
        assertEq(staker.rewardRate(), rate);
        assertEq(staker.queuedRewards(), 7 ether);
        assertApproxEqAbs(staker.earned(alice), 4 ether, 1e12);
    }

    function testPermissionlessStartQueuedRewardsAfterIdleDelay() public {
        _stakeAlice(100 ether);
        reward.mint(address(staker), 21 ether);
        staker.notifyRewardAmount(7 ether);
        staker.notifyRewardAmount(14 ether);

        vm.warp(staker.periodFinish() + 2 days);
        vm.prank(bob);
        staker.startQueuedRewards();

        assertEq(staker.queuedRewards(), 0);
        assertEq(staker.rewardRate(), 14 ether / REWARDS_DURATION);
        assertEq(staker.periodFinish(), block.timestamp + REWARDS_DURATION);
    }

    function testStartQueuedRewardsNoOpsWhenIneligible() public {
        staker.startQueuedRewards();
        assertEq(staker.periodFinish(), 0);

        reward.mint(address(staker), 14 ether);
        staker.notifyRewardAmount(7 ether);
        staker.startQueuedRewards();
        assertEq(staker.queuedRewards(), 7 ether);
        assertEq(staker.periodFinish(), 0);

        _stakeAlice(100 ether);
        staker.notifyRewardAmount(7 ether);

        uint256 finish = staker.periodFinish();
        uint256 rate = staker.rewardRate();
        uint256 lastUpdateTime = staker.lastUpdateTime();
        vm.warp(block.timestamp + 1 days);
        staker.startQueuedRewards();

        assertEq(staker.queuedRewards(), 7 ether);
        assertEq(staker.periodFinish(), finish);
        assertEq(staker.rewardRate(), rate);
        assertEq(staker.lastUpdateTime(), lastUpdateTime);
    }

    function testClaimStartsEligibleQueuedPeriod() public {
        _stakeAlice(100 ether);
        reward.mint(address(staker), 21 ether);
        staker.notifyRewardAmount(7 ether);
        staker.notifyRewardAmount(14 ether);

        vm.warp(staker.periodFinish());
        vm.prank(alice);
        staker.getReward();

        assertApproxEqAbs(reward.balanceOf(alice), 7 ether, 1e12);
        assertEq(staker.queuedRewards(), 0);
        assertEq(staker.periodFinish(), block.timestamp + REWARDS_DURATION);
    }

    function testPartialWithdrawalStartsEligibleQueuedPeriod() public {
        _stakeAlice(100 ether);
        reward.mint(address(staker), 21 ether);
        staker.notifyRewardAmount(7 ether);
        staker.notifyRewardAmount(14 ether);

        vm.warp(staker.periodFinish());
        vm.prank(alice);
        staker.withdrawTo(alice, 40 ether);

        assertEq(staker.balanceOf(alice), 60 ether);
        assertEq(staker.queuedRewards(), 0);
        assertEq(staker.periodFinish(), block.timestamp + REWARDS_DURATION);
    }

    function testLaterNotificationStartsQueuedPeriod() public {
        _stakeAlice(100 ether);
        reward.mint(address(staker), 28 ether);
        staker.notifyRewardAmount(7 ether);
        staker.notifyRewardAmount(14 ether);

        vm.warp(staker.periodFinish());
        staker.notifyRewardAmount(7 ether);

        assertEq(staker.queuedRewards(), 0);
        assertEq(staker.rewardRate(), 21 ether / REWARDS_DURATION);
        assertEq(staker.periodFinish(), block.timestamp + REWARDS_DURATION);
    }

    function testFinalWithdrawQueuesUndistributedRewards() public {
        _stakeAlice(100 ether);
        reward.mint(address(staker), 28 ether);
        staker.notifyRewardAmount(28 ether);

        vm.warp(block.timestamp + 1 days);

        vm.prank(alice);
        staker.withdrawTo(alice, 100 ether);

        assertEq(staker.totalSupply(), 0);
        assertEq(staker.rewardRate(), 0);
        assertEq(staker.periodFinish(), block.timestamp);
        assertApproxEqAbs(staker.earned(alice), 4 ether, 1e12);
        assertApproxEqAbs(staker.queuedRewards(), 24 ether, 1e12);

        vm.prank(alice);
        staker.getReward();
        assertApproxEqAbs(reward.balanceOf(alice), 4 ether, 1e12);
    }

    function _stakeAlice(uint256 amount) internal {
        vm.startPrank(alice);
        gov.approve(address(staker), amount);
        staker.depositFor(alice, amount);
        staker.delegate(alice);
        vm.stopPrank();
    }
}
