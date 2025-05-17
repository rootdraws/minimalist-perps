# Minimalist Perpetual Futures Documentation

This documentation provides a comprehensive overview of the Minimalist Perpetual Futures system built on the Morpho protocol. It covers implementation details, usage examples, and best practices for integrating with the system.

## Table of Contents

### Core Concepts
- [Market Creation and Management](./core/markets.md) - Creating and configuring perpetual futures markets
- [Interest Rate Models](./core/interest.md) - How interest accrual is managed in Morpho
- [Share Accounting System](./core/shares.md) - How Morpho tracks positions using shares
- [Position Health Management](./core/health.md) - How position health is evaluated and maintained

### Functions 
- [Basic Operations](./functions/basic.md) - Core supply/withdraw operations
- [Management Functions](./functions/management.md) - Asset management operations
- [View Functions](./functions/view.md) - Position health monitoring
- [Admin Controls](./functions/admin.md) - Administrative functions and permissions
- [Authorization](./functions/authorization.md) - Permission systems with EIP-712 signatures
- [Utilities](./functions/utilities.md) - Batch operations and optimizations
- [Flash Loans](./functions/flash.md) - Flash loan implementations for leverage
- [Callbacks](./functions/callbacks.md) - Callback system for composable operations
- [Rewards](./functions/rewards.md) - Protocol reward handling

### Key Operations
- [Supply](./operations/supply.md) - Providing liquidity to the lending pool
- [Supply Collateral](./operations/supplyCollateral.md) - Supplying collateral to back positions
- [Withdraw](./operations/withdraw.md) - Withdrawing supplied assets
- [Withdraw Collateral](./operations/withdrawCollateral.md) - Withdrawing collateral from positions
- [Borrowing](./operations/borrowing.md) - Mechanics for leveraged positions
- [Repayment](./operations/repay.md) - Repaying borrowed assets
- [Liquidation](./operations/liquidation.md) - Liquidation process and handling bad debt

### Integration
- [Metrics and Monitoring](./integration/metrics.md) - API integration for funding rates and liquidity monitoring

## Getting Started

For new users, we recommend the following reading order:

1. Core Concepts: Markets → Share Accounting → Interest Rate Models → Position Health Management
2. Key Operations: Supply → Supply Collateral → Borrowing → Repayment → Liquidation → Withdraw → Withdraw Collateral
3. Functions: Basic Operations → View Functions → Management Functions → Callbacks → Authorization
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