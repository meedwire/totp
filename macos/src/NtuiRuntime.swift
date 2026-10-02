// Phase F: the macOS example ships ZERO C/Obj-C runtime. This file is the Swift
// port of the FFI/host-plumbing half of the old ntui_macos_renderer.c — it
// dlopen's the compiled TS dylib, binds every `ntui_*` accessor, marshals the
// value-ABI (tagged ints / heap Number objects), reconstructs command strings
// and parses colors. It is a faithful 1:1 port; where Swift idioms differ from C
// (UTF-16 → String, optionals) the exact numeric behavior is preserved.

import Darwin
import Foundation

// uintptr_t tagged value (mirrors NtuiValue).
typealias NtuiValue = UInt

private let NTUI_VALUE_NULL: NtuiValue = 0x0a
private let NTUI_VALUE_POS_INFINITY: NtuiValue = 0x2a
private let NTUI_VALUE_NEG_INFINITY: NtuiValue = 0x32
private let NTUI_VALUE_TAG_MASK: NtuiValue = 0x7
private let NTUI_VALUE_INT_TAG: NtuiValue = 0x1
private let NTUI_VALUE_REF_TAG: NtuiValue = 0x0
private let NTUI_HEAP_KIND_NUMBER: UInt64 = 6

// Mirrors NtuiNumberObject { kind, flags, shape, slots, value } (heap number).
private struct NtuiNumberObject {
    var kind: UInt64
    var flags: UInt64
    var shape: UInt64
    var slots: UInt64
    var value: Double
}

typealias NtuiFn0 = @convention(c) (NtuiValue) -> NtuiValue
typealias NtuiFn1 = @convention(c) (NtuiValue, NtuiValue) -> NtuiValue
typealias NtuiFn2 = @convention(c) (NtuiValue, NtuiValue, NtuiValue) -> NtuiValue
typealias NtuiFn3 = @convention(c) (NtuiValue, NtuiValue, NtuiValue, NtuiValue) -> NtuiValue
typealias NtuiFn5 = @convention(c) (NtuiValue, NtuiValue, NtuiValue, NtuiValue, NtuiValue, NtuiValue) -> NtuiValue
typealias NtuiFn8 = @convention(c) (
    NtuiValue, NtuiValue, NtuiValue, NtuiValue, NtuiValue, NtuiValue, NtuiValue, NtuiValue, NtuiValue
) -> NtuiValue
typealias NtuiMainFn = @convention(c) () -> Void
typealias NtuiGcCollectFn = @convention(c) () -> UInt64
typealias NtuiGcCollectAutoFn = @convention(c) (UnsafePointer<CChar>?) -> UInt64
typealias NtuiGcFrameFn = @convention(c) () -> UInt64
typealias NtuiTimerWaitFn = @convention(c) () -> Int32
typealias NtuiTimerShutdownFn = @convention(c) () -> Void

// Mirrors NtuiMacosColor (r,g,b,a in 0..1 doubles).
struct NtuiColor {
    var r: Double
    var g: Double
    var b: Double
    var a: Double
}

// Mirrors NtuiMacosTextRenderOptions.
struct NtuiTextRenderOptions {
    var lineIndex: Int = -1
    var runIndex: Int = -1
    var letterSpacing: Double = 0
    var wordSpacing: Double = 0
    var textDecorationThickness: Double = 0
    var textUnderlineOffset: Double = 0
    var textIndent: Double = 0
    var textDecorationLine: String = "none"
    var textDecorationStyle: String = "solid"
    var textDecorationColor: String = ""
    var textUnderlinePosition: String = "auto"
    var textShadow: String = ""
    var direction: String = "ltr"
    var writingMode: String = "horizontal-tb"
}

final class NtuiRuntime {
    private var handle: UnsafeMutableRawPointer?
    private var mainCalled = false
    private(set) var initialized = false
    private(set) var lastError: String?

    // Required entry points.
    private var mainFn: NtuiMainFn!
    private var initFn: NtuiFn0!
    private var renderFrameFn: NtuiFn3!
    private var tickFn: NtuiFn1!
    private var handleTouchFn: NtuiFn5!
    private var handleScrollFn: NtuiFn8!
    // Entrada de texto. `optional` de proposito: um app compilado antes desta ponte
    // continua carregando, so sem teclado — o host nao pode deixar de subir por
    // causa de um simbolo novo.
    private var handleKeyFn: NtuiFn2?
    private var compositionBeginFn: NtuiFn0?
    private var compositionPushByteFn: NtuiFn1?
    private var compositionCommitFn: NtuiFn0?
    private var inputFocusedFn: NtuiFn0?
    private var inputSetMarkedFn: NtuiFn0?
    private var inputClearMarkedFn: NtuiFn0?
    private var commandKindFn: NtuiFn1!
    private var commandXFn: NtuiFn1!
    private var commandYFn: NtuiFn1!
    private var commandWidthFn: NtuiFn1!
    private var commandHeightFn: NtuiFn1!
    private var commandFontSizeFn: NtuiFn1!
    private var commandBaselineOffsetFn: NtuiFn1!
    private var commandBoxWidthFn: NtuiFn1!
    private var commandLineHeightFn: NtuiFn1!
    private var commandFontWeightFn: NtuiFn1!
    private var commandBorderWidthFn: NtuiFn1!
    private var commandBorderRadiusFn: NtuiFn1!
    private var commandOpacityFn: NtuiFn1!
    private var commandColorLenFn: NtuiFn1!
    private var commandColorCharFn: NtuiFn2!
    private var commandTextLenFn: NtuiFn1!
    private var commandTextCharFn: NtuiFn2!
    private var commandTextAlignLenFn: NtuiFn1!
    private var commandTextAlignCharFn: NtuiFn2!
    private var commandFontFamilyLenFn: NtuiFn1!
    private var commandFontFamilyCharFn: NtuiFn2!
    private var commandFontStyleLenFn: NtuiFn1!
    private var commandFontStyleCharFn: NtuiFn2!
    private var commandBorderColorLenFn: NtuiFn1!
    private var commandBorderColorCharFn: NtuiFn2!

