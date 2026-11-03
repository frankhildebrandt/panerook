# PaneRook – ergänzende Bedienungsreferenz

## Funktionsstand

- Zwei native Dateilisten mit Systemicons, Größe, Datum, Sortierung und vollständigem oder kompaktem Listenformat. Pfade verstehen absolute und relative Angaben sowie `~`; Verlauf, Hotlist und Finder-Anbindung ergänzen die Navigation.
- Git-Repository-Ordner zeigen bereits im übergeordneten Verzeichnis ihren Branch und Status neben dem Namen: **✓** sauber, **●** Änderungen oder unversionierte Einträge, **!** Konflikte. **↑/↓** geben lokale Commit-Abstände zum bekannten Upstream an. Ein Tooltip schlüsselt vorgemerkte und übrige Änderungen auf. Die Anzeige funktioniert auch im kompakten Listenformat und für Worktrees; sie wird im Hintergrund beim Laden und Aktualisieren (**⌘R**) der Ordnerliste ermittelt, ohne Netzwerkzugriff.
- Pro Panel: Dateiliste, Schnellansicht, Info, ein beim Aufklappen nachgeladener Verzeichnisbaum oder ein eingebettetes Ghostty-Terminal. Schnellansicht und Info folgen der Auswahl des anderen Panels. Dateimasken filtern Dateien; Ordner bleiben zum Navigieren sichtbar. Gruppen lassen sich per Maske markieren, abwählen oder umkehren.
- Git-Repositories mit Branch-/Statusanzeige in beiden Panels, Statusfiltern und gespeicherten Watched-Markierungen. Ein eigenes Git-Fenster bietet Diffs, Staging, Commits, Branch- und Versionswechsel, Stashes, Tags und Remote-Abgleich.
- ZIP-, TAR- und tar.gz-/TGZ-Archive als virtuelle Ordner direkt in den Hauptpanels: Unterordner öffnen, Dateien hinein- und herauskopieren, verschieben/umbenennen, Ordner anlegen und Einträge löschen.
- Nativer Dateiaustausch lokaler Dateien per Drag & Drop und Datei-Zwischenablage, auch mit Finder, Desktop und anderen Apps.
- Rekursives Kopieren/Verschieben mit Datei-/Gesamtfortschritt und Abbruch, neue Ordner, Papierkorb, harte und symbolische Links einschließlich relativer Links und Linkzielbearbeitung. Chmod und Chown arbeiten mit den Benutzerrechten von macOS; Chmod unterstützt gemischte Mehrfachauswahlen und Sonderbits.
- Rekursive Datei- und Textsuche mit Übernahme der Treffer ins Panel, byteweise Datei- und Verzeichnisvergleiche sowie berechnete Ordnergrößen. Diese Werkzeuge laufen in abbrechbaren Ergebnisfenstern.
- Quick Look, eingebaute Textvorschau mit wählbarer Codierung, Bearbeiten über TextEdit und Öffnen mit der Standard-App oder einer konfigurierten App-Zuordnung.
- Gemeinsame Aufgaben-Queue für Dateiaktionen, Suche, Vergleiche, Ordnergrößen, Shell-Befehle und Remote-Transfers: Fortschritt, Hintergrundmodus, Abbruch und erneut aufrufbare Ergebnisse. Benutzermenü, Befehls-/Dateichronik und eine Liste der geöffneten App-Fenster ergänzen den Ablauf.
- FTP, SSH-Shell, SFTP und Nextcloud (WebDAV über HTTPS) als Dateiliste im gewählten Panel für Navigation, Kopieren, Verschieben, Umbenennen, Vorschau, Ordner und Löschen; Details und Grenzen stehen unten.
- Native MC-Menükategorien „Links · Datei · Befehl · Optionen · Rechts“. F9 und das Menü-Symbol öffnen dieselben Kategorien im Fenster. Einstellungen steuern Layout, Zeilenhöhe, Symbole, Auswahlstatus, Rückfragen, Hell/Dunkel, Codierung und die Tastaturbelegung aller App-Aktionen.
- Gespeicherte Panelpfade, Sortierung, Filter, Codierung, Listenformat, Fensterposition und Panelbreite. Liquid Glass auf macOS 26+, native Vibrancy-Materialien auf älteren unterstützten Versionen; kompakte Pfadzeilen, ruhige Dateilisten und eine schmale Funktionstastenleiste.

Jedes Panel hat rechts am Pfad ein **Favoriten-Dropdown** (**⌥↓**). Es enthält **Volumes**, die vorhandenen Cloud-Anbieter (**iCloud Drive**, **Proton Drive**, **Dropbox**), **Netzwerk** und **Eigene Favoriten**. Volumes werden aus den gemounteten Laufwerken geladen; Cloud-Ordner aus den lokalen File-Provider-Pfaden und üblichen älteren Ablagen erkannt. Nicht vorhandene Cloud-Anbieter erscheinen nicht im Dropdown. Mehrere Konten stehen in einem Untermenü. Eine eigene Zuordnung lässt sich unter **Eigene Favoriten → Cloud-Ordner zuordnen** festlegen oder auf automatische Erkennung zurücksetzen. Es werden keine Cloud-Dateien zur Erkennung gelesen oder heruntergeladen.

