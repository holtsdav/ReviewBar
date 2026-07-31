import SwiftUI

struct DataStatusBanner: View {
    let lastUpdated: Date?
    let issue: AppError?

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(issue?.title ?? "Showing Saved Data")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                if let lastUpdated {
                    Text("Some information was last updated \(DisplayFormatters.dateTime(lastUpdated)).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let issue {
                    Text(issue.message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: issue == nil ? "clock.arrow.circlepath" : "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
                .foregroundStyle(.orange)
        }
        .accessibilityElement(children: .combine)
    }
}
