pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {
    GovernorVotesQuorumFraction
} from "@openzeppelin/contracts/governance/extensions/GovernorVotesQuorumFraction.sol";

import {CoinDAOFactory} from "../src/CoinDAOFactory.sol";
import {CoinDAOGovernor} from "../src/CoinDAOGovernor.sol";
import {StakedGovToken} from "../src/StakedGovToken.sol";
import {CoinDAOTestBase} from "./helpers/CoinDAOTestBase.sol";

contract CoinDAOGovernorTest is CoinDAOTestBase {
    event QuorumNumeratorUpdated(uint256 oldQuorumNumerator, uint256 newQuorumNumerator);

    function testDefaultQuorumUsesFixedGovSupply() public {
        CoinDAOFactory.Deployment memory deployment = _deploy(0, CoinDAOFactory.StakingTokenChoice.Coin);
        CoinDAOGovernor governor = CoinDAOGovernor(payable(deployment.governor));
        StakedGovToken staker = StakedGovToken(deployment.staker);
        uint256 expectedQuorum = factory.GOV_TOKEN_SUPPLY() / governor.quorumDenominator();

        assertEq(governor.quorumNumerator(), factory.GOVERNOR_QUORUM_NUMERATOR());
        assertEq(governor.quorumDenominator(), 1_000);
        assertEq(governor.votingDelay(), governor.DEFAULT_VOTING_DELAY_BLOCKS());
        assertEq(governor.votingPeriod(), governor.DEFAULT_VOTING_PERIOD_BLOCKS());
        assertEq(governor.proposalThreshold(), factory.GOVERNOR_PROPOSAL_THRESHOLD());

        vm.roll(staker.clock() + 1);
        uint256 firstTimepoint = staker.clock() - 1;
        assertEq(staker.getPastTotalSupply(firstTimepoint), 0);
        assertEq(governor.quorum(firstTimepoint), expectedQuorum);

        _stakeGov(deployment, address(0xA11CE), 1_999);
        vm.roll(staker.clock() + 1);
        uint256 secondTimepoint = staker.clock() - 1;
        assertEq(staker.getPastTotalSupply(secondTimepoint), 1_999);
        assertEq(governor.quorum(secondTimepoint), expectedQuorum);

        _stakeGov(deployment, address(0xB0B), 1_001);
        vm.roll(staker.clock() + 1);
        uint256 thirdTimepoint = staker.clock() - 1;
        assertEq(staker.getPastTotalSupply(thirdTimepoint), 3_000);
        assertEq(governor.quorum(thirdTimepoint), expectedQuorum);
        assertEq(governor.quorum(firstTimepoint), expectedQuorum);

        uint48 currentTimepoint = governor.clock();
        vm.expectRevert(
            abi.encodeWithSelector(CoinDAOGovernor.ERC5805FutureLookup.selector, currentTimepoint, currentTimepoint)
        );
        governor.quorum(currentTimepoint);
    }

    function testQuorumUpdateRejectsDirectCalls() public {
        CoinDAOGovernor governor = CoinDAOGovernor(payable(_deploy(0, CoinDAOFactory.StakingTokenChoice.Coin).governor));
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorOnlyExecutor.selector, address(this)));
        governor.updateQuorumNumerator(2);
    }

    function testGovernanceUpdatesQuorumAndCheckpointsHistory() public {
        CoinDAOFactory.Deployment memory deployment = _deploy(0, CoinDAOFactory.StakingTokenChoice.Coin);
        CoinDAOGovernor governor = CoinDAOGovernor(payable(deployment.governor));
        uint256 oldNumerator = governor.quorumNumerator();
        uint256 historicalTimepoint = governor.clock();
        uint256 newNumerator = oldNumerator * 2;

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash) =
            _passAndQueueQuorumProposal(deployment, newNumerator, "Raise quorum");
        vm.warp(block.timestamp + factory.DEFAULT_TIMELOCK_DELAY());
        vm.expectEmit(false, false, false, true, address(governor));
        emit QuorumNumeratorUpdated(oldNumerator, newNumerator);
        governor.execute(targets, values, calldatas, descriptionHash);
        vm.roll(governor.clock() + 1);

        assertEq(governor.quorumNumerator(historicalTimepoint), oldNumerator);
        assertEq(governor.quorumNumerator(governor.clock() - 1), newNumerator);
        assertEq(governor.quorum(historicalTimepoint), factory.GOV_TOKEN_SUPPLY() / 1_000);
        assertEq(governor.quorum(governor.clock() - 1), (factory.GOV_TOKEN_SUPPLY() * newNumerator) / 1_000);

        (targets, values, calldatas, descriptionHash) =
            _passAndQueueQuorumProposal(deployment, 1_001, "Reject excessive quorum");
        vm.warp(block.timestamp + factory.DEFAULT_TIMELOCK_DELAY());
        vm.expectRevert(
            abi.encodeWithSelector(GovernorVotesQuorumFraction.GovernorInvalidQuorumFraction.selector, 1_001, 1_000)
        );
        governor.execute(targets, values, calldatas, descriptionHash);
    }

    function testQuorumChangesDoNotRetroactivelyReviveDefeatedProposal() public {
        CoinDAOFactory.Deployment memory deployment = _deploy(0, CoinDAOFactory.StakingTokenChoice.Coin);
        CoinDAOGovernor governor = CoinDAOGovernor(payable(deployment.governor));
        StakedGovToken staker = StakedGovToken(deployment.staker);
        address proposer = address(0xA11CE);
        address lowQuorumVoter = address(0xB0B);

        uint256 proposalThreshold = governor.proposalThreshold();
        deal(deployment.govToken, proposer, proposalThreshold, true);
        vm.startPrank(proposer);
        IERC20(deployment.govToken).approve(deployment.staker, proposalThreshold);
        staker.depositFor(proposer, proposalThreshold);
        staker.delegate(proposer);
        vm.stopPrank();
        _stakeGov(deployment, lowQuorumVoter, 10 ether);
        vm.roll(block.number + 1);

        address[] memory defeatedTargets = new address[](1);
        defeatedTargets[0] = address(governor);
        uint256[] memory defeatedValues = new uint256[](1);
        bytes[] memory defeatedCalldatas = new bytes[](1);
        defeatedCalldatas[0] = abi.encodeCall(governor.updateQuorumNumerator, (0));
        string memory defeatedDescription = "Proposal below original quorum";
        vm.prank(proposer);
        uint256 defeatedProposalId =
            governor.propose(defeatedTargets, defeatedValues, defeatedCalldatas, defeatedDescription);
        uint256 defeatedSnapshot = governor.proposalSnapshot(defeatedProposalId);
        vm.roll(defeatedSnapshot + 1);
        vm.prank(lowQuorumVoter);
        governor.castVote(defeatedProposalId, 1);
        vm.roll(governor.proposalDeadline(defeatedProposalId) + 1);

        uint256 oldQuorum = governor.quorum(defeatedSnapshot);
        assertEq(uint256(governor.state(defeatedProposalId)), uint256(IGovernor.ProposalState.Defeated));
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash) =
            _passAndQueueQuorumProposal(deployment, 0, "Lower quorum");
        vm.warp(block.timestamp + factory.DEFAULT_TIMELOCK_DELAY());
        governor.execute(targets, values, calldatas, descriptionHash);
        vm.roll(governor.clock() + 1);

        assertEq(governor.quorum(governor.clock() - 1), 0);
        assertEq(governor.quorum(defeatedSnapshot), oldQuorum);
        assertEq(uint256(governor.state(defeatedProposalId)), uint256(IGovernor.ProposalState.Defeated));
    }

    function _passAndQueueQuorumProposal(
        CoinDAOFactory.Deployment memory deployment,
        uint256 newQuorumNumerator,
        string memory description
    )
        internal
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash)
    {
        CoinDAOGovernor governor = CoinDAOGovernor(payable(deployment.governor));
        address voter = address(0xC0FFEE);
        uint256 votingPower = governor.proposalThreshold();
        _stakeGov(deployment, voter, votingPower);
        vm.roll(governor.clock() + 1);

        targets = new address[](1);
        targets[0] = address(governor);
        values = new uint256[](1);
        calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(governor.updateQuorumNumerator, (newQuorumNumerator));
        descriptionHash = keccak256(bytes(description));
        vm.prank(voter);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);
        vm.roll(governor.proposalSnapshot(proposalId) + 1);
        vm.prank(voter);
        governor.castVote(proposalId, 1);
        vm.roll(governor.proposalDeadline(proposalId) + 1);
        governor.queue(targets, values, calldatas, descriptionHash);
    }
}
