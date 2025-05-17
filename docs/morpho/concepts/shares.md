# Share Accounting System in Morpho

## Overview

Morpho's share-based accounting system is fundamental to its operation, enabling accurate tracking of user positions and interest accrual. The protocol uses shares to represent proportional ownership in the supply and borrow side of markets, automatically handling interest distribution without requiring explicit interest payments.

## Core Concepts

### Shares vs Assets

- **Assets**: The actual token amounts (e.g., 100 USDC)
- **Shares**: Tokenized representation of proportional ownership in a pool of assets
- **Exchange Rate**: The ratio between total assets and total shares, which changes as interest accrues

### Types of Shares

```solidity
// Main share types in Morpho
struct MarketShares {
    uint128 totalSupplyShares;    // Total shares representing supplied assets
    uint128 totalBorrowShares;    // Total shares representing borrowed assets
}

// User position shares
struct Position {
    uint256 supplyShares;         // User's shares of the supply side
    uint256 borrowShares;         // User's shares of the borrow side
    uint256 collateral;           // User's collateral (tracked in assets, not shares)
}
```

## Share-to-Asset Conversions

```solidity
// Convert shares to assets (rounding up - used for borrows)
function toAssetsUp(
    uint256 shares,
    uint256 totalAssets,
    uint256 totalShares
) internal pure returns (uint256) {
    return shares.mulDivUp(totalAssets, totalShares);
}

// Convert shares to assets (rounding down - used for supplies)
function toAssetsDown(
    uint256 shares,
    uint256 totalAssets,
    uint256 totalShares
) internal pure returns (uint256) {
    return shares.mulDivDown(totalAssets, totalShares);
}

// Convert assets to shares (rounding up - used for supplies)
function toSharesUp(
    uint256 assets,
    uint256 totalAssets,
    uint256 totalShares
) internal pure returns (uint256) {
    return assets.mulDivUp(totalShares, totalAssets);
}

// Convert assets to shares (rounding down - used for borrows)
function toSharesDown(
    uint256 assets,
    uint256 totalAssets,
    uint256 totalShares
) internal pure returns (uint256) {
    return assets.mulDivDown(totalShares, totalAssets);
}
```

## Market Initialization and Share Pricing

When a market is first created, the share-to-asset exchange rate is initialized at 1:1. As interest accrues, the ratio changes:

```solidity
// Initializing a new market
function createMarket(MarketParams memory marketParams) external returns (bytes32 marketId) {
    // ... other initialization ...
    
    // Initialize the market with a 1:1 share-to-asset ratio
    market[marketId].lastUpdate = uint128(block.timestamp);
    market[marketId].fee = marketParams.fee;
    
    // If there are already assets in the market (from seeding)
    if (initialAssets > 0) {
        market[marketId].totalSupplyAssets = uint128(initialAssets);
        market[marketId].totalSupplyShares = uint128(initialAssets); // 1:1 ratio at start
    }
}
```

## Share-Based Position Management

### Supplying Assets

When a user supplies assets to Morpho, they receive shares proportional to the current exchange rate:

```solidity
function supply(
    MarketParams memory marketParams,
    uint256 assets,
    uint256 minShares,
    address onBehalf
) external returns (uint256 sharesReceived) {
    // ... input validation ...
    
    // Calculate shares based on current exchange rate
    // Rounds up in favor of the protocol
    sharesReceived = assetsToSharesUp(assets, totalSupplyAssets, totalSupplyShares);
    
    // Ensure minimum shares received
    if (sharesReceived < minShares) {
        revert InsufficientShares(sharesReceived, minShares);
    }
    
    // Update user position
    position[marketId][onBehalf].supplyShares += sharesReceived;
    
    // Update market totals
    market[marketId].totalSupplyAssets += uint128(assets);
    market[marketId].totalSupplyShares += uint128(sharesReceived);
    
    // ... additional logic ...
}
```

### Borrowing Assets

When borrowing, shares are used to track the debt including accrued interest:

```solidity
function borrow(
    MarketParams memory marketParams,
    uint256 assets,
    uint256 maxShares,
    address onBehalf,
    address receiver
) external returns (uint256 sharesOwed) {
    // ... input validation ...
    
    // Calculate borrow shares based on current exchange rate
    // Rounds down in favor of the protocol
    sharesOwed = assetsToSharesDown(assets, totalBorrowAssets, totalBorrowShares);
    
    // Ensure maximum shares not exceeded
    if (sharesOwed > maxShares) {
        revert ExcessiveShares(sharesOwed, maxShares);
    }
    
    // Update user position
    position[marketId][onBehalf].borrowShares += sharesOwed;
    
    // Update market totals
    market[marketId].totalBorrowAssets += uint128(assets);
    market[marketId].totalBorrowShares += uint128(sharesOwed);
    
    // ... additional logic ...
}
```

## Interest Accrual through Share Price

The key advantage of share-based accounting is automatic interest distribution:

```solidity
function accrueInterest(bytes32 marketId) internal returns (uint256 interestEarned) {
    uint256 timeDelta = block.timestamp - market[marketId].lastUpdate;
    if (timeDelta == 0) return 0;
    
    uint256 borrowRate = calculateBorrowRate(marketId);
    
    // Calculate interest accrued
    interestEarned = market[marketId].totalBorrowAssets.mulWadDown(
        borrowRate.mulDivDown(timeDelta, SECONDS_PER_YEAR)
    );
    
    // Update the total borrow and supply assets with earned interest
    market[marketId].totalBorrowAssets += uint128(interestEarned);
    market[marketId].totalSupplyAssets += uint128(interestEarned);
    
    // Note: totalBorrowShares and totalSupplyShares remain unchanged
    // This effectively increases the value of each share
    
    market[marketId].lastUpdate = uint128(block.timestamp);
    
    return interestEarned;
}
```

