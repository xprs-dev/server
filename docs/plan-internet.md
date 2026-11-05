# Plan: reaching an XPRS server from the internet, with nobody touching the router

Status: plan, nothing built. Decisions **(N1)…(N6)** are open, listed at the end.

## 1. The goal

Someone types `https://x3qhn4.xprs.link` (or follows it from a QR code) and gets
this server's web chat, from any network. The operator does nothing beyond
installing the server: no port forwarding, no dynamic-DNS account, no
certificate work. The same mechanism serves every XPRS server, so it is run
by the servers themselves, not by a person per server.

## 2. What the network here actually allows (measured 2026-11-05)

| | Finding | Meaning |
|---|---|---|
| IPv6 | global `2a02:908:2616:da20::/64` (Vodafone cable), SLAAC, EUI-64 plus temporary addresses | every server has its own public address; there is no NAT on IPv6, only the router's firewall |
| IPv4 | router WAN `178.202.105.29`, public (not DS-Lite/CGNAT) | port mapping is possible here, but on many cable/fibre lines it is not (CGNAT): IPv4 can never be the plan |
| Router | AVM FRITZ!Box 6690 Cable, advertises UPnP IGDv2 incl. `WANIPv6FirewallControl:1` (and PCP) | a device can open its own IPv6 pinhole **if** the per-device switch "permit independent port sharing" is on. It is off by default |
| Prefix | a cable /64 is renumbered by the ISP from time to time | any published address must be refreshed automatically |

So: IPv6 is the natural address, the router's firewall is the only obstacle,
and the router can be asked to open it, but on most routers only after one
click the operator has not made. A design that needs that click fails the
goal. Hence a ladder that ends in a path needing nothing.

## 3. The reachability ladder

The server tries each rung at start and every time its address changes, keeps
the best that works, and says which one it is on (`/api/status`, the log):

| Rung | How | Needs from the router | Who it reaches |
|---|---|---|---|
| **A. Direct IPv6** | listen on `[::]:443`; some ISPs/routers do not firewall inbound IPv6 at all | nothing | IPv6 visitors |
| **B. IPv6 pinhole** | UPnP IGDv2 `AddPinhole` (443, 4242) with a lease, renewed; PCP (RFC 6887) `MAP` as the second protocol | the per-device "allow apps to open ports" switch (FRITZ!Box), or a router that allows it by default | IPv6 visitors |
| **C. IPv4 mapping** | UPnP IGD `AddPortMapping` / NAT-PMP / PCP, only when the WAN IPv4 is public | the same switch | IPv4 visitors |
| **D. Relay over Reticulum** | the server is fronted by another XPRS server that IS reachable, over the outbound Reticulum link it already holds | **nothing**: outbound only | everybody |

A, B and C are tried, never required. D is what makes the goal true: every
server already keeps outbound links to the hubs, so every server can always
be fronted.

**Knowing a rung works needs somebody outside.** A server cannot test its own
inbound reachability from inside. It asks a peer (the name service, or a relay)
to connect back to `[addr]:443` and answer with a signed result. Only a probed
address is ever published as direct (section 4); until then the name points at
a relay.

IPv4-only visitors (still a large share of mobile networks) reach an
IPv6-only server through a relay, or through rung C where it exists. A relay
with both families fixes that for everybody.

## 4. Names

### 4.1 The callsign name (recommended primary)

`x3qhn4.xprs.link`: the station's own callsign, lower-cased.

The callsign is self-certifying: it is derived from the station's key
(XPRS.md section 3), so **whoever can sign with that key owns that name**, and no
account, password or token is needed. The name service is a small
authoritative DNS server that accepts only signed updates:

```
t:service f:X3QHN4 serve:web url:https://x3qhn4.xprs.link/ ip6:2a02:908:2616:da20::d505 via:direct ts:... k:npub1... sig:...
```

