#!/bin/bash
# Tests for the ambient source chain: which source wins, what each one refuses,
# and what the solar model learns and predicts.
#
# Everything runs against a throwaway state directory and a stub brightness
# reader, so the live agent - which ticks every five seconds - is untouched and
# no DDC traffic is generated.
#
#   tests/ambient-chain.test.sh
set -u
export LC_ALL=C

HERE="$(cd "$(dirname "$0")" && pwd)"
AB="$HERE/../bin/autobrightness"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export AUTOBRIGHTNESS_STATE="$TMP/state"
export AUTOBRIGHTNESS_CONFIG="$TMP/config"
export AUTOBRIGHTNESS_BB="$TMP/bb"
mkdir -p "$AUTOBRIGHTNESS_STATE"

pass=0; fail=0
ok() { pass=$(( pass + 1 )); printf '  ok   %s\n' "$1"; }
no() { fail=$(( fail + 1 )); printf '  FAIL %s\n       expected %s\n       actual   %s\n' "$1" "$2" "$3"; }
is() { # name expected actual
    if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "$2" "$3"; fi
}
near() { # name expected actual tolerance
    if awk -v a="$2" -v b="$3" -v t="$4" 'BEGIN{d=a-b; if(d<0)d=-d; exit !(d <= t)}'; then
        ok "$1"
    else no "$1" "$2 (+-$4)" "$3"; fi
}

# A stub for the built-in display reader. "off" makes it behave like a panel
# whose backlight is off: readable slider, zero nits - what a shut lid gives.
stub_bb() { # slider nits | off | fail
    case "$1" in
      off)  printf '#!/bin/sh\necho "0.5822 0.0 1600.0"\n' > "$AUTOBRIGHTNESS_BB" ;;
      fail) printf '#!/bin/sh\necho "no built-in display with readable brightness" >&2\nexit 1\n' > "$AUTOBRIGHTNESS_BB" ;;
      *)    printf '#!/bin/sh\necho "%s %s 1600.0"\n' "$1" "$2" > "$AUTOBRIGHTNESS_BB" ;;
    esac
    chmod +x "$AUTOBRIGHTNESS_BB"
}
config() { # extra lines
    {
        echo 'DISPLAYS=("TESTDISP:10:90::")'
        echo 'DISPLAY_NITS=("TESTDISP:250")'
        echo 'SOLAR_LAT=55.7558'
        echo 'SOLAR_LON=37.6176'
        cat
    } > "$AUTOBRIGHTNESS_CONFIG"
}
reset() { rm -rf "$AUTOBRIGHTNESS_STATE"; mkdir -p "$AUTOBRIGHTNESS_STATE"; }
field() { "$AB" ambient | awk -v k="$1" '$1 == k { print $2 }'; }
now() { date +%s; }

echo "TC-1: no source at all says so, instead of guessing"
reset; config </dev/null; stub_bb fail
is "source is none"  "none" "$(field source)"
is "no nits"         "none" "$(field nits)"

echo "TC-2: the last trusted reading is held when the panel goes dark"
reset; config </dev/null; stub_bb off
echo "137.5 0.6 $(( $(now) - 300 ))" > "$AUTOBRIGHTNESS_STATE/autobrightness.live"
is "source is hold"  "hold"  "$(field source)"
is "nits held"       "137.5" "$(field nits)"
near "age is the file's" 300 "$("$AB" ambient | awk '$1=="age"{sub(/s$/,"",$2); print $2}')" 2

echo "TC-3: a hand-set level outranks a live panel"
reset; config </dev/null; stub_bb 0.80 300.0
echo "42 $(now)" > "$AUTOBRIGHTNESS_STATE/autobrightness.manual"
is "source is manual" "manual" "$(field source)"
is "nits from manual" "42"     "$(field nits)"

echo "TC-4: an external meter outranks the panel, and junk from it is refused"
reset; config <<'CFG'
AMBIENT_CMD='echo 88.5'
CFG
stub_bb 0.80 300.0
is "source is sensor" "sensor" "$(field source)"
is "nits from sensor" "88.5"   "$(field nits)"
reset; config <<'CFG'
WAKE_SETTLE=0
AMBIENT_CMD='echo "Could not find a suitable external display."'
CFG
stub_bb 0.80 300.0
is "junk falls through to the panel" "als" "$(field source)"
reset; config <<'CFG'
WAKE_SETTLE=0
AMBIENT_CMD='exit 7'
CFG
stub_bb 0.80 300.0
is "a failing meter falls through"   "als" "$(field source)"

