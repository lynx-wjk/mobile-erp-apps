// ignore_for_file: unused_element
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/ui/app_ui.dart';
import '../../../core/constants/app_roles.dart';
import '../../../core/constants/marketplace_providers.dart';
import '../../../models/app_user.dart';
import '../models/marketplace_account_public.dart';
import '../services/marketplace_service.dart';

class MarketplaceAccountsPage extends StatefulWidget {
  final AppUser currentUser;

  const MarketplaceAccountsPage({
    super.key,
    required this.currentUser,
  });

  @override
  State<MarketplaceAccountsPage> createState() =>
      _MarketplaceAccountsPageState();
}

class _MarketplaceAccountsPageState extends State<MarketplaceAccountsPage> {
  final MarketplaceService _service = MarketplaceService();

  String get _roleId => widget.currentUser.role.roleId;
  bool get _isDemoSuperAdmin => AppRolePermissions.isDemoSuperAdminId(_roleId);
  bool get _canConnectNew =>
      AppRolePermissions.canConnectNewMarketplace(_roleId) &&
      !_isDemoSuperAdmin;
  bool get _canReconnect =>
      AppRolePermissions.canManageMarketplaceAuth(_roleId) &&
      !_isDemoSuperAdmin;
  bool get _canDeleteAccount =>
      AppRolePermissions.canDeleteBusinessData(_roleId) && !_isDemoSuperAdmin;
  final TextEditingController _storeAliasController = TextEditingController();

  bool _isLoading = true;
  bool _isCreatingLink = false;
  final Set<String> _deletingAccountIds = <String>{};
  String? _errorMessage;
  String _selectedMarketplace = 'tiktok_shop';
  String _selectedEnvironment = 'testing';
  String? _generatedLink;
  String? _generatedLinkTitle;
  String? _generatedLinkEnvironment;
  String? _generatedLinkHost;
  String? _generatedLinkCredentialSource;
  String? _generatedLinkPartnerIdMasked;
  bool _generatedLinkRedirectUriConfigured = false;
  bool _generatedLinkUsedFallbackCredential = false;
  DateTime? _generatedLinkExpiresAt;
  List<MarketplaceAccountPublic> _accounts = const [];

  @override
  void initState() {
    super.initState();
    _loadAccounts();
  }

  void _showDemoBlocked() {
    _showSnack(
        'Mode demo hanya bisa melihat akun marketplace. Perubahan akun dikunci.');
  }

  void _showSuperAdminOnly() {
    _showSnack('Aksi ini hanya tersedia untuk Super Admin.');
  }

  @override
  void dispose() {
    _storeAliasController.dispose();
    super.dispose();
  }

