# Reclaim

**Your Mac is not full. Your tools are messy.**

Reclaim is an explainable, app-aware storage intelligence tool for macOS. It
finds the hidden waste that Cursor, Xcode, npm, browsers, and build tools leave
behind, explains exactly what each finding is, chooses the safest supported
removal method, and proves how much space was actually recovered.

Born from a real cleanup session that recovered **90+ GB verified** without
deleting a single source file, photo, or piece of app history.

## Architecture

One deterministic engine, multiple front-ends (per the product master plan):

```
Sources/
├── ReclaimCore/          The engine — shared by everything
│   ├── Models/           RiskTier (5-tier safety), Recipe schema, Finding
│   ├── Recipes/          Versioned recipe catalog (~25 launch recipes)
│   └── Scanner/          Read-only scanner: allocated+apparent size,
│                         process checks, protected-path hard stops
├── reclaim-cli/          `reclaim` — Phase 0 concierge tool
└── ReclaimApp/           SwiftUI dashboard prototype
```

## Principles (non-negotiable)

- **Read-only first** — a scan never mutates the computer.
- **Explain before acting** — every finding states what it is, why it exists,
  what deletion changes, and whether it returns.
- **AI advises, recipes act** — no LLM ever constructs a deletion.
- **Reversible by default** — quarantine/Trash before permanent deletion.
- **Supported paths** — `simctl`, `npm`, `brew` over raw `rm`.
- **macOS protections are hard stops** — "Operation not permitted" means skipped.
- **Prove the outcome** — every cleanup ends with a verification rescan.

## Usage

```sh
swift build
.build/debug/reclaim scan            # human-readable read-only report
.build/debug/reclaim scan --json     # machine-readable ledger entry
.build/debug/reclaim recipes         # list the recipe catalog
swift run ReclaimApp                 # SwiftUI dashboard prototype
./scripts/test.sh                    # test suite (CLT-compatible flags)
```

The five risk tiers:

| Tier | Meaning | Allowed behavior |
|---|---|---|
| 🟢 Green | Regenerable caches | One-click after app checks |
| 🔵 Blue | Reversible local data | Quarantine with rollback window |
| 🟡 Yellow | History / workflow state | Explicit per-item selection |
| 🟠 Orange | Personal / cloud-synced | Never auto-delete; precise warnings |
| 🔴 Red | System-protected | Never touch; supported manager only |

V1 automates Green only.

## Status

- [x] Phase 0/1 (in progress): read-only scanner, recipe catalog, CLI, app prototype
- [ ] Concierge cleanups (0/10) — see `PLAYBOOK.md`
- [ ] Phase 2: recipe engine with quarantine + supported-CLI adapters + verification ledger
- [ ] Phase 3: developer intelligence modules + growth ledger
- [ ] Phase 4: paid beta (Free Scan + Solo Pro)

See the product master plan for the full roadmap.

## Live workspace & verified recovery

Activity includes a process list and a navigable 3D diagram of the same live
system measurements. Both views share app/helper groups, resource use and
actionable insights. See [WORKSPACE.md](WORKSPACE.md) for coverage and controls.

Recovery history now distinguishes quarantined data from measured space freed after
permanent deletion. Tests and macOS CI cover event expiry, corrupt feeds/manifests,
rollback, and recovery accounting.