    // Optional accessors (may be absent on older dylibs).
    private var fontAssetCountFn: NtuiFn0?
    private var fontAssetWeightFn: NtuiFn1?
    private var fontAssetFamilyLenFn: NtuiFn1?
    private var fontAssetFamilyCharFn: NtuiFn2?
    private var fontAssetPathLenFn: NtuiFn1?
    private var fontAssetPathCharFn: NtuiFn2?
    private var fontAssetStyleLenFn: NtuiFn1?
    private var fontAssetStyleCharFn: NtuiFn2?
    private var commandLineIndexFn: NtuiFn1?
    private var commandRunIndexFn: NtuiFn1?
    private var commandLetterSpacingFn: NtuiFn1?
    private var commandWordSpacingFn: NtuiFn1?
    private var commandTextDecorationThicknessFn: NtuiFn1?
    private var commandTextUnderlineOffsetFn: NtuiFn1?
    private var commandTextIndentFn: NtuiFn1?
    private var commandTextDecorationLineLenFn: NtuiFn1?
    private var commandTextDecorationLineCharFn: NtuiFn2?
    private var commandTextDecorationStyleLenFn: NtuiFn1?
    private var commandTextDecorationStyleCharFn: NtuiFn2?
    private var commandTextDecorationColorLenFn: NtuiFn1?
    private var commandTextDecorationColorCharFn: NtuiFn2?
    private var commandTextUnderlinePositionLenFn: NtuiFn1?
    private var commandTextUnderlinePositionCharFn: NtuiFn2?
    private var commandTextShadowLenFn: NtuiFn1?
    private var commandTextShadowCharFn: NtuiFn2?
    private var commandDirectionLenFn: NtuiFn1?
    private var commandDirectionCharFn: NtuiFn2?
    private var commandWritingModeLenFn: NtuiFn1?
    private var commandWritingModeCharFn: NtuiFn2?

    // Self-hosted text (Phase C4) quad accessors.
    private var textQuadsPrepareFn: NtuiFn2?
    private var textQuadsPtrFn: NtuiFn0?
    private var textQuadsCountFn: NtuiFn0?
    private var textQuadsWidthFn: NtuiFn0?
    private var textQuadsHeightFn: NtuiFn0?
    private var textQuadsLineCountFn: NtuiFn0?
    private var textQuadsAtlasWidthFn: NtuiFn0?
    private var textQuadsAtlasHeightFn: NtuiFn0?

    private var gcCollectFn: NtuiGcCollectFn?
    private var gcCollectAutoFn: NtuiGcCollectAutoFn?
    private var gcCollectFrameFn: NtuiGcFrameFn?
    private var snapshotPrepareFn: NtuiFn0?
    private var snapshotPtrFn: NtuiFn0?
    private var snapshotTextPtrFn: NtuiFn0?
    private var snapshotStrideFn: NtuiFn0?
    private var timerWaitFn: NtuiTimerWaitFn?
    private var timerShutdownFn: NtuiTimerShutdownFn?

    // Memory counters (globals in the dylib).
    private var memAllocations: UnsafePointer<UInt64>?
    private var memBytes: UnsafePointer<UInt64>?
    private var memLiveAllocations: UnsafePointer<UInt64>?
    private var memLiveBytes: UnsafePointer<UInt64>?
    private var memHeapAllocations: UnsafePointer<UInt64>?
    private var memHeapBytes: UnsafePointer<UInt64>?
    private var memRawAllocations: UnsafePointer<UInt64>?
    private var memRawBytes: UnsafePointer<UInt64>?
    private var gcCyclesPtr: UnsafePointer<UInt64>?
    private var gcCollectedBytesPtr: UnsafePointer<UInt64>?

    private var libraryPath = ""
    private var resourcePath = ""
    private let fontRegistrar: (_ resourcePath: String, _ family: String, _ assetPath: String, _ weight: Int, _ style: String) -> Void

    // fontRegistrar registers a discovered font asset with CoreText (delegated to
    // the Metal renderer, mirroring ntui_macos_metal_register_font_asset's role).
    init(fontRegistrar: @escaping (String, String, String, Int, String) -> Void) {
        self.fontRegistrar = fontRegistrar
    }

    // MARK: - value-ABI marshalling (mirrors ntui_macos_box_int / value_to_double / value_to_int)

    func boxInt(_ value: Int) -> NtuiValue {
        return (NtuiValue(bitPattern: value) << 3) | NTUI_VALUE_INT_TAG
    }

    func valueToDouble(_ value: NtuiValue) -> Double {
        if value & NTUI_VALUE_TAG_MASK == NTUI_VALUE_INT_TAG {
            return Double(Int(bitPattern: value) >> 3)
        }
        if value != 0 && value & NTUI_VALUE_TAG_MASK == NTUI_VALUE_REF_TAG {
            if let obj = UnsafeRawPointer(bitPattern: value)?.assumingMemoryBound(to: NtuiNumberObject.self) {
                if obj.pointee.kind == NTUI_HEAP_KIND_NUMBER { return obj.pointee.value }
            }
        }
        if value == NTUI_VALUE_POS_INFINITY { return .infinity }
        if value == NTUI_VALUE_NEG_INFINITY { return -.infinity }
        return .nan
    }

