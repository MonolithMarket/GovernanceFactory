// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IMonolithFactory} from "../../src/interfaces/IMonolith.sol";
import {MockERC20} from "./MockERC20.sol";

contract MockMonolithVault {}

contract MockMonolithLender {
    address public operator;
    address public pendingOperator;
    address public manager;
    address public immutable coin;
    address public immutable vault;

    constructor(address operator_, address manager_, address coin_, address vault_) {
        operator = operator_;
        manager = manager_;
        coin = coin_;
        vault = vault_;
    }

    function setPendingOperator(address pendingOperator_) external {
        require(msg.sender == operator, "Unauthorized");
        pendingOperator = pendingOperator_;
    }

    function acceptOperator() external {
        require(msg.sender == pendingOperator, "Unauthorized");
        operator = pendingOperator;
        pendingOperator = address(0);
    }
}

contract MockMonolithFactory is IMonolithFactory {
    address[] public deployments;
    DeployParams public lastParams;

    event Deployed(address indexed lender, address indexed coin, address indexed vault);

    function deploymentsLength() external view returns (uint256) {
        return deployments.length;
    }

    function deploy(DeployParams calldata params) external returns (address lender, address coin, address vault) {
        lastParams = params;

        MockERC20 coinToken = new MockERC20(params.name, params.symbol);
        MockMonolithVault monolithVault = new MockMonolithVault();
        MockMonolithLender monolithLender =
            new MockMonolithLender(params.operator, params.manager, address(coinToken), address(monolithVault));

        lender = address(monolithLender);
        coin = address(coinToken);
        vault = address(monolithVault);

        deployments.push(lender);
        emit Deployed(lender, coin, vault);
    }
}
