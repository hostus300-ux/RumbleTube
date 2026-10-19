// Tests extract.js in Chromium against markup captured from rumble.com (Oct 2026):
// search results (server-rendered <article class="video-item">), a channel header, and a
// client-rendered grid inside a shadow root (how channel pages load their videos).
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';

const require = createRequire('/opt/npm-tools/node_modules/');
const { chromium } = require('playwright');
const extract = readFileSync(new URL('../RumbleTube/Resources/extract.js', import.meta.url), 'utf8');

// Real search-result card (trimmed svg paths / tracking attributes)
const article = (id, slug, title, dur, ch) => `<li class="video-listing-entry"><article class="video-item "><a class="video-item--a" href="/${id}-${slug}.html?e9s=src_v1_s%2Csrc_v1_s_o&amp;sci=ec03"><div class="video-item--img-wrapper"><img
  class="video-item--img" src="https://hugh.cdn.rumble.cloud/video/fww1/3d/s8/6/G/m/r/7/Gmr7A.oq1b.jpg" alt="${title}"></div><span class="video-item--duration" data-value="${dur}"></span></a><div class="video-item--info"><time class="video-item--meta video-item--time" datetime=2026-10-16T14:24:34-04:00 title="October 16, 2026">3 days ago</time><h3 class=video-item--title>${title}</h3><address class=video-item--by><a rel=author class="video-item--by-a video-item--by-a--ukqd4p" href="/user/${ch}?e9s=src_v1_cmd"><div class=ellipsis-1>${ch}<svg class="video-item--by-verified verification-badge-icon" role=img width=23 height=24><title>Verified</title><path d="M0"/></svg></div></a></address><footer class="video-item--footer"><div class="video-item--rumbles"><div class="rumbles-vote rumbles-vote-with-bar" data-type="1" data-id="448088618"><div class="rumbles-vote-vote rumbles-vote-up"><svg width=17 height=16><path d="M1"/></svg>12</div><div class="rating-bar" title="12 Likes | 3 Dislikes"><div class="rating-bar__fill" style="width: 80%"></div></div><div class="rumbles-vote-vote rumbles-vote-down"><svg width=17 height=16><path d="M1"/></svg>3</div></div></div><div class="video-counters"><div class="video-counters--item video-item--views"><svg class=video-counters--icon width=15 height=11><path d="M1"/></svg>1.81K</div></div></footer></div></article></li>`;

const searchHtml = `<!doctype html><html><body><main><ol>
  ${article('v7gygbk', 'breaking-news-on-katie-zacharia', 'BREAKING NEWS ON KATIE ZACHARIA', '1:17', 'RealAmericasVoice')}
  ${article('v7h1izc', 'america-is-the-new-rome', 'America Is the New Rome', '1:02:44', 'SomeChannel')}
  <li class="video-listing-entry"><article class="video-item "><a class="video-item--a" href="/v7live01-live-show.html"><div class="video-item--img-wrapper"><img class="video-item--img" src="https://x.rumble.cloud/a.jpg" alt="Live show"></div><span class="video-item--live" data-value="LIVE"></span></a><div class="video-item--info"><h3 class=video-item--title>Live show</h3><address class=video-item--by><a rel=author class="video-item--by-a" href="/c/LiveGuy"><div class=ellipsis-1>LiveGuy</div></a></address></div></article></li>
  </ol>
  <nav class="flex"><a href="/search/video?q=news&e9s=x">1</a><a href="/search/video?page=2&q=news&e9s=x">2</a><a href="/search/video?page=3&q=news">3</a></nav>
  </main></body></html>`;

