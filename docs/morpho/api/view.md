# View Functions in MinimalistPerps

## Core Query Functions

```solidity
function supplyAPY(MarketParams memory marketParams) external view returns (uint256);
function borrowAPY(MarketParams memory marketParams) external view returns (uint256);
function expectedMarketBalances(MarketParams memory marketParams) external view returns (uint256, uint256, uint256, uint256);
function maxWithdraw(Id id, address owner) external view returns (uint256);
function borrowBalance(Id id, address account) external view returns (uint256);
function supplyBalance(Id id, address account) external view returns (uint256);
```

## Advanced Market Query Functions

The following functions provide detailed market analytics and user position information based on Morpho Blue's design:

```solidity
/// @notice Calculates the supply APY (Annual Percentage Yield) for a given market
/// @param marketParams The parameters of the market
/// @param market The market for which the supply APY is being calculated
/// @return supplyApy The calculated supply APY (scaled by WAD)
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

/// @notice Calculates the borrow APY (Annual Percentage Yield) for a given market
/// @param marketParams The parameters of the market
/// @param market The state of the market
/// @return borrowApy The calculated borrow APY (scaled by WAD)
function borrowAPY(MarketParams memory marketParams, Market memory market)
    public
    view
    returns (uint256 borrowApy)
{
    if (marketParams.irm != address(0)) {
        borrowApy = IIrm(marketParams.irm).borrowRateView(marketParams, market).wTaylorCompounded(365 days);
    }
}

/// @notice Calculates the total supply of assets in a specific market
/// @param marketParams The parameters of the market
/// @return totalSupplyAssets The calculated total supply of assets
function marketTotalSupply(MarketParams memory marketParams) public view returns (uint256 totalSupplyAssets) {
    totalSupplyAssets = morpho.expectedTotalSupplyAssets(marketParams);
}

/// @notice Calculates the total borrow of assets in a specific market
/// @param marketParams The parameters of the market
/// @return totalBorrowAssets The calculated total borrow of assets
function marketTotalBorrow(MarketParams memory marketParams) public view returns (uint256 totalBorrowAssets) {
    totalBorrowAssets = morpho.expectedTotalBorrowAssets(marketParams);
}
```

## User Balance Functions

These functions allow querying user-specific balances in Morpho markets:

```solidity
/// @notice Calculates the total supply balance of a given user in a specific market
/// @param marketParams The parameters of the market
/// @param user The address of the user whose supply balance is being calculated
/// @return totalSupplyAssets The calculated total supply balance
function supplyAssetsUser(MarketParams memory marketParams, address user)
    public
    view
    returns (uint256 totalSupplyAssets)
{
    totalSupplyAssets = morpho.expectedSupplyAssets(marketParams, user);
}

/// @notice Calculates the total borrow balance of a given user in a specific market
/// @param marketParams The parameters of the market
/// @param user The address of the user whose borrow balance is being calculated
/// @return totalBorrowAssets The calculated total borrow balance
function borrowAssetsUser(MarketParams memory marketParams, address user)
    public
    view
    returns (uint256 totalBorrowAssets)
{
    totalBorrowAssets = morpho.expectedBorrowAssets(marketParams, user);
}

/// @notice Calculates the total collateral balance of a given user in a specific market
/// @dev Uses extSloads to load only one storage slot of the Position struct to save gas
/// @param marketId The identifier of the market
/// @param user The address of the user whose collateral balance is being calculated
/// @return totalCollateralAssets The calculated total collateral balance
function collateralAssetsUser(Id marketId, address user) public view returns (uint256 totalCollateralAssets) {
    bytes32[] memory slots = new bytes32[](1);
    slots[0] = MorphoStorageLib.positionBorrowSharesAndCollateralSlot(marketId, user);
    bytes32[] memory values = morpho.extSloads(slots);
    totalCollateralAssets = uint256(values[0] >> 128);
}
```

## Position Health Tracking