In Dateiliste und Verzeichnisbaum zeigt die Pfadleiste den verfügbaren Speicherplatz des aktuellen Volumes, etwa **128 GB frei**. Das gilt auch für eingebundene Netzwerkfreigaben, sofern macOS deren Kapazität meldet. Die Anzeige wird beim Ordnerwechsel, mit **⌘R** und nach Dateiaktionen aktualisiert. Bei wenig Platz in der Pfadleiste, unbekannter Kapazität, Archiven, Suchergebnissen und den übrigen Panelansichten bleibt sie ausgeblendet. Bei lokalen Cloud-Ordnern bezieht sie sich auf das lokale Volume, nicht auf das Cloud-Kontingent.

**Eigene Favoriten** enthält die Ordner der bestehenden Hotlist sowie alle Einträge des Verbindungsarchivs. Das Menü kann den aktuellen Ordner oder einen gewählten Ordner hinzufügen und gespeicherte Ordner entfernen. Ein Favorit gehört beiden Dropdowns; geöffnet wird er im Panel, dessen Menü benutzt wurde. Verbindungen öffnen sich im Panel des verwendeten Menüs, FTP und Nextcloud mit erneuter Passwortabfrage. Esc/F10/Ctrl-G schließen das Dropdown.

**Git-Repositories** im Favoriten-Dropdown (**⌥↓**) merkt sich automatisch die zuletzt besuchten Repositories, auch beim Besuch eines Unterordners oder eines verknüpften Worktrees. Die Liste bleibt über App-Neustarts erhalten und wird von beiden Panels und allen Fenstern geteilt. Worktrees desselben Repositories stehen gemeinsam unter einem Eintrag. Im aktuellen Repository sind seine Worktrees direkt im Menü erreichbar, mit Branch, Ordnername und einem Häkchen am aktuellen Worktree; die Auswahl öffnet den Worktree im jeweiligen Panel. Die vollständigen Pfade stehen im Tooltip. Fehlende, von Git als entfernbar markierte Worktrees sind deaktiviert; gesperrte Worktrees lassen sich weiterhin öffnen. Beim Öffnen des Favoritenmenüs wird die gespeicherte Worktree-Liste im Hintergrund aktualisiert; **Worktrees aktualisieren** und **⌘R** laden sie erneut. **Aus Liste entfernen** entfernt nur den gespeicherten Repository-Eintrag. Der nächste Besuch merkt ihn erneut. Gespeichert werden höchstens 100 Repositories, ohne Netzwerkzugriff oder Änderungen an Git-Repositories.

**Netzwerk** zeigt im jeweiligen Panel über Bonjour angekündigte SMB-/AFP-Server und bereits gemountete Netzwerkfreigaben. Enter/Doppelklick verwendet die native macOS-Anmeldung und Freigabeauswahl; anschließend öffnet PaneRook den Mountpunkt im Panel. **Mit Server verbinden …** nimmt eine `smb://`- oder `afp://`-Adresse entgegen. Dafür kann macOS lokalen Netzwerkzugriff verlangen. Finders private NetBIOS-/Verzeichnisdienst-Suche wird nicht nachgebaut; nicht angekündigte Server lassen sich über ihre Adresse verbinden. Mounts mit echten Zugangsdaten wurden mangels Testfreigabe nicht geprüft.

Der Kopier-/Verschiebedialog behält den bisherigen Ablauf: Quellmaske (`*`, `?`, Zeichenklassen), bearbeitbarer Zielpfad und Umbenennen einzelner Einträge. Enter bestätigt; Esc, F10 und Ctrl-G brechen ab und geben den Fokus an die Dateiliste zurück. Relative Ziele gelten ab dem Quellordner; die Maske filtert die aktuelle Auswahl.

Längere Vorgänge öffnen ein Fortschrittsfenster. **In den Hintergrund** (**⌥B**) gibt die Panels frei; die Aufgabe läuft weiter. Weitere Aufgaben kommen in die **FIFO-Queue** und beginnen der Reihe nach. Der **Aufgaben**-Button rechts in der Titelleiste oder **Befehl → Hintergrundaufgaben** öffnet ein separates Fenster mit laufenden, wartenden und beendeten Aufgaben samt Fortschrittsbalken. Der Button bleibt auch ohne aktive Aufgaben erreichbar; ein weiterer Klick holt dasselbe Fenster nach vorne. Die Aufgaben-Statusleiste erscheint nur, solange Aufgaben laufen, warten oder abgebrochen werden; danach wird sie ausgeblendet. Bei ausgeblendeter Symbolleiste bleibt die Aufgabenliste über das Menü erreichbar. Dort lassen sich Details und Ergebnisse öffnen, Aufgaben abbrechen und beendete Einträge entfernen. Hintergrundaufgaben öffnen ihre Ergebnisse nicht ungefragt; Fehler bleiben in der Queue sichtbar.

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
| ⌘C / ⌘V | Lokale Dateiauswahl kopieren / im fokussierten Panelordner einsetzen |
| ⌘⌥V | Dateien aus der Zwischenablage in den fokussierten Panelordner verschieben |
| F7 / ⌘⇧N | Neuer Ordner |
| ⌘⌥N | Sparse-Datei erstellen |
| F8 / ⌘⌫ | Lokal in den Papierkorb legen; Archiveinträge nach Rückfrage löschen |
| ⌘Z / ⇧⌘Z | Lokale Dateiaktion rückgängig / wiederholen (in der Dateiliste) |
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
| ⌘⇧P | Befehlspalette öffnen |
| Ctrl-O | Panels ein-/ausblenden; bei ausgeblendeten Panels einen Shell-Befehl eingeben |
| Ctrl-D | Verzeichnis-Hotlist |

