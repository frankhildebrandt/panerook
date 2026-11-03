<img src="assets/icon.svg" width="64" height="64" alt="">

# PaneRook

Ein nativer macOS-Dateimanager, inspiriert von Midnight Commander. Zwei unabhängige Panels, direkte Tastaturbedienung und native macOS-Integration. Swift + AppKit, mit Sparkle für App-Updates und eingebettetem Ghostty-Terminal.

## Download

[Projektseite](https://frankhildebrandt.github.io/panerook/) · [Aktueller Release](https://github.com/frankhildebrandt/panerook/releases/latest)

Version **0.3.1** öffnet Remote-Verbindungen im ausgewählten Panel und bietet einen gemeinsamen Einstellungsdialog mit Themes und frei belegbaren Tastenkürzeln. PaneRook unterstützt Apple Silicon und Intel ab macOS 14. Installation und Bedienung stehen in der [Dokumentation](https://frankhildebrandt.github.io/panerook/dokumentation/).

## Starten

Voraussetzungen: macOS 14 oder neuer und Xcode 26 oder neuer mit ausgewählter Command Line Toolchain.

```sh
make dev
```

Das Makefile bietet folgende Targets:

| Aufruf | Aktion |
| --- | --- |
| `make run` | Optimiertes App-Bundle bauen und starten |
| `make dev` | Debug-App starten, Änderungen beobachten und nach erfolgreichem Build neu starten |
| `make build` | Optimiertes App-Bundle unter `build/PaneRook.app` bauen (auch Standard für `make`) |
| `make test` | Swift-Tests und Appcast-Prüfung ausführen |
| `make clean` | SwiftPM-Buildprodukte und den Ordner `build/` entfernen |

Die Build-Targets verwenden `scripts/build-app.sh`.
`make dev` prüft im Sekundentakt `Sources/`, `Resources/`, `scripts/`, das Makefile sowie `Package.swift` und `Package.resolved`, ohne zusätzliche Watcher-Abhängigkeit. Bei Buildfehlern läuft die zuletzt gestartete App weiter; die nächste Änderung löst einen neuen Versuch aus. `Ctrl-C` beendet den Watcher und die von ihm gestartete App. Beim Neustart wird diese App beendet; laufende Dateioperationen vorher abschließen.

Für Entwicklung in Xcode: `open Package.swift`, Scheme **PaneRook** ausführen. Das Skript erzeugt zusätzlich das eigentliche App-Bundle und signiert es ohne weitere Konfiguration lokal ad hoc.

SwiftPM lädt die festgelegte Sparkle-Version **2.10.0** sowie **libghostty-spm 1.5.2** (Ghostty **1.3.1**, MIT) beim ersten Build. Ghostty wird statisch verlinkt; das Buildskript legt Shell-Integration, Terminfo und Lizenztexte ins App-Bundle. Das Buildskript bettet außerdem das Sparkle-Framework und seine Helfer in das App-Bundle ein und signiert sie. Ohne `PANEROOK_SPARKLE_PUBLIC_KEY` bleiben Update-Funktionen im Entwicklungsbuild deaktiviert; das gilt auch beim Start des bloßen SwiftPM-Executables.

Für ein Universal-DMG und ein Universal-ZIP inklusive eigener SHA-256-Prüfsummen:

```sh
./scripts/package-release.sh
```

Die Pakete liegen unter `build/release/`. Das DMG enthält `PaneRook.app` und eine Verknüpfung zum Programme-Ordner. Das Skript baut beide Architekturen und prüft die App-Signatur sowie das Disk-Image. Eine optionale Versionsangabe (`./scripts/package-release.sh 0.3.1`) muss mit `Resources/Info.plist` übereinstimmen.

Für das Paketieren müssen zusätzlich `PANEROOK_SPARKLE_PUBLIC_KEY` und `PANEROOK_SPARKLE_PRIVATE_KEY` gesetzt sein. Die einmalige Einrichtung steht unter [Update-Signierung](docs/signing.md#sparkle-update-signierung). Das Skript erstellt außerdem `appcast.xml` für GitHub Releases und prüft, dass Update-Signatur und eingebetteter öffentlicher Schlüssel zusammenpassen.

Für Release-Builds ist ein **Developer ID Application**-Zertifikat für **Frank Hildebrandt (4R24354Z88)** eingerichtet. Der zugehörige private Schlüssel und der eigene Schlüsselbund liegen verschlüsselt außerhalb des Repositorys unter `~/Library/Application Support/PaneRook/Signing/DeveloperID/`. Für einen lokalen Build mit dieser Identität:

```sh
signing_directory="$HOME/Library/Application Support/PaneRook/Signing/DeveloperID"
security unlock-keychain -p "$(cat "$signing_directory/keychain-password.txt")" \
  "$signing_directory/signing.keychain-db"
PANEROOK_SIGNING_IDENTITY="$(cat "$signing_directory/identity.txt")" \
PANEROOK_SIGNING_KEYCHAIN="$signing_directory/signing.keychain-db" \
PANEROOK_SIGNING_TIMESTAMP=secure \
PANEROOK_NOTARY_PROFILE=panerook-notary \
PANEROOK_NOTARY_KEYCHAIN="$signing_directory/signing.keychain-db" \
./scripts/package-release.sh
```

Mit konfigurierten Apple-Zugangsdaten kann der Release-Workflow App und DMG notarisieren und die Tickets anheften. Einrichtung, verschlüsselte Sicherung, Zertifikatserneuerung und die optionale persönliche Signatur stehen unter [Signierung und Releases](docs/signing.md).

```sh
make test
```

In einer Umgebung, die verschachtelte Build-Sandboxen verhindert:

```sh
PANEROOK_DISABLE_BUILD_SANDBOX=1 make dev
PANEROOK_DISABLE_BUILD_SANDBOX=1 make test
```

Falls die Umgebung das Erzeugen von dSYM-Dateien verhindert, lässt sich zusätzlich `PANEROOK_DISABLE_DEBUG_SYMBOLS=1` setzen. Das App-Bundle wird dann ohne separate Debug-Symbole erstellt.

## Projektseite und Releases

Die statische Website liegt unter `website/` und wird mit Astro gebaut. Neben der Produktseite mit App-Screenshots gibt es eine [Dokumentation für Installation und Nutzung](https://frankhildebrandt.github.io/panerook/dokumentation/) sowie [Release Notes](https://frankhildebrandt.github.io/panerook/release-notes/). Alle Seiten verwenden dieselbe Hauptnavigation.

```sh
cd website
npm ci
npm run build
```

`astro.config.mjs` setzt `site` auf `https://frankhildebrandt.github.io` und `base` auf `/panerook`. Die Release-Notes-Seite übernimmt die versionierten Markdown-Dateien aus `docs/releases/` automatisch und sortiert sie absteigend nach Version. Der Workflow `.github/workflows/pages.yml` veröffentlicht Änderungen an der Website oder diesen Release-Dateien auf `main` über GitHub Actions auf GitHub Pages. In den Repository-Einstellungen muss **Pages → Source → GitHub Actions** aktiviert sein.

Der Workflow `.github/workflows/release.yml` testet die App auf einem macOS-Runner und signiert App und DMG mit der in GitHub-Secrets hinterlegten Developer-ID-Identität. Mit vollständigen Apple-Notarisierungs-Secrets übermittelt er beide an Apple und heftet die Tickets an. Ohne vollständige Signierkonfiguration bricht er ab. Ein Tag `v<Version>` veröffentlicht anschließend ein GitHub-Release mit Universal-DMG, Universal-ZIP und den jeweiligen SHA-256-Prüfsummen; die Version muss zum App-Bundle passen. Release-Hinweise liegen optional unter `docs/releases/<Version>.md`. Über **Run workflow** lässt sich der Build auch ohne Veröffentlichung als Actions-Artefakt ausführen. Release 0.1.1 ist die erste signierte und notarisierte Ausgabe mit DMG und ZIP.

## App-Updates

**PaneRook → Nach Updates suchen …** prüft manuell auf eine neuere Version. Standardmäßig prüft die App außerdem einmal täglich im Hintergrund. Unter **PaneRook → Einstellungen … → Updates** lassen sich die automatischen Prüfungen und das automatische Herunterladen und Installieren einstellen. Automatische Installation ist zunächst ausgeschaltet; Sparkle speichert die gewählte Einstellung für spätere Starts.

Der Feed liegt als `appcast.xml` beim [neuesten stabilen GitHub Release](https://github.com/frankhildebrandt/panerook/releases/latest). Downloads laufen über HTTPS; Sparkle prüft die Ed25519-Signatur des Update-ZIPs vor dem Entpacken. Vorabversionen werden über diesen Feed nicht angeboten. Die App sollte im Programme-Ordner liegen, nicht im geöffneten DMG.

Für Releases sind die zusätzlichen GitHub-Secrets `PANEROOK_SPARKLE_PUBLIC_KEY` und `PANEROOK_SPARKLE_PRIVATE_KEY` einzurichten. Jede neue Ausgabe braucht eine höhere `CFBundleVersion` sowie eine passende `CFBundleShortVersionString` in `Resources/Info.plist`. Bestehende Installationen von **0.1.1** müssen **0.2.0** als erste Ausgabe mit Updater einmal manuell installieren; anschließend sind Updates in der App möglich.

## Funktionen und Bedienung

PaneRook verbindet zwei Dateipanels mit Dateiaktionen, Archiven, Git, Remote-Verbindungen, einem Ghostty-Terminal und Hintergrundaufgaben. Die [Nutzerdokumentation](https://frankhildebrandt.github.io/panerook/dokumentation/) erklärt Einstieg und Bedienung; ausführliche zusätzliche Hinweise stehen in der [Bedienungsreferenz](docs/bedienungsreferenz.md).

Über **Links/Rechts → Git-Diff und Verlauf** oder **⌘⌥G** wird ein Panel zum Git-Viewer. Der Viewer folgt dem Ordner und der ausgewählten Datei oder dem Verzeichnis im anderen Panel. Commit-Auswahl und Älter/Neuer navigieren durch die zugehörigen Versionen, mit Diff, damaligem Dateiinhalt und aktuellen Arbeitskopie-/Staged-Änderungen. **Dateiliste** kehrt zur bisherigen Auswahl zurück.

**Links/Rechts → Ghostty-Terminal** öffnet eine interaktive Shell im bisherigen Panelordner. Das andere Panel verwendet das aktuelle Terminalverzeichnis als Ziel für **F5 Kopieren** und **F6 Verschieben**. Verzeichniswechsel mit `cd` aktualisieren dieses Ziel; der beim Öffnen des Transferdialogs angezeigte Pfad bleibt für den Auftrag fest. **⌘⌥Tab** wechselt zwischen den Panels, während Tab und Ctrl-Tasten im Terminal der Shell gehören. **Dateiliste** blendet die bisherige Dateiliste wieder ein; das Terminal bleibt für den erneuten Aufruf erhalten. Ghostty ist eingebettet und muss nicht separat installiert werden.

## Architektur

- `Sources/PaneRook/`: ausführbarer Einstieg.
- `Sources/PaneRookApp/`: AppKit-Oberfläche, nach Features gegliedert; `Shell/` enthält Fensterkoordination und die Zusammenstellung der Features.
- `Sources/PaneRookCore/`: lokale Dateioperationen, Archive, Metadaten, Suche, Vergleich und Shell-Ausführung.
- `Sources/PaneRookTasks/`: UI-unabhängige Aufgaben-Queue und Fortschrittsmodelle.
- `Sources/PaneRookRemote/`: Verbindungsarchiv, Transferregeln und separate FTP-, SSH-, SFTP- und Nextcloud-Anbieter.
- `Sources/PaneRookPanels/`: testbarer Panelzustand mit Navigation, Verlauf, Filterung und Sortierung.
- `Tests/`: eigene Tests für Core, Tasks, Remote, Panels und App-Integration, einschließlich automatischer Architekturgrenzen. Ein SFTP-Test verwendet den lokalen System-`sftp-server`; echte Remote-Zugänge werden dadurch nicht geprüft.
- `Resources/Info.plist` und `scripts/build-app.sh`: lokales macOS-App-Bundle.
- `scripts/generate-icon.swift`: reproduzierbares App-Icon in `Resources/` und `assets/`.
- [Architektur, Schnittstellen und parallele Entwicklung](docs/architecture.md).
- [MC-Untersuchung und Ausgangspunkt](docs/midnight-commander-reference.md).

## Grenzen und nächste Schritte

Die App arbeitet mit den Rechten des angemeldeten Benutzers und erhöht sie nicht für Chmod/Chown. macOS kann für geschützte Ordner eine Zugriffsfreigabe verlangen. Eine App-Sandbox und Security-Scoped Bookmarks sind noch nicht eingerichtet.

Kopier- und Verschiebeaktionen fragen nach und überschreiben keine bestehenden Ziele. Fehler bei der Eingabe bleiben im Dialog sichtbar; der Dialog lässt sich auch aus einem Textfeld mit Esc abbrechen. Ein Konflikt wird vor Beginn der gesamten Auswahl geprüft. Attribute und symbolische Links werden beibehalten; MCs zusätzliche Optionen für Regex-Umbenennung, Folgen von Links, Verzeichniszusammenführung und Attributumschaltung sind noch nicht umgesetzt. Laufzeitfehler können eine teilweise abgeschlossene Auswahl hinterlassen; die App meldet das und lädt beide Panels neu. Lokale Kopien verwenden ein temporäres Ziel und veröffentlichen den aktuellen Eintrag erst nach vollständiger Übertragung ohne Überschreiben. Bei Abbruch wird dieses temporäre Ziel entfernt; vorher abgeschlossene Einträge bleiben erhalten. Verschieben auf demselben Volume verwendet eine atomare Umbenennung, über Volume-Grenzen Kopieren und anschließendes Entfernen der Quelle. **⌘Z / ⇧⌘Z** machen lokale Umbenennungen, Verschiebungen, neu angelegte leere Ordner und Papierkorb-Aktionen rückgängig bzw. wiederholen sie. Das **Datei → Operationsprotokoll** zeigt abgeschlossene Schritte und Teilfehler. Das Journal gilt pro Fenster und Sitzung; vor der Wiederherstellung werden Identität, Inhalt, Attribute und Zielpfade geprüft. Geänderte Einträge und belegte Ziele werden nicht ersetzt. Kopieren, Shell-, Remote- und Archivaktionen haben kein Datei-Undo; Textfelder und Ghostty behalten ihre native Bedienung. Details und Grenzen stehen in der [Bedienungsreferenz](docs/bedienungsreferenz.md#rückgängig-und-operationsprotokoll).

Inhaltssuche und die eigene Textvorschau lesen höchstens 1 MiB pro Datei. Die Suche endet bei 10.000 Treffern oder 250.000 geprüften Einträgen. Datei- und Verzeichnisvergleiche vergleichen reguläre Dateien bis 1 GiB pro Datei; der Verzeichnisvergleich ist auf 100.000 Einträge je Seite begrenzt. Ordnergrößen werden bis 1.000.000 Einträge berechnet. Symbolische Links werden bei diesen rekursiven Werkzeugen nicht verfolgt. Begrenzungen und nicht lesbare Einträge werden im Ergebnis gemeldet. Shell-Ausgaben werden zur Anzeige auf 4 MiB je Ausgabestrom begrenzt.

Noch offen: interner Editor, Tabs, Drag & Drop, automatische Dateisystembeobachtung und erweiterte Kopier-/Konfliktdialoge mit Überschreiben, Zusammenführen, Linkfolge und Wiederaufnahme. Die Menüeinträge sind native Umsetzungen des MC-Arbeitsablaufs; vollständige Funktions- oder Formatkompatibilität mit MC wird nicht behauptet.

## Lizenz

PaneRook steht unter der [MIT-Lizenz](LICENSE).
