//! OrcaX Multiplexer — manages multiple streams over a single connection
//!
//! One TLS connection carries unlimited concurrent TCP/UDP streams.
//! Each stream has its own flow control window.
//! Stream IDs: odd = client-initiated, even = server-initiated.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::Arc;

use anyhow::{anyhow, Result};
use tokio::sync::mpsc;

use crate::address::TargetAddr;
use crate::orca::{Frame, FrameType};

/// Default window size per stream (256KB)
pub const DEFAULT_WINDOW_SIZE: u32 = 262144;

/// Maximum concurrent streams per connection
pub const MAX_STREAMS: u32 = 256;

/// Stream state
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StreamState {
    Open,
    HalfClosedLocal,
    HalfClosedRemote,
    Closed,
}

/// A single multiplexed stream
#[derive(Debug)]
pub struct MuxStream {
    pub id: u32,
    pub state: StreamState,
    pub target: Option<TargetAddr>,
    pub window_size: AtomicU32,
    pub bytes_sent: u64,
    pub bytes_received: u64,
    /// Is this a TCP or UDP stream?
    pub is_udp: bool,
}

/// Multiplexer — tracks all streams on a connection
pub struct Multiplexer {
    /// Active streams
    streams: HashMap<u32, MuxStream>,
    /// Next stream ID (odd for client, even for server)
    next_stream_id: u32,
    /// Maximum concurrent streams
    max_streams: u32,
}

impl Multiplexer {
    /// Create a server-side multiplexer (even stream IDs)
    pub fn new_server() -> Self {
        Self {
            streams: HashMap::new(),
            next_stream_id: 2, // even = server-initiated
            max_streams: MAX_STREAMS,
        }
    }

    /// Create a client-side multiplexer (odd stream IDs)
    pub fn new_client() -> Self {
        Self {
            streams: HashMap::new(),
            next_stream_id: 1, // odd = client-initiated
            max_streams: MAX_STREAMS,
        }
    }

    /// Open a new stream (returns stream ID)
    pub fn open_stream(&mut self, target: Option<TargetAddr>, is_udp: bool) -> Result<u32> {
        if self.streams.len() >= self.max_streams as usize {
            return Err(anyhow!("max streams reached: {}", self.max_streams));
        }

        let id = self.next_stream_id;
        self.next_stream_id += 2; // skip by 2 (odd/even separation)

        self.streams.insert(id, MuxStream {
            id,
            state: StreamState::Open,
            target,
            window_size: AtomicU32::new(DEFAULT_WINDOW_SIZE),
            bytes_sent: 0,
            bytes_received: 0,
            is_udp,
        });

        Ok(id)
    }

    /// Register a remotely-opened stream
    pub fn register_remote_stream(&mut self, id: u32, target: Option<TargetAddr>, is_udp: bool) -> Result<()> {
        if self.streams.len() >= self.max_streams as usize {
            return Err(anyhow!("max streams reached"));
        }
        if self.streams.contains_key(&id) {
            return Err(anyhow!("stream {} already exists", id));
        }

        self.streams.insert(id, MuxStream {
            id,
            state: StreamState::Open,
            target,
            window_size: AtomicU32::new(DEFAULT_WINDOW_SIZE),
            bytes_sent: 0,
            bytes_received: 0,
            is_udp,
        });

        Ok(())
    }

    /// Close a stream
    pub fn close_stream(&mut self, id: u32) {
        if let Some(stream) = self.streams.get_mut(&id) {
            stream.state = StreamState::Closed;
        }
        self.streams.remove(&id);
    }

    /// Get a mutable reference to a stream
    pub fn get_stream(&mut self, id: u32) -> Option<&mut MuxStream> {
        self.streams.get_mut(&id)
    }

    /// Get stream count
    pub fn stream_count(&self) -> usize {
        self.streams.len()
    }

    /// Check if a stream exists and is open
    pub fn is_open(&self, id: u32) -> bool {
        self.streams.get(&id)
            .map(|s| s.state == StreamState::Open || s.state == StreamState::HalfClosedRemote)
            .unwrap_or(false)
    }

    /// Record bytes sent on a stream
    pub fn record_sent(&mut self, id: u32, bytes: u64) {
        if let Some(stream) = self.streams.get_mut(&id) {
            stream.bytes_sent += bytes;
        }
    }

    /// Record bytes received on a stream
    pub fn record_received(&mut self, id: u32, bytes: u64) {
        if let Some(stream) = self.streams.get_mut(&id) {
            stream.bytes_received += bytes;
        }
    }

    /// Get total bytes across all streams
    pub fn total_bytes(&self) -> (u64, u64) {
        let mut sent = 0u64;
        let mut received = 0u64;
        for stream in self.streams.values() {
            sent += stream.bytes_sent;
            received += stream.bytes_received;
        }
        (sent, received)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::address::{Address, TargetAddr};
    use std::net::Ipv4Addr;

    #[test]
    fn server_mux_even_ids() {
        let mut mux = Multiplexer::new_server();
        let id1 = mux.open_stream(None, false).unwrap();
        let id2 = mux.open_stream(None, false).unwrap();
        assert_eq!(id1, 2); // even
        assert_eq!(id2, 4);
        assert_eq!(mux.stream_count(), 2);
    }

    #[test]
    fn client_mux_odd_ids() {
        let mut mux = Multiplexer::new_client();
        let id1 = mux.open_stream(None, false).unwrap();
        let id2 = mux.open_stream(None, false).unwrap();
        assert_eq!(id1, 1); // odd
        assert_eq!(id2, 3);
    }

    #[test]
    fn close_stream() {
        let mut mux = Multiplexer::new_server();
        let id = mux.open_stream(None, false).unwrap();
        assert!(mux.is_open(id));
        mux.close_stream(id);
        assert!(!mux.is_open(id));
        assert_eq!(mux.stream_count(), 0);
    }

    #[test]
    fn max_streams() {
        let mut mux = Multiplexer::new_server();
        for _ in 0..MAX_STREAMS {
            mux.open_stream(None, false).unwrap();
        }
        assert!(mux.open_stream(None, false).is_err());
    }

    #[test]
    fn byte_tracking() {
        let mut mux = Multiplexer::new_server();
        let id = mux.open_stream(None, false).unwrap();
        mux.record_sent(id, 100);
        mux.record_received(id, 200);
        let (sent, received) = mux.total_bytes();
        assert_eq!(sent, 100);
        assert_eq!(received, 200);
    }

    #[test]
    fn register_remote_stream() {
        let mut mux = Multiplexer::new_server();
        let target = TargetAddr {
            addr: Address::IPv4(Ipv4Addr::new(1, 2, 3, 4)),
            port: 80,
        };
        mux.register_remote_stream(1, Some(target), false).unwrap();
        assert!(mux.is_open(1));
        // Duplicate should fail
        assert!(mux.register_remote_stream(1, None, false).is_err());
    }
}
