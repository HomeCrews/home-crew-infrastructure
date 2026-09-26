# Suite A, static: everything that can be verified without starting the stack.
#
#   A-SH       every shell script parses in sh, dash, bash and busybox ash, and
#              has no CR byte                                             (R8)
#   A-PS       every .ps1 parses under Windows PowerShell 5.1 and pwsh 7, and
#              is ASCII without a BOM                                     (R8)
#   A-EOL      git ls-files --eol across the fifteen checkouts            (R8)
#   A-CFG-01   the rendered model of docker-compose.yml + compose.dev.yml:
#              ports, JDWP, the Maven volume, depends_on, healthchecks, the
#              DEV_* passthrough, and the shared env anchor    (R1 R2 R4 R8 R11)
#   A-CFG-02   config --quiet with your real .env, exit code only         (R8)
#   A-CFG-04   compose.dev.yml does not use ${HOME}                       (R1)
#   A-CFG-05   each Java service's environment against the baseline
#              compose.dev.yml, through an allowlist                      (R6)
#   A-URL-01   container-profile URLs name services, never the host       (R2)
#   A-PROD-01  docker-compose.yml, .github/ and postgres/ are unchanged  (R10)
#   A-PROD-02  every changed file is a dev file or under test/           (R10)
#   A-PROD-03  the fifteen checkouts end the run as they started it      (R10)
#   A-PROD-04  the fourteen siblings are at their baseline commits       (R10)
#   R-PROD-nn  the production findings this change leaves alone, from
#              test/prod-findings.tsv, re-checked every run         (R10, INFO)
#   A-WRAP-01  one Maven wrapper distribution for all twelve              (R3)
#   A-TOOLS-*  what dev-reload.sh and test/ rely on is in the dev image
#
# A-PROD-03 is not run from Invoke-SuiteStatic: it compares a snapshot taken at
# the start of the whole run (Save-SiblingSnapshot) with one taken at the end
# (Compare-SiblingSnapshot), so run.ps1 calls those two around every suite.
#
# THE MODEL IS RENDERED WITH test/fixtures/ci.env, NEVER .env. The rendered JSON
# is saved as evidence, and with dummy values in it there is nothing to leak.
# The real .env is used by exactly one check, A-CFG-02, and only its exit code
# is kept. The render also removes from the CHILD's environment every variable
# the compose files interpolate, plus DEV_*, COMPOSE_* and
# SPRING_PROFILES_ACTIVE: the shell beats the env file in compose, so a
# DEV_RELOAD_INTERVAL left in your session would otherwise be what these checks
# see. This process's own environment is never touched.
#
# Every check that needs docker records SKIP when it is missing, and the rest of
# the suite still runs: A-EOL, A-CFG-04, the URL files, A-PROD and R-PROD need
# only git and the checkouts.

$script:StaticSiblingSnapshot = $null

function Invoke-SuiteStatic {
    Enter-Suite 'static' 'syntax, line endings, the rendered compose model, production scope'
    $ctx = [pscustomobject]@{
        Docker       = [bool](Test-DockerAvailable)
        DevImage     = $null    # $true or $false once Ensure-DevImage has been asked
        AlpineImage  = $null
        Dev          = $null    # docker-compose.yml + compose.dev.yml, rendered with ci.env
        DevEvidence  = $null
        Base         = $null    # docker-compose.yml alone
        BaseEvidence = $null
    }
    # One step failing with an exception must not cost the rest of the suite
    # its results, so each is caught on its own and reported as a FAIL.
    $steps = [ordered]@{
        'A-SH'     = 'Static-ShellSyntax'
        'A-PS'     = 'Static-PsParse'
        'A-EOL'    = 'Static-LineEndings'
        'A-CFG-01' = 'Static-Cfg01'
        'A-CFG-02' = 'Static-Cfg02'
        'A-CFG-04' = 'Static-Cfg04'
        'A-CFG-05' = 'Static-Cfg05'
        'A-URL-01' = 'Static-UrlAudit'
        'A-PROD'   = 'Static-ProdScope'
        'R-PROD'   = 'Static-ProdFindings'
        'A-WRAP'   = 'Static-Wrapper'
        'A-TOOLS'  = 'Static-Tools'
    }
    foreach ($id in $steps.Keys) {
        try { & $steps[$id] $ctx }
        catch { Static-HarnessError $id $_ }
    }
}

# ---------------------------------------------------------------------------
# Small helpers. StrictMode 3.0 throws on a missing property, and compose
# leaves keys out of its JSON rather than writing null, so every optional field
# is read through Static-Prop.
# ---------------------------------------------------------------------------

function Static-HarnessError {
    param([string] $Id, $ErrorRecord)
    $pos = ''
    if ($ErrorRecord.InvocationInfo) { $pos = $ErrorRecord.InvocationInfo.PositionMessage -replace "`r?`n", ' ' }
    Add-Result -Id "$Id-HARNESS-ERROR" -Status 'FAIL' -Message ('harness error in {0}: {1} {2}' -f $Id, $ErrorRecord.Exception.Message, $pos)
}

function Static-Prop {
    param($Obj, [string] $Name)
    if ($null -eq $Obj) { return $null }
    if ($Obj -is [System.Collections.IDictionary]) {
        if ($Obj.Contains($Name)) { return $Obj[$Name] }
        return $null
    }
    $p = $Obj.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    return $p.Value
}

# The elements of a list-valued field, never $null elements: call as
# @(Static-Items $obj 'ports').
function Static-Items {
    param($Obj, [string] $Name)
    $v = Static-Prop $Obj $Name
    if ($null -eq $v) { return }
    foreach ($i in @($v)) { if ($null -ne $i) { $i } }
}

function Static-Keys {
    param($Obj)
    if ($null -eq $Obj) { return }
    foreach ($p in $Obj.PSObject.Properties) { $p.Name }
}

function Static-Svc {
    param($Model, [string] $Name)
    return (Static-Prop (Static-Prop $Model 'services') $Name)
}

# Every service of a model, as name/value properties.
function Static-ServiceProps {
    param($Model)
    $svcs = Static-Prop $Model 'services'
    if ($null -eq $svcs) { return }
    foreach ($p in $svcs.PSObject.Properties) { $p }
}

# A service's environment as a case-SENSITIVE dictionary: environment variable
# names are case-sensitive in the Linux containers, whatever Windows thinks.
function Static-EnvMap {
    param($Svc)
    $d = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
    $e = Static-Prop $Svc 'environment'
    if ($null -ne $e) { foreach ($p in $e.PSObject.Properties) { $d[$p.Name] = $p.Value } }
    return , $d
}

function Static-Int {
    param($Value)
    $i = 0
    if ([int]::TryParse([string]$Value, [ref]$i)) { return $i }
    return -1
}

function Static-FirstLine {
    param([AllowEmptyString()][AllowNull()][string] $Text)
    if (-not $Text) { return '' }
    $l = @($Text -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
    if ($l.Count -eq 0) { return '' }
    return $l[0].Trim()
}

# A stable text form of a JSON value, for "is this the same as the base file's"
# comparisons that must not depend on property order.
function Static-Canon {
    param($Value)
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [string]) { return '"' + $Value + '"' }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $parts = @(foreach ($p in @($Value.PSObject.Properties | Sort-Object Name)) { $p.Name + ':' + (Static-Canon $p.Value) })
        return '{' + ($parts -join ',') + '}'
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $parts = @(foreach ($i in $Value) { Static-Canon $i })
        return '[' + ($parts -join ',') + ']'
    }
    return [string]$Value
}

function Static-Join {
    param($Items, [int] $Max = 12)
    $all = @($Items)
    if ($all.Count -le $Max) { return ($all -join '; ') }
    return (($all | Select-Object -First $Max) -join '; ') + ('; ... and {0} more' -f ($all.Count - $Max))
}

# The fifteen repositories, from baseline-refs.tsv: a checkout missing on disk
# then shows up as a finding instead of being silently left out.
function Static-RepoNames {
    $h = Get-Harness
    $names = @()
    foreach ($line in [System.IO.File]::ReadAllLines((Join-Path $h.TestRoot 'baseline-refs.tsv'))) {
        if ($line -match '^\s*#' -or -not $line.Trim()) { continue }
        $names += ($line -split "`t")[0].Trim()
    }
    return $names
}

function Static-AllServiceNames {
    return @('postgres', 'kafka') + @(Get-JavaServices | ForEach-Object Name) + @('webapp')
}

function Static-DevImage {
    param($Ctx)
    if ($null -eq $Ctx.DevImage) { $Ctx.DevImage = [bool](Ensure-DevImage) }
    return $Ctx.DevImage
}

# node:24-alpine is the webapp's image, so it is normally present already; a
# pull is the fallback, and it needs the network.
function Static-AlpineImage {
    param($Ctx)
    if ($null -eq $Ctx.AlpineImage) {
        $ok = (Invoke-Docker @('image', 'inspect', 'node:24-alpine') -TimeoutSec 60).ExitCode -eq 0
        if (-not $ok) { $ok = (Invoke-Docker @('pull', 'node:24-alpine') -TimeoutSec 900).ExitCode -eq 0 }
        $Ctx.AlpineImage = $ok
    }
    return $Ctx.AlpineImage
}

# ---------------------------------------------------------------------------
# A-SH
# ---------------------------------------------------------------------------

