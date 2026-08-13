import SwiftUI
import UIKit

/// Renders a "My Oshi" composition (all its layers, positioned/scaled like the
/// editor) into a single flattened PNG stored on disk, so it can be used as the
/// app wallpaper. Previously only the top layer's remote URL was used, so a
/// multi-layer composition never showed up as the wallpaper.
enum WallpaperRenderer {
    /// The editor canvas is a 300×300 logical space with a 90pt base layer size.
    private static let canvasSize: CGFloat = 300
    private static let baseSize: Double = 90

    /// Filename prefix under Documents. Storing the bare name keeps it valid
    /// across launches/updates, since the container path can change.
    private static let filePrefix = "oshi_wallpaper"

    @MainActor
    static func render(layers: [AvatarLayer]) async -> String? {
        // Download each layer's image up front — ImageRenderer can't resolve
        // AsyncImage, so layers must already be UIImages at render time.
        // Fetched concurrently since compose() re-sorts by zIndex anyway, so
        // download order doesn't need to match layer order.
        let loaded = await withTaskGroup(of: (layer: AvatarLayer, image: UIImage)?.self) { group in
            for layer in layers {
                group.addTask {
                    guard let url = URL(string: layer.imageUrl),
                          let (data, _) = try? await URLSession.shared.data(from: url),
                          let image = UIImage(data: data) else { return nil }
                    return (layer: layer, image: image)
                }
            }
            var results: [(layer: AvatarLayer, image: UIImage)] = []
            for await entry in group {
                if let entry { results.append(entry) }
            }
            return results
        }
        guard let png = compose(loaded)?.pngData() else { return nil }

        return writeRenderedPNG(png)
    }

#if DEBUG
    @MainActor
    static func writeRenderedPNGForTesting(_ png: Data) -> String? {
        writeRenderedPNG(png)
    }
#endif

    @MainActor
    private static func writeRenderedPNG(_ png: Data) -> String? {
        let fileName = "\(filePrefix)_\(UUID().uuidString).png"
        let url = localURL(for: fileName)
        do {
            try png.write(to: url, options: .atomic)
            removeOldRenderedWallpapers(except: fileName)
            return fileName
        } catch {
            AppLogger.network.error("Wallpaper render write failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Flatten already-loaded layers into a single image. Network-free so it can
    /// be unit-tested. Returns nil when there's nothing to draw.
    @MainActor
    static func compose(_ layers: [(layer: AvatarLayer, image: UIImage)]) -> UIImage? {
        guard !layers.isEmpty else { return nil }
        let sorted = layers.sorted { $0.layer.zIndex < $1.layer.zIndex }
        let renderer = ImageRenderer(content: WallpaperCanvas(layers: sorted))
        renderer.scale = 3
        return renderer.uiImage
    }

    /// Resolve a stored wallpaper spec (remote URL or bare local filename) to a
    /// loadable local file URL, rebuilding the Documents path at call time.
    @MainActor
    static func localURL(for fileName: String) -> URL {
        LocalProfileStore.shared.assetURL(for: fileName)
    }

    @MainActor
    private static func removeOldRenderedWallpapers(except retainedFileName: String) {
        let retainedURL = localURL(for: retainedFileName)
        let directory = retainedURL.deletingLastPathComponent()
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }
        for url in contents where
            url.lastPathComponent.hasPrefix(filePrefix) &&
            url.lastPathComponent != retainedFileName {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Static, gesture-free mirror of the editor's layer layout.
    private struct WallpaperCanvas: View {
        let layers: [(layer: AvatarLayer, image: UIImage)]

        var body: some View {
            ZStack {
                Color.clear
                ForEach(layers, id: \.layer.id) { entry in
                    let layer = entry.layer
                    let size = baseSize * layer.scale
                    Image(uiImage: entry.image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .scaleEffect(layer.cropScale ?? 1.0)
                        .offset(x: layer.cropX ?? 0.0, y: layer.cropY ?? 0.0)
                        .frame(width: size, height: size)
                        .clipped()
                        .rotationEffect(.degrees(layer.rotation ?? 0.0))
                        .position(x: layer.x + size / 2.0, y: layer.y + size / 2.0)
                }
            }
            .frame(width: canvasSize, height: canvasSize)
        }
    }
}

/// Faint full-bleed background behind the feed. Accepts either a remote URL or a
/// bare local filename (the rendered "My Oshi" composition). Local files are
/// decoded once per spec change rather than on every view update.
struct WallpaperBackground: View {
    let spec: String
    @State private var localImage: UIImage?

    var body: some View {
        Group {
            if spec.hasPrefix("http"), let url = URL(string: spec) {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fit)
                } placeholder: {
                    EmptyView()
                }
            } else if let localImage {
                Image(uiImage: localImage).resizable().aspectRatio(contentMode: .fit)
            } else {
                EmptyView()
            }
        }
        .opacity(0.22)
        .ignoresSafeArea()
        .task(id: spec) {
            guard !spec.hasPrefix("http") else { localImage = nil; return }
            let path = WallpaperRenderer.localURL(for: spec).path
            localImage = UIImage(contentsOfFile: path)
        }
    }
}
