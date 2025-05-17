# Flash Functions in MinimalistPerps

## Callback Implementations

```solidity
// Must implement these interfaces
contract MinimalistPerps is 
    IMorphoFlashLoanCallback,
    IMorphoSupplyCallback, 
    IMorphoSupplyCollateralCallback,
    IMorphoRepayCallback

// Flash loan callback - core leverage mechanism
function onMorphoFlashLoan(uint256 amount, bytes memory data) external override {
    // Always verify sender
    require(msg.sender == address(morpho), "Unauthorized");
    
    // Extract selector and data
    bytes4 selector;
    bytes memory callbackData;
    (selector, callbackData) = abi.decode(data, (bytes4, bytes));
    
    if (selector == CREATE_LONG_SELECTOR) {
        // Decode long position parameters
        (
            uint256 positionId,
            address collateralToken,
            address borrowToken,
            uint256 collateralAmount,
            uint256 leverage,
            uint24 uniswapFee,
            address trader
        ) = abi.decode(callbackData, (uint256, address, address, uint256, uint256, uint24, address));
        
        // Execute long position setup
        executeLongPosition(
            positionId,
            collateralToken,
            borrowToken,
            collateralAmount,
            amount,
            uniswapFee
        );
        
        // Approve token for flash loan repayment
        IERC20(borrowToken).approve(address(morpho), amount);
    }
}

// Supply callback for just-in-time approval
function onMorphoSupply(uint256 amount, bytes memory data) external override {
    require(msg.sender == address(morpho), "Unauthorized");
    
    bytes4 selector;
    bytes memory callbackData;
    (selector, callbackData) = abi.decode(data, (bytes4, bytes));
    
    // Extract token from callback data
    address token = abi.decode(callbackData, (address));
    
    // Approve tokens
    IERC20(token).approve(address(morpho), amount);
}

// Repay callback for position management
function onMorphoRepay(uint256 amount, bytes memory data) external override {
    require(msg.sender == address(morpho), "Unauthorized");
    
    bytes4 selector;
    bytes memory callbackData;
    (selector, callbackData) = abi.decode(data, (bytes4, bytes));
    
    // Get token from callback data
    address token = abi.decode(callbackData, (address));
    
    // Approve repayment
    IERC20(token).approve(address(morpho), amount);
}
```

## Position Creation Implementation

```solidity
// Create long position with flash loan leverage
function createLongPosition(
    address collateralToken,
    address borrowToken,
    uint256 collateralAmount,
    uint256 leverage,
    uint24 uniswapFee
) external nonReentrant returns (uint256 positionId) {
    // Validate inputs
    require(collateralAmount > 0, "Collateral must be positive");
    require(leverage > 1 && leverage <= MAX_LEVERAGE, "Invalid leverage");
    require(morphoMarkets[borrowToken] != address(0), "Market not supported");
    
    // Transfer collateral from user
    IERC20(collateralToken).safeTransferFrom(msg.sender, address(this), collateralAmount);
    
    // Mint position NFT
    positionId = positionNFT.mint(msg.sender);
    
    // Calculate flash loan amount for leverage
    uint256 flashLoanAmount = collateralAmount * (leverage - 1);
    
    // Prepare flash loan data with selector
    bytes memory flashLoanData = abi.encode(
        CREATE_LONG_SELECTOR,
        abi.encode(
            positionId,
            collateralToken,
            borrowToken,
            collateralAmount,
            leverage,
            uniswapFee,
            msg.sender
        )
    );
    
    // Execute flash loan to create leveraged position
    morpho.flashLoan(address(this), borrowToken, flashLoanAmount, flashLoanData);
    
    emit PositionCreated(positionId, msg.sender, true, collateralAmount, leverage);
    
    return positionId;
}
```

## Position Management Functions

