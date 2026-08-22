#Requires -Version 5.1

<#
.SYNOPSIS
    Now Video Down - PowerShell WinForms GUI (Pro Designer Edition v2.37)
.NOTES
    Requires:  yt-dlp.exe (+ ffmpeg.exe for merging/thumbnails)
               Place both next to this script.
    Important: Save this script under UTF-8-BOM encoding
    Created by Nikos Georgousis - Updated June 2026
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# -- HIGH-DPI AWARENESS (crisp UI on scaled displays) ----------------------
try {
    Add-Type -Namespace Win32 -Name NativeMethods -MemberDefinition @"
[DllImport("user32.dll")]
public static extern bool SetProcessDPIAware();
"@ -ErrorAction Stop
    [Win32.NativeMethods]::SetProcessDPIAware() | Out-Null
} catch { }

# -- NOTIFICATION SUPPORT TYPES --------------------------------------------
# A borderless form that never steals focus (WS_EX_NOACTIVATE) - used for the
# completion popup, so it never yanks the keyboard away from the user.
$script:hasNoActivate = $false
try {
    Add-Type -TypeDefinition @"
using System;
using System.Windows.Forms;
public class NoActivateForm : System.Windows.Forms.Form {
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams {
        get { CreateParams cp = base.CreateParams; cp.ExStyle |= 0x08000000; return cp; }
    }
}
"@ -ErrorAction Stop
    $script:hasNoActivate = $true
} catch { }
# Taskbar flash (FLASHW_ALL | FLASHW_TIMERNOFG) without stealing focus.
try {
    Add-Type -Namespace Win32 -Name Flash -MemberDefinition @"
[DllImport("user32.dll")]
public static extern bool FlashWindowEx(ref FLASHWINFO pwfi);
public struct FLASHWINFO { public uint cbSize; public IntPtr hwnd; public uint dwFlags; public uint uCount; public uint dwTimeout; }
"@ -ErrorAction Stop
} catch { }
# Dark/light title bar via DWM (Win10 1809+ attribute 19, Win11 attribute 20).
try {
    Add-Type -Namespace Win32 -Name Dwm -MemberDefinition @"
[DllImport("dwmapi.dll")]
public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);
"@ -ErrorAction Stop
} catch { }

# -- PATHS & PORTABILITY ---------------------------------------------------
$ScriptDir      = Split-Path -Parent $MyInvocation.MyCommand.Definition
$DownloadFolder = Join-Path $ScriptDir "Downloads"
function Get-ActiveList {
    foreach ($l in @("list.txt", "list1.txt", "list2.txt", "list3.txt")) {
        $path = Join-Path $ScriptDir $l
        if (Test-Path $path) { return $path }
    }
    return $null
}

$SettingsFile   = Join-Path $ScriptDir "settings.json"
$OldSettingsFile = Join-Path $env:APPDATA "VideoDownloader\settings.json"

# first run = no settings here AND no legacy settings to migrate
$script:isFirstRun = -not ((Test-Path $SettingsFile) -or (Test-Path $OldSettingsFile))

if (-not (Test-Path $SettingsFile) -and (Test-Path $OldSettingsFile)) {
    try { Copy-Item -Path $OldSettingsFile -Destination $SettingsFile -Force | Out-Null } catch {}
}
if (-not (Test-Path $DownloadFolder)) { New-Item -ItemType Directory $DownloadFolder -Force | Out-Null }

