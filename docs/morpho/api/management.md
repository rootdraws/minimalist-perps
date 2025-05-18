# Asset Management in MinimalistPerps

## Vault Operations

```solidity
function depositInVault(address vault, uint256 assets, address onBehalf) internal returns (uint256 shares);
function withdrawFromVaultAmount(address vault, uint256 assets, address receiver) internal returns (uint256 withdrawn);
function redeemAllFromVault(address vault, address receiver) internal returns (uint256 redeemed);
function reallocateAssets(address vault, MarketParams[] memory sources, MarketParams memory destination) internal;
```

## Implementation

```solidity
// Supply user collateral to Morpho vault
function _supplyCollateral(address token, uint256 amount) internal returns (uint256 shares) {
    if (amount == 0) revert ZeroAmount();
    if (!supportedCollateral[token]) revert UnsupportedCollateral(token);
    
    IERC20(token).transferFrom(msg.sender, address(this), amount);
    _approveToken(token, vaultForToken[token], amount);
    
    try IVault(vaultForToken[token]).deposit(amount, address(this)) returns (uint256 _shares) {
        shares = _shares;
        emit CollateralSupplied(msg.sender, token, amount, shares);
    } catch (bytes memory reason) {
        // Revert original tokens to user
        IERC20(token).transfer(msg.sender, amount);
        emit SupplyFailed(token, amount, reason);
    }
}

// Withdraw collateral back to user or contract
function _withdrawCollateral(
    address token, 
    uint256 amount, 
    address receiver
) internal returns (uint256 withdrawn) {
    if (amount == 0) revert ZeroAmount();
    if (receiver == address(0)) revert ZeroAddress();
    
    address vault = vaultForToken[token];
    
    // Check available liquidity and cap if needed
    uint256 maxWithdraw = IVault(vault).maxWithdraw(address(this));
    if (amount > maxWithdraw) {
        amount = maxWithdraw;
        emit PartialWithdrawal(token, amount, maxWithdraw);
    }
    
    withdrawn = IVault(vault).withdraw(amount, receiver, address(this));
}

// Withdraw all collateral (useful for emergency scenarios)
function emergencyWithdraw(
    address token,
    address receiver
) external onlyRole(EMERGENCY_ROLE) returns (uint256 withdrawn) {
    address vault = vaultForToken[token];
    withdrawn = IVault(vault).redeem(
        IVault(vault).balanceOf(address(this)),
        receiver,
        address(this)
    );
    emit EmergencyWithdrawal(token, withdrawn, receiver);
}

// Optimal treasury management function
function rebalanceTreasury(
    address[] calldata sourceTokens,
    address destinationToken
) external onlyRole(TREASURY_ROLE) returns (uint256 rebalanced) {
    if (sourceTokens.length == 0) revert EmptySources();
    if (!supportedCollateral[destinationToken]) revert UnsupportedCollateral(destinationToken);
    
    MarketParams[] memory sources = new MarketParams[](sourceTokens.length);
    for (uint256 i; i < sourceTokens.length; i++) {
        if (!supportedCollateral[sourceTokens[i]]) revert UnsupportedCollateral(sourceTokens[i]);
        sources[i] = tokenToMarketParams[sourceTokens[i]];
    }
    
    try ITreasury(treasury).reallocateAssets(
        sources,
        tokenToMarketParams[destinationToken]
    ) returns (uint256 amount) {
        rebalanced = amount;
        emit TreasuryRebalanced(sourceTokens, destinationToken, amount);
    } catch (bytes memory reason) {
        emit RebalanceFailed(reason);
    }
}
```

## Integration Points

```solidity
// Position management
function openPosition(address collateralToken, uint256 amount, uint256 leverage) external nonReentrant {
    uint256 shares = _supplyCollateral(collateralToken, amount);
    // Use shares for position tracking
    positions[nextPositionId].collateralShares = shares;
    // Additional position setup...
}

function closePosition(uint256 positionId) external nonReentrant {
    Position storage position = positions[positionId];
    // Convert shares back to assets for withdrawal
    uint256 assets = IVault(vaultForToken[position.token]).convertToAssets(position.collateralShares);
    _withdrawCollateral(position.token, assets, msg.sender);
    // Handle remaining position closing logic...
}

// Emergency pause actions
function pauseWithdrawals() external onlyRole(GUARDIAN_ROLE) {
    withdrawalsPaused = true;
    emit WithdrawalsPaused(block.timestamp);
}
```

## Withdrawal Strategies

The MorphoBlueSnippets contract provides several efficient withdrawal strategies:

```solidity
/// @notice Handles the withdrawal of a specified amount of assets by the caller from a specific market.
/// @param marketParams The parameters of the market.
/// @param amount The amount of assets the user is withdrawing.
/// @return assetsWithdrawn The actual amount of assets withdrawn.
/// @return sharesWithdrawn The shares withdrawn in return for the assets.
function withdrawAmount(MarketParams memory marketParams, uint256 amount)
    external
    returns (uint256 assetsWithdrawn, uint256 sharesWithdrawn)
{
    uint256 shares;
    address onBehalf = msg.sender;
    address receiver = msg.sender;

    (assetsWithdrawn, sharesWithdrawn) = morpho.withdraw(marketParams, amount, shares, onBehalf, receiver);
}

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

    (assetsWithdrawn, sharesWithdrawn) = morpho.withdraw(marketParams, amount, supplyShares, onBehalf, receiver);
}

/// @notice Handles the withdrawal of a specified amount of assets by the caller from a specific market. If the
/// amount is greater than the total amount supplied by the user, withdraws all the shares of the user.
/// @param marketParams The parameters of the market.
/// @param amount The amount of assets the user is withdrawing.
/// @return assetsWithdrawn The actual amount of assets withdrawn.
/// @return sharesWithdrawn The shares withdrawn in return for the assets.
function withdrawAmountOrAll(MarketParams memory marketParams, uint256 amount)
    external
    returns (uint256 assetsWithdrawn, uint256 sharesWithdrawn)
{
    Id id = marketParams.id();

    address onBehalf = msg.sender;
    address receiver = msg.sender;

    morpho.accrueInterest(marketParams);
    uint256 totalSupplyAssets = morpho.totalSupplyAssets(id);
    uint256 totalSupplyShares = morpho.totalSupplyShares(id);
    uint256 shares = morpho.supplyShares(id, msg.sender);

    uint256 assetsMax = shares.toAssetsDown(totalSupplyAssets, totalSupplyShares);

    if (amount >= assetsMax) {
        (assetsWithdrawn, sharesWithdrawn) = morpho.withdraw(marketParams, 0, shares, onBehalf, receiver);
    } else {
        (assetsWithdrawn, sharesWithdrawn) = morpho.withdraw(marketParams, amount, 0, onBehalf, receiver);
    }
}
```

## Repayment Strategies

Similarly, the contract provides flexible approaches to debt repayment:

```solidity
/// @notice Handles the repayment of a specified amount of assets by the caller to a specific market.
/// @param marketParams The parameters of the market.
/// @param amount The amount of assets the user is repaying.
/// @return assetsRepaid The actual amount of assets repaid.
/// @return sharesRepaid The shares repaid in return for the assets.
function repayAmount(MarketParams memory marketParams, uint256 amount)
    external
    returns (uint256 assetsRepaid, uint256 sharesRepaid)
{
    ERC20(marketParams.loanToken).forceApprove(address(morpho), type(uint256).max);
    ERC20(marketParams.loanToken).safeTransferFrom(msg.sender, address(this), amount);

    uint256 shares;
    address onBehalf = msg.sender;
    (assetsRepaid, sharesRepaid) = morpho.repay(marketParams, amount, shares, onBehalf, hex"");
}

/// @notice Handles the repayment of 50% of the borrowed assets by the caller to a specific market.
/// @param marketParams The parameters of the market.
/// @return assetsRepaid The actual amount of assets repaid.
/// @return sharesRepaid The shares repaid in return for the assets.
function repay50Percent(MarketParams memory marketParams)
    external
    returns (uint256 assetsRepaid, uint256 sharesRepaid)
{
    ERC20(marketParams.loanToken).forceApprove(address(morpho), type(uint256).max);

    Id marketId = marketParams.id();

    (,, uint256 totalBorrowAssets, uint256 totalBorrowShares) = morpho.expectedMarketBalances(marketParams);
    uint256 borrowShares = morpho.position(marketId, msg.sender).borrowShares;

    uint256 repaidAmount = (borrowShares / 2).toAssetsUp(totalBorrowAssets, totalBorrowShares);
    ERC20(marketParams.loanToken).safeTransferFrom(msg.sender, address(this), repaidAmount);

    uint256 amount;
    address onBehalf = msg.sender;

    (assetsRepaid, sharesRepaid) = morpho.repay(marketParams, amount, borrowShares / 2, onBehalf, hex"");
}

/// @notice Handles the repayment of all the borrowed assets by the caller to a specific market.
/// @param marketParams The parameters of the market.
/// @return assetsRepaid The actual amount of assets repaid.
/// @return sharesRepaid The shares repaid in return for the assets.
function repayAll(MarketParams memory marketParams) external returns (uint256 assetsRepaid, uint256 sharesRepaid) {
    ERC20(marketParams.loanToken).forceApprove(address(morpho), type(uint256).max);

    Id marketId = marketParams.id();

    (,, uint256 totalBorrowAssets, uint256 totalBorrowShares) = morpho.expectedMarketBalances(marketParams);
    uint256 borrowShares = morpho.position(marketId, msg.sender).borrowShares;

    uint256 repaidAmount = borrowShares.toAssetsUp(totalBorrowAssets, totalBorrowShares);
    ERC20(marketParams.loanToken).safeTransferFrom(msg.sender, address(this), repaidAmount);

    uint256 amount;
    address onBehalf = msg.sender;
    (assetsRepaid, sharesRepaid) = morpho.repay(marketParams, amount, borrowShares, onBehalf, hex"");
}

/// @notice Handles the repayment of a specified amount of assets by the caller to a specific market. If the amount
/// is greater than the total amount borrowed by the user, repays all the shares of the user.
/// @param marketParams The parameters of the market.
/// @param amount The amount of assets the user is repaying.
/// @return assetsRepaid The actual amount of assets repaid.
/// @return sharesRepaid The shares repaid in return for the assets.
function repayAmountOrAll(MarketParams memory marketParams, uint256 amount)
    external
    returns (uint256 assetsRepaid, uint256 sharesRepaid)
{
    ERC20(marketParams.loanToken).forceApprove(address(morpho), type(uint256).max);

    Id id = marketParams.id();

    address onBehalf = msg.sender;

    morpho.accrueInterest(marketParams);
    uint256 totalBorrowAssets = morpho.totalBorrowAssets(id);
    uint256 totalBorrowShares = morpho.totalBorrowShares(id);
    uint256 shares = morpho.borrowShares(id, msg.sender);
    uint256 assetsMax = shares.toAssetsUp(totalBorrowAssets, totalBorrowShares);

    if (amount >= assetsMax) {
        ERC20(marketParams.loanToken).safeTransferFrom(msg.sender, address(this), assetsMax);
        (assetsRepaid, sharesRepaid) = morpho.repay(marketParams, 0, shares, onBehalf, hex"");
    } else {
        ERC20(marketParams.loanToken).safeTransferFrom(msg.sender, address(this), amount);
        (assetsRepaid, sharesRepaid) = morpho.repay(marketParams, amount, 0, onBehalf, hex"");
    }
}
```

