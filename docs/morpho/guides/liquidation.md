# Liquidation Mechanics in Morpho

## Core Liquidation Function

```solidity
// Main liquidation function
function liquidate(
    MarketParams memory marketParams,  // Market parameters
    address borrower,                  // Address of the position to liquidate
    uint256 seizedAssets,              // Collateral amount to seize (provide 0 if using shares)
    uint256 repaidShares,              // Shares to repay (provide 0 if using seizedAssets)
    bytes calldata data                // Callback data
) external returns (uint256 seized, uint256 repaid);
```

## Position Health Assessment

```solidity
// Check if a position is liquidatable
function isLiquidatable(
    address borrower,
    address collateralToken,
    address debtToken
) public view returns (bool) {
    MarketParams memory params = marketParamsForToken[collateralToken];
    
    // Get borrower's collateral and debt
    uint256 collateralAmount = morpho.collateral(params.id(), borrower);
    uint256 borrowAmount = morpho.borrowBalance(params.id(), borrower);
    
    // Get current oracle price
    uint256 price = IOracle(params.oracle).price();
    
    // Calculate collateral value in USD
    uint256 collateralValue = collateralAmount.mulDivDown(price, ORACLE_PRICE_SCALE);
    
    // Calculate max allowed borrow based on LLTV
    uint256 maxBorrow = collateralValue.wMulDown(params.lltv);
    
    // Position is liquidatable if borrow amount exceeds max allowed
    return borrowAmount > maxBorrow;
}
```

## Liquidation Parameter Calculation

```solidity
// Calculate liquidation incentive factor based on LLTV
function _liquidationIncentiveFactor(uint256 lltv) internal pure returns (uint256) {
    // Lower LLTV markets have higher incentives for liquidators
    // This follows Morpho's approach: (WAD - lltv) / 2 + LIQUIDATION_INCENTIVE_BASE
    return (WAD - lltv) / 2 + LIQUIDATION_INCENTIVE_BASE;
}

// Calculate max amount of collateral that can be seized
function calculateMaxSeizableCollateral(
    address borrower,
    address collateralToken,
    address debtToken
) public view returns (uint256) {
    MarketParams memory params = marketParamsForToken[collateralToken];
    
    // Get liquidation incentive
    uint256 liquidationIncentive = _liquidationIncentiveFactor(params.lltv);
    
    // Get borrower's debt
    uint256 debt = morpho.borrowBalance(params.id(), borrower);
    
    // Get oracle price
    uint256 price = IOracle(params.oracle).price();
    
    // Calculate seizeable amount with incentive
    return debt.wMulDown(liquidationIncentive).mulDivDown(ORACLE_PRICE_SCALE, price);
}
```

## Liquidation Implementation

```solidity
// Execute liquidation with collateral amount input
function liquidatePosition(
    uint256 positionId,
    uint256 collateralAmount
) external nonReentrant returns (uint256 seized, uint256 repaid) {
    // Get position details
    Position storage position = positions[positionId];
    address borrower = ownerOf(positionId);
    
    // Verify position is liquidatable
    if (!isLiquidatable(borrower, position.collateralToken, position.debtToken)) {
        revert HealthyPosition(positionId);
    }
    
    // Transfer debt tokens from liquidator to contract
    MarketParams memory params = marketParamsForToken[position.collateralToken];
    
    // Cap collateral amount to max allowable seizure
    uint256 maxSeizable = calculateMaxSeizableCollateral(
        borrower,
        position.collateralToken,
        position.debtToken
    );
    
    if (collateralAmount > maxSeizable) {
        collateralAmount = maxSeizable;
    }
    
    // Approve tokens for repayment
    IERC20(position.debtToken).transferFrom(msg.sender, address(this), type(uint256).max);
    IERC20(position.debtToken).approve(address(morpho), type(uint256).max);
    
    // Execute liquidation
    (seized, repaid) = morpho.liquidate(
        params,
        borrower,
        collateralAmount,
        0,  // Using collateral amount input
        "" // No callback data
    );
    
    // Transfer seized collateral to liquidator
    IERC20(position.collateralToken).transfer(msg.sender, seized);
    
    // Refund any unused debt tokens
    uint256 remainingBalance = IERC20(position.debtToken).balanceOf(address(this));
    if (remainingBalance > 0) {
        IERC20(position.debtToken).transfer(msg.sender, remainingBalance);
    }
    
    // Update position state
    position.collateralAmount -= seized;
    position.debtAmount -= repaid;
    
    emit PositionLiquidated(positionId, msg.sender, seized, repaid);
    
    return (seized, repaid);
}
```

