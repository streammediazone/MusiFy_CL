# MusiFy

Android prehrávač hudby (Flutter), ktorý streamuje skladby zo zdieľaného priečinka kDrive.
Prehráva na pozadí, zobrazuje obaly z FLAC metadát a ovládanie v notifikácii.

## Konfigurácia kDrive

ID disku a token zdieľaného odkazu sú ako predvolené hodnoty v `KDriveService` (`lib/main.dart`).
Pri buildi ich možno voliteľne prepísať cez `--dart-define=KDRIVE_DRIVE_ID=...` a `--dart-define=KDRIVE_SHARE_TOKEN=...`.

## Build cez GitHub Actions

Workflow `.github/workflows/android-apk.yml` vygeneruje Android projekt, spustí analýzu a testy
a zostaví `app-release.apk`. Žiadne secrets nie sú povinné. Voliteľné secrets na stabilný podpis APK
(*Settings → Secrets and variables → Actions*):

| Secret | Obsah |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | keystore zakódovaný v base64 |
| `ANDROID_KEYSTORE_PASSWORD` | heslo keystore |
| `ANDROID_KEY_ALIAS` | alias kľúča |
| `ANDROID_KEY_PASSWORD` | heslo kľúča |

Bez signing secrets sa APK podpíše dočasným debug kľúčom, ktorý je pri každom builde iný,
takže ďalšiu verziu nepôjde nainštalovať ako aktualizáciu (treba odinštalovať).

### Vytvorenie keystore (jednorazovo)

```bash
keytool -genkey -v -keystore upload-keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias musify
base64 -w0 upload-keystore.jks        # Linux; na macOS: base64 -i upload-keystore.jks | tr -d '\n'
```

Výstup `base64` vlož do secretu `ANDROID_KEYSTORE_BASE64`. Súbor `upload-keystore.jks` si **bezpečne
zálohuj mimo repozitára** – bez neho sa už nikdy nepodarí vydať aktualizáciu s rovnakým podpisom.
Krok „Show APK signing certificate“ v CI vypíše SHA-256 odtlačok, podľa ktorého overíš, že je podpis stabilný.

## Testy

```bash
flutter test
```
