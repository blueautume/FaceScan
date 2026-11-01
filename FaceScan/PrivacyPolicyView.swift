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
                Text("Privacy")
                    .font(.system(size: 25, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("FaceScan processes everything on your device.")
                    .font(.system(size: 14))
                    .foregroundStyle(ScanTheme.secondary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 17) {
                    section("Camera & Face Data", text: "The camera is used only after you tap Start Scan. Camera images, TrueDepth depth data, and head pose are processed on your device to build the model. FaceScan does not identify you or record the original camera footage. Imported PLY files are read and displayed locally without changing the source file.")
                    section("Original Scans on This Device", text: "After each successful scan, FaceScan automatically saves an original point cloud on this device, including its positions, colors, and scan details. Filtering never overwrites the original. You can reopen or delete it in Scan History. Records are not automatically removed and are excluded from system backups. Deleting or reinstalling the app may erase them, so export any models you want to keep.")
                    section("No Cloud Services", text: "No account is required. FaceScan does not upload scan data or provide cloud sync, and contains no advertising, analytics, or third-party tracking. The privacy agreement version and your filter preferences are also stored only on this device.")
                    section("Exporting & Clearing Data", text: "When you export a model, you choose where to save it in the system file picker. If you choose iCloud or another file service, that service handles the file. Withdrawing consent stops capture and clears the current model, all scan history on this device, and temporary files. Files you have already exported are not deleted automatically. You can delete them separately.")
                }
                .padding(.trailing, 3)
            }
            .frame(maxHeight: 320)

            VStack(spacing: 12) {
                Button(action: isAccepted ? onLater : onAccept) {
                    Text(isAccepted ? LocalizedStringKey("Done") : LocalizedStringKey("Agree & Continue"))
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(ScanPrimaryButton())

                Button(action: isAccepted ? onRevoke : onLater) {
                    Text(isAccepted ? LocalizedStringKey("Withdraw Consent & Clear History")
                                    : LocalizedStringKey("Continue Without Camera"))
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

    private func section(_ title: LocalizedStringKey, text: LocalizedStringKey) -> some View {
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
