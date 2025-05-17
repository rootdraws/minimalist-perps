# Minimalist Perps

A minimalist perpetual futures trading protocol built on Ethereum. This project utilizes Morpho for lending/borrowing and Uniswap for swaps.

## Features

- Leveraged long and short positions
- Position management (create, modify, close)
- Liquidation mechanisms
- NFT-based position ownership

## Development

### Prerequisites

- Node.js (v16+)
- npm or yarn

### Installation

1. Clone the repository
```bash
git clone https://github.com/yourusername/minimalist-perps.git
cd minimalist-perps
```

2. Install dependencies
```bash
npm install
```

### Compile Contracts

```bash
npx hardhat compile
```

### Run Tests

```bash
npx hardhat test
```

### Deploy

1. Configure deployment parameters in `scripts/deploy.ts`
2. Run deployment script:
```bash
npx hardhat run scripts/deploy.ts --network [network-name]
```

## Contract Architecture

- `PerpsPositionNFT`: NFT contract for position ownership
- `MinimalistPerps`: Main contract handling all perpetual functions
  - Position creation (long/short)
  - Position management (modify/close)
  - Liquidation
  - Flash loan integration

## License

MIT
