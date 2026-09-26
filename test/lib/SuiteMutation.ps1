# Suite M, mutation: the key checks of the other suites, run where the fix
# they guard is ABSENT - against the baseline commit (test/baseline-refs.tsv,
# or -BaselineRef), or with the fix switched off - where each must FAIL.
# Loaded by test/run.ps1 after lib/Harness.ps1 and the other Suite*.ps1
# files; read Harness.ps1's CONVENTIONS first. Every helper here is named
# Mut-*. ASCII only, and nothing Windows PowerShell 5.1 cannot parse: suite A
# parses every .ps1 here with 5.1.
#
# WHY. A check that passes proves something only if it could have failed. The
# obvious ways to "test" these fixes would all pass on the unfixed setup:
# twelve unlocked cold builds rarely CORRUPT anything (the resolver renames
# downloads into place atomically; what they do is download the same jar
# twelve times), and a watcher test that only edits files never notices that
# deletions were invisible. So each key check is pointed at the regression
# and must catch it:
#
#   PASS   "the check detects the regression" - it fails without the fix,
#          and (where a control is run) passes with it
#   WEAK   "the check also passes without the fix" - it cannot tell the two
#          apart, whatever it said about the fixed setup
#   WARN   inconclusive because the check fails on the FIXED setup too; the
#          suite that owns the check reports that failure itself
#   FAIL   inconclusive for a reason that needs fixing (the mutated run broke
#          before it got to the point, or measured nothing)
#
#   M-PORTS  A-CFG-01a (every published port on 127.0.0.1) on the model
#            rendered from the baseline compose.dev.yml, the way A-CFG-05
#            renders it: at least one port must be on every interface.
#            Control: the current files, where none may be.
#   M-FP-<case>  unit-state-machine.sh's delete-file and backdated-edit cases
#            (suite C) run against the baseline dev-reload.sh, whose
#            `find -newer` watcher sees neither a deletion nor an edit with an
#            old mtime: both must FAIL, under mvnd and mvnw. Control: the same
#            cases against the current script, which must pass.
#   M-DOWNV  suite B's down-v scenario on the baseline dev.ps1 under Windows
#            PowerShell 5.1: its param() block bound -v to -Verbose, so the
#            fake docker must see `compose ... down` WITHOUT -v. Windows only.
#            Control: the current dev.ps1, whose call carries -v.
#   M-LOCKS  suite D's cold round (Conc-Invoke-ColdBuildRound) with the lock
#            replaced by Maven's default in-JVM one - rwlock-local with the gav
#            mapper, appended last to every build's arguments so it wins - on
#            an empty test volume: twelve builds must download at least one
#            artifact more than once. Whether unlocked builds collide is a
#            matter of timing, so a round without duplicates is run once more
#            before the check is called WEAK. The control is D-COLD itself.
#
# Everything runs in throwaway containers (--network none for the state
# machine) or in the isolated test project; nothing here touches your live
# stack, your Maven cache or your checkouts. The baseline files are taken with
# `git show` and written to this run's evidence directory; they are only ever
# read from there.

Set-StrictMode -Version 3.0

# Maven's own defaults for the named-lock factory and mapper: exclusion
# between the threads of ONE JVM, nothing across containers - the setup
# before the fix. Appended after dev-reload.sh's own flags (DEV_MAVEN_EXTRA_ARGS
# comes last on every Maven command line), and a later -D wins.
$script:MutUnlockedArgs = '-Daether.syncContext.named.factory=rwlock-local -Daether.syncContext.named.nameMapper=gav'

# Error lines that are the race itself showing, not the network: an unlocked
# round that fails with one of these has been caught just as surely as one
# that downloads a jar twice.
$script:MutRacePattern = 'Checksum validation failed|ZipException|invalid LOC header|error in opening zip|NoSuchFileException'

$script:MutFpCases = @('delete-file', 'backdated-edit')

function Invoke-SuiteMutation {
    Enter-Suite 'mutation' 'each key check where its fix is absent: it must fail there'
    $h = Get-Harness
    $ctx = [pscustomobject]@{
        Docker = $false; Ref = [string]$h.BaselineRef; RefOk = $false; RefWhy = ''; RefStatus = 'SKIP'
    }
    $ctx.Docker = Test-DockerAvailable
    if (-not $h.Git) { $ctx.RefWhy = 'git is not on PATH, so the baseline files cannot be read' }
    elseif (-not $ctx.Ref) { $ctx.RefWhy = 'no baseline commit is configured'; $ctx.RefStatus = 'FAIL' }
    else {
        $g = Invoke-Git $h.InfraRoot @('cat-file', '-e', "$($ctx.Ref)^{commit}")
        if ($g.ExitCode -eq 0) { $ctx.RefOk = $true }
        else {
            $ctx.RefWhy = "the baseline $($ctx.Ref) is not a commit in this clone (a shallow clone? git fetch --unshallow)"
            $ctx.RefStatus = 'BLOCKED'
        }
    }

    # Quickest first; the twelve cold builds last.
    Mut-Step -Id 'M-PORTS' -Req @('R11', 'R2') -Body { Mut-Ports $ctx }
    Mut-Step -Id 'M-DOWNV' -Req @('R9', 'R1') -Body { Mut-DownV $ctx }
    Mut-Step -Id 'M-FP' -Req @('R7') -Body { Mut-Fp $ctx }
    Mut-Step -Id 'M-LOCKS' -Req @('R4') -Body { Mut-Locks $ctx }
}

