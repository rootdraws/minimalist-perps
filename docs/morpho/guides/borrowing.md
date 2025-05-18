# Borrowing Mechanics in Morpho

## Core Borrowing Functions

```solidity
// Main borrowing function in Morpho
function borrow(
    MarketParams memory marketParams,
    uint256 assets,        // Amount of assets to borrow (use 0 if borrowing shares)
    uint256 shares,        // Amount of shares to borrow (use 0 if borrowing assets)
    address onBehalf,      // Who will own the debt
    address receiver       // Who receives the borrowed assets
) external returns (uint256 assetsOut, uint256 sharesOut);
```

## Implementation Requirements

```solidity
// Before borrowing, verify market parameters and collateral
function _verifyBorrowRequirements(
    address token,
    uint256 amount,
    address onBehalf
) internal view {
    // 1. Market must exist
    if (!supportedMarkets[token]) revert UnsupportedMarket(token);
    
    // 2. Amount must be greater than zero
    if (amount == 0) revert ZeroAmount();
    
    // 3. Cannot borrow to zero address
    if (msg.sender == address(0) || onBehalf == address(0)) revert ZeroAddress();
    
    // 4. Caller must be authorized if borrowing on behalf
    if (msg.sender != onBehalf && !morpho.isAuthorized(onBehalf, msg.sender)) {
        revert Unauthorized(msg.sender, onBehalf);
    }
    
    // 5. Borrower must have sufficient collateral
    if (!_hasEnoughCollateral(onBehalf, amount)) {
        revert InsufficientCollateral(onBehalf, amount);
    }
    
    // 6. Market must have sufficient liquidity
    if (!_hasEnoughLiquidity(token, amount)) {
        revert InsufficientLiquidity(token, amount);
    }
}
```

## Asset vs. Share Borrowing

```solidity
// Borrowing with exact assets (for predictable leverage)
function borrowWithExactAssets(
    address token,
    uint256 assetAmount,
    address onBehalf,
    address receiver
) internal returns (uint256 borrowedAssets, uint256 borrowShares) {
    MarketParams memory params = marketParamsForToken[token];
    
    // Always use 0 for shares when borrowing exact assets
    return morpho.borrow(params, assetAmount, 0, onBehalf, receiver);
}

// Borrowing with exact shares (advanced use cases)
function borrowWithExactShares(
    address token,
    uint256 shareAmount,
    address onBehalf,
    address receiver
) internal returns (uint256 borrowedAssets, uint256 borrowShares) {
    MarketParams memory params = marketParamsForToken[token];
    
    // Always use 0 for assets when borrowing exact shares
    return morpho.borrow(params, 0, shareAmount, onBehalf, receiver);
}

// Never provide both assets and shares - will revert with INCONSISTENT_INPUT
```

## Position Health Management

```solidity
// Check if a position has sufficient collateral for borrowing
function _hasEnoughCollateral(
    address account,
    uint256 additionalBorrowAmount
) internal view returns (bool) {
    // Get existing collateral value
    uint256 collateralValue = getAccountCollateralValue(account);
    
    // Get existing + new borrow value
    uint256 currentBorrowValue = getAccountBorrowValue(account);
    uint256 newTotalBorrowValue = currentBorrowValue + additionalBorrowAmount;
    
    // Calculate max borrow value based on collateral and LLTV
    uint256 maxBorrowValue = collateralValue * marketParams.lltv / PRECISION;
    
    return newTotalBorrowValue <= maxBorrowValue;
}

// Calculate how much can be borrowed based on collateral
function getMaxBorrowAmount(address account, address token) public view returns (uint256) {
    uint256 collateralValue = getAccountCollateralValue(account);
    uint256 currentBorrowValue = getAccountBorrowValue(account);
    
    uint256 maxBorrowValue = collateralValue * marketParams.lltv / PRECISION;
    
    if (currentBorrowValue >= maxBorrowValue) return 0;
    
    uint256 remainingBorrowValue = maxBorrowValue - currentBorrowValue;
    
    // Convert borrow value to token amount using price
    uint256 tokenPrice = getOraclePrice(token);
    return remainingBorrowValue * PRECISION / tokenPrice;
}
```

## Leverage Implementation

