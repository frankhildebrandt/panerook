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

Für spätere VFS-Anbindungen lässt sich das isolierte Dateisystemmodul um ein Provider-Protokoll erweitern, sobald konkrete Remote- oder Archivfunktionen feststehen.

## Verifikation des Bootstraps

Sieben XCTest-Fälle prüfen natürliche Dateisortierung/versteckte Dateien, Kopieren und Verschieben, vollständige Konfliktprüfung vor einer Auswahl, rekursive Ziele einschließlich Symlinks, vorhandene defekte Symlinks, rekursive Ordnerkopien und ungültige Namen/Pfade. Alle bestanden auf dem Entwicklungsrechner.

In der nativen App wurden Pfadeingabe und Navigation, F3/Quick Look sowie F5 mit Bestätigungsdialog und anschließender Aktualisierung beider Panels geprüft. Die UI-Kopie erfolgte ausschließlich mit eigenen Testdateien unter `/private/tmp/PaneRookSmoke.PXEstn`; Quelle und Ziel wurden danach byteweise verglichen. App-Bundle und Signatur wurden lokal validiert.

## Weiterentwicklung: Kopierdialog und Tastatur

Ein weiterer kontrollierter REA-Lauf der installierten MC-Version zeigte den F5-Dialog mit Quellmaske, Zielpfad und zusätzlichen Optionen für Links und Attribute. Der Referenzdialog wurde abgebrochen und MC endete mit Exitcode 0; Evidence: `ev_4ec6a983dd70cd7f0001959e2a745539a64240a1d250f46368b59c3385cf1d5f`.

PaneRook verwendet jetzt einen eigenen nativen Kopier-/Verschiebedialog mit bearbeitbarer Quellmaske und Zielpfad. Eine einzelne Datei oder ein Ordner kann dabei einen neuen Namen erhalten. Quellmasken filtern die Auswahl über Shell-Muster; Regex-Transformationen und MCs weitere Kopieroptionen sind noch nicht umgesetzt. Attribute und symbolische Links bleiben erhalten.

Elf Dateisystemtests bestanden einschließlich Zielumbenennung, Quellmasken, ungültigen Eingaben und rekursiven Zielen über Symlinks. Native UI-Prüfung: Esc aus dem aktiven Zieltextfeld, Rückkehr des Fokus in die Dateiliste und erneutes F5, Bestätigung eines geänderten Zielnamens mit Enter, inline angezeigter Konflikt ohne Überschreiben, Ctrl-G und F10 zum Abbrechen. Die mit Enter erzeugte Testkopie wurde byteweise geprüft. Es wurde keine Datei im Projekt durch die Tests kopiert oder verschoben.