    func valueToInt(_ value: NtuiValue) -> Int {
        let number = valueToDouble(value)
        if !number.isFinite { return 0 }
        if number > Double(Int32.max) { return Int(Int32.max) }
        if number < Double(Int32.min) { return Int(Int32.min) }
        return Int(number.rounded())
    }

    private var nullValue: NtuiValue { NTUI_VALUE_NULL }

    // MARK: - dlopen + symbol binding

    func setLibraryPath(_ path: String?) { libraryPath = path ?? "" }

    func setResourcePath(_ path: String?) {
        resourcePath = path ?? ""
        // Mirror ntui_macos_renderer_set_resource_path: seed the default bundled font.
        if !resourcePath.isEmpty {
            fontRegistrar(resourcePath, "Roboto", "fonts/Roboto-Regular.ttf", 400, "normal")
        }
    }

    @discardableResult
    func ensureRuntime() -> Bool {
        if initialized { return true }
        if handle == nil {
            if libraryPath.isEmpty {
                lastError = "runtime library path is not configured"
                return false
            }
            guard let h = dlopen(libraryPath, RTLD_NOW | RTLD_LOCAL) else {
                let err = dlerror().map { String(cString: $0) } ?? "dlopen failed"
                lastError = "\(libraryPath): \(err)"
                return false
            }
            handle = h
            if !loadSymbols() { return false }
        }
        if !mainCalled {
            mainFn()
            mainCalled = true
        }
        _ = initFn(nullValue)
        registerFontAssets()
        initialized = true
        return true
    }

    private func required<T>(_ name: String, _ type: T.Type) -> T? {
        dlerror()
        guard let sym = dlsym(handle, name) else {
            let err = dlerror().map { String(cString: $0) } ?? "missing symbol"
            lastError = "\(name): \(err)"
            return nil
        }
        return unsafeBitCast(sym, to: T.self)
    }

    private func optional<T>(_ name: String, _ type: T.Type) -> T? {
        dlerror()
        guard let sym = dlsym(handle, name) else { dlerror(); return nil }
        dlerror()
        return unsafeBitCast(sym, to: T.self)
    }

    private func optionalCounter(_ name: String) -> UnsafePointer<UInt64>? {
        dlerror()
        var sym = dlsym(handle, name)
        if sym == nil && name.hasPrefix("_") {
            sym = dlsym(handle, String(name.dropFirst()))
        }
        dlerror()
        return sym.map { UnsafeRawPointer($0).assumingMemoryBound(to: UInt64.self) }
    }