# -- SINGLE INSTANCE GUARD ---------------------------------------------------
# Two instances fight over settings.json and both try to own a tray icon.
$script:isFirstInstance = $false
$script:appMutex = New-Object System.Threading.Mutex($true, "NowVideoDown-SingleInstance", [ref]$script:isFirstInstance)
if (-not $script:isFirstInstance -and $env:NVD_SELFTEST -ne "1") {
    [System.Windows.Forms.MessageBox]::Show(
        "Now Video Down is already running.`n`nIf you minimized it to the tray, look for its icon next to the clock - or inside the hidden icons area (the ^ arrow) - and double-click it to restore the window.",
        "Now Video Down - Already Running",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    exit
}

# -- FATAL ERROR SAFETY NET -------------------------------------------------
# The launchers hide the console, so an unhandled error would be invisible.
# Log it to error.log next to the script and show a message box before exiting.
trap {
    $errRec = $_
    try { $errRec | Out-File (Join-Path $ScriptDir "error.log") -Encoding UTF8 -Force } catch { }
    try {
        [System.Windows.Forms.MessageBox]::Show(
            "Now Video Down hit an unexpected error:`n$($errRec.Exception.Message)`n(Line $($errRec.InvocationInfo.ScriptLineNumber))`n`nDetails saved to error.log next to the script.",
            "Now Video Down - Fatal Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    } catch { }
    break
}

# -- SETTINGS & PROFILES ENGINE --------------------------------------------
function New-ProfileObj($name) {
    return [PSCustomObject]@{
        Name=$name; Description=""; Format="mp4"; Quality="Best"; AudioOnly=$false
        AudioFormat="mp3"; AudioQuality="Best"; Subs=$false; SubLang="en"; Thumb=$false; Playlist=$false; PlaylistRange=""
        Verbose=$true; Folder=$DownloadFolder; Subfolder=""; AskDestination=$false
        FilenameTemplate=""; RateLimit=""; CookiesFile=""
        Created=(Get-Date -Format "yyyy-MM-dd"); LastUsed=$null
    }
}
function Normalize-Profile($p) {
    if ($null -eq $p) { return $null }
    $d = New-ProfileObj "x"
    foreach ($prop in @($d.PSObject.Properties.Name)) {
        if ($null -eq $p.PSObject.Properties[$prop]) {
            Add-Member -InputObject $p -NotePropertyName $prop -NotePropertyValue $d.$prop -Force
        } elseif ($null -eq $p.$prop -and $prop -ne "LastUsed") {
            $p.$prop = $d.$prop
        }
    }
    # v2.27 -> v2.28: audio formats live in their own AudioFormat field now
    if ($p.Format -in @('mp3','m4a','opus','flac','wav')) {
        if ($p.AudioOnly -and $p.AudioFormat -eq 'mp3') { $p.AudioFormat = $p.Format }
        $p.Format = 'mp4'
    }
    if ([string]::IsNullOrWhiteSpace($p.Name)) { $p.Name = "Profile " + (Get-Random -Maximum 9999) }
    return $p
}
function Load-Settings {
    $defProfiles = @(
        (New-ProfileObj "Default Video"),
        (New-ProfileObj "Audio Only")
    )
    $defProfiles[1].Format = "mp3"; $defProfiles[1].AudioOnly = $true
    $defConfig = [PSCustomObject]@{ X=$null; Y=$null; WinW=900; WinH=915; Theme="Deep Space Tech"; ActiveProfile="Default Video"; DefaultProfile="Default Video"; RecentFolders=@(); Trash=@(); TrayMinimize=$true; AlwaysTray=$false; NotifyStyle=2; ClipboardWatch=$true; Profiles=$defProfiles }

    if (Test-Path $SettingsFile) {
        try {
            $json = Get-Content $SettingsFile -Raw | ConvertFrom-Json
            if ($null -eq $json.Profiles) {
                # legacy v1 layout (single Format/Quality/AudioOnly)
                $legacy = New-ProfileObj "Default Video"
                $legacy.Format    = if ($null -ne $json.Format)    { $json.Format }    else { "mp4" }
                $legacy.Quality   = if ($null -ne $json.Quality)   { $json.Quality }   else { "Best" }
                $legacy.AudioOnly = if ($null -ne $json.AudioOnly) { $json.AudioOnly } else { $false }
                $legacy2 = New-ProfileObj "Audio Only"; $legacy2.Format = "mp3"; $legacy2.AudioOnly = $true
                $defConfig.Profiles = @($legacy, $legacy2)
                $defConfig.X = $json.X; $defConfig.Y = $json.Y
                return $defConfig
            }
            $profiles = @($json.Profiles | ForEach-Object { Normalize-Profile $_ })
            if ($profiles.Count -eq 0) { $profiles = $defConfig.Profiles }
            $defConfig.Profiles = $profiles
            if ($null -ne $json.X)              { $defConfig.X = $json.X }
            if ($null -ne $json.Y)              { $defConfig.Y = $json.Y }
            if ($null -ne $json.WinW)           { $defConfig.WinW = [int]$json.WinW }
            if ($null -ne $json.WinH)           { $defConfig.WinH = [int]$json.WinH }
            if ($null -ne $json.Theme)          { $defConfig.Theme = $json.Theme }
            if ($null -ne $json.ActiveProfile)  { $defConfig.ActiveProfile = $json.ActiveProfile }
            if ($null -ne $json.DefaultProfile) { $defConfig.DefaultProfile = $json.DefaultProfile }
            if ($null -ne $json.RecentFolders)  { $defConfig.RecentFolders = @($json.RecentFolders) }
            if ($null -ne $json.Trash)          { $defConfig.Trash = @($json.Trash) }
            if ($null -ne $json.TrayMinimize)   { $defConfig.TrayMinimize = [bool]$json.TrayMinimize }
            if ($null -ne $json.AlwaysTray)     { $defConfig.AlwaysTray = [bool]$json.AlwaysTray }
            if ($null -ne $json.NotifyStyle)    { $defConfig.NotifyStyle = [int]$json.NotifyStyle }
            if ($null -ne $json.ClipboardWatch) { $defConfig.ClipboardWatch = [bool]$json.ClipboardWatch }
            return $defConfig
        } catch { }
    }
    return $defConfig
}
function Save-Settings($frm, $cfgObj) {
    $bounds = if ($frm.WindowState -eq [System.Windows.Forms.FormWindowState]::Normal) { $frm.Bounds } else { $frm.RestoreBounds }
    $cfgObj.X = $bounds.X; $cfgObj.Y = $bounds.Y
    $cfgObj.WinW = $frm.ClientSize.Width; $cfgObj.WinH = $frm.ClientSize.Height
    try { $cfgObj | ConvertTo-Json -Depth 4 | Set-Content $SettingsFile -Encoding UTF8 -Force } catch { }
}
$cfg = Load-Settings

# -- DEPENDENCY DETECTION --------------------------------------------------
function Find-Tool($name) {
    $loc = Join-Path $ScriptDir $name
    if (Test-Path $loc) { return $loc }
    $cmd = Get-Command ($name -replace '\.exe$','') -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

$script:ytdlp  = Find-Tool "yt-dlp.exe"
$script:ffmpeg = Find-Tool "ffmpeg.exe"

$script:cancelRequested = $false; $script:activeJob = $null; $script:activeTimer = $null; $script:delayTimer = $null
$script:onDoneCallback = $null; $script:batchLinks = @(); $script:batchTotal = 0; $script:batchDone = 0; $script:batchOk = 0; $script:batchFail = 0
$script:lastDownloadedFile = $null; $script:isUpdatingUI = $false
$script:jobExitCode = $null
$script:runFolderOverride = $null; $script:isDirty = $false; $script:pasteDlTimer = $null
$script:inTray = $false; $script:tray = $null; $script:notifPopup = $null; $script:notifPopTimer = $null; $script:aboutForm = $null; $script:managerForm = $null
$script:clipLast = ""; $script:clipUrl = $null; $script:clipTimer = $null
$script:updateJob = $null; $script:updTimer = $null; $script:ytdlpOutdated = $false; $script:ytdlpLocal = "?"
# persistent session log (log.txt next to the script, capped + rotated)
$script:logFile = Join-Path $ScriptDir "log.txt"
$script:logSize = 0; $script:logMaxSize = 512 * 1024
if (Test-Path $script:logFile) { try { $script:logSize = (Get-Item $script:logFile).Length } catch { } }
# PIDs of yt-dlp/ffmpeg already running BEFORE our first download, so that
# Cancel/Close only kills processes we spawned - never a user's own yt-dlp
# running outside the app.
$script:knownPIDs = @(Get-Process -Name 'yt-dlp','ffmpeg' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)

# -- TYPOGRAPHY ------------------------------------------------------------
$fTitle  = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
$fSub    = New-Object System.Drawing.Font("Segoe UI",  8, [System.Drawing.FontStyle]::Regular)
$fNormal = New-Object System.Drawing.Font("Segoe UI",  9, [System.Drawing.FontStyle]::Regular)
$fBold   = New-Object System.Drawing.Font("Segoe UI",  9, [System.Drawing.FontStyle]::Bold)
$fMono   = New-Object System.Drawing.Font("Consolas",  9, [System.Drawing.FontStyle]::Regular)

# -- THEME ENGINE ----------------------------------------------------------
function HexToCol($hex) { return [System.Drawing.ColorTranslator]::FromHtml($hex) }

function Get-ThemePalette($themeName) {
    $cSuccess = HexToCol "#10B981"; $cDanger  = HexToCol "#EF4444"; $cWarn    = HexToCol "#F59E0B"
    switch ($themeName) {
        "Cyberpunk Neon"   { return @{ Bg=HexToCol "#001011"; Panel=HexToCol "#0A1C1D"; Entry=HexToCol "#122425"; Accent=HexToCol "#6ccff6"; Text=HexToCol "#fffffc"; Sub=HexToCol "#757780"; BtnGray=HexToCol "#2E3A3B"; Success=HexToCol "#98ce00"; Danger=$cDanger; Warn=$cWarn; IsDark=$true } }
        "Amethyst Dream"   { return @{ Bg=HexToCol "#f2fcf9"; Panel=HexToCol "#d5fff3"; Entry=HexToCol "#ffffff"; Accent=HexToCol "#820b8a"; Text=HexToCol "#50203c"; Sub=HexToCol "#8e7692"; BtnGray=HexToCol "#c7ede4"; Success=$cSuccess; Danger=$cDanger; Warn=$cWarn; IsDark=$false } }
        "Warm Minimalist"  { return @{ Bg=HexToCol "#f4f3ee"; Panel=HexToCol "#ffffff"; Entry=HexToCol "#fcfcfb"; Accent=HexToCol "#c88673"; Text=HexToCol "#36302c"; Sub=HexToCol "#726963"; BtnGray=HexToCol "#d6d2cb"; Success=$cSuccess; Danger=$cDanger; Warn=$cWarn; IsDark=$false } }
        "Deep Space Tech"  { return @{ Bg=HexToCol "#0b132b"; Panel=HexToCol "#182440"; Entry=HexToCol "#11182B"; Accent=HexToCol "#5bc0be"; Text=HexToCol "#ffffff"; Sub=HexToCol "#9fb1cc"; BtnGray=HexToCol "#3a506b"; Success=$cSuccess; Danger=$cDanger; Warn=$cWarn; IsDark=$true } }
        "Arctic Breeze"    { return @{ Bg=HexToCol "#e0ebeb"; Panel=HexToCol "#ffffff"; Entry=HexToCol "#f0f5f5"; Accent=HexToCol "#007ea7"; Text=HexToCol "#003249"; Sub=HexToCol "#3b7285"; BtnGray=HexToCol "#a6d9dc"; Success=$cSuccess; Danger=$cDanger; Warn=$cWarn; IsDark=$false } }
        "Slate Harbor"     { return @{ Bg=HexToCol "#475b5a"; Panel=HexToCol "#3A4B4A"; Entry=HexToCol "#2E3D3C"; Accent=HexToCol "#52d1dc"; Text=HexToCol "#ffffff"; Sub=HexToCol "#bbbbbf"; BtnGray=HexToCol "#8d8e8e"; Success=$cSuccess; Danger=$cDanger; Warn=$cWarn; IsDark=$true } }
        "Forest Canopy"    { return @{ Bg=HexToCol "#fefee3"; Panel=HexToCol "#ffffff"; Entry=HexToCol "#f5f5dc"; Accent=HexToCol "#2c6e49"; Text=HexToCol "#223322"; Sub=HexToCol "#4c956c"; BtnGray=HexToCol "#d68c45"; Success=$cSuccess; Danger=$cDanger; Warn=$cWarn; IsDark=$false } }
        "Velvet Corporate" { return @{ Bg=HexToCol "#f5f4f4"; Panel=HexToCol "#dad9cf"; Entry=HexToCol "#ffffff"; Accent=HexToCol "#61252c"; Text=HexToCol "#15120e"; Sub=HexToCol "#8a8075"; BtnGray=HexToCol "#bdb0a0"; Success=$cSuccess; Danger=$cDanger; Warn=$cWarn; IsDark=$false } }
        "Midnight Ocean"   { return @{ Bg=HexToCol "#1b3b6f"; Panel=HexToCol "#21295c"; Entry=HexToCol "#0f173b"; Accent=HexToCol "#9eb3c2"; Text=HexToCol "#ffffff"; Sub=HexToCol "#7790a8"; BtnGray=HexToCol "#065a82"; Success=$cSuccess; Danger=$cDanger; Warn=$cWarn; IsDark=$true } }
        "Retro Arcade"     { return @{ Bg=HexToCol "#3a3335"; Panel=HexToCol "#2B2527"; Entry=HexToCol "#1E1A1B"; Accent=HexToCol "#f0544f"; Text=HexToCol "#fdf0d5"; Sub=HexToCol "#c6d8d3"; BtnGray=HexToCol "#d81e5b"; Success=$cSuccess; Danger=$cDanger; Warn=$cWarn; IsDark=$true } }
        Default { return Get-ThemePalette "Deep Space Tech" }
    }
}

# -- FORM SETUP ------------------------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text            = "Now Video Down - Pro Edition v2.37"
$winW = if ($cfg.WinW -and $cfg.WinW -gt 500) { [int]$cfg.WinW } else { 900 }
$winH = if ($cfg.WinH -and $cfg.WinH -gt 500) { [int]$cfg.WinH } else { 915 }
$form.ClientSize      = [System.Drawing.Size]::new($winW, $winH)
$form.Font            = $fNormal
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::Sizable
$form.MaximizeBox     = $true
$form.MinimumSize     = [System.Drawing.Size]::new(760, 700)

$IconPath = Join-Path $ScriptDir "app.ico"
if (Test-Path $IconPath) { try { $form.Icon = New-Object System.Drawing.Icon($IconPath) } catch { } }

$onScreen = $false
if ($null -ne $cfg.X -and $null -ne $cfg.Y) {
    $savedPoint = [System.Drawing.Point]::new([int]$cfg.X, [int]$cfg.Y)
    foreach ($scr in [System.Windows.Forms.Screen]::AllScreens) {
        if ($scr.WorkingArea.Contains($savedPoint)) { $onScreen = $true; break }
    }
}
if ($onScreen) { $form.StartPosition = 'Manual'; $form.Location = $savedPoint } 
else { $form.StartPosition = 'CenterScreen' }

# -- NEW TOP MENU STANDARDIZATION ------------------------------------------
$menu = New-Object System.Windows.Forms.MenuStrip

# 1. File Menu
$menuFile = New-Object System.Windows.Forms.ToolStripMenuItem("File")
$miExit = New-Object System.Windows.Forms.ToolStripMenuItem("Exit")
$miExit.Add_Click({ $form.Close() })
[void]$menuFile.DropDownItems.Add($miExit)

# 2. Tools Menu
$menuTools = New-Object System.Windows.Forms.ToolStripMenuItem("Tools")
$miOpenDir = New-Object System.Windows.Forms.ToolStripMenuItem("Open script folder")
$miOpenDir.Add_Click({ Start-Process $ScriptDir })
$miSep = New-Object System.Windows.Forms.ToolStripSeparator
$menuUpdateYt = New-Object System.Windows.Forms.ToolStripMenuItem("Download / Update yt-dlp")
$menuUpdateFfmpeg = New-Object System.Windows.Forms.ToolStripMenuItem("Download / Update ffmpeg (Auto)")
$menuGetFfmpeg = New-Object System.Windows.Forms.ToolStripMenuItem("Get ffmpeg manually (Opens Browser)")
$menuNotify = New-Object System.Windows.Forms.ToolStripMenuItem("Completion notification")
$miNotifyOff = New-Object System.Windows.Forms.ToolStripMenuItem("Off")
$miNotifyFlash = New-Object System.Windows.Forms.ToolStripMenuItem("In-app flash only")
$miNotifyPopup = New-Object System.Windows.Forms.ToolStripMenuItem("Popup (no sound)")
$miNotifyPopSound = New-Object System.Windows.Forms.ToolStripMenuItem("Popup + sound")
foreach ($pair in @(@($miNotifyOff, 0), @($miNotifyFlash, 1), @($miNotifyPopup, 2), @($miNotifyPopSound, 3))) {
    $pair[0].CheckOnClick = $true
    if ($cfg.NotifyStyle -eq $pair[1]) { $pair[0].Checked = $true }
    # NOTE: never capture loop variables in handlers - use Tag (PowerShell
    # scriptblocks capture the variable binding, not its value)
    $pair[0].Tag = $pair[1]
    $pair[0].Add_Click({
        foreach ($it in $menuNotify.DropDownItems) { $it.Checked = $false }
        $this.Checked = $true
        $cfg.NotifyStyle = [int]$this.Tag
    })
    [void]$menuNotify.DropDownItems.Add($pair[0])
}
$menuClip = New-Object System.Windows.Forms.ToolStripMenuItem("Watch clipboard for URLs")
$menuClip.CheckOnClick = $true; $menuClip.Checked = $cfg.ClipboardWatch
$menuClip.Add_Click({ $cfg.ClipboardWatch = $menuClip.Checked; Sync-ClipboardWatchUI })
$menuTools.DropDownItems.AddRange(@($miOpenDir, $miSep, $menuUpdateYt, $menuUpdateFfmpeg, $menuGetFfmpeg, $menuNotify, $menuClip))

# 3. Themes Menu
$menuThemes = New-Object System.Windows.Forms.ToolStripMenuItem("Themes")
$ThemesList = @("Cyberpunk Neon", "Amethyst Dream", "Slate Harbor", "Forest Canopy", "Velvet Corporate", "Midnight Ocean", "Retro Arcade", "Warm Minimalist", "Deep Space Tech", "Arctic Breeze")
foreach ($t in $ThemesList) {
    $mi = New-Object System.Windows.Forms.ToolStripMenuItem($t)
    if ($t -eq $cfg.Theme) { $mi.Checked = $true }
    $mi.Add_Click({ 
        foreach ($item in $menuThemes.DropDownItems) { $item.Checked = $false }
        $this.Checked = $true
        $cfg.Theme = $this.Text
        Apply-Theme $cfg.Theme 
    })
    [void]$menuThemes.DropDownItems.Add($mi)
}

# 4. About Menu
$menuAbout = New-Object System.Windows.Forms.ToolStripMenuItem("About...")

$menu.Items.Add($menuFile) | Out-Null
$menu.Items.Add($menuTools) | Out-Null
$menu.Items.Add($menuThemes) | Out-Null
$menu.Items.Add($menuAbout) | Out-Null
$form.Controls.Add($menu)
$form.MainMenuStrip = $menu

function New-ProButton($text,$x,$y,$w,$h) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text; $b.Location = [System.Drawing.Point]::new($x,$y); $b.Size = [System.Drawing.Size]::new($w,$h)
    $b.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat; $b.Font = $fBold
    $b.FlatAppearance.BorderSize = 0; $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    return $b
}

# -- UI CONTROLS DEFINITION (GROUPBOX LAYOUT) ------------------------------

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = "Now Video Down"; $lblTitle.Font = $fTitle; $lblTitle.Location = [System.Drawing.Point]::new(20,35); $lblTitle.AutoSize = $true

$lblSub = New-Object System.Windows.Forms.Label
$lblSub.Text = "YouTube | Facebook | Twitter/X | Instagram | TikTok | 1000+ sites"
$lblSub.Font = $fSub; $lblSub.Location = [System.Drawing.Point]::new(20,65); $lblSub.AutoSize = $true

$lblCredits = New-Object System.Windows.Forms.Label
$lblCredits.Text = "v 2.37 Pro Edition - Nikos Georgousis"
$lblCredits.Font = $fSub; $lblCredits.Location = [System.Drawing.Point]::new(620,40); $lblCredits.AutoSize = $true

# Group 1: Source (GroupBox) - URL/batch row + clipboard detection row
$gbUrl = New-Object System.Windows.Forms.GroupBox
$gbUrl.Text = "1. SOURCE URL OR BATCH LIST"; $gbUrl.Font = $fBold
$gbUrl.Location = [System.Drawing.Point]::new(20,95); $gbUrl.Size = [System.Drawing.Size]::new(860,100)
$txtUrl = New-Object System.Windows.Forms.TextBox; $txtUrl.Location = [System.Drawing.Point]::new(15,30); $txtUrl.Size = [System.Drawing.Size]::new(470,30); $txtUrl.BorderStyle = 'FixedSingle'; $txtUrl.Font = $fNormal
$btnClear    = New-ProButton "X"            495 29  30 30
$btnDownload = New-ProButton "Download URL" 535 29 120 30
$btnOpenList = New-ProButton "Open list"    665 29  75 30
$btnList     = New-ProButton "Run list.txt" 750 29  80 30
$btnList.Enabled = ($null -ne (Get-ActiveList))
$lblClipHint = New-Object System.Windows.Forms.Label; $lblClipHint.Text = "Clipboard watch: ON - copy a video URL anywhere and it appears here"; $lblClipHint.Location = [System.Drawing.Point]::new(15,68); $lblClipHint.Size = [System.Drawing.Size]::new(460,16); $lblClipHint.Font = $fSub; $lblClipHint.AutoEllipsis = $true; $lblClipHint.Visible = $false
$lblClipUrl = New-Object System.Windows.Forms.Label; $lblClipUrl.Text = ""; $lblClipUrl.Location = [System.Drawing.Point]::new(15,66); $lblClipUrl.Size = [System.Drawing.Size]::new(455,22); $lblClipUrl.Font = $fNormal; $lblClipUrl.AutoEllipsis = $true; $lblClipUrl.Visible = $false; $lblClipUrl.Cursor = [System.Windows.Forms.Cursors]::Hand
$btnClipDl = New-ProButton "Download" 480 63 80 26; $btnClipDl.Visible = $false
$btnClipIgnore = New-ProButton "Ignore" 566 63 60 26; $btnClipIgnore.Visible = $false
$gbUrl.Controls.AddRange(@($txtUrl, $btnClear, $btnDownload, $btnOpenList, $btnList, $lblClipHint, $lblClipUrl, $btnClipDl, $btnClipIgnore))

# Group 2: Profile & Destination (GroupBox)
$gbProf = New-Object System.Windows.Forms.GroupBox
$gbProf.Text = "2. PROFILE AND DESTINATION"; $gbProf.Font = $fBold
$gbProf.Location = [System.Drawing.Point]::new(20,205); $gbProf.Size = [System.Drawing.Size]::new(860,135)
$cmbProfile = New-Object System.Windows.Forms.ComboBox; $cmbProfile.Location = [System.Drawing.Point]::new(15,30); $cmbProfile.Size = [System.Drawing.Size]::new(280,28); $cmbProfile.DropDownStyle = 'DropDownList'; $cmbProfile.FlatStyle = 'Flat'; $cmbProfile.Font = $fNormal
$lblDirty = New-Object System.Windows.Forms.Label; $lblDirty.Text = "•"; $lblDirty.Location = [System.Drawing.Point]::new(300,32); $lblDirty.Size = [System.Drawing.Size]::new(16,16); $lblDirty.Font = $fBold; $lblDirty.Visible = $false
$btnNewProf    = New-ProButton "＋ New Profile…" 330 27 130 30
$btnEditProf   = New-ProButton "✎ Edit"          470 27 70 30
$btnManageProf = New-ProButton "⚙ Manage…"       550 27 110 30
$cmbFolder = New-Object System.Windows.Forms.ComboBox; $cmbFolder.Location = [System.Drawing.Point]::new(15,66); $cmbFolder.Size = [System.Drawing.Size]::new(560,28); $cmbFolder.DropDownStyle = 'DropDown'; $cmbFolder.FlatStyle = 'Flat'; $cmbFolder.Font = $fNormal
$lblFolderState = New-Object System.Windows.Forms.Label; $lblFolderState.Text = "•"; $lblFolderState.Location = [System.Drawing.Point]::new(582,70); $lblFolderState.Size = [System.Drawing.Size]::new(20,16); $lblFolderState.Font = $fBold
$btnBrowse   = New-ProButton "Browse…"  610 63 90 30
$btnOpenDest = New-ProButton "Open"     710 63 70 30
$chkQuick    = New-Object System.Windows.Forms.CheckBox; $chkQuick.Text = "⚡ Quick"; $chkQuick.Location = [System.Drawing.Point]::new(790,68); $chkQuick.AutoSize = $true; $chkQuick.Font = $fNormal
$lblProfileSummary = New-Object System.Windows.Forms.Label; $lblProfileSummary.Text = ""; $lblProfileSummary.Location = [System.Drawing.Point]::new(15,104); $lblProfileSummary.Size = [System.Drawing.Size]::new(760,16); $lblProfileSummary.Font = $fSub; $lblProfileSummary.AutoEllipsis = $true
$gbProf.Controls.AddRange(@($cmbProfile, $lblDirty, $btnNewProf, $btnEditProf, $btnManageProf, $cmbFolder, $lblFolderState, $btnBrowse, $btnOpenDest, $chkQuick, $lblProfileSummary))

# Group 3: Configuration (GroupBox) - VIDEO | AUDIO columns
$gbOpts = New-Object System.Windows.Forms.GroupBox
$gbOpts.Text = "3. SETTINGS AND QUALITY"; $gbOpts.Font = $fBold
$gbOpts.Location = [System.Drawing.Point]::new(20,350); $gbOpts.Size = [System.Drawing.Size]::new(860,110)
$lblVideoHdr = New-Object System.Windows.Forms.Label; $lblVideoHdr.Text = "VIDEO OUTPUT"; $lblVideoHdr.Location = [System.Drawing.Point]::new(15,20); $lblVideoHdr.AutoSize = $true; $lblVideoHdr.Font = $fSub
$lblAudioHdr = New-Object System.Windows.Forms.Label; $lblAudioHdr.Text = "AUDIO"; $lblAudioHdr.Location = [System.Drawing.Point]::new(392,20); $lblAudioHdr.AutoSize = $true; $lblAudioHdr.Font = $fSub
$sepCol = New-Object System.Windows.Forms.Panel; $sepCol.Location = [System.Drawing.Point]::new(378,18); $sepCol.Size = [System.Drawing.Size]::new(1,76)
$cmbFormat = New-Object System.Windows.Forms.ComboBox; $cmbFormat.Location = [System.Drawing.Point]::new(15,40); $cmbFormat.Size = [System.Drawing.Size]::new(90,28); $cmbFormat.DropDownStyle = 'DropDownList'; $cmbFormat.FlatStyle = 'Flat'; $cmbFormat.Font = $fNormal
@("mp4","mkv","webm") | ForEach-Object { [void]$cmbFormat.Items.Add($_) }
$cmbQuality = New-Object System.Windows.Forms.ComboBox; $cmbQuality.Location = [System.Drawing.Point]::new(115,40); $cmbQuality.Size = [System.Drawing.Size]::new(120,28); $cmbQuality.DropDownStyle = 'DropDownList'; $cmbQuality.FlatStyle = 'Flat'; $cmbQuality.Font = $fNormal
@("Best","1080p","720p","480p") | ForEach-Object { [void]$cmbQuality.Items.Add($_) }
$chkSubs = New-Object System.Windows.Forms.CheckBox; $chkSubs.Text = "Embed Subs"; $chkSubs.Location = [System.Drawing.Point]::new(15,72); $chkSubs.AutoSize = $true; $chkSubs.Font = $fNormal
$chkThumb = New-Object System.Windows.Forms.CheckBox; $chkThumb.Text = "Embed Thumb"; $chkThumb.Location = [System.Drawing.Point]::new(125,72); $chkThumb.AutoSize = $true; $chkThumb.Font = $fNormal
$chkPlaylist = New-Object System.Windows.Forms.CheckBox; $chkPlaylist.Text = "Playlist/Channel"; $chkPlaylist.Location = [System.Drawing.Point]::new(240,72); $chkPlaylist.AutoSize = $true; $chkPlaylist.Font = $fNormal

$chkAudio = New-Object System.Windows.Forms.CheckBox; $chkAudio.Text = "Audio Only"; $chkAudio.Location = [System.Drawing.Point]::new(392,44); $chkAudio.AutoSize = $true; $chkAudio.Font = $fNormal
$cmbAudioFmt = New-Object System.Windows.Forms.ComboBox; $cmbAudioFmt.Location = [System.Drawing.Point]::new(480,40); $cmbAudioFmt.Size = [System.Drawing.Size]::new(90,28); $cmbAudioFmt.DropDownStyle = 'DropDownList'; $cmbAudioFmt.FlatStyle = 'Flat'; $cmbAudioFmt.Font = $fNormal
@("mp3","m4a","opus","flac","wav") | ForEach-Object { [void]$cmbAudioFmt.Items.Add($_) }
$cmbAudioQuality = New-Object System.Windows.Forms.ComboBox; $cmbAudioQuality.Location = [System.Drawing.Point]::new(580,40); $cmbAudioQuality.Size = [System.Drawing.Size]::new(70,28); $cmbAudioQuality.DropDownStyle = 'DropDownList'; $cmbAudioQuality.FlatStyle = 'Flat'; $cmbAudioQuality.Font = $fNormal
@("Best","128","192","320") | ForEach-Object { [void]$cmbAudioQuality.Items.Add($_) }
$gbOpts.Controls.AddRange(@($lblVideoHdr, $lblAudioHdr, $sepCol, $cmbFormat, $cmbQuality, $chkSubs, $chkThumb, $chkPlaylist, $chkAudio, $cmbAudioFmt, $cmbAudioQuality))

# Group 4: DOWNLOAD AND STATUS (GroupBox) - contains all remaining controls
$gbStatus = New-Object System.Windows.Forms.GroupBox
$gbStatus.Text = "4. DOWNLOAD AND STATUS"; $gbStatus.Font = $fBold
$gbStatus.Location = [System.Drawing.Point]::new(20,475); $gbStatus.Size = [System.Drawing.Size]::new(860, 420)

# Warning Label
$lblWarn = New-Object System.Windows.Forms.Label
$lblWarn.Font = $fBold; $lblWarn.Location = [System.Drawing.Point]::new(15,22); $lblWarn.Size = [System.Drawing.Size]::new(600,18)

# Update-available link (shown when a newer yt-dlp exists)
$lnkUpdateYt = New-Object System.Windows.Forms.LinkLabel
$lnkUpdateYt.Text = ""; $lnkUpdateYt.Location = [System.Drawing.Point]::new(620,22); $lnkUpdateYt.AutoSize = $true
$lnkUpdateYt.Visible = $false; $lnkUpdateYt.LinkArea = New-Object System.Windows.Forms.LinkArea(0, 1000)
$lnkUpdateYt.Add_LinkClicked({ $lnkUpdateYt.Visible = $false; try { $menuUpdateYt.PerformClick() } catch { } })

# Progress Bar
$progress = New-Object System.Windows.Forms.ProgressBar; $progress.Location = [System.Drawing.Point]::new(15,48); $progress.Size = [System.Drawing.Size]::new(700,15)

# Status Label
$lblStatus = New-Object System.Windows.Forms.Label; $lblStatus.Text = ""; $lblStatus.Location = [System.Drawing.Point]::new(15,70); $lblStatus.Size = [System.Drawing.Size]::new(600,20)

# Live Speed / ETA Labels
$lblSpeed = New-Object System.Windows.Forms.Label; $lblSpeed.Text = "-"; $lblSpeed.Location = [System.Drawing.Point]::new(625,72); $lblSpeed.Size = [System.Drawing.Size]::new(95,16); $lblSpeed.Font = $fSub
$lblEta   = New-Object System.Windows.Forms.Label; $lblEta.Text = "-";   $lblEta.Location = [System.Drawing.Point]::new(730,72); $lblEta.Size = [System.Drawing.Size]::new(115,16); $lblEta.Font = $fSub

# Cancel Button
$btnCancel   = New-ProButton "Cancel Task"   740 45 100 35; $btnCancel.Enabled = $false

# Utility Buttons
$btnFolder   = New-ProButton "Open Folder"   15 120 110 30
$btnPlayLast = New-ProButton "Play Latest"   135 120 110 30; $btnPlayLast.Visible = $false

# Log Header
$lblLogHdr = New-Object System.Windows.Forms.Label; $lblLogHdr.Text = "DOWNLOAD LOG"; $lblLogHdr.Font = $fBold; $lblLogHdr.Location = [System.Drawing.Point]::new(15, 165); $lblLogHdr.AutoSize = $true

# Verbose Checkbox
$chkVerbose = New-Object System.Windows.Forms.CheckBox; $chkVerbose.Text = "Verbose Log"; $chkVerbose.Location = [System.Drawing.Point]::new(750, 165); $chkVerbose.AutoSize = $true

# Log TextBox
$txtLog = New-Object System.Windows.Forms.RichTextBox; $txtLog.Location = [System.Drawing.Point]::new(15, 190); $txtLog.Size = [System.Drawing.Size]::new(830, 180); $txtLog.Font = $fMono; $txtLog.ReadOnly = $true; $txtLog.BorderStyle = 'None'; $txtLog.ScrollBars = 'Vertical'

# Footer Label
$lblFooter = New-Object System.Windows.Forms.Label; $lblFooter.Text = "Batch files supported: list.txt, list1.txt, list2.txt, list3.txt"; $lblFooter.Location = [System.Drawing.Point]::new(15, 380); $lblFooter.Size = [System.Drawing.Size]::new(830, 18); $lblFooter.Font = $fSub

# Add all controls to the groupbox
$gbStatus.Controls.AddRange(@(
    $lblWarn, $lnkUpdateYt, $progress, $lblStatus, $lblSpeed, $lblEta, $btnCancel,
    $btnFolder, $btnPlayLast,
    $lblLogHdr, $chkVerbose, $txtLog, $lblFooter
))

function SetStatus($msg) { $lblStatus.Text = $msg }

function Update-UIState {
    param([switch]$ResetStatus)
    $script:ytdlp  = Find-Tool "yt-dlp.exe"
    $script:ffmpeg = Find-Tool "ffmpeg.exe"
    
    if (-not $script:ytdlp) {
        $lblWarn.Text = "WARNING: yt-dlp.exe not found! Core downloads disabled."
        $lblWarn.Visible = $true
        $btnDownload.Enabled = $false
        $btnList.Enabled = $false
        if ($ResetStatus) { SetStatus "Action Required: Use the Tools menu to Download yt-dlp" }
    } else {
        $btnDownload.Enabled = $true
        $btnList.Enabled = ($null -ne (Get-ActiveList))
        if (-not $script:ffmpeg) {
            $lblWarn.Text = "Notice: ffmpeg.exe not found. Subtitles/Thumbs disabled."
            $lblWarn.Visible = $true
            if ($ResetStatus) { SetStatus "Ready (Limited) - right-click URL box to Paste and Download" }
        } else {
            $lblWarn.Visible = $false
            if ($ResetStatus) { SetStatus "Ready - right-click the URL box for Paste and Download" }
        }
    }
    if (-not $script:ffmpeg) {
        $chkSubs.Checked = $false; $chkSubs.Enabled = $false
        $chkThumb.Checked = $false; $chkThumb.Enabled = $false
    } else {
        $chkSubs.Enabled = $true
        $chkThumb.Enabled = $true
    }
}

# -- DYNAMIC THEME APPLIER -------------------------------------------------
function Style-Button($btn, $bgColor, $fgColor, $isDark) {
    $btn.BackColor = $bgColor; $btn.ForeColor = $fgColor
    if ($isDark) { $btn.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb([Math]::Min($bgColor.R+25,255), [Math]::Min($bgColor.G+25,255), [Math]::Min($bgColor.B+25,255)) } 
    else { $btn.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb([Math]::Max($bgColor.R-20,0), [Math]::Max($bgColor.G-20,0), [Math]::Max($bgColor.B-20,0)) }
}

# Cancel button: flat buttons do NOT auto-gray when disabled, so give the
# disabled state an unmistakable muted look instead of a dead red button.
function Set-CancelButtonState([bool]$active) {
    $btnCancel.Enabled = $active
    $t = Get-ThemePalette $cfg.Theme
    if ($active) {
        Style-Button $btnCancel $t.Danger (HexToCol "#ffffff") $t.IsDark
    } else {
        $btnCancel.BackColor = $t.BtnGray
        $btnCancel.ForeColor = $t.Sub
        $btnCancel.FlatAppearance.MouseOverBackColor = $t.BtnGray
    }
}

# DARK / LIGHT TITLE BAR (follows the theme) - defined here because
# Apply-Theme calls it at SCRIPT LOAD, and PowerShell does not hoist
# function definitions to earlier statements.
function Apply-DarkTitleBar([bool]$dark, $palette) {
    try {
        if (-not ("Win32.Dwm" -as [type])) { return }
        [void]$form.Handle
        $v = if ($dark) { 1 } else { 0 }
        [void][Win32.Dwm]::DwmSetWindowAttribute($form.Handle, 20, [ref]$v, 4)   # Win11
        [void][Win32.Dwm]::DwmSetWindowAttribute($form.Handle, 19, [ref]$v, 4)   # Win10
        try {
            # caption + caption text colors (Win11 22H2+); harmless if unsupported
            $cap = [System.Drawing.ColorTranslator]::ToWin32($palette.Panel)
            $capTxt = [System.Drawing.ColorTranslator]::ToWin32($palette.Text)
            [void][Win32.Dwm]::DwmSetWindowAttribute($form.Handle, 33, [ref]$cap, 4)
            [void][Win32.Dwm]::DwmSetWindowAttribute($form.Handle, 34, [ref]$capTxt, 4)
        } catch { }
    } catch { }
}

function Update-AudioUIState {
    $isAudio = $chkAudio.Checked
    $cmbAudioFmt.Enabled = $isAudio
    $cmbAudioQuality.Enabled = $isAudio
    $cmbFormat.Enabled   = (-not $isAudio)
    $cmbQuality.Enabled  = (-not $isAudio)
}

# -- yt-dlp UPDATE CHECK (non-blocking; runs at startup and after updates) ---
function Check-YtDlpVersion {
    try {
        if (-not $script:ytdlp) { return }
        $local = ""
        try { $local = [string](& $script:ytdlp --version 2>&1 | Select-Object -First 1) } catch { }
        $script:ytdlpLocal = $local
        if ($script:updateJob) { try { Remove-Job $script:updateJob -Force -ErrorAction SilentlyContinue } catch { } }
        $script:updateJob = Start-Job {
            param($local)
            $remote = $null
            try {
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                $r = Invoke-RestMethod -Uri "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest" -Headers @{ "User-Agent" = "NowVideoDown" } -TimeoutSec 20
                $remote = [string]$r.tag_name
            } catch { }
            [PSCustomObject]@{ Local = $local; Remote = $remote }
        } -ArgumentList $local
        if ($script:updTimer) { try { $script:updTimer.Stop(); $script:updTimer.Dispose() } catch { } }
        $script:updTimer = New-Object System.Windows.Forms.Timer
        $script:updTimer.Interval = 1000
        $script:updTimer.Add_Tick({
            try {
                if ($script:updateJob -and $script:updateJob.State -ne 'Running') {
                    $script:updTimer.Stop(); $script:updTimer.Dispose(); $script:updTimer = $null
                    $res = @(Receive-Job $script:updateJob -ErrorAction SilentlyContinue)
                    Remove-Job $script:updateJob -Force -ErrorAction SilentlyContinue; $script:updateJob = $null
                    if ($res -and $res[0].Remote) {
                        $l = [string]$res[0].Local; $r = [string]$res[0].Remote
                        if ($l -and $r -and $l -ne $r) {
                            $script:ytdlpOutdated = $true
                            $lnkUpdateYt.Text = "yt-dlp $l -> $r - update now"
                            $lnkUpdateYt.Visible = $true
                            Log ("yt-dlp update available: {0} -> {1}" -f $l, $r) "Yellow"
                        }
                    }
                }
            } catch {
                try { Write-SessionLog ("UPDATE CHECK ERROR: " + $_.Exception.Message) } catch { }
            }
        })
        $script:updTimer.Start()
    } catch { }
}

# -- FIRST-RUN WIZARD (only when settings.json does not exist yet) ----------
function Show-FirstRunWizard {
    try {
        Log "Wizard: opening" "Cyan"
        $t = Get-ThemePalette $cfg.Theme
        $frm = New-Object System.Windows.Forms.Form
        $frm.Text = "Welcome to NowVideoDown"
        $frm.Size = [System.Drawing.Size]::new(560, 420)
        $frm.StartPosition = 'CenterParent'; $frm.FormBorderStyle = 'FixedDialog'
        $frm.MaximizeBox = $false; $frm.MinimizeBox = $false
        $frm.BackColor = $t.Bg; $frm.ForeColor = $t.Text
        if (Test-Path $IconPath) { try { $frm.Icon = New-Object System.Drawing.Icon($IconPath) } catch { } }

        $lblHello = New-Object System.Windows.Forms.Label
        $lblHello.Text = "Welcome! Two quick choices and you are ready to download."
        $lblHello.Location = [System.Drawing.Point]::new(20, 16); $lblHello.AutoSize = $true; $lblHello.ForeColor = $t.Sub

        $gb1 = New-Object System.Windows.Forms.GroupBox
        $gb1.Text = "1. DOWNLOAD ENGINE"; $gb1.Font = $fBold; $gb1.ForeColor = $t.Accent
        $gb1.Location = [System.Drawing.Point]::new(20, 46); $gb1.Size = [System.Drawing.Size]::new(520, 82)
        $lblYt = New-Object System.Windows.Forms.Label; $lblYt.Text = "yt-dlp:"; $lblYt.Location = [System.Drawing.Point]::new(15, 28); $lblYt.AutoSize = $true; $lblYt.ForeColor = $t.Text
        $lblYtState = New-Object System.Windows.Forms.Label; $lblYtState.Location = [System.Drawing.Point]::new(75, 28); $lblYtState.AutoSize = $true; $lblYtState.Font = $fBold
        $lblFfmpeg = New-Object System.Windows.Forms.Label; $lblFfmpeg.Text = "ffmpeg:"; $lblFfmpeg.Location = [System.Drawing.Point]::new(15, 54); $lblFfmpeg.AutoSize = $true; $lblFfmpeg.ForeColor = $t.Text
        $lblFfmpegState = New-Object System.Windows.Forms.Label; $lblFfmpegState.Location = [System.Drawing.Point]::new(75, 54); $lblFfmpegState.AutoSize = $true; $lblFfmpegState.Font = $fBold
        if ($script:ytdlp) { $lblYtState.Text = "Ready (v$script:ytdlpLocal)"; $lblYtState.ForeColor = $t.Success }
        else { $lblYtState.Text = "Missing - get it from Tools later"; $lblYtState.ForeColor = $t.Warn }
        if ($script:ffmpeg) { $lblFfmpegState.Text = "Ready"; $lblFfmpegState.ForeColor = $t.Success }
        else { $lblFfmpegState.Text = "Missing - get it from Tools later"; $lblFfmpegState.ForeColor = $t.Warn }
        $gb1.Controls.AddRange(@($lblYt, $lblYtState, $lblFfmpeg, $lblFfmpegState))

        $gb2 = New-Object System.Windows.Forms.GroupBox
        $gb2.Text = "2. APPEARANCE"; $gb2.Font = $fBold; $gb2.ForeColor = $t.Accent
        $gb2.Location = [System.Drawing.Point]::new(20, 138); $gb2.Size = [System.Drawing.Size]::new(520, 72)
        $cmbThemeW = New-Object System.Windows.Forms.ComboBox; $cmbThemeW.Location = [System.Drawing.Point]::new(15, 32); $cmbThemeW.Size = [System.Drawing.Size]::new(240, 26); $cmbThemeW.DropDownStyle = 'DropDownList'; $cmbThemeW.FlatStyle = 'Flat'; $cmbThemeW.BackColor = $t.Entry; $cmbThemeW.ForeColor = $t.Text
        $ThemesList | ForEach-Object { [void]$cmbThemeW.Items.Add($_) }
        $ti = $cmbThemeW.Items.IndexOf($cfg.Theme); if ($ti -ge 0) { $cmbThemeW.SelectedIndex = $ti } else { $cmbThemeW.SelectedIndex = 0 }
        $gb2.Controls.AddRange(@($cmbThemeW))

        $gb3 = New-Object System.Windows.Forms.GroupBox
        $gb3.Text = "3. DOWNLOADS FOLDER"; $gb3.Font = $fBold; $gb3.ForeColor = $t.Accent
        $gb3.Location = [System.Drawing.Point]::new(20, 220); $gb3.Size = [System.Drawing.Size]::new(520, 78)
        $txtFolderW = New-Object System.Windows.Forms.TextBox; $txtFolderW.Location = [System.Drawing.Point]::new(15, 34); $txtFolderW.Size = [System.Drawing.Size]::new(400, 26); $txtFolderW.Text = $DownloadFolder; $txtFolderW.BackColor = $t.Entry; $txtFolderW.ForeColor = $t.Text
        $btnBrowseW = New-ProButton "Browse..." 425 31 75 28
        $btnBrowseW.Add_Click({
            $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
            $fbd.Description = "Choose the default downloads folder"
            try { $fbd.SelectedPath = $txtFolderW.Text } catch { }
            if ($fbd.ShowDialog() -eq 'OK') { $txtFolderW.Text = $fbd.SelectedPath }
        })
        $gb3.Controls.AddRange(@($txtFolderW, $btnBrowseW))

        $btnOkW = New-Object System.Windows.Forms.Button
        $btnOkW.Text = "Start using NowVideoDown"; $btnOkW.Location = [System.Drawing.Point]::new(140, 318); $btnOkW.Size = [System.Drawing.Size]::new(210, 34)
        $btnOkW.FlatStyle = 'Flat'; $btnOkW.FlatAppearance.BorderSize = 0
        Style-Button $btnOkW $t.Success (HexToCol "#ffffff") $t.IsDark
        $btnSkipW = New-Object System.Windows.Forms.Button
        $btnSkipW.Text = "Skip"; $btnSkipW.Location = [System.Drawing.Point]::new(360, 318); $btnSkipW.Size = [System.Drawing.Size]::new(80, 34)
        $btnSkipW.FlatStyle = 'Flat'; $btnSkipW.FlatAppearance.BorderSize = 0
        Style-Button $btnSkipW $t.BtnGray $t.Text $t.IsDark
        $btnSkipW.DialogResult = 'Cancel'
        $frm.AcceptButton = $btnOkW; $frm.CancelButton = $btnSkipW
        $btnOkW.Add_Click({
            try {
                if ($cmbThemeW.Text) { $cfg.Theme = $cmbThemeW.Text; Apply-Theme $cfg.Theme }
                $folder = $txtFolderW.Text.Trim()
                if (-not $folder) { $folder = $DownloadFolder }
                if ($folder -ne $DownloadFolder) {
                    $dp = $cfg.Profiles | Where-Object { $_.Name -eq "Default Video" }
                    if ($dp) { $dp.Folder = $folder }
                }
                $script:isUpdatingUI = $true; $cmbFolder.Text = $folder; $script:isUpdatingUI = $false
                Save-Settings $form $cfg
                Log "First-run setup complete." "Lime"
            } catch { }
            $frm.Close()
        })
        $frm.Controls.AddRange(@($lblHello, $gb1, $gb2, $gb3, $btnOkW, $btnSkipW))
        [void]$frm.ShowDialog()
    } catch {
        try { Write-SessionLog ("WIZARD ERROR: " + $_.Exception.Message); $_ | Out-File (Join-Path $ScriptDir "error.log") -Encoding UTF8 -Force } catch { }
    }
}

function Apply-Theme($themeName) {
    $t = Get-ThemePalette $themeName
    $form.BackColor = $t.Bg; $form.ForeColor = $t.Text
    $menu.BackColor = $t.Panel; $menu.ForeColor = $t.Text
    Apply-DarkTitleBar $t.IsDark $t
    
    # Color GroupBox Headers
    @($gbUrl, $gbProf, $gbOpts, $gbStatus) | ForEach-Object { $_.ForeColor = $t.Accent }
    
    $lblTitle.ForeColor = $t.Text
    @($lblSub, $lblCredits, $lblStatus, $lblSpeed, $lblEta, $lblFooter, $lblProfileSummary, $lblClipHint) | ForEach-Object { $_.ForeColor = $t.Sub }
    $lblWarn.ForeColor = $t.Warn
    $lblDirty.ForeColor = $t.Warn
    $lblClipUrl.ForeColor = $t.Accent
    $lnkUpdateYt.LinkColor = $t.Accent; $lnkUpdateYt.ActiveLinkColor = $t.Accent; $lnkUpdateYt.VisitedLinkColor = $t.Accent
    $lnkUpdateYt.ForeColor = $t.Accent
    $lblVideoHdr.ForeColor = $t.Accent; $lblAudioHdr.ForeColor = $t.Accent
    $sepCol.BackColor = $t.BtnGray
    
    $textBg = $t.Entry; $textFg = $t.Text
    @($txtUrl, $cmbFolder, $cmbProfile, $cmbFormat, $cmbQuality, $cmbAudioFmt, $cmbAudioQuality, $txtLog) | ForEach-Object { $_.BackColor = $textBg; $_.ForeColor = $textFg }
    
    @($chkAudio, $chkSubs, $chkThumb, $chkPlaylist, $chkVerbose, $chkQuick) | ForEach-Object { $_.ForeColor = $t.Text }

    $primaryFg = HexToCol "#ffffff"
    $grayFg    = $t.Text

    Style-Button $btnClear      $t.BtnGray $grayFg    $t.IsDark
    Style-Button $btnDownload   $t.Accent  $primaryFg $t.IsDark
    Style-Button $btnList       $t.Success $primaryFg $t.IsDark
    Style-Button $btnNewProf    $t.Success $primaryFg $t.IsDark
    Style-Button $btnEditProf   $t.BtnGray $grayFg    $t.IsDark
    Style-Button $btnManageProf $t.Accent  $primaryFg $t.IsDark
    Style-Button $btnBrowse     $t.BtnGray $grayFg    $t.IsDark
    Style-Button $btnOpenDest   $t.BtnGray $grayFg    $t.IsDark
    Style-Button $btnClipDl     $t.Success $primaryFg $t.IsDark
    Style-Button $btnClipIgnore $t.BtnGray $grayFg    $t.IsDark
    Style-Button $btnFolder     $t.BtnGray $grayFg    $t.IsDark
    Style-Button $btnOpenList   $t.BtnGray $grayFg    $t.IsDark
    Style-Button $btnPlayLast   $t.Success $primaryFg $t.IsDark
    Set-CancelButtonState $btnCancel.Enabled
}

$ctx = New-Object System.Windows.Forms.ContextMenuStrip
$miPaste   = $ctx.Items.Add("Paste"); $miPasteDL = $ctx.Items.Add("Paste and Download")
[void]$ctx.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$miSelAll  = $ctx.Items.Add("Select All"); $miClear   = $ctx.Items.Add("Clear")
$miPaste.Add_Click({ try { $txtUrl.Text = ([string][System.Windows.Forms.Clipboard]::GetText()).Trim() } catch { } })
$miPasteDL.Add_Click({
    try { $txtUrl.Text = ([string][System.Windows.Forms.Clipboard]::GetText()).Trim() } catch { }
    # Show the pasted URL immediately, then start the download on the next
    # UI tick - feels instant instead of "clicked but nothing happened".
    $txtUrl.Update()
    if ($script:pasteDlTimer) { try { $script:pasteDlTimer.Stop(); $script:pasteDlTimer.Dispose() } catch { }; $script:pasteDlTimer = $null }
    $script:pasteDlTimer = New-Object System.Windows.Forms.Timer
    $script:pasteDlTimer.Interval = 120
    $script:pasteDlTimer.Add_Tick({
        try {
            $script:pasteDlTimer.Stop(); $script:pasteDlTimer.Dispose(); $script:pasteDlTimer = $null
            Start-SingleDownload
        } catch {
            try { Write-SessionLog ("PASTE TICK ERROR: " + $_.Exception.Message); $_ | Out-File (Join-Path $ScriptDir "error.log") -Encoding UTF8 -Force } catch { }
        }
    })
    $script:pasteDlTimer.Start()
})
$miSelAll.Add_Click({ $txtUrl.SelectAll() }); $miClear.Add_Click({ $txtUrl.Clear() })
$txtUrl.ContextMenuStrip = $ctx

# -- DRAG & DROP URL SUPPORT ------------------------------------------------
$form.AllowDrop = $true; $txtUrl.AllowDrop = $true
$dragEnter = {
    if ($_.Data.GetDataPresent([System.Windows.Forms.DataFormats]::Text)) { $_.Effect = [System.Windows.Forms.DragDropEffects]::Copy }
    else { $_.Effect = [System.Windows.Forms.DragDropEffects]::None }
}
$dragDrop = {
    try { $txtUrl.Text = ([string]$_.Data.GetData([System.Windows.Forms.DataFormats]::Text)).Trim() } catch { }
    $txtUrl.Focus()
}
$form.Add_DragEnter($dragEnter); $form.Add_DragDrop($dragDrop)
$txtUrl.Add_DragEnter($dragEnter); $txtUrl.Add_DragDrop($dragDrop)

$form.Controls.AddRange(@(
    $lblTitle,$lblSub,$lblCredits,
    $gbUrl, $gbProf, $gbOpts, $gbStatus
))

# -- CLIPBOARD WATCH --------------------------------------------------------
function Show-ClipChip {
    try {
        if (-not $script:clipUrl) { return }
        $lblClipHint.Visible = $false
        $hostPart = ""; try { $hostPart = ([uri]$script:clipUrl).Host } catch { }
        $lblClipUrl.Text = "📋 Detected: $hostPart"
        $lblClipUrl.Visible = $true; $btnClipDl.Visible = $true; $btnClipIgnore.Visible = $true
    } catch { }
}
function Clear-ClipChip {
    try {
        $script:clipUrl = $null
        $lblClipUrl.Visible = $false; $btnClipDl.Visible = $false; $btnClipIgnore.Visible = $false
        $lblClipHint.Visible = $cfg.ClipboardWatch
    } catch { }
}
function Sync-ClipboardWatchUI {
    try { if (-not $cfg.ClipboardWatch) { Clear-ClipChip } else { Show-ClipChip } } catch { }
}
$lblClipUrl.Add_Click({ if ($script:clipUrl) { $txtUrl.Text = $script:clipUrl; Clear-ClipChip; $txtUrl.Focus() } })
$btnClipDl.Add_Click({ if ($script:clipUrl) { $txtUrl.Text = $script:clipUrl; Clear-ClipChip; Start-SingleDownload } })
$btnClipIgnore.Add_Click({ Clear-ClipChip })
$script:clipTimer = New-Object System.Windows.Forms.Timer
$script:clipTimer.Interval = 1000
$script:clipTimer.Add_Tick({
    try {
        if (-not $cfg.ClipboardWatch) { return }
        $txt = ""
        try { $txt = ([string][System.Windows.Forms.Clipboard]::GetText()).Trim() } catch { return }
        if ([string]::IsNullOrWhiteSpace($txt)) {
            if ($script:clipUrl) { Clear-ClipChip }
            return
        }
        if ($txt -eq $script:clipLast) { return }
        $script:clipLast = $txt
        if ($txt -match '^https?://') {
            $script:clipUrl = $txt
            Show-ClipChip
        } else {
            if ($script:clipUrl) { Clear-ClipChip }
        }
    } catch {
        try { Write-SessionLog ("CLIP TICK ERROR: " + $_.Exception.Message); $_ | Out-File (Join-Path $ScriptDir "error.log") -Encoding UTF8 -Force } catch { }
    }
})
$script:clipTimer.Start()
Sync-ClipboardWatchUI

# -- TOOLTIPS ---------------------------------------------------------------
$tooltip = New-Object System.Windows.Forms.ToolTip
$tooltip.InitialDelay = 400
$tooltip.SetToolTip($txtUrl,      "Paste a video URL here, then press Enter or click Download URL")
$tooltip.SetToolTip($btnDownload, "Download the URL from the box above")
$tooltip.SetToolTip($btnClear,    "Clear the URL box")
$tooltip.SetToolTip($btnOpenList, "Edit list.txt in Notepad (Ctrl+O)")
$tooltip.SetToolTip($btnList,     "Download every URL listed in list.txt, one per line (Ctrl+R)")
$tooltip.SetToolTip($gbUrl,       "Paste any video URL and download it, or manage the batch list (list.txt)")
$tooltip.SetToolTip($cmbProfile,  "Active profile - a saved set of format/quality/folder options")
$tooltip.SetToolTip($lblDirty,    "Settings changed since you selected this profile - they are auto-saved and persisted when the app closes")
$tooltip.SetToolTip($btnNewProf,  "Create a new profile from the current settings (Ctrl+N)")
$tooltip.SetToolTip($btnEditProf, "Edit the active profile's full options (Ctrl+E)")
$tooltip.SetToolTip($btnManageProf, "Manage all profiles: edit, rename, duplicate, delete, reorder, import/export")
$tooltip.SetToolTip($cmbFolder,   "Destination folder for this profile - type a path or pick a recent one")
$tooltip.SetToolTip($btnBrowse,   "Choose the destination folder with a folder picker")
$tooltip.SetToolTip($btnOpenDest, "Open the active destination folder in Explorer")
$tooltip.SetToolTip($chkQuick,    "Quick mode: settings apply to this download only and are NOT saved to any profile")
$tooltip.SetToolTip($cmbFormat,   "Video container format (mp4 / mkv / webm)")
$tooltip.SetToolTip($cmbQuality,  "Maximum resolution (video downloads only)")
$tooltip.SetToolTip($chkAudio,    "Extract audio only - switches the output to the AUDIO column")
$tooltip.SetToolTip($cmbAudioFmt, "Audio format for audio-only downloads (mp3 / m4a / opus / flac / wav)")
$tooltip.SetToolTip($chkSubs,     "Download and embed subtitles (needs ffmpeg)")
$tooltip.SetToolTip($chkThumb,    "Embed the video thumbnail (needs ffmpeg)")
$tooltip.SetToolTip($chkPlaylist, "Download the whole playlist/channel instead of a single video")
$tooltip.SetToolTip($chkVerbose,  "Show the full yt-dlp output in the log")
$tooltip.SetToolTip($btnCancel,   "Stop the current download and clean up partial files - only active during a download")
$tooltip.SetToolTip($btnFolder,   "Open the active destination folder")
$tooltip.SetToolTip($btnPlayLast, "Play the most recently downloaded file")
$tooltip.SetToolTip($gbProf,      "Profiles bundle a destination folder with all output settings")
$tooltip.SetToolTip($gbOpts,      "Output settings split into VIDEO and AUDIO columns")
$tooltip.SetToolTip($gbStatus,    "Download progress, log and utilities")
$tooltip.SetToolTip($progress,    "Download progress")
$tooltip.SetToolTip($lblStatus,   "Current status of the download engine")
$tooltip.SetToolTip($lblSpeed,    "Current download speed")
$tooltip.SetToolTip($lblEta,      "Estimated time remaining")
$tooltip.SetToolTip($txtLog,      "Full yt-dlp output - scrollable")
$tooltip.SetToolTip($lblProfileSummary, "What the active profile will produce and where it saves")
$tooltip.SetToolTip($lnkUpdateYt, "A newer yt-dlp is available - click to update it now")
$tooltip.SetToolTip($cmbAudioQuality,  "Audio bitrate (Best = original quality)")
$tooltip.SetToolTip($lblClipHint,      "Copy a video URL anywhere and it will appear here - toggle under Tools or the tray menu")
$tooltip.SetToolTip($lblClipUrl,       "Click to copy the detected URL into the URL box")
$tooltip.SetToolTip($btnClipDl,        "Download the detected URL now")
$tooltip.SetToolTip($btnClipIgnore,    "Ignore this URL")

Update-UIState -ResetStatus
Apply-Theme $cfg.Theme
Check-YtDlpVersion

# -- ABOUT MENU WIRING -----------------------------------------------------
function Get-ImageSafe($path) {
    # loads an image WITHOUT locking the file; returns $null on ANY failure so
    # a missing/corrupt image can never crash the app
    try {
        if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path)) { return $null }
        $fs = [System.IO.File]::OpenRead($path)
        $src = [System.Drawing.Image]::FromStream($fs)
        $copy = New-Object System.Drawing.Bitmap($src)
        $src.Dispose(); $fs.Dispose()
        return $copy
    } catch { try { $fs.Dispose() } catch { }; return $null }
}

function Show-AboutDialog {
    try {
        $t = Get-ThemePalette $cfg.Theme
        $abtForm = New-Object System.Windows.Forms.Form
        $script:aboutForm = $abtForm
        $abtForm.BackColor = $t.Bg; $abtForm.ForeColor = $t.Text
        $abtForm.Text = "About Now Video Down"
        $abtForm.Size = [System.Drawing.Size]::new(640, 500)
        $abtForm.StartPosition = 'CenterParent'; $abtForm.FormBorderStyle = 'FixedDialog'
        $abtForm.MaximizeBox = $false; $abtForm.MinimizeBox = $false
        if (Test-Path $IconPath) { try { $abtForm.Icon = New-Object System.Drawing.Icon($IconPath) } catch { } }

        # logo image (fallback: app icon) - missing files are simply skipped
        $picLogo = New-Object System.Windows.Forms.PictureBox
        $picLogo.Location = [System.Drawing.Point]::new(20, 24); $picLogo.Size = [System.Drawing.Size]::new(140, 140)
        $picLogo.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
        $picLogo.BackColor = $t.Bg
        $picLogo.Visible = $false
        $logoImg = Get-ImageSafe (Join-Path $ScriptDir "NowVideoDown-Logo.png")
        if ($null -eq $logoImg -and (Test-Path $IconPath)) {
            try { $logoImg = (New-Object System.Drawing.Icon($IconPath)).ToBitmap() } catch { }
        }
        if ($null -ne $logoImg) { $picLogo.Image = $logoImg; $picLogo.Visible = $true }

        $lblTitleAbt = New-Object System.Windows.Forms.Label
        $lblTitleAbt.Text = "Now Video Down"; $lblTitleAbt.Font = $fTitle; $lblTitleAbt.Location = [System.Drawing.Point]::new(185, 34)
        $lblTitleAbt.AutoSize = $true; $lblTitleAbt.ForeColor = $t.Accent

        $lblVer = New-Object System.Windows.Forms.Label
        $lblVer.Text = "Pro Edition v2.37"; $lblVer.Font = $fBold; $lblVer.Location = [System.Drawing.Point]::new(185, 66)
        $lblVer.AutoSize = $true; $lblVer.ForeColor = $t.Text

        $lblDesc = New-Object System.Windows.Forms.Label
        $lblDesc.Text = "The ultimate YouTube and 1000+ sites video/audio downloader.`n`nDesigned and Developed by Nikos Georgousis | June 2026"
        $lblDesc.Location = [System.Drawing.Point]::new(185, 96); $lblDesc.Size = [System.Drawing.Size]::new(430, 70)
        $lblDesc.ForeColor = $t.Sub

        # Dependencies section
        $lblDeps = New-Object System.Windows.Forms.Label
        $lblDeps.Text = "DEPENDENCIES:"
        $lblDeps.Font = $fBold
        $lblDeps.Location = [System.Drawing.Point]::new(20, 190); $lblDeps.AutoSize = $true
        $lblDeps.ForeColor = $t.Accent

        $lblDepInfo = New-Object System.Windows.Forms.Label
        $lblDepInfo.Text = "This script relies on third-party tools for its core functionality:"
        $lblDepInfo.Location = [System.Drawing.Point]::new(20, 213); $lblDepInfo.Size = [System.Drawing.Size]::new(600, 20)
        $lblDepInfo.ForeColor = $t.Sub

        $lnkYtdlp = New-Object System.Windows.Forms.LinkLabel
        $lnkYtdlp.Text = "• yt-dlp (YouTube downloader) - https://github.com/yt-dlp/yt-dlp"
        $lnkYtdlp.Location = [System.Drawing.Point]::new(20, 240); $lnkYtdlp.Size = [System.Drawing.Size]::new(600, 20)
        $lnkYtdlp.LinkColor = $t.Accent; $lnkYtdlp.ActiveLinkColor = $t.Accent; $lnkYtdlp.VisitedLinkColor = $t.Accent
        $lnkYtdlp.ForeColor = $t.Sub
        $lnkYtdlp.Add_Click({ Start-Process "https://github.com/yt-dlp/yt-dlp" })

        $lnkFfmpeg = New-Object System.Windows.Forms.LinkLabel
        $lnkFfmpeg.Text = "• FFmpeg (for merging/thumbnails) - https://github.com/yt-dlp/FFmpeg-Builds"
        $lnkFfmpeg.Location = [System.Drawing.Point]::new(20, 265); $lnkFfmpeg.Size = [System.Drawing.Size]::new(600, 20)
        $lnkFfmpeg.LinkColor = $t.Accent; $lnkFfmpeg.ActiveLinkColor = $t.Accent; $lnkFfmpeg.VisitedLinkColor = $t.Accent
        $lnkFfmpeg.ForeColor = $t.Sub
        $lnkFfmpeg.Add_Click({ Start-Process "https://github.com/yt-dlp/FFmpeg-Builds" })

        $lnkFfmpegAlt = New-Object System.Windows.Forms.LinkLabel
        $lnkFfmpegAlt.Text = "• FFmpeg (alternative) - https://www.gyan.dev/ffmpeg/builds/"
        $lnkFfmpegAlt.Location = [System.Drawing.Point]::new(20, 290); $lnkFfmpegAlt.Size = [System.Drawing.Size]::new(600, 20)
        $lnkFfmpegAlt.LinkColor = $t.Accent; $lnkFfmpegAlt.ActiveLinkColor = $t.Accent; $lnkFfmpegAlt.VisitedLinkColor = $t.Accent
        $lnkFfmpegAlt.ForeColor = $t.Sub
        $lnkFfmpegAlt.Add_Click({ Start-Process "https://www.gyan.dev/ffmpeg/builds/" })

        # Repository link
        $lblRepo = New-Object System.Windows.Forms.Label
        $lblRepo.Text = "Project Repository:"
        $lblRepo.Font = $fBold
        $lblRepo.Location = [System.Drawing.Point]::new(20, 335); $lblRepo.AutoSize = $true
        $lblRepo.ForeColor = $t.Accent

        $lnkRepo = New-Object System.Windows.Forms.LinkLabel
        $lnkRepo.Text = "https://github.com/limbo666/NowVideoDown"
        $lnkRepo.Location = [System.Drawing.Point]::new(20, 358); $lnkRepo.Size = [System.Drawing.Size]::new(600, 20)
        $lnkRepo.LinkColor = $t.Accent; $lnkRepo.ActiveLinkColor = $t.Accent; $lnkRepo.VisitedLinkColor = $t.Accent
        $lnkRepo.ForeColor = $t.Sub
        $lnkRepo.Add_Click({ Start-Process "https://github.com/limbo666/NowVideoDown" })

        $btnOkAbt = New-Object System.Windows.Forms.Button
        $btnOkAbt.Text = "Close"; $btnOkAbt.Location = [System.Drawing.Point]::new(270, 420); $btnOkAbt.Size = [System.Drawing.Size]::new(90, 30)
        $btnOkAbt.FlatStyle = 'Flat'; $btnOkAbt.FlatAppearance.BorderSize = 0
        Style-Button $btnOkAbt $t.BtnGray $t.Text $t.IsDark
        $btnOkAbt.DialogResult = 'OK'

        $abtForm.Controls.AddRange(@($picLogo, $lblTitleAbt, $lblVer, $lblDesc, $lblDeps, $lblDepInfo, $lnkYtdlp, $lnkFfmpeg, $lnkFfmpegAlt, $lblRepo, $lnkRepo, $btnOkAbt))
        $abtForm.Add_FormClosed({ try { $script:aboutForm = $null } catch { } })
        [void]$abtForm.ShowDialog()
    } catch {
        try { Write-SessionLog ("ABOUT ERROR: " + $_.Exception.Message); $_ | Out-File (Join-Path $ScriptDir "error.log") -Encoding UTF8 -Force } catch { }
    }
}

$menuAbout.Add_Click({ Show-AboutDialog })

# -- HELPER FUNCTIONS ------------------------------------------------------
function Get-SafeInputBox($title, $prompt) {
    $frm = New-Object System.Windows.Forms.Form
    $t = Get-ThemePalette $cfg.Theme
    $frm.Text = $title; $frm.Size = [System.Drawing.Size]::new(350,150)
    $frm.StartPosition = 'CenterParent'; $frm.FormBorderStyle = 'FixedDialog'
    $frm.MaximizeBox = $false; $frm.MinimizeBox = $false; $frm.BackColor = $t.Bg; $frm.ForeColor = $t.Text
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $prompt; $lbl.Location = [System.Drawing.Point]::new(10,20); $lbl.AutoSize = $true
    $txt = New-Object System.Windows.Forms.TextBox
    $txt.Location = [System.Drawing.Point]::new(10,45); $txt.Size = [System.Drawing.Size]::new(310,24); $txt.BackColor = $t.Entry; $txt.ForeColor = $t.Text
    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = "OK"; $btnOk.Location = [System.Drawing.Point]::new(160,80); $btnOk.DialogResult = 'OK'; $btnOk.FlatStyle = 'Flat'; $btnOk.FlatAppearance.BorderSize = 0
    Style-Button $btnOk $t.Success (HexToCol "#ffffff") $t.IsDark
    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancel"; $btnCancel.Location = [System.Drawing.Point]::new(240,80); $btnCancel.DialogResult = 'Cancel'; $btnCancel.FlatStyle = 'Flat'; $btnCancel.FlatAppearance.BorderSize = 0
    Style-Button $btnCancel $t.BtnGray $t.Text $t.IsDark
    $frm.Controls.AddRange(@($lbl,$txt,$btnOk,$btnCancel))
    $frm.AcceptButton = $btnOk; $frm.CancelButton = $btnCancel
    if ($frm.ShowDialog() -eq 'OK' -and $txt.Text.Trim() -ne "") { return $txt.Text.Trim() }
    return $null
}

function Get-ActiveFolder {
    if ($script:runFolderOverride) { return $script:runFolderOverride }
    $path = $cmbFolder.Text.Trim()
    if (-not $path) { $path = $DownloadFolder }
    if (-not (Test-Path $path)) {
        try { New-Item -ItemType Directory -Path $path -Force | Out-Null }
        catch { 
            $path = Join-Path $ScriptDir "Downloads"
            if (-not (Test-Path $path)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
            Log "Warning: Profile folder unavailable. Falling back to default Downloads."
        }
    }
    return $path
}

function Log($msg, $overrideColor = $null) {
    $txtLog.SelectionStart  = $txtLog.TextLength
    $txtLog.SelectionLength = 0
    $t = Get-ThemePalette $cfg.Theme
    if ($overrideColor) { 
        try { $txtLog.SelectionColor = [System.Drawing.Color]::$overrideColor } catch { $txtLog.SelectionColor = $t.Accent }
    } else {
        $txtLog.SelectionColor = $t.Sub
    }
    $txtLog.AppendText("$msg`n")
    $txtLog.ScrollToCaret()
    Write-SessionLog $msg
}

function SetProgress($pct) { $progress.Value = [Math]::Max(0, [Math]::Min(100, [int]$pct)) }
function Get-SafeFileName($fullPath) { try { return Split-Path -Path $fullPath -Leaf -ErrorAction Stop } catch { return $fullPath } }
function Clean-YtDlpPath($raw) { try { if ($null -eq $raw) { return "" }; return ($raw -replace '"','').Trim() } catch { return "" } }

function Get-YtdlpArgs($url) {
    $p = Get-ActiveProfile
    $fmt  = $cmbFormat.Text; $qual = $cmbQuality.Text
    $targetDir = Get-ActiveFolder
    if ($p -and $p.Subfolder) {
        $sub = $p.Subfolder
        if ($sub -eq '@date')      { $sub = Get-Date -Format "yyyy-MM-dd" }
        elseif ($sub -eq '@uploader') { $sub = "%(uploader)s" }
        elseif ($sub -eq '@playlist') { $sub = "%(playlist)s" }
        try { New-Item -ItemType Directory -Path (Join-Path $targetDir $sub) -Force | Out-Null } catch { }
        $targetDir = Join-Path $targetDir $sub
    }
    $tpl = "%(title)s.%(ext)s"
    if ($p -and $p.FilenameTemplate) { $tpl = $p.FilenameTemplate }
    # escape literal % (keep template markers like %(title)s intact)
    $outTpl = ((Join-Path $targetDir $tpl) -replace '%(?!\()', '%%')
    $a = [System.Collections.Generic.List[string]]::new()
    
    if ($chkAudio.Checked) {
        $aFmt = $cmbAudioFmt.Text; if (-not $aFmt) { $aFmt = "mp3" }
        $aq = if ($p -and $p.AudioQuality) { $p.AudioQuality } else { $cmbAudioQuality.Text }
        $aqArg = switch ($aq) { "Best" { "0" } "128" { "128K" } "192" { "192K" } "320" { "320K" } default { "0" } }
        $a.AddRange([string[]]@('-x','--audio-format',$aFmt,'--audio-quality',$aqArg))
    } 
    else {
        $vidFormat = "bestvideo+bestaudio/best"
        if ($qual -eq "1080p") { $vidFormat = "bv*[height<=1080]+ba/b / bv[height<=1080] / best[height<=1080] / best" }
        elseif ($qual -eq "720p") { $vidFormat = "bv*[height<=720]+ba/b / bv[height<=720] / best[height<=720] / best" }
        elseif ($qual -eq "480p") { $vidFormat = "bv*[height<=480]+ba/b / bv[height<=480] / best[height<=480] / best" }

        if ($fmt -in @('mp4','mkv','webm')) { $a.AddRange([string[]]@('-f', $vidFormat, '--merge-output-format', $fmt)) } 
        else { $a.AddRange([string[]]@('-f', $vidFormat)) }
    }
    if ($chkSubs.Checked) {
        $lang = if ($p -and $p.SubLang) { $p.SubLang } else { "en" }
        $a.AddRange([string[]]@('--write-auto-sub','--embed-subs','--sub-lang',$lang))
    }
    if ($chkThumb.Checked)         { $a.Add('--embed-thumbnail') }
    if (-not $chkPlaylist.Checked) { $a.Add('--no-playlist') }
    elseif ($p -and $p.PlaylistRange) { $a.AddRange([string[]]@('--playlist-items',$p.PlaylistRange)) }
    if ($p -and $p.RateLimit)      { $a.AddRange([string[]]@('--limit-rate',$p.RateLimit)) }
    if ($p -and $p.CookiesFile -and (Test-Path $p.CookiesFile)) { $a.AddRange([string[]]@('--cookies',$p.CookiesFile)) }
    $a.AddRange([string[]]@('--newline','--no-warnings','-o',$outTpl,$url))
    return $a.ToArray()
}

# -- CORE DOWNLOAD ENGINE --------------------------------------------------
function Start-Download($url, [scriptblock]$callback) {
    if (-not $script:ytdlp) {
        [System.Windows.Forms.MessageBox]::Show("yt-dlp.exe not found.`nUse the Tools menu to download it.","Missing yt-dlp",
            [System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        if ($callback) { & $callback $false }
        return
    }

    $script:onDoneCallback = $callback; $script:cancelRequested = $false; Set-CancelButtonState $true; $btnPlayLast.Visible = $false; SetProgress 0
    $script:jobExitCode = $null
    $script:knownPIDs = @(Get-Process -Name 'yt-dlp','ffmpeg' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
    $lblSpeed.Text = "-"; $lblEta.Text = "-"
    $ytExe = $script:ytdlp; $dlArgs = Get-YtdlpArgs $url
    Log "--------------------------------------------------"
    Log "URL: $url" "Cyan"

    if ($script:activeTimer) { try { $script:activeTimer.Stop(); $script:activeTimer.Dispose() } catch {}; $script:activeTimer = $null }

    $script:activeJob = Start-Job -ScriptBlock { param($exe, $toolArgs); & $exe @toolArgs 2>&1; Write-Output ("__EXITCODE__:" + $LASTEXITCODE) } -ArgumentList $ytExe, (, $dlArgs)

    $script:activeTimer = New-Object System.Windows.Forms.Timer; $script:activeTimer.Interval = 250
    $script:activeTimer.Add_Tick({
        try {
        if ($script:cancelRequested) {
            $script:activeTimer.Stop(); $script:activeTimer.Dispose(); $script:activeTimer = $null
            if ($script:activeJob) { Stop-Job $script:activeJob -ErrorAction SilentlyContinue; Remove-Job $script:activeJob -Force -ErrorAction SilentlyContinue; $script:activeJob = $null }
            Log "  Cancelled by user." "Yellow"; SetStatus "Cancelled."
            SetProgress 0; Set-CancelButtonState $false; $lblSpeed.Text = "-"; $lblEta.Text = "-"
            if ($script:onDoneCallback) { & $script:onDoneCallback $false }
            return
        }

        if ($script:activeJob) {
            try   { $lines = @(Receive-Job $script:activeJob -ErrorAction SilentlyContinue) } catch { $lines = @() }
            foreach ($line in $lines) {
                $s = [string]$line
                if ($s -match '^__EXITCODE__:(\d+)') { $script:jobExitCode = [int]$Matches[1]; continue }
                if ($s -match '\[download\]\s+([\d\.]+)%') {
                    $pct = [double]$Matches[1]; SetProgress $pct
                    $detail = ($s -replace '^.*\[download\]\s+[\d\.]+%\s*','').Trim()
                    $detail = ($detail -replace 'at\s+[\d\.]+[KMG]?i?B/s','') -replace 'ETA\s+[\d:]+\s*$',''
                    SetStatus ("Downloading: {0}%   {1}" -f $pct, $detail.Trim())
                    if ($s -match 'at\s+([\d\.]+[KMG]?i?B/s)') { $lblSpeed.Text = $Matches[1] }
                    if ($s -match 'ETA\s+([\d:]+)') { $lblEta.Text = "ETA $($Matches[1])" }
                } 
                elseif ($s -match '\[download\]\s+Destination:\s+(.*)') { Log "Destination: $(Get-SafeFileName (Clean-YtDlpPath $Matches[1]))" } 
                elseif ($s -match '\[download\]\s+(.*?)\s+has\s+already\s+been\s+downloaded') { Log "File already exists: $(Get-SafeFileName (Clean-YtDlpPath $Matches[1]))" "Yellow" } 
                elseif ($s -match '\[Merger\]\s+Merging\s+formats\s+into\s+"?([^"]+)"?') { Log "Merging streams into: $(Get-SafeFileName (Clean-YtDlpPath $Matches[1]))" "Cyan" } 
                elseif ($s -match '\[ffmpeg\]|\[ExtractAudio\]|\[EmbedThumbnail\]|\[ThumbnailsConvertor\]|\[FixupM\]') {
                    SetStatus "Post-processing with ffmpeg..."
                    if ($chkVerbose.Checked -and $s.Trim()) { Log $s }
                } 
                elseif ($s -match 'ERROR:') { Log $s "Red"; SetStatus "Error - see log" } 
                elseif ($s.Trim() -ne '') { if ($chkVerbose.Checked -and -not $s.StartsWith("[debug]", [System.StringComparison]::OrdinalIgnoreCase)) { Log $s } }
            }

            try   { $state = (Get-Job -Id $script:activeJob.Id -ErrorAction Stop).State } catch { $state = 'Completed' }
            if ($state -in @('Completed','Failed','Stopped')) {
                $script:activeTimer.Stop(); $script:activeTimer.Dispose(); $script:activeTimer = $null
                try {
                    $rem = @(Receive-Job $script:activeJob -ErrorAction SilentlyContinue)
                    foreach ($r in $rem) { 
                        $s = [string]$r
                        if ($s -match '^__EXITCODE__:(\d+)') { $script:jobExitCode = [int]$Matches[1]; continue }
                        if ($s.Trim() -ne '') { if ($s -match 'ERROR:') { Log $s "Red" } elseif ($chkVerbose.Checked -and -not $s.StartsWith("[debug]", [System.StringComparison]::OrdinalIgnoreCase)) { Log $s } } 
                    }
                } catch {}
                
                # Only a clean yt-dlp exit (code 0) counts as success - the job's
                # 'Completed' state alone is not proof (native failures still complete).
                $ok = ($state -eq 'Completed' -and $script:jobExitCode -eq 0)
                Remove-Job $script:activeJob -Force -ErrorAction SilentlyContinue; $script:activeJob = $null
                
                if ($ok) { 
                    SetProgress 100; Log "Done." "Lime"; $lblSpeed.Text = "-"; $lblEta.Text = "-"
                    $targetDir = Get-ActiveFolder
                    $latest = Get-ChildItem -Path $targetDir -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
                    if ($latest) { $script:lastDownloadedFile = $latest.FullName; $btnPlayLast.Visible = $true }
                } else { SetProgress 0; Log "Failed." "Red"; $lblSpeed.Text = "-"; $lblEta.Text = "-" }
                Set-CancelButtonState $false
                if ($script:onDoneCallback) { & $script:onDoneCallback $ok }
            }
        }
        Update-TrayTip
        } catch {
            # exceptions inside timer delegates bypass the script trap and hit
            # the .NET JIT crash dialog - log and swallow instead
            try { Write-SessionLog ("TICK ERROR: " + $_.Exception.Message); $_ | Out-File (Join-Path $ScriptDir "error.log") -Encoding UTF8 -Force } catch { }
        }
    })
    $script:activeTimer.Start()

    # auto-minimize to tray when configured and a download starts
    if ($cfg.TrayMinimize -and -not $script:inTray -and $form.Visible) { Hide-ToTray }
}

# -- SINGLE URL & BATCH PROCESSING -----------------------------------------
function Start-SingleDownload {
    $url = $txtUrl.Text.Trim()
    if (-not $url) { SetStatus "Please enter a URL."; return }
    if ($url -notmatch '^https?://') { SetStatus "URL must start with http:// or https://"; return }
    if (-not (Resolve-AskDestination)) { return }
    Add-RecentFolder $cmbFolder.Text.Trim()

    $btnDownload.Enabled = $false; $btnList.Enabled = $false; SetStatus "Starting download..."
    Start-Download $url {
        param($ok)
        $script:runFolderOverride = $null
        $btnDownload.Enabled = $true; $btnList.Enabled = ($null -ne (Get-ActiveList))
        if ($ok) {
            SetStatus "Download complete."; $txtUrl.Clear()
            Notify-Completed $true ("Saved to: " + (Get-SafeFileName $script:lastDownloadedFile))
        } else {
            SetStatus "Download failed - check the log."
            Notify-Completed $false "Check the log for details."
        }
    }
}

function Process-Next {
    if ($script:batchDone -ge $script:batchTotal -or $script:cancelRequested) {
        Log ("===  Batch finished - OK: {0}   Failed: {1}  ===" -f $script:batchOk,$script:batchFail) "Cyan"
        SetStatus "Batch complete."
        $script:runFolderOverride = $null
        Notify-Completed ($script:batchFail -eq 0) ("Batch: {0} OK, {1} failed" -f $script:batchOk, $script:batchFail)
        SetProgress 0; $btnDownload.Enabled = $true; $btnList.Enabled = ($null -ne (Get-ActiveList)); return
    }
    $url = $script:batchLinks[$script:batchDone]; $script:batchDone++
    Log ("--- [{0}/{1}]  {2}" -f $script:batchDone,$script:batchTotal,$url) "Cyan"
    SetStatus "Batch [$($script:batchDone)/$($script:batchTotal)]"

    Start-Download $url {
        param($ok)
        if ($ok) { $script:batchOk++ } else { $script:batchFail++ }
        if ($script:delayTimer) { try { $script:delayTimer.Stop(); $script:delayTimer.Dispose() } catch {}; $script:delayTimer = $null }
        $script:delayTimer = New-Object System.Windows.Forms.Timer; $script:delayTimer.Interval = 700
        $script:delayTimer.Add_Tick({ try { $script:delayTimer.Stop(); $script:delayTimer.Dispose(); $script:delayTimer = $null; Process-Next } catch { try { Write-SessionLog ("DELAY TICK ERROR: " + $_.Exception.Message); $_ | Out-File (Join-Path $ScriptDir "error.log") -Encoding UTF8 -Force } catch { } } })
        $script:delayTimer.Start()
    }
}

function Start-ListDownload {
 $targetList = Get-ActiveList
    if (-not $targetList) { [System.Windows.Forms.MessageBox]::Show("No valid list file found.","File Not Found", [System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null; return }
    $raw = @(Get-Content $targetList -Encoding UTF8 -ErrorAction SilentlyContinue | Where-Object { $_.Trim() -match '^https?://' } | ForEach-Object { $_.Trim() })
    if ($raw.Count -eq 0) { SetStatus "list.txt contains no valid URLs."; return }
    if (-not (Resolve-AskDestination)) { return }
    Add-RecentFolder $cmbFolder.Text.Trim()
    $script:batchLinks = $raw; $script:batchTotal = $raw.Count; $script:batchDone = 0; $script:batchOk = 0; $script:batchFail = 0
    $btnDownload.Enabled = $false; $btnList.Enabled = $false
    Log ("===  Batch start - {0} links  ===" -f $script:batchTotal) "Cyan"
    Process-Next
}

# -- PROFILES: HELPERS, EDITOR & MANAGER ------------------------------------
function Get-ActiveProfile {
    if ($chkQuick.Checked -or -not $cmbProfile.SelectedItem) { return $null }
    return $cfg.Profiles | Where-Object { $_.Name -eq $cmbProfile.SelectedItem.ToString() }
}

function Update-DirtyDot { $lblDirty.Visible = ($script:isDirty -and -not $chkQuick.Checked) }

function Update-ProfileSummary {
    $parts = @($cmbFormat.Text)
    if ($chkAudio.Checked) { $parts = @("$($cmbAudioFmt.Text) Audio") } else { $parts += $cmbQuality.Text }
    if ($chkSubs.Checked)  { $parts += "Subs" }
    if ($chkThumb.Checked) { $parts += "Thumb" }
    if ($chkPlaylist.Checked) { $parts += "Playlist" }
    $folder = $cmbFolder.Text.Trim(); if (-not $folder) { $folder = "Downloads (default)" }
    if ($chkQuick.Checked) { $lblProfileSummary.Text = "QUICK SESSION - not saved to any profile:  " + ($parts -join " · ") + "  →  " + $folder }
    else { $lblProfileSummary.Text = ($parts -join " · ") + "  →  " + $folder }
}

function Update-FolderState {
    $t = Get-ThemePalette $cfg.Theme
    $path = $cmbFolder.Text.Trim()
    if (-not $path) { $lblFolderState.Text = "•"; $lblFolderState.ForeColor = $t.Warn; $tooltip.SetToolTip($lblFolderState, "No folder set - will use the Downloads folder"); return }
    if (Test-Path $path) { $lblFolderState.Text = "✓"; $lblFolderState.ForeColor = $t.Success; $tooltip.SetToolTip($lblFolderState, "Folder exists") }
    else { $lblFolderState.Text = "⚠"; $lblFolderState.ForeColor = $t.Warn; $tooltip.SetToolTip($lblFolderState, "Folder does not exist yet - it will be created on download") }
}

function Add-RecentFolder($path) {
    if ([string]::IsNullOrWhiteSpace($path)) { return }
    $path = $path.Trim()
    $first = @($cfg.RecentFolders | Select-Object -First 1)
    if ($first -and $first[0] -eq $path) { return }
    $cfg.RecentFolders = @(@($path) + @($cfg.RecentFolders | Where-Object { $_ -ne $path }) | Select-Object -First 8)
    Refresh-FolderHistory
}

function Refresh-FolderHistory {
    $cur = $cmbFolder.Text
    $cmbFolder.Items.Clear()
    foreach ($f in @($cfg.RecentFolders)) { [void]$cmbFolder.Items.Add($f) }
    $script:isUpdatingUI = $true
    $cmbFolder.Text = $cur
    $script:isUpdatingUI = $false
}

function Refresh-ProfileCombo {
    $cur = $cfg.ActiveProfile
    $script:isUpdatingUI = $true
    $cmbProfile.Items.Clear()
    $cfg.Profiles | ForEach-Object { [void]$cmbProfile.Items.Add($_.Name) }
    if ($cmbProfile.Items.Contains($cur)) { $cmbProfile.SelectedItem = $cur }
    elseif ($cmbProfile.Items.Count -gt 0) { $cmbProfile.SelectedIndex = 0 }
    $script:isUpdatingUI = $false
    if ($cmbProfile.SelectedItem) { $cfg.ActiveProfile = $cmbProfile.Text; Sync-UI-To-Profile $cfg.ActiveProfile }
}

function Resolve-AskDestination {
    $p = Get-ActiveProfile
    if ($p -and $p.AskDestination) {
        $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
        $fbd.Description = "Choose the destination folder for this download"
        try { $fbd.SelectedPath = $cmbFolder.Text } catch { }
        if ($fbd.ShowDialog() -ne 'OK') { SetStatus "Download cancelled - no folder chosen."; return $false }
        $script:runFolderOverride = $fbd.SelectedPath
        Add-RecentFolder $fbd.SelectedPath
    }
    return $true
}

function Show-ProfileEditor([string]$editName) {
    $t = Get-ThemePalette $cfg.Theme
    $isEdit = -not [string]::IsNullOrEmpty($editName)
    $src = if ($isEdit) { $cfg.Profiles | Where-Object { $_.Name -eq $editName } } else { $null }

    $frm = New-Object System.Windows.Forms.Form
    $frm.Text = if ($isEdit) { "Edit Profile - $editName" } else { "New Profile" }
    $frm.Size = [System.Drawing.Size]::new(640, 640)
    $frm.StartPosition = 'CenterParent'; $frm.FormBorderStyle = 'FixedDialog'
    $frm.MaximizeBox = $false; $frm.MinimizeBox = $false
    $frm.BackColor = $t.Bg; $frm.ForeColor = $t.Text
    if (Test-Path $IconPath) { try { $frm.Icon = New-Object System.Drawing.Icon($IconPath) } catch { } }

    # -- Section 1: identity
    $gb1 = New-Object System.Windows.Forms.GroupBox
    $gb1.Text = "IDENTITY"; $gb1.Font = $fBold; $gb1.ForeColor = $t.Accent
    $gb1.Location = [System.Drawing.Point]::new(15,10); $gb1.Size = [System.Drawing.Size]::new(595,90)
    $lblName = New-Object System.Windows.Forms.Label; $lblName.Text = "Name:"; $lblName.Location = [System.Drawing.Point]::new(15,30); $lblName.AutoSize = $true; $lblName.ForeColor = $t.Text
    $txtName = New-Object System.Windows.Forms.TextBox; $txtName.Location = [System.Drawing.Point]::new(75,26); $txtName.Size = [System.Drawing.Size]::new(500,26); $txtName.BackColor = $t.Entry; $txtName.ForeColor = $t.Text
    $lblDesc = New-Object System.Windows.Forms.Label; $lblDesc.Text = "Note:"; $lblDesc.Location = [System.Drawing.Point]::new(15,62); $lblDesc.AutoSize = $true; $lblDesc.ForeColor = $t.Text
    $txtDesc = New-Object System.Windows.Forms.TextBox; $txtDesc.Location = [System.Drawing.Point]::new(75,58); $txtDesc.Size = [System.Drawing.Size]::new(500,26); $txtDesc.BackColor = $t.Entry; $txtDesc.ForeColor = $t.Text

    # -- Section 2: destination
    $gb2 = New-Object System.Windows.Forms.GroupBox
    $gb2.Text = "DESTINATION"; $gb2.Font = $fBold; $gb2.ForeColor = $t.Accent
    $gb2.Location = [System.Drawing.Point]::new(15,108); $gb2.Size = [System.Drawing.Size]::new(595,145)
    $lblFolder = New-Object System.Windows.Forms.Label; $lblFolder.Text = "Folder:"; $lblFolder.Location = [System.Drawing.Point]::new(15,30); $lblFolder.AutoSize = $true; $lblFolder.ForeColor = $t.Text
    $txtFolder = New-Object System.Windows.Forms.TextBox; $txtFolder.Location = [System.Drawing.Point]::new(75,26); $txtFolder.Size = [System.Drawing.Size]::new(400,26); $txtFolder.BackColor = $t.Entry; $txtFolder.ForeColor = $t.Text
    $btnBrowseE = New-ProButton "Browse…" 485 26 90 26
    $lblSub = New-Object System.Windows.Forms.Label; $lblSub.Text = "Subfolder:"; $lblSub.Location = [System.Drawing.Point]::new(15,62); $lblSub.AutoSize = $true; $lblSub.ForeColor = $t.Text
    $cmbSub = New-Object System.Windows.Forms.ComboBox; $cmbSub.Location = [System.Drawing.Point]::new(75,58); $cmbSub.Size = [System.Drawing.Size]::new(400,26); $cmbSub.DropDownStyle = 'DropDown'; $cmbSub.FlatStyle = 'Flat'; $cmbSub.BackColor = $t.Entry; $cmbSub.ForeColor = $t.Text
    @('', '@date  (e.g. 2026-08-22)', '@uploader  (video author)', '@playlist  (playlist name)') | ForEach-Object { [void]$cmbSub.Items.Add($_) }
    $lblSubHint = New-Object System.Windows.Forms.Label; $lblSubHint.Text = "Optional subfolder under the folder above: type a name, or use @date / @uploader / @playlist."; $lblSubHint.Location = [System.Drawing.Point]::new(15,90); $lblSubHint.Size = [System.Drawing.Size]::new(565,16); $lblSubHint.Font = $fSub; $lblSubHint.ForeColor = $t.Sub
    $chkAsk = New-Object System.Windows.Forms.CheckBox; $chkAsk.Text = "Ask me for the destination on every download"; $chkAsk.Location = [System.Drawing.Point]::new(15,112); $chkAsk.AutoSize = $true; $chkAsk.ForeColor = $t.Text

    # -- Section 3: output & extras
    $gb3 = New-Object System.Windows.Forms.GroupBox
    $gb3.Text = "OUTPUT & EXTRAS"; $gb3.Font = $fBold; $gb3.ForeColor = $t.Accent
    $gb3.Location = [System.Drawing.Point]::new(15,261); $gb3.Size = [System.Drawing.Size]::new(595,205)
    $lblFmt = New-Object System.Windows.Forms.Label; $lblFmt.Text = "Format:"; $lblFmt.Location = [System.Drawing.Point]::new(15,30); $lblFmt.AutoSize = $true; $lblFmt.ForeColor = $t.Text
    $cmbFormatE = New-Object System.Windows.Forms.ComboBox; $cmbFormatE.Location = [System.Drawing.Point]::new(75,26); $cmbFormatE.Size = [System.Drawing.Size]::new(90,26); $cmbFormatE.DropDownStyle = 'DropDownList'; $cmbFormatE.FlatStyle = 'Flat'; $cmbFormatE.BackColor = $t.Entry; $cmbFormatE.ForeColor = $t.Text
    @("mp4","mkv","webm") | ForEach-Object { [void]$cmbFormatE.Items.Add($_) }
    $lblQual = New-Object System.Windows.Forms.Label; $lblQual.Text = "Quality:"; $lblQual.Location = [System.Drawing.Point]::new(185,30); $lblQual.AutoSize = $true; $lblQual.ForeColor = $t.Text
    $cmbQualityE = New-Object System.Windows.Forms.ComboBox; $cmbQualityE.Location = [System.Drawing.Point]::new(245,26); $cmbQualityE.Size = [System.Drawing.Size]::new(100,26); $cmbQualityE.DropDownStyle = 'DropDownList'; $cmbQualityE.FlatStyle = 'Flat'; $cmbQualityE.BackColor = $t.Entry; $cmbQualityE.ForeColor = $t.Text
    @("Best","1080p","720p","480p") | ForEach-Object { [void]$cmbQualityE.Items.Add($_) }
    $chkAudioE = New-Object System.Windows.Forms.CheckBox; $chkAudioE.Text = "Audio only"; $chkAudioE.Location = [System.Drawing.Point]::new(365,28); $chkAudioE.AutoSize = $true; $chkAudioE.ForeColor = $t.Text
    $cmbAudioFmtE = New-Object System.Windows.Forms.ComboBox; $cmbAudioFmtE.Location = [System.Drawing.Point]::new(455,26); $cmbAudioFmtE.Size = [System.Drawing.Size]::new(90,26); $cmbAudioFmtE.DropDownStyle = 'DropDownList'; $cmbAudioFmtE.FlatStyle = 'Flat'; $cmbAudioFmtE.BackColor = $t.Entry; $cmbAudioFmtE.ForeColor = $t.Text
    @("mp3","m4a","opus","flac","wav") | ForEach-Object { [void]$cmbAudioFmtE.Items.Add($_) }
    $cmbAudioQualityE = New-Object System.Windows.Forms.ComboBox; $cmbAudioQualityE.Location = [System.Drawing.Point]::new(505,61); $cmbAudioQualityE.Size = [System.Drawing.Size]::new(58,26); $cmbAudioQualityE.DropDownStyle = 'DropDownList'; $cmbAudioQualityE.FlatStyle = 'Flat'; $cmbAudioQualityE.BackColor = $t.Entry; $cmbAudioQualityE.ForeColor = $t.Text
    @("Best","128","192","320") | ForEach-Object { [void]$cmbAudioQualityE.Items.Add($_) }
    $chkSubsE = New-Object System.Windows.Forms.CheckBox; $chkSubsE.Text = "Embed subs"; $chkSubsE.Location = [System.Drawing.Point]::new(15,62); $chkSubsE.AutoSize = $true; $chkSubsE.ForeColor = $t.Text
    $lblLang = New-Object System.Windows.Forms.Label; $lblLang.Text = "Lang:"; $lblLang.Location = [System.Drawing.Point]::new(110,65); $lblLang.AutoSize = $true; $lblLang.ForeColor = $t.Text
    $cmbLang = New-Object System.Windows.Forms.ComboBox; $cmbLang.Location = [System.Drawing.Point]::new(150,61); $cmbLang.Size = [System.Drawing.Size]::new(90,26); $cmbLang.DropDownStyle = 'DropDown'; $cmbLang.FlatStyle = 'Flat'; $cmbLang.BackColor = $t.Entry; $cmbLang.ForeColor = $t.Text
    @("en","el","en,el","es","fr","de","it","pt","ru","ar","all") | ForEach-Object { [void]$cmbLang.Items.Add($_) }
    $chkThumbE = New-Object System.Windows.Forms.CheckBox; $chkThumbE.Text = "Embed thumb"; $chkThumbE.Location = [System.Drawing.Point]::new(260,62); $chkThumbE.AutoSize = $true; $chkThumbE.ForeColor = $t.Text
    $chkPlaylistE = New-Object System.Windows.Forms.CheckBox; $chkPlaylistE.Text = "Playlist/Channel"; $chkPlaylistE.Location = [System.Drawing.Point]::new(380,62); $chkPlaylistE.AutoSize = $true; $chkPlaylistE.ForeColor = $t.Text
    $lblItems = New-Object System.Windows.Forms.Label; $lblItems.Text = "Items:"; $lblItems.Location = [System.Drawing.Point]::new(15,96); $lblItems.AutoSize = $true; $lblItems.ForeColor = $t.Text
    $txtItems = New-Object System.Windows.Forms.TextBox; $txtItems.Location = [System.Drawing.Point]::new(75,92); $txtItems.Size = [System.Drawing.Size]::new(110,26); $txtItems.BackColor = $t.Entry; $txtItems.ForeColor = $t.Text
    $lblRate = New-Object System.Windows.Forms.Label; $lblRate.Text = "Rate:"; $lblRate.Location = [System.Drawing.Point]::new(200,96); $lblRate.AutoSize = $true; $lblRate.ForeColor = $t.Text
    $txtRate = New-Object System.Windows.Forms.TextBox; $txtRate.Location = [System.Drawing.Point]::new(245,92); $txtRate.Size = [System.Drawing.Size]::new(80,26); $txtRate.BackColor = $t.Entry; $txtRate.ForeColor = $t.Text
    $lblCookies = New-Object System.Windows.Forms.Label; $lblCookies.Text = "Cookies:"; $lblCookies.Location = [System.Drawing.Point]::new(340,96); $lblCookies.AutoSize = $true; $lblCookies.ForeColor = $t.Text
    $txtCookies = New-Object System.Windows.Forms.TextBox; $txtCookies.Location = [System.Drawing.Point]::new(400,92); $txtCookies.Size = [System.Drawing.Size]::new(175,26); $txtCookies.BackColor = $t.Entry; $txtCookies.ForeColor = $t.Text
    $lblTpl = New-Object System.Windows.Forms.Label; $lblTpl.Text = "File name template:"; $lblTpl.Location = [System.Drawing.Point]::new(15,128); $lblTpl.AutoSize = $true; $lblTpl.ForeColor = $t.Text
    $txtTpl = New-Object System.Windows.Forms.TextBox; $txtTpl.Location = [System.Drawing.Point]::new(130,124); $txtTpl.Size = [System.Drawing.Size]::new(445,26); $txtTpl.BackColor = $t.Entry; $txtTpl.ForeColor = $t.Text
    $lblTplHint = New-Object System.Windows.Forms.Label; $lblTplHint.Text = "Leave empty for the default %(title)s.%(ext)s. Example: %(uploader)s - %(title)s.%(ext)s"; $lblTplHint.Location = [System.Drawing.Point]::new(15,155); $lblTplHint.Size = [System.Drawing.Size]::new(565,16); $lblTplHint.Font = $fSub; $lblTplHint.ForeColor = $t.Sub
    $chkVerboseE = New-Object System.Windows.Forms.CheckBox; $chkVerboseE.Text = "Verbose log"; $chkVerboseE.Location = [System.Drawing.Point]::new(15,177); $chkVerboseE.AutoSize = $true; $chkVerboseE.ForeColor = $t.Text

    $btnOK = New-Object System.Windows.Forms.Button
    $btnOK.Text = if ($isEdit) { "Save Changes" } else { "Create Profile" }
    $btnOK.Location = [System.Drawing.Point]::new(210, 480); $btnOK.Size = [System.Drawing.Size]::new(110, 32)
    $btnOK.FlatStyle = 'Flat'; $btnOK.FlatAppearance.BorderSize = 0
    Style-Button $btnOK $t.Success (HexToCol "#ffffff") $t.IsDark
    $btnCancelE = New-Object System.Windows.Forms.Button
    $btnCancelE.Text = "Cancel"; $btnCancelE.Location = [System.Drawing.Point]::new(330, 480); $btnCancelE.Size = [System.Drawing.Size]::new(90, 32)
    $btnCancelE.FlatStyle = 'Flat'; $btnCancelE.FlatAppearance.BorderSize = 0
    Style-Button $btnCancelE $t.BtnGray $t.Text $t.IsDark
    $btnCancelE.DialogResult = 'Cancel'
    $frm.AcceptButton = $btnOK; $frm.CancelButton = $btnCancelE

    $gb1.Controls.AddRange(@($lblName,$txtName,$lblDesc,$txtDesc))
    $gb2.Controls.AddRange(@($lblFolder,$txtFolder,$btnBrowseE,$lblSub,$cmbSub,$lblSubHint,$chkAsk))
    $gb3.Controls.AddRange(@($lblFmt,$cmbFormatE,$lblQual,$cmbQualityE,$chkAudioE,$cmbAudioFmtE,$chkSubsE,$lblLang,$cmbLang,$chkThumbE,$chkPlaylistE,$cmbAudioQualityE,$lblItems,$txtItems,$lblRate,$txtRate,$lblCookies,$txtCookies,$lblTpl,$txtTpl,$lblTplHint,$chkVerboseE))
    $frm.Controls.AddRange(@($gb1, $gb2, $gb3, $btnOK, $btnCancelE))

    # -- prefill
    $ed = @{ Name=""; Description=""; Format="mp4"; Quality="Best"; AudioOnly=$false; AudioFormat="mp3"; AudioQuality="Best"; Subs=$false; SubLang="en"; Thumb=$false; Playlist=$false; PlaylistRange=""; Verbose=$true; Folder=$DownloadFolder; Subfolder=""; AskDestination=$false; FilenameTemplate=""; RateLimit=""; CookiesFile="" }
    if ($src) {
        foreach ($k in @($ed.Keys)) { if ($null -ne $src.$k) { $ed[$k] = $src.$k } }
        if ([string]::IsNullOrWhiteSpace($ed.SubLang)) { $ed.SubLang = "en" }
    } else {
        # new profile: capture what the user currently sees in the main window
        $ed.Format = $cmbFormat.Text; $ed.Quality = $cmbQuality.Text; $ed.AudioOnly = $chkAudio.Checked
        $ed.Subs = $chkSubs.Checked; $ed.Thumb = $chkThumb.Checked; $ed.Playlist = $chkPlaylist.Checked
        $ed.Verbose = $chkVerbose.Checked; $ed.Folder = $cmbFolder.Text.Trim()
        $ap = Get-ActiveProfile
        if ($ap) { $ed.SubLang = $ap.SubLang; $ed.AudioFormat = $ap.AudioFormat; $ed.AudioQuality = $ap.AudioQuality; $ed.Subfolder = $ap.Subfolder; $ed.FilenameTemplate = $ap.FilenameTemplate; $ed.RateLimit = $ap.RateLimit; $ed.CookiesFile = $ap.CookiesFile; $ed.PlaylistRange = $ap.PlaylistRange }
    }
    $txtName.Text = $ed.Name; $txtDesc.Text = $ed.Description
    $txtFolder.Text = $ed.Folder
    $cmbSub.Text = $ed.Subfolder
    $chkAsk.Checked = $ed.AskDestination
    $fI = $cmbFormatE.Items.IndexOf($ed.Format); if ($fI -ge 0) { $cmbFormatE.SelectedIndex = $fI }
    $qI = $cmbQualityE.Items.IndexOf($ed.Quality); if ($qI -ge 0) { $cmbQualityE.SelectedIndex = $qI }
    $chkAudioE.Checked = $ed.AudioOnly
    $aF = $cmbAudioFmtE.Items.IndexOf($ed.AudioFormat); if ($aF -ge 0) { $cmbAudioFmtE.SelectedIndex = $aF } else { $cmbAudioFmtE.SelectedIndex = 0 }
    $aqF = $cmbAudioQualityE.Items.IndexOf($ed.AudioQuality); if ($aqF -ge 0) { $cmbAudioQualityE.SelectedIndex = $aqF } else { $cmbAudioQualityE.SelectedIndex = 0 }
    Update-EditorAudioState
    $chkSubsE.Checked = $ed.Subs; $cmbLang.Text = $ed.SubLang
    $chkThumbE.Checked = $ed.Thumb; $chkPlaylistE.Checked = $ed.Playlist
    $txtItems.Text = $ed.PlaylistRange; $txtRate.Text = $ed.RateLimit; $txtCookies.Text = $ed.CookiesFile
    $txtTpl.Text = $ed.FilenameTemplate; $chkVerboseE.Checked = $ed.Verbose

    # -- editor wiring
    $tooltip.SetToolTip($txtItems, "Playlist items to download, e.g. 1-10 or 3,5,8-12 (only when playlist is on)")
    $tooltip.SetToolTip($txtRate,  "Download speed limit, e.g. 5M (5 MB/s) - leave empty for no limit")
    $tooltip.SetToolTip($txtCookies,"Path to a cookies.txt file for age-restricted / login-only videos")
    $tooltip.SetToolTip($txtTpl,   "yt-dlp output template; default is %(title)s.%(ext)s")
    $tooltip.SetToolTip($cmbSub,  "Optional subfolder under the destination folder")
    $tooltip.SetToolTip($chkAsk,  "Prompt for the destination folder before every download")
    $tooltip.SetToolTip($cmbLang, "Subtitle language code(s), e.g. en, el or en,el")
    $tooltip.SetToolTip($cmbAudioFmtE, "Audio format for audio-only downloads")
    $tooltip.SetToolTip($chkVerboseE, "Show the full yt-dlp output in the log")
    function Update-EditorAudioState {
        $isAudio = $chkAudioE.Checked
        $cmbAudioFmtE.Enabled = $isAudio
        $cmbAudioQualityE.Enabled = $isAudio
        $cmbFormatE.Enabled   = (-not $isAudio)
        $cmbQualityE.Enabled  = (-not $isAudio)
    }
    $chkAudioE.Add_CheckedChanged({ Update-EditorAudioState })
    $btnBrowseE.Add_Click({
        $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
        $fbd.Description = "Select destination folder"
        try { $fbd.SelectedPath = $txtFolder.Text } catch { }
        if ($fbd.ShowDialog() -eq 'OK') { $txtFolder.Text = $fbd.SelectedPath }
    })

    $script:editorResult = $null
    $btnOK.Add_Click({
        $name = $txtName.Text.Trim()
        if (-not $name) { [System.Windows.Forms.MessageBox]::Show("Please give the profile a name.","Name required",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null; return }
        if ($cfg.Profiles | Where-Object { $_.Name -eq $name -and $_.Name -ne $editName }) {
            [System.Windows.Forms.MessageBox]::Show("A profile named '$name' already exists.","Duplicate name",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null; return
        }
        $lang = $cmbLang.Text.Trim(); if (-not $lang) { $lang = "en" }
        $script:editorResult = [PSCustomObject]@{
            Name = $name; Description = $txtDesc.Text.Trim()
            Format = $cmbFormatE.Text; Quality = $cmbQualityE.Text; AudioOnly = $chkAudioE.Checked; AudioFormat = $cmbAudioFmtE.Text; AudioQuality = $cmbAudioQualityE.Text
            Subs = $chkSubsE.Checked; SubLang = $lang
            Thumb = $chkThumbE.Checked; Playlist = $chkPlaylistE.Checked; PlaylistRange = $txtItems.Text.Trim()
            Verbose = $chkVerboseE.Checked; Folder = $txtFolder.Text.Trim()
            Subfolder = ($cmbSub.Text -replace '\s*\(.*$','').Trim()
            AskDestination = $chkAsk.Checked
            FilenameTemplate = $txtTpl.Text.Trim(); RateLimit = $txtRate.Text.Trim(); CookiesFile = $txtCookies.Text.Trim()
            Created = (Get-Date -Format "yyyy-MM-dd"); LastUsed = $null
        }
        $frm.Close()
    })
    [void]$frm.ShowDialog()
    return $script:editorResult
}

function Show-ProfileManager {
    $t = Get-ThemePalette $cfg.Theme
    $frm = New-Object System.Windows.Forms.Form
    $script:managerForm = $frm
    $frm.Text = "Manage Profiles"
    $frm.Size = [System.Drawing.Size]::new(780, 560)
    $frm.StartPosition = 'CenterParent'; $frm.FormBorderStyle = 'FixedDialog'
    $frm.MaximizeBox = $false; $frm.MinimizeBox = $false
    $frm.BackColor = $t.Bg; $frm.ForeColor = $t.Text
    if (Test-Path $IconPath) { try { $frm.Icon = New-Object System.Drawing.Icon($IconPath) } catch { } }

    $lblHint = New-Object System.Windows.Forms.Label
    $lblHint.Text = "★ = default profile   ·   bold = active profile   ·   double-click a row to edit"
    $lblHint.Location = [System.Drawing.Point]::new(15, 8); $lblHint.AutoSize = $true; $lblHint.Font = $fSub; $lblHint.ForeColor = $t.Sub

    $lv = New-Object System.Windows.Forms.ListView
    $lv.Location = [System.Drawing.Point]::new(15,28); $lv.Size = [System.Drawing.Size]::new(735,320)
    $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.GridLines = $false; $lv.BorderStyle = 'FixedSingle'
    $lv.BackColor = $t.Entry; $lv.ForeColor = $t.Text
    [void]$lv.Columns.Add("Name", 160)
    [void]$lv.Columns.Add("Format", 70)
    [void]$lv.Columns.Add("Quality", 70)
    [void]$lv.Columns.Add("Audio", 55)
    [void]$lv.Columns.Add("Subs", 50)
    [void]$lv.Columns.Add("Thumb", 60)
    [void]$lv.Columns.Add("Playlist", 65)
    [void]$lv.Columns.Add("Destination", 200)

    $btnNew    = New-ProButton "＋ New…"      15 360 90 30
    $btnEdit   = New-ProButton "✎ Edit"      115 360 80 30
    $btnRename = New-ProButton "Rename"      205 360 85 30
    $btnDup    = New-ProButton "Duplicate"   300 360 95 30
    $btnDel    = New-ProButton "Delete"      405 360 85 30
    $btnSetDef = New-ProButton "Set default" 500 360 110 30
    $btnClose  = New-ProButton "Close"       660 360 90 30
    $btnUp     = New-ProButton "↑ Move up"   15 400 90 30
    $btnDown   = New-ProButton "↓ Move down" 115 400 105 30
    $btnExport = New-ProButton "Export…"     230 400 90 30
    $btnExpAll = New-ProButton "Export all"  330 400 100 30
    $btnImport = New-ProButton "Import…"     440 400 90 30
    $btnTrash  = New-ProButton "Trash…"      540 400 90 30

    $frm.Controls.AddRange(@($lblHint, $lv, $btnNew, $btnEdit, $btnRename, $btnDup, $btnDel, $btnSetDef, $btnClose, $btnUp, $btnDown, $btnExport, $btnExpAll, $btnImport, $btnTrash))
    foreach ($b in @($btnNew,$btnEdit,$btnRename,$btnDup,$btnSetDef,$btnUp,$btnDown,$btnExport,$btnExpAll,$btnImport)) { Style-Button $b $t.BtnGray $t.Text $t.IsDark }
    Style-Button $btnDel   $t.Danger (HexToCol "#ffffff") $t.IsDark
    Style-Button $btnTrash $t.Warn   $t.Text    $t.IsDark
    Style-Button $btnClose $t.Accent (HexToCol "#ffffff") $t.IsDark
    $frm.CancelButton = $btnClose
    $tooltip.SetToolTip($btnNew,    "Create a new profile from the current settings")
    $tooltip.SetToolTip($btnEdit,   "Edit the selected profile (or double-click a row)")
    $tooltip.SetToolTip($btnRename, "Rename the selected profile")
    $tooltip.SetToolTip($btnDup,    "Duplicate the selected profile as a starting point")
    $tooltip.SetToolTip($btnDel,    "Delete - kept in the Trash, restorable")
    $tooltip.SetToolTip($btnSetDef, "Mark as the default profile (★)")
    $tooltip.SetToolTip($btnUp,     "Move the selected profile up")
    $tooltip.SetToolTip($btnDown,   "Move the selected profile down")
    $tooltip.SetToolTip($btnExport, "Save the selected profile as a JSON file")
    $tooltip.SetToolTip($btnExpAll, "Save all profiles as one JSON file")
    $tooltip.SetToolTip($btnImport, "Import profiles from JSON files")
    $tooltip.SetToolTip($btnTrash,  "Restore or permanently delete trashed profiles")
    $tooltip.SetToolTip($btnClose,  "Close the manager (changes are saved)")

    function Refresh-ManagerList {
        $lv.BeginUpdate(); $lv.Items.Clear()
        foreach ($p in $cfg.Profiles) {
            $isDef = ($p.Name -eq $cfg.DefaultProfile)
            $isAct = ($p.Name -eq $cfg.ActiveProfile)
            $item = New-Object System.Windows.Forms.ListViewItem(($(if ($isDef) { "★ " } else { "" }) + $p.Name))
            if ($isAct) { $item.Font = $fBold }
            [void]$item.SubItems.Add($p.Format)
            [void]$item.SubItems.Add($(if ($p.AudioOnly) { "Audio" } else { $p.Quality }))
            [void]$item.SubItems.Add($(if ($p.AudioOnly) { "Yes" } else { "No" }))
            [void]$item.SubItems.Add($(if ($p.Subs) { "Yes" } else { "No" }))
            [void]$item.SubItems.Add($(if ($p.Thumb) { "Yes" } else { "No" }))
            [void]$item.SubItems.Add($(if ($p.Playlist) { "Yes" } else { "No" }))
            [void]$item.SubItems.Add($p.Folder)
            [void]$lv.Items.Add($item)
        }
        $lv.EndUpdate()
    }
    function Get-SelectedProfile {
        if ($lv.SelectedItems.Count -eq 0) { return $null }
        $n = $lv.SelectedItems[0].Text -replace '^★\s*',''
        return $cfg.Profiles | Where-Object { $_.Name -eq $n }
    }
    function Move-ManagerItem($dir) {
        if ($lv.SelectedIndices.Count -eq 0) { return }
        $idx = $lv.SelectedIndices[0]; $newIdx = $idx + $dir
        if ($newIdx -lt 0 -or $newIdx -ge $cfg.Profiles.Count) { return }
        $tmp = $cfg.Profiles[$idx]; $cfg.Profiles[$idx] = $cfg.Profiles[$newIdx]; $cfg.Profiles[$newIdx] = $tmp
        Refresh-ManagerList
        if ($newIdx -lt $lv.Items.Count) { $lv.Items[$newIdx].Selected = $true; $lv.Items[$newIdx].Focused = $true }
    }

    $btnNew.Add_Click({
        $newProf = Show-ProfileEditor $null
        if ($newProf) {
            $cfg.Profiles += $newProf
            $cfg.ActiveProfile = $newProf.Name
            Refresh-ManagerList
            Log ("Profile '{0}' created ({1}, {2} → {3})" -f $newProf.Name, $newProf.Format, $(if ($newProf.AudioOnly) { "Audio" } else { $newProf.Quality }), $newProf.Folder) "Lime"
        }
    })
    $btnEdit.Add_Click({
        $p = Get-SelectedProfile
        if (-not $p) { return }
        $edited = Show-ProfileEditor $p.Name
        if ($edited) {
            $names = @($cfg.Profiles | ForEach-Object { $_.Name })
            $idx = [Array]::IndexOf($names, $p.Name)
            if ($idx -ge 0) {
                $cfg.Profiles[$idx] = $edited
                if ($cfg.ActiveProfile -eq $p.Name) { $cfg.ActiveProfile = $edited.Name }
                if ($cfg.DefaultProfile -eq $p.Name) { $cfg.DefaultProfile = $edited.Name }
            }
            Refresh-ManagerList
            Log "Profile updated: $($edited.Name)" "Lime"
        }
    })
    $btnRename.Add_Click({
        $p = Get-SelectedProfile
        if (-not $p) { return }
        $newName = Get-SafeInputBox "Rename Profile" "New name for '$($p.Name)':"
        if ($newName -and $newName -ne $p.Name) {
            if ($cfg.Profiles | Where-Object { $_.Name -eq $newName }) {
                [System.Windows.Forms.MessageBox]::Show("A profile named '$newName' already exists.","Duplicate name",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            } else {
                $old = $p.Name
                $p.Name = $newName
                if ($cfg.ActiveProfile -eq $old)  { $cfg.ActiveProfile = $newName }
                if ($cfg.DefaultProfile -eq $old) { $cfg.DefaultProfile = $newName }
                Refresh-ManagerList
                Log "Renamed profile: $old → $newName" "Cyan"
            }
        }
    })
    $btnDup.Add_Click({
        $p = Get-SelectedProfile
        if (-not $p) { return }
        $copy = $p.PSObject.Copy()
        $base = $p.Name + " copy"; $newName = $base; $n = 2
        while ($cfg.Profiles | Where-Object { $_.Name -eq $newName }) { $newName = "$base $n"; $n++ }
        $copy.Name = $newName; $copy.Created = (Get-Date -Format "yyyy-MM-dd")
        $cfg.Profiles += $copy
        Refresh-ManagerList
        Log "Duplicated profile: $($p.Name) → $newName" "Cyan"
    })
    $btnDel.Add_Click({
        $p = Get-SelectedProfile
        if (-not $p) { return }
        if ($cfg.Profiles.Count -le 1) { [System.Windows.Forms.MessageBox]::Show("Cannot delete the last remaining profile.","Protected",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null; return }
        if ([System.Windows.Forms.MessageBox]::Show("Delete profile '$($p.Name)'?`nIt will be kept in the Trash and can be restored.","Confirm Delete",[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Question) -eq 'Yes') {
            $cfg.Profiles = @($cfg.Profiles | Where-Object { $_.Name -ne $p.Name })
            $p.DeletedAt = Get-Date -Format "yyyy-MM-dd HH:mm"
            $cfg.Trash = @(@($p) + @($cfg.Trash) | Select-Object -First 5)
            if ($cfg.ActiveProfile -eq $p.Name) { $cfg.ActiveProfile = $cfg.Profiles[0].Name }
            if ($cfg.DefaultProfile -eq $p.Name) { $cfg.DefaultProfile = $cfg.Profiles[0].Name }
            Refresh-ManagerList
            Log "Deleted profile: $($p.Name) (kept in trash)" "Yellow"
        }
    })
    $btnSetDef.Add_Click({
        $p = Get-SelectedProfile
        if (-not $p) { return }
        $cfg.DefaultProfile = $p.Name
        Refresh-ManagerList
        Log "Default profile set to: $($p.Name)" "Cyan"
    })
    $btnUp.Add_Click({ Move-ManagerItem -1 }); $btnDown.Add_Click({ Move-ManagerItem 1 })
    $btnClose.Add_Click({ $frm.Close() })
    $btnExport.Add_Click({
        $p = Get-SelectedProfile
        if (-not $p) { return }
        $sfd = New-Object System.Windows.Forms.SaveFileDialog
        $sfd.Filter = "Profile JSON (*.json)|*.json"
        $sfd.FileName = $p.Name + ".json"
        if ($sfd.ShowDialog() -eq 'OK') {
            try {
                $p | ConvertTo-Json -Depth 4 | Set-Content $sfd.FileName -Encoding UTF8 -Force
                [System.Windows.Forms.MessageBox]::Show("Profile exported to:`n$($sfd.FileName)","Export OK",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
            } catch { [System.Windows.Forms.MessageBox]::Show("Export failed: $($_.Exception.Message)","Export Error",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null }
        }
    })
    $btnExpAll.Add_Click({
        $sfd = New-Object System.Windows.Forms.SaveFileDialog
        $sfd.Filter = "Profile JSON (*.json)|*.json"; $sfd.FileName = "profiles.json"
        if ($sfd.ShowDialog() -eq 'OK') {
            try {
                @{ Profiles = @($cfg.Profiles) } | ConvertTo-Json -Depth 4 | Set-Content $sfd.FileName -Encoding UTF8 -Force
                [System.Windows.Forms.MessageBox]::Show("All $($cfg.Profiles.Count) profiles exported to:`n$($sfd.FileName)","Export OK",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
            } catch { [System.Windows.Forms.MessageBox]::Show("Export failed: $($_.Exception.Message)","Export Error",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null }
        }
    })
    $btnImport.Add_Click({
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter = "Profile JSON (*.json)|*.json"; $ofd.Multiselect = $true
        if ($ofd.ShowDialog() -eq 'OK') {
            $imported = 0; $skipped = 0
            foreach ($f in $ofd.FileNames) {
                try {
                    $j = Get-Content $f -Raw | ConvertFrom-Json
                    $arr = if ($null -ne $j.Profiles) { @($j.Profiles) } else { @($j) }
                    foreach ($p in $arr) {
                        $p = Normalize-Profile $p
                        if (-not $p.Name) { $skipped++; continue }
                        if ($cfg.Profiles | Where-Object { $_.Name -eq $p.Name }) {
                            if ([System.Windows.Forms.MessageBox]::Show("A profile named '$($p.Name)' already exists. Overwrite it?","Import conflict",[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Question) -ne 'Yes') { $skipped++; continue }
                            $names = @($cfg.Profiles | ForEach-Object { $_.Name })
                            $idx = [Array]::IndexOf($names, $p.Name)
                            if ($idx -ge 0) { $cfg.Profiles[$idx] = $p }
                        } else { $cfg.Profiles += $p }
                        $imported++
                    }
                } catch { $skipped++ }
            }
            Refresh-ManagerList
            Log "Import finished: $imported imported, $skipped skipped." "Cyan"
        }
    })
    $btnTrash.Add_Click({
        if (@($cfg.Trash).Count -eq 0) { [System.Windows.Forms.MessageBox]::Show("The trash is empty. Deleted profiles are kept here (last 5) and can be restored.","Trash",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null; return }
        $tfrm = New-Object System.Windows.Forms.Form
        $tfrm.Text = "Trash - deleted profiles"; $tfrm.Size = [System.Drawing.Size]::new(500, 360)
        $tfrm.StartPosition = 'CenterParent'; $tfrm.FormBorderStyle = 'FixedDialog'
        $tfrm.MaximizeBox = $false; $tfrm.MinimizeBox = $false
        $tfrm.BackColor = $t.Bg; $tfrm.ForeColor = $t.Text
        if (Test-Path $IconPath) { try { $tfrm.Icon = New-Object System.Drawing.Icon($IconPath) } catch { } }
        $lst = New-Object System.Windows.Forms.ListBox
        $lst.Location = [System.Drawing.Point]::new(15,15); $lst.Size = [System.Drawing.Size]::new(455,210)
        $lst.BackColor = $t.Entry; $lst.ForeColor = $t.Text
        foreach ($tp in @($cfg.Trash)) { [void]$lst.Items.Add("$($tp.Name)   (deleted $($tp.DeletedAt))") }
        $btnRestore = New-ProButton "Restore"       15 240 90 30
        $btnPurge   = New-ProButton "Delete forever" 115 240 130 30
        $btnCloseT  = New-ProButton "Close"         255 240 80 30
        Style-Button $btnRestore $t.Success (HexToCol "#ffffff") $t.IsDark
        Style-Button $btnPurge   $t.Danger  (HexToCol "#ffffff") $t.IsDark
        Style-Button $btnCloseT  $t.BtnGray $t.Text $t.IsDark
        $tooltip.SetToolTip($btnRestore, "Move the selected profile back into the list")
        $tooltip.SetToolTip($btnPurge,   "Permanently delete - cannot be undone")
        $tooltip.SetToolTip($btnCloseT,  "Close the trash")
        $tfrm.Controls.AddRange(@($lst, $btnRestore, $btnPurge, $btnCloseT))
        $btnRestore.Add_Click({
            if ($lst.SelectedIndex -lt 0) { return }
            $tp = @($cfg.Trash)[$lst.SelectedIndex]
            if ($cfg.Profiles | Where-Object { $_.Name -eq $tp.Name }) { $tp.Name = $tp.Name + " (restored)" }
            $cfg.Profiles += $tp
            $cfg.Trash = @($cfg.Trash | Where-Object { $_ -ne $tp })
            [void]$tfrm.Close()
            Refresh-ManagerList
            Log "Profile restored from trash: $($tp.Name)" "Lime"
        })
        $btnPurge.Add_Click({
            if ($lst.SelectedIndex -lt 0) { return }
            if ([System.Windows.Forms.MessageBox]::Show("Permanently delete '$(@($cfg.Trash)[$lst.SelectedIndex].Name)'? This cannot be undone.","Delete forever",[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Warning) -eq 'Yes') {
                $tp = @($cfg.Trash)[$lst.SelectedIndex]
                $cfg.Trash = @($cfg.Trash | Where-Object { $_ -ne $tp })
                $lst.Items.RemoveAt($lst.SelectedIndex)
                Log "Profile permanently deleted: $($tp.Name)" "Yellow"
            }
        })
        $btnCloseT.Add_Click({ $tfrm.Close() })
        $tfrm.CancelButton = $btnCloseT
        [void]$tfrm.ShowDialog()
    })

    $lv.Add_DoubleClick({ if ($lv.SelectedItems.Count) { $btnEdit.PerformClick() } })
    $frm.Add_FormClosed({ Refresh-ProfileCombo; Save-Settings $form $cfg; $script:managerForm = $null })
    Refresh-ManagerList
    [void]$frm.ShowDialog()
}

# -- EVENT WIRING (PROFILES & UI) ------------------------------------------
function Sync-UI-To-Profile($profName) {
    $script:isUpdatingUI = $true
    $p = $cfg.Profiles | Where-Object { $_.Name -eq $profName }
    if ($p) {
        $fIdx = $cmbFormat.Items.IndexOf($p.Format); if ($fIdx -ge 0) { $cmbFormat.SelectedIndex = $fIdx }
        $qIdx = $cmbQuality.Items.IndexOf($p.Quality); if ($qIdx -ge 0) { $cmbQuality.SelectedIndex = $qIdx }
        $chkAudio.Checked = $p.AudioOnly
        $chkPlaylist.Checked = if ($null -ne $p.Playlist) { $p.Playlist } else { $false }
        $chkVerbose.Checked  = if ($null -ne $p.Verbose) { $p.Verbose } else { $true }
        
        if ($script:ffmpeg) {
            $chkSubs.Checked  = if ($null -ne $p.Subs) { $p.Subs } else { $false }
            $chkThumb.Checked = if ($null -ne $p.Thumb) { $p.Thumb } else { $false }
        }
        
        $cmbFolder.Text = $p.Folder
        $afIdx = $cmbAudioFmt.Items.IndexOf($p.AudioFormat); if ($afIdx -ge 0) { $cmbAudioFmt.SelectedIndex = $afIdx } else { $cmbAudioFmt.SelectedIndex = 0 }
        $aqIdx = $cmbAudioQuality.Items.IndexOf($p.AudioQuality); if ($aqIdx -ge 0) { $cmbAudioQuality.SelectedIndex = $aqIdx } else { $cmbAudioQuality.SelectedIndex = 0 }
        Update-AudioUIState
    }
    $script:isUpdatingUI = $false
    $script:isDirty = $false
    Update-DirtyDot
    Update-ProfileSummary
    Update-FolderState
}

$updateProfileAction = {
    try {
        if (-not $script:isUpdatingUI -and -not $chkQuick.Checked -and $cmbProfile.SelectedItem) {
            $p = $cfg.Profiles | Where-Object { $_.Name -eq $cmbProfile.SelectedItem.ToString() }
            if ($p) {
                $p.Format = $cmbFormat.Text; $p.Quality = $cmbQuality.Text; $p.AudioOnly = $chkAudio.Checked
                $p.AudioFormat = $cmbAudioFmt.Text; $p.AudioQuality = $cmbAudioQuality.Text
                $p.Subs = $chkSubs.Checked; $p.Thumb = $chkThumb.Checked; $p.Playlist = $chkPlaylist.Checked
                $p.Verbose = $chkVerbose.Checked; $p.Folder = $cmbFolder.Text.Trim()
                $script:isDirty = $true; Update-DirtyDot
            }
        }
        Update-ProfileSummary
        Update-FolderState
    } catch {
        try { Write-SessionLog ("PROFILE ACTION ERROR: " + $_.Exception.Message); $_ | Out-File (Join-Path $ScriptDir "error.log") -Encoding UTF8 -Force } catch { }
    }
}

Refresh-ProfileCombo
Refresh-FolderHistory

$cmbProfile.Add_SelectedIndexChanged({ if (-not $script:isUpdatingUI) { $cfg.ActiveProfile = $cmbProfile.Text; Sync-UI-To-Profile $cfg.ActiveProfile } })

$chkQuick.Add_CheckedChanged({
    $cmbProfile.Enabled = (-not $chkQuick.Checked)
    if ($chkQuick.Checked) { $script:isDirty = $false }
    Update-DirtyDot; Update-ProfileSummary
})
$cmbFolder.Add_TextChanged({ & $updateProfileAction })
$cmbFolder.Add_KeyDown({ if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Enter) { Add-RecentFolder $cmbFolder.Text.Trim(); $_.SuppressKeyPress = $true } })
$cmbFolder.Add_SelectedIndexChanged({ if (-not $script:isUpdatingUI) { Add-RecentFolder $cmbFolder.Text.Trim(); & $updateProfileAction } })

$btnNewProf.Add_Click({
    $newProf = Show-ProfileEditor $null
    if ($newProf) {
        $cfg.Profiles += $newProf
        $script:isUpdatingUI = $true; [void]$cmbProfile.Items.Add($newProf.Name)
        $cmbProfile.SelectedItem = $newProf.Name; $script:isUpdatingUI = $false
        $cfg.ActiveProfile = $newProf.Name
        Sync-UI-To-Profile $cfg.ActiveProfile
        Log ("Profile '{0}' created ({1}, {2}{3} → {4})" -f $newProf.Name, $newProf.Format, $(if ($newProf.AudioOnly) { "Audio" } else { $newProf.Quality }), $(if ($newProf.Subfolder) { ", sub: " + $newProf.Subfolder } else { "" }), $newProf.Folder) "Lime"
    }
})
$btnEditProf.Add_Click({
    $curName = $cmbProfile.Text
    $edited = Show-ProfileEditor $curName
    if ($edited) {
        $idx = $cmbProfile.Items.IndexOf($curName)
        if ($idx -ge 0) { $cmbProfile.Items[$idx] = $edited.Name }
        $cfg.ActiveProfile = $edited.Name
        $script:isUpdatingUI = $true; $cmbProfile.SelectedItem = $edited.Name; $script:isUpdatingUI = $false
        Sync-UI-To-Profile $edited.Name
        Log "Profile updated: $($edited.Name)" "Lime"
    }
})
$btnManageProf.Add_Click({ Show-ProfileManager })
$btnBrowse.Add_Click({
    $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
    $fbd.Description = "Select destination folder for this profile"
    try { $fbd.SelectedPath = $cmbFolder.Text } catch { }
    if ($fbd.ShowDialog() -eq 'OK') { $cmbFolder.Text = $fbd.SelectedPath; Add-RecentFolder $fbd.SelectedPath; & $updateProfileAction }
})
$btnOpenDest.Add_Click({ $targetDir = Get-ActiveFolder; if (Test-Path $targetDir) { Start-Process $targetDir } })

$cmbFormat.Add_SelectedIndexChanged($updateProfileAction)
$cmbQuality.Add_SelectedIndexChanged($updateProfileAction)
$chkAudio.Add_CheckedChanged({ Update-AudioUIState; & $updateProfileAction })
$chkSubs.Add_CheckedChanged($updateProfileAction); $chkThumb.Add_CheckedChanged($updateProfileAction)
$chkPlaylist.Add_CheckedChanged($updateProfileAction); $chkVerbose.Add_CheckedChanged($updateProfileAction)

# -- UTILITY WIRING --------------------------------------------------------
$btnClear.Add_Click({ $txtUrl.Clear(); $txtUrl.Focus() })
$btnDownload.Add_Click({ Start-SingleDownload })
$btnList.Add_Click({ Start-ListDownload })

$btnFolder.Add_Click({ $targetDir = Get-ActiveFolder; if (Test-Path $targetDir) { Start-Process $targetDir } })
$btnPlayLast.Add_Click({
    if ($script:lastDownloadedFile -and (Test-Path -LiteralPath $script:lastDownloadedFile)) { Start-Process $script:lastDownloadedFile } 
    else { SetStatus "File not found."; $btnPlayLast.Visible = $false }
})
$btnOpenList.Add_Click({
    $target = Get-ActiveList; if (-not $target) { $target = Join-Path $ScriptDir "list.txt"; Set-Content $target -Value "" -Encoding UTF8 }
    Start-Process "notepad.exe" $target; $btnList.Enabled = $true
})
$btnCancel.Add_Click({
    $script:cancelRequested = $true; SetStatus "Cancelling task & cleaning up..."; Set-CancelButtonState $false
    Get-Process -Name "yt-dlp", "ffmpeg" -ErrorAction SilentlyContinue | Where-Object { $_.Id -notin $script:knownPIDs } | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
    try {
        $targetDir = Get-ActiveFolder; if (Test-Path $targetDir) {
            $tempFiles = Get-ChildItem -Path $targetDir -Include *.part, *.ytdl, *.frag, *.temp -File -Recurse -ErrorAction SilentlyContinue
            if ($tempFiles) { $tempFiles | Remove-Item -Force -ErrorAction SilentlyContinue; Log "Cleaned up partial/temp files." "Yellow" }
        }
    } catch { }
})

# -- TOOL UPDATERS ---------------------------------------------------------
$menuUpdateYt.Add_Click({
    if ($script:ytdlp -or $ytdlp) {
        SetStatus "Updating yt-dlp..."; Log "Running yt-dlp -U..." "Yellow"
        $exe = if ($script:ytdlp) { $script:ytdlp } else { $ytdlp }
        Start-Process -FilePath $exe -ArgumentList "-U" -NoNewWindow -Wait; 
        
        Update-UIState -ResetStatus
        Log "yt-dlp update check completed." "Lime"
        $lnkUpdateYt.Visible = $false
        Check-YtDlpVersion
    } else {
        SetStatus "Downloading yt-dlp.exe..."; Log "Fetching latest release from GitHub..." "Yellow"
        $btnDownload.Enabled = $false; $btnList.Enabled = $false
        $script:dlJob = Start-Job { param($dest); [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe" -OutFile $dest -UseBasicParsing } -ArgumentList (Join-Path $ScriptDir "yt-dlp.exe")
        $script:dlTimer = New-Object System.Windows.Forms.Timer; $script:dlTimer.Interval = 500
        $script:dlTimer.Add_Tick({
            try {
                if ($script:dlJob.State -ne 'Running') {
                    $script:dlTimer.Stop(); $script:dlTimer.Dispose(); Receive-Job $script:dlJob | Out-Null; Remove-Job $script:dlJob -Force
                    
                    Update-UIState -ResetStatus
                    if ($script:ytdlp) { Log "yt-dlp downloaded successfully!" "Lime"; $lnkUpdateYt.Visible = $false; Check-YtDlpVersion } else { Log "yt-dlp download failed." "Red" }
                }
            } catch {
                try { Write-SessionLog ("DL TICK ERROR: " + $_.Exception.Message); $_ | Out-File (Join-Path $ScriptDir "error.log") -Encoding UTF8 -Force } catch { }
            }
        }); $script:dlTimer.Start()
    }
})

$menuUpdateFfmpeg.Add_Click({
    SetStatus "Downloading ffmpeg (this may take a minute)..."; Log "Fetching yt-dlp ffmpeg build from GitHub..." "Yellow"
    $btnDownload.Enabled = $false; $btnList.Enabled = $false
    
    $script:dlJobFfmpeg = Start-Job {
        param($destDir)
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $zipUrl = "https://github.com/yt-dlp/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip"
        $zipPath = Join-Path $destDir "ffmpeg_temp.zip"
        $extractPath = Join-Path $destDir "ffmpeg_extract"
        
        try {
            Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing
            if (Test-Path $extractPath) { Remove-Item $extractPath -Recurse -Force }
            Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force
            
            $ffmpegExe = Get-ChildItem -Path $extractPath -Filter "ffmpeg.exe" -Recurse | Select-Object -First 1
            if ($ffmpegExe) {
                Move-Item -Path $ffmpegExe.FullName -Destination (Join-Path $destDir "ffmpeg.exe") -Force
            }
        } finally {
            if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
            if (Test-Path $extractPath) { Remove-Item $extractPath -Recurse -Force }
        }
    } -ArgumentList $ScriptDir
    
    $script:dlTimerFfmpeg = New-Object System.Windows.Forms.Timer; $script:dlTimerFfmpeg.Interval = 1000
    $script:dlTimerFfmpeg.Add_Tick({
        try {
            if ($script:dlJobFfmpeg.State -ne 'Running') {
                $script:dlTimerFfmpeg.Stop(); $script:dlTimerFfmpeg.Dispose(); Receive-Job $script:dlJobFfmpeg | Out-Null; Remove-Job $script:dlJobFfmpeg -Force
                
                Update-UIState -ResetStatus
                if ($script:ffmpeg) { 
                    Log "ffmpeg downloaded and extracted successfully!" "Lime"
                    Sync-UI-To-Profile $cfg.ActiveProfile
                } else { 
                    Log "ffmpeg download or extraction failed." "Red" 
                }
            }
        } catch {
            try { Write-SessionLog ("FFMPEG TICK ERROR: " + $_.Exception.Message); $_ | Out-File (Join-Path $ScriptDir "error.log") -Encoding UTF8 -Force } catch { }
        }
    }); $script:dlTimerFfmpeg.Start()
})

$menuGetFfmpeg.Add_Click({
    $res = [System.Windows.Forms.MessageBox]::Show("Would you like to open your browser to manually download FFmpeg?`n`nDownload the zip, extract it, and place ffmpeg.exe next to this script.", "Get FFmpeg Manually", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Information)
    if ($res -eq 'Yes') { Start-Process "https://github.com/yt-dlp/FFmpeg-Builds/releases/tag/latest" }
})

$txtUrl.Add_KeyDown({ if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Enter) { Start-SingleDownload } })

# -- KEYBOARD SHORTCUTS ------------------------------------------------------
$form.KeyPreview = $true
$form.Add_KeyDown({
    if     ($_.Control -and $_.KeyCode -eq [System.Windows.Forms.Keys]::O)      { $btnOpenList.PerformClick();   $_.SuppressKeyPress = $true }
    elseif ($_.Control -and $_.KeyCode -eq [System.Windows.Forms.Keys]::L)      { $txtUrl.Focus(); $txtUrl.SelectAll(); $_.SuppressKeyPress = $true }
    elseif ($_.Control -and $_.KeyCode -eq [System.Windows.Forms.Keys]::R)      { $btnList.PerformClick();       $_.SuppressKeyPress = $true }
    elseif ($_.Control -and $_.KeyCode -eq [System.Windows.Forms.Keys]::N)      { $btnNewProf.PerformClick();    $_.SuppressKeyPress = $true }
    elseif ($_.Control -and $_.KeyCode -eq [System.Windows.Forms.Keys]::E)      { $btnEditProf.PerformClick();   $_.SuppressKeyPress = $true }
    elseif ($_.Control -and $_.KeyCode -eq [System.Windows.Forms.Keys]::Enter)  { Start-SingleDownload;          $_.SuppressKeyPress = $true }
    elseif ($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape)                 { $btnCancel.PerformClick();     $_.SuppressKeyPress = $true }
})

$form.Add_FormClosing({
    Save-Settings $form $cfg
    Write-SessionLog "--- Now Video Down closed ---"
    if ($script:tray) { $script:tray.Visible = $false; try { $script:tray.Dispose() } catch { }; $script:tray = $null }
    if ($script:activeTimer) { try{$script:activeTimer.Stop();$script:activeTimer.Dispose()}catch{} }
    if ($script:delayTimer)  { try{$script:delayTimer.Stop(); $script:delayTimer.Dispose() }catch{} }
    if ($script:pasteDlTimer) { try{$script:pasteDlTimer.Stop(); $script:pasteDlTimer.Dispose() }catch{} }
    if ($script:updTimer)     { try{$script:updTimer.Stop(); $script:updTimer.Dispose() }catch{} }
    if ($script:updateJob)    { try{Remove-Job $script:updateJob -Force -ErrorAction SilentlyContinue}catch{} }
    if ($script:activeJob)   { Stop-Job $script:activeJob -ErrorAction SilentlyContinue; Remove-Job $script:activeJob -Force -ErrorAction SilentlyContinue }
    Get-Process -Name "yt-dlp", "ffmpeg" -ErrorAction SilentlyContinue | Where-Object { $_.Id -notin $script:knownPIDs } | Stop-Process -Force -ErrorAction SilentlyContinue
})

# -- TRAY ICON, NOTIFICATIONS & SESSION LOG --------------------------------
function Write-SessionLog($line) {
    try {
        $entry = "[{0}] {1}`r`n" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $line
        [System.IO.File]::AppendAllText($script:logFile, $entry, [System.Text.Encoding]::UTF8)
        $script:logSize += $entry.Length
        if ($script:logSize -gt $script:logMaxSize) {
            Copy-Item $script:logFile (Join-Path $ScriptDir "log.old.txt") -Force -ErrorAction SilentlyContinue
            [System.IO.File]::WriteAllText($script:logFile, "", [System.Text.Encoding]::UTF8)
            $script:logSize = 0
        }
    } catch { }
}

function Show-MainWindow {
    $script:inTray = $false
    # restore: Show the hidden form first, then restore the state.
    # (Setting WindowState while the form is still hidden is a no-op -
    #  the window would come back stuck minimized.)
    $form.Show()
    $form.Visible = $true
    $form.WindowState = 'Normal'
    $form.ShowInTaskbar = $true
    $form.Activate()
}

function Hide-ToTray {
    $script:inTray = $true
    # never Hide() synchronously from an event handler - defer it
    $form.BeginInvoke([System.Windows.Forms.MethodInvoker]{
        try { $form.Hide(); Update-TrayTip } catch { }
    }) | Out-Null
}

function Update-TrayTip {
    try {
        if (-not $script:tray) { return }
        if ($script:activeJob) {
            $tip = "Downloading"
            if ($script:batchTotal -gt 0) { $tip = "Batch $($script:batchDone)/$($script:batchTotal)" }
            if ($lblSpeed.Text -and $lblSpeed.Text -ne "-") { $tip += " · $($lblSpeed.Text)" }
            $script:tray.Text = $tip.Substring(0, [Math]::Min(63, $tip.Length))
        } elseif (-not $script:inTray) {
            $script:tray.Text = "Now Video Down"
        }
    } catch { }
}

function Flash-MainWindow {
    try {
        if (-not ("Win32.Flash" -as [type])) { return }
        $fi = New-Object Win32.Flash+FLASHWINFO
        $fi.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf([Win32.Flash+FLASHWINFO])
        $fi.hwnd = $form.Handle
        $fi.dwFlags = 3 -bor 12   # FLASHW_ALL | FLASHW_TIMERNOFG
        $fi.uCount = 3
        [Win32.Flash]::FlashWindowEx([ref]$fi) | Out-Null
    } catch { }
}

function Show-NotifPopup($title, $msg) {
    try {
        $t = Get-ThemePalette $cfg.Theme
        $pop = if ($script:hasNoActivate) { New-Object NoActivateForm } else { New-Object System.Windows.Forms.Form }
        # keep the popup + its timer in SCRIPT scope - a timer that outlives this
        # function cannot safely reference function-local variables (PowerShell
        # cleans the local scope up; the later tick then sees $null -> crash)
        $script:notifPopup = $pop
        $pop.FormBorderStyle = 'None'; $pop.StartPosition = 'Manual'; $pop.ShowInTaskbar = $false; $pop.TopMost = $true
        $pop.Size = [System.Drawing.Size]::new(400, 128)
        $pop.BackColor = $t.Panel; $pop.ForeColor = $t.Text
        $lblT = New-Object System.Windows.Forms.Label
        $lblT.Text = $title; $lblT.Font = $fBold; $lblT.ForeColor = $t.Accent
        $lblT.Location = [System.Drawing.Point]::new(14, 10); $lblT.AutoSize = $true
        $lblM = New-Object System.Windows.Forms.Label
        $lblM.Text = $msg; $lblM.Font = $fNormal; $lblM.ForeColor = $t.Sub
        $lblM.Location = [System.Drawing.Point]::new(14, 36); $lblM.Size = [System.Drawing.Size]::new(372, 44); $lblM.AutoEllipsis = $true
        $lnkFolder = New-Object System.Windows.Forms.LinkLabel
        $lnkFolder.Text = "Open folder"; $lnkFolder.LinkColor = $t.Accent; $lnkFolder.ActiveLinkColor = $t.Accent; $lnkFolder.VisitedLinkColor = $t.Accent
        $lnkFolder.Location = [System.Drawing.Point]::new(14, 92); $lnkFolder.AutoSize = $true
        $lnkFolder.Add_LinkClicked({
            try { $targetDir = Get-ActiveFolder; if (Test-Path $targetDir) { Start-Process $targetDir } } catch { }
            try { if ($script:notifPopup) { $script:notifPopup.Close() } } catch { }
        })
        $lnkShow = New-Object System.Windows.Forms.LinkLabel
        $lnkShow.Text = "Show window"; $lnkShow.LinkColor = $t.Accent; $lnkShow.ActiveLinkColor = $t.Accent; $lnkShow.VisitedLinkColor = $t.Accent
        $lnkShow.Location = [System.Drawing.Point]::new(110, 92); $lnkShow.AutoSize = $true
        $lnkShow.Add_LinkClicked({
            try { Show-MainWindow } catch { }
            try { if ($script:notifPopup) { $script:notifPopup.Close() } } catch { }
        })
        $pop.Controls.AddRange(@($lblT, $lblM, $lnkFolder, $lnkShow))
        $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $pop.Location = [System.Drawing.Point]::new($wa.Right - $pop.Width - 14, $wa.Bottom - $pop.Height - 14)
        if ($script:notifPopTimer) { try { $script:notifPopTimer.Stop(); $script:notifPopTimer.Dispose() } catch { } }
        $script:notifPopTimer = New-Object System.Windows.Forms.Timer
        $script:notifPopTimer.Interval = 6000
        $script:notifPopTimer.Add_Tick({
            try {
                $script:notifPopTimer.Stop(); $script:notifPopTimer.Dispose(); $script:notifPopTimer = $null
                if ($script:notifPopup) { $script:notifPopup.Close() }
            } catch { }
        })
        $script:notifPopTimer.Start()
        $pop.Add_FormClosed({
            try { if ($script:notifPopTimer) { $script:notifPopTimer.Stop(); $script:notifPopTimer.Dispose(); $script:notifPopTimer = $null } } catch { }
            try { $script:notifPopup = $null } catch { }
        })
        $pop.Show()
    } catch {
        try { Write-SessionLog ("POPUP ERROR: " + $_.Exception.Message); $_ | Out-File (Join-Path $ScriptDir "error.log") -Encoding UTF8 -Force } catch { }
    }
}

function Notify-Completed([bool]$ok, $summary) {
    if ($cfg.NotifyStyle -eq 0) { return }
    if ($cfg.NotifyStyle -ge 3) {
        try { if ($ok) { [System.Media.SystemSounds]::Asterisk.Play() } else { [System.Media.SystemSounds]::Exclamation.Play() } } catch { }
    }
    if ($cfg.NotifyStyle -ge 2) {
        Show-NotifPopup ($(if ($ok) { "Download complete" } else { "Download failed" })) $summary
    } else {
        # in-app only: flash the taskbar + status
        Flash-MainWindow
        SetStatus $(if ($ok) { "Download complete." } else { "Download failed - check the log." })
    }
    try {
        if ($script:tray) {
            $tip = $(if ($ok) { "Done · " } else { "Failed · " }) + $summary
            $script:tray.Text = $tip.Substring(0, [Math]::Min(63, $tip.Length))
        }
    } catch { }
}

# -- tray icon + context menu ----------------------------------------------
$script:tray = New-Object System.Windows.Forms.NotifyIcon
$script:tray.Visible = $true
$script:tray.Text = "Now Video Down"
if (Test-Path $IconPath) { try { $script:tray.Icon = New-Object System.Drawing.Icon($IconPath) } catch { } }
if ($null -eq $script:tray.Icon) { $script:tray.Icon = [System.Drawing.SystemIcons]::Application }
$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$miTrayOpen   = $trayMenu.Items.Add("Open Now Video Down")
$miTrayAuto   = $trayMenu.Items.Add("Auto-minimize to tray when a download starts")
$miTrayAuto.CheckOnClick = $true; $miTrayAuto.Checked = $cfg.TrayMinimize
$miTrayAlways = $trayMenu.Items.Add("Minimize to tray when I minimize the window")
$miTrayAlways.CheckOnClick = $true; $miTrayAlways.Checked = $cfg.AlwaysTray
[void]$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$miTrayExit   = $trayMenu.Items.Add("Exit")
$miTrayOpen.Add_Click({ Show-MainWindow })
$miTrayAuto.Add_Click({ $cfg.TrayMinimize = $miTrayAuto.Checked })
$miTrayAlways.Add_Click({ $cfg.AlwaysTray = $miTrayAlways.Checked })
$miTrayClip = $trayMenu.Items.Add("Watch clipboard for URLs")
$miTrayClip.CheckOnClick = $true; $miTrayClip.Checked = $cfg.ClipboardWatch
$miTrayClip.Add_Click({ $cfg.ClipboardWatch = $miTrayClip.Checked; Sync-ClipboardWatchUI })
$miTrayExit.Add_Click({ $form.Close() })
$script:tray.ContextMenuStrip = $trayMenu
$script:tray.Add_MouseDoubleClick({ if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Show-MainWindow } })

# minimize → tray (only when the user chooses "minimize to tray")
$form.Add_Resize({
    try {
        if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized -and -not $script:inTray) {
            if ($cfg.AlwaysTray) {
                Hide-ToTray
            }
        }
    } catch {
        try { Write-SessionLog ("RESIZE ERROR: " + $_.Exception.Message); $_ | Out-File (Join-Path $ScriptDir "error.log") -Encoding UTF8 -Force } catch { }
    }
})

Write-SessionLog "--- Now Video Down v2.37 started ---"

# -- SELF-TEST HOOK (only when NVD_SELFTEST=1) -----------------------------
# Reproduces the minimize→tray→restore cycle in-process and writes the
# observed states to selftest.txt. Invisible in normal use.
if ($env:NVD_SELFTEST -eq "1") {
    $stTimer = New-Object System.Windows.Forms.Timer
    $stTimer.Interval = 6000
    $stTimer.Add_Tick({
        $stTimer.Stop()
        $script:res = @()
        function StLog($line) { $script:res += $line; try { $script:res | Set-Content (Join-Path $ScriptDir "selftest.txt") -Encoding UTF8 } catch { } }
        try {
            StLog "selftest: started"
            # --- screenshots (Screenshots folder) ---
            $script:shotDir = Join-Path $ScriptDir "Screenshots"
            try { New-Item -ItemType Directory -Path $script:shotDir -Force | Out-Null } catch { }
            function Save-WindowShot($frm2, $path) {
                try {
                    if (-not $frm2) { StLog "shot: no form -> $path"; return }
                    if (-not $frm2.Visible) { StLog "shot: invisible -> $path"; return }
                    [void]$frm2.Activate()
                    [System.Windows.Forms.Application]::DoEvents()
                    $bounds = $frm2.Bounds
                    StLog "shot: bounds $($bounds.X),$($bounds.Y) $($bounds.Width)x$($bounds.Height)"
                    $bmp = New-Object System.Drawing.Bitmap($bounds.Width, $bounds.Height)
                    $g = [System.Drawing.Graphics]::FromImage($bmp)
                    $g.CopyFromScreen($bounds.X, $bounds.Y, 0, 0, (New-Object System.Drawing.Size($bounds.Width, $bounds.Height)))
                    $g.Dispose()
                    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
                    $bmp.Dispose()
                    StLog "shot saved: $(Split-Path $path -Leaf)"
                } catch { StLog "shot error: $($_.Exception.Message)" }
            }
            try { $txtUrl.Text = "https://www.youtube.com/watch?v=dQw4w9WgXcQ" } catch { }
            Save-WindowShot $form (Join-Path $script:shotDir "01-main.png")
            $shotT = New-Object System.Windows.Forms.Timer
            $shotT.Interval = 1200
            $shotT.Add_Tick({
                $shotT.Stop(); $shotT.Dispose()
                try {
                    Save-WindowShot $script:managerForm (Join-Path $script:shotDir "02-profiles.png")
                    if ($script:managerForm) { $script:managerForm.Close() }
                } catch { }
            })
            $shotT.Start()
            Show-ProfileManager
            $shotT2 = New-Object System.Windows.Forms.Timer
            $shotT2.Interval = 1200
            $shotT2.Add_Tick({
                $shotT2.Stop(); $shotT2.Dispose()
                try {
                    Save-WindowShot $script:aboutForm (Join-Path $script:shotDir "03-about.png")
                    if ($script:aboutForm) { $script:aboutForm.Close() }
                } catch { }
            })
            $shotT2.Start()
            Show-AboutDialog
            StLog "shots: captured"
            $form.WindowState = 'Minimized'
            for ($i = 0; $i -lt 20; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100 }
            StLog "afterMinimize: inTray=$script:inTray formVisible=$($form.Visible) trayVisible=$($script:tray.Visible) state=$($form.WindowState)"
            Show-MainWindow
            for ($i = 0; $i -lt 10; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100 }
            StLog "afterRestore: inTray=$script:inTray formVisible=$($form.Visible) trayVisible=$($script:tray.Visible) state=$($form.WindowState)"
            Hide-ToTray
            for ($i = 0; $i -lt 10; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100 }
            StLog "afterAutoTray: inTray=$script:inTray formVisible=$($form.Visible)"
            Show-MainWindow
            for ($i = 0; $i -lt 5; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100 }
            StLog "afterAutoRestore: inTray=$script:inTray formVisible=$($form.Visible) state=$($form.WindowState)"
            # popup regression: must show, auto-close (6s) and NOT crash
            Show-NotifPopup "Self-test popup" "Testing the completion popup close timer."
            for ($i = 0; $i -lt 80; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100 }
            StLog "afterPopup: closed=$($null -eq $script:notifPopup) timerNull=$($null -eq $script:notifPopTimer)"
            # clipboard detection regression (skipped if the clipboard is locked)
            try {
                [System.Windows.Forms.Clipboard]::SetText("https://example.com/cliptest")
                for ($i = 0; $i -lt 25; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100 }
                StLog "afterClip: url=$($script:clipUrl) chipVisible=$($btnClipDl.Visible)"
                [System.Windows.Forms.Clipboard]::SetText("plain text no url")
                for ($i = 0; $i -lt 15; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100 }
                StLog "afterClipClear: urlNull=$($null -eq $script:clipUrl)"
            } catch { StLog "clipboardTest: skipped" }
            # about dialog: must open (with logo), close via timer, not crash
            $script:closeAbtTimer = New-Object System.Windows.Forms.Timer
            $script:closeAbtTimer.Interval = 1200
            $script:closeAbtTimer.Add_Tick({ try { $script:closeAbtTimer.Stop(); $script:closeAbtTimer.Dispose(); $script:closeAbtTimer = $null; if ($script:aboutForm) { $script:aboutForm.Close() } } catch { } })
            $script:closeAbtTimer.Start()
            Show-AboutDialog
            StLog "afterAbout: closed=$($null -eq $script:aboutForm)"
            # adaptive layout: grow the window, verify the status group grows
            try {
                $form.ClientSize = [System.Drawing.Size]::new(1150, 1050)
                for ($i = 0; $i -lt 10; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 50 }
                StLog "afterGrow: gbStatus=$($gbStatus.Width)x$($gbStatus.Height) log=$($txtLog.Height)"
                $form.ClientSize = [System.Drawing.Size]::new(900, 915)
                for ($i = 0; $i -lt 10; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 50 }
                StLog "afterReset: gbStatus=$($gbStatus.Width)x$($gbStatus.Height) log=$($txtLog.Height)"
            } catch { StLog "layoutTest: error $($_.Exception.Message)" }
        } catch { StLog "SELFTEST ERROR: $($_.Exception.Message)" }
        StLog "selftest: DONE"
        try { $form.Close() } catch { }
    })
    $stTimer.Start()
}

# -- ADAPTIVE LAYOUT (window is resizable; log/status absorb the change) -----
function Layout-Adaptive {
    try {
        $cw = $form.ClientSize.Width; $ch = $form.ClientSize.Height
        $gw = [Math]::Max(700, $cw - 40)   # group width

        @($gbUrl, $gbProf, $gbOpts, $gbStatus) | ForEach-Object { $_.Width = $gw }

        # status group fills the remaining height; right-anchored controls
        $gbStatus.Height = [Math]::Max(220, $ch - $gbStatus.Top - 12)
        if ($gbStatus.Height -lt 300) {
            $lblFooter.Visible = $false
            $txtLog.Height = [Math]::Max(10, $gbStatus.Height - $txtLog.Top - 12)
        } else {
            $lblFooter.Visible = $true
            $lblFooter.Top = $gbStatus.Height - $lblFooter.Height - 12
            $txtLog.Height = [Math]::Max(40, $lblFooter.Top - $txtLog.Top - 8)
        }
        $innerW = $gw - 30
        $txtLog.Width = $innerW; $lblFooter.Width = $innerW
        $lblWarn.Width = [Math]::Max(200, $innerW - 230)
        $lblStatus.Width = [Math]::Max(200, $innerW - 260)
        $progress.Width = [Math]::Max(120, $innerW - 160)
        $btnCancel.Left = $gw - 120
        $chkVerbose.Left = $gw - 110
        $lblEta.Left = $gw - 130
        $lblSpeed.Left = $gw - 235

        # source row: right-anchored
        $txtUrl.Width = [Math]::Max(300, $gw - 390)
        $btnClear.Left = $gw - 365
        $btnDownload.Left = $gw - 325
        $btnOpenList.Left = $gw - 195
        $btnList.Left = $gw - 110

        # profile row: folder combo stretches
        $cmbFolder.Width = [Math]::Max(300, $gw - 300)
        $lblFolderState.Left = $gw - 278
        $btnBrowse.Left = $gw - 250
        $btnOpenDest.Left = $gw - 150
        $chkQuick.Left = $gw - 70
        $lblProfileSummary.Width = [Math]::Max(300, $gw - 100)
    } catch {
        try { Write-SessionLog ("LAYOUT ERROR: " + $_.Exception.Message); $_ | Out-File (Join-Path $ScriptDir "error.log") -Encoding UTF8 -Force } catch { }
    }
}
$form.Add_SizeChanged({ Layout-Adaptive })

# -- FIT TO SCREEN (small laptops) & INITIAL LAYOUT -------------------------
$workArea = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
if ($form.Width  -gt ($workArea.Width  - 16)) { $form.Width  = $workArea.Width  - 16 }
if ($form.Height -gt ($workArea.Height - 16)) { $form.Height = $workArea.Height - 16 }
Layout-Adaptive

# first-run wizard: one-shot timer, opens right after the main window is up
if ($script:isFirstRun) {
    $wizTimer = New-Object System.Windows.Forms.Timer
    $wizTimer.Interval = 1500
    $wizTimer.Add_Tick({
        $wizTimer.Stop(); $wizTimer.Dispose()
        try {
            if ($script:isFirstRun -and $env:NVD_SELFTEST -ne "1") { Show-FirstRunWizard }
        } catch {
            try { Write-SessionLog ("WIZARD TIMER ERROR: " + $_.Exception.Message) } catch { }
        }
    })
    $wizTimer.Start()
}

try {
    # Application.Run instead of ShowDialog: hiding the form to the tray must
    # NOT end the message loop. With ShowDialog, Hide() makes the modal loop
    # return -> the script ends -> the whole process exits and both the window
    # and the tray icon vanish. Application.Run keeps pumping until the form
    # actually closes.
    [void][System.Windows.Forms.Application]::Run($form)
} catch {
    try { $_ | Out-File (Join-Path $ScriptDir "error.log") -Encoding UTF8 -Force } catch { }
    [System.Windows.Forms.MessageBox]::Show(
        "Now Video Down crashed unexpectedly:`n$($_.Exception.Message)`n`nDetails saved to error.log next to the script.",
        "Now Video Down - Fatal Error",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
}