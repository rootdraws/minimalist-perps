# Position Repayment in Morpho

## Repay Function

```solidity
function repay(
    MarketParams memory marketParams,
    uint256 assets,
    uint256 shares,
    address onBehalf,
    bytes calldata data
) external returns (uint256 repaidAssets, uint256 repaidShares);
```

Repayment is a critical function for managing and closing positions in the perpetual futures system. It allows users to pay down borrowed assets on a market, either for themselves or on behalf of other users.

## Implementation for MinimalistPerps

```solidity
contract MinimalistPerps {
    // Morpho interface reference
    IMorpho public immutable morpho;
    
    /**
     * @notice Repay a loan position in the specified market
     * @param marketParams The market parameters
     * @param assets The amount of assets to repay (specify 0 if using shares)
     * @param shares The amount of shares to repay (specify 0 if using assets)
     * @param onBehalf The address whose position to repay
     * @return repaidAssets The amount of assets repaid
     * @return repaidShares The amount of shares repaid
     */
    function repayPosition(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf
    ) external returns (uint256 repaidAssets, uint256 repaidShares) {
        // Verify valid input
        if ((assets == 0 && shares == 0) || (assets > 0 && shares > 0)) {
            revert InconsistentInput();
        }
        
        if (onBehalf == address(0)) revert ZeroAddress();
        
        // Get market ID
        bytes32 marketId = morpho.idFromMarketParams(marketParams);
        
        // Verify market exists
        if (!morpho.isMarketCreated(marketId)) revert MarketNotCreated();
        
        // Get the loan token
        address loanToken = marketParams.loanToken;
        
        // If using assets, calculate the max required
        if (assets > 0) {
            // Pull tokens from caller
            IERC20(loanToken).safeTransferFrom(msg.sender, address(this), assets);
            
            // Approve morpho to use tokens
            IERC20(loanToken).safeApprove(address(morpho), assets);
        } else {
            // For shares, calculate the max assets needed
            uint256 totalBorrowAssets = morpho.totalBorrowAssets(marketId);
            uint256 totalBorrowShares = morpho.totalBorrowShares(marketId);
            uint256 maxAssets = shares.toAssetsUp(totalBorrowAssets, totalBorrowShares);
            
            // Pull tokens from caller
            IERC20(loanToken).safeTransferFrom(msg.sender, address(this), maxAssets);
            
            // Approve morpho to use tokens
            IERC20(loanToken).safeApprove(address(morpho), maxAssets);
        }
        
        // Execute repayment
        (repaidAssets, repaidShares) = morpho.repay(
            marketParams,
            assets,
            shares,
            onBehalf,
            "" // No callback data needed
        );
        
        // If we pulled too many tokens, refund the excess
        if (assets > 0 && repaidAssets < assets) {
            IERC20(loanToken).safeTransfer(msg.sender, assets - repaidAssets);
        } else if (assets == 0) {
            // Calculate how many assets were actually used for the share-based repayment
            uint256 totalBorrowAssets = morpho.totalBorrowAssets(marketId);
            uint256 totalBorrowShares = morpho.totalBorrowShares(marketId);
            uint256 maxAssets = shares.toAssetsUp(totalBorrowAssets, totalBorrowShares);
            
            if (repaidAssets < maxAssets) {
                IERC20(loanToken).safeTransfer(msg.sender, maxAssets - repaidAssets);
            }
        }
        
        emit PositionRepaid(marketId, msg.sender, onBehalf, repaidAssets, repaidShares);
        
        return (repaidAssets, repaidShares);
    }
    
    /**
     * @notice Repay the maximum amount of a borrower's position
     * @param marketParams The market parameters
     * @param onBehalf The address whose position to repay
     * @return repaidAssets The amount of assets repaid
     * @return repaidShares The amount of shares repaid
     */
    function repayPositionMax(
        MarketParams memory marketParams,
        address onBehalf
    ) external returns (uint256 repaidAssets, uint256 repaidShares) {
        if (onBehalf == address(0)) revert ZeroAddress();
        
        // Get market ID
        bytes32 marketId = morpho.idFromMarketParams(marketParams);
        
        // Verify market exists
        if (!morpho.isMarketCreated(marketId)) revert MarketNotCreated();
        
        // Get the loan token
        address loanToken = marketParams.loanToken;
        
        // Get the borrower's share balance
        uint256 borrowShares = morpho.borrowShares(marketId, onBehalf);
        
        if (borrowShares == 0) revert NothingToRepay();
        
        // Calculate the assets needed to repay all shares
        uint256 totalBorrowAssets = morpho.totalBorrowAssets(marketId);
        uint256 totalBorrowShares = morpho.totalBorrowShares(marketId);
        uint256 maxAssets = borrowShares.toAssetsUp(totalBorrowAssets, totalBorrowShares);
        
        // Pull tokens from caller
        IERC20(loanToken).safeTransferFrom(msg.sender, address(this), maxAssets);
        
        // Approve morpho to use tokens
        IERC20(loanToken).safeApprove(address(morpho), maxAssets);
        
        // Execute max repayment
        (repaidAssets, repaidShares) = morpho.repay(
            marketParams,
            0,
            borrowShares,
            onBehalf,
            "" // No callback data needed
        );
        
        // Refund unused assets
        if (repaidAssets < maxAssets) {
            IERC20(loanToken).safeTransfer(msg.sender, maxAssets - repaidAssets);
        }
        
        emit PositionRepaidMax(marketId, msg.sender, onBehalf, repaidAssets, repaidShares);
        
        return (repaidAssets, repaidShares);
    }
}
```

