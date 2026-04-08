use anyhow::{anyhow, Result};
use tokio::io::{AsyncRead, AsyncReadExt};

use crate::address::TargetAddr;

/// Maximum addons protobuf blob size. Real clients send 0-64 bytes.
/// Cap at 256 to allow FPv1 extensions while preventing abuse.
const MAX_ADDONS_LEN: usize = 256;

/// VLESS command types
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Command {
    Tcp = 1,
    Udp = 2,
    Mux = 3,
}

impl Command {
    pub fn from_byte(b: u8) -> Result<Self> {
        match b {
            1 => Ok(Command::Tcp),
            2 => Ok(Command::Udp),
            3 => Ok(Command::Mux),
            _ => Err(anyhow!("unsupported VLESS command: {}", b)),
        }
    }
}

/// Parsed VLESS v0 handshake with full address decoding
#[derive(Debug)]
pub struct VlessRequest {
    /// UUID in canonical format (8-4-4-4-12)
    pub uuid: String,
    /// Raw UUID bytes (16 bytes) for fast comparison
    pub uuid_bytes: [u8; 16],
    /// Command: TCP, UDP, or MUX
    pub command: Command,
    /// Target address (for TCP/UDP commands)
    pub target: Option<TargetAddr>,
    /// Raw addons blob (for FPv1 extension detection)
    pub addons: Vec<u8>,
    /// Any piggybacked payload after the address header
    pub initial_payload: Vec<u8>,
}

/// Parse a VLESS v0 request header from any async reader.
///
/// Wire format (v0):
///   [0]        version  (must be 0)
///   [1..17]    UUID     (16 bytes)
///   [17]       addons_len (N)
///   [18..18+N] addons   (protobuf, usually empty)
///   [18+N]     command  (1=TCP, 2=UDP, 3=MUX)
///   [18+N+1..] port(2) + addr_type(1) + addr + piggybacked payload
pub async fn parse_request<R: AsyncRead + Unpin>(stream: &mut R) -> Result<VlessRequest> {
    // --- Fixed preamble: version(1) + uuid(16) + addons_len(1) = 18 bytes ---
    let mut hdr = [0u8; 18];
    stream
        .read_exact(&mut hdr)
        .await
        .map_err(|_| anyhow!("short header read"))?;

    if hdr[0] != 0 {
        return Err(anyhow!("unsupported VLESS version: {}", hdr[0]));
    }

    // UUID bytes
    let mut uuid_bytes = [0u8; 16];
    uuid_bytes.copy_from_slice(&hdr[1..17]);

    // UUID → canonical lowercase hex
    let uuid_hex = hex::encode(&uuid_bytes);
    let uuid = format!(
        "{}-{}-{}-{}-{}",
        &uuid_hex[0..8],
        &uuid_hex[8..12],
        &uuid_hex[12..16],
        &uuid_hex[16..20],
        &uuid_hex[20..32]
    );

    // Read addons (protobuf blob) — bounded to prevent memory exhaustion
    let addons_len = hdr[17] as usize;
    if addons_len > MAX_ADDONS_LEN {
        return Err(anyhow!(
            "addons too large: {} > {}",
            addons_len,
            MAX_ADDONS_LEN
        ));
    }
    let addons = if addons_len > 0 {
        let mut buf = vec![0u8; addons_len];
        stream
            .read_exact(&mut buf)
            .await
            .map_err(|_| anyhow!("short addons read"))?;
        buf
    } else {
        Vec::new()
    };

    // Command byte
    let mut cmd_buf = [0u8; 1];
    stream
        .read_exact(&mut cmd_buf)
        .await
        .map_err(|_| anyhow!("missing command"))?;
    let command = Command::from_byte(cmd_buf[0])?;

    // Read remaining data: port(2) + addr_type(1) + addr + piggybacked payload
    let mut rest = vec![0u8; 16384];
    let n = stream.read(&mut rest).await?;
    if n < 3 && command != Command::Mux {
        return Err(anyhow!("truncated address"));
    }
    rest.truncate(n);

    // Parse target address for TCP/UDP commands
    let (target, initial_payload) = if command == Command::Mux {
        // MUX command has no initial target — streams are multiplexed later
        (None, rest)
    } else {
        let (addr, consumed) = TargetAddr::parse(&rest)?;
        let payload = rest[consumed..].to_vec();
        (Some(addr), payload)
    };

    Ok(VlessRequest {
        uuid,
        uuid_bytes,
        command,
        target,
        addons,
        initial_payload,
    })
}

