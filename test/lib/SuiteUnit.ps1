# Suite C, "unit": dev-reload.sh taken apart, inside the dev image, with no
# stack running. Dot-sourced by test/run.ps1 after Harness.ps1; the entry
# point is Invoke-SuiteUnit, and every helper here is named Unit-*.
#
# Two container-side scripts do the work:
#
#   test/container/unit-dev-reload.sh     one function at a time: change
#                                         detection, the main class, the launch
#                                         command, the last-good snapshot,
#                                         resource pruning, settings, the
#                                         wrapper install, the Maven flags
#   test/container/unit-state-machine.sh  the real main loop against fake
#                                         mvnd/mvnw/java/curl - run twice,
#                                         once with each compiler, because the
#                                         two take different paths through it
#
# Both run in `docker run --rm --network none` of homecrew-dev-runtime:jdk25
# with this checkout read-only at /src (Invoke-InDevImage). That is the same
# dash, GNU find, flock and javap the real containers use, whatever the host
# is - a Windows host has none of them, and a Mac has the BSD ones, which
# behave differently in exactly the places dev-reload.sh depends on. Neither
# script can reach the network or write to your checkout.
#
# Everything a script prints is saved as evidence; its HCRESULT lines become
# the results. One more row per run (<label>-RUN) checks the run itself: a
# script that died half-way, or whose exit status disagrees with its own
# results, must not read as a clean pass just because the rows it DID print
# all passed.
#
# ASCII only, and nothing newer than Windows PowerShell 5.1 can parse: suite A
# parses every .ps1 here with 5.1.

# Which requirement a result is evidence for, by id prefix. C-WRAP is the
# wrapper-install race (R3) and C-MVN the lock flags on every Maven call (R4);
# everything else in this suite is launch parity (R6) or reload behaviour (R7).
function Unit-ReqFor {
    param([string] $Id)
    switch -Regex ($Id) {
        '^C-FP(-|$)'   { return @('R7') }
        '^C-GOOD(-|$)' { return @('R7') }
        '^C-RES(-|$)'  { return @('R7') }
        '^C-MC(-|$)'   { return @('R6') }
        '^C-LC(-|$)'   { return @('R6') }
        '^C-WRAP(-|$)' { return @('R3') }
        '^C-MVN(-|$)'  { return @('R4') }
    }
    return @('R6', 'R7')
}

# The state-machine script's ids, put under C-SM-<compiler>- so the two runs
# never share an id. It may already use C-SM-, SM- or no prefix at all; each
# is mapped once, never doubled.
function Unit-SmId {
    param([string] $Id, [string] $Compiler)
    $p = "C-SM-$Compiler-"
    if ($Id.StartsWith('C-SM-mvnd-') -or $Id.StartsWith('C-SM-mvnw-')) { return $Id }
    if ($Id.StartsWith('C-SM-')) { return $p + $Id.Substring(5) }
    if ($Id.StartsWith('SM-')) { return $p + $Id.Substring(3) }
    if ($Id.StartsWith('C-')) { return $p + $Id.Substring(2) }
    return $p + $Id
}

# Files a container would run that carry a CR. dash reads `set -eu\r` as an
# unknown option and every case would fail for a reason that has nothing to do
# with what it tests - so this is checked first, and said plainly.
function Unit-FilesWithCR {
    param([string[]] $RelPaths)
    $h = Get-Harness
    $bad = @()
    foreach ($rel in $RelPaths) {
        $p = Join-Path $h.InfraRoot $rel
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { continue }
        $bytes = [System.IO.File]::ReadAllBytes($p)
        if ([Array]::IndexOf($bytes, [byte]13) -ge 0) { $bad += $rel }
    }
    return $bad
}

# HCRESULT lines to results, one line at a time: each id gets its own
# requirements, and a line that Add-Result would reject (an unknown status, an
# empty message) becomes a FAIL that says so, rather than a harness error that
# takes the rest of the suite with it.
function Unit-ImportLines {
    param([AllowEmptyString()][string] $Text, [string] $SmCompiler = '', [string[]] $Evidence = @())
    $valid = @('PASS', 'FAIL', 'SKIP', 'BLOCKED', 'WARN', 'INFO', 'WEAK')
    $total = 0
    $failed = 0
    $malformed = 0
    foreach ($line in ($Text -split "`r?`n")) {
        if (-not $line.StartsWith("HCRESULT`t")) { continue }
        $c = $line -split "`t", 4
        if ($c.Count -lt 4) { $malformed++; continue }
        $id = $c[1].Trim()
        if (-not $id) { $id = 'UNNAMED' }
        if ($SmCompiler) { $id = Unit-SmId -Id $id -Compiler $SmCompiler }
        $status = $c[2].Trim().ToUpperInvariant()
        $msg = $c[3]
        if ($valid -notcontains $status) {
            $msg = "the script reported an unknown status '$($c[2])': $msg"
            $status = 'FAIL'
        }
        if (-not $msg.Trim()) { $msg = '(the script gave no message)' }
        $total += Import-HcResults -Text "HCRESULT`t$id`t$status`t$msg" -Req (Unit-ReqFor $id) -Evidence $Evidence
        if ($status -eq 'FAIL' -or $status -eq 'WEAK') { $failed++ }
    }
    return [pscustomobject]@{ Total = $total; Failed = $failed; Malformed = $malformed }
}

