[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Path,

    [string]$AutoCADProgId = 'AutoCAD.Application.25',

    [double]$TextHeight = 4.0,
    [double]$ArrowSize = 2.5,
    [double]$OverallScale = 1.0,

    [ValidateRange(30, 1800)]
    [int]$TimeoutSeconds = 300,

    [switch]$KeepWorkFiles
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Convert-ToAcadPath {
    param([Parameter(Mandatory = $true)][string]$Value)
    return ($Value -replace '\\', '/')
}

function Convert-ToLispNumber {
    param([Parameter(Mandatory = $true)][double]$Value)
    return $Value.ToString('0.############', [Globalization.CultureInfo]::InvariantCulture)
}

function Assert-DwgUnlocked {
    param([Parameter(Mandatory = $true)][string]$TargetPath)

    $directory = [IO.Path]::GetDirectoryName($TargetPath)
    $baseName = [IO.Path]::GetFileNameWithoutExtension($TargetPath)
    $lockFiles = @(
        [IO.Path]::Combine($directory, "$baseName.dwl"),
        [IO.Path]::Combine($directory, "$baseName.dwl2")
    )
    $existingLocks = @($lockFiles | Where-Object { Test-Path -LiteralPath $_ })
    if ($existingLocks.Count -gt 0) {
        throw "DWG appears to be open in AutoCAD. Lock file(s): $($existingLocks -join ', ')"
    }

    $stream = $null
    try {
        $stream = [IO.File]::Open(
            $TargetPath,
            [IO.FileMode]::Open,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None
        )
    }
    catch {
        throw "DWG is locked, read-only, or unavailable: $TargetPath. $($_.Exception.Message)"
    }
    finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }
}

function New-VerifiedBackup {
    param([Parameter(Mandatory = $true)][string]$TargetPath)

    $directory = [IO.Path]::GetDirectoryName($TargetPath)
    $baseName = [IO.Path]::GetFileNameWithoutExtension($TargetPath)
    $extension = [IO.Path]::GetExtension($TargetPath)
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $backupLabel = ([string][char]0x4FEE) + ([string][char]0x6539) + ([string][char]0x524D)
    $candidate = [IO.Path]::Combine($directory, "${baseName}_${backupLabel}_${timestamp}${extension}")
    $suffix = 1
    while (Test-Path -LiteralPath $candidate) {
        $candidate = [IO.Path]::Combine($directory, "${baseName}_${backupLabel}_${timestamp}_${suffix}${extension}")
        $suffix++
    }

    Copy-Item -LiteralPath $TargetPath -Destination $candidate

    $sourceItem = Get-Item -LiteralPath $TargetPath
    $backupItem = Get-Item -LiteralPath $candidate
    if ($sourceItem.Length -ne $backupItem.Length) {
        throw "Backup length verification failed: $candidate"
    }

    $sourceHash = (Get-FileHash -LiteralPath $TargetPath -Algorithm SHA256).Hash
    $backupHash = (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash
    if ($sourceHash -ne $backupHash) {
        throw "Backup SHA-256 verification failed: $candidate"
    }

    return [pscustomobject]@{
        Path = $candidate
        Hash = $backupHash
        Length = $backupItem.Length
    }
}

function Read-KeyValueReport {
    param([Parameter(Mandatory = $true)][string]$ReportPath)

    if (-not (Test-Path -LiteralPath $ReportPath)) {
        throw "AutoCAD report was not created: $ReportPath"
    }

    $values = [ordered]@{}
    foreach ($line in Get-Content -LiteralPath $ReportPath -Encoding UTF8) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        $parts = $line -split '=', 2
        if ($parts.Count -eq 2) {
            $values[$parts[0]] = $parts[1]
        }
    }
    return $values
}

function Wait-AutoCADReport {
    param(
        [Parameter(Mandatory = $true)][string]$ReportPath,
        [Parameter(Mandatory = $true)][string]$PhaseName
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $ReportPath) {
            Start-Sleep -Milliseconds 500
            return
        }
        Start-Sleep -Milliseconds 250
    }
    throw "Hidden AutoCAD timed out during $PhaseName after $TimeoutSeconds seconds."
}

