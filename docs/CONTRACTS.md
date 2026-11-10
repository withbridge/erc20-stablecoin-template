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
├── IdempotencyKeys       (forwards to the shared IdempotencyKeyRegistry)
└── Seize                 (shared seize rules; see Seize below)
```

**Immutables:**
| Name | Type | Description |
|------|------|-------------|
| `RESERVE_LEDGER_TOKEN` | `address` | The reserve asset |
| `ABSOLUTE_MAX` | `uint256` | Hard cap on any single amount (`1_000_000_000 * 1e6`) |
| `AUTH_REGISTRY` | `IAuthRegistry` | Registry holding the Seizure Wallet list. Set in the constructor, which requires it to equal `RESERVE_LEDGER_TOKEN`'s own `AUTH_REGISTRY` (`AuthRegistryMismatch` otherwise) |

**Storage (sequential slots — append only):**
```solidity
mapping(address stablecoin => mapping(address minter => uint256)) minterAllowances; // slot 0
mapping(address stablecoin => uint256) mintTxnLimits;                              // slot 1
mapping(address stablecoin => address handler) tokenHandlers;                      // slot 2
MintIntentVersion public mintIntentVersion;                                        // slot 3
mapping(address stablecoin => bool) public stablecoinIsPaused;                     // slot 4
IIdempotencyKeyRegistry public idempotencyKeyRegistry;                             // slot 5
mapping(address stablecoin => address seizeHandler) seizeHandlers;                 // slot 6
uint256 public seizureWalletPolicyId;                                              // slot 7
```

Idempotency-key state is *not* stored here — it lives in the shared [`IdempotencyKeyRegistry`](#idempotencykeyregistry). New variables must be appended, since this contract sits behind a UUPS proxy.

**Key Functions:**
| Function | Access | Description |
|----------|--------|-------------|
| `mint(stablecoin, to, amount, keys)` | Allowance holder | Rate-limited mint. Empty `keys` only when `mintIntentVersion == Optional`; non-empty keys are marked used first |
| `mintBridgeEcosystem(stablecoin, to, amount)` | `BRIDGE_ECOSYSTEM_CONTRACT_ROLE` | Mint without limits |
| `burn(stablecoin, amount)` | `BURNER_ROLE` | Burn tokens |
| `burn(stablecoin, amount, keys)` | `BURNER_ROLE` | Burn, marking the given keys used |
| `wrap(stablecoin, to, amount)` | Public | Wrap reserve into stablecoin |
| `unwrap(stablecoin, amount)` | `UNWRAPPER_ROLE` | Unwrap stablecoin to reserve |
| `registerStablecoin(stablecoin, handler, seizeHandler, mintTxnLimit)` | `DEFAULT_ADMIN_ROLE` | Add stablecoin with its token handler and seize handler (zero seize handler = not seizable yet) |
| `unregisterStablecoin(stablecoin)` | `TOKEN_AUTHORITY_HANDLER_SETTER_ROLE` | Remove stablecoin. Also clears its seize handler |
| `setTokenHandler(stablecoin, handler)` | `TOKEN_AUTHORITY_HANDLER_SETTER_ROLE` | Swap handler (stablecoin must be paused) |
| `setMinterAllowance(stablecoin, minter, amount)` | `MINT_RATE_LIMIT_SETTER_ROLE` | Set minter's allowance |
| `setTxnMintLimit(stablecoin, limit)` | `MINT_RATE_LIMIT_SETTER_ROLE` | Set per-tx limit |
| `setStablecoinPaused(stablecoin, pause)` | `STABLECOIN_PAUSER_ROLE` | Pause/unpause a stablecoin |
| `setMintIntentVersion(version)` | `DEFAULT_ADMIN_ROLE` | Allow (`Optional`) or require (`Required`) keys on `mint` |
| `setIdempotencyKeyRegistry(registry)` | `DEFAULT_ADMIN_ROLE` | Migrate to a different shared registry |
| `seize(stablecoin, from, to, amount)` | `SEIZER_ROLE` | Seize from a frozen holder (see Seize below) |
| `setSeizeHandler(stablecoin, seizeHandler)` | `DEFAULT_ADMIN_ROLE` | Set, replace or clear (zero) a registered stablecoin's seize handler. For stablecoins registered before `registerStablecoin` took one; no pause needed |
| `getSeizeHandler(stablecoin)` | Public | Read a stablecoin's seize handler |
| `setSeizureWalletPolicyId(policyId)` | `DEFAULT_ADMIN_ROLE` | Set the one `AUTH_REGISTRY` policy listing the Seizure Wallets for every stablecoin on this TokenAuthority; `0` disables seize. Shared with `TIP20Controller` through `Seize` |
| `seizureWalletPolicyId()` | Public | Read the Seizure Wallet policy ID |

Key functions inherited from `IdempotencyKeys` — `useKeys` (`PUBLISHER_ROLE`) — forward to the shared registry and emit `KeyUsed` per key.

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
event SeizeHandlerSet(address indexed sender, address indexed stablecoinContract, address indexed seizeHandler);
event SeizureWalletPolicyIdSet(address indexed sender, uint64 policyId);
event Seized(address indexed stablecoinContract, address indexed from, address indexed to, uint256 amount, address caller);
```

