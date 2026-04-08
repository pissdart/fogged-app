use anyhow::{anyhow, Result};

/// Parsed TLS ClientHello — extracts the fields Reality needs
#[derive(Debug, Clone)]
pub struct ClientHelloInfo {
    /// Full raw ClientHello handshake message (for AAD computation)
    pub raw: Vec<u8>,
    /// ClientHello.Random (32 bytes)
    pub random: [u8; 32],
    /// Legacy SessionID (32 bytes — contains encrypted Reality auth)
    pub session_id: Vec<u8>,
    /// Offset of SessionID in raw message (for zeroing in AAD)
    pub session_id_offset: usize,
    /// Server Name Indication (SNI)
    pub sni: Option<String>,
    /// x25519 key share (client's ephemeral public key, 32 bytes)
    pub x25519_key: Option<[u8; 32]>,
    /// Cipher suites offered
    pub cipher_suites: Vec<u16>,
}

/// Parse a TLS ClientHello from the handshake payload.
/// Input is the handshake message body (after the 5-byte TLS record header).
pub fn parse_client_hello(data: &[u8]) -> Result<ClientHelloInfo> {
    if data.len() < 4 {
        return Err(anyhow!("handshake too short"));
    }

    // Handshake header: type(1) + length(3)
    let hs_type = data[0];
    if hs_type != 0x01 {
        return Err(anyhow!("not a ClientHello: type={:#x}", hs_type));
    }
    let hs_len = ((data[1] as usize) << 16) | ((data[2] as usize) << 8) | (data[3] as usize);
    if data.len() < 4 + hs_len {
        return Err(anyhow!("ClientHello truncated: have {}, need {}", data.len(), 4 + hs_len));
    }

    let raw = data[..4 + hs_len].to_vec();
    let body = &data[4..4 + hs_len];
    let mut pos = 0;

    // Legacy version (2 bytes)
    if body.len() < pos + 2 {
        return Err(anyhow!("missing legacy version"));
    }
    pos += 2;

    // Random (32 bytes)
    if body.len() < pos + 32 {
        return Err(anyhow!("missing random"));
    }
    let mut random = [0u8; 32];
    random.copy_from_slice(&body[pos..pos + 32]);
    pos += 32;

    // Session ID (1 byte length + variable)
    if body.len() < pos + 1 {
        return Err(anyhow!("missing session ID length"));
    }
    let session_id_len = body[pos] as usize;
    pos += 1;
    // Offset in the raw message: 4 (handshake header) + 2 (version) + 32 (random) + 1 (sid_len)
    let session_id_offset = 4 + 2 + 32 + 1;
    if body.len() < pos + session_id_len {
        return Err(anyhow!("truncated session ID"));
    }
    let session_id = body[pos..pos + session_id_len].to_vec();
    pos += session_id_len;

    // Cipher suites (2 byte length + variable)
    if body.len() < pos + 2 {
        return Err(anyhow!("missing cipher suites length"));
    }
    let cs_len = u16::from_be_bytes([body[pos], body[pos + 1]]) as usize;
    pos += 2;
    if body.len() < pos + cs_len || cs_len % 2 != 0 {
        return Err(anyhow!("invalid cipher suites"));
    }
    let mut cipher_suites = Vec::with_capacity(cs_len / 2);
    for i in (0..cs_len).step_by(2) {
        cipher_suites.push(u16::from_be_bytes([body[pos + i], body[pos + i + 1]]));
    }
    pos += cs_len;

    // Compression methods (1 byte length + variable)
    if body.len() < pos + 1 {
        return Err(anyhow!("missing compression methods"));
    }
    let comp_len = body[pos] as usize;
    pos += 1 + comp_len;

    // Extensions (2 byte length + variable)
    let mut sni = None;
    let mut x25519_key = None;

    if body.len() > pos + 2 {
        let ext_len = u16::from_be_bytes([body[pos], body[pos + 1]]) as usize;
        pos += 2;
        let ext_end = pos + ext_len;

        while pos + 4 <= ext_end && pos + 4 <= body.len() {
            let ext_type = u16::from_be_bytes([body[pos], body[pos + 1]]);
            let ext_data_len = u16::from_be_bytes([body[pos + 2], body[pos + 3]]) as usize;
            pos += 4;

            if pos + ext_data_len > body.len() {
                break;
            }

            let ext_data = &body[pos..pos + ext_data_len];

            match ext_type {
                // SNI (0x0000)
                0x0000 => {
                    sni = parse_sni(ext_data);
                }
                // Key Share (0x0033)
                0x0033 => {
                    x25519_key = parse_key_share(ext_data);
                }
                _ => {}
            }

            pos += ext_data_len;
        }
    }

    Ok(ClientHelloInfo {
        raw,
        random,
        session_id,
        session_id_offset,
        sni,
        x25519_key,
        cipher_suites,
    })
}

