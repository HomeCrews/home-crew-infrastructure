# Suite F, "stack": the live dev stack - the one you actually use - started by
# the real launcher, then looked at from the host and from inside the
# containers. Dot-sourced by test/run.ps1 after Harness.ps1; the entry point is
# Invoke-SuiteStack, and every helper here is named Stack-*.
#
# Requirements covered: the Maven volume is one external volume, shared by all
# twelve (R1, R5); the services find one another by compose name and never by
# localhost (R2); the debug ports belong to the application JVMs and are
# reachable from this machine only (R11); and once up, nothing rebuilds or
# restarts on its own (R4).
#
# WHY THE REAL LAUNCHER. `docker compose up` would start the same containers,
# but the question is whether YOUR entry point does: on Windows that is
# .\dev.ps1, run here with the pwsh that runs this harness; elsewhere sh ./dev.
# A stack that is already fully running is not restarted - it is what you are
# using, and a restart would prove less about it, not more.
#
# WHY "READY" IS TWO THINGS. `up --wait` returns once compose's healthchecks
# pass, and ten of the twelve have none: they are still compiling behind it.
# So each service must have logged "[dev-reload] app-ready" AFTER its last
# "app-started" (dev-reload.sh's own readiness gate), AND its port must answer
# from the host on 127.0.0.1 - the log line alone would pass with a port that
# was never published. Any HTTP status counts there; UP is checked later.
#
# WHY PROBES ARE COPIED IN. The live containers mount no /test (only the test
# project does), and nothing may be written into your checkouts. So lib.sh,
# stack-probe.sh and KafkaProbe.java are docker cp'd into each container's
# /tmp/hc-stack - the container's own filesystem, gone when it is recreated -
# and removed again at the end.
#
# NOTHING HERE STOPS THE STACK. The reload and lifecycle suites run against it
# next, and you probably want it afterwards. Nothing here reads .env either
# (compose does, for `docker compose port`, as it does for every command): the
# one check that needs credentials (F-NET-06, the configuration config-server
# actually serves) takes them from the container's own environment, inside the
# container, so they never pass through this process's command lines or the
# evidence.
#
# Results, in the order they run:
#
#   F-JDWP-05-attach/-readme/-banners   committed IDE configs and port tables
#   F-UP-01                             the launcher, when the stack was not up
#   F-READY-<svc>                       app-ready logged, port answering
#   F-VOL-01-volume, F-VOL-01-<svc>     one external Maven volume at /root/.m2
#   F-JDWP-01-<svc>, F-VOL-03-<svc>     from stack-probe.sh, inside each one
#   F-VOL-02                            the same dev:inode in all twelve
#   F-NET-01-<svc> .. F-NET-06-<svc>    Eureka, gateway, health, config, Kafka
#   F-JDWP-02-<svc>, -03-*, -04-<port>  the debug ports from the host
#   F-IDLE-<svc>                        120s with nothing rebuilt or restarted
#
# Evidence: test/results/<run>/stack/ - events.log has every HTTP call and TCP
# probe made from here, which commands.log (native commands only) does not.
#
# ASCII only, and nothing newer than Windows PowerShell 5.1 can parse: suite A
# parses every .ps1 here with 5.1.

# The whole wait: launcher plus every service ready. A cold start - empty Maven
# volume, twelve builds - takes most of it on a laptop.
$script:StackBudgetSec = 2700
$script:StackPollSec = 10
# A service whose last dev-reload event is a failure it waits in, and that has
# said nothing new for this long, is not going to become ready by itself.
$script:StackQuietGiveUpSec = 300
# "app-ready" in the log but no answer on 127.0.0.1 for this long: the port
# is not published, or something else holds it.
$script:StackHttpGiveUpSec = 120
$script:StackSettleSec = 30
$script:StackIdleSec = 120
# Eureka's registry, the gateway's load-balancer cache and the health
# indicators all lag a fresh start by up to half a minute; checks that depend
# on them retry for this long before judging.
$script:StackRetrySec = 90
$script:StackProbeDir = '/tmp/hc-stack'
$script:StackEvents = $null
$script:StackHttpClient = $null
$script:StackJsonReady = $false

# The gateway's routes (home-crew-api-gateway application.properties), and the
# service each one is load-balanced to.
$script:StackRoutes = [ordered]@{
    '/users' = 'user-service'; '/auth' = 'auth-service'; '/admin' = 'admin-service'
    '/bookings' = 'booking-service'; '/workers' = 'worker-service'; '/notifications' = 'notification-service'
    '/payments' = 'payment-service'; '/xp' = 'xp-service'; '/assignments' = 'assignment-service'
}

# Every port the dev stack publishes on the host.
$script:StackHostPorts = @(5005..5016) + @(8080..8089) + @(8761, 8888, 5432, 9092, 4200)

# dev-reload.sh events after which it waits for you (a fix and a save) rather
# than trying again by itself.
$script:StackTerminalEvents = @(
    'build-failed', 'compile-failed', 'build-broken', 'launch-refused', 'restart-exhausted',
    'restart-deferred', 'main-class-error', 'classpath-error', 'fatal', 'reload-failed'
)

# A line in the idle window that means something rebuilt, reloaded or
# restarted. The six events the contract names, plus the ones that announce a
# change was noticed at all, plus the Spring and DevTools markers.
$script:StackIdleRe = '\[dev-reload\] (build-start|compile-start|app-started|app-exited|restart-scheduled|boot-timeout|source-changed|build-changed|build-pending|trigger-touched|app-stopped|app-killed):|Restarting due to|Started .+ in [0-9]'

function Invoke-SuiteStack {
    Enter-Suite 'stack' 'the live dev stack: Maven volume, network, debug ports, idle'
    $h = Get-Harness
    $allReq = @('R1', 'R2', 'R4', 'R5', 'R11')
    $script:StackEvents = Join-Path (Get-EvidenceDir 'stack') 'events.log'
    Stack-Note "suite stack, run $($h.RunId)"

    # What the committed files say about the debug ports: needs neither docker
    # nor a running stack, so it runs first and always.
    Stack-Step 'F-JDWP-05-attach' @('R11') { Stack-CheckAttachConfigs } | Out-Null
    Stack-Step 'F-JDWP-05-tables' @('R11') { Stack-CheckDebugTables } | Out-Null

    if (-not (Test-DockerAvailable)) {
        Add-Result -Id 'F-STACK' -Status 'SKIP' -Req $allReq -Message "docker is not available here (not on PATH, or 'docker info' fails): everything else in this suite looks at the running stack"
        return
    }

    $up = Stack-Step 'F-UP' @('R1', 'R4') { Stack-EnsureUp }
    if ($null -eq $up -or -not $up.Continue) { return }

    $ready = Stack-Step 'F-READY' @('R4') { Stack-WaitReady -Deadline $up.Deadline }
    if ($null -eq $ready) { return }

    $stage = Stack-Step 'F-PROBE' $allReq { Stack-StageProbe }
    $copied = Stack-Step 'F-PROBE' $allReq { Stack-CopyProbes -Stage $stage -Ready $ready }
    if ($null -eq $copied) { $copied = @{} }

    Stack-Step 'F-VOL-01' @('R1', 'R5') { Stack-CheckMounts -Ready $ready } | Out-Null
    Stack-Step 'F-VOL-02' @('R5', 'R11') { Stack-RunProbes -Ready $ready -Copied $copied } | Out-Null
    Stack-Step 'F-NET-01' @('R2') { Stack-CheckEureka -Ready $ready } | Out-Null
    Stack-Step 'F-NET-02' @('R2') { Stack-CheckGateway -Ready $ready } | Out-Null
    Stack-Step 'F-NET-03' @('R2') { Stack-CheckHealth -Ready $ready } | Out-Null
    Stack-Step 'F-NET-04' @('R2') { Stack-CheckLocatedEnvironment -Ready $ready } | Out-Null
    Stack-Step 'F-NET-05' @('R2') { Stack-CheckKafka -Ready $ready -Copied $copied } | Out-Null
    Stack-Step 'F-NET-06' @('R2') { Stack-CheckServedConfig -Ready $ready } | Out-Null
    Stack-Step 'F-JDWP-02' @('R11') { Stack-CheckHandshakes -Ready $ready -Copied $copied } | Out-Null
    Stack-Step 'F-JDWP-03-listeners' @('R11') { Stack-CheckListeners } | Out-Null
    Stack-Step 'F-JDWP-03-compose' @('R11') { Stack-CheckComposePorts } | Out-Null
    Stack-Step 'F-JDWP-04' @('R11') { Stack-CheckLan } | Out-Null
    # Last: nothing above restarts anything, but it all makes noise in the
    # logs, and the window must start well after the last service came up.
    Stack-Step 'F-IDLE' @('R4') { Stack-CheckIdle -Ready $ready } | Out-Null
    Stack-Step 'F-PROBE' $allReq { Stack-RemoveProbes -Copied $copied } | Out-Null

    Add-Result -Id 'F-STACK-LEFT' -Status 'INFO' -Req @('R4') -Message 'the live stack is left running - the reload and lifecycle suites need it. Stop it with .\dev.ps1 down (./dev down)'
}

# ---------------------------------------------------------------------------
# Plumbing
# ---------------------------------------------------------------------------

# One check that throws must not take the rest of the suite with it: it
# becomes a FAIL that says so, and the next check runs. The parameter names are
# deliberately unlike anything a check's script block reads from its caller.
function Stack-Step {
    param([string] $StepId, [string[]] $StepReq, [scriptblock] $StepBody)
    try { return (& $StepBody) }
    catch {
        $where = ($_.InvocationInfo.PositionMessage -replace "`r?`n", ' ')
        Add-Result -Id "$StepId-HARNESS-ERROR" -Status 'FAIL' -Req $StepReq -Message ("harness error: {0} at {1}" -f $_.Exception.Message, $where)
        return $null
    }
}

# A timestamped line in stack/events.log: HTTP calls and the other things that
# are not native commands (and so are not in commands.log).
function Stack-Note {
    param([string] $Line)
    if (-not $script:StackEvents) { return }
    $text = (Get-Date -Format 'HH:mm:ss') + '  ' + (Protect-Text $Line) + "`n"
    [System.IO.File]::AppendAllText($script:StackEvents, $text, [System.Text.UTF8Encoding]::new($false))
}

function Stack-Ctr { param([object] $Svc) return ($script:LiveContainerPrefix + $Svc.Name) }

function Stack-Cut {
    param([AllowEmptyString()][string] $Text, [int] $Max = 300)
    if (-not $Text) { return '' }
    $t = ($Text -replace "[`r`n`t]+", ' ').Trim()
    if ($t.Length -gt $Max) { return $t.Substring(0, $Max) + '...' }
    return $t
}

function Stack-FirstLine {
    param([AllowEmptyString()][string] $Text)
    foreach ($l in (([string]$Text) -split "`r?`n")) { if ($l.Trim()) { return (Stack-Cut $l 300) } }
    return ''
}

# The line that explains a failure. compose prints its progress on stderr, so
# the first line of a failed `up` is "Network homecrew Creating" and the cause
# comes last; the launchers' own refusals come first, in words like these.
function Stack-ErrorLine {
    param([AllowEmptyString()][string] $Text)
    $lines = @((([string]$Text) -split "`r?`n") | Where-Object { $_.Trim() })
    if ($lines.Count -eq 0) { return '' }
    $hits = @($lines | Where-Object { $_ -match '(?i)\b(error|failed|unhealthy|refused|denied|missing|not responding|required|cannot|could not|no such)\b' })
    if ($hits.Count) { return (Stack-Cut $hits[$hits.Count - 1] 300) }
    return (Stack-Cut $lines[$lines.Count - 1] 300)
}

# The useful part of an exception chain. PowerShell wraps every .NET call's
# exception in "Exception calling X with N argument(s)", which says nothing.
function Stack-ExMessage {
    param([object] $Ex)
    $parts = [System.Collections.Generic.List[string]]::new()
    $e = $Ex
    $n = 0
    while ($null -ne $e -and $n -lt 8) {
        $m = [string]$e.Message
        if ($m -and -not ($e -is [System.Management.Automation.MethodInvocationException]) -and -not $parts.Contains($m)) { $parts.Add($m) }
        $e = $e.InnerException
        $n++
    }
    if ($parts.Count -eq 0 -and $null -ne $Ex) { $parts.Add([string]$Ex.Message) }
    return (Stack-Cut ($parts -join ' <- ') 400)
}

function Stack-EvidenceText {
    param([object] $R)
    $b = [System.Collections.Generic.List[string]]::new()
    $b.Add("# $($R.CommandLine)")
    $b.Add("# exit $($R.ExitCode)$(if ($R.TimedOut) { ' - TIMED OUT' } else { '' })")
    $b.Add([string]$R.StdOut)
    if ($R.StdErr) { $b.Add('# ---- stderr ----'); $b.Add([string]$R.StdErr) }
    return ($b -join "`n")
}

function Stack-Exec {
    param([string] $Container, [string[]] $Command, [int] $TimeoutSec = 60)
    # -w /tmp: nothing a probe does may land in /app, which is your checkout.
    return Invoke-Docker -DockerArgs (@('exec', '-w', '/tmp', $Container) + $Command) -TimeoutSec $TimeoutSec
}

function Stack-ReqFor {
    param([string] $Id)
    switch -Regex ($Id) {
        '^F-VOL-01' { return @('R1', 'R5') }
        '^F-VOL-'   { return @('R5') }
        '^F-NET-'   { return @('R2') }
        '^F-JDWP-'  { return @('R11') }
        '^F-IDLE'   { return @('R4') }
        '^F-READY'  { return @('R4') }
        '^F-UP'     { return @('R1', 'R4') }
    }
    return @('R1', 'R2', 'R4', 'R5', 'R11')
}

# A failure in a service that never came up says little about the check
# itself; the message points at the reason.
function Stack-NotReadyNote {
    param([object] $Ready, [object] $Svc)
    if ($null -eq $Ready) { return '' }
    if ($Ready.States.Contains($Svc.Name) -and -not $Ready.States[$Svc.Name].Ok) {
        return " (this service never became ready - see F-READY-$($Svc.Name))"
    }
    return ''
}

# HCRESULT lines from stack-probe.sh to results, each with the requirements of
# its own id. A malformed line becomes a FAIL that says so rather than a
# harness error. Returns the ids reported, so the caller can tell a check the
# probe never reached from one that passed.
function Stack-ImportLines {
    param([AllowEmptyString()][string] $Text, [string[]] $Evidence = @(), [string] $FailNote = '')
    $valid = @('PASS', 'FAIL', 'SKIP', 'BLOCKED', 'WARN', 'INFO', 'WEAK')
    $ids = [System.Collections.Generic.List[string]]::new()
    foreach ($line in (([string]$Text) -split "`r?`n")) {
        if (-not $line.StartsWith("HCRESULT`t")) { continue }
        $c = $line -split "`t", 4
        if ($c.Count -lt 4) { continue }
        $id = $c[1].Trim()
        if (-not $id) { continue }
        $status = $c[2].Trim().ToUpperInvariant()
        $msg = $c[3]
        if ($valid -notcontains $status) { $msg = "the probe reported an unknown status '$($c[2])': $msg"; $status = 'FAIL' }
        if (-not $msg.Trim()) { $msg = '(the probe gave no message)' }
        if ($status -eq 'FAIL' -and $FailNote) { $msg += $FailNote }
        Add-Result -Id $id -Status $status -Req (Stack-ReqFor $id) -Message $msg -Evidence $Evidence
        $ids.Add($id)
    }
    return , $ids.ToArray()
}

