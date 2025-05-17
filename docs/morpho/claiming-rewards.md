# Morpho - Claiming Rewards

## Core Functions
```solidity
// Universal Rewards Distributor (URD)
urd.claim(account, reward, claimable, proof);  // Claim rewards with Merkle proof verification
```

// urd means universal rewards distributor

## Claim Function Details
```solidity
// Full function signature
function claim(
    address account,    // Reward recipient
    address reward,     // Reward token address
    uint256 claimable,  // Total amount claimable (from API)
    bytes32[] calldata proof  // Merkle proof validating the claim
) external returns (uint256 amount);
```

## Implementation Steps
1. Get user's claimable rewards and proof from API
2. Call the URD contract's claim function
3. Handle returned amount (may be less than claimable if partially claimed)

## Security Tips
- Never modify proof data from API
- Batch claims when possible for gas efficiency
- Verify URD contract addresses
- Implement proper error handling

## Example Usage
```solidity
// Get data from API (pseudo-code)
(uint256 claimable, bytes32[] memory proof) = getClaimData(userAddress, rewardToken);

// Execute claim
uint256 claimed = urd.claim(userAddress, rewardToken, claimable, proof);
```
