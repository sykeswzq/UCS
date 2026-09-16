#!/bin/bash
# build trigger marker: rebuild to refresh CI checkout
set -eu

# HealthBoost build script (roothide layout - single deb with App + tweak)
# Key conventions (from roothide official docs):
#   1) App must be at relative path ./Applications/UCS.app
#      - roothide's real root is /var/roothide
#      - dpkg will extract to /var/roothide/Applications/UCS.app
#      - NEVER use paths like ./var/jb/ or ./var/roothide/ (dpkg will fail)
#   2) Tweak must be at relative path ./Library/MobileSubstrate/DynamicLibraries/
#   3) Use ldid -M -S<entitlements> for signing (official method)
#   4) Entitlements must include roothide 4 basic permissions + healthkit private permission

# Version: v3.0.3 (鍚堟垚鏍锋湰鏀归摵鍑屾櫒鏃舵锛岄伩寮€HealthKit鏃堕棿閲嶅彔鍘婚噸瀵艰嚧鐨勬鏁颁涪澶?
VER=3.4.3
echo "Version: $VER"
PKG="com.sykes.ucs"
OUT="${PKG}_${VER}_iphoneos-arm64e.deb"

echo "[1/5] Creating staging directory (roothide layout)"
rm -rf staging tweak_staging pkg
mkdir -p staging/Applications/UCS.app
mkdir -p staging/Library/MobileSubstrate/DynamicLibraries
mkdir -p staging/DEBIAN
mkdir -p tweak_staging/Library/MobileSubstrate/DynamicLibraries

SDK=$(xcrun --sdk iphoneos --show-sdk-path)

echo "[2/5] Compiling iOS App (UCS.app) - arm64 + arm64e"
xcrun --sdk iphoneos clang \
  -framework UIKit \
  -framework Foundation \
  -framework HealthKit \
  -framework Security \
  -framework UserNotifications \
  -fobjc-arc \
  -arch arm64 -arch arm64e \
  -mios-version-min=13.4 \
  -isysroot "$SDK" \
  -o staging/Applications/UCS.app/HealthBoostApp \
  HealthBoostApp/HealthBoostApp.m HealthBoostApp/AppDelegate.m
chmod 755 staging/Applications/UCS.app/HealthBoostApp
echo "  app: $(wc -c < staging/Applications/UCS.app/HealthBoostApp) bytes"

echo "[3/5] Copying app resources + signing with ldid"
cp HealthBoostApp/Info.plist  staging/Applications/UCS.app/
cp HealthBoostApp/HealthBoost/AppIcon60x60@2x.png staging/Applications/UCS.app/
cp HealthBoostApp/HealthBoost/PkgInfo    staging/Applications/UCS.app/
chmod 644 staging/Applications/UCS.app/Info.plist
chmod 644 staging/Applications/UCS.app/AppIcon60x60@2x.png
chmod 644 staging/Applications/UCS.app/PkgInfo

if ! command -v ldid >/dev/null 2>&1; then
  echo "ERROR: ldid not installed, cannot sign"
  exit 1
fi
if [ ! -f HealthBoost.entitlements.plist ]; then
  echo "ERROR: HealthBoost.entitlements.plist missing"
  exit 1
fi
ldid -M -SHealthBoost.entitlements.plist staging/Applications/UCS.app/HealthBoostApp
echo "  signed with ldid"

# Verify signature has healthkit permission
if ! ldid -e staging/Applications/UCS.app/HealthBoostApp 2>/dev/null | grep -q "healthkit"; then
  echo "ERROR: signature missing healthkit permission"
  exit 1
fi
# Verify signature has roothide no-sandbox permission
if ! ldid -e staging/Applications/UCS.app/HealthBoostApp 2>/dev/null | grep -q "no-sandbox"; then
  echo "ERROR: signature missing com.apple.private.security.no-sandbox"
  exit 1
fi
# Verify Mach-O magic
magic=$(xxd -p -l4 staging/Applications/UCS.app/HealthBoostApp 2>/dev/null || od -An -tx1 -N4 staging/Applications/UCS.app/HealthBoostApp | tr -d ' \n')
if [ "$magic" != "cafebabe" ]; then
  echo "ERROR: Mach-O header invalid (magic=$magic)"
  exit 1
fi
echo "  signature verified: healthkit + no-sandbox present, Mach-O header OK"

echo "[4/5] Compiling and signing StepFaker tweak (embedded in same deb)"
xcrun --sdk iphoneos clang \
  -dynamiclib -fobjc-arc \
  -framework Foundation -framework CoreFoundation -framework CoreMotion -framework HealthKit \
  -arch arm64 -arch arm64e \
  -mios-version-min=13.0 \
  -isysroot "$SDK" \
  -o tweak_staging/Library/MobileSubstrate/DynamicLibraries/StepFaker.dylib \
  tweak/StepFaker.m
chmod 755 tweak_staging/Library/MobileSubstrate/DynamicLibraries/StepFaker.dylib
echo "  tweak dylib: $(wc -c < tweak_staging/Library/MobileSubstrate/DynamicLibraries/StepFaker.dylib) bytes"

cp tweak/StepFaker.plist tweak_staging/Library/MobileSubstrate/DynamicLibraries/StepFaker.plist
chmod 644 tweak_staging/Library/MobileSubstrate/DynamicLibraries/StepFaker.plist

