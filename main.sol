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
    mapping(uint256 epochId => uint256 swapCount) private _snapshotSwapCount;

    constructor() {
        feeCollector = address(0x9C4d6E8f0A2b4c6D8e0F2a4B6c8d0E2f4A6b8C0d);
        weth = address(0x2F5a7B9c1D3e5F7A9b1C3d5E7f9A1b3C5d7E9f1A);
        router = address(0x4A6b8C0d2E4f6A8b0C2d4E6f8A0b2C4d6E8f0A2b);
        genesisBlock = block.number;
        domainSeed = keccak256(abi.encodePacked("EasyTradeV2_Kite_", block.chainid, block.timestamp, address(this)));
    }

    modifier whenNotPaused() {
        if (kitePaused) revert ET_Paused();
        _;
    }

    function setPaused(bool paused) external onlyOwner {
        kitePaused = paused;
    }

    function setRouter(address newRouter) external onlyOwner {
        if (routerUpdateCount >= MAX_ROUTER_UPDATES) revert ET_RouterUpdatesExhausted();
        if (newRouter == address(0)) revert ET_ZeroAddress();
        address prev = router;
        router = newRouter;
        routerUpdateCount++;
        emit KiteRouterUpdated(prev, newRouter, routerUpdateCount);
    }

    function executeSwapExactIn(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        uint256 deadline
    ) external nonReentrant whenNotPaused returns (uint256 amountOut, uint256 feeWei) {
        if (amountIn == 0) revert ET_ZeroAmount();
        if (tokenIn == address(0) || tokenOut == address(0)) revert ET_ZeroAddress();

        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;

        feeWei = (amountIn * FEE_BPS) / BPS_DENOM;
        uint256 amountInAfterFee = amountIn - feeWei;

        IERC20Min(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        if (feeWei > 0) {
            bool ok = IERC20Min(tokenIn).transfer(feeCollector, feeWei);
            if (!ok) revert ET_TransferOutFailed();
        }

        IERC20Min(tokenIn).approve(router, amountInAfterFee);
        uint256 balanceBefore = IERC20Min(tokenOut).balanceOf(msg.sender);

        try IRouterMin(router).swapExactTokensForTokens(
            amountInAfterFee,
            amountOutMin,
            path,
            msg.sender,
            deadline
        ) returns (uint256[] memory amounts) {
            amountOut = amounts[amounts.length - 1];
        } catch {
            IERC20Min(tokenIn).approve(router, 0);
            revert ET_RouterCallFailed();
        }

        IERC20Min(tokenIn).approve(router, 0);
        uint256 balanceAfter = IERC20Min(tokenOut).balanceOf(msg.sender);
        if (balanceAfter <= balanceBefore) revert ET_TransferOutFailed();
        amountOut = balanceAfter - balanceBefore;

        swapCounter++;
        emit KiteSwapExecuted(msg.sender, tokenIn, tokenOut, amountIn, amountOut, feeWei, swapCounter);
        return (amountOut, feeWei);
    }

    struct SwapLeg {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 amountOutMin;
        uint256 deadline;
    }

    /// @notice Execute multiple exact-in swaps in one tx; reverts if any leg fails.
    function executeSwapExactInBatch(SwapLeg[] calldata legs) external nonReentrant whenNotPaused returns (uint256 totalAmountOut, uint256 totalFeeWei) {
        uint256 n = legs.length;
        if (n == 0) revert ET_ZeroAmount();
        uint256 fromSwapId = swapCounter + 1;

        for (uint256 i; i < n; ) {
            SwapLeg calldata leg = legs[i];
            if (leg.amountIn == 0) revert ET_ZeroAmount();
            if (leg.tokenIn == address(0) || leg.tokenOut == address(0)) revert ET_ZeroAddress();

            address[] memory path = new address[](2);
            path[0] = leg.tokenIn;
            path[1] = leg.tokenOut;

            uint256 feeWei = (leg.amountIn * FEE_BPS) / BPS_DENOM;
            uint256 amountInAfterFee = leg.amountIn - feeWei;
            totalFeeWei += feeWei;

            IERC20Min(leg.tokenIn).transferFrom(msg.sender, address(this), leg.amountIn);
            if (feeWei > 0) {
                bool ok = IERC20Min(leg.tokenIn).transfer(feeCollector, feeWei);
                if (!ok) revert ET_TransferOutFailed();
            }

            IERC20Min(leg.tokenIn).approve(router, amountInAfterFee);
            uint256 balanceBefore = IERC20Min(leg.tokenOut).balanceOf(msg.sender);

            try IRouterMin(router).swapExactTokensForTokens(
                amountInAfterFee,
                leg.amountOutMin,
                path,
                msg.sender,
                leg.deadline
            ) { } catch {
                IERC20Min(leg.tokenIn).approve(router, 0);
                revert ET_RouterCallFailed();
            }

            IERC20Min(leg.tokenIn).approve(router, 0);
            uint256 balanceAfter = IERC20Min(leg.tokenOut).balanceOf(msg.sender);
            if (balanceAfter <= balanceBefore) revert ET_TransferOutFailed();
            totalAmountOut += (balanceAfter - balanceBefore);

            swapCounter++;
            unchecked { ++i; }
        }

        emit KiteSwapBatchExecuted(msg.sender, n, totalFeeWei, fromSwapId);
        return (totalAmountOut, totalFeeWei);
    }

    function executeSwapExactInMultiHop(
        address[] calldata path,
        uint256 amountIn,
        uint256 amountOutMin,
        uint256 deadline
    ) external nonReentrant whenNotPaused returns (uint256 amountOut, uint256 feeWei) {
        if (path.length < MIN_PATH_LEN || path.length > MAX_PATH_LEN) revert ET_PathLength();
        if (amountIn == 0) revert ET_ZeroAmount();
        if (path[0] == address(0) || path[path.length - 1] == address(0)) revert ET_ZeroAddress();

        feeWei = (amountIn * FEE_BPS) / BPS_DENOM;
        uint256 amountInAfterFee = amountIn - feeWei;

        IERC20Min(path[0]).transferFrom(msg.sender, address(this), amountIn);
        if (feeWei > 0) {
            bool ok = IERC20Min(path[0]).transfer(feeCollector, feeWei);
            if (!ok) revert ET_TransferOutFailed();
        }

        IERC20Min(path[0]).approve(router, amountInAfterFee);
        address tokenOut = path[path.length - 1];
        uint256 balanceBefore = IERC20Min(tokenOut).balanceOf(msg.sender);

        try IRouterMin(router).swapExactTokensForTokens(
            amountInAfterFee,
            amountOutMin,
            path,
            msg.sender,
            deadline
        ) returns (uint256[] memory amounts) {
            amountOut = amounts[amounts.length - 1];
        } catch {
            IERC20Min(path[0]).approve(router, 0);
            revert ET_RouterCallFailed();
        }

        IERC20Min(path[0]).approve(router, 0);
        uint256 balanceAfter = IERC20Min(tokenOut).balanceOf(msg.sender);
        if (balanceAfter <= balanceBefore) revert ET_TransferOutFailed();
        amountOut = balanceAfter - balanceBefore;

        swapCounter++;
        emit KiteSwapExecuted(msg.sender, path[0], tokenOut, amountIn, amountOut, feeWei, swapCounter);
        return (amountOut, feeWei);
    }

    /// @notice Seal current swap count and block for an epoch (owner only); for settlement reporting.
    function snapshot(uint256 epochId) external onlyOwner {
        _snapshotBlock[epochId] = block.number;
        _snapshotSwapCount[epochId] = swapCounter;
        emit KiteSnapshotSealed(epochId, block.number, swapCounter);
    }

    /// @notice Quote exact-in raw output from router (no fee deducted).
    function quoteExactIn(address tokenIn, address tokenOut, uint256 amountIn)
        external
        view
        returns (uint256 amountOutEst)
    {
        if (amountIn == 0 || tokenIn == address(0) || tokenOut == address(0)) return 0;
        address[] memory p = _path(tokenIn, tokenOut);
        try IRouterMin(router).getAmountsOut(amountIn, p) returns (uint256[] memory amounts) {
            if (amounts.length < 2) return 0;
            return amounts[amounts.length - 1];
        } catch {
            return 0;
        }
    }

    /// @notice Quote exact-in output after deducting fee from input (amountIn * (1 - FEE_BPS/BPS_DENOM)).
    function quoteExactInNet(address tokenIn, address tokenOut, uint256 amountIn)
        external
