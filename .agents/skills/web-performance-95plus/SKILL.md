---
name: web-performance-95plus
description: Use this skill when building, auditing, refactoring, optimizing, or deploying modern landing pages and web applications to achieve 95-100 Google PageSpeed Insights and Lighthouse scores across Mobile & Desktop (0ms TBT, 0.000 CLS, sub-1s FCP/LCP, 100 SEO, 100 Accessibility, 100 Best Practices, and 3/3 Agentic AI Browsing).
---

# Web Performance 95+ Engineering Standard

Standar operasional prosedur (SOP) baku rekayasa web untuk membangun dan mengoptimalkan landing page, aplikasi web, dan portal SaaS agar mencapai skor 95–100 pada Google PageSpeed Insights / Lighthouse (Mobile & Desktop).

---

## 1. Sasaran Metrik & Target Skor

| Metrik Core Web Vitals | Target Mobile | Target Desktop | Dampak Performa |
| :--- | :--- | :--- | :--- |
| **First Contentful Paint (FCP)** | `< 0.8s` | `< 0.4s` | Persepsi kecepatan muat pertama kali |
| **Largest Contentful Paint (LCP)** | `< 1.2s` | `< 0.8s` | Waktu render elemen konten utama |
| **Total Blocking Time (TBT)** | `0 ms` (Hijau) | `0 ms` (Hijau) | Responsivitas terhadap klik & interaksi |
| **Cumulative Layout Shift (CLS)** | `< 0.005` (Nol) | `< 0.005` (Nol) | Stabilitas tata letak visual tanpa loncatan |
| **Speed Index (SI)** | `< 1.5s` | `< 0.8s` | Kecepatan visualisasi seluruh viewport |
| **Accessibility** | `100 / 100` | `100 / 100` | Ramah pembaca layar & kontras warna WCAG |
| **Best Practices** | `100 / 100` | `100 / 100` | Keamanan HTTPS, header modern, format WebP |
| **SEO** | `100 / 100` | `100 / 100` | Schema JSON-LD, kanonikal, meta deskripsi |
| **Agentic AI Browsing** | `3 / 3 (100%)` | `3 / 3 (100%)` | Kepatuhan terhadap spesifikasi llms.txt |

---

## 2. Arsitektur Rendering & Zero CLS (0.000)

### Aturan Utama:
1. **Single Inlined Minified Stylesheet di `<head>`**:
   - Untuk landing page (HTML statis atau server-rendered), inlining seluruh stylesheet minified ke dalam tag `<style>` tunggal di dalam `<head>`.
   - Menghilangkan *network roundtrip* terpisah untuk file CSS dan mencegah *flash of unstyled content* (FOUC).
2. **Dimensi Eksplisit pada Seluruh Elemen Gambar**:
   - Setiap tag `<img>`, `<picture>`, dan icon container **wajib** memiliki atribut `width` dan `height` numerik eksplisit (misal `width="280" height="593"`).
   - Gunakan CSS `aspect-ratio` pada container pembungkus agar browser mengalokasikan ruang piksel sebelum gambar selesai diunduh:
     ```css
     .hero-phone-device-frame {
       width: 290px;
       max-width: 100%;
       aspect-ratio: 755 / 1600;
       contain: layout size;
     }
     ```
3. **Content Visibility & Containment**:
   - Terapkan `content-visibility: auto` dan `contain-intrinsic-size` pada section di bawah lipatan layar (*below-the-fold*):
     ```css
     .features-section, .pricing-section, .faq-section {
       content-visibility: auto;
       contain-intrinsic-size: 1px 800px;
     }
     ```

---

## 3. Pemberantasan FOIT (Flash of Invisible Text) & FCP Sub-Detik

### Masalah Klasik:
Pada simulasi jaringan lambat / Mobile 4G Lighthouse, jika Google Fonts dimuat secara blocking, browser menahan rendering teks selama 3 detik (*timeout FOIT*), menyebabkan FCP membengkak menjadi `4.4s` (Skor anjlok ke 70-an).

### Solusi Zero-FOIT:
1. **System Font Fallback Stack**:
   Definisikan variabel font dengan mengutamakan system font stack sebagai cadangan pertama:
   ```css
   :root {
     --font-heading: 'Outfit', -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif;
     --font-body: 'Plus Jakarta Sans', -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif;
   }
   ```
