// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {VestingWallet} from "@openzeppelin/contracts/finance/VestingWallet.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";

import {CoinDAOFactory} from "../src/CoinDAOFactory.sol";
import {CoinDAOGovernor} from "../src/CoinDAOGovernor.sol";
import {GovToken} from "../src/GovToken.sol";
import {RevenueRouter} from "../src/RevenueRouter.sol";
import {StakedGovToken} from "../src/StakedGovToken.sol";
import {StakingRewards} from "../src/StakingRewards.sol";
import {IMonolithFactory} from "../src/interfaces/IMonolith.sol";
import {MockMonolithFactory, MockMonolithLender} from "./mocks/MockMonolith.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Proof-of-concept tests for the Nemesis audit of the
/// `feat/add-deployed-coins-path` branch.
contract NemesisPoCTest is Test {
    CoinDAOFactory internal factory;
    MockMonolithFactory internal monolithFactory;

    address internal existingOperator = address(0x1004);
    address internal existingManager = address(0x1005);
    address internal monolithRecipient = address(0x1003);

    function setUp() public {
        monolithFactory = new MockMonolithFactory();
        factory = new CoinDAOFactory(IMonolithFactory(address(monolithFactory)));
    }

    // ------------------------------------------------------------------
    // NM-006: the lender `operator` role is irreversibly burned into the
    // RevenueRouter, which exposes no way to ever nominate a successor.
    // ------------------------------------------------------------------
    function testLenderOperatorRoleIsPermanentlyLockedInRevenueRouter() public {
        CoinDAOFactory.Deployment memory d = _attachToExistingMarket();
        MockMonolithLender lender = MockMonolithLender(d.lender);

        // The handoff completed: the router is now the operator.
        assertEq(lender.operator(), d.revenueRouter);
        assertEq(lender.pendingOperator(), address(0));

        address successorRouter = address(0xC0FFEE);

        // 1. The timelock owns the RevenueRouter, but it is not the lender
        //    operator, so it cannot nominate a successor directly.
        vm.prank(d.timelock);
        vm.expectRevert(MockMonolithLender.Unauthorized.selector);
        lender.setPendingOperator(successorRouter);

        // 2. The market's original operator has been permanently displaced.
        vm.prank(existingOperator);
        vm.expectRevert(MockMonolithLender.Unauthorized.selector);
        lender.setPendingOperator(existingOperator);

        // 3. The RevenueRouter itself is the only account that *could* call
        //    setPendingOperator, and it has no function that does so. Its
        //    entire owner-callable surface is enumerated here; none of it
        //    moves the operator role.
        vm.startPrank(d.timelock);
        RevenueRouter(d.revenueRouter).setGovStakingBps(0);
        RevenueRouter(d.revenueRouter).setManager(address(0xBEEF));
        vm.stopPrank();

        // acceptLenderOperator() is the router's only other lender-facing call,
        // and it can only ever accept a nomination the router cannot create.
        vm.prank(d.timelock);
        vm.expectRevert(MockMonolithLender.Unauthorized.selector);
        RevenueRouter(d.revenueRouter).acceptLenderOperator();

        assertEq(lender.operator(), d.revenueRouter, "operator role is frozen forever");

        // 4. Even renouncing router ownership does not release the role; it
        //    only destroys the remaining governance controls over it.
        vm.prank(d.timelock);
        RevenueRouter(d.revenueRouter).renounceOwnership();
        assertEq(lender.operator(), d.revenueRouter);
    }

    // ------------------------------------------------------------------
    // NM-007: at launch the DAO has zero voting supply, so no proposal can
    // be created and governance is inert for weeks.
    // ------------------------------------------------------------------
    function testGovernanceIsInertAtLaunchBecauseNoLiquidGovExists() public {
        CoinDAOFactory.Deployment memory d = _attachToExistingMarket();
        CoinDAOGovernor governor = CoinDAOGovernor(payable(d.governor));
        StakedGovToken staker = StakedGovToken(d.staker);
        GovToken govToken = GovToken(d.govToken);

        // Zero sGOV exists, so total voting power across the whole system is 0.
        assertEq(staker.totalSupply(), 0);

        // Every GOV token sits in a contract: the funder, the timelock, or a
        // vesting wallet that has released nothing yet.
        assertEq(govToken.balanceOf(monolithRecipient), 0);
        assertEq(VestingWallet(payable(d.monolithVesting)).releasable(address(govToken)), 0);

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _setBpsProposal(d.revenueRouter, 5_000);

        vm.roll(block.number + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IGovernor.GovernorInsufficientProposerVotes.selector,
                monolithRecipient,
                0,
                factory.GOVERNOR_PROPOSAL_THRESHOLD()
            )
        );
        vm.prank(monolithRecipient);
        governor.propose(targets, values, calldatas, "reduce staking share");
    }

    /// @notice Measures how long the launch-window governance blackout lasts
    /// when the monolith vesting wallet is the only source of liquid GOV.
    function testTimeUntilFirstProposalIsPossible() public {
        CoinDAOFactory.Deployment memory d = _attachToExistingMarket();
        CoinDAOGovernor governor = CoinDAOGovernor(payable(d.governor));
        StakedGovToken staker = StakedGovToken(d.staker);
        GovToken govToken = GovToken(d.govToken);
        VestingWallet vesting = VestingWallet(payable(d.monolithVesting));

        uint256 threshold = factory.GOVERNOR_PROPOSAL_THRESHOLD();
        uint256 quorumNeeded = governor.quorum(block.number);
        emit log_named_uint("proposal threshold (GOV)", threshold / 1e18);
        emit log_named_uint("quorum (GOV)", quorumNeeded / 1e18);

        // 72 days in: still short of the proposal threshold.
        vm.warp(block.timestamp + 72 days);
        vesting.release(address(govToken));
        assertLt(govToken.balanceOf(monolithRecipient), threshold);
        emit log_named_uint("day 72 monolith GOV", govToken.balanceOf(monolithRecipient) / 1e18);

        // 74 days in: the threshold is finally reachable.
        vm.warp(block.timestamp + 2 days);
        vesting.release(address(govToken));
        uint256 balance = govToken.balanceOf(monolithRecipient);
        assertGe(balance, threshold);
        emit log_named_uint("day 74 monolith GOV", balance / 1e18);

        // Stake + self-delegate to convert GOV into voting power.
        vm.startPrank(monolithRecipient);
        govToken.approve(address(staker), balance);
        staker.depositFor(monolithRecipient, balance);
        staker.delegate(monolithRecipient);
        vm.stopPrank();

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _setBpsProposal(d.revenueRouter, 5_000);

        vm.roll(block.number + 1);
        vm.prank(monolithRecipient);
        uint256 proposalId = governor.propose(targets, values, calldatas, "reduce staking share");
        assertGt(proposalId, 0);

        // ...but quorum still cannot be met: total voting supply is far below it.
        emit log_named_uint("total sGOV voting supply (GOV)", staker.totalSupply() / 1e18);
        assertLt(staker.totalSupply(), quorumNeeded);
    }

    /// @notice The realistic bootstrap path on an existing market: a Coin whale
    /// stakes at T0 and farms the GOV emissions, then converts them to votes.
    /// This is the *fastest possible* route out of the governance blackout.
    function testFastestPossibleRouteToQuorumWithAnActiveCoinStaker() public {
        CoinDAOFactory.Deployment memory d = _attachToExistingMarket();
        CoinDAOGovernor governor = CoinDAOGovernor(payable(d.governor));
        StakedGovToken staker = StakedGovToken(d.staker);
        GovToken govToken = GovToken(d.govToken);
        StakingRewards rewards = StakingRewards(d.coinStakingRewards);

        uint256 quorumNeeded = governor.quorum(block.number);

        // An existing Coin holder stakes the whole time, capturing 100% of
        // tranche 0 emissions. Nobody can do better than this.
        address whale = makeAddr("whale");
        MockERC20(d.coin).mint(whale, 1_000_000 ether);
        vm.startPrank(whale);
        IERC20(d.coin).approve(address(rewards), type(uint256).max);
        rewards.stake(1_000_000 ether);
        vm.stopPrank();

        // NOTE: warp to absolute timestamps. `vm.warp(block.timestamp + delta)`
        // inside a loop does not compound, because `block.timestamp` folds to
        // its value on entry to the test frame.
        uint256 start = block.timestamp;
        uint256 elapsed;
        while (elapsed < 400 days) {
            elapsed += 1 days;
            vm.warp(start + elapsed);
            if (rewards.earned(whale) >= quorumNeeded) break;
        }

        emit log_named_uint("days until a sole max staker can reach quorum", elapsed / 1 days);
        emit log_named_uint("GOV farmed by then", rewards.earned(whale) / 1e18);
        assertGe(rewards.earned(whale), quorumNeeded);

        // Convert farmed GOV into voting power.
        vm.startPrank(whale);
        rewards.getReward();
        uint256 farmed = govToken.balanceOf(whale);
        govToken.approve(address(staker), farmed);
        staker.depositFor(whale, farmed);
        staker.delegate(whale);
        vm.stopPrank();

        vm.roll(block.number + 1);
        assertGe(governor.getVotes(whale, block.number - 1), quorumNeeded);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------
    function _attachToExistingMarket() internal returns (CoinDAOFactory.Deployment memory) {
        IMonolithFactory.DeployParams memory monolithParams = _monolithParams();
        monolithParams.operator = existingOperator;
        monolithParams.manager = existingManager;
        (address lenderAddress,,) = monolithFactory.deploy(monolithParams);

        vm.prank(existingOperator);
        MockMonolithLender(lenderAddress).setPendingOperator(address(factory));

        CoinDAOFactory.GovLaunchParams memory govParams;
        govParams.govTokenName = "Existing GOV";
        govParams.govTokenSymbol = "eGOV";
        govParams.deployerStakeBps = 0;
        govParams.deployerRecipient = address(0);
        govParams.monolithRecipient = monolithRecipient;
        govParams.stakingTokenChoice = CoinDAOFactory.StakingTokenChoice.Coin;

        vm.prank(existingOperator);
        return factory.deployForExistingCoin(govParams, lenderAddress);
    }

    function _setBpsProposal(address router, uint16 bps)
        internal
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas)
    {
        targets = new address[](1);
        targets[0] = router;
        values = new uint256[](1);
        calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(RevenueRouter.setGovStakingBps, (bps));
    }

    function _monolithParams() internal pure returns (IMonolithFactory.DeployParams memory params) {
        params = IMonolithFactory.DeployParams({
            name: "Example Coin",
            symbol: "xUSD",
            collateral: address(0x2001),
            psmAsset: address(0x2002),
            psmVault: address(0x2003),
            feed: address(0x2004),
            collateralFactor: 8_000,
            minDebt: 1 ether,
            timeUntilImmutability: 30 days,
            operator: address(0),
            manager: address(0),
            halfLife: 7 days,
            targetFreeDebtRatioStartBps: 0,
            targetFreeDebtRatioEndBps: 0,
            redeemFeeBps: 0,
            stalenessThreshold: 0,
            maxBorrowDeltaBps: 0,
            psmVaultMinTotalSupply: 0
        });
    }
}
