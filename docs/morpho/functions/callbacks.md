# Callback System in Morpho

## Overview

Morpho's callback system enables atomic operations and composable DeFi integrations. Callbacks allow external contracts to execute custom logic during key operations, creating powerful possibilities for leverage, position management, and multi-step transactions.

## Core Callback Interfaces

Morpho implements five distinct callback types, each corresponding to a specific protocol operation:

```solidity
interface IMorphoSupplyCallback {
    function onMorphoSupply(uint256 assets, bytes calldata data) external;
}

interface IMorphoRepayCallback {
    function onMorphoRepay(uint256 assets, bytes calldata data) external;
}

interface IMorphoSupplyCollateralCallback {
    function onMorphoSupplyCollateral(uint256 assets, bytes calldata data) external;
}

interface IMorphoLiquidateCallback {
    function onMorphoLiquidate(uint256 repaidAssets, bytes calldata data) external;
}

interface IMorphoFlashLoanCallback {
    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external;
}
```

## Callback Execution Flow

The general pattern for Morpho callbacks follows these steps:

1. The user calls a Morpho function that supports callbacks (e.g., `supply`, `repay`)
2. The user provides optional `data` for the callback
3. Morpho executes its standard logic for the operation
4. If callback data is provided, Morpho calls the appropriate callback function on the caller's contract
5. After the callback completes, Morpho finalizes the operation (typically by transferring tokens)

This pattern allows users to execute complex operations within a single transaction.

## Supply Callback

```solidity
function supply(
    MarketParams memory marketParams,
    uint256 assets,
    uint256 shares,
    address onBehalf,
    bytes calldata data
) external returns (uint256, uint256) {
    // ... standard supply logic ...
    
    emit EventsLib.Supply(id, msg.sender, onBehalf, assets, shares);

    if (data.length > 0) IMorphoSupplyCallback(msg.sender).onMorphoSupply(assets, data);

    IERC20(marketParams.loanToken).safeTransferFrom(msg.sender, address(this), assets);

    return (assets, shares);
}
```

The supply callback is executed after Morpho updates internal state but before tokens are transferred from the caller. This allows implementations to source the required tokens within the same transaction.

### Supply Callback Use Cases

1. **Just-in-time liquidity**: Swap another asset for the required supply token
2. **Multi-asset supplying**: Supply multiple assets in one transaction
3. **Recursive leveraging**: Create self-reinforcing positions

## Repay Callback

```solidity
function repay(
    MarketParams memory marketParams,
    uint256 assets,
    uint256 shares,
    address onBehalf,
    bytes calldata data
) external returns (uint256, uint256) {
    // ... standard repay logic ...
    
    emit EventsLib.Repay(id, msg.sender, onBehalf, assets, shares);

    if (data.length > 0) IMorphoRepayCallback(msg.sender).onMorphoRepay(assets, data);

    IERC20(marketParams.loanToken).safeTransferFrom(msg.sender, address(this), assets);

    return (assets, shares);
}
```

Like the supply callback, the repay callback is executed before token transfer, allowing the caller to source repayment funds dynamically.

### Repay Callback Use Cases

1. **Debt refinancing**: Borrow from another protocol to repay Morpho debt
2. **Collateral-to-repayment conversion**: Sell collateral to repay debt
3. **Automated debt management**: Repay based on custom rules or thresholds

## Supply Collateral Callback

```solidity
function supplyCollateral(
    MarketParams memory marketParams,
    uint256 assets,
    address onBehalf,
    bytes calldata data
) external {
    // ... standard supply collateral logic ...
    
    emit EventsLib.SupplyCollateral(id, msg.sender, onBehalf, assets);

    if (data.length > 0) IMorphoSupplyCollateralCallback(msg.sender).onMorphoSupplyCollateral(assets, data);

    IERC20(marketParams.collateralToken).safeTransferFrom(msg.sender, address(this), assets);
}
```