2. **Pemuatan Asinkron dengan Media Print Hack**:
   Muat Google Fonts menggunakan `media="print" onload="this.media='all'"`:
   ```html
   <link rel="preconnect" href="https://fonts.googleapis.com">
   <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
   <link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Outfit:wght@600;800&family=Plus+Jakarta+Sans:wght@400;600;700&family=Material+Symbols+Outlined:opsz,wght,FILL,GRAD@24,400,0,0&display=swap" media="print" onload="this.media='all'">
   <noscript>
     <link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Outfit:wght@600;800&family=Plus+Jakarta+Sans:wght@400;600;700&family=Material+Symbols+Outlined:opsz,wght,FILL,GRAD@24,400,0,0&display=swap">
   </noscript>
   ```
   *Hasil*: Browser langsung merender layar secara instan dalam `< 0.4s` menggunakan system font, lalu memutakhirkan tipografi saat webfont selesai diunduh.

---

## 4. Standar Pengiriman Gambar Presisi (1x WebP)

### Aturan Dimensi:
- **Jangan kirim gambar yang lebih besar dari dimensi tampilannya di layar**. Jika sebuah mockup ponsel ditampilkan pada lebar `280px`, berkas gambar WebP harus dibuat dengan lebar persis `280px` (bukan 1080px atau 560px).
- Ukuran target untuk screenshot interface mobile adalah **5 KB – 15 KB**.

### Responsive Picture Tag untuk Hero LCP:
```html
<!-- Preload di dalam <head> -->
<link rel="preload" as="image" href="assets/mobile_screens/login_page_mobile.webp" type="image/webp" media="(max-width: 640px)" fetchpriority="high">
<link rel="preload" as="image" href="assets/mobile_screens/login_page.webp" type="image/webp" media="(min-width: 641px)" fetchpriority="high">

<!-- Elemen di dalam <body> -->
<picture>
  <source media="(max-width: 640px)" srcset="assets/mobile_screens/login_page_mobile.webp" type="image/webp">
  <source srcset="assets/mobile_screens/login_page.webp" type="image/webp">
  <img src="assets/mobile_screens/login_page.webp" alt="Tampilan Halaman Login Mobile ERP" class="phone-screen-img" width="280" height="593" fetchpriority="high" decoding="async">
</picture>
```

---

## 5. Zero Total Blocking Time (TBT: 0ms)

### Kebijakan JavaScript Ringan:
1. **Dilarang Menggunakan JS Animasi Berat**:
   - Hindari *GSAP*, *ScrollTrigger*, *Anime.js*, atau *jQuery* pada landing page.
   - Ganti seluruh efek transisi, tab fade, dan marquee dengan **Pure CSS Keyframes**:
     ```css
     @keyframes fadeInPane {
       from { opacity: 0; transform: translateY(8px); }
       to { opacity: 1; transform: translateY(0); }
     }
     ```
2. **Lazy Initialization Berbasis Interaksi Nyata Pengguna**:
   - Jika halaman memiliki efek Canvas 2D/3D (seperti mesh partikel atau chart interaktif), jangan jalankan saat halaman dimuat.
   - Tunda hingga pengguna menyentuh layar atau menggerakkan kursor:
     ```javascript
     function initHeavyComponents() {
       // Jalankan Canvas atau WebGL
     }

     const triggerEvents = ['pointerdown', 'touchstart', 'keydown', 'scroll'];
     function onFirstInteraction() {
       triggerEvents.forEach(e => window.removeEventListener(e, onFirstInteraction, { passive: true }));
       requestIdleCallback ? requestIdleCallback(initHeavyComponents) : setTimeout(initHeavyComponents, 100);
     }
     triggerEvents.forEach(e => window.addEventListener(e, onFirstInteraction, { passive: true, once: true }));
     ```
3. **Passive Event Listeners**:
   - Selalu tambahkan `{ passive: true }` pada semua event listener `scroll`, `touchstart`, dan `touchmove`.

---

## 6. Aksesibilitas & Best Practices (100 / 100)

1. **Kontras Warna WCAG AA/AAA**:
   - Teks pada latar gelap harus memiliki kontras minimal `4.5:1` (teks reguler) dan `3:1` (teks tebal/judul besar). Gunakan `#cbd5e1` (bukan `#64748b` untuk teks isi panjang).
2. **Atribut ARIA & Dekorasi**:
   - Seluruh ikon SVG atau font ikon (seperti Material Symbols) **wajib** memiliki `aria-hidden="true"`.
   - Seluruh tombol interaktif atau icon-only button **wajib** memiliki `aria-label="Deskripsi Aksi"`.
3. **Struktur Tag Semantik**:
   - Gunakan `<header>`, `<nav>`, `<main>`, `<section>`, dan `<footer>` secara hierarkis.
   - Hanya perbolehkan **satu tag `<h1>`** per halaman. Gunakan `<h2>` untuk judul seksi dan `<h3>` untuk sub-kartu.
