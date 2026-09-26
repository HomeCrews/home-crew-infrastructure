#Requires -Version 7.2
# Shared plumbing for test/run.ps1: results, process execution, the safety
# guard, and the facts about the twelve services every suite needs.
#
# ASCII only, like dev.ps1. The harness needs PowerShell 7.2+ to RUN, but suite
# A still parses every .ps1 here with Windows PowerShell 5.1 to catch the
# encoding problems 5.1 has with non-ASCII files.
#
# CONVENTIONS FOR SUITE FILES (lib/Suite*.ps1)
#
#   * Each file defines exactly one entry point, Invoke-Suite<Name>, taking no
#     parameters, and records everything through Add-Result. Nothing is
#     printed as a verdict any other way.
#   * Every external command goes through Invoke-Native / Invoke-Docker /
#     Invoke-TestCompose / Invoke-LiveCompose, so that it is logged in
#     commands.log with its exit code and duration - that log is the "commands
#     executed" part of the report.
#   * Destructive docker operations are checked by Assert-DockerArgsSafe, which
#     Invoke-Docker calls for you. Never bypass it.
#   * Files in the sibling checkouts are only ever changed through the edit
#     manifest (Start-EditManifest / Set-TrackedFile / Remove-TrackedFile /
#     Restore-EditManifest), which restores byte-exactly and refuses to
#     overwrite anything it did not write itself.
#   * Evidence goes under Get-EvidenceDir <suite>; never into the checkouts.
#   * Statuses: PASS, FAIL, SKIP (could not run here - say why), BLOCKED (an
#     environment problem stopped it: memory, network, policy), WARN (passed
#     with a caveat), INFO (a finding, not a verdict), WEAK (a mutation check
#     showed the test would also pass without the fix).

Set-StrictMode -Version 3.0

$script:Hc = $null

# The twelve Java services, in compose.dev.yml order. Debug is the HOST port;
# every JVM listens on container port 5005. App is spring.application.name,
# which is what Eureka registers and the gateway routes to (lb://<App>).
$script:JavaServices = @(
    [pscustomobject]@{ Name = 'service-discovery';    Repo = 'home-crew-service-discovery';    App = 'servicediscovery';    Port = 8761; Debug = 5005; Main = 'com.homecrew.servicediscovery.ServicediscoveryApplication';       Jpa = $false; Kafka = $false; ConfigClient = $false; Volume = 'service_discovery_target' }
    [pscustomobject]@{ Name = 'config-server';        Repo = 'home-crew-config-server';        App = 'configserver';        Port = 8888; Debug = 5006; Main = 'com.homecrew.configserver.ConfigserverApplication';               Jpa = $false; Kafka = $false; ConfigClient = $false; Volume = 'config_server_target' }
    [pscustomobject]@{ Name = 'api-gateway';          Repo = 'home-crew-api-gateway';          App = 'apigateway';          Port = 8080; Debug = 5007; Main = 'com.homecrew.apigateway.ApigatewayApplication';                   Jpa = $false; Kafka = $false; ConfigClient = $true;  Volume = 'api_gateway_target' }
    [pscustomobject]@{ Name = 'auth-service';         Repo = 'home-crew-auth-service';         App = 'authservice';         Port = 8082; Debug = 5008; Main = 'com.homecrew.authservice.AuthserviceApplication';                 Jpa = $true;  Kafka = $false; ConfigClient = $true;  Volume = 'auth_service_target' }
    [pscustomobject]@{ Name = 'user-service';         Repo = 'home-crew-user-service';         App = 'userservice';         Port = 8081; Debug = 5009; Main = 'com.homecrew.userservice.UserserviceApplication';                 Jpa = $true;  Kafka = $false; ConfigClient = $true;  Volume = 'user_service_target' }
    [pscustomobject]@{ Name = 'admin-service';        Repo = 'home-crew-admin-service';        App = 'adminservice';        Port = 8083; Debug = 5010; Main = 'com.homecrew.adminservice.AdminserviceApplication';               Jpa = $true;  Kafka = $true;  ConfigClient = $true;  Volume = 'admin_service_target' }
    [pscustomobject]@{ Name = 'booking-service';      Repo = 'home-crew-booking-service';      App = 'bookingservice';      Port = 8084; Debug = 5011; Main = 'com.homecrew.bookingservice.BookingserviceApplication';           Jpa = $true;  Kafka = $true;  ConfigClient = $true;  Volume = 'booking_service_target' }
    [pscustomobject]@{ Name = 'worker-service';       Repo = 'home-crew-worker-service';       App = 'workerservice';       Port = 8085; Debug = 5012; Main = 'com.homecrew.workerservice.WorkerserviceApplication';             Jpa = $true;  Kafka = $true;  ConfigClient = $true;  Volume = 'worker_service_target' }
    [pscustomobject]@{ Name = 'notification-service'; Repo = 'home-crew-notification-service'; App = 'notificationservice'; Port = 8086; Debug = 5013; Main = 'com.homecrew.notificationservice.NotificationserviceApplication'; Jpa = $false; Kafka = $true;  ConfigClient = $true;  Volume = 'notification_service_target' }
    [pscustomobject]@{ Name = 'payment-service';      Repo = 'home-crew-payment-service';      App = 'paymentservice';      Port = 8087; Debug = 5014; Main = 'com.homecrew.paymentservice.PaymentserviceApplication';           Jpa = $true;  Kafka = $true;  ConfigClient = $true;  Volume = 'payment_service_target' }
    [pscustomobject]@{ Name = 'xp-service';           Repo = 'home-crew-xp-service';           App = 'xpservice';           Port = 8088; Debug = 5015; Main = 'com.homecrew.xpservice.XpserviceApplication';                     Jpa = $true;  Kafka = $true;  ConfigClient = $true;  Volume = 'xp_service_target' }
    [pscustomobject]@{ Name = 'assignment-service';   Repo = 'home-crew-assignment-service';   App = 'assignmentservice';   Port = 8089; Debug = 5016; Main = 'com.homecrew.assignmentservice.AssignmentserviceApplication';     Jpa = $false; Kafka = $true;  ConfigClient = $true;  Volume = 'assignment_service_target' }
)

# Everything the dev setup is allowed to change, relative to the infra repo.
# Anything else in `git diff --name-only <baseline>` is a scope violation.
$script:DevFiles = @(
    'compose.dev.yml', 'dev-reload.sh', 'Dockerfile.dev', 'dev', 'dev.ps1',
    'webapp-dev.sh', 'README.md', '.env.example', '.gitattributes', '.gitignore'
)
$script:ProdPaths = @('docker-compose.yml', '.github', 'postgres')

