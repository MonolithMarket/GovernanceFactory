// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

import {GovToken} from "../src/GovToken.sol";
import {IStGovTokenRewards, RevenueRouter} from "../src/RevenueRouter.sol";
import {StGovToken} from "../src/StGovToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract RevenueRouterTest is Test {
    address internal treasury = address(0x7);

    MockERC20 internal coin;
    GovToken internal govToken;
    StGovToken internal stGovToken;
    RevenueRouter internal router;

    function setUp() public {
        coin = new MockERC20("Coin", "COIN");
        govToken = new GovToken("Gov", "GOV", address(this), 1_000 ether);
        stGovToken = new StGovToken(IERC20(address(govToken)), "Staked Gov", "stGOV", address(this));
        router = new RevenueRouter(
            address(0x1), IERC20(address(coin)), treasury, IStGovTokenRewards(address(stGovToken)), 5_000
        );

        stGovToken.addRewardToken(address(coin), 100);
        stGovToken.setRewardNotifier(address(coin), address(router), true);
    }

    function testDistributeSplitsCoinBetweenTreasuryAndStGovToken() public {
        coin.mint(address(router), 100 ether);

        (uint256 treasuryAmount, uint256 stGovAmount) = router.distribute();

        assertEq(treasuryAmount, 50 ether);
        assertEq(stGovAmount, 50 ether);
        assertEq(coin.balanceOf(treasury), 50 ether);
        assertEq(coin.balanceOf(address(stGovToken)), 50 ether);

        (,, uint256 rewardRate,,) = stGovToken.rewardData(address(coin));
        assertEq(rewardRate, 0.5 ether);
    }

    function testDistributeHandlesZeroAndFullRevenueShare() public {
        vm.prank(treasury);
        router.setRevShareBps(0);
        coin.mint(address(router), 100 ether);
        router.distribute();

        assertEq(coin.balanceOf(treasury), 100 ether);
        assertEq(coin.balanceOf(address(stGovToken)), 0);

        vm.prank(treasury);
        router.setRevShareBps(10_000);
        coin.mint(address(router), 100 ether);
        router.distribute();

        assertEq(coin.balanceOf(treasury), 100 ether);
        assertEq(coin.balanceOf(address(stGovToken)), 100 ether);
    }

    function testOnlyTreasuryCanSetRevenueShare() public {
        vm.expectRevert(RevenueRouter.Unauthorized.selector);
        router.setRevShareBps(1);

        vm.prank(treasury);
        vm.expectRevert(abi.encodeWithSelector(RevenueRouter.InvalidRevShareBps.selector, uint16(10_001)));
        router.setRevShareBps(10_001);

        vm.prank(treasury);
        router.setRevShareBps(7_500);
        assertEq(router.revShareBps(), 7_500);
    }
}
