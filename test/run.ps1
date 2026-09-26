#Requires -Version 7.2
# Verification harness for the local dev setup. See test/README.md.
#
#   pwsh -NoProfile -ExecutionPolicy Bypass -File .\test\run.ps1 -Suite quick
#   pwsh -NoProfile -ExecutionPolicy Bypass -File .\test\run.ps1 -Suite all
#   pwsh -NoProfile -File .\test\run.ps1 -Restore <run-id>
#
# quick = static + cli + unit (no running stack; about ten minutes).
# all   = every suite; non-destructive unless you add the opt-in switches.
#
# This file may use a param() block, unlike dev.ps1: it is a PowerShell 7
# program with its own switches, and nothing it receives is passed on.

param(
    # quick, all, or any of: static cli unit concurrency parity stack reload
    # lifecycle mutation. Comma-separated works too, which is what
    # `pwsh -File run.ps1 -Suite static,cli` passes (one string).
    [string[]] $Suite = @('quick'),

    # The commit the parity and mutation suites compare against; defaults to
    # the infra entry in test/baseline-refs.tsv.
    [string] $BaselineRef,

    # Also run the cold start against your REAL Maven cache (it is deleted and
    # downloaded again). Off by default.
    [switch] $ColdRealMavenVolume,

    # Also run `.\dev.ps1 down -v` against your REAL stack, emptying its
    # databases. Off by default.
    [switch] $AllowDataLoss,

    # Leave the isolated homecrew-test project running afterwards, to poke at.
    [switch] $KeepTestProject,

    # Also exercise ./dev through WSL where it is installed.
    [switch] $WithWsl,

    # Put back the files a crashed run had edited (hash-guarded: nothing you
    # changed since is overwritten).
    [string] $Restore
)

$ErrorActionPreference = 'Stop'
$InfraRoot = Split-Path -Parent $PSScriptRoot

. (Join-Path $PSScriptRoot 'lib/Harness.ps1')
foreach ($f in Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'lib') -Filter 'Suite*.ps1' | Sort-Object Name) { . $f.FullName }

if ($Restore) {
    $dir = Join-Path (Join-Path $PSScriptRoot 'results') (Join-Path $Restore 'manifests')
    if (-not (Test-Path -LiteralPath $dir)) { [Console]::Error.WriteLine("no manifests for run '$Restore' under $dir"); exit 2 }
    # Restore-EditManifest needs nothing but the manifest files, so no harness
    # context - and no new results directory - is created for it.
    $refusedAll = @()
    foreach ($m in Get-ChildItem -LiteralPath $dir -Filter '*.json') {
        $refused = @(Restore-EditManifest -ManifestPath $m.FullName)
        $refusedAll += $refused
        Write-Host "restored from $($m.Name)$(if ($refused) { " - REFUSED (changed since the harness wrote them): $($refused -join ', ')" })"
    }
    exit ([int]($refusedAll.Count -gt 0))
}

