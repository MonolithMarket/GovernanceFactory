pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CoinDAOFactory} from "../../src/CoinDAOFactory.sol";
import {CoinDAOVestingWallet} from "../../src/CoinDAOVestingWallet.sol";
import {GovToken} from "../../src/GovToken.sol";
import {RevenueRouter} from "../../src/RevenueRouter.sol";
import {StakedGovToken} from "../../src/StakedGovToken.sol";
import {StakingRewards} from "../../src/StakingRewards.sol";
import {StakingRewardsFunder} from "../../src/StakingRewardsFunder.sol";
import {IMonolithFactory} from "../../src/interfaces/IMonolith.sol";
import {MockMonolithFactory} from "../mocks/MockMonolith.sol";

abstract contract CoinDAOTestBase is Test {
    CoinDAOFactory internal factory;
    MockMonolithFactory internal monolithFactory;
    CoinDAOFactory.Implementations internal implementationSet;

    address internal manager = address(0x1001);
    address internal deployerRecipient = address(0x1002);
    address internal monolithRecipient = address(0x1003);
    address internal existingOperator = address(0x1004);
    address internal existingManager = address(0x1005);
    uint256 internal saltNonce;

    function setUp() public virtual {
        monolithFactory = new MockMonolithFactory();
        implementationSet = _newImplementations();
        factory = new CoinDAOFactory(IMonolithFactory(address(monolithFactory)), monolithRecipient, implementationSet);
    }

    function _deploy(uint16 deployerStakeBps, CoinDAOFactory.StakingTokenChoice stakingTokenChoice)
        internal
        returns (CoinDAOFactory.Deployment memory)
    {
        return factory.deploy(_nextSalt(), _govParams(deployerStakeBps, stakingTokenChoice), _monolithParams(), manager);
    }

    function _deployExisting(uint16 deployerStakeBps, CoinDAOFactory.StakingTokenChoice stakingTokenChoice)
        internal
        returns (CoinDAOFactory.Deployment memory deployment)
    {
        (address lenderAddress,,) = _deployExistingMarket(existingOperator, existingManager);
        // The incumbent operator nominates the factory, then invokes the atomic attachment path.
        vm.prank(existingOperator);
        _lender(lenderAddress).setPendingOperator(address(factory));
        vm.prank(existingOperator);
        deployment = factory.deployForExistingCoin(
            _nextSalt(), _existingGovParams(deployerStakeBps, stakingTokenChoice), lenderAddress
        );
    }

    function _nextSalt() internal returns (bytes32) {
        return bytes32(++saltNonce);
    }

    function _newImplementations() internal returns (CoinDAOFactory.Implementations memory implementations_) {
        implementations_ = CoinDAOFactory.Implementations({
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
        IMonolithFactory.DeployParams memory params = _monolithParams();
        params.operator = operator_;
        params.manager = manager_;
        return monolithFactory.deploy(params);
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
        params = _govParams(deployerStakeBps, stakingTokenChoice);
        params.govTokenName = "Existing GOV";
        params.govTokenSymbol = "eGOV";
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

    function _stakeGov(CoinDAOFactory.Deployment memory deployment, address account, uint256 amount) internal {
        deal(deployment.govToken, account, amount, true);
        vm.startPrank(account);
        IERC20(deployment.govToken).approve(deployment.staker, amount);
        StakedGovToken(deployment.staker).depositFor(account, amount);
        StakedGovToken(deployment.staker).delegate(account);
        vm.stopPrank();
    }

    function _sum(CoinDAOFactory.AllocationAmounts memory allocation) internal pure returns (uint256) {
        return allocation.coinStakingRewards + allocation.immediateAllocation + allocation.treasuryVested
            + allocation.monolithVesting + allocation.deployerVesting;
    }

    function _assertMinimalProxy(address instance, address implementation) internal view {
        bytes memory expected =
            abi.encodePacked(hex"363d3d373d3d3d363d73", implementation, hex"5af43d82803e903d91602b57fd5bf3");
        assertEq(instance.code, expected);
    }

    function _lender(address lenderAddress) internal pure returns (MockLenderLike) {
        return MockLenderLike(lenderAddress);
    }
}

interface MockLenderLike {
    function setPendingOperator(address pendingOperator) external;
}