  Future<void> _loadAccounts() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final accounts = await _service.listAccounts(
        tenantId: widget.currentUser.tenantId,
      );
      if (!mounted) return;
      setState(() => _accounts = accounts);
    } catch (error) {
      if (!mounted) return;
      setState(() => _errorMessage = error.toString());
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _createConnectLink() async {
    if (!_canConnectNew) {
      _showSuperAdminOnly();
      return;
    }

    final alias = _storeAliasController.text.trim();
    if (alias.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Isi nama toko / alias internal dulu.')),
      );
      return;
    }

    setState(() {
      _isCreatingLink = true;
      _generatedLink = null;
      _generatedLinkTitle = null;
      _generatedLinkEnvironment = null;
      _generatedLinkHost = null;
      _generatedLinkCredentialSource = null;
      _generatedLinkPartnerIdMasked = null;
      _generatedLinkRedirectUriConfigured = false;
      _generatedLinkUsedFallbackCredential = false;
      _generatedLinkExpiresAt = null;
      _errorMessage = null;
    });

    try {
      final link = await _service.createConnectLink(
        marketplace: _selectedMarketplace,
        storeAlias: alias,
        authAction: 'connect_new',
        environment: _selectedEnvironment,
      );

      if (!mounted) return;
      setState(() {
        _generatedLink = link.authorizationUrl;
        _generatedLinkTitle = 'Tambah Toko';
        _generatedLinkEnvironment = link.environment;
        _generatedLinkHost = link.shopeeHost;
        _generatedLinkCredentialSource = link.shopeeCredentialSource;
        _generatedLinkPartnerIdMasked = link.shopeePartnerIdMasked;
        _generatedLinkRedirectUriConfigured = link.shopeeRedirectUriConfigured;
        _generatedLinkUsedFallbackCredential =
            link.shopeeUsedFallbackCredential;
        _generatedLinkExpiresAt = link.expiresAt;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _errorMessage = error.toString());
    } finally {
      if (mounted) setState(() => _isCreatingLink = false);
    }
  }

  Future<void> _reconnectAccount(MarketplaceAccountPublic account) async {
    if (!_canReconnect) {
      _showDemoBlocked();
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Hubungkan Ulang marketplace account?'),
        content: Text(
          'Hubungkan ulang toko "${account.safeStoreName}". Pastikan login menggunakan toko yang sama.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Generate Link'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    setState(() {
      _isCreatingLink = true;
      _generatedLink = null;
      _generatedLinkTitle = null;
      _generatedLinkEnvironment = null;
      _generatedLinkHost = null;
      _generatedLinkCredentialSource = null;
      _generatedLinkPartnerIdMasked = null;
      _generatedLinkRedirectUriConfigured = false;
      _generatedLinkUsedFallbackCredential = false;
      _generatedLinkExpiresAt = null;
      _errorMessage = null;
    });

    try {
      final link = await _service.createConnectLink(
        marketplace: account.marketplace,
        storeAlias: account.safeStoreName,
        authAction: 'reconnect',
        marketplaceAccountId: account.marketplaceAccountId,
        environment: account.environment,
      );

      if (!mounted) return;
      setState(() {
        _generatedLink = link.authorizationUrl;
        _generatedLinkTitle = 'Hubungkan Ulang ${account.safeStoreName}';
        _generatedLinkEnvironment = link.environment;
        _generatedLinkHost = link.shopeeHost;
        _generatedLinkCredentialSource = link.shopeeCredentialSource;
        _generatedLinkPartnerIdMasked = link.shopeePartnerIdMasked;
        _generatedLinkRedirectUriConfigured = link.shopeeRedirectUriConfigured;
        _generatedLinkUsedFallbackCredential =
            link.shopeeUsedFallbackCredential;
        _generatedLinkExpiresAt = link.expiresAt;
      });
      await _copyGeneratedLink(showSnack: false);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text(
                'Hubungkan Ulang link dibuat dan disalin. Buka dengan akun seller yang sama.')),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _errorMessage = error.toString());
    } finally {
      if (mounted) setState(() => _isCreatingLink = false);
    }
  }

  Future<void> _toggleStockSync(
      MarketplaceAccountPublic account, bool enabled) async {
    if (!_canReconnect) {
      _showDemoBlocked();
      return;
    }

    try {
      await _service.setMarketplaceAccountStockSyncEnabled(
        tenantId: widget.currentUser.tenantId,
        marketplaceAccountId: account.marketplaceAccountId,
        enabled: enabled,
      );
      await _loadAccounts();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(enabled
              ? 'Stock sync account diaktifkan.'
              : 'Stock sync account dimatikan.'),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.toString())),
      );
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<bool> _confirmHapusAccount(MarketplaceAccountPublic account) async {
    String typed = '';

    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      useRootNavigator: true,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            final canHapus = typed.trim().toUpperCase() == 'DELETE';

            return AlertDialog(
              title: Text('Hapus akun marketplace?'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Akun "${account.safeStoreName}" akan dihapus permanen beserta data marketplace terkait. Data order, mapping SKU, produk marketplace, finance marketplace, refund/cancel, dan log sync untuk akun ini tidak akan tampil lagi.',
                  ),
                  const SizedBox(height: 12),
                  Text('Ketik DELETE untuk konfirmasi.'),
                  const SizedBox(height: 8),
                  TextField(
                    autofocus: true,
                    textInputAction: TextInputAction.done,
                    onChanged: (value) => setDialogState(() => typed = value),
                    onSubmitted: (_) {
                      if (canHapus) {
                        Navigator.of(dialogContext, rootNavigator: true)
                            .pop(true);
                      }
                    },
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      hintText: 'DELETE',
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () =>
                      Navigator.of(dialogContext, rootNavigator: true)
                          .pop(false),
                  child: Text('Batal'),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: AppUi.red),
                  onPressed: canHapus
                      ? () => Navigator.of(dialogContext, rootNavigator: true)
                          .pop(true)
                      : null,
                  child: Text('Hapus'),
                ),
              ],
            );
          },
        );
      },
    );

    // Tunggu route dialog benar-benar dilepas sebelum page melakukan setState/reload.
    // Ini menghindari Flutter assertion "_dependents.isEmpty" yang biasanya muncul
    // saat widget dialog/TextField masih punya dependency tetapi parent sudah berubah.
    await Future<void>.delayed(Duration.zero);

    return confirmed == true;
  }

  Future<void> _deleteAccount(MarketplaceAccountPublic account) async {
    if (!_canDeleteAccount) {
      _showSuperAdminOnly();
      return;
    }
    if (_deletingAccountIds.contains(account.marketplaceAccountId)) return;

    final confirmed = await _confirmHapusAccount(account);
    if (!mounted || confirmed != true) return;

    setState(() {
      _deletingAccountIds.add(account.marketplaceAccountId);
      _errorMessage = null;
    });

    try {
      await _service.deleteMarketplaceAccount(
        tenantId: widget.currentUser.tenantId,
        marketplaceAccountId: account.marketplaceAccountId,
      );

      if (!mounted) return;

      setState(() {
        _accounts = _accounts
            .where((item) =>
                item.marketplaceAccountId != account.marketplaceAccountId)
            .toList(growable: false);
      });

      await _loadAccounts();

      if (!mounted) return;
      _showSnack(
          'Akun marketplace dan data terkait berhasil dihapus permanen.');
    } catch (error) {
      if (!mounted) return;
      setState(() => _errorMessage = error.toString());
      _showSnack(error.toString());
    } finally {
      if (mounted) {
        setState(
            () => _deletingAccountIds.remove(account.marketplaceAccountId));
      }
    }
  }

  Future<void> _copyGeneratedLink({bool showSnack = true}) async {
    final link = _generatedLink;
    if (link == null || link.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: link));
    if (!mounted || !showSnack) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
          content: Text('Link otorisasi disalin. Buka di browser seller.')),
    );
  }

  Future<void> _openGeneratedLink() async {
    final link = _generatedLink;
    final uri = link == null ? null : Uri.tryParse(link);
    if (uri == null) {
      AppUi.showSnack('Link otorisasi belum valid.');
      return;
    }
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened)
      AppUi.showSnack('Link belum bisa dibuka. Copy lalu buka manual.');
  }

  String _fmtDate(DateTime? date) {
    if (date == null) return '-';
    final local = date.toLocal();
    final y = local.year.toString().padLeft(4, '0');
    final m = local.month.toString().padLeft(2, '0');
    final d = local.day.toString().padLeft(2, '0');
    final h = local.hour.toString().padLeft(2, '0');
    final min = local.minute.toString().padLeft(2, '0');
    return '$y-$m-$d $h:$min';
  }

  Widget _connectCard() {
    return NiceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionTitle(
              title: _canConnectNew
                  ? 'Tambah Akun Marketplace'
                  : 'Otorisasi Marketplace'),
          const SizedBox(height: 10),
          Text(
            _isDemoSuperAdmin
                ? 'Mode demo: akun marketplace hanya bisa dilihat.'
                : !_canConnectNew
                    ? 'Admin dapat hubungkan ulang toko yang sudah ada dan mengatur sinkronisasi. Tambah toko baru hanya untuk Super Admin.'
                    : 'Gunakan tombol ini untuk menambah toko baru. Jangan gunakan hubungkan ulang jika ingin menambah toko berbeda.',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 14),
          DropdownButtonFormField<String>(
            value: _selectedMarketplace,
            decoration: const InputDecoration(
              labelText: 'Marketplace',
              border: OutlineInputBorder(),
            ),
            items: MarketplaceProviders.active
                .map(
                  (provider) => DropdownMenuItem<String>(
                    value: provider.id,
                    child: Text(provider.label),
                  ),
                )
                .toList(growable: false),
            onChanged: _isCreatingLink || !_canConnectNew
                ? null
                : (value) {
                    if (value == null) return;
                    setState(() {
                      _selectedMarketplace = value;
                      if (value == 'shopee') _selectedEnvironment = 'testing';
                    });
                  },
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            value: _selectedEnvironment,
            decoration: const InputDecoration(
              labelText: 'Account Type',
              border: OutlineInputBorder(),
            ),
            items: const [
              DropdownMenuItem(
                  value: 'testing', child: Text('Testing / Dev Shop')),
              DropdownMenuItem(
                  value: 'production',
                  child: Text('Production / Real Account')),
            ],
            onChanged: _isCreatingLink || !_canConnectNew
                ? null
                : (value) {
                    if (value == null) return;
                    setState(() => _selectedEnvironment = value);
                  },
          ),
          if (_selectedMarketplace == 'shopee' &&
              _selectedEnvironment == 'testing') ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppUi.orange.withOpacity(0.12),
                borderRadius: BorderRadius.zero,
                border: Border.all(color: AppUi.orange.withOpacity(0.36)),
              ),
              child: const Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.science_outlined, color: AppUi.orange),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Shopee yang masih developing wajib pakai Testing / Dev Shop. Isi SHOPEE_TEST_PARTNER_ID dan SHOPEE_TEST_PARTNER_KEY di Supabase Secrets untuk sandbox. Backend sekarang tidak memakai fallback credential production untuk mode Testing.',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 12),
          TextField(
            controller: _storeAliasController,
            enabled: !_isCreatingLink && _canConnectNew,
            decoration: const InputDecoration(
              labelText: 'Nama toko / alias internal',
              hintText: 'Contoh: Toko Utama / Akun Marketplace Production',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _isCreatingLink
                ? null
                : (_canConnectNew ? _createConnectLink : _showSuperAdminOnly),
            icon: _isCreatingLink
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(Icons.add_link),
            label: Text(_isCreatingLink ? 'Membuat link...' : 'Tambah Toko'),
          ),
          if (_generatedLink != null) _authorizationLinkBox(),
        ],
      ),
    );
  }

  Widget _authorizationLinkBox() {
    final environment = (_generatedLinkEnvironment ?? _selectedEnvironment)
        .toLowerCase()
        .trim();
    final isTesting = environment == 'testing';
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Color.alphaBlend(
            (isTesting ? Theme.of(context).colorScheme.secondary : Theme.of(context).colorScheme.primary)
                .withOpacity(.12),
            (Theme.of(context).cardColor),
          ),
          borderRadius: BorderRadius.zero,
          border: Border.all(color: (Theme.of(context).dividerColor), width: 1.4),
          boxShadow: [
            BoxShadow(
              color: (Theme.of(context).dividerColor).withOpacity(.12),
              blurRadius: 0,
              offset: const Offset(3, 3),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: isTesting
                        ? Theme.of(context).colorScheme.secondary
                        : Theme.of(context).colorScheme.primary,
                    borderRadius: BorderRadius.zero,
                    border:
                        Border.all(color: (Theme.of(context).dividerColor), width: 1.2),
                  ),
                  child: Icon(
                    isTesting
                        ? Icons.science_outlined
                        : Icons.storefront_outlined,
                    color: Colors.white,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _generatedLinkTitle ?? 'Link otorisasi siap',
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          color: (Theme.of(context).textTheme).bodyLarge?.color,
                        ),
                      ),
                      Text(
                        isTesting
                            ? 'Mode Testing / Dev Shop'
                            : 'Mode Production / Real Account',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          color: (Theme.of(context).textTheme).bodyMedium?.color,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (_generatedLinkHost != null &&
                _generatedLinkHost!.trim().isNotEmpty) ...[
              Text(
                'Shopee host: $_generatedLinkHost',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: (Theme.of(context).textTheme).bodyMedium?.color,
                ),
              ),
              const SizedBox(height: 6),
            ],
            if ((_generatedLinkPartnerIdMasked ?? '').trim().isNotEmpty ||
                (_generatedLinkCredentialSource ?? '').trim().isNotEmpty) ...[
              Text(
                'Credential: ${_generatedLinkCredentialSource ?? '-'}'
                '${(_generatedLinkPartnerIdMasked ?? '').trim().isNotEmpty ? ' / Partner ${_generatedLinkPartnerIdMasked}' : ''}',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: (Theme.of(context).textTheme).bodyMedium?.color,
                ),
              ),
              const SizedBox(height: 6),
            ],
            if (isTesting &&
                (_generatedLinkHost ?? '').trim().isNotEmpty &&
                !_generatedLinkRedirectUriConfigured) ...[
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.error.withOpacity(.14),
                  borderRadius: BorderRadius.zero,
                  border: Border.all(
                    color: (Theme.of(context).dividerColor).withOpacity(.22),
                  ),
                ),
                child: Text(
                  'Redirect URI Shopee belum terdeteksi lengkap. Isi SHOPEE_REDIRECT_URI atau SHOPEE_TEST_REDIRECT_URI di Supabase Secrets.',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12),
                ),
              ),
              const SizedBox(height: 8),
            ],
            if (_generatedLinkUsedFallbackCredential) ...[
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.secondary.withOpacity(.18),
                  borderRadius: BorderRadius.zero,
                  border: Border.all(
                    color: (Theme.of(context).dividerColor).withOpacity(.22),
                  ),
                ),
                child: Text(
                  'Backend melaporkan link ini dibuat dari credential fallback versi lama. Generate ulang link Testing setelah SHOPEE_TEST_PARTNER_ID dan SHOPEE_TEST_PARTNER_KEY lengkap.',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12),
                ),
              ),
              const SizedBox(height: 8),
            ],
            SelectableText(
              _generatedLink!,
              style: TextStyle(
                fontSize: 12,
                color: (Theme.of(context).textTheme).bodyLarge?.color,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text('Expired: ${_fmtDate(_generatedLinkExpiresAt)}'),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _copyGeneratedLink,
                  icon: Icon(Icons.copy),
                  label: Text('Copy Link'),
                ),
                FilledButton.icon(
                  onPressed: _openGeneratedLink,
                  icon: Icon(Icons.open_in_new),
                  label: Text('Buka Link'),
                ),
                OutlinedButton.icon(
                  onPressed: _loadAccounts,
                  icon: Icon(Icons.refresh),
                  label: Text('Refresh Accounts'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Color _marketplaceAccent(MarketplaceAccountPublic account) {
    if (account.isTesting) return Theme.of(context).colorScheme.tertiary;
    switch (account.marketplace) {
      case 'tiktok_shop':
        return Theme.of(context).colorScheme.secondary;
      case 'shopee':
        return Theme.of(context).colorScheme.primary;
      default:
        return AppUi.blue;
    }
  }

  List<Color> _marketplaceGradient(MarketplaceAccountPublic account) {
    if (account.isTesting) {
      return [Theme.of(context).colorScheme.tertiary.withOpacity(0.1), Theme.of(context).colorScheme.primary.withOpacity(0.1), Theme.of(context).colorScheme.secondary.withOpacity(0.1)];
    }
    switch (account.marketplace) {
      case 'tiktok_shop':
        return [Theme.of(context).colorScheme.primary.withOpacity(0.1), Theme.of(context).colorScheme.secondary.withOpacity(0.1), Theme.of(context).colorScheme.tertiary.withOpacity(0.1)];
      case 'shopee':
        return [Theme.of(context).colorScheme.secondary.withOpacity(0.1), Theme.of(context).colorScheme.tertiary.withOpacity(0.1), Theme.of(context).colorScheme.primary.withOpacity(0.1)];
      default:
        return [Theme.of(context).colorScheme.primary.withOpacity(0.1), Theme.of(context).colorScheme.surface.withOpacity(0.1), Theme.of(context).colorScheme.tertiary.withOpacity(0.1)];
    }
  }

  IconData _marketplaceIcon(MarketplaceAccountPublic account) {
    switch (account.marketplace) {
      case 'tiktok_shop':
        return Icons.music_note_rounded;
      case 'shopee':
        return Icons.shopping_bag_outlined;
      default:
        return Icons.storefront_outlined;
    }
  }

  String _tokenHealthText(DateTime? accessTokenExpiredAt) {
    if (accessTokenExpiredAt == null) return 'Status belum terbaca';
    final diff = accessTokenExpiredAt.toLocal().difference(DateTime.now());
    if (diff.isNegative) return 'Perlu hubungkan ulang';
    if (diff.inHours < 24) return 'Expired kurang dari 24 jam';
    if (diff.inDays <= 3) return 'Expired ${diff.inDays} hari lagi';
    return 'Terhubung';
  }

  Color _tokenHealthColor(DateTime? accessTokenExpiredAt) {
    if (accessTokenExpiredAt == null) return AppUi.orange;
    final diff = accessTokenExpiredAt.toLocal().difference(DateTime.now());
    if (diff.isNegative) return AppUi.red;
    if (diff.inDays <= 3) return AppUi.orange;
    return AppUi.green;
  }

  bool _tokenNeedsAdminAttention(MarketplaceAccountPublic account) {
    final expiredAt = account.accessTokenExpiredAt;
    if (expiredAt == null) return true;
    return expiredAt.toLocal().difference(DateTime.now()).inDays <= 3;
  }

  String _tokenAttentionText() {
    final count = _accounts.where(_tokenNeedsAdminAttention).length;
    if (count <= 0) return '';
    final expired = _accounts.where((item) {
      final expiredAt = item.accessTokenExpiredAt;
      return expiredAt == null || expiredAt.toLocal().isBefore(DateTime.now());
    }).length;
    if (expired > 0)
      return '$expired akun sudah expired. Hubungkan ulang agar sinkron tidak berhenti.';
    return '$count akun akan expired dalam 3 hari. Hubungkan ulang sebelum sinkron berhenti.';
  }

  Widget _tokenAttentionCard() {
    final message = _tokenAttentionText();
    if (message.isEmpty) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppUi.orange.withOpacity(0.14),
        borderRadius: BorderRadius.zero,
        border: Border.all(color: AppUi.orange.withOpacity(0.42)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.notifications_active_outlined, color: AppUi.orange),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                  color: (Theme.of(context).textTheme).bodyLarge?.color,
                  fontWeight: FontWeight.w800,
                  height: 1.35),
            ),
          ),
        ],
      ),
    );
  }

  Widget _accountCard(MarketplaceAccountPublic account) {
    final hasError =
        account.lastError != null && account.lastError!.trim().isNotEmpty;
    final accent = _marketplaceAccent(account);
    final tokenColor = _tokenHealthColor(account.accessTokenExpiredAt);

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.zero,
        color: Theme.of(context).cardColor,
        border: Border.all(color: Colors.black, width: 2.5),
        boxShadow: const [
          BoxShadow(
            color: Colors.black,
            blurRadius: 0,
            offset: Offset(5, 5),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 54,
                      height: 54,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.zero,
                        color: accent,
                        border: Border.all(
                            color: (Theme.of(context).dividerColor), width: 1.3),
                        boxShadow: [
                          BoxShadow(
                            color: (Theme.of(context).dividerColor).withOpacity(0.16),
                            blurRadius: 0,
                            offset: const Offset(3, 3),
                          ),
                        ],
                      ),
                      child: Icon(_marketplaceIcon(account),
                          color: Colors.white, size: 30),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            account.safeStoreName,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: (Theme.of(context).textTheme).bodyLarge?.color,
                              fontWeight: FontWeight.w900,
                              fontSize: 19,
                              height: 1.15,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 8,
                            runSpacing: 6,
                            children: [
                              _GlassPill(
                                  icon: Icons.store_mall_directory_outlined,
                                  label: account.marketplaceLabel),
                              _GlassPill(
                                  icon: Icons.public,
                                  label: account.shopRegion),
                              _GlassPill(
                                  icon: account.isTesting
                                      ? Icons.science_outlined
                                      : Icons.verified_outlined,
                                  label: account.environmentLabel),
                              _GlassPill(
                                  icon: account.stockSyncEnabled
                                      ? Icons.sync
                                      : Icons.sync_disabled,
                                  label: account.stockSyncEnabled
                                      ? 'Sinkron Stok ON'
                                      : 'Sinkron Stok OFF'),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color:
                            AppUi.statusColor(account.status).withOpacity(0.16),
                        borderRadius: BorderRadius.zero,
                        border: Border.all(
                            color: AppUi.statusColor(account.status)
                                .withOpacity(0.46)),
                      ),
                      child: Text(
                        account.status.toUpperCase(),
                        style: TextStyle(
                            color: (Theme.of(context).textTheme).bodyLarge?.color,
                            fontWeight: FontWeight.w900,
                            fontSize: 11,
                            letterSpacing: 0),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.76),
                    borderRadius: BorderRadius.zero,
                    border:
                        Border.all(color: (Theme.of(context).dividerColor), width: 1.2),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              color: tokenColor,
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                    color: tokenColor.withOpacity(0.45),
                                    blurRadius: 0)
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _tokenHealthText(account.accessTokenExpiredAt),
                              style: TextStyle(
                                  color: (Theme.of(context).textTheme).bodyLarge?.color,
                                  fontWeight: FontWeight.w900),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final twoColumns = constraints.maxWidth >= 460;
                          final itemWidth = twoColumns
                              ? (constraints.maxWidth - 10) / 2
                              : constraints.maxWidth;
                          return Wrap(
                            spacing: 10,
                            runSpacing: 10,
                            children: [
                              _AccountInfoTile(
                                  width: itemWidth,
                                  label: 'Shop ID',
                                  value: account.shopIdMasked ?? '-',
                                  icon: Icons.tag),
                              _AccountInfoTile(
                                  width: itemWidth,
                                  label: 'Shop Cipher',
                                  value: account.shopCipherMasked ?? '-',
                                  icon: Icons.vpn_key_outlined),
                              _AccountInfoTile(
                                  width: itemWidth,
                                  label: 'Berlaku Sampai',
                                  value: _fmtDate(account.accessTokenExpiredAt),
                                  icon: Icons.timer_outlined),
                              _AccountInfoTile(
                                  width: itemWidth,
                                  label: 'Perlu Update',
                                  value:
                                      _fmtDate(account.refreshTokenExpiredAt),
                                  icon: Icons.autorenew),
                            ],
                          );
                        },
                      ),
                    ],
                  ),
                ),
                if (hasError) ...[
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppUi.red.withOpacity(0.12),
                      borderRadius: BorderRadius.zero,
                      border: Border.all(color: AppUi.red.withOpacity(0.38)),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.warning_amber_rounded,
                            color: AppUi.red),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            account.lastError!,
                            style: TextStyle(
                                color: (Theme.of(context).textTheme).bodyLarge?.color,
                                fontWeight: FontWeight.w800,
                                height: 1.35),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: _isCreatingLink
                          ? null
                          : (_canReconnect
                              ? () => _reconnectAccount(account)
                              : _showDemoBlocked),
                      icon: Icon(Icons.link),
                      label: Text('Hubungkan Ulang'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _canReconnect
                          ? () => _toggleStockSync(
                              account, !account.stockSyncEnabled)
                          : _showDemoBlocked,
                      icon: Icon(account.stockSyncEnabled
                          ? Icons.sync_disabled
                          : Icons.sync),
                      label: Text(account.stockSyncEnabled
                          ? 'Matikan Sinkron'
                          : 'Aktifkan Sinkron'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: (Theme.of(context).textTheme).bodyLarge?.color,
                        side: BorderSide(color: (Theme.of(context).dividerColor)),
                      ),
                    ),
                    if (_canDeleteAccount)
                      OutlinedButton.icon(
                        onPressed: _deletingAccountIds
                                .contains(account.marketplaceAccountId)
                            ? null
                            : () => _deleteAccount(account),
                        icon: _deletingAccountIds
                                .contains(account.marketplaceAccountId)
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : Icon(Icons.delete_outline),
                        label: Text(_deletingAccountIds
                                .contains(account.marketplaceAccountId)
                            ? 'Menghapus...'
                            : 'Hapus'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Theme.of(context).colorScheme.error,
                          side: BorderSide(color: Theme.of(context).colorScheme.error),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
    );
  }

  String get _tenantShortLabel {
    final value = widget.currentUser.tenantId.trim();
    if (value.isEmpty) return '-';
    if (value.length <= 8) return value;
    return '${value.substring(0, 8)}…';
  }

  int get _testingCount => _accounts.where((a) => a.isTesting).length;
  int get _productionCount => _accounts.where((a) => !a.isTesting).length;

  Widget _body() {
    if (_isLoading) return const LoadingState();

    return RefreshIndicator(
      onRefresh: _loadAccounts,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 90),
        children: [
          FuturisticHeader(
            icon: Icons.hub_outlined,
            title: 'Akun Marketplace',
            subtitle: 'Kelola koneksi toko dan sinkronisasi stok marketplace.',
            stats: [
              StatPill(label: 'Connected', value: _accounts.length.toString()),
              StatPill(label: 'Testing', value: _testingCount.toString()),
              StatPill(label: 'Production', value: _productionCount.toString()),
            ],
          ),
          const SizedBox(height: 14),
          if (_errorMessage != null) ...[
            ErrorState(message: _errorMessage!, onRetry: _loadAccounts),
            const SizedBox(height: 14),
          ],
          _tokenAttentionCard(),
          _connectCard(),
          const SizedBox(height: 16),
          const SectionTitle(title: 'Akun Terhubung'),
          const SizedBox(height: 10),
          if (_accounts.isEmpty)
            const EmptyState(
              title: 'Belum ada akun marketplace',
              subtitle:
                  'Tambahkan akun testing atau production untuk mulai sinkronisasi.',
            )
          else
            ..._accounts.map(_accountCard),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Akun Marketplace'),
        actions: [
          IconButton(onPressed: _loadAccounts, icon: Icon(Icons.refresh)),
        ],
      ),
      body: _body(),
    );
  }
}

