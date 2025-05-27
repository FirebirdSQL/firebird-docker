#
# Functions
#

# Run commands in a container and return.
function Invoke-Container([string[]]$DockerParameters, [string[]]$ImageParameters) {
    assert $env:FULL_IMAGE_NAME "'FULL_IMAGE_NAME' environment variable must be set to the image name to test."
    
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
    assert $env:FULL_IMAGE_NAME "'FULL_IMAGE_NAME' environment variable must be set to the image name to test."

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
function Contains([Parameter(ValueFromPipeline)]$InputValue, [string[]]$Pattern, [int]$ReturnMatchPosition, [string]$ErrorMessage) {
    process {
        if ($hasMatch) { return; }
        $_matches = $InputValue | Select-String -Pattern $Pattern
        $hasMatch = $null -ne $_matches

        if ($hasMatch -and ($null -ne $ReturnMatchPosition)) {
            $result = $_matches.Matches.Groups[$ReturnMatchPosition].Value
        }
    }

    end {
        if ([string]::IsNullOrEmpty($ErrorMessage)) {
            $ErrorMessage = "InputValue does not contain the specified Pattern."
        }
        assert $hasMatch $ErrorMessage
        return $result
    }
}

# Asserts that InputValue contains exactly ExpectedCount occurences of Pattern.
function ContainsExactly([Parameter(ValueFromPipeline)]$InputValue, [string[]]$Pattern, [int]$ExpectedCount, [string]$ErrorMessage) {
    process {
        $_matches = $InputValue | Select-String -Pattern $Pattern
        $totalMatches += $_matches.Count
    }

    end {
        if ([string]::IsNullOrEmpty($ErrorMessage)) {
            $ErrorMessage = "InputValue does not contain exactly $ExpectedCount occurrences of Pattern."
        }
        assert ($totalMatches -eq $ExpectedCount) $ErrorMessage
    }
}

# Asserts that LastExitCode is equal to ExpectedValue.
function ExitCodeIs ([Parameter(ValueFromPipeline)]$Unused, [int]$ExpectedValue, [string]$ErrorMessage) {
    process { }
    end {
        # Actual value from pipeline is discarded. Just check for $LastExitCode.
        if ([string]::IsNullOrEmpty($ErrorMessage)) {
            $ErrorMessage = "ExitCode = $LastExitCode, expected = $ExpectedValue."
        }
        assert ($LastExitCode -eq $ExpectedValue) $ErrorMessage
    }
}

# Asserts that the difference between two DateTime values are under a given tolerance.
function IsAdjacent ([Parameter(ValueFromPipeline)][datetime]$InputValue, [datetime]$ExpectedValue, [timespan]$Tolerance=[timespan]::FromSeconds(1), [string]$ErrorMessage) {
    process { }
    end {
        $difference = $InputValue - $ExpectedValue
        if ([string]::IsNullOrEmpty($ErrorMessage)) {
            $ErrorMessage = "The difference between $InputValue and $ExpectedValue is larger than the expected tolerance ($Tolerance)."
        }
        assert ($difference.Duration() -lt $Tolerance) $ErrorMessage
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
        ContainsExactly -Pattern 'firebird|fbguard' -ExpectedCount 0 -ErrorMessage "Firebird processes should not be running when a command is specified."
}

task Without_command_should_start_Firebird {
    Use-Container -ScriptBlock {
        param($cId)

        # Both firebird and fbguard must be running
        docker exec $cId ps -A |
            ContainsExactly -Pattern 'firebird|fbguard' -ExpectedCount 2 -ErrorMessage "Expected 'firebird' and 'fbguard' processes to be running."

        # "Starting" but no "Stopping"
        docker logs $cId |
            ContainsExactly -Pattern 'Starting Firebird|Stopping Firebird' -ExpectedCount 1 -ErrorMessage "Expected 'Starting Firebird' log entry."

        # Stop
        docker stop $cId > $null

        # "Starting" and "Stopping"
        docker logs $cId |
            ContainsExactly -Pattern 'Starting Firebird|Stopping Firebird' -ExpectedCount 2 -ErrorMessage "Expected both 'Starting Firebird' and 'Stopping Firebird' log entries after container stop."
    }
}

task FIREBIRD_DATABASE_can_create_database {
    Use-Container -Parameters '-e', 'FIREBIRD_DATABASE=test.fdb' {
        param($cId)

        docker exec $cId test -f /var/lib/firebird/data/test.fdb |
            ExitCodeIs -ExpectedValue 0 -ErrorMessage "Expected database file '/var/lib/firebird/data/test.fdb' to exist."

        docker logs $cId |
            Contains -Pattern "Creating database '/var/lib/firebird/data/test.fdb'" -ErrorMessage "Expected log message indicating creation of database '/var/lib/firebird/data/test.fdb'."
    }
}

task FIREBIRD_DATABASE_can_create_database_with_absolute_path {
    $absolutePathDatabase = '/tmp/test.fdb'
    Use-Container -Parameters '-e', "FIREBIRD_DATABASE=$absolutePathDatabase" {
        param($cId)

        docker exec $cId test -f $absolutePathDatabase |
            ExitCodeIs -ExpectedValue 0 -ErrorMessage "Expected database file '$absolutePathDatabase' to exist when absolute path is used."

        docker logs $cId |
            Contains -Pattern "Creating database '$absolutePathDatabase'" -ErrorMessage "Expected log message indicating creation of database '$absolutePathDatabase' when absolute path is used."
    }
}

task FIREBIRD_DATABASE_can_create_database_with_spaces_in_path {
    $absolutePathDatabase = '/tmp/test database.fdb'
    Use-Container -Parameters '-e', "FIREBIRD_DATABASE=$absolutePathDatabase" {
        param($cId)

        docker exec $cId test -f $absolutePathDatabase |
            ExitCodeIs -ExpectedValue 0 -ErrorMessage "Expected database file '$absolutePathDatabase' to exist when spaces in path are used."

        docker logs $cId |
            Contains -Pattern "Creating database '$absolutePathDatabase'" -ErrorMessage "Expected log message indicating creation of database '$absolutePathDatabase' when spaces in path are used."
    }
}

task FIREBIRD_DATABASE_can_create_database_with_unicode_characters {
    $absolutePathDatabase = '/tmp/próf-áêïôù-🗄️.fdb'
    Use-Container -Parameters '-e', "FIREBIRD_DATABASE=$absolutePathDatabase" {
        param($cId)

        docker exec $cId test -f $absolutePathDatabase |
            ExitCodeIs -ExpectedValue 0 -ErrorMessage "Expected database file '$absolutePathDatabase' to exist when unicode characters are used."

        docker logs $cId |
            Contains -Pattern "Creating database '$absolutePathDatabase'" -ErrorMessage "Expected log message indicating creation of database '$absolutePathDatabase' when unicode characters are used."
    }
}

task FIREBIRD_DATABASE_PAGE_SIZE_can_set_page_size_on_database_creation {
    Use-Container -Parameters '-e', 'FIREBIRD_DATABASE=test.fdb', '-e', 'FIREBIRD_DATABASE_PAGE_SIZE=4096' {
        param($cId)

        'SET LIST ON; SELECT mon$page_size FROM mon$database;' |
            docker exec -i $cId isql -b -q /var/lib/firebird/data/test.fdb |
                Contains -Pattern 'MON\$PAGE_SIZE(\s+)4096' -ErrorMessage "Expected database page size to be 4096."
    }

    Use-Container -Parameters '-e', 'FIREBIRD_DATABASE=test.fdb', '-e', 'FIREBIRD_DATABASE_PAGE_SIZE=16384' {
        param($cId)

        'SET LIST ON; SELECT mon$page_size FROM mon$database;' |
            docker exec -i $cId isql -b -q /var/lib/firebird/data/test.fdb |
                Contains -Pattern 'MON\$PAGE_SIZE(\s+)16384' -ErrorMessage "Expected database page size to be 16384."
    }
}

task FIREBIRD_DATABASE_DEFAULT_CHARSET_can_set_default_charset_on_database_creation {
    Use-Container -Parameters '-e', 'FIREBIRD_DATABASE=test.fdb' {
        param($cId)

        'SET LIST ON; SELECT rdb$character_set_name FROM rdb$database;' |
            docker exec -i $cId isql -b -q /var/lib/firebird/data/test.fdb |
                Contains -Pattern 'RDB\$CHARACTER_SET_NAME(\s+)NONE' -ErrorMessage "Expected default database charset to be NONE."
    }

    Use-Container -Parameters '-e', 'FIREBIRD_DATABASE=test.fdb', '-e', 'FIREBIRD_DATABASE_DEFAULT_CHARSET=UTF8' {
        param($cId)

        'SET LIST ON; SELECT rdb$character_set_name FROM rdb$database;' |
            docker exec -i $cId isql -b -q /var/lib/firebird/data/test.fdb |
                Contains -Pattern 'RDB\$CHARACTER_SET_NAME(\s+)UTF8' -ErrorMessage "Expected default database charset to be UTF8."
    }
}

task FIREBIRD_USER_fails_without_password {
    # Captures both stdout and stderr
    $($stdout = Invoke-Container -DockerParameters '-e', 'FIREBIRD_USER=alice') 2>&1 |
        Contains -Pattern 'FIREBIRD_PASSWORD variable is not set.' -ErrorMessage "Expected error message 'FIREBIRD_PASSWORD variable is not set.' when FIREBIRD_USER is set without FIREBIRD_PASSWORD."    # stderr

    assert ($stdout -eq $null) "Expected stdout to be null when FIREBIRD_USER is set without FIREBIRD_PASSWORD."
}

task FIREBIRD_USER_can_create_user {
    Use-Container -Parameters '-e', 'FIREBIRD_DATABASE=test.fdb', '-e', 'FIREBIRD_USER=alice', '-e', 'FIREBIRD_PASSWORD=bird' {
        param($cId)

        # Use 'SET BAIL ON' (-b) for isql to return exit codes.
        # Use 'inet://' protocol to not connect directly to database (skipping authentication)

        # Correct password
        'SELECT 1 FROM rdb$database;' |
            docker exec -i $cId isql -b -q -u alice -p bird inet:///var/lib/firebird/data/test.fdb |
                ExitCodeIs -ExpectedValue 0 -ErrorMessage "Expected successful login with correct password for user 'alice'."

        # Incorrect password
        'SELECT 1 FROM rdb$database;' |
            docker exec -i $cId isql -b -q -u alice -p tiger inet:///var/lib/firebird/data/test.fdb 2>&1 |
                ExitCodeIs -ExpectedValue 1 -ErrorMessage "Expected failed login with incorrect password for user 'alice'."

        # File /opt/firebird/SYSDBA.password exists?
        docker exec $cId test -f /opt/firebird/SYSDBA.password |
            ExitCodeIs -ExpectedValue 0 -ErrorMessage "Expected SYSDBA.password file to exist when a new user is created."

        docker logs $cId |
            Contains -Pattern "Creating user 'alice'" -ErrorMessage "Expected log message indicating creation of user 'alice'."
    }
}

task FIREBIRD_ROOT_PASSWORD_can_change_sysdba_password {
    Use-Container -Parameters '-e', 'FIREBIRD_DATABASE=test.fdb', '-e', 'FIREBIRD_ROOT_PASSWORD=passw0rd' {
        param($cId)

        # Correct password
        'SELECT 1 FROM rdb$database;' |
            docker exec -i $cId isql -b -q -u SYSDBA -p passw0rd inet:///var/lib/firebird/data/test.fdb |
                ExitCodeIs -ExpectedValue 0 -ErrorMessage "Expected successful login with new SYSDBA password."

        # Incorrect password
        'SELECT 1 FROM rdb$database;' |
            docker exec -i $cId isql -b -q -u SYSDBA -p tiger inet:///var/lib/firebird/data/test.fdb 2>&1 |
                ExitCodeIs -ExpectedValue 1 -ErrorMessage "Expected failed login with incorrect (old) SYSDBA password."

        # File /opt/firebird/SYSDBA.password removed?
        docker exec $cId test -f /opt/firebird/SYSDBA.password |
            ExitCodeIs -ExpectedValue 1 -ErrorMessage "Expected SYSDBA.password file to be removed after changing SYSDBA password."

        docker logs $cId |
            Contains -Pattern 'Changing SYSDBA password' -ErrorMessage "Expected log message indicating SYSDBA password change."
    }
}

task FIREBIRD_USE_LEGACY_AUTH_enables_legacy_auth {
    Use-Container -Parameters '-e', 'FIREBIRD_USE_LEGACY_AUTH=true' {
        param($cId)

        $logs = docker logs $cId
        $logs | Contains -Pattern "Using Legacy_Auth" -ErrorMessage "Expected log message 'Using Legacy_Auth'."
        $logs | Contains -Pattern "AuthServer = Legacy_Auth" -ErrorMessage "Expected log message 'AuthServer = Legacy_Auth'."
        $logs | Contains -Pattern "AuthClient = Legacy_Auth" -ErrorMessage "Expected log message 'AuthClient = Legacy_Auth'."
        $logs | Contains -Pattern "WireCrypt = Enabled" -ErrorMessage "Expected log message 'WireCrypt = Enabled' when Legacy_Auth is used."
    }
}

task FIREBIRD_CONF_can_change_any_setting {
    Use-Container -Parameters '-e', 'FIREBIRD_CONF_DefaultDbCachePages=64K', '-e', 'FIREBIRD_CONF_DefaultDbCachePages=64K', '-e', 'FIREBIRD_CONF_FileSystemCacheThreshold=100M' {
        param($cId)

        $logs = docker logs $cId
        $logs | Contains -Pattern "DefaultDbCachePages = 64K" -ErrorMessage "Expected log message 'DefaultDbCachePages = 64K'."
        $logs | Contains -Pattern "FileSystemCacheThreshold = 100M" -ErrorMessage "Expected log message 'FileSystemCacheThreshold = 100M'."
    }
}

task FIREBIRD_CONF_key_is_case_sensitive {
    Use-Container -Parameters '-e', 'FIREBIRD_CONF_WireCrypt=Disabled' {
        param($cId)

        $logs = docker logs $cId
        $logs | Contains -Pattern "WireCrypt = Disabled" -ErrorMessage "Expected log message 'WireCrypt = Disabled' when using correct case."
    }

    Use-Container -Parameters '-e', 'FIREBIRD_CONF_WIRECRYPT=Disabled' {
        param($cId)

        $logs = docker logs $cId
        $logs | ContainsExactly -Pattern "WireCrypt = Disabled" -ExpectedCount 0 -ErrorMessage "Expected no log message 'WireCrypt = Disabled' when using incorrect case (WIRECRYPT)."
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
            $logs | Contains -Pattern "10-create-table.sql" -ErrorMessage "Expected log message for '10-create-table.sql' execution."
            $logs | Contains -Pattern "20-insert-data.sql" -ErrorMessage "Expected log message for '20-insert-data.sql' execution."

            'SET LIST ON; SELECT count(*) AS country_count FROM country;' |
            docker exec -i $cId isql -b -q /var/lib/firebird/data/test.fdb |
                Contains -Pattern 'COUNTRY_COUNT(\s+)5' -ErrorMessage "Expected country count to be 5 after init scripts."
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
