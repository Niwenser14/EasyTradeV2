// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title EasyTradeV2
/// @notice Kite routing with batch execution, fee-aware quotes, and sealed snapshots for settlement reconciliation.
/// @dev All deploy-time config immutable; router updatable by owner up to a fixed cap. ReentrancyGuard and explicit checks.

import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/security/ReentrancyGuard.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/access/Ownable.sol";

interface IERC20Min {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IRouterMin {
    function swapExactTokensForTokens(
