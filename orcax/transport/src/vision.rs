//! XTLS Vision (`xtls-rprx-vision`) padding protocol — server side.
//!
//! Port of xray-core's `proxy/proxy.go` Vision reader/writer. Vision
//! disguises the first few post-VLESS-header frames as random-length
//! padded TCP segments so a passive on-path observer can't distinguish
//! a VLESS+Reality session from a generic HTTPS connection based on
//! packet sizes. After 8 frames (or when a `PaddingEnd`/`PaddingDirect`
//! marker is seen) both peers switch to raw pass-through.
//!
//! ## Wire format
//!
//! Per frame (first frame from the **client** carries a 16-byte UUID
//! prefix that the server verifies against the authenticated user):
//!
//! ```text
//!   first frame only:  UUID      (16 bytes)
//!   every frame:       cmd       (1 byte)   0x00=continue / 0x01=end / 0x02=direct
//!                      content   (2 bytes, big-endian length)
//!                      padding   (2 bytes, big-endian length)
//!                      body      (content bytes — real VLESS payload)
//!                      padding   (padding bytes — discarded)
//! ```
//!
//! The server emits its own padded frames in the downlink direction,
//! also with a 16-byte UUID prefix on the first one. After
//! `NumberOfPacketToFilter` packets (8 by default) or on an explicit
//! stop command, both sides cut over to unwrapped raw bytes which lets
//! `relay_rustls` / `kTLS+splice` take over the relay.
//!
//! ## What we do NOT implement
//!
//! - **TLS filter / fingerprint detection**. Xray walks the first 8
//!   client packets looking for TLS 1.3 records to decide whether the
//!   upstream can be zero-copy spliced. We always use the safe path
//!   (userspace relay) for Vision sessions — no reflection-based input
//!   buffer access like xray's `UnwrapRawConn`.
//! - **Seed** / PQC additions in the `Addons` protobuf. `Flow` is the
//!   only field we act on.
//! - **MuxAndNotXUDP** downgrading. We already reject mux separately.

use rand::RngCore;

/// Vision command byte values. Values match xray-core's constants
/// exactly — changing any of these breaks wire compatibility.
#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Command {
    /// More padded frames will follow (stay in padding mode).
    PaddingContinue = 0x00,
    /// This is the last padded frame; unwrap subsequent bytes raw.
    PaddingEnd = 0x01,
    /// Same as End, plus the peer signals we can zero-copy splice
    /// (input/rawInput draining). We treat identically to End.
    PaddingDirect = 0x02,
}

impl Command {
    pub fn from_byte(b: u8) -> Option<Self> {
        match b {
            0x00 => Some(Command::PaddingContinue),
            0x01 => Some(Command::PaddingEnd),
            0x02 => Some(Command::PaddingDirect),
            _ => None,
        }
    }
}

/// Max frame size — 2 KiB matches xray's `buf.Size`. Any single
/// Vision content+padding body must fit under this minus the 21-byte
/// overhead (16 UUID + 5 header) for the first frame.
pub const FRAME_MAX: usize = 2048;
const HEADER_OVERHEAD: usize = 21; // 16 UUID + 5 cmd/content/padding bytes

/// Number of outbound packets the writer wraps with random padding
/// before switching to raw pass-through. Matches xray's
/// `NumberOfPacketToFilter` default of 8.
pub const NUMBER_OF_PACKETS_TO_FILTER: u32 = 8;

/// Default padding-length generator params. Matches xray's hardcoded
/// `Testseed = {900, 500, 900, 256}` for VLESS clients.
#[derive(Debug, Clone, Copy)]
pub struct PaddingSeed {
    pub long_threshold: u32,    // content smaller than this is long-padded
    pub long_rand_mod: u32,     // random picked in [0, long_rand_mod)
    pub long_base: u32,         // long_base subtracted from content_len
    pub short_rand_mod: u32,    // short path random in [0, short_rand_mod)
}

