# TODO 

## Critical Issues

### NFTPosition.sol
1. **Missing METADATA_ROLE Grant** - The `METADATA_ROLE` is defined but never granted to any entity, making metadata updates impossible
2. **No Automated Metadata Generation** - Despite extensive comments on how to implement position metadata, there's no actual code that generates metadata for positions
3. **No Token URI Implementation** - Need a mechanism to dynamically generate metadata based on current position metrics
4. **Missing tokenOfOwnerByIndex** - The `positionsOf` function relies on ERC721Enumerable's `tokenOfOwnerByIndex`, but we're using ERC721URIStorage which doesn't include this

### MinimalistPerps.sol
1. **Fatal Liquidation Bug** - In `liquidatePosition()`, the code emits the owner AFTER burning the NFT, which will revert as `ownerOf()` can't find a burned token
2. **No Slippage Protection** - All Uniswap swaps use `amountOutMinimum: 0`, making positions vulnerable to sandwich attacks and MEV
3. **Missing Short Position Implementation** - The `closePosition()` function has incomplete logic for handling short positions
4. **No Health Factor Checks** - After position modifications, there's no validation that the position remains healthy
5. **Division By Zero Risk** - `getHealthFactor()` has no check if `debtValueUSD` is zero, which would cause a revert

## Major Issues

1. **Position Metadata Disconnected** - No code in MinimalistPerps that updates NFT metadata when position health/values change
2. **Missing METADATA_ROLE Assignment** - MinimalistPerps never grants itself the METADATA_ROLE, so can't update position metadata
3. **Redundant Math** - `collateralToWithdraw = position.collateralAmount * sizeToReduce / position.collateralAmount` simplifies to `sizeToReduce`
4. **No Oracle Manipulation Protection** - Price feeds are used without any sanity checks or Time-Weighted Average Price (TWAP)
5. **No Emergency Pause Mechanism** - No way to pause the contract in case of emergency
6. **Flash Loan Attack Vector** - No checks against price manipulation via flash loans

## Integration Issues

1. **NFT Marketplace Integration** - Need to implement a mechanism to expose position health data to marketplaces
2. **Missing API for Secondary Market** - No way for marketplaces to query current position equity value
3. **No URI Update Triggers** - Need to add URI updates when:
   - Position is created
   - Position is modified
   - Health factor crosses critical thresholds
   - Collateral value changes significantly
4. **No Health Visualization** - No way to visually represent position health status on NFT marketplaces
5. **No Position Value Display** - No mechanism to show current equity value in position

## Feature Gaps

1. **Protocol Rescuer Mechanism** - Implement the "protocol as position rescuer" concept
2. **Pre-Liquidation Market Tools** - Add functions to support the secondary market for distressed positions
3. **Position Value Calculation** - Add a function to calculate current equity value of positions
4. **Health Factor Thresholds** - Define and implement visual indicators for different health statuses
5. **Bulk Position Management** - Add functions to view and manage multiple positions

## Implementation Suggestions Based on Morpho Documentation

### Critical Fixes

1. **Fix Fatal Liquidation Bug**:
```solidity
function liquidatePosition(uint256 positionId, uint24 uniswapFee) external nonReentrant {
    require(getHealthFactor(positionId) < LIQUIDATION_THRESHOLD, "Position not liquidatable");
    
    Position memory position = positions[positionId];
    address positionOwner = positionNFT.ownerOf(positionId); // Store owner BEFORE burning
    
    // Implement proper Morpho liquidation
    MarketParams memory marketParams = MarketParams({
        loanToken: position.borrowToken,
        collateralToken: position.collateralToken,
        oracle: address(priceFeeds[position.collateralToken]),
        irm: address(0), // Get from market params
        lltv: WAD * LIQUIDATION_THRESHOLD / HEALTH_FACTOR_PRECISION
    });
    
    // Transfer debt token to this contract for repayment
    uint256 repayAmount = position.debtAmount;
    IERC20(position.borrowToken).transferFrom(msg.sender, address(this), repayAmount);
    IERC20(position.borrowToken).approve(address(morpho), repayAmount);
    
    // Execute liquidation - seize all collateral
    (uint256 seized, uint256 repaid) = morpho.liquidate(
        marketParams,
        positionOwner,
        position.collateralAmount, // Seize all collateral
        0,
        ""
    );
    
    // Transfer seized collateral to liquidator
    IERC20(position.collateralToken).transfer(msg.sender, seized);
    
    // Burn the position NFT
    positionNFT.burn(positionId);
    
    // Delete position data
    delete positions[positionId];
    
    emit PositionLiquidated(positionId, positionOwner, msg.sender);
}
```

