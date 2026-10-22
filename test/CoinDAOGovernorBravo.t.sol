// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";

import {CoinDAOFactory} from "../src/CoinDAOFactory.sol";
import {CoinDAOGovernor} from "../src/CoinDAOGovernor.sol";
import {CoinDAOTimelock} from "../src/CoinDAOTimelock.sol";
import {StakedGovToken} from "../src/StakedGovToken.sol";
import {CoinDAOTestBase} from "./helpers/CoinDAOTestBase.sol";

contract CoinDAOGovernorBravoTest is CoinDAOTestBase {
    address internal constant PROPOSER = address(0xA11CE);
    address internal constant OTHER = address(0xB0B);

    function testOnePendingOrActiveProposalPerProposer() public {
        (CoinDAOFactory.Deployment memory deployment, CoinDAOGovernor governor) = _deployWithProposer();
        _stakeGov(deployment, OTHER, governor.proposalThreshold());
        vm.roll(governor.clock() + 1);
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _actions();

        uint256 firstId = _propose(governor, PROPOSER, targets, values, calldatas, "First");
        assertEq(governor.latestProposalIds(PROPOSER), firstId);
        vm.prank(PROPOSER);
        vm.expectRevert(
            abi.encodeWithSelector(CoinDAOGovernor.GovernorProposerHasLiveProposal.selector, PROPOSER, firstId)
        );
        governor.propose(targets, values, calldatas, "Second");

        uint256 otherId = _propose(governor, OTHER, targets, values, calldatas, "Other proposer");
        assertEq(governor.latestProposalIds(OTHER), otherId);
        vm.roll(governor.proposalSnapshot(firstId) + 1);
        assertEq(uint256(governor.state(firstId)), uint256(IGovernor.ProposalState.Active));
        vm.prank(PROPOSER);
        vm.expectRevert(
            abi.encodeWithSelector(CoinDAOGovernor.GovernorProposerHasLiveProposal.selector, PROPOSER, firstId)
        );
        governor.propose(targets, values, calldatas, "Second");

        vm.prank(PROPOSER);
        governor.castVote(firstId, 1);
        vm.roll(governor.proposalDeadline(firstId) + 1);
        assertEq(uint256(governor.state(firstId)), uint256(IGovernor.ProposalState.Succeeded));
        uint256 secondId = _propose(governor, PROPOSER, targets, values, calldatas, "Second");
        assertEq(governor.latestProposalIds(PROPOSER), secondId);
    }

    function testCanceledAndDefeatedProposalsReleaseProposer() public {
        (, CoinDAOGovernor governor) = _deployWithProposer();
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _actions();
        uint256 firstId = _propose(governor, PROPOSER, targets, values, calldatas, "Cancel me");

        vm.prank(PROPOSER);
        governor.cancel(targets, values, calldatas, keccak256("Cancel me"));
        assertEq(uint256(governor.state(firstId)), uint256(IGovernor.ProposalState.Canceled));
        uint256 secondId = _propose(governor, PROPOSER, targets, values, calldatas, "Defeat me");
        vm.roll(governor.proposalDeadline(secondId) + 1);
        assertEq(uint256(governor.state(secondId)), uint256(IGovernor.ProposalState.Defeated));
        uint256 thirdId = _propose(governor, PROPOSER, targets, values, calldatas, "Third");
        assertEq(governor.latestProposalIds(PROPOSER), thirdId);
    }

    function testThirdPartyCancellationUsesPriorDelegatedVotes() public {
        (CoinDAOFactory.Deployment memory deployment, CoinDAOGovernor governor) = _deployWithProposer();
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _actions();
        uint256 proposalId = _propose(governor, PROPOSER, targets, values, calldatas, "Pending");
        bytes32 descriptionHash = keccak256("Pending");
        assertEq(governor.getVotes(PROPOSER, governor.clock() - 1), governor.proposalThreshold());

        vm.prank(OTHER);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorUnableToCancel.selector, proposalId, OTHER));
        governor.cancel(targets, values, calldatas, descriptionHash);

        vm.prank(PROPOSER);
        StakedGovToken(deployment.staker).delegate(address(0));
        assertEq(StakedGovToken(deployment.staker).balanceOf(PROPOSER), governor.proposalThreshold());
        vm.prank(OTHER);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorUnableToCancel.selector, proposalId, OTHER));
        governor.cancel(targets, values, calldatas, descriptionHash);

        vm.roll(governor.clock() + 1);
        assertEq(governor.getVotes(PROPOSER, governor.clock() - 1), 0);
        vm.prank(OTHER);
        governor.cancel(targets, values, calldatas, descriptionHash);
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Canceled));
    }

    function testThirdPartyCanCancelActiveAndQueuedProposals() public {
        (CoinDAOFactory.Deployment memory deployment, CoinDAOGovernor governor) = _deployWithProposer();
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _actions();
        StakedGovToken staker = StakedGovToken(deployment.staker);
        uint256 activeId = _propose(governor, PROPOSER, targets, values, calldatas, "Active");
        vm.roll(governor.proposalSnapshot(activeId) + 1);
        vm.prank(PROPOSER);
        staker.delegate(address(0));
        vm.roll(governor.clock() + 1);
        assertEq(uint256(governor.state(activeId)), uint256(IGovernor.ProposalState.Active));
        vm.prank(OTHER);
        governor.cancel(targets, values, calldatas, keccak256("Active"));
        assertEq(uint256(governor.state(activeId)), uint256(IGovernor.ProposalState.Canceled));

        vm.prank(PROPOSER);
        staker.delegate(PROPOSER);
        vm.roll(governor.clock() + 1);
        uint256 queuedId = _propose(governor, PROPOSER, targets, values, calldatas, "Queued");
        vm.roll(governor.proposalSnapshot(queuedId) + 1);
        vm.prank(PROPOSER);
        governor.castVote(queuedId, 1);
        vm.roll(governor.proposalDeadline(queuedId) + 1);
        bytes32 descriptionHash = keccak256("Queued");
        governor.queue(targets, values, calldatas, descriptionHash);
        CoinDAOTimelock timelock = CoinDAOTimelock(payable(deployment.timelock));
        bytes32 operationId =
            timelock.hashOperationBatch(targets, values, calldatas, 0, bytes20(address(governor)) ^ descriptionHash);
        assertTrue(timelock.isOperationPending(operationId));

        vm.prank(PROPOSER);
        staker.delegate(address(0));
        vm.roll(governor.clock() + 1);
        vm.prank(OTHER);
        governor.cancel(targets, values, calldatas, descriptionHash);
        assertEq(uint256(governor.state(queuedId)), uint256(IGovernor.ProposalState.Canceled));
        assertFalse(timelock.isOperation(operationId));
    }

    function testProposerCanCancelAfterVotingStartsAndAfterQueueing() public {
        (CoinDAOFactory.Deployment memory deployment, CoinDAOGovernor governor) = _deployWithProposer();
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _actions();
        uint256 activeId = _propose(governor, PROPOSER, targets, values, calldatas, "Active self-cancel");
        vm.roll(governor.proposalSnapshot(activeId) + 1);
        vm.prank(PROPOSER);
        governor.cancel(targets, values, calldatas, keccak256("Active self-cancel"));
        assertEq(uint256(governor.state(activeId)), uint256(IGovernor.ProposalState.Canceled));

        uint256 queuedId = _propose(governor, PROPOSER, targets, values, calldatas, "Queued self-cancel");
        vm.roll(governor.proposalSnapshot(queuedId) + 1);
        vm.prank(PROPOSER);
        governor.castVote(queuedId, 1);
        vm.roll(governor.proposalDeadline(queuedId) + 1);
        bytes32 descriptionHash = keccak256("Queued self-cancel");
        governor.queue(targets, values, calldatas, descriptionHash);
        CoinDAOTimelock timelock = CoinDAOTimelock(payable(deployment.timelock));
        bytes32 operationId =
            timelock.hashOperationBatch(targets, values, calldatas, 0, bytes20(address(governor)) ^ descriptionHash);
        assertTrue(timelock.isOperationPending(operationId));

        vm.prank(PROPOSER);
        governor.cancel(targets, values, calldatas, descriptionHash);
        assertEq(uint256(governor.state(queuedId)), uint256(IGovernor.ProposalState.Canceled));
        assertFalse(timelock.isOperation(operationId));
        vm.prank(PROPOSER);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorUnableToCancel.selector, queuedId, PROPOSER));
        governor.cancel(targets, values, calldatas, descriptionHash);
    }

    function testThirdPartyCanCancelSucceededProposal() public {
        (CoinDAOFactory.Deployment memory deployment, CoinDAOGovernor governor) = _deployWithProposer();
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _actions();
        uint256 proposalId = _propose(governor, PROPOSER, targets, values, calldatas, "Succeeded");
        vm.roll(governor.proposalSnapshot(proposalId) + 1);
        vm.prank(PROPOSER);
        governor.castVote(proposalId, 1);
        vm.roll(governor.proposalDeadline(proposalId) + 1);
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Succeeded));

        vm.prank(PROPOSER);
        StakedGovToken(deployment.staker).delegate(address(0));
        vm.roll(governor.clock() + 1);
        vm.prank(OTHER);
        governor.cancel(targets, values, calldatas, keccak256("Succeeded"));
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Canceled));
    }

    function testExecutedProposalCannotBeCanceled() public {
        (CoinDAOFactory.Deployment memory deployment, CoinDAOGovernor governor) = _deployWithProposer();
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _actions();
        uint256 proposalId = _propose(governor, PROPOSER, targets, values, calldatas, "Execute");
        vm.roll(governor.proposalSnapshot(proposalId) + 1);
        vm.prank(PROPOSER);
        governor.castVote(proposalId, 1);
        vm.roll(governor.proposalDeadline(proposalId) + 1);
        bytes32 descriptionHash = keccak256("Execute");
        governor.queue(targets, values, calldatas, descriptionHash);
        vm.warp(governor.proposalEta(proposalId));
        governor.execute(targets, values, calldatas, descriptionHash);
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Executed));

        vm.prank(PROPOSER);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorUnableToCancel.selector, proposalId, PROPOSER));
        governor.cancel(targets, values, calldatas, descriptionHash);
        vm.prank(PROPOSER);
        StakedGovToken(deployment.staker).delegate(address(0));
        vm.roll(governor.clock() + 1);
        vm.prank(OTHER);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorUnableToCancel.selector, proposalId, OTHER));
        governor.cancel(targets, values, calldatas, descriptionHash);
    }

    function testCancellationUsesCurrentGovernanceThreshold() public {
        (, CoinDAOGovernor governor) = _deployWithProposer();
        uint256 originalThreshold = governor.proposalThreshold();
        address[] memory settingsTargets = new address[](1);
        settingsTargets[0] = address(governor);
        uint256[] memory settingsValues = new uint256[](1);
        bytes[] memory settingsCalldatas = new bytes[](1);
        settingsCalldatas[0] = abi.encodeCall(governor.setProposalThreshold, (2 * originalThreshold));
        uint256 settingsId =
            _propose(governor, PROPOSER, settingsTargets, settingsValues, settingsCalldatas, "Raise threshold");
        vm.roll(governor.proposalSnapshot(settingsId) + 1);
        vm.prank(PROPOSER);
        governor.castVote(settingsId, 1);
        vm.roll(governor.proposalDeadline(settingsId) + 1);
        bytes32 settingsDescriptionHash = keccak256("Raise threshold");
        governor.queue(settingsTargets, settingsValues, settingsCalldatas, settingsDescriptionHash);

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _actions();
        uint256 pendingId = _propose(governor, PROPOSER, targets, values, calldatas, "Pending under new threshold");
        vm.warp(governor.proposalEta(settingsId));
        governor.execute(settingsTargets, settingsValues, settingsCalldatas, settingsDescriptionHash);
        assertEq(governor.proposalThreshold(), 2 * originalThreshold);
        assertEq(uint256(governor.state(pendingId)), uint256(IGovernor.ProposalState.Pending));

        vm.prank(OTHER);
        governor.cancel(targets, values, calldatas, keccak256("Pending under new threshold"));
        assertEq(uint256(governor.state(pendingId)), uint256(IGovernor.ProposalState.Canceled));
    }

    function _deployWithProposer()
        internal
        returns (CoinDAOFactory.Deployment memory deployment, CoinDAOGovernor governor)
    {
        deployment = _deploy(0, CoinDAOFactory.StakingTokenChoice.Coin);
        governor = CoinDAOGovernor(payable(deployment.governor));
        _stakeGov(deployment, PROPOSER, governor.proposalThreshold());
        vm.roll(governor.clock() + 1);
    }

    function _actions()
        internal
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas)
    {
        targets = new address[](1);
        targets[0] = address(0xBEEF);
        values = new uint256[](1);
        calldatas = new bytes[](1);
    }

    function _propose(
        CoinDAOGovernor governor,
        address proposer,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) internal returns (uint256) {
        vm.prank(proposer);
        return governor.propose(targets, values, calldatas, description);
    }
}
