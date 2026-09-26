#Requires -Version 7.2
# Suite D, concurrency: twelve cold builds against ONE Maven volume, the way
# `./dev up` runs them, and the proof that nothing about it races (R3, R4, R1,
# R5). Loaded by test/run.ps1 after lib/Harness.ps1; read that file's
# CONVENTIONS first. ASCII only.
#
# What each part proves, and why it is needed:
#
#   D-COLD-*     Twelve `dev-reload.sh --build-only` runs on an EMPTY test
#                volume, released together by a barrier - once through mvnd
#                and once through ./mvnw, because auto picks mvnd whenever it
#                works and the wrapper path would otherwise never run here.
#                The discriminating check is DUPLICATE DOWNLOADS. Resolver 1.9
#                downloads to <file>.<n>.tmp and renames atomically, so twelve
#                UNLOCKED builds rarely leave corruption behind - they download
#                the same jar twelve times. Under a working cross-process lock
#                the second container waits, looks again, and finds it there.
#                Transfer lines are only visible without -q: DEV_MAVEN_QUIET=0.
#   D-SCAN-*     The volume afterwards (test/container/scan-repo.sh): no temp
#                or tracking leftovers, no empty jar, every .sha1 right, every
#                jar entry readable, and lock files that are still THERE -
#                true only when deleteLockFiles=false reached the JVM that
#                took them. Hence once after an mvnd-only and once after an
#                mvnw-only round.
#   D-WRAP-*     The wrapper's own install, which no resolver lock covers:
#                downloaded once, never nested, complete, and an incomplete
#                install left by a killed container cleaned up, not run.
#   D-LOCK-*     The lock itself: configured (the resolver's adapter line),
#                in the mvnd DAEMON's JVM (jcmd), excluding another process
#                (holder test), and - the reverse probe - excluding it THROUGH
#                the file Maven made, which is the part deleteLockFiles=false
#                fixes: with the default, the file is unlinked as it is opened.
#   D-WARM-DOWNV `down -v` of the test project takes its own volumes and
#                leaves both external Maven volumes alone.
#   D-WARM       A round on the warm volume after that `down -v`: nothing
#                downloaded, nothing in the repository changed.
#   D-STACK-COLD The REAL entrypoint, all twelve, from an empty volume, until
#                each answers on its port, then two quiet minutes: no rebuild
#                loop, no restart loop.
#   D-REAL       Opt-in (-ColdRealMavenVolume): the same cold start on your
#                real Maven cache, through the real launcher.
#
# Everything but D-REAL runs in the isolated test project (-p homecrew-test,
# test/compose.test.yml): its own Maven volume, no host ports, checkouts
# read-only. homecrew-maven-repo is only ever inspected, except by D-REAL.
#
# For the mutation suite: Conc-Invoke-ColdBuildRound is usable on its own -
# see the comment above it.

Set-StrictMode -Version 3.0

# The lines that mean a build went wrong in a way this suite exists to catch.
$script:ConcErrorPattern = 'Could not acquire|FailedToAcquireLock|Checksum validation failed|ZipException|invalid LOC header|error in opening zip|Could not transfer|Could not resolve|Could not find artifact|BUILD FAILURE|NoSuchFileException'

# The lines that mean the NETWORK or the repository failed the build, not the
# setup: a failed round that shows one of these is BLOCKED, not FAIL.
$script:ConcBlockedPattern = 'status code: (429|5\d\d)|\b429 Too Many Requests|\b50[0-4] (Internal Server Error|Bad Gateway|Service Unavailable|Gateway Timeout)|UnknownHostException|Network is unreachable|Temporary failure in name resolution|Connection timed out|connect timed out|Connection reset|No route to host'

# Nothing an idle stack should ever log.
$script:ConcIdlePattern = '\[dev-reload\] (build-start|compile-start|app-started|app-exited|restart-scheduled|source-changed|build-changed|trigger-touched|boot-timeout):|Restarting due to'

# The single-container tests run in service-discovery: its environment holds
# no credential at all, so even a -X debug log of it cannot leak one. The
# scans run in user-service, as the plan has it.
$script:ConcLockService = 'service-discovery'
$script:ConcScanService = 'user-service'

function Invoke-SuiteConcurrency {
    Enter-Suite 'concurrency' 'twelve builds, one Maven volume (R3, R4, R1, R5)'
    $h = Get-Harness
    $what = 'D-COLD, D-SCAN, D-WRAP, D-LOCK, D-WARM-DOWNV, D-WARM, D-STACK-COLD and D-REAL'

    if (-not (Test-DockerAvailable)) {
        Add-Result -Id 'D-PRE' -Status 'SKIP' -Req @('R4') -Message "docker is not available, so $what did not run"
        return
    }
    if (-not (Test-Path -LiteralPath (Join-Path $h.InfraRoot '.env') -PathType Leaf)) {
        Add-Result -Id 'D-PRE' -Status 'SKIP' -Req @('R4') -Message "there is no .env, which compose needs to render docker-compose.yml at all, so $what did not run"
        return
    }
    # Twelve 1g containers next to a running dev stack is twelve more: the
    # need doubles, and an OOM in the Docker VM can take the user's own
    # containers with it.
    $live = Test-LiveStackRunning
    $need = 10GB
    if ($live) { $need = 20GB }
    $mem = Test-DockerMemory -NeedBytes $need
    if ($mem) {
        $hint = ''
        if ($live) { $hint = ' (your dev stack is running beside it; ./dev down frees its share)' }
        Add-Result -Id 'D-PRE' -Status 'BLOCKED' -Req @('R4') -Message "$mem$hint - $what did not run"
        return
    }

    $st = @{
        RealExisted = ((Invoke-Docker @('volume', 'inspect', $script:RealMavenVol) -TimeoutSec 60).ExitCode -eq 0)
        BootVersion = (Conc-Get-BootVersion)
        HasMvnd     = $false
        First       = 'mvnw'
        FirstRound  = $null
    }
    $why = Initialize-TestProject -FreshMavenVolume
    if ($why) {
        Add-Result -Id 'D-PRE' -Status 'FAIL' -Req @('R4') -Message "the test project could not be prepared: $why"
        return
    }
    $st.HasMvnd = Conc-Test-Mvnd
    if ($st.HasMvnd) { $st.First = 'mvnd' }
    else {
        Add-Result -Id 'D-MVND' -Status 'INFO' -Req @('R4') -Message "mvnd does not run in $($script:DevImage) (Dockerfile.dev installs it non-fatally), so every service falls back to ./mvnw; the mvnd parts of this suite are skipped"
    }

    try {
        Conc-Step 'D-COLD-FIRST' { Conc-Step-FirstCold $st }
        Conc-Step 'D-LOCK-ADAPTER' { Conc-Step-LockAdapter $st }
        Conc-Step 'D-LOCK-HOLD' { Conc-Step-LockHold $st }
        Conc-Step 'D-LOCK-PROBE' { Conc-Step-LockProbe $st }
        Conc-Step 'D-WARM' { Conc-Step-Warm $st } -Req @('R4', 'R1')
        Conc-Step 'D-COLD-mvnw' { Conc-Step-SecondCold $st }
        Conc-Step 'D-STACK-COLD' { Conc-Step-StackCold $st }
        Conc-Step 'D-REAL' { Conc-Step-Real $st } -Req @('R1', 'R4')
    }
    finally {
        # The one-off containers never outlive the suite, whatever happened.
        $ps = Invoke-Docker @('ps', '-a', '--format', '{{.Names}}') -TimeoutSec 60
        foreach ($c in @(($ps.StdOut -split "`r?`n") | Where-Object { $_ -like 'hct-*' })) {
            Invoke-Docker @('rm', '-f', $c) -TimeoutSec 120 | Out-Null
        }
        # The Maven cache the cold rounds filled stays for the suites after
        # this one - only this suite needs it cold, and makes it so itself.
        # run.ps1 removes it at the very end.
        if (-not (Conc-Opt 'KeepTestProject')) { Remove-TestProject -KeepMavenVolume | Out-Null }
    }
}

# ---------------------------------------------------------------------------
# The steps
# ---------------------------------------------------------------------------

# One failing step - or a harness bug in it - must not take the rest of the
# suite down with it; the error is a FAIL row that says where it happened.
function Conc-Step {
    param([Parameter(Mandatory)][string] $Id, [Parameter(Mandatory)][scriptblock] $Body, [string[]] $Req = @('R4'))
    try { $null = & $Body }
    catch {
        $where = ''
        if ($_.InvocationInfo) { $where = ($_.InvocationInfo.PositionMessage -replace "`r?`n", ' ') }
        Add-Result -Id "$Id-HARNESS-ERROR" -Status 'FAIL' -Req $Req -Message ('harness error: {0} {1}' -f $_.Exception.Message, $where)
    }
}

# The first cold round, with mvnd when it works. It also carries the
# partial-install case: in mvnd mode the wrapper is installed up front but is
# not what builds, so recovering the seeded half-install is measured without
# the round depending on it.
function Conc-Step-FirstCold {
    param($st)
    $c = $st.First
    if (-not $st.HasMvnd) {
        Add-Result -Id 'D-COLD-mvnd' -Status 'SKIP' -Req @('R4') -Message 'no mvnd in the dev image, so there is no mvnd round'
    }
    $why = Conc-Reset-TestProject
    if ($why) {
        Add-Result -Id "D-COLD-$c" -Status 'FAIL' -Req @('R4') -Message "could not start from empty volumes: $why"
        return
    }
    $seed = Conc-Seed-PartialWrapper
    Conc-Say "D-COLD-${c}: twelve cold builds, one volume (typically 5-20 min)"
    $round = Conc-Invoke-ColdBuildRound -Compiler $c -Label $c
    $st.FirstRound = $round
    Conc-Report-Round -Round $round -Id "D-COLD-$c"
    Conc-Invoke-Scan -Label $c
    Conc-Report-PartialWrapper -Round $round -Seed $seed
    if ($c -eq 'mvnw') { Conc-Report-WrapperOnce -Round $round }
}

# The mvnw round, when mvnd had the first one: empty volumes again, so the
# wrapper is installed from nothing by twelve containers at once.
function Conc-Step-SecondCold {
    param($st)
    if (-not $st.HasMvnd) { return }   # then the first round WAS the mvnw round
    $why = Conc-Reset-TestProject
    if ($why) {
        Add-Result -Id 'D-COLD-mvnw' -Status 'FAIL' -Req @('R4') -Message "could not start from empty volumes: $why"
        return
    }
    Conc-Say 'D-COLD-mvnw: twelve cold builds through ./mvnw'
    $round = Conc-Invoke-ColdBuildRound -Compiler 'mvnw' -Label 'mvnw'
    Conc-Report-Round -Round $round -Id 'D-COLD-mvnw'
    Conc-Invoke-Scan -Label 'mvnw'
    Conc-Report-WrapperOnce -Round $round
}

