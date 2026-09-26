# Suite G, "reload": live reload semantics on the running dev stack - deeply
# on user-service, lightly on all twelve. Loaded by test/run.ps1 after
# lib/Harness.ps1; read that file's CONVENTIONS first. The entry point is
# Invoke-SuiteReload, and every helper here is named Reload-*. ASCII only, and
# nothing Windows PowerShell 5.1 cannot parse: suite A parses every .ps1 here
# with 5.1.
#
# Requirements: R7 (every kind of change is picked up exactly once, at the
# cheapest level, and a broken edit leaves the application serving), R6 (the
# classpath a new JVM runs with is the one Maven resolves), R11 (the new JVM
# owns the debug port, and a debugger survives a DevTools restart), and R10
# for the restore rows (the service repositories are left as they were).
#
# Results, in the order they run. user-service first:
#
#   G-PRE         docker, .env, a CLEAN home-crew-user-service (refused
#                 otherwise, with what to do), the container mounting THIS
#                 checkout, the application serving. When it is not running
#                 it is started with the real launcher - .\dev.ps1 up
#                 user-service on Windows, sh ./dev up user-service elsewhere
#                 (G-PRE-UP) - and waited for.
#   G-01          a new probe class: one DevTools restart, same pid, HC-PROBE
#                 HcProbeA v1 printed
#   G-02          modified: one restart, only v2 printed
#   G-03          renamed to HcProbeB: one restart, HcProbeA.class gone from
#                 /app/target/classes, only HcProbeB printed
#   G-04          deleted: one restart, the class gone, no marker
#   G-05          a syntax error: no restart, compile-failed and
#                 classes-restored logged - and again by dev-reload.sh's one
#                 automatic retry 30s later, which the case waits for, so that
#                 the fix below cannot race it - /actuator/health answering 200
#                 every second throughout, the trigger file untouched and every
#                 file in target/classes byte for byte as before
#   G-05-FIX      the fix: exactly one restart, and it is served
#   G-06          src/main/resources/hc-probe.txt added: one restart, copied
#   G-06-DEL      deleted: one restart, the copy pruned (resource-removed)
#   G-07          a broken file under src/test: nothing compiles at all
#   G-08          with it still there, an XML comment appended to pom.xml:
#                 exactly one new JVM (app-stopped, app-started, a new pid,
#                 Started once), which owns the 5005 LISTEN socket and answers
#                 a JDWP handshake from this machine on 127.0.0.1:5009
#   G-08-RESTORE  pom.xml put back, the test file deleted: one new JVM
#   G-09          .mvn/jvm.config edited: one new JVM; G-09-RESTORE likewise
#   G-10          commons-lang3 added to <dependencies>: a new JVM, and the jar
#                 in dev-classpath.txt AND in the live java.class.path (jcmd
#                 VM.system_properties); G-10-REMOVE: gone from both
#   G-11-ADD      commons-text added: commons-lang3 arrives with it
#   G-11          an <exclusion> of commons-lang3 added to that dependency -
#                 exactly the edit mvnd's cached project dependencies do not
#                 see: the container's dev-classpath.txt must EQUAL a fresh
#                 resolve by ./mvnw in a one-off container, and lack
#                 commons-lang3; G-11-RESTORE: the classpath the suite started
#                 with, byte for byte
#   G-12          invalid XML in pom.xml: no restart, build-failed and
#                 build-broken, then the first automatic retry failing too,
#                 health 200 throughout; G-12-RESTORE: one new JVM
#   G-13          an edit whose mtime is then set an hour back: still served
#   G-14          touch only, same bytes: INFO with the restarts it caused
#   G-15          five saves within a second: one restart PASS, two WARN, more
#                 FAIL - and the last save is the one served
#   G-16          a JDWP session opened from this machine is still answered
#                 (VirtualMachine.Version) after a DevTools restart
#   G-17          a save while a new JVM is still booting: reload-deferred,
#                 then after app-ready exactly one trigger-touched, and the
#                 save served; G-17-RESTORE: pom.xml back, one new JVM
#   G-RESTORE     everything put back through the manifest, the probe classes
#                 purged from the target volume, one clean reload, git status
#                 clean again
#   G-GIT         .git/config and .git/hooks exactly as at the start
#
# then all twelve - service-discovery and config-server LAST, because every
# other service depends on them:
#
#   G-ALL-<svc>          a probe created, then deleted, in <base
#                        package>.devprobe: one restart each, the marker
#                        printed, then gone
#   G-ALL-<svc>-RESTORE  put back, purged, clean, .git untouched
#
# COUNTING RESTARTS WITHOUT A STOPWATCH. A window starts at the Docker VM's
# clock (Get-DockerNow - the clock docker logs stamps lines with, not this
# machine's) just before the edit. The case then waits, bounded, until the log
# since then shows the "Started <App> in" lines it expects and every event it
# requires, with nothing in flight - no compile, trigger, DevTools restart or
# launch still waiting for its outcome - and then for 20 more seconds in which
# nothing new is logged at all. A restart that is merely slow extends the wait
# instead of being missed; a fixed sleep would under-count on a slow Windows
# laptop, and a restart counted twice is the very thing R7 forbids. Every
# timeout saves the window and the last 200 lines of the container's log, and
# records FAIL - BLOCKED when that log shows the network or the OOM killer -
# and the suite goes on. If the application stops serving altogether, the
# remaining cases say so instead of each waiting out its own timeout.
#
# SAME JVM OR A NEW ONE. The application's pid comes from jcmd -l inside the
# container, before and after: a DevTools restart must keep it, a build-file
# change must replace it - with the pid dev-reload.sh's app-started names.
#
# THE PROBES are @Component classes in <base package>.devprobe whose
# constructor prints "HC-PROBE <name> <version>". A context that loaded the
# class prints it once per start, so WHAT is served is read off the log, not
# inferred from timing.
#
# YOUR CHECKOUT. Every edit goes through the edit manifest (Harness.ps1),
# saved before the edit; the restore runs in finally, puts back only bytes the
# harness wrote, and can be repeated later with run.ps1 -Restore <run-id>.
# mtimes are only ever moved on files this suite itself created. After the
# restore the probe classes are also removed from the target VOLUME - a
# compile does not always delete a class whose source went, and dev-reload.sh's
# last-good snapshot would copy them back on your next failed compile - and one
# clean reload proves the running context no longer has them.
#
# CONTAINER-SIDE SCRIPTS go in on stdin (docker exec -i <c> sh -s), never
# inside a command-line argument: Windows re-quotes every argument on its way
# to docker.exe, and a script full of quotes and newlines is exactly what
# that mangles. Nothing in them reads stdin, which is the script itself.

Set-StrictMode -Version 3.0

# Budgets. A source change is a full module compile (dev-reload.sh forces one,
# against clock skew) plus a DevTools restart; a build-file change is a daemon
# stop, a full build that may download, and a JVM boot. Generous: a timeout
# only costs time, and a Windows laptop on battery is slow.
$script:ReloadSourceSec = 420
$script:ReloadBuildSec = 900
$script:ReloadQuietSec = 20
# dev-reload.sh waits for a fix after a failure; its first automatic retry
# comes 30s later, and this is long enough to see that one start.
$script:ReloadGiveUpSec = 45
$script:ReloadLogPollSec = 2
# A cold start of user-service and what it depends on: an empty Maven volume,
# three builds.
$script:ReloadStartSec = 2700
$script:ReloadGateSec = 300
$script:ReloadHttpClient = $null
$script:ReloadSeq = 0

# dev-reload.sh events (its LOG MARKER CONTRACT) after which more must follow,
# and events that end a piece of work. The Spring "Started" line ends one too,
# and DevTools' "Restarting due to" begins one. Anything else is neutral:
# build-retry-scheduled in particular, or every failed build would count as
# busy until its last retry minutes later.
$script:ReloadBeginEvents = @(
    'source-changed', 'build-changed', 'build-pending', 'compile-start', 'compile-ok', 'build-start',
    'build-ok', 'classpath-written', 'trigger-touched', 'reload-deferred', 'main-class-changed',
    'app-stopped', 'app-started', 'app-exited', 'app-killed', 'restart-scheduled', 'boot-timeout'
)
$script:ReloadEndEvents = @(
    'compile-failed', 'build-failed', 'build-broken', 'reload-skipped', 'launch-refused', 'trigger-error',
    'app-ready', 'reload-failed', 'restart-exhausted', 'restart-deferred', 'main-class-error',
    'classpath-error', 'fatal'
)
# The events a result message lists, when they occurred.
$script:ReloadSummaryEvents = @(
    'source-changed', 'build-changed', 'compile-start', 'compile-ok', 'compile-failed', 'build-start',
    'build-ok', 'build-failed', 'build-broken', 'classes-restored', 'resource-removed', 'reload-deferred',
    'trigger-touched', 'app-stopped', 'app-started', 'app-ready'
)
# Failure events a source change can end in, and a build-file change.
$script:ReloadSourceFailOn = @('compile-failed', 'build-failed', 'build-broken', 'reload-skipped', 'launch-refused', 'reload-failed', 'trigger-error')
$script:ReloadBuildFailOn = @('build-broken', 'launch-refused', 'restart-exhausted', 'restart-deferred', 'reload-failed')

# A timeout whose log shows one of these is the network's fault, not the
# setup's.
$script:ReloadBlockedRe = 'UnknownHostException|Temporary failure in name resolution|Network is unreachable|No route to host|Connection timed out|connect timed out|Connection reset|status code: (?:429|5\d\d)|429 Too Many Requests|Could not transfer artifact|TLS handshake timeout|i/o timeout'

# G-10 adds the first of these that is NOT already on the classpath - a jar
# that is there already would make "it appeared" prove nothing. Explicit
# versions, so the case does not depend on what the parent manages.
$script:ReloadDepCandidates = @(
    [pscustomobject]@{ Group = 'org.apache.commons'; Artifact = 'commons-lang3'; Version = '3.20.0' }
    [pscustomobject]@{ Group = 'org.apache.commons'; Artifact = 'commons-collections4'; Version = '4.5.0' }
)
$script:ReloadTextDep = [pscustomobject]@{ Group = 'org.apache.commons'; Artifact = 'commons-text'; Version = '1.14.0' }
$script:ReloadLangDep = [pscustomobject]@{ Group = 'org.apache.commons'; Artifact = 'commons-lang3'; Version = '' }

# ---------------------------------------------------------------------------
# What goes into the checkouts
# ---------------------------------------------------------------------------

$script:ReloadProbeJava = @'
package __PKG__.devprobe;

// Written by home-crew-infrastructure/test/run.ps1 (suite reload), and deleted
// again when that suite ends. Its constructor prints the marker the suite
// counts: once per start of the application context.
@org.springframework.stereotype.Component
public class __NAME__ {

  public __NAME__() {
    System.out.println("__LINE__")__SEMI__
  }
}
'@

$script:ReloadBrokenTestJava = @'
package __PKG__.devprobe;

// Written by home-crew-infrastructure/test/run.ps1 (suite reload): a test
// source that does not compile, on purpose. src/test is not watched, so it
// must cause no compile, and must not stop a pom.xml change from building.
class HcProbeBrokenTest {
  this is not java
}
'@

# ---------------------------------------------------------------------------
# Container-side scripts (POSIX sh, run by dash in homecrew-dev-runtime:jdk25)
# ---------------------------------------------------------------------------

# The settings dev-reload.sh runs with, as this container has them.
$script:ReloadShFacts = @'
printf 'interval=%s\n' "${DEV_RELOAD_INTERVAL:-2}"
printf 'trigger=%s\n' "${SPRING_DEVTOOLS_RESTART_TRIGGER_FILE:-.reloadtrigger}"
printf 'compiler=%s\n' "${DEV_COMPILER:-auto}"
printf 'port=%s\n' "${DEV_APP_PORT:-}"
if command -v mvnd >/dev/null 2>&1; then echo 'mvnd=yes'; else echo 'mvnd=no'; fi
'@

# Who holds container port 5005 (138D in hex): every LISTEN socket with the
# pids whose descriptors point at its inode, and every ESTABLISHED connection -
# a debugger attached. One ls over all the fd directories rather than a
# readlink per descriptor: a JVM has hundreds.
$script:ReloadShSockets = @'
for t in /proc/net/tcp /proc/net/tcp6; do
    [ -r "$t" ] || continue
    awk 'NR > 1 { n = split($2, a, ":"); if (a[n] == "138D") print $4, $10 }' "$t"
done | while read -r st ino; do
    case $st in
        0A)
            owners=$(ls -l /proc/[0-9]*/fd 2>/dev/null | awk -v want="socket:[$ino]" '
                /^\/proc\/[0-9]+\/fd:$/ { split($0, a, "/"); p = a[3]; next }
                $NF == want { print p }' | sort -u | tr '\n' ' ')
            echo "LISTEN $ino $owners" ;;
        01) echo "ESTAB $ino" ;;
    esac
done
exit 0
'@

# $1: the package directory (com/homecrew/<svc>); $2, optional: one resource
# the suite may have left behind. Both trees: the compiled classes, and
# dev-reload.sh's last-good snapshot, which a later failed compile copies back
# over them. Each removal says how many files went with it.
$script:ReloadShPurge = @'
for base in /app/target/classes /app/target/.dev-reload/good/classes; do
    d="$base/$1/devprobe"
    if [ -e "$d" ]; then
        n=$(find "$d" -type f | wc -l | tr -d ' ')
        rm -rf "$d" && echo "removed $d $n"
    fi
    if [ -n "${2:-}" ] && [ -e "$base/$2" ]; then rm -f "$base/$2" && echo "removed $base/$2 1"; fi
    if [ -e "$d" ]; then echo "left $d"; fi
done
exit 0
'@

# Every file in target/classes except the trigger, with its checksum: a failed
# compile must leave this exactly as the last good one did.
$script:ReloadShListing = @'
cd /app/target/classes 2>/dev/null || exit 3
find . -type f ! -name "$1" -exec cksum {} + | LC_ALL=C sort -k 3
'@

# A fresh classpath, resolved by ./mvnw in a one-off container: no daemon, so
# nothing cached from an earlier build of this pom. Through dev-reload.sh's own
# run_maven, so it runs with exactly the flags its builds use - the lock
# settings, --batch-mode, -q, and -Dhooks.install.skip=true, without which a
# Maven run could rewrite core.hooksPath in the checkout's .git/config. One
# line, no double quotes: it travels as a command-line argument.
$script:ReloadShFreshCp = 'cd /app && DEV_RELOAD_LIB_ONLY=1 . /dev-reload.sh && COMPILE=mvnw && rc=0 && { run_maven dependency:build-classpath -DincludeScope=runtime -Dmdep.outputFile=/tmp/hc-cp.txt >/tmp/hc-mvn.log 2>&1 || rc=$?; } && cat /tmp/hc-mvn.log && echo HC-CP-RC $rc && echo HC-CP-BEGIN && cat /tmp/hc-cp.txt && echo && echo HC-CP-END'

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

function Invoke-SuiteReload {
    Enter-Suite 'reload' 'live reload on user-service, and a probe in all twelve (R7, R6, R11)'
    $h = Get-Harness
    $script:ReloadSeq = 0
    if (-not (Test-DockerAvailable)) {
        Reload-Add -Id 'G-PRE' -Status 'SKIP' -Req @('R7') -Message 'docker is not available here (not on PATH, or docker info fails): every case edits a checkout that a running container watches'
        return
    }
    if (-not (Test-Path -LiteralPath (Join-Path $h.InfraRoot '.env') -PathType Leaf)) {
        Reload-Add -Id 'G-PRE' -Status 'SKIP' -Req @('R7') -Message 'there is no .env, and compose cannot render docker-compose.yml without it, so the stack can neither be started nor run from: copy .env.example to .env and fill in CONFIG_GIT_USERNAME and CONFIG_GIT_TOKEN'
        return
    }
    if (-not $h.Git) {
        Reload-Add -Id 'G-PRE' -Status 'SKIP' -Req @('R7') -Message 'git is not on PATH, and this suite refuses to edit a checkout whose state it cannot check'
        return
    }

    $ctx = Reload-NewCtx (Get-JavaService 'user-service')
    $go = $false
    try { $go = Reload-Prepare $ctx }
    catch { Reload-HarnessError -Id 'G-PRE' -Req @('R7') -Err $_ }
    if ($go) { Reload-UserService $ctx }

    # The light probe runs even when user-service was refused: each repository
    # is judged on its own.
    Reload-All
}

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------

function Reload-NewCtx {
    param([Parameter(Mandatory)] $Svc)
    $h = Get-Harness
    $main = [string]$Svc.Main
    $dot = $main.LastIndexOf('.')
    $pkg = $main.Substring(0, $dot)
    $simple = $main.Substring($dot + 1)
    $repoPath = Get-RepoPath $Svc.Repo
    $pkgPath = $pkg.Replace('.', '/')
    $probeParts = @($repoPath, 'src', 'main', 'java') + @($pkg.Split('.')) + @('devprobe')
    $testParts = @($repoPath, 'src', 'test', 'java') + @($pkg.Split('.')) + @('devprobe')
    return [pscustomobject]@{
        Svc        = $Svc
        Name       = [string]$Svc.Name
        Container  = $script:LiveContainerPrefix + $Svc.Name
        Repo       = [string]$Svc.Repo
        RepoPath   = $repoPath
        Main       = $main
        Pkg        = $pkg
        PkgPath    = $pkgPath
        Simple     = $simple
        StartedRe  = 'Started ' + [regex]::Escape($simple) + ' in [0-9]'
        HealthUrl  = "http://127.0.0.1:$($Svc.Port)/actuator/health"
        ProbeDir   = [System.IO.Path]::Combine([string[]]$probeParts)
        TestDir    = [System.IO.Path]::Combine([string[]]$testParts)
        Interval   = 2.0
        Trigger    = '.reloadtrigger'
        Compiler   = ''
        JvmPid     = ''
        BaselineCp = ''
        Debugger   = $false
        Abort      = ''
        Tracked    = @{}
        Versions   = @{}
        Manifest   = ''
        GitHash    = ''
        Nonce      = $h.RunId
    }
}

