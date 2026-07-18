# Buffer UI Notes

## Intent

The buffer is a native IME-layer staging area. It is not an AX/paste workaround and it is not part of Rime composition. Rime commits become blocks; blocks may be displayed, edited later, or flushed to the focused client through the normal delivery path.

## Current Shape

- `BufferModel` is an ordered block store, not an append-only queue anymore. A `Block` has stable `id`, `text`, `origin`, and `createdAt`. Rime commits establish block boundaries; accepted external text can also enter with provenance.
- Blocks can be inserted at `insertionIndex`, removed, or edited explicitly. Editing preserves `id`, `origin`, and `createdAt`; saving empty text removes that block. Live blocks are pending by definition because successful delivery consumes them.
- `BufferWindowController` owns the independent workbench. It is a borderless, nonactivating `NSPanel`, not a bottom-of-screen `BufferSurface`. The runtime surface is a 44pt single-line rail when collapsed; its controls expand upward to a total height of 78pt while the bottom edge stays fixed. Width may be adjusted, while the former tall preview layout is gone. Only the dedicated compact 22pt drag-handle icon may initiate window movement, and it exposes the pointing-hand cursor on hover; the panel background and other controls must not drag. Visibility, frame, controls-expanded state, and pin-to-all-spaces are persisted in UserDefaults.
- The collapsed main row is exactly: drag handle, expand/collapse affordance, `BufferInlineView`, and the explicit send-all paper plane. The upward shelf contains only a target-free status message, block edit, a first-click `NSSwitch` for persistent capture, and close. Pin and move remain available from Settings/the input-source menu, not the workbench. There is no manual privacy-eye, history/restore, or clear/undo control. The workbench does not embed a candidate projection or a full-text preview. An ordinary close resolves current composition if safe, saves and scrubs an open editor, pauses capture, clears transient loading/error state, preserves staged blocks, and hides; secure/session protection scrubs without saving.
- `BufferWindowGeometry.clampedFrame` restores off-screen frames, chooses the screen with greatest intersection, clamps width to the selected screen, and normalizes height to either the 44pt collapsed or 78pt expanded contract. Expanding or collapsing preserves the window's bottom edge, so the candidate anchor does not jump. Runtime min/max sizes are resynchronized per screen after move/resize.
- `RimeBufferController.drainCommit` remains the routing point: buffer off means direct `Delivery.insert`; buffer on means append the commit to `BufferModel`. Preedit remains in marked text and the regular `CandidateWindow`, never in a stored block.
- While buffer mode is on, plain or Shift-modified Return and Backspace are always consumed by the input method, including engine-failure or untrusted-focus paths. A Return press with pending Rime/chord/raw composition only settles that input into a block and suppresses the rest of the same physical press. Otherwise a tap requests `sendNext` and a hold of about 1.2 seconds requests `sendAll`; Backspace edits active Rime/chord state or removes a buffer block only when precise focus is trusted. Neither key may fall through to the host text field.
- While an exact external buffer lease owns those controls, `CompositionSession` keeps one invisible U+200B marked-text guard alive even when Rime is idle. This prevents Chromium/ProseMirror hosts from submitting the raw Return before/around IMK's handled result. Guard lifetime is independent from semantic Rime composition: idle guard means `composition.composing == false`, `FocusLease.compositionActive == false`, and `markedRangeReliable == false`. Transient external content uses the idle guard but keeps real Rime preedit inline; secure input, own-window focus, focus loss, or buffer deactivation removes the guard.
- `BufferDeliveryCoordinator` is the only component allowed to turn staged blocks into `Delivery.insert` calls. Keyboard delivery passes the `FocusToken` captured on Return keyDown; the explicit paper-plane control at the right end of the main row remains a current-focus `sendAll` alternative. The window never retains or calls an `IMKTextInput` directly.
- A send starts from `InputFocusCoordinator.liveTarget()`. The lease must have the current and expected `FocusToken`, an external target, trusted delivery state, live controller/client, a `controller.client()` whose object identity still matches the lease, matching client bundle, and a frontmost application whose process PID (plus bundle when available) matches the lease. There is no recent-controller or last-client fallback.
- If composition is active, the coordinator may explicitly resolve it, then must reacquire the same expected token. It revalidates that target, composition state, and secure input before every block, stopping immediately if focus changes.
- A successful `Delivery.insert` call is only an accepted attempt, not a destination ACK, but the current product contract consumes that accepted block from the live buffer immediately. A failure stops the operation; the failed block and every not-yet-sent block stay in place.
- Accepted deliveries are consumed from live `blocks` without retaining a plaintext delivery history. There is no user-facing clear/undo path; automatic privacy discard remains an irreversible safety operation and also scrubs any open editor plaintext.
- Block editing uses a separate key window. Activating it invalidates the old external target; ETInput-owned text fields bypass buffer capture and remote mirroring. The editor follows the forced day/night appearance and is moved to the active Space/pointer screen whenever it is reopened from elsewhere. An empty buffer reports that there is nothing to edit instead of silently disabling the button. Secure input, automatic privacy discard, lock and sleep close the editor without saving or reactivating another app and erase its hidden plaintext controls. After ordinary editing, the user must focus an external field again before sending.
- Automatic flushing and timer-based deletion remain disabled. Return tap/hold and the paper-plane button are deliberate user actions; an accepted `insertText` attempt consumes the corresponding live block synchronously even though the target app does not provide a stronger acknowledgement.

