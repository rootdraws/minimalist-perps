# Supply (Lending) in Morpho

## Supply Function

```solidity
function supply(
    MarketParams memory marketParams,
    uint256 assets,
    uint256 shares,
    address onBehalf,
    bytes calldata data
) external returns (uint256 returnAssets, uint256 returnShares);
```

The `supply` function is the core lending operation in Morpho, allowing users to provide liquidity to markets. Unlike `supplyCollateral`, which is used to back one's own borrowing positions, the `supply` function makes assets available for other users to borrow, with suppliers earning interest over time.

## Implementation for MinimalistPerps

```solidity
contract MinimalistPerps {
    // Morpho interface reference
    IMorpho public immutable morpho;
    
    /**
     * @notice Supply assets to a market for lending
     * @param marketParams The market parameters
     * @param assets The amount of assets to supply (specify 0 if using shares)
     * @param shares The amount of shares to supply (specify 0 if using assets)
     * @param onBehalf The address that will own the supply position
     * @return returnAssets The amount of assets supplied
     * @return returnShares The amount of shares received
     */
    function supplyLiquidity(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf
    ) external returns (uint256 returnAssets, uint256 returnShares) {
        // Validate input
        if ((assets == 0 && shares == 0) || (assets > 0 && shares > 0)) {
            revert InconsistentInput();
        }
        
        if (onBehalf == address(0)) revert ZeroAddress();
        
        // Get market ID
        bytes32 marketId = morpho.idFromMarketParams(marketParams);
        
        // Verify market exists
        if (!morpho.isMarketCreated(marketId)) revert MarketNotCreated();
        
        // Get the loan token
        address loanToken = marketParams.loanToken;
        
        // Calculate the max required transfer amount
        uint256 maxAssets;
        if (assets > 0) {
            maxAssets = assets;
        } else {
            // For shares, calculate the max assets needed
            uint256 totalSupplyAssets = morpho.totalSupplyAssets(marketId);
            uint256 totalSupplyShares = morpho.totalSupplyShares(marketId);
            maxAssets = shares.toAssetsUp(totalSupplyAssets, totalSupplyShares);
        }
        
        // Pull tokens from caller
        IERC20(loanToken).safeTransferFrom(msg.sender, address(this), maxAssets);
        
        // Approve morpho to use tokens
        IERC20(loanToken).safeApprove(address(morpho), maxAssets);
        
        // Execute supply
        try morpho.supply(
            marketParams,
            assets,
            shares,
            onBehalf,
            "" // No callback data needed
        ) returns (uint256 suppliedAssets, uint256 suppliedShares) {
            returnAssets = suppliedAssets;
            returnShares = suppliedShares;
            
            // If we pulled too many tokens, refund the excess
            uint256 refundAmount = maxAssets - suppliedAssets;
            if (refundAmount > 0) {
                IERC20(loanToken).safeTransfer(msg.sender, refundAmount);
            }
            
            emit LiquiditySupplied(marketId, msg.sender, onBehalf, suppliedAssets, suppliedShares);
            
            return (returnAssets, returnShares);
        } catch Error(string memory reason) {
            // Handle specific error cases
            revert SupplyFailed(reason);
        }
    }
    
    /**
     * @notice Calculate the current balance of a supplier including accrued interest
     * @param marketParams The market parameters
     * @param supplier The address of the supplier
     * @return assets The current value of the supply position in assets
     * @return shares The current shares owned by the supplier
     */
    function getSupplyBalance(
        MarketParams memory marketParams,
        address supplier
    ) external view returns (uint256 assets, uint256 shares) {
        bytes32 marketId = morpho.idFromMarketParams(marketParams);
        
        // Get the supplier's share balance
        shares = morpho.supplyShares(marketId, supplier);
        
        if (shares == 0) return (0, 0);
        
        // Convert shares to assets
        uint256 totalSupplyAssets = morpho.totalSupplyAssets(marketId);
        uint256 totalSupplyShares = morpho.totalSupplyShares(marketId);
        
        // Calculate the asset value
        assets = shares.toAssets(totalSupplyAssets, totalSupplyShares);
        
        return (assets, shares);
    }
}
```

## Usage Examples

### Supplying with Exact Asset Amount

