#!/bin/bash
#
# mikagosz-build.sh — SpliceKit bez Sentry do kopii Final Cuta, jednym poleceniem.
#
# Zastępuje patcher/patch_fcp.sh (przestarzały: kompiluje bez aktualnych flag
# i pęka na spacjach w ścieżce) i `make deploy` (bez wstrzykiwania, za to
# z BRAW/VP9/MKV, których nie używamy).
#
#   1. make all                     → build/SpliceKit
#   2. framework do kopii FCP       → Contents/Frameworks/SpliceKit.framework
#   3. opisy zgód w Info.plist      → mowa, mikrofon
#   4. insert_dylib                 → LC_LOAD_DYLIB, tylko gdy go jeszcze nie ma
#   5. ustawienia CloudContent      → bez nich przepodpisana kopia pada przy starcie
#   6. podpis certyfikatem lokalny certyfikat (bez cichego zapasu adhoc)
#   7. weryfikacja
#
# Oryginał w /Applications nie jest ruszany — także jego preferencje: żyją
# w kontenerze sandboksa, a kopia (bez sandboksa) czyta ~/Library/Preferences.
#
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/SpliceKit/Final Cut Pro.app"
BIN="$APP/Contents/MacOS/Final Cut Pro"
FW_DIR="$APP/Contents/Frameworks/SpliceKit.framework"
ENTITLEMENTS="$REPO/entitlements.plist"
IDENTITY="${SPLICEKIT_SIGN_IDENTITY:?ustaw SPLICEKIT_SIGN_IDENTITY}"
LOAD_CMD="@rpath/SpliceKit.framework/Versions/A/SpliceKit"
INSERT_DYLIB="$REPO/build/insert_dylib"
INSERT_DYLIB_SRC="$REPO/build/insert_dylib-src"
VERSION="$(awk -F= '/SPLICEKIT_VERSION/ { gsub(/[ ;]/, "", $2); print $2; exit }' "$REPO/patcher/SpliceKit/Configuration/Version.xcconfig")"

krok() { printf '\n=== %s ===\n' "$*"; }
stop() { printf '\n[X] %s\n' "$*" >&2; exit 1; }

# --- 0. warunki -------------------------------------------------------------
krok "0. Warunki"
[[ -d "$APP" ]] || stop "Brak kopii Final Cuta: $APP"
if pgrep -f "$BIN" >/dev/null; then
    stop "Kopia Final Cuta chodzi — zamknij ją i odpal jeszcze raz."
fi
# find-identity BEZ -v: certyfikat jest samopodpisany, -v go ukrywa.
security find-identity -p codesigning | grep -q "$IDENTITY" \
    || stop "Nie widzę certyfikatu lokalny certyfikat ($IDENTITY) w pęku kluczy."
echo "[+] kopia FCP: $APP"
echo "[+] SpliceKit $VERSION, repo: $REPO"

# --- 1. budowa --------------------------------------------------------------
krok "1. Budowa biblioteki"
make -C "$REPO" all
[[ -f "$REPO/build/SpliceKit" ]] || stop "make nie zostawił build/SpliceKit"

# --- 2. framework -----------------------------------------------------------
krok "2. Framework w kopii FCP"
mkdir -p "$FW_DIR/Versions/A/Resources"
cp -f "$REPO/build/SpliceKit" "$FW_DIR/Versions/A/SpliceKit"
# -n: przy kolejnym przebiegu podmienia dowiązanie, zamiast wchodzić w nie.
ln -sfn A "$FW_DIR/Versions/Current"
ln -sfn Versions/Current/SpliceKit "$FW_DIR/SpliceKit"
ln -sfn Versions/Current/Resources "$FW_DIR/Resources"
cat > "$FW_DIR/Versions/A/Resources/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.splicekit.SpliceKit</string>
    <key>CFBundleName</key><string>SpliceKit</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundlePackageType</key><string>FMWK</string>
    <key>CFBundleExecutable</key><string>SpliceKit</string>
</dict>
</plist>
PLIST
echo "[+] $FW_DIR"

# --- 3. opisy zgód ----------------------------------------------------------
krok "3. Opisy zgód w Info.plist"
ustaw_opis() {
    local klucz="$1" tekst="$2" plist="$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :$klucz '$tekst'" "$plist" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :$klucz string '$tekst'" "$plist"
}
ustaw_opis NSSpeechRecognitionUsageDescription "SpliceKit uses speech recognition for transcript editing inside Final Cut Pro."
ustaw_opis NSMicrophoneUsageDescription "SpliceKit uses the microphone for voice dictation inside Final Cut Pro."
echo "[+] mowa, mikrofon"