# ---------------------------------------------------------------------------
# M-PORTS
# ---------------------------------------------------------------------------

function Mut-Ports {
    param($Ctx)
    $id = 'M-PORTS'
    $req = @('R11', 'R2')
    if (-not $Ctx.Docker) { Mut-Add -Id $id -Status 'SKIP' -Req $req -Message 'docker is not available, so neither compose model can be rendered'; return }
    if (-not $Ctx.RefOk) { Mut-Add -Id $id -Status $Ctx.RefStatus -Req $req -Message $Ctx.RefWhy; return }

    $cur = Get-ComposeModel
    $b = Mut-GitShow -Ctx $Ctx -Path 'compose.dev.yml'
    if (-not $b.Ok) { Mut-Add -Id $id -Status 'FAIL' -Req $req -Message "inconclusive: $($b.Why)"; return }
    # GetFullPath: Save-Evidence joins 'ports/...' onto a Windows path, and
    # what reaches docker should not mix separators.
    $file = [System.IO.Path]::GetFullPath((Save-Evidence -Suite 'mutation' -Name 'ports/baseline-compose.dev.yml' -Content $b.Text))
    # As A-CFG-05 renders it: the second -f file resolves its relative paths
    # against the first one's directory, the infra root, so the copy in the
    # evidence directory renders as if it were in place. The baseline mounted
    # ${HOME}/.m2, so HOME is a dummy - your home directory stays out of the
    # evidence - and DOCKER_CONFIG keeps the docker CLI finding its compose
    # plugin, which it looks for under HOME on macOS and Linux.
    $dummyHome = [System.IO.Path]::GetFullPath((Join-Path (Get-EvidenceDir 'mutation') 'ports/dummy-home'))
    $dockerConfig = $env:DOCKER_CONFIG
    if (-not $dockerConfig) { $dockerConfig = Join-Path $HOME '.docker' }
    $old = Get-ComposeModel -Files @('docker-compose.yml', $file) -Environment @{ HOME = $dummyHome; DOCKER_CONFIG = $dockerConfig }

    $curScan = $null
    $oldScan = $null
    if ($cur) { $curScan = Mut-OffLoopback $cur }
    if ($old) { $oldScan = Mut-OffLoopback $old }
    $sb = [System.Text.StringBuilder]::new()
    foreach ($pair in @(@('current compose.dev.yml', $curScan), @("baseline $($Ctx.Ref) compose.dev.yml", $oldScan))) {
        [void]$sb.AppendLine("== $($pair[0])")
        if (-not $pair[1]) { [void]$sb.AppendLine('(did not render)'); continue }
        [void]$sb.AppendLine("$($pair[1].Total) published ports; not on 127.0.0.1:")
        foreach ($x in @($pair[1].Bad)) { [void]$sb.AppendLine("  $x") }
    }
    $ev = @((Save-Evidence -Suite 'mutation' -Name 'ports/ports.txt' -Content $sb.ToString()), $file)

    if (-not $old) { Mut-Add -Id $id -Status 'FAIL' -Req $req -Message "inconclusive: the baseline compose.dev.yml ($($Ctx.Ref)) did not render - see commands.log" -Evidence $ev; return }
    if (-not $cur) { Mut-Add -Id $id -Status 'FAIL' -Req $req -Message 'inconclusive: the current compose files did not render, so there is no control (see A-CFG-01)' -Evidence $ev; return }
    $oldBad = @($oldScan.Bad)
    $curBad = @($curScan.Bad)
    if ($oldBad.Count -eq 0) {
        Mut-Add -Id $id -Status 'WEAK' -Req $req -Message "the check also passes without the fix: every one of the $($oldScan.Total) ports the baseline publishes is on 127.0.0.1 already" -Evidence $ev
    }
    elseif ($curBad.Count -gt 0) {
        Mut-Add -Id $id -Status 'WARN' -Req $req -Message "inconclusive: the baseline publishes $($oldBad.Count) ports off 127.0.0.1, but so do the current files ($(Mut-Clip ($curBad -join ', ') 160)) - A-CFG-01a fails on the fix itself" -Evidence $ev
    }
    else {
        Mut-Add -Id $id -Status 'PASS' -Req $req -Message ("the check detects the regression: the baseline ({0}) publishes {1} of its {2} ports on every interface, e.g. {3} - while all {4} ports of the current files are on 127.0.0.1" -f $Ctx.Ref, $oldBad.Count, $oldScan.Total, (Mut-Clip (@($oldBad | Select-Object -First 3) -join ', ') 200), $curScan.Total) -Evidence $ev
    }
}

