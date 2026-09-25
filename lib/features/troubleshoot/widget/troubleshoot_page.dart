import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gap/gap.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/features/auto_connect/data/attempt_log.dart';
import 'package:hiddify/features/auto_connect/model/connection_candidate.dart';
import 'package:hiddify/features/auto_connect/notifier/auto_connect_notifier.dart';
import 'package:hiddify/features/log/data/log_data_providers.dart';
import 'package:hiddify/features/settings/notifier/battery_optimization/battery_optimizations_notifier.dart';
import 'package:hiddify/features/sources/notifier/source_list_notifier.dart';
import 'package:hiddify/features/troubleshoot/data/log_masker.dart';
import 'package:hiddify/features/warp/notifier/warp_layer.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:intl/intl.dart';

/// Local-only troubleshooting: recent attempts, route-list status, masked log
/// export and the two Android settings that most often break background VPNs.
class TroubleshootPage extends ConsumerWidget {
  const TroubleshootPage({super.key});

  static const int maxLogLines = 400;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final attempts = ref.watch(attemptLogProvider).records.reversed.toList();
    final sources = ref.watch(sourceListProvider).valueOrNull;
    final battery = Platform.isAndroid ? ref.watch(batteryOptimizationNotifierProvider) : null;
    final timeFormat = DateFormat.Hms();

    return Scaffold(
      appBar: AppBar(title: Text(t.belderchin.troubleshoot.title)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _Section(
            title: t.belderchin.troubleshoot.lastAttempts,
            child: attempts.isEmpty
                ? Text(t.belderchin.troubleshoot.noAttempts)
                : Column(
                    children: [
                      for (final record in attempts)
                        ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(_outcomeIcon(record.outcome), color: _outcomeColor(context, record.outcome)),
                          title: Text('${record.candidateName} · ${_layerLabel(t, record)}'),
                          subtitle: Text(
                            [
                              timeFormat.format(record.at),
                              record.outcome.name,
                              if (record.detail != null) record.detail!,
                              if (record.latency != null) '${record.latency!.inMilliseconds} ms',
                            ].join(' · '),
                          ),
                        ),
                    ],
                  ),
          ),
          _Section(
            title: t.belderchin.troubleshoot.sources,
            child: sources == null
                ? const LinearProgressIndicator()
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(t.belderchin.home.sourcesVersion(version: sources.list.version.toString())),
                      Text(t.belderchin.troubleshoot.sourcesOrigin(origin: sources.origin.name)),
                      Text(
                        sources.lastFetchAt == null
                            ? t.belderchin.troubleshoot.sourcesNever
                            : t.belderchin.troubleshoot.sourcesFetched(time: DateFormat.yMd().add_Hm().format(sources.lastFetchAt!)),
                      ),
                      if (sources.lastAttempts.isNotEmpty) ...[
                        const Gap(8),
                        Text(t.belderchin.troubleshoot.mirrors, style: Theme.of(context).textTheme.labelLarge),
                        for (final attempt in sources.lastAttempts)
                          Text(
                            '${attempt.url.host} — ${attempt.succeeded ? 'v${attempt.version}' : (attempt.error ?? 'failed')} '
                            '(${attempt.elapsed.inMilliseconds} ms)',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                      ],
                      const Gap(8),
                      Wrap(
                        spacing: 8,
                        children: [
                          OutlinedButton.icon(
                            onPressed: sources.refreshStatus == SourceListRefreshStatus.running
                                ? null
                                : () => ref.read(sourceListProvider.notifier).refresh(),
                            icon: const Icon(Icons.refresh),
                            label: Text(t.belderchin.troubleshoot.refreshSources),
                          ),
                          OutlinedButton.icon(
                            onPressed: () => ref.read(autoConnectProvider.notifier).forgetPreferred(),
                            icon: const Icon(Icons.restart_alt),
                            label: Text(t.belderchin.troubleshoot.resetState),
                          ),
                          OutlinedButton.icon(
                            onPressed: () => ref.read(warpLayerProvider).reset(),
                            icon: const Icon(Icons.key_off_outlined),
                            label: Text(t.belderchin.troubleshoot.resetWarp),
                          ),
                        ],
                      ),
                    ],
                  ),
          ),
          if (battery != null)
            _Section(
              title: t.belderchin.troubleshoot.battery,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(battery.valueOrNull == true ? t.belderchin.troubleshoot.batteryOk : t.belderchin.troubleshoot.batteryBody),
                  if (battery.valueOrNull != true) ...[
                    const Gap(8),
                    FilledButton.tonalIcon(
                      onPressed: () => ref.read(batteryOptimizationNotifierProvider.notifier).requestToIgnore(),
                      icon: const Icon(Icons.battery_saver),
                      label: Text(t.belderchin.troubleshoot.batteryFix),
                    ),
                  ],
                ],
              ),
            ),
          if (Platform.isAndroid)
            _Section(title: t.belderchin.troubleshoot.alwaysOn, child: Text(t.belderchin.troubleshoot.alwaysOnBody)),
          const Gap(8),
          FilledButton.icon(
            onPressed: () => _copyMaskedLog(context, ref, t),
            icon: const Icon(Icons.copy_all),
            label: Text(t.belderchin.troubleshoot.copyLog),
          ),
        ],
      ),
    );
  }

  Future<void> _copyMaskedLog(BuildContext context, WidgetRef ref, Translations t) async {
    final resolver = ref.read(logPathResolverProvider);
    final buffer = StringBuffer();
    for (final file in [resolver.appFile(), resolver.coreFile()]) {
      if (!file.existsSync()) continue;
      final lines = await file.readAsLines();
      final tail = lines.length > maxLogLines ? lines.sublist(lines.length - maxLogLines) : lines;
      buffer
        ..writeln('==== ${file.uri.pathSegments.last} (last ${tail.length} lines) ====')
        ..writeln(tail.join('\n'));
    }
    for (final record in ref.read(attemptLogProvider).records) {
      buffer.writeln('attempt ${record.at.toIso8601String()} ${record.layer.name}/${record.candidateId} ${record.outcome.name} ${record.detail ?? ''}');
    }
    final text = buffer.toString().trim();
    if (!context.mounted) return;
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.belderchin.troubleshoot.logEmpty)));
      return;
    }
    await Clipboard.setData(ClipboardData(text: const LogMasker().mask(text)));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.belderchin.troubleshoot.copied)));
  }

  String _layerLabel(Translations t, AttemptRecord record) => switch (record.layer) {
    CandidateLayer.warp => t.belderchin.home.layerWarp,
    CandidateLayer.workers => t.belderchin.home.layerWorkers,
    CandidateLayer.backup => t.belderchin.home.layerBackup,
  };

  IconData _outcomeIcon(AttemptOutcome outcome) => switch (outcome) {
    AttemptOutcome.success => Icons.check_circle_outline,
    AttemptOutcome.unhealthy => Icons.wifi_off_outlined,
    AttemptOutcome.cancelled => Icons.cancel_outlined,
    _ => Icons.error_outline,
  };

  Color _outcomeColor(BuildContext context, AttemptOutcome outcome) => switch (outcome) {
    AttemptOutcome.success => Colors.green.shade700,
    AttemptOutcome.cancelled => Theme.of(context).disabledColor,
    _ => Theme.of(context).colorScheme.error,
  };
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const Gap(8),
            child,
          ],
        ),
      ),
    );
  }
}
