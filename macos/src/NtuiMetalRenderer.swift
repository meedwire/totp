// Phase F: Swift port of the Metal backend half of ntui_macos_renderer.m. This
// is a faithful 1:1 port — the shader source, pipeline/blend state, clip-scissor
// stack, NDC/coordinate math, the baked A8 atlas upload (Phase C4), the
// TS-quad draw, and the AppKit/CoreText fallback all preserve the exact behavior
// of the Obj-C original. The old .m is one `git show` away for diffing if the
// on-screen render needs adjustment.

import AppKit
import CoreText
import MetalKit

// Metal shader source — byte-identical to kNtuiMacosShaderSource in the .m.
private let kNtuiMacosShaderSource = """
#include <metal_stdlib>
using namespace metal;
struct NtuiVertex {
  packed_float2 position;
  packed_float4 color;
  packed_float2 texCoord;
};
struct NtuiRaster {
  float4 position [[position]];
  float4 color;
  float2 texCoord;
};
vertex NtuiRaster ntui_vertex(uint vertexID [[vertex_id]], constant NtuiVertex *vertices [[buffer(0)]]) {
  NtuiVertex inputVertex = vertices[vertexID];
  NtuiRaster out;
  out.position = float4(inputVertex.position, 0.0, 1.0);
  out.color = inputVertex.color;
  out.texCoord = inputVertex.texCoord;
  return out;
}
fragment float4 ntui_solid_fragment(NtuiRaster in [[stage_in]]) {
  return in.color;
}
float ntui_rounded_rect_sdf(float2 p, float2 halfSize, float radius) {
  float2 q = abs(p) - (halfSize - float2(radius));
  return length(max(q, float2(0.0))) + min(max(q.x, q.y), 0.0) - radius;
}
fragment float4 ntui_box_fragment(NtuiRaster in [[stage_in]], constant float4 *box [[buffer(0)]]) {
  float2 size = max(box[0].xy, float2(0.0));
  float2 halfSize = size * 0.5;
  float radius = clamp(box[0].z, 0.0, min(halfSize.x, halfSize.y));
  float borderWidth = clamp(box[0].w, 0.0, min(halfSize.x, halfSize.y));
  float2 local = (in.texCoord * size) - halfSize;
  float outer = ntui_rounded_rect_sdf(local, halfSize, radius);
  float outerAa = max(fwidth(outer), 1e-4);
  float outerAlpha = 1.0 - smoothstep(-outerAa * 0.5, outerAa * 0.5, outer);
  if (outerAlpha <= 0.0) discard_fragment();
  float innerAlpha = 1.0;
  if (borderWidth > 0.0) {
    float2 innerHalf = max(halfSize - float2(borderWidth), float2(0.0));
    float innerRadius = max(radius - borderWidth, 0.0);
    innerAlpha = 0.0;
    if (innerHalf.x > 0.0 && innerHalf.y > 0.0) {
      float inner = ntui_rounded_rect_sdf(local, innerHalf, innerRadius);
      float innerAa = max(fwidth(inner), 1e-4);
      innerAlpha = 1.0 - smoothstep(-innerAa * 0.5, innerAa * 0.5, inner);
    }
  }
  float4 color = mix(box[2], box[1], innerAlpha);
  color.a *= outerAlpha;
  return color;
}
fragment float4 ntui_texture_fragment(NtuiRaster in [[stage_in]], texture2d<float> texture [[texture(0)]]) {
  constexpr sampler textSampler(address::clamp_to_edge, filter::linear);
  return texture.sample(textSampler, in.texCoord) * in.color;
}
fragment float4 ntui_text_fragment(NtuiRaster in [[stage_in]], texture2d<float> texture [[texture(0)]]) {
  constexpr sampler textSampler(address::clamp_to_edge, filter::linear);
  float alpha = in.texCoord.x < -0.5 ? 1.0 : texture.sample(textSampler, in.texCoord).r;
  return float4(in.color.rgb, in.color.a * alpha);
}
"""