# Git for Windows' root, from `git --exec-path` (<root>/mingw64/libexec/git-core).
# Get-Command git finds <root>\cmd\git.exe, which has no sh.exe beside it.
function Static-GitRoot {
    $h = Get-Harness
    if (-not $h.Git) { return $null }
    $r = Invoke-Git $h.InfraRoot @('--exec-path')
    if ($r.ExitCode -ne 0) { return $null }
    $m = [regex]::Match($r.StdOut.Trim(), '^(.*?)[\\/](mingw64|mingw32|clangarm64|clang64|ucrt64)[\\/]libexec[\\/]git-core[\\/]?$', 'IgnoreCase')
    if (-not $m.Success) { return $null }
    return ($m.Groups[1].Value -replace '/', '\')
}

function Static-ShellSyntax {
    param($Ctx)
    $req = @('R8')
    $rel = 'test/static/sh-syntax.sh'

    # The host. On Windows that is Git Bash's bin\sh.exe - the launcher that
    # puts /usr/bin first on PATH, which the script's grep, sed and tr need -
    # and never a PATH lookup of sh or bash, which can land on WSL's bash.exe in
    # System32. The script and the root are passed relative to the infra root
    # (the working directory), so no path has to survive MSYS conversion.
    $hostSh = $null
    $why = ''
    if ($IsWindows) {
        $gitRoot = Static-GitRoot
        if (-not $gitRoot) { $why = 'git --exec-path does not point into a Git for Windows installation' }
        else {
            $cand = Join-Path $gitRoot 'bin\sh.exe'
            if (Test-Path -LiteralPath $cand -PathType Leaf) { $hostSh = $cand } else { $why = "there is no $cand" }
        }
    }
    elseif (Test-Path -LiteralPath '/bin/sh' -PathType Leaf) { $hostSh = '/bin/sh' }
    else { $why = '/bin/sh does not exist' }

    if ($hostSh) {
        $r = Invoke-Native -FilePath $hostSh -ArgumentList @($rel, '.', 'host') -Environment @{ MSYS_NO_PATHCONV = '1'; MSYS2_ARG_CONV_EXCL = '*' } -TimeoutSec 300
        Static-ImportShellRun -Where 'host' -Label $hostSh -Result $r
    }
    else { Add-Result -Id 'A-SH-host' -Status 'SKIP' -Message "no host shell to parse with: $why" -Req $req }

    if (-not $Ctx.Docker) {
        Add-Result -Id 'A-SH-image' -Status 'SKIP' -Message "docker is not available: dash and bash in $($script:DevImage) did not run" -Req $req
        Add-Result -Id 'A-SH-alpine' -Status 'SKIP' -Message 'docker is not available: busybox ash in node:24-alpine did not run' -Req $req
    }
    else {
        if (Static-DevImage $Ctx) {
            $r = Invoke-InDevImage -Script 'sh /src/test/static/sh-syntax.sh /src image' -TimeoutSec 300
            Static-ImportShellRun -Where 'image' -Label $script:DevImage -Result $r
        }
        else { Add-Result -Id 'A-SH-image' -Status 'BLOCKED' -Message "could not build $($script:DevImage) (see commands.log): dash and bash did not run" -Req $req }
        if (Static-AlpineImage $Ctx) {
            $r = Invoke-InDevImage -Image 'node:24-alpine' -Script 'sh /src/test/static/sh-syntax.sh /src alpine' -TimeoutSec 300
            Static-ImportShellRun -Where 'alpine' -Label 'node:24-alpine' -Result $r
        }
        else { Add-Result -Id 'A-SH-alpine' -Status 'BLOCKED' -Message 'node:24-alpine is not present and could not be pulled: busybox ash did not run' -Req $req }
    }

    # Which parsers actually ran, over the three places together: the point of
    # the three runs is that dash, bash and busybox each saw every file.
    $ran = @{}
    foreach ($res in @((Get-Harness).Results)) {
        if ($res.Id -match '^A-SH-(host|image|alpine)-(sh|dash|bash|busybox)-' -and $res.Status -in @('PASS', 'FAIL')) { $ran["$($Matches[1])-$($Matches[2])"] = $true }
    }
    $missing = @()
    if (@($ran.Keys | Where-Object { $_ -like 'host-*' }).Count -eq 0) { $missing += 'the host shell' }
    foreach ($s in @('dash', 'bash', 'busybox')) {
        if (@($ran.Keys | Where-Object { $_ -like "*-$s" }).Count -eq 0) { $missing += $s }
    }
    $used = (@($ran.Keys | Sort-Object) -join ', ')
    if ($missing.Count -eq 0) { Add-Result -Id 'A-SH-COVERAGE' -Status 'PASS' -Message "every file was parsed by: $used" -Req $req }
    elseif (-not $Ctx.Docker) { Add-Result -Id 'A-SH-COVERAGE' -Status 'SKIP' -Message ('not parsed by {0} (no docker); parsed by: {1}' -f ($missing -join ', '), $(if ($used) { $used } else { 'nothing' })) -Req $req }
    else { Add-Result -Id 'A-SH-COVERAGE' -Status 'WARN' -Message ('not parsed by {0}; parsed by: {1}' -f ($missing -join ', '), $(if ($used) { $used } else { 'nothing' })) -Req $req }
}

function Static-ImportShellRun {
    param([string] $Where, [string] $Label, $Result)
    $h = Get-Harness
    $req = @('R8')
    $ev = Save-Evidence -Suite 'static' -Name "sh-syntax-$Where.txt" -Content ("# test/static/sh-syntax.sh, $Where ($Label), exit $($Result.ExitCode)`n" + $Result.StdOut + "`n# stderr`n" + $Result.StdErr)
    $before = $h.Results.Count
    $n = Import-HcResults -Text $Result.StdOut -Req $req -Evidence @($ev)
    $fails = @($h.Results | Select-Object -Skip $before | Where-Object { $_.Status -eq 'FAIL' }).Count
    if ($Result.TimedOut) {
        Add-Result -Id "A-SH-$Where" -Status 'FAIL' -Message "sh-syntax.sh timed out in $Where ($Label)" -Req $req -Evidence @($ev)
    }
    elseif ($n -eq 0 -and $Where -ne 'host' -and $Result.ExitCode -in @(125, 126, 127)) {
        # docker run itself failed - a mount Docker Desktop refuses, a missing
        # image - so nothing was parsed: an environment problem, not a verdict.
        Add-Result -Id "A-SH-$Where" -Status 'BLOCKED' -Message ('docker run failed in {0} (exit {1}): {2}' -f $Where, $Result.ExitCode, (Static-FirstLine $Result.StdErr)) -Req $req -Evidence @($ev)
    }
    elseif ($n -eq 0) {
        Add-Result -Id "A-SH-$Where" -Status 'FAIL' -Message ('sh-syntax.sh reported nothing in {0} ({1}), exit {2}: {3}' -f $Where, $Label, $Result.ExitCode, (Static-FirstLine $Result.StdErr)) -Req $req -Evidence @($ev)
    }
    elseif ($Result.ExitCode -ne 0 -and $fails -eq 0) {
        Add-Result -Id "A-SH-$Where" -Status 'FAIL' -Message ('sh-syntax.sh exited {0} in {1} without reporting a failure: {2}' -f $Result.ExitCode, $Where, (Static-FirstLine $Result.StdErr)) -Req $req -Evidence @($ev)
    }
    elseif ($Result.ExitCode -eq 0 -and $fails -gt 0) {
        Add-Result -Id "A-SH-$Where" -Status 'FAIL' -Message "sh-syntax.sh reported $fails failure(s) in $Where but exited 0" -Req $req -Evidence @($ev)
    }
}

# ---------------------------------------------------------------------------
# A-PS
# ---------------------------------------------------------------------------

# The pwsh running this harness: the process's own executable when that is
# pwsh (a Store/MSIX install's $PSHOME is not always startable directly), else
# the one in $PSHOME.
function Static-PwshPath {
    $exe = 'pwsh'
    if ($IsWindows) { $exe = 'pwsh.exe' }
    $pp = [System.Environment]::ProcessPath
    if ($pp -and [System.IO.Path]::GetFileName($pp) -ieq $exe) { return $pp }
    $p = Join-Path $PSHOME $exe
    if (Test-Path -LiteralPath $p -PathType Leaf) { return $p }
    if ($pp) { return $pp }
    return (Get-Process -Id $PID).Path
}

function Static-PsParse {
    param($Ctx)
    $h = Get-Harness
    $req = @('R8')
    $files = [System.Collections.Generic.List[string]]::new()
    foreach ($f in @('dev.ps1', 'test/run.ps1')) {
        if (Test-Path -LiteralPath (Join-Path $h.InfraRoot $f) -PathType Leaf) { $files.Add($f) }
        else { Add-Result -Id "A-PS-missing-$f" -Status 'FAIL' -Message "$f does not exist" -Req $req }
    }
    foreach ($dir in @('test/lib', 'test/cli', 'test/static')) {
        $d = Join-Path $h.InfraRoot $dir
        if (-not (Test-Path -LiteralPath $d -PathType Container)) { continue }
        foreach ($f in @(Get-ChildItem -LiteralPath $d -Filter '*.ps1' -File | Sort-Object Name)) { $files.Add("$dir/$($f.Name)") }
    }
    # Relative to the infra root, which is the child's working directory, in
    # the platform's own separators: nothing absolute has to survive a trip
    # through 5.1's command line.
    $sep = [string][System.IO.Path]::DirectorySeparatorChar
    $native = @($files | ForEach-Object { $_ -replace '/', $sep })
    $parser = 'test/static/Test-PsParse.ps1' -replace '/', $sep

    $pwsh = Static-PwshPath
    $a = @('-NoProfile')
    if ($IsWindows) { $a += @('-ExecutionPolicy', 'Bypass') }
    $a += @('-File', $parser) + $native
    $r = Invoke-Native -FilePath $pwsh -ArgumentList $a -TimeoutSec 300
    Static-ImportParse -Engine '7' -Label $pwsh -Result $r -Files @($files)

    if (-not $IsWindows) {
        Add-Result -Id 'A-PS-51' -Status 'SKIP' -Message 'Windows PowerShell 5.1 exists only on Windows; the 5.1 parse runs there' -Req $req
        return
    }
    $ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $ps51 -PathType Leaf)) {
        Add-Result -Id 'A-PS-51' -Status 'SKIP' -Message "Windows PowerShell 5.1 is not at $ps51" -Req $req
        return
    }
    # PSModulePath is dropped for the child: pwsh 7 puts its own module
    # directories first in it, and 5.1 inheriting them can load a 7-only module.
    $r = Invoke-Native -FilePath $ps51 -ArgumentList (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $parser) + $native) -RemoveEnvironment @('PSModulePath') -TimeoutSec 300
    Static-ImportParse -Engine '51' -Label $ps51 -Result $r -Files @($files)
}

function Static-ImportParse {
    param([string] $Engine, [string] $Label, $Result, [string[]] $Files)
    $req = @('R8')
    $ev = Save-Evidence -Suite 'static' -Name "ps-parse-$Engine.txt" -Content ("# test/static/Test-PsParse.ps1 under $Label, exit $($Result.ExitCode)`n" + $Result.StdOut + "`n# stderr`n" + $Result.StdErr)
    $all = "$($Result.StdOut)`n$($Result.StdErr)"
    if ($Result.ExitCode -eq -2) {
        Add-Result -Id "A-PS-$Engine" -Status 'BLOCKED' -Message ('could not start {0}: {1}' -f $Label, (Static-FirstLine $Result.StdErr)) -Req $req -Evidence @($ev)
        return
    }
    # A Group Policy execution policy beats -ExecutionPolicy Bypass. That is the
    # machine's policy, not a defect in the files.
    if ($all -match '(?i)execution ?polic|running scripts is disabled|is not digitally signed') {
        Add-Result -Id "A-PS-$Engine" -Status 'BLOCKED' -Message "$Label refused to run Test-PsParse.ps1 because of the execution policy (a Group Policy setting overrides -ExecutionPolicy Bypass)" -Req $req -Evidence @($ev)
        return
    }
    $lines = @($Result.StdOut -split "`r?`n")
    $engineLine = @($lines | Where-Object { $_ -like "ENGINE`t*" } | Select-Object -First 1)
    if ($engineLine.Count -eq 0) {
        # Test-PsParse.ps1 not parsing under this PowerShell lands here, which
        # is a failure of the files under test like any other.
        Add-Result -Id "A-PS-$Engine" -Status 'FAIL' -Message ('Test-PsParse.ps1 did not run under {0} (exit {1}): {2}' -f $Label, $Result.ExitCode, (Static-FirstLine $all)) -Req $req -Evidence @($ev)
        return
    }
    $ec = @($engineLine[0] -split "`t")
    $ver = if ($ec.Count -ge 2) { $ec[1] } else { '?' }
    $mode = if ($ec.Count -ge 4) { $ec[3] } else { '' }
    if ($mode -and $mode -ne 'FullLanguage') {
        Add-Result -Id "A-PS-$Engine" -Status 'BLOCKED' -Message "PowerShell $ver runs in $mode mode here (an AppLocker or WDAC policy), where scripts cannot call the parser" -Req $req -Evidence @($ev)
        return
    }
    $wrongEngine = ($Engine -eq '51' -and -not $ver.StartsWith('5.')) -or ($Engine -eq '7' -and -not ($ver -match '^([7-9]|\d\d)\.'))
    if ($wrongEngine) {
        Add-Result -Id "A-PS-$Engine" -Status 'FAIL' -Message "expected PowerShell $Engine to do the parsing, but $Label reported $ver" -Req $req -Evidence @($ev)
        return
    }

    $rows = @{}
    foreach ($l in $lines) {
        if ($l -match '^PARSE\t(.*?)\t(OK|FAIL)\t(.*)$') { $rows[($Matches[1] -replace '\\', '/')] = [pscustomobject]@{ Status = $Matches[2]; Detail = $Matches[3] } }
    }
    $printedFails = @($rows.Values | Where-Object { $_.Status -eq 'FAIL' }).Count
    foreach ($f in $Files) {
        $id = "A-PS-$Engine-$f"
        if (-not $rows.ContainsKey($f)) {
            Add-Result -Id $id -Status 'FAIL' -Message "Test-PsParse.ps1 printed no result for $f under PowerShell $ver" -Req $req -Evidence @($ev)
            continue
        }
        $row = $rows[$f]
        $status = 'PASS'
        if ($row.Status -ne 'OK') { $status = 'FAIL' }
        $detail = $row.Detail
        if (-not $detail) { $detail = $row.Status }
        Add-Result -Id $id -Status $status -Message "$f under PowerShell $($ver): $detail" -Req $req -Evidence @($ev)
    }
    $expectExit = [Math]::Min($printedFails, 255)
    if ($Result.ExitCode -ne $expectExit) {
        Add-Result -Id "A-PS-$Engine" -Status 'FAIL' -Message ('Test-PsParse.ps1 exited {0} under {1}, but printed {2} failure(s): {3}' -f $Result.ExitCode, $Label, $printedFails, (Static-FirstLine $Result.StdErr)) -Req $req -Evidence @($ev)
    }
}

# ---------------------------------------------------------------------------
# A-EOL
# ---------------------------------------------------------------------------

