#Requires -Version 5.1
<#
.SYNOPSIS
    VM Setup Suite - Motore v1.0: prepara un PC Windows 10/11 appena installato in base a un profilo JSON.
.DESCRIPTION
    Passi idempotenti (rieseguibili senza danni), ognuno isolato e loggato:
      Prerequisiti (winget, punto di ripristino) - Nome PC - Rimozione app preinstallate - Debloat (Win11Debloat di Raphire,
      opzionale) - Installazione app (winget) - Impostazioni Windows (correnti + utente predefinito) - Energia - Stampanti
      (driver, porte IP, condivise per-macchina) - Unita' di rete (per tutti gli utenti) - Utenti locali - Collegamenti -
      Sfondo - BitLocker - Windows Update - Dominio (opzionale) - Riavvio.
    I profili stanno in Profili\*.json (vedi Profili\_schema.md). Log e report in C:\ProgramData\VMSetup\.
.NOTES
    (c) vm technology - uso interno. Richiede privilegi di amministratore.
#>
Set-StrictMode -Version 2.0
$script:Version = '1.0.0'
$script:LogCallback = $null; $script:ProgCallback = $null; $script:CancelRef = $null
$script:LogDir = Join-Path $(if ($env:ProgramData) { $env:ProgramData } else { $env:TEMP }) 'VMSetup'
$script:LogFile = $null
$script:RebootNeeded = $false
$script:Internet = $false
$script:HasWinget = $false
$script:DefaultPrinter = $null

function Initialize-SsCallbacks { param([scriptblock]$OnLog, [scriptblock]$OnProgress, [ref]$Cancel) $script:LogCallback = $OnLog; $script:ProgCallback = $OnProgress; $script:CancelRef = $Cancel }
function Write-SsLog {
    param([string]$Message, [ValidateSet('INFO','OK','WARN','ERROR','STEP')][string]$Level = 'INFO')
    $line = "{0} [{1,-5}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    if ($script:LogFile) { try { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 } catch {} }
    if ($script:LogCallback) { try { & $script:LogCallback $Level $Message } catch {} }
}
function Write-SsProgress { param([double]$Percent, [string]$Status) if ($script:ProgCallback) { try { & $script:ProgCallback $Percent $Status } catch {} } }
function Test-SsCancelled { if ($script:CancelRef -and $script:CancelRef.Value) { throw [System.OperationCanceledException]::new('Annullato dall''utente.') } }
function Test-SsAdmin { ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
function Test-SsInternet { try { return [bool](Test-Connection -ComputerName 1.1.1.1 -Count 1 -Quiet -ErrorAction SilentlyContinue) } catch { return $false } }

# ------------------------------------------------------------------------------
#  PROFILI
# ------------------------------------------------------------------------------
function Get-SsProfiles {
    <# Legge Profili\*.json (esclusi quelli che iniziano con _). Ritorna oggetti con Nome, Descrizione, File, Dati. #>
    param([string]$Folder)
    $list = @()
    foreach ($f in Get-ChildItem -LiteralPath $Folder -Filter *.json -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '_*' }) {
        try { $d = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json; $list += [pscustomobject]@{ Nome = $(if ($d.PSObject.Properties['Nome']) { $d.Nome } else { $f.BaseName }); Descrizione = $(if ($d.PSObject.Properties['Descrizione']) { $d.Descrizione } else { '' }); File = $f.FullName; Dati = $d } }
        catch { Write-SsLog -Level WARN -Message "Profilo non valido $($f.Name): $($_.Exception.Message)" }
    }
    return $list
}
function Get-SsProp { param($Obj, [string]$Name, $Default = $null) if ($null -ne $Obj -and $Obj.PSObject.Properties[$Name]) { return $Obj.$Name } ; return $Default }