# D-LOCK (1) and (2): the resolver really was configured for file-lock +
# file-gav (its own DEBUG line), for both kinds of JVM - and the mvnd DAEMON,
# which is the JVM that loads the lock class, carries deleteLockFiles=false.
function Conc-Step-LockAdapter {
    param($st)
    $dir = Conc-New-EvidenceDir 'lock-adapter'
    foreach ($c in @('mvnd', 'mvnw')) {
        $id = "D-LOCK-ADAPTER-$c"
        if ($c -eq 'mvnd' -and -not $st.HasMvnd) {
            Add-Result -Id $id -Status 'SKIP' -Req @('R4') -Message 'no mvnd in the dev image'
            Add-Result -Id 'D-LOCK-JCMD' -Status 'SKIP' -Req @('R4') -Message 'no mvnd in the dev image'
            Add-Result -Id 'D-MVND-OPTS' -Status 'SKIP' -Req @('R4') -Message 'no mvnd in the dev image'
            continue
        }
        $flags = @()
        if ($c -eq 'mvnd') { $flags = @('--jcmd') }
        Conc-Say "${id}: one -X build through $c"
        $b = Conc-Invoke-SingleBuild -Service $script:ConcLockService -Compiler $c -Tag "adapter-$c" -Dir $dir -ExtraArgs '-X' -Flags $flags -TimeoutSec 1800
        $line = [regex]::Match($b.Log, '(?m)^.*nameMapper ''file-gav'' and factory ''file-lock''.*$')
        if ($line.Success) {
            $status = 'PASS'
            $tail = ''
            if ($b.Rc -ne 0) { $status = 'WARN'; $tail = " - but the build itself exited $(Conc-RcText $b.Rc)" }
            Add-Result -Id $id -Status $status -Req @('R4') -Message ("the $c build's resolver logged: {0}{1}" -f (Conc-Clip $line.Value.Trim() 160), $tail) -Evidence @($b.LogPath)
        }
        else {
            $other = [regex]::Match($b.Log, '(?m)^.*Creating adapter using nameMapper.*$')
            $saw = 'no adapter line at all'
            if ($other.Success) { $saw = 'instead: ' + (Conc-Clip $other.Value.Trim() 160) }
            Add-Result -Id $id -Status 'FAIL' -Req @('R4') -Message "no `"nameMapper 'file-gav' and factory 'file-lock'`" in the -X log of the $c build (exit $(Conc-RcText $b.Rc)); $saw" -Evidence @($b.LogPath)
        }
        if ($c -eq 'mvnd') {
            $jpath = Join-Path $dir "adapter-$c.jcmd"
            $m = [regex]::Match($b.Jcmd, 'JCMD-SUMMARY daemons=(\d+) deleteLockFiles_false=(\d+)')
            if (-not $m.Success) {
                Add-Result -Id 'D-LOCK-JCMD' -Status 'FAIL' -Req @('R4') -Message 'build-once.sh --jcmd left no summary: the daemon was never inspected' -Evidence @($jpath)
            }
            else {
                $n = [int]$m.Groups[1].Value
                $ok = [int]$m.Groups[2].Value
                if ($n -ge 1 -and $ok -eq $n) {
                    Add-Result -Id 'D-LOCK-JCMD' -Status 'PASS' -Req @('R4') -Message "jcmd <pid> VM.system_properties of the mvnd daemon ($n JVM) has aether.named.file-lock.deleteLockFiles=false" -Evidence @($jpath)
                }
                elseif ($n -eq 0) {
                    Add-Result -Id 'D-LOCK-JCMD' -Status 'FAIL' -Req @('R4') -Message 'no mvnd daemon JVM was running after the mvnd build (no java process with mvnd on its command line)' -Evidence @($jpath)
                }
                else {
                    Add-Result -Id 'D-LOCK-JCMD' -Status 'FAIL' -Req @('R4') -Message "only $ok of $n mvnd daemon JVMs have aether.named.file-lock.deleteLockFiles=false: it did not reach the daemon's JVM, so the daemon deletes the lock files it takes" -Evidence @($jpath)
                }
            }
            Conc-Report-MvndOptions -Jcmd $b.Jcmd -Evidence @($jpath)
        }
    }
}

# D-MVND-OPTS: what mvnd did with the rest of its options, read off the daemon
# itself. A daemon registry on the shared volume (~/.m2/mvnd) means
# mvnd.daemonStorage was not applied, and twelve containers would find each
# other's daemons there; a heap above 320 MB means mvnd.maxHeapSize was not,
# in a 1g container.
function Conc-Report-MvndOptions {
    param([AllowEmptyString()][string] $Jcmd, [string[]] $Evidence = @())
    $reg = [regex]::Match($Jcmd, 'JCMD-REGISTRY tmp=(\w+) m2=(\w+)')
    $heaps = @([regex]::Matches($Jcmd, 'JCMD-DAEMON pid=\d+ deleteLockFiles=\S+ maxHeapMB=(\d+)') | ForEach-Object { [int]$_.Groups[1].Value })
    if (-not $reg.Success -or $heaps.Count -eq 0) {
        Add-Result -Id 'D-MVND-OPTS' -Status 'FAIL' -Req @('R4') -Message 'build-once.sh --jcmd reported no daemon or no registry, so the mvnd options could not be checked' -Evidence $Evidence
        return
    }
    $problems = [System.Collections.Generic.List[string]]::new()
    if ($reg.Groups[2].Value -eq 'yes') { $problems.Add('a daemon registry exists on the shared volume (~/.m2/mvnd/registry.bin): mvnd.daemonStorage was not applied') }
    if ($reg.Groups[1].Value -ne 'yes') { $problems.Add('no registry in /tmp/mvnd, where mvnd.daemonStorage puts it') }
    $big = @($heaps | Where-Object { $_ -ne 320 })
    if ($big.Count) { $problems.Add("daemon max heap $($big -join ', ') MB, not the 320 MB of mvnd.maxHeapSize") }
    if ($problems.Count) {
        Add-Result -Id 'D-MVND-OPTS' -Status 'FAIL' -Req @('R4') -Message ($problems -join '; ') -Evidence $Evidence
    }
    else {
        Add-Result -Id 'D-MVND-OPTS' -Status 'PASS' -Req @('R4') -Message "the daemon registered in /tmp/mvnd (per container, nothing on the shared volume), and its heap is capped at 320 MB" -Evidence $Evidence
    }
}

# D-LOCK (4), the holder test: a container holding the spring-boot artifact's
# lock file must make an offline build in another container fail - with the
# resolver's own "Could not acquire", after the 5 s it was given, not after
# 900 - and the same build must succeed once the holder has gone.
function Conc-Step-LockHold {
    param($st)
    $svc = $script:ConcLockService
    $v = $st.BootVersion
    $lock = "/root/.m2/repository/.locks/artifact~org.springframework.boot~spring-boot~$v.lock"
    $lockName = $lock.Substring($lock.LastIndexOf('/') + 1)
    $jar = "/root/.m2/repository/org/springframework/boot/spring-boot/$v/spring-boot-$v.jar"
    $pre = Invoke-TestCompose @('run', '--rm', '--no-deps', '-T', '--entrypoint', 'test', $svc, '-f', $jar) -TimeoutSec 300
    foreach ($c in @('mvnd', 'mvnw')) {
        $id = "D-LOCK-HOLD-$c"
        if ($c -eq 'mvnd' -and -not $st.HasMvnd) {
            Add-Result -Id $id -Status 'SKIP' -Req @('R4') -Message 'no mvnd in the dev image'
            continue
        }
        if ($pre.ExitCode -ne 0) {
            Add-Result -Id $id -Status 'SKIP' -Req @('R4') -Message "spring-boot-$v.jar is not in the test volume - the cold round before this did not complete, and an offline build needs it"
            continue
        }
        $dir = Conc-New-EvidenceDir "lock-hold-$c"
        $holder = "hct-lock-hold-$c"
        Conc-Remove-Containers @($holder)
        try {
            Conc-Say "${id}: holding $lockName while $c builds offline"
            $hr = Invoke-TestCompose @('run', '-d', '--no-deps', '-T', '--name', $holder, '-v', "$($dir):/out",
                '--entrypoint', 'java', $svc, '/test/java/LockProbe.java', 'hold', $lock, '900', '/out/release') -TimeoutSec 300
            if ($hr.ExitCode -ne 0) {
                Add-Result -Id $id -Status 'FAIL' -Req @('R4') -Message "could not start the holder container: $(Conc-FirstLine $hr.StdErr)"
                continue
            }
            if (-not (Conc-Wait-ContainerLog -Name $holder -Pattern '(?m)^HELD ' -TimeoutSec 180)) {
                $hl = Conc-SaveIn $dir 'holder.log' (Get-ContainerLog -Container $holder)
                Add-Result -Id $id -Status 'FAIL' -Req @('R4') -Message 'the holder never printed HELD' -Evidence @($hl)
                continue
            }
            $mvnArgs = @('-o', 'dependency:build-classpath', '-Dmdep.outputFile=/tmp/hc-cp.txt')
            $held = Conc-Invoke-SingleBuild -Service $svc -Compiler $c -Tag 'held' -Dir $dir -ExtraArgs '-Daether.syncContext.named.time=5' -Maven $mvnArgs -TimeoutSec 300
            [System.IO.File]::WriteAllText((Join-Path $dir 'release'), "release`n")
            Invoke-Docker @('wait', $holder) -TimeoutSec 120 | Out-Null
            $hlog = Get-ContainerLog -Container $holder
            $hl = Conc-SaveIn $dir 'holder.log' $hlog
            $free = Conc-Invoke-SingleBuild -Service $svc -Compiler $c -Tag 'free' -Dir $dir -ExtraArgs '-Daether.syncContext.named.time=5' -Maven $mvnArgs -TimeoutSec 600

            $problems = [System.Collections.Generic.List[string]]::new()
            $acq = [regex]::Match($held.Log, '(?m)^.*Could not acquire.*$')
            if ($held.TimedOut) { $problems.Add('while the lock was held the build did not end within 300 s: aether.syncContext.named.time=5 was not what bounded it') }
            elseif ($held.Rc -eq 0) { $problems.Add("the build SUCCEEDED while another container held ${lockName}: nothing excluded it") }
            elseif (-not $acq.Success) { $problems.Add("while the lock was held the build failed (exit $(Conc-RcText $held.Rc)), but not with 'Could not acquire': $(Conc-FirstLine ([regex]::Match($held.Log, '(?m)^.*ERROR.*$').Value))") }
            if ($null -ne $held.Secs -and -not $held.TimedOut -and ($held.Secs -lt 5 -or $held.Secs -gt 120)) { $problems.Add("it ended after $($held.Secs)s, which a 5 s lock timeout does not explain") }
            if ($hlog -notmatch '(?m)^RELEASED ') { $problems.Add('the holder did not report RELEASED') }
            if ($free.Rc -ne 0) { $problems.Add("once the holder had gone, the same build failed (exit $(Conc-RcText $free.Rc))") }
            elseif ($free.Log -match 'Could not acquire') { $problems.Add("once the holder had gone, the build still logged 'Could not acquire'") }
            $ev = @($held.LogPath, $free.LogPath, $hl)
            if ($problems.Count) {
                Add-Result -Id $id -Status 'FAIL' -Req @('R4') -Message ($problems -join ' | ') -Evidence $ev
            }
            else {
                $status = 'PASS'
                $note = ''
                if ($held.Secs -gt 20) { $status = 'WARN'; $note = ' (slower than the 5-20 s expected, but bounded by the lock timeout)' }
                Add-Result -Id $id -Status $status -Req @('R4') -Message ("with the lock held elsewhere the $c build failed after {0}s: {1}{2}; after the holder exited it succeeded" -f $held.Secs, (Conc-Clip $acq.Value.Trim() 140), $note) -Evidence $ev
            }
        }
        finally {
            Conc-Remove-Containers @($holder)
        }
    }
}

