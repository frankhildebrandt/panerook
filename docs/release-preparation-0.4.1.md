# Releaseprotokoll 0.4.1

Stand: 4. November 2026. **Veröffentlichung läuft.** Version 0.4.1 (Build 7) ist ausdrücklich gewählt. Der Tag v0.4.0 bleibt nach dem fehlgeschlagenen CI-Versuch unverändert; dafür wurde kein App-Paket veröffentlicht. Letzter veröffentlichter App-Release ist vor diesem Abschluss weiterhin 0.3.1 (Build 5).

## Umfang und Korrektur

Funktionen, Belege und Dokumentationsziele entsprechen der [Arbeitsliste für 0.4.0](release-preparation-0.4.0.md#abgleich-von-funktionen-und-dokumentation). Es gibt keine Änderung am App-Laufzeitcode. `GitHistoryPaneTests` vergleicht die Diffbreite jetzt mit der tatsächlich verfügbaren Scroll-Viewportbreite. Klassische und überlagerte Scrollleisten werden jeweils bei 320 × 400, 450 × 500 und 700 × 700 Pixeln erzwungen. Randabstände, Mindesthöhe und Erreichbarkeit der Bedienelemente bleiben geprüft. Alle zehn Git-Viewer-Tests sind lokal erfolgreich.

App-Metadaten, Website, README und Downloadnamen verwenden 0.4.1 (Build 7). `docs/releases/0.4.1.md` speist Website und GitHub Notes. 0.4.0 verweist als nicht veröffentlichtes App-Paket auf 0.4.1. Historische Tags und Bilder bleiben erhalten.

## Aufnahmen und Prüfungen

`website/public/screenshots/releases/0.4.1/panels.png` wurde frisch aus dem neu gebauten Bundle 0.4.1 (7) aufgenommen und visuell geprüft. Die übrigen neun echten Motive sind versionierte Kopien aus der Vorbereitung, da Laufzeitcode und Oberfläche unverändert sind. Die Bilder unter 0.4.0 bleiben erhalten. Der Demo-Arbeitsbereich wurde entfernt, die ursprüngliche Sitzung wieder geöffnet und die Aufnahme-App beendet.

Die vollständige lokale Suite vor dem Release umfasste 544 Testfälle ohne Fehler. Alle drei zunächst übersprungenen Opt-in-Tests wurden separat erfolgreich aktiviert: Ghostty-/PTY, Papierkorb und Undo/Redo über ein temporäres zweites Volume. Das Testvolume wurde ausgehängt. Die Appcast-Prüfung war ebenfalls erfolgreich.

Der native Aufnahmebuild für 0.4.1 ist arm64 und ad hoc signiert. Die Universal-Pakete werden über den bestehenden GitHub-Workflow mit eingerichteten Apple- und Sparkle-Secrets gebaut. Die Website wird vor den GitHub Notes veröffentlicht.

## Veröffentlichungsergebnis

Noch ausstehend: Pages-Deploy, signierte/notarisierte Universal-Pakete, GitHub-Veröffentlichung sowie öffentliche Prüfung von Seiten, Bildern, Downloads, Prüfsummen, Apple-Tickets und stabilem Appcast. Der Sparkle-Schlüssel wird zusätzlich mit dem tatsächlich veröffentlichten 0.3.1-Paket verglichen. Das Ergebnis wird nach Abschluss ergänzt.
