# Deploy Scripts — Implementation Plan

## Goal

Create modular Forge scripts for the erc20-stablecoin-template repo that support two deployment scenarios:

1. **New chain** — Deploy all infrastructure (AuthRegistry, ReserveLedger, TokenAuthority) + first stablecoin from scratch
2. **New stablecoin on existing chain** — Deploy an additional StablecoinTemplateV3 using already-deployed infrastructure

Scripts should be reliable enough that any engineer can execute them.

## Deployment Architecture

### What gets deployed once per chain (infrastructure)

| Contract | Purpose | Constructor Args | Proxy? |
|----------|---------|-----------------|--------|
| **AuthRegistry** | On-chain policy engine for compliance (blocklist/whitelist) | None | No (not upgradeable) |
| **ReserveLedger** | Internal backing token (RD), ERC20 | `_authRegistry` (immutable) | Yes — DeterministicProxyFactory |
| **TokenAuthority** | Central mint/burn rate limiter | `_reserveLedgerToken` (immutable), `_disableInitializer = true` | Yes — DeterministicProxyFactory |

### What gets deployed per stablecoin

| Contract | Purpose | Constructor Args | Proxy? |
|----------|---------|-----------------|--------|
| **StablecoinTemplateV3** | User-facing wrapped stablecoin (e.g. EURR, DKUSD) | `_reserveLedgerAddress` (immutable), `_authRegistry` (immutable) | Yes — DeterministicProxyFactory |

### Auth Registry policies created during deploy

| Policy | Type | Scope | Created By |
|--------|------|-------|------------|
| Transfer policy | BLACKLIST | Shared across all tokens on chain | `02_DeployReserveLedger` |
| RL mint recipient policy | WHITELIST | ReserveLedger only | `02_DeployReserveLedger` |
| Stablecoin mint recipient policy | WHITELIST | One per stablecoin | `04_DeployStablecoin` |

### Proxy deployment: DeterministicProxyFactory

All proxy contracts use `DeterministicProxyFactory` (already a soldeer dependency) instead of raw `ERC1967Proxy`. Reasons:

- Tests already deploy through `DeterministicProxyFactoryFixture.deterministicProxyOZ()` with `PermissionedSalt` — production should match
- Deterministic addresses let you pre-compute all contract addresses before deployment, enabling address verification and multi-chain address parity
- The factory atomically deploys proxy + initializes in one tx, reducing partial-deploy risk

Each proxy deployment requires its own salt nonce (see env vars). Using the same nonces across chains produces the same proxy addresses for the same contract types.

### AuthRegistry deployment: bare CREATE2 (no proxy)

AuthRegistry is not upgradeable (no UUPS). It is deployed directly via the deterministic CREATE2 deployer at `0x4e59b44847b379578588920cA78FbF26c0B4956C` with `salt = bytes32(0)`. This gives a deterministic address without a proxy. Because the address is identical across all chains, step 01 checks if code already exists at the target address and skips deployment if so (idempotent).

## Proposed Script Inventory

### `script/Common.s.sol` — Base contract

Shared base for all scripts. Provides validated env var accessors (pattern from `bridge-cards-evm`) and prerequisite validation:

```solidity
abstract contract Common is Script {
    function run() public { vm.createSelectFork(rpcUrl()); _run(); }
    function _run() internal virtual;

    // Env var helpers with validation (revert if missing or zero)
    function rpcUrl() internal view returns (string memory);
    function authRegistryAddress() internal view returns (address);
    function reserveLedgerAddress() internal view returns (address);
    function tokenAuthorityAddress() internal view returns (address);
    function adminAddress() internal view returns (address);
    function policyAdminAddress() internal view returns (address);

    // Prerequisite check: verify a contract exists at the given address
    function requireDeployed(address target, string memory label) internal view {
        require(target.code.length > 0, string.concat(label, " not deployed at specified address"));
    }
}
```

Each script calls `requireDeployed()` on all input addresses before proceeding. This prevents deploying against wrong/missing addresses (one `extcodesize` check per address).

### `script/01_DeployAuthRegistry.s.sol`

Deploys AuthRegistry via deterministic CREATE2 deployer (bare contract, no proxy).

| Env Var | Type | Description |
|---------|------|-------------|
| `RPC_URL` | string | Target chain RPC endpoint |

