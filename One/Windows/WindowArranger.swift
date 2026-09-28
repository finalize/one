import AppKit

/// ウィンドウの操作を実際に行う。
///
/// 行き先の計算は `WindowAction.target`、ウィンドウの読み書きは `AXWindow` に任せて、
/// ここはその間をつなぐだけにしている。計算の側は画面にもウィンドウにも触らないので
/// テストで全部試せる。触る側（ここと `AXWindow`）は薄くしておく。
///
/// ショートカット・メニュー・ドラッグでのスナップのどれから来ても、置くのは `place` で、
/// 「元に戻す」の記録も1つを共有する。スナップで置いたウィンドウを ⌃⌥⌫ で戻せるし、
/// ショートカットで置いたウィンドウをドラッグで引き剥がせば元の大きさに戻る。
final class WindowArranger {
    /// 「元に戻す」の戻り先。ウィンドウごと。
    private var history = WindowHistory<AXUIElement>()

    /// 手前のアプリのウィンドウに `action` を行う。ショートカットとメニューから呼ぶ。
    ///
    /// 動かせなかったときはビープを鳴らす。ショートカットは画面に何も出さないので、
    /// 押したのに何も起きないと、効かなかったのか何もすることが無かったのか分からない。
    func perform(_ action: WindowAction) {
        // 許可が無くても AX の呼び出しはエラーを返すだけで、何が悪いのか分からない。
        // 先に見ておく。
        guard AXIsProcessTrusted() else {
            log.error("ウィンドウを動かせない: アクセシビリティの許可が無い")
            NSSound.beep()
            return
        }
        guard let window = AXWindow.focused() else {
            skip(action, "手前のアプリにウィンドウが無い")
            return
        }
        guard !window.isFullScreen else {
            skip(action, "フルスクリーンのウィンドウは動かさない")
            return
        }
        place(window, action, screens: ScreenArea.connected)
    }

    /// `window` に `action` を行う。
    ///
    /// - Parameters:
    ///   - screens: 行き先を探す画面。ドラッグでのスナップは行き先の画面が決まっているので、
    ///     その1枚だけを渡す
    ///   - start: 「元に戻す」の出発点の候補。省くと今の枠。ドラッグでのスナップでは、
    ///     ドラッグを始める前の枠を渡す。離した位置（たまたまカーソルがあった場所）に
    ///     戻っても意味が無いから
    func place(_ window: AXWindow, _ action: WindowAction, screens: [ScreenArea], from start: CGRect? = nil) {
        guard let current = window.frame else {
            skip(action, "ウィンドウの位置が読めない")
            return
        }
        let restore = history.restoreFrame(for: window.element)
        guard var target = action.target(for: current, screens: screens, restore: restore) else {
            // 行き先が無いのは3通りしかない（`WindowAction.target` の説明を参照）。
            switch action {
            case .restore: skip(action, "戻り先を覚えていない")
            case .previousDisplay, .nextDisplay: skip(action, "ほかの画面が無い")
            case .smaller: skip(action, "これ以上小さくできない")
            default: skip(action, "行き先が決まらない")
            }
            return
        }

        // 大きさを変えられないウィンドウ（計算機、システム設定など）は、大きさを保ったまま
        // 行き先の真ん中に置く。左上に寄せると、右半分に送ったのに左に偏って見える。
        if !window.isResizable {
            target = current.size.centered(in: target)
        }

        window.setFrame(target)
        var placed = window.frame ?? target

        // アプリには最小の大きさがあり、指示したところまで縮まないことがある。すると
        // 右や下が画面からはみ出すので、画面の中へ押し戻す。ただし「元に戻す」は、
        // 利用者が元々置いていた場所へ戻すものなので、はみ出していてもそのままにする。
        if action != .restore, let screen = ScreenArea.containing(target, in: screens) {
            let inside = placed.nudged(into: screen.visible)
            if inside != placed {
                window.move(to: inside.origin)
                placed = window.frame ?? inside
            }
        }

        if action == .restore {
            history.forget(window.element)
        } else {
            history.recordMove(of: window.element, from: start ?? current, to: placed)
        }
        // 操作のたびに出るので debug（ディスクには残らない）。
        log.debug("ウィンドウ \(action.title, privacy: .public) アプリ=\(window.appID, privacy: .public) \(Self.describe(current), privacy: .public) → \(Self.describe(placed), privacy: .public)")
    }

    /// スナップしていたウィンドウを、ドラッグで引き剥がした。大きさだけ元に戻す。
    ///
    /// One が置いた場所から動かし始めたときだけ戻す。手で大きさを整えたウィンドウを
    /// 動かしただけで縮んだり広がったりしたら困る。
    ///
    /// 記録は消さない。ここで ⌃⌥⌫ を押せば、スナップする前の位置まで戻れる
    /// （位置も含めて戻すのは、大きさだけ戻す「引き剥がし」とは別の操作）。
    ///
    /// - Parameters:
    ///   - initial: ドラッグを始める前の枠。One が置いた枠と比べる
    ///   - current: 動き始めたところの枠
    func unsnap(_ window: AXWindow, initial: CGRect, current: CGRect, cursor: CGPoint) {
        guard let restore = history.restoreFrame(for: window.element, ifStillAt: initial) else { return }
        let frame = current.unsnapped(to: restore.size, cursor: cursor)
        if frame.origin == current.origin {
            window.resize(to: frame.size)
        } else {
            window.setFrame(frame)
        }
        log.debug("スナップを外した アプリ=\(window.appID, privacy: .public) \(Self.describe(current), privacy: .public) → \(Self.describe(frame), privacy: .public)")
    }

    private func skip(_ action: WindowAction, _ reason: String) {
        log.debug("ウィンドウ \(action.title, privacy: .public) をしない: \(reason, privacy: .public)")
        NSSound.beep()
    }

    private static func describe(_ r: CGRect) -> String {
        "(\(Int(r.minX)), \(Int(r.minY)), \(Int(r.width))×\(Int(r.height)))"
    }
}

extension ScreenArea {
    /// つながっている画面すべてを、AX の座標で。先頭が主画面。
    ///
    /// `NSScreen.screens` の先頭は常に主画面（メニューバーのある画面）で、AppKit の座標の
    /// 原点はその左下にある。変換にはその高さを使う（`ScreenArea` の説明を参照）。
    static var connected: [ScreenArea] {
        guard let primary = NSScreen.screens.first else { return [] }
        return NSScreen.screens.map {
            ScreenArea(cocoaFrame: $0.frame, cocoaVisibleFrame: $0.visibleFrame,
                       primaryHeight: primary.frame.height)
        }
    }
}
