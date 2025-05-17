# Morpho Snippets

## Core Functions

### View Functions
```solidity
// Vault Information
totalDepositVault(address vault)                           // Get total assets in vault
vaultAssetsInMarket(address vault, MarketParams)           // Get vault's assets in specific market
totalSharesUserVault(address vault, address user)          // Get user's shares in vault

// Queues & Configuration
supplyQueueVault(address vault)                            // Get vault's supply queue
withdrawQueueVault(address vault)                          // Get vault's withdraw queue
totalCapCollateral(address vault, address asset)           // Get total cap for specific collateral

// APY Calculations
supplyAPYMarket(MarketParams, Market)                      // Calculate APY for a market
supplyAPYVault(address vault)                              // Calculate weighted APY for a vault
```

### Management Functions
```solidity
// Core Operations
depositInVault(address vault, uint256 assets, address onBehalf)          // Deposit into vault
withdrawFromVaultAmount(address vault, uint256 assets, address receiver)  // Withdraw specific amount
redeemAllFromVault(address vault, address receiver)                       // Redeem all assets

// Advanced Operations
reallocateAvailableLiquidity(                              // Move liquidity between markets
    address vault,
    MarketParams[] srcMarketParams, 
    MarketParams destMarketParams
)
```

## Implementation

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Imports

import {IMetaMorpho, MarketAllocation} from "../../lib/metamorpho/src/interfaces/IMetaMorpho.sol";
import {ConstantsLib} from "../../lib/metamorpho/src/libraries/ConstantsLib.sol";

import {MarketParamsLib} from "../../lib/metamorpho/lib/morpho-blue/src/libraries/MarketParamsLib.sol";
import {Id, IMorpho, Market, MarketParams} from "../../lib/metamorpho/lib/morpho-blue/src/interfaces/IMorpho.sol";
import {IIrm} from "../../lib/metamorpho/lib/morpho-blue/src/interfaces/IIrm.sol";
import {SharesMathLib} from "../../lib/metamorpho/lib/morpho-blue/src/libraries/SharesMathLib.sol";
import {MorphoLib} from "../../lib/metamorpho/lib/morpho-blue/src/libraries/periphery/MorphoLib.sol";
import {MorphoBalancesLib} from "../../lib/metamorpho/lib/morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";
import {MathLib, WAD} from "../../lib/metamorpho/lib/morpho-blue/src/libraries/MathLib.sol";
import {UtilsLib} from "../../lib/metamorpho/lib/morpho-blue/src/libraries/UtilsLib.sol";

import {Math} from "../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import {ERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

