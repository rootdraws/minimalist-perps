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

## Position Monitoring and Risk Management

Leveraged positions require active monitoring and management due to their increased risk profile. The MorphoBlueSnippets contract provides essential utilities for monitoring leveraged positions:

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

This function:
1. Gets the current oracle price for the collateral
2. Retrieves the user's collateral and borrow balances
3. Calculates the maximum borrowing capacity
4. Returns the health factor as the ratio of max borrow capacity to current borrowed amount

A health factor below 1.0 means the position is eligible for liquidation, so it's crucial to maintain a buffer above this threshold.

### Efficient Position Balance Monitoring

MorphoBlueSnippets provides gas-efficient methods to track position components:

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

The `collateralAssetsUser` function is particularly efficient as it uses `extSloads` to directly access storage slots rather than making more expensive function calls.

### Managing Leveraged Positions

When managing leveraged positions, you can use the following functions from MorphoBlueSnippets:

#### Adding More Collateral to Improve Health Factor

```solidity
function supplyCollateral(MarketParams memory marketParams, uint256 amount) external {
    ERC20(marketParams.collateralToken).forceApprove(address(morpho), type(uint256).max);
    ERC20(marketParams.collateralToken).safeTransferFrom(msg.sender, address(this), amount);

    address onBehalf = msg.sender;

    morpho.supplyCollateral(marketParams, amount, onBehalf, hex"");
}
```

#### Reducing Leverage by Partially Repaying Debt

```solidity
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

#### Customized Repayment to Target a Specific Health Factor

```solidity
function repayToTargetHealthFactor(
    MarketParams memory marketParams,
    address user,
    uint256 targetHealthFactor
) external returns (uint256 repaidAssets) {
    Id id = marketParams.id();
    
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
    (repaidAssets, ) = repayAmount(marketParams, repayAmount);
    
    return repaidAssets;
}
```

### Market Analysis for Leveraged Positions

MorphoBlueSnippets provides functions to analyze market conditions, which is crucial for leveraged positions:

```solidity
/// @notice Calculates the total supply of assets in a specific market.
/// @param marketParams The parameters of the market.
/// @return totalSupplyAssets The calculated total supply of assets.
function marketTotalSupply(MarketParams memory marketParams) public view returns (uint256 totalSupplyAssets) {
    totalSupplyAssets = morpho.expectedTotalSupplyAssets(marketParams);
}

/// @notice Calculates the total borrow of assets in a specific market.
/// @param marketParams The parameters of the market.
/// @return totalBorrowAssets The calculated total borrow of assets.
function marketTotalBorrow(MarketParams memory marketParams) public view returns (uint256 totalBorrowAssets) {
    totalBorrowAssets = morpho.expectedTotalBorrowAssets(marketParams);
}

/// @notice Calculates the borrow APY (Annual Percentage Yield) for a given market.
/// @param marketParams The parameters of the market.
/// @param market The state of the market.
/// @return borrowApy The calculated borrow APY (scaled by WAD).
function borrowAPY(MarketParams memory marketParams, Market memory market)
    public
    view
    returns (uint256 borrowApy)
{
    if (marketParams.irm != address(0)) {
        borrowApy = IIrm(marketParams.irm).borrowRateView(marketParams, market).wTaylorCompounded(365 days);
    }
}
```

Monitoring these metrics helps users make informed decisions about when to leverage, deleverage, or adjust their positions.

## Complete Leverage Management Strategy

For optimal management of leveraged positions, implement the following strategy:

1. **Creation**: Use the leveraging callback mechanism to create the position efficiently
2. **Monitoring**: 
   - Track health factor regularly using `userHealthFactor`
   - Monitor borrow APY to anticipate interest costs
   - Track collateral and borrow balances with the specialized functions

3. **Risk Management**:
   - Maintain a minimum health factor buffer (recommended: >1.5)
   - Implement automatic health factor maintenance by:
     - Adding collateral when health factor drops too low
     - Partially repaying debt during market volatility

4. **Exit Strategy**:
   - Deleverage gradually using partial repayments
   - Monitor slippage during exit to optimize outcomes
   - Consider repaying fully during favorable market conditions

A complete implementation would integrate position creation, monitoring, and management functions into a unified interface that provides a comprehensive view of the user's leveraged positions along with risk indicators and management options. 