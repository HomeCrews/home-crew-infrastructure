# HomeCrew, running locally, in watch mode. Windows.
#
#   .\dev.ps1 up [svc...]      start everything, or just these services and
#                              what they depend on, hot reloading
#   .\dev.ps1 down [flags...]  stop everything; the volumes are kept unless you
#                              pass -v (the Maven cache is kept even then)
#   .\dev.ps1 logs [args...]   follow logs
#
# A line-for-line mirror of ./dev, the POSIX sh version. Anything changed in one
# belongs in the other - the two are a pair, and a fix applied to only one of
# them is how a Windows developer ends up debugging a problem that was solved
# months ago on macOS. test/ runs both against the same scenarios.
#
# There is no non-watch mode. Every service runs from its sibling checkout at
# ..\home-crew-<service>, compiled inside its own container, so saving a .java
# file restarts that one service and nothing else. No image is rebuilt in the
# loop and no homecrew image is pulled from Docker Hub.
#
# Your machine needs Docker Desktop (with Compose 2.24.4 or later) and a .env.
# It does NOT need a JDK or Maven - the containers do the compiling. Works in
# Windows PowerShell 5.1 and in PowerShell 7.
#
# From cmd.exe rather than PowerShell:
#
#     powershell -ExecutionPolicy Bypass -File dev.ps1 up
#
# To wipe the databases, Kafka's log and the build caches, which this script
# will not do unless you ask:
#
#     .\dev.ps1 down -v

# No param() block, on purpose. [Parameter()] makes this an ADVANCED script,
# and an advanced script binds PowerShell's common parameters by prefix:
# `.\dev.ps1 down -v` handed -v to -Verbose, so compose never saw it and the
# volumes silently survived; -d became -Debug and -p swallowed the next word.
# A plain script receives every word in $args, untouched. (PowerShell itself
# still swallows a bare `--`; there is nothing to be done about that.)

$ErrorActionPreference = 'Stop'

# Stop applies to CMDLETS only - unless a profile or policy has turned on
# $PSNativeCommandUseErrorActionPreference (PowerShell 7.3+), which makes a
# non-zero exit from a NATIVE command throw as well, and would turn every
# $LASTEXITCODE check below into a raw exception. Guarded with Test-Path
# because the variable does not exist before 7.3.
if (Test-Path 'variable:PSNativeCommandUseErrorActionPreference') {
    $PSNativeCommandUseErrorActionPreference = $false
}

$argv = @($args)
$Command = 'help'
$Rest = @()
if ($argv.Count -gt 0) { $Command = [string]$argv[0] }
if ($argv.Count -gt 1) { $Rest = @($argv[1..($argv.Count - 1)] | ForEach-Object { [string]$_ }) }

$Root     = $PSScriptRoot
$Siblings = Split-Path -Parent $PSScriptRoot

# Relative, and only ever used from inside $Root - the same as ./dev.
$ComposeFiles = @('-f', 'docker-compose.yml', '-f', 'compose.dev.yml')

$MavenVolume = 'homecrew-maven-repo'
$ComposeMin  = @(2, 24, 4)

$Services = @(
    'service-discovery', 'config-server', 'api-gateway', 'auth-service',
    'user-service', 'admin-service', 'booking-service', 'worker-service',
    'notification-service', 'payment-service', 'xp-service',
    'assignment-service', 'webapp'
)

# Resolved once, as the application on PATH: a docker alias or function in a
# profile cannot stand in for it.
$script:Docker = $null

function Die {
    param([string[]] $Lines)
    foreach ($l in $Lines) { [Console]::Error.WriteLine($l) }
    exit 1
}

function Warn {
    param([string[]] $Lines)
    foreach ($l in $Lines) { [Console]::Error.WriteLine("WARNING: $l") }
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

# Every docker call runs under a LOCAL $ErrorActionPreference = 'Continue'.
#
# Windows PowerShell 5.1 turns every line a native command writes to a
# REDIRECTED stderr into an error record, and with 'Stop' the first one throws.
# So `docker info *> $null` raised a raw exception instead of the "daemon is
# not responding" message below - and so did a perfectly healthy docker that
# printed a plugin warning to stderr. It is not only this script's own
# redirections that count: run as `.\dev.ps1 up 2>&1 | Tee-Object up.log`, or in
# the ISE, compose's progress lines on stderr are redirected by the CALLER, and
# would throw just the same. $LASTEXITCODE survives the finally block.

# Runs docker with its output going straight to the console; the caller reads
# $LASTEXITCODE.
function Invoke-Docker {
    param([string[]] $DockerArgs)
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $script:Docker @DockerArgs }
    finally { $ErrorActionPreference = $saved }
}

