import CBasisUniversal
import Foundation

/// Minimal KTX2 reader for files the Basis transcoder rejects but Metal can sample directly (plain ASTC).
struct KTX2File {
    struct Level {
        var byteOffset: Int
        var byteLength: Int
        var uncompressedByteLength: Int
    }

    enum ASTCKind: Equatable {
        case ldr(BlockSize, isSRGB: Bool)
        case hdr(BlockSize)
    }

    static let identifier: [UInt8] = [0xAB, 0x4B, 0x54, 0x58, 0x20, 0x32, 0x30, 0xBB, 0x0D, 0x0A, 0x1A, 0x0A]
    static let supercompressionNone: UInt32 = 0
    static let supercompressionZstd: UInt32 = 2

    var vkFormat: UInt32
    var width: Int
    var height: Int
    var depth: Int
    var layers: Int
    var faces: Int
    var supercompressionScheme: UInt32
    var levels: [Level]

    init(_ bytes: UnsafeRawBufferPointer) throws {
        guard bytes.count >= 80, Array(bytes.prefix(12)) == Self.identifier else {
            throw BasisTextureError.invalidKTX2
        }
        func u32(_ offset: Int) -> UInt32 { UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
        func u64(_ offset: Int) -> UInt64 { UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self)) }

        vkFormat = u32(12)
        width = Int(u32(20))
        height = max(1, Int(u32(24)))
        depth = max(1, Int(u32(28)))
        layers = max(1, Int(u32(32)))
        faces = Int(u32(36))
        let levelCount = max(1, Int(u32(40)))
        supercompressionScheme = u32(44)
        guard 80 + levelCount * 24 <= bytes.count else {
            throw BasisTextureError.invalidKTX2
        }
        levels = try (0 ..< levelCount).map { index in
            let base = 80 + index * 24
            let offset = u64(base), length = u64(base + 8), uncompressed = u64(base + 16)
            guard offset <= UInt64(bytes.count), length <= UInt64(bytes.count) - offset else {
                throw BasisTextureError.invalidKTX2
            }
            return Level(byteOffset: Int(offset), byteLength: Int(length), uncompressedByteLength: Int(uncompressed))
        }
    }

    var astcKind: ASTCKind? {
        // VK_FORMAT_ASTC_4x4_UNORM_BLOCK ... VK_FORMAT_ASTC_12x12_SRGB_BLOCK, UNORM/SRGB pairs.
        if (157 ... 184).contains(vkFormat) {
            let offset = Int(vkFormat - 157)
            return .ldr(TargetFormat.astcSizes[offset / 2], isSRGB: offset % 2 == 1)
        }
        // VK_FORMAT_ASTC_4x4_SFLOAT_BLOCK ... VK_FORMAT_ASTC_12x12_SFLOAT_BLOCK.
        if (1_000_066_000 ... 1_000_066_013).contains(vkFormat) {
            return .hdr(TargetFormat.astcSizes[Int(vkFormat - 1_000_066_000)])
        }
        return nil
    }

    /// Level bytes, Zstd-decompressed if needed.
    func levelData(_ index: Int, in bytes: UnsafeRawBufferPointer) throws -> Data {
        let level = levels[index]
        let source = UnsafeRawBufferPointer(rebasing: bytes[level.byteOffset ..< level.byteOffset + level.byteLength])
        switch supercompressionScheme {
        case Self.supercompressionNone:
            return Data(source)
        case Self.supercompressionZstd:
            var output = Data(count: level.uncompressedByteLength)
            let written = output.withUnsafeMutableBytes { destination in
                ZSTD_decompress(destination.baseAddress, destination.count, source.baseAddress, source.count)
            }
            guard ZSTD_isError(written) == 0, written == level.uncompressedByteLength else {
                throw BasisTextureError.invalidKTX2
            }
            return output
        default:
            throw BasisTextureError.unsupportedTexture("KTX2 supercompression scheme \(supercompressionScheme)")
        }
    }
}