## Display Requirements

- Show block boundaries because they are meaningful Rime commit boundaries.
- Keep current model order and the insertion point visually clear; edits and explicit insertion mean it is not always strict creation-time order.
- Show provenance for non-Rime blocks. The live rail contains pending blocks only; do not render sent checks or other sent-state decoration.
- Make long block text inspectable with a tooltip while keeping the rail single-line.
- Keep first-click controls working inside nonactivating panels by using controls that accept first mouse.
- Show Return hold progress as a 2px accent line along the bottom of the always-visible rail without changing panel height; clear it on release, cancellation, focus change, or secure-input shielding.
- Show candidates through the regular `CandidateWindow`, with the same theme, metrics, paging, and token-owned actions as normal input. In buffer mode its anchor is the compact strip, so the panel opens immediately below the strip (or flips above only when screen bounds require it); never duplicate candidate state or project candidates into the strip.
- Treat an ordered panel on another macOS Space as not currently visible. An explicit Show action may re-order the unpinned strip onto the active Space.
- Keep the collapsed rail at 44pt and the upward-expanded panel at 78pt, with a bounded width; long text should truncate or scroll instead of resizing the panel off screen. The bottom edge must remain stationary across expansion so the candidate anchor stays stable. Geometry must still fit visible frames narrower than the normal minimum.
- Inset the rounded chrome inside a transparent window margin, fill it with the fixed day/night workbench surface token so HUD backdrop sampling cannot reduce text contrast, and draw the border as a backing-scale hairline inside its path. Do not center a layer border on the window bounds, where macOS clips it into fuzzy corner/edge fragments.
- Keep queued content visible even if buffer mode is switched off; do not hide unsent text.
- Keep an empty state visible when buffer mode is on but no blocks exist.
- Shield staged text plus candidate/delivery rails while secure input is active and close any open editor too. Hide the workbench and revoke its target while the desktop session is inactive, locked, or asleep. There is no separate manual privacy-shield state.

## Safe Extension Points

- Add read-only presentation properties to `BufferModel`, such as grouped counts, source summaries, ages, or pending-delivery summaries. Keep mutation in explicit model methods so identity, provenance, order, and notifications stay coherent.
- Add richer single-line presentation to `BufferWindowController`/`BufferInlineView`, but route send actions through `BufferDeliveryCoordinator` and candidate actions through the token-owned `CandidateWindow` state machine.
- Extend explicit block editing or add transformations by either preserving the existing block metadata or deliberately creating a new derived block.
- Add visibility, placement, or appearance settings through `SettingsWindow` and UserDefaults. Reuse `BufferWindowGeometry.clampedFrame` for restoration and add tiny-screen cases whenever geometry rules change.
- Evolve focus handling through the pure `FocusTargetRules`, `FocusEventRules`, and `FocusActivationRules` predicates. Any relaxation must retain exact-token ownership, event ordering, lifecycle attribution, external-target filtering, lease/client plus `controller.client()` identity checks, and frontmost bundle/PID checks, with matching `buffer-window-smoke` cases. Pending chord callbacks must be isolated before a lease is suspended or displaced.
- Add another delivery destination only behind an explicit routing layer. Local text insertion must still end at `Delivery.insert`, and a multi-block operation must stop rather than switch destinations when the original token becomes stale.
- Add persistence for buffer text only as an explicit privacy/product decision. Current content is intentionally process-local, and delivery history is intentionally not retained.
- Do not add automatic or delayed delivery outside the explicit Return gesture and paper-plane actions. A keyboard gesture must retain the keyDown token, deliberately settle any intervening composition without sending in the same press, and revalidate that exact token immediately before every insertion.

## Do Not Do

