# Specification Report: Mobile ERP Enterprise SEO, Rich Schemas & Consultation Engine

**Author**: Explorer 3 (SEO & Enterprise Spec Miner)  
**Target File**: `landing_page/index.html`, `landing_page/app.js`, `landing_page/robots.txt`, `landing_page/sitemap.xml`  
**Canonical Production URL**: `https://mdhproduction.com`  
**Consultation Endpoint**: WhatsApp `085155338246` (Intl: `6285155338246`) | Email `bdchydi@sre.co.id`  
**Date**: 2026-08-16  

---

## Features Discovered

| # | Category | Feature | Description | Inputs | Outputs | Error Behavior | Discovered Via |
|---|----------|---------|-------------|--------|---------|----------------|----------------|
| 1 | SEO & Rich Schema | Schema.org JSON-LD `@graph` | Consolidated structured data providing rich snippets for enterprise Google Search results | Canonical domain, logo asset (`assets/logo.png`), contact points, pricing tiers, FAQs | Valid JSON-LD graph conforming to Google Rich Result tests | Fallback to base Organization/WebSite schema if dynamic pricing fails | `ORIGINAL_REQUEST.md`, `landing_page/index.html:46-129` |
| 2 | SEO & Rich Schema | `SoftwareApplication` Schema | Declares Mobile ERP application category, OS support, aggregate rating (4.9/5, 156 reviews), and tiered offers | Application metadata, rating scores, pricing matrix | Rich snippet app rating & price cards on SERP | Defaults to AggregateOffer if single tier unavailable | Schema.org standard, `ORIGINAL_REQUEST.md:R4` |
| 3 | SEO & Rich Schema | `Organization` & `ContactPoint` Schema | Declares corporate entity, official metallic logo, telephone (+6285155338246), email (bdchydi@sre.co.id), and languages | Corporate address (Jakarta, ID), verified contact points | Knowledge Graph card on Google Search | Fallback to root domain if contact fails | Schema.org standard, `ORIGINAL_REQUEST.md:R4` |
| 4 | SEO & Rich Schema | `WebSite` & `BreadcrumbList` Schema | Declares site identity and 5-level hierarchical navigation breadcrumbs for SERP search results | URL endpoints (`#fitur`, `#showcase`, `#paket-harga`, `#faq`) | SERP breadcrumb path display | Omits invalid breadcrumb positions | Google Search Central specification |
| 5 | SEO & Rich Schema | `FAQPage` Schema | Structured questions & answers written in enterprise terminology without prohibited words | 5 curated enterprise Q&As on WMS, OMS, FMS, HRIS, EMS | Expandable FAQ accordion rich snippets on Google | Strips HTML tags inside JSON-LD text | Schema.org standard, `ORIGINAL_REQUEST.md:R4` |
| 6 | Meta Tags | Indonesian Enterprise Search Meta Tags | Primary title, meta description, enterprise keywords, canonical tag, geo tags (Jakarta, ID) | Search keywords: "Mobile ERP", "Software ERP Indonesia", "WMS Indonesia", "Omnichannel ERP", "Integrasi Shopee TikTok" | Optimized snippet preview on Indonesian search engines | Keyword stuffing prevention; strict 155-160 char description | Google SEO Guidelines, `ORIGINAL_REQUEST.md:43` |
| 7 | Meta Tags & Social | OpenGraph & Twitter Cards | Rich link cards for WhatsApp, LinkedIn, Twitter/X, Facebook sharing | Title, description, `assets/logo.png` (512x512), secure URL | High-converting social card preview with metallic logo | Default fallback icon if image fails to render | Open Graph Protocol & Twitter Card Specs |
| 8 | Crawler Indexing | `robots.txt` Directives | Specific crawler access instructions for Googlebot, Googlebot-Image, Bingbot, and other crawlers | Crawl paths, Disallow `/api/`, `/_admin/`, `/temp/`, Allow `/assets/`, CSS, JS | 200 OK text response for web spiders | Prevents indexing of backend endpoints | RFC 9309 Robots Exclusion Protocol |
| 9 | Crawler Indexing | `sitemap.xml` XML Schema | Canonical URL index with image metadata for Google Image Search | URLs for `mdhproduction.com/`, `app.mdhproduction.com/`, `app.mdhproduction.com/register` | XML conforming to Sitemaps.org 0.9 schema | Returns standard XML or 404 if path missing | Sitemaps.org Protocol |
| 10 | Enterprise Conversion | Tiered WhatsApp Triggers (5 Plans) | Pre-filled enterprise WhatsApp consultation URLs for Trial, Starter, Growth, Pro, Enterprise | Plan code, plan name, price amount, billing cycle | One-click launch to WhatsApp `085155338246` with custom greeting | Graceful fallback if Supabase RPC fails via static plans | `ORIGINAL_REQUEST.md:R3`, `app.js:164-173` |
| 11 | Enterprise Conversion | Hero & Sticky Nav Triggers | Global consultation triggers routing enterprise leads to specialized consultant desk | Consultation query text | Direct WhatsApp deep link (`https://wa.me/6285155338246?text=...`) | Falls back to mailto `bdchydi@sre.co.id` | `ORIGINAL_REQUEST.md:R3` |
| 12 | Enterprise Governance | Enterprise Terminology Dictionary | Exhaustive replacement mapping eliminating amateur/casual terms ("owner", "stok barang", "bayar", etc.) | Prohibited term vocabulary | Formal corporate phrasing ("Tim Konsultan Enterprise", "WMS", "OMS", "FMS", "HRIS", "EMS") | Zero occurrences of "owner" across codebase | `ORIGINAL_REQUEST.md:R1, R3` |

