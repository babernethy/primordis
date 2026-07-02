import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:primordis/sim/providers/active_backend_provider.dart';

/// A minimal stand-in for the reduced-mode-aware UI shell
/// ([PRIMORDIS-TASK-805] owns the real chrome): proves
/// [activeBackendProvider] supports the "detecting, then resolved, no hang"
/// contract required by [PRIMORDIS-TASK-797] without this task reaching into
/// `lib/features/simulation/**` (out of scope here; see PR notes).
class _SelectionGate extends ConsumerWidget {
  const _SelectionGate();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selection = ref.watch(activeBackendProvider);
    return selection.when(
      loading: () => const Text('Detecting GPU…'),
      error: (e, st) => Text('Selection failed: $e'),
      data: (s) => Text('Simulation (${s.tier.kind.name})'),
    );
  }
}

void main() {
  testWidgets(
    'shows a detecting state while selection is pending, then the resolved '
    'simulation — no indefinite hang',
    (tester) async {
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(home: Scaffold(body: Center(child: _SelectionGate()))),
        ),
      );

      // First frame: selection hasn't resolved yet (async provider) — the
      // detecting/initializing state must be visible immediately, not a
      // blank/white screen.
      expect(find.text('Detecting GPU…'), findsOneWidget);
      expect(find.textContaining('Simulation ('), findsNothing);

      // Let the async selection (probe -> CPU-WASM init off-web) resolve.
      await tester.pumpAndSettle();

      expect(find.text('Detecting GPU…'), findsNothing);
      expect(find.textContaining('Simulation ('), findsOneWidget);
    },
  );
}
