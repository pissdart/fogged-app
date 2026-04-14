//! OrcaX Pro Max Client Library
//!
//! Connects to OrcaX servers via Reality TLS + native OrcaX protocol.
//! Handles Passthrough command for wire-speed relay.
//!
//! Usage from Flutter (via FFI):
//!   1. orcax_connect(server, port, uuid, server_pubkey) → handle
//!   2. orcax_open_stream(handle, host, port) → stream_id
//!   3. orcax_send(handle, stream_id, data) / orcax_recv(handle, stream_id) → data
//!   4. orcax_disconnect(handle)

mod tunnel;
pub mod whitelist;

pub use tunnel::{OrcaXTunnel, TunnelConfig, TunnelState};
pub use whitelist::Whitelist;

/// C FFI for Flutter — simple connect/disconnect interface.
/// The Flutter app calls these via dart:ffi.
#[no_mangle]
pub extern "C" fn orcax_version() -> u32 {
    1 // Protocol version
}
