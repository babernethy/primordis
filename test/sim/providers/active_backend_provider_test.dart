import 'package:flutter_test/flutter_test.dart';
import 'package:primordis/sim/backend_selector.dart';
import 'package:primordis/sim/backends/cpu/cpu_wasm_backend.dart';
import 'package:primordis/sim/models/capability_tier.dart';
import 'package:primordis/sim/providers/active_backend_provider.dart';
import 'package:riverpod/riverpod.dart';

/// On the Dart VM (`flutter test`), the web WebGPU facade
/// ([createWebSimBackend]) always returns null and the probe always reports
/// [WebGpuSupport.unsupportedNoApi] ([web_backend_stub.dart]), so
/// [activeBackendProvider] deterministically resolves to the real
/// [CpuWasmBackend] — this exercises the provider end-to-end (not just the
/// pure [selectWebBackend] function) without needing a browser.
void main() {
  ProviderContainer container() {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    return c;
  }

  test('resolves to the CPU-WASM tier off-web, non-blocking (AsyncLoading '
      'then AsyncData)', () async {
    final c = container();

    final pending = c.read(activeBackendProvider);
    expect(pending, isA<AsyncLoading<SimBackendSelection>>());

    final selection = await c.read(activeBackendProvider.future);

    expect(selection.backend, isA<CpuWasmBackend>());
    expect(selection.tier.kind, CapabilityBackendKind.webCpuWasm);
    expect(selection.tier.reducedMode, isTrue);
    expect(selection.tier.reason, 'navigator.gpu is unavailable');
    expect(selection.tier.capabilities.maxParticles, lessThan(24000));

    final resolved = c.read(activeBackendProvider);
    expect(resolved, isA<AsyncData<SimBackendSelection>>());
  });

  test('disposing the container disposes the resolved backend', () async {
    final c = container();
    final selection = await c.read(activeBackendProvider.future);
    final backend = selection.backend as CpuWasmBackend;

    expect(backend.isDisposed, isFalse);
    c.dispose();
    expect(backend.isDisposed, isTrue);
  });
}
