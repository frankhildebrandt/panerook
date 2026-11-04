# Releasevorbereitung 0.4.0

Stand: 4. November 2026. **Nicht als App-Paket veröffentlicht; ersetzt durch 0.4.1.** Zielversion 0.4.0 und Build 6 sind bestätigt. Ausgangspunkt ist `dc8150d` (Merge von Remote Edit nach Tabs, Transfers und weiteren Features); hinzu kommen die lokalen Release-Inhalte und Metadaten dieses Checkouts. Keine Änderungen an App-Funktionen im Rahmen der Vorbereitung.

Letzter tatsächlich veröffentlichter Release: **v0.3.1**, veröffentlicht am 2. November 2026 um 17:47:37 UTC, als neuester stabiler Release durch `gh release list` geprüft. Dessen App-Metadaten enthalten Version 0.3.1 und Build 5. v0.3.0 ist ein vorhandener Tag samt damaligen Notes, aber kein veröffentlichter App-Release. Vergleich: `v0.3.1...HEAD`.

## Abgleich von Funktionen und Dokumentation

Die Belege beziehen sich auf Implementierung, registrierte Aktionen und vorhandene Tests; UI-Aufnahmen stammen aus dem neu gebauten App-Bundle. „Neu“ bedeutet seit dem letzten veröffentlichten App-Release. Bestehende Funktionen werden durch nachgeholte Anleitungen nicht als neue App-Funktionen vermarktet.

| Funktion | Beleg unter Sources / Tests | Dokumentationsziel | Aufnahme 0.4.0 | Einordnung und Darstellung |
| --- | --- | --- | --- | --- |
| Tabs und benannte Arbeitsbereiche | App/Workspaces, Shell/WorkspaceCoordination; WorkspaceTests | `/dokumentation/arbeitsbereiche/` | `panels.png` | Neu; Release-Hauptthema und Landingpage |
| Ghostty-Terminal | App/Terminal; TerminalPanelTests, GhosttyRuntimeTests | `/dokumentation/terminal/` | `terminal.png` | Neu; Release-Hauptthema und Landingpage-Verweis |
| Git-Verlauf im Panel | App/Git/GitHistoryView; GitHistoryPaneTests | `/dokumentation/git/` | `git-verlauf.png` | Neu; Release-Hauptthema und Landingpage |
| Mehrfachumbenennen | App/FileOperations/BatchRename*, Core/BatchRename*; BatchRenameTests, BatchRenameIntegrationTests | `/dokumentation/dateiaktionen/` | `umbenennen.png` | Neu; Release-Hauptthema und Landingpage-Verweis |
| Lokale Ordnersynchronisation | App/Inspection/DirectorySyncWindow, Core/DirectorySync*; DirectorySyncTests | `/dokumentation/synchronisation/` | `synchronisation.png` | Neu; Release-Hauptthema und Landingpage-Verweis |
| Transferkonflikte | App/FileOperations/TransferConflictPrompt, Core/TransferConflicts, Remote/RemoteTransferConflicts; passende Integrationstests | `/dokumentation/transfers/` | `konflikte.png` | Neu; Release-Hauptthema und Landingpage-Verweis |
| Fortsetzbare Transfers | App/Tasks/Recoverable*, Tasks/RecoverableTransfer; RecoverableTransferIntegrationTests | `/dokumentation/transfers/` | `aufgaben.png` | Neu; Release-Hauptthema und Landingpage-Verweis |
| Remote-Arbeitskopien | App/Remote/RemoteEdit*, Remote/RemoteEditSession; RemoteEditSessionTests, RemoteEditIntegrationTests | `/dokumentation/remote/#bearbeiten` | `remote-arbeitskopien.png` | Neu; Release-Hauptthema; FTP-Rückupload ausdrücklich gesperrt |
| Befehlspalette | App/CommandPalette; CommandPaletteTests | Dokumentation, Erste Schritte | Kein zusätzliches Bild nötig | Neu; kompakter Release-Punkt |
| Automatische Ordner-/Git-Aktualisierung | App/Panels/LocalDirectoryObservation, ListingPresentation; LocalDirectoryObservationTests | Dokumentation, Git und Grenzen | Hauptansicht als realer Kontext | Neu; kompakter Release-Punkt |
| Datei-Undo und Operationsprotokoll | App/FileOperations/FileOperationUndo, Core/FileOperationJournal; FileOperationUndoTests | `/dokumentation/dateiaktionen/` | Kein zusätzlicher Dialog nötig | Neu; kompakter Release-Punkt, Grenzen dokumentiert |
| Drag & Drop und Datei-Zwischenablage | App/FileOperations/NativeFileExchange, App/Panels/PanelFileExchange; NativeFileExchangeTests | `/dokumentation/dateiaktionen/` | Hauptansicht als Kontext | Neu; kompakter Release-Punkt |
| Archive | App/Preview/ArchivePreviewStore, Core/Archive* | `/dokumentation/archive/` | `archive.png` | Bestehend; aktuelle Oberfläche für Landingpage/Anleitung |
| Remote-Navigation, Anmeldung, Netzwerkfreigaben | App/Remote/RemoteBrowser*, Panels/NetworkBrowserView; RemoteDrive*Tests | `/dokumentation/remote/` | `remote.png` | Bestehend; aktuelle Aufnahme und aktualisierte Grenzen |
| Metadaten, Links, Sparse-Dateien, Suche und eigene Befehle | App/FileOperations/MetadataCommands, SparseFileDialog, InspectionCommands, WorkflowCommands; Bedienungsreferenz | Dateiaktionen, Terminal, Dokumentations-Einstieg | Kein weiterer Screenshot nötig | Bestehend; Bedienung nachdokumentiert, keine neue Release-Schlagzeile |

