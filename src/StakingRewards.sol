// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Synthetix-style staking rewards with a fixed four-tranche emission schedule.
/// @dev Reward accounting adapted from Synthetix StakingRewards:
/// GitHub: https://github.com/Synthetixio/synthetix/blob/develop/contracts/StakingRewards.sol
/// Verified deployment: https://etherscan.io/address/0x8302fe9f0c509a996573d3cc5b0d5d51e4fdd5ec
/// Original Synthetix snippets are included next to adapted methods; identical methods are marked.
contract StakingRewards is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 public constant BPS = 10_000;
    uint256 public constant TRANCHE_COUNT = 4;
    uint256 public constant REWARD_PRECISION = 1e18;

    IERC20 public immutable stakingToken;
    IERC20 public immutable rewardsToken;
    uint256 public immutable totalRewards;
    uint256 public immutable rewardsDuration;

    uint256 private _totalSupply;
    mapping(address account => uint256) private _balances;

    uint256 public nextTranche;
    uint256 public periodFinish;
    uint256 public rewardRate;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    mapping(address account => uint256) public userRewardPerTokenPaid;
    mapping(address account => uint256) public rewards;

    event RewardAdded(uint256 reward);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event TrancheStarted(uint256 indexed tranche, uint256 amount, uint256 periodFinish);

    error ZeroRewards();
    error InvalidTranche(uint256 tranche);
    error PreviousTrancheActive(uint256 periodFinish);
    error AllTranchesStarted();
    error NoStakers();
    error InsufficientBalance(uint256 balance, uint256 required);

    constructor(address stakingToken_, address rewardsToken_, uint256 totalRewards_, uint256 rewardsDuration_) {
        require(stakingToken_ != address(0), "Staking token cannot be 0");
        require(rewardsToken_ != address(0), "Rewards token cannot be 0");
        if (totalRewards_ == 0) revert ZeroRewards();
        require(rewardsDuration_ > 0, "Rewards duration cannot be 0");

        stakingToken = IERC20(stakingToken_);
        rewardsToken = IERC20(rewardsToken_);
        totalRewards = totalRewards_;
        rewardsDuration = rewardsDuration_;
    }

    // Identical to Synthetix original.
    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    // Identical to Synthetix original.
    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    // Identical to Synthetix original.
    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    // Identical to Synthetix original.
    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    // Functionally identical to Synthetix original, using Solidity built-in safe math.
    function rewardPerToken() public view returns (uint256) {
        if (_totalSupply == 0) return rewardPerTokenStored;
        return rewardPerTokenStored + ((lastTimeRewardApplicable() - lastUpdateTime) * rewardRate * REWARD_PRECISION)
            / _totalSupply;
    }

    // Functionally identical to Synthetix original, using Solidity built-in safe math.
    function earned(address account) public view returns (uint256) {
        return (_balances[account] * (rewardPerToken() - userRewardPerTokenPaid[account])) / REWARD_PRECISION
            + rewards[account];
    }

    // Functionally identical to Synthetix original, using Solidity built-in safe math.
    function getRewardForDuration() external view returns (uint256) {
        return rewardRate * rewardsDuration;
    }

    // Diff: No pause modifier. Otherwise functionally identical using solidity built-in safe math
    function stake(uint256 amount) external nonReentrant updateReward(msg.sender) {
        require(amount > 0, "Cannot stake 0");
        _totalSupply += amount;
        _balances[msg.sender] += amount;
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);

        if (nextTranche == 0) _startNextTranche();
    }

    // Functionally identical to Synthetix original, using Solidity built-in safe math.
    function withdraw(uint256 amount) public nonReentrant updateReward(msg.sender) {
        require(amount > 0, "Cannot withdraw 0");
        _totalSupply -= amount;
        _balances[msg.sender] -= amount;
        stakingToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    // Identical to Synthetix original.
    function getReward() public nonReentrant updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            rewardsToken.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    // Identical to Synthetix original.
    function exit() external {
        withdraw(_balances[msg.sender]);
        getReward();
    }

    /// @notice Starts the next annual reward tranche once the previous tranche has finished.
    /// @dev Tranche zero starts automatically on the first successful stake.
    function startNextTranche() external nonReentrant updateReward(address(0)) {
        _startNextTranche();
    }

    function trancheBps(uint256 tranche) public pure returns (uint16) {
        if (tranche == 0) return 3_250;
        if (tranche == 1) return 2_750;
        if (tranche == 2) return 2_250;
        if (tranche == 3) return 1_750;
        revert InvalidTranche(tranche);
    }

    function trancheAmount(uint256 tranche) external view returns (uint256) {
        if (tranche >= TRANCHE_COUNT) revert InvalidTranche(tranche);
        return _trancheAmount(tranche);
    }

    function _startNextTranche() internal {
        uint256 tranche = nextTranche;
        if (tranche == TRANCHE_COUNT) revert AllTranchesStarted();
        if (block.timestamp < periodFinish) revert PreviousTrancheActive(periodFinish);
        if (_totalSupply == 0) revert NoStakers();

        uint256 amount = _trancheAmount(tranche);
        uint256 balance = rewardsToken.balanceOf(address(this));
        uint256 required = tranche == 0 ? totalRewards : amount;
        if (balance < required) revert InsufficientBalance(balance, required);

        nextTranche = tranche + 1;
        _startReward(amount);

        emit TrancheStarted(tranche, amount, periodFinish);
    }

    function _startReward(uint256 reward) internal {
        rewardRate = reward / rewardsDuration;

        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + rewardsDuration;
        emit RewardAdded(reward);
    }

    function _trancheAmount(uint256 tranche) internal view returns (uint256) {
        uint256 rewards_ = totalRewards;
        if (tranche < TRANCHE_COUNT - 1) return (rewards_ * trancheBps(tranche)) / BPS;

        uint256 priorTranches;
        for (uint256 i; i < TRANCHE_COUNT - 1; ++i) {
            priorTranches += (rewards_ * trancheBps(i)) / BPS;
        }
        return rewards_ - priorTranches;
    }

    // Synthetix's external reward notification, pause, recovery, and mutable duration
    // hooks are intentionally omitted in favor of the fixed, fully funded schedule.
}