$script:DevImage       = 'homecrew-dev-runtime:jdk25'
$script:RealMavenVol   = 'homecrew-maven-repo'
$script:TestProject    = 'homecrew-test'
$script:TestMavenVol   = 'homecrew-maven-repo-test'
$script:TestNetwork    = 'homecrew-test'
$script:LiveContainerPrefix = 'homecrew-'

function Get-JavaServices { return $script:JavaServices }
function Get-JavaService { param([string] $Name) return ($script:JavaServices | Where-Object Name -EQ $Name | Select-Object -First 1) }

# ---------------------------------------------------------------------------
# Setup and results
# ---------------------------------------------------------------------------

function Initialize-Harness {
    param([Parameter(Mandatory)][string] $InfraRoot, [hashtable] $Options = @{})
    $infra = (Resolve-Path -LiteralPath $InfraRoot).Path
    $runId = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + ([Environment]::MachineName.ToLowerInvariant() -replace '[^a-z0-9-]', '')
    $results = Join-Path (Join-Path $infra 'test') (Join-Path 'results' $runId)
    New-Item -ItemType Directory -Force -Path $results | Out-Null
    $docker = Get-Command docker -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $script:Hc = [pscustomobject]@{
        InfraRoot    = $infra
        SiblingsRoot = Split-Path -Parent $infra
        TestRoot     = Join-Path $infra 'test'
        ResultsDir   = $results
        RunId        = $runId
        Options      = $Options
        Results      = [System.Collections.Generic.List[object]]::new()
        CommandsLog  = Join-Path $results 'commands.log'
        Docker       = if ($docker) { $docker.Source } else { $null }
        Git          = if ($git) { $git.Source } else { $null }
        BaselineRef  = $null
        Secrets      = [System.Collections.Generic.List[string]]::new()
        StartedAt    = Get-Date
        OnWindows    = $IsWindows
    }
    Set-Content -LiteralPath $script:Hc.CommandsLog -Value "# commands executed by test/run.ps1, run $runId" -Encoding utf8NoBOM
    $script:Hc.BaselineRef = if ($Options.ContainsKey('BaselineRef') -and $Options.BaselineRef) { $Options.BaselineRef } else { Get-BaselineRef 'home-crew-infrastructure' }
    return $script:Hc
}

function Get-Harness { if (-not $script:Hc) { throw 'Initialize-Harness has not run' }; return $script:Hc }

# Baseline commits of all fifteen repositories, committed in
# test/baseline-refs.tsv: the state before the dev-setup change, which the
# parity and mutation suites compare against.
function Get-BaselineRef {
    param([string] $Repo)
    $file = Join-Path (Get-Harness).TestRoot 'baseline-refs.tsv'
    foreach ($line in [System.IO.File]::ReadAllLines($file)) {
        if ($line -match '^\s*#' -or -not $line.Trim()) { continue }
        $cols = $line -split "`t"
        if ($cols[0] -eq $Repo) { return $cols[1] }
    }
    throw "no baseline for $Repo in $file"
}

function Add-Result {
    param(
        [Parameter(Mandatory)][string] $Id,
        [Parameter(Mandatory)][ValidateSet('PASS', 'FAIL', 'SKIP', 'BLOCKED', 'WARN', 'INFO', 'WEAK')][string] $Status,
        [Parameter(Mandatory)][string] $Message,
        [string[]] $Req = @(),
        [string[]] $Evidence = @(),
        [string] $Suite = $script:CurrentSuite
    )
    $r = [pscustomobject]@{
        Suite = $Suite; Id = $Id; Req = @($Req); Status = $Status; Message = (Protect-Text $Message)
        Evidence = @($Evidence | ForEach-Object { if ($_) { [System.IO.Path]::GetRelativePath((Get-Harness).ResultsDir, $_) } })
        At = (Get-Date).ToString('HH:mm:ss')
    }
    (Get-Harness).Results.Add($r)
    $colour = switch ($Status) { 'PASS' { 'Green' } 'FAIL' { 'Red' } 'WEAK' { 'Red' } 'BLOCKED' { 'Magenta' } 'WARN' { 'Yellow' } 'SKIP' { 'DarkGray' } default { 'Cyan' } }
    Write-Host ('  {0,-8} {1,-22} {2}' -f $Status, $Id, $Message) -ForegroundColor $colour
}

$script:CurrentSuite = ''
function Enter-Suite {
    param([string] $Name, [string] $Title)
    $script:CurrentSuite = $Name
    Write-Host ''
    Write-Host "== $Name - $Title" -ForegroundColor White
}

function Get-EvidenceDir {
    param([Parameter(Mandatory)][string] $Suite)
    $d = Join-Path (Get-Harness).ResultsDir $Suite
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    return $d
}

function Save-Evidence {
    param([Parameter(Mandatory)][string] $Suite, [Parameter(Mandatory)][string] $Name, [AllowEmptyString()][string] $Content)
    $p = Join-Path (Get-EvidenceDir $Suite) $Name
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $p) | Out-Null
    [System.IO.File]::WriteAllText($p, (Protect-Text $Content), [System.Text.UTF8Encoding]::new($false))
    return $p
}

# Container output (HCRESULT<TAB>id<TAB>status<TAB>message lines, written by
# test/container/lib.sh) becomes results.
function Import-HcResults {
    param([AllowEmptyString()][string] $Text, [string[]] $Req = @(), [string[]] $Evidence = @(), [string] $Prefix = '')
    $n = 0
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -notmatch "^HCRESULT`t") { continue }
        $c = $line -split "`t", 4
        if ($c.Count -lt 3 -or -not $c[1]) { continue }
        # A malformed line must not throw away the rest of the container's
        # results: an unknown status becomes a FAIL that says so, and an empty
        # message a placeholder.
        $status = $c[2].Trim().ToUpperInvariant()
        $msg = if ($c.Count -ge 4 -and $c[3].Trim()) { $c[3] } else { '(no message)' }
        if ($status -notin @('PASS', 'FAIL', 'SKIP', 'BLOCKED', 'WARN', 'INFO', 'WEAK')) {
            $msg = "unknown status '$($c[2])' from the container: $msg"
            $status = 'FAIL'
        }
        Add-Result -Id ($Prefix + $c[1]) -Status $status -Message $msg -Req $Req -Evidence $Evidence
        $n++
    }
    return $n
}

