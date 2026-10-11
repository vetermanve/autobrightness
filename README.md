# autocontrast

Make external monitors follow room light on macOS.

macOS adjusts the built-in display automatically and offers True Tone, but most
third-party monitors get neither — the True Tone checkbox simply does not appear
for them. This keeps them in step instead: it reads the built-in display's
brightness, which already tracks ambient light, and drives external monitors over
DDC/CI to match.

## What this is not

**This is not True Tone.** Apple measures the room's colour *temperature* with a
multi-channel ambient sensor and does not expose that reading. The sensor shows up
in the IORegistry as an `AppleSPUHIDInterface` behind the AOP coprocessor and
publishes only IOReport packet counters — no lux, no chromaticity.

So this uses ambient *level* only: a brighter room means brighter and more neutral,
a darker room means dimmer and warmer. Under a tungsten lamp and under daylight of
the same intensity it behaves identically. True Tone would not.

## Requirements

- Apple Silicon Mac with a built-in display, auto-brightness enabled
- macOS with Xcode command line tools (`swiftc`)
- [`m1ddc`](https://github.com/waydabber/m1ddc) — `brew install m1ddc`
- External monitors that answer DDC/CI. Many do not: check with `display-check`.
  A monitor reporting `max luminance = 0` cannot be driven.
- DisplayPort or USB-C works more reliably than HDMI for DDC on Apple Silicon.

## Install

```sh
git clone https://github.com/vetermanve/autocontrast
cd autocontrast
./install.sh
```

This compiles one small Swift helper and symlinks three commands into
`~/.local/bin`. Nothing is written outside your home directory and no `sudo` is used.

## Configure

Find your monitors' names:

```sh
m1ddc display list
```

Then write `~/.config/autocontrast/config`:

```sh
DISPLAYS=(
  "CR270ST:15:90:38:50"
  "HP P24h G4:10:85::"
)
```

Each entry is `name:lum_min:lum_max:blue_min:blue_max`.

- `name` — any substring that matches the `m1ddc display list` output
- `lum_min` / `lum_max` — monitor brightness at the dark and bright ends
- `blue_min` / `blue_max` — blue gain, where 50 is neutral and lower is warmer.
  **Leave both empty** if the monitor has no RGB gain control; brightness only.

Check the mapping before trusting it:

```sh
autocontrast curve
```

Calibrate in both extremes — in daylight and in a dark room — and adjust the
pair of numbers for the end that looks wrong. Set brightness first: a luminance
mismatch between screens reads as a colour mismatch, and chasing white point
before brightness is chasing a ghost.

## Run

```sh
autocontrast install      # load the launchd agent, polls every 10s
autocontrast status       # built-in brightness, targets, current values
autocontrast curve        # full mapping table
autocontrast once         # apply right now
autocontrast pause        # stop interfering so you can adjust by hand
autocontrast resume
autocontrast uninstall
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
target has not moved, the tick exits in under 50 ms without a single DDC
transaction. Every 18th tick the cache is bypassed and the monitors are re-read,
which catches changes made through the monitor's own OSD.

One DDC write costs about 63 ms on the hardware this was built against, and that
is what paces the ramp. Transitions step in single DDC units — the finest the
protocol allows — which works out to roughly 16 updates per second. The ramp is
deliberately linear: with one-unit steps, easing the acceleration would have to
skip values through the middle of the move, reintroducing exactly the stutter it
was meant to remove.

Small drifts (4 units or less) skip the ramp and are written directly, because
most ticks are slow auto-brightness drift and spending two dozen transactions on
them would load the I2C bus for nothing. Monitors are driven in parallel so they
move together.

## Limitations

- Ambient level only, not colour temperature. See above.
- DDC brightness resolution is 1/100 of the range. Near the dark end a single
  step is a larger relative change than near the bright end.
- Monitors without DDC/CI brightness cannot be driven at all.
- A monitor's RGB gain control is often absent even when brightness works.
- If you change brightness behind the agent's back it will not notice until the
  next resync tick, by design — so it does not fight you mid-adjustment.

## License

MIT
