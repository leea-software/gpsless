import Foundation

enum FieldReferenceStore {
    static var directory: URL {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("FieldReferences", isDirectory: true)
    }

    static func recordings() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { url in
            return url.pathExtension == "jsonl"
        }.sorted { first, second in
            return first.lastPathComponent < second.lastPathComponent
        }
    }

    /// Separate, atomic files preserve reference observations even if no new
    /// drive is started. References never become replay position observations.
    @discardableResult
    static func save(_ reference: ManualReference, metadata: [String: String], mapSnapshot: String, directory: URL = directory) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var details = metadata
        details["mapSnapshot"] = mapSnapshot
        details["formatVersion"] = "3"
        let entry = DriveEntry(kind: "field-reference", reference: reference, details: details, receivedUptime: ProcessInfo.processInfo.systemUptime, wallTime: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(entry)
        data.append(0x0a)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let url = directory.appendingPathComponent("Reference_\(formatter.string(from: reference.observedAt))_\(UUID().uuidString.prefix(4)).jsonl")
        try data.write(to: url, options: .atomic)
        return url
    }
}
