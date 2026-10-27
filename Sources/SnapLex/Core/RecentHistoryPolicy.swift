enum RecentHistoryPolicy {
    static func inserting<Element>(_ element: Element, into history: [Element], limit: Int) -> [Element] {
        guard limit > 0 else { return [] }
        return [element] + history.prefix(limit - 1)
    }
}
