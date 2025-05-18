# Withdrawing Supplied Assets in Morpho

## Withdraw Function

```solidity
function withdraw(
    MarketParams memory marketParams,
    uint256 assets,
    uint256 shares,
    address owner,
    address receiver
) external returns (uint256 returnAssets, uint256 returnShares);
```

The `withdraw` function allows users to withdraw previously supplied assets from a market. This is distinct from `withdrawCollateral`, as it deals with the lending side of the protocol rather than collateral for borrowing. Suppliers who have provided liquidity to the market can withdraw their assets plus any accrued interest, subject to available liquidity.

## Implementation for MinimalistPerps

```solidity
contract MinimalistPerps {
    // Morpho interface reference
    IMorpho public immutable morpho;
    
    /**
     * @notice Withdraw previously supplied assets from a market
     * @param marketParams The market parameters
     * @param assets The amount of assets to withdraw (specify 0 if using shares)
     * @param shares The amount of shares to withdraw (specify 0 if using assets)
     * @param owner The address that owns the supply position
     * @param receiver The address that will receive the withdrawn assets
     * @return returnAssets The amount of assets withdrawn
     * @return returnShares The amount of shares burned
     */
    function withdrawSuppliedAssets(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address owner,
        address receiver
    ) external returns (uint256 returnAssets, uint256 returnShares) {
        // Validate input
        if ((assets == 0 && shares == 0) || (assets > 0 && shares > 0)) {
            revert InconsistentInput();
        }
        
        if (receiver == address(0)) revert ZeroAddress();
        
        // Get market ID
        bytes32 marketId = morpho.idFromMarketParams(marketParams);
        
        // Verify market exists
        if (!morpho.isMarketCreated(marketId)) revert MarketNotCreated();
        
        // Authorization check
        if (owner != msg.sender && !morpho.isAuthorized(owner, msg.sender)) {
            revert Unauthorized(owner, msg.sender);
        }
        
        // Check available liquidity
        if (assets > 0) {
            uint256 availableLiquidity = _calculateAvailableLiquidity(marketId);
            if (assets > availableLiquidity) {
                revert InsufficientLiquidity(assets, availableLiquidity);
            }
        } else {
            // For shares, calculate the corresponding asset amount
            uint256 totalSupplyAssets = morpho.totalSupplyAssets(marketId);
            uint256 totalSupplyShares = morpho.totalSupplyShares(marketId);
            uint256 estimatedAssets = shares.toAssetsDown(totalSupplyAssets, totalSupplyShares);
            
            uint256 availableLiquidity = _calculateAvailableLiquidity(marketId);
            if (estimatedAssets > availableLiquidity) {
                revert InsufficientLiquidity(estimatedAssets, availableLiquidity);
            }
        }
        
        // Execute withdrawal
        try morpho.withdraw(
            marketParams,
            assets,
            shares,
            owner,
            receiver
        ) returns (uint256 withdrawnAssets, uint256 withdrawnShares) {
            returnAssets = withdrawnAssets;
            returnShares = withdrawnShares;
            
            emit AssetsWithdrawn(marketId, msg.sender, owner, receiver, withdrawnAssets, withdrawnShares);
            
            return (returnAssets, returnShares);
        } catch Error(string memory reason) {
            // Handle specific error cases
            revert WithdrawalFailed(reason);
        }
    }
    
    /**
     * @notice Helper function to calculate available liquidity in a market
     * @param marketId The market ID
     * @return availableLiquidity The amount of liquidity available for withdrawal
     */
    function _calculateAvailableLiquidity(bytes32 marketId) internal view returns (uint256 availableLiquidity) {
        uint256 totalSupply = morpho.totalSupplyAssets(marketId);
        uint256 totalBorrow = morpho.totalBorrowAssets(marketId);
        
        return totalSupply - totalBorrow;
    }
    
    /**
     * @notice Calculate the maximum withdrawable amount for a user
     * @param marketParams The market parameters
     * @param owner The address that owns the supply position
     * @return maxWithdrawable The maximum amount of assets that can be withdrawn
     * @return maxShares The corresponding amount of shares
     */
    function maxWithdrawable(
        MarketParams memory marketParams,
        address owner
    ) external view returns (uint256 maxWithdrawable, uint256 maxShares) {
        bytes32 marketId = morpho.idFromMarketParams(marketParams);
        
        // Get user's supply shares
        uint256 supplyShares = morpho.supplyShares(marketId, owner);
        
        if (supplyShares == 0) {
            return (0, 0);
        }
        
        // Convert shares to assets
        uint256 totalSupplyAssets = morpho.totalSupplyAssets(marketId);
        uint256 totalSupplyShares = morpho.totalSupplyShares(marketId);
        uint256 userAssets = supplyShares.toAssets(totalSupplyAssets, totalSupplyShares);
        
        // Calculate available liquidity in the market
        uint256 availableLiquidity = _calculateAvailableLiquidity(marketId);
        
        // The user can withdraw the minimum of their balance or available liquidity
        maxWithdrawable = userAssets < availableLiquidity ? userAssets : availableLiquidity;
        
        // Calculate the corresponding shares
        maxShares = maxWithdrawable.toSharesUp(totalSupplyAssets, totalSupplyShares);
        
        return (maxWithdrawable, maxShares);
    }
}
```

