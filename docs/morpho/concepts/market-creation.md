# Market Creation in Morpho

## Market Parameters Structure

```solidity
struct MarketParams {
    address loanToken;       // Token that can be borrowed (e.g., BTCN)
    address collateralToken; // Token used as collateral (e.g., USDT)
    address oracle;          // Price oracle for token pair
    address irm;             // Interest Rate Model contract
    uint256 lltv;            // Loan-to-Value ratio (liquidation threshold)
}
```

## Required Steps for Market Creation

```solidity
// 1. Enable the Interest Rate Model (if not already enabled)
function enableIrm(address irm) external onlyOwner {
    if (irm == address(0)) revert ZeroAddress();
    if (_isIrmEnabled[irm]) revert AlreadyEnabled();
    
    _isIrmEnabled[irm] = true;
    emit IrmEnabled(irm);
}

// 2. Enable the Loan-to-Value ratio (if not already enabled)
function enableLltv(uint256 lltv) external onlyOwner {
    if (lltv > WAD) revert LltvTooHigh();
    if (_isLltvEnabled[lltv]) revert AlreadyEnabled();
    
    _isLltvEnabled[lltv] = true;
    emit LltvEnabled(lltv);
}

// 3. Create the market with the prepared parameters
function createMarket(MarketParams memory marketParams) external onlyOwner returns (Id id) {
    // Validations will be performed by Morpho
    id = morpho.createMarket(marketParams);
    
    // Store market parameters for our contract
    Id marketId = marketParams.id();
    supportedMarkets[marketParams.loanToken] = true;
    supportedMarkets[marketParams.collateralToken] = true;
    marketParamsForToken[marketParams.loanToken] = marketParams;
    marketParamsForToken[marketParams.collateralToken] = marketParams;
    marketIdForToken[marketParams.loanToken] = marketId;
    marketIdForToken[marketParams.collateralToken] = marketId;
    
    emit MarketCreated(marketId, marketParams.loanToken, marketParams.collateralToken);
    return id;
}
```

## Validation Checks

When creating a market, Morpho enforces these validations:

1. The IRM must be enabled (`isIrmEnabled(marketParams.irm) == true`)
2. The LLTV must be enabled (`isLltvEnabled(marketParams.lltv) == true`)
3. The market must not already exist

## Creating a BTCN/USDT Market

Here's a step-by-step example for creating a BTCN/USDT market:

```solidity
// Contract setup and constants
address public constant BTCN = 0x1234...;  // BTCN token address
address public constant USDT = 0xabcd...;  // USDT token address
address public constant ORACLE = 0x9876...; // Price oracle for BTCN/USDT
address public constant IRM = 0xdef0...;   // Interest Rate Model
uint256 public constant LLTV = 0.8 * 1e18; // 80% LTV (expressed in WAD, 18 decimals)

// Function to initialize BTCN/USDT market
function setupBTCNUSDTMarket() external onlyOwner {
    // 1. Enable IRM if not already enabled
    if (!morpho.isIrmEnabled(IRM)) {
        morpho.enableIrm(IRM);
    }
    
    // 2. Enable LLTV if not already enabled
    if (!morpho.isLltvEnabled(LLTV)) {
        morpho.enableLltv(LLTV);
    }
    
    // 3. Create market parameters
    MarketParams memory params = MarketParams({
        loanToken: BTCN,
        collateralToken: USDT,
        oracle: ORACLE,
        irm: IRM,
        lltv: LLTV
    });
    
    // 4. Create market
    try morpho.createMarket(params) returns (Id marketId) {
        // 5. Store market information in our contract
        btcnUsdtMarketId = marketId;
        // Additional setup...
        emit MarketSetupComplete(BTCN, USDT, marketId);
    } catch Error(string memory reason) {
        emit MarketSetupFailed(BTCN, USDT, reason);
    }
}
```

## Market IDs and Retrieval

```solidity
// Generate market ID from parameters (for verification)
function getMarketId(
    address loanToken,
    address collateralToken,
    address oracle,
    address irm,
    uint256 lltv
) public pure returns (bytes32) {
    MarketParams memory params = MarketParams({
        loanToken: loanToken,
        collateralToken: collateralToken,
        oracle: oracle,
        irm: irm,
        lltv: lltv
    });
    
    return params.id();
}

// Retrieve market parameters from ID
function getMarketParams(Id marketId) public view returns (MarketParams memory) {
    return morpho.idToMarketParams(marketId);
}
```

## Recommended LLTV Values

Different assets have different risk profiles, and LLTV values should be set accordingly:

| Asset Pair | Recommended LLTV | Notes |
|------------|------------------|-------|
| ETH/USDC   | 80% (0.8e18)     | Major asset, relatively stable |
| WBTC/USDT  | 75% (0.75e18)    | Volatile but major asset |
| BTCN/USDT  | 70% (0.7e18)     | Newer asset, higher volatility |
| Altcoins   | 50-65% (0.5-0.65e18) | Higher risk |

## Error Handling

```solidity
// Custom errors
error ZeroAddress();
error AlreadyEnabled();
error LltvTooHigh();
error MarketAlreadyExists(bytes32 marketId);
error InvalidMarketParams();
error IrmNotEnabled(address irm);
error LltvNotEnabled(uint256 lltv);

// Events
event IrmEnabled(address irm);
event LltvEnabled(uint256 lltv);
event MarketCreated(bytes32 indexed marketId, address loanToken, address collateralToken);
event MarketSetupComplete(address loanToken, address collateralToken, bytes32 marketId);
event MarketSetupFailed(address loanToken, address collateralToken, string reason);
``` 