# Everything G needs before it touches anything. Returns $true when the
# user-service cases may run; every reason they may not is a G-PRE row.
function Reload-Prepare {
    param([Parameter(Mandatory)] $Ctx)
    $req = @('R7')
    $pom = Reload-RepoFile $Ctx 'pom.xml'
    if (-not (Test-Path -LiteralPath $pom -PathType Leaf)) {
        Reload-Add -Id 'G-PRE' -Status 'SKIP' -Req $req -Message "$pom does not exist: the checkout is missing, so there is nothing to edit"
        return $false
    }
    # Refused, not skipped: a dirty tree is someone's work in progress, and
    # the verification did not happen - the row has to be noticed.
    if (-not (Test-RepoClean $Ctx.Repo)) {
        $st = Invoke-Git $Ctx.RepoPath @('status', '--porcelain')
        $ev = Save-Evidence -Suite 'reload' -Name 'G-PRE-git-status.txt' -Content $st.StdOut
        Reload-Add -Id 'G-PRE' -Status 'FAIL' -Req $req -Evidence @($ev) -Message ("refused: {0} has uncommitted changes ({1}), and this suite edits that checkout. Commit or stash them first - git -C '{2}' stash push --include-untracked - then run -Suite reload again, and git stash pop afterwards" -f $Ctx.Repo, (Reload-StatusSummary $st.StdOut), $Ctx.RepoPath)
        return $false
    }

    $notes = [System.Collections.Generic.List[string]]::new()
    $state = Reload-ContainerState $Ctx.Container
    if ($state) {
        $foreign = Reload-ForeignCheckout $Ctx
        if ($foreign) {
            Reload-Add -Id 'G-PRE' -Status 'SKIP' -Req $req -Message "$($Ctx.Container) belongs to the compose project in $foreign, not to this checkout, so edits here would never reach it. Stop that stack from its own checkout, start this one (.\dev.ps1 up), and run -Suite reload again"
            return $false
        }
    }
    if ($state -ne 'running') {
        $why = Reload-StartService $Ctx
        if ($why) {
            Reload-Add -Id 'G-PRE' -Status $why -Req $req -Message "not run: $($Ctx.Name) was not running ($(Reload-StateText $state)) and could not be started - see G-PRE-UP"
            return $false
        }
        $notes.Add("$($Ctx.Name) was not running, and was started with the launcher (G-PRE-UP)")
    }

    Reload-Say "waiting for $($Ctx.Name) to serve: one JVM, its port answering, dev-reload.sh idle"
    $look = Reload-WaitServing -Ctx $Ctx -TimeoutSec $script:ReloadStartSec
    if (-not $look.Ok) {
        $tail = Reload-Tail $Ctx 200
        $ev = Save-Evidence -Suite 'reload' -Name 'G-PRE-last200.log' -Content $tail
        $why = Reload-Classify -Ctx $Ctx -Text $tail
        $status = 'FAIL'
        $msg = "$($Ctx.Name) is not serving: $($look.Why) - the last 200 lines of its log are in the evidence"
        if ($why) { $status = 'BLOCKED'; $msg = "$msg ($why)" }
        Reload-Add -Id 'G-PRE' -Status $status -Req $req -Evidence @($ev) -Message $msg
        return $false
    }
    $Ctx.JvmPid = $look.JvmPid

    # The container must see THIS checkout: edits anywhere else would never
    # arrive, and every case would time out without saying why.
    $hostSha = Reload-Sha $pom
    $in = Invoke-Docker @('exec', $Ctx.Container, 'sha256sum', '/app/pom.xml') -TimeoutSec 60
    $inSha = ''
    if ($in.ExitCode -eq 0) { $inSha = ([string](@($in.StdOut.Trim() -split '\s+')[0])).ToUpperInvariant() }
    if ($inSha -ne $hostSha) {
        Reload-Add -Id 'G-PRE' -Status 'FAIL' -Req $req -Message ("/app/pom.xml in {0} (sha256 {1}) is not {2} (sha256 {3}): the container does not mount this checkout" -f $Ctx.Container, (Reload-Short $inSha), $pom, (Reload-Short $hostSha))
        return $false
    }

    Reload-ReadFacts $Ctx
    $Ctx.BaselineCp = Reload-DevClasspath $Ctx
    if (-not $Ctx.BaselineCp) {
        Reload-Add -Id 'G-PRE' -Status 'FAIL' -Req $req -Message "$($Ctx.Name) serves, yet /app/target/dev-classpath.txt is missing or empty - the classpath cases would have nothing to compare with"
        return $false
    }
    $sock = Reload-Sockets $Ctx
    $Ctx.Debugger = @($sock.Items | Where-Object { $_.State -eq 'ESTAB' }).Count -gt 0
    if ($Ctx.Debugger) { $notes.Add('a debugger is attached to 5005, so the JDWP cases will not take it over') }

    # Probe classes a crashed earlier run left in the target volume would print
    # markers of their own in every window.
    $purge = Reload-PurgeProbes -Ctx $Ctx -Extra 'hc-probe.txt'
    if (@($purge.Removed).Count) { $notes.Add('removed what an earlier run left in the target volume: ' + (@($purge.Removed) -join ', ')) }

    $facts = @(
        "container:        $($Ctx.Container)",
        "checkout:         $($Ctx.RepoPath)",
        "application pid:  $($Ctx.JvmPid)",
        "compiler:         $($Ctx.Compiler)",
        "poll interval:    $($Ctx.Interval)s",
        "trigger file:     /app/target/classes/$($Ctx.Trigger)",
        "debugger on 5005: $($Ctx.Debugger)",
        '',
        'dev-classpath.txt at the start:',
        $Ctx.BaselineCp
    )
    $ev = Save-Evidence -Suite 'reload' -Name 'G-PRE-facts.txt' -Content ($facts -join "`n")
    $extra = ''
    if ($notes.Count) { $extra = '; ' + ($notes -join '; ') }
    Reload-Add -Id 'G-PRE' -Status 'PASS' -Req $req -Evidence @($ev) -Message ("{0} is clean; {1} serves it (pid {2}, compiler {3}, poll every {4}s){5}" -f $Ctx.Repo, $Ctx.Container, $Ctx.JvmPid, $Ctx.Compiler, $Ctx.Interval, $extra)
    return $true
}

# The launcher, as you would run it: .\dev.ps1 under the pwsh running this
# harness on Windows, sh ./dev elsewhere. Returns '' once it has started, or
# the status G-PRE should carry.
function Reload-StartService {
    param([Parameter(Mandatory)] $Ctx)
    $h = Get-Harness
    $l = Reload-Launcher
    if (-not $l) {
        Reload-Add -Id 'G-PRE-UP' -Status 'SKIP' -Req @('R7') -Message 'there is no sh on PATH to run ./dev with'
        return 'SKIP'
    }
    # user-service, postgres, kafka, service-discovery and config-server: three
    # JVMs of up to 1g, and the Maven daemons beside them during a cold start.
    $tight = Test-DockerMemory -NeedBytes 4GB
    if ($tight) {
        Reload-Add -Id 'G-PRE-UP' -Status 'BLOCKED' -Req @('R7') -Message "not starting $($Ctx.Name): $tight"
        return 'BLOCKED'
    }
    $what = "$($l.Label) up $($Ctx.Name)"
    # The launcher runs docker itself, out of the guard's reach, so the guard
    # sees the compose command it turns into first.
    Assert-DockerArgsSafe @('compose', '-f', 'docker-compose.yml', '-f', 'compose.dev.yml', 'up', '-d', '--build', '--wait', $Ctx.Name)
    Reload-Say "starting it with $what; a first start compiles from cold and takes minutes"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-Native -FilePath $l.Exe -ArgumentList (@($l.Pre) + @('up', $Ctx.Name)) -WorkingDirectory $h.InfraRoot -TimeoutSec $script:ReloadStartSec
    $secs = [int]$sw.Elapsed.TotalSeconds
    $ev = Save-Evidence -Suite 'reload' -Name 'G-PRE-UP.log' -Content ("# $what`n# $($r.CommandLine)`n# exit $($r.ExitCode) after ${secs}s`n---- stdout ----`n$($r.StdOut)`n---- stderr ----`n$($r.StdErr)`n")
    if ($r.ExitCode -eq 0) {
        Reload-Add -Id 'G-PRE-UP' -Status 'PASS' -Req @('R7') -Evidence @($ev) -Message "$what exited 0 after ${secs}s"
        return ''
    }
    $text = [string]$r.StdOut + "`n" + [string]$r.StdErr
    $net = [regex]::Match($text, "(?im)^.*(?:$($script:ReloadBlockedRe)).*$")
    if ($r.TimedOut) {
        Reload-Add -Id 'G-PRE-UP' -Status 'FAIL' -Req @('R7') -Evidence @($ev) -Message "$what did not return within $($script:ReloadStartSec)s and was stopped"
        return 'FAIL'
    }
    if ($r.ExitCode -eq -2) {
        Reload-Add -Id 'G-PRE-UP' -Status 'BLOCKED' -Req @('R7') -Evidence @($ev) -Message "$what could not be started at all: $(Reload-FirstLine $r.StdErr)"
        return 'BLOCKED'
    }
    if ($net.Success) {
        Reload-Add -Id 'G-PRE-UP' -Status 'BLOCKED' -Req @('R7') -Evidence @($ev) -Message "$what exited $($r.ExitCode) on a network failure: $(Reload-Clip $net.Value.Trim() 200)"
        return 'BLOCKED'
    }
    Reload-Add -Id 'G-PRE-UP' -Status 'FAIL' -Req @('R7') -Evidence @($ev) -Message "$what exited $($r.ExitCode) after ${secs}s: $(Reload-FirstLine $r.StdErr)"
    return 'FAIL'
}

function Reload-Launcher {
    $h = Get-Harness
    if ($h.OnWindows) {
        $exe = [System.Environment]::ProcessPath
        if (-not $exe) { $exe = (Get-Process -Id $PID).Path }
        return [pscustomobject]@{ Exe = $exe; Pre = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $h.InfraRoot 'dev.ps1')); Label = '.\dev.ps1' }
    }
    $sh = Get-Command sh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $sh) { return $null }
    return [pscustomobject]@{ Exe = $sh.Source; Pre = @('./dev'); Label = 'sh ./dev' }
}

# compose labels every container with the directory it was run from. A
# different one means another clone owns the pinned container names - unless
# /app/pom.xml is byte for byte ours, when it is more likely the same
# directory spelt differently (a junction, a subst drive); the pom check in
# Reload-Prepare still has the last word. Returns the other directory, or ''.
function Reload-ForeignCheckout {
    param([Parameter(Mandatory)] $Ctx)
    $h = Get-Harness
    $r = Invoke-Docker @('inspect', '-f', '{{index .Config.Labels "com.docker.compose.project.working_dir"}}', $Ctx.Container) -TimeoutSec 60
    if ($r.ExitCode -ne 0) { return '' }
    $wd = $r.StdOut.Trim()
    if (-not $wd -or $wd -eq '<no value>') { return '' }
    if ((Reload-NormPath $wd) -eq (Reload-NormPath $h.InfraRoot)) { return '' }
    $in = Invoke-Docker @('exec', $Ctx.Container, 'sha256sum', '/app/pom.xml') -TimeoutSec 60
    if ($in.ExitCode -eq 0) {
        $inSha = ([string](@($in.StdOut.Trim() -split '\s+')[0])).ToUpperInvariant()
        if ($inSha -eq (Reload-Sha (Reload-RepoFile $Ctx 'pom.xml'))) { return '' }
    }
    return $wd
}

function Reload-NormPath {
    param([string] $Path)
    $x = $Path.Replace('\', '/').TrimEnd('/')
    if ((Get-Harness).OnWindows) { $x = $x.ToLowerInvariant() }
    return $x
}

# One look: the container running, exactly one application JVM, its port
# answering HTTP (any status - dev-reload.sh's own rule), and dev-reload.sh
# not in the middle of something.
function Reload-Serving {
    param([Parameter(Mandatory)] $Ctx)
    $state = Reload-ContainerState $Ctx.Container
    if ($state -ne 'running') {
        return [pscustomobject]@{ Ok = $false; Dead = $true; Why = "$($Ctx.Container) is $(Reload-StateText $state)"; JvmPid = ''; Key = '' }
    }
    $tail = Reload-ParseLog -Ctx $Ctx -Text (Reload-Tail $Ctx 300)
    $key = $tail.Last
    $jvm = Reload-AppPid $Ctx
    if (-not $jvm) { return [pscustomobject]@{ Ok = $false; Dead = $false; Why = "no $($Ctx.Simple) JVM in jcmd -l (last: $(Reload-Clip $tail.Last 160))"; JvmPid = ''; Key = $key } }
    if ($jvm.Contains(',')) { return [pscustomobject]@{ Ok = $false; Dead = $false; Why = "two $($Ctx.Simple) JVMs at once ($jvm)"; JvmPid = $jvm; Key = $key } }
    $code = Reload-Liveness $Ctx
    if ($code -eq 0) { return [pscustomobject]@{ Ok = $false; Dead = $false; Why = "port $($Ctx.Svc.Port) does not answer HTTP inside the container (last: $(Reload-Clip $tail.Last 160))"; JvmPid = $jvm; Key = $key } }
    if ($tail.Busy) { return [pscustomobject]@{ Ok = $false; Dead = $false; Why = "dev-reload.sh is still busy (last: $(Reload-Clip $tail.Last 160))"; JvmPid = $jvm; Key = $key } }
    return [pscustomobject]@{ Ok = $true; Dead = $false; Why = ''; JvmPid = $jvm; Key = $key }
}

# Until it serves; given up early when the container is gone, or when nothing
# new has been logged for 300s - dev-reload.sh waiting for a fix.
function Reload-WaitServing {
    param([Parameter(Mandatory)] $Ctx, [int] $TimeoutSec = 300)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $dead = 0
    $lastKey = $null
    $keySince = 0.0
    while ($true) {
        $look = Reload-Serving $Ctx
        if ($look.Ok) { return $look }
        $el = $sw.Elapsed.TotalSeconds
        if ($look.Dead) {
            $dead++
            if ($dead -ge 3) { return $look }
        }
        else { $dead = 0 }
        if ($look.Key -ne $lastKey) { $lastKey = $look.Key; $keySince = $el }
        elseif (($el - $keySince) -ge 300) {
            $look.Why = $look.Why + ' - and nothing new in its log for 300s'
            return $look
        }
        if ($el -ge $TimeoutSec) {
            $look.Why = $look.Why + " - still, after ${TimeoutSec}s"
            return $look
        }
        Start-Sleep -Seconds 5
    }
}

# Before every case: serving, or waited for; if it does not come back, the
# remaining cases are reported as not run instead of each timing out.
function Reload-Gate {
    param([Parameter(Mandatory)] $Ctx, [Parameter(Mandatory)][string] $Id)
    $look = Reload-Serving $Ctx
    if (-not $look.Ok) {
        Reload-Say "${Id}: waiting for $($Ctx.Name) first - $($look.Why)"
        $look = Reload-WaitServing -Ctx $Ctx -TimeoutSec $script:ReloadGateSec
    }
    if ($look.Ok) {
        $Ctx.JvmPid = $look.JvmPid
        return $true
    }
    $null = Save-Evidence -Suite 'reload' -Name "$Id-not-serving.log" -Content (Reload-Tail $Ctx 200)
    $Ctx.Abort = "$($Ctx.Name) stopped serving before $Id ($($look.Why)); its last 200 log lines are in reload/$Id-not-serving.log"
    return $false
}

function Reload-ReadFacts {
    param([Parameter(Mandatory)] $Ctx)
    $r = Reload-ExecScript -Container $Ctx.Container -Script $script:ReloadShFacts -TimeoutSec 60
    $mvnd = ''
    foreach ($l in ($r.StdOut -split "`r?`n")) {
        $m = [regex]::Match($l, '^([a-z]+)=(.*)$')
        if (-not $m.Success) { continue }
        $v = $m.Groups[2].Value.Trim()
        switch ($m.Groups[1].Value) {
            'interval' {
                $d = 0.0
                if ([double]::TryParse($v, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref] $d) -and $d -gt 0) { $Ctx.Interval = $d }
            }
            'trigger' { if ($v -and $v -notmatch '[/\\]') { $Ctx.Trigger = $v } }
            'compiler' { $Ctx.Compiler = $v }
            'mvnd' { $mvnd = $v }
        }
    }
    if ($Ctx.Compiler -eq 'auto' -and $mvnd) { $Ctx.Compiler = "auto (mvnd installed: $mvnd)" }
}

# How long "nothing happens" is watched for: dev-reload.sh notices a change
# within one poll interval, settles for a second or more, and logs.
function Reload-ObserveSec {
    param([Parameter(Mandatory)] $Ctx)
    return [int][Math]::Max(20, [Math]::Ceiling(4 * $Ctx.Interval) + 10)
}

# ---------------------------------------------------------------------------
# user-service, in depth
# ---------------------------------------------------------------------------

function Reload-UserService {
    param([Parameter(Mandatory)] $Ctx)
    $Ctx.GitHash = Get-GitConfigHash $Ctx.Repo
    $Ctx.Manifest = Start-EditManifest 'reload'
    $cases = [ordered]@{
        'G-01' = 'Reload-G01'; 'G-02' = 'Reload-G02'; 'G-03' = 'Reload-G03'; 'G-04' = 'Reload-G04'
        'G-05' = 'Reload-G05'; 'G-06' = 'Reload-G06'; 'G-07' = 'Reload-G07'; 'G-08' = 'Reload-G08'
        'G-09' = 'Reload-G09'; 'G-10' = 'Reload-G10'; 'G-11' = 'Reload-G11'; 'G-12' = 'Reload-G12'
        'G-13' = 'Reload-G13'; 'G-14' = 'Reload-G14'; 'G-15' = 'Reload-G15'; 'G-16' = 'Reload-G16'
        'G-17' = 'Reload-G17'
    }
    # $false in the finally only after Ctrl+C - a catch never sees that, so an
    # error still gets the full restore. Then the restore does only what is
    # quick (see Reload-RestoreRepo -Quick): a finally cannot be interrupted.
    $finished = $false
    try {
        foreach ($id in $cases.Keys) {
            if (-not $Ctx.Abort) { $null = Reload-Gate -Ctx $Ctx -Id $id }
            if ($Ctx.Abort) {
                Reload-Add -Id $id -Status 'FAIL' -Req @('R7') -Message "not run: $($Ctx.Abort)"
                continue
            }
            try { & $cases[$id] $Ctx }
            catch { Reload-HarnessError -Id $id -Req @('R7') -Err $_ }
        }
        $finished = $true
    }
    catch { $finished = $true; throw }
    finally {
        try { Reload-RestoreRepo -Ctx $Ctx -Id 'G-RESTORE' -Quick:(-not $finished) }
        catch { Reload-HarnessError -Id 'G-RESTORE' -Req @('R7', 'R10') -Err $_ }
        try {
            $after = Get-GitConfigHash $Ctx.Repo
            $ev = Save-Evidence -Suite 'reload' -Name 'G-GIT.txt' -Content ("before: $($Ctx.GitHash)`nafter:  $after`n")
            if ($after -eq $Ctx.GitHash) {
                Reload-Add -Id 'G-GIT' -Status 'PASS' -Req @('R7', 'R10') -Evidence @($ev) -Message "$($Ctx.Repo)/.git/config and .git/hooks are byte for byte as they were before the first edit, after every build the suite caused"
            }
            else {
                Reload-Add -Id 'G-GIT' -Status 'FAIL' -Req @('R7', 'R10') -Evidence @($ev) -Message "$($Ctx.Repo)/.git/config or .git/hooks changed while the suite ran: a build in the container reached into your checkout's git settings (the pom's core.hooksPath exec, run without -Dhooks.install.skip=true?) - compare the two fingerprints in the evidence"
            }
        }
        catch { Reload-HarnessError -Id 'G-GIT' -Req @('R7', 'R10') -Err $_ }
    }
}