if command -v ldid >/dev/null 2>&1; then
  ldid -M -S tweak_staging/Library/MobileSubstrate/DynamicLibraries/StepFaker.dylib
  echo "  signed tweak dylib with ldid"
else
  echo "WARN: ldid not available, tweak dylib unsigned (may fail to load on roothide)"
fi

# Verify dylib Mach-O magic
smagic=$(xxd -p -l4 tweak_staging/Library/MobileSubstrate/DynamicLibraries/StepFaker.dylib 2>/dev/null || od -An -tx1 -N4 tweak_staging/Library/MobileSubstrate/DynamicLibraries/StepFaker.dylib | tr -d ' \n')
if [ "$smagic" != "cafebabe" ]; then
  echo "ERROR: tweak dylib Mach-O header invalid (magic=$smagic)"
  exit 1
fi
echo "  tweak signed verified: Mach-O header OK"

echo "  merging tweak into staging"
cp tweak_staging/Library/MobileSubstrate/DynamicLibraries/StepFaker.dylib staging/Library/MobileSubstrate/DynamicLibraries/StepFaker.dylib
cp tweak_staging/Library/MobileSubstrate/DynamicLibraries/StepFaker.plist staging/Library/MobileSubstrate/DynamicLibraries/StepFaker.plist
chmod 755 staging/Library/MobileSubstrate/DynamicLibraries/StepFaker.dylib
chmod 644 staging/Library/MobileSubstrate/DynamicLibraries/StepFaker.plist

echo "[5/5] Generating control/postinst and packaging (single deb)"
cat > staging/DEBIAN/control << EOF
Package: com.sykes.ucs
Name: UCS
Version: ${VER}
Architecture: iphoneos-arm64e
Installed-Size: 1152
Depends: firmware (>= 13.0)
Maintainer: sykeswzq
Author: sykeswzq
Description: UCS 运动步数注入工具，健康与微信运动同步显示真实+虚拟步数
Section: utilities
Priority: optional
EOF

cat > staging/DEBIAN/postinst << 'EOF'
#!/bin/sh
APP=/var/jb/Applications/UCS.app/HealthBoostApp
PLIST=/var/mobile/Library/LaunchAgents/com.sykes.ucs.schedule.plist
LOG=/var/mobile/Documents/hb_install.log
echo "=== postinst $(date) ===" > "$LOG"
# Refresh icon cache
if [ -x /var/jb/usr/bin/uicache ]; then
  /var/jb/usr/bin/uicache -a 2>/dev/null || true
  /var/jb/usr/bin/uicache -p /Applications/UCS.app 2>/dev/null || true
elif [ -x /usr/bin/uicache ]; then
  /usr/bin/uicache -a 2>/dev/null || true
  /usr/bin/uicache -p /Applications/UCS.app 2>/dev/null || true
fi
# Install LaunchAgent to standard mobile path (visible in user/foreground domain)
mkdir -p /var/mobile/Library/LaunchAgents
# Pre-create log files with correct permissions (launchd won't start if it can't write)
touch /var/mobile/Documents/hb_launchd.log /var/mobile/Documents/hb_launchd_err.log
chmod 666 /var/mobile/Documents/hb_launchd.log /var/mobile/Documents/hb_launchd_err.log
cat > "$PLIST" << PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.sykes.ucs.schedule</string>
  <key>ProgramArguments</key>
  <array>
    <string>/var/jb/Applications/UCS.app/HealthBoostApp</string>
    <string>--auto-generate</string>
  </array>
  <key>StartInterval</key>
  <integer>60</integer>
  <key>RunAtLoad</key>
  <false/>
</dict>
</plist>
PLIST_EOF
chmod 644 "$PLIST"
chown mobile:mobile "$PLIST" 2>/dev/null || chown 501:501 "$PLIST" 2>/dev/null || true
echo "PLIST=$PLIST" >> "$LOG"
ls -la "$PLIST" >> "$LOG" 2>&1
echo "APP exists:" >> "$LOG"
ls -la "$APP" >> "$LOG" 2>&1
# v3.3.5: 用旧命令 launchctl load -w（不需要 bootstrap 域格式）
echo "--- load -w ---" >> "$LOG"
launchctl unload "$PLIST" 2>>"$LOG" || true
launchctl load -w "$PLIST" >> "$LOG" 2>&1
echo "load -w exit=$?" >> "$LOG"
echo "--- kickstart test ---" >> "$LOG"
launchctl start com.sykes.ucs.schedule 2>>"$LOG" || echo "start failed" >> "$LOG"
sleep 2
echo "--- list ---" >> "$LOG"
launchctl list | grep -i sykes >> "$LOG" 2>&1 || echo "no sykes in list" >> "$LOG"
echo "=== done ===" >> "$LOG"
# Force kill WeChat
for k in /var/jb/bin/killall /usr/bin/killall killall; do
  if [ -x "$k" ]; then
    "$k" -9 WeChat 2>/dev/null || true
    break
  fi
done
exit 0
EOF

chmod 755 staging/DEBIAN/postinst

dpkg-deb -b -Zgzip staging "$OUT"
echo "  -> $(ls -lh "$OUT" | awk '{print $5}') bytes"
echo "DONE: $OUT"
