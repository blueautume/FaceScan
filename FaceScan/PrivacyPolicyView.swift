import SwiftUI

/// Presented inside the scanner's existing screen; it never opens another page.
struct PrivacyPolicyView: View {
    let isAccepted: Bool
    let onAccept: () -> Void
    let onLater: () -> Void
    let onRevoke: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 9) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 25, weight: .medium))
                    .foregroundStyle(ScanTheme.tint)
                    .accessibilityHidden(true)
                Text("隐私协议")
                    .font(.system(size: 25, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("FaceScan，全程在本机处理。")
                    .font(.system(size: 14))
                    .foregroundStyle(ScanTheme.secondary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 17) {
                    section("相机与面部数据", text: "点击开始扫描后才使用相机。画面、原深感深度与头部姿态仅在本机重建模型，不用于识别身份，不录制原始画面。打开的 PLY 仅在本机读取与展示，不改写源文件。")
                    section("本机原始历史", text: "每次扫描成功后，自动在本机保存一份原始点云，保留位置、颜色与扫描信息。滤波和呈现增强不会覆盖历史，可从历史列表重新打开或删除。历史不自动淘汰，排除系统备份；删除或重新安装 App 可能丢失记录，需要长期保留的模型请主动导出。")
                    section("没有云端交互", text: "无需账号。App 不上传扫描数据，不提供云同步，也不包含广告、分析统计或第三方追踪。协议版本、滤波和显示参数偏好也仅保存在本机。")
                    section("导出与清除", text: "主动导出时，由你通过系统面板选择保存位置；若选择 iCloud 或其他文件服务，由所选服务处理。撤回同意会停止采集并清除当前模型、全部本机扫描历史与临时文件，已主动导出的文件需自行删除。")
                }
                .padding(.trailing, 3)
            }
            .frame(maxHeight: 320)

            VStack(spacing: 12) {
                Button(action: isAccepted ? onLater : onAccept) {
                    Text(isAccepted ? "完成" : "同意并继续")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(ScanPrimaryButton())

                Button(action: isAccepted ? onRevoke : onLater) {
                    Text(isAccepted ? "撤回同意并清除全部扫描" : "暂不使用相机")
                        .font(.system(size: 13))
                        .foregroundStyle(isAccepted ? ScanTheme.destructive : ScanTheme.secondary)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(24)
        .frame(maxWidth: 460)
        .foregroundStyle(ScanTheme.primary)
        .background(ScanTheme.card, in: RoundedRectangle(cornerRadius: 28))
        .overlay {
            RoundedRectangle(cornerRadius: 28)
                .stroke(ScanTheme.border.opacity(0.75), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .shadow(color: ScanTheme.primary.opacity(0.08), radius: 24, y: 8)
        .accessibilityElement(children: .contain)
    }

    private func section(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(ScanTheme.secondary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
