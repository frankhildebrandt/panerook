# Releaseprotokoll 0.4.1

Stand: 4. November 2026. **Veröffentlicht und öffentlich verifiziert.** Version 0.4.1 (Build 7) ist ausdrücklich gewählt. Der Tag v0.4.0 bleibt nach dem fehlgeschlagenen CI-Versuch unverändert; dafür wurde kein App-Paket veröffentlicht. Letzter veröffentlichter App-Release ist vor diesem Abschluss weiterhin 0.3.1 (Build 5).

## Umfang und Korrektur

Funktionen, Belege und Dokumentationsziele entsprechen der [Arbeitsliste für 0.4.0](release-preparation-0.4.0.md#abgleich-von-funktionen-und-dokumentation). Es gibt keine Änderung am App-Laufzeitcode. `GitHistoryPaneTests` vergleicht die Diffbreite jetzt mit der tatsächlich verfügbaren Scroll-Viewportbreite. Klassische und überlagerte Scrollleisten werden jeweils bei 320 × 400, 450 × 500 und 700 × 700 Pixeln erzwungen. Randabstände, Mindesthöhe und Erreichbarkeit der Bedienelemente bleiben geprüft. Alle zehn Git-Viewer-Tests sind lokal erfolgreich.

App-Metadaten, Website, README und Downloadnamen verwenden 0.4.1 (Build 7). `docs/releases/0.4.1.md` speist Website und GitHub Notes. 0.4.0 verweist als nicht veröffentlichtes App-Paket auf 0.4.1. Historische Tags und Bilder bleiben erhalten.

## Aufnahmen und Prüfungen

`website/public/screenshots/releases/0.4.1/panels.png` wurde frisch aus dem neu gebauten Bundle 0.4.1 (7) aufgenommen und visuell geprüft. Die übrigen neun echten Motive sind versionierte Kopien aus der Vorbereitung, da Laufzeitcode und Oberfläche unverändert sind. Die Bilder unter 0.4.0 bleiben erhalten. Der Demo-Arbeitsbereich wurde entfernt, die ursprüngliche Sitzung wieder geöffnet und die Aufnahme-App beendet.

Die vollständige lokale Suite vor dem Release umfasste 544 Testfälle ohne Fehler. Alle drei zunächst übersprungenen Opt-in-Tests wurden separat erfolgreich aktiviert: Ghostty-/PTY, Papierkorb und Undo/Redo über ein temporäres zweites Volume. Das Testvolume wurde ausgehängt. Die Appcast-Prüfung war ebenfalls erfolgreich.

Der native Aufnahmebuild für 0.4.1 ist arm64 und ad hoc signiert. Die Universal-Pakete werden über den bestehenden GitHub-Workflow mit eingerichteten Apple- und Sparkle-Secrets gebaut. Die Website wird vor den GitHub Notes veröffentlicht.

## Veröffentlichungsergebnis

- [GitHub Release v0.4.1](https://github.com/frankhildebrandt/panerook/releases/tag/v0.4.1), veröffentlicht am 4. November 2026 um 12:23:53 UTC. Stabiles Release, kein Entwurf und keine Vorabversion. Release-Commit: `38b2b2201ecfd0ee48bf92464615c77a800e5e29`.
- [App-Release-Workflow](https://github.com/frankhildebrandt/panerook/actions/runs/41827169605) erfolgreich: 544 Testfälle, drei reguläre Opt-in-Skips, keine Fehler; die drei Opt-in-Prüfungen sind separat lokal erfolgreich. Appcast-Prüfung erfolgreich. Apple hat App und DMG angenommen; beide Tickets wurden angeheftet und validiert.
- [Pages-Workflow](https://github.com/frankhildebrandt/panerook/actions/runs/41827106232) erfolgreich auf demselben Release-Commit. Öffentliche Nachprüfung aller 18 Seiten und zehn 0.4.1-Bilder erfolgreich; Bilddateien stimmen per SHA-256 mit den lokalen Originalen überein. Die [Release-Einzelseite](https://frankhildebrandt.github.io/panerook/release-notes/0.4.1/) und alle Dokumentations-Unterseiten sind erreichbar. Lokal zusätzlich 381 Link-/Asset-Verweise und 74 Bildvorkommen geprüft.
- Beide Pakete samt SHA-256-Dateien und `appcast.xml` erneut von GitHub heruntergeladen. Prüfsummen stimmen, veröffentlichte Notes entsprechen der gemeinsamen Markdown-Quelle. Der stabile Latest-Feed liefert 0.4.1, Build 7, Mindestversion macOS 14.0 und die korrekte ZIP-Länge.
- Die heruntergeladene App enthält arm64 und x86_64. Developer-ID-Signaturen, angeheftete Notarisierungstickets und Gatekeeper-Bewertung erfolgreich. Das DMG wurde schreibgeschützt eingehängt: App-Plist und ausführbare Datei stimmen bytegenau mit dem ZIP überein, die Verknüpfung zeigt auf `/Applications`; das Image wurde wieder ausgehängt.
- Sparkle-Ed25519-Signatur des veröffentlichten ZIPs kryptografisch gegen den eingebetteten Schlüssel geprüft. Dieser Schlüssel entspricht dem tatsächlich veröffentlichten 0.3.1-Paket; die Buildnummer steigt von 5 auf 7. Updates bestehender Installationen behalten damit denselben Vertrauensschlüssel.

Prüfprotokolle und erneut heruntergeladene Pakete liegen lokal unter `build/release-verification/`; lokale Vorprüfungen unter `build/release-review/`. Diese Build-Artefakte sind nicht versioniert. Es bleiben keine Veröffentlichungsschritte offen. Echte Rückuploads mit privaten SFTP-/SSH-/Nextcloud-Zugängen wurden weiterhin nicht manuell ausgeführt.
