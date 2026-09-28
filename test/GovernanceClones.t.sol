// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {
    TimelockControllerUpgradeable
} from "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";

import {CoinDAOFactory} from "../src/CoinDAOFactory.sol";
import {CoinDAOGovernor} from "../src/CoinDAOGovernor.sol";
import {CoinDAOTimelock} from "../src/CoinDAOTimelock.sol";
import {CoinDAOTestBase} from "./helpers/CoinDAOTestBase.sol";

contract TimestampClockVotes {
    function clock() external view returns (uint48) {
        return uint48(block.timestamp);
    }
}

contract GovernanceClonesTest is CoinDAOTestBase {
    function testQuorumInitializationUsesVotingTokenClock() public {
        uint256 initializedAt = 10 days;
        vm.warp(initializedAt);
        TimestampClockVotes token = new TimestampClockVotes();
        CoinDAOGovernor governor = CoinDAOGovernor(payable(Clones.clone(implementationSet.governor)));
        governor.initialize("Timestamp governance", IVotes(address(token)), CoinDAOTimelock(payable(address(1))), 1, 1);

        assertEq(governor.clock(), initializedAt);
        assertEq(governor.quorumNumerator(initializedAt - 1), 0);
        assertEq(governor.quorumNumerator(initializedAt), 1);
        vm.warp(initializedAt + 1);
        assertEq(governor.quorum(initializedAt), factory.GOV_TOKEN_SUPPLY() / 1_000);
    }

    function testGovernanceSettingsRolesAndHistoryAreIndependent() public {
        CoinDAOFactory.Deployment memory first = _deploy(0, CoinDAOFactory.StakingTokenChoice.Coin);
        CoinDAOFactory.GovLaunchParams memory params = _govParams(0, CoinDAOFactory.StakingTokenChoice.Coin);
        params.govTokenName = "Another governance token with a long name";
        CoinDAOFactory.Deployment memory second = factory.deploy(_nextSalt(), params, _monolithParams(), manager);
        CoinDAOGovernor governor = CoinDAOGovernor(payable(first.governor));
        CoinDAOGovernor other = CoinDAOGovernor(payable(second.governor));
        CoinDAOTimelock timelock = CoinDAOTimelock(payable(first.timelock));
        CoinDAOTimelock otherTimelock = CoinDAOTimelock(payable(second.timelock));
        uint256 initializedAt = governor.clock();

        _assertDomain(governor, "Example GOV Governor");
        _assertDomain(other, string.concat(params.govTokenName, " Governor"));
        assertEq(address(governor.token()), first.staker);
        assertEq(address(other.token()), second.staker);
        assertEq(governor.timelock(), first.timelock);
        assertEq(other.timelock(), second.timelock);
        _assertRoles(first, second);
        _assertRoles(second, first);

        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorOnlyExecutor.selector, address(this)));
        governor.setVotingPeriod(456);
        vm.expectRevert(
            abi.encodeWithSelector(TimelockControllerUpgradeable.TimelockUnauthorizedCaller.selector, address(this))
        );
        timelock.updateDelay(3 days);

        address[] memory targets = new address[](5);
        uint256[] memory values = new uint256[](5);
        bytes[] memory calldatas = new bytes[](5);
        for (uint256 i; i < 4; ++i) {
            targets[i] = first.governor;
        }
        targets[4] = first.timelock;
        calldatas[0] = abi.encodeCall(governor.updateQuorumNumerator, (2));
        calldatas[1] = abi.encodeCall(governor.setVotingDelay, (123));
        calldatas[2] = abi.encodeCall(governor.setVotingPeriod, (456));
        calldatas[3] = abi.encodeCall(governor.setProposalThreshold, (2 * factory.GOVERNOR_PROPOSAL_THRESHOLD()));
        calldatas[4] = abi.encodeCall(timelock.updateDelay, (3 days));
        _stakeGov(first, address(this), governor.proposalThreshold());
        vm.roll(governor.clock() + 1);
        string memory description = "Update this DAO's governance settings";
        bytes32 descriptionHash = keccak256(bytes(description));
        uint256 proposalId = governor.propose(targets, values, calldatas, description);
        vm.roll(governor.proposalSnapshot(proposalId) + 1);
        governor.castVote(proposalId, 1);
        vm.roll(governor.proposalDeadline(proposalId) + 1);
        governor.queue(targets, values, calldatas, descriptionHash);
        bytes32 operationId =
            timelock.hashOperationBatch(targets, values, calldatas, 0, bytes20(first.governor) ^ descriptionHash);
        assertTrue(timelock.isOperationPending(operationId));
        assertFalse(otherTimelock.isOperation(operationId));
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorNonexistentProposal.selector, proposalId));
        other.state(proposalId);

        vm.warp(governor.proposalEta(proposalId) - 1);
        vm.expectPartialRevert(TimelockControllerUpgradeable.TimelockUnexpectedOperationState.selector);
        governor.execute(targets, values, calldatas, descriptionHash);
        vm.warp(governor.proposalEta(proposalId));
        governor.execute(targets, values, calldatas, descriptionHash);
        // Read the contract's clock across rolls; via IR may cache block.number in the test frame.
        uint256 updatedAt = governor.clock();
        vm.roll(updatedAt + 1);

        assertTrue(timelock.isOperationDone(operationId));
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Executed));
        assertEq(governor.quorumNumerator(initializedAt), 1);
        assertEq(governor.quorumNumerator(updatedAt), 2);
        assertEq(other.quorumNumerator(updatedAt), 1);
        assertEq(governor.votingDelay(), 123);
        assertEq(governor.votingPeriod(), 456);
        assertEq(governor.proposalThreshold(), 2 * factory.GOVERNOR_PROPOSAL_THRESHOLD());
        assertEq(timelock.getMinDelay(), 3 days);
        assertEq(other.votingDelay(), other.DEFAULT_VOTING_DELAY_BLOCKS());
        assertEq(other.votingPeriod(), other.DEFAULT_VOTING_PERIOD_BLOCKS());
        assertEq(other.proposalThreshold(), factory.GOVERNOR_PROPOSAL_THRESHOLD());
        assertEq(otherTimelock.getMinDelay(), factory.DEFAULT_TIMELOCK_DELAY());
    }

    function testSignatureVotesCannotReplayAcrossClonesWithSameNameAndProposal() public {
        uint256 voterKey = 0xA11CE;
        address voter = vm.addr(voterKey);
        (CoinDAOGovernor first, CoinDAOGovernor second, uint256 proposalId) = _matchingProposals(voter);
        _assertDomain(first, "Example GOV Governor");
        _assertDomain(second, "Example GOV Governor");
        vm.roll(first.proposalSnapshot(proposalId) + 1);

        bytes memory signature = _signVote(first, voterKey, proposalId);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorInvalidSignature.selector, voter));
        second.castVoteBySig(proposalId, 1, voter, signature);
        assertFalse(second.hasVoted(proposalId, voter));
        assertEq(second.nonces(voter), 0);

        assertEq(first.castVoteBySig(proposalId, 1, voter, signature), first.proposalThreshold());
        assertTrue(first.hasVoted(proposalId, voter));
        assertEq(first.nonces(voter), 1);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorInvalidSignature.selector, voter));
        first.castVoteBySig(proposalId, 1, voter, signature);

        assertEq(
            second.castVoteBySig(proposalId, 1, voter, _signVote(second, voterKey, proposalId)),
            second.proposalThreshold()
        );
        assertTrue(second.hasVoted(proposalId, voter));
    }

    function testProposerCancellationOnlyAffectsItsOwnClone() public {
        address proposer = address(0xA11CE);
        (CoinDAOGovernor first, CoinDAOGovernor second, uint256 proposalId) = _matchingProposals(proposer);
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _matchingActions();
        bytes32 descriptionHash = keccak256("Same proposal");

        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorUnableToCancel.selector, proposalId, address(this)));
        first.cancel(targets, values, calldatas, descriptionHash);
        vm.prank(proposer);
        first.cancel(targets, values, calldatas, descriptionHash);
        assertEq(uint256(first.state(proposalId)), uint256(IGovernor.ProposalState.Canceled));
        assertEq(uint256(second.state(proposalId)), uint256(IGovernor.ProposalState.Pending));
    }

    function _matchingProposals(address voter)
        internal
        returns (CoinDAOGovernor first, CoinDAOGovernor second, uint256 proposalId)
    {
        CoinDAOFactory.Deployment memory firstDAO = _deploy(0, CoinDAOFactory.StakingTokenChoice.Coin);
        CoinDAOFactory.Deployment memory secondDAO = _deploy(0, CoinDAOFactory.StakingTokenChoice.Coin);
        first = CoinDAOGovernor(payable(firstDAO.governor));
        second = CoinDAOGovernor(payable(secondDAO.governor));
        _stakeGov(firstDAO, voter, first.proposalThreshold());
        _stakeGov(secondDAO, voter, second.proposalThreshold());
        vm.roll(block.number + 1);
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _matchingActions();
        vm.prank(voter);
        proposalId = first.propose(targets, values, calldatas, "Same proposal");
        vm.prank(voter);
        uint256 secondId = second.propose(targets, values, calldatas, "Same proposal");
        assertEq(proposalId, secondId);
    }

    function _matchingActions()
        internal
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas)
    {
        targets = new address[](1);
        targets[0] = address(0xBEEF);
        values = new uint256[](1);
        calldatas = new bytes[](1);
        calldatas[0] = hex"12345678";
    }

    function _signVote(CoinDAOGovernor governor, uint256 key, uint256 proposalId) internal view returns (bytes memory) {
        address voter = vm.addr(key);
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(governor.name())),
                keccak256(bytes(governor.version())),
                block.chainid,
                address(governor)
            )
        );
        bytes32 ballot =
            keccak256(abi.encode(governor.BALLOT_TYPEHASH(), proposalId, uint8(1), voter, governor.nonces(voter)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, keccak256(abi.encodePacked(hex"1901", domainSeparator, ballot)));
        return abi.encodePacked(r, s, v);
    }

    function _assertDomain(CoinDAOGovernor governor, string memory expectedName) internal view {
        (bytes1 fields, string memory name, string memory version, uint256 chainId, address verifyingContract,,) =
            governor.eip712Domain();
        assertEq(fields, hex"0f");
        assertEq(name, expectedName);
        assertEq(governor.name(), expectedName);
        assertEq(version, "1");
        assertEq(chainId, block.chainid);
        assertEq(verifyingContract, address(governor));
    }

    function _assertRoles(CoinDAOFactory.Deployment memory deployment, CoinDAOFactory.Deployment memory other)
        internal
    {
        CoinDAOTimelock timelock = CoinDAOTimelock(payable(deployment.timelock));
        assertEq(timelock.getMinDelay(), factory.DEFAULT_TIMELOCK_DELAY());
        assertTrue(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), deployment.timelock));
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), deployment.governor));
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), deployment.governor));
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0)));
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(factory)));
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(this)));
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), other.timelock));
        assertFalse(timelock.hasRole(timelock.PROPOSER_ROLE(), other.governor));
        assertFalse(timelock.hasRole(timelock.CANCELLER_ROLE(), other.governor));
        bytes32 proposerRole = timelock.PROPOSER_ROLE();
        uint256 delay = factory.DEFAULT_TIMELOCK_DELAY();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, other.governor, proposerRole
            )
        );
        vm.prank(other.governor);
        timelock.schedule(address(0xBEEF), 0, "", 0, 0, delay);
    }
}
