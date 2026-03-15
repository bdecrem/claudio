#if os(iOS)
import UIKit
typealias PlatformImage = UIImage
#elseif os(macOS)
import AppKit
typealias PlatformImage = NSImage
#endif
import os

private let log = Logger(subsystem: "com.claudio.app", category: "MediaImageCache")

actor MediaImageCache {
    static let shared = MediaImageCache()

    private let memoryCache = NSCache<NSString, PlatformImage>()
    private let diskCacheURL: URL
    private var inFlightTasks: [String: Task<PlatformImage, Error>] = [:]

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        diskCacheURL = caches.appendingPathComponent("MediaImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskCacheURL, withIntermediateDirectories: true)
        memoryCache.totalCostLimit = 50 * 1024 * 1024 // 50MB
    }

    /// Load an image from a URL string. Handles:
    /// - Data URIs (data:image/png;base64,...)
    /// - Full HTTP(S) URLs
    /// - Relative paths (prepended with serverBaseURL)
    func image(urlString: String, serverBaseURL: String, token: String) async throws -> PlatformImage {
        // Data URIs — decode inline, no caching needed
        if urlString.hasPrefix("data:") {
            return try decodeDataURI(urlString)
        }

        let cacheKey = urlString as NSString

        // Memory cache
        if let cached = memoryCache.object(forKey: cacheKey) {
            return cached
        }

        // Disk cache
        let diskFile = diskCacheURL.appendingPathComponent(diskFileName(for: urlString))
        if let data = try? Data(contentsOf: diskFile),
           let img = PlatformImage(data: data) {
            memoryCache.setObject(img, forKey: cacheKey, cost: data.count)
            return img
        }

        // Deduplicate in-flight requests
        if let existing = inFlightTasks[urlString] {
            return try await existing.value
        }

        let task = Task<PlatformImage, Error> {
            try await fetchImage(urlString: urlString, serverBaseURL: serverBaseURL, token: token)
        }
        inFlightTasks[urlString] = task

        do {
            let img = try await task.value
            inFlightTasks[urlString] = nil
            return img
        } catch {
            inFlightTasks[urlString] = nil
            throw error
        }
    }

    // MARK: - Data URI

    private func decodeDataURI(_ uri: String) throws -> PlatformImage {
        // Format: data:image/png;base64,iVBOR...
        guard let commaIndex = uri.firstIndex(of: ",") else {
            throw URLError(.cannotDecodeContentData)
        }
        let base64String = String(uri[uri.index(after: commaIndex)...])
        guard let data = Data(base64Encoded: base64String),
              let img = PlatformImage(data: data) else {
            throw URLError(.cannotDecodeContentData)
        }
        log.info("Decoded data URI image (\(data.count) bytes)")
        return img
    }

    // MARK: - Network Fetch

    private func fetchImage(urlString: String, serverBaseURL: String, token: String) async throws -> PlatformImage {
        // Build the full URL
        let fullURLString: String
        if urlString.hasPrefix("http://") || urlString.hasPrefix("https://") {
            fullURLString = urlString
        } else {
            // Relative path — prepend server base URL
            let base = serverBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let path = urlString.hasPrefix("/") ? urlString : "/\(urlString)"
            fullURLString = base + path
        }

        guard let url = URL(string: fullURLString) else {
            log.error("Bad image URL: \(fullURLString)")
            throw URLError(.badURL)
        }

        log.info("Fetching image: \(fullURLString)")

        var request = URLRequest(url: url)
        request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            log.error("Image fetch failed: HTTP \(httpResponse.statusCode) for \(fullURLString)")
            throw URLError(.badServerResponse)
        }

        guard let img = PlatformImage(data: data) else {
            let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "unknown"
            log.error("Cannot decode image data (\(data.count) bytes, content-type: \(contentType))")
            throw URLError(.cannotDecodeContentData)
        }

        // Cache to memory + disk
        let cacheKey = urlString as NSString
        memoryCache.setObject(img, forKey: cacheKey, cost: data.count)

        let diskFile = diskCacheURL.appendingPathComponent(diskFileName(for: urlString))
        try? data.write(to: diskFile, options: .atomic)

        log.info("Cached image: \(urlString) (\(data.count) bytes)")
        return img
    }

    private func diskFileName(for path: String) -> String {
        let hash = path.utf8.reduce(into: UInt64(5381)) { hash, byte in
            hash = hash &* 33 &+ UInt64(byte)
        }
        let ext = (path as NSString).pathExtension
        return "\(hash).\(ext.isEmpty ? "img" : ext)"
    }
}