**Prerequisites:** None. If AuthRegistry is already deployed at the deterministic address (e.g. prior deploy or another project), the script skips deployment and logs the existing address.

**Outputs:** AuthRegistry address (logged + deterministic).

### `script/02_DeployReserveLedger.s.sol`

Creates transfer + RL mint policies in AuthRegistry, then deploys ReserveLedger implementation + proxy via DeterministicProxyFactory.

Note: policy IDs are created within this script and immediately used in the proxy's `reinitialize()` calldata. Policy creation and proxy deployment are tightly coupled — the returned policy IDs flow directly into `StablecoinTemplateV3Base.reinitialize(... _transferPolicyId, _mintRecipientPolicyId)`.

| Env Var | Type | Description |
|---------|------|-------------|
| `RPC_URL` | string | Target chain RPC |
| `AUTH_REGISTRY` | address | From step 01 |
| `RL_NAME` | string | e.g. "Reserve Ledger Dollar" |
| `RL_SYMBOL` | string | e.g. "RD" |
| `RL_DECIMALS` | uint8 | Typically 6 |
| `RL_ADMIN` | address | ReserveLedger admin (Fireblocks key) |
| `POLICY_ADMIN` | address | Admin for AuthRegistry policies |
| `RL_SALT_NONCE` | bytes32 | Salt for ReserveLedger proxy |

**Prerequisites:** `requireDeployed(AUTH_REGISTRY)`.

**Outputs:** ReserveLedger proxy address, transfer policy ID, RL mint recipient policy ID (all logged).

### `script/03_DeployTokenAuthority.s.sol`

Deploys TokenAuthority implementation (with `_disableInitializer = true`) + proxy via DeterministicProxyFactory.

| Env Var | Type | Description |
|---------|------|-------------|
| `RPC_URL` | string | Target chain RPC |
| `RESERVE_LEDGER` | address | From step 02 |
| `TOKEN_AUTHORITY_ADMIN` | address | TokenAuthority admin (Fireblocks key) |
| `TA_SALT_NONCE` | bytes32 | Salt for TokenAuthority proxy |

**Prerequisites:** `requireDeployed(RESERVE_LEDGER)`.

**Outputs:** TokenAuthority proxy address (logged).

### `script/04_DeployStablecoin.s.sol`

Creates stablecoin mint recipient policy in AuthRegistry, then deploys StablecoinTemplateV3 implementation + proxy via DeterministicProxyFactory.

| Env Var | Type | Description |
|---------|------|-------------|
| `RPC_URL` | string | Target chain RPC |
| `AUTH_REGISTRY` | address | From step 01 |
| `RESERVE_LEDGER` | address | From step 02 |
| `TRANSFER_POLICY_ID` | uint64 | From step 02 (reused across stablecoins) |
| `STABLECOIN_NAME` | string | e.g. "Revolut Euro" |
| `STABLECOIN_SYMBOL` | string | e.g. "EURR" |
| `STABLECOIN_DECIMALS` | uint8 | Typically 6 |
| `STABLECOIN_ADMIN` | address | Stablecoin admin (Fireblocks key) |
| `POLICY_ADMIN` | address | Admin for mint recipient policy |
| `SC_SALT_NONCE` | bytes32 | Salt for stablecoin proxy |

**Prerequisites:** `requireDeployed(AUTH_REGISTRY)`, `requireDeployed(RESERVE_LEDGER)`.

**Outputs:** StablecoinTemplateV3 proxy address, stablecoin mint recipient policy ID (all logged).

### `script/05a_ConfigureReserveLedger.s.sol`

Post-deployment configuration for ReserveLedger: max supply, role grants, initial whitelist population. Only run on new chain deployments (deployer has admin on RL).

| Env Var | Type | Description |
|---------|------|-------------|
| `RPC_URL` | string | Target chain RPC |
| `AUTH_REGISTRY` | address | From step 01 |
| `RESERVE_LEDGER` | address | From step 02 |
| `TOKEN_AUTHORITY` | address | From step 03 |
| `RL_MAX_SUPPLY` | uint256 | Max supply for ReserveLedger |
| `RL_MINT_RECIPIENT_POLICY_ID` | uint64 | From step 02 |
| `PAUSER_ADDRESS` | address | Address to grant PAUSER_ROLE |
| `UNPAUSER_ADDRESS` | address | Address to grant UNPAUSER_ROLE |
| `BLOCKED_ADDRESS_BURNER_ADDRESS` | address | Address to grant BLOCKED_ADDRESS_BURNER_ROLE |