# critical: CRLF breaks it inside a Linux container or in Git Bash.
# warn:     CRLF is tolerated today (bin/mvn, Lombok, BuildKit and psql all
#           strip the CR), but it is not intended.
function Static-EolClass {
    param([string] $Repo, [string] $File)
    if ($Repo -eq 'home-crew-infrastructure') {
        if ($File -ceq 'dev' -or $File -like '*.sh' -or $File.StartsWith('test/', [System.StringComparison]::Ordinal) -or $File -match '^(docker-)?compose[^/]*\.ya?ml$') { return 'critical' }
    }
    elseif ($File -ceq 'mvnw' -and @(Get-JavaServices | Where-Object { $_.Repo -eq $Repo }).Count -gt 0) { return 'critical' }
    if ($File -ceq '.mvn/jvm.config' -or $File -match '(^|/)lombok\.config$' -or $File -match '(^|/)Dockerfile\.dev$' -or $File -match '\.sql$') { return 'warn' }
    return $null
}

function Static-LineEndings {
    param($Ctx)
    $h = Get-Harness
    $req = @('R8')
    if (-not $h.Git) {
        Add-Result -Id 'A-EOL-01' -Status 'SKIP' -Message 'git is not on PATH' -Req $req
        return
    }
    $crit = [System.Collections.Generic.List[string]]::new()
    $warn = [System.Collections.Generic.List[string]]::new()
    $attr = [System.Collections.Generic.List[string]]::new()
    $errs = [System.Collections.Generic.List[string]]::new()
    $log = [System.Text.StringBuilder]::new()
    $critCount = 0
    # Files that must be there to be checked at all: a critical file missing
    # from the listing is not "fine", it is unchecked.
    $required = @{}
    foreach ($f in @('dev', 'dev-reload.sh', 'webapp-dev.sh', 'compose.dev.yml', 'docker-compose.yml')) { $required["home-crew-infrastructure/$f"] = $false }
    foreach ($s in Get-JavaServices) { $required["$($s.Repo)/mvnw"] = $false }

    foreach ($repo in Static-RepoNames) {
        $path = Get-RepoPath $repo
        if (-not (Test-Path -LiteralPath (Join-Path $path '.git'))) { $errs.Add("$repo is not a git checkout at $path"); continue }
        # Untracked too (not ignored): test/ before it is committed, a new
        # script someone has not added yet.
        foreach ($set in @('tracked', 'untracked')) {
            $gitArgs = @('ls-files', '--eol', '-z')
            if ($set -eq 'untracked') { $gitArgs += @('--others', '--exclude-standard') }
            $r = Invoke-Git $path $gitArgs
            if ($r.ExitCode -ne 0) { $errs.Add("$($repo): git ls-files ($set) failed with exit $($r.ExitCode)"); continue }
            foreach ($rec in ($r.StdOut -split "`0")) {
                if (-not $rec) { continue }
                $m = [regex]::Match($rec, '^i/(\S*)\s+w/(\S*)\s+attr/([^\t]*)\t(.+)$')
                if (-not $m.Success) { continue }
                $w = $m.Groups[2].Value
                $at = $m.Groups[3].Value.Trim()
                $file = $m.Groups[4].Value
                [void]$log.Append($repo).Append("`t").Append($rec).Append("`n")
                $class = Static-EolClass $repo $file
                if (-not $class) { continue }
                $key = "$repo/$file"
                if ($required.ContainsKey($key)) { $required[$key] = $true }
                $isCrlf = $w -in @('crlf', 'mixed')
                if ($class -eq 'critical') {
                    $critCount++
                    if ($isCrlf) { $crit.Add("$key (w/$w)") }
                    elseif ($at -notmatch '(^|\s)eol=lf(\s|$)') { $attr.Add("$key (attr $at)") }
                }
                elseif ($isCrlf) { $warn.Add("$key (w/$w)") }
            }
        }
    }
    $ev = Save-Evidence -Suite 'static' -Name 'eol.txt' -Content ("# git ls-files --eol, tracked and untracked, all fifteen checkouts`n" + $log.ToString())
    foreach ($k in $required.Keys) { if (-not $required[$k]) { $errs.Add("$k is not in git ls-files, so it was not checked") } }

    $remedy = 'Delete each file and check it out again - git writes LF for it: Remove-Item <file>; git -C <repository> checkout -- <file> (sh: rm <file> && git -C <repository> checkout -- <file>). A file not committed yet has to be converted to LF in the editor.'
    if ($crit.Count -gt 0 -or $errs.Count -gt 0) {
        $msg = @()
        if ($crit.Count -gt 0) { $msg += ('CRLF in files that break with it: {0}. {1}' -f (Static-Join $crit), $remedy) }
        if ($errs.Count -gt 0) { $msg += ('not checked: {0}' -f (Static-Join $errs)) }
        Add-Result -Id 'A-EOL-01' -Status 'FAIL' -Message ($msg -join ' ') -Req $req -Evidence @($ev)
    }
    else {
        Add-Result -Id 'A-EOL-01' -Status 'PASS' -Message "all $critCount critical files are LF in the working tree: dev, *.sh, the compose files and test/** in infra, and mvnw in the twelve services" -Req $req -Evidence @($ev)
    }
    if ($warn.Count -gt 0) {
        Add-Result -Id 'A-EOL-02' -Status 'WARN' -Message ('CRLF where it is tolerated but not intended: {0}. {1}' -f (Static-Join $warn), $remedy) -Req $req -Evidence @($ev)
    }
    else {
        Add-Result -Id 'A-EOL-02' -Status 'PASS' -Message '.mvn/jvm.config, lombok.config, Dockerfile.dev and *.sql are LF in every checkout' -Req $req -Evidence @($ev)
    }
    # LF today, but the next Windows checkout decides by .gitattributes alone.
    if ($attr.Count -gt 0) {
        Add-Result -Id 'A-EOL-03' -Status 'WARN' -Message ('critical files LF today but with no eol=lf attribute, so a fresh Windows checkout would get CRLF: {0}' -f (Static-Join $attr)) -Req $req -Evidence @($ev)
    }
    else {
        Add-Result -Id 'A-EOL-03' -Status 'PASS' -Message 'every critical file has an eol=lf attribute, so a fresh Windows checkout gets LF as well' -Req $req -Evidence @($ev)
    }
}

# ---------------------------------------------------------------------------
# Rendering the compose model
# ---------------------------------------------------------------------------

# Everything whose value in THIS process would change the rendered model: each
# variable the two compose files interpolate, the DEV_* knobs, COMPOSE_* and
# SPRING_PROFILES_ACTIVE. They are removed for the child only.
function Static-ComposeVarsToRemove {
    $h = Get-Harness
    $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($f in @('docker-compose.yml', 'compose.dev.yml')) {
        $p = Join-Path $h.InfraRoot $f
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { continue }
        foreach ($m in [regex]::Matches([System.IO.File]::ReadAllText($p), '(?<!\$)\$\{?([A-Za-z_][A-Za-z0-9_]*)')) { [void]$set.Add($m.Groups[1].Value) }
    }
    foreach ($k in [System.Environment]::GetEnvironmentVariables().Keys) {
        $name = [string]$k
        if ($name -match '^(DEV_|COMPOSE_)') { [void]$set.Add($name) }
    }
    [void]$set.Add('SPRING_PROFILES_ACTIVE')
    # Never these, whatever a compose file happens to mention: the docker CLI
    # finds its contexts and its compose plugin through them (~/.docker on
    # macOS and Linux, %USERPROFILE%\.docker on Windows).
    $keep = @('HOME', 'USERPROFILE', 'PATH', 'PATHEXT', 'APPDATA', 'LOCALAPPDATA', 'PROGRAMDATA', 'SYSTEMROOT', 'WINDIR', 'TEMP', 'TMP', 'TMPDIR', 'XDG_CONFIG_HOME', 'XDG_RUNTIME_DIR')
    return @($set | Where-Object { $keep -notcontains $_ -and $_ -notmatch '^DOCKER_' })
}

# `docker compose config --format json` with test/fixtures/ci.env, run with
# Invoke-Native directly because Invoke-Docker cannot remove variables from the
# child's environment. It is read-only, and still shown to the guard first.
function Static-Render {
    param([Parameter(Mandatory)][string[]] $Files, [hashtable] $Environment = @{}, [Parameter(Mandatory)][string] $Name)
    $h = Get-Harness
    $dockerArgs = @('compose', '--env-file', 'test/fixtures/ci.env')
    foreach ($f in $Files) { $dockerArgs += @('-f', $f) }
    $dockerArgs += @('config', '--format', 'json')
    Assert-DockerArgsSafe $dockerArgs
    $remove = @(Static-ComposeVarsToRemove | Where-Object { -not $Environment.ContainsKey($_) })
    $r = Invoke-Native -FilePath $h.Docker -ArgumentList $dockerArgs -Environment $Environment -RemoveEnvironment $remove -TimeoutSec 120
    $out = [pscustomobject]@{ Model = $null; Evidence = $null; ExitCode = $r.ExitCode; Error = '' }
    if ($r.ExitCode -ne 0) {
        $out.Evidence = Save-Evidence -Suite 'static' -Name "$Name.stderr.txt" -Content ("docker $($dockerArgs -join ' ')`nexit $($r.ExitCode)`n$($r.StdErr)")
        $out.Error = Static-FirstLine $r.StdErr
        if (-not $out.Error) { $out.Error = "exit $($r.ExitCode)" }
        return $out
    }
    $out.Evidence = Save-Evidence -Suite 'static' -Name "$Name.json" -Content $r.StdOut
    try { $out.Model = $r.StdOut | ConvertFrom-Json -Depth 64 }
    catch { $out.Error = "the JSON did not parse: $($_.Exception.Message)" }
    return $out
}

# The lock settings dev-reload.sh passes to its own builds, read from the
# script, so that MAVEN_ARGS is checked against what the builds really use.
function Static-DevReloadLockFlags {
    $h = Get-Harness
    $out = [pscustomobject]@{ Args = @(); JvmProp = $null }
    $p = Join-Path $h.InfraRoot 'dev-reload.sh'
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $out }
    $flags = @()
    foreach ($l in [System.IO.File]::ReadAllLines($p)) {
        if ($l -match '^\s*MVN_FLAGS=') {
            foreach ($m in [regex]::Matches($l, '-Daether\.syncContext\.[A-Za-z.]+=[^\s"]+')) { $flags += $m.Value }
        }
        if ($l -match '^\s*LOCK_JVM_PROP="([^"]+)"') { $out.JvmProp = $Matches[1] }
    }
    $out.Args = @($flags | Select-Object -Unique)
    return $out
}

function Static-Tokens {
    param($Value)
    if ($null -eq $Value) { return @() }
    return @(([string]$Value) -split '\s+' | Where-Object { $_ })
}

# ---------------------------------------------------------------------------
# A-CFG-01
# ---------------------------------------------------------------------------

function Static-Cfg01 {
    param($Ctx)
    if (-not $Ctx.Docker) {
        Add-Result -Id 'A-CFG-01' -Status 'SKIP' -Message 'docker is not available, so the compose model cannot be rendered (A-CFG-01a..h did not run)' -Req @('R1', 'R2', 'R8', 'R11')
        return
    }
    $dev = Static-Render -Files @('docker-compose.yml', 'compose.dev.yml') -Name 'compose-dev'
    $base = Static-Render -Files @('docker-compose.yml') -Name 'compose-base'
    $Ctx.Dev = $dev.Model
    $Ctx.DevEvidence = $dev.Evidence
    $Ctx.Base = $base.Model
    $Ctx.BaseEvidence = $base.Evidence
    if (-not $dev.Model) {
        Add-Result -Id 'A-CFG-01' -Status 'FAIL' -Message "docker compose -f docker-compose.yml -f compose.dev.yml config failed with test/fixtures/ci.env: $($dev.Error)" -Req @('R8') -Evidence @($dev.Evidence)
        return
    }
    foreach ($g in @('a', 'b', 'c', 'd', 'e', 'f', 'g', 'h')) {
        try { & "Static-Cfg01$g" $Ctx }
        catch { Static-HarnessError "A-CFG-01$g" $_ }
    }
}

