import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/app_user.dart';

class UserRepository {
  final SupabaseClient _client = Supabase.instance.client;

  Future<AppUser?> getCurrentUserProfile() async {
    final authUser = _client.auth.currentUser;

    if (authUser == null) {
      return null;
    }

    final data = await _client
        .from('users')
        .select('user_id, nama, email, role_id, status, nomor_hp, tenant_id')
        .eq('user_id', authUser.id)
        .maybeSingle();

    if (data == null) {
      return null;
    }

    return AppUser.fromMap(data);
  }
}