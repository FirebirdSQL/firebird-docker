#
# Unit tests for the Get-ImageTags function in firebird-docker.build.ps1
#

BeforeAll {
    # Source the shared functions (contains Get-ImageTags)
    . $PSScriptRoot/functions.ps1
}

Describe 'Get-ImageTags' {

    Context 'Latest overall version on default distro (bookworm)' {
        It 'generates all tag types for 5.0.3-bookworm' {
            $tags = Get-ImageTags -Version '5.0.3' -Distro 'bookworm' `
                -IsLatestOfMajor $true -IsLatestOverall $true -DefaultDistro 'bookworm'

            $tags | Should -Contain '5.0.3-bookworm'   # version-distro
            $tags | Should -Contain '5-bookworm'       # major-distro
            $tags | Should -Contain 'bookworm'         # distro (latest overall)
            $tags | Should -Contain '5.0.3'            # version (default distro)
            $tags | Should -Contain '5'                # major (default distro)
            $tags | Should -Contain 'latest'           # latest (default distro)
            $tags | Should -HaveCount 6
        }
    }

    Context 'Latest overall version on non-default distro (noble)' {
        It 'generates distro-qualified tags for 5.0.3-noble' {
            $tags = Get-ImageTags -Version '5.0.3' -Distro 'noble' `
                -IsLatestOfMajor $true -IsLatestOverall $true -DefaultDistro 'bookworm'

            $tags | Should -Contain '5.0.3-noble'      # version-distro
            $tags | Should -Contain '5-noble'          # major-distro
            $tags | Should -Contain 'noble'            # distro (latest overall)
            $tags | Should -Not -Contain '5.0.3'       # no bare version
            $tags | Should -Not -Contain '5'           # no bare major
            $tags | Should -Not -Contain 'latest'      # no latest
            $tags | Should -HaveCount 3
        }
    }

    Context 'Latest of major but not latest overall' {
        It 'generates major tags for 4.0.6-bookworm' {
            $tags = Get-ImageTags -Version '4.0.6' -Distro 'bookworm' `
                -IsLatestOfMajor $true -IsLatestOverall $false -DefaultDistro 'bookworm'

            $tags | Should -Contain '4.0.6-bookworm'   # version-distro
            $tags | Should -Contain '4-bookworm'       # major-distro
            $tags | Should -Not -Contain 'bookworm'    # NOT latest overall
            $tags | Should -Contain '4.0.6'            # version (default distro)
            $tags | Should -Contain '4'                # major (default distro)
            $tags | Should -Not -Contain 'latest'      # NOT latest overall
            $tags | Should -HaveCount 4
        }
    }

    Context 'Older patch version (not latest of major)' {
        It 'generates minimal tags for 5.0.2-bookworm' {
            $tags = Get-ImageTags -Version '5.0.2' -Distro 'bookworm' `
                -IsLatestOfMajor $false -IsLatestOverall $false -DefaultDistro 'bookworm'

            $tags | Should -Contain '5.0.2-bookworm'   # version-distro
            $tags | Should -Contain '5.0.2'            # version (default distro)
            $tags | Should -Not -Contain '5-bookworm'  # NOT latest of major
            $tags | Should -Not -Contain '5'           # NOT latest of major
            $tags | Should -Not -Contain 'latest'      # NOT latest
            $tags | Should -HaveCount 2
        }
    }

    Context 'Older patch version on non-default distro' {
        It 'generates only version-distro for 4.0.5-jammy' {
            $tags = Get-ImageTags -Version '4.0.5' -Distro 'jammy' `
                -IsLatestOfMajor $false -IsLatestOverall $false -DefaultDistro 'bookworm'

            $tags | Should -Contain '4.0.5-jammy'      # version-distro
            $tags | Should -Not -Contain '4.0.5'       # not default distro
            $tags | Should -HaveCount 1
        }
    }

    Context 'Tag uniqueness' {
        It 'produces no duplicate tags' {
            $tags = Get-ImageTags -Version '5.0.3' -Distro 'bookworm' `
                -IsLatestOfMajor $true -IsLatestOverall $true -DefaultDistro 'bookworm'

            $tags | Should -HaveCount ($tags | Sort-Object -Unique | Measure-Object).Count
        }
    }
}
