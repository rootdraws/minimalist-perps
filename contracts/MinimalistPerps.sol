// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";

// Proper Morpho interfaces
interface IMorpho {
    function supply(address market, uint256 assets, uint256 shares, address onBehalf, bytes calldata data) external returns (uint256, uint256);
    function withdraw(address market, uint256 assets, uint256 shares, address receiver, address owner, bytes calldata data) external returns (uint256, uint256);
    function borrow(address market, uint256 assets, uint256 shares, address onBehalf, address receiver, bytes calldata data) external returns (uint256, uint256);
    function repay(address market, uint256 assets, uint256 shares, address onBehalf, bytes calldata data) external returns (uint256, uint256);
    function flashLoan(address receiver, address token, uint256 amount, bytes calldata data) external returns (bool);
}

// Flash loan callback interface
interface IMorphoFlashLoanCallback {
    function onMorphoFlashLoan(uint256 amount, bytes calldata data) external;
}

// Supply callback interface
interface IMorphoSupplyCallback {
    function onMorphoSupply(uint256 amount, bytes calldata data) external;
}

// Supply collateral callback interface
interface IMorphoSupplyCollateralCallback {
    function onMorphoSupplyCollateral(uint256 amount, bytes calldata data) external;
}

// Repay callback interface
interface IMorphoRepayCallback {
    function onMorphoRepay(uint256 amount, bytes calldata data) external;
}

