# Deleveraging in Morpho Blue

This document explains the concept of deleveraging in Morpho Blue and provides implementation details from our MinimalistPerps system.

## Overview

Deleveraging is the process of reducing a leveraged position's exposure by repaying debt and withdrawing collateral. In Morpho Blue, this involves:

1. Repaying the borrowed assets (loan token)
2. Withdrawing the supplied collateral
3. Optionally, swapping a portion of the collateral to repay the loan

The process effectively reverses a leveraged position, allowing a user to exit their position efficiently.

## Implementation

Our implementation uses Morpho's callback system to create a clean, gas-efficient deleveraging operation. Here's how it works:

```solidity
function deLeverageMe(MarketParams calldata marketParams) public returns (uint256 amountRepaid) {
    uint256 totalShares = morpho.borrowShares(marketParams.id(), msg.sender);

    _approveMaxTo(marketParams.loanToken, address(morpho));

    (amountRepaid,) =
        morpho.repay(marketParams, 0, totalShares, msg.sender, abi.encode(RepayData(marketParams, msg.sender)));

    ERC20(marketParams.collateralToken).safeTransfer(
        msg.sender, ERC20(marketParams.collateralToken).balanceOf(address(this))
    );
}
```

This function:
1. Retrieves the user's total borrow shares for the specific market
2. Approves Morpho to use the loan token
3. Repays the debt using the `repay` function, passing callback data for additional actions
4. Transfers any remaining collateral back to the user

## Callback Mechanism

The deleveraging process uses Morpho's repay callback system. When `morpho.repay()` is called, it triggers the `onMorphoRepay` callback:

```solidity
function onMorphoRepay(uint256 amount, bytes calldata data) external onlyMorpho {
    RepayData memory decoded = abi.decode(data, (RepayData));
    uint256 toWithdraw = morpho.collateral(decoded.marketParams.id(), decoded.user);

    morpho.withdrawCollateral(decoded.marketParams, toWithdraw, decoded.user, address(this));

    ERC20(decoded.marketParams.collateralToken).approve(address(swapper), amount);
    swapper.swapCollatToLoan(amount);
}
```

This callback:
1. Decodes the callback data to get market parameters and user address
2. Retrieves the user's collateral amount 
3. Withdraws the collateral on behalf of the user
4. Approves the swapper contract to use the collateral
5. Swaps the necessary amount of collateral to loan token to cover the repayment

## The Deleveraging Process Step by Step

1. **User Initiates Deleveraging**: The user calls `deLeverageMe()` with the appropriate market parameters.

2. **Repayment Begins**: The contract repays the user's debt by calling `morpho.repay()`, which triggers the callback.

3. **Callback Processing**:
   - The callback withdraws all of the user's collateral
   - It swaps the necessary amount of collateral to the loan token to cover the debt
   
4. **Position Closure**: The collateral is withdrawn and any remaining balance is returned to the user.

5. **Final State**: The user's leveraged position is closed, with all debt repaid and collateral recovered (minus any swap fees).

## Implementation Notes

### Data Structures

```solidity
struct RepayData {
    MarketParams marketParams;
    address user;
}
```

This structure encapsulates the data needed during the repay callback.

### Security Considerations

1. **Callback Authentication**: 
   ```solidity
   modifier onlyMorpho() {
       require(msg.sender == address(morpho), "msg.sender should be Morpho Blue");
       _;
   }
   ```
   This ensures only the Morpho contract can trigger callbacks.

2. **Token Approvals**: The helper function ensures tokens are properly approved:
   ```solidity
   function _approveMaxTo(address asset, address spender) internal {
       if (ERC20(asset).allowance(address(this), spender) == 0) {
           ERC20(asset).safeApprove(spender, type(uint256).max);
       }
   }
   ```

### Swap Mechanism

The `swapper` in this implementation is a placeholder for any token swapping service. In a production environment, you would integrate with your preferred DEX or liquidity source.

```solidity
swapper.swapCollatToLoan(amount);
```

When implementing a swap service, carefully consider:
1. Slippage protection
2. Price impact
3. Transaction fees
4. Oracle reliability

## Example Use Case

