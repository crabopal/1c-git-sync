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
$script:DumpWatchPath         = $null
$script:DumpWatchTitle        = ""
$script:DumpWatchStarted      = $null
$script:DumpWatchLastPoll     = $null
$script:Ui                    = @{}

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

function Format-DumpSize {
    param([int64]$Bytes)
    if ($Bytes -lt 1KB) { return "$Bytes Б" }
    if ($Bytes -lt 1MB) { return ("{0} КБ" -f [int][Math]::Round($Bytes / 1KB)) }
    if ($Bytes -lt 1GB) { return ("{0} МБ" -f [Math]::Round($Bytes / 1MB, 1)) }
    return ("{0} ГБ" -f [Math]::Round($Bytes / 1GB, 2))
}

function Get-DumpWatchStats {
    param([string]$Path)
    $xmlCount = 0
    $bytes = [int64]0
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
        return [PSCustomObject]@{ XmlCount = 0; Bytes = [int64]0 }
    }
    try {
        $files = [System.IO.Directory]::EnumerateFiles($Path, "*.xml", [System.IO.SearchOption]::AllDirectories)
        foreach ($f in $files) {
            $xmlCount++
            try { $bytes += ([System.IO.FileInfo]$f).Length } catch { }
        }
    }
    catch { }
    return [PSCustomObject]@{ XmlCount = $xmlCount; Bytes = $bytes }
}

function Start-DumpWatch {
    param([string]$Path, [string]$Title)
    $script:DumpWatchPath = $Path
    $script:DumpWatchTitle = $Title
    $script:DumpWatchStarted = Get-Date
    $script:DumpWatchLastPoll = [datetime]::MinValue
}

function Stop-DumpWatch {
    $script:DumpWatchPath = $null
    $script:DumpWatchTitle = ""
    $script:DumpWatchStarted = $null
    $script:DumpWatchLastPoll = $null
}

