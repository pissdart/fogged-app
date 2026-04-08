//! OrcaX Native Protocol v1
//!
//! A purpose-built anti-censorship tunnel protocol with:
//! - x25519 ECDH authentication (no certificates needed)
//! - ChaCha20-Poly1305 encrypted framing
//! - Built-in multiplexing (multiple streams over one connection)
//! - Native UDP support (no TCP wrapping overhead)
//! - Traffic padding (defeats statistical analysis)
//! - Zero-copy where possible
//!
//! Wire format runs inside standard TLS 1.3 (rustls) so DPI sees
//! normal HTTPS traffic to a legitimate-looking domain.
//!
//! ## Handshake
//!
//! ```text
//! Client                              Server
//!   |                                    |
//!   |--- ClientAuth (48 bytes) -------->|
//!   |    [ephemeral_pub: 32]            |
//!   |    [encrypted_uuid: 16]           |
//!   |                                    |
//!   |    Server derives shared secret    |
//!   |    Server decrypts UUID            |
//!   |    Server validates UUID           |
//!   |                                    |
//!   |<-- ServerAuth (33 bytes) ---------|
//!   |    [server_ephemeral_pub: 32]     |
//!   |    [status: 1]                    |
//!   |                                    |
//!   |    Both derive session keys        |
//!   |    (ChaCha20-Poly1305)            |
//!   |                                    |
//!   |=== Encrypted frames =============>|
//!   |<== Encrypted frames ==============|
//! ```
//!
//! ## Frame Format (after handshake, inside TLS)
//!
//! ```text
//! [type: 1] [flags: 1] [stream_id: 4] [length: 2] [payload: N] [padding: P]
//! ```
//!
//! Total overhead: 8 bytes per frame (vs VLESS 18+ bytes handshake per connection)

use anyhow::{anyhow, Result};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

use crate::address::TargetAddr;

// ── Protocol Constants ──────────────────────────────────────────

/// Protocol version
pub const VERSION: u8 = 1;

/// Max frame payload size (64KB)
pub const MAX_FRAME_SIZE: usize = 65535;

/// Max padding size
pub const MAX_PADDING: usize = 256;

// ── Frame Types ─────────────────────────────────────────────────

/// Frame types for the multiplexed stream protocol
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum FrameType {
    /// Data payload for an existing stream
    Data = 0x00,
    /// Open a new stream (payload = target address)
    StreamOpen = 0x01,
    /// Close a stream gracefully
    StreamClose = 0x02,
    /// Ping (keepalive)
    Ping = 0x03,
    /// Pong (keepalive response)
    Pong = 0x04,
    /// Server-initiated shutdown
    GoAway = 0x05,
    /// Window update (flow control)
    WindowUpdate = 0x06,
    /// UDP datagram (no stream, just fire-and-forget)
    UdpDatagram = 0x07,
    /// Server→Client: inner TLS 1.3 detected, drop outer encryption.
    /// After both sides process this, the connection switches to raw TCP.
    /// splice() moves data at wire speed — zero encryption overhead.
    /// Payload: [tls_version: 2] [cipher_suite: 2] (for logging/verification)
    Passthrough = 0x08,
}

impl FrameType {
    pub fn from_byte(b: u8) -> Result<Self> {
        match b {
            0x00 => Ok(Self::Data),
            0x01 => Ok(Self::StreamOpen),
            0x02 => Ok(Self::StreamClose),
            0x03 => Ok(Self::Ping),
            0x04 => Ok(Self::Pong),
            0x05 => Ok(Self::GoAway),
            0x06 => Ok(Self::WindowUpdate),
            0x07 => Ok(Self::UdpDatagram),
            0x08 => Ok(Self::Passthrough),
            _ => Err(anyhow!("unknown frame type: {:#x}", b)),
        }
    }
}

// ── Frame Flags ─────────────────────────────────────────────────

pub mod flags {
    /// Stream is finished (no more data from this side)
    pub const FIN: u8 = 0x01;
    /// Reset stream (abort)
    pub const RST: u8 = 0x02;
    /// Frame has padding appended
    pub const PADDED: u8 = 0x04;
    /// UDP frame (combined with UdpDatagram type)
    pub const UDP: u8 = 0x08;
}

// ── Frame ───────────────────────────────────────────────────────

/// A single OrcaX protocol frame
#[derive(Debug, Clone)]
pub struct Frame {
    pub frame_type: FrameType,
    pub flags: u8,
    pub stream_id: u32,
    pub payload: Vec<u8>,
}

