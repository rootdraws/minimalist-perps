# Withdrawing Collateral in Morpho

## Withdraw Collateral Function

```solidity
function withdrawCollateral(
    MarketParams memory marketParams,
    uint256 amount,
    address owner,
    address receiver
) external;
```

The `withdrawCollateral` function allows users to withdraw previously deposited collateral from a market. This is an essential operation for managing risk exposure, taking profits, and closing positions in the perpetual futures system.

## Implementation for MinimalistPerps

```solidity
contract MinimalistPerps {
    // Morpho interface reference
    IMorpho public immutable morpho;
    
    /**
     * @notice Withdraw collateral from a position in the specified market
     * @param marketParams The market parameters
     * @param amount The amount of collateral to withdraw
     * @param owner The address that owns the collateral position
     * @param receiver The address that will receive the withdrawn collateral
     * @return withdrawnAmount The amount of collateral withdrawn
     */
    function withdrawCollateral(
        MarketParams memory marketParams,
        uint256 amount,
        address owner,
        address receiver
    ) external returns (uint256 withdrawnAmount) {
        // Validate input
        if (amount == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        
        // Get market ID
        bytes32 marketId = morpho.idFromMarketParams(marketParams);
        
        // Verify market exists
        if (!morpho.isMarketCreated(marketId)) revert MarketNotCreated();
        
        // Authorization check
        if (owner != msg.sender && !morpho.isAuthorized(owner, msg.sender)) {
            revert Unauthorized(owner, msg.sender);
        }
        
        // Check if withdrawal would make position unhealthy
        uint256 borrowShares = morpho.borrowShares(marketId, owner);
        
        // If there are active borrows, verify the position remains healthy
        if (borrowShares > 0) {
            // Check position health after withdrawal
            uint256 collateralBalance = morpho.collateral(marketId, owner);
            
            if (amount > collateralBalance) revert InsufficientCollateral();
            
            // Calculate remaining collateral after withdrawal
            uint256 remainingCollateral = collateralBalance - amount;
            
            // Get the loan token amount from borrow shares
            uint256 totalBorrowAssets = morpho.totalBorrowAssets(marketId);
            uint256 totalBorrowShares = morpho.totalBorrowShares(marketId);
            uint256 borrowBalance = borrowShares.toAssets(totalBorrowAssets, totalBorrowShares);
            
            // Get oracle price and LLTV
            uint256 oraclePrice = IOracle(marketParams.oracle).getPrice();
            uint256 lltv = marketParams.lltv;
            
            // Calculate minimum required collateral
            uint256 minCollateral = (borrowBalance * WAD * WAD) / (oraclePrice * lltv);
            
            // Verify remaining collateral is sufficient
            if (remainingCollateral < minCollateral) {
                revert InsufficientCollateral();
            }
        }
        
        // Execute withdrawal
        try morpho.withdrawCollateral(
            marketParams,
            amount,
            owner,
            receiver
        ) returns (uint256 withdrawn) {
            withdrawnAmount = withdrawn;
            
            emit CollateralWithdrawn(marketId, msg.sender, owner, receiver, amount);
            
            return withdrawnAmount;
        } catch Error(string memory reason) {
            // Handle specific error cases
            revert CollateralWithdrawalFailed(reason);
        }
    }
    
    /**
     * @notice Calculate the maximum withdrawable collateral amount for a user
     * @param marketParams The market parameters
     * @param owner The address that owns the position
     * @return maxWithdrawable The maximum amount that can be withdrawn
     */
    function maxWithdrawableCollateral(
        MarketParams memory marketParams,
        address owner
    ) external view returns (uint256 maxWithdrawable) {
        bytes32 marketId = morpho.idFromMarketParams(marketParams);
        
        // Get current collateral balance
        uint256 collateralBalance = morpho.collateral(marketId, owner);
        
        // Get borrow shares
        uint256 borrowShares = morpho.borrowShares(marketId, owner);
        
        // If no borrow, all collateral can be withdrawn
        if (borrowShares == 0) {
            return collateralBalance;
        }
        
        // Convert borrow shares to assets
        uint256 totalBorrowAssets = morpho.totalBorrowAssets(marketId);
        uint256 totalBorrowShares = morpho.totalBorrowShares(marketId);
        uint256 borrowBalance = borrowShares.toAssets(totalBorrowAssets, totalBorrowShares);
        
        // Get oracle price and LLTV
        uint256 oraclePrice = IOracle(marketParams.oracle).getPrice();
        uint256 lltv = marketParams.lltv;
        
        // Calculate minimum required collateral
        uint256 minCollateral = (borrowBalance * WAD * WAD) / (oraclePrice * lltv);
        
        // Calculate max withdrawable amount
        if (collateralBalance <= minCollateral) {
            maxWithdrawable = 0;
        } else {
            maxWithdrawable = collateralBalance - minCollateral;
        }
        
        return maxWithdrawable;
    }
}
```

