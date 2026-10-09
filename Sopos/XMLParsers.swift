import Foundation

/// Flattens a SOAP response into `[elementName: text]` for all leaf elements.
final class LeafXMLParser: NSObject, XMLParserDelegate {
    private var fields: [String: String] = [:]
    private var text: String?

    static func parse(_ data: Data) -> [String: String] {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        let delegate = LeafXMLParser()
        parser.delegate = delegate
        parser.parse()
        return delegate.fields
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text?.append(string)
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if let text { fields[name] = text }
        text = nil
    }
}

struct DIDLItem {
    var title: String?
    var creator: String?
    var uri: String?
    var metadata: String?
    var albumArtURI: String?
    var streamContent: String?
}

/// Parses DIDL-Lite, the metadata format Sonos uses for favorites and tracks.
final class DIDLParser: NSObject, XMLParserDelegate {
    private var items: [DIDLItem] = []
    private var current: DIDLItem?
    private var text: String?

    static func parse(_ xml: String) -> [DIDLItem] {
        guard !xml.isEmpty, let data = xml.data(using: .utf8) else { return [] }
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        let delegate = DIDLParser()
        parser.delegate = delegate
        parser.parse()
        return delegate.items
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        if name == "item" || name == "container" { current = DIDLItem() }
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text?.append(string)
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        defer { text = nil }
        if name == "item" || name == "container" {
            if let current { items.append(current) }
            current = nil
            return
        }
        guard current != nil, let text else { return }
        switch name {
        case "title": current?.title = text
        case "creator": current?.creator = text
        case "res": if current?.uri == nil { current?.uri = text }
        case "resMD": current?.metadata = text
        case "albumArtURI": current?.albumArtURI = text
        case "streamContent": current?.streamContent = text
        default: break
        }
    }
}

/// Parses the ZoneGroupState XML into rooms (one per group, addressed via its coordinator).
final class ZoneGroupParser: NSObject, XMLParserDelegate {
    private struct Member {
        let uuid: String
        let name: String
        let host: String?
        let visible: Bool
    }

    private var rooms: [Room] = []
    private var coordinator: String?
    private var members: [Member] = []

    static func parse(_ xml: String) -> [Room] {
        guard let data = xml.data(using: .utf8) else { return [] }
        let parser = XMLParser(data: data)
        let delegate = ZoneGroupParser()
        parser.delegate = delegate
        parser.parse()
        return delegate.rooms.sorted { $0.name < $1.name }
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        switch name {
        case "ZoneGroup":
            coordinator = attributes["Coordinator"]
            members = []
        case "ZoneGroupMember":
            guard let uuid = attributes["UUID"] else { return }
            members.append(Member(
                uuid: uuid,
                name: attributes["ZoneName"] ?? "Sonos",
                host: attributes["Location"].flatMap { URL(string: $0)?.host },
                visible: attributes["Invisible"] != "1" && attributes["IsZoneBridge"] != "1"))
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        guard name == "ZoneGroup" else { return }
        defer { coordinator = nil; members = [] }
        guard let leader = members.first(where: { $0.uuid == coordinator }), let host = leader.host else { return }
        var names: [String] = []
        for member in members where member.visible && !names.contains(member.name) {
            names.append(member.name)
        }
        guard !names.isEmpty else { return }
        rooms.append(Room(id: leader.uuid, name: names.joined(separator: " + "), host: host))
    }
}
