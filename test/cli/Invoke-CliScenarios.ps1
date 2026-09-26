#Requires -Version 7.2
# Suite B (cli), the dev.ps1 half - plus ./dev under Git Bash on Windows: runs
# every scenario in test/cli/scenarios.tsv against a fake docker and checks
# each transcript against the table, exactly as test/cli/run-cli.sh does for
# ./dev under sh, dash and busybox.
#
# Implementations:
#
#   ps51     dev.ps1 under Windows PowerShell 5.1 (Windows only)
#   ps7      dev.ps1 under PowerShell 7 (the pwsh running this)
#   gitbash  ./dev under <GitRoot>\bin\sh.exe (Windows only), with GitRoot
#            found from `git --exec-path` - never `sh` or `bash` from PATH,
#            which can be WSL's bash.exe
#
# each started as its own process: `-NoLogo -NoProfile -NonInteractive
# -ExecutionPolicy Bypass -File <dev.ps1> <args>` for PowerShell, which is how
# a user runs it (and -NoProfile keeps a profile's `docker` alias out). The
# ps-hijack scenario is the one exception: it runs under -Command with a
# `docker` FUNCTION defined, which dev.ps1 must ignore.
#
# THE FAKE. On Windows every implementation calls one FakeDocker.exe, built at
# run time from test/cli/FakeDocker.cs by .NET Framework's csc.exe (or by
# Windows PowerShell 5.1's Add-Type): a real executable is the only thing that
# is launched the way docker.exe is. If it cannot be built or cannot run -
# AppLocker, WDAC and Smart App Control all block unsigned programs in %TEMP%
# on managed machines - every Windows implementation is BLOCKED, never quietly
# passed through a .cmd stand-in. Elsewhere pwsh runs dev.ps1 against
# test/cli/fake-docker.sh.
#
# SAFETY. A scenario that reached the REAL docker could run `compose up` or
# `down` on your stack. So before anything runs, each implementation proves
# with a probe that `docker` on its PATH is the fake, and that the no-docker
# PATH really has no docker on it; if either fails, the implementation (or
# the no-docker scenario) is BLOCKED instead of run.
#
# NORMALISATION. Every form the sandbox path takes - as created, as the fake
# saw it (8.3 names, /private/var on macOS), as Git Bash prints it (/tmp/...
# or /c/...) - is learned by the same probes and replaced by <ROOT>, <SIB> and
# <BASE>; CR and ANSI escapes are dropped. Transcripts go to
# <OutDir>/<impl>/<id>/ in the layout run-cli.sh uses, so SuiteCli compares
# all implementations the same way.
#
# TWO WAYS IN.
#
#   . test/cli/Invoke-CliScenarios.ps1
#
#       (test/lib/SuiteCli.ps1) defines the CliScen-* functions and does
#       nothing else. It must be dot-sourced, not run with &: the harness
#       functions it calls read $script:Hc, and a script started with & would
#       make its own scope the "script" scope they look in. For the same
#       reason it has no param() block and sets no variables at the top level
#       - dot-sourcing would otherwise overwrite the caller's.
#
#   pwsh -NoProfile -File test/cli/Invoke-CliScenarios.ps1 [-Implementations ps51,ps7,gitbash]
#        [-Only id,id] [-DevScript path] [-DevPs1 path] [-OutDir dir] [-KeepSandbox]
#
#       standalone, to debug one implementation: starts its own harness run
#       under test/results/, prints one line per scenario, exits 1 on a FAIL.
#
# ASCII only, like dev.ps1.

function CliScen-FakeKnobs {
    return @('FAKE_INFO_EXIT', 'FAKE_INFO_STDERR', 'FAKE_COMPOSE_VERSION', 'FAKE_VERSION_EXIT',
        'FAKE_VOLUME_CREATE_EXIT', 'FAKE_CONFIG_EXIT', 'FAKE_COMPOSE_EXIT', 'FAKE_COMPOSE_STDERR')
}

# ---------------------------------------------------------------------------
# The scenario table
# ---------------------------------------------------------------------------

function CliScen-ReadScenarios {
    param([Parameter(Mandatory)][string] $Path)
    $rows = [System.Collections.Generic.List[object]]::new()
    $n = 0
    foreach ($raw in [System.IO.File]::ReadAllLines($Path)) {
        $n++
        $line = $raw.TrimEnd("`r")
        if ($line.Trim() -eq '' -or $line.StartsWith('#')) { continue }
        $c = @($line.Split([char[]]@([char]9)))
        if ($c.Count -ne 10) { throw "scenarios.tsv:${n}: $($c.Count) columns, expected 10" }
        if ($c[0] -notmatch '^[A-Za-z0-9._-]+$') { throw "scenarios.tsv:${n}: bad id '$($c[0])'" }
        $argv = @()
        if ($c[1] -ne '-') { $argv = @($c[1].Split([char[]]@([char]32)) | Where-Object { $_ -ne '' }) }
        $setup = @()
        if ($c[2] -ne '-') { $setup = @($c[2].Split([char[]]@([char]44))) }
        $envMap = [ordered]@{}
        if ($c[3] -ne '-') {
            foreach ($kv in $c[3].Split([char[]]@([char]59))) {
                $i = $kv.IndexOf('=')
                if ($i -lt 1) { throw "scenarios.tsv:${n}: bad env entry '$kv'" }
                $k = $kv.Substring(0, $i)
                if ($k -cnotmatch '^FAKE_[A-Z0-9_]+$') { throw "scenarios.tsv:${n}: '$k' is not a FAKE_* knob" }
                $envMap[$k] = $kv.Substring($i + 1)
            }
        }
        $exit = 0
        if (-not [int]::TryParse($c[4], [ref] $exit)) { throw "scenarios.tsv:${n}: bad exit '$($c[4])'" }
        $calls = ''
        if ($c[5] -ne '-') { $calls = $c[5] }
        $info = ''
        if ($c[8] -ne '-') { $info = $c[8] }
        $rows.Add([pscustomobject]@{
                Id     = $c[0]
                Argv   = $argv
                Setup  = $setup
                Env    = $envMap
                Exit   = $exit
                Calls  = $calls
                Stderr = $c[6]
                Stdout = $c[7]
                Info   = $info
                Req    = @($c[9].Split([char[]]@([char]44)))
                Line   = $n
                Raw    = $line
            })
    }
    return $rows.ToArray()
}

