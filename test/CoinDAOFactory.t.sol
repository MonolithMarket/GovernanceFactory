pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {VestingWallet} from "@openzeppelin/contracts/finance/VestingWallet.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {
    GovernorVotesQuorumFraction
} from "@openzeppelin/contracts/governance/extensions/GovernorVotesQuorumFraction.sol";

import {CoinDAOFactory} from "../src/CoinDAOFactory.sol";
import {CoinDAOVestingWallet} from "../src/CoinDAOVestingWallet.sol";
import {CoinDAOGovernor} from "../src/CoinDAOGovernor.sol";
import {GovToken} from "../src/GovToken.sol";
import {RevenueRouter} from "../src/RevenueRouter.sol";
import {StakedGovToken} from "../src/StakedGovToken.sol";
import {StakingRewards} from "../src/StakingRewards.sol";
import {StakingRewardsFunder} from "../src/StakingRewardsFunder.sol";
import {IMonolithFactory} from "../src/interfaces/IMonolith.sol";
import {MockMonolithFactory, MockMonolithLender} from "./mocks/MockMonolith.sol";

contract CoinDAOFactoryTest is Test {
    event QuorumNumeratorUpdated(uint256 oldQuorumNumerator, uint256 newQuorumNumerator);
    event MonolithBeneficiaryTransferStarted(address indexed currentBeneficiary, address indexed pendingBeneficiary);
    event MonolithBeneficiaryTransferred(address indexed previousBeneficiary, address indexed newBeneficiary);

    CoinDAOFactory internal factory;
    MockMonolithFactory internal monolithFactory;
    CoinDAOFactory.Implementations internal implementationSet;

    address internal manager = address(0x1001);
    address internal deployerRecipient = address(0x1002);
    address internal monolithRecipient = address(0x1003);
    address internal existingOperator = address(0x1004);
    address internal existingManager = address(0x1005);
    uint256 internal saltNonce;

    function setUp() public {
        monolithFactory = new MockMonolithFactory();
        implementationSet = _newImplementations();
        factory = new CoinDAOFactory(IMonolithFactory(address(monolithFactory)), monolithRecipient, implementationSet);
    }

    function testConstructorRejectsZeroMonolithFactory() public {
        vm.expectRevert(CoinDAOFactory.ZeroAddress.selector);
        new CoinDAOFactory(IMonolithFactory(address(0)), monolithRecipient, implementationSet);
    }

    function testConstructorRejectsZeroMonolithBeneficiary() public {
        vm.expectRevert(CoinDAOFactory.ZeroAddress.selector);
        new CoinDAOFactory(IMonolithFactory(address(monolithFactory)), address(0), implementationSet);
    }

    function testConstructorRejectsImplementationWithoutCode() public {
        CoinDAOFactory.Implementations memory invalid = implementationSet;
        invalid.govToken = address(0xBAD);

        vm.expectRevert(
            abi.encodeWithSelector(
                CoinDAOFactory.InvalidImplementation.selector, factory.GOV_TOKEN_IMPLEMENTATION_ID(), address(0xBAD)
            )
        );
        new CoinDAOFactory(IMonolithFactory(address(monolithFactory)), monolithRecipient, invalid);
    }

    function testConstructorRejectsIncorrectImplementationType() public {
        CoinDAOFactory.Implementations memory invalid = implementationSet;
        invalid.govToken = implementationSet.stakedGovToken;

        vm.expectRevert(
            abi.encodeWithSelector(
                CoinDAOFactory.InvalidImplementation.selector,
                factory.GOV_TOKEN_IMPLEMENTATION_ID(),
                implementationSet.stakedGovToken
            )
        );
        new CoinDAOFactory(IMonolithFactory(address(monolithFactory)), monolithRecipient, invalid);
    }

    function testConstructorRejectsDuplicateImplementation() public {
        CoinDAOFactory.Implementations memory invalid = implementationSet;
        invalid.revenueRouter = implementationSet.govToken;

        vm.expectRevert(
            abi.encodeWithSelector(CoinDAOFactory.DuplicateImplementation.selector, implementationSet.govToken)
        );
        new CoinDAOFactory(IMonolithFactory(address(monolithFactory)), monolithRecipient, invalid);
    }

    function testImplementationsAreLocked() public {
        vm.expectRevert();
        GovToken(implementationSet.govToken).initialize("Governance", "GOV", address(this));

        vm.expectRevert();
        StakedGovToken(implementationSet.stakedGovToken)
            .initialize(IERC20(address(1)), IERC20(address(2)), "Staked Governance", "sGOV", address(this), 7 days);

        vm.expectRevert();
        RevenueRouter(implementationSet.revenueRouter)
            .initialize(address(1), address(2), address(3), address(4), 10_000, address(this));

        vm.expectRevert();
        StakingRewards(implementationSet.stakingRewards).initialize(address(1), address(2), address(this), 1 days);

        vm.expectRevert();
        StakingRewardsFunder(implementationSet.stakingRewardsFunder).initialize(StakingRewards(address(1)), 1);

        vm.expectRevert();
        CoinDAOVestingWallet(payable(implementationSet.vestingWallet)).initialize(address(this), 1, 1 days);
    }

    function testPredictsDeterministicAddressesAndDeploysMinimalProxies() public {
        bytes32 userSalt = keccak256("deterministic launch");
        CoinDAOFactory.GovLaunchParams memory govParams = _govParams(1_000, CoinDAOFactory.StakingTokenChoice.Coin);
        CoinDAOFactory.PredictedAddresses memory predicted =
            factory.predictCoinDAOAddresses(address(this), userSalt, govParams);

        CoinDAOFactory.Deployment memory deployment = factory.deploy(userSalt, govParams, _monolithParams(), manager);

        _assertPredictedAddresses(deployment, predicted);
        _assertMinimalProxy(deployment.govToken, implementationSet.govToken);
        _assertMinimalProxy(deployment.staker, implementationSet.stakedGovToken);
        _assertMinimalProxy(deployment.revenueRouter, implementationSet.revenueRouter);
        _assertMinimalProxy(deployment.coinStakingRewards, implementationSet.stakingRewards);
        _assertMinimalProxy(deployment.coinStakingRewardsFunder, implementationSet.stakingRewardsFunder);
        _assertMinimalProxy(deployment.treasuryVesting, implementationSet.vestingWallet);
        _assertMinimalProxy(deployment.monolithVesting, implementationSet.vestingWallet);
        _assertMinimalProxy(deployment.deployerVesting, implementationSet.vestingWallet);

        assertGt(deployment.governor.code.length, 45);
        assertGt(deployment.timelock.code.length, 45);

        bytes32 key = factory.deploymentKey(address(this), userSalt);
        assertTrue(factory.usedDeploymentKeys(key));
        assertEq(factory.deploymentKeyForId(0), key);
    }

    function testSameUserSaltIsNamespacedByCreator() public view {
        bytes32 userSalt = keccak256("shared salt");
        CoinDAOFactory.GovLaunchParams memory govParams = _govParams(0, CoinDAOFactory.StakingTokenChoice.Coin);

        CoinDAOFactory.PredictedAddresses memory first =
            factory.predictCoinDAOAddresses(address(this), userSalt, govParams);
        CoinDAOFactory.PredictedAddresses memory second =
            factory.predictCoinDAOAddresses(address(0xA11CE), userSalt, govParams);

        assertNotEq(first.govToken, second.govToken);
        assertNotEq(first.timelock, second.timelock);
        assertNotEq(first.governor, second.governor);
        assertNotEq(factory.deploymentKey(address(this), userSalt), factory.deploymentKey(address(0xA11CE), userSalt));
    }

    function testRejectsReusedDeploymentKeyBeforeDeployingMonolithMarket() public {
        bytes32 userSalt = keccak256("single use");
        CoinDAOFactory.GovLaunchParams memory govParams = _govParams(0, CoinDAOFactory.StakingTokenChoice.Coin);
        factory.deploy(userSalt, govParams, _monolithParams(), manager);

        bytes32 key = factory.deploymentKey(address(this), userSalt);
        vm.expectRevert(abi.encodeWithSelector(CoinDAOFactory.DeploymentKeyAlreadyUsed.selector, key));
        factory.deploy(userSalt, govParams, _monolithParams(), manager);

        assertEq(monolithFactory.deploymentsLength(), 1);
        assertEq(factory.deploymentsLength(), 1);
    }

    function testCloneLaunchGasRegression() public {
        uint256 gasBefore = gasleft();
        factory.deploy(
            keccak256("gas regression"),
            _govParams(0, CoinDAOFactory.StakingTokenChoice.Coin),
            _monolithParams(),
            manager
        );
        uint256 gasUsed = gasBefore - gasleft();

        emit log_named_uint("Mock-market CoinDAO deployment gas", gasUsed);
        assertLt(gasUsed, 10_000_000);
    }

    function testZeroDeployerAllocationLeavesPredictedVestingAddressEmpty() public {
        bytes32 userSalt = keccak256("no deployer vesting");
        CoinDAOFactory.GovLaunchParams memory govParams = _govParams(0, CoinDAOFactory.StakingTokenChoice.Coin);
        CoinDAOFactory.PredictedAddresses memory predicted =
            factory.predictCoinDAOAddresses(address(this), userSalt, govParams);

        CoinDAOFactory.Deployment memory deployment = factory.deploy(userSalt, govParams, _monolithParams(), manager);

        assertEq(deployment.deployerVesting, address(0));
        assertEq(predicted.deployerVesting.code.length, 0);
    }

    function testInitializedClonesCannotBeInitializedAgain() public {
        CoinDAOFactory.Deployment memory deployment = _deploy(1_000, CoinDAOFactory.StakingTokenChoice.Coin);

        vm.expectRevert();
        GovToken(deployment.govToken).initialize("Other", "OTHER", address(this));

        vm.expectRevert();
        StakedGovToken(deployment.staker)
            .initialize(IERC20(deployment.govToken), IERC20(deployment.coin), "Other", "oGOV", address(this), 1 days);

        vm.expectRevert();
        RevenueRouter(deployment.revenueRouter)
            .initialize(deployment.lender, deployment.coin, deployment.timelock, deployment.staker, 0, address(this));

        vm.expectRevert();
        StakingRewards(deployment.coinStakingRewards)
            .initialize(deployment.coin, deployment.govToken, address(this), 1 days);

        vm.expectRevert();
        StakingRewardsFunder(deployment.coinStakingRewardsFunder)
            .initialize(StakingRewards(deployment.coinStakingRewards), 1);

        vm.expectRevert();
        CoinDAOVestingWallet(payable(deployment.treasuryVesting)).initialize(address(this), 1, 1 days);
    }

    function testMonolithBeneficiaryCanNominateAndReplacePendingBeneficiary() public {
        address firstNominee = address(0xB001);
        address secondNominee = address(0xB002);

        vm.expectEmit(true, true, false, true, address(factory));
        emit MonolithBeneficiaryTransferStarted(monolithRecipient, firstNominee);
        vm.prank(monolithRecipient);
        factory.setPendingMonolithBeneficiary(firstNominee);
        assertEq(factory.pendingMonolithBeneficiary(), firstNominee);

        vm.expectEmit(true, true, false, true, address(factory));
        emit MonolithBeneficiaryTransferStarted(monolithRecipient, secondNominee);
        vm.prank(monolithRecipient);
        factory.setPendingMonolithBeneficiary(secondNominee);
        assertEq(factory.pendingMonolithBeneficiary(), secondNominee);
    }

    function testSetPendingMonolithBeneficiaryRejectsUnauthorizedCallerAndZeroAddress() public {
        address unauthorizedCaller = address(0xBAD);

        vm.expectRevert(
            abi.encodeWithSelector(
                CoinDAOFactory.CallerNotMonolithBeneficiary.selector, unauthorizedCaller, monolithRecipient
            )
        );
        vm.prank(unauthorizedCaller);
        factory.setPendingMonolithBeneficiary(address(0xB001));

        vm.expectRevert(CoinDAOFactory.ZeroAddress.selector);
        vm.prank(monolithRecipient);
        factory.setPendingMonolithBeneficiary(address(0));
    }

    function testOnlyLatestPendingMonolithBeneficiaryCanAccept() public {
        address replacedNominee = address(0xB001);
        address newBeneficiary = address(0xB002);

        vm.startPrank(monolithRecipient);
        factory.setPendingMonolithBeneficiary(replacedNominee);
        factory.setPendingMonolithBeneficiary(newBeneficiary);
        vm.stopPrank();

        vm.expectRevert(
            abi.encodeWithSelector(
                CoinDAOFactory.CallerNotPendingMonolithBeneficiary.selector, replacedNominee, newBeneficiary
            )
        );
        vm.prank(replacedNominee);
        factory.acceptMonolithBeneficiary();

        vm.expectEmit(true, true, false, true, address(factory));
        emit MonolithBeneficiaryTransferred(monolithRecipient, newBeneficiary);
        vm.prank(newBeneficiary);
        factory.acceptMonolithBeneficiary();

        assertEq(factory.monolithBeneficiary(), newBeneficiary);
        assertEq(factory.pendingMonolithBeneficiary(), address(0));

        vm.expectRevert(
            abi.encodeWithSelector(
                CoinDAOFactory.CallerNotMonolithBeneficiary.selector, monolithRecipient, newBeneficiary
            )
        );
        vm.prank(monolithRecipient);
        factory.setPendingMonolithBeneficiary(address(0xB003));
    }

    function testBeneficiaryHandoffOnlyAffectsFutureMonolithVestings() public {
        CoinDAOFactory.Deployment memory first = _deploy(0, CoinDAOFactory.StakingTokenChoice.Coin);
        address newBeneficiary = address(0xB001);

        vm.prank(monolithRecipient);
        factory.setPendingMonolithBeneficiary(newBeneficiary);

        CoinDAOFactory.Deployment memory beforeAcceptance = _deploy(0, CoinDAOFactory.StakingTokenChoice.Coin);
        assertEq(VestingWallet(payable(first.monolithVesting)).owner(), monolithRecipient);
        assertEq(VestingWallet(payable(beforeAcceptance.monolithVesting)).owner(), monolithRecipient);

        vm.prank(newBeneficiary);
        factory.acceptMonolithBeneficiary();
        CoinDAOFactory.Deployment memory afterAcceptance = _deploy(0, CoinDAOFactory.StakingTokenChoice.Coin);

        assertEq(VestingWallet(payable(first.monolithVesting)).owner(), monolithRecipient);
        assertEq(VestingWallet(payable(beforeAcceptance.monolithVesting)).owner(), monolithRecipient);
        assertEq(VestingWallet(payable(afterAcceptance.monolithVesting)).owner(), newBeneficiary);
    }

    function testAllocationForZeroDeployerStake() public view {
        uint256 supply = factory.GOV_TOKEN_SUPPLY();
        CoinDAOFactory.AllocationAmounts memory allocation = factory.allocationFor(0);

        assertEq(allocation.monolithVesting, (supply * 200) / 10_000);
        assertEq(allocation.deployerVesting, 0);
        assertEq(allocation.coinStakingRewards, (supply * 6_500) / 10_000);
        assertEq(allocation.immediateAllocation, (supply * 500) / 10_000);
        assertEq(allocation.treasuryVested, (supply * 2_800) / 10_000);
        assertEq(_sum(allocation), supply);
    }

    function testAllocationForMaxDeployerStake() public view {
        uint256 supply = factory.GOV_TOKEN_SUPPLY();
        CoinDAOFactory.AllocationAmounts memory allocation = factory.allocationFor(2_000);
        uint256 remainingAllocation = supply - allocation.monolithVesting - allocation.deployerVesting;

        assertEq(allocation.monolithVesting, (supply * 200) / 10_000);
        assertEq(allocation.deployerVesting, (supply * 2_000) / 10_000);
        assertEq(allocation.coinStakingRewards, (remainingAllocation * 6_500) / 9_800);
        assertEq(allocation.immediateAllocation, (remainingAllocation * 500) / 9_800);
        assertEq(
            allocation.treasuryVested,
            remainingAllocation - allocation.coinStakingRewards - allocation.immediateAllocation
        );
        assertEq(_sum(allocation), supply);
    }

    function testFuzzAllocationForValidDeployerStake(uint16 deployerStakeBps_) public view {
        uint16 deployerStakeBps = uint16(bound(deployerStakeBps_, 0, factory.MAX_DEPLOYER_STAKE_BPS()));
        uint256 supply = factory.GOV_TOKEN_SUPPLY();
        uint256 expectedMonolithVesting = (supply * 200) / 10_000;
        uint256 expectedDeployerVesting = (supply * deployerStakeBps) / 10_000;
        uint256 remainingAllocation = supply - expectedMonolithVesting - expectedDeployerVesting;
        uint256 expectedCoinStakingRewards = (remainingAllocation * 6_500) / 9_800;
        uint256 expectedImmediateAllocation = (remainingAllocation * 500) / 9_800;

        CoinDAOFactory.AllocationAmounts memory allocation = factory.allocationFor(deployerStakeBps);

        assertEq(factory.ALLOCATION_WEIGHT_TOTAL(), 9_800);
        assertEq(
            factory.COIN_STAKING_REWARDS_WEIGHT() + factory.IMMEDIATE_ALLOCATION_WEIGHT()
                + factory.VESTED_TREASURY_WEIGHT(),
            factory.ALLOCATION_WEIGHT_TOTAL()
        );
        assertEq(allocation.monolithVesting, expectedMonolithVesting);
        assertEq(allocation.deployerVesting, expectedDeployerVesting);
        assertEq(allocation.coinStakingRewards, expectedCoinStakingRewards);
        assertEq(allocation.immediateAllocation, expectedImmediateAllocation);
        assertEq(
            allocation.treasuryVested, remainingAllocation - expectedCoinStakingRewards - expectedImmediateAllocation
        );
        assertEq(_sum(allocation), supply);
    }

    function testAllocationRejectsTooMuchDeployerStake() public {
        vm.expectRevert(abi.encodeWithSelector(CoinDAOFactory.DeployerStakeExceedsMaximum.selector, 2_001));
        factory.allocationFor(2_001);
    }

    function testDeployRejectsVestedStakeWithoutDeployerRecipient() public {
        CoinDAOFactory.GovLaunchParams memory govParams = _govParams(1_000, CoinDAOFactory.StakingTokenChoice.Coin);
        govParams.deployerRecipient = address(0);

        vm.expectRevert(CoinDAOFactory.DeployerRecipientRequired.selector);
        factory.deploy(_nextSalt(), govParams, _monolithParams(), manager);
    }

    function testDeployWiresCoinStakingLaunch() public {
        CoinDAOFactory.Deployment memory deployment = _deploy(1_000, CoinDAOFactory.StakingTokenChoice.Coin);
        CoinDAOFactory.AllocationAmounts memory allocation = factory.allocationFor(1_000);

        _assertDeploymentContractsHaveCode(deployment);

        assertEq(factory.deploymentsLength(), 1);
        assertTrue(factory.hasCoinDAO(deployment.lender));
        assertEq(deployment.stakingToken, deployment.coin);
        assertEq(CoinDAOGovernor(payable(deployment.governor)).name(), "Example GOV Governor");
        assertEq(MockMonolithLender(deployment.lender).operator(), deployment.revenueRouter);
        assertEq(MockMonolithLender(deployment.lender).manager(), manager);

        GovToken govToken = GovToken(deployment.govToken);
        StakingRewardsFunder rewardsFunder = StakingRewardsFunder(deployment.coinStakingRewardsFunder);
        uint256 firstTranche = rewardsFunder.trancheAmounts(0);

        assertEq(govToken.totalSupply(), factory.GOV_TOKEN_SUPPLY());
        assertEq(govToken.balanceOf(deployment.coinStakingRewards), firstTranche);
        assertEq(govToken.balanceOf(deployment.coinStakingRewardsFunder), allocation.coinStakingRewards - firstTranche);
        assertEq(govToken.balanceOf(deployment.timelock), 0);
        assertEq(govToken.balanceOf(deployerRecipient), allocation.immediateAllocation);
        assertEq(govToken.balanceOf(deployment.treasuryVesting), allocation.treasuryVested);
        assertEq(govToken.balanceOf(deployment.monolithVesting), allocation.monolithVesting);
        assertEq(govToken.balanceOf(deployment.deployerVesting), allocation.deployerVesting);

        assertEq(Ownable(deployment.coinStakingRewards).owner(), address(0));
        assertEq(
            StakingRewards(deployment.coinStakingRewards).rewardsDistribution(), deployment.coinStakingRewardsFunder
        );
        assertEq(
            StakingRewards(deployment.coinStakingRewards).rewardsDuration(), factory.COIN_STAKING_REWARD_DURATION()
        );
        assertEq(factory.COIN_STAKING_REWARD_DURATION(), 365 days);
        assertEq(address(rewardsFunder.stakingRewards()), deployment.coinStakingRewards);
        assertEq(address(rewardsFunder.rewardsToken()), deployment.govToken);
        assertEq(rewardsFunder.totalRewards(), allocation.coinStakingRewards);
        assertEq(rewardsFunder.nextTranche(), 1);
        CoinDAOGovernor governor = CoinDAOGovernor(payable(deployment.governor));
        StakedGovToken staker = StakedGovToken(deployment.staker);

        assertEq(address(governor.token()), deployment.staker);
        assertEq(governor.quorumNumerator(), factory.GOVERNOR_QUORUM_NUMERATOR());
        assertEq(governor.quorumDenominator(), 1_000);
        assertEq(staker.rewardsDistribution(), deployment.revenueRouter);
        assertEq(staker.rewardsDuration(), factory.GOV_STAKING_REWARD_DURATION());
        assertEq(factory.GOV_STAKING_REWARD_DURATION(), 7 days);
        assertEq(Ownable(deployment.revenueRouter).owner(), deployment.timelock);
        assertEq(VestingWallet(payable(deployment.treasuryVesting)).owner(), deployment.timelock);
        assertEq(VestingWallet(payable(deployment.monolithVesting)).owner(), monolithRecipient);
        assertEq(factory.monolithBeneficiary(), monolithRecipient);
        assertEq(VestingWallet(payable(deployment.deployerVesting)).owner(), deployerRecipient);
        assertEq(RevenueRouter(deployment.revenueRouter).govStakingBps(), 10_000);
        assertFalse(TimelockController(payable(deployment.timelock)).hasRole(bytes32(0), address(factory)));
    }

    function testDeployWiresSCoinStakingLaunch() public {
        CoinDAOFactory.Deployment memory deployment = _deploy(0, CoinDAOFactory.StakingTokenChoice.SCoin);
        CoinDAOFactory.AllocationAmounts memory allocation = factory.allocationFor(0);
        GovToken govToken = GovToken(deployment.govToken);

        assertEq(deployment.stakingToken, deployment.vault);
        assertEq(deployment.deployerVesting, address(0));
        assertEq(govToken.balanceOf(deployment.timelock), allocation.immediateAllocation);
        assertEq(govToken.balanceOf(deployerRecipient), 0);
    }

    function testDeployIssuesImmediateAllocationWithoutVestedStake() public {
        CoinDAOFactory.GovLaunchParams memory govParams = _govParams(0, CoinDAOFactory.StakingTokenChoice.Coin);
        govParams.deployerRecipient = deployerRecipient;

        CoinDAOFactory.Deployment memory deployment = factory.deploy(_nextSalt(), govParams, _monolithParams(), manager);
        CoinDAOFactory.AllocationAmounts memory allocation = factory.allocationFor(0);
        GovToken govToken = GovToken(deployment.govToken);

        assertEq(deployment.deployerVesting, address(0));
        assertEq(govToken.balanceOf(deployerRecipient), allocation.immediateAllocation);
        assertEq(govToken.balanceOf(deployment.timelock), 0);
    }

    function testDeployForExistingCoinWiresFullCoinDAOAndPreservesManager() public {
        (address lenderAddress, address coin, address vault) = _deployExistingMarket(existingOperator, existingManager);
        MockMonolithLender lender = MockMonolithLender(lenderAddress);
        CoinDAOFactory.GovLaunchParams memory govParams =
            _existingGovParams(1_000, CoinDAOFactory.StakingTokenChoice.Coin);

        vm.prank(existingOperator);
        lender.setPendingOperator(address(factory));

        vm.prank(existingOperator);
        CoinDAOFactory.Deployment memory deployment =
            factory.deployForExistingCoin(_nextSalt(), govParams, lenderAddress);
        CoinDAOFactory.AllocationAmounts memory allocation = factory.allocationFor(govParams.deployerStakeBps);

        _assertDeploymentContractsHaveCode(deployment);
        assertEq(deployment.lender, lenderAddress);
        assertEq(deployment.coin, coin);
        assertEq(deployment.vault, vault);
        assertEq(deployment.stakingToken, coin);

        assertEq(factory.deploymentsLength(), 1);
        assertTrue(factory.hasCoinDAO(lenderAddress));
        assertEq(lender.operator(), deployment.revenueRouter);
        assertEq(lender.pendingOperator(), address(0));
        assertEq(lender.manager(), existingManager);
        assertEq(Ownable(deployment.revenueRouter).owner(), deployment.timelock);
        assertEq(StakedGovToken(deployment.staker).rewardsDistribution(), deployment.revenueRouter);

        GovToken govToken = GovToken(deployment.govToken);
        assertEq(govToken.balanceOf(deployment.timelock), 0);
        assertEq(govToken.balanceOf(deployerRecipient), allocation.immediateAllocation);
        assertEq(govToken.balanceOf(deployment.treasuryVesting), allocation.treasuryVested);
        assertEq(govToken.balanceOf(deployment.monolithVesting), allocation.monolithVesting);
        assertEq(govToken.balanceOf(deployment.deployerVesting), allocation.deployerVesting);

        lender.setAccruedLocalReserves(100 ether);
        RevenueRouter(deployment.revenueRouter).distribute();
        assertEq(IERC20(coin).balanceOf(deployment.staker), 100 ether);
    }

    function testDeployForExistingCoinSupportsSCoinAndZeroDeployerStake() public {
        (address lenderAddress,, address vault) = _deployExistingMarket(existingOperator, existingManager);
        MockMonolithLender lender = MockMonolithLender(lenderAddress);

        vm.prank(existingOperator);
        lender.setPendingOperator(address(factory));
        vm.prank(existingOperator);
        CoinDAOFactory.Deployment memory deployment = factory.deployForExistingCoin(
            _nextSalt(), _existingGovParams(0, CoinDAOFactory.StakingTokenChoice.SCoin), lenderAddress
        );
        CoinDAOFactory.AllocationAmounts memory allocation = factory.allocationFor(0);
        GovToken govToken = GovToken(deployment.govToken);

        assertEq(deployment.stakingToken, vault);
        assertEq(deployment.deployerVesting, address(0));
        assertEq(lender.manager(), existingManager);
        assertEq(govToken.balanceOf(deployment.timelock), allocation.immediateAllocation);
        assertEq(govToken.balanceOf(deployerRecipient), 0);
    }

    function testDeployForExistingCoinIssuesImmediateAllocationWithoutVestedStake() public {
        (address lenderAddress,,) = _deployExistingMarket(existingOperator, existingManager);
        MockMonolithLender lender = MockMonolithLender(lenderAddress);
        CoinDAOFactory.GovLaunchParams memory govParams = _existingGovParams(0, CoinDAOFactory.StakingTokenChoice.Coin);
        govParams.deployerRecipient = deployerRecipient;

        vm.prank(existingOperator);
        lender.setPendingOperator(address(factory));
        vm.prank(existingOperator);
        CoinDAOFactory.Deployment memory deployment =
            factory.deployForExistingCoin(_nextSalt(), govParams, lenderAddress);
        CoinDAOFactory.AllocationAmounts memory allocation = factory.allocationFor(0);
        GovToken govToken = GovToken(deployment.govToken);

        assertEq(deployment.deployerVesting, address(0));
        assertEq(govToken.balanceOf(deployerRecipient), allocation.immediateAllocation);
        assertEq(govToken.balanceOf(deployment.timelock), 0);
    }

    function testDeployForExistingCoinRejectsUnrecognizedLender() public {
        address unrecognizedLender = address(0xBAD);

        vm.expectRevert(abi.encodeWithSelector(CoinDAOFactory.UnrecognizedLender.selector, unrecognizedLender));
        vm.prank(existingOperator);
        factory.deployForExistingCoin(
            _nextSalt(), _existingGovParams(0, CoinDAOFactory.StakingTokenChoice.Coin), unrecognizedLender
        );
    }

    function testDeployForExistingCoinRejectsCallerThatIsNotCurrentOperator() public {
        (address lenderAddress,,) = _deployExistingMarket(existingOperator, existingManager);
        MockMonolithLender lender = MockMonolithLender(lenderAddress);
        address attacker = address(0xA77AC);

        vm.prank(existingOperator);
        lender.setPendingOperator(address(factory));

        vm.expectRevert(
            abi.encodeWithSelector(CoinDAOFactory.CallerNotLenderOperator.selector, attacker, existingOperator)
        );
        vm.prank(attacker);
        factory.deployForExistingCoin(
            _nextSalt(), _existingGovParams(0, CoinDAOFactory.StakingTokenChoice.Coin), lenderAddress
        );

        assertEq(lender.operator(), existingOperator);
        assertEq(lender.pendingOperator(), address(factory));
        assertEq(factory.deploymentsLength(), 0);
    }

    function testDeployForExistingCoinRequiresFactoryNomination() public {
        (address lenderAddress,,) = _deployExistingMarket(existingOperator, existingManager);

        vm.expectRevert(abi.encodeWithSelector(CoinDAOFactory.FactoryNotPendingOperator.selector, address(0)));
        vm.prank(existingOperator);
        factory.deployForExistingCoin(
            _nextSalt(), _existingGovParams(0, CoinDAOFactory.StakingTokenChoice.Coin), lenderAddress
        );
    }

    function testDeployForExistingCoinRejectsDuplicate() public {
        (address lenderAddress,,) = _deployExistingMarket(existingOperator, existingManager);
        MockMonolithLender lender = MockMonolithLender(lenderAddress);
        CoinDAOFactory.GovLaunchParams memory govParams = _existingGovParams(0, CoinDAOFactory.StakingTokenChoice.Coin);

        vm.prank(existingOperator);
        lender.setPendingOperator(address(factory));
        vm.prank(existingOperator);
        factory.deployForExistingCoin(_nextSalt(), govParams, lenderAddress);

        vm.expectRevert(abi.encodeWithSelector(CoinDAOFactory.CoinDAOAlreadyExists.selector, lenderAddress));
        factory.deployForExistingCoin(_nextSalt(), govParams, lenderAddress);
    }

    function testDeployForExistingCoinRollsBackAcceptedOperatorIfRouterHandoffFails() public {
        (address lenderAddress,,) = _deployExistingMarket(existingOperator, existingManager);
        MockMonolithLender lender = MockMonolithLender(lenderAddress);
        bytes32 userSalt = _nextSalt();
        bytes32 key = factory.deploymentKey(existingOperator, userSalt);

        vm.prank(existingOperator);
        lender.setPendingOperator(address(factory));
        lender.setFailOperatorNomination(true);
        uint256 factoryNonce = vm.getNonce(address(factory));

        vm.expectRevert(MockMonolithLender.ForcedFailure.selector);
        vm.prank(existingOperator);
        factory.deployForExistingCoin(
            userSalt, _existingGovParams(0, CoinDAOFactory.StakingTokenChoice.Coin), lenderAddress
        );

        assertEq(lender.operator(), existingOperator);
        assertEq(lender.pendingOperator(), address(factory));
        assertEq(lender.manager(), existingManager);
        assertEq(factory.deploymentsLength(), 0);
        assertFalse(factory.hasCoinDAO(lenderAddress));
        assertFalse(factory.usedDeploymentKeys(key));
        assertEq(vm.getNonce(address(factory)), factoryNonce);
    }

    function testGovernorUpdateQuorumNumeratorRejectsDirectCalls() public {
        CoinDAOFactory.Deployment memory deployment = _deploy(0, CoinDAOFactory.StakingTokenChoice.Coin);
        CoinDAOGovernor governor = CoinDAOGovernor(payable(deployment.governor));

        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorOnlyExecutor.selector, address(this)));
        governor.updateQuorumNumerator(2);
    }

    function testGovernorUpdatesQuorumNumeratorThroughGovernance() public {
        CoinDAOFactory.Deployment memory deployment = _deploy(0, CoinDAOFactory.StakingTokenChoice.Coin);
        CoinDAOGovernor governor = CoinDAOGovernor(payable(deployment.governor));
        StakedGovToken staker = StakedGovToken(deployment.staker);
        uint256 oldNumerator = governor.quorumNumerator();
        uint256 historicalTimepoint = governor.clock();
        uint256 newNumerator = oldNumerator * 2;

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash) =
            _passAndQueueQuorumProposal(deployment, newNumerator, "Raise quorum");

        vm.warp(block.timestamp + factory.DEFAULT_TIMELOCK_DELAY());
        vm.expectEmit(false, false, false, true, address(governor));
        emit QuorumNumeratorUpdated(oldNumerator, newNumerator);
        governor.execute(targets, values, calldatas, descriptionHash);
        vm.roll(governor.clock() + 1);

        uint256 latestTimepoint = governor.clock() - 1;
        assertEq(governor.quorumNumerator(historicalTimepoint), oldNumerator);
        assertEq(governor.quorumNumerator(latestTimepoint), newNumerator);
        assertEq(governor.quorum(latestTimepoint), staker.getPastTotalSupply(latestTimepoint) * newNumerator / 1_000);

        (targets, values, calldatas, descriptionHash) =
            _passAndQueueQuorumProposal(deployment, 1_001, "Reject excessive quorum numerator");
        vm.warp(block.timestamp + factory.DEFAULT_TIMELOCK_DELAY());
        vm.expectRevert(
            abi.encodeWithSelector(GovernorVotesQuorumFraction.GovernorInvalidQuorumFraction.selector, 1_001, 1_000)
        );
        governor.execute(targets, values, calldatas, descriptionHash);
    }

    function testGovernorQuorumChangesDoNotApplyRetroactively() public {
        CoinDAOFactory.Deployment memory deployment = _deploy(0, CoinDAOFactory.StakingTokenChoice.Coin);
        CoinDAOGovernor governor = CoinDAOGovernor(payable(deployment.governor));
        StakedGovToken staker = StakedGovToken(deployment.staker);
        address proposer = address(0xA11CE);
        address lowQuorumVoter = address(0xB0B);
        uint256 newNumerator = 0;

        uint256 proposalThreshold = governor.proposalThreshold();
        deal(deployment.govToken, proposer, proposalThreshold, true);
        vm.startPrank(proposer);
        IERC20(deployment.govToken).approve(deployment.staker, proposalThreshold);
        staker.depositFor(proposer, proposalThreshold);
        staker.delegate(proposer);
        vm.stopPrank();

        uint256 lowQuorumVotes = 10 ether;
        deal(deployment.govToken, lowQuorumVoter, lowQuorumVotes, true);
        vm.startPrank(lowQuorumVoter);
        IERC20(deployment.govToken).approve(deployment.staker, lowQuorumVotes);
        staker.depositFor(lowQuorumVoter, lowQuorumVotes);
        staker.delegate(lowQuorumVoter);
        vm.stopPrank();
        vm.roll(block.number + 1);

        address[] memory defeatedTargets = new address[](1);
        defeatedTargets[0] = address(governor);
        uint256[] memory defeatedValues = new uint256[](1);
        bytes[] memory defeatedCalldatas = new bytes[](1);
        defeatedCalldatas[0] = abi.encodeCall(governor.updateQuorumNumerator, (newNumerator));
        string memory defeatedDescription = "Proposal below the original quorum";

        vm.prank(proposer);
        uint256 defeatedProposalId =
            governor.propose(defeatedTargets, defeatedValues, defeatedCalldatas, defeatedDescription);
        uint256 defeatedSnapshot = governor.proposalSnapshot(defeatedProposalId);

        vm.roll(defeatedSnapshot + 1);
        vm.prank(lowQuorumVoter);
        governor.castVote(defeatedProposalId, 1);
        vm.roll(governor.proposalDeadline(defeatedProposalId) + 1);

        uint256 oldQuorum = governor.quorum(defeatedSnapshot);
        (, uint256 forVotes,) = governor.proposalVotes(defeatedProposalId);
        assertEq(forVotes, lowQuorumVotes);
        assertLt(forVotes, oldQuorum);
        assertEq(uint256(governor.state(defeatedProposalId)), uint256(IGovernor.ProposalState.Defeated));
        assertEq(governor.quorum(defeatedSnapshot), oldQuorum);

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash) =
            _passAndQueueQuorumProposal(deployment, newNumerator, "Lower quorum through governance");

        vm.warp(block.timestamp + factory.DEFAULT_TIMELOCK_DELAY());
        governor.execute(targets, values, calldatas, descriptionHash);
        vm.roll(governor.clock() + 1);

        assertEq(governor.quorumNumerator(), newNumerator);
        assertEq(governor.quorum(governor.clock() - 1), 0);
        assertEq(governor.quorum(defeatedSnapshot), oldQuorum);
        assertEq(uint256(governor.state(defeatedProposalId)), uint256(IGovernor.ProposalState.Defeated));
    }

    function testGovernorConstructorRejectsQuorumNumeratorAboveDenominator() public {
        CoinDAOFactory.Deployment memory deployment = _deploy(0, CoinDAOFactory.StakingTokenChoice.Coin);
        uint256 proposalThreshold = factory.GOVERNOR_PROPOSAL_THRESHOLD();
        uint256 excessiveNumerator = 1_001;

        vm.expectRevert(
            abi.encodeWithSelector(
                GovernorVotesQuorumFraction.GovernorInvalidQuorumFraction.selector, excessiveNumerator, 1_000
            )
        );
        new CoinDAOGovernor(
            "Invalid Governor",
            StakedGovToken(deployment.staker),
            TimelockController(payable(deployment.timelock)),
            proposalThreshold,
            excessiveNumerator
        );
    }

    function testGovernorConstructorAcceptsQuorumNumeratorBoundaries() public {
        CoinDAOFactory.Deployment memory deployment = _deploy(0, CoinDAOFactory.StakingTokenChoice.Coin);
        TimelockController timelock = TimelockController(payable(deployment.timelock));
        StakedGovToken staker = StakedGovToken(deployment.staker);

        vm.expectEmit(false, false, false, true);
        emit QuorumNumeratorUpdated(0, 0);
        CoinDAOGovernor minimumGovernor =
            new CoinDAOGovernor("Minimum Governor", staker, timelock, factory.GOVERNOR_PROPOSAL_THRESHOLD(), 0);
        CoinDAOGovernor maximumGovernor =
            new CoinDAOGovernor("Maximum Governor", staker, timelock, factory.GOVERNOR_PROPOSAL_THRESHOLD(), 1_000);

        assertEq(minimumGovernor.quorumNumerator(), 0);
        assertEq(maximumGovernor.quorumNumerator(), 1_000);
        assertEq(minimumGovernor.quorumDenominator(), 1_000);
        assertEq(maximumGovernor.quorumDenominator(), 1_000);
    }

    function testGovernorQuorumTracksHistoricalStakedSupplyAndRoundsDown() public {
        CoinDAOFactory.Deployment memory deployment = _deploy(0, CoinDAOFactory.StakingTokenChoice.Coin);
        CoinDAOGovernor governor = CoinDAOGovernor(payable(deployment.governor));
        StakedGovToken staker = StakedGovToken(deployment.staker);
        address alice = address(0xA11CE);
        address bob = address(0xB0B);

        _stakeGov(deployment, alice, 1_999);
        vm.roll(staker.clock() + 1);
        uint256 firstTimepoint = staker.clock() - 1;

        assertEq(staker.getPastTotalSupply(firstTimepoint), 1_999);
        assertEq(governor.quorum(firstTimepoint), 1);

        _stakeGov(deployment, bob, 1_001);
        vm.roll(staker.clock() + 1);
        uint256 secondTimepoint = staker.clock() - 1;

        assertEq(staker.getPastTotalSupply(secondTimepoint), 3_000);
        assertEq(governor.quorum(secondTimepoint), 3);
        assertEq(governor.quorum(firstTimepoint), 1);
    }

    function testDeployTwiceKeepsRevenueRouterAsRewardsDistribution() public {
        CoinDAOFactory.Deployment memory first = _deploy(1_000, CoinDAOFactory.StakingTokenChoice.Coin);
        CoinDAOFactory.Deployment memory second = _deploy(0, CoinDAOFactory.StakingTokenChoice.SCoin);

        assertEq(StakedGovToken(first.staker).rewardsDistribution(), first.revenueRouter);
        assertEq(StakedGovToken(second.staker).rewardsDistribution(), second.revenueRouter);

        vm.expectRevert(StakedGovToken.RewardsDistributionAlreadyFinalized.selector);
        vm.prank(first.revenueRouter);
        StakedGovToken(first.staker).finalizeRewardsDistribution(second.revenueRouter);
    }

    function testCoinStakingFunderReleasesSecondTranchePermissionlessly() public {
        CoinDAOFactory.Deployment memory deployment = _deploy(0, CoinDAOFactory.StakingTokenChoice.Coin);
        GovToken govToken = GovToken(deployment.govToken);
        StakingRewards rewards = StakingRewards(deployment.coinStakingRewards);
        StakingRewardsFunder rewardsFunder = StakingRewardsFunder(deployment.coinStakingRewardsFunder);

        uint256 firstTranche = rewardsFunder.trancheAmounts(0);
        uint256 secondTranche = rewardsFunder.trancheAmounts(1);

        vm.warp(rewards.periodFinish());
        vm.prank(address(0xCA11));
        rewardsFunder.fundNextTranche();

        assertEq(rewardsFunder.nextTranche(), 2);
        assertEq(govToken.balanceOf(address(rewards)), firstTranche + secondTranche);
        assertEq(
            govToken.balanceOf(address(rewardsFunder)), rewardsFunder.totalRewards() - firstTranche - secondTranche
        );
    }

    function testRouterDistributesRevenueToStakerByDefault() public {
        CoinDAOFactory.Deployment memory deployment = _deploy(0, CoinDAOFactory.StakingTokenChoice.Coin);
        MockMonolithLender lender = MockMonolithLender(deployment.lender);
        address newManager = address(0xBEEF);

        vm.prank(deployment.timelock);
        RevenueRouter(deployment.revenueRouter).setManager(newManager);
        assertEq(lender.manager(), newManager);

        lender.setAccruedLocalReserves(100 ether);
        RevenueRouter(deployment.revenueRouter).distribute();
        assertEq(IERC20(deployment.coin).balanceOf(deployment.staker), 100 ether);
        assertEq(IERC20(deployment.coin).balanceOf(deployment.timelock), 0);
        assertEq(lender.accruedLocalReserves(), 0);
        assertEq(StakedGovToken(deployment.staker).queuedRewards(), 100 ether);
        assertEq(StakedGovToken(deployment.staker).periodFinish(), 0);
    }

    function testStakerEarnsCoinRevenueAndPreservesVotes() public {
        CoinDAOFactory.Deployment memory deployment = _deploy(0, CoinDAOFactory.StakingTokenChoice.Coin);
        address alice = address(0xA11CE);
        deal(deployment.govToken, alice, 100 ether, true);

        StakedGovToken staker = StakedGovToken(deployment.staker);

        vm.startPrank(alice);
        IERC20(deployment.govToken).approve(deployment.staker, 100 ether);
        staker.depositFor(alice, 100 ether);
        staker.delegate(alice);
        vm.stopPrank();

        // Staked GOV is the governor vote token; raw GOV has no voting power.
        vm.roll(block.number + 1);
        assertEq(staker.getVotes(alice), 100 ether);
        assertEq(IERC20(deployment.govToken).balanceOf(deployment.staker), 100 ether);
        assertEq(staker.balanceOf(alice), 100 ether);

        // Revenue routed to the staker streams to the sole staker over the reward duration.
        deal(deployment.coin, deployment.revenueRouter, 30 ether, true);
        RevenueRouter(deployment.revenueRouter).distribute();
        uint256 finish = staker.periodFinish();

        // A live-period distribution still pulls reserves, but queues the
        // staking allocation instead of extending the current period.
        vm.warp(block.timestamp + 1 days);
        MockMonolithLender(deployment.lender).setAccruedLocalReserves(7 ether);
        RevenueRouter(deployment.revenueRouter).distribute();

        assertEq(MockMonolithLender(deployment.lender).accruedLocalReserves(), 0);
        assertEq(staker.queuedRewards(), 7 ether);
        assertEq(staker.periodFinish(), finish);

        vm.warp(finish);
        vm.prank(alice);
        staker.getReward();
        assertApproxEqAbs(IERC20(deployment.coin).balanceOf(alice), 30 ether, 1e12);
        assertEq(staker.queuedRewards(), 0);
        assertEq(staker.periodFinish(), block.timestamp + 7 days);
    }

    function _deploy(uint16 deployerStakeBps, CoinDAOFactory.StakingTokenChoice stakingTokenChoice)
        internal
        returns (CoinDAOFactory.Deployment memory)
    {
        return factory.deploy(_nextSalt(), _govParams(deployerStakeBps, stakingTokenChoice), _monolithParams(), manager);
    }

    function _nextSalt() internal returns (bytes32) {
        return bytes32(++saltNonce);
    }

    function _newImplementations() internal returns (CoinDAOFactory.Implementations memory newImplementations) {
        newImplementations = CoinDAOFactory.Implementations({
            govToken: address(new GovToken()),
            stakedGovToken: address(new StakedGovToken()),
            revenueRouter: address(new RevenueRouter()),
            stakingRewards: address(new StakingRewards()),
            stakingRewardsFunder: address(new StakingRewardsFunder()),
            vestingWallet: address(new CoinDAOVestingWallet())
        });
    }

    function _deployExistingMarket(address operator_, address manager_)
        internal
        returns (address lender, address coin, address vault)
    {
        IMonolithFactory.DeployParams memory monolithParams = _monolithParams();
        monolithParams.operator = operator_;
        monolithParams.manager = manager_;
        return monolithFactory.deploy(monolithParams);
    }

    function _govParams(uint16 deployerStakeBps, CoinDAOFactory.StakingTokenChoice stakingTokenChoice)
        internal
        view
        returns (CoinDAOFactory.GovLaunchParams memory params)
    {
        params.govTokenName = "Example GOV";
        params.govTokenSymbol = "xGOV";
        params.deployerStakeBps = deployerStakeBps;
        params.deployerRecipient = deployerStakeBps == 0 ? address(0) : deployerRecipient;
        params.stakingTokenChoice = stakingTokenChoice;
    }

    function _existingGovParams(uint16 deployerStakeBps, CoinDAOFactory.StakingTokenChoice stakingTokenChoice)
        internal
        view
        returns (CoinDAOFactory.GovLaunchParams memory params)
    {
        params.govTokenName = "Existing GOV";
        params.govTokenSymbol = "eGOV";
        params.deployerStakeBps = deployerStakeBps;
        params.deployerRecipient = deployerStakeBps == 0 ? address(0) : deployerRecipient;
        params.stakingTokenChoice = stakingTokenChoice;
    }

    function _monolithParams() internal pure returns (IMonolithFactory.DeployParams memory params) {
        params = IMonolithFactory.DeployParams({
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
            halfLife: 0,
            targetFreeDebtRatioStartBps: 0,
            targetFreeDebtRatioEndBps: 0,
            redeemFeeBps: 0,
            stalenessThreshold: 0,
            maxBorrowDeltaBps: 0,
            psmVaultMinTotalSupply: 0
        });
    }

    function _passAndQueueQuorumProposal(
        CoinDAOFactory.Deployment memory deployment,
        uint256 newQuorumNumerator,
        string memory description
    )
        internal
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash)
    {
        CoinDAOGovernor governor = CoinDAOGovernor(payable(deployment.governor));
        StakedGovToken staker = StakedGovToken(deployment.staker);
        address voter = address(0xC0FFEE);
        uint256 votingPower = governor.proposalThreshold();

        deal(deployment.govToken, voter, votingPower, true);
        vm.startPrank(voter);
        IERC20(deployment.govToken).approve(deployment.staker, votingPower);
        staker.depositFor(voter, votingPower);
        staker.delegate(voter);
        vm.stopPrank();
        vm.roll(governor.clock() + 1);

        targets = new address[](1);
        targets[0] = address(governor);
        values = new uint256[](1);
        calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(governor.updateQuorumNumerator, (newQuorumNumerator));
        descriptionHash = keccak256(bytes(description));

        vm.prank(voter);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);
        vm.roll(governor.proposalSnapshot(proposalId) + 1);
        vm.prank(voter);
        governor.castVote(proposalId, 1);
        vm.roll(governor.proposalDeadline(proposalId) + 1);
        governor.queue(targets, values, calldatas, descriptionHash);
    }

    function _stakeGov(CoinDAOFactory.Deployment memory deployment, address account, uint256 amount) internal {
        deal(deployment.govToken, account, amount, true);
        vm.startPrank(account);
        IERC20(deployment.govToken).approve(deployment.staker, amount);
        StakedGovToken(deployment.staker).depositFor(account, amount);
        vm.stopPrank();
    }

    function _sum(CoinDAOFactory.AllocationAmounts memory allocation) internal pure returns (uint256) {
        return allocation.coinStakingRewards + allocation.immediateAllocation + allocation.treasuryVested
            + allocation.monolithVesting + allocation.deployerVesting;
    }

    function _assertDeploymentContractsHaveCode(CoinDAOFactory.Deployment memory deployment) internal view {
        assertGt(deployment.govToken.code.length, 0);
        assertGt(deployment.staker.code.length, 0);
        assertGt(deployment.governor.code.length, 0);
        assertGt(deployment.timelock.code.length, 0);
        assertGt(deployment.lender.code.length, 0);
        assertGt(deployment.coin.code.length, 0);
        assertGt(deployment.vault.code.length, 0);
        assertGt(deployment.stakingToken.code.length, 0);
        assertGt(deployment.revenueRouter.code.length, 0);
        assertGt(deployment.coinStakingRewards.code.length, 0);
        assertGt(deployment.coinStakingRewardsFunder.code.length, 0);
        assertGt(deployment.treasuryVesting.code.length, 0);
        assertGt(deployment.monolithVesting.code.length, 0);
        if (deployment.deployerVesting != address(0)) {
            assertGt(deployment.deployerVesting.code.length, 0);
        }
    }

    function _assertPredictedAddresses(
        CoinDAOFactory.Deployment memory deployment,
        CoinDAOFactory.PredictedAddresses memory predicted
    ) internal pure {
        assertEq(deployment.govToken, predicted.govToken);
        assertEq(deployment.staker, predicted.staker);
        assertEq(deployment.governor, predicted.governor);
        assertEq(deployment.timelock, predicted.timelock);
        assertEq(deployment.revenueRouter, predicted.revenueRouter);
        assertEq(deployment.coinStakingRewards, predicted.coinStakingRewards);
        assertEq(deployment.coinStakingRewardsFunder, predicted.coinStakingRewardsFunder);
        assertEq(deployment.treasuryVesting, predicted.treasuryVesting);
        assertEq(deployment.monolithVesting, predicted.monolithVesting);
        assertEq(deployment.deployerVesting, predicted.deployerVesting);
    }

    function _assertMinimalProxy(address instance, address implementation) internal view {
        bytes memory expectedRuntime =
            abi.encodePacked(hex"363d3d373d3d3d363d73", implementation, hex"5af43d82803e903d91602b57fd5bf3");
        assertEq(instance.code, expectedRuntime);
    }
}