## Usage Examples

### Basic Collateral Withdrawal

```solidity
// Withdraw collateral when no debt is present
function withdrawIdleCollateral(uint256 amount) external {
    // Get market parameters
    MarketParams memory params = minimalistPerps.getMarketParams(USDC_MARKET_ID);
    
    // Withdraw collateral to self
    uint256 withdrawnAmount = minimalistPerps.withdrawCollateral(
        params,
        amount,
        address(this), // owner
        address(this)  // receiver
    );
    
    console.log("Withdrawn collateral:", withdrawnAmount);
}
```

### Maximum Safe Withdrawal

```solidity
// Withdraw the maximum possible collateral while keeping position healthy
function withdrawMaxCollateral() external {
    // Get market parameters
    MarketParams memory params = minimalistPerps.getMarketParams(WETH_MARKET_ID);
    
    // Calculate max withdrawable amount
    uint256 maxAmount = minimalistPerps.maxWithdrawableCollateral(
        params,
        address(this)
    );
    
    if (maxAmount == 0) {
        console.log("No collateral available for withdrawal");
        return;
    }
    
    // Apply safety buffer (95% of max)
    uint256 safeAmount = (maxAmount * 95) / 100;
    
    // Withdraw collateral
    uint256 withdrawnAmount = minimalistPerps.withdrawCollateral(
        params,
        safeAmount,
        address(this), // owner
        address(this)  // receiver
    );
    
    console.log("Safely withdrawn collateral:", withdrawnAmount);
}
```

### Authorized Withdrawal on Behalf

```solidity
// Manage collateral for another user (who has authorized this contract)
function withdrawCollateralForUser(
    address user, 
    bytes32 marketId, 
    uint256 amount
) external onlyManager {
    // Get market parameters
    MarketParams memory params = minimalistPerps.getMarketParams(marketId);
    
    // Withdraw on behalf with proper authorization
    uint256 withdrawnAmount = minimalistPerps.withdrawCollateral(
        params,
        amount,
        user,       // owner (the user who authorized this contract)
        address(this) // receiver (the manager contract)
    );
    
    // Process the withdrawn collateral
    IERC20 collateralToken = IERC20(params.collateralToken);
    
    // Update accounting records
    managedCollateral[user] -= withdrawnAmount;
    
    // Perform additional operations with the withdrawn collateral
    // (e.g., reinvest, distribute, etc.)
    
    emit CollateralManagedForUser(user, marketId, withdrawnAmount);
}
```

### Position Closure

```solidity
// Close a position by repaying debt and withdrawing all collateral
function closePosition(bytes32 marketId) external {
    MarketParams memory params = minimalistPerps.getMarketParams(marketId);
    
    // Step 1: Repay all debt first
    minimalistPerps.repayPositionMax(
        params,
        msg.sender
    );
    
    // Step 2: Get collateral balance
    uint256 collateralBalance = morpho.collateral(marketId, msg.sender);
    
    if (collateralBalance > 0) {
        // Step 3: Withdraw all collateral
        minimalistPerps.withdrawCollateral(
            params,
            collateralBalance,
            msg.sender,
            msg.sender
        );
    }
    
    emit PositionClosed(marketId, msg.sender);
}
```

