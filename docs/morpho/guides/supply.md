# Supply (Lending) in Morpho

## Supply Function

```solidity
function supply(
    MarketParams memory marketParams,
    uint256 assets,
    uint256 shares,
    address onBehalf,
    bytes calldata data
) external returns (uint256 returnAssets, uint256 returnShares);
```

The `supply` function is the core lending operation in Morpho, allowing users to provide liquidity to markets. Unlike `supplyCollateral`, which is used to back one's own borrowing positions, the `supply` function makes assets available for other users to borrow, with suppliers earning interest over time.

## Implementation for MinimalistPerps

```solidity
contract MinimalistPerps {
    // Morpho interface reference
    IMorpho public immutable morpho;
    
    /**
     * @notice Supply assets to a market for lending
     * @param marketParams The market parameters
     * @param assets The amount of assets to supply (specify 0 if using shares)
     * @param shares The amount of shares to supply (specify 0 if using assets)
     * @param onBehalf The address that will own the supply position
     * @return returnAssets The amount of assets supplied
     * @return returnShares The amount of shares received
     */
    function supplyLiquidity(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf
    ) external returns (uint256 returnAssets, uint256 returnShares) {
        // Validate input
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
        
        // Calculate the max required transfer amount
        uint256 maxAssets;
        if (assets > 0) {
            maxAssets = assets;
        } else {
            // For shares, calculate the max assets needed
            uint256 totalSupplyAssets = morpho.totalSupplyAssets(marketId);
            uint256 totalSupplyShares = morpho.totalSupplyShares(marketId);
            maxAssets = shares.toAssetsUp(totalSupplyAssets, totalSupplyShares);
        }
        
        // Pull tokens from caller
        IERC20(loanToken).safeTransferFrom(msg.sender, address(this), maxAssets);
        
        // Approve morpho to use tokens
        IERC20(loanToken).safeApprove(address(morpho), maxAssets);
        
        // Execute supply
        try morpho.supply(
            marketParams,
            assets,
            shares,
            onBehalf,
            "" // No callback data needed
        ) returns (uint256 suppliedAssets, uint256 suppliedShares) {
            returnAssets = suppliedAssets;
            returnShares = suppliedShares;
            
            // If we pulled too many tokens, refund the excess
            uint256 refundAmount = maxAssets - suppliedAssets;
            if (refundAmount > 0) {
                IERC20(loanToken).safeTransfer(msg.sender, refundAmount);
            }
            
            emit LiquiditySupplied(marketId, msg.sender, onBehalf, suppliedAssets, suppliedShares);
            
            return (returnAssets, returnShares);
        } catch Error(string memory reason) {
            // Handle specific error cases
            revert SupplyFailed(reason);
        }
    }
    
    /**
     * @notice Calculate the current balance of a supplier including accrued interest
     * @param marketParams The market parameters
     * @param supplier The address of the supplier
     * @return assets The current value of the supply position in assets
     * @return shares The current shares owned by the supplier
     */
    function getSupplyBalance(
        MarketParams memory marketParams,
        address supplier
    ) external view returns (uint256 assets, uint256 shares) {
        bytes32 marketId = morpho.idFromMarketParams(marketParams);
        
        // Get the supplier's share balance
        shares = morpho.supplyShares(marketId, supplier);
        
        if (shares == 0) return (0, 0);
        
        // Convert shares to assets
        uint256 totalSupplyAssets = morpho.totalSupplyAssets(marketId);
        uint256 totalSupplyShares = morpho.totalSupplyShares(marketId);
        
        // Calculate the asset value
        assets = shares.toAssets(totalSupplyAssets, totalSupplyShares);
        
        return (assets, shares);
    }
}
```

## Usage Examples

### Supplying with Exact Asset Amount

```solidity
// Supply 1000 USDC to the lending pool
function supplyUSDCLiquidity(uint256 amount) external {
    // Ensure token approval first
    IERC20(USDC).approve(address(minimalistPerps), amount);
    
    // Get market parameters
    MarketParams memory params = minimalistPerps.getMarketParams(USDC_MARKET_ID);
    
    // Supply liquidity with exact amount
    (uint256 suppliedAssets, uint256 suppliedShares) = minimalistPerps.supplyLiquidity(
        params,
        amount, // exact assets
        0,      // no shares specified
        address(this) // supplying for myself
    );
    
    console.log("Supplied assets:", suppliedAssets);
    console.log("Received shares:", suppliedShares);
}
```

### Supplying with Share Amount

