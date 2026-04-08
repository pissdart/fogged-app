//! Reality Dynamic Certificate — matches xray-lite's exact approach
//!
//! Uses rcgen 0.12 (same as xray-lite) to generate Ed25519 certs.
//! The last 64 bytes of the DER are overwritten with HMAC-SHA512(auth_key, ed25519_pubkey).

use std::collections::HashMap;
use std::sync::Mutex;

use anyhow::{anyhow, Result};
use rustls_pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};

static CERT_CACHE: Mutex<Option<HashMap<String, (Vec<u8>, Vec<u8>, Vec<u8>)>>> = Mutex::new(None);

pub fn generate_reality_cert(
    auth_key: &[u8; 32],
    domain: &str,
) -> Result<(CertificateDer<'static>, PrivateKeyDer<'static>)> {
    let (mut cert_der, priv_key_der, pub_key_raw) = get_or_create_template(domain)?;

    // HMAC-SHA512(auth_key, ed25519_public_key) — exactly like xray-lite
    use hmac::{Hmac, Mac};
    use sha2::Sha512;
    let mut mac = <Hmac<Sha512> as Mac>::new_from_slice(auth_key)
        .map_err(|_| anyhow!("HMAC key init failed"))?;
    Mac::update(&mut mac, &pub_key_raw);
    let signature = mac.finalize().into_bytes();

    let total_len = cert_der.len();
    if total_len < 64 {
        return Err(anyhow!("cert DER too short: {} bytes", total_len));
    }
    cert_der[total_len - 64..].copy_from_slice(&signature[..64]);

    Ok((
        CertificateDer::from(cert_der),
        PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(priv_key_der)),
    ))
}

fn get_or_create_template(domain: &str) -> Result<(Vec<u8>, Vec<u8>, Vec<u8>)> {
    let mut cache = CERT_CACHE.lock().unwrap_or_else(|p| p.into_inner());
    let cache = cache.get_or_insert_with(HashMap::new);

    if let Some(cached) = cache.get(domain) {
        return Ok(cached.clone());
    }

    // Use rcgen 0.12 API — EXACTLY like xray-lite
    use rcgen::{CertificateParams, KeyPair, PKCS_ED25519};

    let key_pair = KeyPair::generate(&PKCS_ED25519)
        .map_err(|e| anyhow!("Ed25519 keygen: {}", e))?;
    let pub_key_raw = key_pair.public_key_raw().to_vec();

    let mut params = CertificateParams::new(vec![domain.to_string()]);
    params.alg = &PKCS_ED25519;
    params.key_pair = Some(key_pair);

    let cert = rcgen::Certificate::from_params(params)
        .map_err(|e| anyhow!("cert gen: {}", e))?;
    let cert_der = cert.serialize_der()
        .map_err(|e| anyhow!("cert serialize: {}", e))?;
    let priv_key_der = cert.serialize_private_key_der();

    cache.insert(
        domain.to_string(),
        (cert_der.clone(), priv_key_der.clone(), pub_key_raw.clone()),
    );

    Ok((cert_der, priv_key_der, pub_key_raw))
}

pub fn get_cached_pubkey(domain: &str) -> Option<Vec<u8>> {
    let cache = CERT_CACHE.lock().ok()?;
    cache.as_ref()?.get(domain).map(|(_, _, pk)| pk.clone())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generate_cert_basic() {
        let auth_key = [0x42u8; 32];
        let (cert, _key) = generate_reality_cert(&auth_key, "test-basic.com").unwrap();
        assert!(!cert.as_ref().is_empty());
        assert!(cert.as_ref().len() > 64);
    }

    #[test]
    fn different_auth_keys_different_sigs() {
        let key1 = [0x11u8; 32];
        let key2 = [0x22u8; 32];
        let (cert1, _) = generate_reality_cert(&key1, "diff-test.com").unwrap();
        let (cert2, _) = generate_reality_cert(&key2, "diff-test.com").unwrap();
        let len = cert1.as_ref().len();
        assert_ne!(&cert1.as_ref()[len - 64..], &cert2.as_ref()[len - 64..]);
        assert_eq!(&cert1.as_ref()[..len - 64], &cert2.as_ref()[..len - 64]);
    }

    #[test]
    fn cached_pubkey_32_bytes() {
        let key = [0x55u8; 32];
        generate_reality_cert(&key, "cache-test.com").unwrap();
        let pk = get_cached_pubkey("cache-test.com");
        assert!(pk.is_some());
        assert_eq!(pk.unwrap().len(), 32);
    }
}

#[cfg(test)]
mod dump_test {
    use super::*;
    #[test]
    fn dump_cert_to_file() {
        let auth_key = [0x42u8; 32];
        let (cert, _) = generate_reality_cert(&auth_key, "go-test.com").unwrap();
        std::fs::write("/tmp/orcax-test-cert.der", cert.as_ref()).unwrap();
        let pk = get_cached_pubkey("go-test.com").unwrap();
        std::fs::write("/tmp/orcax-test-pubkey.bin", &pk).unwrap();
        println!("Wrote cert ({} bytes) and pubkey ({} bytes)", cert.as_ref().len(), pk.len());
    }
}
