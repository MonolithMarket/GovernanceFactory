pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {GovToken} from "../src/GovToken.sol";
import {CloneTestUtils} from "./helpers/CloneTestUtils.sol";

contract GovTokenTest is Test, CloneTestUtils {
    GovToken internal gov;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal delegatee = address(0xDE1E6A7E);

    function setUp() public {
        gov = _newGovToken("Governance", "GOV", alice);
    }

    function testVotingPowerRequiresDelegation() public {
        assertEq(gov.balanceOf(alice), gov.totalSupply());
        assertEq(gov.getVotes(alice), 0);

        vm.prank(alice);
        gov.delegate(alice);

        assertEq(gov.delegates(alice), alice);
        assertEq(gov.getVotes(alice), gov.totalSupply());
    }

    function testTransfersMoveDelegatedVotingPower() public {
        vm.prank(alice);
        gov.delegate(alice);

        vm.prank(alice);
        gov.transfer(bob, 100 ether);

        assertEq(gov.getVotes(alice), gov.totalSupply() - 100 ether);
        assertEq(gov.getVotes(bob), 0);

        vm.prank(bob);
        gov.delegate(delegatee);

        assertEq(gov.getVotes(delegatee), 100 ether);
    }

    function testHistoricalVoteAndSupplyCheckpoints() public {
        vm.prank(alice);
        gov.delegate(alice);
        uint256 snapshotBlock = gov.clock();

        vm.roll(snapshotBlock + 1);
        vm.prank(alice);
        gov.transfer(bob, 100 ether);

        assertEq(gov.getPastVotes(alice, snapshotBlock), gov.totalSupply());
        assertEq(gov.getPastTotalSupply(snapshotBlock), gov.totalSupply());
        assertEq(gov.getVotes(alice), gov.totalSupply() - 100 ether);
    }
}
