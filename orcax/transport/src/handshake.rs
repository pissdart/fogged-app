//! OrcaX Handshake v2 — x25519 ECDH + ChaCha20-Poly1305 AEAD
//!
//! After QUIC/TLS 1.3 is established, the OrcaX handshake authenticates
//! the client's UUID using Diffie-Hellman key agreement with authenticated
//! encryption and replay protection.
//!
//! Wire format:
//!   Client → Server: [ephemeral_pub:32][encrypted_payload:40] = 72 bytes
//!     encrypted_payload = ChaCha20-Poly1305(key, nonce, [uuid:16][timestamp:8])
//!   Server → Client: [server_ephemeral_pub:32][status:1] = 33 bytes
//!
//! Replay protection: timestamp must be within ±15s of server time.

use anyhow::{anyhow, Result};
use chacha20poly1305::{ChaCha20Poly1305, KeyInit, AeadInPlace, Nonce};
use hkdf::Hkdf;
use sha2::Sha256;
use x25519_dalek::{EphemeralSecret, PublicKey, StaticSecret};

/// Max time drift allowed (seconds)
const MAX_TIME_DRIFT: u64 = 15;

/// Server-side handshake config
#[derive(Clone)]
pub struct HandshakeConfig {
    /// Server's static x25519 private key
    pub static_key: StaticSecret,
}

/// Result of a successful server-side handshake
pub struct HandshakeResult {
    /// Authenticated UUID string (8-4-4-4-12 format)
    pub uuid: String,
    /// Server's ephemeral public key (sent to client)
    pub server_ephemeral_pub: [u8; 32],
}

/// Perform server-side OrcaX handshake (v2 — AEAD + replay protection)
///
/// Input: client's 72-byte auth message (ephemeral_pub + encrypted_payload)
/// Output: authenticated UUID + server response
pub fn server_handshake(
    config: &HandshakeConfig,
    client_ephemeral_pub: &[u8; 32],
    encrypted_payload: &[u8],
) -> Result<HandshakeResult> {
    // 1. ECDH: server_static * client_ephemeral = shared_secret
    let client_public = PublicKey::from(*client_ephemeral_pub);
    let shared_secret = config.static_key.clone().diffie_hellman(&client_public);

    // 2. HKDF to derive 32-byte key + 12-byte nonce
    let hkdf = Hkdf::<Sha256>::new(Some(b"orcax-v2"), shared_secret.as_bytes());
    let mut key_material = [0u8; 44]; // 32 key + 12 nonce
    hkdf.expand(b"ORCAX-AUTH-V2", &mut key_material)
        .map_err(|_| anyhow!("HKDF expand failed"))?;

    let key = &key_material[..32];
    let nonce = Nonce::from_slice(&key_material[32..44]);

    // 3. Decrypt with ChaCha20-Poly1305 AEAD
    let cipher = ChaCha20Poly1305::new_from_slice(key)
        .map_err(|_| anyhow!("cipher init"))?;

    // encrypted_payload = ciphertext(24) + tag(16) = 40 bytes
    if encrypted_payload.len() != 40 {
        return Err(anyhow!("bad auth payload size"));
    }

    let mut plaintext = encrypted_payload[..24].to_vec(); // ciphertext without tag
    let tag = &encrypted_payload[24..40];

    cipher.decrypt_in_place_detached(nonce, b"", &mut plaintext, tag.into())
        .map_err(|_| anyhow!("auth decryption failed — wrong key or tampered"))?;

    // plaintext = [uuid:16][timestamp:8]
    let uuid_bytes = &plaintext[..16];
    let timestamp_bytes = &plaintext[16..24];
    let client_timestamp = u64::from_be_bytes(timestamp_bytes.try_into().unwrap());

    // 4. Replay protection: check timestamp within ±120s
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs();
    let drift = if now > client_timestamp { now - client_timestamp } else { client_timestamp - now };
    if drift > MAX_TIME_DRIFT {
        return Err(anyhow!("auth timestamp drift {}s exceeds {}s", drift, MAX_TIME_DRIFT));
    }

    // 5. Format UUID
    let uuid_hex = hex::encode(uuid_bytes);
    let uuid = format!(
        "{}-{}-{}-{}-{}",
        &uuid_hex[0..8],
        &uuid_hex[8..12],
        &uuid_hex[12..16],
        &uuid_hex[16..20],
        &uuid_hex[20..32]
    );

    // 6. Generate server ephemeral key
    let server_secret = EphemeralSecret::random_from_rng(rand::thread_rng());
    let server_public = PublicKey::from(&server_secret);

    Ok(HandshakeResult {
        uuid,
        server_ephemeral_pub: server_public.to_bytes(),
    })
}