# (a) Nothing reachable from the LAN: every published port of all fifteen
# services on 127.0.0.1. Without `ports: !override` compose APPENDS to the base
# file's list and the 0.0.0.0 binding survives next to the new one.
function Static-Cfg01a {
    param($Ctx)
    $m = $Ctx.Dev
    $bad = [System.Collections.Generic.List[string]]::new()
    $n = 0
    foreach ($name in Static-AllServiceNames) { if ($null -eq (Static-Svc $m $name)) { $bad.Add("$name is not in the model") } }
    foreach ($sp in @(Static-ServiceProps $m)) {
        foreach ($p in @(Static-Items $sp.Value 'ports')) {
            $n++
            $ip = [string](Static-Prop $p 'host_ip')
            if ($ip -ne '127.0.0.1') {
                $where = if ($ip) { $ip } else { 'every interface' }
                $bad.Add(('{0} {1}->{2} on {3}' -f $sp.Name, (Static-Prop $p 'published'), (Static-Prop $p 'target'), $where))
            }
        }
    }
    # postgres and kafka are published only through their own `ports: !override`
    # stanzas; losing them would lose the host's 127.0.0.1:5432 and :9092.
    foreach ($pair in @(@('postgres', 5432), @('kafka', 9092))) {
        $ports = @(Static-Items (Static-Svc $m $pair[0]) 'ports')
        $hit = @($ports | Where-Object { (Static-Int (Static-Prop $_ 'target')) -eq $pair[1] -and [string](Static-Prop $_ 'published') -eq [string]$pair[1] })
        if ($hit.Count -ne 1) { $bad.Add(('{0} does not publish {1}->{1} exactly once' -f $pair[0], $pair[1])) }
    }
    if ($bad.Count -gt 0) { Add-Result -Id 'A-CFG-01a' -Status 'FAIL' -Message ('not bound to 127.0.0.1 only: {0}' -f (Static-Join $bad)) -Req @('R2', 'R11') -Evidence @($Ctx.DevEvidence) }
    else { Add-Result -Id 'A-CFG-01a' -Status 'PASS' -Message "all $n published ports of the 15 services are bound to 127.0.0.1 (postgres 5432 and kafka 9092 included)" -Req @('R2', 'R11') -Evidence @($Ctx.DevEvidence) }
}

# (b) JDWP: container port 5005 in every JVM, the host port from the table -
# unique, 5005..5016 - and the application port unchanged.
function Static-Cfg01b {
    param($Ctx)
    $m = $Ctx.Dev
    $bad = [System.Collections.Generic.List[string]]::new()
    $seen = @{}
    foreach ($s in Get-JavaServices) {
        $svc = Static-Svc $m $s.Name
        if ($null -eq $svc) { $bad.Add("$($s.Name) is not in the model"); continue }
        $ports = @(Static-Items $svc 'ports')
        $dbg = @($ports | Where-Object { (Static-Int (Static-Prop $_ 'target')) -eq 5005 })
        $app = @($ports | Where-Object { (Static-Int (Static-Prop $_ 'target')) -eq $s.Port })
        if ($dbg.Count -ne 1) { $bad.Add("$($s.Name) has $($dbg.Count) ports with container port 5005, not 1") }
        else {
            $pub = [string](Static-Prop $dbg[0] 'published')
            if ($pub -ne [string]$s.Debug) { $bad.Add("$($s.Name) publishes JDWP on host port $pub, the table says $($s.Debug)") }
            if ($seen.ContainsKey($pub)) { $bad.Add("host port $pub is the debug port of both $($seen[$pub]) and $($s.Name)") } else { $seen[$pub] = $s.Name }
        }
        if ($app.Count -ne 1) { $bad.Add("$($s.Name) has $($app.Count) ports with container port $($s.Port), not 1") }
        elseif ([string](Static-Prop $app[0] 'published') -ne [string]$s.Port) { $bad.Add("$($s.Name) publishes its app port $($s.Port) as $(Static-Prop $app[0] 'published')") }
        if ($ports.Count -ne 2) { $bad.Add("$($s.Name) publishes $($ports.Count) ports, not exactly the app port and the debug port") }
    }
    $web = @(Static-Items (Static-Svc $m 'webapp') 'ports')
    if ($web.Count -ne 1 -or (Static-Int (Static-Prop $web[0] 'target')) -ne 80 -or [string](Static-Prop $web[0] 'published') -ne '4200') {
        $bad.Add(('webapp publishes {0} - expected exactly 4200->80' -f (@($web | ForEach-Object { '{0}->{1}' -f (Static-Prop $_ 'published'), (Static-Prop $_ 'target') }) -join ', ')))
    }
    if ($bad.Count -gt 0) { Add-Result -Id 'A-CFG-01b' -Status 'FAIL' -Message (Static-Join $bad) -Req @('R11') -Evidence @($Ctx.DevEvidence) }
    else {
        $table = @(Get-JavaServices | ForEach-Object { "$($_.Name) $($_.Debug)" }) -join ', '
        Add-Result -Id 'A-CFG-01b' -Status 'PASS' -Message "every JVM listens on container port 5005, published on its own host port ($table); app ports unchanged; webapp 4200->80" -Req @('R11') -Evidence @($Ctx.DevEvidence)
    }
}

# (c) The debugger is the application's alone: DEV_JVM_ARGS opens JDWP, and
# JAVA_TOOL_OPTIONS is EMPTY (not absent, which would inherit the base file's
# -Xmx128m, and not null, which would take the host's value) - otherwise Maven
# and every other JVM in the container would try to bind 5005 too.
function Static-Cfg01c {
    param($Ctx)
    $m = $Ctx.Dev
    $bad = [System.Collections.Generic.List[string]]::new()
    foreach ($s in Get-JavaServices) {
        $e = Static-EnvMap (Static-Svc $m $s.Name)
        if (-not $e.ContainsKey('DEV_JVM_ARGS') -or $null -eq $e['DEV_JVM_ARGS']) { $bad.Add("$($s.Name) has no DEV_JVM_ARGS") }
        else {
            $v = [string]$e['DEV_JVM_ARGS']
            $jm = [regex]::Match($v, '-agentlib:jdwp=(\S+)')
            if (-not $jm.Success) { $bad.Add("$($s.Name): DEV_JVM_ARGS has no -agentlib:jdwp= ($v)") }
            else {
                $opts = @($jm.Groups[1].Value -split ',')
                foreach ($need in @('server=y', 'suspend=n', 'address=*:5005')) { if ($opts -cnotcontains $need) { $bad.Add("$($s.Name): DEV_JVM_ARGS lacks $need ($v)") } }
            }
        }
        if (-not $e.ContainsKey('JAVA_TOOL_OPTIONS')) { $bad.Add("$($s.Name) has no JAVA_TOOL_OPTIONS, so the base file's value applies to every JVM") }
        elseif ($null -eq $e['JAVA_TOOL_OPTIONS']) { $bad.Add("$($s.Name): JAVA_TOOL_OPTIONS is null, so compose passes the host's value through") }
        elseif ([string]$e['JAVA_TOOL_OPTIONS'] -ne '') { $bad.Add("$($s.Name): JAVA_TOOL_OPTIONS is '$($e['JAVA_TOOL_OPTIONS'])', not empty") }
    }
    if ($bad.Count -gt 0) { Add-Result -Id 'A-CFG-01c' -Status 'FAIL' -Message (Static-Join $bad) -Req @('R11') -Evidence @($Ctx.DevEvidence) }
    else { Add-Result -Id 'A-CFG-01c' -Status 'PASS' -Message 'all 12: DEV_JVM_ARGS has -agentlib:jdwp with server=y, suspend=n, address=*:5005, and JAVA_TOOL_OPTIONS is exactly empty' -Req @('R11') -Evidence @($Ctx.DevEvidence) }
}

# (d) One Maven repository for all twelve, in the external volume ./dev
# creates, never a bind of anybody's ~/.m2; and a target/ of their own each.
function Static-Cfg01d {
    param($Ctx)
    $m = $Ctx.Dev
    $bad = [System.Collections.Generic.List[string]]::new()
    $vol = Static-Prop (Static-Prop $m 'volumes') 'maven_repo'
    if ($null -eq $vol) { $bad.Add('there is no top-level volume maven_repo') }
    else {
        if ((Static-Prop $vol 'name') -ne $script:RealMavenVol) { $bad.Add("volume maven_repo is named '$(Static-Prop $vol 'name')', not $($script:RealMavenVol)") }
        if ((Static-Prop $vol 'external') -ne $true) { $bad.Add('volume maven_repo is not external, so ./dev down -v would delete the Maven cache') }
    }
    foreach ($sp in @(Static-ServiceProps $m)) {
        foreach ($mt in @(Static-Items $sp.Value 'volumes')) {
            if ((Static-Prop $mt 'type') -eq 'bind' -and [string](Static-Prop $mt 'source') -match '[/\\]\.m2([/\\]|$)') { $bad.Add("$($sp.Name) bind-mounts $(Static-Prop $mt 'source')") }
        }
    }
    foreach ($s in Get-JavaServices) {
        $mounts = @(Static-Items (Static-Svc $m $s.Name) 'volumes')
        $m2 = @($mounts | Where-Object { (Static-Prop $_ 'target') -eq '/root/.m2' })
        if ($m2.Count -ne 1) { $bad.Add("$($s.Name) has $($m2.Count) mounts at /root/.m2, not 1") }
        elseif ((Static-Prop $m2[0] 'type') -ne 'volume' -or (Static-Prop $m2[0] 'source') -ne 'maven_repo') { $bad.Add("$($s.Name): /root/.m2 is $(Static-Prop $m2[0] 'type') $(Static-Prop $m2[0] 'source'), not volume maven_repo") }
        $tg = @($mounts | Where-Object { (Static-Prop $_ 'target') -eq '/app/target' })
        if ($tg.Count -ne 1) { $bad.Add("$($s.Name) has $($tg.Count) mounts at /app/target, not 1") }
        elseif ((Static-Prop $tg[0] 'type') -ne 'volume' -or (Static-Prop $tg[0] 'source') -ne $s.Volume) { $bad.Add("$($s.Name): /app/target is $(Static-Prop $tg[0] 'type') $(Static-Prop $tg[0] 'source'), not volume $($s.Volume)") }
    }
    if ($bad.Count -gt 0) { Add-Result -Id 'A-CFG-01d' -Status 'FAIL' -Message (Static-Join $bad) -Req @('R1', 'R5') -Evidence @($Ctx.DevEvidence) }
    else { Add-Result -Id 'A-CFG-01d' -Status 'PASS' -Message "maven_repo is the external volume $($script:RealMavenVol); each of the 12 mounts it once at /root/.m2 and its own *_target volume at /app/target; no service binds a .m2 directory" -Req @('R1', 'R5') -Evidence @($Ctx.DevEvidence) }
}

# (e) Startup order: webapp starts on its own, and the Java services wait for
# exactly what they waited for in the base file.
function Static-Cfg01e {
    param($Ctx)
    $bad = [System.Collections.Generic.List[string]]::new()
    $dep = Static-Prop (Static-Svc $Ctx.Dev 'webapp') 'depends_on'
    $webDeps = @(Static-Keys $dep)
    if ($webDeps.Count -gt 0) { $bad.Add("webapp still depends on $($webDeps -join ', ')") }
    if (-not $Ctx.Base) { $bad.Add('docker-compose.yml alone did not render, so there is nothing to compare depends_on with') }
    else {
        foreach ($s in Get-JavaServices) {
            $d = Static-Canon (Static-Prop (Static-Svc $Ctx.Dev $s.Name) 'depends_on')
            $b = Static-Canon (Static-Prop (Static-Svc $Ctx.Base $s.Name) 'depends_on')
            if ($d -cne $b) { $bad.Add("$($s.Name) depends_on is $d, the base file's is $b") }
        }
    }
    $ev = @($Ctx.DevEvidence, $Ctx.BaseEvidence)
    if ($bad.Count -gt 0) { Add-Result -Id 'A-CFG-01e' -Status 'FAIL' -Message (Static-Join $bad) -Req @('R2', 'R8') -Evidence $ev }
    else { Add-Result -Id 'A-CFG-01e' -Status 'PASS' -Message "webapp has no depends_on; the 12 Java services' depends_on equal docker-compose.yml's" -Req @('R2', 'R8') -Evidence $ev }
}