# Runs one container-side script in the dev image, saves everything it printed,
# imports its results, and adds the <Label>-RUN row about the run itself.
function Unit-RunContainerScript {
    param(
        [Parameter(Mandatory)][string] $ScriptName,
        [string[]] $Arguments = @(),
        [Parameter(Mandatory)][string] $Label,
        [Parameter(Mandatory)][string] $EvidenceName,
        [string] $SmCompiler = '',
        [int] $TimeoutSec = 2400
    )
    $h = Get-Harness
    $runId = "$Label-RUN"
    $req = @('R6', 'R7')
    $what = ((@($ScriptName) + @($Arguments)) -join ' ')

    $cr = @(Unit-FilesWithCR @("test/container/$ScriptName", 'test/container/lib.sh', 'dev-reload.sh'))
    if ($cr.Count -gt 0) {
        Add-Result -Id $runId -Status 'FAIL' -Req $req -Message ("not run: {0} {1} Windows (CRLF) line endings, which dash cannot run. Delete them and git checkout -- them again; .gitattributes then writes LF" -f ($cr -join ', '), $(if ($cr.Count -eq 1) { 'has' } else { 'have' }))
        return
    }

    # A name, so that a run the harness gives up on (a timeout, or Ctrl+C) can
    # be removed: killing the docker CLI does not stop the container it
    # started. Invoke-InDevImage removes it; hct-* is the prefix
    # Assert-DockerArgsSafe lets the harness remove.
    $name = ('hct-unit-{0}-{1}' -f $h.RunId, $Label).ToLowerInvariant()
    $cmd = ((@("sh /src/test/container/$ScriptName") + @($Arguments)) -join ' ')
    Write-Host "  running $what in $($script:DevImage) (a few minutes)..." -ForegroundColor DarkGray
    $r = Invoke-InDevImage -Script $cmd -Name $name -TimeoutSec $TimeoutSec

    $body = [System.Collections.Generic.List[string]]::new()
    $body.Add("# $($r.CommandLine)")
    $body.Add("# exit $($r.ExitCode)$(if ($r.TimedOut) { " - TIMED OUT after ${TimeoutSec}s, container removed" } else { '' })")
    $body.Add($r.StdOut)
    if ($r.StdErr) {
        $body.Add('# ---- stderr ----')
        $body.Add($r.StdErr)
    }
    $ev = Save-Evidence -Suite 'unit' -Name $EvidenceName -Content ($body -join "`n")

    $stats = Unit-ImportLines -Text $r.StdOut -SmCompiler $SmCompiler -Evidence @($ev)
    # The script's last line when it got to its end (hc_done in lib.sh). Both
    # scripts exit 1 for failed cases - and so does one that was stopped
    # half-way, whose later groups never printed anything.
    $done = $r.StdOut -match "(?m)^HCDONE`t"

    # What to quote when there are no results to explain a failure: docker's
    # own complaint if it made one, else the last thing the script said.
    $errLines = @(($r.StdErr -split "`r?`n") | Where-Object { $_.Trim() })
    $outLines = @(($r.StdOut -split "`r?`n") | Where-Object { $_.Trim() })
    $hint = '(no output)'
    if ($errLines.Count -gt 0) { $hint = $errLines[0] } elseif ($outLines.Count -gt 0) { $hint = $outLines[$outLines.Count - 1] }
    if ($hint.Length -gt 300) { $hint = $hint.Substring(0, 300) + '...' }

    if ($r.ExitCode -eq -2) {
        Add-Result -Id $runId -Status 'BLOCKED' -Req $req -Evidence @($ev) -Message "docker could not be started: $hint"
    }
    elseif ($r.TimedOut) {
        Add-Result -Id $runId -Status 'FAIL' -Req $req -Evidence @($ev) -Message "$what did not finish within ${TimeoutSec}s; the container was removed, and the $($stats.Total) results it printed before that are above"
    }
    elseif ($stats.Total -eq 0 -and $r.ExitCode -eq 125) {
        # 125 is docker run's own failure, before the script ever started:
        # on Docker Desktop usually a drive or folder that is not shared.
        Add-Result -Id $runId -Status 'BLOCKED' -Req $req -Evidence @($ev) -Message "docker run failed before $ScriptName started (exit 125): $hint"
    }
    elseif ($stats.Total -eq 0) {
        Add-Result -Id $runId -Status 'FAIL' -Req $req -Evidence @($ev) -Message "$what printed no results (exit $($r.ExitCode)): $hint"
    }
    elseif ($stats.Malformed -gt 0) {
        Add-Result -Id $runId -Status 'FAIL' -Req $req -Evidence @($ev) -Message "$what printed $($stats.Malformed) malformed HCRESULT line(s) - results were lost; see the evidence"
    }
    elseif (-not $done) {
        Add-Result -Id $runId -Status 'FAIL' -Req $req -Evidence @($ev) -Message "$what stopped before its end (exit $($r.ExitCode), no HCDONE line): the $($stats.Total) results above are all it printed, and later cases may be missing ($hint)"
    }
    elseif ($r.ExitCode -eq 0 -and $stats.Failed -gt 0) {
        Add-Result -Id $runId -Status 'FAIL' -Req $req -Evidence @($ev) -Message "$what exited 0 although $($stats.Failed) of its cases failed: its exit status cannot be trusted"
    }
    elseif ($r.ExitCode -ne 0 -and $stats.Failed -eq 0) {
        Add-Result -Id $runId -Status 'FAIL' -Req $req -Evidence @($ev) -Message "$what exited $($r.ExitCode) although none of its $($stats.Total) cases failed: it stopped abnormally ($hint)"
    }
    elseif ($r.ExitCode -ne 0 -and $r.ExitCode -ne 1) {
        Add-Result -Id $runId -Status 'FAIL' -Req $req -Evidence @($ev) -Message "$what exited $($r.ExitCode), not the 1 it uses for failed cases: it did not end normally ($hint)"
    }
    elseif ($stats.Failed -gt 0) {
        Add-Result -Id $runId -Status 'INFO' -Req $req -Evidence @($ev) -Message "$what ran to the end: $($stats.Total) results, $($stats.Failed) failed (listed above)"
    }
    else {
        Add-Result -Id $runId -Status 'PASS' -Req $req -Evidence @($ev) -Message "$what ran to the end: $($stats.Total) results, none failed"
    }
}