```solidity
// Create a leveraged position
function createLeveragedPosition(
    address collateralToken,
    address borrowToken,
    uint256 collateralAmount,
    uint256 leverage
) external nonReentrant returns (uint256 positionId) {
    // 1. Supply user's collateral
    _supplyCollateral(collateralToken, collateralAmount);
    
    // 2. Calculate borrow amount based on leverage
    uint256 borrowAmount = calculateLeveragedBorrowAmount(
        collateralToken,
        borrowToken,
        collateralAmount,
        leverage
    );
    
    // 3. Borrow assets
    (uint256 borrowedAssets, ) = borrowWithExactAssets(
        borrowToken,
        borrowAmount,
        address(this),  // Contract holds the debt
        address(this)   // Contract receives the tokens for position management
    );
    
    // 4. Create and store position data
    positionId = _createPosition(
        collateralToken,
        borrowToken,
        collateralAmount,
        borrowedAssets,
        leverage
    );
    
    // 5. Emit event and return position ID
    emit PositionCreated(positionId, msg.sender, collateralToken, borrowToken, leverage);
    return positionId;
}

// Calculate borrow amount for desired leverage
function calculateLeveragedBorrowAmount(
    address collateralToken,
    address borrowToken,
    uint256 collateralAmount,
    uint256 leverage
) public view returns (uint256) {
    // Get token prices
    uint256 collateralPrice = getOraclePrice(collateralToken);
    uint256 borrowPrice = getOraclePrice(borrowToken);
    
    // Calculate collateral value
    uint256 collateralValue = collateralAmount * collateralPrice / PRECISION;
    
    // Calculate target position value based on leverage
    // Leverage of 2x means borrowing collateral value * 1
    uint256 targetPositionValue = collateralValue * leverage / PRECISION;
    uint256 borrowValue = targetPositionValue - collateralValue;
    
    // Convert borrow value to borrow token amount
    return borrowValue * PRECISION / borrowPrice;
}
```

## Error Handling

```solidity
// Custom errors for borrow operations
error UnsupportedMarket(address token);
error ZeroAmount();
error ZeroAddress();
error Unauthorized(address caller, address account);
error InsufficientCollateral(address account, uint256 amount);
error InsufficientLiquidity(address token, uint256 amount);
error InconsistentInput();
error ExcessiveLeverage(uint256 requested, uint256 maximum);

// Events
event PositionCreated(
    uint256 indexed positionId,
    address indexed owner,
    address collateralToken,
    address borrowToken,
    uint256 leverage
);
```

## Security Considerations

1. **Health Factor Protection**
   - Always check position health before borrowing
   - Check minimum health factor after creating positions
   - Monitor positions during high market volatility

2. **Liquidation Prevention**
   - Implement safety buffers below LLTV for initial positions
   - Add automatic deleveraging mechanisms to avoid liquidations

3. **Market Liquidity**
   - Check market liquidity before large borrows
   - Cap position sizes based on market depth

4. **Authorization**
   - Verify authorization for all position operations
   - Implement timelock for large position changes

## Implementation Example

```solidity
// Full implementation example for a leveraged long position
function openLongPosition(
    address collateralToken,
    uint256 collateralAmount,
    uint256 leverage
) external nonReentrant returns (uint256 positionId) {
    // 1. Transfer and approve tokens
    IERC20(collateralToken).transferFrom(msg.sender, address(this), collateralAmount);
    
    // 2. Supply collateral to Morpho
    _supplyCollateral(collateralToken, collateralAmount);
    
    // 3. Calculate borrow amount (same as collateral token for long position)
    uint256 borrowAmount = calculateLeveragedBorrowAmount(
        collateralToken,
        collateralToken, // Borrow same token for long
        collateralAmount,
        leverage
    );
    
    // 4. Borrow from Morpho
    (uint256 borrowedAssets, ) = morpho.borrow(
        marketParamsForToken[collateralToken],
        borrowAmount,
        0, // Using asset amount, not shares
        address(this), // Position contract holds the debt
        address(this)  // Contract receives borrowed assets
    );
    
    // 5. Record new position
    positionId = nextPositionId++;
    positions[positionId] = Position({
        owner: msg.sender,
        collateralToken: collateralToken,
        debtToken: collateralToken,
        collateralAmount: collateralAmount + borrowedAssets, // Total position size
        debtAmount: borrowedAssets,
        leverage: leverage,
        createdAt: block.timestamp,
        lastUpdateTime: block.timestamp
    });
    
    // 6. Mint position NFT to user
    _mint(msg.sender, positionId);
    
    emit PositionCreated(positionId, msg.sender, collateralToken, collateralToken, leverage);
    return positionId;
}
```

## Simplified Implementations from MorphoBlueSnippets

MorphoBlueSnippets provides streamlined implementations of borrowing functions and utilities for position monitoring:

### Basic Borrowing Function

```solidity
/// @notice Handles the borrowing of assets by the caller from a specific market.
/// @param marketParams The parameters of the market.
/// @param amount The amount of assets the user is borrowing.
/// @return assetsBorrowed The actual amount of assets borrowed.
/// @return sharesBorrowed The shares borrowed in return for the assets.
function borrow(MarketParams memory marketParams, uint256 amount)
    external
    returns (uint256 assetsBorrowed, uint256 sharesBorrowed)
{
    uint256 shares;
    address onBehalf = msg.sender;
    address receiver = msg.sender;

    (assetsBorrowed, sharesBorrowed) = morpho.borrow(marketParams, amount, shares, onBehalf, receiver);
}
```

This simplified implementation:
- Assumes the borrower is also the receiver of the funds (most common case)
- Uses exact asset amount rather than shares for more predictable outcomes
- Doesn't handle token transfers or approvals, focusing only on the core borrowing logic