---

### Seize (`TokenAuthority` and `TIP20Controller`)

Moves a frozen holder's coins into an approved Seizure Wallet without changing supply or reserve backing. Both controllers inherit the abstract `Seize` base (`src/seize/Seize.sol`) and the `ISeize` interface, so the function, role, event and errors are byte-identical on each.

**Every seize** (`seize(stablecoin, from, to, amount)`, `SEIZER_ROLE`):
1. Seize is configured: a non-zero `seizureWalletPolicyId`, and on `TokenAuthority` a seize handler for the stablecoin. Otherwise `SeizeNotConfigured`.
2. `to` is neither `from` nor the controller, and is authorized on the Seizure Wallet list (`isAuthorized(seizureWalletPolicyId, to)` on the controller's fixed registry).
3. `from` is frozen on the stablecoin. On `TokenAuthority` this is read through the stablecoin's seize handler (`isHolderBlocked`), which knows the stablecoin's type.
4. `0 < amount <= balanceOf(from)`.
5. After the move, the base asserts that `to` gained exactly `amount` (`SeizeBalanceMismatch`). Anything specific to a path is handled by that path; the `BurnAndRemintSeizeHandler`, for example, asserts its own balances are unchanged.

It ignores the controller's own `setStablecoinPaused`, which halts issuance, not compliance actions. It never goes through a token handler or the reserve-minting path.

**How coins move:**

| Controller | Moved by | Move |
|---|---|---|
| `TokenAuthority` | the stablecoin's **seize handler** (see below) | `TokenAuthority` stays a pass-through, like `mint`: it enforces the rules above and calls `seizeHandler.seize(...)` |
| `TIP20Controller` | the controller itself | Unpause if paused → `burnAt(from, amount)` → the coin's own `mint(to, amount)` → re-pause |

On `TokenAuthority`, the seize handler is also refused as a destination, because it can't move coins on.

**Seizure Wallet list** (`setSeizureWalletPolicyId`, implemented once in `Seize` like `setIdempotencyKeyRegistry` in `IdempotencyKeys`): each controller reads one policy ID from one fixed registry, `AUTH_REGISTRY` on `TokenAuthority` and TIP-403 on `TIP20Controller`. A TokenAuthority belongs to one entity, which seizes into the same wallets for all of its coins. `0` disables seize; any other ID must not be a built-in (`1` always-allow) and must not authorize the controller itself (this rejects allow-all and blacklist-type lists).

**Seize handler** (`registerStablecoin` and `setSeizeHandler`): zero, or a contract that implements `ISeizeHandler` (ERC165, the same check token handlers get) and whose `TOKEN_AUTHORITY` is this TokenAuthority. Anything else reverts with `InvalidSeizeHandler`.

**Roles each stablecoin grants for seize** (granted by the stablecoin's admin during setup, not by the upgrade):

| Stablecoin | Granted to | Roles / lists |
|---|---|---|
| `StablecoinTemplateV3` | `ForceTransferSeizeHandler` | `FORCE_TRANSFER_ROLE` |
| `StablecoinTemplateV2` | `BurnAndRemintSeizeHandler` | `BLOCKED_ADDRESS_BURNER_ROLE`, `MINTER_ROLE`, `UNBLOCKER_ROLE`, `BLOCKER_ROLE`, `PAUSER_ROLE`, `UNPAUSER_ROLE`; `addMintRecipient` for the Seizure Wallet and the seize handler |
| TIP-20 | `TIP20Controller` | `BURN_AT_ROLE` (T12+), `PAUSE_ROLE`, `UNPAUSE_ROLE`, plus the existing `ISSUER_ROLE`. The Seizure Wallet must be authorized under the coin's TIP-403 transfer policy, because TIP-20 `mint` checks the recipient. |

**`TIP20Controller` additions:**

| Item | Detail |
|---|---|
| `seizureWalletPolicyId()` | TIP-403 policy listing the Seizure Wallets for every coin on this controller. `0` means seize is disabled. Returns `uint256` (always fits a `uint64` TIP-403 ID). Storage slot 6, after `idempotencyKeyRegistry`. |
| `setSeizureWalletPolicyId(policyId)` | `DEFAULT_ADMIN_ROLE`, inherited from `Seize`. `0` disables seize; any other value is validated as above against the TIP-403 registry. |
| `event SeizureWalletPolicyIdSet(address indexed sender, uint64 policyId)` | Declared on `ISeize` |

**Selectors and topics** (monorail, Fireblocks rules and monitoring key on these):

| Kind | Signature | Selector / topic |
|---|---|---|
| Function | `seize(address,address,address,uint256)` | `0xacb82dec` |
| Function | `SEIZER_ROLE()` | `0x421a40a7` (value `0xe770a2b882b0a3a025be15ffce2d5d54f5d719264e701933268dd62f79db677f`) |
| Function | `registerStablecoin(address,address,address,uint256)` | `0x16c1e855` (replaces `0x3ccf985e`, the three-argument form) |
| Function | `setSeizeHandler(address,address)` | `0x2eefdac6` |
| Function | `getSeizeHandler(address)` | `0x8225b566` |
| Function | `AUTH_REGISTRY()` (TokenAuthority) | `0x91bd7738` |
| Function | `setSeizureWalletPolicyId(uint64)` | `0x798953e0` (both controllers) |
| Function | `seizureWalletPolicyId()` | `0xd51c6560` (both controllers) |
| Function | `forceTransfer(address,address,uint256)` | `0x33bebb77` |
| Function | `FORCE_TRANSFER_ROLE()` | `0xede3fc8c` (value `0xf03e19c53afadaa67869d28def12770ead62d3b7112af11002e6f2f27cd92391`) |
| Event | `Seized(address,address,address,uint256,address)` | `0x61cfce727addc1ab55f91beabbd27489a8558f075cf83922e12818b77b8aa704` |
| Event | `SeizeHandlerSet(address,address,address)` | `0x76040d400821bc7dd795469e9154c8cb955a6e6a97dd3635e7b2d586e38841a1` |
| Function (seize handler) | `seize(address,address,address,uint256,uint256)` | `0x17cde087` |
| Function (seize handler) | `isHolderBlocked(address,address)` | `0x423f1647` |
| Event (seize handler) | `Seized(address,address,address,uint256)` | `0xa9aec5d8b86e2fa2fd6ac3af62f2622e3dfdab1967d4cbbb56a5df7d74cb887c` |
| Event | `SeizureWalletPolicyIdSet(address,uint64)` | `0xb881fe19b6eeadc37f4e78a1cb1ade5fc5d0bb4e3f634d539c0807d370c28f38` (both controllers) |
| Event | `ForceTransferred(uint256,address,address,address)` | `0x708057b4d5a5f38837968e955e789b952ce74d42c5eeeb4964b668fe6aaca057` |

---

### IdempotencyKeyRegistry

Shared registry that owns all idempotency-key state for every controller deployment.

**Why it is shared:** keys are only single-use within the storage that tracks them. When each controller proxy kept its own mapping, the same key could be used once *per controller*. Deploying one registry and pointing every controller (`TokenAuthority`, `TIP20Controller`) at it makes those keys single-use across all of them.

Deploy **once per environment** (`scripts/03a_DeployIdempotencyKeyRegistry.s.sol`) and reuse the proxy address for every controller.

Uniqueness is registry-wide: a key can be used once across *every* controller. Any controller with `CONTROLLER_ROLE` may mark a still-free key used. Keys in one `useKeys` call are not bound to each other beyond atomicity — the caller supplies every identifier that must be retired together.

**Inheritance:**
```
IdempotencyKeyRegistry
├── AccessControlEnumerableUpgradeable
└── UUPSUpgradeable
```

**Storage (EIP-7201, namespace `bridge.IdempotencyKeyStorage`):**
```solidity
enum IdempotencyKeyState { FREE, USED }

struct IdempotencyKeyStorage {
    mapping(bytes32 idempotencyKey => IdempotencyKeyState state) _idempotencyKeyStates;
}
```

**Key state machine:**
```
FREE ──useKeys──> USED
```
`USED` is terminal. A key leaves `FREE` exactly once, by mint, burn, or publisher `useKeys`. Duplicates in the same `useKeys` array fail on the second visit.

A `USED` key can never be reused **within a given registry**, by any controller pointed at it.

> **Migration warning.** Uniqueness is a property of the registry's storage, not of the key itself. Pointing a controller at a *freshly deployed* registry via `setIdempotencyKeyRegistry` resets the namespace: keys already `USED` become free again, so one source operation can be processed twice — the exact failure this registry exists to prevent. **Replace a registry only by UUPS-upgrading the existing proxy, never by deploying a new one.** The setter is for correcting a mis-wired pointer, not for rotating state. Pinned by `test_setIdempotencyKeyRegistry_freshRegistryReopensSpentKeys`.

**Key Functions:**

All state-mutating functions require `CONTROLLER_ROLE`. Callers are expected to be controllers, which authorize their own callers (via `PUBLISHER_ROLE` / minter allowance / `BURNER_ROLE`) before forwarding.

| Function | Access | Description |
|----------|--------|-------------|
| `useKeys(keys)` | `CONTROLLER_ROLE` | Mark every key used. Empty array, zero keys, and already-used keys revert |
| `isFree(key)` | View | Whether the key has never been used |
| `upgradeToAndCall(impl, data)` | `DEFAULT_ADMIN_ROLE` | Upgrade the implementation |

The registry emits no key-lifecycle events. The calling controller emits `IIdempotencyKeys.KeyUsed` with the original caller as the actor, preserving EOA attribution in the audit trail.

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

The seize counterpart of token handlers, in `src/tokenAuthority/seizeHandler/`. A token handler issues and redeems a stablecoin; a seize handler only moves a frozen holder's coins, using functions the stablecoin already has. They are separate from token handlers so that adding seize doesn't replace the deployed token handlers, which own the reserve stores of backed stablecoins. Seize never touches reserve ledger tokens, so seize handlers hold no state and can be swapped by pointing `setSeizeHandler` at a new one.

| Contract | Stablecoins | Move |
|---|---|---|
| `ForceTransferSeizeHandler` | Hold their own backing (`StablecoinTemplateV3`, issued through `ReserveLedgerWrappedHandler`) | `stablecoin.forceTransfer(from, to, amount)`. Backing stays inside the coin. |
| `BurnAndRemintSeizeHandler` | Backing in a reserve store (`StablecoinTemplateV2`, issued through `ReserveLedgerBackedHandler`; driven through `IStablecoinTemplateV2` in `src/utils/`) | Unpause if paused → `burnFromBlockedAddress(from)` → `mint(to, amount)`. On a partial seize: `mint(handler, remainder)`, `unblockAddress(from)`, `transfer(from, remainder)`, `blockAddress(from)`. Then re-pause. Reverts if its own stablecoin or reserve ledger balance changes, which also refuses a V3 coin wrongly given this handler (its burn would pay out backing). |

Both inherit `SeizeHandler` (only `TOKEN_AUTHORITY` may call; ERC165 for `ISeizeHandler`) and emit `Seized(address indexed stablecoinContract, address indexed from, address indexed to, uint256 amount)`. Each also answers `isHolderBlocked(stablecoin, holder)` through its stablecoin's own type (`StablecoinTemplateV3` or `IStablecoinTemplateV2`), which the TokenAuthority uses for its frozen-holder check.

**Deployment:** `scripts/07_DeploySeizeHandlers.s.sol` deploys both handlers for one TokenAuthority (`run(address tokenAuthority)`) and checks they were built for it.
- New chains: `deploy-new-chain.sh` runs 07 right after 03, and `05_ConfigureAndHandover` (via `deploy-new-stablecoin.sh`, which now takes `FORCE_TRANSFER_SEIZE_HANDLER`) grants the new V3 stablecoin's `FORCE_TRANSFER_ROLE` to the force-transfer handler and registers the stablecoin with it. `DeployAll` does the same. `06_Verify` checks the seize handler, that it was built for the TokenAuthority, and that it is the only `FORCE_TRANSFER_ROLE` holder.
- Existing TokenAuthorities: run 07 on its own, then each stablecoin's admin grants the roles and the TokenAuthority admin calls `setSeizeHandler`.
- Never scripted: `setSeizureWalletPolicyId` and the `SEIZER_ROLE` grant, which belong to the entity's Seizure List Authority and Seize Authority setup.
- Tested by `DeployAllE2ETest` (`test_seizeEndToEnd_stablecoinRegisteredWithSeizeHandler`, `test_deploySeizeHandlersScript_existingStablecoin`, and `Verify` in `test_fullDeployment`).

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
| `0xd11b25af` | `AmountCannotBeZero()` | Zero amount passed to a mint/burn/wrap/unwrap operation |

### TokenAuthority (`ITokenAuthority`)

Defined in `src/tokenAuthority/ITokenAuthority.sol`.

| Selector | Error | Meaning |
|----------|-------|---------|
| `0xe4d2551c` | `MintTxnLimitExceeded()` | Mint amount exceeds the configured per-transaction limit |
| `0xec408451` | `MinterAllowanceExceeded()` | Mint amount exceeds caller's remaining minter allowance |
| `0xd11b25af` | `AmountCannotBeZero()` | Zero amount passed to an authority operation |
| `0x643687f2` | `AmountExceedsAbsoluteMax()` | Amount exceeds the absolute maximum allowed |
| `0x271bb77f` | `ReserveLedgerBalanceMismatch()` | Reserve ledger balance does not match expected value |
| `0x49e9bedc` | `TokenHandlerNotSet()` | No token handler is configured for the stablecoin |
| `0x49cb9bfc` | `StablecoinNotRegistered()` | Stablecoin is not registered with the authority |
| `0xd92e233d` | `ZeroAddress()` | A required address argument is the zero address |
| `0x343578d7` | `InvalidTokenHandler()` | Provided handler does not implement `ITokenHandler` |
| `0x4dfaba25` | `StablecoinAlreadyRegistered()` | Stablecoin is already registered with the authority |
| `0x2136284a` | `IdempotencyKeysRequired()` | Mint without idempotency keys while `idempotencyKeysVersion == Required` |
| `0x37b3468f` | `PrecisionMismatch(uint256,uint256)` | Stablecoin decimals differ from the reserve ledger's |
| `0xc41537d3` | `StablecoinPaused()` | Operation attempted on a paused stablecoin |
| `0xc9fc8444` | `StablecoinNotPaused()` | Operation requires the stablecoin to be paused first |
| `0xaea894e7` | `InvalidSeizeHandler()` | Provided seize handler does not implement `ISeizeHandler`, or its `TOKEN_AUTHORITY` is another TokenAuthority |
| `0xa56ea4f8` | `AuthRegistryMismatch(address,address)` | Constructor: the AuthRegistry is not the reserve ledger's; args are the reserve ledger's, then the one passed |

### Seize (`ISeize`)

Defined in `src/seize/interfaces/ISeize.sol`. Raised identically by `TokenAuthority` and `TIP20Controller`.

| Selector | Error | Meaning |
|----------|-------|---------|
| `0x72caeba5` | `SeizeNotConfigured(address)` | `seizureWalletPolicyId == 0`, or (TokenAuthority) the stablecoin has no seize handler |
| `0x9e3c18ba` | `InvalidSeizureWalletList(address,uint64)` | Built-in policy ID 1, or a list that authorizes the controller itself; args are the controller's fixed registry and the policy ID |
| `0x14d41d67` | `InvalidSeizeDestination(address)` | `to` is the holder or the controller |
| `0x181235d3` | `DestinationNotSeizureWallet(address)` | `to` is not on the Seizure Wallet list |
| `0xa7d8a38f` | `HolderNotBlocked(address)` | `from` is not frozen before the move |
| `0xf2125033` | `InvalidSeizeAmount(uint256,uint256)` | Amount is zero or above the holder's balance; args are `amount`, `holderBalance` |
| `0xe66e11d4` | `SeizeBalanceMismatch(address,uint256,uint256)` | Post-condition: the Seizure Wallet did not receive exactly `amount`; args are the wallet, the expected balance, the actual balance. Should never happen |

### Idempotency keys (`IIdempotencyKeyErrors`)

Defined in `src/idempotency/interfaces/IIdempotencyKeyErrors.sol`. Raised by the shared `IdempotencyKeyRegistry` and surfaced through whichever controller forwarded the call.

| Selector | Error | Meaning |
|----------|-------|---------|
| `0xc7a8dae7` | `InvalidIdempotencyKeys()` | `useKeys` called with an empty array |
| `0x254fbbce` | `InvalidIdempotencyKey()` | A key is `bytes32(0)` |
| `0x911c96f9` | `IdempotencyKeyUsed(bytes32)` | Key is already used, including a duplicate in the same call |
| `0x11a1e697` | `InvalidRegistry()` | Registry address is the zero address |
| `0x4495f996` | `ControllerNotAuthorizedOnRegistry(address)` | `setIdempotencyKeyRegistry` target has not granted this controller `CONTROLLER_ROLE` |

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
