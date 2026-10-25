import 'package:ministrant_manager/core/secure/secure_storage_service.dart';
import 'package:ministrant_manager/core/security/access_refusals.dart';

/// Each widget-test fixture replaces the mock keystore with a fresh map and
/// runs with a new fake clock. Its operation queue must be fresh too: a Future
/// retained by the process-wide production gate can belong to a finished test's
/// fake-async zone. Keep real method-channel reads/writes, with a fixture scope.
class IsolatedSecureStorage extends SecureStorageService {
  IsolatedSecureStorage({Object? scope}) : _scope = scope ?? Object();

  final Object _scope;
  late final RefusalStorage _refusals = _ScopedRefusalStorage(super.refusalStorage, _scope);

  @override
  RefusalStorage get refusalStorage => _refusals;
}

class _ScopedRefusalStorage implements RefusalStorage, SharedRefusalStorage {
  _ScopedRefusalStorage(this.delegate, this.gateKey);
  final RefusalStorage delegate;
  @override
  final Object gateKey;

  @override
  Future<String?> read(RefusalSlot slot) => delegate.read(slot);
  @override
  Future<void> write(RefusalSlot slot, String value) => delegate.write(slot, value);
  @override
  Future<void> delete(RefusalSlot slot) => delegate.delete(slot);
}
