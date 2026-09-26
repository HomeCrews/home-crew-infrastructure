# Suite E, parity: every one of the twelve services launched twice in the
# isolated test project - OLD, the way the baseline dev-reload.sh did it
# (./mvnw spring-boot:run), and NEW, the way dev-reload.sh does it now (plain
# java) - and the two running JVMs compared property by property (R6; the
# debug-port check is R11 as well).
#
# WHY LIVE JVMs AND NOT SCRIPTS. The claim under test is "the application
# cannot tell the difference". Reading the two scripts side by side proves
# nothing about that: what matters is what each JVM actually received, which
# only the JVM can say. So test/container/capture-launch.sh asks the live
# process - jcmd VM.command_line / VM.system_properties / VM.flags and
# /proc/<pid> - and test/java/LaunchDiff.java compares the two captures.
#
# WHY THE BASELINE SCRIPT RUNS UNDER TODAY'S COMPOSE FILES. OLD and NEW differ
# in exactly one thing, the script that launches the JVM; the container
# around them is the same service definition. Differences that come from
# compose itself are suite A's (A-CFG-05), not this one's.
#
# WHY TWO CONTAINERS PER SERVICE, hct-old-<svc> and hct-new-<svc>, started
# with `compose run -T`: a fresh container for each, so neither launch finds
# the other's processes, and no TTY, so that "stderr is stdout" is something
# the launch did rather than something a terminal does to every process. The
# one visible cost, HOSTNAME, is whitelisted in test/parity/whitelist.txt.
#
# Everything runs in the homecrew-test project (test/compose.test.yml): its
# own network and volumes, checkouts mounted read-only, no host ports. Your
# live stack, its databases and your Maven cache are never touched, and the
# live stack does not have to be down.

# Long enough for the slowest OLD start on a warm Maven volume: mvnd compile,
# then spring-boot:run forking the lifecycle through test-compile, then boot.
$script:ParityStartTimeoutSec = 420
$script:ParityPollSec = 6
# Launched NEW twice. Whatever differs between two identical launches is
# noise by definition - the volatile set - and is ignored for all twelve.
# One servlet client and config-server, the one with the most unusual startup.
$script:ParityLearnFrom = @('config-server', 'user-service')
# The two services the rest depend on, and the only two whose test-project
# instance is running. It is stopped while their own OLD and NEW run: all
# three containers mount the same target/ volume, and two compilers writing
# one tree is exactly what the per-container target volumes exist to prevent.
# Started again, and waited for, before the next service.
$script:ParityGateways = @('service-discovery', 'config-server')
$script:ParityChecks = @('jvm-args', 'main', 'classpath', 'sysprops', 'env', 'cwd', 'exe', 'streams', 'nomaven', 'jdwp', 'sigign')
# Pinned to their defaults for every compose call in this suite: the knobs that
# change NEW but not OLD, and the profile the log checks expect. The shell
# environment wins over .env in compose's substitution, so your own tuning
# (DEV_OPTIMIZED_LAUNCH=false, a -o in DEV_MAVEN_EXTRA_ARGS, another profile)
# cannot read as a parity failure of the defaults. The same values for up and
# run also keep compose from recreating the gateways between the two.
$script:ParityEnv = @{ DEV_OPTIMIZED_LAUNCH = 'true'; DEV_MAVEN_EXTRA_ARGS = ''; DEV_COMPILER = 'auto'; SPRING_PROFILES_ACTIVE = 'container' }
# Keys the hashes capture-launch.sh puts in place of secret values; one per
# run, in memory only (see Parity-Capture).
$script:ParitySalt = ''

function Parity-Compose {
    param([Parameter(Mandatory)][string[]] $ComposeArgs, [int] $TimeoutSec = 900)
    return Invoke-TestCompose -ComposeArgs $ComposeArgs -TimeoutSec $TimeoutSec -Environment $script:ParityEnv
}

