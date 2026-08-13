pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

import {CoinDAOVestingWallet} from "./CoinDAOVestingWallet.sol";
import {CoinDAOGovernor} from "./CoinDAOGovernor.sol";
import {GOV_TOKEN_SUPPLY as FIXED_GOV_TOKEN_SUPPLY, GovToken} from "./GovToken.sol";
import {RevenueRouter} from "./RevenueRouter.sol";
import {StakedGovToken} from "./StakedGovToken.sol";
import {StakingRewards} from "./StakingRewards.sol";
import {StakingRewardsFunder} from "./StakingRewardsFunder.sol";
import {CoreDeploymentLib, GovernorDeploymentLib} from "./deployment/DeploymentLibraries.sol";
import {IImplementation} from "./interfaces/IImplementation.sol";
import {IMonolithFactory, IMonolithLender} from "./interfaces/IMonolith.sol";

contract CoinDAOFactory {
    using SafeERC20 for IERC20;

    uint16 public constant BPS = 10_000;
    uint16 public constant MAX_DEPLOYER_STAKE_BPS = 2_000;
    uint16 public constant MONOLITH_BPS = 200;
    uint16 public constant ALLOCATION_WEIGHT_TOTAL = 9_800;
    uint16 public constant COIN_STAKING_REWARDS_WEIGHT = 6_500;
    uint16 public constant IMMEDIATE_ALLOCATION_WEIGHT = 500;
    uint16 public constant VESTED_TREASURY_WEIGHT = 2_800;
    uint16 public constant DEFAULT_GOV_STAKING_BPS = 10_000;
    uint256 public constant GOV_TOKEN_SUPPLY = FIXED_GOV_TOKEN_SUPPLY;
    uint256 public constant GOVERNOR_PROPOSAL_THRESHOLD = GOV_TOKEN_SUPPLY / 1_000;
    uint256 public constant GOVERNOR_QUORUM_NUMERATOR = 1;

    uint64 public constant FOUR_YEARS = 365 days * 4;
    uint256 public constant DEFAULT_TIMELOCK_DELAY = 2 days;
    uint256 public constant COIN_STAKING_REWARD_DURATION = 365 days;
    uint256 public constant GOV_STAKING_REWARD_DURATION = 7 days;

    bytes32 public constant GOV_TOKEN_IMPLEMENTATION_ID = keccak256("MonolithCoinDAO.GovToken.v1");
    bytes32 public constant STAKED_GOV_TOKEN_IMPLEMENTATION_ID = keccak256("MonolithCoinDAO.StakedGovToken.v1");
    bytes32 public constant REVENUE_ROUTER_IMPLEMENTATION_ID = keccak256("MonolithCoinDAO.RevenueRouter.v1");
    bytes32 public constant STAKING_REWARDS_IMPLEMENTATION_ID = keccak256("MonolithCoinDAO.StakingRewards.v1");
    bytes32 public constant STAKING_REWARDS_FUNDER_IMPLEMENTATION_ID =
        keccak256("MonolithCoinDAO.StakingRewardsFunder.v1");
    bytes32 public constant VESTING_WALLET_IMPLEMENTATION_ID = keccak256("MonolithCoinDAO.VestingWallet.v1");

    bytes32 internal constant _GOV_TOKEN_COMPONENT = keccak256("GOV_TOKEN");
    bytes32 internal constant _TIMELOCK_COMPONENT = keccak256("TIMELOCK");
    bytes32 internal constant _STAKER_COMPONENT = keccak256("STAKER");
    bytes32 internal constant _REVENUE_ROUTER_COMPONENT = keccak256("REVENUE_ROUTER");
    bytes32 internal constant _GOVERNOR_COMPONENT = keccak256("GOVERNOR");
    bytes32 internal constant _STAKING_REWARDS_COMPONENT = keccak256("STAKING_REWARDS");
    bytes32 internal constant _STAKING_REWARDS_FUNDER_COMPONENT = keccak256("STAKING_REWARDS_FUNDER");
    bytes32 internal constant _TREASURY_VESTING_COMPONENT = keccak256("TREASURY_VESTING");
    bytes32 internal constant _MONOLITH_VESTING_COMPONENT = keccak256("MONOLITH_VESTING");
    bytes32 internal constant _DEPLOYER_VESTING_COMPONENT = keccak256("DEPLOYER_VESTING");

    IMonolithFactory public immutable monolithFactory;
    address public immutable govTokenImplementation;
    address public immutable stakedGovTokenImplementation;
    address public immutable revenueRouterImplementation;
    address public immutable stakingRewardsImplementation;
    address public immutable stakingRewardsFunderImplementation;
    address public immutable vestingWalletImplementation;
    address public monolithBeneficiary;
    address public pendingMonolithBeneficiary;

    enum StakingTokenChoice {
        Coin,
        SCoin
    }

    struct GovLaunchParams {
        string govTokenName;
        string govTokenSymbol;
        uint16 deployerStakeBps;
        address deployerRecipient;
        StakingTokenChoice stakingTokenChoice;
    }

    struct Implementations {
        address govToken;
        address stakedGovToken;
        address revenueRouter;
        address stakingRewards;
        address stakingRewardsFunder;
        address vestingWallet;
    }

    struct PredictedAddresses {
        address govToken;
        address staker;
        address governor;
        address timelock;
        address revenueRouter;
        address coinStakingRewards;
        address coinStakingRewardsFunder;
        address treasuryVesting;
        address monolithVesting;
        address deployerVesting;
    }

    struct AllocationAmounts {
        uint256 coinStakingRewards;
        uint256 treasuryVested;
        uint256 immediateAllocation;
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
    bytes32[] public deploymentKeyForId;
    mapping(address lender => bool) public hasCoinDAO;
    mapping(bytes32 deploymentKey => bool) public usedDeploymentKeys;

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
    event DeploymentKeyUsed(
        uint256 indexed id, bytes32 indexed deploymentKey, address indexed creator, bytes32 userSalt
    );
    event MonolithBeneficiaryTransferStarted(address indexed currentBeneficiary, address indexed pendingBeneficiary);
    event MonolithBeneficiaryTransferred(address indexed previousBeneficiary, address indexed newBeneficiary);

    error ZeroAddress();
    error DeployerStakeExceedsMaximum(uint16 deployerStakeBps);
    error DeployerRecipientRequired();
    error UnrecognizedLender(address lender);
    error CoinDAOAlreadyExists(address lender);
    error CallerNotLenderOperator(address caller, address operator);
    error FactoryNotPendingOperator(address pendingOperator);
    error CallerNotMonolithBeneficiary(address caller, address beneficiary);
    error CallerNotPendingMonolithBeneficiary(address caller, address pendingBeneficiary);
    error InvalidImplementation(bytes32 implementationId, address implementation);
    error DuplicateImplementation(address implementation);
    error DeploymentKeyAlreadyUsed(bytes32 deploymentKey);

    constructor(
        IMonolithFactory monolithFactory_,
        address monolithBeneficiary_,
        Implementations memory implementations_
    ) {
        if (address(monolithFactory_) == address(0) || monolithBeneficiary_ == address(0)) revert ZeroAddress();
        _validateImplementations(implementations_);

        monolithFactory = monolithFactory_;
        govTokenImplementation = implementations_.govToken;
        stakedGovTokenImplementation = implementations_.stakedGovToken;
        revenueRouterImplementation = implementations_.revenueRouter;
        stakingRewardsImplementation = implementations_.stakingRewards;
        stakingRewardsFunderImplementation = implementations_.stakingRewardsFunder;
        vestingWalletImplementation = implementations_.vestingWallet;
        monolithBeneficiary = monolithBeneficiary_;
    }

    function implementations() external view returns (Implementations memory) {
        return Implementations({
            govToken: govTokenImplementation,
            stakedGovToken: stakedGovTokenImplementation,
            revenueRouter: revenueRouterImplementation,
            stakingRewards: stakingRewardsImplementation,
            stakingRewardsFunder: stakingRewardsFunderImplementation,
            vestingWallet: vestingWalletImplementation
        });
    }

    function deploymentsLength() external view returns (uint256) {
        return deployments.length;
    }

    function deploymentKey(address creator, bytes32 userSalt) public pure returns (bytes32) {
        return keccak256(abi.encode(creator, userSalt));
    }

    function predictCoinDAOAddresses(address creator, bytes32 userSalt, GovLaunchParams calldata govParams)
        external
        view
        returns (PredictedAddresses memory predicted)
    {
        bytes32 key = deploymentKey(creator, userSalt);
        predicted.govToken = Clones.predictDeterministicAddress(
            govTokenImplementation, _componentSalt(key, _GOV_TOKEN_COMPONENT), address(this)
        );

        address[] memory proposers = new address[](0);
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        bytes32 timelockHash =
            CoreDeploymentLib.timelockInitCodeHash(DEFAULT_TIMELOCK_DELAY, proposers, executors, address(this));
        predicted.timelock =
            Create2.computeAddress(_componentSalt(key, _TIMELOCK_COMPONENT), timelockHash, address(this));

        predicted.staker = Clones.predictDeterministicAddress(
            stakedGovTokenImplementation, _componentSalt(key, _STAKER_COMPONENT), address(this)
        );
        predicted.revenueRouter = Clones.predictDeterministicAddress(
            revenueRouterImplementation, _componentSalt(key, _REVENUE_ROUTER_COMPONENT), address(this)
        );

        string memory governorName = string.concat(govParams.govTokenName, " Governor");
        bytes32 governorHash = GovernorDeploymentLib.governorInitCodeHash(
            governorName,
            IVotes(predicted.staker),
            TimelockController(payable(predicted.timelock)),
            GOVERNOR_PROPOSAL_THRESHOLD,
            GOVERNOR_QUORUM_NUMERATOR
        );
        predicted.governor =
            Create2.computeAddress(_componentSalt(key, _GOVERNOR_COMPONENT), governorHash, address(this));

        predicted.coinStakingRewards = Clones.predictDeterministicAddress(
            stakingRewardsImplementation, _componentSalt(key, _STAKING_REWARDS_COMPONENT), address(this)
        );
        predicted.coinStakingRewardsFunder = Clones.predictDeterministicAddress(
            stakingRewardsFunderImplementation, _componentSalt(key, _STAKING_REWARDS_FUNDER_COMPONENT), address(this)
        );
        predicted.treasuryVesting = Clones.predictDeterministicAddress(
            vestingWalletImplementation, _componentSalt(key, _TREASURY_VESTING_COMPONENT), address(this)
        );
        predicted.monolithVesting = Clones.predictDeterministicAddress(
            vestingWalletImplementation, _componentSalt(key, _MONOLITH_VESTING_COMPONENT), address(this)
        );
        predicted.deployerVesting = Clones.predictDeterministicAddress(
            vestingWalletImplementation, _componentSalt(key, _DEPLOYER_VESTING_COMPONENT), address(this)
        );
    }

    function setPendingMonolithBeneficiary(address pendingBeneficiary) external {
        address currentBeneficiary = monolithBeneficiary;
        if (msg.sender != currentBeneficiary) {
            revert CallerNotMonolithBeneficiary(msg.sender, currentBeneficiary);
        }
        if (pendingBeneficiary == address(0)) revert ZeroAddress();

        pendingMonolithBeneficiary = pendingBeneficiary;
        emit MonolithBeneficiaryTransferStarted(currentBeneficiary, pendingBeneficiary);
    }

    function acceptMonolithBeneficiary() external {
        address pendingBeneficiary = pendingMonolithBeneficiary;
        if (msg.sender != pendingBeneficiary) {
            revert CallerNotPendingMonolithBeneficiary(msg.sender, pendingBeneficiary);
        }

        address previousBeneficiary = monolithBeneficiary;
        monolithBeneficiary = pendingBeneficiary;
        pendingMonolithBeneficiary = address(0);
        emit MonolithBeneficiaryTransferred(previousBeneficiary, pendingBeneficiary);
    }

    function allocationFor(uint16 deployerStakeBps) public pure returns (AllocationAmounts memory allocation) {
        if (deployerStakeBps > MAX_DEPLOYER_STAKE_BPS) revert DeployerStakeExceedsMaximum(deployerStakeBps);

        uint256 totalSupply = GOV_TOKEN_SUPPLY;
        // Monolith beneficiary always receives 2%, vesting over 4 years.
        allocation.monolithVesting = (totalSupply * MONOLITH_BPS) / uint256(BPS);
        // Deployer vesting receives up to 20% of supply over 4 years.
        allocation.deployerVesting = (totalSupply * deployerStakeBps) / uint256(BPS);
        // The remainder is split using a 65:5:28 staking/immediate/vested-treasury ratio.
        // Increasing the deployer stake proportionally reduces all three of those allocations.
        uint256 remainingAllocation = totalSupply - allocation.monolithVesting - allocation.deployerVesting;
        allocation.coinStakingRewards =
            (remainingAllocation * COIN_STAKING_REWARDS_WEIGHT) / uint256(ALLOCATION_WEIGHT_TOTAL);
        allocation.immediateAllocation =
            (remainingAllocation * IMMEDIATE_ALLOCATION_WEIGHT) / uint256(ALLOCATION_WEIGHT_TOTAL);
        // Assign all division dust to the vested treasury so the fixed supply is fully allocated.
        allocation.treasuryVested = remainingAllocation - allocation.coinStakingRewards - allocation.immediateAllocation;
    }

    function deploy(
        bytes32 userSalt,
        GovLaunchParams calldata govParams,
        IMonolithFactory.DeployParams calldata monolithParams_,
        address manager
    ) external returns (Deployment memory deployment) {
        if (manager == address(0)) revert ZeroAddress();
        _validate(govParams);
        bytes32 key = _reserveDeploymentKey(msg.sender, userSalt);

        // Deploy the Monolith market first; every downstream contract wires against these addresses.
        IMonolithFactory.DeployParams memory monolithParams = monolithParams_;
        monolithParams.operator = address(this);
        monolithParams.manager = manager;

        (deployment.lender, deployment.coin, deployment.vault) = monolithFactory.deploy(monolithParams);
        if (deployment.lender == address(0) || deployment.coin == address(0) || deployment.vault == address(0)) {
            revert ZeroAddress();
        }

        deployment = _deployCoinDAO(deployment, govParams, key, msg.sender, userSalt);
    }

    function deployForExistingCoin(bytes32 userSalt, GovLaunchParams calldata govParams, address lenderAddress)
        external
        returns (Deployment memory deployment)
    {
        _validate(govParams);
        bytes32 key = deploymentKey(msg.sender, userSalt);

        if (lenderAddress == address(0)) revert ZeroAddress();
        if (!monolithFactory.isDeployed(lenderAddress)) revert UnrecognizedLender(lenderAddress);
        if (hasCoinDAO[lenderAddress]) revert CoinDAOAlreadyExists(lenderAddress);

        IMonolithLender lender = IMonolithLender(lenderAddress);
        address previousOperator = lender.operator();
        if (msg.sender != previousOperator) revert CallerNotLenderOperator(msg.sender, previousOperator);

        address pendingOperator = lender.pendingOperator();
        if (pendingOperator != address(this)) revert FactoryNotPendingOperator(pendingOperator);

        _reserveDeploymentKey(key);

        deployment.lender = lenderAddress;
        deployment.coin = lender.coin();
        deployment.vault = lender.vault();

        // The current operator has explicitly nominated this factory. Accepting
        // here makes the complete factory -> RevenueRouter handoff atomic.
        lender.acceptOperator();

        deployment = _deployCoinDAO(deployment, govParams, key, msg.sender, userSalt);

        emit CoinDAOAttached(deployments.length - 1, lenderAddress, previousOperator);
    }

    function _deployCoinDAO(
        Deployment memory deployment,
        GovLaunchParams memory params,
        bytes32 key,
        address creator,
        bytes32 userSalt
    ) internal returns (Deployment memory) {
        if (hasCoinDAO[deployment.lender]) revert CoinDAOAlreadyExists(deployment.lender);
        hasCoinDAO[deployment.lender] = true;

        AllocationAmounts memory allocation = allocationFor(params.deployerStakeBps);

        // Deploy GOV, the timelock, staking, and the governor that will control the launch.
        GovToken govToken =
            GovToken(Clones.cloneDeterministic(govTokenImplementation, _componentSalt(key, _GOV_TOKEN_COMPONENT)));
        govToken.initialize(params.govTokenName, params.govTokenSymbol, address(this));
        deployment.govToken = address(govToken);

        address[] memory proposers = new address[](0);
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        TimelockController timelock = TimelockController(
            payable(CoreDeploymentLib.deployTimelock(
                    _componentSalt(key, _TIMELOCK_COMPONENT),
                    DEFAULT_TIMELOCK_DELAY,
                    proposers,
                    executors,
                    address(this)
                ))
        );
        deployment.timelock = address(timelock);

        StakedGovToken staker = StakedGovToken(
            Clones.cloneDeterministic(stakedGovTokenImplementation, _componentSalt(key, _STAKER_COMPONENT))
        );
        staker.initialize(
            IERC20(deployment.govToken),
            IERC20(deployment.coin),
            string.concat("Staked ", params.govTokenName),
            string.concat("s", params.govTokenSymbol),
            address(this),
            GOV_STAKING_REWARD_DURATION
        );
        deployment.staker = address(staker);

        RevenueRouter revenueRouter = RevenueRouter(
            Clones.cloneDeterministic(revenueRouterImplementation, _componentSalt(key, _REVENUE_ROUTER_COMPONENT))
        );
        revenueRouter.initialize(
            deployment.lender,
            deployment.coin,
            deployment.timelock,
            deployment.staker,
            DEFAULT_GOV_STAKING_BPS,
            address(this)
        );
        deployment.revenueRouter = address(revenueRouter);
        staker.finalizeRewardsDistribution(deployment.revenueRouter);

        string memory governorName = string.concat(params.govTokenName, " Governor");
        CoinDAOGovernor governor = CoinDAOGovernor(
            payable(GovernorDeploymentLib.deployGovernor(
                    _componentSalt(key, _GOVERNOR_COMPONENT),
                    governorName,
                    IVotes(address(staker)),
                    timelock,
                    GOVERNOR_PROPOSAL_THRESHOLD,
                    GOVERNOR_QUORUM_NUMERATOR
                ))
        );
        deployment.governor = address(governor);

        // Move governance authority from the factory to the governor/timelock pair.
        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(governor));
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), address(this));

        address stakingToken = params.stakingTokenChoice == StakingTokenChoice.Coin ? deployment.coin : deployment.vault;
        deployment.stakingToken = stakingToken;
        StakingRewards coinStakingRewards = StakingRewards(
            Clones.cloneDeterministic(stakingRewardsImplementation, _componentSalt(key, _STAKING_REWARDS_COMPONENT))
        );
        coinStakingRewards.initialize(stakingToken, address(govToken), address(this), COIN_STAKING_REWARD_DURATION);
        deployment.coinStakingRewards = address(coinStakingRewards);
        StakingRewardsFunder coinStakingRewardsFunder = StakingRewardsFunder(
            Clones.cloneDeterministic(
                stakingRewardsFunderImplementation, _componentSalt(key, _STAKING_REWARDS_FUNDER_COMPONENT)
            )
        );
        coinStakingRewardsFunder.initialize(coinStakingRewards, allocation.coinStakingRewards);
        deployment.coinStakingRewardsFunder = address(coinStakingRewardsFunder);

        // Route lender revenue through the staker while leaving future management under timelock control.
        IMonolithLender(deployment.lender).setPendingOperator(deployment.revenueRouter);
        revenueRouter.acceptLenderOperator();
        revenueRouter.transferOwnership(deployment.timelock);

        // Prepare vesting recipients before distributing the fixed GOV supply.
        CoinDAOVestingWallet treasuryVesting = CoinDAOVestingWallet(
            payable(Clones.cloneDeterministic(
                    vestingWalletImplementation, _componentSalt(key, _TREASURY_VESTING_COMPONENT)
                ))
        );
        treasuryVesting.initialize(deployment.timelock, uint64(block.timestamp), FOUR_YEARS);
        deployment.treasuryVesting = address(treasuryVesting);
        CoinDAOVestingWallet monolithVesting = CoinDAOVestingWallet(
            payable(Clones.cloneDeterministic(
                    vestingWalletImplementation, _componentSalt(key, _MONOLITH_VESTING_COMPONENT)
                ))
        );
        monolithVesting.initialize(monolithBeneficiary, uint64(block.timestamp), FOUR_YEARS);
        deployment.monolithVesting = address(monolithVesting);
        CoinDAOVestingWallet deployerVesting;
        if (allocation.deployerVesting != 0) {
            deployerVesting = CoinDAOVestingWallet(
                payable(Clones.cloneDeterministic(
                        vestingWalletImplementation, _componentSalt(key, _DEPLOYER_VESTING_COMPONENT)
                    ))
            );
            deployerVesting.initialize(params.deployerRecipient, uint64(block.timestamp), FOUR_YEARS);
            deployment.deployerVesting = address(deployerVesting);
        }

        IERC20 govTokenErc20 = IERC20(address(govToken));
        govTokenErc20.safeTransfer(address(coinStakingRewardsFunder), allocation.coinStakingRewards);
        coinStakingRewards.setRewardsDistribution(address(coinStakingRewardsFunder));
        coinStakingRewardsFunder.fundNextTranche();
        coinStakingRewards.renounceOwnership();

        // Issue the liquid allocation to the deployer when specified, otherwise retain it in the treasury.
        address immediateRecipient =
            params.deployerRecipient == address(0) ? deployment.timelock : params.deployerRecipient;
        govTokenErc20.safeTransfer(immediateRecipient, allocation.immediateAllocation);
        govTokenErc20.safeTransfer(address(treasuryVesting), allocation.treasuryVested);
        govTokenErc20.safeTransfer(address(monolithVesting), allocation.monolithVesting);
        if (allocation.deployerVesting != 0) {
            govTokenErc20.safeTransfer(address(deployerVesting), allocation.deployerVesting);
        }

        // Store and emit the deployment map for callers and indexers.
        deployments.push(deployment);
        deploymentKeyForId.push(key);
        emit DeploymentKeyUsed(deployments.length - 1, key, creator, userSalt);
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

    function _reserveDeploymentKey(address creator, bytes32 userSalt) internal returns (bytes32 key) {
        key = deploymentKey(creator, userSalt);
        _reserveDeploymentKey(key);
    }

    function _reserveDeploymentKey(bytes32 key) internal {
        if (usedDeploymentKeys[key]) revert DeploymentKeyAlreadyUsed(key);
        usedDeploymentKeys[key] = true;
    }

    function _componentSalt(bytes32 key, bytes32 component) internal pure returns (bytes32) {
        return keccak256(abi.encode(key, component));
    }

    function _validateImplementations(Implementations memory implementationSet) internal view {
        address[6] memory values = [
            implementationSet.govToken,
            implementationSet.stakedGovToken,
            implementationSet.revenueRouter,
            implementationSet.stakingRewards,
            implementationSet.stakingRewardsFunder,
            implementationSet.vestingWallet
        ];
        bytes32[6] memory ids = [
            GOV_TOKEN_IMPLEMENTATION_ID,
            STAKED_GOV_TOKEN_IMPLEMENTATION_ID,
            REVENUE_ROUTER_IMPLEMENTATION_ID,
            STAKING_REWARDS_IMPLEMENTATION_ID,
            STAKING_REWARDS_FUNDER_IMPLEMENTATION_ID,
            VESTING_WALLET_IMPLEMENTATION_ID
        ];

        for (uint256 i; i < values.length; ++i) {
            address implementation = values[i];
            if (implementation.code.length == 0) revert InvalidImplementation(ids[i], implementation);

            for (uint256 j; j < i; ++j) {
                if (values[j] == implementation) revert DuplicateImplementation(implementation);
            }

            (bool success, bytes memory result) =
                implementation.staticcall(abi.encodeCall(IImplementation.implementationId, ()));
            if (!success || result.length != 32 || abi.decode(result, (bytes32)) != ids[i]) {
                revert InvalidImplementation(ids[i], implementation);
            }
        }
    }

    function _validate(GovLaunchParams calldata params) internal pure {
        if (params.deployerStakeBps > MAX_DEPLOYER_STAKE_BPS) {
            revert DeployerStakeExceedsMaximum(params.deployerStakeBps);
        }
        if (params.deployerStakeBps != 0 && params.deployerRecipient == address(0)) {
            revert DeployerRecipientRequired();
        }
    }
}
