import SwiftUI

/// Detail panel showing all properties of the selected element.
struct PropertyInspectorView: View {
    let element: ElementNode?

    var body: some View {
        if let element {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerSection(element)
                    identitySection(element)
                    frameSection(element)
                    accessibilitySection(element)
                    if !element.customActions.isEmpty {
                        actionsSection(element)
                    }
                    if !element.children.isEmpty {
                        childrenSection(element)
                    }
                }
                .padding()
            }
        } else {
            ContentUnavailableView(
                "No Selection",
                systemImage: "cursorarrow.click.2",
                description: Text("Select an element from the tree or click an element in the Simulator to inspect it.")
            )
        }
    }

    @ViewBuilder
    private func headerSection(_ el: ElementNode) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(el.type)
                .font(.system(.title2, design: .monospaced))
                .fontWeight(.bold)
            if let label = el.label, !label.isEmpty {
                Text("\"\(label)\"")
                    .font(.title3)
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private func identitySection(_ el: ElementNode) -> some View {
        PropertySection(title: "Identity") {
            PropertyRow(label: "Type", value: el.type)
            PropertyRow(label: "Role", value: el.role ?? "—")
            PropertyRow(label: "Role Desc", value: el.roleDescription ?? "—")
            PropertyRow(label: "Label", value: el.label ?? "—")
            PropertyRow(label: "Identifier", value: el.identifier ?? "—")
            PropertyRow(label: "Value", value: el.value ?? "—")
            PropertyRow(label: "Help", value: el.help ?? "—")
            PropertyRow(label: "Subrole", value: el.subrole ?? "—")
            PropertyRow(label: "Enabled", value: el.enabled ? "Yes" : "No")
        }
    }

    @ViewBuilder
    private func frameSection(_ el: ElementNode) -> some View {
        PropertySection(title: "Frame") {
            PropertyRow(label: "X", value: String(format: "%.1f", el.frame.x))
            PropertyRow(label: "Y", value: String(format: "%.1f", el.frame.y))
            PropertyRow(label: "Width", value: String(format: "%.1f", el.frame.width))
            PropertyRow(label: "Height", value: String(format: "%.1f", el.frame.height))
        }
    }

    @ViewBuilder
    private func accessibilitySection(_ el: ElementNode) -> some View {
        PropertySection(title: "Accessibility") {
            if el.traits.isEmpty {
                PropertyRow(label: "Traits", value: "None")
            } else {
                ForEach(el.traits, id: \.self) { trait in
                    PropertyRow(label: "Trait", value: trait)
                }
            }
        }
    }

    @ViewBuilder
    private func actionsSection(_ el: ElementNode) -> some View {
        PropertySection(title: "Custom Actions") {
            ForEach(el.customActions, id: \.self) { action in
                PropertyRow(label: "Action", value: action)
            }
        }
    }

    @ViewBuilder
    private func childrenSection(_ el: ElementNode) -> some View {
        PropertySection(title: "Children (\(el.children.count))") {
            ForEach(el.children) { child in
                HStack {
                    Text(child.displayTitle)
                        .font(.system(.caption, design: .monospaced))
                    Spacer()
                    Text(child.frame.description)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary.opacity(0.7))
                }
            }
        }
    }
}

// MARK: - Reusable Components

struct PropertySection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)

            VStack(spacing: 4) {
                content
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)
        }
    }
}

struct PropertyRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .trailing)
            Text(value)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
            Spacer()
        }
    }
}
