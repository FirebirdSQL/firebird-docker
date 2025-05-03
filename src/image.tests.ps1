#
# Functions
#

# Run commands in a container and return.
function Invoke-Container([string[]]$DockerParameters, [string[]]$ImageParameters) {
    $allParameters = @('run', '--tmpfs', '/var/lib/firebird/data', '--rm'; $DockerParameters; $env:FULL_IMAGE_NAME)
    if ($ImageParameters) {
        # Do not append a $null as last parameter if $ImageParameters is empty
        $allParameters += $ImageParameters
    }

    Write-Verbose 'Running container... Command line is'
    Write-Verbose "  docker $allParameters"
    docker $allParameters
}

# Run commands in a detached container.
function Use-Container([string[]]$Parameters, [Parameter(Mandatory)][ScriptBlock]$ScriptBlock) {
    $allParameters = @('run'; $Parameters; '--tmpfs', '/var/lib/firebird/data', '--detach', $env:FULL_IMAGE_NAME)

    Write-Verbose 'Starting container... Command line is'
    Write-Verbose "  docker $allParameters"
    $cId = docker $allParameters
    try {
        Write-Verbose "  container id = $cId"
        Start-Sleep -Seconds 0.5
        Wait-Port -ContainerName $cId -Port 3050

        # Last check before execute
        docker top $cId > $null 2>&1
        if ($?) {
            # Container is running. Execute script block.
            Invoke-Command $ScriptBlock -ArgumentList $cId
        }
        else {
            # Container is not running/exited. Display log.
            Write-Warning 'Container is not running. Output log is:'
            docker logs $cId
        }
    }
    finally {
        Write-Verbose "    Removing container..."
        docker stop --time 5 $cId > $null
        docker rm --force $cId > $null
    }
}

# Wait for a port to be open in a container.
function Wait-Port([string]$ContainerName, [int]$Port) {
    while (-not (Test-Port -ContainerName $cId -Port 3050)) {
        Start-Sleep -Seconds 0.2
    }
}

# Test if a port is open in a container.
function Test-Port([string]$ContainerName, [int]$Port) {
    $command = "cat < /dev/null > /dev/tcp/localhost/$Port"
    docker exec $ContainerName bash -c $command -ErrorAction SilentlyContinue *>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
}

# Asserts that InputValue contains at least one occurence of Pattern.
#   If -ReturnMatchPosition is informed, return the match value for that pattern position.
function Contains([Parameter(ValueFromPipeline)]$InputValue, [string[]]$Pattern, [int]$ReturnMatchPosition) {
    process {
        if ($hasMatch) { return; }
        $_matches = $InputValue | Select-String -Pattern $Pattern
        $hasMatch = $null -ne $_matches

        if ($hasMatch -and ($null -ne $ReturnMatchPosition)) {
            $result = $_matches.Matches.Groups[$ReturnMatchPosition].Value
        }
    }

    end {
        assert $hasMatch
        return $result
    }
}

# Asserts that InputValue contains exactly ExpectedCount occurences of Pattern.
function ContainsExactly([Parameter(ValueFromPipeline)]$InputValue, [string[]]$Pattern, [int]$ExpectedCount) {
    process {
        $_matches = $InputValue | Select-String -Pattern $Pattern
        $totalMatches += $_matches.Count
    }

    end {
        assert ($totalMatches -eq $ExpectedCount)
    }
}

# Asserts that LastExitCode is equal to ExpectedValue.
function ExitCodeIs ([Parameter(ValueFromPipeline)]$InputValue, [int]$ExpectedValue) {
    process { }
    end {
        assert ($LastExitCode -eq $ExpectedValue)
    }
}

# Asserts that the difference between two DateTime values are under a given tolerance.
function IsAdjacent ([Parameter(ValueFromPipeline)][datetime]$InputValue, [datetime]$ExpectedValue, [timespan]$Tolerance=[timespan]::FromSeconds(2)) {
    process { }
    end {
        $difference = $InputValue - $ExpectedValue
        assert ($difference.Duration() -lt $Tolerance)
    }
}

