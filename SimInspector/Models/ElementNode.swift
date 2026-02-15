import Foundation
import CoreGraphics

/// A node in the iOS accessibility/UI element tree returned by idb.
final class ElementNode: Identifiable, ObservableObject {
    let id: UUID
    let type: String
    let label: String?
    let identifier: String?
    let value: String?
    let frame: ElementFrame
    let enabled: Bool
    let traits: [String]
    let customActions: [String]
    let children: [ElementNode]
    let role: String?
    let roleDescription: String?
    let help: String?
    let subrole: String?

    /// Depth in the tree (0 = root)
    var depth: Int = 0

    init(
        type: String,
        label: String? = nil,
        identifier: String? = nil,
        value: String? = nil,
        frame: ElementFrame = .zero,
        enabled: Bool = true,
        traits: [String] = [],
        customActions: [String] = [],
        children: [ElementNode] = [],
        depth: Int = 0,
        role: String? = nil,
        roleDescription: String? = nil,
        help: String? = nil,
        subrole: String? = nil
    ) {
        self.id = UUID()
        self.type = type
        self.label = label
        self.identifier = identifier
        self.value = value
        self.frame = frame
        self.enabled = enabled
        self.traits = traits
        self.customActions = customActions
        self.children = children
        self.depth = depth
        self.role = role
        self.roleDescription = roleDescription
        self.help = help
        self.subrole = subrole
    }

    /// Display title for the tree view.
    var displayTitle: String {
        if let label, !label.isEmpty {
            return "\(type) — \"\(label)\""
        }
        if let identifier, !identifier.isEmpty {
            return "\(type) — \(identifier)"
        }
        return type
    }

    /// Flatten the tree for searching.
    var flattened: [ElementNode] {
        [self] + children.flatMap { $0.flattened }
    }
}

extension ElementNode: Hashable {
    static func == (lhs: ElementNode, rhs: ElementNode) -> Bool {
        lhs.id == rhs.id
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// Frame rectangle for a UI element (in iOS points).
struct ElementFrame: Hashable, Codable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    static let zero = ElementFrame(x: 0, y: 0, width: 0, height: 0)

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    var description: String {
        String(format: "(%.0f, %.0f, %.0f × %.0f)", x, y, width, height)
    }
}

// MARK: - JSON Decoding from idb output

extension ElementNode {
    /// Parse idb's `describe-all` JSON output into element nodes.
    static func fromIDBJSON(_ data: Data) throws -> [ElementNode] {
        let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        return json.map { Self.parseNode($0, depth: 0) }
    }

    /// Parse a single idb `describe-point` JSON result.
    static func fromIDBPointJSON(_ data: Data) throws -> ElementNode? {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return parseNode(json, depth: 0)
    }

    private static func parseNode(_ dict: [String: Any], depth: Int) -> ElementNode {
        let frame: ElementFrame
        if let frameDict = dict["frame"] as? [String: Any] {
            frame = ElementFrame(
                x: frameDict["x"] as? Double ?? 0,
                y: frameDict["y"] as? Double ?? 0,
                width: frameDict["width"] as? Double ?? 0,
                height: frameDict["height"] as? Double ?? 0
            )
        } else {
            frame = .zero
        }

        let childDicts = dict["children"] as? [[String: Any]] ?? []
        let children = childDicts.map { parseNode($0, depth: depth + 1) }

        let traitsRaw = dict["traits"] as? [String] ?? []
        let actionsRaw = dict["custom_actions"] as? [String] ?? []

        // idb uses different keys depending on version
        let type = dict["type"] as? String
            ?? dict["AXClass"] as? String
            ?? dict["element_type"] as? String
            ?? "Unknown"

        let label = dict["label"] as? String
            ?? dict["AXLabel"] as? String

        let identifier = dict["identifier"] as? String
            ?? dict["AXIdentifier"] as? String

        let value = dict["value"] as? String
            ?? dict["AXValue"] as? String

        let enabled = dict["enabled"] as? Bool ?? true

        let role = dict["role"] as? String
        let roleDescription = dict["role_description"] as? String
        let help = dict["help"] as? String
        let subrole = dict["subrole"] as? String

        return ElementNode(
            type: type,
            label: label,
            identifier: identifier,
            value: value,
            frame: frame,
            enabled: enabled,
            traits: traitsRaw,
            customActions: actionsRaw,
            children: children,
            depth: depth,
            role: role,
            roleDescription: roleDescription,
            help: help,
            subrole: subrole
        )
    }
}