function Reload-G01 {
    param([Parameter(Mandatory)] $Ctx)
    $v = Reload-NextVersion $Ctx 'HcProbeA'
    $a = @{
        Ctx = $Ctx; Id = 'G-01'; What = 'a new @Component class (devprobe.HcProbeA)'
        Edits = @(Reload-ProbeEdit -Ctx $Ctx -Name 'HcProbeA' -Version $v)
        Markers = @{ HcProbeA = $v }; Present = @(Reload-ClassRel $Ctx 'HcProbeA')
    }
    $r = Reload-SourceCase @a
    if ($r) { Reload-Finish $r }
}

function Reload-G02 {
    param([Parameter(Mandatory)] $Ctx)
    $v = Reload-NextVersion $Ctx 'HcProbeA'
    $a = @{
        Ctx = $Ctx; Id = 'G-02'; What = "HcProbeA modified (its marker now $v)"
        Edits = @(Reload-ProbeEdit -Ctx $Ctx -Name 'HcProbeA' -Version $v)
        Markers = @{ HcProbeA = $v }; Present = @(Reload-ClassRel $Ctx 'HcProbeA')
    }
    $r = Reload-SourceCase @a
    if ($r) { Reload-Finish $r }
}

# One delete and one create, back to back: dev-reload.sh settles on the pair
# as one change.
function Reload-G03 {
    param([Parameter(Mandatory)] $Ctx)
    $v = 'v1'
    if ($Ctx.Versions.ContainsKey('HcProbeA')) { $v = 'v' + $Ctx.Versions['HcProbeA'] }
    $Ctx.Versions['HcProbeB'] = [int]$v.Substring(1)
    $a = @{
        Ctx = $Ctx; Id = 'G-03'; What = 'HcProbeA renamed to HcProbeB'
        Edits = @(
            @{ Op = 'delete'; Path = (Reload-ProbePath $Ctx 'HcProbeA') },
            (Reload-ProbeEdit -Ctx $Ctx -Name 'HcProbeB' -Version $v)
        )
        Markers = @{ HcProbeB = $v }; NoMarkers = @('HcProbeA')
        Present = @(Reload-ClassRel $Ctx 'HcProbeB'); Absent = @(Reload-ClassRel $Ctx 'HcProbeA')
    }
    $r = Reload-SourceCase @a
    if ($r) { Reload-Finish $r }
}

function Reload-G04 {
    param([Parameter(Mandatory)] $Ctx)
    $a = @{
        Ctx = $Ctx; Id = 'G-04'; What = 'HcProbeB deleted'
        Edits = @(@{ Op = 'delete'; Path = (Reload-ProbePath $Ctx 'HcProbeB') })
        NoMarkers = @('*'); Absent = @(Reload-ClassRel $Ctx 'HcProbeB')
    }
    $r = Reload-SourceCase @a
    if ($r) { Reload-Finish $r }
}

function Reload-G05 {
    param([Parameter(Mandatory)] $Ctx)
    $name = 'HcProbeC'
    $listBefore = Reload-ClassListing $Ctx
    $trigBefore = Reload-TriggerStamp $Ctx
    $pre = Reload-Http -Url $Ctx.HealthUrl -TimeoutSec 5
    # dev-reload.sh retries a failed compile once, RETRY_DELAY (30s) later, in
    # case it was transient. The window waits for that retry to fail as well:
    # a fix saved while the retry compiles is built twice - by the retry, and
    # again by the next poll, which still sees the file as changed - and
    # G-05-FIX would count two restarts for one save.
    $a = @{
        Ctx = $Ctx; Id = 'G-05'; What = 'a syntax error in a new class (devprobe.HcProbeC)'
        Edits = @(Reload-ProbeEdit -Ctx $Ctx -Name $name -Version 'broken' -Broken)
        Restarts = 0; Events = @('compile-failed', 'classes-restored', 'build-retry-scheduled'); Counts = @{ 'compile-failed' = 2 }
        FailOn = @(); Health = $true
        NoMarkers = @($name)
    }
    $r = Reload-SourceCase @a
    if ($r) {
        Reload-CheckHealth -R $r -Pre $pre
        $nr = Reload-Count $r.W.P 'build-retry-scheduled'
        if ($nr -ne 1) { $r.Problems.Add("build-retry-scheduled x${nr}: a failed compile is retried exactly once") }
        else { $r.Notes.Add('retried once, and failed again, as a genuine compile error should') }
        $trigAfter = Reload-TriggerStamp $Ctx
        if (-not $trigBefore) { $r.Problems.Add("/app/target/classes/$($Ctx.Trigger) could not be read before the edit, so 'untouched' cannot be shown") }
        elseif ($trigAfter -ne $trigBefore) { $r.Problems.Add("the trigger file was touched after a FAILED compile ($trigBefore -> $trigAfter)") }
        else { $r.Notes.Add("trigger file untouched ($trigAfter)") }
        $n = Reload-Count $r.W.P 'trigger-touched'
        if ($n) { $r.Problems.Add("trigger-touched x$n after a failed compile") }
        $listAfter = Reload-ClassListing $Ctx
        if (-not $listBefore.Ok -or -not $listAfter.Ok) { $r.Problems.Add('the file list of /app/target/classes could not be read before and after') }
        elseif ($listAfter.Text -cne $listBefore.Text) {
            $r.Evidence.Add((Save-Evidence -Suite 'reload' -Name 'G-05-classes.txt' -Content ("---- before the edit ----`n$($listBefore.Text)`n---- after the failed compile ----`n$($listAfter.Text)`n")))
            $r.Problems.Add("target/classes is not what the last good compile left: $(Reload-ListDiff $listBefore.Text $listAfter.Text)")
        }
        else { $r.Notes.Add("all $($listAfter.Count) files in target/classes byte for byte as before") }
        Reload-Finish $r
    }

    $v = Reload-NextVersion $Ctx $name
    $b = @{
        Ctx = $Ctx; Id = 'G-05-FIX'; What = "the syntax error fixed (HcProbeC $v)"
        Edits = @(Reload-ProbeEdit -Ctx $Ctx -Name $name -Version $v)
        Markers = @{ $name = $v }; Present = @(Reload-ClassRel $Ctx $name)
    }
    $r2 = Reload-SourceCase @b
    if ($r2) { Reload-Finish $r2 }
}

function Reload-G06 {
    param([Parameter(Mandatory)] $Ctx)
    $path = [System.IO.Path]::Combine($Ctx.RepoPath, 'src', 'main', 'resources', 'hc-probe.txt')
    $content = "hc-probe resource, written by test/run.ps1 (suite reload), run $($Ctx.Nonce)`n"
    $a = @{
        Ctx = $Ctx; Id = 'G-06'; What = 'a resource added (src/main/resources/hc-probe.txt)'
        Edits = @(@{ Op = 'write'; Path = $path; Content = $content }); Present = @('hc-probe.txt')
    }
    $r = Reload-SourceCase @a
    if ($r) {
        $got = Reload-CatFile $Ctx '/app/target/classes/hc-probe.txt'
        if ($got.Ok -and $got.Text.Replace("`r", '') -cne $content) { $r.Problems.Add('target/classes/hc-probe.txt is there, but its content is not the resource written') }
        Reload-Finish $r
    }
    $b = @{
        Ctx = $Ctx; Id = 'G-06-DEL'; What = 'the resource deleted again'
        Edits = @(@{ Op = 'delete'; Path = $path }); Absent = @('hc-probe.txt'); Events = @('resource-removed')
    }
    $r2 = Reload-SourceCase @b
    if ($r2) {
        $rm = @($r2.W.P.Order | Where-Object { $_.Kind -eq 'resource-removed' -and $_.Detail -eq 'hc-probe.txt' })
        if ($rm.Count -eq 0) { $r2.Problems.Add('resource-removed was logged, but not for hc-probe.txt') }
        else { $r2.Notes.Add('resource-removed: hc-probe.txt') }
        Reload-Finish $r2
    }
}

function Reload-G07 {
    param([Parameter(Mandatory)] $Ctx)
    $a = @{
        Ctx = $Ctx; Id = 'G-07'; What = 'a src/test file that does not compile'
        Edits = @(@{ Op = 'write'; Path = (Reload-TestProbePath $Ctx); Content = (Reload-Fill $script:ReloadBrokenTestJava $Ctx) })
        Restarts = 0; MinSec = (Reload-ObserveSec $Ctx); FailOn = @()
    }
    $r = Reload-SourceCase @a
    if ($r) {
        foreach ($e in @('source-changed', 'build-changed', 'compile-start', 'build-start')) {
            $n = Reload-Count $r.W.P $e
            if ($n) { $r.Problems.Add("$e x${n}: a src/test edit was acted on") }
        }
        if (-not $r.Problems.Count) { $r.Notes.Add("nothing compiled in $($r.W.Secs)s of watching") }
        Reload-Finish $r
    }
}

function Reload-G08 {
    param([Parameter(Mandatory)] $Ctx)
    $pom = Reload-RepoFile $Ctx 'pom.xml'
    $orig = Reload-Original $Ctx $pom
    $test = Reload-TestProbePath $Ctx
    $testThere = Test-Path -LiteralPath $test -PathType Leaf
    $a = @{
        Ctx = $Ctx; Id = 'G-08'; Req = @('R7', 'R11')
        What = 'an XML comment appended to pom.xml, with the broken src/test file still there'
        Edits = @(@{ Op = 'write'; Path = $pom; Content = (Reload-PomComment $orig "hc-probe G-08 $($Ctx.Nonce)") })
    }
    $r = Reload-JvmCase @a
    if ($r) {
        if (-not $testThere) { $r.Problems.Add("the broken src/test file from G-07 was not there, so this does not show that it cannot block a build") }
        Reload-CheckJdwpOwner -Ctx $Ctx -R $r -Handshake
        Reload-Finish $r
    }
    $b = @{
        Ctx = $Ctx; Id = 'G-08-RESTORE'; What = 'pom.xml put back, and the broken src/test file deleted'
        Edits = @(@{ Op = 'write'; Path = $pom; Content = $orig }, @{ Op = 'delete'; Path = $test })
    }
    $r2 = Reload-JvmCase @b
    if ($r2) {
        Reload-CheckRestored -Ctx $Ctx -R $r2 -Paths @($pom)
        Reload-Finish $r2
    }
}

function Reload-G09 {
    param([Parameter(Mandatory)] $Ctx)
    $cfg = Reload-RepoFile $Ctx '.mvn/jvm.config'
    $orig = Reload-Original $Ctx $cfg
    $nl = "`n"
    $base = ''
    if ($null -ne $orig) {
        $nl = Reload-Newline $orig
        $base = $orig
        if ($base.Length -gt 0 -and -not $base.EndsWith("`n")) { $base += $nl }
    }
    $a = @{
        Ctx = $Ctx; Id = 'G-09'; What = '.mvn/jvm.config: one harmless JVM option added (-Dhc.probe=g09)'
        Edits = @(@{ Op = 'write'; Path = $cfg; Content = ($base + '-Dhc.probe=g09' + $nl) })
    }
    $r = Reload-JvmCase @a
    if ($r) { Reload-Finish $r }
    $back = @{ Op = 'write'; Path = $cfg; Content = $orig }
    if ($null -eq $orig) { $back = @{ Op = 'delete'; Path = $cfg } }
    $b = @{ Ctx = $Ctx; Id = 'G-09-RESTORE'; What = '.mvn/jvm.config put back'; Edits = @($back) }
    $r2 = Reload-JvmCase @b
    if ($r2) {
        Reload-CheckRestored -Ctx $Ctx -R $r2 -Paths @($cfg)
        Reload-Finish $r2
    }
}

function Reload-G10 {
    param([Parameter(Mandatory)] $Ctx)
    $req = @('R7', 'R6')
    $dep = $null
    foreach ($d in $script:ReloadDepCandidates) {
        if (-not (Reload-CpHas $Ctx.BaselineCp $d.Artifact)) { $dep = $d; break }
    }
    if (-not $dep) {
        Reload-Add -Id 'G-10' -Status 'SKIP' -Req $req -Message ('every candidate ({0}) is on the classpath already, so adding one would prove nothing' -f (@($script:ReloadDepCandidates | ForEach-Object { $_.Artifact }) -join ', '))
        return
    }
    $gav = "$($dep.Group):$($dep.Artifact):$($dep.Version)"
    $pom = Reload-RepoFile $Ctx 'pom.xml'
    $orig = Reload-Original $Ctx $pom
    $new = Reload-PomAddDependency -Pom $orig -Lines (Reload-DepLines -Dep $dep)
    $bad = Reload-PomProblem -Old $orig -New $new -Added @($dep.Artifact)
    if ($bad) {
        Reload-Add -Id 'G-10' -Status 'FAIL' -Req $req -Message "harness: adding $gav did not give a valid pom.xml ($bad), so it was not written"
        return
    }
    $a = @{ Ctx = $Ctx; Id = 'G-10'; Req = $req; What = "$gav added to <dependencies>"; Edits = @(@{ Op = 'write'; Path = $pom; Content = $new }) }
    $r = Reload-JvmCase @a
    if ($r) {
        $cp = Reload-DevClasspath $Ctx
        $live = Reload-LiveClasspath $Ctx $r.Pid1
        $r.Evidence.Add((Reload-SaveClasspaths -Name 'G-10-classpath.txt' -Cp $cp -Live $live))
        if (Reload-CpHas $cp $dep.Artifact) { $r.Notes.Add("dev-classpath.txt has $($dep.Artifact)") }
        else { $r.Problems.Add("dev-classpath.txt has no $($dep.Artifact) jar") }
        if (Reload-CpHas $live $dep.Artifact) { $r.Notes.Add("so does the live java.class.path") }
        else { $r.Problems.Add("the live java.class.path (jcmd $($r.Pid1) VM.system_properties) has no $($dep.Artifact) jar") }
        Reload-CheckLiveCp -R $r -Cp $cp -Live $live
        Reload-Finish $r
    }
    $b = @{ Ctx = $Ctx; Id = 'G-10-REMOVE'; Req = $req; What = "$gav removed again"; Edits = @(@{ Op = 'write'; Path = $pom; Content = $orig }) }
    $r2 = Reload-JvmCase @b
    if ($r2) {
        $cp = Reload-DevClasspath $Ctx
        $live = Reload-LiveClasspath $Ctx $r2.Pid1
        $r2.Evidence.Add((Reload-SaveClasspaths -Name 'G-10-REMOVE-classpath.txt' -Cp $cp -Live $live))
        if (Reload-CpHas $cp $dep.Artifact) { $r2.Problems.Add("dev-classpath.txt still has $($dep.Artifact)") }
        if (Reload-CpHas $live $dep.Artifact) { $r2.Problems.Add("the live java.class.path still has $($dep.Artifact)") }
        if ($cp -cne $Ctx.BaselineCp) { $r2.Problems.Add("dev-classpath.txt is not the one the suite started with: $(Reload-CpDiff $Ctx.BaselineCp $cp 'the start' 'now')") }
        else { $r2.Notes.Add('dev-classpath.txt is again byte for byte the one the suite started with') }
        Reload-CheckLiveCp -R $r2 -Cp $cp -Live $live
        Reload-CheckRestored -Ctx $Ctx -R $r2 -Paths @($pom)
        Reload-Finish $r2
    }
}