# STACKPROBE<TAB>key=value<TAB>... lines, as one hashtable.
function Stack-ProbeFacts {
    param([AllowEmptyString()][string] $Text)
    $kv = @{}
    foreach ($line in (([string]$Text) -split "`r?`n")) {
        if (-not $line.StartsWith("STACKPROBE`t")) { continue }
        $pairs = $line.Split("`t")
        for ($i = 1; $i -lt $pairs.Count; $i++) {
            $eq = $pairs[$i].IndexOf('=')
            if ($eq -gt 0) { $kv[$pairs[$i].Substring(0, $eq)] = $pairs[$i].Substring($eq + 1) }
        }
    }
    return $kv
}

# ---------------------------------------------------------------------------
# JSON, case-sensitively
# ---------------------------------------------------------------------------
#
# Not ConvertFrom-Json: Eureka writes both "overriddenStatus" and the legacy
# "overriddenstatus" in every instance, and a PSObject cannot hold two
# properties that differ only in case. System.Text.Json reads it as it is;
# objects become ordinal Dictionary[string,object], arrays object[].

function Stack-FromJson {
    param([AllowEmptyString()][string] $Text)
    if (-not $Text -or -not $Text.Trim()) { return $null }
    if (-not $script:StackJsonReady) {
        try { Add-Type -AssemblyName 'System.Text.Json' -ErrorAction Stop } catch { }
        # Loud, not $null: every JSON check would otherwise read as "the
        # service answered garbage".
        if (-not ('System.Text.Json.JsonDocument' -as [type])) { throw 'System.Text.Json is not available in this PowerShell' }
        $script:StackJsonReady = $true
    }
    $doc = $null
    try { $doc = [System.Text.Json.JsonDocument]::Parse($Text) }
    catch { return $null }
    try { $v = Stack-JsonValue $doc.RootElement; return , $v }
    finally { $doc.Dispose() }
}

function Stack-JsonValue {
    param([object] $E)
    $kind = [string]$E.ValueKind
    if ($kind -eq 'Object') {
        $d = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
        foreach ($p in $E.EnumerateObject()) { $v = Stack-JsonValue $p.Value; $d[$p.Name] = $v }
        return , $d
    }
    if ($kind -eq 'Array') {
        $l = [System.Collections.Generic.List[object]]::new()
        foreach ($x in $E.EnumerateArray()) { $v = Stack-JsonValue $x; $l.Add($v) }
        return , $l.ToArray()
    }
    if ($kind -eq 'String') { return $E.GetString() }
    if ($kind -eq 'Number') { return $E.GetDouble() }
    if ($kind -eq 'True') { return $true }
    if ($kind -eq 'False') { return $false }
    return $null
}

# $Obj[k1][k2]..., or $null as soon as a step is missing or not an object.
function Stack-Get {
    param([object] $Obj, [string[]] $Path)
    $cur = $Obj
    foreach ($k in $Path) {
        if ($null -eq $cur -or -not ($cur -is [System.Collections.IDictionary]) -or -not $cur.ContainsKey($k)) { return $null }
        $cur = $cur[$k]
    }
    return , $cur
}

# Always an array: $null is empty, one object is one element.
function Stack-List {
    param([object] $V)
    if ($null -eq $V) { return , @() }
    if ($V -is [System.Array]) { return , $V }
    $a = [object[]]::new(1)
    $a[0] = $V
    return , $a
}

# ---------------------------------------------------------------------------
# HTTP and TCP from the host
# ---------------------------------------------------------------------------

# One client for the whole suite. No proxy: a corporate proxy setting must not
# decide whether 127.0.0.1 is reachable. No redirects: a 302 is an answer.
function Stack-Http {
    param([Parameter(Mandatory)][string] $Url, [string] $Accept = '', [int] $TimeoutSec = 15)
    if ($null -eq $script:StackHttpClient) {
        try { Add-Type -AssemblyName 'System.Net.Http' -ErrorAction Stop } catch { }
        $handler = [System.Net.Http.SocketsHttpHandler]::new()
        $handler.UseProxy = $false
        $handler.AllowAutoRedirect = $false
        $handler.ConnectTimeout = [TimeSpan]::FromSeconds(5)
        $client = [System.Net.Http.HttpClient]::new($handler)
        $client.Timeout = [System.Threading.Timeout]::InfiniteTimeSpan
        $script:StackHttpClient = $client
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $code = 0
    $body = ''
    $err = ''
    $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $Url)
    if ($Accept) { [void]$req.Headers.TryAddWithoutValidation('Accept', $Accept) }
    $cts = [System.Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($TimeoutSec))
    try {
        $resp = $script:StackHttpClient.SendAsync($req, $cts.Token).GetAwaiter().GetResult()
        try {
            $code = [int]$resp.StatusCode
            $body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        }
        finally { $resp.Dispose() }
    }
    catch {
        $err = Stack-ExMessage $_.Exception
        if ($cts.IsCancellationRequested) { $err = "no answer within ${TimeoutSec}s" }
    }
    finally {
        $req.Dispose()
        $cts.Dispose()
    }
    Stack-Note ("GET {0} -> {1} in {2}ms{3}" -f $Url, $code, $sw.ElapsedMilliseconds, $(if ($err) { " ($err)" } else { '' }))
    return [pscustomobject]@{ Url = $Url; Code = $code; Body = $body; Error = $err; Ms = $sw.ElapsedMilliseconds }
}

function Stack-TcpConnect {
    param([string] $Address, [int] $Port, [int] $TimeoutMs = 2000)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $t = $client.ConnectAsync($Address, $Port)
        $done = $false
        try { $done = $t.Wait($TimeoutMs) }
        catch { return [pscustomobject]@{ Connected = $false; How = "refused ($(Stack-ExMessage $_.Exception))"; Ms = $sw.ElapsedMilliseconds } }
        if (-not $done) { return [pscustomobject]@{ Connected = $false; How = "no answer within $($TimeoutMs)ms"; Ms = $sw.ElapsedMilliseconds } }
        return [pscustomobject]@{ Connected = [bool]$client.Connected; How = 'connected'; Ms = $sw.ElapsedMilliseconds }
    }
    finally { $client.Dispose() }
}

# A real JDWP handshake, not a connect: Docker Desktop's port forwarder
# accepts every connection on a published port whether or not anything
# listens behind it, so only the agent echoing the 14 bytes back proves the
# debugger would attach.
function Stack-JdwpHandshake {
    param([string] $Address, [int] $Port)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $t = $client.ConnectAsync($Address, $Port)
        $done = $false
        try { $done = $t.Wait(3000) }
        catch { return [pscustomobject]@{ Ok = $false; Detail = "connect failed: $(Stack-ExMessage $_.Exception)"; Ms = $sw.ElapsedMilliseconds } }
        if (-not $done) { return [pscustomobject]@{ Ok = $false; Detail = 'connect timed out after 3s'; Ms = $sw.ElapsedMilliseconds } }
        $s = $client.GetStream()
        $s.ReadTimeout = 5000
        $s.WriteTimeout = 5000
        $hs = [System.Text.Encoding]::ASCII.GetBytes('JDWP-Handshake')
        $buf = [byte[]]::new(14)
        $n = 0
        try {
            $s.Write($hs, 0, $hs.Length)
            $s.Flush()
            while ($n -lt 14) {
                $k = $s.Read($buf, $n, 14 - $n)
                if ($k -le 0) { break }
                $n += $k
            }
        }
        catch { return [pscustomobject]@{ Ok = $false; Detail = "connected, but no reply to the handshake: $(Stack-ExMessage $_.Exception)"; Ms = $sw.ElapsedMilliseconds } }
        $got = [System.Text.Encoding]::ASCII.GetString($buf, 0, $n)
        if ($n -eq 14 -and $got -eq 'JDWP-Handshake') { return [pscustomobject]@{ Ok = $true; Detail = 'JDWP-Handshake echoed'; Ms = $sw.ElapsedMilliseconds } }
        $shown = ($got -replace '[^\x20-\x7E]', '.')
        return [pscustomobject]@{ Ok = $false; Detail = "connected, but read $n byte(s) back ('$shown') instead of the 14-byte JDWP-Handshake: the port is forwarded, and no JDWP agent answered behind it"; Ms = $sw.ElapsedMilliseconds }
    }
    catch { return [pscustomobject]@{ Ok = $false; Detail = (Stack-ExMessage $_.Exception); Ms = $sw.ElapsedMilliseconds } }
    finally { $client.Dispose() }
}

# curl from inside a container: http://<service>:<port> by compose name, the
# way the services reach one another. With -Auth the credentials are the
# container's own CONFIG_CLIENT_* variables, expanded by sh INSIDE the
# container - they never appear in a command line this harness logs.
function Stack-CurlIn {
    param([string] $Container, [string] $Url, [int] $TimeoutSec = 15, [switch] $Auth)
    if ($Auth) {
        $sc = 'curl -s -S -m "$2" -w "\nHCHTTP %{http_code}\n" -u "${CONFIG_CLIENT_USERNAME:-}:${CONFIG_CLIENT_PASSWORD:-}" "$1"'
        $cmd = @('sh', '-c', $sc, 'hc', $Url, "$TimeoutSec")
    }
    else {
        $cmd = @('curl', '-s', '-S', '-m', "$TimeoutSec", '-w', '\nHCHTTP %{http_code}\n', $Url)
    }
    $r = Stack-Exec -Container $Container -Command $cmd -TimeoutSec ($TimeoutSec + 30)
    $out = [string]$r.StdOut
    $code = 0
    $body = $out
    $i = $out.LastIndexOf('HCHTTP ')
    if ($i -ge 0) {
        $body = $out.Substring(0, $i).TrimEnd("`r", "`n")
        $m = [regex]::Match($out.Substring($i), '^HCHTTP (\d{3})')
        if ($m.Success) { $code = [int]$m.Groups[1].Value }
    }
    $err = ''
    if ($code -eq 0) { $err = Stack-FirstLine ([string]$r.StdErr + "`n" + $out) }
    Stack-Note ("in {0}: GET {1} -> {2}{3}" -f $Container, $Url, $code, $(if ($err) { " ($err)" } else { '' }))
    return [pscustomobject]@{ Code = $code; Body = $body; Error = $err }
}

function Stack-HealthStatus {
    param([AllowEmptyString()][string] $Body)
    $j = Stack-FromJson $Body
    $s = Stack-Get $j @('status')
    if ($s -is [string]) { return $s }
    return ''
}

# "HTTP 503, status DOWN (not UP: db=DOWN)" or "no answer (...)".
function Stack-DescribeHealth {
    param([int] $Code, [string] $Status, [string] $Err, [AllowEmptyString()][string] $Body)
    if ($Code -eq 0) { return "no answer ($Err)" }
    $down = @()
    $comps = Stack-Get (Stack-FromJson $Body) @('components')
    if ($comps -is [System.Collections.IDictionary]) {
        foreach ($k in @($comps.Keys)) {
            $cs = Stack-Get $comps @($k, 'status')
            if ($cs -and $cs -ne 'UP') { $down += "$k=$cs" }
        }
    }
    $s = if ($Status) { "status $Status" } else { 'no health status in the answer' }
    if ($down.Count) { return "HTTP $Code, $s (not UP: $($down -join ', '))" }
    return "HTTP $Code, $s"
}

# ---------------------------------------------------------------------------
# F-UP: the stack, started by the real launcher if it is not running
# ---------------------------------------------------------------------------

# Every homecrew-* container's state (running, exited, created, restarting,
# ...), leaving out the isolated test project's.
function Stack-ContainerStates {
    $r = Invoke-Docker @('ps', '-a', '--format', '{{.Names}}|{{.State}}') -TimeoutSec 60
    $map = @{}
    foreach ($l in (([string]$r.StdOut) -split "`r?`n")) {
        $c = $l.Trim() -split '\|', 2
        if ($c.Count -lt 2) { continue }
        if ($c[0] -notlike "$($script:LiveContainerPrefix)*" -or $c[0] -like "$($script:TestProject)*") { continue }
        $map[$c[0]] = $c[1].Trim().ToLowerInvariant()
    }
    return $map
}

# The first line that looks like the internet failing - an image pull, apt-get,
# Maven Central, a clone from GitHub - rather than the stack. Names inside the
# compose network have no dots, so an unresolvable dotted name is outside it.
function Stack-NetworkLine {
    param([AllowEmptyString()][string] $Text)
    $re = '(?im)^.*(Could not transfer artifact|Could not resolve host|Temporary failure in name resolution|Network is unreachable|failed to resolve source metadata|TLS handshake timeout|toomanyrequests|dial tcp [^\r\n]*(i/o timeout|no such host|connection refused)|Failed to fetch https?://|UnknownHostException: [A-Za-z0-9-]+\.[A-Za-z0-9.-]+).*$'
    $m = [regex]::Match([string]$Text, $re)
    if ($m.Success) { return (Stack-Cut $m.Value 200) }
    return ''
}

