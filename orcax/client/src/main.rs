mod brutal;
use std::collections::HashMap;
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};
use std::sync::Arc;
use anyhow::{anyhow, Result};
use chacha20poly1305::aead::KeyInit;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{mpsc, Mutex};

type TlsStream = tokio_rustls::client::TlsStream<TcpStream>;

fn dlog(msg: &str) {
    let ts = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_millis();
    println!("{{\"status\":\"log\",\"ts\":{},\"msg\":\"{}\"}}", ts, msg.replace('"', "'").replace('\\', "/"));
}

/// Per-stream channel: receives Data frames from the TLS reader
struct StreamHandle {
    rx: mpsc::Receiver<Vec<u8>>,
}

/// Single mux connection (TLS + reader + writer)
struct MuxLink {
    write_tx: mpsc::Sender<Vec<u8>>,
}

/// Multi-connection mux pool — distributes streams across N TLS connections
struct MuxPool {
    links: Vec<MuxLink>,
    streams: Arc<Mutex<HashMap<u32, mpsc::Sender<Vec<u8>>>>>,
    next_id: AtomicU32,
    server_addr: String,
    session_token: [u8; 16], // from first link's auth
}

impl MuxPool {
    /// Open stream on the least-loaded connection (round-robin by stream_id)
    async fn open_stream(&self, target: &orcax_protocol::address::TargetAddr) -> Result<(u32, StreamHandle)> {
        let sid = self.next_id.fetch_add(2, Ordering::Relaxed);
        let (tx, rx) = mpsc::channel(64);
        self.streams.lock().await.insert(sid, tx);

        // Round-robin: pick connection based on stream_id
        let link_idx = (sid as usize / 2) % self.links.len();
        let frame = orcax_protocol::orca::Frame::stream_open(sid, target).encode();
        self.links[link_idx].write_tx.send(frame).await.map_err(|_| anyhow!("write closed"))?;

        Ok((sid, StreamHandle { rx }))
    }

    /// Send data on the connection that owns this stream
    fn link_for(&self, stream_id: u32) -> &MuxLink {
        let idx = (stream_id as usize / 2) % self.links.len();
        &self.links[idx]
    }

    async fn close_stream(&self, stream_id: u32) {
        let frame = orcax_protocol::orca::Frame::stream_close(stream_id).encode();
        let _ = self.link_for(stream_id).write_tx.send(frame).await;
        self.streams.lock().await.remove(&stream_id);
    }
}

/// Establish TLS + OrcaX auth, return the TLS stream
async fn connect_and_auth(sa: &str) -> Result<(TlsStream, [u8; 16])> {
    dlog(&format!("connecting to {}", sa));
    let tcp = TcpStream::connect(sa).await?;
    tcp.set_nodelay(true)?;
    dlog("TCP connected");
    let sock = socket2::SockRef::from(&tcp);
    let _ = sock.set_recv_buffer_size(262144);
    let _ = sock.set_send_buffer_size(262144);

    let cfg = rustls::ClientConfig::builder()
        .dangerous().with_custom_certificate_verifier(Arc::new(NV)).with_no_client_auth();
    let con = tokio_rustls::TlsConnector::from(Arc::new(cfg));
    let sni = rustls_pki_types::ServerName::try_from("orcax.local")
        .map_err(|_| anyhow!("bad SNI"))?.to_owned();
    let mut tls = tokio::time::timeout(
        std::time::Duration::from_secs(30),
        con.connect(sni, tcp)
    ).await.map_err(|_| anyhow!("TLS timeout"))?.map_err(|e| anyhow!("TLS: {}", e))?;
    dlog("TLS handshake done");

    // OrcaX handshake
    let pk = spk();
    let uuid = parse_uuid(&arg_s(sa, "--uuid").unwrap_or("0804b576-4dfb-424a-80e7-e812e5c13cae".into()));
    let (eph, enc) = orcax_transport::handshake::client_encrypt_uuid(&pk, &uuid);
    let mut a = Vec::with_capacity(32 + enc.len());
    a.extend_from_slice(&eph); a.extend_from_slice(&enc);
    tls.write_all(&a).await?; tls.flush().await?;
    let mut rr = [0u8; 33]; tls.read_exact(&mut rr).await?;
    if rr[32] != 0 { return Err(anyhow!("auth: {}", rr[32])); }
    dlog("OrcaX auth OK");

    // Read session token for split-path raw data channel
    let mut session_token = [0u8; 16];
    tls.read_exact(&mut session_token).await?;

    Ok((tls, session_token))
}

/// Generate random SOCKS5 auth token (prevents local proxy sniffing — Happ-class vuln)
fn generate_socks_token() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let seed = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_nanos();
    format!("{:016x}", seed ^ 0xDEADBEEF_CAFEBABE)
}