echo "TC-5: a panel that just woke is not trusted until it settles"
reset; config <<'CFG'
WAKE_SETTLE=30
CFG
stub_bb off
echo "137.5 0.6 $(( $(now) - 300 ))" > "$AUTOBRIGHTNESS_STATE/autobrightness.live"
field source >/dev/null                      # records the off phase
stub_bb 0.95 390.0                           # lid opens, panel comes back bright
is "held during the settle window" "hold" "$(field source)"
is "and the held value is used"    "137.5" "$(field nits)"
# backdate the phase file: the settle window has now passed
echo "als $(( $(now) - 31 ))" > "$AUTOBRIGHTNESS_STATE/autobrightness.phase"
is "trusted once settled"          "als"   "$(field source)"
is "nits from the panel"           "390.0" "$(field nits)"

echo "TC-6: zero nits is a dark backlight, not a dark room"
reset; config <<'CFG'
WAKE_SETTLE=0
CFG
stub_bb off
echo "137.5 0.6 $(( $(now) - 300 ))" > "$AUTOBRIGHTNESS_STATE/autobrightness.live"
is "zero is refused" "hold" "$(field source)"
stub_bb 0.05 1.0
is "one nit is a reading" "als" "$(field source)"

echo "TC-7: the solar model answers for a bucket it has measured"
reset; config <<'CFG'
WAKE_SETTLE=0
CFG
stub_bb off
bin=$(awk -v e="$("$AB" sun)" 'BEGIN{print int((e + 90) / 5)}')
echo "$bin 61.0 40 $(now)" > "$AUTOBRIGHTNESS_STATE/autobrightness.solar"
is "source is solar" "solar" "$(field source)"
is "nits from the bucket" "61.0" "$(field nits)"

echo "TC-8: a bucket with no data is interpolated from its neighbours"
reset; config <<'CFG'
WAKE_SETTLE=0
CFG
stub_bb off
bin=$(awk -v e="$("$AB" sun)" 'BEGIN{print int((e + 90) / 5)}')
{ echo "$(( bin - 2 )) 20.0 10 $(now)"; echo "$(( bin + 2 )) 60.0 10 $(now)"; } \
    > "$AUTOBRIGHTNESS_STATE/autobrightness.solar"
is "halfway between the two"  "40.0" "$(field nits)"
# one side only: hold it flat rather than extrapolate off the end of the data
echo "$(( bin + 3 )) 72.0 10 $(now)" > "$AUTOBRIGHTNESS_STATE/autobrightness.solar"
is "nearest bucket, held flat" "72.0" "$(field nits)"
# beyond the search span the model has nothing to say
echo "$(( bin + 5 )) 72.0 10 $(now)" > "$AUTOBRIGHTNESS_STATE/autobrightness.solar"
echo "137.5 0.6 $(now)" > "$AUTOBRIGHTNESS_STATE/autobrightness.live"
is "too far away, falls to hold" "hold" "$(field source)"

echo "TC-9: without coordinates the model is off entirely"
reset
{ echo 'DISPLAYS=("TESTDISP:10:90::")'; echo 'DISPLAY_NITS=("TESTDISP:250")'; echo 'WAKE_SETTLE=0'; } \
    > "$AUTOBRIGHTNESS_CONFIG"
stub_bb off
echo "137.5 0.6 $(now)" > "$AUTOBRIGHTNESS_STATE/autobrightness.live"
is "falls through to hold" "hold" "$(field source)"

echo "TC-10: the model learns from live readings and averages the bucket"
reset; config <<'CFG'
WAKE_SETTLE=0
SAMPLE_EVERY=0
CFG
bin=$(awk -v e="$("$AB" sun)" 'BEGIN{print int((e + 90) / 5)}')
stub_bb 0.80 200.0
field source >/dev/null
is "the bucket exists after one sample" "200.0" \
   "$(awk -v b="$bin" '$1 == b { print $2 }' "$AUTOBRIGHTNESS_STATE/autobrightness.solar")"
stub_bb 0.80 100.0
field source >/dev/null
near "two samples average" 150.0 \
   "$(awk -v b="$bin" '$1 == b { print $2 }' "$AUTOBRIGHTNESS_STATE/autobrightness.solar")" 0.1