function Stack-EnsureUp {
    $h = Get-Harness
    $deadline = [DateTime]::UtcNow.AddSeconds($script:StackBudgetSec)
    $names = @('postgres', 'kafka') + @(Get-JavaServices | ForEach-Object { $_.Name }) + @('webapp')
    $want = @($names | ForEach-Object { $script:LiveContainerPrefix + $_ })
    $before = Stack-ContainerStates
    $missing = @($want | Where-Object { -not ($before.ContainsKey($_) -and $before[$_] -eq 'running') })
    if ($missing.Count -eq 0) {
        Add-Result -Id 'F-UP-01' -Status 'INFO' -Req @('R1', 'R4') -Message "the live stack was already running (all $($want.Count) containers), so it was not started again"
        return [pscustomobject]@{ Continue = $true; Deadline = $deadline; Ran = $false }
    }

    # config-server cannot clone the private home-crew-config or decrypt
    # anything without .env, and nothing starts without config-server.
    if (-not (Test-Path -LiteralPath (Join-Path $h.InfraRoot '.env') -PathType Leaf)) {
        Add-Result -Id 'F-UP-01' -Status 'SKIP' -Req @('R1', 'R4') -Message ".env is missing, so the live stack cannot be started (not running: $($missing -join ', ')): copy .env.example to .env and fill in CONFIG_GIT_USERNAME and CONFIG_GIT_TOKEN"
        return [pscustomobject]@{ Continue = $false; Deadline = $deadline; Ran = $false }
    }
    # Twelve JVMs and, during a cold start, up to twelve Maven daemons beside
    # them. Below 6 GB that does not fit; below 10 GB it may, slowly.
    $tight = Test-DockerMemory -NeedBytes 6GB
    if ($tight) {
        Add-Result -Id 'F-UP-01' -Status 'BLOCKED' -Req @('R1', 'R4') -Message "not starting the live stack: $tight"
        return [pscustomobject]@{ Continue = $false; Deadline = $deadline; Ran = $false }
    }
    $small = Test-DockerMemory -NeedBytes 10GB
    if ($small) { Add-Result -Id 'F-UP-memory' -Status 'WARN' -Req @('R4') -Message "starting anyway, but a cold start may be slow or OOM: $small" }

    if ($h.OnWindows) {
        # The pwsh running this harness, so the launcher runs under the same
        # PowerShell. -ExecutionPolicy Bypass for this one process, as the
        # README tells you to start the harness itself: a machine policy of
        # Restricted is not what this check is about.
        $exe = [System.Environment]::ProcessPath
        if (-not $exe) { $exe = (Get-Process -Id $PID).Path }
        $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $h.InfraRoot 'dev.ps1'), 'up')
        $label = '.\dev.ps1 up'
    }
    else {
        $sh = Get-Command sh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $sh) {
            Add-Result -Id 'F-UP-01' -Status 'SKIP' -Req @('R1', 'R4') -Message 'no sh on PATH to run ./dev with'
            return [pscustomobject]@{ Continue = $false; Deadline = $deadline; Ran = $false }
        }
        $exe = $sh.Source
        $argv = @('./dev', 'up')
        $label = 'sh ./dev up'
    }
    Write-Host "  starting the live stack with $label (not running: $($missing.Count) of $($want.Count)); a first start takes many minutes..." -ForegroundColor DarkGray
    $left = [int][Math]::Max(60, ($deadline - [DateTime]::UtcNow).TotalSeconds)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-Native -FilePath $exe -ArgumentList $argv -WorkingDirectory $h.InfraRoot -TimeoutSec $left
    $secs = [int]$sw.Elapsed.TotalSeconds
    $ev = Save-Evidence -Suite 'stack' -Name 'launcher-up.log' -Content (Stack-EvidenceText $r)
    $text = [string]$r.StdOut + "`n" + [string]$r.StdErr
    if ($r.ExitCode -eq 0) {
        Add-Result -Id 'F-UP-01' -Status 'PASS' -Req @('R1', 'R4') -Evidence @($ev) -Message "$label exited 0 after ${secs}s: compose started every container and its healthchecks passed (--wait). Not running before: $($missing -join ', ')"
    }
    elseif ($r.TimedOut) {
        Add-Result -Id 'F-UP-01' -Status 'FAIL' -Req @('R1', 'R4') -Evidence @($ev) -Message "$label did not return within ${left}s and was stopped; the containers it started keep running"
    }
    elseif ($r.ExitCode -eq -2) {
        Add-Result -Id 'F-UP-01' -Status 'BLOCKED' -Req @('R1', 'R4') -Evidence @($ev) -Message "$label could not be started at all: $(Stack-FirstLine $r.StdErr)"
    }
    else {
        $net = Stack-NetworkLine $text
        if ($net) {
            Add-Result -Id 'F-UP-01' -Status 'BLOCKED' -Req @('R1', 'R4') -Evidence @($ev) -Message "$label exited $($r.ExitCode) on a network failure (image pull, apt-get or a download): $net"
        }
        else {
            $why = Stack-ErrorLine $text
            Add-Result -Id 'F-UP-01' -Status 'FAIL' -Req @('R1', 'R4') -Evidence @($ev) -Message "$label exited $($r.ExitCode) after ${secs}s: $why"
        }
    }
    # Whatever it managed to start is still worth looking at; nothing at all
    # is not.
    $after = Stack-ContainerStates
    $java = @(Get-JavaServices | Where-Object { $after.ContainsKey((Stack-Ctr $_)) })
    if ($java.Count -eq 0) {
        Add-Result -Id 'F-UP-02' -Status 'FAIL' -Req @('R1', 'R4') -Message "after $label no homecrew-<service> container exists, so there is nothing to check"
        return [pscustomobject]@{ Continue = $false; Deadline = $deadline; Ran = $true }
    }
    return [pscustomobject]@{ Continue = $true; Deadline = $deadline; Ran = $true }
}

# ---------------------------------------------------------------------------
# F-READY: every service ready, by its own log and from the host
# ---------------------------------------------------------------------------

# Docker's RFC3339Nano timestamps drop trailing zeros, so they do not compare
# as strings; padded to nine digits they do.
function Stack-TsKey {
    param([string] $Ts)
    $m = [regex]::Match([string]$Ts, '^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(?:\.(\d{1,9}))?Z$')
    if (-not $m.Success) { return '' }
    return $m.Groups[1].Value + '.' + $m.Groups[2].Value.PadRight(9, '0')
}

# The log since the last poll (docker logs -t --since <newest timestamp
# seen>), folded into the service's state. --since is inclusive, so a line at
# or before that timestamp was seen already and is skipped.
function Stack-ReadNewLog {
    param([object] $X)
    $a = @('logs', '-t')
    if ($X.LastTs) { $a += @('--since', $X.LastTs) }
    $a += $X.Ctr
    $r = Invoke-Docker -DockerArgs $a -TimeoutSec 120
    if ($r.ExitCode -ne 0) { return }
    $text = [string]$r.StdOut
    if (-not $text.Trim()) { return }
    $prev = $X.LastKey
    foreach ($m in [regex]::Matches($text, '(?m)^(\S+) \[dev-reload\] ([a-z-]+):([^\r\n]*)')) {
        $key = Stack-TsKey $m.Groups[1].Value
        if ($prev -and $key -and [string]::CompareOrdinal($key, $prev) -le 0) { continue }
        $ev = $m.Groups[2].Value
        # Ready means app-ready AFTER the last launch or context restart: an
        # app-ready from before the JVM was replaced says nothing about now.
        if ($ev -eq 'app-ready') { $X.LogReady = $true }
        elseif (@('app-started', 'app-exited', 'app-stopped', 'app-killed', 'trigger-touched', 'boot-timeout') -contains $ev) { $X.LogReady = $false }
        if ($ev -eq 'app-started' -or $ev -eq 'app-ready') { $X.SawStart = $true }
        if ($ev -eq 'fatal') { $X.Fatals++ }
        $X.LastEvent = $ev
        $X.LastEventLine = Stack-Cut ('[dev-reload] ' + $ev + ':' + $m.Groups[3].Value) 250
        $X.LastEventAt = [DateTime]::UtcNow
    }
    $t = $text.TrimEnd("`r", "`n")
    $nl = $t.LastIndexOf("`n")
    $last = if ($nl -ge 0) { $t.Substring($nl + 1) } else { $t }
    $ts = ($last -split ' ', 2)[0]
    $key = Stack-TsKey $ts
    if ($key -and (-not $prev -or [string]::CompareOrdinal($key, $prev) -gt 0)) {
        $X.LastKey = $key
        $X.LastTs = $ts
    }
}

function Stack-GiveUp {
    param([object] $X, [string] $Why)
    $X.Final = $true
    $X.Ok = $false
    $X.Reason = $Why
}

function Stack-PollService {
    param([object] $X, [hashtable] $States)
    $state = 'absent'
    if ($States.ContainsKey($X.Ctr)) { $state = $States[$X.Ctr] }
    $X.State = $state
    # created = compose made it and then gave up starting it (a dependency
    # never became healthy); exited or dead with a restart policy that has not
    # brought it back. Three polls of grace for a restart in flight.
    if (@('absent', 'exited', 'dead', 'created') -contains $state) {
        $X.DeadPolls++
        if ($X.DeadPolls -ge 3) { Stack-GiveUp $X "container $($X.Ctr) is $state" }
        return
    }
    $X.DeadPolls = 0
    Stack-ReadNewLog $X
    $now = [DateTime]::UtcNow
    # docker keeps 3 x 10 MB of log (the base file's json-file options), so on
    # a stack that has run for days the launch and its app-ready can have
    # scrolled out. No app-started or app-ready anywhere in the log, and yet
    # an answer on the port, is that case: the application IS up, and only
    # the proof in the log is gone. Before the first launch the port does not
    # answer, so this cannot fire during a start.
    if (-not $X.LogReady -and -not $X.SawStart) {
        $r = Stack-Http ("http://127.0.0.1:{0}/actuator/health" -f $X.Svc.Port) -TimeoutSec 15
        if ($r.Code -gt 0) {
            $X.Final = $true
            $X.Ok = $true
            $X.Rotated = $true
            $X.HttpCode = $r.Code
            $X.ReadyAt = $now
            return
        }
    }
    if ($X.LogReady) {
        $r = Stack-Http ("http://127.0.0.1:{0}/actuator/health" -f $X.Svc.Port) -TimeoutSec 15
        if ($r.Code -gt 0) {
            $X.Final = $true
            $X.Ok = $true
            $X.HttpCode = $r.Code
            $X.ReadyAt = $now
            return
        }
        if ($null -eq $X.HttpFailSince) { $X.HttpFailSince = $now }
        elseif (($now - $X.HttpFailSince).TotalSeconds -ge $script:StackHttpGiveUpSec) {
            Stack-GiveUp $X ("its log says app-ready, but 127.0.0.1:{0} has not answered for {1}s ({2}): the port is not published to the host, or something else holds it" -f $X.Svc.Port, $script:StackHttpGiveUpSec, $r.Error)
        }
        return
    }
    $X.HttpFailSince = $null
    if ($X.Fatals -ge 3) {
        Stack-GiveUp $X "dev-reload.sh stopped with a fatal error $($X.Fatals) times, and compose keeps restarting it into the same one"
        return
    }
    if ($script:StackTerminalEvents -contains $X.LastEvent -and ($now - $X.LastEventAt).TotalSeconds -ge $script:StackQuietGiveUpSec) {
        Stack-GiveUp $X ("nothing new for {0}s after a failure dev-reload.sh waits in for a fix" -f $script:StackQuietGiveUpSec)
    }
}

# Why a service that did not come up is an environment limit rather than a
# fault: out of memory, no network, or credentials .env did not provide.
# Returns '' when it is none of those.
function Stack-ClassifyFailure {
    param([string] $Container, [AllowEmptyString()][string] $Text)
    $i = Invoke-Docker @('inspect', '-f', '{{.State.OOMKilled}}', $Container) -TimeoutSec 60
    if ($i.ExitCode -eq 0 -and $i.StdOut.Trim() -eq 'true') {
        return 'BLOCKED (memory): the container was OOM-killed - raise DEV_SERVICE_MEM, or the Docker VM (on Windows [wsl2] memory= in %UserProfile%\.wslconfig)'
    }
    # 137 = SIGKILL; dev-reload.sh logs app-killed when it is the one sending it.
    if ($Text -match '\[dev-reload\] app-exited: pid \d+, status 137' -and $Text -notmatch '\[dev-reload\] app-killed:') {
        return 'BLOCKED (memory): the application was SIGKILLed (status 137) by something other than dev-reload.sh, which inside a 1g container is almost always the kernel OOM killer'
    }
    $net = Stack-NetworkLine $Text
    if ($net) { return "BLOCKED (network): $net" }
    $m = [regex]::Match([string]$Text, '(?im)^.*(Authentication is required|not authorized|Authentication failed for|git-upload-pack not permitted|could not read Username).*$')
    if ($m.Success) { return "BLOCKED (credentials): $(Stack-Cut $m.Value 200) - check CONFIG_GIT_USERNAME and CONFIG_GIT_TOKEN in .env" }
    return ''
}

function Stack-WaitReady {
    param([DateTime] $Deadline)
    $st = [ordered]@{}
    foreach ($s in Get-JavaServices) {
        $st[$s.Name] = [pscustomobject]@{
            Svc = $s; Ctr = (Stack-Ctr $s); LastKey = ''; LastTs = ''
            LogReady = $false; SawStart = $false; Rotated = $false; LastEvent = ''; LastEventLine = ''; LastEventAt = [DateTime]::UtcNow; Fatals = 0
            HttpFailSince = $null; DeadPolls = 0; State = ''
            Final = $false; Ok = $false; Reason = ''; ReadyAt = $null; HttpCode = 0
        }
    }
    $started = [DateTime]::UtcNow
    $nextProgress = $started.AddSeconds(60)
    Write-Host ("  waiting for each service to log [dev-reload] app-ready and answer on 127.0.0.1 (at most {0} min)..." -f [int][Math]::Ceiling(($Deadline - $started).TotalMinutes)) -ForegroundColor DarkGray
    while ($true) {
        $pending = @($st.Values | Where-Object { -not $_.Final })
        if ($pending.Count -eq 0) { break }
        if ([DateTime]::UtcNow -ge $Deadline) {
            foreach ($x in $pending) { Stack-GiveUp $x ("not ready when the {0}-minute budget ran out" -f [int]($script:StackBudgetSec / 60)) }
            break
        }
        $states = Stack-ContainerStates
        foreach ($x in $pending) { Stack-PollService -X $x -States $states }
        $pending = @($st.Values | Where-Object { -not $_.Final })
        if ($pending.Count -eq 0) { break }
        if ([DateTime]::UtcNow -ge $nextProgress) {
            $nextProgress = [DateTime]::UtcNow.AddSeconds(60)
            $doneN = @($st.Values | Where-Object { $_.Ok }).Count
            $what = @($pending | Select-Object -First 4 | ForEach-Object { "$($_.Svc.Name): $(if ($_.LastEvent) { $_.LastEvent } else { $_.State })" })
            Write-Host ("  {0}/{1} ready, {2:0} min left; waiting on {3}" -f $doneN, $st.Count, ($Deadline - [DateTime]::UtcNow).TotalMinutes, ($what -join ', ')) -ForegroundColor DarkGray
        }
        Start-Sleep -Seconds $script:StackPollSec
    }

    $allReadyAt = $null
    $summary = [System.Collections.Generic.List[string]]::new()
    foreach ($x in $st.Values) {
        $id = "F-READY-$($x.Svc.Name)"
        if ($x.Ok) {
            if ($null -eq $allReadyAt -or $x.ReadyAt -gt $allReadyAt) { $allReadyAt = $x.ReadyAt }
            $after = [int]($x.ReadyAt - $started).TotalSeconds
            if ($x.Rotated) {
                Add-Result -Id $id -Status 'WARN' -Req @('R4') -Message ("{0}: 127.0.0.1:{1}/actuator/health answers (HTTP {2}), but docker's log no longer holds its [dev-reload] app-started/app-ready lines - rotated away on a long-running stack, so readiness is taken from the port alone" -f $x.Ctr, $x.Svc.Port, $x.HttpCode)
                $summary.Add(("{0,-22} ready (port only, log rotated), HTTP {1}" -f $x.Svc.Name, $x.HttpCode))
                continue
            }
            Add-Result -Id $id -Status 'PASS' -Req @('R4') -Message ("{0} logged [dev-reload] app-ready and 127.0.0.1:{1}/actuator/health answered (HTTP {2}), {3}s into the wait" -f $x.Ctr, $x.Svc.Port, $x.HttpCode, $after)
            $summary.Add(("{0,-22} ready after {1}s, HTTP {2}" -f $x.Svc.Name, $after, $x.HttpCode))
            continue
        }
        $tail = Invoke-Docker @('logs', '--tail', '300', $x.Ctr) -TimeoutSec 120
        $text = [string]$tail.StdOut + "`n" + [string]$tail.StdErr
        $ev = Save-Evidence -Suite 'stack' -Name "ready/$($x.Svc.Name).log" -Content $text
        $why = if ($x.Reason) { $x.Reason } else { 'not ready' }
        if ($x.LastEventLine) { $why += "; last dev-reload line: $($x.LastEventLine)" }
        $status = 'FAIL'
        $cls = Stack-ClassifyFailure -Container $x.Ctr -Text $text
        if ($cls) { $status = 'BLOCKED'; $why = "$cls. $why" }
        Add-Result -Id $id -Status $status -Req @('R4') -Evidence @($ev) -Message ("{0} is not ready: {1}" -f $x.Ctr, $why)
        $summary.Add(("{0,-22} NOT ready: {1}" -f $x.Svc.Name, $why))
    }
    Save-Evidence -Suite 'stack' -Name 'ready.txt' -Content ($summary -join "`n") | Out-Null
    return [pscustomobject]@{ States = $st; AllReadyAt = $allReadyAt; Started = $started }
}

