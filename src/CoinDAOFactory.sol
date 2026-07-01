// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {VestingWallet} from "@openzeppelin/contracts/finance/VestingWallet.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import {CoinDAOGovernor} from "./CoinDAOGovernor.sol";
import {GOV_TOKEN_SUPPLY as FIXED_GOV_TOKEN_SUPPLY, GovToken} from "./GovToken.sol";
import {RevenueRouter} from "./RevenueRouter.sol";
import {UniStaker} from "./UniStaker.sol";
import {IERC20Delegates} from "./interfaces/IERC20Delegates.sol";
import {StakingRewards} from "./StakingRewards.sol";
import {StakingRewardsFunder} from "./StakingRewardsFunder.sol";
import {IMonolithFactory, IMonolithLender} from "./interfaces/IMonolith.sol";

contract CoinDAOFactory {
    using SafeERC20 for IERC20;

    uint16 public constant BPS = 10_000;
    uint16 public constant MAX_DEPLOYER_STAKE_BPS = 2_000;
    uint16 public constant MONOLITH_BPS = 200;
    uint16 public constant IMMEDIATE_TREASURY_ALLOCATION = 1_000;
    uint16 public constant BASE_REWARDS_BPS = 6_666;
    uint16 public constant DEFAULT_GOV_STAKING_BPS = 10_000;
    uint256 public constant GOV_TOKEN_SUPPLY = FIXED_GOV_TOKEN_SUPPLY;

    uint64 public constant FOUR_YEARS = 365 days * 4;
    uint256 public constant DEFAULT_TIMELOCK_DELAY = 2 days;
    uint256 public constant COIN_STAKING_REWARD_DURATION = 365 days;

    IMonolithFactory public immutable monolithFactory;

    enum StakingTokenChoice {
        Coin,
        SCoin
    }

    struct LaunchParams {
        string govTokenName;
        string govTokenSymbol;
        IMonolithFactory.DeployParams monolithParams;
        uint16 deployerStakeBps;
        address deployerRecipient;
        address monolithRecipient;
        address manager;
        StakingTokenChoice stakingTokenChoice;
    }

    struct AllocationAmounts {
        uint256 coinStakingRewards;
        uint256 treasuryVested;
        uint256 immediateTreasuryAllocation;
        uint256 monolithVesting;
        uint256 deployerVesting;
    }

    struct Deployment {
        address govToken;
        address staker;
        address governor;
        address timelock;
        address monolithFactory;
        address lender;
        address coin;
        address vault;
        address stakingToken;
        address revenueRouter;
        address coinStakingRewards;
        address coinStakingRewardsFunder;
        address treasuryVesting;
        address monolithVesting;
        address deployerVesting;
    }

    Deployment[] private _deployments;

    event CoinDAODeployed(
        uint256 indexed id,
        address indexed lender,
        address indexed coin,
        address monolithFactory,
        address vault,
        address govToken,
        address staker,
        address governor,
        address timelock,
        address revenueRouter,
        address coinStakingRewards,
        address coinStakingRewardsFunder
    );

    error ZeroAddress();
    error DeployerStakeExceedsMaximum(uint16 deployerStakeBps);
    error DeployerRecipientRequired();

    constructor(IMonolithFactory monolithFactory_) {
        if (address(monolithFactory_) == address(0)) revert ZeroAddress();
        monolithFactory = monolithFactory_;
    }

    function deploymentsLength() external view returns (uint256) {
        return _deployments.length;
    }

    function deployments(uint256 id) external view returns (Deployment memory) {
        return _deployments[id];
    }

    function allocationFor(uint16 deployerStakeBps) public pure returns (AllocationAmounts memory allocation) {
        if (deployerStakeBps > MAX_DEPLOYER_STAKE_BPS) revert DeployerStakeExceedsMaximum(deployerStakeBps);

        uint256 totalSupply = GOV_TOKEN_SUPPLY;
        allocation.monolithVesting = (totalSupply * MONOLITH_BPS) / uint256(BPS);
        allocation.deployerVesting = (totalSupply * deployerStakeBps) / uint256(BPS);
        uint256 remainingAllocation = totalSupply - allocation.monolithVesting - allocation.deployerVesting;
        allocation.coinStakingRewards = (remainingAllocation * BASE_REWARDS_BPS) / uint256(BPS);
        uint256 treasuryAllocation = remainingAllocation - allocation.coinStakingRewards;
        allocation.immediateTreasuryAllocation =
            treasuryAllocation * uint256(IMMEDIATE_TREASURY_ALLOCATION) / uint256(BPS);
        allocation.treasuryVested = treasuryAllocation - allocation.immediateTreasuryAllocation;
    }

    function deploy(LaunchParams calldata params) external returns (Deployment memory deployment) {
        _validate(params);

        // Deploy the Monolith market first; every downstream contract wires against these addresses.
        IMonolithFactory.DeployParams memory monolithParams = params.monolithParams;
        monolithParams.operator = address(this);
        monolithParams.manager = params.manager;

        (deployment.lender, deployment.coin, deployment.vault) = monolithFactory.deploy(monolithParams);
        if (deployment.lender == address(0) || deployment.coin == address(0) || deployment.vault == address(0)) {
            revert ZeroAddress();
        }
        deployment.monolithFactory = address(monolithFactory);

        AllocationAmounts memory allocation = allocationFor(params.deployerStakeBps);

        // Deploy GOV, the timelock, staking, and the governor that will control the launch.
        GovToken govToken = new GovToken(params.govTokenName, params.govTokenSymbol, address(this));
        deployment.govToken = address(govToken);

        address[] memory proposers = new address[](0);
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        TimelockController timelock =
            new TimelockController(DEFAULT_TIMELOCK_DELAY, proposers, executors, address(this));
        deployment.timelock = address(timelock);

        UniStaker staker = new UniStaker(IERC20(deployment.coin), IERC20Delegates(deployment.govToken), address(this));
        deployment.staker = address(staker);

        uint256 proposalThreshold = GOV_TOKEN_SUPPLY / 1_000;
        string memory governorName = string.concat(params.govTokenName, " Governor");
        CoinDAOGovernor governor =
            new CoinDAOGovernor(governorName, IVotes(address(govToken)), timelock, proposalThreshold);
        deployment.governor = address(governor);

        // Move governance authority from the factory to the governor/timelock pair.
        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(governor));
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), address(this));

        address stakingToken = params.stakingTokenChoice == StakingTokenChoice.Coin ? deployment.coin : deployment.vault;
        deployment.stakingToken = stakingToken;
        StakingRewards coinStakingRewards =
            new StakingRewards(stakingToken, address(govToken), address(this), COIN_STAKING_REWARD_DURATION);
        deployment.coinStakingRewards = address(coinStakingRewards);
        StakingRewardsFunder coinStakingRewardsFunder =
            new StakingRewardsFunder(coinStakingRewards, allocation.coinStakingRewards);
        deployment.coinStakingRewardsFunder = address(coinStakingRewardsFunder);

        RevenueRouter revenueRouter = new RevenueRouter(
            deployment.lender,
            deployment.coin,
            deployment.timelock,
            deployment.staker,
            DEFAULT_GOV_STAKING_BPS,
            address(this)
        );
        deployment.revenueRouter = address(revenueRouter);

        // Route lender revenue through the staker while leaving future management under timelock control.
        IMonolithLender(deployment.lender).setPendingOperator(deployment.revenueRouter);
        revenueRouter.acceptLenderOperator();
        revenueRouter.transferOwnership(deployment.timelock);
        staker.setRewardNotifier(deployment.revenueRouter, true);
        staker.setAdmin(deployment.timelock);

        // Prepare vesting recipients before distributing the fixed GOV supply.
        VestingWallet treasuryVesting = new VestingWallet(deployment.timelock, uint64(block.timestamp), FOUR_YEARS);
        deployment.treasuryVesting = address(treasuryVesting);
        VestingWallet monolithVesting = new VestingWallet(params.monolithRecipient, uint64(block.timestamp), FOUR_YEARS);
        deployment.monolithVesting = address(monolithVesting);
        VestingWallet deployerVesting;
        if (allocation.deployerVesting != 0) {
            deployerVesting = new VestingWallet(params.deployerRecipient, uint64(block.timestamp), FOUR_YEARS);
            deployment.deployerVesting = address(deployerVesting);
        }

        IERC20 govTokenErc20 = IERC20(address(govToken));
        govTokenErc20.safeTransfer(address(coinStakingRewardsFunder), allocation.coinStakingRewards);
        coinStakingRewards.setRewardsDistribution(address(coinStakingRewardsFunder));
        coinStakingRewardsFunder.fundNextTranche();
        coinStakingRewards.renounceOwnership();

        // Fund the remaining allocations; the treasury receives liquid GOV plus its vesting wallet.
        govTokenErc20.safeTransfer(address(timelock), allocation.immediateTreasuryAllocation);
        govTokenErc20.safeTransfer(address(treasuryVesting), allocation.treasuryVested);
        govTokenErc20.safeTransfer(address(monolithVesting), allocation.monolithVesting);
        if (allocation.deployerVesting != 0) {
            govTokenErc20.safeTransfer(address(deployerVesting), allocation.deployerVesting);
        }

        // Store and emit the deployment map for callers and indexers.
        _deployments.push(deployment);
        emit CoinDAODeployed(
            _deployments.length - 1,
            deployment.lender,
            deployment.coin,
            deployment.monolithFactory,
            deployment.vault,
            deployment.govToken,
            deployment.staker,
            deployment.governor,
            deployment.timelock,
            deployment.revenueRouter,
            deployment.coinStakingRewards,
            deployment.coinStakingRewardsFunder
        );
    }

    function _validate(LaunchParams calldata params) internal pure {
        if (params.monolithRecipient == address(0) || params.manager == address(0)) {
            revert ZeroAddress();
        }
        if (params.deployerStakeBps > MAX_DEPLOYER_STAKE_BPS) {
            revert DeployerStakeExceedsMaximum(params.deployerStakeBps);
        }
        if (params.deployerStakeBps != 0 && params.deployerRecipient == address(0)) revert DeployerRecipientRequired();
    }
}
