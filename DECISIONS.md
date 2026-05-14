# Architecture Decisions

Decisions made during the v2 rewrite, with rationale.

## D-001: Single Dockerfile.template

**Decision:** Replace 4 per-distro templates with a single parameterized `src/Dockerfile.template`.

**Rationale:** The old templates were nearly identical, differing only in base image, ICU package, and extra packages. Distro-specific config is now in `assets.json` `config.distros` and injected via `{{VAR}}` placeholders.

## D-002: Safe template expansion

**Decision:** Replace `Expand-Template` (which used `$ExecutionContext.InvokeCommand.ExpandString`) with `{{VAR}}` string replacement.

**Rationale:** `ExpandString` evaluates arbitrary PowerShell expressions, creating a code injection risk. The new `Expand-TemplateFile` function only replaces `{{KEY}}` with values from a hashtable — no expression evaluation.

## D-003: Tag algorithm

**Decision:** Deterministic tag generation via `Get-ImageTags` function with parameters: Version, Distro, IsLatestOfMajor, IsLatestOverall, DefaultDistro.

**Tags produced:**
- Always: `{version}-{distro}` (e.g. `5.0.3-bookworm`)
- If latest of major: `{major}-{distro}` (e.g. `5-bookworm`)
- If latest overall: `{distro}` (e.g. `bookworm`)
- Default distro only: `{version}`, `{major}`, `latest`

