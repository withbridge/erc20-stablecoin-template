# Access Control

## Role Hierarchy

```mermaid
graph TB
    subgraph "Stablecoin Roles"
        DA[DEFAULT_ADMIN_ROLE]
        M[MINTER_ROLE]
        P[PAUSER_ROLE]
        UP[UNPAUSER_ROLE]
        BAB[BLOCKED_ADDRESS_BURNER_ROLE]
        UW[UNWRAPPER_ROLE]
    end

    subgraph "TokenAuthority Roles"
        TA_DA[DEFAULT_ADMIN_ROLE]
        MRLS[MINT_RATE_LIMIT_SETTER_ROLE]
        B[BURNER_ROLE]
        TA_UW[UNWRAPPER_ROLE]
        BEC[BRIDGE_ECOSYSTEM_CONTRACT_ROLE]
        THS[TOKEN_AUTHORITY_HANDLER_SETTER_ROLE]
    end

    DA --> M
    DA --> P
    DA --> UP
    DA --> BAB
    DA --> UW

    TA_DA --> MRLS
    TA_DA --> B
    TA_DA --> TA_UW
    TA_DA --> BEC
    TA_DA --> THS
```

## Stablecoin Roles

### `DEFAULT_ADMIN_ROLE`
Full administrative control over the stablecoin.

| Permission | Function |
|------------|----------|
| Set max supply | `setMaxSupply(uint256)` |
| Set transfer policy | `setTransferPolicyId(uint64)` |
| Set mint recipient policy | `setMintRecipientPolicyId(uint64)` |
| Complete migration | `completeMigrationToWrapped()` |
| Upgrade implementation | `upgradeToAndCall(address, bytes)` |
| Manage roles | `grantRole()`, `revokeRole()` |

### `MINTER_ROLE`
Token minting and burning operations.

| Permission | Function |
|------------|----------|
| Mint tokens | `mint(address, uint256)` |
| Burn tokens | `burn(uint256)` |
| Unwrap tokens | `unwrap(address, uint256)` |

Note: `mint()` is disabled after `completeMigrationToWrapped()` is called.

### `PAUSER_ROLE`
Emergency pause capability.

| Permission | Function |
|------------|----------|
| Pause transfers | `pause()` |

### `UNPAUSER_ROLE`
Resume normal operations.

| Permission | Function |
|------------|----------|
| Unpause transfers | `unpause()` |

### `BLOCKED_ADDRESS_BURNER_ROLE`
Force-liquidate blocked addresses.

| Permission | Function |
|------------|----------|
| Burn blocked balances | `burnFromBlockedAddress(address)` |

### `UNWRAPPER_ROLE`
Convert stablecoins back to reserve tokens.

| Permission | Function |
|------------|----------|
| Unwrap tokens | `unwrap(address, uint256)` |

## TokenAuthority Roles

### `DEFAULT_ADMIN_ROLE`
Full administrative control over TokenAuthority.

| Permission | Function |
|------------|----------|
| Register stablecoins | `registerStablecoin(address, address)` |
| Unregister stablecoins | `unregisterStablecoin(address)` |
| Manage roles | `grantRole()`, `revokeRole()` |
| Upgrade implementation | `upgradeToAndCall(address, bytes)` |

### `MINT_RATE_LIMIT_SETTER_ROLE`
Configure minting rate limits.

| Permission | Function |
|------------|----------|
| Set minter allowance | `setMinterAllowance(address, address, uint256)` |
| Set transaction limit | `setMintTxnLimit(address, uint256)` |

### `BURNER_ROLE`
Initiate token burns through TokenAuthority.

| Permission | Function |
|------------|----------|
| Burn tokens | `burn(address, uint256)` |

### `UNWRAPPER_ROLE`
Initiate unwrapping through TokenAuthority.

| Permission | Function |
|------------|----------|
| Unwrap tokens | `unwrap(address, address, uint256)` |

### `BRIDGE_ECOSYSTEM_CONTRACT_ROLE`
Trusted contracts that bypass rate limits.

| Permission | Function |
|------------|----------|
| Mint without limits | `mintBridgeEcosystem(address, address, uint256)` |

### `TOKEN_AUTHORITY_HANDLER_SETTER_ROLE`
Configure token handlers.

| Permission | Function |
|------------|----------|
| Set handler | `setTokenHandler(address, address)` |

## Rate Limiting

TokenAuthority enforces three-level rate limiting for minting:

```mermaid
graph LR
    subgraph "Rate Limit Checks"
        A[Minter Allowance] --> B[Transaction Limit]
        B --> C[Mint Executed]
    end

    style A fill:#f9f,stroke:#333
    style B fill:#bbf,stroke:#333
    style C fill:#bfb,stroke:#333
```

| Level | Scope | Configuration |
|-------|-------|---------------|
| Minter Allowance | Per-user, per-stablecoin | Decrements with each mint |
| Transaction Limit | Per-stablecoin | Max amount per mint call |

## Auth Registry Integration

External policy-based access control:

```mermaid
graph LR
    Transfer[Transfer Request] --> AR{Auth Registry}
    Mint[Mint Request] --> AR
    AR -->|transferPolicyId| TP[Transfer Policy Check]
    AR -->|mintRecipientPolicyId| MP[Mint Recipient Check]
    TP --> Allow/Block
    MP --> Allow/Block
```

| Policy | Purpose |
|--------|---------|
| `transferPolicyId` | Validates sender/recipient for transfers |
| `mintRecipientPolicyId` | Validates recipients for minting |

Blocked addresses cannot send or receive tokens. The `burnFromBlockedAddress()` function uses transient storage to temporarily bypass this restriction during force-liquidation.
