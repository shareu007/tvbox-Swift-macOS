import SwiftUI

struct AppearanceSettingsView: View {
    @AppStorage(AppAppearance.storageKey) private var appearance: AppAppearance = .system

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("显示模式", systemImage: "circle.lefthalf.filled")
                .font(.body)
                .foregroundStyle(.primary)

            Picker("显示模式", selection: $appearance) {
                ForEach(AppAppearance.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("appearancePicker")

            Text("跟随系统会自动切换日间与夜间外观，视频播放区域始终保持深色。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
    }
}
