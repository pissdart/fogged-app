use std::time::{SystemTime, UNIX_EPOCH};

use aes_gcm::{aead::Aead, Aes256Gcm, KeyInit, Nonce};
use anyhow::{anyhow, Result};
use hkdf::Hkdf;
use sha2::Sha256;
use tracing::{debug, warn};
use x25519_dalek::{PublicKey, StaticSecret};

use crate::client_hello::ClientHelloInfo;

/// Reality server configuration
#[derive(Clone)]
pub struct RealityConfig {
    /// x25519 static private key (32 bytes)
    pub private_key: StaticSecret,
    /// Allowed short IDs (hex-decoded, 8 bytes each)
    pub short_ids: Vec<[u8; 8]>,
    /// Allowed SNI hostnames
    pub server_names: Vec<String>,
    /// Fallback destination for failed auth (e.g., "ozon.ru:443")
    pub dest: String,
    /// Maximum time drift in seconds (default 120)
    pub max_time_diff: u64,
}

/// Decoded Reality authentication payload
#[derive(Debug)]
pub struct RealityAuth {
    pub version: [u8; 4],
    pub timestamp: u32,
    pub short_id: [u8; 8],
}

/// Verify a Reality ClientHello. Returns the authenticated payload or an error.
///
/// Steps:
/// 1. Validate SNI against server_names
/// 2. Extract x25519 public key from KeyShare
/// 3. ECDH: server_private * client_public = shared_secret
/// 4. HKDF(shared_secret, Random[0:20], "REALITY") = AuthKey
/// 5. Construct AAD (raw ClientHello with SessionID zeroed)
/// 6. AES-256-GCM decrypt SessionID using AuthKey
/// 7. Validate shortId, timestamp
pub fn verify_client_hello(
    config: &RealityConfig,
    info: &ClientHelloInfo,
) -> Result<RealityAuth> {
    // 1. Validate SNI
    let sni = info.sni.as_deref().unwrap_or("");
    if !config.server_names.iter().any(|s| s == sni) {
        return Err(anyhow!("SNI not in whitelist: {}", sni));
    }

    // 2. Extract x25519 key
    let client_pub_bytes = info
        .x25519_key
        .ok_or_else(|| anyhow!("no x25519 key share in ClientHello"))?;
    let client_public = PublicKey::from(client_pub_bytes);

    // 3. ECDH
    let shared_secret = config.private_key.clone().diffie_hellman(&client_public);

    // 4. HKDF — salt = Random[0:20], info = "REALITY"
    let salt = &info.random[0..20];
    let hkdf = Hkdf::<Sha256>::new(Some(salt), shared_secret.as_bytes());
    let mut auth_key = [0u8; 32];
    hkdf.expand(b"REALITY", &mut auth_key)
        .map_err(|_| anyhow!("HKDF expansion failed"))?;

    // 5. SessionID must be 32 bytes (16 plaintext + 16 GCM tag)
    if info.session_id.len() != 32 {
        return Err(anyhow!(
            "invalid SessionID length: {} (expected 32)",
            info.session_id.len()
        ));
    }

    // 6. Construct AAD — raw ClientHello with SessionID bytes zeroed
    // Go's utls builds hello.Raw with random SessionID, then overwrites SessionId[:16] with
    // plaintext auth. Seal() uses hello.Raw as AAD. Since SessionId is a slice into Raw,
    // the AAD has the plaintext auth data at positions 39-54 and original random at 55-70.
    // But the server receives the ENCRYPTED SessionID in the ClientHello.
    // We reconstruct the AAD by zeroing the SessionID (matching what both sides agree on).
    let mut aad = info.raw.clone();
    let sid_start = info.session_id_offset;
    let sid_end = sid_start + 32;
    if aad.len() >= sid_end {
        for b in &mut aad[sid_start..sid_end] {
            *b = 0;
        }
    } else {
        return Err(anyhow!("AAD too short for SessionID offset"));
    }

    // 7. AES-256-GCM decrypt
    let cipher = Aes256Gcm::new_from_slice(&auth_key)
        .map_err(|_| anyhow!("AES-256-GCM key init failed"))?;
    let nonce = Nonce::from_slice(&info.random[20..32]);

    // The session_id is ciphertext (16 bytes) + GCM tag (16 bytes)
    // aes-gcm crate expects: decrypt(nonce, Payload { msg: ciphertext+tag, aad })
    let plaintext = cipher
        .decrypt(
            nonce,
            aes_gcm::aead::Payload {
                msg: &info.session_id,
                aad: &aad,
            },
        )
        .map_err(|_| anyhow!("Reality auth decryption failed — not a valid Reality client"))?;

    if plaintext.len() < 16 {
        return Err(anyhow!("decrypted auth too short: {}", plaintext.len()));
    }

    // 8. Parse decrypted payload
    let mut version = [0u8; 4];
    version.copy_from_slice(&plaintext[0..4]);

    let timestamp = u32::from_be_bytes([plaintext[4], plaintext[5], plaintext[6], plaintext[7]]);

    let mut short_id = [0u8; 8];
    short_id.copy_from_slice(&plaintext[8..16]);

    // 9. Validate shortId
    if !config.short_ids.iter().any(|sid| sid == &short_id) {
        return Err(anyhow!("shortId not in whitelist"));
    }

    // 10. Validate timestamp (allow max_time_diff seconds of drift)
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs() as u32;
    let diff = if now > timestamp {
        now - timestamp
    } else {
        timestamp - now
    };
    if diff > config.max_time_diff as u32 {
        warn!(
            diff,
            timestamp, now, "Reality timestamp drift too large"
        );
        return Err(anyhow!("timestamp drift: {}s > {}s", diff, config.max_time_diff));
    }

    debug!(
        short_id = hex::encode(short_id),
        timestamp,
        "Reality auth verified"
    );

    Ok(RealityAuth {
        version,
        timestamp,
        short_id,
    })
}

