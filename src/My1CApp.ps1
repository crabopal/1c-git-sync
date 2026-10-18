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

# Плоский архив (так его копирует обновление 1.12 и 2.0) раскладывается
# в src и redist уже после замены файлов. Репозиторий этот шаг пропускает:
# рядом со скриптом в src нет PortableGit-64-bit.7z.exe.
function Get-InstallLayoutWorker {
    return @'
param([string]$Root, [int]$WaitPid)
$ErrorActionPreference = "Stop"
try {
while ($WaitPid -and (Get-Process -Id $WaitPid -ErrorAction SilentlyContinue)) {
    Start-Sleep -Milliseconds 400
}

function Move-LayoutFile {
    param([string]$From, [string]$ToDir)
    if (-not (Test-Path -LiteralPath $From)) { return }
    if (-not (Test-Path -LiteralPath $ToDir)) {
        New-Item -ItemType Directory -Path $ToDir -Force | Out-Null
    }
    $dest = Join-Path $ToDir (Split-Path -Leaf $From)
    for ($i = 0; $i -lt 15; $i++) {
        try {
            if (Test-Path -LiteralPath $dest) {
                Remove-Item -LiteralPath $dest -Force -ErrorAction Stop
            }
            Move-Item -LiteralPath $From -Destination $dest -ErrorAction Stop
            return
        }
        catch {
            Start-Sleep -Milliseconds 400
        }
    }
    throw "Не удалось перенести $From"
}

$src = Join-Path $Root "src"
$redist = Join-Path $Root "redist"
Move-LayoutFile -From (Join-Path $Root "My1CApp.ps1") -ToDir $src
Move-LayoutFile -From (Join-Path $Root "run.bat") -ToDir $src
Move-LayoutFile -From (Join-Path $Root "app.ico") -ToDir $src
Move-LayoutFile -From (Join-Path $Root "PortableGit-64-bit.7z.exe") -ToDir $redist

$logDir = Join-Path $Root "workdir"
if (-not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}
$line = "[{0}] [INFO] Файлы программы разложены по папкам src и redist" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
Add-Content -LiteralPath (Join-Path $logDir "app.log") -Value $line -Encoding UTF8

$exe = Join-Path $Root "1C Git Sync.exe"
$bat = Join-Path $src "run.bat"
if (Test-Path -LiteralPath $exe) {
    Start-Process -FilePath $exe -WorkingDirectory $Root | Out-Null
}
elseif (Test-Path -LiteralPath $bat) {
    Start-Process -FilePath $bat -WorkingDirectory $Root | Out-Null
}
Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue
}
catch {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show(
            "Не удалось разложить файлы программы по папкам src и redist.`r`n`r`n$_",
            "1C Git Sync",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    }
    catch { }
    exit 1
}
'@
}

function Start-InstallLayoutMigration {
    param([string]$Root)
    if (-not $Root) { return }
    if (Test-Path -LiteralPath (Join-Path $Root ".git")) { return }
    $git = Join-Path $Root "PortableGit-64-bit.7z.exe"
    $ps1 = Join-Path $Root "My1CApp.ps1"
    if (-not (Test-Path -LiteralPath $git)) { return }
    if (-not (Test-Path -LiteralPath $ps1)) { return }

    $work = Join-Path $Root "workdir"
    if (-not (Test-Path -LiteralPath $work)) {
        New-Item -ItemType Directory -Path $work -Force | Out-Null
    }
    $helper = Join-Path $work "finish-layout.ps1"
    $utf8 = New-Object System.Text.UTF8Encoding $true
    [System.IO.File]::WriteAllText($helper, (Get-InstallLayoutWorker), $utf8)
    $arg = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$helper`" -Root `"$Root`" -WaitPid $PID"
    Start-Process -FilePath "powershell.exe" -ArgumentList $arg -WindowStyle Hidden | Out-Null
    exit 0
}

$layoutRoot = $PSScriptRoot
if (-not $layoutRoot -and $PSCommandPath) {
    $layoutRoot = Split-Path -Parent $PSCommandPath
}
elseif (-not $layoutRoot -and $MyInvocation.MyCommand.Path) {
    $layoutRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}
Start-InstallLayoutMigration -Root $layoutRoot

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
$ScriptDir = $AppDir

# Скрипт лежит в src, а workdir, VERSION и exe — в корне.
# Так устроен репозиторий и установка после раскладки файлов.
$devRoot = Split-Path $ScriptDir -Parent
$devGit = Join-Path $devRoot "redist\PortableGit-64-bit.7z.exe"
if (((Split-Path $ScriptDir -Leaf) -eq "src") -and (Test-Path -LiteralPath $devGit)) {
    $AppDir = $devRoot
    $EmbeddedGit = $devGit
}
else {
    $EmbeddedGit = Join-Path $AppDir "PortableGit-64-bit.7z.exe"
}