**Prerequisites:** `requireDeployed(RESERVE_LEDGER)`, `requireDeployed(TOKEN_AUTHORITY)`, `requireDeployed(AUTH_REGISTRY)`.

**Actions:**
1. `reserveLedger.setMaxSupply(RL_MAX_SUPPLY)`
2. `reserveLedger.grantRole(MINTER_ROLE, TOKEN_AUTHORITY)` — **critical: without this, TokenAuthority cannot mint RD**
3. `reserveLedger.grantRole(PAUSER_ROLE, PAUSER_ADDRESS)`
4. `reserveLedger.grantRole(UNPAUSER_ROLE, UNPAUSER_ADDRESS)`
5. `reserveLedger.grantRole(BLOCKED_ADDRESS_BURNER_ROLE, BLOCKED_ADDRESS_BURNER_ADDRESS)`
6. `authRegistry.modifyPolicyWhitelist(RL_MINT_RECIPIENT_POLICY_ID, TOKEN_AUTHORITY, true)` — whitelist TokenAuthority as RL mint recipient (required for `_update()` hook)

### `script/05b_ConfigureStablecoin.s.sol`

Post-deployment configuration for a stablecoin: max supply, role grants, TokenAuthority registration, initial whitelist population. Run for every new stablecoin.

| Env Var | Type | Description |
|---------|------|-------------|
| `RPC_URL` | string | Target chain RPC |
| `AUTH_REGISTRY` | address | From step 01 |
| `STABLECOIN` | address | From step 04 |
| `TOKEN_AUTHORITY` | address | From step 03 |
| `STABLECOIN_MAX_SUPPLY` | uint256 | Max supply for stablecoin |
| `SC_MINT_RECIPIENT_POLICY_ID` | uint64 | From step 04 |
| `TXN_MINT_LIMIT` | uint256 | Per-tx mint limit in TokenAuthority |
| `MINTER_ALLOWANCE` | uint256 | Per-minter total allowance in TokenAuthority |
| `MINTER_ADDRESS` | address | Address to grant MINTER_ROLE |
| `PAUSER_ADDRESS` | address | Address to grant PAUSER_ROLE |
| `UNPAUSER_ADDRESS` | address | Address to grant UNPAUSER_ROLE |
| `BLOCKED_ADDRESS_BURNER_ADDRESS` | address | Address to grant BLOCKED_ADDRESS_BURNER_ROLE |
| `INITIAL_MINT_RECIPIENTS` | string | Comma-separated addresses to whitelist as mint recipients (optional) |

**Prerequisites:** `requireDeployed(STABLECOIN)`, `requireDeployed(TOKEN_AUTHORITY)`, `requireDeployed(AUTH_REGISTRY)`.

**Actions:**

Stablecoin configuration:
1. `stablecoin.setMaxSupply(STABLECOIN_MAX_SUPPLY)`
2. `stablecoin.grantRole(MINTER_ROLE, MINTER_ADDRESS)` — for the standard TokenAuthority mint flow, set `MINTER_ADDRESS` to the TokenAuthority proxy address (TA calls `stablecoin.mint()` internally)
3. `stablecoin.grantRole(PAUSER_ROLE, PAUSER_ADDRESS)`
4. `stablecoin.grantRole(UNPAUSER_ROLE, UNPAUSER_ADDRESS)`
5. `stablecoin.grantRole(BLOCKED_ADDRESS_BURNER_ROLE, BLOCKED_ADDRESS_BURNER_ADDRESS)`

TokenAuthority registration:
6. `tokenAuthority.setTxnMintLimit(STABLECOIN, TXN_MINT_LIMIT)`
7. `tokenAuthority.setMinterAllowance(STABLECOIN, MINTER_ADDRESS, MINTER_ALLOWANCE)`

Whitelist population:
8. For each address in `INITIAL_MINT_RECIPIENTS`: `authRegistry.modifyPolicyWhitelist(SC_MINT_RECIPIENT_POLICY_ID, recipient, true)`

Note: the stablecoin's `_update()` hook calls `isMintRecipient(to)` on every mint. If no addresses are whitelisted, minting will revert. At minimum, the stablecoin contract itself or the intended recipient addresses must be whitelisted. Additional addresses can be managed later via ops tooling or direct AuthRegistry calls.

