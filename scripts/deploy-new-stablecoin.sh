#!/usr/bin/env bash
# deploy-new-stablecoin.sh — deploys an additional stablecoin on an existing
# chain where AuthRegistry, ReserveLedger, and TokenAuthority are already live.
# Runs steps 04 (deploy stablecoin) and 05 (configure + handover).
#
# Usage:
#   cp .env.example .env && vi .env   # fill in stablecoin + config values
#   source .env
#   bash scripts/deploy-new-stablecoin.sh [extra forge flags]
#
# Required env vars (from prior deployment):
#   AUTH_REGISTRY, RESERVE_LEDGER, TOKEN_AUTHORITY, TRANSFER_POLICY_ID
#
# Extra forge flags (e.g. --private-key, --ledger, --account) are forwarded
# to every forge script invocation.
#
# Requires: forge

set -euo pipefail

FORGE_EXTRA_FLAGS=("$@")

# ── Validate prerequisites ───────────────────────────────────────────────────

for var in AUTH_REGISTRY RESERVE_LEDGER TOKEN_AUTHORITY TRANSFER_POLICY_ID \
           STABLECOIN_NAME STABLECOIN_SYMBOL STABLECOIN_DECIMALS SC_SALT_NONCE \
           POLICY_ADMIN RPC_URL; do
    if [[ -z "${!var:-}" ]]; then
        echo "ERROR: ${var} is not set. Source your .env first." >&2
        exit 1
    fi
done

# ── Helpers ──────────────────────────────────────────────────────────────────

extract() {
    local key="$1"
    local text="$2"
    echo "$text" | grep -oE "${key}=0x[0-9a-fA-F]+" | head -1 | cut -d= -f2
}

run_script() {
    local label="$1"; shift
    echo ""
    echo "=== ${label} ==="
    forge script "$@" \
        --rpc-url "${RPC_URL}" \
        --broadcast \
        "${FORGE_EXTRA_FLAGS[@]+"${FORGE_EXTRA_FLAGS[@]}"}"
}

# ── Step 04: Deploy Stablecoin ────────────────────────────────────────────────

SC_CONFIG="(\"${STABLECOIN_NAME}\",\"${STABLECOIN_SYMBOL}\",${STABLECOIN_DECIMALS},${POLICY_ADMIN},${SC_SALT_NONCE})"

out=$(run_script "04: Deploy Stablecoin" \
    scripts/04_DeployStablecoin.s.sol \
    --sig "run(address,address,uint64,(string,string,uint8,address,uint96))" \
    "${AUTH_REGISTRY}" "${RESERVE_LEDGER}" "${TRANSFER_POLICY_ID}" "${SC_CONFIG}" 2>&1 | tee /dev/stderr)

STABLECOIN=$(extract "STABLECOIN" "$out")
echo ""
echo "STABLECOIN=${STABLECOIN}"

# ── Step 05: Configure and Handover ──────────────────────────────────────────

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
