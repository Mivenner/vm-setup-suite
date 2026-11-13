<#
.SYNOPSIS  Crea un UNICO file .cmd portatile (nessuna installazione, nessuna compilazione) che contiene tutto il tool.
           Al doppio clic chiede l'elevazione, si estrae in %LOCALAPPDATA%\vmtechnology\<nome>-<versione> e avvia l'interfaccia.
.EXAMPLE   .\Make-Portable.ps1                      # crea dist\<Nome>_Portable.cmd
#>
param([string]$Version = '', [string]$OutDir = '')
$ErrorActionPreference = 'Stop'
$src = $PSScriptRoot
$gui = Get-ChildItem -LiteralPath $src -Filter '*.GUI.ps1' | Select-Object -First 1
if (-not $gui) { throw 'Nessun *.GUI.ps1 trovato.' }
$name = switch -Wildcard ($gui.Name) { 'VMMigration*' { 'VMMigrationSuite' } 'VMHealth*' { 'VMHealthCheck' } 'VMSetup*' { 'VMSetupSuite' } default { $gui.BaseName } }
if (-not $Version) { $Version = (Get-Date -Format 'yyyyMMdd-HHmm') }
if (-not $OutDir) { $OutDir = Join-Path $src 'dist' }
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$stage = Join-Path ([IO.Path]::GetTempPath()) ("vmportable_" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage | Out-Null
Get-ChildItem -LiteralPath $src -File | Where-Object { $_.Extension -in '.ps1', '.psm1', '.xaml', '.png', '.ico', '.md' -and $_.Name -notin 'Build.ps1', 'Make-Portable.ps1' } | Copy-Item -Destination $stage
if (Test-Path (Join-Path $src 'Profili')) { Copy-Item (Join-Path $src 'Profili') $stage -Recurse }
$zip = "$stage.zip"
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -Force
$b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($zip))
Remove-Item $stage -Recurse -Force; Remove-Item $zip -Force
$ps = @(
    '$s=$env:VMSELF'
    '$adm=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)'
    'if(-not $adm){try{Start-Process -FilePath $s -Verb RunAs}catch{};exit}'
    '$t=[IO.File]::ReadAllText($s)'
    '$m=[string]::Concat(''::PAY'',''LOAD::'')'
    '$b=$t.Substring($t.LastIndexOf($m)+$m.Length).Trim()'
    ('$d=Join-Path $env:LOCALAPPDATA ''vmtechnology\{0}-{1}''' -f $name, $Version)
    ('if(-not(Test-Path (Join-Path $d ''{0}''))){{New-Item -ItemType Directory -Path $d -Force|Out-Null;$z=Join-Path $env:TEMP ''vmportable.zip'';[IO.File]::WriteAllBytes($z,[Convert]::FromBase64String($b));Expand-Archive -LiteralPath $z -DestinationPath $d -Force;Remove-Item $z -Force}}' -f $gui.Name)
    '$env:VM_PORTABLE_DIR=Split-Path -Parent $s'
    ('& (Join-Path $d ''{0}'')' -f $gui.Name)
) -join ';'
$cmd = "@echo off`r`nrem $name $Version - versione portatile a file singolo (vm technology). Doppio clic per avviare.`r`nset `"VMSELF=%~f0`"`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -STA -Command `"$ps`"`r`nexit /b`r`n::PAYLOAD::`r`n$b64`r`n"
$out = Join-Path $OutDir ("{0}_Portable.cmd" -f $name)
[IO.File]::WriteAllText($out, $cmd, [Text.Encoding]::ASCII)
Write-Host ("[+] {0} ({1:N0} KB)" -f $out, ((Get-Item $out).Length / 1KB))
