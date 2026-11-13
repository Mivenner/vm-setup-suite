#Requires -Version 5.1
<# VM Setup Suite - interfaccia WPF (wizard 4 passi). Richiede VMSetup.Engine.psm1, GUI.xaml, logo.png, Profili\ nella stessa cartella. #>
[CmdletBinding()] param()
$script:Root = $PSScriptRoot
if (-not $script:Root) { try { $script:Root = Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) } catch {} }
if (-not $script:Root) { $script:Root = [AppDomain]::CurrentDomain.BaseDirectory }
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms
function Show-FatalError([string]$Message, $Err) {
    $d = $Message; if ($Err) { $d += "`n" + $Err.ScriptStackTrace }
    foreach ($lp in (Join-Path $script:Root 'vmsetup_error.log'), (Join-Path $env:TEMP 'vmsetup_error.log')) { try { Add-Content -LiteralPath $lp -Value ("{0} {1}" -f (Get-Date -Format s), $d); break } catch {} }
    try { [System.Windows.MessageBox]::Show($Message, 'VM Setup Suite', 'OK', 'Error') | Out-Null } catch {}
}
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    try { $exe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        if ($exe -match 'powershell(_ise)?\.exe$|pwsh\.exe$') { Start-Process -FilePath $exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-STA','-File', "`"$PSCommandPath`"") -Verb RunAs | Out-Null } else { Start-Process -FilePath $exe -Verb RunAs | Out-Null }
    } catch { Show-FatalError 'Sono necessari privilegi di amministratore.' }
    return
}
try {
try { Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force -ErrorAction SilentlyContinue } catch {}
$EnginePath = Join-Path $script:Root 'VMSetup.Engine.psm1'; $XamlPath = Join-Path $script:Root 'GUI.xaml'; $ProfileFolder = Join-Path $script:Root 'Profili'
if ($env:VM_PORTABLE_DIR -and (Test-Path -LiteralPath (Join-Path $env:VM_PORTABLE_DIR 'Profili'))) { $ProfileFolder = Join-Path $env:VM_PORTABLE_DIR 'Profili' }
foreach ($f in $EnginePath, $XamlPath) { if (-not (Test-Path -LiteralPath $f)) { Show-FatalError "File mancante: $f"; return } }
$EngineText = [System.IO.File]::ReadAllText($EnginePath, [System.Text.Encoding]::UTF8)
Import-Module (New-Module -Name 'VMSetup.Engine' -ScriptBlock ([scriptblock]::Create($EngineText))) -Force
[xml]$xaml = Get-Content -LiteralPath $XamlPath -Raw -Encoding UTF8
$Window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$ui = @{}; $xaml.SelectNodes('//*[@Name]') | ForEach-Object { $ui[$_.Name] = $Window.FindName($_.Name) }
try { $logo = Join-Path $script:Root 'logo.png'; if (Test-Path -LiteralPath $logo) { $bmp = New-Object System.Windows.Media.Imaging.BitmapImage; $bmp.BeginInit(); $bmp.UriSource = New-Object System.Uri($logo); $bmp.CacheOption = 'OnLoad'; $bmp.EndInit(); $ui.imgLogo.Source = $bmp; $Window.Icon = $bmp } } catch {}
$ui.lblComputer.Text = $env:COMPUTERNAME
$ui.lblInternet.Text = $(if (Test-SsInternet) { 'Internet: disponibile' } else { 'Internet: NON disponibile' })
$ui.txtNomePC.Text = $env:COMPUTERNAME
$ui.txtBlKey.Text = Join-Path $env:ProgramData 'VMSetup'

# Profili
$script:Profiles = @(Get-SsProfiles -Folder $ProfileFolder)
if ($script:Profiles.Count -eq 0) { Show-FatalError "Nessun profilo trovato in $ProfileFolder"; return }
$first = $true
foreach ($p in $script:Profiles) {
    $rb = New-Object System.Windows.Controls.RadioButton; $rb.Style = $Window.FindResource('Card'); $rb.Tag = $p; $rb.GroupName = 'prof'; $rb.IsChecked = $first; $first = $false
    $sp = New-Object System.Windows.Controls.StackPanel
    $t1 = New-Object System.Windows.Controls.TextBlock; $t1.Text = $p.Nome; $t1.FontWeight = 'SemiBold'; $t1.FontSize = 14
    $t2 = New-Object System.Windows.Controls.TextBlock; $t2.Text = $p.Descrizione; $t2.Style = $Window.FindResource('Hint')
    $apps = @((Get-SsProp $p.Dati 'Apps' @()) | ForEach-Object { if ($_ -is [string]) { $_ } else { $_.Id } })
    $t3 = New-Object System.Windows.Controls.TextBlock; $t3.Text = 'App: ' + ($apps -join ', '); $t3.Style = $Window.FindResource('Hint')
    [void]$sp.Children.Add($t1); [void]$sp.Children.Add($t2); [void]$sp.Children.Add($t3); $rb.Content = $sp
    [void]$ui.pnlProfiles.Children.Add($rb)
}
function Get-SelectedProfile { ($ui.pnlProfiles.Children | Where-Object { $_.IsChecked }).Tag }
foreach ($s in Get-SsSteps) { $cb = New-Object System.Windows.Controls.CheckBox; $cb.Content = $s.Nome; $cb.Tag = $s.Id; $cb.IsChecked = $s.Default; [void]$ui.pnlSteps.Children.Add($cb) }

$script:Step = 1
function Set-Step([int]$n) {
    $script:Step = $n
    foreach ($p in 'pnlProfile','pnlOptions','pnlRun','pnlDone') { $ui[$p].Visibility = 'Collapsed' }
    $ui.btnBack.IsEnabled = ($n -eq 2); $ui.btnNext.IsEnabled = $true
    switch ($n) {
        1 { $ui.pnlProfile.Visibility = 'Visible'; $ui.lblStepTitle.Text = 'Passo 1 di 4 - Scegli il profilo'; $ui.btnNext.Content = 'Avanti' }
        2 { $ui.pnlOptions.Visibility = 'Visible'; $ui.lblStepTitle.Text = "Passo 2 di 4 - Opzioni per il profilo '$((Get-SelectedProfile).Nome)'"; $ui.btnNext.Content = 'Avvia configurazione' }
        3 { $ui.pnlRun.Visibility = 'Visible'; $ui.lblStepTitle.Text = 'Passo 3 di 4 - Esecuzione'; $ui.btnNext.Content = 'Attendere...'; $ui.btnNext.IsEnabled = $false }
        4 { $ui.pnlDone.Visibility = 'Visible'; $ui.lblStepTitle.Text = 'Passo 4 di 4 - Riepilogo'; $ui.btnNext.Content = 'Chiudi' }
    }
}

$script:Sync = [hashtable]::Synchronized(@{ Log = (New-Object System.Collections.Concurrent.ConcurrentQueue[string]); Percent = 0.0; Status = ''; Done = $false; Error = $null; Report = $null; CancelRef = ([ref]$false) })
$Timer = New-Object System.Windows.Threading.DispatcherTimer; $Timer.Interval = [TimeSpan]::FromMilliseconds(250)
$Timer.Add_Tick({
    $line = $null; $added = $false
    while ($script:Sync.Log.TryDequeue([ref]$line)) { $ui.txtLog.AppendText($line + "`r`n"); $added = $true }
    if ($added) { $ui.txtLog.ScrollToEnd() }
    if ($script:Sync.Percent -lt 0) { $ui.progressBar.IsIndeterminate = $true } else { $ui.progressBar.IsIndeterminate = $false; $ui.progressBar.Value = [double]$script:Sync.Percent }
    $ui.lblStatus.Text = [string]$script:Sync.Status
    if ($script:Sync.Done) {
        $Timer.Stop(); Set-Step 4
        if ($script:Sync.Error) { $ui.lblDoneTitle.Text = 'Configurazione interrotta'; $ui.lblDoneText.Text = $script:Sync.Error; $ui.btnReboot.Visibility = 'Collapsed'; return }
        $r = $script:Sync.Report
        $ui.lblDoneTitle.Text = $(if ($r.Errori -gt 0) { "Completato con $($r.Errori) errori" } else { 'Configurazione completata' })
        $ui.lblDoneText.Text = ("Profilo: {0}`nDurata: {1}`nPassi: {2}`nRiavvio necessario: {3}`n`n{4}" -f $r.Profilo, $r.Durata, (($r.Passi | ForEach-Object { "{0} [{1}]" -f $_.Passo, $_.Esito }) -join "; "), $(if ($r.RiavvioNecessario) { 'SI''' } else { 'no' }), $(if ($r.Errori -gt 0) { 'Vedere il log per i dettagli degli errori.' } else { '' }))
        $ui.btnReboot.Visibility = $(if ($r.RiavvioNecessario) { 'Visible' } else { 'Collapsed' })
        if ($r.RiavvioNecessario -and $ui.chkRebootEnd.IsChecked) { Restart-Computer -Force }
    }
})
function Start-Run {
    $prof = Get-SelectedProfile
    $steps = @($ui.pnlSteps.Children | Where-Object { $_.IsChecked } | ForEach-Object { $_.Tag })
    if ($steps.Count -eq 0) { [System.Windows.MessageBox]::Show('Seleziona almeno un passo.', 'VM Setup Suite') | Out-Null; return }
    $opts = @{ NomePC = $ui.txtNomePC.Text.Trim(); PuntoRipristino = [bool]$ui.chkRestorePoint.IsChecked; BitLocker = ($steps -contains 'BitLocker'); BitLockerKeyFolder = $ui.txtBlKey.Text.Trim(); WindowsUpdate = ($steps -contains 'WindowsUpdate'); ProfileFolder = $ProfileFolder
               AppsExtra = @($ui.txtAppsExtra.Text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    if ($ui.txtUser.Text.Trim()) {
        if ($ui.pwdUser.SecurePassword.Length -lt 1) { [System.Windows.MessageBox]::Show('Inserisci la password del nuovo utente.', 'VM Setup Suite') | Out-Null; return }
        $opts.NuovoUtente = $ui.txtUser.Text.Trim(); $opts.NuovoUtentePassword = $ui.pwdUser.SecurePassword.Copy(); $opts.NuovoUtenteAdmin = [bool]$ui.chkUserAdmin.IsChecked; $opts.NuovoUtenteNomeCompleto = $ui.txtUser.Text.Trim()
    }
    if ($ui.txtDominio.Text.Trim() -and ($steps -contains 'Dominio')) {
        $opts.Dominio = $ui.txtDominio.Text.Trim()
        $cred = Get-Credential -Message "Credenziali per aggiungere il PC al dominio $($opts.Dominio)" -UserName "$($opts.Dominio)\"
        if (-not $cred) { return }
        $opts.DominioCredenziali = $cred
    }
    $msg = "Applicare il profilo '$($prof.Nome)' a questo PC ($env:COMPUTERNAME)?`nPassi: $($steps.Count). Alcune operazioni non sono reversibili (rimozione app, BitLocker, join dominio)."
    if ([System.Windows.MessageBox]::Show($msg, 'Conferma', 'YesNo', 'Question') -ne 'Yes') { return }
    Set-Step 3; $ui.txtLog.Clear(); $ui.lblRunTitle.Text = "Configurazione '$($prof.Nome)' in corso"
    $script:Sync.Done = $false; $script:Sync.Error = $null; $script:Sync.Report = $null; $script:Sync.Percent = 0; $script:Sync.CancelRef = [ref]$false
    $rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState = 'STA'; $rs.Open()
    $rs.SessionStateProxy.SetVariable('Sync', $script:Sync); $rs.SessionStateProxy.SetVariable('EngineText', $EngineText); $rs.SessionStateProxy.SetVariable('Prof', $prof); $rs.SessionStateProxy.SetVariable('Steps', $steps); $rs.SessionStateProxy.SetVariable('Opts', $opts)
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript({
        try {
            Import-Module (New-Module -Name 'VMSetup.Engine' -ScriptBlock ([scriptblock]::Create($EngineText))) -Force
            Initialize-SsCallbacks -OnLog { param($l, $m) $Sync.Log.Enqueue(("{0} [{1,-5}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $l, $m)) } -OnProgress { param($p, $s) $Sync.Percent = $p; $Sync.Status = $s } -Cancel $Sync.CancelRef
            $Sync.Report = Start-SsSetup -Profile $Prof -StepIds $Steps -Options $Opts
        } catch { $Sync.Error = $_.Exception.Message; $Sync.Log.Enqueue('[ERROR] ' + $_.Exception.Message) } finally { $Sync.Done = $true }
    })
    [void]$ps.BeginInvoke(); $Timer.Start()
}
$ui.btnNext.Add_Click({ switch ($script:Step) { 1 { Set-Step 2 } 2 { Start-Run } 4 { $Window.Close() } } })
$ui.btnBack.Add_Click({ Set-Step 1 })
$ui.btnRestart.Add_Click({ Set-Step 1 })
$ui.btnCancel.Add_Click({ $script:Sync.CancelRef.Value = $true; $ui.btnCancel.IsEnabled = $false; $script:Sync.Status = 'Annullamento al termine del passo corrente...' })
$ui.btnOpenProfiles.Add_Click({ Start-Process explorer.exe -ArgumentList "`"$ProfileFolder`"" })
$ui.btnBlBrowse.Add_Click({ $d = New-Object System.Windows.Forms.FolderBrowserDialog; if ($d.ShowDialog() -eq 'OK') { $ui.txtBlKey.Text = $d.SelectedPath } })
$ui.btnOpenLog.Add_Click({ if ($script:Sync.Report -and (Test-Path $script:Sync.Report.Log)) { Start-Process notepad.exe -ArgumentList "`"$($script:Sync.Report.Log)`"" } })
$ui.btnReboot.Add_Click({ if ([System.Windows.MessageBox]::Show('Riavviare adesso?', 'VM Setup Suite', 'YesNo', 'Question') -eq 'Yes') { Restart-Computer -Force } })
Set-Step 1
[void]$Window.ShowDialog()
} catch { Show-FatalError ("Errore all'avvio: " + $_.Exception.Message) $_ }
