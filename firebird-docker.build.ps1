param(
    [string]$VersionFilter,       # Filter by version (e.g. '3', '4.0', '5.0.2').
    [string]$DistributionFilter,  # Filter by image distribution (e.g. 'bookworm', 'trixie', 'jammy').
    [switch]$LatestPerMajor,      # Build/test only the latest release of each major Firebird version.

    [string]$TestFilter,          # Filter by test name (e.g., 'FIREBIRD_USER_can_create_user'). Used only in the 'Test' task.

    [ValidateSet('master', 'v5.0-release', 'v4.0')]
    [string]$Branch,              # Snapshot branch. Used by 'Build-Snapshot' / 'Publish-Snapshot-Manifests'.

    [string]$Registry             # Image registry/owner prefix. Defaults to 'firebirdsql' (Docker Hub).
                                  # Override for forks: e.g. 'ghcr.io/myusername'
)

#
# Globals
#

$outputFolder = './generated'

# Effective image prefix: Registry overrides the default Docker Hub org
$script:imagePrefix = if ($Registry) { $Registry } else { 'firebirdsql' }

# Source shared functions
. "$PSScriptRoot/src/functions.ps1"



#
# Tasks
#

# Synopsis: Rebuild "assets.json" from GitHub releases using PSFirebird.
task Update-Assets {
    # PSFirebird is required for this task
    if (-not (Get-Module PSFirebird -ListAvailable)) {
        Install-Module PSFirebird -MinimumVersion '1.0.0' -Force -Scope CurrentUser
    }
    Import-Module PSFirebird -MinimumVersion '1.0.0'

    # Load current config section (distros, blocked variants, default distro)
    $currentData = Get-Content -Raw -Path './assets.json' | ConvertFrom-Json
    $script:assetsData = $currentData
    $config = $currentData.config

    $defaultDistro = $config.defaultDistro
    $allDistros = $config.distros | Get-Member -MemberType NoteProperty | ForEach-Object { $_.Name }

    # Query GitHub for all Firebird releases
    $allReleases = @()
    foreach ($majorVersion in @(5, 4, 3)) {
        Write-Output "Querying releases for Firebird $majorVersion..."

        # Find all patch versions for this major
        $apiUrl = 'https://api.github.com/repos/FirebirdSQL/firebird/releases?per_page=100'
        $headers = @{ 'User-Agent' = 'PSFirebird' }
        if ($env:GITHUB_TOKEN) {
            $headers['Authorization'] = "Bearer $($env:GITHUB_TOKEN)"
        }
        $releases = Invoke-RestMethod -Uri $apiUrl -Headers $headers

        $matchingReleases = $releases |
            Where-Object { ($_.tag_name -like "v$majorVersion.*") -and (-not $_.prerelease) } |
            ForEach-Object {
                $v = [version]($_.tag_name.TrimStart('v'))
                [PSCustomObject]@{ Version = $v; TagName = $_.tag_name }
            } |
            Sort-Object { $_.Version } -Descending

        foreach ($rel in $matchingReleases) {
            $version = $rel.Version
            if ($version -lt [version]'3.0.9') { continue }

            Write-Output "  Processing $version..."

            # Get amd64 release
            $amd64 = Find-FirebirdRelease -Version ([semver]"$version") -RuntimeIdentifier 'linux-x64'
            $releaseInfo = [ordered]@{
                amd64 = [ordered]@{
                    url    = $amd64.Url
                    sha256 = $amd64.Sha256
                }
            }

            # Get arm64 release (FB5+ only). FB3/FB4 `.arm64.tar.gz` assets are
            # Android builds with a misleading name (per asfernandes, FirebirdSQL/firebird-docker#38),
            # not Linux ARM64 — Linux ARM* packaging starts at FB5. See DECISIONS.md D-015.
            if ($majorVersion -ge 5) {
                try {
                    $arm64 = Find-FirebirdRelease -Version ([semver]"$version") -RuntimeIdentifier 'linux-arm64'
                    $releaseInfo['arm64'] = [ordered]@{
                        url    = $arm64.Url
                        sha256 = $arm64.Sha256
                    }
                } catch {
                    Write-Warning "  No arm64 release for $version"
                }
            }

            # If SHA-256 is null (pre-July 2025 releases), download to compute
            foreach ($arch in @('amd64', 'arm64')) {
                if ($releaseInfo.Contains($arch) -and -not $releaseInfo[$arch].sha256) {
                    Write-Output "    Downloading $arch asset to compute SHA-256..."
                    $tempFile = [System.IO.Path]::GetTempFileName()
                    try {
                        $ProgressPreference = 'SilentlyContinue'
                        Invoke-WebRequest $releaseInfo[$arch].url -OutFile $tempFile
                        $releaseInfo[$arch].sha256 = (Get-FileHash $tempFile -Algorithm SHA256).Hash.ToLower()
                    } finally {
                        Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
                    }
                }
            }

            $allReleases += [PSCustomObject]@{
                Version  = $version
                Major    = $majorVersion
                Releases = $releaseInfo
            }
        }
    }

    # Sort: by major desc, then version desc
    $allReleases = $allReleases | Sort-Object { $_.Major }, { $_.Version } -Descending

    # Group by major to determine latest-of-major
    $byMajor = $allReleases | Group-Object Major
    $latestOverallVersion = $allReleases[0].Version

    # Build tags
    $versions = @()
    foreach ($group in ($byMajor | Sort-Object Name -Descending)) {
        $isFirstInGroup = $true
        foreach ($rel in $group.Group) {
            $validDistros = Get-ValidDistros -Major $rel.Major
            $tags = [ordered]@{}

            foreach ($distro in $validDistros) {
                $distroTags = Get-ImageTags `
                    -Version "$($rel.Version)" `
                    -Distro $distro `
                    -IsLatestOfMajor $isFirstInGroup `
                    -IsLatestOverall ($rel.Version -eq $latestOverallVersion) `
                    -DefaultDistro $defaultDistro
                $tags[$distro] = $distroTags
            }

            $versions += [ordered]@{
                version  = "$($rel.Version)"
                releases = $rel.Releases
                tags     = $tags
            }

            $isFirstInGroup = $false
        }
    }

    # Write assets.json
    $output = [ordered]@{
        config   = $config
        versions = $versions
    }

    $output | ConvertTo-Json -Depth 10 | Out-File './assets.json' -Encoding UTF8
    Write-Output "assets.json updated with $($versions.Count) versions."
}

# Synopsis: Load the assets from "assets.json".
task LoadAssets {
    $script:assetsData = Get-Content -Raw -Path './assets.json' | ConvertFrom-Json
}

# Synopsis: Load the assets from "assets.json", optionally filtering by command-line parameters.
task FilteredAssets LoadAssets, {
    $result = $script:assetsData.versions

    # Filter assets by command-line arguments
    if ($VersionFilter) {
        $result = $result | Where-Object { $_.version -like "$VersionFilter*" }
    }

    if ($DistributionFilter) {
        $result = $result | Where-Object { $_.tags.$DistributionFilter -ne $null } |
            Select-Object -Property 'version','releases',@{Name = 'tags'; Expression = { [PSCustomObject]@{ "$DistributionFilter" = $_.tags.$DistributionFilter } } }
    }

    if ($LatestPerMajor) {
        # Keep only the first (latest) entry per major version
        $result = $result | Group-Object { ([version]$_.version).Major } | ForEach-Object { $_.Group[0] }
    }

    if (-not $result) {
        Write-Error "No assets found matching the specified filters."
        exit 1
    }

    $script:assets = $result
}

# Synopsis: Rebuild "README.md" from "assets.json".
task Update-Readme LoadAssets, {
    $assets = $script:assetsData.versions
    $TSupportedTags = $assets | ForEach-Object {
        $asset = $_
        $version = [version]$asset.version
        $versionFolder = Join-Path $outputFolder $version

        $asset.tags | Get-Member -MemberType NoteProperty | ForEach-Object {
            $image = $_.Name
            $TImageTags = $asset.tags.$image
            if ($TImageTags) {
                $TImageTags = "``{0}``" -f ($TImageTags -join "``, ``")
            }
            $variantFolder = (Join-Path $versionFolder $image).Replace('\', '/')
            Write-Output "|$TImageTags|[Dockerfile]($variantFolder/Dockerfile)|`n"
        }
    }

    $imageFullName = "$script:imagePrefix/firebird"

    $template = Get-Content './src/README.md.template' -Raw -Encoding UTF8
    $content = $template.Replace('{{SupportedTags}}', ($TSupportedTags -join ''))
    $content = $content.Replace('{{IMAGE_FULL_NAME}}', $imageFullName)
    Write-GeneratedFile -Content $content -Destination './README.md'
}

# Synopsis: Clean up the output folder.
task Clean {
    Remove-Item -Path $outputFolder -Recurse -Force -ErrorAction SilentlyContinue
}

# Synopsis: Invoke preprocessor to generate the image source files (can be filtered using command-line options).
task Prepare FilteredAssets, {
    # Create output folders if they do not exist
    New-Item -ItemType Directory $outputFolder -Force > $null

    $config = $script:assetsData.config

    # For each asset
    $assets | ForEach-Object {
        $asset = $_

        $version = [version]$asset.version
        $versionFolder = Join-Path $outputFolder $version
        New-Item -ItemType Directory $versionFolder -Force > $null

        # For each tag/distro
        $asset.tags | Get-Member -MemberType NoteProperty | ForEach-Object {
            $distribution = $_.Name
            $distributionFolder = Join-Path $versionFolder $distribution
            New-Item -ItemType Directory $distributionFolder -Force > $null

            $distroConfig = Get-DistroConfig -Distro $distribution

            # Template variables
            $hasArm64 = ($null -ne $asset.releases.arm64)
            $variables = @{
                'BASE_IMAGE'        = $distroConfig.baseImage
                'ICU_PACKAGE'       = $distroConfig.icuPackage
                'EXTRA_PACKAGES'    = if ($distroConfig.extraPackages) { "        $($distroConfig.extraPackages) \`n" } else { '' }
                'URL_AMD64'         = "$($asset.releases.amd64.url)"
                'SHA256_AMD64'      = "$($asset.releases.amd64.sha256)"
                'URL_ARM64'         = if ($hasArm64) { "$($asset.releases.arm64.url)" } else { '' }
                'SHA256_ARM64'      = if ($hasArm64) { "$($asset.releases.arm64.sha256)" } else { '' }
                'FIREBIRD_VERSION'  = "$($asset.version)"
                'FIREBIRD_MAJOR'    = "$($version.Major)"
            }

            # Render template
            $dockerfile = Expand-TemplateFile -Path './src/Dockerfile.template' -Variables $variables

            # For amd64-only versions, remove the arm64 case from the Dockerfile
            if (-not $hasArm64) {
                $dockerfile = $dockerfile -replace "(?ms)\s+arm64\)\s*\\.*?;;\s*\\", ''
            }

            Write-GeneratedFile -Content $dockerfile -Destination "$distributionFolder/Dockerfile"
            Copy-Item './src/entrypoint.sh' $distributionFolder
        }
    }
}

# Synopsis: Build all docker images (can be filtered using command-line options).
task Build Prepare, {
    $PSStyle.OutputRendering = 'PlainText'
    $config = $script:assetsData.config
    $imagePrefix = $script:imagePrefix
    $imageName = 'firebird'

    # Detect host architecture
    $hostArch = if ($IsLinux) { (dpkg --print-architecture 2>$null) ?? 'amd64' } else { 'amd64' }

    $assets | ForEach-Object {
        $asset = $_
        $version = [version]$asset.version
        $versionFolder = Join-Path $outputFolder $version

        $asset.tags | Get-Member -MemberType NoteProperty | ForEach-Object {
            $distribution = $_.Name
            $distributionFolder = Join-Path $versionFolder $distribution
            $imageTags = $asset.tags.$distribution
            $hasArm64 = ($null -ne $asset.releases.arm64)

            # Build for host architecture
            if ($hostArch -eq 'amd64') {
                $tagsAmd64 = $imageTags | ForEach-Object { '--tag', "$imagePrefix/${imageName}-amd64:$_" }
                $buildArgs = @(
                    'buildx', 'build', '--load'
                    $tagsAmd64
                    '--label', 'org.opencontainers.image.description=Firebird Database'
                    '--label', "org.opencontainers.image.version=$($asset.version)"
                    '--progress=plain'
                    $distributionFolder
                )
                Write-Build Cyan "----- [$($asset.version) / $distribution / amd64] -----"
                exec { & docker $buildArgs *>&1 }
            }

            if ($hasArm64 -and $hostArch -eq 'arm64') {
                $tagsArm64 = $imageTags | ForEach-Object { '--tag', "$imagePrefix/${imageName}-arm64:$_" }
                $buildArgs = @(
                    'buildx', 'build', '--load'
                    $tagsArm64
                    '--label', 'org.opencontainers.image.description=Firebird Database'
                    '--label', "org.opencontainers.image.version=$($asset.version)"
                    '--progress=plain'
                    $distributionFolder
                )
                Write-Build Cyan "----- [$($asset.version) / $distribution / arm64] -----"
                exec { & docker $buildArgs *>&1 }
            }
        }
    }
}

# Synopsis: Run all tests (can be filtered using command-line options).
task Test FilteredAssets, {
    $imagePrefix = $script:imagePrefix
    $imageName = 'firebird'
    $testFile = './src/image.tests.ps1'

    # Detect host architecture
    $hostArch = if ($IsLinux) { (dpkg --print-architecture 2>$null) ?? 'amd64' } else { 'amd64' }

    if ($TestFilter) {
        Write-Verbose "Running single test '$TestFilter'..."
    } else {
        Write-Verbose "Running all tests..."
        $TestFilter = '*'
    }

    $assets | ForEach-Object {
        $asset = $_
        $hasArm64 = ($null -ne $asset.releases.arm64)
        $tag = $asset.tags | Get-Member -MemberType NoteProperty | Select-Object -First 1 | ForEach-Object {
            $asset.tags.($_.Name) | Select-Object -First 1
        }

        # Skip versions not supported on the current host architecture
        if ($hostArch -eq 'arm64' -and -not $hasArm64) {
            Write-Build Yellow "----- [$($asset.version)] skipped (no arm64 build) -----"
            return
        }

        Write-Build Magenta "----- [$($asset.version)] -----"

        # Test host architecture
        $env:FULL_IMAGE_NAME = "$imagePrefix/${imageName}-${hostArch}:${tag}"
        Write-Verbose "  Image: $($env:FULL_IMAGE_NAME)"
        Invoke-Build $TestFilter $testFile
    }
}

# Synopsis: Test published images pulled directly from a registry (requires -Registry).
# Unlike Test (which uses locally built arch-specific images), this task tests the final
# published images — the same ones end users pull.
#
# Examples:
#   Invoke-Build Test-Published -Registry 'ghcr.io/myusername'
#   Invoke-Build Test-Published -Registry 'ghcr.io/myusername' -VersionFilter '5.0.3' -DistributionFilter 'bookworm'
#   Invoke-Build Test-Published -Registry 'firebirdsql'
task Test-Published FilteredAssets, {
    $imagePrefix = $script:imagePrefix
    $imageName = 'firebird'
    $testFile = './src/image.tests.ps1'

    if (-not $imagePrefix) {
        Write-Error "Use -Registry to specify which registry to test. Example: Invoke-Build Test-Published -Registry 'ghcr.io/myusername'"
        exit 1
    }

    if ($TestFilter) {
        Write-Verbose "Running single test '$TestFilter'..."
    } else {
        Write-Verbose "Running all tests..."
        $TestFilter = '*'
    }

    $assets | ForEach-Object {
        $asset = $_

        $asset.tags | Get-Member -MemberType NoteProperty | ForEach-Object {
            $distribution = $_.Name
            # Use the most-specific tag (first in list, e.g. '5.0.3-bookworm') to avoid
            # accidentally re-testing the same image under an alias tag.
            $tag = $asset.tags.$distribution | Select-Object -First 1

            Write-Build Magenta "----- [$($asset.version) / $distribution] -----"

            $env:FULL_IMAGE_NAME = "$imagePrefix/${imageName}:$tag"
            Write-Build Cyan "  Pulling $($env:FULL_IMAGE_NAME)..."
            docker pull $env:FULL_IMAGE_NAME *>&1 | Select-String 'Status:|Error' | Write-Build DarkGray
            Invoke-Build $TestFilter $testFile
        }
    }
}


# Synopsis: Retag and push images using the final name (no -arch suffix). Use for single-arch publishing.
# Produces only one package (e.g. ghcr.io/owner/firebird) with no staging intermediates.
task Publish-Direct FilteredAssets, {
    $imagePrefix = $script:imagePrefix
    $imageName = 'firebird'

    $hostArch = if ($IsLinux) { (dpkg --print-architecture 2>$null) ?? 'amd64' } else { 'amd64' }

    $assets | ForEach-Object {
        $asset = $_

        Write-Build Magenta "----- [$($asset.version) / direct] -----"

        $asset.tags | Get-Member -MemberType NoteProperty | ForEach-Object {
            $distribution = $_.Name
            $imageTags = $asset.tags.$distribution

            $imageTags | ForEach-Object {
                $tag = $_
                docker tag "$imagePrefix/${imageName}-${hostArch}:$tag" "$imagePrefix/${imageName}:$tag"
                docker push "$imagePrefix/${imageName}:$tag"
            }
        }
    }
}

# Synopsis: Push images by digest — no tags created in registry. Saves digest mapping to file.
# Run on each arch runner after Build and Test. Upload generated/digests-*.json as artifact.
task Push-Digests FilteredAssets, {
    $imagePrefix = $script:imagePrefix
    $imageName = 'firebird'
    $hostArch = if ($IsLinux) { (dpkg --print-architecture 2>$null) ?? 'amd64' } else { 'amd64' }

    $digests = [ordered]@{}

    $assets | ForEach-Object {
        $asset = $_
        $version = [version]$asset.version
        $versionFolder = Join-Path $outputFolder $version
        $hasArm64 = ($null -ne $asset.releases.arm64)

        # Skip if this arch can't build this version
        if ($hostArch -eq 'arm64' -and -not $hasArm64) {
            Write-Build Yellow "----- [$($asset.version)] skipped (no arm64 build) -----"
            return
        }

        $asset.tags | Get-Member -MemberType NoteProperty | ForEach-Object {
            $distribution = $_.Name
            $distributionFolder = Join-Path $versionFolder $distribution
            $key = "$($asset.version)/$distribution"

            # Push once per version+distro (all tags share the same image)
            if (-not $digests.Contains($key)) {
                Write-Build Cyan "----- [$($asset.version) / $distribution / $hostArch → push-by-digest] -----"

                $metadataFile = Join-Path ([System.IO.Path]::GetTempPath()) "metadata-$($asset.version)-$distribution.json"

                $buildArgs = @(
                    'buildx', 'build'
                    '--output', "type=image,name=$imagePrefix/$imageName,push-by-digest=true,name-canonical=true,push=true"
                    '--metadata-file', $metadataFile
                    '--label', 'org.opencontainers.image.description=Firebird Database'
                    '--label', "org.opencontainers.image.version=$($asset.version)"
                    '--progress=plain'
                    $distributionFolder
                )
                exec { & docker $buildArgs *>&1 }

                $metadata = Get-Content $metadataFile -Raw | ConvertFrom-Json
                $digest = $metadata.'containerimage.digest'
                $digests[$key] = $digest

                Write-Build Green "  → $digest"
            }
        }
    }

    # Save digests to file for artifact upload
    $digestFile = Join-Path $outputFolder "digests-$hostArch.json"
    New-Item -ItemType Directory (Split-Path $digestFile) -Force > $null
    $digests | ConvertTo-Json | Out-File $digestFile -Encoding UTF8
    Write-Build Green "Digests saved to $digestFile ($($digests.Count) images)"
}

# Synopsis: Create and push multi-arch manifests from digest files (run once after all arch builds complete).
# Requires digest files in generated/digests-{arch}.json (uploaded as artifacts by Push-Digests).
task Publish-Manifests FilteredAssets, {
    $imagePrefix = $script:imagePrefix
    $imageName = 'firebird'

    # Load digests from artifact files. Validate up-front so we fail fast with a
    # clear message instead of a cryptic Docker error downstream.
    $amd64DigestFile = Join-Path $outputFolder 'digests-amd64.json'
    $arm64DigestFile = Join-Path $outputFolder 'digests-arm64.json'

    function Read-DigestFile($path, $required) {
        if (-not (Test-Path $path)) {
            if ($required) {
                throw "Digest file not found: $path. Run Push-Digests first (or download artifacts)."
            }
            return $null
        }
        try {
            $parsed = Get-Content $path -Raw | ConvertFrom-Json -ErrorAction Stop
        } catch {
            throw "Digest file '$path' is not valid JSON: $($_.Exception.Message)"
        }
        $keys = @($parsed.PSObject.Properties.Name)
        if (-not $keys -or $keys.Count -eq 0) {
            throw "Digest file '$path' is empty — no digests to assemble."
        }
        $sampleKey = $keys[0]
        $sampleValue = $parsed.$sampleKey
        if ($sampleValue -notmatch '^sha256:[0-9a-f]{64}$') {
            throw "Digest file '$path' has malformed digest for key '$sampleKey': '$sampleValue'. Expected 'sha256:<64 hex>'."
        }
        Write-Build DarkGray "Loaded $($keys.Count) digests from $path (sample: $sampleKey → $sampleValue)"
        return $parsed
    }

    $amd64Digests = Read-DigestFile $amd64DigestFile -required $true
    $arm64Digests = Read-DigestFile $arm64DigestFile -required $false

    $assets | ForEach-Object {
        $asset = $_
        $hasArm64 = ($null -ne $asset.releases.arm64)

        Write-Build Magenta "----- [$($asset.version)] -----"

        $asset.tags | Get-Member -MemberType NoteProperty | ForEach-Object {
            $distribution = $_.Name
            $imageTags = $asset.tags.$distribution
            $key = "$($asset.version)/$distribution"

            $amd64Digest = $amd64Digests.$key
            if (-not $amd64Digest) {
                Write-Build Yellow "  Skipping $key (no amd64 digest found)"
                return
            }

            $sources = @("$imagePrefix/${imageName}@$amd64Digest")

            if ($hasArm64 -and $arm64Digests) {
                $arm64Digest = $arm64Digests.$key
                if ($arm64Digest) {
                    $sources += "$imagePrefix/${imageName}@$arm64Digest"
                }
            }

            $imageTags | ForEach-Object {
                $tag = $_
                Write-Build Cyan "  $tag → manifest ($($sources.Count) arch)"
                $tagArgs = @('buildx', 'imagetools', 'create', '--tag', "$imagePrefix/${imageName}:$tag") + $sources
                exec { & docker $tagArgs *>&1 }
            }
        }
    }
}

# Helper: produces { snapshotTag, major, defaultDistro } for a given snapshot branch.
function Get-SnapshotMeta($Branch) {
    if (-not $Branch) {
        throw "The -Branch parameter is required. Use: -Branch master|v5.0-release|v4.0"
    }
    $snapshotTag = switch ($Branch) {
        'master'        { '6-snapshot' }
        'v5.0-release'  { '5-snapshot' }
        'v4.0'          { '4-snapshot' }
        default         { throw "Unknown snapshot branch: $Branch" }
    }
    $major = switch ($Branch) {
        'master'        { '6' }
        'v5.0-release'  { '5' }
        'v4.0'          { '4' }
    }
    [pscustomobject]@{
        SnapshotTag   = $snapshotTag
        Major         = $major
        DefaultDistro = $script:assetsData.config.defaultDistro
    }
}

# Synopsis: Build a snapshot image and push it by digest to the registry.
# Saves the digest to generated/digests-snapshot-{arch}.json so a later
# Publish-Snapshot-Manifests run can assemble the multi-arch manifest.
# Caller must be logged into the registry before invoking this task.
task Build-Snapshot LoadAssets, {
    # PSFirebird is required for this task
    if (-not (Get-Module PSFirebird -ListAvailable)) {
        Install-Module PSFirebird -MinimumVersion '1.0.0' -Force -Scope CurrentUser
    }
    Import-Module PSFirebird -MinimumVersion '1.0.0'

    $PSStyle.OutputRendering = 'PlainText'
    $imagePrefix = $script:imagePrefix
    $imageName = 'firebird'
    $meta = Get-SnapshotMeta $Branch
    $snapshotTag = $meta.SnapshotTag
    $major = $meta.Major
    $defaultDistro = $meta.DefaultDistro

    # Detect host architecture
    $hostArch = if ($IsLinux) { (dpkg --print-architecture 2>$null) ?? 'amd64' } else { 'amd64' }
    $rid = if ($hostArch -eq 'amd64') { 'linux-x64' } else { 'linux-arm64' }

    Write-Build Cyan "Querying snapshot for branch '$Branch' ($rid)..."
    $snapshot = Find-FirebirdSnapshotRelease -Branch $Branch -RuntimeIdentifier $rid

    Write-Build Cyan "Found: $($snapshot.FileName) (uploaded: $($snapshot.UploadedAt))"

    # Prepare snapshot Dockerfile
    $snapshotFolder = Join-Path $outputFolder "snapshot-$Branch" $defaultDistro
    New-Item -ItemType Directory $snapshotFolder -Force > $null

    $distroConfig = Get-DistroConfig -Distro $defaultDistro
    $variables = @{
        'BASE_IMAGE'        = $distroConfig.baseImage
        'ICU_PACKAGE'       = $distroConfig.icuPackage
        'EXTRA_PACKAGES'    = ''
        'URL_AMD64'         = if ($hostArch -eq 'amd64') { "$($snapshot.Url)" } else { '' }
        'SHA256_AMD64'      = if ($hostArch -eq 'amd64') { "$($snapshot.Sha256)" } else { '' }
        'URL_ARM64'         = if ($hostArch -eq 'arm64') { "$($snapshot.Url)" } else { '' }
        'SHA256_ARM64'      = if ($hostArch -eq 'arm64') { "$($snapshot.Sha256)" } else { '' }
        'FIREBIRD_VERSION'  = "$snapshotTag"
        'FIREBIRD_MAJOR'    = $major
    }

    $dockerfile = Expand-TemplateFile -Path './src/Dockerfile.template' -Variables $variables

    # Remove the unused arch case
    if ($hostArch -eq 'amd64') {
        $dockerfile = $dockerfile -replace "(?ms)\s+arm64\)\s*\\.*?;;\s*\\", ''
    } else {
        $dockerfile = $dockerfile -replace "(?ms)\s+amd64\)\s*\\.*?;;\s*\\", ''
    }

    Write-GeneratedFile -Content $dockerfile -Destination "$snapshotFolder/Dockerfile"
    Copy-Item './src/entrypoint.sh' $snapshotFolder

    # Build and push by digest. Final tags (e.g. `6-snapshot`, `6-snapshot-trixie`)
    # are assembled from per-arch digests by Publish-Snapshot-Manifests.
    $metadataFile = Join-Path ([System.IO.Path]::GetTempPath()) "metadata-snapshot-$Branch.json"
    $buildArgs = @(
        'buildx', 'build'
        '--output', "type=image,name=$imagePrefix/$imageName,push-by-digest=true,name-canonical=true,push=true"
        '--metadata-file', $metadataFile
        '--label', 'org.opencontainers.image.description=Firebird Database (snapshot)'
        '--label', "org.opencontainers.image.version=$snapshotTag"
        '--progress=plain'
        $snapshotFolder
    )
    Write-Build Cyan "----- [snapshot / $Branch / $defaultDistro / $hostArch → push-by-digest] -----"
    exec { & docker $buildArgs *>&1 }

    $metadata = Get-Content $metadataFile -Raw | ConvertFrom-Json
    $digest = $metadata.'containerimage.digest'

    # Save digest for later manifest assembly
    $digestFile = Join-Path $outputFolder "digests-snapshot-$hostArch.json"
    New-Item -ItemType Directory (Split-Path $digestFile) -Force > $null
    @{ $snapshotTag = $digest } | ConvertTo-Json | Out-File $digestFile -Encoding UTF8

    Write-Build Green "Snapshot $snapshotTag pushed by digest: $digest"
    Write-Build Green "Digest saved to $digestFile"
}

# Synopsis: Assemble a multi-arch (or single-arch) manifest for a snapshot branch
# using digests previously written by Build-Snapshot. Reads
# generated/digests-snapshot-amd64.json (required) and
# generated/digests-snapshot-arm64.json (optional).
task Publish-Snapshot-Manifests LoadAssets, {
    $imagePrefix = $script:imagePrefix
    $imageName = 'firebird'
    $meta = Get-SnapshotMeta $Branch
    $snapshotTag = $meta.SnapshotTag
    $defaultDistro = $meta.DefaultDistro
    $snapshotTagWithDistro = "$snapshotTag-$defaultDistro"

    $amd64File = Join-Path $outputFolder 'digests-snapshot-amd64.json'
    $arm64File = Join-Path $outputFolder 'digests-snapshot-arm64.json'

    if (-not (Test-Path $amd64File)) {
        throw "Required digest file not found: $amd64File. Run Build-Snapshot on amd64 first."
    }
    $amd64Digest = (Get-Content $amd64File -Raw | ConvertFrom-Json).$snapshotTag
    if (-not $amd64Digest) {
        throw "No digest for '$snapshotTag' in $amd64File."
    }

    $sources = @("$imagePrefix/${imageName}@$amd64Digest")
    if (Test-Path $arm64File) {
        $arm64Digest = (Get-Content $arm64File -Raw | ConvertFrom-Json).$snapshotTag
        if ($arm64Digest) {
            $sources += "$imagePrefix/${imageName}@$arm64Digest"
        }
    }

    foreach ($tag in @($snapshotTag, $snapshotTagWithDistro)) {
        Write-Build Cyan "  $tag → manifest ($($sources.Count) arch)"
        $tagArgs = @('buildx', 'imagetools', 'create', '--tag', "$imagePrefix/${imageName}:$tag") + $sources
        exec { & docker $tagArgs *>&1 }
    }

    Write-Build Green "Snapshot manifests published: $snapshotTag, $snapshotTagWithDistro"
}

# Synopsis: Default task.
task . Build
