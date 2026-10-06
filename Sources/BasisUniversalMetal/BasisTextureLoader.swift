import CBasisUniversal
import Foundation
import Metal

public enum BasisTextureError: Error, Equatable {
    case invalidKTX2
    case startTranscodingFailed
    case unsupportedTexture(String)
    case textureCreationFailed
    case transcodeFailed(level: Int, layer: Int, face: Int)
}

/// Transcodes KTX2 + Basis Universal data (as used by `KHR_texture_basisu`) into an `MTLTexture`.
public struct BasisTextureLoader: Sendable {
    public let device: MTLDevice
    /// When true, always transcode to uncompressed RGBA8 / RGBA16F (CPU-readable, larger).
    public var forceUncompressed: Bool

    public init(device: MTLDevice, forceUncompressed: Bool = false) {
        Self.initializeOnce
        self.device = device
        self.forceUncompressed = forceUncompressed
    }

    private static let initializeOnce: Void = bt_init()

    public func makeTexture(from data: Data, usage: MTLTextureUsage = .shaderRead, label: String? = nil) throws -> MTLTexture {
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress, buffer.count >= 4, buffer.count <= Int(UInt32.max) else {
                throw BasisTextureError.invalidKTX2
            }
            let handle = bt_ktx2_open(UInt64(UInt(bitPattern: base)), UInt32(buffer.count))
            guard handle != 0 else {
                throw BasisTextureError.invalidKTX2
            }
            defer { bt_ktx2_close(handle) }
            guard bt_ktx2_start_transcoding(handle) != 0 else {
                throw BasisTextureError.startTranscodingFailed
            }
            return try transcode(handle: handle, usage: usage, label: label)
        }
    }

    private func transcode(handle: UInt64, usage: MTLTextureUsage, label: String?) throws -> MTLTexture {
        let width = Int(bt_ktx2_get_width(handle))
        let height = Int(bt_ktx2_get_height(handle))
        let levels = max(1, Int(bt_ktx2_get_levels(handle)))
        let faces = max(1, Int(bt_ktx2_get_faces(handle)))
        let layers = max(1, Int(bt_ktx2_get_layers(handle)))
        guard bt_ktx2_is_video(handle) == 0 else {
            throw BasisTextureError.unsupportedTexture("video KTX2 files are not supported")
        }
        guard faces == 1 || faces == 6 else {
            throw BasisTextureError.unsupportedTexture("faces = \(faces)")
        }

        let target = try TargetFormat.choose(
            basisFormat: bt_ktx2_get_basis_tex_format(handle),
            isSRGB: bt_ktx2_is_srgb(handle) != 0,
            device: device,
            forceUncompressed: forceUncompressed
        )

        let descriptor = MTLTextureDescriptor()
        descriptor.pixelFormat = target.pixelFormat
        descriptor.width = width
        descriptor.height = height
        descriptor.mipmapLevelCount = levels
        descriptor.usage = usage
        switch (faces, layers) {
        case (1, 1):
            descriptor.textureType = .type2D
        case (1, _):
            descriptor.textureType = .type2DArray
            descriptor.arrayLength = layers
        case (6, 1):
            descriptor.textureType = .typeCube
        default:
            descriptor.textureType = .typeCubeArray
            descriptor.arrayLength = layers
        }
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw BasisTextureError.textureCreationFailed
        }
        texture.label = label

        let bytesPerUnit = Int(bt_basis_get_bytes_per_block_or_pixel(target.transcoderFormat))
        var output: [UInt8] = []
        for level in 0 ..< levels {
            let levelWidth = max(1, width >> level)
            let levelHeight = max(1, height >> level)
            let unitsX: Int
            let unitsY: Int
            if let block = target.blockSize {
                unitsX = (levelWidth + block.width - 1) / block.width
                unitsY = (levelHeight + block.height - 1) / block.height
            } else {
                unitsX = levelWidth
                unitsY = levelHeight
            }
            let unitCount = unitsX * unitsY
            output.removeAll(keepingCapacity: true)
            output.append(contentsOf: repeatElement(0, count: unitCount * bytesPerUnit))

            for layer in 0 ..< layers {
                for face in 0 ..< faces {
                    try output.withUnsafeMutableBytes { outputBuffer in
                        let ok = bt_ktx2_transcode_image_level(
                            handle, UInt32(level), UInt32(layer), UInt32(face),
                            UInt64(UInt(bitPattern: outputBuffer.baseAddress)),
                            UInt32(unitCount), target.transcoderFormat, 0,
                            // State 0 = the handle's own state. Don't use bt_ktx2_create_transcode_state():
                            // it zero-inits the cached level index, breaking level 0 of Zstd files.
                            0, 0, -1, -1, 0
                        )
                        guard ok != 0 else {
                            throw BasisTextureError.transcodeFailed(level: level, layer: layer, face: face)
                        }
                        texture.replace(
                            region: MTLRegionMake2D(0, 0, levelWidth, levelHeight),
                            mipmapLevel: level,
                            slice: layer * faces + face,
                            withBytes: outputBuffer.baseAddress!,
                            bytesPerRow: unitsX * bytesPerUnit,
                            bytesPerImage: 0
                        )
                    }
                }
            }
        }
        return texture
    }
}

struct TargetFormat {
    var transcoderFormat: UInt32
    var pixelFormat: MTLPixelFormat
    var blockSize: (width: Int, height: Int)?

