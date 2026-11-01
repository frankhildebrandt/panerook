<img src="assets/icon.svg" width="64" height="64" alt="">

# PaneRook

Ein nativer macOS-Dateimanager, inspiriert von Midnight Commander. Zwei unabhängige Panels, direkte Tastaturbedienung und native macOS-Integration. Swift + AppKit, ohne zusätzliche Paketabhängigkeiten oder eingebettetes Terminal.

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

## Funktionsstand

- Zwei native Dateilisten mit Systemicons, Größe, Datum, Sortierung und vollständigem oder kompaktem Listenformat. Pfade verstehen absolute und relative Angaben sowie `~`; Verlauf, Hotlist und Finder-Anbindung ergänzen die Navigation.
- Pro Panel: Dateiliste, Schnellansicht, Info oder ein beim Aufklappen nachgeladener Verzeichnisbaum. Schnellansicht und Info folgen der Auswahl des anderen Panels. Dateimasken filtern Dateien; Ordner bleiben zum Navigieren sichtbar. Gruppen lassen sich per Maske markieren, abwählen oder umkehren.
- ZIP-, TAR- und tar.gz-/TGZ-Archive als virtuelle Ordner direkt in den Hauptpanels: Unterordner öffnen, Dateien hinein- und herauskopieren, verschieben/umbenennen, Ordner anlegen und Einträge löschen.
- Rekursives Kopieren/Verschieben mit Datei-/Gesamtfortschritt und Abbruch, neue Ordner, Papierkorb, harte und symbolische Links einschließlich relativer Links und Linkzielbearbeitung. Chmod und Chown arbeiten mit den Benutzerrechten von macOS; Chmod unterstützt gemischte Mehrfachauswahlen und Sonderbits.
- Rekursive Datei- und Textsuche mit Übernahme der Treffer ins Panel, byteweise Datei- und Verzeichnisvergleiche sowie berechnete Ordnergrößen. Diese Werkzeuge laufen in abbrechbaren Ergebnisfenstern.
- Quick Look, eingebaute Textvorschau mit wählbarer Codierung, Bearbeiten über TextEdit und Öffnen mit der Standard-App oder einer konfigurierten App-Zuordnung.
- Gemeinsame Aufgaben-Queue für Dateiaktionen, Suche, Vergleiche, Ordnergrößen, Shell-Befehle und Remote-Transfers: Fortschritt, Hintergrundmodus, Abbruch und erneut aufrufbare Ergebnisse. Benutzermenü, Befehls-/Dateichronik und eine Liste der geöffneten App-Fenster ergänzen den Ablauf.
- FTP, SSH-Shell, SFTP und Nextcloud (WebDAV über HTTPS) mit eigenem Remote-Browser für Navigation, Upload, Download, Ordner und Löschen; Details und Grenzen stehen unten.
- Native MC-Menükategorien „Links · Datei · Befehl · Optionen · Rechts“. F9 und das Menü-Symbol öffnen dieselben Kategorien im Fenster. Einstellungen steuern Layout, Zeilenhöhe, Symbole, Auswahlstatus, Rückfragen, Hell/Dunkel, Codierung und die Belegung von F1–F10.
- Gespeicherte Panelpfade, Sortierung, Filter, Codierung, Listenformat, Fensterposition und Panelbreite. Liquid Glass auf macOS 26+, native Vibrancy-Materialien auf älteren unterstützten Versionen; kompakte Pfadzeilen, ruhige Dateilisten und eine schmale Funktionstastenleiste.

Jedes Panel hat rechts am Pfad ein **Favoriten-Dropdown** (**⌥↓**). Es enthält **Volumes**, die vorhandenen Cloud-Anbieter (**iCloud Drive**, **Proton Drive**, **Dropbox**), **Netzwerk** und **Eigene Favoriten**. Volumes werden aus den gemounteten Laufwerken geladen; Cloud-Ordner aus den lokalen File-Provider-Pfaden und üblichen älteren Ablagen erkannt. Nicht vorhandene Cloud-Anbieter erscheinen nicht im Dropdown. Mehrere Konten stehen in einem Untermenü. Eine eigene Zuordnung lässt sich unter **Eigene Favoriten → Cloud-Ordner zuordnen** festlegen oder auf automatische Erkennung zurücksetzen. Es werden keine Cloud-Dateien zur Erkennung gelesen oder heruntergeladen.

