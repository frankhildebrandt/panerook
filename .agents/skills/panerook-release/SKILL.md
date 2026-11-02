---
name: panerook-release
description: Bereite PaneRook-Releases mit vollständiger Nutzerdokumentation und passenden Unterseiten, echten App-Screenshots, bebilderten Marketing-Release-Notes pro Version, aktualisierter Landingpage und bereinigter README.md vor. Verwende den Skill bei Releasevorbereitung und Durchführung eines PaneRook-Releases.
---

# PaneRook-Release

Bei jedem Release gehören Dokumentation, Screenshots, Release Notes, Landingpage und README zum Lieferumfang. Schreibe auf Deutsch und übernimm die tatsächlichen Bezeichnungen der App. Lies zunächst [references/project-map.md](references/project-map.md) für die bestehenden Pfade, Versionsquellen und Veröffentlichungswege; prüfe sie am aktuellen Checkout.

Der Auftrag bestimmt, ob nur vorbereitet oder auch veröffentlicht wird. Erledige die lokale Vorbereitung vollständig vor einem Veröffentlichungsschritt. Das Anlegen oder Ändern dieses Skills startet keinen Release. Bei bereits beauftragter Veröffentlichung ist keine erneute pauschale Bestätigung nötig; bloße Releasevorbereitung umfasst keine Tags, Pushes oder Deployments.

## 1. Releaseumfang und Dokumentationslücken ermitteln

- Ermittle Zielversion, letzten tatsächlich veröffentlichten Release und vorgesehenen Release-Stand. Nutze Tags und Git-Diff/-Log, Implementierung, Tests und die erreichbare App-Oberfläche. Committexte oder eine Featureliste allein belegen keine Funktion.
- Gleiche alle relevanten vorhandenen App-Funktionen mit der Nutzerdokumentation ab, auch wenn sie bereits vor diesem Release implementiert wurden. Hier bedeutet „fehlende Features“: in der Dokumentation fehlende, tatsächlich nutzbare Funktionen. Nicht implementierte Funktionen bleiben als Grenzen oder Ausblick gekennzeichnet.
- Halte eine knappe Arbeitsliste mit Funktion, Beleg im Code/UI, Dokumentationsziel, Screenshotbedarf und Relevanz für Release Notes/Landingpage. Unterscheide neue Funktionen von lediglich nachgeholter Dokumentation; vermarkte Letztere nicht als neue App-Funktion.
- Übernimm eine vorgegebene Version. Fehlt sie, leite einen Vorschlag aus Umfang und Projektkonvention ab; kläre vor Tag/Paketierung nur eine tatsächlich offene Versionsentscheidung. Fahre mit unabhängiger Dokumentationsarbeit fort.

## 2. Dokumentation vorbereiten und sinnvoll aufteilen

- Ergänze und korrigiere die Dokumentation für den gesamten freigegebenen Funktionsstand: Einstieg, Voraussetzungen, Bedienweg, wichtige Tastaturkürzel, Ergebnis und relevante Grenzen. Prüfe bestehende Aussagen auf Änderungen und entferne überholte Einschränkungen.
- Teile lange oder eigenständige Themen in echte Unterseiten unter `/dokumentation/` auf, beispielsweise Git & Worktrees, Archive oder Remote-Verbindungen. Ein zusätzlicher Abschnittsanker ist keine Unterseite. Kleine Ergänzungen bleiben beim passenden Thema; erzeuge keine leeren oder unnötig kleinteiligen Seiten.
- Behalte `/dokumentation/` als verständlichen Einstieg mit Themenübersicht. Verknüpfe neue Seiten über Navigation, Rückweg und verwandte Themen. Verwende das gemeinsame Layout und erhalte bestehende Ankerziele als kurze Verweise oder aktualisiere alle internen Verlinkungen; bestehende öffentliche Einstiege sollen weiter Orientierung bieten.
- Füge passende aktuelle App-Screenshots bei erklärungsbedürftigen Abläufen ein. Technische Entwicklerdetails gehören in die technischen Referenzen, wenn sie Nutzern bei der Bedienung nicht helfen.

## 3. Echte Screenshots aufnehmen und pflegen

- Baue und starte die App aus dem vorgesehenen Release-Stand. Verwende einen einmaligen Build für Aufnahmen, keinen unbeaufsichtigt laufenden Entwicklungs-Watcher. Prüfe, dass tatsächlich das neu gebaute Bundle läuft.
- Erstelle pro Release eine aktuelle Hauptansicht. Prüfe vorhandene Motive und erneuere Aufnahmen bei geänderter Oberfläche, veralteten Daten oder unleserlicher Darstellung. Ergänze fehlende Ansichten für wichtige neue Funktionen, Dialoge und Arbeitsabläufe.
- Nimm echte App-Fenster mit den verfügbaren Screenshot-/Computerwerkzeugen auf. Nutze nachvollziehbare Demo-Dateien und konsistente Fenstergröße, Skalierung und Erscheinungsbild. Zeige keine privaten Dateien, Zugangsdaten oder Benachrichtigungen; arbeite dafür mit Demo-Daten statt nachträglich UI-Inhalte zu erfinden. Generierte Bilder und Mockups ersetzen keine App-Screenshots.
- Lege Release-Motive als PNG unter `website/public/screenshots/releases/<version>/` ab. Frühere Releaseartikel behalten ihre damaligen Bilder; überschreibe deren Assets nicht mit aktuellen Aufnahmen. Aktuelle Motive für Landingpage und Dokumentation dürfen dieselben neuen Dateien nutzen.
- Prüfe jede Aufnahme visuell: richtiger Build, sichtbarer Funktionszustand, lesbarer Fokus, keine störenden Fenster. Pflege Bildabmessungen, beschreibenden Alternativtext und bei Bedarf eine Bildunterschrift. Verlinke das Original, wenn die Darstellung zum Lesen vergrößert werden muss.
- Fehlen eine erreichbare App, erforderliche Beispieldaten oder Aufnahmeberechtigungen, erledige die übrige Vorbereitung weiter und benenne die konkret fehlenden Motive. Behaupte keine erfolgten Aufnahmen und erkläre den Release nicht für vollständig vorbereitet, solange erforderliche Bilder fehlen.