const channelHtml = `<!doctype html><html><body><main class="nonconstrained">
<div class="channel-header--container"><div class="channel-header--backsplash"><img class="channel-header--backsplash-img"
src="https://hugh.cdn.rumble.cloud/video/z8/N/P/0/f/NP0fa.caa.1-Redacted-t1e5hj.jpeg" alt="" width="1430" height="291" aria-hidden="true"
></div><div class="channel-header--content"><div class="channel-header--content-inner"><div class="constrained"><div
class="channel-header--thumb"><img class="channel-header--img" src="https://hugh.cdn.rumble.cloud/video/z8/N/P/0/f/NP0fa.baa.2-Redacted-rf6g0q.png"
alt="Redacted News"></div><div class="channel-header--title"><div class="flex items-center"><h1>Redacted News</h1><svg></svg></div><span class="text-fjord"><span>697K Followers</span></span></div>
<div class="followed-channel flex items-center" data-title="Redacted News" data-slug="Redacted" data-id="1526375" data-type="channel"><button class="js-media-subscribe btn btn-green">Follow</button></div>
</div></div></div></div>
<section class="channel-listing__container"><rum-videos-grid></rum-videos-grid>
<nav class="flex"><a href=/c/Redacted>1</a><a href="/c/Redacted?page=2">2</a></nav></section></main>
<script>
  // Simulates Rumble's web component rendering cards inside a shadow root after load.
  customElements.define('rum-videos-grid', class extends HTMLElement {
    connectedCallback() {
      const r = this.attachShadow({ mode: 'open' });
      r.innerHTML = [1,2,3,4].map(n => \`<div class="videostream thumbnail__grid--item">
        <a class="videostream__link link" href="/v6red00\${n}-episode-\${n}-of-the-show.html"><div class="thumbnail__thumb">
          <img class="thumbnail__image" src="https://hugh.cdn.rumble.cloud/t\${n}.jpg" alt="Episode \${n}">
          <div class="videostream__status videostream__status--duration">\${n}2:0\${n}</div></div></a>
        <div class="videostream__footer"><a href="/v6red00\${n}-episode-\${n}-of-the-show.html"><h3 class="thumbnail__title">Episode \${n} of the show</h3></a>
          <div class="videostream__data"><span class="videostream__data--item videostream__views">\${n}5.2K views</span>
          <time class="videostream__data--subitem" datetime="2026-10-1\${n}T10:00:00-04:00">\${n} days ago</time></div></div></div>\`).join('');
    }
  });
</script></body></html>`;

const browser = await chromium.launch();
const page = await browser.newPage();
await page.route('https://rumble.com/**', (route) => {
  const u = new URL(route.request().url());
  route.fulfill({ contentType: 'text/html', body: u.pathname.startsWith('/c/') ? channelHtml : searchHtml });
});
let n = 0; const ok = (m) => { n++; console.log('  ✓', m); };

// ---- search ----
await page.goto('https://rumble.com/search/video?q=news');
let r = JSON.parse(await page.evaluate(extract));
assert.equal(r.items.length, 3);
const [a, b, live] = r.items;
assert.deepEqual(
  { id: a.id, url: a.url, title: a.title, duration: a.duration, channelName: a.channelName, channelPath: a.channelPath, views: a.views, published: a.published },
  { id: 'v7gygbk', url: 'https://rumble.com/v7gygbk-breaking-news-on-katie-zacharia.html', title: 'BREAKING NEWS ON KATIE ZACHARIA',
    duration: '1:17', channelName: 'RealAmericasVoice', channelPath: '/user/RealAmericasVoice', views: '1.81K', published: '2026-10-16T14:24:34-04:00' },
);
assert.match(a.thumbnail, /^https:\/\/hugh\.cdn\.rumble\.cloud\/.+\.jpg$/);
assert.equal(b.duration, '1:02:44');
assert.equal(live.live, true);
assert.equal(live.channelPath, '/c/LiveGuy');
assert.equal(r.hasNext, true);
assert.equal(r.channel, null);
ok('search page: titles, thumbs, durations, channels, views, dates, live, pagination');

await page.goto('https://rumble.com/search/video?q=news&page=3');
r = JSON.parse(await page.evaluate(extract));
assert.equal(r.hasNext, false);
ok('last page has no next');

// ---- channel ----
await page.goto('https://rumble.com/c/Redacted');
r = JSON.parse(await page.evaluate(extract));
assert.deepEqual(r.channel, {
  path: '/c/Redacted', name: 'Redacted News',
  avatar: 'https://hugh.cdn.rumble.cloud/video/z8/N/P/0/f/NP0fa.baa.2-Redacted-rf6g0q.png',
  banner: 'https://hugh.cdn.rumble.cloud/video/z8/N/P/0/f/NP0fa.caa.1-Redacted-t1e5hj.jpeg',
  followers: '697K',
});
assert.equal(r.items.length, 4);
assert.equal(r.items[0].title, 'Episode 1 of the show');
assert.equal(r.items[0].duration, '12:01');
assert.equal(r.items[0].views, '15.2K');
assert.equal(r.items[0].published, '2026-10-11T10:00:00-04:00');
assert.equal(r.items[0].thumbnail, 'https://hugh.cdn.rumble.cloud/t1.jpg');
assert.equal(r.hasNext, true);
ok('channel page: header + shadow-DOM grid + pagination');

await browser.close();
console.log(`\n${n} extractor checks passed`);
