#!/usr/bin/env bash
# End-to-end veriseal demo against a real Soroban network.
#
# Demonstrates the full story: seal the build, deploy, upgrade twice, then
# prove on-chain that (a) the current deployment is sealed and (b) the full
# upgrade lineage — including the versions that were deployed WITHOUT a seal —
# is visible and cross-checked against provenance.
#
# Prereqs: a built `veriseal` binary and the Stellar CLI (`stellar`, formerly
# soroban-cli), plus the wasm32 target:
#   rustup target add wasm32v1-none
#   cargo install soroban-cli --version 27.1.0 --locked   # provides the `stellar` CLI
#   cargo build --release --locked
#
# Env:
#   VERISEAL_BIN   path to the veriseal binary        (default: veriseal)
#   STELLAR_BIN   path to the stellar CLI           (default: stellar)
#   RPC_URL       Soroban RPC endpoint              (default: testnet)
#   NETWORK_PASSPHRASE  network passphrase          (default: testnet)
#   SOURCE_KEY    secret key of the signing account (default: generate+fund)
#
# Run from anywhere; it operates on examples/demo-contract.
set -euo pipefail

VERISEAL_BIN="${VERISEAL_BIN:-veriseal}"
STELLAR_BIN="${STELLAR_BIN:-stellar}"
RPC_URL="${RPC_URL:-https://soroban-testnet.stellar.org}"
NETWORK_PASSPHRASE="${NETWORK_PASSPHRASE:-Test SDF Network ; September 2015}"
CONTRACT_DIR="$(cd "$(dirname "$0")/.." && pwd)/examples/demo-contract"
WASM="$CONTRACT_DIR/target/wasm32v1-none/release/demo_contract.wasm"
KEY="veriseal-demo"
CONTRACT_ALIAS="veriseal-demo-contract"

log() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
fail() { printf '\n\033[1;31m!! %s\033[0m\n' "$*" >&2; exit 1; }

command -v "$VERISEAL_BIN" >/dev/null || fail "$VERISEAL_BIN not found on PATH"
command -v "$STELLAR_BIN" >/dev/null || fail "$STELLAR_BIN not found on PATH (cargo install soroban-cli)"

cd "$CONTRACT_DIR"
mkdir -p target
LIB_SRC="$CONTRACT_DIR/src/lib.rs"
cp "$LIB_SRC" /tmp/demo-lib.rs.orig
# Restore the committed source and the seal produced by this run so the tree is
# left exactly as it was found. The provenance is committed as a reproducible
# reference fixture (see README "Verify it yourself"), so restore it from git;
# fall back to removing it for checkouts that predate the fixture.
restore_provenance() {
  if git -C "$CONTRACT_DIR" ls-files --error-unmatch veriseal.provenance.json >/dev/null 2>&1; then
    git -C "$CONTRACT_DIR" checkout -- veriseal.provenance.json
  else
    rm -f "$CONTRACT_DIR/veriseal.provenance.json"
  fi
}
trap 'cp /tmp/demo-lib.rs.orig "$LIB_SRC"; restore_provenance' EXIT

log "Generating a testnet keypair to sign deploys"
if [ -n "${SOURCE_KEY:-}" ]; then
  "$STELLAR_BIN" keys add "$KEY" --secret-key "$SOURCE_KEY" --network-passphrase "$NETWORK_PASSPHRASE"
else
  if "$STELLAR_BIN" keys ls 2>/dev/null | grep -q "$KEY"; then
    "$STELLAR_BIN" keys rm "$KEY" --force >/dev/null 2>&1 || true
  fi
  "$STELLAR_BIN" keys generate "$KEY" --fund --rpc-url "$RPC_URL" --network-passphrase "$NETWORK_PASSPHRASE"
fi

log "Stage 1 — build + seal v1 (value = 1_000)"
cargo build --locked --release --target wasm32v1-none
"$VERISEAL_BIN" record

log "Stage 2 — deploy v1"
"$STELLAR_BIN" contract alias remove "$CONTRACT_ALIAS" >/dev/null 2>&1 || true
"$STELLAR_BIN" contract deploy \
  --wasm "$WASM" --alias "$CONTRACT_ALIAS" --source-account "$KEY" \
  --rpc-url "$RPC_URL" --network-passphrase "$NETWORK_PASSPHRASE"
CONTRACT_ID="$("$STELLAR_BIN" contract alias show "$CONTRACT_ALIAS" --rpc-url "$RPC_URL" --network-passphrase "$NETWORK_PASSPHRASE" | tail -1)"
log "Contract id: $CONTRACT_ID"

log "Stage 3 — prove v1 is sealed on-chain"
"$VERISEAL_BIN" onchain-verify --contract-id "$CONTRACT_ID" --rpc "$RPC_URL"

log "Stage 4 — upgrade to v2 (value = 2_000), deployed WITHOUT a seal"
sed -i 's/        1_000/        2_000/' "$CONTRACT_DIR/src/lib.rs"
cargo build --locked --release --target wasm32v1-none
WASM_HASH="$("$STELLAR_BIN" contract upload --wasm "$WASM" --source-account "$KEY" --rpc-url "$RPC_URL" --network-passphrase "$NETWORK_PASSPHRASE" | tail -1)"
"$STELLAR_BIN" contract invoke --id "$CONTRACT_ID" --source-account "$KEY" --rpc-url "$RPC_URL" --network-passphrase "$NETWORK_PASSPHRASE" -- upgrade --new-wasm-hash "$WASM_HASH" >/dev/null

log "Stage 5 — upgrade to v3 (value = 3_000), deployed WITHOUT a seal"
sed -i 's/        2_000/        3_000/' "$CONTRACT_DIR/src/lib.rs"
cargo build --locked --release --target wasm32v1-none
WASM_HASH="$("$STELLAR_BIN" contract upload --wasm "$WASM" --source-account "$KEY" --rpc-url "$RPC_URL" --network-passphrase "$NETWORK_PASSPHRASE" | tail -1)"
"$STELLAR_BIN" contract invoke --id "$CONTRACT_ID" --source-account "$KEY" --rpc-url "$RPC_URL" --network-passphrase "$NETWORK_PASSPHRASE" -- upgrade --new-wasm-hash "$WASM_HASH" >/dev/null

log "Stage 6 — audit the lineage: v1 sealed, v2/v3 unsealed, current FAILED"
set +e
"$VERISEAL_BIN" onchain-audit --contract-id "$CONTRACT_ID" --rpc "$RPC_URL"
AUDIT_EXIT=$?
set -e
[ "$AUDIT_EXIT" -eq 1 ] || fail "expected exit 1 (unsealed current), got $AUDIT_EXIT"

log "Stage 7 — seal v3 and re-audit: current PASSED"
"$VERISEAL_BIN" record --allow-dirty
"$VERISEAL_BIN" onchain-audit --contract-id "$CONTRACT_ID" --rpc "$RPC_URL"

log "Done. Contract id: $CONTRACT_ID"
