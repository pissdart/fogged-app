//! VLESS request/response **Addons** (protobuf wire format).
//!
//! Xray-core's `proxy/vless/encoding/addons.proto` defines:
//! ```proto
//! message Addons {
//!     string Flow = 1;   // wire type 2 (length-delimited)
//!     bytes  Seed = 2;   // wire type 2 (length-delimited)
//! }
//! ```
//!
//! We only care about `Flow` on the server side — detecting
//! `"xtls-rprx-vision"` flips the post-header I/O path to use
//! `orcax_transport::vision::{VisionReader, VisionWriter}`. Everything
//! else is ignored.
//!
//! Wire format for `flow="xtls-rprx-vision"` (16 chars):
//! ```text
//!   0x0A   field 1, wire type 2 (Flow)
//!   0x10   length = 16
//!   "xtls-rprx-vision"   (16 bytes, UTF-8)
//! ```
//! Total: 18 bytes. `DecodeHeaderAddons` prepends a 1-byte length
//! prefix → the server reads `[addon_len:u8]` then `addon_len` bytes
//! of protobuf.
//!
//! This parser is deliberately minimal: it scans for the `Flow` field
//! tag and extracts the string, tolerating (a) the field appearing at
//! any position, (b) other unknown fields being skipped. Anything it
//! can't parse returns `Addons::default()` — the caller treats that
//! identically to "no Vision".

/// Parsed VLESS request addons. Only the fields OV actually uses.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Addons {
    /// `Flow` field. `"xtls-rprx-vision"` is the one value we act on;
    /// `"xtls-rprx-vision-udp443"` behaves identically for TCP.
    pub flow: String,
}

impl Addons {
    /// True when the client negotiated Vision flow on this VLESS stream.
    pub fn is_vision(&self) -> bool {
        self.flow == "xtls-rprx-vision" || self.flow == "xtls-rprx-vision-udp443"
    }

    /// Parse a protobuf-encoded `Addons` message. `data` is exactly the
    /// `addon_len` bytes the VLESS header told us to read (never
    /// includes the leading length prefix).
    pub fn parse(data: &[u8]) -> Self {
        let mut out = Addons::default();
        let mut i = 0;
        while i < data.len() {
            // Protobuf tag: (field_number << 3) | wire_type.
            // Technically a varint; field numbers 1 and 2 both fit in
            // one byte so we don't implement full varint decoding here.
            let tag = data[i];
            i += 1;
            let field = tag >> 3;
            let wire = tag & 0x07;
            match (field, wire) {
                // Flow (field 1) / Seed (field 2), both wire type 2
                // (length-delimited). Read varint length, then bytes.
                (1, 2) | (2, 2) => {
                    let Some((len, consumed)) = read_varint(&data[i..]) else { break };
                    i += consumed;
                    let end = i.saturating_add(len as usize);
                    if end > data.len() { break; }
                    if field == 1 {
                        if let Ok(s) = std::str::from_utf8(&data[i..end]) {
                            out.flow = s.to_string();
                        }
                    }
                    // Seed (field 2) intentionally ignored.
                    i = end;
                }
                // Unknown field — skip safely for forward-compat.
                (_, 0) => {
                    // varint value
                    let Some((_, consumed)) = read_varint(&data[i..]) else { break };
                    i += consumed;
                }
                (_, 2) => {
                    let Some((len, consumed)) = read_varint(&data[i..]) else { break };
                    i += consumed;
                    let end = i.saturating_add(len as usize);
                    if end > data.len() { break; }
                    i = end;
                }
                // wire types 1 (64-bit), 5 (32-bit), others — we don't
                // expect these in Addons; bail.
                _ => break,
            }
        }
        out
    }
}

/// Decode a base128-varint from the start of `data`. Returns
/// `(value, bytes_consumed)` on success. Caps at 10 bytes per
/// protobuf spec.
fn read_varint(data: &[u8]) -> Option<(u64, usize)> {
    let mut val: u64 = 0;
    let mut shift: u32 = 0;
    for (i, &b) in data.iter().take(10).enumerate() {
        val |= ((b & 0x7F) as u64) << shift;
        if b & 0x80 == 0 {
            return Some((val, i + 1));
        }
        shift += 7;
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_vision_flow() {
        // 0x0A = tag (field=1, wire=2). 0x10 = length 16. Then the
        // literal ASCII string.
        let mut data = vec![0x0A, 0x10];
        data.extend_from_slice(b"xtls-rprx-vision");
        let a = Addons::parse(&data);
        assert_eq!(a.flow, "xtls-rprx-vision");
        assert!(a.is_vision());
    }

    #[test]
    fn parse_vision_with_seed_field() {
        // Flow + Seed: protobuf field order is insignificant, parser
        // must tolerate either ordering.
        let mut data = vec![0x0A, 0x10];
        data.extend_from_slice(b"xtls-rprx-vision");
        data.extend_from_slice(&[0x12, 0x04, 0xDE, 0xAD, 0xBE, 0xEF]); // Seed=0xDEADBEEF
        let a = Addons::parse(&data);
        assert_eq!(a.flow, "xtls-rprx-vision");
    }

    #[test]
    fn empty_addons_is_not_vision() {
        let a = Addons::parse(&[]);
        assert_eq!(a.flow, "");
        assert!(!a.is_vision());
    }

    #[test]
    fn unknown_field_skipped() {
        // Field 99 with wire type 2 — should be gracefully skipped.
        let mut data = vec![(99 << 3) | 2, 0x03, 0xAA, 0xBB, 0xCC];
        data.extend_from_slice(&[0x0A, 0x0D]);
        data.extend_from_slice(b"custom-flow-x");
        let a = Addons::parse(&data);
        assert_eq!(a.flow, "custom-flow-x");
    }

    #[test]
    fn vision_udp443_also_recognized() {
        // "xtls-rprx-vision-udp443" = 23 chars = 0x17
        let mut data = vec![0x0A, 0x17];
        data.extend_from_slice(b"xtls-rprx-vision-udp443");
        let a = Addons::parse(&data);
        assert!(a.is_vision());
    }

    #[test]
    fn malformed_truncated_length_returns_partial() {
        // Length says 100 bytes but only 3 follow. Should not panic.
        let data = vec![0x0A, 0x64, 0x01, 0x02, 0x03];
        let a = Addons::parse(&data);
        assert_eq!(a.flow, ""); // bailed before populating
    }

    #[test]
    fn varint_single_byte() {
        let (v, c) = read_varint(&[0x05]).unwrap();
        assert_eq!(v, 5);
        assert_eq!(c, 1);
    }

    #[test]
    fn varint_two_bytes() {
        // 300 = 0b100101100 → 0xAC 0x02
        let (v, c) = read_varint(&[0xAC, 0x02]).unwrap();
        assert_eq!(v, 300);
        assert_eq!(c, 2);
    }
}
