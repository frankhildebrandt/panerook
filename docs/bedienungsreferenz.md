# PaneRook – ergänzende Bedienungsreferenz

## Funktionsstand

- Zwei native Dateilisten mit Systemicons, Größe, Datum, Sortierung und vollständigem oder kompaktem Listenformat. Pfade verstehen absolute und relative Angaben sowie `~`; Verlauf, Hotlist und Finder-Anbindung ergänzen die Navigation.
- Git-Repository-Ordner zeigen bereits im übergeordneten Verzeichnis ihren Branch und Status neben dem Namen: **✓** sauber, **●** Änderungen oder unversionierte Einträge, **!** Konflikte. **↑/↓** geben lokale Commit-Abstände zum bekannten Upstream an. Ein Tooltip schlüsselt vorgemerkte und übrige Änderungen auf. Die Anzeige funktioniert auch im kompakten Listenformat und für Worktrees; sie wird im Hintergrund beim Laden und Aktualisieren (**⌘R**) der Ordnerliste ermittelt, ohne Netzwerkzugriff.
- Pro Panel: Dateiliste, Schnellansicht, Info, ein beim Aufklappen nachgeladener Verzeichnisbaum oder ein eingebettetes Ghostty-Terminal. Schnellansicht und Info folgen der Auswahl des anderen Panels. Dateimasken filtern Dateien; Ordner bleiben zum Navigieren sichtbar. Gruppen lassen sich per Maske markieren, abwählen oder umkehren.
- Git-Repositories mit Branch-/Statusanzeige in beiden Panels, Statusfiltern und gespeicherten Watched-Markierungen. Ein eigenes Git-Fenster bietet Diffs, Staging, Commits, Branch- und Versionswechsel, Stashes, Tags und Remote-Abgleich.
- ZIP-, TAR- und tar.gz-/TGZ-Archive als virtuelle Ordner direkt in den Hauptpanels: Unterordner öffnen, Dateien hinein- und herauskopieren, verschieben/umbenennen, Ordner anlegen und Einträge löschen.
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

Lokale Transfers zeigen Bytefortschritt für die aktuelle Datei und erledigte Manifesteinträge. Der Bytebalken während des Kopierens bezieht sich auf diese Datei; zwischen Dateien zeigt der Gesamtbalken die erledigten Einträge. Zunächst wird die Auswahl ohne Prozentwert erfasst. Suche und Größenberechnung zeigen während der Erfassung einen unbestimmten Balken und geprüfte Einträge; Vergleiche melden messbare Byte- beziehungsweise Eintragsfortschritte. Remote-Transfers melden abgeschlossene Dateien und Verzeichniseinträge, keinen Bytefortschritt innerhalb einer Remote-Datei. Shell-Befehle laufen mit einem unbestimmten Balken. **Abbrechen**, Esc, F10 oder Ctrl-G stoppen die Aufgabe; **In den Hintergrund** und das Schließen des Fortschrittsfensters lassen sie weiterlaufen. Einzelne native Datei-/Metadatenaufrufe werden zu Ende geführt; Stapel lassen sich zwischen Einträgen abbrechen. Allgemeine Hintergrundaufgaben gelten für die aktuelle App-Sitzung. Kopier- und Verschiebeaufträge zwischen lokalen und/oder Remote-Ordnern bleiben dagegen gespeichert. Beim Beenden fragt PaneRook nach und wartet nach einem Abbruch auf die Bereinigung.

**Wiederholen / Fortsetzen** in der Aufgabenliste oder im Fortschrittsfenster startet einen fehlgeschlagenen, abgebrochenen oder nach App-Neustart offenen Transfer erneut in der seriellen Queue. **Details anzeigen** listet abgeschlossene, offene und fehlgeschlagene Einträge mit Fehlern auf (bei großen Aufträgen die ersten 500). Bereits abgeschlossene unveränderte Dateien werden geprüft und übersprungen; offene und fehlgeschlagene Dateien werden vollständig neu übertragen. Die Fortsetzung erfolgt **auf Dateiebene**, auch innerhalb von Verzeichnissen, ohne bytegenaue Wiederaufnahme. Nach einem Neustart erfolgt keine automatische Ausführung. **Beendete entfernen** behält offene Aufträge. **Verwerfen** entfernt nach Rückfrage den Auftrag, lässt aber bereits übertragene Dateien bestehen.

