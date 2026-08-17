pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {GovToken} from "../src/GovToken.sol";
import {RevenueRouter} from "../src/RevenueRouter.sol";
import {StakedGovToken} from "../src/StakedGovToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockMonolithLender} from "./mocks/MockMonolith.sol";
import {CloneTestUtils} from "./helpers/CloneTestUtils.sol";

contract RevenueRouterTest is Test, CloneTestUtils {
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
        lender = new MockMonolithLender(address(router), address(this), address(coin), address(0xCAFE));
        staker.initialize(IERC20(address(gov)), IERC20(address(coin)), "Staked Governance", "sGOV", address(router));
        router.initialize(address(lender), address(coin), treasury, address(staker), 10_000, address(this));
        assertTrue(gov.transfer(alice, 100 ether));
        assertTrue(gov.transfer(attacker, 100 ether));
    }

    function testFirstDepositRoutesPendingRevenueToTreasury() public {
        lender.setAccruedLocalReserves(30 ether);
        _stake(alice, 100 ether);
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

    function _stake(address account, uint256 amount) internal {
        vm.startPrank(account);
        gov.approve(address(staker), amount);
        staker.depositFor(account, amount);
        vm.stopPrank();
    }
}