# (f) Only start_period and retries are the dev file's: the probe itself and
# its timing stay production's. The start period has to cover a cold Maven
# build, so it must be at least 240s; compose.dev.yml may give one service more
# (service-discovery builds first, on an empty cache). compose renders these as
# Go durations - 240s comes back as 4m0s, 600s as 10m0s.
function Static-DurationSec {
    param([string] $Text)
    $m = [regex]::Match($Text.Trim(), '^(?:(\d+)h)?(?:(\d+)m)?(?:(\d+(?:\.\d+)?)s)?$')
    if (-not $m.Success -or -not $Text.Trim()) { return -1 }
    $sec = 0.0
    if ($m.Groups[1].Success) { $sec += 3600 * [double]$m.Groups[1].Value }
    if ($m.Groups[2].Success) { $sec += 60 * [double]$m.Groups[2].Value }
    if ($m.Groups[3].Success) { $sec += [double]$m.Groups[3].Value }
    return $sec
}

function Static-Cfg01f {
    param($Ctx)
    $bad = [System.Collections.Generic.List[string]]::new()
    $info = @()
    if (-not $Ctx.Base) { $bad.Add('docker-compose.yml alone did not render') }
    else {
        foreach ($name in @('service-discovery', 'config-server')) {
            $hd = Static-Prop (Static-Svc $Ctx.Dev $name) 'healthcheck'
            $hb = Static-Prop (Static-Svc $Ctx.Base $name) 'healthcheck'
            if ($null -eq $hd) { $bad.Add("$name has no healthcheck"); continue }
            foreach ($k in @('test', 'interval', 'timeout')) {
                $a = Static-Canon (Static-Prop $hd $k)
                $b = Static-Canon (Static-Prop $hb $k)
                if ($a -cne $b) { $bad.Add("$name healthcheck $k is $a, the base file's is $b") }
            }
            $sp = [string](Static-Prop $hd 'start_period')
            $spSec = Static-DurationSec $sp
            if ($spSec -lt 240) { $bad.Add("$name start_period is '$sp', less than the 240s a cold build needs") }
            $info += "$name start_period $sp, retries $(Static-Prop $hd 'retries') (base: $(Static-Prop $hb 'start_period'), $(Static-Prop $hb 'retries'))"
        }
    }
    $ev = @($Ctx.DevEvidence, $Ctx.BaseEvidence)
    if ($bad.Count -gt 0) { Add-Result -Id 'A-CFG-01f' -Status 'FAIL' -Message (Static-Join $bad) -Req @('R8') -Evidence $ev }
    else { Add-Result -Id 'A-CFG-01f' -Status 'PASS' -Message ('healthcheck test, interval and timeout are the base file''s, start_period at least 240s: {0}' -f ($info -join '; ')) -Req @('R8') -Evidence $ev }
}

# (g) The passthrough actually passes through: .env and the shell drive compose
# SUBSTITUTION, so a DEV_* knob reaches dev-reload.sh only if the anchor names
# it. The default render must show the default, 2.
function Static-Cfg01g {
    param($Ctx)
    $bad = [System.Collections.Generic.List[string]]::new()
    $r7 = Static-Render -Files @('docker-compose.yml', 'compose.dev.yml') -Environment @{ DEV_RELOAD_INTERVAL = '7' } -Name 'compose-dev-interval7'
    if (-not $r7.Model) { $bad.Add("the render with DEV_RELOAD_INTERVAL=7 failed: $($r7.Error)") }
    foreach ($s in Get-JavaServices) {
        $d = Static-EnvMap (Static-Svc $Ctx.Dev $s.Name)
        $dv = if ($d.ContainsKey('DEV_RELOAD_INTERVAL')) { [string]$d['DEV_RELOAD_INTERVAL'] } else { '<missing>' }
        if ($dv -cne '2') { $bad.Add("$($s.Name): DEV_RELOAD_INTERVAL is '$dv' with nothing set, not the default 2") }
        if ($r7.Model) {
            $e = Static-EnvMap (Static-Svc $r7.Model $s.Name)
            $v = if ($e.ContainsKey('DEV_RELOAD_INTERVAL')) { [string]$e['DEV_RELOAD_INTERVAL'] } else { '<missing>' }
            if ($v -cne '7') { $bad.Add("$($s.Name): DEV_RELOAD_INTERVAL is '$v' with DEV_RELOAD_INTERVAL=7 set") }
        }
    }
    $ev = @($Ctx.DevEvidence, $r7.Evidence)
    if ($bad.Count -gt 0) { Add-Result -Id 'A-CFG-01g' -Status 'FAIL' -Message (Static-Join $bad) -Req @('R8') -Evidence $ev }
    else { Add-Result -Id 'A-CFG-01g' -Status 'PASS' -Message 'DEV_RELOAD_INTERVAL reaches all 12 containers: 2 by default, 7 when set to 7' -Req @('R8') -Evidence $ev }
}

# (h) `<<` is shallow: a service that wrote its own `environment:` without
# merging the anchor would silently lose the lock settings and JDWP. So every
# shared key must be byte-identical in all twelve, and carry what the Maven
# locks need.
function Static-Cfg01h {
    param($Ctx)
    $bad = [System.Collections.Generic.List[string]]::new()
    $maps = [ordered]@{}
    foreach ($s in Get-JavaServices) {
        $svc = Static-Svc $Ctx.Dev $s.Name
        if ($null -eq $svc) { $bad.Add("$($s.Name) is not in the model"); continue }
        $maps[$s.Name] = Static-EnvMap $svc
    }
    $perService = @('DEV_APP_PORT', 'DEV_MAIN_CLASS')
    $keySet = [System.Collections.Generic.SortedSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($k in @('JAVA_TOOL_OPTIONS', 'MAVEN_OPTS', 'MAVEN_ARGS', 'DEV_JVM_ARGS', 'SPRING_DEVTOOLS_RESTART_TRIGGER_FILE', 'DEV_RELOAD_INTERVAL')) { [void]$keySet.Add($k) }
    foreach ($e in $maps.Values) {
        foreach ($k in $e.Keys) {
            if ($k -cmatch '^(JAVA_TOOL_OPTIONS|MAVEN_OPTS|MAVEN_ARGS|SPRING_DEVTOOLS_.+|DEV_.+)$' -and $perService -cnotcontains $k) { [void]$keySet.Add($k) }
        }
    }
    foreach ($k in $keySet) {
        # Ordinal: [ordered]@{} would fold two values that differ only in case.
        $groups = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[string]]]::new([System.StringComparer]::Ordinal)
        foreach ($name in $maps.Keys) {
            $e = $maps[$name]
            $v = if ($e.ContainsKey($k)) { Static-Canon $e[$k] } else { '<missing>' }
            if (-not $groups.ContainsKey($v)) { $groups[$v] = [System.Collections.Generic.List[string]]::new() }
            $groups[$v].Add($name)
        }
        if ($groups.Count -gt 1) {
            $bad.Add(('{0} differs: {1}' -f $k, (@($groups.Keys | ForEach-Object { '{0} in {1}' -f $_, ($groups[$_] -join ',') }) -join ' / ')))
        }
    }
    # What the values must contain. The flags are checked against dev-reload.sh
    # itself, so that a hand-run ./mvnw locks exactly like its builds do.
    $lock = Static-DevReloadLockFlags
    $needArgs = @('-Daether.syncContext.named.factory=file-lock', '-Daether.syncContext.named.nameMapper=file-gav', '-Daether.syncContext.named.time=900') + @($lock.Args)
    $needArgs = @($needArgs | Select-Object -Unique)
    $needOpts = @('-Daether.named.file-lock.deleteLockFiles=false')
    if ($lock.JvmProp -and $needOpts -cnotcontains $lock.JvmProp) { $needOpts += $lock.JvmProp }
    foreach ($name in $maps.Keys) {
        $e = $maps[$name]
        $opts = @(Static-Tokens $(if ($e.ContainsKey('MAVEN_OPTS')) { $e['MAVEN_OPTS'] } else { $null }))
        foreach ($t in $needOpts) { if ($opts -cnotcontains $t) { $bad.Add("$($name): MAVEN_OPTS lacks $t") } }
        $margs = @(Static-Tokens $(if ($e.ContainsKey('MAVEN_ARGS')) { $e['MAVEN_ARGS'] } else { $null }))
        foreach ($t in $needArgs) { if ($margs -cnotcontains $t) { $bad.Add("$($name): MAVEN_ARGS lacks $t") } }
        $s = Get-JavaService $name
        $port = if ($e.ContainsKey('DEV_APP_PORT')) { [string]$e['DEV_APP_PORT'] } else { '<missing>' }
        if ($port -cne [string]$s.Port) { $bad.Add("$($name): DEV_APP_PORT is $port, its port is $($s.Port)") }
    }
    $pinned = @($maps.Keys | Where-Object { $maps[$_].ContainsKey('DEV_MAIN_CLASS') })
    $note = ''
    if ($pinned.Count -gt 0) { $note = " DEV_MAIN_CLASS is pinned in: $($pinned -join ', ')." }
    if ($bad.Count -gt 0) { Add-Result -Id 'A-CFG-01h' -Status 'FAIL' -Message ((Static-Join $bad) + $note) -Req @('R4', 'R8', 'R11') -Evidence @($Ctx.DevEvidence) }
    else {
        Add-Result -Id 'A-CFG-01h' -Status 'PASS' -Message ('{0} shared keys are identical in all 12 ({1}); MAVEN_OPTS carries {2}; MAVEN_ARGS carries the {3} lock flags dev-reload.sh uses; DEV_APP_PORT matches each port.{4}' -f $keySet.Count, (@($keySet) -join ', '), ($needOpts -join ' '), $needArgs.Count, $note) -Req @('R4', 'R8', 'R11') -Evidence @($Ctx.DevEvidence)
    }
}

# ---------------------------------------------------------------------------
# A-CFG-02, -04, -05
# ---------------------------------------------------------------------------

# The one check that sees the real .env. Its output would contain the values,
# so only the exit code is kept - nothing goes to the evidence directory.
function Static-Cfg02 {
    param($Ctx)
    $h = Get-Harness
    $req = @('R8')
    if (-not $Ctx.Docker) { Add-Result -Id 'A-CFG-02' -Status 'SKIP' -Message 'docker is not available' -Req $req; return }
    if (-not (Test-Path -LiteralPath (Join-Path $h.InfraRoot '.env') -PathType Leaf)) {
        Add-Result -Id 'A-CFG-02' -Status 'SKIP' -Message 'there is no .env (cp .env.example .env), so the real configuration cannot be validated' -Req $req
        return
    }
    $r = Invoke-LiveCompose @('config', '--quiet') -TimeoutSec 120
    if ($r.ExitCode -eq 0) { Add-Result -Id 'A-CFG-02' -Status 'PASS' -Message 'docker compose -f docker-compose.yml -f compose.dev.yml config --quiet with your .env: exit 0 (output not recorded)' -Req $req }
    else { Add-Result -Id 'A-CFG-02' -Status 'FAIL' -Message "docker compose -f docker-compose.yml -f compose.dev.yml config --quiet with your .env: exit $($r.ExitCode). The output is deliberately not recorded (it can contain values from .env); run that command yourself to see the error" -Req $req }
}

# The old ${HOME}/.m2 bind is what made twelve containers share one unlocked
# repository, and on Windows ${HOME} is not even set in every shell.
function Static-Cfg04 {
    param($Ctx)
    $h = Get-Harness
    $req = @('R1')
    $p = Join-Path $h.InfraRoot 'compose.dev.yml'
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { Add-Result -Id 'A-CFG-04' -Status 'FAIL' -Message 'compose.dev.yml does not exist' -Req $req; return }
    $hits = @()
    $i = 0
    foreach ($l in [System.IO.File]::ReadAllLines($p)) {
        $i++
        if ($l -match '^\s*#') { continue }
        if ($l -match '\$\{?HOME\b' -or $l -match '~[/\\]\.m2') { $hits += "line $($i): $($l.Trim())" }
    }
    if ($hits.Count -gt 0) { Add-Result -Id 'A-CFG-04' -Status 'FAIL' -Message ('compose.dev.yml still uses the home directory: {0}' -f (Static-Join $hits)) -Req $req }
    else { Add-Result -Id 'A-CFG-04' -Status 'PASS' -Message 'compose.dev.yml has no ${HOME} and no ~/.m2 outside comments' -Req $req }
}

