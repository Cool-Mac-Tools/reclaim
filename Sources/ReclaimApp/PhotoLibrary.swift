import Foundation
import Photos
import AppKit

/// Reads the user's Photos library via PhotoKit and surfaces individual photos
/// and videos with real per-asset byte sizes — the detail the filesystem walk
/// can't provide, because the `.photoslibrary` bundle is an opaque, atomic
/// blob on disk (see `MacStorageMap.atomicBundleSuffixes`). Ported from Beacon's
/// `PhotoStore`, then extended for a storage tool: Beacon only needed on-disk
/// URLs to open assets; Reclaim needs their sizes to rank the biggest space
/// hogs, so we sum `PHAssetResource` file sizes instead of resolving URLs.
///
/// Placement: this lives in the app target (not ReclaimCore) so the core library
/// and CLI stay framework-free — same choice Beacon made. Enumeration is
/// synchronous and MUST run off the main thread (it blocks on PhotoKit).
enum PhotoLibrary {

    /// One photo or video, with the metadata a storage view needs. Identified by
    /// PhotoKit `localIdentifier` (stable across launches) — not a file path,
    /// because a single asset can span several on-disk resources (original +
    /// edited + adjustments) and iCloud-only assets have no local file at all.
    struct Asset: Identifiable, Hashable, Sendable {
        let id: String            // PHAsset.localIdentifier
        let filename: String      // original filename (e.g. IMG_1234.HEIC)
        let bytes: Int64          // sum of all on-disk resource sizes
        let creationDate: Date?
        let isVideo: Bool
        let pixelWidth: Int
        let pixelHeight: Int
        let isFavorite: Bool
        /// True when no bytes live on this Mac (asset is iCloud-only). We can't
        /// reclaim space that isn't here, so these are shown as informational.
        var isLocal: Bool { bytes > 0 }
    }

    // MARK: - Authorization

    /// True if we can read the library right now without prompting.
    static var isAuthorized: Bool {
        let s = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return s == .authorized || s == .limited
    }

    /// `.limited` means the user granted access to a hand-picked subset only, so
    /// totals will understate the real library — the UI should say so.
    static var isLimited: Bool {
        PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited
    }

    static var wasDenied: Bool {
        let s = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return s == .denied || s == .restricted
    }

