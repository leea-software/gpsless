import Foundation
import zlib

private func compressionError(_ code: Int32) -> NSError {
    return NSError(domain: "RecordingCompression", code: Int(code), userInfo: [NSLocalizedDescriptionKey: "Recording compression failed (\(code))."])
}

/// A standard gzip member, readable by Finder, gunzip and Python. Sync flushes
/// preserve complete rows if the process stops before the gzip trailer arrives.
final class GzipEncoder {
    private var stream = z_stream()
    private let handle: FileHandle
    private var finished = false
    private(set) var bytesWritten = 0

    init(handle: FileHandle) throws {
        self.handle = handle
        let code = deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard code == Z_OK else {
            throw compressionError(code)
        }
    }

    deinit {
        deflateEnd(&stream)
    }

    func write(_ data: Data) throws {
        try process(data, flush: Z_NO_FLUSH)
    }

    func synchronizeBlock() throws {
        try process(Data(), flush: Z_SYNC_FLUSH)
    }

    func finish() throws {
        guard !finished else {
            return
        }
        try process(Data(), flush: Z_FINISH)
    }

    private func process(_ data: Data, flush: Int32) throws {
        guard !finished else {
            throw compressionError(Z_STREAM_ERROR)
        }
        try data.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(data.count)
            var output = Data(count: 65_536)
            while true {
                let code = output.withUnsafeMutableBytes { destination in
                    stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(destination.count)
                    return deflate(&stream, flush)
                }
                guard code == Z_OK || code == Z_STREAM_END || code == Z_BUF_ERROR else {
                    throw compressionError(code)
                }
                let produced = output.count - Int(stream.avail_out)
                if produced > 0 {
                    try handle.write(contentsOf: output.prefix(produced))
                    bytesWritten += produced
                }
                if code == Z_STREAM_END {
                    finished = true
                    break
                }
                if stream.avail_in == 0 && stream.avail_out > 0 && flush != Z_FINISH {
                    break
                }
                if code == Z_BUF_ERROR {
                    throw compressionError(code)
                }
            }
        }
    }
}

final class GzipDecoder {
    private var stream = z_stream()
    private var finished = false

    init() throws {
        let code = inflateInit2_(&stream, 15 + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard code == Z_OK else {
            throw compressionError(code)
        }
    }

    deinit {
        inflateEnd(&stream)
    }

    func consume(_ data: Data, receive: (Data) throws -> Void) throws {
        guard !finished else {
            throw compressionError(Z_DATA_ERROR)
        }
        try data.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(data.count)
            var output = Data(count: 65_536)
            while true {
                let code = output.withUnsafeMutableBytes { destination in
                    stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(destination.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                guard code == Z_OK || code == Z_STREAM_END || code == Z_BUF_ERROR else {
                    throw compressionError(code)
                }
                let produced = output.count - Int(stream.avail_out)
                if produced > 0 {
                    try receive(Data(output.prefix(produced)))
                }
                if code == Z_STREAM_END {
                    finished = true
                    guard stream.avail_in == 0 else {
                        throw compressionError(Z_DATA_ERROR)
                    }
                    break
                }
                if stream.avail_in == 0 && stream.avail_out > 0 {
                    break
                }
                if code == Z_BUF_ERROR {
                    throw compressionError(code)
                }
            }
        }
    }
}
