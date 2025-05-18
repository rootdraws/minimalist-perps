# Interest Accrual Management

## State Variables

```solidity
// Market identifier and parameters
struct MarketParams {
    address loanToken;
    address collateralToken;
    address irm;
    address oracle;
    uint256 lltv;
}

// Mappings for efficient market access
mapping(address => MarketParams) public marketParamsForToken;
mapping(address => Id) public marketIdForToken;
mapping(Id => uint256) public lastInterestAccrualTimestamp;

// Constants
uint256 public constant SECONDS_PER_YEAR = 365 days;
uint256 public constant PRECISION = 1e18;
```

## APY Calculation

Morpho calculates Annual Percentage Yield (APY) for both suppliers and borrowers using sophisticated mathematical models that account for market utilization and fee structures.

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
```

### Supply and Borrow APY Relationship

The supply APY is derived from the borrow APY using the following formula:

```
Supply APY = Borrow APY × (1 - Fee) × Utilization Rate
```

Where:
- **Borrow APY**: The interest rate paid by borrowers
- **Fee**: The protocol fee taken from interest (e.g., 0.1e18 represents a 10% fee)
- **Utilization Rate**: The ratio of borrowed assets to supplied assets (totalBorrowAssets / totalSupplyAssets)

This relationship ensures that higher market utilization leads to higher yields for suppliers, while the protocol can capture a portion of the interest through fees.

### Taylor Series Compounding

Morpho uses a Taylor series approximation to calculate the compounded APY from a given per-second interest rate:

```solidity
// Example of Taylor series compounding
borrowApy = IIrm(marketParams.irm).borrowRateView(marketParams, market).wTaylorCompounded(365 days);
```

The `wTaylorCompounded` function uses a mathematical approximation to convert a linear interest rate to a compounded one using the formula:

```
APY = (1 + r)^t - 1
```

Where `r` is the per-second rate and `t` is the number of seconds in a year (365 days).

### Accruing Interest Before Important Operations

For operations that depend on accurate debt balances, it's critical to accrue interest first:

```solidity
// Example from withdrawal function
morpho.accrueInterest(marketParams);
uint256 totalSupplyAssets = morpho.totalSupplyAssets(id);
uint256 totalSupplyShares = morpho.totalSupplyShares(id);
```

This ensures all interest calculations are based on up-to-date balances.

## Interest Accrual Functions

```solidity
// Ensure interest is accrued before any position operations
function _accrueMarketInterest(address token) internal {
    if (!supportedMarkets[token]) revert UnsupportedMarket(token);
    
    MarketParams memory params = marketParamsForToken[token];
    Id marketId = morpho.marketParamsToId(params);
    
    try morpho.accrueInterest(params) {
        lastInterestAccrualTimestamp[marketId] = block.timestamp;
    } catch (bytes memory reason) {
        emit InterestAccrualFailed(token, reason);
        // Continue execution - we'll use the latest values even if accrual fails
    }
}

// Get position's current debt with accrued interest
function getPositionDebt(uint256 positionId) public returns (uint256 currentDebt) {
    if (!_exists(positionId)) revert InvalidPositionId(positionId);
    
    Position storage position = positions[positionId];
    address debtToken = position.debtToken;
    
    // Ensure interest is accrued for accurate debt calculation
    _accrueMarketInterest(debtToken);
    
    // Get latest debt including accrued interest
    return morpho.borrowBalance(
        marketIdForToken[debtToken],
        address(this)
    );
}

// Calculate interest accrued over a time period
function calculateAccruedInterest(
    address token, 
    uint256 principal, 
    uint256 duration
) public view returns (uint256) {
    if (!supportedMarkets[token]) revert UnsupportedMarket(token);
    
    // Get current borrow rate from Morpho
    uint256 borrowRate = morpho.borrowAPY(marketParamsForToken[token]);
    
    // Calculate interest: principal * rate * time / SECONDS_PER_YEAR
    return (principal * borrowRate * duration) / (SECONDS_PER_YEAR * PRECISION);
}
```

## Position Health Management

```solidity
// Get health factor with latest interest-adjusted debt
function getHealthFactor(uint256 positionId) public returns (uint256) {
    if (!_exists(positionId)) revert InvalidPositionId(positionId);
    
    Position storage position = positions[positionId];
    
    // Get current debt with accrued interest
    uint256 currentDebt = getPositionDebt(positionId);
    if (currentDebt == 0) return type(uint256).max; // No debt = maximum health
    
    // Get collateral value from oracle
    uint256 collateralValue = getCollateralValue(
        position.collateralToken, 
        position.collateralAmount
    );
    
    // Calculate and return health factor
    return (collateralValue * PRECISION) / getDebtValue(position.debtToken, currentDebt);
}