As interest accrues:
1. `totalBorrowAssets` and `totalSupplyAssets` increase
2. `totalBorrowShares` and `totalSupplyShares` remain constant
3. This causes the share-to-asset exchange rate to increase over time
4. Users automatically earn interest proportional to their share of the pool

## Share Prices and Bad Debt

When bad debt occurs, the share pricing mechanism helps distribute losses fairly:

```solidity
// During liquidation with bad debt
if (position[id][borrower].collateral == 0 && position[id][borrower].borrowShares > 0) {
    badDebtShares = position[id][borrower].borrowShares;
    badDebtAssets = badDebtShares.toAssetsUp(market[id].totalBorrowAssets, market[id].totalBorrowShares);
    
    // Reduce both total borrow and supply assets
    market[id].totalBorrowAssets -= badDebtAssets.toUint128();
    market[id].totalSupplyAssets -= badDebtAssets.toUint128();
    market[id].totalBorrowShares -= badDebtShares.toUint128();
    
    // Clear borrower's debt
    position[id][borrower].borrowShares = 0;
}
```

This reduces the share price for suppliers, effectively socializing the loss across all suppliers proportionally to their share of the pool.

## Calculating User Balances

To determine a user's current asset balance, convert their shares using the current exchange rate:

```solidity
function supplyBalance(bytes32 marketId, address user) public view returns (uint256) {
    uint256 userShares = position[marketId][user].supplyShares;
    return userShares.toAssetsDown(
        market[marketId].totalSupplyAssets,
        market[marketId].totalSupplyShares
    );
}

function borrowBalance(bytes32 marketId, address user) public view returns (uint256) {
    uint256 userShares = position[marketId][user].borrowShares;
    return userShares.toAssetsUp(
        market[marketId].totalBorrowAssets,
        market[marketId].totalBorrowShares
    );
}
```

## Advanced Share Price Scenarios

### Market Supply and Demand Dynamics

As market conditions change, share prices adjust automatically:

1. **High Borrow Demand**: Interest rates increase, causing faster growth in supply share prices
2. **Low Utilization**: Interest rates decrease, slowing growth of share prices
3. **Liquidations**: Can affect share prices if bad debt is realized

### Fee Extraction

Protocol fees can be extracted without disturbing share accounting:

```solidity
function extractFees(bytes32 marketId) external onlyOwner returns (uint256 feeAmount) {
    // Accrue interest first
    accrueInterest(marketId);
    
    // Calculate accumulated fees
    feeAmount = accumulatedFees[marketId];
    
    // Reduce total supply assets (but not shares)
    // This effectively reduces share price slightly
    market[marketId].totalSupplyAssets -= uint128(feeAmount);
    
    // Reset accumulated fees
    accumulatedFees[marketId] = 0;
    
    // Transfer fees to treasury
    IERC20(market[marketId].asset).safeTransfer(treasury, feeAmount);
    
    return feeAmount;
}
```

## Implementation Examples

### Calculating Current Share Price

```solidity
function currentSharePrice(bytes32 marketId, bool isBorrow) public view returns (uint256) {
    if (isBorrow) {
        return market[marketId].totalBorrowAssets.wDivDown(market[marketId].totalBorrowShares);
    } else {
        return market[marketId].totalSupplyAssets.wDivDown(market[marketId].totalSupplyShares);
    }
}
```

### Monitoring Share Price Growth

```solidity
function getShareValueGrowth(
    bytes32 marketId,
    uint256 startTime,
    uint256 endTime
) external view returns (uint256 growthRate) {
    // Get share prices at start and end time
    uint256 startPrice = getHistoricalSharePrice(marketId, startTime);
    uint256 endPrice = getHistoricalSharePrice(marketId, endTime);
    
    // Calculate annualized growth rate
    uint256 timeDelta = endTime - startTime;
    growthRate = (endPrice - startPrice).mulDivDown(SECONDS_PER_YEAR, timeDelta.mulWadDown(startPrice));
    
    return growthRate;
}
```

## Security Considerations

1. **Rounding Direction**
   - Always round in favor of the protocol (up when converting to shares for suppliers, down when converting to shares for borrowers)
   - This prevents economic attacks exploiting rounding errors

2. **First Depositor Attack**
   - Implement minimum deposit thresholds
   - Consider market seeding to establish reasonable initial share prices

3. **Share Value Manipulation**
   - Implement rate limits on extremely large deposits/withdrawals
   - Monitor for unusual share price fluctuations

4. **Mathematical Precision**
   - Use safe math libraries to prevent overflow/underflow
   - Be aware of precision loss in calculations with very small numbers

5. **Share Price Oracle**
   - Systems using share prices as oracle inputs should implement safeguards against flash loan attacks
   - Consider time-weighted average share prices for external integrations

## Integration Guidelines

When integrating with Morpho's share system:

1. Always calculate expected share amounts before transactions
2. Include slippage protection parameters (minShares, maxShares)
3. Use view functions to estimate current share prices
4. Be aware that share prices will change between blocks due to interest accrual
5. For UI display, always convert shares to assets for user-facing information

## Common Errors and Troubleshooting

- **InsufficientShares**: Received shares are below specified minimum
- **ExcessiveShares**: Required shares exceed specified maximum
- **ZeroShares**: Attempted operation with zero shares
- **ZeroTotalShares**: Market has no shares yet (division by zero)
- **SharesOverflow**: Share calculation exceeds uint128 limits 