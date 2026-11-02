# Signierung und Releases

Für PaneRook ist ein Apple-Zertifikat **Developer ID Application: Frank Hildebrandt (4R24354Z88)** eingerichtet. Der private Schlüssel gehört zu dieser Identität und bleibt außerhalb des Repositorys. Der Release-Workflow verlangt eine hinterlegte Signieridentität und signiert damit sowohl die App als auch das DMG. Er fällt bei fehlenden Signier-Secrets nicht auf ad hoc zurück.

Apple-Notarisierung ist ein zusätzlicher Schritt: Erst mit einem eingerichteten lokalen Notarisierungsprofil oder vollständigen GitHub-Notarisierungs-Secrets übermittelt der Build die App und das DMG an Apple. Eine erfolgreiche Signaturprüfung allein bestätigt noch keine Notarisierung oder Gatekeeper-Freigabe. Siehe [Apples Beschreibung von Code Signing und Notarisierung](https://support.apple.com/guide/security/sec3ad8e6e53/web).

## Developer-ID-Zertifikat und private Dateien

Die eingerichtete Identität hat folgende öffentliche Kennungen:

| Eigenschaft | Wert |
| --- | --- |
| Zertifikat | `Developer ID Application: Frank Hildebrandt (4R24354Z88)` |
| Apple-Team | `4R24354Z88` |
| Zertifikat-ID im Apple-Portal | `7M8C57CP2F` |
| SHA-1-Fingerabdruck zur Schlüsselbund-Auswahl | `C998BDA96A8181AA2CE7BBCCA12F031F29289C2C` |
| Gültig bis | 2. Dezember 2027 |

Der private RSA-Schlüssel mit 2048 Bit, die zugehörige CSR, das von Apple ausgestellte Zertifikat, die passwortgeschützte PKCS#12-Datei `certificate.p12`, lokale Passwortdateien, `identity.txt` und der eigene Schlüsselbund `signing.keychain-db` liegen unter:

```text
~/Library/Application Support/PaneRook/Signing/DeveloperID/
```

Dieser Ordner gehört nicht in Git. Sichere ihn verschlüsselt an einem getrennten Ort: Für spätere Builds mit derselben Identität müssen der private Schlüssel und seine Passwörter erhalten bleiben. Das öffentliche Zertifikat kann zur Überprüfung weitergegeben werden. Der SHA-1-Fingerabdruck dient nur zur Auswahl des Zertifikats; Downloads erhalten zusätzlich SHA-256-Prüfsummen.

Vor Ablauf des Zertifikats ein neues **Developer ID Application**-Zertifikat ausstellen lassen, Schlüsselbund und GitHub-Secrets aktualisieren und den vollständigen Signier- und Notarisierungsablauf erneut prüfen. Das Erneuern der GitHub-Secrets allein verlängert kein Zertifikat.

Für eine neue Ausstellung wird lokal ein verschlüsselter RSA-Schlüssel mit **2048 Bit** und eine zugehörige Certificate Signing Request erzeugt. Die CSR im Apple-Developer-Portal für **Developer ID Application** mit der **G2**-Zwischenzertifizierungsstelle einreichen. Anschließend das ausgestellte Zertifikat mit genau diesem privaten Schlüssel und dem öffentlichen **Developer ID G2**-Zwischenzertifikat in eine passwortgeschützte PKCS#12-Datei exportieren und in einen eigenen Schlüsselbund importieren. Der private Schlüssel wird nicht an Apple geschickt. Das Zwischenzertifikat muss in der Signierkette verfügbar sein; auf dem CI-Runner wird der temporäre Schlüsselbund deshalb zusätzlich in die Schlüsselbund-Suchliste aufgenommen. Siehe [Developer-ID-Zertifikate bei Apple](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/).

## Lokal signiert paketieren

Voraussetzungen: macOS und die ausgewählte Xcode-Command-Line-Toolchain. Den privaten Schlüsselbund bei Bedarf entsperren und die Identität ausdrücklich angeben:

```sh
signing_directory="$HOME/Library/Application Support/PaneRook/Signing/DeveloperID"
security unlock-keychain -p "$(cat "$signing_directory/keychain-password.txt")" \
  "$signing_directory/signing.keychain-db"
export PANEROOK_SIGNING_IDENTITY="$(cat "$signing_directory/identity.txt")"
export PANEROOK_SIGNING_KEYCHAIN="$signing_directory/signing.keychain-db"
export PANEROOK_SIGNING_TIMESTAMP=secure
./scripts/package-release.sh
```

Dieselben Variablen gelten für `./scripts/build-app.sh release`. Ohne `PANEROOK_SIGNING_IDENTITY` bleibt ein lokaler Entwicklungsbuild ad hoc signiert. Eine ausdrücklich konfigurierte, aber nicht verfügbare Identität lässt den Build fehlschlagen. Ein sicherer Zeitstempel gehört zur Developer-ID-Signierung und wird hier mit `PANEROOK_SIGNING_TIMESTAMP=secure` angefordert.

`package-release.sh` baut für Apple Silicon und Intel und erzeugt unter `build/release/`:

- `PaneRook-<Version>-macOS-universal.dmg` mit App und Verknüpfung zu `/Applications`;
- `PaneRook-<Version>-macOS-universal.zip` mit dem App-Bundle;
- jeweils eine passende Datei mit Endung `.sha256`.

Die Versionsnummer stammt aus `Resources/Info.plist`. Ein optionales Argument wie `./scripts/package-release.sh v0.1.0` muss dazu passen. Die ZIP-Datei enthält die signierte App; das DMG trägt zusätzlich eine eigene Signatur.

Signatur und Inhalt lassen sich mit den macOS-Werkzeugen prüfen:

```sh
codesign --verify --strict --all-architectures build/PaneRook.app
codesign --display --verbose=4 build/PaneRook.app
hdiutil verify build/release/PaneRook-0.1.0-macOS-universal.dmg
cd build/release
shasum -a 256 -c PaneRook-0.1.0-macOS-universal.zip.sha256
shasum -a 256 -c PaneRook-0.1.0-macOS-universal.dmg.sha256
```

## Apple-Notarisierung

Für die Auslieferung unter den normalen Gatekeeper-Einstellungen sind das Apple-Developer-ID-Zertifikat und Apples Notarisierung erforderlich. Für einen lokalen notarisierten Build die obige Signierkonfiguration um ein zuvor mit `xcrun notarytool store-credentials` eingerichtetes Profil ergänzen:

```sh
export PANEROOK_NOTARY_PROFILE=panerook-notary
# Bei einem Profil in einem eigenen Schlüsselbund zusätzlich:
export PANEROOK_NOTARY_KEYCHAIN="$PANEROOK_SIGNING_KEYCHAIN"
./scripts/package-release.sh
```

Das Paketierskript übermittelt zuerst die App an Apple und heftet das Notarisierungsticket an die App, bevor es ZIP und DMG erstellt. Anschließend wird auch das signierte DMG notarisiert und sein Ticket angeheftet. Erst danach werden die finalen Prüfsummen berechnet. Ohne Profil wird nur signiert; das Skript behauptet dann keine Notarisierung.

Nach einem erfolgreich notarisierten Build lassen sich die angehefteten Tickets und die Gatekeeper-Bewertung prüfen:

```sh
xcrun stapler validate build/PaneRook.app
xcrun stapler validate build/release/PaneRook-0.1.0-macOS-universal.dmg
spctl --assess --type execute --verbose=4 build/PaneRook.app
```

Details zum Verfahren: [Apples Notarisierungsdokumentation](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

## GitHub Actions

Das Repository `frankhildebrandt/panerook` verwendet folgende Actions-Secrets für die Developer-ID-Identität:

| Secret | Inhalt |
| --- | --- |
| `PANEROOK_CERTIFICATE_BASE64` | Base64-kodierte PKCS#12-Datei mit Zertifikat, privatem Schlüssel und Zwischenzertifikat |
| `PANEROOK_CERTIFICATE_PASSWORD` | Passwort dieser PKCS#12-Datei |
| `PANEROOK_SIGNING_IDENTITY` | SHA-1-Fingerabdruck des Signierzertifikats |

Die Secret-Werte werden nicht in Workflow-Dateien geschrieben. Die Repository-Variable `PANEROOK_SIGNING_TIMESTAMP` steht für Developer-ID-Builds auf `secure`.

Für die Notarisierung ist der eigene App-Store-Connect-Team-Schlüssel **PaneRook Notarization** mit der Rolle **Developer** eingerichtet. Seine private `.p8`-Datei liegt ebenfalls im privaten Developer-ID-Ordner. Das lokale Schlüsselbundprofil heißt `panerook-notary`. In GitHub sind alle drei Secrets hinterlegt:

| Secret | Inhalt |
| --- | --- |
| `APPLE_NOTARY_KEY_P8` | Vollständiger privater API-Schlüssel im `.p8`-Format |
| `APPLE_NOTARY_KEY_ID` | API-Key-ID |
| `APPLE_NOTARY_ISSUER_ID` | Issuer-ID |

Mit vollständigen Notarisierungs-Secrets richtet der Workflow das `notarytool`-Profil ein und aktiviert den sicheren Zeitstempel automatisch. Ohne Apple-Zugangsdaten wird nur die konfigurierte Signatur angebracht. Eine unvollständige Notarisierungskonfiguration wird als Fehler behandelt.

Der Workflow `.github/workflows/release.yml` testet zunächst die App und importiert die hinterlegte Identität anschließend in einen temporären Schlüsselbund auf dem macOS-Runner. App und DMG werden damit signiert und bei konfigurierter Notarisierung von Apple geprüft. Ein abschließender Schritt entfernt den Schlüsselbund und temporäre Zugangsdaten auch nach einem Buildfehler.

**Actions → App release → Run workflow** erstellt ZIP, DMG und Prüfsummen als Artefakt `PaneRook-macOS-universal`. Ein Tag `v<Version>` veröffentlicht diese Dateien als GitHub-Release. Vor dem Tag müssen die Versionsangaben im App-Bundle und gegebenenfalls `docs/releases/<Version>.md` aktualisiert sein.

Das bestehende öffentliche Release `v0.1.0` enthält weiterhin das ursprünglich veröffentlichte ad-hoc-signierte ZIP. Die neue Konfiguration verändert bereits veröffentlichte Dateien nicht rückwirkend.

## Optional: persönliche Signatur ohne Apple

`setup-signing.sh` erzeugt ein persönliches selbst signiertes Code-Signing-Zertifikat mit einem privaten RSA-Schlüssel von 3072 Bit. Es erstellt **kein** Apple-Developer-ID-Zertifikat und ermöglicht keine Apple-Notarisierung. macOS vertraut einem solchen Zertifikat auf anderen Macs nicht automatisch. Das Setup verändert keine systemweiten Zertifikatsvertrauenseinstellungen.

```sh
./scripts/setup-signing.sh
```

Die Dateien liegen standardmäßig unter `~/Library/Application Support/PaneRook/Signing/`, getrennt vom Unterordner `DeveloperID/`. Ein anderer privater Speicherort lässt sich mit `--directory "/absoluter/pfad"` auswählen. Ein bereits vorhandenes Verzeichnis wird nicht überschrieben.

Für einen lokalen Build mit einer persönlichen Identität die Signiervariablen auf deren `identity.txt` und Schlüsselbund setzen, `PANEROOK_SIGNING_TIMESTAMP=none` verwenden und kein Notarisierungsprofil setzen. Der private Ordner muss ebenso verschlüsselt gesichert werden.

Die Optionen `--github` und `--github-only` laden die jeweilige persönliche Identität in die drei `PANEROOK_*`-Signier-Secrets hoch; `--github-only` verwendet vorhandene Dateien ohne neue Schlüsselerzeugung. **Dies ersetzt die bestehende Developer-ID-Konfiguration in GitHub.** Für reguläre Releases mit Apple-Notarisierung diese Optionen nicht mit dem persönlichen Zertifikat ausführen.