## 4. Release Notes und eigene Release-Unterseite erstellen

- Pflege `docs/releases/<version>.md` als gemeinsame Inhaltsquelle für Website und GitHub Release. Schreibe einen kurzen Einstieg mit dem Nutzen dieser Version.
- Stelle die wichtigsten neuen Funktionen mit einer verständlichen Nutzenüberschrift, einem konkreten Anwendungsfall und einem passenden Screenshot vor. Erkläre etwa, welcher Arbeitsschritt einfacher wird; keine unbelegten Versprechen, Superlative oder erfundenen Leistungsgewinne. Nutze für nicht visuelle Funktionen eine passende reale Bedien-/Ergebnisansicht, soweit vorhanden; erfinde dafür keine Oberfläche.
- Kleinere Verbesserungen und Fixes erhalten knappe Textpunkte ohne erzwungenes Bild. Ergänze relevante Update-/Installationshinweise, Kompatibilität, bekannte Grenzen sowie Download- und Vergleichslinks. Stelle Signierung/Notarisierung nur so dar, wie sie für den tatsächlichen Build belegt ist.
- Jede veröffentlichte Version erhält eine eigene erreichbare Seite unter `/release-notes/<version>/`. Nutze die versionierte Markdown-Datei auch für diese Seite. Behalte `/release-notes/` als Übersicht mit Links und einem Hinweis auf den aktuellen Release. Ein Anker auf der Sammelseite genügt nicht.
- Wenn noch keine Einzelrouten existieren, implementiere sie im Releaseauftrag, zum Beispiel mit einer statischen Astro-Route `[version].astro` und `getStaticPaths()`. Bestehende Release-Dateien sollen darüber ebenfalls erreichbar sein. Schreibe frühere Releaseinhalte dabei nicht auf den heutigen Funktionsstand um.
- Bilder und Links müssen sowohl im GitHub Release als auch auf der Website funktionieren. Verwende in gemeinsamem Markdown absolute öffentliche Bild-URLs zu den versionierten Assets; beachte den Website-Basispfad und die Reihenfolge der Veröffentlichung. Lokale Dateipfade oder nur auf einer Plattform gültige relative Links genügen nicht.

## 5. Landingpage aktualisieren und README aufräumen

- Aktualisiere Versions-/Downloadverweise, den Einstieg, hervorgehobene Funktionen und Screenshots der Landingpage passend zum Release. Mache die wichtigsten Vorteile sichtbar und verlinke die konkrete Release-Unterseite sowie passende Dokumentation. Korrigiere Links auf aufgeteilte Themen.
- Räume bei jedem Release `README.md` auf: korrigiere Versionen, Links, Funktionsstand und Grenzen; entferne Wiederholungen und überholte Übergangshinweise. Lagere lange Nutzeranleitungen in die passende Dokumentation aus und ersetze sie durch kurze Orientierung mit Links. Bewahre alle weiterhin relevanten Informationen am neuen Ort.
- Halte Produktzweck, Download, Voraussetzungen, Entwicklungsstart, Build-/Testbefehle, technische Referenzen und Lizenz leicht auffindbar. Die README soll nicht die gesamte Nutzerdokumentation oder Releasehistorie duplizieren. Prüfe ihre Links und Bilder auch aus Sicht der GitHub-Darstellung.

## 6. Prüfen und entsprechend dem Auftrag abschließen

- Synchronisiere bei einem Versionswechsel App-Metadaten, Buildnummer, Website-Version, Downloadnamen und Release Notes gemäß Projektreferenz. Erhöhe die Buildnummer gegenüber der letzten veröffentlichten Ausgabe.
- Baue die Website. Prüfe im erzeugten Ergebnis die Dokumentations-Unterseiten, jede Release-Einzelseite, Navigation, alte Einstiege, Bildpfade und den `/panerook`-Basispfad. Prüfe Lesbarkeit, Bildgrößen und responsive Layouts mit den erlaubten Darstellungswerkzeugen; führe Browserarbeit nur im Rahmen des aktuellen Auftrags aus.
- Führe bei einem vollständigen App-Release die Projektprüfungen aus und nutze die bestehenden Paketierungs-/Signierwege. Bei reinen Inhaltsänderungen genügen Website-Build sowie Link- und Bildprüfung. Bestätige keine Builds, Laufzeitprüfungen oder öffentlichen URLs, die nicht tatsächlich geprüft wurden.
- Melde vor einer Veröffentlichung konkrete Restpunkte. Nach beauftragter Veröffentlichung prüfe die öffentlichen Dokumentations-, Release- und Bild-URLs sowie die Download-/Update-Metadaten. Fehlgeschlagene Veröffentlichungsschritte nicht durch stilles Neuschreiben veröffentlichter Tags beheben.

Fertig ist die Vorbereitung erst, wenn Dokumentationslücken geschlossen, sinnvolle Unterseiten verknüpft, erforderliche Screenshots vorhanden, Release Notes bebildert, die Release-Einzelseite erreichbar, Landingpage und README aktuell sowie die erforderlichen Prüfungen erfolgreich sind. Berichte knapp die Version, die geänderten Inhalte und Prüfungen sowie verbleibende Blocker. Unterscheide „lokal vorbereitet“ von „veröffentlicht“.
