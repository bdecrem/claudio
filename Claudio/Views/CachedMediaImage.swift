import SwiftUI

struct CachedMediaImage: View {
    let relativePath: String
    let serverURL: String
    let token: String

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else if failed {
                Label("Image unavailable", systemImage: "photo")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.textDim)
                    .frame(width: 140, height: 80)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.surface)
                    .frame(width: 140, height: 80)
                    .overlay {
                        ProgressView()
                            .tint(Theme.textDim)
                    }
            }
        }
        .task(id: relativePath) {
            do {
                let img = try await MediaImageCache.shared.image(
                    relativePath: relativePath,
                    serverBaseURL: serverURL,
                    token: token
                )
                image = img
            } catch {
                failed = true
            }
        }
    }
}