Dies ist die Standardbelegung. **Einstellungen** (**⌘,**) → **Tastatur → Belegung bearbeiten …** zeigt alle App-Aktionen mit ihrer aktuellen und ursprünglichen Belegung, einschließlich Aktionen ohne Standardkürzel. Die Liste lässt sich nach Aktion, Bereich oder Tastenkombination durchsuchen. **Belegen …** zeichnet die nächste Tastenkombination auf; auch Return, Tab, Escape und Funktionstasten sind möglich. Mit **Speichern** wird sie dauerhaft übernommen. **Belegung entfernen** gibt ein Kürzel dauerhaft frei, **Standard wiederherstellen** setzt nur die ausgewählte Aktion zurück; **Alle zurücksetzen …** stellt nach Bestätigung die gesamte Standardbelegung wieder her. Bisher gespeicherte Belegungen bleiben erhalten.

Die Bereiche unterscheiden Hauptfenster, Dateipanels, Textbearbeitung, Konsole, Dialoge, Git, Remote-Panels, Verbindungsarchiv, Aufgaben, Suchergebnisse und Netzwerk. Dieselbe Kombination darf in getrennten Fenstern unterschiedliche Aktionen auslösen; Konflikte innerhalb gleichzeitig aktiver Bereiche verhindern das Speichern. Alternative Kürzel einer Aktion, etwa Enter und Enter auf dem Ziffernblock oder F3 und ⌘Y, sind als eigene Einträge anpassbar. Normale Zeicheneingaben in Textfeldern bleiben erhalten; reine Zeichenbelegungen für Dateiaktionen gelten in den Listen. Dialogbestätigung und Abbruch (standardmäßig Enter beziehungsweise Esc/F10/Ctrl-G) sind ebenfalls anpassbar. In Remote-Panels gelten für Kopieren/Herunterladen, neue Ordner, Löschen, Öffnen und Navigation dieselben Belegungen wie im Hauptfenster. Zusätzliche Remote-Belegungen lassen sich separat vergeben; F10 bricht einen Remote-Vorgang ab oder trennt die aktive Verbindung. Menüeinträge, die Funktionstastenleiste und die Tastaturhilfe zeigen die aktuelle Belegung. Auf Apple-Tastaturen brauchen die Funktionstasten je nach Systemeinstellung zusätzlich **fn**.

## Befehlspalette

**Befehl → Befehlspalette …** (**⌘⇧P**) öffnet eine durchsuchbare Einblendung im Hauptfenster. Sie enthält aktuell verfügbare Aktionen mit ihren eingestellten Tastenkürzeln, eigene Ordnerfavoriten aus der Hotlist, gespeicherte Verbindungen, bekannte Git-Worktrees und besuchte Ordner beider Panels. Der vollständige Pfad beziehungsweise Verbindungstyp und Server unterscheiden gleichnamige Ziele. Ein Ordner, der zugleich Favorit und besuchter Ort ist, erscheint nur einmal. Nicht erreichbare Favoriten bleiben auffindbar; ein Fehler beim Öffnen wird wie bei normaler Panelnavigation gemeldet. Als entfernbar markierte und Bare-Worktrees werden ausgelassen.

Die Suche berücksichtigt Namen, Kategorien, Pfade, Branches, Server, Benutzer und Aktionskennungen. Groß-/Kleinschreibung und Akzente spielen keine Rolle. Mehrere durch Leerzeichen getrennte Suchbegriffe müssen alle passen; Abkürzungen dürfen Buchstaben auslassen, solange deren Reihenfolge stimmt. Genaue Namen, Wortanfänge und zusammenhängende Treffer stehen vor weit gestreuten Abkürzungen. Ohne Suchtext stehen Aktionen zuerst; innerhalb der besuchten Orte bleibt die Reihenfolge des jeweiligen Panelverlaufs erhalten.

**↑/↓** wählen einen Treffer, **Page Up/Page Down** springen um mehrere Zeilen und **Home/End** zum Anfang oder Ende. **Return** oder **Doppelklick** führt den ausgewählten Treffer aus. **Esc**, die eingestellten Dialog-Abbruchkürzel oder ein Klick außerhalb schließen die Palette und stellen den vorherigen Fokus wieder her. Die Aktion **Befehlspalette …** lässt sich unter **Einstellungen → Tastatur** umbelegen oder ohne Kürzel verwenden. Die Suche im Belegungseditor bleibt davon unabhängig.

Die Palette führt dieselben registrierten Aktionen und Verfügbarkeitsprüfungen wie die Menüs aus. Verfügbare Aktionen werden vor dem Fokuswechsel ins Suchfeld ermittelt und unmittelbar vor der Ausführung im ursprünglichen Kontext erneut geprüft. So bleiben auch Datei-Undo und Zwischenablageaktionen aus der Dateiliste auffindbar, während Textbearbeitungskürzel das Suchfeld bearbeiten. Bestehende Rückfragen und Passwortdialoge bleiben erhalten. Ziele öffnen sich im beim Aufruf aktiven Panel. Solange ein Dialog, ein Menü oder ein anderes Feature-Fenster aktiv ist, wird keine Hauptfensterpalette geöffnet. Im Terminal bleibt die Palette über ihr Command-Kürzel erreichbar; reine Dateilistenaktionen werden dort nicht angeboten, und Shell-Tasten behalten außerhalb der Palette ihre bisherige Funktion. Kontextaktionen separater Git-, Aufgaben- oder Verbindungsfenster werden weiterhin in ihren eigenen Fenstern ausgeführt. Datenquellen werden bei jedem Öffnen neu gelesen; Fehler einer Quelle werden in der Palette angezeigt und lassen die übrigen Quellen benutzbar.

