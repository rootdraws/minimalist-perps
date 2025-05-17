# Introduction to Morpho SDKs

https://docs.morpho.org/sdks/introduction/ [Intro about SDKs]
https://docs.morpho.org/overview/developers/quick-start/ [Basic App Repos]

The Morpho SDKs comprise a comprehensive suite of tools designed to facilitate interaction with the Morpho and Morpho Vaults ecosystems. These SDKs are organized into several categories to serve different development needs.

It is recommended to always use the most recently updated SDKs.

## Core SDKs

- **blue-sdk** - Framework-agnostic package that defines Morpho-related entity classes (such as Market, Token, Vault)
- **simulation-sdk** - Framework-agnostic package that defines methods to simulate interactions on Morpho (such as Supply, Borrow) and Morpho Vaults (such as Deposit, Withdraw)
- **blue-api-sdk** - GraphQL SDK that exports types from the API's GraphQL schema and a useful Apollo cache controller

## Viem Integration

- **blue-sdk-viem** - Viem-based augmentation of @morpho-org/blue-sdk that exports (and optionally injects) viem-based fetch methods
- **bundler-sdk-viem** - Viem-based extension of @morpho-org/simulation-sdk that exports utilities to transform simple interactions on Morpho (such as Blue_Borrow) and Morpho Vaults (such as MetaMorpho_Deposit) into the required bundles (with ERC20 approvals, transfers, etc) to submit to the bundler onchain
- **liquidity-sdk-viem** - Viem-based package that helps seamlessly calculate the liquidity available through the PublicAllocator
- **liquidation-sdk-viem** - Viem-based package that provides utilities to build viem-based liquidation bots on Morpho and examples using Flashbots and Morpho's GraphQL API

## Wagmi Integration

- **blue-sdk-wagmi** - Wagmi-based package that exports Wagmi (React) hooks to fetch Morpho-related entities
- **simulation-sdk-wagmi** - Wagmi-based extension of @morpho-org/simulation-sdk that exports Wagmi (React) hooks to fetch simulation states

## Ethers Integration

- **blue-sdk-ethers** - Ethers-based augmentation of @morpho-org/blue-sdk that exports (and optionally injects) ethers-based fetch methods
- **liquidity-sdk-ethers** - Ethers-based package that helps seamlessly calculate the liquidity available through the PublicAllocator

## Development Tools

- **morpho-ts** - TypeScript package to handle all things time & format-related

## Testing Utilities

- **test** - Viem-based package that exports utilities to build Vitest & Playwright fixtures that spawn anvil forks as child processes
- **test-wagmi** - Wagmi-based extension of @morpho-org/test that injects a test Wagmi config as a test fixture alongside viem's anvil client
- **morpho-test** - Framework-agnostic extension of @morpho-org/blue-sdk that exports test fixtures useful for E2E tests on forks

## How They Work Together

The Morpho Stack is designed with modularity in mind:

1. **Core Layer**: The blue-sdk, simulation-sdk, and blue-api-sdk provide the foundation
2. **Integration Layer**: Client-specific packages (Viem, Wagmi, Ethers) extend the core functionality
3. **Specialized Tools**: Packages for specific needs (liquidations, bundling, liquidity)
4. **Testing Layer**: Comprehensive testing utilities for different frameworks

## SDKs for MinimalistPerps

For our MinimalistPerps project, we have installed:

1. **@morpho-org/blue-sdk** - Provides classes for working with Morpho markets, positions, and tokens. This helps us model and calculate aspects of our perpetual futures system.

2. **@morpho-org/bundler-sdk-viem** - Helps bundle multiple transactions into one, making our frontend interactions more efficient.

These SDKs enable us to build a more efficient and user-friendly interface for our perpetual trading system while correctly modeling the underlying Morpho Blue protocol.

## Further Resources

For the latest updates and detailed documentation, visit the [Morpho SDKs repository](https://github.com/morpho-org) and the [Morpho Developer Hub](https://docs.morpho.org/). 