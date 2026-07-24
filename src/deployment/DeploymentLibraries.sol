// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {VestingWallet} from "@openzeppelin/contracts/finance/VestingWallet.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import {CoinDAOGovernor} from "../CoinDAOGovernor.sol";
import {GovToken} from "../GovToken.sol";
import {RevenueRouter} from "../RevenueRouter.sol";
import {StakedGovToken} from "../StakedGovToken.sol";
import {StakingRewards} from "../StakingRewards.sol";
import {StakingRewardsFunder} from "../StakingRewardsFunder.sol";

/// @dev External library calls execute with DELEGATECALL, so contracts created
/// here are created by the calling CoinDAOFactory rather than by the library.
library CoreDeploymentLib {
    function deployGovToken(string calldata name_, string calldata symbol_, address initialHolder)
        external
        returns (address)
    {
        return address(new GovToken(name_, symbol_, initialHolder));
    }

    function deployTimelock(uint256 minDelay, address[] memory proposers, address[] memory executors, address admin)
        external
        returns (address)
    {
        return address(new TimelockController(minDelay, proposers, executors, admin));
    }

    function deployVestingWallet(address beneficiary, uint64 startTimestamp, uint64 durationSeconds)
        external
        returns (address)
    {
        return address(new VestingWallet(beneficiary, startTimestamp, durationSeconds));
    }
}

library StakingDeploymentLib {
    function deployStakedGovToken(
        IERC20 govToken_,
        IERC20 rewardsToken_,
        string calldata name_,
        string calldata symbol_,
        address rewardsDistribution_,
        uint256 rewardsDuration_
    ) external returns (address) {
        return address(
            new StakedGovToken(govToken_, rewardsToken_, name_, symbol_, rewardsDistribution_, rewardsDuration_)
        );
    }

    function deployRevenueRouter(
        address lender_,
        address coin_,
        address treasury_,
        address govStaking_,
        uint16 govStakingBps_,
        address owner_
    ) external returns (address) {
        return address(new RevenueRouter(lender_, coin_, treasury_, govStaking_, govStakingBps_, owner_));
    }
}

library GovernorDeploymentLib {
    function deployGovernor(
        string calldata name_,
        IVotes token_,
        TimelockController timelock_,
        uint256 proposalThreshold_,
        uint256 quorum_
    ) external returns (address) {
        return address(new CoinDAOGovernor(name_, token_, timelock_, proposalThreshold_, quorum_));
    }
}

library RewardsDeploymentLib {
    function deployStakingRewards(
        address stakingToken_,
        address rewardsToken_,
        address initialOwner_,
        uint256 rewardsDuration_
    ) external returns (address) {
        return address(new StakingRewards(stakingToken_, rewardsToken_, initialOwner_, rewardsDuration_));
    }

    function deployStakingRewardsFunder(StakingRewards stakingRewards_, uint256 totalRewards_)
        external
        returns (address)
    {
        return address(new StakingRewardsFunder(stakingRewards_, totalRewards_));
    }
}