# D-LOCK (3), the reverse probe. A real cold resolve (container A) into a
# repository of its own, while container B opens the lock files A creates -
# WITHOUT CREATE, so B only ever meets A's own files - and tries to lock them.
# Contention proves A's lock is on a file other processes can find; the files
# still being there afterwards proves they were never unlinked. Both are
# needed: with DELETE_ON_CLOSE a probe can still, rarely, open a file in the
# instant between its open and its unlink and see it locked.
function Conc-Step-LockProbe {
    param($st)
    $svc = $script:ConcLockService
    $c = $st.First
    $repo = '/root/.m2/lockprobe-repo'
    $dir = Conc-New-EvidenceDir 'lock-probe'
    $prober = 'hct-lock-probe'
    Conc-Remove-Containers @($prober, 'hct-one-lockprobe')
    try {
        Invoke-TestCompose @('run', '--rm', '--no-deps', '-T', '--entrypoint', 'rm', $svc, '-rf', $repo) -TimeoutSec 300 | Out-Null
        $pr = Invoke-TestCompose @('run', '-d', '--no-deps', '-T', '--name', $prober, '-v', "$($dir):/out",
            '--entrypoint', 'java', $svc, '/test/java/LockProbe.java', 'probe', "$repo/.locks", '3000', '/out/lockprobe.rc') -TimeoutSec 300
        if ($pr.ExitCode -ne 0 -or -not (Conc-Wait-ContainerLog -Name $prober -Pattern '(?m)^PROBING ' -TimeoutSec 180)) {
            Add-Result -Id 'D-LOCK-PROBE' -Status 'FAIL' -Req @('R4') -Message "the probe container did not start: $(Conc-FirstLine $pr.StdErr)"
            return
        }
        Conc-Say "D-LOCK-PROBE: a cold $c resolve into $repo, probed from another container"
        $a = Conc-Invoke-SingleBuild -Service $svc -Compiler $c -Tag 'lockprobe' -Dir $dir -ExtraArgs "-C -Dmaven.repo.local=$repo" -Flags @('--repo', $repo) -TimeoutSec 2700
        # The probe stops by itself once lockprobe.rc exists.
        Invoke-Docker @('wait', $prober) -TimeoutSec 180 | Out-Null
        $plog = Get-ContainerLog -Container $prober
        $pl = Conc-SaveIn $dir 'prober.log' $plog
        $cnt = Invoke-TestCompose @('run', '--rm', '--no-deps', '-T', '--entrypoint', 'sh', $svc, '-c',
            "find $repo/.locks -maxdepth 1 -type f -name 'artifact~*.lock' 2>/dev/null | wc -l") -TimeoutSec 300
        $left = 0
        if ($cnt.ExitCode -ne 0 -or -not [int]::TryParse($cnt.StdOut.Trim(), [ref] $left)) { $left = -1 }

        $sum = [regex]::Matches($plog, 'CONTENDED=(\d+) SEEN=(\d+)')
        $contended = -1
        $seen = -1
        if ($sum.Count) {
            $contended = [int]$sum[$sum.Count - 1].Groups[1].Value
            $seen = [int]$sum[$sum.Count - 1].Groups[2].Value
        }
        $ev = @($a.LogPath, $pl)
        $problems = [System.Collections.Generic.List[string]]::new()
        if ($a.Rc -ne 0) { $problems.Add("the cold resolve itself failed (exit $(Conc-RcText $a.Rc))") }
        if ($contended -lt 0) { $problems.Add('the probe printed no CONTENDED=/SEEN= summary') }
        elseif ($contended -lt 1) { $problems.Add("the probe saw $seen lock files and never found one held: the lock is not on a file another process can find") }
        if ($left -lt 0) { $problems.Add("could not count the lock files left in $repo/.locks: $(Conc-FirstLine $cnt.StdErr)") }
        elseif ($left -lt 1) { $problems.Add("no artifact~*.lock left in $repo/.locks after the build exited: the files were deleted as they were opened (deleteLockFiles is not in effect for $c)") }
        if ($problems.Count) {
            $status = 'FAIL'
            if ($a.Rc -ne 0 -and $a.Log -match "(?i)(?:$script:ConcBlockedPattern)") { $status = 'BLOCKED'; $problems.Insert(0, 'the network failed the cold resolve') }
            Add-Result -Id 'D-LOCK-PROBE' -Status $status -Req @('R4') -Message ($problems -join ' | ') -Evidence $ev
        }
        else {
            Add-Result -Id 'D-LOCK-PROBE' -Status 'PASS' -Req @('R4') -Message "while $c resolved cold, a probe in another container found $contended of its lock attempts blocked on the build's own lock files ($seen seen, opened without CREATE), and $left artifact locks were still there after the build exited" -Evidence $ev
        }
    }
    finally {
        Conc-Remove-Containers @($prober, 'hct-one-lockprobe')
        Invoke-TestCompose @('run', '--rm', '--no-deps', '-T', '--entrypoint', 'rm', $svc, '-rf', $repo) -TimeoutSec 300 | Out-Null
    }
}

# D-WARM and D-WARM-DOWNV: `down -v`, then the same round on what is left.
function Conc-Step-Warm {
    param($st)
    $c = $st.First
    $dir = Conc-New-EvidenceDir 'warm'
    $before = Conc-Get-Snapshot
    $sb = Conc-SaveIn $dir 'snapshot-before.txt' $before.Text

    $volsBefore = @(Conc-Get-Volumes | Where-Object { $_ -like "$($script:TestProject)_*" })
    $down = Invoke-TestCompose @('down', '-v', '--remove-orphans') -TimeoutSec 600
    $volsAfter = @(Conc-Get-Volumes)
    $vl = Conc-SaveIn $dir 'volumes.txt' ("before down -v:`n" + ($volsBefore -join "`n") + "`n`nafter down -v:`n" + ($volsAfter -join "`n") + "`n`ndown -v said:`n" + $down.StdOut + $down.StdErr)
    $stay = @($volsAfter | Where-Object { $_ -like "$($script:TestProject)_*" })
    $problems = [System.Collections.Generic.List[string]]::new()
    if ($down.ExitCode -ne 0) { $problems.Add("down -v exited $($down.ExitCode)") }
    if ($stay.Count) { $problems.Add("still there: $($stay -join ', ')") }
    if ($volsAfter -notcontains $script:TestMavenVol) { $problems.Add("$($script:TestMavenVol) is GONE - an external volume was removed") }
    if ($st.RealExisted -and $volsAfter -notcontains $script:RealMavenVol) { $problems.Add("$($script:RealMavenVol) is GONE") }
    if ($problems.Count) {
        Add-Result -Id 'D-WARM-DOWNV' -Status 'FAIL' -Req @('R1') -Message ($problems -join ' | ') -Evidence @($vl)
    }
    elseif ($volsBefore.Count -eq 0) {
        Add-Result -Id 'D-WARM-DOWNV' -Status 'WARN' -Req @('R1') -Message 'there were no homecrew-test_* volumes to remove, so down -v proved little; both Maven volumes survived it' -Evidence @($vl)
    }
    else {
        $real = 'homecrew-maven-repo did not exist before the suite'
        if ($st.RealExisted) { $real = "$($script:RealMavenVol) still exists" }
        Add-Result -Id 'D-WARM-DOWNV' -Status 'PASS' -Req @('R1') -Message "down -v removed all $($volsBefore.Count) homecrew-test_* volumes; $($script:TestMavenVol) still exists; $real" -Evidence @($vl)
    }

    if (-not $st.FirstRound -or $st.FirstRound.Status -ne 'PASS' -or -not $before.Ok) {
        Add-Result -Id 'D-WARM' -Status 'SKIP' -Req @('R4') -Message 'the cold round before it did not pass, so there is no complete warm volume to rebuild from'
        return
    }
    Conc-Say "D-WARM: twelve builds again, on the warm volume, through $c"
    $round = Conc-Invoke-ColdBuildRound -Compiler $c -Label 'warm'
    $after = Conc-Get-Snapshot
    $sa = Conc-SaveIn $dir 'snapshot-after.txt' $after.Text
    $round.Evidence.Add($sb)
    $round.Evidence.Add($sa)
    $extra = @()
    if (-not $after.Ok) { $extra += "the snapshot after the round failed (exit $($after.Exit))" }
    else {
        $diff = @(Compare-Object -ReferenceObject $before.Lines -DifferenceObject $after.Lines -CaseSensitive)
        if ($diff.Count) {
            $show = @($diff | Select-Object -First 4 | ForEach-Object {
                $side = 'after only'
                if ($_.SideIndicator -eq '<=') { $side = 'before only' }
                "$($_.InputObject) ($side)"
            })
            $extra += "the repository changed ($($diff.Count) lines of <path> <size> differ), e.g. $($show -join '; ')"
        }
    }
    Conc-Report-Round -Round $round -Id 'D-WARM' -Warm -Extra $extra
}

