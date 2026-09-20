#!/bin/bash
# build trigger marker: rebuild to refresh CI checkout
set -eu

# UCS v5.3.0 - 两个独立 deb：App 本体 + 自动守护
# deb1: com.sykes.ucs (git5 App + dylib，手动生成微信+健康正确)
# deb2: com.sykes.ucs.schedule (launchd + 脚本，锁屏+关App自动触发)

VER=5.3.6
echo "Version: $VER"

# ========== deb1: App 本体 ==========
PKG1="com.sykes.ucs"
OUT1="${PKG1}_${VER}_iphoneos-arm64e.deb"

echo "[1/6] Building App deb (git5 precompiled)"
rm -rf staging1
mkdir -p staging1/Applications/UCS.app
mkdir -p staging1/Library/MobileSubstrate/DynamicLibraries
mkdir -p staging1/DEBIAN

# git5 precompiled App
cp tweak/HealthBoostApp_precompiled staging1/Applications/UCS.app/HealthBoostApp
chmod 755 staging1/Applications/UCS.app/HealthBoostApp
echo "  app: $(wc -c < staging1/Applications/UCS.app/HealthBoostApp) bytes"

# App resources
cp HealthBoostApp/Info.plist  staging1/Applications/UCS.app/
cp HealthBoostApp/HealthBoost/AppIcon60x60@2x.png staging1/Applications/UCS.app/
cp HealthBoostApp/HealthBoost/PkgInfo    staging1/Applications/UCS.app/
chmod 644 staging1/Applications/UCS.app/Info.plist
chmod 644 staging1/Applications/UCS.app/AppIcon60x60@2x.png
chmod 644 staging1/Applications/UCS.app/PkgInfo

# git5 precompiled dylib
cp tweak/StepFaker_precompiled.dylib staging1/Library/MobileSubstrate/DynamicLibraries/StepFaker.dylib
chmod 755 staging1/Library/MobileSubstrate/DynamicLibraries/StepFaker.dylib
echo "  dylib: $(wc -c < staging1/Library/MobileSubstrate/DynamicLibraries/StepFaker.dylib) bytes"

cp tweak/StepFaker.plist staging1/Library/MobileSubstrate/DynamicLibraries/StepFaker.plist
chmod 644 staging1/Library/MobileSubstrate/DynamicLibraries/StepFaker.plist

# control
cat > staging1/DEBIAN/control << EOF
Package: ${PKG1}
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

# postinst - 只做 uicache，不装 launchd
cat > staging1/DEBIAN/postinst << 'EOF'
#!/bin/sh
echo "=== UCS App postinst $(date) ==="
mkdir -p /var/mobile/Media/HealthBoost
chmod 777 /var/mobile/Media/HealthBoost
mkdir -p /var/mobile/Documents
chmod 777 /var/mobile/Documents
if [ -x /var/jb/usr/bin/uicache ]; then
  /var/jb/usr/bin/uicache -a 2>/dev/null || true
  /var/jb/usr/bin/uicache -p /Applications/UCS.app 2>/dev/null || true
fi
exit 0
EOF
chmod 755 staging1/DEBIAN/postinst

dpkg-deb -b -Zgzip staging1 "$OUT1"
echo "  -> $OUT1 ($(ls -lh "$OUT1" | awk '{print $5}'))"

# ========== deb2: 自动守护 ==========
PKG2="com.sykes.ucs.schedule"
OUT2="${PKG2}_${VER}_iphoneos-arm64e.deb"

echo "[2/6] Building schedule daemon deb"
rm -rf staging2
mkdir -p staging2/DEBIAN
mkdir -p staging2/Library/LaunchDaemons

# control
cat > staging2/DEBIAN/control << EOF
Package: ${PKG2}
Name: UCS Schedule Daemon
Version: ${VER}
Architecture: iphoneos-arm64e
Installed-Size: 32
Depends: ${PKG1} (>= ${VER}), firmware (>= 13.0)
Maintainer: sykeswzq
Author: sykeswzq
Description: UCS 定时自动生成守护（锁屏+关App后台触发）
Section: utilities
Priority: optional
EOF

# postinst - 安装脚本 + plist + bootstrap
cat > staging2/DEBIAN/postinst << 'POSTEOF'
#!/bin/sh
LOG=/var/mobile/Documents/hb_install.log
mkdir -p /var/mobile/Documents
chmod 777 /var/mobile/Documents
echo "=== schedule postinst $(date) ===" >> "$LOG"

