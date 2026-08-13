pragma solidity ^0.8.26;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {
    ERC20PermitUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";

uint256 constant GOV_TOKEN_SUPPLY = 10_000_000 * 1e18;

contract GovToken is ERC20Upgradeable, ERC20PermitUpgradeable {
    bytes32 internal constant _IMPLEMENTATION_ID = keccak256("MonolithCoinDAO.GovToken.v1");

    constructor() {
        _disableInitializers();
    }

    function initialize(string memory name_, string memory symbol_, address initialHolder) external initializer {
        if (initialHolder == address(0)) revert ZeroAddress();

        __ERC20_init(name_, symbol_);
        __ERC20Permit_init(name_);
        _mint(initialHolder, GOV_TOKEN_SUPPLY);
    }

    function implementationId() external pure returns (bytes32) {
        return _IMPLEMENTATION_ID;
    }

    error ZeroAddress();
}
