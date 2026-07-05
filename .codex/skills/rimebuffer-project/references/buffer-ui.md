# Buffer UI Notes

## Intent

The buffer is a native IME-layer staging area. It is not an AX/paste workaround and it is not part of Rime composition. Rime commits become blocks; blocks may be displayed, edited later, or flushed to the focused client through the normal delivery path.

## Current Shape

- `BufferModel` is append-only. Each Rime commit becomes a `Block` with `text` and `createdAt`.
- `BufferSurface` is a passive `NSPanel` at the bottom of the screen. It is borderless, nonactivating, and should not steal focus.
- `RimeBufferController.drainCommit` is the routing point: buffer off means direct `Delivery.insert`; buffer on means append to `BufferModel` and clear marked text.
- `BufferModel.deliver` is wired in `main.swift` to the active controller, which attempts to insert into the current client.
- Manual send keeps blocks queued. The target app does not acknowledge `insertText`, so only explicit clear should remove staged text.
- Automatic flushing is disabled for now. IMK `insertText` has no strong success acknowledgement, so the buffer must not remove blocks just because an `IMKTextInput` object existed.
- `compositionActive` must gate any future automatic or delayed flush so the buffer never flushes mid-composition.

## Display Requirements

- Show the complete staged text, not only individual chips.
- Show block boundaries because they are meaningful Rime commit boundaries.
- Keep oldest-to-newest order visually clear.
- Make long block text inspectable with tooltip or a larger preview.
- Keep first-click controls working inside nonactivating panels by using controls that accept first mouse.
- Keep panel dimensions stable and bounded; long text should truncate or scroll instead of resizing off screen.
- Keep queued content visible even if buffer mode is switched off; do not hide unsent text.
- Keep an empty state visible when buffer mode is on but no blocks exist.

## Safe Extension Points

- Add read-only presentation properties to `BufferModel` for UI display, such as joined text, character count, oldest/newest age, or pending flush state.
- Add richer display to `BufferSurface`: grouped rows, preview, per-block badges, countdown indicators, or manual flush/clear controls.
- Add explicit edit mode later, but entering edit mode must be deliberate because normal buffer display must not steal focus.
- Add settings for visibility or panel position through `SettingsWindow`/`UserDefaults`.

## Do Not Do

- Do not write buffer content directly to clients from `BufferSurface`.
- Do not flush while `compositionActive` is true.
- Do not implement timer-based deletion or automatic delivery without a stronger success model and explicit UX.
- Do not make the passive panel key by default.
- Do not reintroduce diff/reconcile logic from old `buffer-bar`; commit boundaries are already known.
- Do not put preedit into the buffer. Composition preview belongs to marked text and/or candidate window.

## Validation Checklist

- Build with `swift build -c debug`.
- Enable buffer mode from the status menu or settings.
- Type several committed words and punctuation; confirm the surface shows whole staged text and individual blocks.
- Confirm manual send preserves order, attempts delivery through the focused field, and keeps staged text visible.
- Confirm leaving buffer mode preserves queued blocks until the user clears them.
- Confirm clearing removes blocks without delivering.
- Confirm no automatic flush or deletion happens without user action.