**Eigene Favoriten** enthält die Ordner der bestehenden Hotlist sowie alle Einträge des Verbindungsarchivs. Das Menü kann den aktuellen Ordner oder einen gewählten Ordner hinzufügen und gespeicherte Ordner entfernen. Ein Favorit gehört beiden Dropdowns; geöffnet wird er im Panel, dessen Menü benutzt wurde. Verbindungen verwenden weiterhin den vorhandenen Remote-Browser, FTP und Nextcloud mit erneuter Passwortabfrage. Esc/F10/Ctrl-G schließen das Dropdown.

**Netzwerk** zeigt im jeweiligen Panel über Bonjour angekündigte SMB-/AFP-Server und bereits gemountete Netzwerkfreigaben. Enter/Doppelklick verwendet die native macOS-Anmeldung und Freigabeauswahl; anschließend öffnet PaneRook den Mountpunkt im Panel. **Mit Server verbinden …** nimmt eine `smb://`- oder `afp://`-Adresse entgegen. Dafür kann macOS lokalen Netzwerkzugriff verlangen. Finders private NetBIOS-/Verzeichnisdienst-Suche wird nicht nachgebaut; nicht angekündigte Server lassen sich über ihre Adresse verbinden. Mounts mit echten Zugangsdaten wurden mangels Testfreigabe nicht geprüft.

Der Kopier-/Verschiebedialog behält den bisherigen Ablauf: Quellmaske (`*`, `?`, Zeichenklassen), bearbeitbarer Zielpfad und Umbenennen einzelner Einträge. Enter bestätigt; Esc, F10 und Ctrl-G brechen ab und geben den Fokus an die Dateiliste zurück. Relative Ziele gelten ab dem Quellordner; die Maske filtert die aktuelle Auswahl.

Längere Vorgänge öffnen ein Fortschrittsfenster. **In den Hintergrund** (**⌥B**) gibt die Panels frei; die Aufgabe läuft weiter. Weitere Aufgaben kommen in die **FIFO-Queue** und beginnen der Reihe nach. **Befehl → Hintergrundaufgaben** oder **Aufgaben …** in der Statusleiste zeigt laufende, wartende und beendete Aufgaben mit Fortschrittsbalken. Dort lassen sich Details und Ergebnisse öffnen, Aufgaben abbrechen und beendete Einträge entfernen. Hintergrundaufgaben öffnen ihre Ergebnisse nicht ungefragt; Fehler bleiben in der Queue sichtbar.

Lokale Kopien zeigen übertragene Bytes für die aktuelle Datei und die gesamte Auswahl sowie erledigte Einträge. Zunächst wird die Auswahl ohne Prozentwert erfasst. Suche und Größenberechnung zeigen während der Erfassung einen unbestimmten Balken und geprüfte Einträge; Vergleiche melden messbare Byte- beziehungsweise Eintragsfortschritte. Remote-Transfers melden abgeschlossene ausgewählte Einträge, keinen Bytefortschritt innerhalb einer Datei. Shell-Befehle laufen mit einem unbestimmten Balken. **Abbrechen**, Esc, F10 oder Ctrl-G stoppen die Aufgabe; **In den Hintergrund** und das Schließen des Fortschrittsfensters lassen sie weiterlaufen. Einzelne native Datei-/Metadatenaufrufe werden zu Ende geführt; Stapel lassen sich zwischen Einträgen abbrechen. Die Queue gilt für die aktuelle App-Sitzung. Beim Beenden fragt PaneRook nach und wartet nach einem Abbruch auf die Bereinigung.

**Datei → Sparse-Datei erstellen …** legt im aktiven Panelordner eine Datei mit frei wählbarem Namen und logischer Größe an (B bis TiB, Dezimalzahlen mit Punkt oder Komma). Ungeschriebene Bereiche bleiben Speicherlöcher; vorhandene Dateien und Links werden nicht überschrieben. Enter erstellt, Esc/F10/Ctrl-G brechen den Dialog ab.

