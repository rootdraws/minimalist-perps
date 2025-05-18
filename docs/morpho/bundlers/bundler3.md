# Bundler3 [Custom Swiss Army Knife with Features]

## Overview
Bundler3 is a call dispatcher that enables atomic execution of arbitrary calls with enhanced features for authorization management and callback handling.

## Core Functionality
The core Bundler3 contract implements `multicall(Call[] calldata bundle)`, where each call is defined by:

- `to`: Target address
- `data`: Calldata
- `value`: Native currency amount
- `skipRevert`: Flag to skip reverting if this particular call fails
- `callbackHash`: Specifies the hash used for controlling reentrancy callbacks

## Adapter System
Adapters all inherit from `CoreAdapter`, which provides access to the initiator (the original caller) via transient storage. This mechanism allows adapters to enforce strict permission checks (e.g., only acting on behalf of the initiator).

Chain-specific adapters, such as `EthereumGeneralAdapter1`, extend the base `GeneralAdapter1` to support network-specific features (e.g., stETH on Ethereum).

## Specialized Adapters
- `ParaswapAdapter` for DEX aggregation (buy/sell/swaps)
- Migration adapters for moving user positions between protocols (Aave, Compound, Morpho, etc.)

## SDK Integration
Bundler3 can be accessed through the SDK packages:
- `@morpho-org/bundler-sdk-viem`
- `@morpho-org/bundler-sdk-ethers`

### Available Actions
The SDK provides helper functions for various operations:

- **Token Operations**: Transfer ERC20/native tokens, wrap/unwrap ETH
- **Permit2 Integration**: Approve and transfer using Uniswap's Permit2
- **Morpho Markets**: Supply, borrow, repay, withdraw from Morpho markets
- **ERC4626 Vaults**: Deposit, withdraw, mint, redeem from Morpho vaults
- **Protocol Migrations**: Move positions between lending protocols (Aave, Compound)
- **Specialized Actions**: Lido staking, Universal Rewards Distributor claims

### Example Usage
```typescript
await bundler
  .connect(signer)
  .multicall([
    BundlerAction.wrapNative(1000000000000000000n),
    BundlerAction.erc20Transfer(wethAddress, recipient, 500000000000000000n),
    BundlerAction.morphoBorrow(
      marketParams,
      borrowAmount,
      0n,
      slippageAmount,
      borrower
    )
  ]);
```

### Best Practices
- Use slippage parameters to protect against price movements
- Utilize `bigint` for numeric values to avoid precision loss
- Consider gas optimization by ordering actions efficiently
- Test your encoded actions thoroughly before deploying

## Advanced SDK Usage

### Prerequisites
The bundler-sdk-viem package extends Morpho's interaction capabilities by converting simple user actions into bundled transactions with automatic handling of:
- ERC20 approvals and transfers
- Token wrapping/unwrapping
- Liquidity reallocations
- Simulation and error handling

### Installation
```bash
npm install @morpho-org/bundler-sdk-viem @morpho-org/blue-sdk @morpho-org/morpho-ts viem
```

### Core Workflow

1. **Populate Bundle**: Transform high-level operations into low-level contract calls
   ```typescript
   const { operations } = populateBundle(
     inputOperations,
     simulationState,
     bundlingOptions
   );
   ```

2. **Finalize Bundle**: Optimize by merging duplicate operations and redirecting tokens
   ```typescript
   const optimizedOperations = finalizeBundle(
     operations,
     simulationState,
     receiverAddress,
     unwrapTokensSet,
     unwrapSlippage
   );
   ```

3. **Encode Bundle**: Package operations into transaction format
   ```typescript
   const bundle = encodeBundle(operations, startData, supportsSignature);
   ```

4. **Execute Transaction**: Send the bundle to the blockchain
   ```typescript
   // Handle signature requirements first
   await Promise.all(
     bundle.requirements.signatures.map((requirement) => 
       requirement.sign(client, account)
     )
   );
   
   // Send transactions
   for (const tx of txs) {
     await client.sendTransaction({ ...tx, account });
   }
   ```

### Supported Operations

#### Blue Operations:
- `Blue_SetAuthorization`
- `Blue_Borrow`
- `Blue_Repay`
- `Blue_Supply`
- `Blue_SupplyCollateral`
- `Blue_Withdraw`
- `Blue_WithdrawCollateral`

#### Morpho Vaults Operations:
- `MetaMorpho_Deposit`
- `MetaMorpho_Withdraw`
- `MetaMorpho_PublicReallocate`

### Advanced Bundling Options
```typescript
const bundlingOptions: BundlingOptions = {
  withSimplePermit: new Set(["0xTokenAddress1", "0xTokenAddress2"]),
  publicAllocatorOptions: {
    enabled: true,
    supplyTargetUtilization: {
      [marketId]: 905000000000000000n, // ~90.5%
    },
    defaultSupplyTargetUtilization: 905000000000000000n,
  },
};
```

### Slippage Considerations
Always include slippage tolerance for operations involving asset conversions to ensure transactions succeed despite minor market changes:

```typescript
{
  type: "Blue_Repay",
  sender: userAddress,
  address: morpho,
  args: {
    id: marketId,
    shares: position.borrowShares,
    onBehalf: userAddress,
    slippage: DEFAULT_SLIPPAGE_TOLERANCE,
  },
}
```