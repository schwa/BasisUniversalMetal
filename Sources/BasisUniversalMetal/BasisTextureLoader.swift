import CBasisUniversal
import Foundation
import Metal

public enum BasisTextureError: Error, Equatable {
    case invalidKTX2
    case startTranscodingFailed
    case unsupportedTexture(String)
    case textureCreationFailed
    case transcodeFailed(level: Int, layer: Int, face: Int)
    case uploadFailed(String)
}

/// Transcodes KTX2 + Basis Universal data (as used by `KHR_texture_basisu`) into an `MTLTexture`.
/// Also loads plain ASTC KTX2 files (`EXT_texture_astc`).
public struct BasisTextureLoader: @unchecked Sendable {
    public enum ColorSpace: Sendable {
        /// Use the KTX2 file's transfer function.
        case fromFile
        case sRGB
        case linear
    }

    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    /// When true, always transcode to uncompressed RGBA8 / RGBA16F (larger, but CPU-readable and mipmap-generatable).
    public var forceUncompressed: Bool
    var capabilities: GPUCapabilities

    public init(device: MTLDevice, commandQueue: MTLCommandQueue? = nil, forceUncompressed: Bool = false) {
        Self.initializeOnce
        self.device = device
        self.commandQueue = commandQueue ?? device.makeCommandQueue()!
        self.forceUncompressed = forceUncompressed
        capabilities = GPUCapabilities(device: device)
    }

    private static let initializeOnce: Void = bt_init()

