//! Brutal Congestion Controller — sends at fixed rate regardless of loss.
//! Matches Hysteria2's approach: speed > fairness.

use std::any::Any;
use std::sync::Arc;
use std::time::Instant;
use quinn::congestion::{Controller, ControllerFactory};
use quinn_proto::RttEstimator;

/// Target bandwidth in bytes/sec. 100 Mbps = 12,500,000 bytes/sec.
const DEFAULT_TARGET_RATE: u64 = 12_500_000;

#[derive(Clone)]
pub struct BrutalController {
    target_rate: u64,
    cwnd: u64,
    mtu: u64,
}

impl BrutalController {
    pub fn new(target_rate: u64) -> Self {
        Self {
            target_rate,
            cwnd: target_rate, // Start at full target — no slow start
            mtu: 1200,
        }
    }
}

impl Controller for BrutalController {
    fn on_sent(&mut self, _now: Instant, _bytes: u64, _last_packet_number: u64) {}

    fn on_ack(&mut self, _now: Instant, _sent: Instant, bytes: u64, _app_limited: bool, rtt: &RttEstimator) {
        // Maintain window at target_rate * RTT (BDP)
        let rtt_secs = rtt.get().as_secs_f64().max(0.01);
        self.cwnd = (self.target_rate as f64 * rtt_secs) as u64;
        self.cwnd = self.cwnd.max(self.mtu * 2); // Minimum 2 MTU
    }

    fn on_end_acks(&mut self, _now: Instant, _in_flight: u64, _app_limited: bool, _largest: Option<u64>) {}

    fn on_congestion_event(&mut self, _now: Instant, _sent: Instant, _is_persistent: bool, lost_bytes: u64) {
        // DON'T reduce window. Instead, INCREASE to compensate for loss.
        // This is Brutal's key insight: if loss = 5%, send 105% of target.
        if lost_bytes > 0 {
            self.cwnd = (self.cwnd as f64 * 1.05) as u64; // 5% boost on loss
        }
    }

    fn on_mtu_update(&mut self, new_mtu: u16) {
        self.mtu = new_mtu as u64;
    }

    fn window(&self) -> u64 { self.cwnd }

    fn clone_box(&self) -> Box<dyn Controller> { Box::new(self.clone()) }

    fn initial_window(&self) -> u64 { self.target_rate } // No slow start

    fn into_any(self: Box<Self>) -> Box<dyn Any> { self }
}

/// Factory for creating Brutal controllers
#[derive(Clone)]
pub struct BrutalFactory {
    target_rate: u64,
}

impl BrutalFactory {
    pub fn new(target_rate: u64) -> Self { Self { target_rate } }
    pub fn default() -> Self { Self { target_rate: DEFAULT_TARGET_RATE } }
}

impl ControllerFactory for BrutalFactory {
    fn build(self: Arc<Self>, _now: Instant, _current_mtu: u16) -> Box<dyn Controller> {
        Box::new(BrutalController::new(self.target_rate))
    }
}