The supply collateral callback enables dynamic collateral sourcing and management.

### Supply Collateral Callback Use Cases

1. **Asset conversion**: Convert assets to appropriate collateral tokens
2. **Collateral optimization**: Choose optimal collateral based on market conditions
3. **Cross-protocol integration**: Withdraw assets from other protocols to use as collateral

## Liquidate Callback

```solidity
function liquidate(
    MarketParams memory marketParams,
    address borrower,
    uint256 seizedAssets,
    uint256 repaidShares,
    bytes calldata data
) external returns (uint256, uint256) {
    // ... standard liquidation logic ...
    
    IERC20(marketParams.collateralToken).safeTransfer(msg.sender, seizedAssets);

    if (data.length > 0) IMorphoLiquidateCallback(msg.sender).onMorphoLiquidate(repaidAssets, data);

    IERC20(marketParams.loanToken).safeTransferFrom(msg.sender, address(this), repaidAssets);

    return (seizedAssets, repaidAssets);
}
```

The liquidate callback is unique because it's called after the liquidator receives seized collateral but before they need to pay the repaid assets.

### Liquidate Callback Use Cases

1. **Immediate collateral selling**: Sell seized collateral to cover repayment
2. **Liquidation cascades**: Use seized collateral to liquidate other positions
3. **Arbitrage integration**: Execute arb strategies with seized collateral

## Flash Loan Callback

```solidity
function flashLoan(address token, uint256 assets, bytes calldata data) external {
    require(assets != 0, ErrorsLib.ZERO_ASSETS);

    emit EventsLib.FlashLoan(msg.sender, token, assets);

    IERC20(token).safeTransfer(msg.sender, assets);

    IMorphoFlashLoanCallback(msg.sender).onMorphoFlashLoan(assets, data);

    IERC20(token).safeTransferFrom(msg.sender, address(this), assets);
}
```

Flash loans in Morpho follow the standard pattern: tokens are transferred to the borrower, a callback is executed, and then tokens must be returned to the protocol.

### Flash Loan Callback Use Cases

1. **Arbitrage**: Execute cross-platform arbitrage opportunities
2. **Collateral swapping**: Replace one collateral type with another
3. **Self-liquidation**: Liquidate your own positions to avoid liquidation penalties
4. **Complex position management**: Restructure positions across multiple protocols

## Implementation Examples

### Basic Leverage Strategy

```solidity
// Simple leverage strategy using supply collateral callback
contract LeverageStrategy is IMorphoSupplyCollateralCallback {
    Morpho public immutable morpho;
    
    constructor(address _morpho) {
        morpho = Morpho(_morpho);
    }
    
    function executeMultiLeverage(
        MarketParams memory marketParams,
        uint256 initialCollateral,
        uint8 leverageIterations
    ) external {
        // Initial collateral supply
        IERC20(marketParams.collateralToken).transferFrom(msg.sender, address(this), initialCollateral);
        IERC20(marketParams.collateralToken).approve(address(morpho), initialCollateral);
        
        bytes memory callbackData = abi.encode(
            marketParams,
            msg.sender,
            leverageIterations
        );
        
        morpho.supplyCollateral(
            marketParams,
            initialCollateral,
            msg.sender,
            callbackData
        );
    }
    
    function onMorphoSupplyCollateral(uint256 assets, bytes calldata data) external override {
        require(msg.sender == address(morpho), "Unauthorized");
        
        (
            MarketParams memory marketParams,
            address user,
            uint8 iterations
        ) = abi.decode(data, (MarketParams, address, uint8));
        
        if (iterations == 0) return;
        
        // Calculate borrowable amount based on supplied collateral
        uint256 borrowAmount = _calculateSafeBorrowAmount(marketParams, user, assets);
        
        // Borrow assets
        morpho.borrow(marketParams, borrowAmount, 0, user, address(this));
        
        // Approve borrowed assets as collateral
        IERC20(marketParams.loanToken).approve(address(morpho), borrowAmount);
        
        // Recursively leverage with one fewer iteration
        bytes memory newCallbackData = abi.encode(
            marketParams,
            user,
            iterations - 1
        );
        
        morpho.supplyCollateral(
            marketParams,
            borrowAmount,
            user,
            newCallbackData
        );
    }
    
    function _calculateSafeBorrowAmount(MarketParams memory marketParams, address user, uint256 assets)
        internal
        view
        returns (uint256)
    {
        // Safety margin to prevent liquidation (80% of max borrow)
        return assets.mulDivDown(marketParams.lltv, ORACLE_PRICE_SCALE).mulDivDown(80, 100);
    }
}
```