## Usage Examples

### Basic Asset Withdrawal

```solidity
// Withdraw supplied assets
function withdrawLiquidity(uint256 amount) external {
    // Get market parameters
    MarketParams memory params = minimalistPerps.getMarketParams(USDC_MARKET_ID);
    
    // Withdraw assets to self
    (uint256 withdrawnAssets, uint256 withdrawnShares) = minimalistPerps.withdrawSuppliedAssets(
        params,
        amount,
        0,          // no shares specified
        address(this), // owner
        address(this)  // receiver
    );
    
    console.log("Withdrawn assets:", withdrawnAssets);
    console.log("Burned shares:", withdrawnShares);
}
```

### Maximum Withdrawal

```solidity
// Withdraw the maximum possible amount
function withdrawMaxLiquidity() external {
    // Get market parameters
    MarketParams memory params = minimalistPerps.getMarketParams(USDC_MARKET_ID);
    
    // Calculate max withdrawable amount
    (uint256 maxAmount, ) = minimalistPerps.maxWithdrawable(
        params,
        address(this)
    );
    
    if (maxAmount == 0) {
        console.log("No assets available for withdrawal");
        return;
    }
    
    // Apply safety buffer (95% of max)
    uint256 safeAmount = (maxAmount * 95) / 100;
    
    // Withdraw assets
    (uint256 withdrawnAssets, uint256 withdrawnShares) = minimalistPerps.withdrawSuppliedAssets(
        params,
        safeAmount,
        0,
        address(this), // owner
        address(this)  // receiver
    );
    
    console.log("Withdrawn assets:", withdrawnAssets);
    console.log("Burned shares:", withdrawnShares);
}
```

### Share-Based Withdrawal

```solidity
// Withdraw by specifying shares instead of asset amount
function withdrawShares(uint256 sharesToWithdraw) external {
    // Get market parameters
    MarketParams memory params = minimalistPerps.getMarketParams(USDC_MARKET_ID);
    
    // Withdraw based on shares
    (uint256 withdrawnAssets, uint256 withdrawnShares) = minimalistPerps.withdrawSuppliedAssets(
        params,
        0,                // no assets specified
        sharesToWithdraw, // exact shares
        address(this),    // owner
        address(this)     // receiver
    );
    
    console.log("Withdrawn assets:", withdrawnAssets);
    console.log("Burned shares:", withdrawnShares);
}
```

### Authorized Withdrawal on Behalf

```solidity
// Withdraw on behalf of another user (who has authorized this contract)
function withdrawOnBehalf(
    address user, 
    bytes32 marketId, 
    uint256 amount
) external onlyManager {
    // Get market parameters
    MarketParams memory params = minimalistPerps.getMarketParams(marketId);
    
    // Withdraw on behalf with proper authorization
    (uint256 withdrawnAssets, uint256 withdrawnShares) = minimalistPerps.withdrawSuppliedAssets(
        params,
        amount,
        0,
        user,         // owner (the user who authorized this contract)
        address(this) // receiver (the manager contract)
    );
    
    // Process the withdrawn assets
    address loanToken = params.loanToken;
    
    // Update accounting records
    managedAssets[user][loanToken] -= withdrawnAssets;
    
    // Perform additional operations with the withdrawn assets
    // (e.g., reinvest, distribute, etc.)
    
    emit AssetsManagedForUser(user, marketId, withdrawnAssets);
}
```

