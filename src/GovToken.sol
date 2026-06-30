// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.23;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";

uint256 constant GOV_TOKEN_SUPPLY = 10_000_000 * 1e18;

contract GovToken is ERC20, ERC20Permit, ERC20Votes {
    constructor(string memory name_, string memory symbol_, address initialHolder)
        ERC20(name_, symbol_)
        ERC20Permit(name_)
    {
        if (initialHolder == address(0)) revert ZeroAddress();
        _mint(initialHolder, GOV_TOKEN_SUPPLY);
    }

    error ZeroAddress();

    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }

    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }
}