private struct ClipRect {
    var x: Int
    var y: Int
    var width: Int
    var height: Int
}

final class NtuiMetalRenderer {
    private var device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var solidPipeline: MTLRenderPipelineState?
    private var boxPipeline: MTLRenderPipelineState?
    private var texturePipeline: MTLRenderPipelineState?
    private var textPipeline: MTLRenderPipelineState?
    private var textureLoader: MTKTextureLoader?

    private var commandBuffer: MTLCommandBuffer?
    private var encoder: MTLRenderCommandEncoder?
    private var drawable: CAMetalDrawable?
    private var drawableWidth = 0
    private var drawableHeight = 0

    private var clipStack = [ClipRect]()
    private let clipStackMax = 64

    private var builtinAtlasTexture: MTLTexture?
    private var builtinAtlasWidth = 0
    private var builtinAtlasHeight = 0
    private var atlasBytes: [UInt8]?

    private var framesSubmitted: UInt64 = 0
    private var fontTextureCount: UInt64 = 0
    private var fontTextureBytes: UInt64 = 0
    private var appkitFallbackTextureCount: UInt64 = 0
    private var appkitFallbackTextureBytes: UInt64 = 0

    // MARK: - device / pipelines (mirrors ntui_macos_prepare_device + compile_pipelines)

