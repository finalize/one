import AVFoundation

/// カメラのセッションを持ち、開始・停止・カメラと画質の切り替えをする。
///
/// 外から呼ぶのはメインスレッドだけ。`AVCaptureSession` の `startRunning` は
/// 映像が流れ始めるまで戻ってこない（0.5〜1 秒ほど固まる）ので、セッションを触る処理は
/// 専用のキューに逃がし、結果だけをメインに戻して `state` に書く。
final class Camera {
    enum State: Equatable {
        case stopped
        case starting
        case running
        /// カメラの使用が許可されていない
        case denied
        case noDevice
        case failed(String)
    }

    let session = AVCaptureSession()

    /// 変わったら呼ばれる（メインスレッド）。
    var onStateChange: ((State) -> Void)?

    /// セッションの入力やプリセットを組み替えた後に呼ばれる（メインスレッド）。
    ///
    /// プレビューの接続（`AVCaptureConnection`）は入力を差し替えると作り直され、
    /// 鏡像の設定が消える。これを合図にかけ直す。
    var onConfigured: (() -> Void)?

    private(set) var state: State = .stopped {
        didSet { if state != oldValue { onStateChange?(state) } }
    }

    /// 実際に流れている解像度（"1920×1080" など）。プリセットは「その程度」を頼むだけで、
    /// 何が出るかはカメラ次第なので、メニューに実際の値を出して確かめられるようにする。
    private(set) var activeResolution: String?

    private let queue = DispatchQueue(label: "com.finalize.one.camera")

    /// 内蔵・外付け・iPhone（連係カメラ）を拾う。
    ///
    /// 連係カメラ用の `.continuityCamera` は入れていない。Info.plist に
    /// `NSCameraUseContinuityCameraDeviceType` を書かない限り、連係カメラは
    /// `.builtInWideAngleCamera` として報告される（SDK のヘッダに書いてある）ので、
    /// これで一緒に拾える。
    private let discovery = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.builtInWideAngleCamera, .external],
        mediaType: .video,
        position: .unspecified
    )

    /// 映していたいか（メインスレッドだけで読み書きする）。
    ///
    /// 許可のダイアログに答えている間に窓を閉じられることがある。答えが返ってきた時点で
    /// これが false なら、カメラを点けない。点けると、窓が無いのに緑のランプだけが灯る。
    private var wantsRunning = false

    /// いまセッションに入っているカメラ（キューの上だけで読み書きする）。
    private var configuredDeviceID: String?

    private enum Keys {
        static let device = "cameraID"
        static let quality = "quality"
    }

    init() {
        let center = NotificationCenter.default
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let device = note.object as? AVCaptureDevice
                log.notice("カメラの抜き差し: \(name.rawValue, privacy: .public) \(device?.localizedName ?? "?", privacy: .public)")
                self?.restartIfRunning()
            }
        }
        center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
            let message = error?.localizedDescription ?? "不明なエラー"
            log.error("セッションが止まった: \(message, privacy: .public)")
            self?.state = .failed(message)
        }
    }

    // MARK: - 選ぶ

    var devices: [AVCaptureDevice] { discovery.devices }

    /// 選んだカメラ。nil は「自動」（macOS がおすすめするカメラ）。
    var selectedDeviceID: String? {
        get { UserDefaults.standard.string(forKey: Keys.device) }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.device)
            restartIfRunning()
        }
    }

    var preferredQuality: Quality {
        get { Quality(saved: UserDefaults.standard.string(forKey: Keys.quality)) }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Keys.quality)
            restartIfRunning()
        }
    }

    /// いま使う（開けば使うことになる）カメラ。
    ///
    /// 選んだカメラが抜かれていたら、自動と同じ選び方に戻る。
    var currentDevice: AVCaptureDevice? {
        let all = devices
        if let id = selectedDeviceID, let chosen = all.first(where: { $0.uniqueID == id }) {
            return chosen
        }
        return AVCaptureDevice.systemPreferredCamera ?? all.first
    }

    func supports(_ quality: Quality, on device: AVCaptureDevice) -> Bool {
        quality == .auto || device.supportsSessionPreset(quality.preset)
    }

    // MARK: - 点ける・消す

    func start() {
        wantsRunning = true
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            run()
        case .notDetermined:
            state = .starting
            // [weak self] は外側のクロージャに付ける。内側にだけ付けると、内側に渡すために
            // 外側が self を強く掴んでしまう（Xcode 27 はそれを警告する）。
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    log.notice("カメラの許可: \(granted ? "下りた" : "断られた", privacy: .public)")
                    if !granted {
                        self.state = .denied
                    } else if self.wantsRunning {
                        self.run()
                    } else {
                        self.state = .stopped
                    }
                }
            }
        default:
            state = .denied
        }
    }

    func stop() {
        wantsRunning = false
        state = .stopped
        queue.async { [session] in
            guard session.isRunning else { return }
            session.stopRunning()
            log.notice("カメラを止めた")
        }
    }

    private func restartIfRunning() {
        guard wantsRunning, AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
        run()
    }

    /// セッションを組んで流す。何度呼んでもいい（変わったところだけ組み替える）。
    private func run() {
        guard let device = currentDevice else {
            log.notice("カメラが見つからない")
            state = .noDevice
            queue.async { [self] in
                // 使っていたカメラが抜かれた場合に、死んだ入力を抱えたまま回さない。
                session.stopRunning()
                session.inputs.forEach(session.removeInput)
                configuredDeviceID = nil
            }
            return
        }
        let quality = preferredQuality.effective { supports($0, on: device) }
        if state != .running { state = .starting }

        queue.async { [self] in
            let failure = configure(device: device, quality: quality)
            if failure == nil, !session.isRunning {
                session.startRunning()
            }
            // プリセットが実際にどの形式を選んだかは、流し始めた後でないと確定しない。
            let size = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            let resolution = "\(size.width)×\(size.height)"

            DispatchQueue.main.async { [self] in
                onConfigured?()
                if let failure {
                    log.error("カメラを開けなかった: \(failure, privacy: .public)")
                    state = .failed(failure)
                    return
                }
                // 流し始めるのを待っている間に stop() が呼ばれていたら、何もしない。
                // 止める処理は stop() がキューの後ろに積んである。
                guard wantsRunning else { return }
                activeResolution = resolution
                state = .running
                log.notice("映している: \(device.localizedName, privacy: .public) 画質=\(quality.rawValue, privacy: .public) 実際=\(resolution, privacy: .public)")
            }
        }
    }

    /// キューの上で呼ぶ。失敗したら理由を返す。
    private func configure(device: AVCaptureDevice, quality: Quality) -> String? {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if configuredDeviceID != device.uniqueID {
            session.inputs.forEach(session.removeInput)
            configuredDeviceID = nil
            do {
                let input = try AVCaptureDeviceInput(device: device)
                guard session.canAddInput(input) else { return "このカメラはセッションに入れられない" }
                session.addInput(input)
                configuredDeviceID = device.uniqueID
            } catch {
                return error.localizedDescription
            }
        }

        let preset = quality.preset
        session.sessionPreset = session.canSetSessionPreset(preset) ? preset : .high
        return nil
    }
}

extension Quality {
    var preset: AVCaptureSession.Preset {
        switch self {
        case .auto: .high
        case .uhd2160: .hd4K3840x2160
        case .fhd1080: .hd1920x1080
        case .hd720: .hd1280x720
        case .qhd540: .qHD960x540
        case .vga480: .vga640x480
        }
    }
}
