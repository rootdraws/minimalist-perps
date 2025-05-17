# Morpho - Basic User Actions

## Core Functions
```solidity
// Key operations
morpho.supply(market, assets, shares, onBehalf, data);     // Supply assets to market
morpho.withdraw(market, assets, shares, receiver, owner, data);  // Withdraw assets
morpho.borrow(market, assets, shares, onBehalf, receiver, data); // Borrow assets
morpho.repay(market, assets, shares, onBehalf, data);      // Repay borrowed assets

// Vault interactions (ERC4626)
vault.deposit(assets, receiver);  // Deposit tokens, receive shares
vault.mint(shares, receiver);     // Receive exact shares amount
vault.withdraw(assets, receiver, owner);  // Withdraw exact token amount
vault.redeem(shares, receiver, owner);    // Burn shares for tokens
```

## Approvals
```solidity
// Standard approval
IERC20(token).approve(vaultAddress, amount);

// Gasless approval (EIP-2612)
permit(owner, spender, value, deadline, v, r, s);
```

## Deposit Operations
```solidity
// Asset-First: Deposit exact token amount
sharesReceived = vault.deposit(amountToDeposit, receiver);

// Shares-First: Get exact shares amount
assetsDeposited = vault.mint(sharesToMint, receiver);
```

## Withdrawal Operations
```solidity
// Asset-First: Get exact token amount
sharesBurned = vault.withdraw(amountToWithdraw, receiver, owner);

// Shares-First: Burn exact shares (best for full withdrawals)
assetsReceived = vault.redeem(sharesToRedeem, receiver, owner);
```

## Usage Tips
- For deposits: Use `deposit()` in most cases
- For withdrawals: Use `redeem()` for full withdrawals, `withdraw()` for specific amounts
- Check `maxRedeem()` and `maxWithdraw()` before executing
- High market utilization may limit withdrawals
