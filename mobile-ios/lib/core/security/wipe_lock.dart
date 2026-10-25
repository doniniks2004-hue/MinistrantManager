import 'package:flutter/foundation.dart';

/// ONE lock for "data of this device is being erased, or the erasing has not been finished".
///
/// Taken by RevocationHandler when a wipe STARTS (before the marker is written, before anything is
/// deleted) and released only when the wipe is confirmed COMPLETE. A wipe that fails leaves it held:
/// from then on nothing may show or hand out the data it was meant to remove, whichever screen is
/// on top, until [RevocationHandler.retryIncompleteWipe] succeeds.
///
/// It is shared by the handler (which holds it), the OfflinePageCoordinator (which hands out saved
/// copies) and HomeScreen (which shows the panel); each is given the same instance by AppServices.
/// There is deliberately no process-wide singleton: a test's leftover lock must not leak into the next.
class WipeLock extends ChangeNotifier {
  bool _held = false;

  /// True from the start of a wipe until it is complete.
  bool get isHeld => _held;

  void acquire() {
    if (_held) return;
    _held = true;
    notifyListeners();
  }

  void release() {
    if (!_held) return;
    _held = false;
    notifyListeners();
  }
}
