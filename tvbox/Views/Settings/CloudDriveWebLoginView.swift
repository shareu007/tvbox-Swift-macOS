#if os(macOS)
import Foundation
import SwiftUI
import WebKit

enum CloudDriveLoginProvider: String, Identifiable {
    case quark
    case ali

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quark: return "夸克网盘"
        case .ali: return "阿里云盘"
        }
    }

    var loginURL: URL {
        switch self {
        case .quark:
            return URL(string: "https://pan.quark.cn/")!
        case .ali:
            return URL(string: "https://www.alipan.com/drive")!
        }
    }

    var scanInstruction: String {
        "请使用\(title)手机 App 扫描网页中的官方二维码，并在手机上确认登录"
    }
}

enum CloudDriveLoginCredentialExtractor {
    private static let quarkLoginCookieNames: Set<String> = [
        "__puus", "__pus", "kps"
    ]

    static func quarkCookie(from cookies: [HTTPCookie]) -> String? {
        let quarkCookies = cookies.filter { cookie in
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return domain == "quark.cn" || domain.hasSuffix(".quark.cn")
        }
        guard quarkCookies.contains(where: { quarkLoginCookieNames.contains($0.name.lowercased()) }) else {
            return nil
        }

        let cookieHeader = quarkCookies
            .sorted {
                if $0.name == $1.name { return $0.path < $1.path }
                return $0.name < $1.name
            }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
        return cookieHeader.isEmpty ? nil : cookieHeader
    }

    static func aliRefreshToken(from storageValues: [String]) -> String? {
        for value in storageValues {
            if let data = value.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data),
               let token = findRefreshToken(in: object, depth: 0) {
                return token
            }
        }
        return nil
    }

    private static func findRefreshToken(in value: Any, depth: Int) -> String? {
        guard depth <= 8 else { return nil }
        if let dictionary = value as? [String: Any] {
            if let token = dictionary["refresh_token"] as? String,
               !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return token
            }
            for nestedValue in dictionary.values {
                if let token = findRefreshToken(in: nestedValue, depth: depth + 1) {
                    return token
                }
            }
        } else if let array = value as? [Any] {
            for nestedValue in array {
                if let token = findRefreshToken(in: nestedValue, depth: depth + 1) {
                    return token
                }
            }
        }
        return nil
    }
}

struct CloudDriveWebLoginView: View {
    let provider: CloudDriveLoginProvider
    let onCredential: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var status = "正在载入官方登录页面…"
    @State private var reloadID = UUID()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("扫码登录\(provider.title)")
                        .font(.headline)
                    Text(provider.scanInstruction)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    reloadID = UUID()
                    status = "正在重新载入官方登录页面…"
                } label: {
                    Label("重新载入", systemImage: "arrow.clockwise")
                }
                Button("取消") { dismiss() }
            }
            .padding(16)

            Divider()

            CloudDriveLoginWebView(
                provider: provider,
                status: $status,
                onCredential: onCredential
            )
            .id(reloadID)

            Divider()

            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(provider.loginURL.host ?? "")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .frame(height: 42)
        }
        .frame(minWidth: 900, minHeight: 680)
    }
}

private struct CloudDriveLoginWebView: NSViewRepresentable {
    let provider: CloudDriveLoginProvider
    @Binding var status: String
    let onCredential: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(provider: provider, status: $status, onCredential: onCredential)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        context.coordinator.attach(to: webView)
        webView.load(URLRequest(url: provider.loginURL))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.stop()
        webView.navigationDelegate = nil
        webView.stopLoading()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let provider: CloudDriveLoginProvider
        private var status: Binding<String>
        private let onCredential: (String) -> Void
        private weak var webView: WKWebView?
        private var timer: Timer?
        private var completed = false

        init(
            provider: CloudDriveLoginProvider,
            status: Binding<String>,
            onCredential: @escaping (String) -> Void
        ) {
            self.provider = provider
            self.status = status
            self.onCredential = onCredential
        }

        func attach(to webView: WKWebView) {
            self.webView = webView
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                self?.pollCredential()
            }
        }

        func stop() {
            timer?.invalidate()
            timer = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            status.wrappedValue = "页面已载入，等待手机扫码确认…"
            pollCredential()
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            status.wrappedValue = "页面载入失败：\(error.localizedDescription)"
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            status.wrappedValue = "无法打开官方登录页：\(error.localizedDescription)"
        }

        private func pollCredential() {
            guard !completed, let webView else { return }
            switch provider {
            case .quark:
                webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                    guard let credential = CloudDriveLoginCredentialExtractor.quarkCookie(from: cookies) else {
                        return
                    }
                    self?.complete(with: credential)
                }
            case .ali:
                webView.evaluateJavaScript(Self.storageValuesScript) { [weak self] result, _ in
                    guard let json = result as? String,
                          let data = json.data(using: .utf8),
                          let values = try? JSONDecoder().decode([String].self, from: data),
                          let credential = CloudDriveLoginCredentialExtractor.aliRefreshToken(from: values) else {
                        return
                    }
                    self?.complete(with: credential)
                }
            }
        }

        private func complete(with credential: String) {
            DispatchQueue.main.async { [weak self] in
                guard let self, !completed else { return }
                completed = true
                stop()
                status.wrappedValue = "登录成功，正在安全保存凭据…"
                onCredential(credential)
            }
        }

        private static let storageValuesScript = """
        (() => {
          const values = [];
          for (const storage of [window.localStorage, window.sessionStorage]) {
            try {
              for (let index = 0; index < storage.length; index++) {
                const key = storage.key(index);
                const value = key === null ? null : storage.getItem(key);
                if (typeof value === 'string') values.push(value);
              }
            } catch (_) {}
          }
          return JSON.stringify(values);
        })()
        """
    }
}
#endif
