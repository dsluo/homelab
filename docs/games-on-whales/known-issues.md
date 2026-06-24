# Known issues / open quirks

Low-priority items that don't block the validated Firefox pipeline.

## Test Ball `wolfConfig` video override is ignored

The Test Ball App sets `startVirtualCompositor: false` and a `video.source`
(`videotestsrc pattern=ball`), but Wolf still runs `Create wayland compositor` +
`waylanddisplaysrc`, so you get the empty compositor desktop, not the ball pattern.

Not blocking: the streaming pipeline is proven end-to-end, and the Test Ball was
only ever a diagnostic crutch. Worth investigating whether the operator/fork passes
per-App `wolfConfig.{video,startVirtualCompositor}` only if it becomes useful later.

> Related expected behaviour: an "empty desktop + cursor" on Test Ball is **normal**
> — Wolf runs its Wayland compositor and Test Ball has no app container drawing into
> it.

## Controller / keyboard input not wired

Wolf logs `MOUSE_MOVE_REL_PACKET but no mouse device is present`, and
`/dev/uinput` + `/dev/input/event*` are "not present" in the session pod. The
pointer worked over the stream, but full controller/virtual input needs a
`squat.ai/uinput` device plugin (or a privileged `/dev/uinput` hostPath mount) on
talos1, plus the uinput kernel module. We currently skip it (shrinedogg ships it).
Test Ball needs no input.
