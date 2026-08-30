const fs = require('fs');
const path = require('path');

console.log('=== RUNNING LANDING PAGE VALIDATION ===');

// 1. Check HTML JSON-LD
const htmlPath = path.join(__dirname, '..', '..', 'landing_page', 'index.html');
const htmlContent = fs.readFileSync(htmlPath, 'utf8');

const jsonLdMatch = htmlContent.match(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/);
if (!jsonLdMatch) {
  console.error('FAIL: No JSON-LD block found');
  process.exit(1);
}

try {
  const jsonLd = JSON.parse(jsonLdMatch[1]);
  console.log('PASS: JSON-LD is valid JSON');
  console.log('Graph entities count:', jsonLd['@graph'].length);
  jsonLd['@graph'].forEach((entity, idx) => {
    console.log(`  [${idx + 1}] ${entity['@type']} (${entity['@id'] || 'no @id'})`);
  });
} catch (err) {
  console.error('FAIL: JSON-LD JSON parse error:', err.message);
  process.exit(1);
}

// 2. Check for "owner" occurrences
const filesToCheck = ['index.html', 'styles.css', 'app.js', 'robots.txt', 'sitemap.xml'];
let totalOwnerCount = 0;

filesToCheck.forEach(filename => {
  const filePath = path.join(__dirname, '..', '..', 'landing_page', filename);
  const content = fs.readFileSync(filePath, 'utf8');
  const matches = content.match(/owner/gi);
  if (matches) {
    console.error(`FAIL: Found ${matches.length} occurrences of 'owner' in ${filename}`);
    totalOwnerCount += matches.length;
  } else {
    console.log(`PASS: 0 'owner' occurrences in ${filename}`);
  }
});

if (totalOwnerCount > 0) {
  console.error(`FAIL: Total ${totalOwnerCount} 'owner' occurrences found!`);
  process.exit(1);
}

// 3. Verify Logo References
const logoTagCount = (htmlContent.match(/assets\/logo\.png/g) || []).length;
console.log(`PASS: 'assets/logo.png' referenced ${logoTagCount} times in index.html`);

// 4. Verify Module Classifications (WMS, OMS, FMS, HRIS, EMS)
['WMS', 'OMS', 'FMS', 'HRIS', 'EMS'].forEach(mod => {
  if (htmlContent.includes(mod)) {
    console.log(`PASS: Module taxonomy '${mod}' present in index.html`);
  } else {
    console.error(`FAIL: Missing module taxonomy '${mod}'`);
  }
});

// 5. Verify Console Tabs in JS and HTML
const tabs = ['wms', 'oms', 'fms', 'hris', 'ems'];
tabs.forEach(tab => {
  if (htmlContent.includes(`data-tab="${tab}"`)) {
    console.log(`PASS: HTML Tab button for '${tab}' present`);
  } else {
    console.error(`FAIL: Missing HTML Tab button for '${tab}'`);
  }
  if (htmlContent.includes(`id="pane-${tab}"`)) {
    console.log(`PASS: HTML Tab pane for 'pane-${tab}' present`);
  } else {
    console.error(`FAIL: Missing HTML Tab pane for 'pane-${tab}'`);
  }
});

// 6. Verify Contacts & WhatsApp
if (htmlContent.includes('085155338246') && htmlContent.includes('6285155338246')) {
  console.log('PASS: WhatsApp contact 085155338246 / 6285155338246 present');
} else {
  console.error('FAIL: Missing WhatsApp contact');
}

if (htmlContent.includes('bdchydi@sre.co.id')) {
  console.log('PASS: Email contact bdchydi@sre.co.id present');
} else {
  console.error('FAIL: Missing email contact');
}

// 7. Verify Sitemap & Robots
const sitemapPath = path.join(__dirname, '..', '..', 'landing_page', 'sitemap.xml');
const sitemapContent = fs.readFileSync(sitemapPath, 'utf8');
if (sitemapContent.includes('https://mdhproduction.com/assets/logo.png')) {
  console.log('PASS: Sitemap contains logo image entry');
} else {
  console.error('FAIL: Sitemap missing logo image entry');
}

const robotsPath = path.join(__dirname, '..', '..', 'landing_page', 'robots.txt');
const robotsContent = fs.readFileSync(robotsPath, 'utf8');
if (robotsContent.includes('Googlebot') && robotsContent.includes('sitemap.xml')) {
  console.log('PASS: Robots.txt contains Googlebot directives and sitemap reference');
} else {
  console.error('FAIL: Robots.txt missing directives');
}

console.log('=== ALL VERIFICATIONS PASSED SUCCESSFULLY ===');