# Two steps on purpose. Adding commons-text brings commons-lang3 in; adding
# ONLY the <exclusion> then changes nothing but what one dependency drags
# along - the edit the dependency cache of a long-lived mvnd daemon does not
# notice. The container's classpath must then equal what a fresh ./mvnw
# resolves.
function Reload-G11 {
    param([Parameter(Mandatory)] $Ctx)
    $req = @('R7', 'R6')
    $text = $script:ReloadTextDep
    $lang = $script:ReloadLangDep
    if (Reload-CpHas $Ctx.BaselineCp $text.Artifact) {
        Reload-Add -Id 'G-11' -Status 'SKIP' -Req $req -Message "$($text.Artifact) is on the classpath already, so adding it changes nothing"
        return
    }
    $langElsewhere = Reload-CpHas $Ctx.BaselineCp $lang.Artifact
    $pom = Reload-RepoFile $Ctx 'pom.xml'
    $orig = Reload-Original $Ctx $pom
    $withText = Reload-PomAddDependency -Pom $orig -Lines (Reload-DepLines -Dep $text)
    $withExcl = Reload-PomAddDependency -Pom $orig -Lines (Reload-DepLines -Dep $text -Exclude $lang)
    $bad = Reload-PomProblem -Old $orig -New $withText -Added @($text.Artifact)
    if (-not $bad) { $bad = Reload-PomProblem -Old $orig -New $withExcl -Added @($text.Artifact) }
    if ($bad) {
        Reload-Add -Id 'G-11' -Status 'FAIL' -Req $req -Message "harness: adding $($text.Artifact) did not give a valid pom.xml ($bad), so it was not written"
        return
    }
    $gav = "$($text.Group):$($text.Artifact):$($text.Version)"

    $a = @{ Ctx = $Ctx; Id = 'G-11-ADD'; Req = $req; What = "$gav added"; Edits = @(@{ Op = 'write'; Path = $pom; Content = $withText }) }
    $r1 = Reload-JvmCase @a
    if ($r1) {
        $cp = Reload-DevClasspath $Ctx
        $r1.Evidence.Add((Reload-SaveClasspaths -Name 'G-11-ADD-classpath.txt' -Cp $cp -Live ''))
        if (-not (Reload-CpHas $cp $text.Artifact)) { $r1.Problems.Add("dev-classpath.txt has no $($text.Artifact)") }
        if (-not (Reload-CpHas $cp $lang.Artifact)) { $r1.Problems.Add("dev-classpath.txt has no $($lang.Artifact), which $($text.Artifact) depends on") }
        else { $r1.Notes.Add("$($lang.Artifact) came in with it") }
        Reload-Finish $r1
    }

    $b = @{ Ctx = $Ctx; Id = 'G-11'; Req = $req; What = "an <exclusion> of $($lang.Artifact) added to $($text.Artifact)"; Edits = @(@{ Op = 'write'; Path = $pom; Content = $withExcl }) }
    $r2 = Reload-JvmCase @b
    if ($r2) {
        $cp = Reload-DevClasspath $Ctx
        $live = Reload-LiveClasspath $Ctx $r2.Pid1
        $fresh = Reload-FreshClasspath -Ctx $Ctx -Name 'G-11'
        $r2.Evidence.Add($fresh.Evidence)
        $r2.Evidence.Add((Reload-SaveClasspaths -Name 'G-11-classpath.txt' -Cp $cp -Live $live -Fresh $fresh.Cp))
        if (-not $fresh.Ok) {
            if ($fresh.Blocked) { $r2.Warnings.Add("no fresh classpath to compare with: $($fresh.Why)") }
            else { $r2.Problems.Add("no fresh classpath to compare with: $($fresh.Why)") }
        }
        elseif ($cp -cne $fresh.Cp) { $r2.Problems.Add("dev-classpath.txt is NOT what a fresh ./mvnw resolves - a cached resolution survived the pom change: $(Reload-CpDiff $cp $fresh.Cp 'dev-classpath.txt' 'the fresh resolve')") }
        else { $r2.Notes.Add("dev-classpath.txt equals a fresh ./mvnw resolve in a one-off container ($(@($cp.Split(':')).Count) entries)") }
        if (-not (Reload-CpHas $cp $text.Artifact)) { $r2.Problems.Add("dev-classpath.txt has no $($text.Artifact)") }
        if ($langElsewhere) { $r2.Warnings.Add("$($lang.Artifact) also comes from another dependency, so the exclusion leaves it on the classpath and this case cannot tell a stale resolution from a fresh one by that jar - the comparison with the fresh resolve still holds") }
        elseif (Reload-CpHas $cp $lang.Artifact) { $r2.Problems.Add("$($lang.Artifact) is still on dev-classpath.txt: the exclusion was not seen") }
        else { $r2.Notes.Add("$($lang.Artifact) gone") }
        Reload-CheckLiveCp -R $r2 -Cp $cp -Live $live
        Reload-Finish $r2
    }

    $c = @{ Ctx = $Ctx; Id = 'G-11-RESTORE'; Req = $req; What = 'pom.xml put back'; Edits = @(@{ Op = 'write'; Path = $pom; Content = $orig }) }
    $r3 = Reload-JvmCase @c
    if ($r3) {
        $cp = Reload-DevClasspath $Ctx
        if ($cp -cne $Ctx.BaselineCp) { $r3.Problems.Add("dev-classpath.txt is not the one the suite started with: $(Reload-CpDiff $Ctx.BaselineCp $cp 'the start' 'now')") }
        else { $r3.Notes.Add('dev-classpath.txt is again byte for byte the one the suite started with') }
        Reload-CheckRestored -Ctx $Ctx -R $r3 -Paths @($pom)
        Reload-Finish $r3
    }
}

function Reload-G12 {
    param([Parameter(Mandatory)] $Ctx)
    $pom = Reload-RepoFile $Ctx 'pom.xml'
    $orig = Reload-Original $Ctx $pom
    $broken = Reload-PomBreak $orig
    if ((Reload-PomArtifacts $broken).Ok) {
        Reload-Add -Id 'G-12' -Status 'FAIL' -Req @('R7') -Message 'harness: the pom meant to be broken still parses as XML, so it was not written'
        return
    }
    $pre = Reload-Http -Url $Ctx.HealthUrl -TimeoutSec 5
    # A failed full build is retried, first 30s later. As in G-05, the window
    # waits for that first retry, so that the restore below cannot land while
    # it builds - which would make two builds and two JVMs of one save. The
    # next retry comes a minute after this one: time enough for the restore.
    $a = @{
        Ctx = $Ctx; Id = 'G-12'; What = 'pom.xml made invalid XML (an unclosed element)'
        Edits = @(@{ Op = 'write'; Path = $pom; Content = $broken })
        Restarts = 0; Events = @('build-failed', 'build-broken'); Counts = @{ 'build-failed' = 2 }
        FailOn = @(); Health = $true
        TimeoutSec = $script:ReloadBuildSec
    }
    $r = Reload-SourceCase @a
    if ($r) {
        Reload-CheckHealth -R $r -Pre $pre
        Reload-Finish $r
    }
    $b = @{ Ctx = $Ctx; Id = 'G-12-RESTORE'; What = 'pom.xml put back'; Edits = @(@{ Op = 'write'; Path = $pom; Content = $orig }) }
    $r2 = Reload-JvmCase @b
    if ($r2) {
        Reload-CheckRestored -Ctx $Ctx -R $r2 -Paths @($pom)
        Reload-Finish $r2
    }
}

# The host clock and the Docker VM's disagree - WSL2 notoriously, after a
# sleep - and an edit that looks older than its class file must still be
# compiled and served.
function Reload-G13 {
    param([Parameter(Mandatory)] $Ctx)
    $name = 'HcProbeC'
    $path = Reload-ProbePath $Ctx $name
    $v = Reload-NextVersion $Ctx $name
    $a = @{
        Ctx = $Ctx; Id = 'G-13'; What = "HcProbeC edited ($v), then its mtime set an hour into the past"
        Edits = @((Reload-ProbeEdit -Ctx $Ctx -Name $name -Version $v), @{ Op = 'mtime'; Path = $path; AgoSec = 3600 })
        Markers = @{ $name = $v }
    }
    $r = Reload-SourceCase @a
    if ($r) {
        $age = ([DateTime]::UtcNow - [System.IO.File]::GetLastWriteTimeUtc($path)).TotalMinutes
        if ($age -lt 50) { $r.Problems.Add("the file did not stay backdated (its mtime is only $([int]$age) min old), so this proves nothing about old mtimes") }
        else { $r.Notes.Add("mtime $([int]$age) min in the past, served anyway") }
        Reload-Finish $r
    }
}

function Reload-G14 {
    param([Parameter(Mandatory)] $Ctx)
    $r = Reload-NewResult -Id 'G-14' -Req @('R7') -What 'touch only: HcProbeC given a new mtime, same bytes'
    $path = Reload-ProbePath $Ctx 'HcProbeC'
    $sha0 = Reload-Sha $path
    if ($sha0 -eq 'ABSENT') {
        Reload-Add -Id 'G-14' -Status 'FAIL' -Req @('R7') -Message 'HcProbeC.java is not there to touch (G-05-FIX should have left it)'
        return
    }
    $r.Pid0 = Reload-AppPid $Ctx
    $t0 = Reload-Now $Ctx
    Reload-ApplyEdits -Ctx $Ctx -Edits @(@{ Op = 'mtime'; Path = $path; AgoSec = 0 })
    $w = Reload-Watch -Ctx $Ctx -Since $t0 -Started 0 -MinSec (Reload-ObserveSec $Ctx) -TimeoutSec $script:ReloadSourceSec -FailOn $script:ReloadSourceFailOn
    $r.W = $w
    $r.Evidence.Add((Reload-SaveWindow -Ctx $Ctx -Name 'G-14' -W $w))
    if (-not $w.Ok) { Reload-Timeout -Ctx $Ctx -R $r; return }
    $r.Pid1 = Reload-AppPid $Ctx
    if ((Reload-Sha $path) -ne $sha0) { $r.Problems.Add('the bytes changed: this was meant to be a touch') }
    if ($r.Pid0 -ne $r.Pid1) { $r.Problems.Add("the pid changed ($($r.Pid0) -> $($r.Pid1))") }
    $n = $w.P.Started
    $r.Notes.Add("$n restart(s) after a touch - dev-reload.sh fingerprints path, size and mtime, so a new mtime is a change and one restart is what it should cause")
    Reload-Finish -R $r -PassStatus 'INFO'
}

function Reload-G15 {
    param([Parameter(Mandatory)] $Ctx)
    $name = 'HcProbeC'
    $r = Reload-NewResult -Id 'G-15' -Req @('R7') -What 'a burst: HcProbeC saved five times within a second'
    $r.Pid0 = Reload-AppPid $Ctx
    $t0 = Reload-Now $Ctx
    $written = @()
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    for ($k = 0; $k -lt 5; $k++) {
        $v = Reload-NextVersion $Ctx $name
        Reload-ApplyEdits -Ctx $Ctx -Edits @(Reload-ProbeEdit -Ctx $Ctx -Name $name -Version $v)
        $written += $v
        if ($k -lt 4) { Start-Sleep -Milliseconds 200 }
    }
    $burstMs = $sw.ElapsedMilliseconds
    $last = $written[$written.Count - 1]
    $w = Reload-Watch -Ctx $Ctx -Since $t0 -Started 1 -TimeoutSec $script:ReloadSourceSec -FailOn $script:ReloadSourceFailOn
    $r.W = $w
    $r.Evidence.Add((Reload-SaveWindow -Ctx $Ctx -Name 'G-15' -W $w))
    if (-not $w.Ok) { Reload-Timeout -Ctx $Ctx -R $r; return }
    $r.Pid1 = Reload-AppPid $Ctx
    $r.Notes.Add("written $($written -join ', ') in $burstMs ms")
    if ($burstMs -gt 1500) { $r.Warnings.Add("the five writes took $burstMs ms, not under a second - this machine was too slow to make it a burst") }
    $n = $w.P.Started
    if ($n -eq 2) { $r.Warnings.Add('two restarts for one burst: the settle check split it') }
    elseif ($n -ne 1) { $r.Problems.Add("$n restarts for one burst") }
    if ($r.Pid0 -ne $r.Pid1) { $r.Problems.Add("the pid changed ($($r.Pid0) -> $($r.Pid1))") }
    $served = @($w.P.Probes | Where-Object { $_.Name -eq $name })
    if ($served.Count -eq 0) { $r.Problems.Add("HcProbeC printed nothing: no version of the burst was served") }
    else {
        $got = $served[$served.Count - 1].Version
        if ($got -ne $last) { $r.Problems.Add("the last save ($last) is not what is served ($got)") }
        else { $r.Notes.Add("the last save ($last) is served") }
    }
    Reload-Finish $r
}

# JDWP is one connection at a time; a DevTools restart happens inside the JVM,
# so a session opened before it must still be answered after it.
function Reload-G16 {
    param([Parameter(Mandatory)] $Ctx)
    $req = @('R11', 'R7')
    $name = 'HcProbeC'
    $port = [int]$Ctx.Svc.Debug
    $r = Reload-NewResult -Id 'G-16' -Req $req -What "a JDWP session on 127.0.0.1:$port kept open across a DevTools restart"
    $sock = Reload-Sockets $Ctx
    if (@($sock.Items | Where-Object { $_.State -eq 'ESTAB' }).Count) {
        Reload-Add -Id 'G-16' -Status 'SKIP' -Req $req -Message "a debugger is attached to $($Ctx.Name) (an ESTABLISHED connection on container port 5005), and JDWP takes one at a time: detach it and run -Suite reload again"
        return
    }
    $conn = Reload-JdwpOpen -Port $port
    if (-not $conn.Ok) {
        Reload-Add -Id 'G-16' -Status 'FAIL' -Req $req -Message "no JDWP session could be opened on 127.0.0.1:${port}: $($conn.Detail)"
        return
    }
    try {
        $r.Pid0 = Reload-AppPid $Ctx
        $t0 = Reload-Now $Ctx
        $v = Reload-NextVersion $Ctx $name
        Reload-ApplyEdits -Ctx $Ctx -Edits @(Reload-ProbeEdit -Ctx $Ctx -Name $name -Version $v)
        $w = Reload-Watch -Ctx $Ctx -Since $t0 -Started 1 -TimeoutSec $script:ReloadSourceSec -FailOn $script:ReloadSourceFailOn
        $r.W = $w
        $r.Evidence.Add((Reload-SaveWindow -Ctx $Ctx -Name 'G-16' -W $w))
        if (-not $w.Ok) { Reload-Timeout -Ctx $Ctx -R $r; return }
        $r.Pid1 = Reload-AppPid $Ctx
        Reload-CheckDevtools -R $r -Restarts 1
        Reload-CheckMarkers -R $r -Want @{ $name = $v }
        $ans = Reload-JdwpVersion -Conn $conn
        if ($ans.Ok) { $r.Notes.Add("after the restart the same session answered VirtualMachine.Version: $($ans.Detail)") }
        else { $r.Problems.Add("the session opened before the restart did not answer VirtualMachine.Version after it: $($ans.Detail)") }
        Reload-Finish $r
    }
    finally { if ($conn.Client) { $conn.Client.Dispose() } }
}

# The readiness gate: a source save while a new JVM boots must wait for
# app-ready - DevTools' watcher has no snapshot yet - and then be compiled and
# served exactly once.
function Reload-G17 {
    param([Parameter(Mandatory)] $Ctx)
    $req = @('R7')
    $name = 'HcProbeC'
    $pom = Reload-RepoFile $Ctx 'pom.xml'
    $orig = Reload-Original $Ctx $pom
    $r = Reload-NewResult -Id 'G-17' -Req $req -What 'a source save while a new JVM boots (after a pom.xml edit)'
    $r.Pid0 = Reload-AppPid $Ctx
    $t0 = Reload-Now $Ctx
    Reload-ApplyEdits -Ctx $Ctx -Edits @(@{ Op = 'write'; Path = $pom; Content = (Reload-PomComment $orig "hc-probe G-17 $($Ctx.Nonce)") })

    # Save the moment the new JVM is announced, well before it can answer.
    $saved = ''
    $seenReady = $false
    $p = $null
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $script:ReloadBuildSec) {
        $p = Reload-ParseLog -Ctx $Ctx -Text (Get-ContainerLog -Container $Ctx.Container -Since $t0)
        if ((Reload-Count $p 'app-started') -ge 1) {
            $seenReady = (Reload-Count $p 'app-ready') -ge 1
            $saved = Reload-NextVersion $Ctx $name
            Reload-ApplyEdits -Ctx $Ctx -Edits @(Reload-ProbeEdit -Ctx $Ctx -Name $name -Version $saved)
            break
        }
        if ((Reload-Count $p 'build-broken') -or (Reload-Count $p 'launch-refused')) { break }
        Start-Sleep -Milliseconds 500
    }
    if (-not $saved) {
        $r.W = [pscustomobject]@{ Ok = $false; TimedOut = $true; FailedOn = ''; Secs = [int]$sw.Elapsed.TotalSeconds; P = $p; Codes = @(); Text = $(if ($p) { $p.Text } else { '' }); Since = $t0 }
        if ($null -eq $p) { $r.W.P = Reload-ParseLog -Ctx $Ctx -Text '' }
        $r.Evidence.Add((Reload-SaveWindow -Ctx $Ctx -Name 'G-17' -W $r.W))
        Reload-Timeout -Ctx $Ctx -R $r
    }
    else {
        $w = Reload-Watch -Ctx $Ctx -Since $t0 -Started 2 -Events @('app-ready', 'trigger-touched') -TimeoutSec $script:ReloadBuildSec -FailOn $script:ReloadSourceFailOn
        $r.W = $w
        $r.Evidence.Add((Reload-SaveWindow -Ctx $Ctx -Name 'G-17' -W $w))
        if (-not $w.Ok) { Reload-Timeout -Ctx $Ctx -R $r }
        else {
            $r.Pid1 = Reload-AppPid $Ctx
            Reload-CheckBootSave -R $r -Saved $saved -Name $name -SeenReady $seenReady
            Reload-Finish $r
        }
    }
    $b = @{ Ctx = $Ctx; Id = 'G-17-RESTORE'; What = 'pom.xml put back'; Edits = @(@{ Op = 'write'; Path = $pom; Content = $orig }) }
    $r2 = Reload-JvmCase @b
    if ($r2) {
        Reload-CheckRestored -Ctx $Ctx -R $r2 -Paths @($pom)
        Reload-Finish $r2
    }
}

function Reload-CheckBootSave {
    param([Parameter(Mandatory)] $R, [string] $Saved, [string] $Name, [bool] $SeenReady)
    $p = $R.W.P
    $o = @($p.Order)
    $iStart = Reload-FirstIdx -Order $o -Kinds @('app-started') -After -1
    $iDefer = Reload-FirstIdx -Order $o -Kinds @('reload-deferred') -After $iStart
    $iReady = Reload-FirstIdx -Order $o -Kinds @('app-ready') -After $iStart
    $iSrc = Reload-FirstIdx -Order $o -Kinds @('source-changed', 'compile-start', 'build-pending') -After $iStart
    $trig = @($o | Where-Object { $_.Kind -eq 'trigger-touched' -and $_.I -gt $iStart })
    $ns = Reload-Count $p 'app-started'
    $nx = Reload-Count $p 'app-stopped'
    if ($ns -ne 1 -or $nx -ne 1) { $R.Problems.Add("app-stopped $nx and app-started $ns, expected one new JVM") }
    if ($SeenReady -or ($iDefer -lt 0 -and $iSrc -gt $iReady -and $iReady -ge 0)) {
        # The save reached dev-reload.sh only after the boot: nothing here
        # says anything about the gate.
        $R.Warnings.Add('inconclusive: the save was only noticed after app-ready (the JVM booted faster than the save landed), so the deferral was not exercised')
    }
    elseif ($iDefer -lt 0) { $R.Problems.Add('no reload-deferred: the save during the boot was not held back') }
    elseif ($iReady -ge 0 -and $iDefer -gt $iReady) { $R.Problems.Add('reload-deferred came after app-ready') }
    else { $R.Notes.Add('reload-deferred while booting') }
    if ($iReady -lt 0) { $R.Problems.Add('no app-ready after the new JVM started') }
    elseif ($iSrc -ge 0 -and $iSrc -lt $iReady) { $R.Problems.Add('the save was compiled while the application was still booting') }
    if ($trig.Count -ne 1) { $R.Problems.Add("trigger-touched x$($trig.Count) after the launch, expected exactly one") }
    elseif ($iReady -ge 0 -and $trig[0].I -lt $iReady) { $R.Problems.Add('the trigger was touched before app-ready') }
    else { $R.Notes.Add('exactly one trigger-touched, after app-ready') }
    if ($p.Started -ne 2) { $R.Problems.Add("Started x$($p.Started), expected 2 (the new JVM, then the DevTools restart)") }
    $served = @($p.Probes | Where-Object { $_.Name -eq $Name })
    if ($served.Count -eq 0) { $R.Problems.Add("$Name printed nothing") }
    else {
        $lastProbe = $served[$served.Count - 1]
        if ($lastProbe.Version -ne $Saved) { $R.Problems.Add("the save ($Saved) is not what is served ($($lastProbe.Version))") }
        elseif ($trig.Count -ge 1 -and $lastProbe.I -lt $trig[0].I) { $R.Problems.Add("$Name $Saved was printed before the trigger - it cannot be the reload") }
        else { $R.Notes.Add("the save ($Saved) is served") }
    }
    $announced = Reload-AnnouncedPid $p
    if (-not $R.Pid1) { $R.Problems.Add('no application JVM in jcmd -l afterwards') }
    elseif ($R.Pid1 -eq $R.Pid0) { $R.Problems.Add("the pid is still $($R.Pid0): the pom.xml edit did not replace the JVM") }
    elseif ($announced -and $announced -ne $R.Pid1) { $R.Problems.Add("jcmd -l shows pid $($R.Pid1), but app-started announced ${announced}: the DevTools restart should have kept that JVM") }
}

