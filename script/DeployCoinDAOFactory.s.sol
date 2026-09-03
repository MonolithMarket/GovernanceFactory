// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";

import {CoinDAOFactory} from "../src/CoinDAOFactory.sol";
import {CoinDAOVestingWallet} from "../src/CoinDAOVestingWallet.sol";
import {GovToken} from "../src/GovToken.sol";
import {RevenueRouter} from "../src/RevenueRouter.sol";
import {StakedGovToken} from "../src/StakedGovToken.sol";
import {StakingRewards} from "../src/StakingRewards.sol";
import {StakingRewardsFunder} from "../src/StakingRewardsFunder.sol";
import {IMonolithFactory} from "../src/interfaces/IMonolith.sol";

contract DeployCoinDAOFactoryScript is Script {
    uint256 public constant SEPOLIA_CHAIN_ID = 11_155_111;
    address public constant MONOLITH_FACTORY = 0x365009FA2Ddb17f386E20854E4B281827619E4D2;

    function run() external returns (CoinDAOFactory factory) {
        require(block.chainid == SEPOLIA_CHAIN_ID, "Sepolia only");
        require(MONOLITH_FACTORY.code.length != 0, "Monolith factory has no code");

        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address beneficiary = vm.envAddress("MONOLITH_BENEFICIARY");
        require(privateKey != 0, "Invalid private key");
        require(beneficiary != address(0), "Invalid Monolith beneficiary");

        address deployer = vm.addr(privateKey);
        console.log("Deployer:", deployer);
        console.log("Monolith factory:", MONOLITH_FACTORY);
        console.log("Monolith beneficiary:", beneficiary);

        vm.startBroadcast(privateKey);
        CoinDAOFactory.Implementations memory implementationSet = CoinDAOFactory.Implementations({
            govToken: address(new GovToken()),
            stakedGovToken: address(new StakedGovToken()),
            revenueRouter: address(new RevenueRouter()),
            stakingRewards: address(new StakingRewards()),
            stakingRewardsFunder: address(new StakingRewardsFunder()),
            vestingWallet: address(new CoinDAOVestingWallet())
        });
        factory = new CoinDAOFactory(IMonolithFactory(MONOLITH_FACTORY), beneficiary, implementationSet);
        vm.stopBroadcast();

        require(address(factory.monolithFactory()) == MONOLITH_FACTORY, "Incorrect Monolith factory");
        require(factory.monolithBeneficiary() == beneficiary, "Incorrect Monolith beneficiary");
        require(factory.govTokenImplementation() == implementationSet.govToken, "Incorrect GOV implementation");
        require(
            factory.stakedGovTokenImplementation() == implementationSet.stakedGovToken,
            "Incorrect staked GOV implementation"
        );
        require(
            factory.revenueRouterImplementation() == implementationSet.revenueRouter, "Incorrect router implementation"
        );
        require(
            factory.stakingRewardsImplementation() == implementationSet.stakingRewards,
            "Incorrect rewards implementation"
        );
        require(
            factory.stakingRewardsFunderImplementation() == implementationSet.stakingRewardsFunder,
            "Incorrect funder implementation"
        );
        require(
            factory.vestingWalletImplementation() == implementationSet.vestingWallet, "Incorrect vesting implementation"
        );

        console.log("GOV implementation:", implementationSet.govToken);
        console.log("Staked GOV implementation:", implementationSet.stakedGovToken);
        console.log("Revenue router implementation:", implementationSet.revenueRouter);
        console.log("Staking rewards implementation:", implementationSet.stakingRewards);
        console.log("Rewards funder implementation:", implementationSet.stakingRewardsFunder);
        console.log("Vesting wallet implementation:", implementationSet.vestingWallet);
        console.log("CoinDAO factory:", address(factory));
    }
}
