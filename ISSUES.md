# ISSUES.md

File format: <https://github.com/schwa/issues-format>

---

## 1: Cannot choose sRGB or linear for a texture

+++
status: closed
priority: high
kind: feature
labels: effort:s
created: 2026-10-06T18:55:27Z
updated: 2026-10-06T19:07:56Z
closed: 2026-10-06T19:07:56Z
+++

makeTexture(from:) picks an sRGB or linear pixel format from the KTX2 file's transfer function. glTF decides by use instead: base color, emissive, specular color and sheen color are sRGB; normal, metallic-roughness, occlusion and the other data textures are linear. A file whose flag disagrees with its slot would be decoded wrongly, and one image used in both kinds of slot needs both formats. Wanted: a parameter (e.g. colorSpace: .sRGB / .linear / .fromFile, default .fromFile) that overrides the file. Blocks MetalSprocketsGLTF #36 (KHR_texture_basisu).

---

## 2: Textures without mipmaps cannot get mipmaps

+++
status: closed
priority: medium
kind: feature
labels: effort:s
created: 2026-10-06T18:55:27Z
updated: 2026-10-06T19:07:56Z
closed: 2026-10-06T19:07:56Z
+++

KTX2 files saved with a single level produce a texture with one mip level. For compressed targets (ASTC, BC7, BC6H) Metal cannot generate mipmaps afterwards (generateMipmaps needs a renderable, uncompressed format), so such textures shimmer and alias when minified. Wanted: an option to get a full mip chain, e.g. transcode single-level files to RGBA8/RGBA16F with mipmapLevelCount for the full chain so the caller can blit-generate them, or generate them here.

---

## 3: Package has no remote

+++
status: new
priority: medium
kind: task
labels: effort:xs
created: 2026-10-06T18:55:27Z
+++

The repository only exists locally (no git remote), so other packages (MetalSprocketsGLTF for KHR_texture_basisu, #36 there) can only depend on it by local path. Wanted: push it (e.g. github.com/schwa/BasisUniversalMetal) or decide to fold it into another package such as SwiftGLTF.

---

## 4: Textures must be CPU-accessible

+++
status: closed
priority: low
kind: enhancement
labels: effort:s
created: 2026-10-06T18:55:27Z
updated: 2026-10-06T19:07:56Z
closed: 2026-10-06T19:07:56Z
+++

Transcoded data is uploaded with MTLTexture.replace(region:...), which requires shared or managed storage; a caller cannot get a .private texture (better for GPU-only sampling on discrete GPUs). Wanted: an option for private storage, uploading through a staging buffer and a blit encoder.

---

## 5: Compressed-texture output is not checked on the GPU

+++
status: closed
priority: medium
kind: task
labels: effort:s
created: 2026-10-06T18:57:20Z
updated: 2026-10-06T19:07:56Z
closed: 2026-10-06T19:07:56Z
+++

Tests check only the size, mip count and type of ASTC/BC textures. Their texel data is never sampled. A wrong pixel format or bytesPerRow on the compressed path would still pass. Only the forceUncompressed path has pixel checks.

---

## 6: BC7/BC6H fallback path is never tested

+++
status: closed
priority: low
kind: task
labels: effort:s
created: 2026-10-06T18:57:20Z
updated: 2026-10-06T19:07:56Z
closed: 2026-10-06T19:07:56Z
+++

TargetFormat.choose picks BC7 (LDR) or BC6H (HDR) on devices without ASTC (Intel/AMD Macs). Tests run on Apple GPUs only, so this path never runs. Format selection depends on a live MTLDevice, so the selection cannot be tested on its own.

---

## 7: No test pins the upstream transcode-state bug workaround

+++
status: closed
priority: low
kind: task
labels: effort:xs
created: 2026-10-06T18:57:20Z
updated: 2026-10-06T19:07:56Z
closed: 2026-10-06T19:07:56Z
+++

Upstream bt_ktx2_create_transcode_state() sets the cached level index to 0, not -1. Level 0 of a Zstd-supercompressed KTX2 (e.g. UASTC) then fails to transcode: an assert in debug, a failed call in release. The loader passes state 0 to avoid this. Only the Zstd UASTC sample files cover it indirectly. Nothing names the bug.

---

## 8: Upstream bug in bt_ktx2_create_transcode_state not reported

+++
status: new
priority: low
kind: task
labels: effort:xs, deferred
created: 2026-10-06T18:57:20Z
updated: 2026-10-06T19:09:59Z
+++

basis_universal @ 99f52d63: new ktx2_transcode_state_t() value-initializes ktx2_transcoder_state, so m_uncomp_data_level_index is 0, not -1. Repro: open a UASTC+Zstd KTX2, create a state with bt_ktx2_create_transcode_state(), transcode level 0. Expected: success. Actual: assert at basisu_transcoder.cpp:20807 (debug), returns false (release). Not yet reported to BinomialLLC.

---

## 9: Plain ASTC KTX2 files cannot be loaded

+++
status: closed
priority: low
kind: feature
labels: effort:s
created: 2026-10-06T18:59:24Z
updated: 2026-10-06T19:07:56Z
closed: 2026-10-06T19:07:56Z
+++

makeTexture(from:) only handles KTX2 files holding Basis Universal data. glTF's EXT_texture_astc stores ASTC blocks directly in KTX2 (vkFormat = a VK_FORMAT_ASTC_* value, no Basis payload), which Apple GPUs can sample as-is with no transcoding. Wanted: detect such files, map the vkFormat to the matching MTLPixelFormat (block size, sRGB vs UNORM, HDR), and upload each level's bytes directly; handle zstd supercompression if present (the zstd decoder is already vendored). On GPUs without ASTC (Intel Macs) either decode on the CPU or fail with a clear error. Unknown: whether upstream's C API exposes enough to read non-Basis KTX2 levels, or whether this needs a small KTX2 reader of our own. Needed by MetalSprocketsGLTF #88 (EXT_texture_astc); no glTF-Sample-Assets model uses it, so tests need generated files (astcenc + ktx create).

---
