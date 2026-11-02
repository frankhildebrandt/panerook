# Projektkarte für PaneRook-Releases

Alle Projektpfade beziehen sich auf die Repository-Wurzel. Diese Karte beschreibt den Ausgangszustand; lies vor Änderungen die aktuellen Dateien. Bereits vorhandene Unterseiten oder gemeinsame Renderer weiterverwenden.

## Inhaltsquellen und Routen

| Inhalt | Bestehender Ort | Beim Release beachten |
| --- | --- | --- |
| Nutzeranleitung | `website/src/pages/dokumentation.astro` | Bisher eine Sammelseite. Größere Themen in `website/src/pages/dokumentation/<thema>.astro` auslagern; Einstieg und Ankerziele berücksichtigen. |
| Release-Inhalte | `docs/releases/<version>.md` | Wird auch vom App-Release-Workflow als `--notes-file` verwendet. Keine zweite manuell gepflegte Inhaltskopie. |
| Release-Übersicht | `website/src/pages/release-notes.astro` | Rendert bislang alle Markdown-Dateien auf einer Seite. Für echte Einzelrouten etwa `website/src/pages/release-notes/[version].astro` ergänzen. |
| Landingpage | `website/src/pages/index.astro` | Hero, Featuretexte, Bilder, Dokumentations- und Releaseverweise prüfen. Bildabmessungen stehen derzeit direkt im Seitencode. |
| Gemeinsames Layout | `website/src/layouts/SiteLayout.astro` | `page="documentation"` bzw. `page="releases"` setzt die Navigation. |
| Aktuelle App-Bilder | `website/public/screenshots/` | Vorhandene Motive: `panels.png`, `git-diff.png`, `archives.png`, `connections.png`. Neue Themen brauchen ggf. zusätzliche Motive. |
| Neue Release-Bilder | `website/public/screenshots/releases/<version>/<motiv>.png` | Versionsgebundene Ablage, damit historische Artikel ihre Bilder behalten. |
| Projektübersicht | `README.md` | Derzeit sehr ausführlich; Nutzeranleitungen sinnvoll auslagern und verlinken. |
| Technische Referenzen | `docs/architecture.md`, `docs/signing.md`, `docs/midnight-commander-reference.md` | Architektur/Entwicklung und Signierung getrennt von Nutzeranleitungen halten. |

Die Website ist statisches Astro. `website/astro.config.mjs` setzt `site` auf `https://frankhildebrandt.github.io`, `base` auf `/panerook` und `trailingSlash: 'always'`. Verwende für Astro-interne Links/Bilder den Basiswert wie in den vorhandenen Seiten:

```js
const base = import.meta.env.BASE_URL.replace(/\/$/, '');
```

Ein öffentliches Release-Bild hat beispielsweise die URL `https://frankhildebrandt.github.io/panerook/screenshots/releases/<version>/<motiv>.png`. `<version>` und `<motiv>` sind bei Verwendung zu ersetzen. Kein `/public/` im URL-Pfad. Diese URL ist erst nach Veröffentlichung der Website öffentlich prüfbar.

Bestehende Verweise verwenden unter anderem `/dokumentation/#git`, `#archive`, `#remote`, `#updates` und `#installation`. Bei Aufteilung kurze Weiterverweise an bisherigen Zielen erhalten und interne Links aktualisieren. Für neue Release-Unterseiten gemeinsame Darstellung nutzen, dabei Dokumentüberschriften und Anker nicht versehentlich doppelt verschachteln.

## App-Stand und Versionen

