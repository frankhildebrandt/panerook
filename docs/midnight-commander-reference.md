# Midnight Commander als Ausgangspunkt

Untersucht am 1. November 2026 auf dem Entwicklungsrechner.

## Lokale Installation

- Einstieg: `/opt/homebrew/bin/mc`, Symlink auf Homebrews Version 4.8.33.
- Der Einstieg ist ein Bash-Wrapper, der `diffutils` im `PATH` ergänzt und die tatsächliche Binary startet.
- Binary: `/opt/homebrew/Cellar/midnight-commander/4.8.33/libexec/bin/mc`, Mach-O arm64.
- SHA-256 der Binary: `bcd7625d7ca37c4b853d4414229a49ed57585df3450e49bb35f82571817ad7b0`.
- `mc --version`: GNU Midnight Commander 4.8.33, GLib 2.86.0, S-Lang 2.3.3, libssh2 1.11.1; eingebauter Editor, Subshell, Hintergrundaktionen und virtuelle Dateisysteme einschließlich FTP/SFTP/Archive.

## Laufzeitbeobachtung mit REA

Ein kontrollierter PTY-Lauf startete den lokalen Wrapper mit `--nosubshell --nocolor`, links dem Projektverzeichnis und rechts `/private/tmp`. Eigene XDG-Verzeichnisse unter `/private/tmp/panerook-mc-reference` trennten die Testkonfiguration von der normalen MC-Konfiguration.

Beobachtet: zwei Dateipanels mit Name/Größe/Datum, Elternordner `..`, Funktionsleiste und Panelwechsel durch Tab. Beenden über die Terminalsequenz Escape+0 endete mit Exitcode 0. REA bestätigte die Bereinigung der eigenen Prozessgruppe. Die Prozessabtastung blieb unvollständig; Netzwerk- und Dateisystemeffekte wurden nicht erfasst. Die Beobachtung belegt Navigation und Aufbau, keine vollständige Verhaltensgleichheit aller MC-Funktionen.

REA Evidence: `ev_271a8cb09ae465424229f7b311de66d1047dd73803a7675c5036ec8bb7d4c2ed`.

## Quellcode

Offizielles Repository: <https://github.com/MidnightCommander/mc>.

Gelesene Referenzen aus `master` (nicht als exakt versionsgleich mit der installierten Binary behandelt):

