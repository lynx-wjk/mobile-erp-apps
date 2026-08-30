/**
 * Mobile ERP - Enterprise SaaS Engine & Consultation Triggers
 * Enhanced with UI/UX Pro Max Interaction Polish
 * Production: https://mdhproduction.com
 */

const CONFIG = {
  SUPABASE_URL: 'https://mdhproduction.com',
  SUPABASE_ANON_KEY: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJyb2xlIjoiYW5vbiIsImlzcyI6InN1cGFiYXNlIiwiaWF0IjoxNzgxMzY1OTkwLCJleHAiOjQxMDI0NDQ4MDB9.4ksHkp45OfOVH--8p5ajWnfKUwwDDLUNYbsVV8uFh5Y',
  CONSULTANT_PHONE: '6285155338246',
  CONSULTANT_EMAIL: 'bdchydi@sre.co.id',
  APP_URL: 'https://app.mdhproduction.com'
};

document.addEventListener('DOMContentLoaded', () => {
  initYear();
  initMobileMenu();
  initConsoleTabs();
  initTabScrollNavigation();
  initScreenshotSwitchers();
  initAetherFlowBackground();
  initFaqAccordion();
  fetchLandingPageData();
});

function initYear() {
  const el = document.getElementById('current-year');
  if (el) el.textContent = new Date().getFullYear();
}

function initMobileMenu() {
  const toggleBtn = document.getElementById('mobile-menu-btn');
  const drawer = document.getElementById('mobile-nav-drawer');
  if (!toggleBtn || !drawer) return;

  function toggleMenu(forceState) {
    const isCurrentlyOpen = toggleBtn.classList.contains('active');
    const shouldOpen = typeof forceState === 'boolean' ? forceState : !isCurrentlyOpen;

    if (shouldOpen) {
      toggleBtn.classList.add('active');
      toggleBtn.setAttribute('aria-expanded', 'true');
      drawer.style.display = 'block';
      drawer.classList.add('open');
      drawer.setAttribute('aria-hidden', 'false');
    } else {
      toggleBtn.classList.remove('active');
      toggleBtn.setAttribute('aria-expanded', 'false');
      drawer.classList.remove('open');
      drawer.style.display = 'none';
      drawer.setAttribute('aria-hidden', 'true');
    }
  }

  toggleBtn.addEventListener('click', (e) => {
    e.stopPropagation();
    toggleMenu();
  });

  // Close when clicking any nav link inside mobile drawer
  drawer.querySelectorAll('a').forEach(link => {
    link.addEventListener('click', () => {
      toggleMenu(false);
    });
  });

  // Close on Escape key
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape' && drawer.classList.contains('open')) {
      toggleMenu(false);
    }
  });

  // Close when clicking outside header
  document.addEventListener('click', (e) => {
    const header = document.getElementById('main-nav');
    if (header && !header.contains(e.target) && drawer.classList.contains('open')) {
      toggleMenu(false);
    }
  });
}

function initConsoleTabs() {
  const tabs = document.querySelectorAll('.tab-btn');
  const panes = document.querySelectorAll('.tab-content');

  tabs.forEach(tab => {
    tab.addEventListener('click', () => {
      tabs.forEach(t => {
        t.classList.remove('active');
        t.setAttribute('aria-selected', 'false');
      });
      panes.forEach(p => {
        p.classList.remove('active');
      });

      tab.classList.add('active');
      tab.setAttribute('aria-selected', 'true');
      
      // Auto-scroll selected tab into view
      tab.scrollIntoView({ behavior: 'smooth', inline: 'nearest', block: 'nearest' });

      const targetId = `pane-${tab.dataset.tab}`;
      const targetPane = document.getElementById(targetId);
      if (targetPane) {
        targetPane.classList.add('active');
        
        // Micro-pop 3D animation for the active pane
        if (typeof gsap !== 'undefined') {
          gsap.fromTo(targetPane, 
            { opacity: 0, y: 12, scale: 0.98 }, 
            { opacity: 1, y: 0, scale: 1, duration: 0.35, ease: 'power2.out' }
          );
        }
      }
    });
  });
}

/**
 * Tab Bar Scroll Navigation & Mouse Wheel Support
 */
