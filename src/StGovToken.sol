// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {ERC20Wrapper} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Wrapper.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {Time} from "@openzeppelin/contracts/utils/types/Time.sol";

contract StGovToken is ERC20Wrapper, ERC20Permit, ERC20Votes, Ownable {
    using SafeERC20 for IERC20;

    uint256 public constant REWARD_PRECISION = 1e18;

    struct RewardState {
        uint256 rewardDuration;
        uint256 periodFinish;
        uint256 rewardRate;
        uint256 lastUpdateTime;
        uint256 rewardPerTokenStored;
    }

    IERC20 public immutable govToken;

    address[] private _rewardTokens;
    mapping(address rewardToken => bool) public isRewardToken;
    mapping(address rewardToken => RewardState) public rewardData;
    mapping(address rewardToken => mapping(address notifier => bool)) public isRewardNotifier;
    mapping(address user => mapping(address rewardToken => uint256)) public userRewardPerTokenPaid;
    mapping(address user => mapping(address rewardToken => uint256)) public rewards;

    error NonTransferable();
    error ZeroAmount();
    error ZeroAddress();
    error InvalidRewardDuration();
    error RewardTokenAlreadyConfigured(address rewardToken);
    error RewardTokenNotConfigured(address rewardToken);
    error NotRewardNotifier(address rewardToken, address notifier);
    error RewardRateIsZero(address rewardToken);
    error InsufficientRewardBalance(address rewardToken, uint256 required, uint256 available);

    event RewardTokenAdded(address indexed rewardToken, uint256 rewardDuration);
    event RewardDurationUpdated(address indexed rewardToken, uint256 rewardDuration);
    event RewardNotifierUpdated(address indexed rewardToken, address indexed notifier, bool allowed);
    event RewardAdded(address indexed rewardToken, address indexed notifier, uint256 amount, uint256 rewardRate);
    event RewardPaid(address indexed user, address indexed rewardToken, address indexed recipient, uint256 amount);

    constructor(IERC20 govToken_, string memory name_, string memory symbol_, address initialOwner)
        ERC20(name_, symbol_)
        ERC20Wrapper(govToken_)
        ERC20Permit(name_)
        Ownable(initialOwner)
    {
        if (address(govToken_) == address(0) || initialOwner == address(0)) revert ZeroAddress();
        govToken = govToken_;
    }

    function stake(uint256 amount) external returns (bool) {
        if (amount == 0) revert ZeroAmount();
        return depositFor(msg.sender, amount);
    }

    function stakeFor(address account, uint256 amount) external returns (bool) {
        if (account == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        return depositFor(account, amount);
    }

    function unstake(uint256 amount) external returns (bool) {
        if (amount == 0) revert ZeroAmount();
        return withdrawTo(msg.sender, amount);
    }

    function unstakeTo(address account, uint256 amount) external returns (bool) {
        if (account == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        return withdrawTo(account, amount);
    }

    function rewardTokens() external view returns (address[] memory) {
        return _rewardTokens;
    }

    function rewardTokensLength() external view returns (uint256) {
        return _rewardTokens.length;
    }

    function addRewardToken(address rewardToken, uint256 rewardDuration) external onlyOwner {
        if (rewardToken == address(0)) revert ZeroAddress();
        if (rewardDuration == 0) revert InvalidRewardDuration();
        if (isRewardToken[rewardToken]) revert RewardTokenAlreadyConfigured(rewardToken);

        isRewardToken[rewardToken] = true;
        _rewardTokens.push(rewardToken);
        rewardData[rewardToken].rewardDuration = rewardDuration;

        emit RewardTokenAdded(rewardToken, rewardDuration);
    }

    function setRewardDuration(address rewardToken, uint256 rewardDuration) external onlyOwner {
        if (!isRewardToken[rewardToken]) revert RewardTokenNotConfigured(rewardToken);
        if (rewardDuration == 0) revert InvalidRewardDuration();

        _updateReward(address(0));
        rewardData[rewardToken].rewardDuration = rewardDuration;

        emit RewardDurationUpdated(rewardToken, rewardDuration);
    }

    function setRewardNotifier(address rewardToken, address notifier, bool allowed) external onlyOwner {
        if (!isRewardToken[rewardToken]) revert RewardTokenNotConfigured(rewardToken);
        if (notifier == address(0)) revert ZeroAddress();

        isRewardNotifier[rewardToken][notifier] = allowed;

        emit RewardNotifierUpdated(rewardToken, notifier, allowed);
    }

    function lastTimeRewardApplicable(address rewardToken) public view returns (uint256) {
        RewardState memory data = rewardData[rewardToken];
        return block.timestamp < data.periodFinish ? block.timestamp : data.periodFinish;
    }

    function rewardPerToken(address rewardToken) public view returns (uint256) {
        RewardState memory data = rewardData[rewardToken];
        uint256 supply = totalSupply();
        if (supply == 0) return data.rewardPerTokenStored;

        return data.rewardPerTokenStored
            + ((lastTimeRewardApplicable(rewardToken) - data.lastUpdateTime) * data.rewardRate * REWARD_PRECISION)
            / supply;
    }

    function earned(address account, address rewardToken) public view returns (uint256) {
        return ((balanceOf(account) * (rewardPerToken(rewardToken) - userRewardPerTokenPaid[account][rewardToken]))
                / REWARD_PRECISION) + rewards[account][rewardToken];
    }

    function notifyRewardAmount(address rewardToken, uint256 amount) external {
        if (!isRewardToken[rewardToken]) revert RewardTokenNotConfigured(rewardToken);
        if (!isRewardNotifier[rewardToken][msg.sender]) revert NotRewardNotifier(rewardToken, msg.sender);
        if (amount == 0) revert ZeroAmount();

        _updateReward(address(0));
        IERC20(rewardToken).safeTransferFrom(msg.sender, address(this), amount);

        RewardState storage data = rewardData[rewardToken];
        uint256 rewardAmount = amount;
        if (block.timestamp < data.periodFinish) {
            rewardAmount += (data.periodFinish - block.timestamp) * data.rewardRate;
        }

        uint256 rewardRate = rewardAmount / data.rewardDuration;
        if (rewardRate == 0) revert RewardRateIsZero(rewardToken);

        uint256 available = _availableRewardBalance(rewardToken);
        uint256 required = rewardRate * data.rewardDuration;
        if (required > available) revert InsufficientRewardBalance(rewardToken, required, available);

        data.rewardRate = rewardRate;
        data.lastUpdateTime = block.timestamp;
        data.periodFinish = block.timestamp + data.rewardDuration;

        emit RewardAdded(rewardToken, msg.sender, amount, rewardRate);
    }

    function claimReward(address rewardToken, address recipient) public returns (uint256 amount) {
        if (!isRewardToken[rewardToken]) revert RewardTokenNotConfigured(rewardToken);
        if (recipient == address(0)) revert ZeroAddress();

        _updateReward(msg.sender);

        amount = rewards[msg.sender][rewardToken];
        if (amount > 0) {
            rewards[msg.sender][rewardToken] = 0;
            IERC20(rewardToken).safeTransfer(recipient, amount);
            emit RewardPaid(msg.sender, rewardToken, recipient, amount);
        }
    }

    function claimRewards(address recipient) external {
        if (recipient == address(0)) revert ZeroAddress();
        _claimRewards(msg.sender, recipient);
    }

    function getReward() external {
        _claimRewards(msg.sender, msg.sender);
    }

    function _availableRewardBalance(address rewardToken) internal view returns (uint256) {
        uint256 balance = IERC20(rewardToken).balanceOf(address(this));
        if (rewardToken == address(govToken)) {
            return balance - totalSupply();
        }
        return balance;
    }

    function _updateReward(address account) internal {
        uint256 length = _rewardTokens.length;
        for (uint256 i; i < length; ++i) {
            address rewardToken = _rewardTokens[i];
            RewardState storage data = rewardData[rewardToken];
            data.rewardPerTokenStored = rewardPerToken(rewardToken);
            data.lastUpdateTime = lastTimeRewardApplicable(rewardToken);

            if (account != address(0)) {
                rewards[account][rewardToken] = earned(account, rewardToken);
                userRewardPerTokenPaid[account][rewardToken] = data.rewardPerTokenStored;
            }
        }
    }

    function _claimRewards(address account, address recipient) internal {
        _updateReward(account);
        uint256 length = _rewardTokens.length;
        for (uint256 i; i < length; ++i) {
            address rewardToken = _rewardTokens[i];
            uint256 amount = rewards[account][rewardToken];
            if (amount > 0) {
                rewards[account][rewardToken] = 0;
                IERC20(rewardToken).safeTransfer(recipient, amount);
                emit RewardPaid(account, rewardToken, recipient, amount);
            }
        }
    }

    function _update(address from, address to, uint256 amount) internal override(ERC20, ERC20Votes) {
        if (from != address(0) && to != address(0)) revert NonTransferable();
        if (from != address(0)) _updateReward(from);
        if (to != address(0)) _updateReward(to);
        super._update(from, to, amount);
    }

    function decimals() public view override(ERC20, ERC20Wrapper) returns (uint8) {
        return super.decimals();
    }

    function clock() public view override returns (uint48) {
        return Time.timestamp();
    }

    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=timestamp";
    }

    function nonces(address owner_) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner_);
    }
}