function Invoke-ComRetry {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [Parameter(Mandatory = $true)][string]$Operation,
        [int]$RetrySeconds = 60
    )

    $deadline = (Get-Date).AddSeconds($RetrySeconds)
    do {
        try {
            return (& $Action)
        }
        catch {
            $hresult = $_.Exception.HResult
            if (
                $hresult -ne -2147418111 -and
                $hresult -ne -2147417846
            ) {
                throw
            }
            Start-Sleep -Milliseconds 300
        }
    } while ((Get-Date) -lt $deadline)

    throw "AutoCAD remained busy during $Operation for $RetrySeconds seconds."
}

function Close-AutoCADDocument {
    param([object]$Document)

    if ($null -ne $Document) {
        try {
            Invoke-ComRetry `
                -Operation 'document close' `
                -RetrySeconds 30 `
                -Action { $Document.Close($false) } | Out-Null
        }
        catch {
        }
        try {
            [Runtime.InteropServices.Marshal]::FinalReleaseComObject($Document) | Out-Null
        }
        catch {
        }
    }
}

function Restore-FromBackup {
    param(
        [Parameter(Mandatory = $true)][string]$BackupPath,
        [Parameter(Mandatory = $true)][string]$TargetPath,
        [Parameter(Mandatory = $true)][string]$ExpectedHash
    )

    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline) {
        try {
            $stream = [IO.File]::Open(
                $TargetPath,
                [IO.FileMode]::Open,
                [IO.FileAccess]::ReadWrite,
                [IO.FileShare]::None
            )
            $stream.Dispose()
            break
        }
        catch {
            Start-Sleep -Milliseconds 300
        }
    }

    Copy-Item -LiteralPath $BackupPath -Destination $TargetPath -Force
    $restoredHash = (Get-FileHash -LiteralPath $TargetPath -Algorithm SHA256).Hash
    if ($restoredHash -ne $ExpectedHash) {
        throw "Automatic restore verification failed. Restore manually from: $BackupPath"
    }
}

if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    throw 'Run this script with Windows PowerShell -STA so AutoCAD COM automation is reliable.'
}

$target = (Resolve-Path -LiteralPath $Path).Path
if ([IO.Path]::GetExtension($target) -ine '.dwg') {
    throw "Only a single .dwg file is supported: $target"
}

$lispSource = Join-Path $PSScriptRoot 'normalize-dimstyle.lsp'
if (-not (Test-Path -LiteralPath $lispSource)) {
    throw "Bundled AutoLISP file is missing: $lispSource"
}

Assert-DwgUnlocked -TargetPath $target
$backup = New-VerifiedBackup -TargetPath $target
Assert-DwgUnlocked -TargetPath $target

$workRoot = 'C:\Windows\Temp\autocad-normalize-dimstyle'
$workId = [Guid]::NewGuid().ToString('N')
$workDirectory = Join-Path $workRoot $workId
New-Item -ItemType Directory -Path $workDirectory -Force | Out-Null

$targetDirectory = [IO.Path]::GetDirectoryName($target)
$targetBaseName = [IO.Path]::GetFileNameWithoutExtension($target)
$outputPath = [IO.Path]::Combine(
    $targetDirectory,
    "${targetBaseName}_CodexNormalize_${workId}.dwg"
)

$acad = $null
$document = $null
$restored = $false
$phase = 'INITIALIZE'
try {
    $tempLisp = Join-Path $workDirectory 'normalize-dimstyle.lsp'
    $normalizeReportPath = Join-Path $workDirectory 'normalize-report.txt'
    $verifyReportPath = Join-Path $workDirectory 'verify-report.txt'
    Copy-Item -LiteralPath $lispSource -Destination $tempLisp

    $acadLisp = Convert-ToAcadPath $tempLisp
    $acadNormalizeReport = Convert-ToAcadPath $normalizeReportPath
    $acadVerifyReport = Convert-ToAcadPath $verifyReportPath
    $acadOutput = Convert-ToAcadPath $outputPath
    $textValue = Convert-ToLispNumber $TextHeight
    $arrowValue = Convert-ToLispNumber $ArrowSize
    $scaleValue = Convert-ToLispNumber $OverallScale

    $phase = 'START_HIDDEN_AUTOCAD'
    $acad = New-Object -ComObject $AutoCADProgId
    Invoke-ComRetry `
        -Operation 'set hidden visibility' `
        -Action { $acad.Visible = $false } | Out-Null

    $phase = 'OPEN_SOURCE_DWG'
    $document = Invoke-ComRetry `
        -Operation 'open source DWG' `
        -Action { $acad.Documents.Open($target, $false) }
    $normalizeCommand = (
        "(setvar `"SECURELOAD`" 0) " +
        "(load `"$acadLisp`") " +
        "(cnd-normalize `"$acadNormalizeReport`" `"$acadOutput`" " +
        "$textValue $arrowValue $scaleValue `"MHSA-DIM`" `"ISO-25`" `"DIM`") "
    )
    $phase = 'SEND_NORMALIZE_COMMAND'
    Invoke-ComRetry `
        -Operation 'send normalization command' `
        -Action { $document.SendCommand($normalizeCommand) } | Out-Null
    $phase = 'WAIT_NORMALIZE_REPORT'
    Wait-AutoCADReport -ReportPath $normalizeReportPath -PhaseName 'normalization'

    $phase = 'READ_NORMALIZE_REPORT'
    $normalizeReport = Read-KeyValueReport -ReportPath $normalizeReportPath
    if ($normalizeReport['STATUS'] -ne 'SUCCESS' -or $normalizeReport['SAVED'] -ne 'TRUE') {
        throw "Normalization failed in phase $($normalizeReport['PHASE']): $($normalizeReport['MESSAGE'])"
    }
    if (-not (Test-Path -LiteralPath $outputPath)) {
        throw "Normalized temporary DWG was not created: $outputPath"
    }

    Close-AutoCADDocument -Document $document
    $document = $null

    $phase = 'OPEN_NORMALIZED_DWG'
    $document = Invoke-ComRetry `
        -Operation 'open normalized DWG' `
        -Action { $acad.Documents.Open($outputPath, $false) }
    $verifyCommand = (
        "(setvar `"SECURELOAD`" 0) " +
        "(load `"$acadLisp`") " +
        "(cnd-verify `"$acadVerifyReport`" " +
        "$textValue $arrowValue $scaleValue `"ISO-25`" `"DIM`") "
    )
    $phase = 'SEND_VERIFY_COMMAND'
    Invoke-ComRetry `
        -Operation 'send verification command' `
        -Action { $document.SendCommand($verifyCommand) } | Out-Null
    $phase = 'WAIT_VERIFY_REPORT'
    Wait-AutoCADReport -ReportPath $verifyReportPath -PhaseName 'post-save verification'

    $phase = 'READ_VERIFY_REPORT'
    $verifyReport = Read-KeyValueReport -ReportPath $verifyReportPath
    if ($verifyReport['STATUS'] -ne 'SUCCESS') {
        throw "Post-save verification failed in phase $($verifyReport['PHASE']): $($verifyReport['MESSAGE'])"
    }

    Close-AutoCADDocument -Document $document
    $document = $null
    $phase = 'QUIT_HIDDEN_AUTOCAD'
    Invoke-ComRetry `
        -Operation 'quit hidden AutoCAD' `
        -RetrySeconds 30 `
        -Action { $acad.Quit() } | Out-Null
    [Runtime.InteropServices.Marshal]::FinalReleaseComObject($acad) | Out-Null
    $acad = $null

    $phase = 'REPLACE_ORIGINAL'
    Assert-DwgUnlocked -TargetPath $target
    Copy-Item -LiteralPath $outputPath -Destination $target -Force
    $outputHash = (Get-FileHash -LiteralPath $outputPath -Algorithm SHA256).Hash
    $targetHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
    if ($outputHash -ne $targetHash) {
        throw 'Final replacement SHA-256 verification failed.'
    }

    [pscustomobject]@{
        status = 'SUCCESS'
        target = $target
        backup = $backup.Path
        backup_sha256 = $backup.Hash
        final_sha256 = $targetHash
        dimensions = [int]$verifyReport['DIMENSIONS']
        leaders = [int]$verifyReport['LEADERS']
        tolerances = [int]$verifyReport['TOLERANCES']
        total_dimstyle_references = [int]$verifyReport['TOTAL_REFERENCES']
        deleted_dimension_styles = [int]$normalizeReport['DELETED_STYLE_COUNT']
        remaining_local_dimension_styles = @(
            $verifyReport['LOCAL_STYLES'] -split ';;' |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )
        xref_names = @(
            $verifyReport['XREF_NAMES'] -split ';;' |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )
        xref_dependent_dimension_styles = @(
            $verifyReport['XREF_STYLES'] -split ';;' |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )
        final_style = 'ISO-25'
        text_height = [double]$verifyReport['DIMTXT']
        arrow_size = [double]$verifyReport['DIMASZ']
        overall_scale = [double]$verifyReport['DIMSCALE']
        dimension_line_color = 'ByLayer'
        extension_line_color = 'ByLayer'
        dimension_text_color = 'ByLayer'
        decimal_separator = $verifyReport['DIMDSEP']
        dimension_precision = '0.0'
        dimension_decimal_places = [int]$verifyReport['DIMDEC']
        dimension_layer = $verifyReport['DIMENSION_LAYER']
        dimension_layer_mismatch_count = [int]$verifyReport['LAYER_MISMATCH_COUNT']
        text_style = $verifyReport['TEXT_STYLE']
        text_style_fixed_height = [double]$verifyReport['TEXT_STYLE_HEIGHT']
        restored = $false
    } | ConvertTo-Json -Depth 5
}
catch {
    $failure = $_

    Close-AutoCADDocument -Document $document
    $document = $null
    if ($null -ne $acad) {
        try {
            $acad.Quit()
        }
        catch {
        }
        try {
            [Runtime.InteropServices.Marshal]::FinalReleaseComObject($acad) | Out-Null
        }
        catch {
        }
        $acad = $null
    }

    try {
        Restore-FromBackup `
            -BackupPath $backup.Path `
            -TargetPath $target `
            -ExpectedHash $backup.Hash
        $restored = $true
    }
    catch {
        throw "Failure phase: $phase. $($failure.Exception.Message) Automatic restore also failed: $($_.Exception.Message) Backup: $($backup.Path)"
    }

    [pscustomobject]@{
        status = 'FAILED_RESTORED'
        target = $target
        backup = $backup.Path
        failure_phase = $phase
        message = $failure.Exception.Message
        restored = $restored
    } | ConvertTo-Json -Depth 4
    exit 1
}
finally {
    Close-AutoCADDocument -Document $document
    if ($null -ne $acad) {
        try {
            $acad.Quit()
        }
        catch {
        }
        try {
            [Runtime.InteropServices.Marshal]::FinalReleaseComObject($acad) | Out-Null
        }
        catch {
        }
    }

    if (Test-Path -LiteralPath $outputPath) {
        Remove-Item -LiteralPath $outputPath -Force
    }

    if (-not $KeepWorkFiles -and (Test-Path -LiteralPath $workDirectory)) {
        $resolvedWork = (Resolve-Path -LiteralPath $workDirectory).Path
        $resolvedRoot = (Resolve-Path -LiteralPath $workRoot).Path
        if ($resolvedWork.StartsWith($resolvedRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $resolvedWork -Recurse -Force
        }
    }
}
