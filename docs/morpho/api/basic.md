# Basic Morpho Functions in MinimalistPerps

## Core Integration Points

```solidity
// Main functions used in our implementation
morpho.supply(marketParams, assets, 0, address(this), data);     // Deposit collateral
morpho.withdraw(marketParams, assets, 0, receiver, address(this), ""); // Remove collateral
morpho.borrow(marketParams, assets, 0, address(this), address(this), ""); // Leverage positions
morpho.repay(marketParams, assets, 0, address(this), data);      // Unwind positions
```

## Collateral Management

```solidity
// Supply collateral for positions
function _supplyCollateral(address token, uint256 amount) internal {
    // Ensure market approval
    IERC20(token).approve(address(morpho), amount);
    
    // Supply to appropriate market
    morpho.supply(
        tokenToMarketParams[token],
        amount,
        0, // Min shares (0 for any amount)
        address(this), // On behalf of contract
        "" // No callback needed for pre-approved tokens
    );
}

// Withdraw collateral when closing positions
function _withdrawCollateral(
    address token, 
    uint256 amount, 
    address receiver
) internal returns (uint256 withdrawn) {
    withdrawn = morpho.withdraw(
        tokenToMarketParams[token],
        amount,
        0, // Min shares (0 for any amount)
        receiver,
        address(this), // Owner (contract holds position)
        "" // No callback needed
    );
}
```

## Leverage Operations

```solidity
// Borrow for leveraged positions
function _borrowToken(
    address token, 
    uint256 amount
) internal returns (uint256 borrowed) {
    borrowed = morpho.borrow(
        tokenToMarketParams[token],
        amount,
        0, // Min borrow (0 for any amount)
        address(this), // Debt recorded to contract
        address(this), // Receive tokens here
        "" // No callback needed
    );
}

// Repay debt when closing positions
function _repayDebt(
    address token, 
    uint256 amount
) internal returns (uint256 repaid) {
    // Ensure contract has approved tokens
    IERC20(token).approve(address(morpho), amount);
    
    repaid = morpho.repay(
        tokenToMarketParams[token],
        amount,
        0, // Min repay (0 for any amount)
        address(this), // Repay contract's debt
        "" // No callback needed
    );
}
```

## Position Lifecycle Implementation

```solidity
// From position creation function
function createLongPosition(...) external nonReentrant returns (uint256 positionId) {
    // Initial position setup...
    
    // First add user's collateral to Morpho
    _supplyCollateral(collateralToken, collateralAmount);
    
    // Borrow additional tokens for leverage via flash loan
    // (See flash-functions.md for details)
    
    // Record position data
    positions[positionId] = Position({
        collateralToken: collateralToken,
        borrowToken: borrowToken,
        collateralAmount: totalCollateral,
        debtAmount: flashLoanAmount,
        isLong: true
    });
}

// From position closing function
function closePosition(uint256 positionId) external nonReentrant {
    Position memory position = positions[positionId];
    
    // 1. Withdraw collateral from Morpho
    _withdrawCollateral(
        position.collateralToken, 
        position.collateralAmount,
        address(this)
    );
    
    // 2. Swap some for debt token
    // Swap implementation...
    
    // 3. Repay debt to Morpho
    _repayDebt(position.borrowToken, position.debtAmount);
    
    // 4. Return remaining collateral to user
    IERC20(position.collateralToken).transfer(msg.sender, remainingCollateral);
}
```

## Error Handling

```solidity
function _safeSupply(address token, uint256 amount) internal returns (uint256, uint256) {
    try morpho.supply(tokenToMarketParams[token], amount, 0, address(this), "") {
        return morpho.getSupplyBalance(tokenToMarketParams[token].id(), address(this));
    } catch Error(string memory reason) {
        emit SupplyFailed(token, amount, reason);
        return (0, 0);
    }
}

function _safeWithdraw(address token, uint256 amount, address receiver) internal returns (uint256) {
    // Check max available first to avoid reverts
    uint256 maxWithdraw = morpho.maxWithdraw(tokenToMarketParams[token].id(), address(this));
    if (amount > maxWithdraw) {
        amount = maxWithdraw;
    }
    
    return morpho.withdraw(tokenToMarketParams[token], amount, 0, receiver, address(this), "");
}
```
