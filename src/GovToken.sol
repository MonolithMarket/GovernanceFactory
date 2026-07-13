// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

uint256 constant GOV_TOKEN_SUPPLY = 10_000_000 * 1e18;

contract GovToken is ERC20, ERC20Permit {
    constructor(string memory name_, string memory symbol_, address initialHolder)
        ERC20(name_, symbol_)
        ERC20Permit(name_)
    {
        if (initialHolder == address(0)) revert ZeroAddress();
        _mint(initialHolder, GOV_TOKEN_SUPPLY);
    }

    error ZeroAddress();
}