```solidity
// Get current health factor with latest debt values
function getPositionHealth(uint256 positionId) public view returns (uint256) {
    if (!_exists(positionId)) revert InvalidPositionId(positionId);
    
    Position storage position = positions[positionId];
    
    // Get latest debt value with accrued interest
    uint256 currentDebt = morpho.borrowBalance(
        marketIdForToken[position.debtToken], 
        address(this)
    );
    
    if (currentDebt == 0) return type(uint256).max; // No debt = maximum health
    
    // Get latest collateral value from oracle
    uint256 collateralValue = getCollateralValue(position.collateralToken, position.collateralAmount);
    
    // Calculate LTV ratio scaled by PRECISION (1e18)
    return (collateralValue * PRECISION) / getDebtValue(position.debtToken, currentDebt);
}

// Check if position is liquidatable
function isLiquidatable(uint256 positionId) public view returns (bool) {
    uint256 health = getPositionHealth(positionId);
    return health < LIQUIDATION_THRESHOLD;
}

// Get maximum withdrawable collateral for a position
function getMaxWithdraw(uint256 positionId) external view returns (uint256) {
    if (!_exists(positionId)) revert InvalidPositionId(positionId);
    Position storage position = positions[positionId];
    
    // Get current debt and collateral values
    uint256 debtValue = getDebtValue(
        position.debtToken, 
        morpho.borrowBalance(marketIdForToken[position.debtToken], address(this))
    );
    uint256 collateralValue = getCollateralValue(position.collateralToken, position.collateralAmount);
    
    // Calculate excess collateral (what can be withdrawn while maintaining min health)
    if (debtValue == 0) return position.collateralAmount;
    
    uint256 requiredCollateralValue = (debtValue * MIN_HEALTH_FACTOR) / PRECISION;
    if (collateralValue <= requiredCollateralValue) return 0;
    
    uint256 excessValue = collateralValue - requiredCollateralValue;
    uint256 collateralPrice = getOraclePrice(position.collateralToken);
    
    // Convert excess value to collateral amount
    return excessValue * PRECISION / collateralPrice;
}

/// @notice Calculates the health factor of a user in a specific market
/// @param marketParams The parameters of the market
/// @param id The identifier of the market
/// @param user The address of the user whose health factor is being calculated
/// @return healthFactor The calculated health factor
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

## Market and Liquidity Monitoring

```solidity
// Get current market status for risk assessment
function getMarketStatus(address token) external view returns (
    uint256 totalSupply,
    uint256 totalBorrow,
    uint256 utilization,
    uint256 availableLiquidity
) {
    if (!supportedMarkets[token]) revert UnsupportedMarket(token);
    
    MarketParams memory params = marketParamsForToken[token];
    
    // Get market balances
    (totalSupply, , totalBorrow, ) = morpho.expectedMarketBalances(params);
    
    // Calculate utilization rate (scaled by 1e18)
    utilization = totalBorrow == 0 ? 0 : (totalBorrow * PRECISION) / totalSupply;
    
    // Calculate available liquidity
    availableLiquidity = totalSupply > totalBorrow ? totalSupply - totalBorrow : 0;
}

// Check liquidity for potential trades
function hasEnoughLiquidity(address token, uint256 amount) public view returns (bool) {
    if (!supportedMarkets[token]) revert UnsupportedMarket(token);
    
    (, , , uint256 liquidity) = getMarketStatus(token);
    
    // Buffer for safety (allow max 80% of available liquidity per trade)
    uint256 safetyBuffer = liquidity * 80 / 100;
    return amount <= safetyBuffer;
}

// Get current funding rate (for position cost calculation)
function getCurrentFundingRate(address token) public view returns (uint256) {
    if (!supportedMarkets[token]) revert UnsupportedMarket(token);
    
    // Get borrowing interest rate
    uint256 borrowRate = morpho.borrowAPY(marketParamsForToken[token]);
    
    // Apply spread factor for protocol margin
    return borrowRate + (borrowRate * fundingRateSpread / MAX_BPS);
}
```

## Position Management Views

```solidity
// Get all user positions
function getUserPositions(address user) external view returns (uint256[] memory) {
    uint256 balance = balanceOf(user);
    if (balance == 0) return new uint256[](0);
    
    uint256[] memory result = new uint256[](balance);
    uint256 index = 0;
    
    // Iterate through user's tokens to find positions
    for (uint256 i = 0; i < balance; i++) {
        uint256 positionId = tokenOfOwnerByIndex(user, i);
        result[index++] = positionId;
    }
    
    return result;
}