## Interest Accrual and Share Management

Critical aspects of managing user positions involve proper interest accrual and conversion between shares and assets:

```solidity
// Always accrue interest before calculating current balances
function getCurrentPosition(MarketParams memory marketParams, address user) external returns (uint256 supply, uint256 borrow, uint256 collateral) {
    Id id = marketParams.id();
    
    // Ensure interest is accrued for accurate calculations
    morpho.accrueInterest(marketParams);
    
    // Get updated positions
    supply = morpho.supplyShares(id, user).toAssetsDown(
        morpho.totalSupplyAssets(id),
        morpho.totalSupplyShares(id)
    );
    
    borrow = morpho.borrowShares(id, user).toAssetsUp(
        morpho.totalBorrowAssets(id),
        morpho.totalBorrowShares(id)
    );
    
    collateral = morpho.collateral(id, user);
}

// Share to asset conversion patterns
function sharesManagement() internal {
    // Convert supply shares to assets (round down in favor of protocol)
    uint256 supplyAssets = supplyShares.toAssetsDown(totalSupplyAssets, totalSupplyShares);
    
    // Convert borrow shares to assets (round up in favor of protocol)
    uint256 borrowAssets = borrowShares.toAssetsUp(totalBorrowAssets, totalBorrowShares);
    
    // Convert desired assets to minimum shares needed (round up for supplying)
    uint256 sharesToSupply = assetsDesired.toSharesUp(totalSupplyAssets, totalSupplyShares);
    
    // Convert desired assets to maximum shares allowed (round down for borrowing)
    uint256 sharesToBorrow = assetsDesired.toSharesDown(totalBorrowAssets, totalBorrowShares);
}

// Efficient asset transfer and approval
function tokenHandling(address token, uint256 amount, address recipient) internal {
    // Approve token for Morpho contract
    ERC20(token).forceApprove(address(morpho), type(uint256).max);
    
    // Transfer from user to this contract
    ERC20(token).safeTransferFrom(msg.sender, address(this), amount);
    
    // Transfer to recipient
    ERC20(token).transfer(recipient, amount);
}
```

## Best Practices

When implementing position management with Morpho:

1. **Always accrue interest before critical operations**
   - Use `morpho.accrueInterest(marketParams)` before calculating position values
   - Apply this before withdrawing, repaying, or calculating health factors

2. **Use appropriate rounding for shares/assets conversion**
   - `.toAssetsDown()` when converting supply shares (favors protocol)
   - `.toAssetsUp()` when converting borrow shares (favors protocol)
   - `.toSharesUp()` when calculating supply shares from assets (user puts in more)
   - `.toSharesDown()` when calculating borrow shares from assets (user gets less)

3. **Handle token approvals properly**
   - Use `forceApprove` or `safeIncreaseAllowance` to avoid approval race conditions
   - Consider using infinite approvals for frequent operations to save gas

4. **Implement "OrAll" pattern for flexible user experience**
   - Calculate maximum available amounts before operations
   - Provide fallback cases to handle edge cases gracefully

5. **Return both assets and shares for clarity**
   - Methods should return both the assets and shares involved in an operation
   - This helps with accurate accounting and transparency