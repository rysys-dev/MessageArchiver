import MessageArchiverCore
import SwiftUI

struct VersionFooter: View {
    var body: some View {
        HStack(spacing: 4) {
            Text("v\(AppVersion.full) ·")
            Link("rysys.net", destination: AppVersion.websiteURL)
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}