### Liquidation Bot with Instant Selling

```solidity
// Liquidation bot that immediately sells collateral
contract LiquidationBot is IMorphoLiquidateCallback {
    Morpho public immutable morpho;
    ISwapRouter public immutable swapRouter;
    
    constructor(address _morpho, address _swapRouter) {
        morpho = Morpho(_morpho);
        swapRouter = ISwapRouter(_swapRouter);
    }
    
    function executeLiquidation(
        MarketParams memory marketParams,
        address borrower,
        uint256 seizedAssets
    ) external {
        bytes memory callbackData = abi.encode(
            marketParams.collateralToken,
            marketParams.loanToken,
            msg.sender
        );
        
        morpho.liquidate(
            marketParams,
            borrower,
            seizedAssets,
            0,
            callbackData
        );
    }
    
    function onMorphoLiquidate(uint256 repaidAssets, bytes calldata data) external override {
        require(msg.sender == address(morpho), "Unauthorized");
        
        (
            address collateralToken,
            address loanToken,
            address liquidator
        ) = abi.decode(data, (address, address, address));
        
        // Get seized collateral balance
        uint256 collateralBalance = IERC20(collateralToken).balanceOf(address(this));
        
        // Approve swapRouter to use collateral
        IERC20(collateralToken).approve(address(swapRouter), collateralBalance);
        
        // Swap collateral for loan token to repay
        uint256 minAmountOut = repaidAssets; // We need at least this much to break even
        uint256 amountReceived = swapRouter.swapExactTokensForTokens(
            collateralBalance,
            minAmountOut,
            _getPath(collateralToken, loanToken),
            address(this),
            block.timestamp
        );
        
        // Approve Morpho to take repayment
        IERC20(loanToken).approve(address(morpho), repaidAssets);
        
        // Send any profit to liquidator
        if (amountReceived > repaidAssets) {
            IERC20(loanToken).transfer(liquidator, amountReceived - repaidAssets);
        }
    }
    
    function _getPath(address tokenIn, address tokenOut) internal pure returns (address[] memory) {
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;
        return path;
    }
}
```

### Flash Loan Arbitrage

```solidity
// Flash loan arbitrage example
contract FlashLoanArbitrage is IMorphoFlashLoanCallback {
    Morpho public immutable morpho;
    IExchange public immutable exchangeA;
    IExchange public immutable exchangeB;
    
    constructor(address _morpho, address _exchangeA, address _exchangeB) {
        morpho = Morpho(_morpho);
        exchangeA = IExchange(_exchangeA);
        exchangeB = IExchange(_exchangeB);
    }
    
    function executeArbitrage(
        address token0,
        address token1,
        uint256 amount
    ) external {
        bytes memory callbackData = abi.encode(
            token0,
            token1,
            msg.sender
        );
        
        morpho.flashLoan(token0, amount, callbackData);
    }
    
    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external override {
        require(msg.sender == address(morpho), "Unauthorized");
        
        (
            address token0,
            address token1,
            address user
        ) = abi.decode(data, (address, address, address));
        
        // Step 1: Approve token0 for exchangeA
        IERC20(token0).approve(address(exchangeA), assets);
        
        // Step 2: Swap token0 for token1 on exchangeA
        uint256 token1Amount = exchangeA.swap(token0, token1, assets);
        
        // Step 3: Approve token1 for exchangeB
        IERC20(token1).approve(address(exchangeB), token1Amount);
        
        // Step 4: Swap token1 back to token0 on exchangeB
        uint256 token0AmountOut = exchangeB.swap(token1, token0, token1Amount);
        
        // Step 5: Approve Morpho to take back the flash loaned amount
        IERC20(token0).approve(address(morpho), assets);
        
        // Step 6: Send profits to user
        if (token0AmountOut > assets) {
            IERC20(token0).transfer(user, token0AmountOut - assets);
        }
    }
}
```

