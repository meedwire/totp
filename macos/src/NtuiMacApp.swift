// Phase F: the macOS example is now a thin Swift shell over the compiled TS
// dylib. The old C host loop (ntui_macos_renderer.c) and Obj-C Metal backend
// (ntui_macos_renderer.m) are gone — NtuiHost (Swift) dlopen's the dylib, reads
// the ntui_command_* / ntui_command_text_quads_* accessors, and draws via Metal.

import AppKit
import CoreText
import MetalKit

private final class NtuiMetalView: MTKView {
    private let host: NtuiHost

    override var acceptsFirstResponder: Bool { true }

    init(frame: NSRect, host: NtuiHost) {
        self.host = host
        super.init(frame: frame, device: MTLCreateSystemDefaultDevice())
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = false
        clearColor = MTLClearColor(red: 0.063, green: 0.075, blue: 0.090, alpha: 1.0)
        isPaused = true
        enableSetNeedsDisplay = true
        updateDrawableSize()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("NtuiMetalView does not support NSCoder")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        updateDrawableSize()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        updateDrawableSize()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        autoreleasepool {
            updateDrawableSize()
            let commandCount = host.render(
                view: self,
                drawableWidth: max(1, Int(drawableSize.width.rounded())),
                drawableHeight: max(1, Int(drawableSize.height.rounded())),
                scaleMillis: Int(scaleMillis())
            )
            if commandCount == 0, let error = host.lastError {
                NSLog("ntui_macos_renderer: %@", error)
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        dispatchMouse(event, phase: 0)
    }

    override func mouseUp(with event: NSEvent) {
        dispatchMouse(event, phase: 2)
    }

    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let logicalX = Float(point.x)
        let logicalY = Float(bounds.height - point.y)
        let handled = host.scroll(
            x: logicalX,
            y: logicalY,
            deltaX: Float(event.scrollingDeltaX),
            deltaY: Float(event.scrollingDeltaY),
            scaleMillis: Int(scaleMillis())
        )
        NSLog(
            "cmd_snapshot kind=scroll logical=(%.2f,%.2f) delta=(%.2f,%.2f) phase=1",
            Double(logicalX),
            Double(logicalY),
            Double(event.scrollingDeltaX),
            Double(event.scrollingDeltaY)
        )
        if handled != 0 {
            needsDisplay = true
        }
    }

    // TECLADO. `interpretKeyEvents` faz o AppKit resolver o evento — teclas mortas,
    // Option+letra, e o IME inteiro — e devolver o resultado por NSTextInputClient.
    // Ler `event.characters` direto pularia tudo isso e quebraria acento e IME.
    override func keyDown(with event: NSEvent) {
        if let neutral = NtuiMetalView.neutralKeyCode(for: event) {
            if host.key(keyCode: neutral, modifiers: NtuiMetalView.neutralModifiers(for: event)) != 0 {
                needsDisplay = true
            }
            return
        }
        // Cmd+A seleciona tudo. Sem isto o AppKit trataria como comando de menu.
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "a" {
            if host.key(keyCode: 10, modifiers: 0) != 0 { needsDisplay = true }
            return
        }
        interpretKeyEvents([event])
    }

    // SHIFT e o que separa navegar de selecionar. Mascara NEUTRA, nao NSEvent flags.
    private static func neutralModifiers(for event: NSEvent) -> Int {
        var mask = 0
        if event.modifierFlags.contains(.shift) { mask |= 1 }
        if event.modifierFlags.contains(.control) { mask |= 2 }
        if event.modifierFlags.contains(.option) { mask |= 4 }
        if event.modifierFlags.contains(.command) { mask |= 8 }
        return mask
    }

    // O codigo do AppKit vira o codigo NEUTRO aqui, na borda. Nenhum keycode de
    // sistema operacional atravessa a ponte.
    private static func neutralKeyCode(for event: NSEvent) -> Int? {
        guard let scalars = event.charactersIgnoringModifiers?.unicodeScalars,
              let first = scalars.first else { return nil }
        switch Int(first.value) {
        case NSDeleteCharacter: return 1        // backspace
        case NSDeleteFunctionKey: return 2      // delete adiante
        case NSLeftArrowFunctionKey: return 3
        case NSRightArrowFunctionKey: return 4
        case NSHomeFunctionKey: return 5
        case NSEndFunctionKey: return 6
        case 0x0d, 0x03: return 7               // return / enter
        case 0x09: return 8                     // tab
        case 0x1b: return 9                     // escape
        default: return nil
        }
    }

    private func dispatchMouse(_ event: NSEvent, phase: Int) {
        let point = convert(event.locationInWindow, from: nil)
        let logicalX = Float(point.x)
        let logicalY = Float(bounds.height - point.y)
        let handled = host.touch(x: logicalX, y: logicalY, phase: phase, scaleMillis: Int(scaleMillis()))
        if handled != 0 {
            needsDisplay = true
        }
    }

    private func updateDrawableSize() {
        let scale = backingScale()
        drawableSize = CGSize(
            width: max(1, bounds.width * scale),
            height: max(1, bounds.height * scale)
        )
    }

    // NSResponder. As teclas de edicao ja foram tratadas em keyDown pelo codigo
    // neutro; aqui so evitamos o NSBeep do comportamento padrao.
    override func doCommand(by selector: Selector) {}

    private func scaleMillis() -> Int32 {
        Int32((backingScale() * 1000.0).rounded())
    }

    fileprivate func backingScale() -> CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1.0
    }
}