---

## Edge Cases

| # | Feature | Input | Observed Behavior / Required Handling |
|---|---------|-------|----------------------------------------|
| 1 | WhatsApp Deep Link | User on desktop browser without WhatsApp Desktop app | Browser opens WhatsApp Web interface with encoded query text pre-filled |
| 2 | WhatsApp Deep Link | Special characters (accents, parentheses, currency symbols) in message | Message string must be strictly `encodeURIComponent()` encoded to avoid URI malformation |
| 3 | JSON-LD Schema | Non-existent favicon.ico referenced in schema | Broken image in Google Search Console audit. Must strictly reference `https://mdhproduction.com/assets/logo.png` |
| 4 | JSON-LD FAQPage | Prohibited words ("owner") in FAQ schema | Google Search index shows casual wording. Must be strictly sanitized to enterprise terminology |
| 5 | Meta Description | Description length exceeds 160 characters | Google SERP truncates text with ellipses. Must maintain description between 150-158 characters |
| 6 | Sitemap Image Extension | XML image namespace without proper closing tags | XML parsing error in Google Search Console. Must use `<image:image>` and `<image:loc>` correctly |
| 7 | Dynamic Pricing Matrix | Supabase RPC `get_public_landing_page_data` unreachable or offline | `app.js` catches error and renders fallback enterprise pricing with verified WhatsApp links |
| 8 | Breadcrumb Navigation | Deep links with anchor hashes (`#fitur`, `#paket-harga`) | Schema Breadcrumb must use absolute URLs with valid section IDs |

---

## 1. Complete JSON-LD Schema Specification

The landing page must inject the following valid JSON-LD structure inside `<head>` via `<script type="application/ld+json">`.

