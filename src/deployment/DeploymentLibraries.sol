pragma solidity ^0.8.26;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import {CoinDAOGovernor} from "../CoinDAOGovernor.sol";

/// @dev External library calls execute with DELEGATECALL, so CREATE2 uses the
/// calling CoinDAOFactory as the deployer for both deployment and prediction.
library CoreDeploymentLib {
    function deployTimelock(
        bytes32 salt,
        uint256 minDelay,
        address[] memory proposers,
        address[] memory executors,
        address admin
    ) external returns (address) {
        return address(new TimelockController{salt: salt}(minDelay, proposers, executors, admin));
    }

    function timelockInitCodeHash(
        uint256 minDelay,
        address[] memory proposers,
        address[] memory executors,
        address admin
    ) external pure returns (bytes32) {
        return keccak256(
            abi.encodePacked(type(TimelockController).creationCode, abi.encode(minDelay, proposers, executors, admin))
        );
    }
}

library GovernorDeploymentLib {
    function deployGovernor(
        bytes32 salt,
        string calldata name_,
        IVotes token_,
        TimelockController timelock_,
        uint256 proposalThreshold_,
        uint256 quorumNumerator_
    ) external returns (address) {
        return address(new CoinDAOGovernor{salt: salt}(name_, token_, timelock_, proposalThreshold_, quorumNumerator_));
    }

    function governorInitCodeHash(
        string calldata name_,
        IVotes token_,
        TimelockController timelock_,
        uint256 proposalThreshold_,
        uint256 quorumNumerator_
    ) external pure returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                type(CoinDAOGovernor).creationCode,
                abi.encode(name_, token_, timelock_, proposalThreshold_, quorumNumerator_)
            )
        );
    }
}