/// Generate the auth HMAC for ServerHello.Random[20:32]
/// This lets the client verify the server is a real Reality server
pub fn server_hello_auth(auth_key: &[u8; 32], server_random_prefix: &[u8; 20], client_random: &[u8; 32]) -> [u8; 12] {
    use hmac::{Hmac, Mac};

    let mut mac = <Hmac<Sha256> as Mac>::new_from_slice(auth_key).unwrap();
    Mac::update(&mut mac, server_random_prefix);
    Mac::update(&mut mac, client_random);
    let result = mac.finalize().into_bytes();

    let mut out = [0u8; 12];
    out.copy_from_slice(&result[..12]);
    out
}

/// Derive the AuthKey from ECDH shared secret and client random
/// (Exported for use in ServerHello generation)
pub fn derive_auth_key(
    private_key: &StaticSecret,
    client_public: &PublicKey,
    client_random: &[u8; 32],
) -> [u8; 32] {
    let shared_secret = private_key.clone().diffie_hellman(client_public);
    let salt = &client_random[0..20];
    let hkdf = Hkdf::<Sha256>::new(Some(salt), shared_secret.as_bytes());
    let mut auth_key = [0u8; 32];
    hkdf.expand(b"REALITY", &mut auth_key).unwrap();
    auth_key
}

/// Parse a hex-encoded short ID into 8 bytes (zero-padded)
pub fn parse_short_id(hex_str: &str) -> Result<[u8; 8]> {
    let bytes = hex::decode(hex_str).map_err(|_| anyhow!("invalid hex shortId"))?;
    if bytes.len() > 8 {
        return Err(anyhow!("shortId too long: {} bytes", bytes.len()));
    }
    let mut sid = [0u8; 8];
    sid[..bytes.len()].copy_from_slice(&bytes);
    Ok(sid)
}

/// Parse a base64-encoded x25519 private key
pub fn parse_private_key(b64: &str) -> Result<StaticSecret> {
    let bytes = base64::Engine::decode(&base64::engine::general_purpose::STANDARD, b64)
        .map_err(|_| anyhow!("invalid base64 private key"))?;
    if bytes.len() != 32 {
        return Err(anyhow!("private key must be 32 bytes, got {}", bytes.len()));
    }
    let mut key = [0u8; 32];
    key.copy_from_slice(&bytes);
    Ok(StaticSecret::from(key))
}

#[cfg(test)]
mod tests {
    use super::*;
    use x25519_dalek::PublicKey;

    #[test]
    fn parse_short_id_basic() {
        let sid = parse_short_id("0a1ea84f841b1c90").unwrap();
        assert_eq!(sid, [0x0a, 0x1e, 0xa8, 0x4f, 0x84, 0x1b, 0x1c, 0x90]);
    }

    #[test]
    fn parse_short_id_short() {
        let sid = parse_short_id("abcd").unwrap();
        assert_eq!(sid, [0xab, 0xcd, 0, 0, 0, 0, 0, 0]);
    }

    #[test]
    fn parse_short_id_reject_long() {
        assert!(parse_short_id("0a1ea84f841b1c9000").is_err());
    }

    #[test]
    fn derive_auth_key_deterministic() {
        let secret = StaticSecret::from([0x42u8; 32]);
        let public = PublicKey::from([0xABu8; 32]);
        let random = [0x11u8; 32];

        let key1 = derive_auth_key(&secret, &public, &random);
        let key2 = derive_auth_key(&secret, &public, &random);
        assert_eq!(key1, key2);
    }

    #[test]
    fn server_hello_auth_deterministic() {
        let auth_key = [0x42u8; 32];
        let prefix = [0x11u8; 20];
        let client_random = [0x22u8; 32];

        let hmac1 = server_hello_auth(&auth_key, &prefix, &client_random);
        let hmac2 = server_hello_auth(&auth_key, &prefix, &client_random);
        assert_eq!(hmac1, hmac2);
        assert_ne!(hmac1, [0u8; 12]); // not all zeros
    }

    #[test]
    fn parse_private_key_roundtrip() {
        let secret = StaticSecret::random_from_rng(rand::thread_rng());
        let bytes: [u8; 32] = secret.to_bytes();
        let b64 = base64::Engine::encode(&base64::engine::general_purpose::STANDARD, bytes);
        let parsed = parse_private_key(&b64).unwrap();
        assert_eq!(parsed.to_bytes(), bytes);
    }
}
