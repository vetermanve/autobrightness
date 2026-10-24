# autobrightness

Make external monitors follow room light on macOS.

macOS adjusts the built-in display automatically and offers True Tone, but most
third-party monitors get neither — the True Tone checkbox simply does not appear
for them. This keeps them in step instead: it reads the built-in display's
brightness, which already tracks ambient light, and drives external monitors to
match over DDC/CI, or through the gamma table when DDC is unavailable.

## What this is not

**This is not True Tone.** Apple measures the room's colour *temperature* with a
multi-channel ambient sensor and does not expose that reading. The sensor appears
in the IORegistry as an `AppleSPUHIDInterface` behind the AOP coprocessor and
publishes only IOReport packet counters — no lux, no chromaticity.

So this uses ambient *level* only: a brighter room means brighter and more
neutral, a darker room means dimmer and warmer. Under a tungsten lamp and under
daylight of the same intensity it behaves identically. True Tone would not.

## Requirements

- Apple Silicon Mac with a built-in display, auto-brightness enabled
- Xcode command line tools (`swiftc`)
- [`m1ddc`](https://github.com/waydabber/m1ddc) — `brew install m1ddc`

## Install

```sh
git clone https://github.com/vetermanve/autobrightness
cd autobrightness
./install.sh
```

Two small Swift helpers are compiled and three commands are symlinked into
`~/.local/bin`. Nothing is written outside your home directory, no `sudo`.

## Which monitors can be driven

Run `display-check` and look at `max luminance`:

- **`max luminance = 100`** — DDC works. The backlight itself is controlled.
- **`max luminance = 0`** — the monitor does not answer DDC. Use the gamma
  fallback described below.

Two things commonly break DDC, both worth checking before giving up:

1. **The monitor's own DDC/CI switch.** Dell and others hide it under
   `Menu > Others > DDC/CI`. Without it nothing works.
2. **The connection.** DDC over the built-in HDMI port of an Apple Silicon Mac
   has been broken since M1 and still is. The same panel on USB-C/DisplayPort
   usually answers fine. Cheap USB-C hubs and HDMI adapters also strip DDC.

## Configure

Find your monitors' names with `m1ddc display list`, then write
`~/.config/autobrightness/config`:

```sh
DISPLAYS=(
  "CR270ST:0:90:38:50"
  "HP P24h G4:10:85::"
  "DELL E2420HS:25:100:::gamma"
)
```

Each entry is `name:lum_min:lum_max:blue_min:blue_max[:mode]`.

- `name` — any substring matching the `m1ddc display list` output
- `lum_min` / `lum_max` — monitor brightness at the dark and bright ends
- `blue_min` / `blue_max` — blue gain, 50 is neutral, lower is warmer.
  **Leave both empty** when the monitor has no RGB gain control.
- `mode` — `ddc` (default) or `gamma`

The solar model needs to know where you are, in degrees, north and east
positive:

```sh
SOLAR_LAT=55.7558
SOLAR_LON=37.6176
```

The menu bar app fills these in for you: "Use my time zone" reads the position
macOS already ships for your zone in `/usr/share/zoneinfo/zone.tab` - no prompt,
no network - and "Use my location" asks CoreLocation, which an ad-hoc signed app
does not reliably get permission for. Either way the numbers stay editable: the
zone's position is its reference city, and the sun's elevation is bucketed in
five degree steps, so a city is close enough.

Without coordinates the model stays off and a closed lid falls back to holding
the last reading.

Check the mapping before trusting it:

```sh
autobrightness curve
```

Calibrate in both extremes — in daylight and in a dark room — and adjust the pair
of numbers for the end that looks wrong. Set brightness first: a luminance
mismatch between screens reads as a colour mismatch, and chasing white point
before brightness is chasing a ghost.

## With the lid shut

The built-in display is the sensor here, and closing the lid turns it off. The
ambient sensor itself is no help either: it sits in the lid, next to the camera,
and with the lid shut it faces the keyboard. **A clamshelled Mac has no reading
of the room at all** - not a worse one, none.

Three things went wrong before this was handled explicitly, all of them visible
in the log:

```
23:54:40 HP P24h G4: 66/- -> 10/-  (builtin 0.0000)
23:54:40 CR270ST:    55/45 -> 0/38 (builtin 0.0000)
00:52:11 CR270ST:    0/38 -> 90/50 (builtin 0.9375)
```

A panel whose backlight is off reports zero nits, and zero nits read as a pitch
dark room, so the monitors were driven to the floor as the lid came down and back
to daylight when it opened. In between, the agent died every five seconds on the
missing display - which is the only reason the monitors stayed put at all.

So ambient is now resolved through a chain, and every link says what it is:

| Source | What it is |
|---|---|
| `manual` | a level set by hand, from the menu bar app or `autobrightness manual`. An instruction, so it outranks every sensor until cleared |
| `sensor` | `AMBIENT_CMD`, an external meter printing nits. Nothing ships with one - see `docs/ideas.md` |
| `als` | the built-in display's luminance, the only real measurement available |
| `solar` | this machine's own `als` history, replayed for the sun's current elevation |
| `hold` | the last trusted reading, when the model has nothing for this hour |

Two rules keep the bad readings out. **Zero nits is not a dark room** - it is a
dark backlight, and it is refused. And a panel that has just woken is not trusted
for `WAKE_SETTLE` seconds: macOS restores the pre-sleep brightness first and
auto-brightness corrects it a moment later, so the first readings after a lid
opens describe the room the Mac went to sleep in.

If nothing in the chain can speak, the monitors are left exactly where they are.

### What the solar model actually is

Not a curve someone invented. While the lid is open the agent is already reading
real luminance every few seconds, so it buckets those readings by the sun's
elevation - 5 degrees per bucket, 36 buckets from horizon to horizon - and keeps
a running mean per bucket. With the lid shut it looks up the bucket for the
current elevation and replays what this machine measured there.

That makes it a model of your habits as much as of the daylight: the buckets
below the horizon are lamplight, and they learn what you actually set in the
evening. The first `MODEL_MEAN_OVER` samples in a bucket form a plain mean;
after that it becomes an EWMA with the same time constant, so a bucket settles on
the habit across days rather than on the last visit. A bucket nobody has visited
for `MODEL_FORGET_DAYS` is replaced outright - the season moved, or the lamps did.

```sh
autobrightness model     # what each bucket has learned
autobrightness ambient   # which source is answering right now, and why
autobrightness sun       # the sun's elevation, for checking against an almanac
```

Sun position is the low-precision NOAA formulation, good to about 0.01 degrees -
three orders of magnitude finer than a bucket. It is checked against the equinox
day length at three latitudes, the solstice noon elevation at the equator, and
polar night: `tests/ambient-chain.test.sh`.

### What it will never be

The model replays a typical day. It cannot know that today is overcast, or that
you turned a lamp on. For that there has to be a meter that can see the room with
the lid shut, which means hardware - `AMBIENT_CMD` is the hook, and
`docs/ideas.md` lists what fits.

## Why it matches by luminance, not by percentage

The built-in display's brightness slider is badly nonlinear in actual light
output. Measured on a 14" M-series XDR by reading `IOMFBBrightnessLevel` out of
the IORegistry while sweeping the slider:

```
slider |  nits  | share of max | a linear map would say
  0.05 |    1.0 |        0.2 % |                 20 nits
  0.10 |    1.5 |        0.4 % |                 40 nits
  0.20 |    4.7 |        1.2 % |                 80 nits
  0.30 |   14.6 |        3.7 % |                120 nits
  0.40 |   45.2 |       11.3 % |                160 nits
  0.50 |  140.0 |       35.0 % |                200 nits
  0.70 |  202.5 |       50.6 % |                280 nits
  1.00 |  400.2 |      100.0 % |                400 nits
```

At slider 0.10 the panel is at **1.5 nits**. Mapping that percentage straight
onto a 300-nit monitor puts it near 45 nits — thirty times too bright, and very
obvious in a dark room.

So `MATCH=nits` (the default) reads the built-in's real luminance and converts:

```
ddc_target = 100 * builtin_nits / panel_nits
```

clamped into the configured `lum_min`..`lum_max` window. Set each panel's peak
luminance in `DISPLAY_NITS`; the spec sheet figure is close enough, and
`display-check` prints the value the EDID declares.

`MATCH=slider` restores the old linear map between `B_LO` and `B_HI` if you want
to shape the response by hand instead.

## The gamma fallback

For monitors that do not answer DDC, `mode: gamma` dims through the display's
gamma table instead. This is a fallback, not an equal:

| | DDC | gamma |
|---|---|---|
| what changes | backlight current | the signal into the panel |
| black level | drops with white | stays exactly where it was |
| contrast | preserved | falls |
| backlight life, power | saved | not saved |
| tonal steps | all present | banding when dimmed hard |

Keep `lum_min` around 20 for gamma displays; below that the picture turns muddy
and starts to band. That floor is also the limit of how dark a software-dimmed
panel can go, so it will stay brighter than its DDC neighbours in a dark room.

**Set the monitor's own brightness to maximum and leave it there.** The gamma
table can only take light away, so every point of hardware brightness you give up
is cut off the top of its range - and silently, because nothing in software can
see that setting. A panel found at OSD brightness 75 cost an hour here: it looked
like a weak backlight, and the measured "panel peak" would have been a ceiling
invented by a slider rather than anything physical.

**Measure the peak, do not trust the spec sheet.** Set the gamma display to its
full output, then dim a DDC-controlled monitor next to it until the two match;
the DDC monitor's luminance at that point is the real peak. A six-year-old panel
rated 250 nits measured 140 here. Feeding the paper figure into `DISPLAY_NITS`
makes the conversion ask for roughly half the light it should, which looks exactly
like the bug this whole mechanism exists to fix.

macOS reverts a gamma table the moment the process that set it exits, so gamma
displays cannot be served by a periodic one-shot. `autobrightness install` writes
a second launchd agent with `KeepAlive` that stays resident and owns the gamma.
It also re-applies after a display reconfiguration drops the table.

That daemon takes no readings of its own. The tick resolves ambient once and
leaves the result in `~/.local/state/autobrightness.ambient`; the daemon reads
that file and holds its last level when the file goes stale. Two independent
readers of the same sensor disagreed in exactly the case that matters: with the
lid shut the agent held its last value while the daemon saw zero nits and drove
to the floor.

## Run

```sh
autobrightness install      # load the launchd agents
autobrightness status       # ambient source, targets, current values
autobrightness ambient      # which source is answering, how old it is
autobrightness model        # what the solar model has learned
autobrightness sun [epoch]  # the sun's elevation here
autobrightness curve        # full mapping table
autobrightness once         # apply right now
autobrightness manual 40    # hold 40 nits worth of room light, whatever the sensors say
autobrightness manual off   # back to automatic
autobrightness pause        # stop interfering so you can adjust by hand
autobrightness resume
autobrightness uninstall
```

A gauge in the menu bar shows which source is answering and lets you set a level
by hand without a terminal: `macos/README.md`.


Manual white point and brightness, for calibration:

```sh
ddc-tune -d CR270ST show
ddc-tune -d CR270ST bright 60
ddc-tune -d CR270ST warm 5     # lower blue gain
ddc-tune -d CR270ST cool 5     # lower red gain
ddc-tune -d CR270ST reset      # back to 50/50/50
```

Monitor acceptance report — what a panel really is, as opposed to what its
listing claimed:

```sh
display-check
```

It decodes the EDID (bit depth, physical size, native timing, declared HDR and
peak luminance, white point), shows EDR headroom and lists the HiDPI modes macOS
offers for each display.

## How it works

Reading the built-in display's brightness costs about 9 ms and touches no DDC, so
the agent can poll often. The last applied value is cached per monitor; when the
target has not moved, a tick exits in under 50 ms without a single DDC
transaction.

Every 2nd tick the cache is bypassed and the monitors are re-read, which catches
changes made through the monitor's own OSD. That read is what bounds how long a
manual adjustment survives: 10 seconds here. Raising `RESYNC_EVERY` stretches
that window and buys very little — a read costs about 63 ms, so checking two
monitors every 10 seconds is a bit over one percent of bus time.

One DDC write costs about 63 ms on the hardware this was built against, and that
is what paces the ramp. Transitions step in single DDC units — the finest the
protocol allows — which works out to roughly 16 updates per second. The ramp is
deliberately linear: with one-unit steps, easing the acceleration would have to
skip values through the middle of the move, reintroducing exactly the stutter it
was meant to remove.

**The target is recomputed mid-ramp**, every 8 units of travel, from a fresh
ambient reading. Without that the agent drives toward a target that went stale
while it was moving, arrives, and only then notices — which reads as chasing
rather than tracking, and is very visible while you drag the brightness slider.

Small drifts of 4 units or less skip the ramp and are written directly, because
most ticks are slow auto-brightness drift and spending two dozen transactions on
them would load the I2C bus for nothing. Monitors are driven in parallel so they
move together.

A luminance read of zero from a panel whose `max luminance` is 100 means the I2C
transaction collided with a write in flight, not that the monitor is at zero. The
agent falls back to its cache in that case; taking the zero at face value makes it
ramp from the wrong starting point. The same guard covers `m1ddc` printing its
errors on stdout: `Could not find a suitable external display.` arrives where a
number should be, and as a number it is zero.

Displays are resolved by UUID, not by the position they happen to hold in a list.
`NSScreen.screens` is a per-process snapshot that refreshes only when an app's run
loop handles a display-reconfiguration notification, so in a daemon it goes stale
the first time a monitor sleeps - and `CGSetDisplayTransferByTable` reports no
error for an id that no longer exists. A gamma daemon here spent thirteen days
believing it was dimming a display. The agent writes a uuid-to-name map each tick
and the daemon looks the id up live.

## Limitations

- Ambient level only, not colour temperature. See above.
- DDC brightness resolution is 1/100 of the range. Near the dark end a single
  step is a larger relative change than near the bright end.
- A monitor's RGB gain control is often absent even when brightness works.
- If you change brightness behind the agent's back it will not notice until the
  next resync tick, by design — so it does not fight you mid-adjustment.
- With the lid shut nothing measures the room. The solar model replays a typical
  day at that sun elevation; it cannot see an overcast afternoon or a lamp being
  switched on. See `docs/ideas.md` for the hardware that would.

## License

MIT
