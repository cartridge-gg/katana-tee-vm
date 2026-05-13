# TODOs

## Tighten katana release asset pattern in release.yml

**What:** Replace the `*linux*x86_64*.tar.gz` glob in `.github/workflows/release.yml` (`gh release download`) with the exact asset name pattern published by `dojoengine/katana`.

**Why:** The glob is a guess. If katana ever publishes a second matching asset (e.g., a debug build) or renames the release asset, the workflow may silently fetch the wrong binary and embed it in the released initrd. Failure is silent and downstream — the released VM appears valid but its embedded katana is wrong.

**Context:** Confirm the current asset name with `gh release view --repo dojoengine/katana <latest tag>`. Pin that pattern; consider also verifying the binary's sha256 against the asset's checksum file if katana publishes one.

## Fix build.sh standalone-mode PROJECT_ROOT assumption

**What:** `build.sh` lines 162, 200, 249 compute `PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"`, assuming the script lives at `<katana>/misc/AMDSEV/build.sh`. In this standalone repo `${SCRIPT_DIR}/../..` resolves to the wrong directory (e.g. `/Users/.../cartridge-gg/`).

**Why:** Today, CI always passes `--katana <path>` so the release path works. But `PROJECT_ROOT` is also used for (a) `scripts/build-gnu.sh` (the build-from-source fallback when `--katana` is omitted), (b) `target/x86_64-unknown-linux-musl/.../snp-derivekey`, and (c) `target/cryptsetup-static` for sealed-storage builds. (b) and (c) still fire and may fail or use stale paths. Local dev without a sibling katana checkout hits this immediately.

**Context:** Options — require `--katana` always (drop the build-from-source fallback), or accept a `KATANA_REPO=/path` env var to point at an external checkout. Pick one and apply consistently across all three call sites.
