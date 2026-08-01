import SwiftUI
import UIKit

struct AppIconView: View {
    let asset: AppIconAsset?
    let appName: String
    let size: CGFloat
    private let loader: any AppIconLoading
    @State private var image: UIImage?
    @State private var isLoading = false
    @Environment(\.displayScale) private var displayScale

    init(
        asset: AppIconAsset?,
        appName: String,
        size: CGFloat = 48,
        loader: any AppIconLoading = AppIconCache.shared
    ) {
        self.asset = asset
        self.appName = appName
        self.size = size
        self.loader = loader
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                fallback
                    .overlay {
                        if isLoading {
                            ProgressView()
                                .controlSize(.mini)
                                .tint(.secondary)
                        }
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: size * 0.225))
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .stroke(.primary.opacity(0.08), lineWidth: 0.5)
        }
        .accessibilityHidden(true)
        .task(id: asset) {
            image = nil
            guard let url = asset?.resolvedURL(pointSize: max(1, Int(size.rounded(.up)))) else { return }
            isLoading = true
            defer { isLoading = false }
            do {
                let data = try await loader.data(for: url)
                guard !Task.isCancelled else { return }
                image = UIImage(data: data, scale: displayScale)
            } catch is CancellationError {
                return
            } catch {
                // A broken or unavailable icon intentionally degrades to the
                // generated local glyph without affecting dashboard data.
            }
        }
    }

    private var fallback: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .fill(.tint.opacity(0.13))
            Text(String(appName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)).uppercased())
                .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
                .foregroundStyle(.tint)
        }
    }
}
