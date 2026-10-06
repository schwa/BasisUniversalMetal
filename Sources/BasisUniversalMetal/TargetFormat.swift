import CBasisUniversal
import Metal

struct GPUCapabilities: Sendable, Equatable {
    var astcLDR: Bool
    var astcHDR: Bool
    var bc: Bool

    static let uncompressedOnly = GPUCapabilities(astcLDR: false, astcHDR: false, bc: false)

    init(astcLDR: Bool, astcHDR: Bool, bc: Bool) {
        self.astcLDR = astcLDR
        self.astcHDR = astcHDR
        self.bc = bc
    }

    init(device: MTLDevice) {
        astcLDR = device.supportsFamily(.apple2)
        astcHDR = device.supportsFamily(.apple6)
        bc = device.supportsBCTextureCompression
    }
}

struct BlockSize: Sendable, Equatable {
    var width: Int
    var height: Int
}

struct TargetFormat: Sendable, Equatable {
    var transcoderFormat: UInt32
    var pixelFormat: MTLPixelFormat
    /// nil for uncompressed (pixel) formats.
    var blockSize: BlockSize?
    var bytesPerUnit: Int

    static let astcSizes: [BlockSize] = [
        .init(width: 4, height: 4), .init(width: 5, height: 4), .init(width: 5, height: 5), .init(width: 6, height: 5),
        .init(width: 6, height: 6), .init(width: 8, height: 5), .init(width: 8, height: 6), .init(width: 8, height: 8),
        .init(width: 10, height: 5), .init(width: 10, height: 6), .init(width: 10, height: 8), .init(width: 10, height: 10),
        .init(width: 12, height: 10), .init(width: 12, height: 12),
    ]

    static func rgba32(isSRGB: Bool) -> TargetFormat {
        TargetFormat(transcoderFormat: UInt32(TF_RGBA32), pixelFormat: isSRGB ? .rgba8Unorm_srgb : .rgba8Unorm, blockSize: nil, bytesPerUnit: 4)
    }

    static let rgbaHalf = TargetFormat(transcoderFormat: UInt32(TF_RGBA_HALF), pixelFormat: .rgba16Float, blockSize: nil, bytesPerUnit: 8)

    static func bc7(isSRGB: Bool) -> TargetFormat {
        TargetFormat(transcoderFormat: UInt32(TF_BC7_RGBA), pixelFormat: isSRGB ? .bc7_rgbaUnorm_srgb : .bc7_rgbaUnorm, blockSize: .init(width: 4, height: 4), bytesPerUnit: 16)
    }

    static let bc6h = TargetFormat(transcoderFormat: UInt32(TF_BC6H), pixelFormat: .bc6H_rgbuFloat, blockSize: .init(width: 4, height: 4), bytesPerUnit: 16)

    static func choose(basisFormat: UInt32, isSRGB: Bool, capabilities: GPUCapabilities) throws -> TargetFormat {
        func ldr(_ astc: TargetFormat) -> TargetFormat {
            if capabilities.astcLDR { return astc }
            if capabilities.bc { return bc7(isSRGB: isSRGB) }
            return rgba32(isSRGB: isSRGB)
        }
        func hdr(_ astc: TargetFormat) -> TargetFormat {
            if capabilities.astcHDR { return astc }
            if capabilities.bc { return bc6h }
            return rgbaHalf
        }

        switch Int32(basisFormat) {
        case BTF_ETC1S, BTF_UASTC_LDR_4X4:
            return ldr(astcLDR(.init(width: 4, height: 4), isSRGB: isSRGB)!)
        case BTF_XUBC7:
            if capabilities.bc { return bc7(isSRGB: isSRGB) }
            return ldr(astcLDR(.init(width: 4, height: 4), isSRGB: isSRGB)!)
        case BTF_UASTC_HDR_4X4:
            return hdr(TargetFormat(transcoderFormat: UInt32(TF_ASTC_HDR_4X4_RGBA), pixelFormat: .astc_4x4_hdr, blockSize: .init(width: 4, height: 4), bytesPerUnit: 16))
        case BTF_ASTC_HDR_6X6, BTF_UASTC_HDR_6X6:
            return hdr(TargetFormat(transcoderFormat: UInt32(TF_ASTC_HDR_6X6_RGBA), pixelFormat: .astc_6x6_hdr, blockSize: .init(width: 6, height: 6), bytesPerUnit: 16))
        default:
            // XUASTC / ASTC LDR at various block sizes: transcode to the matching ASTC format.
            guard bt_basis_tex_format_is_ldr(basisFormat) != 0 else {
                throw BasisTextureError.unsupportedTexture("basis format \(basisFormat)")
            }
            let size = BlockSize(width: Int(bt_basis_tex_format_get_block_width(basisFormat)), height: Int(bt_basis_tex_format_get_block_height(basisFormat)))
            guard let astc = astcLDR(size, isSRGB: isSRGB) else {
                throw BasisTextureError.unsupportedTexture("ASTC block size \(size.width)x\(size.height)")
            }
            return ldr(astc)
        }
    }