$WorkDir          = Join-Path $AppDir "workdir"
$GitDir           = Join-Path $WorkDir "PortableGit"
$GitExe           = Join-Path $GitDir "cmd\git.exe"
$GitHome          = Join-Path $WorkDir "git-home"
$GitRepo          = Join-Path $WorkDir "repo"
$ConfigExportPath = Join-Path $GitRepo "Config"
$ConfigPath       = Join-Path $WorkDir "config.json"
$AppVersion       = "2.0.3"
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
        [int]$PollMs = 40
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

    while (-not $Proc.WaitForExit(40)) {
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
    if ($Busy -and $script:ProgressBar -and -not $script:ProgressBar.IsDisposed) {
        $script:ProgressBar.Value = 0
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

# === ИНТЕРФЕЙС ===
function Initialize-UiTheme {
    if ($script:UiThemeReady) { return }
    $script:UiFont = New-Object System.Drawing.Font("Segoe UI", 10)
    $script:UiFontBold = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $script:UiFontTitle = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
    $script:UiFontSmall = New-Object System.Drawing.Font("Segoe UI", 9)
    $script:UiFontLog = New-Object System.Drawing.Font("Consolas", 9)
    $script:UiColor = [PSCustomObject]@{
        Window     = [System.Drawing.Color]::FromArgb(244, 245, 247)
        Card       = [System.Drawing.Color]::White
        Border     = [System.Drawing.Color]::FromArgb(218, 220, 224)
        Text       = [System.Drawing.Color]::FromArgb(32, 33, 36)
        Muted      = [System.Drawing.Color]::FromArgb(95, 99, 104)
        Accent     = [System.Drawing.Color]::FromArgb(37, 99, 235)
        AccentDown = [System.Drawing.Color]::FromArgb(29, 78, 216)
        NavActive  = [System.Drawing.Color]::FromArgb(232, 240, 254)
        WarnBg     = [System.Drawing.Color]::FromArgb(255, 244, 229)
        WarnText   = [System.Drawing.Color]::FromArgb(146, 64, 14)
        LogBg      = [System.Drawing.Color]::FromArgb(24, 24, 27)
        LogFg      = [System.Drawing.Color]::FromArgb(228, 228, 231)
    }
    $script:UiThemeReady = $true
}

function Enable-UiDoubleBuffer {
    param($Control)
    try {
        $flags = [System.Reflection.BindingFlags]"Instance,NonPublic"
        $prop = $Control.GetType().GetProperty("DoubleBuffered", $flags)
        if ($prop) { $prop.SetValue($Control, $true, $null) }
    }
    catch { }
}

function Update-UiNavButton {
    param($Button, [bool]$Active)
    $c = $script:UiColor
    if ($Active) {
        $Button.BackColor = $c.NavActive
        $Button.ForeColor = $c.Accent
        $Button.Font = $script:UiFontBold
    }
    else {
        $Button.BackColor = $c.Card
        $Button.ForeColor = $c.Text
        $Button.Font = $script:UiFont
    }
}

function New-UiNavButton {
    param($Parent, [string]$Text)
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = "   $Text"
    $btn.Dock = "Top"
    $btn.Height = 40
    $btn.FlatStyle = "Flat"
    $btn.FlatAppearance.BorderSize = 0
    $btn.TextAlign = "MiddleLeft"
    $btn.Cursor = [System.Windows.Forms.Cursors]::Hand
    $btn.FlatAppearance.MouseOverBackColor = $script:UiColor.NavActive
    $btn.FlatAppearance.MouseDownBackColor = $script:UiColor.NavActive
    Update-UiNavButton -Button $btn -Active $false
    $Parent.Controls.Add($btn)
    return $btn
}

function New-UiButton {
    param(
        $Parent = $null,
        [string]$Text,
        [int]$Width = 140,
        [int]$Height = 36,
        [ValidateSet("Primary", "Secondary")]
        [string]$Kind = "Secondary"
    )
    $c = $script:UiColor
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = $Text
    $btn.Width = $Width
    $btn.Height = $Height
    $btn.FlatStyle = "Flat"
    $btn.Font = $script:UiFont
    $btn.Cursor = [System.Windows.Forms.Cursors]::Hand
    if ($Kind -eq "Primary") {
        $btn.BackColor = $c.Accent
        $btn.ForeColor = [System.Drawing.Color]::White
        $btn.FlatAppearance.BorderSize = 0
        $btn.FlatAppearance.MouseOverBackColor = $c.AccentDown
        $btn.FlatAppearance.MouseDownBackColor = $c.AccentDown
    }
    else {
        $btn.BackColor = $c.Card
        $btn.ForeColor = $c.Text
        $btn.FlatAppearance.BorderSize = 1
        $btn.FlatAppearance.BorderColor = $c.Border
        $btn.FlatAppearance.MouseOverBackColor = $c.NavActive
        $btn.FlatAppearance.MouseDownBackColor = $c.NavActive
    }
    if ($Parent) { $Parent.Controls.Add($btn) }
    return $btn
}

function New-UiCaption {
    param($Parent, [string]$Text, [int]$Top, [int]$Left = 0)
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $Text
    $lbl.Left = $Left
    $lbl.Top = $Top
    $lbl.Height = 18
    $lbl.Width = 420
    $lbl.Font = $script:UiFontSmall
    $lbl.ForeColor = $script:UiColor.Muted
    $lbl.BackColor = $Parent.BackColor
    $Parent.Controls.Add($lbl)
    return $lbl
}

function New-UiTextBox {
    param($Parent, [int]$Top, [int]$Left = 0, [int]$Width = 280, [string]$Value = "")
    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Left = $Left
    $tb.Top = $Top
    $tb.Width = $Width
    $tb.Font = $script:UiFont
    $tb.Text = $Value
    $tb.BorderStyle = "FixedSingle"
    $Parent.Controls.Add($tb)
    return $tb
}

function New-UiCheckBox {
    param($Parent, [string]$Text, [int]$Top, [int]$Left = 0, [bool]$Checked = $false, [int]$Width = 480)
    $cb = New-Object System.Windows.Forms.CheckBox
    $cb.Text = $Text
    $cb.Left = $Left
    $cb.Top = $Top
    $cb.Width = $Width
    $cb.Height = 24
    $cb.Checked = $Checked
    $cb.Font = $script:UiFont
    $cb.ForeColor = $script:UiColor.Text
    $cb.BackColor = $Parent.BackColor
    $Parent.Controls.Add($cb)
    return $cb
}

function Register-UiGrow {
    param($Parent, $Box, $Button)
    $handler = {
        $w = $Parent.ClientSize.Width
        if ($w -lt 160) { return }
        if ($Button) {
            $Button.Left = $w - $Button.Width
            $Box.Width = [Math]::Max(80, $w - $Button.Width - 8)
        }
        else {
            $Box.Width = $w
        }
    }.GetNewClosure()
    $Parent.Add_Resize($handler)
    & $handler
}

function New-UiStack {
    param($Parent)
    $stack = New-Object System.Windows.Forms.Panel
    $stack.Dock = "Fill"
    $stack.AutoScroll = $true
    $stack.BackColor = $script:UiColor.Window
    $Parent.Controls.Add($stack)
    Enable-UiDoubleBuffer $stack
    $script:UiStacks = @($script:UiStacks) + $stack
    $stack.Tag = New-Object System.Collections.Generic.List[object]
    $stack.Add_Resize({ Update-UiStacks })
    return $stack
}

function Register-UiStackItem {
    param($Stack, $Control)
    if (-not $Stack.Tag) {
        $Stack.Tag = New-Object System.Collections.Generic.List[object]
    }
    [void]$Stack.Tag.Add($Control)
}

function Update-UiStacks {
    if ($script:UiStackLayout) { return }
    $script:UiStackLayout = $true
    try {
        $scrollW = [System.Windows.Forms.SystemInformation]::VerticalScrollBarWidth
        foreach ($stack in @($script:UiStacks)) {
            if (-not $stack -or $stack.IsDisposed) { continue }
            $w = $stack.Width - 32 - $scrollW
            if ($w -lt 280) { continue }
            $items = @()
            if ($stack.Tag) { $items = @($stack.Tag) }
            if ($items.Count -eq 0) { $items = @($stack.Controls) }
            $scrollY = 0
            if ($stack.AutoScrollPosition) { $scrollY = [Math]::Abs($stack.AutoScrollPosition.Y) }
            $stack.SuspendLayout()
            $stack.AutoScroll = $false
            $y = 16
            foreach ($card in $items) {
                if (-not $card -or $card.IsDisposed) { continue }
                $card.Left = 16
                $card.Top = $y
                if ($card.Width -ne $w) { $card.Width = $w }
                $y += $card.Height + 12
            }
            $stack.AutoScrollMinSize = New-Object System.Drawing.Size(0, ($y + 8))
            $stack.AutoScroll = $true
            if ($scrollY -gt 0) {
                $stack.AutoScrollPosition = New-Object System.Drawing.Point(0, (-1 * $scrollY))
            }
            $stack.ResumeLayout()
        }
    }
    finally {
        $script:UiStackLayout = $false
    }
}

function New-UiCard {
    param($Stack, [string]$Title, [int]$BodyHeight)
    $c = $script:UiColor
    $card = New-Object System.Windows.Forms.Panel
    $card.BackColor = $c.Card
    $card.Height = 52 + $BodyHeight
    $card.Width = 640
    $card.Padding = New-Object System.Windows.Forms.Padding(16, 12, 16, 12)
    $card.Add_Paint({
        param($sender, $e)
        if ($sender.Width -lt 2 -or $sender.Height -lt 2) { return }
        $pen = New-Object System.Drawing.Pen($script:UiColor.Border)
        $rect = New-Object System.Drawing.Rectangle(0, 0, ($sender.Width - 1), ($sender.Height - 1))
        $e.Graphics.DrawRectangle($pen, $rect)
        $pen.Dispose()
    })
    $card.Add_Resize({ $this.Invalidate() })

    $body = New-Object System.Windows.Forms.Panel
    $body.Dock = "Fill"
    $body.BackColor = $c.Card
    $card.Controls.Add($body)

    $titleLbl = New-Object System.Windows.Forms.Label
    $titleLbl.Text = $Title
    $titleLbl.Dock = "Top"
    $titleLbl.Height = 28
    $titleLbl.Font = $script:UiFontBold
    $titleLbl.ForeColor = $c.Text
    $titleLbl.BackColor = $c.Card
    $card.Controls.Add($titleLbl)

    $Stack.Controls.Add($card)
    Register-UiStackItem -Stack $Stack -Control $card
    return [PSCustomObject]@{ Card = $card; Body = $body }
}

function New-UiActionBar {
    param($Parent)
    $bar = New-Object System.Windows.Forms.Panel
    $bar.Dock = "Bottom"
    $bar.Height = 64
    $bar.BackColor = $script:UiColor.Window
    $Parent.Controls.Add($bar)
    return $bar
}

function Get-AppIcon {
    if ($script:AppIcon) { return $script:AppIcon }
    foreach ($path in @(
        (Join-Path $ScriptDir "app.ico"),
        (Join-Path $AppDir "app.ico")
    )) {
        if (Test-Path -LiteralPath $path) {
            $script:AppIcon = New-Object System.Drawing.Icon -ArgumentList $path
            break
        }
    }
    return $script:AppIcon
}

function Set-AppIcon {
    param($Form)
    $icon = Get-AppIcon
    if ($icon -and $Form) { $Form.Icon = $icon }
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
    if (-not $found) { throw "В архиве обновления нет My1CApp.ps1" }
    $dir = $found.DirectoryName
    # Архив новой раскладки: My1CApp.ps1 в src, рядом exe и redist.
    # Копировать нужно родителя, иначе обновление заберёт только src.
    if ((Split-Path $dir -Leaf) -eq "src") {
        $parent = Split-Path $dir -Parent
        if ($parent -and (Test-Path -LiteralPath (Join-Path $parent "src\My1CApp.ps1"))) {
            return $parent
        }
    }
    return $dir
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
        "Доступна версия $($rel.Version) (сейчас $currentText).`r`n`r`nСкачать релиз и перезапустить программу?`r`nКаталог workdir не изменяется. Скрипт, run.bat, иконка и PortableGit переносятся в папки src и redist.",
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

        $utf8 = New-Object System.Text.UTF8Encoding $true
        $layoutPs1 = Join-Path $WorkDir "finish-layout.ps1"
        [System.IO.File]::WriteAllText($layoutPs1, (Get-InstallLayoutWorker), $utf8)

        $updPs1 = Join-Path $WorkDir "apply-update.ps1"
        $updText = @"
param([string]`$Src, [string]`$Dst, [int]`$WaitPid)
while (Get-Process -Id `$WaitPid -ErrorAction SilentlyContinue) {
    Start-Sleep -Seconds 1
}
Copy-Item -Path (Join-Path `$Src '*') -Destination `$Dst -Recurse -Force
`$layout = Join-Path `$Dst 'workdir\finish-layout.ps1'
if (Test-Path -LiteralPath `$layout) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File `$layout -Root `$Dst -WaitPid 0
}
else {
    `$srcDir = Join-Path `$Dst 'src'
    `$redistDir = Join-Path `$Dst 'redist'
    foreach (`$name in @('My1CApp.ps1', 'run.bat', 'app.ico')) {
        `$from = Join-Path `$Dst `$name
        if (Test-Path -LiteralPath `$from) {
            if (-not (Test-Path -LiteralPath `$srcDir)) { New-Item -ItemType Directory -Path `$srcDir -Force | Out-Null }
            `$dest = Join-Path `$srcDir `$name
            if (Test-Path -LiteralPath `$dest) { Remove-Item -LiteralPath `$dest -Force }
            Move-Item -LiteralPath `$from -Destination `$dest
        }
    }
    `$gitFrom = Join-Path `$Dst 'PortableGit-64-bit.7z.exe'
    if (Test-Path -LiteralPath `$gitFrom) {
        if (-not (Test-Path -LiteralPath `$redistDir)) { New-Item -ItemType Directory -Path `$redistDir -Force | Out-Null }
        `$gitTo = Join-Path `$redistDir 'PortableGit-64-bit.7z.exe'
        if (Test-Path -LiteralPath `$gitTo) { Remove-Item -LiteralPath `$gitTo -Force }
        Move-Item -LiteralPath `$gitFrom -Destination `$gitTo
    }
    `$exe = Join-Path `$Dst '1C Git Sync.exe'
    `$bat = Join-Path `$Dst 'src\run.bat'
    if (-not (Test-Path -LiteralPath `$bat)) { `$bat = Join-Path `$Dst 'run.bat' }
    if (Test-Path -LiteralPath `$exe) {
        Start-Process -FilePath `$exe -WorkingDirectory `$Dst | Out-Null
    }
    elseif (Test-Path -LiteralPath `$bat) {
        Start-Process -FilePath `$bat -WorkingDirectory `$Dst | Out-Null
    }
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


function Show-SettingsForm {
    param([PSCustomObject]$Existing)

    Initialize-UiTheme
    $script:UiStacks = @()
    $Existing = Merge-Config -Existing $Existing
    $c = $script:UiColor

    $form = New-Object System.Windows.Forms.Form
    Set-AppIcon -Form $form
    $form.Text = "1C Git Sync " + (Get-AppVersion)
    $form.Width = 980
    $form.Height = 720
    $form.StartPosition = "CenterScreen"
    $form.MinimumSize = New-Object System.Drawing.Size(880, 640)
    $form.Font = $script:UiFont
    $form.BackColor = $c.Window
    $form.ForeColor = $c.Text
    Enable-UiDoubleBuffer $form

    $tip = New-Object System.Windows.Forms.ToolTip
    $tip.AutoPopDelay = 12000
    $tip.InitialDelay = 400

    $pnlNav = New-Object System.Windows.Forms.Panel
    $pnlNav.Dock = "Left"
    $pnlNav.Width = 200
    $pnlNav.BackColor = $c.Card

    $sep = New-Object System.Windows.Forms.Panel
    $sep.Dock = "Left"
    $sep.Width = 1
    $sep.BackColor = $c.Border

    $pnlMain = New-Object System.Windows.Forms.Panel
    $pnlMain.Dock = "Fill"
    $pnlMain.BackColor = $c.Window

    $form.Controls.Add($pnlMain)
    $form.Controls.Add($sep)
    $form.Controls.Add($pnlNav)

    $pnlNavFoot = New-Object System.Windows.Forms.Panel
    $pnlNavFoot.Dock = "Bottom"
    $pnlNavFoot.Height = 84
    $pnlNavFoot.BackColor = $c.Card
    $pnlNavFoot.Padding = New-Object System.Windows.Forms.Padding(12, 8, 12, 12)

    $lblVersion = New-Object System.Windows.Forms.Label
    $lblVersion.Text = "Версия " + (Get-AppVersion)
    $lblVersion.Dock = "Top"
    $lblVersion.Height = 22
    $lblVersion.Font = $script:UiFontSmall
    $lblVersion.ForeColor = $c.Muted
    $lblVersion.BackColor = $c.Card
    $pnlNavFoot.Controls.Add($lblVersion)

    $btnUpdate = New-UiButton -Text "Обновить" -Width 160 -Height 32 -Kind Secondary
    $btnUpdate.Dock = "Bottom"
    $tip.SetToolTip($btnUpdate, "Проверить GitHub Releases и установить новую версию")
    $pnlNavFoot.Controls.Add($btnUpdate)
    $pnlNav.Controls.Add($pnlNavFoot)

    $btnNavSettings = New-UiNavButton -Parent $pnlNav -Text "Настройки"
    $btnNavLoad = New-UiNavButton -Parent $pnlNav -Text "Загрузка"
    $btnNavDump = New-UiNavButton -Parent $pnlNav -Text "Выгрузка"

    $lblBrand = New-Object System.Windows.Forms.Label
    $lblBrand.Text = "  1C Git Sync"
    $lblBrand.Dock = "Top"
    $lblBrand.Height = 52
    $lblBrand.Font = $script:UiFontTitle
    $lblBrand.ForeColor = $c.Text
    $lblBrand.BackColor = $c.Card
    $lblBrand.TextAlign = "MiddleLeft"
    $pnlNav.Controls.Add($lblBrand)

    $pnlHeader = New-Object System.Windows.Forms.Panel
    $pnlHeader.Dock = "Top"
    $pnlHeader.Height = 68
    $pnlHeader.BackColor = $c.Card

    $lblHeaderBranch = New-Object System.Windows.Forms.Label
    $lblHeaderBranch.Dock = "Top"
    $lblHeaderBranch.Height = 20
    $lblHeaderBranch.Font = $script:UiFontSmall
    $lblHeaderBranch.ForeColor = $c.Muted
    $lblHeaderBranch.BackColor = $c.Card
    $lblHeaderBranch.AutoEllipsis = $true
    $lblHeaderBranch.Padding = New-Object System.Windows.Forms.Padding(20, 0, 16, 0)
    $lblHeaderBranch.Text = "ветка main"
    $pnlHeader.Controls.Add($lblHeaderBranch)

    $lblHeaderBase = New-Object System.Windows.Forms.Label
    $lblHeaderBase.Dock = "Top"
    $lblHeaderBase.Height = 28
    $lblHeaderBase.Font = $script:UiFontBold
    $lblHeaderBase.ForeColor = $c.Text
    $lblHeaderBase.BackColor = $c.Card
    $lblHeaderBase.AutoEllipsis = $true
    $lblHeaderBase.Padding = New-Object System.Windows.Forms.Padding(20, 12, 16, 0)
    $lblHeaderBase.Text = "База не выбрана"
    $pnlHeader.Controls.Add($lblHeaderBase)

    $hdrLine = New-Object System.Windows.Forms.Panel
    $hdrLine.Dock = "Bottom"
    $hdrLine.Height = 1
    $hdrLine.BackColor = $c.Border
    $pnlHeader.Controls.Add($hdrLine)

    $pnlLog = New-Object System.Windows.Forms.Panel
    $pnlLog.Dock = "Bottom"
    $pnlLog.Height = 190
    $pnlLog.BackColor = $c.LogBg

    $pnlLogBar = New-Object System.Windows.Forms.Panel
    $pnlLogBar.Dock = "Top"
    $pnlLogBar.Height = 68
    $pnlLogBar.BackColor = $c.Window
    $pnlLogBar.Padding = New-Object System.Windows.Forms.Padding(16, 6, 12, 4)

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Text = "Готово к запуску"
    $lblStatus.Dock = "Fill"
    $lblStatus.Font = $script:UiFont
    $lblStatus.ForeColor = $c.Text
    $lblStatus.BackColor = $c.Window
    $lblStatus.TextAlign = "MiddleLeft"
    $lblStatus.AutoEllipsis = $true
    $pnlLogBar.Controls.Add($lblStatus)

    $btnCancelOp = New-UiButton -Text "Отмена" -Width 96 -Height 30 -Kind Secondary
    $btnCancelOp.Dock = "Right"
    $btnCancelOp.Enabled = $false
    $btnCancelOp.Add_Click({
        $script:CancelRequested = $true
        $this.Enabled = $false
        $this.Text = "Отмена..."
        Write-Log "Запрошена отмена операции"
        Stop-TrackedProcess -Proc $script:CurrentProcess
    })
    $pnlLogBar.Controls.Add($btnCancelOp)

    $bar = New-Object System.Windows.Forms.ProgressBar
    $bar.Dock = "Bottom"
    $bar.Height = 18
    $bar.Minimum = 0
    $bar.Maximum = 100
    $bar.Value = 0
    $pnlLogBar.Controls.Add($bar)

    $txtLog = New-Object System.Windows.Forms.TextBox
    $txtLog.Dock = "Fill"
    $txtLog.Multiline = $true
    $txtLog.ScrollBars = "Vertical"
    $txtLog.ReadOnly = $true
    $txtLog.BorderStyle = "None"
    $txtLog.Font = $script:UiFontLog
    $txtLog.BackColor = $c.LogBg
    $txtLog.ForeColor = $c.LogFg

    $logLine = New-Object System.Windows.Forms.Panel
    $logLine.Dock = "Top"
    $logLine.Height = 1
    $logLine.BackColor = $c.Border

    $pnlLog.Controls.Add($txtLog)
    $pnlLog.Controls.Add($logLine)
    $pnlLog.Controls.Add($pnlLogBar)

    $pnlPages = New-Object System.Windows.Forms.Panel
    $pnlPages.Dock = "Fill"
    $pnlPages.BackColor = $c.Window

    $pnlMain.Controls.Add($pnlPages)
    $pnlMain.Controls.Add($pnlHeader)
    $pnlMain.Controls.Add($pnlLog)

    $pageDump = New-Object System.Windows.Forms.Panel
    $pageDump.Dock = "Fill"
    $pageDump.BackColor = $c.Window
    $pageLoad = New-Object System.Windows.Forms.Panel
    $pageLoad.Dock = "Fill"
    $pageLoad.BackColor = $c.Window
    $pageSettings = New-Object System.Windows.Forms.Panel
    $pageSettings.Dock = "Fill"
    $pageSettings.BackColor = $c.Window
    $pnlPages.Controls.Add($pageSettings)
    $pnlPages.Controls.Add($pageLoad)
    $pnlPages.Controls.Add($pageDump)

    $ShowPage = {
        param([string]$Name)
        $pageDump.Visible = ($Name -eq "Dump")
        $pageLoad.Visible = ($Name -eq "Load")
        $pageSettings.Visible = ($Name -eq "Settings")
        Update-UiNavButton -Button $btnNavDump -Active ($Name -eq "Dump")
        Update-UiNavButton -Button $btnNavLoad -Active ($Name -eq "Load")
        Update-UiNavButton -Button $btnNavSettings -Active ($Name -eq "Settings")
        Update-UiStacks
    }
    $btnNavDump.Add_Click({ & $ShowPage "Dump" })
    $btnNavLoad.Add_Click({ & $ShowPage "Load" })
    $btnNavSettings.Add_Click({ & $ShowPage "Settings" })

    # --- Выгрузка ---
    $stackDump = New-UiStack -Parent $pageDump
    $barDump = New-UiActionBar -Parent $pageDump

    $dumpCard = New-UiCard -Stack $stackDump -Title "Состав" -BodyHeight 108
    $chkMain = New-UiCheckBox -Parent $dumpCard.Body -Text "Основная конфигурация" -Top 4 -Checked ([bool]$Existing.ExportMainConfig)
    $chkExt = New-UiCheckBox -Parent $dumpCard.Body -Text "Расширения" -Top 36 -Checked ([bool]$Existing.ExportExtensions)
    $chkManual = New-UiCheckBox -Parent $dumpCard.Body -Text "Выбрать расширения вручную" -Top 68 -Left 20 -Checked ([bool]$Existing.SelectExtensionsManually)
    $chkManual.Enabled = $chkExt.Checked
    $chkExt.Add_CheckedChanged({ $chkManual.Enabled = $chkExt.Checked })

    $paramCard = New-UiCard -Stack $stackDump -Title "Параметры" -BodyHeight 112
    [void](New-UiCaption -Parent $paramCard.Body -Text "Префикс исключения" -Top 0)
    $prefixValue = "EF_"
    if ($null -ne $Existing.ExtensionExcludePrefix) { $prefixValue = [string]$Existing.ExtensionExcludePrefix }
    $tbPrefix = New-UiTextBox -Parent $paramCard.Body -Top 20 -Width 180 -Value $prefixValue
    $tip.SetToolTip($tbPrefix, "Расширения с этим префиксом не выгружаются, если список не выбирается вручную")
    [void](New-UiCaption -Parent $paramCard.Body -Text "Режим выгрузки" -Top 52)
    $cbDumpMode = New-Object System.Windows.Forms.ComboBox
    $cbDumpMode.Left = 0
    $cbDumpMode.Top = 72
    $cbDumpMode.Width = 420
    $cbDumpMode.DropDownStyle = "DropDownList"
    $cbDumpMode.Font = $script:UiFont
    [void]$cbDumpMode.Items.Add("Авто (полная, если каталог пустой)")
    [void]$cbDumpMode.Items.Add("Полная (каталог очищается)")
    [void]$cbDumpMode.Items.Add("Инкрементальная (-update)")
    $dumpMode = [string]$Existing.DumpMode
    if ($dumpMode -eq "Full") { $cbDumpMode.SelectedIndex = 1 }
    elseif ($dumpMode -eq "Incremental") { $cbDumpMode.SelectedIndex = 2 }
    else { $cbDumpMode.SelectedIndex = 0 }
    $paramCard.Body.Controls.Add($cbDumpMode)
    Register-UiGrow -Parent $paramCard.Body -Box $cbDumpMode

    $btnDump = New-UiButton -Parent $barDump -Text "Выгрузить в Git" -Width 180 -Kind Primary
    $btnDump.Left = 16
    $btnDump.Top = 14
    $tip.SetToolTip($btnDump, "Выгружает отмеченный состав и отправляет коммит в Git")

    $btnGit = New-UiButton -Parent $barDump -Text "Только Git" -Width 120 -Kind Secondary
    $btnGit.Left = 208
    $btnGit.Top = 14
    $tip.SetToolTip($btnGit, "Индексация, commit и push уже выгруженных файлов")

    $btnPushOnly = New-UiButton -Parent $barDump -Text "Только push" -Width 130 -Kind Secondary
    $btnPushOnly.Left = 340
    $btnPushOnly.Top = 14
    $tip.SetToolTip($btnPushOnly, "Отправляет уже созданные локальные коммиты. Не индексирует файлы и не создаёт коммит")

    # --- Загрузка ---
    $stackLoad = New-UiStack -Parent $pageLoad
    $barLoad = New-UiActionBar -Parent $pageLoad

    $warn = New-Object System.Windows.Forms.Panel
    $warn.Height = 72
    $warn.BackColor = $c.WarnBg
    $lblLoadWarn = New-Object System.Windows.Forms.Label
    $lblLoadWarn.Text = "Конфигурация в базе 1С будет заменена файлами из Git. Закройте конфигуратор и сеансы, при необходимости сделайте копию базы."
    $lblLoadWarn.Dock = "Fill"
    $lblLoadWarn.Padding = New-Object System.Windows.Forms.Padding(12, 8, 12, 8)
    $lblLoadWarn.Font = $script:UiFontSmall
    $lblLoadWarn.ForeColor = $c.WarnText
    $lblLoadWarn.BackColor = $c.WarnBg
    $warn.Controls.Add($lblLoadWarn)
    $stackLoad.Controls.Add($warn)
    Register-UiStackItem -Stack $stackLoad -Control $warn

    $loadCard = New-UiCard -Stack $stackLoad -Title "Состав" -BodyHeight 168
    $chkLoadMain = New-UiCheckBox -Parent $loadCard.Body -Text "Основная конфигурация" -Top 4 -Checked ([bool]$Existing.LoadMainConfig)
    $chkLoadExt = New-UiCheckBox -Parent $loadCard.Body -Text "Расширения" -Top 36 -Checked ([bool]$Existing.LoadExtensions)
    $chkLoadManual = New-UiCheckBox -Parent $loadCard.Body -Text "Выбрать расширения вручную (из папки Git)" -Top 68 -Left 20 -Checked ([bool]$Existing.LoadSelectExtensionsManually)
    $chkLoadManual.Enabled = $chkLoadExt.Checked
    $chkLoadExt.Add_CheckedChanged({ $chkLoadManual.Enabled = $chkLoadExt.Checked })
    $chkUpdateDB = New-UiCheckBox -Parent $loadCard.Body -Text "Обновить конфигурацию базы данных" -Top 100 -Checked ([bool]$Existing.UpdateInfobaseCfg)
    $tip.SetToolTip($chkUpdateDB, "UpdateDBCfg после загрузки файлов")
    $chkDynamic = New-UiCheckBox -Parent $loadCard.Body -Text "Динамическое обновление (без монопольного доступа)" -Top 132 -Left 20 -Checked ([bool]$Existing.DynamicUpdateCfg)
    $chkDynamic.Enabled = $chkUpdateDB.Checked
    $chkUpdateDB.Add_CheckedChanged({ $chkDynamic.Enabled = $chkUpdateDB.Checked })

    $btnLoad = New-UiButton -Parent $barLoad -Text "Загрузить в 1С" -Width 180 -Kind Primary
    $btnLoad.Left = 16
    $btnLoad.Top = 14
    $tip.SetToolTip($btnLoad, "Заменяет конфигурацию в базе файлами из Git по флажкам на этой странице")

    # --- Настройки ---
    $stackSettings = New-UiStack -Parent $pageSettings
    $baseCard = New-UiCard -Stack $stackSettings -Title "База" -BodyHeight 280
    $bodyBase = $baseCard.Body

    $lblIBase = New-UiCaption -Parent $bodyBase -Text "База из списка" -Top 0
    $cbIBases = New-Object System.Windows.Forms.ComboBox
    $cbIBases.Left = 0
    $cbIBases.Top = 20
    $cbIBases.Width = 360
    $cbIBases.DropDownStyle = "DropDownList"
    $cbIBases.DropDownWidth = 620
    $cbIBases.Font = $script:UiFont
    $bodyBase.Controls.Add($cbIBases)
    $tip.SetToolTip($cbIBases, "Список информационных баз из ibases.v8i")

    $btnBrowseV8i = New-UiButton -Parent $bodyBase -Text "Список..." -Width 96 -Height 28 -Kind Secondary
    $btnBrowseV8i.Top = 18
    $tip.SetToolTip($btnBrowseV8i, "Открыть другой файл ibases.v8i")

    $lblType = New-UiCaption -Parent $bodyBase -Text "Тип базы" -Top 56
    $rbFile = New-Object System.Windows.Forms.RadioButton
    $rbFile.Text = "Файловая"
    $rbFile.Left = 0
    $rbFile.Top = 76
    $rbFile.AutoSize = $true
    $rbFile.Font = $script:UiFont
    $rbFile.BackColor = $c.Card
    $bodyBase.Controls.Add($rbFile)
    $rbServer = New-Object System.Windows.Forms.RadioButton
    $rbServer.Text = "Клиент-серверная"
    $rbServer.Left = 140
    $rbServer.Top = 76
    $rbServer.AutoSize = $true
    $rbServer.Font = $script:UiFont
    $rbServer.BackColor = $c.Card
    $bodyBase.Controls.Add($rbServer)

    $IsServer = $false
    if ($Existing.DBType -eq "Server") { $IsServer = $true }
    elseif ($Existing.InfobasePath -and $Existing.InfobasePath -notmatch '^[a-zA-Z]:\\') { $IsServer = $true }
    if ($IsServer) { $rbServer.Checked = $true } else { $rbFile.Checked = $true }

    $lblFile = New-UiCaption -Parent $bodyBase -Text "Каталог информационной базы" -Top 108
    $fileBaseValue = ""
    if (-not $IsServer) { $fileBaseValue = [string]$Existing.InfobasePath }
    $tbFileBase = New-UiTextBox -Parent $bodyBase -Top 128 -Width 360 -Value $fileBaseValue
    $btnBrowseBase = New-UiButton -Parent $bodyBase -Text "Обзор..." -Width 96 -Height 28 -Kind Secondary
    $btnBrowseBase.Top = 126
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

    $serverHostValue = ""
    $serverBaseValue = ""
    if ($IsServer -and $Existing.InfobasePath) {
        $parts = $Existing.InfobasePath -split '\\', 2
        if ($parts.Count -ge 1) { $serverHostValue = $parts[0] }
        if ($parts.Count -ge 2) { $serverBaseValue = $parts[1] }
    }
    $lblHost = New-UiCaption -Parent $bodyBase -Text "Кластер серверов" -Top 108
    $tbServerHost = New-UiTextBox -Parent $bodyBase -Top 128 -Width 460 -Value $serverHostValue
    $lblBaseName = New-UiCaption -Parent $bodyBase -Text "Имя информационной базы" -Top 164
    $tbServerBase = New-UiTextBox -Parent $bodyBase -Top 184 -Width 460 -Value $serverBaseValue

    $lblPlatform = New-UiCaption -Parent $bodyBase -Text "Путь к 1cv8.exe" -Top 164
    $platformValue = $Existing.PlatformPath
    if (-not $platformValue) {
        $AutoPath = Find-Latest1CPlatform
        if ($AutoPath) { $platformValue = $AutoPath }
        else { $platformValue = "C:\Program Files\1cv8\8.3.XX.XXXX\bin\1cv8.exe" }
    }
    $tbPlatform = New-UiTextBox -Parent $bodyBase -Top 184 -Width 360 -Value $platformValue
    $btnBrowsePlatform = New-UiButton -Parent $bodyBase -Text "Обзор..." -Width 96 -Height 28 -Kind Secondary
    $btnBrowsePlatform.Top = 182
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

    $LayoutBaseCard = {
        $y = 108
        if ($rbServer.Checked) {
            $lblFile.Visible = $false
            $tbFileBase.Visible = $false
            $btnBrowseBase.Visible = $false
            $lblHost.Visible = $true
            $tbServerHost.Visible = $true
            $lblBaseName.Visible = $true
            $tbServerBase.Visible = $true
            $lblHost.Top = $y
            $tbServerHost.Top = $y + 20
            $y += 56
            $lblBaseName.Top = $y
            $tbServerBase.Top = $y + 20
            $y += 56
        }
        else {
            $lblFile.Visible = $true
            $tbFileBase.Visible = $true
            $btnBrowseBase.Visible = $true
            $lblHost.Visible = $false
            $tbServerHost.Visible = $false
            $lblBaseName.Visible = $false
            $tbServerBase.Visible = $false
            $lblFile.Top = $y
            $tbFileBase.Top = $y + 20
            $btnBrowseBase.Top = $y + 18
            $y += 56
        }
        $lblPlatform.Top = $y
        $tbPlatform.Top = $y + 20
        $btnBrowsePlatform.Top = $y + 18
        $y += 52
        $baseCard.Card.Height = 52 + $y
        Update-UiStacks
    }
    $rbFile.Add_CheckedChanged($LayoutBaseCard)
    $rbServer.Add_CheckedChanged($LayoutBaseCard)

    Register-UiGrow -Parent $bodyBase -Box $cbIBases -Button $btnBrowseV8i
    Register-UiGrow -Parent $bodyBase -Box $tbFileBase -Button $btnBrowseBase
    Register-UiGrow -Parent $bodyBase -Box $tbServerHost
    Register-UiGrow -Parent $bodyBase -Box $tbServerBase
    Register-UiGrow -Parent $bodyBase -Box $tbPlatform -Button $btnBrowsePlatform

    $accessCard = New-UiCard -Stack $stackSettings -Title "Доступ" -BodyHeight 148
    [void](New-UiCaption -Parent $accessCard.Body -Text "Пользователь 1С" -Top 0)
    $userValue = "Admin"
    if ($Existing.User) { $userValue = $Existing.User }
    $tbUser = New-UiTextBox -Parent $accessCard.Body -Top 20 -Width 360 -Value $userValue
    [void](New-UiCaption -Parent $accessCard.Body -Text "Пароль 1С" -Top 56)
    $tbPass = New-UiTextBox -Parent $accessCard.Body -Top 76 -Width 360
    $tbPass.UseSystemPasswordChar = $true
    $chkShow = New-UiCheckBox -Parent $accessCard.Body -Text "Показать пароль" -Top 112
    $chkShow.Add_CheckedChanged({ $tbPass.UseSystemPasswordChar = -not $chkShow.Checked })
    Register-UiGrow -Parent $accessCard.Body -Box $tbUser
    Register-UiGrow -Parent $accessCard.Body -Box $tbPass

    $gitCard = New-UiCard -Stack $stackSettings -Title "Git" -BodyHeight 200
    [void](New-UiCaption -Parent $gitCard.Body -Text "URL Git-репозитория" -Top 0)
    $tbRepo = New-UiTextBox -Parent $gitCard.Body -Top 20 -Width 460 -Value ([string]$Existing.GitRepoUrl)
    $tip.SetToolTip($tbRepo, "При первом запуске Git покажет окно авторизации")
    [void](New-UiCaption -Parent $gitCard.Body -Text "Ветка" -Top 56)
    $branchValue = "main"
    if ($Existing.GitBranch) { $branchValue = $Existing.GitBranch }
    $tbBranch = New-UiTextBox -Parent $gitCard.Body -Top 76 -Width 280 -Value $branchValue
    $tip.SetToolTip($tbBranch, "Если ветки ещё нет на сервере, она будет создана при первой отправке")
    $chkAutoPush = New-UiCheckBox -Parent $gitCard.Body -Text "Отправлять коммит без подтверждения" -Top 112 -Checked ([bool]$Existing.AutoConfirmGitPush)
    $tip.SetToolTip($chkAutoPush, "Окно со списком изменений не показывается: коммит и push выполняются сразу")
    $btnCleanClone = New-UiButton -Parent $gitCard.Body -Text "Начать с чистого клона" -Width 210 -Height 32 -Kind Secondary
    $btnCleanClone.Left = 0
    $btnCleanClone.Top = 148
    $tip.SetToolTip($btnCleanClone, "Удалит локальную копию workdir\repo и склонирует репозиторий заново")
    $lblClean = New-Object System.Windows.Forms.Label
    $lblClean.Text = "Удалит локальную копию и клонирует репозиторий заново."
    $lblClean.Left = 222
    $lblClean.Top = 154
    $lblClean.Width = 360
    $lblClean.Height = 24
    $lblClean.Font = $script:UiFontSmall
    $lblClean.ForeColor = $c.Muted
    $lblClean.BackColor = $c.Card
    $gitCard.Body.Controls.Add($lblClean)
    Register-UiGrow -Parent $gitCard.Body -Box $tbRepo
    Register-UiGrow -Parent $gitCard.Body -Box $tbBranch

    $script:IBaseComboItems = @()
    $script:IBasesExtraFile = $null
    $script:IBasesUpdating = $false

    $UpdateHeader = {
        if ($rbServer.Checked) {
            $h = $tbServerHost.Text.Trim()
            $n = $tbServerBase.Text.Trim()
            if ($h -or $n) { $ib = "$h\$n" } else { $ib = "База не выбрана" }
        }
        else {
            $ib = $tbFileBase.Text.Trim()
            if (-not $ib) { $ib = "База не выбрана" }
        }
        $branch = $tbBranch.Text.Trim()
        if (-not $branch) { $branch = "main" }
        $lblHeaderBase.Text = $ib
        $lblHeaderBranch.Text = "ветка $branch"
    }

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
        & $UpdateHeader
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
            & $UpdateHeader
        }
    })

    foreach ($tb in @($tbFileBase, $tbServerHost, $tbServerBase, $tbBranch)) {
        $tb.Add_TextChanged({ & $UpdateHeader })
    }
    $rbFile.Add_CheckedChanged($UpdateHeader)
    $rbServer.Add_CheckedChanged($UpdateHeader)

    & $FillIBaseCombo "" ([string]$Existing.InfobasePath)
    & $LayoutBaseCard
    & $UpdateHeader
    & $ShowPage "Dump"

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
    $script:MainTabs             = $pnlPages
    $script:ActionButtons        = @($btnDump, $btnGit, $btnPushOnly, $btnLoad, $btnCleanClone, $btnUpdate, $btnNavDump, $btnNavLoad, $btnNavSettings)
    $script:SetLogExpanded       = { }

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
        Update-UiStacks
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
        try {
            $rel = Get-LatestAppRelease
            $script:LatestRelease = $rel
            $cur = ConvertTo-AppVersion -Text (Get-AppVersion)
            if ($cur -and $rel.Version -gt $cur) {
                $lblVersion.Text = "Версия $(Get-AppVersion)  ·  доступна $($rel.Version)"
                $lblVersion.ForeColor = [System.Drawing.Color]::DarkOrange
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
    if (-not $script:ProgressLabel -or $script:ProgressLabel.IsDisposed) { return }
    $lines = @($Text -split "`r`n" | Where-Object { $_.Trim() })
    if ($lines.Count -eq 0) { return }
    $head = [string]$lines[0]
    $total = $null
    foreach ($line in $lines) {
        if ($line -like "Всего:*") { $total = [string]$line; break }
    }
    if ($total -and $total -ne $head) {
        $script:ProgressLabel.Text = "$head  ·  $total"
    }
    else {
        $script:ProgressLabel.Text = $head
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

    Initialize-UiTheme
    $c = $script:UiColor
    $form = New-Object System.Windows.Forms.Form
    Set-AppIcon -Form $form
    $form.Text = "1C Git Sync — выбор расширений"
    $form.Width = 520
    $form.Height = 520
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.Font = $script:UiFont
    $form.BackColor = $c.Window
    $form.ForeColor = $c.Text

    $list = New-Object System.Windows.Forms.CheckedListBox
    $list.Dock = "Fill"
    $list.CheckOnClick = $true
    $list.BorderStyle = "None"
    $list.Font = $script:UiFont
    $list.BackColor = $c.Card
    $list.IntegralHeight = $false
    foreach ($name in $Extensions) {
        $idx = $list.Items.Add($name)
        $checked = -not (Test-NameHasPrefix -Name $name -Prefix $ExcludePrefix)
        $list.SetItemChecked($idx, $checked)
    }
    $form.Controls.Add($list)

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $PromptText
    $lbl.Dock = "Top"
    $lbl.Height = 48
    $lbl.Padding = New-Object System.Windows.Forms.Padding(16, 14, 16, 8)
    $lbl.Font = $script:UiFont
    $lbl.ForeColor = $c.Text
    $lbl.BackColor = $c.Window
    $form.Controls.Add($lbl)

    $bar = New-Object System.Windows.Forms.Panel
    $bar.Dock = "Bottom"
    $bar.Height = 64
    $bar.BackColor = $c.Window
    $form.Controls.Add($bar)

    $state = @{ Action = "skip" }

    $btnDump = New-UiButton -Parent $bar -Text $AcceptText -Width 200 -Kind Primary
    $btnDump.Left = 16
    $btnDump.Top = 14
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

    $btnSkip = New-UiButton -Parent $bar -Text "Пропустить" -Width 140 -Kind Secondary
    $btnSkip.Left = 228
    $btnSkip.Top = 14
    $btnSkip.DialogResult = [System.Windows.Forms.DialogResult]::Ignore
    $btnSkip.Add_Click({ $state.Action = "skip" })
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

    Initialize-UiTheme
    $c = $script:UiColor
    $form = New-Object System.Windows.Forms.Form
    Set-AppIcon -Form $form
    $form.Text = "1C Git Sync — изменения"
    $form.Width = 800
    $form.Height = 620
    $form.MinimumSize = New-Object System.Drawing.Size(640, 480)
    $form.StartPosition = "CenterScreen"
    $form.Font = $script:UiFont
    $form.BackColor = $c.Window
    $form.ForeColor = $c.Text

    $bottom = New-Object System.Windows.Forms.Panel
    $bottom.Dock = "Bottom"
    $bottom.Height = 120
    $bottom.BackColor = $c.Window

    $txtDiff = New-Object System.Windows.Forms.TextBox
    $txtDiff.Dock = "Fill"
    $txtDiff.Multiline = $true
    $txtDiff.ScrollBars = "Both"
    $txtDiff.ReadOnly = $true
    $txtDiff.WordWrap = $false
    $txtDiff.BorderStyle = "None"
    $txtDiff.Font = $script:UiFontLog
    $txtDiff.BackColor = $c.LogBg
    $txtDiff.ForeColor = $c.LogFg
    $txtDiff.Text = "Файлы:`r`n$StatusText`r`n`r`nСводка:`r`n$StatText"
    $form.Controls.Add($txtDiff)
    $form.Controls.Add($bottom)

    $lblMsg = New-Object System.Windows.Forms.Label
    $lblMsg.Text = "Сообщение коммита"
    $lblMsg.Left = 16
    $lblMsg.Top = 10
    $lblMsg.Width = 240
    $lblMsg.Height = 18
    $lblMsg.Font = $script:UiFontSmall
    $lblMsg.ForeColor = $c.Muted
    $bottom.Controls.Add($lblMsg)

    $tbMsg = New-Object System.Windows.Forms.TextBox
    $tbMsg.Left = 16
    $tbMsg.Top = 32
    $tbMsg.Width = 740
    $tbMsg.Anchor = "Top,Left,Right"
    $tbMsg.Font = $script:UiFont
    $tbMsg.BorderStyle = "FixedSingle"
    $tbMsg.Text = $DefaultMessage
    $bottom.Controls.Add($tbMsg)

    $state = @{ Action = "cancel"; Message = $DefaultMessage }

    $btnSkip = New-UiButton -Parent $bottom -Text "Пропустить" -Width 120 -Kind Secondary
    $btnSkip.Left = 16
    $btnSkip.Top = 70
    $btnSkip.Add_Click({
        $state.Action = "skip"
        $state.Message = $tbMsg.Text
        $form.DialogResult = [System.Windows.Forms.DialogResult]::Ignore
        $form.Close()
    })

    $btnCancel = New-UiButton -Parent $bottom -Text "Отмена" -Width 100 -Kind Secondary
    $btnCancel.Left = 148
    $btnCancel.Top = 70
    $btnCancel.Add_Click({
        $state.Action = "cancel"
        $form.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $form.Close()
    })
    $form.CancelButton = $btnCancel

    $btnPush = New-UiButton -Parent $bottom -Text "Закоммитить и отправить" -Width 230 -Kind Primary
    $btnPush.Top = 70
    $btnPush.Anchor = "Top,Right"
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
    $form.Add_Shown({
        $btnPush.Left = $bottom.ClientSize.Width - $btnPush.Width - 16
    })
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
        [object[]]$Steps,
        [datetime]$StartedAt,
        [datetime]$EndedAt
    )

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($step in @($Steps)) {
        if (-not $step) { continue }
        $elapsedText = "не выполнялась"
        if ($step.Timing) {
            $elapsedText = Format-ElapsedTime -Elapsed $step.Timing.Elapsed
        }
        $lines.Add("$($step.Name): $elapsedText")
    }

    $lines.Add("")
    $lines.Add("Всего: $(Format-ElapsedTime -Elapsed ($EndedAt - $StartedAt))")
    $lines.Add("Начало: $(Format-DateTimeStamp -Value $StartedAt)")
    $lines.Add("Окончание: $(Format-DateTimeStamp -Value $EndedAt)")
    return ($lines -join "`r`n")
}

function New-TimingStep {
    param([string]$Name, $Timing)
    return [PSCustomObject]@{
        Name   = $Name
        Timing = $Timing
    }
}

function Write-TimingSummary {
    param([string]$Text)
    foreach ($timingLine in ($Text -split "`r`n")) {
        if ($timingLine) { Write-Log $timingLine }
    }
}

function Show-CompletionForm {
    param(
        [string]$Title,
        [string]$Message,
        [switch]$ShowRepoButton
    )

    Initialize-UiTheme
    $c = $script:UiColor
    $lineCount = @($Message -split "`r?`n").Count
    $msgHeight = [Math]::Max(80, [Math]::Min(260, ($lineCount * 18) + 16))

    $form = New-Object System.Windows.Forms.Form
    Set-AppIcon -Form $form
    $form.Text = $Title
    $form.Width = 560
    $form.Height = $msgHeight + 150
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.Font = $script:UiFont
    $form.BackColor = $c.Window
    $form.ForeColor = $c.Text

    $bar = New-Object System.Windows.Forms.Panel
    $bar.Dock = "Bottom"
    $bar.Height = 64
    $bar.BackColor = $c.Window

    $box = New-Object System.Windows.Forms.TextBox
    $box.Multiline = $true
    $box.ReadOnly = $true
    $box.TabStop = $false
    $box.BorderStyle = "None"
    $box.BackColor = $c.Window
    $box.ForeColor = $c.Text
    $box.Font = $script:UiFont
    $box.Dock = "Fill"
    $box.Text = $Message
    $form.Padding = New-Object System.Windows.Forms.Padding(16, 12, 16, 0)
    $form.Controls.Add($box)
    $form.Controls.Add($bar)

    $x = 16
    if ($ShowRepoButton) {
        $btnRepo = New-UiButton -Parent $bar -Text "Папка репозитория" -Width 170 -Kind Secondary
        $btnRepo.Left = $x
        $btnRepo.Top = 14
        $btnRepo.Add_Click({
            if (Test-Path $GitRepo) { Invoke-Item $GitRepo }
        })
        $x = 198
    }

    $btnLog = New-UiButton -Parent $bar -Text "Открыть лог" -Width 120 -Kind Secondary
    $btnLog.Left = $x
    $btnLog.Top = 14
    $btnLog.Add_Click({
        $log = Join-Path $WorkDir "app.log"
        if (Test-Path $log) { Invoke-Item $log }
    })

    $btnOk = New-UiButton -Parent $bar -Text "OK" -Width 90 -Kind Primary
    $btnOk.Top = 14
    $btnOk.Anchor = "Top,Right"
    $btnOk.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.AcceptButton = $btnOk
    $form.Add_Shown({ $btnOk.Left = $bar.ClientSize.Width - $btnOk.Width - 16 })

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
        "/Config/Ext/ParentConfigurations.bin",
        "/Config/Configuration.ParentConfigurations.bin",
        "/Config/Configuration.ParentConfigurations",
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
    $pushStart = Get-Date
    Set-Status -Text "Отправка в удалённый репозиторий (git push)..." -Percent 95

    $isFirstCommit = -not (Test-GitRemoteBranchExists -GitExe $GitExe -RepoDir $RepoDir -Branch $Branch)
    Invoke-GitPushBranch -GitExe $GitExe -RepoDir $RepoDir -Branch $Branch `
        -IsFirstCommit $isFirstCommit -NoReconcile
    $script:RemotePushTiming = New-OpTiming -StartedAt $pushStart -EndedAt (Get-Date)
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
    $script:IndexCommitTiming = $null
    $script:RemotePushTiming = $null

    if (-not $Branch) { $Branch = "main" }

    Ensure-DumpGitIgnore -RepoDir $RepoDir

    $isFirstCommit = -not (Test-GitHeadExists -GitExe $GitExe -RepoDir $RepoDir)
    if ($isFirstCommit) {
        Initialize-GitUnbornBranch -GitExe $GitExe -RepoDir $RepoDir -Branch $Branch
        Write-Log "Режим первого коммита: pull не выполняется, ветка будет создана на сервере при push"
    }

    $indexStart = Get-Date
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
            $script:IndexCommitTiming = New-OpTiming -StartedAt $indexStart -EndedAt (Get-Date)
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
            $script:IndexCommitTiming = New-OpTiming -StartedAt $indexStart -EndedAt (Get-Date)
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
            $script:IndexCommitTiming = New-OpTiming -StartedAt $indexStart -EndedAt (Get-Date)
            return "skip"
        }
        "push" {
            $msg = [string]$review.Message
            $msg = $msg -replace '"', "'"
            Set-Status -Text "Коммит изменений..." -Percent 92
            Invoke-Git -GitExe $GitExe -WorkingDirectory $RepoDir -GitArgs @("commit", "-m", $msg)
            Invoke-Git -GitExe $GitExe -WorkingDirectory $RepoDir `
                -GitArgs @("branch", "-M", $Branch) -IgnoreExitCode | Out-Null
            $script:IndexCommitTiming = New-OpTiming -StartedAt $indexStart -EndedAt (Get-Date)
            $pushStart = Get-Date
            Set-Status -Text "Отправка в удалённый репозиторий (git push)..." -Percent 95
            Invoke-GitPushBranch -GitExe $GitExe -RepoDir $RepoDir -Branch $Branch -IsFirstCommit $isFirstCommit
            $script:RemotePushTiming = New-OpTiming -StartedAt $pushStart -EndedAt (Get-Date)
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
    if (-not $Path) { return $false }
    if ($Path -match 'System\.Object\[\]') { return $false }
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $xmlPath = [System.IO.Path]::Combine($Path, "Configuration.xml")
    return (Test-Path -LiteralPath $xmlPath)
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
        if ($Extension) { $ArgLine += " -Extension `"$Extension`"" }
        if ($useUpdate) { $ArgLine += " -update" }
        $ArgLine += " -Format Hierarchical"

        Write-Log $title
        Set-Status -Text "$title..." -Percent $ProgressFrom

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
            Exit-ShortDumpPath -Info $short
        }

        if (-not $done -and -not $useUpdate -and $attemptedUpdate) {
            Clear-ExportPath -Path $OutputPath
            $attemptedUpdate = $false
        }
    }

    Write-Log "Выгрузка завершена: $OutputPath"
}

function Get-RepoExtensionInfos {
    param([string]$RepoDir)
    $result = New-Object System.Collections.Generic.List[object]
    $root = [System.IO.Path]::Combine([string]$RepoDir, "Extensions")
    if (-not (Test-Path -LiteralPath $root)) {
        Write-Output -NoEnumerate $result
        return
    }

    $dirs = Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue
    if ($null -eq $dirs) {
        Write-Output -NoEnumerate $result
        return
    }
    if ($dirs -isnot [System.Array]) { $dirs = @($dirs) }

    foreach ($dir in $dirs) {
        $folderName = [string]$dir.Name
        $folderPath = [string]$dir.FullName
        $xmlPath = [System.IO.Path]::Combine($folderPath, "Configuration.xml")
        if (-not (Test-Path -LiteralPath $xmlPath)) { continue }
        $meta = Get-ConfigurationDumpMeta -ConfigXmlPath $xmlPath
        $internalName = [string]$meta.Name
        if (-not $internalName) { $internalName = $folderName }
        $result.Add([PSCustomObject]@{
            FolderName = $folderName
            Path       = $folderPath
            Name       = $internalName
        })
    }
    Write-Output -NoEnumerate $result
}

function Get-RepoExtensionNames {
    param([string]$RepoDir)
    $names = New-Object System.Collections.Generic.List[string]
    $infos = Get-RepoExtensionInfos -RepoDir $RepoDir
    for ($i = 0; $i -lt $infos.Count; $i++) {
        [void]$names.Add([string]$infos[$i].Name)
    }
    Write-Output -NoEnumerate $names
}

function Test-VendorParentCfPresent {
    param([string]$DumpPath)
    $dir = Join-Path $DumpPath "Ext\ParentConfigurations"
    if (-not (Test-Path -LiteralPath $dir)) { return $false }
    $cfs = @(Get-ChildItem -LiteralPath $dir -Filter "*.cf" -File -ErrorAction SilentlyContinue)
    return ($cfs.Count -gt 0)
}

function Repair-DumpCatalogForLoad {
    param([string]$DumpPath)
    if (-not $DumpPath -or -not (Test-Path -LiteralPath $DumpPath)) { return }

    if (Test-VendorParentCfPresent -DumpPath $DumpPath) {
        Write-Log "Найдены файлы конфигурации поставщика (*.cf) — загрузка с поддержкой"
        return
    }

    $candidates = @(
        (Join-Path $DumpPath "Configuration.ParentConfigurations.bin"),
        (Join-Path $DumpPath "Configuration.ParentConfigurations.xml"),
        (Join-Path $DumpPath "Configuration.ParentConfigurations"),
        (Join-Path $DumpPath "Ext\ParentConfigurations.bin"),
        (Join-Path $DumpPath "Ext\ParentConfigurations.xml")
    )

    $removed = @()
    foreach ($f in $candidates) {
        if (Test-Path -LiteralPath $f) {
            Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
            $removed += [System.IO.Path]::GetFileName($f)
        }
    }

    $parentDir = Join-Path $DumpPath "Ext\ParentConfigurations"
    if (Test-Path -LiteralPath $parentDir) {
        Remove-Item -LiteralPath $parentDir -Recurse -Force -ErrorAction SilentlyContinue
        $removed += "Ext/ParentConfigurations/"
    }

    if ($removed.Count -gt 0) {
        Write-Log "Файлы конфигурации поставщика (*.cf) не хранятся в Git из-за размера. Настройки поддержки убраны для загрузки:"
        foreach ($name in $removed) { Write-Log "  $name" }
        Write-Log "Конфигурация будет загружена как снятая с поддержки"
    }
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

    Repair-DumpCatalogForLoad -DumpPath $InputPath

    $title = "Загрузка основной конфигурации в 1С"
    if ($Extension) { $title = "Загрузка расширения в 1С: $Extension" }

    $useUpdate = Test-Path -LiteralPath (Join-Path $InputPath "ConfigDumpInfo.xml")
    $attemptedUpdate = $useUpdate
    $done = $false
    $ConnParams = Get-1CConnectionParams -DBType $DBType -BasePath $BasePath
    $loadStart = Get-Date

    while (-not $done) {
        Test-Cancelled
        $short = Enter-ShortDumpPath -TargetPath $InputPath
        $dumpArg = $short.DumpPath
        if ($dumpArg -match '\s') { $dumpArg = "`"$dumpArg`"" }

        $ArgLine = "DESIGNER $ConnParams /N `"$User`" /P `"$Password`" /LoadConfigFromFiles $dumpArg"
        if ($Extension) { $ArgLine += " -Extension `"$Extension`"" }
        if ($useUpdate) { $ArgLine += " -update" }
        $ArgLine += " -Format Hierarchical"

        Write-Log $title
        if ($useUpdate) { Write-Log "Режим загрузки: инкрементальная (-update)" }
        else { Write-Log "Режим загрузки: полная" }
        Set-Status -Text "$title..." -Percent $ProgressFrom

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
            Exit-ShortDumpPath -Info $short
        }

        if (-not $done -and -not $useUpdate -and $attemptedUpdate) {
            $attemptedUpdate = $false
        }
    }

    $loadElapsed = (Get-Date) - $loadStart
    $dbElapsed = $null
    if ($UpdateDB) {
        Test-Cancelled
        $updTitle = "Обновление конфигурации БД"
        if ($Extension) { $updTitle = "Обновление расширения в БД: $Extension" }
        Write-Log $updTitle
        Set-Status -Text "$updTitle..." -Percent ([Math]::Min(99, $ProgressFrom + 8))
        $updArgs = "DESIGNER $ConnParams /N `"$User`" /P `"$Password`" /UpdateDBCfg"
        if ($Dynamic) { $updArgs += " -Dynamic+" }
        else { $updArgs += " -Dynamic-" }
        if ($Extension) { $updArgs += " -Extension `"$Extension`"" }
        $dbStart = Get-Date
        try {
            Invoke-1CDesigner -Platform $Platform -ArgumentString $updArgs | Out-Null
        }
        finally {
            $dbElapsed = (Get-Date) - $dbStart
        }
    }

    Write-Log "Загрузка завершена: $InputPath"
    return [PSCustomObject]@{
        LoadElapsed = $loadElapsed
        DbElapsed   = $dbElapsed
    }
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

    $AllExtensions = Get-RepoExtensionInfos -RepoDir $RepoDir
    if ($AllExtensions.Count -eq 0) {
        Write-Log "В Git нет расширений с Configuration.xml (папка Extensions)"
        return
    }
    Write-Log ("В Git найдено расширений: {0}" -f $AllExtensions.Count)

    $ExtensionsToLoad = New-Object System.Collections.Generic.List[object]
    if ($SelectManually) {
        Set-ProgressCancelEnabled -Enabled $false
        $pickerNames = New-Object System.Collections.Generic.List[string]
        for ($i = 0; $i -lt $AllExtensions.Count; $i++) {
            [void]$pickerNames.Add([string]$AllExtensions[$i].FolderName)
        }
        $selected = @(Show-ExtensionPicker -Extensions $pickerNames.ToArray() -ExcludePrefix $ExcludePrefix `
            -PromptText "Отметьте расширения для загрузки в 1С:" -AcceptText "Загрузить выбранные")
        Set-ProgressCancelEnabled -Enabled $true
        Test-Cancelled
        for ($i = 0; $i -lt $AllExtensions.Count; $i++) {
            $ext = $AllExtensions[$i]
            if ($selected -contains [string]$ext.FolderName) { [void]$ExtensionsToLoad.Add($ext) }
        }
        if ($ExtensionsToLoad.Count -eq 0) {
            Write-Log "Загрузка расширений пропущена пользователем"
            return
        }
    }
    else {
        for ($i = 0; $i -lt $AllExtensions.Count; $i++) {
            $ext = $AllExtensions[$i]
            $extName = [string]$ext.Name
            $extFolder = [string]$ext.FolderName
            if ((Test-NameHasPrefix -Name $extName -Prefix $ExcludePrefix) -or
                (Test-NameHasPrefix -Name $extFolder -Prefix $ExcludePrefix)) {
                continue
            }
            [void]$ExtensionsToLoad.Add($ext)
        }
        if ($ExtensionsToLoad.Count -eq 0) {
            Write-Log "После фильтра по префиксу '$ExcludePrefix' расширений не осталось"
            return
        }
    }

    $Total = $ExtensionsToLoad.Count
    $failed = New-Object System.Collections.Generic.List[string]
    $loadElapsed = [TimeSpan]::Zero
    $dbElapsed = [TimeSpan]::Zero
    $didLoad = $false
    $didDb = $false
    for ($Index = 0; $Index -lt $Total; $Index++) {
        $ext = $ExtensionsToLoad[$Index]
        $extName = [string]$ext.Name
        $extFolder = [string]$ext.FolderName
        $extPath = [string]$ext.Path
        $PercentFrom = 70 + [int]($Index / $Total * 20)
        Write-Log ("Расширение '{0}' (папка '{1}')" -f $extName, $extFolder)
        if (-not (Test-DumpCatalogReady -Path $extPath)) {
            Write-Log "Пропуск расширения '$extName': нет Configuration.xml в $extPath"
            [void]$failed.Add($extName)
            continue
        }
        try {
            $part = Invoke-1CLoad -Platform $Platform -DBType $DBType -BasePath $BasePath `
                -User $User -Password $Password -InputPath $extPath `
                -Extension $extName -UpdateDB $UpdateDB -Dynamic $Dynamic `
                -ProgressFrom $PercentFrom
            $didLoad = $true
            $loadElapsed += $part.LoadElapsed
            if ($null -ne $part.DbElapsed) {
                $didDb = $true
                $dbElapsed += $part.DbElapsed
            }
        }
        catch [System.OperationCanceledException] {
            throw
        }
        catch {
            Write-Log "Ошибка загрузки расширения '$extName': $_" "ERROR"
            [void]$failed.Add($extName)
        }
    }
    if ($failed.Count -gt 0) {
        Write-Log ("Не загружены расширения: " + ($failed -join ", "))
        if ($failed.Count -eq $Total) {
            throw "Не удалось загрузить ни одного расширения"
        }
    }

    if (-not $didLoad) { return $null }
    return [PSCustomObject]@{
        LoadElapsed = $loadElapsed
        DbElapsed   = $(if ($didDb) { $dbElapsed } else { $null })
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

    $script:IndexCommitTiming = $null
    $script:RemotePushTiming = $null

    $runStarted = Get-Date
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
        Initialize-PortableGit -EmbeddedArchive $EmbeddedGit
        Initialize-GitIdentity -GitExe $GitExe -GitHome $GitHome
        Invoke-GitPushOnly -GitExe $GitExe -RepoDir $GitRepo `
            -Branch $GitBranch -GitHome $GitHome -RemoteUrl $GitRepoUrl
        Set-Status -Text "Готово!" -Percent 100
        Write-Log "Операция успешно завершена"
        $doneMessage = "Локальные коммиты отправлены в ветку '$GitBranch' без нового коммита."
        $timingText = Format-TimingSummary -StartedAt $runStarted -EndedAt (Get-Date) -Steps @(
            (New-TimingStep -Name "Выгрузка основной конфигурации"),
            (New-TimingStep -Name "Выгрузка расширений"),
            (New-TimingStep -Name "Добавление изменений в индекс и коммит"),
            (New-TimingStep -Name "Отправка в удалённый репозиторий" -Timing $script:RemotePushTiming)
        )
        Write-TimingSummary -Text $timingText
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
        Initialize-PortableGit -EmbeddedArchive $EmbeddedGit
        Initialize-GitIdentity -GitExe $GitExe -GitHome $GitHome
        Initialize-GitRepository -GitExe $GitExe -RepoDir $GitRepo `
            -RemoteUrl $GitRepoUrl -Branch $GitBranch -GitHome $GitHome `
            -SkipPullIfDirty -ForceCheckout
        Sync-GitWorktreeToOrigin -GitExe $GitExe -RepoDir $GitRepo -Branch $GitBranch
        $fetchTiming = New-OpTiming -StartedAt $gitPrepStart -EndedAt (Get-Date)

        $configTiming = $null
        $extTiming = $null
        $dbElapsed = [TimeSpan]::Zero
        $didDb = $false

        if ($LoadMainConfig) {
            $loaded = Invoke-1CLoad -Platform $PlatformPath -DBType $DBType -BasePath $InfobasePath `
                -User $1CUser -Password $1CPassword -InputPath $ConfigExportPath `
                -UpdateDB $UpdateInfobaseCfg -Dynamic $DynamicUpdateCfg -ProgressFrom 50
            $configTiming = New-OpTiming -Elapsed $loaded.LoadElapsed
            if ($null -ne $loaded.DbElapsed) {
                $didDb = $true
                $dbElapsed += $loaded.DbElapsed
            }
        }

        if ($LoadExtensionsFlag) {
            $loadedExt = Invoke-LoadExtensionsPipeline -Platform $PlatformPath -DBType $DBType `
                -BasePath $InfobasePath -User $1CUser -Password $1CPassword `
                -RepoDir $GitRepo -SelectManually $LoadSelectManually `
                -ExcludePrefix $ExtensionExcludePrefix `
                -UpdateDB $UpdateInfobaseCfg -Dynamic $DynamicUpdateCfg
            if ($loadedExt) {
                $extTiming = New-OpTiming -Elapsed $loadedExt.LoadElapsed
                if ($null -ne $loadedExt.DbElapsed) {
                    $didDb = $true
                    $dbElapsed += $loadedExt.DbElapsed
                }
            }
        }

        $dbTiming = $null
        if ($didDb) { $dbTiming = New-OpTiming -Elapsed $dbElapsed }

        Set-Status -Text "Загрузка в 1С завершена" -Percent 100
        Write-Log "Операция успешно завершена"

        $doneMessage = "Загрузка из Git в базу '$InfobasePath' завершена."
        $timingText = Format-TimingSummary -StartedAt $runStarted -EndedAt (Get-Date) -Steps @(
            (New-TimingStep -Name "Получение файлов из удалённого репозитория" -Timing $fetchTiming),
            (New-TimingStep -Name "Загрузка основной конфигурации в 1С" -Timing $configTiming),
            (New-TimingStep -Name "Загрузка расширений в 1С" -Timing $extTiming),
            (New-TimingStep -Name "Обновление конфигурации БД" -Timing $dbTiming)
        )
        Write-TimingSummary -Text $timingText
        Set-TimingSummaryText -Text ($doneMessage + "`r`n`r`n" + $timingText)
        return
    }

    if ($doGitPrepare) {
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

    $configTiming = $null
    $extTiming = $null

    if ($doMain) {
        $opStart = Get-Date
        Invoke-1CExport -Platform $PlatformPath -DBType $DBType -BasePath $InfobasePath `
            -User $1CUser -Password $1CPassword -OutputPath $ConfigExportPath `
            -DumpMode $DumpMode -ProgressFrom 45 -ProgressTo 65
        $configTiming = New-OpTiming -StartedAt $opStart -EndedAt (Get-Date)
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
    }
    elseif ($Action -eq "all") {
        Write-Log "Выгрузка расширений отключена в настройках"
    }

    $publishResult = $null
    if ($doGitPublish) {
        Test-Cancelled
        $publishResult = Invoke-GitPublish -GitExe $GitExe -RepoDir $GitRepo `
            -Branch $GitBranch -GitHome $GitHome -InfobasePath $InfobasePath `
            -AutoConfirm:$AutoConfirmGitPush
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

    $timingText = Format-TimingSummary -StartedAt $runStarted -EndedAt (Get-Date) -Steps @(
        (New-TimingStep -Name "Выгрузка основной конфигурации" -Timing $configTiming),
        (New-TimingStep -Name "Выгрузка расширений" -Timing $extTiming),
        (New-TimingStep -Name "Добавление изменений в индекс и коммит" -Timing $script:IndexCommitTiming),
        (New-TimingStep -Name "Отправка в удалённый репозиторий" -Timing $script:RemotePushTiming)
    )
    Write-TimingSummary -Text $timingText
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
