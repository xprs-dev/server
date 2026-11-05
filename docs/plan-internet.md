# Plan: a public name for every XPRS server, by dynamic DNS

Status: plan, nothing built. Decisions **(N1)…(N4)** are open, listed at the end.
Revised 2026-11-05 (fourth version): dynamic DNS, set up by the server itself.

## 1. The goal

A server installed anywhere names itself on the internet, with no person
involved: it claims a dynamic DNS name (its callsign where free:
`x3qhn4.freemyip.com`), keeps the name pointed at its current addresses as the
ISP renumbers them, gets a certificate for it, and announces it. The operator
does nothing.

## 2. Dynamic DNS services a program can use (checked 2026-11-05)

| Service | Claiming a name | IPv6 | TXT (not needed: certificates use HTTP-01) | Keeping it |
|---|---|---|---|---|
| **freemyip.com** | "No login required": pick a free name and get a token. No captcha on the claim form. **Not yet confirmed** that the whole claim works from a program: needs one test claim (**N1**) | `&myip=` takes an IPv6 address | `&txt=` sets/clears a TXT record | one update a year; a deleted name is blocked for 12 months |
| **myaddr** (`myaddr.tools` / `.dev` / `.io`) | no account, no personal data, but the claim page has a Cloudflare Turnstile challenge: **a person claims once**, then the server holds the key | `ip=` any v4/v6, one of each | `acme_challenge=`, served on `_acme-challenge`, removed after a few minutes | update each address every 90 days; released after 120 days without updates |
| **DuckDNS, deSEC (`dedyn.io`), dynv6** | an account a person creates; the server then takes a token | yes | yes | per service |
| **nip.io** | nothing to claim: the address is written in the name (`2a02-908-…-d505.nip.io`) | yes | no (no records to set) | nothing to keep, but the name changes with the address |
| ~~dyn.direct~~ | automatic claim by API, but the service is gone (its name no longer resolves; code untouched since 2023) | | | |

So freemyip is the one that may be fully automatic, myaddr is automatic after a
single human step, and the account-based ones need an operator who wants them.
The server supports them behind one interface, tries them in an order (**N1**),
and nip.io is the name it always has even before any claim.

## 3. How the server does it

1. **Addresses.** List global IPv6 addresses and choose a stable one: an RFC
   7217 stable-privacy address, not EUI-64, which carries the network card's
   MAC into DNS. IPv4 goes in only when the machine's own address is public
   (no NAT in front of it).
2. **Claim, once.** Ask the provider for the callsign (`x3qhn4`); if taken,
   the callsign plus a short suffix. Store the provider's token or key in the
   data directory (0600). It is the name's only credential: lose it and the
   name is gone, so it goes in the identity backup too.
3. **Keep it pointed.** Update the AAAA (and A) record when an address
   changes, and at the provider's minimum interval otherwise (a year for
   freemyip, 90 days for myaddr). The address watch is the host's job, cheap,
   and outside the core.
4. **Certificate.** Let's Encrypt by **HTTP-01** (corrected 2026-11-05: the
   earlier DNS-01/TXT design was unnecessary): the server answers the
   challenge itself on port 80, so no provider TXT API is needed and any
   name that resolves to the server works. The certificate is only useful
   once the server is reachable, which HTTP-01 already requires. It renews
   automatically.
5. **Serve.** HTTPS on 443 with the page and the visitor API; port 80
   redirects.
6. **Announce.** The current URL goes in the server's signed announcement
   (`url:`, a field XPRS.md already uses to name a source), so XPRS apps find
   it by callsign; the webchat page and the app show the link and a QR code.

## 4. What a name does not do

DNS says where the server is; it cannot let anyone through a firewall. On IPv6
there is no NAT, so whether a visitor gets in depends only on the router
admitting inbound connections to that address:

- routers that admit inbound IPv6: it works with nothing else done;
- routers that block by default (the FRITZ!Box here does): the name, the
  certificate and the announcement are all correct, and visitors still time
  out until that router admits port 443;
- IPv4 behind NAT: unreachable by any name.

The server should say which case it is in rather than look healthy. Checking
needs someone outside: another XPRS station (a phone on mobile data, another
server) tries the name and reports back, over Reticulum, with a signed answer.
The log then says "published as https://x3qhn4.freemyip.com/; reachable from
outside: yes/no", and the status API carries the same.

Whether the server may ask the router to admit 443 itself, by UPnP IGDv2/PCP
where the router permits it (no operator action), is **N3**.

## 5. Phases

1. **Name.** The provider interface, freemyip and myaddr (and the
   token-based ones), nip.io always; claim, store, update on address change;
   the name in the log and `/api/status`. Testable here.