**Rationale:** Every image has a fully-qualified immutable tag. The `-{distro}` suffix (Issue #34) enables pulling specific OS variants. Only the default distro gets bare tags to avoid confusion.

## D-004: Tini as PID 1

**Decision:** Install `tini` in the image and use `ENTRYPOINT ["tini", "--"]` instead of running entrypoint.sh as PID 1.

**Rationale:** Shell scripts don't handle signals properly as PID 1 (no zombie reaping, inconsistent SIGTERM forwarding). Tini is the standard solution, weighing ~20KB.

## D-005: STOPSIGNAL SIGTERM

**Decision:** Set `STOPSIGNAL SIGTERM` in the Dockerfile.

**Rationale:** Firebird's fbguard/firebird processes handle SIGTERM for graceful shutdown. Docker's default is also SIGTERM, but being explicit documents the intent.

## D-006: SQL injection prevention in entrypoint.sh

**Decision:** Escape single quotes in passwords via `escape_sql_string()` before interpolating into SQL.

**Rationale:** Passwords like `it's_me` would break SQL syntax or enable injection. The function doubles single quotes (`'` → `''`), which is the standard SQL escape.

## D-007: blockedVariants in assets.json

**Decision:** Use a `blockedVariants` config map to exclude incompatible version+distro combinations (e.g. FB3 on Noble).

**Rationale:** Firebird 3 depends on `libncurses5`, which was removed from Ubuntu Noble. Rather than special-casing in code, we declare blocked combinations in config.

**Amended by D-017** for the FB3 + (Noble | Trixie) carve-out: the mechanism remains, but the FB3 entries have been cleared and the missing dependency is now provisioned in the template.

## D-008: Fork CI scope — latest release per major version

**Decision:** On forks (non-official repo, non-`workflow_dispatch`), CI builds and tests only the latest release of each major Firebird version (e.g. 5.0.3, 4.0.6, 3.0.13). The official repository always performs a full build of all versions.

**Rationale:** A full matrix (17 versions × 4 distros × 2 arches) takes 17+ minutes on forks where contributors verify a single change. The latest of each major is sufficient to catch regressions across the version range. The official repo and manual `workflow_dispatch` runs always build everything. Controlled via the `LatestPerMajor` switch in `firebird-docker.build.ps1`.

## D-009: No QEMU in CI

**Decision:** Build only the host architecture locally and in CI. Multi-arch manifests are created during publish using native runners.

**Rationale:** QEMU builds are 5-10x slower and unreliable. When ARM64 runners are available, they build natively.

## D-010: PSFirebird for release discovery

**Decision:** Use the `PSFirebird` PowerShell module (`Find-FirebirdRelease`, `Find-FirebirdSnapshotRelease`) instead of custom GitHub API calls.

**Rationale:** Centralizes Firebird release parsing, SHA256 verification, and snapshot discovery. Published on PSGallery as `PSFirebird` v1.0.0+.

## D-011: Snapshot images

**Decision:** Daily snapshot builds from `master` (FB6) and `v5.0-release` branches, tagged as `{major}-snapshot`.

**Rationale:** Pre-release testing is valuable for the community. Snapshot tags are clearly distinguished and never collide with release tags.

## D-012: Trixie as default distro

**Decision:** The `defaultDistro` in `assets.json` is `trixie` (Debian 13). Bare tags (`5.0.4`, `5`, `latest`) resolve to the Trixie variant.

**Rationale:** Trixie is the current Debian stable — it ships newer library versions (libicu76, OpenSSL 3.x, glibc 2.41) that match what a fresh deployment would pull elsewhere. Bookworm remains available as `*-bookworm` tags for users who prefer the previous LTS for production stability. Users who want to pin should use the explicit `*-bookworm` or `*-bullseye` tags; the bare tags move forward with Debian stable.

## D-013: Digest-based multi-arch assembly

**Decision:** Use `docker buildx` with `push-by-digest=true` to push per-arch images without creating any staging tags. Multi-arch manifests are assembled via `docker buildx imagetools create` from raw SHA256 digests.

**Rationale:** The previous approach pushed staging tags (`firebird:tag-amd64`, `firebird:tag-arm64`) into the main Docker Hub package, polluting it with implementation artifacts. The digest-based approach — used by major projects like `postgres`, `nginx`, and `redis` — keeps the registry clean. Image digests are passed between GitHub Actions jobs via artifacts.

## D-014: Generated Dockerfiles are tracked in git

**Decision:** The `generated/` directory is committed to the repository. After a successful publish, a workflow job (`update-repo`) regenerates the Dockerfiles and README and auto-commits any changes with `[skip ci]`.

**Rationale:** README links to per-variant `Dockerfile`s (e.g. `generated/5.0.4/trixie/Dockerfile`) need valid targets on GitHub. Keeping the output in git guarantees the links work without requiring contributors to regenerate locally. Auto-commit prevents drift: the committed files always reflect the last successful publish. Contributors must not edit `generated/` by hand — run `Invoke-Build Prepare` to regenerate. The `[skip ci]` marker on the auto-commit prevents a trigger loop.

## D-015: No ARM64 for Firebird 3.x / 4.x

**Decision:** The ARM64 discovery gate in `Update-Assets` is `$majorVersion -ge 5`. FB3 and FB4 are published as amd64-only, even though `.arm64.tar.gz` assets exist in their GitHub releases.

**Rationale:** The FB3/FB4 `.arm64.tar.gz` files are **Android builds with a misleading filename**, not Linux ARM64 — confirmed by asfernandes in [FirebirdSQL/firebird-docker#38](https://github.com/FirebirdSQL/firebird-docker/issues/38): "These are Android builds manually built by Alex. Names are very misleading. But better names were introduced in v5 only, as well Linux ARM* packages." Their internal layout reflects this (pre-extracted `firebird/` tree with `AfterUntar.sh`, no `install.sh`), which is why our Dockerfile template cannot consume them — but the deeper reason is that they are fundamentally the wrong binaries for a Linux container. No upstream packaging fix will change this for existing FB3/FB4 releases; any future "teach the template two install paths" workaround would install Android binaries on Linux and must be rejected. When FB3.x or FB4.x ships a future point release with a true Linux ARM64 bundle, the gate can be widened on a per-version basis.

## D-016: `init_db` pipes `*.sql` files into `isql` (does not redirect)

**Decision:** In `init_db()`, run plain SQL files as `cat "$f" | process_sql`, not `process_sql < "$f"`.

**Rationale:** `isql` reads stdin one byte per `read()` syscall (no stdio buffer is set up on stdin). With `cat | isql`, those byte-reads come from a kernel pipe (in-memory, lock-free). With `isql < file`, every byte-read goes through the regular-file path (i_rwsem, atime, FS layer). On native disk this is a ~25 % cost on init.d-driven schema loads; on layered or remote filesystems (Docker Desktop bind mounts on macOS/Windows, gRPC FUSE / virtiofs, NFS) per-syscall overhead amplifies it into 10×+ slowdowns — see [issue #40](https://github.com/FirebirdSQL/firebird-docker/issues/40). The pipe form is also consistent with the compressed cases (`*.sql.gz`, `*.sql.xz`, `*.sql.zst`) which already use a decompressor pipeline. `process_sql` itself stays redirect-friendly so callers other than `init_db` are unaffected.

## D-017: Re-enable Firebird 3 on Trixie and Noble via .deb side-load

**Decision:** Stop excluding `noble` and `trixie` from FB3 builds. Provision `libncurses5`/`libtinfo5` for FB3 by downloading the corresponding `.deb` files from the bookworm (for Trixie) and jammy (for Noble) archive pools and installing them with `dpkg -i`. Clears `blockedVariants["3"]`.

**Rationale:** D-007 declared FB3+Noble unsupportable because `libncurses5` had been dropped from Noble's apt sources, and chose a config-level block over template special-casing. Debian Trixie has since dropped the same packages, which would have required adding Trixie to the block list — defeating the intent of D-012 (Trixie as default distro). The FB3 binaries' only remaining unresolved dependencies on Trixie/Noble are `libncurses.so.5` and `libtinfo.so.5` (verified by `ldd`); the corresponding `.deb` files are still served by the bookworm and jammy archive pools and install cleanly. The workaround is localized to one `RUN` block in the template, gated on `FIREBIRD_MAJOR == 3` and keyed off `/etc/os-release`. Supersedes the FB3 + (Noble | Trixie) clause of D-007. See [issue #42](https://github.com/FirebirdSQL/firebird-docker/issues/42).

Also adds `tzdata` to Noble's distro `extraPackages` (matching Jammy). FB3 relies on libc `localtime()` for the `TZ` env var, which requires `/usr/share/zoneinfo` — the Ubuntu Noble base image, like Jammy, ships without it. FB4+ embeds its own zoneinfo and is unaffected, which is why the gap surfaced only when re-enabling FB3 builds on Noble.
