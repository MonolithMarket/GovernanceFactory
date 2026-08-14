pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

import {StakingRewards} from "./StakingRewards.sol";

/// @notice Permissionless fixed-schedule funder for a StakingRewards contract.
contract StakingRewardsFunder is Initializable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 public constant BPS = 10_000;
    uint256 public constant TRANCHE_COUNT = 4;

    StakingRewards public stakingRewards;
    IERC20 public rewardsToken;
    uint256 public totalRewards;

    uint256 public nextTranche;

    event TrancheFunded(uint256 indexed tranche, uint256 amount, uint256 periodFinish);

    error ZeroAddress();
    error ZeroRewards();
    error InvalidTranche(uint256 tranche);
    error PreviousTrancheActive(uint256 periodFinish);
    error AllTranchesFunded();
    error NotRewardsDistribution(address rewardsDistribution);
    error InsufficientBalance(uint256 balance, uint256 required);

    constructor() {
        _disableInitializers();
    }

    function initialize(StakingRewards stakingRewards_, uint256 totalRewards_) external initializer {
        if (address(stakingRewards_) == address(0)) revert ZeroAddress();
        if (totalRewards_ == 0) revert ZeroRewards();

        stakingRewards = stakingRewards_;
        rewardsToken = stakingRewards_.rewardsToken();
        totalRewards = totalRewards_;
    }

    //Each tranche has basispoints corresponding to percentage of total GOV tokens that will be issued to Coin stakers
    // Current implementation issues yearly tranches:
    // Tranche 1: 32.5%
    // Tranche 2: 27.5%
    // Tranche 3: 22.5%
    // Tranche 4: 17.5%
    function trancheBps(uint256 tranche) public pure returns (uint16) {
        if (tranche == 0) return 3_250;
        if (tranche == 1) return 2_750;
        if (tranche == 2) return 2_250;
        if (tranche == 3) return 1_750;
        revert InvalidTranche(tranche);
    }

    function trancheAmounts(uint256 tranche) external view returns (uint256) {
        if (tranche >= TRANCHE_COUNT) revert InvalidTranche(tranche);
        return _trancheAmount(tranche);
    }

    function fundNextTranche() external nonReentrant {
        uint256 tranche = nextTranche;
        if (tranche == TRANCHE_COUNT) revert AllTranchesFunded();

        uint256 periodFinish = stakingRewards.periodFinish();
        if (block.timestamp < periodFinish) revert PreviousTrancheActive(periodFinish);

        address rewardsDistribution = stakingRewards.rewardsDistribution();
        if (rewardsDistribution != address(this)) revert NotRewardsDistribution(rewardsDistribution);

        uint256 amount = _trancheAmount(tranche);
        uint256 balance = rewardsToken.balanceOf(address(this));
        if (balance < amount) revert InsufficientBalance(balance, amount);

        nextTranche = tranche + 1;

        rewardsToken.safeTransfer(address(stakingRewards), amount);
        stakingRewards.notifyRewardAmount(amount);

        emit TrancheFunded(tranche, amount, stakingRewards.periodFinish());
    }

    function _trancheAmount(uint256 tranche) internal view returns (uint256) {
        uint256 rewards = totalRewards;
        if (tranche < TRANCHE_COUNT - 1) return (rewards * trancheBps(tranche)) / BPS;
        // The final tranche sweeps any reward dust left after the fixed tranches.
        return rewardsToken.balanceOf(address(this));
    }
}
