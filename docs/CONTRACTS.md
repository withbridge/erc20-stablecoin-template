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
| `forceTransfer(from, to, amount)` | `FORCE_TRANSFER_ROLE` | Move coins out of a blocked `from`, past the freeze and pause checks (seize) |
| `completeMigrationToWrapped()` | `DEFAULT_ADMIN_ROLE` | Lock mint/burn, require full collateral |

**Events:**
```solidity
event Wrapped(address indexed account, address indexed to, uint256 amount);
event Unwrapped(address indexed account, address indexed to, uint256 amount);
event BurnedFromBlockedAddress(address indexed burner, address indexed blockedAddress, uint256 amount);
event ForceTransferred(uint256 amount, address indexed from, address indexed to, address indexed sender);
```

`forceTransfer` requires `from` blocked, `to` not blocked, and a non-zero amount. It sets two transient flags (`bridge.TemporaryUnblock` and `bridge.TemporaryPauseBypass`) for the single `_transfer` and clears them before returning, so every other transfer in the same transaction is still gated. No persistent storage is added. `ReserveLedger` does not expose it.

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

**Inheritance:**
```
TokenAuthority
├── AccessControlEnumerableUpgradeable
├── UUPSUpgradeable
├── MintIntent            (forwards to the shared MintIntentRegistry)
└── Seize                 (shared seize rules; see Seize below)
```

**Immutables:**
| Name | Type | Description |
|------|------|-------------|
| `RESERVE_LEDGER_TOKEN` | `address` | The reserve asset |
| `ABSOLUTE_MAX` | `uint256` | Hard cap on any single amount (`1_000_000_000 * 1e6`) |

**Storage (sequential slots — append only):**
```solidity
mapping(address stablecoin => mapping(address minter => uint256)) minterAllowances; // slot 0
mapping(address stablecoin => uint256) mintTxnLimits;                              // slot 1
mapping(address stablecoin => address handler) tokenHandlers;                      // slot 2
MintIntentVersion public mintIntentVersion;                                        // slot 3
mapping(address stablecoin => bool) public stablecoinIsPaused;                     // slot 4
IMintIntentRegistry public mintIntentRegistry;                                     // slot 5
mapping(address stablecoin => SeizeConfig) seizeConfigs;                           // slot 6 (seize handler + list)
```