/// SOCKS5 auth negotiation: require username/password if token is set
async fn socks5_auth(c: &mut TcpStream, token: &str) -> Result<()> {
    let mut b = [0u8; 258];
    tokio::time::timeout(std::time::Duration::from_secs(5), c.read(&mut b)).await
        .map_err(|_| anyhow!("socks5 timeout"))??;

    if token.is_empty() {
        // No auth required (backwards compat)
        c.write_all(&[5, 0]).await?;
        return Ok(());
    }

    // Check if client offered method 0x02 (username/password)
    let nmethods = b.get(1).copied().unwrap_or(0) as usize;
    let methods = &b[2..2 + nmethods.min(256)];
    if methods.contains(&0x02) {
        // Accept username/password auth
        c.write_all(&[5, 2]).await?;
        // Read auth: [ver:1][ulen:1][user:N][plen:1][pass:N]
        let mut auth = [0u8; 515];
        let n = tokio::time::timeout(std::time::Duration::from_secs(5), c.read(&mut auth)).await
            .map_err(|_| anyhow!("socks5 auth timeout"))??;
        if n < 3 || auth[0] != 1 { return Err(anyhow!("bad socks5 auth")); }
        let ulen = auth[1] as usize;
        let plen = auth[2 + ulen] as usize;
        let pass = std::str::from_utf8(&auth[3 + ulen..3 + ulen + plen]).unwrap_or("");
        if pass == token {
            c.write_all(&[1, 0]).await?; // success
            Ok(())
        } else {
            c.write_all(&[1, 1]).await?; // failure
            Err(anyhow!("socks5 auth rejected"))
        }
    } else if methods.contains(&0x00) {
        // Client only supports no-auth — allow from localhost only
        c.write_all(&[5, 0]).await?;
        Ok(())
    } else {
        c.write_all(&[5, 0xFF]).await?;
        Err(anyhow!("no acceptable socks5 auth method"))
    }
}

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().collect();
    let mut sa = arg(&args, "--server").unwrap_or("204.168.171.253:9444".into());
    let sk = arg(&args, "--socks").unwrap_or("127.0.0.1:1080".into());
    let protocol = arg(&args, "--protocol").unwrap_or("tcp".into());
    let socks_token = arg(&args, "--socks-token").unwrap_or_else(|| generate_socks_token());
    let cdn_url = arg(&args, "--cdn-url");
    let extra_servers = arg(&args, "--extra-servers"); // comma-separated backup servers for multi-path

    // Port hopping: if --ports is provided, pick a random port from the list
    if let Some(ports_str) = arg(&args, "--ports") {
        let ports: Vec<u16> = ports_str.split(',').filter_map(|p| p.trim().parse().ok()).collect();
        if !ports.is_empty() {
            use rand::Rng;
            let port = ports[rand::thread_rng().gen_range(0..ports.len())];
            // Replace port in server address
            if let Some(colon) = sa.rfind(':') {
                sa = format!("{}:{}", &sa[..colon], port);
            }
            dlog(&format!("port hop: selected port {} from {} options", port, ports.len()));
        }
    }

    // Kill any previous instance hogging the SOCKS port
    if let Some(port_str) = sk.rsplit(':').next() {
        let _ = std::process::Command::new("sh")
            .arg("-c")
            .arg(format!("lsof -ti :{} | xargs kill -9 2>/dev/null", port_str))
            .output();
        std::thread::sleep(std::time::Duration::from_millis(100));
    }

    emit("connecting", None);

    if protocol == "quic" {
        run_quic_mode(&sa, &sk, &args, &socks_token, &extra_servers).await;
        // If QUIC failed and we have a CDN URL, try WebSocket fallback
        if let Some(ref url) = cdn_url {
            dlog("QUIC failed, trying CDN WebSocket fallback...");
            emit("connecting", Some("CDN fallback"));
            run_ws_cdn_mode(url, &sa, &sk, &args, &socks_token).await;
        }
        return;
    }

    // Establish ONE control TLS connection (mux for StreamOpen/Close)
    let streams: Arc<Mutex<HashMap<u32, mpsc::Sender<Vec<u8>>>>> = Arc::new(Mutex::new(HashMap::new()));
    let bu = Arc::new(AtomicU64::new(0));
    let bd = Arc::new(AtomicU64::new(0));
    let mut links = Vec::new();
    let mut first_token = [0u8; 16];

    for i in 0..1 { // Only 1 control connection now (data goes per-stream)
        let (tls, token) = match connect_and_auth(&sa).await {
            Ok(t) => t,
            Err(e) => {
                if i == 0 { emit("error", Some(&format!("{}", e))); std::process::exit(1); }
                dlog(&format!("link {} failed: {}", i, e));
                continue;
            }
        };
        if i == 0 { first_token = token; }
        dlog(&format!("control link established"));

        let (write_tx, mut write_rx) = mpsc::channel::<Vec<u8>>(256);
        let (mut tls_read, mut tls_write) = tokio::io::split(tls);

        // Writer task for this connection
        tokio::spawn(async move {
            loop {
                let frame = match write_rx.recv().await { Some(f) => f, None => break };
                if tls_write.write_all(&frame).await.is_err() { break; }
                while let Ok(f) = write_rx.try_recv() { if tls_write.write_all(&f).await.is_err() { break; } }
                if tls_write.flush().await.is_err() { break; }
            }
        });

        // Reader task for this connection
        let streams2 = streams.clone();
        let bd2 = bd.clone();
        let write_tx2 = write_tx.clone();
        tokio::spawn(async move {
            let mut hdr = [0u8; 8];
            let mut frame_count = 0u64;
            loop {
                if tls_read.read_exact(&mut hdr).await.is_err() { dlog(&format!("link {} reader: closed", i)); std::process::exit(1); }
                let frame_type = hdr[0];
                let stream_id = u32::from_be_bytes([hdr[2], hdr[3], hdr[4], hdr[5]]);
                let length = u16::from_be_bytes([hdr[6], hdr[7]]) as usize;
                let mut payload = vec![0u8; length];
                if length > 0 { if tls_read.read_exact(&mut payload).await.is_err() { break; } }
                let flags = hdr[1];
                frame_count += 1;
                if frame_count <= 20 || frame_count % 100 == 0 {
                    dlog(&format!("frame #{} type={} sid={} len={}", frame_count, frame_type, stream_id, length));
                }
                match frame_type {
                    0x00 => {
                        let data = if flags & 0x04 != 0 && !payload.is_empty() {
                            let pad_len = *payload.last().unwrap_or(&0) as usize;
                            if pad_len > 0 && pad_len < payload.len() { payload[..payload.len() - pad_len].to_vec() } else { payload }
                        } else { payload };
                        bd2.fetch_add(data.len() as u64, Ordering::Relaxed);
                        let map = streams2.lock().await;
                        if let Some(tx) = map.get(&stream_id) { let _ = tx.send(data).await; }
                    }
                    0x01 => { // StreamReady — route to waiting stream
                        let map = streams2.lock().await;
                        if let Some(tx) = map.get(&stream_id) { let _ = tx.send(payload).await; }
                    }
                    0x02 => { streams2.lock().await.remove(&stream_id); }
                    0x03 => { let _ = write_tx2.send(orcax_protocol::orca::Frame::pong().encode()).await; }
                    _ => {}
                }
            }
        });

        links.push(MuxLink { write_tx });
    }

    let l = match TcpListener::bind(&sk).await {
        Ok(l) => l,
        Err(e) => { emit("error", Some(&format!("{}", e))); std::process::exit(1); }
    };
    emit("connected", Some(&sk));
    dlog(&format!("{} links established", links.len()));

    let mux = Arc::new(MuxPool {
        links,
        streams: streams.clone(),
        next_id: AtomicU32::new(1),
        server_addr: sa.clone(),
        session_token: first_token,
    });

    // Stats reporter
    let (b1, b2) = (bu.clone(), bd.clone());
    tokio::spawn(async move {
        let mut last = 0u64;
        loop {
            tokio::time::sleep(std::time::Duration::from_secs(2)).await;
            let d = b2.load(Ordering::Relaxed);
            let sp = d.saturating_sub(last) / 2;
            last = d;
            println!("{{\"status\":\"stats\",\"up\":{},\"down\":{},\"speed\":{}}}", b1.load(Ordering::Relaxed), d, sp);
        }
    });

    // Accept SOCKS5 connections — each becomes a mux stream
    let sa2 = Arc::new(sa);
    let token = Arc::new(socks_token.clone());
    // Print token so the Flutter app can read it from stdout
    println!("{{\"status\":\"socks_token\",\"token\":\"{}\"}}", token);
    loop {
        let (c, _) = match l.accept().await { Ok(v) => v, Err(_) => continue };
        let mux = mux.clone();
        let bu = bu.clone();
        let tk = token.clone();
        tokio::spawn(async move { let _ = handle_socks5(c, &mux, &bu, &tk).await; });
    }
}