# Every published port of every service that is not bound to 127.0.0.1. A
# port without host_ip is on every interface, which is what the base file
# does.
function Mut-OffLoopback {
    param($Model)
    $bad = [System.Collections.Generic.List[string]]::new()
    $n = 0
    if ($Model.PSObject.Properties['services']) {
        foreach ($sp in $Model.services.PSObject.Properties) {
            $svc = $sp.Value
            if ($null -eq $svc -or -not $svc.PSObject.Properties['ports']) { continue }
            foreach ($p in @($svc.ports)) {
                if ($null -eq $p) { continue }
                $n++
                $ip = ''
                if ($p.PSObject.Properties['host_ip']) { $ip = [string]$p.host_ip }
                if ($ip -eq '127.0.0.1') { continue }
                $pub = ''
                if ($p.PSObject.Properties['published']) { $pub = [string]$p.published }
                $tgt = ''
                if ($p.PSObject.Properties['target']) { $tgt = [string]$p.target }
                $where = 'every interface'
                if ($ip) { $where = $ip }
                $bad.Add(('{0} {1}->{2} on {3}' -f $sp.Name, $pub, $tgt, $where))
            }
        }
    }
    return [pscustomobject]@{ Total = $n; Bad = $bad.ToArray() }
}

# ---------------------------------------------------------------------------
# M-FP
# ---------------------------------------------------------------------------

function Mut-Fp {
    param($Ctx)
    $h = Get-Harness
    $req = @('R7')
    $cases = @($script:MutFpCases)
    $sm = Join-Path $h.TestRoot 'container/unit-state-machine.sh'
    $skip = ''
    $status = 'SKIP'
    if (-not $Ctx.Docker) { $skip = "docker is not available: the state machine runs inside $($script:DevImage)" }
    elseif (-not (Test-Path -LiteralPath $sm -PathType Leaf)) { $skip = 'test/container/unit-state-machine.sh is not present' }
    elseif (-not $Ctx.RefOk) { $skip = $Ctx.RefWhy; $status = $Ctx.RefStatus }
    else {
        # dash reads `set -u\r` as an unknown option: every case would fail
        # for a reason that has nothing to do with the watcher.
        $cr = @(Mut-FilesWithCR @('test/container/unit-state-machine.sh', 'test/container/lib.sh', 'dev-reload.sh'))
        if ($cr.Count) { $skip = "not run: $($cr -join ', ') have Windows (CRLF) line endings, which dash cannot run - delete them and git checkout -- them again"; $status = 'FAIL' }
        elseif (-not (Ensure-DevImage)) { $skip = "$($script:DevImage) is missing and could not be built (see commands.log)"; $status = 'BLOCKED' }
    }
    if ($skip) {
        foreach ($c in $cases) { Mut-Add -Id "M-FP-$c" -Status $status -Req $req -Message $skip }
        return
    }
    $b = Mut-GitShow -Ctx $Ctx -Path 'dev-reload.sh'
    $problem = ''
    if (-not $b.Ok) { $problem = $b.Why }
    elseif ($b.Text.Contains("`r")) { $problem = "the baseline dev-reload.sh as git show printed it contains CR bytes, so dash would reject it for that alone" }
    if ($problem) {
        foreach ($c in $cases) { Mut-Add -Id "M-FP-$c" -Status 'FAIL' -Req $req -Message "inconclusive: $problem" }
        return
    }
    $file = [System.IO.Path]::GetFullPath((Save-Evidence -Suite 'mutation' -Name 'fp/baseline/dev-reload.sh' -Content $b.Text))
    $dir = [System.IO.Path]::GetDirectoryName($file)
    $only = $cases -join ','

    Mut-Say "M-FP: $only against the current dev-reload.sh (control), then against $($Ctx.Ref)'s - with mvnd and mvnw, a few minutes"
    $ctl = Mut-RunSm -Label 'control' -Arguments @('--only', $only)
    # Read-only, and the state machine copies it before adapting its APP line.
    $base = Mut-RunSm -Label 'baseline' -Arguments @('--script', '/hc-baseline/dev-reload.sh', '--only', $only) -ExtraArgs @('-v', "$($dir):/hc-baseline:ro")
    foreach ($c in $cases) { Mut-FpVerdict -Ctx $Ctx -Case $c -Control $ctl -Baseline $base -BaselineFile $file }
}

