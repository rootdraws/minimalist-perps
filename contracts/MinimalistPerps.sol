// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";

// Simplified interface for Morpho
interface IMorpho {
    function supply(address market, uint256 assets, uint256 shares, address onBehalf, bytes calldata data) external returns (uint256, uint256);
    function withdraw(address market, uint256 assets, uint256 shares, address receiver, address owner, bytes calldata data) external returns (uint256, uint256);
    function borrow(address market, uint256 assets, uint256 shares, address onBehalf, address receiver, bytes calldata data) external returns (uint256, uint256);
    function repay(address market, uint256 assets, uint256 shares, address onBehalf, bytes calldata data) external returns (uint256, uint256);
    function flashLoan(address receiver, address token, uint256 amount, bytes calldata data) external returns (bool);
}

// Flash loan receiver interface
interface IFlashLoanReceiver {
    function onFlashLoan(address initiator, address token, uint256 amount, uint256 fee, bytes calldata data) external returns (bytes32);
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
contract MinimalistPerps is ReentrancyGuard, AccessControl, IFlashLoanReceiver {
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
            positionId,
            collateralToken,
            borrowToken,
            collateralAmount,
            leverage,
            uniswapFee,
            true, // isLong
            msg.sender
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
            positionId,
            collateralToken,
            borrowToken,
            collateralAmount,
            leverage,
            uniswapFee,
            false, // isLong
            msg.sender
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
            // Increase position size (similar to creating a position)
            uint256 additionalSize = uint256(sizeChange);
            
            // Calculate flash loan amount
            uint256 flashLoanAmount = position.isLong ? 
                additionalSize * position.debtAmount / position.collateralAmount :
                additionalSize;
            
            // Prepare flash loan data for increase
            bytes memory flashLoanData = abi.encode(
                positionId,
                position.collateralToken,
                position.borrowToken,
                additionalSize,
                0, // Not used for increase
                uniswapFee,
                position.isLong,
                msg.sender
            );
            
            // Execute flash loan to increase
            morpho.flashLoan(
                address(this),
                position.isLong ? position.borrowToken : position.collateralToken,
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
                
                // Swap collateral for borrow token
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
                
                uint256 amountOut = uniswapRouter.exactInputSingle(params);
                
                // Repay debt
                IERC20(position.borrowToken).approve(address(morpho), amountOut);
                morpho.repay(
                    morphoMarkets[position.borrowToken],
                    debtToRepay,
                    0,
                    address(this),
                    bytes("")
                );
            } else {
                // For short: similar but opposite direction
                // (implementation similar to long but with tokens reversed)
            }
            
            // Update position
            position.collateralAmount -= collateralToWithdraw;
            position.debtAmount -= debtToRepay;
        }
        
