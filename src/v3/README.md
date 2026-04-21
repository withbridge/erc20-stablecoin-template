# Stablecoin Template V3

V3 introduces OpenZeppelin v5, EIP-7201 storage, and flexible deployment patterns.

## Changes from V2

- **OZ v5 Migration**
  - `AccessControlEnumerableUpgradeable` replaces `AccessControlUpgradeable`
  - `_update()` replaces `_beforeTokenTransfer()`
  - Custom errors replace string reverts
  - `setMaxSupply()` replaces `{increase,decrease}MaxSupply()`

- **EIP-7201 Storage Layout**
  - Namespaced storage prevents slot collisions during upgrades
  - Storage location: `keccak256("bridge.storage.StablecoinTemplateV3") - 1`

- **Deterministic Proxy Factory Support**
  - Deploy via CREATE2 for predictable addresses
  - BeaconProxy pattern: `UUPS → BeaconProxy → UpgradeableBeacon → Implementation`
  - Bridge manages upgrades via UpgradeableBeacon
  - Developers can assume ownership later

## Contract Structure

```
src/v3/
├── StablecoinTemplateV3Base.sol   # Abstract base with core functionality
├── StablecoinTemplateV3.sol       # Wrapped stablecoin implementation
├── ReserveLedger.sol              # Simple stablecoin (no wrapping)
├── TokenAuthority.sol             # Central control with rate limiting
├── handlers/
│   ├── ITokenHandler.sol          # Handler interface
│   ├── SingleTokenHandler.sol     # No collateral handler
│   ├── ReserveLedgerWrappedHandler.sol   # Inline collateral handler
│   └── ReserveLedgerBackedHandler.sol    # Isolated reserve handler
└── ReserveStore.sol               # Per-stablecoin collateral storage
```

See the [main documentation](../../docs/ARCHITECTURE.md) for detailed architecture and flow diagrams.