# ------------------------------------------------------------------------------
#  UTILITA' REGISTRO (utente corrente + utente predefinito per i nuovi profili)
# ------------------------------------------------------------------------------
function Set-SsReg {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)]$Value, [string]$Type = 'DWord')
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}
function Set-SsUserReg {
    <# Scrive la stessa chiave in HKCU e nell'hive dell'utente predefinito (C:\Users\Default\NTUSER.DAT), cosi' vale per gli utenti futuri. #>
    param([Parameter(Mandatory)][string]$RelPath, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)]$Value, [string]$Type = 'DWord')
    Set-SsReg -Path "HKCU:\$RelPath" -Name $Name -Value $Value -Type $Type
    if ($script:DefaultHive) { Set-SsReg -Path "Registry::HKEY_USERS\$($script:DefaultHive)\$RelPath" -Name $Name -Value $Value -Type $Type }
}
$script:DefaultHive = $null
function Mount-SsDefaultHive {
    $dat = Join-Path $env:SystemDrive 'Users\Default\NTUSER.DAT'
    if (-not (Test-Path -LiteralPath $dat)) { return }
    $name = 'VMSETUP_DEFAULT'
    $p = Start-Process reg.exe -ArgumentList @('load', "HKU\$name", "`"$dat`"") -Wait -PassThru -WindowStyle Hidden
    if ($p.ExitCode -eq 0) { $script:DefaultHive = $name } else { Write-SsLog -Level WARN -Message 'Hive utente predefinito non montabile: le impostazioni varranno solo per l''utente corrente.' }
}
function Dismount-SsDefaultHive {
    if (-not $script:DefaultHive) { return }
    [gc]::Collect(); [gc]::WaitForPendingFinalizers()
    for ($i = 1; $i -le 5; $i++) { $p = Start-Process reg.exe -ArgumentList @('unload', "HKU\$($script:DefaultHive)") -Wait -PassThru -WindowStyle Hidden; if ($p.ExitCode -eq 0) { break }; Start-Sleep -Milliseconds (400 * $i) }
    $script:DefaultHive = $null
}

# ------------------------------------------------------------------------------
#  PASSI
# ------------------------------------------------------------------------------
function Step-Prerequisiti {
    param($P, $Opt)
    if (-not (Test-SsAdmin)) { throw 'Servono privilegi di amministratore.' }
    $script:Internet = Test-SsInternet
    Write-SsLog ("Internet: {0}" -f $(if ($script:Internet) { 'disponibile' } else { 'NON disponibile (app, debloat e update verranno saltati)' }))
    $wg = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $wg) {
        Write-SsLog -Level WARN -Message 'winget non trovato: provo a registrare App Installer...'
        try { Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe -ErrorAction Stop; $wg = Get-Command winget.exe -ErrorAction SilentlyContinue } catch {}
        if (-not $wg -and $script:Internet) {
            try {
                $tmp = Join-Path $env:TEMP 'AppInstaller.msixbundle'
                Invoke-WebRequest -Uri 'https://aka.ms/getwinget' -OutFile $tmp -UseBasicParsing
                Add-AppxPackage -Path $tmp -ErrorAction Stop; $wg = Get-Command winget.exe -ErrorAction SilentlyContinue
            } catch { Write-SsLog -Level WARN -Message "Installazione winget fallita: $($_.Exception.Message)" }
        }
    }
    $script:HasWinget = [bool]$wg
    if ($wg) { $v = (& winget.exe --version 2>$null); Write-SsLog -Level OK -Message "winget $v disponibile" } else { Write-SsLog -Level WARN -Message 'winget non disponibile: le app non verranno installate.' }
    if ($Opt.PuntoRipristino) {
        try { Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue; Checkpoint-Computer -Description 'VM Setup Suite - prima della configurazione' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop; Write-SsLog -Level OK -Message 'Punto di ripristino creato.' }
        catch { Write-SsLog -Level WARN -Message "Punto di ripristino non creato: $($_.Exception.Message)" }
    }
}

function Step-NomePC {
    param($P, $Opt)
    $nome = $Opt.NomePC
    if (-not $nome) { Write-SsLog 'Nome PC non specificato: invariato.'; return }
    if ($nome -eq $env:COMPUTERNAME) { Write-SsLog "Nome PC gia' $nome."; return }
    if ($nome -notmatch '^[A-Za-z0-9\-]{1,15}$') { throw "Nome PC non valido: '$nome' (max 15 caratteri, lettere/numeri/trattino)." }
    Rename-Computer -NewName $nome -Force -ErrorAction Stop
    $script:RebootNeeded = $true
    Write-SsLog -Level OK -Message "Nome PC impostato a $nome (attivo dopo il riavvio)."
}

function Step-RimuoviApp {
    param($P, $Opt)
    $list = @(Get-SsProp $P 'RimuoviApp' @())
    if ($list.Count -eq 0) { Write-SsLog 'Nessuna app da rimuovere nel profilo.'; return }
    $n = 0
    foreach ($id in $list) {
        Test-SsCancelled
        try {
            $pk = @(Get-AppxPackage -AllUsers -Name $id -ErrorAction SilentlyContinue)
            foreach ($x in $pk) { Remove-AppxPackage -Package $x.PackageFullName -AllUsers -ErrorAction SilentlyContinue }
            $prov = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object DisplayName -like $id)
            foreach ($x in $prov) { Remove-AppxProvisionedPackage -Online -PackageName $x.PackageName -ErrorAction SilentlyContinue | Out-Null }
            if ($pk.Count -or $prov.Count) { $n++; Write-SsLog "Rimossa: $id" }
        } catch { Write-SsLog -Level WARN -Message "Rimozione $id fallita: $($_.Exception.Message)" }
    }
    Write-SsLog -Level OK -Message "App preinstallate rimosse: $n."
}

function Step-Debloat {
    <# Esegue Win11Debloat (Raphire) con i default + Sysprep (nuovi utenti). Richiede Internet. Non sostituisce i nostri passi: li integra. #>
    param($P, $Opt)
    if (-not $script:Internet) { Write-SsLog -Level WARN -Message 'Debloat saltato: nessuna connessione.'; return }
    $dir = Join-Path $env:TEMP 'Win11Debloat'
    try {
        $zip = Join-Path $env:TEMP 'Win11Debloat.zip'
        Invoke-WebRequest -Uri 'https://github.com/Raphire/Win11Debloat/archive/refs/heads/master.zip' -OutFile $zip -UseBasicParsing
        if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
        Expand-Archive -Path $zip -DestinationPath $dir -Force
        $ps1 = Get-ChildItem -Path $dir -Filter Win11Debloat.ps1 -Recurse | Select-Object -First 1
        if (-not $ps1) { throw 'Win11Debloat.ps1 non trovato nell''archivio.' }
        $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$($ps1.FullName)`"", '-RunDefaults', '-Silent')
        if (Get-SsProp $P 'DebloatNuoviUtenti' $true) { $psArgs += '-Sysprep' }
        Write-SsLog "Avvio Win11Debloat ($($ps1.Directory.Name))..."
        $p = Start-Process powershell.exe -ArgumentList $psArgs -Wait -PassThru -WindowStyle Hidden
        Write-SsLog -Level OK -Message "Win11Debloat completato (codice $($p.ExitCode))."
    } catch { Write-SsLog -Level WARN -Message "Debloat fallito: $($_.Exception.Message)" }
}

