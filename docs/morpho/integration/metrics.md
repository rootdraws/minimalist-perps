# Morpho Protocol Metrics Integration

## Core API Endpoints

```javascript
const MORPHO_API_URL = "https://blue-api.morpho.org/graphql";
const MORPHO_SUBGRAPH = "https://api.thegraph.com/subgraphs/name/morpho-labs/morpho-blue";
```

## Contract State Variables

```solidity
// Analytics trackers
struct MarketMetrics {
    uint256 lastUpdateTimestamp;
    uint256 currentSupplyAPY;
    uint256 currentBorrowAPY;
    uint256 totalLiquidity;
    uint256 utilization;
}

// Market metrics storage
mapping(address => MarketMetrics) public marketMetrics;
uint256 public constant UPDATE_INTERVAL = 1 hours;
```

## On-chain Metric Collection

```solidity
// Update market metrics from Morpho contract
function updateMarketMetrics(address token) public {
    if (!supportedMarkets[token]) revert UnsupportedMarket(token);
    MarketMetrics storage metrics = marketMetrics[token];
    
    // Only update once per interval
    if (block.timestamp < metrics.lastUpdateTimestamp + UPDATE_INTERVAL) return;
    
    // Get current APY rates
    MarketParams memory params = marketParamsForToken[token];
    metrics.currentSupplyAPY = morpho.supplyAPY(params);
    metrics.currentBorrowAPY = morpho.borrowAPY(params);
    
    // Get current market balances
    (uint256 totalSupply, , uint256 totalBorrow, ) = morpho.expectedMarketBalances(params);
    metrics.totalLiquidity = totalSupply > totalBorrow ? totalSupply - totalBorrow : 0;
    metrics.utilization = totalBorrow == 0 ? 0 : (totalBorrow * PRECISION) / totalSupply;
    
    // Update timestamp
    metrics.lastUpdateTimestamp = block.timestamp;
    
    emit MarketMetricsUpdated(token, metrics.currentSupplyAPY, metrics.currentBorrowAPY, metrics.utilization);
}

// Calculate funding rate from market APYs
function calculateFundingRate(address token) public view returns (uint256) {
    if (!supportedMarkets[token]) revert UnsupportedMarket(token);
    
    MarketMetrics memory metrics = marketMetrics[token];
    
    // Funding rate = borrow APY + spread
    return metrics.currentBorrowAPY + (metrics.currentBorrowAPY * fundingRateSpread / MAX_BPS);
}

// Check liquidity in multiple markets
function getMarketsWithLowLiquidity() external view returns (address[] memory) {
    address[] memory lowLiquidityMarkets = new address[](supportedTokens.length);
    uint256 count = 0;
    
    for (uint256 i = 0; i < supportedTokens.length; i++) {
        address token = supportedTokens[i];
        MarketMetrics memory metrics = marketMetrics[token];
        
        // Check if liquidity is below threshold
        if (metrics.totalLiquidity < minLiquidityThresholds[token]) {
            lowLiquidityMarkets[count] = token;
            count++;
        }
    }
    
    // Resize array to actual count
    assembly {
        mstore(lowLiquidityMarkets, count)
    }
    
    return lowLiquidityMarkets;
}
```

## Off-chain API Integration

```typescript
// Fetch market metrics for UI display
export async function fetchMorphoMetrics(tokens: string[]): Promise<Record<string, MarketMetrics>> {
  try {
    const query = `
      query GetMarketMetrics($tokens: [String!]!) {
        markets(where: { id_in: $tokens }) {
          id
          totalSupplyAssets
          totalBorrowAssets
          borrowRate
          supplyRate
          lastUpdate
        }
      }
    `;
    
    const response = await fetch(MORPHO_API_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        query,
        variables: { tokens }
      })
    });
    
    const { data } = await response.json();
    
    // Process and format the results
    const results: Record<string, MarketMetrics> = {};
    for (const market of data.markets) {
      const utilization = market.totalBorrowAssets > 0 
        ? (market.totalBorrowAssets * 1e18) / market.totalSupplyAssets 
        : 0;
      
      results[market.id] = {
        supplyAPY: parseInt(market.supplyRate),
        borrowAPY: parseInt(market.borrowRate),
        liquidity: parseInt(market.totalSupplyAssets) - parseInt(market.totalBorrowAssets),
        utilization,
        timestamp: parseInt(market.lastUpdate)
      };
    }
    
    return results;
  } catch (error) {
    console.error('Error fetching Morpho metrics:', error);
    throw new Error('Failed to fetch market metrics');
  }
}

// Calculate position funding rate from API data
export function calculatePositionFundingCost(
  positionValue: number,
  borrowAPY: number,
  timeHeldInDays: number
): number {
  // Convert APY to daily rate (APY is in basis points)
  const dailyRate = borrowAPY / 10000 / 365;
  
  // Calculate funding cost
  return positionValue * dailyRate * timeHeldInDays;
}
```

