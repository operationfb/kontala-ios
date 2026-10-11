import Foundation

#if canImport(zlib)
    import zlib
#elseif canImport(CZlib)
    import CZlib
#endif

/// [data] compressed as gzip, RFC 1952, with zlib, which Apple's SDKs and every Linux the tests run on carry: nil
/// where zlib refused, which sends the body as it is.
package func gzip(_ data: Data) -> Data? {
    var stream = z_stream()
    // A window of 15 bits, plus 16 for gzip's header and trailer rather than zlib's.
    let started = deflateInit2_(
        &stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION,
        Int32(MemoryLayout<z_stream>.size))
    guard started == Z_OK else { return nil }
    defer { deflateEnd(&stream) }
    var input = [UInt8](data)
    var out = Data()
    var buffer = [UInt8](repeating: 0, count: 16 * 1024)
    let status: Int32 = input.withUnsafeMutableBufferPointer { inBuf -> Int32 in
        stream.next_in = inBuf.baseAddress
        stream.avail_in = uInt(inBuf.count)
        var result = Z_OK
        repeat {
            result = buffer.withUnsafeMutableBufferPointer { outBuf -> Int32 in
                stream.next_out = outBuf.baseAddress
                stream.avail_out = uInt(outBuf.count)
                let r = deflate(&stream, Z_FINISH)
                out.append(outBuf.baseAddress!, count: outBuf.count - Int(stream.avail_out))
                return r
            }
        } while result == Z_OK
        return result
    }
    return status == Z_STREAM_END ? out : nil
}

/// [data] decompressed from gzip, for the tests' collector: nil where it is not gzip.
package func gunzip(_ data: Data) -> Data? {
    var stream = z_stream()
    guard inflateInit2_(&stream, 15 + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
        return nil
    }
    defer { inflateEnd(&stream) }
    var input = [UInt8](data)
    var out = Data()
    var buffer = [UInt8](repeating: 0, count: 16 * 1024)
    let status: Int32 = input.withUnsafeMutableBufferPointer { inBuf -> Int32 in
        stream.next_in = inBuf.baseAddress
        stream.avail_in = uInt(inBuf.count)
        var result = Z_OK
        repeat {
            result = buffer.withUnsafeMutableBufferPointer { outBuf -> Int32 in
                stream.next_out = outBuf.baseAddress
                stream.avail_out = uInt(outBuf.count)
                let r = inflate(&stream, Z_NO_FLUSH)
                out.append(outBuf.baseAddress!, count: outBuf.count - Int(stream.avail_out))
                return r
            }
        } while result == Z_OK
        return result
    }
    return status == Z_STREAM_END ? out : nil
}
