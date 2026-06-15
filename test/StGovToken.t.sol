// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

import {GovToken} from "../src/GovToken.sol";
import {StGovToken} from "../src/StGovToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract StGovTokenTest is Test {
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal notifier = address(0xA71CE);

    GovToken internal govToken;
    StGovToken internal stGovToken;
    MockERC20 internal rewardToken;

    function setUp() public {
        govToken = new GovToken("Monolith Gov", "MGOV", address(this), 1_000_000 ether);
        stGovToken = new StGovToken(IERC20(address(govToken)), "Staked Monolith Gov", "stMGOV", address(this));
        rewardToken = new MockERC20("Reward", "RWD");
    }

    function testStakeDelegateUnstakeAndDisableTransfers() public {
        assertTrue(govToken.transfer(alice, 100 ether));

        vm.startPrank(alice);
        govToken.approve(address(stGovToken), 100 ether);
        stGovToken.stake(100 ether);

        assertEq(stGovToken.balanceOf(alice), 100 ether);
        assertEq(govToken.balanceOf(alice), 0);
        assertEq(stGovToken.getVotes(alice), 0);

        stGovToken.delegate(alice);
        assertEq(stGovToken.getVotes(alice), 100 ether);

        vm.expectRevert(StGovToken.NonTransferable.selector);
        stGovToken.transfer(bob, 1 ether);

        stGovToken.unstake(40 ether);
        assertEq(stGovToken.balanceOf(alice), 60 ether);
        assertEq(govToken.balanceOf(alice), 40 ether);
        assertEq(stGovToken.getVotes(alice), 60 ether);
        vm.stopPrank();
    }

    function testRewardsAccrueAndClaimForCurrentStakers() public {
        stGovToken.addRewardToken(address(rewardToken), 100);
        stGovToken.setRewardNotifier(address(rewardToken), notifier, true);

        assertTrue(govToken.transfer(alice, 100 ether));
        vm.startPrank(alice);
        govToken.approve(address(stGovToken), 100 ether);
        stGovToken.stake(100 ether);
        vm.stopPrank();

        rewardToken.mint(notifier, 100 ether);
        vm.startPrank(notifier);
        rewardToken.approve(address(stGovToken), 100 ether);
        stGovToken.notifyRewardAmount(address(rewardToken), 100 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 50);
        assertApproxEqAbs(stGovToken.earned(alice, address(rewardToken)), 50 ether, 1);

        vm.prank(alice);
        uint256 claimed = stGovToken.claimReward(address(rewardToken), alice);
        assertApproxEqAbs(claimed, 50 ether, 1);
        assertApproxEqAbs(rewardToken.balanceOf(alice), 50 ether, 1);
    }

    function testUnderlyingGovTokenRewardsCannotConsumeBacking() public {
        stGovToken.addRewardToken(address(govToken), 100);
        stGovToken.setRewardNotifier(address(govToken), notifier, true);

        assertTrue(govToken.transfer(alice, 100 ether));
        assertTrue(govToken.transfer(notifier, 100 ether));

        vm.startPrank(alice);
        govToken.approve(address(stGovToken), 100 ether);
        stGovToken.stake(100 ether);
        vm.stopPrank();

        vm.startPrank(notifier);
        govToken.approve(address(stGovToken), 100 ether);
        stGovToken.notifyRewardAmount(address(govToken), 100 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 100);
        vm.prank(alice);
        stGovToken.claimReward(address(govToken), alice);

        assertEq(stGovToken.totalSupply(), 100 ether);
        assertEq(govToken.balanceOf(address(stGovToken)), stGovToken.totalSupply());
        assertEq(govToken.balanceOf(alice), 100 ether);
    }
}
