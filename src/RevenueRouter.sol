// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IStGovTokenRewards {
    function notifyRewardAmount(address rewardToken, uint256 amount) external;
}

interface IMonolithOperatorAcceptor {
    function acceptOperator() external;
}

contract RevenueRouter {
    using SafeERC20 for IERC20;

    uint16 public constant MAX_BPS = 10_000;

    address public immutable lender;
    IERC20 public immutable coin;
    address public immutable treasury;
    IStGovTokenRewards public immutable stGovToken;
    uint16 public revShareBps;

    error Unauthorized();
    error InvalidRevShareBps(uint16 revShareBps);
    error ZeroAddress();

    event RevenueDistributed(uint256 totalAmount, uint256 treasuryAmount, uint256 stGovAmount);
    event RevShareBpsUpdated(uint16 oldRevShareBps, uint16 newRevShareBps);

    constructor(address lender_, IERC20 coin_, address treasury_, IStGovTokenRewards stGovToken_, uint16 revShareBps_) {
        if (
            lender_ == address(0) || address(coin_) == address(0) || treasury_ == address(0)
                || address(stGovToken_) == address(0)
        ) {
            revert ZeroAddress();
        }
        if (revShareBps_ > MAX_BPS) revert InvalidRevShareBps(revShareBps_);

        lender = lender_;
        coin = coin_;
        treasury = treasury_;
        stGovToken = stGovToken_;
        revShareBps = revShareBps_;
    }

    modifier onlyTreasury() {
        if (msg.sender != treasury) revert Unauthorized();
        _;
    }

    function acceptLenderOperator() external {
        IMonolithOperatorAcceptor(lender).acceptOperator();
    }

    function distribute() external returns (uint256 treasuryAmount, uint256 stGovAmount) {
        uint256 balance = coin.balanceOf(address(this));
        stGovAmount = (balance * revShareBps) / MAX_BPS;
        treasuryAmount = balance - stGovAmount;

        if (treasuryAmount > 0) coin.safeTransfer(treasury, treasuryAmount);
        if (stGovAmount > 0) {
            coin.forceApprove(address(stGovToken), stGovAmount);
            stGovToken.notifyRewardAmount(address(coin), stGovAmount);
        }

        emit RevenueDistributed(balance, treasuryAmount, stGovAmount);
    }

    function setRevShareBps(uint16 newRevShareBps) external onlyTreasury {
        if (newRevShareBps > MAX_BPS) revert InvalidRevShareBps(newRevShareBps);

        uint16 oldRevShareBps = revShareBps;
        revShareBps = newRevShareBps;

        emit RevShareBpsUpdated(oldRevShareBps, newRevShareBps);
    }
}