```solidity
// Increase position size
function increasePosition(
    uint256 positionId, 
    uint256 additionalSize, 
    uint24 uniswapFee
) external nonReentrant {
    require(positionNFT.ownerOf(positionId) == msg.sender, "Not position owner");
    Position storage position = positions[positionId];
    
    // Calculate flash loan amount 
    uint256 flashLoanAmount = position.isLong ? 
        additionalSize * position.debtAmount / position.collateralAmount :
        additionalSize;
    
    // Create callback data with modifier selector
    bytes memory flashLoanData = abi.encode(
        MODIFY_POSITION_SELECTOR,
        abi.encode(
            positionId,
            position.collateralToken,
            position.borrowToken,
            additionalSize,
            uniswapFee,
            true, // isIncrease
            msg.sender
        )
    );
    
    // Flash loan for position increase
    morpho.flashLoan(
        address(this),
        position.borrowToken,
        flashLoanAmount,
        flashLoanData
    );
    
    emit PositionModified(positionId, int256(additionalSize), position.collateralAmount, position.debtAmount);
}

// Close position using callbacks
function closePosition(uint256 positionId, uint24 uniswapFee) external nonReentrant {
    require(positionNFT.ownerOf(positionId) == msg.sender, "Not position owner");
    Position memory position = positions[positionId];
    
    // Prepare repayment callback data
    bytes memory repayData = abi.encode(
        bytes4(0), // No special handling 
        abi.encode(position.borrowToken)
    );
    
    // Execute repayment with callback
    morpho.repay(
        marketParams[position.borrowToken],
        position.debtAmount,
        0,
        address(this),
        repayData
    );
    
    // Position closing logic...
}
```

## Chaining Operations Example

```solidity
// Example of chained operations (from test)
function executeFlashSequence(
    address collateralToken,
    address borrowToken,
    uint256 collateralAmount,
    uint256 borrowAmount
) external {
    // Step 1: Supply collateral with callback that triggers borrowing
    bytes memory supplyData = abi.encode(
        FLASH_SEQUENCE_SELECTOR,
        abi.encode(borrowAmount)
    );
    
    morpho.supplyCollateral(
        marketParams[collateralToken],
        collateralAmount,
        address(this),
        supplyData
    );
    
    // Step 2: When done, repay with callback that withdraws collateral
    bytes memory repayData = abi.encode(
        FLASH_SEQUENCE_SELECTOR,
        abi.encode(collateralAmount)
    );
    
    morpho.repay(
        marketParams[borrowToken],
        borrowAmount,
        0,
        address(this),
        repayData
    );
}

// Callback implementations for chaining
function onMorphoSupplyCollateral(uint256 amount, bytes memory data) external override {
    require(msg.sender == address(morpho), "Unauthorized");
    
    bytes4 selector;
    bytes memory callbackData;
    (selector, callbackData) = abi.decode(data, (bytes4, bytes));
    
    // Approve collateral token
    IERC20(collateralToken).approve(address(morpho), amount);
    
    if (selector == FLASH_SEQUENCE_SELECTOR) {
        // Extract borrow amount from callback data
        uint256 borrowAmount = abi.decode(callbackData, (uint256));
        
        // Execute borrowing immediately after collateral supply
        morpho.borrow(
            marketParams[borrowToken],
            borrowAmount,
            0,
            address(this),
            address(this)
        );
    }
}
```

## Testing Strategy

1. Test callback-based position creation:
   ```solidity
   function testCreateLongPosition() public {
       // Setup test state
       vm.startPrank(user);
       uint256 positionId = perps.createLongPosition(
           collateralToken, borrowToken, 1 ether, 5, 3000 // 5x leverage
       );
       vm.stopPrank();
       
       // Verify position creation
       (address cToken, address bToken, uint256 cAmount, uint256 dAmount, bool isLong) = 
           perps.positions(positionId);
       assertEq(cAmount, 5 ether); // 1 + 4 from flash loan
       assertEq(dAmount, 4 ether); // Flash loan amount
   }
   ```

2. Test callback parameter encoding/decoding:
   ```solidity
   // Use reveal debugging pattern
   function onMorphoFlashLoan(uint256 amount, bytes calldata data) {
       (bytes4 selector, bytes memory callbackData) = abi.decode(data, (bytes4, bytes));
       emit CallbackReceived(selector, callbackData); // Capture for testing
       // Rest of implementation
   }
   ``` 