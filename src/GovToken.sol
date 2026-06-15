// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

contract GovToken is ERC20, ERC20Permit {
    constructor(string memory name_, string memory symbol_, address initialHolder, uint256 initialSupply)
        ERC20(name_, symbol_)
        ERC20Permit(name_)
    {
        _mint(initialHolder, initialSupply);
    }
}
