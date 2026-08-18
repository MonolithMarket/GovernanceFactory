pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {VestingWallet} from "@openzeppelin/contracts/finance/VestingWallet.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {CoinDAOFactory} from "../src/CoinDAOFactory.sol";
import {CoinDAOVestingWallet} from "../src/CoinDAOVestingWallet.sol";
import {CoinDAOGovernor} from "../src/CoinDAOGovernor.sol";
import {GovToken} from "../src/GovToken.sol";
import {RevenueRouter} from "../src/RevenueRouter.sol";
import {StakedGovToken} from "../src/StakedGovToken.sol";
import {StakingRewards} from "../src/StakingRewards.sol";
import {StakingRewardsFunder} from "../src/StakingRewardsFunder.sol";
import {IMonolithFactory} from "../src/interfaces/IMonolith.sol";
import {MockMonolithLender} from "./mocks/MockMonolith.sol";
import {CoinDAOTestBase} from "./helpers/CoinDAOTestBase.sol";

contract CoinDAOFactoryTest is CoinDAOTestBase {
    event MonolithBeneficiaryTransferStarted(address indexed currentBeneficiary, address indexed pendingBeneficiary);
    event MonolithBeneficiaryTransferred(address indexed previousBeneficiary, address indexed newBeneficiary);

    function testConstructorValidation() public {
        vm.expectRevert(CoinDAOFactory.ZeroAddress.selector);
        new CoinDAOFactory(IMonolithFactory(address(0)), monolithRecipient, implementationSet);

        vm.expectRevert(CoinDAOFactory.ZeroAddress.selector);
        new CoinDAOFactory(IMonolithFactory(address(monolithFactory)), address(0), implementationSet);

        CoinDAOFactory.Implementations memory invalid = implementationSet;
        invalid.govToken = address(0xBAD);
        vm.expectRevert(abi.encodeWithSelector(CoinDAOFactory.InvalidImplementation.selector, address(0xBAD)));
        new CoinDAOFactory(IMonolithFactory(address(monolithFactory)), monolithRecipient, invalid);

        invalid = implementationSet;
        invalid.revenueRouter = implementationSet.govToken;
        vm.expectRevert(
            abi.encodeWithSelector(CoinDAOFactory.DuplicateImplementation.selector, implementationSet.govToken)
        );
        new CoinDAOFactory(IMonolithFactory(address(monolithFactory)), monolithRecipient, invalid);
    }

    function testImplementationsAndInitializedClonesAreLocked() public {
        vm.expectRevert();
        GovToken(implementationSet.govToken).initialize("Governance", "GOV", address(this));
        vm.expectRevert();
        StakedGovToken(implementationSet.stakedGovToken)
            .initialize(IERC20(address(1)), IERC20(address(2)), "Staked", "sGOV", address(this));
        vm.expectRevert();
        RevenueRouter(implementationSet.revenueRouter)
            .initialize(address(1), address(2), address(3), address(4), 10_000, address(this));
        vm.expectRevert();
        StakingRewards(implementationSet.stakingRewards).initialize(address(1), address(2), address(this), 1 days);
        vm.expectRevert();
        StakingRewardsFunder(implementationSet.stakingRewardsFunder).initialize(StakingRewards(address(1)), 1);
        vm.expectRevert();
        CoinDAOVestingWallet(payable(implementationSet.vestingWallet)).initialize(address(this), 1, 1 days);

        CoinDAOFactory.Deployment memory deployment = _deploy(1_000, CoinDAOFactory.StakingTokenChoice.Coin);
        vm.expectRevert();
        GovToken(deployment.govToken).initialize("Other", "OTHER", address(this));
        vm.expectRevert();
        StakedGovToken(deployment.staker)
            .initialize(IERC20(deployment.govToken), IERC20(deployment.coin), "Other", "oGOV", address(this));
        vm.expectRevert();
        RevenueRouter(deployment.revenueRouter)
            .initialize(deployment.lender, deployment.coin, address(this), deployment.staker, 0, address(this));
        vm.expectRevert();
        StakingRewards(deployment.coinStakingRewards)
            .initialize(deployment.coin, deployment.govToken, address(this), 1 days);
        vm.expectRevert();
        StakingRewardsFunder(deployment.coinStakingRewardsFunder)
            .initialize(StakingRewards(deployment.coinStakingRewards), 1);
        vm.expectRevert();
        CoinDAOVestingWallet(payable(deployment.treasuryVesting)).initialize(address(this), 1, 1 days);
    }

    function testFreshLaunchPredictsProxiesAndWiresCanonicalDeployment() public {
        bytes32 userSalt = keccak256("canonical launch");
        CoinDAOFactory.GovLaunchParams memory params = _govParams(1_000, CoinDAOFactory.StakingTokenChoice.Coin);
        CoinDAOFactory.PredictedAddresses memory predicted =
            factory.predictCoinDAOAddresses(address(this), userSalt, params);
        CoinDAOFactory.Deployment memory deployment = factory.deploy(userSalt, params, _monolithParams(), manager);

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
        assertEq(factory.deploymentsLength(), 1);
        assertTrue(factory.hasCoinDAO(deployment.lender));
        assertEq(deployment.stakingToken, deployment.coin);
        assertEq(MockMonolithLender(deployment.lender).operator(), deployment.revenueRouter);
        assertEq(MockMonolithLender(deployment.lender).manager(), manager);

        CoinDAOFactory.AllocationAmounts memory allocation = factory.allocationFor(1_000);
        GovToken govToken = GovToken(deployment.govToken);
        StakingRewardsFunder funder = StakingRewardsFunder(deployment.coinStakingRewardsFunder);
        uint256 firstTranche = funder.trancheAmount(0);
        assertEq(govToken.totalSupply(), factory.GOV_TOKEN_SUPPLY());
        assertEq(govToken.balanceOf(deployment.coinStakingRewards), firstTranche);
        assertEq(govToken.balanceOf(deployment.coinStakingRewardsFunder), allocation.coinStakingRewards - firstTranche);
        assertEq(govToken.balanceOf(deployerRecipient), allocation.immediateAllocation);
        assertEq(govToken.balanceOf(deployment.treasuryVesting), allocation.treasuryVested);
        assertEq(govToken.balanceOf(deployment.monolithVesting), allocation.monolithVesting);
        assertEq(govToken.balanceOf(deployment.deployerVesting), allocation.deployerVesting);

        CoinDAOGovernor governor = CoinDAOGovernor(payable(deployment.governor));
        assertEq(address(governor.token()), deployment.staker);
        assertEq(governor.name(), "Example GOV Governor");
        assertEq(governor.quorumNumerator(), factory.GOVERNOR_QUORUM_NUMERATOR());
        assertEq(address(StakedGovToken(deployment.staker).revenueRouter()), deployment.revenueRouter);
        assertEq(Ownable(deployment.revenueRouter).owner(), deployment.timelock);
        assertEq(VestingWallet(payable(deployment.treasuryVesting)).owner(), deployment.timelock);
        assertEq(VestingWallet(payable(deployment.monolithVesting)).owner(), monolithRecipient);
        assertEq(VestingWallet(payable(deployment.deployerVesting)).owner(), deployerRecipient);
        assertEq(RevenueRouter(deployment.revenueRouter).govStakingBps(), 10_000);
        assertEq(address(funder.stakingRewards()), deployment.coinStakingRewards);
        assertEq(funder.totalRewards(), allocation.coinStakingRewards);
        assertEq(funder.nextTranche(), 1);
        assertEq(
            StakingRewards(deployment.coinStakingRewards).rewardsDistribution(), deployment.coinStakingRewardsFunder
        );
        assertEq(
            StakingRewards(deployment.coinStakingRewards).rewardsDuration(), factory.COIN_STAKING_REWARD_DURATION()
        );
        assertEq(Ownable(deployment.coinStakingRewards).owner(), address(0));
        assertFalse(TimelockController(payable(deployment.timelock)).hasRole(bytes32(0), address(factory)));
    }

    function testLaunchVariantsCoverSCoinAndUnvestedImmediateAllocation() public {
        bytes32 zeroSalt = _nextSalt();
        CoinDAOFactory.GovLaunchParams memory zeroParams = _govParams(0, CoinDAOFactory.StakingTokenChoice.SCoin);
        CoinDAOFactory.PredictedAddresses memory zeroPredicted =
            factory.predictCoinDAOAddresses(address(this), zeroSalt, zeroParams);
        CoinDAOFactory.Deployment memory zeroDeployment =
            factory.deploy(zeroSalt, zeroParams, _monolithParams(), manager);
        CoinDAOFactory.AllocationAmounts memory allocation = factory.allocationFor(0);

        assertEq(zeroDeployment.stakingToken, zeroDeployment.vault);
        assertEq(zeroDeployment.deployerVesting, address(0));
        assertEq(zeroPredicted.deployerVesting.code.length, 0);
        assertEq(GovToken(zeroDeployment.govToken).balanceOf(zeroDeployment.timelock), allocation.immediateAllocation);

        CoinDAOFactory.GovLaunchParams memory recipientParams = _govParams(0, CoinDAOFactory.StakingTokenChoice.Coin);
        recipientParams.deployerRecipient = deployerRecipient;
        CoinDAOFactory.Deployment memory recipientDeployment =
            factory.deploy(_nextSalt(), recipientParams, _monolithParams(), manager);
        assertEq(recipientDeployment.deployerVesting, address(0));
        assertEq(GovToken(recipientDeployment.govToken).balanceOf(deployerRecipient), allocation.immediateAllocation);
        assertEq(GovToken(recipientDeployment.govToken).balanceOf(recipientDeployment.timelock), 0);
    }

    function testSameSaltIsNamespacedByCreator() public view {
        bytes32 userSalt = keccak256("shared salt");
        CoinDAOFactory.GovLaunchParams memory params = _govParams(0, CoinDAOFactory.StakingTokenChoice.Coin);
        CoinDAOFactory.PredictedAddresses memory first =
            factory.predictCoinDAOAddresses(address(this), userSalt, params);
        CoinDAOFactory.PredictedAddresses memory second =
            factory.predictCoinDAOAddresses(address(0xA11CE), userSalt, params);
        assertNotEq(first.govToken, second.govToken);
        assertNotEq(first.governor, second.governor);
        assertNotEq(factory.deploymentKey(address(this), userSalt), factory.deploymentKey(address(0xA11CE), userSalt));
    }

    function testReusedDeploymentKeyRevertsBeforeExternalMarketDeployment() public {
        bytes32 userSalt = keccak256("single use");
        CoinDAOFactory.GovLaunchParams memory params = _govParams(0, CoinDAOFactory.StakingTokenChoice.Coin);
        factory.deploy(userSalt, params, _monolithParams(), manager);
        bytes32 key = factory.deploymentKey(address(this), userSalt);
        vm.expectRevert(abi.encodeWithSelector(CoinDAOFactory.DeploymentKeyAlreadyUsed.selector, key));
        factory.deploy(userSalt, params, _monolithParams(), manager);
        assertEq(monolithFactory.deploymentsLength(), 1);
        assertEq(factory.deploymentsLength(), 1);
    }

    function testCloneLaunchGasRegression() public {
        uint256 gasBefore = gasleft();
        _deploy(0, CoinDAOFactory.StakingTokenChoice.Coin);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("Mock-market CoinDAO deployment gas", gasUsed);
        assertLt(gasUsed, 10_000_000);
    }

    function testMonolithBeneficiaryHandoffLifecycle() public {
        address firstNominee = address(0xB001);
        address beneficiary = address(0xB002);
        address attacker = address(0xBAD);

        vm.expectRevert(
            abi.encodeWithSelector(CoinDAOFactory.CallerNotMonolithBeneficiary.selector, attacker, monolithRecipient)
        );
        vm.prank(attacker);
        factory.setPendingMonolithBeneficiary(firstNominee);
        vm.expectRevert(CoinDAOFactory.ZeroAddress.selector);
        vm.prank(monolithRecipient);
        factory.setPendingMonolithBeneficiary(address(0));

        vm.startPrank(monolithRecipient);
        factory.setPendingMonolithBeneficiary(firstNominee);
        vm.expectEmit(true, true, false, true, address(factory));
        emit MonolithBeneficiaryTransferStarted(monolithRecipient, beneficiary);
        factory.setPendingMonolithBeneficiary(beneficiary);
        vm.stopPrank();

        vm.expectRevert(
            abi.encodeWithSelector(
                CoinDAOFactory.CallerNotPendingMonolithBeneficiary.selector, firstNominee, beneficiary
            )
        );
        vm.prank(firstNominee);
        factory.acceptMonolithBeneficiary();
        vm.expectEmit(true, true, false, true, address(factory));
        emit MonolithBeneficiaryTransferred(monolithRecipient, beneficiary);
        vm.prank(beneficiary);
        factory.acceptMonolithBeneficiary();
        assertEq(factory.monolithBeneficiary(), beneficiary);
        assertEq(factory.pendingMonolithBeneficiary(), address(0));
        vm.expectRevert(
            abi.encodeWithSelector(CoinDAOFactory.CallerNotMonolithBeneficiary.selector, monolithRecipient, beneficiary)
        );
        vm.prank(monolithRecipient);
        factory.setPendingMonolithBeneficiary(firstNominee);
    }

    function testBeneficiaryHandoffOnlyAffectsFutureVestings() public {
        CoinDAOFactory.Deployment memory beforeHandoff = _deploy(0, CoinDAOFactory.StakingTokenChoice.Coin);
        address beneficiary = address(0xB001);
        vm.prank(monolithRecipient);
        factory.setPendingMonolithBeneficiary(beneficiary);
        CoinDAOFactory.Deployment memory pending = _deploy(0, CoinDAOFactory.StakingTokenChoice.Coin);
        vm.prank(beneficiary);
        factory.acceptMonolithBeneficiary();
        CoinDAOFactory.Deployment memory afterHandoff = _deploy(0, CoinDAOFactory.StakingTokenChoice.Coin);

        assertEq(VestingWallet(payable(beforeHandoff.monolithVesting)).owner(), monolithRecipient);
        assertEq(VestingWallet(payable(pending.monolithVesting)).owner(), monolithRecipient);
        assertEq(VestingWallet(payable(afterHandoff.monolithVesting)).owner(), beneficiary);
    }

    function testFuzzAllocationPreservesWeightsAndSupply(uint16 deployerStakeBps_) public view {
        _assertAllocation(0);
        _assertAllocation(factory.MAX_DEPLOYER_STAKE_BPS());
        _assertAllocation(uint16(bound(deployerStakeBps_, 0, factory.MAX_DEPLOYER_STAKE_BPS())));
    }

    function testAllocationRejectsExcessiveDeployerStake() public {
        vm.expectRevert(abi.encodeWithSelector(CoinDAOFactory.DeployerStakeExceedsMaximum.selector, 2_001));
        factory.allocationFor(2_001);
    }

    function testDeployRejectsVestedStakeWithoutRecipient() public {
        CoinDAOFactory.GovLaunchParams memory params = _govParams(1_000, CoinDAOFactory.StakingTokenChoice.Coin);
        params.deployerRecipient = address(0);
        vm.expectRevert(CoinDAOFactory.DeployerRecipientRequired.selector);
        factory.deploy(_nextSalt(), params, _monolithParams(), manager);
    }

    function testExistingMarketLaunchPreservesMarketAndWiresDAO() public {
        (address lenderAddress, address coin, address vault) = _deployExistingMarket(existingOperator, existingManager);
        MockMonolithLender lender = MockMonolithLender(lenderAddress);
        vm.prank(existingOperator);
        lender.setPendingOperator(address(factory));
        vm.prank(existingOperator);
        CoinDAOFactory.Deployment memory deployment = factory.deployForExistingCoin(
            _nextSalt(), _existingGovParams(1_000, CoinDAOFactory.StakingTokenChoice.Coin), lenderAddress
        );

        assertEq(deployment.lender, lenderAddress);
        assertEq(deployment.coin, coin);
        assertEq(deployment.vault, vault);
        assertEq(deployment.stakingToken, coin);
        assertEq(lender.operator(), deployment.revenueRouter);
        assertEq(lender.pendingOperator(), address(0));
        assertEq(lender.manager(), existingManager);
        assertEq(Ownable(deployment.revenueRouter).owner(), deployment.timelock);
        assertEq(address(StakedGovToken(deployment.staker).revenueRouter()), deployment.revenueRouter);
        assertTrue(factory.hasCoinDAO(lenderAddress));

        CoinDAOFactory.AllocationAmounts memory allocation = factory.allocationFor(1_000);
        GovToken govToken = GovToken(deployment.govToken);
        assertEq(govToken.balanceOf(deployerRecipient), allocation.immediateAllocation);
        assertEq(govToken.balanceOf(deployment.treasuryVesting), allocation.treasuryVested);
        assertEq(govToken.balanceOf(deployment.monolithVesting), allocation.monolithVesting);
        assertEq(govToken.balanceOf(deployment.deployerVesting), allocation.deployerVesting);
    }

    function testExistingMarketLaunchSupportsSCoin() public {
        CoinDAOFactory.Deployment memory deployment = _deployExisting(0, CoinDAOFactory.StakingTokenChoice.SCoin);
        assertEq(deployment.stakingToken, deployment.vault);
        assertEq(deployment.deployerVesting, address(0));
        assertEq(MockMonolithLender(deployment.lender).manager(), existingManager);
        assertEq(
            GovToken(deployment.govToken).balanceOf(deployment.timelock), factory.allocationFor(0).immediateAllocation
        );
    }

    function testExistingMarketRejectsUnrecognizedLender() public {
        address unrecognized = address(0xBAD);
        vm.expectRevert(abi.encodeWithSelector(CoinDAOFactory.UnrecognizedLender.selector, unrecognized));
        vm.prank(existingOperator);
        factory.deployForExistingCoin(
            _nextSalt(), _existingGovParams(0, CoinDAOFactory.StakingTokenChoice.Coin), unrecognized
        );
    }

    function testExistingMarketRejectsCallerThatIsNotOperator() public {
        (address lenderAddress,,) = _deployExistingMarket(existingOperator, existingManager);
        MockMonolithLender lender = MockMonolithLender(lenderAddress);
        vm.prank(existingOperator);
        lender.setPendingOperator(address(factory));
        address attacker = address(0xA77AC);
        vm.expectRevert(
            abi.encodeWithSelector(CoinDAOFactory.CallerNotLenderOperator.selector, attacker, existingOperator)
        );
        vm.prank(attacker);
        factory.deployForExistingCoin(
            _nextSalt(), _existingGovParams(0, CoinDAOFactory.StakingTokenChoice.Coin), lenderAddress
        );
        assertEq(lender.operator(), existingOperator);
        assertEq(factory.deploymentsLength(), 0);
    }

    function testExistingMarketRequiresFactoryNomination() public {
        (address lenderAddress,,) = _deployExistingMarket(existingOperator, existingManager);
        vm.expectRevert(abi.encodeWithSelector(CoinDAOFactory.FactoryNotPendingOperator.selector, address(0)));
        vm.prank(existingOperator);
        factory.deployForExistingCoin(
            _nextSalt(), _existingGovParams(0, CoinDAOFactory.StakingTokenChoice.Coin), lenderAddress
        );
    }

    function testExistingMarketRejectsDuplicateAttachment() public {
        CoinDAOFactory.Deployment memory deployment = _deployExisting(0, CoinDAOFactory.StakingTokenChoice.Coin);
        vm.expectRevert(abi.encodeWithSelector(CoinDAOFactory.CoinDAOAlreadyExists.selector, deployment.lender));
        factory.deployForExistingCoin(
            _nextSalt(), _existingGovParams(0, CoinDAOFactory.StakingTokenChoice.Coin), deployment.lender
        );
    }

    function testRouterHandoffFailureRollsBackEntireExistingMarketAttachment() public {
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

    function _assertAllocation(uint16 deployerStakeBps) internal view {
        uint256 supply = factory.GOV_TOKEN_SUPPLY();
        uint256 monolithAmount = (supply * 200) / 10_000;
        uint256 deployerAmount = (supply * deployerStakeBps) / 10_000;
        uint256 remaining = supply - monolithAmount - deployerAmount;
        CoinDAOFactory.AllocationAmounts memory allocation = factory.allocationFor(deployerStakeBps);
        assertEq(allocation.monolithVesting, monolithAmount);
        assertEq(allocation.deployerVesting, deployerAmount);
        assertEq(allocation.coinStakingRewards, (remaining * 6_500) / 9_800);
        assertEq(allocation.immediateAllocation, (remaining * 500) / 9_800);
        assertEq(_sum(allocation), supply);
    }
}