# D-STACK-COLD: the real entrypoint, nothing replaced. The ten config clients
# wait for config-server and service-discovery through depends_on exactly as
# in ./dev up, so this is the cold start a developer actually gets.
function Conc-Step-StackCold {
    param($st)
    $services = @(Get-JavaServices)
    $dir = Conc-New-EvidenceDir 'stack-cold'
    $why = Conc-Reset-TestProject
    if ($why) {
        Add-Result -Id 'D-STACK-COLD' -Status 'FAIL' -Req @('R4') -Message "could not start from empty volumes: $why"
        return
    }
    try {
        $t0 = [DateTime]::UtcNow
        $deadline = $t0.AddMinutes(45)
        Conc-Say 'D-STACK-COLD: postgres and kafka, then all twelve with the real entrypoint (up to 45 min)'
        $infra = Invoke-TestCompose @('up', '-d', '--wait', 'postgres', 'kafka') -TimeoutSec 900
        $ev = [System.Collections.Generic.List[string]]::new()
        $ev.Add((Conc-SaveIn $dir 'up-infra.txt' ($infra.StdOut + $infra.StdErr)))
        if ($infra.ExitCode -ne 0) {
            Add-Result -Id 'D-STACK-COLD' -Status 'FAIL' -Req @('R4') -Message "postgres and kafka did not come up healthy (exit $($infra.ExitCode)): $(Conc-FirstLine $infra.StdErr)" -Evidence @($ev)
            return
        }
        $left = [int][Math]::Max(60, ($deadline - [DateTime]::UtcNow).TotalSeconds)
        $up = Invoke-TestCompose -ComposeArgs (@('up', '-d') + @($services | ForEach-Object { $_.Name })) -TimeoutSec $left
        $ev.Add((Conc-SaveIn $dir 'up.txt' ($up.StdOut + $up.StdErr)))
        $map = Conc-Get-ProjectContainers
        $ready = Conc-Wait-AppReady -Map $map -Services $services -Deadline $deadline -Start $t0
        foreach ($s in $services) {
            if ($map.ContainsKey($s.Name)) { [void](Conc-SaveIn $dir "$($s.Name).log" (Get-ContainerLog -Container $map[$s.Name])) }
        }
        $ev.Add($dir)

        $notReady = @($services | Where-Object { -not $ready[$_.Name].Ready })
        if ($notReady.Count) {
            $list = @($notReady | ForEach-Object { "$($_.Name) ($($ready[$_.Name].Why))" })
            $msg = "not serving: $($list -join ', ')"
            if ($up.ExitCode -ne 0) { $msg = "compose up exited $($up.ExitCode) ($(Conc-FirstLine $up.StdErr)); $msg" }
            $status = 'FAIL'
            if (@($notReady | Where-Object { $ready[$_.Name].Blocked }).Count) { $status = 'BLOCKED' }
            Add-Result -Id 'D-STACK-COLD' -Status $status -Req @('R4') -Message $msg -Evidence @($ev)
            Add-Result -Id 'D-STACK-COLD-IDLE' -Status 'SKIP' -Req @('R4') -Message 'not every service became ready, so there is no idle stack to watch'
            return
        }
        $slow = @($services | Sort-Object { $ready[$_.Name].Secs } -Descending | Select-Object -First 1)[0]
        Add-Result -Id 'D-STACK-COLD' -Status 'PASS' -Req @('R4') -Message ("all 12 logged '[dev-reload] app-ready' from an empty Maven volume with the real entrypoint; slowest {0} after about {1}s" -f $slow.Name, $ready[$slow.Name].Secs) -Evidence @($ev)

        # Only after everything is up, and 30 s more: a service that became
        # ready last must not have its own start counted as a restart.
        Start-Sleep -Seconds 30
        $idle = Conc-Watch-Idle -Map $map -Services $services -Seconds 120
        $iv = Conc-SaveIn $dir 'idle.txt' $idle.Text
        if ($idle.Problems.Count) {
            Add-Result -Id 'D-STACK-COLD-IDLE' -Status 'FAIL' -Req @('R4') -Message ("in 120 s of doing nothing: " + ($idle.Problems -join ' | ')) -Evidence @($iv)
        }
        else {
            Add-Result -Id 'D-STACK-COLD-IDLE' -Status 'PASS' -Req @('R4') -Message '120 s idle: no build, compile, start, exit, restart or DevTools restart in any of the 12, RestartCount unchanged, all still running' -Evidence @($iv)
        }
    }
    finally {
        # Down, but the Maven cache this stack filled is kept (see the end of
        # Invoke-SuiteConcurrency).
        if (-not (Conc-Opt 'KeepTestProject')) { Remove-TestProject -KeepMavenVolume | Out-Null }
    }
}

# D-REAL: the user's own cache, emptied and filled again by the real launcher.
function Conc-Step-Real {
    param($st)
    if (-not (Conc-Opt 'ColdRealMavenVolume')) {
        Add-Result -Id 'D-REAL' -Status 'SKIP' -Req @('R1', 'R4') -Message "not run: it deletes your Maven cache ($($script:RealMavenVol)) and downloads it again - opt in with -ColdRealMavenVolume"
        return
    }
    if ((Conc-Get-ProjectContainers).Count -gt 0) {
        $mem = Test-DockerMemory -NeedBytes 20GB
        if ($mem) {
            Add-Result -Id 'D-REAL' -Status 'BLOCKED' -Req @('R1', 'R4') -Message "$mem - and the test project is still running (-KeepTestProject)"
            return
        }
    }
    $services = @(Get-JavaServices)
    $dir = Conc-New-EvidenceDir 'real'
    $wasRunning = Test-LiveStackRunning
    $launcher = 'sh ./dev'
    if ((Get-Harness).OnWindows) { $launcher = '.\dev.ps1' }

    Conc-Say "D-REAL: $launcher down, docker volume rm $($script:RealMavenVol), $launcher up"
    $down = Conc-Invoke-Launcher -LauncherArgs @('down') -TimeoutSec 900
    $dl = Conc-SaveIn $dir 'launcher-down.txt' ($down.StdOut + $down.StdErr)
    $isDown = ''
    if ($wasRunning) { $isDown = " (your dev stack is down now; $launcher up brings it back)" }
    if ($down.ExitCode -ne 0) {
        Add-Result -Id 'D-REAL' -Status 'FAIL' -Req @('R1', 'R4') -Message "$launcher down exited $($down.ExitCode)" -Evidence @($dl)
        return
    }
    if ((Invoke-Docker @('volume', 'inspect', $script:RealMavenVol) -TimeoutSec 60).ExitCode -eq 0) {
        $rm = Invoke-Docker @('volume', 'rm', $script:RealMavenVol) -TimeoutSec 300
        if ($rm.ExitCode -ne 0) {
            Add-Result -Id 'D-REAL' -Status 'FAIL' -Req @('R1', 'R4') -Message "docker volume rm $($script:RealMavenVol) failed: $(Conc-FirstLine $rm.StdErr)$isDown" -Evidence @($dl)
            return
        }
    }
    try {
        $t0 = [DateTime]::UtcNow
        $deadline = $t0.AddMinutes(45)
        $up = Conc-Invoke-Launcher -LauncherArgs @('up') -TimeoutSec 2700
        $ul = Conc-SaveIn $dir 'launcher-up.txt' ($up.StdOut + $up.StdErr)
        $volBack = (Invoke-Docker @('volume', 'inspect', $script:RealMavenVol) -TimeoutSec 60).ExitCode -eq 0
        if ($up.ExitCode -ne 0 -or -not $volBack) {
            Add-Result -Id 'D-REAL-UP' -Status 'FAIL' -Req @('R1') -Message "$launcher up exited $($up.ExitCode); $($script:RealMavenVol) exists afterwards: $volBack" -Evidence @($ul)
            return
        }
        Add-Result -Id 'D-REAL-UP' -Status 'PASS' -Req @('R1') -Message "$launcher up created $($script:RealMavenVol) again and exited 0" -Evidence @($ul)

        $map = @{}
        foreach ($s in $services) { $map[$s.Name] = "$($script:LiveContainerPrefix)$($s.Name)" }
        $ready = Conc-Wait-AppReady -Map $map -Services $services -Deadline $deadline -Start $t0
        foreach ($s in $services) { [void](Conc-SaveIn $dir "$($s.Name).log" (Get-ContainerLog -Container $map[$s.Name])) }
        $notReady = @($services | Where-Object { -not $ready[$_.Name].Ready })
        if ($notReady.Count) {
            $status = 'FAIL'
            if (@($notReady | Where-Object { $ready[$_.Name].Blocked }).Count) { $status = 'BLOCKED' }
            Add-Result -Id 'D-REAL-READY' -Status $status -Req @('R4') -Message ('not serving: ' + (@($notReady | ForEach-Object { "$($_.Name) ($($ready[$_.Name].Why))" }) -join ', ')) -Evidence @($dir)
        }
        else {
            Add-Result -Id 'D-REAL-READY' -Status 'PASS' -Req @('R4') -Message 'all 12 logged [dev-reload] app-ready from an empty real Maven volume' -Evidence @($dir)
        }
        Conc-Invoke-Scan -Label 'real' -Live -ScanPrefix 'D-REAL-SCAN-' -WrapPrefix 'D-REAL-WRAP-'
    }
    finally {
        # Left as it was found: a stack that was not running goes down again.
        if (-not $wasRunning) { Conc-Invoke-Launcher -LauncherArgs @('down') -TimeoutSec 900 | Out-Null }
    }
}

# ---------------------------------------------------------------------------
# The cold build round
# ---------------------------------------------------------------------------