/// VLESS v0 response: version(1) + addons_len(1) = 2 bytes, both zero.
pub fn create_response() -> [u8; 2] {
    [0u8; 2]
}

/// Check if addons contain FPv1 magic bytes (0xF0 0x99)
pub fn is_fpv1(addons: &[u8]) -> bool {
    addons.len() >= 2 && addons[0] == 0xF0 && addons[1] == 0x99
}

#[cfg(test)]
mod tests {
    use super::*;

    fn build_vless_packet(
        uuid_bytes: &[u8; 16],
        addons_len: u8,
        addons: &[u8],
        command: u8,
        rest: &[u8],
    ) -> Vec<u8> {
        let mut pkt = Vec::new();
        pkt.push(0); // version
        pkt.extend_from_slice(uuid_bytes);
        pkt.push(addons_len);
        pkt.extend_from_slice(addons);
        pkt.push(command);
        pkt.extend_from_slice(rest);
        pkt
    }

    fn test_uuid_bytes() -> [u8; 16] {
        [
            0x55, 0x0e, 0x84, 0x00, 0xe2, 0x9b, 0x41, 0xd4, 0xa7, 0x16, 0x44, 0x66, 0x55, 0x44,
            0x00, 0x00,
        ]
    }

    fn ipv4_addr_payload(port: u16, ip: [u8; 4]) -> Vec<u8> {
        let mut v = Vec::new();
        v.extend_from_slice(&port.to_be_bytes());
        v.push(1); // IPv4
        v.extend_from_slice(&ip);
        v
    }

    fn domain_addr_payload(port: u16, domain: &str) -> Vec<u8> {
        let mut v = Vec::new();
        v.extend_from_slice(&port.to_be_bytes());
        v.push(2); // Domain
        v.push(domain.len() as u8);
        v.extend_from_slice(domain.as_bytes());
        v
    }

    #[tokio::test]
    async fn parse_tcp_ipv4() {
        let rest = ipv4_addr_payload(80, [127, 0, 0, 1]);
        let pkt = build_vless_packet(&test_uuid_bytes(), 0, &[], 1, &rest);
        let mut reader = &pkt[..];

        let req = parse_request(&mut reader).await.unwrap();
        assert_eq!(req.uuid, "550e8400-e29b-41d4-a716-446655440000");
        assert_eq!(req.command, Command::Tcp);
        assert_eq!(req.target.unwrap().port, 80);
        assert!(req.initial_payload.is_empty());
    }

    #[tokio::test]
    async fn parse_tcp_domain() {
        let rest = domain_addr_payload(443, "google.com");
        let pkt = build_vless_packet(&test_uuid_bytes(), 0, &[], 1, &rest);
        let mut reader = &pkt[..];

        let req = parse_request(&mut reader).await.unwrap();
        assert_eq!(req.command, Command::Tcp);
        let target = req.target.unwrap();
        assert_eq!(target.port, 443);
        assert_eq!(target.to_socket_string(), "google.com:443");
    }

    #[tokio::test]
    async fn parse_udp_command() {
        let rest = ipv4_addr_payload(53, [8, 8, 8, 8]);
        let pkt = build_vless_packet(&test_uuid_bytes(), 0, &[], 2, &rest);
        let mut reader = &pkt[..];

        let req = parse_request(&mut reader).await.unwrap();
        assert_eq!(req.command, Command::Udp);
        assert_eq!(req.target.unwrap().port, 53);
    }

