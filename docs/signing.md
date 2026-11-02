# Signierung und Releases

PaneRook kann lokal ad hoc, mit einem persönlichen selbst signierten Zertifikat oder mit einem Apple-Developer-ID-Zertifikat gebaut werden. Der GitHub-Release-Workflow verlangt eine hinterlegte Signieridentität und signiert damit sowohl die App als auch das DMG. Er fällt bei fehlenden Zugangsdaten nicht auf ad hoc zurück.

Eine persönliche Signatur schützt die Integrität mit dem eigenen privaten Schlüssel. macOS vertraut einem selbst signierten Zertifikat auf anderen Macs jedoch nicht automatisch. Für die Auslieferung unter den normalen Gatekeeper-Einstellungen sind ein von Apple ausgestelltes **Developer ID Application**-Zertifikat und Apples Notarisierung erforderlich. Das Setup verändert keine systemweiten Zertifikatsvertrauenseinstellungen. Siehe [Apples Beschreibung von Code Signing und Notarisierung](https://support.apple.com/guide/security/sec3ad8e6e53/web).

## Persönlichen Schlüssel einrichten

Voraussetzungen: macOS, die Xcode-Command-Line-Werkzeuge und für den Secret-Upload ein angemeldetes GitHub CLI (`gh auth login`) mit Schreibzugriff auf die Actions-Secrets des Repositorys.

```sh
./scripts/setup-signing.sh --github
```

Das Skript erzeugt einen privaten RSA-Schlüssel mit 3072 Bit und ein selbst signiertes Code-Signing-Zertifikat. Die passwortgeschützte PKCS#12-Datei `certificate.p12`, lokale Passwortdateien, die Identität in `identity.txt` und ein eigener Schlüsselbund `signing.keychain-db` liegen standardmäßig unter:

```text
~/Library/Application Support/PaneRook/Signing/
```

Dieser Ordner ist privat und gehört nicht in Git. Sichere ihn verschlüsselt an einem getrennten Ort: Für spätere Releases mit derselben Identität müssen der private Schlüssel und seine Passwörter erhalten bleiben. Das öffentliche Zertifikat kann dagegen zur Überprüfung weitergegeben werden.

Mit `--directory "/anderer/privater/Ordner"` lässt sich der Speicherort wählen. Ohne `--github` richtet das Skript nur die lokalen Schlüssel ein. Bereits vorhandenes Schlüsselmaterial lässt sich ohne Neugenerierung erneut hochladen:

```sh
./scripts/setup-signing.sh --github-only
```

Der Upload richtet im Repository `frankhildebrandt/panerook` diese Actions-Secrets ein:

| Secret | Inhalt |
| --- | --- |
| `PANEROOK_CERTIFICATE_BASE64` | Base64-kodierte PKCS#12-Datei mit Zertifikat und privatem Schlüssel |
| `PANEROOK_CERTIFICATE_PASSWORD` | Passwort dieser PKCS#12-Datei |
| `PANEROOK_SIGNING_IDENTITY` | SHA-1-Fingerabdruck des Signierzertifikats als eindeutige Schlüsselbund-Identität |

Die Secret-Werte werden nicht in Workflow-Dateien geschrieben. Der SHA-1-Fingerabdruck dient hier nur zur Auswahl des Zertifikats; Downloads erhalten zusätzlich SHA-256-Prüfsummen.

## Lokal signiert paketieren

```sh
signing_directory="$HOME/Library/Application Support/PaneRook/Signing"
security unlock-keychain -p "$(cat "$signing_directory/keychain-password.txt")" \
  "$signing_directory/signing.keychain-db"
export PANEROOK_SIGNING_IDENTITY="$(cat "$signing_directory/identity.txt")"
export PANEROOK_SIGNING_KEYCHAIN="$signing_directory/signing.keychain-db"
./scripts/package-release.sh
```

Dieselben Variablen gelten für `./scripts/build-app.sh release`. Ohne `PANEROOK_SIGNING_IDENTITY` bleibt ein lokaler Entwicklungsbuild ad hoc signiert. Eine ausdrücklich konfigurierte, aber nicht verfügbare Identität lässt den Build fehlschlagen.

`package-release.sh` baut für Apple Silicon und Intel und erzeugt unter `build/release/`:

- `PaneRook-<Version>-macOS-universal.dmg` mit App und Verknüpfung zu `/Applications`;
- `PaneRook-<Version>-macOS-universal.zip` mit dem App-Bundle;
- jeweils eine passende Datei mit Endung `.sha256`.

Die Versionsnummer stammt aus `Resources/Info.plist`. Ein optionales Argument wie `./scripts/package-release.sh v0.1.0` muss dazu passen. Die ZIP-Datei enthält die signierte App; das DMG trägt zusätzlich eine eigene Signatur.

Signatur und Inhalt lassen sich mit den macOS-Werkzeugen prüfen:

```sh
codesign --verify --strict build/PaneRook.app
codesign --display --verbose=4 build/PaneRook.app
hdiutil verify build/release/PaneRook-0.1.0-macOS-universal.dmg
cd build/release
shasum -a 256 -c PaneRook-0.1.0-macOS-universal.zip.sha256
shasum -a 256 -c PaneRook-0.1.0-macOS-universal.dmg.sha256
```

Eine erfolgreiche `codesign`-Prüfung bestätigt die Signaturintegrität, nicht die Gatekeeper-Freigabe oder eine Apple-Notarisierung.

## GitHub Actions

Der Workflow `.github/workflows/release.yml` testet zunächst die App und importiert die hinterlegte Identität anschließend in einen temporären Schlüsselbund auf dem macOS-Runner. App und DMG werden mit dieser Identität signiert. Ein abschließender Schritt entfernt den Schlüsselbund und temporäre Zugangsdaten auch nach einem Buildfehler.

**Actions → App release → Run workflow** erstellt ZIP, DMG und Prüfsummen als Artefakt `PaneRook-macOS-universal`. Ein Tag `v<Version>` veröffentlicht diese Dateien als GitHub-Release. Vor dem Tag müssen die Versionsangaben im App-Bundle und gegebenenfalls `docs/releases/<Version>.md` aktualisiert sein.

Das bestehende öffentliche Release `v0.1.0` enthält weiterhin das ursprünglich veröffentlichte ad-hoc-signierte ZIP. Die neue Konfiguration verändert bereits veröffentlichte Dateien nicht rückwirkend.

## Optional: Developer ID und Notarisierung

Für Apples Vertrauenskette ist eine Apple-Developer-Mitgliedschaft erforderlich. Das persönliche selbst signierte Zertifikat kann nicht nachträglich in ein Developer-ID-Zertifikat umgewandelt werden. Erstelle über Apple ein **Developer ID Application**-Zertifikat und exportiere es zusammen mit seinem privaten Schlüssel als passwortgeschützte `.p12`-Datei. Ersetze damit die drei Signier-Secrets; `PANEROOK_SIGNING_IDENTITY` muss zum neuen Zertifikat passen. Das Skript `setup-signing.sh` erzeugt selbst keine von Apple ausgestellten Zertifikate. Siehe [Developer-ID-Zertifikate bei Apple](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/).

Für einen lokalen Build mit Developer ID und sicherem Zeitstempel:

```sh
export PANEROOK_SIGNING_IDENTITY="<Fingerabdruck des Developer-ID-Zertifikats>"
export PANEROOK_SIGNING_KEYCHAIN="<Pfad zum Schlüsselbund>"
export PANEROOK_SIGNING_TIMESTAMP=secure
export PANEROOK_NOTARY_PROFILE="<notarytool-Schlüsselbundprofil>"
# Bei einem Profil in einem eigenen Schlüsselbund zusätzlich:
# export PANEROOK_NOTARY_KEYCHAIN="<Pfad zum Schlüsselbund>"
./scripts/package-release.sh
```

Das Profil muss zuvor mit `xcrun notarytool store-credentials` eingerichtet sein. Das Paketierskript übermittelt zuerst die App an Apple und heftet das Notarisierungsticket an die App, bevor es ZIP und DMG erstellt. Anschließend wird auch das signierte DMG notarisiert und sein Ticket angeheftet. Erst danach werden die finalen Prüfsummen berechnet.

Für die Notarisierung in GitHub Actions zusätzlich alle drei Secrets eines App-Store-Connect-API-Schlüssels mit Notarisierungsberechtigung hinterlegen:

| Secret | Inhalt |
| --- | --- |
| `APPLE_NOTARY_KEY_P8` | Vollständiger privater API-Schlüssel im `.p8`-Format |
| `APPLE_NOTARY_KEY_ID` | API-Key-ID |
| `APPLE_NOTARY_ISSUER_ID` | Issuer-ID |

Mit vollständigen Notarisierungs-Secrets aktiviert der Workflow den sicheren Zeitstempel automatisch. Für Developer-ID-Builds ohne Notarisierung lässt er sich über die Repository-Variable `PANEROOK_SIGNING_TIMESTAMP=secure` aktivieren. Ohne Apple-Zugangsdaten wird nur die konfigurierte Signatur angebracht. Eine unvollständige Notarisierungskonfiguration wird als Fehler behandelt. Developer-ID-Builds für die öffentliche Verteilung sollten mit Notarisierung ausgeführt werden. Details zum Verfahren: [Apples Notarisierungsdokumentation](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).