```solidity
// Supply 1000 USDC to the lending pool
function supplyUSDCLiquidity(uint256 amount) external {
    // Ensure token approval first
    IERC20(USDC).approve(address(minimalistPerps), amount);
    
    // Get market parameters
    MarketParams memory params = minimalistPerps.getMarketParams(USDC_MARKET_ID);
    
    // Supply liquidity with exact amount
    (uint256 suppliedAssets, uint256 suppliedShares) = minimalistPerps.supplyLiquidity(
        params,
        amount, // exact assets
        0,      // no shares specified
        address(this) // supplying for myself
    );
    
    console.log("Supplied assets:", suppliedAssets);
    console.log("Received shares:", suppliedShares);
}
```

### Supplying with Share Amount

```solidity
// Supply liquidity by specifying the share amount
function supplyByShares(uint256 sharesToMint) external {
    // Get market parameters
    MarketParams memory params = minimalistPerps.getMarketParams(WETH_MARKET_ID);
    bytes32 marketId = minimalistPerps.getMarketId(WETH_MARKET_ID);
    
    // Calculate assets needed
    uint256 totalSupplyAssets = morpho.totalSupplyAssets(marketId);
    uint256 totalSupplyShares = morpho.totalSupplyShares(marketId);
    
    // Maximum amount of assets that could be needed (worst case)
    uint256 maxAssets = sharesToMint.toAssetsUp(totalSupplyAssets, totalSupplyShares);
    
    // Ensure token approval
    IERC20(WETH).approve(address(minimalistPerps), maxAssets);
    
    // Supply with exact shares
    (uint256 suppliedAssets, uint256 suppliedShares) = minimalistPerps.supplyLiquidity(
        params,
        0,            // no assets specified
        sharesToMint, // exact shares
        address(this) // supplying for myself
    );
    
    console.log("Supplied assets:", suppliedAssets);
    console.log("Received shares:", suppliedShares);
}
```

### Supplying on Behalf of Others

```solidity
// Supply liquidity on behalf of another address (e.g., for a vault)
function supplyForVault(address vault, uint256 amount) external onlyVaultManager {
    // Ensure token approval
    IERC20(USDC).approve(address(minimalistPerps), amount);
    
    // Get market parameters
    MarketParams memory params = minimalistPerps.getMarketParams(USDC_MARKET_ID);
    
    // Supply liquidity to vault's balance
    (uint256 suppliedAssets, uint256 suppliedShares) = minimalistPerps.supplyLiquidity(
        params,
        amount,
        0,
        vault // supplying on behalf of the vault
    );
    
    // Update vault accounting
    vaultSupplyBalances[vault] += suppliedAssets;
    
    emit VaultSupplied(vault, suppliedAssets, suppliedShares);
}
```

## Tracking Interest and Earnings

```solidity
// Calculate the interest earned by a supplier
function calculateSupplyInterestEarned(
    bytes32 marketId, 
    address supplier,
    uint256 initialSupplyAmount
) external view returns (uint256 interestEarned) {
    // Get current supply balance
    (uint256 currentAssets, ) = minimalistPerps.getSupplyBalance(
        marketId,
        supplier
    );
    
    // Interest earned is the difference between current balance and initial supply
    if (currentAssets > initialSupplyAmount) {
        interestEarned = currentAssets - initialSupplyAmount;
    } else {
        interestEarned = 0;
    }
    
    return interestEarned;
}
```

## APY Calculation

```solidity
// Calculate the current APY for suppliers in a market
function calculateSupplyAPY(bytes32 marketId) public view returns (uint256 apy) {
    MarketParams memory params = getMarketParams(marketId);
    
    // Get current interest rate model
    IIrm irm = IIrm(params.irm);
    
    // Get current utilization ratio
    uint256 totalSupply = morpho.totalSupplyAssets(marketId);
    uint256 totalBorrow = morpho.totalBorrowAssets(marketId);
    
    // Avoid division by zero
    if (totalSupply == 0) return 0;
    
    uint256 utilization = totalBorrow * 1e18 / totalSupply;
    
    // Get borrow rate from IRM (in ray, 1e27)
    uint256 borrowRate = irm.borrowRateView(params, utilization);
    
    // Calculate supply rate (borrow rate * utilization * (1 - fee))
    uint256 fee = morpho.fee(marketId);
    uint256 supplyRate = borrowRate * utilization * (WAD - fee) / WAD / 1e27;
    
    // Convert to APY (compounded per block to annual)
    // Assuming 7200 blocks per day (12 sec block time)
    uint256 blocksPerYear = 7200 * 365;
    
    // Formula: (1 + rate per block)^blocks per year - 1
    apy = ((1e18 + supplyRate) ** blocksPerYear) - 1e18;
    
    return apy;
}
```

