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

