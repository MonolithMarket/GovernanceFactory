// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IMonolithFactory {
    struct DeployParams {
        string name;
        string symbol;
        address collateral;
        address psmAsset;
        address psmVault;
        address feed;
        uint256 collateralFactor;
        uint256 minDebt;
        uint256 timeUntilImmutability;
        address operator;
        address manager;
        address eventTriggerOperator;
        uint64 halfLife;
        uint16 targetPsmDebtRatioStartBps;
        uint16 targetPsmDebtRatioEndBps;
        uint32 stalenessThreshold;
        uint16 maxBorrowDeltaBps;
        uint128 psmVaultMinTotalSupply;
    }

    function deploy(DeployParams calldata params) external returns (address lender, address coin, address vault);
}

interface IMonolithLender {
    function setPendingOperator(address pendingOperator) external;
    function acceptOperator() external;
}