Quellen, Zielpfade und Dateiinhalte werden bei der Fortsetzung erneut geprüft. Geänderte Quellen, veränderte abgeschlossene Ziele und vorhandene, nicht sicher dem Auftrag zugeordnete Ziele werden als Fehler gemeldet und nicht überschrieben. Ursache prüfen, Konflikte gegebenenfalls außerhalb des Auftrags auflösen und erneut fortsetzen; bei gewollten Quelländerungen einen neuen Auftrag anlegen. Ein Absturz unmittelbar nach dem Schreiben einer Datei und vor dem Speichern ihres Ergebnisses kann deshalb eine manuell zu prüfende Kollision hinterlassen. Verschieben entfernt nur bestätigte unveränderte Quelldateien und anschließend leere Quellordner; später hinzugefügte Dateien bleiben erhalten. Dateihashes erkennen auch Inhaltsänderungen bei unveränderter Größe und Zeitangabe. Remote-Transfers bewahren wie bisher bei Downloads/Uploads nicht sämtliche Serverattribute; auch Verschieben in derselben Verbindung verwendet in diesem Ablauf Kopieren und Löschen. Remote-Prüfungen benötigen zusätzliche Downloads und temporären lokalen Speicher bis zur Größe der geprüften Datei; sie können deshalb länger dauern. Externe Änderungen während eines Serveraufrufs lassen sich nicht transaktional ausschließen.

Remote-Aufträge speichern nur Protokoll, Server, Port, Benutzer, Schlüsseldateipfad und Transferpfade. Beim Fortsetzen wird die Anmeldung erneut bestätigt; FTP-/Nextcloud-Passwörter werden erneut abgefragt und nicht gespeichert. SSH/SFTP verwenden weiterhin Schlüssel/Agent und die vorhandene Hostschlüsselprüfung. Das Manifest und Einzelergebnisse liegen unter `~/Library/Application Support/PaneRook/Transfers`. Direktes Umbenennen, Archivaktionen, Vorschaukopien, Shell-Befehle und andere Hintergrundaufgaben werden nicht wiederhergestellt. Pro Transfer gelten höchstens 100.000 Einträge und 256 Verzeichnisebenen. Symbolische Links bleiben nur bei rein lokalen Transfers unterstützt.

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

Dies ist die Standardbelegung. **Einstellungen** (**⌘,**) → **Tastatur → Belegung bearbeiten …** zeigt alle App-Aktionen mit ihrer aktuellen und ursprünglichen Belegung, einschließlich Aktionen ohne Standardkürzel. Die Liste lässt sich nach Aktion, Bereich oder Tastenkombination durchsuchen. **Belegen …** zeichnet die nächste Tastenkombination auf; auch Return, Tab, Escape und Funktionstasten sind möglich. Mit **Speichern** wird sie dauerhaft übernommen. **Belegung entfernen** gibt ein Kürzel dauerhaft frei, **Standard wiederherstellen** setzt nur die ausgewählte Aktion zurück; **Alle zurücksetzen …** stellt nach Bestätigung die gesamte Standardbelegung wieder her. Bisher gespeicherte Belegungen bleiben erhalten.