# ---------------------------------------------------------------------------
# The probe files, into /tmp in each container
# ---------------------------------------------------------------------------

# Copied with LF line endings whatever the checkout has: dash reads a CR as
# part of every command, and a clone made before .gitattributes covered test/
# would otherwise fail every probe for a reason that has nothing to do with
# the stack.
function Stack-StageProbe {
    $h = Get-Harness
    $dir = Join-Path (Get-EvidenceDir 'stack') 'probe-files'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    foreach ($rel in @('container/lib.sh', 'container/stack-probe.sh', 'java/KafkaProbe.java')) {
        $src = Join-Path $h.TestRoot $rel
        if (-not (Test-Path -LiteralPath $src -PathType Leaf)) {
            Add-Result -Id 'F-PROBE-FILES' -Status 'FAIL' -Req @('R2', 'R5', 'R11') -Message "test/$rel is missing, so nothing can be checked inside the containers"
            return $null
        }
        $text = [System.IO.File]::ReadAllText($src).Replace("`r", '')
        [System.IO.File]::WriteAllText((Join-Path $dir (Split-Path -Leaf $rel)), $text, [System.Text.UTF8Encoding]::new($false))
    }
    return $dir
}

function Stack-CopyProbes {
    param([AllowNull()][string] $Stage, [object] $Ready)
    $copied = @{}
    $failed = @()
    foreach ($s in Get-JavaServices) {
        $copied[$s.Name] = $false
        if (-not $Stage) { continue }
        $ctr = Stack-Ctr $s
        # docker cp creates the destination directory from the source one only
        # when it does not exist yet; otherwise it nests a copy inside it.
        Stack-Exec -Container $ctr -Command @('rm', '-rf', $script:StackProbeDir) | Out-Null
        $r = Invoke-Docker @('cp', $Stage, "$($ctr):$($script:StackProbeDir)") -TimeoutSec 120
        if ($r.ExitCode -eq 0) { $copied[$s.Name] = $true }
        else { $failed += "$ctr ($(Stack-FirstLine $r.StdErr))$(Stack-NotReadyNote $Ready $s)" }
    }
    if ($Stage -and $failed.Count) {
        Add-Result -Id 'F-PROBE-COPY' -Status 'FAIL' -Req @('R2', 'R5', 'R11') -Message "docker cp of the probe into /tmp failed for: $($failed -join '; ')"
    }
    return $copied
}

function Stack-RemoveProbes {
    param([hashtable] $Copied)
    foreach ($s in Get-JavaServices) {
        if ($Copied.ContainsKey($s.Name) -and $Copied[$s.Name]) {
            Stack-Exec -Container (Stack-Ctr $s) -Command @('rm', '-rf', $script:StackProbeDir) | Out-Null
        }
    }
}

# ---------------------------------------------------------------------------
# F-VOL: one external Maven volume, the same one in all twelve
# ---------------------------------------------------------------------------

function Stack-CheckMounts {
    param([object] $Ready)
    $vol = $script:RealMavenVol

    # External means compose does not own it, which is what keeps `down -v`
    # from taking the Maven cache with it: a volume compose created carries
    # its project label.
    $v = Invoke-Docker @('volume', 'inspect', $vol) -TimeoutSec 60
    if ($v.ExitCode -ne 0) {
        Add-Result -Id 'F-VOL-01-volume' -Status 'FAIL' -Req @('R1') -Message "volume $vol does not exist, although the stack is up - the launcher creates it before compose runs"
    }
    else {
        $list = Stack-List (Stack-FromJson $v.StdOut)
        $labels = $null
        if ($list.Count -gt 0) { $labels = Stack-Get $list[0] @('Labels') }
        $proj = $null
        if ($labels -is [System.Collections.IDictionary] -and $labels.ContainsKey('com.docker.compose.project')) { $proj = $labels['com.docker.compose.project'] }
        if ($proj) {
            Add-Result -Id 'F-VOL-01-volume' -Status 'FAIL' -Req @('R1') -Message "volume $vol belongs to compose project '$proj', so it is not external: '.\dev.ps1 down -v' would delete the Maven cache"
        }
        else {
            Add-Result -Id 'F-VOL-01-volume' -Status 'PASS' -Req @('R1') -Message "volume $vol exists and no compose project owns it (no com.docker.compose.project label): it is external, and down -v leaves it alone"
        }
    }

    $all = [System.Collections.Generic.List[string]]::new()
    foreach ($s in Get-JavaServices) {
        $id = "F-VOL-01-$($s.Name)"
        $ctr = Stack-Ctr $s
        $r = Invoke-Docker @('inspect', '-f', '{{json .Mounts}}', $ctr) -TimeoutSec 60
        $all.Add("== $ctr")
        $all.Add([string]$r.StdOut)
        if ($r.ExitCode -ne 0) {
            Add-Result -Id $id -Status 'FAIL' -Req @('R1', 'R5') -Message ("docker inspect {0} failed: {1}{2}" -f $ctr, (Stack-FirstLine $r.StdErr), (Stack-NotReadyNote $Ready $s))
            continue
        }
        $mounts = Stack-List (Stack-FromJson $r.StdOut)
        $m2 = @()
        $under = @()
        $binds = @()
        foreach ($m in $mounts) {
            $dst = [string](Stack-Get $m @('Destination'))
            $src = [string](Stack-Get $m @('Source'))
            if ($dst -eq '/root/.m2') { $m2 += , $m }
            elseif ($dst.StartsWith('/root/.m2/')) { $under += $dst }
            # Any path form: /Users/x/.m2, C:\Users\x\.m2, /run/desktop/mnt/host/c/Users/x/.m2/...
            if ($src -match '[/\\]\.m2([/\\]|$)') { $binds += "$src -> $dst" }
        }
        $problems = @()
        if ($m2.Count -ne 1) { $problems += "$($m2.Count) mounts at /root/.m2 (want exactly one)" }
        else {
            $type = [string](Stack-Get $m2[0] @('Type'))
            $name = [string](Stack-Get $m2[0] @('Name'))
            if ($type -ne 'volume') { $problems += "/root/.m2 is a '$type' mount, not a volume" }
            if ($name -ne $vol) { $problems += "/root/.m2 is volume '$name', not $vol" }
            if ((Stack-Get $m2[0] @('RW')) -eq $false) { $problems += '/root/.m2 is mounted read-only, so no build could write to it' }
        }
        if ($under.Count) { $problems += "something else is mounted inside /root/.m2: $($under -join ', ')" }
        if ($binds.Count) { $problems += "a host .m2 is bind-mounted: $($binds -join '; ')" }
        if ($problems.Count) {
            Add-Result -Id $id -Status 'FAIL' -Req @('R1', 'R5') -Message ("{0}: {1}" -f $ctr, ($problems -join '; '))
        }
        else {
            Add-Result -Id $id -Status 'PASS' -Req @('R1', 'R5') -Message "$ctr has exactly one /root/.m2 mount, the volume $vol, and no host .m2 bind"
        }
    }
    Save-Evidence -Suite 'stack' -Name 'mounts.txt' -Content ($all -join "`n") | Out-Null
}

# stack-probe.sh probe in each container: F-JDWP-01, F-VOL-03 from its
# results, and the dev:inode it prints for F-VOL-02 here.
function Stack-RunProbes {
    param([object] $Ready, [hashtable] $Copied)
    $devino = [ordered]@{}
    $sameAsRoot = @()
    $noAnswer = @()
    foreach ($s in Get-JavaServices) {
        $ctr = Stack-Ctr $s
        $note = Stack-NotReadyNote $Ready $s
        $expected = @("F-JDWP-01-$($s.Name)", "F-VOL-03-$($s.Name)", "F-VOL-03-$($s.Name)-jvm")
        if (-not ($Copied.ContainsKey($s.Name) -and $Copied[$s.Name])) {
            foreach ($id in $expected) { Add-Result -Id $id -Status 'FAIL' -Req (Stack-ReqFor $id) -Message "the probe could not be copied into $ctr$note" }
            $noAnswer += $s.Name
            continue
        }
        $r = Stack-Exec -Container $ctr -Command @('sh', "$($script:StackProbeDir)/stack-probe.sh", 'probe', $s.Name, $s.Main) -TimeoutSec 180
        $ev = Save-Evidence -Suite 'stack' -Name "probe/$($s.Name).txt" -Content (Stack-EvidenceText $r)
        $seen = Stack-ImportLines -Text $r.StdOut -Evidence @($ev) -FailNote $note
        foreach ($id in $expected) {
            if ($seen -notcontains $id) {
                $why = Stack-FirstLine ([string]$r.StdErr + "`n" + [string]$r.StdOut)
                Add-Result -Id $id -Status 'FAIL' -Req (Stack-ReqFor $id) -Evidence @($ev) -Message "stack-probe.sh reported nothing for this (exit $($r.ExitCode)): $why$note"
            }
        }
        $kv = Stack-ProbeFacts $r.StdOut
        if ($kv.ContainsKey('devino') -and $kv['devino']) {
            $devino[$s.Name] = $kv['devino']
            # The repository on the same device as the container's root is a
            # directory in the container's own layer, not a mount at all.
            $dev = ($kv['devino'] -split ':')[0]
            if ($kv.ContainsKey('rootdev') -and $kv['rootdev'] -and $kv['rootdev'] -eq $dev) { $sameAsRoot += $s.Name }
        }
        else { $noAnswer += $s.Name }
    }

    $groups = @($devino.Values | Group-Object | Sort-Object Count -Descending)
    if ($devino.Count -eq 0) {
        Add-Result -Id 'F-VOL-02' -Status 'FAIL' -Req @('R5') -Message 'no container reported the dev:inode of /root/.m2/repository'
    }
    elseif ($groups.Count -eq 1 -and $noAnswer.Count -eq 0 -and $sameAsRoot.Count -eq 0) {
        Add-Result -Id 'F-VOL-02' -Status 'PASS' -Req @('R5') -Message "all $($devino.Count) containers see /root/.m2/repository as one directory on one filesystem (dev:inode $($groups[0].Name)), separate from their own root filesystem"
    }
    else {
        $parts = @()
        if ($groups.Count -gt 1) {
            $parts += 'different directories: ' + (@($groups | ForEach-Object { $g = $_.Name; "$g in " + ((@($devino.Keys | Where-Object { $devino[$_] -eq $g })) -join ',') }) -join '; ')
        }
        if ($sameAsRoot.Count) { $parts += "on the container's own root filesystem, so not a mount: $($sameAsRoot -join ', ')" }
        if ($noAnswer.Count) { $parts += "not reported by: $($noAnswer -join ', ')" }
        Add-Result -Id 'F-VOL-02' -Status 'FAIL' -Req @('R5') -Message ("/root/.m2/repository is not the same shared directory everywhere - {0}" -f ($parts -join ' | '))
    }
}

# ---------------------------------------------------------------------------
# F-NET: names, not localhost
# ---------------------------------------------------------------------------

function Stack-InstancePort {
    param([object] $Instance)
    $p = Stack-Get $Instance @('port', '$')
    if ($null -eq $p) { return 0 }
    $n = 0
    if ([int]::TryParse([string]$p, [ref] $n)) { return $n }
    return 0
}

# APPNAME -> its instances, from GET /eureka/apps.
function Stack-EurekaApps {
    param([AllowEmptyString()][string] $Body)
    $map = @{}
    $j = Stack-FromJson $Body
    foreach ($app in (Stack-List (Stack-Get $j @('applications', 'application')))) {
        $n = [string](Stack-Get $app @('name'))
        if (-not $n) { continue }
        $inst = Stack-List (Stack-Get $app @('instance'))
        $map[$n.ToUpperInvariant()] = $inst
    }
    return $map
}

# The instances of $Svc that are UP on its own port.
function Stack-EurekaGood {
    param([hashtable] $Apps, [object] $Svc)
    $name = $Svc.App.ToUpperInvariant()
    if (-not $Apps.ContainsKey($name)) { return , @() }
    $out = @(@($Apps[$name]) | Where-Object { ([string](Stack-Get $_ @('status'))) -eq 'UP' -and (Stack-InstancePort $_) -eq $Svc.Port })
    return , $out
}

function Stack-Resolve {
    param([string] $Container, [string] $Name)
    $r = Stack-Exec -Container $Container -Command @('getent', 'hosts', $Name) -TimeoutSec 60
    $first = Stack-FirstLine $r.StdOut
    if ($r.ExitCode -ne 0 -or -not $first) {
        return [pscustomobject]@{ Ok = $false; Ip = ''; Detail = "getent hosts exit $($r.ExitCode)$(if ($r.StdErr.Trim()) { ': ' + (Stack-FirstLine $r.StdErr) })" }
    }
    return [pscustomobject]@{ Ok = $true; Ip = (($first -split '\s+')[0]); Detail = $first }
}

