#!/bin/bash
# Differential test for thomx/fr24feed-piaware-style images.
#   fr24-imagetest.sh <image> <platform>      e.g. fr24up:A-arm64 linux/arm64
# Prints a normalised report (comparable across images with diff).
set -uo pipefail
IMG="$1" PLAT="$2"
name="t-$(echo "$IMG-$PLAT" | tr -c 'a-zA-Z0-9' '-')"

echo "### static"
docker run --rm --platform "$PLAT" --entrypoint bash "$IMG" -c '
  . /etc/os-release; echo "debian: $VERSION_CODENAME"
  echo "dpkg-arch: $(dpkg --print-architecture)"
  echo "dump1090: $(/usr/lib/fr24/dump1090 --version 2>&1 | grep -m1 -i "dump1090")"
  echo "piaware: $(/usr/bin/piaware -v 2>&1 | head -1)"
  echo "fr24feed: $(/fr24feed/fr24feed/fr24feed --version 2>&1 | head -1)"
  echo "readsb: $(/usr/local/share/adsbexchange/readsb --version 2>&1 | head -1)"
  echo "adsbx-mlat: $(/usr/local/share/adsbexchange/venv/bin/python3 -c "import mlat.client; print(\"import ok\")" 2>&1 | tail -1)"
  echo "rb-mlat: $(/usr/local/share/radarbox-mlat-client/venv/bin/python3 -c "import mlat.client; print(\"import ok\")" 2>&1 | tail -1)"
  echo "pfclient: $(/planefinder/pfclient --version 2>&1 | head -1)"
  echo "rbfeeder: $(/usr/bin/rbfeeder --version 2>&1 | head -1)"
  echo "confd: $(/opt/confd/bin/confd --version 2>&1 | head -1)"
  echo "nginx: $(nginx -v 2>&1)"
  echo "nc: $(ls -l /bin/nc 2>&1 | awk "{print \$NF}")"
  echo "tcl-tls: $(echo "package require tls; puts [package version tls]" | tclsh 2>&1)"
  echo "opensky: $(ls /usr/bin/openskyd* 2>/dev/null | tr "\n" " ")"
  echo "loader: $(ls -l /lib | head -1 >/dev/null; [ -L /lib ] && echo "/lib -> $(readlink /lib)" || echo "/lib is a directory")"
' 2>&1

echo "### tls handshake piaware.flightaware.com:1200"
docker run --rm --platform "$PLAT" --entrypoint bash "$IMG" -c '
cat > /tmp/t.tcl <<"EOF"
package require tls
if {[catch {
  set s [tls::socket -async piaware.flightaware.com 1200]
  fconfigure $s -blocking 1
  tls::handshake $s
  set st [tls::status $s]
  puts "handshake: ok, cipher [dict get $st cipher], peer [dict get $st subject]"
  close $s
} err]} { puts "handshake: FAILED $err" }
EOF
tclsh /tmp/t.tcl' 2>&1 | tail -1

echo "### runtime (network none, all feeders on except adsbhub which downloads at runtime, dummy keys)"
docker rm -f "$name" >/dev/null 2>&1
docker run -d --name "$name" --platform "$PLAT" --network none \
  -e FR24FEED_FR24KEY=0000000000000000 \
  -e PIAWARE_FEEDER_DASH_ID=00000000-0000-0000-0000-000000000000 \
  -e DUMP1090_ADDITIONAL_ARGS="--device-type none" \
  -e SERVICE_ENABLE_ADSBEXCHANGE=true -e ADSBEXCHANGE_UUID=00000000-0000-0000-0000-000000000000 \
  -e SERVICE_ENABLE_ADSBFI=true -e ADSBFI_UUID=00000000-0000-0000-0000-000000000000 \
  -e SERVICE_ENABLE_PLANEFINDER=true -e PLANEFINDER_SHARECODE=000000000000 \
  -e SERVICE_ENABLE_OPENSKY=true -e OPENSKY_USERNAME=test -e OPENSKY_SERIAL=1 \
  -e SERVICE_ENABLE_RADARBOX=true -e RADARBOX_SHARING_KEY=00000000000000000000000000000000 \
  -e MLAT_EXACT_LAT=50.1 -e MLAT_EXACT_LON=8.7 -e MLAT_ALTITUDE_MSL_METERS=112 -e ADSBEXCHANGE_STATION_NAME=test \
  -e HTML_SITE_LAT=50.1 -e HTML_SITE_LON=8.7 \
  "$IMG" >/dev/null
sleep 90
docker exec "$name" bash -c '
  for s in /run/service/*; do
    n=$(basename "$s"); case "$n" in s6rc-*|*-log) continue;; esac
    st=$(/command/s6-svstat "$s" 2>/dev/null)
    state=${st%% *}
    sec=$(echo "$st" | grep -oE "[0-9]+ seconds" | head -1 | grep -oE "^[0-9]+")
    if [ "$state" = up ] && [ "${sec:-0}" -ge 45 ]; then echo "svc $n: up (stable)"
    elif [ "$state" = up ]; then echo "svc $n: up (restarted within 45s)"
    else echo "svc $n: ${st:-no status}" | sed -E "s/[0-9]+ seconds//; s/pid [0-9]+ pgid [0-9]+//"; fi
  done | sort
  echo "http /: $(curl -s -o /dev/null -w %{http_code} http://localhost:8080/)"
  echo "http aircraft.json: $(curl -s -o /dev/null -w %{http_code} http://localhost:8080/data/aircraft.json)"
' 2>&1
echo "### log problems"
docker logs "$name" 2>&1 | grep -iE "cannot execute|required file not found|error while loading shared|Illegal instruction|Segmentation fault|exec format error|No such file or directory|command not found" \
  | sed -E 's/\x1b\[[0-9;]*m//g; s/^[0-9T:.Z-]+ [0-9a-f]+ //; s/[0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9:.]+//g' | sort | uniq -c | sort -rn | head -15
docker rm -f "$name" >/dev/null