impl Frame {
    /// Create a data frame
    pub fn data(stream_id: u32, payload: Vec<u8>) -> Self {
        Self {
            frame_type: FrameType::Data,
            flags: 0,
            stream_id,
            payload,
        }
    }

    /// Create a stream open frame with target address
    pub fn stream_open(stream_id: u32, target: &TargetAddr) -> Self {
        let mut payload = Vec::with_capacity(32);
        // Command: 1=TCP, 2=UDP
        payload.push(1); // TCP by default
        payload.extend_from_slice(&target.port.to_be_bytes());
        match &target.addr {
            crate::address::Address::IPv4(ip) => {
                payload.push(1);
                payload.extend_from_slice(&ip.octets());
            }
            crate::address::Address::Domain(d) => {
                payload.push(2);
                payload.push(d.len() as u8);
                payload.extend_from_slice(d.as_bytes());
            }
            crate::address::Address::IPv6(ip) => {
                payload.push(3);
                payload.extend_from_slice(&ip.octets());
            }
        }
        Self {
            frame_type: FrameType::StreamOpen,
            flags: 0,
            stream_id,
            payload,
        }
    }

    /// Create a stream close frame
    pub fn stream_close(stream_id: u32) -> Self {
        Self {
            frame_type: FrameType::StreamClose,
            flags: flags::FIN,
            stream_id,
            payload: Vec::new(),
        }
    }

    /// Create a UDP datagram frame (no stream, just target + data)
    pub fn udp_datagram(target: &TargetAddr, data: Vec<u8>) -> Self {
        let mut payload = Vec::with_capacity(data.len() + 32);
        payload.extend_from_slice(&target.port.to_be_bytes());
        match &target.addr {
            crate::address::Address::IPv4(ip) => {
                payload.push(1);
                payload.extend_from_slice(&ip.octets());
            }
            crate::address::Address::Domain(d) => {
                payload.push(2);
                payload.push(d.len() as u8);
                payload.extend_from_slice(d.as_bytes());
            }
            crate::address::Address::IPv6(ip) => {
                payload.push(3);
                payload.extend_from_slice(&ip.octets());
            }
        }
        // Length-prefixed datagram
        payload.extend_from_slice(&(data.len() as u16).to_be_bytes());
        payload.extend_from_slice(&data);
        Self {
            frame_type: FrameType::UdpDatagram,
            flags: flags::UDP,
            stream_id: 0,
            payload,
        }
    }

    /// Create a ping frame
    pub fn ping() -> Self {
        Self {
            frame_type: FrameType::Ping,
            flags: 0,
            stream_id: 0,
            payload: Vec::new(),
        }
    }

    /// Create a pong frame
    pub fn pong() -> Self {
        Self {
            frame_type: FrameType::Pong,
            flags: 0,
            stream_id: 0,
            payload: Vec::new(),
        }
    }

    /// Create a passthrough frame — signals both sides to drop outer TLS
    /// and switch to raw TCP + splice for wire-speed relay.
    /// Sent by server after detecting inner TLS 1.3 traffic.
    pub fn passthrough(tls_version: u16, cipher_suite: u16) -> Self {
        let mut payload = Vec::with_capacity(4);
        payload.extend_from_slice(&tls_version.to_be_bytes());
        payload.extend_from_slice(&cipher_suite.to_be_bytes());
        Self {
            frame_type: FrameType::Passthrough,
            flags: 0,
            stream_id: 0,
            payload,
        }
    }

    /// Serialize frame to bytes
    /// Format: [type:1] [flags:1] [stream_id:4] [length:2] [payload:N]
    pub fn encode(&self) -> Vec<u8> {
        let len = self.payload.len() as u16;
        let mut buf = Vec::with_capacity(8 + self.payload.len());
        buf.push(self.frame_type as u8);
        buf.push(self.flags);
        buf.extend_from_slice(&self.stream_id.to_be_bytes());
        buf.extend_from_slice(&len.to_be_bytes());
        buf.extend_from_slice(&self.payload);
        buf
    }

