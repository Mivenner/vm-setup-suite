<!-- header -->
<p align="center"><img src="logo.png" width="96" alt="vm technology"></p>
<h1 align="center">VM Setup Suite</h1>
<p align="center">Prepara un PC Windows appena installato partendo da un profilo JSON: pulizia, app, impostazioni, stampanti, utenti, BitLocker.</p>
<p align="center">
  <a href="https://github.com/Mivenner/vm-setup-suite/actions/workflows/build.yml"><img src="https://github.com/Mivenner/vm-setup-suite/actions/workflows/build.yml/badge.svg" alt="Build"></a>
  <img src="https://img.shields.io/badge/Windows-10%20%7C%2011-0078D4" alt="Windows 10 | 11">
  <img src="https://img.shields.io/badge/PowerShell-5.1%20%7C%207-5391FE" alt="PowerShell 5.1 | 7">
</p>

**Download dell'ultima build:** [File singolo .cmd](https://github.com/Mivenner/vm-setup-suite/releases/latest/download/VMSetupSuite_Portable.cmd) · [Zip portable](https://github.com/Mivenner/vm-setup-suite/releases/latest/download/VMSetupSuite_Portable.zip) · [Installer](https://github.com/Mivenner/vm-setup-suite/releases/latest/download/VMSetupSuite_Setup.exe)

Altri strumenti vm technology: [Migration Suite](https://github.com/Mivenner/vm-migration-suite) · [Health Check](https://github.com/Mivenner/vm-health-check) · [Setup Suite](https://github.com/Mivenner/vm-setup-suite) · [Printer Manager](https://github.com/Mivenner/vm-printer-manager)

---

Prepara un PC Windows 10/11 appena installato in base a un **profilo** (Base, Ufficio, Agente, Produzione, o i tuoi): rimozione app preinstallate, debloat opzionale (Win11Debloat), installazione app con winget, impostazioni Windows per l'utente corrente **e** per gli utenti futuri, energia, stampanti, unità di rete, utenti locali, collegamenti, sfondo, BitLocker, Windows Update, join al dominio.

- GUI: `VMSetupSuite.exe` (o `Avvia-GUI.cmd` dai sorgenti) — wizard in 4 passi.
- CLI: `Avvia-CLI.cmd -Profilo Ufficio -NomePC UFF-01` (`-Lista` per profili e passi). Codice di uscita 0 ok, 2 errori nei passi, 1 errore fatale.
- Profili: cartella `Profili\` (JSON, vedi `_schema.md`). Copia un profilo, rinominalo e adattalo per sede/cliente.
- Log e report: `C:\ProgramData\VMSetup\setup_<data>.log/.json`.

## Cosa fa ogni passo
| Passo | Dettagli |
|------|----------|
| Prerequisiti | Verifica/installa winget, controlla Internet, punto di ripristino |
| Nome PC | `Rename-Computer` (attivo al riavvio) |
| Rimozione app | Appx e pacchetti provisioned elencati nel profilo (Xbox, Solitaire, Clipchamp, News, Copilot…) |
| Debloat | Scarica ed esegue [Win11Debloat](https://github.com/Raphire/Win11Debloat) `-RunDefaults -Silent -Sysprep` |
| App | `winget install` per ogni ID (salta quelle già presenti); app aggiuntive dalla GUI |
| Impostazioni | Esplora file, menu classico, barra, Copilot/widget/suggerimenti, telemetria, RDP, SMB1, avvio rapido… scritte in HKCU e nell'hive `Default` |
| Energia | Piano, timeout schermo/sospensione, pulsante alimentazione |
| Stampanti | Driver (`pnputil`), porte IP, stampanti condivise **per macchina** (`printui /ga`), predefinita per tutti |
| Unità di rete | Script `net use` eseguito a ogni accesso di ogni utente (HKLM Run) |
| Utenti | Creazione utenti locali (password dalla GUI) |
| Collegamenti / Sfondo | Desktop pubblico; sfondo in `C:\Windows\Web\Wallpaper\VMTechnology` per utenti correnti e futuri |
| BitLocker | XTS-AES 256 solo spazio usato, TPM + chiave di ripristino salvata nella cartella scelta (e su Entra ID se joinato) |
| Windows Update | Ricerca/scarica/installa via API Windows Update (COM) |
| Dominio | `Add-Computer` con credenziali richieste all'avvio |

## Build
`.\Build.ps1` (PS2EXE + Inno Setup 6) oppure push su GitHub: il workflow produce exe, zip portable e Setup, e aggiorna la release `latest`.