# ---------------------------------------------------------------------------
# Secrets: nothing from .env may end up in the results directory
# ---------------------------------------------------------------------------

# Values from .env worth protecting. The public defaults from .env.example
# (homecrew, localdev) and anything short are not secrets and would match
# everywhere, so they are left out.
function Register-EnvSecrets {
    $h = Get-Harness
    $envFile = Join-Path $h.InfraRoot '.env'
    $example = Join-Path $h.InfraRoot '.env.example'
    if (-not (Test-Path -LiteralPath $envFile)) { return }
    $defaults = @{}
    if (Test-Path -LiteralPath $example) {
        foreach ($l in [System.IO.File]::ReadAllLines($example)) { if ($l -match '^([A-Z0-9_]+)=(.*)$') { $defaults[$Matches[1]] = $Matches[2] } }
    }
    foreach ($l in [System.IO.File]::ReadAllLines($envFile)) {
        if ($l -notmatch '^([A-Z0-9_]+)=(.*)$') { continue }
        $k = $Matches[1]; $v = $Matches[2].Trim().Trim('"')
        if ($v.Length -lt 12) { continue }
        if ($defaults.ContainsKey($k) -and $defaults[$k] -eq $v) { continue }
        if (-not $h.Secrets.Contains($v)) { $h.Secrets.Add($v) }
    }
}

function Protect-Text {
    param([AllowEmptyString()][string] $Text)
    if (-not $Text -or -not $script:Hc) { return $Text }
    $i = 0
    foreach ($s in $script:Hc.Secrets) { $i++; $Text = $Text.Replace($s, "<redacted#$i>") }
    return $Text
}

function Test-ResultsForSecrets {
    $h = Get-Harness
    $hits = @()
    foreach ($f in Get-ChildItem -LiteralPath $h.ResultsDir -Recurse -File) {
        $t = [System.IO.File]::ReadAllText($f.FullName)
        foreach ($s in $h.Secrets) { if ($t.Contains($s)) { $hits += $f.FullName; break } }
    }
    return $hits
}

# ---------------------------------------------------------------------------
# Running things
# ---------------------------------------------------------------------------