// Check if position needs liquidation after interest accrual
function isLiquidatable(uint256 positionId) public returns (bool) {
    uint256 healthFactor = getHealthFactor(positionId);
    return healthFactor < LIQUIDATION_THRESHOLD;
}
```

## Integration with Position Operations

```solidity
// Create position with interest accrual
function openPosition(
    address collateralToken,
    address debtToken,
    uint256 collateralAmount,
    uint256 leverage,
    bool isLong
) external nonReentrant returns (uint256 positionId) {
    if (!supportedMarkets[collateralToken]) revert UnsupportedMarket(collateralToken);
    if (!supportedMarkets[debtToken]) revert UnsupportedMarket(debtToken);
    
    // Accrue interest before any position changes
    _accrueMarketInterest(collateralToken);
    _accrueMarketInterest(debtToken);
    
    // Calculate debt based on leverage
    uint256 debtAmount = calculateLeveragedDebt(collateralAmount, leverage);
    
    // Additional position opening logic...
    
    // Return the new position ID
    return nextPositionId++;
}

// Close position with interest accrual
function closePosition(uint256 positionId) external nonReentrant {
    if (!_exists(positionId)) revert InvalidPositionId(positionId);
    if (_ownerOf(positionId) != msg.sender) revert NotPositionOwner(positionId);
    
    Position storage position = positions[positionId];
    
    // Accrue interest before position changes
    _accrueMarketInterest(position.collateralToken);
    _accrueMarketInterest(position.debtToken);
    
    // Get current debt with accrued interest
    uint256 currentDebt = getPositionDebt(positionId);
    
    // Additional position closing logic...
}
```

## Interest Fee Handling

```solidity
// Calculate funding fee based on accrued interest
function calculateFundingFee(uint256 positionId) public returns (uint256 fee) {
    Position storage position = positions[positionId];
    
    // Get time elapsed since last fee payment
    uint256 lastFeeTimestamp = position.lastFeeTimestamp;
    uint256 timeElapsed = block.timestamp - lastFeeTimestamp;
    if (timeElapsed == 0) return 0;
    
    // Update last fee timestamp
    position.lastFeeTimestamp = block.timestamp;
    
    // Calculate interest accrued over the period
    uint256 currentDebt = getPositionDebt(positionId);
    fee = calculateAccruedInterest(position.debtToken, currentDebt, timeElapsed);
    
    // Apply protocol fee spread
    fee = fee + (fee * feePremium / MAX_BPS);
    
    emit FundingFeeCharged(positionId, fee, block.timestamp);
    return fee;
}

// Distribute protocol portion of interest fees
function distributeProtocolFees() external onlyRole(TREASURY_ROLE) {
    if (totalProtocolFees == 0) revert NoFeesToCollect();
    
    uint256 amount = totalProtocolFees;
    totalProtocolFees = 0;
    
    // Transfer collected fees to treasury
    IERC20(feeToken).transfer(treasury, amount);
    
    emit ProtocolFeesDistributed(amount);
}
```

## Error Handling

```solidity
// Custom errors
error UnsupportedMarket(address token);
error InvalidPositionId(uint256 positionId);
error NotPositionOwner(uint256 positionId);
error NoFeesToCollect();
error InterestAccrualError(bytes reason);