function initTabScrollNavigation() {
  const scrollContainer = document.getElementById('console-tab-scroll');
  const prevBtn = document.getElementById('tab-nav-prev');
  const nextBtn = document.getElementById('tab-nav-next');

  if (!scrollContainer) return;

  if (prevBtn) {
    prevBtn.addEventListener('click', () => {
      scrollContainer.scrollBy({ left: -220, behavior: 'smooth' });
    });
  }

  if (nextBtn) {
    nextBtn.addEventListener('click', () => {
      scrollContainer.scrollBy({ left: 220, behavior: 'smooth' });
    });
  }

  // Allow horizontal scroll with vertical mouse wheel on desktop
  scrollContainer.addEventListener('wheel', (e) => {
    if (Math.abs(e.deltaY) > Math.abs(e.deltaX)) {
      e.preventDefault();
      scrollContainer.scrollLeft += e.deltaY * 0.8;
    }
  }, { passive: false });
}

/**
 * Interactive Screenshot Switchers for All 6 Modules
 */
function initScreenshotSwitchers() {
  const chipContainers = document.querySelectorAll('.phone-feature-thumbnails');

  chipContainers.forEach(container => {
    const chips = container.querySelectorAll('.phone-thumb-chip');
    const parentPane = container.closest('.tab-content');
    if (!parentPane) return;
    
    const phoneImg = parentPane.querySelector('.phone-screen-img');
    if (!phoneImg) return;

    chips.forEach(chip => {
      chip.addEventListener('click', () => {
        const targetImgSrc = chip.getAttribute('data-img');
        if (!targetImgSrc || phoneImg.getAttribute('src') === targetImgSrc) return;

        // Update active chip state
        chips.forEach(c => c.classList.remove('active'));
        chip.classList.add('active');

        // Smooth image switch with micro crossfade
        phoneImg.classList.add('switching');
        
        const tempImg = new Image();
        tempImg.onload = () => {
          phoneImg.setAttribute('src', targetImgSrc);
          setTimeout(() => {
            phoneImg.classList.remove('switching');
          }, 60);
        };
        tempImg.onerror = () => {
          phoneImg.setAttribute('src', targetImgSrc);
          phoneImg.classList.remove('switching');
        };
        tempImg.src = targetImgSrc;
      });
    });
  });
}

/**
 * Aether Flow Interactive Particle Background
 * Features flowing light particles that weave and connect with dynamic cursor swirls and scroll responsiveness.
 * Inspired by 21st.dev Aether Flow Hero.
 */