# The environment each Java service gets, against the baseline compose.dev.yml:
# suite E compares OLD and NEW launches under the NEW compose file, so a change
# that came from compose itself - a lock property landing in JDK_JAVA_OPTIONS,
# say, and so in the application JVM - would be invisible there.
function Static-Cfg05 {
    param($Ctx)
    $h = Get-Harness
    $req = @('R6')
    if (-not $Ctx.Docker) { Add-Result -Id 'A-CFG-05' -Status 'SKIP' -Message 'docker is not available' -Req $req; return }
    if (-not $Ctx.Dev) { Add-Result -Id 'A-CFG-05' -Status 'FAIL' -Message 'the current model did not render (see A-CFG-01), so there is nothing to compare' -Req $req; return }
    if (-not $h.Git) { Add-Result -Id 'A-CFG-05' -Status 'SKIP' -Message 'git is not on PATH' -Req $req; return }
    $ref = $h.BaselineRef
    $g = Invoke-Git $h.InfraRoot @('show', "$($ref):compose.dev.yml")
    if ($g.ExitCode -ne 0) { Add-Result -Id 'A-CFG-05' -Status 'FAIL' -Message ('git show {0}:compose.dev.yml failed: {1}' -f $ref, (Static-FirstLine $g.StdErr)) -Req $req; return }
    $file = Save-Evidence -Suite 'static' -Name 'baseline-compose.dev.yml' -Content $g.StdOut
    # Relative paths in the second -f file resolve against the FIRST file's
    # directory, the infra root, so the copy in the evidence directory renders
    # as if it were in place. The baseline bound ${HOME}/.m2: any HOME will do,
    # and a dummy one keeps your home directory out of the evidence. The docker
    # CLI finds its compose plugin and contexts under HOME on macOS and Linux,
    # though, so DOCKER_CONFIG keeps pointing at the real ~/.docker.
    $dummyHome = Join-Path (Get-EvidenceDir 'static') 'dummy-home'
    $dockerConfig = $env:DOCKER_CONFIG
    if (-not $dockerConfig) { $dockerConfig = Join-Path $HOME '.docker' }
    $r = Static-Render -Files @('docker-compose.yml', $file) -Environment @{ HOME = $dummyHome; DOCKER_CONFIG = $dockerConfig } -Name 'compose-baseline-dev'
    if (-not $r.Model) { Add-Result -Id 'A-CFG-05' -Status 'FAIL' -Message "the baseline compose.dev.yml ($ref) did not render: $($r.Error)" -Req $req -Evidence @($file, $r.Evidence); return }

    $allowedNew = @('MAVEN_ARGS', 'DEV_APP_PORT', 'DEV_COMPILER', 'DEV_MAVEN_EXTRA_ARGS', 'DEV_STOP_TIMEOUT', 'DEV_BOOT_TIMEOUT', 'DEV_OPTIMIZED_LAUNCH')
    $lockProp = '-Daether.named.file-lock.deleteLockFiles=false'
    $bad = [System.Collections.Generic.List[string]]::new()
    $added = @{}
    $jvmChanged = 0
    $optsChanged = 0
    foreach ($s in Get-JavaServices) {
        $oldSvc = Static-Svc $r.Model $s.Name
        if ($null -eq $oldSvc) { $bad.Add("$($s.Name) is not in the baseline model"); continue }
        $old = Static-EnvMap $oldSvc
        $new = Static-EnvMap (Static-Svc $Ctx.Dev $s.Name)
        foreach ($k in $old.Keys) { if (-not $new.ContainsKey($k)) { $bad.Add("$($s.Name): $k was removed") } }
        foreach ($k in $new.Keys) {
            if (-not $old.ContainsKey($k)) {
                if ($allowedNew -ccontains $k) { $added[$k] = 1 + $(if ($added.ContainsKey($k)) { $added[$k] } else { 0 }) }
                else { $bad.Add("$($s.Name): new key $k is not on the allowlist") }
                continue
            }
            if ((Static-Canon $old[$k]) -ceq (Static-Canon $new[$k])) { continue }
            if ($k -ceq 'DEV_JVM_ARGS') {
                # The one intended change: every JVM listens on container port
                # 5005 now, whatever its old per-service port was.
                $expect = [string]$old[$k] -replace 'address=\*:\d+', 'address=*:5005'
                if ([string]$new[$k] -cne $expect) { $bad.Add("$($s.Name): DEV_JVM_ARGS is '$($new[$k])', expected '$expect'") } else { $jvmChanged++ }
            }
            elseif ($k -ceq 'MAVEN_OPTS') {
                # Everything it had, plus the lock property and nothing else.
                $o = @(Static-Tokens $old[$k])
                $n = @(Static-Tokens $new[$k])
                $lost = @($o | Where-Object { $n -cnotcontains $_ })
                $extra = @($n | Where-Object { $o -cnotcontains $_ })
                if ($lost.Count -gt 0 -or ($extra.Count -ne 1) -or $extra[0] -cne $lockProp) { $bad.Add("$($s.Name): MAVEN_OPTS went from '$($old[$k])' to '$($new[$k])'; only $lockProp may be added") } else { $optsChanged++ }
            }
            else { $bad.Add("$($s.Name): $k changed from '$($old[$k])' to '$($new[$k])'") }
        }
        foreach ($k in @('JDK_JAVA_OPTIONS', 'JAVA_TOOL_OPTIONS')) {
            if ($new.ContainsKey($k) -and [string]$new[$k] -match '-D(aether|maven)\.') { $bad.Add("$($s.Name): $k carries Maven settings ($($new[$k])), which would reach the application JVM") }
        }
    }
    $ev = @($file, $r.Evidence, $Ctx.DevEvidence)
    if ($bad.Count -gt 0) { Add-Result -Id 'A-CFG-05' -Status 'FAIL' -Message ('environment changes against {0} outside the allowlist: {1}' -f $ref, (Static-Join $bad)) -Req $req -Evidence $ev }
    else {
        $newKeys = @($added.Keys | Sort-Object | ForEach-Object { "$_ x$($added[$_])" }) -join ', '
        Add-Result -Id 'A-CFG-05' -Status 'PASS' -Message "against $($ref): DEV_JVM_ARGS moved to *:5005 in $jvmChanged, MAVEN_OPTS gained only the lock property in $optsChanged, new keys: $newKeys; nothing else differs, and no Maven setting is in JAVA_TOOL_OPTIONS or JDK_JAVA_OPTIONS" -Req $req -Evidence $ev
    }
}

# ---------------------------------------------------------------------------
# A-URL-01
# ---------------------------------------------------------------------------

function Static-YamlScalar {
    param([string] $Raw)
    $v = ($Raw -replace '\s+#.*$', '').Trim()
    if ($v.Length -ge 2 -and (($v[0] -eq '"' -and $v[-1] -eq '"') -or ($v[0] -eq "'" -and $v[-1] -eq "'"))) { $v = $v.Substring(1, $v.Length - 2) }
    return $v
}

# ${NAME:default} is audited by its default, which is what applies when the
# environment does not set NAME. ${NAME} with no default cannot be audited
# statically and returns $null.
function Static-ResolvePlaceholders {
    param([string] $Value)
    $v = $Value
    for ($i = 0; $i -lt 5 -and $v.Contains('${'); $i++) {
        if ($v -match '\$\{[^}:]+\}') { return $null }
        $v = [regex]::Replace($v, '\$\{[^}:]+:([^}]*)\}', '$1')
    }
    return $v
}

function Static-HostPort {
    param([string] $Value)
    $v = $Value.Trim()
    $m = [regex]::Match($v, '^(?:[A-Za-z][A-Za-z0-9+.-]*:)*//(?:[^@/]*@)?(\[[^\]]+\]|[^/:?#]+)(?::(\d+))?')
    if (-not $m.Success) { $m = [regex]::Match($v, '^(\[[^\]]+\]|[^:/\s]+):(\d+)$') }
    if (-not $m.Success) { return $null }
    return [pscustomobject]@{ Host = $m.Groups[1].Value.ToLowerInvariant(); Port = $m.Groups[2].Value }
}

