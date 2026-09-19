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

# Version: v3.0.3 (閸氬牊鍨氶弽閿嬫拱閺€褰掓懙閸戝本娅掗弮鑸殿唽閿涘矂浼╁鈧琀ealthKit閺冨爼妫块柌宥呭綌閸樺鍣哥€佃壈鍤ч惃鍕劄閺侀娑径?
VER=4.4.27
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
if [ "$magic" != "cafebabe" ] && [ "$magic" != "cffaedfe" ]; then
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
  ldid -S tweak_staging/Library/MobileSubstrate/DynamicLibraries/StepFaker.dylib
  echo "  signed tweak dylib with ldid"
else
  echo "WARN: ldid not available, tweak dylib unsigned (may fail to load on roothide)"
fi

# Verify dylib Mach-O magic
smagic=$(xxd -p -l4 tweak_staging/Library/MobileSubstrate/DynamicLibraries/StepFaker.dylib 2>/dev/null || od -An -tx1 -N4 tweak_staging/Library/MobileSubstrate/DynamicLibraries/StepFaker.dylib | tr -d ' \n')
if [ "$smagic" != "cafebabe" ] && [ "$smagic" != "cffaedfe" ]; then
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
mkdir -p /var/mobile/Documents
chmod 777 /var/mobile/Documents
touch /var/mobile/Documents/hb_nexttime.txt /var/mobile/Documents/hb_lastgen.txt
chmod 666 /var/mobile/Documents/hb_nexttime.txt /var/mobile/Documents/hb_lastgen.txt
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
sleep 2
killall -9 hb_schedule.sh 2>/dev/null || true
pkill -9 -f hb_schedule.sh 2>/dev/null || true
sleep 1
# App will bootstrap on launch
# App will bootstrap on launch
# App will bootstrap on launch
rm -f /var/mobile/Library/LaunchAgents/com.sykes.ucs.schedule.plist 2>/dev/null || true
rm -f /var/mobile/Library/LaunchAgents/com.sykes.ucs.schedule.plist 2>/dev/null || true
rm -f /var/mobile/Library/LaunchAgents/com.sykes.ucs.schedule.plist 2>/dev/null || true

# Install LaunchDaemon as mobile user (sh poller, no HealthKit direct)
mkdir -p /Library/LaunchDaemons
chmod 777 /Library/LaunchDaemons
PLIST=/Library/LaunchDaemons/com.sykes.ucs.schedule.plist

# Simple trigger script - just uiopen
SCRIPT=/var/mobile/Media/HealthBoost/hb_schedule.sh
cat > "$SCRIPT" << 'SCRIPT_EOF'
#!/bin/sh
LOG=/var/mobile/Media/HealthBoost/hb_launchd.log
echo "script started $(date) uid=$(id -u)" >> $LOG
LAST=/var/mobile/Containers/Shared/AppGroup/.jbroot-C149CB1AB24ACB6A/var/mobile/Documents/hb_lastgen.txt
NEXT=/var/mobile/Containers/Shared/AppGroup/.jbroot-C149CB1AB24ACB6A/var/mobile/Documents/hb_nexttime.txt
while true; do
  TODAY=$(date +%Y-%m-%d)
  LASTV=$(cat $LAST 2>/dev/null)
  if [ "$LASTV" = "$TODAY" ]; then sleep 300; continue; fi
  NT=$(cat $NEXT 2>/dev/null)
  echo "poll: nt=$NT nextpath=$NEXT" >> $LOG
  if [ -z "$NT" ]; then sleep 300; continue; fi
  NOWH=$(date +%H); NOWM=$(date +%M); N=$((NOWH*60+NOWM))
  SH=$(echo "$NT" | cut -d: -f1); SM=$(echo "$NT" | cut -d: -f2); S=$((SH*60+SM))
  D=$((S - N))
  if [ $D -le 0 ]; then
    echo "wake $(date) now=$N sched=$S" >> $LOG
    SB_PID=$(launchctl list | grep SpringBoard | awk '{print $1}' | head -1)
    echo "wake sb_pid=$SB_PID" >> $LOG
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
ls -la "$SCRIPT" >> "$LOG" 2>&1
echo "script written: $(wc -l < $SCRIPT) lines" >> "$LOG"

# Default plist with StartCalendarInterval 6:00
cat > "$PLIST" << PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.sykes.ucs.schedule</string>
  <key>RunAtLoad</key><true/>
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
# Also write to App container mirror path (roothide sandbox redirect)
APPMIRROR=/var/containers/Bundle/Application/.jbroot-C149CB1AB24ACB6A/Library/LaunchDaemons
mkdir -p "$APPMIRROR" 2>/dev/null || true
cp "$PLIST" "$APPMIRROR/com.sykes.ucs.schedule.plist" 2>/dev/null || true
chmod 644 "$APPMIRROR/com.sykes.ucs.schedule.plist" 2>/dev/null || true
echo "PLIST installed" >> "$LOG"
ls -la /var/mobile/Library/LaunchAgents/ >> "$LOG" 2>&1
ls -la /var/mobile/Media/HealthBoost/ >> "$LOG" 2>&1
# App will bootstrap on launch
# App will bootstrap on launch
# root daemon not loaded; App setupDaemon bootstraps gui/501 (git4 behavior)
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