function Stack-CheckEureka {
    param([object] $Ready)
    $clients = @(Get-JavaServices | Where-Object { $_.Name -ne 'service-discovery' })
    $gw = $script:LiveContainerPrefix + 'api-gateway'
    $deadline = [DateTime]::UtcNow.AddSeconds($script:StackRetrySec)
    $resp = $null
    $apps = @{}
    while ($true) {
        $resp = Stack-Http 'http://127.0.0.1:8761/eureka/apps' -Accept 'application/json' -TimeoutSec 20
        $apps = Stack-EurekaApps $resp.Body
        $waiting = 0
        foreach ($c in $clients) { $g = Stack-EurekaGood $apps $c; if ($g.Count -eq 0) { $waiting++ } }
        if ($waiting -eq 0 -or [DateTime]::UtcNow -ge $deadline) { break }
        Start-Sleep -Seconds 5
    }
    $ev = Save-Evidence -Suite 'stack' -Name 'eureka-apps.json' -Content $resp.Body
    if ($resp.Code -ne 200 -or $apps.Count -eq 0) {
        foreach ($s in $clients) {
            Add-Result -Id "F-NET-01-$($s.Name)" -Status 'FAIL' -Req @('R2') -Evidence @($ev) -Message ("GET 127.0.0.1:8761/eureka/apps answered HTTP {0}{1} with {2} application(s) in it{3}" -f $resp.Code, $(if ($resp.Error) { " ($($resp.Error))" } else { '' }), $apps.Count, (Stack-NotReadyNote $Ready (Get-JavaService 'service-discovery')))
        }
        return
    }
    $resolved = @{}
    foreach ($s in $clients) {
        $id = "F-NET-01-$($s.Name)"
        $name = $s.App.ToUpperInvariant()
        $note = Stack-NotReadyNote $Ready $s
        $inst = @()
        if ($apps.ContainsKey($name)) { $inst = @($apps[$name]) }
        $good = Stack-EurekaGood $apps $s
        if ($inst.Count -eq 0) {
            Add-Result -Id $id -Status 'FAIL' -Req @('R2') -Evidence @($ev) -Message ("{0} is not registered in Eureka after {1}s (registered: {2}){3}" -f $name, $script:StackRetrySec, ((@($apps.Keys) | Sort-Object) -join ', '), $note)
            continue
        }
        if ($good.Count -eq 0) {
            $seen = @($inst | ForEach-Object { "$([string](Stack-Get $_ @('hostName'))):$(Stack-InstancePort $_) $([string](Stack-Get $_ @('status')))" })
            Add-Result -Id $id -Status 'FAIL' -Req @('R2') -Evidence @($ev) -Message ("{0} is registered, but no instance is UP on port {1}: {2}{3}" -f $name, $s.Port, ($seen -join '; '), $note)
            continue
        }
        $problems = @()
        $warns = @()
        $shown = @()
        foreach ($g in $good) {
            $hn = [string](Stack-Get $g @('hostName'))
            $ip = [string](Stack-Get $g @('ipAddr'))
            if (-not $hn) { $problems += 'an UP instance has no hostName'; continue }
            if (-not $resolved.ContainsKey($hn)) { $resolved[$hn] = Stack-Resolve -Container $gw -Name $hn }
            $res = $resolved[$hn]
            $shown += "$($hn):$($s.Port)"
            # The gateway routes lb://<app> to exactly this name, so it has to
            # resolve there - and to the service, not back to the gateway.
            if (-not $res.Ok) { $problems += "hostName '$hn' does not resolve inside $gw ($($res.Detail)), so the gateway cannot route lb://$($s.App) to it" }
            elseif ($hn -eq 'localhost' -or $res.Ip -match '^(127\.|::1$)') { $problems += "hostName '$hn' resolves to $($res.Ip) inside $gw - the gateway itself, not the service" }
            elseif ($ip -and $res.Ip -ne $ip) { $warns += "hostName '$hn' resolves to $($res.Ip) inside $gw, but the instance registered ipAddr $ip" }
        }
        $stale = $inst.Count - $good.Count
        if ($stale -gt 0) { $warns += "$stale more instance(s) not UP on $($s.Port) are registered too - left over from an earlier container, until Eureka expires them" }
        if ($problems.Count) {
            Add-Result -Id $id -Status 'FAIL' -Req @('R2') -Evidence @($ev) -Message ("{0}: {1}{2}" -f $name, ($problems -join '; '), $note)
        }
        elseif ($warns.Count) {
            Add-Result -Id $id -Status 'WARN' -Req @('R2') -Evidence @($ev) -Message ("{0} is UP as {1}, which resolves inside {2}; but {3}" -f $name, ($shown -join ', '), $gw, ($warns -join '; '))
        }
        else {
            Add-Result -Id $id -Status 'PASS' -Req @('R2') -Evidence @($ev) -Message ("{0} is registered UP as {1}, and that name resolves inside {2}" -f $name, ($shown -join ', '), $gw)
        }
    }
    $expected = @($clients | ForEach-Object { $_.App.ToUpperInvariant() })
    $extra = @($apps.Keys | Where-Object { $expected -notcontains $_ })
    if ($extra.Count) {
        Add-Result -Id 'F-NET-01-extra' -Status 'INFO' -Req @('R2') -Evidence @($ev) -Message "Eureka also lists: $($extra -join ', ')"
    }
}

function Stack-CheckGateway {
    param([object] $Ready)
    $base = 'http://127.0.0.1:8080'
    $gwNote = Stack-NotReadyNote $Ready (Get-JavaService 'api-gateway')

    # A known answer end to end: host -> gateway -> Eureka -> user-service.
    $deadline = [DateTime]::UtcNow.AddSeconds($script:StackRetrySec)
    $t = $null
    while ($true) {
        $t = Stack-Http "$base/users/test" -TimeoutSec 20
        if (($t.Code -eq 200 -and $t.Body.Contains('User Service is working')) -or [DateTime]::UtcNow -ge $deadline) { break }
        Start-Sleep -Seconds 5
    }
    if ($t.Code -eq 200 -and $t.Body.Contains('User Service is working')) {
        Add-Result -Id 'F-NET-02-users-test' -Status 'PASS' -Req @('R2') -Message "GET 127.0.0.1:8080/users/test through the gateway: HTTP 200 'User Service is working'"
    }
    else {
        $got = if ($t.Code -eq 0) { "no answer ($($t.Error))" } else { "HTTP $($t.Code) '$(Stack-Cut $t.Body 120)'" }
        Add-Result -Id 'F-NET-02-users-test' -Status 'FAIL' -Req @('R2') -Message ("GET 127.0.0.1:8080/users/test through the gateway, for {0}s: {1}, not HTTP 200 'User Service is working'{2}{3}" -f $script:StackRetrySec, $got, $gwNote, (Stack-NotReadyNote $Ready (Get-JavaService 'user-service')))
    }

    # Every route: anything but the gateway's own "could not reach it" is
    # fine - a 401 or a 404 comes from the service behind it. 503 is what an
    # lb:// route with no instance in Eureka returns.
    $bad = @(0, 502, 503, 504)
    $last = [ordered]@{}
    $deadline = [DateTime]::UtcNow.AddSeconds($script:StackRetrySec)
    while ($true) {
        foreach ($p in @($script:StackRoutes.Keys)) {
            if ($last.Contains($p) -and $bad -notcontains $last[$p].Code) { continue }
            $last[$p] = Stack-Http "$base$p" -TimeoutSec 20
        }
        $open = @(@($last.Keys) | Where-Object { $bad -contains $last[$_].Code })
        if ($open.Count -eq 0 -or [DateTime]::UtcNow -ge $deadline) { break }
        Start-Sleep -Seconds 5
    }
    foreach ($p in @($script:StackRoutes.Keys)) {
        $id = 'F-NET-02' + ($p -replace '/', '-')
        $x = $last[$p]
        $svc = Get-JavaService $script:StackRoutes[$p]
        if ($x.Code -eq 0) {
            Add-Result -Id $id -Status 'FAIL' -Req @('R2') -Message ("GET 127.0.0.1:8080{0}: no answer from the gateway ({1}){2}" -f $p, $x.Error, $gwNote)
        }
        elseif ($bad -contains $x.Code) {
            Add-Result -Id $id -Status 'FAIL' -Req @('R2') -Message ("GET 127.0.0.1:8080{0} -> HTTP {1} for {2}s: the gateway could not reach lb://{3}{4}" -f $p, $x.Code, $script:StackRetrySec, $svc.App, (Stack-NotReadyNote $Ready $svc))
        }
        elseif ($x.Code -eq 500) {
            Add-Result -Id $id -Status 'WARN' -Req @('R2') -Message ("GET 127.0.0.1:8080{0} -> HTTP 500: either {1} failed the request or the gateway failed to reach it - a 500 does not say which" -f $p, $svc.App)
        }
        elseif ($x.Code -eq 404) {
            # Both the service and the gateway itself answer 404 the same way;
            # what matters here is that it is not the 503 of an empty lb:// route.
            Add-Result -Id $id -Status 'PASS' -Req @('R2') -Message ("GET 127.0.0.1:8080{0} -> HTTP 404: not the 502/503/504 of an unreachable lb://{1} (a 404 does not say whether {1} or the gateway sent it)" -f $p, $svc.App)
        }
        else {
            Add-Result -Id $id -Status 'PASS' -Req @('R2') -Message ("GET 127.0.0.1:8080{0} -> HTTP {1}: routed to {2}, which answered" -f $p, $x.Code, $svc.App)
        }
    }
}

function Stack-DetailResult {
    param([string] $Id, [object] $Components, [string] $Name, [string] $What, [string] $From, [string] $Note)
    if (-not ($Components -is [System.Collections.IDictionary])) {
        Add-Result -Id $Id -Status 'INFO' -Req @('R2') -Message "health details are hidden ($From shows only the overall status), so the $Name component ($What) cannot be checked"
        return
    }
    $st = Stack-Get $Components @($Name, 'status')
    if ($null -eq $st) {
        Add-Result -Id $Id -Status 'FAIL' -Req @('R2') -Message "the health details ($From) have no '$Name' component, although this service should have one ($What)$Note"
    }
    elseif ($st -eq 'UP') {
        Add-Result -Id $Id -Status 'PASS' -Req @('R2') -Message "$Name is UP ($What), from $From"
    }
    else {
        Add-Result -Id $Id -Status 'FAIL' -Req @('R2') -Message "$Name is $st ($What), from $From$Note"
    }
}

function Stack-CheckHealth {
    param([object] $Ready)
    $svcs = @(Get-JavaServices)
    $gw = $script:LiveContainerPrefix + 'api-gateway'

    # From the host, retried until UP: a health indicator can report DOWN or
    # UNKNOWN for a moment after a start (discovery before the first registry
    # fetch, say).
    $hostSide = @{}
    $deadline = [DateTime]::UtcNow.AddSeconds($script:StackRetrySec)
    while ($true) {
        foreach ($s in $svcs) {
            if ($hostSide.ContainsKey($s.Name) -and $hostSide[$s.Name].Status -eq 'UP') { continue }
            $r = Stack-Http ("http://127.0.0.1:{0}/actuator/health" -f $s.Port) -TimeoutSec 20
            $hostSide[$s.Name] = [pscustomobject]@{ Code = $r.Code; Status = (Stack-HealthStatus $r.Body); Body = $r.Body; Error = $r.Error }
        }
        $notUp = @($svcs | Where-Object { $hostSide[$_.Name].Status -ne 'UP' })
        if ($notUp.Count -eq 0 -or [DateTime]::UtcNow -ge $deadline) { break }
        Start-Sleep -Seconds 5
    }

    $ev = [System.Collections.Generic.List[string]]::new()
    foreach ($s in $svcs) {
        $id = "F-NET-03-$($s.Name)"
        $note = Stack-NotReadyNote $Ready $s
        $hs = $hostSide[$s.Name]
        # From inside the network, by compose name - the path the services
        # themselves use.
        $url = "http://$($s.Name):$($s.Port)/actuator/health"
        $in = Stack-CurlIn -Container $gw -Url $url -TimeoutSec 20
        $inStatus = Stack-HealthStatus $in.Body
        if ($inStatus -ne 'UP') {
            Start-Sleep -Seconds 5
            $in = Stack-CurlIn -Container $gw -Url $url -TimeoutSec 20
            $inStatus = Stack-HealthStatus $in.Body
        }
        $ev.Add("== $($s.Name)")
        $ev.Add("host 127.0.0.1:$($s.Port): HTTP $($hs.Code) $($hs.Status) $($hs.Error)")
        $ev.Add([string]$hs.Body)
        $ev.Add("in $($gw): $url -> HTTP $($in.Code) $inStatus $($in.Error)")
        $ev.Add([string]$in.Body)

        if ($hs.Status -eq 'UP' -and $inStatus -eq 'UP') {
            Add-Result -Id $id -Status 'PASS' -Req @('R2') -Message "/actuator/health is UP from the host on 127.0.0.1:$($s.Port) and from $gw as $url"
        }
        else {
            $parts = @()
            if ($hs.Status -ne 'UP') { $parts += "from the host (127.0.0.1:$($s.Port)): $(Stack-DescribeHealth $hs.Code $hs.Status $hs.Error $hs.Body)" }
            if ($inStatus -ne 'UP') { $parts += "from $gw ($url): $(Stack-DescribeHealth $in.Code $inStatus $in.Error $in.Body)" }
            Add-Result -Id $id -Status 'FAIL' -Req @('R2') -Message (($parts -join '; ') + $note)
        }

        $comps = Stack-Get (Stack-FromJson $hs.Body) @('components')
        $from = "the host's view of 127.0.0.1:$($s.Port)"
        # config-server shows details only to an authenticated caller
        # (show-details=when-authorized); its clients have the credentials.
        if (-not ($comps -is [System.Collections.IDictionary]) -and $s.Name -eq 'config-server') {
            $auth = Stack-CurlIn -Container $gw -Url 'http://config-server:8888/actuator/health' -TimeoutSec 20 -Auth
            $comps = Stack-Get (Stack-FromJson $auth.Body) @('components')
            $from = "$gw, authenticated with its own CONFIG_CLIENT_* credentials"
            $ev.Add("authenticated, in $($gw): HTTP $($auth.Code) $($auth.Error)")
            $ev.Add([string]$auth.Body)
        }
        if ($s.Jpa) { Stack-DetailResult -Id "$id-db" -Components $comps -Name 'db' -What 'its PostgreSQL datasource' -From $from -Note $note }
        if ($s.Name -ne 'service-discovery') { Stack-DetailResult -Id "$id-discovery" -Components $comps -Name 'discoveryComposite' -What 'its Eureka client' -From $from -Note $note }
    }
    Save-Evidence -Suite 'stack' -Name 'health.txt' -Content ($ev -join "`n") | Out-Null
}

function Stack-CheckLocatedEnvironment {
    param([object] $Ready)
    foreach ($s in @(Get-JavaServices | Where-Object { $_.ConfigClient })) {
        $id = "F-NET-04-$($s.Name)"
        $ctr = Stack-Ctr $s
        $log = Get-ContainerLog -Container $ctr
        $needle = "Located environment: name=$($s.App), profiles=[container"
        if ($log.Contains($needle)) {
            Add-Result -Id $id -Status 'PASS' -Req @('R2') -Message "$ctr logged '$needle...': its configuration came from config-server, container profile"
            continue
        }
        $other = [regex]::Match($log, 'Located environment: name=[^,\r\n]*, profiles=\[[^\]\r\n]*\]')
        $seen = if ($other.Success) { "it logged '$($other.Value)' instead" } else { 'no Located environment line at all' }
        # json-file drops the OLDEST lines first, so while the line dev-reload.sh
        # prints first on every container start is still there, the log reaches
        # back past the application's first config import. When it is gone,
        # the import may simply have scrolled out on a long-running stack.
        if (-not $other.Success -and -not $log.Contains('[dev-reload] compiler:')) {
            Add-Result -Id $id -Status 'WARN' -Req @('R2') -Message ("{0}: no Located environment line, but docker's log no longer reaches back to the container's start (rotated at 3 x 10 MB), so it may have scrolled out - restart the service to check it" -f $ctr)
            continue
        }
        Add-Result -Id $id -Status 'FAIL' -Req @('R2') -Message ("{0} never logged '{1}...': {2}{3}" -f $ctr, $needle, $seen, (Stack-NotReadyNote $Ready $s))
    }
}

