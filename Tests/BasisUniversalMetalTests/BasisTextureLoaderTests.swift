@testable import BasisUniversalMetal
import CBasisUniversal
import Foundation
import Metal
import Testing

struct Expectation: Sendable, CustomStringConvertible {
    var name: String
    var width: Int
    var height: Int
    var mipmapLevelCount: Int
    var textureType: MTLTextureType = .type2D
    var arrayLength = 1
    var isHDR = false
    var description: String { name }
}

func resourceData(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "ktx2", subdirectory: "Resources"))
    return try Data(contentsOf: url)
}

func makeDevice() throws -> MTLDevice {
    try #require(MTLCreateSystemDefaultDevice())
}

struct BasisTextureLoaderTests {
    static let expectations: [Expectation] = [
        // KHR_texture_basisu formats.
        .init(name: "etc1s_mips", width: 768, height: 512, mipmapLevelCount: 10),
        .init(name: "etc1s_alpha", width: 256, height: 256, mipmapLevelCount: 1),
        .init(name: "uastc_mips", width: 768, height: 512, mipmapLevelCount: 10),
        .init(name: "etc1s_cube", width: 256, height: 256, mipmapLevelCount: 9, textureType: .typeCube),
        .init(name: "uastc_array", width: 256, height: 256, mipmapLevelCount: 9, textureType: .type2DArray, arrayLength: 3),
        // Newer Basis formats.
        .init(name: "uastc_hdr", width: 644, height: 874, mipmapLevelCount: 10, isHDR: true),
        .init(name: "uastc_hdr_nozstd", width: 256, height: 170, mipmapLevelCount: 9, isHDR: true),
        .init(name: "kodim01", width: 768, height: 512, mipmapLevelCount: 1),
        .init(name: "kodim23", width: 768, height: 512, mipmapLevelCount: 1),
        .init(name: "base_xuastc_arith", width: 512, height: 512, mipmapLevelCount: 1),
        .init(name: "base_xuastc_zstd", width: 512, height: 512, mipmapLevelCount: 1),
        .init(name: "t6x6", width: 1024, height: 1024, mipmapLevelCount: 11),
        .init(name: "kodim26_xubc7", width: 1118, height: 1105, mipmapLevelCount: 11),
        // Plain ASTC (EXT_texture_astc), read by the Basis transcoder.
        .init(name: "astc_6x6_srgb", width: 256, height: 256, mipmapLevelCount: 1),
        .init(name: "astc_8x8_srgb_zstd", width: 256, height: 256, mipmapLevelCount: 9),
    ]

    static let twoDimensional = expectations.filter { $0.textureType == .type2D }

    static func load(_ name: String, forceUncompressed: Bool = false) throws -> MTLTexture {
        try BasisTextureLoader(device: makeDevice(), forceUncompressed: forceUncompressed).makeTexture(from: resourceData(name))
    }

    @Test(arguments: expectations, [false, true])
    func loads(expectation: Expectation, forceUncompressed: Bool) throws {
        let texture = try Self.load(expectation.name, forceUncompressed: forceUncompressed)
        #expect(texture.width == expectation.width)
        #expect(texture.height == expectation.height)
        #expect(texture.mipmapLevelCount == expectation.mipmapLevelCount)
        #expect(texture.textureType == expectation.textureType)
        #expect(texture.arrayLength == expectation.arrayLength)
        if forceUncompressed {
            let expected: [MTLPixelFormat] = expectation.isHDR ? [.rgba16Float] : [.rgba8Unorm, .rgba8Unorm_srgb]
            #expect(expected.contains(texture.pixelFormat))
        }
    }

    @Test(arguments: ["etc1s_mips", "uastc_mips", "kodim23", "kodim26_xubc7", "t6x6"])
    func uncompressedPixelsLookSane(name: String) throws {
        let texture = try Self.load(name, forceUncompressed: true)
        var pixels = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        texture.getBytes(&pixels, bytesPerRow: texture.width * 4, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        // A real photo has many distinct colors; an all-zero or garbage-constant buffer does not.
        var distinct = Set<UInt32>()
        for index in stride(from: 0, to: pixels.count, by: 4 * 97) {
            distinct.insert(UInt32(pixels[index]) << 16 | UInt32(pixels[index + 1]) << 8 | UInt32(pixels[index + 2]))
        }
        #expect(distinct.count > 100)
        if let directory = ProcessInfo.processInfo.environment["BASISU_DUMP_DIR"] {
            var ppm = Data("P6\n\(texture.width) \(texture.height)\n255\n".utf8)
            for index in stride(from: 0, to: pixels.count, by: 4) {
                ppm.append(contentsOf: pixels[index ..< index + 3])
            }
            try ppm.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).ppm"))
        }
    }