### Accurate Health Factor Calculation

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

The health factor calculation:
1. Gets the current oracle price for the collateral
2. Retrieves exact collateral and borrow balances
3. Calculates the maximum borrow capacity based on the loan-to-value ratio
4. Returns the ratio of maximum borrow capacity to current borrowed amount

A health factor below 1.0 means the position is eligible for liquidation.

### Efficient Position Monitoring

MorphoBlueSnippets provides gas-optimized functions for monitoring position components:

```solidity
/// @notice Calculates the total borrow balance of a given user in a specific market.
/// @param marketParams The parameters of the market.
/// @param user The address of the user whose borrow balance is being calculated.
/// @return totalBorrowAssets The calculated total borrow balance.
function borrowAssetsUser(MarketParams memory marketParams, address user)
    public
    view
    returns (uint256 totalBorrowAssets)
{
    totalBorrowAssets = morpho.expectedBorrowAssets(marketParams, user);
}

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

The `collateralAssetsUser` function is particularly efficient as it uses `extSloads` to directly access storage slots rather than making more expensive function calls.

### Market Analysis Tools

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

These functions help borrowers assess market conditions and borrowing costs before taking on debt.

## Complete Borrowing Workflow Using MorphoBlueSnippets

Here's a recommended borrowing workflow using MorphoBlueSnippets:

### 1. Pre-Borrowing Analysis

```solidity
// Check market conditions before borrowing
function analyzeBorrowingMarket(MarketParams memory marketParams) external view returns (
    uint256 totalSupply,
    uint256 totalBorrow,
    uint256 utilizationRate,
    uint256 currentAPY
) {
    Market memory market = morpho.market(marketParams.id());
    
    totalSupply = morphoSnippets.marketTotalSupply(marketParams);
    totalBorrow = morphoSnippets.marketTotalBorrow(marketParams);
    
    if (totalSupply > 0) {
        utilizationRate = totalBorrow * 1e18 / totalSupply;
    }
    
    currentAPY = morphoSnippets.borrowAPY(marketParams, market);
    
    return (totalSupply, totalBorrow, utilizationRate, currentAPY);
}
```

### 2. Position Simulation

```solidity
// Simulate borrowing impact on health factor
function simulateBorrowImpact(
    MarketParams memory marketParams,
    uint256 borrowAmount
) external view returns (uint256 currentHF, uint256 resultingHF) {
    Id id = marketParams.id();
    address user = msg.sender;
    
    // Get current health factor
    currentHF = morphoSnippets.userHealthFactor(marketParams, id, user);
    
    // Get current balances
    uint256 collateral = morphoSnippets.collateralAssetsUser(id, user);
    uint256 borrowed = morphoSnippets.borrowAssetsUser(marketParams, user);
    
    // Calculate new borrowed amount
    uint256 newBorrowed = borrowed + borrowAmount;
    
    // Simulate new health factor
    uint256 collateralPrice = IOracle(marketParams.oracle).price();
    uint256 maxBorrow = collateral.mulDivDown(collateralPrice, ORACLE_PRICE_SCALE).wMulDown(marketParams.lltv);
    
    if (newBorrowed == 0) {
        resultingHF = type(uint256).max;
    } else {
        resultingHF = maxBorrow.wDivDown(newBorrowed);
    }
    
    return (currentHF, resultingHF);
}
```

### 3. Execute Borrowing

```solidity
// Execute borrowing and verify health
function executeBorrow(
    MarketParams memory marketParams,
    uint256 borrowAmount,
    uint256 minHealthFactor
) external returns (uint256 assetsBorrowed, uint256 resultingHF) {
    Id id = marketParams.id();
    
    // Execute borrow
    (assetsBorrowed, ) = morphoSnippets.borrow(marketParams, borrowAmount);
    
    // Verify resulting health factor
    resultingHF = morphoSnippets.userHealthFactor(marketParams, id, msg.sender);
    
    // Ensure health factor remains above minimum
    require(resultingHF >= minHealthFactor, "Health factor too low after borrow");
    
    return (assetsBorrowed, resultingHF);
}
```

### 4. Post-Borrowing Monitoring

```solidity
// Track all borrowed positions
function monitorPositions(
    MarketParams[] memory marketParams
) external view returns (BorrowPosition[] memory positions) {
    positions = new BorrowPosition[](marketParams.length);
    
    for (uint256 i = 0; i < marketParams.length; i++) {
        Id id = marketParams[i].id();
        
        positions[i].collateral = morphoSnippets.collateralAssetsUser(id, msg.sender);
        positions[i].borrowed = morphoSnippets.borrowAssetsUser(marketParams[i], msg.sender);
        positions[i].healthFactor = morphoSnippets.userHealthFactor(marketParams[i], id, msg.sender);
        positions[i].marketId = id;
    }
    
    return positions;
}
```

This workflow demonstrates how to use MorphoBlueSnippets functions together to create a comprehensive borrowing management system that includes market analysis, position simulation, execution with safety checks, and monitoring. 