impl Default for PaddingSeed {
    fn default() -> Self {
        Self { long_threshold: 900, long_rand_mod: 500, long_base: 900, short_rand_mod: 256 }
    }
}

/// Per-connection Vision state — one side (reader or writer) owns it.
/// Kept internal to this module; callers interact via the `Unpad`
/// state machine and `encode_frame` helper.
#[derive(Debug)]
pub struct UnpadState {
    /// 16-byte VLESS UUID — the first 16 bytes of the client's first
    /// frame must match or the stream is rejected.
    user_uuid: [u8; 16],
    /// `-1` = initial state; otherwise the number of header bytes left
    /// to consume (`5 → cmd → content_hi → content_lo → pad_hi → pad_lo`).
    remaining_command: i32,
    remaining_content: i32,
    remaining_padding: i32,
    /// The most recent command byte we read.
    current_command: u8,
    /// Set once we've seen PaddingEnd/Direct — no more framing, pass
    /// every subsequent byte through.
    done: bool,
    /// Buffer that accumulates the first 16 UUID prefix bytes across
    /// arbitrarily-sized `feed()` calls. rustls can hand us as little
    /// as 1 byte at a time, so UUID validation can't assume the whole
    /// prefix arrives in one call.
    uuid_buf: Vec<u8>,
    /// False until we've validated + consumed the UUID prefix.
    uuid_done: bool,
}

impl UnpadState {
    pub fn new(user_uuid: [u8; 16]) -> Self {
        Self {
            user_uuid,
            remaining_command: -1,
            remaining_content: -1,
            remaining_padding: -1,
            current_command: 0,
            done: false,
            uuid_buf: Vec::with_capacity(16),
            uuid_done: false,
        }
    }

    /// True when the state machine has consumed a `PaddingEnd` or
    /// `PaddingDirect` marker. After this, the caller should bypass
    /// the state machine and splice/copy bytes raw.
    pub fn is_done(&self) -> bool { self.done }

    /// Feed wire bytes in, get unwrapped application bytes out.
    /// Writes unwrapped bytes into `out`. Returns `Ok(())` on success,
    /// `Err(...)` on protocol violation (bad UUID, garbage header).
    ///
    /// A single call may consume all of `wire` without producing any
    /// output (pure padding/header bytes) or may produce multiple
    /// content segments. The caller drives in chunks at its own pace;
    /// UUID bytes, header bytes, and content/padding bytes may all
    /// split across feed calls at arbitrary offsets.
    pub fn feed(&mut self, wire: &[u8], out: &mut Vec<u8>) -> Result<(), UnpadError> {
        let mut i = 0;

        // First 16 bytes of the stream: accumulate UUID bytes until we
        // have all of them, then validate.
        if !self.uuid_done {
            let need = 16 - self.uuid_buf.len();
            let take = need.min(wire.len());
            self.uuid_buf.extend_from_slice(&wire[..take]);
            i += take;
            if self.uuid_buf.len() < 16 {
                // Still need more; return clean.
                return Ok(());
            }
            if self.uuid_buf[..] != self.user_uuid {
                return Err(UnpadError::UuidMismatch);
            }
            self.uuid_done = true;
            self.remaining_command = 5;
        }

        while i < wire.len() {
            // Stream finished — pass remaining bytes through.
            if self.done {
                out.extend_from_slice(&wire[i..]);
                return Ok(());
            }

            if self.remaining_command > 0 {
                let b = wire[i];
                i += 1;
                match self.remaining_command {
                    5 => self.current_command = b,
                    4 => self.remaining_content = (b as i32) << 8,
                    3 => self.remaining_content |= b as i32,
                    2 => self.remaining_padding = (b as i32) << 8,
                    1 => self.remaining_padding |= b as i32,
                    _ => unreachable!(),
                }
                self.remaining_command -= 1;
            } else if self.remaining_content > 0 {
                let available = wire.len() - i;
                let take = (self.remaining_content as usize).min(available);
                out.extend_from_slice(&wire[i..i + take]);
                i += take;
                self.remaining_content -= take as i32;
            } else if self.remaining_padding > 0 {
                let available = wire.len() - i;
                let take = (self.remaining_padding as usize).min(available);
                i += take; // discard
                self.remaining_padding -= take as i32;
            }

            // Frame complete — command byte decides what's next.
            if self.remaining_command == 0
                && self.remaining_content == 0
                && self.remaining_padding == 0
            {
                match Command::from_byte(self.current_command) {
                    Some(Command::PaddingContinue) => {
                        // Reset for next frame.
                        self.remaining_command = 5;
                        self.remaining_content = -1;
                        self.remaining_padding = -1;
                    }
                    Some(Command::PaddingEnd) | Some(Command::PaddingDirect) => {
                        self.done = true;
                        // Anything left in this chunk is raw payload.
                        if i < wire.len() {
                            out.extend_from_slice(&wire[i..]);
                        }
                        return Ok(());
                    }
                    None => {
                        return Err(UnpadError::BadCommand(self.current_command));
                    }
                }
            }
        }
        Ok(())
    }
}