# ---------------------------------------------------------------------------
# The two kinds of case
# ---------------------------------------------------------------------------

# A change dev-reload.sh should answer with DevTools restarts - $Restarts of
# them, zero included - in the SAME JVM. Records a timeout itself and returns
# $null; otherwise returns the result for the caller to add to and finish.
function Reload-SourceCase {
    param(
        [Parameter(Mandatory)] $Ctx,
        [Parameter(Mandatory)][string] $Id,
        [Parameter(Mandatory)][string] $What,
        [object[]] $Edits = @(),
        [string[]] $Req = @('R7'),
        [string] $Tag = '',
        [int] $Restarts = 1,
        [hashtable] $Markers = @{},
        [string[]] $NoMarkers = @(),
        [string[]] $Present = @(),
        [string[]] $Absent = @(),
        [string[]] $Events = @(),
        [hashtable] $Counts = @{},
        [AllowNull()][string[]] $FailOn = $null,
        [int] $MinSec = 0,
        [int] $TimeoutSec = 0,
        [switch] $Health
    )
    if (-not $Tag) { $Tag = $Id }
    if ($null -eq $FailOn) { $FailOn = $script:ReloadSourceFailOn }
    if ($TimeoutSec -le 0) { $TimeoutSec = $script:ReloadSourceSec }
    Reload-Say "${Id}: $What"
    $r = Reload-NewResult -Id $Id -Req $Req -What $What
    $r.Pid0 = Reload-AppPid $Ctx
    $t0 = Reload-Now $Ctx
    Reload-ApplyEdits -Ctx $Ctx -Edits $Edits
    $w = Reload-Watch -Ctx $Ctx -Since $t0 -Started $Restarts -Events $Events -Counts $Counts -TimeoutSec $TimeoutSec -MinSec $MinSec -FailOn $FailOn -Health:$Health
    $r.W = $w
    $r.Evidence.Add((Reload-SaveWindow -Ctx $Ctx -Name $Tag -W $w))
    if (-not $w.Ok) {
        Reload-Timeout -Ctx $Ctx -R $r -Tag $Tag
        return $null
    }
    $r.Pid1 = Reload-AppPid $Ctx
    Reload-CheckDevtools -R $r -Restarts $Restarts
    Reload-CheckMarkers -R $r -Want $Markers -Unwanted $NoMarkers
    foreach ($rel in $Present) {
        if (-not (Reload-InClasses $Ctx $rel)) { $r.Problems.Add("/app/target/classes/$rel is missing") }
    }
    foreach ($rel in $Absent) {
        if (Reload-InClasses $Ctx $rel) { $r.Problems.Add("/app/target/classes/$rel is still there") }
        else { $r.Notes.Add("$(Reload-Leaf $rel) gone from target/classes") }
    }
    return $r
}

# A change to pom.xml, .mvn or lombok.config: exactly one NEW JVM.
function Reload-JvmCase {
    param(
        [Parameter(Mandatory)] $Ctx,
        [Parameter(Mandatory)][string] $Id,
        [Parameter(Mandatory)][string] $What,
        [object[]] $Edits = @(),
        [string[]] $Req = @('R7'),
        [string[]] $Events = @('build-ok')
    )
    Reload-Say "${Id}: $What"
    $r = Reload-NewResult -Id $Id -Req $Req -What $What
    $r.Pid0 = Reload-AppPid $Ctx
    $t0 = Reload-Now $Ctx
    Reload-ApplyEdits -Ctx $Ctx -Edits $Edits
    $w = Reload-Watch -Ctx $Ctx -Since $t0 -Started 1 -Events (@('build-changed', 'app-started') + @($Events)) -TimeoutSec $script:ReloadBuildSec -FailOn $script:ReloadBuildFailOn
    $r.W = $w
    $r.Evidence.Add((Reload-SaveWindow -Ctx $Ctx -Name $Id -W $w))
    if (-not $w.Ok) {
        Reload-Timeout -Ctx $Ctx -R $r
        return $null
    }
    $r.Pid1 = Reload-AppPid $Ctx
    $p = $w.P
    $ns = Reload-Count $p 'app-started'
    $nx = Reload-Count $p 'app-stopped'
    if ($nx -ne 1 -or $ns -ne 1) { $r.Problems.Add("app-stopped $nx and app-started $ns, expected exactly one of each") }
    if ($p.Started -ne 1) { $r.Problems.Add("Started x$($p.Started), expected once") }
    if ($p.Restarting) { $r.Problems.Add("DevTools restarted as well (Restarting due to x$($p.Restarting))") }
    $nb = Reload-Count $p 'build-changed'
    if ($nb -ne 1) { $r.Problems.Add("build-changed x$nb, expected once") }
    $announced = Reload-AnnouncedPid $p
    if (-not $r.Pid1) { $r.Problems.Add('no application JVM in jcmd -l afterwards') }
    elseif ($r.Pid1.Contains(',')) { $r.Problems.Add("two application JVMs afterwards ($($r.Pid1))") }
    elseif ($r.Pid1 -eq $r.Pid0) { $r.Problems.Add("the pid is still $($r.Pid0): the JVM was not replaced") }
    elseif ($announced -and $announced -ne $r.Pid1) { $r.Problems.Add("jcmd -l shows pid $($r.Pid1), but app-started announced $announced") }
    else { $r.Notes.Add("new JVM, pid $($r.Pid0) -> $($r.Pid1)") }
    return $r
}

function Reload-CheckDevtools {
    param([Parameter(Mandatory)] $R, [int] $Restarts)
    $p = $R.W.P
    if ($p.Started -ne $Restarts) { $R.Problems.Add("Started x$($p.Started), expected $Restarts") }
    if ($p.Restarting -ne $Restarts) { $R.Problems.Add("DevTools 'Restarting due to' x$($p.Restarting), expected $Restarts") }
    $ns = Reload-Count $p 'app-started'
    $nx = Reload-Count $p 'app-stopped'
    if ($ns -or $nx) { $R.Problems.Add("a new JVM instead of a context restart (app-stopped $nx, app-started $ns)") }
    if (-not $R.Pid0 -or -not $R.Pid1) { $R.Problems.Add("the application pid could not be read (before '$($R.Pid0)', after '$($R.Pid1)')") }
    elseif ($R.Pid0 -ne $R.Pid1) { $R.Problems.Add("the pid changed from $($R.Pid0) to $($R.Pid1): not the same JVM") }
    else { $R.Notes.Add("same pid $($R.Pid1)") }
}

# $Want: name -> the one version that must be printed, exactly once.
# $Unwanted: names that must not print at all; '*' for any probe.
function Reload-CheckMarkers {
    param([Parameter(Mandatory)] $R, [hashtable] $Want = @{}, [string[]] $Unwanted = @())
    $probes = @($R.W.P.Probes)
    foreach ($name in @($Want.Keys)) {
        $seen = @($probes | Where-Object { $_.Name -eq $name })
        $vers = @($seen | ForEach-Object { $_.Version })
        if ($seen.Count -eq 0) { $R.Problems.Add("HC-PROBE $name $($Want[$name]) was never printed: the change was not served") }
        elseif ($seen.Count -ne 1 -or $vers[0] -ne $Want[$name]) { $R.Problems.Add("expected HC-PROBE $name $($Want[$name]) once, saw: $($vers -join ', ')") }
        else { $R.Notes.Add("HC-PROBE $name $($Want[$name]) printed once") }
    }
    foreach ($name in $Unwanted) {
        $seen = @($probes | Where-Object { $name -eq '*' -or $_.Name -eq $name })
        if ($seen.Count) { $R.Problems.Add('printed, and must not have been: ' + (@($seen | ForEach-Object { "HC-PROBE $($_.Name) $($_.Version)" }) -join ', ')) }
    }
}

# Every poll 200 while a broken edit sits there. If it was not 200 before the
# edit either, what matters is that it never went away.
function Reload-CheckHealth {
    param([Parameter(Mandatory)] $R, [int] $Pre)
    $codes = @($R.W.Codes)
    if ($codes.Count -eq 0) { $R.Problems.Add('/actuator/health was never polled'); return }
    $dist = (@($codes | Group-Object | Sort-Object Name | ForEach-Object { "$($_.Name) x$($_.Count)" }) -join ', ')
    $bad = @($codes | Where-Object { $_ -ne 200 })
    if ($bad.Count -eq 0) { $R.Notes.Add("/actuator/health 200 on all $($codes.Count) polls, one a second"); return }
    $down = @($codes | Where-Object { $_ -eq 0 })
    if ($Pre -ne 200 -and $Pre -ne 0 -and $down.Count -eq 0 -and @($codes | Where-Object { $_ -ne $Pre }).Count -eq 0) {
        $R.Warnings.Add("/actuator/health answered $Pre on every poll ($dist) - never down, but it was not 200 before the edit either, so something else is unhealthy")
        return
    }
    $R.Problems.Add("/actuator/health did not answer 200 on every poll: $dist (before the edit: $Pre; 0 = no answer)")
}

# Mid-suite restores are byte-exact too, or the next case starts from a
# different file than it thinks.
function Reload-CheckRestored {
    param([Parameter(Mandatory)] $Ctx, [Parameter(Mandatory)] $R, [string[]] $Paths)
    foreach ($p in $Paths) {
        if ((Reload-Sha $p) -ne $Ctx.Tracked[$p]) { $R.Problems.Add("$(Reload-Rel $Ctx $p) is not byte for byte its original") }
    }
}

# The new JVM owns the LISTEN socket on container port 5005, and a debugger
# on this machine gets an answer through the published port.
function Reload-CheckJdwpOwner {
    param([Parameter(Mandatory)] $Ctx, [Parameter(Mandatory)] $R, [switch] $Handshake)
    $port = [int]$Ctx.Svc.Debug
    $s = Reload-Sockets $Ctx
    $R.Evidence.Add((Save-Evidence -Suite 'reload' -Name "$($R.Id)-sockets.txt" -Content $s.Text))
    $listen = @($s.Items | Where-Object { $_.State -eq 'LISTEN' })
    $estab = @($s.Items | Where-Object { $_.State -eq 'ESTAB' })
    if ($listen.Count -eq 0) { $R.Problems.Add('nothing LISTENs on container port 5005') }
    else {
        $owners = @($listen | ForEach-Object { $_.Owners } | Where-Object { $_ } | Sort-Object -Unique)
        if ($owners.Count -ne 1 -or $owners[0] -ne $R.Pid1) { $R.Problems.Add("the 5005 LISTEN socket belongs to pid(s) '$($owners -join ',')', not to the new JVM $($R.Pid1)") }
        else { $R.Notes.Add("pid $($R.Pid1) owns the 5005 LISTEN socket") }
    }
    if (-not $Handshake) { return }
    if ($estab.Count) {
        $R.Warnings.Add("a debugger is attached to the new JVM already, so the handshake from here was not tried (JDWP takes one at a time)")
        return
    }
    $hs = Reload-JdwpOpen -Port $port
    if ($hs.Ok) {
        $R.Notes.Add("127.0.0.1:$port answered the JDWP handshake")
        $hs.Client.Dispose()
    }
    else { $R.Problems.Add("127.0.0.1:$port did not answer a JDWP handshake: $($hs.Detail)") }
}

function Reload-CheckLiveCp {
    param([Parameter(Mandatory)] $R, [AllowEmptyString()][string] $Cp, [AllowEmptyString()][string] $Live)
    if (-not $Live) { $R.Problems.Add('the live java.class.path could not be read with jcmd'); return }
    if ($Live -cne ('/app/target/classes:' + $Cp)) { $R.Problems.Add("the live java.class.path is not /app/target/classes followed by dev-classpath.txt: $(Reload-CpDiff ('/app/target/classes:' + $Cp) $Live 'the file' 'the JVM')") }
    else { $R.Notes.Add('the live java.class.path is /app/target/classes + dev-classpath.txt, exactly') }
}

# ---------------------------------------------------------------------------
# Watching the log
# ---------------------------------------------------------------------------

# Polls the container's log since $Since until: at least $Started Spring
# "Started" lines, every event in $Events, every event in $Counts at least that
# many times, at least $MinSec gone, nothing in flight - and then
# $script:ReloadQuietSec with nothing new logged. Gives up
# early when a $FailOn event was logged and nothing follows it for
# $script:ReloadGiveUpSec. With -Health, GETs /actuator/health once a second
# throughout.
function Reload-Watch {
    param(
        [Parameter(Mandatory)] $Ctx,
        [Parameter(Mandatory)][string] $Since,
        [int] $Started = 0,
        [string[]] $Events = @(),
        [hashtable] $Counts = @{},
        [int] $TimeoutSec = 420,
        [int] $MinSec = 0,
        [string[]] $FailOn = @(),
        [switch] $Health
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $codes = [System.Collections.Generic.List[int]]::new()
    $p = $null
    $quietAt = -1.0
    $quietKey = ''
    $failKey = $null
    $failAt = 0.0
    $nextLog = 0.0
    $done = $false
    $timedOut = $false
    $failedOn = ''
    while ($true) {
        $el = $sw.Elapsed.TotalSeconds
        if ($Health) { $codes.Add((Reload-Http -Url $Ctx.HealthUrl -TimeoutSec 2)) }
        if ($el -ge $nextLog -or $null -eq $p) {
            $nextLog = $el + $script:ReloadLogPollSec
            $p = Reload-ParseLog -Ctx $Ctx -Text (Get-ContainerLog -Container $Ctx.Container -Since $Since)
            $goal = ($p.Started -ge $Started) -and ($el -ge $MinSec) -and (-not $p.Busy)
            foreach ($e in $Events) { if ((Reload-Count $p $e) -lt 1) { $goal = $false } }
            foreach ($e in $Counts.Keys) { if ((Reload-Count $p $e) -lt [int]$Counts[$e]) { $goal = $false } }
            if ($goal) {
                $failKey = $null
                if ($quietAt -lt 0 -or $p.Key -ne $quietKey) { $quietAt = $el; $quietKey = $p.Key }
                elseif (($el - $quietAt) -ge $script:ReloadQuietSec) { $done = $true; break }
            }
            else {
                $quietAt = -1.0
                $failed = @($FailOn | Where-Object { (Reload-Count $p $_) -gt 0 })
                if ($failed.Count -and -not $p.Busy) {
                    if ($p.Key -ne $failKey) { $failKey = $p.Key; $failAt = $el }
                    elseif (($el - $failAt) -ge $script:ReloadGiveUpSec) { $failedOn = $failed[0]; break }
                }
                else { $failKey = $null }
            }
        }
        if ($el -ge $TimeoutSec) { $timedOut = $true; break }
        $spent = $sw.Elapsed.TotalSeconds - $el
        Start-Sleep -Milliseconds ([int][Math]::Max(100, 1000 - $spent * 1000))
    }
    return [pscustomobject]@{
        Ok = $done; TimedOut = $timedOut; FailedOn = $failedOn; Secs = [int]$sw.Elapsed.TotalSeconds
        P = $p; Codes = $codes.ToArray(); Text = $p.Text; Since = $Since
    }
}

# The log as the cases read it: dev-reload.sh events in order, Spring's
# "Started <App> in", DevTools' "Restarting due to", and the probes' markers.
# Busy = the last thing that begins work comes after the last thing that ends
# some. Key changes whenever anything countable is logged.
function Reload-ParseLog {
    param([Parameter(Mandatory)] $Ctx, [AllowNull()][AllowEmptyString()][string] $Text)
    $clean = ([string]$Text).Replace("`r", '')
    $lines = @($clean -split "`n")
    $events = @{}
    $order = [System.Collections.Generic.List[object]]::new()
    $probes = [System.Collections.Generic.List[object]]::new()
    $started = 0
    $restarting = 0
    $total = 0
    $lastBegin = -1
    $lastEnd = -1
    $last = ''
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $l = $lines[$i]
        if (-not $l) { continue }
        $m = [regex]::Match($l, '\[dev-reload\] ([a-z][a-z-]*): ?(.*)$')
        if ($m.Success) {
            $e = $m.Groups[1].Value
            $detail = $m.Groups[2].Value.Trim()
            if ($events.ContainsKey($e)) { $events[$e] = $events[$e] + 1 } else { $events[$e] = 1 }
            $total++
            $order.Add([pscustomobject]@{ I = $i; Kind = $e; Detail = $detail })
            if ($script:ReloadBeginEvents -contains $e) { $lastBegin = $i }
            elseif ($script:ReloadEndEvents -contains $e) { $lastEnd = $i }
            $last = "[dev-reload] ${e}: $detail"
            continue
        }
        if ([regex]::IsMatch($l, $Ctx.StartedRe)) {
            $started++
            $lastEnd = $i
            $order.Add([pscustomobject]@{ I = $i; Kind = 'Started'; Detail = '' })
            $last = 'Started ' + $Ctx.Simple
            continue
        }
        if ($l.Contains('Restarting due to')) {
            $restarting++
            $lastBegin = $i
            $order.Add([pscustomobject]@{ I = $i; Kind = 'Restarting'; Detail = '' })
            $last = 'DevTools: Restarting due to ...'
            continue
        }
        $pm = [regex]::Match($l, 'HC-PROBE (\S+) (\S+)')
        if ($pm.Success) { $probes.Add([pscustomobject]@{ I = $i; Name = $pm.Groups[1].Value; Version = $pm.Groups[2].Value }) }
    }
    return [pscustomobject]@{
        Text = $clean; Events = $events; Order = $order.ToArray(); Probes = $probes.ToArray()
        Started = $started; Restarting = $restarting; Busy = ($lastBegin -gt $lastEnd)
        Key = "$started/$restarting/$total"; Last = $last
    }
}

function Reload-Count {
    param($P, [string] $Name)
    if ($null -eq $P) { return 0 }
    if ($P.Events.ContainsKey($Name)) { return [int]$P.Events[$Name] }
    return 0
}

