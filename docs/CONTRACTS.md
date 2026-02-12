# Contract Reference

## Token Contracts

### StablecoinTemplateV3

Wrapped stablecoin with reserve ledger backing. Supports collateralization via wrapping/unwrapping.

**Inheritance:**
```
StablecoinTemplateV3
├── StablecoinTemplateV3Base
│   ├── ERC20Upgradeable
│   ├── AccessControlEnumerableUpgradeable
│   ├── PausableUpgradeable
│   ├── ERC20PermitUpgradeable
│   ├── UUPSUpgradeable
│   └── OwnableUpgradeable
```

**Immutables:**
| Name | Type | Description |
|------|------|-------------|
| `AUTH_REGISTRY` | `IAuthRegistry` | External policy registry |
| `RESERVE_LEDGER_ADDRESS` | `address` | Underlying reserve token |

**Storage (EIP-7201):**
```solidity
struct StablecoinTemplateV3Storage {
    mapping(address => bool) __DEPRECATED_blockedList;
    mapping(address => bool) __DEPRECATED_mintRecipientList;
    uint256 _maxSupply;
    uint8 _decimals;
    uint64 _transferPolicyId;
    uint64 _mintRecipientPolicyId;
    bool _migrationToWrappedCompleted;
}
```

**Key Functions:**
| Function | Access | Description |
|----------|--------|-------------|
| `mint(to, amount)` | `MINTER_ROLE` | Mint tokens (disabled after migration) |
| `burn(amount)` | `MINTER_ROLE` | Burn caller's tokens |
| `wrap(to, amount)` | Public | Deposit reserve, receive stablecoin |
| `unwrap(to, amount)` | `MINTER_ROLE` | Burn stablecoin, receive reserve |
| `burnFromBlockedAddress(addr)` | `BLOCKED_ADDRESS_BURNER_ROLE` | Force-liquidate blocked address |
| `completeMigrationToWrapped()` | `DEFAULT_ADMIN_ROLE` | Lock mint/burn, require full collateral |

**Events:**
```solidity
event Wrapped(address indexed account, address indexed to, uint256 amount);
event Unwrapped(address indexed account, address indexed to, uint256 amount);
event BurnedFromBlockedAddress(address indexed burner, address indexed blockedAddress, uint256 amount);
```

---

### ReserveLedger

Simple stablecoin without wrapping capability. Direct mint/burn only.

**Inheritance:**
```
ReserveLedger
└── StablecoinTemplateV3Base
```

**Key Functions:**
| Function | Access | Description |
|----------|--------|-------------|
| `mint(to, amount)` | `MINTER_ROLE` | Mint tokens |
| `burn(amount)` | `MINTER_ROLE` | Burn caller's tokens |

---

## Control Contracts

### TokenAuthority

Central control point for minting, burning, wrapping, and unwrapping with rate limiting.

**Immutables:**
| Name | Type | Description |
|------|------|-------------|
| `RESERVE_LEDGER_TOKEN` | `IERC20` | The reserve asset |

**Storage (EIP-7201):**
```solidity
struct TokenAuthorityStorage {
    mapping(address stablecoin => mapping(address minter => uint256)) minterAllowances;
    mapping(address stablecoin => uint256) mintTxnLimits;
    mapping(address stablecoin => address handler) tokenHandlers;
}
```

**Key Functions:**
| Function | Access | Description |
|----------|--------|-------------|
| `mint(stablecoin, to, amount)` | Allowance holder | Rate-limited mint |
| `mintBridgeEcosystem(stablecoin, to, amount)` | `BRIDGE_ECOSYSTEM_CONTRACT_ROLE` | Mint without limits |
| `burn(stablecoin, amount)` | `BURNER_ROLE` | Burn tokens |
| `wrap(stablecoin, to, amount)` | Public | Wrap reserve into stablecoin |
| `unwrap(stablecoin, to, amount)` | `UNWRAPPER_ROLE` | Unwrap stablecoin to reserve |
| `registerStablecoin(stablecoin, handler)` | `DEFAULT_ADMIN_ROLE` | Add stablecoin with handler |
| `setMinterAllowance(stablecoin, minter, amount)` | `MINT_RATE_LIMIT_SETTER_ROLE` | Set minter's allowance |
| `setMintTxnLimit(stablecoin, limit)` | `MINT_RATE_LIMIT_SETTER_ROLE` | Set per-tx limit |