// Events
event InterestAccrualFailed(address token, bytes reason);
event FundingFeeCharged(uint256 positionId, uint256 amount, uint256 timestamp);
event ProtocolFeesDistributed(uint256 amount);
```

## Practical Interest Accrual Implementations

The MorphoBlueSnippets contract demonstrates best practices for interest accrual in real-world operations. Here are key implementation patterns:

### Interest Accrual Before Asset-Share Conversions

When performing operations that require accurate asset-to-share or share-to-asset conversions, always accrue interest first to ensure up-to-date exchange rates:

```solidity
// From withdrawAmountOrAll - ensuring accurate asset-share conversion
function withdrawAmountOrAll(MarketParams memory marketParams, uint256 amount) external returns (uint256, uint256) {
    Id id = marketParams.id();
    // --------- CRITICAL STEP ----------
    morpho.accrueInterest(marketParams);
    // ---------------------------------
    
    // Now retrieve accurate post-interest values
    uint256 totalSupplyAssets = morpho.totalSupplyAssets(id);
    uint256 totalSupplyShares = morpho.totalSupplyShares(id);
    uint256 shares = morpho.supplyShares(id, msg.sender);

    // Calculate max assets based on fresh exchange rate
    uint256 assetsMax = shares.toAssetsDown(totalSupplyAssets, totalSupplyShares);
    
    // Rest of function logic...
}
```

### Interest Accrual Before Repayments

Interest accrual is critical before repayments to ensure the correct amount is repaid:

```solidity
// From repayAmountOrAll - ensuring accurate debt calculation
function repayAmountOrAll(MarketParams memory marketParams, uint256 amount) external returns (uint256, uint256) {
    Id id = marketParams.id();
    
    // --------- CRITICAL STEP ----------
    morpho.accrueInterest(marketParams);
    // ---------------------------------
    
    // Get accurate debt information after interest accrual
    uint256 totalBorrowAssets = morpho.totalBorrowAssets(id);
    uint256 totalBorrowShares = morpho.totalBorrowShares(id);
    uint256 shares = morpho.borrowShares(id, msg.sender);
    
    // Calculate maximum debt with accrued interest
    uint256 assetsMax = shares.toAssetsUp(totalBorrowAssets, totalBorrowShares);
    
    // Handle repayment based on up-to-date debt
    if (amount >= assetsMax) {
        // Repay exact full debt amount with accrued interest
        ERC20(marketParams.loanToken).safeTransferFrom(msg.sender, address(this), assetsMax);
        return morpho.repay(marketParams, 0, shares, onBehalf, hex"");
    } else {
        // Repay partial amount
        ERC20(marketParams.loanToken).safeTransferFrom(msg.sender, address(this), amount);
        return morpho.repay(marketParams, amount, 0, onBehalf, hex"");
    }
}
```

### Efficient Utilization Calculation

When calculating interest rates and utilization ratios, it's important to use the expected market balances to include pending interest:

```solidity
function getUtilizationRate(MarketParams memory marketParams) public view returns (uint256 utilization) {
    (uint256 totalSupplyAssets,, uint256 totalBorrowAssets,) = morpho.expectedMarketBalances(marketParams);
    
    // Avoid division by zero
    if (totalSupplyAssets == 0) return 0;
    
    // Calculate utilization with precise rounding
    return totalBorrowAssets.wDivUp(totalSupplyAssets);
}
```

### Share-Asset Conversion with Interest Consideration

Interest accrual affects the share-to-asset exchange rate. Proper implementation must handle this:

```solidity
// From repay50Percent function - calculating assets based on shares with interest
function repay50Percent(MarketParams memory marketParams) external returns (uint256, uint256) {
    Id marketId = marketParams.id();

    // Get market balances that include accrued but unaccounted interest
    (,, uint256 totalBorrowAssets, uint256 totalBorrowShares) = morpho.expectedMarketBalances(marketParams);
    uint256 borrowShares = morpho.position(marketId, msg.sender).borrowShares;

    // Calculate exact repayment amount needed for half of shares
    uint256 repaidAmount = (borrowShares / 2).toAssetsUp(totalBorrowAssets, totalBorrowShares);
    
    // Transfer the precise amount needed
    ERC20(marketParams.loanToken).safeTransferFrom(msg.sender, address(this), repaidAmount);

    // Execute repayment with shares
    return morpho.repay(marketParams, 0, borrowShares / 2, onBehalf, hex"");
}
```

## Implementation Recommendations

Based on MorphoBlueSnippets implementations, here are best practices for interest handling:

### 1. Explicit Interest Accrual

Always explicitly call `accrueInterest()` before operations that:
- Convert between shares and assets
- Read current borrower debt
- Perform repayments
- Calculate health factors

```solidity
// Always start with interest accrual for critical operations
morpho.accrueInterest(marketParams);
```

### 2. Accurate Market Balance Queries

Use the appropriate balance query functions based on needs:

- **Current on-chain balances (no interest accrual):**
  ```solidity
  uint256 totalSupplyAssets = morpho.totalSupplyAssets(id);
  uint256 totalSupplyShares = morpho.totalSupplyShares(id);
  ```

- **Expected balances with pending interest (more accurate):**
  ```solidity
  (uint256 totalSupplyAssets,, uint256 totalBorrowAssets,) = morpho.expectedMarketBalances(marketParams);
  ```

### 3. Error Handling for Interest Accrual

Implement robust error handling for interest accrual operations:

```solidity
// Example error handling pattern
try morpho.accrueInterest(marketParams) {
    // Operation succeeded, continue
} catch Error(string memory reason) {
    // Known error occurred
    emit InterestAccrualFailed(address(marketParams.loanToken), bytes(reason));
    // Decide whether to continue or revert
} catch (bytes memory reason) {
    // Unknown error occurred
    emit InterestAccrualFailed(address(marketParams.loanToken), reason);
    // Decide whether to continue or revert
}
```

### 4. Interest-Aware UI Calculations

When building user interfaces, always reflect expected interest-adjusted balances:

```solidity
// Calculate actual borrow balance with interest for UI display
function getCurrentBorrowBalance(MarketParams memory marketParams, address user) 
    external view returns (uint256 borrowBalance) 
{
    // Use expectedBorrowAssets to include pending interest
    return morpho.expectedBorrowAssets(marketParams, user);
}
```

These implementation patterns ensure accurate interest calculation and accrual in all operations, maintaining system integrity and user transparency.