function Reload-FirstIdx {
    param([object[]] $Order = @(), [string[]] $Kinds, [int] $After = -1)
    foreach ($x in $Order) {
        if ($x.I -gt $After -and $Kinds -contains $x.Kind) { return [int]$x.I }
    }
    return -1
}

# The pid the last app-started line names.
function Reload-AnnouncedPid {
    param($P)
    $found = ''
    foreach ($x in @($P.Order)) {
        if ($x.Kind -ne 'app-started') { continue }
        $m = [regex]::Match($x.Detail, '^pid (\d+)')
        if ($m.Success) { $found = $m.Groups[1].Value }
    }
    return $found
}

function Reload-Summary {
    param($W)
    $p = $W.P
    $parts = @()
    foreach ($e in $script:ReloadSummaryEvents) {
        $n = Reload-Count $p $e
        if ($n) { $parts += "$e $n" }
    }
    $dr = 'nothing'
    if ($parts.Count) { $dr = $parts -join ', ' }
    return ('Started x{0}, Restarting x{1}; dev-reload: {2}; {3}s' -f $p.Started, $p.Restarting, $dr, $W.Secs)
}

function Reload-SaveWindow {
    param([Parameter(Mandatory)] $Ctx, [Parameter(Mandatory)][string] $Name, [Parameter(Mandatory)] $W)
    $head = "# $($Ctx.Container) log since $($W.Since) (Docker VM clock) - $(Reload-Summary $W)`n"
    return (Save-Evidence -Suite 'reload' -Name "$Name.log" -Content ($head + $W.Text))
}

# The start of a window, on the clock docker logs --since compares with.
function Reload-Now {
    param([Parameter(Mandatory)] $Ctx)
    $re = '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?Z$'
    $t = ''
    try { $t = [string](Get-DockerNow) } catch { $t = '' }
    if ($t -notmatch $re) {
        $r = Invoke-Docker @('exec', $Ctx.Container, 'date', '-u', '+%Y-%m-%dT%H:%M:%S.%NZ') -TimeoutSec 60
        $t = $r.StdOut.Trim()
    }
    if ($t -notmatch $re) { throw "could not read the Docker VM's clock (got '$t')" }
    return $t
}

# ---------------------------------------------------------------------------
# Facts from inside the container
# ---------------------------------------------------------------------------

function Reload-ExecScript {
    param([Parameter(Mandatory)][string] $Container, [Parameter(Mandatory)][string] $Script, [string[]] $ScriptArgs = @(), [int] $TimeoutSec = 120)
    $a = @('exec', '-i', $Container, 'sh', '-s') + @($ScriptArgs)
    return Invoke-Docker -DockerArgs $a -StdinText ($Script.Replace("`r", '')) -TimeoutSec $TimeoutSec
}

function Reload-ContainerState {
    param([Parameter(Mandatory)][string] $Name)
    $r = Invoke-Docker @('inspect', '-f', '{{.State.Status}}', $Name) -TimeoutSec 60
    if ($r.ExitCode -ne 0) { return '' }
    return $r.StdOut.Trim()
}

function Reload-StateText {
    param([AllowEmptyString()][string] $State)
    if (-not $State) { return 'not there' }
    return $State
}

function Reload-Tail {
    param([Parameter(Mandatory)] $Ctx, [int] $Lines = 200)
    $r = Invoke-Docker @('logs', '--tail', [string]$Lines, $Ctx.Container) -TimeoutSec 120
    return ([string]$r.StdOut + [string]$r.StdErr)
}

# The application JVM, by its main class in jcmd -l. Two at once come back
# comma-separated: that is a finding in itself.
function Reload-AppPid {
    param([Parameter(Mandatory)] $Ctx)
    $r = Invoke-Docker @('exec', $Ctx.Container, 'jcmd', '-l') -TimeoutSec 60
    if ($r.ExitCode -ne 0) { return '' }
    $found = @()
    foreach ($l in ($r.StdOut -split "`r?`n")) {
        $m = [regex]::Match($l, '^\s*(\d+)\s+(\S+)')
        if ($m.Success -and $m.Groups[2].Value -ceq $Ctx.Main) { $found += $m.Groups[1].Value }
    }
    return ($found -join ',')
}

# What dev-reload.sh asks: any HTTP answer on the application's own port.
function Reload-Liveness {
    param([Parameter(Mandatory)] $Ctx)
    $r = Invoke-Docker @('exec', $Ctx.Container, 'curl', '-s', '-o', '/dev/null', '-m', '5', '-w', '%{http_code}', "http://127.0.0.1:$($Ctx.Svc.Port)/actuator/health/liveness") -TimeoutSec 60
    $code = 0
    if ([int]::TryParse($r.StdOut.Trim(), [ref] $code)) { return $code }
    return 0
}

function Reload-InClasses {
    param([Parameter(Mandatory)] $Ctx, [Parameter(Mandatory)][string] $Rel)
    $r = Invoke-Docker @('exec', $Ctx.Container, 'test', '-e', "/app/target/classes/$Rel") -TimeoutSec 60
    return ($r.ExitCode -eq 0)
}

function Reload-CatFile {
    param([Parameter(Mandatory)] $Ctx, [Parameter(Mandatory)][string] $Path)
    $r = Invoke-Docker @('exec', $Ctx.Container, 'cat', $Path) -TimeoutSec 60
    return [pscustomobject]@{ Ok = ($r.ExitCode -eq 0); Text = [string]$r.StdOut }
}

function Reload-DevClasspath {
    param([Parameter(Mandatory)] $Ctx)
    $f = Reload-CatFile $Ctx '/app/target/dev-classpath.txt'
    if (-not $f.Ok) { return '' }
    return $f.Text.Trim()
}

# java.class.path as the running JVM has it. VM.system_properties prints in
# java.util.Properties form, where every ':' is escaped.
function Reload-LiveClasspath {
    param([Parameter(Mandatory)] $Ctx, [AllowEmptyString()][string] $JvmPid)
    if (-not $JvmPid -or $JvmPid.Contains(',')) { return '' }
    $r = Invoke-Docker @('exec', $Ctx.Container, 'jcmd', $JvmPid, 'VM.system_properties') -TimeoutSec 60
    if ($r.ExitCode -ne 0) { return '' }
    foreach ($l in ($r.StdOut -split "`r?`n")) {
        if ($l.StartsWith('java.class.path=')) { return [regex]::Replace($l.Substring(16).Trim(), '\\(.)', '$1') }
    }
    return ''
}

function Reload-TriggerStamp {
    param([Parameter(Mandatory)] $Ctx)
    $r = Invoke-Docker @('exec', $Ctx.Container, 'stat', '-c', '%y', "/app/target/classes/$($Ctx.Trigger)") -TimeoutSec 60
    if ($r.ExitCode -ne 0) { return '' }
    return $r.StdOut.Trim()
}

function Reload-TouchTrigger {
    param([Parameter(Mandatory)] $Ctx)
    $r = Invoke-Docker @('exec', $Ctx.Container, 'touch', "/app/target/classes/$($Ctx.Trigger)") -TimeoutSec 60
    return ($r.ExitCode -eq 0)
}

function Reload-ClassListing {
    param([Parameter(Mandatory)] $Ctx)
    $r = Reload-ExecScript -Container $Ctx.Container -Script $script:ReloadShListing -ScriptArgs @($Ctx.Trigger) -TimeoutSec 120
    $text = ([string]$r.StdOut).Replace("`r", '').Trim()
    $n = 0
    if ($text) { $n = @($text -split "`n").Count }
    return [pscustomobject]@{ Ok = ($r.ExitCode -eq 0 -and $n -gt 0); Text = $text; Count = $n }
}

function Reload-ListDiff {
    param([string] $Before, [string] $After)
    $b = @($Before -split "`n")
    $a = @($After -split "`n")
    $gone = @($b | Where-Object { $a -notcontains $_ } | ForEach-Object { @($_ -split '\s+')[-1] })
    $new = @($a | Where-Object { $b -notcontains $_ } | ForEach-Object { @($_ -split '\s+')[-1] })
    $parts = @()
    if ($gone.Count) { $parts += 'missing or changed: ' + (Reload-Clip ($gone -join ', ') 300) }
    if ($new.Count) { $parts += 'new or changed: ' + (Reload-Clip ($new -join ', ') 300) }
    return ($parts -join '; ')
}

function Reload-Sockets {
    param([Parameter(Mandatory)] $Ctx)
    $r = Reload-ExecScript -Container $Ctx.Container -Script $script:ReloadShSockets -TimeoutSec 60
    $list = [System.Collections.Generic.List[object]]::new()
    foreach ($l in ($r.StdOut -split "`r?`n")) {
        $f = @($l.Trim() -split '\s+' | Where-Object { $_ })
        if ($f.Count -lt 2) { continue }
        if ($f[0] -eq 'LISTEN') {
            $own = @()
            if ($f.Count -gt 2) { $own = @($f[2..($f.Count - 1)]) }
            $list.Add([pscustomobject]@{ State = 'LISTEN'; Inode = $f[1]; Owners = $own })
        }
        elseif ($f[0] -eq 'ESTAB') {
            $list.Add([pscustomobject]@{ State = 'ESTAB'; Inode = $f[1]; Owners = @() })
        }
    }
    return [pscustomobject]@{ Ok = ($r.ExitCode -eq 0); Items = $list.ToArray(); Text = [string]$r.StdOut }
}

# HC-PROBE markers the RUNNING context printed while it started: those between
# its last "Started" line and the DevTools restart or JVM launch before it.
# $null when the tail of the log holds no Started line to go by.
function Reload-RunningProbes {
    param([Parameter(Mandatory)] $Ctx)
    $p = Reload-ParseLog -Ctx $Ctx -Text (Reload-Tail $Ctx 400)
    $o = @($p.Order)
    $starts = @($o | Where-Object { $_.Kind -eq 'Started' })
    if ($starts.Count -eq 0) { return $null }
    $iS = $starts[$starts.Count - 1].I
    $iB = -1
    foreach ($x in $o) { if ($x.I -lt $iS -and $x.Kind -in @('Restarting', 'app-started')) { $iB = $x.I } }
    # The comma: an empty array returned bare would reach the caller as $null.
    return , @($p.Probes | Where-Object { $_.I -gt $iB -and $_.I -lt $iS } | ForEach-Object { "HC-PROBE $($_.Name) $($_.Version)" })
}

function Reload-PurgeProbes {
    param([Parameter(Mandatory)] $Ctx, [string] $Extra = '')
    $sa = @($Ctx.PkgPath)
    if ($Extra) { $sa += $Extra }
    $r = Reload-ExecScript -Container $Ctx.Container -Script $script:ReloadShPurge -ScriptArgs $sa -TimeoutSec 60
    $removed = @()
    $left = @()
    # Files taken out of /app/target/classes, which DevTools watches: only
    # those make a trigger touch restart the context.
    [int] $classesFiles = 0
    foreach ($l in ($r.StdOut -split "`r?`n")) {
        $m = [regex]::Match($l, '^removed (\S+) (\d+)$')
        if ($m.Success) {
            $removed += $m.Groups[1].Value
            if ($m.Groups[1].Value.StartsWith('/app/target/classes/')) { $classesFiles += [int]$m.Groups[2].Value }
        }
        elseif ($l.StartsWith('left ')) { $left += $l.Substring(5).Trim() }
    }
    return [pscustomobject]@{ Ok = ($r.ExitCode -eq 0); Removed = $removed; Left = $left; ClassesFiles = $classesFiles }
}

# A classpath resolved from scratch, in a one-off container of the live
# project: --no-deps so nothing else starts, -T so the output is not a
# terminal's, a hct-* name so a stuck one can be removed through the guard.
function Reload-FreshClasspath {
    param([Parameter(Mandatory)] $Ctx, [Parameter(Mandatory)][string] $Name)
    $script:ReloadSeq++
    $cname = 'hct-reload-cp-{0}-{1}' -f $script:ReloadSeq, [DateTime]::UtcNow.ToString('HHmmss')
    $r = Invoke-LiveCompose -ComposeArgs @('run', '--rm', '--no-deps', '-T', '--name', $cname, '--entrypoint', 'sh', $Ctx.Name, '-c', $script:ReloadShFreshCp) -TimeoutSec 900
    if ($r.TimedOut) { Invoke-Docker @('rm', '-f', $cname) -TimeoutSec 120 | Out-Null }
    $out = ([string]$r.StdOut).Replace("`r", '')
    $ev = Save-Evidence -Suite 'reload' -Name "$Name-fresh-classpath.log" -Content ("# $($r.CommandLine)`n# exit $($r.ExitCode)`n$out`n---- stderr ----`n$($r.StdErr)`n")
    $m = [regex]::Match($out, '(?s)HC-CP-BEGIN\n(.*?)\n*HC-CP-END')
    if ($m.Success -and $m.Groups[1].Value.Trim()) {
        return [pscustomobject]@{ Ok = $true; Cp = $m.Groups[1].Value.Trim(); Why = ''; Blocked = $false; Evidence = $ev }
    }
    $rc = [regex]::Match($out, 'HC-CP-RC (\d+)')
    $why = "the one-off container exited $($r.ExitCode)"
    if ($rc.Success) { $why = "./mvnw dependency:build-classpath exited $($rc.Groups[1].Value)" }
    if ($r.TimedOut) { $why = 'the one-off container did not finish within 900s' }
    $net = [regex]::Match($out + "`n" + $r.StdErr, "(?im)^.*(?:$($script:ReloadBlockedRe)).*$")
    if ($net.Success) { return [pscustomobject]@{ Ok = $false; Cp = ''; Why = "$why on a network failure: $(Reload-Clip $net.Value.Trim() 200)"; Blocked = $true; Evidence = $ev } }
    return [pscustomobject]@{ Ok = $false; Cp = ''; Why = "$why - see $Name-fresh-classpath.log"; Blocked = $false; Evidence = $ev }
}

function Reload-SaveClasspaths {
    param([Parameter(Mandatory)][string] $Name, [AllowEmptyString()][string] $Cp, [AllowEmptyString()][string] $Live, [AllowEmptyString()][string] $Fresh = '')
    $t = "---- /app/target/dev-classpath.txt, one entry per line ----`n" + (($Cp -split ':') -join "`n") + "`n"
    if ($Live) { $t += "`n---- java.class.path of the running JVM ----`n" + (($Live -split ':') -join "`n") + "`n" }
    if ($Fresh) { $t += "`n---- a fresh ./mvnw dependency:build-classpath ----`n" + (($Fresh -split ':') -join "`n") + "`n" }
    return (Save-Evidence -Suite 'reload' -Name $Name -Content $t)
}

function Reload-CpHas {
    param([AllowNull()][AllowEmptyString()][string] $Cp, [Parameter(Mandatory)][string] $Artifact)
    if (-not $Cp) { return $false }
    $re = '(^|[/\\])' + [regex]::Escape($Artifact) + '-[0-9][^/\\]*\.jar$'
    foreach ($e in ($Cp.Trim() -split ':')) {
        if ([regex]::IsMatch($e.Trim(), $re)) { return $true }
    }
    return $false
}

function Reload-CpDiff {
    param([AllowEmptyString()][string] $A, [AllowEmptyString()][string] $B, [string] $NameA, [string] $NameB)
    $ea = @(($A.Trim() -split ':') | Where-Object { $_ })
    $eb = @(($B.Trim() -split ':') | Where-Object { $_ })
    $onlyA = @($ea | Where-Object { $eb -cnotcontains $_ } | ForEach-Object { Reload-Leaf $_ })
    $onlyB = @($eb | Where-Object { $ea -cnotcontains $_ } | ForEach-Object { Reload-Leaf $_ })
    $parts = @()
    if ($onlyA.Count) { $parts += "only in ${NameA}: " + (Reload-Clip ($onlyA -join ', ') 300) }
    if ($onlyB.Count) { $parts += "only in ${NameB}: " + (Reload-Clip ($onlyB -join ', ') 300) }
    if ($parts.Count -eq 0) {
        if ($ea.Count -eq $eb.Count) { $parts += "the same $($ea.Count) entries in a different order" }
        else { $parts += "the same entries, some of them repeated ($($ea.Count) vs $($eb.Count))" }
    }
    return ($parts -join '; ')
}

# ---------------------------------------------------------------------------
# From this machine: HTTP and JDWP
# ---------------------------------------------------------------------------

# One client for the suite; no proxy (a corporate proxy must not decide
# whether 127.0.0.1 answers), no redirects. 0 = no answer at all.
function Reload-Http {
    param([Parameter(Mandatory)][string] $Url, [int] $TimeoutSec = 3)
    if ($null -eq $script:ReloadHttpClient) {
        try { Add-Type -AssemblyName 'System.Net.Http' -ErrorAction Stop } catch { }
        $handler = [System.Net.Http.SocketsHttpHandler]::new()
        $handler.UseProxy = $false
        $handler.AllowAutoRedirect = $false
        $handler.ConnectTimeout = [TimeSpan]::FromSeconds(2)
        $client = [System.Net.Http.HttpClient]::new($handler)
        $client.Timeout = [System.Threading.Timeout]::InfiniteTimeSpan
        $script:ReloadHttpClient = $client
    }
    $cts = [System.Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($TimeoutSec))
    $code = 0
    try {
        $resp = $script:ReloadHttpClient.GetAsync($Url, $cts.Token).GetAwaiter().GetResult()
        $code = [int]$resp.StatusCode
        $resp.Dispose()
    }
    catch { $code = 0 }
    finally { $cts.Dispose() }
    return $code
}

# Connects and exchanges the 14-byte JDWP-Handshake. Docker Desktop's port
# forwarder accepts a connection on a published port whether or not anything
# listens behind it, so only the echo proves an agent is there.
function Reload-JdwpOpen {
    param([Parameter(Mandatory)][int] $Port)
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $t = $client.ConnectAsync('127.0.0.1', $Port)
        if (-not $t.Wait(3000)) { throw 'no connection within 3s' }
        $s = $client.GetStream()
        $s.ReadTimeout = 10000
        $s.WriteTimeout = 5000
        $hs = [System.Text.Encoding]::ASCII.GetBytes('JDWP-Handshake')
        $s.Write($hs, 0, $hs.Length)
        $s.Flush()
        $back = Reload-ReadBytes -Stream $s -Count 14
        $got = [System.Text.Encoding]::ASCII.GetString($back)
        if ($got -cne 'JDWP-Handshake') { throw ("the reply was '{0}', not JDWP-Handshake" -f ($got -replace '[^\x20-\x7E]', '.')) }
        return [pscustomobject]@{ Ok = $true; Client = $client; Stream = $s; Detail = 'JDWP-Handshake echoed' }
    }
    catch {
        $client.Dispose()
        return [pscustomobject]@{ Ok = $false; Client = $null; Stream = $null; Detail = (Reload-ExMessage $_.Exception) }
    }
}

