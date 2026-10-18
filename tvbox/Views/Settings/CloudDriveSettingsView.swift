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
                    Divider().background(Color.primary.opacity(0.1))
                    credentialField(
                        title: "阿里云盘 Token",
                        placeholder: "请输入阿里云盘 refresh token",
                        text: $aliToken,
                        provider: .ali
                    )
                }

                Text("夸克网盘线路使用夸克 Cookie。可粘贴已有凭据，也可在官方网页完成登录后自动保存。123 网盘无需登录凭据。阿里 Token 供兼容线路使用，保存 Token 不代表所有阿里线路都支持播放。")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text("凭据仅保存在本机，不会随点播接口导出，也不会交给第三方脚本。清空输入框后保存即可移除对应凭据。")
                    .font(.caption)
                    .foregroundColor(.secondary)

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
                .accessibilityIdentifier("cloudCredentials.save")
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
                    .foregroundColor(.primary)
                Spacer()
                Button {
                    loginProvider = provider
                } label: {
                    Label("网页登录", systemImage: "person.crop.circle.badge.checkmark")
                }
                .buttonStyle(.bordered)
                .tint(.orange)
            }
            SecureField(placeholder, text: text)
                .textFieldStyle(.plain)
                .padding(12)
                .background(Color.primary.opacity(0.08))
                .cornerRadius(10)
#if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
#endif
                .accessibilityIdentifier("cloudCredentials.\(provider.rawValue)")

            HStack {
                PasteButton(payloadType: String.self) { values in
                    if let value = values.first { text.wrappedValue = value }
                }
                .labelStyle(.titleAndIcon)
                .tint(.orange)
                Spacer()
                Button("清空", role: .destructive) { text.wrappedValue = "" }
                    .disabled(text.wrappedValue.isEmpty)
            }
            .font(.subheadline)
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
            credentialsDidChange()
            isError = false
            message = "\(provider.title)登录成功，凭据已保存到本机"
            loginProvider = nil
        } catch {
            isError = true
            message = error.localizedDescription
        }
    }

    private func save() {
        do {
            try CloudDriveCredentialStore.save([.quarkCookie: quarkCookie, .aliToken: aliToken])
            credentialsDidChange()
            isError = false
            message = "已安全保存；下次网盘请求会自动使用新凭据"
        } catch {
            isError = true
            message = error.localizedDescription
        }
    }

    private func credentialsDidChange() {
#if os(macOS)
        EmbeddedSpiderGateway.shared.stop()
#endif
        // iOS refreshes the trusted native configuration before every request;
        // its single in-process Node engine must not be stopped or restarted.
    }
}
