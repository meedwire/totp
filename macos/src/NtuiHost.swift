// Phase F: Swift port of the host-loop half of ntui_macos_renderer.c. Ties the
// dylib runtime (NtuiRuntime) to the Metal backend (NtuiMetalRenderer): drives
// ntui_render_frame, iterates the command stream, applies DPR scaling + the
// opacity stack, and dispatches each command to Metal — a faithful 1:1 port of
// ntui_macos_renderer_render / _touch / _scroll / _wait_timers.

import Foundation
import MetalKit

final class NtuiHost {
    private let runtime: NtuiRuntime
    private let metal: NtuiMetalRenderer

    private var opacityStack = [Double]()
    private var currentOpacity = 1.0

    init() {
        let metal = NtuiMetalRenderer()
        self.metal = metal
        self.runtime = NtuiRuntime(fontRegistrar: { resourcePath, family, assetPath, weight, style in
            metal.registerFontAsset(resourcePath: resourcePath, family: family, assetPath: assetPath, weight: weight, style: style)
        })
        loadAtlasResource()
    }

    // Load the committed baked A8 atlas bundled as an app Resource (Phase F: the
    // atlas is no longer embedded via font_atlas_a8.S).
    private func loadAtlasResource() {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("font-atlas-sans-serif.a8.bin"),
              let data = try? Data(contentsOf: url) else {
            return
        }
        metal.setAtlasBytes([UInt8](data))
    }

    var lastError: String? { runtime.lastError }

    func setLibraryPath(_ path: String?) { runtime.setLibraryPath(path) }
    func setResourcePath(_ path: String?) { runtime.setResourcePath(path) }

    // Initialize the TS runtime on the CALLING thread. This MUST be invoked once
    // on the main thread during app setup, before the NtuiTimerWaiter thread is
    // started. The self-hosted TS GC does a conservative stack scan of only the
    // currently-collecting thread; if the runtime init / first allocation / GC
    // init ran (racily) on the waiter thread, a collect there would free Values
    // live-rooted on the main render thread (or vice-versa) — a cross-thread
    // use-after-free that surfaces as an EXC_BAD_ACCESS dereferencing the GC
    // "ntscgcv1" header magic. Doing init on main first makes ensureRuntime() a
    // no-op on the waiter thread, whose only TS call is then the alloc-free
    // ntsc_timer_wait_ready_host blocking primitive — keeping all TS allocation
    // (and every GC collect) single-threaded on main.
    @discardableResult
    func warmUpRuntime() -> Bool { runtime.ensureRuntime() }

    // MARK: - opacity stack (mirrors the .c opacity helpers)

    private func clampOpacity(_ value: Double) -> Double {
        if !value.isFinite { return 1.0 }
        if value <= 0.0 { return 0.0 }
        if value >= 1.0 { return 1.0 }
        return value
    }

    private func resetOpacityStack() {
        opacityStack.removeAll(keepingCapacity: true)
        currentOpacity = 1.0
    }

    private func applyOpacity(_ color: NtuiColor) -> NtuiColor {
        var out = color
        out.a *= clampOpacity(currentOpacity)
        return out
    }

    private func beginOpacityLayer(_ x: Double, _ y: Double, _ width: Double, _ height: Double, _ opacity: Double) {
        if opacityStack.count >= 32 { return }
        let clamped = clampOpacity(opacity)
        opacityStack.append(currentOpacity)
        currentOpacity = clampOpacity(currentOpacity * clamped)
        if Logs.render {
            Logs.write(String(format: "ntui_macos_renderer: opacity_layer begin x=%.2f y=%.2f width=%.2f height=%.2f opacity=%.3f effective=%.3f depth=%d\n",
                              x, y, width, height, clamped, currentOpacity, opacityStack.count))
        }
    }

    private func endOpacityLayer() {
        if opacityStack.isEmpty {
            currentOpacity = 1.0
            if Logs.render { Logs.write("ntui_macos_renderer: opacity_layer end underflow\n") }
            return
        }
        currentOpacity = opacityStack.removeLast()
        if Logs.render {
            Logs.write(String(format: "ntui_macos_renderer: opacity_layer end effective=%.3f depth=%d\n", currentOpacity, opacityStack.count))
        }
    }