function Step-InstallaApp {
    param($P, $Opt)
    $apps = @(Get-SsProp $P 'Apps' @())
    if ($Opt.AppsExtra) { $apps += $Opt.AppsExtra }
    if ($apps.Count -eq 0) { Write-SsLog 'Nessuna app nel profilo.'; return }
    if (-not $script:HasWinget -or -not $script:Internet) { Write-SsLog -Level WARN -Message "Installazione app saltata (winget: $($script:HasWinget), Internet: $($script:Internet))."; return }
    $i = 0; $ok = 0; $fail = @()
    foreach ($app in $apps) {
        Test-SsCancelled; $i++
        $id = $app; $extra = @()
        if ($app -is [pscustomobject]) { $id = $app.Id; if ($app.PSObject.Properties['Override']) { $extra = @('--override', $app.Override) } }
        Write-SsProgress -Percent -1 -Status ("App {0}/{1}: {2}" -f $i, $apps.Count, $id)
        $listed = & winget.exe list --id $id -e --accept-source-agreements 2>$null | Out-String
        if ($listed -match [regex]::Escape($id)) { Write-SsLog "$id gia' installata."; $ok++; continue }
        $out = & winget.exe install --id $id -e --silent --accept-package-agreements --accept-source-agreements --disable-interactivity @extra 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0 -or $out -match 'Installazione completata|Successfully installed|already installed|gia'' installat') { $ok++; Write-SsLog -Level OK -Message "$id installata." }
        else { $fail += $id; Write-SsLog -Level WARN -Message ("{0}: codice {1} - {2}" -f $id, $LASTEXITCODE, (($out -split "`n" | Where-Object { $_ -match '\S' } | Select-Object -Last 1) -join '').Trim()) }
    }
    Write-SsLog -Level $(if ($fail.Count) { 'WARN' } else { 'OK' }) -Message ("App: {0} ok, {1} fallite{2}" -f $ok, $fail.Count, $(if ($fail.Count) { ': ' + ($fail -join ', ') } else { '' }))
}