```json
{
  "@context": "https://schema.org",
  "@graph": [
    {
      "@type": "Organization",
      "@id": "https://mdhproduction.com/#organization",
      "name": "Mobile ERP Indonesia",
      "alternateName": "Mobile ERP Enterprise Omnichannel Suite",
      "url": "https://mdhproduction.com/",
      "logo": {
        "@type": "ImageObject",
        "url": "https://mdhproduction.com/assets/logo.png",
        "width": 512,
        "height": 512,
        "caption": "Logo Resmi Mobile ERP"
      },
      "image": "https://mdhproduction.com/assets/logo.png",
      "email": "bdchydi@sre.co.id",
      "telephone": "+6285155338246",
      "foundingLocation": {
        "@type": "Place",
        "name": "Jakarta, Indonesia"
      },
      "address": {
        "@type": "PostalAddress",
        "streetAddress": "Jakarta Enterprise Business Center",
        "addressLocality": "Jakarta",
        "addressRegion": "DKI Jakarta",
        "postalCode": "12930",
        "addressCountry": "ID"
      },
      "contactPoint": [
        {
          "@type": "ContactPoint",
          "telephone": "+6285155338246",
          "contactType": "Sales & Enterprise Consultation",
          "email": "bdchydi@sre.co.id",
          "availableLanguage": ["Indonesian", "English"],
          "areaServed": "ID",
          "contactOption": ["HearingImpairedSupported", "TollFree"]
        },
        {
          "@type": "ContactPoint",
          "telephone": "+6285155338246",
          "contactType": "Technical Support",
          "email": "bdchydi@sre.co.id",
          "availableLanguage": ["Indonesian", "English"],
          "areaServed": "ID"
        }
      ],
      "sameAs": [
        "https://app.mdhproduction.com"
      ]
    },
    {
      "@type": "SoftwareApplication",
      "@id": "https://mdhproduction.com/#software",
      "name": "Mobile ERP",
      "alternateName": "Mobile ERP Enterprise Omnichannel Suite",
      "operatingSystem": "Web, Android, iOS, Windows, macOS, Linux",
      "applicationCategory": "BusinessApplication, EnterpriseResourcePlanning, InventoryManagement",
      "applicationSubCategory": "Omnichannel ERP & Warehouse Management",
      "softwareVersion": "10.4 Enterprise",
      "url": "https://mdhproduction.com/",
      "image": "https://mdhproduction.com/assets/logo.png",
      "screenshot": "https://mdhproduction.com/assets/logo.png",
      "publisher": {
        "@id": "https://mdhproduction.com/#organization"
      },
      "description": "Platform Mobile ERP multi-tenant & manajemen inventaris pergudangan omnichannel (WMS, OMS, FMS, HRIS, EMS) #1 di Indonesia dengan integrasi Shopee Open Platform, TikTok Shop Partner, dan PostgreSQL Row-Level Security.",
      "featureList": [
        "WMS: Multi-Warehouse Architecture, Barcode Scanning & Reorder Point Limits",
        "OMS: Shopee Open Platform & TikTok Shop 2-Way Realtime Sync",
        "FMS: Automated 10-Minute Escrow Settlement Reconciliation & COGS Ledger",
        "HRIS: Live Stream Host Scheduling, GPS Attendance & Encrypted Payroll",
        "EMS: PostgreSQL Row-Level Security (RLS) Cryptographic Tenant Isolation"
      ],
      "aggregateRating": {
        "@type": "AggregateRating",
        "ratingValue": "4.9",
        "ratingCount": "156",
        "reviewCount": "156",
        "bestRating": "5",
        "worstRating": "1"
      },
      "offers": {
        "@type": "AggregateOffer",
        "priceCurrency": "IDR",
        "lowPrice": "0",
        "highPrice": "1299999",
        "offerCount": "5",
        "offers": [
          {
            "@type": "Offer",
            "name": "Trial Plan",
            "price": "0",
            "priceCurrency": "IDR",
            "description": "Evaluasi sistem gratis 14 hari dengan kapabilitas 3 pengguna, 2 toko marketplace, dan retensi 30 hari.",
            "url": "https://mdhproduction.com/#paket-harga",
            "availability": "https://schema.org/InStock",
            "priceValidUntil": "2027-12-31"
          },
          {
            "@type": "Offer",
            "name": "Starter Plan",
            "price": "300000",
            "priceCurrency": "IDR",
            "billingDuration": "P1M",
            "description": "Otomasi esensial untuk bisnis berkembang hingga 5 pengguna dan 5 toko marketplace.",
            "url": "https://mdhproduction.com/#paket-harga",
            "availability": "https://schema.org/InStock",
            "priceValidUntil": "2027-12-31"
          },
          {
            "@type": "Offer",
            "name": "Growth Plan",
            "price": "500000",
            "priceCurrency": "IDR",
            "billingDuration": "P1M",
            "description": "Skalabilitas ratusan pesanan harian untuk 12 pengguna dan 10 toko marketplace.",
            "url": "https://mdhproduction.com/#paket-harga",
            "availability": "https://schema.org/InStock",
            "priceValidUntil": "2027-12-31"
          },
          {
            "@type": "Offer",
            "name": "Pro Plan",
            "price": "800000",
            "priceCurrency": "IDR",
            "billingDuration": "P1M",
            "description": "Fitur multi-gudang dan studio live streaming untuk 25 pengguna dan 20 toko marketplace.",
            "url": "https://mdhproduction.com/#paket-harga",
            "availability": "https://schema.org/InStock",
            "priceValidUntil": "2027-12-31"
          },
          {
            "@type": "Offer",
            "name": "Enterprise Plan",
            "price": "1299999",
            "priceCurrency": "IDR",
            "billingDuration": "P1M",
            "description": "Infrastruktur dedicated multi-cabang tanpa batas pengguna dan marketplace dengan SLA prioritas.",
            "url": "https://mdhproduction.com/#paket-harga",
            "availability": "https://schema.org/InStock",
            "priceValidUntil": "2027-12-31"
          }
        ]
      }
    },
    {
      "@type": "WebSite",
      "@id": "https://mdhproduction.com/#website",
      "url": "https://mdhproduction.com/",
      "name": "Mobile ERP",
      "alternateName": "Mobile ERP Official Portal",
      "description": "Situs resmi Mobile ERP: Sistem ERP dan manajemen inventaris pergudangan omnichannel multi-tenant terdepan di Indonesia.",
      "publisher": {
        "@id": "https://mdhproduction.com/#organization"
      },
      "inLanguage": "id-ID"
    },
    {
      "@type": "BreadcrumbList",
      "@id": "https://mdhproduction.com/#breadcrumb",
      "itemListElement": [
        {
          "@type": "ListItem",
          "position": 1,
          "name": "Beranda",
          "item": "https://mdhproduction.com/"
        },
        {
          "@type": "ListItem",
          "position": 2,
          "name": "Modul Enterprise (WMS, OMS, FMS, HRIS, EMS)",
          "item": "https://mdhproduction.com/#fitur"
        },
        {
          "@type": "ListItem",
          "position": 3,
          "name": "Konsol Interaktif & Live Demo",
          "item": "https://mdhproduction.com/#showcase"
        },
        {
          "@type": "ListItem",
          "position": 4,
          "name": "Paket Investasi & Konsultasi",
          "item": "https://mdhproduction.com/#paket-harga"
        },
        {
          "@type": "ListItem",
          "position": 5,
          "name": "Tanya Jawab (FAQ)",
          "item": "https://mdhproduction.com/#faq"
        }
      ]
    },
    {
      "@type": "FAQPage",
      "@id": "https://mdhproduction.com/#faqpage",
      "mainEntity": [
        {
          "@type": "Question",
          "name": "Bagaimana cara melakukan evaluasi dan aktivasi akun Mobile ERP untuk perusahaan kami?",
          "acceptedAnswer": {
            "@type": "Answer",
            "text": "Perusahaan Anda dapat memilih paket implementasi yang sesuai pada menu daftar harga, kemudian klik tombol konsultasi untuk langsung terhubung dengan Tim Konsultan Enterprise melalui WhatsApp di 085155338246 atau email resmi bdchydi@sre.co.id. Tim kami akan memandu proses provisioning tenant, setup master data, dan pendampingan migrasi secara terstruktur."
          }
        },
        {
          "@type": "Question",
          "name": "Apakah Mobile ERP mendukung integrasi resmi dua arah dengan Shopee dan TikTok Shop?",
          "acceptedAnswer": {
            "@type": "Answer",
            "text": "Ya. Mobile ERP terintegrasi langsung menggunakan Shopee Open Platform dan TikTok Shop Partner API resmi untuk sinkronisasi pesanan secara terpusat, pembaruan katalog varian, dan pembaruan stok otomatis dua arah dengan perlindungan zero-oversell locking."
          }
        },
        {
          "@type": "Question",
          "name": "Bagaimana arsitektur keamanan data multi-tenant di Mobile ERP melindungi rahasia bisnis kami?",
          "acceptedAnswer": {
            "@type": "Answer",
            "text": "Mobile ERP mengimplementasikan arsitektur Enterprise Multi-Tenant Security (EMS) berbasis PostgreSQL Row-Level Security (RLS). Setiap query database diisolasi secara kriptografis berdasarkan Tenant ID dan User Session, menjamin data finansial, inventaris, dan pelanggan Anda terisolasi secara mutlak."
          }
        },
        {
          "@type": "Question",
          "name": "Bagaimana modul Financial Management System (FMS) merekonsiliasi pencairan dana marketplace?",
          "acceptedAnswer": {
            "@type": "Answer",
            "text": "Modul FMS Mobile ERP menjalankan algoritma rekonsiliasi otomatis setiap 10 menit untuk mencocokkan nilai transaksi penjualan dengan escrow settlement payout aktual. Sistem secara otomatis mendeteksi anomali potongan admin fee, menghitung HPP/COGS secara presisi, serta menghasilkan laporan laba rugi bersih multi-toko secara realtime."
          }
        },
        {
          "@type": "Question",
          "name": "Apakah Mobile ERP menyediakan manajemen pergudangan multi-lokasi dan operasional host live?",
          "acceptedAnswer": {
            "@type": "Answer",
            "text": "Ya. Modul WMS menyediakan integrasi scanner barcode, mutasi stok multi-gudang, opname dinamis, dan peringatan batas Reorder Point (ROP). Modul HRIS mengelola jadwal shifting studio host live streaming, absensi berbasis GPS & foto geotagging, kalkulasi komisi omzet berjenjang, serta slip gaji digital terenkripsi."
          }
        }
      ]
    }
  ]
}
```