    /// Issue #5: compressed texel data is checked by sampling it on the GPU.
    @Test(arguments: twoDimensional)
    func compressedMatchesUncompressed(expectation: Expectation) throws {
        let readback = try GPUReadback(device: makeDevice())
        let compressed = try Self.load(expectation.name)
        let uncompressed = try Self.load(expectation.name, forceUncompressed: true)
        #expect(compressed.pixelFormat != uncompressed.pixelFormat)
        let error = GPUReadback.error(try readback.read(compressed), reference: try readback.read(uncompressed), isHDR: expectation.isHDR)
        #expect(error < (expectation.isHDR ? 0.05 : 0.01), "\(expectation.name) \(compressed.pixelFormat.rawValue): \(error)")
    }

    /// Issue #6: the BC7/BC6H fallback, forced on GPUs that support both ASTC and BC.
    @Test(arguments: twoDimensional)
    func bcFallbackMatchesUncompressed(expectation: Expectation) throws {
        let device = try makeDevice()
        try #require(device.supportsBCTextureCompression)
        var loader = BasisTextureLoader(device: device)
        loader.capabilities = GPUCapabilities(astcLDR: false, astcHDR: false, bc: true)
        let bc = try loader.makeTexture(from: resourceData(expectation.name))
        let expectedFormats: [MTLPixelFormat] = expectation.isHDR ? [.bc6H_rgbuFloat] : [.bc7_rgbaUnorm, .bc7_rgbaUnorm_srgb]
        #expect(expectedFormats.contains(bc.pixelFormat))
        let uncompressed = try Self.load(expectation.name, forceUncompressed: true)
        let readback = try GPUReadback(device: device)
        let error = GPUReadback.error(try readback.read(bc), reference: try readback.read(uncompressed), isHDR: expectation.isHDR)
        #expect(error < (expectation.isHDR ? 0.05 : 0.01), "\(expectation.name): \(error)")
    }

    /// Issue #7: upstream's bt_ktx2_create_transcode_state() breaks level 0 of Zstd files; the loader must avoid it.
    @Test(arguments: ["uastc_mips", "uastc_array", "uastc_hdr"])
    func zstdLevelZeroTranscodes(name: String) throws {
        let texture = try Self.load(name, forceUncompressed: true)
        let pixels = try GPUReadback(device: makeDevice()).read(texture)
        #expect(pixels.contains { $0.x > 0.01 || $0.y > 0.01 || $0.z > 0.01 })
    }

    @Test
    func rejectsGarbage() throws {
        #expect(throws: BasisTextureError.invalidKTX2) {
            try BasisTextureLoader(device: makeDevice()).makeTexture(from: Data(repeating: 7, count: 64))
        }
    }
}

/// Issue #6: format choice for each kind of GPU.
struct TargetFormatTests {
    static let astcOnly = GPUCapabilities(astcLDR: true, astcHDR: true, bc: false)
    static let bcOnly = GPUCapabilities(astcLDR: false, astcHDR: false, bc: true)
    static let astcLDROnly = GPUCapabilities(astcLDR: true, astcHDR: false, bc: false)

    @Test
    func ldr() throws {
        #expect(try TargetFormat.choose(basisFormat: 0, isSRGB: true, capabilities: Self.astcOnly).pixelFormat == .astc_4x4_srgb)
        #expect(try TargetFormat.choose(basisFormat: 0, isSRGB: true, capabilities: Self.bcOnly).pixelFormat == .bc7_rgbaUnorm_srgb)
        #expect(try TargetFormat.choose(basisFormat: 0, isSRGB: false, capabilities: Self.bcOnly).pixelFormat == .bc7_rgbaUnorm)
        #expect(try TargetFormat.choose(basisFormat: 0, isSRGB: true, capabilities: .uncompressedOnly).pixelFormat == .rgba8Unorm_srgb)
    }

    @Test
    func hdr() throws {
        let uastcHDR4x4: UInt32 = 2
        #expect(try TargetFormat.choose(basisFormat: uastcHDR4x4, isSRGB: false, capabilities: Self.astcOnly).pixelFormat == .astc_4x4_hdr)
        #expect(try TargetFormat.choose(basisFormat: uastcHDR4x4, isSRGB: false, capabilities: Self.astcLDROnly).pixelFormat == .rgba16Float)
        #expect(try TargetFormat.choose(basisFormat: uastcHDR4x4, isSRGB: false, capabilities: Self.bcOnly).pixelFormat == .bc6H_rgbuFloat)
    }

    @Test
    func astcBlockSizesMapToMatchingTranscoderFormats() throws {
        // BTF_ASTC_LDR_4X4 (19) ... BTF_ASTC_LDR_12X12 (32) and the XUASTC equivalents (5...18).
        for basisFormat in UInt32(5) ... 32 {
            let size = BlockSize(width: Int(bt_basis_tex_format_get_block_width(basisFormat)), height: Int(bt_basis_tex_format_get_block_height(basisFormat)))
            let target = try TargetFormat.choose(basisFormat: basisFormat, isSRGB: false, capabilities: Self.astcOnly)
            #expect(target.blockSize == size)
            #expect(bt_basis_get_block_width(target.transcoderFormat) == UInt32(size.width))
            #expect(bt_basis_get_block_height(target.transcoderFormat) == UInt32(size.height))
        }
    }
}

