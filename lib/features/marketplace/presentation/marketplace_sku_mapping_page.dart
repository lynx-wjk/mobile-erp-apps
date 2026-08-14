// ignore_for_file: unused_element
import 'dart:typed_data';

import 'package:excel/excel.dart' hide Border;
import 'package:file_selector/file_selector.dart' as fs;
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/constants/marketplace_providers.dart';
import '../../../core/ui/app_ui.dart';
import '../../../core/ui/web_responsive_layout.dart';
import '../../../models/app_user.dart';
import '../../../core/constants/app_roles.dart';
import '../../stock/models/product.dart';
import '../models/marketplace_account_public.dart';
import '../models/marketplace_sku_map.dart';
import '../models/marketplace_variant_snapshot.dart';
import '../services/marketplace_service.dart';

class MarketplaceSkuMappingPage extends StatefulWidget {
  final AppUser currentUser;

  const MarketplaceSkuMappingPage({
    super.key,
    required this.currentUser,
  });

  @override
  State<MarketplaceSkuMappingPage> createState() =>
      _MarketplaceSkuMappingPageState();
}

class _MarketplaceSkuMappingPageState extends State<MarketplaceSkuMappingPage> {
  String get _roleId => widget.currentUser.role.roleId;
  bool get _canManageHppMapping =>
      AppRolePermissions.isSuperRoleId(_roleId) &&
      !AppRolePermissions.isDemoSuperAdminId(_roleId);

  final MarketplaceService _service = MarketplaceService();

  final TextEditingController _variantCariController = TextEditingController();
  final TextEditingController _productCariController = TextEditingController();
  final TextEditingController _mapCariController = TextEditingController();
  final TextEditingController _hppCariController = TextEditingController();

  bool _isLoading = true;
  bool _isPulling = false;
  bool _isSaving = false;
  bool _isSearchingProduct = false;
  bool _isHppLoading = false;
  bool _isHppSaving = false;
  bool _isSyncingHppFromSkuMap = false;
  bool _isRefreshingFinanceAfterHpp = false;
  bool _isSkuExcelBusy = false;
  bool _isSyncingHpp = false;
  bool _isRecalculatingFinance = false;
  bool _hppMissingOnly = false;
  bool _unmappedOnly = false;
  bool _formSyncEnabled = true;
  String? _errorMessage;

  List<MarketplaceAccountPublic> _accounts = const [];
  List<MarketplaceVariantSnapshot> _variants = const [];
  List<MarketplaceSkuMap> _maps = const [];
  List<Product> _products = const [];
  List<Map<String, dynamic>> _hppRows = const [];
  int _hppTotal = 0;
  int _hppPage = 1;
  static const int _hppPageSize = 20;

  String _selectedMarketplace = 'all';
  String? _selectedAccountId;
  String? _selectedVariantId;
  String? _selectedProductId;
  String? _selectedMarketplaceProductId;
  final Map<String, String> _bulkLocalProductByVariantId = {};

  @override
  void initState() {
    super.initState();
    _loadInitial();
  }

  @override
  void dispose() {
    _variantCariController.dispose();
    _productCariController.dispose();
    _mapCariController.dispose();
    _hppCariController.dispose();
    super.dispose();
  }

  Future<void> _loadInitial() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final accountsRaw =
          await _service.listAccounts(tenantId: widget.currentUser.tenantId);
      final products = await _service.listLocalProducts(
          tenantId: widget.currentUser.tenantId);

      final accounts = accountsRaw.where((account) {
        final status = account.status.toLowerCase().trim();
        return status != 'deleted' &&
            status != 'revoked' &&
            status != 'disabled';
      }).toList();

      MarketplaceAccountPublic? selectedAccount;
      for (final account in accounts) {
        if (account.marketplaceAccountId == _selectedAccountId) {
          selectedAccount = account;
          break;
        }
      }
      if (selectedAccount == null) {
        for (final account in accounts) {
          final status = account.status.toLowerCase().trim();
          if (status == 'connected' ||
              status == 'active' ||
              status == 'authorized' ||
              status == 'ready') {
            selectedAccount = account;
            break;
          }
        }
      }
      selectedAccount ??= accounts.isEmpty ? null : accounts.first;

      if (!mounted) return;
      setState(() {
        _accounts = accounts;
        _products = products;
        _selectedMarketplace = selectedAccount == null
            ? 'all'
            : MarketplaceProviders.normalize(selectedAccount.marketplace);
        _selectedAccountId = selectedAccount?.marketplaceAccountId;
      });

