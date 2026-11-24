#!/usr/bin/env bash
# Deploys the Rosca contracts to Arc mainnet from YOUR machine with YOUR key.
# Arc Studio does not run this script, sign, or fund anything on mainnet.
#
# Required environment variables (no defaults, on purpose):
#   PRIVATE_KEY        deployer key. Keep it in your shell or a keystore, never in a file in this repo.
#   ADMIN              address that can only pause or unpause creating NEW groups. Use a multisig.
#   MIN_PHI_BPS        minimum holdback in basis points (10000 = 100%)
#   MIN_DEPOSIT_BPS    minimum deposit as basis points of the installment
#   MIN_C              minimum installment, in USDC base units (6 decimals)
#   MAX_C              maximum installment, in USDC base units (6 decimals)
#   MAX_DURATION       maximum group length in seconds
# Optional:
#   GATE               existing PassportGate address. Leave unset to disable the Passport gate.
#   ATTESTER           if set and GATE is unset, deploys a new PassportGate trusting this address
#
# These values are immutable once deployed. Choose them from your own loss cap and review.

set -euo pipefail
cd "$(dirname "$0")/.."

need() { [ -n "${!1:-}" ] || { echo "Missing required variable: $1" >&2; exit 1; }; }
for v in PRIVATE_KEY ADMIN MIN_PHI_BPS MIN_DEPOSIT_BPS MIN_C MAX_C MAX_DURATION; do need "$v"; done

ZERO=0x0000000000000000000000000000000000000000
RPC="$(bun -e "import { requireChain } from './src/onchain-facts'; console.log(requireChain(5042).rpcUrls[0])")"
CHAIN_ID="$(cast chain-id --rpc-url "$RPC")"
[ "$CHAIN_ID" = "5042" ] || { echo "Expected chain id 5042 (Arc mainnet), got $CHAIN_ID" >&2; exit 1; }

DEPLOYER="$(cast wallet address --private-key "$PRIVATE_KEY")"
echo "Network:    Arc mainnet (chain $CHAIN_ID)"
echo "Deployer:   $DEPLOYER"
echo "Admin:      $ADMIN"
echo "Gate:       ${GATE:-${ATTESTER:+new gate trusting $ATTESTER}}"
echo "Floors:     phi>=$MIN_PHI_BPS bps, deposit>=$MIN_DEPOSIT_BPS bps, C in [$MIN_C, $MAX_C], duration<=$MAX_DURATION s"
echo
echo "This sends real transactions that cannot be undone."
read -r -p "Type DEPLOY to continue: " ok
[ "$ok" = "DEPLOY" ] || { echo "Cancelled."; exit 1; }

forge build >/dev/null

deploy() { # <path:Name> [constructor args...]
  local target="$1"; shift
  local out
  if [ "$#" -gt 0 ]; then
    out="$(forge create "$target" --rpc-url "$RPC" --private-key "$PRIVATE_KEY" --broadcast --json --constructor-args "$@")"
  else
    out="$(forge create "$target" --rpc-url "$RPC" --private-key "$PRIVATE_KEY" --broadcast --json)"
  fi
  printf '%s' "$out" | python3 -c "import json,sys; print(json.load(sys.stdin)['deployedTo'])"
}

IMPL="$(deploy contracts/RoscaGroup.sol:RoscaGroup)"
echo "RoscaGroup implementation: $IMPL"

if [ -n "${GATE:-}" ]; then
  GATE_ADDR="$GATE"
elif [ -n "${ATTESTER:-}" ]; then
  GATE_ADDR="$(deploy contracts/PassportGate.sol:PassportGate "$ATTESTER")"
  echo "PassportGate: $GATE_ADDR"
else
  GATE_ADDR="$ZERO"
  echo "Passport gate disabled (address zero)."
fi

FACTORY="$(deploy contracts/GroupFactory.sol:GroupFactory "$ADMIN" "$IMPL" "$GATE_ADDR" "$MIN_PHI_BPS" "$MIN_DEPOSIT_BPS" "$MIN_C" "$MAX_C" "$MAX_DURATION")"
echo "GroupFactory: $FACTORY"

echo
echo "Read back from chain (verify these against what you intended):"
echo "  admin          $(cast call "$FACTORY" 'admin()(address)' --rpc-url "$RPC")"
echo "  implementation $(cast call "$FACTORY" 'implementation()(address)' --rpc-url "$RPC")"
echo "  gate           $(cast call "$FACTORY" 'gate()(address)' --rpc-url "$RPC")"
REGISTRY="$(cast call "$FACTORY" 'registry()(address)' --rpc-url "$RPC")"
echo "  registry       $REGISTRY"
echo
echo "Add these lines to .env, then rebuild the app:"
echo "VITE_ROSCA_NETWORK=mainnet"
echo "VITE_ROSCA_MAINNET_FACTORY_ADDRESS=$FACTORY"
echo "VITE_ROSCA_MAINNET_REGISTRY_ADDRESS=$REGISTRY"
echo "VITE_ROSCA_MAINNET_GATE_ADDRESS=$GATE_ADDR"
echo "VITE_ROSCA_MAINNET_ADMIN_ADDRESS=$ADMIN"
