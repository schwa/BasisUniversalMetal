import BasisUniversalMetal
import Foundation
import Metal
import Testing

struct Expectation: Sendable, CustomStringConvertible {
    var name: String
    var width: Int
    var height: Int
    var mipmapLevelCount: Int
    var textureType: MTLTextureType
    var arrayLength = 1
    var isHDR = false
    var description: String { name }
}

struct BasisTextureLoaderTests {
    static let expectations: [Expectation] = [
        // KHR_texture_basisu formats.
        .init(name: "etc1s_mips", width: 768, height: 512, mipmapLevelCount: 10, textureType: .type2D),
        .init(name: "etc1s_alpha", width: 256, height: 256, mipmapLevelCount: 1, textureType: .type2D),
        .init(name: "uastc_mips", width: 768, height: 512, mipmapLevelCount: 10, textureType: .type2D),
        .init(name: "etc1s_cube", width: 256, height: 256, mipmapLevelCount: 9, textureType: .typeCube),
        .init(name: "uastc_array", width: 256, height: 256, mipmapLevelCount: 9, textureType: .type2DArray, arrayLength: 3),
        // Newer Basis formats.
        .init(name: "uastc_hdr", width: 644, height: 874, mipmapLevelCount: 10, textureType: .type2D, isHDR: true),
        .init(name: "kodim01", width: 768, height: 512, mipmapLevelCount: 1, textureType: .type2D),
        .init(name: "kodim23", width: 768, height: 512, mipmapLevelCount: 1, textureType: .type2D),
        .init(name: "base_xuastc_arith", width: 512, height: 512, mipmapLevelCount: 1, textureType: .type2D),
        .init(name: "base_xuastc_zstd", width: 512, height: 512, mipmapLevelCount: 1, textureType: .type2D),
        .init(name: "t6x6", width: 1024, height: 1024, mipmapLevelCount: 11, textureType: .type2D),
        .init(name: "kodim26_xubc7", width: 1118, height: 1105, mipmapLevelCount: 11, textureType: .type2D),
    ]

    static func load(_ name: String, forceUncompressed: Bool = false) throws -> MTLTexture {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "ktx2", subdirectory: "Resources"))
        return try BasisTextureLoader(device: device, forceUncompressed: forceUncompressed).makeTexture(from: Data(contentsOf: url))
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

    @Test
    func rejectsGarbage() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        #expect(throws: BasisTextureError.invalidKTX2) {
            try BasisTextureLoader(device: device).makeTexture(from: Data(repeating: 7, count: 64))
        }
    }
}
