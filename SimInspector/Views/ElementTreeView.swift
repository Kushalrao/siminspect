import SwiftUI

/// Outline view of the element hierarchy tree.
struct ElementTreeView: View {
    let elements: [ElementNode]
    @Binding var selectedElement: ElementNode?
    @Binding var searchText: String

    var body: some View {
        VStack(spacing: 0) {
            // Search field
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search elements...", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(.bar)

            Divider()

            if elements.isEmpty {
                ContentUnavailableView(
                    "No Elements",
                    systemImage: "rectangle.dashed",
                    description: Text("No UI elements found. Make sure an app is running in the Simulator.")
                )
            } else {
                List(selection: $selectedElement) {
                    ForEach(filteredElements) { node in
                        ElementTreeRow(node: node, isSelected: selectedElement?.id == node.id)
                            .tag(node)
                    }
                    .listRowSeparator(.hidden)
                }
                .listStyle(.sidebar)
            }
        }
    }

    private var filteredElements: [ElementNode] {
        if searchText.isEmpty {
            return elements
        }
        return elements.compactMap { filterNode($0) }
    }

    /// Recursively filter nodes matching the search text.
    private func filterNode(_ node: ElementNode) -> ElementNode? {
        let matchesSelf = node.type.localizedCaseInsensitiveContains(searchText)
            || (node.label?.localizedCaseInsensitiveContains(searchText) ?? false)
            || (node.identifier?.localizedCaseInsensitiveContains(searchText) ?? false)

        let matchingChildren = node.children.compactMap { filterNode($0) }

        if matchesSelf || !matchingChildren.isEmpty {
            return ElementNode(
                type: node.type,
                label: node.label,
                identifier: node.identifier,
                value: node.value,
                frame: node.frame,
                enabled: node.enabled,
                traits: node.traits,
                customActions: node.customActions,
                children: matchingChildren,
                depth: node.depth,
                role: node.role,
                roleDescription: node.roleDescription,
                help: node.help,
                subrole: node.subrole
            )
        }
        return nil
    }
}

/// A single row in the element tree.
struct ElementTreeRow: View {
    let node: ElementNode
    let isSelected: Bool

    var body: some View {
        DisclosureGroup {
            ForEach(node.children) { child in
                ElementTreeRow(node: child, isSelected: false)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: iconForType(node.type))
                    .foregroundColor(colorForType(node.type))
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text(node.type)
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(.medium)

                    if let label = node.label, !label.isEmpty {
                        Text("\"\(label)\"")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else if let identifier = node.identifier, !identifier.isEmpty {
                        Text(identifier)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                Text(node.frame.description)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.7))
            }
            .padding(.vertical, 2)
        }
    }

    private func iconForType(_ type: String) -> String {
        let lower = type.lowercased()
        if lower.contains("button") { return "hand.tap" }
        if lower.contains("label") || lower.contains("text") { return "textformat" }
        if lower.contains("image") { return "photo" }
        if lower.contains("textfield") || lower.contains("searchfield") { return "character.cursor.ibeam" }
        if lower.contains("switch") || lower.contains("toggle") { return "switch.2" }
        if lower.contains("slider") { return "slider.horizontal.3" }
        if lower.contains("table") || lower.contains("list") || lower.contains("collection") { return "list.bullet" }
        if lower.contains("cell") { return "rectangle" }
        if lower.contains("scroll") { return "scroll" }
        if lower.contains("navigation") || lower.contains("navbar") { return "menubar.rectangle" }
        if lower.contains("tab") { return "square.grid.2x2" }
        if lower.contains("window") || lower.contains("application") { return "macwindow" }
        return "square.dashed"
    }

    private func colorForType(_ type: String) -> Color {
        let lower = type.lowercased()
        if lower.contains("button") { return .blue }
        if lower.contains("label") || lower.contains("text") { return .green }
        if lower.contains("image") { return .purple }
        if lower.contains("textfield") || lower.contains("searchfield") { return .orange }
        if lower.contains("switch") || lower.contains("toggle") { return .teal }
        return .secondary
    }
}
