# Suite H, lifecycle: what ./dev and .\dev.ps1 do to the stack as a whole -
# the Maven volume they create, the volumes `down -v` takes and the one it
# must leave, the services `up <svc>` starts, and the webapp container's
# lockfile-keyed npm ci (R1, R9). Loaded by test/run.ps1 after
# lib/Harness.ps1; read that file's CONVENTIONS first. Every helper here is
# named Life-*. ASCII only, and nothing Windows PowerShell 5.1 cannot parse:
# suite A parses every .ps1 here with 5.1.
#
#   H-VOL-01   `docker volume create homecrew-maven-repo`, twice: both exit 0
#              and the second hands back the SAME volume (its CreatedAt does
#              not move). Both launchers run it before every `up`, so a create
#              that replaced the volume would empty the Maven cache each time.
#   H-VOL-02   The isolated test project: postgres up, then `down -v`. Its own
#              volumes go; homecrew-maven-repo-test, declared external, stays.
#              That is the property that lets `./dev down -v` empty the
#              databases without throwing away every downloaded jar.
#   H-VOL-03   The same on your REAL stack, through `.\dev.ps1 down -v`.
#              Opt-in (-AllowDataLoss): it empties your databases.
#   H-UP-01    `up user-service` starts user-service and what it depends on -
#              postgres, kafka, service-discovery, config-server - and nothing
#              else.
#   H-UP-02    `up webapp` starts webapp ALONE (compose.dev.yml resets its
#              depends_on) and 127.0.0.1:4200 answers 200.
#   H-UP-03    The same through ./dev under Git Bash, the one place MSYS
#              argument rewriting could break it (Windows); elsewhere it is
#              reported SKIP and ./dev runs under /bin/sh as H-UP-03-sh.
#   H-WEB-01   Starting webapp changed nothing in the home-crew-webapp
#              checkout: same sha256 for package.json and package-lock.json,
#              same git status.
#   H-WEB-02   One newline appended to package-lock.json through the edit
#              manifest; `docker restart homecrew-webapp` logs "reinstalling
#              with npm ci", then the dev server starts, the install stamp
#              matches the new files, and the host file still holds exactly
#              the bytes the harness wrote: npm ci never writes the lockfile
#              (npm install may, and /app is your checkout).
#              H-WEB-02-RESTORE: the file put back byte for byte, the next
#              restart reinstalls again, git status is what it was.
#   H-WEB-03   Both reinstalls went onto the POPULATED node_modules volume
#              without EBUSY. The volume's mount point cannot be removed, and
#              an npm that tries to remove node_modules itself fails there.
#   H-RESTORE  The stack is left the way it was found.
#
# WHICH LAUNCHER, AND WHY. dev.ps1 runs under the pwsh that runs this harness
# (on Windows that is exactly what you run; elsewhere it is the mirror, which
# must behave the same), ./dev under Git Bash on Windows and /bin/sh
# elsewhere:
#
#   H-UP-01     the platform's own launcher: .\dev.ps1 on Windows, sh ./dev
#               elsewhere
#   H-UP-02     dev.ps1 under pwsh, everywhere
#   H-UP-03     ./dev under <GitRoot>\bin\sh.exe (found from git --exec-path,
#               never sh or bash from PATH, which can be WSL's), with the MSYS
#               variables left as they are - ./dev exports its own - and Git's
#               tool directories first on PATH, as a Git Bash window has them
#   H-VOL-03    dev.ps1 under pwsh, everywhere (the command -AllowDataLoss
#               names)
#   H-RESTORE   the platform's own launcher again
#
# YOUR STACK. H-UP-* and H-WEB-* take your dev stack down (volumes kept) and
# start parts of it. The services that were running at the start are recorded
# first and started again at the end - `<launcher> down`, then `<launcher> up
# <those services>` - in a finally block; a stack that was not running is left
# down. A stack running from ANOTHER checkout (the same pinned container names
# under a different compose project) is not touched at all: the H-UP and
# H-WEB tests are skipped instead.
#
# THE GUARD. The launchers run docker themselves, out of Assert-DockerArgsSafe's
# reach, so every launcher command is first shown to the guard as the compose
# command it turns into. `down -v` on the live project therefore cannot run
# without -AllowDataLoss, even through a harness bug.

Set-StrictMode -Version 3.0

# What `up user-service` has to start: user-service, what it depends on, and
# what those depend on (docker-compose.yml: user-service -> config-server,
# service-discovery, postgres; config-server -> service-discovery;
# service-discovery -> postgres, kafka). Sorted, for comparing.
$script:LifeUserServiceSet = @('config-server', 'kafka', 'postgres', 'service-discovery', 'user-service')
$script:LifeWebappContainer = 'homecrew-webapp'
$script:LifeWebappUrl = 'http://127.0.0.1:4200/'

# The dev server must answer within this many seconds of starting. A cold
# node_modules volume first spends minutes in npm ci; that phase gets its own,
# longer bound, and both are reported, so neither hides the other.
$script:LifeServeSec = 300
$script:LifeInstallSec = 1200

# What a launcher's cold start looks like when the NETWORK failed it, not the
# setup: a failure that shows one of these is BLOCKED, not FAIL.
$script:LifeBlockedPattern = 'UnknownHostException|Temporary failure in name resolution|Network is unreachable|Connection timed out|connect timed out|Connection reset|No route to host|status code: (429|5\d\d)|429 Too Many Requests|TLS handshake timeout|i/o timeout|failed to resolve reference|dial tcp'

function Invoke-SuiteLifecycle {
    Enter-Suite 'lifecycle' 'the launchers and the stack: the Maven volume, down -v, up <svc>, the webapp install (R1, R9)'
    $h = Get-Harness

    if (-not (Test-DockerAvailable)) {
        Life-Add -Id 'H-PRE' -Status 'SKIP' -Req @('R1', 'R9') -Message 'docker is not available (not on PATH, or docker info fails), so none of H-VOL, H-UP and H-WEB ran'
        return
    }
    Life-Step -Id 'H-VOL-01' -Req @('R1') -Body { Life-Vol01 }

    # docker-compose.yml has POSTGRES_PASSWORD as ${VAR:?}: without .env
    # compose renders nothing at all, and both launchers refuse to start.
    if (-not (Test-Path -LiteralPath (Join-Path $h.InfraRoot '.env') -PathType Leaf)) {
        Life-Add -Id 'H-PRE' -Status 'SKIP' -Req @('R1', 'R9') -Message 'there is no .env, which compose needs to render docker-compose.yml and both launchers check for first, so H-VOL-02, H-VOL-03, H-UP and H-WEB did not run'
        return
    }
    Life-Step -Id 'H-VOL-02' -Req @('R1') -Body { Life-Vol02 }

    $ctx = $null
    try { $ctx = Life-NewContext }
    catch {
        Life-Add -Id 'H-PRE' -Status 'FAIL' -Req @('R1', 'R9') -Message "harness error while reading the live stack's state: $($_.Exception.Message) - so H-VOL-03, H-UP and H-WEB did not run, and your stack was not touched"
        return
    }
    if ($ctx.Why) {
        Life-Add -Id 'H-PRE' -Status $ctx.WhyStatus -Req @('R1', 'R9') -Message "$($ctx.Why) - so H-VOL-03, H-UP and H-WEB did not run"
        return
    }
    $was = 'not running'
    if (@($ctx.StartServices).Count -gt 0) { $was = 'running: ' + (@($ctx.StartServices) -join ' ') }
    Life-Say "live project '$($ctx.Live)', $was at the start; it is put back that way at the end"

    try {
        Life-Step -Id 'H-UP-01' -Req @('R9', 'R1') -Body { Life-Up01 $ctx }
        Life-Step -Id 'H-VOL-03' -Req @('R1') -Body { Life-Vol03 $ctx }
        Life-Step -Id 'H-UP-02' -Req @('R9') -Body { Life-UpWebapp -Ctx $ctx -Id 'H-UP-02' -Launcher $ctx.Ps -WithWeb01 }
        Life-Step -Id 'H-WEB-02' -Req @('R1') -Body { Life-Web02 $ctx }
        Life-Step -Id 'H-UP-03' -Req @('R9') -Body { Life-Up03 $ctx }
    }
    finally {
        Life-Step -Id 'H-RESTORE' -Req @() -Body { Life-RestoreStack $ctx }
    }
}

# ---------------------------------------------------------------------------
# H-VOL
# ---------------------------------------------------------------------------

