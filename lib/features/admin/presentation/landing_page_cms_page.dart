import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../core/ui/app_segmented_tab_bar.dart';
import '../../../core/ui/app_ui.dart';
import '../../../core/ui/web_responsive_layout.dart';

class LandingPageCmsPage extends StatefulWidget {
  const LandingPageCmsPage({super.key});

  @override
  State<LandingPageCmsPage> createState() => _LandingPageCmsPageState();
}

class _LandingPageCmsPageState extends State<LandingPageCmsPage>
    with SingleTickerProviderStateMixin {
  final SupabaseClient _client = Supabase.instance.client;
  late TabController _tabController;

  bool _isLoading = true;
  bool _isSaving = false;

  // Form Controllers - Hero
  final _heroBadgeCtrl = TextEditingController();
  final _heroTitleCtrl = TextEditingController();
  final _heroSubtitleCtrl = TextEditingController();
  final _heroCtaPrimaryTextCtrl = TextEditingController();
  final _heroCtaPrimaryLinkCtrl = TextEditingController();
  final _heroCtaSecondaryTextCtrl = TextEditingController();
  final _heroCtaSecondaryLinkCtrl = TextEditingController();

  // Form Controllers - Contact
  final _companyNameCtrl = TextEditingController();
  final _waNumberCtrl = TextEditingController();
  final _waMessageCtrl = TextEditingController();
  final _supportEmailCtrl = TextEditingController();
  final _addressCtrl = TextEditingController();

  // Form Controllers - SEO
  final _seoTitleCtrl = TextEditingController();
  final _seoDescCtrl = TextEditingController();
  final _seoKeywordsCtrl = TextEditingController();

  // Dynamic Lists
  List<Map<String, dynamic>> _faqList = [];
  List<Map<String, dynamic>> _testiList = [];
  List<Map<String, dynamic>> _featureList = [];
  List<Map<String, dynamic>> _statsList = [];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 5, vsync: this);
    _loadCmsData();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _heroBadgeCtrl.dispose();
    _heroTitleCtrl.dispose();
    _heroSubtitleCtrl.dispose();
    _heroCtaPrimaryTextCtrl.dispose();
    _heroCtaPrimaryLinkCtrl.dispose();
    _heroCtaSecondaryTextCtrl.dispose();
    _heroCtaSecondaryLinkCtrl.dispose();
    _companyNameCtrl.dispose();
    _waNumberCtrl.dispose();
    _waMessageCtrl.dispose();
    _supportEmailCtrl.dispose();
    _addressCtrl.dispose();
    _seoTitleCtrl.dispose();
    _seoDescCtrl.dispose();
    _seoKeywordsCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadCmsData() async {
    setState(() => _isLoading = true);
    try {
      final res = await _client.from('platform_landing_page_cms').select('*');
      for (final row in res) {
        final key = row['section_key']?.toString();
        final content = row['content'] is Map
            ? Map<String, dynamic>.from(row['content'] as Map)
            : <String, dynamic>{};

        if (key == 'hero') {
          _heroBadgeCtrl.text = content['badge']?.toString() ?? '';
          _heroTitleCtrl.text = content['title']?.toString() ?? '';
          _heroSubtitleCtrl.text = content['subtitle']?.toString() ?? '';
          _heroCtaPrimaryTextCtrl.text =
              content['cta_primary_text']?.toString() ?? '';
          _heroCtaPrimaryLinkCtrl.text =
              content['cta_primary_link']?.toString() ?? '';
          _heroCtaSecondaryTextCtrl.text =
              content['cta_secondary_text']?.toString() ?? '';
          _heroCtaSecondaryLinkCtrl.text =
              content['cta_secondary_link']?.toString() ?? '';

          if (content['stats'] is List) {
            _statsList = (content['stats'] as List)
                .map((e) => Map<String, dynamic>.from(e as Map))
                .toList();
          }
        } else if (key == 'contact') {
          _companyNameCtrl.text = content['company_name']?.toString() ?? '';
          _waNumberCtrl.text = content['whatsapp_number']?.toString() ?? '';
          _waMessageCtrl.text = content['whatsapp_message']?.toString() ?? '';
          _supportEmailCtrl.text = content['support_email']?.toString() ?? '';
          _addressCtrl.text = content['address']?.toString() ?? '';
        } else if (key == 'seo') {
          _seoTitleCtrl.text = content['meta_title']?.toString() ?? '';
          _seoDescCtrl.text = content['meta_description']?.toString() ?? '';
          _seoKeywordsCtrl.text = content['meta_keywords']?.toString() ?? '';
        } else if (key == 'faq') {
          if (content['items'] is List) {
            _faqList = (content['items'] as List)
                .map((e) => Map<String, dynamic>.from(e as Map))
                .toList();
          }
        } else if (key == 'testimonials') {
          if (content['items'] is List) {
            _testiList = (content['items'] as List)
                .map((e) => Map<String, dynamic>.from(e as Map))
                .toList();
          }
        } else if (key == 'features') {
          if (content['items'] is List) {
            _featureList = (content['items'] as List)
                .map((e) => Map<String, dynamic>.from(e as Map))
                .toList();
          }
        }
      }
    } catch (e, st) {
      debugPrint('[LOAD_CMS_ERROR] $e\n$st');
      AppUi.showSnack('GAGAL MEMUAT DATA CMS: ${e.toString()}');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _saveSection(String sectionKey, Map<String, dynamic> content) async {
    setState(() => _isSaving = true);
    try {
      final res = await _client.rpc('platform_update_landing_cms', params: {
        'p_section_key': sectionKey,
        'p_content': content,
        'p_is_active': true,
      });

      final ok = res is Map && (res['ok'] as bool? ?? false);
      if (ok) {
        AppUi.showSnack('Perubahan pada "$sectionKey" berhasil disimpan!');
      } else {
        throw Exception(res is Map ? res['message'] : 'Gagal menyimpan');
      }
    } catch (e) {
      AppUi.showSnack('GAGAL SIMPAN: ${e.toString()}');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _openLiveLandingPage() async {
    final uri = Uri.parse('https://mdhproduction.com');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      AppUi.showSnack('Tidak dapat membuka URL https://mdhproduction.com');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return WebResponsiveScaffold(
      title: 'LANDING PAGE CMS & MARKETING',
      activeWebTitle: 'Landing Page CMS & Marketing Manager',
      actions: [
        TextButton.icon(
          onPressed: _openLiveLandingPage,
          icon: const Icon(Icons.open_in_new_rounded, size: 18, color: Colors.blueAccent),
          label: const Text('LIHAT LANDING PAGE', style: TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.bold)),
        ),
        const SizedBox(width: 8),
      ],
      body: WebResponsiveWrapper(
        activeTitle: 'LANDING PAGE CMS & MARKETING',
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1100),
                  child: Column(
                    children: [
                      AppSegmentedTabBar(
                        controller: _tabController,
                        isScrollable: true,
                        tabs: const [
                          AppTabItem(label: 'Hero & Banner', icon: Icons.view_carousel_rounded),
                          AppTabItem(label: 'Kontak & Sales WA', icon: Icons.chat_rounded),
                          AppTabItem(label: 'Fitur Unggulan', icon: Icons.star_rounded),
                          AppTabItem(label: 'FAQ', icon: Icons.quiz_rounded),
                          AppTabItem(label: 'Testimoni & SEO', icon: Icons.reviews_rounded),
                        ],
                      ),
                      Expanded(
                        child: TabBarView(
                          controller: _tabController,
                          children: [
                            _buildHeroTab(theme),
                            _buildContactTab(theme),
                            _buildFeaturesTab(theme),
                            _buildFaqTab(theme),
                            _buildTestiAndSeoTab(theme),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
      ),
    );
  }

  Widget _buildHeroTab(ThemeData theme) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionCard(
            theme: theme,
            title: 'HERO HEADER & PANGGILAN AKSI (CTA)',
            description: 'Atur teks banner pembuka di halaman depan mdhproduction.com.',
            child: Column(
              children: [
                _buildTextField(theme, 'Badge / Label Atas', _heroBadgeCtrl, 'Contoh: ERP Multi-Tenant & Omnichannel Marketplace #1 di Indonesia'),
                const SizedBox(height: 14),
                _buildTextField(theme, 'Headline Utama (Judul Besar)', _heroTitleCtrl, 'Judul utama landing page', maxLines: 2),
                const SizedBox(height: 14),
                _buildTextField(theme, 'Sub-headline (Penjelasan Singkat)', _heroSubtitleCtrl, 'Penjelasan ringkas nilai manfaat produk', maxLines: 3),
                const SizedBox(height: 18),
                const Divider(),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(child: _buildTextField(theme, 'Teks Tombol Utama', _heroCtaPrimaryTextCtrl, 'Coba Gratis Sekarang')),
                    const SizedBox(width: 12),
                    Expanded(child: _buildTextField(theme, 'Link Tombol Utama', _heroCtaPrimaryLinkCtrl, 'https://app.mdhproduction.com/register')),
                  ],
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(child: _buildTextField(theme, 'Teks Tombol Sekunder', _heroCtaSecondaryTextCtrl, 'Konsultasi Sales')),
                    const SizedBox(width: 12),
                    Expanded(child: _buildTextField(theme, 'Link Tombol Sekunder', _heroCtaSecondaryLinkCtrl, 'https://wa.me/...')),
                  ],
                ),
                const SizedBox(height: 20),
                Align(
                  alignment: Alignment.centerRight,
                  child: _buildSaveButton(
                    theme: theme,
                    label: 'SIMPAN HERO SECTION',
                    onSave: () {
                      _saveSection('hero', {
                        'badge': _heroBadgeCtrl.text.trim(),
                        'title': _heroTitleCtrl.text.trim(),
                        'subtitle': _heroSubtitleCtrl.text.trim(),
                        'cta_primary_text': _heroCtaPrimaryTextCtrl.text.trim(),
                        'cta_primary_link': _heroCtaPrimaryLinkCtrl.text.trim(),
                        'cta_secondary_text': _heroCtaSecondaryTextCtrl.text.trim(),
                        'cta_secondary_link': _heroCtaSecondaryLinkCtrl.text.trim(),
                        'stats': _statsList,
                      });
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContactTab(ThemeData theme) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionCard(
            theme: theme,
            title: 'KONTAK SALES & INTEGRASI WHATSAPP',
            description: 'Pengaturan tombol chat WhatsApp floating dan informasi kontak resmi di footer.',
            child: Column(
              children: [
                _buildTextField(theme, 'Nama Brand / Perusahaan', _companyNameCtrl, 'MDH Production'),
                const SizedBox(height: 14),
                _buildTextField(theme, 'Nomor WhatsApp Sales (Gunakan awalan 62)', _waNumberCtrl, '6281234567890'),
                const SizedBox(height: 14),
                _buildTextField(theme, 'Template Pesan Otomatis WhatsApp', _waMessageCtrl, 'Halo Admin, saya tertarik dengan paket ERP ini.', maxLines: 2),
                const SizedBox(height: 14),
                _buildTextField(theme, 'Email Support Resmi', _supportEmailCtrl, 'support@mdhproduction.com'),
                const SizedBox(height: 14),
                _buildTextField(theme, 'Alamat Kantor', _addressCtrl, 'Jakarta, Indonesia'),
                const SizedBox(height: 20),
                Align(
                  alignment: Alignment.centerRight,
                  child: _buildSaveButton(
                    theme: theme,
                    label: 'SIMPAN KONTAK & WHATSAPP',
                    color: AppUi.green,
                    onSave: () {
                      _saveSection('contact', {
                        'company_name': _companyNameCtrl.text.trim(),
                        'whatsapp_number': _waNumberCtrl.text.trim(),
                        'whatsapp_message': _waMessageCtrl.text.trim(),
                        'support_email': _supportEmailCtrl.text.trim(),
                        'address': _addressCtrl.text.trim(),
                        'app_login_url': 'https://app.mdhproduction.com',
                        'app_register_url': 'https://app.mdhproduction.com/register',
                      });
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFeaturesTab(ThemeData theme) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionCard(
            theme: theme,
            title: 'DAFTAR FITUR UNGGULAN LANDING PAGE',
            description: 'Kelola 6 kartu fitur showcase yang tampil di bagian Fitur Unggulan.',
            child: Column(
              children: [
                ..._featureList.asMap().entries.map((entry) {
                  final idx = entry.key;
                  final item = entry.value;
                  return Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: theme.scaffoldBackgroundColor,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.white10),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Fitur #${idx + 1}', style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.blueAccent)),
                        const SizedBox(height: 8),
                        TextFormField(
                          initialValue: item['title']?.toString() ?? '',
                          decoration: const InputDecoration(labelText: 'Judul Fitur', isDense: true),
                          onChanged: (v) => _featureList[idx]['title'] = v,
                        ),
                        const SizedBox(height: 8),
                        TextFormField(
                          initialValue: item['desc']?.toString() ?? '',
                          maxLines: 2,
                          decoration: const InputDecoration(labelText: 'Deskripsi Fitur', isDense: true),
                          onChanged: (v) => _featureList[idx]['desc'] = v,
                        ),
                      ],
                    ),
                  );
                }),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerRight,
                  child: _buildSaveButton(
                    theme: theme,
                    label: 'SIMPAN FITUR UNGGULAN',
                    onSave: () {
                      _saveSection('features', {
                        'badge': 'Fitur Unggulan',
                        'title': 'Solusi Menyeluruh untuk Efisiensi Bisnis Anda',
                        'subtitle': 'Setiap modul dirancang khusus untuk mempermudah operasional harian.',
                        'items': _featureList,
                      });
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFaqTab(ThemeData theme) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionCard(
            theme: theme,
            title: 'PERTANYAAN & JAWABAN (FAQ)',
            description: 'Pertanyaan umum yang sering ditanyakan oleh calon tenant.',
            child: Column(
              children: [
                ..._faqList.asMap().entries.map((entry) {
                  final idx = entry.key;
                  final item = entry.value;
                  return Container(
                    margin: const EdgeInsets.only(bottom: 14),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: theme.scaffoldBackgroundColor,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.white10),
                    ),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Text('FAQ #${idx + 1}', style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.amber)),
                            const Spacer(),
                            IconButton(
                              icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 20),
                              onPressed: () {
                                setState(() => _faqList.removeAt(idx));
                              },
                            ),
                          ],
                        ),
                        TextFormField(
                          initialValue: item['question']?.toString() ?? '',
                          decoration: const InputDecoration(labelText: 'Pertanyaan', isDense: true),
                          onChanged: (v) => _faqList[idx]['question'] = v,
                        ),
                        const SizedBox(height: 8),
                        TextFormField(
                          initialValue: item['answer']?.toString() ?? '',
                          maxLines: 2,
                          decoration: const InputDecoration(labelText: 'Jawaban', isDense: true),
                          onChanged: (v) => _faqList[idx]['answer'] = v,
                        ),
                      ],
                    ),
                  );
                }),
                OutlinedButton.icon(
                  onPressed: () {
                    setState(() {
                      _faqList.add({'question': 'Pertanyaan baru?', 'answer': 'Jawaban penjelasan...'});
                    });
                  },
                  icon: const Icon(Icons.add),
                  label: const Text('TAMBAH ITEM FAQ'),
                ),
                const SizedBox(height: 20),
                Align(
                  alignment: Alignment.centerRight,
                  child: _buildSaveButton(
                    theme: theme,
                    label: 'SIMPAN FAQ',
                    onSave: () {
                      _saveSection('faq', {
                        'badge': 'FAQ',
                        'title': 'Pertanyaan yang Sering Diajukan',
                        'subtitle': 'Punya pertanyaan seputar cara kerja sistem? Temukan jawabannya di sini.',
                        'items': _faqList,
                      });
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTestiAndSeoTab(ThemeData theme) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionCard(
            theme: theme,
            title: 'TESTIMONI PENGGUNA',
            description: 'Ulasan dan bukti sosial dari pebisnis yang telah menggunakan sistem.',
            child: Column(
              children: [
                ..._testiList.asMap().entries.map((entry) {
                  final idx = entry.key;
                  final item = entry.value;
                  return Container(
                    margin: const EdgeInsets.only(bottom: 14),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: theme.scaffoldBackgroundColor,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.white10),
                    ),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Text('Testimoni #${idx + 1}', style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.purpleAccent)),
                            const Spacer(),
                            IconButton(
                              icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 20),
                              onPressed: () {
                                setState(() => _testiList.removeAt(idx));
                              },
                            ),
                          ],
                        ),
                        Row(
                          children: [
                            Expanded(
                              child: TextFormField(
                                initialValue: item['name']?.toString() ?? '',
                                decoration: const InputDecoration(labelText: 'Nama Klien', isDense: true),
                                onChanged: (v) => _testiList[idx]['name'] = v,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: TextFormField(
                                initialValue: item['role']?.toString() ?? '',
                                decoration: const InputDecoration(labelText: 'Jabatan / Nama Toko', isDense: true),
                                onChanged: (v) => _testiList[idx]['role'] = v,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        TextFormField(
                          initialValue: item['quote']?.toString() ?? '',
                          maxLines: 2,
                          decoration: const InputDecoration(labelText: 'Kutipan Testimoni', isDense: true),
                          onChanged: (v) => _testiList[idx]['quote'] = v,
                        ),
                      ],
                    ),
                  );
                }),
                OutlinedButton.icon(
                  onPressed: () {
                    setState(() {
                      _testiList.add({'name': 'Nama Klien', 'role': 'Owner Brand', 'quote': 'Kesan pengalaman menggunakan ERP...'});
                    });
                  },
                  icon: const Icon(Icons.add),
                  label: const Text('TAMBAH TESTIMONI'),
                ),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerRight,
                  child: _buildSaveButton(
                    theme: theme,
                    label: 'SIMPAN TESTIMONI',
                    color: AppUi.teal,
                    onSave: () {
                      _saveSection('testimonials', {
                        'badge': 'Testimoni Pengguna',
                        'title': 'Dipercaya Oleh Pebisnis & Brand di Seluruh Indonesia',
                        'subtitle': 'Dengarkan pengalaman langsung dari mereka yang telah mendigitalkan operasionalnya.',
                        'items': _testiList,
                      });
                    },
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          _sectionCard(
            theme: theme,
            title: 'OPTIMASI SEARCH ENGINE (SEO)',
            description: 'Tag meta yang muncul di hasil pencarian Google dan preview media sosial saat link dibagikan.',
            child: Column(
              children: [
                _buildTextField(theme, 'Meta Title (Judul Tab Browser)', _seoTitleCtrl, 'MDH Production - Sistem ERP & Omnichannel Inventory Management'),
                const SizedBox(height: 14),
                _buildTextField(theme, 'Meta Description', _seoDescCtrl, 'Deskripsi 1-2 kalimat untuk Google search', maxLines: 2),
                const SizedBox(height: 14),
                _buildTextField(theme, 'Keywords (Pisahkan dengan koma)', _seoKeywordsCtrl, 'ERP Indonesia, Manajemen Stok, Shopee, TikTok'),
                const SizedBox(height: 20),
                Align(
                  alignment: Alignment.centerRight,
                  child: _buildSaveButton(
                    theme: theme,
                    label: 'SIMPAN PENGATURAN SEO',
                    onSave: () {
                      _saveSection('seo', {
                        'meta_title': _seoTitleCtrl.text.trim(),
                        'meta_description': _seoDescCtrl.text.trim(),
                        'meta_keywords': _seoKeywordsCtrl.text.trim(),
                      });
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSaveButton({
    required ThemeData theme,
    required String label,
    required VoidCallback onSave,
    Color? color,
  }) {
    final btnColor = color ?? theme.colorScheme.primary;
    return FilledButton.icon(
      onPressed: _isSaving ? null : onSave,
      style: FilledButton.styleFrom(
        backgroundColor: btnColor,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        elevation: 2,
      ),
      icon: _isSaving
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Colors.white))
          : const Icon(Icons.save_rounded, size: 18, color: Colors.white),
      label: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w700,
          fontSize: 13,
          letterSpacing: 0.2,
        ),
      ),
    );
  }

  Widget _sectionCard({
    required ThemeData theme,
    required String title,
    required String description,
    required Widget child,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, letterSpacing: 0.5)),
          const SizedBox(height: 4),
          Text(description, style: const TextStyle(color: Colors.grey, fontSize: 13)),
          const SizedBox(height: 18),
          child,
        ],
      ),
    );
  }

  Widget _buildTextField(ThemeData theme, String label, TextEditingController ctrl, String hint, {int maxLines = 1}) {
    return TextFormField(
      controller: ctrl,
      onTap: AppUi.selectOnTap(ctrl),
      maxLines: maxLines,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        filled: true,
        fillColor: theme.scaffoldBackgroundColor,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Colors.white10)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Colors.white10)),
      ),
    );
  }
}