## Liquidity Check and Available Balance

```solidity
// Check if a withdrawal can be processed
function canWithdraw(
    bytes32 marketId,
    address user,
    uint256 withdrawAmount
) public view returns (bool canProcess, string memory reason) {
    MarketParams memory params = minimalistPerps.getMarketParams(marketId);
    
    // Check user's balance
    uint256 supplyShares = morpho.supplyShares(marketId, user);
    if (supplyShares == 0) {
        return (false, "No supply balance");
    }
    
    // Convert shares to assets
    uint256 totalSupplyAssets = morpho.totalSupplyAssets(marketId);
    uint256 totalSupplyShares = morpho.totalSupplyShares(marketId);
    uint256 userAssets = supplyShares.toAssets(totalSupplyAssets, totalSupplyShares);
    
    if (withdrawAmount > userAssets) {
        return (false, "Insufficient balance");
    }
    
    // Check available liquidity
    uint256 totalBorrow = morpho.totalBorrowAssets(marketId);
    uint256 availableLiquidity = totalSupplyAssets - totalBorrow;
    
    if (withdrawAmount > availableLiquidity) {
        return (false, "Insufficient liquidity");
    }
    
    return (true, "");
}
```

## Calculating Earned Interest

```solidity
// Calculate interest earned on supplied assets
function calculateEarnedInterest(
    bytes32 marketId,
    address user,
    uint256 initialSupplyAmount
) public view returns (uint256 interestEarned) {
    uint256 supplyShares = morpho.supplyShares(marketId, user);
    
    if (supplyShares == 0) {
        return 0;
    }
    
    // Convert shares to current asset value
    uint256 totalSupplyAssets = morpho.totalSupplyAssets(marketId);
    uint256 totalSupplyShares = morpho.totalSupplyShares(marketId);
    uint256 currentAssetValue = supplyShares.toAssets(totalSupplyAssets, totalSupplyShares);
    
    // Interest earned is the difference between current value and initial supply
    if (currentAssetValue > initialSupplyAmount) {
        interestEarned = currentAssetValue - initialSupplyAmount;
    } else {
        interestEarned = 0;
    }
    
    return interestEarned;
}
```

## Error Handling

```solidity
// Custom errors
error InconsistentInput();
error ZeroAddress();
error MarketNotCreated();
error Unauthorized(address owner, address caller);
error InsufficientLiquidity(uint256 requested, uint256 available);
error WithdrawalFailed(string reason);

// Events
event AssetsWithdrawn(
    bytes32 indexed marketId,
    address indexed caller,
    address indexed owner,
    address receiver,
    uint256 assets,
    uint256 shares
);

event AssetsManagedForUser(
    address indexed user,
    bytes32 indexed marketId,
    uint256 assets
);
```

## Integration with Yield Strategies

The withdrawal functionality integrates with yield optimization strategies:

```solidity
contract YieldStrategy {
    MinimalistPerps public immutable perps;
    mapping(bytes32 => uint256) public depositedAmounts;
    mapping(bytes32 => uint256) public lastInterestIndex;
    
    constructor(address _perps) {
        perps = MinimalistPerps(_perps);
    }
    
    // Rebalance assets between markets for optimal yield
    function rebalance() external onlyManager {
        bytes32[] memory markets = getActiveMarkets();
        uint256[] memory apys = new uint256[](markets.length);
        
        // Find highest APY market
        bytes32 highestApyMarket = findHighestApyMarket(markets);
        
        // Withdraw from lower-yielding markets
        for (uint256 i = 0; i < markets.length; i++) {
            if (markets[i] != highestApyMarket && depositedAmounts[markets[i]] > 0) {
                MarketParams memory params = perps.getMarketParams(markets[i]);
                
                // Calculate max withdrawable
                (uint256 maxAmount, ) = perps.maxWithdrawable(params, address(this));
                
                if (maxAmount > 0) {
                    // Withdraw liquidity
                    (uint256 withdrawn, ) = perps.withdrawSuppliedAssets(
                        params,
                        maxAmount,
                        0,
                        address(this),
                        address(this)
                    );
                    
                    // Update tracking
                    depositedAmounts[markets[i]] -= withdrawn;
                    
                    // Supply to highest APY market
                    if (withdrawn > 0) {
                        supplyToHighestYieldMarket(highestApyMarket, withdrawn);
                    }
                }
            }
        }
    }
    
    // Helper to find market with highest APY
    function findHighestApyMarket(bytes32[] memory markets) internal view returns (bytes32) {
        // Implementation details...
    }
    
    // Helper to supply to highest yield market
    function supplyToHighestYieldMarket(bytes32 market, uint256 amount) internal {
        // Implementation details...
    }
}
```