# Twelve `sh /dev-reload.sh --build-only` runs in the test project, released
# together, and everything they left behind. Also called by the mutation
# suite (with -ExtraArgs '-Daether.syncContext.named.factory=rwlock-local
# -Daether.syncContext.named.nameMapper=gav' and -Fresh), which expects
# .Duplicates -gt 0 - it needs Initialize-TestProject to have run once, which
# -Fresh does.
#
#   -Compiler   mvnd | mvnw, as DEV_COMPILER
#   -ExtraArgs  appended to DEV_MAVEN_EXTRA_ARGS after -C (strict checksums)
#   -Label      names the containers (hct-build-<label>-<svc>) and the
#               evidence directory (<suite>/round-<label>)
#   -Fresh      empty test Maven volume and project volumes first
#
# Returns an object:
#   Status        PASS | FAIL | BLOCKED - exit codes, error lines, duplicates
#                 and the barrier; Blocked says why when BLOCKED
#   Failures      what went wrong outside the builds (start, barrier, timeout)
#   Services      per service: Name, Rc, RcText, Secs, MainClass,
#                 ExpectedMain, MainOk, CpCheck, CpOk, ErrorHits,
#                 WrapperLines ('[dev-reload] wrapper:' lines), OomKilled,
#                 TimedOut, Log
#   AllRcZero, MainOk, CpOk
#   ErrorHits     "<svc>: <line>" for every error-pattern line
#   Downloads     'Downloaded from' lines in all twelve logs; DistinctUrls
#   Downloading   'Downloading from' lines
#   Duplicates    ARTIFACT urls downloaded more than once across the logs;
#                 DuplicateUrls lists them (Url, Count, Services);
#                 MetadataDuplicates counts maven-metadata ones separately
#   WrapperInstalls  fetches of the Maven distribution (build-once.sh shim)
#   WrapperMarker    mvnw's "Couldn't find MAVEN_HOME..." lines
#   PartialRemoved   dev-reload.sh's "removing the incomplete Maven install"
#   StubRan          runs of the seeded incomplete install (must be 0)
#   OomKilled     services whose container was OOM-killed
#   EvidenceDir, Evidence, BarrierSec, DurationSec, StartedCount, ReadyCount
function Conc-Invoke-ColdBuildRound {
    param(
        [Parameter(Mandatory)][ValidateSet('mvnd', 'mvnw')][string] $Compiler,
        [AllowEmptyString()][string] $ExtraArgs = '',
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.-]*$')][string] $Label,
        [switch] $Fresh,
        [string] $EvidenceSuite = '',
        [int] $TimeoutSec = 2700
    )
    if (-not $EvidenceSuite) {
        $EvidenceSuite = 'concurrency'
        if ($script:CurrentSuite) { $EvidenceSuite = $script:CurrentSuite }
    }
    $services = @(Get-JavaServices)
    $round = [pscustomobject]@{
        Label = $Label; Compiler = $Compiler; ExtraArgs = $ExtraArgs
        EvidenceDir = ''; Evidence = [System.Collections.Generic.List[string]]::new()
        Status = 'FAIL'; Blocked = ''; Failures = [System.Collections.Generic.List[string]]::new()
        Services = [System.Collections.Generic.List[object]]::new()
        StartedCount = 0; ReadyCount = 0; BarrierSec = 0; DurationSec = 0
        AllRcZero = $false; MainOk = $false; CpOk = $false
        ErrorHits = [System.Collections.Generic.List[string]]::new()
        Downloads = 0; Downloading = 0; DistinctUrls = 0
        Duplicates = 0; DuplicateUrls = @(); MetadataDuplicates = 0
        WrapperInstalls = 0; WrapperMarker = 0; PartialRemoved = 0; StubRan = 0
        OomKilled = @()
    }
    if ($Fresh) {
        $why = Initialize-TestProject
        if (-not $why) { $why = Conc-Reset-TestProject }
        if ($why) {
            $round.Failures.Add("could not start from empty volumes: $why")
            return $round
        }
    }
    $dir = Conc-New-EvidenceDir -Name "round-$Label" -Suite $EvidenceSuite
    $round.EvidenceDir = $dir
    $extra = ('-C ' + $ExtraArgs).Trim()
    $names = [ordered]@{}
    foreach ($s in $services) { $names[$s.Name] = "hct-build-$Label-$($s.Name)" }
    Conc-Remove-Containers @($names.Values)

    # -- start all twelve; each waits at the barrier -------------------------
    $started = [System.Collections.Generic.List[string]]::new()
    foreach ($s in $services) {
        $ca = @('run', '-d', '--no-deps', '-T', '--name', $names[$s.Name],
            '-e', 'DEV_MAVEN_QUIET=0', '-e', "DEV_COMPILER=$Compiler", '-e', 'MVNW_VERBOSE=true',
            '-e', "DEV_MAVEN_EXTRA_ARGS=$extra", '-v', "$($dir):/out",
            '--entrypoint', 'sh', $s.Name, '/test/container/build-once.sh', $s.Name)
        $r = Invoke-TestCompose -ComposeArgs $ca -TimeoutSec 300
        if ($r.ExitCode -eq 0) { $started.Add($s.Name) }
        else { $round.Failures.Add("$($s.Name): compose run exited $($r.ExitCode): $(Conc-FirstLine $r.StdErr)") }
    }
    $round.StartedCount = $started.Count

    # -- the barrier ----------------------------------------------------------
    $t0 = [DateTime]::UtcNow
    $limit = $t0.AddSeconds(600)
    $lastCheck = $t0
    $expected = [System.Collections.Generic.List[string]]::new()
    foreach ($n in $started) { $expected.Add($n) }
    while ($true) {
        $waiting = @($expected | Where-Object { -not [System.IO.File]::Exists((Join-Path $dir "$_.ready")) })
        if ($waiting.Count -eq 0 -or [DateTime]::UtcNow -gt $limit) { break }
        # A container that died before its ready file must not hold the
        # other eleven at the barrier for ten minutes.
        if (([DateTime]::UtcNow - $lastCheck).TotalSeconds -ge 10) {
            $lastCheck = [DateTime]::UtcNow
            foreach ($n in $waiting) {
                $stt = Conc-Get-ContainerState $names[$n]
                if (-not $stt -or $stt.Status -ne 'running') {
                    [void]$expected.Remove($n)
                    $what = 'gone'
                    if ($stt) { $what = $stt.Status }
                    $round.Failures.Add("${n}: the container stopped before it reached the barrier ($what)")
                }
            }
        }
        Start-Sleep -Milliseconds 500
    }
    $ready = @($started | Where-Object { [System.IO.File]::Exists((Join-Path $dir "$_.ready")) })
    $round.ReadyCount = $ready.Count
    [System.IO.File]::WriteAllText((Join-Path $dir 'GO'), "go`n")
    $round.BarrierSec = [int]([DateTime]::UtcNow - $t0).TotalSeconds
    if ($ready.Count -lt $services.Count) {
        $round.Failures.Add("barrier: only $($ready.Count) of $($services.Count) builds were ready to start together")
    }
    Conc-Say "round ${Label}: $($ready.Count) builds released together; waiting (at most $([int]($TimeoutSec / 60)) min)"

    # -- wait for every one, bounded ------------------------------------------
    $goAt = [DateTime]::UtcNow
    $until = $goAt.AddSeconds($TimeoutSec)
    $timedOut = [System.Collections.Generic.List[string]]::new()
    foreach ($n in $started) {
        $left = [int][Math]::Max(5, ($until - [DateTime]::UtcNow).TotalSeconds)
        $w = Invoke-Docker @('wait', $names[$n]) -TimeoutSec $left
        if ($w.TimedOut) { $timedOut.Add($n) }
    }
    $round.DurationSec = [int]([DateTime]::UtcNow - $goAt).TotalSeconds
    # A build that hangs is most likely waiting on a lock: the kernel's lock
    # table and every JVM's threads say who holds what.
    foreach ($n in $timedOut) {
        $round.Failures.Add("${n}: still running after $TimeoutSec s")
        $d = Invoke-Docker @('exec', $names[$n], 'sh', '/test/container/build-once.sh', '--diag') -TimeoutSec 300
        $round.Evidence.Add((Conc-SaveIn $dir "$n.diag.txt" ($d.StdOut + $d.StdErr)))
    }

    # -- collect --------------------------------------------------------------
    $urlCount = [System.Collections.Generic.Dictionary[string, int]]::new([System.StringComparer]::Ordinal)
    $urlWho = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
    $blockedHits = [System.Collections.Generic.List[string]]::new()
    foreach ($s in $services) {
        $n = $s.Name
        $cname = $names[$n]
        $stt = Conc-Get-ContainerState $cname
        if ($stt) {
            $dl = Invoke-Docker @('logs', $cname) -TimeoutSec 120
            [void](Conc-SaveIn $dir "$n.docker.txt" ($dl.StdOut + $dl.StdErr))
        }
        $logPath = Join-Path $dir "$n.log"
        $log = Conc-ReadText $logPath
        $rc = Conc-ReadInt (Join-Path $dir "$n.rc")
        $cpLine = [regex]::Match((Conc-ReadText (Join-Path $dir "$n.cp-check")), '(?m)^CP-CHECK [^\r\n]*').Value
        $mains = [regex]::Matches($log, '(?m)^\[dev-reload\] main-class: (\S+)')
        $main = ''
        if ($mains.Count) { $main = $mains[$mains.Count - 1].Groups[1].Value }
        $hits = @([regex]::Matches($log, "(?m)^[^\r\n]*(?:$($script:ConcErrorPattern))[^\r\n]*") | ForEach-Object { $_.Value.Trim() })
        foreach ($x in $hits) { $round.ErrorHits.Add("${n}: $x") }
        foreach ($m in [regex]::Matches($log, 'Downloaded from [^\s:]+: (\S+)')) {
            $u = $m.Groups[1].Value
            $round.Downloads = $round.Downloads + 1
            if ($urlCount.ContainsKey($u)) {
                $urlCount[$u] = $urlCount[$u] + 1
                $urlWho[$u] = $urlWho[$u] + ",$n"
            }
            else {
                $urlCount[$u] = 1
                $urlWho[$u] = $n
            }
        }
        $round.Downloading = $round.Downloading + [regex]::Matches($log, 'Downloading from [^\s:]+: \S').Count
        $round.WrapperMarker = $round.WrapperMarker + [regex]::Matches($log, "Couldn't find MAVEN_HOME, downloading and installing it").Count
        $round.WrapperInstalls = $round.WrapperInstalls + [regex]::Matches($log, '(?m)^HC-FETCH \S+ [^\r\n]*apache-maven-[^\s/]*-bin\.').Count
        $round.PartialRemoved = $round.PartialRemoved + [regex]::Matches($log, '\[dev-reload\] wrapper: removing the incomplete Maven install').Count
        $round.StubRan = $round.StubRan + [regex]::Matches($log, 'HC-PARTIAL-DIST-STUB').Count
        $wrapperLines = @([regex]::Matches($log, '(?m)^\[dev-reload\] wrapper: [^\r\n]*') | Where-Object { $_.Value -notmatch 'removing the incomplete' }).Count
        foreach ($m in [regex]::Matches($log, "(?mi)^[^\r\n]*(?:$($script:ConcBlockedPattern))[^\r\n]*")) { $blockedHits.Add("${n}: $($m.Value.Trim())") }
        $round.Services.Add([pscustomobject]@{
            Name = $n; Container = $cname; Rc = $rc; RcText = (Conc-RcText $rc)
            Secs = (Conc-ReadInt (Join-Path $dir "$n.secs"))
            MainClass = $main; ExpectedMain = $s.Main; MainOk = ($main -eq $s.Main)
            CpCheck = $cpLine; CpOk = $cpLine.StartsWith('CP-CHECK ok')
            ErrorHits = $hits.Count; WrapperLines = $wrapperLines
            OomKilled = [bool]($stt -and $stt.OomKilled)
            TimedOut = $timedOut.Contains($n)
            Log = $logPath
        })
    }
    Conc-Remove-Containers @($names.Values)

    # -- judge ----------------------------------------------------------------
    $recs = @($round.Services)
    $round.AllRcZero = ($recs.Count -eq $services.Count) -and (@($recs | Where-Object { $_.Rc -ne 0 }).Count -eq 0)
    $round.MainOk = ($recs.Count -eq $services.Count) -and (@($recs | Where-Object { -not $_.MainOk }).Count -eq 0)
    $round.CpOk = ($recs.Count -eq $services.Count) -and (@($recs | Where-Object { -not $_.CpOk }).Count -eq 0)
    $round.DistinctUrls = $urlCount.Count
    $dups = @($urlCount.Keys | Where-Object { $urlCount[$_] -gt 1 } | Sort-Object -Property @{ Expression = { $urlCount[$_] }; Descending = $true }, @{ Expression = { $_ } })
    $artifactDups = @($dups | Where-Object { $_ -notmatch 'maven-metadata[^/]*\.xml$' })
    $round.Duplicates = $artifactDups.Count
    $round.MetadataDuplicates = $dups.Count - $artifactDups.Count
    $round.DuplicateUrls = @($artifactDups | ForEach-Object { [pscustomobject]@{ Url = $_; Count = $urlCount[$_]; Services = $urlWho[$_] } })
    $round.OomKilled = @($recs | Where-Object { $_.OomKilled } | ForEach-Object { $_.Name })

    $buildFailing = (-not $round.AllRcZero) -or $round.ErrorHits.Count -gt 0 -or $round.Failures.Count -gt 0
    if ($buildFailing -and $round.OomKilled.Count) {
        $round.Blocked = "OOM-killed: $($round.OomKilled -join ', ') - the Docker VM needs more memory"
    }
    elseif ($buildFailing -and $blockedHits.Count) {
        $round.Blocked = "the network or the remote repository failed the build, not the setup ($(Conc-Clip $blockedHits[0] 160))"
    }
    $round.Status = 'PASS'
    if ($round.Blocked) { $round.Status = 'BLOCKED' }
    elseif ($buildFailing -or $round.Duplicates -gt 0) { $round.Status = 'FAIL' }

    # -- evidence -------------------------------------------------------------
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("round $Label - compiler $Compiler - DEV_MAVEN_EXTRA_ARGS=$extra")
    [void]$sb.AppendLine("started $($round.StartedCount), ready at the barrier $($round.ReadyCount) after $($round.BarrierSec)s, all done $($round.DurationSec)s after GO")
    [void]$sb.AppendLine("status $($round.Status) $($round.Blocked)")
    [void]$sb.AppendLine("downloads $($round.Downloads) of $($round.DistinctUrls) urls; artifact duplicates $($round.Duplicates); metadata duplicates $($round.MetadataDuplicates); 'Downloading from' $($round.Downloading)")
    [void]$sb.AppendLine("wrapper: fetches $($round.WrapperInstalls), install lines $($round.WrapperMarker), partial removed $($round.PartialRemoved), stub ran $($round.StubRan)")
    foreach ($f in $round.Failures) { [void]$sb.AppendLine("failure: $f") }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("service`trc`tsecs`tmain class`tclasspath`terror lines`toom`ttimed out")
    foreach ($x in $recs) {
        [void]$sb.AppendLine(("{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}`t{7}" -f $x.Name, $x.RcText, $x.Secs, $x.MainClass, $x.CpCheck, $x.ErrorHits, $x.OomKilled, $x.TimedOut))
    }
    $round.Evidence.Add((Conc-SaveIn $dir 'summary.txt' $sb.ToString()))
    $tsv = @($urlCount.Keys | Sort-Object -Property @{ Expression = { $urlCount[$_] }; Descending = $true }, @{ Expression = { $_ } } |
        ForEach-Object { "$($urlCount[$_])`t$_`t$($urlWho[$_])" })
    $round.Evidence.Add((Conc-SaveIn $dir 'downloads.tsv' ("count`turl`tservices`n" + ($tsv -join "`n"))))
    if ($round.ErrorHits.Count) { $round.Evidence.Add((Conc-SaveIn $dir 'errors.txt' ($round.ErrorHits -join "`n"))) }
    if ($blockedHits.Count) { $round.Evidence.Add((Conc-SaveIn $dir 'blocked.txt' ($blockedHits -join "`n"))) }
    $round.Evidence.Add($dir)
    return $round
}

