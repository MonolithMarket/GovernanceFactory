pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {StakingRewards} from "../src/StakingRewards.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract StakingRewardsTest is Test {
    MockERC20 internal stakingToken;
    MockERC20 internal rewardsToken;
    StakingRewards internal rewards;

    address internal alice = address(0xA11CE);

    function setUp() public {
        vm.warp(1);
        stakingToken = new MockERC20("Stake", "STK");
        rewardsToken = new MockERC20("Reward", "RWD");
        rewards = new StakingRewards(address(stakingToken), address(rewardsToken), address(this), 100 days);
    }

    function testLinearRewardsAndEmptyPeriodBehavior() public {
        rewardsToken.mint(address(rewards), 100 ether);
        rewards.notifyRewardAmount(100 ether);

        vm.warp(10 days + 1);
        stakingToken.mint(alice, 1 ether);
        vm.startPrank(alice);
        stakingToken.approve(address(rewards), 1 ether);
        rewards.stake(1 ether);
        vm.stopPrank();

        vm.warp(20 days + 1);
        assertApproxEqAbs(rewards.earned(alice), 10 ether, 100_000);

        vm.prank(alice);
        rewards.getReward();
        assertApproxEqAbs(rewardsToken.balanceOf(alice), 10 ether, 100_000);
    }

    function testMidPeriodNotificationRollsLeftoverForward() public {
        rewardsToken.mint(address(rewards), 200 ether);
        rewards.notifyRewardAmount(100 ether);

        stakingToken.mint(alice, 1 ether);
        vm.startPrank(alice);
        stakingToken.approve(address(rewards), 1 ether);
        rewards.stake(1 ether);
        vm.stopPrank();

        vm.warp(50 days + 1);
        rewards.notifyRewardAmount(100 ether);

        vm.warp(100 days + 1);
        assertApproxEqAbs(rewards.earned(alice), 125 ether, 1e12);
    }

    function testOnlyRewardsDistributionCanNotify() public {
        rewardsToken.mint(address(rewards), 100 ether);

        vm.expectRevert(bytes("Caller is not RewardsDistribution contract"));
        vm.prank(alice);
        rewards.notifyRewardAmount(100 ether);

        rewards.setRewardsDistribution(alice);
        assertEq(rewards.rewardsDistribution(), alice);

        vm.prank(alice);
        rewards.notifyRewardAmount(100 ether);
        assertEq(rewards.periodFinish(), block.timestamp + rewards.rewardsDuration());
    }

    function testStakeWithdrawClaimAndExit() public {
        rewardsToken.mint(address(rewards), 100 ether);
        rewards.notifyRewardAmount(100 ether);

        stakingToken.mint(alice, 2 ether);
        vm.startPrank(alice);
        stakingToken.approve(address(rewards), 2 ether);
        rewards.stake(2 ether);

        vm.warp(25 days + 1);
        rewards.withdraw(1 ether);
        assertEq(rewards.balanceOf(alice), 1 ether);

        vm.warp(50 days + 1);
        rewards.getReward();
        assertApproxEqAbs(rewardsToken.balanceOf(alice), 50 ether, 1e12);

        rewards.exit();
        assertEq(rewards.balanceOf(alice), 0);
        assertEq(stakingToken.balanceOf(alice), 2 ether);
        vm.stopPrank();
    }
}