function Life-Vol01 {
    $vol = $script:RealMavenVol
    $existed = Life-VolumeExists $vol
    $c1 = Invoke-Docker @('volume', 'create', $vol) -TimeoutSec 60
    $t1 = Life-VolumeCreatedAt $vol
    $c2 = Invoke-Docker @('volume', 'create', $vol) -TimeoutSec 60
    $t2 = Life-VolumeCreatedAt $vol
    $ev = Save-Evidence -Suite 'lifecycle' -Name 'H-VOL-01.txt' -Content (
        "existed before: $existed`n" +
        "1st create: exit $($c1.ExitCode) stdout '$($c1.StdOut.Trim())' stderr '$($c1.StdErr.Trim())'`nCreatedAt after 1st: $t1`n" +
        "2nd create: exit $($c2.ExitCode) stdout '$($c2.StdOut.Trim())' stderr '$($c2.StdErr.Trim())'`nCreatedAt after 2nd: $t2`n")
    $problems = [System.Collections.Generic.List[string]]::new()
    if ($c1.ExitCode -ne 0) { $problems.Add("the first create exited $($c1.ExitCode): $(Life-FirstLine $c1.StdErr)") }
    if ($c2.ExitCode -ne 0) { $problems.Add("the second create exited $($c2.ExitCode): $(Life-FirstLine $c2.StdErr)") }
    if ($c2.ExitCode -eq 0 -and $c2.StdOut.Trim() -ne $vol) { $problems.Add("the second create printed '$($c2.StdOut.Trim())', not the volume name") }
    if (-not $t1 -or -not $t2) { $problems.Add('docker volume inspect could not read the volume back') }
    elseif ($t1 -ne $t2) { $problems.Add("the second create REPLACED the volume: CreatedAt went from $t1 to $t2") }
    if ($problems.Count) {
        Life-Add -Id 'H-VOL-01' -Status 'FAIL' -Req @('R1') -Message ($problems -join ' | ') -Evidence @($ev)
        return
    }
    $note = 'it existed already'
    if (-not $existed) { $note = 'it did not exist before, so the first create made it, as the first ./dev up would' }
    Life-Add -Id 'H-VOL-01' -Status 'PASS' -Req @('R1') -Message "docker volume create $vol twice: both exit 0, and the second returned the same volume (CreatedAt $t2 unchanged) - $note" -Evidence @($ev)
}