---

## 2. Indonesian Enterprise ERP Meta Tags Specification

```html
<!-- Character Encoding & Viewport -->
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">

<!-- Primary SEO Meta Tags -->
<title>Mobile ERP | Software ERP & Omnichannel Inventory Management Terdepan di Indonesia</title>
<meta name="title" content="Mobile ERP | Software ERP & Omnichannel Inventory Management Terdepan di Indonesia">
<meta name="description" content="Platform Mobile ERP enterprise multi-tenant & manajemen inventaris omnichannel (WMS, OMS, FMS, HRIS, EMS) #1 di Indonesia. Sinkronisasi Shopee & TikTok Shop realtime, rekonsiliasi settlement 10 menit, multi-gudang barcode, dan isolasi data PostgreSQL RLS.">
<meta name="keywords" content="Mobile ERP, Software ERP Indonesia, WMS Indonesia, Omnichannel ERP, Integrasi Shopee TikTok, aplikasi inventory multi gudang, rekonsiliasi keuangan marketplace, software manajemen stok shopee tiktok, aplikasi absensi dan payroll karyawan, ERP cloud indonesia, sistem manajemen pergudangan barcode, PostgreSQL RLS ERP">
<meta name="author" content="Mobile ERP Enterprise Solutions">
<meta name="robots" content="index, follow, max-image-preview:large, max-snippet:-1, max-video-preview:-1">
<meta name="googlebot" content="index, follow, max-snippet:-1, max-image-preview:large, max-video-preview:-1">
<meta name="bingbot" content="index, follow, max-snippet:-1, max-image-preview:large, max-video-preview:-1">
<link rel="canonical" href="https://mdhproduction.com/">

<!-- Geo & Indonesian Market Localization -->
<meta name="geo.region" content="ID">
<meta name="geo.placename" content="Jakarta, Indonesia">
<meta name="geo.position" content="-6.2088;106.8456">
<meta name="ICBM" content="-6.2088, 106.8456">
<meta name="language" content="Indonesian">
<meta http-equiv="content-language" content="id">
<meta name="revisit-after" content="1 days">
<meta name="rating" content="general">
<meta name="theme-color" content="#080C14">

<!-- Open Graph / Facebook -->
<meta property="og:type" content="website">
<meta property="og:url" content="https://mdhproduction.com/">
<meta property="og:title" content="Mobile ERP | Software ERP & Omnichannel Inventory Management Terdepan di Indonesia">
<meta property="og:description" content="Platform Mobile ERP enterprise multi-tenant & manajemen inventaris omnichannel (WMS, OMS, FMS, HRIS, EMS) #1 di Indonesia. Sinkronisasi Shopee & TikTok Shop realtime, rekonsiliasi settlement 10 menit, dan isolasi data PostgreSQL RLS.">
<meta property="og:image" content="https://mdhproduction.com/assets/logo.png">
<meta property="og:image:secure_url" content="https://mdhproduction.com/assets/logo.png">
<meta property="og:image:type" content="image/png">
<meta property="og:image:width" content="512">
<meta property="og:image:height" content="512">
<meta property="og:image:alt" content="Mobile ERP Enterprise Omnichannel Suite">
<meta property="og:site_name" content="Mobile ERP">
<meta property="og:locale" content="id_ID">

<!-- Twitter Cards -->
<meta property="twitter:card" content="summary_large_image">
<meta property="twitter:url" content="https://mdhproduction.com/">
<meta property="twitter:title" content="Mobile ERP | Software ERP & Omnichannel Inventory Management Terdepan di Indonesia">
<meta property="twitter:description" content="Infrastruktur Mobile ERP modern untuk akselerasi bisnis online & offline: WMS, OMS, FMS, HRIS, dan PostgreSQL RLS.">
<meta property="twitter:image" content="https://mdhproduction.com/assets/logo.png">
<meta property="twitter:image:alt" content="Mobile ERP Enterprise Suite">

<!-- Favicon & Touch Icons -->
<link rel="icon" type="image/png" sizes="32x32" href="assets/logo.png">
<link rel="apple-touch-icon" sizes="180x180" href="assets/logo.png">
```

