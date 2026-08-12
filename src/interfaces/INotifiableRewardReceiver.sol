pragma solidity ^0.8.26;

/// @title INotifiableRewardReceiver
/// @notice Minimal interface for contracts that receive externally forwarded reward tokens and
/// account for their distribution internally.
interface INotifiableRewardReceiver {
    /// @notice Method called to notify a reward receiver it has received a reward.
    /// @param amount The amount of reward.
    function notifyRewardAmount(uint256 amount) external;
}
