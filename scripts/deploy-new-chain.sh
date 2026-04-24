#!/usr/bin/env bash
# deploy-new-chain.sh — bootstraps shared infrastructure on a new chain:
#   01. AuthRegistry
#   02. ReserveLedger  (+ transfer and mint-recipient policies)
#   03. TokenAuthority
#
# Run this once per chain. After this, use deploy-new-stablecoin.sh for each
# stablecoin you want to deploy on this chain.
#
# Usage:
#   cp .env.example .env && vi .env   # fill in chain + RL config
#   source .env
#   bash scripts/deploy-new-chain.sh [extra forge flags]
#
# Extra forge flags (e.g. --private-key, --ledger, --account) are forwarded
# to every forge script invocation.
#
# Requires: forge

set -euo pipefail

FORGE_EXTRA_FLAGS=("$@")

# ── Helpers ──────────────────────────────────────────────────────────────────

extract() {
    local key="$1" text="$2"
    echo "$text" | grep -oE "${key}=0x[0-9a-fA-F]+" | head -1 | cut -d= -f2
}

extract_uint() {
    local key="$1" text="$2"
    echo "$text" | grep -oE "${key}=[0-9]+" | head -1 | cut -d= -f2
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

# ── Step 01: Deploy AuthRegistry ─────────────────────────────────────────────

out=$(run_script "01: Deploy AuthRegistry" \
    scripts/01_DeployAuthRegistry.s.sol 2>&1 | tee /dev/stderr)

AUTH_REGISTRY=$(extract "AUTH_REGISTRY" "$out")

# ── Step 02: Deploy ReserveLedger ────────────────────────────────────────────
#
# TokenConfig tuple: (string name, string symbol, uint8 decimals, address policyAdmin, uint96 saltNonce)
#
RL_CONFIG="(\"${RL_NAME}\",\"${RL_SYMBOL}\",${RL_DECIMALS},${POLICY_ADMIN},${RL_SALT_NONCE})"

out=$(run_script "02: Deploy ReserveLedger" \
    scripts/02_DeployReserveLedger.s.sol \
    --sig "run(address,(string,string,uint8,address,uint96))" \
    "${AUTH_REGISTRY}" "${RL_CONFIG}" 2>&1 | tee /dev/stderr)

RESERVE_LEDGER=$(extract "RESERVE_LEDGER" "$out")
TRANSFER_POLICY_ID=$(extract_uint "TRANSFER_POLICY_ID" "$out")

# ── Step 03: Deploy TokenAuthority ───────────────────────────────────────────

out=$(run_script "03: Deploy TokenAuthority" \
    scripts/03_DeployTokenAuthority.s.sol \
    --sig "run(address)" "${RESERVE_LEDGER}" 2>&1 | tee /dev/stderr)

TOKEN_AUTHORITY=$(extract "TOKEN_AUTHORITY" "$out")

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "===== Chain Infrastructure Deployed ====="
echo "AUTH_REGISTRY=${AUTH_REGISTRY}"
echo "RESERVE_LEDGER=${RESERVE_LEDGER}"
echo "TOKEN_AUTHORITY=${TOKEN_AUTHORITY}"
echo "TRANSFER_POLICY_ID=${TRANSFER_POLICY_ID}"
echo ""
echo "Deploy a stablecoin on this chain:"
echo "  bash scripts/deploy-new-stablecoin.sh \\"
echo "    ${AUTH_REGISTRY} ${RESERVE_LEDGER} ${TOKEN_AUTHORITY} ${TRANSFER_POLICY_ID}"
