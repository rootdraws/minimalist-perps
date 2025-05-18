# Minimalist Perpetual Futures Documentation

This documentation provides a comprehensive overview of the Minimalist Perpetual Futures system built on the Morpho protocol. It covers implementation details, usage examples, and best practices for integrating with the system.

## Table of Contents

### Core Concepts
- [Market Creation and Management](./concepts/market-creation.md) - Creating and configuring perpetual futures markets
- [Interest Rate Models](./concepts/interest.md) - How interest accrual is managed in Morpho
- [Share Accounting System](./concepts/shares.md) - How Morpho tracks positions using shares
- [Position Health Management](./concepts/health.md) - How position health is evaluated and maintained

### API Reference 
- [Basic Operations](./api/basic.md) - Core supply/withdraw operations
- [Management Functions](./api/management.md) - Asset management operations
- [View Functions](./api/view.md) - Position health monitoring
- [Admin Controls](./api/admin.md) - Administrative functions and permissions
- [Authorization](./api/authorization.md) - Permission systems with EIP-712 signatures
- [Utilities](./api/utilities.md) - Batch operations and optimizations
- [Flash Loans](./api/flash.md) - Flash loan implementations for leverage
- [Callbacks](./api/callbacks.md) - Callback system for composable operations
- [Rewards](./api/rewards.md) - Protocol reward handling

### User Guides
- [Supply](./guides/supply.md) - Providing liquidity to the lending pool
- [Supply Collateral](./guides/supplyCollateral.md) - Supplying collateral to back positions
- [Withdraw](./guides/withdraw.md) - Withdrawing supplied assets
- [Withdraw Collateral](./guides/withdrawCollateral.md) - Withdrawing collateral from positions
- [Borrowing](./guides/borrowing.md) - Mechanics for leveraged positions
- [Repayment](./guides/repay.md) - Repaying borrowed assets
- [Liquidation](./guides/liquidation.md) - Liquidation process and handling bad debt
- [Leverage](./guides/leverage.md) - Creating leveraged positions using callbacks
- [Deleverage](./guides/deleverage.md) - Unwinding leveraged positions

### Integration
- [Metrics and Monitoring](./integration/metrics.md) - API integration for funding rates and liquidity monitoring

### SDKs
- [Introduction to Morpho SDKs](./sdk/intro.md) - Overview of available Morpho SDKs and their uses

### Oracles
- [Oracle Overview](./oracles/Oracle.md) - Introduction to oracles in the Morpho ecosystem

### Bundlers
- [Bundler References](./bundlers/bundler-ref.md) - Links to bundler resources and repositories
- [Bundler2](./bundlers/bundler2.md) - Simple multi-tool bundler implementation
- [Bundler3](./bundlers/bundler3.md) - Advanced bundler with enhanced features and SDK integration

## Getting Started

For new users, we recommend the following reading order:

1. Core Concepts: Market Creation → Share Accounting → Interest Rate Models → Position Health Management
2. User Guides: Supply → Supply Collateral → Borrowing → Repayment → Liquidation → Withdraw → Withdraw Collateral
3. API Reference: Basic Operations → View Functions → Management Functions → Callbacks → Authorization
4. Advanced Topics: Flash Loans → Admin Controls

## Implementation Notes

This documentation is specifically tailored to MinimalistPerps, a minimalist implementation of perpetual futures trading using the Morpho protocol. All code examples include practical implementation details that can be directly integrated into your projects.

Each document includes:
- Function signatures and parameters
- Implementation examples
- Error handling
- Security considerations

## Security Considerations

When implementing or integrating with MinimalistPerps, always consider:
- Oracle reliability and manipulation risks
- Liquidation thresholds and market volatility
- Position health monitoring
- Authorization and access controls

For any security concerns or questions, please open an issue in the repository. 