2. **Certificate and HTTPS.** An ACME client in Dart for HTTP-01 (served on
   port 80); the staging endpoint in tests; 443 plus the 80 redirect.
3. **Announce and show.** `url:` in the signed announcement; link and QR in the
   page and the app.
4. **Reachability check.** The signed connect-back by another XPRS station,
   and the plain statement in the log.

## 6. Decisions for you

- **N1** Default provider: freemyip first, if one test claim confirms a
  program can claim without a person (I have not claimed anything; it would
  register a real name on their service), then myaddr with a one-time human
  claim, then account tokens. Or another order.
- **N2** The name itself: the callsign (`x3qhn4.freemyip.com`, recommended:
  the same name the mesh uses), or a name the operator picks.
- **N3** On routers that permit it, let the server admit port 443 to itself
  by UPnP/PCP automatically (no operator action), or never touch the router.
- **N4** Also publish the nip.io name, which needs no provider and no claim but
  breaks when the address changes, or only the claimed name.

## Sources

- freemyip: https://freemyip.com/ and https://freemyip.com/help
- myaddr: https://myaddr.tools
- dyn.direct (dead): https://github.com/csnewman/dyndirect
- nip.io: https://nip.io/
- Let's Encrypt (HTTP-01; IP and short-lived certificates):
  https://letsencrypt.org/2026/01/15/6day-and-ip-general-availability

## Findings 2026-11-05 (investigation of free name options, station X3PTZM)

Network facts on the Pi (FRITZ!Box 6690 Cable): WAN IPv4 178.202.105.29 is public (equals the egress address, not CGNAT); no UPnP port mappings exist yet; the router offers UPnP IGD (`WANIPConnection:2`) and `WANIPv6FirewallControl:1` (IPv6 pinholes). Global IPv6 is SLAAC/EUI-64 on 2a02:908:2616:da20::/64: the interface id is stable, the /64 prefix may change. **The web chat binds `0.0.0.0` only (config `http_address`, default in server_config.dart) so nothing answers on IPv6 yet; `http_address: '::'` would make it dual-stack.**

Provider findings (read from their own pages):
- **freemyip.com**: availability check works from a program (POST /website subdomain=x3ptzm -> "available"), but the claim step is behind Google reCAPTCHA: a person must claim. x3ptzm.freemyip.com is free. N1 resolved: not fully automatic.
- **ipq.co / fdns.uk**: form POST /records, no captcha, IPv4+IPv6, free label (x3ptzm.ipq.co). But static: no update API ("once we implement it"), no TXT, "records owned by ipq.co, can be removed at any time". A 2010 hobby project (Rails 3); history of a Safe Browsing flag. Weak for long-term use.
- **nip.io / sslip.io / backname.io / traefik.me**: IP embedded in the name, nothing to claim, no custom label. IPv6 with dashes. No TXT/wildcard certs, but per-hostname HTTP-01 certs work. White-label needs an own domain (rejected).
- **afraid.org FreeDNS**: 22,966 shared domains, free label, dynamic update `curl https://v6.sync.afraid.org/u/<token>/` for IPv6, web forwarding. Signup needs name+email+image captcha+activation email (a person, once). TXT only via the web UI, no ACME API found.
- **Let's Encrypt IP-address certs** (GA 2026-01-15): IPv4/IPv6, must use the `shortlived` profile (~6 days), only http-01 and tls-alpn-01 (no DNS-01). Needs port 80/443 reachable, no name at all.
- **ACME**: HTTP-01 on port 80 covers any named host. TXT records/DNS-01 are irrelevant to provider choice (only wildcards would need them, and we do not).

## Status 2026-11-05 (later)
- Server now binds `::` (`/etc/xprs-server/config.yaml`, `http_address: "::"`).
- The user opened IPv4 port 80 on the FRITZ!Box themselves; `http://178-202-105-29.nip.io/` serves the web chat from outside. The FRITZ!Box has IPv6 pinholes disabled (UPnP `InboundPinholeAllowed=0`) and needs an admin login to change: not available to the agent. The LAN resolver also drops nip.io answers (rebind protection).
- Next: HTTP-01 ACME client (Let's Encrypt) in the server, then 443.

## Built 2026-11-05
`core/lib/src/connections/internet/public_name/` (moved to the core so the app
can serve HTTPS on Android/desktop too), wired in `server/bin/xprs_server.dart`
behind `public_name`, `https_port`, `upnp`, `acme_email`, `acme_staging`.
First run on the Pi: IPv6 name unreachable (router), IPv4 name reachable on 80
and 443, real certificate issued, https://178-202-105-29.nip.io/ live.
Not done yet: `url:` in the signed announcement; the app's share server as an
`AcmeWebServer`.