- Do not write buffer content directly to clients from `BufferWindowController`, `BufferInlineView`, or the block editor.
- Do not restore `active ?? recent`, `lastClient`, or bundle-only target fallbacks. The frontmost PID check is required because an app can relaunch with the same bundle identifier.
- Do not flush through an unresolved composition. Only `BufferDeliveryCoordinator` may resolve it for a user-initiated send, after which it must reacquire the same token.
- Do not let Return or Backspace escape to the host while buffer mode is enabled, even when Rime is unavailable or the focus lease is untrusted. Return delivery may occur only through the tap/hold state machine; repeats, late keyUp/command callbacks, focus changes, and composition-settling presses must never create an extra send.
- Do not implement timer-based deletion or automatic delivery. Consuming a block is part of the synchronous user-initiated successful delivery transaction; failure must leave that block live.
- Do not make the passive panel key by default.
- Do not reintroduce diff/reconcile logic from old `buffer-bar`; commit boundaries are already known.
- Do not put preedit into the buffer. Composition preview belongs to marked text and/or candidate window.
- Do not persist buffer text/history accidentally while adding window preferences; those have a different privacy lifetime.

## Validation Checklist

- Build with `swift build -c debug`.
- Run `.build/debug/RimeBuffer buffer-smoke`. It covers successful live-block consumption without history retention, unsent-order preservation, per-block edit metadata, insertion point movement, and close/pause block preservation plus transient-state cleanup.
- Run `.build/debug/RimeBuffer buffer-window-smoke`. It must cover:
  - stale focus epochs/deactivate rejection;
  - every target gate: current/expected token, external/trusted target, live controller/client, lease and current-controller client identity, client bundle, and frontmost bundle/PID;
  - event timestamp ordering and background ownership rejection;
  - provisional activation confirmation, ambiguous lifecycle age gating, and lifetime rejection for lifecycle callbacks on a reused client identity;
  - external-app privacy transitions that ignore ETInput-owned windows and preserve mixed/external content;
  - a rendered block rail followed by a shielded refresh that scrubs its chips and keeps the rail hidden;
  - active-Space visibility plus loading/error state that is ended by pause/close without deleting staged blocks;
  - off-screen restore, oversized-width clamping, 44pt/78pt height normalization with a fixed bottom edge, and a visible frame narrower than the normal minimum.
- Enable buffer mode from the status menu or settings. Confirm the workbench is a 44pt single-line strip whose main row is drag handle → disclosure → blocks → send. Expanding reveals only status → edit → capture switch → close above it at 78pt total height without moving the strip bottom or candidate anchor. Confirm only the drag handle moves the horizontally resizable nonactivating panel, it respects pin/current-Space behavior, restores to a visible screen, and closes without deleting staged blocks.
- With buffer mode enabled, exercise plain Return, Shift+Return, keypad Enter, and Backspace with active composition, no composition, engine failure, and stale/untrusted focus. Confirm they never insert a newline or delete text in the host. A composition-settling Return must create/finish a block without sending on that same press; a clean tap sends exactly one block and a 1.2-second hold sends all exactly once. With the engine unavailable, unresolved composition is consumed without delivery, while existing blocks with no pending composition may still send through the exact live target. Repeats and late keyUp/command callbacks must not duplicate either action.
- Type several committed words and punctuation. Confirm block boundaries, insertion point, and origin badges match `BufferModel` order. Confirm the regular candidate panel uses its normal style and appears directly below the strip.
- Focus two fields in sequence, including two fields in the same app. Confirm a stale candidate action or send cannot affect the newer field. Relaunching an app under the same bundle but a new PID must invalidate the old target.
- Start a composition and send. Confirm the coordinator resolves it deliberately, reacquires the same token, and stops if focus changes before or during the block loop.
- Confirm secure input shields the workbench and blocks every delivery attempt.
- Edit a block. Confirm the editor becomes key only deliberately, the old external target is no longer sendable, no editor text feeds back into the buffer, metadata is preserved, and the edited block becomes pending.
- Confirm `sendNext` and `sendAll` preserve block order, remove each successfully accepted block from the live rail, keep the failed and remaining blocks untouched, and stop on the first target/security failure.
- Confirm successful delivery leaves no recoverable workbench history, and close/pause preserves staged blocks while ending transient loading/error state; then restart the process and confirm blocks are not presented as persistent state.
- Confirm both Return tap/hold and the main-row paper-plane button route through `BufferDeliveryCoordinator`; automatic delivery, timer deletion, and target fallback must not occur. Change focus during a hold and confirm no block is delivered to either the old or new field.
