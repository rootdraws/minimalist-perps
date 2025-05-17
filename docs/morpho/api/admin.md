# Administrative Controls in Morpho

## Core Admin Functions

```solidity
// Owner management
function owner() external view returns (address);
function setOwner(address newOwner) external;

// Market parameter management
function enableIrm(address irm) external;
function enableLltv(uint256 lltv) external;
function setFee(MarketParams memory marketParams, uint256 newFee) external;
function setFeeRecipient(address newFeeRecipient) external;

// Permission checks
function isIrmEnabled(address irm) external view returns (bool);
function isLltvEnabled(uint256 lltv) external view returns (bool);
```

## Admin Implementation for MinimalistPerps

```solidity
// Access control roles
bytes32 public constant OWNER_ROLE = keccak256("OWNER_ROLE");
bytes32 public constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");
bytes32 public constant MARKET_MANAGER_ROLE = keccak256("MARKET_MANAGER_ROLE");
bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

// Admin function implementation
contract MinimalistPerps is AccessControl {
    // Morpho interface reference
    IMorpho public immutable morpho;
    
    constructor(address _morpho) {
        morpho = IMorpho(_morpho);
        
        // Setup initial roles
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(OWNER_ROLE, msg.sender);
        _setupRole(FEE_MANAGER_ROLE, msg.sender);
        _setupRole(MARKET_MANAGER_ROLE, msg.sender);
        _setupRole(EMERGENCY_ROLE, msg.sender);
    }
    
    // Transfer ownership of Morpho contract
    function transferMorphoOwnership(address newOwner) external onlyRole(OWNER_ROLE) {
        morpho.setOwner(newOwner);
        emit MorphoOwnershipTransferred(newOwner);
    }
    
    // Enable new IRM for use in markets
    function enableInterestRateModel(address irm) external onlyRole(MARKET_MANAGER_ROLE) {
        if (morpho.isIrmEnabled(irm)) revert IrmAlreadyEnabled(irm);
        
        try morpho.enableIrm(irm) {
            emit InterestRateModelEnabled(irm);
        } catch Error(string memory reason) {
            revert IrmEnableFailed(irm, reason);
        }
    }
    
    // Enable new LLTV for use in markets
    function enableLoanToValueRatio(uint256 lltv) external onlyRole(MARKET_MANAGER_ROLE) {
        if (lltv > WAD) revert LltvTooHigh(lltv);
        if (morpho.isLltvEnabled(lltv)) revert LltvAlreadyEnabled(lltv);
        
        try morpho.enableLltv(lltv) {
            emit LoanToValueRatioEnabled(lltv);
        } catch Error(string memory reason) {
            revert LltvEnableFailed(lltv, reason);
        }
    }
    
    // Configure fee for a specific market
    function setMarketFee(
        address loanToken,
        address collateralToken,
        uint256 newFee
    ) external onlyRole(FEE_MANAGER_ROLE) {
        if (newFee > MAX_FEE) revert FeeTooHigh(newFee);
        
        MarketParams memory params = marketParamsForToken[loanToken];
        
        // Verify market exists and parameters match
        if (params.loanToken != loanToken || params.collateralToken != collateralToken) {
            revert MarketNotFound(loanToken, collateralToken);
        }
        
        try morpho.setFee(params, newFee) {
            emit MarketFeeUpdated(loanToken, collateralToken, newFee);
        } catch Error(string memory reason) {
            revert FeeUpdateFailed(reason);
        }
    }
    
    // Update fee recipient for protocol fees
    function updateFeeRecipient(address newRecipient) external onlyRole(FEE_MANAGER_ROLE) {
        if (newRecipient == address(0)) revert ZeroAddress();
        
        try morpho.setFeeRecipient(newRecipient) {
            emit FeeRecipientUpdated(newRecipient);
        } catch Error(string memory reason) {
            revert FeeRecipientUpdateFailed(reason);
        }
    }
}
```

## Role Separation

For secure administration, separate permissions across different roles:

1. **Owner Role**
   - Can transfer Morpho ownership
   - Manages administrative roles

2. **Market Manager Role**
   - Enables new IRMs (Interest Rate Models)
   - Enables new LLTVs (Loan-to-Value ratios)
   - Creates new markets

3. **Fee Manager Role**
   - Sets market fees
   - Updates fee recipient
   - Manages protocol fee distribution

4. **Emergency Role**
   - Can pause borrowing/liquidations
   - Can execute emergency operations

## Managing Market Parameters

