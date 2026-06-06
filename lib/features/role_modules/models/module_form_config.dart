class ModuleFormConfig {
  final String titleLabel;
  final String titleHint;
  final String descriptionLabel;
  final String descriptionHint;
  final String amountLabel;
  final String proofLabel;
  final String proofHint;
  final bool showAmount;
  final bool showProof;
  final bool showAssignedRole;
  final String defaultAssignedRole;
  final String defaultStatus;
  final List<String> statusOptions;

  const ModuleFormConfig({
    required this.titleLabel,
    required this.titleHint,
    required this.descriptionLabel,
    required this.descriptionHint,
    required this.amountLabel,
    required this.proofLabel,
    required this.proofHint,
    required this.showAmount,
    required this.showProof,
    required this.showAssignedRole,
    required this.defaultAssignedRole,
    required this.defaultStatus,
    required this.statusOptions,
  });

  factory ModuleFormConfig.fromKey(String moduleKey) {
    switch (moduleKey) {
      case 'purchase_request':
        return const ModuleFormConfig(
          titleLabel: 'Nama Barang / Bahan',
          titleHint: 'Contoh: Kain cotton combed 24s',
          descriptionLabel: 'Detail Pembelian',
          descriptionHint: 'Isi supplier, jenis barang, harga per item, jumlah, catatan',
          amountLabel: 'Total Pembelian / Qty',
          proofLabel: 'Link Bukti / Nota',
          proofHint: 'Opsional, link foto nota atau file',
          showAmount: true,
          showProof: true,
          showAssignedRole: true,
          defaultAssignedRole: 'finance',
          defaultStatus: 'waiting_verification',
          statusOptions: [
            'waiting_verification',
            'approved',
            'rejected',
            'done',
          ],
        );

      case 'nota_upload':
        return const ModuleFormConfig(
          titleLabel: 'Nomor Nota / Nama Supplier',
          titleHint: 'Contoh: Nota Toko ABC 14/05',
          descriptionLabel: 'Detail Nota',
          descriptionHint: 'Isi item, harga, total, dan catatan nota',
          amountLabel: 'Total Nota',
          proofLabel: 'Link Foto Nota',
          proofHint: 'Tempel link foto/file nota',
          showAmount: true,
          showProof: true,
          showAssignedRole: true,
          defaultAssignedRole: 'finance',
          defaultStatus: 'waiting_verification',
          statusOptions: [
            'waiting_verification',
            'approved',
            'rejected',
          ],
        );

      case 'stock_progress':
        return const ModuleFormConfig(
          titleLabel: 'Nama Proses / SKU',
          titleHint: 'Contoh: Produksi Rubelle Top Black',
          descriptionLabel: 'Detail Proses',
          descriptionHint: 'Isi bahan, qty masuk proses, estimasi selesai, catatan',
          amountLabel: 'Qty Progress',
          proofLabel: 'Link Bukti',
          proofHint: 'Opsional',
          showAmount: true,
          showProof: false,
          showAssignedRole: true,
          defaultAssignedRole: 'produksi',
          defaultStatus: 'progress',
          statusOptions: [
            'open',
            'progress',
            'done',
          ],
        );

      case 'finance_note_check':
        return const ModuleFormConfig(
          titleLabel: 'Nomor Nota / Pembelian',
          titleHint: 'Contoh: Nota ABC / Pembelian kain',
          descriptionLabel: 'Hasil Cek Nota',
          descriptionHint: 'Isi kesesuaian item, harga, total, selisih, catatan finance',
          amountLabel: 'Total / Selisih',
          proofLabel: 'Link Bukti Nota',
          proofHint: 'Opsional',
          showAmount: true,
          showProof: true,
          showAssignedRole: true,
          defaultAssignedRole: 'finance',
          defaultStatus: 'open',
          statusOptions: [
            'open',
            'approved',
            'rejected',
            'done',
          ],
        );

      case 'global_task':
        return const ModuleFormConfig(
          titleLabel: 'Judul Task',
          titleHint: 'Contoh: Cek stock opname rak A',
          descriptionLabel: 'Detail Task',
          descriptionHint: 'Isi instruksi, deadline, target kerja',
          amountLabel: 'Bobot / Qty',
          proofLabel: 'Link Bukti Task',
          proofHint: 'Opsional, link foto/file bukti',
          showAmount: false,
          showProof: true,
          showAssignedRole: true,
          defaultAssignedRole: 'warehouse',
          defaultStatus: 'open',
          statusOptions: [
            'open',
            'progress',
            'waiting_verification',
            'approved',
            'rejected',
            'done',
          ],
        );

      case 'host_live_verification':
      case 'stream_off_proof':
        return const ModuleFormConfig(
          titleLabel: 'Nama Host / Shift',
          titleHint: 'Contoh: Dini - Shift 1 Sesi 2',
          descriptionLabel: 'Detail Live',
          descriptionHint: 'Isi jam live, platform, kendala, catatan stream off',
          amountLabel: 'Durasi Live / Score',
          proofLabel: 'Link Bukti Stream Off',
          proofHint: 'Tempel link foto/screenshot bukti stream off',
          showAmount: true,
          showProof: true,
          showAssignedRole: true,
          defaultAssignedRole: 'hr',
          defaultStatus: 'waiting_verification',
          statusOptions: [
            'waiting_verification',
            'approved',
            'rejected',
            'done',
          ],
        );

      case 'live_schedule':
        return const ModuleFormConfig(
          titleLabel: 'Nama Host / Jadwal',
          titleHint: 'Contoh: Dini - Shift 2',
          descriptionLabel: 'Detail Jadwal',
          descriptionHint: 'Isi tanggal, jam, sesi 1/2, platform',
          amountLabel: 'Durasi',
          proofLabel: 'Link Bukti',
          proofHint: 'Opsional',
          showAmount: false,
          showProof: false,
          showAssignedRole: true,
          defaultAssignedRole: 'host_live',
          defaultStatus: 'open',
          statusOptions: [
            'open',
            'progress',
            'done',
          ],
        );

      case 'content_task':
      case 'content_proof':
        return const ModuleFormConfig(
          titleLabel: 'Judul Konten',
          titleHint: 'Contoh: Video produk Rubelle Black',
          descriptionLabel: 'Brief / Detail Konten',
          descriptionHint: 'Isi konsep, platform, deadline, caption, catatan revisi',
          amountLabel: 'Jumlah Konten',
          proofLabel: 'Link Bukti Konten',
          proofHint: 'Tempel link posting/file konten',
          showAmount: true,
          showProof: true,
          showAssignedRole: true,
          defaultAssignedRole: 'content_creator',
          defaultStatus: 'open',
          statusOptions: [
            'open',
            'progress',
            'waiting_verification',
            'approved',
            'rejected',
            'done',
          ],
        );

      case 'employee_performance':
        return const ModuleFormConfig(
          titleLabel: 'Nama Karyawan',
          titleHint: 'Contoh: Staff Warehouse 01',
          descriptionLabel: 'Catatan Kinerja',
          descriptionHint: 'Isi performa, absensi, task selesai, kendala',
          amountLabel: 'Nilai / Score',
          proofLabel: 'Link Bukti',
          proofHint: 'Opsional',
          showAmount: true,
          showProof: false,
          showAssignedRole: true,
          defaultAssignedRole: 'hr',
          defaultStatus: 'open',
          statusOptions: [
            'open',
            'reviewed',
            'done',
          ],
        );

      case 'supplier_master':
        return const ModuleFormConfig(
          titleLabel: 'Nama Supplier',
          titleHint: 'Contoh: Toko Kain ABC',
          descriptionLabel: 'Detail Supplier',
          descriptionHint: 'Isi kontak, alamat, jenis barang, catatan',
          amountLabel: 'Limit / Saldo',
          proofLabel: 'Link Dokumen',
          proofHint: 'Opsional',
          showAmount: false,
          showProof: false,
          showAssignedRole: false,
          defaultAssignedRole: 'super_admin',
          defaultStatus: 'active',
          statusOptions: [
            'active',
            'inactive',
          ],
        );

      case 'work_location':
        return const ModuleFormConfig(
          titleLabel: 'Nama Lokasi Kerja',
          titleHint: 'Contoh: Gudang Utama',
          descriptionLabel: 'Detail Geofence',
          descriptionHint: 'Isi latitude, longitude, radius meter, catatan lokasi',
          amountLabel: 'Radius Meter',
          proofLabel: 'Link Maps',
          proofHint: 'Opsional',
          showAmount: true,
          showProof: true,
          showAssignedRole: false,
          defaultAssignedRole: 'super_admin',
          defaultStatus: 'active',
          statusOptions: [
            'active',
            'inactive',
          ],
        );

      default:
        return const ModuleFormConfig(
          titleLabel: 'Judul Data',
          titleHint: 'Isi judul data',
          descriptionLabel: 'Detail / Catatan',
          descriptionHint: 'Isi detail data modul',
          amountLabel: 'Nominal / Qty',
          proofLabel: 'Link Bukti / File',
          proofHint: 'Opsional',
          showAmount: true,
          showProof: true,
          showAssignedRole: true,
          defaultAssignedRole: 'super_admin',
          defaultStatus: 'open',
          statusOptions: [
            'open',
            'progress',
            'waiting_verification',
            'approved',
            'rejected',
            'done',
          ],
        );
    }
  }
}