// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract StakingRewards is Ownable {
    using SafeERC20 for IERC20;

    uint256 public constant REWARD_PRECISION = 1e18;

    IERC20 public immutable stakingToken;
    IERC20 public immutable rewardsToken;

    uint256 public rewardsDuration;
    uint256 public periodFinish;
    uint256 public rewardRate;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;

    uint256 private _totalSupply;
    mapping(address account => uint256) private _balances;
    mapping(address account => uint256) public userRewardPerTokenPaid;
    mapping(address account => uint256) public rewards;

    error ZeroAddress();
    error ZeroAmount();
    error InvalidRewardDuration();
    error RewardRateIsZero();
    error InsufficientRewardBalance(uint256 required, uint256 available);

    event RewardAdded(uint256 reward);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardsDurationUpdated(uint256 newDuration);

    constructor(IERC20 stakingToken_, IERC20 rewardsToken_, address initialOwner, uint256 rewardsDuration_)
        Ownable(initialOwner)
    {
        if (address(stakingToken_) == address(0) || address(rewardsToken_) == address(0) || initialOwner == address(0))
        {
            revert ZeroAddress();
        }
        if (rewardsDuration_ == 0) revert InvalidRewardDuration();

        stakingToken = stakingToken_;
        rewardsToken = rewardsToken_;
        rewardsDuration = rewardsDuration_;
    }

    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    function rewardPerToken() public view returns (uint256) {
        if (_totalSupply == 0) return rewardPerTokenStored;
        return rewardPerTokenStored + ((lastTimeRewardApplicable() - lastUpdateTime) * rewardRate * REWARD_PRECISION)
            / _totalSupply;
    }

    function earned(address account) public view returns (uint256) {
        return ((_balances[account] * (rewardPerToken() - userRewardPerTokenPaid[account])) / REWARD_PRECISION)
            + rewards[account];
    }

    function stake(uint256 amount) external updateReward(msg.sender) {
        if (amount == 0) revert ZeroAmount();

        _totalSupply += amount;
        _balances[msg.sender] += amount;
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);

        emit Staked(msg.sender, amount);
    }

    function withdraw(uint256 amount) public updateReward(msg.sender) {
        if (amount == 0) revert ZeroAmount();

        _totalSupply -= amount;
        _balances[msg.sender] -= amount;
        stakingToken.safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, amount);
    }

    function getReward() public updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            rewardsToken.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    function exit() external {
        withdraw(_balances[msg.sender]);
        getReward();
    }

    function notifyRewardAmount(uint256 reward) external onlyOwner updateReward(address(0)) {
        if (reward == 0) revert ZeroAmount();

        uint256 rewardAmount = reward;
        if (block.timestamp < periodFinish) {
            rewardAmount += (periodFinish - block.timestamp) * rewardRate;
        }

        uint256 newRewardRate = rewardAmount / rewardsDuration;
        if (newRewardRate == 0) revert RewardRateIsZero();

        uint256 available = rewardsToken.balanceOf(address(this));
        uint256 required = newRewardRate * rewardsDuration;
        if (required > available) revert InsufficientRewardBalance(required, available);

        rewardRate = newRewardRate;
        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + rewardsDuration;

        emit RewardAdded(reward);
    }

    function setRewardsDuration(uint256 rewardsDuration_) external onlyOwner {
        if (block.timestamp <= periodFinish) revert InvalidRewardDuration();
        if (rewardsDuration_ == 0) revert InvalidRewardDuration();

        rewardsDuration = rewardsDuration_;

        emit RewardsDurationUpdated(rewardsDuration_);
    }
}