    /// - Parameters:
    ///   - colorSpace: overrides the file's sRGB/linear flag (glTF decides this by material slot). Ignored for HDR.
    ///   - generateMipmaps: for single-level files, build a full mip chain on the GPU. This forces an
    ///     uncompressed format because Metal cannot generate mipmaps for compressed formats.
    ///     Plain ASTC files can't be decoded on the CPU, so they keep a single level.
    ///   - storageMode: nil uses Metal's default; `.private` uploads through a staging buffer.
    public func makeTexture(
        from data: Data,
        colorSpace: ColorSpace = .fromFile,
        generateMipmaps: Bool = false,
        storageMode: MTLStorageMode? = nil,
        usage: MTLTextureUsage = .shaderRead,
        label: String? = nil
    ) throws -> MTLTexture {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress, bytes.count >= 4, bytes.count <= Int(UInt32.max) else {
                throw BasisTextureError.invalidKTX2
            }
            let request = Request(colorSpace: colorSpace, generateMipmaps: generateMipmaps, storageMode: storageMode, usage: usage, label: label)
            let handle = bt_ktx2_open(UInt64(UInt(bitPattern: base)), UInt32(bytes.count))
            guard handle != 0 else {
                // Not Basis-readable; maybe plain ASTC.
                let file = try KTX2File(bytes)
                guard file.astcKind != nil else {
                    throw BasisTextureError.invalidKTX2
                }
                return try makeRawASTCTexture(file: file, bytes: bytes, request: request)
            }
            defer { bt_ktx2_close(handle) }
            guard bt_ktx2_start_transcoding(handle) != 0 else {
                throw BasisTextureError.startTranscodingFailed
            }
            return try makeBasisTexture(handle: handle, request: request)
        }
    }

    struct Request {
        var colorSpace: ColorSpace
        var generateMipmaps: Bool
        var storageMode: MTLStorageMode?
        var usage: MTLTextureUsage
        var label: String?

        func isSRGB(file: Bool) -> Bool {
            switch colorSpace {
            case .fromFile: file
            case .sRGB: true
            case .linear: false
            }
        }
    }

    struct Shape {
        var width: Int
        var height: Int
        var levels: Int
        var faces: Int
        var layers: Int
    }

    private func makeBasisTexture(handle: UInt64, request: Request) throws -> MTLTexture {
        guard bt_ktx2_is_video(handle) == 0 else {
            throw BasisTextureError.unsupportedTexture("video KTX2 files are not supported")
        }
        let shape = Shape(
            width: Int(bt_ktx2_get_width(handle)),
            height: Int(bt_ktx2_get_height(handle)),
            levels: max(1, Int(bt_ktx2_get_levels(handle))),
            faces: max(1, Int(bt_ktx2_get_faces(handle))),
            layers: max(1, Int(bt_ktx2_get_layers(handle)))
        )
        let generating = request.generateMipmaps && shape.levels == 1 && max(shape.width, shape.height) > 1
        let target = try TargetFormat.choose(
            basisFormat: bt_ktx2_get_basis_tex_format(handle),
            isSRGB: request.isSRGB(file: bt_ktx2_is_srgb(handle) != 0),
            capabilities: forceUncompressed || generating ? .uncompressedOnly : capabilities
        )
        return try makeTexture(shape: shape, target: target, generateMipmaps: generating, request: request) { level, layer, face, destination in
            // State 0 = the handle's own state. Don't use bt_ktx2_create_transcode_state():
            // it zero-inits the cached level index, breaking level 0 of Zstd files (issue #7).
            let ok = bt_ktx2_transcode_image_level(
                handle, UInt32(level), UInt32(layer), UInt32(face),
                UInt64(UInt(bitPattern: destination.baseAddress)),
                UInt32(destination.count / target.bytesPerUnit), target.transcoderFormat, 0,
                0, 0, -1, -1, 0
            )
            guard ok != 0 else {
                throw BasisTextureError.transcodeFailed(level: level, layer: layer, face: face)
            }
        }
    }

    private func makeRawASTCTexture(file: KTX2File, bytes: UnsafeRawBufferPointer, request: Request) throws -> MTLTexture {
        guard file.depth == 1, file.faces == 1 || file.faces == 6 else {
            throw BasisTextureError.unsupportedTexture("3D or unusual-face KTX2 files are not supported")
        }
        let target: TargetFormat
        switch file.astcKind {
        case let .ldr(size, isSRGB):
            guard capabilities.astcLDR, !forceUncompressed else {
                throw BasisTextureError.unsupportedTexture("plain ASTC LDR KTX2 needs a GPU with ASTC support")
            }
            target = TargetFormat.astcLDR(size, isSRGB: request.isSRGB(file: isSRGB))!
        case let .hdr(size):
            guard capabilities.astcHDR, !forceUncompressed else {
                throw BasisTextureError.unsupportedTexture("plain ASTC HDR KTX2 needs a GPU with ASTC HDR support")
            }
            target = TargetFormat.astcHDR(size)!
        case nil:
            throw BasisTextureError.invalidKTX2
        }
        let shape = Shape(width: file.width, height: file.height, levels: file.levels.count, faces: file.faces, layers: file.layers)
        var cachedLevel = -1
        var levelData = Data()
        return try makeTexture(shape: shape, target: target, generateMipmaps: false, request: request) { level, layer, face, destination in
            if level != cachedLevel {
                levelData = try file.levelData(level, in: bytes)
                cachedLevel = level
            }
            let start = (layer * shape.faces + face) * destination.count
            guard start + destination.count <= levelData.count else {
                throw BasisTextureError.invalidKTX2
            }
            levelData.copyBytes(to: destination.bindMemory(to: UInt8.self), from: start ..< start + destination.count)
        }
    }

    /// Creates the texture, fills each image through `writeImage`, and uploads it.
    private func makeTexture(
        shape: Shape,
        target: TargetFormat,
        generateMipmaps: Bool,
        request: Request,
        writeImage: (_ level: Int, _ layer: Int, _ face: Int, _ destination: UnsafeMutableRawBufferPointer) throws -> Void
    ) throws -> MTLTexture {
        guard shape.width > 0, shape.height > 0 else {
            throw BasisTextureError.invalidKTX2
        }
        guard shape.faces == 1 || shape.faces == 6 else {
            throw BasisTextureError.unsupportedTexture("faces = \(shape.faces)")
        }
        if request.storageMode == .memoryless {
            throw BasisTextureError.unsupportedTexture("memoryless storage")
        }

        let descriptor = MTLTextureDescriptor()
        descriptor.pixelFormat = target.pixelFormat
        descriptor.width = shape.width
        descriptor.height = shape.height
        descriptor.mipmapLevelCount = generateMipmaps
            ? Int(log2(Double(max(shape.width, shape.height)))) + 1
            : shape.levels
        descriptor.usage = request.usage
        if let storageMode = request.storageMode {
            descriptor.storageMode = storageMode
        }
        switch (shape.faces, shape.layers) {
        case (1, 1):
            descriptor.textureType = .type2D
        case (1, _):
            descriptor.textureType = .type2DArray
            descriptor.arrayLength = shape.layers
        case (6, 1):
            descriptor.textureType = .typeCube
        default:
            descriptor.textureType = .typeCubeArray
            descriptor.arrayLength = shape.layers
        }
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw BasisTextureError.textureCreationFailed
        }
        texture.label = request.label

        struct Image {
            var level: Int
            var slice: Int
            var width: Int
            var height: Int
            var bytesPerRow: Int
            var offset: Int
            var length: Int
        }
        var images: [Image] = []
        var totalLength = 0
        for level in 0 ..< shape.levels {
            let width = max(1, shape.width >> level)
            let height = max(1, shape.height >> level)
            let block = target.blockSize ?? BlockSize(width: 1, height: 1)
            let unitsX = (width + block.width - 1) / block.width
            let unitsY = (height + block.height - 1) / block.height
            let length = unitsX * unitsY * target.bytesPerUnit
            for slice in 0 ..< shape.layers * shape.faces {
                images.append(Image(level: level, slice: slice, width: width, height: height, bytesPerRow: unitsX * target.bytesPerUnit, offset: totalLength, length: length))
                totalLength += length
            }
        }

        guard let staging = device.makeBuffer(length: totalLength, options: .storageModeShared) else {
            throw BasisTextureError.uploadFailed("staging buffer allocation failed")
        }
        for image in images {
            let destination = UnsafeMutableRawBufferPointer(start: staging.contents() + image.offset, count: image.length)
            try writeImage(image.level, image.slice / shape.faces, image.slice % shape.faces, destination)
        }

        let usesBlit = texture.storageMode == .private
        if !usesBlit {
            for image in images {
                texture.replace(
                    region: MTLRegionMake2D(0, 0, image.width, image.height),
                    mipmapLevel: image.level,
                    slice: image.slice,
                    withBytes: staging.contents() + image.offset,
                    bytesPerRow: image.bytesPerRow,
                    bytesPerImage: 0
                )
            }
        }
        guard usesBlit || generateMipmaps else {
            return texture
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer(), let blit = commandBuffer.makeBlitCommandEncoder() else {
            throw BasisTextureError.uploadFailed("could not create blit encoder")
        }
        if usesBlit {
            for image in images {
                blit.copy(
                    from: staging, sourceOffset: image.offset,
                    sourceBytesPerRow: image.bytesPerRow, sourceBytesPerImage: image.length,
                    sourceSize: MTLSize(width: image.width, height: image.height, depth: 1),
                    to: texture, destinationSlice: image.slice, destinationLevel: image.level,
                    destinationOrigin: MTLOrigin()
                )
            }
        }
        if generateMipmaps {
            blit.generateMipmaps(for: texture)
        }
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error {
            throw BasisTextureError.uploadFailed(error.localizedDescription)
        }
        return texture
    }
}
