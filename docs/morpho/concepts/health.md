# Position Health Management in Morpho

## Overview

Position health is a critical concept in the Morpho protocol that determines whether a borrower's position has sufficient collateral to back their borrowed assets. The health check system ensures that positions remain solvent and helps prevent liquidations while maintaining protocol security.

## Health Check Function

```solidity
/// @dev Returns whether the position of `borrower` in the given market is healthy.
function _isHealthy(MarketParams memory marketParams, Id id, address borrower) internal view returns (bool) {
    if (position[id][borrower].borrowShares == 0) return true;

    uint256 collateralPrice = IOracle(marketParams.oracle).price();

    return _isHealthy(marketParams, id, borrower, collateralPrice);
}

/// @dev Returns whether the position of `borrower` is healthy with the given collateral price.
function _isHealthy(MarketParams memory marketParams, Id id, address borrower, uint256 collateralPrice)
    internal
    view
    returns (bool)
{
    uint256 borrowed = uint256(position[id][borrower].borrowShares).toAssetsUp(
        market[id].totalBorrowAssets, market[id].totalBorrowShares
    );
    uint256 maxBorrow = uint256(position[id][borrower].collateral).mulDivDown(collateralPrice, ORACLE_PRICE_SCALE)
        .wMulDown(marketParams.lltv);

    return maxBorrow >= borrowed;
}
```

## Quantitative Health Factor Calculation

While the `_isHealthy` function returns a boolean indicating whether a position is healthy, it's often more useful to have a quantitative measure of position health. The `userHealthFactor` function provides this by calculating the ratio between maximum allowed borrowing and current borrowed amount:

```solidity
/// @notice Calculates the health factor of a user in a specific market
/// @param marketParams The parameters of the market
/// @param id The identifier of the market
/// @param user The address of the user whose health factor is being calculated
/// @return healthFactor The calculated health factor (scaled by WAD)
function userHealthFactor(MarketParams memory marketParams, Id id, address user)
    public
    view
    returns (uint256 healthFactor)
{
    uint256 collateralPrice = IOracle(marketParams.oracle).price();
    uint256 collateral = morpho.collateral(id, user);
    uint256 borrowed = morpho.expectedBorrowAssets(marketParams, user);

    uint256 maxBorrow = collateral.mulDivDown(collateralPrice, ORACLE_PRICE_SCALE).wMulDown(marketParams.lltv);

    if (borrowed == 0) return type(uint256).max; // No debt = maximum health
    healthFactor = maxBorrow.wDivDown(borrowed);
}
```

### Interpreting Health Factor Values

The health factor is expressed as a ratio with WAD precision (1e18):

- Health factor = 1e18 (1.0): Position is at the exact liquidation threshold
- Health factor > 1e18: Position is healthy (the higher, the safer)
- Health factor < 1e18: Position is eligible for liquidation

For example:
- Health factor of 2e18 (2.0): Position can withstand a 50% drop in collateral value
- Health factor of 1.5e18 (1.5): Position can withstand a 33% drop in collateral value
- Health factor of 0.8e18 (0.8): Position is underwater and can be liquidated

### Using Expected Values for Accurate Health Calculation

For the most accurate health assessment, always use the `expectedBorrowAssets` method instead of direct balance checks:

```solidity
// This includes accrued interest since the last update
uint256 borrowed = morpho.expectedBorrowAssets(marketParams, user);

// Instead of:
// uint256 borrowed = morpho.borrowBalance(id, user);
```

This ensures that even if interest hasn't been formally accrued in storage, the health calculation reflects the actual current state including all pending interest.

## Core Concepts

### Liquidation-to-Value (LLTV)

The Liquidation-to-Value (LLTV) is a key parameter that determines the maximum amount a user can borrow relative to the value of their collateral. It's expressed as a WAD value (1e18 based) between 0 and 1.

For example:
- LLTV of 0.8 (80%) means a user can borrow up to 80% of their collateral value
- The lower the LLTV, the more conservative the protocol is about lending
- Each market has its own LLTV parameter set at creation

