<#
.SYNOPSIS
    Richtet die PowerShell-Konsole mit Oh My Posh ein (Windows PowerShell 5.1 und PowerShell 7).

.DESCRIPTION
    - PowerShell 7 pruefen: fehlt es oder ist es veraltet, wird gefragt, ob es installiert/aktualisiert werden soll
    - Execution Policy CurrentUser -> RemoteSigned (fuer 5.1 und 7)
    - Oh My Posh installieren (winget, sonst offizielles Installationsskript)
    - Nerd Font "Meslo" installieren (abschaltbar mit -OhneSchrift)
    - Theme paradox.omp.json (zeigt Benutzer@Rechner) nach $HOME\.config\oh-my-posh
    - Init-Zeile in die Profile von PowerShell 5.1 und 7 eintragen
    - Windows-Terminal-Schrift auf "MesloLGM Nerd Font" setzen (wenn Terminal + Schrift vorhanden)
    - optional: PowerShell 7 als Standard-Shell fuer OpenSSH (-SshStandardShell, nur als Admin)

    Das Skript ist idempotent: mehrfaches Ausfuehren erzeugt keine Doppeleintraege.
    Geaenderte Dateien (Profil, Theme, Terminal-Einstellungen) werden vorher als *.bak-<Zeitstempel> gesichert.

.PARAMETER OhneSchrift
    Keine Nerd-Font-Installation (sinnvoll auf Servern, die nur per SSH genutzt werden:
    die Schrift wird nur auf dem Client gebraucht, der das Terminal anzeigt).

.PARAMETER OhneTerminalSchrift
    Die Schrift in Windows Terminal nicht anpassen.

.PARAMETER SshStandardShell
    Setzt HKLM:\SOFTWARE\OpenSSH\DefaultShell auf pwsh.exe (nur als Administrator,
    nur wenn PowerShell 7 installiert ist).

.PARAMETER PowerShell7
    PowerShell 7 ohne Rueckfrage installieren bzw. aktualisieren, wenn es fehlt oder veraltet ist.

.PARAMETER OhnePowerShell7
    PowerShell 7 weder pruefen noch nachfragen.

.EXAMPLE
    .\Install-Konsole.ps1

.EXAMPLE
    .\Install-Konsole.ps1 -OhneSchrift -SshStandardShell

.EXAMPLE
    .\Install-Konsole.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interaktives Einrichtungsskript')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingInvokeExpression', '', Justification = 'Offizielles Oh-My-Posh-Installationsskript als Rueckfallebene')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Parameter werden in den Funktionen ueber den Skriptbereich gelesen')]
