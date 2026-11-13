#Requires -Version 5.1
<# Compila VMSetupSuite.exe (PS2EXE) e, se presente Inno Setup 6, l'installer. Eseguire in Windows PowerShell 5.1 come amministratore. #>
[CmdletBinding()] param([switch]$SkipInstaller, [string]$Version = '1.0.0')
$ErrorActionPreference = 'Stop'
$src = $PSScriptRoot; $dist = Join-Path $src 'dist'
New-Item -ItemType Directory -Path $dist -Force | Out-Null
& (Join-Path $src 'Tests\Test-Syntax.ps1')
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
if (-not (Get-Module -ListAvailable -Name ps2exe)) { Install-Module -Name ps2exe -Scope CurrentUser -Force -AllowClobber }
Import-Module ps2exe -Force
$exe = Join-Path $dist 'VMSetupSuite.exe'
Invoke-PS2EXE -InputFile (Join-Path $src 'VMSetup.GUI.ps1') -OutputFile $exe -IconFile (Join-Path $src 'app.ico') -NoConsole -RequireAdmin -STA -x64 `
    -Title 'VM Setup Suite' -Description 'Configurazione automatica di PC Windows da profilo' -Company 'vm technology' -Product 'VM Setup Suite' -Copyright "(c) $(Get-Date -Format yyyy) vm technology" -Version "$Version.0"
foreach ($f in 'VMSetup.Engine.psm1', 'VMSetup.CLI.ps1', 'GUI.xaml', 'logo.png', 'app.ico', 'README.md', 'Avvia-CLI.cmd', 'Profili') { $p = Join-Path $src $f; if (Test-Path $p) { Copy-Item $p $dist -Recurse -Force } }
Compress-Archive -Path (Join-Path $dist '*') -DestinationPath (Join-Path $dist "VMSetupSuite_Portable_$Version.zip") -Force
Write-Host "[+] Compilazione completata: $dist"
if ($SkipInstaller) { return }
$iscc = @("${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe", "$env:ProgramFiles\Inno Setup 6\ISCC.exe", "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) { Write-Warning 'Inno Setup 6 non trovato: salto l''installer.'; return }
& $iscc "/DMyAppVersion=$Version" "/DSourceDir=$dist" "/O$dist" (Join-Path $src 'installer.iss')
if ($LASTEXITCODE -ne 0) { throw "ISCC ha restituito $LASTEXITCODE" }
Write-Host "[+] Installer creato in $dist"