```solidity
// Enable an LLTV parameter
function enableLltv(uint256 lltv) external onlyOwner {
    require(!isLltvEnabled[lltv], ErrorsLib.ALREADY_SET);
    require(lltv < WAD, ErrorsLib.MAX_LLTV_EXCEEDED);

    isLltvEnabled[lltv] = true;

    emit EventsLib.EnableLltv(lltv);
}
```

### Oracle Integration

Position health relies on accurate price data from trusted oracles:

```solidity
// Get current price from the oracle
uint256 collateralPrice = IOracle(marketParams.oracle).price();
```

The oracle returns prices in a standard scale defined by `ORACLE_PRICE_SCALE`, which is typically set to 1e18. This ensures consistent price interpretation across different assets.

## Health Evaluation Process

### 1. Calculating Borrowed Amount

```solidity
uint256 borrowed = uint256(position[id][borrower].borrowShares).toAssetsUp(
    market[id].totalBorrowAssets, market[id].totalBorrowShares
);
```

The system converts the borrower's shares into the actual borrowed asset amount using the current share price. The conversion rounds up to favor the protocol's security.

### 2. Calculating Maximum Borrow Capacity

```solidity
uint256 maxBorrow = uint256(position[id][borrower].collateral).mulDivDown(collateralPrice, ORACLE_PRICE_SCALE)
    .wMulDown(marketParams.lltv);
```

This calculation involves:
1. Converting collateral amount to value using the oracle price
2. Applying the LLTV to determine maximum borrow capacity
3. Rounding down for additional security

### 3. Health Status Determination

```solidity
return maxBorrow >= borrowed;
```

A position is considered healthy if the maximum borrow capacity is greater than or equal to the current borrowed amount.

## Health Check Implementation in Key Functions

### Borrowing

```solidity
function borrow(
    MarketParams memory marketParams,
    uint256 assets,
    uint256 shares,
    address onBehalf,
    address receiver
) external returns (uint256, uint256) {
    // ... other validations and logic ...

    position[id][onBehalf].borrowShares += shares.toUint128();
    market[id].totalBorrowShares += shares.toUint128();
    market[id].totalBorrowAssets += assets.toUint128();

    require(_isHealthy(marketParams, id, onBehalf), ErrorsLib.INSUFFICIENT_COLLATERAL);
    
    // ... additional logic ...
}
```

The health check ensures that any borrowing operation leaves the position in a healthy state.

### Withdrawing Collateral

```solidity
function withdrawCollateral(MarketParams memory marketParams, uint256 assets, address onBehalf, address receiver)
    external
{
    // ... other validations and logic ...

    _accrueInterest(marketParams, id);

    position[id][onBehalf].collateral -= assets.toUint128();

    require(_isHealthy(marketParams, id, onBehalf), ErrorsLib.INSUFFICIENT_COLLATERAL);
    
    // ... additional logic ...
}
```

Health checks prevent users from withdrawing collateral that would leave their position undercollateralized.

### Liquidation Eligibility

```solidity
function liquidate(
    MarketParams memory marketParams,
    address borrower,
    uint256 seizedAssets,
    uint256 repaidShares,
    bytes calldata data
) external returns (uint256, uint256) {
    // ... other validations and logic ...

    _accrueInterest(marketParams, id);

    {
        uint256 collateralPrice = IOracle(marketParams.oracle).price();

        require(!_isHealthy(marketParams, id, borrower, collateralPrice), ErrorsLib.HEALTHY_POSITION);
        
        // ... additional liquidation logic ...
    }
}
```

A position must be unhealthy (failing the health check) to be eligible for liquidation.

## External Health Check Functions

External interfaces can be added to allow users to check the health of their positions:

```solidity
// External view function to check position health
function isHealthy(MarketParams memory marketParams, address borrower) external view returns (bool) {
    Id id = marketParams.id();
    return _isHealthy(marketParams, id, borrower);
}

// External view function to get health factor as a percentage
function healthFactor(MarketParams memory marketParams, address borrower) external view returns (uint256) {
    Id id = marketParams.id();
    
    if (position[id][borrower].borrowShares == 0) return type(uint256).max; // Max health if no borrows
    
    uint256 collateralPrice = IOracle(marketParams.oracle).price();
    uint256 borrowed = uint256(position[id][borrower].borrowShares).toAssetsUp(
        market[id].totalBorrowAssets, market[id].totalBorrowShares
    );
    uint256 maxBorrow = uint256(position[id][borrower].collateral).mulDivDown(collateralPrice, ORACLE_PRICE_SCALE)
        .wMulDown(marketParams.lltv);
    
    // Return as percentage, 100% = healthy threshold, >100% is healthy, <100% is unhealthy
    return maxBorrow.mulDivDown(100e18, borrowed);
}
```

## Health Monitoring Tools

### Calculating Safe Collateral Withdrawal

```solidity
function maxWithdrawableCollateral(MarketParams memory marketParams, address borrower) public view returns (uint256) {
    Id id = marketParams.id();
    
    if (position[id][borrower].borrowShares == 0) return position[id][borrower].collateral;
    
    uint256 borrowed = uint256(position[id][borrower].borrowShares).toAssetsUp(
        market[id].totalBorrowAssets, market[id].totalBorrowShares
    );
    uint256 collateralPrice = IOracle(marketParams.oracle).price();
    
    // Calculate minimum collateral needed to maintain healthy position
    uint256 minCollateral = borrowed.mulDivUp(ORACLE_PRICE_SCALE, collateralPrice.wMulDown(marketParams.lltv));
    
    // Return withdrawable amount, possibly 0 if already at or below minimum
    if (position[id][borrower].collateral <= minCollateral) return 0;
    return position[id][borrower].collateral - minCollateral;
}
```

### Calculating Safe Borrow Amount

```solidity
function maxBorrowableAssets(MarketParams memory marketParams, address borrower) public view returns (uint256) {
    Id id = marketParams.id();
    
    uint256 collateralPrice = IOracle(marketParams.oracle).price();
    uint256 currentBorrowed = uint256(position[id][borrower].borrowShares).toAssetsUp(
        market[id].totalBorrowAssets, market[id].totalBorrowShares
    );
    uint256 maxBorrow = uint256(position[id][borrower].collateral).mulDivDown(collateralPrice, ORACLE_PRICE_SCALE)
        .wMulDown(marketParams.lltv);
    
    // Return additional borrowable amount, possibly 0 if already exceeded
    if (maxBorrow <= currentBorrowed) return 0;
    return maxBorrow - currentBorrowed;
}
```

## Hypothetical Health Factor Calculations

The VirtualHealthFactorSnippets contract provides essential functions for calculating how potential transactions would affect a position's health before actually executing them:

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
    return maxBorrow.wDivDown(borrowed);
}

/// @notice Calculates the health factor of a user after a virtual repayment.
/// @param marketParams The parameters of the market.
/// @param id The identifier of the market.
/// @param user The address of the user whose health factor is being calculated.
/// @param repaidAssets The amount of assets to be virtually repaid.
/// @return healthFactor The calculated health factor after the virtual repayment.
function userHypotheticalHealthFactor(
    MarketParams memory marketParams,
    Id id,
    address user,
    uint256 repaidAssets
) public view returns (uint256 healthFactor) {
    uint256 collateralPrice = IOracle(marketParams.oracle).price();
    uint256 collateral = morpho.collateral(id, user);
    uint256 borrowed = morpho.expectedBorrowAssets(marketParams, user);

    uint256 newBorrowed = borrowed > repaidAssets ? borrowed - repaidAssets : 0;
    
    uint256 maxBorrow = collateral.mulDivDown(collateralPrice, ORACLE_PRICE_SCALE).wMulDown(marketParams.lltv);

    return newBorrowed == 0 ? type(uint256).max : maxBorrow.wDivDown(newBorrowed);
}

