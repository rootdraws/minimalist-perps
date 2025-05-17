# Morpho Reward Management

## Core Functions

```solidity
function claim(address account, address rewardToken, uint256 claimable, bytes32[] calldata proof) external returns (uint256);
function getRewardsBalance(address account, address[] memory rewardTokens) external view returns (uint256[] memory);
function pendingRewards(address account) external view returns (address[] memory tokens, uint256[] memory amounts);
```

## Implementation

```solidity
// Contract state variables
mapping(address => uint256) public rewardBalances;
mapping(uint256 => uint256) public lastRewardClaim;
address public immutable urdController;

// Protocol reward claiming with Merkle proof verification
function claimProtocolRewards(
    address rewardToken,
    uint256 amount,
    bytes32[] calldata proof
) external onlyRole(TREASURY_ROLE) returns (uint256 claimed) {
    if (amount == 0) revert ZeroAmount();
    if (rewardToken == address(0)) revert ZeroAddress();
    
    // Verify and claim rewards
    try IUniversalRewardsDistributor(urdController).claim(
        address(this),
        rewardToken, 
        amount,
        proof
    ) returns (uint256 _claimed) {
        claimed = _claimed;
        
        // Split rewards between protocol treasury and user incentives
        uint256 treasuryPortion = claimed * protocolFeeRate / MAX_BPS; // e.g. 8000 = 80%
        uint256 userPortion = claimed - treasuryPortion;
        
        // Update reward pool
        rewardBalances[rewardToken] += userPortion;
        
        // Transfer protocol share to treasury
        IERC20(rewardToken).transfer(treasury, treasuryPortion);
        
        emit RewardsClaimed(rewardToken, claimed, treasuryPortion, userPortion);
    } catch (bytes memory reason) {
        emit RewardsClaimFailed(rewardToken, amount, reason);
    }
}

// Claim rewards for specific position
function claimPositionRewards(uint256 positionId) external nonReentrant returns (uint256) {
    if (!_exists(positionId)) revert InvalidPositionId(positionId);
    if (_ownerOf(positionId) != msg.sender) revert NotPositionOwner(positionId);
    
    // Calculate rewards based on position age and size
    uint256 rewards = _calculateRewards(positionId);
    if (rewards == 0) revert NoRewardsAvailable();
    
    address rewardToken = defaultRewardToken;
    if (rewardBalances[rewardToken] < rewards) {
        rewards = rewardBalances[rewardToken]; // Cap to available balance
    }
    
    // Update balances
    rewardBalances[rewardToken] -= rewards;
    lastRewardClaim[positionId] = block.timestamp;
    
    // Transfer rewards
    IERC20(rewardToken).transfer(msg.sender, rewards);
    
    emit PositionRewardsClaimed(positionId, rewardToken, rewards);
    return rewards;
}

// Calculate rewards based on position metrics
function _calculateRewards(uint256 positionId) internal view returns (uint256) {
    Position storage position = positions[positionId];
    
    // Get time since position opened or last claimed
    uint256 lastClaim = lastRewardClaim[positionId];
    uint256 timePeriod = lastClaim > 0 
        ? block.timestamp - lastClaim 
        : block.timestamp - position.createdAt;
        
    // Skip if position is too new
    if (timePeriod < MIN_REWARD_PERIOD) return 0;
    
    // Base reward on position size and time
    uint256 positionValue = getPositionValue(positionId);
    uint256 baseReward = positionValue * rewardRate * timePeriod / (365 days * PRECISION);
    
    // Apply multiplier for long-term positions (max 2x)
    uint256 ageMultiplier = Math.min(
        2 * PRECISION,
        PRECISION + ((position.createdAt - block.timestamp) * PRECISION / MAX_REWARD_AGE)
    );
    
    return baseReward * ageMultiplier / PRECISION;
}

// View function for available rewards
function getClaimableRewards(uint256 positionId) external view returns (uint256) {
    if (!_exists(positionId)) return 0;
    if (_ownerOf(positionId) != msg.sender) return 0;
    
    uint256 rewards = _calculateRewards(positionId);
    address rewardToken = defaultRewardToken;
    
    // Cap to available balance
    if (rewards > rewardBalances[rewardToken]) {
        rewards = rewardBalances[rewardToken];
    }
    
    return rewards;
}
```

## Error Handling

```solidity
// Custom errors
error ZeroAmount();
error ZeroAddress();
error InvalidPositionId(uint256 positionId);
error NotPositionOwner(uint256 positionId);
error NoRewardsAvailable();
error InsufficientRewards(uint256 requested, uint256 available);

// Events for tracking
event RewardsClaimed(address token, uint256 total, uint256 treasury, uint256 users);
event RewardsClaimFailed(address token, uint256 amount, bytes reason);
event PositionRewardsClaimed(uint256 positionId, address token, uint256 amount);
```

## Integration With Positions

```solidity
// Add to position creation
function openPosition(...) external nonReentrant returns (uint256 positionId) {
    // ... existing position creation logic ...
    
    // Initialize reward tracking
    positions[positionId].createdAt = block.timestamp;
    
    // ... remaining logic ...
}

// Add to fee calculation
function calculateTradingFee(address user, uint256 amount) public view returns (uint256) {
    // Apply discount based on user's claimed rewards
    uint256 userRewards = totalUserRewards[user];
    uint256 discount = Math.min(MAX_FEE_DISCOUNT, userRewards * FEE_DISCOUNT_RATE / PRECISION);
    
    // Calculate fee with discount
    return amount * (baseFeeRate - discount) / MAX_BPS;
}
```

## Backend Requirements

1. **Reward Monitoring**
   - Poll Morpho API for claimable rewards
   - Generate and store Merkle proofs
   
2. **Keeper Service**
   - Automated reward claiming (weekly)
   - Position reward calculation and distribution

## UI Integration

- Display claimable rewards on position dashboard
- Claim button for eligible position holders
- Track rewards history for tax reporting
