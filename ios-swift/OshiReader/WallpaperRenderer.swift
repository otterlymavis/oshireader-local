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

    /// Filename (not absolute path) under Documents. Storing the bare name keeps
    /// it valid across launches/updates, since the container path can change.
    static let fileName = "oshi_wallpaper.png"

    @MainActor
    static func render(layers: [AvatarLayer]) async -> String? {
        // Download each layer's image up front — ImageRenderer can't resolve
        // AsyncImage, so layers must already be UIImages at render time.
        var loaded: [(layer: AvatarLayer, image: UIImage)] = []
        for layer in layers.sorted(by: { $0.zIndex < $1.zIndex }) {
            guard let url = URL(string: layer.imageUrl),
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data) else { continue }
            loaded.append((layer, image))
        }
        guard !loaded.isEmpty else { return nil }

        let renderer = ImageRenderer(content: WallpaperCanvas(layers: loaded))
        renderer.scale = 3
        guard let uiImage = renderer.uiImage, let png = uiImage.pngData() else { return nil }

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent(fileName)
        do {
            try png.write(to: url, options: .atomic)
            return fileName
        } catch {
            return nil
        }
    }

    /// Resolve a stored wallpaper spec (remote URL or bare local filename) to a
    /// loadable local file URL, rebuilding the Documents path at call time.
    static func localURL(for fileName: String) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(fileName)
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
