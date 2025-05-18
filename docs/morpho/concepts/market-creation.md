# Market Creation in Morpho

## Market Parameters Structure

```solidity
struct MarketParams {
    address loanToken;       // Token that can be borrowed (e.g., BTCN)
    address collateralToken; // Token used as collateral (e.g., USDT)
    address oracle;          // Price oracle for token pair
    address irm;             // Interest Rate Model contract
    uint256 lltv;            // Loan-to-Value ratio (liquidation threshold)
}
```

## Required Steps for Market Creation

```solidity
// 1. Enable the Interest Rate Model (if not already enabled)
function enableIrm(address irm) external onlyOwner {
    if (irm == address(0)) revert ZeroAddress();
    if (_isIrmEnabled[irm]) revert AlreadyEnabled();
    
    _isIrmEnabled[irm] = true;
    emit IrmEnabled(irm);
}

// 2. Enable the Loan-to-Value ratio (if not already enabled)
function enableLltv(uint256 lltv) external onlyOwner {
    if (lltv > WAD) revert LltvTooHigh();
    if (_isLltvEnabled[lltv]) revert AlreadyEnabled();
    
    _isLltvEnabled[lltv] = true;
    emit LltvEnabled(lltv);
}

// 3. Create the market with the prepared parameters
function createMarket(MarketParams memory marketParams) external onlyOwner returns (Id id) {
    // Validations will be performed by Morpho
    id = morpho.createMarket(marketParams);
    
    // Store market parameters for our contract
    Id marketId = marketParams.id();
    supportedMarkets[marketParams.loanToken] = true;
    supportedMarkets[marketParams.collateralToken] = true;
    marketParamsForToken[marketParams.loanToken] = marketParams;
    marketParamsForToken[marketParams.collateralToken] = marketParams;
    marketIdForToken[marketParams.loanToken] = marketId;
    marketIdForToken[marketParams.collateralToken] = marketId;
    
    emit MarketCreated(marketId, marketParams.loanToken, marketParams.collateralToken);
    return id;
}
```

## Validation Checks

When creating a market, Morpho enforces these validations:

1. The IRM must be enabled (`isIrmEnabled(marketParams.irm) == true`)
2. The LLTV must be enabled (`isLltvEnabled(marketParams.lltv) == true`)
3. The market must not already exist

## Creating a BTCN/USDT Market

Here's a step-by-step example for creating a BTCN/USDT market:

```solidity
// Contract setup and constants
address public constant BTCN = 0x1234...;  // BTCN token address
address public constant USDT = 0xabcd...;  // USDT token address
address public constant ORACLE = 0x9876...; // Price oracle for BTCN/USDT
address public constant IRM = 0xdef0...;   // Interest Rate Model
uint256 public constant LLTV = 0.8 * 1e18; // 80% LTV (expressed in WAD, 18 decimals)

// Function to initialize BTCN/USDT market
function setupBTCNUSDTMarket() external onlyOwner {
    // 1. Enable IRM if not already enabled
    if (!morpho.isIrmEnabled(IRM)) {
        morpho.enableIrm(IRM);
    }
    
    // 2. Enable LLTV if not already enabled
    if (!morpho.isLltvEnabled(LLTV)) {
        morpho.enableLltv(LLTV);
    }
    
    // 3. Create market parameters
    MarketParams memory params = MarketParams({
        loanToken: BTCN,
        collateralToken: USDT,
        oracle: ORACLE,
        irm: IRM,
        lltv: LLTV
    });
    
    // 4. Create market
    try morpho.createMarket(params) returns (Id marketId) {
        // 5. Store market information in our contract
        btcnUsdtMarketId = marketId;
        // Additional setup...
        emit MarketSetupComplete(BTCN, USDT, marketId);
    } catch Error(string memory reason) {
        emit MarketSetupFailed(BTCN, USDT, reason);
    }
}
```

## Market IDs and Retrieval

```solidity
// Generate market ID from parameters (for verification)
function getMarketId(
    address loanToken,
    address collateralToken,
    address oracle,
    address irm,
    uint256 lltv
) public pure returns (bytes32) {
    MarketParams memory params = MarketParams({
        loanToken: loanToken,
        collateralToken: collateralToken,
        oracle: oracle,
        irm: irm,
        lltv: lltv
    });
    
    return params.id();
}

// Retrieve market parameters from ID
function getMarketParams(Id marketId) public view returns (MarketParams memory) {
    return morpho.idToMarketParams(marketId);
}
```

## Recommended LLTV Values

Different assets have different risk profiles, and LLTV values should be set accordingly:

| Asset Pair | Recommended LLTV | Notes |
|------------|------------------|-------|
| ETH/USDC   | 80% (0.8e18)     | Major asset, relatively stable |
| WBTC/USDT  | 75% (0.75e18)    | Volatile but major asset |
| BTCN/USDT  | 70% (0.7e18)     | Newer asset, higher volatility |
| Altcoins   | 50-65% (0.5-0.65e18) | Higher risk |

## Error Handling

```solidity
// Custom errors
error ZeroAddress();
error AlreadyEnabled();
error LltvTooHigh();
error MarketAlreadyExists(bytes32 marketId);
error InvalidMarketParams();
error IrmNotEnabled(address irm);
error LltvNotEnabled(uint256 lltv);

// Events
event IrmEnabled(address irm);
event LltvEnabled(uint256 lltv);
event MarketCreated(bytes32 indexed marketId, address loanToken, address collateralToken);
event MarketSetupComplete(address loanToken, address collateralToken, bytes32 marketId);
event MarketSetupFailed(address loanToken, address collateralToken, string reason);
```