    static func choose(basisFormat: UInt32, isSRGB: Bool, device: MTLDevice, forceUncompressed: Bool) throws -> TargetFormat {
        let supportsASTC = !forceUncompressed && device.supportsFamily(.apple2)
        let supportsASTCHDR = !forceUncompressed && device.supportsFamily(.apple6)
        let supportsBC = !forceUncompressed && device.supportsBCTextureCompression

        func rgba32() -> TargetFormat {
            TargetFormat(transcoderFormat: UInt32(TF_RGBA32), pixelFormat: isSRGB ? .rgba8Unorm_srgb : .rgba8Unorm, blockSize: nil)
        }
        func bc7() -> TargetFormat {
            TargetFormat(transcoderFormat: UInt32(TF_BC7_RGBA), pixelFormat: isSRGB ? .bc7_rgbaUnorm_srgb : .bc7_rgbaUnorm, blockSize: (4, 4))
        }
        func ldr(_ preferredASTC: TargetFormat) -> TargetFormat {
            if supportsASTC { return preferredASTC }
            if supportsBC { return bc7() }
            return rgba32()
        }
        func hdr(_ preferredASTC: TargetFormat) -> TargetFormat {
            if supportsASTCHDR { return preferredASTC }
            if supportsBC { return TargetFormat(transcoderFormat: UInt32(TF_BC6H), pixelFormat: .bc6H_rgbuFloat, blockSize: (4, 4)) }
            return TargetFormat(transcoderFormat: UInt32(TF_RGBA_HALF), pixelFormat: .rgba16Float, blockSize: nil)
        }

        switch Int32(basisFormat) {
        case BTF_ETC1S, BTF_UASTC_LDR_4X4:
            return ldr(astcLDR(4, 4, isSRGB: isSRGB)!)
        case BTF_XUBC7:
            if supportsBC { return bc7() }
            return ldr(astcLDR(4, 4, isSRGB: isSRGB)!)
        case BTF_UASTC_HDR_4X4:
            return hdr(TargetFormat(transcoderFormat: UInt32(TF_ASTC_HDR_4X4_RGBA), pixelFormat: .astc_4x4_hdr, blockSize: (4, 4)))
        case BTF_ASTC_HDR_6X6, BTF_UASTC_HDR_6X6:
            return hdr(TargetFormat(transcoderFormat: UInt32(TF_ASTC_HDR_6X6_RGBA), pixelFormat: .astc_6x6_hdr, blockSize: (6, 6)))
        default:
            // XUASTC / ASTC LDR at various block sizes: transcode to the matching ASTC format.
            guard bt_basis_tex_format_is_ldr(basisFormat) != 0 else {
                throw BasisTextureError.unsupportedTexture("basis format \(basisFormat)")
            }
            let width = Int(bt_basis_tex_format_get_block_width(basisFormat))
            let height = Int(bt_basis_tex_format_get_block_height(basisFormat))
            guard let astc = astcLDR(width, height, isSRGB: isSRGB) else {
                throw BasisTextureError.unsupportedTexture("ASTC block size \(width)x\(height)")
            }
            return ldr(astc)
        }
    }

    static func astcLDR(_ width: Int, _ height: Int, isSRGB: Bool) -> TargetFormat? {
        let entry: (Int32, MTLPixelFormat, MTLPixelFormat)
        switch (width, height) {
        case (4, 4): entry = (TF_ASTC_LDR_4X4_RGBA, .astc_4x4_ldr, .astc_4x4_srgb)
        case (5, 4): entry = (TF_ASTC_LDR_5X4_RGBA, .astc_5x4_ldr, .astc_5x4_srgb)
        case (5, 5): entry = (TF_ASTC_LDR_5X5_RGBA, .astc_5x5_ldr, .astc_5x5_srgb)
        case (6, 5): entry = (TF_ASTC_LDR_6X5_RGBA, .astc_6x5_ldr, .astc_6x5_srgb)
        case (6, 6): entry = (TF_ASTC_LDR_6X6_RGBA, .astc_6x6_ldr, .astc_6x6_srgb)
        case (8, 5): entry = (TF_ASTC_LDR_8X5_RGBA, .astc_8x5_ldr, .astc_8x5_srgb)
        case (8, 6): entry = (TF_ASTC_LDR_8X6_RGBA, .astc_8x6_ldr, .astc_8x6_srgb)
        case (8, 8): entry = (TF_ASTC_LDR_8X8_RGBA, .astc_8x8_ldr, .astc_8x8_srgb)
        case (10, 5): entry = (TF_ASTC_LDR_10X5_RGBA, .astc_10x5_ldr, .astc_10x5_srgb)
        case (10, 6): entry = (TF_ASTC_LDR_10X6_RGBA, .astc_10x6_ldr, .astc_10x6_srgb)
        case (10, 8): entry = (TF_ASTC_LDR_10X8_RGBA, .astc_10x8_ldr, .astc_10x8_srgb)
        case (10, 10): entry = (TF_ASTC_LDR_10X10_RGBA, .astc_10x10_ldr, .astc_10x10_srgb)
        case (12, 10): entry = (TF_ASTC_LDR_12X10_RGBA, .astc_12x10_ldr, .astc_12x10_srgb)
        case (12, 12): entry = (TF_ASTC_LDR_12X12_RGBA, .astc_12x12_ldr, .astc_12x12_srgb)
        default: return nil
        }
        return TargetFormat(transcoderFormat: UInt32(entry.0), pixelFormat: isSRGB ? entry.2 : entry.1, blockSize: (width, height))
    }
}
