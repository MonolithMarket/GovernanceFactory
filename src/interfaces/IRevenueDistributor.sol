pragma solidity ^0.8.26;

/// @title IRevenueDistributor
/// @notice Minimal interface for synchronizing pending revenue before staking reward state changes.
interface IRevenueDistributor {
    function distribute() external returns (uint256 treasuryAmount, uint256 govStakingAmount);
}