## Bad Debt Handling

### Protocol-Level Bad Debt Resolution

The Morpho protocol has a built-in mechanism for handling bad debt that occurs when a borrower's position is liquidated but the collateral value is insufficient to cover the outstanding debt. Let's examine how this works at the protocol level:

```solidity
// From Morpho.sol - within the liquidate function
if (position[id][borrower].collateral == 0) {
    badDebtShares = position[id][borrower].borrowShares;
    badDebtAssets = UtilsLib.min(
        market[id].totalBorrowAssets,
        badDebtShares.toAssetsUp(market[id].totalBorrowAssets, market[id].totalBorrowShares)
    );

    market[id].totalBorrowAssets -= badDebtAssets.toUint128();
    market[id].totalSupplyAssets -= badDebtAssets.toUint128();
    market[id].totalBorrowShares -= badDebtShares.toUint128();
    position[id][borrower].borrowShares = 0;
}
```

When a liquidation occurs and depletes all of a borrower's collateral (`position[id][borrower].collateral == 0`), but the borrower still has outstanding debt (`position[id][borrower].borrowShares > 0`), the protocol:

1. **Identifies Bad Debt**: The remaining borrow shares become bad debt shares
2. **Calculates Asset Equivalent**: Converts the bad debt shares to asset terms
3. **Socializes Losses**: Reduces both `totalBorrowAssets` and `totalSupplyAssets` by the bad debt amount
4. **Clears Borrower's Position**: Sets the borrower's borrow shares to zero

This process effectively socializes the loss across all suppliers in the market, as the reduction in `totalSupplyAssets` diminishes the value of all supply shares. Every supplier absorbs a portion of the bad debt proportional to their supply share in the market.

### Implementation for MinimalistPerps

```solidity
// Extended implementation that handles bad debt processes
function liquidateWithBadDebtTracking(
    MarketParams memory marketParams,
    address borrower
) external returns (uint256 seizedAssets, uint256 repaidAssets, uint256 badDebtAmount) {
    bytes32 marketId = morpho.idFromMarketParams(marketParams);
    
    // Get borrower's position details
    uint256 collateralBalance = morpho.collateral(marketId, borrower);
    uint256 borrowShares = morpho.borrowShares(marketId, borrower);
    uint256 totalBorrowAssets = morpho.totalBorrowAssets(marketId);
    uint256 totalBorrowShares = morpho.totalBorrowShares(marketId);
    
    // Calculate total debt in asset terms
    uint256 totalDebt = borrowShares.toAssetsUp(totalBorrowAssets, totalBorrowShares);
    
    // Determine if we're likely to have bad debt
    uint256 collateralPrice = IOracle(marketParams.oracle).price();
    uint256 collateralValue = collateralBalance.mulDivDown(collateralPrice, ORACLE_PRICE_SCALE);
    uint256 potentialBadDebt = 0;
    
    // Check if collateral value is less than debt (including liquidation incentive)
    if (collateralValue < totalDebt) {
        potentialBadDebt = totalDebt - (collateralValue.wDivDown(LIQUIDATION_INCENTIVE_FACTOR));
        emit PotentialBadDebtDetected(marketId, borrower, potentialBadDebt);
    }
    
    // Track supply metrics before liquidation for analysis
    uint256 totalSupplyBefore = morpho.totalSupplyAssets(marketId);
    uint256 totalSupplySharesBefore = morpho.totalSupplyShares(marketId);
    
    // Execute the liquidation
    (seizedAssets, repaidAssets) = morpho.liquidate(
        marketParams,
        borrower,
        collateralBalance, // Attempt to seize all collateral
        0,
        "" // No callback data
    );
    
    // Check for realized bad debt by comparing metrics after liquidation
    uint256 totalSupplyAfter = morpho.totalSupplyAssets(marketId);
    
    // If total supply decreased more than just from repayment, bad debt was realized
    if (totalSupplyBefore - totalSupplyAfter > repaidAssets) {
        badDebtAmount = totalSupplyBefore - totalSupplyAfter - repaidAssets;
        emit BadDebtRealized(marketId, borrower, badDebtAmount);
        
        // Update protocol-level bad debt tracking
        cumulativeBadDebtByMarket[marketId] += badDebtAmount;
        totalBadDebt += badDebtAmount;
    }
    
    return (seizedAssets, repaidAssets, badDebtAmount);
}
```

