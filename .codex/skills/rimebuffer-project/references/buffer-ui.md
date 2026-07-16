# Buffer UI Notes

## Intent

The buffer is a native IME-layer staging area. It is not an AX/paste workaround and it is not part of Rime composition. Rime commits become blocks; blocks may be displayed, edited later, or flushed to the focused client through the normal delivery path.

## Current Shape

- `BufferModel` is an ordered block store, not an append-only queue anymore. A `Block` has stable `id`, `text`, `origin`, `createdAt`, `lastSentAt`, and `lastSentTargetBundleID`. Rime commits establish block boundaries; accepted external text can also enter with provenance.
- Blocks can be inserted at `insertionIndex`, removed, or edited explicitly. Editing preserves `id`, `origin`, and `createdAt`, clears the previous sent markers, and makes the block pending again; saving empty text removes that block.
- `BufferWindowController` owns the independent workbench. It is a borderless, resizable, draggable, nonactivating `NSPanel`, not a bottom-of-screen `BufferSurface`. Visibility, frame, pin-to-all-spaces, and candidate placement are persisted in UserDefaults.
- The workbench combines a token-owned candidate projection, complete read-only text preview, `BufferInlineView` block rail, target/availability label, send history controls, privacy shield, and explicit block editor. An ordinary close resolves current composition if safe, saves and scrubs an open editor, pauses capture, preserves model content, and hides; secure/privacy/session protection scrubs without saving. Clear is a separate reversible action.
- `BufferWindowGeometry.clampedFrame` restores off-screen frames, chooses the screen with greatest intersection, clamps oversized frames, and reduces the nominal 520×340 minimum when the visible screen itself is smaller. Runtime min/max sizes are resynchronized per screen after move/resize.
- `RimeBufferController.drainCommit` remains the routing point: buffer off means direct `Delivery.insert`; buffer on means append the commit to `BufferModel`. Preedit remains in marked text and the candidate projection, never in a stored block.
- `BufferDeliveryCoordinator` is the only component allowed to turn staged blocks into `Delivery.insert` calls. The window and `BufferInlineView` request `sendNext`/`sendAll`; they never retain or call an `IMKTextInput` directly.
- A send starts from `InputFocusCoordinator.liveTarget()`. The lease must have the current and expected `FocusToken`, an external target, trusted delivery state, live controller/client, a `controller.client()` whose object identity still matches the lease, matching client bundle, and a frontmost application whose process PID (plus bundle when available) matches the lease. There is no recent-controller or last-client fallback.
- If composition is active, the coordinator may explicitly resolve it, then must reacquire the same expected token. It revalidates that target, composition state, and secure input before every block, stopping immediately if focus changes.
- A successful `Delivery.insert` call is only an accepted attempt, not a destination ACK. Sent blocks stay visible and receive sent markers; later retries skip that accepted prefix unless the user edits or restores it.
- `sentHistory` keeps at most 50 delivery snapshots in memory and the workbench exposes all of them in a selector. A snapshot can restore cleared blocks or mark surviving blocks pending while preserving relative order. Manual clear keeps one in-memory undo snapshot; privacy discard erases blocks, undo, history, and any open editor plaintext. None survive an input-method process restart.
- Block editing uses a separate key window. Activating it invalidates the old external target; ETInput-owned text fields bypass buffer capture and remote mirroring. Privacy shield, secure input, lock and sleep close the editor without saving or reactivating another app and erase its hidden plaintext controls. After ordinary editing, the user must focus an external field again before sending.
- Automatic flushing and timer-based deletion remain disabled. The target app does not provide a strong acknowledgement for `insertText`, so user action owns delivery and deletion.

## Display Requirements

- Show the complete staged text, not only individual chips.
- Show block boundaries because they are meaningful Rime commit boundaries.
- Keep current model order and the insertion point visually clear; edits and explicit insertion mean it is not always strict creation-time order.
- Show provenance for non-Rime blocks and distinguish pending blocks from blocks already attempted.
- Make long block text inspectable with tooltip or a larger preview.
- Keep first-click controls working inside nonactivating panels by using controls that accept first mouse.
- Treat an ordered panel on another macOS Space as not currently visible. Candidate projection must fall back to the caret there; an explicit Show action may re-order the unpinned panel onto the active Space.
- Keep panel dimensions stable and bounded; long text should truncate or scroll instead of resizing off screen. Geometry must still fit visible frames smaller than the normal minimum.
- Keep queued content visible even if buffer mode is switched off; do not hide unsent text.
- Keep an empty state visible when buffer mode is on but no blocks exist.
- Shield staged text plus candidate/delivery rails while secure input is active or the user enables the privacy shield; close any open editor too. Hide the workbench and revoke its target while the desktop session is inactive, locked, or asleep.

## Safe Extension Points