$order = @('static', 'cli', 'unit', 'concurrency', 'parity', 'stack', 'reload', 'lifecycle', 'mutation')
$requested = @($Suite | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
$unknown = @($requested | Where-Object { $_ -notin (@('quick', 'all') + $order) })
if ($unknown.Count) {
    [Console]::Error.WriteLine("unknown suite(s): $($unknown -join ', '). Use quick, all, or: $($order -join ' ')")
    exit 2
}
$wanted = [System.Collections.Generic.List[string]]::new()
foreach ($s in $requested) {
    switch ($s) {
        'quick' { foreach ($x in @('static', 'cli', 'unit')) { if (-not $wanted.Contains($x)) { $wanted.Add($x) } } }
        'all'   { foreach ($x in $order) { if (-not $wanted.Contains($x)) { $wanted.Add($x) } } }
        default { if (-not $wanted.Contains($s)) { $wanted.Add($s) } }
    }
}
$run = @($order | Where-Object { $wanted.Contains($_) })

$options = @{
    BaselineRef         = $BaselineRef
    ColdRealMavenVolume = [bool]$ColdRealMavenVolume
    AllowDataLoss       = [bool]$AllowDataLoss
    KeepTestProject     = [bool]$KeepTestProject
    WithWsl             = [bool]$WithWsl
    Suites              = $run
}

$savedEncoding = [Console]::OutputEncoding
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$harnessError = $false
$bad = 0
try {
    $h = Initialize-Harness -InfraRoot $InfraRoot -Options $options
    Register-EnvSecrets
    # What every sibling repository looks like before anything runs, compared
    # again at the very end (A-PROD-03): nothing the harness does may leave a
    # commit, a modified file or a changed .git/config behind.
    if (Get-Command Save-SiblingSnapshot -ErrorAction SilentlyContinue) { Save-SiblingSnapshot }
    Write-Host "HomeCrew dev-setup verification - run $($h.RunId)" -ForegroundColor White
    Write-Host "suites: $($run -join ', ')"
    Write-Host "results: $($h.ResultsDir)"
    Write-Environment | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }

    foreach ($s in $run) {
        $fn = 'Invoke-Suite' + $s.Substring(0, 1).ToUpperInvariant() + $s.Substring(1)
        if (-not (Get-Command $fn -CommandType Function -ErrorAction SilentlyContinue)) {
            Enter-Suite $s 'not available'
            Add-Result -Id "$s-MISSING" -Status 'SKIP' -Message "lib/Suite$($s.Substring(0, 1).ToUpperInvariant() + $s.Substring(1)).ps1 is not present"
            continue
        }
        try { & $fn }
        catch {
            $harnessError = $true
            Add-Result -Suite $s -Id "$s-HARNESS-ERROR" -Status 'FAIL' -Message ("harness error: {0} at {1}" -f $_.Exception.Message, $_.InvocationInfo.PositionMessage -replace "`r?`n", ' ')
        }
    }
}
catch {
    # Outside any suite - setup itself failed. That is a harness error (exit
    # 2), not a verdict about the dev setup (exit 1).
    $harnessError = $true
    [Console]::Error.WriteLine("harness error: $($_.Exception.Message)")
    [Console]::Error.WriteLine($_.InvocationInfo.PositionMessage)
}
finally {
    if ($script:Hc) {
        # The isolated test project never outlives the run unless asked.
        if (-not $KeepTestProject -and $script:Hc.Docker) {
            try {
                # The containers suites start themselves (hct-*) first: one
                # that Ctrl+C interrupted is still running, and would keep the
                # test Maven volume in use.
                $names = (Invoke-Docker @('ps', '-a', '--format', '{{.Names}}') -TimeoutSec 120).StdOut -split "`r?`n"
                foreach ($c in @($names | Where-Object { $_ -like 'hct-*' })) { Invoke-Docker @('rm', '-f', $c) -TimeoutSec 120 | Out-Null }
                $ps = Invoke-TestCompose @('ps', '-a', '-q') -TimeoutSec 120
                if ($ps.StdOut.Trim()) { Invoke-TestCompose @('down', '-v', '--remove-orphans') -TimeoutSec 600 | Out-Null }
                $v = Invoke-Docker @('volume', 'inspect', $script:TestMavenVol) -TimeoutSec 60
                if ($v.ExitCode -eq 0) { Invoke-Docker @('volume', 'rm', $script:TestMavenVol) -TimeoutSec 120 | Out-Null }
            }
            catch { Write-Warning "cleaning up the test project failed: $($_.Exception.Message)" }
        }
        $script:CurrentSuite = 'final'
        if (Get-Command Compare-SiblingSnapshot -ErrorAction SilentlyContinue) {
            try { Compare-SiblingSnapshot -Suite 'final' }
            catch { Add-Result -Id 'A-PROD-03' -Status 'FAIL' -Message "comparing the sibling repositories failed: $($_.Exception.Message)" }
        }
        $hits = @(Test-ResultsForSecrets)
        if ($hits.Count) { Add-Result -Id 'SECRET-SCAN' -Status 'FAIL' -Message "values from .env appear in: $($hits -join ', ')" }
        else { Add-Result -Id 'SECRET-SCAN' -Status 'PASS' -Message 'no value from .env appears anywhere in the results' }
        $bad = Write-Summary
        Write-Host ''
        Write-Host "summary: $(Join-Path $script:Hc.ResultsDir 'summary.md')" -ForegroundColor White
    }
    [Console]::OutputEncoding = $savedEncoding
}

if ($harnessError) { exit 2 }
if ($bad -gt 0) { exit 1 }
exit 0