### Impact on Suppliers

When bad debt is realized, all suppliers in the affected market experience a dilution of their supply shares' value. This loss distribution mechanism has several implications:

1. **Loss Socialization**: Each supplier loses a portion of their value proportional to their share of the total supply
2. **No Insurance Fund**: Unlike some lending protocols, Morpho does not maintain an insurance fund to cover bad debt
3. **Transparent Accounting**: The total supply value immediately reflects the loss (no hidden liabilities)
4. **Market Isolation**: Bad debt in one market does not affect suppliers in other markets

Example calculation of a supplier's loss from bad debt:

```solidity
function calculateSupplierBadDebtImpact(
    bytes32 marketId,
    address supplier,
    uint256 badDebtAmount
) public view returns (uint256 supplierLoss) {
    uint256 totalSupplyAssets = morpho.totalSupplyAssets(marketId);
    uint256 totalSupplyShares = morpho.totalSupplyShares(marketId);
    uint256 supplierShares = morpho.supplyShares(marketId, supplier);
    
    // Supplier's proportion of the market
    uint256 supplierProportion = supplierShares.wDivDown(totalSupplyShares);
    
    // Supplier's portion of the bad debt
    supplierLoss = badDebtAmount.wMulDown(supplierProportion);
    
    return supplierLoss;
}
```

### Risk Mitigation Strategies

To minimize the impact of bad debt:

1. **Conservative LTVs**: Set lower liquidation LTV ratios for volatile assets
2. **Robust Oracles**: Implement safeguards against oracle manipulation or failure
3. **Liquidation Incentives**: Ensure liquidation incentives are attractive enough to encourage timely liquidations
4. **Circuit Breakers**: Implement market pauses during extreme volatility
5. **Position Monitoring**: Provide early warning systems for borrowers approaching liquidation thresholds

### Events and Monitoring

```solidity
// Events for bad debt tracking
event PotentialBadDebtDetected(
    bytes32 indexed marketId,
    address indexed borrower,
    uint256 estimatedBadDebtAmount
);

event BadDebtRealized(
    bytes32 indexed marketId,
    address indexed borrower,
    uint256 badDebtAmount
);

event MarketBadDebtRatioChanged(
    bytes32 indexed marketId,
    uint256 previousRatio,
    uint256 newRatio
);
```

### Liquidation with bad debt realization

```solidity
// Liquidation with bad debt realization
function liquidateWithBadDebtHandling(
    uint256 positionId
) external nonReentrant returns (uint256 seized, uint256 repaid, uint256 badDebt) {
    Position storage position = positions[positionId];
    address borrower = ownerOf(positionId);
    
    // Verify position is liquidatable
    if (!isLiquidatable(borrower, position.collateralToken, position.debtToken)) {
        revert HealthyPosition(positionId);
    }
    
    // Transfer maximum debt tokens from liquidator for full liquidation
    uint256 maxDebt = morpho.borrowBalance(
        marketIdForToken[position.debtToken],
        borrower
    );
    
    // Transfer debt tokens from liquidator
    IERC20(position.debtToken).transferFrom(msg.sender, address(this), maxDebt);
    IERC20(position.debtToken).approve(address(morpho), maxDebt);
    
    // Liquidate the entire position
    MarketParams memory params = marketParamsForToken[position.collateralToken];
    
    // Get total collateral
    uint256 totalCollateral = position.collateralAmount;
    
    try morpho.liquidate(
        params,
        borrower,
        totalCollateral, // Seize all collateral
        0,
        ""
    ) returns (uint256 _seized, uint256 _repaid) {
        seized = _seized;
        repaid = _repaid;
        
        // Calculate bad debt (if any)
        if (repaid < maxDebt) {
            badDebt = maxDebt - repaid;
        }
        
        // Refund unused debt tokens
        uint256 remainingBalance = IERC20(position.debtToken).balanceOf(address(this));
        if (remainingBalance > 0) {
            IERC20(position.debtToken).transfer(msg.sender, remainingBalance);
        }
        
        // Transfer seized collateral to liquidator
        IERC20(position.collateralToken).transfer(msg.sender, seized);
        
        // Update position state
        position.collateralAmount = 0;
        position.debtAmount = 0;
        
        emit PositionLiquidatedWithBadDebt(positionId, msg.sender, seized, repaid, badDebt);
    } catch Error(string memory reason) {
        emit LiquidationFailed(positionId, reason);
        // Refund liquidator
        IERC20(position.debtToken).transfer(msg.sender, maxDebt);
        revert LiquidationError(reason);
    }
    
    return (seized, repaid, badDebt);
}
```

