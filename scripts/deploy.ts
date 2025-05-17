import { ethers } from "hardhat";

async function main() {
  console.log("Deploying MinimalistPerps...");

  // These addresses should be replaced with actual addresses for your deployment environment
  const morphoAddress = "0x0000000000000000000000000000000000000000"; // Replace with actual Morpho address
  const uniswapRouterAddress = "0x0000000000000000000000000000000000000000"; // Replace with actual Uniswap Router address
  const treasuryAddress = "0x0000000000000000000000000000000000000000"; // Replace with actual Treasury address

  // Get the contract factory
  const MinimalistPerps = await ethers.getContractFactory("MinimalistPerps");

  // Deploy the contract
  const minimalistPerps = await MinimalistPerps.deploy(
    morphoAddress,
    uniswapRouterAddress,
    treasuryAddress
  );

  await minimalistPerps.waitForDeployment();

  console.log(
    `MinimalistPerps deployed to: ${await minimalistPerps.getAddress()}`
  );
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
}); 