### `script/06_Verify.s.sol`

On-chain verification script. Reads deployed state and asserts all invariants hold. Run without `--broadcast` (read-only).

| Env Var | Type | Description |
|---------|------|-------------|
| `RPC_URL` | string | Target chain RPC |
| `AUTH_REGISTRY` | address | Expected AuthRegistry address |
| `RESERVE_LEDGER` | address | Expected ReserveLedger proxy address |
| `TOKEN_AUTHORITY` | address | Expected TokenAuthority proxy address |
| `STABLECOIN` | address | Expected stablecoin proxy address |
| `MINTER_ADDRESS` | address | Address that should have MINTER_ROLE |
| `DEPLOYER_ADDRESS` | address | Address that should have NO roles (revoked) |
| `RL_NAME` | string | Expected ReserveLedger name |
| `RL_SYMBOL` | string | Expected ReserveLedger symbol |
| `STABLECOIN_NAME` | string | Expected stablecoin name |
| `STABLECOIN_SYMBOL` | string | Expected stablecoin symbol |

**Prerequisites:** `requireDeployed(AUTH_REGISTRY)`, `requireDeployed(RESERVE_LEDGER)`, `requireDeployed(TOKEN_AUTHORITY)`, `requireDeployed(STABLECOIN)`.

**Assertions:**
- AuthRegistry has code at expected address
- ReserveLedger: `name()`, `symbol()`, `decimals()`, `owner()` match expected values
- ReserveLedger: `transferPolicyId()` and `mintRecipientPolicyId()` match expected IDs
- ReserveLedger: `maxSupply()` is set
- ReserveLedger: TokenAuthority address has `MINTER_ROLE`
- ReserveLedger: TokenAuthority is whitelisted in RL mint recipient policy
- StablecoinTemplateV3: same checks as RL
- StablecoinTemplateV3: `RESERVE_LEDGER_ADDRESS()` points to correct RL
- TokenAuthority: admin has `DEFAULT_ADMIN_ROLE`
- TokenAuthority: `mintTxnLimits(stablecoin)` > 0
- TokenAuthority: `minterAllowances(stablecoin, minter)` > 0
- Deployer address has no roles on any contract (permissions revoked)

### `script/DeployAll.s.sol`

Orchestrates all steps in a single `vm.startBroadcast()` / `vm.stopBroadcast()` block for greenfield chain deploys. This sends multiple transactions (one per external call), not a single atomic transaction. Policy IDs returned from AuthRegistry flow directly into subsequent proxy init calldata within the same script execution.

Execution order: 01 → 02 → 03 → 05a → 04 → 05b (same as step-by-step runbook). 05a runs before 04 because RL configuration (max supply, MINTER_ROLE grant to TokenAuthority) must be complete before stablecoin deployment.

DeployAll deploys exactly **one stablecoin**. For multiple stablecoins on day one (e.g. EURR + DKUSD), run DeployAll for the first, then 04 + 05b for each additional stablecoin.

Env vars for DeployAll are a subset of the individual scripts — infrastructure addresses (`AUTH_REGISTRY`, `RESERVE_LEDGER`, `TOKEN_AUTHORITY`, `TRANSFER_POLICY_ID`, `STABLECOIN`) are not needed because they are passed programmatically between steps within the script. See `.env.example` for which vars are "step-by-step only" vs "DeployAll."

### `.env.example`

Documents every env var, grouped by scenario:

```bash
# ── Always Required ──────────────────────────────────────────────
RPC_URL=                          # Target chain RPC endpoint
# Deployer: use --private-key, --ledger, or --account <keystore>
# See "Deployer Key" section below.

# ── New Chain Only (steps 01-03, 05a) ────────────────────────────
RL_NAME="Reserve Ledger Dollar"   # ReserveLedger token name
RL_SYMBOL="RD"                    # ReserveLedger token symbol
RL_DECIMALS=6                     # ReserveLedger decimals
RL_ADMIN=0x...                    # ReserveLedger admin (Fireblocks)
RL_MAX_SUPPLY=1000000000000000    # RL max supply (in atomic units)
POLICY_ADMIN=0x...                # Admin for AuthRegistry policies
TOKEN_AUTHORITY_ADMIN=0x...       # TokenAuthority admin (Fireblocks)
RL_SALT_NONCE=0x00...00           # DeterministicProxyFactory salt for RL
TA_SALT_NONCE=0x00...01           # DeterministicProxyFactory salt for TA

# ── Per Stablecoin (steps 04, 05b) ───────────────────────────────
STABLECOIN_NAME="Revolut Euro"    # Stablecoin token name
STABLECOIN_SYMBOL="EURR"          # Stablecoin token symbol
STABLECOIN_DECIMALS=6             # Stablecoin decimals
STABLECOIN_ADMIN=0x...            # Stablecoin admin (Fireblocks)
STABLECOIN_MAX_SUPPLY=1000000000000000  # Stablecoin max supply
SC_SALT_NONCE=0x00...02           # DeterministicProxyFactory salt for stablecoin

# ── Step-by-Step Only (not needed for DeployAll) ─────────────────
# These are outputs from prior steps, passed as env vars when running
# scripts individually. DeployAll computes them internally.
AUTH_REGISTRY=0x...               # AuthRegistry address (from step 01)
RESERVE_LEDGER=0x...              # ReserveLedger proxy (from step 02)
TOKEN_AUTHORITY=0x...             # TokenAuthority proxy (from step 03)
TRANSFER_POLICY_ID=2              # Transfer blacklist policy (from step 02)
RL_MINT_RECIPIENT_POLICY_ID=3     # RL mint whitelist policy (from step 02)
SC_MINT_RECIPIENT_POLICY_ID=4     # Stablecoin mint whitelist policy (from step 04)
STABLECOIN=0x...                  # Stablecoin proxy (from step 04)

# ── Configuration (step 05a + 05b) ───────────────────────────────
TXN_MINT_LIMIT=1000000000000      # Per-tx mint limit (atomic units)
MINTER_ALLOWANCE=1000000000000000 # Per-minter total allowance
MINTER_ADDRESS=0x...              # Address granted MINTER_ROLE
PAUSER_ADDRESS=0x...              # Address granted PAUSER_ROLE
UNPAUSER_ADDRESS=0x...            # Address granted UNPAUSER_ROLE
BLOCKED_ADDRESS_BURNER_ADDRESS=0x...  # Address granted BLOCKED_ADDRESS_BURNER_ROLE
INITIAL_MINT_RECIPIENTS=0x...,0x...   # Comma-separated whitelist for stablecoin mint recipients (optional)
```

## Deployer Key

Scripts use `vm.startBroadcast()` / `vm.stopBroadcast()`. The deployer authenticates via Forge's standard mechanisms:

- **Local testing:** `--private-key <key>` or `--account <keystore-name>` (created via `cast wallet import`)
- **Production:** Fireblocks or hardware wallet integration (TBD — depends on ops team tooling)

The deployer is a temporary key used only for initial deployment. Post-deploy:
1. All admin roles are held by Fireblocks multisig addresses (set during `reinitialize()`)
2. The deployer has no residual roles — `DEFAULT_ADMIN_ROLE` is granted to the admin address, not the deployer
3. Step 06_Verify confirms the deployer holds no roles on any contract

## Runbook: New Chain Deployment

```bash
# 1. Set up .env with all variables
cp .env.example .env
# Edit .env — fill in ALL sections except "Step-by-Step Only"

# 2. Option A: Deploy everything at once
forge script script/DeployAll.s.sol --broadcast --verify

# 2. Option B: Deploy step by step
forge script script/01_DeployAuthRegistry.s.sol --broadcast --verify
# Copy AuthRegistry address to .env → AUTH_REGISTRY

forge script script/02_DeployReserveLedger.s.sol --broadcast --verify
# Copy RL proxy address + policy IDs to .env → RESERVE_LEDGER, TRANSFER_POLICY_ID, RL_MINT_RECIPIENT_POLICY_ID

forge script script/03_DeployTokenAuthority.s.sol --broadcast --verify
# Copy TokenAuthority address to .env → TOKEN_AUTHORITY

forge script script/05a_ConfigureReserveLedger.s.sol --broadcast

forge script script/04_DeployStablecoin.s.sol --broadcast --verify
# Copy stablecoin address + policy ID to .env → STABLECOIN, SC_MINT_RECIPIENT_POLICY_ID

forge script script/05b_ConfigureStablecoin.s.sol --broadcast

# 3. Verify on-chain state
forge script script/06_Verify.s.sol

# 4. Transfer admin to Fireblocks multisig (manual step, if not already set in .env)
# 5. Revoke deployer permissions if any remain (manual step)
```

