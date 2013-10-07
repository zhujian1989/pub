// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library pub.command.serve;

import 'dart:async';

import '../barback/dart_forwarding_transformer.dart';
import '../barback/dart2js_transformer.dart';
import '../barback/pub_package_provider.dart';
import '../barback.dart' as barback;
import '../command.dart';
import '../entrypoint.dart';
import '../exit_codes.dart' as exit_codes;
import '../io.dart';
import '../log.dart' as log;
import '../utils.dart';

final _green = getSpecial('\u001b[32m');
final _red = getSpecial('\u001b[31m');
final _none = getSpecial('\u001b[0m');
final _arrow = getSpecial('\u2192', '=>');

/// Handles the `serve` pub command.
class ServeCommand extends PubCommand {
  String get description => "Run a local web development server.";
  String get usage => 'pub serve';

  PubPackageProvider _provider;

  String get hostname => commandOptions['hostname'];

  /// `true` if Dart entrypoints should be compiled to JavaScript.
  bool get useDart2JS => commandOptions['dart2js'];

  ServeCommand() {
    commandParser.addOption('port', defaultsTo: '8080',
        help: 'The port to listen on.');

    // A hidden option for the tests to work around a bug in some of the OS X
    // bots where "localhost" very rarely resolves to the IPv4 loopback address
    // instead of IPv6 (or vice versa). The tests will always set this to
    // 127.0.0.1.
    commandParser.addOption('hostname',
                            defaultsTo: 'localhost',
                            hide: true);

    commandParser.addFlag('dart2js', defaultsTo: true,
        help: 'Compile Dart to JavaScript.');
  }

  Future onRun() {
    var port;
    try {
      port = int.parse(commandOptions['port']);
    } on FormatException catch (_) {
      log.error('Could not parse port "${commandOptions['port']}"');
      this.printUsage();
      return flushThenExit(exit_codes.USAGE);
    }

    return ensureLockFileIsUpToDate().then((_) {
      return entrypoint.loadPackageGraph();
    }).then((graph) {
      // TODO(rnystrom): Add support for dart2dart transformer here.
      var builtInTransformers = null;
      if (useDart2JS) {
        builtInTransformers = [
          new Dart2JSTransformer(graph),
          new DartForwardingTransformer()
        ];
      }

      return barback.createServer(hostname, port, graph,
          builtInTransformers: builtInTransformers);
    }).then((server) {
      /// This completer is used to keep pub running (by not completing) and
      /// to pipe fatal errors to pub's top-level error-handling machinery.
      var completer = new Completer();

      server.barback.errors.listen((error) {
        log.error("${_red}Build error:\n$error$_none");
      });

      server.barback.results.listen((result) {
        if (result.succeeded) {
          // TODO(rnystrom): Report using growl/inotify-send where available.
          log.message("Build completed ${_green}successfully$_none");
        } else {
          log.message("Build completed with "
              "${_red}${result.errors.length}$_none errors.");
        }
      }, onError: (error) {
        if (!completer.isCompleted) completer.completeError(error);
      });

      server.results.listen((result) {
        if (result.isSuccess) {
          log.message("${_green}GET$_none ${result.url.path} $_arrow "
              "${result.id}");
          return;
        }

        var msg = "${_red}GET$_none ${result.url.path} $_arrow";
        var error = result.error.toString();
        if (error.contains("\n")) {
          log.message("$msg\n${prefixLines(error)}");
        } else {
          log.message("$msg $error");
        }
      }, onError: (error) {
        if (!completer.isCompleted) completer.completeError(error);
      });

      log.message("Serving ${entrypoint.root.name} "
          "on http://$hostname:${server.port}");

      return completer.future;
    });
  }

  /// Gets dependencies if the lockfile is out of date with respect to the
  /// pubspec.
  Future ensureLockFileIsUpToDate() {
    return new Future.sync(() {
      // The server relies on an up-to-date lockfile, so get first if needed.
      if (!entrypoint.isLockFileUpToDate()) {
        if (entrypoint.lockFileExists) {
          log.message(
              "Your pubspec has changed, so we need to update your lockfile:");
        } else {
          log.message(
              "You don't have a lockfile, so we need to generate that:");
        }
        return entrypoint.getDependencies().then((_) {
          log.message("Got dependencies!");
        });
      }
    });
  }
}