4. **Kebijakan Zero-Emoji**:
   - Selalu gunakan font ikon resmi (Material Symbols Outlined / SVG) daripada karakter emoji untuk konsistensi cross-platform dan kejelasan screen reader.

---

## 7. SEO & Structured Data (100 / 100)

Semua landing page wajib menyematkan multi-graph Schema.org JSON-LD sebelum tag penutup `</body>`:
```html
<script type="application/ld+json">
{
  "@context": "https://schema.org",
  "@graph": [
    {
      "@type": "WebSite",
      "@id": "https://domain.com/#website",
      "url": "https://domain.com/",
      "name": "Nama Produk / Brand",
      "inLanguage": "id-ID"
    },
    {
      "@type": "Organization",
      "@id": "https://domain.com/#organization",
      "name": "Nama Perusahaan",
      "url": "https://domain.com/",
      "logo": "https://domain.com/assets/logo.png"
    },
    {
      "@type": "SoftwareApplication",
      "@id": "https://domain.com/#software",
      "name": "Nama Aplikasi",
      "operatingSystem": "Android, iOS, Web",
      "applicationCategory": "BusinessApplication"
    },
    {
      "@type": "FAQPage",
      "@id": "https://domain.com/#faq",
      "mainEntity": [
        {
          "@type": "Question",
          "name": "Pertanyaan FAQ 1?",
          "acceptedAnswer": {
            "@type": "Answer",
            "text": "Jawaban terperinci..."
          }
        }
      ]
    }
  ]
}
</script>
```

---

## 8. Standar Agentic AI Browsing (llms.txt) (3/3 Passed)

Letakkan file `llms.txt` dan `llms-full.txt` di direktori root web (`/var/www/landing_page/llms.txt`):
- Format `llms.txt`:
  ```markdown
  # Nama Platform / Software

  > Ringkasan eksekutif produk, sasaran pengguna, dan keunggulan utama dalam 1 paragraf padat.

  ## Fitur Utama & Dokumentasi
  - [Manajemen Stok Gudang](https://domain.com/#fitur-stok): Real-time barcode scanner dan sinkronisasi omnichannel.
  - [Rekonsiliasi Keuangan](https://domain.com/#fitur-keuangan): Otomasi audit pencairan dana Shopee & TikTok Shop.
  - [Aktivasi & Coba Gratis](https://domain.com/#kontak): Hubungi konsultan via WhatsApp resmi.

  ## Direct Action Endpoints
  - Portal Aplikasi: https://app.domain.com
  - WhatsApp Hotline: https://wa.me/6285155338246
  ```

---

## 9. Konfigurasi DevOps & Nginx Pre-Gzipping

1. **Pre-Gzipping Otomatis**:
   Kompresi seluruh berkas `.html`, `.css`, `.js`, dan `.txt` menjadi `.gz` sebelum dideploy ke server.
2. **Nginx Block Configuration**:
   ```nginx
   server {
       listen 80;
       server_name domain.com www.domain.com;
       root /var/www/landing_page;
       index index.html;

       # Aktifkan pre-gzip statis
       gzip_static on;
       gzip_vary on;

       # Security Headers
       add_header X-Frame-Options "SAMEORIGIN" always;
       add_header X-Content-Type-Options "nosniff" always;

       # Cache control: HTML wajib selalu fresh
       location ~* \.html$ {
           add_header Cache-Control "no-cache, must-revalidate";
       }

       # Cache control: Aset statis & gambar immutable 1 tahun
       location ~* \.(webp|png|jpg|jpeg|svg|ico|woff2|woff|ttf|txt)$ {
           add_header Cache-Control "public, max-age=31536000, immutable";
           access_log off;
       }
   }
   ```

---

## 10. Checklist Verifikasi Sebelum Rilis

- [ ] Seluruh stylesheet utama di-inline ke tag `<style>` di `<head>`.
- [ ] Google Fonts dimuat dengan `media="print" onload="this.media='all'"` dan system font stack.
- [ ] Seluruh gambar berformat WebP dengan dimensi 1x presisi (ukuran < 15 KB).
- [ ] Atribut `width`, `height`, dan `aspect-ratio` terpasang di semua media visual.
- [ ] JavaScript bebas dari library berat (Zero GSAP / Zero jQuery).
- [ ] TBT teruji `0 ms` dan CLS `< 0.005`.
- [ ] Multi-graph Schema.org JSON-LD valid di Rich Results Test.
- [ ] Berkas `/llms.txt` tersedia dan dapat diakses publik.
- [ ] Nginx menyajikan `gzip_static on` dengan header cache yang tepat.
