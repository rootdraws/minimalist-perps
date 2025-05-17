# Morpho - Vault Metrics

## Core Functions
```graphql
// Main API queries
vaults { items { address, name, symbol } }                    // Get list of vaults
vaults { items { state { totalAssets, totalAssetsUsd } } }    // Get vault assets/liquidity
vaults { items { state { apy, netApy, dailyNetApy } } }       // Get yield information
vaults { items { historicalState { apy, netApy } } }          // Get historical performance

// User-specific query
vaultPositions(where: { userAddress_in: [$userAddress] }) { items { assets } }  // Get user positions
```

## API Endpoint
```
blue-api.morpho.org/graphql
```

## Detailed Queries

### Vault List
```graphql
query {
  vaults {
    items {
      address
      symbol
      name
      asset { address, decimals }
      chain { id, network }
    }
  }
}
```

### Assets & Liquidity
```graphql
query {
  vaults(first: 100, orderBy: TotalAssetsUsd) {
    items {
      address
      state {
        totalAssets
        totalAssetsUsd
        totalSupply
      }
    }
  }
}
```

### APY Components
```graphql
query {
  vaults(first: 10) {
    items {
      address
      state {
        apy            # Native APY
        netApy         # Total APY with rewards
        dailyNetApy    # 24h APY with rewards
        rewards {
          asset { address }
          supplyApr
        }
      }
    }
  }
}
```

### Historical Performance
```graphql
query VaultApys($options: TimeseriesOptions) {
  vaults(first: 10) {
    items {
      address
      historicalState {
        apy(options: $options) { x, y }
        netApy(options: $options) { x, y }
      }
    }
  }
}
```

## APY Calculation Formula

```
Net APY = Native APY + Underlying Token Yield + Rewards APRs - Performance Fee
```

Where:
- Native APY: Base yield from market deposits
- Rewards APRs: Additional incentives (vault-level and market-level)
- Performance Fee: Applied only to Native APY component

## User Positions

```graphql
query GetUserPositions($chainId: Int!, $userAddress: String!) {
  vaultPositions(
    where: { 
      chainId_in: [$chainId], 
      userAddress_in: [$userAddress] 
    }
  ) {
    items {
      assets
      vault { address }
    }
  }
}
```
