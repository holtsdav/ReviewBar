import Foundation
import zlib

enum GzipDecoder {
    static func decompress(_ data: Data, maximumOutputBytes: Int = 256 * 1_024 * 1_024) throws -> Data {
        guard !data.isEmpty, data.count <= Int(UInt32.max), maximumOutputBytes > 0 else {
            throw AppError(kind: .malformedResponse, message: "The Analytics report archive is empty or too large.")
        }
        var stream = z_stream()
        let initialized = inflateInit2_(&stream, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initialized == Z_OK else {
            throw AppError(kind: .malformedResponse, message: "ReviewBar couldn't initialize Analytics decompression.")
        }
        defer { inflateEnd(&stream) }

        return try data.withUnsafeBytes { input in
            guard let inputBase = input.bindMemory(to: Bytef.self).baseAddress else {
                throw AppError(kind: .malformedResponse, message: "The Analytics report archive is empty.")
            }
            stream.next_in = UnsafeMutablePointer(mutating: inputBase)
            stream.avail_in = UInt32(data.count)
            var output = Data()
            var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
            while true {
                try Task.checkCancellation()
                let status = buffer.withUnsafeMutableBytes { bytes -> Int32 in
                    stream.next_out = bytes.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = UInt32(bytes.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let produced = buffer.count - Int(stream.avail_out)
                guard output.count + produced <= maximumOutputBytes else {
                    throw AppError(kind: .malformedResponse, message: "The Analytics report expanded beyond ReviewBar's safety limit.")
                }
                output.append(contentsOf: buffer.prefix(produced))
                if status == Z_STREAM_END { return output }
                guard status == Z_OK else {
                    throw AppError(kind: .malformedResponse, message: "The Analytics report archive is corrupt or truncated.")
                }
                guard produced > 0 || stream.avail_in > 0 else {
                    throw AppError(kind: .malformedResponse, message: "The Analytics report archive ended unexpectedly.")
                }
            }
        }
    }
}