function Stack-CheckKafka {
    param([object] $Ready, [hashtable] $Copied)
    $dir = $script:StackProbeDir
    foreach ($s in @(Get-JavaServices | Where-Object { $_.Kafka })) {
        $id = "F-NET-05-$($s.Name)"
        $ctr = Stack-Ctr $s
        $note = Stack-NotReadyNote $Ready $s
        if (-not ($Copied.ContainsKey($s.Name) -and $Copied[$s.Name])) {
            Add-Result -Id $id -Status 'FAIL' -Req @('R2') -Message "the probe could not be copied into $ctr$note"
            continue
        }
        $r = Stack-Exec -Container $ctr -Command @('sh', "$dir/stack-probe.sh", 'kafka', $s.Name, "$dir/KafkaProbe.java", 'kafka:9092') -TimeoutSec 180
        $ev = Save-Evidence -Suite 'stack' -Name "kafka/$($s.Name).txt" -Content (Stack-EvidenceText $r)
        $seen = Stack-ImportLines -Text $r.StdOut -Evidence @($ev) -FailNote $note
        if ($seen -notcontains $id) {
            Add-Result -Id $id -Status 'FAIL' -Req @('R2') -Evidence @($ev) -Message "stack-probe.sh kafka reported nothing (exit $($r.ExitCode)): $(Stack-FirstLine ([string]$r.StdErr + "`n" + [string]$r.StdOut))$note"
        }
    }
}

# ---------------------------------------------------------------------------
# F-NET-06: every address in the configuration config-server SERVES
# ---------------------------------------------------------------------------

# The compose names a container can reach, with their container ports.
function Stack-KnownHosts {
    $k = @{ 'postgres' = 5432; 'kafka' = 9092 }
    foreach ($s in Get-JavaServices) { $k[$s.Name] = $s.Port }
    foreach ($n in @($k.Keys)) { $k[$script:LiveContainerPrefix + $n] = $k[$n] }
    return $k
}

function Stack-RedactUrl {
    param([AllowEmptyString()][string] $Value)
    $v = [regex]::Replace([string]$Value, '://[^/@\s]+@', '://<redacted>@')
    return [regex]::Replace($v, '(?i)(password|passwd|pwd|secret|token|apikey|api-key)=([^&;\s]+)', '$1=<redacted>')
}

# One verdict per address: a compose service name on its container port is
# right; localhost, a loopback address or a debug port is wrong; any other
# name is not something this stack runs, which is worth a look.
function Stack-JudgeAuthority {
    param([string] $Authority, [string] $Scheme, [bool] $InPlaceholder)
    $a = $Authority
    $at = $a.LastIndexOf('@')
    if ($at -ge 0) { $a = $a.Substring($at + 1) }
    $hostPart = $a
    $port = 0
    $m = [regex]::Match($a, '^\[([^\]]+)\](?::(\d+))?$')
    if (-not $m.Success) { $m = [regex]::Match($a, '^([^:]+)(?::(\d+))?$') }
    if ($m.Success) {
        $hostPart = $m.Groups[1].Value
        if ($m.Groups[2].Success) { $port = [int]$m.Groups[2].Value }
    }
    if ($port -eq 0) {
        switch ($Scheme) { 'http' { $port = 80 } 'https' { $port = 443 } 'jdbc:postgresql' { $port = 5432 } }
    }
    $hl = $hostPart.ToLowerInvariant()
    $shown = if ($port) { "$($hostPart):$port" } else { $hostPart }
    $known = Stack-KnownHosts
    $verdict = 'PASS'
    $why = 'a compose service on its container port'
    if ($hl -match '^(localhost|127\.|0\.0\.0\.0$|::1$|0:0:0:0:0:0:0:1$|host\.docker\.internal$|gateway\.docker\.internal$)') {
        $verdict = 'FAIL'; $why = 'loopback or the host: inside a container that is not the service'
    }
    elseif ($port -ge 5005 -and $port -le 5016) {
        $verdict = 'FAIL'; $why = "port $port is a JDWP debug port"
    }
    elseif ($known.ContainsKey($hl)) {
        if ($port -ne $known[$hl]) { $verdict = 'FAIL'; $why = "$hostPart is a compose service, but its container port is $($known[$hl]), not $port" }
    }
    elseif ($Scheme -eq 'lb' -and @(Get-JavaServices | Where-Object { $_.App -eq $hl }).Count -gt 0) {
        $why = 'a load-balanced Eureka application name'
    }
    else {
        $verdict = 'WARN'; $why = 'not a compose service name: an external host, or a name nothing on the homecrew network answers to'
    }
    if ($InPlaceholder -and $verdict -eq 'FAIL') {
        $verdict = 'WARN'; $why += ' - but it is inside a ${...} placeholder, used only if the client lacks that variable'
    }
    return [pscustomobject]@{ Authority = $shown; Verdict = $verdict; Why = $why }
}

# The addresses in one value: every scheme://authority (http, jdbc:postgresql,
# ...), and for the host:port-list keys the bare entries too.
function Stack-UrlFindings {
    param([string] $Key, [string] $Value)
    $out = [System.Collections.Generic.List[object]]::new()
    $inPh = $Value.Contains('${')
    $found = 0
    # jdbc:postgresql://host:port is scheme "jdbc:postgresql"; the optional
    # prefix is only "jdbc:", or the match would start at "postgresql".
    foreach ($m in [regex]::Matches($Value, '(?i)\b((?:jdbc:)?[a-z][a-z0-9+.\-]*)://([^/?#\s,;"''{}]+)')) {
        $out.Add((Stack-JudgeAuthority -Authority $m.Groups[2].Value -Scheme $m.Groups[1].Value.ToLowerInvariant() -InPlaceholder $inPh))
        $found++
    }
    # A YAML list arrives flattened, as key[0], key[1], ...
    if ($found -eq 0 -and $Key -match '(?i)(bootstrap[-._]?servers|brokers|defaultzone)(\[\d+\])?$') {
        foreach ($part in ($Value -split ',')) {
            $p = $part.Trim()
            if ($p) { $out.Add((Stack-JudgeAuthority -Authority $p -Scheme '' -InPlaceholder $inPh)) }
        }
    }
    return , $out.ToArray()
}

# config-server lists property sources highest precedence first, so the first
# source to set a key is the value the client ends up with. Keys are compared
# the way Spring's relaxed binding does, near enough: case and dashes aside.
function Stack-AuditServed {
    param([object[]] $Sources)
    $taken = @{}
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($ps in $Sources) {
        $name = [string](Stack-Get $ps @('name'))
        $src = Stack-Get $ps @('source')
        if (-not ($src -is [System.Collections.IDictionary])) { continue }
        foreach ($k in @($src.Keys)) {
            $canon = $k.ToLowerInvariant().Replace('-', '')
            $effective = -not $taken.ContainsKey($canon)
            if ($effective) { $taken[$canon] = $true }
            $v = $src[$k]
            if (-not ($v -is [string])) { continue }
            $finds = Stack-UrlFindings -Key $k -Value $v
            foreach ($f in $finds) {
                $rows.Add([pscustomobject]@{ Key = $k; Source = $name; Effective = $effective; Authority = $f.Authority; Verdict = $f.Verdict; Why = $f.Why; Value = (Stack-RedactUrl $v) })
            }
        }
    }
    return , $rows.ToArray()
}

function Stack-CheckServedConfig {
    param([object] $Ready)
    foreach ($s in @(Get-JavaServices | Where-Object { $_.ConfigClient })) {
        $id = "F-NET-06-$($s.Name)"
        $ctr = Stack-Ctr $s
        $note = Stack-NotReadyNote $Ready $s
        $pe = Stack-Exec -Container $ctr -Command @('printenv', 'CONFIG_SERVER_URI') -TimeoutSec 60
        $envUri = if ($pe.ExitCode -eq 0) { $pe.StdOut.Trim() } else { '' }
        $path = "/$($s.App)/container"
        $c = Stack-CurlIn -Container $ctr -Url "http://config-server:8888$path" -TimeoutSec 20 -Auth
        if ($c.Code -ne 200) {
            $hint = ''
            if ($c.Code -eq 401) { $hint = ': the CONFIG_CLIENT_* credentials in the container are not the ones config-server expects' }
            elseif ($c.Code -eq 404) { $hint = ": config-server serves nothing for $($s.App) (accept-empty=false)" }
            elseif ($c.Code -eq 0) { $hint = ": no answer ($($c.Error))" }
            Add-Result -Id $id -Status 'FAIL' -Req @('R2') -Message ("config-server answered HTTP {0} to {1} for {2}{3}{4}" -f $c.Code, $ctr, $path, $hint, $note)
            continue
        }
        $j = Stack-FromJson $c.Body
        $sources = Stack-List (Stack-Get $j @('propertySources'))
        $names = @($sources | ForEach-Object { [string](Stack-Get $_ @('name')) })
        $rows = Stack-AuditServed -Sources $sources
        # Only the audit goes into the evidence, never the body: it holds the
        # DECRYPTED {cipher} values.
        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add("# GET http://config-server:8888$path from $ctr, with its own CONFIG_CLIENT_* credentials: HTTP 200")
        $lines.Add("# CONFIG_SERVER_URI in the container: $envUri")
        $lines.Add('# property sources, highest precedence first:')
        foreach ($n in $names) { $lines.Add("#   $n") }
        foreach ($r in $rows) {
            $lines.Add(("{0,-5} {1,-9} {2} -> {3}  [{4}]  = {5}  (from {6})" -f $r.Verdict, $(if ($r.Effective) { 'effective' } else { 'shadowed' }), $r.Key, $r.Authority, $r.Why, $r.Value, $r.Source))
        }
        $ev = Save-Evidence -Suite 'stack' -Name "served-config/$($s.App).txt" -Content ($lines -join "`n")

        $eff = @($rows | Where-Object { $_.Effective })
        $shadowed = @($rows | Where-Object { -not $_.Effective })
        $fails = @($eff | Where-Object { $_.Verdict -eq 'FAIL' })
        $warns = @($eff | Where-Object { $_.Verdict -eq 'WARN' })
        $problems = @()
        if ($fails.Count) { $problems += (@($fails | Select-Object -First 5 | ForEach-Object { "$($_.Key) -> $($_.Authority) ($($_.Why))" }) -join '; ') }
        if ($eff.Count -eq 0) { $problems += 'no URL-like value is served at all - expected at least the Eureka defaultZone and spring.kafka.bootstrap-servers from application-container.yml' }
        if (@($names | Where-Object { $_ -match 'application-container\.' }).Count -eq 0) { $problems += "application-container.yml, where the container topology lives, is not among the served sources ($($names -join ', '))" }
        if ($envUri -ne 'http://config-server:8888') { $problems += "CONFIG_SERVER_URI in $ctr is '$envUri', not http://config-server:8888" }
        if ($problems.Count) {
            Add-Result -Id $id -Status 'FAIL' -Req @('R2') -Evidence @($ev) -Message (($problems -join ' | ') + $note)
            continue
        }
        $good = @($eff | Select-Object -First 6 | ForEach-Object { "$($_.Key)=$($_.Authority)" }) -join ', '
        $tail = if ($shadowed.Count) { "; $($shadowed.Count) default-profile value(s) such as localhost are overridden by the container profile" } else { '' }
        if ($warns.Count) {
            Add-Result -Id $id -Status 'WARN' -Req @('R2') -Evidence @($ev) -Message ("{0} served address(es) are not compose services: {1}; the rest are ({2})" -f $warns.Count, (@($warns | ForEach-Object { "$($_.Key) -> $($_.Authority)" }) -join '; '), $good)
        }
        else {
            Add-Result -Id $id -Status 'PASS' -Req @('R2') -Evidence @($ev) -Message ("all {0} effective address(es) config-server serves {1} are compose names on container ports ({2}); CONFIG_SERVER_URI=http://config-server:8888{3}" -f $eff.Count, $s.App, $good, $tail)
        }
    }
}

# ---------------------------------------------------------------------------
# F-JDWP: the debug ports, from the host
# ---------------------------------------------------------------------------

function Stack-CheckHandshakes {
    param([object] $Ready, [hashtable] $Copied)
    foreach ($s in Get-JavaServices) {
        $id = "F-JDWP-02-$($s.Name)"
        $ctr = Stack-Ctr $s
        $hs = Stack-JdwpHandshake -Address '127.0.0.1' -Port $s.Debug
        Stack-Note ("JDWP 127.0.0.1:{0} ({1}): {2} in {3}ms" -f $s.Debug, $s.Name, $hs.Detail, $hs.Ms)
        if ($hs.Ok) {
            Add-Result -Id $id -Status 'PASS' -Req @('R11') -Message ("127.0.0.1:{0} answered the JDWP handshake (the 14 bytes echoed) in {1}ms" -f $s.Debug, $hs.Ms)
            continue
        }
        # One debugger at a time: while yours is attached, the agent does not
        # listen, and the handshake fails for a reason that is not a fault.
        $facts = @{}
        if ($Copied.ContainsKey($s.Name) -and $Copied[$s.Name]) {
            $st = Stack-Exec -Container $ctr -Command @('sh', "$($script:StackProbeDir)/stack-probe.sh", 'jdwp-state') -TimeoutSec 60
            $facts = Stack-ProbeFacts $st.StdOut
        }
        $est = if ($facts.ContainsKey('jdwp_established')) { $facts['jdwp_established'] } else { '?' }
        $lis = if ($facts.ContainsKey('jdwp_listen')) { $facts['jdwp_listen'] } else { '?' }
        if ($est -match '^[1-9]') {
            Add-Result -Id $id -Status 'SKIP' -Req @('R11') -Message ("127.0.0.1:{0}: {1} - but {2} has an ESTABLISHED connection on :5005 (listening: {3}): a debugger is attached, and JDWP takes one at a time" -f $s.Debug, $hs.Detail, $ctr, $lis)
        }
        else {
            Add-Result -Id $id -Status 'FAIL' -Req @('R11') -Message ("127.0.0.1:{0}: {1}; inside {2}, :5005 listening={3} established={4}{5}" -f $s.Debug, $hs.Detail, $ctr, $lis, $est, (Stack-NotReadyNote $Ready $s))
        }
    }
}

function Stack-SplitHostPort {
    param([string] $Text)
    $m = [regex]::Match($Text, '^\[([^\]]+)\]:(\d+)$')
    if (-not $m.Success) { $m = [regex]::Match($Text, '^(.*):(\d+)$') }
    if (-not $m.Success) { return $null }
    $a = $m.Groups[1].Value
    $pct = $a.IndexOf('%')
    if ($pct -ge 0) { $a = $a.Substring(0, $pct) }
    return [pscustomobject]@{ Address = $a; Port = [int]$m.Groups[2].Value }
}

function Stack-IsLoopbackAddress {
    param([string] $Address)
    return ($Address -match '^(127\.|::1$|0:0:0:0:0:0:0:1$|::ffff:127\.|localhost$)')
}

# Every TCP listener on $Ports: Address, Port, Pid, Process.
function Stack-HostListeners {
    param([int[]] $Ports)
    $h = Get-Harness
    $items = [System.Collections.Generic.List[object]]::new()
    $how = ''
    $raw = ''
    if ($h.OnWindows) {
        $got = $false
        if (Get-Command -Name 'Get-NetTCPConnection' -ErrorAction SilentlyContinue) {
            try {
                foreach ($c in @(Get-NetTCPConnection -State Listen -ErrorAction Stop)) {
                    $p = [int]$c.LocalPort
                    if ($Ports -notcontains $p) { continue }
                    $items.Add([pscustomobject]@{ Address = [string]$c.LocalAddress; Port = $p; Pid = [int]$c.OwningProcess; Process = '' })
                }
                $how = 'Get-NetTCPConnection -State Listen'
                $got = $true
            }
            catch { $how = "Get-NetTCPConnection failed ($(Stack-ExMessage $_.Exception)), so "; $items.Clear() }
        }
        if (-not $got) {
            $r = Invoke-Native -FilePath (Join-Path $env:SystemRoot 'System32\netstat.exe') -ArgumentList @('-ano') -TimeoutSec 60
            $raw = [string]$r.StdOut
            foreach ($l in ($raw -split "`r?`n")) {
                $m = [regex]::Match($l, '^\s*TCP\s+(\S+)\s+(\S+)\s+\S*\s*(\d+)\s*$')
                if (-not $m.Success) { continue }
                # A listening socket has no peer; the state column itself is
                # translated on non-English Windows.
                if (@('0.0.0.0:0', '[::]:0') -notcontains $m.Groups[2].Value) { continue }
                $hp = Stack-SplitHostPort $m.Groups[1].Value
                if ($null -eq $hp -or $Ports -notcontains $hp.Port) { continue }
                $items.Add([pscustomobject]@{ Address = $hp.Address; Port = $hp.Port; Pid = [int]$m.Groups[3].Value; Process = '' })
            }
            $how += 'netstat -ano'
        }
        $names = @{}
        foreach ($it in $items) {
            if (-not $names.ContainsKey($it.Pid)) {
                $pr = Get-Process -Id $it.Pid -ErrorAction SilentlyContinue
                $names[$it.Pid] = if ($pr) { [string]$pr.ProcessName } else { '' }
            }
            $it.Process = $names[$it.Pid]
        }
    }
    elseif ($IsMacOS) {
        $lsof = Get-Command lsof -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $lsof) { return [pscustomobject]@{ How = 'lsof is not on PATH'; Items = $null; Raw = '' } }
        # +c 0: the whole command name, not its first nine characters.
        $r = Invoke-Native -FilePath $lsof.Source -ArgumentList @('+c', '0', '-nP', '-iTCP', '-sTCP:LISTEN') -TimeoutSec 60
        $raw = [string]$r.StdOut
        foreach ($l in ($raw -split "`r?`n")) {
            $m = [regex]::Match($l, '^(\S+)\s+(\d+)\s+.*\sTCP\s+(\S+)\s+\(LISTEN\)\s*$')
            if (-not $m.Success) { continue }
            $hp = Stack-SplitHostPort $m.Groups[3].Value
            if ($null -eq $hp -or $Ports -notcontains $hp.Port) { continue }
            $items.Add([pscustomobject]@{ Address = $hp.Address; Port = $hp.Port; Pid = [int]$m.Groups[2].Value; Process = ($m.Groups[1].Value -replace '\\x20', ' ') })
        }
        $how = 'lsof -nP -iTCP -sTCP:LISTEN'
    }
    else {
        $ss = Get-Command ss -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $ss) { return [pscustomobject]@{ How = 'ss is not on PATH'; Items = $null; Raw = '' } }
        $r = Invoke-Native -FilePath $ss.Source -ArgumentList @('-H', '-l', '-t', '-n', '-p') -TimeoutSec 60
        # iproute2 before 4.12 has no -H; the header line is skipped below.
        if ($r.ExitCode -ne 0) { $r = Invoke-Native -FilePath $ss.Source -ArgumentList @('-l', '-t', '-n', '-p') -TimeoutSec 60 }
        $raw = [string]$r.StdOut
        foreach ($l in ($raw -split "`r?`n")) {
            if ($l -match '^\s*State\s') { continue }
            $f = @($l.Trim() -split '\s+')
            if ($f.Count -lt 5) { continue }
            $hp = Stack-SplitHostPort $f[3]
            if ($null -eq $hp -or $Ports -notcontains $hp.Port) { continue }
            $proc = ''
            $pid2 = 0
            $pm = [regex]::Match($l, 'users:\(\("([^"]+)",pid=(\d+)')
            if ($pm.Success) { $proc = $pm.Groups[1].Value; $pid2 = [int]$pm.Groups[2].Value }
            $items.Add([pscustomobject]@{ Address = $hp.Address; Port = $hp.Port; Pid = $pid2; Process = $proc })
        }
        $how = 'ss -ltnH'
    }
    return [pscustomobject]@{ How = $how; Items = $items.ToArray(); Raw = $raw }
}

