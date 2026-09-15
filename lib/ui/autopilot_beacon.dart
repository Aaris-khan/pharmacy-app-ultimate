import 'package:flutter/material.dart';

import '../domain/stock_guidance.dart';
import '../state/autopilot_supervisor.dart';

/// A compact global signal for urgent pharmacist work.
///
/// The beacon is intentionally read-only. Tapping it opens the existing
/// dependency-aware Needs Attention workflow, where exact-row editing, ordering,
/// confirmation, CAS and Undo boundaries remain authoritative.
class AarisAutopilotBeacon extends StatelessWidget {
  const AarisAutopilotBeacon({
    super.key,
    required this.supervisor,
    required this.onOpenWorkQueue,
  });

  final AarisAutopilotSupervisor supervisor;
  final VoidCallback onOpenWorkQueue;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: supervisor,
    builder: (context, _) {
      final digest = supervisor.digest;
      if (!digest.isReady || !digest.needsProminentSignal) {
        return const SizedBox.shrink();
      }

      final theme = Theme.of(context);
      final scheme = theme.colorScheme;
      final degraded = digest.health == AarisAutopilotHealth.degraded;
      final critical = digest.criticalCount > 0;
      final useErrorSurface = degraded || critical;
      final background = useErrorSurface
          ? scheme.errorContainer
          : scheme.primaryContainer;
      final foreground = useErrorSurface
          ? scheme.onErrorContainer
          : scheme.onPrimaryContainer;
      final priorityText = degraded
          ? 'दोबारा जाँचें'
          : critical
          ? '${digest.criticalCount} बहुत ज़रूरी'
          : '${digest.highCount} ज़रूरी';
      final next = !degraded && digest.nextKind != null
          ? stockActionLabel(digest.nextKind!)
          : 'काम देखने के लिए टैप करें';

      return Semantics(
        button: true,
        label: 'आज के काम · $priorityText · $next',
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Material(
            color: background,
            elevation: 4,
            shadowColor: scheme.shadow.withValues(alpha: .18),
            borderRadius: BorderRadius.circular(18),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onOpenWorkQueue,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      degraded
                          ? Icons.sync_problem_rounded
                          : critical
                          ? Icons.health_and_safety_rounded
                          : Icons.psychology_alt_rounded,
                      color: foreground,
                    ),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'आज के काम · $priorityText',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelLarge?.copyWith(
                              color: foreground,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            next,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: foreground,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(Icons.arrow_forward_rounded, color: foreground),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}