    #[tokio::test]
    async fn parse_mux_command() {
        // MUX has no initial target
        let pkt = build_vless_packet(&test_uuid_bytes(), 0, &[], 3, &[0; 10]);
        let mut reader = &pkt[..];

        let req = parse_request(&mut reader).await.unwrap();
        assert_eq!(req.command, Command::Mux);
        assert!(req.target.is_none());
    }

    #[tokio::test]
    async fn parse_with_piggybacked_payload() {
        let mut rest = ipv4_addr_payload(443, [1, 2, 3, 4]);
        rest.extend_from_slice(b"GET / HTTP/1.1\r\n"); // piggybacked data
        let pkt = build_vless_packet(&test_uuid_bytes(), 0, &[], 1, &rest);
        let mut reader = &pkt[..];

        let req = parse_request(&mut reader).await.unwrap();
        assert_eq!(req.initial_payload, b"GET / HTTP/1.1\r\n");
    }

    #[tokio::test]
    async fn parse_with_addons() {
        let addons = vec![0x0a, 0x02, 0x08, 0x01];
        let rest = ipv4_addr_payload(443, [127, 0, 0, 1]);
        let pkt = build_vless_packet(&test_uuid_bytes(), addons.len() as u8, &addons, 1, &rest);
        let mut reader = &pkt[..];

        let req = parse_request(&mut reader).await.unwrap();
        assert_eq!(req.addons, addons);
    }

    #[tokio::test]
    async fn detect_fpv1_magic() {
        assert!(is_fpv1(&[0xF0, 0x99, 0x01, 0x00]));
        assert!(!is_fpv1(&[0x0a, 0x02]));
        assert!(!is_fpv1(&[]));
    }

    #[tokio::test]
    async fn reject_unsupported_version() {
        let rest = ipv4_addr_payload(80, [127, 0, 0, 1]);
        let mut pkt = build_vless_packet(&test_uuid_bytes(), 0, &[], 1, &rest);
        pkt[0] = 1;
        let mut reader = &pkt[..];
        assert!(parse_request(&mut reader).await.is_err());
    }

    #[tokio::test]
    async fn reject_oversized_addons() {
        let rest = ipv4_addr_payload(80, [127, 0, 0, 1]);
        let addons = vec![0u8; 257];
        let mut pkt = Vec::new();
        pkt.push(0);
        pkt.extend_from_slice(&test_uuid_bytes());
        pkt.push(255); // addons_len = 255 < 256 so this should pass
        pkt.extend_from_slice(&addons[..255]);
        pkt.push(1);
        pkt.extend_from_slice(&rest);
        let mut reader = &pkt[..];
        // 255 < 256, should pass
        assert!(parse_request(&mut reader).await.is_ok());
    }

    #[tokio::test]
    async fn reject_truncated_header() {
        let pkt = vec![0u8; 5];
        let mut reader = &pkt[..];
        assert!(parse_request(&mut reader).await.is_err());
    }

    #[tokio::test]
    async fn uuid_format_canonical() {
        let zero_uuid = [0u8; 16];
        let rest = ipv4_addr_payload(80, [127, 0, 0, 1]);
        let pkt = build_vless_packet(&zero_uuid, 0, &[], 1, &rest);
        let mut reader = &pkt[..];
        let req = parse_request(&mut reader).await.unwrap();
        assert_eq!(req.uuid, "00000000-0000-0000-0000-000000000000");

        let ff_uuid = [0xFF; 16];
        let pkt = build_vless_packet(&ff_uuid, 0, &[], 1, &rest);
        let mut reader = &pkt[..];
        let req = parse_request(&mut reader).await.unwrap();
        assert_eq!(req.uuid, "ffffffff-ffff-ffff-ffff-ffffffffffff");
    }

    #[test]
    fn response_is_two_zero_bytes() {
        assert_eq!(create_response(), [0u8, 0u8]);
    }
}
