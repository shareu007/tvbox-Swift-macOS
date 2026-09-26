import Foundation

/// CMS XML fields may be reordered, omitted, escaped text, or CDATA.
final class CMSXMLResponseParser: NSObject, XMLParserDelegate {
    struct Response {
        let sorts: [MovieSort.SortData]
        let homeVideos: [Movie.Video]
        let details: [VodInfo]
    }
    private var details: [VodInfo] = []
    private var routes: [(flag: String, url: String)] = []
    private var sorts: [MovieSort.SortData] = []
    private var videos: [Movie.Video] = []
    private var elements: [(name: String, text: String, attributes: [String: String])] = []
    private var categoryID: String?
    private var videoFields: [String: String]?
    private let sourceKey: String

    private init(sourceKey: String) {
        self.sourceKey = sourceKey
    }

    static func parse(_ data: Data, sourceKey: String) throws -> Response {
        let delegate = CMSXMLResponseParser(sourceKey: sourceKey)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else {
            throw SourceError.parseError("XML 数据格式错误")
        }
        return Response(sorts: delegate.sorts, homeVideos: delegate.videos, details: delegate.details)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        let elementName = elementName.lowercased()
        elements.append((elementName, "", attributeDict))
        if elementName == "video" { videoFields = [:]; routes = [] }
        if elementName == "ty", videoFields == nil { categoryID = attributeDict["id"] }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !elements.isEmpty else { return }
        elements[elements.count - 1].text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let text = String(data: CDATABlock, encoding: .utf8) {
            self.parser(parser, foundCharacters: text)
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let elementName = elementName.lowercased()
        guard let element = elements.popLast() else { return }
        if !elements.isEmpty { elements[elements.count - 1].text += element.text }
        let text = element.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if elementName == "video", let fields = videoFields {
            if let id = fields["id"], !id.isEmpty, let name = fields["name"], !name.isEmpty {
                var video = Movie.Video(id: id, name: name, pic: fields["pic"] ?? "", note: fields["note"] ?? fields["remarks"] ?? "", sourceKey: sourceKey)
                video.year = fields["year"] ?? ""
                video.area = fields["area"] ?? ""
                video.type = fields["type"] ?? ""
                video.tid = fields["tid"] ?? ""
                video.actor = fields["actor"] ?? ""
                video.director = fields["director"] ?? ""
                video.des = fields["des"] ?? ""
                video.last = fields["last"] ?? ""
                videos.append(video)
                details.append(VodInfo.from(video: video,
                    playFrom: routes.map(\.flag).joined(separator: "$$$"),
                    playUrl: routes.map(\.url).joined(separator: "$$$")))
            }
            videoFields = nil
        } else if elementName == "dd", videoFields != nil, !text.isEmpty {
            let flag = element.attributes["flag"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            routes.append((flag.isEmpty ? "线路\(routes.count + 1)" : flag, text))
        } else if videoFields != nil, elements.last?.name == "video" {
            videoFields?[elementName] = text
        } else if elementName == "ty", let id = categoryID {
            if !id.isEmpty, !text.isEmpty { sorts.append(.init(id: id, name: text)) }
            categoryID = nil
        }
    }
}