is "sample count kept" "2" \
   "$(awk -v b="$bin" '$1 == b { print $3 }' "$AUTOBRIGHTNESS_STATE/autobrightness.solar")"

echo "TC-11: a bucket nobody has visited for a month is replaced, not blended"
reset; config <<'CFG'
WAKE_SETTLE=0
SAMPLE_EVERY=0
MODEL_FORGET_DAYS=30
CFG
bin=$(awk -v e="$("$AB" sun)" 'BEGIN{print int((e + 90) / 5)}')
stub_bb 0.80 200.0
echo "$bin 12.0 40 $(( $(now) - 40 * 86400 ))" > "$AUTOBRIGHTNESS_STATE/autobrightness.solar"
field source >/dev/null
is "replaced outright" "200.0" \
   "$(awk -v b="$bin" '$1 == b { print $2 }' "$AUTOBRIGHTNESS_STATE/autobrightness.solar")"
is "count restarts"    "1" \
   "$(awk -v b="$bin" '$1 == b { print $3 }' "$AUTOBRIGHTNESS_STATE/autobrightness.solar")"

echo "TC-12: HOLD_MAX_AGE gives up on a reading that is too old"
reset; config <<'CFG'
WAKE_SETTLE=0
HOLD_MAX_AGE=600
CFG
stub_bb off
echo "137.5 0.6 $(( $(now) - 1200 ))" > "$AUTOBRIGHTNESS_STATE/autobrightness.live"
is "stale hold is refused" "none" "$(field source)"
echo "137.5 0.6 $(( $(now) - 60 ))" > "$AUTOBRIGHTNESS_STATE/autobrightness.live"
is "fresh hold is used"    "hold" "$(field source)"

echo "TC-13: a non-numeric manual level is refused outright"
reset; config </dev/null; stub_bb fail
out=$("$AB" manual "Could not find a suitable external display." 2>&1); rc=$?
is "exits non-zero" "1" "$rc"
case "$out" in *usage*) ok "says what it wanted";; *) no "says what it wanted" "usage line" "$out";; esac
is "nothing written" "manual off" "$("$AB" manual show)"

echo "TC-14: the indicator stays valid JSON in every state"
for state in none hold manual; do
    reset; config </dev/null; stub_bb off
    case "$state" in
      hold)   echo "137.5 0.6 $(now)" > "$AUTOBRIGHTNESS_STATE/autobrightness.live" ;;
      manual) echo "42 $(now)" > "$AUTOBRIGHTNESS_STATE/autobrightness.manual" ;;
    esac
    if "$AB" --indicator | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
        ok "valid JSON with source $state"
    else
        no "valid JSON with source $state" "parseable" "$("$AB" --indicator)"
    fi
done

echo "TC-15: solar elevation against facts the almanac fixes"
eq() { TZ=UTC date -j -f '%Y-%m-%d %H:%M:%S' "$1" +%s; }
at() { # lat lon epoch -> degrees, through the script itself
    reset
    { echo 'DISPLAYS=("TESTDISP:10:90::")'; echo 'DISPLAY_NITS=("TESTDISP:250")'
      echo "SOLAR_LAT=$1"; echo "SOLAR_LON=$2"; } > "$AUTOBRIGHTNESS_CONFIG"
    "$AB" sun "$3"
}
near "equator noon at the December solstice" 66.56 \
     "$(at 0 0 "$(eq '2026-12-21 12:00:00')")" 0.1
near "the tropic of Capricorn has it overhead" 90.0 \
     "$(at -23.44 0 "$(eq '2026-12-21 12:00:00')")" 0.5
near "Moscow solar noon today stays low" 22.3 \
     "$(at 55.7558 37.6176 "$(eq '2026-10-24 09:13:00')")" 0.5
# at solar midnight the sun sits at dec - (90 - lat): -12.0 - 34.24 degrees
near "and sinks to dec-(90-lat) at solar midnight" -46.2 \
     "$(at 55.7558 37.6176 "$(eq '2026-10-24 21:13:00')")" 0.5
reset
{ echo 'DISPLAYS=("TESTDISP:10:90::")'; echo 'DISPLAY_NITS=("TESTDISP:250")'; } \
    > "$AUTOBRIGHTNESS_CONFIG"
out=$("$AB" sun 2>&1); rc=$?
is "without coordinates it refuses to invent a sky" "1" "$rc"

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