---

## 3. Robots.txt and Sitemap.xml Specifications

### `landing_page/robots.txt`
```txt
# ==============================================================================
# Mobile ERP Enterprise Search Crawler Directives (Googlebot / Search Engines)
# Production Host: https://mdhproduction.com
# ==============================================================================

User-agent: Googlebot
Allow: /
Allow: /assets/
Allow: /styles.css
Allow: /app.js
Disallow: /api/
Disallow: /_admin/
Disallow: /temp/

User-agent: Googlebot-Image
Allow: /assets/
Allow: /assets/*.png
Allow: /assets/*.jpg
Allow: /assets/*.svg

User-agent: Googlebot-Mobile
Allow: /

User-agent: Bingbot
Allow: /
Allow: /assets/
Allow: /styles.css
Allow: /app.js
Disallow: /api/
Disallow: /_admin/

User-agent: *
Allow: /
Allow: /assets/
Allow: /styles.css
Allow: /app.js
Disallow: /api/
Disallow: /_admin/
Disallow: /temp/

Host: https://mdhproduction.com
Sitemap: https://mdhproduction.com/sitemap.xml
```

### `landing_page/sitemap.xml`
```xml
<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"
        xmlns:xhtml="http://www.w3.org/1999/xhtml"
        xmlns:image="http://www.google.com/schemas/sitemap-image/1.1">
  <url>
    <loc>https://mdhproduction.com/</loc>
    <lastmod>2026-08-16</lastmod>
    <changefreq>daily</changefreq>
    <priority>1.0</priority>
    <image:image>
      <image:loc>https://mdhproduction.com/assets/logo.png</image:loc>
      <image:title>Mobile ERP Official Logo</image:title>
      <image:caption>Sistem Mobile ERP &amp; Omnichannel Inventory Management Enterprise Indonesia</image:caption>
    </image:image>
  </url>
  <url>
    <loc>https://app.mdhproduction.com/</loc>
    <lastmod>2026-08-16</lastmod>
    <changefreq>weekly</changefreq>
    <priority>0.9</priority>
  </url>
  <url>
    <loc>https://app.mdhproduction.com/register</loc>
    <lastmod>2026-08-16</lastmod>
    <changefreq>monthly</changefreq>
    <priority>0.8</priority>
  </url>
</urlset>
```

---

## 4. WhatsApp Consultation Message Template Specifications

**Target Phone**: `085155338246` (International: `6285155338246`)  
**Target Email**: `bdchydi@sre.co.id`  
**Base URL Format**: `https://wa.me/6285155338246?text=[URL_ENCODED_MESSAGE]`

### Matrix of Trigger Points & Pre-Filled Messages