## Keeper Service Implementation

```typescript
// Keeper service to monitor market health
import { ethers } from 'ethers';
import { MinimalistPerpsABI } from './abis';

export async function monitorMarketHealth(
  provider: ethers.providers.Provider,
  contractAddress: string,
  warningThresholdPercent: number = 15
): Promise<void> {
  const contract = new ethers.Contract(contractAddress, MinimalistPerpsABI, provider);
  
  // Get supported tokens
  const supportedTokens = await contract.getSupportedTokens();
  
  // Query Morpho API for market data
  const marketData = await fetchMorphoMetrics(supportedTokens);
  
  // Check liquidity of each market
  for (const token of supportedTokens) {
    const metrics = marketData[token];
    const minRequired = await contract.minLiquidityThresholds(token);
    
    // Calculate liquidity as percentage of minimum required
    const liquidityPercent = (metrics.liquidity * 100) / minRequired;
    
    if (liquidityPercent < warningThresholdPercent) {
      console.warn(`CRITICAL: ${token} liquidity at ${liquidityPercent.toFixed(2)}% of minimum threshold`);
      // Send alerts via preferred notification channel
      await sendAlert({
        token,
        currentLiquidity: metrics.liquidity,
        minRequired,
        utilization: metrics.utilization
      });
    }
  }
}

// Run keeper service every 10 minutes
setInterval(async () => {
  await monitorMarketHealth(provider, PERPS_CONTRACT_ADDRESS);
}, 10 * 60 * 1000);
```

## UI Components

```typescript
// React component for position funding information
function PositionFundingInfo({ positionId }: { positionId: string }) {
  const [fundingData, setFundingData] = useState({
    dailyRate: 0,
    hourlyRate: 0,
    accruedFees: 0
  });
  
  useEffect(() => {
    async function loadFundingData() {
      // Get position from contract
      const position = await perpsContract.getPositionDetails(positionId);
      
      // Get current market metrics from our API cache
      const marketData = await fetchMorphoMetrics([position.debtToken]);
      const borrowAPY = marketData[position.debtToken].borrowAPY;
      
      // Calculate funding rates
      const dailyRate = borrowAPY / 365 / 10000;
      const hourlyRate = dailyRate / 24;
      
      // Calculate accrued fees since last payment
      const accruedFees = await perpsContract.calculateFundingFee(positionId);
      
      setFundingData({
        dailyRate,
        hourlyRate,
        accruedFees: ethers.utils.formatUnits(accruedFees, 18)
      });
    }
    
    loadFundingData();
    // Refresh every 5 minutes
    const interval = setInterval(loadFundingData, 5 * 60 * 1000);
    return () => clearInterval(interval);
  }, [positionId]);
  
  return (
    <div className="funding-info">
      <h3>Funding Information</h3>
      <div>Daily Rate: {(fundingData.dailyRate * 100).toFixed(4)}%</div>
      <div>Hourly Rate: {(fundingData.hourlyRate * 100).toFixed(4)}%</div>
      <div>Accrued Fees: {parseFloat(fundingData.accruedFees).toFixed(6)}</div>
    </div>
  );
}
```

## Error Handling

```solidity
// Custom errors
error UnsupportedMarket(address token);
error StaleMetrics(address token, uint256 lastUpdate);
error APIRequestFailed(string reason);

// Events
event MarketMetricsUpdated(address token, uint256 supplyAPY, uint256 borrowAPY, uint256 utilization);
event LiquidityAlert(address token, uint256 currentLiquidity, uint256 minThreshold);
```
