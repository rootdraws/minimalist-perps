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

## Share-Based Operations

The MorphoBlueSnippets contract demonstrates how to work effectively with Morpho's share accounting system:

```solidity
/// @notice Handles the withdrawal of 50% of the assets by the caller from a specific market.
/// @param marketParams The parameters of the market.
/// @return assetsWithdrawn The actual amount of assets withdrawn.
/// @return sharesWithdrawn The shares withdrawn in return for the assets.
function withdraw50Percent(MarketParams memory marketParams)
    external
    returns (uint256 assetsWithdrawn, uint256 sharesWithdrawn)
{
    Id marketId = marketParams.id();
    uint256 supplyShares = morpho.position(marketId, msg.sender).supplyShares;
    uint256 amount;
    uint256 shares = supplyShares / 2;

    address onBehalf = msg.sender;
    address receiver = msg.sender;

    // Pass shares instead of amount for more gas-efficient operation
    (assetsWithdrawn, sharesWithdrawn) = morpho.withdraw(marketParams, amount, shares, onBehalf, receiver);
}

/// @notice Handles the withdrawal of all the assets by the caller from a specific market.
/// @param marketParams The parameters of the market.
/// @return assetsWithdrawn The actual amount of assets withdrawn.
/// @return sharesWithdrawn The shares withdrawn in return for the assets.
function withdrawAll(MarketParams memory marketParams)
    external
    returns (uint256 assetsWithdrawn, uint256 sharesWithdrawn)
{
    Id marketId = marketParams.id();
    uint256 supplyShares = morpho.position(marketId, msg.sender).supplyShares;
    uint256 amount;

    address onBehalf = msg.sender;
    address receiver = msg.sender;

    // Withdraw all shares in a single operation
    (assetsWithdrawn, sharesWithdrawn) = morpho.withdraw(marketParams, amount, supplyShares, onBehalf, receiver);
}
```

## Proper Interest Accrual

When performing operations that depend on current position values, always accrue interest first:

```solidity
function withdrawWithInterestAccrual(MarketParams memory marketParams, uint256 amount) external returns (uint256, uint256) {
    Id id = marketParams.id();
    
    // Always accrue interest before critical operations
    morpho.accrueInterest(marketParams);
    
    // Now use the updated market state
    uint256 totalSupplyAssets = morpho.totalSupplyAssets(id);
    uint256 totalSupplyShares = morpho.totalSupplyShares(id);
    uint256 shares = morpho.supplyShares(id, msg.sender);
    
    // Calculate current position value with latest interest
    uint256 currentBalance = shares.toAssetsDown(totalSupplyAssets, totalSupplyShares);
    
    // Proceed with withdrawal
    return morpho.withdraw(marketParams, amount, 0, msg.sender, msg.sender);
}

function repayWithExactAmount(MarketParams memory marketParams, uint256 amount) external returns (uint256, uint256) {
    // Ensure interest is accrued for accurate debt calculation
    morpho.accrueInterest(marketParams);
    
    // Approve tokens for transfer
    ERC20(marketParams.loanToken).forceApprove(address(morpho), amount);
    ERC20(marketParams.loanToken).safeTransferFrom(msg.sender, address(this), amount);
    
    // Repay the exact amount specified
    return morpho.repay(marketParams, amount, 0, msg.sender, "");
}
```

## Flexible Repayment and Withdrawal Patterns

The MorphoBlueSnippets contract demonstrates the "OrAll" pattern for maximum flexibility:

