pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {GovToken} from "../src/GovToken.sol";
import {StakedGovToken} from "../src/StakedGovToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {CloneTestUtils} from "./helpers/CloneTestUtils.sol";

contract StakedGovTokenTest is Test, CloneTestUtils {
    event RewardAdded(uint256 reward);
    event RewardPaid(address indexed account, uint256 reward);

    error DistributionFailed();

    GovToken internal gov;
    MockERC20 internal reward;
    StakedGovToken internal staker;

    uint256 internal pendingReward;
    uint256 internal treasuryRewards;
    uint256 internal distributionCalls;
    bool internal distributionShouldRevert;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public {
        gov = _newGovToken("Governance", "GOV", address(this));
        reward = new MockERC20("Coin", "COIN");
        staker = _newStakedGovToken(
            IERC20(address(gov)), IERC20(address(reward)), "Staked Governance", "sGOV", address(this)
        );

        assertTrue(gov.transfer(alice, 1_000 ether));
        assertTrue(gov.transfer(bob, 1_000 ether));
    }

    function testDepositDelegatesVotesAndWithdrawsUnderlying() public {
        _stake(alice, 100 ether);

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
        _stake(alice, 100 ether);

        vm.prank(alice);
        vm.expectRevert(StakedGovToken.NonTransferable.selector);
        staker.transfer(bob, 1 ether);
    }

    function testWithdrawFullyToSender() public {
        _stake(alice, 100 ether);

        vm.prank(alice);
        staker.withdraw();

        assertEq(staker.balanceOf(alice), 0);
        assertEq(staker.totalSupply(), 0);
        assertEq(gov.balanceOf(alice), 1_000 ether);
        assertEq(gov.balanceOf(address(staker)), 0);
    }

    function testOnlyRevenueRouterCanNotifyRewards() public {
        _stake(alice, 100 ether);
        reward.mint(address(staker), 30 ether);

        vm.prank(alice);
        vm.expectRevert(bytes("Caller is not RevenueRouter contract"));
        staker.notifyRewardAmount(30 ether);
    }

    function testNotificationRejectsZeroStakedSupply() public {
        reward.mint(address(staker), 30 ether);

        vm.expectRevert(StakedGovToken.NoStakedSupply.selector);
        staker.notifyRewardAmount(30 ether);
    }

    function testRewardAccruesImmediatelyToSoleStaker() public {
        _stake(alice, 100 ether);
        reward.mint(address(staker), 30 ether);

        vm.expectEmit(false, false, false, true, address(staker));
        emit RewardAdded(30 ether);
        staker.notifyRewardAmount(30 ether);

        assertEq(staker.rewardPerToken(), 0.3 ether);
        assertEq(staker.earned(alice), 30 ether);

        vm.expectEmit(true, false, false, true, address(staker));
        emit RewardPaid(alice, 30 ether);
        vm.prank(alice);
        staker.getReward();

        assertEq(reward.balanceOf(alice), 30 ether);
        assertEq(staker.earned(alice), 0);
    }

    function testRewardAccruesProRataToCurrentStakers() public {
        _stake(alice, 100 ether);
        _stake(bob, 300 ether);

        _notifyReward(40 ether);

        assertEq(staker.earned(alice), 10 ether);
        assertEq(staker.earned(bob), 30 ether);
    }

    function testNewStakeDoesNotEarnPastRewards() public {
        _stake(alice, 100 ether);
        _notifyReward(10 ether);

        _stake(bob, 100 ether);
        _notifyReward(20 ether);

        assertEq(staker.earned(alice), 20 ether);
        assertEq(staker.earned(bob), 10 ether);
    }

    function testStakeImmediatelyBeforeNotificationSharesReward() public {
        _stake(alice, 100 ether);
        _stake(bob, 100 ether);

        _notifyReward(20 ether);

        assertEq(staker.earned(alice), 10 ether);
        assertEq(staker.earned(bob), 10 ether);
    }

    function testWithdrawnHolderRetainsAccruedReward() public {
        _stake(alice, 100 ether);
        _notifyReward(30 ether);

        vm.prank(alice);
        staker.withdraw();

        assertEq(staker.totalSupply(), 0);
        assertEq(staker.earned(alice), 30 ether);

        vm.prank(alice);
        staker.getReward();
        assertEq(reward.balanceOf(alice), 30 ether);
    }

    function testBalanceChangesApplyOnlyToLaterDistributions() public {
        _stake(alice, 100 ether);
        _stake(bob, 100 ether);
        _notifyReward(20 ether);

        vm.prank(bob);
        staker.withdrawTo(bob, 50 ether);
        _notifyReward(15 ether);

        assertEq(staker.earned(alice), 20 ether);
        assertEq(staker.earned(bob), 15 ether);
    }

    function testDepositDistributesPendingRewardBeforeMinting() public {
        _stake(alice, 100 ether);
        _queueReward(30 ether);

        _stake(bob, 100 ether);

        assertEq(staker.earned(alice), 30 ether);
        assertEq(staker.earned(bob), 0);
        assertEq(reward.balanceOf(address(staker)), 30 ether);
    }

    function testTopUpDoesNotApplyPendingRewardToNewStake() public {
        _stake(alice, 100 ether);
        _stake(bob, 100 ether);
        _queueReward(20 ether);

        _stake(alice, 100 ether);

        assertEq(staker.balanceOf(alice), 200 ether);
        assertEq(staker.earned(alice), 10 ether);
        assertEq(staker.earned(bob), 10 ether);
    }

    function testWithdrawDistributesPendingRewardBeforeBurning() public {
        _stake(alice, 100 ether);
        _stake(bob, 100 ether);
        _queueReward(20 ether);

        vm.prank(alice);
        staker.withdraw();

        assertEq(staker.balanceOf(alice), 0);
        assertEq(staker.earned(alice), 10 ether);
        assertEq(staker.earned(bob), 10 ether);
    }

    function testGetRewardDistributesAndPaysPendingReward() public {
        _stake(alice, 100 ether);
        _queueReward(30 ether);

        vm.prank(alice);
        staker.getReward();

        assertEq(reward.balanceOf(alice), 30 ether);
        assertEq(staker.earned(alice), 0);
    }

    function testRewardUpdatesSucceedWithNothingToDistribute() public {
        _stake(alice, 100 ether);
        uint256 callsBefore = distributionCalls;

        _stake(bob, 100 ether);
        vm.prank(bob);
        staker.withdrawTo(bob, 10 ether);
        vm.prank(bob);
        staker.getReward();

        assertEq(distributionCalls, callsBefore + 3);
    }

    function testDistributionFailureRevertsEveryRewardUpdate() public {
        _stake(alice, 100 ether);
        distributionShouldRevert = true;

        vm.startPrank(bob);
        gov.approve(address(staker), 100 ether);
        vm.expectRevert(DistributionFailed.selector);
        staker.depositFor(bob, 100 ether);
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert(DistributionFailed.selector);
        staker.withdrawTo(alice, 10 ether);

        vm.prank(alice);
        vm.expectRevert(DistributionFailed.selector);
        staker.getReward();
    }

    function testFirstDepositRoutesPendingRewardAwayFromStaking() public {
        _queueReward(30 ether);

        _stake(alice, 100 ether);

        assertEq(treasuryRewards, 30 ether);
        assertEq(staker.earned(alice), 0);
        assertEq(reward.balanceOf(address(staker)), 0);
    }

    function distribute() external returns (uint256 treasuryAmount, uint256 govStakingAmount) {
        if (distributionShouldRevert) revert DistributionFailed();
        distributionCalls++;

        uint256 amount = pendingReward;
        pendingReward = 0;
        if (amount == 0) return (0, 0);

        if (staker.totalSupply() == 0) {
            treasuryRewards += amount;
            return (amount, 0);
        }

        reward.mint(address(staker), amount);
        staker.notifyRewardAmount(amount);
        return (0, amount);
    }

    function _notifyReward(uint256 amount) internal {
        reward.mint(address(staker), amount);
        staker.notifyRewardAmount(amount);
    }

    function _queueReward(uint256 amount) internal {
        pendingReward += amount;
    }

    function _stake(address account, uint256 amount) internal {
        vm.startPrank(account);
        gov.approve(address(staker), amount);
        staker.depositFor(account, amount);
        staker.delegate(account);
        vm.stopPrank();
    }
}
