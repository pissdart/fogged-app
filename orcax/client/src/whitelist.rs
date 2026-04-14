//! Whitelist/split-tunneling: decide per-connection whether to bypass the VPN.
//!
//! Applied inside the SOCKS5 CONNECT handler. If a destination matches, we
//! connect directly from the client machine to the target (no tunnel), so
//! Russian banks/gov sites that block foreign IPs still work while the VPN
//! is on.
//!
//! Two match paths:
//!  - Domain suffix match (e.g. `host == "vk.com"` or `host.ends_with(".vk.com")`)
//!  - IP CIDR match (when SOCKS5 sends an IP address, not a hostname)

use std::net::IpAddr;
use std::str::FromStr;

use ipnet::IpNet;

/// Default Russian domains bypassed when `--whitelist` is enabled.
/// Subdomains automatically match.
pub const DEFAULT_DOMAINS: &[&str] = &[
    // Social
    "vk.com", "vk.me", "vkontakte.ru", "vk.cc", "userapi.com",
    "ok.ru", "odnoklassniki.ru", "mycdn.me",
    // Email
    "mail.ru", "list.ru", "inbox.ru", "bk.ru",
    // Yandex
    "yandex.ru", "yandex.com", "yandex.net", "ya.ru", "yandex.st", "yastatic.net",
    // Banks
    "sberbank.ru", "online.sberbank.ru", "sber.ru", "sbrf.ru",
    "tinkoff.ru", "tbank.ru",
    "alfabank.ru", "alfa-bank.ru",
    "vtb.ru", "vtb24.ru",
    "gazprombank.ru", "raiffeisen.ru", "open.ru", "psb.ru",
    // Government
    "gosuslugi.ru", "mos.ru", "gov.ru", "kremlin.ru", "nalog.ru", "nalog.gov.ru",
    // News
    "ria.ru", "tass.ru", "rt.com", "rbc.ru", "kommersant.ru", "lenta.ru",
    // E-commerce / delivery
    "wildberries.ru", "wb.ru", "ozon.ru", "ozone.ru", "avito.ru", "yandex.market",
    "lamoda.ru", "dns-shop.ru", "citilink.ru",
    // Streaming
    "rutube.ru", "dzen.ru", "kinopoisk.ru", "okko.tv", "ivi.ru",
    // Telecom
    "megafon.ru", "mts.ru", "beeline.ru", "tele2.ru", "rostelecom.ru",
    // Corporate
    "gazprom.ru", "rosneft.ru", "sibur.ru", "lukoil.ru",
];

/// Major Russian service CIDRs. Used when SOCKS5 clients skip DNS resolution
/// and send us a raw IP. Not exhaustive — domain matching covers most cases.
pub const DEFAULT_CIDRS: &[&str] = &[
    // Yandex
    "5.45.192.0/18", "5.255.192.0/18", "37.9.64.0/18", "37.140.128.0/18",
    "77.88.0.0/18", "87.250.224.0/19", "93.158.128.0/18", "95.108.128.0/17",
    "141.8.128.0/18", "178.154.128.0/18", "213.180.192.0/19",
    // VK (Mail.ru group)
    "87.240.128.0/18", "87.240.190.0/24", "95.213.0.0/16",
    "185.225.76.0/22", "185.32.184.0/22",
    "95.163.32.0/19", "94.100.176.0/20", "217.69.128.0/20",
    // Sberbank / SberTech
    "194.186.207.0/24", "195.218.190.0/23", "213.171.32.0/19",
    // MTS
    "213.87.0.0/16", "95.106.0.0/17",
    // Megafon
    "83.149.0.0/16", "188.130.0.0/17",
    // Beeline / VimpelCom
    "85.140.0.0/16", "213.234.192.0/19",
    // Rostelecom
    "81.23.0.0/17", "195.98.64.0/19",
    // Gosuslugi (Rostelecom-hosted)
    "89.169.16.0/24", "194.54.14.0/24",
];

/// Resolver over domains + user-provided extras + IP CIDRs.
#[derive(Clone)]
pub struct Whitelist {
    domains: Vec<String>,
    cidrs: Vec<IpNet>,
}

impl Whitelist {
    /// Build a whitelist from the compiled-in defaults plus optional user extras.
    ///
    /// `extra` is a comma-separated list ("vk.com,custom.ru"). Malformed entries
    /// are silently dropped.
    pub fn new(extra: Option<&str>) -> Self {
        let mut domains: Vec<String> =
            DEFAULT_DOMAINS.iter().map(|s| s.to_ascii_lowercase()).collect();

        if let Some(s) = extra {
            for e in s.split(',') {
                let e = e.trim().to_ascii_lowercase();
                if !e.is_empty() && e.contains('.') && !domains.contains(&e) {
                    domains.push(e);
                }
            }
        }

        let cidrs: Vec<IpNet> = DEFAULT_CIDRS
            .iter()
            .filter_map(|c| IpNet::from_str(c).ok())
            .collect();

        Self { domains, cidrs }
    }

    /// True when the destination should bypass the VPN.
    ///
    /// Accepts either a hostname or a literal IP. Host matching is a suffix
    /// test so subdomains are covered automatically.
    pub fn matches(&self, host: &str) -> bool {
        if let Ok(ip) = host.parse::<IpAddr>() {
            return self.matches_ip(ip);
        }
        let host = host.to_ascii_lowercase();
        for d in &self.domains {
            if host == *d || host.ends_with(&format!(".{}", d)) {
                return true;
            }
        }
        false
    }

    /// IP-only variant for the SOCKS5 IPv4/IPv6 address types.
    pub fn matches_ip(&self, ip: IpAddr) -> bool {
        self.cidrs.iter().any(|c| c.contains(&ip))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exact_domain_matches() {
        let w = Whitelist::new(None);
        assert!(w.matches("vk.com"));
        assert!(w.matches("yandex.ru"));
        assert!(w.matches("sberbank.ru"));
    }

    #[test]
    fn subdomains_match() {
        let w = Whitelist::new(None);
        assert!(w.matches("m.vk.com"));
        assert!(w.matches("login.mos.ru"));
        assert!(w.matches("online.sberbank.ru"));
    }

    #[test]
    fn suffix_attack_doesnt_match() {
        let w = Whitelist::new(None);
        // vk.com.evil.com must NOT match vk.com
        assert!(!w.matches("vk.com.evil.com"));
        assert!(!w.matches("evilvk.com"));
    }

    #[test]
    fn non_whitelisted_doesnt_match() {
        let w = Whitelist::new(None);
        assert!(!w.matches("youtube.com"));
        assert!(!w.matches("google.com"));
        assert!(!w.matches("netflix.com"));
    }

    #[test]
    fn extras_are_respected() {
        let w = Whitelist::new(Some("custom.ru,another.example"));
        assert!(w.matches("custom.ru"));
        assert!(w.matches("sub.custom.ru"));
        assert!(w.matches("another.example"));
    }

    #[test]
    fn malformed_extras_ignored() {
        // No dot, empty, whitespace
        let w = Whitelist::new(Some("nodot,,   "));
        assert!(!w.matches("nodot"));
    }

    #[test]
    fn ip_cidr_matches() {
        let w = Whitelist::new(None);
        // Yandex range
        assert!(w.matches("77.88.55.60"));
        // Not in any CIDR
        assert!(!w.matches("8.8.8.8"));
    }

    #[test]
    fn case_insensitive() {
        let w = Whitelist::new(Some("CASE.RU"));
        assert!(w.matches("Case.RU"));
        assert!(w.matches("sub.CASE.ru"));
    }
}