Die Bereiche unterscheiden Hauptfenster, Dateipanels, Textbearbeitung, Konsole, Dialoge, Git, Remote-Panels, Verbindungsarchiv, Aufgaben, Suchergebnisse und Netzwerk. Dieselbe Kombination darf in getrennten Fenstern unterschiedliche Aktionen auslösen; Konflikte innerhalb gleichzeitig aktiver Bereiche verhindern das Speichern. Alternative Kürzel einer Aktion, etwa Enter und Enter auf dem Ziffernblock oder F3 und ⌘Y, sind als eigene Einträge anpassbar. Normale Zeicheneingaben in Textfeldern bleiben erhalten; reine Zeichenbelegungen für Dateiaktionen gelten in den Listen. Dialogbestätigung und Abbruch (standardmäßig Enter beziehungsweise Esc/F10/Ctrl-G) sind ebenfalls anpassbar. In Remote-Panels gelten für Kopieren/Herunterladen, neue Ordner, Löschen, Öffnen und Navigation dieselben Belegungen wie im Hauptfenster. Zusätzliche Remote-Belegungen lassen sich separat vergeben; F10 bricht einen Remote-Vorgang ab oder trennt die aktive Verbindung. Menüeinträge, die Funktionstastenleiste und die Tastaturhilfe zeigen die aktuelle Belegung. Auf Apple-Tastaturen brauchen die Funktionstasten je nach Systemeinstellung zusätzlich **fn**.

## Ghostty-Terminal im Panel

**Links/Rechts → Ghostty-Terminal** startet im bisherigen lokalen Panelordner eine interaktive Shell mit Ghosttys nativer Terminaldarstellung. Ghostty muss nicht separat installiert werden. Der Kopf zeigt den Terminaltitel und das zuletzt von der Shell gemeldete lokale Arbeitsverzeichnis. Die mitgelieferte Shell-Integration unterstützt zsh und bash; bei anderen Shells braucht die Verzeichnisverfolgung lokale OSC-7-Meldungen.

Das gegenüberliegende Dateipanel bleibt unabhängig navigierbar. **F5 Kopieren** und **F6 Verschieben** verwenden das im Terminalkopf angezeigte Verzeichnis als vorgeschlagenes Ziel. Nach einem `cd` wird dieses Ziel aktualisiert. Sobald der Transferdialog geöffnet ist, bleibt dessen Zielpfad fest, auch wenn sich die Shell danach weiterbewegt. Bestehende Rückfragen und Konfliktregeln gelten weiter. Ein per SSH geöffnetes entferntes Verzeichnis wird nicht als lokaler Zielpfad übernommen.

**⌘⌥Tab** wechselt den Fokus zum anderen Panel. Tab, Pfeiltasten, Esc, Funktionstasten und Ctrl-Kombinationen wie Ctrl-C, Ctrl-D und Ctrl-O gehen im Terminal an die Shell, auch wenn sie sonst PaneRook-Aktionen auslösen. **⌘C/⌘V** kopieren beziehungsweise fügen Terminaltext ein; **⌘A** markiert den Terminalinhalt. Der Panelwechsel lässt sich unter **Einstellungen → Tastatur** umbelegen.

**Dateiliste** oder **Links/Rechts → Dateiliste** kehrt zur bisherigen Dateiliste und Auswahl zurück. Beim erneuten Öffnen erscheint dieselbe Terminalsitzung mit ihrem Verlauf und aktuellen Verzeichnis. **⌘L** öffnet die Pfadeingabe in der Dateiliste. Aktualisieren und abgeschlossene Dateioperationen starten die Shell nicht neu. `exit` beendet die Shell und zeigt wieder die Dateiliste; das Schließen des Fensters oder Ersetzen des Panels durch eine Remote-Verbindung beendet die Sitzung ebenfalls. Terminalsitzungen werden nach einem App-Neustart nicht wiederhergestellt. In einem Archiv oder einem Remote-Panel ist der Terminalmodus nicht verfügbar.

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
- **F6** verschiebt die Auswahl nach Rückfrage ins gegenüberliegende Panel. Wiederherstellbare Transfers kopieren und prüfen jede Datei und entfernen die unveränderte Quelle anschließend. Das gilt auch innerhalb derselben Verbindung; direktes Umbenennen verwendet weiterhin die Umbenennung des Servers.
- **Datei → Umbenennen …** benennt einen einzelnen gewählten Eintrag um.
- **Enter/Doppelklick** öffnet Dateien als lokale, schreibgeschützte Lesekopien in der Standard-App. **F3 / ⌘Y / Leertaste** bereiten dieselbe Lesekopie für Quick Look vor. Änderungen werden nicht automatisch auf den Server zurückgeschrieben; F4 ist für Remote-Dateien deaktiviert.
- **F7** legt Ordner an; **F8** löscht nach Rückfrage auf dem Server. Bei FTP/SSH/SFTP verwendet PaneRook keinen Papierkorb; bei Nextcloud hängt eine Wiederherstellung vom serverseitigen Papierkorb ab.

