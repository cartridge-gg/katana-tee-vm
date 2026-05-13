# TODOs

## Tighten katana release asset pattern in release.yml

**What:** Replace the `*linux*x86_64*.tar.gz` glob in `.github/workflows/release.yml` (`gh release download`) with the exact asset name pattern published by `dojoengine/katana`.

**Why:** The glob is a guess. If katana ever publishes a second matching asset (e.g., a debug build) or renames the release asset, the workflow may silently fetch the wrong binary and embed it in the released initrd. Failure is silent and downstream — the released VM appears valid but its embedded katana is wrong.

**Context:** Confirm the current asset name with `gh release view --repo dojoengine/katana <latest tag>`. Pin that pattern; consider also verifying the binary's sha256 against the asset's checksum file if katana publishes one.

## Pin the `sev-snp` git dependency to a specific revision

**What:** `snp-tools/Cargo.toml`'s `[dependencies.sev-snp]` currently tracks `branch = "main"` of `automata-network/amd-sev-snp-attestation-sdk`. Pin to a specific commit sha (`rev = "..."`) for reproducibility.

**Why:** `branch = "main"` means a `cargo update` (or a fresh checkout with a stale lockfile) can pull in upstream changes silently. The published launch measurement is reproducible only as long as the snp-derivekey binary itself doesn't drift. The dep is in the runtime-critical path: it implements the SNP ioctl call that derives the disk-unsealing key.

**Context:** Pick a rev once snp-derivekey builds green on CI; record it in `Cargo.toml`. Mirrors how `[dependencies.sev]` should also be pinned (currently also `branch = "main"`).