function Invoke-SuiteParity {
    Enter-Suite 'parity' 'direct java launch vs spring-boot:run, all twelve services'
    $h = Get-Harness
    $req = @('R6')

    if (-not (Test-DockerAvailable)) {
        Add-Result -Id 'E-PRE-docker' -Status 'SKIP' -Req $req -Message 'docker is not available here (not on PATH, or the daemon does not answer)'
        return
    }
    # config-server clones the private home-crew-config at startup and needs
    # ENCRYPT_KEY; without .env it cannot start, and then nothing else can.
    if (-not (Test-Path -LiteralPath (Join-Path $h.InfraRoot '.env') -PathType Leaf)) {
        Add-Result -Id 'E-PRE-env' -Status 'SKIP' -Req $req -Message '.env is missing, and config-server cannot start without its git credentials and ENCRYPT_KEY: copy .env.example to .env and fill it in'
        return
    }
    # postgres, kafka, service-discovery, config-server and one service under
    # test at a time: five containers, not the twelve Test-DockerMemory's
    # default is sized for - on top of what your live stack already uses. A
    # container's mem_limit does not stop the VM as a whole running out, and
    # its OOM killer then picks the largest process in ANY container: most
    # likely one of your live JVMs.
    $live = Test-LiveStackRunning
    [long] $liveBytes = 0
    if ($live) { $liveBytes = Get-LiveStackMemoryBytes }
    $mem = Test-DockerMemory -NeedBytes (5GB + $liveBytes)
    if ($mem) {
        if ($live) { $mem += ('. Your live stack is using {0:0.0} GB of that: stop it (./dev down) or give the VM more memory' -f ($liveBytes / 1GB)) }
        Add-Result -Id 'E-PRE-memory' -Status 'BLOCKED' -Req $req -Message $mem
        return
    }
    # Checks the rendered test model is isolated BEFORE anything is started
    # or emptied, builds the dev image if needed, and creates the test Maven
    # volume if it is missing - keeping it if it is already there, so a cache
    # an earlier suite left warm is reused.
    $why = Initialize-TestProject
    if ($why) {
        $st = if ($why -like 'test project is not isolated*') { 'FAIL' } else { 'BLOCKED' }
        Add-Result -Id 'E-PRE-project' -Status $st -Req $req -Message $why
        return
    }

    # Not a precondition - the test project publishes no ports, so the two
    # coexist - but they share the Docker VM's memory.
    if ($live) {
        Add-Result -Id 'E-PRE-live' -Status 'INFO' -Req $req -Message ('your live dev stack is running alongside the test project, using {0:0.0} GB, which the memory check counted; an OOM-killed launch here is BLOCKED, not FAIL' -f ($liveBytes / 1GB))
    }
    $pinned = @($script:ParityEnv.Keys | Sort-Object | ForEach-Object { "$_='$($script:ParityEnv[$_])'" })
    Add-Result -Id 'E-ENV' -Status 'INFO' -Req $req -Message "every compose call here pins $($pinned -join ', '), whatever .env or your shell says: parity is measured for the defaults"
    $script:ParitySalt = [Convert]::ToHexString([System.Security.Cryptography.RandomNumberGenerator]::GetBytes(16))

    $keep = [bool]($h.Options.ContainsKey('KeepTestProject') -and $h.Options['KeepTestProject'])
    $ev = Get-EvidenceDir 'parity'
    $ctx = [pscustomobject]@{
        Ev       = $ev
        # Read-only: the containers only read the baseline script and the
        # captures from here, and a root-owned file written into a Linux
        # host's results directory would outlive the run.
        Mount    = "$($ev):/out:ro"
        Captures = @{}    # "<svc>.<kind>" -> saved capture, for the diffs
        Logs     = @{}    # "<svc>.<kind>" -> container log of a launch that started
    }
    try {
        Parity-Run -Ctx $ctx
    }
    finally {
        Parity-RemoveContainers
        if ($keep) {
            Add-Result -Id 'E-KEEP' -Status 'INFO' -Req $req -Message 'the homecrew-test project was left running (-KeepTestProject)'
        }
        else {
            # The warm Maven cache stays for the suites after this one;
            # run.ps1 removes it at the very end.
            Remove-TestProject -KeepMavenVolume | Out-Null
        }
    }
}

function Parity-Run {
    param([Parameter(Mandatory)] $Ctx)
    $req = @('R6')

    # Fresh project volumes: an OLD run must not inherit target/ state a
    # previous harness run left, or the other way round. The Maven volume is
    # external, so `down -v` leaves it alone. Suites run one at a time, so any
    # hct-* container still here is a crashed run's, and it would keep the
    # test network busy and make `down` fail.
    Parity-RemoveContainers -All
    $down = Parity-Compose @('down', '-v', '--remove-orphans') -TimeoutSec 600
    if ($down.ExitCode -ne 0) {
        Add-Result -Id 'E-PRE-fresh' -Status 'FAIL' -Req $req -Message ("could not empty the test project first (exit {0}): {1}" -f $down.ExitCode, (Parity-Tail $down.StdErr))
        return
    }

    if (-not (Parity-SaveBaseline -Ctx $Ctx)) { return }

    $up = Parity-Compose @('up', '-d', '--wait', 'postgres', 'kafka', 'service-discovery', 'config-server') -TimeoutSec 1800
    if ($up.ExitCode -ne 0) {
        $text = $up.StdOut + "`n" + $up.StdErr + "`n" + (Parity-ProjectLogs)
        $p = Save-Evidence -Suite 'parity' -Name 'infra-up.txt' -Content $text
        # Maven Central or GitHub out of reach during the first cold start is
        # the network, not the dev setup.
        $c = Parity-Classify -Log $text -Default 'FAIL'
        Add-Result -Id 'E-PRE-infra' -Status $c.Status -Req $req -Message ("the test project's postgres, kafka, service-discovery and config-server did not come up healthy (exit {0}){1}: {2}" -f $up.ExitCode, $c.Note, (Parity-Tail $up.StdErr)) -Evidence @($p)
        return
    }
    Add-Result -Id 'E-PRE-infra' -Status 'PASS' -Req $req -Message 'postgres, kafka, service-discovery and config-server are up and healthy in homecrew-test'

    foreach ($s in Get-JavaServices) { Parity-MeasureService -Ctx $Ctx -Svc $s }

    # Only now: the volatile set is learned from two services and applied to
    # all twelve, including the ones measured before it existed.
    $volatile = Parity-LearnVolatile -Ctx $Ctx
    foreach ($s in Get-JavaServices) {
        Parity-Diff -Ctx $Ctx -Svc $s -VolatilePath $volatile
        Parity-CompareLogs -Ctx $Ctx -Svc $s
    }
}

