# Plan: reaching an XPRS server from the internet, deployed anywhere

Status: plan, nothing built. Decisions **(N1)…(N4)** are open, listed at the end.
Revised 2026-11-05 (third version): **outbound connections only.**

## 1. The goal and the constraint

Anybody installs the server on any machine (a Pi at home, a laptop on hotel
WiFi, a box behind carrier NAT) and it gets a public `https://` address for its
web chat. Nobody opens a port, configures a router, or signs up for anything.

That rules out every inbound path, UPnP and PCP included: they work only where
a router happens to allow them, and a design for "anywhere" cannot count on
that. The only thing every network allows is **a connection the server makes
outward**. So the public address must live on a machine that IS reachable,
and that machine carries visitors to the server over a connection the server
opened. That is a relay, whoever runs it.

## 2. The design: XPRS servers relay for each other

Some XPRS servers are reachable: deployed on a VPS or behind a router somebody
did open. They already run the same binary. Such a server offers to front
others; every other server keeps an outbound link to one of them.

```
browser ──https──▶ relay (public IP, port 443) ══ Reticulum link, opened by the home server ══▶ home server
                   x3qhn4.<relay-ip>.nip.io                                         (any network)
```

### 2.1 The link

The home server adds the relay as an ordinary Reticulum uplink (TCP to
`relay:4242`), which `RnsService.connectUplink` already does for public hubs.
It is outbound, so it works from anywhere, and it is the link the server would
keep anyway. Over it the server opens a Reticulum link to the relay's web
destination and registers its callsign with a signed request (the callsign
derives from the key, so only the real X3QHN4 can claim the name).

### 2.2 The name: nip.io under the relay's address, no domain of ours

nip.io resolves any prefix in front of an address, so a relay at
`203.0.113.7` serves every home under its own address with no DNS to run:

```
x3qhn4.203-0-113-7.nip.io      → 203.0.113.7  (the relay; it routes by name)
x3qhn4.2001-db8--7.nip.io      → 2001:db8::7  (the same relay over IPv6)
```

The relay routes on the TLS SNI, the name the browser asked for, to the link
that callsign registered.

### 2.3 TLS stays end to end

- **443:** the relay does not decrypt. It reads the SNI and copies the TLS
  stream to the home server over the link. The home server holds the
  certificate and the key; the relay sees which name and how many bytes,
  nothing more.
- **The certificate:** the home server asks Let's Encrypt for
  `x3qhn4.203-0-113-7.nip.io` by HTTP-01. Let's Encrypt connects to the relay
  on port 80; the relay passes `/.well-known/acme-challenge/` for that name
  down the link, and the home server answers it. The certificate is issued
  to the home server, which never had a port open.
- **80:** otherwise just a redirect to 443.

### 2.4 Finding a relay

- A server that can be reached from outside offers relaying in its signed
  announcement (`serve:relay,web`; `serve:relay` is already XPRS vocabulary,
  `web` is new: **N3**), heard over the Reticulum hubs every server already
  uses. Being reachable is proven the same way the home server's certificate
  is: the relay's own Let's Encrypt validation succeeds.
- A home server picks the relay with the best path and spare quota, keeps a
  second as standby, and moves when one stops answering. Its name changes with
  the relay (the relay's address is in it), which is why it also announces its
  current URL (2.5).
- Until enough people run relays, the project runs two or three on small VPSs
  (**N2**). The relay is the same server binary with the role on.

### 2.5 Telling people where it is

The server puts its current URL in its signed announcement (`url:`, a field
XPRS.md already uses to name a source) and re-airs it when it changes. XPRS
apps find a server by callsign; the webchat page and the app show the link and
a QR code.

## 3. Costs and limits

- **Bandwidth through the relay** is the web chat's: a 35 kB page (gzipped)
  and short JSON. A small VPS fronts many homes. Relays announce a per-home
  quota (bytes, concurrent visitors) and enforce it.
- **Latency**: one extra hop through the relay. Fine for chat.
- **Relays are someone's machine**: with SNI passthrough they cannot read
  the traffic, but they can refuse to carry it or log who visited which name.
  Being able to switch relays (and run your own) is the answer.
- **Let's Encrypt**: nip.io names share one LE quota (LE has raised it to
  250,000 over the years). sslip.io is the documented second domain. A relay
  with its own domain can offer names under that instead. Tests must use LE's
  staging endpoint.
- **IPv4 and IPv6**: a relay with both reaches every visitor, whatever the
  home server's network has.

## 4. Ready-made tunnels, compared

Used for development, or as a bootstrap before any XPRS relay exists (**N1**):

| Service | Account | Name | Limits | TLS |
|---|---|---|---|---|
| Cloudflare Quick Tunnel (`trycloudflare.com`) | none | random, new on each restart | "testing and development only", no uptime promise, about 200 requests in flight | Cloudflare terminates it and can read the traffic |
| localhost.run (over ssh) | none | random, rotates after a few hours on the free tier | speed-limited on free | the service terminates it |
| Pinggy (over ssh) | none | random | free sessions end after 60 minutes | the service terminates it |

None of them gives a stable name, a promise to stay up, or end-to-end TLS on
the free tier, and each is one company's goodwill. Good for trying it out;
not something to ship as the way XPRS servers are reached.

## 5. Phases

1. **Relay link, HTTP only.** The relay role (`serve:relay,web`), the
   registration over a Reticulum link, routing by Host header, plain HTTP.
   Proves the path end to end with two machines (this Pi plus any VPS).
2. **TLS passthrough.** Routing by SNI, the ACME HTTP-01 pass-through, an ACME
   client in the home server, certificates in the data directory.
3. **Discovery and failover.** Picking a relay from announcements, standby,
   quotas, the announced `url:` and its QR code in the page and the app.
4. **Bootstrap relays** run by the project (N2), and the README line "it is
   on the internet at …" for a fresh install.

## 6. Decisions for you

- **N1** A ready-made tunnel (Cloudflare Quick Tunnel) as a temporary
  fallback until XPRS relays exist, or XPRS relays only from the start
  (recommended: fewer moving parts, no third party reading the traffic).
- **N2** Who runs the first relays: the project, on two or three small VPSs
  (recommended), or only volunteers.
- **N3** Spec words: `serve:relay,web` and `url:` on the announcement, plus
  the registration exchange, go into XPRS.md first.
- **N4** A home server whose own network does allow inbound connections:
  serve directly (its own nip.io name from its own address) and skip the relay,
  or always use the relay so every server works the same way.

## Sources

- nip.io / sslip.io: https://nip.io/
- Let's Encrypt, short-lived and IP address certificates GA:
  https://letsencrypt.org/2026/01/15/6day-and-ip-general-availability
- Cloudflare Quick Tunnels:
  https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/trycloudflare/
- Free tunnel comparison (vendor-written, limits to recheck):
  https://merginit.com/blog/19062026-free-developer-tunnels-comparison