function Mut-FpVerdict {
    param($Ctx, [string] $Case, $Control, $Baseline, [string] $BaselineFile)
    $id = "M-FP-$Case"
    $req = @('R7')
    $sid = "C-SM-$Case"
    $ev = @($Baseline.Evidence, $Control.Evidence, $BaselineFile)
    $b = @($Baseline.Rows | Where-Object { $_.Id -eq $sid })
    $c = @($Control.Rows | Where-Object { $_.Id -eq $sid })
    if ($b.Count -eq 0) {
        $setup = @($Baseline.Rows | Where-Object { $_.Id -like 'C-SM-setup*' -and $_.Status -eq 'FAIL' } | ForEach-Object { $_.Message })
        $why = "the run against the baseline printed no $sid result (exit $($Baseline.ExitCode))"
        if ($setup.Count) { $why += ": $(Mut-Clip $setup[0] 200)" }
        elseif ($Baseline.TimedOut) { $why += ': it timed out' }
        else { $why += ": $($Baseline.Hint)" }
        $status = 'FAIL'
        if ($Baseline.ExitCode -eq 125 -or $Baseline.ExitCode -eq -2) { $status = 'BLOCKED' }
        Mut-Add -Id $id -Status $status -Req $req -Message "inconclusive: $why" -Evidence $ev
        return
    }
    # A case that never got as far as its edit - the old script did not even
    # boot in the fixture - failed, but not because of the regression.
    $bootRe = '^\[[A-Za-z0-9]+\] boot: '
    $passed = @($b | Where-Object { $_.Status -eq 'PASS' })
    $early = @($b | Where-Object { $_.Status -eq 'FAIL' -and $_.Message -match $bootRe })
    $other = @($b | Where-Object { $_.Status -ne 'PASS' -and $_.Status -ne 'FAIL' })
    $caught = @($b | Where-Object { $_.Status -eq 'FAIL' -and $_.Message -notmatch $bootRe })
    $ctlBad = @($c | Where-Object { $_.Status -ne 'PASS' })
    $show = @($caught | ForEach-Object { Mut-Clip $_.Message 160 }) -join '; '
    if ($passed.Count) {
        Mut-Add -Id $id -Status 'WEAK' -Req $req -Message ("the check also passes without the fix: against the baseline dev-reload.sh ({0}) {1} passed - {2}" -f $Ctx.Ref, $sid, (Mut-Clip (@($passed | ForEach-Object { $_.Message }) -join '; ') 300)) -Evidence $ev
    }
    elseif ($early.Count -or $other.Count) {
        $x = @($early) + @($other)
        Mut-Add -Id $id -Status 'FAIL' -Req $req -Message ("inconclusive: against the baseline the case did not get as far as its edit - {0}" -f (Mut-Clip (@($x | ForEach-Object { "$($_.Status) $($_.Message)" }) -join '; ') 300)) -Evidence $ev
    }
    elseif ($c.Count -eq 0 -or $ctlBad.Count) {
        $cs = 'no result'
        if ($ctlBad.Count) { $cs = Mut-Clip (@($ctlBad | ForEach-Object { "$($_.Status) $($_.Message)" }) -join '; ') 200 }
        Mut-Add -Id $id -Status 'WARN' -Req $req -Message "inconclusive: $sid fails against the baseline ($show), but the control run against the current dev-reload.sh did not pass either ($cs), so the failure does not single out the fix" -Evidence $ev
    }
    else {
        $comps = @($caught | ForEach-Object { $_.Compiler } | Where-Object { $_ }) -join ' and '
        if (-not $comps) { $comps = "$($caught.Count) run(s)" }
        Mut-Add -Id $id -Status 'PASS' -Req $req -Message ("the check detects the regression: against the baseline dev-reload.sh ({0}) {1} fails under {2} - {3} - while the current script passes it" -f $Ctx.Ref, $sid, $comps, (Mut-Clip $show 300)) -Evidence $ev
    }
}

