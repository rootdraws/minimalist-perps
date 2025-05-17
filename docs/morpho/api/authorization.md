# Authorization System

## Core Functions

```solidity
function setAuthorization(address authorized, bool isAuthorized) external;
function setAuthorizationWithSig(Authorization calldata authorization, Signature calldata signature) external;
function isAuthorized(address authorizer, address authorized) external view returns (bool);
function nonce(address authorizer) external view returns (uint256);
function DOMAIN_SEPARATOR() external view returns (bytes32);
```

## Data Structures

```solidity
// Authorization data for signature-based approvals
struct Authorization {
    address authorizer;    // Address giving permission
    address authorized;    // Address receiving permission
    bool isAuthorized;     // Whether to authorize or revoke
    uint256 nonce;         // Unique nonce to prevent replay
    uint256 deadline;      // Timestamp until which the signature is valid
}

// EIP-712 signature components
struct Signature {
    uint8 v;
    bytes32 r;
    bytes32 s;
}
```

## Implementation

```solidity
// State variables for authorization tracking
mapping(address => mapping(address => bool)) private _isAuthorized;
mapping(address => uint256) private _nonces;
bytes32 public immutable DOMAIN_SEPARATOR;

// Simple direct authorization
function setAuthorization(address authorized, bool isAuthorized) external {
    // Prevent redundant authorizations
    if (_isAuthorized[msg.sender][authorized] == isAuthorized) {
        revert AlreadySet(isAuthorized);
    }
    
    // Update authorization status
    _isAuthorized[msg.sender][authorized] = isAuthorized;
    
    emit AuthorizationSet(msg.sender, authorized, isAuthorized);
}

// Signature-based authorization
function setAuthorizationWithSig(
    Authorization calldata authorization,
    Signature calldata signature
) external {
    // Check authorization deadline
    if (block.timestamp > authorization.deadline) {
        revert SignatureExpired(authorization.deadline);
    }
    
    // Verify nonce
    if (authorization.nonce != _nonces[authorization.authorizer]) {
        revert InvalidNonce(authorization.nonce, _nonces[authorization.authorizer]);
    }
    
    // Construct EIP-712 digest
    bytes32 digest = keccak256(
        abi.encodePacked(
            "\x19\x01",
            DOMAIN_SEPARATOR,
            keccak256(
                abi.encode(
                    keccak256("Authorization(address authorizer,address authorized,bool isAuthorized,uint256 nonce,uint256 deadline)"),
                    authorization.authorizer,
                    authorization.authorized,
                    authorization.isAuthorized,
                    authorization.nonce,
                    authorization.deadline
                )
            )
        )
    );
    
    // Recover signer and verify
    address recoveredAddress = ecrecover(digest, signature.v, signature.r, signature.s);
    if (recoveredAddress == address(0) || recoveredAddress != authorization.authorizer) {
        revert InvalidSignature();
    }
    
    // Increment nonce
    _nonces[authorization.authorizer]++;
    
    // Update authorization
    _isAuthorized[authorization.authorizer][authorization.authorized] = authorization.isAuthorized;
    
    emit AuthorizationSet(
        authorization.authorizer,
        authorization.authorized,
        authorization.isAuthorized
    );
}

// Check if an address is authorized
function isAuthorized(address authorizer, address authorized) external view returns (bool) {
    return authorizer == authorized || _isAuthorized[authorizer][authorized];
}
```

## Integration with Position Management

