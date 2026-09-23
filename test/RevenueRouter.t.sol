pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {GovToken} from "../src/GovToken.sol";
import {RevenueRouter} from "../src/RevenueRouter.sol";
import {StakedGovToken} from "../src/StakedGovToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockMonolithLender} from "./mocks/MockMonolith.sol";
import {CloneTestUtils} from "./helpers/CloneTestUtils.sol";

contract RevenueRouterTest is Test, CloneTestUtils {
    event LocalReserveFeeUpdated(uint256 feeBps);
    event ImmutabilityEnabled(uint256 timestamp);

    address internal alice = address(0xA11CE);
    address internal attacker = address(0xBAD);
    address internal treasury = address(0xBEEF);

    GovToken internal gov;
    MockERC20 internal coin;
    StakedGovToken internal staker;
    RevenueRouter internal router;
    MockMonolithLender internal lender;

    function setUp() public {
        gov = _newGovToken("Governance", "GOV", address(this));
        coin = new MockERC20("Coin", "COIN");
        staker = StakedGovToken(Clones.clone(address(new StakedGovToken())));
        router = RevenueRouter(Clones.clone(address(new RevenueRouter())));
        lender = new MockMonolithLender(address(router), address(this), address(coin), address(0xCAFE), 30 days);
        staker.initialize(IERC20(address(gov)), IERC20(address(coin)), "Staked Governance", "sGOV", address(router));
        router.initialize(address(lender), address(coin), treasury, address(staker), 10_000, address(this));
        assertTrue(gov.transfer(alice, 100 ether));
        assertTrue(gov.transfer(attacker, 100 ether));
    }

    function testFirstDepositRoutesPendingRevenueToTreasury() public {
        assertEq(router.govStaking().totalSupply(), 0);
        lender.setAccruedLocalReserves(30 ether);
        _stake(alice, 100 ether);
        assertEq(router.govStaking().totalSupply(), 100 ether);
        assertEq(lender.accruedLocalReserves(), 0);
        assertEq(coin.balanceOf(treasury), 30 ether);
        assertEq(staker.earned(alice), 0);
    }

    function testLaterDepositorCannotCapturePendingRevenue() public {
        _stake(alice, 100 ether);
        lender.setAccruedLocalReserves(30 ether);
        _stake(attacker, 100 ether);

        assertEq(lender.accruedLocalReserves(), 0);
        assertEq(staker.earned(alice), 30 ether);
        assertEq(staker.earned(attacker), 0);
        (uint256 treasuryAmount, uint256 stakingAmount) = router.distribute();
        assertEq(treasuryAmount, 0);
        assertEq(stakingAmount, 0);
        vm.prank(attacker);
        staker.withdraw();
        assertEq(staker.earned(attacker), 0);
    }

    function testConfiguredSplitPaysTreasuryAndActiveStaker() public {
        _stake(alice, 100 ether);
        router.setGovStakingBps(2_500);
        router.setManager(address(0xCA11));
        assertEq(lender.manager(), address(0xCA11));

        lender.setAccruedLocalReserves(100 ether);
        (uint256 treasuryAmount, uint256 stakingAmount) = router.distribute();
        assertEq(treasuryAmount, 75 ether);
        assertEq(stakingAmount, 25 ether);
        assertEq(coin.balanceOf(treasury), 75 ether);
        assertEq(staker.earned(alice), 25 ether);
        vm.prank(alice);
        staker.getReward();
        assertEq(coin.balanceOf(alice), 25 ether);
    }

    function testSetLocalReserveFeeBpsAcceptsEndpointsAndEmitsFromLender() public {
        vm.expectEmit(false, false, false, true, address(lender));
        emit LocalReserveFeeUpdated(1_000);
        router.setLocalReserveFeeBps(1_000);
        assertEq(lender.feeBps(), 1_000);

        vm.expectEmit(false, false, false, true, address(lender));
        emit LocalReserveFeeUpdated(0);
        router.setLocalReserveFeeBps(0);
        assertEq(lender.feeBps(), 0);
    }

    function testFuzzSetLocalReserveFeeBps(uint256 newFeeBps) public {
        newFeeBps = bound(newFeeBps, 0, 1_000);
        router.setLocalReserveFeeBps(newFeeBps);
        assertEq(lender.feeBps(), newFeeBps);
    }

    function testFuzzInvalidLocalReserveFeePreservesExistingFee(uint256 newFeeBps) public {
        newFeeBps = bound(newFeeBps, 1_001, type(uint256).max);
        router.setLocalReserveFeeBps(500);

        vm.expectRevert(bytes("Invalid fee"));
        router.setLocalReserveFeeBps(newFeeBps);
        assertEq(lender.feeBps(), 500);
    }

    function testOnlyOwnerCanControlLenderFeeAndImmutability() public {
        _assertLenderControlsRejectCaller(attacker);
    }

    function testLenderManagerCannotControlFeeOrImmutability() public {
        router.setManager(alice);
        assertEq(lender.manager(), alice);
        _assertLenderControlsRejectCaller(alice);
    }

    function testRouterOwnerCannotCallLenderOperatorActionsDirectly() public {
        vm.expectRevert(MockMonolithLender.Unauthorized.selector);
        lender.setLocalReserveFeeBps(500);
        vm.expectRevert(MockMonolithLender.Unauthorized.selector);
        lender.enableImmutabilityNow();
    }

    function testEnableImmutabilityBeforeDeadlineEmitsFromLender() public {
        uint256 previousDeadline = lender.immutabilityDeadline();
        vm.warp(previousDeadline - 1);

        vm.expectEmit(false, false, false, true, address(lender));
        emit ImmutabilityEnabled(block.timestamp);
        router.enableImmutabilityNow();
        assertEq(lender.immutabilityDeadline(), previousDeadline - 1);
    }

    function testEnableImmutabilityRejectsAtAndAfterDeadline() public {
        uint256 deadline = lender.immutabilityDeadline();
        vm.warp(deadline);
        vm.expectRevert(bytes("Deadline passed"));
        router.enableImmutabilityNow();
        assertEq(lender.immutabilityDeadline(), deadline);

        vm.warp(deadline + 1);
        vm.expectRevert(bytes("Deadline passed"));
        router.enableImmutabilityNow();
        assertEq(lender.immutabilityDeadline(), deadline);
    }

    function testEnableImmutabilityCannotBeRepeatedOrExtended() public {
        router.enableImmutabilityNow();
        uint256 deadline = lender.immutabilityDeadline();

        vm.expectRevert(bytes("Deadline passed"));
        router.enableImmutabilityNow();
        vm.warp(deadline + 1);
        vm.expectRevert(bytes("Deadline passed"));
        router.enableImmutabilityNow();
        assertEq(lender.immutabilityDeadline(), deadline);
    }

    function testLocalReserveFeeRemainsAdjustableAfterImmutability() public {
        router.enableImmutabilityNow();
        uint256 deadline = lender.immutabilityDeadline();
        vm.warp(deadline + 1);

        router.setLocalReserveFeeBps(1_000);
        assertEq(lender.feeBps(), 1_000);
        router.setLocalReserveFeeBps(0);
        assertEq(lender.feeBps(), 0);
        assertEq(lender.immutabilityDeadline(), deadline);
    }

    function _assertLenderControlsRejectCaller(address caller) internal {
        uint256 deadline = lender.immutabilityDeadline();
        vm.startPrank(caller);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, caller));
        router.setLocalReserveFeeBps(500);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, caller));
        router.enableImmutabilityNow();
        vm.stopPrank();

        assertEq(lender.feeBps(), 0);
        assertEq(lender.immutabilityDeadline(), deadline);
    }

    function _stake(address account, uint256 amount) internal {
        vm.startPrank(account);
        gov.approve(address(staker), amount);
        staker.depositFor(account, amount);
        vm.stopPrank();
    }
}