Consider a user who created a 5x leveraged ETH-USDC position:
- Initial collateral: 10 ETH
- Borrowed: 40 ETH worth of USDC
- Total position: 50 ETH worth of exposure

To deleverage this position, the user would call:

```solidity
// Initialize contract with Morpho and Swap addresses
LeverageDeleverageSnippets deleverager = new LeverageDeleverageSnippets(morphoAddress, swapperAddress);

// Approve the contract to manage positions
morpho.setAuthorization(address(deleverager), true);

// Define market parameters
MarketParams memory marketParams = MarketParams({
    loanToken: USDC_ADDRESS,
    collateralToken: WETH_ADDRESS,
    oracle: ORACLE_ADDRESS,
    irm: IRM_ADDRESS,
    lltv: LLTV_VALUE
});

// Deleverage the position
uint256 amountRepaid = deleverager.deLeverageMe(marketParams);
```

After this operation:
1. The borrowed USDC is fully repaid
2. All ETH collateral is withdrawn and returned to the user
3. The leveraged position is completely closed

## Integration with MinimalistPerps

In our MinimalistPerps system, deleveraging is a key component for:
1. Closing positions
2. Reducing position size
3. Managing risk during volatility

The implementation allows for efficient position management and capital utilization through Morpho Blue's callback system.

## Simplified Deleveraging with MorphoBlueSnippets

While the callback approach provides an atomic, gas-efficient way to deleverage, the MorphoBlueSnippets contract offers simpler, more flexible functions for deleveraging that can be used when callbacks aren't necessary:

### Complete Position Closure

```solidity
/// @notice Repays all borrowed assets and withdraws all collateral to close a position.
/// @param marketParams The parameters of the market.
/// @return assetsRepaid The amount of assets repaid.
/// @return sharesRepaid The amount of shares repaid.
function closePosition(MarketParams memory marketParams) external returns (uint256 assetsRepaid, uint256 sharesRepaid) {
    // Step 1: Repay all borrowed assets
    (assetsRepaid, sharesRepaid) = repayAll(marketParams);
    
    // Step 2: Withdraw all collateral after repayment
    Id marketId = marketParams.id();
    uint256 collateralAmount = morpho.collateral(marketId, msg.sender);
    
    if (collateralAmount > 0) {
        morpho.withdrawCollateral(marketParams, collateralAmount, msg.sender, msg.sender);
    }
}
```

This function demonstrates how to fully close a position by:
1. First repaying all borrowed assets using `repayAll`
2. Then withdrawing all collateral using `withdrawCollateral`

### Gradual Deleveraging

The MorphoBlueSnippets provides functions for partial repayment that enable gradual deleveraging:

```solidity
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
```

This function repays exactly 50% of the position, enabling a more controlled deleveraging process.

### Smart Deleveraging to Target Health Factor

```solidity
/// @notice Repays just enough of a position to reach a target health factor.
/// @param marketParams The parameters of the market.
/// @param targetHealthFactor The health factor to target (scaled by WAD).
/// @return assetsRepaid The amount of assets repaid to reach the target health factor.
function deleverageToHealthFactor(
    MarketParams memory marketParams,
    uint256 targetHealthFactor
) external returns (uint256 assetsRepaid) {
    Id id = marketParams.id();
    address user = msg.sender;
    
    // Get current health factor
    uint256 currentHealthFactor = userHealthFactor(marketParams, id, user);
    
    // If health factor is already above target, no need to repay
    if (currentHealthFactor >= targetHealthFactor) return 0;
    
    // Get current borrow balance
    uint256 borrowed = borrowAssetsUser(marketParams, user);
    
    // Get collateral value in loan token units
    uint256 collateralPrice = IOracle(marketParams.oracle).price();
    uint256 collateral = morpho.collateral(id, user);
    uint256 collateralValue = collateral.mulDivDown(collateralPrice, ORACLE_PRICE_SCALE).wMulDown(marketParams.lltv);
    
    // Calculate how much to repay to reach target health factor
    // targetHF = collateralValue / (borrowed - repayAmount)
    // repayAmount = borrowed - (collateralValue / targetHF)
    uint256 repayAmount = borrowed - collateralValue.wDivDown(targetHealthFactor);
    
    // Execute repayment
    (assetsRepaid, ) = repayAmount(marketParams, repayAmount);
    
    return assetsRepaid;
}
```