```solidity
// Position modifiers using authorization
modifier onlyPositionOwnerOrAuthorized(uint256 positionId) {
    address owner = _ownerOf(positionId);
    if (msg.sender != owner && !morpho.isAuthorized(owner, msg.sender)) {
        revert NotAuthorized(msg.sender, positionId);
    }
    _;
}

// Position modification with authorization check
function adjustPosition(
    uint256 positionId, 
    uint256 newLeverage
) external nonReentrant onlyPositionOwnerOrAuthorized(positionId) {
    // Position adjustment logic
    // ...
}

// Signature-based position management
function adjustPositionWithSig(
    uint256 positionId,
    uint256 newLeverage,
    Authorization calldata authorization,
    Signature calldata signature
) external nonReentrant {
    // Verify authorization
    address owner = _ownerOf(positionId);
    if (authorization.authorizer != owner) {
        revert NotPositionOwner(authorization.authorizer, positionId);
    }
    
    // Use morpho to verify signature
    if (!_verifyAuthorizationSignature(authorization, signature)) {
        revert InvalidSignature();
    }
    
    // Position adjustment logic
    // ...
}
```

## Advanced Features

```solidity
// Grant time-limited authorization to automated strategies
function authorizeStrategyUntil(
    address strategy, 
    uint256 expiryTime
) external {
    if (expiryTime <= block.timestamp) revert InvalidDeadline(expiryTime);
    
    _temporaryAuthorizations[msg.sender][strategy] = expiryTime;
    emit TemporaryAuthorizationSet(msg.sender, strategy, expiryTime);
}

// Time-limited authorization check
function isStrategyAuthorized(
    address owner, 
    address strategy
) public view returns (bool) {
    uint256 expiry = _temporaryAuthorizations[owner][strategy];
    return expiry > block.timestamp;
}

// DeFi position management integration
function executeStrategy(
    uint256 positionId,
    bytes calldata strategyData
) external nonReentrant {
    address owner = _ownerOf(positionId);
    
    // Check for valid strategy authorization
    if (!isStrategyAuthorized(owner, msg.sender)) {
        revert StrategyNotAuthorized(msg.sender);
    }
    
    // Execute strategy logic
    // ...
}
```

## Error Handling

```solidity
// Custom errors
error AlreadySet(bool currentValue);
error InvalidSignature();
error SignatureExpired(uint256 deadline);
error InvalidNonce(uint256 providedNonce, uint256 currentNonce);
error NotAuthorized(address caller, uint256 positionId);
error NotPositionOwner(address caller, uint256 positionId);
error InvalidDeadline(uint256 deadline);
error StrategyNotAuthorized(address strategy);

// Events
event AuthorizationSet(address indexed authorizer, address indexed authorized, bool isAuthorized);
event TemporaryAuthorizationSet(address indexed authorizer, address indexed strategy, uint256 expiry);
```

## Front-end Integration

```typescript
// Create signature for authorization
async function createAuthorizationSignature(
  signer: ethers.Signer,
  authorizedAddress: string,
  isAuthorized: boolean,
  deadline: number = Math.floor(Date.now() / 1000) + 3600 // 1 hour from now
): Promise<{ authorization: Authorization, signature: Signature }> {
  const authorizer = await signer.getAddress();
  const contract = new ethers.Contract(PERPS_CONTRACT_ADDRESS, MinimalistPerpsABI, signer);
  
  // Get current nonce
  const nonce = await contract.nonce(authorizer);
  
  // Create authorization object
  const authorization = {
    authorizer,
    authorized: authorizedAddress,
    isAuthorized,
    nonce: nonce.toString(),
    deadline: deadline.toString()
  };
  
  // Get domain data
  const domain = {
    name: 'MinimalistPerps',
    version: '1',
    chainId: await signer.getChainId(),
    verifyingContract: PERPS_CONTRACT_ADDRESS
  };
  
  // Define EIP-712 type
  const types = {
    Authorization: [
      { name: 'authorizer', type: 'address' },
      { name: 'authorized', type: 'address' },
      { name: 'isAuthorized', type: 'bool' },
      { name: 'nonce', type: 'uint256' },
      { name: 'deadline', type: 'uint256' }
    ]
  };
  
  // Sign the typed data
  const signature = await signer._signTypedData(domain, types, authorization);
  const { v, r, s } = ethers.utils.splitSignature(signature);
  
  return {
    authorization,
    signature: { v, r, s }
  };
}
``` 