# The baseline dev-reload.sh, byte for byte from git, with LF endings, next to
# the evidence. `git show <ref>:<path>` prints the blob without eol filters,
# so autocrlf cannot have touched it; the CRLF normalisation is belt and
# braces, because dash would choke on a \r in every line.
function Parity-SaveBaseline {
    param([Parameter(Mandatory)] $Ctx)
    $h = Get-Harness
    $req = @('R6')
    $ref = $h.BaselineRef
    $g = Invoke-Git -Repo $h.InfraRoot -GitArgs @('show', "$($ref):dev-reload.sh")
    if ($g.ExitCode -ne 0 -or -not $g.StdOut) {
        Add-Result -Id 'E-PRE-baseline' -Status 'FAIL' -Req $req -Message ("git show {0}:dev-reload.sh failed (exit {1}): {2}" -f $ref, $g.ExitCode, (Parity-Tail $g.StdErr))
        return $false
    }
    $text = $g.StdOut -replace "`r`n", "`n"
    # Guards against a -BaselineRef that points at the wrong thing: the
    # comparison is only meaningful if OLD really is a spring-boot:run launch
    # and really is not today's script.
    $current = [System.IO.File]::ReadAllText((Join-Path $h.InfraRoot 'dev-reload.sh')) -replace "`r`n", "`n"
    if (-not $text.StartsWith('#!/bin/sh') -or -not $text.Contains('spring-boot:run')) {
        Add-Result -Id 'E-PRE-baseline' -Status 'FAIL' -Req $req -Message "dev-reload.sh at $ref does not launch with spring-boot:run - wrong -BaselineRef?"
        return $false
    }
    if ($text -eq $current) {
        Add-Result -Id 'E-PRE-baseline' -Status 'FAIL' -Req $req -Message "dev-reload.sh at $ref is identical to today's, so there is nothing to compare - wrong -BaselineRef?"
        return $false
    }
    $path = Join-Path $Ctx.Ev 'baseline-dev-reload.sh'
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($text)
    [System.IO.File]::WriteAllBytes($path, $bytes)
    Add-Result -Id 'E-PRE-baseline' -Status 'PASS' -Req $req -Message ("OLD launches with dev-reload.sh from {0} ({1} bytes, sha256 {2})" -f $ref, $bytes.Length, (Get-Sha256Hex $bytes).Substring(0, 12)) -Evidence @($path)
    return $true
}

function Parity-MeasureService {
    param([Parameter(Mandatory)] $Ctx, [Parameter(Mandatory)] $Svc)
    $name = $Svc.Name
    $gate = $script:ParityGateways -contains $name
    $kinds = @('old', 'new')
    if ($script:ParityLearnFrom -contains $name) { $kinds += 'new2' }
    # Set on every normal way out. Ctrl+C or a harness error leaves it $false,
    # and then the gateways are NOT started again: two JVMs booted just for
    # Invoke-SuiteParity's Remove-TestProject to tear down would only hold the
    # abort up for minutes.
    $finished = $false
    try {
        if ($gate) {
            $st = Parity-Compose @('stop', $name) -TimeoutSec 180
            if ($st.ExitCode -ne 0) {
                Add-Result -Id "E-$name-stop" -Status 'FAIL' -Req @('R6') -Message ("could not stop the test project's {0} before measuring it (exit {1}): {2}" -f $name, $st.ExitCode, (Parity-Tail $st.StdErr))
                # It may still be running, on the same target volume as the
                # launches: two compilers on one tree, which the stop exists to
                # prevent. Nothing measured that way could be trusted.
                foreach ($k in $kinds) {
                    Add-Result -Id "E-$name-launch-$k" -Status 'BLOCKED' -Req @('R6') -Message "not measured: the test project's $name could not be stopped, and it shares this launch's target volume"
                }
                $finished = $true
                return
            }
        }
        foreach ($k in $kinds) { Parity-Launch -Ctx $Ctx -Svc $Svc -Kind $k }
        $finished = $true
    }
    finally {
        if ($gate -and $finished) {
            # BOTH gateways, not just this one: a compose `stop` of one service
            # can take the services that depend on it down too (config-server
            # depends on service-discovery), depending on the compose version.
            # `up --wait` on existing, unchanged containers is a start that
            # also waits for the healthchecks the next services depend on.
            $up = Parity-Compose (@('up', '-d', '--wait', '--no-deps') + $script:ParityGateways) -TimeoutSec 900
            if ($up.ExitCode -ne 0) {
                Add-Result -Id "E-$name-restart" -Status 'FAIL' -Req @('R6') -Message ("could not bring the test project's {0} back up after measuring {1} (exit {2}); the services measured after it will fail to import config or register: {3}" -f ($script:ParityGateways -join ' and '), $name, $up.ExitCode, (Parity-Tail $up.StdErr))
            }
        }
    }
}

