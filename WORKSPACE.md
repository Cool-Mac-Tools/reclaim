# Activity and the live Mac diagram

Open **Activity**, then choose **List** or **Diagram**. My Mac's diagram button
opens the same Activity view. Workspace no longer occupies a separate sidebar tab.

Both views share one system sample every three seconds: apps and their helper
processes, background processes, CPU, resident memory and disk usage. Every sampled
process belongs to exactly one group. The list supports search and CPU/memory sort;
the diagram shows up to 12 objects per zone for legibility. Use the list to review
all groups. Switching views does not start another sampler.

Drag the diagram to orbit, scroll to zoom, and click an object to inspect its
measured resource use. The computer object opens My Mac. Insights above either
view explain notable CPU, memory, thermal or storage conditions and provide next
steps. Insights can be collapsed to give the diagram more space.

CPU at 100% means one core. Resident memory summed across helpers can include
shared pages. Swap alone is not proof of current memory pressure. Measurements
are observations, not a guarantee that an app is responsible for perceived slowness.
An unavailable process sample is shown as a collection problem, never a healthy
empty Mac. My Mac's storage categories are separately timestamped scan snapshots.

The diagram does not collect browser tabs, document contents, screen pixels or
agent conversations. The earlier connection panels are removed. The existing
`workspace-event` CLI protocol remains available for compatibility, but these
external events are not displayed as part of Activity's measured process sample.

## Recovery accounting

History separates bytes moved to quarantine from measured free-space increases
after permanent deletion. Failed purges stay retryable. Supported tool cleanup
commands also record measured recovery, bounded by the size removed from their
known storage paths. Quarantine-only sessions are not counted as freed space.
Snapshots and concurrent disk activity can delay or reduce the measured delta.

History updates use a cross-process lock, atomic replacement and a backup of the
previous valid generation. A read or decode failure preserves the existing file
and the UI's last loaded totals. Errors remain visible; unreadable history never
silently becomes an empty record. Older recovery entries remain compatible.
Quarantine manifests are atomic, and a failed move record triggers rollback.

## Development checks

`bash scripts/test.sh` uses SwiftPM with Xcode or a direct Swift Testing runner
with Command Line Tools. The direct runner accepts `--filter REGEX` and
`--skip REGEX`. Restricted tool sessions may block `ps`; the full process-probe
integration test runs in macOS CI. Cleanup tests use temporary fixtures.

The native diagram uses SceneKit on macOS 14 and later.
