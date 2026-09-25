import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/features/auto_connect/model/auto_connect_state.dart';
import 'package:hiddify/features/auto_connect/model/connection_candidate.dart';
import 'package:hiddify/features/auto_connect/notifier/auto_connect_notifier.dart';
import 'package:hiddify/features/sources/notifier/source_list_notifier.dart';
import 'package:hiddify/gen/assets.gen.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Brand palette (see tools/branding): sand, terracotta, night.
abstract final class BelderchinColors {
  static const Color sand = Color(0xFFF2DDBD);
  static const Color sandDeep = Color(0xFFE6C9A0);
  static const Color terracotta = Color(0xFFCA4F12);
  static const Color night = Color(0xFF1F1B16);
  static const Color olive = Color(0xFF5E7A4A);
}

/// The whole app for most users: one big button, one line of status.
class BelderchinHomePage extends HookConsumerWidget {
  const BelderchinHomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final state = ref.watch(autoConnectProvider);
    final sources = ref.watch(sourceListProvider).valueOrNull;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final background = dark ? BelderchinColors.night : BelderchinColors.sand;
    final foreground = dark ? BelderchinColors.sand : BelderchinColors.night;

    return Scaffold(
      backgroundColor: background,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: Row(
                children: [
                  Assets.images.logoMark.image(width: 36, height: 36),
                  const Gap(10),
                  Text(
                    t.common.appTitle,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(color: foreground, fontWeight: FontWeight.w700),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: t.belderchin.home.troubleshoot,
                    onPressed: () => context.push('/troubleshoot'),
                    icon: Icon(Icons.healing_outlined, color: foreground),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _BigButton(state: state, onTap: () => ref.read(autoConnectProvider.notifier).toggle()),
                    const Gap(28),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 250),
                        child: Text(
                          _statusText(t, state),
                          key: ValueKey(_statusText(t, state)),
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(color: foreground, height: 1.6),
                        ),
                      ),
                    ),
                    const Gap(12),
                    if (state case AutoConnectConnected(:final candidate)) _LayerChip(candidate: candidate, t: t),
                    if (state case AutoConnectTrying(:final candidate)) _LayerChip(candidate: candidate, t: t, muted: true),
                  ],
                ),
              ),
            ),
            if (sources != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  children: [
                    if (sources.requiresNewerApp)
                      _Hint(text: t.belderchin.status.needUpdate, color: BelderchinColors.terracotta),
                    if (sources.expired) _Hint(text: t.belderchin.status.stale, color: foreground.withValues(alpha: 0.7)),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: Row(
                children: [
                  Text(
                    sources == null ? '' : t.belderchin.home.sourcesVersion(version: sources.list.version.toString()),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: foreground.withValues(alpha: 0.6)),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () => context.push('/home'),
                    style: TextButton.styleFrom(foregroundColor: foreground.withValues(alpha: 0.8)),
                    icon: const Icon(Icons.tune, size: 18),
                    label: Text(t.belderchin.home.advanced),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _statusText(Translations t, AutoConnectState state) => switch (state) {
    AutoConnectIdle() => t.belderchin.status.idle,
    AutoConnectPreparing() => t.belderchin.status.preparing,
    AutoConnectTrying(:final candidate, :final index, :final total, :final stage) =>
      stage == TryStage.checking
          ? t.belderchin.status.checking
          : t.belderchin.status.trying(name: candidate.name, index: index.toString(), total: total.toString()),
    AutoConnectConnected(:final candidate) => t.belderchin.status.connected(name: candidate.name),
    AutoConnectReconnecting(:final delay) => t.belderchin.status.reconnecting(seconds: delay.inSeconds.toString()),
    AutoConnectDisconnecting() => t.belderchin.status.disconnecting,
    AutoConnectFailed(:final reason) => switch (reason) {
      FailureReason.noCandidates => t.belderchin.status.noSources,
      FailureReason.vpnPermissionDenied => t.belderchin.status.vpnPermission,
      FailureReason.cancelled => t.belderchin.status.cancelled,
      FailureReason.allFailed => t.belderchin.status.failed,
    },
  };
}

class _BigButton extends HookWidget {
  const _BigButton({required this.state, required this.onTap});

  final AutoConnectState state;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final busy = state.isBusy || state is AutoConnectReconnecting;
    final connected = state.isConnected;
    final controller = useAnimationController(duration: const Duration(milliseconds: 1400));
    useEffect(() {
      if (busy) {
        controller.repeat(reverse: true);
      } else {
        controller
          ..stop()
          ..value = 0;
      }
      return null;
    }, [busy]);

    final fill = connected ? BelderchinColors.terracotta : BelderchinColors.night;
    final label = switch (state) {
      AutoConnectConnected() => Icons.check_rounded,
      AutoConnectPreparing() || AutoConnectTrying() || AutoConnectReconnecting() => Icons.close_rounded,
      _ => Icons.power_settings_new_rounded,
    };

    return Semantics(
      button: true,
      label: connected ? 'disconnect' : 'connect',
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedBuilder(
          animation: controller,
          builder: (context, child) {
            final pulse = busy ? 1 + controller.value * 0.06 : 1.0;
            return Transform.scale(scale: pulse, child: child);
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            width: 196,
            height: 196,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: fill,
              boxShadow: [
                BoxShadow(
                  color: fill.withValues(alpha: connected ? 0.45 : 0.25),
                  blurRadius: connected ? 40 : 24,
                  spreadRadius: connected ? 6 : 2,
                ),
              ],
              border: Border.all(color: BelderchinColors.sandDeep, width: 6),
            ),
            child: Center(
              child: busy
                  ? const SizedBox(
                      width: 56,
                      height: 56,
                      child: CircularProgressIndicator(strokeWidth: 5, color: BelderchinColors.sand),
                    )
                  : Icon(label, size: 84, color: BelderchinColors.sand),
            ),
          ),
        ),
      ),
    );
  }
}

class _LayerChip extends StatelessWidget {
  const _LayerChip({required this.candidate, required this.t, this.muted = false});

  final ConnectionCandidate candidate;
  final Translations t;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final layer = switch (candidate.layer) {
      CandidateLayer.warp => t.belderchin.home.layerWarp,
      CandidateLayer.workers => t.belderchin.home.layerWorkers,
      CandidateLayer.backup => t.belderchin.home.layerBackup,
    };
    final color = muted ? BelderchinColors.night.withValues(alpha: 0.5) : BelderchinColors.olive;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color),
      ),
      child: Text(
        candidate.name == layer ? layer : '$layer · ${candidate.name}',
        style: Theme.of(context).textTheme.labelMedium?.copyWith(color: color),
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.info_outline, size: 16, color: color),
          const Gap(6),
          Flexible(child: Text(text, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: color))),
        ],
      ),
    );
  }
}
