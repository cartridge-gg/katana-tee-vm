# AMD SEV-SNP TEE Build Scripts

Build scripts for creating TEE (Trusted Execution Environment) components to run Katana inside AMD SEV-SNP confidential VMs.

## Requirements

- **QEMU 10.2.0** - Only tested with this version. Earlier versions may lack required SEV-SNP features.
  ```sh
  # Build from source using the provided script
  ./scripts/build-qemu.sh
  ```
- AMD EPYC processor with SEV-SNP support
- Host kernel with SEV-SNP enabled

## Quick Start

```sh
# Build everything (OVMF, kernel, initrd) with a prebuilt katana binary.
# Download katana from https://github.com/dojoengine/katana/releases.
./build.sh --katana /path/to/katana
```

Output is written to `output/qemu/`.

### Katana Binary

`--katana` is required when building the initrd. Download a prebuilt linux-gnu binary from [dojoengine/katana releases](https://github.com/dojoengine/katana/releases) (the `*_linux_amd64.tar.gz` portable build).

For reproducibility, the initrd does not copy glibc or shared libraries from the build host. Instead, `scripts/build-initrd.sh` downloads the exact runtime `.deb` packages listed in `build-config`, verifies their SHA-256 checksums, then copies the ELF interpreter and the shared libraries declared by Katana with `readelf`. If providing a custom dynamic binary with `--katana`, build it against a glibc compatible with the pinned runtime and make sure any extra shared libraries it needs are covered by `GLIBC_RUNTIME_PACKAGES` and `GLIBC_RUNTIME_PACKAGE_SHA256S`.

## Layout

| Path | Description |
|------|-------------|
| `build.sh` | Orchestrator entry point — builds OVMF, kernel, initrd; writes `build-info.txt` |
| `start-vm.sh` | Starts a TEE VM with SEV-SNP and launches Katana asynchronously (consumer-facing) |
| `verify-build.sh` | Verifies sha256s + sealed launch measurement of a build / downloaded release |
| `build-config` | Pinned versions and checksums for reproducible builds |
| `scripts/build-ovmf.sh` | Builds OVMF firmware from AMD's fork with SEV-SNP support |
| `scripts/build-kernel.sh` | Downloads and extracts Ubuntu kernel (`vmlinuz`) |
| `scripts/build-initrd.sh` | Creates minimal initrd with busybox, SEV-SNP modules, snp-derivekey, cryptsetup, and katana |
| `scripts/build-cryptsetup.sh` | Builds static cryptsetup + mkfs.ext2 in an Alpine container |
| `scripts/build-qemu.sh` | Builds QEMU 10.2.0 from source with SEV-SNP support (operator host setup, not part of build pipeline) |
| `scripts/sealed-cmdline.sh` | Single source of truth for the measured kernel cmdline |
| `scripts/test-initrd.sh` | Isolated initrd boot smoke test in plain QEMU |
| `snp-tools/` | Cargo crate with `snp-digest`, `snp-report`, `ovmf-metadata`, `snp-derivekey` |

## SNP Tools

The `snp-tools` crate provides CLI utilities for SEV-SNP development:

| Binary | Description |
|--------|-------------|
| `snp-digest` | Calculate SEV-SNP launch measurement digest |
| `snp-report` | Decode and display SEV-SNP attestation reports |
| `ovmf-metadata` | Extract and display OVMF SEV metadata sections |
| `snp-derivekey` | Derive a sealed-storage key via `SNP_GET_DERIVED_KEY` (runs in-guest; used by the initrd to unlock the LUKS data disk) |

Build with:
```sh
cargo build -p snp-tools
```

## Output Files

| File | Description |
|------|-------------|
| `OVMF.fd` | UEFI firmware with SEV-SNP support |
| `vmlinuz` | Linux kernel |
| `initrd.img` | Initial ramdisk containing katana |
| `katana` | Katana binary (copied from build) |
| `build-info.txt` | Build metadata and checksums |

## Running

`start-vm.sh` launches a TEE VM with SEV-SNP enabled and starts Katana inside it:

```sh
# Start VM with default boot components (output/qemu/)
sudo ./start-vm.sh

# Or specify a custom boot components directory
sudo ./start-vm.sh /path/to/boot-components

# Or customize Katana runtime flags (comma-separated)
sudo ./start-vm.sh --katana-args "--http.addr,0.0.0.0,--http.port,5050,--tee,sev-snp,--dev"

# Or boot without starting Katana (drive the control channel manually)
sudo ./start-vm.sh --no-start
```

The script:
- Starts QEMU with SEV-SNP confidential computing enabled
- Uses direct kernel boot with `kernel-hashes=on` for attestation
- Creates (on first run) and attaches a persistent data disk as `/dev/sda` — default `~/.katana/data.img`, override with `--data-disk` or `$KATANA_DATA_DISK`
- Boots with **sealed storage** by default: the data disk is wrapped in LUKS2 + dm-integrity and unlocked inside the guest via `SNP_GET_DERIVED_KEY`. The measured kernel cmdline is `console=ttyS0 KATANA_EXPECTED_LUKS_UUID=<uuid>`; the UUID is generated once per host, persisted at `~/.katana/luks-uuid`, and can be overridden with `--luks-uuid` or `$KATANA_LUKS_UUID`
- With `--unsealed`, skips sealed storage (plain ext4 on `/dev/sda`) and keeps the cmdline at `console=ttyS0` — this produces a different (and separately pinnable) launch measurement from the sealed boot
- Starts Katana asynchronously via a virtio-serial control channel
- Forwards RPC port 5050 to host port 15051
- Outputs serial log to a temp file and follows it

### Manual QEMU Invocation

For reference, this is roughly what `start-vm.sh` runs under the hood. The inline comments make it non-copy-pasteable; see `start-vm.sh` for the exact invocation.

```sh
qemu-system-x86_64 \
    # Use KVM hardware virtualization (required for SEV-SNP)
    -enable-kvm \
    # AMD EPYC CPU with SEV-SNP support
    -cpu EPYC-v4 \
    # Q35 machine type with confidential computing enabled, referencing sev0 object
    -machine q35,confidential-guest-support=sev0 \
    # SEV-SNP guest configuration:
    #   policy=0x30000    - Guest policy flags (SMT allowed, debug disabled)
    #   cbitpos=51        - C-bit position in page table entries (memory encryption bit)
    #   reduced-phys-bits - Physical address bits reserved for encryption
    #   kernel-hashes=on  - Include kernel/initrd/cmdline hashes in attestation report,
    #                       allowing remote verifiers to confirm exact boot components
    # 
    # Reference: https://www.qemu.org/docs/master/system/i386/amd-memory-encryption.html#launching-sev-snp
    -object sev-snp-guest,id=sev0,policy=0x30000,cbitpos=51,reduced-phys-bits=1,kernel-hashes=on \
    # OVMF firmware with SEV-SNP support (measures itself into attestation)
    -bios output/qemu/OVMF.fd \
    # Direct kernel boot (kernel is measured when kernel-hashes=on)
    -kernel output/qemu/vmlinuz \
    # Initial ramdisk containing katana (measured when kernel-hashes=on)
    -initrd output/qemu/initrd.img \
    # Kernel command line (measured when kernel-hashes=on).
    # Unsealed variant shown; the sealed (default) variant appends
    # KATANA_EXPECTED_LUKS_UUID=<uuid> (see scripts/sealed-cmdline.sh)
    -append "console=ttyS0" \
    # Data disk, attached as /dev/sda — REQUIRED, the guest init panics
    # without it. Unsealed mode expects an ext4 filesystem on the raw disk;
    # sealed mode expects raw (luksFormat'd on first boot) or LUKS2
    -device virtio-scsi-pci,id=scsi0 \
    -drive file=$HOME/.katana/data.img,format=raw,if=none,id=disk0,cache=none \
    -device scsi-hd,drive=disk0,bus=scsi0.0 \
    # Katana control channel (used to start Katana asynchronously after boot)
    -device virtio-serial-pci,id=virtio-serial0 \
    -chardev socket,id=katanactl,path=/tmp/katana-control.sock,server=on,wait=off \
    -device virtserialport,chardev=katanactl,name=org.katana.control.0 \
    ..
```

### Start Katana via Control Channel

In the QEMU example above, this line defines the host-side control channel endpoint:

```sh
-chardev socket,id=katanactl,path=/tmp/katana-control.sock,server=on,wait=off
```

The `path=/tmp/katana-control.sock` value is the Unix socket file on the host
(`start-vm.sh` uses `/tmp/katana-tee-vm-control.<pid>.sock` and prints the path at startup).
That socket is connected to the guest virtio-serial port:

```sh
-device virtserialport,chardev=katanactl,name=org.katana.control.0
```

So writes to that Unix socket become control commands inside the VM:

| Command | Responses |
|---------|-----------|
| `start <comma-separated-args>` | `ok started pid=<pid>`, `err already-running pid=<pid>` |
| `status` | `running pid=<pid>`, `stopped exit=<code>` |

Example:

```sh
# Start Katana with comma-separated CLI args. Keep stdin open briefly after
# the command: if socat closes the socket as soon as stdin EOFs, QEMU drops
# the guest's reply (the command itself still executes)
{ printf 'start --http.addr,0.0.0.0,--http.port,5050,--tee,sev-snp\n'; sleep 2; } \
  | socat -t 2 - UNIX-CONNECT:/tmp/katana-control.sock

# Check launcher status
{ printf 'status\n'; sleep 2; } | socat -t 2 - UNIX-CONNECT:/tmp/katana-control.sock
```

The guest always pins Katana's database to the data disk mount by passing its
own `--db-dir`, and strips any `--db-*` flags from the supplied args.

## Isolated Initrd Testing

Use `test-initrd.sh` for focused initrd boot validation without the full SEV-SNP launch path:

```sh
# Run plain-QEMU boot smoke test
./scripts/test-initrd.sh

# Custom timeout/output directory
./scripts/test-initrd.sh --output-dir ./output/qemu --timeout 300
```

## Launch Measurement Verification

To verify a TEE VM's integrity, compute the expected launch measurement using `snp-digest`:

```sh
# Build the SNP tools
cargo build -p snp-tools

# Sealed boot (start-vm.sh default): the measured cmdline carries the
# per-host LUKS UUID from ~/.katana/luks-uuid
./target/debug/snp-digest \
    --ovmf output/qemu/OVMF.fd \
    --kernel output/qemu/vmlinuz \
    --initrd output/qemu/initrd.img \
    --append "console=ttyS0 KATANA_EXPECTED_LUKS_UUID=$(cat ~/.katana/luks-uuid)" \
    --vcpus 1 \
    --cpu epyc-v4 \
    --vmm qemu \
    --guest-features 0x1

# Unsealed boot (start-vm.sh --unsealed): same command with
#   --append "console=ttyS0"
```

`start-vm.sh` prints the exact `snp-digest` command for its configuration at startup.
The computed measurement should match the `measurement` field in the attestation report.

## Decoding Attestation Reports

Katana running inside a TEE exposes an RPC endpoint to retrieve attestation reports:

```sh
curl -X POST http://localhost:15051 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tee_generateQuote","params":[null,0]}'
```

Params are `[prevBlockId, blockId]`; pass `null` as `prevBlockId` for the genesis block.

Example response (abridged — the exact field set depends on the Katana version):
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "quote": "0x05000000000000000000030000000000000000000000000000000000000000000000000000000000000000000000000001000000010000000a000000000018546700000000000000000000000000000005e1f35913fe09ee5c672a1f1f941dbef203852e79fd118afe9fc09c0e2c242d0000000000000000000000000000000000000000000000000000000000000000a61905c576e54ec9ac77f55ccbc2200eefa5b0613139700ebf16984517634cf14e054792b45ff1a3f4af8922be06d09c000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000023dbf8e0935cca11f2b9bdb518f313296eaa53d743c340b90c342fd4fb8eaaffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff0a0000000000185419110100000000000000000000000000000000000000000001b884fdb43aeab96927fda3a7675bc1d679ca24cde425f6f1c4975749888d3a12aa09535f6eb816553af6d59e278da7e2912acecbc657db12612423f85efd140a000000000018542a3701002a3701000a000000000018540000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000008468441401989b660464e8e9e2643a38cc397fef0f3c302d30600c6409e0f286f6011aad3013ef48a337f6fdd93142c70000000000000000000000000000000000000000000000003cadd7de8ed2fbea2b6f29fa46962d2ce1ed8e5451a1745ee288508648e42182f839e90312797af942c601f9080d3c7d0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
    "stateRoot": "0x1d89a119a324817db2eeee4b68ab886d40ef1f6812768882db55c4b82e0701b",
    "blockHash": "0x13ff95ae61d6da161cc0c9493199a655ff3e25acce2babdc447efccbf09909c",
    "blockNumber": 0
  }
}
```

Use `snp-report` to decode the `quote` field:

```sh
# Decode the attestation report
./target/debug/snp-report --hex "0x05000000..."

