# Suite B (cli): dev and dev.ps1 against a fake docker. Every scenario in
# test/cli/scenarios.tsv, under every shell and PowerShell the two launchers
# are used with, checked against the table - and then the implementations
# checked against EACH OTHER, which is what "dev.ps1 mirrors ./dev" means
# (R9; the volume create and `down -v` rows also carry R1).
#
# Implementations (result ids are B-<impl>-<scenario>):
#
#   sh       test/cli/run-cli.sh on the host's sh - /bin/sh on macOS and
#            Linux, Git Bash's sh.exe on Windows - against fake-docker.sh
#   dash     the same inside homecrew-dev-runtime:jdk25 (Ubuntu's dash)
#   busybox  the same inside node:24-alpine (busybox ash)
#   wsl      the same inside the default WSL distribution (-WithWsl only)
#   gitbash  ./dev under <GitRoot>\bin\sh.exe against FakeDocker.exe: the one
#            run where MSYS argument rewriting can actually happen (Windows)
#   ps51     dev.ps1 under Windows PowerShell 5.1 (Windows)
#   ps7      dev.ps1 under PowerShell 7
#
# The container runs use --network none and see the infra checkout read-only
# at /src; run-cli.sh builds its sandbox in the container's /tmp and writes
# transcripts to a mounted directory under this run's results. Nothing here
# touches a real docker daemon's state: the containers are --rm and the
# launchers only ever meet the fake.
#
# Results:
#
#   B-<impl>-<id>   one scenario on one implementation vs scenarios.tsv
#   B-<impl>        an implementation that could not run at all (SKIP/BLOCKED)
#   B-PARITY-<id>   every implementation that ran <id> produced the same exit
#                   code, the same docker calls in the same working
#                   directories, and the same '==>' lines
#   B-MAP-01        every function of dev and dev.ps1 is paired in
#                   test/cli/function-map.txt
#
# Invoke-CliScenarioSet runs chosen scenarios against chosen scripts WITHOUT
# recording results, for the mutation suite: it points it at the baseline
# dev.ps1 and expects `down-v` to FAIL.
#
# test/cli/Invoke-CliScenarios.ps1 is dot-sourced inside the two public
# functions (see its header for why it cannot be run with &). Its CliScen-*
# functions then live in that function's scope, and PowerShell's dynamic
# scoping makes them visible to the Cli-* helpers called from there.

function Invoke-SuiteCli {
    Enter-Suite 'cli' 'dev and dev.ps1 against a fake docker: every scenario, every shell, then parity'
    $h = Get-Harness
    $cliDir = [System.IO.Path]::Combine($h.TestRoot, 'cli')
    . ([System.IO.Path]::Combine($cliDir, 'Invoke-CliScenarios.ps1'))
    $scenarios = @(CliScen-ReadScenarios ([System.IO.Path]::Combine($cliDir, 'scenarios.tsv')))
    $ev = Get-EvidenceDir 'cli'

    Cli-CheckFunctionMap

    # Reported as each implementation finishes, so a long Git Bash or
    # container run shows progress rather than a silent wait.
    $runners = @(
        @{ Label = 'sh'; Run = { Cli-RunHostSh -Scenarios $scenarios -OutRoot $ev } }
        @{ Label = 'dash'; Run = { Cli-RunInContainer -Impl 'dash' -Image $script:DevImage -Scenarios $scenarios -OutRoot $ev } }
        @{ Label = 'busybox'; Run = { Cli-RunInContainer -Impl 'busybox' -Image 'node:24-alpine' -Scenarios $scenarios -OutRoot $ev } }
        @{ Label = 'wsl'; Run = { Cli-RunWsl -Scenarios $scenarios -OutRoot $ev } }
        @{ Label = 'ps'; Run = { CliScen-Invoke -InfraRoot $h.InfraRoot -OutDir $ev -Scenarios $scenarios } }
    )
    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($runner in $runners) {
        $start = $results.Count
        Cli-Collect $runner.Label $runner.Run $results
        for ($k = $start; $k -lt $results.Count; $k++) { Cli-Report $results[$k] }
    }
    Cli-AddParity -Scenarios $scenarios -Results $results.ToArray()
}

