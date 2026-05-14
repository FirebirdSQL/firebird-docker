# AGENTS.md — Guidelines for AI Agents

## Project
Firebird Docker images. PowerShell (InvokeBuild) build system generating Dockerfiles from templates.

## Structure
```
assets.json                    # Source of truth: versions, URLs, SHA-256, distro config
firebird-docker.build.ps1      # InvokeBuild: Update-Assets, Prepare, Build, Test, Publish
src/Dockerfile.template        # Single parameterized Dockerfile ({{VAR}} placeholders)
src/entrypoint.sh              # Container entrypoint (bash)
src/image.tests.ps1            # Integration tests (InvokeBuild tasks)
src/README.md.template         # README generator
.github/workflows/             # CI, Publish, Snapshot workflows
```

## Key Rules
- `assets.json` is the single source of truth. Never hard-code versions or URLs elsewhere.
- Use `{{VAR}}` template syntax (simple string replacement). Never `<% %>` or `ExpandString`.
- PSFirebird v1.0.0+ from PSGallery is a dependency. Do NOT reference `./tmp/PSFirebird/`.
- `./tmp/` is for temporary files only. Never commit or reference in production code.
- Default distro: `bookworm`. Blocked: none.
- ARM64 only for Firebird 5+. No QEMU — use native ARM64 GitHub runners.
- All tags computed deterministically from version matrix via `Get-ImageTags`.

## Build Commands
```powershell
Invoke-Build Update-Assets                          # Refresh assets.json from GitHub
Invoke-Build Prepare                                # Generate Dockerfiles from template
Invoke-Build Build                                  # Build all images
Invoke-Build Test                                   # Run all tests
Invoke-Build Build -VersionFilter 5 -DistributionFilter bookworm  # Filtered
```

## Testing
- Tests use `InvokeBuild` tasks in `src/image.tests.ps1`
- Tests require Docker daemon running
- Filter: `-TestFilter 'task_name'`
- PSFirebird used in tests for DB operations via `inet://` protocol

## Documentation
- `README.md` — End users (auto-generated from template)
- `DEVELOPMENT.md` — Local dev setup, testing, debugging
- `DECISIONS.md` — Architectural Decision Records
- `AGENTS.md` — This file

## CI/CD
- `ci.yaml` — Build+test on push/PR. Full matrix (amd64 + arm64) on all repos. Forks: latest release per major version only. Official repo or `workflow_dispatch`: all versions. Filtered via workflow_dispatch inputs.
- `publish.yaml` — Official repo only. Build+test+push to Docker Hub.
- `snapshot.yaml` — Snapshot pre-release images from FirebirdSQL/snapshots.

When pushing commits, use `gh` command to monitor the workflow execution.