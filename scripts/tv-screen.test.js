// SPDX-License-Identifier: AGPL-3.0-only
// Gerçek Chromium yerleşimiyle TV ekran çevirisi. node --test scripts/tv-screen.test.js
// Tarayıcı yolu: COUCHSUBS_TEST_BROWSER; bağımlılık/model indirme ve canlı TV bağlantısı yok.
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { pathToFileURL } = require('node:url');
const root = path.join(__dirname, '..', 'tv-webos');
const browser = [process.env.COUCHSUBS_TEST_BROWSER, process.env.CHROME_BIN,
  'C:/Program Files/Google/Chrome/Application/chrome.exe',
  'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
  '/usr/bin/google-chrome', '/usr/bin/chromium', '/usr/bin/chromium-browser',
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'].find(p => p && fs.existsSync(p));
const item = (text, left, top, right, bottom, line = .03) => ({ text, box: { left, top, right, bottom }, line });
// 1×1 PNG.
const PNG = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';
const upper = item('Bu bölgedeki bütün gizli belgeleri bul ve güvenli bölgeye geri dön.', .10, .20, .28, .23);
const lower = item('Görevler', .10, .26, .28, .28, .02);
const scenarios = {
  neighbours: [upper, lower],
  tight: [upper, item('Görevler', .10, .24, .28, .26, .02)],
  reversed: [lower, upper],
  isolated: [item('Kaydet', .10, .20, .28, .23)],
  columns: [item('Kaydet', .10, .20, .28, .23), item('Seçenekler', .70, .21, .90, .24)],
  edge: [item('Gizli belgeleri bul ve güvenli bölgeye geri dön.', .1, .945, .28, .975)],
  paragraph: [Object.assign(item('Bu görevde önce köprüyü geçmeli, ardından köyün kuzeyindeki güvenli bölgeye ulaşmalısın.\nYanındaki belgeleri muhafıza teslim et.', .1, .1, .45, .4), {paragraphs:true}),
    item('Harita', .1, .5, .3, .53)],
  dense: [item('Bütün belgeleri güvenli bölgeye götür. '.repeat(30), .1, .2, .2, .23),
    item('Görevler', .1, .24, .2, .26, .02)],
  invalid: [null, {text:'Geçersiz',box:{left:.2,top:.2,right:.1,bottom:.3}},
    item('', .1, .23, .28, .24), item('Kaydet', .1, .2, .28, .23)],
  // Çevirinin içindeki kumanda simgesi (bilgisayar oyun karesinden keser); resim olmayan adres yok sayılır.
  icons: [Object.assign(item('Koşmak için basılı tutun.', .1, .2, .28, .23), {icons: [{at: 12, src: PNG}]}),
    Object.assign(item('Kaydet', .1, .5, .28, .53), {icons: [{at: 0, src: 'javascript:alert(1)'}]})],
};
// Ek alanda ayrı duran iki yazı grubu (sağ üstte görev başlığı, altında sola kaymış ayrı hedef satırı).
const regionBlocks = [item('Demirciyi bul ve kılıcını onarmasını iste', .72, .05, .95, .08),
  item('Ahıra git', .62, .12, .70, .15)];

function render(width, height) {
  const app = fs.readFileSync(path.join(root, 'app.js'), 'utf8');
  const start = app.indexOf('  var screenTimer = null;');
  const end = app.indexOf('\n  //', app.indexOf('  function hideScreen()', start));
  const regionStart = app.indexOf('  var regionBoxes = {};');
  const regionEnd = app.indexOf('\n  //', app.indexOf('  function hideRegions()', regionStart));
  const validStart = app.indexOf('  function validBox(box)');
  const validEnd = app.indexOf('\n  //', validStart);
  assert.ok(start > 0 && end > start && validStart > 0 && validEnd > validStart && regionStart > 0 && regionEnd > regionStart,
    'TV işlevleri bulunamadı');
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'couchsubs-screen-test-'));
  try {
    const html = `<!doctype html><meta charset="utf-8"><style>${fs.readFileSync(path.join(root, 'style.css'), 'utf8')}</style>
      <div id="regions" class="hidden"></div><div id="screen"></div><pre id="result"></pre><script>
      function $(id) { return document.getElementById(id); }
      var hidden = []; function hideSubtitle(reason) { hidden.push(reason); }
      ${app.slice(validStart, validEnd)}
      ${app.slice(start, end)}
      ${app.slice(regionStart, regionEnd)}
      var result = {};
      function measure(el) {
        var b = el.getBoundingClientRect();
        return {text: el.textContent, left:b.left, right:b.right, top:b.top, bottom:b.bottom,
          width:b.width, height:b.height, font:parseFloat(getComputedStyle(el).fontSize),
          clientHeight:el.clientHeight, scrollHeight:el.scrollHeight, align:getComputedStyle(el).textAlign,
          position:getComputedStyle(el).position, background:getComputedStyle(el).backgroundColor,
          color:getComputedStyle(el).color};
      }
      var regionBlocks = ${JSON.stringify(regionBlocks)};
      showRegion({id:'q', text:'Demirciyi bul\\nAhıra git', box:{left:.62, top:.05, right:.95, bottom:.15}, blocks:regionBlocks});
      result.regionKind = $('regions').children[0].className;
      result.regionBlocks = Array.from($('regions').children[0].children).map(measure);
      showRegion({id:'q', text:'Ahıra git', box:regionBlocks[1].box});
      result.regionSingle = Array.from($('regions').children).map(function(el) { return el.className; });
      function regionSample(sample) {
        showRegion(sample);
        return measure($('regions').children[0]);
      }
      result.shortPhone = regionSample({id:'q', text:'Tamam.', line:.023, box:{left:.71, top:.72, right:.98, bottom:.82}});
      result.longPhone = regionSample({id:'q', text:'Kuzey yolundaki eski istasyondan gelen son mesajı kontrol et ve hemen eve dön. '.repeat(3),
        line:.04, box:{left:.71,top:.77,right:.98,bottom:.88}});
      result.help = regionSample({id:'q', text:'Görev listesini açmak için basılı tut', line:.04,
        box:{left:.02,top:.07,right:.14,bottom:.11}});
      showRegion({id:'q', text:'Köşe', box:{left:.98,right:.999,top:.13,bottom:.16},
        blocks:[{text:'Görev',box:{left:.81,right:.967,top:.13,bottom:.16},line:.025},
          {text:'Köşe',box:{left:.98,right:.999,top:.13,bottom:.16},line:.025}]});
      result.edgeNeighbours = Array.from($('regions').children[0].children).map(measure);
      result.fullWidthRegion = regionSample({id:'q', text:'Devam', box:{left:0,top:.05,right:1,bottom:.09}});
      result.denseHelp = regionSample({id:'q', text:'İşaretli güzergâhtaki en eski binanın ön kapısına kadar ilerle. '.repeat(12),
        line:.03, box:{left:.04,top:.08,right:.18,bottom:.11}});
      showRegion({id:'q', text:'Ahıra git', box:regionBlocks[1].box});
      var phoneBox = {left:.43,top:.42,right:.52,bottom:.45};
      var reply = {text:'Yanıt', box:phoneBox, line:.025, surface:{background:'#2575a4',foreground:'#ffffff'}};
      var next = {text:'Git', box:{left:.49,top:.52,right:.52,bottom:.55}, line:.025,
        surface:{background:['#ff0000'],foreground:'#ffffff'}};
      showRegion({id:'game-phone', text:'Yanıt / Git', box:phoneBox, blocks:[reply,next]});
      result.phone = Array.from($('regions').querySelectorAll('.phone')).map(measure);
      showRegion({id:'game-phone', text:''});
      result.afterPhone = $('regions').textContent;
      showRegion({id:'q', text:'Yanıt', box:phoneBox, blocks:[reply]});
      result.normalColor = getComputedStyle($('regions').querySelector('.item')).backgroundColor;
      // Otomatik bulunan ekran yazısı özgün görünüşüyle: açık zemin + koyu kalın dar yazı, sağa yaslı; düz olmayan zemin %85.
      showRegion({id:'auto-1', text:"VİCKİ'NİN PATRONUNU SOY", box:{left:.05,top:.1,right:.25,bottom:.14}, blocks:[
        {text:"VİCKİ'NİN PATRONUNU SOY", box:{left:.05,top:.1,right:.25,bottom:.13}, line:.03,
          surface:{background:'#f0f0f0', foreground:'#101010', flat:true}, style:{bold:true, condensed:true, align:'right', upper:true}},
        {text:"Vicki patronunu soyup parayı paylaşmak istiyor. Onunla Delights'ta buluş.", box:{left:.05,top:.135,right:.25,bottom:.16}, line:.02,
          surface:{background:'#1a1c20', foreground:'#ffffff', flat:false}, style:{bold:false, condensed:false, align:'left', upper:false}}]});
      result.styled = Array.from($('regions').querySelectorAll('.item')).slice(-2).map(function (el) {
        var cs = getComputedStyle(el), b = el.getBoundingClientRect();
        return {background:cs.backgroundColor, color:cs.color, weight:cs.fontWeight, align:cs.textAlign,
          family:cs.fontFamily, width:b.width, font:parseFloat(cs.fontSize)};
      });
      var scenarios = ${JSON.stringify(scenarios)};
      for (var key in scenarios) {
        showScreen(scenarios[key], 10000);
        result[key] = Array.from($('screen').children).map(function(el) {
          var b = el.getBoundingClientRect();
          return {text: el.textContent, left:b.left, right:b.right, top:b.top, bottom:b.bottom,
            width:b.width, height:b.height, font:parseFloat(getComputedStyle(el).fontSize),
            clientHeight:el.clientHeight, scrollHeight:el.scrollHeight, align:getComputedStyle(el).textAlign,
            images:el.querySelectorAll('img.icon').length,
            lead:el.firstChild && el.firstChild.nodeType === 3 ? el.firstChild.textContent : ''};
        });
      }
      hideScreen(); result.hidden = $('screen').className; result.count = $('screen').children.length;
      result.viewport = {width:innerWidth,height:innerHeight}; result.hideReasons = hidden;
      $('result').textContent = btoa(unescape(encodeURIComponent(JSON.stringify(result))));
      </script>`;
    // Pencere çerçevesi/işletim sistemi ölçeği yerine tam hedef çözünürlükte bir iframe.
    const encoded = Buffer.from(html, 'utf8').toString('base64');
    const page = `<!doctype html><iframe id="frame" style="border:0;width:${width}px;height:${height}px"></iframe>
      <pre id="result"></pre><script>
      var frame = document.getElementById('frame');
      frame.contentDocument.open();
      frame.contentDocument.write(decodeURIComponent(escape(atob('${encoded}'))));
      frame.contentDocument.close();
      document.getElementById('result').textContent = frame.contentDocument.getElementById('result').textContent;
      </script>`;
    const file = path.join(temp, 'test.html'); fs.writeFileSync(file, page);
    const run = spawnSync(browser, ['--headless=new', '--disable-gpu', '--disable-background-networking',
      '--no-first-run', '--no-default-browser-check', '--hide-scrollbars', '--force-device-scale-factor=1', '--window-size=' + width + ',' + height,
      ...(process.platform === 'linux' ? ['--no-sandbox'] : []),
      '--user-data-dir=' + path.join(temp, 'profile'), '--dump-dom', pathToFileURL(file).href],
      { encoding:'utf8', timeout:30000, maxBuffer:2*1024*1024, windowsHide:true });
    assert.equal(run.status, 0, String(run.error || run.stderr));
    const match = run.stdout.match(/<pre id="result">([A-Za-z0-9+/=]+)<\/pre>/);
    assert.ok(match, 'Tarayıcı ölçüm üretmedi: ' + run.stdout.slice(-1000));
    return JSON.parse(Buffer.from(match[1], 'base64').toString('utf8'));
  } finally {
    // Yalnız bu testin sistem geçici dizininde oluşturduğu klasör.
    assert.equal(path.dirname(temp), path.resolve(os.tmpdir()));
    fs.rmSync(temp, {recursive:true, force:true, maxRetries:5, retryDelay:200});
  }
}

