# BasisUniversalMetal

KTX2 / Basis Universal (`KHR_texture_basisu`) → `MTLTexture`, via upstream's plain C transcoder API. No C++ interop.

```swift
let texture = try BasisTextureLoader(device: device).makeTexture(from: ktx2Data)
```

Target format: ASTC (Apple GPUs) → BC7/BC6H (Intel/AMD Macs) → RGBA8/RGBA16F. `forceUncompressed: true` forces the last.

Vendored: `Sources/CBasisUniversal/vendor` (see `VERSION`) — transcoder, zstd decoder, and `encoder/basisu_wasm_transcoder_api.*` (the C API) only.
