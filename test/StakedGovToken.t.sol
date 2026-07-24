// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {GovToken} from "../src/GovToken.sol";
import {StakedGovToken} from "../src/StakedGovToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract StakedGovTokenTest is Test {
    GovToken internal gov;
    MockERC20 internal reward;
    StakedGovToken internal staker;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public {
        gov = new GovToken("Governance", "GOV", address(this));
        reward = new MockERC20("Coin", "COIN");
        staker = new StakedGovToken(
            IERC20(address(gov)), IERC20(address(reward)), "Staked Governance", "sGOV", address(this), 30 days
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

    function testRewardsQueueUntilFirstStake() public {
        reward.mint(address(staker), 30 ether);
        staker.notifyRewardAmount(30 ether);

        assertEq(staker.queuedRewards(), 30 ether);
        assertEq(staker.periodFinish(), 0);

        _stakeAlice(100 ether);

        assertEq(staker.queuedRewards(), 0);
        assertEq(staker.periodFinish(), block.timestamp + 30 days);

        vm.warp(block.timestamp + 30 days);
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
        assertEq(staker.periodFinish(), block.timestamp + 30 days);
    }

    function testFinalWithdrawQueuesUndistributedRewards() public {
        _stakeAlice(100 ether);
        reward.mint(address(staker), 30 ether);
        staker.notifyRewardAmount(30 ether);

        vm.warp(block.timestamp + 10 days);

        vm.prank(alice);
        staker.withdrawTo(alice, 100 ether);

        assertEq(staker.totalSupply(), 0);
        assertEq(staker.rewardRate(), 0);
        assertEq(staker.periodFinish(), block.timestamp);
        assertApproxEqAbs(staker.earned(alice), 10 ether, 1e12);
        assertApproxEqAbs(staker.queuedRewards(), 20 ether, 1e12);

        vm.prank(alice);
        staker.getReward();
        assertApproxEqAbs(reward.balanceOf(alice), 10 ether, 1e12);
    }

    function _stakeAlice(uint256 amount) internal {
        vm.startPrank(alice);
        gov.approve(address(staker), amount);
        staker.depositFor(alice, amount);
        staker.delegate(alice);
        vm.stopPrank();
    }
}