- [`README`](https://github.com/MidnightCommander/mc/blob/master/README), Blob `4baf2281ff969405a2fa5dd15340f4085698a97c`: Funktionsübersicht, VFS, Editor und Lizenzhinweis.
- [`misc/mc.default.keymap`](https://github.com/MidnightCommander/mc/blob/master/misc/mc.default.keymap), Blob `4f237ce7e772d1574aedd46d98bcae225d316394`: Tab wechselt Panels; F3 Vorschau, F4 Bearbeiten, F5 Kopieren, F6 Verschieben, F7 Ordner, F8 Löschen.

## Umsetzung in PaneRook

Das Zweipanel-Prinzip und die wichtigsten Funktionstasten werden übernommen. AppKit liefert die native Oberfläche; Foundation-Dateioperationen ersetzen die MC-Ausführung. Quick Look, Standard-Apps, TextEdit und Papierkorb integrieren die macOS-Konventionen. Es wurde kein MC-Quellcode übernommen und MC ist keine Laufzeitabhängigkeit. Die Referenz nennt GPL-3.0-or-later für MC; eine spätere Übernahme von MC-Code wäre eine separate Architektur- und Lizenzentscheidung.

Lokale Operationen und Remote-Transporte sind getrennte Core-Bausteine. FTP, SSH, SFTP und Nextcloud verwenden die Systemwerkzeuge `curl`, `ssh` und `sftp`; MC bleibt auch dafür keine Laufzeitabhängigkeit. Nextcloud verwendet WebDAV über HTTPS. Die Remote-Oberfläche ist ein eigenes natives Fenster, kein Ersatz eines lokalen Hauptpanels und noch kein allgemeines Archiv-/VFS-Provider-System.

## Verifikation des ursprünglichen Bootstraps

Sieben XCTest-Fälle prüfen natürliche Dateisortierung/versteckte Dateien, Kopieren und Verschieben, vollständige Konfliktprüfung vor einer Auswahl, rekursive Ziele einschließlich Symlinks, vorhandene defekte Symlinks, rekursive Ordnerkopien und ungültige Namen/Pfade. Alle bestanden auf dem Entwicklungsrechner.

In der nativen App wurden Pfadeingabe und Navigation, F3/Quick Look sowie F5 mit Bestätigungsdialog und anschließender Aktualisierung beider Panels geprüft. Die UI-Kopie erfolgte ausschließlich mit eigenen Testdateien unter `/private/tmp/PaneRookSmoke.PXEstn`; Quelle und Ziel wurden danach byteweise verglichen. App-Bundle und Signatur wurden lokal validiert.

## Weiterentwicklung: Kopierdialog und Tastatur

Ein weiterer kontrollierter REA-Lauf der installierten MC-Version zeigte den F5-Dialog mit Quellmaske, Zielpfad und zusätzlichen Optionen für Links und Attribute. Der Referenzdialog wurde abgebrochen und MC endete mit Exitcode 0; Evidence: `ev_4ec6a983dd70cd7f0001959e2a745539a64240a1d250f46368b59c3385cf1d5f`.

PaneRook verwendet jetzt einen eigenen nativen Kopier-/Verschiebedialog mit bearbeitbarer Quellmaske und Zielpfad. Eine einzelne Datei oder ein Ordner kann dabei einen neuen Namen erhalten. Quellmasken filtern die Auswahl über Shell-Muster; Regex-Transformationen und MCs weitere Kopieroptionen sind noch nicht umgesetzt. Attribute und symbolische Links bleiben erhalten.

Elf Dateisystemtests bestanden einschließlich Zielumbenennung, Quellmasken, ungültigen Eingaben und rekursiven Zielen über Symlinks. Native UI-Prüfung: Esc aus dem aktiven Zieltextfeld, Rückkehr des Fokus in die Dateiliste und erneutes F5, Bestätigung eines geänderten Zielnamens mit Enter, inline angezeigter Konflikt ohne Überschreiben, Ctrl-G und F10 zum Abbrechen. Die mit Enter erzeugte Testkopie wurde byteweise geprüft. Es wurde keine Datei im Projekt durch die Tests kopiert oder verschoben.

## MC-Menüs

Die deutsche Menüstruktur der installierten 4.8.33 wurde mit F9, Abwärtspfeil und vier Menüwechseln beobachtet. Der Lauf führte keine Menüaktion aus und endete mit Exitcode 0. REA Evidence: `ev_3dc0e272eca8402fb776dcc124d0c028bcfbec0563ced10835e7a2c2c03b9ded`.

Die Reihenfolge wurde zusätzlich gegen die [Menüdefinitionen des Tags 4.8.33](https://github.com/MidnightCommander/mc/blob/4.8.33/src/filemanager/filemanager.c) geprüft. PaneRook übernimmt die fünf Kategorien und ihre Einträge/Gruppierung als native AppKit-Menüs. macOS-Bearbeiten und Hilfe sowie bestehende ⌘-Kurzbefehle ergänzen sie. F9 öffnet einen nativen Menü-Popup mit diesen Kategorien, ohne eine zusätzliche permanente Zeile im Dateibereich. Die Navigation im Popup folgt den nativen verschachtelten macOS-Menüs. Es gibt keinen Terminal-Wrapper und keine kopierte MC-Implementierung.

Die Menüeinträge sind mit nativen Funktionen verbunden; ihre Semantik wird dort an macOS angepasst, wo MC Terminalzustand oder seine eigenen Konfigurationsformate verwendet. „Löschen“ verwendet lokal den macOS-Papierkorb. F10 ist kontextabhängig: Menü/Dialog abbrechen, sonst App beenden. Esc und Ctrl-G brechen ebenfalls ab. Im Remote-Browser dient F10 zum Abbrechen beziehungsweise Schließen des Fensters.

## Ergänzte Menüfunktionen und native Adaptionen

| MC-Bereich | Umsetzung in PaneRook |
| --- | --- |
| Links / Rechts | Dateiliste, Schnellansicht, Info und nachgeladenes Baum-Panel; Voll-/Kompaktliste, Sortierung, Filter und Codierung. Inspektoren folgen der Auswahl des gegenüberliegenden Panels. Elternordner und Verzeichnisse bleiben bei Dateimasken sichtbar. |
| Datei | Gefilterte Ansicht als ausdrücklich gestarteter Shell-Filter; native Chmod-/Chown-Sheets, harte/absolute/relative symbolische Links und Bearbeitung bestehender Linkziele. Rechte und Eigentümer werden ohne Rechteerhöhung geändert; ausgewählte Symlinks werden dabei nicht verfolgt. |
| Befehl | F2-Benutzermenü, Datei-/Inhaltssuche, Datei-/Verzeichnisvergleich, Ordnergrößen, Panelübernahme von Suchtreffern oder extern ausgegebenen Pfaden, Historien und Hotlist. |
| Panels an/aus | Ctrl-O blendet die Hauptpanels aus und zeigt eine native Befehlseingabe. Ergebnisse erscheinen in separaten Fenstern; es gibt keine interaktive PTY-Subshell. |
| Hintergrundaufgaben | Gemeinsame serielle Aufgaben-Queue für lokale Dateiaktionen, Suche/Vergleich/Größenberechnung, Shell-Befehle und Remote-Transfers. Fortschrittsfenster lassen sich in den Hintergrund schicken und erneut öffnen; wartende und laufende Aufgaben lassen sich abbrechen. Ergebnisse bleiben abrufbar. |
| Bildschirmliste | Auswahl der sichtbaren App-Fenster statt MCs Terminalbildschirme. |
| Konfigurationsdateien | Native JSON-Dateien für Benutzermenü, Dateimuster/App-Zuordnungen und farbliche Hervorhebungen; keine Parser für MCs bestehende Menü-/Erweiterungsformate. |
| Optionen | Befehlschronik, Panelwiederherstellung, horizontales/vertikales Layout, Toolbar/Funktionsleiste, Zeilenhöhe, Symbole, Status, Papierkorbrückfrage, System/Hell/Dunkel sowie anlernbare Funktionstasten. „Darstellungsbits“ öffnet die Textcodierung statt Terminal-Bitoptionen. |

Standardkürzel ergänzen den bisherigen Ablauf: F2 öffnet das Benutzermenü, ⌘⇧F die Suche, Ctrl-D die Hotlist und Ctrl-O die Befehlseingabe. **Optionen → Tasten lernen** kann die Aktionen von F1–F10 neu belegen; Esc und Ctrl-G bleiben reserviert. Der kompakte Kopier-/Verschiebedialog behält Quellmaske, Ziel, Enter und die Abbruchwege Esc/F10/Ctrl-G bei. Zusätzliche Kopieroptionen für Überschreiben/Zusammenführen, Regex-Umbenennung, Folgen von Links und Attributumschaltung sind weiterhin offen. Lokale Kopien zeigen Bytefortschritt für Datei und gesamte Auswahl sowie erledigte Einträge. Abbruch bereinigt das temporäre Ziel des laufenden Eintrags; vorher abgeschlossene Einträge bleiben erhalten.

Benutzerbefehle laufen mit `/bin/zsh -l -c` im Panelordner und erhalten `PANEROOK_FILE`, `PANEROOK_DIRECTORY`, `PANEROOK_OTHER_DIRECTORY` und `PANEROOK_SELECTION_JSON`. Das Anordnen erwartet einen vorhandenen Dateipfad pro Standardausgabezeile. Die Dateien `menu.json`, `extensions.json` und `highlight.json` liegen unter `~/Library/Application Support/PaneRook/` und werden über das Befehl-Menü in TextEdit geöffnet. Erweiterungsregeln wählen eine App; Dateinamen oder Dateizuordnungen lösen keine automatische Shell-Ausführung aus.

## Remote-Verbindungen

FTP-/Shell-/SFTP-/Nextcloud-Menüaktionen öffnen einen nativen Remote-Browser und binden ihn an das lokale Panel, aus dessen Menü sie gestartet wurden. Downloads gehen in dessen aktuellen Ordner; Uploads verwenden dessen aktuelle Auswahl. Navigation, Aktualisieren, rekursive Datei-/Ordnertransfers, Ordnererstellung und Löschen sind implementiert. Aktive Verbindungen lassen sich über die VFS-Liste anzeigen oder trennen. Bei FTP/SSH/SFTP verwendet PaneRook keinen Papierkorb; Nextcloud kann gelöschte Einträge abhängig von der Serverkonfiguration im eigenen Papierkorb ablegen. Symbolische Links und Spezialdateien werden bei Remote-Dateiaktionen nicht unterstützt.

SSH/SFTP verwenden Schlüssel oder SSH-Agent, `BatchMode=yes` und `StrictHostKeyChecking=yes`; unbekannte Hosts müssen zuvor außerhalb der App bestätigt worden sein. Interaktive SSH-Passwortanmeldung ist nicht enthalten. FTP verwendet Klartext für Dateien und Zugangsdaten. Nextcloud verwendet die HTTPS-Installationsadresse, den Benutzernamen und ein App-Passwort; Unterverzeichnis-Installationen werden unterstützt. Der Startpfad ist relativ zur Dateiwurzel des Benutzers, der WebDAV-Endpunkt wird automatisch ergänzt. HTTP und öffentliche Freigabelinks sind nicht enthalten. Verbindungskennwörter werden nicht persistiert; FTP-/Nextcloud-Zugangsdaten gelangen über die Standardeingabe in `curl`, nicht in dessen Argumentliste. Nextcloud lässt sich im Verbindungsarchiv speichern, filtern, bearbeiten und aus den Favoriten öffnen; beim Verbinden wird das App-Passwort erneut abgefragt.

Remote-Kollisionen werden vor dem jeweiligen Transfer geprüft. Diese Vorprüfung ist keine allgemeine atomare Nichtüberschreibgarantie: parallele Serveränderungen können insbesondere bei SFTP/FTP-Uploads zu Überschreiben führen. Nextcloud-Uploads verwenden zusätzlich `If-None-Match: *` gegen bereits vorhandene Zieldateien. Abbruch und Fehler können bereits übertragene Remote-Einträge zurücklassen. Ein abgeschlossener Download wird aus einem lokalen temporären Staging-Verzeichnis an seinen Zielpfad verschoben.

## Grenzen und Verifikation der Ergänzungen

Die eigene Textvorschau und Inhaltssuche lesen bis 1 MiB je Datei. Die Suche ist auf 10.000 Treffer und 250.000 geprüfte Einträge begrenzt. Reguläre Dateien werden bis 1 GiB byteweise verglichen; ein Verzeichnisvergleich verarbeitet bis 100.000 Einträge je Seite. Die Größenberechnung endet spätestens nach 1.000.000 Einträgen. Rekursive Werkzeuge verfolgen keine symbolischen Links; Dateivergleiche vergleichen bei Symlinks das Linkziel. Ergebnisfenster melden Grenzen, ausgelassene Dateien und Lesefehler. Die eigene Textansicht zeigt dekodierten Text; für andere Formate wird Quick Look verwendet.

Core-Tests decken unter anderem Suchmasken und Inhaltsgrenzen, Abbruch, byteweise Vergleiche, Symlink-Zyklen, Rechte-Masken, Linkkollisionen, atomare Linkzielbearbeitung und Prozessausführung einschließlich begrenzter Ausgabe ab. Transporttests prüfen Pfadquotierung, die Übergabe von Zugangsdaten, Abbruch sowie unvollständige Downloads. Der SFTP-Integrationstest startet `/usr/libexec/sftp-server` direkt über den Systemclient und prüft echte Listings, Upload/Download/Löschen, rekursive Verzeichnisse und literale Sonderzeichen in Dateinamen. Er prüft weder SSH-Authentifizierung noch die Verbindung zu einem externen Netzwerkserver. Für Live-FTP-/SSH-/SFTP-/Nextcloud-Server lagen keine Testzugangsdaten vor.

Die historischen UI-Prüfungen oben belegen den jeweiligen Bootstrap-Stand. Die Ergänzungen behaupten keine vollständige MC-Parität: Archiv-VFS, interaktives Terminal/PTY, interner Editor, Tabs, Drag & Drop, Dateisystembeobachtung und die erweiterten Kopier-/Konfliktoptionen bleiben nächste Entwicklungsschritte.

## Fortschritt und Aufgaben-Queue

Für diese Ergänzung wurden MCs [filegui.c](https://github.com/MidnightCommander/mc/blob/master/src/filemanager/filegui.c) und die Abschnitte „File Operations“ und „Background Jobs“ der [offiziellen Manpage](https://github.com/MidnightCommander/mc/blob/master/doc/man/mc.1.in) betrachtet. MC führt Datei- und Gesamtbalken sowie Zähler; der Kopier-/Verschiebedialog bietet Hintergrundausführung und eine separate Jobverwaltung. PaneRook setzt dieses Bedienmuster eigenständig mit AppKit und einer seriellen DispatchQueue um. Eine FIFO-Warteschlange ist hier eine zusätzliche PaneRook-Entscheidung, keine Behauptung über MCs Scheduling.

Fortschrittsfenster bieten **In den Hintergrund** / **⌥B**, Abbruch und später **Ergebnis anzeigen**. Schließen blendet laufende Details aus. Die Queue zeigt Status, Balken, Details und Abbruch sowie das Entfernen beendeter Aufgaben. Die Statusleiste enthält den aktuellen Vorgang und die Zahl wartender Aufgaben. Hintergrundresultate stehlen keinen Fokus. Erfassung und Shell-Befehle verwenden unbestimmte Balken, lokale Kopien Datei-/Gesamtbytes, Vergleiche Bytes beziehungsweise Einträge und Remote-Aktionen die abgeschlossene Auswahl. Die Queue bleibt im Speicher der aktuellen Sitzung; Beenden aktiver Aufgaben erfordert eine Rückfrage und wartet auf die Bereinigung.

Tests prüfen FIFO-Reihenfolge, Fehlerfortsetzung, Abbruch wartender und laufender Aufgaben, Fortschrittsmeldungen, Kopierabbruch innerhalb einer Datei, Metadatenerhalt, Symlinks und erneut geprüfte Zielkonflikte nach Wartezeit. Remote-Bytefortschritt, Pausieren/Fortsetzen und dauerhafte Wiederaufnahme nach App-Neustart sind nicht enthalten.