function Life-Vol02 {
    $proj = $script:TestProject
    if ((Life-Opt 'KeepTestProject') -and (Invoke-TestCompose @('ps', '-a', '-q') -TimeoutSec 120).StdOut.Trim()) {
        Life-Add -Id 'H-VOL-02' -Status 'SKIP' -Req @('R1') -Message "the test project is running and -KeepTestProject asks for it to be kept, so it is not taken down with -v here"
        return
    }
    $why = $null
    # From nothing, so that "before" is exactly what `up postgres` created:
    # a volume still held by a container another suite left behind would
    # survive down -v and read as this test failing.
    if (-not (Life-Opt 'KeepTestProject')) { Remove-TestProject | Out-Null }
    $why = Initialize-TestProject
    if ($why) {
        $status = 'FAIL'
        if ($why -like 'could not build*') { $status = 'BLOCKED' }
        Life-Add -Id 'H-VOL-02' -Status $status -Req @('R1') -Message "the test project could not be prepared: $why"
        return
    }
    $realBefore = Life-VolumeExists $script:RealMavenVol
    $tm = Get-ComposeModel -Files @('docker-compose.yml', 'compose.dev.yml', 'test/compose.test.yml') -Project $proj
    Life-Say 'H-VOL-02: postgres in the test project, then down -v'
    $up = Invoke-TestCompose @('up', '-d', '--no-deps', 'postgres') -TimeoutSec 600
    $before = @(Life-ProjectVolumes $proj)
    $down = Invoke-TestCompose @('down', '-v') -TimeoutSec 600
    $after = @(Life-ProjectVolumes $proj)
    $testMaven = Life-VolumeExists $script:TestMavenVol
    $realAfter = Life-VolumeExists $script:RealMavenVol
    $vs = Life-SplitVolumes -Model $tm -Project $proj -Before $before -After $after
    $ev = Save-Evidence -Suite 'lifecycle' -Name 'H-VOL-02.txt' -Content (
        "up -d --no-deps postgres: exit $($up.ExitCode)`n$($up.StdOut)$($up.StdErr)`n" +
        "$proj volumes before down -v:`n$($before -join "`n")`n`n" +
        "down -v: exit $($down.ExitCode)`n$($down.StdOut)$($down.StdErr)`n" +
        "$proj volumes after down -v:`n$($after -join "`n")`n`n" +
        "declared by the model (non-external):`n$($vs.Declared -join "`n")`n`n" +
        "$($script:TestMavenVol) exists after: $testMaven`n$($script:RealMavenVol) exists before/after: $realBefore/$realAfter`n")

    if ($up.ExitCode -ne 0) {
        $status = 'FAIL'
        if (($up.StdOut + $up.StdErr) -match "(?i)(?:$($script:LifeBlockedPattern))") { $status = 'BLOCKED' }
        Life-Add -Id 'H-VOL-02' -Status $status -Req @('R1') -Message "postgres did not start in the test project (exit $($up.ExitCode)): $(Life-FirstLine $up.StdErr)" -Evidence @($ev)
        return
    }
    $problems = [System.Collections.Generic.List[string]]::new()
    if ($vs.Had.Count -eq 0) { $problems.Add("postgres ran, yet none of the project's declared volumes existed to remove - the test proves nothing") }
    if ($down.ExitCode -ne 0) { $problems.Add("down -v exited $($down.ExitCode): $(Life-FirstLine $down.StdErr)") }
    if ($vs.Stayed.Count) { $problems.Add("still there after down -v: $($vs.Stayed -join ', ')") }
    if (-not $testMaven) { $problems.Add("$($script:TestMavenVol) is GONE: down -v removed an external volume") }
    if ($realBefore -and -not $realAfter) { $problems.Add("$($script:RealMavenVol) is GONE") }
    if ($problems.Count) {
        Life-Add -Id 'H-VOL-02' -Status 'FAIL' -Req @('R1') -Message ($problems -join ' | ') -Evidence @($ev)
        return
    }
    $real = "$($script:RealMavenVol) did not exist to begin with"
    if ($realBefore) { $real = "$($script:RealMavenVol) untouched" }
    Life-Add -Id 'H-VOL-02' -Status 'PASS' -Req @('R1') -Message "down -v of the test project removed its $($vs.Had.Count) volume(s) ($($vs.Had -join ', ')); the external $($script:TestMavenVol) still exists; $real$($vs.Note)" -Evidence @($ev)
}

function Life-Vol03 {
    param($Ctx)
    if (-not (Life-Opt 'AllowDataLoss')) {
        Life-Add -Id 'H-VOL-03' -Status 'SKIP' -Req @('R1') -Message "not run: .\dev.ps1 down -v on your real stack empties your databases (postgres_data, kafka_data) and every target and node_modules volume of project '$($Ctx.Live)' - opt in with -AllowDataLoss"
        return
    }
    $L = $Ctx.Ps
    $before = @(Life-ProjectVolumes $Ctx.Live)
    $mavenBefore = Life-VolumeExists $script:RealMavenVol
    Life-Say "H-VOL-03: $($L.Label) down -v on project '$($Ctx.Live)' (-AllowDataLoss)"
    $d = Life-Launch -Ctx $Ctx -Launcher $L -LauncherArgs @('down', '-v') -TimeoutSec 900 -Name 'H-VOL-03-down-v'
    $after = @(Life-ProjectVolumes $Ctx.Live)
    $mavenAfter = Life-VolumeExists $script:RealMavenVol
    $vs = Life-SplitVolumes -Model $Ctx.Model -Project $Ctx.Live -Before $before -After $after
    $ev = Save-Evidence -Suite 'lifecycle' -Name 'H-VOL-03-volumes.txt' -Content (
        "project $($Ctx.Live), volumes before:`n$($before -join "`n")`n`nafter:`n$($after -join "`n")`n`n" +
        "declared by the model (non-external):`n$($vs.Declared -join "`n")`n`n" +
        "$($script:RealMavenVol) exists before/after: $mavenBefore/$mavenAfter`n")
    $evs = @($d.Evidence, $ev)
    $problems = [System.Collections.Generic.List[string]]::new()
    if ($d.ExitCode -ne 0) { $problems.Add("$($d.What) exited $($d.ExitCode): $(Life-FirstLine $d.StdErr)") }
    if ($vs.Stayed.Count) { $problems.Add("still there after down -v: $($vs.Stayed -join ', ')") }
    if ($mavenBefore -and -not $mavenAfter) { $problems.Add("$($script:RealMavenVol) is GONE: down -v took the Maven cache") }
    if ($problems.Count) {
        Life-Add -Id 'H-VOL-03' -Status 'FAIL' -Req @('R1') -Message ($problems -join ' | ') -Evidence $evs
    }
    elseif ($vs.Had.Count -eq 0) {
        Life-Add -Id 'H-VOL-03' -Status 'WARN' -Req @('R1') -Message "project '$($Ctx.Live)' had none of its declared volumes to remove, so down -v proved little; $($d.What) exited 0$($vs.Note)" -Evidence $evs
    }
    elseif (-not $mavenBefore) {
        Life-Add -Id 'H-VOL-03' -Status 'WARN' -Req @('R1') -Message "$($d.What) removed all $($vs.Had.Count) volumes of the project, but $($script:RealMavenVol) did not exist beforehand, so its survival was not tested$($vs.Note)" -Evidence $evs
    }
    else {
        Life-Add -Id 'H-VOL-03' -Status 'PASS' -Req @('R1') -Message "$($d.What) removed all $($vs.Had.Count) volumes of project '$($Ctx.Live)' ($($vs.Had -join ', ')); $($script:RealMavenVol) is still there$($vs.Note)" -Evidence $evs
    }
}

# `down -v` removes the non-external volumes the compose files DECLARE. One
# that carries the project's label but that the files no longer declare - left
# by an older version of them - is not compose's to remove: it is reported,
# never counted as a failure. Without a model every volume counts, strictly.
function Life-SplitVolumes {
    param($Model, [Parameter(Mandatory)][string] $Project, [string[]] $Before = @(), [string[]] $After = @())
    $declared = @(Life-DeclaredVolumes -Model $Model -Project $Project)
    $strict = ($declared.Count -eq 0)
    $isOurs = { param($v) $strict -or ($declared -contains $v) }
    $had = @($Before | Where-Object { & $isOurs $_ })
    $stayed = @($After | Where-Object { & $isOurs $_ })
    $stale = @($After | Where-Object { -not (& $isOurs $_) })
    $note = ''
    if ($stale.Count) { $note = "; left alone, as the compose files no longer declare them: $($stale -join ', ')" }
    if ($strict) { $note += '; the model did not render, so every volume of the project was required to go' }
    return [pscustomobject]@{ Declared = $declared; Had = $had; Stayed = $stayed; Stale = $stale; Note = $note }
}

# The names compose gives the model's non-external volumes: the explicit name
# if the model has one, else <project>_<key>. Rendered under another project
# name than the one the stack really runs as (a COMPOSE_PROJECT_NAME in .env),
# the prefix is swapped.
function Life-DeclaredVolumes {
    param($Model, [Parameter(Mandatory)][string] $Project)
    $out = [System.Collections.Generic.List[string]]::new()
    if (-not $Model -or -not $Model.PSObject.Properties['volumes'] -or $null -eq $Model.volumes) { return $out.ToArray() }
    $modelProject = ''
    if ($Model.PSObject.Properties['name']) { $modelProject = [string]$Model.name }
    foreach ($p in $Model.volumes.PSObject.Properties) {
        $v = $p.Value
        if ($v -and $v.PSObject.Properties['external'] -and $v.external) { continue }
        $name = "$($Project)_$($p.Name)"
        if ($v -and $v.PSObject.Properties['name'] -and $v.name) {
            $name = [string]$v.name
            if ($modelProject -and $modelProject -ne $Project -and $name.StartsWith("$($modelProject)_")) {
                $name = "$($Project)_" + $name.Substring($modelProject.Length + 1)
            }
        }
        $out.Add($name)
    }
    return $out.ToArray()
}

# ---------------------------------------------------------------------------
# H-UP
# ---------------------------------------------------------------------------

function Life-Up01 {
    param($Ctx)
    $id = 'H-UP-01'
    $L = $Ctx.Main
    $ev = [System.Collections.Generic.List[string]]::new()
    $d = Life-Launch -Ctx $Ctx -Launcher $L -LauncherArgs @('down') -TimeoutSec 900 -Name "$id-down"
    $ev.Add($d.Evidence)
    if ($d.ExitCode -ne 0) {
        Life-Add -Id $id -Status 'FAIL' -Req @('R9', 'R1') -Message "$($d.What) exited $($d.ExitCode): $(Life-FirstLine $d.StdErr)" -Evidence $ev
        return
    }
    $left = @(Life-RunningServices $Ctx.Live)
    if ($left.Count) {
        Life-Add -Id $id -Status 'FAIL' -Req @('R9', 'R1') -Message "$($d.What) exited 0 but left running: $($left -join ' ')" -Evidence $ev
        return
    }
    Life-Say "H-UP-01: $($L.Label) up user-service (a cold start compiles three services first; up to an hour)"
    $u = Life-Launch -Ctx $Ctx -Launcher $L -LauncherArgs @('up', 'user-service') -TimeoutSec 3600 -Name "$id-up"
    $ev.Add($u.Evidence)
    $running = @(Life-RunningServices $Ctx.Live)
    $ev.Add((Life-SaveContainers -Project $Ctx.Live -Name "$id-containers.txt"))
    $want = @($script:LifeUserServiceSet)
    $missing = @($want | Where-Object { $running -notcontains $_ })
    $extra = @($running | Where-Object { $want -notcontains $_ })
    $maven = Life-VolumeExists $script:RealMavenVol

    $problems = [System.Collections.Generic.List[string]]::new()
    if ($u.TimedOut) { $problems.Add("$($u.What) did not finish within 3600 s") }
    elseif ($u.ExitCode -ne 0) { $problems.Add("$($u.What) exited $($u.ExitCode): $(Life-LastLine $u.StdErr)") }
    if ($missing.Count) { $problems.Add("not running: $($missing -join ' ')") }
    if ($extra.Count) { $problems.Add("running but not asked for: $($extra -join ' ')") }
    if (-not $maven) { $problems.Add("$($script:RealMavenVol) does not exist after up: the launcher did not create it") }
    if ($problems.Count) {
        $status = 'FAIL'
        if (Life-LooksBlocked -Text ($u.StdOut + $u.StdErr) -Project $Ctx.Live -Services $missing) { $status = 'BLOCKED' }
        Life-Add -Id $id -Status $status -Req @('R9', 'R1') -Message ("$($L.Label): " + ($problems -join ' | ')) -Evidence $ev
        return
    }
    Life-Add -Id $id -Status 'PASS' -Req @('R9', 'R1') -Message "$($d.What), then $($u.What): running exactly $($running -join ', '), and $($script:RealMavenVol) exists" -Evidence $ev
}

# H-UP-02 and H-UP-03: down, `up webapp`, only webapp running, and the dev
# server answering. H-UP-02 also carries H-WEB-01, because it is the start
# that may install node_modules.
function Life-UpWebapp {
    param([Parameter(Mandatory)] $Ctx, [Parameter(Mandatory)][string] $Id, $Launcher, [switch] $WithWeb01)
    $req = @('R9')
    if (-not $Launcher) {
        Life-Add -Id $Id -Status 'SKIP' -Req $req -Message 'no launcher to run it with (see H-PRE)'
        if ($WithWeb01) { Life-Add -Id 'H-WEB-01' -Status 'SKIP' -Req @('R1') -Message "webapp was not started ($Id did not run)" }
        return
    }
    $pre = $null
    if ($WithWeb01) { $pre = Life-WebSnapshot }
    $ev = [System.Collections.Generic.List[string]]::new()
    $d = Life-Launch -Ctx $Ctx -Launcher $Launcher -LauncherArgs @('down') -TimeoutSec 900 -Name "$Id-down"
    $ev.Add($d.Evidence)
    $problems = [System.Collections.Generic.List[string]]::new()
    if ($d.ExitCode -ne 0) { $problems.Add("$($d.What) exited $($d.ExitCode): $(Life-FirstLine $d.StdErr)") }
    else {
        $left = @(Life-RunningServices $Ctx.Live)
        if ($left.Count) { $problems.Add("$($d.What) exited 0 but left running: $($left -join ' ')") }
    }
    $w = $null
    $running = @()
    if ($problems.Count -eq 0) {
        Life-Say "${Id}: $($Launcher.Label) up webapp, then 127.0.0.1:4200 (a cold node_modules volume installs first)"
        $u = Life-Launch -Ctx $Ctx -Launcher $Launcher -LauncherArgs @('up', 'webapp') -TimeoutSec 1800 -Name "$Id-up"
        $ev.Add($u.Evidence)
        $running = @(Life-RunningServices $Ctx.Live)
        if ($u.TimedOut) { $problems.Add("$($u.What) did not finish within 1800 s") }
        elseif ($u.ExitCode -ne 0) { $problems.Add("$($u.What) exited $($u.ExitCode): $(Life-LastLine $u.StdErr)") }
        $extra = @($running | Where-Object { $_ -ne 'webapp' })
        if ($extra.Count) { $problems.Add("running besides webapp: $($extra -join ' ') - its depends_on reached the stack") }
        if ($running -notcontains 'webapp') { $problems.Add('webapp is not running') }
        else {
            $w = Life-WaitServing
            $ev.Add((Save-Evidence -Suite 'lifecycle' -Name "$Id-webapp.log" -Content $w.Log))
            if (-not $w.Ok) { $problems.Add("http://127.0.0.1:4200 did not answer 200: $($w.Why)") }
        }
    }
    if ($problems.Count) {
        $status = 'FAIL'
        $text = ''
        if ($w) { $text = $w.Log }
        if ($text -match "(?i)(?:$($script:LifeBlockedPattern)|ETIMEDOUT|EAI_AGAIN|ECONNRESET)") { $status = 'BLOCKED' }
        Life-Add -Id $Id -Status $status -Req $req -Message ("$($Launcher.Label): " + ($problems -join ' | ')) -Evidence $ev
    }
    else {
        $how = 'node_modules was current, no install'
        if ($w.Installed) { $how = 'npm ci ran first' }
        Life-Add -Id $Id -Status 'PASS' -Req $req -Message ("$($Launcher.Label): down, then up webapp - only webapp running; http://127.0.0.1:4200 answered 200 {0}s after up, {1}s after the dev server started ({2})" -f $w.Secs, $w.ServeSecs, $how) -Evidence $ev
        if ($Id -eq 'H-UP-02') { $Ctx.WebReady = $true }
    }

    if ($WithWeb01) {
        if (-not (Life-ContainerState $script:LifeWebappContainer)) {
            Life-Add -Id 'H-WEB-01' -Status 'SKIP' -Req @('R1') -Message "the webapp container never existed ($Id failed first), so there is no start to compare across"
            return
        }
        Life-CompareWeb -Pre $pre -Post (Life-WebSnapshot) -Id 'H-WEB-01' -What 'webapp started'
    }
}

function Life-Up03 {
    param($Ctx)
    $h = Get-Harness
    if ($h.OnWindows) {
        if (-not $Ctx.Sh) {
            Life-Add -Id 'H-UP-03' -Status 'SKIP' -Req @('R9') -Message $Ctx.ShWhy
            return
        }
        Life-UpWebapp -Ctx $Ctx -Id 'H-UP-03' -Launcher $Ctx.Sh
        return
    }
    Life-Add -Id 'H-UP-03' -Status 'SKIP' -Req @('R9') -Message 'Git Bash is the Windows case - MSYS argument rewriting happens only there; ./dev runs under /bin/sh here instead, as H-UP-03-sh'
    if (-not $Ctx.Sh) {
        Life-Add -Id 'H-UP-03-sh' -Status 'SKIP' -Req @('R9') -Message $Ctx.ShWhy
        return
    }
    Life-UpWebapp -Ctx $Ctx -Id 'H-UP-03-sh' -Launcher $Ctx.Sh
}

# ---------------------------------------------------------------------------
# H-WEB
# ---------------------------------------------------------------------------

# package.json, package-lock.json and git status of home-crew-webapp.
function Life-WebSnapshot {
    $repo = Get-RepoPath 'home-crew-webapp'
    $st = $null
    if ((Get-Harness).Git -and (Test-Path -LiteralPath $repo -PathType Container)) { $st = Invoke-Git $repo @('status', '--porcelain') }
    $status = $null
    if ($st -and $st.ExitCode -eq 0) { $status = $st.StdOut.Replace("`r", '').Trim() }
    return [pscustomobject]@{
        Pkg    = Life-Sha (Join-Path $repo 'package.json')
        Lock   = Life-Sha (Join-Path $repo 'package-lock.json')
        Status = $status
    }
}

function Life-CompareWeb {
    param($Pre, $Post, [string] $Id, [string] $What)
    $ev = Save-Evidence -Suite 'lifecycle' -Name "$Id.txt" -Content (
        "before: package.json $($Pre.Pkg)`n        package-lock.json $($Pre.Lock)`n        git status:`n$($Pre.Status)`n`n" +
        "after:  package.json $($Post.Pkg)`n        package-lock.json $($Post.Lock)`n        git status:`n$($Post.Status)`n")
    $problems = [System.Collections.Generic.List[string]]::new()
    if ($Pre.Pkg -eq 'ABSENT') { $problems.Add('home-crew-webapp has no package.json') }
    if ($Pre.Pkg -ne $Post.Pkg) { $problems.Add("package.json changed ($(Life-Short $Pre.Pkg) -> $(Life-Short $Post.Pkg))") }
    if ($Pre.Lock -ne $Post.Lock) { $problems.Add("package-lock.json changed ($(Life-Short $Pre.Lock) -> $(Life-Short $Post.Lock))") }
    if ($null -eq $Pre.Status -or $null -eq $Post.Status) { $problems.Add('git status could not be read') }
    elseif ($Pre.Status -cne $Post.Status) { $problems.Add('git status changed') }
    if ($problems.Count) {
        Life-Add -Id $Id -Status 'FAIL' -Req @('R1') -Message "after ${What}: $($problems -join ' | ')" -Evidence @($ev)
        return
    }
    $clean = 'clean'
    if ($Pre.Status) { $clean = 'unchanged (it was not clean before either)' }
    Life-Add -Id $Id -Status 'PASS' -Req @('R1') -Message "after ${What}: package.json and package-lock.json have the same sha256 as before, and git status is $clean" -Evidence @($ev)
}

function Life-Web02 {
    param($Ctx)
    $ids = @('H-WEB-02', 'H-WEB-02-RESTORE', 'H-WEB-03')
    if (-not $Ctx.WebReady) {
        foreach ($i in $ids) { Life-Add -Id $i -Status 'SKIP' -Req @('R1') -Message 'webapp is not serving (see H-UP-02), so there is no installed container to restart' }
        return
    }
    $h = Get-Harness
    $repo = Get-RepoPath 'home-crew-webapp'
    $lock = Join-Path $repo 'package-lock.json'
    $pkg = Join-Path $repo 'package.json'
    if (-not (Test-Path -LiteralPath $lock -PathType Leaf)) {
        foreach ($i in $ids) { Life-Add -Id $i -Status 'SKIP' -Req @('R1') -Message "home-crew-webapp has no package-lock.json" }
        return
    }
    $st0 = Invoke-Git $repo @('status', '--porcelain')
    if ($st0.ExitCode -ne 0) {
        foreach ($i in $ids) { Life-Add -Id $i -Status 'SKIP' -Req @('R1') -Message "git status failed in home-crew-webapp (exit $($st0.ExitCode)): $(Life-FirstLine $st0.StdErr)" }
        return
    }
    $status0 = $st0.StdOut.Replace("`r", '').Trim()
    # Never a file you are working on: the manifest would put your bytes back,
    # but npm ci would install from them in between.
    $mine = @(($status0 -split "`n") | Where-Object { $_ -match 'package(-lock)?\.json\s*$' })
    if ($mine.Count) {
        foreach ($i in $ids) { Life-Add -Id $i -Status 'SKIP' -Req @('R1') -Message "you have uncommitted changes to $(($mine | ForEach-Object { $_.Trim() }) -join ', ') in home-crew-webapp; the harness does not edit them" }
        return
    }
    $orig = [System.IO.File]::ReadAllBytes($lock)
    $origHash = Get-Sha256Hex $orig
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    $text = $utf8.GetString($orig)
    if ((Get-Sha256Hex ($utf8.GetBytes($text))) -ne $origHash) {
        foreach ($i in $ids) { Life-Add -Id $i -Status 'SKIP' -Req @('R1') -Message 'package-lock.json is not valid UTF-8, so the harness cannot append to it and restore it byte for byte' }
        return
    }
    $newText = $text + "`n"
    $wroteHash = Get-Sha256Hex ($utf8.GetBytes($newText))
    $pkgHash = Life-Sha $pkg

    $r1 = $null
    $hostAfter = ''
    $pkgAfter = ''
    $stamp1 = $null
    $refused = @()
    $restoreErr = ''
    $editErr = ''
    $manifest = Start-EditManifest 'lifecycle-webapp'
    # Restored in finally, whatever happens in between; an error in between is
    # reported below rather than thrown, so that the restore's own outcome is
    # always reported too.
    try {
        Set-TrackedFile -Path $lock -Content $newText
        Life-Say 'H-WEB-02: package-lock.json + one newline, docker restart homecrew-webapp (npm ci: minutes)'
        $r1 = Life-RestartWebapp -Tag 'H-WEB-02-edit'
        $hostAfter = Life-Sha $lock
        $pkgAfter = Life-Sha $pkg
        if ($r1.DevServer) { $stamp1 = Life-WebappStamp }
    }
    catch {
        $editErr = $_.Exception.Message
    }
    finally {
        try { $refused = @(Restore-EditManifest) }
        catch { $restoreErr = $_.Exception.Message }
    }

    # H-WEB-02: the edit was noticed, installed, and left alone on the host.
    $p = [System.Collections.Generic.List[string]]::new()
    if ($editErr) { $p.Add("harness error during the edit round: $editErr") }
    Life-CheckReinstall -Round $r1 -Problems $p
    if ($r1 -and $hostAfter -ne $wroteHash) {
        $what = 'different bytes'
        if ($hostAfter -eq $origHash) { $what = 'the ORIGINAL bytes again' }
        elseif ($hostAfter -eq 'ABSENT') { $what = 'nothing - the file is gone' }
        $p.Add("the host package-lock.json holds $what, not the bytes the harness wrote: something in the container rewrote it")
    }
    if ($r1 -and $pkgAfter -ne $pkgHash) { $p.Add('package.json changed on the host') }
    if ($r1 -and $r1.DevServer) {
        if (-not $stamp1 -or -not $stamp1.Ok) { $p.Add("the install stamp does not match the edited files: $(Life-StampText $stamp1)") }
    }
    $ev1 = @($manifest)
    if ($r1) { $ev1 += $r1.Evidence }
    if ($p.Count) {
        Life-Add -Id 'H-WEB-02' -Status 'FAIL' -Req @('R1') -Message ($p -join ' | ') -Evidence $ev1
    }
    else {
        Life-Add -Id 'H-WEB-02' -Status 'PASS' -Req @('R1') -Message ("one newline appended to package-lock.json; after docker restart the log shows 'reinstalling with npm ci', then the dev server starting ({0}s), the stamp matches the new files, and the host file still has exactly the bytes the harness wrote (sha256 {1}...)" -f $r1.Secs, $wroteHash.Substring(0, 12)) -Evidence $ev1
    }

    # H-WEB-02-RESTORE: the original back, reinstalled from, git as it was.
    $p = [System.Collections.Generic.List[string]]::new()
    $r2 = $null
    $stamp2 = $null
    $nowHash = Life-Sha $lock
    if ($restoreErr) { $p.Add("restoring package-lock.json threw: $restoreErr") }
    if ($refused.Count) { $p.Add("REFUSED to restore $($refused -join ', '): it changed since the harness wrote it - nothing was overwritten; compare it with the manifest $manifest, or run test/run.ps1 -Restore $($h.RunId)") }
    if ($nowHash -ne $origHash) { $p.Add('package-lock.json is not back to its original bytes') }
    else {
        Life-Say 'H-WEB-02: restored; docker restart homecrew-webapp again'
        $r2 = Life-RestartWebapp -Tag 'H-WEB-02-restore'
        Life-CheckReinstall -Round $r2 -Problems $p
        if ($r2.DevServer) {
            $stamp2 = Life-WebappStamp
            if (-not $stamp2 -or -not $stamp2.Ok) { $p.Add("the install stamp does not match the restored files: $(Life-StampText $stamp2)") }
        }
    }
    $st1 = Invoke-Git $repo @('status', '--porcelain')
    $status1 = $null
    if ($st1.ExitCode -eq 0) { $status1 = $st1.StdOut.Replace("`r", '').Trim() }
    if ($null -eq $status1) { $p.Add('git status could not be read afterwards') }
    elseif ($status1 -cne $status0) { $p.Add("git status of home-crew-webapp is not what it was: '$($status1 -replace "`n", '; ')'") }
    $ev2 = @($manifest)
    if ($r2) { $ev2 += $r2.Evidence }
    if ($p.Count) {
        Life-Add -Id 'H-WEB-02-RESTORE' -Status 'FAIL' -Req @('R1') -Message ($p -join ' | ') -Evidence $ev2
    }
    else {
        $clean = 'clean'
        if ($status0) { $clean = 'as it was before' }
        Life-Add -Id 'H-WEB-02-RESTORE' -Status 'PASS' -Req @('R1') -Message ("package-lock.json restored byte for byte; the next restart reinstalled again and the dev server started ({0}s); the stamp matches the original files; git status is {1}" -f $r2.Secs, $clean) -Evidence $ev2
    }

    # H-WEB-03: both reinstalls went onto the populated volume.
    $rounds = @(@($r1, $r2) | Where-Object { $_ -and $_.Reinstall })
    if ($rounds.Count -eq 0) {
        Life-Add -Id 'H-WEB-03' -Status 'SKIP' -Req @('R1') -Message 'no reinstall ran (see H-WEB-02), so npm ci onto a populated node_modules volume was not exercised'
        return
    }
    $p = [System.Collections.Generic.List[string]]::new()
    foreach ($r in $rounds) {
        if ($r.Ebusy) { $p.Add("$($r.Tag): EBUSY in the log ($(Life-Clip $r.EbusyLine 160)) - npm tried to remove the node_modules mount point") }
        if ($r.CiFailed) { $p.Add("$($r.Tag): npm ci failed") }
        elseif (-not $r.DevServer) { $p.Add("$($r.Tag): the dev server never started ($($r.Why))") }
    }
    $evs = @($rounds | ForEach-Object { $_.Evidence })
    if ($p.Count) {
        Life-Add -Id 'H-WEB-03' -Status 'FAIL' -Req @('R1') -Message ($p -join ' | ') -Evidence $evs
    }
    else {
        Life-Add -Id 'H-WEB-03' -Status 'PASS' -Req @('R1') -Message "$($rounds.Count) reinstall(s) onto the populated node_modules volume: npm ci succeeded each time, no EBUSY, and the dev server started after it" -Evidence $evs
    }
}

# The reinstall a changed lockfile must cause: the right line, then the dev
# server, in that order, and no npm ci failure.
function Life-CheckReinstall {
    param($Round, [System.Collections.Generic.List[string]] $Problems)
    if (-not $Round) { $Problems.Add('the restart did not happen'); return }
    if ($Round.RestartExit -ne 0) { $Problems.Add("docker restart $($script:LifeWebappContainer) exited $($Round.RestartExit)"); return }
    if (-not $Round.Reinstall) {
        if ($Round.FreshInstall) { $Problems.Add("$($Round.Tag): it logged 'installing dependencies' instead of 'reinstalling': the stamp of the last install was missing") }
        elseif ($Round.Skipped) { $Problems.Add("$($Round.Tag): it logged 'skipping install' - the changed package-lock.json went unnoticed") }
        else { $Problems.Add("$($Round.Tag): no 'reinstalling with npm ci' line") }
    }
    if ($Round.CiFailed) { $Problems.Add("$($Round.Tag): npm ci failed (see the log)") }
    elseif (-not $Round.DevServer) { $Problems.Add("$($Round.Tag): the dev server did not start ($($Round.Why))") }
    elseif ($Round.Reinstall -and -not $Round.OrderOk) { $Problems.Add("$($Round.Tag): the dev server started before the reinstall line") }
}

# `docker restart homecrew-webapp`, then its log from the moment it started
# again - State.StartedAt, the daemon's own clock, so no host clock is
# compared with the VM's - until the dev server starts, npm ci fails, the
# container stops, or the time is up.
function Life-RestartWebapp {
    param([Parameter(Mandatory)][string] $Tag, [int] $TimeoutSec = 1200)
    $c = $script:LifeWebappContainer
    $w = [pscustomobject]@{
        Tag = $Tag; RestartExit = 0; Since = ''; Out = ''; Err = ''; DevServer = $false; CiFailed = $false
        Reinstall = $false; FreshInstall = $false; Skipped = $false; OrderOk = $false; Ebusy = $false; EbusyLine = ''
        Why = ''; Secs = 0; Evidence = ''
    }
    $r = Invoke-Docker @('restart', $c) -TimeoutSec 180
    $w.RestartExit = $r.ExitCode
    $t0 = [DateTime]::UtcNow
    if ($r.ExitCode -eq 0) {
        $w.Since = Life-StartedAt $c
        while ($true) {
            $lg = Life-Logs -Container $c -Since $w.Since
            $w.Out = $lg.Out
            $w.Err = $lg.Err
            if ($lg.Out -match 'starting the Angular dev server') { $w.DevServer = $true; break }
            if ($lg.Out -match 'npm ci failed') { $w.CiFailed = $true; $w.Why = 'npm ci failed'; break }
            $state = Life-ContainerState $c
            if ($state -ne 'running') { $w.Why = "the container is $(Life-StateText $state)"; break }
            if (([DateTime]::UtcNow - $t0).TotalSeconds -gt $TimeoutSec) { $w.Why = "not within ${TimeoutSec}s"; break }
            Start-Sleep -Seconds 5
        }
    }
    else { $w.Why = "docker restart exited $($r.ExitCode): $(Life-FirstLine $r.StdErr)" }
    $w.Secs = [int]([DateTime]::UtcNow - $t0).TotalSeconds
    $out = $w.Out
    $w.Reinstall = $out -match 'reinstalling with npm ci'
    $w.FreshInstall = $out -match 'installing dependencies with npm ci'
    $w.Skipped = $out -match 'skipping install'
    $iR = $out.IndexOf('reinstalling with npm ci')
    $iS = $out.IndexOf('starting the Angular dev server')
    $w.OrderOk = ($iR -ge 0 -and $iS -gt $iR)
    $eb = [regex]::Match($out + "`n" + $w.Err, '(?m)^[^\r\n]*EBUSY[^\r\n]*')
    $w.Ebusy = $eb.Success
    if ($eb.Success) { $w.EbusyLine = $eb.Value.Trim() }
    $w.Evidence = Save-Evidence -Suite 'lifecycle' -Name "$Tag-webapp.log" -Content (
        "# docker restart $c - exit $($r.ExitCode); log since State.StartedAt $($w.Since); $($w.Secs)s`n" +
        "# dev server started: $($w.DevServer); npm ci failed: $($w.CiFailed); $($w.Why)`n" +
        "---- stdout ----`n$($w.Out)`n---- stderr ----`n$($w.Err)`n")
    return $w
}

# What webapp-dev.sh compares: the checksum of the two files as the container
# sees them, and the stamp it writes after a successful install.
function Life-WebappStamp {
    $r = Invoke-Docker @('exec', $script:LifeWebappContainer, 'sh', '-c', 'cd /app && cat package.json package-lock.json 2>/dev/null | cksum && cat node_modules/.homecrew-lock.cksum 2>/dev/null') -TimeoutSec 60
    $lines = @(($r.StdOut -split "`r?`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $want = ''
    $have = ''
    if ($lines.Count -ge 1) { $want = $lines[0] }
    if ($lines.Count -ge 2) { $have = $lines[1] }
    return [pscustomobject]@{ Want = $want; Have = $have; Ok = ($r.ExitCode -eq 0 -and $want -and $want -eq $have) }
}

function Life-StampText {
    param($Stamp)
    if (-not $Stamp) { return 'not read' }
    $have = $Stamp.Have
    if (-not $have) { $have = 'no stamp' }
    return "files '$($Stamp.Want)', stamp '$have'"
}

# Until 127.0.0.1:4200 answers 200: $script:LifeInstallSec for the dev server
# to start (npm ci on a cold volume comes first), then $script:LifeServeSec
# from that moment for it to answer.
function Life-WaitServing {
    $c = $script:LifeWebappContainer
    $t0 = [DateTime]::UtcNow
    $since = Life-StartedAt $c
    $serveFrom = $null
    $w = [pscustomobject]@{ Ok = $false; Code = 0; Secs = 0; ServeSecs = -1; Installed = $false; Why = ''; Log = '' }
    $out = ''
    $err = ''
    while ($true) {
        $code = Life-HttpCode $script:LifeWebappUrl
        $w.Code = $code
        $lg = Life-Logs -Container $c -Since $since
        $out = $lg.Out
        $err = $lg.Err
        $now = [DateTime]::UtcNow
        if ($null -eq $serveFrom -and $out -match 'starting the Angular dev server') { $serveFrom = $now }
        if ($code -eq 200) {
            $w.Ok = $true
            if ($null -eq $serveFrom) { $serveFrom = $now }
            break
        }
        if ($out -match 'npm ci failed') { $w.Why = 'npm ci failed in the container (see its log)'; break }
        $state = Life-ContainerState $c
        if ($state -ne 'running') { $w.Why = "the container is $(Life-StateText $state)"; break }
        if ($null -eq $serveFrom -and ($now - $t0).TotalSeconds -gt $script:LifeInstallSec) {
            $w.Why = "the dev server did not start within $($script:LifeInstallSec)s (npm ci still running?)"
            break
        }
        if ($null -ne $serveFrom -and ($now - $serveFrom).TotalSeconds -gt $script:LifeServeSec) {
            $w.Why = "no 200 within $($script:LifeServeSec)s of the dev server starting (last answer: $(Life-CodeText $code))"
            break
        }
        Start-Sleep -Seconds 5
    }
    $end = [DateTime]::UtcNow
    $w.Secs = [int]($end - $t0).TotalSeconds
    if ($null -ne $serveFrom) { $w.ServeSecs = [int]($end - $serveFrom).TotalSeconds }
    $w.Installed = $out -match 'with npm ci'
    $w.Log = "# log of $c since State.StartedAt $since; last HTTP answer $(Life-CodeText $w.Code) after $($w.Secs)s`n---- stdout ----`n$out`n---- stderr ----`n$err`n"
    return $w
}

# The HTTP status of one GET, 0 when nothing answered. No proxy: this is the
# loopback address, and a corporate proxy must not be what answers it.
function Life-HttpCode {
    param([Parameter(Mandatory)][string] $Url, [int] $TimeoutSec = 10)
    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.UseProxy = $false
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
    try {
        $resp = $client.GetAsync($Url).GetAwaiter().GetResult()
        $code = [int]$resp.StatusCode
        $resp.Dispose()
        return $code
    }
    catch { return 0 }
    finally { $client.Dispose() }
}

function Life-CodeText {
    param([int] $Code)
    if ($Code -eq 0) { return 'nothing answered' }
    return "HTTP $Code"
}

# ---------------------------------------------------------------------------
# The stack as it was
# ---------------------------------------------------------------------------

function Life-RestoreStack {
    param($Ctx)
    if (-not $Ctx -or -not $Ctx.Touched) { return }
    $L = $Ctx.Main
    $target = @($Ctx.StartServices)
    $ev = [System.Collections.Generic.List[string]]::new()
    Life-Say "H-RESTORE: $($L.Label) down, then up $($target -join ' ')"
    $d = Life-Launch -Ctx $Ctx -Launcher $L -LauncherArgs @('down') -TimeoutSec 900 -Name 'H-RESTORE-down'
    $ev.Add($d.Evidence)
    $u = $null
    if ($target.Count -gt 0) {
        $u = Life-Launch -Ctx $Ctx -Launcher $L -LauncherArgs (@('up') + $target) -TimeoutSec 3600 -Name 'H-RESTORE-up'
        $ev.Add($u.Evidence)
    }
    $now = @(Life-RunningServices $Ctx.Live)
    $want = (@($target | Sort-Object) -join ' ')
    $have = (@($now | Sort-Object) -join ' ')
    if ($target.Count -eq 0) {
        if ($d.ExitCode -eq 0 -and $now.Count -eq 0) {
            Life-Add -Id 'H-RESTORE' -Status 'PASS' -Message "your stack was not running at the start, and is down again ($($d.What))" -Evidence $ev
        }
        else {
            Life-Add -Id 'H-RESTORE' -Status 'FAIL' -Message "your stack was not running at the start; after $($d.What) (exit $($d.ExitCode)) these are still running: $have" -Evidence $ev
        }
        return
    }
    # A superset is fine: a dependency that had crashed before the run is
    # started again by `up`, as it would be by yours.
    $missing = @($target | Where-Object { $now -notcontains $_ })
    $extra = @($now | Where-Object { $target -notcontains $_ })
    if ($u.ExitCode -eq 0 -and $missing.Count -eq 0) {
        $note = ''
        if ($extra.Count) { $note = "; also running now, as dependencies: $($extra -join ' ')" }
        Life-Add -Id 'H-RESTORE' -Status 'PASS' -Message "running again, as at the start: $want ($($u.What))$note" -Evidence $ev
    }
    else {
        Life-Add -Id 'H-RESTORE' -Status 'FAIL' -Message "your stack ran $want at the start; after $($u.What) (exit $($u.ExitCode)) it runs '$have'. Start it yourself: $($L.Label) up $($target -join ' ')" -Evidence $ev
    }
}

# Everything the launcher tests need, and the reasons they cannot run.
function Life-NewContext {
    $h = Get-Harness
    $c = [pscustomobject]@{
        Why = ''; WhyStatus = 'SKIP'; Live = ''; Model = $null; Ps = $null; Sh = $null; ShWhy = ''; Main = $null
        StartServices = @(); Touched = $false; WebReady = $false
    }
    $m = Get-ComposeModel
    if (-not $m -or -not $m.PSObject.Properties['name'] -or -not [string]$m.name) {
        $c.Why = 'docker compose config (docker-compose.yml + compose.dev.yml, test/fixtures/ci.env) failed, so the live project name is unknown - see commands.log'
        $c.WhyStatus = 'FAIL'
        return $c
    }
    $c.Model = $m
    $c.Live = Life-ProjectName ([string]$m.name)
    # The container names are pinned, so a stack from another checkout of this
    # repository - another compose project - holds them. Taking it down is not
    # this suite's business, and starting this one would collide with it.
    $others = @(Life-LiveContainers | Where-Object { $_.Project -ne $c.Live })
    if ($others.Count) {
        $list = @($others | Select-Object -First 4 | ForEach-Object {
                $p = $_.Project
                if (-not $p) { $p = 'no compose project' }
                "$($_.Name) ($p)"
            }) -join ', '
        $c.Why = "containers with the pinned names belong to another compose project than this checkout's '$($c.Live)': $list - stop that stack from its own checkout first"
        return $c
    }
    $c.Ps = Life-PsLauncher
    $sh = Life-ShLauncher
    $c.Sh = $sh.Launcher
    $c.ShWhy = $sh.Why
    if ($h.OnWindows) { $c.Main = $c.Ps }
    else {
        $c.Main = $c.Sh
        if (-not $c.Main) { $c.Main = $c.Ps }
    }
    $c.StartServices = @(Life-RunningServices $c.Live)
    return $c
}

# compose's own rule, as far as it can differ from the model above: that was
# rendered with the fixture env file, so a COMPOSE_PROJECT_NAME in the real
# .env (which the launchers do read) is looked up here. Only that one key is
# read; nothing else from .env leaves this function.
function Life-ProjectName {
    param([Parameter(Mandatory)][string] $ModelName)
    $h = Get-Harness
    if ($env:COMPOSE_PROJECT_NAME) { return $ModelName }
    $f = Join-Path $h.InfraRoot '.env'
    if (Test-Path -LiteralPath $f -PathType Leaf) {
        foreach ($l in [System.IO.File]::ReadAllLines($f)) {
            if ($l -match '^\s*COMPOSE_PROJECT_NAME\s*=\s*(.*)$') {
                $v = $Matches[1].Trim().Trim('"').Trim("'")
                if ($v) { return $v.ToLowerInvariant() }
            }
        }
    }
    return $ModelName
}

# ---------------------------------------------------------------------------
# The launchers
# ---------------------------------------------------------------------------

function Life-PsLauncher {
    $h = Get-Harness
    $exe = 'pwsh'
    if ($h.OnWindows) { $exe = 'pwsh.exe' }
    $p = Join-Path $PSHOME $exe
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { $p = (Get-Process -Id $PID).Path }
    $pre = @('-NoProfile')
    if ($h.OnWindows) { $pre += @('-ExecutionPolicy', 'Bypass') }
    $pre += @('-File', (Join-Path $h.InfraRoot 'dev.ps1'))
    $label = 'pwsh dev.ps1'
    if ($h.OnWindows) { $label = '.\dev.ps1 (pwsh)' }
    return [pscustomobject]@{ Label = $label; Exe = $p; PreArgs = $pre; Env = @{} }
}

function Life-ShLauncher {
    $h = Get-Harness
    if ($h.OnWindows) {
        $gb = Life-FindGitBash
        if (-not $gb) {
            return [pscustomobject]@{ Launcher = $null; Why = 'Git for Windows not found (no <GitRoot>\bin\sh.exe above git --exec-path), so ./dev under Git Bash could not run' }
        }
        # A Git Bash window's order: mingw, then usr/bin, then Windows' PATH,
        # which is where docker.exe is. The MSYS_* variables are NOT set here:
        # ./dev exports its own, and that export is part of what is tested.
        $path = (@($gb.MingwBins) + @($gb.UsrBin) + @($env:PATH)) -join ';'
        return [pscustomobject]@{
            Launcher = [pscustomobject]@{ Label = 'sh ./dev (Git Bash)'; Exe = $gb.Sh; PreArgs = @('./dev'); Env = @{ PATH = $path } }
            Why      = ''
        }
    }
    if (-not (Test-Path -LiteralPath '/bin/sh' -PathType Leaf)) {
        return [pscustomobject]@{ Launcher = $null; Why = 'there is no /bin/sh here' }
    }
    return [pscustomobject]@{ Launcher = [pscustomobject]@{ Label = 'sh ./dev'; Exe = '/bin/sh'; PreArgs = @('./dev'); Env = @{} }; Why = '' }
}

# <GitRoot>\bin\sh.exe, GitRoot being the first ancestor of `git --exec-path`
# with both bin\sh.exe and usr\bin (Git for Windows' layout) - the same rule
# as suite B's.
function Life-FindGitBash {
    $h = Get-Harness
    if (-not $h.OnWindows -or -not $h.Git) { return $null }
    $r = Invoke-Native -FilePath $h.Git -ArgumentList @('--exec-path') -TimeoutSec 60 -Quiet
    if ($r.ExitCode -ne 0 -or -not $r.StdOut.Trim()) { return $null }
    $d = [System.IO.Path]::GetFullPath($r.StdOut.Trim())
    while ($d) {
        $sh = [System.IO.Path]::Combine($d, 'bin', 'sh.exe')
        $usr = [System.IO.Path]::Combine($d, 'usr', 'bin')
        if ([System.IO.File]::Exists($sh) -and [System.IO.Directory]::Exists($usr)) {
            $mingw = @(foreach ($m in @('mingw64', 'clangarm64', 'ucrt64', 'mingw32')) {
                    $b = [System.IO.Path]::Combine($d, $m, 'bin')
                    if ([System.IO.Directory]::Exists($b)) { $b }
                })
            return [pscustomobject]@{ Root = $d; Sh = $sh; UsrBin = $usr; MingwBins = $mingw }
        }
        $d = [System.IO.Path]::GetDirectoryName($d)
    }
    return $null
}

# The compose command a launcher command becomes, shown to the guard first.
function Life-AssertLauncherSafe {
    param([string[]] $LauncherArgs)
    $a = @($LauncherArgs)
    if ($a.Count -eq 0) { return }
    if ($a[0] -in @('up', 'down', 'logs')) {
        Assert-DockerArgsSafe (@('compose', '-f', 'docker-compose.yml', '-f', 'compose.dev.yml') + $a)
    }
}

# One launcher command from the infra root, as a user runs it; its whole
# output is evidence.
function Life-Launch {
    param(
        [Parameter(Mandatory)] $Ctx,
        [Parameter(Mandatory)] $Launcher,
        [Parameter(Mandatory)][string[]] $LauncherArgs,
        [int] $TimeoutSec = 900,
        [Parameter(Mandatory)][string] $Name
    )
    $h = Get-Harness
    Life-AssertLauncherSafe $LauncherArgs
    $Ctx.Touched = $true
    $r = Invoke-Native -FilePath $Launcher.Exe -ArgumentList (@($Launcher.PreArgs) + @($LauncherArgs)) -WorkingDirectory $h.InfraRoot -Environment $Launcher.Env -TimeoutSec $TimeoutSec
    $what = "$($Launcher.Label) $($LauncherArgs -join ' ')"
    $tail = ''
    if ($r.TimedOut) { $tail = " - TIMED OUT after ${TimeoutSec}s" }
    $ev = Save-Evidence -Suite 'lifecycle' -Name "$Name.txt" -Content (
        "# $what`n# $($r.CommandLine)`n# exit $($r.ExitCode)$tail`n---- stdout ----`n$($r.StdOut)`n---- stderr ----`n$($r.StdErr)`n")
    return [pscustomobject]@{ ExitCode = $r.ExitCode; StdOut = $r.StdOut; StdErr = $r.StdErr; TimedOut = $r.TimedOut; Evidence = $ev; What = $what }
}

# A failed start is BLOCKED when the launcher's output, or the log of a
# service that did not come up, shows the network failing rather than the
# setup.
function Life-LooksBlocked {
    param([AllowEmptyString()][string] $Text, [string] $Project, [string[]] $Services = @())
    if ($Text -match "(?i)(?:$($script:LifeBlockedPattern))") { return $true }
    foreach ($s in @($Services)) {
        $name = "$($script:LiveContainerPrefix)$s"
        if (-not (Life-ContainerState $name)) { continue }
        $lg = Life-Logs -Container $name -Tail 400
        if (($lg.Out + $lg.Err) -match "(?i)(?:$($script:LifeBlockedPattern))") { return $true }
    }
    return $false
}

# ---------------------------------------------------------------------------
# Docker state
# ---------------------------------------------------------------------------

# Services of the project with a RUNNING container, sorted. A docker ps that
# fails throws: an empty answer would read as "nothing is running".
function Life-RunningServices {
    param([Parameter(Mandatory)][string] $Project)
    $r = Invoke-Docker @('ps', '--filter', "label=com.docker.compose.project=$Project", '--filter', 'status=running', '--format', '{{.Label "com.docker.compose.service"}}') -TimeoutSec 60
    if ($r.ExitCode -ne 0) { throw "docker ps failed (exit $($r.ExitCode)): $(Life-FirstLine $r.StdErr)" }
    return @(($r.StdOut -split "`r?`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Sort-Object -Unique)
}

# Every container with a pinned homecrew-* name (the test project's are
# homecrew-test-*, and not pinned), with its compose labels.
function Life-LiveContainers {
    $r = Invoke-Docker @('ps', '-a', '--format', '{{.Names}}|{{.Label "com.docker.compose.project"}}|{{.Label "com.docker.compose.service"}}|{{.Status}}') -TimeoutSec 60
    if ($r.ExitCode -ne 0) { throw "docker ps -a failed (exit $($r.ExitCode)): $(Life-FirstLine $r.StdErr)" }
    $list = [System.Collections.Generic.List[object]]::new()
    foreach ($l in ($r.StdOut -split "`r?`n")) {
        $p = @($l.Trim() -split '\|', 4)
        if ($p.Count -lt 4 -or -not $p[0]) { continue }
        if ($p[0] -notlike "$($script:LiveContainerPrefix)*" -or $p[0] -like "$($script:TestProject)*") { continue }
        $list.Add([pscustomobject]@{ Name = $p[0]; Project = $p[1]; Service = $p[2]; Status = $p[3] })
    }
    return $list.ToArray()
}

function Life-SaveContainers {
    param([Parameter(Mandatory)][string] $Project, [Parameter(Mandatory)][string] $Name)
    $r = Invoke-Docker @('ps', '-a', '--filter', "label=com.docker.compose.project=$Project", '--format', '{{.Names}}|{{.Label "com.docker.compose.service"}}|{{.Status}}') -TimeoutSec 60
    return (Save-Evidence -Suite 'lifecycle' -Name $Name -Content ("containers of project $Project (name|service|status):`n" + $r.StdOut))
}

# A project's volumes, by compose's label and by the <project>_ prefix it
# names them with: either alone could miss one.
function Life-ProjectVolumes {
    param([Parameter(Mandatory)][string] $Project)
    $a = Invoke-Docker @('volume', 'ls', '--filter', "label=com.docker.compose.project=$Project", '--format', '{{.Name}}') -TimeoutSec 60
    $b = Invoke-Docker @('volume', 'ls', '--format', '{{.Name}}') -TimeoutSec 60
    if ($a.ExitCode -ne 0 -or $b.ExitCode -ne 0) { throw "docker volume ls failed: $(Life-FirstLine ($a.StdErr + $b.StdErr))" }
    $byLabel = @(($a.StdOut -split "`r?`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $byName = @(($b.StdOut -split "`r?`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ -like "$($Project)_*" })
    return @(@($byLabel) + @($byName) | Sort-Object -Unique)
}

function Life-VolumeExists {
    param([Parameter(Mandatory)][string] $Name)
    return ((Invoke-Docker @('volume', 'inspect', $Name) -TimeoutSec 60).ExitCode -eq 0)
}

function Life-VolumeCreatedAt {
    param([Parameter(Mandatory)][string] $Name)
    $r = Invoke-Docker @('volume', 'inspect', '--format', '{{.CreatedAt}}', $Name) -TimeoutSec 60
    if ($r.ExitCode -ne 0) { return '' }
    return $r.StdOut.Trim()
}

# '' when there is no such container.
function Life-ContainerState {
    param([Parameter(Mandatory)][string] $Name)
    $r = Invoke-Docker @('inspect', '--format', '{{.State.Status}}', $Name) -TimeoutSec 60
    if ($r.ExitCode -ne 0) { return '' }
    return $r.StdOut.Trim()
}

function Life-StateText {
    param([AllowEmptyString()][string] $State)
    if (-not $State) { return 'gone' }
    return $State
}

function Life-StartedAt {
    param([Parameter(Mandatory)][string] $Name)
    $r = Invoke-Docker @('inspect', '--format', '{{.State.StartedAt}}', $Name) -TimeoutSec 60
    if ($r.ExitCode -ne 0) { return '' }
    return $r.StdOut.Trim()
}

# A container's log with the two streams apart: webapp-dev.sh writes stdout,
# npm its errors to stderr, and the order of our own lines matters.
function Life-Logs {
    param([Parameter(Mandatory)][string] $Container, [string] $Since = '', [int] $Tail = 0)
    $a = @('logs')
    if ($Since) { $a += @('--since', $Since) }
    if ($Tail -gt 0) { $a += @('--tail', [string]$Tail) }
    $a += $Container
    $r = Invoke-Docker $a -TimeoutSec 120
    return [pscustomobject]@{ Out = $r.StdOut.Replace("`r", ''); Err = $r.StdErr.Replace("`r", ''); ExitCode = $r.ExitCode }
}

# ---------------------------------------------------------------------------
# Small things
# ---------------------------------------------------------------------------

# One failing test - or a harness bug in one - must not stop the rest, and
# above all not the restore; the error becomes a FAIL row saying where.
function Life-Step {
    param([Parameter(Mandatory)][string] $Id, [string[]] $Req = @(), [Parameter(Mandatory)][scriptblock] $Body)
    try { $null = & $Body }
    catch {
        $where = ''
        if ($_.InvocationInfo) { $where = ($_.InvocationInfo.PositionMessage -replace "`r?`n", ' ') }
        Life-Add -Id "$Id-HARNESS-ERROR" -Status 'FAIL' -Req $Req -Message ('harness error: {0} {1}' -f $_.Exception.Message, $where)
    }
}

# Add-Result with the message redacted: a project name or a path can come
# from .env, and summary.md is scanned for .env values at the end.
function Life-Add {
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

function Life-Opt {
    param([Parameter(Mandatory)][string] $Name)
    $o = (Get-Harness).Options
    return [bool]($o -and $o.ContainsKey($Name) -and $o[$Name])
}

# Progress, not a verdict.
function Life-Say {
    param([string] $Text)
    Write-Host "    $Text" -ForegroundColor DarkGray
}

function Life-Sha {
    param([Parameter(Mandatory)][string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 'ABSENT' }
    return (Get-Sha256Hex ([System.IO.File]::ReadAllBytes($Path)))
}

function Life-Short {
    param([AllowNull()][AllowEmptyString()][string] $Hash)
    if (-not $Hash) { return '(none)' }
    if ($Hash.Length -le 12) { return $Hash }
    return $Hash.Substring(0, 12)
}

function Life-Clip {
    param([AllowNull()][AllowEmptyString()][string] $Text, [int] $Max = 200)
    if (-not $Text) { return '' }
    if ($Text.Length -le $Max) { return $Text }
    return $Text.Substring(0, $Max) + '...'
}

function Life-FirstLine {
    param([AllowNull()][AllowEmptyString()][string] $Text)
    $l = @(($Text -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -First 1)
    if ($l.Count -eq 0) { return '(no output)' }
    return (Life-Clip $l[0].Trim() 200)
}

# compose prints progress first and the reason last.
function Life-LastLine {
    param([AllowNull()][AllowEmptyString()][string] $Text)
    $l = @(($Text -split "`r?`n") | Where-Object { $_.Trim() })
    if ($l.Count -eq 0) { return '(no output)' }
    return (Life-Clip $l[$l.Count - 1].Trim() 200)
}
