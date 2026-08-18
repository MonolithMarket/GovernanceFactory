// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {
    ERC20PermitUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {
    ERC20VotesUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import {
    ERC20WrapperUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20WrapperUpgradeable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {NoncesUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/NoncesUpgradeable.sol";

import {INotifiableRewardReceiver} from "./interfaces/INotifiableRewardReceiver.sol";
import {IRevenueDistributor} from "./interfaces/IRevenueDistributor.sol";

/// @notice Non-transferable staked GOV receipt token with delegated voting and Coin rewards.
/// @dev Each reward notification is accrued immediately to the stGOV supply that exists at that moment.
/// The underlying GOV and reward token must transfer exact amounts and maintain stable account balances;
/// fee-on-transfer and rebasing tokens are unsupported.
contract StakedGovToken is
    ERC20WrapperUpgradeable,
    ERC20PermitUpgradeable,
    ERC20VotesUpgradeable,
    ReentrancyGuard,
    INotifiableRewardReceiver
{
    using SafeERC20 for IERC20;

    uint256 public constant REWARD_PRECISION = 1e18;

    IERC20 public rewardsToken;
    IRevenueDistributor public revenueRouter;

    uint256 public rewardPerTokenStored;

    mapping(address account => uint256) public userRewardPerTokenPaid;
    mapping(address account => uint256) public rewards;

    event RewardAdded(uint256 reward);
    event RewardPaid(address indexed account, uint256 reward);

    error ZeroAddress();
    error NoStakedSupply();
    error NonTransferable();

    constructor() {
        _disableInitializers();
    }

    function initialize(
        IERC20 govToken_,
        IERC20 rewardsToken_,
        string memory name_,
        string memory symbol_,
        address revenueRouter_
    ) external initializer {
        if (address(govToken_) == address(0)) revert ZeroAddress();
        if (address(rewardsToken_) == address(0)) revert ZeroAddress();
        if (revenueRouter_ == address(0)) revert ZeroAddress();

        __ERC20_init(name_, symbol_);
        __ERC20Permit_init(name_);
        __ERC20Wrapper_init(govToken_);
        __ERC20Votes_init();
        rewardsToken = rewardsToken_;
        revenueRouter = IRevenueDistributor(revenueRouter_);
    }

    modifier onlyRevenueRouter() {
        require(msg.sender == address(revenueRouter), "Caller is not RevenueRouter contract");
        _;
    }

    modifier harvestYield() {
        revenueRouter.distribute();
        _;
    }

    modifier updateReward(address account) {
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    function decimals() public view override(ERC20Upgradeable, ERC20WrapperUpgradeable) returns (uint8) {
        return super.decimals();
    }

    function totalSupply() public view override(ERC20Upgradeable, INotifiableRewardReceiver) returns (uint256) {
        return super.totalSupply();
    }

    function depositFor(address account, uint256 value)
        public
        override
        nonReentrant
        harvestYield
        updateReward(account)
        returns (bool)
    {
        return super.depositFor(account, value);
    }

    function withdrawTo(address account, uint256 value)
        public
        override
        nonReentrant
        updateReward(msg.sender)
        returns (bool)
    {
        return super.withdrawTo(account, value);
    }

    function withdraw() external returns (bool) {
        return withdrawTo(msg.sender, balanceOf(msg.sender));
    }

    function rewardPerToken() public view returns (uint256) {
        return rewardPerTokenStored;
    }

    function earned(address account) public view returns (uint256) {
        return Math.mulDiv(balanceOf(account), rewardPerTokenStored - userRewardPerTokenPaid[account], REWARD_PRECISION)
            + rewards[account];
    }

    function getReward() public nonReentrant updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            rewardsToken.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    /// @notice Immediately accrues a received reward to the current stGOV supply.
    /// @dev The revenue router must transfer the reward tokens before notifying.
    function notifyRewardAmount(uint256 reward) external onlyRevenueRouter {
        uint256 supply = totalSupply();
        if (supply == 0) revert NoStakedSupply();

        rewardPerTokenStored += Math.mulDiv(reward, REWARD_PRECISION, supply);
        emit RewardAdded(reward);
    }

    function _update(address from, address to, uint256 value)
        internal
        override(ERC20Upgradeable, ERC20VotesUpgradeable)
    {
        if (from != address(0) && to != address(0)) {
            revert NonTransferable();
        }
        super._update(from, to, value);
    }

    function nonces(address owner) public view override(ERC20PermitUpgradeable, NoncesUpgradeable) returns (uint256) {
        return super.nonces(owner);
    }
}