    private func loadSymbols() -> Bool {
        guard let mainFn = required("main", NtuiMainFn.self) else { return false }
        self.mainFn = mainFn
        guard let initFn = required("ntui_init", NtuiFn0.self) else { return false }
        self.initFn = initFn
        guard let renderFrameFn = required("ntui_render_frame", NtuiFn3.self) else { return false }
        self.renderFrameFn = renderFrameFn
        guard let tickFn = required("ntui_tick", NtuiFn1.self) else { return false }
        self.tickFn = tickFn
        guard let handleTouchFn = required("ntui_handle_touch", NtuiFn5.self) else { return false }
        self.handleTouchFn = handleTouchFn
        guard let handleScrollFn = required("ntui_handle_scroll", NtuiFn8.self) else { return false }
        self.handleScrollFn = handleScrollFn
        handleKeyFn = optional("ntui_handle_key", NtuiFn2.self)
        compositionBeginFn = optional("ntui_input_composition_begin", NtuiFn0.self)
        compositionPushByteFn = optional("ntui_input_composition_push_byte", NtuiFn1.self)
        compositionCommitFn = optional("ntui_input_composition_commit", NtuiFn0.self)
        inputFocusedFn = optional("ntui_input_focused", NtuiFn0.self)
        inputSetMarkedFn = optional("ntui_input_set_marked", NtuiFn0.self)
        inputClearMarkedFn = optional("ntui_input_clear_marked", NtuiFn0.self)

        // Bind the required command accessors explicitly (keeps types exact).
        guard let ck = required("ntui_command_kind", NtuiFn1.self) else { return false }; commandKindFn = ck
        guard let cx = required("ntui_command_x", NtuiFn1.self) else { return false }; commandXFn = cx
        guard let cy = required("ntui_command_y", NtuiFn1.self) else { return false }; commandYFn = cy
        guard let cw = required("ntui_command_width", NtuiFn1.self) else { return false }; commandWidthFn = cw
        guard let ch = required("ntui_command_height", NtuiFn1.self) else { return false }; commandHeightFn = ch
        guard let fs = required("ntui_command_font_size", NtuiFn1.self) else { return false }; commandFontSizeFn = fs
        guard let bo = required("ntui_command_baseline_offset", NtuiFn1.self) else { return false }; commandBaselineOffsetFn = bo
        guard let bw = required("ntui_command_box_width", NtuiFn1.self) else { return false }; commandBoxWidthFn = bw
        guard let lh = required("ntui_command_line_height", NtuiFn1.self) else { return false }; commandLineHeightFn = lh
        guard let fw = required("ntui_command_font_weight", NtuiFn1.self) else { return false }; commandFontWeightFn = fw
        guard let bdw = required("ntui_command_border_width", NtuiFn1.self) else { return false }; commandBorderWidthFn = bdw
        guard let bdr = required("ntui_command_border_radius", NtuiFn1.self) else { return false }; commandBorderRadiusFn = bdr
        guard let op = required("ntui_command_opacity", NtuiFn1.self) else { return false }; commandOpacityFn = op
        guard let ccl = required("ntui_command_color_length", NtuiFn1.self) else { return false }; commandColorLenFn = ccl
        guard let ccc = required("ntui_command_color_char_code", NtuiFn2.self) else { return false }; commandColorCharFn = ccc
        guard let ctl = required("ntui_command_text_length", NtuiFn1.self) else { return false }; commandTextLenFn = ctl
        guard let ctc = required("ntui_command_text_char_code", NtuiFn2.self) else { return false }; commandTextCharFn = ctc
        guard let cal = required("ntui_command_text_align_length", NtuiFn1.self) else { return false }; commandTextAlignLenFn = cal
        guard let cac = required("ntui_command_text_align_char_code", NtuiFn2.self) else { return false }; commandTextAlignCharFn = cac
        guard let ffl = required("ntui_command_font_family_length", NtuiFn1.self) else { return false }; commandFontFamilyLenFn = ffl
        guard let ffc = required("ntui_command_font_family_char_code", NtuiFn2.self) else { return false }; commandFontFamilyCharFn = ffc
        guard let fsl = required("ntui_command_font_style_length", NtuiFn1.self) else { return false }; commandFontStyleLenFn = fsl
        guard let fsc = required("ntui_command_font_style_char_code", NtuiFn2.self) else { return false }; commandFontStyleCharFn = fsc
        guard let bcl = required("ntui_command_border_color_length", NtuiFn1.self) else { return false }; commandBorderColorLenFn = bcl
        guard let bcc = required("ntui_command_border_color_char_code", NtuiFn2.self) else { return false }; commandBorderColorCharFn = bcc

        fontAssetCountFn = optional("ntui_font_asset_count", NtuiFn0.self)
        fontAssetWeightFn = optional("ntui_font_asset_weight", NtuiFn1.self)
        fontAssetFamilyLenFn = optional("ntui_font_asset_family_length", NtuiFn1.self)
        fontAssetFamilyCharFn = optional("ntui_font_asset_family_char_code", NtuiFn2.self)
        fontAssetPathLenFn = optional("ntui_font_asset_path_length", NtuiFn1.self)
        fontAssetPathCharFn = optional("ntui_font_asset_path_char_code", NtuiFn2.self)
        fontAssetStyleLenFn = optional("ntui_font_asset_style_length", NtuiFn1.self)
        fontAssetStyleCharFn = optional("ntui_font_asset_style_char_code", NtuiFn2.self)
        commandLineIndexFn = optional("ntui_command_line_index", NtuiFn1.self)
        commandRunIndexFn = optional("ntui_command_run_index", NtuiFn1.self)
        commandLetterSpacingFn = optional("ntui_command_letter_spacing", NtuiFn1.self)
        commandWordSpacingFn = optional("ntui_command_word_spacing", NtuiFn1.self)
        commandTextDecorationThicknessFn = optional("ntui_command_text_decoration_thickness", NtuiFn1.self)
        commandTextUnderlineOffsetFn = optional("ntui_command_text_underline_offset", NtuiFn1.self)
        commandTextIndentFn = optional("ntui_command_text_indent", NtuiFn1.self)
        commandTextDecorationLineLenFn = optional("ntui_command_text_decoration_line_length", NtuiFn1.self)
        commandTextDecorationLineCharFn = optional("ntui_command_text_decoration_line_char_code", NtuiFn2.self)
        commandTextDecorationStyleLenFn = optional("ntui_command_text_decoration_style_length", NtuiFn1.self)
        commandTextDecorationStyleCharFn = optional("ntui_command_text_decoration_style_char_code", NtuiFn2.self)
        commandTextDecorationColorLenFn = optional("ntui_command_text_decoration_color_length", NtuiFn1.self)
        commandTextDecorationColorCharFn = optional("ntui_command_text_decoration_color_char_code", NtuiFn2.self)
        commandTextUnderlinePositionLenFn = optional("ntui_command_text_underline_position_length", NtuiFn1.self)
        commandTextUnderlinePositionCharFn = optional("ntui_command_text_underline_position_char_code", NtuiFn2.self)
        commandTextShadowLenFn = optional("ntui_command_text_shadow_length", NtuiFn1.self)
        commandTextShadowCharFn = optional("ntui_command_text_shadow_char_code", NtuiFn2.self)
        commandDirectionLenFn = optional("ntui_command_direction_length", NtuiFn1.self)
        commandDirectionCharFn = optional("ntui_command_direction_char_code", NtuiFn2.self)
        commandWritingModeLenFn = optional("ntui_command_writing_mode_length", NtuiFn1.self)
        commandWritingModeCharFn = optional("ntui_command_writing_mode_char_code", NtuiFn2.self)

        textQuadsPrepareFn = optional("ntui_command_text_quads_prepare", NtuiFn2.self)
        textQuadsPtrFn = optional("ntui_command_text_quads_ptr", NtuiFn0.self)
        textQuadsCountFn = optional("ntui_command_text_quads_count", NtuiFn0.self)
        textQuadsWidthFn = optional("ntui_command_text_quads_width", NtuiFn0.self)
        textQuadsHeightFn = optional("ntui_command_text_quads_height", NtuiFn0.self)
        textQuadsLineCountFn = optional("ntui_command_text_quads_line_count", NtuiFn0.self)
        textQuadsAtlasWidthFn = optional("ntui_command_text_quads_atlas_width", NtuiFn0.self)
        textQuadsAtlasHeightFn = optional("ntui_command_text_quads_atlas_height", NtuiFn0.self)
        snapshotPrepareFn = optional("ntui_frame_snapshot_prepare", NtuiFn0.self)
        snapshotPtrFn = optional("ntui_frame_snapshot_ptr", NtuiFn0.self)
        snapshotTextPtrFn = optional("ntui_frame_snapshot_text_ptr", NtuiFn0.self)
        snapshotStrideFn = optional("ntui_frame_snapshot_stride", NtuiFn0.self)

        gcCollectFn = optional("ntsc_gc_collect", NtuiGcCollectFn.self)
        gcCollectAutoFn = optional("ntsc_gc_collect_auto_if_needed", NtuiGcCollectAutoFn.self)
        gcCollectFrameFn = optional("ntsc_gc_collect_auto_frame", NtuiGcFrameFn.self)
        timerWaitFn = optional("ntsc_timer_wait_ready_host", NtuiTimerWaitFn.self)
        timerShutdownFn = optional("ntsc_timer_shutdown_waiters", NtuiTimerShutdownFn.self)

        memAllocations = optionalCounter("_ntsc_memory_snapshot_allocations")
        memBytes = optionalCounter("_ntsc_memory_snapshot_bytes")
        memLiveAllocations = optionalCounter("_ntsc_memory_snapshot_live_allocations")
        memLiveBytes = optionalCounter("_ntsc_memory_snapshot_live_bytes")
        memHeapAllocations = optionalCounter("_ntsc_memory_snapshot_heap_allocations")
        memHeapBytes = optionalCounter("_ntsc_memory_snapshot_heap_bytes")
        memRawAllocations = optionalCounter("_ntsc_memory_snapshot_raw_allocations")
        memRawBytes = optionalCounter("_ntsc_memory_snapshot_raw_bytes")
        gcCyclesPtr = optionalCounter("_ntsc_gc_cycles")
        gcCollectedBytesPtr = optionalCounter("_ntsc_gc_collected_bytes")
        return true
    }