# Creates a temporary directory -- https://stackoverflow.com/a/34559554
function New-TemporaryDirectory {
    $parent = [System.IO.Path]::GetTempPath()
    [string]$name = [System.Guid]::NewGuid()
    New-Item -ItemType Directory -Path (Join-Path $parent $name) -Force
}


#
# Tests
#

task With_command_should_not_start_Firebird {
    Invoke-Container -ImageParameters 'ps', '-A' |
        ContainsExactly -Pattern 'firebird|fbguard' -ExpectedCount 0
}

task Without_command_should_start_Firebird {
    Use-Container -ScriptBlock {
        param($cId)

        # Both firebird and fbguard must be running
        docker exec $cId ps -A |
            ContainsExactly -Pattern 'firebird|fbguard' -ExpectedCount 2

        # "Starting" but no "Stopping"
        docker logs $cId |
            ContainsExactly -Pattern 'Starting Firebird|Stopping Firebird' -ExpectedCount 1

        # Stop
        docker stop $cId > $null

        # "Starting" and "Stopping"
        docker logs $cId |
            ContainsExactly -Pattern 'Starting Firebird|Stopping Firebird' -ExpectedCount 2
    }
}

task FIREBIRD_DATABASE_can_create_database {
    Use-Container -Parameters '-e', 'FIREBIRD_DATABASE=test.fdb' {
        param($cId)

        docker exec $cId test -f /var/lib/firebird/data/test.fdb |
            ExitCodeIs -ExpectedValue 0

        docker logs $cId |
            Contains -Pattern "Creating database '/var/lib/firebird/data/test.fdb'"
    }
}

task FIREBIRD_DATABASE_can_create_database_with_absolute_path {
    Use-Container -Parameters '-e', 'FIREBIRD_DATABASE=/tmp/test.fdb' {
        param($cId)

        docker exec $cId test -f /tmp/test.fdb |
            ExitCodeIs -ExpectedValue 0

        docker logs $cId |
            Contains -Pattern "Creating database '/tmp/test.fdb'"
    }
}

task FIREBIRD_DATABASE_PAGE_SIZE_can_set_page_size_on_database_creation {
    Use-Container -Parameters '-e', 'FIREBIRD_DATABASE=test.fdb', '-e', 'FIREBIRD_DATABASE_PAGE_SIZE=4096' {
        param($cId)

        'SET LIST ON; SELECT mon$page_size FROM mon$database;' |
            docker exec -i $cId isql -b -q /var/lib/firebird/data/test.fdb |
                Contains -Pattern 'MON\$PAGE_SIZE(\s+)4096'
    }

    Use-Container -Parameters '-e', 'FIREBIRD_DATABASE=test.fdb', '-e', 'FIREBIRD_DATABASE_PAGE_SIZE=16384' {
        param($cId)

        'SET LIST ON; SELECT mon$page_size FROM mon$database;' |
            docker exec -i $cId isql -b -q /var/lib/firebird/data/test.fdb |
                Contains -Pattern 'MON\$PAGE_SIZE(\s+)16384'
    }
}

task FIREBIRD_DATABASE_DEFAULT_CHARSET_can_set_default_charset_on_database_creation {
    Use-Container -Parameters '-e', 'FIREBIRD_DATABASE=test.fdb' {
        param($cId)

        'SET LIST ON; SELECT rdb$character_set_name FROM rdb$database;' |
            docker exec -i $cId isql -b -q /var/lib/firebird/data/test.fdb |
                Contains -Pattern 'RDB\$CHARACTER_SET_NAME(\s+)NONE'
    }

    Use-Container -Parameters '-e', 'FIREBIRD_DATABASE=test.fdb', '-e', 'FIREBIRD_DATABASE_DEFAULT_CHARSET=UTF8' {
        param($cId)

        'SET LIST ON; SELECT rdb$character_set_name FROM rdb$database;' |
            docker exec -i $cId isql -b -q /var/lib/firebird/data/test.fdb |
                Contains -Pattern 'RDB\$CHARACTER_SET_NAME(\s+)UTF8'
    }
}