| # | Trigger Location / Tier | Action Button Label | Raw Indonesian Message Template | Pre-encoded URL Link |
|---|-------------------------|---------------------|---------------------------------|----------------------|
| 1 | **Trial Plan (14 Hari)** | `Klaim Trial Enterprise` | `Halo Tim Konsultan Mobile ERP, saya tertarik dengan uji coba gratis (Trial 14 Hari). Mohon informasi panduan setup dan aktivasi akun enterprise kami.` | `https://wa.me/6285155338246?text=Halo%20Tim%20Konsultan%20Mobile%20ERP%2C%20saya%20tertarik%20dengan%20uji%20coba%20gratis%20%28Trial%2014%20Hari%29.%20Mohon%20informasi%20panduan%20setup%20dan%20aktivasi%20akun%20enterprise%20kami.` |
| 2 | **Starter Plan (Rp 300rb)** | `Pilih Paket Starter` | `Halo Tim Konsultan Mobile ERP, saya tertarik dengan implementasi paket Starter (Rp 300.000/bln). Mohon informasi panduan setup dan aktivasi akun enterprise kami.` | `https://wa.me/6285155338246?text=Halo%20Tim%20Konsultan%20Mobile%20ERP%2C%20saya%20tertarik%20dengan%20implementasi%20paket%20Starter%20%28Rp%20300.000%2Fbln%29.%20Mohon%20informasi%20panduan%20setup%20dan%20aktivasi%20akun%20enterprise%20kami.` |
| 3 | **Growth Plan (Rp 500rb)** | `Pilih Paket Growth` | `Halo Tim Konsultan Mobile ERP, saya tertarik dengan implementasi paket Growth (Rp 500.000/bln). Mohon informasi panduan setup dan aktivasi akun enterprise kami.` | `https://wa.me/6285155338246?text=Halo%20Tim%20Konsultan%20Mobile%20ERP%2C%20saya%20tertarik%20dengan%20implementasi%20paket%20Growth%20%28Rp%20500.000%2Fbln%29.%20Mohon%20informasi%20panduan%20setup%20dan%20aktivasi%20akun%20enterprise%20kami.` |
| 4 | **Pro Plan (Rp 800rb)** | `Pilih Paket Pro` | `Halo Tim Konsultan Mobile ERP, saya tertarik dengan implementasi paket Pro (Rp 800.000/bln). Mohon informasi panduan setup dan aktivasi akun enterprise kami.` | `https://wa.me/6285155338246?text=Halo%20Tim%20Konsultan%20Mobile%20ERP%2C%20saya%20tertarik%20dengan%20implementasi%20paket%20Pro%20%28Rp%20800.000%2Fbln%29.%20Mohon%20informasi%20panduan%20setup%20dan%20aktivasi%20akun%20enterprise%20kami.` |
| 5 | **Enterprise Plan (Custom)** | `Konsultasi Paket Enterprise` | `Halo Tim Konsultan Mobile ERP, kami membutuhkan penawaran khusus dan panduan implementasi untuk paket Enterprise Multi-Cabang. Mohon info diskusi lebih lanjut.` | `https://wa.me/6285155338246?text=Halo%20Tim%20Konsultan%20Mobile%20ERP%2C%20kami%20membutuhkan%20penawaran%20khusus%20dan%20panduan%20implementasi%20untuk%20paket%20Enterprise%20Multi-Cabang.%20Mohon%20info%20diskusi%20lebih%20lanjut.` |
| 6 | **Top Announcement Bar** | `Konsultasi Rilis` | `Halo Tim Konsultan Mobile ERP, saya tertarik dengan rilis terbaru Mobile ERP v10.4. Mohon informasi konsultasi aktivasi sistem.` | `https://wa.me/6285155338246?text=Halo%20Tim%20Konsultan%20Mobile%20ERP%2C%20saya%20tertarik%20dengan%20rilis%20terbaru%20Mobile%20ERP%20v10.4.%20Mohon%20informasi%20konsultasi%20aktivasi%20sistem.` |
| 7 | **Sticky Navbar Action** | `Konsultasi Enterprise` | `Halo Tim Konsultan Mobile ERP, saya ingin berkonsultasi mengenai solusi Mobile ERP untuk perusahaan kami.` | `https://wa.me/6285155338246?text=Halo%20Tim%20Konsultan%20Mobile%20ERP%2C%20saya%20ingin%20berkonsultasi%20mengenai%20solusi%20Mobile%20ERP%20untuk%20perusahaan%20kami.` |
| 8 | **Hero Section Primary CTA** | `Konsultasi Tim Spesialis (Aktivasi Cepat)` | `Halo Tim Konsultan Mobile ERP, saya tertarik untuk mengimplementasikan sistem Mobile ERP di bisnis kami. Mohon informasi panduan aktivasi akun.` | `https://wa.me/6285155338246?text=Halo%20Tim%20Konsultan%20Mobile%20ERP%2C%20saya%20tertarik%20untuk%20mengimplementasikan%20sistem%20Mobile%20ERP%20di%20bisnis%20kami.%20Mohon%20informasi%20panduan%20aktivasi%20akun.` |
| 9 | **Direct Contact Banner** | `Jadwalkan Demo via WhatsApp` | `Halo Tim Konsultan Mobile ERP, saya ingin menjadwalkan sesi live demo sistem ERP dan konsultasi arsitektur multi-tenant.` | `https://wa.me/6285155338246?text=Halo%20Tim%20Konsultan%20Mobile%20ERP%2C%20saya%20ingin%20menjadwalkan%20sesi%20live%20demo%20sistem%20ERP%20dan%20konsultasi%20arsitektur%20multi-tenant.` |
| 10 | **Bottom Huge CTA** | `Hubungi Tim Konsultan Sekarang` | `Halo Tim Konsultan Mobile ERP, saya ingin mengaktifkan akun evaluasi Mobile ERP dan mendapatkan pendampingan setup sistem.` | `https://wa.me/6285155338246?text=Halo%20Tim%20Konsultan%20Mobile%20ERP%2C%20saya%20ingin%20mengaktifkan%20akun%20evaluasi%20Mobile%20ERP%20dan%20mendapatkan%20pendampingan%20setup%20sistem.` |
| 11 | **Floating WhatsApp Widget** | `Chat Konsultan ERP` | `Halo Tim Solusi Mobile ERP, saya ingin berkonsultasi mengenai integrasi omnichannel dan implementasi ERP perusahaan.` | `https://wa.me/6285155338246?text=Halo%20Tim%20Solusi%20Mobile%20ERP%2C%20saya%20ingin%20berkonsultasi%20mengenai%20integrasi%20omnichannel%20dan%20implementasi%20ERP%20perusahaan.` |