# VirtualMachine.Version (command set 1, command 1) on an open session: an
# 11-byte header - length, id, flags 0, set, command - and no data. Packets
# the VM sends on its own (events) are skipped until the reply to our id.
function Reload-JdwpVersion {
    param([Parameter(Mandatory)] $Conn)
    $s = $Conn.Stream
    $id = 0x4843
    $pkt = [byte[]]@(0, 0, 0, 11, 0, 0, 0x48, 0x43, 0, 1, 1)
    try {
        $s.Write($pkt, 0, $pkt.Length)
        $s.Flush()
        for ($i = 0; $i -lt 8; $i++) {
            $hdr = Reload-ReadBytes -Stream $s -Count 11
            $len = [int](Reload-BeInt $hdr 0)
            $rid = [int](Reload-BeInt $hdr 4)
            $flags = [int]$hdr[8]
            if ($len -lt 11 -or $len -gt 1048576) { throw "a packet with length $len" }
            $body = Reload-ReadBytes -Stream $s -Count ($len - 11)
            if (($flags -band 0x80) -eq 0 -or $rid -ne $id) { continue }
            $err = ([int]$hdr[9] -shl 8) -bor [int]$hdr[10]
            if ($err -ne 0) { return [pscustomobject]@{ Ok = $false; Detail = "the reply carries JDWP error $err" } }
            $d = Reload-JdwpStr $body 0
            $major = Reload-BeInt $body $d.Next
            $minor = Reload-BeInt $body ($d.Next + 4)
            $vv = Reload-JdwpStr $body ($d.Next + 8)
            $vn = Reload-JdwpStr $body $vv.Next
            return [pscustomobject]@{ Ok = $true; Detail = "JDWP $major.$minor, $($vn.S) $($vv.S)" }
        }
        return [pscustomobject]@{ Ok = $false; Detail = 'no reply among the first 8 packets' }
    }
    catch { return [pscustomobject]@{ Ok = $false; Detail = (Reload-ExMessage $_.Exception) } }
}

function Reload-ReadBytes {
    param([Parameter(Mandatory)] $Stream, [int] $Count)
    $buf = [byte[]]::new($Count)
    $n = 0
    while ($n -lt $Count) {
        $k = $Stream.Read($buf, $n, $Count - $n)
        if ($k -le 0) { break }
        $n += $k
    }
    if ($n -lt $Count) { throw "the connection closed after $n of $Count bytes" }
    return , $buf
}

function Reload-BeInt {
    param([byte[]] $B, [int] $Off)
    if ($Off + 4 -gt $B.Length) { throw 'a reply shorter than its fields' }
    return (([long]$B[$Off] -shl 24) -bor ([long]$B[$Off + 1] -shl 16) -bor ([long]$B[$Off + 2] -shl 8) -bor [long]$B[$Off + 3])
}

function Reload-JdwpStr {
    param([byte[]] $B, [int] $Off)
    $n = [int](Reload-BeInt $B $Off)
    if ($n -lt 0 -or $Off + 4 + $n -gt $B.Length) { throw 'a reply shorter than its fields' }
    return [pscustomobject]@{ S = [System.Text.Encoding]::UTF8.GetString($B, $Off + 4, $n); Next = $Off + 4 + $n }
}

# ---------------------------------------------------------------------------
# Edits in the checkout - through the manifest, always
# ---------------------------------------------------------------------------

# Each edit is a hashtable: @{ Op = 'write'; Path; Content },
# @{ Op = 'delete'; Path } or @{ Op = 'mtime'; Path; AgoSec } - the last only
# for files this suite created.
function Reload-ApplyEdits {
    param([Parameter(Mandatory)] $Ctx, [object[]] $Edits = @())
    foreach ($e in $Edits) {
        switch ($e.Op) {
            'write' { Reload-Write -Ctx $Ctx -Path $e.Path -Content $e.Content }
            'delete' { Reload-Delete -Ctx $Ctx -Path $e.Path }
            'mtime' {
                if ($Ctx.Tracked[$e.Path] -ne 'ABSENT') { throw "refusing to move the mtime of $($e.Path): the suite did not create it" }
                [System.IO.File]::SetLastWriteTimeUtc($e.Path, [DateTime]::UtcNow.AddSeconds(-[int]$e.AgoSec))
            }
            default { throw "unknown edit '$($e.Op)'" }
        }
    }
}

# Remembers what a file held before the suite first touched it, for the
# checks and the restore report; the manifest keeps the bytes themselves.
function Reload-Track {
    param([Parameter(Mandatory)] $Ctx, [Parameter(Mandatory)][string] $Path)
    if (-not $Ctx.Tracked.ContainsKey($Path)) { $Ctx.Tracked[$Path] = Reload-Sha $Path }
}

# An editor or a virus scanner can hold a file for a moment on Windows: a
# sharing violation is retried, anything else is not.
function Reload-Write {
    param([Parameter(Mandatory)] $Ctx, [Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][AllowEmptyString()][string] $Content)
    Reload-Track $Ctx $Path
    for ($i = 1; $i -le 5; $i++) {
        try {
            Set-TrackedFile -Path $Path -Content $Content
            return
        }
        catch {
            $x = $_.Exception
            while ($null -ne $x -and -not ($x -is [System.IO.IOException])) { $x = $x.InnerException }
            if ($null -eq $x -or $i -ge 5) { throw }
            Start-Sleep -Milliseconds 300
        }
    }
}

function Reload-Delete {
    param([Parameter(Mandatory)] $Ctx, [Parameter(Mandatory)][string] $Path)
    Reload-Track $Ctx $Path
    Remove-TrackedFile -Path $Path
}

# The original text of a file, registered with the manifest before anything
# is written. It is written back as UTF-8 later, so a file that would not come
# back byte for byte is refused here, before any edit.
function Reload-Original {
    param([Parameter(Mandatory)] $Ctx, [Parameter(Mandatory)][string] $Path)
    Reload-Track $Ctx $Path
    $text = Get-TrackedOriginal -Path $Path
    if ($null -eq $text) { return $null }
    $again = Get-Sha256Hex ([System.Text.UTF8Encoding]::new($false).GetBytes($text))
    if ($again -ne $Ctx.Tracked[$Path]) { throw "$Path does not round-trip through UTF-8, so the suite will not edit it" }
    return $text
}

