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

Check the mapping before trusting it:

```sh
autobrightness curve
```

Calibrate in both extremes — in daylight and in a dark room — and adjust the pair
of numbers for the end that looks wrong. Set brightness first: a luminance
mismatch between screens reads as a colour mismatch, and chasing white point
before brightness is chasing a ghost.

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

## Run

```sh
autobrightness install      # load the launchd agents
autobrightness status       # built-in brightness, targets, current values
autobrightness curve        # full mapping table
autobrightness once         # apply right now
autobrightness pause        # stop interfering so you can adjust by hand
autobrightness resume
autobrightness uninstall
```

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
ramp from the wrong starting point.

## Limitations

- Ambient level only, not colour temperature. See above.
- DDC brightness resolution is 1/100 of the range. Near the dark end a single
  step is a larger relative change than near the bright end.
- A monitor's RGB gain control is often absent even when brightness works.
- If you change brightness behind the agent's back it will not notice until the
  next resync tick, by design — so it does not fight you mid-adjustment.

## License

MIT
