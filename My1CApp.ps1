<#
.SYNOPSIS
    Автономное приложение для выгрузки конфигураций 1С в Git.
#>

param(
    [string]$AppDir = ""
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# === ПУТИ ПРИЛОЖЕНИЯ ===
if (-not $AppDir -or -not (Test-Path $AppDir)) {
    $AppDir = $null

    if ($PSScriptRoot -and (Test-Path $PSScriptRoot)) {
        $AppDir = $PSScriptRoot
    }
    elseif ($PSCommandPath) {
        $AppDir = Split-Path -Parent $PSCommandPath
    }
    elseif ($MyInvocation.MyCommand.Path) {
        $AppDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    }
    else {
        $AppDir = (Get-Location).Path
    }
}

$AppDir = $AppDir.TrimEnd('\', '/')

$WorkDir          = Join-Path $AppDir "workdir"
$GitDir           = Join-Path $WorkDir "PortableGit"
$GitExe           = Join-Path $GitDir "cmd\git.exe"
$GitHome          = Join-Path $WorkDir "git-home"
$GitRepo          = Join-Path $WorkDir "repo"
$ConfigExportPath = Join-Path $GitRepo "Config"
$ConfigPath       = Join-Path $WorkDir "config.json"
$EmbeddedGit      = Join-Path $AppDir "PortableGit-64-bit.7z.exe"
$AppVersion       = "1.8.0"
$AppGitHubRepo    = "crabopal/1c-git-sync"

# === ГЛОБАЛЬНЫЙ КОНТЕКСТ ПРОГРЕССА ===
$script:ProgressForm          = $null
$script:ProgressLabel         = $null
$script:ProgressBar           = $null
$script:ProgressLog           = $null
$script:ProgressCancelButton  = $null
$script:TimingBox             = $null
$script:MainTabs              = $null
$script:ActionButtons         = @()
$script:CancelRequested       = $false
$script:CurrentProcess        = $null
$script:IsBusy                = $false
$script:DumpWatchTitle        = ""
$script:DumpWatchStarted      = $null
$script:DumpWatchLastPoll     = $null
$script:Ui                    = @{}
$script:LogExpanded           = $false
$script:SetLogExpanded        = $null
$script:LastTimingSummary     = ""
$script:IsUpdating            = $false
$script:LatestRelease         = $null

# === ЛОГИРОВАНИЕ ===
function Get-AppLogPath {
    return (Join-Path $WorkDir "app.log")
}

function Clear-OldLogEntries {
    $logFile = Get-AppLogPath
    if (-not (Test-Path -LiteralPath $logFile)) { return 0 }

    $todayPrefix = "[" + (Get-Date -Format "yyyy-MM-dd") + " "
    try {
        $lines = @(Get-Content -LiteralPath $logFile -Encoding UTF8 -ErrorAction Stop)
        $kept = @($lines | Where-Object { $_ -like ($todayPrefix + "*") })
        if ($kept.Count -eq $lines.Count) { return 0 }
        if ($kept.Count -eq 0) {
            [System.IO.File]::WriteAllText($logFile, "")
        }
        else {
            Set-Content -LiteralPath $logFile -Value $kept -Encoding UTF8
        }
        return ($lines.Count - $kept.Count)
    }
    catch {
        return 0
    }
}

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogLine = "[$Timestamp] [$Level] $Message"

    try {
        if (-not (Test-Path $WorkDir)) {
            New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
        }
        $LogFile = Get-AppLogPath
        Add-Content -Path $LogFile -Value $LogLine -Encoding UTF8
    }
    catch { }

    if ($script:ProgressLog) {
        $script:ProgressLog.AppendText($LogLine + "`r`n")
        $script:ProgressLog.SelectionStart = $script:ProgressLog.Text.Length
        $script:ProgressLog.ScrollToCaret()
        [System.Windows.Forms.Application]::DoEvents()
    }
}

function Set-Status {
    param([string]$Text, [int]$Percent = -1)
    if ($script:ProgressLabel) { $script:ProgressLabel.Text = $Text }
    if ($script:ProgressBar -and $Percent -ge 0) {
        if ($Percent -gt 100) { $Percent = 100 }
        $script:ProgressBar.Value = $Percent
    }
    [System.Windows.Forms.Application]::DoEvents()
}

function Start-DumpWatch {
    param([string]$Title)
    $script:DumpWatchTitle = $Title
    $script:DumpWatchStarted = Get-Date
    $script:DumpWatchLastPoll = [datetime]::MinValue
}

function Stop-DumpWatch {
    $script:DumpWatchTitle = ""
    $script:DumpWatchStarted = $null
    $script:DumpWatchLastPoll = $null
}

function Update-DumpWatchStatus {
    if (-not $script:DumpWatchStarted) { return }
    $now = Get-Date
    if ($script:DumpWatchLastPoll -and ($now - $script:DumpWatchLastPoll).TotalSeconds -lt 2) { return }
    $script:DumpWatchLastPoll = $now

    $elapsed = $now - $script:DumpWatchStarted
    $title = $script:DumpWatchTitle
    if (-not $title) { $title = "Выгрузка" }
    Set-Status -Text ("{0} — {1}" -f $title, (Format-ElapsedTime -Elapsed $elapsed))
}

function Initialize-WorkDir {
    if (-not (Test-Path $WorkDir)) {
        New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
    }
    if (-not (Test-Path $GitHome)) {
        New-Item -ItemType Directory -Path $GitHome -Force | Out-Null
    }
    $removed = Clear-OldLogEntries
    if ($removed -gt 0) {
        Write-Log "Журнал: удалено $removed записей за предыдущие дни"
    }
}

function Test-Cancelled {
    if ($script:CancelRequested) {
        throw (New-Object System.OperationCanceledException("Операция отменена пользователем"))
    }
}

function Stop-TrackedProcess {
    param($Proc)
    if (-not $Proc) { return }
    try {
        if (-not $Proc.HasExited) {
            Start-Process -FilePath "taskkill.exe" `
                -ArgumentList "/PID $($Proc.Id) /T /F" `
                -Wait -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null
        }
    }
    catch { }
    try {
        if (-not $Proc.HasExited) { $Proc.Kill() }
    }
    catch { }
}

function Wait-CancellableProcess {
    param(
        [Parameter(Mandatory = $true)][System.Diagnostics.Process]$Process,
        [int]$PollMs = 300
    )

    $script:CurrentProcess = $Process
    try {
        while (-not $Process.WaitForExit($PollMs)) {
            Update-DumpWatchStatus
            [System.Windows.Forms.Application]::DoEvents()
            if ($script:CancelRequested) {
                Stop-TrackedProcess -Proc $Process
                throw (New-Object System.OperationCanceledException("Операция отменена пользователем"))
            }
        }
        # WaitForExit(timeout) может вернуть управление до появления ExitCode
        $Process.WaitForExit()
    }
    finally {
        $script:CurrentProcess = $null
    }

    $code = $null
    try { $code = $Process.ExitCode } catch { }
    return $code
}

function ConvertTo-ArgString {
    param([string[]]$Parts)
    $escaped = foreach ($p in $Parts) {
        if ($null -eq $p) { '""' }
        elseif ($p -match '^-') { $p }
        else { '"' + ($p -replace '"', '\"') + '"' }
    }
    return ($escaped -join ' ')
}

function Invoke-CancellableProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FileName,
        [string]$ArgumentString = "",
        [string[]]$ArgumentList = $null,
        [string]$WorkingDirectory = "",
        [switch]$IgnoreExitCode,
        [switch]$Quiet
    )

    Test-Cancelled

    if ($ArgumentList) {
        $ArgumentString = ConvertTo-ArgString -Parts $ArgumentList
    }

    $Psi = New-Object System.Diagnostics.ProcessStartInfo
    $Psi.FileName = $FileName
    $Psi.Arguments = $ArgumentString
    $Psi.UseShellExecute = $false
    $Psi.RedirectStandardOutput = $true
    $Psi.RedirectStandardError = $true
    $Psi.CreateNoWindow = $true
    $Psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $Psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    if ($WorkingDirectory) { $Psi.WorkingDirectory = $WorkingDirectory }

    $Proc = New-Object System.Diagnostics.Process
    $Proc.StartInfo = $Psi
    $script:CurrentProcess = $Proc
    $Proc.Start() | Out-Null

    $StdoutTask = $Proc.StandardOutput.ReadToEndAsync()
    $StderrTask = $Proc.StandardError.ReadToEndAsync()

    while (-not $Proc.WaitForExit(300)) {
        Update-DumpWatchStatus
        [System.Windows.Forms.Application]::DoEvents()
        if ($script:CancelRequested) {
            Stop-TrackedProcess -Proc $Proc
            $script:CurrentProcess = $null
            throw (New-Object System.OperationCanceledException("Операция отменена пользователем"))
        }
    }
    $Proc.WaitForExit()
    $script:CurrentProcess = $null

    $Stdout = ""
    $Stderr = ""
    try { $Stdout = $StdoutTask.Result } catch { }
    try { $Stderr = $StderrTask.Result } catch { }

    if ($script:CancelRequested) {
        throw (New-Object System.OperationCanceledException("Операция отменена пользователем"))
    }

    if (-not $Quiet) {
        if ($Stdout) { Write-Log $Stdout.TrimEnd() }
        if ($Stderr) { Write-Log $Stderr.TrimEnd() }
    }

    $exitCode = $null
    try { $exitCode = $Proc.ExitCode } catch { }

    if (-not $IgnoreExitCode -and $null -ne $exitCode -and $exitCode -ne 0) {
        throw "Процесс '$FileName' завершился с кодом $exitCode"
    }

    return [PSCustomObject]@{
        ExitCode = $exitCode
        Stdout   = $Stdout
        Stderr   = $Stderr
    }
}

function Invoke-Git {
    param(
        [string]$GitExe,
        [string[]]$GitArgs,
        [string]$WorkingDirectory = "",
        [switch]$IgnoreExitCode,
        [switch]$Quiet
    )

    $params = @{
        FileName           = $GitExe
        ArgumentList       = $GitArgs
        WorkingDirectory   = $WorkingDirectory
        IgnoreExitCode     = $IgnoreExitCode
        Quiet              = $Quiet
    }
    return Invoke-CancellableProcess @params
}

function Test-GitHeadExists {
    param([string]$GitExe, [string]$RepoDir)
    $r = Invoke-Git -GitExe $GitExe -WorkingDirectory $RepoDir `
        -GitArgs @("rev-parse", "--verify", "HEAD") -IgnoreExitCode -Quiet
    return ($r.ExitCode -eq 0)
}

function Initialize-GitUnbornBranch {
    param([string]$GitExe, [string]$RepoDir, [string]$Branch)
    Write-Log "Локальных коммитов нет — это первый коммит, ветка '$Branch'"
    Invoke-Git -GitExe $GitExe -WorkingDirectory $RepoDir `
        -GitArgs @("symbolic-ref", "HEAD", "refs/heads/$Branch")
}

function Test-GitRemoteBranchExists {
    param([string]$GitExe, [string]$RepoDir, [string]$Branch)
    $ls = Invoke-Git -GitExe $GitExe -WorkingDirectory $RepoDir `
        -GitArgs @("ls-remote", "--heads", "origin", $Branch) -IgnoreExitCode
    return [bool]($ls.Stdout -and $ls.Stdout.Trim())
}

function ConvertTo-ComparableGitUrl {
    param([string]$Url)
    if (-not $Url) { return "" }
    $u = $Url.Trim() -replace '\\', '/'
    $u = $u.TrimEnd('/')
    if ($u.EndsWith(".git", [System.StringComparison]::OrdinalIgnoreCase)) {
        $u = $u.Substring(0, $u.Length - 4)
    }
    return $u.ToLowerInvariant()
}

function Get-GitOriginUrl {
    param([string]$GitExe, [string]$RepoDir)
    $r = Invoke-Git -GitExe $GitExe -WorkingDirectory $RepoDir `
        -GitArgs @("remote", "get-url", "origin") -IgnoreExitCode
    if ($r.Stdout) { return $r.Stdout.Trim().Split("`n")[0].Trim() }
    return ""
}