# Runs scenarios against the given launcher scripts and RETURNS the result
# objects (Impl, Id, Status, Message, Req, Evidence, Exit, Calls, CallsCwd,
# Info) without recording anything: the caller decides what a FAIL means.
#
#   Invoke-CliScenarioSet -DevPs1 <baseline dev.ps1> -Only down-v
#
# Implementations default to what the given scripts need: ps7 (and ps51 on
# Windows) for -DevPs1, sh (and gitbash on Windows) for -DevScript. Pass
# -Implementations to choose, including dash and busybox.
function Invoke-CliScenarioSet {
    param(
        [string] $DevScript = '',
        [string] $DevPs1 = '',
        [string[]] $Only = @(),
        [string[]] $Implementations = @()
    )
    $h = Get-Harness
    $cliDir = [System.IO.Path]::Combine($h.TestRoot, 'cli')
    . ([System.IO.Path]::Combine($cliDir, 'Invoke-CliScenarios.ps1'))
    $scenarios = @(CliScen-ReadScenarios ([System.IO.Path]::Combine($cliDir, 'scenarios.tsv')))
    foreach ($p in @($DevScript, $DevPs1)) {
        if ($p -and -not [System.IO.File]::Exists($p)) { throw "Invoke-CliScenarioSet: no such file: $p" }
    }
    $only = @($Only | Where-Object { $_ })
    foreach ($o in $only) {
        if ($o -notmatch '^[A-Za-z0-9._-]+$') { throw "Invoke-CliScenarioSet: bad scenario id '$o'" }
        if (@($scenarios | Where-Object { $_.Id -eq $o }).Count -eq 0) { throw "Invoke-CliScenarioSet: no scenario '$o' in scenarios.tsv" }
    }
    $out = [System.IO.Path]::Combine((Get-EvidenceDir 'cli'), ('set-' + (Get-Date -Format 'HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6)))
    [void][System.IO.Directory]::CreateDirectory($out)

    $impls = @($Implementations | Where-Object { $_ })
    if ($impls.Count -eq 0) {
        if ($DevPs1) { $impls += 'ps7'; if ($IsWindows) { $impls += 'ps51' } }
        if ($DevScript) { $impls += 'sh'; if ($IsWindows) { $impls += 'gitbash' } }
        if ($impls.Count -eq 0) {
            $impls = @('sh', 'ps7')
            if ($IsWindows) { $impls += @('ps51', 'gitbash') }
        }
    }

    $results = [System.Collections.Generic.List[object]]::new()
    if ($impls -contains 'sh') {
        Cli-Collect 'sh' { Cli-RunHostSh -Scenarios $scenarios -OutRoot $out -Only $only -DevScript $DevScript } $results
    }
    foreach ($c in @(@{ Impl = 'dash'; Image = $script:DevImage }, @{ Impl = 'busybox'; Image = 'node:24-alpine' })) {
        if ($impls -notcontains $c.Impl) { continue }
        $ci = $c.Impl
        $cim = $c.Image
        Cli-Collect $ci { Cli-RunInContainer -Impl $ci -Image $cim -Scenarios $scenarios -OutRoot $out -Only $only -DevScript $DevScript } $results
    }
    $ps = @($impls | Where-Object { $_ -in @('ps51', 'ps7', 'gitbash') })
    if ($ps.Count -gt 0) {
        Cli-Collect 'ps' {
            CliScen-Invoke -InfraRoot $h.InfraRoot -OutDir $out -Scenarios $scenarios -Implementations $ps -Only $only -DevScript $DevScript -DevPs1 $DevPs1
        } $results
    }
    return $results.ToArray()
}

# ---------------------------------------------------------------------------
# Plumbing
# ---------------------------------------------------------------------------

function Cli-ImplResult {
    param([string] $Impl, [string] $Status, [string] $Message)
    if (-not $Message) { $Message = '(no detail)' }
    return [pscustomobject]@{
        Impl = $Impl; Id = ''; Status = $Status; Message = $Message; Req = @('R9'); Evidence = ''
        Exit = $null; Calls = @(); CallsCwd = @(); Info = @(); Setup = @()
    }
}

# One runner's results into the list; a runner that throws becomes one FAIL
# for that implementation instead of taking the whole suite down with it.
function Cli-Collect {
    param([string] $Label, [scriptblock] $Run, [System.Collections.Generic.List[object]] $Into)
    try {
        foreach ($r in @(& $Run)) { if ($null -ne $r) { $Into.Add($r) } }
    }
    catch {
        $where = ($_.InvocationInfo.PositionMessage -replace "`r?`n", ' ')
        $Into.Add((Cli-ImplResult $Label 'FAIL' ("harness error: {0} at {1}" -f $_.Exception.Message, $where)))
    }
}

function Cli-Report {
    param($R)
    $id = "B-$($R.Impl)"
    if ($R.Id) { $id = "B-$($R.Impl)-$($R.Id)" }
    $msg = [string]$R.Message
    if (-not $msg) { $msg = '(no detail)' }
    $evidence = @()
    if ($R.Evidence) { $evidence = @([string]$R.Evidence) }
    Add-Result -Id $id -Status $R.Status -Message $msg -Req @($R.Req) -Evidence $evidence
}

function Cli-ResetDir {
    param([string] $Path)
    if ([System.IO.Directory]::Exists($Path)) { [System.IO.Directory]::Delete($Path, $true) }
    [void][System.IO.Directory]::CreateDirectory($Path)
}

# A path as Git Bash takes it on the command line: C:/x/y (a backslash path
# would reach `dirname` in ./dev whole, and come back as '.').
function Cli-ShPath {
    param([string] $Path)
    if ($IsWindows) { return $Path.Replace('\', '/') }
    return $Path
}

function Cli-ReadLines {
    param([string] $Path)
    if (-not [System.IO.File]::Exists($Path)) { return @() }
    return @([System.IO.File]::ReadAllText($Path).Replace("`r", '').Split([char[]]@([char]10)) | Where-Object { $_ -ne '' })
}

# The transcripts run-cli.sh wrote under <OutDir>/<id>/ as result objects, in
# the shape CliScen-Invoke returns. A scenario it should have run and did not
# is a FAIL; no transcripts at all is one FAIL (or BLOCKED, when docker itself
# refused to start the container) for the implementation.
function Cli-ReadTranscripts {
    param([string] $Impl, [string] $OutDir, [object[]] $Scenarios, [string[]] $Only = @(), $Run, [string] $Log = '', [switch] $ViaDockerRun)
    $list = [System.Collections.Generic.List[object]]::new()
    $missing = [System.Collections.Generic.List[string]]::new()
    foreach ($s in $Scenarios) {
        if (-not (CliScen-Applies -Impl $Impl -Scenario $s -Only $Only)) { continue }
        $d = [System.IO.Path]::Combine($OutDir, $s.Id)
        $vf = [System.IO.Path]::Combine($d, 'verdict')
        if (-not [System.IO.File]::Exists($vf)) { $missing.Add($s.Id); continue }
        $v = [System.IO.File]::ReadAllText($vf).TrimEnd([char[]]@([char]13, [char]10))
        $parts = $v.Split([char[]]@([char]9), 2)
        $status = $parts[0]
        $msg = ''
        if ($parts.Count -gt 1) { $msg = $parts[1] }
        if ($status -notin @('PASS', 'FAIL', 'SKIP', 'BLOCKED', 'WARN', 'INFO')) { $msg = "unreadable verdict '$v'"; $status = 'FAIL' }
        $exit = $null
        $ef = [System.IO.Path]::Combine($d, 'exit')
        if ([System.IO.File]::Exists($ef)) {
            $n = 0
            if ([int]::TryParse([System.IO.File]::ReadAllText($ef).Trim(), [ref] $n)) { $exit = $n }
        }
        $list.Add([pscustomobject]@{
                Impl = $Impl; Id = $s.Id; Status = $status; Message = $msg; Req = @($s.Req); Evidence = $d
                Exit = $exit
                Calls = @(Cli-ReadLines ([System.IO.Path]::Combine($d, 'calls')))
                CallsCwd = @(Cli-ReadLines ([System.IO.Path]::Combine($d, 'calls.cwd')))
                Info = @(Cli-ReadLines ([System.IO.Path]::Combine($d, 'info')))
                Setup = @($s.Setup)
            })
    }
    $rc = -1
    $tail = ''
    if ($Run) {
        $rc = $Run.ExitCode
        $tail = (($Run.StdErr + ' ' + $Run.StdOut).Trim() -replace '\s+', ' ')
        if ($tail.Length -gt 400) { $tail = $tail.Substring(0, 400) + ' ...' }
    }
    if ($list.Count -eq 0 -and $missing.Count -gt 0) {
        $status = 'FAIL'
        if ($ViaDockerRun -and $rc -in @(125, 126, 127)) { $status = 'BLOCKED' }
        $r = Cli-ImplResult $Impl $status ("run-cli.sh wrote no transcripts (exit {0}): {1}" -f $rc, $tail)
        if ($Log) { $r.Evidence = $Log }
        return $r
    }
    foreach ($id in $missing) {
        $s = @($Scenarios | Where-Object { $_.Id -eq $id })[0]
        $list.Add([pscustomobject]@{
                Impl = $Impl; Id = $id; Status = 'FAIL'; Message = "run-cli.sh did not get to this scenario (exit $rc)"; Req = @($s.Req)
                Evidence = $Log; Exit = $null; Calls = @(); CallsCwd = @(); Info = @(); Setup = @($s.Setup)
            })
    }
    return $list.ToArray()
}

function Cli-RunShArgs {
    param([string] $Impl, [string] $RunCli, [string] $Out, [string[]] $Only, [string] $DevScript)
    $a = @($RunCli, '--check', '--impl', $Impl, '--out', $Out)
    $o = @($Only | Where-Object { $_ })
    if ($o.Count -gt 0) { $a += @('--only', ($o -join ',')) }
    if ($DevScript) { $a += @('--script', $DevScript) }
    return $a
}

# ---------------------------------------------------------------------------
# The ./dev runners
# ---------------------------------------------------------------------------

function Cli-RunHostSh {
    param([object[]] $Scenarios, [string] $OutRoot, [string[]] $Only = @(), [string] $DevScript = '')
    $h = Get-Harness
    $impl = 'sh'
    $runEnv = @{}
    if ($IsWindows) {
        $gb = CliScen-FindGitBash
        if (-not $gb) { return (Cli-ImplResult $impl 'SKIP' 'Git for Windows (<GitRoot>\bin\sh.exe from git --exec-path) not found; ./dev needs Git Bash on Windows') }
        $shell = $gb.Sh
        # Git's own tools first, as a Git Bash window has them.
        $runEnv['PATH'] = (@($gb.UsrBin) + @($gb.MingwBins) + @($env:PATH)) -join ';'
    }
    else {
        $shell = '/bin/sh'
    }
    $out = [System.IO.Path]::Combine($OutRoot, $impl)
    Cli-ResetDir $out
    $dev = ''
    if ($DevScript) { $dev = Cli-ShPath $DevScript }
    $a = Cli-RunShArgs -Impl $impl -RunCli (Cli-ShPath ([System.IO.Path]::Combine($h.TestRoot, 'cli', 'run-cli.sh'))) -Out (Cli-ShPath $out) -Only $Only -DevScript $dev
    $r = Invoke-Native -FilePath $shell -ArgumentList $a -Environment $runEnv -RemoveEnvironment @('MSYS_NO_PATHCONV', 'MSYS2_ARG_CONV_EXCL', 'BASH_ENV', 'ENV', 'CDPATH') -TimeoutSec 1800
    $log = Save-Evidence -Suite 'cli' -Name "run-cli-$impl-$([System.IO.Path]::GetFileName($OutRoot)).log" -Content ($r.StdOut + "`n--- stderr ---`n" + $r.StdErr)
    return (Cli-ReadTranscripts -Impl $impl -OutDir $out -Scenarios $Scenarios -Only $Only -Run $r -Log $log)
}

function Cli-RunInContainer {
    param([string] $Impl, [string] $Image, [object[]] $Scenarios, [string] $OutRoot, [string[]] $Only = @(), [string] $DevScript = '')
    $h = Get-Harness
    if (-not $h.Docker) { return (Cli-ImplResult $Impl 'SKIP' 'docker is not on PATH') }
    if (-not (Test-DockerAvailable)) { return (Cli-ImplResult $Impl 'SKIP' 'the docker daemon is not responding') }
    if ($Image -eq $script:DevImage) {
        if (-not (Ensure-DevImage)) { return (Cli-ImplResult $Impl 'BLOCKED' "could not build $Image (see commands.log)") }
    }
    else {
        $ins = Invoke-Docker @('image', 'inspect', $Image) -TimeoutSec 60
        if ($ins.ExitCode -ne 0) {
            # The dev stack runs webapp on this image, so it is normally
            # present; pulling it is the one network access this suite makes.
            $pull = Invoke-Docker @('pull', $Image) -TimeoutSec 900
            if ($pull.ExitCode -ne 0) { return (Cli-ImplResult $Impl 'BLOCKED' "$Image is not present and could not be pulled: $($pull.StdErr.Trim())") }
        }
    }
    $out = [System.IO.Path]::Combine($OutRoot, $Impl)
    Cli-ResetDir $out
    $extra = @('-v', "${out}:/out")
    # A Linux host's daemon writes as root into the bind mount; run as the
    # invoking user so the results stay removable. Docker Desktop maps
    # ownership itself.
    if ($IsLinux) {
        $u = Invoke-Native -FilePath 'id' -ArgumentList @('-u') -TimeoutSec 30 -Quiet
        $g = Invoke-Native -FilePath 'id' -ArgumentList @('-g') -TimeoutSec 30 -Quiet
        if ($u.ExitCode -eq 0 -and $g.ExitCode -eq 0) { $extra += @('--user', ('{0}:{1}' -f $u.StdOut.Trim(), $g.StdOut.Trim())) }
    }
    $dev = ''
    if ($DevScript) {
        $extra += @('-v', "${DevScript}:/hc-dev-under-test:ro")
        $dev = '/hc-dev-under-test'
    }
    # Everything interpolated here is a fixed word or a validated scenario id.
    $cmd = 'sh ' + ((Cli-RunShArgs -Impl $Impl -RunCli '/src/test/cli/run-cli.sh' -Out '/out' -Only $Only -DevScript $dev) -join ' ')
    $r = Invoke-InDevImage -Script $cmd -ExtraArgs $extra -Image $Image -TimeoutSec 900
    $log = Save-Evidence -Suite 'cli' -Name "run-cli-$Impl-$([System.IO.Path]::GetFileName($OutRoot)).log" -Content ($r.StdOut + "`n--- stderr ---`n" + $r.StdErr)
    return (Cli-ReadTranscripts -Impl $Impl -OutDir $out -Scenarios $Scenarios -Only $Only -Run $r -Log $log -ViaDockerRun)
}

# ./dev inside WSL, as a developer with a WSL checkout would run it. Opt-in:
# the default distribution is whatever the machine has, and starting WSL is
# slow.
function Cli-RunWsl {
    param([object[]] $Scenarios, [string] $OutRoot, [string[]] $Only = @())
    $h = Get-Harness
    if (-not $IsWindows) { return @() }
    if (-not $h.Options['WithWsl']) { return (Cli-ImplResult 'wsl' 'SKIP' 'WSL is exercised only with -WithWsl') }
    $wsl = [System.IO.Path]::Combine($env:SystemRoot, 'System32', 'wsl.exe')
    if (-not [System.IO.File]::Exists($wsl)) { return (Cli-ImplResult 'wsl' 'SKIP' 'wsl.exe not found') }
    $out = [System.IO.Path]::Combine($OutRoot, 'wsl')
    Cli-ResetDir $out
    $paths = @{}
    foreach ($k in @('RunCli', 'Out')) {
        $win = if ($k -eq 'RunCli') { [System.IO.Path]::Combine($h.TestRoot, 'cli', 'run-cli.sh') } else { $out }
        $c = Invoke-Native -FilePath $wsl -ArgumentList @('-e', 'wslpath', '-u', $win) -TimeoutSec 120 -Quiet
        if ($c.ExitCode -ne 0 -or -not $c.StdOut.Trim()) { return (Cli-ImplResult 'wsl' 'BLOCKED' "wslpath failed (exit $($c.ExitCode)): $($c.StdErr.Trim())") }
        $paths[$k] = $c.StdOut.Trim()
    }
    $a = @('-e', 'sh') + (Cli-RunShArgs -Impl 'wsl' -RunCli $paths['RunCli'] -Out $paths['Out'] -Only $Only -DevScript '')
    $r = Invoke-Native -FilePath $wsl -ArgumentList $a -TimeoutSec 1800
    $log = Save-Evidence -Suite 'cli' -Name "run-cli-wsl-$([System.IO.Path]::GetFileName($OutRoot)).log" -Content ($r.StdOut + "`n--- stderr ---`n" + $r.StdErr)
    return (Cli-ReadTranscripts -Impl 'wsl' -OutDir $out -Scenarios $Scenarios -Only $Only -Run $r -Log $log)
}

# ---------------------------------------------------------------------------
# B-MAP-01
# ---------------------------------------------------------------------------

function Cli-CheckFunctionMap {
    $h = Get-Harness
    $dev = [System.IO.Path]::Combine($h.InfraRoot, 'dev')
    $ps1 = [System.IO.Path]::Combine($h.InfraRoot, 'dev.ps1')
    $map = [System.IO.Path]::Combine($h.TestRoot, 'cli', 'function-map.txt')
    foreach ($f in @($dev, $ps1, $map)) {
        if (-not [System.IO.File]::Exists($f)) {
            Add-Result -Id 'B-MAP-01' -Status 'FAIL' -Message "missing $f" -Req @('R9')
            return
        }
    }
    $sh = @(foreach ($l in [System.IO.File]::ReadAllLines($dev)) {
            if ($l -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*(\{.*)?$') { $Matches[1] }
        })
    $sh = @($sh | Select-Object -Unique)
    # The parser, not a regex, for PowerShell: it knows what is a function
    # definition and what is text in a here-string.
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($ps1, [ref] $tokens, [ref] $errors)
    $ps = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name } | Select-Object -Unique)

    $left = [System.Collections.Generic.List[string]]::new()
    $right = [System.Collections.Generic.List[string]]::new()
    $problems = [System.Collections.Generic.List[string]]::new()
    if (@($errors).Count -gt 0) { $problems.Add("dev.ps1 has $(@($errors).Count) parse error(s)") }
    $n = 0
    foreach ($raw in [System.IO.File]::ReadAllLines($map)) {
        $n++
        $line = $raw
        $comment = ''
        $i = $line.IndexOf('#')
        if ($i -ge 0) { $comment = $line.Substring($i + 1); $line = $line.Substring(0, $i) }
        $line = $line -replace '\s', ''
        if (-not $line) { continue }
        $j = $line.IndexOf('=')
        if ($j -lt 0) { $problems.Add("line ${n}: no '='"); continue }
        $a = $line.Substring(0, $j)
        $b = $line.Substring($j + 1)
        if (-not $a -and -not $b) { $problems.Add("line ${n}: empty entry"); continue }
        if ((-not $a -or -not $b) -and $comment -notmatch '[A-Za-z]') { $problems.Add("line ${n}: one-sided entry without a reason") }
        if ($a) { $left.Add($a) }
        if ($b) { $right.Add($b) }
    }
    foreach ($f in $sh) { if ($left -cnotcontains $f) { $problems.Add("dev:$f is not in the map") } }
    foreach ($f in $ps) { if ($right -notcontains $f) { $problems.Add("dev.ps1:$f is not in the map") } }
    foreach ($f in $left) { if ($sh -cnotcontains $f) { $problems.Add("map:$f is not a function in dev") } }
    foreach ($f in $right) { if ($ps -notcontains $f) { $problems.Add("map:$f is not a function in dev.ps1") } }
    $ev = Save-Evidence -Suite 'cli' -Name 'function-map-check.txt' -Content (
        "dev: $($sh -join ' ')`ndev.ps1: $($ps -join ' ')`nproblems:`n$($problems -join "`n")`n")
    if ($problems.Count -eq 0) {
        Add-Result -Id 'B-MAP-01' -Status 'PASS' -Message ("all {0} dev and {1} dev.ps1 functions are paired in test/cli/function-map.txt" -f $sh.Count, $ps.Count) -Req @('R9') -Evidence @($ev)
    }
    else {
        Add-Result -Id 'B-MAP-01' -Status 'FAIL' -Message ("function-map.txt is out of step: " + ($problems -join '; ')) -Req @('R9') -Evidence @($ev)
    }
}

# ---------------------------------------------------------------------------
# Parity
# ---------------------------------------------------------------------------

function Cli-Signature {
    param($R)
    return ("exit=" + $R.Exit + "`n" + (@($R.CallsCwd | ForEach-Object { Cli-CallKey $_ }) -join "`n") + "`n==>`n" + (@($R.Info) -join "`n"))
}

# One "<cwd><TAB><argv>" line as parity compares it. The working directory is
# part of a call's behaviour only where docker reads files relative to it -
# compose's -f files, and .env - so for every other call it is left out.
# Windows PowerShell 5.1 started in a directory whose name holds [ or ] reads
# that name as a wildcard, cannot set its location there, and runs from
# $PSHOME: harmless for docker info, and no difference in what dev.ps1 does.
function Cli-CallKey {
    param([string] $Line)
    $p = $Line -split "`t", 2
    if ($p.Count -lt 2 -or $p[1] -match '^compose\b.* -f ') { return $Line }
    return "*`t" + $p[1]
}

function Cli-ShortSignature {
    param($R)
    $calls = @($R.CallsCwd | ForEach-Object { $_.Replace("`t", ' $ ') }) -join ' ; '
    $s = "exit $($R.Exit); calls [$calls]; ==> [$(@($R.Info) -join ' | ')]"
    if ($s.Length -gt 400) { $s = $s.Substring(0, 400) + ' ...' }
    return $s
}

function Cli-AddParity {
    param([object[]] $Scenarios, [object[]] $Results)
    foreach ($s in $Scenarios) {
        # Only runs that produced a transcript: a SKIP or BLOCKED says nothing
        # about behaviour, and neither does a sandbox that could not be built.
        $ran = @($Results | Where-Object { $_.Id -eq $s.Id -and $_.Status -in @('PASS', 'FAIL') -and $null -ne $_.Exit })
        $impls = @($ran | ForEach-Object { $_.Impl })
        if ($ran.Count -lt 2) {
            $why = 'no implementation ran it'
            if ($ran.Count -eq 1) { $why = "only $($impls[0]) ran it" }
            Add-Result -Id "B-PARITY-$($s.Id)" -Status 'SKIP' -Message "nothing to compare: $why" -Req @($s.Req)
            continue
        }
        $text = [System.Collections.Generic.List[string]]::new()
        foreach ($r in $ran) { $text.Add("== $($r.Impl) ($($r.Status))"); $text.Add((Cli-Signature $r)); $text.Add('') }
        $ev = Save-Evidence -Suite 'cli' -Name "parity/$($s.Id).txt" -Content ($text -join "`n")
        $groups = @($ran | Group-Object -Property { Cli-Signature $_ } -CaseSensitive)
        if ($groups.Count -eq 1) {
            $msg = "{0} agree: exit {1}, {2} docker call(s), {3} '==>' line(s)" -f ($impls -join ', '), $ran[0].Exit, @($ran[0].Calls).Count, @($ran[0].Info).Count
            Add-Result -Id "B-PARITY-$($s.Id)" -Status 'PASS' -Message $msg -Req @($s.Req) -Evidence @($ev)
        }
        else {
            $desc = @($groups | ForEach-Object { '[' + (@($_.Group | ForEach-Object { $_.Impl }) -join ', ') + ': ' + (Cli-ShortSignature $_.Group[0]) + ']' }) -join ' vs '
            Add-Result -Id "B-PARITY-$($s.Id)" -Status 'FAIL' -Message "the implementations disagree: $desc" -Req @($s.Req) -Evidence @($ev)
        }
    }
}