# Empty when the value is right; otherwise what is wrong with it.
function Static-UrlProblem {
    param([string] $Value, [string] $Expect)
    $resolved = Static-ResolvePlaceholders $Value
    if ($null -eq $resolved) { return "'$Value' is a placeholder without a default" }
    $problems = @()
    foreach ($part in @($resolved -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
        $hp = Static-HostPort $part
        if ($null -eq $hp) { $problems += "cannot read a host and port from '$part'"; continue }
        if ($hp.Host -in @('localhost', '127.0.0.1', 'host.docker.internal', '0.0.0.0', '::1', '[::1]')) { $problems += "'$part' points at $($hp.Host)" }
        if ($hp.Port -match '^50\d\d$') { $problems += "'$part' uses port $($hp.Port), a debug port" }
        $got = '{0}:{1}' -f $hp.Host, $hp.Port
        if ($got -ne $Expect) { $problems += "'$part' is $got, expected $Expect" }
    }
    return ($problems -join '; ')
}

# The effective container-profile URLs, audited line by line without a YAML
# library: in the compose network a service reaches another by service name
# and container port, and localhost, the host's loopback or a published debug
# port there is a bug that only shows once the stack runs.
function Static-UrlAudit {
    param($Ctx)
    $h = Get-Harness
    $req = @('R2')
    $rows = [System.Collections.Generic.List[string]]::new()
    $bad = [System.Collections.Generic.List[string]]::new()
    $n = 0

    $checkedEnv = $false
    if ($Ctx.Dev) {
        $checkedEnv = $true
        foreach ($s in @(Get-JavaServices | Where-Object { $_.ConfigClient })) {
            $e = Static-EnvMap (Static-Svc $Ctx.Dev $s.Name)
            $n++
            if (-not $e.ContainsKey('CONFIG_SERVER_URI')) { $bad.Add("$($s.Name) has no CONFIG_SERVER_URI"); continue }
            $p = Static-UrlProblem ([string]$e['CONFIG_SERVER_URI']) 'config-server:8888'
            $rows.Add("compose $($s.Name)`tCONFIG_SERVER_URI`t$($e['CONFIG_SERVER_URI'])`t$(if ($p) { $p } else { 'ok' })")
            if ($p) { $bad.Add("$($s.Name) CONFIG_SERVER_URI: $p") }
        }
    }

    $keys = @(
        [pscustomobject]@{ Name = 'bootstrap-servers'; Rx = '^\s*bootstrap-servers\s*:\s*(.+)$'; Expect = 'kafka:9092' }
        [pscustomobject]@{ Name = 'defaultZone'; Rx = '^\s*defaultZone\s*:\s*(.+)$'; Expect = 'service-discovery:8761' }
        [pscustomobject]@{ Name = 'datasource url'; Rx = '^\s*url\s*:\s*(jdbc:.+)$'; Expect = 'postgres:5432' }
    )
    $found = @{}
    $cfgRepo = Get-RepoPath 'home-crew-config'
    $cfgFiles = @()
    if (Test-Path -LiteralPath $cfgRepo -PathType Container) { $cfgFiles = @(Get-ChildItem -LiteralPath $cfgRepo -Filter '*-container.yml' -File | Sort-Object Name) }
    else { $bad.Add("home-crew-config is not checked out at $cfgRepo") }
    foreach ($f in $cfgFiles) {
        $i = 0
        foreach ($l in [System.IO.File]::ReadAllLines($f.FullName)) {
            $i++
            if ($l -match '^\s*#') { continue }
            foreach ($k in $keys) {
                $m = [regex]::Match($l, $k.Rx)
                if (-not $m.Success) { continue }
                $v = Static-YamlScalar $m.Groups[1].Value
                $n++
                $found["$($f.Name)|$($k.Name)"] = $true
                $p = Static-UrlProblem $v $k.Expect
                $rows.Add("home-crew-config/$($f.Name):$i`t$($k.Name)`t$v`t$(if ($p) { $p } else { 'ok' })")
                if ($p) { $bad.Add("home-crew-config/$($f.Name):$i $($k.Name): $p") }
            }
        }
    }
    if ($cfgFiles.Count -gt 0) {
        foreach ($need in @('bootstrap-servers', 'defaultZone')) {
            if (-not $found.ContainsKey("application-container.yml|$need")) { $bad.Add("home-crew-config/application-container.yml sets no $need") }
        }
        # Each JPA service needs a container datasource URL, or it would fall
        # back to the default profile's localhost one.
        foreach ($s in @(Get-JavaServices | Where-Object { $_.Jpa })) {
            if (-not $found.ContainsKey("$($s.App)-container.yml|datasource url")) { $bad.Add("home-crew-config/$($s.App)-container.yml has no container datasource url") }
        }
    }

    # config-server is not a config client: its own container profile is in its
    # repository.
    $csProps = Join-Path (Get-RepoPath 'home-crew-config-server') 'src/main/resources/application-container.properties'
    if (-not (Test-Path -LiteralPath $csProps -PathType Leaf)) { $bad.Add('home-crew-config-server has no src/main/resources/application-container.properties') }
    else {
        $i = 0
        $seenZone = $false
        foreach ($l in [System.IO.File]::ReadAllLines($csProps)) {
            $i++
            $m = [regex]::Match($l, '^\s*eureka\.client\.service-?url\.defaultZone\s*[=:]\s*(.+?)\s*$', 'IgnoreCase')
            if (-not $m.Success) { continue }
            $seenZone = $true
            $n++
            $p = Static-UrlProblem $m.Groups[1].Value 'service-discovery:8761'
            $rows.Add("home-crew-config-server/.../application-container.properties:$i`tdefaultZone`t$($m.Groups[1].Value)`t$(if ($p) { $p } else { 'ok' })")
            if ($p) { $bad.Add("config-server application-container.properties:$i defaultZone: $p") }
        }
        if (-not $seenZone) { $bad.Add('config-server application-container.properties sets no eureka defaultZone') }
    }

    $ev = Save-Evidence -Suite 'static' -Name 'url-audit.tsv' -Content ("source`tkey`tvalue`tverdict`n" + ($rows -join "`n") + "`n")
    $served = 'This audits the local checkouts; the configuration config-server actually SERVES comes from GitHub and is audited live in suite stack.'
    if ($bad.Count -gt 0) { Add-Result -Id 'A-URL-01' -Status 'FAIL' -Message ('{0} {1}' -f (Static-Join $bad), $served) -Req $req -Evidence @($ev) }
    elseif (-not $checkedEnv) { Add-Result -Id 'A-URL-01' -Status 'WARN' -Message "$n container-profile URLs in the config files are right, but CONFIG_SERVER_URI was not checked: the compose model did not render (no docker, or see A-CFG-01). $served" -Req $req -Evidence @($ev) }
    else { Add-Result -Id 'A-URL-01' -Status 'PASS' -Message "$n effective container-profile URLs point at config-server:8888, service-discovery:8761, kafka:9092 and postgres:5432 - none at localhost, 127.0.0.1, host.docker.internal or a 50xx port. $served" -Req $req -Evidence @($ev) }
}

# ---------------------------------------------------------------------------
# A-PROD-01, -02, -04
# ---------------------------------------------------------------------------

function Static-GitLines {
    param([string] $Text, [switch] $Nul)
    $sep = "`r?`n"
    if ($Nul) { $sep = "`0" }
    return @($Text -split $sep | Where-Object { $_ })
}

function Static-ProdScope {
    param($Ctx)
    $h = Get-Harness
    $req = @('R10')
    if (-not $h.Git) {
        foreach ($id in @('A-PROD-01', 'A-PROD-02', 'A-PROD-04')) { Add-Result -Id $id -Status 'SKIP' -Message 'git is not on PATH' -Req $req }
        return
    }
    $ref = $h.BaselineRef
    $infra = $h.InfraRoot
    $v = Invoke-Git $infra @('rev-parse', '--verify', '--quiet', "$($ref)^{commit}")
    if ($v.ExitCode -ne 0) {
        foreach ($id in @('A-PROD-01', 'A-PROD-02')) { Add-Result -Id $id -Status 'FAIL' -Message "the baseline $ref is not a commit in this clone (a shallow clone? git fetch --unshallow), so nothing can be compared" -Req $req }
        return
    }

    # A-PROD-01: the production files, working tree against the baseline, and
    # nothing new dropped in beside them.
    $d = Invoke-Git $infra (@('diff', '--exit-code', '--name-status', '--no-renames', $ref, '--') + $script:ProdPaths)
    $u = Invoke-Git $infra (@('ls-files', '--others', '--exclude-standard', '-z', '--') + $script:ProdPaths)
    $untracked = @(Static-GitLines $u.StdOut -Nul)
    $changed = @(Static-GitLines $d.StdOut)
    $ev1 = Save-Evidence -Suite 'static' -Name 'prod-diff.txt' -Content ("git diff --exit-code --name-status $ref -- $($script:ProdPaths -join ' ')`nexit $($d.ExitCode)`n$($d.StdOut)`n$($d.StdErr)`nuntracked:`n$($untracked -join "`n")`n")
    if ($d.ExitCode -eq 0 -and $u.ExitCode -eq 0 -and $untracked.Count -eq 0) {
        Add-Result -Id 'A-PROD-01' -Status 'PASS' -Message "docker-compose.yml, .github/ and postgres/ are unchanged since $ref, with nothing untracked in them" -Req $req -Evidence @($ev1)
    }
    elseif ($d.ExitCode -in @(0, 1) -and $u.ExitCode -eq 0) {
        $what = @()
        if ($changed.Count -gt 0) { $what += "changed: $(Static-Join $changed)" }
        if ($untracked.Count -gt 0) { $what += "untracked: $(Static-Join $untracked)" }
        Add-Result -Id 'A-PROD-01' -Status 'FAIL' -Message ('production files differ from {0} - {1}' -f $ref, ($what -join '; ')) -Req $req -Evidence @($ev1)
    }
    else {
        Add-Result -Id 'A-PROD-01' -Status 'FAIL' -Message ('git diff/ls-files failed (exit {0}/{1}): {2}' -f $d.ExitCode, $u.ExitCode, (Static-FirstLine ($d.StdErr + $u.StdErr))) -Req $req -Evidence @($ev1)
    }

    # A-PROD-02: the whole change set, committed or not, against the dev-file
    # allowlist. Deletions count as changes; renames are split into both names.
    $n = Invoke-Git $infra @('diff', '--name-only', '--no-renames', '-z', $ref, '--')
    $o = Invoke-Git $infra @('ls-files', '--others', '--exclude-standard', '-z')
    if ($n.ExitCode -ne 0 -or $o.ExitCode -ne 0) {
        Add-Result -Id 'A-PROD-02' -Status 'FAIL' -Message ('git diff --name-only / ls-files failed (exit {0}/{1}): {2}' -f $n.ExitCode, $o.ExitCode, (Static-FirstLine ($n.StdErr + $o.StdErr))) -Req $req
    }
    else {
        $all = @(@(Static-GitLines $n.StdOut -Nul) + @(Static-GitLines $o.StdOut -Nul) | Sort-Object -Unique)
        $outside = @($all | Where-Object { $script:DevFiles -cnotcontains $_ -and -not $_.StartsWith('test/', [System.StringComparison]::Ordinal) })
        $inTest = @($all | Where-Object { $_.StartsWith('test/', [System.StringComparison]::Ordinal) }).Count
        $ev2 = Save-Evidence -Suite 'static' -Name 'change-set.txt' -Content ("# changed or untracked since $ref`n" + ($all -join "`n") + "`n")
        if ($outside.Count -gt 0) { Add-Result -Id 'A-PROD-02' -Status 'FAIL' -Message ('outside the dev-file allowlist and test/: {0}' -f (Static-Join $outside)) -Req $req -Evidence @($ev2) }
        else {
            $devTouched = @($all | Where-Object { $script:DevFiles -ccontains $_ })
            Add-Result -Id 'A-PROD-02' -Status 'PASS' -Message ('{0} files changed or added since {1}, all dev-only: {2}, and {3} under test/' -f $all.Count, $ref, ($devTouched -join ', '), $inTest) -Req $req -Evidence @($ev2)
        }
    }

    # A-PROD-04: the service repositories build the production images, so a
    # commit there is a production change - but it can just as well be your own
    # work, which is why this warns rather than fails.
    $notes = @()
    foreach ($repo in Static-RepoNames) {
        if ($repo -eq 'home-crew-infrastructure') { continue }
        $path = Get-RepoPath $repo
        if (-not (Test-Path -LiteralPath (Join-Path $path '.git'))) { $notes += "$repo is not checked out"; continue }
        $base = Get-BaselineRef $repo
        $hd = Invoke-Git $path @('rev-parse', 'HEAD')
        $head = $hd.StdOut.Trim()
        if ($hd.ExitCode -ne 0) { $notes += "$($repo): HEAD unreadable" }
        elseif (-not $head.StartsWith($base, [System.StringComparison]::OrdinalIgnoreCase)) { $notes += "$repo is at $($head.Substring(0, [Math]::Min(10, $head.Length))), baseline $base" }
        if (-not (Test-RepoClean $repo)) { $notes += "$repo has uncommitted changes" }
    }
    if ($notes.Count -gt 0) { Add-Result -Id 'A-PROD-04' -Status 'WARN' -Message ('not at the baseline of test/baseline-refs.tsv, or not clean: {0}. The dev-setup change touches none of these repositories; if this is your own work, it is not the harness' -f (Static-Join $notes)) -Req $req }
    else { Add-Result -Id 'A-PROD-04' -Status 'PASS' -Message 'the 14 sibling repositories are at their baseline commits (test/baseline-refs.tsv) and clean' -Req $req }
}

# ---------------------------------------------------------------------------
# A-PROD-03: the checkouts at the start and at the end of the whole run
# ---------------------------------------------------------------------------

function Static-TakeSnapshot {
    $snap = [ordered]@{}
    foreach ($repo in Static-RepoNames) {
        $path = Get-RepoPath $repo
        $e = [pscustomobject]@{ Head = ''; Status = @(); Config = ''; Error = '' }
        if (-not (Test-Path -LiteralPath (Join-Path $path '.git'))) { $e.Error = 'not a git checkout'; $snap[$repo] = $e; continue }
        $hd = Invoke-Git $path @('rev-parse', 'HEAD')
        $st = Invoke-Git $path @('status', '--porcelain', '--untracked-files=all')
        if ($hd.ExitCode -ne 0 -or $st.ExitCode -ne 0) { $e.Error = "git failed (exit $($hd.ExitCode)/$($st.ExitCode))" }
        $e.Head = $hd.StdOut.Trim()
        $e.Status = @(Static-GitLines $st.StdOut)
        # .git/config and the hooks: what a container that ran git on the bind
        # mount could change without git status ever showing it.
        $e.Config = Get-GitConfigHash $repo
        $snap[$repo] = $e
    }
    return $snap
}

# Called by run.ps1 right after Initialize-Harness, before any suite.
function Save-SiblingSnapshot {
    $h = Get-Harness
    $script:StaticSiblingSnapshot = $null
    if (-not $h.Git) { return }
    $script:StaticSiblingSnapshot = Static-TakeSnapshot
    Save-Evidence -Suite 'static' -Name 'sibling-snapshot-start.json' -Content ($script:StaticSiblingSnapshot | ConvertTo-Json -Depth 5) | Out-Null
}

# Called by run.ps1 at the very end, after every suite (and after the test
# project is gone). Anything that moved is reported - a HEAD that moved as well
# as a dirty tree - because a suite should have left every checkout exactly as
# it found it.
function Compare-SiblingSnapshot {
    param([string] $Suite = 'static')
    $h = Get-Harness
    $req = @('R10')
    if (-not $h.Git) { Add-Result -Suite $Suite -Id 'A-PROD-03' -Status 'SKIP' -Message 'git is not on PATH' -Req $req; return }
    $start = $script:StaticSiblingSnapshot
    if ($null -eq $start) { Add-Result -Suite $Suite -Id 'A-PROD-03' -Status 'SKIP' -Message 'there is no snapshot from the start of the run (Save-SiblingSnapshot was not called)' -Req $req; return }
    $end = Static-TakeSnapshot
    $ev = Save-Evidence -Suite 'static' -Name 'sibling-snapshot-end.json' -Content ($end | ConvertTo-Json -Depth 5)
    $changes = @()
    foreach ($repo in $start.Keys) {
        $a = $start[$repo]
        $b = $end[$repo]
        if ($null -eq $b) { $changes += "$repo disappeared"; continue }
        if ($a.Error -ne $b.Error) { $changes += "$($repo): '$($a.Error)' at the start, '$($b.Error)' at the end" }
        if ($a.Head -ne $b.Head) { $changes += "$($repo): HEAD moved from $($a.Head) to $($b.Head)" }
        $gone = @($a.Status | Where-Object { @($b.Status) -cnotcontains $_ })
        $new = @($b.Status | Where-Object { @($a.Status) -cnotcontains $_ })
        if ($gone.Count -gt 0 -or $new.Count -gt 0) {
            $parts = @()
            if ($new.Count -gt 0) { $parts += "now: $(Static-Join $new 5)" }
            if ($gone.Count -gt 0) { $parts += "no longer: $(Static-Join $gone 5)" }
            $changes += "$($repo) git status changed ($($parts -join '; '))"
        }
        if ($a.Config -ne $b.Config) { $changes += "$($repo): .git/config or .git/hooks changed" }
    }
    if ($changes.Count -gt 0) { Add-Result -Suite $Suite -Id 'A-PROD-03' -Status 'FAIL' -Message ('changed during the run: {0}. If you worked in these repositories while the harness ran, that is you, not the harness' -f (Static-Join $changes)) -Req $req -Evidence @($ev) }
    else { Add-Result -Suite $Suite -Id 'A-PROD-03' -Status 'PASS' -Message "all $(@($start.Keys).Count) repositories end the run as they started it: same HEAD, same git status, same .git/config and hooks" -Req $req -Evidence @($ev) }
}

# ---------------------------------------------------------------------------
# R-PROD
# ---------------------------------------------------------------------------

# A path relative to the homecrew root, with * and ? allowed within a segment.
function Static-ExpandPath {
    param([string] $Root, [string] $Spec)
    $current = @($Root)
    foreach ($seg in @($Spec -split '[\\/]' | Where-Object { $_ })) {
        $next = @()
        foreach ($dir in $current) {
            if ($seg -match '[*?]') {
                if (Test-Path -LiteralPath $dir -PathType Container) {
                    $next += @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like $seg } | Sort-Object Name | ForEach-Object { $_.FullName })
                }
            }
            else {
                $p = Join-Path $dir $seg
                if (Test-Path -LiteralPath $p) { $next += $p }
            }
        }
        $current = $next
    }
    return @($current | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
}

function Static-ProdFindings {
    param($Ctx)
    $h = Get-Harness
    $req = @('R10')
    $tsv = Join-Path $h.TestRoot 'prod-findings.tsv'
    if (-not (Test-Path -LiteralPath $tsv -PathType Leaf)) { Add-Result -Id 'R-PROD' -Status 'FAIL' -Message 'test/prod-findings.tsv is missing' -Req $req; return }
    $rows = 0
    $log = [System.Text.StringBuilder]::new()
    $lineNo = 0
    foreach ($line in [System.IO.File]::ReadAllLines($tsv)) {
        $lineNo++
        if (-not $line.Trim() -or $line.StartsWith('#')) { continue }
        $c = @($line -split "`t")
        if ($c.Count -ne 6) { Add-Result -Id "R-PROD-LINE$lineNo" -Status 'FAIL' -Message "test/prod-findings.tsv line $lineNo has $($c.Count) columns, not 6" -Req $req; continue }
        $rows++
        $id = $c[0].Trim(); $loc = $c[1]; $impact = $c[2]; $follow = $c[3]
        $specs = @($c[4] -split ';;')
        $rxs = @($c[5] -split ';;')
        if ($rxs.Count -eq 1 -and $specs.Count -gt 1) { $rxs = @(foreach ($x in $specs) { $c[5] }) }
        $state = 'still present'
        if ($rxs.Count -ne $specs.Count) { $state = 'not checked: the row has a different number of files and regexes' }
        else {
            # Present only while every spec holds: each needs at least one
            # matching file.
            for ($i = 0; $i -lt $specs.Count; $i++) {
                $files = @(Static-ExpandPath $h.SiblingsRoot $specs[$i])
                if ($files.Count -eq 0) { $state = "not checked: $($specs[$i]) not found"; break }
                $re = $null
                try { $re = [regex]::new($rxs[$i], [System.Text.RegularExpressions.RegexOptions]::Multiline) }
                catch { $state = "not checked: invalid regex for $($specs[$i])"; break }
                $hits = @($files | Where-Object { $re.IsMatch(([System.IO.File]::ReadAllText($_) -replace "`r`n", "`n")) })
                [void]$log.Append("R-PROD-$id`t$($specs[$i])`t$($hits.Count)/$($files.Count) match`t$(@($hits | ForEach-Object { [System.IO.Path]::GetRelativePath($h.SiblingsRoot, $_) }) -join ', ')`n")
                if ($hits.Count -eq 0) { $state = 'no longer present'; break }
            }
        }
        Add-Result -Id "R-PROD-$id" -Status 'INFO' -Message ('{0}: {1} Follow-up: {2} ({3})' -f $loc, $impact, $follow, $state) -Req $req
    }
    $ev = Save-Evidence -Suite 'static' -Name 'prod-findings.txt' -Content $log.ToString()
    if ($rows -eq 0) { Add-Result -Id 'R-PROD' -Status 'FAIL' -Message 'test/prod-findings.tsv has no findings in it' -Req $req -Evidence @($ev) }
}

# ---------------------------------------------------------------------------
# A-WRAP-01
# ---------------------------------------------------------------------------

# dev-reload.sh installs ONE wrapper distribution into the shared volume for all
# twelve; twelve different distributionUrls would be twelve installs racing for
# the same lock, and twelve Mavens.
function Static-Wrapper {
    param($Ctx)
    $req = @('R3')
    $byUrl = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[string]]]::new([System.StringComparer]::Ordinal)
    $noSha = @()
    $missing = @()
    $versions = @{}
    foreach ($s in Get-JavaServices) {
        $f = Join-Path (Get-RepoPath $s.Repo) '.mvn/wrapper/maven-wrapper.properties'
        if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { $missing += $s.Repo; continue }
        $props = @{}
        foreach ($l in [System.IO.File]::ReadAllLines($f)) {
            if ($l -match '^\s*([A-Za-z0-9_.]+)\s*[=:]\s*(.*?)\s*$') { $props[$Matches[1]] = ($Matches[2] -replace '\\:', ':') }
        }
        $url = if ($props.ContainsKey('distributionUrl')) { [string]$props['distributionUrl'] } else { '<none>' }
        if (-not $byUrl.ContainsKey($url)) { $byUrl[$url] = [System.Collections.Generic.List[string]]::new() }
        $byUrl[$url].Add($s.Repo)
        if (-not $props.ContainsKey('distributionSha256Sum')) { $noSha += $s.Repo }
        $versions["$(if ($props.ContainsKey('wrapperVersion')) { $props['wrapperVersion'] } else { '?' }) $(if ($props.ContainsKey('distributionType')) { $props['distributionType'] } else { '?' })"] = $true
    }
    if ($missing.Count -gt 0 -or $byUrl.Count -ne 1 -or $byUrl.ContainsKey('<none>')) {
        $parts = @()
        if ($missing.Count -gt 0) { $parts += "no .mvn/wrapper/maven-wrapper.properties in $($missing -join ', ')" }
        if ($byUrl.Count -gt 1 -or $byUrl.ContainsKey('<none>')) { $parts += (@($byUrl.Keys | ForEach-Object { '{0} in {1}' -f $_, ($byUrl[$_] -join ',') }) -join ' / ') }
        Add-Result -Id 'A-WRAP-01' -Status 'FAIL' -Message ('the twelve do not share one wrapper distribution: {0}' -f ($parts -join '; ')) -Req $req
    }
    else {
        Add-Result -Id 'A-WRAP-01' -Status 'PASS' -Message ('all 12 use {0} (wrapperVersion/distributionType: {1})' -f @($byUrl.Keys)[0], (@($versions.Keys) -join ', ')) -Req $req
    }
    if ($noSha.Count -gt 0) {
        Add-Result -Id 'A-WRAP-02' -Status 'INFO' -Message ('{0} of 12 have no distributionSha256Sum, so the wrapper runs the Maven it downloads unverified (production finding R-PROD-08)' -f $noSha.Count) -Req $req
    }
}

