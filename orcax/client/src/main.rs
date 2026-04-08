mod brutal;
use std::collections::HashMap;
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};
use std::sync::Arc;
use anyhow::{anyhow, Result};
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

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().collect();
    let sa = arg(&args, "--server").unwrap_or("204.168.171.253:9444".into());
    let sk = arg(&args, "--socks").unwrap_or("127.0.0.1:1080".into());
    let protocol = arg(&args, "--protocol").unwrap_or("tcp".into());

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
        run_quic_mode(&sa, &sk, &args).await;
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
    loop {
        let (c, _) = match l.accept().await { Ok(v) => v, Err(_) => continue };
        let mux = mux.clone();
        let bu = bu.clone();
        tokio::spawn(async move { let _ = handle_socks5(c, &mux, &bu).await; });
    }
}

async fn handle_socks5(mut c: TcpStream, mux: &MuxPool, bu: &Arc<AtomicU64>) -> Result<()> {
    c.set_nodelay(true)?;
    let mut b = [0u8; 258];
    tokio::time::timeout(std::time::Duration::from_secs(5), c.read(&mut b)).await
        .map_err(|_| anyhow!("socks5 timeout"))??;
    c.write_all(&[5, 0]).await?;
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
    let conn = match endpoint.connect(addr, "orcax.local") {
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

async fn run_quic_mode(sa: &str, sk: &str, args: &[String]) {
    dlog(&format!("QUIC mode → {}", sa));

    // QUIC client: post-quantum TLS (ML-KEM + X25519 hybrid)
    let client_config = {
        let crypto = quinn::rustls::crypto::aws_lc_rs::default_provider();
        let tls = quinn::rustls::ClientConfig::builder_with_provider(crypto.into())
            .with_safe_default_protocol_versions().unwrap()
            .dangerous().with_custom_certificate_verifier(Arc::new(QuicNV))
            .with_no_client_auth();
        let mut cc = quinn::ClientConfig::new(Arc::new(quinn::crypto::rustls::QuicClientConfig::try_from(tls).unwrap()));
        // BBR for client (smart probing), server uses Brutal (aggressive sending)
        let mut transport = quinn::TransportConfig::default();
        transport.congestion_controller_factory(Arc::new(quinn::congestion::BbrConfig::default()));
        transport.max_idle_timeout(Some(quinn::IdleTimeout::from(quinn::VarInt::from_u32(300_000))));
        transport.keep_alive_interval(Some(std::time::Duration::from_secs(15)));
        transport.stream_receive_window(quinn::VarInt::from_u32(8_000_000)); // 8MB per stream
        transport.receive_window(quinn::VarInt::from_u32(16_000_000)); // 16MB total
        transport.send_window(8_000_000); // 8MB send buffer
        cc.transport_config(Arc::new(transport));
        cc
    };

    let mut endpoint = quinn::Endpoint::client("0.0.0.0:0".parse().unwrap()).unwrap();
    endpoint.set_default_client_config(client_config);

    let addr: std::net::SocketAddr = sa.parse().unwrap_or_else(|_| {
        let parts: Vec<&str> = sa.split(':').collect();
        format!("{}:{}", parts[0], parts.get(1).unwrap_or(&"9444")).parse().unwrap()
    });

    // Initial connection
    let conn = match quic_connect_and_auth(&endpoint, addr, args).await {
        Some(c) => c,
        None => { emit("error", Some("QUIC connection failed")); return; }
    };

    let l = match TcpListener::bind(sk).await { Ok(l) => l, Err(e) => { emit("error", Some(&format!("{}", e))); return; } };
    emit("connected", Some(sk));

    let conn = Arc::new(tokio::sync::RwLock::new(conn));

    // Spawn connection health monitor — reconnects on failure
    let conn_monitor = conn.clone();
    let endpoint_clone = endpoint.clone();
    let args_owned: Vec<String> = args.to_vec();
    tokio::spawn(async move {
        loop {
            // Check if connection is alive
            tokio::time::sleep(std::time::Duration::from_secs(5)).await;
            let is_dead = {
                let c = conn_monitor.read().await;
                c.close_reason().is_some()
            };
            if !is_dead { continue; }

            // Connection died — reconnect with exponential backoff
            emit("reconnecting", None);
            dlog("connection lost, reconnecting...");
            let mut delay = 1u64;
            loop {
                if let Some(new_conn) = quic_connect_and_auth(&endpoint_clone, addr, &args_owned).await {
                    let mut c = conn_monitor.write().await;
                    *c = new_conn;
                    emit("connected", Some("127.0.0.1:1080"));
                    dlog("reconnected");
                    break;
                }
                dlog(&format!("reconnect failed, retry in {}s", delay));
                tokio::time::sleep(std::time::Duration::from_secs(delay)).await;
                delay = (delay * 2).min(30);
            }
        }
    });

    // Accept SOCKS5 connections, using current connection
    loop {
        let (c, _) = match l.accept().await { Ok(v) => v, Err(_) => continue };
        let conn = conn.clone();
        tokio::spawn(async move {
            let conn_guard = conn.read().await;
            if conn_guard.close_reason().is_some() {
                drop(conn_guard);
                // Connection dead, wait briefly for reconnect
                tokio::time::sleep(std::time::Duration::from_millis(500)).await;
                let conn_guard = conn.read().await;
                if conn_guard.close_reason().is_some() { return; } // Still dead
                let _ = quic_socks5(c, &conn_guard).await;
            } else {
                let _ = quic_socks5(c, &conn_guard).await;
            }
        });
    }
}

async fn quic_socks5(mut c: TcpStream, conn: &quinn::Connection) -> Result<()> {
    c.set_nodelay(true)?;
    let mut b = [0u8; 258]; c.read(&mut b).await?; c.write_all(&[5, 0]).await?;
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