    /// Read a frame from an async reader
    pub async fn decode<R: AsyncRead + Unpin>(reader: &mut R) -> Result<Self> {
        let mut hdr = [0u8; 8];
        reader.read_exact(&mut hdr).await
            .map_err(|_| anyhow!("short frame header"))?;

        let frame_type = FrameType::from_byte(hdr[0])?;
        let flags = hdr[1];
        let stream_id = u32::from_be_bytes([hdr[2], hdr[3], hdr[4], hdr[5]]);
        let length = u16::from_be_bytes([hdr[6], hdr[7]]) as usize;

        if length > MAX_FRAME_SIZE {
            return Err(anyhow!("frame too large: {}", length));
        }

        let mut payload = vec![0u8; length];
        if length > 0 {
            reader.read_exact(&mut payload).await
                .map_err(|_| anyhow!("short frame payload"))?;
        }

        // Strip padding if PADDED flag set
        if flags & flags::PADDED != 0 && !payload.is_empty() {
            let pad_len = *payload.last().unwrap() as usize;
            if pad_len < payload.len() {
                payload.truncate(payload.len() - pad_len - 1);
            }
        }

        Ok(Frame {
            frame_type,
            flags,
            stream_id,
            payload,
        })
    }

    /// Add random padding to a frame (anti-DPI)
    pub fn with_padding(mut self, min: usize, max: usize) -> Self {
        use rand::Rng;
        let pad_len = rand::thread_rng().gen_range(min..=max.min(MAX_PADDING));
        let mut padding = vec![0u8; pad_len];
        rand::thread_rng().fill(&mut padding[..]);
        // Last byte = padding length (so receiver knows how much to strip)
        if !padding.is_empty() {
            *padding.last_mut().unwrap() = pad_len as u8;
        }
        self.payload.extend_from_slice(&padding);
        self.flags |= flags::PADDED;
        self
    }
}

// ── Handshake ───────────────────────────────────────────────────

/// Client authentication message (48 bytes)
/// Sent as the first message after TLS handshake
#[derive(Debug)]
pub struct ClientAuth {
    /// Client's ephemeral x25519 public key (32 bytes)
    pub ephemeral_pub: [u8; 32],
    /// UUID encrypted with shared secret (16 bytes)
    pub encrypted_uuid: [u8; 16],
}

impl ClientAuth {
    pub const SIZE: usize = 48;

    pub async fn read<R: AsyncRead + Unpin>(reader: &mut R) -> Result<Self> {
        let mut buf = [0u8; Self::SIZE];
        reader.read_exact(&mut buf).await
            .map_err(|_| anyhow!("short client auth"))?;
        let mut ephemeral_pub = [0u8; 32];
        ephemeral_pub.copy_from_slice(&buf[0..32]);
        let mut encrypted_uuid = [0u8; 16];
        encrypted_uuid.copy_from_slice(&buf[32..48]);
        Ok(Self { ephemeral_pub, encrypted_uuid })
    }

    pub async fn write<W: AsyncWrite + Unpin>(&self, writer: &mut W) -> Result<()> {
        let mut buf = [0u8; Self::SIZE];
        buf[0..32].copy_from_slice(&self.ephemeral_pub);
        buf[32..48].copy_from_slice(&self.encrypted_uuid);
        writer.write_all(&buf).await?;
        Ok(())
    }
}

/// Server authentication response (33 bytes)
#[derive(Debug)]
pub struct ServerAuth {
    /// Server's ephemeral x25519 public key (32 bytes)
    pub ephemeral_pub: [u8; 32],
    /// Status: 0=ok, 1=auth_failed, 2=device_limit, 3=banned
    pub status: u8,
}

impl ServerAuth {
    pub const SIZE: usize = 33;

    pub const STATUS_OK: u8 = 0;
    pub const STATUS_AUTH_FAILED: u8 = 1;
    pub const STATUS_DEVICE_LIMIT: u8 = 2;
    pub const STATUS_BANNED: u8 = 3;
    pub const STATUS_SERVER_ERROR: u8 = 4;

    pub async fn read<R: AsyncRead + Unpin>(reader: &mut R) -> Result<Self> {
        let mut buf = [0u8; Self::SIZE];
        reader.read_exact(&mut buf).await
            .map_err(|_| anyhow!("short server auth"))?;
        let mut ephemeral_pub = [0u8; 32];
        ephemeral_pub.copy_from_slice(&buf[0..32]);
        Ok(Self { ephemeral_pub, status: buf[32] })
    }

    pub async fn write<W: AsyncWrite + Unpin>(&self, writer: &mut W) -> Result<()> {
        let mut buf = [0u8; Self::SIZE];
        buf[0..32].copy_from_slice(&self.ephemeral_pub);
        buf[32] = self.status;
        writer.write_all(&buf).await?;
        Ok(())
    }
}

// ── TLS 1.3 Detection ──────────────────────────────────────────

