// What the public-name loop would see from this machine, without changing
// anything: public addresses, nip.io names, the UPnP router and its
// permissions.  dart run tool/public_name_check.dart
import 'package:xprs_core/src/connections/internet/public_name/public_address_io.dart';
import 'package:xprs_core/src/connections/internet/public_name/upnp_io.dart';

Future<void> main() async {
  final a = await discoverPublicAddresses();
  print('public addresses: $a');
  if (a.v6 != null) print('  IPv6 name: ${nipName(a.v6!)}');
  if (a.v4 != null) print('  IPv4 name: ${nipName(a.v4!)}');
  final gw = await UpnpGateway.discover();
  if (gw == null) {
    print('UPnP router: none found');
    return;
  }
  print('UPnP router: ${gw.base}  IPv4 mapping: ${gw.canMapV4}  '
      'IPv6 firewall: ${gw.canPinholeV6}');
  print('  router says public IPv4 is ${(await gw.externalIPv4())?.address}');
  print('  LAN address here: ${(await gw.lanAddress())?.address}');
}
