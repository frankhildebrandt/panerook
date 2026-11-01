<img src="assets/icon.svg" width="64" height="64" alt="">

# PaneRook

Ein nativer macOS-Dateimanager, inspiriert von Midnight Commander. Zwei unabhängige Panels, direkte Tastaturbedienung und native macOS-Integration. Swift + AppKit, ohne externe Abhängigkeiten oder eingebettetes Terminal.

## Starten

Voraussetzungen: macOS 14 oder neuer und Xcode mit ausgewählter Command Line Toolchain.

```sh
./scripts/build-app.sh
open build/PaneRook.app
```

Für einen optimierten Build: `./scripts/build-app.sh release`.
Für Entwicklung in Xcode: `open Package.swift`, Scheme **PaneRook** ausführen. Das Skript erzeugt zusätzlich das eigentliche App-Bundle und signiert es lokal ad hoc. Distribution und Notarisierung sind noch nicht eingerichtet.

```sh
swift test
```

In einer Umgebung, die verschachtelte Build-Sandboxen verhindert:

```sh
PANEROOK_DISABLE_BUILD_SANDBOX=1 ./scripts/build-app.sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" swift test --disable-sandbox --cache-path "$PWD/.build/cache"
```

## Stand 0.1

- Zwei native Dateilisten mit Systemicons, Größe, Änderungsdatum und Spaltensortierung; Ordner stehen zuerst.
- Pfadeingabe (absolut, relativ, `~`), Navigation, Verlauf zurück, Benutzerordner und Finder-Anbindung.
- Mehrfachauswahl per ⇧/⌘-Klick und ⌘A; Anzeige versteckter Dateien.
- Rekursives Kopieren und Verschieben ins andere Panel, neue Ordner und macOS-Papierkorb.
- MC-artiger Kopier-/Verschiebedialog mit Quellmaske (`*`, `?`, Zeichenklassen), bearbeitbarem Zielpfad und Umbenennen einzelner Einträge. Enter bestätigt; Esc, F10 und Ctrl-G brechen ab. Relative Ziele gelten ab dem Quellordner; die Maske filtert die aktuelle Auswahl.
- Native Quick-Look-Vorschau, Bearbeiten über TextEdit und Öffnen mit der Standard-App.
- Gespeicherte Panelpfade, Fensterposition, Panelbreite und Anzeige versteckter Dateien.
- Verzeichnislesen und Dateioperationen im Hintergrund.

| Taste | Aktion |
| --- | --- |
| Tab | Panel wechseln |
| ↑ / ↓, ⇧, ⌘A | Auswählen / Mehrfachauswahl |
| Enter / Doppelklick | Ordner oder Datei öffnen |
| Rücktaste / ⌘↑ | Übergeordneter Ordner |
| Leertaste / F3 / ⌘Y | Quick Look |
| F4 | In TextEdit bearbeiten |
| F5 / F6 | Ins andere Panel kopieren / verschieben |
| F7 / ⌘⇧N | Neuer Ordner |
| F8 / ⌘⌫ | In den Papierkorb legen |
| ⌘L | Pfad eingeben |
| ⌘R | Beide Panels aktualisieren |
| ⌘⇧. | Versteckte Dateien umschalten |
| ⌘U | Panelpfade tauschen |
| ⌘⇧R | Im Finder zeigen |

Auf Apple-Tastaturen brauchen die Funktionstasten je nach Systemeinstellung zusätzlich **fn**.

## Architektur

- `Sources/PaneRook/`: App-Lifecycle, Menüs, Zweipanel-Controller, native `NSTableView`-Dateilisten und Quick Look.
- `Sources/PaneRookCore/`: Dateisystemmodell und validierte Dateioperationen, unabhängig von der Oberfläche.
- `Tests/PaneRookCoreTests/`: Operationen auf isolierten temporären Verzeichnissen.
- `Resources/Info.plist` und `scripts/build-app.sh`: lokales macOS-App-Bundle.
- `scripts/generate-icon.swift`: reproduzierbares App-Icon (SVG, PNG und alle macOS-Icongrößen in `Resources/PaneRook.icns`); erneut erzeugen mit `swift scripts/generate-icon.swift`.
- [MC-Untersuchung und Ausgangspunkt](docs/midnight-commander-reference.md).

## Bewusste Grenzen des Bootstraps

Die App arbeitet mit lokalen Dateisystemen und den Rechten des angemeldeten Benutzers. macOS kann für geschützte Ordner eine Zugriffsfreigabe verlangen. Eine App-Sandbox und Security-Scoped Bookmarks sind noch nicht eingerichtet.

Kopier- und Verschiebeaktionen fragen nach und überschreiben keine bestehenden Ziele. Fehler bei der Eingabe bleiben im Dialog sichtbar; der Dialog lässt sich auch aus einem Textfeld mit Esc abbrechen. Ein Konflikt wird vor Beginn der gesamten Auswahl geprüft. Attribute und symbolische Links werden beibehalten; MCs zusätzliche Optionen für Regex-Umbenennung, Folgen von Links, Verzeichniszusammenführung und Attributumschaltung sind noch nicht umgesetzt. Laufzeitfehler können eine teilweise abgeschlossene Auswahl hinterlassen; die App meldet das und lädt beide Panels neu. Große Operationen haben bisher eine Aktivitätsanzeige, aber keinen prozentualen Fortschritt oder Abbruch. Es gibt noch kein Undo für Dateiaktionen; Dateien im Papierkorb lassen sich über den Finder zurückholen.

Noch offen: integriertes Terminal, interner Editor, rekursive Suche, Archive, SFTP/VFS, Tabs, Drag & Drop, automatische Dateisystembeobachtung und Konfliktdialoge mit Überschreiboptionen.