/// Per-connection Vision writer state for the DOWNLINK (server→client).
///
/// Minimal-but-compatible impl: wrap the **first** outgoing buffer in
/// one Vision padded frame carrying the UUID prefix and
/// `PaddingEnd` — this is the absolute minimum needed for clients to
/// accept the session as valid Vision. xray's full writer pads the
/// first N packets and then scans for a TLS ApplicationData record to
/// flip to raw; we skip that because:
///
/// - Our relay downstream is kTLS+splice on the target socket. Adding
///   more than one user-space-padded frame forces us to stay in
///   user-space rustls for longer, hurting throughput.
/// - Clients (Karing, v2rayN, Hiddify) accept a single padded frame
///   ending in `PaddingEnd` — empirically validated against xray's
///   reader state machine.
///
/// If we ever need xray-identical wire behaviour (e.g. JA3/JA4
/// fingerprint parity) come back and pad the first 8 writes instead.
#[derive(Debug)]
pub struct PadState {
    user_uuid: [u8; 16],
    done: bool,
    seed: PaddingSeed,
}

impl PadState {
    pub fn new(user_uuid: [u8; 16]) -> Self {
        Self { user_uuid, done: false, seed: PaddingSeed::default() }
    }

    pub fn is_done(&self) -> bool { self.done }

    /// Wrap `payload` for writing to the client. After the first call
    /// this becomes a no-op — the first frame carries UUID prefix and
    /// a `PaddingEnd` command, and every subsequent write passes
    /// through raw.
    pub fn wrap(&mut self, payload: &[u8]) -> Vec<u8> {
        if self.done {
            return payload.to_vec();
        }
        self.done = true;
        encode_frame(
            payload,
            Command::PaddingEnd,
            true,
            &self.user_uuid,
            true, // long_padding — hides VLESS response size
            self.seed,
        )
    }
}

#[derive(Debug, thiserror::Error)]
pub enum UnpadError {
    #[error("Vision first frame UUID doesn't match authenticated user")]
    UuidMismatch,
    #[error("unknown Vision command byte 0x{0:02x}")]
    BadCommand(u8),
}