function Sync-GitOriginUrl {
    param(
        [string]$GitExe,
        [string]$RepoDir,
        [string]$RemoteUrl
    )

    if (-not (Test-Path (Join-Path $RepoDir ".git"))) { return }

    $current = Get-GitOriginUrl -GitExe $GitExe -RepoDir $RepoDir
    if (-not $current) {
        Write-Log "У локального клона нет origin — добавляем $RemoteUrl"
        Invoke-Git -GitExe $GitExe -WorkingDirectory $RepoDir `
            -GitArgs @("remote", "add", "origin", $RemoteUrl)
        return
    }

    if ((ConvertTo-ComparableGitUrl -Url $current) -eq (ConvertTo-ComparableGitUrl -Url $RemoteUrl)) {
        return
    }

    Write-Log "URL в настройках не совпадает с origin локального клона — меняем origin, файлы не удаляем."
    Write-Log "Было: $current"
    Write-Log "Стало: $RemoteUrl"
    Invoke-Git -GitExe $GitExe -WorkingDirectory $RepoDir `
        -GitArgs @("remote", "set-url", "origin", $RemoteUrl)
    Write-Log "origin обновлён. Чтобы удалить локальные файлы и клонировать заново, нажмите «Начать с чистого клона»."
}

function Reset-GitLocalClone {
    param(
        [string]$GitExe,
        [string]$RepoDir,
        [string]$RemoteUrl
    )

    if (-not $RemoteUrl) {
        throw "Не указан URL Git-репозитория"
    }

    Write-Log "Пересоздаём workdir\\repo под $RemoteUrl ..."
    $parent = Split-Path -Parent $RepoDir
    if (-not (Test-Path $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $backup = $null
    if (Test-Path -LiteralPath $RepoDir) {
        $backupName = "repo.bak-" + (Get-Date -Format "yyyyMMdd-HHmmss")
        $backup = Join-Path $parent $backupName
        Rename-Item -LiteralPath $RepoDir -NewName $backupName
    }

    try {
        Invoke-Git -GitExe $GitExe -WorkingDirectory $parent `
            -GitArgs @("clone", $RemoteUrl, $RepoDir)
        Write-Log "Новый клон готов"
        if ($backup) {
            Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $backup) {
                Write-Log "Старый клон не удалось удалить, остался как $backup"
            }
            else {
                Write-Log "Старый клон удалён"
            }
        }
    }
    catch {
        if ($backup -and -not (Test-Path (Join-Path $RepoDir ".git")) -and (Test-Path -LiteralPath $backup)) {
            Rename-Item -LiteralPath $backup -NewName (Split-Path -Leaf $RepoDir)
            Write-Log "Клонирование не удалось, восстановлен прежний каталог repo"
        }
        throw
    }
}

function Set-ProgressCancelEnabled {
    param([bool]$Enabled)
    if ($script:ProgressCancelButton) {
        $script:ProgressCancelButton.Enabled = $Enabled -and -not $script:CancelRequested
        [System.Windows.Forms.Application]::DoEvents()
    }
}

function Get-DialogOwner {
    if ($script:ProgressForm -and -not $script:ProgressForm.IsDisposed) {
        return $script:ProgressForm
    }
    return $null
}

# === АВТООПРЕДЕЛЕНИЕ ПЛАТФОРМЫ 1С ===
function Find-Latest1CPlatform {
    $SearchPaths = @(
        "C:\Program Files\1cv8",
        "C:\Program Files (x86)\1cv8"
    )
    $Candidates = @()

    foreach ($BasePath in $SearchPaths) {
        if (-not (Test-Path $BasePath)) { continue }
        $Dirs = Get-ChildItem -Path $BasePath -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^\d+(\.\d+)+$' }
        foreach ($Dir in $Dirs) {
            $ExePath = Join-Path $Dir.FullName "bin\1cv8.exe"
            if (Test-Path $ExePath) {
                $Candidates += [PSCustomObject]@{
                    Version = $Dir.Name
                    Path    = $ExePath
                }
            }
        }
    }

    if ($Candidates.Count -eq 0) { return $null }

    $Sorted = $Candidates | Sort-Object -Property @{
        Expression = {
            $P = $_.Version -split '\.'
            [int]$P[0] * 1000000 + [int]$P[1] * 10000 + [int]$P[2] * 100 + [int]$P[3]
        }
    } -Descending

    return $Sorted[0].Path
}

function Get-DefaultIBasesV8iPaths {
    $paths = @(
        (Join-Path $env:APPDATA "1C\1CEStart\ibases.v8i"),
        (Join-Path $env:APPDATA "1C\1cv8\ibases.v8i"),
        (Join-Path $env:ProgramData "1C\1CEStart\ibases.v8i")
    )
    if ($env:USERPROFILE) {
        $paths += (Join-Path $env:USERPROFILE "AppData\Roaming\1C\1CEStart\ibases.v8i")
    }
    return @($paths | Where-Object { $_ } | Select-Object -Unique)
}

function Read-IBasesV8iText {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return "" }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -eq 0) { return "" }
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        return [System.Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
    }
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        return [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
    }
    $probe = [Math]::Min(120, $bytes.Length)
    $zeros = 0
    for ($i = 0; $i -lt $probe; $i++) {
        if ($bytes[$i] -eq 0) { $zeros++ }
    }
    if ($zeros -gt 20) {
        return [System.Text.Encoding]::Unicode.GetString($bytes)
    }
    return [System.Text.Encoding]::GetEncoding(1251).GetString($bytes)
}

function Get-IBasesConnectValue {
    param([string]$Connect, [string]$Key)
    $patternQuoted = '(?i)(?:^|;)\s*' + [regex]::Escape($Key) + '\s*=\s*"([^"]*)"'
    if ($Connect -match $patternQuoted) { return $Matches[1].Trim() }
    $patternSingle = '(?i)(?:^|;)\s*' + [regex]::Escape($Key) + "\s*=\s*'([^']*)'"
    if ($Connect -match $patternSingle) { return $Matches[1].Trim() }
    $patternBare = '(?i)(?:^|;)\s*' + [regex]::Escape($Key) + '\s*=\s*([^;]+)'
    if ($Connect -match $patternBare) { return $Matches[1].Trim().Trim('"').Trim("'") }
    return ""
}

function ConvertFrom-IBasesConnect {
    param([string]$Name, [string]$Connect)
    if (-not $Connect) { return $null }
    $c = $Connect.Trim()
    if ($c -match '(?i)(?:^|;)\s*ws\s*=') { return $null }

    $filePath = Get-IBasesConnectValue -Connect $c -Key "File"
    if ($filePath) {
        return [PSCustomObject]@{
            Title    = $Name
            Kind     = "File"
            FilePath = $filePath
            Server   = ""
            Ref      = ""
        }
    }

    $srvr = Get-IBasesConnectValue -Connect $c -Key "Srvr"
    $ref = Get-IBasesConnectValue -Connect $c -Key "Ref"

    if ($srvr -and $ref) {
        return [PSCustomObject]@{
            Title    = $Name
            Kind     = "Server"
            FilePath = ""
            Server   = $srvr
            Ref      = $ref
        }
    }
    return $null
}

function Read-IBasesV8iFile {
    param([string]$Path)
    $bases = New-Object System.Collections.Generic.List[object]
    $text = Read-IBasesV8iText -Path $Path
    if (-not $text) { return }

    $name = $null
    $connect = ""

    foreach ($raw in ($text -split "`r?`n")) {
        $line = $raw.Trim()
        if ($line -match '^\[(.*)\]$') {
            if ($name -and $connect) {
                $item = ConvertFrom-IBasesConnect -Name $name -Connect $connect
                if ($item) { [void]$bases.Add($item) }
            }
            $name = $Matches[1].Trim()
            $connect = ""
            continue
        }
        if ($line -match '^(?i)Connect\s*=\s*(.*)$') {
            $connect = $Matches[1].Trim()
        }
    }
    if ($name -and $connect) {
        $item = ConvertFrom-IBasesConnect -Name $name -Connect $connect
        if ($item) { [void]$bases.Add($item) }
    }
    foreach ($b in $bases) { $b }
}

function Get-1CIbasesList {
    param([string[]]$ExtraFiles = @())
    $files = New-Object System.Collections.Generic.List[string]
    foreach ($p in (Get-DefaultIBasesV8iPaths)) {
        if ($p -and (Test-Path -LiteralPath $p)) { [void]$files.Add($p) }
    }
    foreach ($p in @($ExtraFiles)) {
        if ($p -and (Test-Path -LiteralPath $p) -and -not $files.Contains($p)) { [void]$files.Add($p) }
    }

    $result = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($file in $files) {
        foreach ($item in @(Read-IBasesV8iFile -Path $file)) {
            $key = "$($item.Kind)|$($item.FilePath)|$($item.Server)|$($item.Ref)"
            if ($seen.ContainsKey($key.ToLowerInvariant())) { continue }
            $seen[$key.ToLowerInvariant()] = $true
            $suffix = "файловая"
            if ($item.Kind -eq "Server") { $suffix = "$($item.Server)\$($item.Ref)" }
            else { $suffix = $item.FilePath }
            $item.Title = "$($item.Title)  [$suffix]"
            [void]$result.Add($item)
        }
    }
    foreach ($b in $result) { $b }
}

# === ОКНО ПРОГРЕССА ===
function Show-ProgressForm {
    $script:CancelRequested = $false
    $script:CurrentProcess = $null
    if ($script:ProgressBar) { $script:ProgressBar.Value = 0 }
    if ($script:ProgressCancelButton -and -not $script:ProgressCancelButton.IsDisposed) {
        $script:ProgressCancelButton.Text = "Отмена"
        $script:ProgressCancelButton.Enabled = $true
    }
    [System.Windows.Forms.Application]::DoEvents()
}

function Close-ProgressForm {
    if ($script:ProgressCancelButton -and -not $script:ProgressCancelButton.IsDisposed) {
        $script:ProgressCancelButton.Enabled = $false
        $script:ProgressCancelButton.Text = "Отмена"
    }
    [System.Windows.Forms.Application]::DoEvents()
}

function Set-MainFormBusy {
    param([bool]$Busy)
    $script:IsBusy = $Busy
    if ($script:MainTabs -and -not $script:MainTabs.IsDisposed) {
        $script:MainTabs.Enabled = -not $Busy
    }
    foreach ($btn in @($script:ActionButtons)) {
        if ($btn -and -not $btn.IsDisposed) { $btn.Enabled = -not $Busy }
    }
    if ($script:ProgressBar -and -not $script:ProgressBar.IsDisposed) {
        $script:ProgressBar.Visible = $Busy
        if ($Busy) { $script:ProgressBar.Value = 0 }
    }
    if ($Busy -and $script:SetLogExpanded) {
        & $script:SetLogExpanded $true
    }
    if ($script:ProgressCancelButton -and -not $script:ProgressCancelButton.IsDisposed) {
        $script:ProgressCancelButton.Visible = $true
        $script:ProgressCancelButton.Enabled = $Busy -and -not $script:CancelRequested
        if (-not $Busy) { $script:ProgressCancelButton.Text = "Отмена" }
    }
    [System.Windows.Forms.Application]::DoEvents()
}

function Get-DefaultConfig {
    return [PSCustomObject]@{
        PlatformPath               = ""
        DBType                     = "File"
        InfobasePath               = ""
        User                       = ""
        GitRepoUrl                 = ""
        GitBranch                  = "main"
        AutoConfirmGitPush         = $false
        ExportMainConfig           = $true
        ExportExtensions           = $true
        SelectExtensionsManually   = $false
        ExtensionExcludePrefix     = "EF_"
        DumpMode                   = "Auto"
        LoadMainConfig             = $true
        LoadExtensions             = $true
        LoadSelectExtensionsManually = $false
        UpdateInfobaseCfg          = $true
        DynamicUpdateCfg           = $false
    }
}

function Merge-Config {
    param($Existing)
    $merged = Get-DefaultConfig
    if (-not $Existing) { return $merged }

    foreach ($name in $merged.PSObject.Properties.Name) {
        $prop = $Existing.PSObject.Properties[$name]
        if ($prop) {
            $merged.$name = $prop.Value
        }
    }
    return $merged
}

function Add-FormLabel {
    param($Parent, [string]$Text, [int]$Left, [int]$Top, [int]$Width = 210)
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $Text
    $lbl.Left = $Left; $lbl.Top = $Top; $lbl.Width = $Width
    $Parent.Controls.Add($lbl)
    return $lbl
}

function Add-FormTextBox {
    param($Parent, [int]$Left, [int]$Top, [int]$Width, [string]$Value = "")
    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Left = $Left; $tb.Top = $Top; $tb.Width = $Width
    $tb.Text = $Value
    $Parent.Controls.Add($tb)
    return $tb
}

function Add-FormLinkLabel {
    param($Parent, [string]$Text, [int]$Left, [int]$Top, [int]$Width = 220)
    $lnk = New-Object System.Windows.Forms.LinkLabel
    $lnk.Text = $Text
    $lnk.Left = $Left; $lnk.Top = $Top; $lnk.Width = $Width
    $lnk.Height = 20
    $Parent.Controls.Add($lnk)
    return $lnk
}

function Get-AppVersion {
    $vf = Join-Path $AppDir "VERSION"
    if (Test-Path -LiteralPath $vf) {
        $fromFile = (Get-Content -LiteralPath $vf -Raw -ErrorAction SilentlyContinue)
        if ($fromFile) {
            $v = ($fromFile.Trim() -replace '^[vV]', '')
            if ($v) { return $v }
        }
    }
    return $AppVersion
}

function ConvertTo-AppVersion {
    param([string]$Text)
    $clean = ($Text -replace '^[vV]', '').Trim()
    if ($clean -notmatch '^\d+(\.\d+){1,3}$') { return $null }
    try { return [version]$clean } catch { return $null }
}

function Initialize-Tls12 {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }
    catch { }
}

function Get-LatestAppRelease {
    Initialize-Tls12
    $uri = "https://api.github.com/repos/$AppGitHubRepo/releases/latest"
    $rel = Invoke-RestMethod -Uri $uri -TimeoutSec 20 -Headers @{
        "User-Agent" = "1c-git-sync"
        "Accept"     = "application/vnd.github+json"
    }
    $asset = @($rel.assets) | Where-Object { $_.name -eq "1c-git-sync.zip" } | Select-Object -First 1
    if (-not $asset -or -not $asset.browser_download_url) {
        throw "В последнем релизе нет файла 1c-git-sync.zip"
    }
    $tag = [string]$rel.tag_name
    $ver = ConvertTo-AppVersion -Text $tag
    if (-not $ver) { $ver = ConvertTo-AppVersion -Text ([string]$rel.name) }
    if (-not $ver) { throw "Не удалось разобрать номер версии релиза: $tag" }
    return [PSCustomObject]@{
        Tag     = $tag
        Version = $ver
        Url     = [string]$asset.browser_download_url
        Size    = [int64]$asset.size
    }
}

function Save-HttpFile {
    param([string]$Url, [string]$Dest)
    Initialize-Tls12
    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.Method = "GET"
    $req.UserAgent = "1c-git-sync"
    $req.AllowAutoRedirect = $true
    $req.Timeout = 60000
    $req.ReadWriteTimeout = 300000
    $resp = $req.GetResponse()
    $total = $resp.ContentLength
    $stream = $resp.GetResponseStream()
    $fs = [System.IO.File]::Create($Dest)
    $buf = New-Object byte[] 65536
    $readTotal = [int64]0
    try {
        while (($n = $stream.Read($buf, 0, $buf.Length)) -gt 0) {
            Test-Cancelled
            $fs.Write($buf, 0, $n)
            $readTotal += $n
            if ($total -gt 0) {
                $pct = [int][Math]::Min(100, [Math]::Round(100.0 * $readTotal / $total))
                $mb = [Math]::Round($readTotal / 1MB, 1)
                $all = [Math]::Round($total / 1MB, 1)
                Set-Status -Text ("Скачивание обновления: {0} из {1} МБ ({2}%)" -f $mb, $all, $pct) -Percent $pct
            }
            else {
                Set-Status -Text ("Скачивание обновления: {0} МБ" -f [Math]::Round($readTotal / 1MB, 1))
            }
            [System.Windows.Forms.Application]::DoEvents()
        }
    }
    finally {
        $fs.Dispose()
        $stream.Dispose()
        $resp.Close()
    }
}

function Find-UpdatePayloadDir {
    param([string]$Root)
    $direct = Join-Path $Root "My1CApp.ps1"
    if (Test-Path -LiteralPath $direct) { return $Root }
    $found = Get-ChildItem -LiteralPath $Root -Recurse -Filter "My1CApp.ps1" -File -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($found) { return $found.DirectoryName }
    throw "В архиве обновления нет My1CApp.ps1"
}

function Start-AppSelfUpdate {
    param($Form)

    if ($script:IsBusy) { return }

    $currentText = Get-AppVersion
    $current = ConvertTo-AppVersion -Text $currentText
    if (-not $current) { $current = [version]"0.0.0" }

    try {
        Set-Status -Text "Проверка обновлений..."
        [System.Windows.Forms.Application]::DoEvents()
        $rel = Get-LatestAppRelease
        $script:LatestRelease = $rel
    }
    catch {
        Write-Log "Проверка обновлений не удалась: $_" "ERROR"
        [System.Windows.Forms.MessageBox]::Show(
            "Не удалось проверить обновления:`r`n`r`n$_",
            "1C Git Sync",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        Set-Status -Text "Готово к запуску"
        return
    }

    if ($rel.Version -le $current) {
        [System.Windows.Forms.MessageBox]::Show(
            "Установлена актуальная версия $currentText.",
            "1C Git Sync",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        Set-Status -Text "Готово к запуску"
        return
    }

    $answer = [System.Windows.Forms.MessageBox]::Show(
        "Доступна версия $($rel.Version) (сейчас $currentText).`r`n`r`nСкачать релиз и перезапустить программу?`r`nКаталог workdir не изменяется.",
        "Обновление 1C Git Sync",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
        Set-Status -Text ("Доступна версия {0}" -f $rel.Version)
        return
    }

    $stageRoot = Join-Path $WorkDir "update-staging"
    $zipPath = Join-Path $WorkDir "1c-git-sync-update.zip"
    $script:CancelRequested = $false
    Set-MainFormBusy -Busy $true
    try {
        if (-not (Test-Path $WorkDir)) {
            New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
        }
        if (Test-Path -LiteralPath $stageRoot) {
            Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $zipPath) {
            Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
        }

        Write-Log "Скачивание $($rel.Tag) из $($rel.Url)"
        Save-HttpFile -Url $rel.Url -Dest $zipPath
        Test-Cancelled

        Set-Status -Text "Распаковка обновления..." -Percent 90
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $stageRoot)
        $payload = Find-UpdatePayloadDir -Root $stageRoot
        Write-Log "Пакет обновления: $payload"

        $updPs1 = Join-Path $WorkDir "apply-update.ps1"
        $updText = @"
param([string]`$Src, [string]`$Dst, [int]`$WaitPid)
while (Get-Process -Id `$WaitPid -ErrorAction SilentlyContinue) {
    Start-Sleep -Seconds 1
}
Copy-Item -Path (Join-Path `$Src '*') -Destination `$Dst -Recurse -Force
`$run = Join-Path `$Dst 'run.bat'
if (Test-Path -LiteralPath `$run) {
    Start-Process -FilePath `$run -WorkingDirectory `$Dst
}
`$stage = Split-Path -Parent `$Src
if (`$stage -and ((Split-Path `$stage -Leaf) -eq 'update-staging')) {
    Remove-Item -LiteralPath `$stage -Recurse -Force -ErrorAction SilentlyContinue
}
`$zip = Join-Path `$Dst 'workdir\1c-git-sync-update.zip'
if (Test-Path -LiteralPath `$zip) {
    Remove-Item -LiteralPath `$zip -Force -ErrorAction SilentlyContinue
}
Remove-Item -LiteralPath `$PSCommandPath -Force -ErrorAction SilentlyContinue
"@
        $utf8 = New-Object System.Text.UTF8Encoding $true
        [System.IO.File]::WriteAllText($updPs1, $updText, $utf8)

        $arg = "-NoProfile -ExecutionPolicy Bypass -File `"$updPs1`" `"$payload`" `"$AppDir`" $PID"
        Write-Log "Перезапуск после обновления до $($rel.Version)"
        $script:IsUpdating = $true
        Start-Process -FilePath "powershell.exe" -ArgumentList $arg -WindowStyle Hidden | Out-Null
        if ($Form -and -not $Form.IsDisposed) { $Form.Close() }
    }
    catch [System.OperationCanceledException] {
        Write-Log "Обновление отменено"
        Set-Status -Text "Обновление отменено"
        Set-MainFormBusy -Busy $false
    }
    catch {
        Write-Log "Ошибка обновления: $_" "ERROR"
        Set-MainFormBusy -Busy $false
        Set-Status -Text "Ошибка обновления"
        [System.Windows.Forms.MessageBox]::Show(
            "Не удалось обновить программу:`r`n`r`n$_",
            "1C Git Sync",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    }
}

# === ГЛАВНОЕ ОКНО ===
function Show-SettingsForm {
    param([PSCustomObject]$Existing)

    $Existing = Merge-Config -Existing $Existing

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "1C Git Sync " + (Get-AppVersion)
    $form.Width = 740
    $form.Height = 640
    $form.StartPosition = "CenterScreen"
    $form.MinimumSize = New-Object System.Drawing.Size(720, 560)
    $form.MaximizeBox = $true
    $form.MinimizeBox = $true
    $form.Font = New-Object System.Drawing.Font("Segoe UI", 9)

    $tip = New-Object System.Windows.Forms.ToolTip
    $tip.AutoPopDelay = 12000
    $tip.InitialDelay = 400

    $form.Padding = New-Object System.Windows.Forms.Padding(10, 10, 10, 8)

    $tabs = New-Object System.Windows.Forms.TabControl
    $tabs.Dock = "Fill"


    $tabDump = New-Object System.Windows.Forms.TabPage
    $tabDump.Text = "Выгрузка"
    $tabDump.AutoScroll = $true
    $tabLoad = New-Object System.Windows.Forms.TabPage
    $tabLoad.Text = "Загрузка"
    $tabLoad.AutoScroll = $true
    $tabSettings = New-Object System.Windows.Forms.TabPage
    $tabSettings.Text = "Настройки"
    $tabSettings.AutoScroll = $true
    $tabs.TabPages.Add($tabDump)
    $tabs.TabPages.Add($tabLoad)
    $tabs.TabPages.Add($tabSettings)

    $pnlBottom = New-Object System.Windows.Forms.Panel
    $pnlBottom.Dock = "Bottom"
    $pnlBottom.Height = 92
    $form.Controls.Add($pnlBottom)

    $pnlActions = New-Object System.Windows.Forms.Panel
    $pnlActions.Dock = "Bottom"
    $pnlActions.Height = 48
    $form.Controls.Add($pnlActions)
    $form.Controls.Add($tabs)

    $btnDump = New-Object System.Windows.Forms.Button
    $btnDump.Text = "Выгрузить в Git"
    $btnDump.Left = 5; $btnDump.Top = 7
    $btnDump.Width = 155; $btnDump.Height = 34
    $pnlActions.Controls.Add($btnDump)
    $tip.SetToolTip($btnDump, "Выгружает отмеченный состав на вкладке «Выгрузка» и отправляет коммит в Git")

    $btnGit = New-Object System.Windows.Forms.Button
    $btnGit.Text = "Только Git"
    $btnGit.Left = 165; $btnGit.Top = 7
    $btnGit.Width = 110; $btnGit.Height = 34
    $pnlActions.Controls.Add($btnGit)
    $tip.SetToolTip($btnGit, "Индексация, commit и push уже выгруженных файлов")

    $btnPushOnly = New-Object System.Windows.Forms.Button
    $btnPushOnly.Text = "Только push"
    $btnPushOnly.Left = 280; $btnPushOnly.Top = 7
    $btnPushOnly.Width = 115; $btnPushOnly.Height = 34
    $pnlActions.Controls.Add($btnPushOnly)
    $tip.SetToolTip($btnPushOnly, "Отправляет уже созданные локальные коммиты. Не индексирует файлы и не создаёт коммит")

    $btnLoad = New-Object System.Windows.Forms.Button
    $btnLoad.Text = "Загрузить в 1С"
    $btnLoad.Left = 400; $btnLoad.Top = 7
    $btnLoad.Width = 155; $btnLoad.Height = 34
    $pnlActions.Controls.Add($btnLoad)
    $tip.SetToolTip($btnLoad, "Заменяет конфигурацию в базе файлами из Git по флажкам вкладки «Загрузка»")

    $labelLeft = 15; $fieldLeft = 230; $fieldWidth = 300; $browseLeft = 540; $browseWidth = 90
    $rowHeight = 32; $topStart = 16

    # --- Общие поля подключения (вкладка «Настройки») ---
    [void](Add-FormLabel -Parent $tabSettings -Text "База из списка:" -Left $labelLeft -Top ($topStart + 3))
    $cbIBases = New-Object System.Windows.Forms.ComboBox
    $cbIBases.Left = $fieldLeft
    $cbIBases.Top = $topStart
    $cbIBases.Width = $fieldWidth
    $cbIBases.DropDownStyle = "DropDownList"
    $cbIBases.DropDownWidth = 620
    $tabSettings.Controls.Add($cbIBases)
    $tip.SetToolTip($cbIBases, "Список информационных баз из ibases.v8i")

    $btnBrowseV8i = New-Object System.Windows.Forms.Button
    $btnBrowseV8i.Text = "Список..."
    $btnBrowseV8i.Left = $browseLeft
    $btnBrowseV8i.Top = $topStart
    $btnBrowseV8i.Width = $browseWidth
    $btnBrowseV8i.Height = 22
    $tabSettings.Controls.Add($btnBrowseV8i)
    $tip.SetToolTip($btnBrowseV8i, "Открыть другой файл ibases.v8i")

    $lnkConnExtra = Add-FormLinkLabel -Parent $tabSettings -Text "Параметры подключения" -Left $fieldLeft -Top ($topStart + $rowHeight) -Width 240

    $pnlConn = New-Object System.Windows.Forms.Panel
    $pnlConn.Left = 0
    $pnlConn.Top = $topStart + ($rowHeight * 2) - 4
    $pnlConn.Width = 680
    $pnlConn.Height = 230
    $pnlConn.Visible = $false
    $tabSettings.Controls.Add($pnlConn)

    [void](Add-FormLabel -Parent $pnlConn -Text "Путь к 1cv8.exe:" -Left $labelLeft -Top 3)
    $platformValue = $Existing.PlatformPath
    if (-not $platformValue) {
        $AutoPath = Find-Latest1CPlatform
        if ($AutoPath) { $platformValue = $AutoPath }
        else { $platformValue = "C:\Program Files\1cv8\8.3.XX.XXXX\bin\1cv8.exe" }
    }
    $tbPlatform = Add-FormTextBox -Parent $pnlConn -Left $fieldLeft -Top 0 -Width $fieldWidth -Value $platformValue
    $btnBrowsePlatform = New-Object System.Windows.Forms.Button
    $btnBrowsePlatform.Text = "Обзор..."
    $btnBrowsePlatform.Left = $browseLeft; $btnBrowsePlatform.Top = 0
    $btnBrowsePlatform.Width = $browseWidth; $btnBrowsePlatform.Height = 22
    $btnBrowsePlatform.Add_Click({
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Filter = "Платформа 1С (1cv8.exe)|1cv8.exe|Исполняемые файлы (*.exe)|*.exe"
        $dlg.Title = "Выберите 1cv8.exe"
        $dlg.FileName = "1cv8.exe"
        if ($tbPlatform.Text -and (Test-Path $tbPlatform.Text)) {
            $dlg.InitialDirectory = Split-Path -Parent $tbPlatform.Text
        }
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $tbPlatform.Text = $dlg.FileName
        }
    })
    $pnlConn.Controls.Add($btnBrowsePlatform)

    [void](Add-FormLabel -Parent $pnlConn -Text "Тип базы:" -Left $labelLeft -Top ($rowHeight + 3))
    $rbFile = New-Object System.Windows.Forms.RadioButton
    $rbFile.Text = "Файловая"
    $rbFile.Left = $fieldLeft; $rbFile.Top = $rowHeight
    $rbFile.Width = 100
    $pnlConn.Controls.Add($rbFile)

    $rbServer = New-Object System.Windows.Forms.RadioButton
    $rbServer.Text = "Клиент-серверная"
    $rbServer.Left = $fieldLeft + 110; $rbServer.Top = $rowHeight
    $rbServer.Width = 160
    $pnlConn.Controls.Add($rbServer)

    $IsServer = $false
    if ($Existing.DBType -eq "Server") { $IsServer = $true }
    elseif ($Existing.InfobasePath -and $Existing.InfobasePath -notmatch '^[a-zA-Z]:\\') { $IsServer = $true }
    if ($IsServer) { $rbServer.Checked = $true } else { $rbFile.Checked = $true }

    $lbl2 = Add-FormLabel -Parent $pnlConn -Text "Каталог информационной базы:" -Left $labelLeft -Top (($rowHeight * 2) + 3)
    $fileBaseValue = ""
    if (-not $IsServer) { $fileBaseValue = [string]$Existing.InfobasePath }
    $tbFileBase = Add-FormTextBox -Parent $pnlConn -Left $fieldLeft -Top ($rowHeight * 2) -Width $fieldWidth -Value $fileBaseValue

    $btnBrowseBase = New-Object System.Windows.Forms.Button
    $btnBrowseBase.Text = "Обзор..."
    $btnBrowseBase.Left = $browseLeft; $btnBrowseBase.Top = $rowHeight * 2
    $btnBrowseBase.Width = $browseWidth; $btnBrowseBase.Height = 22
    $btnBrowseBase.Add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = "Выберите каталог информационной базы"
        if ($tbFileBase.Text -and (Test-Path $tbFileBase.Text)) {
            $dlg.SelectedPath = $tbFileBase.Text
        }
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $tbFileBase.Text = $dlg.SelectedPath
        }
    })
    $pnlConn.Controls.Add($btnBrowseBase)

    $lbl3 = Add-FormLabel -Parent $pnlConn -Text "Кластер серверов:" -Left $labelLeft -Top (($rowHeight * 3) + 3)
    $serverHostValue = ""
    $serverBaseValue = ""
    if ($IsServer -and $Existing.InfobasePath) {
        $parts = $Existing.InfobasePath -split '\\', 2
        if ($parts.Count -ge 1) { $serverHostValue = $parts[0] }
        if ($parts.Count -ge 2) { $serverBaseValue = $parts[1] }
    }
    $tbServerHost = Add-FormTextBox -Parent $pnlConn -Left $fieldLeft -Top ($rowHeight * 3) -Width ($fieldWidth + $browseWidth + 10) -Value $serverHostValue

    $lbl4 = Add-FormLabel -Parent $pnlConn -Text "Имя информационной базы:" -Left $labelLeft -Top (($rowHeight * 4) + 3)
    $tbServerBase = Add-FormTextBox -Parent $pnlConn -Left $fieldLeft -Top ($rowHeight * 4) -Width ($fieldWidth + $browseWidth + 10) -Value $serverBaseValue

    $UpdateVisibility = {
        if ($rbServer.Checked) {
            $lbl2.Visible = $false; $tbFileBase.Visible = $false; $btnBrowseBase.Visible = $false
            $lbl3.Visible = $true;  $tbServerHost.Visible = $true
            $lbl4.Visible = $true;  $tbServerBase.Visible = $true
        }
        else {
            $lbl2.Visible = $true;  $tbFileBase.Visible = $true; $btnBrowseBase.Visible = $true
            $lbl3.Visible = $false; $tbServerHost.Visible = $false
            $lbl4.Visible = $false; $tbServerBase.Visible = $false
        }
    }
    $rbFile.Add_CheckedChanged($UpdateVisibility)
    $rbServer.Add_CheckedChanged($UpdateVisibility)
    & $UpdateVisibility

    $authTop = $topStart + $rowHeight
    $lblUser = Add-FormLabel -Parent $tabSettings -Text "Пользователь 1С:" -Left $labelLeft -Top ($authTop + 3)
    $userValue = "Admin"
    if ($Existing.User) { $userValue = $Existing.User }
    $tbUser = Add-FormTextBox -Parent $tabSettings -Left $fieldLeft -Top $authTop -Width ($fieldWidth + $browseWidth + 10) -Value $userValue

    $lblPass = Add-FormLabel -Parent $tabSettings -Text "Пароль 1С:" -Left $labelLeft -Top ($authTop + $rowHeight + 3)
    $tbPass = Add-FormTextBox -Parent $tabSettings -Left $fieldLeft -Top ($authTop + $rowHeight) -Width ($fieldWidth + $browseWidth + 10)
    $tbPass.UseSystemPasswordChar = $true

    $chkShow = New-Object System.Windows.Forms.CheckBox
    $chkShow.Text = "Показать пароль"
    $chkShow.Left = $fieldLeft
    $chkShow.Top = $authTop + ($rowHeight * 2) - 2
    $chkShow.Width = 220
    $chkShow.Add_CheckedChanged({ $tbPass.UseSystemPasswordChar = -not $chkShow.Checked })
    $tabSettings.Controls.Add($chkShow)

    $gitTop = $authTop + ($rowHeight * 3) + 8
    $lblRepo = Add-FormLabel -Parent $tabSettings -Text "URL Git-репозитория:" -Left $labelLeft -Top ($gitTop + 3)
    $tbRepo = Add-FormTextBox -Parent $tabSettings -Left $fieldLeft -Top $gitTop -Width ($fieldWidth + $browseWidth + 10) -Value ([string]$Existing.GitRepoUrl)
    $tip.SetToolTip($tbRepo, "При первом запуске Git покажет окно авторизации")

    $lblBranch = Add-FormLabel -Parent $tabSettings -Text "Ветка:" -Left $labelLeft -Top ($gitTop + $rowHeight + 3)
    $branchValue = "main"
    if ($Existing.GitBranch) { $branchValue = $Existing.GitBranch }
    $tbBranch = Add-FormTextBox -Parent $tabSettings -Left $fieldLeft -Top ($gitTop + $rowHeight) -Width ($fieldWidth + $browseWidth + 10) -Value $branchValue
    $tip.SetToolTip($tbBranch, "Если ветки ещё нет на сервере, она будет создана при первой отправке")

    $chkAutoPush = New-Object System.Windows.Forms.CheckBox
    $chkAutoPush.Text = "Отправлять коммит без подтверждения"
    $chkAutoPush.Left = $fieldLeft
    $chkAutoPush.Top = $gitTop + ($rowHeight * 2) + 4
    $chkAutoPush.Width = 400
    $chkAutoPush.Checked = [bool]$Existing.AutoConfirmGitPush
    $tabSettings.Controls.Add($chkAutoPush)
    $tip.SetToolTip($chkAutoPush, "Окно со списком изменений не показывается: коммит и push выполняются сразу")

    $lnkGitExtra = Add-FormLinkLabel -Parent $tabSettings -Text "Дополнительно" -Left $fieldLeft -Top ($gitTop + ($rowHeight * 3) + 2) -Width 160

    $pnlGitExtra = New-Object System.Windows.Forms.Panel
    $pnlGitExtra.Left = $labelLeft
    $pnlGitExtra.Top = $gitTop + ($rowHeight * 4)
    $pnlGitExtra.Width = 640
    $pnlGitExtra.Height = 44
    $pnlGitExtra.Visible = $false
    $tabSettings.Controls.Add($pnlGitExtra)

    $btnCleanClone = New-Object System.Windows.Forms.Button
    $btnCleanClone.Text = "Начать с чистого клона"
    $btnCleanClone.Left = 0
    $btnCleanClone.Top = 4
    $btnCleanClone.Width = 210
    $btnCleanClone.Height = 28
    $pnlGitExtra.Controls.Add($btnCleanClone)
    $tip.SetToolTip($btnCleanClone, "Удалит локальную копию workdir\repo и склонирует репозиторий заново")

    $lblCleanClone = New-Object System.Windows.Forms.Label
    $lblCleanClone.Text = "Удалит локальную копию и клонирует репозиторий заново."
    $lblCleanClone.Left = 220; $lblCleanClone.Top = 8
    $lblCleanClone.Width = 400; $lblCleanClone.Height = 28
    $lblCleanClone.ForeColor = [System.Drawing.Color]::Gray
    $pnlGitExtra.Controls.Add($lblCleanClone)

    $RelayoutSettings = {
        $y = $chkAutoPush.Top + $chkAutoPush.Height + 12
        $lnkConnExtra.Top = $y
        $y += 22
        $pnlConn.Top = $y
        if ($pnlConn.Visible) { $y += $pnlConn.Height + 8 }
        $lnkGitExtra.Top = $y
        $y += 24
        $pnlGitExtra.Top = $y
        if ($pnlGitExtra.Visible) { $y += $pnlGitExtra.Height }
        $tabSettings.AutoScrollMinSize = New-Object System.Drawing.Size(0, ($y + 24))
        $pnlConn.SendToBack()
        $pnlGitExtra.SendToBack()
        foreach ($ctl in @($lblUser, $tbUser, $lblPass, $tbPass, $chkShow, $lblRepo, $tbRepo, $lblBranch, $tbBranch, $chkAutoPush)) {
            $ctl.BringToFront()
        }
    }

    $lnkConnExtra.Add_LinkClicked({
        $pnlConn.Visible = -not $pnlConn.Visible
        if ($pnlConn.Visible) { $lnkConnExtra.Text = "Скрыть параметры подключения" }
        else { $lnkConnExtra.Text = "Параметры подключения" }
        & $RelayoutSettings
    })
    $lnkGitExtra.Add_LinkClicked({
        $pnlGitExtra.Visible = -not $pnlGitExtra.Visible
        if ($pnlGitExtra.Visible) { $lnkGitExtra.Text = "Скрыть дополнительно" }
        else { $lnkGitExtra.Text = "Дополнительно" }
        & $RelayoutSettings
    })

    if (-not (Test-Path -LiteralPath $tbPlatform.Text)) {
        $pnlConn.Visible = $true
        $lnkConnExtra.Text = "Скрыть параметры подключения"
    }
    & $RelayoutSettings

    $script:IBaseComboItems = @()
    $script:IBasesExtraFile = $null
    $script:IBasesUpdating = $false

    $FillIBaseCombo = {
        param([string]$ExtraFile, [string]$SelectPath)
        $script:IBasesUpdating = $true
        $extra = @()
        if ($ExtraFile) { $extra = @($ExtraFile) }
        $bases = @(Get-1CIbasesList -ExtraFiles $extra)
        $script:IBaseComboItems = $bases
        $cbIBases.Items.Clear()
        if ($bases.Count -eq 0) {
            [void]$cbIBases.Items.Add("(список ibases.v8i не найден или пуст)")
        }
        else {
            [void]$cbIBases.Items.Add("(выберите базу из ibases.v8i)")
        }
        $selectIndex = 0
        $idx = 1
        foreach ($b in $bases) {
            [void]$cbIBases.Items.Add($b.Title)
            if ($SelectPath) {
                if ($b.Kind -eq "File" -and [string]::Equals($b.FilePath, $SelectPath, [StringComparison]::OrdinalIgnoreCase)) {
                    $selectIndex = $idx
                }
                elseif ($b.Kind -eq "Server") {
                    $full = "$($b.Server)\$($b.Ref)"
                    if ([string]::Equals($full, $SelectPath, [StringComparison]::OrdinalIgnoreCase)) {
                        $selectIndex = $idx
                    }
                }
            }
            $idx++
        }
        if ($cbIBases.Items.Count -gt 0) { $cbIBases.SelectedIndex = $selectIndex }
        $script:IBasesUpdating = $false
    }

    $GetConnectionSummary = {
        $ib = ""
        if ($rbServer.Checked) {
            $h = $tbServerHost.Text.Trim(); $n = $tbServerBase.Text.Trim()
            if ($h -or $n) { $ib = "$h\$n" }
        }
        else { $ib = $tbFileBase.Text.Trim() }
        if (-not $ib) { $ib = "не выбрана" }
        $branch = $tbBranch.Text.Trim()
        if (-not $branch) { $branch = "main" }
        return "База: $ib    Ветка: $branch"
    }

    $UpdateSummaries = {
        $text = & $GetConnectionSummary
        $lblDumpSummary.Text = $text
        $lblLoadSummary.Text = $text
    }

    $cbIBases.Add_SelectedIndexChanged({
        if ($script:IBasesUpdating) { return }
        $sel = $cbIBases.SelectedIndex
        if ($sel -le 0) { return }
        $item = $script:IBaseComboItems[$sel - 1]
        if (-not $item) { return }
        if ($item.Kind -eq "File") {
            $tbFileBase.Text = $item.FilePath
            $rbFile.Checked = $true
        }
        elseif ($item.Kind -eq "Server") {
            $tbServerHost.Text = $item.Server
            $tbServerBase.Text = $item.Ref
            $rbServer.Checked = $true
        }
        & $UpdateSummaries
    })

    $btnBrowseV8i.Add_Click({
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Filter = "Список баз 1С (ibases.v8i)|ibases.v8i;*.v8i|Все файлы (*.*)|*.*"
        $dlg.Title = "Выберите ibases.v8i"
        $dlg.FileName = "ibases.v8i"
        $startDir = Join-Path $env:APPDATA "1C\1CEStart"
        if (Test-Path $startDir) { $dlg.InitialDirectory = $startDir }
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $script:IBasesExtraFile = $dlg.FileName
            $currentPath = ""
            if ($rbServer.Checked) { $currentPath = "$($tbServerHost.Text.Trim())\$($tbServerBase.Text.Trim())" }
            else { $currentPath = $tbFileBase.Text.Trim() }
            & $FillIBaseCombo $script:IBasesExtraFile $currentPath
            & $UpdateSummaries
        }
    })

    foreach ($tb in @($tbFileBase, $tbServerHost, $tbServerBase, $tbBranch)) {
        $tb.Add_TextChanged({ & $UpdateSummaries })
    }

    & $FillIBaseCombo "" ([string]$Existing.InfobasePath)

    $GoToSettings = {
        $tabs.SelectedTab = $tabSettings
        $cbIBases.Focus()
    }

    # --- Вкладка «Выгрузка» ---
    $lblDumpSummary = New-Object System.Windows.Forms.Label
    $lblDumpSummary.Left = $labelLeft; $lblDumpSummary.Top = $topStart
    $lblDumpSummary.Width = 520; $lblDumpSummary.Height = 22
    $lblDumpSummary.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $tabDump.Controls.Add($lblDumpSummary)

    $lnkDumpSettings = Add-FormLinkLabel -Parent $tabDump -Text "Изменить подключение" -Left 540 -Top $topStart -Width 150
    $lnkDumpSettings.Add_LinkClicked({ & $GoToSettings })

    $chkMain = New-Object System.Windows.Forms.CheckBox
    $chkMain.Text = "Основная конфигурация"
    $chkMain.Left = $labelLeft; $chkMain.Top = $topStart + 40
    $chkMain.Width = 400
    $chkMain.Checked = [bool]$Existing.ExportMainConfig
    $tabDump.Controls.Add($chkMain)

    $chkExt = New-Object System.Windows.Forms.CheckBox
    $chkExt.Text = "Расширения"
    $chkExt.Left = $labelLeft; $chkExt.Top = $topStart + 72
    $chkExt.Width = 400
    $chkExt.Checked = [bool]$Existing.ExportExtensions
    $tabDump.Controls.Add($chkExt)

    $chkManual = New-Object System.Windows.Forms.CheckBox
    $chkManual.Text = "Выбрать расширения вручную"
    $chkManual.Left = $labelLeft + 24; $chkManual.Top = $topStart + 100
    $chkManual.Width = 400
    $chkManual.Checked = [bool]$Existing.SelectExtensionsManually
    $chkManual.Enabled = $chkExt.Checked
    $tabDump.Controls.Add($chkManual)
    $chkExt.Add_CheckedChanged({ $chkManual.Enabled = $chkExt.Checked })

    $lnkDumpExtra = Add-FormLinkLabel -Parent $tabDump -Text "Дополнительно" -Left $labelLeft -Top ($topStart + 136) -Width 160

    $pnlDumpExtra = New-Object System.Windows.Forms.Panel
    $pnlDumpExtra.Left = $labelLeft
    $pnlDumpExtra.Top = $topStart + 158
    $pnlDumpExtra.Width = 640
    $pnlDumpExtra.Height = 90
    $pnlDumpExtra.Visible = $false
    $tabDump.Controls.Add($pnlDumpExtra)

    [void](Add-FormLabel -Parent $pnlDumpExtra -Text "Префикс исключения:" -Left 0 -Top 3 -Width 180)
    $prefixValue = "EF_"
    if ($null -ne $Existing.ExtensionExcludePrefix) { $prefixValue = [string]$Existing.ExtensionExcludePrefix }
    $tbPrefix = Add-FormTextBox -Parent $pnlDumpExtra -Left 190 -Top 0 -Width 160 -Value $prefixValue
    $tip.SetToolTip($tbPrefix, "Расширения с этим префиксом не выгружаются, если список не выбирается вручную")

    [void](Add-FormLabel -Parent $pnlDumpExtra -Text "Режим выгрузки:" -Left 0 -Top 35 -Width 180)
    $cbDumpMode = New-Object System.Windows.Forms.ComboBox
    $cbDumpMode.Left = 190; $cbDumpMode.Top = 32
    $cbDumpMode.Width = 380
    $cbDumpMode.DropDownStyle = "DropDownList"
    [void]$cbDumpMode.Items.Add("Авто (полная, если каталог пустой)")
    [void]$cbDumpMode.Items.Add("Полная (каталог очищается)")
    [void]$cbDumpMode.Items.Add("Инкрементальная (-update)")
    $dumpMode = [string]$Existing.DumpMode
    if ($dumpMode -eq "Full") { $cbDumpMode.SelectedIndex = 1 }
    elseif ($dumpMode -eq "Incremental") { $cbDumpMode.SelectedIndex = 2 }
    else { $cbDumpMode.SelectedIndex = 0 }
    $pnlDumpExtra.Controls.Add($cbDumpMode)

    $lnkDumpExtra.Add_LinkClicked({
        $pnlDumpExtra.Visible = -not $pnlDumpExtra.Visible
        if ($pnlDumpExtra.Visible) { $lnkDumpExtra.Text = "Скрыть дополнительно" }
        else { $lnkDumpExtra.Text = "Дополнительно" }
    })

    # --- Вкладка «Загрузка» ---
    $lblLoadSummary = New-Object System.Windows.Forms.Label
    $lblLoadSummary.Left = $labelLeft; $lblLoadSummary.Top = $topStart
    $lblLoadSummary.Width = 520; $lblLoadSummary.Height = 22
    $lblLoadSummary.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $tabLoad.Controls.Add($lblLoadSummary)

    $lnkLoadSettings = Add-FormLinkLabel -Parent $tabLoad -Text "Изменить подключение" -Left 540 -Top $topStart -Width 150
    $lnkLoadSettings.Add_LinkClicked({ & $GoToSettings })

    $lblLoadWarn = New-Object System.Windows.Forms.Label
    $lblLoadWarn.Text = "Конфигурация в базе 1С будет заменена файлами из Git. Закройте конфигуратор и сеансы, при необходимости сделайте копию базы."
    $lblLoadWarn.Left = $labelLeft
    $lblLoadWarn.Top = $topStart + 32
    $lblLoadWarn.Width = 660
    $lblLoadWarn.Height = 40
    $lblLoadWarn.ForeColor = [System.Drawing.Color]::Firebrick
    $tabLoad.Controls.Add($lblLoadWarn)

    $chkLoadMain = New-Object System.Windows.Forms.CheckBox
    $chkLoadMain.Text = "Основная конфигурация"
    $chkLoadMain.Left = $labelLeft
    $chkLoadMain.Top = $topStart + 84
    $chkLoadMain.Width = 400
    $chkLoadMain.Checked = [bool]$Existing.LoadMainConfig
    $tabLoad.Controls.Add($chkLoadMain)

    $chkLoadExt = New-Object System.Windows.Forms.CheckBox
    $chkLoadExt.Text = "Расширения"
    $chkLoadExt.Left = $labelLeft
    $chkLoadExt.Top = $topStart + 116
    $chkLoadExt.Width = 400
    $chkLoadExt.Checked = [bool]$Existing.LoadExtensions
    $tabLoad.Controls.Add($chkLoadExt)

    $chkLoadManual = New-Object System.Windows.Forms.CheckBox
    $chkLoadManual.Text = "Выбрать расширения вручную (из папки Git)"
    $chkLoadManual.Left = $labelLeft + 24
    $chkLoadManual.Top = $topStart + 144
    $chkLoadManual.Width = 500
    $chkLoadManual.Checked = [bool]$Existing.LoadSelectExtensionsManually
    $chkLoadManual.Enabled = $chkLoadExt.Checked
    $tabLoad.Controls.Add($chkLoadManual)
    $chkLoadExt.Add_CheckedChanged({ $chkLoadManual.Enabled = $chkLoadExt.Checked })

    $chkUpdateDB = New-Object System.Windows.Forms.CheckBox
    $chkUpdateDB.Text = "Обновить конфигурацию базы данных"
    $chkUpdateDB.Left = $labelLeft
    $chkUpdateDB.Top = $topStart + 180
    $chkUpdateDB.Width = 500
    $chkUpdateDB.Checked = [bool]$Existing.UpdateInfobaseCfg
    $tabLoad.Controls.Add($chkUpdateDB)
    $tip.SetToolTip($chkUpdateDB, "UpdateDBCfg после загрузки файлов")

    $lnkLoadExtra = Add-FormLinkLabel -Parent $tabLoad -Text "Дополнительно" -Left $labelLeft -Top ($topStart + 212) -Width 160

    $pnlLoadExtra = New-Object System.Windows.Forms.Panel
    $pnlLoadExtra.Left = $labelLeft
    $pnlLoadExtra.Top = $topStart + 234
    $pnlLoadExtra.Width = 640
    $pnlLoadExtra.Height = 36
    $pnlLoadExtra.Visible = $false
    $tabLoad.Controls.Add($pnlLoadExtra)

    $chkDynamic = New-Object System.Windows.Forms.CheckBox
    $chkDynamic.Text = "Динамическое обновление (без монопольного доступа)"
    $chkDynamic.Left = 24; $chkDynamic.Top = 4
    $chkDynamic.Width = 600
    $chkDynamic.Checked = [bool]$Existing.DynamicUpdateCfg
    $chkDynamic.Enabled = $chkUpdateDB.Checked
    $pnlLoadExtra.Controls.Add($chkDynamic)
    $chkUpdateDB.Add_CheckedChanged({ $chkDynamic.Enabled = $chkUpdateDB.Checked })

    $lnkLoadExtra.Add_LinkClicked({
        $pnlLoadExtra.Visible = -not $pnlLoadExtra.Visible
        if ($pnlLoadExtra.Visible) { $lnkLoadExtra.Text = "Скрыть дополнительно" }
        else { $lnkLoadExtra.Text = "Дополнительно" }
    })

    & $UpdateSummaries
    $tabs.Add_SelectedIndexChanged({ & $UpdateSummaries })

    # --- Нижняя панель: статус, прогресс, журнал ---
    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Text = "Готово к запуску"
    $lblStatus.Left = 5; $lblStatus.Top = 6
    $lblStatus.Width = 590; $lblStatus.Height = 22
    $lblStatus.Anchor = "Top,Left,Right"
    $lblStatus.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $pnlBottom.Controls.Add($lblStatus)

    $btnCancelOp = New-Object System.Windows.Forms.Button
    $btnCancelOp.Text = "Отмена"
    $btnCancelOp.Left = 605; $btnCancelOp.Top = 2
    $btnCancelOp.Width = 90; $btnCancelOp.Height = 28
    $btnCancelOp.Enabled = $false
    $btnCancelOp.Anchor = "Top,Right"
    $btnCancelOp.Add_Click({
        $script:CancelRequested = $true
        $this.Enabled = $false
        $this.Text = "Отмена..."
        Write-Log "Запрошена отмена операции"
        Stop-TrackedProcess -Proc $script:CurrentProcess
    })
    $pnlBottom.Controls.Add($btnCancelOp)

    $bar = New-Object System.Windows.Forms.ProgressBar
    $bar.Left = 5; $bar.Top = 32
    $bar.Width = 690; $bar.Height = 14
    $bar.Anchor = "Top,Left,Right"
    $bar.Minimum = 0; $bar.Maximum = 100; $bar.Value = 0
    $bar.Visible = $false
    $pnlBottom.Controls.Add($bar)

    $btnToggleLog = New-Object System.Windows.Forms.Button
    $btnToggleLog.Text = "Показать журнал"
    $btnToggleLog.Left = 5; $btnToggleLog.Top = 52
    $btnToggleLog.Width = 150; $btnToggleLog.Height = 24
    $btnToggleLog.Anchor = "Top,Left"
    $pnlBottom.Controls.Add($btnToggleLog)

    $btnUpdate = New-Object System.Windows.Forms.Button
    $btnUpdate.Text = "Обновить"
    $btnUpdate.Left = 165; $btnUpdate.Top = 52
    $btnUpdate.Width = 120; $btnUpdate.Height = 24
    $btnUpdate.Anchor = "Top,Left"
    $pnlBottom.Controls.Add($btnUpdate)
    $tip.SetToolTip($btnUpdate, "Проверить GitHub Releases и установить новую версию")

    $lblVersion = New-Object System.Windows.Forms.Label
    $lblVersion.Text = "Версия " + (Get-AppVersion)
    $lblVersion.Left = 295; $lblVersion.Top = 55
    $lblVersion.Width = 390; $lblVersion.Height = 20
    $lblVersion.Anchor = "Top,Left,Right"
    $lblVersion.ForeColor = [System.Drawing.Color]::Gray
    $pnlBottom.Controls.Add($lblVersion)

    $txtLog = New-Object System.Windows.Forms.TextBox
    $txtLog.Left = 5; $txtLog.Top = 80
    $txtLog.Width = 690; $txtLog.Height = 200
    $txtLog.Anchor = "Top,Bottom,Left,Right"
    $txtLog.Multiline = $true
    $txtLog.ScrollBars = "Vertical"
    $txtLog.ReadOnly = $true
    $txtLog.Font = New-Object System.Drawing.Font("Consolas", 8)
    $txtLog.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $txtLog.ForeColor = [System.Drawing.Color]::LightGreen
    $txtLog.Visible = $false
    $pnlBottom.Controls.Add($txtLog)

    $script:SetLogExpanded = {
        param([bool]$Expanded)
        $script:LogExpanded = $Expanded
        if ($Expanded) {
            $txtLog.Visible = $true
            $pnlBottom.Height = 300
            $btnToggleLog.Text = "Скрыть журнал"
        }
        else {
            $txtLog.Visible = $false
            $pnlBottom.Height = 92
            $btnToggleLog.Text = "Показать журнал"
        }
    }
    $btnToggleLog.Add_Click({
        & $script:SetLogExpanded (-not $script:LogExpanded)
    })

    $script:Ui = @{
        Form          = $form
        RbServer      = $rbServer
        TbServerHost  = $tbServerHost
        TbServerBase  = $tbServerBase
        TbFileBase    = $tbFileBase
        TbPlatform    = $tbPlatform
        TbUser        = $tbUser
        TbPass        = $tbPass
        TbRepo        = $tbRepo
        TbBranch      = $tbBranch
        ChkAutoPush   = $chkAutoPush
        ChkMain       = $chkMain
        ChkExt        = $chkExt
        ChkManual     = $chkManual
        TbPrefix      = $tbPrefix
        CbDumpMode    = $cbDumpMode
        ChkLoadMain   = $chkLoadMain
        ChkLoadExt    = $chkLoadExt
        ChkLoadManual = $chkLoadManual
        ChkUpdateDB   = $chkUpdateDB
        ChkDynamic    = $chkDynamic
    }

    $script:ProgressForm         = $form
    $script:ProgressLabel        = $lblStatus
    $script:ProgressBar          = $bar
    $script:ProgressLog          = $txtLog
    $script:ProgressCancelButton = $btnCancelOp
    $script:TimingBox            = $null
    $script:MainTabs             = $tabs
    $script:ActionButtons        = @($btnDump, $btnGit, $btnPushOnly, $btnLoad, $btnCleanClone, $btnUpdate)

    $btnDump.Add_Click({ Start-UiAction -Action "all" })
    $btnGit.Add_Click({ Start-UiAction -Action "git" })
    $btnPushOnly.Add_Click({ Start-UiAction -Action "push" })
    $btnLoad.Add_Click({ Start-UiAction -Action "load" })
    $btnCleanClone.Add_Click({ Start-UiAction -Action "reclone" })
    $btnUpdate.Add_Click({ Start-AppSelfUpdate -Form $form })

    $form.Add_FormClosing({
        if ($script:IsUpdating) { return }
        if ($script:IsBusy) {
            $_.Cancel = $true
            [System.Windows.Forms.MessageBox]::Show(
                "Дождитесь окончания операции или нажмите «Отмена».",
                "1C Git Sync",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        }
    })

    $form.Add_Shown({
        $logFile = Get-AppLogPath
        if ((Test-Path -LiteralPath $logFile) -and $script:ProgressLog) {
            try {
                $existingLog = Get-Content -LiteralPath $logFile -Encoding UTF8 -ErrorAction Stop
                if ($existingLog) {
                    $script:ProgressLog.Text = (($existingLog | Select-Object -Last 200) -join "`r`n") + "`r`n"
                    $script:ProgressLog.SelectionStart = $script:ProgressLog.Text.Length
                    $script:ProgressLog.ScrollToCaret()
                }
            }
            catch { }
        }
        Write-Log "Приложение запущено, версия $(Get-AppVersion)"
        Set-Status -Text "Готово к запуску" -Percent 0
        if ($script:ProgressBar) { $script:ProgressBar.Visible = $false }
        try {
            $rel = Get-LatestAppRelease
            $script:LatestRelease = $rel
            $cur = ConvertTo-AppVersion -Text (Get-AppVersion)
            if ($cur -and $rel.Version -gt $cur) {
                $lblVersion.Text = "Версия $(Get-AppVersion)  ·  доступна $($rel.Version)"
                $lblVersion.ForeColor = [System.Drawing.Color]::DarkOrange
                $btnUpdate.Text = "Обновить"
                Set-Status -Text ("Доступна версия {0} — нажмите «Обновить»" -f $rel.Version)
            }
        }
        catch {
            Write-Log "Фоновая проверка обновлений: $_"
        }
    })

    [void]$form.ShowDialog()
}