    // MARK: - frame + input entry points

    func tick(_ value: Int) { _ = tickFn(nullValue, boxInt(value)) }

    func renderFrame(layoutWidth: Int, layoutHeight: Int, dpr: Int) -> Int {
        valueToInt(renderFrameFn(nullValue, boxInt(layoutWidth), boxInt(layoutHeight), boxInt(dpr)))
    }

    // `keyCode` aqui ja e o codigo NEUTRO (NTUI_INPUT_KEY_*). A traducao do codigo
    // do AppKit acontece na view, nao no app.
    func handleKey(keyCode: Int, modifiers: Int) -> Int {
        guard let fn = handleKeyFn else { return 0 }
        return valueToInt(fn(nullValue, boxInt(keyCode), boxInt(modifiers)))
    }

    // Insercao de texto sem marshalling de string no FFI: os bytes UTF-8 sobem um a
    // um e o commit insere. E tambem a forma da composicao de IME.
    func insertText(_ text: String) -> Int {
        guard let begin = compositionBeginFn,
              let push = compositionPushByteFn,
              let commit = compositionCommitFn else { return 0 }
        _ = begin(nullValue)
        for byte in Array(text.utf8) {
            _ = push(nullValue, boxInt(Int(byte)))
        }
        return valueToInt(commit(nullValue))
    }

    // TEXTO PROVISORIO do IME: empilha os bytes e MARCA, em vez de commitar. O
    // texto aparece sublinhado na tela sem entrar no valor do campo.
    func setMarkedText(_ text: String) -> Int {
        guard let begin = compositionBeginFn,
              let push = compositionPushByteFn,
              let mark = inputSetMarkedFn else { return 0 }
        _ = begin(nullValue)
        for byte in Array(text.utf8) {
            _ = push(nullValue, boxInt(Int(byte)))
        }
        return valueToInt(mark(nullValue))
    }

    func clearMarkedText() -> Int {
        guard let fn = inputClearMarkedFn else { return 0 }
        return valueToInt(fn(nullValue))
    }

    func inputFocused() -> Bool {
        guard let fn = inputFocusedFn else { return false }
        return valueToInt(fn(nullValue)) != 0
    }

    func handleTouch(physicalX: Int, physicalY: Int, logicalX: Int, logicalY: Int, phase: Int) -> Int {
        valueToInt(handleTouchFn(nullValue, boxInt(physicalX), boxInt(physicalY), boxInt(logicalX), boxInt(logicalY), boxInt(phase)))
    }

    func handleScroll(physicalX: Int, physicalY: Int, logicalX: Int, logicalY: Int, deltaX: Int, deltaY: Int) -> Int {
        valueToInt(handleScrollFn(nullValue, boxInt(physicalX), boxInt(physicalY), boxInt(logicalX), boxInt(logicalY), boxInt(deltaX), boxInt(deltaY), boxInt(1), boxInt(2)))
    }

    var hasTimerWaiter: Bool { timerWaitFn != nil }
    func waitTimers() -> Int32 { timerWaitFn?() ?? -1 }
    func shutdownTimers() { timerShutdownFn?() }

    // MARK: - command accessors (scalar)

