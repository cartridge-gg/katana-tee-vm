# TODOs

## Tighten katana release asset pattern in release.yml

**What:** Replace the `*linux*x86_64*.tar.gz` glob in `.github/workflows/release.yml` (`gh release download`) with the exact asset name pattern published by `dojoengine/katana`.

**Why:** The glob is a guess. If katana ever publishes a second matching asset (e.g., a debug build) or renames the release asset, the workflow may silently fetch the wrong binary and embed it in the released initrd. Failure is silent and downstream — the released VM appears valid but its embedded katana is wrong.

**Context:** Confirm the current asset name with `gh release view --repo dojoengine/katana <latest tag>`. Pin that pattern; consider also verifying the binary's sha256 against the asset's checksum file if katana publishes one.

