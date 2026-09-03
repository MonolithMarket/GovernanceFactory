// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title INotifiableRewardReceiver
/// @notice Minimal interface for contracts that receive externally forwarded reward tokens and
/// account for their distribution internally.
interface INotifiableRewardReceiver {
    /// @notice Returns the reward receiver's current staking supply.
    function totalSupply() external view returns (uint256);

    /// @notice Method called to notify a reward receiver it has received a reward.
    /// @dev `amount` must equal the tokens actually received. Fee-on-transfer and rebasing reward
    /// tokens are unsupported by the accounting contract that consumes this interface.
    /// @param amount The amount of reward.
    function notifyRewardAmount(uint256 amount) external;
}
