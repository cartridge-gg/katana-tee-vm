#!/bin/bash
# ==============================================================================
# TEST-SNP-E2E.SH - End-to-end release test on real AMD SEV-SNP hardware
# ==============================================================================
#
# Runs ON an SNP-enabled machine (invoked over SSH by the snp-e2e workflow),
# from a checkout of this repo. Downloads a published release, boots it as a
# sealed SEV-SNP guest via start-vm.sh, and asserts the full trust story:
#
#   1. Release artifacts match their published SHA-256s.
#   2. The guest boots, Katana starts via the control channel, RPC answers.
#   3. tee_generateQuote returns a hardware attestation report whose
#      MEASUREMENT equals the published launch measurement and whose policy
#      is the documented 0x30000.
#   4. Reboot reseal: a second boot opens the existing LUKS volume (no
#      reformat) and Katana finds the already-initialized genesis — proving
#      the sealed disk is bound to the measurement and state persists.
#
# Must run as root (start-vm.sh requires it; the serial log is root-owned).
#
# Usage:
#   sudo ./scripts/test-snp-e2e.sh --tag TAG --workdir DIR
#
# The workdir is created fresh; logs land in $WORKDIR/logs (collected by the
# workflow on failure).
# ==============================================================================

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VM_REPO="${KATANA_TEE_VM_REPO:-dojoengine/katana-tee-vm}"
# Canonical UUID from build-config: makes the quote's measurement directly
# comparable to the published launch measurement.
CANONICAL_LUKS_UUID="00000000-0000-0000-0000-000000000001"
HOST_RPC="http://127.0.0.1:15051"
BOOT_TIMEOUT=360
TAG=""
WORKDIR=""
WRAPPER_PID=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tag)     TAG="${2:?--tag requires a value}"; shift 2 ;;
        --workdir) WORKDIR="${2:?--workdir requires a value}"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done
[[ -n "$TAG" && -n "$WORKDIR" ]] || { echo "Usage: $0 --tag TAG --workdir DIR" >&2; exit 1; }
[[ "$EUID" -eq 0 ]] || { echo "ERROR: must run as root" >&2; exit 1; }

log()  { echo "[snp-e2e] $*"; }
fail() { echo "[snp-e2e] FAIL: $*" >&2; exit 1; }

DISK="$WORKDIR/data.img"
LOGS="$WORKDIR/logs"

# Find the serial log path that start-vm.sh announced in its own log.
serial_log_of() {
    awk -F': *' '/^  Serial:/ { print $2; exit }' "$1"
}

# Snapshot diagnostics before any teardown (start-vm.sh deletes its serial
# log on exit).
snapshot_logs() {
    mkdir -p "$LOGS"
    cp -f "$WORKDIR"/start*.log "$LOGS/" 2>/dev/null || true
    local s
    for f in "$WORKDIR"/start*.log; do
        [[ -f "$f" ]] || continue
        s="$(serial_log_of "$f")"
        [[ -n "$s" && -f "$s" ]] && cp -f "$s" "$LOGS/serial-$(basename "$f" .log).log"
    done
}

# Kill ONLY processes belonging to this test (identified by our unique disk
# path in their command lines) — this is a shared machine.
stop_vm() {
    if [[ -n "$WRAPPER_PID" ]] && kill -0 "$WRAPPER_PID" 2>/dev/null; then
        kill "$WRAPPER_PID" 2>/dev/null || true
        for _ in $(seq 1 10); do kill -0 "$WRAPPER_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$WRAPPER_PID" 2>/dev/null || true
    fi
    WRAPPER_PID=""
    pkill -f "[q]emu-system-x86_64.*${DISK}" 2>/dev/null || true
    for _ in $(seq 1 10); do pgrep -f "[q]emu-system-x86_64.*${DISK}" >/dev/null || break; sleep 1; done
    pkill -9 -f "[q]emu-system-x86_64.*${DISK}" 2>/dev/null || true
}

on_exit() {
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        snapshot_logs
        echo "[snp-e2e] diagnostics saved to $LOGS"
    fi
    stop_vm
    exit "$rc"
}
trap on_exit EXIT INT TERM