# One launch: start the container, wait for the application, capture it,
# keep its log, remove the container.
function Parity-Launch {
    param([Parameter(Mandatory)] $Ctx, [Parameter(Mandatory)] $Svc, [Parameter(Mandatory)][string] $Kind)
    $name = $Svc.Name
    $container = "hct-$Kind-$name"
    $id = "E-$name-launch-$Kind"
    $req = @('R6')
    $what = switch ($Kind) {
        'old' { 'OLD (baseline dev-reload.sh, spring-boot:run)' }
        'new' { 'NEW (dev-reload.sh, java)' }
        default { 'NEW again (for the volatile set)' }
    }
    $simple = $Svc.Main.Substring($Svc.Main.LastIndexOf('.') + 1)

    # Left over from a crashed run, if anything.
    Invoke-Docker @('rm', '-f', $container) -TimeoutSec 120 | Out-Null

    # OLD replaces only the entrypoint, with the baseline script; NEW is the
    # service exactly as compose defines it, entrypoint included, and no
    # command - the stray script argument would otherwise reach dev-reload.sh.
    $runArgs = @('run', '-d', '--no-deps', '-T', '--name', $container, '-v', $Ctx.Mount)
    if ($Kind -eq 'old') { $runArgs += @('--entrypoint', 'sh', $name, '/out/baseline-dev-reload.sh') }
    else { $runArgs += @($name) }
    $r = Parity-Compose $runArgs -TimeoutSec 300
    if ($r.ExitCode -ne 0) {
        Add-Result -Id $id -Status 'FAIL' -Req $req -Message ("{0}: compose run failed (exit {1}): {2}" -f $what, $r.ExitCode, (Parity-Tail $r.StdErr))
        Invoke-Docker @('rm', '-f', $container) -TimeoutSec 120 | Out-Null
        return
    }
    try {
        $w = Parity-WaitForApp -Container $container -SimpleName $simple -Kind $Kind
        if (-not $w.Started) {
            $logPath = Save-Evidence -Suite 'parity' -Name "$name.$Kind.log" -Content $w.Log
            Add-Result -Id $id -Status $w.Status -Req $req -Message "${what}: $($w.Reason)" -Evidence @($logPath)
            return
        }
        $cap = Parity-Capture -Container $container -Main $Svc.Main
        # The log once more, after the capture, so it holds everything up to
        # the moment the JVM was measured.
        $log = Get-ContainerLog -Container $container
        $logPath = Save-Evidence -Suite 'parity' -Name "$name.$Kind.log" -Content $log
        $capPath = Save-Evidence -Suite 'parity' -Name "$name.$Kind" -Content $cap.StdOut
        $evidence = @($logPath, $capPath)
        if ($cap.StdErr.Trim()) { $evidence += Save-Evidence -Suite 'parity' -Name "$name.$Kind.stderr" -Content $cap.StdErr }
        $Ctx.Logs["$name.$Kind"] = $log
        $appPid = '?'
        if ($cap.StdOut -match '(?m)^==pid==\r?\n(\d+)') { $appPid = $Matches[1] }
        if ($cap.ExitCode -eq 0) {
            $Ctx.Captures["$name.$Kind"] = $capPath
            Add-Result -Id $id -Status $w.Status -Req $req -Message "${what}: $($w.Reason); application pid $appPid captured" -Evidence $evidence
        }
        elseif ($cap.ExitCode -eq 1 -and $cap.StdOut -match '(?m)^==main==\r?$') {
            # Partial: kept, and the checks that needed the missing part
            # fail in the diff with the reason. Only a capture that started
            # is partial - docker exec's own errors (the container stopped in
            # the meantime) exit 1 as well, with nothing captured.
            $Ctx.Captures["$name.$Kind"] = $capPath
            Add-Result -Id $id -Status 'WARN' -Req $req -Message "${what}: $($w.Reason); captured pid $appPid with gaps: $(Parity-Tail ((@($cap.StdOut -split "`r?`n") | Where-Object { $_ -like '!! *' }) -join '; '))" -Evidence $evidence
        }
        else {
            Add-Result -Id $id -Status 'FAIL' -Req $req -Message ("{0}: {1}, but capture-launch.sh captured nothing (exit {2}): {3}" -f $what, $w.Reason, $cap.ExitCode, (Parity-Tail $cap.StdErr)) -Evidence $evidence
        }
    }
    finally {
        Invoke-Docker @('rm', '-f', $container) -TimeoutSec 120 | Out-Null
    }
}

