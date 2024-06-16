#
# Globals
#

$outputFolder = './generated'



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
    # Add header
    @'
#
# This file was generated. Do not edit. See /src.
#

'@ | Set-Content $Destination -Encoding UTF8

    # Expand template
    Get-Content $Path -Raw -Encoding UTF8 |
        Expand-Template |
            Add-Content $Destination -Encoding UTF8

    # Set readonly flag (another reminder to not edit the file)
    $outputFile = Get-Item $Destination
    $outputFile.Attributes += 'ReadOnly'
}



#
# Tasks
#

# Synopsis: Invoke preprocessor to generate images sources.
task Prepare {
    # Clear output folder
    Remove-Item -Path $outputFolder -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory $outputFolder -Force > $null

    # For each asset
    $assets = Get-Content -Raw -Path '.\assets.json' | ConvertFrom-Json
    $assets | ForEach-Object {
        $asset = $_

        # https://regexr.com/7vo8e
        if ($asset.tag -notmatch 'v(?<Major>\d+)\.(?<Minor>\d+).(?<Patch>\d+)') {
            throw "Invalid tag: $($asset.tag)"
        }

        $major = $Matches.Major
        $majorFolder = Join-Path $outputFolder $major
        New-Item -ItemType Directory $majorFolder -Force > $null

        # For each platform
        $asset.platforms | Get-Member -MemberType NoteProperty | ForEach-Object {
            $platform = $_.Name
            $platformData = $asset.platforms.$platform

            # For each image
            $asset.images | ForEach-Object {
                $image = $_

                $TUrl = $platformData.url
                $TSha256 = $platformData.sha256
                $TVersion = $asset.tag.TrimStart('v')
                $TMajor = $major
                $TImagePlatform = $platform
                $TImageVersion = "$major-$image"

                $TImageTags = $asset.imageTags.$image
                if ($TImageTags) {
                    # https://stackoverflow.com/a/73073678
                    $TImageTags = "'{0}'" -f ($TImageTags -join "', '")
                }            

                $platformFolder = Join-Path $majorFolder $platform
                $imageFolder = Join-Path $platformFolder $image
                New-Item -ItemType Directory $imageFolder -Force > $null

                Copy-TemplateItem "./src/Dockerfile.$image.template" "$imageFolder/Dockerfile"
                Copy-Item './src/entrypoint.sh' $imageFolder
                Copy-TemplateItem "./src/image.build.ps1.template" "$imageFolder/image.build.ps1"
                Copy-Item './src/image.tests.ps1' $imageFolder
            }
        }
    }
}

# Synopsis: Build all docker images.
task Build Prepare, {
    $builds = Get-ChildItem "$outputFolder/**/image.build.ps1" -Recurse | ForEach-Object {
        @{File = $_; Task = 'Build' }
    }    
    Build-Parallel $builds
}

# Synopsis: Run all tests.
task Test {
    $builds = Get-ChildItem "$outputFolder/**/image.build.ps1" -Recurse | ForEach-Object {
        @{File = $_; Task = 'Test' }
    }    
    Build-Parallel $builds
}

# Synopsis: Publish all images.
task Publish {
    $builds = Get-ChildItem "$outputFolder/**/image.build.ps1" -Recurse | ForEach-Object {
        @{File = $_; Task = 'Publish' }
    }    
    Build-Parallel $builds
}

# Synopsis: Default task.
task . Build
