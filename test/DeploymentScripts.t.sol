// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {DeployCoinDAOScript} from "../script/DeployCoinDAO.s.sol";
import {DeployCoinDAOFactoryScript} from "../script/DeployCoinDAOFactory.s.sol";
import {CoinDAOFactory} from "../src/CoinDAOFactory.sol";
import {CoinDAOVestingWallet} from "../src/CoinDAOVestingWallet.sol";
import {GovToken} from "../src/GovToken.sol";
import {RevenueRouter} from "../src/RevenueRouter.sol";
import {StakedGovToken} from "../src/StakedGovToken.sol";
import {StakingRewards} from "../src/StakingRewards.sol";
import {StakingRewardsFunder} from "../src/StakingRewardsFunder.sol";
import {IMonolithFactory} from "../src/interfaces/IMonolith.sol";

contract DeployCoinDAOScriptHarness is DeployCoinDAOScript {
    function preflight(CoinDAOFactory factory) external view {
        _preflight(factory);
    }
}

contract SepoliaWethStub {
    function symbol() external pure returns (string memory) {
        return "WETH";
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }
}

contract SepoliaEthUsdFeedStub {
    function description() external pure returns (string memory) {
        return "ETH / USD";
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData()
        external
        view
        virtual
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (1, 2_000e8, block.timestamp, block.timestamp, 1);
    }
}

contract StaleSepoliaEthUsdFeedStub is SepoliaEthUsdFeedStub {
    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        uint256 staleTimestamp = block.timestamp - 48 hours - 1;
        return (1, 2_000e8, staleTimestamp, staleTimestamp, 1);
    }
}

contract MonolithFactoryStub {
    function isDeployed(address) external pure returns (bool) {
        return false;
    }
}

contract DeploymentScriptsTest is Test {
    DeployCoinDAOScriptHarness internal script;

    function setUp() public {
        script = new DeployCoinDAOScriptHarness();
    }

    function testDefaultSepoliaConfiguration() public {
        DeployCoinDAOFactoryScript factoryScript = new DeployCoinDAOFactoryScript();
        assertEq(script.SEPOLIA_CHAIN_ID(), 11_155_111);
        assertEq(script.MONOLITH_FACTORY(), 0x365009FA2Ddb17f386E20854E4B281827619E4D2);
        assertEq(script.WETH(), 0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9);
        assertEq(script.ETH_USD_FEED(), 0x694AA1769357215DE4FAC081bf1f309aDC325306);
        assertEq(script.COIN_NAME(), "Monolith Sepolia USD");
        assertEq(script.COIN_SYMBOL(), "msUSD");
        assertEq(script.GOV_TOKEN_NAME(), "Monolith Sepolia Governance");
        assertEq(script.GOV_TOKEN_SYMBOL(), "msGOV");
        assertEq(factoryScript.MONOLITH_FACTORY(), script.MONOLITH_FACTORY());

        CoinDAOFactory.GovLaunchParams memory govParams = script.defaultGovParams();
        IMonolithFactory.DeployParams memory monolithParams = script.defaultMonolithParams();
        assertEq(govParams.govTokenName, "Monolith Sepolia Governance");
        assertEq(govParams.govTokenSymbol, "msGOV");
        assertEq(govParams.deployerStakeBps, 0);
        assertEq(govParams.deployerRecipient, address(0));
        assertEq(uint256(govParams.stakingTokenChoice), uint256(CoinDAOFactory.StakingTokenChoice.Coin));

        assertEq(monolithParams.name, "Monolith Sepolia USD");
        assertEq(monolithParams.symbol, "msUSD");
        assertEq(monolithParams.collateral, script.WETH());
        assertEq(monolithParams.feed, script.ETH_USD_FEED());
        assertEq(monolithParams.psmAsset, address(0));
        assertEq(monolithParams.psmVault, address(0));
        assertEq(monolithParams.collateralFactor, 5_000);
        assertEq(monolithParams.minDebt, 1_000 ether);
        assertEq(monolithParams.timeUntilImmutability, 365 days);
        assertEq(monolithParams.halfLife, 7 days);
        assertEq(monolithParams.targetFreeDebtRatioStartBps, 2_000);
        assertEq(monolithParams.targetFreeDebtRatioEndBps, 4_000);
        assertEq(monolithParams.redeemFeeBps, 30);
        assertEq(monolithParams.stalenessThreshold, 48 hours);
        assertEq(monolithParams.maxBorrowDeltaBps, 50);
    }

    function testLaunchOverridesAndValidation() public {
        CoinDAOFactory.GovLaunchParams memory params = script.buildGovParams(0, address(0), "SCOIN");
        assertEq(uint256(params.stakingTokenChoice), uint256(CoinDAOFactory.StakingTokenChoice.SCoin));
        vm.expectRevert("STAKING_TOKEN must be COIN or SCOIN");
        script.buildGovParams(0, address(0), "LP");
        vm.expectRevert("Deployer recipient required");
        script.buildGovParams(1, address(0), "COIN");
        vm.expectRevert("Invalid half life");
        script.buildMonolithParams(5_000, 1_000 ether, 365 days, 12 hours - 1, 2_000, 4_000, 30, 48 hours, 50);
    }

    function testPreflightAcceptsExpectedSepoliaDependencies() public {
        vm.warp(10 days);
        _etchPreflightDependencies(address(new SepoliaEthUsdFeedStub()));

        CoinDAOFactory factory =
            new CoinDAOFactory(IMonolithFactory(script.MONOLITH_FACTORY()), address(this), _newImplementations());
        script.preflight(factory);
    }

    function testPreflightRejectsStaleFeed() public {
        vm.warp(10 days);
        _etchPreflightDependencies(address(new StaleSepoliaEthUsdFeedStub()));

        CoinDAOFactory factory =
            new CoinDAOFactory(IMonolithFactory(script.MONOLITH_FACTORY()), address(this), _newImplementations());
        vm.expectRevert("Stale oracle answer");
        script.preflight(factory);
    }

    function _etchPreflightDependencies(address feedStub) internal {
        MonolithFactoryStub monolithFactoryStub = new MonolithFactoryStub();
        SepoliaWethStub wethStub = new SepoliaWethStub();

        vm.etch(script.MONOLITH_FACTORY(), address(monolithFactoryStub).code);
        vm.etch(script.WETH(), address(wethStub).code);
        vm.etch(script.ETH_USD_FEED(), feedStub.code);
    }

    function _newImplementations() internal returns (CoinDAOFactory.Implementations memory implementationSet) {
        implementationSet = CoinDAOFactory.Implementations({
            govToken: address(new GovToken()),
            stakedGovToken: address(new StakedGovToken()),
            revenueRouter: address(new RevenueRouter()),
            stakingRewards: address(new StakingRewards()),
            stakingRewardsFunder: address(new StakingRewardsFunder()),
            vestingWallet: address(new CoinDAOVestingWallet())
        });
    }
}