function Parity-WaitResult {
    param([bool] $Started, [string] $Status, [string] $Reason, [string] $Log)
    return [pscustomobject]@{ Started = $Started; Status = $Status; Reason = $Reason; Log = $Log }
}

# Up means Spring's own "Started <X> in" line. For NEW, dev-reload.sh's
# app-ready (its port answered) counts too, since that is the moment the
# script itself considers the application up - but Started is still given a
# little time, because it is what the capture should follow. Gives up early
# on what cannot recover by waiting.
function Parity-WaitForApp {
    param([Parameter(Mandatory)][string] $Container, [Parameter(Mandatory)][string] $SimpleName, [Parameter(Mandatory)][string] $Kind)
    $startedRx = 'Started ' + [regex]::Escape($SimpleName) + ' in '
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $readyAt = -1
    $oom = $false
    $oomNote = ' - a process in the container was OOM-killed at its mem_limit (DEV_SERVICE_MEM, 1g by default) on the way'
    while ($true) {
        # The two streams apart: docker cannot say how they interleave in
        # time, so the "last lines" come from stdout alone - Maven and the
        # application both log there - and the markers from both.
        $lr = Invoke-Docker @('logs', $Container) -TimeoutSec 120
        $log = $lr.StdOut + "`n" + $lr.StdErr
        $secs = [int]$sw.Elapsed.TotalSeconds
        $st = Invoke-Docker @('inspect', '-f', '{{.State.Status}} {{.State.ExitCode}} {{.State.OOMKilled}}', $Container) -TimeoutSec 60
        $f = @($st.StdOut.Trim() -split '\s+')
        $gone = ($st.ExitCode -ne 0 -or $f.Count -lt 3)
        # OOMKilled is set when ANY process in the container was killed, and
        # it stays set while the container runs on - with OLD most likely the
        # baseline's idle mvnd daemon, whose -Xmx320m mvnd overrides. So it is
        # remembered, and a verdict only if the application does not start.
        if (-not $gone -and $f[2] -eq 'true') { $oom = $true }
        $okStatus = if ($oom) { 'WARN' } else { 'PASS' }
        $note = if ($oom) { $oomNote } else { '' }

        if ($log -match $startedRx) {
            return (Parity-WaitResult $true $okStatus "Started $SimpleName after ${secs}s$note" $log)
        }
        if ($Kind -ne 'old' -and $log.Contains('[dev-reload] app-ready:')) {
            if ($readyAt -lt 0) { $readyAt = $secs }
            elseif ($secs - $readyAt -ge 30) {
                return (Parity-WaitResult $true $okStatus "[dev-reload] app-ready after ${readyAt}s (no Started line 30s later)$note" $log)
            }
        }
        $bad = Parity-FailureIn -Log $log -Kind $Kind
        if ($bad) {
            # A first compile, or a crash loop, that the network or the memory
            # limit caused is the environment, not the launch.
            if ($bad.Status -eq 'FAIL') {
                $c = Parity-Classify -Log $log -Default 'FAIL'
                if ($c.Status -eq 'BLOCKED') { $bad = [pscustomobject]@{ Status = 'BLOCKED'; Reason = $bad.Reason + $c.Note } }
                elseif ($oom) { $bad = [pscustomobject]@{ Status = 'BLOCKED'; Reason = $bad.Reason + $oomNote } }
            }
            return (Parity-WaitResult $false $bad.Status $bad.Reason $log)
        }
        if ($gone) {
            return (Parity-WaitResult $false 'FAIL' "the container disappeared after ${secs}s: $(Parity-Tail $st.StdErr)" $log)
        }
        if ($f[0] -ne 'running') {
            $c = Parity-Classify -Log $log -Default 'FAIL'
            if ($c.Status -eq 'FAIL' -and $oom) { $c = [pscustomobject]@{ Status = 'BLOCKED'; Note = "$oomNote - the environment, not the launch" } }
            return (Parity-WaitResult $false $c.Status "the container exited (status $($f[0]), exit $($f[1])) after ${secs}s, before the application started$($c.Note)" $log)
        }
        if ($secs -ge $script:ParityStartTimeoutSec) {
            $c = Parity-Classify -Log $log -Default 'FAIL'
            $tail = @($lr.StdOut.Trim() -split "`r?`n")
            if ($c.Status -eq 'FAIL' -and $oom) { $c = [pscustomobject]@{ Status = 'BLOCKED'; Note = $oomNote } }
            # spring-boot:run forks the lifecycle through test-compile, so on a
            # cold test Maven volume the first OLD launches also download every
            # test-scope dependency. Still downloading when time runs out is the
            # network's speed, not the launch.
            if ($c.Status -eq 'FAIL' -and ((@($tail | Select-Object -Last 30) -join "`n") -match 'Download(ing|ed) from ')) {
                $c = [pscustomobject]@{ Status = 'BLOCKED'; Note = ' - Maven was still downloading dependencies (a cold test Maven volume on a slow network)' }
            }
            # Before that, the baseline compiles once with -q, which prints
            # nothing, downloads included; spring-boot:run starts with
            # "Scanning for projects". Still in that first compile is the
            # baseline filling a cold cache, not the launch under test.
            elseif ($c.Status -eq 'FAIL' -and $Kind -eq 'old' -and -not $lr.StdOut.Contains('Scanning for projects')) {
                $c = [pscustomobject]@{ Status = 'BLOCKED'; Note = " - the baseline never got past its quiet (-q) first compile, which shows no downloads: most likely a cold test Maven volume" }
            }
            return (Parity-WaitResult $false $c.Status "no 'Started $SimpleName in' within $($script:ParityStartTimeoutSec)s$($c.Note); last line on stdout: $(Parity-Tail $tail[-1] 200)" $log)
        }
        Start-Sleep -Seconds $script:ParityPollSec
    }
}