# --- 4. wstrzyknięcie -------------------------------------------------------
krok "4. Wstrzyknięcie"
if otool -L "$BIN" | grep -q "$LOAD_CMD"; then
    echo "[+] już wstrzyknięte — pomijam"
else
    if [[ ! -x "$INSERT_DYLIB" ]]; then
        echo "[i] buduję insert_dylib (github.com/tyilo/insert_dylib)"
        [[ -d "$INSERT_DYLIB_SRC" ]] || git clone --quiet --depth 1 https://github.com/tyilo/insert_dylib.git "$INSERT_DYLIB_SRC"
        echo "[i] insert_dylib @ $(git -C "$INSERT_DYLIB_SRC" rev-parse --short HEAD)"
        clang -o "$INSERT_DYLIB" "$INSERT_DYLIB_SRC/insert_dylib/main.c" -framework Foundation
    fi
    "$INSERT_DYLIB" --inplace --all-yes "$LOAD_CMD" "$BIN"
    otool -L "$BIN" | grep -q "$LOAD_CMD" || stop "insert_dylib skończył, ale LC_LOAD_DYLIB nie ma w binarce"
    echo "[+] LC_LOAD_DYLIB wstawione"
fi

# --- 5. CloudContent --------------------------------------------------------
krok "5. Ustawienia CloudContent"
# Przepodpisana kopia traci uprawnienia iCloud i pada na treściach z chmury.
# Pełna ścieżka, nie domena: `defaults write com.apple.FinalCut` trafia do kontenera
# sandboksa ORYGINAŁU. Kopia ma sandbox wyłączony i czyta ~/Library/Preferences.
PREFS="$HOME/Library/Preferences/com.apple.FinalCut.plist"
defaults write "$PREFS" CloudContentFirstLaunchCompleted -bool true
defaults write "$PREFS" FFCloudContentDisabled -bool true
echo "[+] $PREFS: CloudContentFirstLaunchCompleted = true, FFCloudContentDisabled = true"

# --- 6. podpis --------------------------------------------------------------
krok "6. Podpis (lokalny certyfikat)"
# Śmieciowe atrybuty po insert_dylib/PlistBuddy psują pieczęć podpisu.
xattr -cr "$APP" 2>/dev/null || true
# Od środka na zewnątrz: framework, potem aplikacja. Frameworki Apple zostają
# z oryginalnym podpisem — ProAppSupport sprawdza je przy starcie.
codesign --force --options runtime --sign "$IDENTITY" "$FW_DIR"
codesign --force --options runtime --sign "$IDENTITY" --entitlements "$ENTITLEMENTS" "$APP"

# --- 7. weryfikacja ---------------------------------------------------------
krok "7. Weryfikacja"
blad=0
if otool -L "$BIN" | grep -q "$LOAD_CMD"; then echo "[+] wstrzyknięcie: jest"; else echo "[X] wstrzyknięcie: BRAK"; blad=1; fi
podpis="$(codesign -dvv "$APP" 2>&1 | awk -F= '/^Authority=/ && !n++ { print $2 }')"
if [[ "$podpis" == "lokalny certyfikat" ]]; then echo "[+] podpis aplikacji: $podpis"; else echo "[X] podpis aplikacji: ${podpis:-brak}"; blad=1; fi
podpis_fw="$(codesign -dvv "$FW_DIR" 2>&1 | awk -F= '/^Authority=/ && !n++ { print $2 }')"
if [[ "$podpis_fw" == "lokalny certyfikat" ]]; then echo "[+] podpis frameworka: $podpis_fw"; else echo "[X] podpis frameworka: ${podpis_fw:-brak}"; blad=1; fi
if codesign -d --entitlements - "$APP" 2>&1 | grep -q disable-library-validation; then echo "[+] uprawnienia: disable-library-validation"; else echo "[X] uprawnienia: brak disable-library-validation"; blad=1; fi
echo "[i] codesign --verify: $(codesign --verify "$APP" 2>&1 || true)"

[[ $blad -eq 0 ]] || stop "Weryfikacja nie przeszła — kopia może nie wystartować."
printf '\nGotowe. Zamknij oryginalnego Final Cuta i otwórz kopię:\n  open "%s"\n' "$APP"
