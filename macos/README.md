# Gauge in the menu bar

One ring next to the clock, answering the two questions a closed lid raises:
what level is being applied, and whether anything actually measured it.

All numbers come from `autobrightness --indicator`; the app has no opinion of its
own about light. It sends back only the three commands worth having in a hurry -
a level by hand, pause, resume.

## Reading the gauge

| Channel | What it encodes |
| --- | --- |
| Arc length | where the ambient value sits on the nits scale, logarithmic from 1 to 400 |
| Filled centre dot | a sensor is reporting the room right now |
| Hollow centre ring | the solar model is reconstructing it |
| Broken arc, no centre | the last reading, held, with nothing checking it |
| Centre square | a level set by hand, which outranks every sensor |
| Bare track | no source at all; the monitors are left alone |
| Slash | paused |

The distinction the gauge exists for is measured against modelled. A faint arc
was not enough on its own - at eighteen pixels it sat too close to the track - so
a held reading breaks the arc instead of only fading it.

The scale is logarithmic because luminance is. The built-in panel runs from about
one nit in a dark room to several hundred in daylight, and on a linear scale the
whole evening range, where a mismatch between screens is most visible, would be
squeezed into the first few percent of the arc.

## Build and run

```sh
swift build -c release
.build/release/AutoBrightnessBar &
```

That works for a look at it, but the bundle is worth building: without an
`Info.plist` the system does not treat the binary as an application, and
CoreLocation refuses to ask for permission on behalf of a process that has no
usage description - which is how the "Use my location" button fills in the
coordinates.

```sh
./build-app.sh
cp -R AutoBrightnessBar.app /Applications/
open /Applications/AutoBrightnessBar.app
```

Start at login is a checkbox in Settings: it writes
`~/Library/LaunchAgents/local.autobrightness-bar.plist`.

## Looking at the icon without a screenshot

The menu bar cannot be captured without Screen Recording permission, and an
eighteen pixel gauge has to be looked at to be judged. So the drawing is a plain
function over a rectangle, and the binary can render it:

```sh
.build/debug/AutoBrightnessBar --render-strip /tmp/strip.png 6   # every state, both themes
.build/debug/AutoBrightnessBar --render-icon /tmp/one.png solar 60 live 8
```

`labelColor` is a dynamic colour: with no `NSAppearance` in effect it resolves to
nothing and the gauge renders blank, which is why the render path sets one
explicitly. The menu bar supplies its own.

## Settings

- **Coordinates** for the solar model. "Use my time zone" takes them from
  `/usr/share/zoneinfo/zone.tab`, which macOS ships: every zone carries an ISO
  6709 position, so `Europe/Moscow` is `+554521+0373704` with nothing asked of
  anyone. "Use my location" goes through CoreLocation instead, which needs a
  permission prompt that an ad-hoc signed app often never receives - the client
  registers with `locationd`, no decision is recorded, and no callback ever
  arrives. That request now gives up after twelve seconds and says so rather
  than leaving the button looking stuck. They
  belong to the agent, not to this app, so they are written into
  `~/.config/autobrightness/config` - a shell file with comments in it that the
  user also edits by hand. It is never serialised wholesale: one line is
  rewritten, the candidate is handed to the agent to parse (`autobrightness sun`
  against it), and only a clean exit code gets it installed. A commented-out
  assignment stays a comment.
- **Poll interval** for the bar itself, in `~/.config/autobrightness/bar.json`.
  The CLI knows nothing about it.
- **What the model has learned**, bucket by bucket, with a button to forget it.

## Tests

```sh
swift test
```

Under test is the part that must not be wrong: the contract decoding (including
a snapshot with no ambient source at all, which is what a cold start with the lid
already shut looks like), the nits scale, and the config rewrite.