function Parity-FailureIn {
    param([AllowEmptyString()][string] $Log, [string] $Kind)
    # The baseline runs ./mvnw rather than sh ./mvnw, after a chmod that the
    # read-only test mount refuses: a checkout without the exec bit cannot run
    # it here at all. Not the launch under test failing - the baseline cannot
    # be reproduced on this checkout.
    $m = [regex]::Match($Log, '[^\r\n]*mvnw: (Permission denied|not found)[^\r\n]*')
    if ($m.Success) {
        return [pscustomobject]@{ Status = 'BLOCKED'; Reason = "the checkout's mvnw cannot be executed directly in the container, which the baseline script needs: $(Parity-Tail $m.Value 250)" }
    }
    if ($Kind -eq 'old') {
        foreach ($marker in @('THE FIRST COMPILE FAILED', 'the application exited again after 5 restarts')) {
            if ($Log.Contains($marker)) { return [pscustomobject]@{ Status = 'FAIL'; Reason = "the baseline script reported: $marker" } }
        }
    }
    else {
        $m = [regex]::Match($Log, '\[dev-reload\] (fatal|launch-refused|main-class-error|restart-exhausted): [^\r\n]*')
        if ($m.Success) { return [pscustomobject]@{ Status = 'FAIL'; Reason = "dev-reload.sh reported: $(Parity-Tail $m.Value 250)" } }
    }
    return $null
}

# A start that failed because Maven Central or GitHub could not be reached is
# BLOCKED - the network - not a verdict on the launch.
function Parity-Classify {
    param([AllowEmptyString()][string] $Log, [string] $Default)
    $m = [regex]::Match($Log, '[^\r\n]*(Could not transfer artifact|Could not resolve host|Temporary failure in name resolution|UnknownHostException: (repo\.maven\.apache\.org|github\.com))[^\r\n]*')
    if ($m.Success) { return [pscustomobject]@{ Status = 'BLOCKED'; Note = " - a network failure: $(Parity-Tail $m.Value 200)" } }
    return [pscustomobject]@{ Status = $Default; Note = '' }
}

# capture-launch.sh exits 3 when not exactly one JVM runs the main class,
# which is also what a crash-restart in progress looks like: a few retries.
# HC_SALT keys its hashes of secret values. `-e HC_SALT` without a value makes
# docker take it from its own environment, so the salt never appears in an
# argument list, and so never in commands.log.
function Parity-Capture {
    param([Parameter(Mandatory)][string] $Container, [Parameter(Mandatory)][string] $Main)
    $r = $null
    for ($i = 1; $i -le 3; $i++) {
        $r = Invoke-Docker @('exec', '-e', 'HC_SALT', $Container, 'sh', '/test/container/capture-launch.sh', $Main) -Environment @{ HC_SALT = $script:ParitySalt } -TimeoutSec 180
        if ($r.ExitCode -ne 3) { break }
        Start-Sleep -Seconds 10
    }
    return $r
}