# ---------------------------------------------------------------------------
# A-TOOLS
# ---------------------------------------------------------------------------

# What dev-reload.sh and the other suites take for granted in the dev image,
# checked in the image itself: flock for the wrapper install, javap for the
# main class, jcmd for suite E, curl for readiness, git for Maven's validate
# phase, GNU find -printf for the fingerprints.
function Static-Tools {
    param($Ctx)
    $h = Get-Harness
    $reqs = @{
        'flock' = @('R3'); 'javac' = @('R6'); 'javap' = @('R6'); 'jcmd' = @('R6'); 'jar' = @('R6')
        'curl' = @('R7'); 'git' = @('R8'); 'ps' = @('R7'); 'cksum' = @('R7'); 'find-printf' = @('R7')
        'mvnd' = @('R4'); 'arch' = @('R8'); 'java' = @('R6')
    }
    if (-not $Ctx.Docker) { Add-Result -Id 'A-TOOLS' -Status 'SKIP' -Message 'docker is not available' -Req @('R3', 'R6', 'R7'); return }
    if (-not (Static-DevImage $Ctx)) { Add-Result -Id 'A-TOOLS' -Status 'BLOCKED' -Message "could not build $($script:DevImage) (see commands.log)" -Req @('R3', 'R6', 'R7'); return }
    $body = @'
# Written by test/lib/SuiteStatic.ps1 (A-TOOLS); runs in homecrew-dev-runtime:jdk25.
. /src/test/container/lib.sh
tool() {
    _id=$1; _c=$2; shift 2
    if _p=$(command -v "$_c" 2>/dev/null); then
        _v=""
        if [ $# -gt 0 ]; then _v=$("$@" 2>&1 | sed -n 1p); fi
        hc_pass "A-TOOLS-$_id" "$_c: $_p${_v:+ ($_v)}"
    else
        hc_fail "A-TOOLS-$_id" "$_c is not on PATH in the dev image"
    fi
}
tool flock flock flock --version
tool javac javac javac -version
tool javap javap
tool jcmd jcmd
tool jar jar
tool curl curl curl --version
tool git git git --version
tool ps ps
tool cksum cksum
d=$(mktemp -d)
: >"$d/a b"
rc=0
out=$(find "$d" -type f -printf '%p %s %T@\n' 2>&1) || rc=$?
case $out in
    "$d/a b 0 "[0-9]*) hc_pass A-TOOLS-find-printf "find -printf '%p %s %T@' works: $out" ;;
    *) hc_fail A-TOOLS-find-printf "find -printf did not work (exit $rc): $out" ;;
esac
rm -rf "$d"
if p=$(command -v mvnd 2>/dev/null); then
    hc_info A-TOOLS-mvnd "mvnd: $p -> $(readlink -f "$p")"
else
    hc_info A-TOOLS-mvnd "mvnd is not installed in the image: dev-reload.sh builds with sh ./mvnw instead (slower)"
fi
hc_info A-TOOLS-arch "uname -m: $(uname -m); dpkg architecture: $(dpkg --print-architecture 2>/dev/null || echo n/a)"
hc_info A-TOOLS-java "$(java -version 2>&1 | sed -n 1p); /bin/sh is $(readlink -f /bin/sh)"
hc_exit
'@
    $scriptFile = Save-Evidence -Suite 'static' -Name 'a-tools.sh' -Content ($body -replace "`r`n", "`n")
    # The results directory is inside the infra root, which the container sees
    # read-only at /src: run the saved copy, so the evidence is what ran.
    $rel = [System.IO.Path]::GetRelativePath($h.InfraRoot, $scriptFile)
    if ($rel.StartsWith('..')) { $r = Invoke-InDevImage -Script ($body -replace "`r`n", "`n") -TimeoutSec 300 }
    else { $r = Invoke-InDevImage -Script ("sh '/src/" + ($rel -replace '\\', '/') + "'") -TimeoutSec 300 }
    $ev = Save-Evidence -Suite 'static' -Name 'a-tools.txt' -Content ("exit $($r.ExitCode)`n$($r.StdOut)`n# stderr`n$($r.StdErr)")
    $n = 0
    foreach ($l in @($r.StdOut -split "`r?`n")) {
        if ($l -notmatch "^HCRESULT`tA-TOOLS-([^`t]+)`t") { continue }
        $req = if ($reqs.ContainsKey($Matches[1])) { $reqs[$Matches[1]] } else { @('R8') }
        $n += Import-HcResults -Text $l -Req $req -Evidence @($ev, $scriptFile)
    }
    if ($n -eq 0) { Add-Result -Id 'A-TOOLS' -Status 'FAIL' -Message ('the tool check reported nothing (exit {0}): {1}' -f $r.ExitCode, (Static-FirstLine $r.StdErr)) -Req @('R3', 'R6', 'R7') -Evidence @($ev) }
}