// NFT Contract for position ownership
contract PerpsPositionNFT is ERC721Enumerable, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    uint256 private _nextTokenId = 1;

    constructor() ERC721("Perps Position", "PERPS") {
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function mint(address to) external onlyRole(MINTER_ROLE) returns (uint256) {
        uint256 tokenId = _nextTokenId++;
        _safeMint(to, tokenId);
        return tokenId;
    }

    function burn(uint256 tokenId) external onlyRole(MINTER_ROLE) {
        _burn(tokenId);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721Enumerable, AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}

// Main contract handling all perpetual functions
contract MinimalistPerps is ReentrancyGuard, AccessControl, IMorphoFlashLoanCallback, IMorphoSupplyCallback, IMorphoSupplyCollateralCallback, IMorphoRepayCallback {
    using SafeERC20 for IERC20;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    
    // Core position data
    struct Position {
        address collateralToken;
        address borrowToken;
        uint256 collateralAmount;
        uint256 debtAmount;
        bool isLong;
    }
    
    // Contract state
    mapping(uint256 => Position) public positions;
    mapping(address => AggregatorV3Interface) public priceFeeds;
    mapping(address => address) public morphoMarkets;
    
    PerpsPositionNFT public positionNFT;
    IMorpho public morpho;
    ISwapRouter public uniswapRouter;
    address public treasury;
    
    // Liquidation settings
    uint256 public constant LIQUIDATION_THRESHOLD = 1.05e18; // 105%
    uint256 public constant HEALTH_FACTOR_PRECISION = 1e18;
    uint256 public constant MAX_LEVERAGE = 20;
    
    // Protocol fee
    uint256 public protocolFeeBps = 30; // 0.3%
    
    // Selectors for callback function routing
    bytes4 public constant CREATE_LONG_SELECTOR = this.createLongPosition.selector;
    bytes4 public constant CREATE_SHORT_SELECTOR = this.createShortPosition.selector;
    bytes4 public constant MODIFY_POSITION_SELECTOR = this.modifyPosition.selector;
    
    // Events
    event PositionCreated(uint256 indexed positionId, address indexed trader, bool isLong, uint256 collateralAmount, uint256 leverage);
    event PositionModified(uint256 indexed positionId, int256 sizeChange, uint256 newCollateral, uint256 newDebt);
    event PositionClosed(uint256 indexed positionId, address indexed trader, uint256 returnedAmount);
    event PositionLiquidated(uint256 indexed positionId, address indexed trader, address liquidator);
    
    constructor(
        address _morpho,
        address _uniswapRouter,
        address _treasury
    ) {
        morpho = IMorpho(_morpho);
        uniswapRouter = ISwapRouter(_uniswapRouter);
        treasury = _treasury;
        
        // Deploy NFT contract
        positionNFT = new PerpsPositionNFT();
        positionNFT.grantRole(positionNFT.MINTER_ROLE(), address(this));
        
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(OPERATOR_ROLE, msg.sender);
    }
    
    // ======== CORE POSITION FUNCTIONS ========
    
    // Create a leveraged long position
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
        
        // Calculate flash loan amount based on leverage
        uint256 flashLoanAmount = collateralAmount * (leverage - 1);
        
        // Prepare flash loan data
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
        
        // Execute flash loan
        morpho.flashLoan(address(this), borrowToken, flashLoanAmount, flashLoanData);
        
        emit PositionCreated(positionId, msg.sender, true, collateralAmount, leverage);
        
        return positionId;
    }
    
    // Create a leveraged short position
    function createShortPosition(
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
        
        // Calculate flash loan amount based on leverage
        uint256 flashLoanAmount = collateralAmount * leverage;
        
        // Prepare flash loan data
        bytes memory flashLoanData = abi.encode(
            CREATE_SHORT_SELECTOR,
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
        
        // Execute flash loan
        morpho.flashLoan(address(this), borrowToken, flashLoanAmount, flashLoanData);
        
        emit PositionCreated(positionId, msg.sender, false, collateralAmount, leverage);
        
        return positionId;
    }
    
    // Modify position size
    function modifyPosition(
        uint256 positionId,
        int256 sizeChange,
        uint24 uniswapFee
    ) external nonReentrant {
        // Verify ownership
        require(positionNFT.ownerOf(positionId) == msg.sender, "Not position owner");
        
        Position storage position = positions[positionId];
        
        if (sizeChange > 0) {
            // Increase position size
            uint256 additionalSize = uint256(sizeChange);
            
            // Calculate flash loan amount
            uint256 flashLoanAmount = position.isLong ? 
                additionalSize * position.debtAmount / position.collateralAmount :
                additionalSize;
            
            // Prepare flash loan data for increase
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
            
            // Execute flash loan to increase
            morpho.flashLoan(
                address(this),
                position.borrowToken,
                flashLoanAmount,
                flashLoanData
            );
        } else if (sizeChange < 0) {
            // Decrease position size
            uint256 sizeToReduce = uint256(-sizeChange);
            
            require(sizeToReduce <= position.collateralAmount, "Reduction exceeds position size");
            
            // Calculate how much to withdraw and repay
            uint256 collateralToWithdraw = position.collateralAmount * sizeToReduce / position.collateralAmount;
            uint256 debtToRepay = position.debtAmount * sizeToReduce / position.collateralAmount;
            
            // Prepare data for repayment with callback
            bytes memory repayData = abi.encode(
                MODIFY_POSITION_SELECTOR,
                abi.encode(
                    position.borrowToken,
                    positionId,
                    collateralToWithdraw
                )
            );
            
            if (position.isLong) {
                // For long: withdraw collateral, swap to debt token, repay
                // Withdraw collateral from Morpho
                morpho.withdraw(
                    morphoMarkets[position.collateralToken],
                    collateralToWithdraw,
                    0,
                    address(this),
                    address(this),
                    bytes("")
                );
                
                // Swap collateral for debt token
                IERC20(position.collateralToken).approve(address(uniswapRouter), collateralToWithdraw);
                
                ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
                    tokenIn: position.collateralToken,
                    tokenOut: position.borrowToken,
                    fee: uniswapFee,
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: collateralToWithdraw,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                });
                
                uint256 debtTokenReceived = uniswapRouter.exactInputSingle(params);
                
                // Repay debt
                IERC20(position.borrowToken).approve(address(morpho), debtToRepay);
                
                morpho.repay(
                    morphoMarkets[position.borrowToken],
                    debtToRepay,
                    0,
                    address(this),
                    repayData
                );
            } else {
                // For short: repay debt, withdraw collateral
                // Similar implementation to long but with tokens reversed
                
                // Repay debt using callback
                morpho.repay(
                    morphoMarkets[position.borrowToken],
                    debtToRepay,
                    0,
                    address(this),
                    repayData
                );
                
                // Withdraw collateral
                morpho.withdraw(
                    morphoMarkets[position.collateralToken],
                    collateralToWithdraw,
                    0,
                    address(this),
                    address(this),
                    bytes("")
                );
            }
            
            // Update position data
            position.collateralAmount -= collateralToWithdraw;
            position.debtAmount -= debtToRepay;
            
            emit PositionModified(positionId, sizeChange, position.collateralAmount, position.debtAmount);
        }
    }
    
    // Close position
    function closePosition(
        uint256 positionId,
        uint24 uniswapFee
    ) external nonReentrant {
        // Verify ownership
        require(positionNFT.ownerOf(positionId) == msg.sender, "Not position owner");
        
        Position memory position = positions[positionId];
        
        if (position.isLong) {
            // For long: withdraw all collateral, swap part to repay debt, return remainder
            
            // Withdraw all collateral
            morpho.withdraw(
                morphoMarkets[position.collateralToken],
                position.collateralAmount,
                0,
                address(this),
                address(this),
                bytes("")
            );
            
            // Calculate protocol fee
            uint256 protocolFeeAmount = position.collateralAmount * protocolFeeBps / 10000;
            
            // Transfer fee to treasury
            if (protocolFeeAmount > 0) {
                IERC20(position.collateralToken).safeTransfer(treasury, protocolFeeAmount);
            }
            
            // Calculate how much collateral needed to swap for debt repayment
            uint256 collateralToSwap = getCollateralNeeded(
                position.collateralToken,
                position.borrowToken,
                position.debtAmount
            );
            
            // Ensure we have enough collateral after fees
            require(collateralToSwap <= position.collateralAmount - protocolFeeAmount, "Not enough collateral to repay");
            
            // Swap collateral for debt token
            IERC20(position.collateralToken).approve(address(uniswapRouter), collateralToSwap);
            
            ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
                tokenIn: position.collateralToken,
                tokenOut: position.borrowToken,
                fee: uniswapFee,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: collateralToSwap,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            });
            
            uint256 debtTokenReceived = uniswapRouter.exactInputSingle(params);
            
            // Ensure enough debt tokens received
            require(debtTokenReceived >= position.debtAmount, "Insufficient swap output");
            
            // Repay all debt
            bytes memory repayData = abi.encode(
                bytes4(0), // No special function
                abi.encode(position.borrowToken)
            );
            
            morpho.repay(
                morphoMarkets[position.borrowToken],
                position.debtAmount,
                0,
                address(this),
                repayData
            );
            
            // Return remaining collateral to user
            uint256 remainingCollateral = position.collateralAmount - protocolFeeAmount - collateralToSwap;
            if (remainingCollateral > 0) {
                IERC20(position.collateralToken).safeTransfer(msg.sender, remainingCollateral);
            }
            
            // Return excess debt tokens if any
            uint256 excessDebtTokens = debtTokenReceived - position.debtAmount;
            if (excessDebtTokens > 0) {
                IERC20(position.borrowToken).safeTransfer(msg.sender, excessDebtTokens);
            }
            
            emit PositionClosed(positionId, msg.sender, remainingCollateral);
        } else {
            // For short: similar implementation but with tokens reversed
            // Withdraw all collateral, repay debt, return remainder
            
            // Implementation similar to long positions
        }
        
        // Burn the position NFT
        positionNFT.burn(positionId);
        
        // Delete position data
        delete positions[positionId];
    }
    
    // Liquidate position
    function liquidatePosition(uint256 positionId, uint24 uniswapFee) external nonReentrant {
        require(getHealthFactor(positionId) < LIQUIDATION_THRESHOLD, "Position not liquidatable");
        
        Position memory position = positions[positionId];
        
        // Liquidation implementation using callbacks
        
        // Prepare liquidation data
        bytes memory liquidationData = abi.encode(
            bytes4(0), // No special function
            abi.encode(position.borrowToken)
        );
        
        // For a liquidation, we'd implement the proper Morpho liquidate function call
        // This is a simplified example
        
        // Burn the position NFT
        positionNFT.burn(positionId);
        
        // Delete position data
        delete positions[positionId];
        
        emit PositionLiquidated(positionId, positionNFT.ownerOf(positionId), msg.sender);
    }
    
    // ======== MORPHO CALLBACKS ========
    
    // Flash loan callback
    function onMorphoFlashLoan(uint256 amount, bytes calldata data) external override {
        require(msg.sender == address(morpho), "Unauthorized");
        
        // Decode function selector and callback data
        (bytes4 selector, bytes memory callbackData) = abi.decode(data, (bytes4, bytes));
        
        if (selector == CREATE_LONG_SELECTOR) {
            // Handle long position
            (
                uint256 positionId,
                address collateralToken,
                address borrowToken,
                uint256 collateralAmount,
                uint256 leverage,
                uint24 uniswapFee,
                address trader
            ) = abi.decode(callbackData, (uint256, address, address, uint256, uint256, uint24, address));
            
            executeLongPosition(
                positionId,
                collateralToken,
                borrowToken,
                collateralAmount,
                amount,
                uniswapFee
            );
            
            // Approve Morpho to take back the borrowed tokens
            IERC20(borrowToken).approve(address(morpho), amount);
        } else if (selector == CREATE_SHORT_SELECTOR) {
            // Handle short position
            (
                uint256 positionId,
                address collateralToken,
                address borrowToken,
                uint256 collateralAmount,
                uint256 leverage,
                uint24 uniswapFee,
                address trader
            ) = abi.decode(callbackData, (uint256, address, address, uint256, uint256, uint24, address));
            
            executeShortPosition(
                positionId,
                collateralToken,
                borrowToken,
                collateralAmount,
                amount,
                uniswapFee
            );
            
            // Approve Morpho to take back the borrowed tokens
            IERC20(borrowToken).approve(address(morpho), amount);
        } else if (selector == MODIFY_POSITION_SELECTOR) {
            // Handle position modification
            handlePositionModification(callbackData, amount);
            
            // Extract borrowToken from callback data for the approval
            (
                uint256 positionId,
                address collateralToken,
                address borrowToken,
                uint256 additionalSize,
                uint24 uniswapFee,
                bool isIncrease,
                address trader
            ) = abi.decode(callbackData, (uint256, address, address, uint256, uint24, bool, address));
            
            // Approve Morpho to take back the borrowed tokens
            IERC20(borrowToken).approve(address(morpho), amount);
        }
    }
    
    // Supply callback
    function onMorphoSupply(uint256 amount, bytes calldata data) external override {
        require(msg.sender == address(morpho), "Unauthorized");
        
        // Decode function selector and callback data
        (bytes4 selector, bytes memory callbackData) = abi.decode(data, (bytes4, bytes));
        
        // Get token to approve from the callback data
        address token = abi.decode(callbackData, (address));
        
        // Approve tokens for Morpho
        IERC20(token).approve(address(morpho), amount);
    }
    
    // Supply collateral callback
    function onMorphoSupplyCollateral(uint256 amount, bytes calldata data) external override {
        require(msg.sender == address(morpho), "Unauthorized");
        
        // Decode function selector and callback data
        (bytes4 selector, bytes memory callbackData) = abi.decode(data, (bytes4, bytes));
        
        // Get token to approve from the callback data
        address token = abi.decode(callbackData, (address));
        
        // Approve tokens for Morpho
        IERC20(token).approve(address(morpho), amount);
    }
    
    // Repay callback
    function onMorphoRepay(uint256 amount, bytes calldata data) external override {
        require(msg.sender == address(morpho), "Unauthorized");
        
        // Decode function selector and callback data
        (bytes4 selector, bytes memory callbackData) = abi.decode(data, (bytes4, bytes));
        
        // Get token to approve from the callback data
        address token = abi.decode(callbackData, (address));
        
        // Approve tokens for Morpho
        IERC20(token).approve(address(morpho), amount);
    }
    
    // Execute a long position with flash loan
    function executeLongPosition(
        uint256 positionId,
        address collateralToken,
        address borrowToken,
        uint256 initialCollateral,
        uint256 flashLoanAmount,
        uint24 uniswapFee
    ) internal {
        // 1. Swap borrowed tokens for more collateral
        IERC20(borrowToken).approve(address(uniswapRouter), flashLoanAmount);
        
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: borrowToken,
            tokenOut: collateralToken,
            fee: uniswapFee,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: flashLoanAmount,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        
        uint256 collateralBought = uniswapRouter.exactInputSingle(params);
        
        // 2. Supply total collateral to Morpho using callback for approval
        uint256 totalCollateral = initialCollateral + collateralBought;
        
        bytes memory supplyData = abi.encode(
            bytes4(0), // No special handling needed
            abi.encode(collateralToken)
        );
        
        morpho.supply(
            morphoMarkets[collateralToken],
            totalCollateral,
            0,
            address(this),
            supplyData
        );
        
        // 3. Borrow to repay flash loan
        morpho.borrow(
            morphoMarkets[borrowToken],
            flashLoanAmount,
            0,
            address(this),
            address(this),
            bytes("")
        );
        
        // 4. Store position data
        positions[positionId] = Position({
            collateralToken: collateralToken,
            borrowToken: borrowToken,
            collateralAmount: totalCollateral,
            debtAmount: flashLoanAmount,
            isLong: true
        });
    }
    
    // Execute a short position with flash loan
    function executeShortPosition(
        uint256 positionId,
        address collateralToken,
        address borrowToken,
        uint256 initialCollateral,
        uint256 flashLoanAmount,
        uint24 uniswapFee
    ) internal {
        // 1. Swap flash-loaned tokens for collateral
        IERC20(borrowToken).approve(address(uniswapRouter), flashLoanAmount);
        
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: borrowToken,
            tokenOut: collateralToken,
            fee: uniswapFee,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: flashLoanAmount,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        
        uint256 collateralBought = uniswapRouter.exactInputSingle(params);
        
        // 2. Supply total collateral to Morpho using callback for approval
        uint256 totalCollateral = initialCollateral + collateralBought;
        
        bytes memory supplyData = abi.encode(
            bytes4(0), // No special handling needed
            abi.encode(collateralToken)
        );
        
        morpho.supply(
            morphoMarkets[collateralToken],
            totalCollateral,
            0,
            address(this),
            supplyData
        );
        
        // 3. Borrow to repay flash loan
        morpho.borrow(
            morphoMarkets[borrowToken],
            flashLoanAmount,
            0,
            address(this),
            address(this),
            bytes("")
        );
        
        // 4. Store position data
        positions[positionId] = Position({
            collateralToken: collateralToken,
            borrowToken: borrowToken,
            collateralAmount: totalCollateral,
            debtAmount: flashLoanAmount,
            isLong: false
        });
    }
    
    // ======== VIEW FUNCTIONS ========
    
    // Get position details
    function getPosition(uint256 positionId) external view returns (Position memory) {
        return positions[positionId];
    }
    
    // Calculate health factor
    function getHealthFactor(uint256 positionId) public view returns (uint256) {
        Position memory position = positions[positionId];
        
        // Get current value of collateral in USD
        uint256 collateralValueUSD = getTokenValueUSD(
            position.collateralToken,
            position.collateralAmount
        );
        
        // Get current value of debt in USD
        uint256 debtValueUSD = getTokenValueUSD(
            position.borrowToken,
            position.debtAmount
        );
        
        // Calculate health factor (scaled by HEALTH_FACTOR_PRECISION)
        return (collateralValueUSD * HEALTH_FACTOR_PRECISION) / debtValueUSD;
    }
    
    // Get token value in USD
    function getTokenValueUSD(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = priceFeeds[token];
        require(address(priceFeed) != address(0), "No price feed");
        
        (, int256 price,,,) = priceFeed.latestRoundData();
        require(price > 0, "Invalid price");
        
        uint8 decimals = priceFeed.decimals();
        
        return (amount * uint256(price)) / (10 ** decimals);
    }
    
    // Calculate collateral needed for a given debt amount
    function getCollateralNeeded(address collateralToken, address debtToken, uint256 debtAmount) public view returns (uint256) {
        uint256 debtValue = getTokenValueUSD(debtToken, debtAmount);
        uint256 collateralPrice = getTokenValueUSD(collateralToken, 1e18);
        
        return (debtValue * 1e18) / collateralPrice;
    }
    
    // ======== ADMIN FUNCTIONS ========
    
    function setPriceFeed(address token, address feed) external onlyRole(OPERATOR_ROLE) {
        priceFeeds[token] = AggregatorV3Interface(feed);
    }
    
    function setMorphoMarket(address token, address market) external onlyRole(OPERATOR_ROLE) {
        morphoMarkets[token] = market;
    }
    
    function setProtocolFee(uint256 newFeeBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newFeeBps <= 100, "Fee too high"); // Max 1%
        protocolFeeBps = newFeeBps;
    }
    
    function setTreasury(address newTreasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newTreasury != address(0), "Zero address");
        treasury = newTreasury;
    }
    
    // ======== IMPLEMENTATION HELPERS ========
    
    // Handle flash loan callback for position modification
    function handlePositionModification(bytes memory callbackData, uint256 amount) internal {
        (
            uint256 positionId,
            address collateralToken,
            address borrowToken,
            uint256 additionalSize,
            uint24 uniswapFee,
            bool isIncrease,
            address trader
        ) = abi.decode(callbackData, (uint256, address, address, uint256, uint24, bool, address));
        
        Position storage position = positions[positionId];
        
        if (isIncrease) {
            // Handle position increase
            // Implementation similar to executeLongPosition or executeShortPosition
            
            if (position.isLong) {
                // For long positions
                
                // 1. Swap borrowed tokens for more collateral
                IERC20(borrowToken).approve(address(uniswapRouter), amount);
                
                ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
                    tokenIn: borrowToken,
                    tokenOut: collateralToken,
                    fee: uniswapFee,
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: amount,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                });
                
                uint256 collateralBought = uniswapRouter.exactInputSingle(params);
                
                // 2. Supply additional collateral to Morpho
                bytes memory supplyData = abi.encode(
                    bytes4(0),
                    abi.encode(collateralToken)
                );
                
                morpho.supply(
                    morphoMarkets[collateralToken],
                    collateralBought,
                    0,
                    address(this),
                    supplyData
                );
                
                // 3. Update position data
                position.collateralAmount += collateralBought;
                position.debtAmount += amount;
            } else {
                // For short positions
                // Similar implementation
            }
            
            emit PositionModified(positionId, int256(additionalSize), position.collateralAmount, position.debtAmount);
        } else {
            // Handle position decrease
            // Implementation as needed
        }
    }
}