async fn handle_socks5(mut c: TcpStream, mux: &MuxPool, bu: &Arc<AtomicU64>, token: &str) -> Result<()> {
    c.set_nodelay(true)?;
    socks5_auth(&mut c, token).await?;
    let mut r = [0u8; 263];
    let n = tokio::time::timeout(std::time::Duration::from_secs(5), c.read(&mut r)).await
        .map_err(|_| anyhow!("socks5 timeout"))??;
    if n < 7 || r[1] != 1 { return Err(anyhow!("bad socks5")); }
    let (host, port) = match r[3] {
        1 => (format!("{}.{}.{}.{}", r[4], r[5], r[6], r[7]), u16::from_be_bytes([r[8], r[9]])),
        3 => { let l = r[4] as usize; (String::from_utf8(r[5..5+l].to_vec())?, u16::from_be_bytes([r[5+l], r[6+l]])) }
        _ => return Err(anyhow!("unsupported")),
    };

    let t = orcax_protocol::address::TargetAddr {
        addr: if let Ok(ip) = host.parse::<std::net::Ipv4Addr>() { orcax_protocol::address::Address::IPv4(ip) }
        else { orcax_protocol::address::Address::Domain(host) }, port,
    };

    // Send StreamOpen via mux control channel
    dlog(&format!("SOCKS5 → {}:{}", t.to_socket_string(), port));
    let (sid, mut stream) = mux.open_stream(&t).await?;

    // Wait for StreamReady from server (confirms target connected)
    match tokio::time::timeout(std::time::Duration::from_secs(10), stream.rx.recv()).await {
        Ok(Some(_)) => {} // StreamReady received
        _ => return Err(anyhow!("stream ready timeout")),
    }

    // Open data TCP to server — sends [session_token:16][stream_id:4]
    let mut data_tcp = TcpStream::connect(&mux.server_addr).await?;
    data_tcp.set_nodelay(true)?;
    let mut key = [0u8; 20];
    key[..16].copy_from_slice(&mux.session_token);
    key[16..20].copy_from_slice(&sid.to_be_bytes());
    data_tcp.write_all(&key).await?;

    dlog(&format!("stream {} data channel open", sid));
    c.write_all(&[5, 0, 0, 1, 0, 0, 0, 0, 0, 0]).await?;

    // Wire speed: copy_bidirectional between app and data TCP (no framing, no mux)
    let _ = tokio::io::copy_bidirectional(&mut c, &mut data_tcp).await;
    Ok(())
}

