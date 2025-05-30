# Supplying Collateral in Morpho

## Supply Collateral Function

```solidity
function supplyCollateral(
    MarketParams memory marketParams,
    uint256 amount,
    address onBehalf,
    bytes calldata data
) external;
```

Supplying collateral is a fundamental operation in the perpetual futures system. This function allows users to deposit assets as collateral to back their positions, enabling leverage and protecting against market volatility.

## Implementation for MinimalistPerps

```solidity
contract MinimalistPerps {
    // Morpho interface reference
    IMorpho public immutable morpho;
    
    /**
     * @notice Supply collateral to a position in the specified market
     * @param marketParams The market parameters
     * @param amount The amount of collateral to supply
     * @param onBehalf The address that will own the collateral position
     * @return collateralBalance The total collateral balance after supply
     */
    function supplyCollateral(
        MarketParams memory marketParams,
        uint256 amount,
        address onBehalf
    ) external returns (uint256 collateralBalance) {
        // Validate input
        if (amount == 0) revert ZeroAmount();
        if (onBehalf == address(0)) revert ZeroAddress();
        
        // Get market ID
        bytes32 marketId = morpho.idFromMarketParams(marketParams);
        
        // Verify market exists
        if (!morpho.isMarketCreated(marketId)) revert MarketNotCreated();
        
        // Get the collateral token
        address collateralToken = marketParams.collateralToken;
        
        // Pull tokens from caller
        IERC20(collateralToken).safeTransferFrom(msg.sender, address(this), amount);
        
        // Approve morpho to use tokens
        IERC20(collateralToken).safeApprove(address(morpho), amount);
        
        // Execute collateral supply
        try morpho.supplyCollateral(
            marketParams,
            amount,
            onBehalf,
            "" // No callback data needed
        ) {
            // Get updated collateral balance
            collateralBalance = morpho.collateral(marketId, onBehalf);
            
            emit CollateralSupplied(marketId, msg.sender, onBehalf, amount, collateralBalance);
            
            return collateralBalance;
        } catch Error(string memory reason) {
            // Handle specific error cases
            revert CollateralSupplyFailed(reason);
        }
    }
    
    /**
     * @notice Supply collateral in multiple markets or for multiple users in one transaction
     * @param marketParamsArray Array of market parameters
     * @param amounts Array of collateral amounts to supply
     * @param onBehalfArray Array of addresses that will own the collateral positions
     * @return collateralBalances Array of collateral balances after supply
     */
    function batchSupplyCollateral(
        MarketParams[] calldata marketParamsArray,
        uint256[] calldata amounts,
        address[] calldata onBehalfArray
    ) external returns (uint256[] memory collateralBalances) {
        // Validate array lengths
        uint256 length = marketParamsArray.length;
        if (length != amounts.length || length != onBehalfArray.length) {
            revert ArrayLengthMismatch();
        }
        
        collateralBalances = new uint256[](length);
        
        // Process each supply operation
        for (uint256 i = 0; i < length; i++) {
            try this.supplyCollateral(
                marketParamsArray[i],
                amounts[i],
                onBehalfArray[i]
            ) returns (uint256 balance) {
                collateralBalances[i] = balance;
            } catch Error(string memory reason) {
                // Log error but continue with other operations
                emit CollateralSupplyFailed(
                    morpho.idFromMarketParams(marketParamsArray[i]),
                    onBehalfArray[i],
                    reason
                );
            }
        }
        
        return collateralBalances;
    }
}
```

## Usage Examples

### Basic Collateral Supply

```solidity
// Supply 10 ETH as collateral
function supplyETHCollateral(uint256 amount) external {
    // Wrap ETH to WETH first (if using ETH)
    WETH.deposit{value: amount}();
    
    // Ensure token approval
    WETH.approve(address(minimalistPerps), amount);
    
    // Get market parameters
    MarketParams memory params = minimalistPerps.getMarketParams(USDC_MARKET_ID);
    
    // Supply collateral
    uint256 collateralBalance = minimalistPerps.supplyCollateral(
        params,
        amount,
        address(this) // supplying for myself
    );
    
    console.log("New collateral balance:", collateralBalance);
}
```

### Supplying for Another User