2. **Add Health Factor Check After Modifications**:
```solidity
// Add to modifyPosition() after position changes
function _checkAndUpdateHealthFactor(uint256 positionId) internal {
    uint256 healthFactor = getHealthFactor(positionId);
    require(healthFactor >= LIQUIDATION_THRESHOLD, "Position would be liquidatable");
    
    // Update metadata with new health factor
    if (positionNFT.hasRole(positionNFT.METADATA_ROLE(), address(this))) {
        string memory uri = generatePositionMetadata(positionId, healthFactor);
        positionNFT.setTokenURI(positionId, uri);
    }
}
```

3. **Prevent Division By Zero in Health Factor Calculation**:
```solidity
function getHealthFactor(uint256 positionId) public view returns (uint256) {
    Position memory position = positions[positionId];
    
    if (position.debtAmount == 0) return type(uint256).max; // No debt = infinite health
    
    // Get current value of collateral in USD
    uint256 collateralValueUSD = getTokenValueUSD(
        position.collateralToken,
        position.collateralAmount
    );
    
    // Get current value of debt in USD
    uint256 debtValueUSD = getTokenValueUSD(
        position.borrowToken,
        position.debtAmount
    );
    
    if (debtValueUSD == 0) return type(uint256).max; // Prevent division by zero
    
    // Calculate health factor (scaled by HEALTH_FACTOR_PRECISION)
    return (collateralValueUSD * HEALTH_FACTOR_PRECISION) / debtValueUSD;
}
```

### Major Improvements

1. **Add METADATA_ROLE Assignment and URI Updates**:
```solidity
// Add to constructor
constructor(...) {
    // ...existing code...
    
    // Grant METADATA_ROLE to this contract
    positionNFT.grantRole(positionNFT.METADATA_ROLE(), address(this));
}

// Add metadata generation function
function generatePositionMetadata(uint256 positionId, uint256 healthFactor) internal view returns (string memory) {
    Position memory position = positions[positionId];
    
    // Get current position metrics
    uint256 collateralValueUSD = getTokenValueUSD(position.collateralToken, position.collateralAmount);
    uint256 debtValueUSD = getTokenValueUSD(position.borrowToken, position.debtAmount);
    uint256 equityValueUSD = collateralValueUSD > debtValueUSD ? collateralValueUSD - debtValueUSD : 0;
    
    // Determine health status
    string memory healthStatus;
    if (healthFactor >= 2 * HEALTH_FACTOR_PRECISION) healthStatus = "Very Healthy";
    else if (healthFactor >= 1.5 * HEALTH_FACTOR_PRECISION) healthStatus = "Healthy";
    else if (healthFactor >= 1.2 * HEALTH_FACTOR_PRECISION) healthStatus = "Moderate";
    else if (healthFactor >= 1.1 * HEALTH_FACTOR_PRECISION) healthStatus = "Risky";
    else healthStatus = "Near Liquidation";
    
    // Generate JSON metadata
    return string(abi.encodePacked(
        '{"name":"Perp Position #', _toString(positionId), '",',
        '"description":"', position.isLong ? "Long" : "Short", ' ', getTokenSymbol(position.collateralToken), '/',
        getTokenSymbol(position.borrowToken), ' Position",',
        '"image":"https://api.minimalistperps.com/position/image/', _toString(positionId), '/',
        _toString(healthFactor), '",',
        '"attributes":[',
        '{"trait_type":"Position Type","value":"', position.isLong ? "Long" : "Short", '"},',
        '{"trait_type":"Collateral Token","value":"', getTokenSymbol(position.collateralToken), '"},',
        '{"trait_type":"Debt Token","value":"', getTokenSymbol(position.borrowToken), '"},',
        '{"trait_type":"Health Factor","value":', _toString(healthFactor / 1e16), ',"display_type":"number"},',
        '{"trait_type":"Collateral Value (USD)","value":', _toString(collateralValueUSD / 1e18), ',"display_type":"number"},',
        '{"trait_type":"Debt Value (USD)","value":', _toString(debtValueUSD / 1e18), ',"display_type":"number"},',
        '{"trait_type":"Equity Value (USD)","value":', _toString(equityValueUSD / 1e18), ',"display_type":"number"},',
        '{"trait_type":"Health Status","value":"', healthStatus, '"}',
        ']}'));
}

// Helper function for converting uint to string
function _toString(uint256 value) internal pure returns (string memory) {
    if (value == 0) return "0";
    
    uint256 temp = value;
    uint256 digits;
    while (temp != 0) {
        digits++;
        temp /= 10;
    }
    
    bytes memory buffer = new bytes(digits);
    while (value != 0) {
        digits -= 1;
        buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
        value /= 10;
    }
    
    return string(buffer);
}
```

