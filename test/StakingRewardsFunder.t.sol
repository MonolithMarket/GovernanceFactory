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

    function testPermissionlessFourTrancheLifecycleAssignsFinalDust() public {
        StakingRewardsFunder dustFunder = _newStakingRewardsFunder(rewards, 101);
        rewardsToken.mint(address(dustFunder), 101);
        rewards.setRewardsDistribution(address(dustFunder));
        assertEq(dustFunder.TRANCHE_COUNT(), 4);
        assertEq(dustFunder.trancheBps(0), 3_250);
        assertEq(dustFunder.trancheBps(1), 2_750);
        assertEq(dustFunder.trancheBps(2), 2_250);
        assertEq(dustFunder.trancheBps(3), 1_750);
        assertEq(dustFunder.trancheAmounts(0), 32);
        assertEq(dustFunder.trancheAmounts(1), 27);
        assertEq(dustFunder.trancheAmounts(2), 22);

        for (uint256 i; i < 4; ++i) {
            vm.prank(alice);
            dustFunder.fundNextTranche();
            assertEq(dustFunder.nextTranche(), i + 1);
            assertEq(rewards.periodFinish(), (i + 1) * 365 days + 1);
            if (i < 3) vm.warp(rewards.periodFinish());
        }
        assertEq(rewardsToken.balanceOf(address(rewards)), 101);
        assertEq(rewardsToken.balanceOf(address(dustFunder)), 0);
        vm.expectRevert(StakingRewardsFunder.AllTranchesFunded.selector);
        dustFunder.fundNextTranche();
    }

    function testCannotFundBeforePreviousTrancheFinishes() public {
        rewardsToken.mint(address(funder), 100 ether);
        rewards.setRewardsDistribution(address(funder));
        funder.fundNextTranche();
        uint256 periodFinish = rewards.periodFinish();
        vm.expectRevert(abi.encodeWithSelector(StakingRewardsFunder.PreviousTrancheActive.selector, periodFinish));
        funder.fundNextTranche();
    }

    function testCannotFundWhenFunderIsNotRewardsDistribution() public {
        rewardsToken.mint(address(funder), 100 ether);
        vm.expectRevert(abi.encodeWithSelector(StakingRewardsFunder.NotRewardsDistribution.selector, address(this)));
        funder.fundNextTranche();
    }

    function testCannotFundWithInsufficientBalance() public {
        rewards.setRewardsDistribution(address(funder));
        vm.expectRevert(abi.encodeWithSelector(StakingRewardsFunder.InsufficientBalance.selector, 0, 32.5 ether));
        funder.fundNextTranche();
    }
}
