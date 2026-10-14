# BasisUniversalMetal

Loads KTX2 / Basis Universal (`KHR_texture_basisu`) and plain ASTC KTX2 (`EXT_texture_astc`) files into `MTLTexture`s. Uses upstream's plain C transcoder API, so no C++ interop is needed.

```swift
let loader = BasisTextureLoader(device: device)
let texture = try loader.makeTexture(from: ktx2Data)
```

Options on `makeTexture`:

- `colorSpace: .fromFile | .sRGB | .linear` — glTF picks sRGB vs linear by material slot.
- `generateMipmaps: true` — single-level files get a full chain, generated on the GPU. This forces RGBA8/RGBA16F, because Metal can't generate mipmaps for compressed formats. Plain ASTC files keep one level.
- `storageMode: .private` — uploads through a staging buffer and a blit.
- `usage:`, `label:`.

Target format: ASTC on Apple GPUs, BC7/BC6H on Intel/AMD Macs, RGBA8/RGBA16F otherwise. `forceUncompressed: true` on the loader forces the last. Plain ASTC files need a GPU with ASTC (HDR files need ASTC HDR).

Loading is synchronous; for big assets, call it off the main thread.

Vendored: `Sources/CBasisUniversal/vendor` (see `VERSION`) — transcoder, zstd decoder, and `encoder/basisu_wasm_transcoder_api.*` (the C API) only.
