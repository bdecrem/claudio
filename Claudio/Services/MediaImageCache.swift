import UIKit
import os

private let log = Logger(subsystem: "com.claudio.app", category: "MediaImageCache")

actor MediaImageCache {
    static let shared = MediaImageCache()

    private let memoryCache = NSCache<NSString, UIImage>()
    private let diskCacheURL: URL
    private var inFlightTasks: [String: Task<UIImage, Error>] = [:]

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        diskCacheURL = caches.appendingPathComponent("MediaImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskCacheURL, withIntermediateDirectories: true)
        memoryCache.totalCostLimit = 50 * 1024 * 1024 // 50MB
    }

    func image(relativePath: String, serverBaseURL: String, token: String) async throws -> UIImage {
        let cacheKey = relativePath as NSString

        // Memory cache
        if let cached = memoryCache.object(forKey: cacheKey) {
            return cached
        }

        // Disk cache
        let diskFile = diskCacheURL.appendingPathComponent(diskFileName(for: relativePath))
        if let data = try? Data(contentsOf: diskFile),
           let img = UIImage(data: data) {
            let cost = data.count
            memoryCache.setObject(img, forKey: cacheKey, cost: cost)
            return img
        }

        // Deduplicate in-flight requests
        if let existing = inFlightTasks[relativePath] {
            return try await existing.value
        }

        let task = Task<UIImage, Error> {
            let img = try await fetchFromServer(relativePath: relativePath, serverBaseURL: serverBaseURL, token: token)
            return img
        }
        inFlightTasks[relativePath] = task

        do {
            let img = try await task.value
            inFlightTasks[relativePath] = nil
            return img
        } catch {
            inFlightTasks[relativePath] = nil
            throw error
        }
    }

    private func fetchFromServer(relativePath: String, serverBaseURL: String, token: String) async throws -> UIImage {
        let urlString = serverBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + relativePath
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }

        guard let img = UIImage(data: data) else {
            throw URLError(.cannotDecodeContentData)
        }

        // Cache to memory
        let cacheKey = relativePath as NSString
        memoryCache.setObject(img, forKey: cacheKey, cost: data.count)

        // Cache to disk
        let diskFile = diskCacheURL.appendingPathComponent(diskFileName(for: relativePath))
        try? data.write(to: diskFile, options: .atomic)

        log.info("Fetched image: \(relativePath) (\(data.count) bytes)")
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