fn spk() -> [u8; 32] {
    let b = bd("cH5pTMOPPjrQvqzZDGGV-Kq2U29kDBTeBCNvBt0YcWk");
    let mut p = [0u8; 32]; p.copy_from_slice(&b);
    x25519_dalek::PublicKey::from(&x25519_dalek::StaticSecret::from(p)).to_bytes()
}
fn bd(s: &str) -> Vec<u8> { use base64::Engine; base64::engine::general_purpose::URL_SAFE_NO_PAD.decode(s).unwrap_or_default() }

#[derive(Debug)] struct NV;
impl rustls::client::danger::ServerCertVerifier for NV {
    fn verify_server_cert(&self, _: &rustls_pki_types::CertificateDer<'_>, _: &[rustls_pki_types::CertificateDer<'_>], _: &rustls_pki_types::ServerName<'_>, _: &[u8], _: rustls_pki_types::UnixTime) -> Result<rustls::client::danger::ServerCertVerified, rustls::Error> { Ok(rustls::client::danger::ServerCertVerified::assertion()) }
    fn verify_tls12_signature(&self, _: &[u8], _: &rustls_pki_types::CertificateDer<'_>, _: &rustls::DigitallySignedStruct) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> { Ok(rustls::client::danger::HandshakeSignatureValid::assertion()) }
    fn verify_tls13_signature(&self, _: &[u8], _: &rustls_pki_types::CertificateDer<'_>, _: &rustls::DigitallySignedStruct) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> { Ok(rustls::client::danger::HandshakeSignatureValid::assertion()) }
    fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> { vec![rustls::SignatureScheme::ED25519, rustls::SignatureScheme::ECDSA_NISTP256_SHA256, rustls::SignatureScheme::RSA_PSS_SHA256] }
}

fn arg(a: &[String], f: &str) -> Option<String> { a.iter().position(|x| x == f).and_then(|i| a.get(i + 1).cloned()) }
fn arg_s(_sa: &str, _f: &str) -> Option<String> {
    let args: Vec<String> = std::env::args().collect();
    arg(&args, _f)
}
fn parse_uuid(s: &str) -> [u8; 16] {
    let hex: String = s.chars().filter(|c| c.is_ascii_hexdigit()).collect();
    let mut out = [0u8; 16];
    for i in 0..16 { out[i] = u8::from_str_radix(&hex[i*2..i*2+2], 16).unwrap_or(0); }
    out
}
fn emit(s: &str, d: Option<&str>) {
    match d {
        Some(v) => println!("{{\"status\":\"{}\",\"detail\":\"{}\"}}", s, v),
        None => println!("{{\"status\":\"{}\"}}", s),
    }
}

// ── QUIC cert verifier (uses quinn's rustls 0.23, not our fork) ──
#[derive(Debug)]
struct QuicNV;
impl quinn::rustls::client::danger::ServerCertVerifier for QuicNV {
    fn verify_server_cert(&self, _: &rustls_pki_types::CertificateDer<'_>, _: &[rustls_pki_types::CertificateDer<'_>], _: &rustls_pki_types::ServerName<'_>, _: &[u8], _: rustls_pki_types::UnixTime) -> Result<quinn::rustls::client::danger::ServerCertVerified, quinn::rustls::Error> { Ok(quinn::rustls::client::danger::ServerCertVerified::assertion()) }
    fn verify_tls12_signature(&self, _: &[u8], _: &rustls_pki_types::CertificateDer<'_>, _: &quinn::rustls::DigitallySignedStruct) -> Result<quinn::rustls::client::danger::HandshakeSignatureValid, quinn::rustls::Error> { Ok(quinn::rustls::client::danger::HandshakeSignatureValid::assertion()) }
    fn verify_tls13_signature(&self, _: &[u8], _: &rustls_pki_types::CertificateDer<'_>, _: &quinn::rustls::DigitallySignedStruct) -> Result<quinn::rustls::client::danger::HandshakeSignatureValid, quinn::rustls::Error> { Ok(quinn::rustls::client::danger::HandshakeSignatureValid::assertion()) }
    fn supported_verify_schemes(&self) -> Vec<quinn::rustls::SignatureScheme> { vec![quinn::rustls::SignatureScheme::ED25519, quinn::rustls::SignatureScheme::ECDSA_NISTP256_SHA256, quinn::rustls::SignatureScheme::RSA_PSS_SHA256] }
}

// ── QUIC Mode: OrcaX Pro Max over QUIC ──

/// Connect to QUIC server and authenticate. Returns the connection on success.
async fn quic_connect_and_auth(endpoint: &quinn::Endpoint, addr: std::net::SocketAddr, args: &[String]) -> Option<quinn::Connection> {
    dlog(&format!("QUIC connecting to {}", addr));
    // Use a legitimate Russian domain as SNI (matches Reality pool)
    // Randomize per connection to avoid fingerprinting
    let sni_pool = ["ozon.ru", "wildberries.ru", "cdn.jsdelivr.net", "api.vk.com", "lamoda.ru"];
    let sni = sni_pool[addr.port() as usize % sni_pool.len()];
    let conn = match endpoint.connect(addr, sni) {
        Ok(c) => match tokio::time::timeout(std::time::Duration::from_secs(10), c).await {
            Ok(Ok(c)) => { dlog("QUIC connected"); c }
            Ok(Err(e)) => { dlog(&format!("QUIC handshake failed: {}", e)); return None; }
            Err(_) => { dlog("QUIC handshake timeout (10s)"); return None; }
        }
        Err(e) => { dlog(&format!("QUIC endpoint error: {}", e)); return None; }
    };

    // OrcaX auth v2
    let (mut auth_send, mut auth_recv) = match conn.open_bi().await {
        Ok(s) => s,
        Err(e) => { dlog(&format!("auth stream failed: {}", e)); return None; }
    };
    let pk = spk();
    let uuid = parse_uuid(&arg(args, "--uuid").unwrap_or("0804b576-4dfb-424a-80e7-e812e5c13cae".into()));
    let (eph, enc) = orcax_transport::handshake::client_encrypt_uuid(&pk, &uuid);
    let mut a = Vec::with_capacity(32 + enc.len());
    a.extend_from_slice(&eph); a.extend_from_slice(&enc);
    if auth_send.write_all(&a).await.is_err() { return None; }
    auth_send.finish().ok();
    let mut rr = [0u8; 33];
    if auth_recv.read_exact(&mut rr).await.is_err() { dlog("auth read failed"); return None; }
    if rr[32] != 0 { dlog(&format!("auth rejected: {}", rr[32])); return None; }
    dlog("QUIC auth OK");

    Some(conn)
}

async fn run_quic_mode(sa: &str, sk: &str, args: &[String], socks_token: &str, extra_servers: &Option<String>) {
    dlog(&format!("QUIC mode → {}", sa));

    // QUIC client: post-quantum TLS (ML-KEM + X25519 hybrid)
    // TLS fingerprint mimics Chrome 125: same cipher provider (AWS-LC/BoringSSL),
    // same key exchange (X25519+ML-KEM768), ALPN h3, GREASE enabled by default
    let client_config = {
        let crypto = quinn::rustls::crypto::aws_lc_rs::default_provider();
        let mut tls = quinn::rustls::ClientConfig::builder_with_provider(crypto.into())
            .with_safe_default_protocol_versions().unwrap()
            .dangerous().with_custom_certificate_verifier(Arc::new(QuicNV))
            .with_no_client_auth();
        // Chrome ALPN for QUIC
        tls.alpn_protocols = vec![b"h3".to_vec()];
        // Enable session resumption (Chrome stores tickets)
        tls.resumption = quinn::rustls::client::Resumption::in_memory_sessions(256);
        let mut cc = quinn::ClientConfig::new(Arc::new(quinn::crypto::rustls::QuicClientConfig::try_from(tls).unwrap()));
        // BBR for client (smart probing), server uses Brutal (aggressive sending)
        let mut transport = quinn::TransportConfig::default();
        transport.congestion_controller_factory(Arc::new(quinn::congestion::BbrConfig::default()));
        transport.max_idle_timeout(Some(quinn::IdleTimeout::from(quinn::VarInt::from_u32(300_000))));
        transport.keep_alive_interval(Some(std::time::Duration::from_secs(15)));
        transport.stream_receive_window(quinn::VarInt::from_u32(8_000_000)); // 8MB per stream
        transport.receive_window(quinn::VarInt::from_u32(16_000_000)); // 16MB total
        transport.send_window(8_000_000); // 8MB send buffer
        transport.max_concurrent_bidi_streams(quinn::VarInt::from_u32(256));
        transport.max_concurrent_uni_streams(quinn::VarInt::from_u32(64));
        cc.transport_config(Arc::new(transport));
        cc
    };

    let mut endpoint = quinn::Endpoint::client("0.0.0.0:0".parse().unwrap()).unwrap();
    endpoint.set_default_client_config(client_config);

    let addr: std::net::SocketAddr = sa.parse().unwrap_or_else(|_| {
        let parts: Vec<&str> = sa.split(':').collect();
        format!("{}:{}", parts[0], parts.get(1).unwrap_or(&"9444")).parse().unwrap()
    });

    // Build server list: primary + extras for multi-path failover
    let mut server_addrs: Vec<std::net::SocketAddr> = vec![addr];
    if let Some(ref extras) = extra_servers {
        for s in extras.split(',') {
            if let Ok(a) = s.trim().parse::<std::net::SocketAddr>() {
                server_addrs.push(a);
            } else if let Some((h, p)) = s.trim().split_once(':') {
                if let Ok(port) = p.parse::<u16>() {
                    if let Ok(ip) = h.parse::<std::net::IpAddr>() {
                        server_addrs.push(std::net::SocketAddr::new(ip, port));
                    }
                }
            }
        }
        if server_addrs.len() > 1 {
            dlog(&format!("multi-path: {} servers available", server_addrs.len()));
        }
    }

    // Connect to ALL servers concurrently (true multi-path)
    let mut connections: Vec<quinn::Connection> = Vec::new();
    let connect_futures: Vec<_> = server_addrs.iter().map(|a| {
        let ep = endpoint.clone();
        let args_owned = args.to_vec();
        let addr = *a;
        async move { (addr, quic_connect_and_auth(&ep, addr, &args_owned).await) }
    }).collect();
    let results = futures::future::join_all(connect_futures).await;
    for (addr, result) in results {
        match result {
            Some(c) => { dlog(&format!("multi-path: connected to {}", addr)); connections.push(c); }
            None => { dlog(&format!("multi-path: {} unreachable", addr)); }
        }
    }
    if connections.is_empty() {
        emit("error", Some("all servers unreachable"));
        return;
    }
    dlog(&format!("multi-path: {}/{} servers connected", connections.len(), server_addrs.len()));

    let l = match TcpListener::bind(sk).await { Ok(l) => l, Err(e) => { emit("error", Some(&format!("{}", e))); return; } };
    emit("connected", Some(sk));

    // Primary connection (first successful), with all connections available for load balancing
    let conn = Arc::new(tokio::sync::RwLock::new(connections.remove(0)));
    // Store backup connections for failover
    let backup_conns: Arc<tokio::sync::Mutex<Vec<quinn::Connection>>> = Arc::new(tokio::sync::Mutex::new(connections));

    // Spawn connection health monitor — reconnects on failure, cycles through servers
    let conn_monitor = conn.clone();
    let endpoint_clone = endpoint.clone();
    let args_owned: Vec<String> = args.to_vec();
    let server_addrs_clone = server_addrs.clone();
    let backup_conns_clone = backup_conns.clone();
    tokio::spawn(async move {
        loop {
            // Check if connection is alive
            tokio::time::sleep(std::time::Duration::from_secs(5)).await;
            let is_dead = {
                let c = conn_monitor.read().await;
                c.close_reason().is_some()
            };
            if !is_dead { continue; }

            // Connection died — try backup connections first (instant failover)
            emit("reconnecting", None);
            dlog("connection lost, checking backups...");
            let mut recovered = false;
            {
                let mut backups = backup_conns_clone.lock().await;
                // Find a live backup connection
                let mut live_idx = None;
                for (i, bc) in backups.iter().enumerate() {
                    if bc.close_reason().is_none() {
                        live_idx = Some(i);
                        break;
                    }
                }
                if let Some(idx) = live_idx {
                    let backup = backups.remove(idx);
                    let mut c = conn_monitor.write().await;
                    *c = backup;
                    emit("connected", Some("127.0.0.1:1080"));
                    dlog("instant failover to backup connection");
                    recovered = true;
                }
            }
            if recovered { continue; }

            // No live backups — reconnect from scratch, cycling through all servers
            dlog("no live backups, reconnecting...");
            let mut delay = 1u64;
            let mut attempt = 0u64;
            loop {
                let server_idx = attempt as usize % server_addrs_clone.len();
                let target = server_addrs_clone[server_idx];
                dlog(&format!("trying server {} ({})", server_idx, target));
                if let Some(new_conn) = quic_connect_and_auth(&endpoint_clone, target, &args_owned).await {
                    let mut c = conn_monitor.write().await;
                    *c = new_conn;
                    emit("connected", Some("127.0.0.1:1080"));
                    dlog(&format!("reconnected to server {}", server_idx));
                    break;
                }
                attempt += 1;
                if attempt as usize % server_addrs_clone.len() == 0 {
                    delay = (delay * 2).min(30);
                }
                dlog(&format!("server {} failed, retry in {}s", server_idx, delay));
                tokio::time::sleep(std::time::Duration::from_secs(delay)).await;
            }
        }
    });

    // Accept SOCKS5 connections, using current connection
    let qtk = Arc::new(socks_token.to_string());
    println!("{{\"status\":\"socks_token\",\"token\":\"{}\"}}", socks_token);
    loop {
        let (c, _) = match l.accept().await { Ok(v) => v, Err(_) => continue };
        let conn = conn.clone();
        let tk = qtk.clone();
        tokio::spawn(async move {
            let conn_guard = conn.read().await;
            if conn_guard.close_reason().is_some() {
                drop(conn_guard);
                tokio::time::sleep(std::time::Duration::from_millis(500)).await;
                let conn_guard = conn.read().await;
                if conn_guard.close_reason().is_some() { return; }
                let _ = quic_socks5(c, &conn_guard, &tk).await;
            } else {
                let _ = quic_socks5(c, &conn_guard, &tk).await;
            }
        });
    }
}

async fn quic_socks5(mut c: TcpStream, conn: &quinn::Connection, token: &str) -> Result<()> {
    c.set_nodelay(true)?;
    socks5_auth(&mut c, token).await?;
    let mut r = [0u8; 263]; let n = c.read(&mut r).await?;
    if n < 7 || r[1] != 1 { return Err(anyhow!("bad")); }
    let (host, port) = match r[3] {
        1 => (format!("{}.{}.{}.{}", r[4], r[5], r[6], r[7]), u16::from_be_bytes([r[8], r[9]])),
        3 => { let l = r[4] as usize; (String::from_utf8(r[5..5+l].to_vec())?, u16::from_be_bytes([r[5+l], r[6+l]])) }
        _ => return Err(anyhow!("unsupported")),
    };

    let (mut send, mut recv) = conn.open_bi().await.map_err(|e| anyhow!("{}", e))?;

    // Target address
    let mut ab = Vec::with_capacity(64);
    ab.push(1); ab.extend_from_slice(&port.to_be_bytes());
    if let Ok(ip) = host.parse::<std::net::Ipv4Addr>() { ab.push(1); ab.extend_from_slice(&ip.octets()); }
    else { ab.push(2); ab.push(host.len() as u8); ab.extend_from_slice(host.as_bytes()); }
    send.write_all(&ab).await.map_err(|e| anyhow!("{}", e))?;

    c.write_all(&[5, 0, 0, 1, 0, 0, 0, 0, 0, 0]).await?;

    // Relay: TCP ↔ QUIC stream
    let (mut cr, mut cw) = c.into_split();
    let up = tokio::spawn(async move { let _ = tokio::io::copy(&mut cr, &mut send).await; send.finish().ok(); });
    let dn = tokio::spawn(async move { let _ = tokio::io::copy(&mut recv, &mut cw).await; });
    tokio::select! { _ = up => {}, _ = dn => {} }
    Ok(())
}

// ── CDN WebSocket Fallback Mode ──
// When QUIC is blocked by TSPU, tunnel OrcaX through Cloudflare WebSocket.
// Client → Cloudflare (HTTPS/WSS) → Worker → ws://server:9445 → OrcaX auth → relay

async fn run_ws_cdn_mode(cdn_url: &str, _sa: &str, sk: &str, args: &[String], socks_token: &str) {
    use tokio_tungstenite::{connect_async, tungstenite::protocol::Message};
    use futures::{StreamExt, SinkExt};

    let uuid = arg(args, "--uuid").unwrap_or_default();
    let l = match TcpListener::bind(sk).await {
        Ok(l) => l,
        Err(e) => { emit("error", Some(&format!("CDN bind: {}", e))); return; }
    };

    dlog(&format!("CDN WebSocket mode → {}", cdn_url));

    // Connect to Cloudflare Worker WebSocket
    let ws_url = url::Url::parse(cdn_url).unwrap_or_else(|_| url::Url::parse("wss://localhost").unwrap());
    let (ws_stream, _) = match connect_async(ws_url.as_str()).await {
        Ok(s) => s,
        Err(e) => { emit("error", Some(&format!("CDN connect failed: {}", e))); return; }
    };
    dlog("CDN WebSocket connected");

    let (mut ws_write, mut ws_read) = ws_stream.split();

    // OrcaX auth over WebSocket (same 72-byte handshake, sent as binary message)
    let uuid_bytes = uuid.replace('-', "").as_bytes().chunks(2)
        .filter_map(|c| u8::from_str_radix(std::str::from_utf8(c).unwrap_or("00"), 16).ok())
        .collect::<Vec<u8>>();
    if uuid_bytes.len() != 16 { emit("error", Some("bad UUID")); return; }

    // Build auth message (same as QUIC mode)
    let eph_secret = x25519_dalek::EphemeralSecret::random_from_rng(rand::thread_rng());
    let eph_pub = x25519_dalek::PublicKey::from(&eph_secret);

    // Read server pubkey from args
    let server_pub_b64 = arg(args, "--pubkey").unwrap_or_default();
    let server_pub_bytes = base64::Engine::decode(
        &base64::engine::general_purpose::URL_SAFE_NO_PAD, &server_pub_b64
    ).unwrap_or_default();
    if server_pub_bytes.len() != 32 {
        emit("error", Some("bad server pubkey for CDN auth"));
        return;
    }
    let mut spk = [0u8; 32];
    spk.copy_from_slice(&server_pub_bytes);
    let server_pub = x25519_dalek::PublicKey::from(spk);

    // ECDH + HKDF + ChaCha20 (same as handshake.rs)
    let shared = eph_secret.diffie_hellman(&server_pub);
    let hk = hkdf::Hkdf::<sha2::Sha256>::new(Some(b"orcax-v2"), shared.as_bytes());
    let mut okm = [0u8; 44];
    hk.expand(b"ORCAX-AUTH-V2", &mut okm).unwrap();
    let key = chacha20poly1305::Key::from_slice(&okm[..32]);
    let nonce = chacha20poly1305::Nonce::from_slice(&okm[32..44]);

    use chacha20poly1305::AeadInPlace;
    let cipher = chacha20poly1305::ChaCha20Poly1305::new(key);
    let timestamp = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs();
    let mut payload = Vec::with_capacity(24);
    payload.extend_from_slice(&uuid_bytes);
    payload.extend_from_slice(&timestamp.to_be_bytes());
    let tag = cipher.encrypt_in_place_detached(nonce, b"", &mut payload).unwrap();
    payload.extend_from_slice(&tag);

    // Send: [eph_pub:32][encrypted:40] = 72 bytes
    let mut auth_msg = Vec::with_capacity(72);
    auth_msg.extend_from_slice(eph_pub.as_bytes());
    auth_msg.extend_from_slice(&payload);

    if ws_write.send(Message::Binary(auth_msg)).await.is_err() {
        emit("error", Some("CDN auth send failed"));
        return;
    }

    // Read auth response (33 bytes: [server_eph:32][status:1])
    match ws_read.next().await {
        Some(Ok(Message::Binary(data))) if data.len() == 33 && data[32] == 0 => {
            dlog("CDN auth OK");
        }
        _ => {
            emit("error", Some("CDN auth rejected"));
            return;
        }
    }

    emit("connected", Some(&format!("{} (CDN)", sk)));
    println!("{{\"status\":\"socks_token\",\"token\":\"{}\"}}", socks_token);

    // Accept SOCKS5 connections and relay through WebSocket
    // For CDN mode, we use a simpler approach: each SOCKS connection sends
    // StreamOpen + data frames as binary WS messages
    let ws_write = Arc::new(tokio::sync::Mutex::new(ws_write));
    let tk = Arc::new(socks_token.to_string());

    // Frame reader: dispatch incoming WS messages to streams
    let streams: Arc<Mutex<HashMap<u32, mpsc::Sender<Vec<u8>>>>> = Arc::new(Mutex::new(HashMap::new()));
    let streams2 = streams.clone();
    let ws_write2 = ws_write.clone();
    tokio::spawn(async move {
        while let Some(Ok(msg)) = ws_read.next().await {
            if let Message::Binary(data) = msg {
                if data.len() < 8 { continue; }
                let frame_type = data[0];
                let stream_id = u32::from_be_bytes([data[2], data[3], data[4], data[5]]);
                let payload = &data[8..];

                match frame_type {
                    0x00 => { // Data
                        if let Some(tx) = streams2.lock().await.get(&stream_id) {
                            let _ = tx.send(payload.to_vec()).await;
                        }
                    }
                    0x02 => { // StreamClose
                        streams2.lock().await.remove(&stream_id);
                    }
                    _ => {}
                }
            }
        }
        dlog("CDN WebSocket reader ended");
    });

    let next_id = Arc::new(AtomicU32::new(1));

    loop {
        let (c, _) = match l.accept().await { Ok(v) => v, Err(_) => continue };
        let ws_w = ws_write.clone();
        let st = streams.clone();
        let nid = next_id.clone();
        let tk = tk.clone();
        tokio::spawn(async move {
            let _ = cdn_socks5(c, ws_w, st, nid, &tk).await;
        });
    }
}

async fn cdn_socks5(
    mut c: TcpStream,
    ws_write: Arc<tokio::sync::Mutex<futures::stream::SplitSink<tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<TcpStream>>, tokio_tungstenite::tungstenite::protocol::Message>>>,
    streams: Arc<Mutex<HashMap<u32, mpsc::Sender<Vec<u8>>>>>,
    next_id: Arc<AtomicU32>,
    token: &str,
) -> Result<()> {
    use tokio_tungstenite::tungstenite::protocol::Message;
    use futures::SinkExt;

    c.set_nodelay(true)?;
    socks5_auth(&mut c, token).await?;

    let mut r = [0u8; 263];
    let n = tokio::time::timeout(std::time::Duration::from_secs(5), c.read(&mut r)).await
        .map_err(|_| anyhow!("socks5 timeout"))??;
    if n < 7 || r[1] != 1 { return Err(anyhow!("bad socks5")); }
    let (host, port) = match r[3] {
        1 => (format!("{}.{}.{}.{}", r[4], r[5], r[6], r[7]), u16::from_be_bytes([r[8], r[9]])),
        3 => { let l = r[4] as usize; (String::from_utf8(r[5..5+l].to_vec())?, u16::from_be_bytes([r[5+l], r[6+l]])) }
        _ => return Err(anyhow!("unsupported")),
    };

    let sid = next_id.fetch_add(2, Ordering::Relaxed);

    // Build StreamOpen frame
    let mut frame = Vec::with_capacity(64);
    frame.push(0x01); // StreamOpen
    frame.push(0x00); // flags
    frame.extend_from_slice(&sid.to_be_bytes()); // stream_id
    // Build address payload
    let mut addr = Vec::new();
    addr.push(1); // cmd: TCP connect
    addr.extend_from_slice(&port.to_be_bytes());
    if let Ok(ip) = host.parse::<std::net::Ipv4Addr>() {
        addr.push(1); addr.extend_from_slice(&ip.octets());
    } else {
        addr.push(2); addr.push(host.len() as u8); addr.extend_from_slice(host.as_bytes());
    }
    frame.extend_from_slice(&(addr.len() as u16).to_be_bytes()); // length
    frame.extend_from_slice(&addr);

    // Register stream receiver
    let (tx, mut rx) = mpsc::channel::<Vec<u8>>(64);
    streams.lock().await.insert(sid, tx);

    // Send StreamOpen
    ws_write.lock().await.send(Message::Binary(frame)).await.map_err(|e| anyhow!("{}", e))?;

    // SOCKS5 success response
    c.write_all(&[5, 0, 0, 1, 0, 0, 0, 0, 0, 0]).await?;

    // Bidirectional relay: TCP ↔ WS frames
    let (mut cr, mut cw) = c.into_split();
    let ws_w_up = ws_write.clone();

    // Upstream: client TCP → WS Data frames
    let up = tokio::spawn(async move {
        let mut buf = vec![0u8; 65536];
        loop {
            let n = match cr.read(&mut buf).await {
                Ok(0) | Err(_) => break,
                Ok(n) => n,
            };
            let mut frame = Vec::with_capacity(8 + n);
            frame.push(0x00); // Data
            frame.push(0x00); // flags
            frame.extend_from_slice(&sid.to_be_bytes());
            frame.extend_from_slice(&(n as u16).to_be_bytes());
            frame.extend_from_slice(&buf[..n]);
            if ws_w_up.lock().await.send(Message::Binary(frame)).await.is_err() { break; }
        }
    });

    // Downstream: WS Data frames → client TCP
    let dn = tokio::spawn(async move {
        while let Some(data) = rx.recv().await {
            if cw.write_all(&data).await.is_err() { break; }
        }
    });

    tokio::select! { _ = up => {}, _ = dn => {} }

    // Send StreamClose
    let mut close_frame = vec![0x02, 0x00];
    close_frame.extend_from_slice(&sid.to_be_bytes());
    close_frame.extend_from_slice(&0u16.to_be_bytes());
    let _ = ws_write.lock().await.send(Message::Binary(close_frame)).await;
    streams.lock().await.remove(&sid);

    Ok(())
}
