#if os(macOS)
import SwiftUI

struct CloudDriveSettingsView: View {
    @State private var quarkCookie = ""
    @State private var aliToken = ""
    @State private var message = ""
    @State private var isError = false
    @State private var loginProvider: CloudDriveLoginProvider?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SectionCard(title: "网盘凭据") {
                    credentialField(
                        title: "夸克 Cookie",
                        placeholder: "从已登录夸克网盘的浏览器请求中复制 Cookie",
                        text: $quarkCookie,
                        provider: .quark
                    )
                    Divider().background(Color.white.opacity(0.1))
                    credentialField(
                        title: "阿里云盘 Token",
                        placeholder: "请输入阿里云盘 refresh token",
                        text: $aliToken,
                        provider: .ali
                    )
                }

                Text("123 网盘无需登录凭据。夸克 Cookie 和阿里 Token 只保存在本机 Application Support 私有目录，不会触发钥匙串认证，也不会随项目上传到 GitHub。")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.6))

                if !message.isEmpty {
                    Text(message)
                        .font(.subheadline)
                        .foregroundColor(isError ? .red : .green)
                }

                Button(action: save) {
                    Label("保存网盘凭据", systemImage: "key.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
            .padding(24)
        }
        .background(AppTheme.primaryGradient.ignoresSafeArea())
        .navigationTitle("网盘设置")
        .onAppear {
            quarkCookie = CloudDriveCredentialStore.value(for: .quarkCookie)
            aliToken = CloudDriveCredentialStore.value(for: .aliToken)
        }
        .sheet(item: $loginProvider) { provider in
            CloudDriveWebLoginView(provider: provider) { credential in
                saveScannedCredential(credential, for: provider)
            }
        }
    }

    private func credentialField(
        title: String,
        placeholder: String,
        text: Binding<String>,
        provider: CloudDriveLoginProvider
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .foregroundColor(.white.opacity(0.9))
                Spacer()
                Button {
                    loginProvider = provider
                } label: {
                    Label("扫码登录", systemImage: "qrcode.viewfinder")
                }
                .buttonStyle(.bordered)
                .tint(.orange)
            }
            SecureField(placeholder, text: text)
                .textFieldStyle(.plain)
                .padding(12)
                .background(Color.white.opacity(0.08))
                .cornerRadius(10)
        }
        .padding(16)
    }

    private func saveScannedCredential(_ credential: String, for provider: CloudDriveLoginProvider) {
        do {
            switch provider {
            case .quark:
                quarkCookie = credential
                try CloudDriveCredentialStore.save(credential, for: .quarkCookie)
            case .ali:
                aliToken = credential
                try CloudDriveCredentialStore.save(credential, for: .aliToken)
            }
            EmbeddedSpiderGateway.shared.stop()
            isError = false
            message = "\(provider.title)扫码登录成功，凭据已保存到本机私有目录"
            loginProvider = nil
        } catch {
            isError = true
            message = error.localizedDescription
        }
    }

    private func save() {
        do {
            try CloudDriveCredentialStore.save(quarkCookie, for: .quarkCookie)
            try CloudDriveCredentialStore.save(aliToken, for: .aliToken)
            EmbeddedSpiderGateway.shared.stop()
            isError = false
            message = "已安全保存；下次网盘请求会自动使用新凭据"
        } catch {
            isError = true
            message = error.localizedDescription
        }
    }
}
#endif