function initAetherFlowBackground() {
  const canvas = document.getElementById('webgl-3d-bg');
  if (!canvas) return;
  const ctx = canvas.getContext('2d');
  if (!ctx) return;

  let width = (canvas.width = window.innerWidth);
  let height = (canvas.height = window.innerHeight);

  const particleCount = Math.min(Math.floor((width * height) / 11000), 160);
  const connectionDistance = 120;
  const particles = [];

  const mouse = {
    x: -1000,
    y: -1000,
    targetX: -1000,
    targetY: -1000,
    vx: 0,
    vy: 0,
    prevX: -1000,
    prevY: -1000,
    isHover: false
  };

  let scrollVelocity = 0;
  let lastScrollY = window.scrollY;

  const colorPalette = [
    { r: 56, g: 189, b: 248 },   // Sky Cyan (#38bdf8)
    { r: 96, g: 165, b: 250 },   // Electric Blue (#60a5fa)
    { r: 52, g: 211, b: 153 },   // Mint Emerald (#34d399)
    { r: 167, g: 139, b: 250 },  // Vibrant Violet (#a78bfa)
    { r: 6, g: 182, b: 212 }     // Pure Cyan (#06b6d4)
  ];

  class AetherParticle {
    constructor() {
      this.reset(true);
    }

    reset(initial = false) {
      this.x = initial ? Math.random() * width : (Math.random() > 0.5 ? -10 : width + 10);
      this.y = initial ? Math.random() * height : Math.random() * height;
      this.baseRadius = Math.random() * 1.8 + 1.2;
      this.radius = this.baseRadius;
      this.color = colorPalette[Math.floor(Math.random() * colorPalette.length)];
      this.alpha = Math.random() * 0.45 + 0.4;
      this.speed = Math.random() * 0.45 + 0.3;
      this.angle = Math.random() * Math.PI * 2;
      this.angleSpeed = (Math.random() - 0.5) * 0.012;
      this.vx = Math.cos(this.angle) * this.speed;
      this.vy = Math.sin(this.angle) * this.speed;
      this.phase = Math.random() * Math.PI * 2;
    }

    update(time) {
      // 1. Aether Harmonic Flow Field
      const curl1 = Math.sin(this.x * 0.0025 + time * 0.35 + this.phase);
      const curl2 = Math.cos(this.y * 0.0025 + time * 0.35 + this.phase);
      this.angle += (curl1 * curl2) * 0.045 + this.angleSpeed;

      this.vx = Math.cos(this.angle) * this.speed;
      this.vy = Math.sin(this.angle) * this.speed + scrollVelocity * 0.06;

      // 2. Interactive Mouse Swirl & Repulsion
      if (mouse.isHover) {
        const dx = mouse.x - this.x;
        const dy = mouse.y - this.y;
        const dist = Math.sqrt(dx * dx + dy * dy);
        const effectRadius = 190;

        if (dist < effectRadius && dist > 0) {
          const force = (1 - dist / effectRadius);
          
          // Tangential swirl vector (whirlpool eddy)
          const tangentX = -dy / dist;
          const tangentY = dx / dist;
          const swirlForce = 2.2 * force;
          this.vx += tangentX * swirlForce;
          this.vy += tangentY * swirlForce;

          // Soft repulsive bubble
          this.vx -= (dx / dist) * force * 1.0;
          this.vy -= (dy / dist) * force * 1.0;

          this.radius = this.baseRadius + force * 2.2;
        } else {
          this.radius += (this.baseRadius - this.radius) * 0.06;
        }
      } else {
        this.radius += (this.baseRadius - this.radius) * 0.06;
      }

      this.x += this.vx;
      this.y += this.vy;

      // Wrap around viewport boundaries seamlessly
      if (this.x < -25) this.x = width + 25;
      if (this.x > width + 25) this.x = -25;
      if (this.y < -25) this.y = height + 25;
      if (this.y > height + 25) this.y = -25;
    }

    draw() {
      ctx.save();
      ctx.beginPath();
      ctx.arc(this.x, this.y, this.radius, 0, Math.PI * 2);
      ctx.fillStyle = `rgba(${this.color.r}, ${this.color.g}, ${this.color.b}, ${this.alpha})`;
      ctx.shadowColor = `rgba(${this.color.r}, ${this.color.g}, ${this.color.b}, 0.85)`;
      ctx.shadowBlur = 12;
      ctx.fill();
      ctx.restore();
    }
  }

  for (let i = 0; i < particleCount; i++) {
    particles.push(new AetherParticle());
  }

  // Draw connecting luminous woven threads
  function drawConnectingThreads() {
    for (let i = 0; i < particles.length; i++) {
      for (let j = i + 1; j < particles.length; j++) {
        const p1 = particles[i];
        const p2 = particles[j];
        const dx = p1.x - p2.x;
        const dy = p1.y - p2.y;
        const dist = Math.sqrt(dx * dx + dy * dy);

        if (dist < connectionDistance) {
          const alpha = (1 - dist / connectionDistance) * 0.22;
          ctx.beginPath();
          ctx.moveTo(p1.x, p1.y);
          ctx.lineTo(p2.x, p2.y);
          ctx.strokeStyle = `rgba(${p1.color.r}, ${p1.color.g}, ${p1.color.b}, ${alpha})`;
          ctx.lineWidth = 0.9;
          ctx.stroke();
        }
      }
    }
  }

  // Event Listeners for Cursor Dynamics
  window.addEventListener('mousemove', (e) => {
    mouse.targetX = e.clientX;
    mouse.targetY = e.clientY;
    mouse.isHover = true;
  }, { passive: true });

  window.addEventListener('mouseleave', () => {
    mouse.isHover = false;
    mouse.targetX = -1000;
    mouse.targetY = -1000;
  });

  window.addEventListener('scroll', () => {
    const currentScrollY = window.scrollY;
    scrollVelocity = (currentScrollY - lastScrollY) * 0.15;
    lastScrollY = currentScrollY;
  }, { passive: true });

  window.addEventListener('resize', () => {
    width = canvas.width = window.innerWidth;
    height = canvas.height = window.innerHeight;
  }, { passive: true });

  let time = 0;
  function animate() {
    requestAnimationFrame(animate);
    time += 0.015;

    // Smooth cursor interpolation
    if (mouse.isHover) {
      if (mouse.x === -1000) {
        mouse.x = mouse.targetX;
        mouse.y = mouse.targetY;
      } else {
        mouse.x += (mouse.targetX - mouse.x) * 0.2;
        mouse.y += (mouse.targetY - mouse.y) * 0.2;
      }
    } else {
      mouse.x = -1000;
      mouse.y = -1000;
    }

    // Decay scroll impulse
    scrollVelocity *= 0.92;

    ctx.clearRect(0, 0, width, height);

    drawConnectingThreads();

    for (let i = 0; i < particles.length; i++) {
      particles[i].update(time);
      particles[i].draw();
    }
  }
  animate();
}