# ------------------------------------------------------------------------------
# Preflight
# ------------------------------------------------------------------------------
log "Preflight"
[[ -e /dev/sev ]] || fail "/dev/sev not present — not an SNP host?"
[[ "$(cat /sys/module/kvm_amd/parameters/sev_snp 2>/dev/null)" == "Y" ]] || fail "kvm_amd sev_snp not enabled"
for t in qemu-system-x86_64 socat curl python3 mkfs.ext4 dd; do
    command -v "$t" >/dev/null || fail "missing tool: $t"
done

# Clean leftovers from previous runs of THIS test only, then check the port.
pkill -f "[q]emu-system-x86_64.*/snp-e2e/" 2>/dev/null || true
sleep 2
if curl -s --max-time 2 -o /dev/null "$HOST_RPC"; then
    fail "port 15051 already in use by a foreign process — refusing to continue on a shared machine"
fi

rm -rf "$WORKDIR"
mkdir -p "$WORKDIR" "$LOGS"

# ------------------------------------------------------------------------------
# Release artifacts
# ------------------------------------------------------------------------------
log "Downloading release $TAG"
curl -fsSL -o "$WORKDIR/release.tar.gz" \
    "https://github.com/${VM_REPO}/releases/download/${TAG}/katana-tee-vm-${TAG}.tar.gz" \
    || fail "could not download release tarball for $TAG"
mkdir -p "$WORKDIR/boot"
tar xzf "$WORKDIR/release.tar.gz" -C "$WORKDIR/boot"

BUILD_INFO="$WORKDIR/boot/build-info.txt"
[[ -f "$BUILD_INFO" ]] || fail "release tarball has no build-info.txt"
info_get() { awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$BUILD_INFO"; }

EXPECTED_MEASUREMENT="$(info_get LAUNCH_MEASUREMENT)"
RELEASE_LUKS_UUID="$(info_get LUKS_UUID)"
[[ -n "$EXPECTED_MEASUREMENT" ]] || fail "build-info has no LAUNCH_MEASUREMENT"
[[ "$RELEASE_LUKS_UUID" == "$CANONICAL_LUKS_UUID" ]] \
    || fail "release measurement is bound to LUKS_UUID '$RELEASE_LUKS_UUID', expected canonical '$CANONICAL_LUKS_UUID'"

log "Verifying artifact checksums"
for pair in "OVMF.fd:OVMF_SHA256" "vmlinuz:KERNEL_SHA256" "initrd.img:INITRD_SHA256"; do
    f="${pair%%:*}"; k="${pair##*:}"
    actual="$(sha256sum "$WORKDIR/boot/$f" | awk '{print $1}')"
    expected="$(info_get "$k")"
    [[ "$actual" == "$expected" ]] || fail "$f sha256 mismatch (got $actual, recorded $expected)"
done
log "Checksums OK; expected measurement: $EXPECTED_MEASUREMENT"

dd if=/dev/zero of="$DISK" bs=1M count=1024 status=none

# ------------------------------------------------------------------------------
# Boot helpers
# ------------------------------------------------------------------------------
launch_vm() {
    local startlog="$1"
    ( cd "$REPO_DIR" && nohup ./start-vm.sh \
        --ovmf "$WORKDIR/boot/OVMF.fd" \
        --kernel "$WORKDIR/boot/vmlinuz" \
        --initrd "$WORKDIR/boot/initrd.img" \
        --data-disk "$DISK" \
        --luks-uuid "$CANONICAL_LUKS_UUID" \
        > "$startlog" 2>&1 & echo $! > "$WORKDIR/wrapper.pid" )
    WRAPPER_PID="$(cat "$WORKDIR/wrapper.pid")"
}

wait_running() {
    local startlog="$1"
    local waited=0
    while true; do
        grep -q "Status: running pid=" "$startlog" 2>/dev/null && return 0
        if grep -qE "^Error:|Timeout" "$startlog" 2>/dev/null; then
            tail -30 "$startlog" >&2
            fail "start-vm.sh reported an error (see $startlog)"
        fi
        kill -0 "$WRAPPER_PID" 2>/dev/null || { tail -30 "$startlog" >&2; fail "start-vm.sh exited prematurely"; }
        sleep 5; waited=$((waited + 5))
        [[ "$waited" -lt "$BOOT_TIMEOUT" ]] || { tail -30 "$startlog" >&2; fail "timed out waiting for Katana (${BOOT_TIMEOUT}s)"; }
    done
}

rpc() {
    curl -s --max-time 30 -X POST -H "Content-Type: application/json" -d "$1" "$HOST_RPC"
}

# Returns "measurement policy" parsed from a tee_generateQuote response.
# The response is passed via the environment and the Python source via a
# quoted heredoc — no shell escaping inside the Python at all (a previous
# version used escaped quotes inside a single-quoted -c string, which reach
# Python as literal backslashes and are a syntax error).
quote_fields() {
    QUOTE_JSON="$(rpc '{"jsonrpc":"2.0","id":1,"method":"tee_generateQuote","params":[null,0]}')" \
    python3 <<'PYEOF'
import json, os, sys

r = json.loads(os.environ["QUOTE_JSON"])
if "error" in r:
    sys.exit("tee_generateQuote error: %s" % r["error"])
q = bytes.fromhex(r["result"]["quote"].removeprefix("0x"))
print(q[0x90:0x90+48].hex(), hex(int.from_bytes(q[8:16], "little")))
PYEOF
}

# ------------------------------------------------------------------------------
# Boot 1: fresh disk — format, attest, compare measurement
# ------------------------------------------------------------------------------
log "Boot 1: fresh sealed disk"
launch_vm "$WORKDIR/start1.log"
wait_running "$WORKDIR/start1.log"
log "Katana running"

CHAIN_ID="$(rpc '{"jsonrpc":"2.0","method":"starknet_chainId","id":1}' | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"])')"
[[ "$CHAIN_ID" == "0x4b4154414e41" ]] || fail "unexpected chainId: $CHAIN_ID"
log "RPC OK (chainId $CHAIN_ID)"