## Health Check Before Withdrawal

```solidity
// Check if a withdrawal would keep the position healthy
function isWithdrawalSafe(
    bytes32 marketId,
    address user,
    uint256 withdrawAmount
) public view returns (bool isSafe) {
    MarketParams memory params = minimalistPerps.getMarketParams(marketId);
    
    // Get current collateral and borrow balances
    uint256 collateralBalance = morpho.collateral(marketId, user);
    uint256 borrowShares = morpho.borrowShares(marketId, user);
    
    // If no borrow or not enough collateral, return accordingly
    if (borrowShares == 0) return true;
    if (withdrawAmount > collateralBalance) return false;
    
    // Convert borrow shares to assets
    uint256 totalBorrowAssets = morpho.totalBorrowAssets(marketId);
    uint256 totalBorrowShares = morpho.totalBorrowShares(marketId);
    uint256 borrowBalance = borrowShares.toAssets(totalBorrowAssets, totalBorrowShares);
    
    // Get oracle price and LLTV
    uint256 oraclePrice = IOracle(params.oracle).getPrice();
    uint256 lltv = params.lltv;
    
    // Calculate remaining collateral after withdrawal
    uint256 remainingCollateral = collateralBalance - withdrawAmount;
    
    // Calculate minimum required collateral
    uint256 minCollateral = (borrowBalance * WAD * WAD) / (oraclePrice * lltv);
    
    // Check if remaining collateral is sufficient
    return remainingCollateral >= minCollateral;
}
```

## Error Handling

```solidity
// Custom errors
error ZeroAmount();
error ZeroAddress();
error MarketNotCreated();
error Unauthorized(address owner, address caller);
error InsufficientCollateral();
error CollateralWithdrawalFailed(string reason);

// Events
event CollateralWithdrawn(
    bytes32 indexed marketId,
    address indexed caller,
    address indexed owner,
    address receiver,
    uint256 amount
);

event PositionClosed(
    bytes32 indexed marketId,
    address indexed owner
);

event CollateralManagedForUser(
    address indexed user,
    bytes32 indexed marketId,
    uint256 amount
);
```

## Integration with Position Management

Collateral withdrawal is a key part of comprehensive position management, working in tandem with other operations:

1. **Position Reduction**:
   - First repay borrowed assets to improve health factor
   - Then withdraw collateral safely without risk of liquidation

2. **Risk Adjustment**:
   - Withdraw collateral from safer positions
   - Add collateral to riskier positions

3. **Profit Taking**:
   - Extract profits by withdrawing excess collateral
   - Keep positions running with appropriate risk levels

4. **Portfolio Rebalancing**:
   - Move collateral between markets based on opportunities
   - Adjust risk exposure across different assets

## Security Considerations

1. **Health Factor Monitoring**:
   - Always check position health before allowing withdrawals
   - Implement safety buffers to account for price volatility
   - Consider using health factor thresholds above the minimum

2. **Oracle Reliance**:
   - Withdrawal safety depends heavily on oracle price accuracy
   - Implement circuit breakers for extreme price movements
   - Consider timelock delays for large withdrawals

3. **Authorization Control**:
   - Carefully manage authorization for withdrawals on behalf of others
   - Implement revocation mechanisms for authorization
   - Consider time-based or amount-based limits on authorization

4. **Front-Running Protection**:
   - Price changes between transaction submission and execution can affect safety
   - Use minimum health factor requirements with safety margins
   - Consider implementing max withdrawal limits per time period

5. **Gas Considerations**:
   - Batch collateral withdrawals when possible
   - Optimize health calculations for gas efficiency
   - Test withdrawal under varying market conditions

6. **Liquidation Prevention**:
   - Prevent withdrawals that would immediately trigger liquidation
   - Implement warnings for withdrawals that bring positions close to liquidation
   - Provide clear visibility into health factor impact of withdrawals 