    /// Requests read/write access (write is needed later for delete-to-Recently-
    /// Deleted). Safe on a background queue; blocks on the system prompt.
    @discardableResult
    static func ensureAuthorized() -> Bool {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized, .limited:
            return true
        case .notDetermined:
            // Box the result so the completion's write is a reference mutation,
            // not a captured-var mutation (Swift 6 Sendable). The semaphore
            // orders the write-before-read.
            final class Box: @unchecked Sendable { var granted = false }
            let box = Box()
            let sem = DispatchSemaphore(value: 0)
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                box.granted = (status == .authorized || status == .limited)
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + 120)
            return box.granted
        default:
            return false
        }
    }

    // MARK: - Enumerate assets with sizes

    /// The result of a library walk: the largest assets (capped for display) plus
    /// honest totals across the *whole* library, so the UI never implies the
    /// capped list is everything.
    struct Scan: Sendable {
        var assets: [Asset]     // largest-first, capped at `keep`
        var totalBytes: Int64   // on-disk bytes across every photo + video
        var totalCount: Int     // every photo + video (local or iCloud)
        var localCount: Int     // assets with bytes on this Mac
        /// Bytes represented by the returned (capped) list.
        var shownBytes: Int64 { assets.reduce(0) { $0 + $1.bytes } }
    }

    /// Walk the whole library, compute each asset's on-disk size, and return the
    /// largest assets sorted biggest-first (what a space-recovery view wants),
    /// alongside library-wide totals. Synchronous and potentially slow on a big
    /// library — call off the main thread and feed `progress` to the UI. `keep`
    /// caps how many of the largest assets are returned for display.
    static func loadAssets(keep: Int = 3000,
                           progress: ((Int, Int) -> Void)? = nil) -> Scan {
        guard ensureAuthorized() else { return Scan(assets: [], totalBytes: 0, totalCount: 0, localCount: 0) }

        let opts = PHFetchOptions()
        opts.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d",
                                     PHAssetMediaType.image.rawValue,
                                     PHAssetMediaType.video.rawValue)
        opts.includeHiddenAssets = false
        let fetch = PHAsset.fetchAssets(with: opts)
        let total = fetch.count

        var out: [Asset] = []
        out.reserveCapacity(min(total, keep * 2))
        var totalBytes: Int64 = 0
        var localCount = 0
        var i = 0
        fetch.enumerateObjects { asset, _, _ in
            i += 1
            if let progress, i % 250 == 0 { progress(i, total) }
            let bytes = sizeOnDisk(of: asset)
            totalBytes += bytes
            if bytes > 0 { localCount += 1 }
            let name = PHAssetResource.assetResources(for: asset).first?.originalFilename
                ?? asset.localIdentifier
            out.append(Asset(id: asset.localIdentifier,
                             filename: name,
                             bytes: bytes,
                             creationDate: asset.creationDate,
                             isVideo: asset.mediaType == .video,
                             pixelWidth: asset.pixelWidth,
                             pixelHeight: asset.pixelHeight,
                             isFavorite: asset.isFavorite))
        }
        progress?(total, total)
        out.sort { $0.bytes > $1.bytes }
        if out.count > keep { out.removeLast(out.count - keep) }
        return Scan(assets: out, totalBytes: totalBytes, totalCount: total, localCount: localCount)
    }

    // MARK: - Delete (→ Photos' Recently Deleted, recoverable 30 days)

    enum DeleteOutcome: Sendable {
        case deleted(Int)     // count actually removed
        case cancelled        // user declined the system confirmation
        case nothingFound     // ids no longer resolve to assets
    }

    /// Move the given assets to Photos' Recently Deleted via the supported
    /// PhotoKit change request. macOS shows its own confirmation panel; declining
    /// it throws a cancelled error, which we report as `.cancelled` (not a
    /// failure). Recoverable in Photos for 30 days.
    static func delete(ids: [String]) async -> DeleteOutcome {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        guard assets.count > 0 else { return .nothingFound }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets)
            }
            return .deleted(assets.count)
        } catch {
            // The user clicking "Don't Allow" on the system panel surfaces here.
            if (error as NSError).domain == "PHPhotosErrorDomain"
                || (error as NSError).code == PHPhotosError.userCancelled.rawValue {
                return .cancelled
            }
            return .cancelled
        }
    }

    /// Sum of every on-disk resource backing an asset: the original plus any
    /// edited render, adjustment data, or paired video (Live Photos). Uses the
    /// `fileSize` resource value — undocumented but stable and the only way to
    /// get real bytes without downloading iCloud originals. Fine for a non-MAS
    /// Developer ID app (this KVC key is what trips App Store review, which
    /// Reclaim doesn't ship through). Returns 0 for iCloud-only assets.
    static func sizeOnDisk(of asset: PHAsset) -> Int64 {
        var total: Int64 = 0
        for res in PHAssetResource.assetResources(for: asset) {
            let v = res.value(forKey: "fileSize")
            if let n = v as? Int64 { total += n }
            else if let n = v as? Int { total += Int64(n) }
            else if let n = v as? NSNumber { total += n.int64Value }
        }
        return total
    }

    // MARK: - Thumbnails

    private static let imageManager: PHCachingImageManager = {
        let m = PHCachingImageManager()
        return m
    }()

    /// A square thumbnail for an asset id, from the local cache/library (no iCloud
    /// download). Returns nil if the asset is gone or has no local pixels.
    static func thumbnail(for id: String, size: CGFloat = 96) async -> NSImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
        else { return nil }
        let opts = PHImageRequestOptions()
        opts.isNetworkAccessAllowed = false
        opts.deliveryMode = .opportunistic
        opts.resizeMode = .fast
        let target = CGSize(width: size * 2, height: size * 2)   // @2x
        return await withCheckedContinuation { cont in
            var resumed = false
            imageManager.requestImage(for: asset, targetSize: target,
                                      contentMode: .aspectFill, options: opts) { img, info in
                // opportunistic delivery can call back twice (low-res then full);
                // resume once, on the first usable image.
                if resumed { return }
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if let img, !degraded {
                    resumed = true
                    cont.resume(returning: img)
                } else if img == nil && (info?[PHImageErrorKey] != nil
                                         || (info?[PHImageResultIsInCloudKey] as? Bool) == true) {
                    resumed = true
                    cont.resume(returning: nil)
                }
            }
        }
    }
}
