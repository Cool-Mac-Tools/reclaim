# Reclaim app icon

`reclaim-icon-source.png` is the user's approved artwork, preserved unchanged.
The website uses its existing rounded exports.

`reclaim-icon-full-canvas.png` is the macOS asset-catalog variant. It was produced
with the built-in imagegen editing tool, preserving the blue folded R while
extending the navy artwork to all four edges. There is no outer tile, inset
canvas or baked-in rounded mask. macOS supplies its native icon treatment.

Editing prompt: Preserve the exact existing folded blue R, its proportions,
lighting and material. Remove exterior transparent margins, ground shadow and
rounded tile boundary. Extend the navy background seamlessly to the square
edges. Opaque full-canvas artwork, no outer gray tile, no added text or objects.

Run `swift scripts/prepare-appicon.swift` to export the macOS catalog sizes.
Run `scripts/compile-appicon.sh` on a Mac with Xcode to compile the catalog.
CI publishes `macOS-app-icons`; CLT-only signing Macs use the matching compiled
catalog in `Resources/CompiledIcons`. Packaging verifies the source digest.

The original ICNS remains the legacy fallback. Packaged apps use
`CFBundleIconName=AppIcon` and `Assets.car`; the development-only Dock override
must never replace the packaged icon.
