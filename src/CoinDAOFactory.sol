// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {VestingWallet} from "@openzeppelin/contracts/finance/VestingWallet.sol";

import {CliffVestingWallet} from "./CliffVestingWallet.sol";
import {CoinDAOGovernor} from "./CoinDAOGovernor.sol";
import {GovToken} from "./GovToken.sol";
import {IStGovTokenRewards, RevenueRouter} from "./RevenueRouter.sol";
import {StGovToken} from "./StGovToken.sol";
import {StakingRewards} from "./StakingRewards.sol";
import {IMonolithFactory, IMonolithLender} from "./interfaces/IMonolith.sol";

contract CoinDAOFactory {
    using SafeERC20 for IERC20;

    uint16 public constant BPS = 10_000;
    uint16 public constant DEFAULT_REVENUE_SHARE_BPS = 5_000;
    uint256 public constant DEFAULT_TIMELOCK_DELAY = 2 days;
    uint256 public constant DEFAULT_GUARDIAN_DURATION = 365 days;
    uint64 public constant DAO_TREASURY_VEST_DURATION = 4 * 365 days;
    uint64 public constant TEAM_VEST_DURATION = 4 * 365 days;
    uint64 public constant TEAM_CLIFF_DURATION = 365 days;
    uint64 public constant MONOLITH_VEST_DURATION = 2 * 365 days;

    enum AllocationTemplate {
        FairLaunch,
        StandardLaunch,
        TeamLedLaunch
    }

    struct AllocationBps {
        uint16 coinStakingRewards;
        uint16 timelockTreasuryVested;
        uint16 timelockImmediate;
        uint16 teamVesting;
        uint16 monolithVesting;
    }

    struct LaunchParams {
        string govTokenName;
        string govTokenSymbol;
        string stGovTokenName;
        string stGovTokenSymbol;
        string governorName;
        IMonolithFactory monolithFactory;
        IMonolithFactory.DeployParams monolithParams;
        uint256 govTokenSupply;
        AllocationTemplate allocationTemplate;
        address teamRecipient;
        address monolithRecipient;
        address guardian;
        uint256 proposalThreshold;
        uint64 vestingStart;
        uint256 stGovRewardDuration;
        uint256 coinStakingRewardDuration;
    }

    struct Deployment {
        GovToken govToken;
        StGovToken stGovToken;
        CoinDAOGovernor governor;
        TimelockController timelock;
        address monolithFactory;
        address lender;
        IERC20 coin;
        address vault;
        RevenueRouter revenueRouter;
        StakingRewards coinStakingRewards;
        VestingWallet timelockVesting;
        CliffVestingWallet teamVesting;
        VestingWallet monolithVesting;
    }

    Deployment[] private _deployments;

    error ZeroAddress();
    error ZeroAmount();
    error InvalidAllocationTemplate();
    error InvalidAllocationTotal(uint256 totalBps);
    error TeamAllocationExceedsMaximum(uint16 teamAllocationBps);

    event CoinDAODeployed(
        uint256 indexed id,
        address indexed lender,
        address indexed coin,
        address monolithFactory,
        address vault,
        address govToken,
        address stGovToken,
        address governor,
        address timelock,
        address revenueRouter,
        address coinStakingRewards
    );

    function deploymentsLength() external view returns (uint256) {
        return _deployments.length;
    }

    function deployments(uint256 id) external view returns (Deployment memory) {
        return _deployments[id];
    }

    function allocationFor(AllocationTemplate template_) public pure returns (AllocationBps memory allocation) {
        if (template_ == AllocationTemplate.FairLaunch) {
            return AllocationBps(6_800, 2_500, 500, 0, 200);
        }
        if (template_ == AllocationTemplate.StandardLaunch) {
            return AllocationBps(5_300, 2_500, 500, 1_500, 200);
        }
        if (template_ == AllocationTemplate.TeamLedLaunch) {
            return AllocationBps(4_800, 2_500, 500, 2_000, 200);
        }
        revert InvalidAllocationTemplate();
    }

    function deploy(LaunchParams calldata params) external returns (Deployment memory deployment) {
        if (address(params.monolithFactory) == address(0) || params.monolithRecipient == address(0)) {
            revert ZeroAddress();
        }
        if (params.govTokenSupply == 0 || params.stGovRewardDuration == 0 || params.coinStakingRewardDuration == 0) {
            revert ZeroAmount();
        }

        AllocationBps memory allocation = allocationFor(params.allocationTemplate);
        _validateAllocation(allocation, params.teamRecipient);

        uint64 start = params.vestingStart == 0 ? uint64(block.timestamp) : params.vestingStart;

        address[] memory proposers = new address[](0);
        address[] memory executors = new address[](1);
        executors[0] = address(0);

        TimelockController timelock =
            new TimelockController(DEFAULT_TIMELOCK_DELAY, proposers, executors, address(this));

        (address lender, address coin, address vault) =
            params.monolithFactory.deploy(_monolithParams(params.monolithParams, address(timelock)));

        GovToken govToken =
            new GovToken(params.govTokenName, params.govTokenSymbol, address(this), params.govTokenSupply);
        StGovToken stGovToken =
            new StGovToken(IERC20(address(govToken)), params.stGovTokenName, params.stGovTokenSymbol, address(this));

        RevenueRouter revenueRouter = new RevenueRouter(
            lender, IERC20(coin), address(timelock), IStGovTokenRewards(address(stGovToken)), DEFAULT_REVENUE_SHARE_BPS
        );
        IMonolithLender(lender).setPendingOperator(address(revenueRouter));
        revenueRouter.acceptLenderOperator();

        StakingRewards coinStakingRewards = new StakingRewards(
            IERC20(coin), IERC20(address(govToken)), address(this), params.coinStakingRewardDuration
        );

        CoinDAOGovernor governor = new CoinDAOGovernor(
            params.governorName,
            stGovToken,
            timelock,
            params.proposalThreshold,
            params.guardian,
            block.timestamp + DEFAULT_GUARDIAN_DURATION
        );

        VestingWallet timelockVesting = new VestingWallet(address(timelock), start, DAO_TREASURY_VEST_DURATION);
        CliffVestingWallet teamVesting;
        if (allocation.teamVesting > 0) {
            teamVesting = new CliffVestingWallet(params.teamRecipient, start, TEAM_VEST_DURATION, TEAM_CLIFF_DURATION);
        }
        VestingWallet monolithVesting = new VestingWallet(params.monolithRecipient, start, MONOLITH_VEST_DURATION);

        _fundAllocations(
            govToken,
            params.govTokenSupply,
            allocation,
            address(timelock),
            address(timelockVesting),
            address(teamVesting),
            address(monolithVesting),
            address(coinStakingRewards)
        );
        coinStakingRewards.notifyRewardAmount(_amountFor(params.govTokenSupply, allocation.coinStakingRewards));

        stGovToken.addRewardToken(coin, params.stGovRewardDuration);
        stGovToken.setRewardNotifier(coin, address(revenueRouter), true);
        stGovToken.transferOwnership(address(timelock));
        coinStakingRewards.transferOwnership(address(timelock));

        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(governor));
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), address(this));

        deployment = Deployment({
            govToken: govToken,
            stGovToken: stGovToken,
            governor: governor,
            timelock: timelock,
            monolithFactory: address(params.monolithFactory),
            lender: lender,
            coin: IERC20(coin),
            vault: vault,
            revenueRouter: revenueRouter,
            coinStakingRewards: coinStakingRewards,
            timelockVesting: timelockVesting,
            teamVesting: teamVesting,
            monolithVesting: monolithVesting
        });

        _deployments.push(deployment);
        emit CoinDAODeployed(
            _deployments.length - 1,
            lender,
            coin,
            address(params.monolithFactory),
            vault,
            address(govToken),
            address(stGovToken),
            address(governor),
            address(timelock),
            address(revenueRouter),
            address(coinStakingRewards)
        );
    }

    function _monolithParams(IMonolithFactory.DeployParams calldata params, address timelock)
        internal
        view
        returns (IMonolithFactory.DeployParams memory)
    {
        return IMonolithFactory.DeployParams({
            name: params.name,
            symbol: params.symbol,
            collateral: params.collateral,
            psmAsset: params.psmAsset,
            psmVault: params.psmVault,
            feed: params.feed,
            collateralFactor: params.collateralFactor,
            minDebt: params.minDebt,
            timeUntilImmutability: params.timeUntilImmutability,
            operator: address(this),
            manager: timelock,
            eventTriggerOperator: params.eventTriggerOperator,
            halfLife: params.halfLife,
            targetPsmDebtRatioStartBps: params.targetPsmDebtRatioStartBps,
            targetPsmDebtRatioEndBps: params.targetPsmDebtRatioEndBps,
            stalenessThreshold: params.stalenessThreshold,
            maxBorrowDeltaBps: params.maxBorrowDeltaBps,
            psmVaultMinTotalSupply: params.psmVaultMinTotalSupply
        });
    }

    function _validateAllocation(AllocationBps memory allocation, address teamRecipient) internal pure {
        uint256 total = allocation.coinStakingRewards + allocation.timelockTreasuryVested + allocation.timelockImmediate
            + allocation.teamVesting + allocation.monolithVesting;
        if (total != BPS) revert InvalidAllocationTotal(total);
        if (allocation.teamVesting > 2_000) revert TeamAllocationExceedsMaximum(allocation.teamVesting);
        if (allocation.teamVesting > 0 && teamRecipient == address(0)) revert ZeroAddress();
    }

    function _fundAllocations(
        GovToken govToken,
        uint256 supply,
        AllocationBps memory allocation,
        address timelock,
        address timelockVesting,
        address teamVesting,
        address monolithVesting,
        address coinStakingRewards
    ) internal {
        uint256 coinStakingAmount = _amountFor(supply, allocation.coinStakingRewards);
        uint256 timelockVestedAmount = _amountFor(supply, allocation.timelockTreasuryVested);
        uint256 timelockImmediateAmount = _amountFor(supply, allocation.timelockImmediate);
        uint256 teamVestingAmount = _amountFor(supply, allocation.teamVesting);
        uint256 monolithVestingAmount = _amountFor(supply, allocation.monolithVesting);

        IERC20 token = IERC20(address(govToken));
        token.safeTransfer(coinStakingRewards, coinStakingAmount);
        token.safeTransfer(timelockVesting, timelockVestedAmount);
        token.safeTransfer(timelock, timelockImmediateAmount);
        if (teamVestingAmount > 0) token.safeTransfer(teamVesting, teamVestingAmount);
        token.safeTransfer(monolithVesting, monolithVestingAmount);

        uint256 remainder = token.balanceOf(address(this));
        if (remainder > 0) token.safeTransfer(timelock, remainder);
    }

    function _amountFor(uint256 supply, uint16 allocationBps) internal pure returns (uint256) {
        return (supply * allocationBps) / BPS;
    }
}