function Parity-LearnVolatile {
    param([Parameter(Mandatory)] $Ctx)
    $req = @('R6')
    $files = [System.Collections.Generic.List[string]]::new()
    $from = [System.Collections.Generic.List[string]]::new()
    foreach ($n in $script:ParityLearnFrom) {
        if ($Ctx.Captures.ContainsKey("$n.new") -and $Ctx.Captures.ContainsKey("$n.new2")) {
            $files.Add("/out/$n.new")
            $files.Add("/out/$n.new2")
            $from.Add($n)
        }
    }
    $text = "# nothing learned: no service had two NEW captures, so only the whitelist applies`n"
    $status = 'WARN'
    $msg = "no volatile set: neither of $($script:ParityLearnFrom -join ', ') was captured twice, so every difference not in the whitelist counts"
    if ($files.Count -gt 0) {
        $r = Invoke-InDevImage -Script ('java /src/test/java/LaunchDiff.java --learn ' + ($files -join ' ')) -ExtraArgs @('-v', $Ctx.Mount) -TimeoutSec 300
        if ($r.ExitCode -eq 0) {
            $text = $r.StdOut
            $lines = @($text -split "`r?`n")
            $keys = @($lines | Where-Object { $_ -and -not $_.StartsWith('#') } | ForEach-Object { (($_ -split '#')[0]).Trim() })
            # What --learn reported instead of learning: a pair it had to leave
            # out, and keys the launch decides, on which two NEW launches of
            # one service must never disagree.
            $skipped = @($lines | Where-Object { $_.StartsWith('# skipped ') } | ForEach-Object { $_.Substring(10) })
            $never = @($lines | Where-Object { $_.StartsWith('# NEVER-VOLATILE ') } | ForEach-Object { $_.Substring(17).Trim() })
            # Listed in the message, so that a reader sees at once if
            # something that matters (user.dir, say) was declared noise.
            $status = if ($from.Count -eq $script:ParityLearnFrom.Count -and $skipped.Count -eq 0) { 'INFO' } else { 'WARN' }
            $msg = "learned from two NEW launches of $($from -join ' and '): $(if ($keys.Count) { $keys -join ', ' } else { 'nothing differed' })"
            if ($skipped.Count) { $msg += "; left out: $($skipped -join '; ')" }
            if ($never.Count) {
                $status = 'FAIL'
                $msg = "two NEW launches of the same service disagree on what the launch decides, so NEW is not deterministic: $($never -join ', '). $msg"
            }
        }
        else {
            $msg = "LaunchDiff --learn failed (exit $($r.ExitCode)), so only the whitelist applies: $(Parity-Tail $r.StdErr)"
        }
    }
    $path = Save-Evidence -Suite 'parity' -Name 'volatile.txt' -Content $text
    Add-Result -Id 'E-VOLATILE' -Status $status -Req $req -Message $msg -Evidence @($path)
    return $path
}

function Parity-Diff {
    param([Parameter(Mandatory)] $Ctx, [Parameter(Mandatory)] $Svc, [string] $VolatilePath)
    $n = $Svc.Name
    $missing = @()
    if (-not $Ctx.Captures.ContainsKey("$n.old")) { $missing += 'OLD' }
    if (-not $Ctx.Captures.ContainsKey("$n.new")) { $missing += 'NEW' }
    if ($missing.Count) {
        Add-Result -Id "E-$n-compare" -Status 'SKIP' -Req @('R6', 'R11') -Message "not compared ($($script:ParityChecks -join ', ')): the $($missing -join ' and ') launch was not captured - see E-$n-launch-*"
        return
    }
    # In the dev image, with the test Maven volume where the JVMs found their
    # jars: the classpath check opens each NEW-only jar to read its manifest.
    $cmd = "java /src/test/java/LaunchDiff.java /out/$n.old /out/$n.new /src/test/parity/whitelist.txt /out/volatile.txt $n"
    $r = Invoke-InDevImage -Script $cmd -ExtraArgs @('-v', "$($script:TestMavenVol):/root/.m2:ro", '-v', $Ctx.Mount) -TimeoutSec 300
    $out = $r.StdOut
    if ($r.StdErr.Trim()) { $out += "`n# stderr`n" + $r.StdErr }
    $diffPath = Save-Evidence -Suite 'parity' -Name "$n.diff.txt" -Content $out
    $evidence = @($Ctx.Captures["$n.old"], $Ctx.Captures["$n.new"], $diffPath)
    if ($VolatilePath) { $evidence += $VolatilePath }

    # The debug-port result belongs to R11 as well as R6.
    $jdwpRx = "^HCRESULT`tE-[^`t]+-jdwp`t"
    $lines = @($r.StdOut -split "`r?`n")
    $jdwp = @($lines | Where-Object { $_ -match $jdwpRx })
    $rest = @($lines | Where-Object { $_ -notmatch $jdwpRx })
    $count = Import-HcResults -Text ($rest -join "`n") -Req @('R6') -Evidence $evidence
    $count += Import-HcResults -Text ($jdwp -join "`n") -Req @('R6', 'R11') -Evidence $evidence
    if ($count -eq 0 -or $r.ExitCode -ge 2) {
        Add-Result -Id "E-$n-diff" -Status 'FAIL' -Req @('R6') -Message ("LaunchDiff could not compare the two launches (exit {0}, {1} results): {2}" -f $r.ExitCode, $count, (Parity-Tail $r.StdErr)) -Evidence $evidence
    }
}

