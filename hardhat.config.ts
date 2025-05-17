import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";

// Load environment variables for private keys and API keys if needed
// import * as dotenv from "dotenv";
// dotenv.config();

// Uncomment to use private keys from environment variables
// const PRIVATE_KEY = process.env.PRIVATE_KEY || "0x0000000000000000000000000000000000000000000000000000000000000000";

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.17",
    settings: {
      viaIR: true,
      optimizer: {
        enabled: true,
        runs: 200,
      },
    },
  },
  networks: {
    hardhat: {
      chainId: 31337,
    },
    localhost: {
      url: "http://127.0.0.1:8545",
      chainId: 31337,
    },
    // Uncomment to add more networks
    // sepolia: {
    //   url: `https://eth-sepolia.g.alchemy.com/v2/${process.env.ALCHEMY_API_KEY || ""}`,
    //   accounts: PRIVATE_KEY ? [PRIVATE_KEY] : [],
    //   chainId: 11155111,
    // },
    // arbitrum: {
    //   url: `https://arb-mainnet.g.alchemy.com/v2/${process.env.ALCHEMY_API_KEY || ""}`,
    //   accounts: PRIVATE_KEY ? [PRIVATE_KEY] : [],
    //   chainId: 42161,
    // },
  },
  // Uncomment to enable etherscan verification
  // etherscan: {
  //   apiKey: process.env.ETHERSCAN_API_KEY || "",
  // },
};

export default config;