/// Client-side: encrypt UUID + timestamp for sending to server
///
/// Returns (ephemeral_pub[32], encrypted_payload[40])
pub fn client_encrypt_uuid(
    server_static_pub: &[u8; 32],
    uuid_bytes: &[u8; 16],
) -> ([u8; 32], Vec<u8>) {
    // Generate ephemeral key
    let client_secret = EphemeralSecret::random_from_rng(rand::thread_rng());
    let client_public = PublicKey::from(&client_secret);

    // ECDH
    let server_public = PublicKey::from(*server_static_pub);
    let shared_secret = client_secret.diffie_hellman(&server_public);

    // HKDF — 32-byte key + 12-byte nonce
    let hkdf = Hkdf::<Sha256>::new(Some(b"orcax-v2"), shared_secret.as_bytes());
    let mut key_material = [0u8; 44];
    hkdf.expand(b"ORCAX-AUTH-V2", &mut key_material).unwrap();

    let key = &key_material[..32];
    let nonce = Nonce::from_slice(&key_material[32..44]);

    // Build plaintext: [uuid:16][timestamp:8]
    let timestamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs();
    let mut plaintext = Vec::with_capacity(24);
    plaintext.extend_from_slice(uuid_bytes);
    plaintext.extend_from_slice(&timestamp.to_be_bytes());

    // Encrypt with ChaCha20-Poly1305
    let cipher = ChaCha20Poly1305::new_from_slice(key).unwrap();
    let tag = cipher.encrypt_in_place_detached(nonce, b"", &mut plaintext).unwrap();

    // Output: ciphertext(24) + tag(16) = 40 bytes
    plaintext.extend_from_slice(&tag);

    (client_public.to_bytes(), plaintext)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn handshake_roundtrip() {
        let server_static = StaticSecret::random_from_rng(rand::thread_rng());
        let server_pub = PublicKey::from(&server_static);

        let config = HandshakeConfig {
            static_key: server_static,
        };

        let uuid_bytes: [u8; 16] = [
            0x08, 0x04, 0xb5, 0x76, 0x4d, 0xfb, 0x42, 0x4a,
            0x80, 0xe7, 0xe8, 0x12, 0xe5, 0xc1, 0x3c, 0xae,
        ];
        let (client_ephemeral_pub, encrypted_payload) =
            client_encrypt_uuid(&server_pub.to_bytes(), &uuid_bytes);

        let result = server_handshake(&config, &client_ephemeral_pub, &encrypted_payload).unwrap();
        assert_eq!(result.uuid, "0804b576-4dfb-424a-80e7-e812e5c13cae");
    }

    #[test]
    fn wrong_server_key_fails() {
        let server_static = StaticSecret::random_from_rng(rand::thread_rng());
        let wrong_static = StaticSecret::random_from_rng(rand::thread_rng());
        let server_pub = PublicKey::from(&server_static);

        let config = HandshakeConfig {
            static_key: wrong_static,
        };

        let uuid_bytes = [0x42u8; 16];
        let (client_ephemeral_pub, encrypted_payload) =
            client_encrypt_uuid(&server_pub.to_bytes(), &uuid_bytes);

        // AEAD should reject — not silently decrypt to wrong UUID
        let result = server_handshake(&config, &client_ephemeral_pub, &encrypted_payload);
        assert!(result.is_err());
    }

    #[test]
    fn different_ephemeral_keys_produce_different_ciphertexts() {
        let server_static = StaticSecret::random_from_rng(rand::thread_rng());
        let server_pub = PublicKey::from(&server_static);
        let uuid_bytes = [0x11u8; 16];

        let (pub1, enc1) = client_encrypt_uuid(&server_pub.to_bytes(), &uuid_bytes);
        let (pub2, enc2) = client_encrypt_uuid(&server_pub.to_bytes(), &uuid_bytes);

        assert_ne!(pub1, pub2);
        assert_ne!(enc1, enc2);

        // But both decrypt to same UUID
        let config = HandshakeConfig { static_key: server_static };
        let r1 = server_handshake(&config, &pub1, &enc1).unwrap();
        let r2 = server_handshake(&config, &pub2, &enc2).unwrap();
        assert_eq!(r1.uuid, r2.uuid);
    }

    #[test]
    fn tampered_payload_rejected() {
        let server_static = StaticSecret::random_from_rng(rand::thread_rng());
        let server_pub = PublicKey::from(&server_static);

        let config = HandshakeConfig { static_key: server_static };

        let uuid_bytes = [0x42u8; 16];
        let (client_ephemeral_pub, mut encrypted_payload) =
            client_encrypt_uuid(&server_pub.to_bytes(), &uuid_bytes);

        // Flip a bit in the ciphertext
        encrypted_payload[5] ^= 0x01;

        let result = server_handshake(&config, &client_ephemeral_pub, &encrypted_payload);
        assert!(result.is_err());
    }
}