read -r MEASUREMENT1 POLICY1 <<< "$(quote_fields)"
log "quote 1: measurement=$MEASUREMENT1 policy=$POLICY1"
[[ "$POLICY1" == "0x30000" ]] || fail "unexpected guest policy: $POLICY1"
[[ "$MEASUREMENT1" == "$EXPECTED_MEASUREMENT" ]] \
    || fail "measurement does not match published release:
  quote:     $MEASUREMENT1
  published: $EXPECTED_MEASUREMENT"
log "measurement matches published release"

# ------------------------------------------------------------------------------
# Boot 2: reboot reseal + state persistence
# ------------------------------------------------------------------------------
# Give the guest time to write back its page cache before the stop. The VM
# has no host-triggerable graceful shutdown path (init's teardown only runs
# on a guest-side TERM, which nothing external sends; QEMU SIGTERM is a
# power cut), so a stop right after genesis initialization can catch the
# database before ext2 writeback (~30s) persists it — boot 2 then fails
# with "failed to open database". Remove this once the control channel
# grows a graceful `stop` command.
log "Waiting 45s for guest writeback before stopping the VM"
sleep 45

log "Boot 2: reboot with existing sealed disk"
stop_vm
launch_vm "$WORKDIR/start2.log"
wait_running "$WORKDIR/start2.log"

SERIAL2="$(serial_log_of "$WORKDIR/start2.log")"
[[ -n "$SERIAL2" && -f "$SERIAL2" ]] || fail "cannot locate serial log of boot 2"
grep -aq "No LUKS header" "$SERIAL2" \
    && fail "boot 2 reformatted the disk — sealed state was lost (derived key mismatch?)"
grep -aq "Genesis has already been initialized" "$SERIAL2" \
    || fail "boot 2 did not find the existing genesis — state did not persist"

read -r MEASUREMENT2 _ <<< "$(quote_fields)"
[[ "$MEASUREMENT2" == "$EXPECTED_MEASUREMENT" ]] || fail "boot 2 measurement drifted: $MEASUREMENT2"
log "reseal OK: existing LUKS opened, genesis persisted, measurement stable"

# ------------------------------------------------------------------------------
log "Tearing down"
stop_vm
rm -rf "$WORKDIR"
trap - EXIT
echo ""
echo "=========================================="
echo "SNP E2E PASS: $TAG"
echo "  measurement: $MEASUREMENT1"
echo "=========================================="
