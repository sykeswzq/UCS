#!/bin/bash
# build trigger marker: rebuild 2026-09-17T22:49:22.2302023+08:00
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
VER=4.3.9
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
LOG=/var/mobile/Documents/hb_install.log
mkdir -p /var/mobile/Media/HealthBoost
chmod 777 /var/mobile/Media/HealthBoost
echo "=== postinst $(date) ===" > "$LOG"
# Refresh icon cache
if [ -x /var/jb/usr/bin/uicache ]; then
  /var/jb/usr/bin/uicache -a 2>/dev/null || true
  /var/jb/usr/bin/uicache -p /Applications/UCS.app 2>/dev/null || true
elif [ -x /usr/bin/uicache ]; then
  /usr/bin/uicache -a 2>/dev/null || true
  /usr/bin/uicache -p /Applications/UCS.app 2>/dev/null || true
fi
# Remove old launchd job
killall -9 hb_schedule.sh 2>/dev/null || true
pkill -9 -f hb_schedule.sh 2>/dev/null || true
sleep 1
killall -9 hb_schedule.sh 2>/dev/null || true
launchctl bootout gui/501/com.sykes.ucs.schedule 2>>"$LOG" || true
launchctl bootout gui/501/com.sykes.ucs.schedule 2>>"$LOG" || true
launchctl bootout user/foreground/com.sykes.ucs.schedule 2>>"$LOG" || true
rm -f /var/jb/Library/LaunchAgents/com.sykes.ucs.schedule.plist 2>/dev/null || true
rm -f /var/jb/Library/LaunchDaemons/com.sykes.ucs.schedule.plist 2>/dev/null || true
rm -f /var/mobile/Library/LaunchAgents/com.sykes.ucs.schedule.plist 2>/dev/null || true

# Install LaunchDaemon as mobile user (sh poller, no HealthKit direct)
mkdir -p /var/jb/Library/LaunchDaemons
chmod 777 /var/jb/Library/LaunchDaemons
PLIST=/var/jb/Library/LaunchDaemons/com.sykes.ucs.schedule.plist

# Simple trigger script - just uiopen
SCRIPT=/var/mobile/Media/HealthBoost/hb_schedule.sh
cat > "$SCRIPT" << 'SCRIPT_EOF'
#!/bin/sh
LOG=/var/mobile/Media/HealthBoost/hb_launchd.log
echo "script started $(date) uid=$(id -u)" >> $LOG
LAST=/var/mobile/Media/HealthBoost/hb_lastgen.txt
NEXT=/var/mobile/Media/HealthBoost/hb_nexttime.txt
while true; do
  TODAY=$(date +%Y-%m-%d)
  LASTV=$(cat $LAST 2>/dev/null)
  if [ "$LASTV" = "$TODAY" ]; then sleep 300; continue; fi
  NT=$(cat $NEXT 2>/dev/null)
  if [ -z "$NT" ]; then sleep 300; continue; fi
  NOWM=$(date +%H%M | sed "s/^\([0-9][0-9]\)\([0-9][0-9]\)$/\1*60+\2/")
  SCM=$(echo "$NT" | sed "s/^\([0-9][0-9]\):\([0-9][0-9]\)$/\1*60+\2/")
  N=$(echo "$NOWM" | bc)
  S=$(echo "$SCM" | bc)
  D=$((S - N))
  if [ $D -le 0 ]; then
    echo "wake $(date) now=$N sched=$S" >> $LOG
    /var/jb/usr/bin/uiopen ucs://generate 2>>$LOG
    sleep 60
  elif [ $D -le 2 ]; then
    sleep 5
  else
    S=$(( (D - 2) * 60 ))
    if [ $S -gt 300 ]; then S=300; fi
    sleep $S
  fi
done
SCRIPT_EOF
chmod 755 "$SCRIPT"
chown mobile:mobile "$SCRIPT" 2>/dev/null || true

# Default plist with StartCalendarInterval 6:00
cat > "$PLIST" << PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.sykes.ucs.schedule</string>
  <key>UserName</key>
  <string>mobile</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string>
    <string>$SCRIPT</string>
  </array>

  <key>StandardOutPath</key>
  <string>/var/mobile/Media/HealthBoost/hb_launchd.log</string>
  <key>StandardErrorPath</key>
  <string>/var/mobile/Media/HealthBoost/hb_launchd_err.log</string>
</dict>
</plist>
PLIST_EOF
chmod 644 "$PLIST"
chown root:wheel "$PLIST" 2>/dev/null || true
plutil -lint "$PLIST" >> "$LOG" 2>&1
cat "$PLIST" >> "$LOG" 2>&1
chmod 777 /var/jb/Library/LaunchDaemons/ 2>/dev/null || true
echo "PLIST installed" >> "$LOG"
launchctl bootout gui/501/com.sykes.ucs.schedule 2>>"$LOG" || true
launchctl bootstrap gui/501 "$PLIST" >> "$LOG" 2>&1
echo "bootstrap rc=$?" >> "$LOG"
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
