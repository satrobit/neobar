import Foundation

protocol FileMovingFileSystem {
    func volumeIdentifier(for url: URL) throws -> String?
    func itemExists(at url: URL) -> Bool
    func moveItem(at source: URL, to destination: URL) throws
    func copyItem(at source: URL, to destination: URL) throws
    func removeItemIfPresent(at url: URL)
}

struct LiveFileMovingFileSystem: FileMovingFileSystem {
    private let manager = FileManager.default

    func volumeIdentifier(for url: URL) throws -> String? {
        let volumeURL = try url.resourceValues(forKeys: [.volumeURLKey]).volume
        return volumeURL?.standardizedFileURL.resolvingSymlinksInPath().path
    }

    func itemExists(at url: URL) -> Bool {
        manager.fileExists(atPath: url.path)
    }

    func moveItem(at source: URL, to destination: URL) throws {
        try manager.moveItem(at: source, to: destination)
    }

    func copyItem(at source: URL, to destination: URL) throws {
        try manager.copyItem(at: source, to: destination)
    }

    func removeItemIfPresent(at url: URL) {
        guard manager.fileExists(atPath: url.path) else { return }
        try? manager.removeItem(at: url)
    }
}

/// A synchronous, serial file mover. The caller is responsible for putting it on a background serial queue and presenting the result on the main thread.
struct FileMover {
    struct BatchResult: Equatable {
        var succeeded: [URL] = []
        var conflicts: [URL] = []
        var failed: [URL] = []

        var hasIssues: Bool { !conflicts.isEmpty || !failed.isEmpty }
    }

    private let fileSystem: FileMovingFileSystem
    private let temporaryName: (String) -> String

    init(fileSystem: FileMovingFileSystem = LiveFileMovingFileSystem(),
         temporaryName: @escaping (String) -> String = {
             ".neobar-drop-\(UUID().uuidString)-\($0)"
         }) {
        self.fileSystem = fileSystem
        self.temporaryName = temporaryName
    }

    func move(_ sources: [URL], into destination: URL) -> BatchResult {
        var result = BatchResult()
        for source in sources {
            move(source, into: destination, result: &result)
        }
        return result
    }

    private func move(_ source: URL, into destination: URL, result: inout BatchResult) {
        let finalURL = destination.appendingPathComponent(source.lastPathComponent)
        guard !fileSystem.itemExists(at: finalURL) else {
            result.conflicts.append(source)
            return
        }

        let sameVolume: Bool
        do {
            let sourceVolume = try fileSystem.volumeIdentifier(for: source)
            let destinationVolume = try fileSystem.volumeIdentifier(for: destination)
            // Move only when both volume IDs are readable and equal; when it cannot be confirmed, always copy to preserve the source.
            sameVolume = sourceVolume != nil && sourceVolume == destinationVolume
        } catch {
            sameVolume = false
        }

        if sameVolume {
            do {
                try fileSystem.moveItem(at: source, to: finalURL)
                result.succeeded.append(source)
            } catch {
                if fileSystem.itemExists(at: finalURL) {
                    result.conflicts.append(source)
                } else {
                    result.failed.append(source)
                }
            }
            return
        }

        let temporaryURL = destination.appendingPathComponent(temporaryName(source.lastPathComponent))
        // A UUID is not supposed to collide; if an item with the same name really exists, better to fail than ever delete a file of unknown origin.
        guard !fileSystem.itemExists(at: temporaryURL) else {
            result.failed.append(source)
            return
        }
        do {
            try fileSystem.copyItem(at: source, to: temporaryURL)
            guard !fileSystem.itemExists(at: finalURL) else {
                fileSystem.removeItemIfPresent(at: temporaryURL)
                result.conflicts.append(source)
                return
            }
            try fileSystem.moveItem(at: temporaryURL, to: finalURL)
            result.succeeded.append(source)
        } catch {
            fileSystem.removeItemIfPresent(at: temporaryURL)
            if fileSystem.itemExists(at: finalURL) {
                result.conflicts.append(source)
            } else {
                result.failed.append(source)
            }
        }
    }
}