# Runs docker with ALL of its output discarded and returns its exit code.
function Test-Docker {
    param([string[]] $DockerArgs)
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $script:Docker @DockerArgs *> $null }
    finally { $ErrorActionPreference = $saved }
    return $LASTEXITCODE
}

# Runs docker and returns its stdout as one string, stderr discarded.
function Get-DockerOutput {
    param([string[]] $DockerArgs)
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = & $script:Docker @DockerArgs 2> $null }
    finally { $ErrorActionPreference = $saved }
    if ($LASTEXITCODE -ne 0) { return '' }
    return (@($out) -join "`n").Trim()
}

function Test-HasCR {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    # Absolute path on purpose: .NET's current directory is not PowerShell's.
    return ([System.IO.File]::ReadAllBytes($Path) -contains 13)
}

# docker compose reads .env for variable SUBSTITUTION, and POSTGRES_PASSWORD is
# ${VAR:?} in docker-compose.yml, so without .env every command here fails with
# a compose error rather than something actionable. Say it once, properly.
function Require-Env {
    $envFile = Join-Path $Root '.env'
    if (-not (Test-Path -LiteralPath $envFile -PathType Leaf)) {
        Die @(
            "$envFile is missing.",
            '',
            '    Copy-Item .env.example .env',
            '',
            'Then fill in CONFIG_GIT_USERNAME and CONFIG_GIT_TOKEN: home-crew-config',
            'is private, and config-server cannot clone it without a token. The',
            'POSTGRES_* defaults in .env.example are fine as they are.'
        )
    }

    # A .env written by Windows PowerShell 5.1 (`>`, Out-File) is UTF-16, which
    # compose reads as garbage with no useful error. It shows up as NUL bytes.
    if ([System.IO.File]::ReadAllBytes($envFile) -contains 0) {
        Die @(
            "$envFile is not plain text - it looks UTF-16, which is what Windows",
            'PowerShell 5.1 writes with > or Out-File. Save it again as UTF-8, or:',
            '',
            '    Get-Content .env | Set-Content -Encoding ascii .env.new; Move-Item -Force .env.new .env'
        )
    }

    # The environment beats .env, so a SPRING_PROFILES_ACTIVE left in your
    # shell or your Windows user variables silently replaces `container`.
    if (-not [string]::IsNullOrEmpty($env:SPRING_PROFILES_ACTIVE)) {
        Warn @(
            "SPRING_PROFILES_ACTIVE=$($env:SPRING_PROFILES_ACTIVE) is set in your environment and overrides",
            "the stack's default profile (container). Unset it unless you mean it."
        )
    }
}

function Require-Docker {
    $cmd = Get-Command docker -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cmd) {
        Die @('docker is not on PATH. Install Docker Desktop for Windows.')
    }
    $script:Docker = $cmd.Source
    if ((Test-Docker @('info')) -ne 0) {
        Die @('docker is installed but the daemon is not responding. Start Docker Desktop and retry.')
    }
}

# compose.dev.yml uses !override and !reset, which Compose understands from
# 2.24.4. Older versions reject the file with a YAML error that mentions
# neither versions nor tags. Docker Desktop reports versions like
# 2.39.1-desktop.1, sometimes with a leading v: only the three leading numbers
# count. (A [version] cast would throw on exactly those strings.)
function Test-ComposeVersion {
    param([string] $Version)
    if ($Version -notmatch '^v?(\d+)\.(\d+)\.(\d+)') { return $false }
    $have = @([int64]$Matches[1], [int64]$Matches[2], [int64]$Matches[3])
    for ($i = 0; $i -lt 3; $i++) {
        if ($have[$i] -gt $ComposeMin[$i]) { return $true }
        if ($have[$i] -lt $ComposeMin[$i]) { return $false }
    }
    return $true
}

function Require-Compose {
    $v = Get-DockerOutput @('compose', 'version', '--short')
    if (-not (Test-ComposeVersion $v)) {
        $shown = if ($v) { $v } else { 'unknown' }
        Die @(
            "Docker Compose $($ComposeMin -join '.') or later is required; this is '$shown'.",
            'compose.dev.yml uses !override and !reset, which older versions reject.',
            'Update Docker Desktop, or the docker-compose-plugin package.'
        )
    }
}

