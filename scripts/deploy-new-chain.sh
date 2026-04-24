#!/usr/bin/env bash
# deploy-all.sh — orchestrates the full greenfield deployment by chaining
# scripts 01-05 and passing all parameters as explicit arguments (no env var
# reads inside the Solidity scripts).
#
# Usage:
#   cp .env.example .env && vi .env   # fill in all values
#   source .env
#   bash scripts/deploy-all.sh [extra forge flags]
#
# Extra forge flags (e.g. --private-key, --ledger, --account) are forwarded
# to every forge script invocation.
#
# Requires: forge, jq

set -euo pipefail

FORGE_EXTRA_FLAGS=("$@")

# ── Helpers ──────────────────────────────────────────────────────────────────

extract() {
    local key="$1"
    local text="$2"
    echo "$text" | grep -oE "${key}=0x[0-9a-fA-F]+" | head -1 | cut -d= -f2
}

extract_uint() {
    local key="$1"
    local text="$2"
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
echo ""
echo "AUTH_REGISTRY=${AUTH_REGISTRY}"

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
echo ""
echo "RESERVE_LEDGER=${RESERVE_LEDGER}"
echo "TRANSFER_POLICY_ID=${TRANSFER_POLICY_ID}"

# ── Step 03: Deploy TokenAuthority ───────────────────────────────────────────

out=$(run_script "03: Deploy TokenAuthority" \
    scripts/03_DeployTokenAuthority.s.sol \
    --sig "run(address)" "${RESERVE_LEDGER}" 2>&1 | tee /dev/stderr)

TOKEN_AUTHORITY=$(extract "TOKEN_AUTHORITY" "$out")
echo ""
echo "TOKEN_AUTHORITY=${TOKEN_AUTHORITY}"

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
echo ""
echo "STABLECOIN=${STABLECOIN}"

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
echo "===== Deployment Complete ====="
echo "AUTH_REGISTRY=${AUTH_REGISTRY}"
echo "RESERVE_LEDGER=${RESERVE_LEDGER}"
echo "TOKEN_AUTHORITY=${TOKEN_AUTHORITY}"
echo "STABLECOIN=${STABLECOIN}"
echo ""
echo "Set for verification (06_Verify.s.sol):"
echo "  AUTH_REGISTRY=${AUTH_REGISTRY} RESERVE_LEDGER=${RESERVE_LEDGER} \\"
echo "  TOKEN_AUTHORITY=${TOKEN_AUTHORITY} STABLECOIN=${STABLECOIN} \\"
echo "  forge script scripts/06_Verify.s.sol --rpc-url \$RPC_URL"
