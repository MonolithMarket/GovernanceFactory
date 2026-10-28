// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {
    TimelockControllerUpgradeable
} from "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";

/// @notice Timelock implementation for permanently pinned CoinDAO minimal proxies.
contract CoinDAOTimelock is TimelockControllerUpgradeable {
    constructor() {
        _disableInitializers();
    }
}
