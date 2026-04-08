use alloc::string::String;
use alloc::vec;
use alloc::vec::Vec;

use crate::Error;
use ring::hmac;

#[derive(Clone, Debug)]
pub struct RealityConfig {
    pub private_key: Vec<u8>,
    pub verify_client: bool,
    pub dest: Option<String>,
    pub short_ids: Vec<Vec<u8>>,
}

impl RealityConfig {
    pub fn new(private_key: Vec<u8>) -> Self {
        Self {
            private_key,
            verify_client: true,
            dest: None,
            short_ids: Vec::new(),
        }
    }
    pub fn with_verify_client(mut self, verify: bool) -> Self {
        self.verify_client = verify;
        self
    }
    pub fn with_dest(mut self, dest: String) -> Self {
        self.dest = Some(dest);
        self
    }
    pub fn with_short_ids(mut self, short_ids: Vec<Vec<u8>>) -> Self {
        self.short_ids = short_ids;
        self
    }
    pub fn validate(&self) -> Result<(), Error> {
        if self.private_key.len() != 32 {
            return Err(Error::General(
                "Reality private key must be 32 bytes".into(),
            ));
        }
        Ok(())
    }
}

/// Client-side Reality config — encrypts auth data into SessionID
#[derive(Clone, Debug)]
pub struct RealityClientConfig {
    /// Server's x25519 static PUBLIC key (32 bytes)
    pub server_public_key: Vec<u8>,
    /// Short ID (8 bytes)
    pub short_id: Vec<u8>,
}

impl RealityClientConfig {
    pub fn new(server_public_key: Vec<u8>, short_id: Vec<u8>) -> Self {
        Self { server_public_key, short_id }
    }

    /// Encrypt Reality auth into a 32-byte SessionID.
    /// Uses the x25519 ephemeral key from the ClientHello's key_share.
    /// Format: AES-256-GCM(key=auth_key, nonce=random[20:32], aad=hello_with_zeroed_sid,
    ///         plaintext=[version:4][timestamp:4][short_id:8]) = 16 bytes ciphertext + 16 bytes tag
    pub fn encrypt_session_id(
        &self,
        client_ephemeral_pub: &[u8; 32],
        client_random: &[u8; 32],
        raw_hello: &[u8],
        session_id_offset: usize,
    ) -> Result<[u8; 32], Error> {
        use ring::aead;
        use ring::agreement;

        if self.server_public_key.len() != 32 {
            return Err(Error::General("bad server pubkey".into()));
        }

        // ECDH: client_ephemeral * server_static_public = shared_secret
        let peer_pub = agreement::UnparsedPublicKey::new(&agreement::X25519, &self.server_public_key);
        // We need the raw shared secret, but ring doesn't expose it directly.
        // Use HKDF with the shared secret as input.
        // Actually — we compute this outside ring, using x25519-dalek compatible math.
        // For now, use the auth_key from HKDF directly.

        // Build auth_key: HKDF(shared_secret, salt=Random[0:20], info="REALITY")
        // We don't have the shared secret here — the caller must provide auth_key.
        // Let's restructure: the caller computes auth_key and passes it in.
        Err(Error::General("use encrypt_session_id_with_key instead".into()))
    }

    /// Encrypt SessionID given a pre-computed auth_key
    pub fn encrypt_session_id_with_key(
        &self,
        auth_key: &[u8; 32],
        client_random: &[u8; 32],
        raw_hello: &[u8],
        session_id_offset: usize,
    ) -> Result<[u8; 32], Error> {
        use ring::aead;

        // Plaintext: [version:4][timestamp:4][short_id:8] = 16 bytes
        let mut plaintext = [0u8; 16];
        // version = 0
        let timestamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs() as u32;
        plaintext[4..8].copy_from_slice(&timestamp.to_be_bytes());
        let sid_len = self.short_id.len().min(8);
        plaintext[8..8 + sid_len].copy_from_slice(&self.short_id[..sid_len]);

        // AAD: raw ClientHello with SessionID bytes zeroed
        let mut aad = raw_hello.to_vec();
        if aad.len() > session_id_offset + 32 {
            for b in &mut aad[session_id_offset..session_id_offset + 32] {
                *b = 0;
            }
        }

        // AES-256-GCM encrypt
        let key = aead::UnboundKey::new(&aead::AES_256_GCM, auth_key)
            .map_err(|_| Error::General("aead key".into()))?;
        let key = aead::LessSafeKey::new(key);

        // Nonce: Random[20:32] (12 bytes)
        let nonce_bytes: [u8; 12] = client_random[20..32].try_into().unwrap();
        let nonce = aead::Nonce::assume_unique_for_key(nonce_bytes);

        // Encrypt in place: plaintext becomes ciphertext+tag (16+16=32 bytes)
        let mut session_id = Vec::with_capacity(32);
        session_id.extend_from_slice(&plaintext);
        key.seal_in_place_append_tag(nonce, aead::Aad::from(&aad), &mut session_id)
            .map_err(|_| Error::General("aead seal".into()))?;

        let mut result = [0u8; 32];
        result.copy_from_slice(&session_id[..32]);
        Ok(result)
    }
}

/// Inject Reality authentication into ServerHello.random
/// Standard Reality: HMAC-SHA256(Key=AuthKey, Msg=ServerHello.Random[0..20])
pub fn inject_auth(
    server_random: &mut [u8; 32],
    config: &RealityConfig,
    client_random: &[u8; 32],
) -> Result<(), Error> {
    config.validate()?;

    // The key is the session-specific AuthKey
    let key = hmac::Key::new(hmac::HMAC_SHA256, &config.private_key);

    // Xray-core Reality order: ServerRandomPrefix (20) + ClientRandom (32)
    let mut message = Vec::with_capacity(52);
    message.extend_from_slice(&server_random[0..20]);
    message.extend_from_slice(client_random);

    // HMAC-SHA256 SIGN
    let tag = hmac::sign(&key, &message);

    // Inject first 12 bytes of HMAC into server_random[20..32]
    server_random[20..32].copy_from_slice(&tag.as_ref()[0..12]);

    Ok(())
}

pub fn verify_client(session_id: &[u8], client_random: &[u8; 32], config: &RealityConfig) -> bool {
    if session_id.len() < 8 || config.private_key.len() != 32 {
        return false;
    }

    // The key is the session-specific AuthKey
    let key = hmac::Key::new(hmac::HMAC_SHA256, &config.private_key);

    // Reality client auth: HMAC-SHA256(Key=AuthKey, Msg=ClientRandom)
    let tag = hmac::sign(&key, client_random);

    // Constant-time comparison of the first 8 bytes
    use subtle::ConstantTimeEq;
    tag.as_ref()[..8]
        .ct_eq(&session_id[..8])
        .into()
}
