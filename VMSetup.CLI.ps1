#Requires -Version 5.1
<#
.SYNOPSIS  VM Setup Suite da riga di comando (automazione, RMM, chiavetta).
.EXAMPLE   .\VMSetup.CLI.ps1 -Profilo Ufficio -NomePC UFF-01
.EXAMPLE   .\VMSetup.CLI.ps1 -Profilo Base -Passi Prerequisiti,RimuoviApp,Impostazioni,Energia -NoRestorePoint
.EXAMPLE   .\VMSetup.CLI.ps1 -Lista
#>
[CmdletBinding()] param([string]$Profilo, [string[]]$Passi, [string]$NomePC, [string]$Dominio, [switch]$BitLocker, [string]$BitLockerKeyFolder, [switch]$WindowsUpdate, [switch]$NoRestorePoint, [string[]]$AppsExtra, [switch]$Lista, [switch]$Riavvia)
$root = $PSScriptRoot; if (-not $root) { $root = Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) }
$t = [System.IO.File]::ReadAllText((Join-Path $root 'VMSetup.Engine.psm1'), [System.Text.Encoding]::UTF8)
Import-Module (New-Module -Name 'VMSetup.Engine' -ScriptBlock ([scriptblock]::Create($t))) -Force
$profiles = @(Get-SsProfiles -Folder (Join-Path $root 'Profili'))
if ($Lista -or -not $Profilo) {
    Write-Host "`nPROFILI:" -ForegroundColor Cyan; $profiles | ForEach-Object { Write-Host ("  {0,-24} {1}" -f $_.Nome, $_.Descrizione) }
    Write-Host "`nPASSI (Id - nome [default]):" -ForegroundColor Cyan; Get-SsSteps | ForEach-Object { Write-Host ("  {0,-14} {1}{2}" -f $_.Id, $_.Nome, $(if ($_.Default) { '  [*]' } else { '' })) }
    exit 0
}
$p = $profiles | Where-Object { $_.Nome -eq $Profilo -or ([IO.Path]::GetFileNameWithoutExtension($_.File)) -eq $Profilo } | Select-Object -First 1
if (-not $p) { Write-Host "Profilo '$Profilo' non trovato (usa -Lista)." -ForegroundColor Red; exit 1 }
$colors = @{ INFO = 'Gray'; OK = 'Green'; WARN = 'Yellow'; ERROR = 'Red'; STEP = 'Cyan' }
$cancel = [ref]$false
Initialize-SsCallbacks -OnLog { param($l, $m) Write-Host ("[{0,-5}] {1}" -f $l, $m) -ForegroundColor $colors[$l] } -OnProgress { param($pc, $s) if ($pc -ge 0) { Write-Progress -Activity 'VM Setup Suite' -Status $s -PercentComplete $pc } } -Cancel $cancel
if (-not $Passi) { $Passi = @(Get-SsSteps | Where-Object Default | Select-Object -ExpandProperty Id); if ($BitLocker) { $Passi += 'BitLocker' }; if ($WindowsUpdate) { $Passi += 'WindowsUpdate' }; if ($Dominio) { $Passi += 'Dominio' } }
$opts = @{ NomePC = $NomePC; PuntoRipristino = (-not $NoRestorePoint); BitLocker = ($Passi -contains 'BitLocker'); BitLockerKeyFolder = $BitLockerKeyFolder; WindowsUpdate = ($Passi -contains 'WindowsUpdate'); AppsExtra = $AppsExtra; ProfileFolder = (Join-Path $root 'Profili') }
if ($Dominio) { $opts.Dominio = $Dominio; $opts.DominioCredenziali = Get-Credential -Message "Credenziali dominio $Dominio" }
try {
    $r = Start-SsSetup -Profile $p -StepIds $Passi -Options $opts
    Write-Progress -Activity 'VM Setup Suite' -Completed
    Write-Host ("`nCompletato: {0} passi, {1} errori. Riavvio necessario: {2}. Log: {3}" -f $r.Passi.Count, $r.Errori, $r.RiavvioNecessario, $r.Log) -ForegroundColor Cyan
    if ($Riavvia -and $r.RiavvioNecessario) { Restart-Computer -Force }
    exit $(if ($r.Errori -gt 0) { 2 } else { 0 })
} catch { Write-Host "ERRORE: $($_.Exception.Message)" -ForegroundColor Red; exit 1 }