| Taste | Aktion |
| --- | --- |
| Tab | Panel wechseln |
| ↑ / ↓, ⇧, ⌘A | Auswählen / Mehrfachauswahl |
| Page Up / Page Down (fn↑ / fn↓) | Auswahl im Dateipanel eine sichtbare Seite zurück / weiter |
| Home / End (fn← / fn→) | Ersten / letzten Eintrag auswählen und anzeigen |
| Enter / Doppelklick | Ordner, Archiv oder Datei öffnen |
| Rücktaste / ⌘↑ | Übergeordneter Ordner |
| F1 | Tastaturhilfe |
| F2 | Benutzermenü |
| Leertaste / F3 / ⌘Y | Quick Look |
| F4 | In TextEdit bearbeiten |
| F5 / F6 | Ins andere Panel kopieren / verschieben |
| F7 / ⌘⇧N | Neuer Ordner |
| ⌘⌥N | Sparse-Datei erstellen |
| F8 / ⌘⌫ | Lokal in den Papierkorb legen; Archiveinträge nach Rückfrage löschen |
| F9 | MC-Menüs öffnen; Pfeiltasten navigieren, Enter wählt, Esc / F10 / Ctrl-G brechen ab |
| F10 | In der Dateiliste beenden; in Menüs und Dialogen abbrechen |
| ⌘L | Pfad eingeben |
| ⌥↓ | Favoriten des aktiven Panels |
| ⌘R | Beide Panels aktualisieren |
| ⌘⇧. | Versteckte Dateien umschalten |
| ⌘U | Panelpfade tauschen |
| ⌘⇧R | Im Finder zeigen |
| ⌘⇧F | Dateien suchen |
| ⌘K | Verbindungsarchiv |
| Ctrl-O | Panels ein-/ausblenden; bei ausgeblendeten Panels einen Shell-Befehl eingeben |
| Ctrl-D | Verzeichnis-Hotlist |

Dies ist die Standardbelegung. **Optionen → Tasten lernen** ändert die Funktionsaktionen; Esc und Ctrl-G bleiben zum Abbrechen reserviert. Auf Apple-Tastaturen brauchen die Funktionstasten je nach Systemeinstellung zusätzlich **fn**.

## Dateiarchive

**Enter oder Doppelklick** öffnet ZIP-, TAR-, tar.gz- und TGZ-Dateien im jeweiligen Panel wie einen Ordner. Die Pfadzeile zeigt den Archivpfad mit dem inneren Ordner, etwa `/Users/name/Downloads/paket.zip/dokumente`. Unterordner, Sortierung, Filter, versteckte Dateien, Verlauf, Rücktaste und **⌘↑** funktionieren wie in lokalen Ordnern; am Archivanfang führt „..“ zurück in den Ordner der Archivdatei. Das Auflisten liest die Archiveinträge, ohne das gesamte Archiv in einen Ordner zu entpacken. Komprimierte TAR-Dateien müssen dafür trotzdem durchlaufen und dekomprimiert werden.

- **F5** kopiert ausgewählte Dateien oder Ordner zwischen Archiv und lokalem Ordner sowie zwischen Archiven. Um Dateien hinzuzufügen, im Zielpanel das Archiv öffnen und im Quellpanel F5 verwenden.
- **F6** verschiebt Einträge oder benennt sie mit einem neuen Zielnamen um. Die Quelle wird erst nach erfolgreichem Schreiben des Ziels entfernt.
- **F7** legt einen Ordner im Archiv an.
- **F8 / ⌘⌫** löscht Archiveinträge einschließlich gewählter Unterordner nach ausdrücklicher Rückfrage endgültig. Für Archiveinträge gibt es keinen Papierkorb und kein Undo.

Bestehende Zielnamen werden nicht überschrieben. Änderungen schreiben das jeweilige Archiv zunächst in eine temporäre Datei neben dem Original und ersetzen es erst nach Erfolg. Das benötigt Zeit und freien Speicher für die neue Archivdatei und die zwischengespeicherte Auswahl; parallele Änderungen an der Archivdatei werden vor dem Ersetzen geprüft. Ein Transfer zwischen verschiedenen Archiven ist keine gemeinsame Transaktion über beide Dateien.

