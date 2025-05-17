# Leveraging in Morpho Blue

This document explains how to create leveraged positions in Morpho Blue and provides implementation details from our MinimalistPerps system.

## Overview

Leveraging allows users to amplify their exposure to an asset by borrowing funds to increase their position size. In Morpho Blue, this is achieved through:

1. Supplying initial collateral
2. Borrowing loan tokens against that collateral
3. Converting the borrowed tokens back to collateral
4. Iterating the process to achieve the desired leverage

The result is a larger position with the same initial capital, amplifying both potential gains and risks.

## Implementation

Our implementation uses Morpho's callback system to efficiently create leveraged positions in a single transaction:

```solidity
function leverageMe(uint256 leverageFactor, uint256 initAmountCollateral, MarketParams calldata marketParams)
    public
{
    // Transfer the initial collateral from the sender to this contract.
    ERC20(marketParams.collateralToken).safeTransferFrom(msg.sender, address(this), initAmountCollateral);

    // Calculate the final amount of collateral based on the leverage factor.
    uint256 finalAmountCollateral = initAmountCollateral * leverageFactor;

    // Calculate the amount of LoanToken to be borrowed and swapped against CollateralToken.
    uint256 loanAmount = (leverageFactor - 1) * initAmountCollateral;

    // Approve the maximum amount to Morpho on behalf of the collateral token.
    _approveMaxTo(marketParams.collateralToken, address(morpho));

    // Supply the collateral to Morpho, initiating the leverage operation.
    morpho.supplyCollateral(
        marketParams,
        finalAmountCollateral,
        msg.sender,
        abi.encode(SupplyCollateralData(loanAmount, marketParams, msg.sender))
    );
}
```

This function:
1. Transfers the user's initial collateral to the contract
2. Calculates the final collateral amount based on the leverage factor
3. Determines how much to borrow to achieve the desired leverage
4. Approves Morpho to use the collateral token
5. Supplies collateral to Morpho, passing callback data for additional actions

## Callback Mechanism

The leveraging process relies on Morpho's supply collateral callback system. When `morpho.supplyCollateral()` is called, it triggers the `onMorphoSupplyCollateral` callback:

```solidity
function onMorphoSupplyCollateral(uint256 amount, bytes calldata data) external onlyMorpho {
    SupplyCollateralData memory decoded = abi.decode(data, (SupplyCollateralData));
    (uint256 amountBis,) = morpho.borrow(decoded.marketParams, decoded.loanAmount, 0, decoded.user, address(this));

    ERC20(decoded.marketParams.loanToken).approve(address(swapper), amount);

    // Logic to Implement. Following example is a swap, could be a 'unwrap + stake + wrap staked' for
    // wETH(wstETH) Market.
    swapper.swapLoanToCollat(amountBis);
}
```

This callback:
1. Decodes the callback data to get parameters like loan amount, market info, and user address
2. Borrows the specified amount of loan tokens on behalf of the user
3. Approves the swapper contract to use the loan tokens
4. Swaps the borrowed tokens back to collateral (increasing the user's position size)

## The Leveraging Process Step by Step

1. **User Initiates Leveraging**: The user calls `leverageMe()` with the desired leverage factor, initial collateral amount, and market parameters.

2. **Initial Collateral Supply**: The contract supplies the collateral to Morpho, which triggers the callback.

3. **Callback Processing**:
   - The callback borrows loan tokens against the supplied collateral
   - It swaps the borrowed tokens back to collateral
   - The additional collateral effectively increases the user's position size
   
4. **Final Position**: The user now has a leveraged position with:
   - Collateral amount = initial collateral × leverage factor
   - Borrowed amount = (leverage factor - 1) × initial collateral

## Implementation Notes

### Data Structures

```solidity
struct SupplyCollateralData {
    uint256 loanAmount;
    MarketParams marketParams;
    address user;
}
```

This structure encapsulates the data needed during the supply collateral callback.

### Price Considerations

The code includes an important note about price calculation:

```solidity
// Note: In this simplified example, the price is assumed to be `ORACLE_PRICE_SCALE`.
// In a real-world scenario:
// - The price might not equal `ORACLE_PRICE_SCALE`, and the oracle's price should be factored into the
// calculation, like this:
// (leverageFactor - 1) * initAmountCollateral.mulDivDown(ORACLE_PRICE_SCALE, IOracle(oracle).price())
// - Consideration for fees and slippage is crucial to accurately compute `loanAmount`.
```

In production:
1. Always use the oracle price to correctly calculate loan amounts
2. Account for slippage in swap operations
3. Include a buffer for market fluctuations
4. Consider fees when calculating final position sizes

### Swap Mechanism

The `swapper` in this implementation is a placeholder:

```solidity
swapper.swapLoanToCollat(amountBis);
```

When implementing your own swap service, consider:
1. Slippage protection
2. Price impact
3. Transaction fees
4. MEV protection

## Example Use Case

Consider a user who wants to create a 5x leveraged ETH position using USDC as the loan token:
- Initial collateral: 10 ETH
- Desired leverage: 5×
- Final position size: 50 ETH
- Borrowed value: 40 ETH worth of USDC

The user would call:

```solidity
// Initialize contract with Morpho and Swap addresses
LeverageDeleverageSnippets leverager = new LeverageDeleverageSnippets(morphoAddress, swapperAddress);

// Define market parameters
MarketParams memory marketParams = MarketParams({
    loanToken: USDC_ADDRESS,
    collateralToken: WETH_ADDRESS,
    oracle: ORACLE_ADDRESS,
    irm: IRM_ADDRESS,
    lltv: LLTV_VALUE
});

// Approve the contract to use initial collateral
WETH.approve(address(leverager), 10 ether);

// Create the leveraged position
leverager.leverageMe(5, 10 ether, marketParams);
```

After this operation:
1. The user has 50 ETH of collateral on Morpho
2. The user has borrowed 40 ETH worth of USDC
3. The position is 5× leveraged

## Limitations and Risks

1. **Maximum Leverage**: The leverage factor cannot exceed `1/(1-LLTV)`. For example, with an LLTV of 80%, maximum leverage is 5×.

2. **Liquidation Risk**: Higher leverage means higher liquidation risk during market downturns.

3. **Oracle Dependence**: The system relies on accurate oracle prices.

4. **Swap Efficiency**: Inefficient swaps can result in worse-than-expected leverage outcomes.

## Integration with MinimalistPerps

In our MinimalistPerps system, leveraging is a fundamental component that enables:
1. Amplified exposure to market movements
2. Capital efficiency for traders
3. Flexible position sizing with limited upfront capital

The implementation showcases how Morpho Blue's callback system enables complex financial operations in a gas-efficient, single-transaction process. 