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