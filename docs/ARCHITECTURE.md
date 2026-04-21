# Architecture Overview

Bridge's ERC20 stablecoin template provides upgrade-capable stablecoin tokens with sophisticated access control, minting rate limits, and flexible collateralization models.

## System Overview

```mermaid
graph TB
    subgraph "External"
        User[User/Operator]
        AuthReg[Auth Registry]
    end

    subgraph "Control Layer"
        TA[TokenAuthority]
    end

    subgraph "Handler Layer"
        IH[ITokenHandler]
        STH[SingleTokenHandler]
        RLWH[ReserveLedgerWrappedHandler]
        RLBH[ReserveLedgerBackedHandler]
    end

    subgraph "Token Layer"
        RL[ReserveLedger]
        SC[StablecoinTemplateV3]
        RS[ReserveStore]
    end

    User --> TA
    TA --> IH
    IH -.-> STH
    IH -.-> RLWH
    IH -.-> RLBH

    STH --> SC
    RLWH --> RL
    RLWH --> SC
    RLBH --> RL
    RLBH --> SC
    RLBH --> RS

    SC --> AuthReg
    RL --> AuthReg
```

## Component Relationships

### Core Contracts

| Contract | Purpose |
|----------|---------|
| `TokenAuthority` | Central control for minting, burning, wrapping, unwrapping with rate limiting |
| `StablecoinTemplateV3` | Wrapped stablecoin with reserve ledger backing |
| `ReserveLedger` | Simple stablecoin without wrapping capability |
| `ReserveStore` | Isolated collateral storage per stablecoin |

### Token Handlers

The system uses the Strategy pattern for flexible collateralization:

```mermaid
classDiagram
    class ITokenHandler {
        <<interface>>
        +mint(stablecoin, to, amount)
        +burn(stablecoin, amount)
        +wrap(stablecoin, to, amount)
        +unwrap(stablecoin, to, amount)
    }

    class SingleTokenHandler {
        +mint()
        +burn()
        +wrap() reverts
        +unwrap() reverts
    }

    class ReserveLedgerWrappedHandler {
        +mint()
        +burn()
        +wrap()
        +unwrap()
        -RESERVE_LEDGER
    }

    class ReserveLedgerBackedHandler {
        +mint()
        +burn()
        +wrap()
        +unwrap()
        +reserveStores mapping
        -RESERVE_LEDGER
    }

    ITokenHandler <|.. SingleTokenHandler
    ITokenHandler <|.. ReserveLedgerWrappedHandler
    ITokenHandler <|.. ReserveLedgerBackedHandler
```

| Handler | Collateral Model | Use Case |
|---------|-----------------|----------|
| `SingleTokenHandler` | No collateral | Simple tokens, direct mint/burn |
| `ReserveLedgerWrappedHandler` | Stored in stablecoin contract | Compact collateral model |
| `ReserveLedgerBackedHandler` | Isolated `ReserveStore` per token | Auditable, reconcilable reserves |

## Upgrade Architecture

The system uses UUPS (Universal Upgradeable Proxy Standard) with optional BeaconProxy support:

```mermaid
graph TB
    subgraph "Standard UUPS"
        Proxy1[UUPS Proxy] --> Impl1[Implementation]
    end

    subgraph "BeaconProxy Pattern"
        BP1[BeaconProxy] --> IB[Immutable Beacon]
        BP2[BeaconProxy] --> IB
        BP3[BeaconProxy] --> IB
        IB --> UB[UpgradeableBeacon]
        UB --> Impl2[Implementation]
    end
```

The BeaconProxy pattern enables:
- Deterministic deployment via Deterministic Proxy Factory
- Centralized upgrades across all tokens on a chain
- Optional handoff of upgrade authority to token owners

## Storage Layout (EIP-7201)

All contracts use EIP-7201 namespaced storage to prevent slot collisions during upgrades:

```solidity
// Storage namespace for StablecoinTemplateV3
keccak256("bridge.storage.StablecoinTemplateV3") - 1

// Storage namespace for TokenAuthority
keccak256("bridge.storage.TokenAuthority") - 1
```

## External Dependencies

- **Auth Registry**: External policy-based access control for transfers and minting
- **OpenZeppelin Contracts v5.3.0**: Base implementations for ERC20, AccessControl, Pausable, UUPS
- **Deterministic Proxy Factory**: CREATE2-based deterministic deployments
