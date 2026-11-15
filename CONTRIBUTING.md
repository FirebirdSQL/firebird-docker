# Contributing

Thank you for your interest in contributing to Firebird Docker!

## Prerequisites

- [Docker](https://docs.docker.com/engine/install/)
- [PowerShell 7.5+](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-linux)
- [Invoke-Build](https://github.com/nightroman/Invoke-Build#install-as-module)
- [PSFirebird](https://www.powershellgallery.com/packages/PSFirebird) (v1.0.0+, installed automatically by build tasks)



## Building

To generate the source files and build all images from [`assets.json`](assets.json), run:

```bash
Invoke-Build
```

Check all created images with:

```bash
docker image ls firebirdsql/firebird
```

### Filtering builds

```bash
# Build only Firebird 5.x images
Invoke-Build Build -VersionFilter "5"

# Build only a specific version
Invoke-Build Build -VersionFilter "5.0.3"

# Build only bookworm images
Invoke-Build Build -DistributionFilter "bookworm"

# Combine filters
Invoke-Build Build -VersionFilter "4" -DistributionFilter "jammy"
```

### Building for a fork registry

Use `-Registry` to redirect all image tags to a different registry (e.g. GitHub Container Registry):

```bash
# Build tagged for ghcr.io (fork testing)
Invoke-Build Build -VersionFilter "5.0.3" -DistributionFilter "bookworm" -Registry "ghcr.io/myusername"
```



## Testing

```bash
Invoke-Build Test
```

### Filtering tests

```bash
# Test only Firebird 4.x images
Invoke-Build Test -VersionFilter "4"

# Test only bookworm images
Invoke-Build Test -DistributionFilter "bookworm"

# Run a single test by name
Invoke-Build Test -TestFilter "FIREBIRD_USER_can_create_user"

# Combine filters
Invoke-Build Test -VersionFilter "5" -DistributionFilter "noble"
```

### Testing published registry images

Use `Test-Published` to run the full test suite against images already pushed to a registry (the same final images end users pull). Requires `-Registry`.

```bash
# Test all images published to a fork's ghcr.io registry
Invoke-Build Test-Published -Registry "ghcr.io/myusername"

# Narrow down to a specific version + distro
Invoke-Build Test-Published -Registry "ghcr.io/myusername" -VersionFilter "5.0.3" -DistributionFilter "bookworm"

# Test the official Docker Hub images
Invoke-Build Test-Published -Registry "firebirdsql"
```

Unlike `Test` (which tests locally built arch-specific images), `Test-Published` pulls and tests the final multi-arch manifest — exactly what a user would run.

For snapshot images (not in `assets.json`), set `FULL_IMAGE_NAME` directly:

```bash
$env:FULL_IMAGE_NAME = "ghcr.io/myusername/firebird:6-snapshot"
Invoke-Build * ./src/image.tests.ps1
```

### Tag unit tests

```bash
Install-Module Pester -Force -SkipPublisherCheck
Invoke-Pester src/tags.tests.ps1 -Output Detailed
```



## Maintenance tasks

```bash
# Refresh assets.json from GitHub releases (requires network)
Invoke-Build Update-Assets

# Regenerate README.md from assets.json
Invoke-Build Update-Readme

# Regenerate Dockerfiles from template
Invoke-Build Prepare

# Delete generated files
Invoke-Build Clean
```



## Following a new Firebird release

Once a new Firebird release is published on GitHub:

```bash
# 1. Refresh assets.json (downloads new URLs and SHA-256 hashes)
Invoke-Build Update-Assets

# 2. Regenerate README.md
Invoke-Build Update-Readme

# 3. Regenerate Dockerfiles
Invoke-Build Prepare

# 4. Stage all changes
git add -u

# 5. Commit
git commit -m "Add Firebird X.Y.Z"
```



## Project Structure

- `assets.json` — Single source of truth for versions, URLs, SHA-256 hashes, and distro config.
- `firebird-docker.build.ps1` — InvokeBuild script with all tasks (Build, Test, Publish, etc.).
- `src/Dockerfile.template` — Single parameterized Dockerfile using `{{VAR}}` placeholders.
- `src/entrypoint.sh` — Container entrypoint script.
- `src/functions.ps1` — Shared functions (tag generation, template expansion, distro config).
- `src/image.tests.ps1` — Integration test suite (Docker required).
- `src/tags.tests.ps1` — Tag unit tests (Pester, no Docker required).
- `src/README.md.template` — README template (`{{SupportedTags}}` is replaced at generation time).
- `generated/` — Output of the `Prepare` task. Auto-generated — do not edit manually.



## Generated files

The `generated/` directory and `README.md` are produced from `assets.json` + `src/` templates. They are **tracked in git** so the README's per-variant `Dockerfile` links resolve on GitHub.

- **Do not edit files under `generated/` by hand.** Edit `assets.json` or the templates in `src/`, then run `Invoke-Build Prepare` (Dockerfiles) and `Invoke-Build Update-Readme` (README).
- After a successful publish, the `update-repo` CI job regenerates and auto-commits any drift with `[skip ci]`. Manual commits are still welcome; CI just guarantees the tip of `master` is always in sync.
- A local pre-commit hook (`.githooks/pre-commit`) regenerates when `assets.json` is staged and warns if `generated/` or `README.md` end up out of sync. Enable it once per clone:

```bash
git config core.hooksPath .githooks
```



## Key Rules

1. **`assets.json` is the single source of truth.** Never hard-code versions or URLs elsewhere.
2. **Template syntax is `{{VAR}}`.** Simple string replacement only — never `ExpandString` or `<% %>`.
3. **All tests must pass before submitting a PR.**
4. **ARM64 uses native runners only.** Never QEMU.
5. **Never hand-edit `generated/`.** Regenerate via `Invoke-Build Prepare` and stage the result.



## Reporting Issues

Please open an issue on [GitHub Issues](https://github.com/fdcastel/firebird-docker-fork/issues).
