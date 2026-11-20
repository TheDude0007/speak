import Foundation

/// Shared between the Speak app and the Speak keyboard through an App Group,
/// so dictations made in the app can be inserted from the keyboard in any app.
enum SharedStore {
    static let group = "group.com.gemnisound.speak"
    private static let key = "recent"

    static var defaults: UserDefaults? { UserDefaults(suiteName: group) }

    struct Item: Codable, Identifiable, Hashable {
        var id = UUID()
        let date: Date
        let text: String
    }

    static func recent() -> [Item] {
        guard let data = defaults?.data(forKey: key),
              let items = try? JSONDecoder().decode([Item].self, from: data) else { return [] }
        return items
    }

    static func add(_ text: String) {
        var items = recent()
        items.insert(Item(date: Date(), text: text), at: 0)
        if items.count > 50 { items.removeLast(items.count - 50) }
        if let data = try? JSONEncoder().encode(items) { defaults?.set(data, forKey: key) }
    }

    static func remove(_ item: Item) {
        let items = recent().filter { $0.id != item.id }
        if let data = try? JSONEncoder().encode(items) { defaults?.set(data, forKey: key) }
    }

    static func clear() { defaults?.removeObject(forKey: key) }
}
