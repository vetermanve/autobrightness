# A meter that works with the lid shut

The solar model replays a typical day; it cannot see that today is overcast or
that a lamp went on. Only a sensor that can see the room with the lid down fixes
that, and none of the ones the Mac has qualifies. What follows is what was ruled
out and what is left, so none of it has to be rediscovered.

## The hook everything plugs into

The agent takes any external meter through one config line:

```sh
AMBIENT_CMD='curl -s --max-time 2 http://lux.local/nits'
```

The contract is deliberately thin: print one number in nits on stdout, exit zero.
A non-zero exit, no output, or anything that is not a number falls through to the
next source in the chain rather than failing the tick. Nits, not lux, because
everything downstream is nits - the conversion belongs in the meter, where the
calibration constant can be measured once against the built-in panel.

Keep it under a second. It runs inside every tick, and mid-ramp as well.

## Ruled out, with the reason

**The Mac's own ambient sensor.** On Apple Silicon it lives behind the AOP
coprocessor and surfaces as `AppleSPUHIDInterface`, which publishes IOReport
packet counters and no lux. The classic Intel route -
`IOHIDEventSystemClientCreate` with `PrimaryUsagePage 0xff00, PrimaryUsage 4`,
then `kIOHIDEventTypeAmbientLightSensor` - matches zero services on an M5 Pro
(checked). And it would not help anyway: the sensor is in the lid, so with the
lid shut it faces the keyboard.

**The built-in camera.** Same place, same problem, and macOS marks it
`suspended=true` while the lid is down.

**A USB webcam through AVFoundation.** A webcam auto-exposes, so mean frame luma
is pinned near the middle whatever the room does. The reading only means
something at a known exposure, and macOS gives neither: `exposureDuration` and
`iso` are marked `API_UNAVAILABLE(macos)`, and on this machine every exposure
mode - `.locked`, `.custom`, `.autoExpose`, `.continuousAutoExposure` - reports
`isExposureModeSupported == false`, for the built-in camera and for a virtual one
alike. AVFoundation is a dead end for light metering on macOS.

**The monitors.** None of the three here has an ambient sensor, and MCCS has no
standard VCP code for one. An Apple Studio Display does have one, but does not
publish a reading either.

## Still open

### A webcam over UVC, driven directly

The camera is only useless through AVFoundation. The UVC spec has
`CT_EXPOSURE_TIME_ABSOLUTE_CONTROL` and `PU_GAIN_CONTROL` as plain control
transfers, which is how apps like Webcam Settings drive exposure manually. With
exposure and gain pinned, mean luma over a fixed crop becomes a real measurement:

```
relative_lux = mean_luma / (exposure_time * gain)
```

and the constant that turns it into nits can be fitted while the lid is open,
against the `als` source, which is what the solar model already does for itself.

Not buildable blind: the control descriptors differ per camera, and an old camera
may not implement the manual controls at all. The first step with a camera in
hand is to enumerate its UVC control descriptors and find out whether manual
exposure is even offered. Then: is the usable range wide enough? Fixed exposure
covers perhaps 1:50 before it clips at one end, while a room goes from a few lux
at night to several hundred by a window. Auto-ranging - re-lock when the reading
leaves the usable band, carrying the scale factor across the re-lock - is the
standard answer and is where the complexity lives.

A lens pointed at the room also needs somewhere to live that the cat will not
reposition.

### A lux sensor on the network

BH1750 or TSL2591 on an ESP32 or ESP8266, publishing one JSON endpoint. Parts are
a few hundred roubles, the firmware is a few dozen lines, and nothing about it is
Mac-specific. It is the only option here that measures the actual room with no
compromise, and `AMBIENT_CMD` is already the whole integration.

If the sensor instead lands in Home Assistant, the config line becomes a `curl`
against its REST API with a long-lived token, and the same `jq` filter pulls the
illuminance attribute. No code here changes either way.

### A USB lux meter

A Yocto-Light-V4 or similar: a real photometric sensor on USB, no soldering, no
network, and a command line tool that already prints lux. The expensive end of
the options - roughly the price of all the other ones put together - but the only
one that is finished the moment it is plugged in.

## Calibration, whichever one arrives

Any meter needs one constant: how its reading maps onto the nits the rest of the
pipeline speaks. That fitting is free here, because the Mac supplies the answer
whenever the lid is open - both sources can be read at the same moment and the
ratio recorded, exactly as the solar model records its buckets. Which means the
right place for the fit is the same state directory, and the right time is every
tick where `als` is live and the meter answers.