# unit-state-machine.sh in `docker run --rm --network none` of the dev image,
# named hct-* so that one the harness gives up on can be removed (killing the
# docker CLI does not stop the container it started; Invoke-InDevImage removes
# it on a timeout or Ctrl+C).
function Mut-RunSm {
    param([Parameter(Mandatory)][string] $Label, [string[]] $Arguments = @(), [string[]] $ExtraArgs = @(), [int] $TimeoutSec = 1800)
    $h = Get-Harness
    $name = ('hct-mut-fp-{0}-{1}' -f $Label, $h.RunId).ToLowerInvariant()
    $cmd = ((@('sh /src/test/container/unit-state-machine.sh') + @($Arguments)) -join ' ')
    $r = Invoke-InDevImage -Script $cmd -Name $name -ExtraArgs $ExtraArgs -TimeoutSec $TimeoutSec
    $tail = ''
    if ($r.TimedOut) { $tail = " - TIMED OUT after ${TimeoutSec}s, container removed" }
    $ev = Save-Evidence -Suite 'mutation' -Name "fp/state-machine-$Label.log" -Content (
        "# $($r.CommandLine)`n# exit $($r.ExitCode)$tail`n$($r.StdOut)`n# ---- stderr ----`n$($r.StdErr)`n")
    $hint = Mut-FirstLine $r.StdErr
    if ($hint -eq '(no output)') { $hint = Mut-LastLine $r.StdOut }
    return [pscustomobject]@{ ExitCode = $r.ExitCode; TimedOut = $r.TimedOut; Rows = @(Mut-ParseHc $r.StdOut); Evidence = $ev; Hint = $hint }
}

# HCRESULT<TAB>id<TAB>status<TAB>message lines (test/container/lib.sh), NOT
# imported as results: here a FAIL is the expected outcome, and the verdict is
# this suite's to give. The state machine starts each message with the
# compiler in brackets.
function Mut-ParseHc {
    param([AllowNull()][AllowEmptyString()][string] $Text)
    $rows = [System.Collections.Generic.List[object]]::new()
    if (-not $Text) { return $rows.ToArray() }
    foreach ($line in ($Text -split "`r?`n")) {
        if (-not $line.StartsWith("HCRESULT`t")) { continue }
        $f = $line -split "`t", 4
        if ($f.Count -lt 4) { continue }
        $comp = ''
        if ($f[3] -match '^\[([A-Za-z0-9]+)\]') { $comp = $Matches[1] }
        $rows.Add([pscustomobject]@{ Id = $f[1].Trim(); Status = $f[2].Trim().ToUpperInvariant(); Message = $f[3]; Compiler = $comp })
    }
    return $rows.ToArray()
}

function Mut-FilesWithCR {
    param([string[]] $RelPaths)
    $h = Get-Harness
    $bad = @()
    foreach ($rel in $RelPaths) {
        $p = Join-Path $h.InfraRoot $rel
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { continue }
        if ([Array]::IndexOf([System.IO.File]::ReadAllBytes($p), [byte]13) -ge 0) { $bad += $rel }
    }
    return $bad
}

# ---------------------------------------------------------------------------
# M-DOWNV
# ---------------------------------------------------------------------------

