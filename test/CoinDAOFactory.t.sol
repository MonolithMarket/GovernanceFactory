// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {CoinDAOFactory} from "../src/CoinDAOFactory.sol";
import {IMonolithFactory} from "../src/interfaces/IMonolith.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockMonolithFactory, MockMonolithLender} from "./mocks/MockMonolith.sol";

contract CoinDAOFactoryTest is Test {
    address internal team = address(0x710);
    address internal monolith = address(0x2024);
    address internal guardian = address(0x911);
    address internal eventTriggerOperator = address(0xE7);

    CoinDAOFactory internal factory;
    MockMonolithFactory internal monolithFactory;
    MockERC20 internal collateral;

    function setUp() public {
        factory = new CoinDAOFactory();
        monolithFactory = new MockMonolithFactory();
        collateral = new MockERC20("Collateral", "COL");
    }

    function testAllocationTemplatesSumToOneHundredPercent() public view {
        for (uint256 i; i < 3; ++i) {
            CoinDAOFactory.AllocationBps memory allocation = factory.allocationFor(CoinDAOFactory.AllocationTemplate(i));
            uint256 total = allocation.coinStakingRewards + allocation.timelockTreasuryVested
                + allocation.timelockImmediate + allocation.teamVesting + allocation.monolithVesting;

            assertEq(total, factory.BPS());
            assertLe(allocation.teamVesting, 2_000);
        }
    }

    function testDeployStandardLaunchWiresAllocationsAndControls() public {
        uint256 supply = 1_000_000 ether;

        CoinDAOFactory.Deployment memory deployment = factory.deploy(
            CoinDAOFactory.LaunchParams({
                govTokenName: "Monolith Gov",
                govTokenSymbol: "MGOV",
                stGovTokenName: "Staked Monolith Gov",
                stGovTokenSymbol: "stMGOV",
                governorName: "Monolith Governor",
                monolithFactory: IMonolithFactory(address(monolithFactory)),
                monolithParams: _monolithParams(),
                govTokenSupply: supply,
                allocationTemplate: CoinDAOFactory.AllocationTemplate.StandardLaunch,
                teamRecipient: team,
                monolithRecipient: monolith,
                guardian: guardian,
                proposalThreshold: 1 ether,
                vestingStart: uint64(block.timestamp),
                stGovRewardDuration: 7 days,
                coinStakingRewardDuration: 365 days
            })
        );

        assertEq(deployment.govToken.totalSupply(), supply);
        assertEq(monolithFactory.deploymentsLength(), 1);
        assertEq(deployment.monolithFactory, address(monolithFactory));
        assertEq(address(deployment.coin), MockMonolithLender(deployment.lender).coin());
        assertEq(deployment.vault, MockMonolithLender(deployment.lender).vault());
        assertEq(deployment.govToken.balanceOf(address(deployment.coinStakingRewards)), (supply * 5_300) / 10_000);
        assertEq(deployment.govToken.balanceOf(address(deployment.timelockVesting)), (supply * 2_500) / 10_000);
        assertEq(deployment.govToken.balanceOf(address(deployment.timelock)), (supply * 500) / 10_000);
        assertEq(deployment.govToken.balanceOf(address(deployment.teamVesting)), (supply * 1_500) / 10_000);
        assertEq(deployment.govToken.balanceOf(address(deployment.monolithVesting)), (supply * 200) / 10_000);

        assertEq(deployment.stGovToken.owner(), address(deployment.timelock));
        assertEq(deployment.coinStakingRewards.owner(), address(deployment.timelock));
        assertEq(MockMonolithLender(deployment.lender).operator(), address(deployment.revenueRouter));
        assertEq(MockMonolithLender(deployment.lender).manager(), address(deployment.timelock));
        assertEq(deployment.revenueRouter.lender(), deployment.lender);
        assertEq(deployment.revenueRouter.treasury(), address(deployment.timelock));
        assertEq(address(deployment.revenueRouter.coin()), address(deployment.coin));
        assertEq(deployment.governor.proposalGuardian(), guardian);
        assertEq(deployment.governor.guardianExpiresAt(), block.timestamp + factory.DEFAULT_GUARDIAN_DURATION());

        assertTrue(deployment.timelock.hasRole(deployment.timelock.PROPOSER_ROLE(), address(deployment.governor)));
        assertTrue(deployment.timelock.hasRole(deployment.timelock.CANCELLER_ROLE(), address(deployment.governor)));
        assertTrue(deployment.timelock.hasRole(deployment.timelock.EXECUTOR_ROLE(), address(0)));
        assertFalse(deployment.timelock.hasRole(deployment.timelock.DEFAULT_ADMIN_ROLE(), address(factory)));
        assertGt(deployment.coinStakingRewards.rewardRate(), 0);
    }

    function _monolithParams() internal view returns (IMonolithFactory.DeployParams memory) {
        return IMonolithFactory.DeployParams({
            name: "Monolith Coin",
            symbol: "COIN",
            collateral: address(collateral),
            psmAsset: address(0),
            psmVault: address(0),
            feed: address(0xFEE),
            collateralFactor: 8_000,
            minDebt: 1_000 ether,
            timeUntilImmutability: 30 days,
            operator: address(0xBAD),
            manager: address(0xBAD),
            eventTriggerOperator: eventTriggerOperator,
            halfLife: 1 days,
            targetPsmDebtRatioStartBps: 500,
            targetPsmDebtRatioEndBps: 9_000,
            stalenessThreshold: 1 days,
            maxBorrowDeltaBps: 100,
            psmVaultMinTotalSupply: 0
        });
    }
}