## Post-Market Creation Monitoring

After a market is created, it's essential to monitor its performance and health. MorphoBlueSnippets provides several utility functions for market analysis:

### Market APY and Utilization Tracking

```solidity
/// @notice Calculates the supply APY (Annual Percentage Yield) for a given market.
function supplyAPY(MarketParams memory marketParams, Market memory market) public view returns (uint256 supplyApy) {
    (uint256 totalSupplyAssets,, uint256 totalBorrowAssets,) = morpho.expectedMarketBalances(marketParams);

    // Get the borrow rate
    if (marketParams.irm != address(0)) {
        uint256 utilization = totalBorrowAssets == 0 ? 0 : totalBorrowAssets.wDivUp(totalSupplyAssets);
        supplyApy = borrowAPY(marketParams, market).wMulDown(1 ether - market.fee).wMulDown(utilization);
    }
}

/// @notice Calculates the borrow APY (Annual Percentage Yield) for a given market.
function borrowAPY(MarketParams memory marketParams, Market memory market) public view returns (uint256 borrowApy) {
    if (marketParams.irm != address(0)) {
        borrowApy = IIrm(marketParams.irm).borrowRateView(marketParams, market).wTaylorCompounded(365 days);
    }
}
```

These functions enable tracking of key performance metrics:
1. **Supply APY**: The annual yield suppliers can expect to earn
2. **Borrow APY**: The annual cost borrowers pay for loans
3. **Utilization Rate**: The ratio of borrowed assets to supplied assets, a key driver of interest rates

### Market Liquidity Analysis

```solidity
/// @notice Calculates the total supply of assets in a specific market.
function marketTotalSupply(MarketParams memory marketParams) public view returns (uint256 totalSupplyAssets) {
    totalSupplyAssets = morpho.expectedTotalSupplyAssets(marketParams);
}

/// @notice Calculates the total borrow of assets in a specific market.
function marketTotalBorrow(MarketParams memory marketParams) public view returns (uint256 totalBorrowAssets) {
    totalBorrowAssets = morpho.expectedTotalBorrowAssets(marketParams);
}
```

These functions help monitor the market's liquidity and growth:
1. Track total assets supplied to the market
2. Monitor overall borrow demand
3. Identify supply/demand imbalances that might require intervention

### Risk Assessment with Health Factor Calculation

```solidity
/// @notice Calculates the health factor of a user in a specific market.
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

The health factor calculation is essential for:
1. Monitoring the risk level of loans in the market
2. Identifying positions nearing liquidation thresholds
3. Evaluating the overall health of the market based on average health factors

### Market Monitoring Dashboard Example

Here's a recommended approach for a comprehensive market monitoring dashboard:

```solidity
function getMarketStats(MarketParams memory marketParams) external view returns (
    uint256 supplyRate,
    uint256 borrowRate,
    uint256 totalSupply,
    uint256 totalBorrow,
    uint256 utilization,
    uint256 avgHealthFactor
) {
    Id id = marketParams.id();
    Market memory market = morpho.market(id);
    
    // Calculate rates
    supplyRate = supplyAPY(marketParams, market);
    borrowRate = borrowAPY(marketParams, market);
    
    // Calculate supply/borrow
    totalSupply = marketTotalSupply(marketParams);
    totalBorrow = marketTotalBorrow(marketParams);
    
    // Calculate utilization
    utilization = totalBorrow == 0 ? 0 : totalBorrow.wDivDown(totalSupply);
    
    // Average health factor calculation would require off-chain aggregation
    // or an on-chain mapping of all positions
    
    return (supplyRate, borrowRate, totalSupply, totalBorrow, utilization, avgHealthFactor);
}
```

## Market Health Management Best Practices

For newly created markets, follow these best practices:

1. **Initial Seeding**: Consider seeding new markets with some base liquidity to establish stable initial share pricing.

2. **Utilization Rate Monitoring**: Monitor utilization rates closely, as extremely high rates can lead to liquidity crunches.

3. **Oracle Health**: Regularly check oracle price feed reliability, as oracle failures can put the market at risk.

4. **Parameter Adjustments**: Be prepared to adjust interest rate model parameters based on market performance.

5. **Event Monitoring**: Set up alerts for key events such as large withdrawals, borrows, or health factor decreases.

6. **Regular Health Checks**: Implement periodic health checks to ensure market parameters remain appropriate as market conditions evolve:

```solidity
function performMarketHealthCheck(MarketParams memory marketParams) external view returns (bool healthy, string memory recommendation) {
    Id id = marketParams.id();
    Market memory market = morpho.market(id);
    
    uint256 utilization = getUtilizationRate(marketParams);
    uint256 borrowRate = borrowAPY(marketParams, market);
    
    // Check for high utilization
    if (utilization > 0.95e18) {
        return (false, "Utilization too high; consider adjusting IRM parameters");
    }
    
    // Check for extremely low utilization
    if (utilization < 0.05e18 && marketTotalSupply(marketParams) > 1000e18) {
        return (false, "Utilization too low; consider adjusting IRM parameters");
    }
    
    // Check for extremely high borrow rates
    if (borrowRate > 50e16) { // 50%
        return (false, "Borrow rate too high; consider adjusting IRM parameters");
    }
    
    return (true, "Market parameters appear optimal");
}
``` 