It checks that the signature verifies with `k:` and that `X3QHN4` derives from
`k:`, probes the address (section 3), and then answers `AAAA` for the name (or
the relay's addresses, rung D). The update can arrive over HTTP **or simply be
heard over Reticulum**: the name service is itself an XPRS station following
these announcements, so a server needs no extra protocol to publish. A
renumbered prefix is just the next signed announcement.

The name is stable for the life of the key, carries no address, and is the
same name whichever rung the server is on.

### 4.2 The IPv6-in-the-name form (optional, stateless)

`2a02-908-2616-da20-2ecf-67ff-fe14-d505.ip6.xprs.link`, the sslip.io pattern:
the DNS server computes the `AAAA` from the label and stores nothing.

| For | Against |
|---|---|
| zero state, nothing to register or sign; works the moment the address exists | changes whenever the ISP renumbers the prefix, so links and QR codes break |
| useful for debugging and for LAN-only sharing | publishes the address (and, with an EUI-64 address like this one, the network card's MAC) in every link |
| | anybody can mint a name for any address, so it proves nothing about which station answers |
| | useless on rung D, where the visitor must reach the relay, not the address |

So: serve it, because it costs nothing and the user asked for it, but put the
callsign name on the page, the QR code and the announcements. The server
listens on a stable privacy address (RFC 7217) rather than the EUI-64 one, so
neither name leaks the MAC.

### 4.3 The zone

A separate registered domain for this (here `xprs.link`, **N1**), not a
subdomain of the project site, for two reasons:

- it goes on the **Public Suffix List**, so each server's name is its own site
  to the browser (no shared cookies or storage between strangers' servers) and
  Let's Encrypt counts certificates per server name rather than 50 a week for
  the whole zone;
- abuse of one server's page cannot get the project's own domain blocklisted.

## 5. TLS

The page works over plain HTTP (the webchat's own crypto is pure JS, written
for captive portals with no `crypto.subtle`), but browsers mark `http://`
"not secure", some refuse to open it from a link, and the API would cross the
internet in the clear. So HTTPS on every rung:

- **Direct (A–C):** the server gets its own Let's Encrypt certificate for
  `x3qhn4.xprs.link` by **ACME DNS-01**: it asks the name service, with a
  signed packet, to publish the `_acme-challenge` TXT for ITS name only. No
  inbound port 80 is needed for issuance, and the key never leaves the server.
  Renewal is automatic.
- **Relay (D):** the relay passes TLS through by SNI, and the home server
  terminates it with the same certificate. The relay carries bytes it cannot
  read (**N3** has the simpler alternative).

## 6. The relay (rung D)

Any XPRS server that passes the reachability probe can offer to front others,
announced on the existing vocabulary: `serve:relay,web` (the spec already has
`serve:relay`; `web` is new, **N4**).

- **The tunnel:** the home server opens a Reticulum link to the relay
  (reticulum-dart's link/channel), outbound, through hubs it already reaches.
  A visitor connects to the relay on 443; the relay reads the SNI
  (`x3qhn4.xprs.link`), finds the link that callsign registered with a signed
  request, and copies the TLS stream both ways.
- **Choosing a relay:** automatic. Prefer one with both IPv4 and IPv6, low
  path cost, spare quota; keep two (the name service publishes both); move
  when one stops answering.
- **Budget:** the web chat is small (the page is 35 kB gzipped, the API is
  short JSON), so a relay serves many homes. Quotas per home server (bytes,
  concurrent visitors) are announced by the relay, and enforced.
- **Trust:** with SNI passthrough the relay sees which name was asked for and
  how many bytes moved, nothing more. Even with N3's terminating relay, what it
  would see is public chat and sealed DMs (sealed in the browser), never a key.

## 7. Exposure

Putting the server on the internet changes who can call it:

- the visitor API is already written for hostile callers (an allowlist of reads
  and one signed write, per-visitor limits, `WebChatApi`); it stays the only
  thing on 443;
- the admin API stays loopback-only; nothing administrative is opened;
- TCP 4242 (Reticulum transport) is opened only when the operator wants a
  public hub (**N5**); it then needs connection caps and per-source limits,
  which phase 3 of `plan-server.md` already lists;
- pinholes and mappings are leased (a few hours) and renewed, so a stopped
  server closes its own holes.

## 8. Phases

1. **Reachability report.** The server learns its global IPv6 addresses
   (preferring a stable privacy address), tries UPnP IGDv2/PCP pinholes and
   IPv4 mapping, and reports what it got. No names yet. Testable here today
   (the FRITZ!Box answers; the switch decides).
2. **Name service.** A small authoritative DNS server (Dart, in this repo or
   its own), the signed `t:service serve:web` update over HTTP and over
   Reticulum, the connect-back probe, the `ip6.` stateless zone, ACME DNS-01
   TXT on signed request. Run at least two, in different places.
3. **HTTPS on the server.** ACME client (DNS-01 through the name service),
   certificates stored in the data directory, `:443` with HTTP→HTTPS redirect
   on `:80`.
4. **Relay.** `serve:relay,web`, the SNI-passthrough tunnel over a Reticulum
   link, automatic choice and failover, quotas.
5. **Show it.** The webchat page and the app show the station's public link
   and QR code; the server logs which rung it is on.

Phases 1 and 3 help any server with a reachable IPv6 address; phase 2 is what
the rest stands on; phase 4 is what makes "no router changes" true for
everybody.

## 9. Decisions for you

- **N1** The zone. A new registered domain kept for this (recommended,
  e.g. `xprs.link`), or a subdomain of the project's own domain. Either way
  someone has to register it and submit it to the Public Suffix List (the PSL
  submission takes weeks, so it should start early).
- **N2** Who runs the name service. The project runs two instances
  (recommended to start), and anyone can run their own for their own zone with
  the same code.
- **N3** Relay TLS. SNI passthrough, where the relay cannot read the traffic
  (recommended), or a relay that terminates TLS with a wildcard certificate:
  simpler, but the relay then reads the page and API.
- **N4** Spec words. `serve:web` and `url:` on `t:service`, and the
  `ip6:`/`via:` fields of the name update, go into XPRS.md first, since the spec
  is canonical.
- **N5** Opening TCP 4242 publicly, so the server is a public Reticulum hub,
  or keeping it to outbound links (recommended at first).
- **N6** The IPv6-in-the-name zone: served as a convenience (recommended), or
  left out to keep a single way of naming a server.
