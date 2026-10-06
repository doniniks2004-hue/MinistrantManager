import 'dart:async';

import 'package:dio/dio.dart';

import '../../core/network/api_client.dart';
import '../../core/secure/secure_storage_service.dart';

/// Short-lived tickets never enter logs or offline storage.
class WebviewHandoffService {
  WebviewHandoffService({required this.api, required this.secureStorage});
  final ApiClient api;
  final SecureStorageService secureStorage;

  Future<Uri> requestHandoffUrl(String path) async {
    final cancel = CancelToken();
    final deadline = Timer(
      const Duration(milliseconds: 1400),
      () => cancel.cancel('handoff deadline'),
    );
    try {
      final serverUrl = await secureStorage.serverUrl;
      if (serverUrl == null) throw StateError('Device not activated.');
      final dio = await api.parish();
      final resp = await dio.post(
        '/mobile/webview/handoff',
        data: {'path': Uri.parse(path).path},
        cancelToken: cancel,
        options: Options(
          sendTimeout: const Duration(milliseconds: 1400),
          receiveTimeout: const Duration(milliseconds: 1400),
        ),
      );
      final ticket = resp.data['ticket'] as String;
      if (!RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(ticket)) {
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
