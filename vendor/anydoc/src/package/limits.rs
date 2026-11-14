//! Fixed safety limits, applied identically to every conversion.
//!
//! These are hard caps against attack/abuse input shapes (decompression
//! bombs, pathological nesting, runaway expansion) - crossing one returns
//! [`ConvertError::ResourceLimit`](crate::ConvertError::ResourceLimit),
//! always. They are deliberately not configurable: real-world documents sit
//! below these limits in the supported desktop workload.

/// Maximum decompressed size of a single archive entry: 16 MiB.
pub const MAX_ENTRY_BYTES: u64 = 16 * 1024 * 1024;

/// Maximum total decompressed bytes read from one archive: 48 MiB.
pub const MAX_TOTAL_BYTES: u64 = 48 * 1024 * 1024;

/// Maximum number of entries in one archive.
pub const MAX_ENTRY_COUNT: usize = 4096;

/// Maximum XML element nesting depth.
pub const MAX_XML_DEPTH: usize = 256;

/// Maximum number of XML nodes (elements + text runs) in one part. Sized
/// from the measured worst-case DOM cost (~400 bytes/node, see the node-cap
/// memory test) so a saturating part stays around the archive budget.
pub const MAX_XML_NODES: usize = 120_000;

/// Maximum grid positions one spreadsheet table may materialize: 100 thousand.
pub const MAX_GRID_SLOTS: u64 = 100_000;

/// Maximum content-bearing cells a repeat expansion may produce per table.
pub const MAX_EXPANSION: u64 = 100_000;

/// Maximum total text bytes *duplicated* by repeat expansion per document:
/// 16 MiB. The slot budget above bounds positions; this bounds the memory a
/// small document can amplify by repeating content-bearing cells.
pub const MAX_EXPANSION_TEXT_BYTES: u64 = 16 * 1024 * 1024;

/// Maximum total bytes of embedded assets retained in a `Document`: 16 MiB.
pub const MAX_ASSET_TOTAL_BYTES: usize = 16 * 1024 * 1024;

/// Maximum nesting depth of binary record containers (legacy PPT stream).
pub const MAX_RECORD_DEPTH: usize = 64;

/// Maximum total binary records visited in one legacy record stream.
pub const MAX_RECORDS: u64 = 16_000_000;