// Get full position details
function getPositionDetails(uint256 positionId) external view returns (
    address collateralToken,
    uint256 collateralAmount,
    address debtToken,
    uint256 debtAmount,
    uint256 leverage,
    uint256 healthFactor,
    uint256 liquidationPrice,
    uint256 fundingRate,
    bool isLong
) {
    if (!_exists(positionId)) revert InvalidPositionId(positionId);
    Position storage position = positions[positionId];
    
    collateralToken = position.collateralToken;
    collateralAmount = position.collateralAmount;
    debtToken = position.debtToken;
    
    // Get latest debt with interest
    debtAmount = morpho.borrowBalance(marketIdForToken[debtToken], address(this));
    
    // Calculate derived values
    uint256 collateralValue = getCollateralValue(collateralToken, collateralAmount);
    uint256 debtValue = getDebtValue(debtToken, debtAmount);
    
    leverage = collateralValue * PRECISION / (collateralValue - debtValue);
    healthFactor = getPositionHealth(positionId);
    liquidationPrice = calculateLiquidationPrice(positionId);
    fundingRate = getCurrentFundingRate(position.isLong ? debtToken : collateralToken);
    isLong = position.isLong;
}

// Calculate liquidation price
function calculateLiquidationPrice(uint256 positionId) public view returns (uint256) {
    if (!_exists(positionId)) revert InvalidPositionId(positionId);
    Position storage position = positions[positionId];
    
    uint256 debtAmount = morpho.borrowBalance(marketIdForToken[position.debtToken], address(this));
    uint256 debtValue = getDebtValue(position.debtToken, debtAmount);
    
    // Liquidation price is the price at which health factor reaches liquidation threshold
    uint256 liquidationThresholdValue = (debtValue * LIQUIDATION_THRESHOLD) / PRECISION;
    return liquidationThresholdValue * PRECISION / position.collateralAmount;
}
```

## Error Handling

```solidity
// Custom errors
error InvalidPositionId(uint256 positionId);
error UnsupportedMarket(address token);
error PositionUnderwater(uint256 positionId, uint256 healthFactor);
error ZeroLiquidity(address token);

