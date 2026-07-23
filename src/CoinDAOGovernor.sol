// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.26;

import {Governor} from "@openzeppelin/contracts/governance/Governor.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {GovernorCountingSimple} from "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import {GovernorSettings} from "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";
import {GovernorTimelockControl} from "@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol";
import {GovernorVotes} from "@openzeppelin/contracts/governance/extensions/GovernorVotes.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import {GOV_TOKEN_SUPPLY} from "./GovToken.sol";

contract CoinDAOGovernor is Governor, GovernorSettings, GovernorCountingSimple, GovernorVotes, GovernorTimelockControl {
    uint48 public constant DEFAULT_VOTING_DELAY_BLOCKS = 7_200;
    uint32 public constant DEFAULT_VOTING_PERIOD_BLOCKS = 36_000;
    /// @dev Absolute number of GOV token votes needed to reach quorum.
    uint256 private _quorum;

    event QuorumSet(uint256 oldQuorum, uint256 newQuorum);

    error InvalidQuorum(uint256 quorum);

    constructor(
        string memory name_,
        IVotes token_,
        TimelockController timelock_,
        uint256 proposalThreshold_,
        uint256 quorum_
    )
        Governor(name_)
        GovernorSettings(DEFAULT_VOTING_DELAY_BLOCKS, DEFAULT_VOTING_PERIOD_BLOCKS, proposalThreshold_)
        GovernorVotes(token_)
        GovernorTimelockControl(timelock_)
    {
        if (quorum_ == 0 || quorum_ > GOV_TOKEN_SUPPLY) revert InvalidQuorum(quorum_);
        _quorum = quorum_;
        emit QuorumSet(0, quorum_);
    }

    function votingDelay() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.votingDelay();
    }

    function votingPeriod() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.votingPeriod();
    }

    function proposalThreshold() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.proposalThreshold();
    }

    function state(uint256 proposalId) public view override(Governor, GovernorTimelockControl) returns (ProposalState) {
        return super.state(proposalId);
    }

    function proposalNeedsQueuing(uint256 proposalId)
        public
        view
        override(Governor, GovernorTimelockControl)
        returns (bool)
    {
        return super.proposalNeedsQueuing(proposalId);
    }

    function quorum(uint256) public view override returns (uint256) {
        return _quorum;
    }

    function setQuorum(uint256 newQuorum) external onlyGovernance {
        if (newQuorum == 0 || newQuorum > GOV_TOKEN_SUPPLY) revert InvalidQuorum(newQuorum);

        emit QuorumSet(_quorum, newQuorum);
        _quorum = newQuorum;
    }

    function _queueOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint48) {
        return super._queueOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _executeOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) {
        super._executeOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint256) {
        return super._cancel(targets, values, calldatas, descriptionHash);
    }

    function _executor() internal view override(Governor, GovernorTimelockControl) returns (address) {
        return super._executor();
    }
}
