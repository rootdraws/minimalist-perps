// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

/**
 * POSITION NFT SECONDARY MARKET NOTES:
 * 
 * - Positions represented as NFTs create a pre-liquidation secondary market
 * - Traders approaching liquidation can sell positions at discount rather than face penalties
 * - Buyers can acquire distressed positions at discount if they have:
 *   1. Additional collateral to deploy
 *   2. Different market outlook
 *   3. Hedging capacity.
 * - Creates price discovery gradient rather than binary liquidation threshold
 * - Buy positions at 80% of their equity value.
 * - Protocol itself could potentially act as position rescuer
 * - Reduces cascading liquidations and improves market stability
 * - Transforms liquidations from reactive events to proactive position management
 */

/**
 * DYNAMIC POSITION METADATA IMPLEMENTATION GUIDE:
 * 
 * Setup and Integration:
 * 1. Grant METADATA_ROLE to the MinimalistPerps contract or a dedicated metadata updater
 * 2. Create a JSON metadata schema including position metrics (health factor, collateral value, etc.)
 * 3. Implement an update mechanism triggered on significant position changes
 * 
 * Metadata Schema Example:
 * {
 *   "name": "Perp Position #1234",
 *   "description": "ETH/USDC Long Position",
 *   "image": "https://api.minimalistperps.com/position/1234/image",
 *   "attributes": [
 *     {"trait_type": "Position Type", "value": "Long"},
 *     {"trait_type": "Collateral Token", "value": "ETH"},
 *     {"trait_type": "Debt Token", "value": "USDC"},
 *     {"trait_type": "Health Factor", "value": "1.35", "display_type": "number"},
 *     {"trait_type": "Liquidation Threshold", "value": "1.05", "display_type": "number"},
 *     {"trait_type": "Collateral Value (USD)", "value": "5000", "display_type": "number"},
 *     {"trait_type": "Debt Value (USD)", "value": "3500", "display_type": "number"},
 *     {"trait_type": "Equity Value (USD)", "value": "1500", "display_type": "number"},
 *     {"trait_type": "Health Status", "value": "Healthy"}
 *   ]
 * }
 * 
 * Implementation Options:
 * 1. On-chain URI: Store complete metadata on-chain (higher gas costs, fully decentralized)
 * 2. IPFS: Generate and pin metadata JSON to IPFS (moderate cost, good decentralization)
 * 3. API-based: Point to an API that dynamically generates metadata (lowest gas, centralized)
 * 
 * Trigger Points for Metadata Updates:
 * - Position creation (mint)
 * - Significant collateral value change (>5%)
 * - Health factor crossing predefined thresholds (1.5, 1.25, 1.1)
 * - Position modification (add/remove collateral, increase/decrease size)
 * 
 * Secondary Market Integration:
 * - Marketplaces like OpenSea will automatically display position health and metrics
 * - Specialized marketplaces could filter/sort by health factor, collateral type, etc.
 * - Buyers can assess position risk/value directly from the NFT metadata
 */

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title NFTPosition
 * @dev NFT representation of perp positions with role-based access control and metadata support
 */
contract NFTPosition is ERC721URIStorage, AccessControl {
    using Strings for uint256;
    
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant METADATA_ROLE = keccak256("METADATA_ROLE");
    uint256 private _nextTokenId = 1;
    
    // Base URI for generating default token URIs
    string public baseURI;

    constructor(string memory name, string memory symbol) ERC721(name, symbol) {
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /**
     * @dev Mints a new position NFT to the given address
     * @param to The address that will own the minted token
     * @return The ID of the newly minted token
     */
    function mint(address to) external onlyRole(MINTER_ROLE) returns (uint256) {
        uint256 tokenId = _nextTokenId++;
        _safeMint(to, tokenId);
        return tokenId;
    }

    /**
     * @dev Burns a position NFT
     * @param tokenId The ID of the token to burn
     */
    function burn(uint256 tokenId) external onlyRole(MINTER_ROLE) {
        _burn(tokenId);
    }
    
    /**
     * @dev Sets the token URI for a specific position
     * @param tokenId The ID of the token
     * @param uri The new URI to set
     * @notice This function should be called when position metrics change significantly
     * The URI can point to static IPFS content or a dynamic API endpoint
     * For optimal gas efficiency, consider batching URI updates for multiple positions
     */
    function setTokenURI(uint256 tokenId, string calldata uri) external onlyRole(METADATA_ROLE) {
        _setTokenURI(tokenId, uri);
    }
    
    /**
     * @dev Sets the base URI for all tokens
     * @param newBaseURI The new base URI
     * @notice The base URI can point to:
     * - A server endpoint like https://api.example.com/positions/
     * - An IPFS gateway like ipfs://
     * - The token ID will be appended to this base URI
     */
    function setBaseURI(string calldata newBaseURI) external onlyRole(METADATA_ROLE) {
        baseURI = newBaseURI;
    }

    /**
     * @dev Returns the base URI for token metadata
     */
    function _baseURI() internal view override returns (string memory) {
        return baseURI;
    }

    /**
     * @dev Get the owner of a position
     * @param tokenId The ID of the position
     * @return The address of the owner
     */
    function positionOwner(uint256 tokenId) external view returns (address) {
        return ownerOf(tokenId);
    }

    /**
     * @dev Get the URI of a position
     * @param tokenId The ID of the position
     * @return The URI of the position
     * @notice This returns the URI where position metadata is stored
     * External systems should fetch this URI to get position details
     */
    function positionURI(uint256 tokenId) external view returns (string memory) {
        return tokenURI(tokenId);
    }

    /**
     * @dev Get all positions owned by a given address
     * @param owner The address to check
     * @return An array of token IDs owned by the address
     * @notice Useful for UIs to display all positions owned by a user
     * Can be used to build a "My Positions" dashboard
     */
    function positionsOf(address owner) external view returns (uint256[] memory) {
        uint256 balance = balanceOf(owner);
        uint256[] memory tokenIds = new uint256[](balance);
        
        for (uint256 i = 0; i < balance; i++) {
            tokenIds[i] = tokenOfOwnerByIndex(owner, i);
        }
        
        return tokenIds;
    }

    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public view override(ERC721URIStorage, AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
} 