function Step-Impostazioni {
    param($P, $Opt)
    $s = Get-SsProp $P 'Impostazioni'
    if (-not $s) { Write-SsLog 'Nessuna impostazione nel profilo.'; return }
    Mount-SsDefaultHive
    try {
        $tz = Get-SsProp $s 'FusoOrario'; if ($tz) { & tzutil.exe /s "$tz"; Write-SsLog "Fuso orario: $tz" }
        if ($null -ne (Get-SsProp $s 'EstensioniFile')) { Set-SsUserReg 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'HideFileExt' $(if ($s.EstensioniFile) { 0 } else { 1 }) }
        if ($null -ne (Get-SsProp $s 'FileNascosti')) { Set-SsUserReg 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Hidden' $(if ($s.FileNascosti) { 1 } else { 2 }) }
        if (Get-SsProp $s 'EsploraFileSuQuestoPC') { Set-SsUserReg 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'LaunchTo' 1 }
        if (Get-SsProp $s 'MenuContestualeClassico') { Set-SsUserReg 'Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32' '(default)' '' 'String' }
        if (Get-SsProp $s 'BarraSinistra') { Set-SsUserReg 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarAl' 0 }
        if ($null -ne (Get-SsProp $s 'RicercaBarra')) { Set-SsUserReg 'Software\Microsoft\Windows\CurrentVersion\Search' 'SearchboxTaskbarMode' ([int]$s.RicercaBarra) }
        if (Get-SsProp $s 'NoWidget') { Set-SsUserReg 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarDa' 0; Set-SsReg 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0 }
        if (Get-SsProp $s 'NoCopilot') { Set-SsUserReg 'Software\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1; Set-SsReg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1 }
        if (Get-SsProp $s 'NoSuggerimenti') {
            foreach ($n in 'SubscribedContent-338388Enabled','SubscribedContent-338389Enabled','SubscribedContent-353694Enabled','SubscribedContent-353696Enabled','SubscribedContent-310093Enabled','SilentInstalledAppsEnabled','SystemPaneSuggestionsEnabled','SoftLandingEnabled') { Set-SsUserReg 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' $n 0 }
            Set-SsReg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 1
        }
        $tel = Get-SsProp $s 'Telemetria'; if ($null -ne $tel) { Set-SsReg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' ([int]$tel) }
        if ($null -ne (Get-SsProp $s 'DesktopRemoto')) { Set-SsReg 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' 'fDenyTSConnections' $(if ($s.DesktopRemoto) { 0 } else { 1 }); if ($s.DesktopRemoto) { Enable-NetFirewallRule -DisplayGroup 'Desktop remoto' -ErrorAction SilentlyContinue; Enable-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction SilentlyContinue } }
        if ((Get-SsProp $s 'SMB1') -eq $false) { Disable-WindowsOptionalFeature -Online -FeatureName SMB1Protocol -NoRestart -ErrorAction SilentlyContinue | Out-Null; Write-SsLog 'SMB1 disabilitato.' }
        if ($null -ne (Get-SsProp $s 'AvvioRapido')) { Set-SsReg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled' $(if ($s.AvvioRapido) { 1 } else { 0 }) }
        if ((Get-SsProp $s 'Ibernazione') -eq $false) { & powercfg.exe /hibernate off | Out-Null }
        if (Get-SsProp $s 'IndividuazioneRete') { Set-NetConnectionProfile -NetworkCategory Private -ErrorAction SilentlyContinue; Enable-NetFirewallRule -DisplayGroup 'Individuazione rete' -ErrorAction SilentlyContinue; Enable-NetFirewallRule -DisplayGroup 'Network Discovery' -ErrorAction SilentlyContinue; Enable-NetFirewallRule -DisplayGroup 'Condivisione file e stampanti' -ErrorAction SilentlyContinue; Enable-NetFirewallRule -DisplayGroup 'File and Printer Sharing' -ErrorAction SilentlyContinue }
        if (Get-SsProp $s 'NoBloccoAutomaticoAggiornamentoDriver') { Set-SsReg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching' 'SearchOrderConfig' 0 }
        if (Get-SsProp $s 'DisattivaBlocco') { Set-SsReg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization' 'NoLockScreen' 1 }
        Write-SsLog -Level OK -Message 'Impostazioni Windows applicate (utente corrente + utente predefinito).'
    } finally { Dismount-SsDefaultHive }
}

function Step-Energia {
    param($P, $Opt)
    $e = Get-SsProp $P 'Energia'
    if (-not $e) { return }
    $piano = Get-SsProp $e 'Piano'
    if ($piano) {
        $guid = switch ($piano) { 'Prestazioni' { '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' } 'Risparmio' { 'a1841308-3541-4fab-bc81-f71556f20b4a' } default { '381b4222-f694-41f0-9685-ff5bb260df2e' } }
        & powercfg.exe /setactive $guid | Out-Null; Write-SsLog "Piano energetico: $piano"
    }
    $m = Get-SsProp $e 'SpegnimentoSchermoMin'; if ($m) { & powercfg.exe /change monitor-timeout-ac ([int](Get-SsProp $m 'AC' 15)) | Out-Null; & powercfg.exe /change monitor-timeout-dc ([int](Get-SsProp $m 'DC' 5)) | Out-Null }
    $s = Get-SsProp $e 'SospensioneMin'; if ($s) { & powercfg.exe /change standby-timeout-ac ([int](Get-SsProp $s 'AC' 0)) | Out-Null; & powercfg.exe /change standby-timeout-dc ([int](Get-SsProp $s 'DC' 30)) | Out-Null }
    if (Get-SsProp $e 'NoSospensioneDisco') { & powercfg.exe /change disk-timeout-ac 0 | Out-Null }
    if (Get-SsProp $e 'PulsanteAlimentazioneSpegne') { & powercfg.exe /setacvalueindex SCHEME_CURRENT 4f971e89-eebd-4455-a8de-9e59040e7347 7648efa3-dd9c-4e3e-b566-50f929386280 3 | Out-Null; & powercfg.exe /setactive SCHEME_CURRENT | Out-Null }
    Write-SsLog -Level OK -Message 'Impostazioni energia applicate.'
}

function Step-Stampanti {
    param($P, $Opt)
    $list = @(Get-SsProp $P 'Stampanti' @())
    if ($list.Count -eq 0) { Write-SsLog 'Nessuna stampante nel profilo.'; return }
    foreach ($pr in $list) {
        Test-SsCancelled
        try {
            $cond = Get-SsProp $pr 'Condivisa'
            if ($cond) {
                # connessione PER MACCHINA (tutti gli utenti): /ga. Viene applicata al prossimo accesso/riavvio dello spooler.
                $o = & rundll32.exe printui.dll,PrintUIEntry /ga /q /n "$cond" 2>&1
                Write-SsLog -Level OK -Message "Stampante condivisa $cond aggiunta per tutti gli utenti."
                if (Get-SsProp $pr 'Predefinita') { $script:DefaultPrinter = $cond }
                continue
            }
            $nome = $pr.Nome; $ip = Get-SsProp $pr 'IP'; $drv = Get-SsProp $pr 'Driver'; $inf = Get-SsProp $pr 'InfPath'
            if ($inf -and (Test-Path -LiteralPath $inf)) { & pnputil.exe /add-driver "$inf" /install 2>&1 | Out-Null; Write-SsLog "Driver $inf aggiunto al driver store." }
            if ($drv -and -not (Get-PrinterDriver -Name $drv -ErrorAction SilentlyContinue)) { Add-PrinterDriver -Name $drv -ErrorAction Stop }
            if ($ip) {
                $port = "IP_$ip"
                if (-not (Get-PrinterPort -Name $port -ErrorAction SilentlyContinue)) { Add-PrinterPort -Name $port -PrinterHostAddress $ip -ErrorAction Stop }
                if (-not (Get-Printer -Name $nome -ErrorAction SilentlyContinue)) { Add-Printer -Name $nome -DriverName $drv -PortName $port -ErrorAction Stop }
                Write-SsLog -Level OK -Message "Stampante $nome ($ip) configurata."
            }
            if (Get-SsProp $pr 'Predefinita') { $script:DefaultPrinter = $nome }
        } catch { Write-SsLog -Level WARN -Message "Stampante $($pr | ConvertTo-Json -Compress): $($_.Exception.Message)" }
    }
    if ($script:DefaultPrinter) {
        # predefinita per tutti gli utenti al primo accesso (HKLM Run + script)
        $cmd = "rundll32 printui.dll,PrintUIEntry /y /q /n `"$($script:DefaultPrinter)`""
        Set-SsReg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' 'VMSetup-StampantePredefinita' $cmd 'String'
        try { & rundll32.exe printui.dll,PrintUIEntry /y /q /n "$($script:DefaultPrinter)" 2>&1 | Out-Null } catch {}
        Write-SsLog "Stampante predefinita: $($script:DefaultPrinter)"
    }
    Restart-Service Spooler -ErrorAction SilentlyContinue
}
$script:DefaultPrinter = $null

function Step-Unita {
    param($P, $Opt)
    $list = @(Get-SsProp $P 'Unita' @())
    if ($list.Count -eq 0) { Write-SsLog 'Nessuna unita'' di rete nel profilo.'; return }
    $lines = @('@echo off')
    foreach ($u in $list) { $lines += ('net use {0}: "{1}" /persistent:yes >nul 2>&1' -f $u.Lettera.TrimEnd(':'), $u.Percorso) }
    $dir = $script:LogDir; New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $cmd = Join-Path $dir 'MappaUnita.cmd'
    [System.IO.File]::WriteAllLines($cmd, $lines, (New-Object System.Text.UTF8Encoding($false)))
    # eseguito a ogni accesso di qualsiasi utente (le mappature sono per utente)
    Set-SsReg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' 'VMSetup-MappaUnita' "cmd /c `"$cmd`"" 'String'
    try { & cmd.exe /c "`"$cmd`"" | Out-Null } catch {}
    Write-SsLog -Level OK -Message ("Unita' di rete: {0} mappature ({1}) attive a ogni accesso." -f $list.Count, (($list | ForEach-Object { "$($_.Lettera): $($_.Percorso)" }) -join ', '))
}

function Step-Utenti {
    param($P, $Opt)
    $users = @(Get-SsProp $P 'Utenti' @())
    if ($Opt.NuovoUtente) { $users += [pscustomobject]@{ Nome = $Opt.NuovoUtente; NomeCompleto = $Opt.NuovoUtenteNomeCompleto; Admin = [bool]$Opt.NuovoUtenteAdmin; Password = $Opt.NuovoUtentePassword } }
    if ($users.Count -eq 0) { Write-SsLog 'Nessun utente da creare.'; return }
    foreach ($u in $users) {
        try {
            if (Get-LocalUser -Name $u.Nome -ErrorAction SilentlyContinue) { Write-SsLog "Utente $($u.Nome) gia' presente."; continue }
            $pwd = Get-SsProp $u 'Password'
            if (-not $pwd) { Write-SsLog -Level WARN -Message "Utente $($u.Nome): nessuna password fornita, saltato (impostarla nella GUI)."; continue }
            if ($pwd -is [string]) { $pwd = ConvertTo-SecureString $pwd -AsPlainText -Force }
            $nu = New-LocalUser -Name $u.Nome -Password $pwd -FullName (Get-SsProp $u 'NomeCompleto' $u.Nome) -PasswordNeverExpires -AccountNeverExpires -ErrorAction Stop
            Add-LocalGroupMember -SID 'S-1-5-32-545' -Member $nu -ErrorAction SilentlyContinue
            if (Get-SsProp $u 'Admin') { Add-LocalGroupMember -SID 'S-1-5-32-544' -Member $nu -ErrorAction Stop }
            Write-SsLog -Level OK -Message "Utente $($u.Nome) creato (admin: $([bool](Get-SsProp $u 'Admin')))."
        } catch { Write-SsLog -Level WARN -Message "Utente $($u.Nome): $($_.Exception.Message)" }
    }
}

function Step-Collegamenti {
    param($P, $Opt)
    $links = @(Get-SsProp $P 'Collegamenti' @())
    if ($links.Count -eq 0) { return }
    $desk = Join-Path $env:PUBLIC 'Desktop'
    $sh = New-Object -ComObject WScript.Shell
    foreach ($l in $links) {
        try {
            $target = Get-SsProp $l 'Url'; if (-not $target) { $target = Get-SsProp $l 'Percorso' }
            $ext = if ($target -match '^https?://') { '.url' } else { '.lnk' }
            $path = Join-Path $desk ($l.Nome + $ext)
            if ($ext -eq '.url') { Set-Content -LiteralPath $path -Value "[InternetShortcut]`r`nURL=$target" -Encoding ASCII }
            else { $sc = $sh.CreateShortcut($path); $sc.TargetPath = $target; if (Get-SsProp $l 'Icona') { $sc.IconLocation = $l.Icona }; $sc.Save() }
            Write-SsLog "Collegamento: $($l.Nome)"
        } catch { Write-SsLog -Level WARN -Message "Collegamento $($l.Nome): $($_.Exception.Message)" }
    }
    Write-SsLog -Level OK -Message "Collegamenti creati sul desktop pubblico: $($links.Count)."
}

function Step-Sfondo {
    param($P, $Opt)
    $src = Get-SsProp $P 'Sfondo'
    if (-not $src) { return }
    if (-not [System.IO.Path]::IsPathRooted($src)) { $src = Join-Path $Opt.ProfileFolder $src }
    if (-not (Test-Path -LiteralPath $src)) { Write-SsLog -Level WARN -Message "Sfondo non trovato: $src"; return }
    $dir = Join-Path $env:SystemRoot 'Web\Wallpaper\VMTechnology'; New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $dst = Join-Path $dir ('sfondo' + [IO.Path]::GetExtension($src)); Copy-Item -LiteralPath $src -Destination $dst -Force
    Mount-SsDefaultHive
    try { Set-SsUserReg 'Control Panel\Desktop' 'Wallpaper' $dst 'String'; Set-SsUserReg 'Control Panel\Desktop' 'WallpaperStyle' '10' 'String' } finally { Dismount-SsDefaultHive }
    & rundll32.exe user32.dll,UpdatePerUserSystemParameters 2>$null
    Write-SsLog -Level OK -Message "Sfondo impostato: $dst"
}

function Step-BitLocker {
    param($P, $Opt)
    if (-not $Opt.BitLocker) { Write-SsLog 'BitLocker non richiesto.'; return }
    try {
        $tpm = Get-Tpm -ErrorAction Stop
        if (-not $tpm.TpmReady) { Write-SsLog -Level WARN -Message 'TPM non pronto: BitLocker saltato.'; return }
        $v = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
        if ($v.ProtectionStatus -eq 'On' -or $v.VolumeStatus -ne 'FullyDecrypted') { Write-SsLog "BitLocker gia' attivo/in corso su $env:SystemDrive ($($v.VolumeStatus))." }
        else {
            Enable-BitLocker -MountPoint $env:SystemDrive -EncryptionMethod XtsAes256 -UsedSpaceOnly -TpmProtector -SkipHardwareTest -ErrorAction Stop | Out-Null
            Add-BitLockerKeyProtector -MountPoint $env:SystemDrive -RecoveryPasswordProtector -ErrorAction Stop | Out-Null
            Write-SsLog -Level OK -Message 'BitLocker attivato (XTS-AES 256, solo spazio usato).'
        }
        $v = Get-BitLockerVolume -MountPoint $env:SystemDrive
        $rp = $v.KeyProtector | Where-Object KeyProtectorType -eq 'RecoveryPassword' | Select-Object -First 1
        if ($rp) {
            $dest = $Opt.BitLockerKeyFolder; if (-not $dest) { $dest = $script:LogDir }
            New-Item -ItemType Directory -Path $dest -Force | Out-Null
            $file = Join-Path $dest ("BitLocker_{0}_{1}.txt" -f $env:COMPUTERNAME, (Get-Date -Format yyyyMMdd))
            "Computer: $env:COMPUTERNAME`r`nData: $(Get-Date)`r`nID protettore: $($rp.KeyProtectorId)`r`nChiave di ripristino: $($rp.RecoveryPassword)`r`n" | Set-Content -LiteralPath $file -Encoding UTF8
            Write-SsLog -Level OK -Message "Chiave di ripristino salvata in $file (conservarla in luogo sicuro, poi rimuoverla dal PC)."
            try { BackupToAAD-BitLockerKeyProtector -MountPoint $env:SystemDrive -KeyProtectorId $rp.KeyProtectorId -ErrorAction Stop | Out-Null; Write-SsLog 'Chiave salvata anche su Entra ID.' } catch {}
        }
    } catch { Write-SsLog -Level WARN -Message "BitLocker: $($_.Exception.Message)" }
}

function Step-WindowsUpdate {
    param($P, $Opt)
    if (-not $Opt.WindowsUpdate) { return }
    if (-not $script:Internet) { Write-SsLog -Level WARN -Message 'Windows Update saltato: nessuna connessione.'; return }
    try {
        Write-SsProgress -Percent -1 -Status 'Windows Update: ricerca aggiornamenti...'
        $session = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $res = $searcher.Search("IsInstalled=0 and IsHidden=0 and Type='Software'")
        $n = $res.Updates.Count
        if ($n -eq 0) { Write-SsLog -Level OK -Message 'Windows Update: nessun aggiornamento disponibile.'; return }
        $coll = New-Object -ComObject Microsoft.Update.UpdateColl
        for ($i = 0; $i -lt $n; $i++) { $u = $res.Updates.Item($i); if (-not $u.EulaAccepted) { $u.AcceptEula() }; [void]$coll.Add($u); Write-SsLog "Aggiornamento: $($u.Title)" }
        Write-SsProgress -Percent -1 -Status "Windows Update: download di $n aggiornamenti..."
        $dl = $session.CreateUpdateDownloader(); $dl.Updates = $coll; [void]$dl.Download()
        Write-SsProgress -Percent -1 -Status "Windows Update: installazione di $n aggiornamenti..."
        $inst = $session.CreateUpdateInstaller(); $inst.Updates = $coll; $r = $inst.Install()
        if ($r.RebootRequired) { $script:RebootNeeded = $true }
        Write-SsLog -Level OK -Message ("Windows Update: {0} aggiornamenti installati (codice risultato {1}, riavvio richiesto: {2})." -f $n, $r.ResultCode, $r.RebootRequired)
    } catch { Write-SsLog -Level WARN -Message "Windows Update: $($_.Exception.Message)" }
}

function Step-Dominio {
    param($P, $Opt)
    if (-not $Opt.Dominio) { return }
    if ((Get-CimInstance Win32_ComputerSystem).PartOfDomain) { Write-SsLog "PC gia' in dominio."; return }
    if (-not $Opt.DominioCredenziali) { throw 'Credenziali di dominio mancanti.' }
    $joinArgs = @{ DomainName = $Opt.Dominio; Credential = $Opt.DominioCredenziali; Force = $true; ErrorAction = 'Stop' }
    if ($Opt.NomePC -and $Opt.NomePC -ne $env:COMPUTERNAME) { $joinArgs.NewName = $Opt.NomePC }
    if ($Opt.DominioOU) { $joinArgs.OUPath = $Opt.DominioOU }
    Add-Computer @joinArgs
    $script:RebootNeeded = $true
    Write-SsLog -Level OK -Message "PC aggiunto al dominio $($Opt.Dominio) (attivo dopo il riavvio)."
}

# ------------------------------------------------------------------------------
#  ORCHESTRAZIONE
# ------------------------------------------------------------------------------
function Get-SsSteps {
    <# Elenco passi disponibili (Id, Nome, Default). La GUI li mostra come caselle. #>
    @(
        [pscustomobject]@{ Id='Prerequisiti';  Nome='Prerequisiti (winget, punto di ripristino)'; Default=$true;  Fn='Step-Prerequisiti' }
        [pscustomobject]@{ Id='NomePC';        Nome='Nome del PC';                                Default=$true;  Fn='Step-NomePC' }
        [pscustomobject]@{ Id='RimuoviApp';    Nome='Rimozione app preinstallate (profilo)';     Default=$true;  Fn='Step-RimuoviApp' }
        [pscustomobject]@{ Id='Debloat';       Nome='Debloat completo (Win11Debloat, richiede Internet)'; Default=$false; Fn='Step-Debloat' }
        [pscustomobject]@{ Id='InstallaApp';   Nome='Installazione applicazioni (winget)';      Default=$true;  Fn='Step-InstallaApp' }
        [pscustomobject]@{ Id='Impostazioni';  Nome='Impostazioni Windows';                      Default=$true;  Fn='Step-Impostazioni' }
        [pscustomobject]@{ Id='Energia';       Nome='Energia e sospensione';                     Default=$true;  Fn='Step-Energia' }
        [pscustomobject]@{ Id='Stampanti';     Nome='Stampanti';                                 Default=$true;  Fn='Step-Stampanti' }
        [pscustomobject]@{ Id='Unita';         Nome='Unita'' di rete';                           Default=$true;  Fn='Step-Unita' }
        [pscustomobject]@{ Id='Utenti';        Nome='Utenti locali';                             Default=$true;  Fn='Step-Utenti' }
        [pscustomobject]@{ Id='Collegamenti';  Nome='Collegamenti sul desktop';                  Default=$true;  Fn='Step-Collegamenti' }
        [pscustomobject]@{ Id='Sfondo';        Nome='Sfondo aziendale';                          Default=$true;  Fn='Step-Sfondo' }
        [pscustomobject]@{ Id='BitLocker';     Nome='BitLocker sul disco di sistema';            Default=$false; Fn='Step-BitLocker' }
        [pscustomobject]@{ Id='WindowsUpdate'; Nome='Windows Update (puo'' richiedere molto tempo)'; Default=$false; Fn='Step-WindowsUpdate' }
        [pscustomobject]@{ Id='Dominio';       Nome='Join al dominio Active Directory';          Default=$false; Fn='Step-Dominio' }
    )
}

function Start-SsSetup {
    <#
    .SYNOPSIS  Esegue i passi selezionati con il profilo dato. $Options: hashtable con NomePC, PuntoRipristino, BitLocker, BitLockerKeyFolder,
               WindowsUpdate, Dominio, DominioCredenziali, DominioOU, NuovoUtente*, AppsExtra, ProfileFolder.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Profile, [string[]]$StepIds, [hashtable]$Options = @{})
    New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
    $script:LogFile = Join-Path $script:LogDir ("setup_{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $script:RebootNeeded = $false; $script:DefaultPrinter = $null
    $started = Get-Date
    $all = Get-SsSteps
    $todo = @($all | Where-Object { -not $StepIds -or $StepIds -contains $_.Id })
    Write-SsLog -Level STEP -Message ("=== VM Setup Suite v{0} - profilo '{1}' - {2} passi - {3} ===" -f $script:Version, $Profile.Nome, $todo.Count, $env:COMPUTERNAME)
    if ($todo.Id -notcontains 'Prerequisiti') { $script:Internet = Test-SsInternet; $script:HasWinget = [bool](Get-Command winget.exe -ErrorAction SilentlyContinue) }
    $results = @(); $i = 0
    foreach ($s in $todo) {
        Test-SsCancelled
        $i++
        Write-SsProgress -Percent (($i - 1) / $todo.Count * 100) -Status ("Passo {0}/{1}: {2}" -f $i, $todo.Count, $s.Nome)
        Write-SsLog -Level STEP -Message "--- $($s.Nome) ---"
        $t0 = Get-Date
        try { & $s.Fn $Profile.Dati $Options; $results += [pscustomobject]@{ Passo = $s.Nome; Esito = 'OK'; Durata = [int]((Get-Date) - $t0).TotalSeconds; Errore = '' } }
        catch [System.OperationCanceledException] { throw }
        catch { Write-SsLog -Level ERROR -Message "$($s.Nome): $($_.Exception.Message)"; $results += [pscustomobject]@{ Passo = $s.Nome; Esito = 'ERRORE'; Durata = [int]((Get-Date) - $t0).TotalSeconds; Errore = $_.Exception.Message } }
    }
    Write-SsProgress -Percent 100 -Status 'Completato'
    $report = [pscustomobject]@{ Computer = $env:COMPUTERNAME; Profilo = $Profile.Nome; Inizio = $started; Durata = ((Get-Date) - $started).ToString(); Passi = $results; RiavvioNecessario = $script:RebootNeeded; Log = $script:LogFile; Errori = @($results | Where-Object Esito -eq 'ERRORE').Count }
    $report | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath ([IO.Path]::ChangeExtension($script:LogFile, '.json')) -Encoding UTF8
    Write-SsLog -Level STEP -Message ("=== COMPLETATO in {0:mm\:ss}: {1} passi, {2} errori. Riavvio necessario: {3} ===" -f ((Get-Date) - $started), $results.Count, $report.Errori, $script:RebootNeeded)
    return $report
}

Export-ModuleMember -Function *-Ss*, Step-*
