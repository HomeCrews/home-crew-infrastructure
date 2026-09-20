# HomeCrew, running locally, in watch mode. Windows.
#
#   .\dev.ps1 up             start everything, hot reloading
#   .\dev.ps1 down           stop everything (the volumes are kept)
#   .\dev.ps1 logs [svc...]  follow logs
#
# A line-for-line mirror of ./dev, the POSIX sh version. Anything changed in one
# belongs in the other - the two are a pair, and a fix applied to only one of
# them is how a Windows developer ends up debugging a problem that was solved
# months ago on macOS.
#
# There is no non-watch mode. Every service runs from its sibling checkout at
# ..\home-crew-<service>, compiled inside its own container, so saving a .java
# file restarts that one service and nothing else. No image is rebuilt in the
# loop and nothing is pulled from Docker Hub.
#
# Your machine needs Docker Desktop and a .env. It does NOT need a JDK or Maven
# - the containers do the compiling.
#
# From cmd.exe rather than PowerShell:
#
#     powershell -ExecutionPolicy Bypass -File dev.ps1 up
#
# To wipe the databases and Kafka's log, which this script deliberately will not
# do for you:
#
#     docker compose down -v

param(
    [Parameter(Position = 0)]
    [string] $Command = 'help',

    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]] $Rest = @()
)

$ErrorActionPreference = 'Stop'

# Stop applies to CMDLETS only. PowerShell 7.3+ added
# $PSNativeCommandUseErrorActionPreference, defaulting to true, which makes a
# non-zero exit from a NATIVE command throw as well - and that would break every
# $LASTEXITCODE check below, turning a clean "docker is not responding" into a
# raw PowerShell exception. Guarded with Test-Path because the variable does not
# exist before 7.3.
if (Test-Path 'variable:PSNativeCommandUseErrorActionPreference') {
    $PSNativeCommandUseErrorActionPreference = $false
}

$Root     = $PSScriptRoot
$Siblings = Split-Path -Parent $PSScriptRoot

$ComposeFiles = @(
    '-f', (Join-Path $Root 'docker-compose.yml'),
    '-f', (Join-Path $Root 'compose.dev.yml')
)

$Services = @(
    'service-discovery', 'config-server', 'api-gateway', 'auth-service',
    'user-service', 'admin-service', 'booking-service', 'worker-service',
    'notification-service', 'payment-service', 'xp-service',
    'assignment-service', 'webapp'
)

function Die {
    param([string[]] $Lines)
    foreach ($l in $Lines) { [Console]::Error.WriteLine($l) }
    exit 1
}

function Info {
    param([string] $Message)
    # Colour only when stdout is a terminal, so `.\dev.ps1 logs > file` and CI
    # capture do not collect escape sequences.
    if (-not [Console]::IsOutputRedirected) {
        Write-Host '==> ' -ForegroundColor Cyan -NoNewline
        Write-Host $Message
    }
    else {
        Write-Output "==> $Message"
    }
}

# docker compose reads .env for variable SUBSTITUTION, and POSTGRES_PASSWORD is
# ${VAR:?} in docker-compose.yml, so without .env every command here fails with
# a compose error rather than something actionable. Say it once, properly.
function Require-Env {
    if (-not (Test-Path (Join-Path $Root '.env'))) {
        Die @(
            "$Root\.env is missing.",
            '',
            '    Copy-Item .env.example .env',
            '',
            'Then fill in CONFIG_GIT_USERNAME and CONFIG_GIT_TOKEN: home-crew-config',
            'is private, and config-server cannot clone it without a token. The',
            'POSTGRES_* defaults in .env.example are fine as they are.'
        )
    }
}

function Require-Docker {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Die @('docker is not on PATH. Install Docker Desktop for Windows.')
    }
    docker info *> $null
    if ($LASTEXITCODE -ne 0) {
        Die @('docker is installed but the daemon is not responding. Start Docker Desktop and retry.')
    }
}

