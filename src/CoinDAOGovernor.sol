// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {GovernorUpgradeable} from "@openzeppelin/contracts-upgradeable/governance/GovernorUpgradeable.sol";
import {
    TimelockControllerUpgradeable
} from "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";
import {
    GovernorCountingSimpleUpgradeable
} from "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorCountingSimpleUpgradeable.sol";
import {
    GovernorSettingsUpgradeable
} from "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorSettingsUpgradeable.sol";
import {
    GovernorTimelockControlUpgradeable
} from "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorTimelockControlUpgradeable.sol";
import {
    GovernorVotesUpgradeable
} from "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorVotesUpgradeable.sol";
import {
    GovernorVotesQuorumFractionUpgradeable
} from "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorVotesQuorumFractionUpgradeable.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {GOV_TOKEN_SUPPLY as FIXED_GOV_TOKEN_SUPPLY} from "./GovToken.sol";

contract CoinDAOGovernor is
    GovernorUpgradeable,
    GovernorSettingsUpgradeable,
    GovernorCountingSimpleUpgradeable,
    GovernorVotesQuorumFractionUpgradeable,
    GovernorTimelockControlUpgradeable
{
    uint48 public constant DEFAULT_VOTING_DELAY_BLOCKS = 7_200;
    uint32 public constant DEFAULT_VOTING_PERIOD_BLOCKS = 36_000;

    error ERC5805FutureLookup(uint256 timepoint, uint48 clock);

    constructor() {
        _disableInitializers();
    }

    function initialize(
        string memory name_,
        IVotes token_,
        TimelockControllerUpgradeable timelock_,
        uint256 proposalThreshold_,
        uint256 quorumNumerator_
    ) external initializer {
        __Governor_init(name_);
        __GovernorSettings_init(DEFAULT_VOTING_DELAY_BLOCKS, DEFAULT_VOTING_PERIOD_BLOCKS, proposalThreshold_);
        __GovernorCountingSimple_init();
        // Quorum initialization checkpoints against the voting token's clock.
        __GovernorVotes_init(token_);
        __GovernorVotesQuorumFraction_init(quorumNumerator_);
        __GovernorTimelockControl_init(timelock_);
    }

    function votingDelay() public view override(GovernorUpgradeable, GovernorSettingsUpgradeable) returns (uint256) {
        return super.votingDelay();
    }

    function votingPeriod() public view override(GovernorUpgradeable, GovernorSettingsUpgradeable) returns (uint256) {
        return super.votingPeriod();
    }

    function proposalThreshold()
        public
        view
        override(GovernorUpgradeable, GovernorSettingsUpgradeable)
        returns (uint256)
    {
        return super.proposalThreshold();
    }

    function state(uint256 proposalId)
        public
        view
        override(GovernorUpgradeable, GovernorTimelockControlUpgradeable)
        returns (ProposalState)
    {
        return super.state(proposalId);
    }

    function proposalNeedsQueuing(uint256 proposalId)
        public
        view
        override(GovernorUpgradeable, GovernorTimelockControlUpgradeable)
        returns (bool)
    {
        return super.proposalNeedsQueuing(proposalId);
    }

    function quorum(uint256 timepoint)
        public
        view
        override(GovernorUpgradeable, GovernorVotesQuorumFractionUpgradeable)
        returns (uint256)
    {
        uint48 currentTimepoint = clock();
        if (timepoint >= currentTimepoint) revert ERC5805FutureLookup(timepoint, currentTimepoint);
        return Math.mulDiv(FIXED_GOV_TOKEN_SUPPLY, quorumNumerator(timepoint), quorumDenominator());
    }

    function quorumDenominator() public pure override returns (uint256) {
        return 1_000;
    }

    function _queueOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(GovernorUpgradeable, GovernorTimelockControlUpgradeable) returns (uint48) {
        return super._queueOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _executeOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(GovernorUpgradeable, GovernorTimelockControlUpgradeable) {
        super._executeOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(GovernorUpgradeable, GovernorTimelockControlUpgradeable) returns (uint256) {
        return super._cancel(targets, values, calldatas, descriptionHash);
    }

    function _executor()
        internal
        view
        override(GovernorUpgradeable, GovernorTimelockControlUpgradeable)
        returns (address)
    {
        return super._executor();
    }
}
