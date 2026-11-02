# Architektur und parallele Entwicklung

PaneRook ist ein modularer Monolith. SwiftPM erzwingt die Grenzen der fachlichen Targets; die App-Schicht organisiert zusammengehörige UI und Abläufe nach Features.

## Targets und Abhängigkeiten

- `PaneRook`: ausführbarer Einstieg; startet `PaneRookApp`.
- `PaneRookApp`: AppKit-Oberfläche, Feature-Abläufe und Zusammenstellung. Abhängig von Core, Tasks, Remote, Panels und Sparkle 2.10.0.
- `PaneRookPanels`: Panelzustand, Navigationsgenerationen, Verlauf, Filter und Sortierung; abhängig von Core, ohne AppKit.
- `PaneRookCore`: lokale Dateiaktionen, Archive, Metadaten, Suche, Vergleiche und Shell-Ausführung; abhängig von Tasks und der Systembibliothek CArchive.
- `PaneRookTasks`: Queue, Fortschrittswerte und Aufgabenstatus; nur Foundation.
- `PaneRookRemote`: Verbindungen, Verbindungsarchiv, Remote-Transferregeln und Transportanbieter; unabhängig von App, Panels, Core und Tasks.

Die Domain-Targets dürfen keine Oberfläche importieren. Es gibt keine Rückabhängigkeit auf `PaneRookApp`.

Sparkle ist als feste SwiftPM-Paketversion eingebunden und bleibt auf die App-Schicht begrenzt. Das App-Buildskript kopiert das dynamische Framework samt Hilfsprozessen in `Contents/Frameworks` und signiert die Bestandteile vor dem umgebenden App-Bundle. Der ausführbare Einstieg enthält den passenden Framework-Suchpfad.

## Zuständigkeiten in der App

`Shell/FeatureComposition.swift` stellt die Features zusammen und erfüllt ihre Host-Schnittstellen. Der Commander verwaltet Fensterlayout, Panelkoordination und native Responder-Integration. `FileOperations` besitzt Dateiaktionen und deren Dialoge; `Preview` besitzt Quick Look und die Vorbereitung von Archivkopien. `Inspection`, `Remote`, `Workflow`, `Preferences` und `Favorites` besitzen jeweils ihre Abläufe und UI.

Die Host-Protokolle stehen beim jeweiligen Verbraucher. Gemeinsame Verträge für Präsentation, Fehler, Panelpaare und Aufgaben stehen in `SharedUI/FeatureHosting.swift`. Ein Feature bekommt nur seinen Host-Vertrag, keinen konkreten Commander. `PanelAccess` bietet fachliche Paneloperationen und lesbaren Zustand, ohne Tabelle oder Pfadfeld freizugeben. Nur `Panels` und `Shell` dürfen den konkreten Panelcontroller kennen.

`Tasks/TaskCenter` erhält Fenster- und Fokus-Callbacks. `OperationRunner` verbindet native Dateioperationen mit der Queue und einer Aktualisierungsfunktion. Beide kennen den Commander nicht. Die Queue bleibt bewusst seriell: unabhängige Entwicklung von Features bedeutet nicht, potenziell kollidierende Dateioperationen gleichzeitig auszuführen.

