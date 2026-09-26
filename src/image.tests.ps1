#
# Functions
#

# Data directory for test containers. Same ownership and mode as in the image layer (firebird:0, 0775).
$dataTmpfs = '/var/lib/firebird/data:uid=84,gid=0,mode=0775'

# Run commands in a container and return.
function Invoke-Container([string[]]$DockerParameters, [string[]]$ImageParameters) {
    assert $env:FULL_IMAGE_NAME "'FULL_IMAGE_NAME' environment variable must be set to the image name to test."
    
    $allParameters = @('run', '--tmpfs', $dataTmpfs, '--rm'; $DockerParameters; $env:FULL_IMAGE_NAME)
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

    $allParameters = @('run'; $Parameters; '--tmpfs', $dataTmpfs, '--detach', $env:FULL_IMAGE_NAME)

    Write-Verbose 'Starting container... Command line is'
    Write-Verbose "  docker $allParameters"
    $cId = docker $allParameters
    try {
        Write-Verbose "  container id = $cId"
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
function Wait-Port([string]$ContainerName, [int]$Port, [int]$TimeoutSeconds = 60) {
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Port -ContainerName $ContainerName -Port $Port)) {
        if ($stopwatch.Elapsed.TotalSeconds -gt $TimeoutSeconds) {
            Write-Warning "Port $Port not open in container after $TimeoutSeconds seconds. Output log is:"
            docker logs $ContainerName
            throw "Timeout waiting for port $Port in container '$ContainerName'."
        }
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
function IsAdjacent ([Parameter(ValueFromPipeline)][datetime]$InputValue, [datetime]$ExpectedValue, [timespan]$Tolerance=[timespan]::FromSeconds(3), [string]$ErrorMessage) {
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
    Use-Container -Parameters '-e', 'FIREBIRD_DATABASE=test.fdb', '-e', 'FIREBIRD_DATABASE_PAGE_SIZE=8192' {
        param($cId)

        'SET LIST ON; SELECT mon$page_size FROM mon$database;' |
            docker exec -i $cId isql -b -q /var/lib/firebird/data/test.fdb |
                Contains -Pattern 'MON\$PAGE_SIZE(\s+)8192' -ErrorMessage "Expected database page size to be 8192."
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
    # DefaultDbCachePages and TempCacheLimit exist in all supported Firebird versions (3, 4, 5, 6).
    # FileSystemCacheThreshold was removed in Firebird 6 so we intentionally avoid it.
    Use-Container -Parameters '-e', 'FIREBIRD_CONF_DefaultDbCachePages=64K', '-e', 'FIREBIRD_CONF_TempCacheLimit=100M' {
        param($cId)

        $logs = docker logs $cId
        $logs | Contains -Pattern "DefaultDbCachePages = 64K" -ErrorMessage "Expected log message 'DefaultDbCachePages = 64K'."
        $logs | Contains -Pattern "TempCacheLimit = 100M" -ErrorMessage "Expected log message 'TempCacheLimit = 100M'."
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

task FIREBIRD_ROOT_PASSWORD_with_special_characters {
    # Test SQL injection resistance: passwords with single quotes, semicolons, etc.
    Use-Container -Parameters '-e', 'FIREBIRD_DATABASE=test.fdb', '-e', "FIREBIRD_ROOT_PASSWORD=it's;a--test" {
        param($cId)

        # Correct password
        'SELECT 1 FROM rdb$database;' |
            docker exec -i $cId isql -b -q -u SYSDBA -p "it's;a--test" inet:///var/lib/firebird/data/test.fdb |
                ExitCodeIs -ExpectedValue 0 -ErrorMessage "Expected successful login with special character SYSDBA password."

        docker logs $cId |
            Contains -Pattern 'Changing SYSDBA password' -ErrorMessage "Expected log message for SYSDBA password change with special characters."
    }
}

task FIREBIRD_USER_PASSWORD_with_special_characters {
    # Test that user passwords with quotes work (SQL injection vector)
    Use-Container -Parameters '-e', 'FIREBIRD_DATABASE=test.fdb', '-e', "FIREBIRD_USER=alice", '-e', "FIREBIRD_PASSWORD=p@ss'word" {
        param($cId)

        'SELECT 1 FROM rdb$database;' |
            docker exec -i $cId isql -b -q -u alice -p "p@ss'word" inet:///var/lib/firebird/data/test.fdb |
                ExitCodeIs -ExpectedValue 0 -ErrorMessage "Expected successful login with special character user password."

        docker logs $cId |
            Contains -Pattern "Creating user 'alice'" -ErrorMessage "Expected log message indicating creation of user 'alice' with special password."
    }
}

task FIREBIRD_USER_with_dot_creates_delimited_user {
    # Issue #44: usernames that are not regular SQL identifiers (e.g. containing dots)
    # must be created as delimited (double-quoted) identifiers.
    $initDbFolder = New-TemporaryDirectory
    try {
        @'
        CREATE TABLE init_check (id INTEGER NOT NULL PRIMARY KEY);
'@ | Out-File "$initDbFolder/10-init.sql"

        Use-Container -Parameters '-e', 'FIREBIRD_DATABASE=test.fdb', '-e', 'FIREBIRD_USER=dba.backend', '-e', 'FIREBIRD_PASSWORD=bird', '-v', "$($initDbFolder):/docker-entrypoint-initdb.d/" {
            param($cId)

            # Login as the delimited user: the name must be passed quoted.
            #   (pwsh >= 7.3 passes the embedded double quotes verbatim to native commands)
            'SELECT 1 FROM rdb$database;' |
                docker exec -i $cId isql -b -q -u '"dba.backend"' -p bird inet:///var/lib/firebird/data/test.fdb |
                    ExitCodeIs -ExpectedValue 0 -ErrorMessage "Expected successful login as delimited user ""dba.backend""."

            # Init script must have been executed (process_sql logs in as the delimited user)
            'SELECT 1 FROM init_check;' |
                docker exec -i $cId isql -b -q /var/lib/firebird/data/test.fdb |
                    ExitCodeIs -ExpectedValue 0 -ErrorMessage "Expected init script to have created table 'init_check'."

            docker logs $cId |
                Contains -Pattern "Creating user 'dba\.backend'" -ErrorMessage "Expected log message indicating creation of user 'dba.backend'."
        }
    }
    finally {
        Remove-Item $initDbFolder -Force -Recurse
    }
}

task FIREBIRD_USER_already_quoted_is_used_verbatim {
    # Backward compatibility with the pre-existing workaround for issue #44: FIREBIRD_USER='"name.with.dots"'
    # The user is created verbatim (case-sensitive), so the login name must be passed quoted.
    #   (pwsh >= 7.3 passes the embedded double quotes verbatim to native commands)
    Use-Container -Parameters '-e', 'FIREBIRD_DATABASE=test.fdb', '-e', 'FIREBIRD_USER="dba.backend"', '-e', 'FIREBIRD_PASSWORD=bird' {
        param($cId)

        'SELECT 1 FROM rdb$database;' |
            docker exec -i $cId isql -b -q -u '"dba.backend"' -p bird inet:///var/lib/firebird/data/test.fdb |
                ExitCodeIs -ExpectedValue 0 -ErrorMessage "Expected pre-quoted FIREBIRD_USER to keep working."
    }
}

task Graceful_shutdown_via_SIGTERM {
    Use-Container -ScriptBlock {
        param($cId)

        # Send SIGTERM (same as docker stop)
        docker kill --signal SIGTERM $cId > $null
        Start-Sleep -Seconds 3

        # Container should have exited cleanly
        $state = docker inspect --format '{{.State.Status}}' $cId 2>$null
        if ($state -eq 'running') {
            # Give it a bit more time
            Start-Sleep -Seconds 3
        }

        $logs = docker logs $cId
        $logs | Contains -Pattern 'Stopping Firebird' -ErrorMessage "Expected 'Stopping Firebird' log on SIGTERM."
    }
}

task Tini_is_PID_1 {
    Use-Container -ScriptBlock {
        param($cId)

        $pid1 = docker exec $cId cat /proc/1/comm
        assert ($pid1.Trim() -eq 'tini') "Expected PID 1 to be 'tini', got '$($pid1.Trim())'."
    }
}

task FIREBIRD_ROOT_PASSWORD_FILE_can_set_password_from_file {
    $secretDir = New-TemporaryDirectory
    try {
        'secretpass123' | Out-File "$secretDir/password.txt" -NoNewline

        Use-Container -Parameters '-e', 'FIREBIRD_DATABASE=test.fdb', '-e', 'FIREBIRD_ROOT_PASSWORD_FILE=/run/secrets/password.txt', '-v', "$($secretDir):/run/secrets/" {
            param($cId)

            # Correct password from file
            'SELECT 1 FROM rdb$database;' |
                docker exec -i $cId isql -b -q -u SYSDBA -p secretpass123 inet:///var/lib/firebird/data/test.fdb |
                    ExitCodeIs -ExpectedValue 0 -ErrorMessage "Expected successful login with password loaded from _FILE."

            docker logs $cId |
                Contains -Pattern 'Changing SYSDBA password' -ErrorMessage "Expected SYSDBA password change log when using _FILE."
        }
    }
    finally {
        Remove-Item $secretDir -Force -Recurse
    }
}

task FIREBIRD_PASSWORD_FILE_can_set_user_password_from_file {
    $secretDir = New-TemporaryDirectory
    try {
        'userpass456' | Out-File "$secretDir/user_password.txt" -NoNewline

        Use-Container -Parameters '-e', 'FIREBIRD_DATABASE=test.fdb', '-e', 'FIREBIRD_USER=bob', '-e', 'FIREBIRD_PASSWORD_FILE=/run/secrets/user_password.txt', '-v', "$($secretDir):/run/secrets/" {
            param($cId)

            'SELECT 1 FROM rdb$database;' |
                docker exec -i $cId isql -b -q -u bob -p userpass456 inet:///var/lib/firebird/data/test.fdb |
                    ExitCodeIs -ExpectedValue 0 -ErrorMessage "Expected successful login with user password loaded from _FILE."

            docker logs $cId |
                Contains -Pattern "Creating user 'bob'" -ErrorMessage "Expected log for user creation with _FILE password."
        }
    }
    finally {
        Remove-Item $secretDir -Force -Recurse
    }
}

task FILE_and_env_var_are_mutually_exclusive {
    $secretDir = New-TemporaryDirectory
    try {
        'filepass' | Out-File "$secretDir/password.txt" -NoNewline

        # Setting both FIREBIRD_ROOT_PASSWORD and FIREBIRD_ROOT_PASSWORD_FILE should fail
        $($stdout = Invoke-Container -DockerParameters '-e', 'FIREBIRD_ROOT_PASSWORD=envpass', '-e', 'FIREBIRD_ROOT_PASSWORD_FILE=/run/secrets/password.txt', '-v', "$($secretDir):/run/secrets/") 2>&1 |
            Contains -Pattern 'Both FIREBIRD_ROOT_PASSWORD and FIREBIRD_ROOT_PASSWORD_FILE are set' -ErrorMessage "Expected error when both _FILE and env var are set."
    }
    finally {
        Remove-Item $secretDir -Force -Recurse
    }
}

task Tag_correctness_via_docker_inspect {
    # Verify the image has the correct version label
    $labels = docker inspect --format '{{json .Config.Labels}}' $env:FULL_IMAGE_NAME | ConvertFrom-Json
    $version = $labels.'org.opencontainers.image.version'
    assert ($null -ne $version) "Expected 'org.opencontainers.image.version' label to be set."
    # Accept either a semver release (e.g. '5.0.3') or a snapshot tag (e.g. '5-snapshot', '6-snapshot')
    assert ($version -match '^\d+\.\d+\.\d+$' -or $version -match '^\d+-snapshot$') "Expected version label '$version' to be semver or snapshot format."
}

#
# Non-root support -- https://github.com/FirebirdSQL/firebird-docker/issues/46
#

task Runtime_paths_are_owned_by_firebird_and_group_root {
    # Runs 'stat' directly (not via Invoke-Container) to see the data directory as shipped in the image layer, not a tmpfs.
    $paths = '/opt/firebird', '/opt/firebird/firebird.conf', '/opt/firebird/firebird.log', '/opt/firebird/fb_guard', '/tmp/firebird', '/var/lib/firebird/data'
    $stats = docker run --rm --entrypoint stat $env:FULL_IMAGE_NAME -c '%U %g %A %n' @paths
    assert ($LastExitCode -eq 0) "Expected 'stat' to succeed on all runtime paths."

    $stats | ForEach-Object {
        $owner, $gid, $mode, $path = $_ -split ' '
        assert ($owner -eq 'firebird') "Expected '$path' to be owned by 'firebird', got '$owner'."
        assert ($gid -eq '0') "Expected '$path' to have group 0 (root), got '$gid'."
        assert ($mode.Substring(1, 3) -eq $mode.Substring(4, 3)) "Expected '$path' to have group permissions equal to owner permissions, got '$mode'."
    }

    # Binaries must stay owned by root.
    docker run --rm --entrypoint stat $env:FULL_IMAGE_NAME -c '%U' /opt/firebird/bin/firebird |
        Contains -Pattern '^root$' -ErrorMessage "Expected Firebird binaries to stay owned by root."
}

# Runs the whole initialization path (config, SYSDBA password, user, database, init scripts) as the given user.
function Test-NonRootInitialization([Parameter(Mandatory)][string]$User) {
    $initDbFolder = New-TemporaryDirectory
    try {
        @'
        CREATE TABLE init_check (id INTEGER NOT NULL PRIMARY KEY);
'@ | Out-File "$initDbFolder/10-init.sql"

        Use-Container -Parameters '--user', $User, '-e', 'FIREBIRD_CONF_WireCrypt=Enabled', '-e', 'FIREBIRD_ROOT_PASSWORD=passw0rd', '-e', 'FIREBIRD_USER=alice', '-e', 'FIREBIRD_PASSWORD=bird', '-e', 'FIREBIRD_DATABASE=test.fdb', '-v', "$($initDbFolder):/docker-entrypoint-initdb.d/" {
            param($cId)

            $expectedUid = ($User -split ':')[0]
            $serverUid = docker exec $cId ps -o uid= -C firebird
            assert ($serverUid.Trim() -eq $expectedUid) "Expected Firebird server to run as UID $expectedUid, got '$serverUid'."

            $logs = docker logs $cId 2>&1
            $logs | Contains -Pattern 'WireCrypt = Enabled' -ErrorMessage "Expected FIREBIRD_CONF_WireCrypt to be applied when running as '$User'."
            $logs | ContainsExactly -Pattern 'WARNING' -ExpectedCount 0 -ErrorMessage "Expected no permission warning when running as '$User'."

            'SELECT 1 FROM rdb$database;' |
                docker exec -i $cId isql -b -q -u SYSDBA -p passw0rd inet:///var/lib/firebird/data/test.fdb |
                    ExitCodeIs -ExpectedValue 0 -ErrorMessage "Expected successful login with new SYSDBA password when running as '$User'."

            docker exec $cId test -f /opt/firebird/SYSDBA.password |
                ExitCodeIs -ExpectedValue 1 -ErrorMessage "Expected SYSDBA.password file to be removed when running as '$User'."

            # Init script must have been executed as 'alice'
            'SET LIST ON; SELECT rdb$owner_name AS table_owner FROM rdb$relations WHERE rdb$relation_name = ''INIT_CHECK'';' |
                docker exec -i $cId isql -b -q -u alice -p bird inet:///var/lib/firebird/data/test.fdb |
                    Contains -Pattern 'TABLE_OWNER(\s+)ALICE' -ErrorMessage "Expected init script to create table 'init_check' owned by 'alice' when running as '$User'."
        }
    }
    finally {
        Remove-Item $initDbFolder -Force -Recurse
    }
}

task Can_run_as_firebird_user {
    Test-NonRootInitialization -User '84:84'
}

task Can_run_as_arbitrary_uid_with_group_root {
    # OpenShift restricted SCC: random UID, no /etc/passwd entry, GID 0.
    Test-NonRootInitialization -User '12345:0'
}

task Without_FIREBIRD_USER_database_is_owned_by_SYSDBA_for_any_user {
    # Local connections would otherwise take the OS user name (e.g. 'FIREBIRD' for UID 84), not SYSDBA.
    $initDbFolder = New-TemporaryDirectory
    try {
        @'
        CREATE TABLE init_check (id INTEGER NOT NULL PRIMARY KEY);
'@ | Out-File "$initDbFolder/10-init.sql"

        foreach ($user in '0:0', '84:84', '12345:0') {
            Use-Container -Parameters '--user', $user, '-e', 'FIREBIRD_DATABASE=test.fdb', '-v', "$($initDbFolder):/docker-entrypoint-initdb.d/" {
                param($cId)

                'SET LIST ON; SELECT rdb$owner_name AS table_owner FROM rdb$relations WHERE rdb$relation_name = ''INIT_CHECK'';' |
                    docker exec -i $cId isql -b -q -u SYSDBA /var/lib/firebird/data/test.fdb |
                        Contains -Pattern 'TABLE_OWNER(\s+)SYSDBA' -ErrorMessage "Expected init script to create table 'init_check' owned by SYSDBA when running as '$user'."
            }
        }
    }
    finally {
        Remove-Item $initDbFolder -Force -Recurse
    }
}

task Unsupported_user_shows_permission_warning {
    # A UID which is neither 'firebird' nor in group 0 cannot write runtime files.
    $($stdout = Invoke-Container -DockerParameters '--user', '1000:1000', '-e', 'FIREBIRD_CONF_WireCrypt=Enabled') 2>&1 |
        Contains -Pattern 'WARNING: Running as UID 1000 / GID 1000' -ErrorMessage "Expected permission warning when running as an unsupported user."
}