2. **Implement Slippage Protection**:
```solidity
function _swapWithSlippage(
    address tokenIn,
    address tokenOut,
    uint256 amountIn,
    uint24 fee
) internal returns (uint256 amountOut) {
    // Get expected output based on oracle prices (conservative estimate)
    uint256 expectedOut = getExpectedSwapOutput(tokenIn, tokenOut, amountIn);
    uint256 minAmountOut = expectedOut * 95 / 100; // 5% slippage tolerance
    
    IERC20(tokenIn).approve(address(uniswapRouter), amountIn);
    
    ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
        tokenIn: tokenIn,
        tokenOut: tokenOut,
        fee: fee,
        recipient: address(this),
        deadline: block.timestamp,
        amountIn: amountIn,
        amountOutMinimum: minAmountOut, // Apply slippage protection
        sqrtPriceLimitX96: 0
    });
    
    return uniswapRouter.exactInputSingle(params);
}

function getExpectedSwapOutput(
    address tokenIn,
    address tokenOut,
    uint256 amountIn
) public view returns (uint256) {
    uint256 tokenInValueUSD = getTokenValueUSD(tokenIn, amountIn);
    return tokenInValueUSD * 1e18 / getTokenValueUSD(tokenOut, 1e18);
}
```

### New Features for Pre-Liquidation Market

1. **Position Value Calculator**:
```solidity
function getPositionEquityValue(uint256 positionId) public view returns (uint256 equityValueUSD) {
    Position memory position = positions[positionId];
    
    uint256 collateralValueUSD = getTokenValueUSD(position.collateralToken, position.collateralAmount);
    uint256 debtValueUSD = getTokenValueUSD(position.borrowToken, position.debtAmount);
    
    if (collateralValueUSD > debtValueUSD) {
        return collateralValueUSD - debtValueUSD;
    }
    return 0;
}
```

2. **Secondary Market Metrics API**:
```solidity
function getPositionMarketMetrics(uint256 positionId) external view returns (
    uint256 healthFactor,
    uint256 equityValue,
    uint256 liquidationPrice,
    uint256 collateralValue,
    uint256 debtValue
) {
    Position memory position = positions[positionId];
    
    healthFactor = getHealthFactor(positionId);
    collateralValue = getTokenValueUSD(position.collateralToken, position.collateralAmount);
    debtValue = getTokenValueUSD(position.borrowToken, position.debtAmount);
    equityValue = collateralValue > debtValue ? collateralValue - debtValue : 0;
    
    // Calculate the price at which this position would be liquidated
    uint256 currentPrice = uint256(IOracle(priceFeeds[position.collateralToken]).price());
    liquidationPrice = position.isLong ? 
        currentPrice * LIQUIDATION_THRESHOLD / healthFactor :
        currentPrice * healthFactor / LIQUIDATION_THRESHOLD;
        
    return (healthFactor, equityValue, liquidationPrice, collateralValue, debtValue);
}
```