## Rückgängig und Operationsprotokoll

In einer lokalen **Dateiliste** stellt **Bearbeiten → Rückgängig** (**⌘Z**) die letzte protokollierte Dateiaktion wieder her; **Wiederholen** (**⇧⌘Z**) führt sie erneut aus. Die Menübezeichnung nennt die konkrete Aktion und den Dateinamen beziehungsweise die Anzahl der Einträge. Die gleichnamigen Aktionen im **Datei**-Menü sind zusätzlich frei belegbar. In Textfeldern und im Ghostty-Terminal wird kein Datei-Undo ausgelöst. **⌘Z** im Verbindungsarchiv stellt weiterhin entfernte Verbindungen wieder her.

Unterstützt werden lokale **Umbenennungen**, **Verschiebungen**, **Ordner anlegen** und **In den Papierkorb legen**. Eine Mehrfachauswahl bildet einen Auftrag; Undo arbeitet in umgekehrter Reihenfolge. Neu angelegte Ordner werden nur entfernt, wenn sie unverändert und leer sind. Papierkorb-Undo verwendet den von macOS gemeldeten tatsächlichen Ablagepfad und stellt den ursprünglichen Namen am ursprünglichen Ort wieder her. Redo legt die Einträge erneut in den Papierkorb; ein inzwischen geleerter Papierkorb verhindert die Wiederherstellung.

**Datei → Operationsprotokoll …** zeigt die letzten 100 Versuche einschließlich Datum, Richtung, Quell-/Zielpfaden, abgeschlossener Anzahl und Fehlern. Undo und Redo halten jeweils höchstens 100 Aufträge im Arbeitsspeicher dieses Fensters. Beim Schließen des Fensters oder Beenden der App endet diese Historie. Eine neue protokollierte Dateiaktion verwirft die Redo-Historie. Bereits im Finder wiederhergestellte oder außerhalb von PaneRook veränderte Einträge werden nicht automatisch übernommen.

Vor jedem Wiederherstellungsschritt prüft PaneRook Datei- und Volume-Identität, Inhalt (auch in Unterordnern), Linkziele und Attribute. Bestehende Ziele einschließlich defekter Links werden nicht überschrieben. Bei geändertem Inhalt, ersetzten Ordnern, fehlenden Volumes oder Zugriffsfehlern bleibt der betreffende Schritt offen. Den Konflikt beheben bzw. das ursprüngliche Volume wieder einbinden und die Aktion erneut aufrufen. Änderungen werden vorsichtig abgelehnt, auch wenn Pfad und Dateigröße noch gleich aussehen.

Undo und Redo laufen über dieselbe serielle Aufgabenqueue und aktualisieren danach beide Panels. Sie sind verfügbar, wenn keine Aufgabe mehr aktiv ist. Bei Abbruch oder einem Teilfehler bleiben abgeschlossene Schritte erhalten und können in der Gegenrichtung ausgeführt werden; noch offene Schritte bleiben separat wiederholbar. Die Aufgabenliste und das Operationsprotokoll zeigen die tatsächlich abgeschlossene Anzahl. Bereits veröffentlichte Schritte werden einschließlich ihrer Zustandsaufnahme zu Ende geführt, bevor der Abbruch den nächsten Eintrag verhindert.

Die Inhaltsprüfung liest Dateien vollständig und kann bei großen oder ausgelagerten Cloud-Dateien dauern bzw. deren Download auslösen. Pro ausgewähltem Eintrag werden höchstens 100.000 Dateien/Ordner geprüft, einzelne erweiterte Attribute bis 16 MiB. Spezialdateien und nicht sicher lesbare Zustände werden abgelehnt. Bei einem Verschieben über Volume-Grenzen wird zuerst vollständig kopiert; kann die Quelle anschließend nicht vollständig entfernt werden, meldet PaneRook beide Pfade zur manuellen Prüfung. Für diesen unvollständigen Eintrag gibt es kein automatisches Undo. Kopiebasierte Volume-Wechsel erzeugen außerdem neue Identitäten; dadurch können ältere, davon abhängige Schritte auch nach einer Wiederherstellung vorsichtshalber als Konflikt abgelehnt werden. Externe Programme können weiterhin gleichzeitig Dateien verändern; die Prüfungen sperren das Dateisystem nicht. Ein nach dem Verschieben nicht mehr lesbarer Zustand verhindert ebenfalls ein automatisches Undo.

**Kopieren**, Sparse-Dateien, Metadaten-/Linkänderungen, **Shell-Befehle**, Git-Schreibaktionen, **Remote-** und **Archivaktionen** werden nicht durch Datei-Undo zurückgenommen. Der Finder bleibt eine weitere Möglichkeit, lokale Dateien aus dem Papierkorb zurückzuholen.

## Ghostty-Terminal im Panel

**Links/Rechts → Ghostty-Terminal** startet im bisherigen lokalen Panelordner eine interaktive Shell mit Ghosttys nativer Terminaldarstellung. Ghostty muss nicht separat installiert werden. Der Kopf zeigt den Terminaltitel und das zuletzt von der Shell gemeldete lokale Arbeitsverzeichnis. Die mitgelieferte Shell-Integration unterstützt zsh und bash; bei anderen Shells braucht die Verzeichnisverfolgung lokale OSC-7-Meldungen.

