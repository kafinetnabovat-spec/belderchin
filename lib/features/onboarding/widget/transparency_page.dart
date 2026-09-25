import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:gap/gap.dart';
import 'package:hiddify/core/localization/locale_preferences.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/core/model/region.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/features/home/widget/belderchin_home_page.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hiddify/gen/assets.gen.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// First-run screen. It states plainly what the provider can see, what the
/// app never does, and where the source code lives. Accepting it marks the
/// intro as completed; the router then moves to the home page.
class TransparencyPage extends HookConsumerWidget {
  const TransparencyPage({super.key});

  static const String privacyUrl = '${Constants.githubUrl}/blob/main/docs/PRIVACY.fa.md';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final busy = useState(false);
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final foreground = dark ? BelderchinColors.sand : BelderchinColors.night;

    Future<void> accept() async {
      if (busy.value) return;
      busy.value = true;
      // Sensible defaults for the intended audience; changeable under "advanced".
      await ref.read(ConfigOptions.region.notifier).update(Region.ir);
      await ref.read(ConfigOptions.directDnsAddress.notifier).reset();
      if (ref.read(localePreferencesProvider) != AppLocale.fa) {
        await ref.read(localePreferencesProvider.notifier).changeLocale(AppLocale.fa);
      }
      await ref.read(Preferences.introCompleted.notifier).update(true);
    }

    return Scaffold(
      backgroundColor: dark ? BelderchinColors.night : BelderchinColors.sand,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(24, 32, 24, 16),
                children: [
                  Center(child: Assets.images.logoMark.image(width: 96, height: 96)),
                  const Gap(16),
                  Text(
                    t.common.appTitle,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineMedium?.copyWith(color: foreground, fontWeight: FontWeight.w700),
                  ),
                  const Gap(24),
                  Text(t.belderchin.transparency.title, style: theme.textTheme.titleLarge?.copyWith(color: foreground)),
                  const Gap(8),
                  Text(t.belderchin.transparency.intro, style: theme.textTheme.bodyLarge?.copyWith(color: foreground, height: 1.7)),
                  const Gap(20),
                  _Point(icon: Icons.visibility_outlined, text: t.belderchin.transparency.p1, color: foreground),
                  _Point(icon: Icons.block_outlined, text: t.belderchin.transparency.p2, color: foreground),
                  _Point(icon: Icons.phone_android_outlined, text: t.belderchin.transparency.p3, color: foreground),
                  _Point(icon: Icons.code, text: t.belderchin.transparency.p4, color: foreground),
                  const Gap(12),
                  Wrap(
                    spacing: 8,
                    children: [
                      TextButton.icon(
                        onPressed: () => UriUtils.tryLaunch(Uri.parse(Constants.githubUrl)),
                        icon: const Icon(Icons.open_in_new, size: 18),
                        label: Text(t.belderchin.transparency.sourceCode),
                      ),
                      TextButton.icon(
                        onPressed: () => UriUtils.tryLaunch(Uri.parse(privacyUrl)),
                        icon: const Icon(Icons.privacy_tip_outlined, size: 18),
                        label: Text(t.belderchin.transparency.privacy),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: BelderchinColors.terracotta,
                    foregroundColor: BelderchinColors.sand,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  onPressed: busy.value ? null : accept,
                  child: busy.value
                      ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(t.belderchin.transparency.accept, style: theme.textTheme.titleMedium?.copyWith(color: BelderchinColors.sand)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Point extends StatelessWidget {
  const _Point({required this.icon, required this.text, required this.color});

  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: BelderchinColors.terracotta),
          const Gap(12),
          Expanded(child: Text(text, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: color, height: 1.7))),
        ],
      ),
    );
  }
}
