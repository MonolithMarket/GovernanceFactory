// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {ERC20Wrapper} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Wrapper.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";

import {INotifiableRewardReceiver} from "./interfaces/INotifiableRewardReceiver.sol";

/// @notice Non-transferable staked GOV receipt token with delegated voting and streamed Coin rewards.
/// @dev Reward accounting adapted from Synthetix StakingRewards:
/// GitHub: https://github.com/Synthetixio/synthetix/blob/develop/contracts/StakingRewards.sol
/// Verified deployment: https://etherscan.io/address/0x8302fe9f0c509a996573d3cc5b0d5d51e4fdd5ec
/// Functions derived from Synthetix are annotated with the relevant differences.
contract StakedGovToken is ERC20Wrapper, ERC20Permit, ERC20Votes, ReentrancyGuard, INotifiableRewardReceiver {
    using SafeERC20 for IERC20;

    uint256 public constant REWARD_PRECISION = 1e18;

    IERC20 public immutable rewardsToken;
    address public immutable rewardsDistribution;
    uint256 public immutable rewardsDuration;

    uint256 public periodFinish;
    uint256 public rewardRate;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    uint256 public queuedRewards;

    mapping(address account => uint256) public userRewardPerTokenPaid;
    mapping(address account => uint256) public rewards;

    event RewardAdded(uint256 reward);
    event RewardQueued(uint256 reward);
    event RewardPaid(address indexed account, uint256 reward);

    error ZeroAddress();
    error InvalidRewardAmount();
    error NonTransferable();

    // Diff: Replaces Synthetix's plain staking token balance ledger with an ERC20Wrapper
    // receipt token that also supports Permit and Votes. The rewardsDistribution address
    // is immutable instead of owner-managed.
    constructor(
        IERC20 govToken_,
        IERC20 rewardsToken_,
        string memory name_,
        string memory symbol_,
        address rewardsDistribution_,
        uint256 rewardsDuration_
    ) ERC20(name_, symbol_) ERC20Permit(name_) ERC20Wrapper(govToken_) {
        if (address(govToken_) == address(0)) revert ZeroAddress();
        if (address(rewardsToken_) == address(0)) revert ZeroAddress();
        if (rewardsDistribution_ == address(0)) revert ZeroAddress();
        if (rewardsDuration_ == 0) revert InvalidRewardAmount();

        rewardsToken = rewardsToken_;
        rewardsDistribution = rewardsDistribution_;
        rewardsDuration = rewardsDuration_;
    }

    // Functionally identical to Synthetix original, with immutable rewardsDistribution.
    modifier onlyRewardsDistribution() {
        require(msg.sender == rewardsDistribution, "Caller is not RewardsDistribution contract");
        _;
    }

    // Identical to Synthetix original reward accounting modifier.
    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    // OpenZeppelin wrapper override; not present in Synthetix original.
    function decimals() public view override(ERC20, ERC20Wrapper) returns (uint8) {
        return super.decimals();
    }

    // Diff: Replaces Synthetix stake(). Mints a non-transferable voting receipt token
    // through ERC20Wrapper and directly starts queued rewards once supply exists and no
    // reward period is active.
    // Must be implemented for OZ ERC20Wrapper
    function depositFor(address account, uint256 value)
        public
        override
        nonReentrant
        updateReward(account)
        returns (bool)
    {
        bool success = super.depositFor(account, value);
        if (queuedRewards != 0 && totalSupply() != 0 && block.timestamp >= periodFinish) {
            uint256 reward = queuedRewards;
            queuedRewards = 0;
            _startReward(reward);
        }
        return success;
    }

    // Diff: Replaces Synthetix withdraw(). Burns the wrapped voting receipt token and
    // directly stops and queues undistributed rewards if the final withdrawal empties
    // supply mid-period.
    // Must be implemented for OZ ERC20Wrapper
    function withdrawTo(address account, uint256 value)
        public
        override
        nonReentrant
        updateReward(msg.sender)
        returns (bool)
    {
        bool success = super.withdrawTo(account, value);
        if (totalSupply() == 0 && block.timestamp < periodFinish) {
            uint256 remainingReward = (periodFinish - block.timestamp) * rewardRate;
            rewardRate = 0;
            periodFinish = block.timestamp;
            lastUpdateTime = block.timestamp;

            if (remainingReward != 0) {
                queuedRewards += remainingReward;
                emit RewardQueued(remainingReward);
            }
        }
        return success;
    }

    // Diff: Convenience wrapper with no Synthetix equivalent; withdraws the caller's
    // full staked balance to themselves.
    function withdraw() external returns (bool) {
        return withdrawTo(msg.sender, balanceOf(msg.sender));
    }

    // Identical to Synthetix original.
    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    // Functionally identical to Synthetix original, using totalSupply() from the wrapper
    // receipt token and Solidity built-in safe math.
    function rewardPerToken() public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return rewardPerTokenStored;

        return
            rewardPerTokenStored + ((lastTimeRewardApplicable() - lastUpdateTime) * rewardRate * REWARD_PRECISION)
                / supply;
    }

    // Functionally identical to Synthetix original, using receipt token balances and
    // Solidity built-in safe math.
    function earned(address account) public view returns (uint256) {
        return (balanceOf(account) * (rewardPerToken() - userRewardPerTokenPaid[account])) / REWARD_PRECISION
            + rewards[account];
    }

    // Functionally identical to Synthetix original, using Solidity built-in safe math.
    function getRewardForDuration() external view returns (uint256) {
        return rewardRate * rewardsDuration;
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

    // Diff: rewardsDistribution is immutable, and rewards queue while no one is staked.
    function notifyRewardAmount(uint256 reward) external onlyRewardsDistribution updateReward(address(0)) {
        if (totalSupply() == 0) {
            queuedRewards += reward;
            emit RewardQueued(reward);
            return;
        }

        reward += queuedRewards;
        queuedRewards = 0;
        _startReward(reward);
    }

    // Diff: Extracts Synthetix notifyRewardAmount rate setup into an internal helper,
    // preserving leftover reward rollover while queueing rewards that would round to
    // a zero rate.
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
            queuedRewards += reward;
            emit RewardQueued(reward);
            return;
        }

        rewardRate = newRewardRate;
        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + rewardsDuration;
        emit RewardAdded(reward);
    }

    // Diff: New OpenZeppelin token hook with no Synthetix equivalent; allows mint/burn
    // only so staked voting receipts remain non-transferable.
    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        if (from != address(0) && to != address(0)) revert NonTransferable();
        super._update(from, to, value);
    }

    // OpenZeppelin Permit/Votes override; not present in Synthetix original.
    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }
}