**Events:**
```solidity
event Mint(address indexed stablecoin, address indexed to, uint256 amount);
event Burn(address indexed stablecoin, uint256 amount);
event Wrap(address indexed stablecoin, address indexed to, uint256 amount);
event Unwrap(address indexed stablecoin, address indexed to, uint256 amount);
event StablecoinRegistered(address indexed stablecoin, address indexed handler);
event StablecoinUnregistered(address indexed stablecoin);
event MinterAllowanceSet(address indexed stablecoin, address indexed minter, uint256 amount);
event MintTxnLimitSet(address indexed stablecoin, uint256 limit);
```

---

## Handler Contracts

### ITokenHandler (Interface)

```solidity
interface ITokenHandler {
    function mint(address stablecoin, address to, uint256 amount) external;
    function burn(address stablecoin, uint256 amount) external;
    function wrap(address stablecoin, address to, uint256 amount) external;
    function unwrap(address stablecoin, address to, uint256 amount) external;
}
```

---

### SingleTokenHandler

Simplest handler - no collateral management.

| Operation | Behavior |
|-----------|----------|
| `mint` | Direct mint on stablecoin |
| `burn` | Direct burn on stablecoin |
| `wrap` | Reverts with `NotSupported()` |
| `unwrap` | Reverts with `NotSupported()` |

---

### ReserveLedgerWrappedHandler

Collateral stored in the stablecoin contract itself.

**Immutables:**
| Name | Type | Description |
|------|------|-------------|
| `RESERVE_LEDGER` | `IReserveLedger` | Reserve token contract |
| `TOKEN_AUTHORITY` | `address` | Authorized caller |

| Operation | Behavior |
|-----------|----------|
| `mint` | Mint reserve to stablecoin, call `wrap()` |
| `burn` | Call stablecoin `unwrap()`, burn reserve |
| `wrap` | Transfer reserve to stablecoin, call `wrap()` |
| `unwrap` | Call stablecoin `unwrap()` |

---

### ReserveLedgerBackedHandler

Creates isolated `ReserveStore` per stablecoin for auditable reserves.

**Immutables:**
| Name | Type | Description |
|------|------|-------------|
| `RESERVE_LEDGER` | `IReserveLedger` | Reserve token contract |
| `TOKEN_AUTHORITY` | `address` | Authorized caller |

**Storage:**
```solidity
mapping(address stablecoin => address reserveStore) public reserveStores;
```

| Operation | Behavior |
|-----------|----------|
| `mint` | Create ReserveStore if needed, mint reserve to store, mint stablecoin |
| `burn` | Burn stablecoin, transfer reserve from store, burn reserve |
| `wrap` | Transfer reserve to store, mint stablecoin |
| `unwrap` | Burn stablecoin, transfer reserve from store to recipient |

---

### ReserveStore

Minimal contract holding reserve tokens for a single stablecoin.

**Immutables:**
| Name | Type | Description |
|------|------|-------------|
| `RESERVE_LEDGER` | `IERC20` | The collateral token |
| `CONTROLLER` | `address` | Handler that manages this store |
| `STABLECOIN` | `address` | The stablecoin this backs |

Pre-approves the controller for unlimited transfers on deployment.

---

## Custom Errors

```solidity
// Stablecoin errors
error AddressBlocked();
error MaxSupplyExceeded();
error AccountNotValidRecipient();
error AmountCannotBeZero();
error ReserveLedgerBalanceMismatch();
error MintingNotAllowed();

// TokenAuthority errors
error MinterAllowanceExceeded();
error MintTxnLimitExceeded();
error StablecoinNotRegistered();
error StablecoinAlreadyRegistered();
error InvalidHandler();

// Handler errors
error OnlyTokenAuthority();
error NotSupported();
```
