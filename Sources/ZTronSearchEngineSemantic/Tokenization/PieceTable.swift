import Foundation

/// A vocabulary: maps the UTF-8 bytes of a piece to its id.
///
/// Multilingual vocabularies hold 250,000 pieces, and a dictionary of strings would cost one
/// allocation per piece plus the hashing of a freshly built `String` on every lookup. The table
/// keeps every piece in one byte blob and looks slices of the input up directly, by open
/// addressing: about 6 MB for 250,000 pieces and no allocation per lookup.
struct PieceTable: Sendable {
    private var blob: [UInt8] = []
    /// Start of each entry in the blob; one more element than there are entries.
    private var starts: [UInt32] = [0]
    private var ids: [Int32] = []
    /// Entry index per slot, or -1.
    private var slots: [Int32] = []
    private var mask = 0
    /// The longest piece, in bytes: lookups never need to try longer slices.
    private(set) var longestPiece = 0

    /// - Parameter entries: Pieces and their ids. When a piece appears twice its first id wins;
    ///   empty pieces are skipped.
    init(_ entries: [(piece: String, id: Int32)]) {
        self.init(capacity: entries.count)
        for entry in entries {
            var piece = entry.piece
            piece.withUTF8 { insert($0, id: entry.id) }
        }
    }

    /// An empty table with room for `capacity` pieces.
    init(capacity: Int) {
        var slotCount = 16
        while slotCount < capacity * 2 { slotCount <<= 1 }
        slots = [Int32](repeating: -1, count: slotCount)
        mask = slotCount - 1
        ids.reserveCapacity(capacity)
        starts.reserveCapacity(capacity + 1)
    }

    /// Adds the piece spelled by `bytes`. An empty piece, or one the table already holds, is
    /// skipped. The table must have been created with room for it.
    mutating func insert(_ bytes: UnsafeBufferPointer<UInt8>, id: Int32) {
        guard bytes.count > 0, ids.count * 2 < slots.count else { return }
        let probe = slot(of: bytes)
        guard probe.entry == nil else { return }
        slots[probe.slot] = Int32(ids.count)
        blob.append(contentsOf: bytes)
        starts.append(UInt32(blob.count))
        ids.append(id)
        longestPiece = max(longestPiece, bytes.count)
    }

    var count: Int { ids.count }

    /// The id of the piece spelled by `bytes`.
    func id(of bytes: UnsafeBufferPointer<UInt8>) -> Int32? {
        guard bytes.count > 0, bytes.count <= longestPiece else { return nil }
        return slot(of: bytes).entry.map { ids[Int($0)] }
    }

    func id(of piece: String) -> Int32? {
        var copy = piece
        return copy.withUTF8 { id(of: $0) }
    }

    /// The slot `bytes` hashes to after probing, and the entry stored there if it is `bytes`.
    private func slot(of bytes: UnsafeBufferPointer<UInt8>) -> (slot: Int, entry: Int32?) {
        // FNV-1a.
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in bytes {
            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01B3
        }
        var slot = Int(truncatingIfNeeded: hash ^ (hash >> 32)) & mask
        while true {
            let entry = slots[slot]
            if entry < 0 { return (slot, nil) }
            let start = Int(starts[Int(entry)])
            let end = Int(starts[Int(entry) + 1])
            if end - start == bytes.count {
                let isSame = blob.withUnsafeBufferPointer { stored in
                    memcmp(stored.baseAddress.unsafelyUnwrapped + start, bytes.baseAddress, bytes.count) == 0
                }
                if isSame { return (slot, entry) }
            }
            slot = (slot + 1) & mask
        }
    }
}