function initFaqAccordion() {
  const container = document.getElementById('faq-accordion');
  if (!container) return;

  container.addEventListener('click', (e) => {
    const trigger = e.target.closest('.faq-btn-trigger');
    if (!trigger) return;

    const currentCard = trigger.closest('.faq-card-item');
    const isOpen = currentCard.classList.contains('open');

    document.querySelectorAll('.faq-card-item').forEach(c => c.classList.remove('open'));

    if (!isOpen) {
      currentCard.classList.add('open');
    }
  });
}

async function fetchLandingPageData() {
  try {
    const res = await fetch(`${CONFIG.SUPABASE_URL}/rest/v1/rpc/get_public_landing_page_data`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'apikey': CONFIG.SUPABASE_ANON_KEY,
        'Authorization': `Bearer ${CONFIG.SUPABASE_ANON_KEY}`
      },
      body: JSON.stringify({})
    });

    if (!res.ok) throw new Error(`HTTP error ${res.status}`);

    const data = await res.json();
    if (data && data.ok) {
      if (data.cms) applyCmsData(data.cms);
      if (data.plans && Array.isArray(data.plans) && data.plans.length > 0) {
        renderPricingPlans(data.plans);
      } else {
        renderFallbackPlans();
      }
    } else {
      renderFallbackPlans();
    }
  } catch (err) {
    console.warn('[CMS_FETCH_OFFLINE] Using verified enterprise dataset:', err);
    renderFallbackPlans();
  }
}

function formatRupiah(amount) {
  const num = Number(amount) || 0;
  if (num === 0) return 'Gratis (Trial 14 Hari)';
  return 'Rp ' + num.toLocaleString('id-ID');
}

function applyCmsData(cms) {
  // Testimonials
  if (cms.testimonials && Array.isArray(cms.testimonials.items)) {
    const grid = document.getElementById('testimonials-grid');
    if (grid) {
      grid.innerHTML = cms.testimonials.items.map(item => {
        const monogram = (item.name || 'ERP')
          .split(' ')
          .map(n => n[0])
          .slice(0, 2)
          .join('')
          .toUpperCase();

        return `
          <div class="testimonial-card-item">
            <div class="testi-stars-row">
              <span class="material-symbols-outlined icon-xs">star</span>
              <span class="material-symbols-outlined icon-xs">star</span>
              <span class="material-symbols-outlined icon-xs">star</span>
              <span class="material-symbols-outlined icon-xs">star</span>
              <span class="material-symbols-outlined icon-xs">star</span>
            </div>
            <p class="testi-quote-txt">"${escapeHtml(item.quote)}"</p>
            <div class="testi-author-block">
              <div class="author-monogram-circle">${monogram}</div>
              <div class="author-info-box">
                <h4>${escapeHtml(item.name)}</h4>
                <span>${escapeHtml(item.role)}</span>
              </div>
            </div>
          </div>
        `;
      }).join('');
    }
  }

  // FAQ
  if (cms.faq && Array.isArray(cms.faq.items)) {
    const acc = document.getElementById('faq-accordion');
    if (acc) {
      acc.innerHTML = cms.faq.items.map((item, idx) => `
        <div class="faq-card faq-card-item ${idx === 0 ? 'open' : ''}">
          <button class="faq-btn-trigger">
            <span>${escapeHtml(item.question)}</span>
            <span class="material-symbols-outlined faq-icon-arrow icon-sm">expand_more</span>
          </button>
          <div class="faq-body-panel">
            <p>${escapeHtml(item.answer)}</p>
          </div>
        </div>
      `).join('');
    }
  }
}

