// RumbleTube page extractor.
// Runs inside a (hidden) WKWebView on a rumble.com listing page — search, channel, browse —
// and returns JSON describing the videos on it. It does not rely on Rumble's class names:
// it finds every link to a watch page (/v….html), including inside open shadow roots, and
// reads the card around it. That keeps it working through most Rumble redesigns.
(function () {
  'use strict';
  var VID = /^\/(v[a-z0-9]{3,15})-[^?#]*\.html/i;
  var CHAN = /^\/(c|user)\/([^/?#]+)/i;
  var DUR = /^\d{1,2}(:\d{2}){1,2}$/;

  // Shorts live only in the Shorts tab, so skip anything inside a shorts shelf.
  function inShorts(el) {
    for (var n = el; n; n = n.parentNode || n.host) {
      if (n.nodeType === 11) { n = n.host; if (!n) break; }
      if (n.nodeType !== 1) continue;
      var tag = n.tagName.toLowerCase();
      if (tag.indexOf('shorts') !== -1 || /(^|\s|-)shorts(\s|-|_|$)/i.test(n.getAttribute('class') || '')) return true;
    }
    return false;
  }

  function roots() {
    var out = [document];
    (function walk(root) {
      var all = root.querySelectorAll('*');
      for (var i = 0; i < all.length; i++) {
        if (all[i].shadowRoot && !inShorts(all[i])) { out.push(all[i].shadowRoot); walk(all[i].shadowRoot); }
      }
    })(document);
    return out;
  }

  function parseHref(href) {
    try { return new URL(href, location.origin); } catch (e) { return null; }
  }

  function videoIdOf(a) {
    var u = parseHref(a.getAttribute('href'));
    if (!u || u.hostname.replace(/^www\./, '') !== 'rumble.com') return null;
    var m = VID.exec(u.pathname);
    return m ? { id: m[1].toLowerCase(), path: u.pathname } : null;
  }

  function idsIn(el) {
    var s = {}, n = 0, links = el.querySelectorAll('a[href]');
    for (var i = 0; i < links.length; i++) {
      var v = videoIdOf(links[i]);
      if (v && !s[v.id]) { s[v.id] = 1; n++; }
    }
    return n;
  }

  // Climb from the link to the largest ancestor that still only contains this one video.
  function cardFor(a) {
    var el = a;
    for (var depth = 0; depth < 8; depth++) {
      var p = el.parentElement;
      if (!p || p === document.body) break;
      if (idsIn(p) > 1) break;
      el = p;
      var tag = el.tagName;
      if (tag === 'ARTICLE' || tag === 'LI') break;
    }
    return el;
  }

  function text(el) { return el ? (el.textContent || '').replace(/\s+/g, ' ').trim() : ''; }

  function imgSrc(img) {
    if (!img) return null;
    var s = img.getAttribute('src') || img.getAttribute('data-src') || '';
    if ((!s || s.indexOf('data:') === 0) && img.getAttribute('srcset')) s = img.getAttribute('srcset').split(',')[0].trim().split(' ')[0];
    if (!s || s.indexOf('data:') === 0) return null;
    var u = parseHref(s);
    return u ? u.href : null;
  }

  function inChannelLink(el, card) {
    for (var n = el; n && n !== card; n = n.parentElement) {
      if (n.tagName === 'A') {
        var u = parseHref(n.getAttribute('href') || '');
        if (u && CHAN.test(u.pathname)) return true;
      }
    }
    return false;
  }

  function extractCard(card, a, vid) {
    var item = { id: vid.id, url: 'https://rumble.com' + vid.path };

    // thumbnail: first image that isn't a channel avatar
    var imgs = card.querySelectorAll('img');
    for (var i = 0; i < imgs.length; i++) {
      if (inChannelLink(imgs[i], card)) continue;
      var src = imgSrc(imgs[i]);
      if (src) { item.thumbnail = src; if (!item.title && imgs[i].alt) item.altTitle = imgs[i].alt.trim(); break; }
    }

    // title
    var h = card.querySelector('h3, h2, h4, [class*="title"]');
    item.title = text(h) || (a.getAttribute('title') || '').trim() || item.altTitle || text(a);
    delete item.altTitle;

    // duration / live
    var all = card.querySelectorAll('*');
    for (var j = 0; j < all.length; j++) {
      var el = all[j], cls = (el.getAttribute('class') || '').toLowerCase();
      var dv = el.getAttribute('data-value');
      if (!item.duration && dv && DUR.test(dv.trim())) item.duration = dv.trim();
      if (!item.duration && el.children.length === 0 && DUR.test(text(el))) item.duration = text(el);
      if (/(^|[\s_-])live([\s_-]|$)/.test(cls) || (el.children.length === 0 && /^live$/i.test(text(el)))) item.live = true;
      if (/upcoming/.test(cls)) item.upcoming = true;
      if (!item.views && /views/.test(cls)) {
        var vt = text(el).replace(/views?/i, '').trim();
        if (vt) item.views = vt;
      }
    }
    if (!item.views) {
      var vm = /([\d.,]+\s*[KMB]?)\s+views/i.exec(text(card));
      if (vm) item.views = vm[1].replace(/\s+/g, '');
    }

    // date
    var t = card.querySelector('time');
    if (t) {
      item.published = t.getAttribute('datetime') || null;
      item.publishedText = text(t) || null;
    }

    // channel
    var links = card.querySelectorAll('a[href]');
    for (var k = 0; k < links.length; k++) {
      var u = parseHref(links[k].getAttribute('href'));
      var m = u && CHAN.exec(u.pathname);
      if (m) {
        item.channelPath = '/' + m[1].toLowerCase() + '/' + m[2];
        item.channelName = text(links[k]).replace(/\s*Verified\s*$/, '') || m[2];
        var av = links[k].querySelector('img');
        if (av && imgSrc(av)) item.channelAvatar = imgSrc(av);
        break;
      }
    }
    return item;
  }

  function channelHeader() {
    var m = CHAN.exec(location.pathname);
    if (!m) return null;
    var head = document.querySelector('[class*="channel-header"]') || document;
    var h1 = head.querySelector('h1') || document.querySelector('h1');
    var avatar = head.querySelector('[class*="channel-header--img"], [class*="thumb"] img');
    var banner = head.querySelector('[class*="backsplash"] img, [class*="banner"] img');
    var fm = /([\d.,]+\s*[KMB]?)\s+(Followers|Subscribers)/i.exec(text(head));
    return {
      path: '/' + m[1].toLowerCase() + '/' + m[2],
      name: text(h1) || m[2],
      avatar: avatar && avatar.tagName === 'IMG' ? imgSrc(avatar) : null,
      banner: banner ? imgSrc(banner) : null,
      followers: fm ? fm[1].replace(/\s+/g, '') : null,
    };
  }

  function hasNext() {
    var cur = parseInt(new URLSearchParams(location.search).get('page') || '1', 10) || 1;
    var as = document.querySelectorAll('a[href]');
    for (var i = 0; i < as.length; i++) {
      var u = parseHref(as[i].getAttribute('href') || '');
      if (u && u.pathname === location.pathname && parseInt(u.searchParams.get('page') || '0', 10) === cur + 1) return true;
    }
    return false;
  }

  var items = [], seen = {};
  var rs = roots();
  for (var r = 0; r < rs.length; r++) {
    var links = rs[r].querySelectorAll('a[href]');
    for (var i = 0; i < links.length; i++) {
      var vid = videoIdOf(links[i]);
      if (!vid || seen[vid.id] || inShorts(links[i])) continue;
      var card = cardFor(links[i]);
      var item = extractCard(card, links[i], vid);
      if (!item.title) continue;
      seen[vid.id] = 1;
      items.push(item);
    }
  }

  var empty = /no (results|videos)|nothing (found|here)/i.test(text(document.querySelector('main') || document.body).slice(0, 4000));
  return JSON.stringify({ items: items, hasNext: hasNext(), channel: channelHeader(), empty: empty && items.length === 0 });
})();