function Invoke-SuiteUnit {
    Enter-Suite 'unit' 'dev-reload.sh, function by function and as a state machine, in the dev image'
    $h = Get-Harness

    if (-not (Test-DockerAvailable)) {
        Add-Result -Id 'C-UNIT' -Status 'SKIP' -Req @('R6', 'R7') -Message "docker is not available (not on PATH, or 'docker info' fails): these tests run inside $($script:DevImage)"
        return
    }
    # Built here if it is missing: `docker run` of an absent local image would
    # otherwise try to PULL homecrew-dev-runtime:jdk25, which exists nowhere.
    if (-not (Ensure-DevImage)) {
        Add-Result -Id 'C-UNIT-IMAGE' -Status 'BLOCKED' -Req @('R6', 'R7') -Message "$($script:DevImage) is missing and 'docker build -f Dockerfile.dev .' failed (see commands.log) - most often no network for the eclipse-temurin base image"
        return
    }

    Unit-RunContainerScript -ScriptName 'unit-dev-reload.sh' -Label 'C-UNIT' -EvidenceName 'unit-dev-reload.log' -TimeoutSec 2400

    # Written separately; the suite runs it once it exists.
    $sm = Join-Path $h.TestRoot 'container/unit-state-machine.sh'
    foreach ($c in @('mvnd', 'mvnw')) {
        if (-not (Test-Path -LiteralPath $sm -PathType Leaf)) {
            Add-Result -Id "C-SM-$c-RUN" -Status 'SKIP' -Req @('R6', 'R7') -Message "test/container/unit-state-machine.sh is not present, so the state machine was not exercised with $c"
            continue
        }
        Unit-RunContainerScript -ScriptName 'unit-state-machine.sh' -Arguments @('--compiler', $c) -Label "C-SM-$c" -EvidenceName "unit-state-machine-$c.log" -SmCompiler $c -TimeoutSec 2400
    }
}