## Security Considerations

1. **Liquidity Constraints**:
   - Withdrawals are limited by the available liquidity in the market
   - Some assets may be borrowed and unavailable for immediate withdrawal
   - Consider implementing withdrawal queues for large withdrawals

2. **Authorization Control**:
   - Only the owner or an authorized address can withdraw assets
   - Implement secure authorization mechanisms with explicit approval and revocation
   - Monitor for suspicious withdrawal patterns

3. **Share Price Impact**:
   - Large withdrawals can affect the share price for remaining users
   - Consider gradual withdrawal approaches for large positions
   - Monitor share price manipulations

4. **Interest Accrual**:
   - Interest accrues continuously, affecting withdrawal amounts
   - Ensure accurate share-to-asset conversions
   - Consider interest accrual timing in transaction ordering

5. **Gas Optimization**:
   - Large withdrawals may consume significant gas
   - Batch smaller withdrawals over time for gas efficiency
   - Consider gas costs in withdrawal strategies

6. **MEV Protection**:
   - Withdrawals may be susceptible to MEV extraction
   - Consider private transaction pools for large withdrawals
   - Use transaction ordering protection mechanisms

7. **Accounting Precision**:
   - Share-to-asset conversions may result in rounding errors
   - Ensure consistent rounding direction for accounting safety
   - Maintain precise tracking of user positions 

## Simplified Implementation from MorphoBlueSnippets

MorphoBlueSnippets provides several simplified withdrawal implementations that handle common use cases for withdrawing assets:

### Continued Asset Withdrawal

```solidity
/// @notice Handles the withdrawal of a specified amount of assets by the caller from a specific market.
/// @param marketParams The parameters of the market.
/// @param amount The amount of assets the user is withdrawing.
/// @return assetsWithdrawn The actual amount of assets withdrawn.
/// @return sharesWithdrawn The shares withdrawn in return for the assets.
function withdrawAmount(MarketParams memory marketParams, uint256 amount)
    external
    returns (uint256 assetsWithdrawn, uint256 sharesWithdrawn)
{
    uint256 shares;
    address onBehalf = msg.sender;
    address receiver = msg.sender;

    (assetsWithdrawn, sharesWithdrawn) = morpho.withdraw(marketParams, amount, shares, onBehalf, receiver);
}
```

### Withdraw 50% of Assets

```solidity
/// @notice Handles the withdrawal of 50% of the assets by the caller from a specific market.
/// @param marketParams The parameters of the market.
/// @return assetsWithdrawn The actual amount of assets withdrawn.
/// @return sharesWithdrawn The shares withdrawn in return for the assets.
function withdraw50Percent(MarketParams memory marketParams)
    external
    returns (uint256 assetsWithdrawn, uint256 sharesWithdrawn)
{
    Id marketId = marketParams.id();
    uint256 supplyShares = morpho.position(marketId, msg.sender).supplyShares;
    uint256 amount;
    uint256 shares = supplyShares / 2;

    address onBehalf = msg.sender;
    address receiver = msg.sender;

    (assetsWithdrawn, sharesWithdrawn) = morpho.withdraw(marketParams, amount, shares, onBehalf, receiver);
}
```

### Withdraw All Assets

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

### Withdraw Specified Amount or All

