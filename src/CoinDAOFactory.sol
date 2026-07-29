// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {VestingWallet} from "@openzeppelin/contracts/finance/VestingWallet.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {RLP} from "@openzeppelin/contracts/utils/RLP.sol";

import {CoinDAOGovernor} from "./CoinDAOGovernor.sol";
import {GOV_TOKEN_SUPPLY as FIXED_GOV_TOKEN_SUPPLY, GovToken} from "./GovToken.sol";
import {RevenueRouter} from "./RevenueRouter.sol";
import {StakedGovToken} from "./StakedGovToken.sol";
import {StakingRewards} from "./StakingRewards.sol";
import {StakingRewardsFunder} from "./StakingRewardsFunder.sol";
import {
    CoreDeploymentLib,
    GovernorDeploymentLib,
    RewardsDeploymentLib,
    StakingDeploymentLib
} from "./deployment/DeploymentLibraries.sol";
import {IMonolithFactory, IMonolithLender} from "./interfaces/IMonolith.sol";

contract CoinDAOFactory {
    using SafeERC20 for IERC20;
    using RLP for *;

    uint16 public constant BPS = 10_000;
    uint16 public constant MAX_DEPLOYER_STAKE_BPS = 2_000;
    uint16 public constant MONOLITH_BPS = 200;
    uint16 public constant IMMEDIATE_TREASURY_ALLOCATION = 1_000;
    uint16 public constant BASE_REWARDS_BPS = 6_666;
    uint16 public constant DEFAULT_GOV_STAKING_BPS = 10_000;
    uint256 public constant GOV_TOKEN_SUPPLY = FIXED_GOV_TOKEN_SUPPLY;
    uint256 public constant GOVERNOR_PROPOSAL_THRESHOLD = GOV_TOKEN_SUPPLY / 1_000;
    uint256 public constant GOVERNOR_QUORUM = GOV_TOKEN_SUPPLY / 100;

    uint64 public constant FOUR_YEARS = 365 days * 4;
    uint256 public constant DEFAULT_TIMELOCK_DELAY = 2 days;
    uint256 public constant COIN_STAKING_REWARD_DURATION = 365 days;
    uint256 public constant GOV_STAKING_REWARD_DURATION = 30 days;

    IMonolithFactory public immutable monolithFactory;
    uint256 private _nextCreateNonce = 1;

    enum StakingTokenChoice {
        Coin,
        SCoin
    }

    struct GovLaunchParams {
        string govTokenName;
        string govTokenSymbol;
        uint16 deployerStakeBps;
        address deployerRecipient;
        address monolithRecipient;
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

    Deployment[] public deployments;
    mapping(address lender => bool) public hasCoinDAO;

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
    event CoinDAOAttached(uint256 indexed id, address indexed lender, address indexed previousOperator);

    error ZeroAddress();
    error DeployerStakeExceedsMaximum(uint16 deployerStakeBps);
    error DeployerRecipientRequired();
    error PredictedRevenueRouterMismatch(address predicted, address actual);
    error UnrecognizedLender(address lender);
    error CoinDAOAlreadyExists(address lender);
    error CallerNotLenderOperator(address caller, address operator);
    error FactoryNotPendingOperator(address pendingOperator);

    constructor(IMonolithFactory monolithFactory_) {
        if (address(monolithFactory_) == address(0)) revert ZeroAddress();
        monolithFactory = monolithFactory_;
    }

    function deploymentsLength() external view returns (uint256) {
        return deployments.length;
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

    function deploy(
        GovLaunchParams calldata govParams,
        IMonolithFactory.DeployParams calldata monolithParams_,
        address manager
    ) external returns (Deployment memory deployment) {
        if (manager == address(0)) revert ZeroAddress();
        _validate(govParams);

        // Deploy the Monolith market first; every downstream contract wires against these addresses.
        IMonolithFactory.DeployParams memory monolithParams = monolithParams_;
        monolithParams.operator = address(this);
        monolithParams.manager = manager;

        (deployment.lender, deployment.coin, deployment.vault) = monolithFactory.deploy(monolithParams);
        if (deployment.lender == address(0) || deployment.coin == address(0) || deployment.vault == address(0)) {
            revert ZeroAddress();
        }

        deployment = _deployCoinDAO(deployment, govParams);
    }

    function deployForExistingCoin(GovLaunchParams calldata govParams, address lenderAddress)
        external
        returns (Deployment memory deployment)
    {
        _validate(govParams);

        if (lenderAddress == address(0)) revert ZeroAddress();
        if (!monolithFactory.isDeployed(lenderAddress)) revert UnrecognizedLender(lenderAddress);
        if (hasCoinDAO[lenderAddress]) revert CoinDAOAlreadyExists(lenderAddress);

        IMonolithLender lender = IMonolithLender(lenderAddress);
        address previousOperator = lender.operator();
        if (msg.sender != previousOperator) revert CallerNotLenderOperator(msg.sender, previousOperator);

        address pendingOperator = lender.pendingOperator();
        if (pendingOperator != address(this)) revert FactoryNotPendingOperator(pendingOperator);

        deployment.lender = lenderAddress;
        deployment.coin = lender.coin();
        deployment.vault = lender.vault();

        // The current operator has explicitly nominated this factory. Accepting
        // here makes the complete factory -> RevenueRouter handoff atomic.
        lender.acceptOperator();

        deployment = _deployCoinDAO(deployment, govParams);

        emit CoinDAOAttached(deployments.length - 1, lenderAddress, previousOperator);
    }

    function _deployCoinDAO(Deployment memory deployment, GovLaunchParams memory params)
        internal
        returns (Deployment memory)
    {
        if (hasCoinDAO[deployment.lender]) revert CoinDAOAlreadyExists(deployment.lender);
        hasCoinDAO[deployment.lender] = true;

        AllocationAmounts memory allocation = allocationFor(params.deployerStakeBps);

        // Deploy GOV, the timelock, staking, and the governor that will control the launch.
        GovToken govToken =
            GovToken(CoreDeploymentLib.deployGovToken(params.govTokenName, params.govTokenSymbol, address(this)));
        _recordCreate();
        deployment.govToken = address(govToken);

        address[] memory proposers = new address[](0);
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        TimelockController timelock = TimelockController(
            payable(CoreDeploymentLib.deployTimelock(DEFAULT_TIMELOCK_DELAY, proposers, executors, address(this)))
        );
        _recordCreate();
        deployment.timelock = address(timelock);

        address predictedRevenueRouter = _predictCreateAddress(1);
        StakedGovToken staker = StakedGovToken(
            StakingDeploymentLib.deployStakedGovToken(
                IERC20(deployment.govToken),
                IERC20(deployment.coin),
                string.concat("Staked ", params.govTokenName),
                string.concat("s", params.govTokenSymbol),
                predictedRevenueRouter,
                GOV_STAKING_REWARD_DURATION
            )
        );
        _recordCreate();
        deployment.staker = address(staker);

        RevenueRouter revenueRouter = RevenueRouter(
            StakingDeploymentLib.deployRevenueRouter(
                deployment.lender,
                deployment.coin,
                deployment.timelock,
                deployment.staker,
                DEFAULT_GOV_STAKING_BPS,
                address(this)
            )
        );
        _recordCreate();
        deployment.revenueRouter = address(revenueRouter);
        if (deployment.revenueRouter != predictedRevenueRouter) {
            revert PredictedRevenueRouterMismatch(predictedRevenueRouter, deployment.revenueRouter);
        }

        string memory governorName = string.concat(params.govTokenName, " Governor");
        CoinDAOGovernor governor = CoinDAOGovernor(
            payable(GovernorDeploymentLib.deployGovernor(
                    governorName, IVotes(address(staker)), timelock, GOVERNOR_PROPOSAL_THRESHOLD, GOVERNOR_QUORUM
                ))
        );
        _recordCreate();
        deployment.governor = address(governor);

        // Move governance authority from the factory to the governor/timelock pair.
        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(governor));
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), address(this));

        address stakingToken = params.stakingTokenChoice == StakingTokenChoice.Coin ? deployment.coin : deployment.vault;
        deployment.stakingToken = stakingToken;
        StakingRewards coinStakingRewards = StakingRewards(
            RewardsDeploymentLib.deployStakingRewards(
                stakingToken, address(govToken), address(this), COIN_STAKING_REWARD_DURATION
            )
        );
        _recordCreate();
        deployment.coinStakingRewards = address(coinStakingRewards);
        StakingRewardsFunder coinStakingRewardsFunder = StakingRewardsFunder(
            RewardsDeploymentLib.deployStakingRewardsFunder(coinStakingRewards, allocation.coinStakingRewards)
        );
        _recordCreate();
        deployment.coinStakingRewardsFunder = address(coinStakingRewardsFunder);

        // Route lender revenue through the staker while leaving future management under timelock control.
        IMonolithLender(deployment.lender).setPendingOperator(deployment.revenueRouter);
        revenueRouter.acceptLenderOperator();
        revenueRouter.transferOwnership(deployment.timelock);

        // Prepare vesting recipients before distributing the fixed GOV supply.
        VestingWallet treasuryVesting = VestingWallet(
            payable(CoreDeploymentLib.deployVestingWallet(deployment.timelock, uint64(block.timestamp), FOUR_YEARS))
        );
        _recordCreate();
        deployment.treasuryVesting = address(treasuryVesting);
        VestingWallet monolithVesting = VestingWallet(
            payable(CoreDeploymentLib.deployVestingWallet(
                    params.monolithRecipient, uint64(block.timestamp), FOUR_YEARS
                ))
        );
        _recordCreate();
        deployment.monolithVesting = address(monolithVesting);
        VestingWallet deployerVesting;
        if (allocation.deployerVesting != 0) {
            deployerVesting = VestingWallet(
                payable(CoreDeploymentLib.deployVestingWallet(
                        params.deployerRecipient, uint64(block.timestamp), FOUR_YEARS
                    ))
            );
            _recordCreate();
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
        deployments.push(deployment);
        emit CoinDAODeployed(
            deployments.length - 1,
            deployment.lender,
            deployment.coin,
            address(monolithFactory),
            deployment.vault,
            deployment.govToken,
            deployment.staker,
            deployment.governor,
            deployment.timelock,
            deployment.revenueRouter,
            deployment.coinStakingRewards,
            deployment.coinStakingRewardsFunder
        );

        return deployment;
    }

    function _validate(GovLaunchParams calldata params) internal pure {
        if (params.monolithRecipient == address(0)) revert ZeroAddress();
        if (params.deployerStakeBps > MAX_DEPLOYER_STAKE_BPS) {
            revert DeployerStakeExceedsMaximum(params.deployerStakeBps);
        }
        if (params.deployerStakeBps != 0 && params.deployerRecipient == address(0)) {
            revert DeployerRecipientRequired();
        }
    }

    function _predictCreateAddress(uint256 offset) internal view returns (address) {
        bytes memory rlp = RLP.encoder().push(address(this)).push(_nextCreateNonce + offset).encode();
        return address(uint160(uint256(keccak256(rlp))));
    }

    function _recordCreate() internal {
        ++_nextCreateNonce;
    }
}