task FIREBIRD_USER_fails_without_password {
    # Captures both stdout and stderr
    $($stdout = Invoke-Container -DockerParameters '-e', 'FIREBIRD_USER=alice') 2>&1 |
        Contains -Pattern 'FIREBIRD_PASSWORD variable is not set.'    # stderr

    assert ($stdout -eq $null)
}

task FIREBIRD_USER_can_create_user {
    Use-Container -Parameters '-e', 'FIREBIRD_DATABASE=test.fdb', '-e', 'FIREBIRD_USER=alice', '-e', 'FIREBIRD_PASSWORD=bird' {
        param($cId)

        # Use 'SET BAIL ON' (-b) for isql to return exit codes.
        # Use 'inet://' protocol to not connect directly to database (skipping authentication)

        # Correct password
        'SELECT 1 FROM rdb$database;' |
            docker exec -i $cId isql -b -q -u alice -p bird inet:///var/lib/firebird/data/test.fdb |
                ExitCodeIs -ExpectedValue 0

        # Incorrect password
        'SELECT 1 FROM rdb$database;' |
            docker exec -i $cId isql -b -q -u alice -p tiger inet:///var/lib/firebird/data/test.fdb 2>&1 |
                ExitCodeIs -ExpectedValue 1

        # File /opt/firebird/SYSDBA.password exists?
        docker exec $cId test -f /opt/firebird/SYSDBA.password |
            ExitCodeIs -ExpectedValue 0

        docker logs $cId |
            Contains -Pattern "Creating user 'alice'"
    }
}

task FIREBIRD_ROOT_PASSWORD_can_change_sysdba_password {
    Use-Container -Parameters '-e', 'FIREBIRD_DATABASE=test.fdb', '-e', 'FIREBIRD_ROOT_PASSWORD=passw0rd' {
        param($cId)

        # Correct password
        'SELECT 1 FROM rdb$database;' |
            docker exec -i $cId isql -b -q -u SYSDBA -p passw0rd inet:///var/lib/firebird/data/test.fdb |
                ExitCodeIs -ExpectedValue 0

        # Incorrect password
        'SELECT 1 FROM rdb$database;' |
            docker exec -i $cId isql -b -q -u SYSDBA -p tiger inet:///var/lib/firebird/data/test.fdb 2>&1 |
                ExitCodeIs -ExpectedValue 1

        # File /opt/firebird/SYSDBA.password removed?
        docker exec $cId test -f /opt/firebird/SYSDBA.password |
            ExitCodeIs -ExpectedValue 1

        docker logs $cId |
            Contains -Pattern 'Changing SYSDBA password'
    }
}

task FIREBIRD_USE_LEGACY_AUTH_enables_legacy_auth {
    Use-Container -Parameters '-e', 'FIREBIRD_USE_LEGACY_AUTH=true' {
        param($cId)

        $logs = docker logs $cId
        $logs | Contains -Pattern "Using Legacy_Auth"
        $logs | Contains -Pattern "AuthServer = Legacy_Auth"
        $logs | Contains -Pattern "AuthClient = Legacy_Auth"
        $logs | Contains -Pattern "WireCrypt = Enabled"
    }
}

task FIREBIRD_CONF_can_change_any_setting {
    Use-Container -Parameters '-e', 'FIREBIRD_CONF_DefaultDbCachePages=64K', '-e', 'FIREBIRD_CONF_DefaultDbCachePages=64K', '-e', 'FIREBIRD_CONF_FileSystemCacheThreshold=100M' {
        param($cId)

        $logs = docker logs $cId
        $logs | Contains -Pattern "DefaultDbCachePages = 64K"
        $logs | Contains -Pattern "FileSystemCacheThreshold = 100M"
    }
}

