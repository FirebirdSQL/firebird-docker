param(
    [string]$VersionFilter,       # Filter by version (e.g. '3', '4.0', '5.0.2').
    [string]$DistributionFilter,  # Filter by image distribution (e.g. 'bookworm', 'bullseye', 'jammy').

    [string]$TestFilter           # Filter by test name (e.g., 'FIREBIRD_USER_can_create_user'). Used only in the 'Test' task.
)

#
# Globals
#

$outputFolder = './generated'

$defaultVariant = 'bookworm'

$blockedVariants = @{'3' = @('noble') }    # Ubuntu 24.04 doesn't have libncurses5.



#
# Functions
#

function Expand-Template([Parameter(ValueFromPipeline = $true)]$Template) {
    $evaluator = {
        $innerTemplate = $args[0].Groups[1].Value
        $ExecutionContext.InvokeCommand.ExpandString($innerTemplate)
    }
    $regex = [regex]"\<\%(.*?)\%\>"
    $regex.Replace($Template, $evaluator)
}

function Copy-TemplateItem([string]$Path, [string]$Destination) {
    if (Test-Path $Destination) {
        # File already exists: Remove readonly flag (if set).
        $outputFile = Get-Item $Destination
        $outputFile | Set-ItemProperty -Name IsReadOnly -Value $false
    }

    # Add header
    $fileExtension = $Destination.Split('.')[-1]
    $header = if ($fileExtension -eq 'md') {
        @'

[//]: # (This file was auto-generated. Do not edit. See /src.)

'@
    } else {
        @'
#
# This file was auto-generated. Do not edit. See /src.
#

'@
    }
    $header | Set-Content $Destination -Encoding UTF8

    # Expand template
    Get-Content $Path -Raw -Encoding UTF8 |
        Expand-Template |
            Add-Content $Destination -Encoding UTF8

    # Set readonly flag (another reminder to not edit the file)
    $outputFile = Get-Item $Destination
    $outputFile | Set-ItemProperty -Name IsReadOnly -Value $true
}

function Use-CachedResponse {
    param(
        [Parameter(Mandatory = $true)]
        [string]$JsonFile,

        [scriptblock]$ScriptBlock
    )

    if (Test-Path $JsonFile) {
        return Get-Content $JsonFile | ConvertFrom-Json
    }

    $result = Invoke-Command -ScriptBlock $ScriptBlock
    return $result | ConvertTo-Json -Depth 10 | Out-File $JsonFile -Encoding utf8
}



#
# Tasks
#

# Synopsis: Rebuild "assets.json" from GitHub releases.
task Update-Assets {
    $tempFolder = [System.IO.Path]::GetTempPath()

    $releasesFile = Join-Path $tempFolder 'github-releases.json'
    $assetsFolder = Join-Path $tempFolder 'firebird-assets'
    New-Item $assetsFolder -ItemType Directory -Force > $null

    # All github releases
    $releases = Use-CachedResponse -JsonFile $releasesFile { Invoke-RestMethod -Uri "https://api.github.com/repos/FirebirdSQL/firebird/releases" -UseBasicParsing }

    # Ignore legacy and prerelease
    $currentReleases = $releases | Where-Object { ($_.tag_name -like 'v*') -and (-not $_.prerelease) }

    # Select only amd64/arm64 and non-debug assets
    $currentAssets = $currentReleases |
        Select-Object -Property @{ Name='version'; Expression={ [version]$_.tag_name.TrimStart("v") } },
                                @{ Name='download_url'; Expression={ $_.assets.browser_download_url | Where-Object { ( $_ -like '*amd64*' -or $_ -like '*linux-x64*' -or $_ -like '*linux-arm64*') -and ($_ -notlike '*debug*') } } } |
        Sort-Object -Property version -Descending

    # Group by major version
    $groupedAssets = $currentAssets |
        Select-Object -Property @{ Name='major'; Expression={ $_.version.Major } }, 'version', 'download_url' |
        Group-Object -Property 'major' |
        Sort-Object -Property Name -Descending

    # Get Variants
    $dockerFiles = Get-Item './src/Dockerfile.*.template'
    $allOtherVariants = $dockerFiles.Name |
        Select-String -Pattern 'Dockerfile.(.+).template' |
        ForEach-Object { $_.Matches.Groups[1].Value } |
        Where-Object { $_ -ne $defaultVariant }
    $allVariants = @($defaultVariant) + $otherVariants

    # For each asset
    $groupedAssets | ForEach-Object -Begin { $groupIndex = 0 } -Process {
        # For each major version
        $_.Group | ForEach-Object -Begin { $index = 0 } -Process {
            $asset = $_

            # Remove blocked variants

            $otherVariants = $allOtherVariants | Where-Object { $_ -notin $blockedVariants."$($asset.major)" }
            $variants = $allVariants | Where-Object { $_ -notin $blockedVariants."$($asset.major)" }

            $releases = $asset.download_url | ForEach-Object {
                $url = [uri]$_
                $assetFileName = $url.Segments[-1]
                $assetLocalFile = Join-Path $assetsFolder $assetFileName
                if (-not (Test-Path $assetLocalFile)) {
                    $ProgressPreference = 'SilentlyContinue'    # How NOT to implement a progress bar -- https://stackoverflow.com/a/43477248
                    Invoke-WebRequest $url -OutFile $assetLocalFile
                }

                $sha256 = (Get-FileHash $assetLocalFile -Algorithm SHA256).Hash.ToLower()

                if ($url -like '*arm64*') {
                    [ordered]@{
                        arm64 =
                            [ordered]@{
                                url = $url
                                sha256 = $sha256
                            }
                    }
                } else {
                    [ordered]@{
                        amd64 =
                            [ordered]@{
                                url = $url
                                sha256 = $sha256
                            }
                    }
                }
            }

            $tags = [ordered]@{}

            $tags[$defaultVariant] = @("$($asset.version)")
            $otherVariants | ForEach-Object {
                $tags[$_] = @("$($asset.version)-$_")
            }

            if ($index -eq 0) {
                # latest of this major version
                $tags[$defaultVariant] = @("$($asset.major)") + $tags[$defaultVariant]
                $otherVariants | ForEach-Object {
                    $tags[$_] = @("$($asset.major)-$_") + $tags[$_]
                }
            }

            if (($groupIndex -eq 0) -and ($index -eq 0)) {
                # latest of all
                $tags[$defaultVariant] += 'latest'
                $otherVariants | ForEach-Object {
                    $tags[$_] = @("$_") + $tags[$_]
                }
            }

            Write-Output ([ordered]@{
                'version' = "$($asset.version)"
                'releases' = $releases
                'tags' = $tags
            })

            $index++
        }
        $groupIndex++
    } | ConvertTo-Json -Depth 10 | Out-File './assets.json' -Encoding ascii
}

# Synopsis: Rebuild "README.md" from "assets.json".
task Update-Readme {
    # For each asset
    $assets = Get-Content -Raw -Path '.\assets.json' | ConvertFrom-Json
    $TSupportedTags = $assets | ForEach-Object {
        $asset = $_

        $version = [version]$asset.version
        $versionFolder = Join-Path $outputFolder $version

        # For each image
        $asset.tags | Get-Member -MemberType NoteProperty | ForEach-Object {
            $image = $_.Name

            $TImageTags = $asset.tags.$image
            if ($TImageTags) {
                # https://stackoverflow.com/a/73073678
                $TImageTags = "``{0}``" -f ($TImageTags -join "``, ``")
            }

            $variantFolder = (Join-Path $versionFolder $image).Replace('\', '/')

            Write-Output "|$TImageTags|[Dockerfile]($variantFolder/Dockerfile)|`n"
        }
    }

    Copy-TemplateItem "./src/README.md.template" './README.md'
}

# Synopsis: Clean up the output folder.
task Clean {
    Remove-Item -Path $outputFolder -Recurse -Force -ErrorAction SilentlyContinue
}

# Synopsis: Load the assets from "assets.json", optionally filtering it by command-line parameters.
task FilteredAssets {
    $result = Get-Content -Raw -Path '.\assets.json' | ConvertFrom-Json

    # Filter assets by command-line arguments
    if ($VersionFilter) {
        $result = $result | Where-Object { $_.version -like "$VersionFilter*" }
    }

    if ($DistributionFilter) {
        $result = $result | Where-Object { $_.tags.$DistributionFilter -ne $null } |
            # Remove tags that do not match the distribution filter
            Select-Object -Property 'version','releases',@{Name = 'tags'; Expression = { [PSCustomObject]@{ "$DistributionFilter" = $_.tags.$DistributionFilter } } }
    }

    if (-not $result) {
        Write-Error "No assets found matching the specified filters."
        exit 1
    }

    $script:assets = $result
}

# Synopsis: Invoke preprocessor to generate the image source files (can be filtered using command-line options).
task Prepare FilteredAssets, {
    # Create output folders if they do not exist
    New-Item -ItemType Directory $outputFolder -Force > $null
    New-Item -ItemType Directory (Join-Path $outputFolder 'logs') -Force > $null

    # For each asset
    $assets | ForEach-Object {
        $asset = $_

        $version = [version]$asset.version
        $versionFolder = Join-Path $outputFolder $version
        New-Item -ItemType Directory $versionFolder -Force > $null

        # For each tag
        $asset.tags | Get-Member -MemberType NoteProperty | ForEach-Object {
            $distribution = $_.Name
            $distributionFolder = Join-Path $versionFolder $distribution
            New-Item -ItemType Directory $distributionFolder -Force > $null

            # Set variables for the template
            $THasArchARM64 = ($asset.releases.arm64.url -ne $null -and $distribution -ne 'bullseye' -and $distribution -ne 'jammy' ?
                '$true' : '$false')

            $TUrlArchAMD64 = $asset.releases.amd64.url
            $TSha256ArchAMD64 = $asset.releases.amd64.sha256

            $TUrlArchARM64 = $asset.releases.arm64.url
            $TSha256ArchARM64 = $asset.releases.arm64.sha256

            $TMajor = $version.Major
            $TImageVersion = $version

            $TImageTags = $asset.tags.$distribution
            if ($TImageTags) {
                # https://stackoverflow.com/a/73073678
                $TImageTags = "'{0}'" -f ($TImageTags -join "', '")
            }

            # Render templates into the distribution folder
            Copy-TemplateItem "./src/Dockerfile.$distribution.template" "$distributionFolder/Dockerfile"
            Copy-Item './src/entrypoint.sh' $distributionFolder
            Copy-TemplateItem "./src/image.build.ps1.template" "$distributionFolder/image.build.ps1"
            Copy-Item './src/image.tests.ps1' $distributionFolder
        }
    }
}

# Synopsis: Build all docker images (can be filtered using command-line options).
task Build Prepare, {
    $taskName = "Build"

    $PSStyle.OutputRendering = 'PlainText'
    $logFolder = Join-Path $outputFolder 'logs'

    $builds = $assets | ForEach-Object {
        $asset = $_

        $version = [version]$asset.version
        $versionFolder = Join-Path $outputFolder $version

        $asset.tags | Get-Member -MemberType NoteProperty | ForEach-Object {
            $distribution = $_.Name
            $distributionFolder = Join-Path $versionFolder $distribution
            @{
                File = "$distributionFolder/image.build.ps1"
                Task = $taskName
                Log = "$logFolder/$taskName-$version-$distribution.log"

                # Parameters passed to Invoke-Build
                Verbose = $PSCmdlet.MyInvocation.BoundParameters["Verbose"].IsPresent
            }
        }
    }

    Build-Parallel $builds
}

# Synopsis: Run all tests (can be filtered using command-line options).
task Test FilteredAssets, {
    $taskName = "Test"

    $PSStyle.OutputRendering = 'PlainText'
    $logFolder = Join-Path $outputFolder 'logs'

    $tests = $assets | ForEach-Object {
        $asset = $_

        $version = [version]$asset.version
        $versionFolder = Join-Path $outputFolder $version

        $asset.tags | Get-Member -MemberType NoteProperty | ForEach-Object {
            $distribution = $_.Name
            $distributionFolder = Join-Path $versionFolder $distribution
            @{
                File = "$distributionFolder/image.build.ps1"
                Task = $taskName
                Log = "$logFolder/$taskName-$version-$distribution.log"

                # Parameters passed to Invoke-Build
                Verbose = $PSCmdlet.MyInvocation.BoundParameters["Verbose"].IsPresent
                TestFilter = $TestFilter
            }
        }
    }

    Build-Parallel $tests
}

# Synopsis: Publish all images.
task Publish {
    $PSStyle.OutputRendering = 'PlainText'
    $logFolder = Join-Path $outputFolder 'logs'
    $builds = Get-ChildItem "$outputFolder/**/image.build.ps1" -Recurse | ForEach-Object {
        $version = $_.Directory.Parent.Name
        $variant = $_.Directory.Name
        $taskName = "Publish"
        @{
            File = $_.FullName
            Task = $taskName
            Log = (Join-Path $logFolder "$taskName-$version-$variant.log")
        }
    }
    Build-Parallel $builds
}

# Synopsis: Default task.
task . Build