    private func isValidRect(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> Bool {
        x.isFinite && y.isFinite && width.isFinite && height.isFinite && width > 0 && height > 0
    }

    // MARK: - render (mirrors ntui_macos_renderer_render)

    @discardableResult
    func render(view: MTKView, drawableWidth: Int, drawableHeight: Int, scaleMillis: Int) -> Int {
        if drawableWidth <= 0 || drawableHeight <= 0 { return 0 }
        if !runtime.ensureRuntime() { return 0 }

        let normalizedScaleMillis = NtuiRuntime.normalizeScaleMillis(scaleMillis)
        let scale = Double(normalizedScaleMillis) / 1000.0
        let layoutWidth = Int(max(1.0, (Double(drawableWidth) / scale + 0.5).rounded(.down)))
        let layoutHeight = Int(max(1.0, (Double(drawableHeight) / scale + 0.5).rounded(.down)))
        runtime.tick(0)
        let count = runtime.renderFrame(layoutWidth: layoutWidth, layoutHeight: layoutHeight, dpr: 1)

        if !metal.beginFrame(view: view, drawableWidth: drawableWidth, drawableHeight: drawableHeight) { return 0 }
        resetOpacityStack()
        metal.resetClipStack()

        // P2b/06-c: caminho bulk — snapshot SoA lido por ponteiro (3 FFI/frame)
        // substitui a leitura campo-a-campo; fallback automatico quando a dylib
        // nao exporta o snapshot.
        if let snap = runtime.frameSnapshot(), snap.count == count {
            renderFromSnapshot(snap, scale: scale, scaleMillis: normalizedScaleMillis)
            resetOpacityStack()
            metal.resetClipStack()
            if !metal.endFrame() { return 0 }
            runtime.collectGcFramePaced("finish_frame")
            runtime.logMemoryCounters("finish_frame")
            metal.logRendererMemory()
            return count
        }

        for i in 0..<count {
            let kind = runtime.commandKind(i)
            let x = runtime.scalePx(runtime.commandX(i), scale)
            let y = runtime.scalePx(runtime.commandY(i), scale)
            let width = runtime.scalePx(runtime.commandWidth(i), scale)
            let height = runtime.scalePx(runtime.commandHeight(i), scale)

            switch kind {
            case 5:
                metal.pushClipRect(x, y, width, height)
                if Logs.render {
                    Logs.write(String(format: "cmd_snapshot kind=clipPushRect rect={x=%.2f y=%.2f width=%.2f height=%.2f} stackDepth=%d scale_millis=%d\n",
                                      x, y, width, height, metal.clipStackDepth, normalizedScaleMillis))
                }
            case 6:
                let radius = runtime.scalePx(runtime.commandBorderRadius(i), scale)
                metal.pushClipRRect(x, y, width, height, radius)
                if Logs.render {
                    Logs.write(String(format: "cmd_snapshot kind=clipPushRRect rect={x=%.2f y=%.2f width=%.2f height=%.2f} radius=%.2f fallback=rect stackDepth=%d scale_millis=%d\n",
                                      x, y, width, height, radius, metal.clipStackDepth, normalizedScaleMillis))
                }
            case 7:
                metal.popClip()
                if Logs.render {
                    Logs.write(String(format: "cmd_snapshot kind=clipPop stackDepth=%d scale_millis=%d\n", metal.clipStackDepth, normalizedScaleMillis))
                }
            case 9:
                let opacity = runtime.commandOpacity(i)
                beginOpacityLayer(x, y, width, height, opacity)
            case 10:
                endOpacityLayer()
            case 1:
                let color = applyOpacity(NtuiRuntime.parseColor(runtime.commandColor(i), fallback: NtuiColor(r: 0, g: 0, b: 0, a: 1)))
                if isValidRect(x, y, width, height) {
                    metal.drawRect(x, y, width, height, color)
                }
            case 3:
                let fill = applyOpacity(NtuiRuntime.parseColor(runtime.commandColor(i), fallback: NtuiColor(r: 0, g: 0, b: 0, a: 0)))
                let border = applyOpacity(NtuiRuntime.parseColor(runtime.commandBorderColor(i), fallback: NtuiColor(r: 0, g: 0, b: 0, a: 1)))
                let borderWidth = runtime.scalePx(runtime.commandBorderWidth(i), scale)
                let borderRadius = runtime.scalePx(runtime.commandBorderRadius(i), scale)
                if isValidRect(x, y, width, height) {
                    metal.drawBox(x, y, width, height, borderWidth, borderRadius, fill, border)
                }
            case 2:
                dispatchText(i, x: x, y: y, scale: scale, scaleMillis: normalizedScaleMillis)
            default:
                break
            }
        }

        resetOpacityStack()
        metal.resetClipStack()
        if !metal.endFrame() { return 0 }
        runtime.collectGcFramePaced("finish_frame")
        runtime.logMemoryCounters("finish_frame")
        metal.logRendererMemory()
        return count
    }

    private func renderFromSnapshot(_ snap: NtuiRuntime.FrameSnapshot, scale: Double, scaleMillis: Int) {
        let S = snap.stride
        func fld(_ i: Int, _ o: Int) -> Double { Double(snap.nums[i * S + o]) }
        func str(_ i: Int, _ o: Int) -> String {
            let off = Int(snap.nums[i * S + o])
            let len = Int(snap.nums[i * S + o + 1])
            if len <= 0 { return "" }
            return String(utf16CodeUnits: snap.text + off, count: len)
        }
        for i in 0..<snap.count {
            let kind = Int(snap.nums[i * S])
            let x = runtime.scalePx(fld(i, 1), scale)
            let y = runtime.scalePx(fld(i, 2), scale)
            let width = runtime.scalePx(fld(i, 3), scale)
            let height = runtime.scalePx(fld(i, 4), scale)
            switch kind {
            case 5:
                metal.pushClipRect(x, y, width, height)
            case 6:
                let radius = runtime.scalePx(fld(i, 5), scale)
                metal.pushClipRRect(x, y, width, height, radius)
            case 7:
                metal.popClip()
            case 9:
                beginOpacityLayer(x, y, width, height, fld(i, 7))
            case 10:
                endOpacityLayer()
            case 1:
                let color = applyOpacity(NtuiRuntime.parseColor(str(i, 8), fallback: NtuiColor(r: 0, g: 0, b: 0, a: 1)))
                if isValidRect(x, y, width, height) {
                    metal.drawRect(x, y, width, height, color)
                }
            case 3:
                let fill = applyOpacity(NtuiRuntime.parseColor(str(i, 8), fallback: NtuiColor(r: 0, g: 0, b: 0, a: 0)))
                let border = applyOpacity(NtuiRuntime.parseColor(str(i, 10), fallback: NtuiColor(r: 0, g: 0, b: 0, a: 1)))
                let borderWidth = runtime.scalePx(fld(i, 6), scale)
                let borderRadius = runtime.scalePx(fld(i, 5), scale)
                if isValidRect(x, y, width, height) {
                    metal.drawBox(x, y, width, height, borderWidth, borderRadius, fill, border)
                }
            case 2:
                dispatchTextFromSnapshot(i, snap: snap, x: x, y: y, scale: scale, scaleMillis: scaleMillis)
            default:
                break
            }
        }
    }

    private func dispatchTextFromSnapshot(_ i: Int, snap: NtuiRuntime.FrameSnapshot, x: Double, y: Double, scale: Double, scaleMillis: Int) {
        let S = snap.stride
        func fld(_ o: Int) -> Double { Double(snap.nums[i * S + o]) }
        func str(_ o: Int) -> String {
            let off = Int(snap.nums[i * S + o])
            let len = Int(snap.nums[i * S + o + 1])
            if len <= 0 { return "" }
            return String(utf16CodeUnits: snap.text + off, count: len)
        }
        let text = str(12)
        let boxWidth = runtime.scalePx(fld(17), scale)
        let fontSize = runtime.scalePx(fld(14), scale)
        let lineHeight = runtime.scalePx(fld(15), scale)
        let baselineOffset = runtime.scalePx(fld(16), scale)
        let fontWeight = Int(fld(18))
        let textAlign = str(19)
        let fontFamily = str(21)
        let fontStyle = str(23)
        // v1: textRenderOptions ainda via runtime (poucas FFI por comando de texto;
        // as strings raras entram no snapshot numa v2 se aparecerem no perfil).
        let options = runtime.textRenderOptions(i, scale: scale)
        let color = applyOpacity(NtuiRuntime.parseColor(str(8), fallback: NtuiColor(r: 0, g: 0, b: 0, a: 1)))

        guard !text.isEmpty, x.isFinite, y.isFinite, boxWidth > 0, fontSize > 0 else { return }

        if metal.textNeedsAppKitFallback(options) {
            metal.drawTextAppKit(text: text, x: x, baselineY: y, boxWidth: boxWidth, fontSize: fontSize,
                                 lineHeight: lineHeight, baselineOffset: baselineOffset, fontWeight: fontWeight,
                                 textAlign: textAlign, fontFamily: fontFamily, fontStyle: fontStyle, color: color, options: options)
            return
        }
        if runtime.hasTextQuads {
            if let quads = runtime.prepareTextQuads(i, scaleMillis: scaleMillis) {
                metal.drawTextQuads(packed: quads.pointer, floatCount: quads.floatCount,
                                    atlasWidth: quads.atlasWidth, atlasHeight: quads.atlasHeight,
                                    quadsWidth: quads.width, quadsHeight: quads.height, lineCount: quads.lineCount,
                                    x: x, baselineY: y, boxWidth: boxWidth, fontSize: fontSize,
                                    lineHeight: lineHeight, baselineOffset: baselineOffset, color: color, options: options)
            }
            return
        }
        metal.drawTextAppKit(text: text, x: x, baselineY: y, boxWidth: boxWidth, fontSize: fontSize,
                             lineHeight: lineHeight, baselineOffset: baselineOffset, fontWeight: fontWeight,
                             textAlign: textAlign, fontFamily: fontFamily, fontStyle: fontStyle, color: color, options: options)
    }

    private func dispatchText(_ i: Int, x: Double, y: Double, scale: Double, scaleMillis: Int) {
        let text = runtime.commandText(i)
        let boxWidth = runtime.scalePx(runtime.commandBoxWidth(i), scale)
        let fontSize = runtime.scalePx(runtime.commandFontSize(i), scale)
        let lineHeight = runtime.scalePx(runtime.commandLineHeight(i), scale)
        let baselineOffset = runtime.scalePx(runtime.commandBaselineOffset(i), scale)
        let fontWeight = runtime.commandFontWeight(i)
        let textAlign = runtime.commandTextAlign(i)
        let fontFamily = runtime.commandFontFamily(i)
        let fontStyle = runtime.commandFontStyle(i)
        let options = runtime.textRenderOptions(i, scale: scale)
        let color = applyOpacity(NtuiRuntime.parseColor(runtime.commandColor(i), fallback: NtuiColor(r: 0, g: 0, b: 0, a: 1)))

        guard !text.isEmpty, x.isFinite, y.isFinite, boxWidth > 0, fontSize > 0 else { return }

        // Phase C4/F: TS-computed glyph quads are the primary path; AppKit/CoreText
        // handles shadows / vertical writing-mode.
        if metal.textNeedsAppKitFallback(options) {
            metal.drawTextAppKit(text: text, x: x, baselineY: y, boxWidth: boxWidth, fontSize: fontSize,
                                 lineHeight: lineHeight, baselineOffset: baselineOffset, fontWeight: fontWeight,
                                 textAlign: textAlign, fontFamily: fontFamily, fontStyle: fontStyle, color: color, options: options)
            return
        }
        if runtime.hasTextQuads {
            if let quads = runtime.prepareTextQuads(i, scaleMillis: scaleMillis) {
                metal.drawTextQuads(packed: quads.pointer, floatCount: quads.floatCount,
                                    atlasWidth: quads.atlasWidth, atlasHeight: quads.atlasHeight,
                                    quadsWidth: quads.width, quadsHeight: quads.height, lineCount: quads.lineCount,
                                    x: x, baselineY: y, boxWidth: boxWidth, fontSize: fontSize,
                                    lineHeight: lineHeight, baselineOffset: baselineOffset, color: color, options: options)
            }
            // else: no visible glyphs (whitespace-only) — nothing to draw.
            return
        }
        // Safety: dylib without the quad accessors — use the AppKit fallback.
        metal.drawTextAppKit(text: text, x: x, baselineY: y, boxWidth: boxWidth, fontSize: fontSize,
                             lineHeight: lineHeight, baselineOffset: baselineOffset, fontWeight: fontWeight,
                             textAlign: textAlign, fontFamily: fontFamily, fontStyle: fontStyle, color: color, options: options)
    }

    // MARK: - input (mirrors ntui_macos_renderer_touch / _scroll)

    @discardableResult
    func touch(x: Float, y: Float, phase: Int, scaleMillis: Int) -> Int {
        if !runtime.ensureRuntime() { return 0 }
        let normalized = NtuiRuntime.normalizeScaleMillis(scaleMillis)
        let scale = Double(normalized) / 1000.0
        let logicalX = Int(Double(x).rounded())
        let logicalY = Int(Double(y).rounded())
        let physicalX = Int((Double(x) * scale).rounded())
        let physicalY = Int((Double(y) * scale).rounded())
        return runtime.handleTouch(physicalX: physicalX, physicalY: physicalY, logicalX: logicalX, logicalY: logicalY, phase: phase)
    }

    // Entrada de texto. O host so entrega o EVENTO; foco, cursor e o que backspace
    // apaga sao decididos no modelo neutro dentro do dylib, o mesmo do Android e do
    // terminal POS.
    @discardableResult
    func key(keyCode: Int, modifiers: Int) -> Int {
        if !runtime.ensureRuntime() { return 0 }
        return runtime.handleKey(keyCode: keyCode, modifiers: modifiers)
    }

    @discardableResult
    func insertText(_ text: String) -> Int {
        if !runtime.ensureRuntime() { return 0 }
        return runtime.insertText(text)
    }

    @discardableResult
    func setMarkedText(_ text: String) -> Int {
        if !runtime.ensureRuntime() { return 0 }
        return runtime.setMarkedText(text)
    }

    @discardableResult
    func clearMarkedText() -> Int {
        if !runtime.ensureRuntime() { return 0 }
        return runtime.clearMarkedText()
    }

    func inputFocused() -> Bool {
        if !runtime.ensureRuntime() { return false }
        return runtime.inputFocused()
    }

    @discardableResult
    func scroll(x: Float, y: Float, deltaX: Float, deltaY: Float, scaleMillis: Int) -> Int {
        if !runtime.ensureRuntime() { return 0 }
        let normalized = NtuiRuntime.normalizeScaleMillis(scaleMillis)
        let scale = Double(normalized) / 1000.0
        let logicalX = Int(Double(x).rounded())
        let logicalY = Int(Double(y).rounded())
        let physicalX = Int((Double(x) * scale).rounded())
        let physicalY = Int((Double(y) * scale).rounded())
        let deltaXi = Int(Double(deltaX).rounded())
        let deltaYi = Int(Double(deltaY).rounded())
        if Logs.render {
            Logs.write(String(format: "cmd_snapshot kind=scroll logical=(%.2f,%.2f) delta=(%.2f,%.2f) phase=1 scale_millis=%d\n",
                              Double(x), Double(y), Double(deltaX), Double(deltaY), normalized))
        }
        let handled = runtime.handleScroll(physicalX: physicalX, physicalY: physicalY, logicalX: logicalX, logicalY: logicalY, deltaX: deltaXi, deltaY: deltaYi)
        if Logs.scroll {
            Logs.write("ntui_scroll platform=macos logical=(\(logicalX),\(logicalY)) physical=(\(physicalX),\(physicalY)) delta=(\(deltaXi),\(deltaYi)) phase=1 source=2 handled=\(handled) scale_millis=\(normalized)\n")
        }
        return handled
    }

    // MARK: - timers (mirrors ntui_macos_renderer_wait_timers / _shutdown_timers)

    func waitTimers() -> Int32 {
        if !runtime.ensureRuntime() { return -1 }
        return runtime.waitTimers()
    }

    func shutdownTimers() {
        if !runtime.ensureRuntime() { return }
        runtime.shutdownTimers()
    }
}