```solidity
/// @notice Handles the withdrawal of a specified amount of assets by the caller from a specific market.
/// If the amount is greater than the total amount supplied by the user, withdraws all the shares of the user.
function withdrawAmountOrAll(MarketParams memory marketParams, uint256 amount)
    external
    returns (uint256 assetsWithdrawn, uint256 sharesWithdrawn)
{
    Id id = marketParams.id();
    address onBehalf = msg.sender;
    address receiver = msg.sender;

    // Ensure interest is accrued
    morpho.accrueInterest(marketParams);
    
    // Calculate the maximum amount user can withdraw based on current shares
    uint256 totalSupplyAssets = morpho.totalSupplyAssets(id);
    uint256 totalSupplyShares = morpho.totalSupplyShares(id);
    uint256 shares = morpho.supplyShares(id, msg.sender);
    uint256 assetsMax = shares.toAssetsDown(totalSupplyAssets, totalSupplyShares);

    // If requested more than available, withdraw everything
    if (amount >= assetsMax) {
        (assetsWithdrawn, sharesWithdrawn) = morpho.withdraw(marketParams, 0, shares, onBehalf, receiver);
    } else {
        (assetsWithdrawn, sharesWithdrawn) = morpho.withdraw(marketParams, amount, 0, onBehalf, receiver);
    }
}

/// @notice Handles repayment with similar flexibility - repays all if requested amount exceeds debt
function repayAmountOrAll(MarketParams memory marketParams, uint256 amount)
    external
    returns (uint256 assetsRepaid, uint256 sharesRepaid)
{
    ERC20(marketParams.loanToken).forceApprove(address(morpho), type(uint256).max);
    Id id = marketParams.id();
    address onBehalf = msg.sender;

    // Ensure interest is accrued
    morpho.accrueInterest(marketParams);
    
    // Calculate the exact current debt with interest
    uint256 totalBorrowAssets = morpho.totalBorrowAssets(id);
    uint256 totalBorrowShares = morpho.totalBorrowShares(id);
    uint256 shares = morpho.borrowShares(id, msg.sender);
    uint256 assetsMax = shares.toAssetsUp(totalBorrowAssets, totalBorrowShares);

    // Optimize the repayment based on amount
    if (amount >= assetsMax) {
        // Repay exact amount needed (avoid overpaying)
        ERC20(marketParams.loanToken).safeTransferFrom(msg.sender, address(this), assetsMax);
        (assetsRepaid, sharesRepaid) = morpho.repay(marketParams, 0, shares, onBehalf, "");
    } else {
        ERC20(marketParams.loanToken).safeTransferFrom(msg.sender, address(this), amount);
        (assetsRepaid, sharesRepaid) = morpho.repay(marketParams, amount, 0, onBehalf, "");
    }
}
```

## Efficient Token Handling

Proper token approval and transfer patterns are essential for gas optimization and security:

```solidity
function tokenHandlingExample(MarketParams memory marketParams, uint256 amount) internal {
    address loanToken = marketParams.loanToken;
    
    // Option 1: Approve exact amount (more gas efficient for one-time operations)
    ERC20(loanToken).approve(address(morpho), amount);
    
    // Option 2: Infinite approval (more gas efficient for repeated operations)
    ERC20(loanToken).forceApprove(address(morpho), type(uint256).max);
    
    // Safe transfer from user to contract
    ERC20(loanToken).safeTransferFrom(msg.sender, address(this), amount);
    
    // Supply to Morpho (token already in contract)
    morpho.supply(marketParams, amount, 0, msg.sender, "");
}
```

## Share-Asset Conversion Best Practices

When working with Morpho's share system, use proper rounding to ensure fair accounting:

```solidity
function sharesHandlingExample(MarketParams memory marketParams, address user) internal {
    Id id = marketParams.id();
    
    // Always accrue interest before share calculations
    morpho.accrueInterest(marketParams);
    
    // Get the current market state
    uint256 totalSupplyAssets = morpho.totalSupplyAssets(id);
    uint256 totalSupplyShares = morpho.totalSupplyShares(id);
    uint256 totalBorrowAssets = morpho.totalBorrowAssets(id);
    uint256 totalBorrowShares = morpho.totalBorrowShares(id);
    
    // Get user shares
    uint256 supplyShares = morpho.supplyShares(id, user);
    uint256 borrowShares = morpho.borrowShares(id, user);
    
    // Convert supply shares to assets (round down, favoring protocol)
    uint256 supplyAssets = supplyShares.toAssetsDown(totalSupplyAssets, totalSupplyShares);
    
    // Convert borrow shares to assets (round up, favoring protocol)
    uint256 borrowAssets = borrowShares.toAssetsUp(totalBorrowAssets, totalBorrowShares);
    
    // Calculate net position
    uint256 netPosition = supplyAssets > borrowAssets ? supplyAssets - borrowAssets : 0;
}
```