## Usage Examples

### Repaying with Exact Asset Amount

```solidity
// Repay 100 USDC of a position
function repayUSDCPosition(address borrower, uint256 amount) external {
    // Ensure token approval first
    IERC20(USDC).approve(address(minimalistPerps), amount);
    
    MarketParams memory params = minimalistPerps.getMarketParams(USDC_MARKET_ID);
    
    // Repay with exact amount
    (uint256 repaidAssets, uint256 repaidShares) = minimalistPerps.repayPosition(
        params,
        amount, // exact assets
        0,      // no shares specified
        borrower
    );
    
    console.log("Repaid assets:", repaidAssets);
    console.log("Repaid shares:", repaidShares);
}
```

### Repaying with Share Amount

```solidity
// Repay by specifying the share amount
function repayByShares(address borrower, uint256 sharesToRepay) external {
    // Calculate max assets needed first
    MarketParams memory params = minimalistPerps.getMarketParams(WETH_MARKET_ID);
    bytes32 marketId = minimalistPerps.getMarketId(WETH_MARKET_ID);
    
    uint256 totalBorrowAssets = morpho.totalBorrowAssets(marketId);
    uint256 totalBorrowShares = morpho.totalBorrowShares(marketId);
    
    // Maximum amount of assets that could be needed (worst case)
    uint256 maxAssets = sharesToRepay.toAssetsUp(totalBorrowAssets, totalBorrowShares);
    
    // Ensure token approval first
    IERC20(WETH).approve(address(minimalistPerps), maxAssets);
    
    // Repay with exact shares
    (uint256 repaidAssets, uint256 repaidShares) = minimalistPerps.repayPosition(
        params,
        0,            // no assets specified
        sharesToRepay, // exact shares
        borrower
    );
    
    console.log("Repaid assets:", repaidAssets);
    console.log("Repaid shares:", repaidShares);
}
```

### Repaying Maximum Amount

```solidity
// Repay the entire position of a borrower
function repayEntirePosition(address borrower) external {
    MarketParams memory params = minimalistPerps.getMarketParams(USDC_MARKET_ID);
    bytes32 marketId = minimalistPerps.getMarketId(USDC_MARKET_ID);
    
    // Get borrower's position size
    uint256 borrowShares = morpho.borrowShares(marketId, borrower);
    
    // Skip if nothing to repay
    if (borrowShares == 0) return;
    
    // Calculate maximum assets needed
    uint256 totalBorrowAssets = morpho.totalBorrowAssets(marketId);
    uint256 totalBorrowShares = morpho.totalBorrowShares(marketId);
    uint256 maxAssets = borrowShares.toAssetsUp(totalBorrowAssets, totalBorrowShares);
    
    // Ensure token approval first
    IERC20(USDC).approve(address(minimalistPerps), maxAssets);
    
    // Repay max amount
    (uint256 repaidAssets, uint256 repaidShares) = minimalistPerps.repayPositionMax(
        params,
        borrower
    );
    
    console.log("Repaid assets:", repaidAssets);
    console.log("Repaid shares:", repaidShares);
}
```

## Error Handling

```solidity
// Custom errors
error InconsistentInput();
error ZeroAddress();
error MarketNotCreated();
error NothingToRepay();
error InsufficientBalance(uint256 required, uint256 available);

// Events
event PositionRepaid(
    bytes32 indexed marketId,
    address indexed repayer,
    address indexed onBehalf,
    uint256 repaidAssets,
    uint256 repaidShares
);

event PositionRepaidMax(
    bytes32 indexed marketId,
    address indexed repayer,
    address indexed onBehalf,
    uint256 repaidAssets,
    uint256 repaidShares
);
```

## Integration with Position Management

The repay functionality is typically used in the following scenarios:

1. **Position Reduction**: Reducing the size of a leveraged position
2. **Profit Taking**: Using accumulated profits to reduce outstanding debt
3. **Position Closure**: Completely paying off a loan to withdraw collateral
4. **Liquidation Prevention**: Repaying part of a position to avoid liquidation

When implemented as part of a complete position management system:

```solidity
function reducePosition(
    bytes32 marketId,
    uint256 repayAmount,
    uint256 withdrawCollateralAmount
) external {
    MarketParams memory params = getMarketParams(marketId);
    
    // Step 1: Repay debt first
    minimalistPerps.repayPosition(
        params,
        repayAmount,
        0,
        msg.sender
    );
    
    // Step 2: If debt is reduced, collateral can be withdrawn
    if (withdrawCollateralAmount > 0) {
        minimalistPerps.withdrawCollateral(
            params,
            withdrawCollateralAmount,
            msg.sender,
            msg.sender
        );
    }
}
```

## Security Considerations

1. **Partial Repayments**:
   - Ensure health factor remains valid after partial repayments
   - Check position health before allowing collateral withdrawal

2. **Repayment on Behalf**:
   - Anyone can repay on behalf of any borrower
   - This design allows liquidators and helpers to assist positions
   - No special permissions needed to repay someone else's position

3. **Over-Repayment Protection**:
   - Excess tokens are always refunded to the caller
   - System calculates exact repaid amounts and returns them

4. **Shares vs Assets**:
   - Share-based repayment calculations can vary based on accrued interest
   - Asset-based repayments provide more predictable user experience
   - Provide clear UI guidance on expected repayment outcomes

5. **Gas Optimization**:
   - Repaying full positions can save gas on future interest calculations
   - Batch repayments across multiple positions if managing a portfolio 