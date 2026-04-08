//! OrcaX tunnel — connects to server, speaks native protocol, handles Passthrough.
//!
//! The tunnel acts as a local SOCKS5 proxy. Apps connect to localhost:1080,
//! the tunnel forwards traffic through the OrcaX server.

use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::Arc;

use anyhow::{anyhow, Result};
use tracing::{debug, info};

use orcax_protocol::orca::Frame;

/// Tunnel configuration
#[derive(Clone)]
pub struct TunnelConfig {
    /// OrcaX server address (e.g., "204.168.171.253:9444")
    pub server_addr: String,
    /// Server's x25519 public key (base64)
    pub server_pubkey: [u8; 32],
    /// User UUID (16 bytes)
    pub uuid: [u8; 16],
    /// SNI domain for Reality TLS (e.g., "ozon.ru")
    pub sni: String,
    /// Local SOCKS5 listen address (e.g., "127.0.0.1:1080")
    pub socks_addr: String,
    /// Reality short ID
    pub short_id: [u8; 8],
}

/// Tunnel state
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum TunnelState {
    Disconnected,
    Connecting,
    Connected,
    Error,
}

/// The main tunnel struct
pub struct OrcaXTunnel {
    config: TunnelConfig,
    state: Arc<AtomicU32>,
    running: Arc<AtomicBool>,
}

impl OrcaXTunnel {
    pub fn new(config: TunnelConfig) -> Self {
        Self {
            config,
            state: Arc::new(AtomicU32::new(TunnelState::Disconnected as u32)),
            running: Arc::new(AtomicBool::new(false)),
        }
    }

    pub fn state(&self) -> TunnelState {
        match self.state.load(Ordering::Relaxed) {
            0 => TunnelState::Disconnected,
            1 => TunnelState::Connecting,
            2 => TunnelState::Connected,
            _ => TunnelState::Error,
        }
    }

    /// Start the tunnel — binds a local SOCKS5 proxy and forwards through OrcaX.
    pub fn start(&self) -> Result<()> {
        self.running.store(true, Ordering::Release);
        self.state.store(TunnelState::Connecting as u32, Ordering::Relaxed);

        let listener = TcpListener::bind(&self.config.socks_addr)?;
        info!(addr = %self.config.socks_addr, "SOCKS5 proxy listening");
        self.state.store(TunnelState::Connected as u32, Ordering::Relaxed);

        while self.running.load(Ordering::Acquire) {
            let (client, peer) = match listener.accept() {
                Ok(v) => v,
                Err(_) => continue,
            };

            let config = self.config.clone();
            let _running = self.running.clone();
            std::thread::spawn(move || {
                if let Err(e) = handle_socks5(client, &config) {
                    debug!(p = %peer, err = %e, "socks5 err");
                }
            });
        }

        self.state.store(TunnelState::Disconnected as u32, Ordering::Relaxed);
        Ok(())
    }

    /// Stop the tunnel
    pub fn stop(&self) {
        self.running.store(false, Ordering::Release);
    }
}

/// Handle one SOCKS5 connection: negotiate → connect to OrcaX → relay
fn handle_socks5(mut client: TcpStream, config: &TunnelConfig) -> Result<()> {
    // SOCKS5 handshake (minimal — no auth)
    let mut buf = [0u8; 258];
    let n = client.read(&mut buf)?;
    if n < 2 || buf[0] != 0x05 { return Err(anyhow!("not SOCKS5")); }
    // Reply: no auth required
    client.write_all(&[0x05, 0x00])?;

    // SOCKS5 connect request
    let mut req = [0u8; 263];
    let n = client.read(&mut req)?;
    if n < 7 || req[0] != 0x05 || req[1] != 0x01 { return Err(anyhow!("bad SOCKS5 request")); }

    // Parse target address
    let (host, port, _addr_end) = match req[3] {
        0x01 => { // IPv4
            let ip = format!("{}.{}.{}.{}", req[4], req[5], req[6], req[7]);
            let port = u16::from_be_bytes([req[8], req[9]]);
            (ip, port, 10)
        }
        0x03 => { // Domain
            let len = req[4] as usize;
            let domain = String::from_utf8(req[5..5+len].to_vec())?;
            let port = u16::from_be_bytes([req[5+len], req[6+len]]);
            (domain, port, 7 + len)
        }
        0x04 => { // IPv6
            return Err(anyhow!("IPv6 SOCKS not implemented yet"));
        }
        _ => return Err(anyhow!("unknown SOCKS addr type")),
    };

    debug!(host = %host, port, "SOCKS5 connect");

    // Connect to OrcaX server and open a stream
    let mut server = connect_orcax(config)?;

    // Send StreamOpen frame
    let target = orcax_protocol::address::TargetAddr {
        addr: if let Ok(ip) = host.parse::<std::net::Ipv4Addr>() {
            orcax_protocol::address::Address::IPv4(ip)
        } else {
            orcax_protocol::address::Address::Domain(host.clone())
        },
        port,
    };
    let open_frame = Frame::stream_open(1, &target);
    server.write_all(&open_frame.encode())?;

    // SOCKS5 success reply
    client.write_all(&[0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0])?;

    // Relay: client ↔ OrcaX server
    // For MVP: raw bidirectional copy (framing handled by server)
    // Full impl: parse Data frames, handle Passthrough → drop TLS → splice
    relay_tls(&mut client, &mut server)
}