task FIREBIRD_CONF_key_is_case_sensitive {
    Use-Container -Parameters '-e', 'FIREBIRD_CONF_WireCrypt=Disabled' {
        param($cId)

        $logs = docker logs $cId
        $logs | Contains -Pattern "WireCrypt = Disabled"
    }

    Use-Container -Parameters '-e', 'FIREBIRD_CONF_WIRECRYPT=Disabled' {
        param($cId)

        $logs = docker logs $cId
        $logs | ContainsExactly -Pattern "WireCrypt = Disabled" -ExpectedCount 0
    }
}

task Can_init_db_with_scripts {
    $initDbFolder = New-TemporaryDirectory
    try {
        @'
        CREATE DOMAIN countryname   AS VARCHAR(60);

        CREATE TABLE country
        (
            country         COUNTRYNAME NOT NULL PRIMARY KEY,
            currency        VARCHAR(30) NOT NULL
        );
'@ | Out-File "$initDbFolder/10-create-table.sql"

        @'
        INSERT INTO country (country, currency) VALUES ('USA',         'Dollar');
        INSERT INTO country (country, currency) VALUES ('England',     'Pound');
        INSERT INTO country (country, currency) VALUES ('Canada',      'CdnDlr');
        INSERT INTO country (country, currency) VALUES ('Switzerland', 'SFranc');
        INSERT INTO country (country, currency) VALUES ('Japan',       'Yen');
'@ | Out-File "$initDbFolder/20-insert-data.sql"

        Use-Container -Parameters '-e', 'FIREBIRD_DATABASE=test.fdb', '-v', "$($initDbFolder):/docker-entrypoint-initdb.d/" {
            param($cId)

            $logs = docker logs $cId
            $logs | Contains -Pattern "10-create-table.sql"
            $logs | Contains -Pattern "20-insert-data.sql"

            'SET LIST ON; SELECT count(*) AS country_count FROM country;' |
            docker exec -i $cId isql -b -q /var/lib/firebird/data/test.fdb |
                Contains -Pattern 'COUNTRY_COUNT(\s+)5'
        }
    }
    finally {
        Remove-Item $initDbFolder -Force -Recurse
    }
}

task TZ_can_change_system_timezone {
    Use-Container -Parameters '-e', 'FIREBIRD_DATABASE=test.fdb' {
        param($cId)

        $expected = [DateTime]::Now.ToUniversalTime()

        $actual = 'SET LIST ON; SELECT localtimestamp FROM mon$database;' |
            docker exec -i $cId isql -b -q /var/lib/firebird/data/test.fdb |
                Contains -Pattern 'LOCALTIMESTAMP(\s+)(.*)' -ReturnMatchPosition 2
        $actual = [DateTime]$actual

        $actual | IsAdjacent -ExpectedValue $expected
    }

    Use-Container -Parameters '-e', 'FIREBIRD_DATABASE=test.fdb', '-e', 'TZ=America/Los_Angeles' {
        param($cId)

        $tz = Get-TimeZone -id 'America/Los_Angeles'

        $expected = [DateTime]::Now
        # Convert [DateTime] to given time zone
        $expected = [System.TimeZoneInfo]::ConvertTimeBySystemTimeZoneId($expected, $tz.Id)

        $actual = 'SET LIST ON; SELECT localtimestamp FROM mon$database;' |
            docker exec -i $cId isql -b -q /var/lib/firebird/data/test.fdb |
                Contains -Pattern 'LOCALTIMESTAMP(\s+)(.*)' -ReturnMatchPosition 2
        $actual = [DateTime]$actual

        # Creates a [DateTimeOffset] using given time zone -- https://stackoverflow.com/a/59885215
        $utcOffset = $tz.GetUtcOffset($actual)
        $actual = [DateTimeOffset]::new($actual, $utcOffset)
        $actual = $actual.DateTime    # Back to [DateTime]

        $actual | IsAdjacent -ExpectedValue $expected
    }
}
