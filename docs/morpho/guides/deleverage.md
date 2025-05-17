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