# The rows for one round: the builds themselves (R4), the main classes (R6)
# and the classpaths (R5).
function Conc-Report-Round {
    param([Parameter(Mandatory)] $Round, [Parameter(Mandatory)][string] $Id, [switch] $Warm, [string[]] $Extra = @())
    $ev = @($Round.Evidence)
    $recs = @($Round.Services)
    $total = @(Get-JavaServices).Count
    $problems = [System.Collections.Generic.List[string]]::new()
    foreach ($f in $Round.Failures) { $problems.Add($f) }
    $bad = @($recs | Where-Object { $_.Rc -ne 0 })
    if ($bad.Count) { $problems.Add('exit code not 0: ' + (@($bad | ForEach-Object { "$($_.Name)=$($_.RcText)" }) -join ', ')) }
    if ($Round.ErrorHits.Count) { $problems.Add("$($Round.ErrorHits.Count) error lines, first: $(Conc-Clip $Round.ErrorHits[0] 200)") }
    if ($Round.Duplicates) {
        $top = @($Round.DuplicateUrls | Select-Object -First 3 | ForEach-Object { "$($_.Url) x$($_.Count)" })
        $problems.Add("$($Round.Duplicates) artifacts were downloaded more than once across the logs, e.g. $($top -join '; ')")
    }
    if (-not $Warm -and $Round.Downloads -eq 0 -and $Round.StartedCount -gt 0) {
        $problems.Add("no 'Downloaded from' line in any log: transfer logging is not visible (DEV_MAVEN_QUIET=0 not honoured?), so duplicates cannot be counted")
    }
    if ($Warm -and $Round.Downloading -gt 0) { $problems.Add("$($Round.Downloading) 'Downloading from' lines on a warm volume") }
    foreach ($x in $Extra) { if ($x) { $problems.Add($x) } }

    $what = "$($Round.Compiler): $($Round.ReadyCount) builds released together"
    if ($problems.Count) {
        $status = 'FAIL'
        $msg = $problems -join ' | '
        if ($Round.Blocked) { $status = 'BLOCKED'; $msg = "$($Round.Blocked) | $msg" }
        Add-Result -Id $Id -Status $status -Req @('R4') -Message "$what - $msg" -Evidence $ev
    }
    else {
        $dl = "$($Round.Downloads) downloads of $($Round.DistinctUrls) URLs, no artifact twice"
        if ($Warm) { $dl = "no downloads, the repository unchanged" }
        if ($Round.MetadataDuplicates) { $dl += " ($($Round.MetadataDuplicates) maven-metadata files were fetched more than once)" }
        $status = 'PASS'
        $note = ''
        if (@($Round.OomKilled).Count) { $status = 'WARN'; $note = "; OOM-killed: $($Round.OomKilled -join ', ')" }
        Add-Result -Id $Id -Status $status -Req @('R4') -Message "$what - all exit 0 within $($Round.DurationSec)s, 0 error lines, $dl$note" -Evidence $ev
    }

    $wrong = @($recs | Where-Object { -not $_.MainOk })
    if ($recs.Count -eq $total -and $wrong.Count -eq 0) {
        Add-Result -Id "$Id-MAIN" -Status 'PASS' -Req @('R6') -Message "all $total logged '[dev-reload] main-class:' with the class the table has for them" -Evidence $ev
    }
    else {
        $status = 'FAIL'
        if ($Round.Blocked) { $status = 'BLOCKED' }
        $list = @($wrong | ForEach-Object { "$($_.Name) got '$($_.MainClass)', expected $($_.ExpectedMain)" })
        if ($recs.Count -lt $total) { $list += "only $($recs.Count) of $total builds reported" }
        Add-Result -Id "$Id-MAIN" -Status $status -Req @('R6') -Message ($list -join '; ') -Evidence $ev
    }

    $cpBad = @($recs | Where-Object { -not $_.CpOk })
    if ($recs.Count -eq $total -and $cpBad.Count -eq 0) {
        $entries = 0
        foreach ($x in $recs) { $m = [regex]::Match($x.CpCheck, 'entries=(\d+)'); if ($m.Success) { $entries += [int]$m.Groups[1].Value } }
        Add-Result -Id "$Id-CP" -Status 'PASS' -Req @('R5') -Message "every dev-classpath.txt entry of all $total exists and lies under /root/.m2/repository, the shared volume ($entries entries)" -Evidence $ev
    }
    else {
        $status = 'FAIL'
        if ($Round.Blocked) { $status = 'BLOCKED' }
        $list = @($cpBad | ForEach-Object {
            $why = $_.CpCheck
            if (-not $why) { $why = 'no check' }
            "$($_.Name): $why"
        })
        Add-Result -Id "$Id-CP" -Status $status -Req @('R5') -Message ($list -join '; ') -Evidence $ev
    }
}

# D-WRAP-PARTIAL: the incomplete install planted before the first round was
# removed by exactly one container and never executed by any.
function Conc-Report-PartialWrapper {
    param([Parameter(Mandatory)] $Round, [AllowNull()][AllowEmptyString()][string] $Seed)
    $ev = @($Round.Evidence)
    if (-not $Seed) {
        Add-Result -Id 'D-WRAP-PARTIAL' -Status 'FAIL' -Req @('R3') -Message 'could not plant the incomplete install (build-once.sh --seed-partial-wrapper failed), so the recovery was not tested' -Evidence $ev
        return
    }
    if ($Round.StubRan -gt 0) {
        Add-Result -Id 'D-WRAP-PARTIAL' -Status 'FAIL' -Req @('R3') -Message "the incomplete install at $Seed was EXECUTED $($Round.StubRan) times: mvnw trusted a directory that merely exists" -Evidence $ev
    }
    elseif ($Round.PartialRemoved -eq 1) {
        Add-Result -Id 'D-WRAP-PARTIAL' -Status 'PASS' -Req @('R3') -Message "the incomplete install planted at $Seed (bin/ and mvnw.url only) was removed by one container - '[dev-reload] wrapper: removing the incomplete Maven install' - and run by none; the WRAP rows of the scan show what replaced it" -Evidence $ev
    }
    elseif ($Round.PartialRemoved -eq 0) {
        Add-Result -Id 'D-WRAP-PARTIAL' -Status 'FAIL' -Req @('R3') -Message "no container logged 'removing the incomplete Maven install' for the one planted at $Seed" -Evidence $ev
    }
    else {
        Add-Result -Id 'D-WRAP-PARTIAL' -Status 'FAIL' -Req @('R3') -Message "'removing the incomplete Maven install' was logged $($Round.PartialRemoved) times: installs kept failing and being cleaned up again" -Evidence $ev
    }
}