# compose.dev.yml mounts ${HOME}/.m2 into every service container. HOME is a
# POSIX variable and Windows does not set it - Docker Desktop would substitute
# an empty string and try to mount "/.m2", which fails or silently mounts the
# wrong thing. USERPROFILE is the Windows equivalent.
#
# This has no counterpart in ./dev because HOME is always set on macOS and
# Linux. It is the one place the two scripts legitimately differ.
function Require-Home {
    if ([string]::IsNullOrEmpty($env:HOME)) {
        if ([string]::IsNullOrEmpty($env:USERPROFILE)) {
            Die @(
                'Neither HOME nor USERPROFILE is set, so the Maven cache cannot be mounted.',
                'compose.dev.yml mounts ${HOME}/.m2 into every service container.'
            )
        }
        $env:HOME = $env:USERPROFILE
    }
}

# Every service is a bind mount of a sibling repository. A missing one would not
# fail loudly: Docker would happily create an empty directory and the container
# would die on a missing pom, twelve lines deep in a log. Check first.
function Require-Siblings {
    $missing = @()
    foreach ($svc in $Services) {
        $dir = Join-Path $Siblings "home-crew-$svc"
        # pom.xml for the twelve Java services, package.json for webapp -
        # checking only for the directory would pass on an empty clone.
        if (-not (Test-Path (Join-Path $dir 'pom.xml')) -and
            -not (Test-Path (Join-Path $dir 'package.json'))) {
            $missing += "home-crew-$svc"
        }
    }
    if ($missing.Count -gt 0) {
        $lines = @(
            "These checkouts are missing or incomplete: $($missing -join ' ')",
            '',
            'Every service is bind-mounted from a sibling directory, so they all have',
            'to be cloned next to this one:',
            '',
            "    cd $Siblings"
        )
        foreach ($m in $missing) {
            $lines += "    git clone git@github.com:HomeCrews/$m.git"
        }
        Die $lines
    }
}

function Invoke-Compose {
    param([string[]] $ComposeArgs)
    Require-Env
    Require-Docker
    Require-Home
    Push-Location $Root
    try {
        & docker compose @ComposeFiles @ComposeArgs
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }
    finally { Pop-Location }
}

function Command-Up {
    Require-Siblings
    Info 'starting every service in watch mode'

    # --build so the shared dev runtime image exists. It is one FROM and an
    # apt-get, so rebuilding it is cheap and always doing it means a change to
    # Dockerfile.dev cannot be silently ignored.
    Invoke-Compose @('up', '-d', '--build')

    Write-Output @'

Everything is up. The FIRST start is slow: each container resolves its
dependency tree and compiles from cold. Watch it happen with

    .\dev.ps1 logs

After that, save a .java file. The log for that service shows "change
detected, recompiling", then DevTools restarting the context. No image is
rebuilt and no other service is touched.

    webapp           http://localhost:4200
    gateway          http://localhost:8080
    eureka           http://localhost:8761
    config-server    http://localhost:8888/actuator/health
    served config    http://localhost:8888/userservice/container

Debuggers are on 5005 upwards, in the order the services are listed in
compose.dev.yml. Attached debuggers survive a DevTools restart.
'@
}

function Command-Down {
    Info 'stopping everything, keeping the volumes'
    Invoke-Compose @('down')
}

function Command-Logs {
    Invoke-Compose (@('logs', '-f', '--tail', '100') + $Rest)
}

function Command-Help {
    # Print the header comment and stop at the first line that is not one, so
    # this cannot drift out of step with the block above.
    foreach ($line in Get-Content -LiteralPath $PSCommandPath | Select-Object -Skip 1) {
        if ($line -notmatch '^#') { break }
        Write-Output ($line -replace '^# ?', '')
    }
}

switch ($Command) {
    'up'      { Command-Up }
    'down'    { Command-Down }
    'logs'    { Command-Logs }
    'help'    { Command-Help }
    '-h'      { Command-Help }
    '--help'  { Command-Help }
    default   { Die @("unknown command '$Command'; try .\dev.ps1 help") }
}