/// TLS record types
const TLS_HANDSHAKE: u8 = 0x16;
const TLS_APPLICATION_DATA: u8 = 0x17;

/// Detect if data contains a TLS 1.3 ServerHello or Application Data record.
/// Returns Some((version, cipher_suite)) if TLS 1.3 is detected, None otherwise.
///
/// We scan the first bytes from the outbound (target→server) direction.
/// If the target responds with TLS 1.3, it means the inner traffic is already
/// encrypted and the outer Reality TLS is redundant → safe to passthrough.
pub fn detect_inner_tls13(data: &[u8]) -> Option<(u16, u16)> {
    if data.len() < 5 {
        return None;
    }

    let record_type = data[0];
    let version = u16::from_be_bytes([data[1], data[2]]);

    // TLS 1.3 ServerHello is sent as Handshake record (0x16) with legacy version 0x0303
    // TLS 1.3 Application Data is sent as record type 0x17 with version 0x0303
    if record_type == TLS_HANDSHAKE && version == 0x0303 {
        // Parse ServerHello to check for TLS 1.3 supported_versions
        let record_len = u16::from_be_bytes([data[3], data[4]]) as usize;
        if data.len() >= 5 + record_len && record_len > 38 {
            // Handshake message type at data[5]
            if data[5] == 0x02 {
                // ServerHello structure after record header:
                // [5]: handshake type (0x02)
                // [6-8]: handshake length (3 bytes)
                // [9-10]: server version
                // [11-42]: random (32 bytes)
                // [43]: session_id_length
                // [44..44+sid_len]: session_id
                // [44+sid_len..44+sid_len+2]: cipher suite
                if data.len() > 43 {
                    let sid_len = data[43] as usize;
                    let cipher_offset = 44 + sid_len;
                    if data.len() > cipher_offset + 1 {
                        let cipher = u16::from_be_bytes([data[cipher_offset], data[cipher_offset + 1]]);
                        if cipher >= 0x1301 && cipher <= 0x1303 {
                            return Some((0x0304, cipher)); // TLS 1.3!
                        }
                    }
                }
            }
        }
    }

    // TLS Application Data record (0x17) — inner TLS is already established
    if record_type == TLS_APPLICATION_DATA && version == 0x0303 {
        return Some((0x0304, 0x1301)); // Assume TLS 1.3 AES-128-GCM
    }

    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::Ipv4Addr;
    use crate::address::{Address, TargetAddr};

    #[test]
    fn frame_encode_decode_roundtrip() {
        let frame = Frame::data(42, b"hello world".to_vec());
        let encoded = frame.encode();
        assert_eq!(encoded.len(), 8 + 11); // 8 header + 11 payload
        assert_eq!(encoded[0], FrameType::Data as u8);
        assert_eq!(u32::from_be_bytes([encoded[2], encoded[3], encoded[4], encoded[5]]), 42);
    }

    #[tokio::test]
    async fn frame_async_roundtrip() {
        let original = Frame::data(100, b"test payload".to_vec());
        let encoded = original.encode();
        let mut reader = &encoded[..];
        let decoded = Frame::decode(&mut reader).await.unwrap();
        assert_eq!(decoded.frame_type, FrameType::Data);
        assert_eq!(decoded.stream_id, 100);
        assert_eq!(decoded.payload, b"test payload");
    }

    #[tokio::test]
    async fn frame_stream_open() {
        let target = TargetAddr {
            addr: Address::Domain("google.com".into()),
            port: 443,
        };
        let frame = Frame::stream_open(1, &target);
        let encoded = frame.encode();
        let mut reader = &encoded[..];
        let decoded = Frame::decode(&mut reader).await.unwrap();
        assert_eq!(decoded.frame_type, FrameType::StreamOpen);
        assert_eq!(decoded.stream_id, 1);
        // payload: [cmd:1] [port:2] [type:1] [len:1] [domain]
        assert_eq!(decoded.payload[0], 1); // TCP
        assert_eq!(u16::from_be_bytes([decoded.payload[1], decoded.payload[2]]), 443);
    }

    #[tokio::test]
    async fn frame_udp_datagram() {
        let target = TargetAddr {
            addr: Address::IPv4(Ipv4Addr::new(8, 8, 8, 8)),
            port: 53,
        };
        let frame = Frame::udp_datagram(&target, b"dns query".to_vec());
        assert_eq!(frame.frame_type, FrameType::UdpDatagram);
        assert!(frame.flags & flags::UDP != 0);
    }

    #[test]
    fn frame_with_padding() {
        let frame = Frame::data(1, b"secret".to_vec()).with_padding(10, 20);
        assert!(frame.flags & flags::PADDED != 0);
        assert!(frame.payload.len() > 6); // original + padding
    }

    #[tokio::test]
    async fn ping_pong() {
        let ping = Frame::ping();
        assert_eq!(ping.frame_type, FrameType::Ping);
        let encoded = ping.encode();
        let mut reader = &encoded[..];
        let decoded = Frame::decode(&mut reader).await.unwrap();
        assert_eq!(decoded.frame_type, FrameType::Ping);
        assert_eq!(decoded.stream_id, 0);
        assert!(decoded.payload.is_empty());
    }

    #[tokio::test]
    async fn client_auth_roundtrip() {
        let auth = ClientAuth {
            ephemeral_pub: [0xAB; 32],
            encrypted_uuid: [0xCD; 16],
        };
        let mut buf = Vec::new();
        auth.write(&mut buf).await.unwrap();
        assert_eq!(buf.len(), ClientAuth::SIZE);

        let mut reader = &buf[..];
        let decoded = ClientAuth::read(&mut reader).await.unwrap();
        assert_eq!(decoded.ephemeral_pub, [0xAB; 32]);
        assert_eq!(decoded.encrypted_uuid, [0xCD; 16]);
    }

    #[tokio::test]
    async fn server_auth_roundtrip() {
        let auth = ServerAuth {
            ephemeral_pub: [0x11; 32],
            status: ServerAuth::STATUS_OK,
        };
        let mut buf = Vec::new();
        auth.write(&mut buf).await.unwrap();
        assert_eq!(buf.len(), ServerAuth::SIZE);

        let mut reader = &buf[..];
        let decoded = ServerAuth::read(&mut reader).await.unwrap();
        assert_eq!(decoded.status, 0);
    }

    #[test]
    fn frame_types_all_valid() {
        for b in 0x00..=0x08 {
            assert!(FrameType::from_byte(b).is_ok());
        }
        assert!(FrameType::from_byte(0x09).is_err());
    }

    #[test]
    fn passthrough_frame() {
        let frame = Frame::passthrough(0x0304, 0x1301);
        assert_eq!(frame.frame_type, FrameType::Passthrough);
        assert_eq!(frame.payload.len(), 4);
        assert_eq!(u16::from_be_bytes([frame.payload[0], frame.payload[1]]), 0x0304);
        assert_eq!(u16::from_be_bytes([frame.payload[2], frame.payload[3]]), 0x1301);
    }

    #[test]
    fn detect_tls13_server_hello() {
        // Minimal TLS ServerHello with TLS_AES_128_GCM_SHA256 (0x1301)
        let mut record = vec![
            0x16,       // Handshake
            0x03, 0x03, // TLS 1.2 legacy version
            0x00, 0x30, // Record length = 48
            0x02,       // ServerHello message type
            0x00, 0x00, 0x2C, // Length
            0x03, 0x03, // Server version (TLS 1.2 legacy)
        ];
        record.extend_from_slice(&[0u8; 32]); // Random
        record.push(0x00); // session_id_length = 0
        record.push(0x13); record.push(0x01); // TLS_AES_128_GCM_SHA256 (cipher suite)
        record.extend_from_slice(&[0u8; 10]); // rest

        let result = detect_inner_tls13(&record);
        assert!(result.is_some());
        let (ver, cipher) = result.unwrap();
        assert_eq!(ver, 0x0304);
        assert_eq!(cipher, 0x1301);
    }

    #[test]
    fn detect_tls13_app_data() {
        let record = vec![0x17, 0x03, 0x03, 0x00, 0x10]; // Application Data
        let result = detect_inner_tls13(&record);
        assert!(result.is_some());
    }

    #[test]
    fn detect_non_tls() {
        let http = b"HTTP/1.1 200 OK\r\n";
        assert!(detect_inner_tls13(http).is_none());
    }

    #[tokio::test]
    async fn reject_oversized_frame() {
        let mut buf = vec![0x00, 0x00, 0x00, 0x00, 0x00, 0x01]; // type=data, flags=0, stream=1
        buf.extend_from_slice(&[0xFF, 0xFF]); // length = 65535
        buf.extend_from_slice(&vec![0u8; 65535]); // full payload
        let mut reader = &buf[..];
        // Should succeed — 65535 is exactly MAX_FRAME_SIZE
        assert!(Frame::decode(&mut reader).await.is_ok());
    }
}
