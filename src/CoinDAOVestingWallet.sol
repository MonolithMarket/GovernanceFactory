pragma solidity ^0.8.26;

import {VestingWalletUpgradeable} from "@openzeppelin/contracts-upgradeable/finance/VestingWalletUpgradeable.sol";

contract CoinDAOVestingWallet is VestingWalletUpgradeable {
    bytes32 internal constant _IMPLEMENTATION_ID = keccak256("MonolithCoinDAO.VestingWallet.v1");

    constructor() {
        _disableInitializers();
    }

    function implementationId() external pure returns (bytes32) {
        return _IMPLEMENTATION_ID;
    }
}