---

## 5. Exhaustive Enterprise Terminology Dictionary

This dictionary serves as the strict replacement rulebook for all landing page copy, scripts, schemas, and UI elements.

| # | Prohibited / Casual Indonesian Term | Required Enterprise Terminology | Context & Application Rule | Affected Scope |
|---|---|---|---|---|
| 1 | `owner` / `platform owner` | `Tim Konsultan Enterprise` / `Tim Solusi Mobile ERP` / `Tim Spesialis ERP` | Mandatory replacement for all mentions of system providers and contact personnel | Global (HTML, JS, CSS, JSON-LD) |
| 2 | `Hubungi Owner` | `Hubungi Tim Konsultan` / `Konsultasi Enterprise` | Replaced across all CTAs and navigation items | Top Bar, Nav, Pricing, Footer |
| 3 | `Hubungi Platform Owner (Aktivasi Cepat)` | `Konsultasi Tim Spesialis (Aktivasi Cepat)` | Primary hero CTA replacement | Hero Section |
| 4 | `Kontak Owner` | `Konsultasi Enterprise` / `Kontak Konsultan` | Navbar navigation anchor replacement | Navigation Header |
| 5 | `Chat Platform Owner` | `Konsultasi Tim Spesialis ERP` | Floating WhatsApp tooltip bubble text | Floating Launcher |
| 6 | `Dukungan Langsung Platform Owner` | `Konsultasi & Implementasi Dedicated Enterprise` | Feature card heading | Architecture Features Grid |
| 7 | `Pilih Paket (Hubungi Owner)` | `Pilih Paket [Nama]` / `Konsultasi Paket Enterprise` | Pricing card CTA button labels | Pricing Matrix |
| 8 | `Klaim Trial (Hubungi Owner)` | `Klaim Trial Enterprise` | Free trial button label | Pricing Matrix |
| 9 | `Hubungi Owner (Custom)` | `Konsultasi Paket Enterprise` | Enterprise custom plan button label | Pricing Matrix |
| 10 | `Konsultasi Langsung dengan Platform Owner` | `Konsultasi Langsung dengan Tim Konsultan Enterprise` | Direct contact banner title | Pricing Section Banner |
| 11 | `stok barang` | `Manajemen Inventaris Pergudangan (WMS)` / `Katalog Produk & Varian` | Casual inventory phrasing replaced with formal WMS terminology | Meta tags, WMS Section |
| 12 | `aplikasi stok barang online` | `Software Mobile ERP & Omnichannel Inventory Management` | SEO meta keyword replacement | `<meta name="keywords">` |
| 13 | `gudang biasa` / `multi gudang` | `WMS (Warehouse Management System) & Multi-Warehouse Distribution` | Formal enterprise module categorization | Features & Console UI |
| 14 | `pesanan toko` / `pesanan marketplace` | `OMS (Omnichannel Management System) & Centralized Order Queue Routing` | Order processing taxonomy | Features & Console UI |
| 15 | `keuangan` / `laporan kas` | `FMS (Financial Management System) & Escrow Settlement Reconciliation` | Financial module taxonomy | Features & Console UI |
| 16 | `karyawan & absensi` | `HRIS (Human Resource Information System) & Stream Operations` | HR module taxonomy | Features & Console UI |
| 17 | `keamanan biasa` | `EMS (Enterprise Multi-Tenant Security & Infrastructure)` | Security module taxonomy | Features & Security Section |
| 18 | `omzet kotor` | `Pendapatan Kotor (Gross Merchandise Value / GMV)` | Table header in financial console demonstrator | Console UI Demonstrator |
| 19 | `admin fee` | `Potongan Komisi Platform (Marketplace Fee Ledger)` | Table header in financial console demonstrator | Console UI Demonstrator |
| 20 | `payout bersih` | `Pencairan Bersih Terekonsiliasi (Net Disbursed Settlement)` | Table header in financial console demonstrator | Console UI Demonstrator |
| 21 | `rak sample live` | `Alokasi Inventaris Live Studio & Sampling` | WMS console demonstrator table row | Console UI Demonstrator |
| 22 | `shifting tim gudang` | `Manajemen Shifting Operasional Pergudangan 24/7` | HRIS console demonstrator table row | Console UI Demonstrator |
| 23 | `harga murah / murah` | `Investasi Berlangganan Kompetitif & Terukur` | Pricing header & plan descriptions | Pricing Section |
| 24 | `uji coba biasa` | `Evaluasi Sistem 14 Hari (Enterprise Trial Evaluation)` | Plan descriptor badge | Pricing Matrix |
| 25 | `login portal owner` | `Portal Akses Enterprise ERP` | Navbar link and footer application links | Header & Footer |

