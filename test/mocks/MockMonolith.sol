// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.23;

import {IMonolithFactory} from "../../src/interfaces/IMonolith.sol";
import {MockERC20} from "./MockERC20.sol";

contract MockMonolithLender {
    address public operator;
    address public pendingOperator;
    address public manager;
    address public immutable coin;
    address public immutable vault;
    uint256 public accruedLocalReserves;

    error Unauthorized();
    error ZeroAddress();

    constructor(address operator_, address manager_, address coin_, address vault_) {
        operator = operator_;
        manager = manager_;
        coin = coin_;
        vault = vault_;
    }

    function setPendingOperator(address pendingOperator_) external {
        if (msg.sender != operator) revert Unauthorized();
        pendingOperator = pendingOperator_;
    }

    function acceptOperator() external {
        if (msg.sender != pendingOperator) revert Unauthorized();
        operator = pendingOperator;
        pendingOperator = address(0);
    }

    function setManager(address manager_) external {
        if (msg.sender != operator && msg.sender != manager) revert Unauthorized();
        if (manager_ == address(0)) revert ZeroAddress();
        manager = manager_;
    }

    function setAccruedLocalReserves(uint256 amount) external {
        accruedLocalReserves = amount;
    }

    function pullLocalReserves() external {
        if (accruedLocalReserves == 0) return;
        MockERC20(coin).mint(operator, accruedLocalReserves);
        accruedLocalReserves = 0;
    }
}

contract MockMonolithFactory is IMonolithFactory {
    address[] public lenders;
    DeployParams public lastParams;

    event Deployed(address indexed lender, address indexed coin, address indexed vault);

    function deploy(DeployParams calldata params) external returns (address lender, address coin, address vault) {
        lastParams = params;
        MockERC20 coinToken = new MockERC20(params.name, params.symbol);
        MockERC20 vaultToken = new MockERC20(string.concat("Staked ", params.name), string.concat("s", params.symbol));
        MockMonolithLender mockLender =
            new MockMonolithLender(params.operator, params.manager, address(coinToken), address(vaultToken));

        lender = address(mockLender);
        coin = address(coinToken);
        vault = address(vaultToken);
        lenders.push(lender);
        emit Deployed(lender, coin, vault);
    }

    function deploymentsLength() external view returns (uint256) {
        return lenders.length;
    }
}
