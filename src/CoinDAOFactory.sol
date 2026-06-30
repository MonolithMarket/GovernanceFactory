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
    uint256 public constant COIN_STAKING_REWARD_DURATION = FOUR_YEARS;

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
        address coinStakingRewards
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

        (address lender, address coin, address vault) = monolithFactory.deploy(monolithParams);
        if (lender == address(0) || coin == address(0) || vault == address(0)) revert ZeroAddress();

        AllocationAmounts memory allocation = allocationFor(params.deployerStakeBps);

        // Deploy GOV, the timelock, staking, and the governor that will control the launch.
        GovToken govToken = new GovToken(params.govTokenName, params.govTokenSymbol, address(this));

        address[] memory proposers = new address[](0);
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        TimelockController timelock =
            new TimelockController(DEFAULT_TIMELOCK_DELAY, proposers, executors, address(this));

        UniStaker staker = new UniStaker(IERC20(coin), IERC20Delegates(address(govToken)), address(this));

        uint256 proposalThreshold = GOV_TOKEN_SUPPLY / 1_000;
        string memory governorName = string.concat(params.govTokenName, " Governor");
        CoinDAOGovernor governor =
            new CoinDAOGovernor(governorName, IVotes(address(govToken)), timelock, proposalThreshold);

        // Move governance authority from the factory to the governor/timelock pair.
        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(governor));
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), address(this));

        address stakingToken = params.stakingTokenChoice == StakingTokenChoice.Coin ? coin : vault;
        StakingRewards coinStakingRewards =
            new StakingRewards(stakingToken, address(govToken), address(this), COIN_STAKING_REWARD_DURATION);

        RevenueRouter revenueRouter =
            new RevenueRouter(lender, coin, address(timelock), address(staker), DEFAULT_GOV_STAKING_BPS, address(this));

        // Route lender revenue through the staker while leaving future management under timelock control.
        IMonolithLender(lender).setPendingOperator(address(revenueRouter));
        revenueRouter.acceptLenderOperator();
        revenueRouter.transferOwnership(address(timelock));
        staker.setRewardNotifier(address(revenueRouter), true);
        staker.setAdmin(address(timelock));

        // Prepare vesting recipients before distributing the fixed GOV supply.
        VestingWallet treasuryVesting = new VestingWallet(address(timelock), uint64(block.timestamp), FOUR_YEARS);
        VestingWallet monolithVesting = new VestingWallet(params.monolithRecipient, uint64(block.timestamp), FOUR_YEARS);
        VestingWallet deployerVesting;
        if (allocation.deployerVesting != 0) {
            deployerVesting = new VestingWallet(params.deployerRecipient, uint64(block.timestamp), FOUR_YEARS);
        }

        IERC20 govTokenErc20 = IERC20(address(govToken));
        govTokenErc20.safeTransfer(address(coinStakingRewards), allocation.coinStakingRewards);
        coinStakingRewards.notifyRewardAmount(allocation.coinStakingRewards);
        coinStakingRewards.setRewardsDistribution(address(timelock));
        coinStakingRewards.transferOwnership(address(timelock));

        // Fund the remaining allocations; the treasury receives liquid GOV plus its vesting wallet.
        govTokenErc20.safeTransfer(address(timelock), allocation.immediateTreasuryAllocation);
        govTokenErc20.safeTransfer(address(treasuryVesting), allocation.treasuryVested);
        govTokenErc20.safeTransfer(address(monolithVesting), allocation.monolithVesting);
        if (allocation.deployerVesting != 0) {
            govTokenErc20.safeTransfer(address(deployerVesting), allocation.deployerVesting);
        }

        // Store and emit the deployment map for callers and indexers.
        deployment = Deployment({
            govToken: address(govToken),
            staker: address(staker),
            governor: address(governor),
            timelock: address(timelock),
            monolithFactory: address(monolithFactory),
            lender: lender,
            coin: coin,
            vault: vault,
            stakingToken: stakingToken,
            revenueRouter: address(revenueRouter),
            coinStakingRewards: address(coinStakingRewards),
            treasuryVesting: address(treasuryVesting),
            monolithVesting: address(monolithVesting),
            deployerVesting: address(deployerVesting)
        });

        _deployments.push(deployment);
        emit CoinDAODeployed(
            _deployments.length - 1,
            lender,
            coin,
            address(monolithFactory),
            vault,
            address(govToken),
            address(staker),
            address(governor),
            address(timelock),
            address(revenueRouter),
            address(coinStakingRewards)
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
