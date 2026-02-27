import SwiftUI

struct ResultCardView: View {
    let title: String
    let passed: Bool
    let verdict: String
    let details: [(label: String, value: String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.title2)
                    .foregroundColor(passed ? .green : .red)
                Text(title)
                    .font(.headline)
                Spacer()
            }

            ForEach(details.indices, id: \.self) { i in
                HStack {
                    Text(details[i].label)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(details[i].value)
                        .font(.caption.monospaced())
                }
            }

            HStack {
                Spacer()
                Text(verdict)
                    .font(.subheadline.bold())
                    .foregroundColor(passed ? .green : .red)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
        )
    }
}