function Update-DumpWatchStatus {
    if (-not $script:DumpWatchPath) { return }
    $now = Get-Date
    if ($script:DumpWatchLastPoll -and ($now - $script:DumpWatchLastPoll).TotalSeconds -lt 2) { return }
    $script:DumpWatchLastPoll = $now

    $stats = Get-DumpWatchStats -Path $script:DumpWatchPath
    $elapsed = [TimeSpan]::Zero
    if ($script:DumpWatchStarted) { $elapsed = $now - $script:DumpWatchStarted }
    $countText = $stats.XmlCount.ToString("N0")
    $title = $script:DumpWatchTitle
    if (-not $title) { $title = "Выгрузка" }
    Set-Status -Text ("{0} — {1}, {2} XML, {3}" -f $title, (Format-ElapsedTime -Elapsed $elapsed), $countText, (Format-DumpSize -Bytes $stats.Bytes))
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
    if ($script:ProgressCancelButton -and -not $script:ProgressCancelButton.IsDisposed) {
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

# === ГЛАВНОЕ ОКНО ===
function Show-SettingsForm {
    param([PSCustomObject]$Existing)

    $Existing = Merge-Config -Existing $Existing

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "1C Git Sync"
    $form.Width = 740
    $form.Height = 880
    $form.StartPosition = "CenterScreen"
    $form.MinimumSize = New-Object System.Drawing.Size(740, 780)
    $form.MaximizeBox = $true
    $form.MinimizeBox = $true
    $form.Font = New-Object System.Drawing.Font("Segoe UI", 9)

    $tabs = New-Object System.Windows.Forms.TabControl
    $tabs.Left = 10; $tabs.Top = 10
    $tabs.Width = 705; $tabs.Height = 360
    $tabs.Anchor = "Top,Left,Right"
    $form.Controls.Add($tabs)

    $tab1C = New-Object System.Windows.Forms.TabPage
    $tab1C.Text = "База 1С"
    $tabGit = New-Object System.Windows.Forms.TabPage
    $tabGit.Text = "Git"
    $tabDump = New-Object System.Windows.Forms.TabPage
    $tabDump.Text = "Выгрузка"
    $tabs.TabPages.Add($tab1C)
    $tabs.TabPages.Add($tabGit)
    $tabs.TabPages.Add($tabDump)

    $tabLoad = New-Object System.Windows.Forms.TabPage
    $tabLoad.Text = "Загрузка"
    $tabs.TabPages.Add($tabLoad)

    $labelLeft = 15; $fieldLeft = 230; $fieldWidth = 300; $browseLeft = 540; $browseWidth = 90
    $rowHeight = 32; $topStart = 20

    # --- Вкладка «База 1С» ---
    [void](Add-FormLabel -Parent $tab1C -Text "Путь к 1cv8.exe:" -Left $labelLeft -Top ($topStart + 3))

    $platformValue = $Existing.PlatformPath
    if (-not $platformValue) {
        $AutoPath = Find-Latest1CPlatform
        if ($AutoPath) { $platformValue = $AutoPath }
        else { $platformValue = "C:\Program Files\1cv8\8.3.XX.XXXX\bin\1cv8.exe" }
    }
    $tbPlatform = Add-FormTextBox -Parent $tab1C -Left $fieldLeft -Top $topStart -Width $fieldWidth -Value $platformValue

    $btnBrowsePlatform = New-Object System.Windows.Forms.Button
    $btnBrowsePlatform.Text = "Обзор..."
    $btnBrowsePlatform.Left = $browseLeft; $btnBrowsePlatform.Top = $topStart
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
    $tab1C.Controls.Add($btnBrowsePlatform)

    [void](Add-FormLabel -Parent $tab1C -Text "Тип базы:" -Left $labelLeft -Top ($topStart + $rowHeight + 3))

    $rbFile = New-Object System.Windows.Forms.RadioButton
    $rbFile.Text = "Файловая"
    $rbFile.Left = $fieldLeft; $rbFile.Top = $topStart + $rowHeight
    $rbFile.Width = 100
    $tab1C.Controls.Add($rbFile)

    $rbServer = New-Object System.Windows.Forms.RadioButton
    $rbServer.Text = "Клиент-серверная"
    $rbServer.Left = $fieldLeft + 110; $rbServer.Top = $topStart + $rowHeight
    $rbServer.Width = 160
    $tab1C.Controls.Add($rbServer)

    $IsServer = $false
    if ($Existing.DBType -eq "Server") { $IsServer = $true }
    elseif ($Existing.InfobasePath -and $Existing.InfobasePath -notmatch '^[a-zA-Z]:\\') { $IsServer = $true }
    if ($IsServer) { $rbServer.Checked = $true } else { $rbFile.Checked = $true }

    $lbl2 = Add-FormLabel -Parent $tab1C -Text "Каталог информационной базы:" -Left $labelLeft -Top ($topStart + ($rowHeight * 2) + 3)
    $fileBaseValue = ""
    if (-not $IsServer) { $fileBaseValue = [string]$Existing.InfobasePath }
    $tbFileBase = Add-FormTextBox -Parent $tab1C -Left $fieldLeft -Top ($topStart + ($rowHeight * 2)) -Width $fieldWidth -Value $fileBaseValue

    $btnBrowseBase = New-Object System.Windows.Forms.Button
    $btnBrowseBase.Text = "Обзор..."
    $btnBrowseBase.Left = $browseLeft; $btnBrowseBase.Top = $topStart + ($rowHeight * 2)
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
    $tab1C.Controls.Add($btnBrowseBase)

    $lbl3 = Add-FormLabel -Parent $tab1C -Text "Кластер серверов:" -Left $labelLeft -Top ($topStart + ($rowHeight * 3) + 3)
    $serverHostValue = ""
    $serverBaseValue = ""
    if ($IsServer -and $Existing.InfobasePath) {
        $parts = $Existing.InfobasePath -split '\\', 2
        if ($parts.Count -ge 1) { $serverHostValue = $parts[0] }
        if ($parts.Count -ge 2) { $serverBaseValue = $parts[1] }
    }
    $tbServerHost = Add-FormTextBox -Parent $tab1C -Left $fieldLeft -Top ($topStart + ($rowHeight * 3)) -Width ($fieldWidth + $browseWidth + 10) -Value $serverHostValue

    $lbl4 = Add-FormLabel -Parent $tab1C -Text "Имя информационной базы:" -Left $labelLeft -Top ($topStart + ($rowHeight * 4) + 3)
    $tbServerBase = Add-FormTextBox -Parent $tab1C -Left $fieldLeft -Top ($topStart + ($rowHeight * 4)) -Width ($fieldWidth + $browseWidth + 10) -Value $serverBaseValue

    [void](Add-FormLabel -Parent $tab1C -Text "Пользователь 1С:" -Left $labelLeft -Top ($topStart + ($rowHeight * 5) + 3))
    $userValue = "Admin"
    if ($Existing.User) { $userValue = $Existing.User }
    $tbUser = Add-FormTextBox -Parent $tab1C -Left $fieldLeft -Top ($topStart + ($rowHeight * 5)) -Width ($fieldWidth + $browseWidth + 10) -Value $userValue

    [void](Add-FormLabel -Parent $tab1C -Text "Пароль 1С:" -Left $labelLeft -Top ($topStart + ($rowHeight * 6) + 3))
    $tbPass = Add-FormTextBox -Parent $tab1C -Left $fieldLeft -Top ($topStart + ($rowHeight * 6)) -Width ($fieldWidth + $browseWidth + 10)
    $tbPass.UseSystemPasswordChar = $true

    $chkShow = New-Object System.Windows.Forms.CheckBox
    $chkShow.Text = "Показать пароль 1С"
    $chkShow.Left = $fieldLeft
    $chkShow.Top = $topStart + ($rowHeight * 7) - 2
    $chkShow.Width = 220
    $chkShow.Add_CheckedChanged({ $tbPass.UseSystemPasswordChar = -not $chkShow.Checked })
    $tab1C.Controls.Add($chkShow)

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

    # --- Вкладка «Git» ---
    [void](Add-FormLabel -Parent $tabGit -Text "URL Git-репозитория:" -Left $labelLeft -Top ($topStart + 3))
    $tbRepo = Add-FormTextBox -Parent $tabGit -Left $fieldLeft -Top $topStart -Width ($fieldWidth + $browseWidth + 10) -Value ([string]$Existing.GitRepoUrl)

    $lblHint = New-Object System.Windows.Forms.Label
    $lblHint.Text = "При первом запуске Git покажет окно авторизации."
    $lblHint.Left = $fieldLeft
    $lblHint.Top = $topStart + $rowHeight - 4
    $lblHint.Width = 400; $lblHint.Height = 20
    $lblHint.ForeColor = [System.Drawing.Color]::Gray
    $tabGit.Controls.Add($lblHint)

    [void](Add-FormLabel -Parent $tabGit -Text "Ветка:" -Left $labelLeft -Top ($topStart + ($rowHeight * 2) + 3))
    $branchValue = "main"
    if ($Existing.GitBranch) { $branchValue = $Existing.GitBranch }
    $tbBranch = Add-FormTextBox -Parent $tabGit -Left $fieldLeft -Top ($topStart + ($rowHeight * 2)) -Width ($fieldWidth + $browseWidth + 10) -Value $branchValue

    $lblBranchHint = New-Object System.Windows.Forms.Label
    $lblBranchHint.Text = "Если ветки ещё нет на сервере, она будет создана при первой отправке."
    $lblBranchHint.Left = $fieldLeft
    $lblBranchHint.Top = $topStart + ($rowHeight * 3) - 4
    $lblBranchHint.Width = 400; $lblBranchHint.Height = 36
    $lblBranchHint.ForeColor = [System.Drawing.Color]::Gray
    $tabGit.Controls.Add($lblBranchHint)

    $chkAutoPush = New-Object System.Windows.Forms.CheckBox
    $chkAutoPush.Text = "Отправлять коммит без подтверждения"
    $chkAutoPush.Left = $labelLeft
    $chkAutoPush.Top = $topStart + ($rowHeight * 4) + 8
    $chkAutoPush.Width = 500
    $chkAutoPush.Checked = [bool]$Existing.AutoConfirmGitPush
    $tabGit.Controls.Add($chkAutoPush)

    $lblAutoPushHint = New-Object System.Windows.Forms.Label
    $lblAutoPushHint.Text = "Если включено, окно со списком изменений не показывается: коммит и push выполняются сразу. Смена URL меняет origin без удаления файлов."
    $lblAutoPushHint.Left = $labelLeft
    $lblAutoPushHint.Top = $topStart + ($rowHeight * 5) + 10
    $lblAutoPushHint.Width = 610; $lblAutoPushHint.Height = 40
    $lblAutoPushHint.ForeColor = [System.Drawing.Color]::Gray
    $tabGit.Controls.Add($lblAutoPushHint)

    $btnCleanClone = New-Object System.Windows.Forms.Button
    $btnCleanClone.Text = "Начать с чистого клона"
    $btnCleanClone.Left = $labelLeft
    $btnCleanClone.Top = $topStart + ($rowHeight * 7)
    $btnCleanClone.Width = 210
    $btnCleanClone.Height = 28
    $tabGit.Controls.Add($btnCleanClone)

    $lblCleanClone = New-Object System.Windows.Forms.Label
    $lblCleanClone.Text = "Удалит локальную копию workdir\\repo и склонирует репозиторий заново."
    $lblCleanClone.Left = $labelLeft + 220
    $lblCleanClone.Top = $topStart + ($rowHeight * 7) + 4
    $lblCleanClone.Width = 390; $lblCleanClone.Height = 36
    $lblCleanClone.ForeColor = [System.Drawing.Color]::Gray
    $tabGit.Controls.Add($lblCleanClone)

    # --- Вкладка «Выгрузка» ---
    $chkMain = New-Object System.Windows.Forms.CheckBox
    $chkMain.Text = "Основная конфигурация"
    $chkMain.Left = $labelLeft; $chkMain.Top = $topStart
    $chkMain.Width = 400
    $chkMain.Checked = [bool]$Existing.ExportMainConfig
    $tabDump.Controls.Add($chkMain)

    $chkExt = New-Object System.Windows.Forms.CheckBox
    $chkExt.Text = "Расширения"
    $chkExt.Left = $labelLeft; $chkExt.Top = $topStart + $rowHeight
    $chkExt.Width = 400
    $chkExt.Checked = [bool]$Existing.ExportExtensions
    $tabDump.Controls.Add($chkExt)

    $chkManual = New-Object System.Windows.Forms.CheckBox
    $chkManual.Text = "Выбрать расширения вручную"
    $chkManual.Left = $labelLeft + 24; $chkManual.Top = $topStart + ($rowHeight * 2)
    $chkManual.Width = 400
    $chkManual.Checked = [bool]$Existing.SelectExtensionsManually
    $tabDump.Controls.Add($chkManual)

    [void](Add-FormLabel -Parent $tabDump -Text "Префикс исключения:" -Left $labelLeft -Top ($topStart + ($rowHeight * 3) + 3))
    $prefixValue = "EF_"
    if ($null -ne $Existing.ExtensionExcludePrefix) { $prefixValue = [string]$Existing.ExtensionExcludePrefix }
    $tbPrefix = Add-FormTextBox -Parent $tabDump -Left $fieldLeft -Top ($topStart + ($rowHeight * 3)) -Width 160 -Value $prefixValue

    $lblPrefixHint = New-Object System.Windows.Forms.Label
    $lblPrefixHint.Text = "Для кнопки «Выполнить всё» состав задают флажки выше. Отдельные кнопки всегда делают только своё действие."
    $lblPrefixHint.Left = $labelLeft
    $lblPrefixHint.Top = $topStart + ($rowHeight * 4) + 8
    $lblPrefixHint.Width = 610; $lblPrefixHint.Height = 36
    $lblPrefixHint.ForeColor = [System.Drawing.Color]::Gray
    $tabDump.Controls.Add($lblPrefixHint)

    [void](Add-FormLabel -Parent $tabDump -Text "Режим выгрузки:" -Left $labelLeft -Top ($topStart + ($rowHeight * 6) + 3) -Width 210)

    $rbDumpAuto = New-Object System.Windows.Forms.RadioButton
    $rbDumpAuto.Text = "Авто (полная, если каталог пустой)"
    $rbDumpAuto.Left = $fieldLeft
    $rbDumpAuto.Top = $topStart + ($rowHeight * 6)
    $rbDumpAuto.Width = 380
    $tabDump.Controls.Add($rbDumpAuto)

    $rbDumpFull = New-Object System.Windows.Forms.RadioButton
    $rbDumpFull.Text = "Полная (каталог очищается)"
    $rbDumpFull.Left = $fieldLeft
    $rbDumpFull.Top = $topStart + ($rowHeight * 7)
    $rbDumpFull.Width = 380
    $tabDump.Controls.Add($rbDumpFull)

    $rbDumpInc = New-Object System.Windows.Forms.RadioButton
    $rbDumpInc.Text = "Инкрементальная (-update)"
    $rbDumpInc.Left = $fieldLeft
    $rbDumpInc.Top = $topStart + ($rowHeight * 8)
    $rbDumpInc.Width = 380
    $tabDump.Controls.Add($rbDumpInc)

    $dumpMode = [string]$Existing.DumpMode
    if ($dumpMode -eq "Full") { $rbDumpFull.Checked = $true }
    elseif ($dumpMode -eq "Incremental") { $rbDumpInc.Checked = $true }
    else { $rbDumpAuto.Checked = $true }

    # --- Вкладка «Загрузка» ---
    $lblLoadWarn = New-Object System.Windows.Forms.Label
    $lblLoadWarn.Text = "Загрузка заменяет конфигурацию в базе 1С файлами из Git. Закройте конфигуратор и пользовательские сеансы. Сделайте копию базы, если данные нельзя потерять."
    $lblLoadWarn.Left = $labelLeft
    $lblLoadWarn.Top = $topStart
    $lblLoadWarn.Width = 650
    $lblLoadWarn.Height = 50
    $lblLoadWarn.ForeColor = [System.Drawing.Color]::Firebrick
    $tabLoad.Controls.Add($lblLoadWarn)

    $chkLoadMain = New-Object System.Windows.Forms.CheckBox
    $chkLoadMain.Text = "Основная конфигурация"
    $chkLoadMain.Left = $labelLeft
    $chkLoadMain.Top = $topStart + ($rowHeight * 2)
    $chkLoadMain.Width = 400
    $chkLoadMain.Checked = [bool]$Existing.LoadMainConfig
    $tabLoad.Controls.Add($chkLoadMain)

    $chkLoadExt = New-Object System.Windows.Forms.CheckBox
    $chkLoadExt.Text = "Расширения"
    $chkLoadExt.Left = $labelLeft
    $chkLoadExt.Top = $topStart + ($rowHeight * 3)
    $chkLoadExt.Width = 400
    $chkLoadExt.Checked = [bool]$Existing.LoadExtensions
    $tabLoad.Controls.Add($chkLoadExt)

    $chkLoadManual = New-Object System.Windows.Forms.CheckBox
    $chkLoadManual.Text = "Выбрать расширения вручную (из папки Git)"
    $chkLoadManual.Left = $labelLeft + 24
    $chkLoadManual.Top = $topStart + ($rowHeight * 4)
    $chkLoadManual.Width = 500
    $chkLoadManual.Checked = [bool]$Existing.LoadSelectExtensionsManually
    $tabLoad.Controls.Add($chkLoadManual)

    $chkUpdateDB = New-Object System.Windows.Forms.CheckBox
    $chkUpdateDB.Text = "Обновить конфигурацию базы данных (UpdateDBCfg)"
    $chkUpdateDB.Left = $labelLeft
    $chkUpdateDB.Top = $topStart + ($rowHeight * 5) + 4
    $chkUpdateDB.Width = 620
    $chkUpdateDB.Checked = [bool]$Existing.UpdateInfobaseCfg
    $tabLoad.Controls.Add($chkUpdateDB)

    $chkDynamic = New-Object System.Windows.Forms.CheckBox
    $chkDynamic.Text = "Динамическое обновление (без монопольного доступа)"
    $chkDynamic.Left = $labelLeft + 24
    $chkDynamic.Top = $topStart + ($rowHeight * 6) + 4
    $chkDynamic.Width = 600
    $chkDynamic.Checked = [bool]$Existing.DynamicUpdateCfg
    $tabLoad.Controls.Add($chkDynamic)

    $lblLoadHint = New-Object System.Windows.Forms.Label
    $lblLoadHint.Text = "Перед загрузкой выполняется git fetch и сброс локальной копии к origin выбранной ветки. Кнопка «Загрузить в 1С» внизу."
    $lblLoadHint.Left = $labelLeft
    $lblLoadHint.Top = $topStart + ($rowHeight * 8)
    $lblLoadHint.Width = 650
    $lblLoadHint.Height = 40
    $lblLoadHint.ForeColor = [System.Drawing.Color]::Gray
    $tabLoad.Controls.Add($lblLoadHint)

    $btnTop = 378
    $btnAll = New-Object System.Windows.Forms.Button
    $btnAll.Text = "Выполнить всё"
    $btnAll.Left = 15; $btnAll.Top = $btnTop; $btnAll.Width = 108; $btnAll.Height = 30
    $btnAll.Anchor = "Top,Left"
    $form.Controls.Add($btnAll)

    $btnConfig = New-Object System.Windows.Forms.Button
    $btnConfig.Text = "Конфигурация"
    $btnConfig.Left = 127; $btnConfig.Top = $btnTop; $btnConfig.Width = 100; $btnConfig.Height = 30
    $form.Controls.Add($btnConfig)

    $btnExt = New-Object System.Windows.Forms.Button
    $btnExt.Text = "Расширения"
    $btnExt.Left = 231; $btnExt.Top = $btnTop; $btnExt.Width = 95; $btnExt.Height = 30
    $form.Controls.Add($btnExt)

    $btnGit = New-Object System.Windows.Forms.Button
    $btnGit.Text = "Синхронизация Git"
    $btnGit.Left = 330; $btnGit.Top = $btnTop; $btnGit.Width = 125; $btnGit.Height = 30
    $form.Controls.Add($btnGit)

    $btnLoad = New-Object System.Windows.Forms.Button
    $btnLoad.Text = "Загрузить в 1С"
    $btnLoad.Left = 459; $btnLoad.Top = $btnTop; $btnLoad.Width = 125; $btnLoad.Height = 30
    $form.Controls.Add($btnLoad)

    $btnCancelOp = New-Object System.Windows.Forms.Button
    $btnCancelOp.Text = "Отмена"
    $btnCancelOp.Left = 620; $btnCancelOp.Top = $btnTop; $btnCancelOp.Width = 90; $btnCancelOp.Height = 30
    $btnCancelOp.Enabled = $false
    $btnCancelOp.Anchor = "Top,Right"
    $btnCancelOp.Add_Click({
        $script:CancelRequested = $true
        $this.Enabled = $false
        $this.Text = "Отмена..."
        Write-Log "Запрошена отмена операции"
        Stop-TrackedProcess -Proc $script:CurrentProcess
    })
    $form.Controls.Add($btnCancelOp)

    $txtTiming = New-Object System.Windows.Forms.TextBox
    $txtTiming.Multiline = $true
    $txtTiming.ReadOnly = $true
    $txtTiming.TabStop = $false
    $txtTiming.Left = 15
    $txtTiming.Top = 416
    $txtTiming.Width = 695
    $txtTiming.Height = 88
    $txtTiming.Anchor = "Top,Left,Right"
    $txtTiming.Text = "Последняя операция ещё не выполнялась."
    $form.Controls.Add($txtTiming)

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Text = "Готово к запуску"
    $lblStatus.Left = 15; $lblStatus.Top = 512
    $lblStatus.Width = 695; $lblStatus.Height = 22
    $lblStatus.Anchor = "Top,Left,Right"
    $lblStatus.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($lblStatus)

    $bar = New-Object System.Windows.Forms.ProgressBar
    $bar.Left = 15; $bar.Top = 536
    $bar.Width = 695; $bar.Height = 18
    $bar.Anchor = "Top,Left,Right"
    $bar.Minimum = 0; $bar.Maximum = 100; $bar.Value = 0
    $form.Controls.Add($bar)

    $lblLog = New-Object System.Windows.Forms.Label
    $lblLog.Text = "Журнал:"
    $lblLog.Left = 15; $lblLog.Top = 560; $lblLog.Width = 100
    $lblLog.Anchor = "Top,Left"
    $form.Controls.Add($lblLog)

    $txtLog = New-Object System.Windows.Forms.TextBox
    $txtLog.Left = 15; $txtLog.Top = 580
    $txtLog.Width = 695; $txtLog.Height = 230
    $txtLog.Anchor = "Top,Bottom,Left,Right"
    $txtLog.Multiline = $true
    $txtLog.ScrollBars = "Vertical"
    $txtLog.ReadOnly = $true
    $txtLog.Font = New-Object System.Drawing.Font("Consolas", 8)
    $txtLog.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $txtLog.ForeColor = [System.Drawing.Color]::LightGreen
    $form.Controls.Add($txtLog)

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
        RbDumpAuto    = $rbDumpAuto
        RbDumpFull    = $rbDumpFull
        RbDumpInc     = $rbDumpInc
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
    $script:TimingBox            = $txtTiming
    $script:MainTabs             = $tabs
    $script:ActionButtons        = @($btnAll, $btnConfig, $btnExt, $btnGit, $btnLoad, $btnCleanClone)

    $btnAll.Add_Click({ Start-UiAction -Action "all" })
    $btnConfig.Add_Click({ Start-UiAction -Action "config" })
    $btnExt.Add_Click({ Start-UiAction -Action "extensions" })
    $btnGit.Add_Click({ Start-UiAction -Action "git" })
    $btnLoad.Add_Click({ Start-UiAction -Action "load" })
    $btnCleanClone.Add_Click({ Start-UiAction -Action "reclone" })

    $form.Add_FormClosing({
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
        Write-Log "Приложение запущено"
        Set-Status -Text "Готово к запуску" -Percent 0
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
    if ($ui.RbDumpFull.Checked) { $dumpMode = "Full" }
    elseif ($ui.RbDumpInc.Checked) { $dumpMode = "Incremental" }

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
    if ($script:TimingBox -and -not $script:TimingBox.IsDisposed) {
        $script:TimingBox.Text = $Text
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
        Set-Status -Text "Готово к запуску"
    }
}

# === ПРОВЕРКА ВВЕДЁННЫХ ДАННЫХ ===
function Test-Config {
    param([PSCustomObject]$Config)

    $errors = @()
    $action = [string]$Config.Action
    if (-not $action) { $action = "all" }

    $need1C = $action -in @("all", "config", "extensions", "load")
    $needGit = $action -in @("all", "git", "reclone", "load")

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
        $errors += "Для «Выполнить всё» отметьте основную конфигурацию и/или расширения на вкладке «Выгрузка»"
    }

    if ($action -eq "load" -and -not $Config.LoadMainConfig -and -not $Config.LoadExtensions) {
        $errors += "Для загрузки в 1С отметьте основную конфигурацию и/или расширения на вкладке «Загрузка»"
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

# === ПОДГОТОВКА РЕПОЗИТОРИЯ ===
function Initialize-GitRepository {
    param(
        [string]$GitExe,
        [string]$RepoDir,
        [string]$RemoteUrl,
        [string]$Branch,
        [string]$GitHome,
        [switch]$SkipPullIfDirty
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
        Invoke-Git -GitExe $GitExe -WorkingDirectory $WorkDir -GitArgs @("clone", $RemoteUrl, $RepoDir)
    }

    Sync-GitOriginUrl -GitExe $GitExe -RepoDir $RepoDir -RemoteUrl $RemoteUrl

    Set-Status -Text "Подготовка ветки $Branch..." -Percent 35
    Write-Log "Подготовка ветки '$Branch'"

    Invoke-Git -GitExe $GitExe -WorkingDirectory $RepoDir -GitArgs @("fetch", "origin") -IgnoreExitCode

    $hasHead = Test-GitHeadExists -GitExe $GitExe -RepoDir $RepoDir
    $hasRemote = Test-GitRemoteBranchExists -GitExe $GitExe -RepoDir $RepoDir -Branch $Branch

    if (-not $hasHead) {
        Initialize-GitUnbornBranch -GitExe $GitExe -RepoDir $RepoDir -Branch $Branch
    }

    if ($hasRemote -and $hasHead) {
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
        Invoke-Git -GitExe $GitExe -WorkingDirectory $RepoDir `
            -GitArgs @("checkout", "-B", $Branch, "origin/$Branch")
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

    $co = Invoke-Git -GitExe $GitExe -WorkingDirectory $RepoDir `
        -GitArgs @("checkout", $Branch) -IgnoreExitCode
    if ($co.ExitCode -ne 0) {
        Invoke-Git -GitExe $GitExe -WorkingDirectory $RepoDir `
            -GitArgs @("checkout", "-B", $Branch, "origin/$Branch")
    }

    Invoke-Git -GitExe $GitExe -WorkingDirectory $RepoDir `
        -GitArgs @("reset", "--hard", "origin/$Branch")
    Invoke-Git -GitExe $GitExe -WorkingDirectory $RepoDir `
        -GitArgs @("clean", "-fd") -IgnoreExitCode | Out-Null
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
        [bool]$IsFirstCommit
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
    Invoke-Git -GitExe $GitExe -WorkingDirectory $RepoDir -GitArgs @("add", "-A")
    $skippedHuge = Undo-OversizedGitIndex -GitExe $GitExe -RepoDir $RepoDir

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

    if ($AutoConfirm) {
        Write-Log "Автоподтверждение коммита включено — окно ревью пропущено"
        $review = [PSCustomObject]@{ Action = "push"; Message = $defaultMsg }
    }
    else {
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
        Start-DumpWatch -Path $short.DumpPath -Title $title

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
        Start-DumpWatch -Path $short.DumpPath -Title $title

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
    Start-DumpWatch -Path $short.DumpPath -Title "Получение списка расширений"

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
            -RemoteUrl $GitRepoUrl -Branch $GitBranch -GitHome $GitHome -SkipPullIfDirty
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