/// Encode one Vision padded frame — used by the server writer to wrap
/// outbound data for the first `NUMBER_OF_PACKETS_TO_FILTER` packets.
///
/// `payload` is the real bytes going to the client. If
/// `include_uuid_prefix` is true, this is the first frame and the
/// 16-byte UUID prefix is prepended. `command` tells the client
/// whether more padded frames follow (`PaddingContinue`) or this is
/// the last (`PaddingEnd`/`PaddingDirect`).
///
/// Padding length is picked with crypto-grade randomness — don't
/// replace with a faster PRNG; attackers probing the padded path
/// could learn a pattern.
pub fn encode_frame(
    payload: &[u8],
    command: Command,
    include_uuid_prefix: bool,
    uuid: &[u8; 16],
    long_padding: bool,
    seed: PaddingSeed,
) -> Vec<u8> {
    let mut rng = rand::thread_rng();
    let content_len = payload.len() as i32;
    let mut padding_len: i32 = if (content_len as u32) < seed.long_threshold && long_padding {
        // `rand[0, long_rand_mod) + long_base - content_len`
        let r = (rng.next_u32() % seed.long_rand_mod) as i32;
        r + seed.long_base as i32 - content_len
    } else {
        (rng.next_u32() % seed.short_rand_mod) as i32
    };
    if padding_len < 0 { padding_len = 0; }
    // Cap by max frame size — 21 bytes of header + content + padding
    // must fit under FRAME_MAX.
    let cap = (FRAME_MAX as i32) - (HEADER_OVERHEAD as i32) - content_len;
    if padding_len > cap { padding_len = cap.max(0); }

    let mut out = Vec::with_capacity(
        (if include_uuid_prefix { 16 } else { 0 }) + 5 + content_len as usize + padding_len as usize,
    );
    if include_uuid_prefix {
        out.extend_from_slice(uuid);
    }
    out.push(command as u8);
    out.push((content_len >> 8) as u8);
    out.push(content_len as u8);
    out.push((padding_len >> 8) as u8);
    out.push(padding_len as u8);
    out.extend_from_slice(payload);
    out.resize(out.len() + padding_len as usize, 0);
    // Fill padding with random bytes — xray uses rand-Reader-derived
    // junk. Zeros are indistinguishable encrypted inside TLS; random
    // pads match xray on the wire if someone peeks at a TLS-stripped
    // capture.
    let pad_start = out.len() - padding_len as usize;
    rng.fill_bytes(&mut out[pad_start..]);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    const U: [u8; 16] = [
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10,
    ];

    fn wrap_first_frame(payload: &[u8], cmd: Command) -> Vec<u8> {
        encode_frame(payload, cmd, true, &U, false, PaddingSeed::default())
    }

    #[test]
    fn encode_then_decode_content() {
        let payload = b"hello vision";
        let frame = wrap_first_frame(payload, Command::PaddingEnd);
        let mut state = UnpadState::new(U);
        let mut out = Vec::new();
        state.feed(&frame, &mut out).unwrap();
        assert_eq!(&out, payload);
        assert!(state.is_done());
    }

    #[test]
    fn empty_content_padding_only_frame() {
        let frame = wrap_first_frame(b"", Command::PaddingEnd);
        let mut state = UnpadState::new(U);
        let mut out = Vec::new();
        state.feed(&frame, &mut out).unwrap();
        assert!(out.is_empty());
        assert!(state.is_done());
    }

    #[test]
    fn continue_then_end_frame() {
        let first = encode_frame(b"ABC", Command::PaddingContinue, true, &U, false, PaddingSeed::default());
        let second = encode_frame(b"DEF", Command::PaddingEnd, false, &U, false, PaddingSeed::default());
        let mut state = UnpadState::new(U);
        let mut out = Vec::new();
        state.feed(&first, &mut out).unwrap();
        state.feed(&second, &mut out).unwrap();
        assert_eq!(&out, b"ABCDEF");
        assert!(state.is_done());
    }

    #[test]
    fn raw_bytes_after_end_flow_through() {
        let frame = wrap_first_frame(b"first", Command::PaddingEnd);
        let mut concat = frame.clone();
        concat.extend_from_slice(b"RAW-RAW-RAW"); // post-end bytes
        let mut state = UnpadState::new(U);
        let mut out = Vec::new();
        state.feed(&concat, &mut out).unwrap();
        assert_eq!(&out, b"firstRAW-RAW-RAW");
    }

    #[test]
    fn wrong_uuid_rejected() {
        let frame = wrap_first_frame(b"x", Command::PaddingEnd);
        let bad_uuid = [0xFF; 16];
        let mut state = UnpadState::new(bad_uuid);
        let mut out = Vec::new();
        let err = state.feed(&frame, &mut out).unwrap_err();
        matches!(err, UnpadError::UuidMismatch);
    }

    #[test]
    fn feed_in_byte_sized_chunks() {
        // Simulate the worst-case where rustls hands us one byte at a
        // time — the state machine must survive arbitrary chunking.
        let frame = wrap_first_frame(b"chunky", Command::PaddingEnd);
        let mut state = UnpadState::new(U);
        let mut out = Vec::new();
        for b in &frame {
            state.feed(&[*b], &mut out).unwrap();
        }
        assert_eq!(&out, b"chunky");
        assert!(state.is_done());
    }

    #[test]
    fn bad_command_byte_rejected() {
        // Craft a frame with UUID + cmd=0x42 + content_len=0 + pad_len=0
        let mut frame = U.to_vec();
        frame.extend_from_slice(&[0x42, 0x00, 0x00, 0x00, 0x00]);
        let mut state = UnpadState::new(U);
        let mut out = Vec::new();
        let err = state.feed(&frame, &mut out).unwrap_err();
        assert!(matches!(err, UnpadError::BadCommand(0x42)));
    }

    #[test]
    fn padding_length_honors_frame_cap() {
        // Large payload → cap at FRAME_MAX-21-content
        let big = vec![0u8; 1500];
        let frame = encode_frame(&big, Command::PaddingEnd, true, &U, true, PaddingSeed::default());
        assert!(frame.len() <= FRAME_MAX + 16); // 16 allowed since UUID prefix is separate byte-budget
    }

    #[test]
    fn long_padding_picks_bigger_padding_for_short_content() {
        // Many trials; mean padding size with longPadding=true should
        // be much bigger than short-path.
        let seed = PaddingSeed::default();
        let mut short_sum = 0u64;
        let mut long_sum = 0u64;
        for _ in 0..100 {
            short_sum += encode_frame(b"hi", Command::PaddingContinue, false, &U, false, seed).len() as u64;
            long_sum  += encode_frame(b"hi", Command::PaddingContinue, false, &U, true,  seed).len() as u64;
        }
        assert!(long_sum > short_sum * 2, "long {}, short {}", long_sum, short_sum);
    }

    #[test]
    fn pad_state_round_trips_with_unpad_state() {
        // PadState wraps first write with UUID prefix + PaddingEnd.
        // UnpadState should consume it cleanly and then pass remaining
        // raw bytes through — exactly the handshake OV needs.
        let mut pad = PadState::new(U);
        let mut unpad = UnpadState::new(U);

        // First write: VLESS response header [0, 0]
        let wrapped = pad.wrap(&[0u8, 0u8]);
        let mut out = Vec::new();
        unpad.feed(&wrapped, &mut out).unwrap();
        assert_eq!(&out, &[0u8, 0u8]);
        assert!(unpad.is_done());
        assert!(pad.is_done());

        // Subsequent writes are raw; unpad-state forwards raw in done state
        out.clear();
        let raw = pad.wrap(b"hello world");
        assert_eq!(&raw, b"hello world"); // passed through
        unpad.feed(&raw, &mut out).unwrap();
        assert_eq!(&out, b"hello world");
    }

    #[test]
    fn multi_continue_frames_then_end() {
        let mut state = UnpadState::new(U);
        let mut out = Vec::new();
        let f1 = encode_frame(b"a", Command::PaddingContinue, true, &U, false, PaddingSeed::default());
        let f2 = encode_frame(b"b", Command::PaddingContinue, false, &U, false, PaddingSeed::default());
        let f3 = encode_frame(b"c", Command::PaddingContinue, false, &U, false, PaddingSeed::default());
        let f4 = encode_frame(b"d", Command::PaddingEnd, false, &U, false, PaddingSeed::default());
        for f in [&f1, &f2, &f3, &f4] {
            state.feed(f, &mut out).unwrap();
        }
        assert_eq!(&out, b"abcd");
        assert!(state.is_done());
    }
}
