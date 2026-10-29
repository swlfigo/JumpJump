import UIKit

// Aligned player rows — [rank] ● name [value] [note] — for the lobby, the live
// standings and the match result. Fixed-width columns keep scores and statuses
// lined up whatever the names are; long names truncate.
final class PlayerTable: UIStackView {
    struct Row {
        var rank: Int?
        let color: UIColor
        let name: String
        let isSelf: Bool
        var value: String? // e.g. the score
        var note: String?  // e.g. 已准备 / 掉落
        var dimmed = false // out of the race
    }

    private let fontSize: CGFloat
    private let rankWidth: CGFloat
    private let valueWidth: CGFloat
    private let noteWidth: CGFloat
    private let columnSpacing: CGFloat

    init(fontSize: CGFloat, rankWidth: CGFloat = 0, valueWidth: CGFloat = 0, noteWidth: CGFloat = 0, columnSpacing: CGFloat = 6) {
        self.fontSize = fontSize
        self.rankWidth = rankWidth
        self.valueWidth = valueWidth
        self.noteWidth = noteWidth
        self.columnSpacing = columnSpacing
        super.init(frame: .zero)
        axis = .vertical
        spacing = (fontSize * 0.35).rounded()
        // Read as one element: "你，Sim，2；Bot，4，掉落".
        isAccessibilityElement = true
        accessibilityTraits = .staticText
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ rows: [Row]) {
        arrangedSubviews.forEach { $0.removeFromSuperview() }
        rows.forEach { addArrangedSubview(line(for: $0)) }
        accessibilityLabel = rows.map { row in
            [row.rank.map { "第\($0)名" }, row.isSelf ? "你" : nil, row.name, row.value, row.note]
                .compactMap { $0 }.joined(separator: "，")
        }.joined(separator: "；")
    }

    private func line(for row: Row) -> UIView {
        let ink = UIColor(hex: row.dimmed ? 0x7C8588 : 0x303943)
        var cells: [UILabel] = []
        if rankWidth > 0 { cells.append(cell(row.rank.map { "\($0)." } ?? "", width: rankWidth, align: .right, color: ink, digits: true)) }
        cells.append(cell("●", width: fontSize, align: .center, color: row.color))
        cells.append(cell(row.name, width: nil, align: .left, color: ink, weight: row.isSelf ? .bold : .medium))
        if valueWidth > 0 { cells.append(cell(row.value ?? "", width: valueWidth, align: .right, color: ink, digits: true)) }
        if noteWidth > 0 { cells.append(cell(row.note ?? "", width: noteWidth, align: .left, color: UIColor(hex: 0x7C8588))) }
        let line = UIStackView(arrangedSubviews: cells)
        line.spacing = columnSpacing
        line.alignment = .firstBaseline
        return line
    }

    private func cell(_ text: String, width: CGFloat?, align: NSTextAlignment, color: UIColor,
                      weight: UIFont.Weight = .medium, digits: Bool = false) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = digits ? .monospacedDigitSystemFont(ofSize: fontSize, weight: weight) : .systemFont(ofSize: fontSize, weight: weight)
        label.textColor = color
        label.textAlignment = align
        label.lineBreakMode = .byTruncatingTail
        if let width {
            label.widthAnchor.constraint(equalToConstant: width).isActive = true
        } else { // the name column takes whatever is left
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        return label
    }
}
