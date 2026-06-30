// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IMonolithLender} from "./interfaces/IMonolith.sol";
import {INotifiableRewardReceiver} from "./interfaces/INotifiableRewardReceiver.sol";

contract RevenueRouter is Ownable {
    using SafeERC20 for IERC20;

    uint16 public constant MAX_BPS = 10_000;

    IMonolithLender public immutable lender;
    IERC20 public immutable coin;
    address public immutable treasury;
    INotifiableRewardReceiver public immutable govStaking;
    uint16 public govStakingBps;

    event GovStakingBpsUpdated(uint16 oldGovStakingBps, uint16 newGovStakingBps);
    event RevenueDistributed(uint256 totalAmount, uint256 treasuryAmount, uint256 govStakingAmount);
    event ManagerUpdated(address indexed newManager);

    error ZeroAddress();
    error InvalidGovStakingBps(uint16 govStakingBps);

    constructor(
        address lender_,
        address coin_,
        address treasury_,
        address govStaking_,
        uint16 govStakingBps_,
        address owner_
    ) Ownable(owner_) {
        if (
            lender_ == address(0) || coin_ == address(0) || treasury_ == address(0) || govStaking_ == address(0)
                || owner_ == address(0)
        ) revert ZeroAddress();
        if (govStakingBps_ > MAX_BPS) revert InvalidGovStakingBps(govStakingBps_);

        lender = IMonolithLender(lender_);
        coin = IERC20(coin_);
        treasury = treasury_;
        govStaking = INotifiableRewardReceiver(govStaking_);
        govStakingBps = govStakingBps_;
    }

    function acceptLenderOperator() external onlyOwner {
        lender.acceptOperator();
    }

    function distribute() external returns (uint256 treasuryAmount, uint256 govStakingAmount) {
        uint256 amount = coin.balanceOf(address(this));
        govStakingAmount = (amount * govStakingBps) / MAX_BPS;
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
}
