import SwiftUI

struct Tag: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.callout.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .foregroundStyle(tint.mix(with: .black, by: 0.45))
            .background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .lineLimit(1)
            .fixedSize()
    }
}

struct DecisionDot: View {
    let decision: Decision
    var locked: Bool = false

    var body: some View {
        Group {
            switch decision {
            case .redact:
                RoundedRectangle(cornerRadius: 2.5).fill(.primary)
            case .keep:
                Circle().strokeBorder(Color.accentColor, lineWidth: 1.8)
            case .pending:
                Circle().strokeBorder(Color.orange, lineWidth: 1.8)
            }
        }
        .frame(width: 10, height: 10)
        .overlay(alignment: .bottomTrailing) {
            if locked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 6, weight: .bold))
                    .foregroundStyle(.secondary)
                    .offset(x: 5, y: 4)
            }
        }
        .accessibilityLabel(decision.label)
    }
}

/// Segmentierte Entscheidung Schwärzen / Behalten.
struct DecisionPicker: View {
    let decision: Decision
    let locked: Bool
    let lockReason: String
    let onChange: (Decision) -> Void

    var body: some View {
        if locked {
            Label(lockReason.isEmpty ? "Fest" : lockReason, systemImage: "lock.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 176, alignment: .leading)
        } else {
            Picker("Entscheidung", selection: Binding(
                get: { decision },
                set: { onChange($0) }
            )) {
                Text("Schwärzen").tag(Decision.redact)
                Text("Behalten").tag(Decision.keep)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 176)
        }
    }
}

/// Textausschnitt mit hervorgehobenem Treffer.
struct SnippetText: View {
    let before: String
    let matched: String
    let after: String
    let redacted: Bool
    let replacement: String?
    var tint: Color = .orange

    var body: some View {
        Text(attributed)
            .font(.system(.callout, design: .serif))
            .lineLimit(3)
            .textSelection(.enabled)
    }

    private var attributed: AttributedString {
        var a = AttributedString(before)
        var m: AttributedString
        if redacted {
            m = AttributedString(" \(replacement ?? "geschwärzt") ")
            m.foregroundColor = .white
            m.backgroundColor = .black
            m.font = .system(.caption, design: .monospaced)
        } else {
            m = AttributedString(matched)
            m.backgroundColor = tint.opacity(0.25)
        }
        a.append(m)
        a.append(AttributedString(after))
        return a
    }
}

struct StatTile: View {
    let value: String
    let label: String
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(tint)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Schwebende Statuskapsel in Liquid Glass.
struct ProgressPill: View {
    let text: String
    let value: Double

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(text)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            if value > 0 {
                Text(value, format: .percent.precision(.fractionLength(0)))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .glassEffect(.regular, in: .capsule)
        .frame(maxWidth: 560)
    }
}

extension Color {
    static let redactBlack = Color(red: 0.06, green: 0.06, blue: 0.07)
}