Das gegenüberliegende Dateipanel bleibt unabhängig navigierbar. **F5 Kopieren** und **F6 Verschieben** verwenden das im Terminalkopf angezeigte Verzeichnis als vorgeschlagenes Ziel. Nach einem `cd` wird dieses Ziel aktualisiert. Sobald der Transferdialog geöffnet ist, bleibt dessen Zielpfad fest, auch wenn sich die Shell danach weiterbewegt. Bestehende Rückfragen und Konfliktregeln gelten weiter. Ein per SSH geöffnetes entferntes Verzeichnis wird nicht als lokaler Zielpfad übernommen.

**⌘⌥Tab** wechselt den Fokus zum anderen Panel. Tab, Pfeiltasten, Esc, Funktionstasten und Ctrl-Kombinationen wie Ctrl-C, Ctrl-D und Ctrl-O gehen im Terminal an die Shell, auch wenn sie sonst PaneRook-Aktionen auslösen. **⌘C/⌘V** kopieren beziehungsweise fügen Terminaltext ein; **⌘A** markiert den Terminalinhalt. Der Panelwechsel lässt sich unter **Einstellungen → Tastatur** umbelegen.

**Dateiliste** oder **Links/Rechts → Dateiliste** kehrt zur bisherigen Dateiliste und Auswahl zurück. Beim erneuten Öffnen erscheint dieselbe Terminalsitzung mit ihrem Verlauf und aktuellen Verzeichnis. **⌘L** öffnet die Pfadeingabe in der Dateiliste. Aktualisieren und abgeschlossene Dateioperationen starten die Shell nicht neu. `exit` beendet die Shell und zeigt wieder die Dateiliste; das Schließen des Fensters oder Ersetzen des Panels durch eine Remote-Verbindung beendet die Sitzung ebenfalls. Terminalsitzungen werden nach einem App-Neustart nicht wiederhergestellt. In einem Archiv oder einem Remote-Panel ist der Terminalmodus nicht verfügbar.

## Drag & Drop und Datei-Zwischenablage

In einer geladenen lokalen **Dateiliste** kopiert **⌘C** die ausgewählten Dateien als native Datei-URLs in die macOS-Zwischenablage. **⌘V** kopiert sie in den Ordner der jetzt fokussierten Dateiliste; **⌘⌥V** verschiebt sie dorthin. Das funktioniert auch mit im Finder kopierten Dateien. Mehrfachauswahl, Unicode, Leerzeichen, Zeilenumbrüche und Sonderzeichen in Namen bleiben erhalten. Auswahl- und Panelwechsel nach dem Kopieren ändern die erfassten Quellen nicht. Im Menü **Datei** stehen dieselben Dateiaktionen; die bisherigen **Bearbeiten → Kopieren/Einsetzen** und ihre gespeicherten Belegungen verwenden weiter die native Responder Chain. In Pfad-, Such- und anderen Textfeldern sowie im Ghostty-Terminal bleiben **⌘C/⌘V** Textaktionen. Ausschneiden von Dateien mit ⌘X ist nicht vorgesehen.

Dateien lassen sich zwischen den Panels sowie aus Finder, Desktop und Apps mit echten Datei-URLs in eine lokale Dateiliste ziehen. Eine hervorgehobene **Ordnerzeile** ist das Ziel; zwischen Zeilen oder auf freier Listenfläche gilt der **Panelordner**. Reguläre Dateien sind keine Drop-Ziele. Innerhalb desselben Volumes ist Verschieben die Vorgabe, über Volume-Grenzen Kopieren, sofern die Quell-App die Operation anbietet. **⌥** erzwingt Kopieren, **⌘** Verschieben. macOS zeigt die angebotene Operation am Mauszeiger und hebt das Ziel hervor. **⌘⌥** für Link-Erstellung wird nicht angeboten. Selbst-Drops, Ordner in eigene Unterordner (auch über symbolische Links), fehlende Ziele, doppelte Zielnamen und vorhandene Zieldateien werden abgewiesen.

Einfügen und angenommene Drops öffnen den bestehenden **Kopieren/Verschieben-Dialog**. Erst die Bestätigung reiht den Auftrag in dieselbe serielle Aufgaben-Queue wie F5/F6 ein. Quellen und Ziel sind vorher erfasst; spätere Navigation oder eine neue Zwischenablage ersetzen sie nicht. Quellmaske, Konfliktprüfung ohne Überschreiben, Fortschritt, Abbruch und Fehleranzeige gelten unverändert. Ein abgebrochener Dialog verändert keine Dateien. Die Zwischenablage bleibt erhalten; nach einem Verschieben verweisen ihre Datei-URLs auf die bisherigen, nun fehlenden Quellen. Erneutes Einfügen meldet den Fehler.

**Grenzen:** Aus PaneRook zu Finder, Desktop und anderen Apps gezogene Dateien werden als Kopien angeboten; die Ziel-App führt den externen Empfang aus. Verschieben aus PaneRook in einen solchen Ordner geht über dessen Öffnen im zweiten Panel und F6 oder über ⌘C/⌘⌥V im Finder. Remote- und Archivinhalte werden weder als scheinbar lokale URLs noch als temporäre Vorschaukopien angeboten. Sie lassen sich zuerst mit **F5** in einen lokalen Ordner kopieren; die eigentliche lokale Archivdatei kann wie jede andere Datei gezogen werden. Datei-Versprechen anderer Apps, reine Pfadtexte und gemischte Zwischenablagen aus Dateien und anderen Objekten werden nicht angenommen. Ziele in Remote-/Archivansichten und im Verzeichnisbaum sind nicht unterstützt. Suchergebnislisten können lokale Treffer exportieren und Drops auf konkrete Ordnerzeilen annehmen, haben aber kein Hintergrundziel zum Einfügen. Während einer Navigation sind die alten Listenzeilen für den Austausch gesperrt.

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