- Add read-only presentation properties to `BufferModel`, such as grouped counts, source summaries, ages, or pending-delivery summaries. Keep mutation in explicit model methods so identity, provenance, history, and notifications stay coherent.
- Add richer presentation to `BufferWindowController`/`BufferInlineView`, but route send actions through `BufferDeliveryCoordinator` and candidate actions through the token-owned candidate state machine.
- Extend explicit block editing or add transformations by either preserving the existing block metadata or deliberately creating a new derived block. Any text change to an already attempted block must clear its sent markers.
- Add visibility, placement, or appearance settings through `SettingsWindow` and UserDefaults. Reuse `BufferWindowGeometry.clampedFrame` for restoration and add tiny-screen cases whenever geometry rules change.
- Evolve focus handling through the pure `FocusTargetRules`, `FocusEventRules`, and `FocusActivationRules` predicates. Any relaxation must retain exact-token ownership, event ordering, lifecycle attribution, external-target filtering, lease/client plus `controller.client()` identity checks, and frontmost bundle/PID checks, with matching `buffer-window-smoke` cases. Pending chord callbacks must be isolated before a lease is suspended or displaced.
- Add another delivery destination only behind an explicit routing layer. Local text insertion must still end at `Delivery.insert`, and a multi-block operation must stop rather than switch destinations when the original token becomes stale.
- Add persistence for buffer text or delivery history only as an explicit privacy/product decision. Current content, history, and undo snapshots are intentionally process-local.
- Add automatic or delayed delivery only after defining an explicit UX and a stronger success model. Composition must be deliberately resolved and the same token revalidated immediately before every insertion.

## Do Not Do

- Do not write buffer content directly to clients from `BufferWindowController`, `BufferInlineView`, or the block editor.
- Do not restore `active ?? recent`, `lastClient`, or bundle-only target fallbacks. The frontmost PID check is required because an app can relaunch with the same bundle identifier.
- Do not flush through an unresolved composition. Only `BufferDeliveryCoordinator` may resolve it for a user-initiated send, after which it must reacquire the same token.
- Do not implement timer-based deletion or automatic delivery without a stronger success model and explicit UX.
- Do not make the passive panel key by default.
- Do not reintroduce diff/reconcile logic from old `buffer-bar`; commit boundaries are already known.
- Do not put preedit into the buffer. Composition preview belongs to marked text and/or candidate window.
- Do not persist buffer text/history accidentally while adding window preferences; those have a different privacy lifetime.

## Validation Checklist

- Build with `swift build -c debug`.
- Run `.build/debug/RimeBuffer buffer-smoke`. It covers sent-block retention, pending-prefix behavior, delivery-history restoration and relative order, per-block edit metadata, insertion point movement, clear undo, and close/pause preservation.
- Run `.build/debug/RimeBuffer buffer-window-smoke`. It must cover:
  - stale focus epochs/deactivate rejection;
  - every target gate: current/expected token, external/trusted target, live controller/client, lease and current-controller client identity, client bundle, and frontmost bundle/PID;
  - event timestamp ordering and background ownership rejection;
  - provisional activation confirmation, ambiguous lifecycle age gating, and lifetime rejection for lifecycle callbacks on a reused client identity;
  - external-app privacy transitions that ignore ETInput-owned windows and preserve mixed/external content;
  - a rendered block rail followed by a shielded refresh that scrubs its chips and keeps the rail hidden;
  - active-Space visibility plus a loading/error-only state that remains explicitly clearable;
  - off-screen restore, oversized-frame clamping, and a visible frame smaller than 520×340.
- Enable buffer mode from the status menu or settings. Confirm the workbench is draggable/resizable, stays nonactivating, respects pin/current-Space behavior, restores to a visible screen, and closes without clearing blocks.
- Type several committed words and punctuation. Confirm the complete preview, block boundaries, insertion point, origin badges, and sent markers match `BufferModel` order.
- Focus two fields in sequence, including two fields in the same app. Confirm a stale candidate action or send cannot affect the newer field. Relaunching an app under the same bundle but a new PID must invalidate the old target.
- Start a composition and send. Confirm the coordinator resolves it deliberately, reacquires the same token, and stops if focus changes before or during the block loop.
- Confirm secure input shields the workbench and blocks every delivery attempt.
- Edit a block. Confirm the editor becomes key only deliberately, the old external target is no longer sendable, no editor text feeds back into the buffer, metadata is preserved, and the edited block becomes pending.
- Confirm `sendNext` and `sendAll` preserve block order, keep attempted blocks visible, skip the attempted prefix on retry, and stop on the first target/security failure.
- Confirm delivery-history restore, clear undo, and close/pause preservation work; then restart the process and confirm blocks/history are not presented as persistent state.
- Confirm no automatic send, deletion, or target fallback occurs without user action.