    func commandKind(_ i: Int) -> Int { valueToInt(commandKindFn(nullValue, boxInt(i))) }
    func commandX(_ i: Int) -> Double { valueToDouble(commandXFn(nullValue, boxInt(i))) }
    func commandY(_ i: Int) -> Double { valueToDouble(commandYFn(nullValue, boxInt(i))) }
    func commandWidth(_ i: Int) -> Double { valueToDouble(commandWidthFn(nullValue, boxInt(i))) }
    func commandHeight(_ i: Int) -> Double { valueToDouble(commandHeightFn(nullValue, boxInt(i))) }
    func commandFontSize(_ i: Int) -> Double { valueToDouble(commandFontSizeFn(nullValue, boxInt(i))) }
    func commandBaselineOffset(_ i: Int) -> Double { valueToDouble(commandBaselineOffsetFn(nullValue, boxInt(i))) }
    func commandBoxWidth(_ i: Int) -> Double { valueToDouble(commandBoxWidthFn(nullValue, boxInt(i))) }
    func commandLineHeight(_ i: Int) -> Double { valueToDouble(commandLineHeightFn(nullValue, boxInt(i))) }
    func commandFontWeight(_ i: Int) -> Int { valueToInt(commandFontWeightFn(nullValue, boxInt(i))) }
    func commandBorderWidth(_ i: Int) -> Double { valueToDouble(commandBorderWidthFn(nullValue, boxInt(i))) }
    func commandBorderRadius(_ i: Int) -> Double { valueToDouble(commandBorderRadiusFn(nullValue, boxInt(i))) }
    func commandOpacity(_ i: Int) -> Double { valueToDouble(commandOpacityFn(nullValue, boxInt(i))) }

    private func optionalDouble(_ fn: NtuiFn1?, _ i: Int, _ fallback: Double) -> Double {
        guard let fn = fn else { return fallback }
        let value = valueToDouble(fn(nullValue, boxInt(i)))
        return value.isFinite ? value : fallback
    }

    private func optionalInt(_ fn: NtuiFn1?, _ i: Int, _ fallback: Int) -> Int {
        guard let fn = fn else { return fallback }
        return valueToInt(fn(nullValue, boxInt(i)))
    }

    func commandLineIndex(_ i: Int) -> Int { optionalInt(commandLineIndexFn, i, -1) }
    func commandRunIndex(_ i: Int) -> Int { optionalInt(commandRunIndexFn, i, -1) }
    func commandLetterSpacing(_ i: Int) -> Double { optionalDouble(commandLetterSpacingFn, i, 0) }
    func commandWordSpacing(_ i: Int) -> Double { optionalDouble(commandWordSpacingFn, i, 0) }
    func commandTextDecorationThickness(_ i: Int) -> Double { optionalDouble(commandTextDecorationThicknessFn, i, 0) }
    func commandTextUnderlineOffset(_ i: Int) -> Double { optionalDouble(commandTextUnderlineOffsetFn, i, 0) }
    func commandTextIndent(_ i: Int) -> Double { optionalDouble(commandTextIndentFn, i, 0) }

    // MARK: - string reconstruction (mirrors ntui_macos_read_string via UTF-16)

    private func readString(_ lenFn: NtuiFn1, _ charFn: NtuiFn2, _ i: Int) -> String {
        let boxed = boxInt(i)
        let length = valueToInt(lenFn(nullValue, boxed))
        if length <= 0 { return "" }
        var units = [UInt16]()
        units.reserveCapacity(length)
        for offset in 0..<length {
            let code = valueToInt(charFn(nullValue, boxed, boxInt(offset)))
            units.append(UInt16(truncatingIfNeeded: code))
        }
        return String(decoding: units, as: UTF16.self)
    }

    private func readOptionalString(_ lenFn: NtuiFn1?, _ charFn: NtuiFn2?, _ i: Int, _ fallback: String) -> String {
        guard let lenFn = lenFn, let charFn = charFn else { return fallback }
        return readString(lenFn, charFn, i)
    }

    func commandColor(_ i: Int) -> String { readString(commandColorLenFn, commandColorCharFn, i) }
    func commandBorderColor(_ i: Int) -> String { readString(commandBorderColorLenFn, commandBorderColorCharFn, i) }
    func commandText(_ i: Int) -> String { readString(commandTextLenFn, commandTextCharFn, i) }
    func commandTextAlign(_ i: Int) -> String { readString(commandTextAlignLenFn, commandTextAlignCharFn, i) }
    func commandFontFamily(_ i: Int) -> String { readString(commandFontFamilyLenFn, commandFontFamilyCharFn, i) }
    func commandFontStyle(_ i: Int) -> String { readString(commandFontStyleLenFn, commandFontStyleCharFn, i) }

    func textRenderOptions(_ i: Int, scale: Double) -> NtuiTextRenderOptions {
        var options = NtuiTextRenderOptions()
        options.lineIndex = commandLineIndex(i)
        options.runIndex = commandRunIndex(i)
        options.letterSpacing = scalePx(commandLetterSpacing(i), scale)
        options.wordSpacing = scalePx(commandWordSpacing(i), scale)
        options.textDecorationThickness = scalePx(commandTextDecorationThickness(i), scale)
        options.textUnderlineOffset = scalePx(commandTextUnderlineOffset(i), scale)
        options.textIndent = scalePx(commandTextIndent(i), scale)
        options.textDecorationLine = readOptionalString(commandTextDecorationLineLenFn, commandTextDecorationLineCharFn, i, "none")
        options.textDecorationStyle = readOptionalString(commandTextDecorationStyleLenFn, commandTextDecorationStyleCharFn, i, "solid")
        let color = commandColor(i)
        options.textDecorationColor = readOptionalString(commandTextDecorationColorLenFn, commandTextDecorationColorCharFn, i, color)
        options.textUnderlinePosition = readOptionalString(commandTextUnderlinePositionLenFn, commandTextUnderlinePositionCharFn, i, "auto")
        options.textShadow = readOptionalString(commandTextShadowLenFn, commandTextShadowCharFn, i, "")
        options.direction = readOptionalString(commandDirectionLenFn, commandDirectionCharFn, i, "ltr")
        options.writingMode = readOptionalString(commandWritingModeLenFn, commandWritingModeCharFn, i, "horizontal-tb")
        return options
    }