// Events for tracking
event PositionHealthUpdated(uint256 positionId, uint256 healthFactor);
event LiquidityChecked(address token, uint256 amount, bool sufficient);
```

## Gas-Optimized View Operations

### Storage Slot Direct Access

The MorphoBlueSnippets contract demonstrates how to optimize gas usage for frequent view operations by directly accessing specific storage slots:

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

This approach is significantly more gas-efficient than calling higher-level functions, particularly for applications that need to query many positions in a single transaction or for gas-sensitive operations.

### Expected vs. Actual Balance Calculation

When querying balances, MorphoBlueSnippets provides two approaches with different trade-offs:

1. **Expected balances (including pending interest):**
```solidity
function borrowAssetsUser(MarketParams memory marketParams, address user) public view returns (uint256) {
    return morpho.expectedBorrowAssets(marketParams, user);
}
```

2. **Actual on-chain balances (after accruing interest):**
```solidity
// First explicitly accrue interest
morpho.accrueInterest(marketParams);
// Then get the exact current balance
uint256 totalBorrowAssets = morpho.totalBorrowAssets(id);
```

Choose the appropriate method based on your needs:
- Use `expected*` functions for: UI displays, gas-sensitive operations, approximate calculations
- Use explicit interest accrual for: precise values when executing transactions, critical financial calculations

## Practical Multi-Query Implementations

### Complete Market Dashboard

Here's an optimized implementation for retrieving all relevant market metrics in a single view function:

```solidity
/// @notice Get comprehensive market metrics in a single call
/// @param marketParams The parameters of the market
/// @return Market information bundle with all metrics
function getMarketDashboard(MarketParams memory marketParams) external view returns (
    MarketDashboard memory
) {
    Id id = marketParams.id();
    Market memory market = morpho.market(id);
    
    (uint256 totalSupplyAssets, uint256 totalSupplyShares, uint256 totalBorrowAssets, uint256 totalBorrowShares) = 
        morpho.expectedMarketBalances(marketParams);
    
    uint256 utilization = totalBorrowAssets == 0 ? 0 : totalBorrowAssets.wDivUp(totalSupplyAssets);
    uint256 supplyApy = 0;
    uint256 borrowApy = 0;
    
    if (marketParams.irm != address(0)) {
        borrowApy = IIrm(marketParams.irm).borrowRateView(marketParams, market).wTaylorCompounded(365 days);
        supplyApy = borrowApy.wMulDown(1 ether - market.fee).wMulDown(utilization);
    }
    
    // Calculate additional metrics
    uint256 availableLiquidity = totalSupplyAssets > totalBorrowAssets ? totalSupplyAssets - totalBorrowAssets : 0;
    uint256 sharePrice = totalSupplyShares == 0 ? 1e18 : totalSupplyAssets.wDivDown(totalSupplyShares);
    uint256 debtSharePrice = totalBorrowShares == 0 ? 1e18 : totalBorrowAssets.wDivDown(totalBorrowShares);
    
    return MarketDashboard({
        totalSupply: totalSupplyAssets,
        totalBorrow: totalBorrowAssets,
        utilization: utilization,
        supplyAPY: supplyApy,
        borrowAPY: borrowApy,
        availableLiquidity: availableLiquidity,
        sharePrice: sharePrice,
        debtSharePrice: debtSharePrice,
        fee: market.fee,
        lastUpdateTimestamp: market.lastUpdate
    });
}
```

### User Position Snapshot

Efficiently retrieve all positions for a user across multiple markets:

```solidity
/// @notice Get a snapshot of all user positions across multiple markets
/// @param user The address of the user
/// @param marketParams Array of market parameters to check
/// @return positions Array of position snapshots
function getUserPositionSnapshot(
    address user,
    MarketParams[] memory marketParams
) external view returns (UserPosition[] memory positions) {
    positions = new UserPosition[](marketParams.length);
    
    for (uint256 i = 0; i < marketParams.length; i++) {
        Id id = marketParams[i].id();
        
        // Efficient storage slot access for collateral
        bytes32[] memory slots = new bytes32[](1);
        slots[0] = MorphoStorageLib.positionBorrowSharesAndCollateralSlot(id, user);
        bytes32[] memory values = morpho.extSloads(slots);
        uint256 collateral = uint256(values[0] >> 128);
        
        // Get expected balances with interest
        uint256 borrowed = morpho.expectedBorrowAssets(marketParams[i], user);
        uint256 supplied = morpho.expectedSupplyAssets(marketParams[i], user);
        
        // Calculate health factor if there's borrowed amount
        uint256 healthFactor = type(uint256).max;
        if (borrowed > 0 && collateral > 0) {
            uint256 collateralPrice = IOracle(marketParams[i].oracle).price();
            uint256 maxBorrow = collateral.mulDivDown(collateralPrice, ORACLE_PRICE_SCALE).wMulDown(marketParams[i].lltv);
            healthFactor = maxBorrow.wDivDown(borrowed);
        }
        
        positions[i] = UserPosition({
            marketId: id,
            collateral: collateral,
            borrowed: borrowed,
            supplied: supplied,
            healthFactor: healthFactor
        });
    }
    
    return positions;
}
```

## Best Practices for View Functions

1. **Gas Optimization**
   - Use `extSloads` for direct storage access when possible
   - Batch related queries to reduce total gas costs
   - Use `expectedX` functions for approximate values when appropriate

2. **Balance Calculation**
   - Use `expectedBorrowAssets` and `expectedSupplyAssets` for including pending interest
   - Call `accrueInterest` before critical calculations when precision is essential

3. **Health Factor Calculation**
   - Always use the latest oracle prices when calculating health factors
   - Include special handling for zero borrowing (return max uint)
   - Consider gas costs when calculating health factors for many positions

4. **Frontend Integration**
   - Implement polling for critical values like health factors and liquidation prices
   - Use multicall patterns to batch view function calls from frontends
   - Consider implementing GraphQL or subgraphs for historical data queries