function Format-CommandLine {
    param([string] $FilePath, [string[]] $ArgumentList)
    $parts = @($FilePath) + @($ArgumentList)
    return (($parts | ForEach-Object { if ($_ -match '[\s"]' -or $_ -eq '') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' ')
}

# Runs a native program and returns ExitCode, StdOut, StdErr, TimedOut.
#
# ProcessStartInfo.ArgumentList, not a command string, so no argument is ever
# re-split or re-quoted - and no PowerShell native-command handling at all, so
# none of Windows PowerShell's stderr-to-error-record behaviour either. Output
# is read asynchronously (a full pipe would otherwise deadlock the child), and
# the wait polls, so Ctrl+C still works.
function Invoke-Native {
    param(
        [Parameter(Mandatory)][string] $FilePath,
        [string[]] $ArgumentList = @(),
        [string] $WorkingDirectory,
        [hashtable] $Environment = @{},
        [string[]] $RemoveEnvironment = @(),
        [int] $TimeoutSec = 600,
        [AllowNull()][string] $StdinText = $null,
        [switch] $Quiet
    )
    $h = Get-Harness
    if (-not $WorkingDirectory) { $WorkingDirectory = $h.InfraRoot }
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FilePath
    foreach ($a in $ArgumentList) { $psi.ArgumentList.Add([string]$a) }
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = ($null -ne $StdinText)
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    $psi.StandardOutputEncoding = $utf8
    $psi.StandardErrorEncoding = $utf8
    # Removals first, so that a key given in both is SET: an explicit value wins.
    foreach ($k in $RemoveEnvironment) { [void]$psi.Environment.Remove($k) }
    foreach ($k in $Environment.Keys) { $psi.Environment[$k] = [string]$Environment[$k] }

    $cmdLine = Format-CommandLine $FilePath $ArgumentList
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $p = [System.Diagnostics.Process]::new()
    $p.StartInfo = $psi
    try { [void]$p.Start() }
    catch {
        Add-Content -LiteralPath $h.CommandsLog -Value ("{0}  exit=START-FAILED  {1}  # {2}" -f (Get-Date -Format 'HH:mm:ss'), (Protect-Text $cmdLine), $_.Exception.Message) -Encoding utf8NoBOM
        return [pscustomobject]@{ ExitCode = -2; StdOut = ''; StdErr = $_.Exception.Message; TimedOut = $false; CommandLine = $cmdLine }
    }
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    if ($null -ne $StdinText) {
        $p.StandardInput.Write($StdinText)
        $p.StandardInput.Close()
    }
    $timedOut = $false
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
    # Ctrl+C stops the pipeline in the middle of this wait; the finally still
    # runs then, and the child must not outlive the harness.
    try {
        while (-not $p.WaitForExit(250)) {
            if ([DateTime]::UtcNow -gt $deadline) {
                $timedOut = $true
                try { $p.Kill($true) } catch { }
                break
            }
        }
        $p.WaitForExit()
    }
    finally {
        if (-not $p.HasExited) { try { $p.Kill($true) } catch { } }
    }
    $stdout = $outTask.GetAwaiter().GetResult()
    $stderr = $errTask.GetAwaiter().GetResult()
    $rc = if ($timedOut) { -1 } else { $p.ExitCode }
    $sw.Stop()
    $line = "{0}  exit={1,-4} {2,6:0.0}s  {3}{4}" -f (Get-Date -Format 'HH:mm:ss'), $rc, $sw.Elapsed.TotalSeconds, (Protect-Text $cmdLine), $(if ($timedOut) { "  # TIMED OUT after ${TimeoutSec}s" } else { '' })
    Add-Content -LiteralPath $h.CommandsLog -Value $line -Encoding utf8NoBOM
    if (-not $Quiet -and $rc -ne 0) { Write-Verbose "exit $rc from $cmdLine" }
    return [pscustomobject]@{ ExitCode = $rc; StdOut = $stdout; StdErr = $stderr; TimedOut = $timedOut; CommandLine = $cmdLine }
}

# ---------------------------------------------------------------------------
# Docker, behind the guard
# ---------------------------------------------------------------------------

# FAIL-CLOSED. Anything that deletes docker state must name the test project,
# the test volume, or a harness container (hct-*). The real Maven cache and the
# live stack's volumes are touched only with the matching opt-in flag.
function Assert-DockerArgsSafe {
    param([string[]] $DockerArgs)
    $h = Get-Harness
    $a = @($DockerArgs)
    if ($a.Count -eq 0) { return }
    $joined = ' ' + ($a -join ' ') + ' '
    if ($a[0] -eq 'system' -or ($a[0] -in @('volume', 'container', 'image', 'network') -and $a.Count -gt 1 -and $a[1] -eq 'prune')) {
        throw "refused: '$($a -join ' ')' - the harness never prunes"
    }
    if ($a[0] -eq 'volume' -and $a.Count -gt 2 -and $a[1] -in @('rm', 'remove')) {
        foreach ($v in $a[2..($a.Count - 1)]) {
            if ($v -like '-*') { continue }
            $ok = ($v -eq $script:TestMavenVol) -or ($v -like "$($script:TestProject)_*") -or
                  ($v -eq $script:RealMavenVol -and $h.Options.ColdRealMavenVolume)
            if (-not $ok) { throw "refused: removing volume '$v'" }
        }
    }
    if ((($a[0] -eq 'rm') -and $a.Count -gt 1) -or ($a[0] -eq 'container' -and $a.Count -gt 2 -and $a[1] -in @('rm', 'remove'))) {
        $start = if ($a[0] -eq 'rm') { 1 } else { 2 }
        foreach ($c in $a[$start..($a.Count - 1)]) {
            if ($c -like '-*') { continue }
            if (-not ($c -like 'hct-*' -or $c -like "$($script:TestProject)-*")) { throw "refused: removing container '$c'" }
        }
    }
    if ($a[0] -eq 'compose') {
        # The compose SUBCOMMAND is the first word after compose's own options -
        # not any 'rm' or '-v' that happens to appear later, such as a `run -v
        # <dir>:/x <svc> rm -rf ...` whose words belong to the container.
        $withValue = @('-f', '--file', '-p', '--project-name', '--env-file', '--profile', '--project-directory', '--ansi', '--progress', '--parallel')
        $i = 1; $sub = $null; $project = $null
        while ($i -lt $a.Count) {
            $t = $a[$i]
            if ($t -in $withValue) {
                if ($t -in @('-p', '--project-name') -and $i + 1 -lt $a.Count) { $project = $a[$i + 1] }
                $i += 2; continue
            }
            if ($t -like '--project-name=*') { $project = $t.Substring(15); $i++; continue }
            if ($t -like '-*') { $i++; continue }
            $sub = $t; break
        }
        if ($sub -in @('down', 'rm')) {
            $rest = if ($i + 1 -lt $a.Count) { @($a[($i + 1)..($a.Count - 1)]) } else { @() }
            $dropsVolumes = @($rest | Where-Object { $_ -in @('-v', '--volumes') -or $_ -like '--volumes=*' }).Count -gt 0
            $isTest = ($project -eq $script:TestProject)
            if (-not $isTest -and $dropsVolumes -and -not $h.Options.AllowDataLoss) {
                throw "refused: '$($a -join ' ')' on the live project needs -AllowDataLoss"
            }
        }
    }
}

function Invoke-Docker {
    param([Parameter(Mandatory)][string[]] $DockerArgs, [int] $TimeoutSec = 600, [hashtable] $Environment = @{}, [string[]] $RemoveEnvironment = @(), [AllowNull()][string] $StdinText = $null, [string] $WorkingDirectory)
    $h = Get-Harness
    if (-not $h.Docker) { throw 'docker is not on PATH' }
    Assert-DockerArgsSafe $DockerArgs
    $p = @{ FilePath = $h.Docker; ArgumentList = $DockerArgs; TimeoutSec = $TimeoutSec; Environment = $Environment; RemoveEnvironment = $RemoveEnvironment; StdinText = $StdinText }
    if ($WorkingDirectory) { $p.WorkingDirectory = $WorkingDirectory }
    return Invoke-Native @p
}

# The isolated test stack: its own project, containers, network, Maven volume,
# no host ports, checkouts read-only. See test/compose.test.yml.
function Get-TestComposePrefix {
    return @('compose', '-p', $script:TestProject, '-f', 'docker-compose.yml', '-f', 'compose.dev.yml', '-f', 'test/compose.test.yml')
}
function Invoke-TestCompose {
    param([Parameter(Mandatory)][string[]] $ComposeArgs, [int] $TimeoutSec = 900, [hashtable] $Environment = @{})
    return Invoke-Docker -DockerArgs (@(Get-TestComposePrefix) + $ComposeArgs) -TimeoutSec $TimeoutSec -Environment $Environment
}
# The live dev stack, exactly as ./dev drives it.
function Invoke-LiveCompose {
    param([Parameter(Mandatory)][string[]] $ComposeArgs, [int] $TimeoutSec = 900, [hashtable] $Environment = @{})
    return Invoke-Docker -DockerArgs (@('compose', '-f', 'docker-compose.yml', '-f', 'compose.dev.yml') + $ComposeArgs) -TimeoutSec $TimeoutSec -Environment $Environment
}

# The live stack is detected by the names compose pins (homecrew-postgres, ...)
# and by the pinned network - not by project name, which depends on what the
# clone's directory is called.
function Get-LiveContainers {
    $r = Invoke-Docker @('ps', '-a', '--format', '{{.Names}}')
    return @(($r.StdOut -split "`r?`n") | Where-Object { $_ -like "$($script:LiveContainerPrefix)*" -and $_ -notlike "$($script:TestProject)*" })
}
function Test-LiveStackRunning {
    $r = Invoke-Docker @('ps', '--format', '{{.Names}}')
    return @(($r.StdOut -split "`r?`n") | Where-Object { $_ -like "$($script:LiveContainerPrefix)*" -and $_ -notlike "$($script:TestProject)*" }).Count -gt 0
}

function Test-DockerAvailable {
    $h = Get-Harness
    if (-not $h.Docker) { return $false }
    return (Invoke-Docker @('info', '--format', '{{.ServerVersion}}') -TimeoutSec 60).ExitCode -eq 0
}

function Ensure-DevImage {
    $r = Invoke-Docker @('image', 'inspect', $script:DevImage) -TimeoutSec 60
    if ($r.ExitCode -eq 0) { return $true }
    $b = Invoke-Docker @('build', '-t', $script:DevImage, '-f', 'Dockerfile.dev', '.') -TimeoutSec 1800
    if ($b.ExitCode -ne 0) { Save-Evidence -Suite '.' -Name 'dev-image-build.log' -Content ($b.StdOut + "`n" + $b.StdErr) | Out-Null }
    return $b.ExitCode -eq 0
}

# `docker run --rm` of the dev image with the infra repo read-only at /src and
# no network: for unit tests and static checks that must behave the same on
# every host.
$script:InImageCounter = 0
function Invoke-InDevImage {
    param([Parameter(Mandatory)][string] $Script, [string[]] $ExtraArgs = @(), [int] $TimeoutSec = 900, [string] $Image = $script:DevImage, [switch] $WithNetwork, [string] $Name)
    $h = Get-Harness
    # Named, so that a run that times out or is interrupted can be removed:
    # killing the docker client does not stop a `run --rm` container. A -Name
    # must start with hct-, the prefix the guard lets the harness remove.
    if (-not $Name) {
        $script:InImageCounter++
        $Name = ('hct-{0}-{1}' -f ($h.RunId -replace '[^a-z0-9-]', ''), $script:InImageCounter)
    }
    $dockerArgs = @('run', '--rm', '--name', $Name)
    if (-not $WithNetwork) { $dockerArgs += @('--network', 'none') }
    $dockerArgs += @('-v', "$($h.InfraRoot):/src:ro") + $ExtraArgs + @('--entrypoint', 'sh', $Image, '-c', $Script)
    $r = $null
    try { $r = Invoke-Docker -DockerArgs $dockerArgs -TimeoutSec $TimeoutSec }
    finally {
        # $r is still $null when Ctrl+C stopped the wait.
        if ($null -eq $r -or $r.TimedOut) { Invoke-Docker @('rm', '-f', $Name) -TimeoutSec 120 | Out-Null }
    }
    return $r
}

# Variables in YOUR session that compose would prefer over any env file - a
# DEV_RELOAD_INTERVAL or COMPOSE_PROJECT_NAME you exported once - removed from
# a render so that it shows what the files say.
function Get-SessionComposeOverrides {
    return @(Get-ChildItem Env: | Where-Object { $_.Name -match '^(DEV_|COMPOSE_|WEBAPP_|SPRING_PROFILES_ACTIVE$|POSTGRES_|CONFIG_|ENCRYPT_KEY$)' } | ForEach-Object Name)
}

# The model compose actually builds from the files, as JSON. An env file with
# dummy values stands in for .env, so the rendered output contains no secrets.
function Get-ComposeModel {
    param([string[]] $Files = @('docker-compose.yml', 'compose.dev.yml'), [string] $EnvFile = 'test/fixtures/ci.env', [string] $Project, [hashtable] $Environment = @{})
    $dockerArgs = @('compose')
    if ($Project) { $dockerArgs += @('-p', $Project) }
    if ($EnvFile) { $dockerArgs += @('--env-file', $EnvFile) }
    foreach ($f in $Files) { $dockerArgs += @('-f', $f) }
    $dockerArgs += @('config', '--format', 'json')
    $r = Invoke-Docker -DockerArgs $dockerArgs -Environment $Environment -RemoveEnvironment (Get-SessionComposeOverrides) -TimeoutSec 120
    if ($r.ExitCode -ne 0) { return $null }
    return ($r.StdOut | ConvertFrom-Json -Depth 64)
}

# The project name the LIVE stack runs under, the way the launchers resolve it
# (COMPOSE_PROJECT_NAME in the environment or in .env, else the directory
# name). Rendered with the real .env, but only .name is kept - nothing of the
# output is saved.
function Get-LiveProjectName {
    $r = Invoke-Docker -DockerArgs @('compose', '-f', 'docker-compose.yml', '-f', 'compose.dev.yml', 'config', '--format', 'json') -TimeoutSec 120
    if ($r.ExitCode -ne 0) { return $null }
    try { return (($r.StdOut | ConvertFrom-Json -Depth 64).name) } catch { return $null }
}

function Wait-Until {
    param([Parameter(Mandatory)][scriptblock] $Condition, [int] $TimeoutSec = 300, [int] $IntervalSec = 2)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (& $Condition) { return $true }
        Start-Sleep -Seconds $IntervalSec
    }
    return [bool](& $Condition)
}

# Logs of one container since a point in time (RFC3339, from Get-DockerNow),
# without compose prefixes.
function Get-DockerNow {
    $r = Invoke-Docker @('run', '--rm', '--network', 'none', '--entrypoint', 'date', $script:DevImage, '-u', '+%Y-%m-%dT%H:%M:%S.%NZ') -TimeoutSec 60
    return $r.StdOut.Trim()
}
function Get-ContainerLog {
    param([Parameter(Mandatory)][string] $Container, [string] $Since)
    $a = @('logs')
    if ($Since) { $a += @('--since', $Since) }
    $a += $Container
    $r = Invoke-Docker $a -TimeoutSec 120
    return ($r.StdOut + "`n" + $r.StdErr)
}

# ---------------------------------------------------------------------------
# git, read-only
# ---------------------------------------------------------------------------

function Invoke-Git {
    param([Parameter(Mandatory)][string] $Repo, [Parameter(Mandatory)][string[]] $GitArgs, [int] $TimeoutSec = 120)
    $h = Get-Harness
    if (-not $h.Git) { throw 'git is not on PATH' }
    # --no-optional-locks: never take index.lock in your repositories, so a
    # harness `git status` cannot collide with your IDE's.
    return Invoke-Native -FilePath $h.Git -ArgumentList (@('--no-optional-locks', '-C', $Repo) + $GitArgs) -TimeoutSec $TimeoutSec
}
function Get-RepoPath { param([string] $Repo) return Join-Path (Get-Harness).SiblingsRoot $Repo }
function Test-RepoClean { param([string] $Repo) $r = Invoke-Git (Get-RepoPath $Repo) @('status', '--porcelain'); return ($r.ExitCode -eq 0 -and -not $r.StdOut.Trim()) }

# A fingerprint of what a container could have changed behind git's back:
# .git/config and the hooks directory.
function Get-GitConfigHash {
    param([string] $Repo)
    $root = Get-RepoPath $Repo
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $sb = [System.Text.StringBuilder]::new()
    foreach ($f in @((Join-Path $root '.git/config')) + @(Get-ChildItem -LiteralPath (Join-Path $root '.git/hooks') -File -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object FullName)) {
        if (Test-Path -LiteralPath $f) {
            [void]$sb.Append($f.Substring($root.Length)).Append('=').Append([Convert]::ToHexString($sha.ComputeHash([System.IO.File]::ReadAllBytes($f)))).Append(';')
        }
    }
    return $sb.ToString()
}

# ---------------------------------------------------------------------------
# Editing the sibling checkouts, safely
# ---------------------------------------------------------------------------
#
# The reload suite has to edit a real checkout. Every edit goes through a
# manifest written to disk BEFORE the edit: the original bytes (or "did not
# exist") and the hash of every version the harness wrote. Restoring puts back
# the original only if the file still holds bytes the harness wrote - if you
# edited it meanwhile, it refuses and tells you, rather than throwing your work
# away. Bytes are read and written as bytes: Set-Content would add CRLF or a
# BOM depending on the PowerShell version.

$script:Manifest = $null

function Get-Sha256Hex { param([byte[]] $Bytes) return [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($Bytes)) }

function Start-EditManifest {
    param([Parameter(Mandatory)][string] $Name)
    $path = Join-Path (Get-EvidenceDir 'manifests') "$Name.json"
    $script:Manifest = [pscustomobject]@{ Path = $path; Entries = [ordered]@{} }
    Save-Manifest
    return $path
}
function Save-Manifest {
    $m = $script:Manifest
    $json = ($m.Entries.Values | ConvertTo-Json -Depth 6)
    if (-not $json) { $json = '[]' }
    $tmp = "$($m.Path).tmp"
    [System.IO.File]::WriteAllText($tmp, $json, [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $m.Path -Force
}
function Register-ManifestEntry {
    param([string] $Path)
    $m = $script:Manifest
    if (-not $m) { throw 'Start-EditManifest first' }
    if ($m.Entries.Contains($Path)) { return $m.Entries[$Path] }
    $existed = Test-Path -LiteralPath $Path -PathType Leaf
    $e = [pscustomobject]@{
        Path     = $Path
        Existed  = $existed
        Original = if ($existed) { [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($Path)) } else { $null }
        Written  = [System.Collections.Generic.List[string]]::new()
        Dirs     = [System.Collections.Generic.List[string]]::new()
    }
    # Directories the harness creates, so that restore removes exactly those.
    $d = Split-Path -Parent $Path
    $new = @()
    while ($d -and -not (Test-Path -LiteralPath $d)) { $new += $d; $d = Split-Path -Parent $d }
    foreach ($x in $new) { $e.Dirs.Add($x) }
    $m.Entries[$Path] = $e
    Save-Manifest
    return $e
}
function Set-TrackedFile {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][AllowEmptyString()][string] $Content)
    $e = Register-ManifestEntry $Path
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Content)
    $e.Written.Add((Get-Sha256Hex $bytes))
    Save-Manifest
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
    [System.IO.File]::WriteAllBytes($Path, $bytes)
}
function Remove-TrackedFile {
    param([Parameter(Mandatory)][string] $Path)
    $e = Register-ManifestEntry $Path
    $e.Written.Add('ABSENT')
    Save-Manifest
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
}
function Get-TrackedOriginal {
    param([Parameter(Mandatory)][string] $Path)
    $e = Register-ManifestEntry $Path
    if (-not $e.Existed) { return $null }
    return [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($e.Original))
}
# Returns the list of files it refused to restore (empty = all restored).
function Restore-EditManifest {
    param([string] $ManifestPath)
    $entries = if ($ManifestPath) { @(Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json) } elseif ($script:Manifest) { @($script:Manifest.Entries.Values) } else { @() }
    $refused = @()
    foreach ($e in ($entries | Where-Object { $_ })) {
        $p = $e.Path
        $now = if (Test-Path -LiteralPath $p -PathType Leaf) { Get-Sha256Hex ([System.IO.File]::ReadAllBytes($p)) } else { 'ABSENT' }
        $origHash = if ($e.Existed) { Get-Sha256Hex ([Convert]::FromBase64String($e.Original)) } else { 'ABSENT' }
        if ($now -eq $origHash) { continue }
        if (@($e.Written) -notcontains $now) { $refused += $p; continue }
        if ($e.Existed) { [System.IO.File]::WriteAllBytes($p, [Convert]::FromBase64String($e.Original)) }
        elseif (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
    }
    foreach ($e in ($entries | Where-Object { $_ })) {
        foreach ($d in @($e.Dirs)) {
            if ((Test-Path -LiteralPath $d) -and -not (Get-ChildItem -LiteralPath $d -Force | Select-Object -First 1)) { Remove-Item -LiteralPath $d -Force }
        }
    }
    return $refused
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

function Write-Environment {
    $h = Get-Harness
    $lines = @(
        "run:            $($h.RunId)",
        "os:             $([System.Runtime.InteropServices.RuntimeInformation]::OSDescription)",
        "pwsh:           $($PSVersionTable.PSVersion)"
    )
    if ($IsWindows) {
        $ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (Test-Path -LiteralPath $ps51) {
            $v = Invoke-Native -FilePath $ps51 -ArgumentList @('-NoProfile', '-Command', '$PSVersionTable.PSVersion.ToString()') -TimeoutSec 60
            $lines += "powershell 5.1: $($v.StdOut.Trim())"
        }
    }
    if ($h.Docker) {
        $lines += "docker:         $((Invoke-Docker @('version', '--format', '{{.Client.Version}} / engine {{.Server.Version}}') -TimeoutSec 60).StdOut.Trim())"
        $lines += "compose:        $((Invoke-Docker @('compose', 'version', '--short') -TimeoutSec 60).StdOut.Trim())"
        $lines += "docker memory:  $((Invoke-Docker @('info', '--format', '{{.MemTotal}}') -TimeoutSec 60).StdOut.Trim()) bytes"
    }
    if ($h.Git) {
        $lines += "git:            $((Invoke-Native -FilePath $h.Git -ArgumentList @('--version')).StdOut.Trim())"
        $lines += "core.autocrlf:  $((Invoke-Native -FilePath $h.Git -ArgumentList @('config', '--get', 'core.autocrlf')).StdOut.Trim())"
        $lines += "baseline:       $($h.BaselineRef)"
        foreach ($d in Get-ChildItem -LiteralPath $h.SiblingsRoot -Directory -Filter 'home-crew-*') {
            $head = (Invoke-Git $d.FullName @('rev-parse', '--short', 'HEAD')).StdOut.Trim()
            $dirty = if (Test-RepoClean $d.Name) { '' } else { ' (dirty)' }
            $lines += ('  {0,-34} {1}{2}' -f $d.Name, $head, $dirty)
        }
    }
    Save-Evidence -Suite '.' -Name 'env.txt' -Content ($lines -join "`n") | Out-Null
    return $lines
}

function Write-Summary {
    $h = Get-Harness
    $rs = @($h.Results)
    $rs | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $h.ResultsDir 'summary.json') -Encoding utf8NoBOM
    $count = { param($s) @($rs | Where-Object Status -EQ $s).Count }
    $md = [System.Collections.Generic.List[string]]::new()
    $md.Add("# Dev setup verification - $($h.RunId)")
    $md.Add('')
    $md.Add(('PASS {0} - FAIL {1} - WEAK {2} - BLOCKED {3} - WARN {4} - SKIP {5} - INFO {6}' -f (& $count 'PASS'), (& $count 'FAIL'), (& $count 'WEAK'), (& $count 'BLOCKED'), (& $count 'WARN'), (& $count 'SKIP'), (& $count 'INFO')))
    $md.Add('')
    $md.Add('## Environment')
    $md.Add('')
    $md.Add('```')
    $envFile = Join-Path $h.ResultsDir 'env.txt'
    if (Test-Path -LiteralPath $envFile) { foreach ($l in [System.IO.File]::ReadAllLines($envFile)) { $md.Add($l) } }
    $md.Add('```')
    if ($h.Git) {
        $md.Add('')
        $md.Add("## Files changed since $($h.BaselineRef)")
        $md.Add('')
        $md.Add('```')
        $d = Invoke-Git $h.InfraRoot @('diff', '--stat', $h.BaselineRef, '--')
        foreach ($l in ($d.StdOut -split "`r?`n")) { if ($l) { $md.Add($l) } }
        $u = Invoke-Git $h.InfraRoot @('ls-files', '--others', '--exclude-standard')
        foreach ($l in ($u.StdOut -split "`r?`n")) { if ($l) { $md.Add(" $l (untracked)") } }
        $md.Add('```')
    }
    foreach ($suite in ($rs | Select-Object -ExpandProperty Suite -Unique)) {
        $md.Add('')
        $md.Add("## $suite")
        $md.Add('')
        $md.Add('| Status | Id | Req | Result | Evidence |')
        $md.Add('|---|---|---|---|---|')
        foreach ($r in ($rs | Where-Object Suite -EQ $suite)) {
            $msg = ($r.Message -replace '\|', '\|' -replace "`r?`n", ' ')
            $md.Add("| $($r.Status) | $($r.Id) | $(($r.Req) -join ',') | $msg | $(($r.Evidence) -join '<br>') |")
        }
    }
    $lim = @($rs | Where-Object { $_.Status -in @('SKIP', 'BLOCKED', 'WARN', 'WEAK') })
    $md.Add('')
    $md.Add('## Limitations of this run')
    $md.Add('')
    if ($lim.Count -eq 0) { $md.Add('None: nothing was skipped, blocked, weak or warned.') }
    foreach ($r in $lim) { $md.Add("- **$($r.Status)** $($r.Id): $($r.Message)") }
    $info = @($rs | Where-Object { $_.Id -like 'R-PROD-*' })
    if ($info.Count) {
        $md.Add('')
        $md.Add('## Intentionally unchanged production findings')
        $md.Add('')
        foreach ($r in $info) { $md.Add("- $($r.Message)") }
    }
    $md.Add('')
    $md.Add("Every command this run executed, with its exit code: commands.log")
    Set-Content -LiteralPath (Join-Path $h.ResultsDir 'summary.md') -Value ($md -join "`n") -Encoding utf8NoBOM
    return (& $count 'FAIL') + (& $count 'WEAK') + (& $count 'BLOCKED')
}

# ---------------------------------------------------------------------------
# The isolated test project (suites concurrency, parity, mutation)
# ---------------------------------------------------------------------------

# Renders the test model and refuses to go on unless it is actually isolated:
# its own Maven volume and network, no pinned container names, no host ports,
# every service checkout read-only. Returns $null on success, or the reason.
function Test-TestModelIsolated {
    $m = Get-ComposeModel -Files @('docker-compose.yml', 'compose.dev.yml', 'test/compose.test.yml') -Project $script:TestProject
    if (-not $m) { return 'docker compose config failed for the test project' }
    if ($m.volumes.maven_repo.name -ne $script:TestMavenVol) { return "maven_repo is '$($m.volumes.maven_repo.name)', not $($script:TestMavenVol)" }
    if (-not $m.volumes.maven_repo.external) { return 'maven_repo is not external in the test model' }
    if ($m.networks.homecrew.name -ne $script:TestNetwork) { return "network is '$($m.networks.homecrew.name)', not $($script:TestNetwork)" }
    foreach ($p in $m.services.PSObject.Properties) {
        $svc = $p.Value
        if ($svc.PSObject.Properties['container_name'] -and $svc.container_name) { return "$($p.Name) still has container_name $($svc.container_name)" }
        if ($svc.PSObject.Properties['ports'] -and @($svc.ports).Count -gt 0) { return "$($p.Name) still publishes ports" }
    }
    foreach ($s in Get-JavaServices) {
        $app = @($m.services.($s.Name).volumes | Where-Object { $_.target -eq '/app' })
        if ($app.Count -ne 1 -or -not $app[0].read_only) { return "$($s.Name): /app is not mounted read-only" }
    }
    return $null
}

# Everything a test-project run needs, checked or created once: the dev image,
# a target/ directory in each checkout (the mount point of the target volume,
# which docker cannot create inside a read-only bind; target/ is gitignored in
# every service repo), the model isolation, and optionally a fresh test Maven
# volume. Returns $null on success, or the reason it cannot proceed.
function Initialize-TestProject {
    param([switch] $FreshMavenVolume)
    if (-not (Ensure-DevImage)) { return "could not build $($script:DevImage)" }
    foreach ($s in Get-JavaServices) {
        $repo = Get-RepoPath $s.Repo
        $t = Join-Path $repo 'target'
        if (-not (Test-Path -LiteralPath $t)) {
            $ig = Invoke-Git $repo @('check-ignore', '-q', 'target/')
            if ($ig.ExitCode -ne 0) { return "$($s.Repo): target/ is not gitignored - not creating it" }
            New-Item -ItemType Directory -Path $t | Out-Null
        }
    }
    $why = Test-TestModelIsolated
    if ($why) { return "test project is not isolated: $why" }
    if ($FreshMavenVolume) {
        $why = Remove-TestProject
        if ($why) { return "a fresh test Maven volume was asked for, but $why" }
    }
    $v = Invoke-Docker @('volume', 'create', $script:TestMavenVol) -TimeoutSec 60
    if ($v.ExitCode -ne 0) { return "could not create $($script:TestMavenVol)" }
    return $null
}

# Returns $null, or the reason the test Maven volume could not be removed
# (still in use by a leftover container, typically). -KeepMavenVolume keeps
# the test project's Maven cache for the next suite: only the concurrency
# suite needs it cold, and later suites would otherwise re-download everything.
function Remove-TestProject {
    param([switch] $KeepMavenVolume)
    Invoke-TestCompose @('down', '-v', '--remove-orphans') -TimeoutSec 600 | Out-Null
    foreach ($c in (Invoke-Docker @('ps', '-a', '--format', '{{.Names}}')).StdOut -split "`r?`n") {
        if ($c -like 'hct-*') { Invoke-Docker @('rm', '-f', $c) -TimeoutSec 120 | Out-Null }
    }
    if ($KeepMavenVolume) { return $null }
    $v = Invoke-Docker @('volume', 'inspect', $script:TestMavenVol) -TimeoutSec 60
    if ($v.ExitCode -ne 0) { return $null }
    $rm = Invoke-Docker @('volume', 'rm', $script:TestMavenVol) -TimeoutSec 120
    if ($rm.ExitCode -ne 0) { return "could not remove $($script:TestMavenVol): $($rm.StdErr.Trim())" }
    return $null
}

# Roughly what the test project needs: twelve JVM containers at their
# mem_limit plus the infrastructure. Returns $null, or a BLOCKED reason with the
# .wslconfig hint.
function Test-DockerMemory {
    param([long] $NeedBytes = 10GB)
    $r = Invoke-Docker @('info', '--format', '{{.MemTotal}}') -TimeoutSec 60
    [long] $have = 0
    if (-not [long]::TryParse($r.StdOut.Trim(), [ref] $have)) { return $null }
    if ($have -ge $NeedBytes) { return $null }
    return ('the Docker VM has {0:0.0} GB; this needs about {1:0.0} GB. On Windows raise [wsl2] memory= in %UserProfile%\.wslconfig and run wsl --shutdown' -f ($have / 1GB), ($NeedBytes / 1GB))
}

# What the live stack's containers use right now, in bytes: the "used" half of
# docker stats' "used / limit". A suite that starts containers beside a
# running stack adds this to what it needs. 0 when nothing can be read.
function Get-LiveStackMemoryBytes {
    $r = Invoke-Docker @('stats', '--no-stream', '--format', '{{.Name}}|{{.MemUsage}}') -TimeoutSec 120
    [long] $total = 0
    foreach ($line in ($r.StdOut -split "`r?`n")) {
        $p = @($line -split '\|', 2)
        if ($p.Count -lt 2 -or $p[0] -notlike "$($script:LiveContainerPrefix)*" -or $p[0] -like "$($script:TestProject)*") { continue }
        if ($p[1] -notmatch '^\s*([\d.]+)\s*([kKMGT]?i?B)') { continue }
        $mult = switch ($Matches[2]) { 'B' { 1 } 'kB' { 1000 } 'KiB' { 1KB } 'MB' { 1000000 } 'MiB' { 1MB } 'GB' { 1000000000 } 'GiB' { 1GB } 'TiB' { 1TB } default { 0 } }
        $total += [long]([double]::Parse($Matches[1], [System.Globalization.CultureInfo]::InvariantCulture) * $mult)
    }
    return $total
}

# ---------------------------------------------------------------------------
# The real launchers
# ---------------------------------------------------------------------------

# Runs the REAL ./dev or dev.ps1 - the primary entry point on Windows is
# dev.ps1 - with the same guard as a direct docker call: `down -v` on the live
# stack needs -AllowDataLoss. -Launcher ps51 uses Windows PowerShell 5.1
# (Windows only), ps uses the pwsh running the harness, sh uses ./dev through
# Git Bash on Windows or /bin/sh elsewhere, default = ps on Windows, sh elsewhere.
function Get-GitBashSh {
    $h = Get-Harness
    if (-not $h.Git) { return $null }
    $ep = (Invoke-Native -FilePath $h.Git -ArgumentList @('--exec-path') -TimeoutSec 60).StdOut.Trim()
    if (-not $ep) { return $null }
    $root = $ep -replace '[\\/](mingw64|mingw32|clangarm64|clang64|ucrt64)[\\/]libexec[\\/]git-core$', ''
    $sh = Join-Path (Join-Path $root 'bin') 'sh.exe'
    if (Test-Path -LiteralPath $sh) { return $sh }
    return $null
}
function Invoke-Launcher {
    param([Parameter(Mandatory)][string[]] $LauncherArgs, [ValidateSet('default', 'ps', 'ps51', 'sh')][string] $Launcher = 'default', [int] $TimeoutSec = 3600)
    $h = Get-Harness
    $a = @($LauncherArgs)
    if ($a.Count -gt 0 -and $a[0] -eq 'down' -and @($a | Where-Object { $_ -in @('-v', '--volumes') }).Count -gt 0 -and -not $h.Options.AllowDataLoss) {
        throw "refused: launcher 'down -v' on the live stack needs -AllowDataLoss"
    }
    if ($Launcher -eq 'default') { $Launcher = if ($IsWindows) { 'ps' } else { 'sh' } }
    switch ($Launcher) {
        'ps' {
            $exe = (Get-Process -Id $PID).Path
            return Invoke-Native -FilePath $exe -ArgumentList (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $h.InfraRoot 'dev.ps1')) + $a) -TimeoutSec $TimeoutSec
        }
        'ps51' {
            if (-not $IsWindows) { throw 'Windows PowerShell 5.1 exists only on Windows' }
            $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            return Invoke-Native -FilePath $exe -ArgumentList (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $h.InfraRoot 'dev.ps1')) + $a) -TimeoutSec $TimeoutSec
        }
        'sh' {
            $sh = if ($IsWindows) { Get-GitBashSh } else { '/bin/sh' }
            if (-not $sh) { throw 'no POSIX sh: Git for Windows (bin\sh.exe) was not found' }
            return Invoke-Native -FilePath $sh -ArgumentList (@('./dev') + $a) -TimeoutSec $TimeoutSec
        }
    }
}
