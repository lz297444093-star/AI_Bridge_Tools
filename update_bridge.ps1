param(
    [string]$RepoUrl = 'https://github.com/lz297444093-star/AI_Bridge.git',
    [string]$Branch = 'main'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}

function Write-Step {
    param([string]$Message)

    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $stdoutFile = [System.IO.Path]::GetTempFileName()
    $stderrFile = [System.IO.Path]::GetTempFileName()

    try {
        & git @Arguments 1> $stdoutFile 2> $stderrFile

        $stdout = if (Test-Path -LiteralPath $stdoutFile) {
            [string](Get-Content -LiteralPath $stdoutFile -Raw)
        }
        else {
            ''
        }

        $stderr = if (Test-Path -LiteralPath $stderrFile) {
            [string](Get-Content -LiteralPath $stderrFile -Raw)
        }
        else {
            ''
        }

        if ($null -eq $stdout) { $stdout = '' }
        if ($null -eq $stderr) { $stderr = '' }

        if ($LASTEXITCODE -ne 0) {
            throw ((($stderr + [Environment]::NewLine + $stdout).Trim()))
        }

        if (-not [string]::IsNullOrWhiteSpace($stderr)) {
            Write-Host ($stderr.TrimEnd())
        }

        return ($stdout.TrimEnd())
    }
    finally {
        Remove-Item -LiteralPath $stdoutFile, $stderrFile -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-RobocopyBackup {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,
        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    $null = & robocopy $Source $Destination /E /R:1 /W:1 /XJ /NFL /NDL /NJH /NJS /NP
    $exitCode = $LASTEXITCODE

    if ($exitCode -ge 8) {
        throw "robocopy backup failed with exit code $exitCode"
    }
}

function Get-FileMap {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    $fileMap = @{}
    $rootItem = Get-Item -LiteralPath $Root

    Get-ChildItem -LiteralPath $rootItem.FullName -Recurse -File -Force |
        Where-Object { $_.FullName -notmatch '\\.git(\\|$)' } |
        ForEach-Object {
            $relativePath = [System.IO.Path]::GetRelativePath($rootItem.FullName, $_.FullName).Replace('\\', '/')
            $fileMap[$relativePath] = [PSCustomObject]@{
                Path = $relativePath
                Length = $_.Length
                Hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
            }
        }

    return $fileMap
}

function Compare-FileMaps {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Current,
        [Parameter(Mandatory = $true)]
        [hashtable]$Latest
    )

    $added = New-Object System.Collections.Generic.List[string]
    $removed = New-Object System.Collections.Generic.List[string]
    $changed = New-Object System.Collections.Generic.List[string]

    $allPaths = New-Object System.Collections.Generic.HashSet[string]
    foreach ($key in $Current.Keys) { $null = $allPaths.Add($key) }
    foreach ($key in $Latest.Keys) { $null = $allPaths.Add($key) }

    foreach ($path in ($allPaths | Sort-Object)) {
        if (-not $Current.ContainsKey($path)) {
            $added.Add($path)
            continue
        }

        if (-not $Latest.ContainsKey($path)) {
            $removed.Add($path)
            continue
        }

        if ($Current[$path].Hash -ne $Latest[$path].Hash) {
            $changed.Add($path)
        }
    }

    return [PSCustomObject]@{
        Added = $added
        Removed = $removed
        Changed = $changed
    }
}

$desktopPath = [Environment]::GetFolderPath('Desktop')
$bridgePath = Join-Path $desktopPath 'AI_Bridge'
$backupRoot = Join-Path $desktopPath 'Backup\AI_Bridge'
$reportRoot = Join-Path $backupRoot 'reports'
$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$backupPath = Join-Path $backupRoot ("AI_Bridge_{0}" -f $timestamp)
$reportPath = Join-Path $reportRoot ("update_{0}.txt" -f $timestamp)
$tempClonePath = Join-Path $env:TEMP ("AI_Bridge_Update_{0}" -f $timestamp)

New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
New-Item -ItemType Directory -Force -Path $reportRoot | Out-Null

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw 'git is not available in PATH'
}