A particularly useful pattern is to withdraw a specific amount if available, or all assets if the requested amount exceeds the user's balance:

```solidity
/// @notice Handles the withdrawal of a specified amount of assets by the caller from a specific market. If the
/// amount is greater than the total amount suplied by the user, withdraws all the shares of the user.
/// @param marketParams The parameters of the market.
/// @param amount The amount of assets the user is withdrawing.
/// @return assetsWithdrawn The actual amount of assets withdrawn.
/// @return sharesWithdrawn The shares withdrawn in return for the assets.
function withdrawAmountOrAll(MarketParams memory marketParams, uint256 amount)
    external
    returns (uint256 assetsWithdrawn, uint256 sharesWithdrawn)
{
    Id id = marketParams.id();

    address onBehalf = msg.sender;
    address receiver = msg.sender;

    morpho.accrueInterest(marketParams);
    uint256 totalSupplyAssets = morpho.totalSupplyAssets(id);
    uint256 totalSupplyShares = morpho.totalSupplyShares(id);
    uint256 shares = morpho.supplyShares(id, msg.sender);

    uint256 assetsMax = shares.toAssetsDown(totalSupplyAssets, totalSupplyShares);

    if (amount >= assetsMax) {
        (assetsWithdrawn, sharesWithdrawn) = morpho.withdraw(marketParams, 0, shares, onBehalf, receiver);
    } else {
        (assetsWithdrawn, sharesWithdrawn) = morpho.withdraw(marketParams, amount, 0, onBehalf, receiver);
    }
}
```

## APY Calculation and Market Analysis

When making withdrawal decisions, it's important to understand the current yield of the market. MorphoBlueSnippets provides methods to calculate APY and analyze market conditions:

### Supply APY Calculation

```solidity
/// @notice Calculates the supply APY (Annual Percentage Yield) for a given market.
/// @param marketParams The parameters of the market.
/// @param market The market for which the supply APY is being calculated.
/// @return supplyApy The calculated supply APY (scaled by WAD).
function supplyAPY(MarketParams memory marketParams, Market memory market)
    public
    view
    returns (uint256 supplyApy)
{
    (uint256 totalSupplyAssets,, uint256 totalBorrowAssets,) = morpho.expectedMarketBalances(marketParams);

    // Get the borrow rate
    if (marketParams.irm != address(0)) {
        uint256 utilization = totalBorrowAssets == 0 ? 0 : totalBorrowAssets.wDivUp(totalSupplyAssets);
        supplyApy = borrowAPY(marketParams, market).wMulDown(1 ether - market.fee).wMulDown(utilization);
    }
}
```

### Borrow APY Calculation

```solidity
/// @notice Calculates the borrow APY (Annual Percentage Yield) for a given market.
/// @param marketParams The parameters of the market.
/// @param market The state of the market.
/// @return borrowApy The calculated borrow APY (scaled by WAD).
function borrowAPY(MarketParams memory marketParams, Market memory market)
    public
    view
    returns (uint256 borrowApy)
{
    if (marketParams.irm != address(0)) {
        borrowApy = IIrm(marketParams.irm).borrowRateView(marketParams, market).wTaylorCompounded(365 days);
    }
}
```

### Market Total Supply and Borrow

```solidity
/// @notice Calculates the total supply of assets in a specific market.
/// @param marketParams The parameters of the market.
/// @return totalSupplyAssets The calculated total supply of assets.
function marketTotalSupply(MarketParams memory marketParams) public view returns (uint256 totalSupplyAssets) {
    totalSupplyAssets = morpho.expectedTotalSupplyAssets(marketParams);
}

/// @notice Calculates the total borrow of assets in a specific market.
/// @param marketParams The parameters of the market.
/// @return totalBorrowAssets The calculated total borrow of assets.
function marketTotalBorrow(MarketParams memory marketParams) public view returns (uint256 totalBorrowAssets) {
    totalBorrowAssets = morpho.expectedTotalBorrowAssets(marketParams);
}
```

### User Supply Balance

