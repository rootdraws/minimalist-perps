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