In der Tabelle steht App für `PaneRookApp`, Core für `PaneRookCore`, Remote für `PaneRookRemote` und Tasks für `PaneRookTasks`. Die vollständige Bedienungsreferenz bleibt unter `docs/bedienungsreferenz.md` erhalten.

## Inhalte und Bilder

- Fünf neue Unterseiten für Arbeitsbereiche, Dateiaktionen, Transfers, Synchronisation und Terminal. Git, Archive und Remote verwenden nun ebenfalls das gemeinsame `DocumentationLayout` mit Rückweg und Themennavigation.
- Überholte Einschränkungen zu Tabs, Terminal, Undo, Konflikten, Beobachtung und Wiederaufnahme korrigiert. Alte Dokumentationsanker bleiben als Einstieg erhalten.
- `docs/releases/0.4.0.md` ist die gemeinsame Quelle für Website und GitHub Notes. Die vorhandene dynamische Route erzeugt `/release-notes/0.4.0/` und alle historischen Einzelseiten. Die Übersicht zeigt Zusammenfassungen und direkte Links; ihre bisherigen Versions- und Abschnittsanker bleiben erhalten.
- Landingpage, Downloadverweise und `Resources/Info.plist` / `website/src/data/site.ts` auf 0.4.0 aktualisiert. README auf Einstieg, Entwicklung, Paketierung, Referenzen und wesentliche Grenzen gekürzt; ausführliche Bedienung ist verlinkt.
- Zehn echte Aufnahmen liegen unter `website/public/screenshots/releases/0.4.0/`. Hauptansichten verwenden 4112 × 2466 Pixel; Dialoge ihre nativen Größen. Alle Dateien sind tatsächlich PNG, visuell geprüft und mit Alternativtext, korrekten Abmessungen und Originalverlinkung eingebunden. Historische Release-Bilder bleiben unverändert.
- Die Demo liegt unter `/tmp/PaneRook-Demo`. Git-Historie und Dateien wurden dafür lokal erzeugt. Für die Remote-Aufnahme lief ein nur auf 127.0.0.1:2121 erreichbarer, nur lesbarer FTP mit Demo-Daten. F4 hat die README tatsächlich als Arbeitskopie geladen; ein Rückupload wurde nicht behauptet. Der Demoserver und die Aufnahme-App sind beendet, der offene Demo-Transfer verworfen und der ursprüngliche Panelzustand wieder eingestellt. Die unveränderte lokale Remote-Arbeitskopie bleibt entsprechend der App-Funktion erhalten; ihre Beobachtung ist beendet.

## Prüfungen

