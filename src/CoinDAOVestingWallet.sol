pragma solidity ^0.8.26;

import {VestingWalletUpgradeable} from "@openzeppelin/contracts-upgradeable/finance/VestingWalletUpgradeable.sol";

contract CoinDAOVestingWallet is VestingWalletUpgradeable {
    constructor() {
        _disableInitializers();
    }
}
