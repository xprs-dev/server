/*
 * Start at boot, per operating system. One interface, one backend per init
 * system; a platform with no backend yet says so and prints what to do by
 * hand instead of failing mysteriously.
 *
 * A backend returns STEPS (a description plus the action), so `--dry-run`
 * can print exactly what would happen and tests can inspect it without
 * touching the machine.
 */
import 'dart:io';

import 'systemd.dart';

enum ServiceScope { system, user }

class ServiceException implements Exception {
  ServiceException(this.message);
  final String message;
  @override
  String toString() => message;
}

class ServiceOptions {
  const ServiceOptions({
    required this.scope,
    required this.exePath,
    this.configPath,
    this.dryRun = false,
  });

  final ServiceScope scope;

  /// The compiled server binary being installed.
  final String exePath;

  /// Where the service's config file lives (default: the backend's choice).
  final String? configPath;
  final bool dryRun;
}

class ServiceStep {
  const ServiceStep(this.description, this.run);
  final String description;
  final Future<void> Function() run;
}

abstract class AutostartBackend {
  String get name;

  Future<List<ServiceStep>> installSteps(ServiceOptions o);
  Future<List<ServiceStep>> uninstallSteps(ServiceOptions o);

  /// Shows the service's state on the terminal; returns the exit code.
  Future<int> status(ServiceScope scope);

  /// Lines to print after install / uninstall (linger, leftover data...).
  List<String> notes(ServiceScope scope, {required bool installing});

  /// The scope whose service runs the binary at [exePath]; null when no
  /// service of this backend does (the updater then only replaces the file).
  Future<ServiceScope?> installedScope(String exePath);

  /// Restarts the server service (after the updater replaced the binary).
  Future<void> restart(ServiceScope scope);

  /// Whether the server service is running right now.
  Future<bool> isActive(ServiceScope scope);

  /// The backend for this machine; [UnsupportedBackend] when there is none.
  static AutostartBackend forPlatform() {
    if (Platform.isLinux) {
      return Directory('/run/systemd/system').existsSync()
          ? SystemdBackend()
          : const UnsupportedBackend(
              'Linux without systemd',
              'Run `xprs-server` from your init system (OpenRC, runit, s6...) '
                  'with HOME set to a data directory and --config pointing at '
                  'a file made by `xprs-server init-config`.',
            );
    }
    if (Platform.isMacOS) {
      return const UnsupportedBackend(
        'macOS (launchd)',
        'Not implemented yet. By hand: a LaunchDaemon plist whose '
            'ProgramArguments are the binary and --config FILE.',
      );
    }
    if (Platform.isWindows) {
      return const UnsupportedBackend(
        'Windows',
        'Not implemented yet. By hand: a Task Scheduler task "at startup" '
            'running the binary with --config FILE.',
      );
    }
    return UnsupportedBackend(
      Platform.operatingSystem,
      'No boot integration for this system; run the binary yourself.',
    );
  }
}

/// A platform whose boot integration is not written yet.
class UnsupportedBackend implements AutostartBackend {
  const UnsupportedBackend(this.name, this.hint);
  @override
  final String name;
  final String hint;

  Never _no() => throw ServiceException(
    'no boot service support for $name '
    'yet. $hint',
  );

  @override
  Future<List<ServiceStep>> installSteps(ServiceOptions o) async => _no();
  @override
  Future<List<ServiceStep>> uninstallSteps(ServiceOptions o) async => _no();
  @override
  Future<int> status(ServiceScope scope) async => _no();
  @override
  List<String> notes(ServiceScope scope, {required bool installing}) => [];
  @override
  Future<ServiceScope?> installedScope(String exePath) async => null;
  @override
  Future<void> restart(ServiceScope scope) async => _no();
  @override
  Future<bool> isActive(ServiceScope scope) async => _no();
}

/// Prints each step and, unless [dryRun], runs it.
Future<void> runSteps(List<ServiceStep> steps, {required bool dryRun}) async {
  for (final s in steps) {
    stdout.writeln('${dryRun ? '[dry run] ' : '• '}${s.description}');
    if (!dryRun) await s.run();
  }
}