# Or pipe from jq
curl -s -X POST http://localhost:15051 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tee_generateQuote","params":[0,1]}' \
  | jq -r '.result.quote' \
  | ./target/debug/snp-report
```

The output includes:
- **Version**: Report format version (5 = Turin/Genoa)
- **Measurement**: Launch digest to compare against expected value
- **Guest Policy**: Security policy flags (debug, SMT, etc.)
- **TCB Version**: Platform firmware versions
- **Report Data**: User-provided data included in the report
- **Signature**: ECDSA signature for verification

## OVMF Metadata Inspection

Use `ovmf-metadata` to inspect the OVMF firmware's SEV metadata sections:

```sh
./target/debug/ovmf-metadata --ovmf output/qemu/OVMF.fd
```

## Reproducible Builds

Set `SOURCE_DATE_EPOCH` for deterministic output:

```sh
SOURCE_DATE_EPOCH=$(git log -1 --format=%ct) ./build.sh --katana /path/to/katana
```

If unset, `build.sh` warns loudly and falls back to the current wall-clock time
(non-reproducible).

## Troubleshooting

### `SEV: guest firmware hashes table area is invalid (base=0x0 size=0x0)`

**Error:**
```
qemu-system-x86_64: SEV: guest firmware hashes table area is invalid (base=0x0 size=0x0)
```

**Cause:** You are using a standard OVMF firmware (`OvmfPkgX64.dsc`) instead of the AMD SEV OVMF firmware (`AmdSevX64.dsc`) with `kernel-hashes=on`.

When `kernel-hashes=on` is enabled, QEMU needs to inject SHA-256 hashes of the kernel, initrd, and command line into a reserved memory region in the OVMF firmware. The AMD SEV OVMF reserves a 1KB region for this hash table (`PcdQemuHashTableBase=0x010C00`, `PcdQemuHashTableSize=0x000400`), while the standard OVMF has no such region (base=0x0, size=0x0).

**Solution:** Use the OVMF firmware built from `AmdSevX64.dsc`. The `build-ovmf.sh` script already handles building a compatible version from AMD's fork:

```sh
# Use the OVMF built by build.sh or build-ovmf.sh
-bios output/qemu/OVMF.fd

# Or rebuild it manually:
source build-config && ./scripts/build-ovmf.sh ./output/qemu
```

Do not use generic OVMF builds from your distribution or other sources when using `kernel-hashes=on` with SEV-SNP.

**Reference:** [AMD's OVMF fork](https://github.com/AMDESE/ovmf) (branch `snp-latest`) contains the SEV-SNP support and hash table memory region required for direct kernel boot with attestation.