- `Sources/PaneRookApp/Shell/FeatureComposition.swift`, Feature-Verzeichnisse unter `Sources/PaneRookApp/` und deren `*Commands.swift` helfen beim Abgleich der tatsächlich erreichbaren Oberfläche. Implementierung in `Sources/PaneRookCore/`, `PaneRookRemote/`, `PaneRookPanels/`, `PaneRookTasks/` und relevante Tests ergänzend prüfen.
- `Resources/Info.plist`: `CFBundleShortVersionString` ist die App-Version, `CFBundleVersion` die gegenüber dem letzten Release zu erhöhende Buildnummer; Systemvoraussetzungen ebenfalls hier prüfen.
- `website/src/data/site.ts`: aktuelle Website-Version und daraus abgeleiteter GitHub-Release-Link.
- `website/package.json` ist ein privates Website-Paket; seine Paketversion ist nicht die maßgebliche App-Version.
- Tags folgen `v<version>`, Markdown-Dateien heißen `<version>.md` ohne `v`.
- Der bisherige Website-Loader berücksichtigt nur `X.Y.Z`. Bei einem beauftragten Vorabrelease Filter, Einzelrouten und Sortierung entsprechend erweitern; stabile Website-/Downloadverweise nicht versehentlich auf eine Vorabversion umstellen. Der stabile Sparkle-Feed verwendet GitHubs neuestes stabiles Release.

## Bauen, Aufnehmen und Prüfen

Einmaliger lokaler Build aus der Repository-Wurzel:

```sh
make build
open build/PaneRook.app
```

Alternativ baut `./scripts/build-app.sh debug` einen Debug-Build. `make dev` ist ein dauerhafter Watcher und für einmalige Screenshotaufnahmen unnötig. Vor der Aufnahme sicherstellen, dass kein älteres App-Bundle stattdessen geöffnet wurde. Ohne `PANEROOK_SPARKLE_PUBLIC_KEY` sind Updatefunktionen im Entwicklungsbuild deaktiviert; solche Screenshots dürfen keinen angeblich vollständigen Releasezustand vortäuschen. Private Signierschlüssel sind für normale lokale Aufnahmen nicht nötig.

Website-Build, Arbeitsverzeichnis `website/`:

```sh
npm ci
npm run build
```

Das Projekt verlangt derzeit Node 24 oder neuer. Erzeugte Dateien liegen in `website/dist/`; neue statische Routen, Bilder und Links dort überprüfen. Wenn die Lockdatei fehlt oder die reproduzierbare Installation scheitert, die konkrete Ursache beheben bzw. melden, statt einen erfolgreichen Build zu behaupten.

App-Prüfungen, Arbeitsverzeichnis Repository-Wurzel:

```sh
make test
```

Dies umfasst Swift-Tests und `scripts/test-appcast.swift`. Nur bei tatsächlich blockierter verschachtelter Build-Sandbox ist `PANEROOK_DISABLE_BUILD_SANDBOX=1` die vorhandene Projektausweichmöglichkeit.

## Paketierung und Veröffentlichung

- `scripts/package-release.sh [version]` erstellt Universal-ZIP, DMG, SHA-256-Prüfsummen und `appcast.xml` unter `build/release/`. Die Version muss zum App-Bundle passen. Sparkle-Schlüssel sind für die Paketierung erforderlich; bestehende Einrichtung in `docs/signing.md` verwenden.
- `.github/workflows/release.yml`: Ein gepushter `v*`-Tag startet Build, Signierung und GitHub-Veröffentlichung. Ohne Release-Datei würde der Workflow generierte Notes verwenden; für diesen Skill müssen die redaktionellen Notes vorhanden sein. Ein manueller Workflowlauf baut Artefakte ohne GitHub-Release.
- `.github/workflows/pages.yml`: Änderungen an `website/**` und `docs/releases/**` auf `main` starten den separaten Pages-Deploy. Der App-Tag allein veröffentlicht die Website nicht. Versionierte Bilder müssen für veröffentlichte GitHub Notes ebenfalls öffentlich verfügbar sein; beide Veröffentlichungswege koordinieren.
- Signier-/Notarisierungsangaben aus dem tatsächlichen Build ableiten; der Workflow erlaubt derzeit auch einen Lauf ohne konfigurierte Notarisierung. Keine Zugangsdaten in Dokumentation oder Screenshots übernehmen.

Nur die für den aktuellen Auftrag autorisierten Veröffentlichungsschritte ausführen. Keine separate Release-Infrastruktur erfinden, wenn die vorhandenen Wege den Auftrag erfüllen.