// Standardized Indonesian Enterprise WhatsApp Inquiry Templates per tier
const PLAN_INQUIRY_TEMPLATES = {
  trial: "Halo Tim Konsultan Mobile ERP, saya tertarik dengan uji coba gratis (Trial 14 Hari). Mohon informasi panduan setup dan aktivasi akun bisnis kami.",
  starter: "Halo Tim Konsultan Mobile ERP, saya tertarik dengan paket Starter (Rp 300.000/bln). Mohon informasi panduan setup dan aktivasi akun bisnis kami.",
  growth: "Halo Tim Konsultan Mobile ERP, saya tertarik dengan paket Growth (Rp 500.000/bln). Mohon informasi panduan setup dan aktivasi akun bisnis kami.",
  pro: "Halo Tim Konsultan Mobile ERP, saya tertarik dengan paket Pro (Rp 800.000/bln). Mohon informasi panduan setup dan aktivasi akun bisnis kami.",
  enterprise: "Halo Tim Konsultan Mobile ERP, kami membutuhkan penawaran khusus dan demo sistem untuk paket Enterprise Multi-Cabang. Mohon info diskusi lebih lanjut."
};

function getPlanWhatsAppMessage(plan) {
  const code = (plan.plan_code || '').toLowerCase();
  if (PLAN_INQUIRY_TEMPLATES[code]) {
    return PLAN_INQUIRY_TEMPLATES[code];
  }
  if (plan.is_trial || code.includes('trial')) {
    return PLAN_INQUIRY_TEMPLATES.trial;
  }
  if (code.includes('enterprise')) {
    return PLAN_INQUIRY_TEMPLATES.enterprise;
  }
  return `Halo Tim Konsultan Mobile ERP, saya tertarik dengan paket ${plan.plan_name || 'Enterprise'}. Mohon informasi panduan setup dan aktivasi akun bisnis kami.`;
}

function renderPricingPlans(plans) {
  const container = document.getElementById('pricing-grid');
  if (!container) return;

  if (!plans || plans.length === 0) {
    renderFallbackPlans();
    return;
  }

  container.innerHTML = plans.map(plan => {
    const isPopular = plan.plan_code === 'pro' || plan.plan_code === 'growth';
    const isEnterprise = plan.plan_code === 'enterprise';
    const isTrial = plan.is_trial || plan.plan_code === 'trial';

    const priceFormatted = formatRupiah(plan.price_amount);
    const periodText = isTrial ? '14 Hari Coba Gratis' : (plan.billing_period === 'yearly' ? '/ Tahun' : '/ Bulan');

    // Standardized Indonesian Enterprise WhatsApp Inquiry Message
    const waMsg = getPlanWhatsAppMessage(plan);
    const waLink = `https://wa.me/${CONFIG.CONSULTANT_PHONE}?text=${encodeURIComponent(waMsg)}`;
    
    let actionLabel = `Pilih Paket ${escapeHtml(plan.plan_name)}`;
    if (isTrial) {
      actionLabel = 'Coba Gratis 14 Hari';
    } else if (isEnterprise) {
      actionLabel = 'Konsultasi Paket Khusus';
    }

    const btnClass = isPopular ? 'primary' : 'outline';

    // Specifications
    const specs = [];
    specs.push(plan.max_users ? `Kapasitas <strong>${plan.max_users} Karyawan / Staf</strong>` : `Kapasitas <strong>Karyawan Tanpa Batas</strong>`);
    specs.push(plan.max_marketplace_accounts ? `Hingga <strong>${plan.max_marketplace_accounts} Toko Marketplace</strong>` : `Koneksi Toko <strong>Banyak Cabang Tanpa Batas</strong>`);
    
    if (plan.max_storage_mb) {
      const gb = (plan.max_storage_mb / 1024).toFixed(0);
      specs.push(`Penyimpanan Data <strong>${gb > 0 ? gb + ' GB Cloud Aman' : plan.max_storage_mb + ' MB'}</strong>`);
    }

    if (plan.max_order_retention_days) {
      specs.push(`Riwayat Transaksi <strong>${plan.max_order_retention_days} Hari</strong>`);
    }

    if (Array.isArray(plan.features) && plan.features.length > 0) {
      plan.features.slice(0, 4).forEach(f => {
        specs.push(escapeHtml(f.feature_name));
      });
    }

    return `
      <div class="pricing-plan-item ${isPopular ? 'popular' : ''}">
        ${isPopular ? `<div class="popular-ribbon">Paling Diminati</div>` : ''}
        <div>
          <div class="plan-head-block">
            <h3 class="plan-name-txt">${escapeHtml(plan.plan_name)}</h3>
            <p class="plan-desc-txt">${escapeHtml(plan.description || 'Solusi praktis untuk mengotomasi operasional bisnis Anda.')}</p>
            <div class="plan-price-block">
              <span class="price-main-val">${priceFormatted}</span>
              <span class="price-period-val">${periodText}</span>
            </div>
          </div>

          <ul class="plan-features-list">
            ${specs.map(s => `
              <li>
                <span class="material-symbols-outlined icon-xs">check_circle</span>
                <span>${s}</span>
              </li>
            `).join('')}
          </ul>
        </div>

        <a href="${waLink}" target="_blank" rel="noopener noreferrer" class="btn-plan-action ${btnClass}">
          <span class="material-symbols-outlined icon-sm">chat</span>
          <span>${actionLabel}</span>
        </a>
      </div>
    `;
  }).join('');
}

