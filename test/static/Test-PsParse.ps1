# Parses PowerShell files with the parser of whichever PowerShell runs this,
# and checks the bytes that Windows PowerShell 5.1 is sensitive to. Suite A
# (test/lib/SuiteStatic.ps1) runs it twice, as separate processes:
#
#     %SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File test\static\Test-PsParse.ps1 <file>...
#     pwsh -NoProfile -File test/static/Test-PsParse.ps1 <file>...
#
# Output, one line per file, tab-separated, after one ENGINE line that says
# which PowerShell actually did the parsing:
#
#     ENGINE  <PSVersion>  <PSEdition>  <LanguageMode>
#     PARSE   <file>       OK|FAIL      <detail>
#
# The exit code is the number of files that failed (capped at 255, so that it
# cannot wrap round to 0 on a Unix exit status).
#
# Why both parsers: pwsh 7 accepts syntax that 5.1 rejects (&&, ||, ??, the
# ternary), and 5.1 reads a file without a BOM as ANSI, not UTF-8. A single
# UTF-8 em-dash is three bytes, the last of which 5.1 decodes as a curly double
# quote - and PowerShell treats that as a string delimiter, so the file stops
# parsing a long way from the character that caused it. Hence the byte checks:
# the .ps1 files are kept ASCII-only, with no BOM.
#
# THIS FILE ITSELF RUNS UNDER 5.1, so it uses only 5.1 syntax and APIs: no
# ternary, no ??, no && or ||, New-Object rather than ::new(), and no param()
# block - with [Parameter()] it would become an advanced script, and a file
# argument that starts with a dash would bind to a common parameter.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

function Get-OneLine {
    param([string] $Text)
    if ($null -eq $Text) { return '' }
    return (($Text -replace "[`t`r`n]+", ' ').Trim())
}

function Write-Row {
    param([string] $File, [string] $Status, [string] $Detail)
    Write-Output ("PARSE`t{0}`t{1}`t{2}" -f (Get-OneLine $File), $Status, (Get-OneLine $Detail))
}

# The language mode too: under an AppLocker or WDAC policy PowerShell runs in
# ConstrainedLanguage, where the parser API below is off limits, and the caller
# has to report that as a policy block rather than as a parse failure.
$edition = 'Desktop'
if ($PSVersionTable.ContainsKey('PSEdition')) { $edition = [string]$PSVersionTable.PSEdition }
Write-Output ("ENGINE`t{0}`t{1}`t{2}" -f $PSVersionTable.PSVersion, $edition, $ExecutionContext.SessionState.LanguageMode)

$files = @($args)
if ($files.Count -eq 0) {
    [Console]::Error.WriteLine('usage: Test-PsParse.ps1 <file>...')
    exit 1
}

# ISO-8859-1 maps every byte to the char with the same number, so a regex over
# the decoded string finds the offending BYTES, not whatever a UTF-8 decoder
# would make of them. Code page 28591 exists in .NET Framework and in .NET.
$latin1 = [System.Text.Encoding]::GetEncoding(28591)

$failures = 0
foreach ($f in $files) {
    $name = [string]$f
    $problems = New-Object System.Collections.ArrayList
    $detail = ''
    try {
        $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($name)
        if (-not [System.IO.File]::Exists($full)) {
            [void]$problems.Add('file not found')
        }
        else {
            $bytes = [System.IO.File]::ReadAllBytes($full)
            $start = 0
            if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
                [void]$problems.Add('starts with a UTF-8 BOM (the .ps1 files are kept ASCII-only, without one)')
                $start = 3
            }
            elseif ($bytes.Length -ge 2 -and (($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) -or ($bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF))) {
                [void]$problems.Add('is UTF-16 (BOM FF FE or FE FF) - Windows PowerShell 5.1 > and Out-File write that')
                $start = 2
            }

            $text = $latin1.GetString($bytes, $start, $bytes.Length - $start)
            $hits = [regex]::Matches($text, '[^\x00-\x7F]')
            if ($hits.Count -gt 0) {
                $first = $hits[0].Index
                $before = $text.Substring(0, $first)
                $line = $before.Split([char]10).Count
                $col = $first - $before.LastIndexOf([char]10)
                [void]$problems.Add(('{0} non-ASCII byte(s), the first (0x{1:X2}) at line {2} column {3}' -f $hits.Count, [int][char]$hits[0].Value, $line, $col))
            }

            $tokens = $null
            $errors = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($full, [ref]$tokens, [ref]$errors)
            $errs = @($errors)
            if ($errs.Count -gt 0) {
                $shown = @()
                foreach ($e in ($errs | Select-Object -First 3)) {
                    $shown += ('line {0} column {1}: {2} [{3}]' -f $e.Extent.StartLineNumber, $e.Extent.StartColumnNumber, $e.Message, $e.ErrorId)
                }
                $more = ''
                if ($errs.Count -gt 3) { $more = (' (and {0} more)' -f ($errs.Count - 3)) }
                [void]$problems.Add(('{0} parse error(s): {1}{2}' -f $errs.Count, ($shown -join '; '), $more))
            }
            $detail = ('{0} bytes, ASCII, no BOM, 0 parse errors' -f $bytes.Length)
        }
    }
    catch {
        [void]$problems.Add(('could not be checked: {0}' -f $_.Exception.Message))
    }

    if ($problems.Count -gt 0) {
        $failures++
        Write-Row $name 'FAIL' ($problems -join '; ')
    }
    else {
        Write-Row $name 'OK' $detail
    }
}

if ($failures -gt 255) { $failures = 255 }
exit $failures
