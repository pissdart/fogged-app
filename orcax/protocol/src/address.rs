use std::net::{Ipv4Addr, Ipv6Addr, SocketAddr, SocketAddrV4, SocketAddrV6};

use anyhow::{anyhow, Result};

/// VLESS address types
#[derive(Debug, Clone, PartialEq)]
pub enum Address {
    IPv4(Ipv4Addr),
    Domain(String),
    IPv6(Ipv6Addr),
}

/// Parsed target address from VLESS request
#[derive(Debug, Clone)]
pub struct TargetAddr {
    pub addr: Address,
    pub port: u16,
}

impl TargetAddr {
    /// Parse target address from VLESS address payload.
    /// Format: port(2 BE) + addr_type(1) + addr(variable)
    /// Returns the parsed address and the number of bytes consumed.
    pub fn parse(data: &[u8]) -> Result<(Self, usize)> {
        if data.len() < 4 {
            return Err(anyhow!("address data too short: {} bytes", data.len()));
        }

        let port = u16::from_be_bytes([data[0], data[1]]);
        let addr_type = data[2];

        let (addr, consumed) = match addr_type {
            // IPv4: 4 bytes
            1 => {
                if data.len() < 7 {
                    return Err(anyhow!("truncated IPv4 address"));
                }
                let ip = Ipv4Addr::new(data[3], data[4], data[5], data[6]);
                (Address::IPv4(ip), 7)
            }
            // Domain: 1 byte length + domain string
            2 => {
                if data.len() < 4 {
                    return Err(anyhow!("truncated domain length"));
                }
                let domain_len = data[3] as usize;
                if data.len() < 4 + domain_len {
                    return Err(anyhow!("truncated domain name"));
                }
                let domain = String::from_utf8(data[4..4 + domain_len].to_vec())
                    .map_err(|_| anyhow!("invalid UTF-8 in domain"))?;
                (Address::Domain(domain), 4 + domain_len)
            }
            // IPv6: 16 bytes
            3 => {
                if data.len() < 19 {
                    return Err(anyhow!("truncated IPv6 address"));
                }
                let mut octets = [0u8; 16];
                octets.copy_from_slice(&data[3..19]);
                let ip = Ipv6Addr::from(octets);
                (Address::IPv6(ip), 19)
            }
            _ => return Err(anyhow!("unknown address type: {}", addr_type)),
        };

        Ok((TargetAddr { addr, port }, consumed))
    }

    /// Convert to a socket address string for connecting
    pub fn to_socket_string(&self) -> String {
        match &self.addr {
            Address::IPv4(ip) => format!("{}:{}", ip, self.port),
            Address::Domain(d) => format!("{}:{}", d, self.port),
            Address::IPv6(ip) => format!("[{}]:{}", ip, self.port),
        }
    }

    /// Convert to SocketAddr if the address is a direct IP
    pub fn to_socket_addr(&self) -> Option<SocketAddr> {
        match &self.addr {
            Address::IPv4(ip) => Some(SocketAddr::V4(SocketAddrV4::new(*ip, self.port))),
            Address::IPv6(ip) => Some(SocketAddr::V6(SocketAddrV6::new(*ip, self.port, 0, 0))),
            Address::Domain(_) => None,
        }
    }
}

impl std::fmt::Display for TargetAddr {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.to_socket_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_ipv4() {
        // port 80 (0x0050), type 1 (IPv4), 127.0.0.1
        let data = [0x00, 0x50, 0x01, 0x7f, 0x00, 0x00, 0x01];
        let (addr, consumed) = TargetAddr::parse(&data).unwrap();
        assert_eq!(addr.port, 80);
        assert_eq!(addr.addr, Address::IPv4(Ipv4Addr::new(127, 0, 0, 1)));
        assert_eq!(consumed, 7);
        assert_eq!(addr.to_socket_string(), "127.0.0.1:80");
    }

    #[test]
    fn parse_domain() {
        // port 443 (0x01BB), type 2 (domain), len 11, "example.com"
        let mut data = vec![0x01, 0xBB, 0x02, 0x0B];
        data.extend_from_slice(b"example.com");
        let (addr, consumed) = TargetAddr::parse(&data).unwrap();
        assert_eq!(addr.port, 443);
        assert_eq!(addr.addr, Address::Domain("example.com".into()));
        assert_eq!(consumed, 15);
        assert_eq!(addr.to_socket_string(), "example.com:443");
    }

    #[test]
    fn parse_ipv6() {
        // port 8080 (0x1F90), type 3 (IPv6), ::1
        let mut data = vec![0x1F, 0x90, 0x03];
        let mut ipv6 = [0u8; 16];
        ipv6[15] = 1; // ::1
        data.extend_from_slice(&ipv6);
        let (addr, consumed) = TargetAddr::parse(&data).unwrap();
        assert_eq!(addr.port, 8080);
        assert_eq!(addr.addr, Address::IPv6(Ipv6Addr::LOCALHOST));
        assert_eq!(consumed, 19);
    }

    #[test]
    fn reject_truncated() {
        let data = [0x00, 0x50]; // only 2 bytes
        assert!(TargetAddr::parse(&data).is_err());
    }

    #[test]
    fn reject_unknown_type() {
        let data = [0x00, 0x50, 0x04, 0x00]; // type 4 doesn't exist
        assert!(TargetAddr::parse(&data).is_err());
    }
}
