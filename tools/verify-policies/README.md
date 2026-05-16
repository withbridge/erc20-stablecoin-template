# verify-policies

Verify that intended blacklist/whitelist addresses are correctly enforced on-chain for a given token. Supports verifying the same address list across all EVM chains in a single run.

## Install

```bash
cd tools/verify-policies
npm install
```

## Usage

```bash
npx tsx index.ts --input <file.json>
```

Filter to specific chains in a multi-chain config:

```bash
npx tsx index.ts --input examples/ofac-blacklist-all-chains.json --chain Base --chain Ethereum
```

## Input file formats

### Multi-chain (recommended)

Defines addresses once and verifies them across multiple chains/tokens:

```json
{
  "name": "OFAC Blacklist — All EVM Chains",
  "expected_addresses": [
    "0x04dba1194ee10112fe6c3207c0687def0e78bacf",
    "0x..."
  ],
  "chains": [
    {
      "name": "Base",
      "rpc_url": "https://mainnet.base.org",
      "chain_id": 8453,
      "auth_registry": "0x73531Fc88a2A537C668F17cd1B1117C45C15185D",
      "tokens": [
        { "address": "0x73b5d86deae56497f852fd79dd6fe68c7270fb6b", "policy_type": "transfer" }
      ]
    },
    {
      "name": "Ethereum",
      "rpc_url": "https://ethereum-rpc.publicnode.com",
      "chain_id": 1,
      "auth_registry": "0x69026c540cda3d42a1530d0fa3feb092d0bc944d",
      "tokens": []
    }
  ]
}
```

Chains with an empty `tokens` array are skipped with a message.

### Single-chain (legacy)

```json
{
  "name": "Base OFAC Blacklist (DeelUSD)",
  "rpc_url": "https://mainnet.base.org",
  "chain_id": 8453,
  "auth_registry": "0x73531Fc88a2A537C668F17cd1B1117C45C15185D",
  "token": "0x73b5d86deae56497f852fd79dd6fe68c7270fb6b",
  "policy_type": "transfer",
  "expected_addresses": [
    "0x04dba1194ee10112fe6c3207c0687def0e78bacf"
  ]
}
```

## How it works

1. Reads the token's policy ID (`getTransferPolicyId` or `getMintRecipientPolicyId`)
2. Reads the policy type (WHITELIST or BLACKLIST) from the AuthRegistry
3. For each address, calls `isAuthorized(policyId, address)`:
   - **WHITELIST**: expects `true` (address is authorized)
   - **BLACKLIST**: expects `false` (address is blocked)
4. Reports mismatches

## Options

| Flag | Description |
|------|-------------|
| `--input`, `-i` | Input JSON file (required, repeatable) |
| `--chain`, `-c` | Filter to specific chain name(s) in multi-chain files (optional, repeatable) |

## Exit codes

- `0`: all checks passed
- `1`: one or more mismatches found