- `make build`: erfolgreicher optimierter nativer arm64-Build, App-Bundle 0.4.0 (6), ad hoc signiert; Signaturprüfung des Buildskripts erfolgreich. Start über den vollständigen Pfad des neu gebauten Bundles. Dies ist kein signiertes/notarisiertes Universal-Distributionspaket. Ohne Sparkle-Schlüssel sind Updates in diesem lokalen Aufnahmebuild deaktiviert; davon gibt es keine irreführende Aufnahme.
- `make test`: alle fünf Testprodukte erfolgreich, insgesamt **544 Tests, drei optionale Tests übersprungen, keine Fehler**. Die Übersprünge betreffen Papierkorb, zusätzliches Testvolume und den gesondert aktivierbaren nativen Ghostty-Test. Appcast-Prüfungen inklusive Signatur-, Manipulations-, Schlüssel- und Buildnummerfällen erfolgreich.
- Der native Ghostty-/PTY-Test wurde anschließend mit `PANEROOK_TEST_GHOSTTY=1` gezielt ausgeführt und ist ebenfalls erfolgreich: Shellstart, Verzeichnisverfolgung und Erhalt beim Ausblenden. Damit bleiben nur die zwei umgebungsabhängigen Opt-in-Prüfungen für Papierkorb und zusätzliches Volume unausgeführt.
- `npm ci` und `npm run build`: erfolgreich mit Node 26.13.0; 17 statische Seiten einschließlich aller acht Dokumentations-Unterseiten und sechs Release-Einzelseiten.
- Gebautes Ergebnis: lokale Routen, Navigation, alte Dokumentations- und Release-Anker, `/panerook`-Basispfad, eindeutige IDs, genau eine H1 pro Seite, Bilder, Alternativtexte und PNG-Abmessungen geprüft. Alle bestehenden lokalen README-Verweise bleiben erreichbar.
- Selbstständige HTML-Darstellung der gebauten Seiten mit eingebettetem tatsächlichem CSS und lokalen Bildern: Landingpage auf Desktop, Synchronisationsanleitung und Release Notes mobil geprüft. Zur lokalen Prüfung wurden nur die öffentlichen Bild-URLs auf die gebauten Assets aufgelöst; öffentliche Erreichbarkeit wird damit nicht bestätigt.

## Veröffentlichung

Zum Abschluss der lokalen Vorbereitung waren noch keine Tags, Pushes, Deployments oder Distributionspakete erzeugt. Für die Inhaltsvorbereitung fehlen keine erforderlichen Motive. Anschließend wurde die vollständige Veröffentlichung ausdrücklich beauftragt. Sie nutzt den bestehenden Pages- und App-Release-Workflow; das Ergebnis wird nach Abschluss unten ergänzt.

Bei beauftragter Veröffentlichung den bestehenden Paketierungs-/Signierweg und die zwei bestehenden Workflows verwenden. Developer-ID-Signierung, Universal-Pakete, Sparkle-Signatur und gegebenenfalls Notarisierung müssen am tatsächlichen Distributionsbuild geprüft werden. Diese Vorbereitung belegt keine Apple-Notarisierung für 0.4.0.

Versionierte Website-Bilder und Release-Einzelseite müssen öffentlich erreichbar sein, bevor die GitHub Notes veröffentlicht werden. Pages wird über `main` separat bereitgestellt; der App-Tag allein veröffentlicht die Website nicht. Danach GitHub-Downloads, SHA-256-Dateien, Appcast-Version/Build/Signatur sowie die öffentlichen Dokumentations-, Release- und Bild-URLs prüfen. Die für 0.4.0 vorgesehenen öffentlichen URLs sind lokal geprüft, noch nicht öffentlich veröffentlicht oder auf Erreichbarkeit bestätigt.

Echte SFTP-/SSH-/Nextcloud-Rückuploads, Volume-Wechsel und Papierkorb-Wiederherstellung wurden nicht manuell mit privaten Zugängen oder zusätzlichen Volumes ausgeführt. Die entsprechenden Bediengrenzen bleiben dokumentiert; vorhandene automatisierte Transport- und Integrationsprüfungen ersetzen diese Umgebungsprüfungen nicht.

## Ergebnis des Veröffentlichungsversuchs

Die Website wurde mit Commit `dee734c2a8fd94a57a9dcd97e36d1d705f624485` veröffentlicht; alle 17 Seiten und zehn Bilddateien wurden öffentlich geprüft. Der [App-Release-Lauf für v0.4.0](https://github.com/frankhildebrandt/panerook/actions/runs/41824663939) scheiterte an einer falschen Breitenannahme in `GitHistoryPaneTests.testViewerKeepsNavigationAndDiffUsableAtMinimumAndWiderPaneSizes`: Der Test zog die 15 Pixel eines klassischen Scrollbalkens nicht von der erwarteten Diffbreite ab. Es wurden keine App-Pakete veröffentlicht. Der Tag v0.4.0 bleibt unverändert. Der Nutzer hat ausdrücklich 0.4.1 (Build 7) gewählt; siehe [Releaseprotokoll 0.4.1](release-preparation-0.4.1.md).

Die optionalen Papierkorb- und Volume-Undo-Tests wurden beim Veröffentlichungsabschluss separat aktiviert und erfolgreich ausgeführt. Das eigens erzeugte 64-MB-Testvolume wurde danach ausgehängt.
