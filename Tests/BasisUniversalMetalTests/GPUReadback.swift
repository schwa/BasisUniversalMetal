import Foundation
import Metal
import Testing

/// Samples mip level 0, slice 0 of any 2D texture on the GPU into linear float RGBA. Works for compressed and private textures.
struct GPUReadback {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void readback(texture2d<float> texture [[texture(0)]], device float4 *output [[buffer(0)]],
                         constant float &lod [[buffer(1)]], uint2 gid [[thread_position_in_grid]]) {
        uint width = max(1u, texture.get_width() >> uint(lod));
        uint height = max(1u, texture.get_height() >> uint(lod));
        if (gid.x >= width || gid.y >= height) return;
        constexpr sampler nearest(filter::nearest, mip_filter::nearest);
        float2 coordinate = (float2(gid) + 0.5) / float2(width, height);
        output[gid.y * width + gid.x] = texture.sample(nearest, coordinate, level(lod));
    }
    """

    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLComputePipelineState

    init(device: MTLDevice) throws {
        self.device = device
        queue = try #require(device.makeCommandQueue())
        let library = try device.makeLibrary(source: Self.source, options: nil)
        pipeline = try device.makeComputePipelineState(function: try #require(library.makeFunction(name: "readback")))
    }

    func read(_ texture: MTLTexture, level: Int = 0) throws -> [SIMD4<Float>] {
        let width = max(1, texture.width >> level), height = max(1, texture.height >> level)
        let buffer = try #require(device.makeBuffer(length: width * height * 16, options: .storageModeShared))
        let commandBuffer = try #require(queue.makeCommandBuffer())
        let encoder = try #require(commandBuffer.makeComputeCommandEncoder())
        var lod = Float(level)
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(texture, index: 0)
        encoder.setBuffer(buffer, offset: 0, index: 0)
        encoder.setBytes(&lod, length: 4, index: 1)
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        #expect(commandBuffer.error == nil)
        return Array(UnsafeBufferPointer(start: buffer.contents().assumingMemoryBound(to: SIMD4<Float>.self), count: width * height))
    }

    static func meanAbsoluteError(_ lhs: [SIMD4<Float>], _ rhs: [SIMD4<Float>]) -> Float {
        precondition(lhs.count == rhs.count)
        var total: Float = 0
        for (left, right) in zip(lhs, rhs) {
            let difference = left - right
            total += abs(difference.x) + abs(difference.y) + abs(difference.z)
        }
        return total / Float(lhs.count * 3)
    }

    /// Mean absolute error divided by the mean magnitude of `reference`; for HDR data, where values exceed 1.
    static func relativeError(_ lhs: [SIMD4<Float>], reference: [SIMD4<Float>]) -> Float {
        let magnitude = reference.reduce(Float(0)) { $0 + abs($1.x) + abs($1.y) + abs($1.z) } / Float(reference.count * 3)
        return meanAbsoluteError(lhs, reference) / max(magnitude, .leastNormalMagnitude)
    }

    static func error(_ lhs: [SIMD4<Float>], reference: [SIMD4<Float>], isHDR: Bool) -> Float {
        isHDR ? relativeError(lhs, reference: reference) : meanAbsoluteError(lhs, reference)
    }
}