Der App-Start hält den Updater für die gesamte Laufzeit und verbindet ihn mit dem nativen App-Menü. Sparkle übernimmt Update-Dialoge, Zeitplanung, Download, Signaturprüfung und Installation; seine Einstellungen werden über seine API geändert und gespeichert. Bare Executables und Entwicklungsbundles ohne öffentlichen Update-Schlüssel starten keinen Updater. Der Release-Feed ist das `appcast.xml`-Asset des neuesten stabilen GitHub Releases. Die Paketierung signiert das ZIP und erzeugt den Feed aus den Versionsangaben des gebauten Bundles; Details stehen unter [Signierung und Releases](signing.md#sparkle-update-signierung).

## Neue Aktionen

Aktionen gehören in die `*Commands.swift`-Datei ihres Features. Eine Definition umfasst stabile ID, Menüplatzierung, Reihenfolge, Tastaturvorgabe, Verfügbarkeit und Ausführung. Die Registry stellt daraus Menüeinträge, Funktionstastenleiste und Tastaturkonfiguration bereit. Verfügbarkeit wird auch unmittelbar vor Ausführung geprüft.

Bei einer neuen Aktion in einem bestehenden Feature ändern sich weder `CommanderMenus` noch die zentrale Tastaturverteilung. Reihenfolge und Gruppen werden anhand expliziter Werte zusammengeführt; zwischen vorhandenen Werten bleiben Plätze für weitere Aktionen. Ein neues Feature wird einmal in `FeatureComposition` registriert. IDs sind persistente Kennungen: insbesondere `help`, `userMenu`, `preview`, `edit`, `copy`, `move`, `mkdir`, `trash`, `menu` und `exit` müssen für vorhandene Tastatureinstellungen erhalten bleiben.

Native Bearbeiten-Kürzel laufen weiterhin durch AppKits Responder Chain. F10 bleibt in offenen Menüs und Dialogen eine Abbruchaktion. Menü- und Dock-Callbacks dürfen den Commander nicht dauerhaft festhalten.

## Remote-Anbieter erweitern

Jeder Anbieter implementiert die primitiven Operationen des `RemoteTransport`-Vertrags. `RemoteProvider` ergänzt die Erstellung, Verbindungsvalidierung, Anzeige und Formularhinweise. FTP, SFTP, SSH und Nextcloud liegen in eigenen Dateien. Die Zuordnung erfolgt ausschließlich in `RemoteProviderRegistry`; die stabile Protokollkennung bleibt im gespeicherten Verbindungsformat.

Ein neuer Anbieter benötigt seine Implementierung, eine Kennung samt Eintrag in der verfügbaren Protokollliste, eine Registrierung und Tests. Browser, Verbindungsdialog, Archiv und Panelmenüs verwenden Anbieterbeschreibungen und benötigen dafür keine Protokollverzweigungen.

Rekursion, Kollisionsprüfung und temporäre Downloads mit anschließender Veröffentlichung gehören weiterhin in `RemoteFileSystem`. Ein Transport darf diese Regeln nicht duplizieren oder umgehen. `RemoteProcess` kapselt den injizierbaren Prozess-Runner; Provider-Tests benötigen keine echten Zugangsdaten.

## Panelzustand und Hintergrundaufträge

`PanelState` ist ein Werttyp ohne AppKit. Jede Navigation bekommt eine Generation. Ergebnisse älterer Generationen werden verworfen; die Übernahme von Suchergebnissen macht offene Navigation ungültig. Fehlgeschlagene Navigation ersetzt weder Verzeichnis noch Verlauf.

Dateioperationen erfassen Quellen, Zielverzeichnis und auslösendes Panel vor dem Einreihen. Ein Abschluss darf niemals stattdessen das inzwischen aktive Panel verwenden. `canApplyTaskResult` schützt die Übernahme vor Verzeichniswechseln, offenen Navigationen, fremden Ansichtsmodi und Suchergebnissen. AppKit-Auswahl und Fokus bleiben in der Oberfläche.

## Arbeiten auf getrennten Branches

Arbeitspakete nach Features aufteilen, etwa Suche, WebDAV oder Dateiaktionen. Änderungen an gemeinsamen Verträgen zuerst abstimmen und klein integrieren. Andere Features nicht durch Direktzugriffe anbinden; stattdessen den benötigten Callback oder Vertrag ergänzen und im Shell verdrahten. Neue Feature-Dateien brauchen innerhalb eines bestehenden Targets keinen Eintrag im Paketmanifest.

Reine Verschiebungen und breite Umbenennungen früh integrieren, bevor mehrere Feature-Branches darauf aufbauen. Die vorliegende Umstellung verschiebt viele Dateien; laufende Branches sollten diesen Stand vor weiterer Arbeit übernehmen. Ein gemeinsames Manifest und die Feature-Zusammenstellung bleiben bewusste, kleine Integrationspunkte.

## Prüfung

`swift test` führt Domain-Tests, Remote-Vertragstests, Panelzustands-, Befehls- und App-Zusammenstellungstests aus. `ArchitectureBoundaryTests` verhindert Rückgriffe von Features auf konkrete Shell-/Panelcontroller sowie UI-Imports in Domain-Targets. Eigene Testtargets für Tasks, Remote und Panels prüfen die Bereiche getrennt von der App.

`./scripts/build-app.sh` erstellt das vollständige App-Bundle. In eingeschränkten Build-Umgebungen gelten die in der README dokumentierten Cache- und Sandboxoptionen. Die automatischen AppKit-Tests bauen Ansicht und Menüs ohne sichtbares Fenster auf; interaktive Fokusabläufe und echte Remote-Server benötigen weiterhin manuelle Prüfung.