    // MARK: - self-hosted text quads (Phase C4)

    var hasTextQuads: Bool { textQuadsPrepareFn != nil }
    var hasFrameSnapshot: Bool { snapshotPrepareFn != nil }

    struct TextQuads {
        var pointer: UnsafePointer<Float>
        var floatCount: Int
        var width: Double
        var height: Double
        var lineCount: Int
        var atlasWidth: Int
        var atlasHeight: Int
    }

    // Mirrors the C4 kind==2 accessor sequence: prepare fills the TS-owned mmap
    // scratch, then ptr()/count()/width()/height()/line_count()/atlas_* read it.
    func prepareTextQuads(_ i: Int, scaleMillis: Int) -> TextQuads? {
        guard
            let prepare = textQuadsPrepareFn,
            let ptrFn = textQuadsPtrFn,
            let widthFn = textQuadsWidthFn,
            let heightFn = textQuadsHeightFn,
            let lineCountFn = textQuadsLineCountFn,
            let atlasWidthFn = textQuadsAtlasWidthFn,
            let atlasHeightFn = textQuadsAtlasHeightFn
        else { return nil }
        let floatCount = valueToInt(prepare(nullValue, boxInt(i), boxInt(scaleMillis)))
        if floatCount <= 0 { return nil }
        let addr = UInt(bitPattern: Int(valueToDouble(ptrFn(nullValue))))
        guard addr != 0, let pointer = UnsafePointer<Float>(bitPattern: addr) else { return nil }
        return TextQuads(
            pointer: pointer,
            floatCount: floatCount,
            width: valueToDouble(widthFn(nullValue)),
            height: valueToDouble(heightFn(nullValue)),
            lineCount: valueToInt(lineCountFn(nullValue)),
            atlasWidth: valueToInt(atlasWidthFn(nullValue)),
            atlasHeight: valueToInt(atlasHeightFn(nullValue))
        )
    }

    // P2b/06-c: snapshot SoA da cena — 3 FFI + leitura por ponteiro no lugar de
    // ~6-7k crossings campo-a-campo/char-a-char por frame. Contrato ABI (stride 28
    // f32 por comando + arena UTF-16) documentado no gerador
    // (packages/compiler/src/pipeline/macos-web-app.ts). Ponteiros validos apenas
    // DENTRO do frame (nunca retidos entre frames).
    struct FrameSnapshot {
        var nums: UnsafePointer<Float>
        var text: UnsafePointer<UInt16>
        var count: Int
        var stride: Int
    }

    func frameSnapshot() -> FrameSnapshot? {
        guard
            let prepare = snapshotPrepareFn,
            let ptrFn = snapshotPtrFn,
            let textPtrFn = snapshotTextPtrFn,
            let strideFn = snapshotStrideFn
        else { return nil }
        let count = valueToInt(prepare(nullValue))
        if count <= 0 { return nil }
        let stride = valueToInt(strideFn(nullValue))
        if stride <= 0 { return nil }
        let numsAddr = UInt(bitPattern: Int(valueToDouble(ptrFn(nullValue))))
        let textAddr = UInt(bitPattern: Int(valueToDouble(textPtrFn(nullValue))))
        guard numsAddr != 0, let nums = UnsafePointer<Float>(bitPattern: numsAddr) else { return nil }
        // arena pode ser 0 quando nao ha nenhuma string na cena
        let text = UnsafePointer<UInt16>(bitPattern: textAddr == 0 ? numsAddr : textAddr)!
        return FrameSnapshot(nums: nums, text: text, count: count, stride: stride)
    }

    // MARK: - font assets

    private func registerFontAssets() {
        guard
            let countFn = fontAssetCountFn,
            let weightFn = fontAssetWeightFn,
            let familyLen = fontAssetFamilyLenFn, let familyChar = fontAssetFamilyCharFn,
            let pathLen = fontAssetPathLenFn, let pathChar = fontAssetPathCharFn,
            let styleLen = fontAssetStyleLenFn, let styleChar = fontAssetStyleCharFn
        else { return }
        let count = valueToInt(countFn(nullValue))
        for i in 0..<count {
            let family = readString(familyLen, familyChar, i)
            let path = readString(pathLen, pathChar, i)
            let style = readString(styleLen, styleChar, i)
            let weight = valueToInt(weightFn(nullValue, boxInt(i)))
            fontRegistrar(resourcePath, family, path, weight, style)
        }
    }

    // MARK: - GC + memory (mirrors ntui_macos_collect_ts_gc_auto / log_ts_memory_counters)