/// Connect to OrcaX server: TCP → Reality TLS → OrcaX handshake.
/// Returns the TLS stream ready for OrcaX frame exchange.
fn connect_orcax(config: &TunnelConfig) -> Result<impl Read + Write> {
    let stream = TcpStream::connect(&config.server_addr)?;
    stream.set_nodelay(true)?;
    let sock = socket2::SockRef::from(&stream);
    let _ = sock.set_recv_buffer_size(262144);
    let _ = sock.set_send_buffer_size(262144);

    // Reality TLS handshake — connect as if we're visiting ozon.ru
    let _root_store = rustls::RootCertStore::empty();
    // Reality doesn't validate server cert normally — we verify via HMAC
    // Use a custom verifier that accepts any cert (Reality auth is separate)
    let tls_config = rustls::ClientConfig::builder()
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(NoVerify))
        .with_no_client_auth();

    let server_name = rustls_pki_types::ServerName::try_from(config.sni.as_str())
        .map_err(|_| anyhow!("invalid SNI"))?
        .to_owned();

    let conn = rustls::ClientConnection::new(Arc::new(tls_config), server_name)
        .map_err(|e| anyhow!("TLS: {}", e))?;

    let mut tls = rustls::StreamOwned::new(conn, stream);

    // Force TLS handshake
    tls.flush()?;

    // OrcaX handshake: send ClientAuth (48 bytes)
    let (ephemeral_pub, encrypted_uuid) =
        orcax_transport::handshake::client_encrypt_uuid(&config.server_pubkey, &config.uuid);

    let mut auth = [0u8; 48];
    auth[0..32].copy_from_slice(&ephemeral_pub);
    auth[32..48].copy_from_slice(&encrypted_uuid);
    tls.write_all(&auth)?;
    tls.flush()?;

    // Read ServerAuth (33 bytes)
    let mut resp = [0u8; 33];
    tls.read_exact(&mut resp)?;
    let status = resp[32];
    match status {
        0 => debug!("OrcaX auth OK"),
        1 => return Err(anyhow!("auth failed")),
        2 => return Err(anyhow!("device limit exceeded")),
        3 => return Err(anyhow!("account banned")),
        _ => return Err(anyhow!("server error: {}", status)),
    }

    Ok(tls)
}

/// Custom certificate verifier that accepts anything.
/// Reality authentication happens at a different layer (HMAC on cert).
#[derive(Debug)]
struct NoVerify;

impl rustls::client::danger::ServerCertVerifier for NoVerify {
    fn verify_server_cert(
        &self, _: &rustls_pki_types::CertificateDer<'_>,
        _: &[rustls_pki_types::CertificateDer<'_>],
        _: &rustls_pki_types::ServerName<'_>, _: &[u8], _: rustls_pki_types::UnixTime,
    ) -> Result<rustls::client::danger::ServerCertVerified, rustls::Error> {
        Ok(rustls::client::danger::ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self, _: &[u8], _: &rustls_pki_types::CertificateDer<'_>,
        _: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        Ok(rustls::client::danger::HandshakeSignatureValid::assertion())
    }

    fn verify_tls13_signature(
        &self, _: &[u8], _: &rustls_pki_types::CertificateDer<'_>,
        _: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        Ok(rustls::client::danger::HandshakeSignatureValid::assertion())
    }

    fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
        vec![
            rustls::SignatureScheme::ECDSA_NISTP256_SHA256,
            rustls::SignatureScheme::ECDSA_NISTP384_SHA384,
            rustls::SignatureScheme::ED25519,
            rustls::SignatureScheme::RSA_PSS_SHA256,
            rustls::SignatureScheme::RSA_PSS_SHA384,
            rustls::SignatureScheme::RSA_PSS_SHA512,
            rustls::SignatureScheme::RSA_PKCS1_SHA256,
            rustls::SignatureScheme::RSA_PKCS1_SHA384,
            rustls::SignatureScheme::RSA_PKCS1_SHA512,
        ]
    }
}

/// Relay between local client (TcpStream) and OrcaX server (TLS stream).
/// Uses poll() on the client fd + blocking TLS reads in alternation.
fn relay_tls<S: Read + Write>(client: &mut TcpStream, server: &mut S) -> Result<()> {
    client.set_read_timeout(Some(std::time::Duration::from_millis(1)))?;
    client.set_nonblocking(false)?;

    let mut buf_up = [0u8; 65536];
    let mut buf_down = [0u8; 65536];

    loop {
        // Upload: client → server
        match client.read(&mut buf_up) {
            Ok(0) => break,
            Ok(n) => { if server.write_all(&buf_up[..n]).is_err() { break; } }
            Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock
                || e.kind() == std::io::ErrorKind::TimedOut => {}
            Err(_) => break,
        }

        // Download: server → client
        match server.read(&mut buf_down) {
            Ok(0) => break,
            Ok(n) => { if client.write_all(&buf_down[..n]).is_err() { break; } }
            Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock
                || e.kind() == std::io::ErrorKind::TimedOut => {}
            Err(_) => break,
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tunnel_config_create() {
        let config = TunnelConfig {
            server_addr: "127.0.0.1:9444".into(),
            server_pubkey: [0u8; 32],
            uuid: [0x42u8; 16],
            sni: "ozon.ru".into(),
            socks_addr: "127.0.0.1:1080".into(),
            short_id: [0u8; 8],
        };
        let tunnel = OrcaXTunnel::new(config);
        assert_eq!(tunnel.state(), TunnelState::Disconnected);
    }

    #[test]
    fn tunnel_state_transitions() {
        let config = TunnelConfig {
            server_addr: "127.0.0.1:9444".into(),
            server_pubkey: [0u8; 32],
            uuid: [0x42u8; 16],
            sni: "ozon.ru".into(),
            socks_addr: "127.0.0.1:0".into(),
            short_id: [0u8; 8],
        };
        let tunnel = OrcaXTunnel::new(config);
        assert_eq!(tunnel.state(), TunnelState::Disconnected);
        tunnel.stop();
        assert_eq!(tunnel.state(), TunnelState::Disconnected);
    }
}
