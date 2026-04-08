//! OrcaX TLS Server

use anyhow::{anyhow, Result};

/// Reality server config
#[derive(Clone)]
pub struct RealityServerConfig {
    pub private_key: x25519_dalek::StaticSecret,
    pub short_ids: Vec<[u8; 8]>,
    pub server_names: Vec<String>,
    pub dest: String,
    pub max_time_diff: u64,
}

/// Generate a self-signed Ed25519 cert (rcgen 0.12 API)
pub fn generate_cert(domain: &str) -> Result<(Vec<u8>, Vec<u8>)> {
    use rcgen::{CertificateParams, KeyPair, PKCS_ED25519};
    let key_pair = KeyPair::generate(&PKCS_ED25519)
        .map_err(|e| anyhow!("keygen: {}", e))?;
    let mut params = CertificateParams::new(vec![domain.to_string()]);
    params.alg = &PKCS_ED25519;
    params.key_pair = Some(key_pair);
    let cert = rcgen::Certificate::from_params(params)
        .map_err(|e| anyhow!("cert: {}", e))?;
    Ok((cert.serialize_der().unwrap(), cert.serialize_private_key_der()))
}

/// A stream that prepends buffered data before reading from the inner stream
pub struct PrefixedStream {
    prefix: Vec<u8>,
    prefix_pos: usize,
    pub inner: std::net::TcpStream,
}

impl PrefixedStream {
    pub fn new(prefix: Vec<u8>, inner: std::net::TcpStream) -> Self {
        Self { prefix, prefix_pos: 0, inner }
    }
}

impl std::io::Read for PrefixedStream {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        if self.prefix_pos < self.prefix.len() {
            let remaining = &self.prefix[self.prefix_pos..];
            let n = remaining.len().min(buf.len());
            buf[..n].copy_from_slice(&remaining[..n]);
            self.prefix_pos += n;
            return Ok(n);
        }
        self.inner.read(buf)
    }
}

impl std::io::Write for PrefixedStream {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        self.inner.write(buf)
    }
    fn flush(&mut self) -> std::io::Result<()> {
        self.inner.flush()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generate_cert_works() {
        let (c, k) = generate_cert("ozon.ru").unwrap();
        assert!(!c.is_empty());
        assert!(!k.is_empty());
    }
}