Archivaktionen und das Vorbereiten einer Vorschau laufen ebenfalls in der Aufgaben-Queue. Die Verarbeitung meldet die aktuelle Datei und messbare Dateibytes; der Gesamtfortschritt bleibt wegen mehrerer Lesedurchläufe bis zum Abschluss unbestimmt. Ein Abbruch vor dem Ersetzen lässt das ursprüngliche Archiv unverändert. Nach erfolgreichem Schreiben des Ziels wird beim Verschieben die Quelle noch entfernt.

**F3 / Leertaste** und das Öffnen einer enthaltenen Datei stellen nur die ausgewählten Inhalte als temporäre Kopien bereit. Änderungen in einer externen App werden nicht automatisch ins Archiv zurückgeschrieben; **F4** ist innerhalb von Archiven deaktiviert. Zum Bearbeiten zuerst in einen lokalen Ordner kopieren. Verschlüsselte Archive, das direkte Öffnen verschachtelter Archive sowie Archivfunktionen für Rechte, Eigentümer, Links, Sparse-Dateien, Shell-Befehle und lokale Such-/Vergleichswerkzeuge sind nicht unterstützt. Enthaltene Archive können zunächst herauskopiert und anschließend geöffnet werden. Remote-Transfers verwenden weiterhin lokale Ordner als Zwischenstation.

Archive mit Links oder Spezialdateien lassen sich auflisten, aber nicht ändern; beim Herauskopieren werden nur reguläre Dateien und Ordner unterstützt. Unsichere oder mehrdeutige Eintragspfade werden abgewiesen. Die Verarbeitung ist auf 100.000 Einträge, 16 GiB je Datei und 64 GiB je Schreib- oder Entpackvorgang begrenzt. Dateirechte einschließlich Ausführbarkeit bleiben beim Transfer erhalten; Sonderbits werden nicht übernommen.

## Befehle und Konfiguration

Das Benutzermenü und **Befehl ausführen** starten ausdrücklich gewählte Befehle mit `/bin/zsh -l -c` im aktuellen Panelordner. Ausgabe, Fehler und Exitcode erscheinen in einem eigenen Fenster; laufende Befehle lassen sich abbrechen. Es ist keine interaktive Terminalsession. **Anordnen** übernimmt vorhandene Dateipfade aus der Standardausgabe, einen Pfad pro Zeile, ins auslösende Panel.

Für eigene Befehle stehen diese Umgebungsvariablen bereit:

| Variable | Inhalt |
| --- | --- |
| `PANEROOK_FILE` | Pfad des ersten ausgewählten Eintrags |
| `PANEROOK_DIRECTORY` | Arbeitsverzeichnis des Befehls |
| `PANEROOK_OTHER_DIRECTORY` | Verzeichnis des anderen Panels |
| `PANEROOK_SELECTION_JSON` | JSON-Array aller ausgewählten Pfade |

Die drei Bearbeiten-Einträge im Befehl-Menü legen bei Bedarf JSON-Dateien unter `~/Library/Application Support/PaneRook/` an und öffnen sie in TextEdit. Jede Datei enthält ein Array von Einträgen:

| Datei | Einträge |
| --- | --- |
| `menu.json` | `title` und `command` für das Benutzermenü |
| `extensions.json` | `pattern` und `application` für Dateimuster und App-Pfad |
| `highlight.json` | `pattern` und `color` (`blue`, `green`, `orange`, `red`, `purple`, `gray`) |

App-Zuordnungen führen beim Öffnen keine Shell-Befehle aus. Die Befehlschronik lässt sich leeren und unter **Optionen → Konfiguration** abschalten. Layout, Darstellung und Panelzustand werden über die nativen Einstellungen verwaltet; **Einstellungen speichern** sichert zusätzlich den aktuellen Panelzustand.

## Remote-Verbindungen

**Links/Rechts → Verbindungsarchiv …** oder **⌘K** öffnet die gespeicherten FTP-, SFTP-, Shell- und Nextcloud-Verbindungen. Die Liste lässt sich nach Namen, Server, Benutzer oder Startpfad durchsuchen und nach Protokoll filtern. **Neu** legt einen Eintrag an, **Bearbeiten** ändert ihn, **Entfernen** löscht ihn; Entfernen lässt sich im geöffneten Archiv widerrufen. Enter oder Doppelklick verbindet mit dem gewählten Eintrag. Bei FTP und Nextcloud öffnet sich vorher die Passwortabfrage. Esc/F10/Ctrl-G schließen den jeweiligen Dialog.