class _GlassPill extends StatelessWidget {
  final IconData icon;
  final String label;

  const _GlassPill({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: (Theme.of(context).cardColor).withOpacity(0.78),
        borderRadius: BorderRadius.zero,
        border: Border.all(color: (Theme.of(context).dividerColor).withOpacity(0.24)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: Theme.of(context).colorScheme.secondary),
          const SizedBox(width: 5),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 160),
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: (Theme.of(context).textTheme).bodyLarge?.color,
                fontWeight: FontWeight.w800,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AccountInfoTile extends StatelessWidget {
  final double width;
  final String label;
  final String value;
  final IconData icon;

  const _AccountInfoTile(
      {required this.width,
      required this.label,
      required this.value,
      required this.icon});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: (Theme.of(context).cardColor),
          borderRadius: BorderRadius.zero,
          border: Border.all(color: (Theme.of(context).dividerColor).withOpacity(0.22)),
        ),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary.withOpacity(0.14),
                borderRadius: BorderRadius.zero,
              ),
              child: Icon(icon, color: Theme.of(context).colorScheme.primary, size: 18),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label.toUpperCase(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: (Theme.of(context).textTheme).bodySmall?.color,
                        fontWeight: FontWeight.w900,
                        fontSize: 10,
                        letterSpacing: 0),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: (Theme.of(context).textTheme).bodyLarge?.color,
                        fontWeight: FontWeight.w900,
                        fontSize: 13),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