$report = New-Object System.Collections.Generic.List[string]
$report.Add(("Update time: {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')))
$report.Add(("Repository: {0}" -f $RepoUrl))
$report.Add(("Branch: {0}" -f $Branch))
$report.Add(("Desktop bridge: {0}" -f $bridgePath))

try {
    if (Test-Path -LiteralPath $bridgePath) {
        Write-Step 'Backing up current desktop bridge'
        Invoke-RobocopyBackup -Source $bridgePath -Destination $backupPath
        $report.Add(("Backup: {0}" -f $backupPath))
    }
    else {
        $report.Add('Backup: skipped because desktop bridge does not exist yet.')
    }

    if (Test-Path -LiteralPath (Join-Path $bridgePath '.git')) {
        Write-Step 'Fetching latest bridge from GitHub'
        $beforeStatus = Invoke-Git -Arguments @('-C', $bridgePath, 'status', '--short', '--branch')
        $beforeVersion = Invoke-Git -Arguments @('-C', $bridgePath, 'describe', '--tags', '--always', '--dirty')
        Invoke-Git -Arguments @('-C', $bridgePath, 'fetch', 'origin', '--tags', '--prune') | Out-Null
        $remoteVersion = Invoke-Git -Arguments @('-C', $bridgePath, 'describe', '--tags', '--always', ("origin/{0}" -f $Branch))
        $diffText = Invoke-Git -Arguments @('-C', $bridgePath, 'diff', '--name-status', 'HEAD', ("origin/{0}" -f $Branch))

        $report.Add(("Before version: {0}" -f $beforeVersion))
        $report.Add(("Target version: {0}" -f $remoteVersion))
        $report.Add('Before status:')
        foreach ($line in ($beforeStatus -split "`r?`n")) {
            $report.Add(("  {0}" -f $line))
        }

        $report.Add('Git diff against latest:')
        if ([string]::IsNullOrWhiteSpace($diffText)) {
            $report.Add('  No tracked file differences.')
        }
        else {
            foreach ($line in ($diffText -split "`r?`n")) {
                $report.Add(("  {0}" -f $line))
            }
        }

        Write-Step 'Applying latest version over current bridge'
        Invoke-Git -Arguments @('-C', $bridgePath, 'reset', '--hard', ("origin/{0}" -f $Branch)) | Out-Null
        $afterVersion = Invoke-Git -Arguments @('-C', $bridgePath, 'describe', '--tags', '--always')
        $afterHead = Invoke-Git -Arguments @('-C', $bridgePath, 'rev-parse', '--short', 'HEAD')

        $report.Add(("After version: {0}" -f $afterVersion))
        $report.Add(("After HEAD: {0}" -f $afterHead))
    }
    else {
        Write-Step 'Desktop bridge is not a valid git repo, using fresh clone fallback'
        Invoke-Git -Arguments @('clone', '--branch', $Branch, '--single-branch', $RepoUrl, $tempClonePath) | Out-Null
        $afterVersion = Invoke-Git -Arguments @('-C', $tempClonePath, 'describe', '--tags', '--always')

        if (Test-Path -LiteralPath $bridgePath) {
            Write-Step 'Comparing current bridge with latest clone'
            $currentFiles = Get-FileMap -Root $bridgePath
            $latestFiles = Get-FileMap -Root $tempClonePath
            $diff = Compare-FileMaps -Current $currentFiles -Latest $latestFiles

            $report.Add(("Target version: {0}" -f $afterVersion))
            $report.Add(("Added files: {0}" -f $diff.Added.Count))
            $report.Add(("Removed files: {0}" -f $diff.Removed.Count))
            $report.Add(("Changed files: {0}" -f $diff.Changed.Count))

            foreach ($path in $diff.Added) {
                $report.Add(("  A {0}" -f $path))
            }
            foreach ($path in $diff.Removed) {
                $report.Add(("  D {0}" -f $path))
            }
            foreach ($path in $diff.Changed) {
                $report.Add(("  M {0}" -f $path))
            }

            Remove-Item -LiteralPath $bridgePath -Recurse -Force
        }
        else {
            $report.Add(("Target version: {0}" -f $afterVersion))
            $report.Add('Fresh install: desktop bridge was missing.')
        }

        Write-Step 'Installing latest bridge clone to desktop'
        Move-Item -LiteralPath $tempClonePath -Destination $bridgePath
        $afterHead = Invoke-Git -Arguments @('-C', $bridgePath, 'rev-parse', '--short', 'HEAD')
        $report.Add(("After HEAD: {0}" -f $afterHead))
    }

    $report | Set-Content -LiteralPath $reportPath -Encoding UTF8

    Write-Step 'Update completed'
    Write-Host ("Current version: {0}" -f $afterVersion) -ForegroundColor Green
    if (Test-Path -LiteralPath $backupPath) {
        Write-Host ("Backup saved to: {0}" -f $backupPath) -ForegroundColor Green
    }
    Write-Host ("Diff report: {0}" -f $reportPath) -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $tempClonePath) {
        Remove-Item -LiteralPath $tempClonePath -Recurse -Force -ErrorAction SilentlyContinue
    }
}