## Liquidator Implementation

```solidity
// Liquidator keeper that monitors and liquidates positions
function liquidateUnhealthyPositions(
    uint256[] calldata positionIds,
    uint256 minProfitMargin
) external nonReentrant {
    for (uint256 i = 0; i < positionIds.length; i++) {
        uint256 positionId = positionIds[i];
        Position memory position = positions[positionId];
        
        // Skip healthy positions
        if (!isLiquidatable(ownerOf(positionId), position.collateralToken, position.debtToken)) {
            continue;
        }
        
        // Calculate profit potential based on liquidation incentive
        MarketParams memory params = marketParamsForToken[position.collateralToken];
        uint256 liquidationIncentive = _liquidationIncentiveFactor(params.lltv);
        
        // Calculate expected profit
        uint256 debtValue = position.debtAmount;
        uint256 priceCollateral = IOracle(params.oracle).price();
        uint256 seizedValue = debtValue.wMulDown(liquidationIncentive);
        uint256 collateralValue = position.collateralAmount.mulDivDown(priceCollateral, ORACLE_PRICE_SCALE);
        
        // Calculate expected profit (as ratio * 1e18)
        uint256 profitMargin = (seizedValue * WAD) / debtValue - WAD;
        
        // Skip if profit margin is too low
        if (profitMargin < minProfitMargin) {
            continue;
        }
        
        // Try to liquidate the position
        try this.liquidatePosition(positionId, position.collateralAmount) {
            // Liquidation successful
        } catch {
            // Skip failed liquidations
            continue;
        }
    }
}
```

## Error Handling

```solidity
// Custom errors for liquidation operations
error HealthyPosition(uint256 positionId);
error InsufficientCollateral(uint256 available, uint256 required);
error LiquidationError(string reason);
error ZeroAmount();
error InconsistentInput();

// Events
event PositionLiquidated(
    uint256 indexed positionId,
    address indexed liquidator,
    uint256 collateralSeized,
    uint256 debtRepaid
);
event PositionLiquidatedWithBadDebt(
    uint256 indexed positionId,
    address indexed liquidator,
    uint256 collateralSeized,
    uint256 debtRepaid,
    uint256 badDebt
);
event LiquidationFailed(uint256 indexed positionId, string reason);
```

## Testing Strategies

1. **Healthy Position Test**
   - Create a position with sufficient collateral
   - Verify it cannot be liquidated
   
2. **Liquidatable Position Test**
   - Create a position with minimal collateral
   - Decrease oracle price until position becomes unhealthy
   - Verify liquidation succeeds
   
3. **Bad Debt Test**
   - Create a position with debt exceeding collateral value
   - Execute liquidation
   - Verify bad debt is properly recorded
   
4. **Partial Liquidation Test**
   - Create an unhealthy position
   - Liquidate a portion of the collateral
   - Verify remaining position state

## Security Considerations

1. **Price Oracle Manipulation**
   - Implement time-weighted price feeds to reduce manipulation risk
   - Add safety margins around liquidation thresholds
   
