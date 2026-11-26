#!/usr/bin/env bash
# =============================================================================
# maps_monthly.sh: keep the Protomaps planet and its smaller world cuts here.
#
# Once a month (maps-monthly.timer) it downloads the newest daily planet build
# (build.protomaps.com, about 140 GB), checks it against the size and MD5 that
# build-metadata.protomaps.dev lists, and cuts the world at zoom 0..6, 0..8 and
# 0..10 from it (pmtiles_zoom_cut.py). Files are dated; `planet.pmtiles` and
# `world-zN.pmtiles` name the newest. One planet at a time: the disk cannot
# hold two, so the old planet goes when a new download starts (the cuts stay).
#
# Resume: the download is `<key>.part` with the build it is for in
# `.<key>.want` (hidden: the folder is shared, and the server never
# publishes a dotfile or a `.part`). Every run (monthly, at boot, after a failure) carries on from
# the bytes already there (`curl -C -`), retrying until the size is reached.
# A build Protomaps no longer serves is dropped for the newest one.
#
#   maps_monthly.sh            # run now (does nothing when the planet is fresh)
#   MAPS_DIR=/srv/maps    # where the files live
# =============================================================================
set -euo pipefail
DIR=${MAPS_DIR:-/srv/maps}
TOOL=${MAPS_TOOL:-$DIR/bin/pmtiles_zoom_cut.py}
META=${MAPS_META:-https://build-metadata.protomaps.dev/builds.json}
BASE=${MAPS_BASE:-https://build.protomaps.com}
UA=pmtiles-reader
MAX_AGE_DAYS=28
SPARE=$(( ${MAPS_SPARE_GB:-8} * 1000000000 ))
ZOOMS="6 8 10"
cd "$DIR"
exec 9>.lock
flock -n 9 || { echo "another run is busy"; exit 0; }
log() { echo "$(date '+%F %T') $*"; }

builds=$(curl -fsS -A "$UA" --retry 5 --retry-delay 30 "$META")
field() { # field <key> <name>: from the build list
  python3 -I -c 'import json,sys
for b in json.loads(sys.stdin.read()):
    if b["key"]==sys.argv[1]: print(b.get(sys.argv[2],"")); break' "$1" "$2" <<<"$builds"; }
newest=$(python3 -I -c 'import json,sys
print(sorted(json.loads(sys.stdin.read()),key=lambda b:b["key"])[-1]["key"])' <<<"$builds")

# A download under way: go on with it while Protomaps still serves it.
key=""
for w in .*.want; do
  [[ -e "$w" ]] || break
  k=${w#.}; k=${k%.want}
  if [[ -n "$(field "$k" size)" ]]; then key=$k; else
    log "build $k is no longer served: dropping its partial download"
    rm -f "$k.part" "$w"
  fi
done

if [[ -z "$key" ]]; then
  if [[ -e planet.pmtiles ]]; then
    age=$(( ( $(date +%s) - $(stat -L -c %Y planet.pmtiles) ) / 86400 ))
    if (( age < MAX_AGE_DAYS )); then
      log "planet is $age days old (newest build $newest): nothing to do"
      exit 0
    fi
  fi
  key=$newest
  echo "$key" > ".$key.want"
  # Room for the new planet: the old one goes first (the cuts stay).
  for p in planet-*.pmtiles; do [[ -e "$p" ]] && { log "removing old $p"; rm -f "$p"; }; done
fi

size=$(field "$key" size)
md5=$(field "$key" md5sum)
part="$key.part"
have=$(stat -c %s "$part" 2>/dev/null || echo 0)
free=$(df --output=avail -B1 . | tail -1)
if (( size - have + SPARE > free )); then
  log "not enough room: need $(( (size - have) / 1000000000 )) GB plus $(( SPARE / 1000000000 )) GB spare, have $(( free / 1000000000 )) GB"
  exit 2   # not retried by the service: a person has to make room
fi

log "planet $key: $(( have / 1000000000 )) of $(( size / 1000000000 )) GB here"
tries=0
while (( have < size )); do
  tries=$(( tries + 1 ))
  (( tries > 500 )) && { log "giving up for now after $tries attempts"; exit 1; }
  # No --retry here: on a retry curl truncates the file back to where this
  # curl started (it lost 75 GB once). Each pass of this loop is a fresh `-C -`.
  curl -fsS --http1.1 -A "$UA" ${MAPS_CURL_EXTRA:-} -C - \
       --speed-limit 20000 --speed-time 300 -o "$part" "$BASE/$key" && rc=0 || rc=$?
  # 33: the server would not resume (no ranges): that copy starts over.
  (( rc == 33 )) && { log "the server cannot resume this download: starting it over"; rm -f "$part"; }
  have=$(stat -c %s "$part" 2>/dev/null || echo 0)
  (( have < size )) && { log "interrupted at $(( have / 1000000000 )) GB; resuming in ${MAPS_PAUSE:-60} s"; sleep ${MAPS_PAUSE:-60}; }
done
if (( have != size )); then
  log "size $have is not the listed $size: starting over"
  rm -f "$part"; exit 1
fi
if [[ -n "$md5" ]]; then
  log "checking MD5"
  got=$(md5sum "$part" | cut -d' ' -f1 | python3 -I -c 'import base64,sys;print(base64.b64encode(bytes.fromhex(sys.stdin.read().strip())).decode())')
  if [[ "$got" != "$md5" ]]; then
    log "MD5 differs ($got, listed $md5): starting over"
    rm -f "$part"; exit 1
  fi
fi
mv "$part" "planet-$key"
rm -f ".$key.want"
ln -sfn "planet-$key" planet.pmtiles
log "planet $key in place"

day=${key%.pmtiles}
for z in $ZOOMS; do
  out="world-z$z-$day.pmtiles"
  [[ -e "$out" ]] || nice -n 19 ionice -c3 python3 -I "$TOOL" "planet-$key" "$out" "$z"
  ln -sfn "$out" "world-z$z.pmtiles"
  for old in world-z$z-*.pmtiles; do [[ "$old" == "$out" ]] || rm -f "$old"; done
done
log "done: $(ls -1 *.pmtiles | tr '\n' ' ')"
