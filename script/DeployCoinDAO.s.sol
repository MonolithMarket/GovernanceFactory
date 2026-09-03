// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Script, console} from "forge-std/Script.sol";

import {CoinDAOFactory} from "../src/CoinDAOFactory.sol";
import {IMonolithFactory, IMonolithLender} from "../src/interfaces/IMonolith.sol";

interface IChainlinkAggregatorV3 {
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

contract DeployCoinDAOScript is Script {
    using SafeCast for uint256;

    uint256 public constant SEPOLIA_CHAIN_ID = 11_155_111;
    address public constant MONOLITH_FACTORY = 0x365009FA2Ddb17f386E20854E4B281827619E4D2;
    address public constant WETH = 0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9;
    address public constant ETH_USD_FEED = 0x694AA1769357215DE4FAC081bf1f309aDC325306;

    string public constant COIN_NAME = "Monolith Sepolia USD";
    string public constant COIN_SYMBOL = "msUSD";
    string public constant GOV_TOKEN_NAME = "Monolith Sepolia Governance";
    string public constant GOV_TOKEN_SYMBOL = "msGOV";

    uint256 public constant DEFAULT_COLLATERAL_FACTOR = 5_000;
    uint256 public constant DEFAULT_MIN_DEBT = 1_000 ether;
    uint256 public constant DEFAULT_TIME_UNTIL_IMMUTABILITY = 365 days;
    uint256 public constant DEFAULT_HALF_LIFE = 7 days;
    uint256 public constant DEFAULT_TARGET_FREE_DEBT_RATIO_START_BPS = 2_000;
    uint256 public constant DEFAULT_TARGET_FREE_DEBT_RATIO_END_BPS = 4_000;
    uint256 public constant DEFAULT_REDEEM_FEE_BPS = 30;
    uint256 public constant DEFAULT_STALENESS_THRESHOLD = 48 hours;
    uint256 public constant DEFAULT_MAX_BORROW_DELTA_BPS = 50;
    bytes32 public constant DEFAULT_COIN_DAO_SALT = keccak256("Monolith Sepolia CoinDAO v1");

    function run() external returns (CoinDAOFactory.Deployment memory deployment) {
        require(block.chainid == SEPOLIA_CHAIN_ID, "Sepolia only");

        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address factoryAddress = vm.envAddress("COIN_DAO_FACTORY");
        require(privateKey != 0, "Invalid private key");
        require(factoryAddress.code.length != 0, "CoinDAO factory has no code");

        address deployer = vm.addr(privateKey);
        CoinDAOFactory factory = CoinDAOFactory(factoryAddress);
        _preflight(factory);

        CoinDAOFactory.GovLaunchParams memory govParams = govParamsFromEnv();
        IMonolithFactory.DeployParams memory monolithParams = monolithParamsFromEnv();
        bytes32 userSalt = vm.envOr("COIN_DAO_SALT", DEFAULT_COIN_DAO_SALT);
        CoinDAOFactory.PredictedAddresses memory predicted =
            factory.predictCoinDAOAddresses(deployer, userSalt, govParams);
        uint256 deploymentId = factory.deploymentsLength();

        console.log("Deployer and Lender manager:", deployer);
        console.log("CoinDAO factory:", factoryAddress);
        console.log("Collateral (WETH):", WETH);
        console.log("Price feed (ETH / USD):", ETH_USD_FEED);
        console.logBytes32(userSalt);
        _logPredictedAddresses(predicted);

        vm.startBroadcast(privateKey);
        deployment = factory.deploy(userSalt, govParams, monolithParams, deployer);
        vm.stopBroadcast();

        _verifyDeployment(factory, deployment, deployer, deploymentId, govParams.stakingTokenChoice);
        _verifyPredictedAddresses(deployment, predicted);
        _logDeployment(deploymentId, deployment);
    }

    function govParamsFromEnv() public view returns (CoinDAOFactory.GovLaunchParams memory params) {
        uint256 deployerStakeBps = vm.envOr("DEPLOYER_STAKE_BPS", uint256(0));
        address deployerRecipient = vm.envOr("DEPLOYER_RECIPIENT", address(0));
        string memory stakingToken = vm.envOr("STAKING_TOKEN", string("COIN"));

        return buildGovParams(deployerStakeBps, deployerRecipient, stakingToken);
    }

    function defaultGovParams() public pure returns (CoinDAOFactory.GovLaunchParams memory params) {
        return buildGovParams(0, address(0), "COIN");
    }

    function buildGovParams(uint256 deployerStakeBps, address deployerRecipient, string memory stakingToken)
        public
        pure
        returns (CoinDAOFactory.GovLaunchParams memory params)
    {
        require(deployerStakeBps <= 2_000, "Deployer stake exceeds 20%");
        require(deployerStakeBps == 0 || deployerRecipient != address(0), "Deployer recipient required");

        CoinDAOFactory.StakingTokenChoice stakingTokenChoice;
        if (keccak256(bytes(stakingToken)) == keccak256("COIN")) {
            stakingTokenChoice = CoinDAOFactory.StakingTokenChoice.Coin;
        } else if (keccak256(bytes(stakingToken)) == keccak256("SCOIN")) {
            stakingTokenChoice = CoinDAOFactory.StakingTokenChoice.SCoin;
        } else {
            revert("STAKING_TOKEN must be COIN or SCOIN");
        }

        params = CoinDAOFactory.GovLaunchParams({
            govTokenName: GOV_TOKEN_NAME,
            govTokenSymbol: GOV_TOKEN_SYMBOL,
            deployerStakeBps: deployerStakeBps.toUint16(),
            deployerRecipient: deployerRecipient,
            stakingTokenChoice: stakingTokenChoice
        });
    }

    function monolithParamsFromEnv() public view returns (IMonolithFactory.DeployParams memory params) {
        uint256 collateralFactor = vm.envOr("COLLATERAL_FACTOR", DEFAULT_COLLATERAL_FACTOR);
        uint256 minDebt = vm.envOr("MIN_DEBT", DEFAULT_MIN_DEBT);
        uint256 timeUntilImmutability = vm.envOr("TIME_UNTIL_IMMUTABILITY", DEFAULT_TIME_UNTIL_IMMUTABILITY);
        uint256 halfLife = vm.envOr("HALF_LIFE", DEFAULT_HALF_LIFE);
        uint256 targetStart = vm.envOr("TARGET_FREE_DEBT_RATIO_START_BPS", DEFAULT_TARGET_FREE_DEBT_RATIO_START_BPS);
        uint256 targetEnd = vm.envOr("TARGET_FREE_DEBT_RATIO_END_BPS", DEFAULT_TARGET_FREE_DEBT_RATIO_END_BPS);
        uint256 redeemFeeBps = vm.envOr("REDEEM_FEE_BPS", DEFAULT_REDEEM_FEE_BPS);
        uint256 stalenessThreshold = vm.envOr("STALENESS_THRESHOLD", DEFAULT_STALENESS_THRESHOLD);
        uint256 maxBorrowDeltaBps = vm.envOr("MAX_BORROW_DELTA_BPS", DEFAULT_MAX_BORROW_DELTA_BPS);

        return buildMonolithParams(
            collateralFactor,
            minDebt,
            timeUntilImmutability,
            halfLife,
            targetStart,
            targetEnd,
            redeemFeeBps,
            stalenessThreshold,
            maxBorrowDeltaBps
        );
    }

    function defaultMonolithParams() public pure returns (IMonolithFactory.DeployParams memory params) {
        return buildMonolithParams(
            DEFAULT_COLLATERAL_FACTOR,
            DEFAULT_MIN_DEBT,
            DEFAULT_TIME_UNTIL_IMMUTABILITY,
            DEFAULT_HALF_LIFE,
            DEFAULT_TARGET_FREE_DEBT_RATIO_START_BPS,
            DEFAULT_TARGET_FREE_DEBT_RATIO_END_BPS,
            DEFAULT_REDEEM_FEE_BPS,
            DEFAULT_STALENESS_THRESHOLD,
            DEFAULT_MAX_BORROW_DELTA_BPS
        );
    }

    function buildMonolithParams(
        uint256 collateralFactor,
        uint256 minDebt,
        uint256 timeUntilImmutability,
        uint256 halfLife,
        uint256 targetStart,
        uint256 targetEnd,
        uint256 redeemFeeBps,
        uint256 stalenessThreshold,
        uint256 maxBorrowDeltaBps
    ) public pure returns (IMonolithFactory.DeployParams memory params) {
        require(collateralFactor <= 8_500, "Invalid collateral factor");
        require(timeUntilImmutability <= 1_460 days, "Invalid immutability period");
        require(halfLife >= 12 hours && halfLife <= 30 days, "Invalid half life");
        require(targetStart >= 500 && targetStart <= targetEnd, "Invalid target start");
        require(targetEnd <= 9_500, "Invalid target end");
        require(redeemFeeBps <= 500, "Invalid redeem fee");
        require(stalenessThreshold != 0 && stalenessThreshold <= type(uint32).max, "Invalid staleness threshold");
        require(maxBorrowDeltaBps >= 50 && maxBorrowDeltaBps <= 200, "Invalid max borrow delta");
        require(halfLife <= type(uint64).max, "Half life overflow");

        params = IMonolithFactory.DeployParams({
            name: COIN_NAME,
            symbol: COIN_SYMBOL,
            collateral: WETH,
            psmAsset: address(0),
            psmVault: address(0),
            feed: ETH_USD_FEED,
            collateralFactor: collateralFactor,
            minDebt: minDebt,
            timeUntilImmutability: timeUntilImmutability,
            operator: address(0),
            manager: address(0),
            halfLife: halfLife.toUint64(),
            targetFreeDebtRatioStartBps: targetStart.toUint16(),
            targetFreeDebtRatioEndBps: targetEnd.toUint16(),
            redeemFeeBps: redeemFeeBps.toUint16(),
            stalenessThreshold: stalenessThreshold.toUint32(),
            maxBorrowDeltaBps: maxBorrowDeltaBps.toUint16(),
            psmVaultMinTotalSupply: 1
        });
    }

    function _preflight(CoinDAOFactory factory) internal view {
        require(MONOLITH_FACTORY.code.length != 0, "Monolith factory has no code");
        require(address(factory.monolithFactory()) == MONOLITH_FACTORY, "Unexpected Monolith factory");
        _preflightImplementations(factory.implementations());
        require(WETH.code.length != 0, "WETH has no code");
        require(ETH_USD_FEED.code.length != 0, "ETH/USD feed has no code");

        require(IERC20Metadata(WETH).decimals() == 18, "Unexpected WETH decimals");
        require(keccak256(bytes(IERC20Metadata(WETH).symbol())) == keccak256("WETH"), "Unexpected collateral");

        IChainlinkAggregatorV3 feed = IChainlinkAggregatorV3(ETH_USD_FEED);
        require(feed.decimals() == 8, "Unexpected feed decimals");
        require(keccak256(bytes(feed.description())) == keccak256("ETH / USD"), "Unexpected price feed");

        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = feed.latestRoundData();
        require(answer > 0, "Invalid oracle answer");
        require(updatedAt != 0 && updatedAt <= block.timestamp, "Invalid oracle timestamp");
        require(answeredInRound >= roundId, "Incomplete oracle round");

        uint256 stalenessThreshold = vm.envOr("STALENESS_THRESHOLD", DEFAULT_STALENESS_THRESHOLD);
        require(block.timestamp - updatedAt <= stalenessThreshold, "Stale oracle answer");
    }

    function _preflightImplementations(CoinDAOFactory.Implementations memory implementationSet) internal view {
        require(implementationSet.govToken.code.length != 0, "GOV implementation has no code");
        require(implementationSet.stakedGovToken.code.length != 0, "Staked GOV implementation has no code");
        require(implementationSet.revenueRouter.code.length != 0, "Router implementation has no code");
        require(implementationSet.stakingRewards.code.length != 0, "Rewards implementation has no code");
        require(implementationSet.stakingRewardsFunder.code.length != 0, "Rewards funder implementation has no code");
        require(implementationSet.vestingWallet.code.length != 0, "Vesting implementation has no code");
    }

    function _verifyDeployment(
        CoinDAOFactory factory,
        CoinDAOFactory.Deployment memory deployment,
        address expectedManager,
        uint256 expectedId,
        CoinDAOFactory.StakingTokenChoice stakingTokenChoice
    ) internal view {
        require(factory.deploymentsLength() == expectedId + 1, "Deployment not recorded");
        require(factory.hasCoinDAO(deployment.lender), "Lender not registered");

        require(deployment.lender.code.length != 0, "Lender has no code");
        require(deployment.coin.code.length != 0, "Coin has no code");
        require(deployment.vault.code.length != 0, "sCoin has no code");
        require(deployment.govToken.code.length != 0, "GOV has no code");
        require(deployment.staker.code.length != 0, "staked GOV has no code");
        require(deployment.governor.code.length != 0, "Governor has no code");
        require(deployment.timelock.code.length != 0, "Timelock has no code");
        require(deployment.revenueRouter.code.length != 0, "Revenue router has no code");
        require(deployment.coinStakingRewards.code.length != 0, "Staking rewards has no code");
        require(deployment.coinStakingRewardsFunder.code.length != 0, "Rewards funder has no code");
        require(deployment.treasuryVesting.code.length != 0, "Treasury vesting has no code");
        require(deployment.monolithVesting.code.length != 0, "Monolith vesting has no code");
        if (deployment.deployerVesting != address(0)) {
            require(deployment.deployerVesting.code.length != 0, "Deployer vesting has no code");
        }

        IMonolithLender lender = IMonolithLender(deployment.lender);
        require(lender.operator() == deployment.revenueRouter, "Incorrect Lender operator");
        require(_managerOf(deployment.lender) == expectedManager, "Incorrect Lender manager");

        address expectedStakingToken =
            stakingTokenChoice == CoinDAOFactory.StakingTokenChoice.Coin ? deployment.coin : deployment.vault;
        require(deployment.stakingToken == expectedStakingToken, "Incorrect staking token");
    }

    function _managerOf(address lender) internal view returns (address manager) {
        (bool success, bytes memory result) = lender.staticcall(abi.encodeWithSignature("manager()"));
        require(success && result.length == 32, "Cannot read Lender manager");
        manager = abi.decode(result, (address));
    }

    function _logDeployment(uint256 id, CoinDAOFactory.Deployment memory deployment) internal pure {
        console.log("CoinDAO deployment ID:", id);
        console.log("Lender:", deployment.lender);
        console.log("Coin (msUSD):", deployment.coin);
        console.log("sCoin (smsUSD):", deployment.vault);
        console.log("GOV (msGOV):", deployment.govToken);
        console.log("Staked GOV:", deployment.staker);
        console.log("Governor:", deployment.governor);
        console.log("Timelock:", deployment.timelock);
        console.log("Revenue router:", deployment.revenueRouter);
        console.log("Coin staking rewards:", deployment.coinStakingRewards);
        console.log("Coin staking rewards funder:", deployment.coinStakingRewardsFunder);
        console.log("Treasury vesting:", deployment.treasuryVesting);
        console.log("Monolith vesting:", deployment.monolithVesting);
        console.log("Deployer vesting:", deployment.deployerVesting);
    }

    function _logPredictedAddresses(CoinDAOFactory.PredictedAddresses memory predicted) internal pure {
        console.log("Predicted GOV:", predicted.govToken);
        console.log("Predicted staked GOV:", predicted.staker);
        console.log("Predicted Governor:", predicted.governor);
        console.log("Predicted Timelock:", predicted.timelock);
        console.log("Predicted revenue router:", predicted.revenueRouter);
        console.log("Predicted staking rewards:", predicted.coinStakingRewards);
        console.log("Predicted rewards funder:", predicted.coinStakingRewardsFunder);
        console.log("Predicted treasury vesting:", predicted.treasuryVesting);
        console.log("Predicted Monolith vesting:", predicted.monolithVesting);
        console.log("Predicted deployer vesting:", predicted.deployerVesting);
    }

    function _verifyPredictedAddresses(
        CoinDAOFactory.Deployment memory deployment,
        CoinDAOFactory.PredictedAddresses memory predicted
    ) internal pure {
        require(deployment.govToken == predicted.govToken, "Unexpected GOV address");
        require(deployment.staker == predicted.staker, "Unexpected staker address");
        require(deployment.governor == predicted.governor, "Unexpected Governor address");
        require(deployment.timelock == predicted.timelock, "Unexpected Timelock address");
        require(deployment.revenueRouter == predicted.revenueRouter, "Unexpected router address");
        require(deployment.coinStakingRewards == predicted.coinStakingRewards, "Unexpected rewards address");
        require(deployment.coinStakingRewardsFunder == predicted.coinStakingRewardsFunder, "Unexpected funder address");
        require(deployment.treasuryVesting == predicted.treasuryVesting, "Unexpected treasury vesting");
        require(deployment.monolithVesting == predicted.monolithVesting, "Unexpected Monolith vesting");
        if (deployment.deployerVesting != address(0)) {
            require(deployment.deployerVesting == predicted.deployerVesting, "Unexpected deployer vesting");
        }
    }
}
