pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {GovToken} from "../../src/GovToken.sol";
import {StakedGovToken} from "../../src/StakedGovToken.sol";
import {StakingRewards} from "../../src/StakingRewards.sol";
import {StakingRewardsFunder} from "../../src/StakingRewardsFunder.sol";

abstract contract CloneTestUtils {
    function _newGovToken(string memory name_, string memory symbol_, address holder)
        internal
        returns (GovToken token)
    {
        token = GovToken(Clones.clone(address(new GovToken())));
        token.initialize(name_, symbol_, holder);
    }

    function _newStakedGovToken(
        IERC20 govToken,
        IERC20 rewardsToken,
        string memory name_,
        string memory symbol_,
        address rewardsDistribution,
        uint256 rewardsDuration
    ) internal returns (StakedGovToken token) {
        token = StakedGovToken(Clones.clone(address(new StakedGovToken())));
        token.initialize(govToken, rewardsToken, name_, symbol_, rewardsDistribution, rewardsDuration);
    }

    function _newStakingRewards(address stakingToken, address rewardsToken, address owner, uint256 rewardsDuration)
        internal
        returns (StakingRewards rewards)
    {
        rewards = StakingRewards(Clones.clone(address(new StakingRewards())));
        rewards.initialize(stakingToken, rewardsToken, owner, rewardsDuration);
    }

    function _newStakingRewardsFunder(StakingRewards rewards, uint256 totalRewards)
        internal
        returns (StakingRewardsFunder funder)
    {
        funder = StakingRewardsFunder(Clones.clone(address(new StakingRewardsFunder())));
        funder.initialize(rewards, totalRewards);
    }
}