/// @notice Calculates the health factor of a user after a virtual borrow.
/// @param marketParams The parameters of the market.
/// @param id The identifier of the market.
/// @param user The address of the user whose health factor is being calculated.
/// @param borrowAmount The amount of assets to be virtually borrowed.
/// @return healthFactor The calculated health factor after the virtual borrow.
function userHealthFactorAfterVirtualBorrow(
    MarketParams memory marketParams,
    Id id,
    address user,
    uint256 borrowAmount
) public view returns (uint256 healthFactor) {
    uint256 collateralPrice = IOracle(marketParams.oracle).price();
    uint256 collateral = morpho.collateral(id, user);
    uint256 borrowed = morpho.expectedBorrowAssets(marketParams, user);

    uint256 newBorrowed = borrowed + borrowAmount;

    uint256 maxBorrow = collateral.mulDivDown(collateralPrice, ORACLE_PRICE_SCALE).wMulDown(marketParams.lltv);

    return newBorrowed == 0 ? type(uint256).max : maxBorrow.wDivDown(newBorrowed);
}
```

### Virtual Health Factor with Collateral Changes

Here's an additional useful function for simulating the health factor after adding or removing collateral:

```solidity
/// @notice Calculates the health factor of a user after a virtual collateral change.
/// @param marketParams The parameters of the market.
/// @param id The identifier of the market.
/// @param user The address of the user whose health factor is being calculated.
/// @param collateralDelta The amount of collateral to be virtually added (positive) or removed (negative).
/// @return healthFactor The calculated health factor after the virtual collateral change.
function userHealthFactorAfterVirtualCollateralChange(
    MarketParams memory marketParams,
    Id id,
    address user,
    int256 collateralDelta
) public view returns (uint256 healthFactor) {
    uint256 collateralPrice = IOracle(marketParams.oracle).price();
    uint256 collateral = morpho.collateral(id, user);
    uint256 borrowed = morpho.expectedBorrowAssets(marketParams, user);
    
    // Calculate new collateral amount
    uint256 newCollateral;
    if (collateralDelta >= 0) {
        newCollateral = collateral + uint256(collateralDelta);
    } else {
        uint256 collateralToRemove = uint256(-collateralDelta);
        newCollateral = collateral > collateralToRemove ? collateral - collateralToRemove : 0;
    }
    
    uint256 maxBorrow = newCollateral.mulDivDown(collateralPrice, ORACLE_PRICE_SCALE).wMulDown(marketParams.lltv);
    
    if (borrowed == 0) return type(uint256).max;
    return maxBorrow.wDivDown(borrowed);
}
```

### Combined Position Simulation

This function simulates multiple operation types at once for more complex scenarios:

```solidity
/// @notice Simulates health factor after multiple operations.
/// @param marketParams The parameters of the market.
/// @param id The identifier of the market.
/// @param user The address of the user.
/// @param collateralDelta The change in collateral (positive for add, negative for remove).
/// @param borrowDelta The change in borrow (positive for borrow more, negative for repay).
/// @return healthFactor The calculated health factor after all operations.
function simulateHealthFactor(
    MarketParams memory marketParams,
    Id id,
    address user,
    int256 collateralDelta,
    int256 borrowDelta
) public view returns (uint256 healthFactor) {
    uint256 collateralPrice = IOracle(marketParams.oracle).price();
    uint256 collateral = morpho.collateral(id, user);
    uint256 borrowed = morpho.expectedBorrowAssets(marketParams, user);
    
    // Calculate new collateral amount
    uint256 newCollateral;
    if (collateralDelta >= 0) {
        newCollateral = collateral + uint256(collateralDelta);
    } else {
        uint256 collateralToRemove = uint256(-collateralDelta);
        newCollateral = collateral > collateralToRemove ? collateral - collateralToRemove : 0;
    }
    
    // Calculate new borrow amount
    uint256 newBorrowed;
    if (borrowDelta >= 0) {
        newBorrowed = borrowed + uint256(borrowDelta);
    } else {
        uint256 borrowToRepay = uint256(-borrowDelta);
        newBorrowed = borrowed > borrowToRepay ? borrowed - borrowToRepay : 0;
    }
    
    uint256 maxBorrow = newCollateral.mulDivDown(collateralPrice, ORACLE_PRICE_SCALE).wMulDown(marketParams.lltv);
    
    if (newBorrowed == 0) return type(uint256).max;
    return maxBorrow.wDivDown(newBorrowed);
}
```

### User Interface Applications

These hypothetical health factor calculations are particularly useful for:

1. **Pre-transaction estimation:** Show users how a transaction will affect their position health before they submit it
2. **Slider interfaces:** Allow users to visualize health impacts as they adjust transaction parameters
3. **Risk warnings:** Preemptively warn users if a planned action would bring them close to liquidation
4. **Optimal transaction sizing:** Help users calculate the maximum safe amount they can borrow or withdraw

### Implementation in dApp UI

Here's a pseudocode example for implementing this in a frontend:

```javascript
// Calculate and display health factor for a planned transaction
async function displayHealthImpact(user, market, action, amount) {
  // Get market parameters from contract
  const marketParams = await getMarketParams(market);
  const marketId = await getMarketId(marketParams);
  
  let hypotheticalHealth;
  
  // Determine which function to call based on action type
  switch(action) {
    case 'borrow':
      hypotheticalHealth = await virtualHealthFactorContract.userHealthFactorAfterVirtualBorrow(
        marketParams, marketId, user, amount
      );
      break;
    case 'repay':
      hypotheticalHealth = await virtualHealthFactorContract.userHypotheticalHealthFactor(
        marketParams, marketId, user, amount
      );
      break;
    case 'addCollateral':
      hypotheticalHealth = await virtualHealthFactorContract.userHealthFactorAfterVirtualCollateralChange(
        marketParams, marketId, user, amount
      );
      break;
    case 'removeCollateral':
      hypotheticalHealth = await virtualHealthFactorContract.userHealthFactorAfterVirtualCollateralChange(
        marketParams, marketId, user, -amount
      );
      break;
  }
  
  // Display in UI
  if (hypotheticalHealth < 1.2e18) {
    displayWarning("This transaction will put your position at risk of liquidation");
  }
  
  updateHealthDisplay(formatHealthFactor(hypotheticalHealth));
}
```

## Security Considerations

### Oracle Reliance

Health checks depend entirely on the accuracy and availability of price oracles:

```solidity
uint256 collateralPrice = IOracle(marketParams.oracle).price();
```

Considerations:
- Oracle manipulation attacks can bypass health checks
- Oracle failures can prevent healthy positions from borrowing
- Time-weighted average prices (TWAPs) can help mitigate flash loan attacks

### Price Volatility

Highly volatile collateral assets can quickly move positions from healthy to unhealthy:

```solidity
// Adding safety margins for volatile assets
function createMarketWithSafetyMargin(MarketParams memory marketParams, uint256 volatilityFactor) external {
    // Reduce effective LLTV based on asset volatility
    marketParams.lltv = marketParams.lltv.wMulDown(WAD - volatilityFactor);
    
    // Continue with regular market creation
    createMarket(marketParams);
}
```

### Rounding Direction

The health system uses specific rounding directions to ensure protocol safety:

```solidity
// Borrowing calculations round up (in favor of protocol)
uint256 borrowed = position[id][borrower].borrowShares.toAssetsUp(
    market[id].totalBorrowAssets, market[id].totalBorrowShares
);

