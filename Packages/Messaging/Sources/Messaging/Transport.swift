import Foundation
import EpistoliCore

/// An envelope waiting in our mailbox.
public struct InboxItem: Sendable, Equatable {
    public let id: UUID
    public let data: Data
}

/// Moves sealed envelopes and blobs between phones. It never sees plaintext when PGP is on.
/// Section 4: `LoopbackTransport`. Section 5: CloudKit.
public protocol Transport: Sendable {
    /// Puts an envelope in `recipient`'s mailbox.
    func deliver(_ envelope: Data, id: UUID, to recipient: TransportAddress) throws
    /// Stores an attachment blob, readable by everyone who gets a message that names it.
    func putBlob(_ data: Data, id: UUID) throws
    /// `nil` if the blob hasn't arrived (yet).
    func blob(_ id: UUID) throws -> Data?
    /// Envelopes in `address`'s mailbox, oldest first.
    func inbox(for address: TransportAddress) throws -> [InboxItem]
    /// Done with an envelope: processed, or a duplicate.
    func remove(_ id: UUID, for address: TransportAddress) throws
    /// Set aside an envelope that failed its checks. `retryRejected` puts them back.
    func reject(_ id: UUID, for address: TransportAddress) throws
    /// Puts rejected envelopes back in the mailbox, for example after a contact's new key is accepted.
    func retryRejected(for address: TransportAddress) throws
}

public enum TransportError: Error, Equatable, Sendable {
    /// The address isn't one this transport can deliver to.
    case unsupportedAddress(String)
}

/// The section 4 transport: a folder on disk. Simulators on one Mac share it, so two simulators can
/// message each other. Layout: `LoopbackLayout` and docs/WIRE_FORMAT.md. Every file is written to a
/// temporary name and then renamed, so a reader never sees half a file.
public struct LoopbackTransport: Transport {
    public let layout: LoopbackLayout

    public init(root: URL) {
        layout = LoopbackLayout(root: root)
    }

    private var files: FileManager { .default }

    public func deliver(_ envelope: Data, id: UUID, to recipient: TransportAddress) throws {
        guard let mailbox = layout.mailbox(for: recipient), let file = layout.envelopeFile(id, for: recipient) else {
            throw TransportError.unsupportedAddress(recipient.rawValue)
        }
        try files.createDirectory(at: mailbox, withIntermediateDirectories: true)
        try writeAtomically(envelope, to: file)
    }

    public func putBlob(_ data: Data, id: UUID) throws {
        try files.createDirectory(at: layout.blobs, withIntermediateDirectories: true)
        try writeAtomically(data, to: layout.blob(id))
    }

    public func blob(_ id: UUID) throws -> Data? {
        let url = layout.blob(id)
        guard files.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    public func inbox(for address: TransportAddress) throws -> [InboxItem] {
        guard let mailbox = layout.mailbox(for: address) else { throw TransportError.unsupportedAddress(address.rawValue) }
        guard files.fileExists(atPath: mailbox.path) else { return [] }
        let urls = try files.contentsOfDirectory(at: mailbox, includingPropertiesForKeys: [.creationDateKey, .fileSizeKey])
        return try urls.compactMap { url -> (Date, InboxItem)? in
            guard let id = LoopbackLayout.envelopeID(fromFileName: url.lastPathComponent) else { return nil }
            let values = try url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
            // Too large to be an envelope: leave it for `Envelope.decode` to refuse without reading it all.
            let data = (values.fileSize ?? 0) > Envelope.maxBytes ? Data(count: Envelope.maxBytes + 1) : try Data(contentsOf: url)
            return (values.creationDate ?? .distantPast, InboxItem(id: id, data: data))
        }
        .sorted { $0.0 < $1.0 }
        .map(\.1)
    }

    public func remove(_ id: UUID, for address: TransportAddress) throws {
        guard let file = layout.envelopeFile(id, for: address) else { throw TransportError.unsupportedAddress(address.rawValue) }
        try? files.removeItem(at: file)
    }

    public func reject(_ id: UUID, for address: TransportAddress) throws {
        guard let file = layout.envelopeFile(id, for: address), let rejected = layout.rejected(for: address) else {
            throw TransportError.unsupportedAddress(address.rawValue)
        }
        try files.createDirectory(at: rejected, withIntermediateDirectories: true)
        let target = rejected.appendingPathComponent(file.lastPathComponent)
        try? files.removeItem(at: target)
        try files.moveItem(at: file, to: target)
    }

    public func retryRejected(for address: TransportAddress) throws {
        guard let mailbox = layout.mailbox(for: address), let rejected = layout.rejected(for: address),
              files.fileExists(atPath: rejected.path) else { return }
        for url in try files.contentsOfDirectory(at: rejected, includingPropertiesForKeys: nil)
        where LoopbackLayout.envelopeID(fromFileName: url.lastPathComponent) != nil {
            let target = mailbox.appendingPathComponent(url.lastPathComponent)
            if files.fileExists(atPath: target.path) { try files.removeItem(at: url) } else { try files.moveItem(at: url, to: target) }
        }
    }

    private func writeAtomically(_ data: Data, to url: URL) throws {
        try files.createDirectory(at: layout.temporary, withIntermediateDirectories: true)
        let temporary = layout.temporary.appendingPathComponent(UUID().uuidString)
        try data.write(to: temporary)
        do {
            if files.fileExists(atPath: url.path) { try files.removeItem(at: url) }
            try files.moveItem(at: temporary, to: url)
        } catch {
            try? files.removeItem(at: temporary)
            throw error
        }
    }
}