function Reload-Sha {
    param([Parameter(Mandatory)][string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 'ABSENT' }
    return (Get-Sha256Hex ([System.IO.File]::ReadAllBytes($Path)))
}

function Reload-RepoFile {
    param([Parameter(Mandatory)] $Ctx, [Parameter(Mandatory)][string] $Rel)
    $parts = @($Ctx.RepoPath) + @($Rel.Split('/'))
    return [System.IO.Path]::Combine([string[]]$parts)
}

function Reload-Rel {
    param([Parameter(Mandatory)] $Ctx, [Parameter(Mandatory)][string] $Path)
    return ([System.IO.Path]::GetRelativePath($Ctx.RepoPath, $Path)).Replace('\', '/')
}

function Reload-IsBuildFile {
    param($Ctx, [string] $Path)
    $rel = Reload-Rel $Ctx $Path
    return ($rel -eq 'pom.xml' -or $rel -eq 'lombok.config' -or $rel -like '.mvn/*')
}

function Reload-IsSrcMain {
    param($Ctx, [string] $Path)
    return ((Reload-Rel $Ctx $Path) -like 'src/main/*')
}

function Reload-ProbePath {
    param([Parameter(Mandatory)] $Ctx, [Parameter(Mandatory)][string] $Name)
    return [System.IO.Path]::Combine($Ctx.ProbeDir, "$Name.java")
}

function Reload-TestProbePath {
    param([Parameter(Mandatory)] $Ctx)
    return [System.IO.Path]::Combine($Ctx.TestDir, 'HcProbeBrokenTest.java')
}

function Reload-ClassRel {
    param([Parameter(Mandatory)] $Ctx, [Parameter(Mandatory)][string] $Name)
    return "$($Ctx.PkgPath)/devprobe/$Name.class"
}

function Reload-Fill {
    param([Parameter(Mandatory)][string] $Template, [Parameter(Mandatory)] $Ctx)
    return $Template.Replace("`r", '').Replace('__PKG__', $Ctx.Pkg)
}

function Reload-ProbeSource {
    param([Parameter(Mandatory)] $Ctx, [Parameter(Mandatory)][string] $Name, [Parameter(Mandatory)][string] $Version, [switch] $Broken)
    $line = "HC-PROBE $Name $Version"
    $semi = ';'
    # Broken without the marker in it: a compiler that echoed the source line
    # must not look like the probe running.
    if ($Broken) { $line = 'hc probe, broken on purpose'; $semi = '' }
    return (Reload-Fill $script:ReloadProbeJava $Ctx).Replace('__NAME__', $Name).Replace('__LINE__', $line).Replace('__SEMI__', $semi)
}

function Reload-ProbeEdit {
    param([Parameter(Mandatory)] $Ctx, [Parameter(Mandatory)][string] $Name, [Parameter(Mandatory)][string] $Version, [switch] $Broken)
    return @{ Op = 'write'; Path = (Reload-ProbePath $Ctx $Name); Content = (Reload-ProbeSource -Ctx $Ctx -Name $Name -Version $Version -Broken:$Broken) }
}

function Reload-NextVersion {
    param([Parameter(Mandatory)] $Ctx, [Parameter(Mandatory)][string] $Name)
    $n = 1
    if ($Ctx.Versions.ContainsKey($Name)) { $n = [int]$Ctx.Versions[$Name] + 1 }
    $Ctx.Versions[$Name] = $n
    return "v$n"
}

# The file's own line ending, so that an edit on a CRLF checkout (Git for
# Windows, core.autocrlf) does not mix the two.
function Reload-Newline {
    param([AllowEmptyString()][string] $Text)
    if ($Text.Contains("`r`n")) { return "`r`n" }
    return "`n"
}

# An XML comment as the last thing inside <project>.
function Reload-PomComment {
    param([Parameter(Mandatory)][string] $Pom, [Parameter(Mandatory)][string] $Comment)
    $i = $Pom.LastIndexOf('</project>')
    if ($i -lt 0) { throw 'pom.xml has no </project>' }
    return $Pom.Substring(0, $i) + "  <!-- $Comment -->" + (Reload-Newline $Pom) + $Pom.Substring($i)
}

# An element that is never closed: not XML, so Maven cannot read the pom.
function Reload-PomBreak {
    param([Parameter(Mandatory)][string] $Pom)
    $i = $Pom.LastIndexOf('</project>')
    if ($i -lt 0) { throw 'pom.xml has no </project>' }
    return $Pom.Substring(0, $i) + '  <hc-probe-broken>' + (Reload-Newline $Pom) + $Pom.Substring($i)
}

function Reload-DepLines {
    param([Parameter(Mandatory)] $Dep, $Exclude = $null)
    $l = @(
        '<!-- hc-probe: added by test/run.ps1 (suite reload), removed again when it ends -->',
        '<dependency>',
        "  <groupId>$($Dep.Group)</groupId>",
        "  <artifactId>$($Dep.Artifact)</artifactId>",
        "  <version>$($Dep.Version)</version>"
    )
    if ($null -ne $Exclude) {
        $l += @(
            '  <exclusions>',
            '    <exclusion>',
            "      <groupId>$($Exclude.Group)</groupId>",
            "      <artifactId>$($Exclude.Artifact)</artifactId>",
            '    </exclusion>',
            '  </exclusions>'
        )
    }
    $l += '</dependency>'
    return $l
}

# The project's own </dependencies>: the first <dependencies> that is not
# inside a comment, <dependencyManagement>, <build> (plugin dependencies),
# <profiles> or <reporting>. Those are blanked out with spaces of the same
# length, so the index found is an index into the real text.
function Reload-ProjectDependenciesClose {
    param([Parameter(Mandatory)][string] $Pom)
    $blank = { param($m) ' ' * $m.Value.Length }
    $masked = [regex]::Replace($Pom, '<!--.*?-->', $blank, 'Singleline')
    foreach ($sec in @('profiles', 'dependencyManagement', 'build', 'reporting')) {
        $masked = [regex]::Replace($masked, "<$sec>.*?</$sec>", $blank, 'Singleline')
    }
    $open = $masked.IndexOf('<dependencies>')
    if ($open -lt 0) { return -1 }
    return $masked.IndexOf('</dependencies>', $open)
}

function Reload-PomAddDependency {
    param([Parameter(Mandatory)][string] $Pom, [Parameter(Mandatory)][string[]] $Lines)
    $close = Reload-ProjectDependenciesClose $Pom
    if ($close -lt 0) { throw 'pom.xml has no project-level </dependencies>' }
    $nl = Reload-Newline $Pom
    $ls = $Pom.LastIndexOf("`n", $close) + 1
    $indent = $Pom.Substring($ls, $close - $ls)
    $lead = ''
    if ($indent.Trim()) {
        # </dependencies> shares its line with something: insert right before it.
        $ls = $close
        $indent = '  '
        $lead = $nl
    }
    $child = $indent + '  '
    $block = $lead + ((@($Lines) | ForEach-Object { $child + $_ }) -join $nl) + $nl
    if ($lead) { $block += $indent }
    return $Pom.Substring(0, $ls) + $block + $Pom.Substring($ls)
}

# The artifactIds of /project/dependencies, namespace or not; Ok = $false when
# the text is not XML at all.
function Reload-PomArtifacts {
    param([AllowEmptyString()][string] $Text)
    try {
        $x = [xml]($Text.TrimStart([char]0xFEFF))
        $nodes = $x.SelectNodes("/*[local-name()='project']/*[local-name()='dependencies']/*[local-name()='dependency']/*[local-name()='artifactId']")
        $ids = @($nodes | ForEach-Object { $_.InnerText.Trim() })
        return [pscustomobject]@{ Ok = $true; Artifacts = $ids }
    }
    catch { return [pscustomobject]@{ Ok = $false; Artifacts = @() } }
}

# '' when $New is valid XML and has exactly the $Added artifacts more than
# $Old; otherwise what is wrong.
function Reload-PomProblem {
    param([Parameter(Mandatory)][string] $Old, [Parameter(Mandatory)][string] $New, [string[]] $Added)
    $o = Reload-PomArtifacts $Old
    $n = Reload-PomArtifacts $New
    if (-not $o.Ok) { return 'the original does not parse as XML' }
    if (-not $n.Ok) { return 'the edited text does not parse as XML' }
    if (@($n.Artifacts).Count -ne @($o.Artifacts).Count + @($Added).Count) { return "it has $(@($n.Artifacts).Count) dependencies, not $(@($o.Artifacts).Count) + $(@($Added).Count)" }
    foreach ($a in $Added) {
        if (@($n.Artifacts | Where-Object { $_ -eq $a }).Count -ne 1) { return "$a is not in /project/dependencies exactly once" }
    }
    return ''
}

# ---------------------------------------------------------------------------
# Putting a checkout back
# ---------------------------------------------------------------------------

# The manifest restore, then the target volume: probe classes purged from the
# classes AND the last-good snapshot, and one reload that prints no probe
# marker - the running context no longer has them. Then git status must be
# clean. A failure prints exactly what to run by hand.
function Reload-RestoreRepo {
    param(
        [Parameter(Mandatory)] $Ctx,
        [Parameter(Mandatory)][string] $Id,
        [string[]] $Req = @('R7', 'R10'),
        [AllowNull()][string] $GitBefore = $null,
        # After Ctrl+C: the files go back and the probe classes are purged,
        # but the reload that follows is asked for, not waited for - minutes,
        # in a finally that Ctrl+C cannot interrupt again.
        [switch] $Quick
    )
    $problems = [System.Collections.Generic.List[string]]::new()
    $notes = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    $evidence = [System.Collections.Generic.List[string]]::new()
    $paths = @($Ctx.Tracked.Keys)
    $before = @{}
    foreach ($p in $paths) { $before[$p] = Reload-Sha $p }
    $refused = @()
    try { $refused = @(Restore-EditManifest) }
    catch { $problems.Add("the manifest restore threw: $(Reload-ExMessage $_.Exception)") }
    $changed = @($paths | Where-Object { (Reload-Sha $_) -ne $before[$_] })
    $left = @($paths | Where-Object { (Reload-Sha $_) -ne $Ctx.Tracked[$_] })
    if ($refused.Count) { $problems.Add("refused to put back, because they changed after the harness wrote them: $($refused -join ', ')") }
    elseif ($left.Count) { $problems.Add('not back to their original bytes: ' + (@($left | ForEach-Object { Reload-Rel $Ctx $_ }) -join ', ')) }
    if ($changed.Count) { $notes.Add('put back: ' + (@($changed | ForEach-Object { Reload-Rel $Ctx $_ }) -join ', ')) }
    else { $notes.Add('nothing left to put back') }

    $extra = ''
    if ($Ctx.Name -eq 'user-service') { $extra = 'hc-probe.txt' }
    if ((Reload-ContainerState $Ctx.Container) -eq 'running') {
        $build = @($changed | Where-Object { Reload-IsBuildFile $Ctx $_ }).Count -gt 0
        $src = @($changed | Where-Object { Reload-IsSrcMain $Ctx $_ }).Count -gt 0
        # A reload comes from the restore itself when it changed a file
        # dev-reload.sh watches. Otherwise from the trigger - but DevTools
        # leaves the trigger file itself out of the changes it restarts on, so
        # touching it restarts nothing unless the purge took files out of
        # target/classes. With neither, the context has not seen a probe since
        # its last clean restart, and there is nothing to reload.
        if ($Quick) {
            $purge = Reload-PurgeProbes -Ctx $Ctx -Extra $extra
            if (-not ($build -or $src) -and $purge.ClassesFiles -gt 0) { $null = Reload-TouchTrigger $Ctx }
            $warnings.Add("the run was interrupted, so the reload after the restore was not waited for - if $($Ctx.Container) still prints HC-PROBE lines, purge and touch by hand")
        }
        else {
            $t0 = Reload-Now $Ctx
            $first = Reload-PurgeProbes -Ctx $Ctx -Extra $extra
            $touched = $false
            if (-not ($build -or $src) -and $first.ClassesFiles -gt 0) { $null = Reload-TouchTrigger $Ctx; $touched = $true }
            if (-not ($build -or $src -or $touched)) {
                $purge = $first
                $live = Reload-RunningProbes $Ctx
                if ($null -eq $live) { $warnings.Add('nothing to reload - the restore changed no watched file and no probe class was left in target/classes - but the running context''s last start is not in the log to confirm it is clean') }
                elseif ($live.Count) { $problems.Add("the running context loaded probe classes at its last start ($($live -join ', ')), and there is no class left to purge that a trigger could restart it on") }
                else { $notes.Add('nothing to reload: the restore changed no watched file, no probe class was left in target/classes, and the running context started without one') }
            }
            else {
                $to = $script:ReloadSourceSec
                $fail = $script:ReloadSourceFailOn
                if ($build) { $to = $script:ReloadBuildSec; $fail = $script:ReloadBuildFailOn }
                $w = Reload-Watch -Ctx $Ctx -Since $t0 -Started 1 -TimeoutSec $to -FailOn $fail
                $evidence.Add((Reload-SaveWindow -Ctx $Ctx -Name $Id -W $w))
                # Again: a snapshot taken while the first purge ran would hold them.
                $purge = Reload-PurgeProbes -Ctx $Ctx -Extra $extra
                if (-not $w.Ok) {
                    $evidence.Add((Save-Evidence -Suite 'reload' -Name "$Id-last200.log" -Content (Reload-Tail $Ctx 200)))
                    $problems.Add("no reload after the restore within $($w.Secs)s ($(Reload-Summary $w)), so the running context may still hold probe classes")
                }
                elseif (@($w.P.Probes).Count -and $purge.ClassesFiles -eq 0) {
                    $problems.Add('the reload after the restore printed probe markers, yet no probe class was left in target/classes to purge: ' + (@($w.P.Probes | ForEach-Object { "HC-PROBE $($_.Name) $($_.Version)" }) -join ', '))
                }
                elseif (@($w.P.Probes).Count) {
                    # Stale classes were live in that reload; they are gone from
                    # disk now, which is the class change the trigger needs.
                    $t1 = Reload-Now $Ctx
                    $null = Reload-TouchTrigger $Ctx
                    $w2 = Reload-Watch -Ctx $Ctx -Since $t1 -Started 1 -TimeoutSec $script:ReloadSourceSec -FailOn $script:ReloadSourceFailOn
                    $evidence.Add((Reload-SaveWindow -Ctx $Ctx -Name "$Id-again" -W $w2))
                    if ($w2.Ok -and @($w2.P.Probes).Count -eq 0) { $notes.Add('the reload after the restore still printed a probe marker (stale classes in the volume); purged, and the next reload was clean') }
                    else { $problems.Add('probe markers are still printed after the restore and a purge: ' + (@($w2.P.Probes | ForEach-Object { "HC-PROBE $($_.Name) $($_.Version)" }) -join ', ')) }
                }
                else { $notes.Add("one clean reload afterwards ($(Reload-Summary $w))") }
            }
        }
        if (@($purge.Left).Count) { $problems.Add('probe classes are still in the target volume: ' + (@($purge.Left) -join ', ')) }
    }
    else { $problems.Add("$($Ctx.Container) is not running, so the probe classes in its target volume could not be purged") }

    $st = Invoke-Git $Ctx.RepoPath @('status', '--porcelain')
    if ($st.ExitCode -ne 0) { $problems.Add("git status failed (exit $($st.ExitCode))") }
    elseif ($st.StdOut.Trim()) {
        $evidence.Add((Save-Evidence -Suite 'reload' -Name "$Id-git-status.txt" -Content $st.StdOut))
        $problems.Add("git status is not clean: $(Reload-StatusSummary $st.StdOut)")
    }
    else { $notes.Add('git status clean') }

    # Non-empty, not non-null: a [string] parameter turns $null into '', and
    # G-RESTORE leaves this check to G-GIT.
    if ($GitBefore) {
        $after = Get-GitConfigHash $Ctx.Repo
        if ($after -ne $GitBefore) {
            $evidence.Add((Save-Evidence -Suite 'reload' -Name "$Id-git-config.txt" -Content ("before: $GitBefore`nafter:  $after`n")))
            $problems.Add('.git/config or .git/hooks changed while the suite ran: a build in the container reached into the checkout')
        }
        else { $notes.Add('.git/config and hooks unchanged') }
    }

    if ($problems.Count) {
        $cmds = Reload-ManualRestore -Ctx $Ctx -Left $left
        $evidence.Add((Save-Evidence -Suite 'reload' -Name "$Id-manual-restore.txt" -Content (($cmds -join "`n") + "`n")))
        Reload-Add -Id $Id -Status 'FAIL' -Req $Req -Evidence @($evidence) -Message ("{0}: {1}. To put it back by hand: {2}" -f $Ctx.Repo, ($problems -join '; '), ($cmds -join ' ; '))
        return
    }
    if ($warnings.Count) {
        # The last two are the purge and the trigger touch.
        $cmds = @(Reload-ManualRestore -Ctx $Ctx -Left $left | Select-Object -Last 2)
        Reload-Add -Id $Id -Status 'WARN' -Req $Req -Evidence @($evidence) -Message ("{0}: {1}; {2}. By hand: {3}" -f $Ctx.Repo, ($warnings -join '; '), ($notes -join '; '), ($cmds -join ' ; '))
        return
    }
    Reload-Add -Id $Id -Status 'PASS' -Req $Req -Evidence @($evidence) -Message ("{0}: {1}" -f $Ctx.Repo, ($notes -join '; '))
}

function Reload-ManualRestore {
    param([Parameter(Mandatory)] $Ctx, [string[]] $Left = @())
    $h = Get-Harness
    $cmds = @()
    if ($h.OnWindows) { $cmds += "cd '$($h.InfraRoot)'; pwsh -NoProfile -ExecutionPolicy Bypass -File .\test\run.ps1 -Restore $($h.RunId)   (puts back only bytes the harness wrote)" }
    else { $cmds += "cd '$($h.InfraRoot)' && pwsh -NoProfile -File test/run.ps1 -Restore $($h.RunId)   (puts back only bytes the harness wrote)" }
    foreach ($p in $Left) {
        if ($Ctx.Tracked[$p] -eq 'ABSENT') {
            if ($h.OnWindows) { $cmds += "Remove-Item -LiteralPath '$p'   (created by the harness)" }
            else { $cmds += "rm -f '$p'   (created by the harness)" }
        }
        else {
            $cmds += "git -C '$($Ctx.RepoPath)' checkout -- '$(Reload-Rel $Ctx $p)'   (the checkout was clean when the suite started; skip this if you have edited the file since - its original bytes are also base64 in $($Ctx.Manifest))"
        }
    }
    $cmds += "docker exec $($Ctx.Container) rm -rf /app/target/classes/$($Ctx.PkgPath)/devprobe /app/target/.dev-reload/good/classes/$($Ctx.PkgPath)/devprobe"
    $cmds += "docker exec $($Ctx.Container) touch /app/target/classes/$($Ctx.Trigger)   (DevTools restarts without them - but only if the rm above removed a file)"
    return $cmds
}

# ---------------------------------------------------------------------------
# All twelve, lightly
# ---------------------------------------------------------------------------

function Reload-All {
    $all = @(Get-JavaServices)
    $order = @($all | Where-Object { $_.Name -ne 'service-discovery' -and $_.Name -ne 'config-server' }) +
             @($all | Where-Object { $_.Name -eq 'service-discovery' }) +
             @($all | Where-Object { $_.Name -eq 'config-server' })
    foreach ($s in $order) {
        try { Reload-AllOne $s }
        catch { Reload-HarnessError -Id "G-ALL-$($s.Name)" -Req @('R7') -Err $_ }
    }
}

function Reload-AllOne {
    param([Parameter(Mandatory)] $Svc)
    $id = "G-ALL-$($Svc.Name)"
    $req = @('R7')
    $ctx = Reload-NewCtx $Svc
    $pom = Reload-RepoFile $ctx 'pom.xml'
    if (-not (Test-Path -LiteralPath $pom -PathType Leaf)) {
        Reload-Add -Id $id -Status 'SKIP' -Req $req -Message "$pom does not exist: the checkout is missing"
        return
    }
    if (-not (Test-RepoClean $ctx.Repo)) {
        $st = Invoke-Git $ctx.RepoPath @('status', '--porcelain')
        Reload-Add -Id $id -Status 'FAIL' -Req $req -Message ("refused: {0} has uncommitted changes ({1}). Commit or stash them (git -C '{2}' stash push --include-untracked) and run -Suite reload again" -f $ctx.Repo, (Reload-StatusSummary $st.StdOut), $ctx.RepoPath)
        return
    }
    $state = Reload-ContainerState $ctx.Container
    if ($state -ne 'running') {
        Reload-Add -Id $id -Status 'SKIP' -Req $req -Message "$($ctx.Container) is $(Reload-StateText $state): start the whole stack (.\dev.ps1 up, or ./dev up) and run -Suite reload again"
        return
    }
    $foreign = Reload-ForeignCheckout $ctx
    if ($foreign) {
        Reload-Add -Id $id -Status 'SKIP' -Req $req -Message "$($ctx.Container) belongs to the compose project in $foreign, not to this checkout"
        return
    }
    Reload-Say "${id}: waiting for $($ctx.Name) to serve"
    $look = Reload-WaitServing -Ctx $ctx -TimeoutSec 180
    if (-not $look.Ok) {
        $ev = Save-Evidence -Suite 'reload' -Name "$id-not-serving.log" -Content (Reload-Tail $ctx 200)
        Reload-Add -Id $id -Status 'SKIP' -Req $req -Evidence @($ev) -Message "$($ctx.Name) was not serving at the start: $($look.Why)"
        return
    }
    Reload-ReadFacts $ctx
    $null = Reload-PurgeProbes -Ctx $ctx
    $gitBefore = Get-GitConfigHash $ctx.Repo
    $ctx.Manifest = Start-EditManifest "reload-$($Svc.Name)"
    # As in Reload-UserService: $false in the finally only after Ctrl+C.
    $finished = $false
    try {
        $path = Reload-ProbePath $ctx 'HcProbe'
        $rel = Reload-ClassRel $ctx 'HcProbe'
        $a = @{
            Ctx = $ctx; Id = $id; Tag = "$id-create"; What = "a probe created in $($ctx.Pkg).devprobe"
            Edits = @(Reload-ProbeEdit -Ctx $ctx -Name 'HcProbe' -Version 'v1')
            Markers = @{ HcProbe = 'v1' }; Present = @($rel)
        }
        $r1 = Reload-SourceCase @a
        if (-not $r1) { $finished = $true; return }
        $b = @{
            Ctx = $ctx; Id = $id; Tag = "$id-delete"; What = "the probe in $($ctx.Pkg).devprobe deleted"
            Edits = @(@{ Op = 'delete'; Path = $path }); NoMarkers = @('*'); Absent = @($rel)
        }
        $r2 = Reload-SourceCase @b
        if (-not $r2) { $finished = $true; return }
        $r = Reload-NewResult -Id $id -Req $req -What "a probe in $($ctx.Pkg).devprobe created, then deleted"
        foreach ($x in @($r1, $r2)) {
            foreach ($t in $x.Problems) { $r.Problems.Add($t) }
            foreach ($t in $x.Warnings) { $r.Warnings.Add($t) }
            foreach ($t in $x.Evidence) { $r.Evidence.Add($t) }
        }
        $r.Detail = "created: $((@($r1.Notes) + @(Reload-Summary $r1.W)) -join '; ') | deleted: $((@($r2.Notes) + @(Reload-Summary $r2.W)) -join '; ')"
        Reload-Finish $r
        $finished = $true
    }
    catch { $finished = $true; throw }
    finally {
        try { Reload-RestoreRepo -Ctx $ctx -Id "$id-RESTORE" -GitBefore $gitBefore -Quick:(-not $finished) }
        catch { Reload-HarnessError -Id "$id-RESTORE" -Req @('R7', 'R10') -Err $_ }
    }
}

# ---------------------------------------------------------------------------
# Results and small things
# ---------------------------------------------------------------------------

function Reload-NewResult {
    param([Parameter(Mandatory)][string] $Id, [string[]] $Req = @('R7'), [Parameter(Mandatory)][string] $What)
    return [pscustomobject]@{
        Id = $Id; Req = @($Req); What = $What; W = $null; Pid0 = ''; Pid1 = ''; Detail = ''
        Problems = [System.Collections.Generic.List[string]]::new()
        Warnings = [System.Collections.Generic.List[string]]::new()
        Notes    = [System.Collections.Generic.List[string]]::new()
        Evidence = [System.Collections.Generic.List[string]]::new()
    }
}

# FAIL with every problem, WARN with every caveat, otherwise $PassStatus with
# what was seen - and always the counts the verdict rests on.
function Reload-Finish {
    param([Parameter(Mandatory)] $R, [string] $PassStatus = 'PASS')
    $detail = $R.Detail
    if (-not $detail) {
        $seen = @($R.Notes)
        if ($null -ne $R.W) { $seen += (Reload-Summary $R.W) }
        $detail = $seen -join '; '
    }
    if ($R.Problems.Count) {
        $status = 'FAIL'
        $msg = "$($R.What): $($R.Problems -join '; ') [$detail]"
    }
    elseif ($R.Warnings.Count) {
        $status = 'WARN'
        $msg = "$($R.What): $($R.Warnings -join '; ') [$detail]"
    }
    else {
        $status = $PassStatus
        $msg = "$($R.What): $detail"
    }
    Reload-Add -Id $R.Id -Status $status -Req $R.Req -Evidence @($R.Evidence) -Message $msg
}

# A wait that ended without its goal: the window's log, the container's last
# 200 lines, and FAIL - BLOCKED when those show the network or the OOM killer.
function Reload-Timeout {
    param([Parameter(Mandatory)] $Ctx, [Parameter(Mandatory)] $R, [string] $Tag = '')
    if (-not $Tag) { $Tag = $R.Id }
    $w = $R.W
    $tail = Reload-Tail $Ctx 200
    $R.Evidence.Add((Save-Evidence -Suite 'reload' -Name "$Tag-last200.log" -Content $tail))
    $why = Reload-Classify -Ctx $Ctx -Text ($w.Text + "`n" + $tail)
    $how = "timed out after $($w.Secs)s"
    if ($w.FailedOn) { $how = "gave up after $($w.Secs)s: dev-reload.sh logged $($w.FailedOn), and nothing followed it for $($script:ReloadGiveUpSec)s" }
    $state = "Started x$($w.P.Started), Restarting x$($w.P.Restarting), last: $(Reload-Clip $w.P.Last 160)"
    $status = 'FAIL'
    if ($why) {
        $status = 'BLOCKED'
        $how = "$how - $why"
    }
    Reload-Add -Id $R.Id -Status $status -Req $R.Req -Evidence @($R.Evidence) -Message "$($R.What): $how ($state); the window's log and the last 200 lines of $($Ctx.Container) are in the evidence"
}

function Reload-Classify {
    param([Parameter(Mandatory)] $Ctx, [AllowEmptyString()][string] $Text)
    $i = Invoke-Docker @('inspect', '-f', '{{.State.OOMKilled}}', $Ctx.Container) -TimeoutSec 60
    if ($i.ExitCode -eq 0 -and $i.StdOut.Trim() -eq 'true') { return 'memory: the container was OOM-killed - raise DEV_SERVICE_MEM, or the Docker VM ([wsl2] memory= in %UserProfile%\.wslconfig on Windows)' }
    if ($Text -match '\[dev-reload\] app-exited: pid \d+, status 137' -and $Text -notmatch '\[dev-reload\] app-killed:') { return 'memory: the application was SIGKILLed (status 137) by something other than dev-reload.sh, which in a 1g container is the OOM killer' }
    $m = [regex]::Match([string]$Text, "(?im)^.*(?:$($script:ReloadBlockedRe)).*$")
    if ($m.Success) { return "network: $(Reload-Clip $m.Value.Trim() 200)" }
    return ''
}

function Reload-HarnessError {
    param([Parameter(Mandatory)][string] $Id, [string[]] $Req = @('R7'), [Parameter(Mandatory)] $Err)
    $where = ''
    if ($Err.InvocationInfo) { $where = ($Err.InvocationInfo.PositionMessage -replace "`r?`n", ' ') }
    Reload-Add -Id "$Id-HARNESS-ERROR" -Status 'FAIL' -Req $Req -Message ('harness error: {0} {1}' -f (Reload-ExMessage $Err.Exception), $where)
}

# Add-Result with the message redacted: paths and container output can carry
# anything, and the results are scanned for .env values at the end.
function Reload-Add {
    param(
        [Parameter(Mandatory)][string] $Id,
        [Parameter(Mandatory)][string] $Status,
        [AllowEmptyString()][string] $Message = '',
        [string[]] $Req = @(),
        [string[]] $Evidence = @()
    )
    if (-not $Message) { $Message = '(no detail)' }
    Add-Result -Id $Id -Status $Status -Message (Protect-Text $Message) -Req $Req -Evidence @($Evidence | Where-Object { $_ })
}

# Progress, not a verdict.
function Reload-Say {
    param([string] $Text)
    Write-Host "    $Text" -ForegroundColor DarkGray
}

function Reload-ExMessage {
    param($Ex)
    $x = $Ex
    while ($null -ne $x -and $null -ne $x.InnerException) { $x = $x.InnerException }
    if ($null -eq $x) { return 'unknown error' }
    return $x.Message
}

function Reload-StatusSummary {
    param([AllowEmptyString()][string] $Porcelain)
    $l = @(([string]$Porcelain -split "`r?`n") | Where-Object { $_.Trim() })
    if ($l.Count -eq 0) { return 'nothing listed' }
    $shown = @($l | Select-Object -First 3 | ForEach-Object { $_.Trim() }) -join ', '
    if ($l.Count -gt 3) { $shown += ", and $($l.Count - 3) more" }
    return "$($l.Count) entries: $shown"
}

function Reload-Leaf {
    param([string] $Path)
    $p = $Path.Replace('\', '/')
    return $p.Substring($p.LastIndexOf('/') + 1)
}

function Reload-Short {
    param([AllowEmptyString()][string] $Hash)
    if (-not $Hash) { return '(none)' }
    if ($Hash.Length -le 12) { return $Hash }
    return $Hash.Substring(0, 12)
}

function Reload-Clip {
    param([AllowNull()][AllowEmptyString()][string] $Text, [int] $Max = 200)
    if (-not $Text) { return '' }
    if ($Text.Length -le $Max) { return $Text }
    return $Text.Substring(0, $Max) + '...'
}

function Reload-FirstLine {
    param([AllowNull()][AllowEmptyString()][string] $Text)
    $l = @(([string]$Text -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -First 1)
    if ($l.Count -eq 0) { return '(no output)' }
    return (Reload-Clip $l[0].Trim() 200)
}
