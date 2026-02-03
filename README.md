# ERC20 Stablecoin Template

Bridge's ERC20 stablecoin implementation with upgrade-capable tokens, sophisticated access control, minting rate limits, and flexible collateralization models.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                         TokenAuthority                              │
│         (Rate-limited minting, burning, wrapping, unwrapping)       │
└──────────────────────────────┬──────────────────────────────────────┘
                               │
              ┌────────────────┼────────────────┐
              │                │                │
              ▼                ▼                ▼
┌─────────────────┐  ┌─────────────────┐  ┌─────────────────────────┐
│ SingleToken     │  │ ReserveLedger   │  │ ReserveLedgerBacked     │
│ Handler         │  │ WrappedHandler  │  │ Handler                 │
│ (No collateral) │  │ (Inline reserve)│  │ (Isolated ReserveStore) │
└────────┬────────┘  └────────┬────────┘  └────────────┬────────────┘
         │                    │                        │
         ▼                    ▼                        ▼
┌─────────────────┐  ┌─────────────────┐  ┌─────────────────────────┐
│  Stablecoin     │  │  ReserveLedger  │  │  Stablecoin + Reserve   │
│                 │  │  + Stablecoin   │  │  Store                  │
└─────────────────┘  └─────────────────┘  └─────────────────────────┘
```

## Features

- **Upgradeable**: UUPS proxy pattern with optional BeaconProxy support
- **Rate Limiting**: Per-minter allowances and per-transaction limits
- **Flexible Collateralization**: Three handler strategies for different use cases
- **Access Control**: Role-based permissions with Auth Registry integration
- **Compliance**: Blocklist support with force-liquidation capability
- **EIP-7201**: Namespaced storage for safe upgrades

## Quick Start

```bash
# Install dependencies
forge soldeer install

# Build
forge build

# Test
forge test

# Or use just
just build
just test
```

## Documentation

| Document | Description |
|----------|-------------|
| [Architecture](docs/ARCHITECTURE.md) | System overview and component relationships |
| [Operation Flows](docs/FLOWS.md) | Sequence diagrams for mint, burn, wrap, unwrap |
| [Access Control](docs/ACCESS_CONTROL.md) | Roles, permissions, and rate limiting |
| [Contract Reference](docs/CONTRACTS.md) | Detailed contract API documentation |

## Key Contracts

| Contract | Purpose |
|----------|---------|
| `TokenAuthority` | Central control with rate limiting |
| `StablecoinTemplateV3` | Wrapped stablecoin with reserve backing |
| `ReserveLedger` | Simple stablecoin without wrapping |
| `SingleTokenHandler` | Handler for non-collateralized tokens |
| `ReserveLedgerWrappedHandler` | Handler with inline collateral |
| `ReserveLedgerBackedHandler` | Handler with isolated reserve stores |

## License

MIT License - see [LICENSE](LICENSE) file for details.