// Collateral calculations round down (in favor of protocol)
uint256 maxBorrow = position[id][borrower].collateral.mulDivDown(collateralPrice, ORACLE_PRICE_SCALE)
    .wMulDown(marketParams.lltv);
```

### Interest Accrual

Health checks are performed after accruing interest to ensure up-to-date borrowed amounts:

```solidity
function withdrawCollateral(MarketParams memory marketParams, uint256 assets, address onBehalf, address receiver)
    external
{
    // ... other logic ...
    
    _accrueInterest(marketParams, id);
    
    position[id][onBehalf].collateral -= assets.toUint128();
    
    require(_isHealthy(marketParams, id, onBehalf), ErrorsLib.INSUFFICIENT_COLLATERAL);
    
    // ... additional logic ...
}
```

## Implementation Examples

### Health Monitoring Service

```solidity
// Health monitoring service example
contract MorphoHealthMonitor {
    IMorpho public immutable morpho;
    
    constructor(address _morpho) {
        morpho = IMorpho(_morpho);
    }
    
    // Check if position is near liquidation threshold
    function isNearLiquidation(MarketParams memory marketParams, address borrower, uint256 warningThreshold)
        external
        view
        returns (bool)
    {
        Id id = marketParams.id();
        
        if (morpho.position(id, borrower).borrowShares == 0) return false;
        
        uint256 collateralPrice = IOracle(marketParams.oracle).price();
        uint256 borrowed = morpho.borrowBalance(id, borrower);
        uint256 collateral = morpho.position(id, borrower).collateral;
        
        // Calculate current health percentage
        uint256 maxBorrow = collateral.mulDivDown(collateralPrice, ORACLE_PRICE_SCALE)
            .wMulDown(marketParams.lltv);
        uint256 healthPercentage = maxBorrow.mulDivDown(100e18, borrowed);
        
        // Return true if health percentage is below warning threshold
        return healthPercentage < warningThreshold;
    }
    
    // Estimate health after price movement
    function simulateHealthWithPriceChange(
        MarketParams memory marketParams,
        address borrower,
        int256 priceChangePercentage
    ) external view returns (bool) {
        Id id = marketParams.id();
        
        if (morpho.position(id, borrower).borrowShares == 0) return true;
        
        uint256 currentPrice = IOracle(marketParams.oracle).price();
        uint256 adjustedPrice;
        
        if (priceChangePercentage >= 0) {
            adjustedPrice = currentPrice.wMulUp(WAD + uint256(priceChangePercentage));
        } else {
            adjustedPrice = currentPrice.wMulDown(WAD - uint256(-priceChangePercentage));
        }
        
        return morpho.isHealthy(marketParams, borrower, adjustedPrice);
    }
}
```

### User-Friendly Health Status

```solidity
// Categorizing health status for better user experience
function healthStatus(MarketParams memory marketParams, address borrower)
    external
    view
    returns (string memory status, uint256 healthPercentage)
{
    Id id = marketParams.id();
    
    if (morpho.position(id, borrower).borrowShares == 0) {
        return ("EXCELLENT", type(uint256).max);
    }
    
    uint256 borrowed = morpho.borrowBalance(id, borrower);
    uint256 collateralValue = morpho.position(id, borrower).collateral
        .mulDivDown(IOracle(marketParams.oracle).price(), ORACLE_PRICE_SCALE);
    uint256 maxBorrow = collateralValue.wMulDown(marketParams.lltv);
    
    healthPercentage = maxBorrow.mulDivDown(100e18, borrowed);
    
    if (healthPercentage < 100e18) return ("LIQUIDATABLE", healthPercentage);
    else if (healthPercentage < 110e18) return ("CRITICAL", healthPercentage);
    else if (healthPercentage < 125e18) return ("WARNING", healthPercentage);
    else if (healthPercentage < 150e18) return ("MODERATE", healthPercentage);
    else if (healthPercentage < 200e18) return ("GOOD", healthPercentage);
    else return ("EXCELLENT", healthPercentage);
}
```

## Error Handling

```solidity
// Common errors related to position health
error INSUFFICIENT_COLLATERAL();    // Position would be unhealthy after operation
error HEALTHY_POSITION();           // Cannot liquidate a healthy position
error ZERO_ASSETS();                // Cannot process zero assets
error MARKET_NOT_CREATED();         // Market does not exist
``` 