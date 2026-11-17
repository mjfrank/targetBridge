import ApplicationServices
import SwiftUI

struct TBDisplaySenderPermissionAssistant: View {
    @ObservedObject var service: TBDisplaySenderService

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(copy.title, systemImage: "checkmark.shield")
                .font(.title2.weight(.bold))

            Text(copy.intro)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            permissionRow(copy.screenRecording, granted: CGPreflightScreenCaptureAccess()) {
                service.requestScreenRecordingPermission()
            }
            permissionRow(copy.accessibility, granted: AXIsProcessTrusted()) {
                service.requestAccessibilityPermission()
            }
            permissionRow(copy.inputMonitoring, granted: CGPreflightListenEventAccess()) {
                service.requestInputMonitoringPermission()
            }
            permissionRow(copy.microphone, granted: service.microphoneAccessGranted) {
                service.requestMicrophonePermission()
            }
            Text(copy.microphoneHint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button(copy.openSettings) { service.openScreenRecordingSettings() }
                Button(copy.restart) { service.restartAfterPermissionChange() }
                    .buttonStyle(.borderedProminent)
                Spacer()
                Button(copy.done) { service.showingPermissionAssistant = false }
            }
        }
        .padding(24)
        .frame(width: 560)
        .onAppear { service.refreshPrivacyPermissions() }
    }

    private func permissionRow(_ title: String, granted: Bool, request: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? .green : .yellow)
            Text(title)
            Spacer()
            if granted {
                Text(copy.granted).foregroundStyle(.secondary)
            } else {
                Button(copy.allow, action: request).buttonStyle(.bordered)
            }
        }
    }

    private var copy: Copy {
        switch service.language {
        case .italian: return .init(title: "Permessi di TargetBridge", intro: "macOS richiede il tuo consenso per queste funzioni. Puoi autorizzarle qui o aprire le relative Impostazioni di Sistema.", screenRecording: "Registrazione schermo", accessibility: "Accessibilità", inputMonitoring: "Monitoraggio input", microphone: "Audio (in macOS: Microfono)", microphoneHint: "TargetBridge legge il dispositivo TargetBridge Audio per inviarne il suono al Receiver; macOS lo chiama accesso al microfono. Il microfono non viene usato.", granted: "Attivo", allow: "Consenti", openSettings: "Apri Impostazioni", restart: "Riavvia TargetBridge", done: "Fine")
        case .english: return .init(title: "TargetBridge Permissions", intro: "macOS requires your permission for these features. Approve here or open the matching System Settings page.", screenRecording: "Screen Recording", accessibility: "Accessibility", inputMonitoring: "Input Monitoring", microphone: "Audio (macOS calls it Microphone)", microphoneHint: "TargetBridge reads the TargetBridge Audio device to send its sound to the Receiver; macOS counts that as microphone access. Your microphone is not used.", granted: "Granted", allow: "Allow", openSettings: "Open Settings", restart: "Restart TargetBridge", done: "Done")
        case .german: return .init(title: "TargetBridge-Berechtigungen", intro: "macOS benötigt deine Zustimmung für diese Funktionen. Du kannst hier zustimmen oder die passenden Systemeinstellungen öffnen.", screenRecording: "Bildschirmaufnahme", accessibility: "Bedienungshilfen", inputMonitoring: "Eingabeüberwachung", microphone: "Audio (in macOS: Mikrofon)", microphoneHint: "TargetBridge liest das Gerät TargetBridge Audio, um dessen Ton an den Receiver zu senden; macOS zählt das als Mikrofonzugriff. Dein Mikrofon wird nicht verwendet.", granted: "Aktiv", allow: "Erlauben", openSettings: "Einstellungen öffnen", restart: "TargetBridge neu starten", done: "Fertig")
        case .french: return .init(title: "Autorisations TargetBridge", intro: "macOS demande votre autorisation pour ces fonctions. Autorisez-les ici ou ouvrez les Réglages Système correspondants.", screenRecording: "Enregistrement de l’écran", accessibility: "Accessibilité", inputMonitoring: "Surveillance des entrées", microphone: "Audio (macOS l’appelle Micro)", microphoneHint: "TargetBridge lit le périphérique TargetBridge Audio pour envoyer son son au Receiver ; macOS le compte comme un accès au micro. Votre micro n’est pas utilisé.", granted: "Autorisé", allow: "Autoriser", openSettings: "Ouvrir les réglages", restart: "Redémarrer TargetBridge", done: "Terminé")
        case .chinese: return .init(title: "TargetBridge 权限", intro: "这些功能需要你的 macOS 授权。你可以在这里授权，或打开相应的系统设置页面。", screenRecording: "录屏与系统录音", accessibility: "无障碍", inputMonitoring: "输入监控", microphone: "音频（macOS 中称为麦克风）", microphoneHint: "TargetBridge 读取 TargetBridge Audio 设备，把声音发送到接收端；macOS 将其算作麦克风访问。不会使用你的麦克风。", granted: "已授权", allow: "允许", openSettings: "打开设置", restart: "重新启动 TargetBridge", done: "完成")
        }
    }

    private struct Copy {
        let title: String
        let intro: String
        let screenRecording: String
        let accessibility: String
        let inputMonitoring: String
        let microphone: String
        let microphoneHint: String
        let granted: String
        let allow: String
        let openSettings: String
        let restart: String
        let done: String
    }
}