    static func astcLDR(_ size: BlockSize, isSRGB: Bool) -> TargetFormat? {
        guard let index = astcSizes.firstIndex(of: size) else {
            return nil
        }
        let unorm: [MTLPixelFormat] = [
            .astc_4x4_ldr, .astc_5x4_ldr, .astc_5x5_ldr, .astc_6x5_ldr, .astc_6x6_ldr, .astc_8x5_ldr, .astc_8x6_ldr,
            .astc_8x8_ldr, .astc_10x5_ldr, .astc_10x6_ldr, .astc_10x8_ldr, .astc_10x10_ldr, .astc_12x10_ldr, .astc_12x12_ldr,
        ]
        let srgb: [MTLPixelFormat] = [
            .astc_4x4_srgb, .astc_5x4_srgb, .astc_5x5_srgb, .astc_6x5_srgb, .astc_6x6_srgb, .astc_8x5_srgb, .astc_8x6_srgb,
            .astc_8x8_srgb, .astc_10x5_srgb, .astc_10x6_srgb, .astc_10x8_srgb, .astc_10x10_srgb, .astc_12x10_srgb, .astc_12x12_srgb,
        ]
        let transcoderFormats: [Int32] = [
            TF_ASTC_LDR_4X4_RGBA, TF_ASTC_LDR_5X4_RGBA, TF_ASTC_LDR_5X5_RGBA, TF_ASTC_LDR_6X5_RGBA, TF_ASTC_LDR_6X6_RGBA,
            TF_ASTC_LDR_8X5_RGBA, TF_ASTC_LDR_8X6_RGBA, TF_ASTC_LDR_8X8_RGBA, TF_ASTC_LDR_10X5_RGBA, TF_ASTC_LDR_10X6_RGBA,
            TF_ASTC_LDR_10X8_RGBA, TF_ASTC_LDR_10X10_RGBA, TF_ASTC_LDR_12X10_RGBA, TF_ASTC_LDR_12X12_RGBA,
        ]
        return TargetFormat(transcoderFormat: UInt32(transcoderFormats[index]), pixelFormat: isSRGB ? srgb[index] : unorm[index], blockSize: size, bytesPerUnit: 16)
    }

    static func astcHDR(_ size: BlockSize) -> TargetFormat? {
        guard let index = astcSizes.firstIndex(of: size) else {
            return nil
        }
        let formats: [MTLPixelFormat] = [
            .astc_4x4_hdr, .astc_5x4_hdr, .astc_5x5_hdr, .astc_6x5_hdr, .astc_6x6_hdr, .astc_8x5_hdr, .astc_8x6_hdr,
            .astc_8x8_hdr, .astc_10x5_hdr, .astc_10x6_hdr, .astc_10x8_hdr, .astc_10x10_hdr, .astc_12x10_hdr, .astc_12x12_hdr,
        ]
        // Not transcoded; the raw KTX2 path copies blocks as-is.
        return TargetFormat(transcoderFormat: UInt32.max, pixelFormat: formats[index], blockSize: size, bytesPerUnit: 16)
    }
}