function Mut-DownV {
    param($Ctx)
    $h = Get-Harness
    $id = 'M-DOWNV'
    $req = @('R9', 'R1')
    if (-not $h.OnWindows) {
        Mut-Add -Id $id -Status 'SKIP' -Req $req -Message 'Windows PowerShell 5.1 only, and it exists only on Windows: the regression - `.\dev.ps1 down -v` losing -v to -Verbose - is checked in the shell Windows users run dev.ps1 in'
        return
    }
    if (-not (Get-Command Invoke-CliScenarioSet -CommandType Function -ErrorAction SilentlyContinue)) {
        Mut-Add -Id $id -Status 'SKIP' -Req $req -Message 'lib/SuiteCli.ps1 (Invoke-CliScenarioSet) is not present'
        return
    }
    if (-not $Ctx.RefOk) { Mut-Add -Id $id -Status $Ctx.RefStatus -Req $req -Message $Ctx.RefWhy; return }
    $b = Mut-GitShow -Ctx $Ctx -Path 'dev.ps1'
    if (-not $b.Ok) { Mut-Add -Id $id -Status 'FAIL' -Req $req -Message "inconclusive: $($b.Why)"; return }
    $file = [System.IO.Path]::GetFullPath((Save-Evidence -Suite 'mutation' -Name 'downv/baseline/dev.ps1' -Content $b.Text))

    Mut-Say "M-DOWNV: suite B's down-v scenario under Windows PowerShell 5.1, with the current dev.ps1 (control) and $($Ctx.Ref)'s"
    $ctlRow = Mut-CliRow @(Invoke-CliScenarioSet -Only @('down-v') -Implementations @('ps51'))
    $baseRow = Mut-CliRow @(Invoke-CliScenarioSet -DevPs1 $file -Only @('down-v') -Implementations @('ps51'))
    $ev = @($file)
    foreach ($r in @($baseRow, $ctlRow)) { if ($r -and $r.Evidence) { $ev += [string]$r.Evidence } }

    if (-not $baseRow) { Mut-Add -Id $id -Status 'FAIL' -Req $req -Message 'inconclusive: Invoke-CliScenarioSet returned nothing for ps51 down-v' -Evidence $ev; return }
    if (-not $baseRow.Id) {
        # The implementation itself could not run: FakeDocker.exe blocked by
        # policy, no powershell.exe - its own status says which.
        $st = $baseRow.Status
        if ($st -notin @('SKIP', 'BLOCKED')) { $st = 'FAIL' }
        Mut-Add -Id $id -Status $st -Req $req -Message "ps51 could not run the scenario: $($baseRow.Message)" -Evidence $ev
        return
    }
    $bd = Mut-DownCall $baseRow
    $cd = $null
    if ($ctlRow -and $ctlRow.Id) { $cd = Mut-DownCall $ctlRow }
    if ($baseRow.Status -eq 'PASS') {
        Mut-Add -Id $id -Status 'WEAK' -Req $req -Message "the check also passes without the fix: the baseline dev.ps1 ($($Ctx.Ref)) passed B's down-v scenario under 5.1" -Evidence $ev
    }
    elseif (-not $bd) {
        Mut-Add -Id $id -Status 'FAIL' -Req $req -Message "inconclusive: the baseline dev.ps1 made no compose down call at all ($(Mut-Clip $baseRow.Message 240))" -Evidence $ev
    }
    elseif ($bd.HasV) {
        Mut-Add -Id $id -Status 'WARN' -Req $req -Message "inconclusive: the baseline passed -v through ('$($bd.Call)'), so the scenario failed for another reason: $(Mut-Clip $baseRow.Message 240)" -Evidence $ev
    }
    elseif (-not $ctlRow -or -not $ctlRow.Id -or $ctlRow.Status -ne 'PASS' -or -not $cd -or -not $cd.HasV) {
        $cs = 'did not run'
        if ($ctlRow) { $cs = "$($ctlRow.Status): $(Mut-Clip $ctlRow.Message 200)" }
        Mut-Add -Id $id -Status 'WARN' -Req $req -Message "inconclusive: the baseline lost -v ('$($bd.Call)'), but the control with the current dev.ps1 did not pass either ($cs)" -Evidence $ev
    }
    else {
        Mut-Add -Id $id -Status 'PASS' -Req $req -Message "the check detects the regression: under Windows PowerShell 5.1 the baseline dev.ps1 ($($Ctx.Ref)) turned 'down -v' into '$($bd.Call)' - no -v, so the volumes would survive - and B's down-v scenario fails on it, while the current dev.ps1 calls '$($cd.Call)'" -Evidence $ev
    }
}

# The ps51 row for down-v, or the implementation-level row (empty Id) that
# says why ps51 could not run at all. Cli-Collect labels a runner that threw
# with the runner's name, 'ps', rather than the implementation's.
function Mut-CliRow {
    param([object[]] $Results = @())
    $rows = @($Results | Where-Object { $_ -and $_.PSObject.Properties['Impl'] -and $_.PSObject.Properties['Id'] -and $_.Impl -in @('ps51', 'ps') })
    $hit = @($rows | Where-Object { $_.Impl -eq 'ps51' -and $_.Id -eq 'down-v' })
    if ($hit.Count) { return $hit[0] }
    $impl = @($rows | Where-Object { -not $_.Id })
    if ($impl.Count) { return $impl[0] }
    return $null
}

# The first `compose ... down ...` call the fake docker recorded, and whether
# -v or --volumes came after `down`.
function Mut-DownCall {
    param($Row)
    if (-not $Row -or -not $Row.PSObject.Properties['Calls']) { return $null }
    foreach ($call in @($Row.Calls)) {
        $t = @(([string]$call) -split ' ' | Where-Object { $_ })
        if ($t.Count -eq 0 -or $t[0] -ne 'compose') { continue }
        $i = [Array]::IndexOf([object[]]$t, [object]'down')
        if ($i -lt 0) { continue }
        $after = @()
        if ($i + 1 -lt $t.Count) { $after = @($t[($i + 1)..($t.Count - 1)]) }
        $v = @($after | Where-Object { $_ -ceq '-v' -or $_ -ceq '--volumes' })
        return [pscustomobject]@{ Call = [string]$call; HasV = ($v.Count -gt 0) }
    }
    return $null
}

# ---------------------------------------------------------------------------
# M-LOCKS
# ---------------------------------------------------------------------------