    func collectGcAuto(_ reason: String) {
        guard let gc = gcCollectAutoFn else { return }
        let hasLive = memLiveBytes != nil
        let before = memLiveBytes?.pointee ?? 0
        let collected = reason.withCString { gc($0) }
        let after = memLiveBytes?.pointee ?? 0
        if hasLive && Logs.memoryOrRender {
            FileHandle.standardError.write(Data(
                "ts_gc_auto platform=macos reason=\(reason) collectedBytes=\(collected) liveBytesBefore=\(before) liveBytesAfter=\(after)\n".utf8))
        }
    }

    // P3 (plano doc 07): pacing por frame (paridade Android) — coleta pequena e
    // frequente pos-present (teto 24MiB + churn 24MiB, kernel.ts
    // ntsc_gc_collect_auto_frame) em vez da agenda 256/192MiB que pausava ~450ms
    // de uma vez dentro do caminho de alloc. Fallback: agenda antiga.
    func collectGcFramePaced(_ reason: String) {
        guard let gc = gcCollectFrameFn else {
            collectGcAuto(reason)
            return
        }
        let hasLive = memLiveBytes != nil
        let before = memLiveBytes?.pointee ?? 0
        let collected = gc()
        let after = memLiveBytes?.pointee ?? 0
        if hasLive && Logs.memoryOrRender {
            FileHandle.standardError.write(Data(
                "ts_gc_frame platform=macos reason=\(reason) collectedBytes=\(collected) liveBytesBefore=\(before) liveBytesAfter=\(after)\n".utf8))
        }
    }

    func logMemoryCounters(_ reason: String) {
        guard Logs.memoryOrRender else { return }
        func c(_ p: UnsafePointer<UInt64>?) -> UInt64 { p?.pointee ?? 0 }
        let line = "ts_heap_memory platform=macos reason=\(reason)"
            + " allocations=\(c(memAllocations)) bytes=\(c(memBytes))"
            + " liveAllocations=\(c(memLiveAllocations)) liveBytes=\(c(memLiveBytes))"
            + " heapAllocations=\(c(memHeapAllocations)) heapBytes=\(c(memHeapBytes))"
            + " rawAllocations=\(c(memRawAllocations)) rawBytes=\(c(memRawBytes))"
            + " gcCycles=\(c(gcCyclesPtr)) gcCollectedBytes=\(c(gcCollectedBytesPtr))\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    // MARK: - helpers shared with the host loop

    // Mirrors ntui_macos_normalize_scale_millis.
    static func normalizeScaleMillis(_ scaleMillis: Int) -> Int {
        (scaleMillis < 500 || scaleMillis > 8500) ? 1000 : scaleMillis
    }

    // Mirrors ntui_macos_scale_px.
    func scalePx(_ value: Double, _ scale: Double) -> Double {
        value.isFinite ? value * scale : 0.0
    }

    // Mirrors ntui_macos_parse_color (hex / transparent / white / black).
    static func parseColor(_ text: String?, fallback: NtuiColor) -> NtuiColor {
        guard let raw = text else { return fallback }
        let trimmed = raw.drop(while: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" || $0 == "\u{0b}" || $0 == "\u{0c}" })
        let s = String(trimmed)
        if s == "transparent" { return NtuiColor(r: 0, g: 0, b: 0, a: 0) }
        if s == "white" { return NtuiColor(r: 1, g: 1, b: 1, a: 1) }
        if s == "black" { return NtuiColor(r: 0, g: 0, b: 0, a: 1) }
        guard s.hasPrefix("#") else { return fallback }
        let hex = Array(s.dropFirst().utf8)
        func digit(_ ch: UInt8) -> Int {
            if ch >= 0x30 && ch <= 0x39 { return Int(ch - 0x30) }
            if ch >= 0x61 && ch <= 0x66 { return Int(ch - 0x61) + 10 }
            if ch >= 0x41 && ch <= 0x46 { return Int(ch - 0x41) + 10 }
            return -1
        }
        func single(_ ch: UInt8) -> Int { let v = digit(ch); return v < 0 ? -1 : (v << 4) | v }
        func pair(_ hi: UInt8, _ lo: UInt8) -> Int { let h = digit(hi), l = digit(lo); return (h < 0 || l < 0) ? -1 : (h << 4) | l }
        var r = -1, g = -1, b = -1, a = 255
        if hex.count == 3 || hex.count == 4 {
            r = single(hex[0]); g = single(hex[1]); b = single(hex[2])
            if hex.count == 4 { a = single(hex[3]) }
        } else if hex.count == 6 || hex.count == 8 {
            r = pair(hex[0], hex[1]); g = pair(hex[2], hex[3]); b = pair(hex[4], hex[5])
            if hex.count == 8 { a = pair(hex[6], hex[7]) }
        }
        if r < 0 || g < 0 || b < 0 || a < 0 { return fallback }
        return NtuiColor(r: Double(r) / 255.0, g: Double(g) / 255.0, b: Double(b) / 255.0, a: Double(a) / 255.0)
    }
}

// Env-gated logging (mirrors the NTUI_MACOS_*_LOGS gates).
enum Logs {
    private static func on(_ name: String) -> Bool {
        guard let v = ProcessInfo.processInfo.environment[name] else { return false }
        return !v.isEmpty && v != "0"
    }
    static var render: Bool { on("NTUI_MACOS_RENDER_LOGS") }
    static var scroll: Bool { on("NTUI_MACOS_SCROLL_LOGS") }
    static var memory: Bool { on("NTUI_MACOS_MEMORY_LOGS") }
    static var memoryOrRender: Bool { memory || render }
    static func write(_ line: String) { FileHandle.standardError.write(Data(line.utf8)) }
}