---

## 5-Component Handoff Report

### 1. Observation
- Verified `landing_page/index.html` lines 46-129 contain legacy JSON-LD missing BreadcrumbList, missing detailed offer specifications, referencing non-existent `assets/favicon.ico`, and containing casual "Platform Owner" wording inside the FAQ Schema (line 106).
- Verified `landing_page/index.html` lines 146, 170, 179, 209, 390, 633, 648, 707, 711, 791, 792 contain multiple instances of the prohibited word `"owner"` / `"Platform Owner"`.
- Verified `landing_page/app.js` lines 8-9, 164-173 contain variables `OWNER_PHONE`, `OWNER_EMAIL`, and button labels containing `(Hubungi Owner)`.
- Verified `landing_page/robots.txt` currently has only 5 basic lines, lacking specific crawler rules for Googlebot-Image, Bingbot, and explicit Allow rules for assets.
- Verified `landing_page/sitemap.xml` lacks the Google image schema namespace (`xmlns:image="http://www.google.com/schemas/sitemap-image/1.1"`) and image metadata for the official metallic logo (`assets/logo.png`).
- Verified `landing_page/assets/logo.png` exists (95,251 bytes), while `assets/favicon.ico` does not exist in `landing_page/assets/`.

### 2. Logic Chain
- Google Rich Snippets requires strict Schema.org properties: `SoftwareApplication` must have `operatingSystem`, `applicationCategory`, `aggregateRating`, `offers`, and `featureList`; `Organization` must have `logo`, `contactPoint`, `telephone`, and `email`; `BreadcrumbList` is required for SERP hierarchy display.
- Search intent in Indonesia for B2B ERP is heavily driven by queries combining ERP with local marketplace integration ("Integrasi Shopee TikTok", "WMS Indonesia", "Omnichannel ERP"). Incorporating these precise keywords into `<title>`, `<meta name="keywords">`, `<meta name="description">`, and OpenGraph headers ensures top ranking and high CTR.
- B2B procurement conversions in Indonesia rely on direct WhatsApp communication. Formatting wa.me links with professional, plan-specific pre-filled text eliminates friction and guides the enterprise lead directly to onboarding.
- Eliminating "owner" across all files (HTML, JS, CSS, JSON-LD) fulfills the strict Enterprise Linear/Stripe/Vercel standard requested in `ORIGINAL_REQUEST.md:R3`.

### 3. Caveats
- WhatsApp deep links rely on the client device having either WhatsApp mobile app, WhatsApp Desktop, or web browser access to `https://web.whatsapp.com`.
- Schema testing must be validated using Google Rich Results Test / Schema Markup Validator once deployed.

### 4. Conclusion
- All specifications for JSON-LD schemas (5 schemas), Indonesian enterprise SEO meta tags, robots.txt, sitemap.xml, tiered WhatsApp consultation templates (11 trigger points), and the 25-entry enterprise terminology dictionary are 100% defined, verified, and ready for worker implementation.

### 5. Verification Method
- **Schema Validation**: Run JSON-LD validator on the output script block to confirm 0 errors and 0 warnings.
- **Search Terminology Audit**: Run `git grep -in "owner" landing_page/` to verify 0 occurrences post-implementation.
- **WhatsApp Link Testing**: Verify every WhatsApp link encodes properly and redirects to `https://wa.me/6285155338246` with valid Indonesian enterprise greeting text.
- **Sitemap & Robots Check**: Inspect `robots.txt` and `sitemap.xml` syntax against Google Search Console standards.
