import SwiftUI

struct CWLogView: View {
    @EnvironmentObject private var store: CWStore

    var body: some View {
        List {
            if store.logs.isEmpty {
                Text("还没有日志").foregroundColor(CWTheme.sub)
            }
            ForEach(Array(store.logs.reversed())) { line in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(CWLogView.formatter.string(from: line.at))
                            .font(.caption2)
                            .foregroundColor(CWTheme.sub)
                        Text(line.level)
                            .font(.caption2.weight(.semibold))
                            .foregroundColor(color(for: line.level))
                    }
                    Text(line.text)
                        .font(.footnote)
                        .foregroundColor(CWTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)
            }
        }
        .listStyle(.plain)
        .navigationTitle("日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("清空") { store.clearLogs() }
            }
        }
    }

    private func color(for level: String) -> Color {
        switch level {
        case "成功":
            return CWTheme.mint
        case "错误":
            return CWTheme.coral
        case "警告":
            return CWTheme.amber
        default:
            return CWTheme.sub
        }
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