// O contrato que o AppKit usa para entregar TEXTO (e composicao de IME) em vez de
// teclas cruas. `insertText` recebe a NSString ja resolvida; os bytes UTF-8 dela
// sobem um a um pela ponte, que e o unico caminho host -> app para string.
extension NtuiMetalView: NSTextInputClient {
    func insertText(_ string: Any, replacementRange: NSRange) {
        let text: String
        if let attributed = string as? NSAttributedString {
            text = attributed.string
        } else if let plain = string as? String {
            text = plain
        } else {
            return
        }
        if text.isEmpty { return }
        NtuiMetalView.markedLength = 0
        NtuiMetalView.markedString = ""
        if host.insertText(text) != 0 {
            needsDisplay = true
        }
    }

    // COMPOSICAO VIVA. O IME manda o texto provisorio por aqui antes de confirmar;
    // ele aparece sublinhado na tela sem entrar no valor do campo.
    private static var markedLength = 0

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let text: String
        if let attributed = string as? NSAttributedString { text = attributed.string }
        else if let plain = string as? String { text = plain }
        else { return }
        NtuiMetalView.markedLength = (text as NSString).length
        NtuiMetalView.markedString = text
        if text.isEmpty { host.clearMarkedText() } else { host.setMarkedText(text) }
        needsDisplay = true
    }

    func unmarkText() {
        NtuiMetalView.markedLength = 0
        NtuiMetalView.markedString = ""
        host.clearMarkedText()
        needsDisplay = true
    }

    // Enquanto ha composicao o AppKit PRECISA de um selectedRange valido: devolver
    // NSNotFound trava a maquina de estado e a tecla morta nunca confirma. O texto
    // que o AppKit enxerga por esta interface e apenas a composicao, entao o ponto
    // de insercao e o fim dela.
    func selectedRange() -> NSRange {
        NtuiMetalView.markedLength > 0
            ? NSRange(location: NtuiMetalView.markedLength, length: 0)
            : NSRange(location: 0, length: 0)
    }

    func markedRange() -> NSRange {
        NtuiMetalView.markedLength > 0
            ? NSRange(location: 0, length: NtuiMetalView.markedLength)
            : NSRange(location: NSNotFound, length: 0)
    }

    func hasMarkedText() -> Bool { NtuiMetalView.markedLength > 0 }
    // Devolver nil aqui trava a composicao: o AppKit consulta o texto para decidir
    // o proximo passo da tecla morta.
    private static var markedString = ""

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        let text = NtuiMetalView.markedString
        if text.isEmpty { return nil }
        actualRange?.pointee = NSRange(location: 0, length: (text as NSString).length)
        return NSAttributedString(string: text)
    }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        window?.convertToScreen(convert(bounds, to: nil)) ?? .zero
    }
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

}

@main
private final class NtuiMacApp: NSObject, NSApplicationDelegate {
    private static let sharedDelegate = NtuiMacApp()

    private let host = NtuiHost()
    private var window: NSWindow?
    private weak var metalView: NtuiMetalView?
    private var timerWaiterRunning = false
    private var timerWaiterThread: Thread?

    static func main() {
        let app = NSApplication.shared
        app.delegate = sharedDelegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        registerBundledFonts()
        configureResourcePath()
        configureRuntimeLibrary()

        // O app RN e um agente de barra de menu com popover de 380x600
        // (macos/totp-macOS/AppDelegate.mm). O layout do porte — coluna de codigo de
        // 84px, avatar de 30px — foi desenhado para essa largura.
        let contentRect = NSRect(x: 0, y: 0, width: 380, height: 600)
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "TOTP Authenticator"
        let metalView = NtuiMetalView(frame: contentRect, host: host)
        window.contentView = metalView
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.metalView = metalView
        self.window = window

        // Initialize the TS runtime on the MAIN thread BEFORE starting the timer
        // waiter. The self-hosted GC's stack scan only covers the collecting
        // thread; running module init / first alloc / GC init here (not lazily on
        // the NtuiTimerWaiter thread) keeps every TS allocation and GC collect on
        // main. The waiter's ensureRuntime() then no-ops and its only TS call is
        // the alloc-free ntsc_timer_wait_ready_host — no cross-thread GC race.
        host.warmUpRuntime()
        startTimerWaiter()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopTimerWaiter()
    }

    private func startTimerWaiter() {
        if timerWaiterRunning { return }
        timerWaiterRunning = true
        let thread = Thread { [weak self] in
            while self?.timerWaiterRunning == true {
                let ready = self?.host.waitTimers() ?? -1
                if self?.timerWaiterRunning != true { return }
                if ready < 0 { return }
                if ready > 0 {
                    DispatchQueue.main.async { [weak self] in
                        self?.metalView?.needsDisplay = true
                    }
                }
            }
        }
        thread.name = "NtuiTimerWaiter"
        thread.start()
        timerWaiterThread = thread
    }

    private func stopTimerWaiter() {
        if !timerWaiterRunning { return }
        timerWaiterRunning = false
        host.shutdownTimers()
        timerWaiterThread?.cancel()
        timerWaiterThread = nil
    }

    private func configureRuntimeLibrary() {
        let fallback = Bundle.main.bundleURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("Frameworks")
            .appendingPathComponent("libntui_ts_app.dylib")
        let runtimeURL = Bundle.main.privateFrameworksURL?
            .appendingPathComponent("libntui_ts_app.dylib") ?? fallback
        host.setLibraryPath(runtimeURL.path)
    }

    private func configureResourcePath() {
        guard let resourcesURL = Bundle.main.resourceURL else {
            return
        }
        host.setResourcePath(resourcesURL.path)
    }

    private func registerBundledFonts() {
        guard let fontsURL = Bundle.main.resourceURL?.appendingPathComponent("fonts") else {
            return
        }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: fontsURL,
            includingPropertiesForKeys: nil
        ) else {
            return
        }
        for url in files where url.pathExtension.lowercased() == "ttf" {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}
