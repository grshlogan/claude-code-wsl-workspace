// Claude-only profile: no Windows proxy, no browser-level alternative DNS.
user_pref("network.proxy.type", 0);
user_pref("network.trr.mode", 5);
user_pref("network.dns.disableIPv6", true);
user_pref("network.dns.disablePrefetch", true);
user_pref("network.predictor.enabled", false);
user_pref("media.peerconnection.enabled", false);
user_pref("browser.shell.checkDefaultBrowser", false);