```solidity
/// @notice Calculates the total supply balance of a given user in a specific market.
/// @param marketParams The parameters of the market.
/// @param user The address of the user whose supply balance is being calculated.
/// @return totalSupplyAssets The calculated total supply balance.
function supplyAssetsUser(MarketParams memory marketParams, address user)
    public
    view
    returns (uint256 totalSupplyAssets)
{
    totalSupplyAssets = morpho.expectedSupplyAssets(marketParams, user);
}
```

## Optimizing Withdrawal Strategies

When implementing withdrawal strategies, consider these approaches:

### Strategy 1: Yield Comparison Before Withdrawal

```solidity
function shouldWithdraw(MarketParams memory marketParams, Market memory market) public view returns (bool) {
    // Get current supply APY
    uint256 currentApy = supplyAPY(marketParams, market);
    
    // Get alternative investment opportunity APY (e.g., from another protocol)
    uint256 alternativeApy = getAlternativeInvestmentApy();
    
    // Consider gas costs in the calculation
    uint256 estimatedGasCost = 200000; // gas units
    uint256 gasPrice = tx.gasprice;
    uint256 gasCostInEth = estimatedGasCost * gasPrice;
    
    // Convert gas cost to token terms
    uint256 gasCostInToken = convertEthToToken(gasCostInEth);
    
    // Calculate how much the APY difference needs to be to justify the withdrawal
    uint256 userSupply = supplyAssetsUser(marketParams, msg.sender);
    uint256 minApyDifference = (gasCostInToken * WAD) / userSupply;
    
    // Only withdraw if the alternative is sufficiently better
    return alternativeApy > currentApy + minApyDifference;
}
```

### Strategy 2: Partial Withdrawal Based on Utilization

```solidity
function optimizedWithdrawalAmount(MarketParams memory marketParams) public view returns (uint256) {
    // Get market utilization
    (uint256 totalSupply,, uint256 totalBorrow,) = morpho.expectedMarketBalances(marketParams);
    uint256 utilization = totalBorrow.wDivUp(totalSupply);
    
    // Get user's total supply
    uint256 userSupply = supplyAssetsUser(marketParams, msg.sender);
    
    // If utilization is high, withdraw less to avoid liquidity issues
    if (utilization > 0.8 * WAD) { // 80% utilization
        return userSupply / 4;      // Withdraw only 25%
    } else if (utilization > 0.5 * WAD) { // 50% utilization
        return userSupply / 2;      // Withdraw 50%
    } else {
        return userSupply;          // Safe to withdraw all
    }
}
```

### Strategy 3: Time-Based Withdrawal to Maximize Interest

```solidity
mapping(address => uint256) public lastInterestAccrualTime;

function withdrawWithMaximizedInterest(MarketParams memory marketParams) external {
    // Check if interest has accrued since last withdrawal
    uint256 lastAccrualTime = lastInterestAccrualTime[msg.sender];
    
    // Only withdraw if sufficient interest has accrued (e.g., hourly)
    if (block.timestamp >= lastAccrualTime + 1 hours) {
        // Explicitly accrue interest to ensure all earnings are captured
        morpho.accrueInterest(marketParams);
        
        // Withdraw all assets
        (uint256 withdrawnAssets, ) = withdrawAll(marketParams);
        
        // Update last accrual time
        lastInterestAccrualTime[msg.sender] = block.timestamp;
        
        // Use the withdrawn assets...
    }
}
```

## Complete Position Management Workflow

A typical workflow for managing lending positions using MorphoBlueSnippets might look like:

1. **Supply Assets**:
   ```solidity
   (uint256 assetsSupplied, uint256 sharesReceived) = snippets.supply(marketParams, supplyAmount);
   ```

2. **Monitor APY**:
   ```solidity
   uint256 currentApy = snippets.supplyAPY(marketParams, market);
   ```

3. **Check Balance**:
   ```solidity
   uint256 balance = snippets.supplyAssetsUser(marketParams, address(this));
   ```

4. **Partial Withdrawal**:
   ```solidity
   (uint256 withdrawnAssets, ) = snippets.withdraw50Percent(marketParams);
   ```

5. **Full Withdrawal**:
   ```solidity
   (uint256 withdrawnAssets, ) = snippets.withdrawAll(marketParams);
   ```

By combining these functions, users can effectively manage their lending positions while maximizing returns and minimizing risks. 