function CliScen-IsPs { param([string] $Impl) return ($Impl -eq 'ps51' -or $Impl -eq 'ps7') }

# Whether an implementation runs a scenario at all: sh-only rows are ./dev's,
# ps-only rows dev.ps1's.
function CliScen-Applies {
    param([string] $Impl, $Scenario, [string[]] $Only = @())
    $setup = @($Scenario.Setup)
    $isPs = CliScen-IsPs $Impl
    if ($isPs -and $setup -contains 'sh-only') { return $false }
    if (-not $isPs -and $setup -contains 'ps-only') { return $false }
    $o = @($Only | Where-Object { $_ })
    if ($o.Count -gt 0 -and $o -notcontains $Scenario.Id) { return $false }
    return $true
}

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

function CliScen-WriteText {
    param([string] $Path, [AllowEmptyString()][string] $Text)
    [System.IO.File]::WriteAllText($Path, (Protect-Text $Text), [System.Text.UTF8Encoding]::new($false))
}

function CliScen-Lines {
    param([AllowEmptyString()][string[]] $Lines)
    $a = @($Lines)
    if ($a.Count -eq 0) { return '' }
    return (($a -join "`n") + "`n")
}

function CliScen-Dash {
    param([AllowEmptyString()][string] $Text)
    if ($Text) { return $Text }
    return '-'
}

function CliScen-ToCrlf {
    param([string] $Path)
    $in = [System.IO.File]::ReadAllBytes($Path)
    $out = [System.Collections.Generic.List[byte]]::new($in.Length + 64)
    for ($i = 0; $i -lt $in.Length; $i++) {
        if ($in[$i] -eq 10 -and ($i -eq 0 -or $in[$i - 1] -ne 13)) { $out.Add([byte]13) }
        $out.Add($in[$i])
    }
    [System.IO.File]::WriteAllBytes($Path, $out.ToArray())
}

function CliScen-AppendBytes {
    param([string] $Path, [byte[]] $Bytes)
    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Append)
    try { $fs.Write($Bytes, 0, $Bytes.Length) }
    finally { $fs.Dispose() }
}

