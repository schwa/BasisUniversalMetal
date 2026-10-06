# ISSUES.md

File format: <https://github.com/schwa/issues-format>

---

## 1: Cannot choose sRGB or linear for a texture

+++
status: new
priority: high
kind: feature
labels: effort:s
created: 2026-10-06T18:55:27Z
+++

makeTexture(from:) picks an sRGB or linear pixel format from the KTX2 file's transfer function. glTF decides by use instead: base color, emissive, specular color and sheen color are sRGB; normal, metallic-roughness, occlusion and the other data textures are linear. A file whose flag disagrees with its slot would be decoded wrongly, and one image used in both kinds of slot needs both formats. Wanted: a parameter (e.g. colorSpace: .sRGB / .linear / .fromFile, default .fromFile) that overrides the file. Blocks MetalSprocketsGLTF #36 (KHR_texture_basisu).

---

## 2: Textures without mipmaps cannot get mipmaps

+++
status: new
priority: medium
kind: feature
labels: effort:s
created: 2026-10-06T18:55:27Z
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
status: new
priority: low
kind: enhancement
labels: effort:s
created: 2026-10-06T18:55:27Z
+++

Transcoded data is uploaded with MTLTexture.replace(region:...), which requires shared or managed storage; a caller cannot get a .private texture (better for GPU-only sampling on discrete GPUs). Wanted: an option for private storage, uploading through a staging buffer and a blit encoder.

---
