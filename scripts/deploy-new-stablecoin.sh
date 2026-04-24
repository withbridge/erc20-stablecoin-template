#!/usr/bin/env bash
# deploy-new-stablecoin.sh — deploys and configures a new stablecoin on an
# existing chain that already has AuthRegistry, ReserveLedger, and
# TokenAuthority deployed.
#
# Usage:
#   source .env   # fill in stablecoin config vars (see .env.example)
#   bash scripts/deploy-new-stablecoin.sh \
#     <AUTH_REGISTRY> <RESERVE_LEDGER> <TOKEN_AUTHORITY> <TRANSFER_POLICY_ID> \
#     [extra forge flags]
#
# The first four positional arguments are the chain infrastructure addresses
# output by deploy-new-chain.sh.
#
# Requires: forge

set -euo pipefail

if [[ $# -lt 4 ]]; then
    echo "Usage: $0 <AUTH_REGISTRY> <RESERVE_LEDGER> <TOKEN_AUTHORITY> <TRANSFER_POLICY_ID> [forge flags]"
    exit 1
fi

AUTH_REGISTRY="$1"
RESERVE_LEDGER="$2"
TOKEN_AUTHORITY="$3"
TRANSFER_POLICY_ID="$4"
shift 4

FORGE_EXTRA_FLAGS=("$@")

# ── Helpers ──────────────────────────────────────────────────────────────────

extract() {
    local key="$1" text="$2"
    echo "$text" | grep -oE "${key}=0x[0-9a-fA-F]+" | head -1 | cut -d= -f2
}

run_script() {
    local label="$1"; shift
    echo ""
    echo "=== ${label} ==="
    forge script "$@" \
        --rpc-url "${RPC_URL}" \
        --broadcast \
        --verify \
        --etherscan-api-key "${ETHERSCAN_API_KEY}" \
        "${FORGE_EXTRA_FLAGS[@]+"${FORGE_EXTRA_FLAGS[@]}"}"
}

# ── Step 04: Deploy Stablecoin ────────────────────────────────────────────────
#
# TokenConfig tuple: (string name, string symbol, uint8 decimals, address policyAdmin, uint96 saltNonce)
#
SC_CONFIG="(\"${STABLECOIN_NAME}\",\"${STABLECOIN_SYMBOL}\",${STABLECOIN_DECIMALS},${POLICY_ADMIN},${SC_SALT_NONCE})"

out=$(run_script "04: Deploy Stablecoin" \
    scripts/04_DeployStablecoin.s.sol \
    --sig "run(address,address,uint64,(string,string,uint8,address,uint96))" \
    "${AUTH_REGISTRY}" "${RESERVE_LEDGER}" "${TRANSFER_POLICY_ID}" "${SC_CONFIG}" 2>&1 | tee /dev/stderr)

STABLECOIN=$(extract "STABLECOIN" "$out")

# ── Step 05: Configure and Handover ──────────────────────────────────────────
#
# HandoverConfig tuple fields (in order):
#   uint256 txnMintLimit
#   address minterAddress
#   uint256 minterAllowance
#   uint256 rlMaxSupply
#   uint256 stablecoinMaxSupply
#   address pauserAddress
#   address unpauserAddress
#   address blockedAddressBurnerAddress
#   address rlAdmin
#   address stablecoinAdmin
#   address tokenAuthorityAdmin
#
HANDOVER_CONFIG="(${TXN_MINT_LIMIT},${MINTER_ADDRESS},${MINTER_ALLOWANCE},${RL_MAX_SUPPLY},${STABLECOIN_MAX_SUPPLY},${PAUSER_ADDRESS},${UNPAUSER_ADDRESS},${BLOCKED_ADDRESS_BURNER_ADDRESS},${RL_ADMIN},${STABLECOIN_ADMIN},${TOKEN_AUTHORITY_ADMIN})"

run_script "05: Configure and Handover" \
    scripts/05_ConfigureAndHandover.s.sol \
    --sig "run(address,address,address,(uint256,address,uint256,uint256,uint256,address,address,address,address,address,address))" \
    "${RESERVE_LEDGER}" "${TOKEN_AUTHORITY}" "${STABLECOIN}" "${HANDOVER_CONFIG}"

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "===== Stablecoin Deployed ====="
echo "STABLECOIN=${STABLECOIN}"
echo ""
echo "Verify:"
echo "  AUTH_REGISTRY=${AUTH_REGISTRY} RESERVE_LEDGER=${RESERVE_LEDGER} \\"
echo "  TOKEN_AUTHORITY=${TOKEN_AUTHORITY} STABLECOIN=${STABLECOIN} \\"
echo "  forge script scripts/06_Verify.s.sol --rpc-url \$RPC_URL"
