// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {IMonolithLender} from "./interfaces/IMonolith.sol";
import {INotifiableRewardReceiver} from "./interfaces/INotifiableRewardReceiver.sol";
import {IRevenueDistributor} from "./interfaces/IRevenueDistributor.sol";

/// @notice Pulls Lender reserves and routes Coin revenue between staked GOV and the treasury.
/// @dev This contract is intentionally the permanent operator of its paired Lender. It deliberately
/// does not expose a call to `setPendingOperator`, so neither its owner nor the timelock can migrate
/// the operator role after deployment. Governance controls the manager, revenue split, local reserve fee,
/// and early immutability enablement.
/// @dev Coin must transfer the exact requested amount and maintain stable account balances.
/// Fee-on-transfer and rebasing tokens are unsupported.
contract RevenueRouter is OwnableUpgradeable, IRevenueDistributor {
    using SafeERC20 for IERC20;

    uint16 public constant MAX_BPS = 10_000;

    IMonolithLender public lender;
    IERC20 public coin;
    address public treasury;
    INotifiableRewardReceiver public govStaking;
    uint16 public govStakingBps;

    event GovStakingBpsUpdated(uint16 oldGovStakingBps, uint16 newGovStakingBps);
    event RevenueDistributed(uint256 totalAmount, uint256 treasuryAmount, uint256 govStakingAmount);
    event ManagerUpdated(address indexed newManager);

    error ZeroAddress();
    error InvalidGovStakingBps(uint16 govStakingBps);

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address lender_,
        address coin_,
        address treasury_,
        address govStaking_,
        uint16 govStakingBps_,
        address owner_
    ) external initializer {
        if (
            lender_ == address(0) || coin_ == address(0) || treasury_ == address(0) || govStaking_ == address(0)
                || owner_ == address(0)
        ) revert ZeroAddress();
        if (govStakingBps_ > MAX_BPS) revert InvalidGovStakingBps(govStakingBps_);

        __Ownable_init(owner_);
        lender = IMonolithLender(lender_);
        coin = IERC20(coin_);
        treasury = treasury_;
        govStaking = INotifiableRewardReceiver(govStaking_);
        govStakingBps = govStakingBps_;
    }

    /// @notice Accepts the one-time operator nomination used while wiring the CoinDAO deployment.
    /// @dev This function cannot nominate or hand the operator role to another address.
    function acceptLenderOperator() external onlyOwner {
        lender.acceptOperator();
    }

    function distribute() external override returns (uint256 treasuryAmount, uint256 govStakingAmount) {
        lender.pullLocalReserves();

        uint256 amount = coin.balanceOf(address(this));
        if (govStaking.totalSupply() != 0) {
            govStakingAmount = (amount * govStakingBps) / MAX_BPS;
        }
        treasuryAmount = amount - govStakingAmount;

        if (govStakingAmount != 0) {
            coin.safeTransfer(address(govStaking), govStakingAmount);
            govStaking.notifyRewardAmount(govStakingAmount);
        }
        if (treasuryAmount != 0) {
            coin.safeTransfer(treasury, treasuryAmount);
        }

        emit RevenueDistributed(amount, treasuryAmount, govStakingAmount);
    }

    function setGovStakingBps(uint16 newGovStakingBps) external onlyOwner {
        if (newGovStakingBps > MAX_BPS) revert InvalidGovStakingBps(newGovStakingBps);
        emit GovStakingBpsUpdated(govStakingBps, newGovStakingBps);
        govStakingBps = newGovStakingBps;
    }

    function setManager(address newManager) external onlyOwner {
        if (newManager == address(0)) revert ZeroAddress();
        lender.setManager(newManager);
        emit ManagerUpdated(newManager);
    }

    /// @notice Sets the Lender's local reserve fee, including after immutability.
    /// @dev The Lender accrues interest before applying the fee, enforces its 1,000 bps cap, and emits the update.
    function setLocalReserveFeeBps(uint256 newFeeBps) external onlyOwner {
        lender.setLocalReserveFeeBps(newFeeBps);
    }

    /// @notice Permanently freezes the Lender's deadline-gated parameters at the execution timestamp.
    /// @dev The Lender requires execution before its current deadline and emits the update. This freezes
    /// half-life, target debt ratio, and borrowing rounding-limit changes; local reserve fees remain adjustable.
    function enableImmutabilityNow() external onlyOwner {
        lender.enableImmutabilityNow();
    }
}
