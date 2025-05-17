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

