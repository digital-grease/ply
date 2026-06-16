import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/ravelry_credentials.dart';
import '../data/ravelry_service.dart';

/// The credential store (overridable in tests).
final ravelryCredentialsProvider = Provider<RavelryCredentials>((_) => RavelryCredentials());

/// A connected Ravelry session: the username + a ready service. Null = not connected.
class RavelrySession {
  const RavelrySession({required this.username, required this.service});
  final String username;
  final RavelryService service;
}

/// Owns the OPTIONAL Ravelry connection. `build` loads stored credentials WITHOUT a network call (so
/// app startup stays offline); [connect] verifies a fresh key against /current_user.json before
/// saving; [disconnect] wipes the stored key.
class RavelryController extends AsyncNotifier<RavelrySession?> {
  @override
  Future<RavelrySession?> build() async {
    final creds = await ref.read(ravelryCredentialsProvider).load();
    if (creds == null) return null;
    return RavelrySession(
      username: creds.username,
      service: RavelryService(accessKey: creds.accessKey, key: creds.key),
    );
  }

  /// Verify [accessKey] + [key] against Ravelry and, on success, store them and become connected.
  Future<void> connect({required String accessKey, required String key}) async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final service = RavelryService(accessKey: accessKey, key: key);
      final username = await service.currentUsername(); // throws RavelryException on a bad key
      await ref
          .read(ravelryCredentialsProvider)
          .save(RavelryCreds(accessKey: accessKey, key: key, username: username));
      return RavelrySession(username: username, service: service);
    });
  }

  Future<void> disconnect() async {
    await ref.read(ravelryCredentialsProvider).clear();
    state = const AsyncData(null);
  }
}

final ravelryControllerProvider =
    AsyncNotifierProvider<RavelryController, RavelrySession?>(RavelryController.new);