      await Future.wait([
        _loadVariants(),
        _loadMaps(),
        _loadHpp(resetPage: true),
      ]);
    } catch (error) {
      if (!mounted) return;
      setState(() => _errorMessage = error.toString());
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _loadVariants() async {
    final accountId = _selectedAccountId;
    if (accountId == null || accountId.isEmpty) {
      setState(() => _variants = const []);
      return;
    }

    try {
      final variants = await _service.listMarketplaceVariants(
        tenantId: widget.currentUser.tenantId,
        marketplaceAccountId: accountId,
        search: _variantCariController.text,
        unmappedOnly: _unmappedOnly,
      );

      if (!mounted) return;
      setState(() {
        _variants = variants;
        if (_selectedVariantId != null &&
            !_variants.any((item) =>
                item.marketplaceVariantSnapshotId == _selectedVariantId)) {
          _selectedVariantId = null;
        }

        final productIds = _variants
            .map((item) => item.marketplaceProductId)
            .where((value) => value.trim().isNotEmpty)
            .toSet();

        if (_selectedMarketplaceProductId != null &&
            !productIds.contains(_selectedMarketplaceProductId)) {
          _selectedMarketplaceProductId = null;
        }

        if (_selectedMarketplaceProductId == null && productIds.isNotEmpty) {
          _selectedMarketplaceProductId = productIds.first;
        }

        _bulkLocalProductByVariantId.removeWhere(
          (variantId, _) => !_variants
              .any((item) => item.marketplaceVariantSnapshotId == variantId),
        );

        _errorMessage = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _errorMessage = error.toString());
    }
  }

  Future<void> _loadMaps() async {
    final accountId = _selectedAccountId;
    if (accountId == null || accountId.isEmpty) {
      setState(() => _maps = const []);
      return;
    }

    try {
      final maps = await _service.listSkuMaps(
        tenantId: widget.currentUser.tenantId,
        marketplaceAccountId: accountId,
        search: _mapCariController.text,
      );

      if (!mounted) return;
      setState(() {
        _maps = maps;
        _errorMessage = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _errorMessage = error.toString());
    }
  }

  Future<void> _refreshAll() async {
    await Future.wait([
      _loadVariants(),
      _loadMaps(),
      _loadHpp(),
    ]);
  }

  Future<void> _loadHpp({bool resetPage = false}) async {
    if (!_canManageHppMapping) return;
    final accountId = _selectedAccountId;
    if (accountId == null || accountId.isEmpty) {
      setState(() {
        _hppRows = const [];
        _hppTotal = 0;
      });
      return;
    }
    if (resetPage) _hppPage = 1;

    setState(() => _isHppLoading = true);
    try {
      final payload = await _service.hppList(
        accountId: accountId,
        search: _hppCariController.text,
        missingOnly: _hppMissingOnly,
        page: _hppPage,
        pageSize: _hppPageSize,
      );
      final rows = <Map<String, dynamic>>[];
      final rawRows = payload['rows'];
      if (rawRows is List) {
        for (final item in rawRows) {
          if (item is Map) rows.add(Map<String, dynamic>.from(item));
        }
      }
      if (!mounted) return;
      setState(() {
        _hppRows = rows;
        _hppTotal =
            int.tryParse('${payload['total'] ?? rows.length}') ?? rows.length;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _errorMessage = error.toString());
    } finally {
      if (mounted) setState(() => _isHppLoading = false);
    }
  }

  String _rowText(Map<String, dynamic> row, List<String> keys,
      {String fallback = ''}) {
    for (final key in keys) {
      final value = row[key]?.toString().trim();
      if (value != null && value.isNotEmpty && value != 'null') return value;
    }
    return fallback;
  }

  double _rowDouble(Map<String, dynamic> row, List<String> keys) {
    for (final key in keys) {
      final value = row[key];
      if (value is num) return value.toDouble();
      final parsed = _parseNumberText(value?.toString() ?? '');
      if (parsed != 0) return parsed;
    }
    return 0;
  }

  double _parseNumberText(String raw) {
    var text = raw.trim();
    if (text.isEmpty || text == '-' || text.toLowerCase() == 'null') return 0;
    text = text
        .replaceAll('Rp', '')
        .replaceAll('rp', '')
        .replaceAll('%', '')
        .replaceAll(' ', '')
        .replaceAll(RegExp(r'[^0-9,.-]'), '');
    if (text.isEmpty || text == '-' || text == ',' || text == '.') return 0;

    final looksLikeIdThousands =
        RegExp(r'^-?\d{1,3}(\.\d{3})+$').hasMatch(text);
    if (looksLikeIdThousands) {
      text = text.replaceAll('.', '');
    } else if (text.contains('.') && text.contains(',')) {
      text = text.replaceAll('.', '').replaceAll(',', '.');
    } else if (text.contains(',')) {
      text = text.replaceAll(',', '.');
    }
    return double.tryParse(text) ?? 0;
  }

  int _resultInt(Map<String, dynamic> result, String key) {
    final value = result[key];
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  String _hppUpsertMessage(Map<String, dynamic> result, int requested) {
    final upserted = _resultInt(result, 'upserted');
    final skippedConflict = _resultInt(result, 'skipped_conflict');
    final skippedInvalid = _resultInt(result, 'skipped_invalid');
    final parts = <String>['$upserted/$requested baris HPP tersimpan'];
    if (skippedConflict > 0) parts.add('$skippedConflict konflik SKU lokal');
    if (skippedInvalid > 0) parts.add('$skippedInvalid baris invalid');
    final conflicts = result['conflicts'];
    if (conflicts is List && conflicts.isNotEmpty) {
      final first = conflicts.first;
      if (first is Map) {
        final sku = first['local_sku']?.toString();
        if (sku != null && sku.isNotEmpty)
          parts.add('contoh konflik: $sku sudah dipakai mapping lain');
      }
    }
    return parts.join(' · ');
  }

  Product? _productBySku(String? sku) {
    final needle = sku?.trim().toLowerCase();
    if (needle == null || needle.isEmpty) return null;
    for (final product in _products) {
      if (product.kodeSku.trim().toLowerCase() == needle) return product;
    }
    return null;
  }

  Product? _productById(String? id) {
    if (id == null || id.trim().isEmpty) return null;
    for (final product in _products) {
      if (product.productId == id) return product;
    }
    return null;
  }

  Set<String> _usedLocalProductIds({String? exceptSkuMapId}) {
    final used = <String>{};
    for (final map in _maps) {
      final productId = map.productId?.trim();
      if (productId != null &&
          productId.isNotEmpty &&
          map.marketplaceSkuMapId != exceptSkuMapId) {
        used.add(productId);
      }
    }
    for (final row in _hppRows) {
      final productId = _rowText(row, const ['local_product_id', 'product_id']);
      final rowMapId = _rowText(row, const ['marketplace_sku_map_id']);
      if (productId.isNotEmpty && rowMapId != exceptSkuMapId)
        used.add(productId);
    }
    return used;
  }

  Future<void> _editHppRow(Map<String, dynamic> row) async {
    final currentMapId = _rowText(row, const ['marketplace_sku_map_id']);
    final currentProductId =
        _rowText(row, const ['local_product_id', 'product_id']);
    String? selectedProductId =
        currentProductId.isEmpty ? null : currentProductId;
    final hppController = TextEditingController(
        text: AppUi.moneyInput(
            _rowDouble(row, const ['hpp_amount', 'hpp_per_item', 'hpp'])));
    final marginController = TextEditingController(
        text: _rowDouble(row, const ['target_margin_percent', 'target_margin'])
            .toStringAsFixed(0));
    final usedIds = _usedLocalProductIds(exceptSkuMapId: currentMapId);

    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final current = _productById(selectedProductId);
            final availableProducts = _products
                .where((product) =>
                    !usedIds.contains(product.productId) ||
                    product.productId == selectedProductId)
                .toList();
            return Padding(
              padding: EdgeInsets.only(
                  bottom: MediaQuery.of(context).viewInsets.bottom),
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.all(18),
                children: [
                  Text('Mapping HPP Marketplace',
                      style: Theme.of(context)
                          .textTheme
                          .titleLarge
                          ?.copyWith(fontWeight: FontWeight.w800)),
                  SizedBox(height: 10),
                  Text(
                      _rowText(row,
                          const ['marketplace_product_name', 'product_name'],
                          fallback: '-'),
                      style: TextStyle(fontWeight: FontWeight.w800)),
                  Text(_rowText(
                      row,
                      const [
                        'marketplace_variant_name',
                        'variant_name',
                        'sku_name'
                      ],
                      fallback: '-')),
                  SizedBox(height: 14),
                  DropdownButtonFormField<String>(
                    value: selectedProductId,
                    isExpanded: true,
                    decoration: const InputDecoration(
                        labelText: 'Produk lokal',
                        border: OutlineInputBorder()),
                    items: availableProducts
                        .map((product) => DropdownMenuItem<String>(
                              value: product.productId,
                              child: Text(
                                  '${product.namaBarang} · ${product.kodeSku}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis),
                            ))
                        .toList(),
                    onChanged: (value) =>
                        setSheetState(() => selectedProductId = value),
                  ),
                  if (current != null) ...[
                    SizedBox(height: 8),
                    Text('Dipilih: ${current.namaBarang} · ${current.kodeSku}',
                        style: TextStyle(fontWeight: FontWeight.w700)),
                  ],
                  SizedBox(height: 12),
                  TextField(
                    controller: hppController,
                    keyboardType: TextInputType.number,
                    inputFormatters: const [AppMoneyInputFormatter()],
                    decoration: const InputDecoration(
                        labelText: 'HPP per item',
                        prefixText: 'Rp ',
                        border: OutlineInputBorder()),
                  ),
                  SizedBox(height: 12),
                  TextField(
                    controller: marginController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                        labelText: 'Target margin %',
                        border: OutlineInputBorder()),
                  ),
                  SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: selectedProductId == null ||
                            selectedProductId!.isEmpty
                        ? null
                        : () async {
                            final product = _productById(selectedProductId);
                            if (product == null) return;
                            final hpp =
                                AppUi.parseMoneyInput(hppController.text)
                                    .toDouble();
                            final margin = double.tryParse(marginController.text
                                    .replaceAll(',', '.')) ??
                                0;
                            try {
                              final result = await _service.hppUpsertBulk([
                                {
                                  'marketplace_account_id': _rowText(
                                      row, const ['marketplace_account_id'],
                                      fallback: _selectedAccountId ?? ''),
                                  'marketplace': _rowText(
                                      row, const ['marketplace'],
                                      fallback: _selectedAccount?.marketplace ??
                                          'tiktok_shop'),
                                  'marketplace_product_id': _rowText(
                                      row, const ['marketplace_product_id']),
                                  'marketplace_sku_id': _rowText(
                                      row, const ['marketplace_sku_id']),
                                  'marketplace_seller_sku': _rowText(
                                      row, const [
                                    'marketplace_seller_sku',
                                    'seller_sku'
                                  ]),
                                  'marketplace_product_name': _rowText(
                                      row, const [
                                    'marketplace_product_name',
                                    'product_name'
                                  ]),
                                  'marketplace_variant_name': _rowText(
                                      row, const [
                                    'marketplace_variant_name',
                                    'variant_name',
                                    'sku_name'
                                  ]),
                                  'local_product_id': product.productId,
                                  'local_sku': product.kodeSku,
                                  'local_product_name': product.namaBarang,
                                  'hpp': hpp,
                                  'hpp_amount': hpp,
                                  'hpp_per_item': hpp,
                                  'target_margin_percent': margin,
                                }
                              ]);
                              final upserted = _resultInt(result, 'upserted');
                              if (result['ok'] != true || upserted <= 0) {
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                          content: Text(
                                              _hppUpsertMessage(result, 1))));
                                }
                                return;
                              }
                              if (context.mounted) Navigator.pop(context, true);
                            } catch (error) {
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text(error.toString())));
                              }
                            }
                          },
                    icon: Icon(Icons.save_outlined),
                    label: Text('Simpan HPP'),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
    hppController.dispose();
    marginController.dispose();
    if (saved == true) await _loadHpp();
  }

  Future<List<Map<String, dynamic>>> _loadAllHppRowsForExport() async {
    final accountId = _selectedAccountId;
    if (accountId == null || accountId.isEmpty) return const [];

    const exportPageSize = 1000;
    var page = 1;
    var total = 0;
    final rows = <Map<String, dynamic>>[];

    while (true) {
      final payload = await _service.hppList(
        accountId: accountId,
        search: _hppCariController.text,
        missingOnly: _hppMissingOnly,
        page: page,
        pageSize: exportPageSize,
      );
      final rawRows = payload['rows'];
      final pageRows = <Map<String, dynamic>>[];
      if (rawRows is List) {
        for (final item in rawRows) {
          if (item is Map) pageRows.add(Map<String, dynamic>.from(item));
        }
      }
      rows.addAll(pageRows);
      total = int.tryParse('${payload['total'] ?? rows.length}') ?? rows.length;
      if (pageRows.isEmpty || rows.length >= total) break;
      page += 1;
      if (page > 50) break; // Pengaman agar export tidak berjalan tanpa batas.
    }
    return rows;
  }

  Future<void> _exportHppExcel() async {
    if (!_canManageHppMapping) return;
    if (_isHppSaving) return;
    setState(() => _isHppSaving = true);
    try {
      final exportRows = await _loadAllHppRowsForExport();
      final excel = Excel.createExcel();
      const sheetName = 'hpp_mapping';
      final sheet = excel[sheetName];
      if (excel.tables.containsKey('Sheet1')) {
        excel.delete('Sheet1');
      }
      excel.setDefaultSheet(sheetName);

      sheet.appendRow([
        'marketplace_account_id',
        'marketplace',
        'marketplace_product_id',
        'marketplace_sku_id',
        'marketplace_seller_sku',
        'product_name',
        'variant_name',
        'local_product_id',
        'local_sku',
        'local_product_name',
        'hpp',
        'target_margin_percent',
      ].map(TextCellValue.new).toList());

      for (final row in exportRows) {
        final hpp =
            _rowDouble(row, const ['hpp', 'hpp_amount', 'hpp_per_item']);
        sheet.appendRow([
          _rowText(row, const ['marketplace_account_id']),
          _rowText(row, const ['marketplace'],
              fallback: _selectedAccount?.marketplace ?? 'tiktok_shop'),
          _rowText(row, const ['marketplace_product_id']),
          _rowText(row, const ['marketplace_sku_id']),
          _rowText(row, const ['marketplace_seller_sku', 'seller_sku']),
          _rowText(row, const ['marketplace_product_name', 'product_name']),
          _rowText(row,
              const ['marketplace_variant_name', 'variant_name', 'sku_name']),
          _rowText(row, const ['local_product_id', 'product_id']),
          _rowText(row, const ['local_sku']),
          _rowText(row, const ['local_product_name']),
          hpp.toStringAsFixed(0),
          _rowDouble(row, const ['target_margin_percent', 'target_margin'])
              .toStringAsFixed(0),
        ].map((value) {
          final s = value?.toString() ?? '';
          return s.trim().isEmpty ? null : TextCellValue(s);
        }).toList());
      }
      final bytes = excel.encode();
      if (bytes == null) return;
      final filename =
          'hpp_mapping_${DateTime.now().millisecondsSinceEpoch}.xlsx';
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                'Export HPP ${exportRows.length} varian. Sheet aktif: hpp_mapping.')));
      }
      await Share.shareXFiles(
        [
          XFile.fromData(
            Uint8List.fromList(bytes),
            name: filename,
            mimeType:
                'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
          ),
        ],
        text: 'Template bulk update HPP marketplace',
      );
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
    } finally {
      if (mounted) setState(() => _isHppSaving = false);
    }
  }

  Future<void> _importHppExcel() async {
    if (!_canManageHppMapping) return;
    final selectedAccountId = _selectedAccountId?.trim();
    final picked = await fs.openFile(
      acceptedTypeGroups: const <fs.XTypeGroup>[
        fs.XTypeGroup(
          label: 'Excel',
          extensions: <String>['xlsx'],
        ),
      ],
    );
    if (picked == null) return;

    setState(() => _isHppSaving = true);
    try {
      final excel = Excel.decodeBytes(await picked.readAsBytes());
      final sheet = _findHppMappingSheet(excel);
      if (sheet == null || sheet.rows.length < 2) {
        throw Exception(
            'Sheet hpp_mapping tidak ditemukan atau file Excel kosong. Export ulang template dari aplikasi.');
      }

      final header = sheet.rows.first
          .map((cell) => cell?.value.toString().trim() ?? '')
          .toList();
      int col(String name) =>
          header.indexWhere((h) => h.toLowerCase() == name.toLowerCase());
      String cellFrom(List<dynamic> r, List<String> names) {
        for (final name in names) {
          final idx = col(name);
          if (idx >= 0 && idx < r.length) {
            final value = r[idx]?.value.toString().trim() ?? '';
            if (value.isNotEmpty && value.toLowerCase() != 'null') return value;
          }
        }
        return '';
      }

      final rows = <Map<String, dynamic>>[];
      for (final r in sheet.rows.skip(1)) {
        final marketplaceSkuId =
            cellFrom(r, const ['marketplace_sku_id', 'sku_id']);
        final sellerSku =
            cellFrom(r, const ['marketplace_seller_sku', 'seller_sku']);
        final marketplaceProductId = cellFrom(
            r, const ['marketplace_product_id', 'product_id_marketplace']);
        final productName =
            cellFrom(r, const ['product_name', 'marketplace_product_name']);
        final variantName =
            cellFrom(r, const ['variant_name', 'marketplace_variant_name']);
        final hppRaw = cellFrom(r, const ['hpp', 'hpp_amount', 'hpp_per_item']);
        if (marketplaceProductId.isEmpty ||
            marketplaceSkuId.isEmpty ||
            hppRaw.isEmpty) {
          continue;
        }

        final rowAccountId =
            cellFrom(r, const ['marketplace_account_id', 'account_id']);
        final effectiveAccountId =
            rowAccountId.isNotEmpty ? rowAccountId : (selectedAccountId ?? '');
        if (effectiveAccountId.isEmpty) continue;

        final localSku = cellFrom(r, const ['local_sku']);
        final localProductIdFromFile =
            cellFrom(r, const ['local_product_id', 'product_id']);
        final product = localProductIdFromFile.isNotEmpty
            ? _productById(localProductIdFromFile)
            : _productBySku(localSku);
        final hpp = _parseNumberText(hppRaw);
        final targetMargin = _parseNumberText(
            cellFrom(r, const ['target_margin_percent', 'target_margin']));

        rows.add({
          'marketplace_account_id': effectiveAccountId,
          'marketplace': cellFrom(r, const ['marketplace']).isEmpty
              ? (_selectedAccount?.marketplace ?? 'tiktok_shop')
              : cellFrom(r, const ['marketplace']),
          'marketplace_product_id': marketplaceProductId,
          'marketplace_sku_id': marketplaceSkuId,
          'marketplace_seller_sku': sellerSku,
          'marketplace_product_name': productName,
          'marketplace_variant_name': variantName,
          'local_product_id': product?.productId ?? localProductIdFromFile,
          'local_sku': localSku,
          'local_product_name':
              product?.namaBarang ?? cellFrom(r, const ['local_product_name']),
          'hpp': hpp,
          'hpp_amount': hpp,
          'hpp_per_item': hpp,
          'target_margin_percent': targetMargin,
        });
      }

      if (rows.isEmpty) {
        throw Exception(
            'Tidak ada baris HPP valid yang bisa diimport. Pastikan sheet hpp_mapping berisi marketplace_product_id, marketplace_sku_id, dan kolom hpp.');
      }

      final result = await _service.hppUpsertBulk(rows);
      final ok = result['ok'] == true;
      if (!ok)
        throw Exception(result['message']?.toString() ?? 'Import HPP gagal.');
      await _loadHpp(resetPage: true);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(_hppUpsertMessage(result, rows.length))));
      }
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
    } finally {
      if (mounted) setState(() => _isHppSaving = false);
    }
  }

  dynamic _findHppMappingSheet(Excel excel) {
    if (excel.tables.containsKey('hpp_mapping'))
      return excel.tables['hpp_mapping'];
    if (excel.tables.containsKey('HPP_MAPPING'))
      return excel.tables['HPP_MAPPING'];
    for (final sheet in excel.tables.values) {
      if (sheet.rows.isEmpty) continue;
      final header = sheet.rows.first
          .map((cell) => (cell?.value.toString().trim().toLowerCase() ?? ''))
          .toList();
      final hasSku = header.contains('marketplace_sku_id') ||
          header.contains('marketplace_seller_sku') ||
          header.contains('seller_sku');
      final hasHpp = header.contains('hpp') ||
          header.contains('hpp_amount') ||
          header.contains('hpp_per_item');
      if (hasSku && hasHpp) return sheet;
    }
    return null;
  }

  Future<void> _exportSkuMappingExcel() async {
    final accountId = _selectedAccountId;
    if (accountId == null || accountId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pilih marketplace account dulu.')),
      );
      return;
    }
    if (_isSkuExcelBusy) return;
    setState(() => _isSkuExcelBusy = true);
    try {
      final payload = await _service.skuMappingExportSnapshot(
        tenantId: widget.currentUser.tenantId,
        marketplaceAccountId: accountId,
      );
      final variants = (payload['variants'] is List)
          ? List<Map<String, dynamic>>.from((payload['variants'] as List)
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e)))
          : <Map<String, dynamic>>[];
      final localProducts = (payload['local_products'] is List)
          ? List<Map<String, dynamic>>.from((payload['local_products'] as List)
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e)))
          : <Map<String, dynamic>>[];

      final excel = Excel.createExcel();
      const mapSheetName = 'sku_mapping';
      const localSheetName = 'local_products';
      final mapSheet = excel[mapSheetName];
      final localSheet = excel[localSheetName];
      if (excel.tables.containsKey('Sheet1')) excel.delete('Sheet1');
      excel.setDefaultSheet(mapSheetName);

      mapSheet.appendRow([
        'tenant_id',
        'marketplace_account_id',
        'marketplace',
        'marketplace_variant_snapshot_id',
        'marketplace_product_id',
        'marketplace_sku_id',
        'marketplace_sku_code',
        'marketplace_seller_sku',
        'marketplace_product_name',
        'marketplace_variant_name',
        'local_product_id',
        'local_sku',
        'local_product_name',
        'sync_enabled',
      ].map(TextCellValue.new).toList());

      for (final row in variants) {
        mapSheet.appendRow([
          row['tenant_id'],
          row['marketplace_account_id'],
          row['marketplace'],
          row['marketplace_variant_snapshot_id'],
          row['marketplace_product_id'],
          row['marketplace_sku_id'],
          row['marketplace_sku_code'],
          row['marketplace_seller_sku'],
          row['marketplace_product_name'],
          row['marketplace_variant_name'],
          row['local_product_id'],
          row['local_sku'],
          row['local_product_name'],
          row['sync_enabled'] == true ? 'TRUE' : 'TRUE',
        ].map((value) {
          final s = value?.toString() ?? '';
          return s.trim().isEmpty ? null : TextCellValue(s);
        }).toList());
      }

      localSheet.appendRow([
        'local_product_id',
        'local_sku',
        'barcode',
        'local_product_name',
        'kategori',
        'hpp_default',
        'stock_saat_ini',
      ].map(TextCellValue.new).toList());
      for (final row in localProducts) {
        localSheet.appendRow([
          row['product_id'],
          row['kode_sku'],
          row['kode_barcode'],
          row['nama_barang'],
          row['kategori'],
          row['harga_hpp_default'],
          row['stock_saat_ini'],
        ].map((value) {
          final s = value?.toString() ?? '';
          return s.trim().isEmpty ? null : TextCellValue(s);
        }).toList());
      }

      final bytes = excel.encode();
      if (bytes == null) return;
      final filename =
          'sku_mapping_${DateTime.now().millisecondsSinceEpoch}.xlsx';
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                'Export SKU mapping ${variants.length} varian dan ${localProducts.length} SKU lokal.')));
      }
      await Share.shareXFiles(
        [
          XFile.fromData(
            Uint8List.fromList(bytes),
            name: filename,
            mimeType:
                'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
          ),
        ],
        text: 'Template mapping SKU marketplace',
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted) setState(() => _isSkuExcelBusy = false);
    }
  }

  Future<void> _importSkuMappingExcel() async {
    final selectedAccountId = _selectedAccountId?.trim();
    final picked = await fs.openFile(
      acceptedTypeGroups: const <fs.XTypeGroup>[
        fs.XTypeGroup(label: 'Excel', extensions: <String>['xlsx']),
      ],
    );
    if (picked == null) return;

    setState(() => _isSkuExcelBusy = true);
    try {
      final excel = Excel.decodeBytes(await picked.readAsBytes());
      final sheet = excel.tables['sku_mapping'] ?? excel.tables['SKU_MAPPING'];
      if (sheet == null || sheet.rows.length < 2) {
        throw Exception(
            'Sheet sku_mapping tidak ditemukan atau file Excel kosong. Export template dari aplikasi dulu.');
      }
      final header = sheet.rows.first
          .map((cell) => cell?.value.toString().trim() ?? '')
          .toList();
      int col(String name) =>
          header.indexWhere((h) => h.toLowerCase() == name.toLowerCase());
      String cellFrom(List<dynamic> r, List<String> names) {
        for (final name in names) {
          final idx = col(name);
          if (idx >= 0 && idx < r.length) {
            final value = r[idx]?.value.toString().trim() ?? '';
            if (value.isNotEmpty && value.toLowerCase() != 'null') return value;
          }
        }
        return '';
      }

      final rows = <Map<String, dynamic>>[];
      for (final r in sheet.rows.skip(1)) {
        final marketplaceProductId =
            cellFrom(r, const ['marketplace_product_id']);
        final marketplaceSkuId = cellFrom(r, const ['marketplace_sku_id']);
        final sellerSku =
            cellFrom(r, const ['marketplace_seller_sku', 'seller_sku']);
        final snapshotId =
            cellFrom(r, const ['marketplace_variant_snapshot_id']);
        final localProductId =
            cellFrom(r, const ['local_product_id', 'product_id']);
        final localSku = cellFrom(r, const ['local_sku']);
        if ((marketplaceProductId.isEmpty || marketplaceSkuId.isEmpty) &&
            snapshotId.isEmpty) {
          continue;
        }
        if (localProductId.isEmpty && localSku.isEmpty) continue;
        final rowAccountId =
            cellFrom(r, const ['marketplace_account_id', 'account_id']);
        final effectiveAccountId =
            rowAccountId.isNotEmpty ? rowAccountId : (selectedAccountId ?? '');
        if (effectiveAccountId.isEmpty) continue;
        rows.add({
          'tenant_id': cellFrom(r, const ['tenant_id']).isEmpty
              ? widget.currentUser.tenantId
              : cellFrom(r, const ['tenant_id']),
          'marketplace_account_id': effectiveAccountId,
          'marketplace': cellFrom(r, const ['marketplace']).isEmpty
              ? (_selectedAccount?.marketplace ?? 'tiktok_shop')
              : cellFrom(r, const ['marketplace']),
          'marketplace_variant_snapshot_id': snapshotId,
          'marketplace_product_id': marketplaceProductId,
          'marketplace_sku_id': marketplaceSkuId,
          'marketplace_sku':
              cellFrom(r, const ['marketplace_sku', 'marketplace_sku_code']),
          'marketplace_seller_sku': sellerSku,
          'marketplace_product_name':
              cellFrom(r, const ['marketplace_product_name', 'product_name']),
          'marketplace_variant_name':
              cellFrom(r, const ['marketplace_variant_name', 'variant_name']),
          'local_product_id': localProductId,
          'local_sku': localSku,
          'local_product_name': cellFrom(r, const ['local_product_name']),
        });
      }
      if (rows.isEmpty) {
        throw Exception(
            'Tidak ada baris SKU mapping valid. Isi local_product_id atau local_sku pada sheet sku_mapping.');
      }
      final result = await _service.importSkuMappingBulk(
        rows,
        syncEnabled: _formSyncEnabled,
      );
      if (result['ok'] != true) {
        throw Exception(
            result['message']?.toString() ?? 'Import SKU mapping gagal.');
      }
      await _applySkuMapsToOrderItemsForSelectedAccount();
      await _refreshAll();
      if (mounted) {
        final upserted = _resultInt(result, 'upserted');
        final skipped = _resultInt(result, 'skipped_invalid');
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                'Import SKU mapping selesai. Tersimpan: $upserted · Dilewati: $skipped')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted) setState(() => _isSkuExcelBusy = false);
    }
  }

  Future<void> _syncHppFromSkuMaps({bool overwrite = false}) async {
    if (!_canManageHppMapping) return;
    if (_isSyncingHpp) return;
    setState(() => _isSyncingHpp = true);
    try {
      final result = await _service.syncHppFromSkuMaps(
        tenantId: widget.currentUser.tenantId,
        marketplaceAccountId: _selectedAccountId,
        overwrite: overwrite,
      );
      await _applySkuMapsToOrderItemsForSelectedAccount();
      await _loadHpp(resetPage: true);
      if (mounted) {
        final upserted = _resultInt(result, 'upserted');
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                'Sync HPP dari SKU mapping selesai. Tersimpan: $upserted')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted) setState(() => _isSyncingHpp = false);
    }
  }

  Future<Map<String, dynamic>?> _applySkuMapsToOrderItemsForSelectedAccount({
    int daysBack = 90,
  }) async {
    final accountId = _selectedAccountId?.trim();
    if (accountId == null || accountId.isEmpty || accountId == 'all') {
      return null;
    }

    final result = await _service.applySkuMapsToOrderItems(
      tenantId: widget.currentUser.tenantId,
      marketplaceAccountId: accountId,
      daysBack: daysBack,
    );
    if (result['ok'] == false) {
      throw Exception(result['message']?.toString() ??
          'Apply SKU mapping ke order item gagal.');
    }
    return result;
  }

  Future<void> _recalculateFinanceAfterHpp() async {
    if (!_canManageHppMapping) return;
    if (_isRecalculatingFinance) return;
    setState(() => _isRecalculatingFinance = true);
    try {
      final result = await _service.recalculateFinanceAfterHppMapping(
        tenantId: widget.currentUser.tenantId,
        marketplaceAccountId: _selectedAccountId,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(result['ok'] == true
                ? 'Finance refresh dikirim. Buka ulang halaman Finance untuk melihat hasil terbaru.'
                : (result['message']?.toString() ??
                    'Finance refresh selesai.'))));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted) setState(() => _isRecalculatingFinance = false);
    }
  }

  Future<void> _pullMarketplaceProducts() async {
    final accountId = _selectedAccountId;
    if (accountId == null || accountId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pilih marketplace account dulu.')),
      );
      return;
    }

    setState(() => _isPulling = true);

    try {
      final result = await _service.pullMarketplaceProducts(
        tenantId: widget.currentUser.tenantId,
        marketplaceAccountId: accountId,
        limit: 100,
      );

      await _refreshAll();

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(
                'Produk berhasil diambil. ${result.summary} Jika daftar masih kosong, cek toko yang dipilih dan jalankan SQL V35.')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.toString())),
      );
    } finally {
      if (mounted) setState(() => _isPulling = false);
    }
  }

  Future<void> _syncHppFromSkuMappings({bool overwrite = false}) async {
    if (!_canManageHppMapping) return;
    final accountId = _selectedAccountId;
    if (accountId == null || accountId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pilih marketplace account dulu.')),
      );
      return;
    }

    setState(() => _isSyncingHppFromSkuMap = true);
    try {
      final result = await _service.syncHppFromSkuMaps(
        tenantId: widget.currentUser.tenantId,
        marketplaceAccountId: accountId,
        overwrite: overwrite,
      );
      await _applySkuMapsToOrderItemsForSelectedAccount();
      await _refreshAll();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result['message']?.toString() ??
              '${_resultInt(result, 'upserted')} HPP mapping disinkronkan.'),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.toString())));
    } finally {
      if (mounted) setState(() => _isSyncingHppFromSkuMap = false);
    }
  }

  Future<void> _refreshFinanceAfterHppMapping() async {
    final accountId = _selectedAccountId;
    if (accountId == null || accountId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pilih marketplace account dulu.')),
      );
      return;
    }

    setState(() => _isRefreshingFinanceAfterHpp = true);
    try {
      final now = DateTime.now();
      final result = await _service.refreshFinanceAfterHppMapping(
        tenantId: widget.currentUser.tenantId,
        marketplaceAccountId: accountId,
        startDate: DateTime(now.year, now.month, 1),
        endDate: DateTime(now.year, now.month, now.day),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result['message']?.toString() ??
              'Finance siap dibaca ulang setelah sinkron HPP.'),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.toString())));
    } finally {
      if (mounted) setState(() => _isRefreshingFinanceAfterHpp = false);
    }
  }

  Future<void> _clearCache() async {
    final accountId = _selectedAccountId;
    if (accountId == null || accountId.isEmpty) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('Clear product cache only?'),
          content: Text(
            'Ini hanya menghapus daftar produk yang sudah diambil. Mapping yang sudah dibuat tidak ikut dihapus.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text('Batal'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text('Bersihkan'),
            ),
          ],
        );
      },
    );

    if (confirmed != true) return;

    setState(() => _isPulling = true);
    try {
      final count = await _service.clearMarketplaceProductCache(
        tenantId: widget.currentUser.tenantId,
        marketplaceAccountId: accountId,
      );
      await _refreshAll();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(
                'Product cache dibersihkan. $count varian cache dihapus.')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.toString())),
      );
    } finally {
      if (mounted) setState(() => _isPulling = false);
    }
  }

  Future<void> _clearSkuHppMappings() async {
    final accountId = _selectedAccountId;
    if (accountId == null || accountId.isEmpty) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('Clear SKU + HPP mapping?'),
          content: Text(
            'Ini menghapus mapping SKU dan HPP untuk account marketplace yang dipilih saja. Order, finance, payout, dan produk lokal tidak disentuh.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text('Batal'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text('Clear Mapping'),
            ),
          ],
        );
      },
    );

    if (confirmed != true) return;

    setState(() => _isPulling = true);
    try {
      final result = await _service.clearSkuHppMapping(
        tenantId: widget.currentUser.tenantId,
        marketplaceAccountId: accountId,
        marketplace: _selectedAccount?.marketplace,
      );
      await _refreshAll();
      if (!mounted) return;
      final skuCleared = _resultInt(result, 'sku_cleared');
      final hppCleared = _resultInt(result, 'hpp_cleared');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result['message']?.toString() ??
              'SKU mapping dibersihkan: $skuCleared | HPP mapping dibersihkan: $hppCleared.'),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.toString())),
      );
    } finally {
      if (mounted) setState(() => _isPulling = false);
    }
  }

  Future<void> _searchProducts() async {
    setState(() => _isSearchingProduct = true);

    try {
      final products = await _service.listLocalProducts(
        tenantId: widget.currentUser.tenantId,
        search: _productCariController.text,
      );

      if (!mounted) return;
      setState(() {
        _products = products;
        if (_selectedProductId != null &&
            !_products.any((item) => item.productId == _selectedProductId)) {
          _selectedProductId = null;
        }
      });
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.toString())),
      );
    } finally {
      if (mounted) setState(() => _isSearchingProduct = false);
    }
  }

  MarketplaceAccountPublic? get _selectedAccount {
    final id = _selectedAccountId;
    if (id == null) return null;
    for (final account in _accounts) {
      if (account.marketplaceAccountId == id) return account;
    }
    return null;
  }

  List<MarketplaceAccountPublic> get _filteredAccounts {
    if (_selectedMarketplace == 'all') return _accounts;
    return _accounts
        .where((account) =>
            MarketplaceProviders.normalize(account.marketplace) ==
            _selectedMarketplace)
        .toList(growable: false);
  }

  MarketplaceVariantSnapshot? get _selectedVariant {
    final id = _selectedVariantId;
    if (id == null) return null;
    for (final variant in _variants) {
      if (variant.marketplaceVariantSnapshotId == id) return variant;
    }
    return null;
  }

  Product? get _selectedProduct {
    final id = _selectedProductId;
    if (id == null) return null;
    for (final product in _products) {
      if (product.productId == id) return product;
    }
    return null;
  }

  Map<String, Product> get _localProductById => {
        for (final product in _products) product.productId: product,
      };

  List<_MarketplaceProductOption> get _marketplaceProductOptions {
    final grouped = <String, _MarketplaceProductOption>{};

    for (final variant in _variants) {
      final productId = variant.marketplaceProductId.trim();
      if (productId.isEmpty) continue;

      final existing = grouped[productId];
      if (existing == null) {
        grouped[productId] = _MarketplaceProductOption(
          productId: productId,
          productName: variant.marketplaceProductName,
          variantCount: 1,
        );
      } else {
        grouped[productId] =
            existing.copyWith(variantCount: existing.variantCount + 1);
      }
    }

    final result = grouped.values.toList();
    result.sort((a, b) =>
        a.productName.toLowerCase().compareTo(b.productName.toLowerCase()));
    return result;
  }

  List<MarketplaceVariantSnapshot> get _visibleBulkVariants {
    final productId = _selectedMarketplaceProductId;
    if (productId == null || productId.isEmpty) return const [];

    final result = _variants
        .where((variant) => variant.marketplaceProductId == productId)
        .toList();

    result.sort((a, b) {
      final left = a.displayVariant.toLowerCase();
      final right = b.displayVariant.toLowerCase();
      return left.compareTo(right);
    });

    return result;
  }

  int get _bulkReadyCount => _visibleBulkVariants.where(
        (variant) {
          final productId = _bulkLocalProductByVariantId[
              variant.marketplaceVariantSnapshotId];
          return productId != null && productId.trim().isNotEmpty;
        },
      ).length;

  Future<void> _saveMapping() async {
    final variant = _selectedVariant;
    final product = _selectedProduct;

    if (variant == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pilih varian marketplace dulu.')),
      );
      return;
    }

    if (product == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pilih produk lokal dulu.')),
      );
      return;
    }

    setState(() => _isSaving = true);

    try {
      await _service.mapMarketplaceVariantToLocalProduct(
        variant: variant,
        product: product,
        syncEnabled: _formSyncEnabled,
      );
      await _applySkuMapsToOrderItemsForSelectedAccount();

      if (!mounted) return;
      setState(() {
        _selectedVariantId = null;
        _selectedProductId = null;
        _formSyncEnabled = true;
      });
      await _refreshAll();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text(
                'Varian marketplace berhasil dimapping ke varian/SKU lokal.')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.toString())),
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _saveBulkMappings() async {
    final variants = _visibleBulkVariants;
    if (variants.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pilih produk marketplace dulu.')),
      );
      return;
    }

    final productById = _localProductById;
    final pairs = <MapEntry<MarketplaceVariantSnapshot, Product>>[];

    for (final variant in variants) {
      final localProductId =
          _bulkLocalProductByVariantId[variant.marketplaceVariantSnapshotId];
      if (localProductId == null || localProductId.trim().isEmpty) continue;

      final product = productById[localProductId];
      if (product != null) {
        pairs.add(MapEntry(variant, product));
      }
    }

    if (pairs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text(
                'Isi minimal satu pasangan varian marketplace ke produk lokal.')),
      );
      return;
    }

    setState(() => _isSaving = true);

    var saved = 0;
    try {
      for (final pair in pairs) {
        await _service.mapMarketplaceVariantToLocalProduct(
          variant: pair.key,
          product: pair.value,
          syncEnabled: _formSyncEnabled,
        );
        saved += 1;
      }

      await _applySkuMapsToOrderItemsForSelectedAccount();
      await _refreshAll();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$saved mapping varian berhasil disimpan.')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Gagal simpan mapping ke-$saved: $error')),
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _toggleSync(MarketplaceSkuMap item) async {
    try {
      await _service.updateSkuMapSync(
        marketplaceSkuMapId: item.marketplaceSkuMapId,
        syncEnabled: !item.syncEnabled,
      );
      await _refreshAll();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  Future<void> _deleteMapping(MarketplaceSkuMap item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('Hapus mapping?'),
          content: Text(
              'Mapping ${item.marketplaceSellerSku} ke ${item.localSku} akan dihapus. Varian/SKU lokal tetap aman.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text('Batal')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text('Hapus')),
          ],
        );
      },
    );

    if (confirmed != true) return;

    try {
      await _service.deleteSkuMap(
        tenantId: widget.currentUser.tenantId,
        marketplaceSkuMapId: item.marketplaceSkuMapId,
      );
      await _refreshAll();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  String get _tenantShortLabel {
    final value = widget.currentUser.tenantId.trim();
    if (value.isEmpty) return '-';
    if (value.length <= 8) return value;
    return '${value.substring(0, 8)}…';
  }

  int get _mappedVariantCount =>
      _variants.where((item) => item.isMapped).length;
  int get _unmappedVariantCount =>
      _variants.where((item) => !item.isMapped).length;
  int get _syncEnabledCount => _maps.where((item) => item.syncEnabled).length;

  Widget _accountAndPullCard() {
    if (_accounts.isEmpty) {
      return const EmptyState(
        title: 'Marketplace account belum ada',
        subtitle:
            'Hubungkan TikTok/Shopee dari Akun Marketplace, lalu ambil produk.',
        icon: Icons.storefront_outlined,
      );
    }
    final accounts = _filteredAccounts;
    final selectedAccountValue = accounts.any(
            (account) => account.marketplaceAccountId == _selectedAccountId)
        ? _selectedAccountId
        : null;

    return NiceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionTitle(title: '1. Ambil Produk Aktif'),
          SizedBox(height: 8),
          Text(
            'Ambil produk dan varian toko, lalu hubungkan ke SKU lokal.',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          SizedBox(height: 14),
          DropdownButtonFormField<String>(
            isExpanded: true,
            value: _selectedMarketplace,
            decoration: const InputDecoration(
              labelText: 'Marketplace',
              border: OutlineInputBorder(),
            ),
            items: [
              const DropdownMenuItem<String>(
                value: 'all',
                child: Text('Semua marketplace'),
              ),
              ...MarketplaceProviders.active.map(
                (provider) => DropdownMenuItem<String>(
                  value: provider.id,
                  child: Text(provider.label),
                ),
              ),
            ],
            onChanged: _isPulling || _isSaving
                ? null
                : (value) async {
                    if (value == null) return;
                    final scopedAccounts = value == 'all'
                        ? _accounts
                        : _accounts
                            .where((account) =>
                                MarketplaceProviders.normalize(
                                    account.marketplace) ==
                                value)
                            .toList(growable: false);
                    setState(() {
                      _selectedMarketplace = value;
                      _selectedAccountId = scopedAccounts.isEmpty
                          ? null
                          : scopedAccounts.first.marketplaceAccountId;
                      _selectedVariantId = null;
                      _selectedMarketplaceProductId = null;
                      _bulkLocalProductByVariantId.clear();
                    });
                    await _refreshAll();
                  },
          ),
          SizedBox(height: 12),
          DropdownButtonFormField<String>(
            isExpanded: true,
            value: selectedAccountValue,
            hint: Text('Account belum ada untuk marketplace ini'),
            decoration: const InputDecoration(
              labelText: 'Marketplace account',
              border: OutlineInputBorder(),
            ),
            selectedItemBuilder: (context) {
              return accounts.map((account) {
                return Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '${account.safeStoreName} · ${account.marketplaceLabel} · ${account.shopRegion}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                );
              }).toList();
            },
            items: accounts
                .map(
                  (account) => DropdownMenuItem(
                    value: account.marketplaceAccountId,
                    child: Text(
                      '${account.safeStoreName} · ${account.marketplaceLabel} · ${account.shopRegion}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                )
                .toList(),
            onChanged: _isPulling || _isSaving
                ? null
                : (value) async {
                    setState(() {
                      _selectedAccountId = value;
                      _selectedVariantId = null;
                      _selectedMarketplaceProductId = null;
                      _bulkLocalProductByVariantId.clear();
                    });
                    await _refreshAll();
                  },
          ),
          SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              FilledButton.icon(
                onPressed: _isPulling ? null : _pullMarketplaceProducts,
                icon: _isPulling
                    ? SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : Icon(Icons.cloud_download_outlined),
                label:
                    Text(_isPulling ? 'Mengambil...' : 'Ambil Produk & Varian'),
              ),
              OutlinedButton.icon(
                onPressed: _isPulling ? null : _clearCache,
                icon: Icon(Icons.cleaning_services_outlined),
                label: Text('Clear Cache'),
              ),
              OutlinedButton.icon(
                onPressed: _isPulling ? null : _clearSkuHppMappings,
                icon: Icon(Icons.link_off_rounded),
                label: Text('Clear SKU + HPP Mapping'),
              ),
              OutlinedButton.icon(
                onPressed: _refreshAll,
                icon: Icon(Icons.refresh),
                label: Text('Refresh'),
              ),
              OutlinedButton.icon(
                onPressed: _isSkuExcelBusy ? null : _exportSkuMappingExcel,
                icon: _isSkuExcelBusy
                    ? SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : Icon(Icons.file_download_outlined),
                label: Text('Export SKU Mapping'),
              ),
              OutlinedButton.icon(
                onPressed: _isSkuExcelBusy ? null : _importSkuMappingExcel,
                icon: Icon(Icons.file_upload_outlined),
                label: Text('Import SKU Mapping'),
              ),
              OutlinedButton.icon(
                onPressed: _isSyncingHpp ? null : () => _syncHppFromSkuMaps(),
                icon: _isSyncingHpp
                    ? SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : Icon(Icons.price_check_outlined),
                label: Text('Sync HPP dari Mapping'),
              ),
              OutlinedButton.icon(
                onPressed: _isRecalculatingFinance
                    ? null
                    : _recalculateFinanceAfterHpp,
                icon: Icon(Icons.calculate_outlined),
                label: Text('Refresh Finance'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  _MarketplaceProductOption? _selectedMarketplaceProductOption() {
    final selectedId = _selectedMarketplaceProductId;
    if (selectedId == null || selectedId.trim().isEmpty) return null;
    for (final option in _marketplaceProductOptions) {
      if (option.productId == selectedId) return option;
    }
    return null;
  }

  Future<void> _pickMarketplaceProduct() async {
    if (_isSaving) return;
    final options = _marketplaceProductOptions;
    if (options.isEmpty) return;

    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => _MarketplaceProductPicker(
        options: options,
        selectedProductId: _selectedMarketplaceProductId,
      ),
    );

    if (!mounted || picked == null) return;

    setState(() {
      _selectedMarketplaceProductId = picked.trim().isEmpty ? null : picked;
      _bulkLocalProductByVariantId.clear();
    });
  }

  Widget _variantFilterCard() {
    final options = _marketplaceProductOptions;
    final variants = _visibleBulkVariants;

    return NiceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionTitle(title: '2. Mapping Varian Sekaligus'),
          SizedBox(height: 8),
          Text(
            'Pilih produk marketplace, lalu pasangkan semua varian marketplace ke varian/SKU lokal dalam satu layar.',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          SizedBox(height: 14),
          SearchBox(
            controller: _variantCariController,
            hint: 'Cari produk / warna / size / sku id marketplace',
            onChanged: (_) {},
          ),
          SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton.icon(
                onPressed: _loadVariants,
                icon: Icon(Icons.search),
                label: Text('Cari Varian'),
              ),
              FilterChip(
                selected: _unmappedOnly,
                onSelected: (value) async {
                  setState(() {
                    _unmappedOnly = value;
                    _selectedMarketplaceProductId = null;
                    _bulkLocalProductByVariantId.clear();
                  });
                  await _loadVariants();
                },
                label: Text('Belum mapped saja'),
              ),
            ],
          ),
          SizedBox(height: 14),
          if (options.isEmpty)
            const EmptyState(
              title: 'Belum ada cache varian',
              subtitle:
                  'Klik Ambil Produk & Varian dulu. Produk yang tidak aktif tidak ditampilkan.',
              icon: Icons.cloud_off_outlined,
            )
          else ...[
            Builder(
              builder: (context) {
                final selectedOption = _selectedMarketplaceProductOption();
                return InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: _isSaving ? null : _pickMarketplaceProduct,
                  child: InputDecorator(
                    decoration: const InputDecoration(
                      labelText: 'Pilih produk marketplace',
                      border: OutlineInputBorder(),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                selectedOption?.productName ??
                                    'Pilih produk marketplace',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                selectedOption == null
                                    ? '${options.length} produk marketplace tersedia'
                                    : '${selectedOption.variantCount} varian | ID Produk: ${selectedOption.productId}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.color,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Icon(Icons.arrow_drop_down_rounded),
                      ],
                    ),
                  ),
                );
              },
            ),
            SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _productCariController,
                    decoration: const InputDecoration(
                      hintText: 'Cari SKU, barcode, atau nama barang',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _searchProducts(),
                  ),
                ),
                SizedBox(width: 10),
                SizedBox(
                  width: 52,
                  height: 52,
                  child: IconButton.filledTonal(
                    onPressed: _isSearchingProduct ? null : _searchProducts,
                    icon: _isSearchingProduct
                        ? SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : Icon(Icons.search),
                  ),
                ),
              ],
            ),
            SizedBox(height: 12),
            SwitchListTile.adaptive(
              value: _formSyncEnabled,
              contentPadding: EdgeInsets.zero,
              title: Text('Aktif untuk stock sync'),
              subtitle: Text(
                  'Berlaku untuk semua mapping yang disimpan dari tabel ini.'),
              onChanged: _isSaving
                  ? null
                  : (value) => setState(() => _formSyncEnabled = value),
            ),
            SizedBox(height: 12),
            _BulkMappingTable(
              variants: variants,
              products: _products,
              selectedProductIds: _bulkLocalProductByVariantId,
              isSaving: _isSaving,
              onChanged: (variantId, productId) {
                setState(() {
                  if (productId == null || productId.isEmpty) {
                    _bulkLocalProductByVariantId.remove(variantId);
                  } else {
                    _bulkLocalProductByVariantId[variantId] = productId;
                  }
                });
              },
            ),
            SizedBox(height: 14),
            FilledButton.icon(
              onPressed:
                  _isSaving || _bulkReadyCount == 0 ? null : _saveBulkMappings,
              icon: _isSaving
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : Icon(Icons.save_outlined),
              label: Text(_isSaving
                  ? 'Menyimpan...'
                  : 'Simpan $_bulkReadyCount Mapping'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _hppMappingCard() {
    if (!_canManageHppMapping) return const SizedBox.shrink();
    if (!_canManageHppMapping) return const SizedBox.shrink();
    final pageMax =
        _hppTotal <= 0 ? 1 : ((_hppTotal + _hppPageSize - 1) ~/ _hppPageSize);
    return NiceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                  child: SectionTitle(
                      title: '3. HPP & Target Margin Marketplace')),
              if (_isHppLoading || _isHppSaving)
                SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2)),
            ],
          ),
          SizedBox(height: 8),
          Text(
              'Atur HPP dan target margin per produk/varian marketplace. Data ini dipakai laporan SKU dan laba rugi.',
              style: TextStyle(fontWeight: FontWeight.w700)),
          SizedBox(height: 12),
          SearchBox(
            controller: _hppCariController,
            hint: 'Cari marketplace SKU / produk lokal / varian',
            onChanged: (_) {},
          ),
          SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton.tonalIcon(
                  onPressed:
                      _isHppLoading ? null : () => _loadHpp(resetPage: true),
                  icon: Icon(Icons.search),
                  label: Text('Cari HPP')),
              FilterChip(
                  selected: _hppMissingOnly,
                  onSelected: (value) {
                    setState(() => _hppMissingOnly = value);
                    _loadHpp(resetPage: true);
                  },
                  label: Text('Belum mapping/HPP saja')),
              OutlinedButton.icon(
                  onPressed: _isHppSaving ? null : _exportHppExcel,
                  icon: Icon(Icons.download_outlined),
                  label: Text('Export Excel')),
              OutlinedButton.icon(
                  onPressed: _isHppSaving ? null : _importHppExcel,
                  icon: Icon(Icons.upload_file_outlined),
                  label: Text('Import Excel')),
            ],
          ),
          SizedBox(height: 12),
          Text('Total $_hppTotal data · halaman $_hppPage/$pageMax',
              style: TextStyle(fontWeight: FontWeight.w800)),
          SizedBox(height: 10),
          if (_hppRows.isEmpty)
            const EmptyState(
                title: 'Belum ada data HPP',
                subtitle:
                    'Ambil produk marketplace dan buka filter HPP. Import Excel juga bisa dipakai untuk bulk update.',
                icon: Icons.price_change_outlined)
          else
            ..._hppRows.map((row) {
              final hpp =
                  _rowDouble(row, const ['hpp_amount', 'hpp_per_item', 'hpp']);
              final margin = _rowDouble(
                  row, const ['target_margin_percent', 'target_margin']);
              final localName = _rowText(
                  row, const ['local_product_name', 'local_name'],
                  fallback: 'Belum mapping produk lokal');
              return Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(18),
                  color: Theme.of(context)
                      .colorScheme
                      .surfaceVariant
                      .withOpacity(0.24),
                  border: Border.all(
                      color: Theme.of(context).dividerColor.withOpacity(0.30)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                            child: Text(
                                _rowText(
                                    row,
                                    const [
                                      'marketplace_product_name',
                                      'product_name'
                                    ],
                                    fallback: '-'),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontWeight: FontWeight.w800))),
                        TextButton.icon(
                            onPressed: () => _editHppRow(row),
                            icon: Icon(Icons.edit_outlined, size: 16),
                            label: Text('Edit')),
                      ],
                    ),
                    SizedBox(height: 4),
                    Text(
                        _rowText(
                            row,
                            const [
                              'marketplace_variant_name',
                              'variant_name',
                              'sku_name'
                            ],
                            fallback: '-'),
                        style: TextStyle(fontWeight: FontWeight.w700)),
                    SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _SmallStatusChip(
                            label: localName,
                            color: localName.startsWith('Belum')
                                ? AppUi.orange
                                : AppUi.green),
                        _SmallStatusChip(
                            label: 'HPP ${AppUi.rupiah(hpp)}',
                            color: hpp <= 0 ? AppUi.orange : AppUi.blue),
                        _SmallStatusChip(
                            label: 'Target ${margin.toStringAsFixed(1)}%',
                            color: margin <= 0 ? AppUi.orange : AppUi.green),
                        if (_rowText(row, const [
                          'marketplace_seller_sku',
                          'seller_sku'
                        ]).isNotEmpty)
                          _SmallStatusChip(
                              label: 'Seller SKU ${_rowText(row, const [
                                    'marketplace_seller_sku',
                                    'seller_sku'
                                  ])}',
                              color: AppUi.blue),
                      ],
                    ),
                  ],
                ),
              );
            }),
          if (_hppTotal > _hppPageSize) ...[
            SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                    child: OutlinedButton.icon(
                        onPressed: _hppPage <= 1 || _isHppLoading
                            ? null
                            : () {
                                setState(() => _hppPage -= 1);
                                _loadHpp();
                              },
                        icon: Icon(Icons.chevron_left),
                        label: Text('Sebelumnya'))),
                SizedBox(width: 12),
                Expanded(
                    child: OutlinedButton.icon(
                        onPressed: _hppPage >= pageMax || _isHppLoading
                            ? null
                            : () {
                                setState(() => _hppPage += 1);
                                _loadHpp();
                              },
                        icon: Icon(Icons.chevron_right),
                        label: Text('Berikutnya'))),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _mappingListCard() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: SectionTitle(title: 'Daftar Mapping')),
            TextButton.icon(
              onPressed: _loadMaps,
              icon: Icon(Icons.refresh),
              label: Text('Refresh'),
            ),
          ],
        ),
        SizedBox(height: 8),
        SearchBox(
          controller: _mapCariController,
          hint: 'Cari mapping lokal / marketplace',
          onChanged: (_) {},
        ),
        SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.tonalIcon(
            onPressed: _loadMaps,
            icon: Icon(Icons.search),
            label: Text('Cari Mapping'),
          ),
        ),
        SizedBox(height: 10),
        if (_maps.isEmpty)
          const EmptyState(
            title: 'Belum ada mapping',
            subtitle:
                'Ambil produk marketplace, pilih varian, lalu hubungkan ke SKU lokal.',
            icon: Icons.account_tree_outlined,
          )
        else
          ..._maps.map(_mapCard),
      ],
    );
  }

  Widget _mapCard(MarketplaceSkuMap item) {
    final accent = item.marketplace == 'shopee'
        ? Theme.of(context).colorScheme.primary
        : Theme.of(context).colorScheme.secondary;
    final hasError =
        item.lastError != null && item.lastError!.trim().isNotEmpty;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: accent.withOpacity(0.24)),
      ),
      child: NiceCard(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: accent.withOpacity(0.14),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Icon(
                    item.marketplace == 'shopee'
                        ? Icons.shopping_bag_outlined
                        : Icons.music_note_rounded,
                    color: accent,
                  ),
                ),
                SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.marketplaceVariationName ??
                            item.marketplaceSellerSku,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontWeight: FontWeight.w800, fontSize: 17),
                      ),
                      SizedBox(height: 4),
                      Text(
                        '${item.accountStoreAlias} · ${item.marketplaceLabel} · ${item.shopRegion}',
                        style: TextStyle(
                          color: Theme.of(context).textTheme.bodySmall?.color,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  onSelected: (value) {
                    if (value == 'toggle_sync') _toggleSync(item);
                    if (value == 'delete') _deleteMapping(item);
                  },
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: 'toggle_sync',
                      child: Text(item.syncEnabled
                          ? 'Matikan Sinkron'
                          : 'Aktifkan Sinkron'),
                    ),
                    const PopupMenuDivider(),
                    const PopupMenuItem(
                        value: 'delete', child: Text('Hapus Mapping')),
                  ],
                ),
              ],
            ),
            SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context)
                    .colorScheme
                    .surfaceVariant
                    .withOpacity(0.40),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Column(
                children: [
                  _MappingLine(
                    label: 'Marketplace',
                    title: item.marketplaceProductName,
                    subtitle:
                        'ID Produk: ${item.marketplaceProductId ?? '-'} · ID Varian: ${item.marketplaceSkuId ?? '-'}',
                  ),
                  Divider(),
                  _MappingLine(
                    label: 'Lokal',
                    title: item.localProductName,
                    subtitle:
                        'SKU: ${item.localSku} · Stock: ${AppUi.money(item.localStock)} · ${item.localProductStatus}',
                  ),
                ],
              ),
            ),
            SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _SmallStatusChip(
                    label: item.syncLabel,
                    color: item.syncEnabled ? AppUi.green : AppUi.orange),
                _SmallStatusChip(
                    label: item.status, color: AppUi.statusColor(item.status)),
                if (item.marketplaceSellerSku.trim().isNotEmpty)
                  _SmallStatusChip(
                      label: 'Seller SKU: ${item.marketplaceSellerSku}',
                      color: AppUi.blue),
              ],
            ),
            if (hasError) ...[
              SizedBox(height: 10),
              Text(item.lastError!,
                  style:
                      TextStyle(color: AppUi.red, fontWeight: FontWeight.w800)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _body() {
    if (_isLoading) return const LoadingState();

    return RefreshIndicator(
      onRefresh: _loadInitial,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 90),
        children: [
          FuturisticHeader(
            icon: Icons.account_tree_outlined,
            title: 'Mapping Varian',
            subtitle:
                'Hubungkan varian TikTok/Shopee ke SKU lokal. Cocok untuk produk dengan warna atau size.',
            stats: [
              StatPill(label: 'Variants', value: _variants.length.toString()),
              StatPill(label: 'Mapped', value: _mappedVariantCount.toString()),
              StatPill(
                  label: 'Belum Mapping',
                  value: _unmappedVariantCount.toString()),
              StatPill(
                  label: 'Sinkron Aktif', value: _syncEnabledCount.toString()),
            ],
          ),
          SizedBox(height: 14),
          if (_errorMessage != null) ...[
            ErrorState(message: _errorMessage!, onRetry: _loadInitial),
            SizedBox(height: 14),
          ],
          _accountAndPullCard(),
          SizedBox(height: 14),
          _variantFilterCard(),
          SizedBox(height: 16),
          _hppMappingCard(),
          SizedBox(height: 16),
          _mappingListCard(),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return WebResponsiveScaffold(
      title: 'Mapping SKU',
      actions: [
        IconButton(onPressed: _loadInitial, icon: Icon(Icons.refresh)),
      ],
      body: _body(),
    );
  }
}

class _MarketplaceProductPicker extends StatefulWidget {
  final List<_MarketplaceProductOption> options;
  final String? selectedProductId;

  const _MarketplaceProductPicker({
    required this.options,
    required this.selectedProductId,
  });

  @override
  State<_MarketplaceProductPicker> createState() =>
      _MarketplaceProductPickerState();
}

class _MarketplaceProductPickerState extends State<_MarketplaceProductPicker> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  List<_MarketplaceProductOption> get _filtered {
    final keyword = _controller.text.trim().toLowerCase();
    if (keyword.isEmpty) return widget.options;

    return widget.options.where((option) {
      final haystack =
          '${option.productName} ${option.productId} ${option.variantCount}'
              .toLowerCase();
      return haystack.contains(keyword);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filtered;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.82,
      minChildSize: 0.45,
      maxChildSize: 0.95,
      builder: (context, scrollController) {
        return SafeArea(
          top: false,
          child: Column(
            children: [
              const SizedBox(height: 10),
              Container(
                width: 42,
                height: 5,
                decoration: BoxDecoration(
                  color: Theme.of(context).dividerColor.withOpacity(0.5),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 18, 18, 8),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Pilih Produk Marketplace',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Tutup',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
                child: TextField(
                  controller: _controller,
                  autofocus: true,
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search_rounded),
                    suffixIcon: _controller.text.trim().isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Clear',
                            onPressed: () {
                              setState(() => _controller.clear());
                            },
                            icon: const Icon(Icons.close_rounded),
                          ),
                    labelText: 'Cari produk / ID produk marketplace',
                    border: const OutlineInputBorder(),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              if (widget.selectedProductId != null &&
                  widget.selectedProductId!.trim().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
                  child: OutlinedButton.icon(
                    onPressed: () => Navigator.pop(context, ''),
                    icon: const Icon(Icons.clear_rounded),
                    label: const Text('Kosongkan pilihan'),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '${filtered.length} dari ${widget.options.length} produk marketplace',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      color: Theme.of(context).textTheme.bodySmall?.color,
                    ),
                  ),
                ),
              ),
              Expanded(
                child: filtered.isEmpty
                    ? const EmptyState(
                        title: 'Produk marketplace tidak ditemukan',
                        subtitle:
                            'Coba keyword lain atau klik Ambil Produk & Varian untuk refresh cache marketplace.',
                        icon: Icons.search_off_rounded,
                      )
                    : ListView.separated(
                        controller: scrollController,
                        padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
                        keyboardDismissBehavior:
                            ScrollViewKeyboardDismissBehavior.onDrag,
                        itemCount: filtered.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final option = filtered[index];
                          final selected =
                              option.productId == widget.selectedProductId;

                          return InkWell(
                            borderRadius: BorderRadius.circular(18),
                            onTap: () =>
                                Navigator.pop(context, option.productId),
                            child: Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: selected
                                    ? AppUi.blue.withOpacity(0.14)
                                    : Theme.of(context)
                                        .colorScheme
                                        .surfaceVariant
                                        .withOpacity(0.28),
                                borderRadius: BorderRadius.circular(18),
                                border: Border.all(
                                  color: selected
                                      ? AppUi.blue.withOpacity(0.70)
                                      : Theme.of(context)
                                          .dividerColor
                                          .withOpacity(0.35),
                                ),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    selected
                                        ? Icons.check_circle_rounded
                                        : Icons.inventory_2_outlined,
                                    color: selected
                                        ? AppUi.blue
                                        : Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.color,
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          option.productName,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w800,
                                          ),
                                        ),
                                        const SizedBox(height: 3),
                                        Text(
                                          '${option.variantCount} varian | ID Produk: ${option.productId}',
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w700,
                                            color: Theme.of(context)
                                                .textTheme
                                                .bodySmall
                                                ?.color,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _MarketplaceProductOption {
  final String productId;
  final String productName;
  final int variantCount;

  const _MarketplaceProductOption({
    required this.productId,
    required this.productName,
    required this.variantCount,
  });

  _MarketplaceProductOption copyWith({int? variantCount}) {
    return _MarketplaceProductOption(
      productId: productId,
      productName: productName,
      variantCount: variantCount ?? this.variantCount,
    );
  }

  String get dropdownLabel => '$productName · $variantCount varian';
}

class _BulkMappingTable extends StatelessWidget {
  final List<MarketplaceVariantSnapshot> variants;
  final List<Product> products;
  final Map<String, String> selectedProductIds;
  final bool isSaving;
  final void Function(String variantId, String? productId) onChanged;

  const _BulkMappingTable({
    required this.variants,
    required this.products,
    required this.selectedProductIds,
    required this.isSaving,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    if (variants.isEmpty) {
      return const EmptyState(
        title: 'Produk marketplace belum dipilih',
        subtitle:
            'Pilih produk marketplace dulu, nanti daftar variannya muncul di sini.',
        icon: Icons.inventory_2_outlined,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            children: const [
              Expanded(
                child: Text(
                  'Varian Marketplace',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Varian Lokal',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ),
        ),
        SizedBox(height: 8),
        ...variants.map(
          (variant) => Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _BulkMappingRow(
              variant: variant,
              products: products,
              selectedProductId:
                  selectedProductIds[variant.marketplaceVariantSnapshotId],
              isSaving: isSaving,
              onChanged: (productId) =>
                  onChanged(variant.marketplaceVariantSnapshotId, productId),
            ),
          ),
        ),
      ],
    );
  }
}

class _BulkMappingRow extends StatelessWidget {
  final MarketplaceVariantSnapshot variant;
  final List<Product> products;
  final String? selectedProductId;
  final bool isSaving;
  final ValueChanged<String?> onChanged;

  const _BulkMappingRow({
    required this.variant,
    required this.products,
    required this.selectedProductId,
    required this.isSaving,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final accent = variant.marketplace == 'shopee'
        ? Theme.of(context).colorScheme.primary
        : Theme.of(context).colorScheme.secondary;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Container(
            constraints: const BoxConstraints(minHeight: 64),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: accent.withOpacity(0.10),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: accent.withOpacity(0.28)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  variant.displayVariant,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
                SizedBox(height: 4),
                Text(
                  'Stock ${variant.stockQuantity} · ${variant.isMapped ? 'mapped' : 'unmapped'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: Theme.of(context).textTheme.bodySmall?.color,
                  ),
                ),
              ],
            ),
          ),
        ),
        SizedBox(width: 10),
        Expanded(
          child: _CariableLocalProductPicker(
            products: products,
            selectedProductId: selectedProductId,
            enabled: !isSaving,
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }
}

class _CariableLocalProductPicker extends StatelessWidget {
  final List<Product> products;
  final String? selectedProductId;
  final bool enabled;
  final ValueChanged<String?> onChanged;

  const _CariableLocalProductPicker({
    required this.products,
    required this.selectedProductId,
    required this.enabled,
    required this.onChanged,
  });

  Product? get _selectedProduct {
    final id = selectedProductId;
    if (id == null || id.trim().isEmpty) return null;
    for (final product in products) {
      if (product.productId == id) return product;
    }
    return null;
  }

  Future<void> _openCari(BuildContext context) async {
    if (!enabled) return;

    final selected = await showModalBottomSheet<String?>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) {
        return _LocalProductCariSheet(
          products: products,
          selectedProductId: selectedProductId,
        );
      },
    );

    if (selected == null) return;
    onChanged(selected.isEmpty ? null : selected);
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selectedProduct;
    final theme = Theme.of(context);

    return Opacity(
      opacity: enabled ? 1 : 0.56,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: enabled ? () => _openCari(context) : null,
        child: InputDecorator(
          isEmpty: selected == null,
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            suffixIcon: Icon(
              enabled ? Icons.search_rounded : Icons.lock_outline_rounded,
              size: 20,
            ),
          ),
          child: selected == null
              ? Text(
                  'Cari / pilih produk lokal',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: theme.textTheme.bodySmall?.color,
                    fontWeight: FontWeight.w800,
                  ),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      selected.kodeSku,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                    SizedBox(height: 2),
                    Text(
                      selected.namaBarang,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: theme.textTheme.bodySmall?.color,
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

class _LocalProductCariSheet extends StatefulWidget {
  final List<Product> products;
  final String? selectedProductId;

  const _LocalProductCariSheet({
    required this.products,
    required this.selectedProductId,
  });

  @override
  State<_LocalProductCariSheet> createState() => _LocalProductCariSheetState();
}

class _LocalProductCariSheetState extends State<_LocalProductCariSheet> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  List<Product> get _filteredProducts {
    final keyword = _controller.text.trim().toLowerCase();
    final result = widget.products.where((product) {
      if (keyword.isEmpty) return true;

      final searchable = [
        product.kodeSku,
        product.kodeBarcode ?? '',
        product.namaBarang,
        product.kategori ?? '',
        product.lokasiRak ?? '',
        product.status,
      ].join(' ').toLowerCase();

      return searchable.contains(keyword);
    }).toList();

    result.sort((a, b) {
      final left = a.kodeSku.toLowerCase();
      final right = b.kodeSku.toLowerCase();
      return left.compareTo(right);
    });

    return result;
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filteredProducts;
    final viewInsets = MediaQuery.of(context).viewInsets;

    return Padding(
      padding: EdgeInsets.only(bottom: viewInsets.bottom),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.82,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(height: 10),
            Center(
              child: Container(
                width: 42,
                height: 4,
                decoration: BoxDecoration(
                  color: Theme.of(context).dividerColor.withOpacity(0.5),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Pilih Produk Lokal',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Tutup',
                    onPressed: () => Navigator.pop(context),
                    icon: Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
              child: TextField(
                controller: _controller,
                autofocus: true,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  prefixIcon: Icon(Icons.search_rounded),
                  suffixIcon: _controller.text.trim().isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Clear',
                          onPressed: () {
                            setState(() {
                              _controller.clear();
                            });
                          },
                          icon: Icon(Icons.close_rounded),
                        ),
                  labelText: 'Cari SKU / barcode / nama barang',
                  border: const OutlineInputBorder(),
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
            if (widget.selectedProductId != null &&
                widget.selectedProductId!.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
                child: OutlinedButton.icon(
                  onPressed: () => Navigator.pop(context, ''),
                  icon: Icon(Icons.clear_rounded),
                  label: Text('Kosongkan pilihan'),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
              child: Text(
                '${filtered.length} dari ${widget.products.length} SKU lokal',
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: Theme.of(context).textTheme.bodySmall?.color,
                ),
              ),
            ),
            Expanded(
              child: filtered.isEmpty
                  ? const EmptyState(
                      title: 'SKU lokal tidak ditemukan',
                      subtitle:
                          'Coba keyword lain, atau pakai kolom Cari varian lokal di halaman mapping untuk mengambil data dari database.',
                      icon: Icons.search_off_rounded,
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      itemCount: filtered.length,
                      separatorBuilder: (_, __) => SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final product = filtered[index];
                        final selected =
                            product.productId == widget.selectedProductId;

                        return InkWell(
                          borderRadius: BorderRadius.circular(18),
                          onTap: () =>
                              Navigator.pop(context, product.productId),
                          child: Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: selected
                                  ? AppUi.blue.withOpacity(0.14)
                                  : Theme.of(context)
                                      .colorScheme
                                      .surfaceVariant
                                      .withOpacity(0.28),
                              borderRadius: BorderRadius.circular(18),
                              border: Border.all(
                                color: selected
                                    ? AppUi.blue.withOpacity(0.70)
                                    : Theme.of(context)
                                        .dividerColor
                                        .withOpacity(0.35),
                              ),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  selected
                                      ? Icons.check_circle_rounded
                                      : Icons.inventory_2_outlined,
                                  color: selected
                                      ? AppUi.blue
                                      : Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.color,
                                ),
                                SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        product.kodeSku,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                            fontWeight: FontWeight.w800),
                                      ),
                                      SizedBox(height: 3),
                                      Text(
                                        product.namaBarang,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                            fontWeight: FontWeight.w700),
                                      ),
                                      SizedBox(height: 3),
                                      Text(
                                        'Barcode: ${product.barcodeValue} · Stock ${AppUi.money(product.stockSaatIni)} · ${product.status}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w700,
                                          color: Theme.of(context)
                                              .textTheme
                                              .bodySmall
                                              ?.color,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _VariantSelectableCard extends StatelessWidget {
  final MarketplaceVariantSnapshot variant;
  final bool selected;
  final VoidCallback? onTap;

  const _VariantSelectableCard({
    required this.variant,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final accent = variant.marketplace == 'shopee'
        ? Theme.of(context).colorScheme.primary
        : Theme.of(context).colorScheme.secondary;
    final parts = variant.displayVariantParts;

    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: selected
              ? accent.withOpacity(0.16)
              : Theme.of(context).cardColor.withOpacity(0.08),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected
                ? accent
                : Theme.of(context).dividerColor.withOpacity(0.45),
            width: selected ? 1.6 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: selected
                      ? accent
                      : Theme.of(context).textTheme.bodySmall?.color,
                ),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    variant.marketplaceProductName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
              ],
            ),
            SizedBox(height: 10),
            if (parts.isEmpty)
              _SmallStatusChip(
                label: variant.displayVariant,
                color: Colors.amber,
              )
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: parts
                    .map(
                      (part) => _SmallStatusChip(
                        label: part,
                        color: accent,
                      ),
                    )
                    .toList(),
              ),
            SizedBox(height: 10),
            Text(
              'ID Produk: ${variant.marketplaceProductId} · ID Varian: ${variant.marketplaceSkuId}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: Theme.of(context).textTheme.bodySmall?.color,
              ),
            ),
            SizedBox(height: 4),
            Text(
              'Stock marketplace: ${variant.stockQuantity} · ${variant.isMapped ? 'mapped' : 'unmapped'}',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
            ),
          ],
        ),
      ),
    );
  }
}

class _VariantPreviewCard extends StatelessWidget {
  final MarketplaceVariantSnapshot variant;

  const _VariantPreviewCard({required this.variant});

  @override
  Widget build(BuildContext context) {
    final accent = variant.marketplace == 'shopee'
        ? Theme.of(context).colorScheme.primary
        : Theme.of(context).colorScheme.secondary;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: accent.withOpacity(0.10),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: accent.withOpacity(0.28)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                  variant.marketplace == 'shopee'
                      ? Icons.shopping_bag_outlined
                      : Icons.music_note_rounded,
                  color: accent),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  variant.marketplaceProductName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ),
          SizedBox(height: 10),
          _MappingLine(
              label: 'Varian',
              title: variant.displayVariant,
              subtitle: 'ID Varian: ${variant.marketplaceSkuId}'),
          Divider(),
          _MappingLine(
              label: 'Seller SKU',
              title: variant.marketplaceSellerSku ?? '-',
              subtitle: 'Fallback key: ${variant.displaySku}'),
          Divider(),
          _MappingLine(
            label: 'Stock',
            title: '${variant.stockQuantity}',
            subtitle:
                'Price: ${variant.priceCurrency ?? '-'} ${AppUi.money(variant.priceAmount)} · ${variant.isMapped ? 'Sudah mapped' : 'Belum mapped'}',
          ),
        ],
      ),
    );
  }
}

class _MappingLine extends StatelessWidget {
  final String label;
  final String title;
  final String subtitle;

  const _MappingLine({
    required this.label,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 94,
          child: Text(
            label.toUpperCase(),
            style: TextStyle(
              color: Theme.of(context).textTheme.bodySmall?.color,
              fontWeight: FontWeight.w800,
              fontSize: 11,
              letterSpacing: 0.4,
            ),
          ),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
              SizedBox(height: 3),
              Text(
                subtitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: Theme.of(context).textTheme.bodySmall?.color),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SmallStatusChip extends StatelessWidget {
  final String label;
  final Color color;

  const _SmallStatusChip({
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withOpacity(0.32)),
      ),
      child: Text(
        label,
        style:
            TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 12),
      ),
    );
  }
}