Im Archiv: **⌘N** legt einen Eintrag an, **⌘E** bearbeitet die Auswahl; **⌘⌫** entfernt und **⌘Z** widerruft eine Entfernung, wenn die Liste fokussiert ist. Textfelder behalten ihre normale Textbearbeitung.

Die bisherigen Verbindungsdialoge bieten unter **Gespeichert** die Einträge ihres Protokolls an. **Im Archiv speichern** merkt die eingegebenen Daten oder aktualisiert den ausgewählten Eintrag. Gespeichert werden Name, Protokoll, Server, Port, Benutzer, Startpfad und optional der SSH-Schlüsselpfad. Passwörter und Schlüsselinhalt werden nicht archiviert. Das versionierte Archiv liegt in `~/Library/Application Support/PaneRook/connections.json`, bleibt nach einem Neustart erhalten und wird atomar mit Dateirechten `0600` geschrieben. Ungültige Archive werden gemeldet und nicht durch eine leere Liste überschrieben.

**Links/Rechts → FTP-/Shell-/SFTP-/Nextcloud-Verbindung** öffnet ein separates natives Browserfenster, gekoppelt an das auslösende lokale Panel. F5 lädt ausgewählte Remote-Einträge in dessen aktuellen Ordner. **Hochladen** sendet dessen lokale Auswahl ins angezeigte Remote-Verzeichnis. F7 legt Remote-Ordner an; F8 löscht nach Rückfrage auf dem Server. Bei FTP/SSH/SFTP verwendet PaneRook keinen Papierkorb; bei Nextcloud hängt eine Wiederherstellung vom serverseitigen Papierkorb ab. Die aktive VFS-Liste zeigt oder trennt offene Verbindungen. Esc/Ctrl-G brechen einen laufenden Remote-Vorgang ab; F10 bricht ab beziehungsweise schließt den Browser.

SSH und SFTP verwenden die macOS-Werkzeuge mit SSH-Schlüssel oder Agent und bereits bestätigten Hosts in `~/.ssh/known_hosts`; interaktive Passwortanmeldung und eine Ersteinrichtung des Hostvertrauens sind nicht enthalten. FTP verwendet `curl` und überträgt Zugangsdaten und Dateien unverschlüsselt. PaneRook speichert keine Verbindungskennwörter und übergibt FTP-/Nextcloud-Zugangsdaten über die Standardeingabe statt über Prozessargumente.