/// Issues #1, #2, #4, #9: loading options.
struct LoadingOptionsTests {
    @Test(arguments: [false, true])
    func colorSpaceOverride(forceUncompressed: Bool) throws {
        let device = try makeDevice()
        let loader = BasisTextureLoader(device: device, forceUncompressed: forceUncompressed)
        let data = try resourceData("etc1s_mips")
        let fromFile = try loader.makeTexture(from: data)
        let sRGB = try loader.makeTexture(from: data, colorSpace: .sRGB)
        let linear = try loader.makeTexture(from: data, colorSpace: .linear)
        #expect(fromFile.pixelFormat == sRGB.pixelFormat)
        #expect(linear.pixelFormat == (forceUncompressed ? .rgba8Unorm : .astc_4x4_ldr))
        #expect(sRGB.pixelFormat == (forceUncompressed ? .rgba8Unorm_srgb : .astc_4x4_srgb))
        let readback = try GPUReadback(device: device)
        #expect(GPUReadback.meanAbsoluteError(try readback.read(sRGB), try readback.read(linear)) > 0.05)
    }

    @Test
    func generatesMipmapsForSingleLevelFiles() throws {
        let device = try makeDevice()
        let loader = BasisTextureLoader(device: device)
        let texture = try loader.makeTexture(from: resourceData("kodim23"), generateMipmaps: true)
        #expect(texture.mipmapLevelCount == 10)
        #expect(texture.pixelFormat == .rgba8Unorm_srgb)
        let readback = try GPUReadback(device: device)
        let level0 = try readback.read(texture, level: 0)
        let level4 = try readback.read(texture, level: 4)
        // A generated level should average roughly to the same color as level 0.
        let average0 = level0.reduce(SIMD4<Float>(), +) / Float(level0.count)
        let average4 = level4.reduce(SIMD4<Float>(), +) / Float(level4.count)
        let drift = average0 - average4
        #expect(max(abs(drift.x), abs(drift.y), abs(drift.z)) < 0.03)
        #expect(level4.contains { $0.x > 0.01 })
    }

    @Test
    func generateMipmapsKeepsExistingChain() throws {
        let texture = try BasisTextureLoader(device: makeDevice()).makeTexture(from: resourceData("uastc_mips"), generateMipmaps: true)
        #expect(texture.mipmapLevelCount == 10)
        #expect(texture.pixelFormat != .rgba8Unorm_srgb)
    }

    @Test(arguments: ["uastc_mips", "etc1s_cube", "uastc_hdr", "kodim23"], [false, true])
    func privateStorageMatchesShared(name: String, generateMipmaps: Bool) throws {
        let device = try makeDevice()
        let loader = BasisTextureLoader(device: device)
        let data = try resourceData(name)
        let shared = try loader.makeTexture(from: data, generateMipmaps: generateMipmaps)
        let gpuOnly = try loader.makeTexture(from: data, generateMipmaps: generateMipmaps, storageMode: .private)
        #expect(gpuOnly.storageMode == .private)
        #expect(gpuOnly.mipmapLevelCount == shared.mipmapLevelCount)
        guard shared.textureType == .type2D else { return }
        let readback = try GPUReadback(device: device)
        for level in [0, shared.mipmapLevelCount - 1] {
            #expect(GPUReadback.meanAbsoluteError(try readback.read(shared, level: level), try readback.read(gpuOnly, level: level)) == 0)
        }
    }

    /// Issue #9: standard ASTC HDR 4x4 KTX2 (DFD color model ASTC) is rejected by the Basis transcoder.
    @Test(arguments: ["uastc_hdr", "uastc_hdr_nozstd"])
    func plainASTCHDRFile(name: String) throws {
        let device = try makeDevice()
        try #require(device.supportsFamily(.apple6))
        let original = try resourceData(name)
        var plain = original
        let dfdOffset = Int(original.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 48, as: UInt32.self) })
        let dfModelUASTCHDR4x4: UInt8 = 167
        let dfModelASTC: UInt8 = 162
        #expect(plain[dfdOffset + 12] == dfModelUASTCHDR4x4)
        plain[dfdOffset + 12] = dfModelASTC
        let loader = BasisTextureLoader(device: device)
        let basis = try loader.makeTexture(from: original)
        let raw = try loader.makeTexture(from: plain)
        #expect(raw.pixelFormat == .astc_4x4_hdr)
        #expect(raw.mipmapLevelCount == basis.mipmapLevelCount)
        let readback = try GPUReadback(device: device)
        for level in 0 ..< raw.mipmapLevelCount {
            #expect(GPUReadback.meanAbsoluteError(try readback.read(basis, level: level), try readback.read(raw, level: level)) == 0)
        }
        #expect(throws: BasisTextureError.self) {
            try BasisTextureLoader(device: device, forceUncompressed: true).makeTexture(from: plain)
        }
    }
}