This function intelligently calculates exactly how much to repay to reach a specific health factor, enabling precise risk management when deleveraging.

## Position Monitoring During Deleveraging

MorphoBlueSnippets provides several functions that are critical for monitoring positions during the deleveraging process:

### Health Factor Calculation

```solidity
/// @notice Calculates the health factor of a user in a specific market.
/// @param marketParams The parameters of the market.
/// @param id The identifier of the market.
/// @param user The address of the user whose health factor is being calculated.
/// @return healthFactor The calculated health factor.
function userHealthFactor(MarketParams memory marketParams, Id id, address user)
    public
    view
    returns (uint256 healthFactor)
{
    uint256 collateralPrice = IOracle(marketParams.oracle).price();
    uint256 collateral = morpho.collateral(id, user);
    uint256 borrowed = morpho.expectedBorrowAssets(marketParams, user);

    uint256 maxBorrow = collateral.mulDivDown(collateralPrice, ORACLE_PRICE_SCALE).wMulDown(marketParams.lltv);

    if (borrowed == 0) return type(uint256).max;
    healthFactor = maxBorrow.wDivDown(borrowed);
}
```

This function tracks the health factor, which will increase as you deleverage. It can be used to verify the effectiveness of your deleveraging steps.

### Efficient Position Balance Monitoring

```solidity
/// @notice Calculates the total collateral balance of a given user in a specific market.
/// @dev It uses extSloads to load only one storage slot of the Position struct and save gas.
/// @param marketId The identifier of the market.
/// @param user The address of the user whose collateral balance is being calculated.
/// @return totalCollateralAssets The calculated total collateral balance.
function collateralAssetsUser(Id marketId, address user) public view returns (uint256 totalCollateralAssets) {
    bytes32[] memory slots = new bytes32[](1);
    slots[0] = MorphoStorageLib.positionBorrowSharesAndCollateralSlot(marketId, user);
    bytes32[] memory values = morpho.extSloads(slots);
    totalCollateralAssets = uint256(values[0] >> 128);
}

/// @notice Calculates the total borrow balance of a given user in a specific market.
/// @param marketParams The parameters of the market.
/// @param user The address of the user whose borrow balance is being calculated.
/// @return totalBorrowAssets The calculated total borrow balance.
function borrowAssetsUser(MarketParams memory marketParams, address user)
    public
    view
    returns (uint256 totalBorrowAssets)
{
    totalBorrowAssets = morpho.expectedBorrowAssets(marketParams, user);
}
```

These functions provide gas-efficient ways to track position components during deleveraging, which is particularly useful for monitoring the process of large or complex positions.

## Implementing a Complete Deleveraging Strategy

For optimal deleveraging, consider implementing the following strategy using MorphoBlueSnippets:

1. **Position Assessment**:
   - Use `userHealthFactor` to check current position health
   - Use `borrowAssetsUser` and `collateralAssetsUser` to determine position size
   - Determine deleveraging strategy based on position health and market conditions

2. **Gradual Deleveraging in Volatile Markets**:
   - Start with `repay50Percent` to reduce half the position
   - Assess the effect using `userHealthFactor`
   - Continue with smaller repayments as needed using `repayAmount`
   - After each repayment, withdraw proportional collateral

3. **Targeted Deleveraging for Risk Management**:
   - Use `deleverageToHealthFactor` to achieve a specific risk profile
   - Maintain health factor above 2.0 during adverse market conditions

4. **Complete Exit in Favorable Markets**:
   - Use `repayAll` followed by full collateral withdrawal
   - Alternatively, use combined `closePosition` function

5. **Post-Deleveraging Verification**:
   - Verify zero borrow balance using `borrowAssetsUser`
   - Confirm all collateral withdrawn
   - Check for any remaining unclaimed rewards or fees

By following these steps and utilizing the efficient MorphoBlueSnippets functions, you can implement a robust deleveraging strategy that protects positions during market volatility while minimizing gas costs and slippage. 