    private func compilePipelines(pixelFormat: MTLPixelFormat) -> Bool {
        guard let device = device else { return false }
        if solidPipeline != nil && boxPipeline != nil && texturePipeline != nil && textPipeline != nil { return true }
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: kNtuiMacosShaderSource, options: nil)
        } catch {
            NSLog("ntui_macos_renderer: failed to compile Metal library: %@", "\(error)")
            return false
        }
        guard
            let vertex = library.makeFunction(name: "ntui_vertex"),
            let solidFragment = library.makeFunction(name: "ntui_solid_fragment"),
            let boxFragment = library.makeFunction(name: "ntui_box_fragment"),
            let textureFragment = library.makeFunction(name: "ntui_texture_fragment"),
            let textFragment = library.makeFunction(name: "ntui_text_fragment")
        else { return false }

        func makePipeline(_ fragment: MTLFunction, _ label: String) -> MTLRenderPipelineState? {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            let attachment = descriptor.colorAttachments[0]!
            attachment.pixelFormat = pixelFormat
            attachment.isBlendingEnabled = true
            attachment.sourceRGBBlendFactor = .sourceAlpha
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.sourceAlphaBlendFactor = .sourceAlpha
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            do {
                return try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                NSLog("ntui_macos_renderer: failed to compile %@ pipeline: %@", label, "\(error)")
                return nil
            }
        }
        guard let solid = makePipeline(solidFragment, "solid") else { return false }
        solidPipeline = solid
        guard let box = makePipeline(boxFragment, "box") else { return false }
        boxPipeline = box
        guard let texture = makePipeline(textureFragment, "texture") else { return false }
        texturePipeline = texture
        guard let text = makePipeline(textFragment, "text") else { return false }
        textPipeline = text
        return true
    }

    private func prepareDevice(_ view: MTKView) -> Bool {
        if device == nil {
            device = view.device ?? MTLCreateSystemDefaultDevice()
        }
        guard let device = device else { return false }
        if view.device == nil { view.device = device }
        view.framebufferOnly = false
        if view.colorPixelFormat == .invalid {
            view.colorPixelFormat = .bgra8Unorm
        }
        if commandQueue == nil {
            commandQueue = device.makeCommandQueue()
        }
        if textureLoader == nil {
            textureLoader = MTKTextureLoader(device: device)
        }
        return commandQueue != nil && compilePipelines(pixelFormat: view.colorPixelFormat)
    }

    // MARK: - coordinate helpers (mirror write_vertex / make_quad / clamp / floor/ceil)

    private func clamp(_ value: Double, _ minimum: Double, _ maximum: Double) -> Double {
        min(max(value, minimum), maximum)
    }

    private func floorToInt(_ value: Double) -> Int {
        let truncated = Int(value)
        return Double(truncated) > value ? truncated - 1 : truncated
    }

    private func ceilToInt(_ value: Double) -> Int {
        let truncated = Int(value)
        return Double(truncated) < value ? truncated + 1 : truncated
    }

    private func rectIsVisible(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Bool {
        x.isFinite && y.isFinite && w.isFinite && h.isFinite && w > 0 && h > 0 && encoder != nil
    }

    // Appends one vertex (8 floats: pos.xy, color.rgba, tex.uv) in NDC space.
    private func appendVertex(_ into: inout [Float], _ x: Double, _ y: Double, _ u: Double, _ v: Double, _ color: NtuiColor) {
        let ndcX = (x / Double(drawableWidth)) * 2.0 - 1.0
        let ndcY = 1.0 - (y / Double(drawableHeight)) * 2.0
        into.append(Float(ndcX))
        into.append(Float(ndcY))
        into.append(Float(clamp(color.r, 0, 1)))
        into.append(Float(clamp(color.g, 0, 1)))
        into.append(Float(clamp(color.b, 0, 1)))
        into.append(Float(clamp(color.a, 0, 1)))
        into.append(Float(u))
        into.append(Float(v))
    }

    // Six vertices (two triangles) for a rect, matching ntui_macos_make_quad order.
    private func makeQuad(_ x: Double, _ y: Double, _ width: Double, _ height: Double, _ color: NtuiColor, flipTexY: Bool = false) -> [Float] {
        let x0 = x, y0 = y, x1 = x + width, y1 = y + height
        var out = [Float]()
        out.reserveCapacity(48)
        appendVertex(&out, x0, y0, 0, 0, color)
        appendVertex(&out, x1, y0, 1, 0, color)
        appendVertex(&out, x1, y1, 1, 1, color)
        appendVertex(&out, x0, y0, 0, 0, color)
        appendVertex(&out, x1, y1, 1, 1, color)
        appendVertex(&out, x0, y1, 0, 1, color)
        if flipTexY {
            // Flip tex_coord.y for the 6 vertices (u at offset 6, v at offset 7 per vertex stride 8).
            for i in 0..<6 { out[i * 8 + 7] = 1.0 - out[i * 8 + 7] }
        }
        return out
    }

    // MARK: - clip-scissor stack (mirrors the .m clip helpers)

    private func emptyClipRect() -> ClipRect { ClipRect(x: 0, y: 0, width: 0, height: 0) }

    private func intersect(_ a: ClipRect, _ b: ClipRect) -> ClipRect {
        let left = max(a.x, b.x)
        let top = max(a.y, b.y)
        let right = min(a.x + a.width, b.x + b.width)
        let bottom = min(a.y + a.height, b.y + b.height)
        if right <= left || bottom <= top { return emptyClipRect() }
        return ClipRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    private func clipRectFromRect(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> ClipRect {
        if drawableWidth <= 0 || drawableHeight <= 0 { return emptyClipRect() }
        if !x.isFinite || !y.isFinite || !width.isFinite || !height.isFinite || width <= 0 || height <= 0 {
            return emptyClipRect()
        }
        var leftF = x, topF = y
        var rightF = x + width, bottomF = y + height
        if rightF <= 0 || bottomF <= 0 { return emptyClipRect() }
        if leftF >= Double(drawableWidth) || topF >= Double(drawableHeight) { return emptyClipRect() }
        if leftF < 0 { leftF = 0 }
        if topF < 0 { topF = 0 }
        if rightF > Double(drawableWidth) { rightF = Double(drawableWidth) }
        if bottomF > Double(drawableHeight) { bottomF = Double(drawableHeight) }
        let left = floorToInt(leftF)
        let top = floorToInt(topF)
        let right = ceilToInt(rightF)
        let bottom = ceilToInt(bottomF)
        if right <= left || bottom <= top { return emptyClipRect() }
        return ClipRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    private func applyClipScissor() {
        guard let encoder = encoder, drawableWidth > 0, drawableHeight > 0 else { return }
        var rect = ClipRect(x: 0, y: 0, width: drawableWidth, height: drawableHeight)
        if let top = clipStack.last { rect = top }
        encoder.setScissorRect(MTLScissorRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height))
    }

    func resetClipStack() {
        clipStack.removeAll(keepingCapacity: true)
        applyClipScissor()
    }

    @discardableResult
    func pushClipRect(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> Bool {
        if clipStack.count >= clipStackMax { return true }
        var rect = clipRectFromRect(x, y, width, height)
        if let top = clipStack.last { rect = intersect(rect, top) }
        clipStack.append(rect)
        applyClipScissor()
        return true
    }

    @discardableResult
    func pushClipRRect(_ x: Double, _ y: Double, _ width: Double, _ height: Double, _ radius: Double) -> Bool {
        pushClipRect(x, y, width, height)
    }

    func popClip() {
        if !clipStack.isEmpty { clipStack.removeLast() }
        applyClipScissor()
    }

    var clipStackDepth: Int { clipStack.count }

    private func setTextScissor(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> Bool {
        guard let encoder = encoder, drawableWidth > 0, drawableHeight > 0 else { return false }
        var rect = clipRectFromRect(x, y, width, height)
        if let top = clipStack.last { rect = intersect(rect, top) }
        encoder.setScissorRect(MTLScissorRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height))
        return true
    }

    private func resetScissor() { applyClipScissor() }

    // MARK: - frame lifecycle

    func beginFrame(view: MTKView, drawableWidth: Int, drawableHeight: Int) -> Bool {
        if !prepareDevice(view) { return false }
        if drawableWidth <= 0 || drawableHeight <= 0 { return false }
        self.drawableWidth = drawableWidth
        self.drawableHeight = drawableHeight
        guard let passDescriptor = view.currentRenderPassDescriptor, let drawable = view.currentDrawable else { return false }
        self.drawable = drawable
        passDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0.063, 0.075, 0.090, 1.0)
        passDescriptor.colorAttachments[0].loadAction = .clear
        passDescriptor.colorAttachments[0].storeAction = .store
        guard let commandBuffer = commandQueue?.makeCommandBuffer() else { return false }
        self.commandBuffer = commandBuffer
        encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor)
        resetClipStack()
        return encoder != nil
    }

    @discardableResult
    func endFrame() -> Bool {
        guard let encoder = encoder, let commandBuffer = commandBuffer, let drawable = drawable else { return false }
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
        framesSubmitted += 1
        self.encoder = nil
        self.commandBuffer = nil
        self.drawable = nil
        return true
    }

    // MARK: - primitives

    @discardableResult
    func drawRect(_ x: Double, _ y: Double, _ width: Double, _ height: Double, _ color: NtuiColor) -> Bool {
        if !rectIsVisible(x, y, width, height) || color.a <= 0 { return true }
        guard let encoder = encoder, let pipeline = solidPipeline else { return true }
        var vertices = makeQuad(x, y, width, height, color)
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&vertices, length: vertices.count * MemoryLayout<Float>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        return true
    }

    @discardableResult
    func drawBox(_ x: Double, _ y: Double, _ width: Double, _ height: Double, _ borderWidth: Double, _ borderRadius: Double, _ fill: NtuiColor, _ border: NtuiColor) -> Bool {
        if !rectIsVisible(x, y, width, height) { return true }
        let borderClamped = clamp(borderWidth, 0, min(width, height) * 0.5)
        let radiusClamped = clamp(borderRadius, 0, min(width, height) * 0.5)
        if fill.a <= 0 && (borderClamped <= 0 || border.a <= 0) { return true }
        if radiusClamped <= 0 && borderClamped <= 0 {
            return drawRect(x, y, width, height, fill)
        }
        guard let encoder = encoder, let pipeline = boxPipeline else { return true }
        var vertices = makeQuad(x, y, width, height, fill)
        var boxUniforms: [Float] = [
            Float(width), Float(height), Float(radiusClamped), Float(borderClamped),
            Float(clamp(fill.r, 0, 1)), Float(clamp(fill.g, 0, 1)), Float(clamp(fill.b, 0, 1)), Float(clamp(fill.a, 0, 1)),
            Float(clamp(border.r, 0, 1)), Float(clamp(border.g, 0, 1)), Float(clamp(border.b, 0, 1)), Float(clamp(border.a, 0, 1)),
        ]
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&vertices, length: vertices.count * MemoryLayout<Float>.stride, index: 0)
        encoder.setFragmentBytes(&boxUniforms, length: boxUniforms.count * MemoryLayout<Float>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        return true
    }

    // MARK: - baked A8 atlas (Phase C4/F: loaded from the bundled Resource)

    // Teto documentado de `setVertexBytes`/`setFragmentBytes` no Metal.
    fileprivate static let maxSetBytesLength = 4096

    func setAtlasBytes(_ bytes: [UInt8]) { atlasBytes = bytes }

    private func ensureBuiltinAtlas(width: Int, height: Int) -> MTLTexture? {
        guard let device = device, width > 0, height > 0, let bytes = atlasBytes else { return nil }
        if let texture = builtinAtlasTexture, builtinAtlasWidth == width, builtinAtlasHeight == height {
            return texture
        }
        if bytes.count < width * height { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        bytes.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: width)
        }
        builtinAtlasTexture = texture
        builtinAtlasWidth = width
        builtinAtlasHeight = height
        fontTextureCount += 1
        fontTextureBytes += UInt64(width * height)
        return texture
    }

    // MARK: - self-hosted text quads (Phase C4 draw path)

    func textNeedsAppKitFallback(_ options: NtuiTextRenderOptions) -> Bool {
        if !options.textShadow.isEmpty { return true }
        if !options.writingMode.isEmpty && options.writingMode != "horizontal-tb" { return true }
        return false
    }

    @discardableResult
    func drawTextQuads(
        packed: UnsafePointer<Float>, floatCount: Int, atlasWidth: Int, atlasHeight: Int,
        quadsWidth: Double, quadsHeight: Double, lineCount: Int,
        x: Double, baselineY: Double, boxWidth: Double, fontSize: Double, lineHeight: Double, baselineOffset: Double,
        color: NtuiColor, options: NtuiTextRenderOptions
    ) -> Bool {
        guard let encoder = encoder, color.a > 0, floatCount > 0 else { return true }
        guard let texture = ensureBuiltinAtlas(width: atlasWidth, height: atlasHeight) else { return false }

        let vertexCount = floatCount / 4
        let resolvedLineHeight = lineHeight > 0
            ? lineHeight
            : (lineCount > 0 ? quadsHeight / Double(lineCount) : fontSize * 1.25)
        let clipTop = baselineOffset > 0 ? baselineY - baselineOffset : baselineY - fontSize
        var verticalShift = 0.0
        if baselineOffset > 0 && resolvedLineHeight > 0 {
            var minY = 0.0, maxY = 0.0
            var hasInk = false
            for index in 0..<vertexCount {
                let yv = Double(packed[index * 4 + 1])
                if !hasInk { minY = yv; maxY = yv; hasInk = true }
                else { if yv < minY { minY = yv }; if yv > maxY { maxY = yv } }
            }
            if hasInk {
                let lineCenterY = clipTop + resolvedLineHeight * 0.5
                let inkCenterY = (minY + maxY) * 0.5
                let maxShift = max(1.0, resolvedLineHeight * 0.5)
                verticalShift = clamp(lineCenterY - inkCenterY, -maxShift, maxShift)
            }
        }

        var vertices = [Float]()
        vertices.reserveCapacity(vertexCount * 8)
        for index in 0..<vertexCount {
            let base = index * 4
            appendVertex(&vertices,
                         Double(packed[base]),
                         Double(packed[base + 1]) + verticalShift,
                         Double(packed[base + 2]),
                         Double(packed[base + 3]),
                         color)
        }

        let clipWidth = boxWidth > 0 ? boxWidth : quadsWidth
        let clipHeight = quadsHeight > 0 ? quadsHeight : resolvedLineHeight
        let scissorEnabled = setTextScissor(clipWidth > 0 ? x : 0, clipTop, clipWidth, clipHeight)

        if let pipeline = textPipeline {
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(texture, index: 0)
            // `setVertexBytes` tem teto de 4 KB. Acima disso o Metal ABORTA o
            // processo — nao devolve erro, nao desenha errado: mata o app. Uma
            // linha longa de texto (uma nota de rodape sem quebra, um rotulo
            // comprido) passa desse teto com folga: 8 floats por vertice, 6
            // vertices por glifo = 192 bytes por caractere, ou seja ~21 caracteres.
            // Acima do teto o upload vai por MTLBuffer.
            let byteCount = vertices.count * MemoryLayout<Float>.stride
            if byteCount <= NtuiMetalRenderer.maxSetBytesLength {
                encoder.setVertexBytes(&vertices, length: byteCount, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
            } else if let device = device,
                      let buffer = device.makeBuffer(bytes: vertices, length: byteCount, options: .storageModeShared) {
                encoder.setVertexBuffer(buffer, offset: 0, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
            }
        }

        let textWidth = quadsWidth
        if hasToken(options.textDecorationLine, "underline") {
            let thickness = options.textDecorationThickness > 0 ? options.textDecorationThickness : max(1.0, fontSize / 16.0)
            let offset = options.textUnderlineOffset != 0 ? options.textUnderlineOffset : max(1.0, fontSize / 8.0)
            let decorationBaselineY = baselineY + verticalShift
            var decoration = NtuiRuntime.parseColor(options.textDecorationColor, fallback: color)
            decoration.a *= color.a
            drawRect(x, decorationBaselineY + offset, min(clipWidth, textWidth), thickness, decoration)
        }
        if hasToken(options.textDecorationLine, "line-through") {
            let decorationBaselineY = baselineY + verticalShift
            var decoration = NtuiRuntime.parseColor(options.textDecorationColor, fallback: color)
            decoration.a *= color.a
            drawRect(x, decorationBaselineY - (fontSize * 0.35), min(clipWidth, textWidth), max(1.0, fontSize / 16.0), decoration)
        }

        if scissorEnabled { resetScissor() }
        return true
    }

    // MARK: - AppKit/CoreText fallback (shadows / vertical writing-mode)

    private func hasToken(_ text: String, _ token: String) -> Bool { text.contains(token) }

    private func systemWeight(_ fontWeight: Int) -> NSFont.Weight {
        if fontWeight >= 900 { return .black }
        if fontWeight >= 800 { return .heavy }
        if fontWeight >= 700 { return .bold }
        if fontWeight >= 600 { return .semibold }
        if fontWeight >= 500 { return .medium }
        if fontWeight <= 300 { return .light }
        return .regular
    }

    private func fontWeightTrait(_ fontWeight: Int) -> CGFloat {
        if fontWeight >= 900 { return 0.62 }
        if fontWeight >= 800 { return 0.56 }
        if fontWeight >= 700 { return 0.40 }
        if fontWeight >= 600 { return 0.30 }
        if fontWeight >= 500 { return 0.23 }
        if fontWeight <= 300 { return -0.40 }
        return 0.0
    }

    private func resolveFont(_ family: String, _ style: String, _ fontSize: Double, _ fontWeight: Int) -> NSFont {
        let size = CGFloat(max(fontSize, 1.0))
        var font: NSFont?
        if !family.isEmpty {
            let traits: [NSFontDescriptor.TraitKey: Any] = [.weight: fontWeightTrait(fontWeight)]
            let descriptor = NSFontDescriptor(fontAttributes: [
                .family: family,
                .traits: traits,
            ])
            font = NSFont(descriptor: descriptor, size: size)
        }
        if font == nil {
            font = NSFont.systemFont(ofSize: size, weight: systemWeight(fontWeight))
        }
        var result = font ?? NSFont.systemFont(ofSize: size)
        if style == "italic" {
            let italic = NSFontManager.shared.convert(result, toHaveTrait: .italicFontMask)
            result = italic
        }
        return result
    }

    private func nsColor(_ color: NtuiColor) -> NSColor {
        NSColor(deviceRed: CGFloat(color.r), green: CGFloat(color.g), blue: CGFloat(color.b), alpha: CGFloat(color.a))
    }

    private func textAlignment(_ align: String, _ direction: String) -> NSTextAlignment {
        let rtl = direction == "rtl"
        if align.isEmpty { return rtl ? .right : .left }
        if align == "center" { return .center }
        if align == "right" { return .right }
        if align == "left" { return .left }
        if align == "end" { return rtl ? .left : .right }
        if align == "start" { return rtl ? .right : .left }
        return .left
    }

    private func createAppKitTextTexture(
        text: String, boxWidth: Double, fontSize: Double, lineHeight: Double, fontWeight: Int,
        textAlign: String, fontFamily: String, fontStyle: String, color: NtuiColor, options: NtuiTextRenderOptions
    ) -> (texture: MTLTexture, width: Int, height: Int)? {
        if text.isEmpty || boxWidth <= 0 || fontSize <= 0 { return nil }
        let hasPrelaidRun = options.lineIndex >= 0 && options.runIndex >= 0
        let imageWidth = Int(ceil(max(1.0, boxWidth)))
        let imageHeight = Int(ceil(lineHeight > 0
            ? max(1.0, lineHeight)
            : max(fontSize * 1.25, hasPrelaidRun ? fontSize * 1.25 : 0.0)))
        if imageWidth <= 0 || imageHeight <= 0 { return nil }

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: imageWidth, pixelsHigh: imageHeight,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32
        ) else { return nil }
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.shouldAntialias = true
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: imageWidth, height: imageHeight).fill()

        let flip = NSAffineTransform()
        flip.translateX(by: 0, yBy: CGFloat(imageHeight))
        flip.scaleX(by: 1, yBy: -1)
        flip.concat()

        let font = resolveFont(fontFamily, fontStyle, fontSize, fontWeight)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = textAlignment(textAlign, options.direction)
        paragraph.lineBreakMode = hasPrelaidRun ? .byClipping : .byWordWrapping
        paragraph.minimumLineHeight = CGFloat(imageHeight)
        paragraph.maximumLineHeight = CGFloat(imageHeight)
        paragraph.lineSpacing = 0
        paragraph.paragraphSpacing = 0
        paragraph.paragraphSpacingBefore = 0
        if options.textIndent > 0 {
            paragraph.firstLineHeadIndent = CGFloat(options.textIndent)
        }
        paragraph.baseWritingDirection = options.direction == "rtl" ? .rightToLeft : .leftToRight

        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: nsColor(color),
            .paragraphStyle: paragraph,
        ]
        if options.letterSpacing != 0 {
            attributes[.kern] = CGFloat(options.letterSpacing)
        }
        if hasToken(options.textDecorationLine, "underline") {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            if !options.textDecorationColor.isEmpty {
                attributes[.underlineColor] = nsColor(NtuiRuntime.parseColor(options.textDecorationColor, fallback: color))
            }
        }
        if hasToken(options.textDecorationLine, "line-through") {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            if !options.textDecorationColor.isEmpty {
                attributes[.strikethroughColor] = nsColor(NtuiRuntime.parseColor(options.textDecorationColor, fallback: color))
            }
        }
        if !options.textShadow.isEmpty {
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 2.0
            shadow.shadowOffset = NSSize(width: 1.0, height: -1.0)
            shadow.shadowColor = NSColor(deviceWhite: 0.0, alpha: 0.35)
            attributes[.shadow] = shadow
        }

        let attributed = NSMutableAttributedString(string: text, attributes: attributes)
        if options.wordSpacing != 0 {
            let ns = text as NSString
            for index in 0..<ns.length where ns.character(at: index) == UInt16(UnicodeScalar(" ").value) {
                attributed.addAttribute(.kern, value: CGFloat(options.letterSpacing + options.wordSpacing), range: NSRange(location: index, length: 1))
            }
        }
        attributed.draw(with: NSRect(x: 0, y: 0, width: imageWidth, height: imageHeight),
                        options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()

        guard let image = bitmap.cgImage, let textureLoader = textureLoader else { return nil }
        let textureOptions: [MTKTextureLoader.Option: Any] = [
            .SRGB: false,
            .origin: MTKTextureLoader.Origin.topLeft,
        ]
        let texture: MTLTexture
        do {
            texture = try textureLoader.newTexture(cgImage: image, options: textureOptions)
        } catch {
            NSLog("ntui_macos_renderer: failed to create text texture: %@", "\(error)")
            return nil
        }
        appkitFallbackTextureCount += 1
        appkitFallbackTextureBytes += UInt64(imageWidth * imageHeight * 4)
        return (texture, imageWidth, imageHeight)
    }

    @discardableResult
    func drawTextAppKit(
        text: String, x: Double, baselineY: Double, boxWidth: Double, fontSize: Double, lineHeight: Double, baselineOffset: Double,
        fontWeight: Int, textAlign: String, fontFamily: String, fontStyle: String, color: NtuiColor, options: NtuiTextRenderOptions
    ) -> Bool {
        guard let encoder = encoder, color.a > 0 else { return true }
        guard let result = createAppKitTextTexture(
            text: text, boxWidth: boxWidth, fontSize: fontSize, lineHeight: lineHeight, fontWeight: fontWeight,
            textAlign: textAlign, fontFamily: fontFamily, fontStyle: fontStyle, color: color, options: options
        ) else { return true }

        var textTop = baselineY - fontSize
        if baselineOffset > 0 { textTop = baselineY - baselineOffset }
        var vertices = makeQuad(x, textTop, Double(result.width), Double(result.height),
                                NtuiColor(r: 1, g: 1, b: 1, a: 1), flipTexY: true)
        if let pipeline = texturePipeline {
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBytes(&vertices, length: vertices.count * MemoryLayout<Float>.stride, index: 0)
            encoder.setFragmentTexture(result.texture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
        return true
    }

    // MARK: - font registration (CoreText only, for the AppKit fallback)

    @discardableResult
    func registerFontAsset(resourcePath: String, family: String, assetPath: String, weight: Int, style: String) -> Bool {
        if assetPath.isEmpty { return false }
        var path = assetPath
        if !(path as NSString).isAbsolutePath && !resourcePath.isEmpty {
            path = (resourcePath as NSString).appendingPathComponent(path)
        }
        let url = URL(fileURLWithPath: path)
        let registered = CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        return registered
    }

    // MARK: - memory logging (mirrors ntui_macos_metal_log_renderer_memory)

    func logRendererMemory() {
        guard Logs.memoryOrRender else { return }
        Logs.write("macos_renderer_memory frame=\(framesSubmitted) fontTextures=\(fontTextureCount) fontTextureBytes=\(fontTextureBytes) appkitFallbackTextures=\(appkitFallbackTextureCount) appkitFallbackBytes=\(appkitFallbackTextureBytes)\n")
    }
}