# What the application said about itself, OLD against NEW: the same active
# profiles, config fetched from config-server for the ten clients, and the
# same port served.
function Parity-LogFacts {
    param([AllowEmptyString()][string] $Log)
    $prof = $null
    $m = [regex]::Match($Log, 'The following (?:\d+ )?profiles? (?:is|are) active: [^\r\n]*')
    if ($m.Success) { $prof = $m.Value.Trim() }
    $port = $null
    $m = [regex]::Match($Log, '(?:Tomcat|Netty|Jetty|Undertow) started on port(?:\(s\))?:? (\d+)')
    if ($m.Success) { $port = [int]$m.Groups[1].Value }
    $located = $null
    $m = [regex]::Match($Log, 'Located environment: name=[^\r\n]*')
    if ($m.Success) { $located = $m.Value.Trim() }
    return [pscustomobject]@{ Profile = $prof; Port = $port; Located = $located }
}

function Parity-CompareLogs {
    param([Parameter(Mandatory)] $Ctx, [Parameter(Mandatory)] $Svc)
    $n = $Svc.Name
    $id = "E-$n-logs"
    if (-not ($Ctx.Logs.ContainsKey("$n.old") -and $Ctx.Logs.ContainsKey("$n.new"))) {
        Add-Result -Id $id -Status 'SKIP' -Req @('R6') -Message "not compared: the OLD or NEW launch did not start - see E-$n-launch-*"
        return
    }
    $oldLog = $Ctx.Logs["$n.old"]
    $newLog = $Ctx.Logs["$n.new"]
    $o = Parity-LogFacts -Log $oldLog
    $w = Parity-LogFacts -Log $newLog
    $problems = [System.Collections.Generic.List[string]]::new()
    $facts = [System.Collections.Generic.List[string]]::new()

    if (-not $o.Profile -or -not $w.Profile) {
        $problems.Add("no 'The following ... profile is active' line in $(if (-not $o.Profile) { 'OLD' } else { 'NEW' })")
    }
    elseif ($o.Profile -ne $w.Profile) { $problems.Add("profiles differ: OLD '$($o.Profile)', NEW '$($w.Profile)'") }
    else { $facts.Add($w.Profile) }

    if ($Svc.ConfigClient) {
        $want = "Located environment: name=$($Svc.App), profiles=[container]"
        $inOld = $oldLog.Contains($want)
        $inNew = $newLog.Contains($want)
        if ($inOld -and $inNew) { $facts.Add("'$want' in both") }
        else {
            if (-not $inOld) { $problems.Add("OLD lacks '$want' (first Located line: '$(Parity-Tail $o.Located 200)')") }
            if (-not $inNew) { $problems.Add("NEW lacks '$want' (first Located line: '$(Parity-Tail $w.Located 200)')") }
        }
    }

    if ($null -eq $o.Port -or $null -eq $w.Port) {
        $problems.Add("no '<server> started on port' line in $(if ($null -eq $o.Port) { 'OLD' } else { 'NEW' })")
    }
    elseif ($o.Port -ne $w.Port) { $problems.Add("ports differ: OLD $($o.Port), NEW $($w.Port)") }
    elseif ($w.Port -ne $Svc.Port) { $problems.Add("both serve $($w.Port), but compose's DEV_APP_PORT for $n is $($Svc.Port), so dev-reload.sh's readiness check would probe the wrong port") }
    else { $facts.Add("port $($w.Port) in both") }

    $evidence = @((Join-Path $Ctx.Ev "$n.old.log"), (Join-Path $Ctx.Ev "$n.new.log"))
    if ($problems.Count) {
        Add-Result -Id $id -Status 'FAIL' -Req @('R6') -Message ($problems -join '; ') -Evidence $evidence
    }
    else {
        Add-Result -Id $id -Status 'PASS' -Req @('R6') -Message ($facts -join '; ') -Evidence $evidence
    }
}

# This suite's containers, or with -All every harness container. The guard
# allows removing any hct-*; only a run that is starting may assume that the
# ones which are not its own are leftovers.
function Parity-RemoveContainers {
    param([switch] $All)
    $r = Invoke-Docker @('ps', '-a', '--format', '{{.Names}}') -TimeoutSec 60
    foreach ($c in ($r.StdOut -split "`r?`n")) {
        $mine = $c -like 'hct-old-*' -or $c -like 'hct-new-*' -or $c -like 'hct-new2-*'
        if ($mine -or ($All -and $c -like 'hct-*')) {
            Invoke-Docker @('rm', '-f', $c) -TimeoutSec 120 | Out-Null
        }
    }
}

function Parity-ProjectLogs {
    $ps = Parity-Compose @('ps', '-a') -TimeoutSec 120
    $lg = Parity-Compose @('logs', '--no-color', '--tail', '200') -TimeoutSec 180
    return ($ps.StdOut + "`n" + $lg.StdOut + $lg.StdErr)
}

# One line, at most $Max characters, for a result message - and redacted
# before it is cut, so that the cut cannot leave half a secret that
# Add-Result's own redaction would no longer recognise.
function Parity-Tail {
    param([AllowEmptyString()][string] $Text, [int] $Max = 300)
    if (-not $Text) { return '' }
    $t = ((Protect-Text $Text).Trim() -replace '\s+', ' ')
    if ($t.Length -gt $Max) { $t = '...' + $t.Substring($t.Length - $Max) }
    return $t
}