## Git und Versionen

**Links/Rechts → Git-Diff und Verlauf** oder **Befehl → Git → Git-Diff und Verlauf im Panel** (**⌘⌥G**) macht das jeweilige Panel zum Versionsviewer. Der Git-Ordner und die Auswahl stammen immer aus dem **anderen Panel**: Eine ausgewählte Datei öffnet ihren Dateiverlauf; ein ausgewähltes Verzeichnis zeigt nur Commits und Diffs innerhalb dieses Verzeichnisses. Ohne eindeutige Auswahl dient der aktuelle Ordner des anderen Panels zur Repository-Erkennung. Auswahl- und Ordnerwechsel werden automatisch übernommen, auch zwischen Repositories. Der eigene Ordner des Viewer-Panels bleibt für die Rückkehr zur Dateiliste erhalten. Die Ansicht lässt sich zwischen Auswahl und gesamtem Repository umschalten. Über die Versionsauswahl oder **Älter/Neuer** springst du durch die letzten 200 Commits entlang des ersten Elternteils. Der **Commit-Diff** zeigt die Änderung zur vorherigen Version, **Datei** den vollständigen damaligen Dateiinhalt. Dateiumbenennungen werden im Verlauf berücksichtigt. **Arbeitskopie** und **Staged** zeigen aktuelle Änderungen; Diffs sind als Unified Diff und Side-by-Side Diff darstellbar. Die Versionsnavigation ist eine schreibgeschützte Vorschau und verändert weder HEAD noch Arbeitsdateien. **Dateiliste** stellt die bisherige Liste samt Auswahl wieder her; die Versionsauswahl bleibt bei unveränderten Einträgen im anderen Panel erhalten. Remote-, Archiv- und Netzwerkansichten im anderen Panel zeigen einen entsprechenden Hinweis statt des bisherigen Verlaufs. **⌘R** lädt auch geöffnete Versionsviewer neu.

In einem lokalen Git-Arbeitsverzeichnis erscheinen **Branch**, Anzahl geänderter Dateien und **Ahead/Behind** zum konfigurierten Upstream zusammen mit Git-Filter und Stern rechtsbündig in der Pfadzeile, sofern Pfad und Git-Bedienelemente genügend Platz haben. Bei schmalen Panels oder langen Pfaden und Branchnamen bleibt die Git-Gruppe in einer eigenen Zeile darunter. Die Anordnung passt sich beim Ändern der Panelbreite automatisch an. Die Git-Spalte zeigt den Status von Index und Arbeitskopie, bei Ordnern einen zusammengefassten Status. **⌘R** aktualisiert Dateiliste und Git-Status. Die Anzeige unterstützt auch Unterordner, verknüpfte Worktrees, neue Repositories ohne Commit und einen losgelösten HEAD.

Pfadzeile und Repository-Markierungen in der Dateiliste zeigen zunächst den zuletzt bekannten Status aus einem gemeinsamen Cache, auch nach einem App-Neustart. Zusätzlich merkt sich PaneRook während der aktuellen Sitzung den vollständigen Git-Dateistatus von bis zu 20 Worktrees im Arbeitsspeicher. Dieser Stand gilt für das gesamte Repository: Auch beim ersten Öffnen eines Unterordners stehen Git-Spalte und Statusfilter sofort bereit, sobald das Repository bereits geladen wurde, auch in einem anderen Panel. Verschachtelte Repositories und Submodule verwenden ihren eigenen Status. Bei jedem Laden und Aktualisieren wird unabhängig von einem Cache-Treffer ein neuer Status im Hintergrund abgefragt und die Anzeige ersetzt. Meldet die Abfrage keinen Repository-Status mehr, verschwindet die alte Anzeige. Dauerhaft gespeichert werden höchstens 200 kompakte Anzeigeeinträge; die vollständigen Dateistatuswerte werden beim Beenden verworfen.

Der Filter daneben kombiniert die bestehende Dateimaske mit **Changed**, **Staged**, **Untracked**, **Konflikte**, **Stashed**, **Watched**, **Tracked** oder **Ignoriert**. Eltern und Ordner mit passenden Nachfahren bleiben zur Navigation sichtbar. Die Auswahl des Git-Filters wird pro Panel gespeichert; außerhalb eines Repositorys und in Suchergebnissen greift sie nicht. Versteckte Dateien richten sich weiterhin nach der Einstellung für versteckte Dateien. Gelöschte Dateien sind im Git-Fenster sichtbar, da sie in der normalen Dateiliste fehlen.

Der **Stern** markiert ausgewählte Dateien oder Ordner als **Watched**. Das sind lokale, dauerhaft gespeicherte PaneRook-Markierungen pro Repository; die Markierung eines Ordners gilt auch für seine Nachfahren. **Tracked** bezeichnet dagegen die von Git versionierten Dateien. **Stashed** umfasst die Pfade aus allen vorhandenen Stashes einschließlich dort gesicherter unversionierter Dateien; Dateien, die aktuell nur im Stash existieren, erscheinen im Git-Fenster.