Das Auswerfen-Symbol rechts neben dem Pfad trennt die Verbindung und stellt das vorherige lokale Verzeichnis wieder her. Die aktive VFS-Liste aktiviert oder trennt verbundene Panels. Esc/Ctrl-G brechen einen laufenden Remote-Vorgang ab. Archiv-Transfers und lokale Spezialwerkzeuge wie Git, Suche oder Verzeichnisbaum benötigen weiterhin einen lokalen Ordner. Das Tauschen der Panelpfade ist bei offenen Remote-Verbindungen deaktiviert.

SSH und SFTP verwenden die macOS-Werkzeuge mit SSH-Schlüssel oder Agent und bereits bestätigten Hosts in `~/.ssh/known_hosts`; interaktive Passwortanmeldung und eine Ersteinrichtung des Hostvertrauens sind nicht enthalten. FTP verwendet `curl` und überträgt Zugangsdaten und Dateien unverschlüsselt. PaneRook speichert keine Verbindungskennwörter und übergibt FTP-/Nextcloud-Zugangsdaten über die Standardeingabe statt über Prozessargumente.

Für **Nextcloud** als Server die HTTPS-Adresse der Installation eintragen, etwa `https://cloud.example.org` oder `https://example.org/nextcloud`, dazu den Nextcloud-Benutzernamen und ein **App-Passwort** aus den persönlichen Nextcloud-Einstellungen unter **Sicherheit**. Der Standardport ist 443; ein Port in der Server-URL hat Vorrang vor dem Port-Feld. Der **Startpfad** bezieht sich auf die eigenen Dateien: `/` öffnet deren Wurzel, `/Dokumente` den entsprechenden Ordner. Den WebDAV-Pfad `/remote.php/dav/files/<Benutzer>` ergänzt PaneRook selbst. Die Verbindung verwendet `curl` mit HTTPS und Zertifikatsprüfung; HTTP und öffentliche Freigabelinks werden nicht unterstützt. Die [Nextcloud-Dokumentation](https://docs.nextcloud.com/server/stable/user_manual/en/files/access_webdav.html) beschreibt WebDAV und App-Passwörter.

Remote-Transfers unterstützen reguläre Dateien und Verzeichnisse, keine symbolischen Links oder Spezialdateien. Die Remote-Kollisionsprüfung erfolgt vor dem jeweiligen Transfer; sie bietet keine allgemeine atomare Garantie gegen Überschreiben bei parallelen Serveränderungen, insbesondere bei SFTP/FTP-Uploads. Nextcloud-Uploads senden zusätzlich `If-None-Match: *`, damit der Server bereits vorhandene Zieldateien ablehnt. Fehler oder Abbruch können bereits angelegte Remote-Dateien und Ordner zurücklassen. Transfers zwischen zwei Verbindungen verwenden einen privaten temporären lokalen Zwischenordner, der nach dem Vorgang entfernt wird. Bei einem fehlgeschlagenen oder abgebrochenen Verschieben bleibt die noch nicht vollständig übertragene Quelle erhalten; bereits abgeschlossene Einträge bleiben verschoben.

