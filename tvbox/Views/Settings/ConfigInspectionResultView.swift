import SwiftUI

/// 检测报告属于当前页面内容，不再用多个原生 Alert 竞争同一份结果。
struct ConfigInspectionResultView: View {
    let result: VodConfigInspectionResult
    var buttonTitle = "完成"
    var onFinish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("配置检测：\(result.compatibility.title)", systemImage: "checkmark.circle")
                .font(.headline)
            Text(result.message)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Button(buttonTitle, action: onFinish)
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .accessibilityIdentifier("config.inspection.finish")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("config.inspection.result")
    }
}
