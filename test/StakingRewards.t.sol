// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {StakingRewards} from "../src/StakingRewards.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract StakingRewardsTest is Test {
    uint256 internal constant TOTAL_REWARDS = 100 ether;
    uint256 internal constant REWARDS_DURATION = 100 days;

    MockERC20 internal stakingToken;
    MockERC20 internal rewardsToken;
    StakingRewards internal rewards;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public {
        vm.warp(1);
        stakingToken = new MockERC20("Stake", "STK");
        rewardsToken = new MockERC20("Reward", "RWD");
        rewards = new StakingRewards(address(stakingToken), address(rewardsToken), TOTAL_REWARDS, REWARDS_DURATION);
        rewardsToken.mint(address(rewards), TOTAL_REWARDS);
    }

    function testConstructorRejectsZeroRewards() public {
        vm.expectRevert(StakingRewards.ZeroRewards.selector);
        new StakingRewards(address(stakingToken), address(rewardsToken), 0, REWARDS_DURATION);
    }

    function testTrancheMathAndFinalDustAssignment() public {
        StakingRewards dustRewards =
            new StakingRewards(address(stakingToken), address(rewardsToken), 101, REWARDS_DURATION);

        assertEq(dustRewards.TRANCHE_COUNT(), 4);
        assertEq(dustRewards.trancheBps(0), 3_250);
        assertEq(dustRewards.trancheBps(1), 2_750);
        assertEq(dustRewards.trancheBps(2), 2_250);
        assertEq(dustRewards.trancheBps(3), 1_750);
        assertEq(dustRewards.trancheAmount(0), 32);
        assertEq(dustRewards.trancheAmount(1), 27);
        assertEq(dustRewards.trancheAmount(2), 22);
        assertEq(dustRewards.trancheAmount(3), 20);
        assertEq(
            dustRewards.trancheAmount(0) + dustRewards.trancheAmount(1) + dustRewards.trancheAmount(2)
                + dustRewards.trancheAmount(3),
            101
        );
    }

    function testInvalidTrancheReverts() public {
        vm.expectRevert(abi.encodeWithSelector(StakingRewards.InvalidTranche.selector, 4));
        rewards.trancheBps(4);

        vm.expectRevert(abi.encodeWithSelector(StakingRewards.InvalidTranche.selector, 4));
        rewards.trancheAmount(4);
    }

    function testFirstStakeStartsFirstTrancheWithoutPreStakeEmissions() public {
        vm.warp(10 days);
        assertEq(rewards.nextTranche(), 0);
        assertEq(rewards.periodFinish(), 0);

        _stakeAlice(1 ether);

        uint256 firstTranche = rewards.trancheAmount(0);
        assertEq(rewards.nextTranche(), 1);
        assertEq(rewards.rewardRate(), firstTranche / REWARDS_DURATION);
        assertEq(rewards.periodFinish(), block.timestamp + REWARDS_DURATION);
        assertEq(rewards.earned(alice), 0);

        vm.warp(block.timestamp + 10 days);
        assertApproxEqAbs(rewards.earned(alice), firstTranche / 10, 1e12);
    }

    function testFirstStakeRevertsIfFullReserveIsNotFunded() public {
        StakingRewards underfunded =
            new StakingRewards(address(stakingToken), address(rewardsToken), TOTAL_REWARDS, REWARDS_DURATION);
        rewardsToken.mint(address(underfunded), TOTAL_REWARDS - 1);
        stakingToken.mint(alice, 1 ether);

        vm.startPrank(alice);
        stakingToken.approve(address(underfunded), 1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(StakingRewards.InsufficientBalance.selector, TOTAL_REWARDS - 1, TOTAL_REWARDS)
        );
        underfunded.stake(1 ether);
        vm.stopPrank();

        assertEq(underfunded.totalSupply(), 0);
        assertEq(underfunded.balanceOf(alice), 0);
        assertEq(stakingToken.balanceOf(alice), 1 ether);
    }

    function testCannotStartTrancheWithoutStakers() public {
        vm.expectRevert(StakingRewards.NoStakers.selector);
        rewards.startNextTranche();
    }

    function testCannotStartBeforePreviousTrancheFinished() public {
        _stakeAlice(1 ether);

        uint256 periodFinish = rewards.periodFinish();
        vm.expectRevert(abi.encodeWithSelector(StakingRewards.PreviousTrancheActive.selector, periodFinish));
        rewards.startNextTranche();
    }

    function testCanStartNextTranchePermissionlesslyAtPeriodFinish() public {
        _stakeAlice(1 ether);
        uint256 secondTranche = rewards.trancheAmount(1);

        vm.warp(rewards.periodFinish());
        vm.prank(bob);
        rewards.startNextTranche();

        assertEq(rewards.nextTranche(), 2);
        assertEq(rewards.rewardRate(), secondTranche / REWARDS_DURATION);
        assertEq(rewards.periodFinish(), block.timestamp + REWARDS_DURATION);
    }

    function testCannotStartAfterAllTranchesStarted() public {
        _stakeAlice(1 ether);

        for (uint256 i = 1; i < rewards.TRANCHE_COUNT(); ++i) {
            vm.warp(rewards.periodFinish());
            rewards.startNextTranche();
        }

        assertEq(rewards.nextTranche(), rewards.TRANCHE_COUNT());
        vm.warp(rewards.periodFinish());
        vm.expectRevert(StakingRewards.AllTranchesStarted.selector);
        rewards.startNextTranche();
    }

    function testFinalTrancheDoesNotSweepUnclaimedRewardsOrDonations() public {
        _stakeAlice(1 ether);

        vm.warp(rewards.periodFinish());
        rewards.startNextTranche();
        vm.warp(rewards.periodFinish());
        rewards.startNextTranche();

        rewardsToken.mint(address(rewards), 10 ether);
        uint256 finalTranche = rewards.trancheAmount(3);

        vm.warp(rewards.periodFinish());
        rewards.startNextTranche();

        assertEq(finalTranche, 17.5 ether);
        assertEq(rewards.rewardRate(), finalTranche / REWARDS_DURATION);
        assertEq(rewardsToken.balanceOf(address(rewards)), TOTAL_REWARDS + 10 ether);
        assertApproxEqAbs(rewards.earned(alice), TOTAL_REWARDS - finalTranche, 1e12);
    }

    function testStakeWithdrawClaimAndExit() public {
        _stakeAlice(2 ether);

        vm.warp(25 days + 1);
        vm.prank(alice);
        rewards.withdraw(1 ether);
        assertEq(rewards.balanceOf(alice), 1 ether);

        vm.warp(50 days + 1);
        vm.prank(alice);
        rewards.getReward();
        assertApproxEqAbs(rewardsToken.balanceOf(alice), rewards.trancheAmount(0) / 2, 1e12);

        vm.prank(alice);
        rewards.exit();
        assertEq(rewards.balanceOf(alice), 0);
        assertEq(stakingToken.balanceOf(alice), 2 ether);
    }

    function _stakeAlice(uint256 amount) internal {
        stakingToken.mint(alice, amount);
        vm.startPrank(alice);
        stakingToken.approve(address(rewards), amount);
        rewards.stake(amount);
        vm.stopPrank();
    }
}