```solidity
// Supply collateral on behalf of another user
function supplyCollateralForUser(address user, uint256 amount) external {
    // Ensure token approval
    USDC.approve(address(minimalistPerps), amount);
    
    // Get market parameters
    MarketParams memory params = minimalistPerps.getMarketParams(USDC_MARKET_ID);
    
    // Supply collateral on behalf of user
    uint256 collateralBalance = minimalistPerps.supplyCollateral(
        params,
        amount,
        user // supplying for another user
    );
    
    console.log("User's collateral balance:", collateralBalance);
}
```

### Supplying Across Multiple Markets

```solidity
// Supply collateral across multiple markets
function supplyCollateralMultiMarket(
    uint256 ethAmount,
    uint256 usdcAmount
) external {
    // Approve tokens
    WETH.approve(address(minimalistPerps), ethAmount);
    USDC.approve(address(minimalistPerps), usdcAmount);
    
    // Setup market parameters arrays
    MarketParams[] memory marketParamsArray = new MarketParams[](2);
    marketParamsArray[0] = minimalistPerps.getMarketParams(ETH_USDC_MARKET_ID);
    marketParamsArray[1] = minimalistPerps.getMarketParams(USDC_ETH_MARKET_ID);
    
    // Setup amounts
    uint256[] memory amounts = new uint256[](2);
    amounts[0] = ethAmount;
    amounts[1] = usdcAmount;
    
    // Setup recipients (self for both)
    address[] memory recipients = new address[](2);
    recipients[0] = address(this);
    recipients[1] = address(this);
    
    // Batch supply
    uint256[] memory balances = minimalistPerps.batchSupplyCollateral(
        marketParamsArray,
        amounts,
        recipients
    );
    
    console.log("ETH market collateral balance:", balances[0]);
    console.log("USDC market collateral balance:", balances[1]);
}
```

## Error Handling

```solidity
// Custom errors
error ZeroAmount();
error ZeroAddress();
error MarketNotCreated();
error CollateralSupplyFailed(string reason);
error ArrayLengthMismatch();
error InsufficientBalance(uint256 required, uint256 available);

// Events
event CollateralSupplied(
    bytes32 indexed marketId,
    address indexed supplier,
    address indexed onBehalf,
    uint256 amount,
    uint256 newCollateralBalance
);

event CollateralSupplyFailed(
    bytes32 indexed marketId,
    address indexed onBehalf,
    string reason
);
```

## Integration with Position Management

The supply collateral functionality is a key component in position lifecycle management:

1. **Position Initialization**:
   - Before borrowing, users must supply sufficient collateral
   - Collateral determines the maximum leverage available

2. **Position Expansion**:
   - Adding more collateral allows increasing position size
   - Improves health factor to prevent liquidation

3. **Risk Management**:
   - Additional collateral can be added to protect against volatility
   - Acts as a buffer during market downturns

Example of opening a leveraged position:

```solidity
function openLeveragedPosition(
    bytes32 marketId,
    uint256 collateralAmount,
    uint256 borrowAmount
) external {
    MarketParams memory params = getMarketParams(marketId);
    
    // Step 1: Supply collateral first
    minimalistPerps.supplyCollateral(
        params,
        collateralAmount,
        msg.sender
    );
    
    // Step 2: Borrow against the supplied collateral
    minimalistPerps.borrow(
        params,
        borrowAmount,
        0, // no shares specified
        msg.sender,
        msg.sender
    );
}
```

## Health Factor Calculation

```solidity
function calculateHealthFactor(
    bytes32 marketId,
    address user
) public view returns (uint256 healthFactor) {
    // Get market parameters and oracle price
    MarketParams memory params = getMarketParams(marketId);
    uint256 oraclePrice = IOracle(params.oracle).getPrice();
    
    // Get collateral and debt
    uint256 collateralBalance = morpho.collateral(marketId, user);
    uint256 borrowShares = morpho.borrowShares(marketId, user);
    
    if (borrowShares == 0) {
        // No debt means maximum health factor
        return type(uint256).max;
    }
    
    // Convert borrow shares to assets
    uint256 totalBorrowAssets = morpho.totalBorrowAssets(marketId);
    uint256 totalBorrowShares = morpho.totalBorrowShares(marketId);
    uint256 borrowBalance = borrowShares.toAssets(totalBorrowAssets, totalBorrowShares);
    
    // Get LLTV (Liquidation Loan-To-Value)
    uint256 lltv = params.lltv;
    
    // Calculate collateral value in loan token terms
    uint256 collateralValue = collateralBalance * oraclePrice / 1e18;
    
    // Calculate health factor (collateralValue * 1e18 / (borrowBalance * LLTV))
    // Health factor of 1.0 (1e18) means the position is at liquidation threshold
    healthFactor = collateralValue * 1e18 / (borrowBalance * lltv / 1e18);
    
    return healthFactor;
}
```

