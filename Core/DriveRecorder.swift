import Foundation

/// Owned by the motion queue. A complete drive is an exportable JSON-lines file.
final class DriveRecorder {
    private let encoder = JSONEncoder()
    private var handle: FileHandle?
    private var compressor: GzipEncoder?
    private var buffer = Data()
    private var size = 0
    private var lastFlush = 0.0
    private var lastStorageCheck = 0.0
    private var lastSynchronize = 0.0
    private var sequence = 0
    private var counts: [String: Int] = [:]
    private let recordingDirectory: URL
    private(set) var url: URL?
    private(set) var failure: String?

    var bytesOnDisk: Int {
        return compressor?.bytesWritten ?? 0
    }

    init(directory: URL = DriveRecorder.directory) {
        recordingDirectory = directory
    }

    static var directory: URL {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Drives", isDirectory: true)
    }

    static func recordings() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return urls.filter { url in
            return url.pathExtension == "jsonl" || url.lastPathComponent.hasSuffix(".jsonl.gz")
        }.sorted { first, second in
            // Names are Region_yyyy-MM-dd_HH-mm-ss_XXXX: newest first across regions.
            return Self.sortKey(first) > Self.sortKey(second)
        }
    }

    private static func sortKey(_ url: URL) -> String {
        let parts = url.lastPathComponent.split(separator: "_", maxSplits: 1)
        return String(parts.last ?? "")
    }

    func begin(header: DriveHeader) throws {
        try FileManager.default.createDirectory(at: recordingDirectory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let region = (header.metadata?["mapRegion"] ?? "kyiv").capitalized
        let name = "\(region)_\(formatter.string(from: Date()))_\(UUID().uuidString.prefix(4)).jsonl.gz"
        let destination = recordingDirectory.appendingPathComponent(name)
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let file = try FileHandle(forWritingTo: destination)
        handle = file
        compressor = try GzipEncoder(handle: file)
        url = destination
        encoder.dateEncodingStrategy = .iso8601
        write(DriveEntry(kind: "header", header: header))
        flush()
        if let failure {
            try? handle?.close()
            handle = nil
            throw NSError(domain: "Recording", code: 2, userInfo: [NSLocalizedDescriptionKey: failure])
        }
    }

    func write(_ entry: DriveEntry) {
        guard handle != nil, failure == nil else {
            return
        }
        do {
            var entry = entry
            sequence += 1
            entry.sequence = sequence
            entry.receivedUptime = ProcessInfo.processInfo.systemUptime
            let encoded = try encoder.encode(entry)
            counts[entry.kind, default: 0] += 1
            buffer.append(encoded)
            buffer.append(0x0a)
            let now = ProcessInfo.processInfo.systemUptime
            if buffer.count > 65_536 || now - lastFlush > 2 {
                flush()
                lastFlush = now
            }
        } catch {
            failure = "Could not record drive: \(error.localizedDescription)"
        }
    }

    func finish(reason: String) {
        var metrics: [String: Double] = ["uncompressedBytesBeforeFooter": Double(size + buffer.count), "compressedBytesBeforeFooter": Double(bytesOnDisk)]
        for (kind, count) in counts {
            metrics["rows.\(kind)"] = Double(count)
        }
        write(DriveEntry(kind: "footer", event: reason, metrics: metrics, wallTime: Date()))
        flush()
        do {
            try compressor?.finish()
            try handle?.synchronize()
            try handle?.close()
        } catch {
            failure = error.localizedDescription
        }
        handle = nil
    }

    private func flush() {
        guard !buffer.isEmpty else {
            return
        }
        do {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastStorageCheck > 10, let url {
                lastStorageCheck = now
                let available = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
                if let available, available < 128_000_000 {
                    failure = "Storage is almost full. Recording stopped; tracking continues. Export or remove old drives."
                    let notice = try encoder.encode(DriveEntry(kind: "recording-error", event: failure, receivedUptime: now, wallTime: Date()))
                    buffer.append(notice)
                    buffer.append(0x0a)
                }
            }
            try compressor?.write(buffer)
            try compressor?.synchronizeBlock()
            size += buffer.count
            buffer.removeAll(keepingCapacity: true)
            if now - lastSynchronize >= 5 {
                try handle?.synchronize()
                lastSynchronize = now
            }
        } catch {
            failure = "Drive recording failed: \(error.localizedDescription)"
        }
    }
}