```solidity
// Create a new market with role-based access control
function createNewMarket(
    address loanToken,
    address collateralToken,
    address oracle,
    address irm,
    uint256 lltv,
    uint256 initialFee
) external onlyRole(MARKET_MANAGER_ROLE) returns (bytes32 marketId) {
    // Validate parameters
    if (loanToken == address(0) || collateralToken == address(0) || oracle == address(0) || irm == address(0)) {
        revert ZeroAddress();
    }
    
    // Verify IRM and LLTV are enabled
    if (!morpho.isIrmEnabled(irm)) revert IrmNotEnabled(irm);
    if (!morpho.isLltvEnabled(lltv)) revert LltvNotEnabled(lltv);
    
    // Create market parameters
    MarketParams memory params = MarketParams({
        loanToken: loanToken,
        collateralToken: collateralToken,
        oracle: oracle,
        irm: irm,
        lltv: lltv
    });
    
    // Create market in Morpho
    try morpho.createMarket(params) returns (Id id) {
        marketId = id;
        
        // Store market in our contract
        marketParamsForToken[loanToken] = params;
        marketParamsForToken[collateralToken] = params;
        marketIdForToken[loanToken] = marketId;
        marketIdForToken[collateralToken] = marketId;
        
        // Set initial fee if specified
        if (initialFee > 0) {
            try morpho.setFee(params, initialFee) {
                // Fee set successfully
            } catch {
                // Fee setting failed, but market was created
            }
        }
        
        emit MarketCreated(marketId, loanToken, collateralToken);
    } catch Error(string memory reason) {
        revert MarketCreationFailed(reason);
    }
    
    return marketId;
}
```

## Fee Management

```solidity
// Fee structure constants
uint256 public constant MAX_FEE = 0.1e18; // 10%
uint256 public constant WAD = 1e18;

// Update fee structure for multiple markets
function updateFeesForMultipleMarkets(
    address[] calldata loanTokens,
    address[] calldata collateralTokens,
    uint256[] calldata newFees
) external onlyRole(FEE_MANAGER_ROLE) {
    if (loanTokens.length != collateralTokens.length || loanTokens.length != newFees.length) {
        revert InvalidArrayLengths();
    }
    
    for (uint256 i = 0; i < loanTokens.length; i++) {
        try this.setMarketFee(loanTokens[i], collateralTokens[i], newFees[i]) {
            // Fee update successful
        } catch Error(string memory reason) {
            // Log error but continue with other markets
            emit FeeUpdateFailed(loanTokens[i], collateralTokens[i], reason);
        }
    }
}

// Withdraw collected fees to treasury
function withdrawCollectedFees(address token) external onlyRole(FEE_MANAGER_ROLE) {
    uint256 feeBalance = collectedFees[token];
    if (feeBalance == 0) revert NoFeesToWithdraw(token);
    
    collectedFees[token] = 0;
    IERC20(token).transfer(treasury, feeBalance);
    
    emit FeesWithdrawn(token, feeBalance, treasury);
}
```

## Error Handling

```solidity
// Custom errors
error NotOwner(address caller);
error ZeroAddress();
error AlreadySet();
error MaxLltvExceeded(uint256 lltv);
error MaxFeeExceeded(uint256 fee);
error IrmAlreadyEnabled(address irm);
error LltvAlreadyEnabled(uint256 lltv);
error IrmNotEnabled(address irm);
error LltvNotEnabled(uint256 lltv);
error LltvTooHigh(uint256 lltv);
error FeeTooHigh(uint256 fee);
error MarketNotFound(address loanToken, address collateralToken);
error MarketCreationFailed(string reason);
error IrmEnableFailed(address irm, string reason);
error LltvEnableFailed(uint256 lltv, string reason);
error FeeUpdateFailed(string reason);
error FeeRecipientUpdateFailed(string reason);
error InvalidArrayLengths();
error NoFeesToWithdraw(address token);

// Events
event MorphoOwnershipTransferred(address newOwner);
event InterestRateModelEnabled(address irm);
event LoanToValueRatioEnabled(uint256 lltv);
event MarketFeeUpdated(address loanToken, address collateralToken, uint256 newFee);
event FeeRecipientUpdated(address newRecipient);
event MarketCreated(bytes32 indexed marketId, address loanToken, address collateralToken);
event FeesWithdrawn(address token, uint256 amount, address treasury);
event FeeUpdateFailed(address loanToken, address collateralToken, string reason);
```

## Security Considerations

1. **Role Management**
   - Use a timelock for critical role transfers
   - Implement a multisig for the OWNER_ROLE
   - Separate duties across different admin roles

2. **Parameter Validation**
   - Validate all parameters before sending to Morpho
   - Implement upper and lower bounds for fees and LLTVs
   - Use simulation for market creation before committing

3. **Emergency Procedures**
   - Document emergency response procedures
   - Test pause/unpause functionality
   - Maintain backup admin keys in cold storage

4. **Audit Logging**
   - Log all admin actions on-chain
   - Maintain off-chain audit logs with justifications
   - Implement transparent governance process for parameter changes 