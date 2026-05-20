param(
    [string]$RepoPath = (Join-Path ([Environment]::GetFolderPath('Desktop')) 'AI_Bridge'),
    [string]$Branch = 'main',
    [string]$BaseVersion,
    [switch]$BumpMinor,
    [string]$CommitMessage
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

function Get-GitStatusLines {
    param([string]$Repo)

    $raw = Invoke-Git -Arguments @('-C', $Repo, 'status', '--porcelain')
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @()
    }

    return @($raw -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Get-Divergence {
    param(
        [string]$Repo,
        [string]$RemoteRef
    )

    $counts = Invoke-Git -Arguments @('-C', $Repo, 'rev-list', '--left-right', '--count', ("HEAD...{0}" -f $RemoteRef))
    $parts = @($counts -split '\s+' | Where-Object { $_ -match '^\d+$' })
    if ($parts.Count -lt 2) {
        throw "Unexpected divergence output: $counts"
    }

    return [PSCustomObject]@{
        Ahead = [int]$parts[0]
        Behind = [int]$parts[1]
    }
}

function Get-ExistingTags {
    param([string]$Repo)

    $raw = Invoke-Git -Arguments @('-C', $Repo, 'tag', '--list', '--sort=version:refname')
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @()
    }

    return @($raw -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Get-LatestBaseVersion {
    param([string[]]$Tags)

    $baseTags = @($Tags | Where-Object { $_ -match '^\d+\.\d+$' })
    if ($baseTags.Count -gt 0) {
        return ($baseTags | Sort-Object { [version]$_ } | Select-Object -Last 1)
    }

    $patchTags = @($Tags | Where-Object { $_ -match '^\d+\.\d+\.\d+$' })
    if ($patchTags.Count -gt 0) {
        $latestPatch = $patchTags | Sort-Object { [version]$_ } | Select-Object -Last 1
        $segments = $latestPatch.Split('.')
        return ("{0}.{1}" -f $segments[0], $segments[1])
    }

    return '1.0'
}

function Get-NextMinorVersion {
    param([string]$BaseVersionValue)

    $segments = $BaseVersionValue.Split('.')
    return ("{0}.{1}" -f [int]$segments[0], ([int]$segments[1] + 1))
}

function Get-TargetVersion {
    param(
        [string[]]$Tags,
        [string]$RequestedBaseVersion,
        [bool]$ShouldBumpMinor
    )

    if (-not [string]::IsNullOrWhiteSpace($RequestedBaseVersion)) {
        if ($RequestedBaseVersion -notmatch '^\d+\.\d+$') {
            throw 'BaseVersion must use X.Y format, for example 1.2'
        }

        if ($Tags -contains $RequestedBaseVersion) {
            throw "Version $RequestedBaseVersion already exists"
        }

        return $RequestedBaseVersion
    }

    $latestBase = Get-LatestBaseVersion -Tags $Tags

    if ($ShouldBumpMinor) {
        $nextMinor = Get-NextMinorVersion -BaseVersionValue $latestBase
        if ($Tags -contains $nextMinor) {
            throw "Version $nextMinor already exists"
        }

        return $nextMinor
    }

    $patchNumbers = @(
        $Tags |
            Where-Object { $_ -match ("^{0}\.\d+$" -f [regex]::Escape($latestBase)) } |
            ForEach-Object { [int]($_.Split('.')[2]) }
    )

    $nextPatch = if ($patchNumbers.Count -gt 0) {
        ($patchNumbers | Measure-Object -Maximum).Maximum + 1
    }
    else {
        1
    }

    return ("{0}.{1}" -f $latestBase, $nextPatch)
}

function Get-DefaultCommitMessage {
    param([string]$Version)

    return ("sync {0} {1}" -f $Version, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
}

function Test-RebaseInProgress {
    param([string]$Repo)

    $gitDir = Join-Path $Repo '.git'
    return (Test-Path -LiteralPath (Join-Path $gitDir 'rebase-merge')) -or
        (Test-Path -LiteralPath (Join-Path $gitDir 'rebase-apply'))
}

$desktopPath = [Environment]::GetFolderPath('Desktop')
$backupRoot = Join-Path $desktopPath 'Backup\AI_Bridge'
$reportRoot = Join-Path $backupRoot 'reports'
$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$backupPath = Join-Path $backupRoot ("AI_Bridge_upload_{0}" -f $timestamp)
$reportPath = Join-Path $reportRoot ("upload_{0}.txt" -f $timestamp)
$remoteRef = "origin/{0}" -f $Branch

New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
New-Item -ItemType Directory -Force -Path $reportRoot | Out-Null

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw 'git is not available in PATH'
}

if (-not (Test-Path -LiteralPath (Join-Path $RepoPath '.git'))) {
    throw "AI_Bridge repository not found at $RepoPath"
}

$report = New-Object System.Collections.Generic.List[string]
$report.Add(("Upload time: {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')))
$report.Add(("Repository path: {0}" -f $RepoPath))
$report.Add(("Branch: {0}" -f $Branch))

try {
    Write-Step 'Backing up current desktop bridge'
    Invoke-RobocopyBackup -Source $RepoPath -Destination $backupPath
    $report.Add(("Backup: {0}" -f $backupPath))

    Write-Step 'Fetching latest remote state'
    Invoke-Git -Arguments @('-C', $RepoPath, 'fetch', 'origin', '--tags', '--prune') | Out-Null

    $beforeStatus = Invoke-Git -Arguments @('-C', $RepoPath, 'status', '--short', '--branch')
    $statusLines = @(Get-GitStatusLines -Repo $RepoPath)
    $tags = @(Get-ExistingTags -Repo $RepoPath)
    $divergence = Get-Divergence -Repo $RepoPath -RemoteRef $remoteRef

    $report.Add('Before status:')
    foreach ($line in ($beforeStatus -split "`r?`n")) {
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            $report.Add(("  {0}" -f $line))
        }
    }
    $report.Add(("Before divergence: ahead {0}, behind {1}" -f $divergence.Ahead, $divergence.Behind))

    if ($statusLines.Count -eq 0 -and $divergence.Ahead -eq 0 -and $divergence.Behind -eq 0) {
        $report.Add('No upload needed: local and remote are already synchronized.')
        $report | Set-Content -LiteralPath $reportPath -Encoding UTF8
        Write-Step 'No upload needed'
        Write-Host 'Local and remote are already synchronized.' -ForegroundColor Yellow
        Write-Host ("Report: {0}" -f $reportPath) -ForegroundColor Green
        exit 0
    }

    $targetVersion = Get-TargetVersion -Tags $tags -RequestedBaseVersion $BaseVersion -ShouldBumpMinor:$BumpMinor.IsPresent
    $finalCommitMessage = if ([string]::IsNullOrWhiteSpace($CommitMessage)) {
        Get-DefaultCommitMessage -Version $targetVersion
    }
    else {
        $CommitMessage
    }

    if ($statusLines.Count -gt 0) {
        Write-Step 'Committing local changes'
        Invoke-Git -Arguments @('-C', $RepoPath, 'add', '-A') | Out-Null
        Invoke-Git -Arguments @('-C', $RepoPath, 'commit', '-m', $finalCommitMessage) | Out-Null
    }

    $divergenceAfterCommit = Get-Divergence -Repo $RepoPath -RemoteRef $remoteRef
    if ($divergenceAfterCommit.Behind -gt 0) {
        Write-Step 'Rebasing local work onto latest remote'
        try {
            Invoke-Git -Arguments @('-C', $RepoPath, 'rebase', $remoteRef) | Out-Null
        }
        catch {
            if (Test-RebaseInProgress -Repo $RepoPath) {
                Invoke-Git -Arguments @('-C', $RepoPath, 'rebase', '--abort') | Out-Null
            }

            $report.Add('Rebase failed: remote changed and auto-merge hit a conflict.')
            $report.Add(("Rebase error: {0}" -f $_.Exception.Message))
            $report | Set-Content -LiteralPath $reportPath -Encoding UTF8
            throw 'Remote changed and local changes conflict. Rebase was aborted safely; check the upload report and resolve manually.'
        }
    }

    $headTags = @(Get-ExistingTags -Repo $RepoPath | Where-Object { $_ -eq $targetVersion })
    if ($headTags.Count -gt 0) {
        throw "Target version $targetVersion already exists after sync; stop to avoid duplicate tagging."
    }

    Write-Step 'Tagging synced version'
    Invoke-Git -Arguments @('-C', $RepoPath, 'tag', '-a', $targetVersion, '-m', ("Version {0}" -f $targetVersion)) | Out-Null

    Write-Step 'Pushing branch and version tag'
    Invoke-Git -Arguments @('-C', $RepoPath, 'push', 'origin', $Branch) | Out-Null
    Invoke-Git -Arguments @('-C', $RepoPath, 'push', 'origin', $targetVersion) | Out-Null

    $afterVersion = Invoke-Git -Arguments @('-C', $RepoPath, 'describe', '--tags', '--always')
    $afterHead = Invoke-Git -Arguments @('-C', $RepoPath, 'rev-parse', '--short', 'HEAD')
    $afterDivergence = Get-Divergence -Repo $RepoPath -RemoteRef $remoteRef

    $report.Add(("Target version: {0}" -f $targetVersion))
    $report.Add(("After version: {0}" -f $afterVersion))
    $report.Add(("After HEAD: {0}" -f $afterHead))
    $report.Add(("After divergence: ahead {0}, behind {1}" -f $afterDivergence.Ahead, $afterDivergence.Behind))
    $report | Set-Content -LiteralPath $reportPath -Encoding UTF8

    Write-Step 'Upload completed'
    Write-Host ("Uploaded version: {0}" -f $targetVersion) -ForegroundColor Green
    Write-Host ("Backup saved to: {0}" -f $backupPath) -ForegroundColor Green
    Write-Host ("Report: {0}" -f $reportPath) -ForegroundColor Green
}
catch {
    if ($report.Count -gt 0) {
        $report | Set-Content -LiteralPath $reportPath -Encoding UTF8
    }

    throw
}