function CliScen-Ps51Path {
    if (-not $IsWindows) { return '' }
    $p = [System.IO.Path]::Combine($env:SystemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe')
    if ([System.IO.File]::Exists($p)) { return $p }
    return ''
}

# 5.1 started from pwsh 7 would inherit pwsh's PSModulePath and try to load
# PowerShell 7's copies of the core modules. pwsh fixes that up only for
# powershell.exe run through its own native-command path, not for a process
# started with ProcessStartInfo, so it is set here.
function CliScen-Ps51ModulePath {
    return ([System.IO.Path]::Combine($env:ProgramFiles, 'WindowsPowerShell', 'Modules') + ';' +
        [System.IO.Path]::Combine($env:SystemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'Modules'))
}

# <GitRoot>\bin\sh.exe, with GitRoot the first ancestor of `git --exec-path`
# that has both bin\sh.exe and usr\bin (Git for Windows' layout). $null if
# there is none - notably everywhere but Windows.
function CliScen-FindGitBash {
    if (-not $IsWindows) { return $null }
    $h = Get-Harness
    if (-not $h.Git) { return $null }
    $r = Invoke-Native -FilePath $h.Git -ArgumentList @('--exec-path') -TimeoutSec 60 -Quiet
    if ($r.ExitCode -ne 0 -or -not $r.StdOut.Trim()) { return $null }
    $d = [System.IO.Path]::GetFullPath($r.StdOut.Trim())
    while ($d) {
        $sh = [System.IO.Path]::Combine($d, 'bin', 'sh.exe')
        if ([System.IO.File]::Exists($sh) -and [System.IO.Directory]::Exists([System.IO.Path]::Combine($d, 'usr', 'bin'))) {
            $mingw = @(foreach ($m in @('mingw64', 'clangarm64', 'ucrt64', 'mingw32')) {
                    $b = [System.IO.Path]::Combine($d, $m, 'bin')
                    if ([System.IO.Directory]::Exists($b)) { $b }
                })
            return [pscustomobject]@{ Root = $d; Sh = $sh; UsrBin = [System.IO.Path]::Combine($d, 'usr', 'bin'); MingwBins = $mingw }
        }
        $d = [System.IO.Path]::GetDirectoryName($d)
    }
    return $null
}

# ---------------------------------------------------------------------------
# The fake docker
# ---------------------------------------------------------------------------

function CliScen-CompileFake {
    param([string] $Source, [string] $Exe)
    $why = [System.Collections.Generic.List[string]]::new()
    $csc = [System.IO.Path]::Combine($env:WINDIR, 'Microsoft.NET', 'Framework64', 'v4.0.30319', 'csc.exe')
    if (-not [System.IO.File]::Exists($csc)) { $csc = [System.IO.Path]::Combine($env:WINDIR, 'Microsoft.NET', 'Framework', 'v4.0.30319', 'csc.exe') }
    if ([System.IO.File]::Exists($csc)) {
        $r = Invoke-Native -FilePath $csc -ArgumentList @('/nologo', '/target:exe', '/optimize+', ('/out:' + $Exe), $Source) -TimeoutSec 300 -Quiet
        if ($r.ExitCode -eq 0 -and [System.IO.File]::Exists($Exe)) { return [pscustomobject]@{ Ok = $true; How = 'csc.exe (.NET Framework 4)'; Reason = '' } }
        $why.Add(('csc.exe exit {0}: {1}' -f $r.ExitCode, (($r.StdOut + ' ' + $r.StdErr).Trim() -replace '\s+', ' ')))
    }
    else { $why.Add('no csc.exe under %WINDIR%\Microsoft.NET') }
    $ps51 = CliScen-Ps51Path
    if ($ps51) {
        $cmd = 'Add-Type -TypeDefinition ([System.IO.File]::ReadAllText(''' + $Source.Replace("'", "''") + ''')) -Language CSharp -OutputAssembly ''' +
            $Exe.Replace("'", "''") + ''' -OutputType ConsoleApplication'
        $r = Invoke-Native -FilePath $ps51 -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', $cmd) `
            -Environment @{ PSModulePath = (CliScen-Ps51ModulePath) } -TimeoutSec 300 -Quiet
        if ($r.ExitCode -eq 0 -and [System.IO.File]::Exists($Exe)) { return [pscustomobject]@{ Ok = $true; How = 'Add-Type (Windows PowerShell 5.1)'; Reason = '' } }
        $why.Add(('Add-Type exit {0}: {1}' -f $r.ExitCode, (($r.StdOut + ' ' + $r.StdErr).Trim() -replace '\s+', ' ')))
    }
    return [pscustomobject]@{ Ok = $false; How = ''; Reason = ($why -join '; ') }
}

# Builds the fake into <dir>\docker.exe (Windows) or <dir>/docker, and proves
# it runs. On Windows it tries %TEMP% first and then the results directory,
# since an application-control policy may allow one and not the other.
function CliScen-PrepareFake {
    param([string] $Base, [string] $InfraRoot, [string] $OutDir)
    $cli = [System.IO.Path]::Combine($InfraRoot, 'test', 'cli')
    $candidates = @([System.IO.Path]::Combine($Base, 'bin'))
    if ($IsWindows) { $candidates += [System.IO.Path]::Combine($OutDir, 'fakebin') }
    $why = [System.Collections.Generic.List[string]]::new()
    foreach ($bin in $candidates) {
        [void][System.IO.Directory]::CreateDirectory($bin)
        $how = 'fake-docker.sh'
        if ($IsWindows) {
            $exe = [System.IO.Path]::Combine($bin, 'docker.exe')
            $c = CliScen-CompileFake -Source ([System.IO.Path]::Combine($cli, 'FakeDocker.cs')) -Exe $exe
            if (-not $c.Ok) {
                return [pscustomobject]@{ Ok = $false; Status = 'BLOCKED'; Reason = "could not compile test/cli/FakeDocker.cs: $($c.Reason)"; Bin = ''; Exe = ''; How = '' }
            }
            $how = $c.How
        }
        else {
            $exe = [System.IO.Path]::Combine($bin, 'docker')
            [System.IO.File]::Copy([System.IO.Path]::Combine($cli, 'fake-docker.sh'), $exe, $true)
            $chmod = @(Get-Command chmod -CommandType Application -ErrorAction SilentlyContinue)
            if ($chmod.Count -eq 0) { return [pscustomobject]@{ Ok = $false; Status = 'BLOCKED'; Reason = 'chmod not found'; Bin = ''; Exe = ''; How = '' } }
            [void](Invoke-Native -FilePath $chmod[0].Source -ArgumentList @('755', $exe) -TimeoutSec 30 -Quiet)
        }
        $probeLog = [System.IO.Path]::Combine($Base, 'fake-probe.log')
        $p = Invoke-Native -FilePath $exe -ArgumentList @('__fake_probe') -Environment @{ FAKE_DOCKER_LOG = $probeLog } -TimeoutSec 60 -Quiet
        if ($p.ExitCode -eq 0 -and $p.StdOut.Trim() -eq 'fake-docker-probe') {
            return [pscustomobject]@{ Ok = $true; Status = 'READY'; Reason = ''; Bin = $bin; Exe = $exe; How = $how }
        }
        $why.Add(('{0}: exit {1}, {2}' -f $exe, $p.ExitCode, (($p.StdErr).Trim() -replace '\s+', ' ')))
    }
    return [pscustomobject]@{
        Ok = $false; Status = 'BLOCKED'; Bin = ''; Exe = ''; How = ''
        Reason = ('the fake docker was built but will not run here - on a managed machine AppLocker, WDAC or Smart App Control block unsigned programs: ' + ($why -join '; '))
    }
}

# ---------------------------------------------------------------------------
# Normalisation
# ---------------------------------------------------------------------------

# The replacements for one scenario: every learned form of the sandbox base,
# joined to the scenario's directory with either separator, longest first
# within <ROOT>, then <SIB>, then <BASE> (each contains the next).
function CliScen-Pairs {
    param([string[]] $Forms, [string] $Rel, [bool] $IgnoreCase)
    $opt = [System.Text.RegularExpressions.RegexOptions]::None
    if ($IgnoreCase) { $opt = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase }
    $roots = [System.Collections.Generic.List[string]]::new()
    $sibs = [System.Collections.Generic.List[string]]::new()
    $bases = [System.Collections.Generic.List[string]]::new()
    foreach ($f in @($Forms)) {
        if (-not $f) { continue }
        $b = $f.TrimEnd([char[]]@([char]92, [char]47))
        if (-not $b) { continue }
        $bases.Add($b)
        foreach ($sep in @('\', '/')) {
            $sib = $b + $sep + $Rel.Replace('/', $sep)
            $sibs.Add($sib)
            $roots.Add($sib + $sep + 'home-crew-infrastructure')
        }
    }
    $pairs = [System.Collections.Generic.List[object]]::new()
    foreach ($group in @(@{ To = '<ROOT>'; L = $roots }, @{ To = '<SIB>'; L = $sibs }, @{ To = '<BASE>'; L = $bases })) {
        foreach ($x in @($group.L | Select-Object -Unique | Sort-Object -Property Length -Descending)) {
            $pairs.Add([pscustomobject]@{ From = $x; To = $group.To; Options = $opt })
        }
    }
    return $pairs.ToArray()
}

function CliScen-Normalize {
    param([AllowEmptyString()][string] $Text, [object[]] $Pairs)
    if (-not $Text) { return '' }
    $t = $Text.Replace("`r", '')
    $t = [regex]::Replace($t, '\x1b\[[0-9;?]*[A-Za-z]', '')
    $t = $t.Replace([string][char]27, '')
    foreach ($p in @($Pairs)) {
        $t = [regex]::Replace($t, [regex]::Escape($p.From), $p.To, $p.Options)
    }
    return $t
}

# The fake's CALL records: argv (joined by one space), "cwd<TAB>argv" with the
# cwd normalised and '\' read as '/', and the two MSYS variables it saw.
# HIJACK lines come from the ps-hijack scenario's decoy function.
function CliScen-ReadCalls {
    param([string] $LogPath, [object[]] $Pairs)
    $calls = [System.Collections.Generic.List[string]]::new()
    $cwd = [System.Collections.Generic.List[string]]::new()
    $msys = [System.Collections.Generic.List[string]]::new()
    $hijack = 0
    $raw = ''
    if ([System.IO.File]::Exists($LogPath)) { $raw = [System.IO.File]::ReadAllText($LogPath, [System.Text.UTF8Encoding]::new($false)) }
    foreach ($line in $raw.Split([char[]]@([char]10))) {
        $l = $line.TrimEnd("`r")
        if ($l -eq 'HIJACK') { $hijack++; continue }
        if (-not $l.StartsWith("CALL`t")) { continue }
        $f = $l.Split([char[]]@([char]9), 5)
        if ($f.Count -lt 5) { continue }
        $argv = CliScen-Normalize ($f[4].Replace([string][char]0x1f, ' ')) $Pairs
        $dir = (CliScen-Normalize $f[1] $Pairs).Replace('\', '/')
        $calls.Add($argv)
        $cwd.Add($dir + "`t" + $argv)
        $msys.Add($f[2] + "`t" + $f[3])
    }
    return [pscustomobject]@{ Calls = $calls.ToArray(); CallsCwd = $cwd.ToArray(); Msys = $msys.ToArray(); Hijack = $hijack }
}

# ---------------------------------------------------------------------------
# Checks: the same rules as check_scenario in run-cli.sh
# ---------------------------------------------------------------------------

function CliScen-CheckPieces {
    param([AllowEmptyString()][string] $Text, [string] $Spec, [string] $Label, [System.Collections.Generic.List[string]] $Why)
    if ($Spec -eq '-') { return }
    $hay = $Text.Replace('\', '/')
    foreach ($piece in $Spec.Split([char[]]@([char]124))) {
        $p = $piece.Replace('\', '/')
        if ($p.StartsWith('!')) {
            $p = $p.Substring(1)
            if ($hay.Contains($p)) { $Why.Add("$Label must not contain '$p'") }
        }
        elseif (-not $hay.Contains($p)) { $Why.Add("$Label lacks '$p'") }
    }
}

function CliScen-Check {
    param($Scenario, [int] $Exit, $Calls, [string[]] $Info, [AllowEmptyString()][string] $Stdout,
        [AllowEmptyString()][string] $Stderr, [AllowEmptyString()][string] $StdoutRaw, [bool] $ExpectMsys)
    $s = $Scenario
    $why = [System.Collections.Generic.List[string]]::new()
    if ($Exit -ne $s.Exit) { $why.Add("exit $Exit, expected $($s.Exit)") }

    $got = CliScen-Dash (@($Calls.Calls) -join ';')
    $exp = CliScen-Dash $s.Calls
    if ($got -cne $exp) { $why.Add("docker calls [$got], expected [$exp]") }

    foreach ($c in @($Calls.CallsCwd)) {
        $parts = $c.Split([char[]]@([char]9), 2)
        if ($parts.Count -lt 2) { continue }
        if ($parts[1].StartsWith('compose -f ') -and $parts[0] -cne '<ROOT>') {
            $why.Add("compose ran in '$($parts[0])', not in <ROOT>")
            break
        }
    }

    $gotInfo = CliScen-Dash (@($Info) -join '|')
    $expInfo = CliScen-Dash $s.Info
    if ($gotInfo -cne $expInfo) { $why.Add("'==>' lines [$gotInfo], expected [$expInfo]") }

    if ($s.Stderr -eq '(empty)') {
        if (($Stderr -replace '\s', '') -ne '') {
            $first = @($Stderr.Split([char[]]@([char]10)) | Where-Object { $_.Trim() } | Select-Object -First 1)
            $show = ''
            if ($first.Count -gt 0) { $show = $first[0] }
            if ($show.Length -gt 160) { $show = $show.Substring(0, 160) }
            $why.Add("stderr is not empty: $show")
        }
    }
    elseif ($s.Stderr -ne '-') { CliScen-CheckPieces -Text $Stderr -Spec $s.Stderr -Label 'stderr' -Why $why }
    CliScen-CheckPieces -Text $Stdout -Spec $s.Stdout -Label 'stdout' -Why $why

    # Captured output is not a terminal: no colour may leak into it.
    if ($StdoutRaw.Contains([string][char]27)) { $why.Add('stdout carries ANSI escapes') }

    if ($ExpectMsys) {
        $m = @($Calls.Msys)
        if ($m.Count -eq 0 -or @($m | Where-Object { $_ -cne "1`t*" }).Count -gt 0) {
            $why.Add('not every docker call saw MSYS_NO_PATHCONV=1 and MSYS2_ARG_CONV_EXCL=*')
        }
    }
    if ($Calls.Hijack -gt 0) { $why.Add("the docker FUNCTION was called ($($Calls.Hijack)x) instead of the docker application") }
    # Unrolled on purpose: the caller wraps it in @(), and ', $array' would
    # make an empty list look like one reason.
    return $why.ToArray()
}

# ---------------------------------------------------------------------------
# One implementation: how to start it, and the probes that make it safe
# ---------------------------------------------------------------------------

function CliScen-NewContext {
    param([string] $Impl, [string] $Base, [string] $InfraRoot, [string] $OutDir, $Fake, [string] $DevScript, [string] $DevPs1)
    $isWin = [bool]$IsWindows
    $ps = [System.IO.Path]::PathSeparator
    $ctx = [pscustomobject]@{
        Impl = $Impl; Status = 'READY'; Reason = ''; Kind = ''; Exe = ''; PreArgs = @(); Base = $Base
        InfraRoot = $InfraRoot; OutDir = $OutDir; DevFile = ''; DevName = ''; PathNormal = ''; PathNoDocker = ''
        NoDockerBlocked = ''; ExtraEnv = @{}; BaseForms = [System.Collections.Generic.List[string]]::new(); IgnoreCase = $isWin
    }
    switch ($Impl) {
        'ps51' {
            if (-not $isWin) { $ctx.Status = 'SKIP'; $ctx.Reason = 'Windows PowerShell 5.1 exists on Windows only'; return $ctx }
            $ctx.Exe = CliScen-Ps51Path
            if (-not $ctx.Exe) { $ctx.Status = 'SKIP'; $ctx.Reason = 'powershell.exe (5.1) not found under %SystemRoot%'; return $ctx }
            $ctx.Kind = 'ps'
            $ctx.ExtraEnv = @{ PSModulePath = (CliScen-Ps51ModulePath) }
        }
        'ps7' {
            $name = 'pwsh'
            if ($isWin) { $name = 'pwsh.exe' }
            $ctx.Exe = [System.IO.Path]::Combine($PSHOME, $name)
            if (-not [System.IO.File]::Exists($ctx.Exe)) { $ctx.Status = 'SKIP'; $ctx.Reason = "no $name in $PSHOME"; return $ctx }
            $ctx.Kind = 'ps'
        }
        'gitbash' {
            if (-not $isWin) { $ctx.Status = 'SKIP'; $ctx.Reason = 'Git Bash is the Windows case; elsewhere the sh implementation covers ./dev'; return $ctx }
            $gb = CliScen-FindGitBash
            if (-not $gb) { $ctx.Status = 'SKIP'; $ctx.Reason = 'Git for Windows (<GitRoot>\bin\sh.exe from git --exec-path) not found'; return $ctx }
            $ctx.Exe = $gb.Sh
            $ctx.Kind = 'sh'
        }
        default { $ctx.Status = 'SKIP'; $ctx.Reason = "unknown implementation '$Impl'"; return $ctx }
    }
    if (-not $Fake.Ok) { $ctx.Status = $Fake.Status; $ctx.Reason = $Fake.Reason; return $ctx }

    if ($ctx.Kind -eq 'ps') {
        $ctx.PreArgs = @('-NoLogo', '-NoProfile', '-NonInteractive')
        if ($isWin) { $ctx.PreArgs += @('-ExecutionPolicy', 'Bypass') }
        $ctx.DevFile = $DevPs1
        $ctx.DevName = 'dev.ps1'
    }
    else {
        $ctx.DevFile = $DevScript
        $ctx.DevName = 'dev'
    }
    if (-not [System.IO.File]::Exists($ctx.DevFile)) { $ctx.Status = 'FAIL'; $ctx.Reason = "no such file: $($ctx.DevFile)"; return $ctx }

    # PATHs: the fake first, then everything else as it was; or, for the
    # no-docker scenarios, only what the launcher itself needs.
    $ctx.PathNormal = $Fake.Bin + $ps + $env:PATH
    $empty = [System.IO.Path]::Combine($Base, 'empty-bin')
    [void][System.IO.Directory]::CreateDirectory($empty)
    if ($ctx.Kind -eq 'ps') {
        $ctx.PathNoDocker = $empty
        if ($isWin) { $ctx.PathNoDocker = $empty + ';' + [System.IO.Path]::Combine($env:SystemRoot, 'System32') }
        foreach ($dir in $ctx.PathNoDocker.Split([char[]]@($ps))) {
            foreach ($n in @('docker', 'docker.exe', 'docker.cmd', 'docker.bat', 'docker.com', 'docker.ps1')) {
                if ([System.IO.File]::Exists([System.IO.Path]::Combine($dir, $n))) { $ctx.NoDockerBlocked = "a docker is still on the no-docker PATH: $([System.IO.Path]::Combine($dir, $n))" }
            }
        }
    }
    else {
        $gb = CliScen-FindGitBash
        $ctx.PathNoDocker = (@($gb.UsrBin) + @($gb.MingwBins) + @([System.IO.Path]::Combine($env:SystemRoot, 'System32'))) -join ';'
        $chk = Invoke-Native -FilePath $ctx.Exe -ArgumentList @('-c', 'command -v docker') -Environment @{ PATH = $ctx.PathNoDocker } `
            -RemoveEnvironment @('MSYS_NO_PATHCONV', 'MSYS2_ARG_CONV_EXCL', 'BASH_ENV', 'ENV', 'CDPATH') -TimeoutSec 60 -Quiet
        if ($chk.ExitCode -eq 0) { $ctx.NoDockerBlocked = "Git Bash still finds a docker on the no-docker PATH: $($chk.StdOut.Trim())" }
    }

    # The forms the sandbox path takes. As created; physically resolved
    # (macOS: /var is /private/var); and whatever the probes below report.
    $ctx.BaseForms.Add($Base)
    if (-not $isWin -and [System.IO.File]::Exists('/bin/sh')) {
        $pp = Invoke-Native -FilePath '/bin/sh' -ArgumentList @('-c', 'cd "$1" && pwd -P', 'sh', $Base) -TimeoutSec 30 -Quiet
        if ($pp.ExitCode -eq 0 -and $pp.StdOut.Trim()) { $ctx.BaseForms.Add($pp.StdOut.Trim()) }
    }

    # The probe: `docker` as this implementation resolves it must be the fake.
    $probeLog = [System.IO.Path]::Combine($Base, "probe-$Impl.log")
    [System.IO.File]::WriteAllText($probeLog, '')
    $probeEnv = @{ PATH = $ctx.PathNormal; FAKE_DOCKER_LOG = $probeLog }
    foreach ($k in $ctx.ExtraEnv.Keys) { $probeEnv[$k] = $ctx.ExtraEnv[$k] }
    $remove = @('MSYS_NO_PATHCONV', 'MSYS2_ARG_CONV_EXCL', 'BASH_ENV', 'ENV', 'CDPATH')
    if ($ctx.Kind -eq 'ps') {
        $cmd = 'Set-Location -LiteralPath ''' + $Base.Replace("'", "''") + '''; ' +
            '$c = @(Get-Command docker -CommandType Application -ErrorAction SilentlyContinue); ' +
            'if ($c.Count -eq 0) { exit 97 }; & $c[0].Source __fake_probe; exit $LASTEXITCODE'
        $p = Invoke-Native -FilePath $ctx.Exe -ArgumentList (@($ctx.PreArgs) + @('-Command', $cmd)) -WorkingDirectory $Base `
            -Environment $probeEnv -RemoveEnvironment $remove -TimeoutSec 120 -Quiet
        $lines = @($p.StdOut.Replace("`r", '').Split([char[]]@([char]10)) | Where-Object { $_ -ne '' })
        $ok = ($p.ExitCode -eq 0 -and $lines.Count -gt 0 -and $lines[$lines.Count - 1] -ceq 'fake-docker-probe')
    }
    else {
        $p = Invoke-Native -FilePath $ctx.Exe -ArgumentList @('-c', 'cd "$1" && pwd && docker __fake_probe', 'sh', $Base.Replace('\', '/')) `
            -WorkingDirectory $Base -Environment $probeEnv -RemoveEnvironment $remove -TimeoutSec 120 -Quiet
        $lines = @($p.StdOut.Replace("`r", '').Split([char[]]@([char]10)) | Where-Object { $_ -ne '' })
        $ok = ($p.ExitCode -eq 0 -and $lines.Count -ge 2 -and $lines[$lines.Count - 1] -ceq 'fake-docker-probe')
        # How Git Bash prints the sandbox: /tmp/... or /c/Users/...
        if ($ok) { $ctx.BaseForms.Add($lines[0]) }
    }
    if (-not $ok) {
        $ctx.Status = 'BLOCKED'
        $ctx.Reason = ('the {0} probe did not reach the fake docker (exit {1}): {2}' -f $Impl, $p.ExitCode, (($p.StdOut + ' ' + $p.StdErr).Trim() -replace '\s+', ' '))
        return $ctx
    }
    # How the fake itself saw the sandbox as its working directory.
    foreach ($l in [System.IO.File]::ReadAllLines($probeLog)) {
        if (-not $l.StartsWith("CALL`t")) { continue }
        $f = $l.Split([char[]]@([char]9))
        if ($f.Count -ge 2 -and $f[1]) { $ctx.BaseForms.Add($f[1]) }
    }
    return $ctx
}

# ---------------------------------------------------------------------------
# One scenario
# ---------------------------------------------------------------------------

function CliScen-BuildSandbox {
    param($Ctx, [string] $Sib)
    $root = [System.IO.Path]::Combine($Sib, 'home-crew-infrastructure')
    [void][System.IO.Directory]::CreateDirectory($root)
    [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::Combine($Sib, 'elsewhere'))
    [System.IO.File]::Copy($Ctx.DevFile, [System.IO.Path]::Combine($root, $Ctx.DevName), $true)
    foreach ($f in @('docker-compose.yml', 'compose.dev.yml', 'dev-reload.sh', 'webapp-dev.sh')) {
        $src = [System.IO.Path]::Combine($Ctx.InfraRoot, $f)
        if ([System.IO.File]::Exists($src)) { [System.IO.File]::Copy($src, [System.IO.Path]::Combine($root, $f), $true) }
    }
    [System.IO.File]::Copy([System.IO.Path]::Combine($Ctx.InfraRoot, 'test', 'fixtures', 'ci.env'), [System.IO.Path]::Combine($root, '.env'), $true)
    $ascii = [System.Text.Encoding]::ASCII
    foreach ($svc in @('service-discovery', 'config-server', 'api-gateway', 'auth-service', 'user-service', 'admin-service',
            'booking-service', 'worker-service', 'notification-service', 'payment-service', 'xp-service', 'assignment-service')) {
        $d = [System.IO.Path]::Combine($Sib, "home-crew-$svc")
        [void][System.IO.Directory]::CreateDirectory($d)
        [System.IO.File]::WriteAllBytes([System.IO.Path]::Combine($d, 'pom.xml'), $ascii.GetBytes("<project/>`n"))
        # LF bytes, always: a CRLF mvnw is itself a scenario.
        [System.IO.File]::WriteAllBytes([System.IO.Path]::Combine($d, 'mvnw'), $ascii.GetBytes("#!/bin/sh`necho fake mvnw`n"))
    }
    $w = [System.IO.Path]::Combine($Sib, 'home-crew-webapp')
    [void][System.IO.Directory]::CreateDirectory($w)
    [System.IO.File]::WriteAllBytes([System.IO.Path]::Combine($w, 'package.json'), $ascii.GetBytes("{}`n"))
}

function CliScen-Verdict {
    param($Result, [string] $Status, [string] $Message)
    if (-not $Message) { $Message = '(no detail)' }
    $Result.Status = $Status
    $Result.Message = $Message
    CliScen-WriteText ([System.IO.Path]::Combine($Result.Evidence, 'verdict')) ("$Status`t$Message`n")
    return $Result
}

function CliScen-RunOne {
    param($Ctx, $Scenario)
    $s = $Scenario
    $setup = @($s.Setup)
    $dsep = [string][System.IO.Path]::DirectorySeparatorChar
    $rel = "$($Ctx.Impl)/s/$($s.Id)"
    if ($setup -contains 'hostile-sp') { $rel += '/hc cli [x]' }
    elseif ($setup -contains 'hostile-u') { $rel += '/hc-' + [string][char]0x00E9 }
    $sib = [System.IO.Path]::Combine($Ctx.Base, $rel.Replace('/', $dsep))
    $root = [System.IO.Path]::Combine($sib, 'home-crew-infrastructure')
    $d = [System.IO.Path]::Combine($Ctx.OutDir, $Ctx.Impl, $s.Id)
    if ([System.IO.Directory]::Exists($d)) { [System.IO.Directory]::Delete($d, $true) }
    [void][System.IO.Directory]::CreateDirectory($d)
    $log = [System.IO.Path]::Combine($d, 'docker.log')
    [System.IO.File]::WriteAllText($log, '')
    CliScen-WriteText ([System.IO.Path]::Combine($d, 'scenario')) ($s.Raw + "`n")
    $result = [pscustomobject]@{
        Impl = $Ctx.Impl; Id = $s.Id; Status = 'FAIL'; Message = ''; Req = @($s.Req); Evidence = $d
        Exit = $null; Calls = @(); CallsCwd = @(); Info = @(); Setup = $setup
    }

    try { CliScen-BuildSandbox -Ctx $Ctx -Sib $sib }
    catch { return (CliScen-Verdict $result 'FAIL' "could not build the sandbox at ${sib}: $($_.Exception.Message)") }

    $noDocker = $false; $spring = $false; $cwdMode = 'elsewhere'; $expectMsys = $false; $hijack = $false
    $envFile = [System.IO.Path]::Combine($root, '.env')
    foreach ($flag in $setup) {
        switch -CaseSensitive ($flag) {
            'noenv' { [System.IO.File]::Delete($envFile) }
            'utf16env' {
                [System.IO.File]::WriteAllText($envFile, "POSTGRES_USER=homecrew`r`nPOSTGRES_PASSWORD=homecrew`r`nPOSTGRES_DB=homecrew`r`n",
                    [System.Text.UnicodeEncoding]::new($false, $true))
            }
            'crlfenv' { CliScen-ToCrlf $envFile }
            'latin1env' { CliScen-AppendBytes $envFile ([byte[]](@([System.Text.Encoding]::ASCII.GetBytes('HC_LATIN1=caf')) + @(0xE9, 0x0A))) }
            'missing-xp' { [System.IO.File]::Delete([System.IO.Path]::Combine($sib, 'home-crew-xp-service', 'pom.xml')) }
            'crlf-mvnw' { CliScen-ToCrlf ([System.IO.Path]::Combine($sib, 'home-crew-user-service', 'mvnw')) }
            'crlf-reload' { CliScen-ToCrlf ([System.IO.Path]::Combine($root, 'dev-reload.sh')) }
            'nodocker' { $noDocker = $true }
            'spring-profile' { $spring = $true }
            'cwd-root' { $cwdMode = 'root' }
            'cwd-sibling' { $cwdMode = 'sibling' }
            'expect-msys' { $expectMsys = $true }
            'hijack' { $hijack = $true }
            'hostile-sp' { }
            'hostile-u' { }
            'sh-only' { }
            'ps-only' { }
            default { return (CliScen-Verdict $result 'FAIL' "scenarios.tsv: unknown setup flag '$flag'") }
        }
    }
    if ($noDocker -and $Ctx.NoDockerBlocked) { return (CliScen-Verdict $result 'BLOCKED' "not run: $($Ctx.NoDockerBlocked)") }

    $isPs = ($Ctx.Kind -eq 'ps')
    $cwd = [System.IO.Path]::Combine($sib, 'elsewhere')
    $target = [System.IO.Path]::Combine($root, $Ctx.DevName)
    if (-not $isPs) { $target = $target.Replace('\', '/') }
    if ($cwdMode -eq 'root') {
        $cwd = $root
        $target = './dev'
        if ($isPs) { $target = '.' + $dsep + 'dev.ps1' }
    }
    elseif ($cwdMode -eq 'sibling') {
        $cwd = [System.IO.Path]::Combine($sib, 'home-crew-user-service')
        $target = '../home-crew-infrastructure/dev'
        if ($isPs) { $target = '..' + $dsep + 'home-crew-infrastructure' + $dsep + 'dev.ps1' }
    }

    $argv = @($s.Argv)
    if ($isPs -and $hijack) {
        $quoted = @($argv | ForEach-Object { "'" + ([string]$_).Replace("'", "''") + "'" }) -join ' '
        $cmd = 'function docker { Add-Content -LiteralPath $env:FAKE_DOCKER_LOG -Value HIJACK }; & ''' + $target.Replace("'", "''") + ''' ' + $quoted + '; exit $LASTEXITCODE'
        $argList = @($Ctx.PreArgs) + @('-Command', $cmd)
    }
    elseif ($isPs) { $argList = @($Ctx.PreArgs) + @('-File', $target) + $argv }
    else { $argList = @($target) + $argv }

    # Nothing from the caller may steer the run: the fake's knobs come from
    # the table only, and ./dev must set the MSYS variables itself.
    $envSet = @{ FAKE_DOCKER_LOG = $log }
    if ($noDocker) { $envSet['PATH'] = $Ctx.PathNoDocker } else { $envSet['PATH'] = $Ctx.PathNormal }
    foreach ($k in $Ctx.ExtraEnv.Keys) { $envSet[$k] = $Ctx.ExtraEnv[$k] }
    foreach ($k in $s.Env.Keys) { $envSet[$k] = [string]$s.Env[$k] }
    if ($spring) { $envSet['SPRING_PROFILES_ACTIVE'] = 'dev' }
    $remove = [System.Collections.Generic.List[string]]::new()
    foreach ($k in @(CliScen-FakeKnobs) + @('SPRING_PROFILES_ACTIVE', 'MSYS_NO_PATHCONV', 'MSYS2_ARG_CONV_EXCL', 'BASH_ENV', 'ENV', 'CDPATH')) {
        if (-not $envSet.ContainsKey($k)) { $remove.Add($k) }
    }

    $r = Invoke-Native -FilePath $Ctx.Exe -ArgumentList $argList -WorkingDirectory $cwd -Environment $envSet `
        -RemoveEnvironment $remove.ToArray() -TimeoutSec 120 -Quiet
    $exit = [int]$r.ExitCode
    $result.Exit = $exit
    CliScen-WriteText ([System.IO.Path]::Combine($d, 'exit')) ("$exit`n")
    CliScen-WriteText ([System.IO.Path]::Combine($d, 'stdout.raw')) $r.StdOut
    CliScen-WriteText ([System.IO.Path]::Combine($d, 'stderr.raw')) $r.StdErr

    $pairs = CliScen-Pairs -Forms $Ctx.BaseForms.ToArray() -Rel $rel -IgnoreCase $Ctx.IgnoreCase
    $stdout = CliScen-Normalize $r.StdOut $pairs
    $stderr = CliScen-Normalize $r.StdErr $pairs
    $calls = CliScen-ReadCalls -LogPath $log -Pairs $pairs
    $info = @($stdout.Split([char[]]@([char]10)) | Where-Object { $_.StartsWith('==> ') })
    $result.Calls = @($calls.Calls)
    $result.CallsCwd = @($calls.CallsCwd)
    $result.Info = $info
    CliScen-WriteText ([System.IO.Path]::Combine($d, 'stdout')) $stdout
    CliScen-WriteText ([System.IO.Path]::Combine($d, 'stderr')) $stderr
    CliScen-WriteText ([System.IO.Path]::Combine($d, 'calls')) (CliScen-Lines $calls.Calls)
    CliScen-WriteText ([System.IO.Path]::Combine($d, 'calls.cwd')) (CliScen-Lines $calls.CallsCwd)
    CliScen-WriteText ([System.IO.Path]::Combine($d, 'info')) (CliScen-Lines $info)

    if ($r.TimedOut) { return (CliScen-Verdict $result 'FAIL' 'timed out after 120 s') }
    if ($exit -eq -2) { return (CliScen-Verdict $result 'FAIL' "could not start $($Ctx.Exe): $($r.StdErr)") }
    $why = @(CliScen-Check -Scenario $s -Exit $exit -Calls $calls -Info $info -Stdout $stdout -Stderr $stderr -StdoutRaw $r.StdOut -ExpectMsys $expectMsys)
    if ($why.Count -eq 0) {
        return (CliScen-Verdict $result 'PASS' ("exit {0}, {1} docker call(s) and the output as expected" -f $exit, @($calls.Calls).Count))
    }
    return (CliScen-Verdict $result 'FAIL' ($why -join '; '))
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

# Returns one object per (implementation, scenario) - Impl, Id, Status,
# Message, Req, Evidence, Exit, Calls, CallsCwd, Info, Setup - and one with an
# empty Id for an implementation that could not run at all (SKIP, BLOCKED).
function CliScen-Invoke {
    param(
        [Parameter(Mandatory)][string] $InfraRoot,
        [Parameter(Mandatory)][string] $OutDir,
        [object[]] $Scenarios = @(),
        [string[]] $Implementations = @(),
        [string[]] $Only = @(),
        [string] $DevScript = '',
        [string] $DevPs1 = '',
        [switch] $KeepSandbox
    )
    if (-not $DevScript) { $DevScript = [System.IO.Path]::Combine($InfraRoot, 'dev') }
    if (-not $DevPs1) { $DevPs1 = [System.IO.Path]::Combine($InfraRoot, 'dev.ps1') }
    $all = @($Scenarios)
    if ($all.Count -eq 0) { $all = @(CliScen-ReadScenarios ([System.IO.Path]::Combine($InfraRoot, 'test', 'cli', 'scenarios.tsv'))) }
    $impls = @($Implementations | Where-Object { $_ })
    if ($impls.Count -eq 0) {
        $impls = @('ps7')
        if ($IsWindows) { $impls = @('ps51', 'ps7', 'gitbash') }
    }
    [void][System.IO.Directory]::CreateDirectory($OutDir)

    $results = [System.Collections.Generic.List[object]]::new()
    $base = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'hc-cli-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    [void][System.IO.Directory]::CreateDirectory($base)
    try {
        $fake = CliScen-PrepareFake -Base $base -InfraRoot $InfraRoot -OutDir $OutDir
        foreach ($impl in $impls) {
            $ctx = CliScen-NewContext -Impl $impl -Base $base -InfraRoot $InfraRoot -OutDir $OutDir -Fake $fake -DevScript $DevScript -DevPs1 $DevPs1
            if ($ctx.Status -ne 'READY') {
                $results.Add([pscustomobject]@{
                        Impl = $impl; Id = ''; Status = $ctx.Status; Message = $ctx.Reason; Req = @('R9'); Evidence = ''
                        Exit = $null; Calls = @(); CallsCwd = @(); Info = @(); Setup = @()
                    })
                continue
            }
            foreach ($s in $all) {
                if (-not (CliScen-Applies -Impl $impl -Scenario $s -Only $Only)) { continue }
                $results.Add((CliScen-RunOne -Ctx $ctx -Scenario $s))
            }
        }
    }
    finally {
        # .NET, not Remove-Item: the hostile sandboxes have '[x]' in their
        # names, which -Path would read as a wildcard and quietly skip.
        if (-not $KeepSandbox) {
            try { [System.IO.Directory]::Delete($base, $true) }
            catch { Write-Warning "could not remove the CLI sandbox ${base}: $($_.Exception.Message)" }
        }
    }
    return $results.ToArray()
}

# ---------------------------------------------------------------------------
# Standalone
# ---------------------------------------------------------------------------

if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    $opt = @{ InfraRoot = ''; OutDir = ''; Implementations = @(); Only = @(); DevScript = ''; DevPs1 = ''; KeepSandbox = $false }
    $cliArgs = @($args)
    $i = 0
    while ($i -lt $cliArgs.Count) {
        $a = [string]$cliArgs[$i]
        $next = $null
        if ($i + 1 -lt $cliArgs.Count) { $next = $cliArgs[$i + 1] }
        if ($a -match '^-(InfraRoot|OutDir|DevScript|DevPs1)$') { $opt[$Matches[1]] = [string]$next; $i += 2 }
        elseif ($a -match '^-(Implementations|Only)$') {
            # "-Only a,b" arrives as one string under -File, as an array under &.
            $opt[$Matches[1]] = @(@($next) | ForEach-Object { ([string]$_).Split([char[]]@([char]44)) } | Where-Object { $_ })
            $i += 2
        }
        elseif ($a -eq '-KeepSandbox') { $opt.KeepSandbox = $true; $i++ }
        else { [Console]::Error.WriteLine("Invoke-CliScenarios.ps1: unknown argument '$a'"); exit 2 }
    }
    if (-not $opt.InfraRoot) { $opt.InfraRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
    . ([System.IO.Path]::Combine($opt.InfraRoot, 'test', 'lib', 'Harness.ps1'))
    [void](Initialize-Harness -InfraRoot $opt.InfraRoot -Options @{})
    if (-not $opt.OutDir) { $opt.OutDir = Get-EvidenceDir 'cli-standalone' }
    $res = @(CliScen-Invoke -InfraRoot (Get-Harness).InfraRoot -OutDir $opt.OutDir -Implementations $opt.Implementations -Only $opt.Only `
            -DevScript $opt.DevScript -DevPs1 $opt.DevPs1 -KeepSandbox:$opt.KeepSandbox)
    foreach ($r in $res) {
        $id = "B-$($r.Impl)"
        if ($r.Id) { $id = "B-$($r.Impl)-$($r.Id)" }
        Write-Host ('{0,-8} {1,-34} {2}' -f $r.Status, $id, $r.Message)
    }
    Write-Host "transcripts: $($opt.OutDir)"
    exit ([int](@($res | Where-Object { $_.Status -eq 'FAIL' }).Count -gt 0))
}