function Read-UiConfig {
    param([string]$Action)

    $ui = $script:Ui
    if ($ui.RbServer.Checked) {
        $DbType = "Server"
        $InfobasePath = "$($ui.TbServerHost.Text.Trim())\$($ui.TbServerBase.Text.Trim())"
    }
    else {
        $DbType = "File"
        $InfobasePath = $ui.TbFileBase.Text.Trim()
    }

    $branch = $ui.TbBranch.Text.Trim()
    if (-not $branch) { $branch = "main" }

    $dumpMode = "Auto"
    if ($ui.CbDumpMode) {
        switch ([int]$ui.CbDumpMode.SelectedIndex) {
            1 { $dumpMode = "Full" }
            2 { $dumpMode = "Incremental" }
        }
    }

    return [PSCustomObject]@{
        Action                   = $Action
        PlatformPath             = $ui.TbPlatform.Text.Trim()
        DBType                   = $DbType
        InfobasePath             = $InfobasePath
        User                     = $ui.TbUser.Text.Trim()
        Password                 = $ui.TbPass.Text
        GitRepoUrl               = $ui.TbRepo.Text.Trim()
        GitBranch                = $branch
        AutoConfirmGitPush       = [bool]$ui.ChkAutoPush.Checked
        ExportMainConfig         = [bool]$ui.ChkMain.Checked
        ExportExtensions         = [bool]$ui.ChkExt.Checked
        SelectExtensionsManually = [bool]$ui.ChkManual.Checked
        ExtensionExcludePrefix   = $ui.TbPrefix.Text.Trim()
        DumpMode                 = $dumpMode
        LoadMainConfig           = [bool]$ui.ChkLoadMain.Checked
        LoadExtensions           = [bool]$ui.ChkLoadExt.Checked
        LoadSelectExtensionsManually = [bool]$ui.ChkLoadManual.Checked
        UpdateInfobaseCfg        = [bool]$ui.ChkUpdateDB.Checked
        DynamicUpdateCfg         = [bool]$ui.ChkDynamic.Checked
    }
}