param(
    [switch]$OhneSchrift,
    [switch]$OhneTerminalSchrift,
    [switch]$SshStandardShell,
    [switch]$PowerShell7,
    [switch]$OhnePowerShell7,
    # Nur fuer Tests: anderer Dokumente-Ordner fuer die Profile
    [Parameter(DontShow)]
    [string]$DokumentePfad
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$ThemeName     = 'paradox.omp.json'
$ThemeOrdner   = Join-Path $HOME '.config\oh-my-posh'
$ThemeZiel     = Join-Path $ThemeOrdner $ThemeName
$ThemeUrls     = @(
    'https://raw.githubusercontent.com/Beseco/windows-skripte/main/konsole/paradox.omp.json',
    'https://raw.githubusercontent.com/JanDeDobbeleer/oh-my-posh/main/themes/paradox.omp.json'
)
$ExeUrl        = 'https://raw.githubusercontent.com/Beseco/windows-skripte/main/konsole/bin/oh-my-posh.exe'
$SessionTemplate =' {{ .UserName }}@{{ .HostName }} '
$InitZeile     = 'oh-my-posh init pwsh --config "$HOME\.config\oh-my-posh\paradox.omp.json" | Invoke-Expression'
$SchriftName   = 'MesloLGM Nerd Font'
$Zeitstempel   = Get-Date -Format 'yyyyMMdd-HHmmss'
$Utf8OhneBom   = New-Object System.Text.UTF8Encoding($false)
$Utf8MitBom    = New-Object System.Text.UTF8Encoding($true)

# Aeltere Server sprechen sonst kein TLS 1.2
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { Write-Verbose 'TLS 1.2 konnte nicht aktiviert werden.' }

# ---------------------------------------------------------------- Hilfsfunktionen

function Write-Schritt([string]$Text) { Write-Host "`n==> $Text" -ForegroundColor Cyan }
function Write-Ok([string]$Text)      { Write-Host "    [ok] $Text" -ForegroundColor Green }
function Write-Info([string]$Text)    { Write-Host "    $Text" }
function Write-Warnung([string]$Text) { Write-Host "    [!] $Text" -ForegroundColor Yellow }

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Initialize-SitzungsPfad {
    $teile = @(
        [Environment]::GetEnvironmentVariable('Path', 'Machine'),
        [Environment]::GetEnvironmentVariable('Path', 'User'),
        (Join-Path $env:LOCALAPPDATA 'Programs\oh-my-posh\bin'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps')
    ) | Where-Object { $_ }
    $env:Path = (($teile -join ';') -split ';' | Where-Object { $_ } | Select-Object -Unique) -join ';'
}

function Get-OhMyPosh {
    $cmd = Get-Command oh-my-posh -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    return $null
}

function Get-Pwsh {
    # Maschinenweite Installation (MSI, Program Files) bevorzugen, sonst was im PATH liegt (z. B. MSIX/Store)
    $std = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
    if (Test-Path $std) { return $std }
    $cmd = Get-Command pwsh -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    return $null
}

function Save-Sicherung([string]$Pfad) {
    if (Test-Path $Pfad) {
        $bak = "$Pfad.bak-$Zeitstempel"
        Copy-Item -LiteralPath $Pfad -Destination $bak -Force
        Write-Info "Sicherung: $bak"
    }
}

function Test-NerdFont {
    $schluessel = @(
        'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts',
        'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
    )
    foreach ($k in $schluessel) {
        $props = Get-ItemProperty -Path $k -ErrorAction SilentlyContinue
        if ($props -and ($props.PSObject.Properties.Name -match "^$([regex]::Escape($SchriftName)) ")) { return $true }
    }
    return $false
}

# ---------------------------------------------------------------- 0. PowerShell 7

function Get-Pwsh7Version {
    # Installierte PowerShell-7-Version oder $null
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        return [version]('{0}.{1}.{2}' -f $PSVersionTable.PSVersion.Major, $PSVersionTable.PSVersion.Minor, $PSVersionTable.PSVersion.Patch)
    }
    $pwsh = Get-Pwsh
    if (-not $pwsh) { return $null }
    $text = Invoke-AnderePowerShell -Exe $pwsh -Befehl '$v = $PSVersionTable.PSVersion; "{0}.{1}.{2}" -f $v.Major, $v.Minor, $v.Patch'
    if ($text -match '^\d+\.\d+\.\d+$') { return [version]$text }
    return $null
}

function Get-Pwsh7Aktuell([ValidateSet('stable', 'lts')][string]$Kanal) {
    # Aktuelle Version des Kanals: zuerst Microsoft (aka.ms), fuer 'stable' ersatzweise GitHub-API
    try {
        $info = Invoke-RestMethod -Uri "https://aka.ms/pwsh-buildinfo-$Kanal" -UseBasicParsing -TimeoutSec 15
        if ("$($info.ReleaseTag)" -match '^v?(\d+\.\d+\.\d+)$') { return [version]$Matches[1] }
    } catch { Write-Verbose "aka.ms nicht erreichbar: $($_.Exception.Message)" }
    if ($Kanal -eq 'stable') {
        try {
            $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/PowerShell/PowerShell/releases/latest' -UseBasicParsing -TimeoutSec 15
            if ("$($rel.tag_name)" -match '^v?(\d+\.\d+\.\d+)$') { return [version]$Matches[1] }
        } catch { Write-Verbose "GitHub-API nicht erreichbar: $($_.Exception.Message)" }
    }
    return $null
}

function Read-JaNein([string]$Frage) {
    # $true bei Ja (Standard), $false bei Nein oder wenn keine Eingabe moeglich ist (z. B. -NonInteractive)
    try {
        $antwort = Read-Host "    $Frage [J/n]"
    } catch {
        Write-Info 'Keine Eingabe moeglich - uebersprungen (mit -PowerShell7 ohne Rueckfrage installieren).'
        return $false
    }
    return ("$antwort".Trim() -eq '' -or "$antwort".Trim() -match '^(j|ja|y|yes)$')
}

function Install-Pwsh7Msi([version]$Version) {
    # Maschinenweite Installation/Aktualisierung per MSI aus dem offiziellen Release (nur mit Microsoft-Signatur)
    $arch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    $arch = switch ($arch) { 'ARM64' { 'arm64' } 'x86' { 'x86' } default { 'x64' } }
    $name = "PowerShell-$Version-win-$arch.msi"
    $url = "https://github.com/PowerShell/PowerShell/releases/download/v$Version/$name"
    $msi = Join-Path $env:TEMP $name
    try {
        Write-Info "Lade $url ..."
        try { (New-Object System.Net.WebClient).DownloadFile($url, $msi) }
        catch { Write-Warnung "Download fehlgeschlagen: $($_.Exception.Message)"; return $false }

        $sig = Get-AuthenticodeSignature -FilePath $msi
        if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
            Write-Warnung "Signatur ungueltig ($($sig.Status)) - MSI wird nicht ausgefuehrt."
            return $false
        }
        Write-Info 'Installiere (msiexec, still) ...'
        $argumente = @('/i', "`"$msi`"", '/quiet', '/norestart', 'ADD_PATH=1', 'USE_MU=1', 'ENABLE_MU=1')
        $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList $argumente -Wait -PassThru
        switch ($proc.ExitCode) {
            0       { return $true }
            3010    { Write-Warnung 'Installiert - ein Neustart des Rechners ist noetig.'; return $true }
            1641    { Write-Warnung 'Installiert - Neustart wurde eingeleitet.'; return $true }
            default { Write-Warnung "msiexec beendet mit Code $($proc.ExitCode)."; return $false }
        }
    } finally {
        if (Test-Path $msi) { Remove-Item -LiteralPath $msi -Force -ErrorAction SilentlyContinue }
    }
}

function Install-Pwsh7Winget([bool]$Vorhanden) {
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) { Write-Warnung 'winget nicht vorhanden.'; return $false }
    $aktion = if ($Vorhanden) { 'upgrade' } else { 'install' }
    Write-Info "winget $aktion Microsoft.PowerShell ..."
    & $winget.Source $aktion --id Microsoft.PowerShell -e --source winget --silent --accept-source-agreements --accept-package-agreements
    return ($LASTEXITCODE -eq 0)
}

function Update-PowerShell7 {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    Write-Schritt 'PowerShell 7'

    if ($OhnePowerShell7) { Write-Info 'uebersprungen (-OhnePowerShell7)'; return }

    # Ab 7.7 liefert Microsoft kein MSI mehr, nur noch MSIX (pro Benutzer, nicht in Program Files).
    # Als Admin daher die neueste LTS-Version per MSI: fuer alle Benutzer, als SSH-Shell nutzbar,
    # Updates ueber Microsoft Update. Ohne Admin: neueste stabile Version per winget (MSIX).
    $admin = Test-Admin
    $installiert = Get-Pwsh7Version
    $aktuell = $null
    $perMsi = $false
    if ($admin) {
        $aktuell = Get-Pwsh7Aktuell lts
        $perMsi = [bool]$aktuell
    }
    if (-not $aktuell) { $aktuell = Get-Pwsh7Aktuell stable }
    if (-not $aktuell) {
        if ($installiert) { Write-Ok "installiert: $installiert (aktuelle Version nicht ermittelbar)" }
        else { Write-Warnung 'nicht installiert; aktuelle Version nicht ermittelbar (kein Internet?) - uebersprungen' }
        return
    }
    $art = if ($perMsi) { 'LTS, fuer alle Benutzer' } else { 'fuer diesen Benutzer' }
    if ($installiert -and $installiert -ge $aktuell) { Write-Ok "aktuell: $installiert"; return }

    if ($installiert) { $text = "PowerShell $installiert ist installiert, aktuell ist $aktuell ($art)." ; $frage = "Auf $aktuell aktualisieren?" }
    else { $text = "PowerShell 7 ist nicht installiert (aktuell: $aktuell, $art)."; $frage = "PowerShell $aktuell installieren?" }
    Write-Info $text

    if ($WhatIfPreference) {
        $null = $PSCmdlet.ShouldProcess("PowerShell $aktuell", 'Installieren/Aktualisieren')
        return
    }
    if (-not $PowerShell7 -and -not (Read-JaNein $frage)) { Write-Info 'nicht installiert'; return }
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        Write-Warnung 'Dieses Skript laeuft selbst in PowerShell 7 - das Update kann einen Neustart der Konsole oder des Rechners verlangen.'
    }

    $ok = $false
    if ($perMsi) { $ok = Install-Pwsh7Msi $aktuell }
    elseif (-not $admin) { Write-Info 'Ohne Administratorrechte: Installation fuer den aktuellen Benutzer ueber winget.' }
    if (-not $ok) { $ok = Install-Pwsh7Winget ([bool]$installiert) }

    Initialize-SitzungsPfad
    $neu = Get-Pwsh7Version
    if ($neu -and $neu -ge $aktuell) { Write-Ok "PowerShell $neu installiert: $(Get-Pwsh)" }
    elseif ($neu) { Write-Warnung "Installiert ist weiterhin $neu - Installation fehlgeschlagen oder Neustart noetig." }
    else { Write-Warnung 'PowerShell 7 konnte nicht installiert werden (Internet/Proxy? Als Administrator versuchen).' }
}

# ---------------------------------------------------------------- 1. Execution Policy

function Set-Ausfuehrungsrichtlinie {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    Write-Schritt 'Execution Policy (CurrentUser)'

    $erlaubt = @('RemoteSigned', 'Unrestricted', 'Bypass')

    # Aktuelle PowerShell-Version
    $aktuell = Get-ExecutionPolicy -Scope CurrentUser
    if ($erlaubt -contains "$aktuell") {
        Write-Ok "PowerShell $($PSVersionTable.PSVersion.Major): bereits $aktuell"
    } elseif ($PSCmdlet.ShouldProcess("PowerShell $($PSVersionTable.PSVersion.Major) CurrentUser", 'Execution Policy RemoteSigned')) {
        try {
            Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force -ErrorAction Stop
        } catch {
            # Meldung "durch eine Richtlinie mit spezifischerem Bereich ueberschrieben" ist kein Fehler
            if ($_.FullyQualifiedErrorId -notlike '*ExecutionPolicyOverride*') { throw }
            Write-Warnung 'Eine Gruppenrichtlinie ueberschreibt die Einstellung.'
        }
        Write-Ok "PowerShell $($PSVersionTable.PSVersion.Major): RemoteSigned gesetzt"
    }

    # Die jeweils andere Version speichert ihre Richtlinie getrennt (5.1: Registry, 7: powershell.config.json)
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        $andere = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $name = 'Windows PowerShell 5.1'
    } else {
        $andere = Get-Pwsh
        $name = 'PowerShell 7'
    }
    if (-not $andere -or -not (Test-Path $andere)) {
        Write-Info "$name nicht installiert - uebersprungen"
        return
    }
    $abfrage = 'Get-ExecutionPolicy -Scope CurrentUser'
    $wert = Invoke-AnderePowerShell -Exe $andere -Befehl $abfrage
    if ($erlaubt -contains $wert) {
        Write-Ok "${name}: bereits $wert"
    } elseif ($PSCmdlet.ShouldProcess("$name CurrentUser", 'Execution Policy RemoteSigned')) {
        $null = Invoke-AnderePowerShell -Exe $andere -Befehl 'Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force -ErrorAction SilentlyContinue'
        $wert = Invoke-AnderePowerShell -Exe $andere -Befehl $abfrage
        if ($erlaubt -contains $wert) { Write-Ok "${name}: RemoteSigned gesetzt" }
        else { Write-Warnung "${name}: konnte nicht gesetzt werden (aktuell: $wert)" }
    }
}

function Invoke-AnderePowerShell {
    # Startet die jeweils andere PowerShell. -EncodedCommand umgeht die Anfuehrungszeichen-Probleme
    # beim Uebergeben von Argumenten an native Programme unter 5.1; Fehlerausgaben brechen nicht ab.
    param([string]$Exe, [string]$Befehl)
    $kodiert = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Befehl))
    $altEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $ausgabe = & $Exe -NoProfile -NonInteractive -OutputFormat Text -EncodedCommand $kodiert 2>&1 |
            Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } |
            ForEach-Object { "$_".Trim() } | Where-Object { $_ }
    } catch {
        $ausgabe = @()
    } finally {
        $ErrorActionPreference = $altEap
    }
    return "$(@($ausgabe) | Select-Object -Last 1)"
}

# ---------------------------------------------------------------- 2. Oh My Posh

function Install-OhMyPosh {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    Write-Schritt 'Oh My Posh'

    $omp = Get-OhMyPosh
    if ($omp) {
        Write-Ok "vorhanden: $omp ($(& $omp version))"
        return
    }
    if (-not $PSCmdlet.ShouldProcess('Oh My Posh', 'Installieren')) { return }

    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if ($winget) {
        Write-Info 'Installiere ueber winget ...'
        & $winget.Source install --id JanDeDobbeleer.OhMyPosh -e --source winget --silent --accept-source-agreements --accept-package-agreements
        Initialize-SitzungsPfad
        $omp = Get-OhMyPosh
    }
    if (-not $omp) {
        if ($winget) { Write-Warnung 'winget-Installation ohne Erfolg - versuche offizielles Installationsskript.' }
        else { Write-Info 'winget nicht vorhanden - nutze offizielles Installationsskript (ohmyposh.dev).' }
        try {
            $skript = (New-Object System.Net.WebClient).DownloadString('https://ohmyposh.dev/install.ps1')
            # Eigener Bereich: StrictMode/ErrorAction dieses Skripts duerfen das fremde Skript nicht treffen
            # (es fragt z. B. $IsMacOS ab, das es unter 5.1 nicht gibt)
            & {
                Set-StrictMode -Off
                $ErrorActionPreference = 'Continue'
                Invoke-Expression $skript
            }
        } catch {
            Write-Warnung "Offizielles Installationsskript fehlgeschlagen: $($_.Exception.Message)"
        }
        Initialize-SitzungsPfad
        $omp = Get-OhMyPosh
    }
    if (-not $omp) {
        Write-Warnung 'Nutze die mitgelieferte oh-my-posh.exe aus dem Repo.'
        $omp = Install-OhMyPoshExe
    }
    if (-not $omp) { throw 'Oh My Posh konnte nicht installiert werden.' }
    Write-Ok "installiert: $omp"
}

function Install-OhMyPoshExe {
    # Dritte Rueckfallebene: eigenstaendige exe aus diesem Repo (konsole\bin) nach
    # %LOCALAPPDATA%\Programs\oh-my-posh\bin kopieren und in den Benutzer-PATH eintragen.
    # Nur mit gueltiger Signatur von Jan De Dobbeleer.
    $zielOrdner = Join-Path $env:LOCALAPPDATA 'Programs\oh-my-posh\bin'
    $ziel = Join-Path $zielOrdner 'oh-my-posh.exe'
    if (-not (Test-Path $zielOrdner)) { New-Item -ItemType Directory -Path $zielOrdner -Force | Out-Null }

    $tmp = Join-Path $env:TEMP ("oh-my-posh-{0}.exe" -f [Guid]::NewGuid().ToString('N'))
    try {
        $lokal = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'bin\oh-my-posh.exe' } else { $null }
        if ($lokal -and (Test-Path $lokal)) {
            Write-Info "Quelle: $lokal"
            Copy-Item -LiteralPath $lokal -Destination $tmp -Force
        } else {
            Write-Info "Quelle: $ExeUrl"
            try { (New-Object System.Net.WebClient).DownloadFile($ExeUrl, $tmp) }
            catch { Write-Warnung "Download fehlgeschlagen: $($_.Exception.Message)"; return $null }
        }

        $sig = Get-AuthenticodeSignature -FilePath $tmp
        if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'De Dobbeleer') {
            Write-Warnung "Signatur ungueltig ($($sig.Status)) - exe wird nicht verwendet."
            return $null
        }
        Move-Item -LiteralPath $tmp -Destination $ziel -Force
    } finally {
        if (Test-Path $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }

    # Benutzer-PATH dauerhaft ergaenzen (Rohwert lesen, damit %VARIABLEN% erhalten bleiben)
    $envKey = Get-Item -Path 'HKCU:\Environment'
    $roh = [string]$envKey.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    $eintraege = @($roh -split ';' | Where-Object { $_ })
    $vorhanden = $eintraege | Where-Object { [Environment]::ExpandEnvironmentVariables($_).TrimEnd('\') -ieq $zielOrdner.TrimEnd('\') }
    if (-not $vorhanden) {
        $neu = (@($eintraege) + $zielOrdner) -join ';'
        Set-ItemProperty -Path 'HKCU:\Environment' -Name Path -Value $neu -Type ExpandString
        # Explorer/neue Fenster benachrichtigen (SetEnvironmentVariable sendet WM_SETTINGCHANGE)
        [Environment]::SetEnvironmentVariable('HPD_PFAD_AKTUALISIERT', '1', 'User')
        [Environment]::SetEnvironmentVariable('HPD_PFAD_AKTUALISIERT', $null, 'User')
        Write-Info "Benutzer-PATH ergaenzt: $zielOrdner"
    }
    Initialize-SitzungsPfad
    return (Get-OhMyPosh)
}

# ---------------------------------------------------------------- 3. Nerd Font

function Install-NerdFont {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    Write-Schritt 'Nerd Font (Meslo)'

    if ($OhneSchrift) { Write-Info 'uebersprungen (-OhneSchrift)'; return }
    if (Test-NerdFont) { Write-Ok "$SchriftName bereits installiert"; return }

    $omp = Get-OhMyPosh
    if (-not $omp) { Write-Warnung 'oh-my-posh fehlt - Schrift nicht installiert.'; return }
    if ($PSCmdlet.ShouldProcess($SchriftName, 'Schrift installieren')) {
        & $omp font install meslo
        if (Test-NerdFont) { Write-Ok "$SchriftName installiert" }
        else { Write-Warnung 'Schrift nach der Installation nicht gefunden - ggf. Abmelden/Neustart noetig.' }
    }
}

# ---------------------------------------------------------------- 4. Theme

function Get-ThemeInhalt {
    # 1. Theme neben dem Skript (Repo-Klon)
    if ($PSScriptRoot) {
        $lokal = Join-Path $PSScriptRoot $ThemeName
        if (Test-Path $lokal) {
            Write-Info "Quelle: $lokal"
            return [IO.File]::ReadAllText($lokal)
        }
    }
    # 2. Download (eigenes Repo, sonst Original)
    foreach ($url in $ThemeUrls) {
        try {
            $text = (New-Object System.Net.WebClient).DownloadString($url)
            Write-Info "Quelle: $url"
            return $text
        } catch {
            Write-Warnung "Download fehlgeschlagen: $url"
        }
    }
    throw 'Theme konnte weder lokal gefunden noch heruntergeladen werden.'
}

function ConvertTo-ThemeMitRechnername([string]$Json) {
    # Sicherstellen, dass das session-Segment Benutzer@Rechner zeigt
    $muster = '("template"\s*:\s*")[^"]*("\s*,\s*"type"\s*:\s*"session")'
    if ($Json -match $muster) {
        return [regex]::Replace($Json, $muster, { param($m) $m.Groups[1].Value + $SessionTemplate + $m.Groups[2].Value })
    }
    if ($Json -notmatch '\{\{\s*\.HostName\s*\}\}') {
        Write-Warnung 'Theme enthaelt kein session-Segment mit Rechnername - bitte Theme pruefen.'
    }
    return $Json
}

function Install-Theme {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    Write-Schritt "Theme $ThemeName"

    $neu = ConvertTo-ThemeMitRechnername (Get-ThemeInhalt)
    try { $null = $neu | ConvertFrom-Json } catch { throw "Theme ist kein gueltiges JSON: $_" }

    if (Test-Path $ThemeZiel) {
        $alt = [IO.File]::ReadAllText($ThemeZiel)
        if (($alt.Trim() -replace "`r`n", "`n") -ceq ($neu.Trim() -replace "`r`n", "`n")) {
            Write-Ok "unveraendert: $ThemeZiel"
            return
        }
    }
    if ($PSCmdlet.ShouldProcess($ThemeZiel, 'Theme schreiben')) {
        if (-not (Test-Path $ThemeOrdner)) { New-Item -ItemType Directory -Path $ThemeOrdner -Force | Out-Null }
        Save-Sicherung $ThemeZiel
        [IO.File]::WriteAllText($ThemeZiel, $neu, $Utf8OhneBom)
        Write-Ok "geschrieben: $ThemeZiel"
    }
}

# ---------------------------------------------------------------- 5. Profile

function Get-ProfilPfade {
    $doku = $DokumentePfad
    if (-not $doku) {
        # beruecksichtigt OneDrive-/Ordnerumleitung
        $doku = [Environment]::GetFolderPath('MyDocuments')
    }
    if (-not $doku) { $doku = Join-Path $HOME 'Documents' }
    return @(
        [pscustomobject]@{ Name = 'Windows PowerShell 5.1'; Pfad = Join-Path $doku 'WindowsPowerShell\Microsoft.PowerShell_profile.ps1' },
        [pscustomobject]@{ Name = 'PowerShell 7';           Pfad = Join-Path $doku 'PowerShell\Microsoft.PowerShell_profile.ps1' }
    )
}

function Set-ProfilZeile {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Name, [string]$Pfad)

    $zeilen = @()
    if (Test-Path $Pfad) { $zeilen = @(Get-Content -LiteralPath $Pfad) }

    # alte Oh-My-Posh-Init-Zeilen (z. B. mit $env:POSH_THEMES_PATH) ersetzen, nur eine behalten
    $neu = New-Object System.Collections.Generic.List[string]
    $eingetragen = $false
    foreach ($z in $zeilen) {
        if ($z -match '^\s*oh-my-posh(\.exe)?\s+init\s+' -or $z -match '^\s*&\s*.*oh-my-posh.*\binit\b') {
            if (-not $eingetragen) { $neu.Add($InitZeile); $eingetragen = $true }
            continue
        }
        $neu.Add($z)
    }
    if (-not $eingetragen) { $neu.Add($InitZeile) }

    if ((Test-Path $Pfad) -and (($zeilen -join "`n") -ceq ($neu -join "`n"))) {
        Write-Ok "${Name}: unveraendert ($Pfad)"
        return
    }
    if ($PSCmdlet.ShouldProcess($Pfad, "Profil $Name aktualisieren")) {
        $ordner = Split-Path $Pfad -Parent
        if (-not (Test-Path $ordner)) { New-Item -ItemType Directory -Path $ordner -Force | Out-Null }
        Save-Sicherung $Pfad
        # UTF-8 mit BOM: wird von 5.1 und 7 gleich gelesen
        [IO.File]::WriteAllText($Pfad, (($neu -join "`r`n") + "`r`n"), $Utf8MitBom)
        Write-Ok "${Name}: eingetragen ($Pfad)"
    }
}

function Set-Profile {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    Write-Schritt 'PowerShell-Profile'
    foreach ($p in Get-ProfilPfade) { Set-ProfilZeile -Name $p.Name -Pfad $p.Pfad }
}

# ---------------------------------------------------------------- 6. Windows Terminal

function Set-TerminalSchrift {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    Write-Schritt 'Windows-Terminal-Schrift'

    if ($OhneTerminalSchrift) { Write-Info 'uebersprungen (-OhneTerminalSchrift)'; return }
    if (-not (Test-NerdFont) -and -not $WhatIfPreference) { Write-Info "$SchriftName nicht installiert - uebersprungen"; return }

    $dateien = @(
        (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'),
        (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\settings.json')
    ) | Where-Object { Test-Path $_ }

    if (-not $dateien) { Write-Info 'Windows Terminal nicht gefunden - uebersprungen'; return }

    foreach ($datei in $dateien) {
        $text = [IO.File]::ReadAllText($datei)
        try { $cfg = $text | ConvertFrom-Json }
        catch { Write-Warnung "nicht lesbar (Kommentare?) - bitte manuell setzen: $datei"; continue }

        if (-not $cfg.PSObject.Properties['profiles'] -or $cfg.profiles -is [array]) {
            Write-Warnung "unbekanntes Format - bitte manuell setzen: $datei"; continue
        }
        $profile_ = $cfg.profiles
        if (-not $profile_.PSObject.Properties['defaults']) {
            $profile_ | Add-Member -NotePropertyName defaults -NotePropertyValue ([pscustomobject]@{})
        }
        $def = $profile_.defaults
        if (-not $def.PSObject.Properties['font']) {
            $def | Add-Member -NotePropertyName font -NotePropertyValue ([pscustomobject]@{})
        }
        if ($def.font.PSObject.Properties['face'] -and $def.font.face -eq $SchriftName) {
            Write-Ok "bereits gesetzt: $datei"; continue
        }
        if ($PSCmdlet.ShouldProcess($datei, "Schrift '$SchriftName' setzen")) {
            if ($def.font.PSObject.Properties['face']) { $def.font.face = $SchriftName }
            else { $def.font | Add-Member -NotePropertyName face -NotePropertyValue $SchriftName }
            Save-Sicherung $datei
            [IO.File]::WriteAllText($datei, ($cfg | ConvertTo-Json -Depth 64), $Utf8OhneBom)
            Write-Ok "gesetzt: $datei"
        }
    }
}

# ---------------------------------------------------------------- 7. OpenSSH-Standardshell

function Set-SshStandardShell {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    Write-Schritt 'OpenSSH-Standardshell'

    if (-not $SshStandardShell) { Write-Info 'nicht angefordert (-SshStandardShell)'; return }
    if (-not (Test-Admin)) { Write-Warnung 'nur als Administrator moeglich - uebersprungen'; return }
    $pwsh = Get-Pwsh
    if (-not $pwsh) { Write-Warnung 'PowerShell 7 (pwsh.exe) nicht installiert - uebersprungen'; return }
    if ($pwsh -like '*\WindowsApps\*') {
        Write-Warnung "PowerShell 7 ist nur fuer diesen Benutzer installiert ($pwsh) - als SSH-Shell ungeeignet. Skript als Administrator mit -PowerShell7 ausfuehren (MSI-Installation)."
        return
    }

    $key = 'HKLM:\SOFTWARE\OpenSSH'
    $aktuell = (Get-ItemProperty -Path $key -Name DefaultShell -ErrorAction SilentlyContinue).DefaultShell
    if ($aktuell -eq $pwsh) { Write-Ok "bereits $pwsh"; return }
    if ($PSCmdlet.ShouldProcess("$key\DefaultShell", "auf $pwsh setzen")) {
        if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
        New-ItemProperty -Path $key -Name DefaultShell -Value $pwsh -PropertyType String -Force | Out-Null
        Write-Ok "DefaultShell = $pwsh (gilt fuer neue SSH-Verbindungen)"
    }
}

# ---------------------------------------------------------------- 8. Cache

function Clear-OmpCache {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    Write-Schritt 'Oh-My-Posh-Cache'
    $omp = Get-OhMyPosh
    if (-not $omp) { Write-Info 'oh-my-posh fehlt - uebersprungen'; return }
    if ($PSCmdlet.ShouldProcess('oh-my-posh', 'cache clear')) {
        & $omp cache clear | Out-Null
        Write-Ok 'geleert'
    }
}

# ---------------------------------------------------------------- Ablauf

Write-Host "Konsole einrichten: $env:USERNAME@$env:COMPUTERNAME (PowerShell $($PSVersionTable.PSVersion))" -ForegroundColor White
if ($WhatIfPreference) { Write-Host '(Trockenlauf: -WhatIf, es wird nichts geaendert)' -ForegroundColor Yellow }

Initialize-SitzungsPfad
Update-PowerShell7
Set-Ausfuehrungsrichtlinie
Install-OhMyPosh
Install-NerdFont
Install-Theme
Set-Profile
Set-TerminalSchrift
Set-SshStandardShell
Clear-OmpCache

Write-Host "`nFertig. Neue Konsole oeffnen (bzw. SSH neu verbinden), damit der Prompt erscheint." -ForegroundColor Green
if (-not $OhneSchrift) {
    Write-Host "Im Terminal als Schrift '$SchriftName' waehlen, falls Symbole als Kaestchen erscheinen." -ForegroundColor Green
}
