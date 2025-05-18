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

## Simplified Implementation from MorphoBlueSnippets

Here's a simplified implementation of `withdrawCollateral` from the MorphoBlueSnippets contract:

```solidity
/// @notice Handles the withdrawal of collateral by the caller from a specific market of a specific amount.
/// @param marketParams The parameters of the market.
/// @param amount The amount of collateral the user is withdrawing.
function withdrawCollateral(MarketParams memory marketParams, uint256 amount) external {
    address onBehalf = msg.sender;
    address receiver = msg.sender;

    morpho.withdrawCollateral(marketParams, amount, onBehalf, receiver);
}
```

This simplified version delegates directly to the Morpho protocol's `withdrawCollateral` method. It automatically uses the caller as both the owner (`onBehalf`) and the receiver, making it ideal for common use cases where users are managing their own positions.

## Health Factor Calculation

Understanding the health factor is crucial for safe collateral withdrawals. The MorphoBlueSnippets contract provides a helpful implementation:

```solidity
/// @notice Calculates the health factor of a user in a specific market.
/// @param marketParams The parameters of the market.
/// @param id The identifier of the market.
/// @param user The address of the user whose health factor is being calculated.
/// @return healthFactor The calculated health factor.
function userHealthFactor(MarketParams memory marketParams, Id id, address user)
    public
    view
    returns (uint256 healthFactor)
{
    uint256 collateralPrice = IOracle(marketParams.oracle).price();
    uint256 collateral = morpho.collateral(id, user);
    uint256 borrowed = morpho.expectedBorrowAssets(marketParams, user);

    uint256 maxBorrow = collateral.mulDivDown(collateralPrice, ORACLE_PRICE_SCALE).wMulDown(marketParams.lltv);

    if (borrowed == 0) return type(uint256).max;
    healthFactor = maxBorrow.wDivDown(borrowed);
}
```

A health factor of 1.0 (represented as WAD or 1e18) means the position is at the liquidation threshold. For safe withdrawals, maintain a health factor above 1.0, with higher values representing safer positions.

## Integration with MorphoBlueSnippets

The MorphoBlueSnippets contract provides a comprehensive set of utility functions that work alongside collateral management. Here are some key complementary functions:

### Supply Collateral

```solidity
/// @notice Handles the supply of collateral by the caller to a specific market.
/// @param marketParams The parameters of the market.
/// @param amount The amount of collateral the user is supplying.
function supplyCollateral(MarketParams memory marketParams, uint256 amount) external {
    ERC20(marketParams.collateralToken).forceApprove(address(morpho), type(uint256).max);
    ERC20(marketParams.collateralToken).safeTransferFrom(msg.sender, address(this), amount);

    address onBehalf = msg.sender;

    morpho.supplyCollateral(marketParams, amount, onBehalf, hex"");
}
```

### Collateral Balance Check

```solidity
/// @notice Calculates the total collateral balance of a given user in a specific market.
/// @dev It uses extSloads to load only one storage slot of the Position struct and save gas.
/// @param marketId The identifier of the market.
/// @param user The address of the user whose collateral balance is being calculated.
/// @return totalCollateralAssets The calculated total collateral balance.
function collateralAssetsUser(Id marketId, address user) public view returns (uint256 totalCollateralAssets) {
    bytes32[] memory slots = new bytes32[](1);
    slots[0] = MorphoStorageLib.positionBorrowSharesAndCollateralSlot(marketId, user);
    bytes32[] memory values = morpho.extSloads(slots);
    totalCollateralAssets = uint256(values[0] >> 128);
}
```

### Position Closing Strategies

When closing positions, consider these complementary functions from MorphoBlueSnippets:

#### Repay All Borrowed Assets

```solidity
/// @notice Handles the repayment of all the borrowed assets by the caller to a specific market.
/// @param marketParams The parameters of the market.
/// @return assetsRepaid The actual amount of assets repaid.
/// @return sharesRepaid The shares repaid in return for the assets.
function repayAll(MarketParams memory marketParams) external returns (uint256 assetsRepaid, uint256 sharesRepaid) {
    ERC20(marketParams.loanToken).forceApprove(address(morpho), type(uint256).max);

    Id marketId = marketParams.id();

    (,, uint256 totalBorrowAssets, uint256 totalBorrowShares) = morpho.expectedMarketBalances(marketParams);
    uint256 borrowShares = morpho.position(marketId, msg.sender).borrowShares;

    uint256 repaidAmount = borrowShares.toAssetsUp(totalBorrowAssets, totalBorrowShares);
    ERC20(marketParams.loanToken).safeTransferFrom(msg.sender, address(this), repaidAmount);

    uint256 amount;
    address onBehalf = msg.sender;
    (assetsRepaid, sharesRepaid) = morpho.repay(marketParams, amount, borrowShares, onBehalf, hex"");
}
```

#### Withdraw All Supplied Assets

```solidity
/// @notice Handles the withdrawal of all the assets by the caller from a specific market.
/// @param marketParams The parameters of the market.
/// @return assetsWithdrawn The actual amount of assets withdrawn.
/// @return sharesWithdrawn The shares withdrawn in return for the assets.
function withdrawAll(MarketParams memory marketParams)
    external
    returns (uint256 assetsWithdrawn, uint256 sharesWithdrawn)
{
    Id marketId = marketParams.id();
    uint256 supplyShares = morpho.position(marketId, msg.sender).supplyShares;
    uint256 amount;

    address onBehalf = msg.sender;
    address receiver = msg.sender;

    (assetsWithdrawn, sharesWithdrawn) = morpho.withdraw(marketParams, amount, supplyShares, onBehalf, receiver);
}
```

## Complete Position Management Workflow

A typical workflow for position management using MorphoBlueSnippets might look like:

1. **Supply Collateral**:
   ```solidity
   snippets.supplyCollateral(marketParams, collateralAmount);
   ```

2. **Borrow Against Collateral**:
   ```solidity
   (uint256 borrowed, ) = snippets.borrow(marketParams, borrowAmount);
   ```

3. **Check Position Health**:
   ```solidity
   uint256 health = snippets.userHealthFactor(marketParams, marketId, user);
   ```

4. **Withdraw Collateral (if safe)**:
   ```solidity
   snippets.withdrawCollateral(marketParams, withdrawAmount);
   ```

5. **Close Position (when needed)**:
   ```solidity
   snippets.repayAll(marketParams);
   // Now that all debt is repaid, collateral can be safely withdrawn
   snippets.withdrawCollateral(marketParams, collateralBalance);
   ```

By combining these functions, users can effectively manage their positions while ensuring they remain safe from liquidation. 