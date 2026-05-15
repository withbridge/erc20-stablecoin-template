# verify-policies

Verify that intended blacklist/whitelist addresses are correctly enforced on-chain for a given token.

Given a JSON input file with a token address and a list of expected addresses, the script checks each address against the token's auth policy using `isAuthorized()`. Reports mismatches where the on-chain state doesn't match expectations.

## Install

```bash
cd tools/verify-policies
npm install
```

## Usage

```bash
npx tsx index.ts --input <file.json>
```

Multiple files:

```bash
npx tsx index.ts --input examples/base-rd-transfer-whitelist.json --input examples/base-ofac-blacklist-deelusd.json
```

## Input file format

```json
{
  "name": "Base OFAC Blacklist (DeelUSD)",
  "rpc_url": "https://base-mainnet.g.alchemy.com/v2/...",
  "chain_id": 8453,
  "auth_registry": "0x73531Fc88a2A537C668F17cd1B1117C45C15185D",
  "token": "0x73b5d86deae56497f852fd79dd6fe68c7270fb6b",
  "policy_type": "transfer",
  "expected_addresses": [
    "0x04dba1194ee10112fe6c3207c0687def0e78bacf"
  ]
}
```

Fields:
- `name`: human-readable label for output
- `rpc_url`: chain RPC endpoint (public or Alchemy/Infura)
- `chain_id`: expected chain ID (script aborts on mismatch)
- `auth_registry`: AuthRegistry contract address on that chain
- `token`: token contract to verify
- `policy_type`: `"transfer"` or `"mint_recipient"`
- `expected_addresses`: addresses that should be enforced

## How it works

1. Reads the token's policy ID (`getTransferPolicyId` or `getMintRecipientPolicyId`)
2. Reads the policy type (WHITELIST or BLACKLIST) from the AuthRegistry
3. For each address, calls `isAuthorized(policyId, address)`:
   - **WHITELIST**: expects `true` (address is authorized)
   - **BLACKLIST**: expects `false` (address is blocked)
4. Reports mismatches

## Exit codes

- `0`: all checks passed
- `1`: one or more mismatches found