## Security Considerations

1. **Collateral Management**:
   - Ensure users understand the relationship between collateral and leverage
   - Implement minimum collateral requirements for different asset types
   - Consider collateral caps per market to limit risk exposure

2. **Oracle Risk**:
   - Collateral value depends on price oracles
   - Implement multiple oracle sources or circuit breakers for critical price feeds
   - Consider time-weighted average prices to mitigate flash crashes

3. **Market-Specific Considerations**:
   - Volatile assets may require higher collateral ratios
   - Low liquidity collateral might need additional buffers
   - Correlation between collateral and borrowed asset affects system risk

4. **Front-Running Protection**:
   - Large collateral deposits might affect oracle prices or funding rates
   - Consider transaction ordering protections for high-value operations

5. **Gas Optimization**:
   - Batch collateral supplies when managing multiple positions
   - Consider gas limits when working with unusual ERC20 tokens
   - Test with tokens that have transfer fees or rebasing mechanisms

6. **Collateral Liquidation**:
   - Clearly communicate liquidation thresholds to users
   - Provide monitoring tools to track position health
   - Consider partial liquidations for large positions 

## Simplified Implementation from MorphoBlueSnippets

Here's a simplified implementation of the `supplyCollateral` function from the MorphoBlueSnippets contract:

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

This implementation:
1. Uses `forceApprove` to approve the Morpho contract to spend the collateral token
2. Transfers the collateral token from the user to the contract
3. Supplies the collateral to Morpho on behalf of the caller
4. Doesn't include any callback data

## Checking Collateral Balances

MorphoBlueSnippets provides an efficient way to check collateral balances using direct storage access:

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

This method uses `extSloads` to efficiently read storage directly, which can save gas compared to using getters.

## Optimized Health Factor Calculation

The MorphoBlueSnippets contract provides a gas-efficient implementation of health factor calculation:

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

Key aspects of this implementation:
1. Uses `expectedBorrowAssets` to include accrued interest
2. Gets the oracle price directly from the market's oracle
3. Calculates the maximum borrow amount based on collateral value and LLTV
4. Returns `type(uint256).max` for positions with no debt
5. Uses `wMulDown` and `wDivDown` for WAD-scaled operations with conservative rounding

## Complete Position Management Workflow

An effective approach to position management integrates supplying collateral with other operations. Here's a complete workflow using MorphoBlueSnippets:

### 1. Supply Collateral

```solidity
// First step: supply collateral to secure the position
snippets.supplyCollateral(marketParams, collateralAmount);
```

### 2. Check Health Factor Before Borrowing

```solidity
// Check current health factor before borrowing
Id marketId = marketParams.id();
uint256 healthFactor = snippets.userHealthFactor(marketParams, marketId, address(this));
```

### 3. Borrow Assets

```solidity
// Borrow assets against supplied collateral
(uint256 assetsBorrowed, uint256 sharesBorrowed) = snippets.borrow(marketParams, borrowAmount);
```

### 4. Monitor Position Health

```solidity
// Check health factor after borrowing to ensure safety
uint256 newHealthFactor = snippets.userHealthFactor(marketParams, marketId, address(this));
require(newHealthFactor >= MINIMUM_HEALTH_FACTOR, "Position too risky");
```

### 5. Add More Collateral if Needed

```solidity
// If health factor is low, add more collateral
if (newHealthFactor < SAFE_HEALTH_FACTOR) {
    snippets.supplyCollateral(marketParams, additionalCollateralAmount);
}
```

### 6. Partial Repayment to Reduce Risk

```solidity
// Repay part of the debt to improve health factor
snippets.repay50Percent(marketParams);
```

### 7. Close Position

```solidity
// Repay all borrowed assets
snippets.repayAll(marketParams);

// Withdraw collateral after debt is cleared
Id marketId = marketParams.id();
uint256 collateralBalance = morpho.collateral(marketId, address(this));
snippets.withdrawCollateral(marketParams, collateralBalance);
```

## Calculating APY for Collateral Utilization Decisions

When deciding how much collateral to supply, it's important to consider the current APY in the market:

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

This function helps users evaluate the cost of borrowing against their collateral, which is essential for making informed decisions about position management. 