## Error Handling

```solidity
// Custom errors
error InconsistentInput();
error ZeroAddress();
error MarketNotCreated();
error SupplyFailed(string reason);
error InsufficientAllowance(uint256 required, uint256 available);

// Events
event LiquiditySupplied(
    bytes32 indexed marketId,
    address indexed supplier,
    address indexed onBehalf,
    uint256 assets,
    uint256 shares
);

event VaultSupplied(
    address indexed vault,
    uint256 assets,
    uint256 shares
);
```

## Integration with Yield Strategies

The supply functionality can be integrated with automated yield strategies:

```solidity
contract YieldOptimizer {
    MinimalistPerps public immutable perps;
    
    // Track where funds are allocated
    mapping(bytes32 => uint256) public marketAllocations;
    
    constructor(address _perps) {
        perps = MinimalistPerps(_perps);
    }
    
    // Rebalance funds across markets based on APY
    function rebalanceFunds() external onlyManager {
        bytes32[] memory markets = getActiveMarkets();
        uint256[] memory apys = new uint256[](markets.length);
        
        // Get APY for each market
        for (uint256 i = 0; i < markets.length; i++) {
            apys[i] = perps.calculateSupplyAPY(markets[i]);
        }
        
        // Find best market
        uint256 bestMarketIndex = 0;
        for (uint256 i = 1; i < markets.length; i++) {
            if (apys[i] > apys[bestMarketIndex]) {
                bestMarketIndex = i;
            }
        }
        
        // Withdraw from lower yield markets
        for (uint256 i = 0; i < markets.length; i++) {
            if (i != bestMarketIndex && marketAllocations[markets[i]] > 0) {
                // Withdraw from this market
                withdrawFromMarket(markets[i]);
            }
        }
        
        // Supply to highest yield market
        MarketParams memory bestMarketParams = perps.getMarketParams(markets[bestMarketIndex]);
        uint256 availableFunds = IERC20(bestMarketParams.loanToken).balanceOf(address(this));
        
        if (availableFunds > 0) {
            // Supply to best market
            IERC20(bestMarketParams.loanToken).approve(address(perps), availableFunds);
            (uint256 supplied, ) = perps.supplyLiquidity(
                bestMarketParams,
                availableFunds,
                0,
                address(this)
            );
            
            marketAllocations[markets[bestMarketIndex]] += supplied;
        }
    }
    
    // Helper function to withdraw from a market
    function withdrawFromMarket(bytes32 marketId) internal {
        // Implementation for withdrawal
    }
}
```

## Security Considerations

1. **Interest Rate Risk**:
   - Supply rates fluctuate with utilization rate
   - Monitor APY changes over time
   - Consider rate caps to prevent extreme volatility

2. **Liquidity Risk**:
   - Withdrawals might be constrained if most assets are borrowed
   - Consider adding time locks or withdrawal limits for large suppliers
   - Monitor utilization rates for early warning signs

3. **Market Risk**:
   - Value of supplied assets can change due to external market conditions
   - Diversify across multiple markets to reduce exposure
   - Consider protocols with insurance mechanisms

4. **Smart Contract Risk**:
   - Supply operations depend on the security of the underlying protocol
   - Use security features like pausability and withdrawal limits
   - Test against reentrancy and other common vulnerabilities

5. **Systemic Risk**:
   - Supply operations can be affected by broader market conditions
   - Monitor total value locked (TVL) across markets
   - Establish circuit breakers for extreme market conditions

6. **APY Optimization**:
   - Frequent rebalancing can result in gas inefficiency
   - Set minimum APY differentials before triggering a rebalance
   - Consider gas costs in yield calculations

7. **Accounting Precision**:
   - Share-based accounting can lead to rounding errors
   - Use consistent rounding directions (always round down for supply shares)
   - Test with extreme values and edge cases 