function Save-AppConfig {
    param($Config)
    $saved = [PSCustomObject]@{
        PlatformPath             = $Config.PlatformPath
        DBType                   = $Config.DBType
        InfobasePath             = $Config.InfobasePath
        User                     = $Config.User
        GitRepoUrl               = $Config.GitRepoUrl
        GitBranch                = $Config.GitBranch
        AutoConfirmGitPush       = $Config.AutoConfirmGitPush
        ExportMainConfig         = $Config.ExportMainConfig
        ExportExtensions         = $Config.ExportExtensions
        SelectExtensionsManually = $Config.SelectExtensionsManually
        ExtensionExcludePrefix   = $Config.ExtensionExcludePrefix
        DumpMode                 = $Config.DumpMode
        LoadMainConfig           = $Config.LoadMainConfig
        LoadExtensions           = $Config.LoadExtensions
        LoadSelectExtensionsManually = $Config.LoadSelectExtensionsManually
        UpdateInfobaseCfg        = $Config.UpdateInfobaseCfg
        DynamicUpdateCfg         = $Config.DynamicUpdateCfg
    }
    $saved | ConvertTo-Json | Set-Content -Path $ConfigPath -Encoding UTF8
}

function Load-SavedConfig {
    $existing = Get-DefaultConfig
    if (Test-Path $ConfigPath) {
        try {
            $json = Get-Content -Path $ConfigPath -Raw -Encoding UTF8
            $existing = Merge-Config -Existing ($json | ConvertFrom-Json)
        }
        catch {
            Write-Host "Не удалось прочитать config.json: $_"
        }
    }
    return $existing
}

function Set-TimingSummaryText {
    param([string]$Text)
    $script:LastTimingSummary = $Text
    if ($script:ProgressLabel -and -not $script:ProgressLabel.IsDisposed) {
        $lines = @($Text -split "`r`n" | Where-Object { $_.Trim() })
        $script:ProgressLabel.Text = (($lines | Select-Object -First 2) -join "  ·  ")
    }
}