```solidity
// Supply liquidity by specifying the share amount
function supplyByShares(uint256 sharesToMint) external {
    // Get market parameters
    MarketParams memory params = minimalistPerps.getMarketParams(WETH_MARKET_ID);
    bytes32 marketId = minimalistPerps.getMarketId(WETH_MARKET_ID);
    
    // Calculate assets needed
    uint256 totalSupplyAssets = morpho.totalSupplyAssets(marketId);
    uint256 totalSupplyShares = morpho.totalSupplyShares(marketId);
    
    // Maximum amount of assets that could be needed (worst case)
    uint256 maxAssets = sharesToMint.toAssetsUp(totalSupplyAssets, totalSupplyShares);
    
    // Ensure token approval
    IERC20(WETH).approve(address(minimalistPerps), maxAssets);
    
    // Supply with exact shares
    (uint256 suppliedAssets, uint256 suppliedShares) = minimalistPerps.supplyLiquidity(
        params,
        0,            // no assets specified
        sharesToMint, // exact shares
        address(this) // supplying for myself
    );
    
    console.log("Supplied assets:", suppliedAssets);
    console.log("Received shares:", suppliedShares);
}
```

### Supplying on Behalf of Others

```solidity
// Supply liquidity on behalf of another address (e.g., for a vault)
function supplyForVault(address vault, uint256 amount) external onlyVaultManager {
    // Ensure token approval
    IERC20(USDC).approve(address(minimalistPerps), amount);
    
    // Get market parameters
    MarketParams memory params = minimalistPerps.getMarketParams(USDC_MARKET_ID);
    
    // Supply liquidity to vault's balance
    (uint256 suppliedAssets, uint256 suppliedShares) = minimalistPerps.supplyLiquidity(
        params,
        amount,
        0,
        vault // supplying on behalf of the vault
    );
    
    // Update vault accounting
    vaultSupplyBalances[vault] += suppliedAssets;
    
    emit VaultSupplied(vault, suppliedAssets, suppliedShares);
}
```

## Tracking Interest and Earnings

```solidity
// Calculate the interest earned by a supplier
function calculateSupplyInterestEarned(
    bytes32 marketId, 
    address supplier,
    uint256 initialSupplyAmount
) external view returns (uint256 interestEarned) {
    // Get current supply balance
    (uint256 currentAssets, ) = minimalistPerps.getSupplyBalance(
        marketId,
        supplier
    );
    
    // Interest earned is the difference between current balance and initial supply
    if (currentAssets > initialSupplyAmount) {
        interestEarned = currentAssets - initialSupplyAmount;
    } else {
        interestEarned = 0;
    }
    
    return interestEarned;
}
```

## APY Calculation

```solidity
// Calculate the current APY for suppliers in a market
function calculateSupplyAPY(bytes32 marketId) public view returns (uint256 apy) {
    MarketParams memory params = getMarketParams(marketId);
    
    // Get current interest rate model
    IIrm irm = IIrm(params.irm);
    
    // Get current utilization ratio
    uint256 totalSupply = morpho.totalSupplyAssets(marketId);
    uint256 totalBorrow = morpho.totalBorrowAssets(marketId);
    
    // Avoid division by zero
    if (totalSupply == 0) return 0;
    
    uint256 utilization = totalBorrow * 1e18 / totalSupply;
    
    // Get borrow rate from IRM (in ray, 1e27)
    uint256 borrowRate = irm.borrowRateView(params, utilization);
    
    // Calculate supply rate (borrow rate * utilization * (1 - fee))
    uint256 fee = morpho.fee(marketId);
    uint256 supplyRate = borrowRate * utilization * (WAD - fee) / WAD / 1e27;
    
    // Convert to APY (compounded per block to annual)
    // Assuming 7200 blocks per day (12 sec block time)
    uint256 blocksPerYear = 7200 * 365;
    
    // Formula: (1 + rate per block)^blocks per year - 1
    apy = ((1e18 + supplyRate) ** blocksPerYear) - 1e18;
    
    return apy;
}
```

## Error Handling

```solidity
// Custom errors
error InconsistentInput();
error ZeroAddress();
error MarketNotCreated();
error SupplyFailed(string reason);
error InsufficientAllowance(uint256 required, uint256 available);

// Events
event LiquiditySupplied(
    bytes32 indexed marketId,
    address indexed supplier,
    address indexed onBehalf,
    uint256 assets,
    uint256 shares
);

event VaultSupplied(
    address indexed vault,
    uint256 assets,
    uint256 shares
);
```

## Integration with Yield Strategies

The supply functionality can be integrated with automated yield strategies:

```solidity
contract YieldOptimizer {
    MinimalistPerps public immutable perps;
    
    // Track where funds are allocated
    mapping(bytes32 => uint256) public marketAllocations;
    
    constructor(address _perps) {
        perps = MinimalistPerps(_perps);
    }
    
    // Rebalance funds across markets based on APY
    function rebalanceFunds() external onlyManager {
        bytes32[] memory markets = getActiveMarkets();
        uint256[] memory apys = new uint256[](markets.length);
        
        // Get APY for each market
        for (uint256 i = 0; i < markets.length; i++) {
            apys[i] = perps.calculateSupplyAPY(markets[i]);
        }
        
        // Find best market
        uint256 bestMarketIndex = 0;
        for (uint256 i = 1; i < markets.length; i++) {
            if (apys[i] > apys[bestMarketIndex]) {
                bestMarketIndex = i;
            }
        }
        
        // Withdraw from lower yield markets
        for (uint256 i = 0; i < markets.length; i++) {
            if (i != bestMarketIndex && marketAllocations[markets[i]] > 0) {
                // Withdraw from this market
                withdrawFromMarket(markets[i]);
            }
        }
        
        // Supply to highest yield market
        MarketParams memory bestMarketParams = perps.getMarketParams(markets[bestMarketIndex]);
        uint256 availableFunds = IERC20(bestMarketParams.loanToken).balanceOf(address(this));
        
        if (availableFunds > 0) {
            // Supply to best market
            IERC20(bestMarketParams.loanToken).approve(address(perps), availableFunds);
            (uint256 supplied, ) = perps.supplyLiquidity(
                bestMarketParams,
                availableFunds,
                0,
                address(this)
            );
            
            marketAllocations[markets[bestMarketIndex]] += supplied;
        }
    }
    
    // Helper function to withdraw from a market
    function withdrawFromMarket(bytes32 marketId) internal {
        // Implementation for withdrawal
    }
}
```

## Security Considerations

1. **Interest Rate Risk**:
   - Supply rates fluctuate with utilization rate
   - Monitor APY changes over time
   - Consider rate caps to prevent extreme volatility

2. **Liquidity Risk**:
   - Withdrawals might be constrained if most assets are borrowed
   - Consider adding time locks or withdrawal limits for large suppliers
   - Monitor utilization rates for early warning signs

3. **Market Risk**:
   - Value of supplied assets can change due to external market conditions
   - Diversify across multiple markets to reduce exposure
   - Consider protocols with insurance mechanisms

4. **Smart Contract Risk**:
   - Supply operations depend on the security of the underlying protocol
   - Use security features like pausability and withdrawal limits
   - Test against reentrancy and other common vulnerabilities

5. **Systemic Risk**:
   - Supply operations can be affected by broader market conditions
   - Monitor total value locked (TVL) across markets
   - Establish circuit breakers for extreme market conditions

6. **APY Optimization**:
   - Frequent rebalancing can result in gas inefficiency
   - Set minimum APY differentials before triggering a rebalance
   - Consider gas costs in yield calculations

7. **Accounting Precision**:
   - Share-based accounting can lead to rounding errors
   - Use consistent rounding directions (always round down for supply shares)
   - Test with extreme values and edge cases 

## Simplified Implementation from MorphoBlueSnippets

The MorphoBlueSnippets contract provides a streamlined implementation of the supply function that handles common use cases:

```solidity
/// @notice Handles the supply of assets by the caller to a specific market.
/// @param marketParams The parameters of the market.
/// @param amount The amount of assets the user is supplying.
/// @return assetsSupplied The actual amount of assets supplied.
/// @return sharesSupplied The shares supplied in return for the assets.
function supply(MarketParams memory marketParams, uint256 amount)
    external
    returns (uint256 assetsSupplied, uint256 sharesSupplied)
{
    ERC20(marketParams.loanToken).forceApprove(address(morpho), type(uint256).max);
    ERC20(marketParams.loanToken).safeTransferFrom(msg.sender, address(this), amount);

    uint256 shares;
    address onBehalf = msg.sender;

    (assetsSupplied, sharesSupplied) = morpho.supply(marketParams, amount, shares, onBehalf, hex"");
}
```

This implementation:
1. Uses `forceApprove` to approve the Morpho contract to spend the loan token (solves common approval issues)
2. Transfers the loan token from the user to the contract
3. Supplies the assets to Morpho on behalf of the caller 
4. Returns both the supplied assets and the corresponding shares

## Enhanced Market Analysis and APY Calculation

MorphoBlueSnippets offers precise APY calculation functions that use the actual market state:

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

Key improvements over the previous implementation:
1. Uses `expectedMarketBalances` to include pending interest accruals
2. Utilizes the Taylor series approximation for compounding via `wTaylorCompounded`
3. Properly handles the fee calculation
4. More accurately represents the relationship between supply and borrow rates

## Efficient Balance Checking

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

This function uses `expectedSupplyAssets` to include accrued interest, providing a more accurate real-time balance than simply converting shares to assets based on current totals.

## Withdrawal Strategies

MorphoBlueSnippets implements several efficient withdrawal strategies to complement supply operations:

### Partial Withdrawal (50%)

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

### Complete Withdrawal

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

### Smart Withdrawal (Amount or All)

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

This function is particularly useful as it explicitly calls `accrueInterest` before calculating the maximum withdrawable amount, ensuring all interest is included. It then intelligently chooses between withdrawing a specific amount or all available assets.

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

3. **Check Balance with Interest**:
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

By combining these functions, users can effectively manage their lending positions while maximizing interest earnings and minimizing gas costs. 