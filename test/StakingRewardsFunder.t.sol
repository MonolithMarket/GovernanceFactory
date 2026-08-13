pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {StakingRewards} from "../src/StakingRewards.sol";
import {StakingRewardsFunder} from "../src/StakingRewardsFunder.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {CloneTestUtils} from "./helpers/CloneTestUtils.sol";

contract StakingRewardsFunderTest is Test, CloneTestUtils {
    MockERC20 internal stakingToken;
    MockERC20 internal rewardsToken;
    StakingRewards internal rewards;
    StakingRewardsFunder internal funder;

    address internal alice = address(0xA11CE);

    function setUp() public {
        vm.warp(1);
        stakingToken = new MockERC20("Stake", "STK");
        rewardsToken = new MockERC20("Reward", "RWD");
        rewards = _newStakingRewards(address(stakingToken), address(rewardsToken), address(this), 365 days);
        funder = _newStakingRewardsFunder(rewards, 100 ether);
    }

    function testTrancheMathAndFinalDustAssignment() public {
        StakingRewardsFunder dustFunder = _newStakingRewardsFunder(rewards, 101);

        assertEq(dustFunder.TRANCHE_COUNT(), 4);
        assertEq(dustFunder.trancheBps(0), 3_250);
        assertEq(dustFunder.trancheBps(1), 2_750);
        assertEq(dustFunder.trancheBps(2), 2_250);
        assertEq(dustFunder.trancheBps(3), 1_750);
        assertEq(dustFunder.trancheAmounts(0), 32);
        assertEq(dustFunder.trancheAmounts(1), 27);
        assertEq(dustFunder.trancheAmounts(2), 22);

        rewardsToken.mint(address(dustFunder), 101);
        rewards.setRewardsDistribution(address(dustFunder));
        for (uint256 i; i < 3; ++i) {
            dustFunder.fundNextTranche();
            vm.warp(rewards.periodFinish());
        }

        assertEq(dustFunder.trancheAmounts(3), 20);
        dustFunder.fundNextTranche();
        assertEq(rewardsToken.balanceOf(address(rewards)), 101);
        assertEq(rewardsToken.balanceOf(address(dustFunder)), 0);
    }

    function testFundNextTrancheStartsRewardPeriod() public {
        rewardsToken.mint(address(funder), 100 ether);
        rewards.setRewardsDistribution(address(funder));

        funder.fundNextTranche();

        assertEq(funder.nextTranche(), 1);
        assertEq(rewardsToken.balanceOf(address(rewards)), 32.5 ether);
        assertEq(rewardsToken.balanceOf(address(funder)), 67.5 ether);
        assertEq(rewards.periodFinish(), block.timestamp + 365 days);
    }

    function testCannotFundBeforePreviousTrancheFinished() public {
        rewardsToken.mint(address(funder), 100 ether);
        rewards.setRewardsDistribution(address(funder));
        funder.fundNextTranche();

        uint256 periodFinish = rewards.periodFinish();
        vm.expectRevert(abi.encodeWithSelector(StakingRewardsFunder.PreviousTrancheActive.selector, periodFinish));
        funder.fundNextTranche();
    }

    function testCanFundAtPeriodFinishPermissionlessly() public {
        rewardsToken.mint(address(funder), 100 ether);
        rewards.setRewardsDistribution(address(funder));
        funder.fundNextTranche();

        vm.warp(rewards.periodFinish());
        vm.prank(alice);
        funder.fundNextTranche();

        assertEq(funder.nextTranche(), 2);
        assertEq(rewardsToken.balanceOf(address(rewards)), 60 ether);
        assertEq(rewardsToken.balanceOf(address(funder)), 40 ether);
        assertEq(rewards.periodFinish(), block.timestamp + 365 days);
    }

    function testCannotFundAfterAllTranchesFunded() public {
        rewardsToken.mint(address(funder), 100 ether);
        rewards.setRewardsDistribution(address(funder));

        for (uint256 i; i < 4; ++i) {
            funder.fundNextTranche();
            vm.warp(rewards.periodFinish());
        }

        assertEq(funder.nextTranche(), 4);
        assertEq(rewardsToken.balanceOf(address(funder)), 0);

        vm.expectRevert(StakingRewardsFunder.AllTranchesFunded.selector);
        funder.fundNextTranche();
    }

    function testRevertsIfNotRewardsDistribution() public {
        rewardsToken.mint(address(funder), 100 ether);

        vm.expectRevert(abi.encodeWithSelector(StakingRewardsFunder.NotRewardsDistribution.selector, address(this)));
        funder.fundNextTranche();
    }

    function testRevertsIfInsufficientBalance() public {
        rewards.setRewardsDistribution(address(funder));

        vm.expectRevert(abi.encodeWithSelector(StakingRewardsFunder.InsufficientBalance.selector, 0, 32.5 ether));
        funder.fundNextTranche();
    }
}