if (process.env.CI) assert.ok(browser, 'CI: gerçek yerleşim testi için Chrome/Edge gerekli');
// 2580×1080: Samsung ultrawide (3440x1440) yüzeyinde platform.js'in verdiği görünüm (#304).
for (const [width, height] of [[1280,720], [1920,1080], [3840,2160], [2580,1080]]) {
test('TV ekran çevirisi: ' + width + '×' + height, {skip: !browser && 'Chrome/Edge bulunamadı'}, async t => {
  const r = render(width, height);
  assert.deepEqual(r.viewport, {width, height});
  await t.test('uzun üst etiket alttaki bağımsız etiketi kapatmaz', () => {
    assert.ok(r.neighbours[0].bottom <= r.neighbours[1].top, JSON.stringify(r.neighbours));
    assert.equal(r.neighbours[0].text, upper.text);
    assert.ok(r.neighbours[0].scrollHeight <= r.neighbours[0].clientHeight + 1);
  });
  await t.test('çok dar aralıkta okunabilirlik alt sınırı korunur', () => {
    // 720p'de iki satır 14 px ile bu aralığa fiziksel olarak sığmaz.
    // Böyle bir durumda metni kesmek/gizlemek yerine mevcut doğal büyüme kalır.
    if (width >= 1920) assert.ok(r.tight[0].bottom <= r.tight[1].top);
    else assert.equal(r.tight[0].font, 14);
    assert.equal(r.tight[0].text, upper.text);
    assert.ok(r.tight[0].scrollHeight <= r.tight[0].clientHeight + 1);
  });
  await t.test('veri sırası sonucu değiştirmez', () => {
    assert.deepEqual(r.reversed, [...r.neighbours].reverse());
  });
  await t.test('kısa etiket ve ayrı sütunların yerleşimi aynı kalır', () => {
    assert.deepEqual(r.isolated[0], r.columns[0]);
    assert.equal(r.isolated[0].font, Math.max(14, Math.min(96, Math.round(.03 * r.viewport.height * .95))));
    assert.ok(Math.abs(r.isolated[0].left - .096*r.viewport.width) < 1);
  });
  await t.test('ekranın alt kenarında metin kaybolmaz', () => {
    assert.ok(r.edge[0].bottom <= r.viewport.height, JSON.stringify(r.edge));
    assert.equal(r.edge[0].text, scenarios.edge[0].text);
  });
  await t.test('paragraf hizası ve tam metin korunur', () => {
    assert.equal(r.paragraph[0].align, 'left');
    assert.equal(r.paragraph[0].text, scenarios.paragraph[0].text);
    assert.ok(r.paragraph[0].scrollHeight <= r.paragraph[0].clientHeight + 1);
    assert.ok(r.paragraph[0].bottom < r.paragraph[1].top);
  });
  await t.test('sığması imkânsız metin kesilmez ve 14 px altına inmez', () => {
    assert.equal(r.dense.length, 2);
    assert.equal(r.dense[0].text, scenarios.dense[0].text);
    assert.ok(r.dense[0].font >= 14);
    assert.ok(r.dense[0].scrollHeight <= r.dense[0].clientHeight + 1);
  });
  await t.test('boş/geçersiz kutular sağlam etiketi küçültmez', () => {
    assert.deepEqual(r.invalid, r.isolated);
  });
  await t.test('kumanda simgesi çevirinin içinde yerinde durur', () => {
    assert.equal(r.icons[0].text, 'Koşmak için basılı tutun.');
    assert.equal(r.icons[0].images, 1);
    assert.equal(r.icons[0].lead, 'Koşmak için ');
    assert.equal(r.icons[1].images, 0);
    assert.equal(r.icons[1].text, 'Kaydet');
  });
  await t.test('ek alanın ayrı yazıları alt alta değil, kendi yerlerinde', () => {
    assert.equal(r.regionKind, 'region-blocks');
    assert.equal(r.regionBlocks.length, 2);
    const [title, goal] = r.regionBlocks;
    assert.equal(title.text, regionBlocks[0].text);
    assert.equal(goal.text, regionBlocks[1].text);
    assert.equal(title.position, 'absolute');
    assert.notEqual(title.background, 'rgba(0, 0, 0, 0)');
    // Her blok kendi İngilizce yazısının sol üstünde (pay 0.004).
    assert.ok(Math.abs(title.left - .716 * width) < 1, JSON.stringify(title));
    assert.ok(Math.abs(goal.left - .616 * width) < 1, JSON.stringify(goal));
    assert.ok(Math.abs(goal.top - .116 * height) < 1, JSON.stringify(goal));
    // Uzun başlık alttaki bağımsız hedefin üstüne taşmaz ya da yazı kesilmez.
    assert.ok(title.bottom <= goal.top + 1 || title.right <= goal.left || title.left >= goal.right, JSON.stringify(r.regionBlocks));
    assert.ok(title.scrollHeight <= title.clientHeight + 1 || title.font === 14);
    assert.deepEqual(r.regionSingle, ['region']);
  });
  await t.test('kısa telefon çevirisi İngilizce mesaj kutusunun tamamını örter', () => {
    const m = r.shortPhone;
    assert.ok(m.top <= .72 * height + 1 && m.bottom >= .82 * height - 1, JSON.stringify(m));
    assert.ok(m.left <= .71 * width + 1 && m.right >= .98 * width - 1, JSON.stringify(m));
  });
  await t.test('uzun telefon çevirisi alta yaslı kalır ve okunabilir boyutta sığar', () => {
    const m = r.longPhone;
    assert.ok(Math.abs(m.bottom - .884 * height) < 1, JSON.stringify(m));
    assert.ok(m.height <= .118 * height * 1.35 + 1 || m.font === 14, JSON.stringify(m));
    assert.ok(m.scrollHeight <= m.clientHeight + 1 && m.font >= 14 && m.top >= 0, JSON.stringify(m));
  });
  await t.test('tek satırlık ipucu tek satıra sığıyorsa altındaki HUD satırına taşmaz', () => {
    const m = r.help;
    assert.ok(m.height <= .048 * height + 1, JSON.stringify(m));
    assert.ok(m.left >= 0 && m.width <= .35 * width + 1, JSON.stringify(m));
    assert.equal(m.text, 'Görev listesini açmak için basılı tut');
  });
  await t.test('sağ kenardaki dar ek alan bloğunun çevirisi ekran içinde kalır', () => {
    const [label, edge] = r.edgeNeighbours;
    assert.ok(label.right <= edge.left + 1 && edge.right <= width + 1, JSON.stringify(r.edgeNeighbours));
    assert.equal(edge.text, 'Köşe');
  });
  await t.test('ek alan ekran genişliğini aşmaz; sığmayan ipucu okunabilir boyutta sarılır', () => {
    assert.ok(r.fullWidthRegion.left >= 0 && r.fullWidthRegion.right <= width + 1);
    const m = r.denseHelp;
    assert.equal(m.text, 'İşaretli güzergâhtaki en eski binanın ön kapısına kadar ilerle. '.repeat(12));
    if (m.height > .038 * height + 1) assert.equal(m.font, 14);
    assert.ok(m.scrollHeight <= m.clientHeight + 1 && m.right <= width + 1);
  });
  await t.test('kapatma ve normal altyazıdan geçiş korunur', () => {
    assert.equal(r.hidden, 'hidden'); assert.equal(r.count, 0);
    assert.ok(r.hideReasons.every(reason => reason === 'screen'));
  });
  await t.test('telefonun bağımsız satırları kaynak renk ve genişliğini korur', () => {
    const [reply, next] = r.phone;
    assert.equal(reply.text, 'Yanıt');
    assert.equal(reply.background, 'rgb(37, 117, 164)');
    assert.equal(reply.color, 'rgb(255, 255, 255)');
    assert.equal(next.background, 'rgb(36, 39, 42)');
    assert.equal(next.text, 'Git');
    assert.ok(Math.abs(next.left - .489 * width) < 1);
    assert.ok(Math.abs(next.width - .032 * width) < 1);
    assert.ok(reply.bottom <= next.top);
    assert.equal(r.afterPhone, 'Ahıra git');
    assert.equal(r.normalColor, 'rgba(0, 0, 0, 0.97)');
    const [title, body] = r.styled;
    assert.equal(title.background, 'rgb(240, 240, 240)');
    assert.equal(title.color, 'rgb(16, 16, 16)');
    assert.equal(title.weight, '700');
    assert.equal(title.align, 'right');
    assert.match(title.family, /Condensed|Narrow/);
    assert.equal(body.background, 'rgba(26, 28, 32, 0.85)');
    assert.equal(body.weight, '400');
    assert.equal(body.align, 'left');
    // Özgün blok genişliğini aşmaz (en çok iç pay kadar).
    assert.ok(body.width <= (.25 - .05 + 2 * .004) * r.viewport.width + 1, JSON.stringify(body));
  });
});

}