function renderFallbackPlans() {
  const fallback = [
    {
      plan_code: 'trial',
      plan_name: 'Paket Trial',
      description: 'Coba gratis seluruh fitur selama 14 hari tanpa biaya dan tanpa komitmen.',
      price_amount: 0,
      is_trial: true,
      max_users: 3,
      max_marketplace_accounts: 2,
      max_storage_mb: 1024,
      max_order_retention_days: 30,
      features: [
        { feature_name: 'Scan Barcode Kamera HP & Stok Gudang' },
        { feature_name: 'Sinkronisasi Otomatis Shopee & TikTok' },
        { feature_name: 'Pencatatan Keuangan & Uang Cair Dasar' },
        { feature_name: 'Penyimpanan Data Aman & Privat' }
      ]
    },
    {
      plan_code: 'starter',
      plan_name: 'Paket Starter',
      description: 'Pilihan tepat untuk bisnis berkembang dengan hingga 5 toko online.',
      price_amount: 300000,
      billing_period: 'monthly',
      max_users: 5,
      max_marketplace_accounts: 5,
      max_storage_mb: 5120,
      max_order_retention_days: 90,
      features: [
        { feature_name: 'Scan Barcode & Pindah Barang Antar Rak' },
        { feature_name: 'Otomatisasi Pesanan Toko Online' },
        { feature_name: 'Cek Uang Cair Otomatis Tiap 10 Menit' },
        { feature_name: 'Absensi Karyawan GPS & Slip Gaji' }
      ]
    },
    {
      plan_code: 'growth',
      plan_name: 'Paket Growth',
      description: 'Cocok untuk toko dengan ratusan orderan per hari di berbagai marketplace.',
      price_amount: 500000,
      billing_period: 'monthly',
      max_users: 12,
      max_marketplace_accounts: 10,
      max_storage_mb: 15360,
      max_order_retention_days: 180,
      features: [
        { feature_name: 'Stock Opname Cepat & Notifikasi Menipis' },
        { feature_name: 'Cegah Dobel Jual (Anti-Oversell)' },
        { feature_name: 'Laporan Laba Bersih & Hitung Modal HPP' },
        { feature_name: 'Atur Jadwal Host Siaran Live' }
      ]
    },
    {
      plan_code: 'pro',
      plan_name: 'Paket Pro',
      description: 'Solusi lengkap untuk multi-gudang, studio live streaming, dan tim besar.',
      price_amount: 800000,
      billing_period: 'monthly',
      max_users: 25,
      max_marketplace_accounts: 20,
      max_storage_mb: 51200,
      max_order_retention_days: 365,
      features: [
        { feature_name: 'Kontrol Multi-Gudang & Cabang Toko' },
        { feature_name: 'Sinkronisasi Cepat Volume Order Besar' },
        { feature_name: 'Audit Potongan Biaya Admin Toko' },
        { feature_name: 'Hitung Komisi Host & Slip Gaji Digital' }
      ]
    },
    {
      plan_code: 'enterprise',
      plan_name: 'Paket Enterprise',
      description: 'Layanan khusus untuk perusahaan dengan banyak cabang dan kebutuhan spesifik.',
      price_amount: 1299999,
      billing_period: 'monthly',
      max_users: null,
      max_marketplace_accounts: null,
      max_storage_mb: 204800,
      max_order_retention_days: 730,
      features: [
        { feature_name: 'Server Dedicated Khusus Perusahaan' },
        { feature_name: 'Akses Data Super Cepat Tanpa Batas' },
        { feature_name: 'Kustomisasi Fitur Sesuai Alur Bisnis' },
        { feature_name: 'Pendampingan Prioritas 24/7 Langsung' }
      ]
    }
  ];
  renderPricingPlans(fallback);
}

function escapeHtml(str) {
  if (!str) return '';
  return String(str)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#039;');
}