# D-WRAP-ONCE: of twelve containers installing the wrapper's Maven from an
# empty volume at the same moment, exactly one downloads it.
function Conc-Report-WrapperOnce {
    param([Parameter(Mandatory)] $Round)
    $ev = @($Round.Evidence)
    $n = $Round.WrapperInstalls
    $m = $Round.WrapperMarker
    $counts = "$n fetches of apache-maven-*-bin, $m 'Couldn't find MAVEN_HOME, downloading and installing it' lines across the $($Round.ReadyCount) logs"
    if ($n -gt 1 -or $m -gt 1) {
        Add-Result -Id 'D-WRAP-ONCE' -Status 'FAIL' -Req @('R3') -Message "the distribution was installed more than once: $counts" -Evidence $ev
    }
    elseif ($m -eq 1) {
        Add-Result -Id 'D-WRAP-ONCE' -Status 'PASS' -Req @('R3') -Message "installed exactly once: $counts" -Evidence $ev
    }
    elseif ($n -eq 1) {
        Add-Result -Id 'D-WRAP-ONCE' -Status 'WARN' -Req @('R3') -Message "downloaded exactly once ($counts) - counted from the fetch itself, because dev-reload.sh's install_wrapper sends mvnw's stdout, and with it that line, to /dev/null" -Evidence $ev
    }
    else {
        Add-Result -Id 'D-WRAP-ONCE' -Status 'FAIL' -Req @('R3') -Message "no container was seen downloading the distribution onto the empty volume ($counts)" -Evidence $ev
    }

    # D-WRAP-READY: once installed, the wrapper must be found READY. Every
    # mvnw-mode container logs one wrapper line at startup; a second one means
    # the build's own ./mvnw call took the install lock and ran mvnw --version
    # again - wrapper_ready did not recognise the install it had just made.
    $again = @($Round.Services | Where-Object { $_.WrapperLines -gt 1 })
    if (@($Round.Services).Count -eq 0) { return }
    if ($again.Count) {
        Add-Result -Id 'D-WRAP-READY' -Status 'WARN' -Req @('R3') -Message ("in {0} of {1} containers the build's ./mvnw call went through the install lock again ({2}): dev-reload.sh's wrapper_ready does not match the installed dist's mvnw.url - mvnw writes the .tar.gz URL there when unzip is missing" -f $again.Count, @($Round.Services).Count, (@($again | Select-Object -First 3 | ForEach-Object { "$($_.Name) x$($_.WrapperLines)" }) -join ', ')) -Evidence $ev
    }
    else {
        Add-Result -Id 'D-WRAP-READY' -Status 'PASS' -Req @('R3') -Message 'after the install, every build found the wrapper ready: one [dev-reload] wrapper line per container' -Evidence $ev
    }
}

# ---------------------------------------------------------------------------
# Single containers
# ---------------------------------------------------------------------------

# One build-once.sh run in the foreground, with no barrier. -Maven runs one
# run_maven call instead of the full --build-only.
function Conc-Invoke-SingleBuild {
    param(
        [Parameter(Mandatory)][string] $Service,
        [Parameter(Mandatory)][ValidateSet('mvnd', 'mvnw')][string] $Compiler,
        [Parameter(Mandatory)][string] $Tag,
        [Parameter(Mandatory)][string] $Dir,
        [AllowEmptyString()][string] $ExtraArgs = '',
        [string[]] $Flags = @(),
        [string[]] $Maven = @(),
        [int] $TimeoutSec = 1800
    )
    $name = "hct-one-$Tag"
    Conc-Remove-Containers @($name)
    $ca = @('run', '--rm', '--no-deps', '-T', '--name', $name,
        '-e', 'DEV_MAVEN_QUIET=0', '-e', "DEV_COMPILER=$Compiler", '-e', 'MVNW_VERBOSE=true',
        '-e', "DEV_MAVEN_EXTRA_ARGS=$ExtraArgs", '-v', "$($Dir):/out",
        '--entrypoint', 'sh', $Service, '/test/container/build-once.sh', $Service, '--no-barrier', '--tag', $Tag) + @($Flags)
    if (@($Maven).Count) { $ca += @('--maven') + @($Maven) }
    $r = Invoke-TestCompose -ComposeArgs $ca -TimeoutSec $TimeoutSec
    # Killing `compose run` does not stop the container it started.
    if ($r.TimedOut) { Conc-Remove-Containers @($name) }
    $logPath = Join-Path $Dir "$Tag.log"
    return [pscustomobject]@{
        Tag      = $Tag
        Rc       = (Conc-ReadInt (Join-Path $Dir "$Tag.rc"))
        Secs     = (Conc-ReadInt (Join-Path $Dir "$Tag.secs"))
        Log      = (Conc-ReadText $logPath)
        LogPath  = $logPath
        CpCheck  = (Conc-ReadText (Join-Path $Dir "$Tag.cp-check"))
        Jcmd     = (Conc-ReadText (Join-Path $Dir "$Tag.jcmd"))
        TimedOut = [bool]$r.TimedOut
    }
}

# D-SCAN (and D-REAL's scan): scan-repo.sh's SCAN-* rows are R4, its WRAP-*
# rows R3. The live compose model has no /test mount, so -Live adds one.
function Conc-Invoke-Scan {
    param([Parameter(Mandatory)][string] $Label, [string] $ScanPrefix = '', [string] $WrapPrefix = '', [switch] $Live)
    if (-not $ScanPrefix) { $ScanPrefix = "D-SCAN-$Label-" }
    if (-not $WrapPrefix) { $WrapPrefix = "D-WRAP-$Label-" }
    $ca = @('run', '--rm', '--no-deps', '-T')
    if ($Live) { $ca += @('-v', "$((Get-Harness).TestRoot):/test:ro") }
    $ca += @('--entrypoint', 'sh', $script:ConcScanService, '/test/container/scan-repo.sh')
    Conc-Say "scan of the Maven volume after '$Label' (a few minutes: every jar is read)"
    if ($Live) { $r = Invoke-LiveCompose -ComposeArgs $ca -TimeoutSec 1800 }
    else { $r = Invoke-TestCompose -ComposeArgs $ca -TimeoutSec 1800 }
    $ev = Save-Evidence -Suite 'concurrency' -Name "scan-$Label.txt" -Content ($r.StdOut + "`n--- stderr`n" + $r.StdErr)
    $lines = @($r.StdOut -split "`r?`n")
    $scan = @($lines | Where-Object { $_ -like "HCRESULT`tSCAN-*" } | ForEach-Object { $_ -replace "^HCRESULT`tSCAN-", "HCRESULT`t" })
    $wrap = @($lines | Where-Object { $_ -like "HCRESULT`tWRAP-*" } | ForEach-Object { $_ -replace "^HCRESULT`tWRAP-", "HCRESULT`t" })
    $n = Import-HcResults -Text ($scan -join "`n") -Req @('R4') -Evidence @($ev) -Prefix $ScanPrefix
    $m = Import-HcResults -Text ($wrap -join "`n") -Req @('R3') -Evidence @($ev) -Prefix $WrapPrefix
    if ($n -eq 0) {
        Add-Result -Id ($ScanPrefix.TrimEnd('-')) -Status 'FAIL' -Req @('R4') -Message "scan-repo.sh reported nothing (exit $($r.ExitCode)): $(Conc-FirstLine $r.StdErr)" -Evidence @($ev)
    }
    if ($m -eq 0 -and $n -gt 0) {
        Add-Result -Id ($WrapPrefix.TrimEnd('-')) -Status 'FAIL' -Req @('R3') -Message 'scan-repo.sh reported nothing about the wrapper install' -Evidence @($ev)
    }
}

# <path> <size> of every jar, pom and sha1 in the test volume.
function Conc-Get-Snapshot {
    $r = Invoke-TestCompose @('run', '--rm', '--no-deps', '-T', '--entrypoint', 'sh', $script:ConcScanService, '/test/container/scan-repo.sh', '--snapshot') -TimeoutSec 900
    $lines = @(($r.StdOut -split "`r?`n") | Where-Object { $_ })
    return [pscustomobject]@{ Ok = ($r.ExitCode -eq 0 -and $lines.Count -gt 0); Text = ($lines -join "`n"); Lines = $lines; Exit = $r.ExitCode }
}

# ---------------------------------------------------------------------------
# The test project and its containers
# ---------------------------------------------------------------------------

# Empty test Maven volume and project volumes - and PROVEN empty: a volume
# still in use survives `volume rm`, and `volume create` would then quietly
# hand the next round a warm cache.
function Conc-Reset-TestProject {
    Remove-TestProject | Out-Null
    if ((Invoke-Docker @('volume', 'inspect', $script:TestMavenVol) -TimeoutSec 60).ExitCode -eq 0) {
        return "$($script:TestMavenVol) could not be removed - is a container still using it?"
    }
    $c = Invoke-Docker @('volume', 'create', $script:TestMavenVol) -TimeoutSec 60
    if ($c.ExitCode -ne 0) { return "could not create $($script:TestMavenVol): $(Conc-FirstLine $c.StdErr)" }
    return $null
}

# The same probe dev-reload.sh's choose_compiler makes.
function Conc-Test-Mvnd {
    $r = Invoke-TestCompose @('run', '--rm', '--no-deps', '-T', '--entrypoint', 'sh', $script:ConcLockService, '-c',
        'command -v mvnd >/dev/null 2>&1 && mvnd -Dmvnd.daemonStorage=/tmp/mvnd --version') -TimeoutSec 300
    return ($r.ExitCode -eq 0)
}

# Returns the planted directory, or $null.
function Conc-Seed-PartialWrapper {
    $r = Invoke-TestCompose @('run', '--rm', '--no-deps', '-T', '--entrypoint', 'sh', $script:ConcLockService, '/test/container/build-once.sh', '--seed-partial-wrapper') -TimeoutSec 300
    $m = [regex]::Match($r.StdOut, '(?m)^SEEDED (\S+)')
    if ($r.ExitCode -eq 0 -and $m.Success) { return $m.Groups[1].Value }
    return $null
}

# The version whose lock file the holder test takes: the parent every service
# builds on, read from the checkout (read-only) rather than assumed.
function Conc-Get-BootVersion {
    $svc = Get-JavaService $script:ConcLockService
    $pom = Join-Path (Get-RepoPath $svc.Repo) 'pom.xml'
    if (Test-Path -LiteralPath $pom -PathType Leaf) {
        $m = [regex]::Match([System.IO.File]::ReadAllText($pom), '(?s)<parent>.*?<artifactId>spring-boot-starter-parent</artifactId>.*?<version>\s*([^<\s]+)\s*</version>.*?</parent>')
        if ($m.Success) { return $m.Groups[1].Value }
    }
    return '4.1.1'
}

