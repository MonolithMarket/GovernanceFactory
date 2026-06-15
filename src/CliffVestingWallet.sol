// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {VestingWallet} from "@openzeppelin/contracts/finance/VestingWallet.sol";
import {VestingWalletCliff} from "@openzeppelin/contracts/finance/VestingWalletCliff.sol";

contract CliffVestingWallet is VestingWalletCliff {
    constructor(address beneficiary, uint64 startTimestamp, uint64 durationSeconds, uint64 cliffSeconds)
        VestingWallet(beneficiary, startTimestamp, durationSeconds)
        VestingWalletCliff(cliffSeconds)
    {}
}