/// Extract SNI hostname from SNI extension data
fn parse_sni(data: &[u8]) -> Option<String> {
    if data.len() < 5 {
        return None;
    }
    // SNI list length (2) + type (1) + name length (2)
    let _list_len = u16::from_be_bytes([data[0], data[1]]);
    let name_type = data[2];
    if name_type != 0 {
        return None; // Only host_name type (0)
    }
    let name_len = u16::from_be_bytes([data[3], data[4]]) as usize;
    if data.len() < 5 + name_len {
        return None;
    }
    String::from_utf8(data[5..5 + name_len].to_vec()).ok()
}

/// Extract x25519 public key from Key Share extension
fn parse_key_share(data: &[u8]) -> Option<[u8; 32]> {
    if data.len() < 2 {
        return None;
    }
    let list_len = u16::from_be_bytes([data[0], data[1]]) as usize;
    let mut pos = 2;
    let end = (2 + list_len).min(data.len());

    while pos + 4 <= end {
        let group = u16::from_be_bytes([data[pos], data[pos + 1]]);
        let key_len = u16::from_be_bytes([data[pos + 2], data[pos + 3]]) as usize;
        pos += 4;

        if pos + key_len > data.len() {
            break;
        }

        // x25519 group = 0x001d, key = 32 bytes
        if group == 0x001d && key_len == 32 {
            let mut key = [0u8; 32];
            key.copy_from_slice(&data[pos..pos + 32]);
            return Some(key);
        }

        pos += key_len;
    }

    None
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Build a minimal ClientHello for testing
    fn build_test_client_hello(
        random: &[u8; 32],
        session_id: &[u8],
        sni: &str,
        x25519_pub: &[u8; 32],
    ) -> Vec<u8> {
        let mut body = Vec::new();

        // Legacy version
        body.extend_from_slice(&[0x03, 0x03]);
        // Random
        body.extend_from_slice(random);
        // Session ID
        body.push(session_id.len() as u8);
        body.extend_from_slice(session_id);
        // Cipher suites: TLS_AES_128_GCM_SHA256
        body.extend_from_slice(&[0x00, 0x02, 0x13, 0x01]);
        // Compression: null
        body.extend_from_slice(&[0x01, 0x00]);

        // Extensions
        let mut exts = Vec::new();

        // SNI extension (0x0000)
        let sni_bytes = sni.as_bytes();
        let mut sni_ext = Vec::new();
        let name_len = sni_bytes.len() as u16;
        let list_len = name_len + 3;
        sni_ext.extend_from_slice(&list_len.to_be_bytes());
        sni_ext.push(0x00); // host_name type
        sni_ext.extend_from_slice(&name_len.to_be_bytes());
        sni_ext.extend_from_slice(sni_bytes);
        exts.extend_from_slice(&[0x00, 0x00]); // ext type
        exts.extend_from_slice(&(sni_ext.len() as u16).to_be_bytes());
        exts.extend_from_slice(&sni_ext);

        // Key Share extension (0x0033) with x25519
        let mut ks_ext = Vec::new();
        let entry_len: u16 = 2 + 2 + 32; // group(2) + len(2) + key(32)
        ks_ext.extend_from_slice(&entry_len.to_be_bytes()); // list length
        ks_ext.extend_from_slice(&[0x00, 0x1d]); // x25519 group
        ks_ext.extend_from_slice(&[0x00, 0x20]); // key length = 32
        ks_ext.extend_from_slice(x25519_pub);
        exts.extend_from_slice(&[0x00, 0x33]); // ext type
        exts.extend_from_slice(&(ks_ext.len() as u16).to_be_bytes());
        exts.extend_from_slice(&ks_ext);

        // Extensions length
        body.extend_from_slice(&(exts.len() as u16).to_be_bytes());
        body.extend_from_slice(&exts);

        // Wrap in handshake header
        let mut msg = Vec::new();
        msg.push(0x01); // ClientHello type
        let len = body.len();
        msg.push((len >> 16) as u8);
        msg.push((len >> 8) as u8);
        msg.push(len as u8);
        msg.extend_from_slice(&body);

        msg
    }

    #[test]
    fn parse_basic_client_hello() {
        let random = [0x42u8; 32];
        let session_id = [0xABu8; 32];
        let x25519_pub = [0xCDu8; 32];

        let data = build_test_client_hello(&random, &session_id, "ozon.ru", &x25519_pub);
        let info = parse_client_hello(&data).unwrap();

        assert_eq!(info.random, random);
        assert_eq!(info.session_id, session_id);
        assert_eq!(info.sni, Some("ozon.ru".into()));
        assert_eq!(info.x25519_key, Some(x25519_pub));
        assert_eq!(info.cipher_suites, vec![0x1301]);
    }

    #[test]
    fn parse_empty_session_id() {
        let random = [0x11u8; 32];
        let x25519_pub = [0x22u8; 32];
        let data = build_test_client_hello(&random, &[], "example.com", &x25519_pub);
        let info = parse_client_hello(&data).unwrap();
        assert!(info.session_id.is_empty());
        assert_eq!(info.sni, Some("example.com".into()));
    }

    #[test]
    fn reject_non_client_hello() {
        let data = vec![0x02, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00]; // ServerHello type
        assert!(parse_client_hello(&data).is_err());
    }

    #[test]
    fn reject_truncated() {
        assert!(parse_client_hello(&[0x01, 0x00]).is_err());
    }
}