function Stack-CheckListeners {
    $ports = $script:StackHostPorts
    $l = Stack-HostListeners -Ports $ports
    if ($null -eq $l.Items) {
        Add-Result -Id 'F-JDWP-03-listeners' -Status 'SKIP' -Req @('R11') -Message "cannot list this machine's listening sockets: $($l.How)"
        return
    }
    $items = @($l.Items)
    $lines = @($items | Sort-Object Port, Address | ForEach-Object { "{0,-6} {1,-40} pid {2,-7} {3}" -f $_.Port, $_.Address, $_.Pid, $_.Process })
    $ev = Save-Evidence -Suite 'stack' -Name 'host-listeners.txt' -Content ("# $($l.How)`n" + ($lines -join "`n") + "`n# ---- raw ----`n" + $l.Raw)
    $offDocker = @()
    $offOther = @()
    foreach ($it in $items) {
        if (Stack-IsLoopbackAddress $it.Address) { continue }
        $who = if ($it.Process) { "$($it.Process) (pid $($it.Pid))" } elseif ($it.Pid) { "pid $($it.Pid)" } else { 'an unknown process' }
        $desc = "$($it.Address):$($it.Port) held by $who"
        # Someone else's server on the same port - a local PostgreSQL on 5432,
        # say - is worth knowing, but it is not the dev stack's binding.
        if ($it.Process -and $it.Process -notmatch '(?i)docke|vpnkit|wslrelay|rootlesskit|lima|colima|orbstack|^ssh') { $offOther += $desc }
        else { $offDocker += $desc }
    }
    $seenPorts = @($items | ForEach-Object { $_.Port } | Sort-Object -Unique)
    $unseen = @($ports | Where-Object { $seenPorts -notcontains $_ })
    $unseenNote = if ($unseen.Count) { " Nothing listens on $($unseen -join ', ') (not published, or not visible to $($l.How))." } else { '' }
    if ($offDocker.Count) {
        Add-Result -Id 'F-JDWP-03-listeners' -Status 'FAIL' -Req @('R11') -Evidence @($ev) -Message ("listening beyond loopback: {0}.{1}" -f ($offDocker -join '; '), $unseenNote)
    }
    elseif ($items.Count -eq 0) {
        Add-Result -Id 'F-JDWP-03-listeners' -Status 'WARN' -Req @('R11') -Evidence @($ev) -Message "$($l.How) shows no listener on any of the stack's ports, so there is nothing to judge (Linux with the userland proxy off publishes through iptables alone; F-JDWP-03-compose and F-JDWP-04 still apply)"
    }
    elseif ($offOther.Count) {
        Add-Result -Id 'F-JDWP-03-listeners' -Status 'WARN' -Req @('R11') -Evidence @($ev) -Message ("every Docker listener on the stack's ports is on 127.0.0.1/::1, but other programs listen on the same ports on all interfaces: {0}.{1}" -f ($offOther -join '; '), $unseenNote)
    }
    else {
        Add-Result -Id 'F-JDWP-03-listeners' -Status 'PASS' -Req @('R11') -Evidence @($ev) -Message ("{0} listener(s) on 5005-5016, 8080-8089, 8761, 8888, 5432, 9092 and 4200 ({1}), all on 127.0.0.1 or ::1.{2}" -f $items.Count, $l.How, $unseenNote)
    }
}

# What compose itself says each published port is bound to.
function Stack-CheckComposePorts {
    $want = [System.Collections.Generic.List[object]]::new()
    foreach ($s in Get-JavaServices) {
        $want.Add([pscustomobject]@{ Svc = $s.Name; Target = 5005; Expect = "127.0.0.1:$($s.Debug)" })
        $want.Add([pscustomobject]@{ Svc = $s.Name; Target = $s.Port; Expect = "127.0.0.1:$($s.Port)" })
    }
    $want.Add([pscustomobject]@{ Svc = 'postgres'; Target = 5432; Expect = '127.0.0.1:5432' })
    $want.Add([pscustomobject]@{ Svc = 'kafka'; Target = 9092; Expect = '127.0.0.1:9092' })
    $want.Add([pscustomobject]@{ Svc = 'webapp'; Target = 80; Expect = '127.0.0.1:4200' })
    $bad = @()
    $lines = @()
    foreach ($w in $want) {
        $r = Invoke-LiveCompose @('port', $w.Svc, "$($w.Target)") -TimeoutSec 60
        $got = Stack-FirstLine $r.StdOut
        $lines += ("{0} {1} -> {2} (exit {3})" -f $w.Svc, $w.Target, $got, $r.ExitCode)
        if ($r.ExitCode -ne 0 -or $got -ne $w.Expect) {
            $shown = if ($got) { $got } else { "exit $($r.ExitCode): $(Stack-FirstLine $r.StdErr)" }
            $bad += "$($w.Svc):$($w.Target) -> $shown (want $($w.Expect))"
        }
    }
    $ev = Save-Evidence -Suite 'stack' -Name 'compose-port.txt' -Content ($lines -join "`n")
    if ($bad.Count) {
        Add-Result -Id 'F-JDWP-03-compose' -Status 'FAIL' -Req @('R11') -Evidence @($ev) -Message ("docker compose port disagrees for {0} of {1}: {2}" -f $bad.Count, $want.Count, ($bad -join '; '))
    }
    else {
        Add-Result -Id 'F-JDWP-03-compose' -Status 'PASS' -Req @('R11') -Evidence @($ev) -Message "docker compose port: every service's 5005 is 127.0.0.1:<its debug port> (5005-5016 in the README's order), and every app, postgres, kafka and webapp port is on 127.0.0.1"
    }
}

