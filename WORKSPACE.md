# Live 3D workspace

Open **Workspace** in Reclaim's sidebar, or use **3D workspace** from My Mac or
Activity. Drag to orbit, scroll to zoom, and click objects to inspect their source
and current activity. The list provides the same selection via keyboard. Reset
camera, type filters, object search, and Pause work without leaving the view.
Category filters bring the corresponding area closer for inspection; Everything
returns to the full workspace overview.

The world is built from live observations. Running apps, CPU/memory, and the
startup volume update every three seconds while the view is open. App launches,
exits, and focus changes appear in the activity stream. Objects keep their positions
between updates; the renderer draws on demand and honors Reduce Motion.

Connections are explicit and local:

- **Window details:** macOS Accessibility permission exposes window titles and
  open document paths. Recognized terminal windows appear in the Terminals zone;
  terminal contents and command history are not collected.
- **Safari / Chrome:** opt-in Automation connections read open tab titles and URLs
  every 12 seconds (up to 80 per browser). Closing Workspace disconnects them.
- **Workspace folder:** choose a folder to observe recursive saved-file changes.
  Git internals and generated build directories are excluded. Unsaved editor
  buffers are not observed. No file contents or screen pixels are captured.
- **Agents / tasks:** tools report structured events through the local CLI bridge
  below. The app does not infer tool calls from process names or read agent chats.

The 3D scene shows up to 12 objects per zone for legibility; every collected object
remains available in the inspector list. Window collection is bounded per sample,
so slow/unresponsive applications can temporarily have incomplete window coverage.
The storage object opens My Mac's full category map; the Activity link opens the
existing diagnostics. Storage categories retain their scan timestamp.

## Local tool integration

Build the CLI with `swift build --product reclaim`, then put it on your PATH or
use `.build/debug/reclaim`:

```sh
reclaim workspace-event --kind agent --id local-builder --title 'Local builder' --detail 'Compiling Reclaim' --state active
reclaim workspace-event --kind file --id root-view --title 'RootView.swift' --path /absolute/project/RootView.swift --detail 'Saved an edit'
reclaim workspace-event --kind task --id build --title 'Build Reclaim' --state completed
```

Allowed kinds: `agent`, `task`, `file`, `terminal`. States: `active`, `idle`,
`completed`, `failed`. Repeat the same kind + ID to report progress/heartbeats.
Use an ID unique to the tool/task, rather than a new ID on every heartbeat.

Events are newline-terminated JSON objects in `~/.reclaim/workspace-events.jsonl`,
written with an append lock and bounded rotation. External integrations may use
the same schema: `id`, `entityID`, `kind`, `title`, `detail`, `state`, ISO-8601
`timestamp`, and optional `path`. Text and record sizes are bounded. A partial or
malformed record does not stop the reader. Reports become idle after 60 seconds,
expire after ten minutes, and completed/failed tasks linger for two minutes.

Use the bridge from your editor, terminal wrapper, or agent lifecycle hooks.
No hooks or permissions are installed globally by this feature.

## Recovery accounting

History separates bytes moved to quarantine from observed free-space increases
after permanent deletion. Failed purges stay retryable and are not celebrated.
The new `~/.reclaim/purges.json` records successful/failed sessions, deleted bytes,
and before/after free space. Old quarantine-only sessions are not retroactively
counted as verified recovery. Snapshots and unrelated disk activity can affect the
measured delta; the UI keeps deleted bytes separate from that measurement.

Quarantine manifests are written atomically. If recording a move fails, Reclaim
attempts to move it back. A corrupt manifest/history file is preserved for recovery,
not replaced with an empty history or purged during startup.

## Development checks

`bash scripts/test.sh` chooses the normal SwiftPM suite with Xcode or the direct
Swift Testing runner with Command Line Tools. The direct runner also accepts
`--filter REGEX` and `--skip REGEX`. In restricted tool sessions, the real process
probe test can fail because `ps` is blocked; the other tests remain runnable.

The native 3D view supports macOS 14+ through SceneKit. The toolkit is deprecated
on newer macOS releases but remains available for the app's supported systems;
a future RealityKit renderer can reuse the observation model and event protocol.
