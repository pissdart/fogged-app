use anyhow::{anyhow, Result};
use tokio::io::{AsyncRead, AsyncReadExt};

/// TLS record content types
pub const CONTENT_HANDSHAKE: u8 = 0x16;
pub const CONTENT_CCS: u8 = 0x14;
pub const CONTENT_APPLICATION: u8 = 0x17;

/// TLS handshake types
pub const HANDSHAKE_CLIENT_HELLO: u8 = 0x01;
pub const HANDSHAKE_SERVER_HELLO: u8 = 0x02;

/// Maximum TLS record size (16KB + overhead)
const MAX_RECORD_SIZE: usize = 16384 + 256;

/// Raw TLS record header (5 bytes)
#[derive(Debug, Clone)]
pub struct TlsRecordHeader {
    pub content_type: u8,
    pub legacy_version: [u8; 2],
    pub length: u16,
}

/// Read a single TLS record from the wire.
/// Returns the header and the raw record payload.
pub async fn read_tls_record<R: AsyncRead + Unpin>(stream: &mut R) -> Result<(TlsRecordHeader, Vec<u8>)> {
    // Read 5-byte record header
    let mut hdr = [0u8; 5];
    stream.read_exact(&mut hdr).await
        .map_err(|_| anyhow!("short TLS record header"))?;

    let header = TlsRecordHeader {
        content_type: hdr[0],
        legacy_version: [hdr[1], hdr[2]],
        length: u16::from_be_bytes([hdr[3], hdr[4]]),
    };

    if header.length as usize > MAX_RECORD_SIZE {
        return Err(anyhow!("TLS record too large: {} bytes", header.length));
    }

    // Read record payload
    let mut payload = vec![0u8; header.length as usize];
    stream.read_exact(&mut payload).await
        .map_err(|_| anyhow!("short TLS record payload"))?;

    Ok((header, payload))
}

/// Build a raw TLS record from content type and payload
pub fn build_tls_record(content_type: u8, payload: &[u8]) -> Vec<u8> {
    let len = payload.len() as u16;
    let mut record = Vec::with_capacity(5 + payload.len());
    record.push(content_type);
    record.extend_from_slice(&[0x03, 0x03]); // TLS 1.2 legacy version
    record.extend_from_slice(&len.to_be_bytes());
    record.extend_from_slice(payload);
    record
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn read_record() {
        // Build a handshake record
        let payload = vec![0x01, 0x02, 0x03];
        let mut data = vec![CONTENT_HANDSHAKE, 0x03, 0x03, 0x00, 0x03];
        data.extend_from_slice(&payload);

        let mut reader = &data[..];
        let (hdr, body) = read_tls_record(&mut reader).await.unwrap();
        assert_eq!(hdr.content_type, CONTENT_HANDSHAKE);
        assert_eq!(hdr.length, 3);
        assert_eq!(body, payload);
    }

    #[test]
    fn build_record() {
        let record = build_tls_record(CONTENT_HANDSHAKE, &[0x01, 0x02]);
        assert_eq!(record, vec![0x16, 0x03, 0x03, 0x00, 0x02, 0x01, 0x02]);
    }
}
