# Permit2 Integration [A better way to permission smart contracts to use tokens.]

Repo for Examples:
https://github.com/Uniswap/permit2

## Overview
Permit2 is a token approval system compatible with all ERC-20 tokens that streamlines user experience and reduces gas costs. It shifts the intensive work onto smart contracts, requiring users to only sign gasless off-chain messages to express their intent to modify permissions.

## How It Works
1. **One-time Setup**: Users perform a traditional approval for their tokens to the Permit2 contract (typically for the maximum amount)
2. **Permission via Signature**: Users express permission intent through off-chain signatures
3. **Verification and Transfer**: Permit2 verifies signatures and uses pre-approved allowances to transfer tokens on the user's behalf

## Implementation Methods

### Allowance Transfers
- Updates allowance mapping in Permit2 contract via `permit2.permit()`
- Spender can call `permit2.transferFrom()` multiple times within allowance limits
- More efficient for multiple transfers over time
- Example:
  ```solidity
  // First call when permit hasn't been called yet
  permit2.permit(msg.sender, permitSingle, signature);
  permit2.transferFrom(msg.sender, address(this), amount, token);
  
  // Subsequent calls when permit is already active
  permit2.transferFrom(msg.sender, address(this), amount, token);
  ```

### Signature Transfers
- Directly calls `permitTransferFrom()` with valid signature
- No allowance mapping updated - more gas efficient for one-time transfers
- Signatures cannot be reused (nonce is marked used after transfer)
- Can include additional "witness" data for custom applications
- Example:
  ```solidity
  permit2.permitTransferFrom(
      permitData,
      transferDetails,
      msg.sender, 
      signature
  );
  ```

## Benefits
- Reduces transactions from two to one for token transfers
- Works with all ERC-20 tokens (backward compatible)
- Includes permission deadlines to improve security
- Allows for batch operations across multiple tokens
- Integrated within the Morpho ecosystem for optimized transactions 