Ein Klick auf die Branchanzeige oder **Befehl → Git → Repository, Status und Versionen …** (**⌘⇧G**) öffnet das Git-Fenster. Es enthält:

- **Dateien:** Status- und Pfadfilter, Diffs von Arbeitskopie und Index, Stage/Unstage der Auswahl, Commit-Nachricht und Watched-Markierungen.
- **Verlauf:** bis zu 200 Commits mit Patch-Vorschau, optionaler Dateiverlauf und Anzeige des Dateiinhalts einer Version. **Version auschecken** wechselt nach Rückfrage zum gewählten Commit; **Neuer Branch** ermöglicht die Weiterarbeit auf dieser Version.
- **Branches und Tags:** lokale und Remote-Branches wechseln, neue Branches und Tags anlegen, Tags auschecken, einen Branch mergen und bereits integrierte lokale Branches löschen.
- **Stashes:** Änderungen einschließlich unversionierter Dateien sichern, Vorschau, Anwenden, Pop und Löschen nach Rückfrage.
- **Remote:** Fetch, Pull ausschließlich als Fast-Forward und Push an den konfigurierten Remote.

Über der Vorschau schaltet **Unified Diff / Side-by-Side Diff** zwischen dem gemeinsamen Patch und der Gegenüberstellung von **Vorher** und **Nachher** um. Die Gegenüberstellung richtet geänderte Zeilen aus, zeigt Zeilennummern und markiert entfernte Zeilen rot sowie hinzugefügte grün. Beide Seiten scrollen vertikal gemeinsam. Der Umschalter verwendet die bereits geladene Vorschau für Arbeitskopie, Staged, Verlauf und Stashes; unversionierte Textdateien erscheinen als neu hinzugefügter Inhalt.

**Befehl → Git → Repository im aktuellen Ordner anlegen …** initialisiert ein Repository. Git-Aufrufe laufen im Hintergrund mit `/usr/bin/git`; sie verwenden die vorhandene Git-Konfiguration, Identität, Remotes und Zugangsdaten. Interaktive Passwort- und SSH-Abfragen werden nicht geöffnet. Fehler und Konflikte werden angezeigt und die Ansichten anschließend aktualisiert. Branch- und Versionswechsel verwenden keinen erzwungenen Checkout. Rebase, interaktives Staging einzelner Hunks, Submodule-Verwaltung und das Bearbeiten der Remote-Konfiguration haben noch keine eigene Oberfläche.

## Einstellungen und Themes

**PaneRook → Einstellungen …** (⌘,) und **Optionen → Einstellungen …** öffnen denselben SettingsDialog. Die Seitenleiste mit Suche bündelt Allgemein, Aussehen, Layout, Panels, Nachfragen, Codierung, Tastatur, Verbindungen und Updates. Änderungen werden sofort angewendet und dauerhaft gespeichert; Esc, F10 oder Ctrl-G schließen den Dialog.

Unter **Aussehen** stehen die Farbschemata **System**, **Hell** und **Dunkel** sowie sechs Themes zur Wahl: **PaneRook**, **Rose**, **Grove**, **Ocean**, **Ember** und **Iris**. Vorschaubilder zeigen beide Helligkeitsvarianten. Das Theme färbt Panelhintergründe, Auswahl, aktive Rahmen und Akzente. „System“ folgt dem macOS-Erscheinungsbild. Vorhandene Einstellungen und die bisherigen Hell-/Dunkel-Werte bleiben erhalten.

**Tastatur** öffnet den durchsuchbaren Belegungseditor für alle App-Aktionen, einschließlich Aktionen ohne Standardkürzel. Kombinationen können geändert, entfernt und zurückgesetzt werden; Konflikte innerhalb gleichzeitig aktiver Bereiche verhindern das Speichern. **Verbindungen** bündelt das Remote-Zeitlimit und versteckte Remote-Dateien, **Updates** die Sparkle-Einstellungen.

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

App-Zuordnungen führen beim Öffnen keine Shell-Befehle aus. Die Befehlschronik lässt sich leeren und unter **Einstellungen → Allgemein** abschalten. Layout, Darstellung und Panelzustand werden über die nativen Einstellungen verwaltet; **Einstellungen speichern** sichert zusätzlich den aktuellen Panelzustand.

## Remote-Verbindungen

**Links/Rechts → Verbindungsarchiv …** oder **⌘K** öffnet die gespeicherten FTP-, SFTP-, Shell- und Nextcloud-Verbindungen. Die Liste lässt sich nach Namen, Server, Benutzer oder Startpfad durchsuchen und nach Protokoll filtern. **Neu** legt einen Eintrag an, **Bearbeiten** ändert ihn, **Entfernen** löscht ihn; Entfernen lässt sich im geöffneten Archiv widerrufen. Enter oder Doppelklick verbindet mit dem gewählten Eintrag. Bei FTP und Nextcloud öffnet sich vorher die Passwortabfrage. Esc/F10/Ctrl-G schließen den jeweiligen Dialog.

Im Archiv: **⌘N** legt einen Eintrag an, **⌘E** bearbeitet die Auswahl; **⌘⌫** entfernt und **⌘Z** widerruft eine Entfernung, wenn die Liste fokussiert ist. Textfelder behalten ihre normale Textbearbeitung.

