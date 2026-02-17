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

    uint256 public constant AGGREGATOR_SLIPPAGE_BPS = 50;
    uint256 public constant FEE_BPS = 10;
    uint256 public constant BPS_DENOM = 10000;
    uint256 public constant MIN_PATH_LEN = 2;
    uint256 public constant MAX_PATH_LEN = 6;
    uint256 public constant MAX_ROUTER_UPDATES = 5;
    uint256 public constant KITE_DOMAIN_SEED = 0x3c5e7a9f1b4d6e8c0a2b4d6e8f0a2b4c6d8e0f2a4b6c8d0e2f4a6b8c0d2e4f6a8b;

    address public immutable feeCollector;
    address public immutable weth;
    uint256 public immutable genesisBlock;
    bytes32 public immutable domainSeed;

    address public router;
    uint256 public routerUpdateCount;
    uint256 public swapCounter;
    bool public kitePaused;

    mapping(uint256 epochId => uint256 blockNum) private _snapshotBlock;
