import 'dart:async';

import 'package:dio/dio.dart';

import '../../core/network/api_client.dart';
import '../../core/secure/secure_storage_service.dart';

/// Short-lived tickets never enter logs or offline storage.
class WebviewHandoffService {
  WebviewHandoffService({required this.api, required this.secureStorage});
  final ApiClient api;
  final SecureStorageService secureStorage;

  /// The limit used when opening a page: short on purpose, so a missing
  /// network is noticed fast and the saved copy appears within 2 s.
  static const defaultTimeout = Duration(milliseconds: 1400);

  /// [timeout] bounds the whole request. The default is the short opening
  /// limit; the background check for the connection coming back passes a
  /// longer one, because there nobody is waiting and a slow server must be
  /// told apart from a missing one.
  Future<Uri> requestHandoffUrl(
    String path, {
    Duration timeout = defaultTimeout,
  }) async {
    final cancel = CancelToken();
    final deadline = Timer(timeout, () => cancel.cancel('handoff deadline'));
    try {
      final serverUrl = await secureStorage.serverUrl;
      if (serverUrl == null) throw StateError('Device not activated.');
      final dio = await api.parish();
      final resp = await dio.post(
        '/mobile/webview/handoff',
        data: {'path': Uri.parse(path).path},
        cancelToken: cancel,
        options: Options(
          sendTimeout: timeout,
          receiveTimeout: timeout,
        ),
      );
      // Whatever shape the reply has, "the server answered but not with a
      // handoff" is ONE signal (FormatException) — the coordinator relies
      // on it to tell that apart from a failure in this app's own code,
      // which must never be reported as the server's fault.
      final data = resp.data;
      final ticket = data is Map ? data['ticket'] : null;
      if (ticket is! String || !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(ticket)) {
        throw const FormatException('Invalid handoff response.');
      }
      return Uri.parse(serverUrl)
          .resolve('/public/mobile_handoff.php')
          .replace(queryParameters: {'ticket': ticket});
    } finally {
      deadline.cancel();
    }
  }
}
