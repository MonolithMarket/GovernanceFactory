// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

import {CoinDAOGovernor} from "../src/CoinDAOGovernor.sol";
import {GovToken} from "../src/GovToken.sol";
import {StGovToken} from "../src/StGovToken.sol";
import {Box} from "./mocks/Box.sol";

contract CoinDAOGovernorTest is Test {
    address internal guardian = address(0x911);
    address internal voter = address(0xA11CE);

    GovToken internal govToken;
    StGovToken internal stGovToken;
    TimelockController internal timelock;
    CoinDAOGovernor internal governor;
    Box internal box;

    function setUp() public {
        govToken = new GovToken("Gov", "GOV", address(this), 1_000 ether);
        stGovToken = new StGovToken(IERC20(address(govToken)), "Staked Gov", "stGOV", address(this));

        address[] memory proposers = new address[](0);
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        timelock = new TimelockController(2 days, proposers, executors, address(this));
        governor = new CoinDAOGovernor("CoinDAO Governor", stGovToken, timelock, 0, guardian, block.timestamp + 2 days);
        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(governor));
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), address(this));

        box = new Box(address(timelock));
    }

    function testGovernorUsesStGovTokenVotingSource() public {
        assertTrue(govToken.transfer(voter, 100 ether));

        assertEq(address(governor.token()), address(stGovToken));
        assertEq(stGovToken.getVotes(voter), 0);

        vm.startPrank(voter);
        govToken.approve(address(stGovToken), 100 ether);
        stGovToken.stake(100 ether);
        assertEq(stGovToken.getVotes(voter), 0);
        stGovToken.delegate(voter);
        assertEq(stGovToken.getVotes(voter), 100 ether);
        vm.stopPrank();
    }

    function testGuardianCanCancelBeforeExpiry() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, string memory description) =
            _boxProposal(1);

        uint256 proposalId = governor.propose(targets, values, calldatas, description);
        bytes32 descriptionHash = keccak256(bytes(description));

        vm.prank(guardian);
        uint256 canceledId = governor.cancel(targets, values, calldatas, descriptionHash);

        assertEq(canceledId, proposalId);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Canceled));
    }

    function testGuardianCannotCancelAtOrAfterExpiry() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, string memory description) =
            _boxProposal(2);

        uint256 proposalId = governor.propose(targets, values, calldatas, description);
        bytes32 descriptionHash = keccak256(bytes(description));

        vm.warp(governor.guardianExpiresAt());
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorUnableToCancel.selector, proposalId, guardian));
        governor.cancel(targets, values, calldatas, descriptionHash);
    }

    function testSuccessfulProposalQueuesAndExecutesThroughTimelock() public {
        assertTrue(govToken.transfer(voter, 100 ether));
        vm.startPrank(voter);
        govToken.approve(address(stGovToken), 100 ether);
        stGovToken.stake(100 ether);
        stGovToken.delegate(voter);
        vm.stopPrank();

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, string memory description) =
            _boxProposal(42);
        bytes32 descriptionHash = keccak256(bytes(description));

        uint256 proposalId = governor.propose(targets, values, calldatas, description);

        vm.warp(block.timestamp + governor.votingDelay() + 1);
        vm.prank(voter);
        governor.castVote(proposalId, uint8(1));

        vm.warp(block.timestamp + governor.votingPeriod() + 1);
        governor.queue(targets, values, calldatas, descriptionHash);

        vm.warp(block.timestamp + timelock.getMinDelay() + 1);
        governor.execute(targets, values, calldatas, descriptionHash);

        assertEq(box.value(), 42);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Executed));
    }

    function _boxProposal(uint256 newValue)
        internal
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, string memory description)
    {
        targets = new address[](1);
        values = new uint256[](1);
        calldatas = new bytes[](1);

        targets[0] = address(box);
        calldatas[0] = abi.encodeCall(Box.setValue, (newValue));
        description = string.concat("Set box value ", vm.toString(newValue));
    }
}