# A script checked out with Windows line endings breaks INSIDE the Linux
# containers - `set -eu\r` - so twelve containers would crash-loop on it. Git
# normally prevents it (.gitattributes forces LF), but a clone made before
# that rule, or an editor that rewrites line endings, still produces one.
function Require-Lf {
    $bad = @()
    foreach ($f in @((Join-Path $Root 'dev-reload.sh'), (Join-Path $Root 'webapp-dev.sh'))) {
        if (Test-HasCR $f) { $bad += "    $f" }
    }
    foreach ($svc in $Services) {
        $f = Join-Path (Join-Path $Siblings "home-crew-$svc") 'mvnw'
        if (Test-HasCR $f) { $bad += "    $f" }
    }
    if ($bad.Count -gt 0) {
        Die (@('These files have Windows (CRLF) line endings, and the containers cannot run them:', '') +
             $bad +
             @('', 'Check each out again - git writes LF for them:', '',
               '    Remove-Item <file>; git -C <its repository> checkout -- <file>'))
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
        if (-not (Test-Path -LiteralPath (Join-Path $dir 'pom.xml')) -and
            -not (Test-Path -LiteralPath (Join-Path $dir 'package.json'))) {
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
            "    cd '$Siblings'"
        )
        foreach ($m in $missing) {
            $lines += "    git clone git@github.com:HomeCrews/$m.git"
        }
        Die $lines
    }
}

# From inside $Root, so the relative -f paths resolve; the caller reads
# $LASTEXITCODE.
function Invoke-Compose {
    param([string[]] $ComposeArgs)
    Push-Location -LiteralPath $Root
    try { Invoke-Docker (@('compose') + $ComposeFiles + $ComposeArgs) }
    finally { Pop-Location }
}

function Preflight {
    Require-Env
    Require-Docker
    Require-Compose
}

function Command-Up {
    Preflight
    Require-Siblings
    Require-Lf

    # Validated before anything starts, so a typo in either file is one clear
    # compose error here rather than twelve containers half-created.
    Invoke-Compose @('config', '--quiet')
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    # compose.dev.yml declares the Maven cache external, so that `down -v`
    # cannot take it - which also means compose will not create it. This does,
    # and does nothing if it already exists.
    Invoke-Docker @('volume', 'create', $MavenVolume) | Out-Null
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    if ($Rest.Count -gt 0) {
        Info "starting $($Rest -join ' ') and what it depends on, in watch mode"
    }
    else {
        Info 'starting every service in watch mode'
    }

    # --build so the shared dev runtime image exists. It is one FROM and an
    # apt-get, so rebuilding it is cheap and always doing it means a change to
    # Dockerfile.dev cannot be silently ignored.
    #
    # --wait with no --wait-timeout: the healthchecks already bound it, and a
    # shorter timeout leaves every dependent Created and never started.
    Invoke-Compose (@('up', '-d', '--build', '--wait') + $Rest)
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    Write-Output @'

The containers are up. The Java services are still compiling and starting
behind them: on the FIRST start each one resolves its dependencies into the
shared Maven cache and compiles from cold, which takes minutes. Watch it with

    .\dev.ps1 logs

A service is serving once its log shows "[dev-reload] app-ready". After that,
save a .java file: the log shows "[dev-reload] source-changed", then
"trigger-touched", and DevTools restarts the context. A pom.xml change shows
"build-changed" and starts a new JVM. No image is rebuilt and no other service
is touched.

    webapp           http://127.0.0.1:4200
    gateway          http://127.0.0.1:8080
    eureka           http://127.0.0.1:8761
    config-server    http://127.0.0.1:8888/actuator/health

Everything listens on 127.0.0.1 only. Attach a debugger to 127.0.0.1:

    service-discovery 5005    config-server 5006    api-gateway 5007
    auth-service      5008    user-service  5009    admin-service 5010
    booking-service   5011    worker-service 5012   notification-service 5013
    payment-service   5014    xp-service    5015    assignment-service 5016
'@
}

function Command-Down {
    Preflight
    # -ccontains: case-sensitive, like the sh case pattern in ./dev - compose
    # itself has no -V for down.
    if (($Rest -ccontains '-v') -or ($Rest -ccontains '--volumes')) {
        Info 'stopping everything and emptying the volumes (the Maven cache is kept)'
    }
    else {
        Info 'stopping everything, keeping the volumes'
    }
    Invoke-Compose (@('down') + $Rest)
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

function Command-Logs {
    Preflight
    Invoke-Compose (@('logs', '-f', '--tail', '100') + $Rest)
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

function Command-Help {
    # Print the header comment and stop at the first line that is not one, so
    # this cannot drift out of step with the block above.
    foreach ($line in Get-Content -LiteralPath $PSCommandPath) {
        if ($line -notmatch '^#') { break }
        Write-Output ($line -replace '^# ?', '')
    }
}

# Case-sensitive, like ./dev: `.\dev.ps1 UP` is as unknown as `./dev UP`.
switch -CaseSensitive ($Command) {
    'up'      { Command-Up }
    'down'    { Command-Down }
    'logs'    { Command-Logs }
    'help'    { Command-Help }
    '-h'      { Command-Help }
    '--help'  { Command-Help }
    default   { Die @("unknown command '$Command'; try .\dev.ps1 help") }
}