Für **Nextcloud** als Server die HTTPS-Adresse der Installation eintragen, etwa `https://cloud.example.org` oder `https://example.org/nextcloud`, dazu den Nextcloud-Benutzernamen und ein **App-Passwort** aus den persönlichen Nextcloud-Einstellungen unter **Sicherheit**. Der Standardport ist 443; ein Port in der Server-URL hat Vorrang vor dem Port-Feld. Der **Startpfad** bezieht sich auf die eigenen Dateien: `/` öffnet deren Wurzel, `/Dokumente` den entsprechenden Ordner. Den WebDAV-Pfad `/remote.php/dav/files/<Benutzer>` ergänzt PaneRook selbst. Die Verbindung verwendet `curl` mit HTTPS und Zertifikatsprüfung; HTTP und öffentliche Freigabelinks werden nicht unterstützt. Die [Nextcloud-Dokumentation](https://docs.nextcloud.com/server/stable/user_manual/en/files/access_webdav.html) beschreibt WebDAV und App-Passwörter.

Remote-Transfers unterstützen reguläre Dateien und Verzeichnisse, keine symbolischen Links oder Spezialdateien. Die Remote-Kollisionsprüfung erfolgt vor dem jeweiligen Transfer; sie bietet keine allgemeine atomare Garantie gegen Überschreiben bei parallelen Serveränderungen, insbesondere bei SFTP/FTP-Uploads. Nextcloud-Uploads senden zusätzlich `If-None-Match: *`, damit der Server bereits vorhandene Zieldateien ablehnt. Fehler oder Abbruch können bereits angelegte Remote-Dateien und Ordner zurücklassen. Remote-Verbindungen ersetzen derzeit keines der beiden lokalen Hauptpanels.

## Architektur

- `Sources/PaneRook/`: App-Lifecycle, Menüs, Zweipanel-Controller, native Dateilisten, Inspektoren, Werkzeugfenster, Einstellungen und Remote-Browser.
- `Sources/PaneRook/AppStyle.swift`: native Materialien, Rundungen und an die Systemdarstellung angepasste Leseflächen; ohne eigene Eventbehandlung.
- `Sources/PaneRookCore/`: lokale Dateioperationen/Metadaten, Archiv-VFS über die macOS-Systembibliothek libarchive, Suche und Vergleich, Prozessausführung sowie FTP/SSH/SFTP-/Nextcloud-Transport, unabhängig von der Oberfläche.
- `Tests/PaneRookCoreTests/`: isolierte Dateisystem-, Such-, Vergleichs-, Prozess- und Transporttests; ein SFTP-Test spricht den lokalen System-`sftp-server` direkt an. Netzwerkzugänge zu realen SSH-/FTP-/Nextcloud-Servern werden dadurch nicht geprüft.
- `Resources/Info.plist` und `scripts/build-app.sh`: lokales macOS-App-Bundle.
- `scripts/generate-icon.swift`: reproduzierbares App-Icon (SVG, PNG und alle macOS-Icongrößen in `Resources/PaneRook.icns`); erneut erzeugen mit `swift scripts/generate-icon.swift`.
- [MC-Untersuchung und Ausgangspunkt](docs/midnight-commander-reference.md).

## Grenzen und nächste Schritte

Die App arbeitet mit den Rechten des angemeldeten Benutzers und erhöht sie nicht für Chmod/Chown. macOS kann für geschützte Ordner eine Zugriffsfreigabe verlangen. Eine App-Sandbox und Security-Scoped Bookmarks sind noch nicht eingerichtet.

Kopier- und Verschiebeaktionen fragen nach und überschreiben keine bestehenden Ziele. Fehler bei der Eingabe bleiben im Dialog sichtbar; der Dialog lässt sich auch aus einem Textfeld mit Esc abbrechen. Ein Konflikt wird vor Beginn der gesamten Auswahl geprüft. Attribute und symbolische Links werden beibehalten; MCs zusätzliche Optionen für Regex-Umbenennung, Folgen von Links, Verzeichniszusammenführung und Attributumschaltung sind noch nicht umgesetzt. Laufzeitfehler können eine teilweise abgeschlossene Auswahl hinterlassen; die App meldet das und lädt beide Panels neu. Lokale Kopien verwenden ein temporäres Ziel und veröffentlichen den aktuellen Eintrag erst nach vollständiger Übertragung ohne Überschreiben. Bei Abbruch wird dieses temporäre Ziel entfernt; vorher abgeschlossene Einträge bleiben erhalten. Verschieben auf demselben Volume verwendet eine atomare Umbenennung, über Volume-Grenzen Kopieren und anschließendes Entfernen der Quelle. Es gibt noch kein Undo für Dateiaktionen; Dateien im Papierkorb lassen sich über den Finder zurückholen.

Inhaltssuche und die eigene Textvorschau lesen höchstens 1 MiB pro Datei. Die Suche endet bei 10.000 Treffern oder 250.000 geprüften Einträgen. Datei- und Verzeichnisvergleiche vergleichen reguläre Dateien bis 1 GiB pro Datei; der Verzeichnisvergleich ist auf 100.000 Einträge je Seite begrenzt. Ordnergrößen werden bis 1.000.000 Einträge berechnet. Symbolische Links werden bei diesen rekursiven Werkzeugen nicht verfolgt. Begrenzungen und nicht lesbare Einträge werden im Ergebnis gemeldet. Shell-Ausgaben werden zur Anzeige auf 4 MiB je Ausgabestrom begrenzt.

Noch offen: interaktives Terminal/PTY, interner Editor, Tabs, Drag & Drop, automatische Dateisystembeobachtung und erweiterte Kopier-/Konfliktdialoge mit Überschreiben, Zusammenführen, Linkfolge und Wiederaufnahme. Die Menüeinträge sind native Umsetzungen des MC-Arbeitsablaufs; vollständige Funktions- oder Formatkompatibilität mit MC wird nicht behauptet.
