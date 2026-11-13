# Profili VM Setup Suite

Un profilo e' un file JSON in questa cartella (i file che iniziano con `_` vengono ignorati). Tutte le sezioni sono facoltative.

```json
{
  "Nome": "Ufficio", "Descrizione": "PC amministrazione",
  "Apps": ["Google.Chrome", "7zip.7zip", {"Id": "Microsoft.Office", "Override": "/configure config.xml"}],   // ID winget (winget search <nome>)
  "RimuoviApp": ["Microsoft.XboxApp", "Clipchamp.Clipchamp"],        // nomi pacchetti Appx (Get-AppxPackage)
  "DebloatNuoviUtenti": true,                                          // Win11Debloat con -Sysprep (solo se il passo Debloat e' attivo)
  "Impostazioni": { "FusoOrario": "W. Europe Standard Time", "EstensioniFile": true, "FileNascosti": false, "EsploraFileSuQuestoPC": true,
                    "MenuContestualeClassico": true, "BarraSinistra": true, "RicercaBarra": 1, "NoWidget": true, "NoCopilot": true,
                    "NoSuggerimenti": true, "Telemetria": 1, "DesktopRemoto": false, "SMB1": false, "AvvioRapido": false, "Ibernazione": false,
                    "IndividuazioneRete": true, "DisattivaBlocco": false },
  "Energia": { "Piano": "Bilanciato|Prestazioni|Risparmio", "SpegnimentoSchermoMin": {"AC": 15, "DC": 5}, "SospensioneMin": {"AC": 0, "DC": 30}, "NoSospensioneDisco": true, "PulsanteAlimentazioneSpegne": true },
  "Stampanti": [ {"Nome": "HP Ufficio", "IP": "192.168.1.50", "Driver": "HP Universal Printing PCL 6", "InfPath": "\\\\server\\driver\\hpcu.inf", "Predefinita": true},
                 {"Condivisa": "\\\\SERVER\\Magazzino"} ],
  "Unita": [ {"Lettera": "S", "Percorso": "\\\\server\\dati"} ],
  "Utenti": [ {"Nome": "ufficio", "NomeCompleto": "Postazione ufficio", "Admin": false, "Password": "lascia vuoto e inseriscila nella GUI"} ],
  "Collegamenti": [ {"Nome": "Gestionale", "Url": "https://gestionale.azienda.it"}, {"Nome": "Documenti", "Percorso": "S:\\Documenti"} ],
  "Sfondo": "sfondo-aziendale.jpg"       // relativo alla cartella Profili o percorso assoluto
}
```
Per trovare gli ID: `winget search chrome`. Per i pacchetti Appx: `Get-AppxPackage | Select Name`.
Le password nel JSON sono sconsigliate: la GUI chiede quella del nuovo utente.