# This machine's address on the network it shares with others: an up,
# non-loopback IPv4, preferring an interface with a default gateway and not a
# virtual one (vEthernet (WSL), docker0, VPN tunnels).
function Stack-LanAddress {
    $cands = [System.Collections.Generic.List[object]]::new()
    foreach ($ni in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($ni.OperationalStatus -ne [System.Net.NetworkInformation.OperationalStatus]::Up) { continue }
        $t = $ni.NetworkInterfaceType
        if ($t -eq [System.Net.NetworkInformation.NetworkInterfaceType]::Loopback -or $t -eq [System.Net.NetworkInformation.NetworkInterfaceType]::Tunnel) { continue }
        $props = $null
        try { $props = $ni.GetIPProperties() } catch { continue }
        $gw = $false
        # GatewayAddresses throws on macOS; that only costs the preference.
        try { $gw = @($props.GatewayAddresses | Where-Object { $_.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and $_.Address.ToString() -ne '0.0.0.0' }).Count -gt 0 } catch { $gw = $false }
        $virtual = [bool](($ni.Name + ' ' + $ni.Description) -match '(?i)vEthernet|WSL|Hyper-V|docker|vmnet|VirtualBox|vboxnet|^br-|veth|virbr|bridge|utun|awdl|llw|ZeroTier|Tailscale|VPN')
        foreach ($ua in $props.UnicastAddresses) {
            $a = $ua.Address
            if ($a.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { continue }
            if ([System.Net.IPAddress]::IsLoopback($a)) { continue }
            $s = $a.ToString()
            if ($s.StartsWith('169.254.')) { continue }
            $rank = 0
            if (-not $gw) { $rank += 2 }
            if ($virtual) { $rank += 1 }
            $cands.Add([pscustomobject]@{ Ip = $s; Name = [string]$ni.Name; Rank = $rank })
        }
    }
    $best = @($cands | Sort-Object Rank | Select-Object -First 1)
    if ($best.Count -eq 0) { return $null }
    return $best[0]
}

function Stack-CheckLan {
    $lan = Stack-LanAddress
    if ($null -eq $lan) {
        Add-Result -Id 'F-JDWP-04' -Status 'SKIP' -Req @('R11') -Message 'this machine has no LAN IPv4 address (no up, non-loopback interface with one), so there is nothing to connect from'
        return
    }
    foreach ($port in @(5009, 8080)) {
        $id = "F-JDWP-04-$port"
        $r = Stack-TcpConnect -Address $lan.Ip -Port $port -TimeoutMs 2000
        # The negative result means something only if the same port answers
        # on loopback.
        $lo = Stack-TcpConnect -Address '127.0.0.1' -Port $port -TimeoutMs 2000
        Stack-Note ("LAN {0}:{1}: {2}; loopback: {3}" -f $lan.Ip, $port, $r.How, $lo.How)
        if ($r.Connected) {
            Add-Result -Id $id -Status 'FAIL' -Req @('R11') -Message ("connected to {0}:{1} - this machine's address on {2} - so the port is published beyond 127.0.0.1 and anyone on that network can reach it" -f $lan.Ip, $port, $lan.Name)
        }
        elseif (-not $lo.Connected) {
            Add-Result -Id $id -Status 'WARN' -Req @('R11') -Message ("{0}:{1} ({2}) is not reachable ({3}), but neither is 127.0.0.1:{1} ({4}), so this proves nothing" -f $lan.Ip, $port, $lan.Name, $r.How, $lo.How)
        }
        else {
            Add-Result -Id $id -Status 'PASS' -Req @('R11') -Message ("{0}:{1} ({2}) is not reachable ({3}, {4}ms) while 127.0.0.1:{1} is" -f $lan.Ip, $port, $lan.Name, $r.How, $r.Ms)
        }
    }
}

# ---------------------------------------------------------------------------
# F-JDWP-05: what the committed files tell you to attach to
# ---------------------------------------------------------------------------

# A committed IDE attach configuration is one every clone inherits: a
# localhost in it lands on ::1 first on Windows (nothing listens there), and
# any other host is somebody else's machine.
function Stack-CheckAttachConfigs {
    $h = Get-Harness
    $repos = @(Get-ChildItem -LiteralPath $h.SiblingsRoot -Directory -Filter 'home-crew-*' | Sort-Object Name)
    if (-not $h.Git) {
        Add-Result -Id 'F-JDWP-05-attach' -Status 'SKIP' -Req @('R11') -Message 'git is not on PATH, so the committed files cannot be listed'
        return
    }
    $scanned = [System.Collections.Generic.List[string]]::new()
    $bad = [System.Collections.Generic.List[string]]::new()
    $good = [System.Collections.Generic.List[string]]::new()
    $notGit = @()
    foreach ($d in $repos) {
        if (-not (Test-Path -LiteralPath (Join-Path $d.FullName '.git'))) { $notGit += $d.Name; continue }
        $r = Invoke-Git $d.FullName @('ls-files', '-z', '--', '.vscode/launch.json', '.idea/runConfigurations', '.idea/workspace.xml', '.run', '*.launch')
        if ($r.ExitCode -ne 0) { $bad.Add("$($d.Name): git ls-files failed ($(Stack-FirstLine $r.StdErr))"); continue }
        foreach ($rel in @(([string]$r.StdOut).Split([char]0) | Where-Object { $_ })) {
            $scanned.Add("$($d.Name)/$rel")
            $p = Join-Path $d.FullName $rel
            if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { continue }
            $text = [System.IO.File]::ReadAllText($p)
            $ports = @([regex]::Matches($text, '(?<![0-9])50(?:0[5-9]|1[0-6])(?![0-9])') | ForEach-Object { $_.Value } | Sort-Object -Unique)
            if ($ports.Count -eq 0) { continue }
            # VS Code (hostName), IntelliJ (<option name="HOST">) and Eclipse
            # (mapEntry key="hostname").
            $hosts = @(
                @([regex]::Matches($text, '"(?:hostName|host|address)"\s*:\s*"([^"]*)"') | ForEach-Object { $_.Groups[1].Value })
                @([regex]::Matches($text, 'name="HOST"\s+value="([^"]*)"') | ForEach-Object { $_.Groups[1].Value })
                @([regex]::Matches($text, 'key="hostname"\s+value="([^"]*)"') | ForEach-Object { $_.Groups[1].Value })
            )
            $wrong = @($hosts | Where-Object { $_ -ne '127.0.0.1' } | Sort-Object -Unique)
            if ($hosts.Count -eq 0) { $bad.Add("$($d.Name)/$rel references $($ports -join ',') without a host, and the IDE default is localhost") }
            elseif ($wrong.Count) { $bad.Add("$($d.Name)/$rel references $($ports -join ',') on $($wrong -join ', ')") }
            else { $good.Add("$($d.Name)/$rel") }
        }
    }
    $skipped = if ($notGit.Count) { " Not git checkouts, not scanned: $($notGit -join ', ')." } else { '' }
    $count = "$($repos.Count - $notGit.Count) repositories"
    if ($bad.Count) {
        Add-Result -Id 'F-JDWP-05-attach' -Status 'FAIL' -Req @('R11') -Message ("committed IDE attach configurations that point a debug port anywhere but 127.0.0.1: {0}.{1}" -f ($bad -join '; '), $skipped)
    }
    elseif ($good.Count) {
        Add-Result -Id 'F-JDWP-05-attach' -Status 'PASS' -Req @('R11') -Message ("{0} committed attach configuration(s) reference 5005-5016, all on 127.0.0.1: {1} (of {2} tracked IDE files in {3}).{4}" -f $good.Count, ($good -join ', '), $scanned.Count, $count, $skipped)
    }
    else {
        Add-Result -Id 'F-JDWP-05-attach' -Status 'PASS' -Req @('R11') -Message ("no committed IDE configuration in the {0} references 5005-5016 ({1} tracked IDE file(s) scanned{2}).{3}" -f $count, $scanned.Count, $(if ($scanned.Count) { ': ' + ($scanned -join ', ') } else { '' }), $skipped)
    }
}

# compose.dev.yml's published ports per service, read from the file itself -
# the committed text, whether or not docker is here to render it.
function Stack-ComposeDevPorts {
    $h = Get-Harness
    $map = @{}
    $cur = $null
    $inServices = $false
    foreach ($l in [System.IO.File]::ReadAllLines((Join-Path $h.InfraRoot 'compose.dev.yml'))) {
        if ($l -match '^\s*(#|$)') { continue }
        if ($l -match '^services:\s*$') { $inServices = $true; continue }
        if ($l -match '^\S') { $inServices = $false; $cur = $null; continue }
        if (-not $inServices) { continue }
        $m = [regex]::Match($l, '^  ([a-z0-9][a-z0-9-]*):\s*$')
        if ($m.Success) { $cur = $m.Groups[1].Value; $map[$cur] = [System.Collections.Generic.List[object]]::new(); continue }
        $m = [regex]::Match($l, '^\s+-\s+"?(?:(\d{1,3}(?:\.\d{1,3}){3}):)?(\d+):(\d+)(?:/tcp)?"?\s*$')
        if ($cur -and $m.Success) {
            $map[$cur].Add([pscustomobject]@{ Ip = $m.Groups[1].Value; Host = [int]$m.Groups[2].Value; Target = [int]$m.Groups[3].Value })
        }
    }
    return $map
}

function Stack-FormatPorts {
    param([object[]] $Ports)
    if (@($Ports).Count -eq 0) { return 'nothing' }
    return ((@($Ports) | ForEach-Object { "$(if ($_.Ip) { $_.Ip } else { '*' }):$($_.Host)->$($_.Target)" }) -join ', ')
}

# The README's service table, compose.dev.yml's mapping, and the tables the
# launchers and the compose header print, all saying the same thing.
function Stack-CheckDebugTables {
    $h = Get-Harness
    $svcs = @(Get-JavaServices)
    $names = @($svcs | ForEach-Object { $_.Name })
    $compose = Stack-ComposeDevPorts

    # compose.dev.yml is the truth; the harness's own table must agree with
    # it, or every other check here would be testing the wrong port.
    $mapping = @{}
    $problems = [System.Collections.Generic.List[string]]::new()
    foreach ($s in $svcs) {
        $ports = @()
        if ($compose.ContainsKey($s.Name)) { $ports = @($compose[$s.Name]) }
        $dbg = @($ports | Where-Object { $_.Target -eq 5005 })
        $app = @($ports | Where-Object { $_.Target -eq $s.Port })
        if ($dbg.Count -eq 1 -and $dbg[0].Ip -eq '127.0.0.1' -and $app.Count -eq 1 -and $app[0].Ip -eq '127.0.0.1' -and $app[0].Host -eq $s.Port) {
            $mapping[$s.Name] = [pscustomobject]@{ App = $app[0].Host; Debug = $dbg[0].Host }
            if ($dbg[0].Host -ne $s.Debug) { $problems.Add("compose.dev.yml maps $($s.Name) 5005 to $($dbg[0].Host), but the harness expects $($s.Debug) (test/lib/Harness.ps1)") }
        }
        else {
            $problems.Add("compose.dev.yml publishes $($s.Name) as $(Stack-FormatPorts $ports), not 127.0.0.1:$($s.Port)->$($s.Port) plus one 127.0.0.1:<debug>->5005")
        }
    }

    $readme = Join-Path $h.InfraRoot 'README.md'
    $rows = @{}
    if (-not (Test-Path -LiteralPath $readme -PathType Leaf)) { $problems.Add('README.md is missing') }
    else {
        foreach ($l in [System.IO.File]::ReadAllLines($readme)) {
            $m = [regex]::Match($l, '^\|\s*`?([a-z][a-z0-9-]*)`?\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*$')
            if (-not $m.Success -or $names -notcontains $m.Groups[1].Value) { continue }
            $n = $m.Groups[1].Value
            if ($rows.ContainsKey($n)) { $problems.Add("README.md lists $n twice") }
            $rows[$n] = [pscustomobject]@{ App = [int]$m.Groups[2].Value; Debug = [int]$m.Groups[3].Value }
        }
        foreach ($s in $svcs) {
            if (-not $rows.ContainsKey($s.Name)) { $problems.Add("README.md's debug table has no row for $($s.Name)"); continue }
            if (-not $mapping.ContainsKey($s.Name)) { continue }
            $r = $rows[$s.Name]
            $c = $mapping[$s.Name]
            if ($r.App -ne $c.App -or $r.Debug -ne $c.Debug) { $problems.Add("README.md says $($s.Name) is $($r.App)/debug $($r.Debug), compose.dev.yml publishes $($c.App)/debug $($c.Debug)") }
        }
    }
    if ($problems.Count) {
        Add-Result -Id 'F-JDWP-05-readme' -Status 'FAIL' -Req @('R11') -Message ($problems -join '; ')
    }
    else {
        Add-Result -Id 'F-JDWP-05-readme' -Status 'PASS' -Req @('R11') -Message "README.md's table matches compose.dev.yml for all 12: app port and debug port, every one on 127.0.0.1 (5005 for service-discovery up to 5016 for assignment-service)"
    }

    # The tables ./dev and .\dev.ps1 print after `up`, and the compose.dev.yml
    # header: the ones you read while attaching.
    $bannerProblems = [System.Collections.Generic.List[string]]::new()
    foreach ($f in @('dev', 'dev.ps1', 'compose.dev.yml')) {
        $p = Join-Path $h.InfraRoot $f
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { $bannerProblems.Add("$f is missing"); continue }
        $text = [System.IO.File]::ReadAllText($p)
        $said = @{}
        foreach ($m in [regex]::Matches($text, '\b([a-z]+(?:-[a-z]+)+)\s+(50(?:0[5-9]|1[0-6]))\b')) {
            $n = $m.Groups[1].Value
            if ($names -contains $n) { $said[$n] = [int]$m.Groups[2].Value }
        }
        foreach ($s in $svcs) {
            if (-not $mapping.ContainsKey($s.Name)) { continue }
            if (-not $said.ContainsKey($s.Name)) { $bannerProblems.Add("$f's debug-port table has no $($s.Name)"); continue }
            if ($said[$s.Name] -ne $mapping[$s.Name].Debug) { $bannerProblems.Add("$f says $($s.Name) $($said[$s.Name]), compose.dev.yml publishes $($mapping[$s.Name].Debug)") }
        }
    }
    if ($bannerProblems.Count) {
        Add-Result -Id 'F-JDWP-05-banners' -Status 'FAIL' -Req @('R11') -Message ($bannerProblems -join '; ')
    }
    else {
        Add-Result -Id 'F-JDWP-05-banners' -Status 'PASS' -Req @('R11') -Message 'the debug-port tables in dev, dev.ps1 and the compose.dev.yml header match compose.dev.yml for all 12'
    }
}

# ---------------------------------------------------------------------------
# F-IDLE: once up, nothing rebuilds or restarts by itself
# ---------------------------------------------------------------------------

function Stack-RestartInfo {
    param([string] $Container)
    $r = Invoke-Docker @('inspect', '-f', '{{.RestartCount}}|{{.State.StartedAt}}', $Container) -TimeoutSec 60
    if ($r.ExitCode -ne 0) { return "? ($(Stack-FirstLine $r.StdErr))" }
    return $r.StdOut.Trim()
}

function Stack-CheckIdle {
    param([object] $Ready)
    $ok = [System.Collections.Generic.List[object]]::new()
    foreach ($x in $Ready.States.Values) {
        if ($x.Ok) { $ok.Add($x); continue }
        Add-Result -Id "F-IDLE-$($x.Svc.Name)" -Status 'SKIP' -Req @('R4') -Message "not checked: the service never became ready (see F-READY-$($x.Svc.Name))"
    }
    if ($ok.Count -eq 0) { return }

    # The window starts well after the last service came up: its own
    # registration, a first Eureka fetch and the like are start-up, not idling.
    if ($null -ne $Ready.AllReadyAt) {
        $wait = ($Ready.AllReadyAt.AddSeconds($script:StackSettleSec) - [DateTime]::UtcNow).TotalSeconds
        if ($wait -gt 0) { Start-Sleep -Seconds ([int][Math]::Ceiling($wait)) }
    }
    $before = @{}
    foreach ($x in $ok) { $before[$x.Svc.Name] = Stack-RestartInfo $x.Ctr }
    # The Docker VM's clock, not this machine's: docker logs --since compares
    # against timestamps the daemon wrote, and a WSL2 VM drifts.
    $since = Get-DockerNow
    if (-not $since) {
        $d = Stack-Exec -Container $ok[0].Ctr -Command @('date', '-u', '+%Y-%m-%dT%H:%M:%S.%NZ')
        if ($d.ExitCode -eq 0) { $since = $d.StdOut.Trim() }
    }
    if (-not $since) {
        foreach ($x in $ok) { Add-Result -Id "F-IDLE-$($x.Svc.Name)" -Status 'FAIL' -Req @('R4') -Message 'could not read the Docker VM clock to start the idle window' }
        return
    }
    Write-Host "  idle window: ${script:StackIdleSec}s from $since, watching for any rebuild or restart..." -ForegroundColor DarkGray
    Start-Sleep -Seconds $script:StackIdleSec

    foreach ($x in $ok) {
        $id = "F-IDLE-$($x.Svc.Name)"
        $r = Invoke-Docker @('logs', '--since', $since, $x.Ctr) -TimeoutSec 120
        $all = @(([string]$r.StdOut + "`n" + [string]$r.StdErr) -split "`r?`n" | Where-Object { $_ })
        $hits = @($all | Where-Object { $_ -match $script:StackIdleRe })
        $after = Stack-RestartInfo $x.Ctr
        $hr = Stack-Http ("http://127.0.0.1:{0}/actuator/health" -f $x.Svc.Port) -TimeoutSec 20
        $hst = Stack-HealthStatus $hr.Body
        $keep = $all
        if ($keep.Count -gt 3000) { $keep = $keep[($keep.Count - 3000)..($keep.Count - 1)] }
        $ev = Save-Evidence -Suite 'stack' -Name "idle/$($x.Svc.Name).log" -Content ("# docker logs --since $since $($x.Ctr)`n# RestartCount|StartedAt before: $($before[$x.Svc.Name]) after: $after`n" + ($keep -join "`n"))
        $problems = @()
        if ($r.ExitCode -ne 0) { $problems += "docker logs failed: $(Stack-FirstLine $r.StdErr)" }
        if ($hits.Count) { $problems += ("{0} rebuild/restart line(s) in the window, the first: {1}" -f $hits.Count, (Stack-Cut $hits[0] 200)) }
        if ($before[$x.Svc.Name] -ne $after) { $problems += "the container restarted: RestartCount|StartedAt went from $($before[$x.Svc.Name]) to $after" }
        if ($hst -ne 'UP') { $problems += "health is no longer UP: $(Stack-DescribeHealth $hr.Code $hst $hr.Error $hr.Body)" }
        if ($problems.Count) {
            Add-Result -Id $id -Status 'FAIL' -Req @('R4') -Evidence @($ev) -Message ("{0}, {1}s idle: {2}" -f $x.Ctr, $script:StackIdleSec, ($problems -join '; '))
        }
        else {
            Add-Result -Id $id -Status 'PASS' -Req @('R4') -Evidence @($ev) -Message ("{0}, {1}s idle: no build, compile, start, exit, restart or DevTools line; RestartCount unchanged; health still UP" -f $x.Ctr, $script:StackIdleSec)
        }
    }
}