function Mut-Locks {
    param($Ctx)
    $h = Get-Harness
    $id = 'M-LOCKS'
    $req = @('R4')
    if (-not $Ctx.Docker) { Mut-Add -Id $id -Status 'SKIP' -Req $req -Message 'docker is not available, so no cold round can run'; return }
    if (-not (Get-Command Conc-Invoke-ColdBuildRound -CommandType Function -ErrorAction SilentlyContinue)) {
        Mut-Add -Id $id -Status 'SKIP' -Req $req -Message 'lib/SuiteConcurrency.ps1 (Conc-Invoke-ColdBuildRound) is not present'
        return
    }
    if (-not (Test-Path -LiteralPath (Join-Path $h.InfraRoot '.env') -PathType Leaf)) {
        Mut-Add -Id $id -Status 'SKIP' -Req $req -Message 'there is no .env, which compose needs to render the test project at all'
        return
    }
    # Twelve 1g containers, beside the dev stack if that is running.
    $live = Test-LiveStackRunning
    $need = 10GB
    if ($live) { $need = 20GB }
    $mem = Test-DockerMemory -NeedBytes $need
    if ($mem) {
        $hint = ''
        if ($live) { $hint = ' (your dev stack is running beside it; ./dev down frees its share)' }
        Mut-Add -Id $id -Status 'BLOCKED' -Req $req -Message "$mem$hint"
        return
    }

    # mvnw: always there (mvnd is installed non-fatally) and a separate JVM
    # per build, with the lock flags from MAVEN_ARGS first on its command line
    # and these after them.
    $rounds = [System.Collections.Generic.List[object]]::new()
    try {
        foreach ($i in 1..2) {
            Mut-Say "M-LOCKS: twelve cold builds on an empty test volume with $($script:MutUnlockedArgs) (attempt $i of 2; 5-20 min)"
            $round = Conc-Invoke-ColdBuildRound -Compiler 'mvnw' -ExtraArgs $script:MutUnlockedArgs -Label "mut-locks-$i" -Fresh -EvidenceSuite 'mutation'
            $rounds.Add($round)
            # Another attempt only when this one measured something and found
            # no collision: blocked, caught, or unmeasurable will not change.
            if ($round.Blocked -or $round.Duplicates -gt 0 -or @(Mut-RaceHits $round).Count -gt 0) { break }
            if ($round.StartedCount -eq 0 -or $round.Downloads -eq 0) { break }
        }
    }
    finally {
        if (-not (Mut-Opt 'KeepTestProject')) { Remove-TestProject | Out-Null }
    }

    $last = $rounds[$rounds.Count - 1]
    $ev = @($last.Evidence)
    $n = $rounds.Count
    $ctl = Mut-LockControl
    $race = @(Mut-RaceHits $last)
    $fails = @($last.Failures)
    if ($last.Blocked) {
        Mut-Add -Id $id -Status 'BLOCKED' -Req $req -Message "$($last.Blocked) - the unlocked round could not be judged" -Evidence $ev
    }
    elseif ($last.Duplicates -gt 0) {
        $top = @($last.DuplicateUrls | Select-Object -First 2 | ForEach-Object { "$($_.Url) x$($_.Count)" }) -join '; '
        Mut-Add -Id $id -Status 'PASS' -Req $req -Message ("the check detects the regression: with the cross-process lock replaced by rwlock-local/gav, {0} artifacts were downloaded more than once across the {1} cold builds (e.g. {2}), which D-COLD fails on{3}" -f $last.Duplicates, $last.ReadyCount, (Mut-Clip $top 240), $ctl) -Evidence $ev
    }
    elseif ($race.Count -gt 0) {
        Mut-Add -Id $id -Status 'PASS' -Req $req -Message ("the check detects the regression: with the cross-process lock replaced by rwlock-local/gav no jar was fetched twice, but the builds corrupted each other's downloads - {0} such error lines, first: {1} - which D-COLD fails on{2}" -f $race.Count, (Mut-Clip $race[0] 200), $ctl) -Evidence $ev
    }
    elseif ($last.StartedCount -eq 0) {
        Mut-Add -Id $id -Status 'FAIL' -Req $req -Message "inconclusive: the unlocked round did not start: $(Mut-Clip ($fails -join ' | ') 300)" -Evidence $ev
    }
    elseif ($last.Downloads -eq 0) {
        Mut-Add -Id $id -Status 'FAIL' -Req $req -Message "inconclusive: no 'Downloaded from' line in any of the $($last.StartedCount) logs, so duplicates cannot be counted (DEV_MAVEN_QUIET=0 not honoured?)" -Evidence $ev
    }
    elseif ($fails.Count -gt 0 -or -not $last.AllRcZero -or $last.ErrorHits.Count -gt 0) {
        $what = @()
        if ($fails.Count) { $what += $fails }
        if (-not $last.AllRcZero) { $what += ('exit codes: ' + (@($last.Services | Where-Object { $_.Rc -ne 0 } | ForEach-Object { "$($_.Name)=$($_.RcText)" }) -join ', ')) }
        if ($last.ErrorHits.Count) { $what += "first error line: $($last.ErrorHits[0])" }
        Mut-Add -Id $id -Status 'FAIL' -Req $req -Message "inconclusive: $n unlocked round(s) without a duplicate download, and the last did not complete cleanly either, so it says nothing about the lock: $(Mut-Clip ($what -join ' | ') 300)" -Evidence $ev
    }
    else {
        Mut-Add -Id $id -Status 'WEAK' -Req $req -Message ("the check also passes without the fix: in {0} unlocked cold round(s) no artifact was downloaded twice ({1} downloads of {2} URLs in the last). Unlocked cold builds did not happen to collide this time - the race depends on timing, so this shows the duplicate count CAN miss a missing lock, not that the lock is unneeded{3}" -f $n, $last.Downloads, $last.DistinctUrls, $ctl) -Evidence $ev
    }
}

