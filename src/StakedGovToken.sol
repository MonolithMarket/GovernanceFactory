// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {ERC20Wrapper} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Wrapper.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";

import {INotifiableRewardReceiver} from "./interfaces/INotifiableRewardReceiver.sol";

/// @notice Non-transferable staked GOV receipt token with delegated voting and streamed Coin rewards.
contract StakedGovToken is ERC20Wrapper, ERC20Permit, ERC20Votes, Ownable, ReentrancyGuard, INotifiableRewardReceiver {
    using SafeERC20 for IERC20;

    uint256 public constant REWARD_PRECISION = 1e18;

    IERC20 public immutable rewardsToken;
    uint256 public immutable rewardsDuration;

    uint256 public periodFinish;
    uint256 public rewardRate;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    uint256 public queuedRewards;

    mapping(address account => uint256) public userRewardPerTokenPaid;
    mapping(address account => uint256) public rewards;
    mapping(address notifier => bool) public isRewardNotifier;

    event RewardNotifierSet(address indexed account, bool isEnabled);
    event RewardAdded(uint256 reward);
    event RewardQueued(uint256 reward);
    event RewardPaid(address indexed account, uint256 reward);

    error ZeroAddress();
    error InvalidRewardAmount();
    error InsufficientRewardBalance();
    error NotRewardNotifier();
    error NonTransferable();

    constructor(
        IERC20 govToken_,
        IERC20 rewardsToken_,
        string memory name_,
        string memory symbol_,
        address initialOwner_,
        uint256 rewardsDuration_
    ) ERC20(name_, symbol_) ERC20Permit(name_) ERC20Wrapper(govToken_) Ownable(initialOwner_) {
        if (address(govToken_) == address(0)) revert ZeroAddress();
        if (address(rewardsToken_) == address(0)) revert ZeroAddress();
        if (rewardsDuration_ == 0) revert InvalidRewardAmount();

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

    function setRewardNotifier(address account, bool isEnabled) external onlyOwner {
        isRewardNotifier[account] = isEnabled;
        emit RewardNotifierSet(account, isEnabled);
    }

    function decimals() public view override(ERC20, ERC20Wrapper) returns (uint8) {
        return super.decimals();
    }

    function depositFor(address account, uint256 value)
        public
        override
        nonReentrant
        updateReward(account)
        returns (bool)
    {
        bool success = super.depositFor(account, value);
        _startQueuedRewardsIfPossible();
        return success;
    }

    function withdrawTo(address account, uint256 value)
        public
        override
        nonReentrant
        updateReward(msg.sender)
        returns (bool)
    {
        bool success = super.withdrawTo(account, value);
        _queueUndistributedRewardsIfEmpty();
        return success;
    }

    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    function rewardPerToken() public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return rewardPerTokenStored;

        return
            rewardPerTokenStored + ((lastTimeRewardApplicable() - lastUpdateTime) * rewardRate * REWARD_PRECISION)
                / supply;
    }

    function earned(address account) public view returns (uint256) {
        return (balanceOf(account) * (rewardPerToken() - userRewardPerTokenPaid[account])) / REWARD_PRECISION
            + rewards[account];
    }

    function getRewardForDuration() external view returns (uint256) {
        return rewardRate * rewardsDuration;
    }

    function claimReward() external nonReentrant updateReward(msg.sender) returns (uint256 reward) {
        reward = rewards[msg.sender];
        if (reward != 0) {
            rewards[msg.sender] = 0;
            rewardsToken.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    function notifyRewardAmount(uint256 amount) external updateReward(address(0)) {
        if (!isRewardNotifier[msg.sender]) revert NotRewardNotifier();
        if (amount == 0) revert InvalidRewardAmount();

        if (totalSupply() == 0) {
            queuedRewards += amount;
            emit RewardQueued(amount);
            return;
        }

        uint256 reward = amount + queuedRewards;
        queuedRewards = 0;
        _startReward(reward);
    }

    function _startQueuedRewardsIfPossible() internal {
        if (queuedRewards == 0 || totalSupply() == 0 || block.timestamp < periodFinish) return;

        uint256 reward = queuedRewards;
        queuedRewards = 0;
        _startReward(reward);
    }

    function _startReward(uint256 reward) internal {
        uint256 rewardToDistribute = reward;
        if (block.timestamp < periodFinish) {
            rewardToDistribute += (periodFinish - block.timestamp) * rewardRate;
        }

        uint256 newRewardRate = rewardToDistribute / rewardsDuration;
        if (newRewardRate == 0) {
            queuedRewards += reward;
            emit RewardQueued(reward);
            return;
        }

        if (newRewardRate > rewardsToken.balanceOf(address(this)) / rewardsDuration) {
            revert InsufficientRewardBalance();
        }

        rewardRate = newRewardRate;
        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + rewardsDuration;
        emit RewardAdded(reward);
    }

    function _queueUndistributedRewardsIfEmpty() internal {
        if (totalSupply() != 0 || block.timestamp >= periodFinish) return;

        uint256 remainingReward = (periodFinish - block.timestamp) * rewardRate;
        rewardRate = 0;
        periodFinish = block.timestamp;
        lastUpdateTime = block.timestamp;

        if (remainingReward != 0) {
            queuedRewards += remainingReward;
            emit RewardQueued(remainingReward);
        }
    }

    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        if (from != address(0) && to != address(0)) revert NonTransferable();
        super._update(from, to, value);
    }

    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }
}
