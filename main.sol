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
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts);
}

contract EasyTradeV2 is ReentrancyGuard, Ownable {

    event KiteSwapExecuted(
        address indexed trader,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 feeWei,
        uint256 swapId
    );
    event KiteSwapBatchExecuted(address indexed trader, uint256 swapCount, uint256 totalFeeWei, uint256 fromSwapId);
    event KiteQuoteRecorded(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOutEst, uint256 atBlock);
    event KiteFeeWithdrawn(address indexed to, uint256 amountWei);
    event KiteRouterUpdated(address indexed previousRouter, address indexed newRouter, uint256 updateNumber);
    event KiteSnapshotSealed(uint256 indexed epochId, uint256 blockNum, uint256 swapCountAtEpoch);

    error ET_ZeroAmount();
    error ET_ZeroAddress();
    error ET_PathLength();
    error ET_SlippageExceeded();
    error ET_TransferInFailed();
    error ET_TransferOutFailed();
    error ET_ApproveFailed();
    error ET_RouterCallFailed();
    error ET_Paused();
    error ET_BatchLengthMismatch();
    error ET_RouterUpdatesExhausted();