contract MetaMorphoSnippets {
    using SharesMathLib for uint256;
    using MathLib for uint256;
    using Math for uint256;
    using MarketParamsLib for MarketParams;
    using MorphoLib for IMorpho;
    using MorphoBalancesLib for IMorpho;
    using UtilsLib for uint256;

    IMorpho public immutable morpho;

    constructor(address morphoAddress) {
        morpho = IMorpho(morphoAddress);
    }

    // --- VIEW FUNCTIONS ---

    /// @notice Returns the total assets deposited into a MetaMorpho `vault`.
    /// @param vault The address of the MetaMorpho vault.
    function totalDepositVault(address vault) public view returns (uint256 totalAssets) {
        totalAssets = IMetaMorpho(vault).totalAssets();
    }

    /// @notice Returns the total assets supplied into a specific morpho blue market by a MetaMorpho `vault`.
    /// @param vault The address of the MetaMorpho vault.
    /// @param marketParams The morpho blue market.
    function vaultAssetsInMarket(address vault, MarketParams memory marketParams)
        public
        view
        returns (uint256 assets)
    {
        assets = morpho.expectedSupplyAssets(marketParams, vault);
    }

    /// @notice Returns the total shares balance of a `user` on a MetaMorpho `vault`.
    /// @param vault The address of the MetaMorpho vault.
    /// @param user The address of the user.
    function totalSharesUserVault(address vault, address user) public view returns (uint256 totalSharesUser) {
        totalSharesUser = IMetaMorpho(vault).balanceOf(user);
    }

    /// @notice Returns the supply queue a MetaMorpho `vault`.
    /// @param vault The address of the MetaMorpho vault.
    function supplyQueueVault(address vault) public view returns (Id[] memory supplyQueueList) {
        uint256 queueLength = IMetaMorpho(vault).supplyQueueLength();
        supplyQueueList = new Id[](queueLength);

        for (uint256 i; i < queueLength; ++i) {
            supplyQueueList[i] = IMetaMorpho(vault).supplyQueue(i);
        }
    }

    /// @notice Returns the withdraw queue a MetaMorpho `vault`.
    /// @param vault The address of the MetaMorpho vault.
    function withdrawQueueVault(address vault) public view returns (Id[] memory withdrawQueueList) {
        uint256 queueLength = IMetaMorpho(vault).withdrawQueueLength();
        withdrawQueueList = new Id[](queueLength);

        for (uint256 i; i < queueLength; ++i) {
            withdrawQueueList[i] = IMetaMorpho(vault).withdrawQueue(i);
        }
    }

    /// @notice Returns the sum of the supply caps of markets with the same collateral `token` on a MetaMorpho `vault`.
    /// @dev This is a way to visualize exposure to this token.
    /// @param vault The address of the MetaMorpho vault.
    /// @param asset The collateral asset.
    function totalCapCollateral(address vault, address asset) public view returns (uint192 totalCap) {
        uint256 queueLength = IMetaMorpho(vault).withdrawQueueLength();

        for (uint256 i; i < queueLength; ++i) {
            Id idMarket = IMetaMorpho(vault).withdrawQueue(i);
            MarketParams memory marketParams = morpho.idToMarketParams(idMarket);

            if (marketParams.collateralToken == asset) {
                totalCap += IMetaMorpho(vault).config(idMarket).cap;
            }
        }
    }

    /// @notice Returns the current APY of a Morpho Blue market.
    /// @param marketParams The morpho blue market parameters.
    /// @param market The morpho blue market state.
    function supplyAPYMarket(MarketParams memory marketParams, Market memory market)
        public
        view
        returns (uint256 supplyApy)
    {
        // Get the borrow rate
        uint256 borrowRate;
        if (marketParams.irm == address(0)) {
            return 0;
        } else {
            borrowRate = IIrm(marketParams.irm).borrowRateView(marketParams, market).wTaylorCompounded(365 days);
        }

        (uint256 totalSupplyAssets,, uint256 totalBorrowAssets,) = morpho.expectedMarketBalances(marketParams);

        // Get the supply rate
        uint256 utilization = totalBorrowAssets == 0 ? 0 : totalBorrowAssets.wDivUp(totalSupplyAssets);

        supplyApy = borrowRate.wMulDown(1 ether - market.fee).wMulDown(utilization);
    }

    /// @notice Returns the current APY of a MetaMorpho vault.
    /// @dev It is computed as the sum of all APY of enabled markets weighted by the supply on these markets.
    /// @param vault The address of the MetaMorpho vault.
    function supplyAPYVault(address vault) public view returns (uint256 avgSupplyApy) {
        uint256 ratio;
        uint256 queueLength = IMetaMorpho(vault).withdrawQueueLength();

        uint256 totalAmount = totalDepositVault(vault);

        for (uint256 i; i < queueLength; ++i) {
            Id idMarket = IMetaMorpho(vault).withdrawQueue(i);

            MarketParams memory marketParams = morpho.idToMarketParams(idMarket);
            Market memory market = morpho.market(idMarket);

            uint256 currentSupplyAPY = supplyAPYMarket(marketParams, market);
            uint256 vaultAsset = vaultAssetsInMarket(vault, marketParams);
            ratio += currentSupplyAPY.wMulDown(vaultAsset);
        }

        avgSupplyApy = ratio.mulDivDown(WAD - IMetaMorpho(vault).fee(), totalAmount);
    }

    // --- MANAGING FUNCTIONS ---

    /// @notice Deposit `assets` into the `vault` on behalf of `onBehalf`.
    /// @dev Sender must approve the snippets contract to manage his tokens before the call.
    /// @param vault The address of the MetaMorpho vault.
    /// @param assets the amount to deposit.
    /// @param onBehalf The address that will own the increased deposit position.
    function depositInVault(address vault, uint256 assets, address onBehalf) public returns (uint256 shares) {
        ERC20(IMetaMorpho(vault).asset()).transferFrom(msg.sender, address(this), assets);

        _approveMaxVault(vault);

        shares = IMetaMorpho(vault).deposit(assets, onBehalf);
    }

    /// @notice Withdraws `assets` from the `vault` on behalf of the sender, and sends them to `receiver`.
    /// @dev Sender must approve the snippets contract to manage his tokens before the call.
    /// @dev To withdraw all, it is recommended to use the redeem function.
    /// @param vault The address of the MetaMorpho vault.
    /// @param assets the amount to withdraw.
    /// @param receiver The address that will receive the withdrawn assets.
    function withdrawFromVaultAmount(address vault, uint256 assets, address receiver)
        public
        returns (uint256 redeemed)
    {
        redeemed = IMetaMorpho(vault).withdraw(assets, receiver, msg.sender);
    }

    /// @notice Redeems the whole sender's position from the `vault`, and sends the withdrawn amount to `receiver`.
    /// @param vault The address of the MetaMorpho vault.
    /// @param receiver The address that will receive the withdrawn assets.
    function redeemAllFromVault(address vault, address receiver) public returns (uint256 redeemed) {
        uint256 maxToRedeem = IMetaMorpho(vault).maxRedeem(msg.sender);
        redeemed = IMetaMorpho(vault).redeem(maxToRedeem, receiver, msg.sender);
    }

    /// @notice Withdraws the maximum available liquidity from the markets `srcMarketParams`, and supply the withdrawn
    /// assets into `destMarketParams`.
    /// @dev The contract implementing this function must be registered as an allocator of the vault for the function to
    /// be called successfully.
    /// @param vault The address of the MetaMorpho vault.
    /// @param srcMarketParams A MarketParams list of markets to withdraw from.
    /// @param destMarketParams The MarketParams of the market to supply to.
    function reallocateAvailableLiquidity(
        address vault,
        MarketParams[] calldata srcMarketParams,
        MarketParams calldata destMarketParams
    ) public {
        uint256 nbMarkets = srcMarketParams.length;
        MarketAllocation[] memory allocations = new MarketAllocation[](nbMarkets + 1);

        for (uint256 i; i < nbMarkets; ++i) {
            MarketParams memory marketParams = srcMarketParams[i];

            (uint256 totalSupplyAssets, uint256 totalSupplyShares, uint256 totalBorrowAssets,) =
                morpho.expectedMarketBalances(marketParams);

            uint256 supplyShares = morpho.supplyShares(marketParams.id(), vault);
            uint256 supplyAssets = supplyShares.toAssetsDown(totalSupplyAssets, totalSupplyShares);

            uint256 availableLiquidity = totalSupplyAssets - totalBorrowAssets;

            allocations[i] =
                MarketAllocation({marketParams: marketParams, assets: supplyAssets.zeroFloorSub(availableLiquidity)});
        }

        allocations[nbMarkets] = MarketAllocation({marketParams: destMarketParams, assets: type(uint256).max});

        IMetaMorpho(vault).reallocate(allocations);
    }

    function _approveMaxVault(address vault) internal {
        if (ERC20(IMetaMorpho(vault).asset()).allowance(address(this), vault) == 0) {
            ERC20(IMetaMorpho(vault).asset()).approve(vault, type(uint256).max);
        }
    }
}
