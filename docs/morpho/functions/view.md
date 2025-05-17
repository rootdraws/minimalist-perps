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
