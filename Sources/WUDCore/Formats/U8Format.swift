import Foundation

/// Parser/extractor for Nintendo's U8 archive container (used for the FST content and for
/// several other bundled Wii/Wii U asset packs). Big-endian header, a flat node table, then a
/// null-terminated name string table, then raw file data.
public enum U8Format {
    public static let magic: UInt32 = 0x55AA_382D
    static let maxNodes = 100_000
    static let maxFileSize = 100 * 1024 * 1024
    static let maxStackSize = 4096

    public struct Node {
        public let type: UInt16
        public let nameOffset: UInt16
        public let dataOffset: UInt32
        public let size: UInt32
    }

    public struct Archive {
        public let data: [UInt8]
        public let rootNodeOffset: UInt32
        public let dataOffset: UInt32
        public let nodes: [Node]
        public let stringTable: [UInt8]

        public func name(of node: Node) throws -> String {
            guard Int(node.nameOffset) < stringTable.count else {
                throw ParseError.invalidNameOffset(node.nameOffset)
            }
            var end = Int(node.nameOffset)
            while end < stringTable.count, stringTable[end] != 0 { end += 1 }
            guard end < stringTable.count else { throw ParseError.unterminatedString(node.nameOffset) }
            return String(decoding: stringTable[Int(node.nameOffset)..<end], as: UTF8.self)
        }
    }

    public enum ParseError: Error {
        case tooShort
        case badMagic
        case invalidRootNodeOffset(UInt32)
        case invalidDataOffset(UInt32)
        case invalidNodeCount(UInt32)
        case invalidNodeTableBounds
        case invalidStringTableBounds
        case invalidNameOffset(UInt16)
        case unterminatedString(UInt16)
        case unsafePath(String)
        case fileNodeOutOfBounds
        case nestingTooDeep
    }

    public static func parse(_ data: [UInt8]) throws -> Archive {
        guard data.count >= 16 else { throw ParseError.tooShort }
        let magic = bigEndianU32(data[0..<4])
        guard magic == Self.magic else { throw ParseError.badMagic }

        let rootNodeOffset = bigEndianU32(data[4..<8])
        let dataOffset = bigEndianU32(data[12..<16])
        guard rootNodeOffset >= 16, Int(rootNodeOffset) + 12 <= data.count else {
            throw ParseError.invalidRootNodeOffset(rootNodeOffset)
        }
        guard dataOffset >= rootNodeOffset, Int(dataOffset) <= data.count else {
            throw ParseError.invalidDataOffset(dataOffset)
        }

        let root = parseNode(data, at: Int(rootNodeOffset))
        let totalNodes = root.size
        guard totalNodes > 0, totalNodes <= UInt32(maxNodes) else {
            throw ParseError.invalidNodeCount(totalNodes)
        }

        let nodeTableSize = totalNodes &* 12
        guard nodeTableSize <= UInt32(data.count),
              rootNodeOffset + nodeTableSize <= dataOffset,
              Int(rootNodeOffset + nodeTableSize) <= data.count else {
            throw ParseError.invalidNodeTableBounds
        }

        var nodes: [Node] = []
        nodes.reserveCapacity(Int(totalNodes))
        for i in 0..<totalNodes {
            let start = Int(rootNodeOffset + i * 12)
            nodes.append(parseNode(data, at: start))
        }

        let stringTableStart = Int(rootNodeOffset + nodeTableSize)
        let stringTableEnd = Int(dataOffset)
        guard stringTableStart <= data.count, stringTableEnd <= data.count, stringTableStart <= stringTableEnd else {
            throw ParseError.invalidStringTableBounds
        }

        return Archive(
            data: data,
            rootNodeOffset: rootNodeOffset,
            dataOffset: dataOffset,
            nodes: nodes,
            stringTable: Array(data[stringTableStart..<stringTableEnd])
        )
    }

    private static func parseNode(_ data: [UInt8], at offset: Int) -> Node {
        Node(
            type: bigEndianU16(data[offset..<(offset + 2)]),
            nameOffset: bigEndianU16(data[(offset + 2)..<(offset + 4)]),
            dataOffset: bigEndianU32(data[(offset + 4)..<(offset + 8)]),
            size: bigEndianU32(data[(offset + 8)..<(offset + 12)])
        )
    }

    /// Extracts every file/directory node to `outputURL`, rejecting any name that would escape it.
    public static func extract(_ data: [UInt8], to outputURL: URL) throws {
        let archive = try parse(data)
        let fm = FileManager.default
        try fm.createDirectory(at: outputURL, withIntermediateDirectories: true)

        var dirStack: [URL] = [outputURL]
        var currentDir = outputURL
        var breakNodes: [UInt32] = [UInt32(archive.nodes.count)]

        var i: UInt32 = 1
        while i < UInt32(archive.nodes.count) {
            let node = archive.nodes[Int(i)]
            let name = try archive.name(of: node)
            let cleanName = try sanitize(name)

            if node.type == 0x0100 {
                let nextDir = try safeJoin(base: outputURL, current: currentDir, name: cleanName)
                try fm.createDirectory(at: nextDir, withIntermediateDirectories: true)
                currentDir = nextDir
                dirStack.append(nextDir)
                breakNodes.append(node.size)
                if dirStack.count > maxStackSize { throw ParseError.nestingTooDeep }
            } else {
                if node.size <= UInt32(maxFileSize) {
                    let end = node.dataOffset + node.size
                    guard end >= node.dataOffset, Int(end) <= archive.data.count else {
                        throw ParseError.fileNodeOutOfBounds
                    }
                    let targetURL = try safeJoin(base: outputURL, current: currentDir, name: cleanName)
                    let slice = Data(archive.data[Int(node.dataOffset)..<Int(end)])
                    try slice.write(to: targetURL)
                }
            }

            while dirStack.count > 1, breakNodes.last == i + 1 {
                breakNodes.removeLast()
                dirStack.removeLast()
                currentDir = dirStack.last!
            }
            i += 1
        }
    }

    private static func sanitize(_ name: String) throws -> String {
        guard !name.isEmpty, name != ".", !name.contains("\0") else {
            throw ParseError.unsafePath(name)
        }
        let clean = (name as NSString).standardizingPath
        if clean == "." || clean == ".." || clean.hasPrefix("../") || (clean as NSString).isAbsolutePath {
            throw ParseError.unsafePath(name)
        }
        return clean
    }

    private static func safeJoin(base: URL, current: URL, name: String) throws -> URL {
        let target = current.appendingPathComponent(name).standardizedFileURL
        let absBase = base.standardizedFileURL
        guard target.path == absBase.path || target.path.hasPrefix(absBase.path + "/") else {
            throw ParseError.unsafePath(name)
        }
        return target
    }
}