Mint intent state is *not* stored here — it lives in the shared [`MintIntentRegistry`](#mintintentregistry). New variables must be appended, since this contract sits behind a UUPS proxy.

**Key Functions:**
| Function | Access | Description |
|----------|--------|-------------|
| `mint(stablecoin, to, amount)` | Allowance holder | Rate-limited mint (only when `mintIntentVersion == Optional`) |
| `mintWithApproval(params)` | Allowance holder | Rate-limited mint that consumes a published intent |
| `mintBridgeEcosystem(stablecoin, to, amount)` | `BRIDGE_ECOSYSTEM_CONTRACT_ROLE` | Mint without limits |
| `burn(stablecoin, amount)` | `BURNER_ROLE` | Burn tokens |
| `burnWithOperationId(stablecoin, amount, operationId)` | `BURNER_ROLE` | Burn, consuming a globally single-use operation ID |
| `wrap(stablecoin, to, amount)` | Public | Wrap reserve into stablecoin |
| `unwrap(stablecoin, amount)` | `UNWRAPPER_ROLE` | Unwrap stablecoin to reserve |
| `registerStablecoin(stablecoin, handler, mintTxnLimit)` | `DEFAULT_ADMIN_ROLE` | Add stablecoin with handler |
| `unregisterStablecoin(stablecoin)` | `TOKEN_AUTHORITY_HANDLER_SETTER_ROLE` | Remove stablecoin |
| `setTokenHandler(stablecoin, handler)` | `TOKEN_AUTHORITY_HANDLER_SETTER_ROLE` | Swap handler (stablecoin must be paused) |
| `setMinterAllowance(stablecoin, minter, amount)` | `MINT_RATE_LIMIT_SETTER_ROLE` | Set minter's allowance |
| `setTxnMintLimit(stablecoin, limit)` | `MINT_RATE_LIMIT_SETTER_ROLE` | Set per-tx limit |
| `setStablecoinPaused(stablecoin, pause)` | `STABLECOIN_PAUSER_ROLE` | Pause/unpause a stablecoin |
| `setMintIntentVersion(version)` | `DEFAULT_ADMIN_ROLE` | Make mint intents `Optional` or `Required` |
| `setMintIntentRegistry(registry)` | `DEFAULT_ADMIN_ROLE` | Migrate to a different shared registry |
| `seize(stablecoin, from, to, amount)` | `SEIZER_ROLE` | Seize from a frozen holder (see Seize below) |
| `setSeizeConfig(stablecoin, seizeHandler, registry, listId)` | `DEFAULT_ADMIN_ROLE` | Set or clear (zero seize handler) a stablecoin's seize settings |
| `getSeizeConfig(stablecoin)` | Public | Read a stablecoin's seize settings |

Intent lifecycle functions inherited from `MintIntent` — `publishApproval`, `revokeApproval`, `revokeOperationId`, `extendApproval` (all `PUBLISHER_ROLE`) and `getApproval` — forward to the shared registry.

**Events:**
```solidity
event Mint(address indexed sender, address indexed stablecoinContract, address indexed to, uint256 amount);
event Burn(address indexed sender, address indexed stablecoinContract, uint256 amount);
event Wrap(address indexed sender, address indexed stablecoinContract, address indexed to, uint256 amount);
event Unwrap(address indexed sender, address indexed stablecoinContract, uint256 amount);
event StablecoinRegistered(address indexed sender, address indexed stablecoinContract, address indexed tokenHandler, uint256 mintTxnLimit);
event StablecoinUnregistered(address indexed sender, address indexed stablecoinContract);
event MinterAllowanceSet(address indexed sender, address indexed stablecoinContract, address indexed minter, uint256 minterAllowance);
event TxnMintLimitSet(address indexed sender, address indexed stablecoinContract, uint256 mintTxnLimit);
event TokenHandlerSet(address indexed sender, address indexed stablecoinContract, address indexed tokenHandler);
event StablecoinPauseSet(address indexed sender, address indexed stablecoinContract, bool isPaused);
event MintIntentVersionSet(address indexed sender, MintIntentVersion mintIntentVersion);
event SeizeConfigSet(address indexed sender, address indexed stablecoinContract, address indexed seizeHandler, address seizureWalletRegistry, uint64 seizureWalletListId);
event Seized(address indexed stablecoinContract, address indexed from, address indexed to, uint256 amount, address caller);
```

---

### Seize (`TokenAuthority` and `TIP20Controller`)

Moves a frozen holder's coins into an approved Seizure Wallet without changing supply or reserve backing. Both controllers inherit the abstract `Seize` base (`src/seize/Seize.sol`) and the `ISeize` interface, so the function, role, event and errors are byte-identical on each.

**Every seize** (`seize(stablecoin, from, to, amount)`, `SEIZER_ROLE`):
1. The stablecoin has seize settings, otherwise `SeizeNotConfigured`.
2. `to` is neither `from` nor the controller, and is authorized on the Seizure Wallet list (`isAuthorized(listId, to)`).
3. `from` is frozen on the stablecoin.
4. `0 < amount <= balanceOf(from)`.
5. After the move, the base asserts: `from` lost exactly `amount`, `to` gained exactly `amount`, the controller's own balance and the stablecoin's `totalSupply` are unchanged, the pause state is restored, and `from` is still frozen.

It ignores the controller's own `setStablecoinPaused`, which halts issuance, not compliance actions. It never goes through a token handler or the reserve-minting path.

**How coins move:**

| Controller | Moved by | Move |
|---|---|---|
| `TokenAuthority` | the stablecoin's **seize handler** (see below) | `TokenAuthority` stays a pass-through, like `mint`: it enforces the rules above and calls `seizeHandler.seize(...)` |
| `TIP20Controller` | the controller itself | Unpause if paused → `burnAt(from, amount)` → the coin's own `mint(to, amount)` → re-pause |

On `TokenAuthority`, the seize handler is also refused as a destination, because it can't move coins on.

**Seizure Wallet list validation** (setters): the registry is non-zero, the list ID is not a built-in (`0` always-reject, `1` always-allow), and the list does not authorize the controller itself (this rejects allow-all and blacklist-type lists). `setSeizeConfig` also requires the seize handler to implement `ISeizeHandler` (ERC165), the same check `setTokenHandler` applies to token handlers.

**Roles each stablecoin grants for seize** (granted by the stablecoin's admin during setup, not by the upgrade):

| Stablecoin | Granted to | Roles / lists |
|---|---|---|
| `StablecoinTemplateV3` | `ForceTransferSeizeHandler` | `FORCE_TRANSFER_ROLE` |
| `StablecoinTemplateV2` | `BurnAndRemintSeizeHandler` | `BLOCKED_ADDRESS_BURNER_ROLE`, `MINTER_ROLE`, `UNBLOCKER_ROLE`, `BLOCKER_ROLE`, `PAUSER_ROLE`, `UNPAUSER_ROLE`; `addMintRecipient` for the Seizure Wallet and the seize handler |
| TIP-20 | `TIP20Controller` | `BURN_AT_ROLE` (T12+), `PAUSE_ROLE`, `UNPAUSE_ROLE`, plus the existing `ISSUER_ROLE`. The Seizure Wallet must be authorized under the coin's TIP-403 transfer policy, because TIP-20 `mint` checks the recipient. |

**`TIP20Controller` additions:**

| Item | Detail |
|---|---|
| `seizureWalletPolicyId()` | TIP-403 policy listing the Seizure Wallets for every coin on this controller. `0` means seize is disabled. Returns `uint256` (always fits a `uint64` TIP-403 ID). Storage slot 6, after `mintIntentRegistry`. |
| `setSeizureWalletPolicyId(policyId)` | `DEFAULT_ADMIN_ROLE`. `0` disables seize; any other value is validated as above against the TIP-403 registry. |
| `event SeizureWalletPolicyIdSet(address indexed sender, uint64 policyId)` | |

**Selectors and topics** (monorail, Fireblocks rules and monitoring key on these):

| Kind | Signature | Selector / topic |
|---|---|---|
| Function | `seize(address,address,address,uint256)` | `0xacb82dec` |
| Function | `SEIZER_ROLE()` | `0x421a40a7` (value `0xe770a2b882b0a3a025be15ffce2d5d54f5d719264e701933268dd62f79db677f`) |
| Function | `setSeizeConfig(address,address,address,uint64)` | `0xcc9544c9` |
| Function | `getSeizeConfig(address)` | `0xc37f4761` |
| Function | `setSeizureWalletPolicyId(uint64)` | `0x798953e0` |
| Function | `seizureWalletPolicyId()` | `0xd51c6560` |
| Function | `forceTransfer(address,address,uint256)` | `0x33bebb77` |
| Function | `FORCE_TRANSFER_ROLE()` | `0xede3fc8c` (value `0xf03e19c53afadaa67869d28def12770ead62d3b7112af11002e6f2f27cd92391`) |
| Event | `Seized(address,address,address,uint256,address)` | `0x61cfce727addc1ab55f91beabbd27489a8558f075cf83922e12818b77b8aa704` |
| Event | `SeizeConfigSet(address,address,address,address,uint64)` | `0xc37b38cd3126e8b69eb3f8dd58ec3eaf29cfee4b2e564cd52ee3806de2254ae6` |
| Function (seize handler) | `seize(address,address,address,uint256,uint256)` | `0x17cde087` |
| Event (seize handler) | `Seized(address,address,address,uint256)` | `0xa9aec5d8b86e2fa2fd6ac3af62f2622e3dfdab1967d4cbbb56a5df7d74cb887c` |
| Event | `SeizureWalletPolicyIdSet(address,uint64)` | `0xb881fe19b6eeadc37f4e78a1cb1ade5fc5d0bb4e3f634d539c0807d370c28f38` |
| Event | `ForceTransferred(uint256,address,address,address)` | `0x708057b4d5a5f38837968e955e789b952ce74d42c5eeeb4964b668fe6aaca057` |

---

### MintIntentRegistry

Shared registry that owns all mint intent state for every controller deployment.

**Why it is shared:** operation IDs and hold IDs are only single-use within the storage that tracks them. When each controller proxy kept its own intent mappings, the same source-bridge operation could be published and consumed once *per controller*. Deploying one registry and pointing every controller (`TokenAuthority`, `TIP20Controller`) at it makes those identifiers single-use across all of them.

Deploy **once per environment** (`scripts/03a_DeployMintIntentRegistry.s.sol`) and reuse the proxy address for every controller.

**Two guarantees, deliberately scoped differently.** Sharing an ID namespace is not the same as sharing control:

| | Scope | Enforced by |
|---|---|---|
| **Uniqueness** of an operation ID / hold ID | Registry-wide — used once across *every* controller | `ApprovalExistsForOperationId` / `ApprovalExistsForHoldId` on publish, and terminal `CONSUMED`/`REVOKED` states |
| **Authority** over an individual approval | Per-controller — only the publishing controller may consume, revoke, or extend it | `controller` recorded on the `Approval`, checked by `NotApprovalController` |

So one source operation is still processed exactly once system-wide, but controller B can neither spend nor cancel an intent that controller A published. Without the second guarantee, B could revoke A's live intent (no minting rights required — pure griefing), or, where both controllers are authorized to mint the same stablecoin, spend A's intent under B's own rate limits.

Exception: an operation ID with **no** approval has no owner. Any controller may retire it via `revokeOperationId` or `consumeUnusedOperationId` (the burn path), which permanently retires it registry-wide. This is inherent to a shared namespace; `CONTROLLER_ROLE` holders are trusted contracts.

**Inheritance:**
```
MintIntentRegistry
├── AccessControlEnumerableUpgradeable
└── UUPSUpgradeable
```

**Storage (EIP-7201, namespace `bridge.MintIntent`):**
```solidity
struct MintIntentStorage {
    mapping(uint256 operationId => bytes32 holdId) _operationHoldId;
    mapping(bytes32 holdId => Approval approval) _holdIdApproval;
    mapping(uint256 operationId => OperationState state) _operationStates;
}
```

**Operation state machine:**
```
UNUSED ──publishApproval─────────> RESERVED ──consumeApproval──> CONSUMED
   │                                   │
   ├──consumeUnusedOperationId──> CONSUMED   (burn path; UNUSED only)
   │
   └──revokeOperationId──> REVOKED <──revokeOperationId / revokeApproval── RESERVED
```
`consumeUnusedOperationId` accepts **only** `UNUSED` — it cannot spend an ID already reserved by an approval. `revokeOperationId` accepts `UNUSED` or `RESERVED`. `CONSUMED` and `REVOKED` are terminal, pinned by `test_revokeOperationId_revertWhenTerminalState`.

A `CONSUMED` or `REVOKED` operation ID can never be reused **within a given registry**, by any controller pointed at it.

> **Migration warning.** Uniqueness is a property of the registry's storage, not of the ID itself. Pointing a controller at a *freshly deployed* registry via `setMintIntentRegistry` resets the namespace: operation IDs already `CONSUMED` or `REVOKED` become publishable again, so one source operation can be processed twice — the exact failure this registry exists to prevent. **Replace a registry only by UUPS-upgrading the existing proxy, never by deploying a new one.** The setter is for correcting a mis-wired pointer, not for rotating state. Pinned by `test_setMintIntentRegistry_freshRegistryReopensSpentOperationIds`.

**Key Functions:**

All state-mutating functions require `CONTROLLER_ROLE`. Callers are expected to be controllers, which authorize their own callers (via `PUBLISHER_ROLE` / `BURNER_ROLE`) before forwarding.

| Function | Access | Description |
|----------|--------|-------------|
| `publishApproval(params, expiry)` | `CONTROLLER_ROLE` | Reserve an operation ID and store the approval, recording the caller as its owner |
| `revokeApproval(holdId)` | `CONTROLLER_ROLE` + publishing controller | Revoke an approval; returns its operation ID |
| `revokeOperationId(operationId)` | `CONTROLLER_ROLE` + publishing controller *if an approval exists* | Revoke an unused or reserved operation ID; returns its hold ID |
| `extendApproval(holdId, newExpiry)` | `CONTROLLER_ROLE` + publishing controller | Extend expiry; returns the operation ID |
| `consumeApproval(params)` | `CONTROLLER_ROLE` + publishing controller | Consume a published approval (mint path) |
| `consumeUnusedOperationId(operationId)` | `CONTROLLER_ROLE` | Consume an ID with no approval (burn path); unowned, so any controller may |
| `getApproval(holdId)` | View | The stored approval, including its owning `controller` |
| `getOperationHoldId(operationId)` | View | Hold ID for an operation, `bytes32(0)` if none |
| `getOperationState(operationId)` | View | `UNUSED` / `RESERVED` / `CONSUMED` / `REVOKED` |
| `upgradeToAndCall(impl, data)` | `DEFAULT_ADMIN_ROLE` | Upgrade the implementation |

The registry emits no intent lifecycle events. It returns the derived identifiers so the calling controller emits the `IMintIntent` events with the original caller as the actor, preserving EOA attribution in the audit trail.

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
| `wrap` | Reverts with `NotSupported()` (`0xa0387940`) |
| `unwrap` | Reverts with `NotSupported()` (`0xa0387940`) |

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

### Seize Handlers (`ISeizeHandler`)

The seize counterpart of token handlers, in `src/tokenAuthority/seizeHandler/`. A token handler issues and redeems a stablecoin; a seize handler only moves a frozen holder's coins, using functions the stablecoin already has. They are separate from token handlers so that adding seize doesn't replace the deployed token handlers, which own the reserve stores of backed stablecoins. Seize never touches reserve ledger tokens, so seize handlers hold no state and can be swapped by pointing `setSeizeConfig` at a new one.

| Contract | Stablecoins | Move |
|---|---|---|
| `ForceTransferSeizeHandler` | Hold their own backing (`StablecoinTemplateV3`, issued through `ReserveLedgerWrappedHandler`) | `stablecoin.forceTransfer(from, to, amount)`. Backing stays inside the coin. |
| `BurnAndRemintSeizeHandler` | Backing in a reserve store (`StablecoinTemplateV2`, issued through `ReserveLedgerBackedHandler`) | Unpause if paused → `burnFromBlockedAddress(from)` → `mint(to, amount)`. On a partial seize: `mint(handler, remainder)`, `unblockAddress(from)`, `transfer(from, remainder)`, `blockAddress(from)`. Then re-pause. Reverts if its own stablecoin or reserve ledger balance changes, which also refuses a V3 coin wrongly given this handler (its burn would pay out backing). |

Both inherit `SeizeHandler` (only `TOKEN_AUTHORITY` may call; ERC165 for `ISeizeHandler`) and emit `Seized(address indexed stablecoinContract, address indexed from, address indexed to, uint256 amount)`.

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

Each error's 4-byte selector is the first four bytes of `keccak256` over its canonical signature. Use these to decode revert data off-chain.

### Stablecoin (`StablecoinTemplateV3` / `ReserveLedger`)

Defined in `src/v3/StablecoinTemplateV3ErrorsAndEvents.sol`.

| Selector | Error | Meaning |
|----------|-------|---------|
| `0xae170cc2` | `AddressBlocked()` | Sender or recipient is blocked by the auth registry |
| `0xd92e233d` | `ZeroAddress()` | A required address argument is the zero address |
| `0x8a164f63` | `MaxSupplyExceeded()` | Mint would push total supply above `_maxSupply` |
| `0xd5959b7a` | `AccountNotValidRecipient()` | Recipient fails the mint-recipient policy check |
| `0xbe692e78` | `AddressIsNotBlocked()` | `burnFromBlockedAddress` called on a non-blocked address |
| `0x810b516e` | `NoBalanceToBurn()` | `burnFromBlockedAddress` called on an address with zero balance |
| `0xfaa10c8f` | `MaxSupplyMustBeGreaterThanOrEqualToTotalSupply()` | `setMaxSupply` would drop max below current supply |
| `0x9f651e5f` | `CannotRevokeLastAdminRole()` | Attempt to revoke the only `DEFAULT_ADMIN_ROLE` holder |
| `0xde195716` | `OnlyOwnerOrAdmin()` | Caller is neither owner nor admin |
| `0x271bb77f` | `ReserveLedgerBalanceMismatch()` | Reserve ledger balance does not equal total supply at migration |
| `0x401d2707` | `MigrationToWrappedCompleted()` | Operation disabled after migration to wrapped is complete |
| `0xd0c95e80` | `MigrationToWrappedNotCompleted()` | Operation requires migration to wrapped to be complete |
| `0xd11b25af` | `AmountCannotBeZero()` | Zero amount passed to a mint/burn/wrap/unwrap operation |

### TokenAuthority (`ITokenAuthority`)

Defined in `src/tokenAuthority/ITokenAuthority.sol`.

| Selector | Error | Meaning |
|----------|-------|---------|
| `0xe4d2551c` | `MintTxnLimitExceeded()` | Mint amount exceeds the configured per-transaction limit |
| `0xec408451` | `MinterAllowanceExceeded()` | Mint amount exceeds caller's remaining minter allowance |
| `0x7b55d08d` | `CannotUnwrapReserveLedgerToken()` | The reserve ledger token cannot itself be unwrapped |
| `0xd11b25af` | `AmountCannotBeZero()` | Zero amount passed to an authority operation |
| `0x643687f2` | `AmountExceedsAbsoluteMax()` | Amount exceeds the absolute maximum allowed |
| `0x271bb77f` | `ReserveLedgerBalanceMismatch()` | Reserve ledger balance does not match expected value |
| `0x49e9bedc` | `TokenHandlerNotSet()` | No token handler is configured for the stablecoin |
| `0x49cb9bfc` | `StablecoinNotRegistered()` | Stablecoin is not registered with the authority |
| `0xd92e233d` | `ZeroAddress()` | A required address argument is the zero address |
| `0x343578d7` | `InvalidTokenHandler()` | Provided handler does not implement `ITokenHandler` |
| `0x4dfaba25` | `StablecoinAlreadyRegistered()` | Stablecoin is already registered with the authority |
| `0xa68f658f` | `MintIntentRequired()` | `mint()` called while `mintIntentVersion == Required` |
| `0x37b3468f` | `PrecisionMismatch(uint256,uint256)` | Stablecoin decimals differ from the reserve ledger's |
| `0xc41537d3` | `StablecoinPaused()` | Operation attempted on a paused stablecoin |
| `0xc9fc8444` | `StablecoinNotPaused()` | Operation requires the stablecoin to be paused first |
| `0xf042418c` | `InvalidSeizeConfig()` | `setSeizeConfig` with a zero seize handler but a non-zero registry or list ID |
| `0xaea894e7` | `InvalidSeizeHandler()` | Provided seize handler does not implement `ISeizeHandler` |

### Seize (`ISeize`)

Defined in `src/seize/interfaces/ISeize.sol`. Raised identically by `TokenAuthority` and `TIP20Controller`.

| Selector | Error | Meaning |
|----------|-------|---------|
| `0x72caeba5` | `SeizeNotConfigured(address)` | The stablecoin has no seize settings (TokenAuthority) or `seizureWalletPolicyId == 0` (TIP20Controller) |
| `0x9e3c18ba` | `InvalidSeizureWalletList(address,uint64)` | Zero registry, built-in list ID 0 or 1, or a list that authorizes the controller itself |
| `0x14d41d67` | `InvalidSeizeDestination(address)` | `to` is the holder or the controller |
| `0x181235d3` | `DestinationNotSeizureWallet(address)` | `to` is not on the Seizure Wallet list |
| `0xa7d8a38f` | `HolderNotBlocked(address)` | `from` is not frozen, before or (should never happen) after the move |
| `0xf2125033` | `InvalidSeizeAmount(uint256,uint256)` | Amount is zero or above the holder's balance; args are `amount`, `holderBalance` |
| `0xe66e11d4` | `SeizeBalanceMismatch(address,uint256,uint256)` | Post-condition: an account's balance is not what the move should leave. Should never happen |
| `0x34a74a33` | `SeizeTotalSupplyChanged(uint256,uint256)` | Post-condition: total supply changed. Should never happen |
| `0xec43e08a` | `PauseStateNotRestored(bool)` | Post-condition: the stablecoin's pause state differs from its starting state. Should never happen |

### Mint Intent (`IMintIntent`)

Defined in `src/mintIntent/interfaces/IMintIntent.sol`. Raised by the shared `MintIntentRegistry` and surfaced through whichever controller forwarded the call.

| Selector | Error | Meaning |
|----------|-------|---------|
| `0xc42bc14e` | `ApprovalExistsForOperationId(uint256)` | Operation ID is already reserved, consumed, or revoked — **in any controller** |
| `0xa00e9e57` | `ApprovalExistsForHoldId(bytes32)` | Hold ID already has an approval |
| `0x98c03202` | `ApprovalNotExistsForHoldId(bytes32)` | No approval exists for the hold ID |
| `0x9ee19243` | `InvalidApproval(bytes32,uint256)` | Approval is already consumed or revoked; second arg is the flag bitmap |
| `0x9f1785de` | `ApprovalExpiryNotExtended(bytes32,uint64,uint64)` | New expiry is not later than the current one |
| `0x18c3655a` | `InvalidHoldId()` | Hold ID is `bytes32(0)` |
| `0xd36c8500` | `InvalidExpiry()` | Expiry is not in the future |
| `0x282da365` | `InvalidOperationId()` | Operation ID is zero, or not in a state that permits the action |
| `0x2c5211c6` | `InvalidAmount()` | Approval amount is zero |
| `0x9c8d2cd2` | `InvalidRecipient()` | Recipient is the zero address |
| `0x528ac08a` | `InvalidStablecoin()` | Stablecoin is the zero address |
| `0x11a1e697` | `InvalidRegistry()` | Registry address is the zero address |
| `0x4495f996` | `ControllerNotAuthorizedOnRegistry(address)` | `setMintIntentRegistry` target has not granted this controller `CONTROLLER_ROLE` |
| `0xe1ab601b` | `NotApprovalController(bytes32,address,address)` | A controller tried to consume/revoke/extend an approval published by a different controller; args are `holdId`, owning controller, caller |
| `0xf474cfad` | `InvalidApprovalParams(bool,bool,bool,bool,bool,bool)` | Consume params mismatch; flags are `holdId`, `operationId`, `amount`, `recipient`, `stablecoin`, `expiry` |

### Token Handlers (`ITokenHandler` and implementations)

Defined in `src/tokenAuthority/tokenHandler/`.

| Selector | Error | Source | Meaning |
|----------|-------|--------|---------|
| `0xc3b27173` | `OnlyTokenAuthority()` | `ITokenHandler` | Caller is not the configured `TOKEN_AUTHORITY` |
| `0xd92e233d` | `ZeroAddress()` | `ITokenHandler` | A required address argument is the zero address |
| `0xa0387940` | `NotSupported()` | `SingleTokenHandler` | `wrap`/`unwrap` invoked on a non-collateralized handler |
| `0x522954b5` | `ReserveStoreNotFound()` | `ReserveLedgerBackedHandler` | No `ReserveStore` exists for the given stablecoin |

### Seize Handlers (`ISeizeHandler` and implementations)

Defined in `src/tokenAuthority/seizeHandler/`.

| Selector | Error | Source | Meaning |
|----------|-------|--------|---------|
| `0xc3b27173` | `OnlyTokenAuthority()` | `ISeizeHandler` | Caller is not the configured `TOKEN_AUTHORITY` |
| `0xd92e233d` | `ZeroAddress()` | `ISeizeHandler` | A required address argument is the zero address |
| `0x4094e539` | `SeizeHandlerBalanceChanged(address,uint256,uint256)` | `BurnAndRemintSeizeHandler` | The handler's own balance of a token changed during a seize: the remainder wasn't fully returned, or the stablecoin paid out reserve backing. Should never happen |

### ReserveStore

Defined in `src/reserveStore/ReserveStore.sol`.

| Selector | Error | Meaning |
|----------|-------|---------|
| `0xd92e233d` | `ZeroAddress()` | A required address argument is the zero address |
