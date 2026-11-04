<img src="assets/icon.svg" width="64" height="64" alt="">

# PaneRook

Ein nativer macOS-Dateimanager, inspiriert von Midnight Commander: zwei Dateipanels mit unabhängigen Tabs, direkter Tastaturbedienung, Git, Archiven, Remote-Verbindungen und eingebettetem Ghostty-Terminal. Swift + AppKit, MIT-Lizenz.

## Download und Dokumentation

[Projektseite](https://frankhildebrandt.github.io/panerook/) · [Aktueller veröffentlichter Release](https://github.com/frankhildebrandt/panerook/releases/latest) · [Release Notes 0.4.1](docs/releases/0.4.1.md)

Version **0.4.1 (Build 7)** bietet Tabs, benannte Arbeitsbereiche, Git-Verlauf und ein eingebettetes Terminal. Voraussetzung für die fertige App ist **macOS 14 oder neuer**; Release-Pakete unterstützen Apple Silicon und Intel.

[Installation und Einstieg](https://frankhildebrandt.github.io/panerook/dokumentation/) erklären die Bedienung. Eigenständige Anleitungen behandeln [Tabs und Arbeitsbereiche](https://frankhildebrandt.github.io/panerook/dokumentation/arbeitsbereiche/), [Dateiaktionen](https://frankhildebrandt.github.io/panerook/dokumentation/dateiaktionen/), [Transfers und Fortsetzen](https://frankhildebrandt.github.io/panerook/dokumentation/transfers/), [Ordnersynchronisation](https://frankhildebrandt.github.io/panerook/dokumentation/synchronisation/), [Terminal](https://frankhildebrandt.github.io/panerook/dokumentation/terminal/), [Git und Worktrees](https://frankhildebrandt.github.io/panerook/dokumentation/git/), [Archive](https://frankhildebrandt.github.io/panerook/dokumentation/archive/) und [Remote-Verbindungen samt Arbeitskopien](https://frankhildebrandt.github.io/panerook/dokumentation/remote/). Die ausführliche [Bedienungsreferenz](docs/bedienungsreferenz.md) ist auch direkt im Repository lesbar.

## Entwickeln

Voraussetzungen: macOS 14+, **Xcode 26+** mit ausgewählter Command Line Toolchain. Für die Website: **Node 24+**.

```sh
make dev
```

| Aufruf | Ergebnis |
| --- | --- |
| `make run` | Optimiertes App-Bundle bauen und starten |
| `make dev` | Debug-App mit Watcher; Ctrl-C beendet Watcher und gestartete App |
| `make build` | Einmaliger Release-Build unter `build/PaneRook.app` |
| `make test` | Swift-Tests und Appcast-Prüfung |
| `make clean` | SwiftPM-Buildprodukte und `build/` entfernen |

`make dev` beobachtet Sources, Resources, Skripte, Makefile und Paketdateien im Sekundentakt. Bei Buildfehlern bleibt die letzte App offen. Vor einem automatischen Neustart laufende Dateiaktionen abschließen. Alternativ `open Package.swift` und das Scheme **PaneRook** in Xcode ausführen.

SwiftPM lädt die festgelegten Abhängigkeiten Sparkle **2.10.0** und libghostty-spm **1.5.2** (Ghostty **1.3.1**, MIT). Das Buildskript bettet Sparkle samt Helfern, Ghostty-Ressourcen, Shell-Integration, Terminfo und Lizenztexte ein und signiert lokale Builds standardmäßig ad hoc. Ghostty muss nicht separat installiert sein. Ohne `PANEROOK_SPARKLE_PUBLIC_KEY` sind Updates im Entwicklungsbuild deaktiviert; das gilt auch für das bloße SwiftPM-Executable.

Bei blockierter verschachtelter Sandbox ist `PANEROOK_DISABLE_BUILD_SANDBOX=1 make test` beziehungsweise `make dev` die vorhandene Ausweichmöglichkeit. Falls das Erzeugen von dSYM-Dateien gesperrt ist, kann `PANEROOK_DISABLE_DEBUG_SYMBOLS=1` verwendet werden.

## Website und Release-Pakete

```sh
cd website
npm ci
npm run build
```

Die statische Astro-Website verwendet den Basispfad `/panerook`. Versionierte Inhalte unter `docs/releases/<Version>.md` speisen Website-Einzelseiten und GitHub Release Notes. Versionierte App-Bilder liegen unter `website/public/screenshots/releases/<Version>/`.

```sh
./scripts/package-release.sh 0.4.1
```

Der vorhandene Paketierungsweg erstellt Universal-DMG, Universal-ZIP, SHA-256-Prüfsummen und `appcast.xml` unter `build/release/`. Version und Buildnummer stammen aus `Resources/Info.plist`; die Buildnummer muss gegenüber dem letzten veröffentlichten Release steigen. Paketierung benötigt beide Sparkle-Schlüssel. Developer-ID-Signierung, Schlüsselbund, Notarisierung, Einrichtung und Sicherung sind in [Signierung und Releases](docs/signing.md) beschrieben. Private Schlüssel und Passwörter bleiben außerhalb des Repositorys.

Änderungen an Website oder Release-Texten auf `main` starten den separaten Pages-Workflow. Ein gepushter `v<Version>`-Tag startet App-Prüfungen, Paketierung und GitHub-Veröffentlichung; ein manueller Workflowlauf erzeugt nur Actions-Artefakte. Der Release-Workflow verlangt die Signierkonfiguration; Notarisierung benötigt zusätzlich die vollständige Apple-Konfiguration. Bilder auf Pages müssen vor den GitHub Notes öffentlich erreichbar sein. Lokale Vorbereitung führt keine Tags, Pushes oder Deployments aus.

## Funktionen und Grenzen

F5/F6 übertragen zwischen den gewählten Tabs; vorhandene Ziele benötigen eine ausdrückliche Konfliktentscheidung. Kopier-/Verschiebeaufträge bleiben gespeichert und lassen sich auf Dateiebene fortsetzen. Lokale unterstützte Einzelaktionen haben Undo/Redo pro Fenster und Sitzung; Ersetzen, Zusammenführen und Mehrfachumbenennen haben kein automatisches Datei-Undo. Die Ordnersynchronisation ist ein lokaler Ein-Wege-Abgleich mit Vorschau und optionalen endgültigen Löschungen.

F4 öffnet den bevorzugten externen Editor. Remote-Arbeitskopien werden erst ausdrücklich zurückgeladen, mit Versionsprüfung und erhaltener Serversicherung für SFTP, SSH und Nextcloud; FTP-Rückupload ist dabei gesperrt. Remote-Transfers unterstützen reguläre Dateien und Ordner, keine Links. SSH/SFTP benötigen Schlüssel oder Agent und bestätigtes Hostvertrauen. Ein interner Editor und das Folgen von Links bei Transfers fehlen.

PaneRook arbeitet mit den Rechten des angemeldeten Benutzers; App-Sandbox und Security-Scoped Bookmarks sind nicht eingerichtet. macOS kann Ordnerfreigaben verlangen. Grenzen für große Dateien, Archive, Suchergebnisse, Wiederherstellung und konkurrierende Änderungen stehen in den jeweiligen Anleitungen und der [Bedienungsreferenz](docs/bedienungsreferenz.md).

## Technische Referenzen und Lizenz

[Architektur und Modulgrenzen](docs/architecture.md) · [Signierung und Releases](docs/signing.md) · [MC-Untersuchung](docs/midnight-commander-reference.md) · [MIT-Lizenz](LICENSE)

Die Module trennen AppKit-Oberfläche (`PaneRookApp`), lokale Dateisystemarbeit (`PaneRookCore`), Aufgaben (`PaneRookTasks`), Remote-Anbieter (`PaneRookRemote`) und Panelzustand (`PaneRookPanels`). Tests prüfen auch Modulgrenzen und lokale Transportverträge; echte Serverzugänge und Volume-Wechsel benötigen zusätzliche manuelle Prüfung.
