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
$script:CancelRequested       = $false
$script:CurrentProcess        = $null

# === ЛОГИРОВАНИЕ ===
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogLine = "[$Timestamp] [$Level] $Message"

    try {
        if (-not (Test-Path $WorkDir)) {
            New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
        }
        $LogFile = Join-Path $WorkDir "app.log"
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

function Initialize-WorkDir {
    if (-not (Test-Path $WorkDir)) {
        New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
    }
    if (-not (Test-Path $GitHome)) {
        New-Item -ItemType Directory -Path $GitHome -Force | Out-Null
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
        [switch]$IgnoreExitCode
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

    if ($Stdout) { Write-Log $Stdout.TrimEnd() }
    if ($Stderr) { Write-Log $Stderr.TrimEnd() }

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
        [switch]$IgnoreExitCode
    )

    $params = @{
        FileName           = $GitExe
        ArgumentList       = $GitArgs
        WorkingDirectory   = $WorkingDirectory
        IgnoreExitCode     = $IgnoreExitCode
    }
    return Invoke-CancellableProcess @params
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

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "1C Git Sync - Выполняется"
    $form.Width = 720
    $form.Height = 560
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ControlBox = $false
    $form.Font = New-Object System.Drawing.Font("Segoe UI", 9)

    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text = "Текущий шаг:"
    $lblTitle.Left = 15; $lblTitle.Top = 15; $lblTitle.Width = 100
    $form.Controls.Add($lblTitle)

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Text = "Подготовка..."
    $lblStatus.Left = 15; $lblStatus.Top = 35
    $lblStatus.Width = 680; $lblStatus.Height = 22
    $lblStatus.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($lblStatus)

    $bar = New-Object System.Windows.Forms.ProgressBar
    $bar.Left = 15; $bar.Top = 65
    $bar.Width = 680; $bar.Height = 22
    $bar.Minimum = 0; $bar.Maximum = 100; $bar.Value = 0
    $form.Controls.Add($bar)

    $lblLog = New-Object System.Windows.Forms.Label
    $lblLog.Text = "Журнал:"
    $lblLog.Left = 15; $lblLog.Top = 100; $lblLog.Width = 100
    $form.Controls.Add($lblLog)

    $txtLog = New-Object System.Windows.Forms.TextBox
    $txtLog.Left = 15; $txtLog.Top = 120
    $txtLog.Width = 680; $txtLog.Height = 330
    $txtLog.Multiline = $true
    $txtLog.ScrollBars = "Vertical"
    $txtLog.ReadOnly = $true
    $txtLog.Font = New-Object System.Drawing.Font("Consolas", 8)
    $txtLog.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $txtLog.ForeColor = [System.Drawing.Color]::LightGreen
    $form.Controls.Add($txtLog)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Отмена"
    $btnCancel.Left = 605
    $btnCancel.Top = 465
    $btnCancel.Width = 90
    $btnCancel.Height = 28
    $btnCancel.Add_Click({
        $script:CancelRequested = $true
        $this.Enabled = $false
        $this.Text = "Отмена..."
        Write-Log "Запрошена отмена операции"
        Stop-TrackedProcess -Proc $script:CurrentProcess
    })
    $form.Controls.Add($btnCancel)

    $script:ProgressForm         = $form
    $script:ProgressLabel        = $lblStatus
    $script:ProgressBar          = $bar
    $script:ProgressLog          = $txtLog
    $script:ProgressCancelButton = $btnCancel

    $form.Show()
    [System.Windows.Forms.Application]::DoEvents()
}

function Close-ProgressForm {
    if ($script:ProgressForm) {
        $script:ProgressForm.Close()
        $script:ProgressForm.Dispose()
        $script:ProgressForm = $null
        $script:ProgressLabel = $null
        $script:ProgressBar = $null
        $script:ProgressLog = $null
        $script:ProgressCancelButton = $null
    }
}

function Get-DefaultConfig {
    return [PSCustomObject]@{
        PlatformPath               = ""
        DBType                     = "File"
        InfobasePath               = ""
        User                       = ""
        GitRepoUrl                 = ""
        GitBranch                  = "main"
        ExportMainConfig           = $true
        ExportExtensions           = $true
        SelectExtensionsManually   = $false
        ExtensionExcludePrefix     = "EF_"
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

# === ФОРМА НАСТРОЕК ===
function Show-SettingsForm {
    param([PSCustomObject]$Existing)

    $Existing = Merge-Config -Existing $Existing

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "1C Git Sync - Настройки"
    $form.Width = 700
    $form.Height = 600
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.Font = New-Object System.Drawing.Font("Segoe UI", 9)

    $tabs = New-Object System.Windows.Forms.TabControl
    $tabs.Left = 10; $tabs.Top = 10
    $tabs.Width = 665; $tabs.Height = 430
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
    $lblPrefixHint.Text = "Для кнопки «Выполнить всё» состав задают флажки выше. Отдельные кнопки внизу всегда делают только своё действие. Префикс и ручной выбор действуют при выгрузке расширений."
    $lblPrefixHint.Left = $labelLeft
    $lblPrefixHint.Top = $topStart + ($rowHeight * 4) + 8
    $lblPrefixHint.Width = 610; $lblPrefixHint.Height = 50
    $lblPrefixHint.ForeColor = [System.Drawing.Color]::Gray
    $tabDump.Controls.Add($lblPrefixHint)

    $form.Height = 600
    $tabs.Height = 410

    $chosen = @{ Action = $null }

    $btnAll = New-Object System.Windows.Forms.Button
    $btnAll.Text = "Выполнить всё"
    $btnAll.Left = 15; $btnAll.Top = 430; $btnAll.Width = 150; $btnAll.Height = 30
    $btnAll.Add_Click({
        $chosen.Action = "all"
        $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $form.Close()
    })
    $form.Controls.Add($btnAll)
    $form.AcceptButton = $btnAll

    $btnConfig = New-Object System.Windows.Forms.Button
    $btnConfig.Text = "Конфигурация"
    $btnConfig.Left = 175; $btnConfig.Top = 430; $btnConfig.Width = 130; $btnConfig.Height = 30
    $btnConfig.Add_Click({
        $chosen.Action = "config"
        $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $form.Close()
    })
    $form.Controls.Add($btnConfig)

    $btnExt = New-Object System.Windows.Forms.Button
    $btnExt.Text = "Расширения"
    $btnExt.Left = 315; $btnExt.Top = 430; $btnExt.Width = 120; $btnExt.Height = 30
    $btnExt.Add_Click({
        $chosen.Action = "extensions"
        $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $form.Close()
    })
    $form.Controls.Add($btnExt)

    $btnGit = New-Object System.Windows.Forms.Button
    $btnGit.Text = "Синхронизация Git"
    $btnGit.Left = 445; $btnGit.Top = 430; $btnGit.Width = 140; $btnGit.Height = 30
    $btnGit.Add_Click({
        $chosen.Action = "git"
        $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $form.Close()
    })
    $form.Controls.Add($btnGit)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Отмена"
    $btnCancel.Left = 595; $btnCancel.Top = 430; $btnCancel.Width = 80; $btnCancel.Height = 30
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($btnCancel)
    $form.CancelButton = $btnCancel

    $lblActions = New-Object System.Windows.Forms.Label
    $lblActions.Text = "Выгрузить конфигурацию и расширения можно по отдельности. Git только отправит уже выгруженные файлы в выбранную ветку."
    $lblActions.Left = 15; $lblActions.Top = 468; $lblActions.Width = 660; $lblActions.Height = 36
    $lblActions.ForeColor = [System.Drawing.Color]::Gray
    $form.Controls.Add($lblActions)

    $result = $form.ShowDialog()
    if ($result -ne [System.Windows.Forms.DialogResult]::OK -or -not $chosen.Action) {
        return $null
    }

    if ($rbServer.Checked) {
        $DbType = "Server"
        $InfobasePath = "$($tbServerHost.Text.Trim())\$($tbServerBase.Text.Trim())"
    }
    else {
        $DbType = "File"
        $InfobasePath = $tbFileBase.Text.Trim()
    }

    $branch = $tbBranch.Text.Trim()
    if (-not $branch) { $branch = "main" }

    return [PSCustomObject]@{
        Action                   = $chosen.Action
        PlatformPath             = $tbPlatform.Text.Trim()
        DBType                   = $DbType
        InfobasePath             = $InfobasePath
        User                     = $tbUser.Text.Trim()
        Password                 = $tbPass.Text
        GitRepoUrl               = $tbRepo.Text.Trim()
        GitBranch                = $branch
        ExportMainConfig         = [bool]$chkMain.Checked
        ExportExtensions         = [bool]$chkExt.Checked
        SelectExtensionsManually = [bool]$chkManual.Checked
        ExtensionExcludePrefix   = $tbPrefix.Text.Trim()
    }
}

# === ПРОВЕРКА ВВЕДЁННЫХ ДАННЫХ ===
function Test-Config {
    param([PSCustomObject]$Config)

    $errors = @()
    $action = [string]$Config.Action
    if (-not $action) { $action = "all" }

    $need1C = $action -in @("all", "config", "extensions")
    $needGit = $action -in @("all", "git")

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

    $gitUrl = [string]$Config.GitRepoUrl
    if ($needGit -or ($gitUrl -and $action -in @("config", "extensions"))) {
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

    while ($true) {
        $cfg = Show-SettingsForm -Existing $existing
        if ($null -eq $cfg) {
            exit 0
        }

        $errors = Test-Config -Config $cfg
        if ($errors.Count -eq 0) {
            $saved = [PSCustomObject]@{
                PlatformPath             = $cfg.PlatformPath
                DBType                   = $cfg.DBType
                InfobasePath             = $cfg.InfobasePath
                User                     = $cfg.User
                GitRepoUrl               = $cfg.GitRepoUrl
                GitBranch                = $cfg.GitBranch
                ExportMainConfig         = $cfg.ExportMainConfig
                ExportExtensions         = $cfg.ExportExtensions
                SelectExtensionsManually = $cfg.SelectExtensionsManually
                ExtensionExcludePrefix   = $cfg.ExtensionExcludePrefix
            }
            $saved | ConvertTo-Json | Set-Content -Path $ConfigPath -Encoding UTF8
            return $cfg
        }

        $msg = "Обнаружены ошибки:`r`n`r`n" + ($errors -join "`r`n")
        [System.Windows.Forms.MessageBox]::Show(
            $msg, "Проверьте настройки",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null

        $existing = $cfg
    }
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
        [string]$ExcludePrefix
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
    $lbl.Text = "Отметьте расширения для выгрузки:"
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
    $btnDump.Text = "Выгрузить выбранные"
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

function Show-CompletionForm {
    param(
        [string]$Title,
        [string]$Message,
        [switch]$ShowRepoButton
    )

    $form = New-Object System.Windows.Forms.Form
    $form.Text = $Title
    $form.Width = 500
    $form.Height = 210
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.Font = New-Object System.Drawing.Font("Segoe UI", 9)

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $Message
    $lbl.Left = 20; $lbl.Top = 20; $lbl.Width = 440; $lbl.Height = 80
    $form.Controls.Add($lbl)

    $x = 20
    if ($ShowRepoButton) {
        $btnRepo = New-Object System.Windows.Forms.Button
        $btnRepo.Text = "Открыть папку репозитория"
        $btnRepo.Left = $x; $btnRepo.Top = 115; $btnRepo.Width = 190; $btnRepo.Height = 28
        $btnRepo.Add_Click({
            if (Test-Path $GitRepo) { Invoke-Item $GitRepo }
        })
        $form.Controls.Add($btnRepo)
        $x = 220
    }

    $btnLog = New-Object System.Windows.Forms.Button
    $btnLog.Text = "Открыть лог"
    $btnLog.Left = $x; $btnLog.Top = 115; $btnLog.Width = 110; $btnLog.Height = 28
    $btnLog.Add_Click({
        $log = Join-Path $WorkDir "app.log"
        if (Test-Path $log) { Invoke-Item $log }
    })
    $form.Controls.Add($btnLog)

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = "OK"
    $btnOk.Left = 375; $btnOk.Top = 115; $btnOk.Width = 90; $btnOk.Height = 28
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

    Set-Status -Text "Переключение на ветку $Branch..." -Percent 35
    Write-Log "Подготовка ветки '$Branch'"

    Invoke-Git -GitExe $GitExe -WorkingDirectory $RepoDir -GitArgs @("fetch", "origin") -IgnoreExitCode

    $ls = Invoke-Git -GitExe $GitExe -WorkingDirectory $RepoDir `
        -GitArgs @("ls-remote", "--heads", "origin", $Branch) -IgnoreExitCode
    $hasRemote = $ls.Stdout -and $ls.Stdout.Trim()

    $dirty = $false
    if ($SkipPullIfDirty) {
        $st = Invoke-Git -GitExe $GitExe -WorkingDirectory $RepoDir `
            -GitArgs @("status", "--porcelain") -IgnoreExitCode
        if ($st.Stdout -and $st.Stdout.Trim()) {
            $dirty = $true
            Write-Log "Есть локальные изменения — git pull пропущен, чтобы не затереть выгрузку"
        }
    }

    if ($hasRemote) {
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
    else {
        Write-Log "Удалённая ветка '$Branch' ещё не создана (пустой репозиторий)"
        $co = Invoke-Git -GitExe $GitExe -WorkingDirectory $RepoDir `
            -GitArgs @("checkout", "-B", $Branch) -IgnoreExitCode
        if ($co.ExitCode -ne 0) {
            Write-Log "Ветка будет создана при первом коммите"
        }
    }
}

# === ПУБЛИКАЦИЯ В GIT ===
function Invoke-GitPublish {
    param(
        [string]$GitExe,
        [string]$RepoDir,
        [string]$Branch,
        [string]$GitHome
    )

    Test-Cancelled
    $env:HOME = $GitHome

    if (-not $Branch) { $Branch = "main" }

    Set-Status -Text "Добавление изменений в индекс..." -Percent 90
    Invoke-Git -GitExe $GitExe -WorkingDirectory $RepoDir -GitArgs @("add", "-A")

    $statusResult = Invoke-Git -GitExe $GitExe -WorkingDirectory $RepoDir `
        -GitArgs @("status", "--porcelain") -IgnoreExitCode
    $statusText = ""
    if ($statusResult.Stdout) { $statusText = $statusResult.Stdout.TrimEnd() }

    if (-not $statusText) {
        Write-Log "Нет изменений для коммита"
        Set-Status -Text "Нет изменений для коммита" -Percent 98
        return "none"
    }

    $statResult = Invoke-Git -GitExe $GitExe -WorkingDirectory $RepoDir `
        -GitArgs @("diff", "--cached", "--stat") -IgnoreExitCode
    $statText = ""
    if ($statResult.Stdout) { $statText = $statResult.Stdout.TrimEnd() }

    $defaultMsg = "Auto-update: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

    Set-ProgressCancelEnabled -Enabled $false
    $review = Show-DiffReviewForm -StatusText $statusText -StatText $statText -DefaultMessage $defaultMsg
    Set-ProgressCancelEnabled -Enabled $true
    Test-Cancelled

    switch ($review.Action) {
        "cancel" {
            Invoke-Git -GitExe $GitExe -WorkingDirectory $RepoDir -GitArgs @("reset") -IgnoreExitCode
            throw (New-Object System.OperationCanceledException("Операция отменена пользователем"))
        }
        "skip" {
            Invoke-Git -GitExe $GitExe -WorkingDirectory $RepoDir -GitArgs @("reset") -IgnoreExitCode
            Write-Log "Отправка в Git пропущена пользователем"
            Set-Status -Text "Изменения оставлены локально" -Percent 98
            return "skip"
        }
        "push" {
            $msg = [string]$review.Message
            $msg = $msg -replace '"', "'"
            Set-Status -Text "Коммит изменений..." -Percent 92
            Invoke-Git -GitExe $GitExe -WorkingDirectory $RepoDir -GitArgs @("commit", "-m", $msg)
            Set-Status -Text "Отправка в удалённый репозиторий (git push)..." -Percent 95
            Invoke-Git -GitExe $GitExe -WorkingDirectory $RepoDir -GitArgs @("push", "-u", "origin", $Branch)
            Set-Status -Text "Синхронизация с Git завершена" -Percent 98
            Write-Log "Синхронизация с Git завершена"
            return "push"
        }
        default {
            Invoke-Git -GitExe $GitExe -WorkingDirectory $RepoDir -GitArgs @("reset") -IgnoreExitCode
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
        throw "Выгрузка не удалась (код $exitCode). $hint"
    }

    return [PSCustomObject]@{
        ExitCode   = $exitCode
        LogText    = $logText
        DumpResult = $dumpResult
    }
}

# === ВЫГРУЗКА 1С В ФАЙЛЫ ===
function Invoke-1CExport {
    param(
        [string]$Platform,
        [string]$DBType,
        [string]$BasePath,
        [string]$User,
        [string]$Password,
        [string]$OutputPath,
        [string]$Extension = $null,
        [int]$ProgressFrom = 40,
        [int]$ProgressTo   = 80
    )

    Test-Cancelled
    Clear-ExportPath -Path $OutputPath

    $short = Enter-ShortDumpPath -TargetPath $OutputPath
    $dumpArg = $short.DumpPath
    if ($dumpArg -match '\s') { $dumpArg = "`"$dumpArg`"" }

    $ConnParams = Get-1CConnectionParams -DBType $DBType -BasePath $BasePath
    $ArgLine = "DESIGNER $ConnParams /N `"$User`" /P `"$Password`" /DumpConfigToFiles $dumpArg -Format Hierarchical"

    if ($Extension) {
        $ArgLine += " -Extension `"$Extension`""
        Write-Log "Выгрузка расширения: $Extension"
        Set-Status -Text "Выгрузка расширения: $Extension" -Percent $ProgressFrom
    }
    else {
        Write-Log "Выгрузка основной конфигурации"
        Set-Status -Text "Выгрузка основной конфигурации..." -Percent $ProgressFrom
    }

    try {
        $marker = Join-Path $OutputPath "Configuration.xml"
        Invoke-1CDesigner -Platform $Platform -ArgumentString $ArgLine -SuccessMarker $marker | Out-Null
    }
    finally {
        Exit-ShortDumpPath -Info $short
    }
    Write-Log "Выгрузка завершена: $OutputPath"
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

    try {
        Invoke-1CDesigner -Platform $Platform -ArgumentString $ArgLine -IgnoreExitCode | Out-Null
    }
    catch [System.OperationCanceledException] {
        if (Test-Path $TempDir) { Remove-Item $TempDir -Recurse -Force -ErrorAction SilentlyContinue }
        throw
    }
    finally {
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
        [string]$ExcludePrefix
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
            -Extension $ExtName `
            -ProgressFrom $PercentFrom -ProgressTo $PercentTo
    }
}

# === ТОЧКА ВХОДА ПРИЛОЖЕНИЯ ===
try {
    Initialize-WorkDir

    $Config = Get-Config
    $Action                    = [string]$Config.Action
    if (-not $Action) { $Action = "all" }
    $PlatformPath              = $Config.PlatformPath
    $DBType                    = $Config.DBType
    $InfobasePath              = $Config.InfobasePath
    $1CUser                    = $Config.User
    $1CPassword                = $Config.Password
    $GitRepoUrl                = $Config.GitRepoUrl
    $GitBranch                 = $Config.GitBranch
    $ExportMainConfig          = [bool]$Config.ExportMainConfig
    $ExportExtensions          = [bool]$Config.ExportExtensions
    $SelectExtensionsManually  = [bool]$Config.SelectExtensionsManually
    $ExtensionExcludePrefix    = [string]$Config.ExtensionExcludePrefix

    $doMain = ($Action -eq "config") -or ($Action -eq "all" -and $ExportMainConfig)
    $doExt  = ($Action -eq "extensions") -or ($Action -eq "all" -and $ExportExtensions)
    $doGitPublish = $Action -in @("all", "git")
    $doGitPrepare = $doGitPublish -or (($doMain -or $doExt) -and $GitRepoUrl)

    Show-ProgressForm
    Set-Status -Text "Начало работы..." -Percent 5
    Write-Log "Действие: $Action"
    Write-Log "Запуск: $PlatformPath"
    Write-Log "Тип базы: $DBType"
    Write-Log "База: $InfobasePath"
    Write-Log "Репозиторий: $GitRepoUrl"
    Write-Log "Ветка: $GitBranch"
    Write-Log "Выгрузка конфигурации: $doMain; расширения: $doExt; Git: $doGitPublish"

    if ($doGitPrepare) {
        $EmbeddedGit = Join-Path $AppDir "PortableGit-64-bit.7z.exe"
        Initialize-PortableGit -EmbeddedArchive $EmbeddedGit
        Initialize-GitIdentity -GitExe $GitExe -GitHome $GitHome
        Initialize-GitRepository -GitExe $GitExe -RepoDir $GitRepo `
            -RemoteUrl $GitRepoUrl -Branch $GitBranch -GitHome $GitHome `
            -SkipPullIfDirty:($Action -eq "git")
    }
    elseif ($doMain -or $doExt) {
        if (-not (Test-Path $GitRepo)) {
            New-Item -ItemType Directory -Path $GitRepo -Force | Out-Null
        }
    }

    if ($doMain) {
        Invoke-1CExport -Platform $PlatformPath -DBType $DBType -BasePath $InfobasePath `
            -User $1CUser -Password $1CPassword -OutputPath $ConfigExportPath `
            -ProgressFrom 45 -ProgressTo 65
    }
    elseif ($Action -eq "all") {
        Write-Log "Выгрузка основной конфигурации пропущена"
    }

    if ($doExt) {
        Invoke-DumpExtensionsPipeline -Platform $PlatformPath -DBType $DBType `
            -BasePath $InfobasePath -User $1CUser -Password $1CPassword `
            -RepoDir $GitRepo -SelectManually $SelectExtensionsManually `
            -ExcludePrefix $ExtensionExcludePrefix
    }
    elseif ($Action -eq "all") {
        Write-Log "Выгрузка расширений отключена в настройках"
    }

    $publishResult = $null
    if ($doGitPublish) {
        Test-Cancelled
        $publishResult = Invoke-GitPublish -GitExe $GitExe -RepoDir $GitRepo `
            -Branch $GitBranch -GitHome $GitHome
    }

    Set-Status -Text "Готово!" -Percent 100
    Write-Log "Операция успешно завершена"
    Start-Sleep -Seconds 1
    Close-ProgressForm

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

    Show-CompletionForm -Title "1C Git Sync" -Message $doneMessage -ShowRepoButton
}
catch [System.OperationCanceledException] {
    Write-Log "Операция отменена пользователем"
    Set-Status -Text "Операция отменена" -Percent 100
    Close-ProgressForm
    [System.Windows.Forms.MessageBox]::Show(
        "Операция отменена.",
        "1C Git Sync",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    exit 0
}
catch {
    Write-Log "КРИТИЧЕСКАЯ ОШИБКА: $_" "ERROR"
    Set-Status -Text "Ошибка: $_" -Percent 100
    Start-Sleep -Seconds 1
    Close-ProgressForm

    Show-CompletionForm -Title "1C Git Sync" -Message "Ошибка:`r`n`r`n$_`r`n`r`nЛог: $WorkDir\app.log"
    exit 1
}