        emit PositionModified(positionId, sizeChange, position.collateralAmount, position.debtAmount);
    }
    
    // Close a position
    function closePosition(uint256 positionId) external nonReentrant {
        // Verify ownership
        require(positionNFT.ownerOf(positionId) == msg.sender, "Not position owner");
        
        Position memory position = positions[positionId];
        
        // Withdraw all collateral
        morpho.withdraw(
            morphoMarkets[position.collateralToken],
            position.collateralAmount,
            0,
            address(this),
            address(this),
            bytes("")
        );
        
        // For long positions
        if (position.isLong) {
            // Swap enough collateral to repay debt
            IERC20(position.collateralToken).approve(address(uniswapRouter), position.collateralAmount);
            
            // Calculate how much collateral needed to repay debt
            uint256 collateralToSwap = getCollateralNeeded(
                position.collateralToken,
                position.borrowToken,
                position.debtAmount
            );
            
            require(collateralToSwap <= position.collateralAmount, "Insufficient collateral");
            
            // Swap collateral for borrow token
            ISwapRouter.ExactOutputSingleParams memory params = ISwapRouter.ExactOutputSingleParams({
                tokenIn: position.collateralToken,
                tokenOut: position.borrowToken,
                fee: 3000, // Default fee
                recipient: address(this),
                deadline: block.timestamp,
                amountOut: position.debtAmount,
                amountInMaximum: collateralToSwap,
                sqrtPriceLimitX96: 0
            });
            
            uniswapRouter.exactOutputSingle(params);
            
            // Repay debt
            IERC20(position.borrowToken).approve(address(morpho), position.debtAmount);
            morpho.repay(
                morphoMarkets[position.borrowToken],
                position.debtAmount,
                0,
                address(this),
                bytes("")
            );
            
            // Return remaining collateral to user
            uint256 remainingCollateral = IERC20(position.collateralToken).balanceOf(address(this));
            IERC20(position.collateralToken).transfer(msg.sender, remainingCollateral);
            
            emit PositionClosed(positionId, msg.sender, remainingCollateral);
        } else {
            // For short positions (similar logic, tokens reversed)
        }
        
        // Burn position NFT
        positionNFT.burn(positionId);
        
        // Clear position data
        delete positions[positionId];
    }
    
    // Liquidate an unhealthy position
    function liquidatePosition(uint256 positionId) external nonReentrant {
        Position memory position = positions[positionId];
        
        // Check if position is unhealthy
        uint256 healthFactor = getHealthFactor(positionId);
        require(healthFactor < LIQUIDATION_THRESHOLD, "Position is healthy");
        
        // Similar to closePosition but with liquidation bonus
        // Pay liquidator a fee
        // Return remaining funds to position owner
        
        // Burn position NFT
        positionNFT.burn(positionId);
        
        // Clear position data
        delete positions[positionId];
        
        emit PositionLiquidated(positionId, positionNFT.ownerOf(positionId), msg.sender);
    }
    
    // ======== FLASH LOAN CALLBACK ========
    
    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external override returns (bytes32) {
        require(msg.sender == address(morpho), "Unauthorized");
        require(initiator == address(this), "Unauthorized initiator");
        
        // Decode flash loan data
        (
            uint256 positionId,
            address collateralToken,
            address borrowToken,
            uint256 collateralAmount,
            uint256 leverage,
            uint24 uniswapFee,
            bool isLong,
            address trader
        ) = abi.decode(data, (uint256, address, address, uint256, uint256, uint24, bool, address));
        
        if (isLong) {
            // Execute long position
            executeLongPosition(
                positionId,
                collateralToken,
                borrowToken,
                collateralAmount,
                amount,
                fee,
                uniswapFee
            );
        } else {
            // Execute short position
            executeShortPosition(
                positionId,
                collateralToken,
                borrowToken,
                collateralAmount,
                amount,
                fee,
                uniswapFee
            );
        }
        
        return keccak256("MinimalistPerps.onFlashLoan");
    }
    
    // Execute a long position with flash loan
    function executeLongPosition(
        uint256 positionId,
        address collateralToken,
        address borrowToken,
        uint256 initialCollateral,
        uint256 flashLoanAmount,
        uint256 flashLoanFee,
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
        
        // 2. Supply total collateral to Morpho
        uint256 totalCollateral = initialCollateral + collateralBought;
        IERC20(collateralToken).approve(address(morpho), totalCollateral);
        
        morpho.supply(
            morphoMarkets[collateralToken],
            totalCollateral,
            0,
            address(this),
            bytes("")
        );
        
        // 3. Borrow to repay flash loan
        uint256 totalBorrowNeeded = flashLoanAmount + flashLoanFee;
        morpho.borrow(
            morphoMarkets[borrowToken],
            totalBorrowNeeded,
            0,
            address(this),
            address(this),
            bytes("")
        );
        
        // 4. Repay flash loan (handled by morpho automatically)
        IERC20(borrowToken).approve(address(morpho), totalBorrowNeeded);
        
        // 5. Store position data
        positions[positionId] = Position({
            collateralToken: collateralToken,
            borrowToken: borrowToken,
            collateralAmount: totalCollateral,
            debtAmount: totalBorrowNeeded,
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
        uint256 flashLoanFee,
        uint24 uniswapFee
    ) internal {
        // Similar to long but with tokens reversed
        // 1. Swap flash-loaned BTC for USDC
        // 2. Supply total USDC collateral to Morpho
        // 3. Borrow BTC to repay flash loan
        // 4. Repay flash loan
        // 5. Store position data
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
}
