# windows-skripte

Sammlung kleiner PowerShell-Skripte zum Einrichten von Windows-PCs und -Servern.

## konsole/Install-Konsole.ps1

Richtet die PowerShell-Konsole mit [Oh My Posh](https://ohmyposh.dev) ein, sodass im
Prompt immer **Benutzer@Rechnername** steht. Das ist besonders praktisch, wenn man per
SSH zwischen mehreren Windows-Rechnern wechselt.

Das Skript läuft unter **Windows PowerShell 5.1** und **PowerShell 7** und lässt sich
beliebig oft ausführen, ohne dass Einträge doppelt angelegt werden.

### Installation (Einzeiler)

In einer PowerShell-Konsole (für `-SshStandardShell` als Administrator):

```powershell
irm https://raw.githubusercontent.com/Beseco/windows-skripte/main/konsole/Install-Konsole.ps1 | iex
```

Mit Schaltern, z. B. auf einem Server ohne Schrift und mit PowerShell 7 als SSH-Shell:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/Beseco/windows-skripte/main/konsole/Install-Konsole.ps1))) -OhneSchrift -SshStandardShell
```

Falls die Execution Policy noch auf `Restricted` steht, funktioniert `irm | iex`
trotzdem: Das Skript wird dabei nicht als Datei ausgeführt. Es setzt die Richtlinie dann
selbst auf `RemoteSigned`.

Alternativ aus dem geklonten Repo:

```powershell
git clone https://github.com/Beseco/windows-skripte.git
powershell -ExecutionPolicy Bypass -File .\windows-skripte\konsole\Install-Konsole.ps1
```

Danach eine **neue Konsole öffnen** bzw. die SSH-Verbindung neu aufbauen.

### Was das Skript macht

1. **Execution Policy** `CurrentUser` → `RemoteSigned`, getrennt für 5.1 und 7, falls nötig.
2. **Oh My Posh** per `winget install JanDeDobbeleer.OhMyPosh` installieren, falls es fehlt.
   Ohne winget (z. B. auf älteren Servern) wird das offizielle Installationsskript von
   ohmyposh.dev genutzt. Danach wird der `PATH` der laufenden Sitzung aktualisiert.
3. **Nerd Font** `MesloLGM Nerd Font` installieren (`oh-my-posh font install meslo`).
4. **Theme** `paradox.omp.json` aus diesem Repo nach `$HOME\.config\oh-my-posh\` kopieren.
   Das Session-Segment zeigt ` {{ .UserName }}@{{ .HostName }} `. Wird das Skript ohne Repo
   ausgeführt, lädt es das Theme aus diesem Repo herunter, ersatzweise das Original von
   Oh My Posh, und setzt das Session-Template dann selbst.
5. **Profile** von PowerShell 5.1 (`Dokumente\WindowsPowerShell\Microsoft.PowerShell_profile.ps1`)
   und 7 (`Dokumente\PowerShell\Microsoft.PowerShell_profile.ps1`) bekommen die Zeile

   ```powershell
   oh-my-posh init pwsh --config "$HOME\.config\oh-my-posh\paradox.omp.json" | Invoke-Expression
   ```

   Alte `oh-my-posh init`-Zeilen (z. B. mit `$env:POSH_THEMES_PATH`) werden ersetzt.
   Fehlende Profile werden angelegt. Ein auf OneDrive umgeleiteter Dokumente-Ordner wird
   berücksichtigt.
6. **Windows Terminal**: Schrift in `profiles.defaults.font.face` auf `MesloLGM Nerd Font`
   setzen, wenn Terminal und Schrift vorhanden sind.
7. Optional **OpenSSH-Standardshell** `HKLM:\SOFTWARE\OpenSSH\DefaultShell` → `pwsh.exe`.
8. `oh-my-posh cache clear`.

Jede Datei, die das Skript ändert (Profil, Theme, Terminal-`settings.json`), wird vorher als
`*.bak-JJJJMMTT-hhmmss` gesichert.

### Schalter

| Schalter               | Wirkung                                                                                  |
|------------------------|------------------------------------------------------------------------------------------|
| `-OhneSchrift`         | Keine Nerd-Font-Installation. Auf Servern, die man nur per SSH nutzt, ist sie unnötig.    |
| `-OhneTerminalSchrift` | Die Schrift in Windows Terminal bleibt unverändert.                                      |
| `-SshStandardShell`    | PowerShell 7 wird Standard-Shell für OpenSSH (nur als Admin, nur mit installiertem pwsh). |
| `-WhatIf`              | Trockenlauf: zeigt, was geändert würde, ändert aber nichts.                              |

### Hinweis zu SSH

Den Prompt zeichnet bei einer SSH-Verbindung der **entfernte** Rechner. Das Skript muss also
auf jedem Server laufen, auf den man sich verbindet (dort am besten mit `-OhneSchrift`).
Die Nerd Font braucht dagegen nur der **Client**, also der Rechner, auf dem das Terminal
läuft.

### Fehlerbehebung

- **„CONFIG NOT FOUND“**: Die Profilzeile verweist auf ein Theme, das nicht existiert, oft
  über `$env:POSH_THEMES_PATH`. Als App-Paket installiert setzt Oh My Posh diese Variable
  nicht. Das Skript erneut ausführen, dann wird die Zeile ersetzt.
- **Kästchen statt Symbole**: Im Terminal `MesloLGM Nerd Font` als Schrift wählen. Bei SSH
  gilt das für den Client.
- **„Ausführung von Skripts ist deaktiviert“**: Die Execution Policy steht noch auf
  `Restricted`. Das Skript per `irm | iex` ausführen, dann setzt es `RemoteSigned`.