function Mut-RaceHits {
    param($Round)
    return @(@($Round.ErrorHits) | Where-Object { $_ -match $script:MutRacePattern })
}

# The locked rounds of this run, if suite D ran: the other half of the
# comparison.
function Mut-LockControl {
    $rs = @((Get-Harness).Results | Where-Object { $_.Suite -eq 'concurrency' -and $_.Id -match '^D-COLD-(mvnd|mvnw)$' })
    if ($rs.Count -eq 0) { return '; D-COLD, the same round WITH the lock, did not run in this run' }
    return '; with the lock, this run has ' + (@($rs | ForEach-Object { "$($_.Id) $($_.Status)" }) -join ', ')
}

# ---------------------------------------------------------------------------
# Small things
# ---------------------------------------------------------------------------

# A baseline file as git has it. `git show <commit>:<path>` prints the blob
# itself - no checkout filter, no CRLF - and ProcessStartInfo reads it as
# UTF-8, so writing it back as UTF-8 is byte-exact for these ASCII files.
function Mut-GitShow {
    param([Parameter(Mandatory)] $Ctx, [Parameter(Mandatory)][string] $Path)
    $h = Get-Harness
    $g = Invoke-Git $h.InfraRoot @('show', "$($Ctx.Ref):$Path")
    if ($g.ExitCode -ne 0) { return [pscustomobject]@{ Ok = $false; Text = ''; Why = "git show $($Ctx.Ref):$Path failed: $(Mut-FirstLine $g.StdErr)" } }
    return [pscustomobject]@{ Ok = $true; Text = $g.StdOut; Why = '' }
}

# One failing check - or a harness bug in one - must not take the others with
# it; the error is a FAIL row that says where it happened.
function Mut-Step {
    param([Parameter(Mandatory)][string] $Id, [string[]] $Req = @(), [Parameter(Mandatory)][scriptblock] $Body)
    try { $null = & $Body }
    catch {
        $where = ''
        if ($_.InvocationInfo) { $where = ($_.InvocationInfo.PositionMessage -replace "`r?`n", ' ') }
        Mut-Add -Id "$Id-HARNESS-ERROR" -Status 'FAIL' -Req $Req -Message ('harness error: {0} {1}' -f $_.Exception.Message, $where)
    }
}

# Add-Result with the message redacted (summary.md is scanned for .env values
# at the end, and messages quote container output).
function Mut-Add {
    param(
        [Parameter(Mandatory)][string] $Id,
        [Parameter(Mandatory)][string] $Status,
        [Parameter(Mandatory)][AllowEmptyString()][string] $Message,
        [string[]] $Req = @(),
        [string[]] $Evidence = @()
    )
    if (-not $Message) { $Message = '(no detail)' }
    Add-Result -Id $Id -Status $Status -Message (Protect-Text $Message) -Req $Req -Evidence @($Evidence | Where-Object { $_ })
}

function Mut-Opt {
    param([Parameter(Mandatory)][string] $Name)
    $o = (Get-Harness).Options
    return [bool]($o -and $o.ContainsKey($Name) -and $o[$Name])
}

# Progress, not a verdict.
function Mut-Say {
    param([string] $Text)
    Write-Host "    $Text" -ForegroundColor DarkGray
}

function Mut-Clip {
    param([AllowNull()][AllowEmptyString()][string] $Text, [int] $Max = 200)
    if (-not $Text) { return '' }
    if ($Text.Length -le $Max) { return $Text }
    return $Text.Substring(0, $Max) + '...'
}

function Mut-FirstLine {
    param([AllowNull()][AllowEmptyString()][string] $Text)
    $l = @(($Text -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -First 1)
    if ($l.Count -eq 0) { return '(no output)' }
    return (Mut-Clip $l[0].Trim() 200)
}

function Mut-LastLine {
    param([AllowNull()][AllowEmptyString()][string] $Text)
    $l = @(($Text -split "`r?`n") | Where-Object { $_.Trim() })
    if ($l.Count -eq 0) { return '(no output)' }
    return (Mut-Clip $l[$l.Count - 1].Trim() 200)
}