function Start-UiAction {
    param([string]$Action)
    if ($script:IsBusy) { return }

    $cfg = Read-UiConfig -Action $Action
    $errors = Test-Config -Config $cfg
    if ($errors.Count -gt 0) {
        $msg = "Обнаружены ошибки:`r`n`r`n" + ($errors -join "`r`n")
        [System.Windows.Forms.MessageBox]::Show(
            $msg, "Проверьте настройки",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }

    if ($Action -eq "reclone") {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            "Локальная копия workdir\repo будет удалена и склонирована заново из:`r`n$($cfg.GitRepoUrl)`r`n`r`nПродолжить?",
            "Чистый клон",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    }

    if ($Action -eq "load") {
        $parts = @()
        if ($cfg.LoadMainConfig) { $parts += "основную конфигурацию" }
        if ($cfg.LoadExtensions) { $parts += "расширения" }
        $what = ($parts -join " и ")
        $upd = "нет"
        if ($cfg.UpdateInfobaseCfg) {
            if ($cfg.DynamicUpdateCfg) { $upd = "да, динамическое" }
            else { $upd = "да, монопольное" }
        }
        $answer = [System.Windows.Forms.MessageBox]::Show(
            "В базу $($cfg.InfobasePath) будет загружена $what из origin/$($cfg.GitBranch).`r`n`r`nКонфигурация в 1С будет заменена.`r`nЛокальные файлы выгрузки будут приведены к удалённой ветке.`r`nОбновление конфигурации БД: $upd`r`n`r`nПродолжить?",
            "Загрузка в 1С",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    }

    Save-AppConfig -Config $cfg
    Set-MainFormBusy -Busy $true
    try {
        Invoke-SyncPipeline -Config $cfg
    }
    catch [System.OperationCanceledException] {
        Write-Log "Операция отменена пользователем"
        Set-Status -Text "Операция отменена" -Percent 100
        Set-TimingSummaryText -Text "Последняя операция отменена $(Get-Date -Format 'dd.MM.yyyy HH:mm:ss')"
    }
    catch {
        Write-Log "КРИТИЧЕСКАЯ ОШИБКА: $_" "ERROR"
        Set-Status -Text "Ошибка: $_" -Percent 100
        Set-TimingSummaryText -Text "Ошибка: $_"
        [System.Windows.Forms.MessageBox]::Show(
            "Ошибка:`r`n`r`n$_`r`n`r`nПодробности в журнале.",
            "1C Git Sync",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    }
    finally {
        Stop-DumpWatch
        Close-ProgressForm
        Set-MainFormBusy -Busy $false
        if ($script:LastTimingSummary) {
            Set-TimingSummaryText -Text $script:LastTimingSummary
        }
        else {
            Set-Status -Text "Готово к запуску"
        }
    }
}

# === ПРОВЕРКА ВВЕДЁННЫХ ДАННЫХ ===
function Test-Config {
    param([PSCustomObject]$Config)

    $errors = @()
    $action = [string]$Config.Action
    if (-not $action) { $action = "all" }

    $need1C = $action -in @("all", "config", "extensions", "load")
    $needGit = $action -in @("all", "git", "push", "reclone", "load")

    if ($need1C) {
        if (-not $Config.PlatformPath) {
            $errors += "Не указан путь к 1cv8.exe"
        }
        elseif (-not (Test-Path $Config.PlatformPath)) {
            $errors += "Файл 1cv8.exe не найден: $($Config.PlatformPath)"
        }

        if ($Config.DBType -eq "File") {
            if (-not $Config.InfobasePath) {
                $errors += "Не указан каталог информационной базы"
            }
            elseif (-not (Test-Path $Config.InfobasePath)) {
                $errors += "Каталог базы не найден: $($Config.InfobasePath)"
            }
        }
        elseif ($Config.DBType -eq "Server") {
            if (-not $Config.InfobasePath) {
                $errors += "Не указаны кластер серверов и имя информационной базы"
            }
            elseif ($Config.InfobasePath -notmatch '\\') {
                $errors += "Для серверной базы нужно заполнить и кластер серверов, и имя информационной базы"
            }
            elseif ($Config.InfobasePath -match '^\\' -or $Config.InfobasePath -match '\\$') {
                $errors += "Не заполнено одно из полей: кластер серверов или имя информационной базы"
            }
        }
    }

    if ($action -eq "all" -and -not $Config.ExportMainConfig -and -not $Config.ExportExtensions) {
        $errors += "Для выгрузки отметьте основную конфигурацию и/или расширения"
    }

    if ($action -eq "load" -and -not $Config.LoadMainConfig -and -not $Config.LoadExtensions) {
        $errors += "Для загрузки в 1С отметьте основную конфигурацию и/или расширения"
    }

    $gitUrl = [string]$Config.GitRepoUrl
    if ($needGit -or ($gitUrl -and $action -in @("config", "extensions", "load"))) {
        if (-not $gitUrl) {
            $errors += "Не указан URL Git-репозитория"
        }
        elseif ($gitUrl -notmatch "^(https?://|git@)") {
            $errors += "URL Git-репозитория должен начинаться с http://, https:// или git@"
        }

        if (-not $Config.GitBranch) {
            $errors += "Не указана ветка Git"
        }
        elseif ($Config.GitBranch -notmatch '^[A-Za-z0-9._/-]+$') {
            $errors += "Недопустимое имя ветки Git"
        }
    }

    return ,$errors
}

# === КОНФИГ: ЧТЕНИЕ И СОХРАНЕНИЕ ===
function Get-Config {
    return Load-SavedConfig
}

function Test-NameHasPrefix {
    param([string]$Name, [string]$Prefix)
    if (-not $Prefix) { return $false }
    return $Name.StartsWith($Prefix, [System.StringComparison]::OrdinalIgnoreCase)
}

# === ВЫБОР РАСШИРЕНИЙ ===
function Show-ExtensionPicker {
    param(
        [string[]]$Extensions,
        [string]$ExcludePrefix,
        [string]$PromptText = "Отметьте расширения для выгрузки:",
        [string]$AcceptText = "Выгрузить выбранные"
    )

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "1C Git Sync - Выбор расширений"
    $form.Width = 520
    $form.Height = 480
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.Font = New-Object System.Drawing.Font("Segoe UI", 9)

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $PromptText
    $lbl.Left = 15; $lbl.Top = 15; $lbl.Width = 470
    $form.Controls.Add($lbl)

    $list = New-Object System.Windows.Forms.CheckedListBox
    $list.Left = 15; $list.Top = 40
    $list.Width = 470; $list.Height = 330
    $list.CheckOnClick = $true
    foreach ($name in $Extensions) {
        $idx = $list.Items.Add($name)
        $checked = -not (Test-NameHasPrefix -Name $name -Prefix $ExcludePrefix)
        $list.SetItemChecked($idx, $checked)
    }
    $form.Controls.Add($list)

    $state = @{ Action = "skip" }

    $btnDump = New-Object System.Windows.Forms.Button
    $btnDump.Text = $AcceptText
    $btnDump.Left = 15; $btnDump.Top = 390; $btnDump.Width = 180
    $btnDump.Add_Click({
        if ($list.CheckedItems.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show(
                "Не выбрано ни одного расширения.",
                "1C Git Sync",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }
        $state.Action = "dump"
        $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $form.Close()
    })
    $form.Controls.Add($btnDump)

    $btnSkip = New-Object System.Windows.Forms.Button
    $btnSkip.Text = "Пропустить расширения"
    $btnSkip.Left = 205; $btnSkip.Top = 390; $btnSkip.Width = 180
    $btnSkip.DialogResult = [System.Windows.Forms.DialogResult]::Ignore
    $btnSkip.Add_Click({ $state.Action = "skip" })
    $form.Controls.Add($btnSkip)
    $form.CancelButton = $btnSkip

    $owner = Get-DialogOwner
    if ($owner) { [void]$form.ShowDialog($owner) } else { [void]$form.ShowDialog() }

    if ($state.Action -eq "dump") {
        $selected = @($list.CheckedItems | ForEach-Object { $_.ToString() })
        return ,$selected
    }
    return ,@()
}

# === ПРОСМОТР DIFF ===
function Show-DiffReviewForm {
    param(
        [string]$StatusText,
        [string]$StatText,
        [string]$DefaultMessage
    )

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "1C Git Sync - Изменения"
    $form.Width = 740
    $form.Height = 560
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.Font = New-Object System.Drawing.Font("Segoe UI", 9)

    $lblFiles = New-Object System.Windows.Forms.Label
    $lblFiles.Text = "Изменения:"
    $lblFiles.Left = 15; $lblFiles.Top = 12; $lblFiles.Width = 200
    $form.Controls.Add($lblFiles)

    $txtDiff = New-Object System.Windows.Forms.TextBox
    $txtDiff.Left = 15; $txtDiff.Top = 35
    $txtDiff.Width = 695; $txtDiff.Height = 340
    $txtDiff.Multiline = $true
    $txtDiff.ScrollBars = "Both"
    $txtDiff.ReadOnly = $true
    $txtDiff.WordWrap = $false
    $txtDiff.Font = New-Object System.Drawing.Font("Consolas", 8)
    $txtDiff.Text = "Файлы:`r`n$StatusText`r`n`r`nСводка:`r`n$StatText"
    $form.Controls.Add($txtDiff)

    $lblMsg = New-Object System.Windows.Forms.Label
    $lblMsg.Text = "Сообщение коммита:"
    $lblMsg.Left = 15; $lblMsg.Top = 385; $lblMsg.Width = 200
    $form.Controls.Add($lblMsg)

    $tbMsg = New-Object System.Windows.Forms.TextBox
    $tbMsg.Left = 15; $tbMsg.Top = 408
    $tbMsg.Width = 695; $tbMsg.Height = 22
    $tbMsg.Text = $DefaultMessage
    $form.Controls.Add($tbMsg)

    $state = @{ Action = "cancel"; Message = $DefaultMessage }

    $btnSkip = New-Object System.Windows.Forms.Button
    $btnSkip.Text = "Пропустить"
    $btnSkip.Left = 15; $btnSkip.Top = 450; $btnSkip.Width = 120
    $btnSkip.Add_Click({
        $state.Action = "skip"
        $state.Message = $tbMsg.Text
        $form.DialogResult = [System.Windows.Forms.DialogResult]::Ignore
        $form.Close()
    })
    $form.Controls.Add($btnSkip)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Отмена"
    $btnCancel.Left = 145; $btnCancel.Top = 450; $btnCancel.Width = 90
    $btnCancel.Add_Click({
        $state.Action = "cancel"
        $form.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $form.Close()
    })
    $form.Controls.Add($btnCancel)
    $form.CancelButton = $btnCancel

    $btnPush = New-Object System.Windows.Forms.Button
    $btnPush.Text = "Закоммитить и отправить"
    $btnPush.Left = 490; $btnPush.Top = 450; $btnPush.Width = 220
    $btnPush.Add_Click({
        $msg = $tbMsg.Text.Trim()
        if (-not $msg) {
            [System.Windows.Forms.MessageBox]::Show(
                "Укажите сообщение коммита.",
                "1C Git Sync",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }
        $state.Action = "push"
        $state.Message = $msg
        $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $form.Close()
    })
    $form.Controls.Add($btnPush)
    $form.AcceptButton = $btnPush

    $owner = Get-DialogOwner
    if ($owner) { [void]$form.ShowDialog($owner) } else { [void]$form.ShowDialog() }

    return [PSCustomObject]@{
        Action  = $state.Action
        Message = $state.Message
    }
}

function Format-ElapsedTime {
    param([TimeSpan]$Elapsed)
    if ($null -eq $Elapsed) { return "не выполнялась" }
    if ($Elapsed.TotalSeconds -lt 1) { return "меньше 1 сек" }
    $hours = [int][Math]::Floor($Elapsed.TotalHours)
    $mins = $Elapsed.Minutes
    $secs = $Elapsed.Seconds
    if ($hours -gt 0) { return ("{0} ч {1} мин {2} сек" -f $hours, $mins, $secs) }
    if ($mins -gt 0) { return ("{0} мин {1} сек" -f $mins, $secs) }
    return ("{0} сек" -f $secs)
}

function Format-DateTimeStamp {
    param([datetime]$Value)
    return $Value.ToString("dd.MM.yyyy HH:mm:ss")
}

function New-OpTiming {
    param(
        [datetime]$StartedAt,
        [datetime]$EndedAt,
        [TimeSpan]$Elapsed
    )
    if (-not $PSBoundParameters.ContainsKey("Elapsed")) {
        $Elapsed = $EndedAt - $StartedAt
    }
    return [PSCustomObject]@{
        StartedAt = $StartedAt
        EndedAt   = $EndedAt
        Elapsed   = $Elapsed
    }
}

function Format-TimingSummary {
    param(
        $ConfigTiming,
        $ExtensionsTiming,
        $GitTiming,
        [string]$Kind = "Dump"
    )

    $fmt = {
        param($timing)
        if ($timing) { Format-ElapsedTime -Elapsed $timing.Elapsed } else { "не выполнялась" }
    }

    $cfgLabel = "Выгрузка конфигурации"
    $extLabel = "Выгрузка расширений"
    $gitLabel = "Синхронизация с Git"
    if ($Kind -eq "Load") {
        $cfgLabel = "Загрузка конфигурации"
        $extLabel = "Загрузка расширений"
        $gitLabel = "Получение из Git"
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("${cfgLabel}: $( & $fmt $ConfigTiming )")
    $lines.Add("${extLabel}: $( & $fmt $ExtensionsTiming )")
    $lines.Add("${gitLabel}: $( & $fmt $GitTiming )")

    $performed = New-Object System.Collections.Generic.List[object]
    if ($ConfigTiming) { [void]$performed.Add($ConfigTiming) }
    if ($ExtensionsTiming) { [void]$performed.Add($ExtensionsTiming) }
    if ($GitTiming) { [void]$performed.Add($GitTiming) }

    if ($performed.Count -gt 0) {
        $startedAt = $performed[0].StartedAt
        $endedAt = $performed[0].EndedAt
        foreach ($op in $performed) {
            if ($op.StartedAt -lt $startedAt) { $startedAt = $op.StartedAt }
            if ($op.EndedAt -gt $endedAt) { $endedAt = $op.EndedAt }
        }
        $lines.Add("")
        $lines.Add("Всего: $(Format-ElapsedTime -Elapsed ($endedAt - $startedAt))")
        $lines.Add("Начало: $(Format-DateTimeStamp -Value $startedAt)")
        $lines.Add("Окончание: $(Format-DateTimeStamp -Value $endedAt)")
    }

    return ($lines -join "`r`n")
}

function Show-CompletionForm {
    param(
        [string]$Title,
        [string]$Message,
        [switch]$ShowRepoButton
    )

    $lineCount = @($Message -split "`r?`n").Count
    $msgHeight = [Math]::Max(80, [Math]::Min(260, ($lineCount * 18) + 16))
    $btnTop = 20 + $msgHeight + 16

    $form = New-Object System.Windows.Forms.Form
    $form.Text = $Title
    $form.Width = 520
    $form.Height = $btnTop + 80
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.Font = New-Object System.Drawing.Font("Segoe UI", 9)

    $box = New-Object System.Windows.Forms.TextBox
    $box.Multiline = $true
    $box.ReadOnly = $true
    $box.TabStop = $false
    $box.BorderStyle = "None"
    $box.BackColor = $form.BackColor
    $box.Left = 20
    $box.Top = 16
    $box.Width = 460
    $box.Height = $msgHeight
    $box.Text = $Message
    $form.Controls.Add($box)

    $x = 20
    if ($ShowRepoButton) {
        $btnRepo = New-Object System.Windows.Forms.Button
        $btnRepo.Text = "Открыть папку репозитория"
        $btnRepo.Left = $x; $btnRepo.Top = $btnTop; $btnRepo.Width = 190; $btnRepo.Height = 28
        $btnRepo.Add_Click({
            if (Test-Path $GitRepo) { Invoke-Item $GitRepo }
        })
        $form.Controls.Add($btnRepo)
        $x = 220
    }

    $btnLog = New-Object System.Windows.Forms.Button
    $btnLog.Text = "Открыть лог"
    $btnLog.Left = $x; $btnLog.Top = $btnTop; $btnLog.Width = 110; $btnLog.Height = 28
    $btnLog.Add_Click({
        $log = Join-Path $WorkDir "app.log"
        if (Test-Path $log) { Invoke-Item $log }
    })
    $form.Controls.Add($btnLog)

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = "OK"
    $btnOk.Left = 395; $btnOk.Top = $btnTop; $btnOk.Width = 90; $btnOk.Height = 28
    $btnOk.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Controls.Add($btnOk)
    $form.AcceptButton = $btnOk

    [void]$form.ShowDialog()
}

# === GIT IDENTITY ===
function Initialize-GitIdentity {
    param([string]$GitExe, [string]$GitHome)

    $env:HOME = $GitHome

    if (-not (Test-Path $GitHome)) {
        New-Item -ItemType Directory -Path $GitHome -Force | Out-Null
    }

    $Existing = & $GitExe config --global user.email 2>$null

    if (-not $Existing) {
        Write-Log "Настройка Git identity..."
        & $GitExe config --global user.name "1C Git Sync" 2>&1 | Out-Null
        & $GitExe config --global user.email "1c-git-sync@local" 2>&1 | Out-Null
    }

    & $GitExe config --global core.autocrlf false 2>&1 | Out-Null
    & $GitExe config --global core.safecrlf false 2>&1 | Out-Null
    & $GitExe config --global core.longpaths true 2>&1 | Out-Null
    & $GitExe config --global init.defaultBranch main 2>&1 | Out-Null
    & $GitExe config --global advice.detachedHead false 2>&1 | Out-Null
    & $GitExe config --global credential.helper manager 2>&1 | Out-Null
    & $GitExe config --global credential.modalprompt true 2>&1 | Out-Null
}

# === PORTABLE GIT: РАСПАКОВКА ===
function Initialize-PortableGit {
    param([string]$EmbeddedArchive)

    if (Test-Path $GitExe) {
        Write-Log "PortableGit уже распакован"
        return
    }

    Test-Cancelled
    Set-Status -Text "Распаковка PortableGit..." -Percent 15
    Write-Log "Распаковка PortableGit..."

    if (-not (Test-Path $EmbeddedArchive)) {
        throw "Встроенный архив PortableGit не найден: $EmbeddedArchive"
    }

    # Неполный каталог после прошлого сбоя мешает SFX и проверке git.exe
    if (Test-Path $GitDir) {
        Write-Log "Удаление неполной распаковки: $GitDir"
        Remove-Item -Path $GitDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Path $GitDir -Force | Out-Null

    # -NoNewWindow нельзя: PowerShell запущен скрытым окном, SFX тогда отваливается.
    # Аргументы 7-Zip SFX: -o"ПУТЬ" -y (без пробела после -o).
    $sfxArgs = "-o`"$GitDir`" -y"
    Write-Log "Запуск распаковщика: $EmbeddedArchive $sfxArgs"
    $Process = Start-Process -FilePath $EmbeddedArchive `
        -ArgumentList $sfxArgs `
        -PassThru -WindowStyle Hidden
    if (-not $Process) {
        throw "Не удалось запустить распаковщик PortableGit: $EmbeddedArchive"
    }

    $exitCode = Wait-CancellableProcess -Process $Process
    Write-Log "Распаковщик завершился, код: $(if ($null -eq $exitCode) { 'неизвестен' } else { $exitCode })"

    $deadline = (Get-Date).AddSeconds(180)
    while (-not (Test-Path $GitExe) -and (Get-Date) -lt $deadline) {
        Test-Cancelled
        Set-Status -Text "Ожидание файлов PortableGit..." -Percent 18
        Start-Sleep -Milliseconds 400
        [System.Windows.Forms.Application]::DoEvents()
    }

    if (-not (Test-Path $GitExe)) {
        $codeText = if ($null -eq $exitCode) { "неизвестен" } else { "$exitCode" }
        throw "Не удалось распаковать PortableGit (код $codeText). Ожидался файл: $GitExe"
    }

    $PostInstall = Join-Path $GitDir "post-install.bat"
    if (Test-Path $PostInstall) {
        Set-Status -Text "Настройка PortableGit..." -Percent 20
        Write-Log "Запуск post-install.bat..."
        $PostProc = Start-Process -FilePath "cmd.exe" `
            -ArgumentList "/c `"$PostInstall`"" `
            -WorkingDirectory $GitDir `
            -PassThru -WindowStyle Hidden
        if ($PostProc) {
            [void](Wait-CancellableProcess -Process $PostProc)
        }
    }

    Write-Log "PortableGit распакован"
}

function Initialize-GitLargeRepoConfig {
    param(
        [string]$GitExe,
        [string]$RepoDir
    )

    if (-not (Test-Path -LiteralPath (Join-Path $RepoDir ".git"))) { return }

    $pairs = @(
        @{ Key = "core.longpaths";      Value = "true" },
        @{ Key = "feature.manyFiles";   Value = "true" },
        @{ Key = "core.untrackedCache"; Value = "true" },
        @{ Key = "core.fsmonitor";      Value = "true" },
        @{ Key = "index.threads";       Value = "0" }
    )

    $changed = @()
    foreach ($p in $pairs) {
        $got = Invoke-Git -GitExe $GitExe -WorkingDirectory $RepoDir `
            -GitArgs @("config", "--local", "--get", $p.Key) -IgnoreExitCode -Quiet
        $cur = ""
        if ($got.Stdout) { $cur = $got.Stdout.Trim() }
        if ($cur -eq $p.Value) { continue }

        $set = Invoke-Git -GitExe $GitExe -WorkingDirectory $RepoDir `
            -GitArgs @("config", "--local", $p.Key, $p.Value) -IgnoreExitCode -Quiet
        if ($set.ExitCode -eq 0) {
            $changed += "$($p.Key)=$($p.Value)"
        }
        else {
            Write-Log "Не удалось задать git $($p.Key)=$($p.Value)"
        }
    }

    if ($changed.Count -gt 0) {
        Write-Log ("Git для большого дерева файлов: " + ($changed -join ", "))
    }
}

function Clear-RepoWorktree {
    param([string]$RepoDir)
    if (-not $RepoDir -or -not (Test-Path -LiteralPath $RepoDir)) { return }
    $items = @(Get-ChildItem -LiteralPath $RepoDir -Force -ErrorAction SilentlyContinue)
    foreach ($item in $items) {
        if ($item.Name -eq ".git") { continue }
        $target = $item.FullName
        if ($target -notlike "\\?\*") { $target = "\\?\$target" }
        Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# === ПОДГОТОВКА РЕПОЗИТОРИЯ ===
function Initialize-GitRepository {
    param(
        [string]$GitExe,
        [string]$RepoDir,
        [string]$RemoteUrl,
        [string]$Branch,
        [string]$GitHome,
        [switch]$SkipPullIfDirty,
        [switch]$ForceCheckout
    )

    Test-Cancelled
    $env:HOME = $GitHome
    $env:GIT_TERMINAL_PROMPT = $null
    $env:GIT_ASKPASS = $null
    $env:GCM_INTERACTIVE = $null

    if (-not $Branch) { $Branch = "main" }

    if (-not (Test-Path (Join-Path $RepoDir ".git"))) {
        Set-Status -Text "Клонирование репозитория..." -Percent 30
        Write-Log "Клонирование репозитория..."
        if (-not (Test-Path $WorkDir)) {
            New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
        }
        Invoke-Git -GitExe $GitExe -WorkingDirectory $WorkDir `
            -GitArgs @("-c", "core.longpaths=true", "clone", $RemoteUrl, $RepoDir)
    }

    Sync-GitOriginUrl -GitExe $GitExe -RepoDir $RepoDir -RemoteUrl $RemoteUrl
    Initialize-GitLargeRepoConfig -GitExe $GitExe -RepoDir $RepoDir

    Set-Status -Text "Подготовка ветки $Branch..." -Percent 35
    Write-Log "Подготовка ветки '$Branch'"

    Invoke-Git -GitExe $GitExe -WorkingDirectory $RepoDir -GitArgs @("fetch", "origin") -IgnoreExitCode

    $hasHead = Test-GitHeadExists -GitExe $GitExe -RepoDir $RepoDir
    $hasRemote = Test-GitRemoteBranchExists -GitExe $GitExe -RepoDir $RepoDir -Branch $Branch

    if (-not $hasHead) {
        Initialize-GitUnbornBranch -GitExe $GitExe -RepoDir $RepoDir -Branch $Branch
    }

    if ($ForceCheckout -and $hasRemote) {
        Write-Log "Принудительно берём origin/$Branch, локальные файлы будут заменены"
        Invoke-Git -GitExe $GitExe -WorkingDirectory $RepoDir `
            -GitArgs @("-c", "core.longpaths=true", "clean", "-fd") -IgnoreExitCode | Out-Null
        $co = Invoke-Git -GitExe $GitExe -WorkingDirectory $RepoDir `
            -GitArgs @("-c", "core.longpaths=true", "checkout", "-f", "-B", $Branch, "origin/$Branch") `
            -IgnoreExitCode
        if ($co.ExitCode -ne 0) {
            Write-Log "Checkout не прошёл — удаляем локальные файлы и повторяем"
            Clear-RepoWorktree -RepoDir $RepoDir
            Invoke-Git -GitExe $GitExe -WorkingDirectory $RepoDir `
                -GitArgs @("-c", "core.longpaths=true", "checkout", "-f", "-B", $Branch, "origin/$Branch")
        }
    }
    elseif ($hasRemote -and $hasHead) {
        $dirty = $false
        if ($SkipPullIfDirty) {
            $st = Invoke-Git -GitExe $GitExe -WorkingDirectory $RepoDir `
                -GitArgs @("status", "--porcelain") -IgnoreExitCode
            if ($st.Stdout -and $st.Stdout.Trim()) {
                $dirty = $true
                Write-Log "Есть локальные изменения — git pull пропущен, чтобы не затереть выгрузку"
            }
        }

        Set-Status -Text "Переключение на ветку $Branch..." -Percent 38
        $co = Invoke-Git -GitExe $GitExe -WorkingDirectory $RepoDir `
            -GitArgs @("checkout", $Branch) -IgnoreExitCode
        if ($co.ExitCode -ne 0) {
            Invoke-Git -GitExe $GitExe -WorkingDirectory $RepoDir `
                -GitArgs @("checkout", "-B", $Branch, "origin/$Branch")
        }
        if (-not $dirty) {
            Set-Status -Text "Синхронизация с удалённым репозиторием..." -Percent 40
            Invoke-Git -GitExe $GitExe -WorkingDirectory $RepoDir -GitArgs @("pull", "origin", $Branch)
        }
    }
    elseif ($hasRemote -and -not $hasHead) {
        Write-Log "Локально коммитов нет, на origin уже есть '$Branch' — забираем её"
        $co = Invoke-Git -GitExe $GitExe -WorkingDirectory $RepoDir `
            -GitArgs @("checkout", "-B", $Branch, "origin/$Branch") -IgnoreExitCode
        if ($co.ExitCode -ne 0) {
            Write-Log "Не удалось переключить ветку без затирания локальных файлов — оставляем текущее дерево"
        }
    }
    else {
        Write-Log "Удалённая ветка '$Branch' ещё не создана — первый push её опубликует"
    }
}

function Sync-GitWorktreeToOrigin {
    param(
        [string]$GitExe,
        [string]$RepoDir,
        [string]$Branch
    )

    if (-not $Branch) { $Branch = "main" }
    Test-Cancelled
    Set-Status -Text "Получение файлов из origin/$Branch..." -Percent 32
    Write-Log "Сбрасываем локальную копию к origin/$Branch"

    Invoke-Git -GitExe $GitExe -WorkingDirectory $RepoDir -GitArgs @("fetch", "origin")
    $hasRemote = Test-GitRemoteBranchExists -GitExe $GitExe -RepoDir $RepoDir -Branch $Branch
    if (-not $hasRemote) {
        throw "На origin нет ветки '$Branch'. Нечего загружать в 1С."
    }

    Initialize-GitLargeRepoConfig -GitExe $GitExe -RepoDir $RepoDir
    Invoke-Git -GitExe $GitExe -WorkingDirectory $RepoDir `
        -GitArgs @("-c", "core.longpaths=true", "clean", "-fd") -IgnoreExitCode | Out-Null

    $co = Invoke-Git -GitExe $GitExe -WorkingDirectory $RepoDir `
        -GitArgs @("-c", "core.longpaths=true", "checkout", "-f", "-B", $Branch, "origin/$Branch") -IgnoreExitCode
    if ($co.ExitCode -ne 0) {
        Write-Log "Checkout не прошёл — удаляем локальные файлы и повторяем"
        Clear-RepoWorktree -RepoDir $RepoDir
        Invoke-Git -GitExe $GitExe -WorkingDirectory $RepoDir `
            -GitArgs @("-c", "core.longpaths=true", "checkout", "-f", "-B", $Branch, "origin/$Branch")
    }

    Invoke-Git -GitExe $GitExe -WorkingDirectory $RepoDir `
        -GitArgs @("-c", "core.longpaths=true", "reset", "--hard", "origin/$Branch")
    Invoke-Git -GitExe $GitExe -WorkingDirectory $RepoDir `
        -GitArgs @("-c", "core.longpaths=true", "clean", "-fd") -IgnoreExitCode | Out-Null
    Write-Log "Рабочее дерево совпадает с origin/$Branch"
}

# === ПУБЛИКАЦИЯ В GIT ===
function Ensure-DumpGitIgnore {
    param([string]$RepoDir)

    $giPath = Join-Path $RepoDir ".gitignore"
    $required = @(
        "# Vendor parent configurations — .cf often exceeds GitLab/GitHub 100 MiB blob limit",
        "/Config/Ext/ParentConfigurations/*.cf",
        "*.cf"
    )

    $existing = @()
    if (Test-Path -LiteralPath $giPath) {
        $existing = @(Get-Content -LiteralPath $giPath -Encoding UTF8)
    }

    $toAdd = @()
    foreach ($line in $required) {
        if ($line.StartsWith("#")) { continue }
        $found = $false
        foreach ($have in $existing) {
            if ($have.Trim() -eq $line) { $found = $true; break }
        }
        if (-not $found) { $toAdd += $line }
    }

    if ($toAdd.Count -eq 0) { return }

    $block = @()
    if ($existing.Count -gt 0 -and $existing[-1].Trim() -ne "") { $block += "" }
    $block += $required[0]
    $block += $toAdd
    Add-Content -LiteralPath $giPath -Value $block -Encoding UTF8
    Write-Log "Обновлён .gitignore: исключены файлы конфигурации поставщика (*.cf)"
}

function Undo-OversizedGitIndex {
    param(
        [string]$GitExe,
        [string]$RepoDir,
        [int]$MaxMiB = 95
    )

    $maxBytes = [int64]$MaxMiB * 1MB
    $hasHead = Test-GitHeadExists -GitExe $GitExe -RepoDir $RepoDir
    $listed = Invoke-Git -GitExe $GitExe -WorkingDirectory $RepoDir `
        -GitArgs @("-c", "core.quotepath=false", "diff", "--cached", "--name-only") -IgnoreExitCode
    if (-not $listed.Stdout) { return @() }

    $skipped = @()
    $names = $listed.Stdout -split "`r?`n" | Where-Object { $_ -and $_.Trim() }
    foreach ($rel in $names) {
        $rel = $rel.Trim()
        $full = Join-Path $RepoDir $rel
        if (-not (Test-Path -LiteralPath $full)) { continue }
        $len = (Get-Item -LiteralPath $full).Length
        if ($len -le $maxBytes) { continue }

        if ($hasHead) {
            Invoke-Git -GitExe $GitExe -WorkingDirectory $RepoDir `
                -GitArgs @("reset", "-q", "HEAD", "--", $rel) -IgnoreExitCode | Out-Null
        }
        else {
            Invoke-Git -GitExe $GitExe -WorkingDirectory $RepoDir `
                -GitArgs @("rm", "--cached", "-q", "--", $rel) -IgnoreExitCode | Out-Null
        }
        $miB = [math]::Round($len / 1MB, 1)
        $line = "$rel ($miB MiB)"
        Write-Log "Пропущен файл больше $MaxMiB МиБ (лимит GitLab): $line"
        $skipped += $line
    }
    return ,$skipped
}

function Invoke-GitUnstageAll {
    param([string]$GitExe, [string]$RepoDir)
    if (Test-GitHeadExists -GitExe $GitExe -RepoDir $RepoDir) {
        Invoke-Git -GitExe $GitExe -WorkingDirectory $RepoDir -GitArgs @("reset") -IgnoreExitCode | Out-Null
    }
    else {
        Invoke-Git -GitExe $GitExe -WorkingDirectory $RepoDir `
            -GitArgs @("rm", "-r", "--cached", "-q", ".") -IgnoreExitCode | Out-Null
    }
}

function Invoke-GitPushBranch {
    param(
        [string]$GitExe,
        [string]$RepoDir,
        [string]$Branch,
        [bool]$IsFirstCommit,
        [switch]$NoReconcile
    )

    if ($IsFirstCommit) {
        Write-Log "Первый коммит: публикуем новую ветку origin/$Branch"
    }
    else {
        Write-Log "Отправка в origin/$Branch"
    }

    $refspec = "HEAD:refs/heads/$Branch"
    $push = Invoke-Git -GitExe $GitExe -WorkingDirectory $RepoDir `
        -GitArgs @("push", "-u", "origin", $refspec) -IgnoreExitCode

    if ($push.ExitCode -eq 0) { return }

    if ($NoReconcile) {
        $detail = ""
        if ($push.Stderr) { $detail = $push.Stderr.Trim() }
        elseif ($push.Stdout) { $detail = $push.Stdout.Trim() }
        if ($detail) {
            throw "Push не прошёл (код $($push.ExitCode)). $detail"
        }
        throw "Push не прошёл (код $($push.ExitCode)). Удалённая ветка могла уйти вперёд — нажмите «Только Git»."
    }

    Write-Log "Push не прошёл (код $($push.ExitCode)). Проверяем удалённую ветку и повторяем."

    $hasRemote = Test-GitRemoteBranchExists -GitExe $GitExe -RepoDir $RepoDir -Branch $Branch
    if ($hasRemote) {
        $env:GIT_MERGE_AUTOEDIT = "no"
        Invoke-Git -GitExe $GitExe -WorkingDirectory $RepoDir `
            -GitArgs @("pull", "origin", $Branch, "--allow-unrelated-histories", "--no-edit")
    }

    Invoke-Git -GitExe $GitExe -WorkingDirectory $RepoDir `
        -GitArgs @("push", "-u", "origin", $refspec)
}

function Invoke-GitPushOnly {
    param(
        [string]$GitExe,
        [string]$RepoDir,
        [string]$Branch,
        [string]$GitHome,
        [string]$RemoteUrl
    )

    Test-Cancelled
    $env:HOME = $GitHome
    if (-not $Branch) { $Branch = "main" }

    if (-not (Test-Path -LiteralPath (Join-Path $RepoDir ".git"))) {
        throw "Локальный клон не найден. Сначала выгрузите в Git или нажмите «Только Git»."
    }

    if ($RemoteUrl) {
        Sync-GitOriginUrl -GitExe $GitExe -RepoDir $RepoDir -RemoteUrl $RemoteUrl
    }

    if (-not (Test-GitHeadExists -GitExe $GitExe -RepoDir $RepoDir)) {
        throw "Нет локального коммита для отправки. Сначала нажмите «Только Git», чтобы создать коммит."
    }

    $cached = Invoke-Git -GitExe $GitExe -WorkingDirectory $RepoDir `
        -GitArgs @("diff", "--cached", "--quiet") -IgnoreExitCode -Quiet
    $work = Invoke-Git -GitExe $GitExe -WorkingDirectory $RepoDir `
        -GitArgs @("diff", "--quiet") -IgnoreExitCode -Quiet
    if ($cached.ExitCode -eq 1 -or $work.ExitCode -eq 1) {
        Write-Log "Есть незакоммиченные изменения — они не будут отправлены (коммит не создаётся)"
    }

    Write-Log "Режим: только push, без git add и git commit"
    Set-Status -Text "Отправка в удалённый репозиторий (git push)..." -Percent 95

    $isFirstCommit = -not (Test-GitRemoteBranchExists -GitExe $GitExe -RepoDir $RepoDir -Branch $Branch)
    Invoke-GitPushBranch -GitExe $GitExe -RepoDir $RepoDir -Branch $Branch `
        -IsFirstCommit $isFirstCommit -NoReconcile
    Set-Status -Text "Отправка в Git завершена" -Percent 98
    Write-Log "Отправка в Git завершена без нового коммита"
    return "push"
}

function Get-ConfigShortName {
    param([string]$Name)
    if (-not $Name) { return "" }
    $map = @{
        "КомплекснаяАвтоматизация"     = "КА"
        "УправлениеТорговлей"          = "УТ"
        "БухгалтерияПредприятия"       = "БП"
        "ЗарплатаИУправлениеПерсоналом" = "ЗУП"
        "УправлениеНашейФирмой"        = "УНФ"
        "ERPУправлениеПредприятием"    = "ERP"
        "УправлениеПредприятием"       = "ERP"
        "ДокументооборотКОРП"          = "ДО"
        "Документооборот"              = "ДО"
    }
    if ($map.ContainsKey($Name)) { return $map[$Name] }
    return $Name
}

function Get-InfobaseDisplayName {
    param([string]$InfobasePath)
    if (-not $InfobasePath) { return "" }
    $trimmed = $InfobasePath.Trim().TrimEnd("\", "/")
    if ($trimmed -match '[\\/]([^\\/]+)$') { return $Matches[1] }
    return $trimmed
}

function Get-ConfigurationDumpMeta {
    param([string]$ConfigXmlPath)
    $result = [PSCustomObject]@{ Name = ""; Version = "" }
    if (-not $ConfigXmlPath -or -not (Test-Path -LiteralPath $ConfigXmlPath)) { return $result }
    try {
        $text = [System.IO.File]::ReadAllText($ConfigXmlPath)
        if ($text -match '(?s)<Properties>.*?<Name>([^<]+)</Name>') {
            $result.Name = $Matches[1].Trim()
        }
        if ($text -match '(?s)<Properties>.*?<Version>([^<]*)</Version>') {
            $result.Version = $Matches[1].Trim()
        }
    }
    catch { }
    return $result
}

function New-GitCommitMessage {
    param(
        [string]$RepoDir,
        [string]$InfobasePath
    )

    $date = Get-Date -Format "yyyy-MM-dd"
    $xmlPath = Join-Path $RepoDir "Config\Configuration.xml"
    $meta = Get-ConfigurationDumpMeta -ConfigXmlPath $xmlPath
    $short = Get-ConfigShortName -Name $meta.Name
    $ib = Get-InfobaseDisplayName -InfobasePath $InfobasePath

    $headParts = @()
    if ($short) { $headParts += $short }
    if ($meta.Version) { $headParts += $meta.Version }
    $head = ($headParts -join " ")

    $tailParts = @()
    if ($ib) { $tailParts += $ib }
    $tailParts += $date
    $tail = ($tailParts -join ", ")

    if ($head) { return "$head, $tail" }
    return "Auto-update: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
}

function Invoke-GitPublish {
    param(
        [string]$GitExe,
        [string]$RepoDir,
        [string]$Branch,
        [string]$GitHome,
        [string]$InfobasePath = "",
        [switch]$AutoConfirm
    )

    Test-Cancelled
    $env:HOME = $GitHome

    if (-not $Branch) { $Branch = "main" }

    Ensure-DumpGitIgnore -RepoDir $RepoDir

    $isFirstCommit = -not (Test-GitHeadExists -GitExe $GitExe -RepoDir $RepoDir)
    if ($isFirstCommit) {
        Initialize-GitUnbornBranch -GitExe $GitExe -RepoDir $RepoDir -Branch $Branch
        Write-Log "Режим первого коммита: pull не выполняется, ветка будет создана на сервере при push"
    }

    Set-Status -Text "Добавление изменений в индекс..." -Percent 90
    Invoke-Git -GitExe $GitExe -WorkingDirectory $RepoDir `
        -GitArgs @("-c", "index.threads=0", "add", "-A")
    $skippedHuge = Undo-OversizedGitIndex -GitExe $GitExe -RepoDir $RepoDir

    if ($AutoConfirm) {
        $cached = Invoke-Git -GitExe $GitExe -WorkingDirectory $RepoDir `
            -GitArgs @("diff", "--cached", "--quiet") -IgnoreExitCode -Quiet
        if ($cached.ExitCode -eq 0) {
            if ($skippedHuge.Count -gt 0) {
                Write-Log "После исключения крупных файлов изменений для коммита нет"
            }
            else {
                Write-Log "Нет изменений для коммита"
            }
            Set-Status -Text "Нет изменений для коммита" -Percent 98
            return "none"
        }
        if ($cached.ExitCode -ne 1) {
            throw "git diff --cached --quiet завершился с кодом $($cached.ExitCode)"
        }
        if ($skippedHuge.Count -gt 0) {
            Write-Log ("Пропущены файлы больше 95 МиБ:`r`n" + ($skippedHuge -join "`r`n"))
        }
        $defaultMsg = New-GitCommitMessage -RepoDir $RepoDir -InfobasePath $InfobasePath
        Write-Log "Автоподтверждение коммита включено — окно ревью пропущено"
        $review = [PSCustomObject]@{ Action = "push"; Message = $defaultMsg }
    }
    else {
        $statusResult = Invoke-Git -GitExe $GitExe -WorkingDirectory $RepoDir `
            -GitArgs @("status", "--porcelain") -IgnoreExitCode
        $statusText = ""
        if ($statusResult.Stdout) { $statusText = $statusResult.Stdout.TrimEnd() }

        if ($skippedHuge.Count -gt 0) {
            $skipBlock = "Пропущены файлы больше 95 МиБ:`r`n" + ($skippedHuge -join "`r`n")
            if ($statusText) { $statusText = $skipBlock + "`r`n`r`n" + $statusText }
            else { $statusText = $skipBlock }
        }

        if (-not $statusResult.Stdout -or -not $statusResult.Stdout.Trim()) {
            if ($skippedHuge.Count -gt 0) {
                Write-Log "После исключения крупных файлов изменений для коммита нет"
            }
            else {
                Write-Log "Нет изменений для коммита"
            }
            Set-Status -Text "Нет изменений для коммита" -Percent 98
            return "none"
        }

        $statResult = Invoke-Git -GitExe $GitExe -WorkingDirectory $RepoDir `
            -GitArgs @("diff", "--cached", "--stat") -IgnoreExitCode
        $statText = ""
        if ($statResult.Stdout) { $statText = $statResult.Stdout.TrimEnd() }

        $defaultMsg = New-GitCommitMessage -RepoDir $RepoDir -InfobasePath $InfobasePath
        Set-ProgressCancelEnabled -Enabled $false
        $review = Show-DiffReviewForm -StatusText $statusText -StatText $statText -DefaultMessage $defaultMsg
        Set-ProgressCancelEnabled -Enabled $true
        Test-Cancelled
    }

    switch ($review.Action) {
        "cancel" {
            Invoke-GitUnstageAll -GitExe $GitExe -RepoDir $RepoDir
            throw (New-Object System.OperationCanceledException("Операция отменена пользователем"))
        }
        "skip" {
            Invoke-GitUnstageAll -GitExe $GitExe -RepoDir $RepoDir
            Write-Log "Отправка в Git пропущена пользователем"
            Set-Status -Text "Изменения оставлены локально" -Percent 98
            return "skip"
        }
        "push" {
            $msg = [string]$review.Message
            $msg = $msg -replace '"', "'"
            Set-Status -Text "Коммит изменений..." -Percent 92
            Invoke-Git -GitExe $GitExe -WorkingDirectory $RepoDir -GitArgs @("commit", "-m", $msg)
            Invoke-Git -GitExe $GitExe -WorkingDirectory $RepoDir `
                -GitArgs @("branch", "-M", $Branch) -IgnoreExitCode | Out-Null
            Set-Status -Text "Отправка в удалённый репозиторий (git push)..." -Percent 95
            Invoke-GitPushBranch -GitExe $GitExe -RepoDir $RepoDir -Branch $Branch -IsFirstCommit $isFirstCommit
            Set-Status -Text "Синхронизация с Git завершена" -Percent 98
            Write-Log "Синхронизация с Git завершена"
            return "push"
        }
        default {
            Invoke-GitUnstageAll -GitExe $GitExe -RepoDir $RepoDir
            throw (New-Object System.OperationCanceledException("Операция отменена пользователем"))
        }
    }
}

# === ОЧИСТКА ПАПКИ ПЕРЕД ВЫГРУЗКОЙ ===
function Clear-ExportPath {
    param([string]$Path)

    if (Test-Path $Path) {
        Write-Log "Очистка папки перед выгрузкой: $Path"
        Get-ChildItem -Path $Path -Force | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
    else {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

# === ФОРМИРОВАНИЕ ПАРАМЕТРОВ ПОДКЛЮЧЕНИЯ К БАЗЕ ===
function Get-1CConnectionParams {
    param(
        [string]$DBType,
        [string]$BasePath
    )

    if ($DBType -eq "Server") {
        return "/S `"$BasePath`""
    }
    return "/F `"$BasePath`""
}

function Read-1CLogFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return "" }

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -eq 0) { return "" }

    $text = ""
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $text = [System.Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
    }
    elseif ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $text = [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
    }
    else {
        $text = [System.Text.Encoding]::Default.GetString($bytes)
    }
    return $text.Trim()
}

function Get-1CArgsForLog {
    param([string]$ArgLine)
    return ($ArgLine -replace '/P\s+"[^"]*"', '/P "***"')
}

function Get-UnusedDriveLetter {
    $used = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
        if ($d.Name.Length -ge 1) { [void]$used.Add($d.Name.Substring(0, 1)) }
    }
    foreach ($d in Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue) {
        [void]$used.Add($d.Name)
    }
    foreach ($code in 90..68) {
        $letter = [string][char]$code
        if (-not $used.Contains($letter)) { return $letter }
    }
    return $null
}

function Enter-ShortDumpPath {
    param([string]$TargetPath)

    if (-not (Test-Path $TargetPath)) {
        New-Item -ItemType Directory -Path $TargetPath -Force | Out-Null
    }
    $resolved = [System.IO.Path]::GetFullPath($TargetPath)
    $letter = Get-UnusedDriveLetter
    if ($letter) {
        $substExe = Join-Path $env:SystemRoot "System32\subst.exe"
        $substOut = & $substExe "$letter`:" $resolved 2>&1
        if ($substOut) { Write-Log "subst: $substOut" }
        Start-Sleep -Milliseconds 200
        if (Test-Path -LiteralPath "$letter`:\") {
            Write-Log "Короткий путь выгрузки: ${letter}:\ -> $resolved"
            return [PSCustomObject]@{
                DumpPath = "${letter}:\"
                Drive    = $letter
                Target   = $resolved
            }
        }
        Write-Log "Не удалось назначить диск ${letter}:"
    }

    Write-Log "Выгрузка без subst, путь может превысить лимит Windows 260 символов"
    return [PSCustomObject]@{
        DumpPath = $resolved
        Drive    = $null
        Target   = $resolved
    }
}

function Exit-ShortDumpPath {
    param($Info)
    if (-not $Info -or -not $Info.Drive) { return }
    $substExe = Join-Path $env:SystemRoot "System32\subst.exe"
    & $substExe "$($Info.Drive):" /d 2>&1 | Out-Null
}

function Test-1CLogIsFatal {
    param([string]$LogText)
    if (-not $LogText) { return $true }
    if ($LogText -match 'Неправильный путь') { return $true }
    if ($LogText -match 'Схема не зарегистрирована') { return $true }
    if ($LogText -match 'исключительной блокировки') { return $true }
    if ($LogText -match 'Неверный пароль|Идентификация пользователя') { return $true }
    if ($LogText -match 'Ошибка при выполнении') { return $true }
    return $false
}

function Invoke-1CDesigner {
    param(
        [Parameter(Mandatory = $true)][string]$Platform,
        [Parameter(Mandatory = $true)][string]$ArgumentString,
        [string]$SuccessMarker = "",
        [switch]$IgnoreExitCode
    )

    Test-Cancelled

    $outFile = Join-Path $WorkDir "1c_out.txt"
    $dumpResultFile = Join-Path $WorkDir "1c_dumpresult.txt"
    Remove-Item $outFile, $dumpResultFile -Force -ErrorAction SilentlyContinue

    # GUI-процесс: не перехватывать stdout. Без /DisableStartupDialogs скрытые окна 1С дают код 1.
    $fullArgs = "$ArgumentString /DisableStartupDialogs /DisableStartupMessages /Out `"$outFile`" /DumpResult `"$dumpResultFile`""
    Write-Log ("Команда 1С: " + (Get-1CArgsForLog -ArgLine $fullArgs))

    $Psi = New-Object System.Diagnostics.ProcessStartInfo
    $Psi.FileName = $Platform
    $Psi.Arguments = $fullArgs
    $Psi.UseShellExecute = $false
    $Psi.CreateNoWindow = $true
    $Psi.RedirectStandardOutput = $false
    $Psi.RedirectStandardError = $false

    $Proc = New-Object System.Diagnostics.Process
    $Proc.StartInfo = $Psi
    $Proc.Start() | Out-Null
    $exitCode = Wait-CancellableProcess -Process $Proc

    $logText = Read-1CLogFile -Path $outFile
    if ($logText) {
        Write-Log "Журнал конфигуратора:"
        Write-Log $logText
    }

    $dumpResult = Read-1CLogFile -Path $dumpResultFile
    if ($dumpResult) { Write-Log "DumpResult: $dumpResult" }

    $markerOk = $false
    if ($SuccessMarker -and (Test-Path -LiteralPath $SuccessMarker)) { $markerOk = $true }

    $failed = $false
    if ($null -ne $exitCode -and $exitCode -ne 0) { $failed = $true }
    if ($dumpResult -and $dumpResult.Trim() -eq "1") { $failed = $true }

    if ($failed -and $markerOk -and -not (Test-1CLogIsFatal -LogText $logText)) {
        Write-Log "Конфигуратор вернул предупреждение, файлы выгрузки созданы — продолжаем"
        $failed = $false
    }

    if ($failed -and -not $IgnoreExitCode) {
        $hint = $logText
        if (-not $hint) {
            $hint = "Конфигуратор завершился с кодом $exitCode без текста ошибки. Закройте базу в 1С (пользовательский режим и конфигуратор) и проверьте имя пользователя и пароль."
        }
        throw "Операция конфигуратора не удалась (код $exitCode). $hint"
    }

    return [PSCustomObject]@{
        ExitCode   = $exitCode
        LogText    = $logText
        DumpResult = $dumpResult
    }
}

# === ВЫГРУЗКА 1С В ФАЙЛЫ ===
function Test-DumpCatalogReady {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $false }
    return (Test-Path -LiteralPath (Join-Path $Path "Configuration.xml"))
}

function Resolve-UseIncrementalDump {
    param(
        [string]$DumpMode,
        [string]$OutputPath
    )

    $mode = [string]$DumpMode
    if (-not $mode) { $mode = "Auto" }
    $ready = Test-DumpCatalogReady -Path $OutputPath

    switch ($mode) {
        "Full" { return $false }
        "Incremental" {
            if ($ready) { return $true }
            Write-Log "Инкрементальная выгрузка невозможна — нет Configuration.xml. Будет полная выгрузка."
            return $false
        }
        default {
            return [bool]$ready
        }
    }
}

function Invoke-1CExport {
    param(
        [string]$Platform,
        [string]$DBType,
        [string]$BasePath,
        [string]$User,
        [string]$Password,
        [string]$OutputPath,
        [string]$Extension = $null,
        [string]$DumpMode = "Auto",
        [int]$ProgressFrom = 40,
        [int]$ProgressTo   = 80
    )

    Test-Cancelled

    $useUpdate = Resolve-UseIncrementalDump -DumpMode $DumpMode -OutputPath $OutputPath
    if ($useUpdate) {
        Write-Log "Режим выгрузки: инкрементальная (-update)"
        if (-not (Test-Path -LiteralPath $OutputPath)) {
            New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
        }
    }
    else {
        Write-Log "Режим выгрузки: полная"
        Clear-ExportPath -Path $OutputPath
    }

    $title = "Выгрузка основной конфигурации"
    if ($Extension) { $title = "Выгрузка расширения: $Extension" }

    $attemptedUpdate = $useUpdate
    $done = $false
    $lastError = $null

    while (-not $done) {
        Test-Cancelled
        $short = Enter-ShortDumpPath -TargetPath $OutputPath
        $dumpArg = $short.DumpPath
        if ($dumpArg -match '\s') { $dumpArg = "`"$dumpArg`"" }

        $ConnParams = Get-1CConnectionParams -DBType $DBType -BasePath $BasePath
        $ArgLine = "DESIGNER $ConnParams /N `"$User`" /P `"$Password`" /DumpConfigToFiles $dumpArg"
        if ($useUpdate) { $ArgLine += " -update" }
        $ArgLine += " -Format Hierarchical"
        if ($Extension) { $ArgLine += " -Extension `"$Extension`"" }

        Write-Log $title
        Set-Status -Text "$title..." -Percent $ProgressFrom
        Start-DumpWatch -Title $title

        try {
            $marker = Join-Path $OutputPath "Configuration.xml"
            Invoke-1CDesigner -Platform $Platform -ArgumentString $ArgLine -SuccessMarker $marker | Out-Null
            $done = $true
        }
        catch [System.OperationCanceledException] {
            throw
        }
        catch {
            $lastError = $_
            if ($useUpdate) {
                Write-Log "Инкрементальная выгрузка не удалась: $lastError"
                Write-Log "Повторяем как полную выгрузку"
                $useUpdate = $false
            }
            else {
                throw
            }
        }
        finally {
            Stop-DumpWatch
            Exit-ShortDumpPath -Info $short
        }

        if (-not $done -and -not $useUpdate -and $attemptedUpdate) {
            Clear-ExportPath -Path $OutputPath
            $attemptedUpdate = $false
        }
    }

    Write-Log "Выгрузка завершена: $OutputPath"
}

function Get-RepoExtensionNames {
    param([string]$RepoDir)
    $root = Join-Path $RepoDir "Extensions"
    $names = @()
    if (-not (Test-Path -LiteralPath $root)) { return ,$names }
    $dirs = Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue
    foreach ($dir in $dirs) {
        if (Test-Path -LiteralPath (Join-Path $dir.FullName "Configuration.xml")) {
            $names += $dir.Name
        }
    }
    return ,$names
}

function Invoke-1CLoad {
    param(
        [string]$Platform,
        [string]$DBType,
        [string]$BasePath,
        [string]$User,
        [string]$Password,
        [string]$InputPath,
        [string]$Extension = $null,
        [bool]$UpdateDB = $true,
        [bool]$Dynamic = $false,
        [int]$ProgressFrom = 50
    )

    Test-Cancelled
    if (-not (Test-DumpCatalogReady -Path $InputPath)) {
        $where = $InputPath
        if ($Extension) { $where = "$InputPath (расширение $Extension)" }
        throw "Нет Configuration.xml для загрузки: $where"
    }

    $title = "Загрузка основной конфигурации в 1С"
    if ($Extension) { $title = "Загрузка расширения в 1С: $Extension" }

    $useUpdate = Test-Path -LiteralPath (Join-Path $InputPath "ConfigDumpInfo.xml")
    $attemptedUpdate = $useUpdate
    $done = $false

    while (-not $done) {
        Test-Cancelled
        $short = Enter-ShortDumpPath -TargetPath $InputPath
        $dumpArg = $short.DumpPath
        if ($dumpArg -match '\s') { $dumpArg = "`"$dumpArg`"" }

        $ConnParams = Get-1CConnectionParams -DBType $DBType -BasePath $BasePath
        $ArgLine = "DESIGNER $ConnParams /N `"$User`" /P `"$Password`" /LoadConfigFromFiles $dumpArg"
        if ($useUpdate) { $ArgLine += " -update" }
        if ($Extension) { $ArgLine += " -Extension `"$Extension`"" }
        $ArgLine += " -Format Hierarchical"
        if ($UpdateDB) {
            $ArgLine += " /UpdateDBCfg"
            if ($Dynamic) { $ArgLine += " -Dynamic+" }
            else { $ArgLine += " -Dynamic-" }
            if ($Extension) { $ArgLine += " -Extension `"$Extension`"" }
        }

        Write-Log $title
        if ($useUpdate) { Write-Log "Режим загрузки: инкрементальная (-update)" }
        else { Write-Log "Режим загрузки: полная" }
        Set-Status -Text "$title..." -Percent $ProgressFrom
        Start-DumpWatch -Title $title

        try {
            Invoke-1CDesigner -Platform $Platform -ArgumentString $ArgLine | Out-Null
            $done = $true
        }
        catch [System.OperationCanceledException] {
            throw
        }
        catch {
            if ($useUpdate) {
                Write-Log "Инкрементальная загрузка не удалась: $_"
                Write-Log "Повторяем как полную загрузку"
                $useUpdate = $false
            }
            else {
                throw
            }
        }
        finally {
            Stop-DumpWatch
            Exit-ShortDumpPath -Info $short
        }

        if (-not $done -and -not $useUpdate -and $attemptedUpdate) {
            $attemptedUpdate = $false
        }
    }

    Write-Log "Загрузка завершена: $InputPath"
}

function Invoke-LoadExtensionsPipeline {
    param(
        [string]$Platform,
        [string]$DBType,
        [string]$BasePath,
        [string]$User,
        [string]$Password,
        [string]$RepoDir,
        [bool]$SelectManually,
        [string]$ExcludePrefix,
        [bool]$UpdateDB,
        [bool]$Dynamic
    )

    $AllExtensions = @(Get-RepoExtensionNames -RepoDir $RepoDir)
    if ($AllExtensions.Count -eq 0) {
        Write-Log "В Git нет расширений с Configuration.xml (папка Extensions)"
        return
    }

    $ExtensionsToLoad = @()
    if ($SelectManually) {
        Set-ProgressCancelEnabled -Enabled $false
        $ExtensionsToLoad = Show-ExtensionPicker -Extensions $AllExtensions -ExcludePrefix $ExcludePrefix `
            -PromptText "Отметьте расширения для загрузки в 1С:" -AcceptText "Загрузить выбранные"
        Set-ProgressCancelEnabled -Enabled $true
        Test-Cancelled
        if ($ExtensionsToLoad.Count -eq 0) {
            Write-Log "Загрузка расширений пропущена пользователем"
            return
        }
    }
    else {
        $ExtensionsToLoad = @($AllExtensions | Where-Object {
            -not (Test-NameHasPrefix -Name $_ -Prefix $ExcludePrefix)
        })
        if ($ExtensionsToLoad.Count -eq 0) {
            Write-Log "После фильтра по префиксу '$ExcludePrefix' расширений не осталось"
            return
        }
    }

    $Total = $ExtensionsToLoad.Count
    $Index = 0
    foreach ($ExtName in $ExtensionsToLoad) {
        $Index++
        $PercentFrom = 70 + [int](($Index - 1) / $Total * 20)
        $ExtPath = Join-Path $RepoDir "Extensions\$ExtName"
        Invoke-1CLoad -Platform $Platform -DBType $DBType -BasePath $BasePath `
            -User $User -Password $Password -InputPath $ExtPath `
            -Extension $ExtName -UpdateDB $UpdateDB -Dynamic $Dynamic `
            -ProgressFrom $PercentFrom
    }
}

# === ПОЛУЧЕНИЕ СПИСКА РАСШИРЕНИЙ ===
function Get-1CExtensionsList {
    param(
        [string]$Platform,
        [string]$DBType,
        [string]$BasePath,
        [string]$User,
        [string]$Password
    )

    Test-Cancelled
    Write-Log "Получение списка расширений..."
    Set-Status -Text "Получение списка расширений..." -Percent 68

    $Extensions = @()

    $TempDir = Join-Path $WorkDir "_ext_list"
    if (Test-Path $TempDir) { Remove-Item $TempDir -Recurse -Force }
    New-Item -ItemType Directory -Path $TempDir -Force | Out-Null

    $short = Enter-ShortDumpPath -TargetPath $TempDir
    $dumpArg = $short.DumpPath
    if ($dumpArg -match '\s') { $dumpArg = "`"$dumpArg`"" }

    $ConnParams = Get-1CConnectionParams -DBType $DBType -BasePath $BasePath
    $ArgLine = "DESIGNER $ConnParams /N `"$User`" /P `"$Password`" /DumpConfigToFiles $dumpArg -AllExtensions -Format Hierarchical"
    Start-DumpWatch -Title "Получение списка расширений"

    try {
        Invoke-1CDesigner -Platform $Platform -ArgumentString $ArgLine -IgnoreExitCode | Out-Null
    }
    catch [System.OperationCanceledException] {
        if (Test-Path $TempDir) { Remove-Item $TempDir -Recurse -Force -ErrorAction SilentlyContinue }
        throw
    }
    finally {
        Stop-DumpWatch
        Exit-ShortDumpPath -Info $short
    }

    if (Test-Path $TempDir) {
        $SubDirs = Get-ChildItem -Path $TempDir -Directory -ErrorAction SilentlyContinue
        foreach ($Dir in $SubDirs) {
            $Extensions += $Dir.Name
        }
        Remove-Item $TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    $Extensions = @($Extensions | Select-Object -Unique)

    if ($Extensions.Count -eq 0) {
        Write-Log "Расширения не найдены"
    }
    else {
        Write-Log "Найдены расширения: $($Extensions -join ', ')"
    }

    return ,$Extensions
}

function Invoke-DumpExtensionsPipeline {
    param(
        [string]$Platform,
        [string]$DBType,
        [string]$BasePath,
        [string]$User,
        [string]$Password,
        [string]$RepoDir,
        [bool]$SelectManually,
        [string]$ExcludePrefix,
        [string]$DumpMode = "Auto"
    )

    $AllExtensions = Get-1CExtensionsList -Platform $Platform -DBType $DBType `
        -BasePath $BasePath -User $User -Password $Password

    $ExtensionsToDump = @()
    if ($AllExtensions.Count -eq 0) {
        Write-Log "Расширения для выгрузки не найдены"
        return
    }

    if ($SelectManually) {
        Set-ProgressCancelEnabled -Enabled $false
        $ExtensionsToDump = Show-ExtensionPicker -Extensions $AllExtensions -ExcludePrefix $ExcludePrefix
        Set-ProgressCancelEnabled -Enabled $true
        Test-Cancelled
        if ($ExtensionsToDump.Count -eq 0) {
            Write-Log "Выгрузка расширений пропущена пользователем"
            return
        }
    }
    else {
        $ExtensionsToDump = @($AllExtensions | Where-Object {
            -not (Test-NameHasPrefix -Name $_ -Prefix $ExcludePrefix)
        })
        if ($ExtensionsToDump.Count -eq 0) {
            Write-Log "После фильтра по префиксу '$ExcludePrefix' расширений не осталось"
            return
        }
    }

    $Total = $ExtensionsToDump.Count
    $Index = 0
    foreach ($ExtName in $ExtensionsToDump) {
        $Index++
        $PercentFrom = 70 + [int](($Index - 1) / $Total * 20)
        $PercentTo   = 70 + [int]($Index / $Total * 20)
        $ExtPath = Join-Path $RepoDir "Extensions\$ExtName"
        Invoke-1CExport -Platform $Platform -DBType $DBType -BasePath $BasePath `
            -User $User -Password $Password -OutputPath $ExtPath `
            -Extension $ExtName -DumpMode $DumpMode `
            -ProgressFrom $PercentFrom -ProgressTo $PercentTo
    }
}

function Invoke-SyncPipeline {
    param($Config)

    $Action                    = [string]$Config.Action
    if (-not $Action) { $Action = "all" }
    $PlatformPath              = $Config.PlatformPath
    $DBType                    = $Config.DBType
    $InfobasePath              = $Config.InfobasePath
    $1CUser                    = $Config.User
    $1CPassword                = $Config.Password
    $GitRepoUrl                = $Config.GitRepoUrl
    $GitBranch                 = $Config.GitBranch
    $AutoConfirmGitPush        = [bool]$Config.AutoConfirmGitPush
    $ExportMainConfig          = [bool]$Config.ExportMainConfig
    $ExportExtensions          = [bool]$Config.ExportExtensions
    $SelectExtensionsManually  = [bool]$Config.SelectExtensionsManually
    $ExtensionExcludePrefix    = [string]$Config.ExtensionExcludePrefix
    $DumpMode                  = [string]$Config.DumpMode
    if (-not $DumpMode) { $DumpMode = "Auto" }

    $doMain = ($Action -eq "config") -or ($Action -eq "all" -and $ExportMainConfig)
    $doExt  = ($Action -eq "extensions") -or ($Action -eq "all" -and $ExportExtensions)
    $doGitPublish = $Action -in @("all", "git")
    $doGitPrepare = $doGitPublish -or (($doMain -or $doExt) -and $GitRepoUrl) -or ($Action -eq "reclone")

    $configTiming = $null
    $extTiming = $null
    $gitTiming = $null

    Show-ProgressForm
    Set-Status -Text "Начало работы..." -Percent 5
    Write-Log "Действие: $Action"
    Write-Log "Запуск: $PlatformPath"
    Write-Log "Тип базы: $DBType"
    Write-Log "База: $InfobasePath"
    Write-Log "Репозиторий: $GitRepoUrl"
    Write-Log "Ветка: $GitBranch"
    Write-Log "Режим выгрузки: $DumpMode"
    Write-Log "Выгрузка конфигурации: $doMain; расширения: $doExt; Git: $doGitPublish"

    if ($Action -eq "reclone") {
        $EmbeddedGit = Join-Path $AppDir "PortableGit-64-bit.7z.exe"
        Initialize-PortableGit -EmbeddedArchive $EmbeddedGit
        Initialize-GitIdentity -GitExe $GitExe -GitHome $GitHome
        Reset-GitLocalClone -GitExe $GitExe -RepoDir $GitRepo -RemoteUrl $GitRepoUrl
        Initialize-GitRepository -GitExe $GitExe -RepoDir $GitRepo `
            -RemoteUrl $GitRepoUrl -Branch $GitBranch -GitHome $GitHome
        Set-Status -Text "Чистый клон готов" -Percent 100
        Write-Log "Операция успешно завершена"
        Set-TimingSummaryText -Text ("Чистый клон готов.`r`nРепозиторий: {0}`r`nОкончание: {1}" -f $GitRepoUrl, (Format-DateTimeStamp -Value (Get-Date)))
        return
    }

    if ($Action -eq "push") {
        Write-Log "Действие: только push, без git add и git commit"
        $opStart = Get-Date
        $EmbeddedGit = Join-Path $AppDir "PortableGit-64-bit.7z.exe"
        Initialize-PortableGit -EmbeddedArchive $EmbeddedGit
        Initialize-GitIdentity -GitExe $GitExe -GitHome $GitHome
        Invoke-GitPushOnly -GitExe $GitExe -RepoDir $GitRepo `
            -Branch $GitBranch -GitHome $GitHome -RemoteUrl $GitRepoUrl
        $gitTiming = New-OpTiming -StartedAt $opStart -EndedAt (Get-Date)
        Write-Log ("Отправка в Git: {0}" -f (Format-ElapsedTime -Elapsed $gitTiming.Elapsed))
        Set-Status -Text "Готово!" -Percent 100
        Write-Log "Операция успешно завершена"
        $doneMessage = "Локальные коммиты отправлены в ветку '$GitBranch' без нового коммита."
        $timingText = Format-TimingSummary -ConfigTiming $null -ExtensionsTiming $null -GitTiming $gitTiming
        foreach ($timingLine in ($timingText -split "`r`n")) {
            if ($timingLine) { Write-Log $timingLine }
        }
        Set-TimingSummaryText -Text ($doneMessage + "`r`n`r`n" + $timingText)
        return
    }

    if ($Action -eq "load") {
        $LoadMainConfig = [bool]$Config.LoadMainConfig
        $LoadExtensionsFlag = [bool]$Config.LoadExtensions
        $LoadSelectManually = [bool]$Config.LoadSelectExtensionsManually
        $UpdateInfobaseCfg = [bool]$Config.UpdateInfobaseCfg
        $DynamicUpdateCfg = [bool]$Config.DynamicUpdateCfg

        Write-Log "Загрузка конфигурации: $LoadMainConfig; расширения: $LoadExtensionsFlag; UpdateDBCfg: $UpdateInfobaseCfg; Dynamic: $DynamicUpdateCfg"

        $gitPrepStart = Get-Date
        $EmbeddedGit = Join-Path $AppDir "PortableGit-64-bit.7z.exe"
        Initialize-PortableGit -EmbeddedArchive $EmbeddedGit
        Initialize-GitIdentity -GitExe $GitExe -GitHome $GitHome
        Initialize-GitRepository -GitExe $GitExe -RepoDir $GitRepo `
            -RemoteUrl $GitRepoUrl -Branch $GitBranch -GitHome $GitHome `
            -SkipPullIfDirty -ForceCheckout
        Sync-GitWorktreeToOrigin -GitExe $GitExe -RepoDir $GitRepo -Branch $GitBranch
        $gitTiming = New-OpTiming -StartedAt $gitPrepStart -EndedAt (Get-Date)
        Write-Log ("Получение из Git: {0}" -f (Format-ElapsedTime -Elapsed $gitTiming.Elapsed))

        if ($LoadMainConfig) {
            $opStart = Get-Date
            Invoke-1CLoad -Platform $PlatformPath -DBType $DBType -BasePath $InfobasePath `
                -User $1CUser -Password $1CPassword -InputPath $ConfigExportPath `
                -UpdateDB $UpdateInfobaseCfg -Dynamic $DynamicUpdateCfg -ProgressFrom 50
            $configTiming = New-OpTiming -StartedAt $opStart -EndedAt (Get-Date)
            Write-Log ("Загрузка конфигурации: {0}" -f (Format-ElapsedTime -Elapsed $configTiming.Elapsed))
        }

        if ($LoadExtensionsFlag) {
            $opStart = Get-Date
            Invoke-LoadExtensionsPipeline -Platform $PlatformPath -DBType $DBType `
                -BasePath $InfobasePath -User $1CUser -Password $1CPassword `
                -RepoDir $GitRepo -SelectManually $LoadSelectManually `
                -ExcludePrefix $ExtensionExcludePrefix `
                -UpdateDB $UpdateInfobaseCfg -Dynamic $DynamicUpdateCfg
            $extTiming = New-OpTiming -StartedAt $opStart -EndedAt (Get-Date)
            Write-Log ("Загрузка расширений: {0}" -f (Format-ElapsedTime -Elapsed $extTiming.Elapsed))
        }

        Set-Status -Text "Загрузка в 1С завершена" -Percent 100
        Write-Log "Операция успешно завершена"

        $doneMessage = "Загрузка из Git в базу '$InfobasePath' завершена."
        $timingText = Format-TimingSummary -ConfigTiming $configTiming `
            -ExtensionsTiming $extTiming -GitTiming $gitTiming -Kind "Load"
        foreach ($timingLine in ($timingText -split "`r`n")) {
            if ($timingLine) { Write-Log $timingLine }
        }
        Set-TimingSummaryText -Text ($doneMessage + "`r`n`r`n" + $timingText)
        return
    }

    if ($doGitPrepare) {
        $gitPrepStart = Get-Date
        $EmbeddedGit = Join-Path $AppDir "PortableGit-64-bit.7z.exe"
        Initialize-PortableGit -EmbeddedArchive $EmbeddedGit
        Initialize-GitIdentity -GitExe $GitExe -GitHome $GitHome
        Initialize-GitRepository -GitExe $GitExe -RepoDir $GitRepo `
            -RemoteUrl $GitRepoUrl -Branch $GitBranch -GitHome $GitHome `
            -SkipPullIfDirty:($Action -eq "git")
        $gitPrepEnd = Get-Date
        if ($doGitPublish) {
            $gitTiming = New-OpTiming -StartedAt $gitPrepStart -EndedAt $gitPrepEnd
        }
    }
    elseif ($doMain -or $doExt) {
        if (-not (Test-Path $GitRepo)) {
            New-Item -ItemType Directory -Path $GitRepo -Force | Out-Null
        }
    }

    if ($doMain) {
        $opStart = Get-Date
        Invoke-1CExport -Platform $PlatformPath -DBType $DBType -BasePath $InfobasePath `
            -User $1CUser -Password $1CPassword -OutputPath $ConfigExportPath `
            -DumpMode $DumpMode -ProgressFrom 45 -ProgressTo 65
        $configTiming = New-OpTiming -StartedAt $opStart -EndedAt (Get-Date)
        Write-Log ("Выгрузка конфигурации: {0}" -f (Format-ElapsedTime -Elapsed $configTiming.Elapsed))
    }
    elseif ($Action -eq "all") {
        Write-Log "Выгрузка основной конфигурации пропущена"
    }

    if ($doExt) {
        $opStart = Get-Date
        Invoke-DumpExtensionsPipeline -Platform $PlatformPath -DBType $DBType `
            -BasePath $InfobasePath -User $1CUser -Password $1CPassword `
            -RepoDir $GitRepo -SelectManually $SelectExtensionsManually `
            -ExcludePrefix $ExtensionExcludePrefix -DumpMode $DumpMode
        $extTiming = New-OpTiming -StartedAt $opStart -EndedAt (Get-Date)
        Write-Log ("Выгрузка расширений: {0}" -f (Format-ElapsedTime -Elapsed $extTiming.Elapsed))
    }
    elseif ($Action -eq "all") {
        Write-Log "Выгрузка расширений отключена в настройках"
    }

    $publishResult = $null
    if ($doGitPublish) {
        Test-Cancelled
        $opStart = Get-Date
        $publishResult = Invoke-GitPublish -GitExe $GitExe -RepoDir $GitRepo `
            -Branch $GitBranch -GitHome $GitHome -InfobasePath $InfobasePath `
            -AutoConfirm:$AutoConfirmGitPush
        $opEnd = Get-Date
        if ($gitTiming) {
            $gitTiming = New-OpTiming -StartedAt $gitTiming.StartedAt -EndedAt $opEnd `
                -Elapsed ($gitTiming.Elapsed + ($opEnd - $opStart))
        }
        else {
            $gitTiming = New-OpTiming -StartedAt $opStart -EndedAt $opEnd
        }
        Write-Log ("Синхронизация с Git: {0}" -f (Format-ElapsedTime -Elapsed $gitTiming.Elapsed))
    }

    Set-Status -Text "Готово!" -Percent 100
    Write-Log "Операция успешно завершена"

    $doneMessage = "Операция завершена успешно."
    switch ($Action) {
        "config" { $doneMessage = "Основная конфигурация выгружена локально. Чтобы отправить в Git, нажмите «Синхронизация Git»." }
        "extensions" { $doneMessage = "Расширения выгружены локально. Чтобы отправить в Git, нажмите «Синхронизация Git»." }
        "git" {
            $doneMessage = "Синхронизация с веткой '$GitBranch' завершена."
            if ($publishResult -eq "skip") {
                $doneMessage = "Отправка в Git пропущена. Файлы остались локально."
            }
            elseif ($publishResult -eq "none") {
                $doneMessage = "В ветке '$GitBranch' нет изменений для коммита."
            }
        }
        "all" {
            $doneMessage = "Синхронизация завершена успешно!"
            if ($publishResult -eq "skip") {
                $doneMessage = "Выгрузка завершена. Изменения не отправлены в Git и оставлены локально."
            }
            elseif ($publishResult -eq "none") {
                $doneMessage = "Выгрузка завершена. Изменений для коммита нет."
            }
        }
    }

    $timingText = Format-TimingSummary -ConfigTiming $configTiming `
        -ExtensionsTiming $extTiming -GitTiming $gitTiming
    foreach ($timingLine in ($timingText -split "`r`n")) {
        if ($timingLine) { Write-Log $timingLine }
    }
    Set-TimingSummaryText -Text ($doneMessage + "`r`n`r`n" + $timingText)
}

# === ТОЧКА ВХОДА ПРИЛОЖЕНИЯ ===
try {
    Initialize-WorkDir
    $existing = Load-SavedConfig
    Show-SettingsForm -Existing $existing
}
catch {
    Write-Log "КРИТИЧЕСКАЯ ОШИБКА: $_" "ERROR"
    [System.Windows.Forms.MessageBox]::Show(
        "Ошибка запуска:`r`n`r`n$_",
        "1C Git Sync",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    exit 1
}
