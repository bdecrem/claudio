import SwiftUI

struct ToolCallCard: View {
    let toolCall: ToolCall
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header — always visible
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    // Status icon
                    if toolCall.isComplete {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.green)
                    } else {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 12, height: 12)
                    }

                    // Tool name
                    Text(toolCall.name)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary.opacity(0.7))

                    Spacer()

                    // Chevron
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textDim)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
            }
            .buttonStyle(.plain)

            // Expanded detail
            if isExpanded {
                Theme.border.frame(height: 1)
                    .padding(.horizontal, 6)

                VStack(alignment: .leading, spacing: 6) {
                    // Args
                    if !toolCall.args.isEmpty {
                        ForEach(Array(toolCall.args.keys.sorted()), id: \.self) { key in
                            HStack(alignment: .top, spacing: 4) {
                                Text(key + ":")
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundStyle(Theme.textSecondary)
                                Text(toolCall.args[key] ?? "")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(Theme.textPrimary.opacity(0.6))
                                    .lineLimit(3)
                            }
                        }
                    }

                    // Output
                    if let output = toolCall.output, !output.isEmpty {
                        Text(output.prefix(200) + (output.count > 200 ? "..." : ""))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.textPrimary.opacity(0.5))
                            .lineLimit(4)
                            .padding(.top, 2)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
        }
        .background(Theme.background.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
    }
}