# service -> container name of the project's own (not run) containers.
function Conc-Get-ProjectContainers {
    param([string] $Project = $script:TestProject)
    $r = Invoke-Docker @('ps', '-a', '--filter', "label=com.docker.compose.project=$Project", '--filter', 'label=com.docker.compose.oneoff=False',
        '--format', '{{.Names}}|{{.Label "com.docker.compose.service"}}') -TimeoutSec 60
    $map = @{}
    foreach ($l in ($r.StdOut -split "`r?`n")) {
        $p = @($l.Trim() -split '\|')
        if ($p.Count -eq 2 -and $p[0] -and $p[1]) { $map[$p[1]] = $p[0] }
    }
    return $map
}

# Until every service logs app-ready, or cannot any more: the container
# stopped, dev-reload.sh gave up (fatal, restart-exhausted), or the build
# failed four times - the first and all three retries. Returns service ->
# Ready, Secs (since -Start), Why, Blocked.
function Conc-Wait-AppReady {
    param([Parameter(Mandatory)][hashtable] $Map, [Parameter(Mandatory)] $Services, [Parameter(Mandatory)][DateTime] $Deadline, [Parameter(Mandatory)][DateTime] $Start)
    $res = @{}
    $pending = [System.Collections.Generic.List[string]]::new()
    foreach ($s in @($Services)) {
        if ($Map.ContainsKey($s.Name)) { $pending.Add($s.Name) }
        else { $res[$s.Name] = [pscustomobject]@{ Ready = $false; Secs = 0; Why = 'no container'; Blocked = $false } }
    }
    while ($pending.Count -gt 0) {
        foreach ($n in @($pending)) {
            $log = Get-ContainerLog -Container $Map[$n]
            $secs = [int]([DateTime]::UtcNow - $Start).TotalSeconds
            $why = ''
            $stt = $null
            if ($log -match '\[dev-reload\] app-ready:') {
                $res[$n] = [pscustomobject]@{ Ready = $true; Secs = $secs; Why = ''; Blocked = $false }
                [void]$pending.Remove($n)
                continue
            }
            $gaveUp = [regex]::Match($log, '\[dev-reload\] (restart-exhausted|fatal):[^\r\n]*')
            if ($gaveUp.Success) { $why = $gaveUp.Value.Trim() }
            elseif ([regex]::Matches($log, '\[dev-reload\] build-failed:').Count -ge 4 -and $log -notmatch '\[dev-reload\] build-ok:') { $why = 'the build failed, and so did all three retries' }
            else {
                $stt = Conc-Get-ContainerState $Map[$n]
                if (-not $stt) { $why = 'the container is gone' }
                elseif ($stt.Status -ne 'running') { $why = "the container is $($stt.Status) (exit $($stt.ExitCode), OOM-killed $($stt.OomKilled))" }
            }
            if ($why) {
                $blocked = ($log -match "(?i)(?:$($script:ConcBlockedPattern))")
                if ($stt -and $stt.OomKilled) { $blocked = $true }
                $res[$n] = [pscustomobject]@{ Ready = $false; Secs = $secs; Why = $why; Blocked = $blocked }
                [void]$pending.Remove($n)
            }
        }
        if ($pending.Count -eq 0 -or [DateTime]::UtcNow -gt $Deadline) { break }
        Start-Sleep -Seconds 30
    }
    foreach ($n in $pending) {
        $res[$n] = [pscustomobject]@{ Ready = $false; Secs = [int]($Deadline - $Start).TotalSeconds; Why = 'no app-ready within the time limit'; Blocked = $false }
    }
    return $res
}

# Every service's log since the window opened, and its RestartCount before
# and after.
function Conc-Watch-Idle {
    param([Parameter(Mandatory)][hashtable] $Map, [Parameter(Mandatory)] $Services, [int] $Seconds = 120)
    $since = Get-DockerNow
    if (-not $since) { $since = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture) }
    $before = @{}
    foreach ($s in @($Services)) {
        $stt = Conc-Get-ContainerState $Map[$s.Name]
        $before[$s.Name] = -1
        if ($stt) { $before[$s.Name] = $stt.RestartCount }
    }
    Start-Sleep -Seconds $Seconds
    $problems = [System.Collections.Generic.List[string]]::new()
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("idle window: $Seconds s from $since (Docker VM clock)")
    foreach ($s in @($Services)) {
        $n = $s.Name
        $log = Get-ContainerLog -Container $Map[$n] -Since $since
        $hits = @([regex]::Matches($log, "(?m)^[^\r\n]*(?:$($script:ConcIdlePattern))[^\r\n]*") | ForEach-Object { $_.Value.Trim() })
        $stt = Conc-Get-ContainerState $Map[$n]
        [void]$sb.AppendLine("== $n ($($hits.Count) markers)")
        foreach ($x in $hits) { [void]$sb.AppendLine("   $x") }
        if ($hits.Count) { $problems.Add("${n}: $(Conc-Clip $hits[0] 140)") }
        if (-not $stt -or $stt.Status -ne 'running') { $problems.Add("${n}: no longer running") }
        elseif ($stt.RestartCount -ne $before[$n]) { $problems.Add("${n}: RestartCount $($before[$n]) -> $($stt.RestartCount)") }
    }
    return [pscustomobject]@{ Problems = $problems; Text = $sb.ToString() }
}

# The real launcher, as a user runs it: .\dev.ps1 on Windows, sh ./dev
# elsewhere.
function Conc-Invoke-Launcher {
    param([Parameter(Mandatory)][string[]] $LauncherArgs, [int] $TimeoutSec = 900)
    $h = Get-Harness
    if ($h.OnWindows) {
        $pwsh = (Get-Process -Id $PID).Path
        return Invoke-Native -FilePath $pwsh -ArgumentList (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $h.InfraRoot 'dev.ps1')) + $LauncherArgs) -TimeoutSec $TimeoutSec
    }
    $sh = (Get-Command sh -CommandType Application | Select-Object -First 1).Source
    return Invoke-Native -FilePath $sh -ArgumentList (@((Join-Path $h.InfraRoot 'dev')) + $LauncherArgs) -TimeoutSec $TimeoutSec
}

function Conc-Remove-Containers {
    param([string[]] $Names = @())
    foreach ($n in @($Names)) {
        if (-not $n) { continue }
        if ((Invoke-Docker @('container', 'inspect', '--format', '{{.Id}}', $n) -TimeoutSec 60).ExitCode -eq 0) {
            Invoke-Docker @('rm', '-f', $n) -TimeoutSec 120 | Out-Null
        }
    }
}

function Conc-Get-ContainerState {
    param([Parameter(Mandatory)][string] $Name)
    $r = Invoke-Docker @('inspect', '--format', '{{.State.Status}}|{{.State.ExitCode}}|{{.State.OOMKilled}}|{{.RestartCount}}', $Name) -TimeoutSec 60
    if ($r.ExitCode -ne 0) { return $null }
    $p = @($r.StdOut.Trim() -split '\|')
    if ($p.Count -lt 4) { return $null }
    $code = 0
    $restarts = 0
    [void][int]::TryParse($p[1], [ref] $code)
    [void][int]::TryParse($p[3], [ref] $restarts)
    return [pscustomobject]@{ Status = $p[0]; ExitCode = $code; OomKilled = ($p[2] -eq 'true'); RestartCount = $restarts }
}

# True once the container's log matches; false on timeout, or once the
# container has stopped without it.
function Conc-Wait-ContainerLog {
    param([Parameter(Mandatory)][string] $Name, [Parameter(Mandatory)][string] $Pattern, [int] $TimeoutSec = 180)
    $until = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
    while ($true) {
        if ((Get-ContainerLog -Container $Name) -match $Pattern) { return $true }
        $stt = Conc-Get-ContainerState $Name
        if (-not $stt -or $stt.Status -ne 'running') { return [bool]((Get-ContainerLog -Container $Name) -match $Pattern) }
        if ([DateTime]::UtcNow -gt $until) { return $false }
        Start-Sleep -Seconds 1
    }
}

function Conc-Get-Volumes {
    $r = Invoke-Docker @('volume', 'ls', '--format', '{{.Name}}') -TimeoutSec 60
    return @(($r.StdOut -split "`r?`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

# ---------------------------------------------------------------------------
# Small things
# ---------------------------------------------------------------------------

function Conc-Opt {
    param([Parameter(Mandatory)][string] $Name)
    $o = (Get-Harness).Options
    return [bool]($o -and $o.ContainsKey($Name) -and $o[$Name])
}

# Progress, not a verdict - the verdicts are Add-Result rows.
function Conc-Say {
    param([string] $Text)
    Write-Host "    $Text" -ForegroundColor DarkGray
}

# A fresh directory under the suite's evidence directory: a name already used
# in this run gets -2, -3, ... rather than mixing two rounds' files (and a
# stale GO would release the next round's barrier at once).
function Conc-New-EvidenceDir {
    param([Parameter(Mandatory)][string] $Name, [string] $Suite = 'concurrency')
    $base = Get-EvidenceDir $Suite
    $d = Join-Path $base $Name
    $i = 2
    while (Test-Path -LiteralPath $d) {
        $d = Join-Path $base "$Name-$i"
        $i++
    }
    [void][System.IO.Directory]::CreateDirectory($d)
    return $d
}

# Save-Evidence into a directory made by Conc-New-EvidenceDir.
function Conc-SaveIn {
    param([Parameter(Mandatory)][string] $Dir, [Parameter(Mandatory)][string] $Name, [AllowNull()][AllowEmptyString()][string] $Content)
    $rel = [System.IO.Path]::GetRelativePath((Get-Harness).ResultsDir, $Dir)
    return (Save-Evidence -Suite $rel -Name $Name -Content $Content)
}

function Conc-ReadText {
    param([Parameter(Mandatory)][string] $Path)
    if ([System.IO.File]::Exists($Path)) { return [System.IO.File]::ReadAllText($Path) }
    return ''
}

# $null when the file is missing or does not hold a number: "no exit code" is
# not the same thing as exit code 0.
function Conc-ReadInt {
    param([Parameter(Mandatory)][string] $Path)
    $v = 0
    if ([int]::TryParse((Conc-ReadText $Path).Trim(), [ref] $v)) { return $v }
    return $null
}

function Conc-RcText {
    param([AllowNull()] $Rc)
    if ($null -eq $Rc) { return 'none' }
    return "$Rc"
}

function Conc-Clip {
    param([AllowNull()][AllowEmptyString()][string] $Text, [int] $Max = 200)
    if (-not $Text) { return '' }
    if ($Text.Length -le $Max) { return $Text }
    return $Text.Substring(0, $Max) + '...'
}

function Conc-FirstLine {
    param([AllowNull()][AllowEmptyString()][string] $Text, [int] $Max = 200)
    $l = @(($Text -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -First 1)
    if ($l.Count -eq 0) { return '' }
    return (Conc-Clip $l[0].Trim() $Max)
}