Die bisherigen Verbindungsdialoge bieten unter **Gespeichert** die Einträge ihres Protokolls an. **Im Archiv speichern** merkt die eingegebenen Daten oder aktualisiert den ausgewählten Eintrag. Gespeichert werden Name, Protokoll, Server, Port, Benutzer, Startpfad und optional der SSH-Schlüsselpfad. Passwörter und Schlüsselinhalt werden nicht archiviert. Das versionierte Archiv liegt in `~/Library/Application Support/PaneRook/connections.json`, bleibt nach einem Neustart erhalten und wird atomar mit Dateirechten `0600` geschrieben. Ungültige Archive werden gemeldet und nicht durch eine leere Liste überschrieben.

**Links/Rechts → FTP-/Shell-/SFTP-/Nextcloud-Verbindung** öffnet die Verbindung im gewählten Panel. Über **⌘K** gewählte Verbindungen öffnen sich im aktiven Panel. Pfadzeile, Zurück-Pfeil, `..`, Enter/Doppelklick, Tab und **⌘L** funktionieren wie bei lokalen Verzeichnissen. Sortierung nach Name, Größe und Änderungsdatum, kompaktes Listenformat, Filter, versteckte Dateien und Gruppenauswahl verwenden dieselben Panelmenüs und Einstellungen. Über das Favoriten-Dropdown (**⌥↓**) lassen sich auch aus einem verbundenen Panel lokale Laufwerke, Ordner und gespeicherte Verbindungen öffnen.

- **F5** kopiert die Auswahl ins gegenüberliegende Panel: lokal → Server, Server → lokal oder zwischen zwei Verbindungen.
- **F6** verschiebt die Auswahl nach Rückfrage ins gegenüberliegende Panel. Innerhalb derselben Verbindung verwendet PaneRook die Umbenennung des Servers. Bei Transfers wird die Quelle erst nach erfolgreicher Übertragung entfernt.
- **Datei → Umbenennen …** benennt einen einzelnen gewählten Eintrag um.
- **Enter/Doppelklick** öffnet Dateien als lokale, schreibgeschützte Lesekopien in der Standard-App. **F3 / ⌘Y / Leertaste** bereiten dieselbe Lesekopie für Quick Look vor. Änderungen werden nicht automatisch auf den Server zurückgeschrieben; F4 ist für Remote-Dateien deaktiviert.
- **F7** legt Ordner an; **F8** löscht nach Rückfrage auf dem Server. Bei FTP/SSH/SFTP verwendet PaneRook keinen Papierkorb; bei Nextcloud hängt eine Wiederherstellung vom serverseitigen Papierkorb ab.

Das Auswerfen-Symbol rechts neben dem Pfad trennt die Verbindung und stellt das vorherige lokale Verzeichnis wieder her. Die aktive VFS-Liste aktiviert oder trennt verbundene Panels. Esc/Ctrl-G brechen einen laufenden Remote-Vorgang ab. Archiv-Transfers und lokale Spezialwerkzeuge wie Git, Suche oder Verzeichnisbaum benötigen weiterhin einen lokalen Ordner. Das Tauschen der Panelpfade ist bei offenen Remote-Verbindungen deaktiviert.

SSH und SFTP verwenden die macOS-Werkzeuge mit SSH-Schlüssel oder Agent und bereits bestätigten Hosts in `~/.ssh/known_hosts`; interaktive Passwortanmeldung und eine Ersteinrichtung des Hostvertrauens sind nicht enthalten. FTP verwendet `curl` und überträgt Zugangsdaten und Dateien unverschlüsselt. PaneRook speichert keine Verbindungskennwörter und übergibt FTP-/Nextcloud-Zugangsdaten über die Standardeingabe statt über Prozessargumente.

Für **Nextcloud** als Server die HTTPS-Adresse der Installation eintragen, etwa `https://cloud.example.org` oder `https://example.org/nextcloud`, dazu den Nextcloud-Benutzernamen und ein **App-Passwort** aus den persönlichen Nextcloud-Einstellungen unter **Sicherheit**. Der Standardport ist 443; ein Port in der Server-URL hat Vorrang vor dem Port-Feld. Der **Startpfad** bezieht sich auf die eigenen Dateien: `/` öffnet deren Wurzel, `/Dokumente` den entsprechenden Ordner. Den WebDAV-Pfad `/remote.php/dav/files/<Benutzer>` ergänzt PaneRook selbst. Die Verbindung verwendet `curl` mit HTTPS und Zertifikatsprüfung; HTTP und öffentliche Freigabelinks werden nicht unterstützt. Die [Nextcloud-Dokumentation](https://docs.nextcloud.com/server/stable/user_manual/en/files/access_webdav.html) beschreibt WebDAV und App-Passwörter.

Remote-Transfers unterstützen reguläre Dateien und Verzeichnisse, keine symbolischen Links oder Spezialdateien. Die Remote-Kollisionsprüfung erfolgt vor dem jeweiligen Transfer; sie bietet keine allgemeine atomare Garantie gegen Überschreiben bei parallelen Serveränderungen, insbesondere bei SFTP/FTP-Uploads. Nextcloud-Uploads senden zusätzlich `If-None-Match: *`, damit der Server bereits vorhandene Zieldateien ablehnt. Fehler oder Abbruch können bereits angelegte Remote-Dateien und Ordner zurücklassen. Transfers zwischen zwei Verbindungen verwenden einen privaten temporären lokalen Zwischenordner, der nach dem Vorgang entfernt wird. Bei einem fehlgeschlagenen oder abgebrochenen Verschieben bleibt die noch nicht vollständig übertragene Quelle erhalten; bereits abgeschlossene Einträge bleiben verschoben.

