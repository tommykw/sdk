// Copyright (c) 2018, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analysis_server/protocol/protocol.dart';
import 'package:analysis_server/protocol/protocol_generated.dart';
import 'package:analysis_server/src/analysis_server.dart';
import 'package:analysis_server/src/edit/fix/dartfix_info.dart';
import 'package:analysis_server/src/edit/fix/dartfix_listener.dart';
import 'package:analysis_server/src/edit/fix/dartfix_registrar.dart';
import 'package:analysis_server/src/edit/fix/fix_code_task.dart';
import 'package:analysis_server/src/edit/fix/fix_error_task.dart';
import 'package:analysis_server/src/edit/fix/fix_lint_task.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/session.dart';
import 'package:analyzer/file_system/file_system.dart';

class EditDartFix
    with FixCodeProcessor, FixErrorProcessor, FixLintProcessor
    implements DartFixRegistrar {
  final AnalysisServer server;

  final Request request;
  final fixFolders = <Folder>[];
  final fixFiles = <File>[];

  DartFixListener listener;

  EditDartFix(this.server, this.request) {
    listener = new DartFixListener(server);
  }

  Future<Response> compute() async {
    final params = new EditDartfixParams.fromRequest(request);

    // Determine the fixes to be applied
    final fixInfo = <DartFixInfo>[];
    if (params.includeRequiredFixes == true) {
      fixInfo.addAll(allFixes.where((i) => i.isRequired));
    }
    if (params.includedFixes != null) {
      for (String key in params.includedFixes) {
        var info = allFixes.firstWhere((i) => i.key == key, orElse: () => null);
        if (info != null) {
          fixInfo.add(info);
        } else {
          // TODO(danrubel): Report unknown fix to the user
        }
      }
    }
    if (fixInfo.isEmpty) {
      fixInfo.addAll(allFixes.where((i) => i.isDefault));
    }
    if (params.excludedFixes != null) {
      for (String key in params.excludedFixes) {
        var info = allFixes.firstWhere((i) => i.key == key, orElse: () => null);
        if (info != null) {
          fixInfo.remove(info);
        } else {
          // TODO(danrubel): Report unknown fix to the user
        }
      }
    }
    for (DartFixInfo info in fixInfo) {
      info.setup(this, listener);
    }

    // Validate each included file and directory.
    final resourceProvider = server.resourceProvider;
    final contextManager = server.contextManager;
    for (String filePath in params.included) {
      if (!server.isValidFilePath(filePath)) {
        return new Response.invalidFilePathFormat(request, filePath);
      }
      Resource res = resourceProvider.getResource(filePath);
      if (!res.exists ||
          !(contextManager.includedPaths.contains(filePath) ||
              contextManager.isInAnalysisRoot(filePath))) {
        return new Response.fileNotAnalyzed(request, filePath);
      }
      if (res is Folder) {
        fixFolders.add(res);
      } else {
        fixFiles.add(res);
      }
    }

    // Process each source file.
    bool hasErrors = false;
    String changedPath;
    server.contextManager.driverMap.values
        .forEach((d) => d.onCurrentSessionAboutToBeDiscarded = (String path) {
              // Remember the resource that changed during analysis
              changedPath = path;
            });

    try {
      await processResources((ResolvedUnitResult result) async {
        if (await processErrors(result)) {
          hasErrors = true;
        }
        await processLints(result);
        await processCodeTasks(result);
      });
      if (needsSecondPass) {
        await processResources((ResolvedUnitResult result) async {
          await processCodeTasks2(result);
        });
      }
      await finishLints();
      await finishCodeTasks();
    } on InconsistentAnalysisException catch (_) {
      // If a resource changed, report the problem without suggesting fixes
      var changedMessage = changedPath != null
          ? 'resource changed during analysis: $changedPath'
          : 'multiple resources changed during analysis.';
      return new EditDartfixResult(
        [new DartFixSuggestion('Analysis canceled because $changedMessage')],
        listener.otherSuggestions,
        hasErrors,
        listener.sourceChange.edits,
      ).toResponse(request.id);
    } finally {
      server.contextManager.driverMap.values
          .forEach((d) => d.onCurrentSessionAboutToBeDiscarded = null);
    }

    return new EditDartfixResult(
      listener.suggestions,
      listener.otherSuggestions,
      hasErrors,
      listener.sourceChange.edits,
    ).toResponse(request.id);
  }

  /// Return `true` if the path in within the set of `included` files
  /// or is within an `included` directory.
  bool isIncluded(String filePath) {
    if (filePath != null) {
      for (File file in fixFiles) {
        if (file.path == filePath) {
          return true;
        }
      }
      for (Folder folder in fixFolders) {
        if (folder.contains(filePath)) {
          return true;
        }
      }
    }
    return false;
  }

  /// Call the supplied [process] function to process each compilation unit.
  Future processResources(
      Future<void> Function(ResolvedUnitResult result) process) async {
    final contextManager = server.contextManager;
    final resourceProvider = server.resourceProvider;
    final resources = <Resource>[];
    for (String rootPath in contextManager.includedPaths) {
      resources.add(resourceProvider.getResource(rootPath));
    }
    while (resources.isNotEmpty) {
      Resource res = resources.removeLast();
      if (res is Folder) {
        for (Resource child in res.getChildren()) {
          if (!child.shortName.startsWith('.') &&
              contextManager.isInAnalysisRoot(child.path) &&
              !contextManager.isIgnored(child.path)) {
            resources.add(child);
          }
        }
        continue;
      }
      if (!isIncluded(res.path)) {
        continue;
      }
      ResolvedUnitResult result = await server.getResolvedUnit(res.path);
      if (result == null || result.unit == null) {
        continue;
      }
      await process(result);
    }
  }
}