# Kill old script
killall -9 hb_schedule.sh 2>/dev/null || true
pkill -9 -f hb_schedule.sh 2>/dev/null || true
sleep 1

# Install script
SCRIPT=/var/mobile/Documents/hb_schedule.sh
cat > "$SCRIPT" << 'SCRIPT_EOF'
#!/bin/sh
LOG=/var/mobile/Documents/hb_launchd.log
echo "script started $(date) uid=$(id -u)" >> $LOG
# Auto-detect jbroot UUID (changes after jailbreak re-install)
JBDIR=$(ls -dt /var/mobile/Containers/Shared/AppGroup/.jbroot-*/ 2>/dev/null | head -1)
echo "jbroot dir: $JBDIR" >> $LOG
LAST="${JBDIR}var/mobile/Documents/hb_lastgen.txt"
NEXT="${JBDIR}var/mobile/Documents/hb_nexttime.txt"
LASTWAKE=/var/mobile/Documents/hb_lastwake.txt
echo "nextpath=$NEXT" >> $LOG
while true; do
  NT=$(cat $NEXT 2>/dev/null)
  LW=$(cat $LASTWAKE 2>/dev/null)
  echo "poll: nt=$NT lastwake=$LW" >> $LOG
  if [ -z "$NT" ]; then sleep 300; continue; fi
  if [ -z "$LW" ] || [ "$NT" != "$LW" ]; then
    echo "new schedule detected: nt=$NT lw=$LW" >> $LOG
    NOWH=$(date +%H); NOWM=$(date +%M); N=$((NOWH*60+NOWM))
    SH=$(echo "$NT" | cut -d: -f1); SM=$(echo "$NT" | cut -d: -f2); S=$((SH*60+SM))
    D=$((S - N))
    if [ $D -le 0 ]; then
      echo "wake $(date) now=$N sched=$S" >> $LOG
      echo "$NT" > $LASTWAKE
      rm -f $LAST 2>/dev/null
      /var/jb/usr/bin/uiopen ucs://generate 2>>$LOG
      sleep 30
    elif [ $D -le 1 ]; then
      sleep 5
    else
      SLEEP_SECS=$(( (D * 60) - 5 ))
      if [ $SLEEP_SECS -gt 1800 ]; then SLEEP_SECS=1800; fi
      if [ $SLEEP_SECS -lt 60 ]; then SLEEP_SECS=60; fi
      echo "sleeping $SLEEP_SECS seconds until near $NT" >> $LOG
      sleep $SLEEP_SECS
    fi
  else
    sleep 300
  fi
done
SCRIPT_EOF
chmod 755 "$SCRIPT"
chown mobile:mobile "$SCRIPT" 2>/dev/null || true
echo "script written: $(wc -l < $SCRIPT) lines" >> "$LOG"

# Install plist
PLIST=/Library/LaunchDaemons/com.sykes.ucs.schedule.plist
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
  <key>UserName</key>
  <string>mobile</string>
  <key>StandardOutPath</key>
  <string>/var/mobile/Documents/hb_launchd.log</string>
  <key>StandardErrorPath</key>
  <string>/var/mobile/Documents/hb_launchd_err.log</string>
</dict>
</plist>
PLIST_EOF
chmod 644 "$PLIST"
chown root:wheel "$PLIST" 2>/dev/null || true
echo "PLIST installed" >> "$LOG"

# Bootstrap
launchctl bootout system/com.sykes.ucs.schedule 2>/dev/null
launchctl bootstrap system "$PLIST" 2>>"$LOG"
echo "bootstrap result: $?" >> "$LOG"
echo "=== done ===" >> "$LOG"
exit 0
POSTEOF
chmod 755 staging2/DEBIAN/postinst

dpkg-deb -b -Zgzip staging2 "$OUT2"
echo "  -> $OUT2 ($(ls -lh "$OUT2" | awk '{print $5}'))"

echo "[3/6] Verify deb1 contents"
echo "  App: $(wc -c < staging1/Applications/UCS.app/HealthBoostApp) bytes"
echo "  dylib: $(wc -c < staging1/Library/MobileSubstrate/DynamicLibraries/StepFaker.dylib) bytes"

echo "[4/6] Verify deb2 contents"
echo "  script embedded in postinst"
echo "  plist embedded in postinst"

echo "[5/6] Upload to GitHub Release (done by CI)"
echo "[6/6] DONE"
echo "  deb1: $OUT1"
echo "  deb2: $OUT2"