**Recovery:** If a step fails mid-execution, check the Forge broadcast log at `broadcast/<ScriptName>.s.sol/<chainId>/run-latest.json` to see which transactions succeeded. Update `.env` with any deployed addresses and rerun from the failed step.

## Runbook: New Stablecoin on Existing Chain

```bash
# 1. Set up .env — fill "Always Required" + "Per Stablecoin" + "Configuration" sections
# AUTH_REGISTRY, RESERVE_LEDGER, TOKEN_AUTHORITY, TRANSFER_POLICY_ID are from prior deploy

# 2. Deploy stablecoin
forge script script/04_DeployStablecoin.s.sol --broadcast --verify
# Copy stablecoin address + policy ID to .env → STABLECOIN, SC_MINT_RECIPIENT_POLICY_ID

# 3. Configure stablecoin + register with TokenAuthority
forge script script/05b_ConfigureStablecoin.s.sol --broadcast

# 4. Verify on-chain state
forge script script/06_Verify.s.sol

# 5. Transfer admin to Fireblocks multisig (manual step, if not already set in .env)
```

Note: do **not** run 05a here — the deployer no longer has admin on the ReserveLedger after the initial chain deployment.

## Acceptance Criteria

**Functional:**
1. `DeployAll.s.sol` succeeds end-to-end against a local Anvil fork — deploys all contracts, configures roles, populates whitelists
2. `04 + 05b` succeeds against an Anvil fork with pre-deployed infrastructure — adds a second stablecoin to an existing chain
3. `06_Verify.s.sol` passes after both scenarios
4. After deploy, a full mint flow works: TokenAuthority mints RD → wraps into stablecoin → recipient receives tokens (proves all roles, policies, and allowances are wired correctly)
5. Step 01 is idempotent — running it twice doesn't revert

**Script quality:**
6. Every script reverts with a clear error if a required env var is missing or an input address has no code
7. All deployed contracts are source-verified (Etherscan/Blockscout via `--verify`)
8. Broadcast logs in `broadcast/` capture all deployed addresses for recovery

**Documentation:**
9. `.env.example` is complete — an engineer can `cp .env.example .env`, fill in addresses, and run
10. Both runbooks (new chain, new stablecoin) work as documented with no undocumented steps

**Delivery:** Single PR containing all scripts, `.env.example`, and this plan updated as needed.

## Key Design Decisions

1. **Numbered prefixes (01–06)** — Execution order is obvious
2. **Each script runs independently** — New stablecoin only needs scripts 04 + 05b
3. **05a/05b split** — RL config (05a) is new-chain-only; stablecoin config (05b) runs for every stablecoin. This avoids reverts when deployer no longer has RL admin.
4. **Common.s.sol base** — Consistent env var pattern + `requireDeployed()` prerequisite checks
5. **DeterministicProxyFactory for all proxies** — Matches test patterns, enables deterministic addresses and multi-chain address parity
6. **Per-contract salt nonces** (`RL_SALT_NONCE`, `TA_SALT_NONCE`, `SC_SALT_NONCE`) — Prevents address collisions when deploying multiple proxies through the same factory
7. **AuthRegistry is bare CREATE2 (no proxy)** — Not upgradeable, no UUPS
8. **Transfer policy shared per chain** — One blacklist for all tokens (per auth registry design)
9. **Mint recipient policies per contract** — Separate whitelist for RL and each stablecoin
10. **Deploy scripts handle initial whitelist population** — Both 05a (RL recipients) and 05b (stablecoin recipients) add initial addresses to their respective mint whitelist policies. Without whitelisted recipients, the `_update()` hook reverts on mint. Additional addresses are managed later via ops tooling or direct AuthRegistry calls.
11. **06_Verify.s.sol as automated verification** — Read-only script asserting all invariants, replaces manual checklist
12. **DeployAll.s.sol deploys exactly one stablecoin** — For multiple stablecoins on day one, run DeployAll for the first, then 04 + 05b for each additional one
13. **DeployAll.s.sol is optional convenience** — Individual scripts are the primary interface