## Security Considerations

### Reentrancy Risks

Callbacks create potential reentrancy vectors. Morpho's callback pattern places callback execution at specific points to minimize risks, but integrators should be aware of these concerns:

```solidity
// Bad pattern - vulnerable to reentrancy
function unsafeCallback(uint256 assets, bytes calldata data) external {
    // State changes before external calls
    someStateVariable = newValue;
    
    // Perform external call that could reenter
    someExternalContract.doSomething();
    
    // More state changes that assume prior state
    otherStateVariable = calculatedValue;
}

// Better pattern - checks-effects-interactions
function safeCallback(uint256 assets, bytes calldata data) external {
    // Cache old state if needed
    uint256 oldState = someStateVariable;
    
    // Make all state changes
    someStateVariable = newValue;
    otherStateVariable = calculatedValue;
    
    // Perform external calls last
    someExternalContract.doSomething();
}
```

### Gas Considerations

Callbacks can consume significant gas, especially with complex logic. Consider:

1. Gas limits may be reached in complex operations
2. Failed callbacks can cause entire transactions to revert
3. Gas-intensive callbacks increase vulnerability to price manipulation

### Callback Authentication

Always verify the caller in callback functions:

```solidity
function onMorphoSupply(uint256 assets, bytes calldata data) external override {
    require(msg.sender == address(morpho), "Unauthorized callback");
    // Continue with callback logic
}
```

### Slippage Protection

For callbacks that involve swaps or external prices:

```solidity
function safeSwapWithSlippageProtection(
    address tokenIn,
    address tokenOut,
    uint256 amountIn,
    uint256 minAmountOut
) internal returns (uint256) {
    // Calculate expected amount based on current price
    uint256 expectedAmount = oracle.getExpectedOutput(tokenIn, tokenOut, amountIn);
    
    // Ensure minimum amount is reasonable (e.g., within 1% of expected)
    require(
        minAmountOut >= expectedAmount.mulDivDown(99, 100),
        "Slippage tolerance too high"
    );
    
    // Execute swap with minimum amount protection
    return swapRouter.swap(tokenIn, tokenOut, amountIn, minAmountOut);
}
```

### Data Validation

Always validate decoded callback data:

```solidity
function onMorphoSupplyCollateral(uint256 assets, bytes calldata data) external override {
    // ... authentication checks ...
    
    (address token, uint256 amount, address recipient) = abi.decode(
        data,
        (address, uint256, address)
    );
    
    // Validate parameters
    require(token != address(0), "Invalid token");
    require(amount > 0, "Invalid amount");
    require(recipient != address(0), "Invalid recipient");
    
    // Continue with validated data
}
```

## Integration Best Practices

1. **Atomicity**: Design callbacks to succeed or fail atomically
2. **Idempotence**: Where possible, make callbacks idempotent
3. **Fallback mechanisms**: Include fallback paths for critical operations
4. **Modularity**: Keep callback logic focused and modular
5. **Testing**: Comprehensive testing of callback paths, including edge cases

## Tips for Efficient Implementation

1. Pack callback data efficiently to minimize gas costs
2. Use assembly for gas-intensive operations
3. Minimize storage operations within callbacks
4. Consider view functions for preliminary checks before executing callbacks
5. Implement emergency stop mechanisms for callback contracts 