2. **Frontrunning Protection**
   - Use private relayer networks for liquidation transactions
   - Implement gasless liquidations via signatures
   
3. **Gas Optimization**
   - Batch liquidation calls to save gas
   - Avoid unnecessary storage reads during liquidation

4. **Bad Debt Management**
   - Implement protocol fees to build an insurance fund
   - Use token reserves to cover bad debt
   
5. **Position Monitoring**
   - Implement cost-effective position monitoring
   - Set appropriate warning thresholds for positions nearing liquidation

## Callback-Based Liquidations

Morpho supports liquidations with callbacks, allowing liquidators to perform liquidations without holding the repayment tokens upfront. This is particularly useful for:

1. Enabling liquidation bots to operate with minimal capital
2. Facilitating flash-loan-like liquidation operations
3. Implementing just-in-time swaps of seized collateral to repay debt

### Callback Interface Implementation

```solidity
// Implementation of the IMorphoLiquidateCallback interface
contract LiquidationWithCallback is IMorphoLiquidateCallback {
    using SafeTransferLib for ERC20;
    
    IMorpho public immutable morpho;
    ISwap public immutable swapper;
    
    // Type of liquidation callback data
    struct LiquidateData {
        address collateralToken;
    }
    
    modifier onlyMorpho() {
        require(msg.sender == address(morpho), "msg.sender should be Morpho Blue");
        _;
    }
    
    // This function is called by Morpho during the liquidation process
    function onMorphoLiquidate(uint256, bytes calldata data) external onlyMorpho {
        LiquidateData memory decoded = abi.decode(data, (LiquidateData));
        
        // Approve swapper to use seized collateral
        ERC20(decoded.collateralToken).approve(address(swapper), type(uint256).max);
        
        // Swap seized collateral for loan tokens to complete the liquidation
        swapper.swapCollatToLoan(ERC20(decoded.collateralToken).balanceOf(address(this)));
    }
}
```

### Liquidation Without Upfront Capital

```solidity
function fullLiquidationWithoutCollat(
    MarketParams calldata marketParams,
    address borrower,
    bool seizeFullCollat
) public returns (uint256 seizedAssets, uint256 repaidAssets) {
    Id id = marketParams.id();
    
    uint256 seizedCollateral;
    uint256 repaidShares;
    
    if (seizeFullCollat) {
        // Liquidate by specifying collateral amount (seize all available)
        seizedCollateral = morpho.collateral(id, borrower);
    } else {
        // Liquidate by specifying shares amount (repay all debt)
        repaidShares = morpho.borrowShares(id, borrower);
    }
    
    // Approve Morpho to use loan tokens after they're obtained in the callback
    _approveMaxTo(marketParams.loanToken, address(morpho));
    
    // Execute liquidation with callback
    (seizedAssets, repaidAssets) = morpho.liquidate(
        marketParams,
        borrower,
        seizedCollateral,
        repaidShares,
        abi.encode(LiquidateData(marketParams.collateralToken))
    );
    
    // Forward loan tokens to the caller
    ERC20(marketParams.loanToken).safeTransfer(
        msg.sender,
        ERC20(marketParams.loanToken).balanceOf(address(this))
    );
}
```

### Liquidation Flow with Callbacks

1. The liquidator calls `fullLiquidationWithoutCollat`
2. Morpho seizes the collateral from the borrower
3. Before requiring repayment, Morpho calls `onMorphoLiquidate` on the liquidation contract
4. The callback swaps the seized collateral for loan tokens via an external swapper
5. After the callback completes, Morpho completes the liquidation using the newly acquired loan tokens
6. Any profit (excess loan tokens) is forwarded to the original caller

### Integration Considerations

When implementing callback-based liquidations, consider:

1. **Slippage Protection**: Ensure swaps have appropriate slippage protection
2. **MEV Protection**: Be aware of potential MEV (Miner Extractable Value) during swaps
3. **Gas Efficiency**: Use gas-efficient swap routes to maximize profitability
4. **Revert Handling**: Properly handle cases where swaps or callbacks revert

This callback-based approach allows liquidations to be performed without capital lockup, enabling more efficient liquidator operations and potentially faster liquidation of unhealthy positions.