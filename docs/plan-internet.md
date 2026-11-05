# Plan: reaching an XPRS server from the internet, with nobody touching the router

Status: plan, nothing built. Decisions **(N1)…(N4)** are open, listed at the end.
Revised 2026-11-05: existing public services, not infrastructure of our own.

## 1. The goal

Someone opens `https://2a02-908-2616-da20-…-d505.nip.io` (or scans it from a
QR code) and gets this server's web chat, from any network. The operator
does nothing beyond installing the server: no port forwarding, no DNS
account, no certificate work. No name service, domain or relay that XPRS has
to run.

## 2. The pieces that already exist

| Need | Service | What it costs us |
|---|---|---|
| **A name for an IPv6 address** | [nip.io](https://nip.io/) (sslip.io is the same service and now redirects to it): a wildcard DNS that computes the answer from the name. IPv6 is written with dashes: `2a01-4f8-c17-b8f--2.nip.io` → `2a01:4f8:c17:b8f::2` | nothing: no account, no registration, nothing stored. The server just builds the name from its own address |
| **A certificate for that name** | Let's Encrypt, HTTP-01 or TLS-ALPN-01, for the single hostname (nip.io supports this; it has no wildcard) | an ACME client in the server. nip.io names share one Let's Encrypt quota, which LE has raised to 250,000 over the years; sslip.io is the documented second domain if nip.io's runs out |
| **A certificate with no name at all** | Let's Encrypt **IP address certificates**, generally available since January 2026, IPv4 and IPv6, always short-lived (about 6 days), HTTP-01 or TLS-ALPN-01 only | the same ACME client with the `shortlived` profile, renewing every few days. Then `https://[2a02:908:…]/` works with no DNS involved |
| **Proof the server is reachable** | the Let's Encrypt validation itself: LE connects to the name from outside. A certificate issued means the internet can reach this server | nothing extra: the first issuance IS the reachability test |

## 3. What these do NOT solve: the router's firewall

A name only tells a browser where to go. IPv6 has no NAT, but the router
still drops inbound connections unless a hole is open, and Let's Encrypt
must get in too. This network (measured: Vodafone cable, AVM FRITZ!Box 6690):

- the server has a public, global IPv6 address;
- the FRITZ!Box offers UPnP IGDv2 `WANIPv6FirewallControl` (and PCP), so the
  server can open its own pinhole for 443 automatically, but **only if the
  device's "permit independent port sharing" switch is on, which it is not by
  default**;
- some ISPs' routers do not firewall inbound IPv6 at all, so there it simply
  works.

So direct reachability is automatic where the router allows it, and needs that
one switch on a default FRITZ!Box. For the case where nothing can be opened,
there are two fallbacks (**N1**):

| Fallback | How | For | Against |
|---|---|---|---|
| **Cloudflare Quick Tunnel** | `cloudflared tunnel --url http://localhost:80`: no account; the server dials out and gets a random `https://<words>.trycloudflare.com` with a valid certificate | nothing to build or run; works behind any NAT, IPv4 and IPv6 | Cloudflare calls it testing-only, with no uptime guarantee; about 200 requests in flight; a new random name on every restart; Cloudflare terminates TLS and sees the traffic; a non-Dart binary to ship |
| **An XPRS server as relay** | a reachable XPRS server fronts the others over the Reticulum link they already hold outbound | ours, no third party; stable | has to be built (the biggest piece of work here), and somebody has to run reachable relays |

## 4. How the server does it, start to finish

1. **Address.** List global IPv6 addresses; choose a stable one (an RFC 7217
   stable-privacy address, not the EUI-64 one, which carries the network
   card's MAC into every link and QR code). Build the name:
   `2a02-908-2616-da20-xxxx-xxxx-xxxx-xxxx.nip.io`.
2. **Open the door.** Ask the router for a pinhole on 443 (and 80 for the
   redirect) by UPnP IGDv2 `AddPinhole`, then PCP; leased for a few hours and
   renewed, so a stopped server closes its own hole. Refused or no router
   answering: carry on, step 3 will tell.
3. **Certificate.** ACME HTTP-01 / TLS-ALPN-01 for the nip.io name (90 days),
   or an IP certificate (6 days) (**N2**). Success means reachable: serve
   HTTPS on 443 and redirect 80 to it. Failure means not reachable from
   outside: use the fallback (N1), and log one plain line saying why, for
   example "router refused the IPv6 pinhole: turn on 'permit independent port
   sharing' for this device, or the server stays on the relay".
4. **Renumbering.** Cable providers change the /64 prefix now and then. The
   server watches its addresses; a new one means a new name, a new pinhole and
   a new certificate (minutes). Old links stop working, which is why the
   stable way to find a server is its callsign (step 5).
5. **Say where it is.** The server puts its current URL in its signed
   announcement (`url:`, a field XPRS.md already uses to name a source) and
   re-airs it whenever it changes. XPRS apps that know the callsign always
   reach the current address; the webchat page and the app show the link and
   QR code.

## 5. Limits to know

- **IPv4-only visitors cannot reach an IPv6 address.** Most mobile and home
  networks in Germany are dual-stack now, but not all, and many abroad are not.
  Where the WAN IPv4 is public (it is here: `178.202.105.29`), UPnP/PCP can map
  443 on IPv4 too, and nip.io names IPv4 the same way; behind carrier NAT only
  the fallback reaches them.
- **The name follows the address.** A nip.io link breaks when the prefix
  changes. A name that survives renumbering needs a dynamic DNS account
  ([deSEC](https://desec.io)'s free `dedyn.io`, IPv6 and DNS-01 included), a
  one-time sign-up by the operator: offered as an option (**N3**), never
  required.
- **nip.io and Let's Encrypt are third parties.** Both are long-running and
  free; neither promises anything. The server must keep working on the LAN and
  over Reticulum when either is down; the internet page is an addition.

## 6. Phases

1. **Reachability report.** Addresses, the nip.io name, UPnP/PCP pinhole and
   IPv4 mapping attempts, reported in the log and `/api/status`. Testable here
   today against the FRITZ!Box.
2. **HTTPS.** An ACME client in Dart (HTTP-01 and TLS-ALPN-01), certificates in
   the data directory, renewal, 443 plus the 80 redirect, the staging endpoint
   in tests (a crash-looping server must not burn the shared nip.io quota).
3. **Announce the URL** (`url:` on the signed announcement) and show it in the
   webchat page and the app, with a QR code.
4. **Fallback** per N1.

## 7. Decisions for you

- **N1** When the router cannot be opened: Cloudflare Quick Tunnel (quick to
  add, but third-party, testing-only and a random name per restart), an XPRS
  relay (ours, but to be built and run), or neither for now (the server is
  reachable on LAN and Reticulum only).
- **N2** Certificate: the nip.io hostname (recommended: 90-day certificates,
  a name a person can paste), or the bare IP-address certificate (no DNS
  dependency at all, renewed every few days, `https://[v6]/` in the bar).
- **N3** Offer a deSEC `dedyn.io` name as an optional stable address for
  operators willing to sign up once, or not.
- **N4** Open the router automatically by UPnP/PCP when it allows it
  (recommended), or never touch the router, even when it would allow it.

## Sources

- nip.io / sslip.io: https://nip.io/
- Let's Encrypt, short-lived and IP address certificates GA:
  https://letsencrypt.org/2026/01/15/6day-and-ip-general-availability
- Cloudflare Quick Tunnels:
  https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/trycloudflare/
- deSEC dynDNS: https://desec.readthedocs.io/en/latest/dyndns/configure.html
