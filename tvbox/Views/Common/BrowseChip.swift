import SwiftUI

/// 浏览页统一的筛选按钮：保持触控尺寸，选中态同时通过文字颜色和描边表达。
struct BrowseChip: View {
    let title: String
    var icon: String? = nil
    var isSelected = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            if let icon { Image(systemName: icon) }
            Text(title).lineLimit(1)
        }
        .font(.subheadline.weight(isSelected ? .semibold : .regular))
        .foregroundStyle(isSelected ? Color.orange : Color.white.opacity(0.75))
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .background(isSelected ? Color.orange.opacity(0.14) : Color.white.opacity(0.05), in: Capsule())
        .overlay(Capsule().strokeBorder(isSelected ? Color.orange.opacity(0.5) : Color.clear, lineWidth: 1))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isSelected)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
