// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {VestingWallet} from "@openzeppelin/contracts/finance/VestingWallet.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {CoinDAOFactory} from "../src/CoinDAOFactory.sol";
import {CoinDAOGovernor} from "../src/CoinDAOGovernor.sol";
import {GovToken} from "../src/GovToken.sol";
import {RevenueRouter} from "../src/RevenueRouter.sol";
import {UniStaker} from "../src/UniStaker.sol";
import {StakingRewards} from "../src/StakingRewards.sol";
import {IMonolithFactory} from "../src/interfaces/IMonolith.sol";
import {MockMonolithFactory, MockMonolithLender} from "./mocks/MockMonolith.sol";

contract CoinDAOFactoryTest is Test {
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
        assertEq(deployment.monolithFactory, address(monolithFactory));
        assertEq(deployment.stakingToken, deployment.coin);
        assertEq(CoinDAOGovernor(payable(deployment.governor)).name(), "Example GOV Governor");
        assertEq(MockMonolithLender(deployment.lender).operator(), deployment.revenueRouter);
        assertEq(MockMonolithLender(deployment.lender).manager(), manager);

        GovToken govToken = GovToken(deployment.govToken);
        assertEq(govToken.totalSupply(), factory.GOV_TOKEN_SUPPLY());
        assertEq(govToken.balanceOf(deployment.coinStakingRewards), allocation.coinStakingRewards);
        assertEq(govToken.balanceOf(deployment.timelock), allocation.immediateTreasuryAllocation);
        assertEq(govToken.balanceOf(deployment.treasuryVesting), allocation.treasuryVested);
        assertEq(govToken.balanceOf(deployment.monolithVesting), allocation.monolithVesting);
        assertEq(govToken.balanceOf(deployment.deployerVesting), allocation.deployerVesting);

        assertEq(Ownable(deployment.coinStakingRewards).owner(), deployment.timelock);
        assertEq(StakingRewards(deployment.coinStakingRewards).rewardsDistribution(), deployment.timelock);
        assertEq(
            StakingRewards(deployment.coinStakingRewards).rewardsDuration(), factory.COIN_STAKING_REWARD_DURATION()
        );
        assertEq(UniStaker(deployment.staker).admin(), deployment.timelock);
        assertEq(Ownable(deployment.revenueRouter).owner(), deployment.timelock);
        assertEq(VestingWallet(payable(deployment.treasuryVesting)).owner(), deployment.timelock);
        assertEq(VestingWallet(payable(deployment.monolithVesting)).owner(), monolithRecipient);
        assertEq(VestingWallet(payable(deployment.deployerVesting)).owner(), deployerRecipient);
        assertTrue(UniStaker(deployment.staker).isRewardNotifier(deployment.revenueRouter));
        assertEq(RevenueRouter(deployment.revenueRouter).govStakingBps(), 10_000);
        assertFalse(TimelockController(payable(deployment.timelock)).hasRole(bytes32(0), address(factory)));
    }

    function testDeployWiresSCoinStakingLaunch() public {
        CoinDAOFactory.Deployment memory deployment =
            factory.deploy(_params(0, CoinDAOFactory.StakingTokenChoice.SCoin));

        assertEq(deployment.stakingToken, deployment.vault);
        assertEq(deployment.deployerVesting, address(0));
    }

    function testRouterDistributesRevenueToStakerByDefault() public {
        CoinDAOFactory.Deployment memory deployment = factory.deploy(_params(0, CoinDAOFactory.StakingTokenChoice.Coin));
        MockMonolithLender lender = MockMonolithLender(deployment.lender);
        address newManager = address(0xBEEF);

        vm.prank(deployment.timelock);
        RevenueRouter(deployment.revenueRouter).setManager(newManager);
        assertEq(lender.manager(), newManager);

        deal(deployment.coin, deployment.revenueRouter, 100 ether, true);
        RevenueRouter(deployment.revenueRouter).distribute();
        assertEq(IERC20(deployment.coin).balanceOf(deployment.staker), 100 ether);
        assertEq(IERC20(deployment.coin).balanceOf(deployment.timelock), 0);
    }

    function testStakerEarnsCoinRevenueAndPreservesVotes() public {
        CoinDAOFactory.Deployment memory deployment = factory.deploy(_params(0, CoinDAOFactory.StakingTokenChoice.Coin));
        address alice = address(0xA11CE);
        deal(deployment.govToken, alice, 100 ether, true);

        vm.startPrank(alice);
        IERC20(deployment.govToken).approve(deployment.staker, 100 ether);
        UniStaker(deployment.staker).stake(uint96(100 ether), alice);
        vm.stopPrank();

        // Voting power of staked GOV is preserved via the delegation surrogate.
        vm.roll(block.number + 1);
        assertEq(GovToken(deployment.govToken).getVotes(alice), 100 ether);

        // Revenue routed to the staker streams to the sole staker over the reward duration.
        deal(deployment.coin, deployment.revenueRouter, 30 ether, true);
        RevenueRouter(deployment.revenueRouter).distribute();

        vm.warp(block.timestamp + 30 days);
        vm.prank(alice);
        UniStaker(deployment.staker).claimReward();
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

    function _sum(CoinDAOFactory.AllocationAmounts memory allocation) internal pure returns (uint256) {
        return allocation.coinStakingRewards + allocation.immediateTreasuryAllocation + allocation.treasuryVested
            + allocation.monolithVesting + allocation.deployerVesting;
    }
}
