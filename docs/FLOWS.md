# Operation Flows

## Minting

### Via TokenAuthority (Rate-Limited)

```mermaid
sequenceDiagram
    participant User
    participant TA as TokenAuthority
    participant Handler as ITokenHandler
    participant RL as ReserveLedger
    participant SC as Stablecoin

    User->>TA: mint(stablecoin, to, amount)
    TA->>TA: Check minter allowance
    TA->>TA: Check txn limit
    TA->>TA: Decrement allowance
    TA->>Handler: mint(stablecoin, to, amount)

    alt SingleTokenHandler
        Handler->>SC: mint(to, amount)
    else ReserveLedgerBackedHandler
        Handler->>Handler: Get/create ReserveStore
        Handler->>RL: mint(reserveStore, amount)
        Handler->>SC: mint(to, amount)
    else ReserveLedgerWrappedHandler
        Handler->>RL: mint(stablecoin, amount)
        Handler->>SC: wrap(to, amount)
    end

    TA-->>User: Emit Mint event
```

### Bridge Ecosystem Mint (No Rate Limit)

Trusted contracts with `BRIDGE_ECOSYSTEM_CONTRACT_ROLE` bypass rate limits:

```mermaid
sequenceDiagram
    participant Trusted as Bridge Contract
    participant TA as TokenAuthority
    participant Handler as ITokenHandler
    participant SC as Stablecoin

    Trusted->>TA: mintBridgeEcosystem(stablecoin, to, amount)
    Note over TA: No allowance/limit checks
    TA->>Handler: mint(stablecoin, to, amount)
    Handler->>SC: mint(to, amount)
    TA-->>Trusted: Emit Mint event
```

## Burning

```mermaid
sequenceDiagram
    participant User
    participant TA as TokenAuthority
    participant Handler as ITokenHandler
    participant SC as Stablecoin
    participant RL as ReserveLedger
    participant RS as ReserveStore

    User->>TA: burn(stablecoin, amount)
    Note over User: Must have BURNER_ROLE
    TA->>SC: transferFrom(user, tokenAuthority, amount)
    TA->>SC: approve(handler, amount)
    TA->>Handler: burn(stablecoin, amount)

    alt SingleTokenHandler
        Handler->>SC: burn(amount)
    else ReserveLedgerBackedHandler
        Handler->>SC: burn(amount)
        Handler->>RS: transfer reserve to handler
        Handler->>RL: burn(amount)
    else ReserveLedgerWrappedHandler
        Handler->>SC: unwrap(handler, amount)
        Handler->>RL: burn(amount)
    end

    TA-->>User: Emit Burn event
```

## Wrapping (Deposit Reserve → Get Stablecoin)

```mermaid
sequenceDiagram
    participant User
    participant TA as TokenAuthority
    participant Handler as ITokenHandler
    participant RL as ReserveLedger
    participant SC as Stablecoin
    participant RS as ReserveStore

    User->>TA: wrap(stablecoin, to, amount)
    TA->>RL: transferFrom(user, tokenAuthority, amount)
    TA->>RL: approve(handler, amount)
    TA->>Handler: wrap(stablecoin, to, amount)

    alt ReserveLedgerBackedHandler
        Handler->>RL: transfer to ReserveStore
        Handler->>SC: mint(to, amount)
    else ReserveLedgerWrappedHandler
        Handler->>RL: transfer to stablecoin
        Handler->>SC: wrap(to, amount)
    end

    TA-->>User: Emit Wrap event
```

### Direct Wrapping (No TokenAuthority)

```mermaid
sequenceDiagram
    participant User
    participant SC as StablecoinTemplateV3
    participant RL as ReserveLedger
    participant AR as AuthRegistry

    User->>SC: wrap(recipient, amount)
    SC->>AR: isValidMintRecipient(recipient)
    AR-->>SC: true
    SC->>RL: transferFrom(user, stablecoin, amount)
    SC->>SC: _mint(recipient, amount)
    SC-->>User: Emit Wrapped event
```

## Unwrapping (Burn Stablecoin → Get Reserve)

```mermaid
sequenceDiagram
    participant User
    participant TA as TokenAuthority
    participant Handler as ITokenHandler
    participant SC as Stablecoin
    participant RL as ReserveLedger
    participant RS as ReserveStore

    User->>TA: unwrap(stablecoin, to, amount)
    Note over User: Must have UNWRAPPER_ROLE
    TA->>SC: transferFrom(user, tokenAuthority, amount)
    TA->>SC: approve(handler, amount)
    TA->>Handler: unwrap(stablecoin, to, amount)

    alt ReserveLedgerBackedHandler
        Handler->>SC: burn(amount)
        Handler->>RS: transfer reserve to recipient
    else ReserveLedgerWrappedHandler
        Handler->>SC: unwrap(to, amount)
    end

    TA-->>User: Emit Unwrap event
```

## Burning From Blocked Address

Allows force-liquidation of sanctioned addresses:

```mermaid
sequenceDiagram
    participant Admin
    participant SC as StablecoinTemplateV3
    participant AR as AuthRegistry
    participant RL as ReserveLedger

    Admin->>SC: burnFromBlockedAddress(blockedAddr)
    Note over Admin: Must have BLOCKED_ADDRESS_BURNER_ROLE
    SC->>AR: isBlocked(blockedAddr)
    AR-->>SC: true

    SC->>SC: Store temporary unblock (tstore)
    SC->>SC: _burn(blockedAddr, balance)
    SC->>RL: transfer(admin, balance)
    SC->>SC: Clear temporary unblock

    SC-->>Admin: Emit BurnedFromBlockedAddress
```

## Migration to Wrapped

Transition from credit-based to fully-collateralized model:

```mermaid
stateDiagram-v2
    [*] --> DirectMinting: Initial State

    DirectMinting --> GradualWrapping: Users wrap reserves
    note right of DirectMinting: mint() and burn() enabled

    GradualWrapping --> FullyWrapped: completeMigrationToWrapped()
    note right of GradualWrapping: Building reserve backing

    FullyWrapped --> [*]
    note right of FullyWrapped
        mint() disabled
        burn() disabled
        Only wrap/unwrap
    end note
```

Requirements for migration:
1. `RESERVE_LEDGER` balance must equal total supply (full collateralization)
2. Only admin can trigger migration
3. Irreversible once completed
