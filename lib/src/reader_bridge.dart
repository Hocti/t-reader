import 'page_paint.dart';
import 'reader_store.dart';

final _viewportMeta = RegExp(
  '<meta\\b[^>]*\\bname\\s*=\\s*["\']viewport["\'][^>]*>',
  caseSensitive: false,
);

String dressChapter(String html, {required PagePaint paint, required ReaderLayout layout}) {
  final style =
      '<meta name="viewport" content="width=device-width, initial-scale=1"/>'
      '<style id="epub-reader-theme">${readerCss(paint, layout)}</style>';
  final script = _scriptElement(readerJs());
  var dressed = html.replaceAll(_viewportMeta, '');
  dressed = dressed.replaceFirst(
    '<div id="reader-viewport">',
    '<div id="reader-viewport" data-mode="${layout.turn.name}" data-writing="${layout.writing.name}" data-margin="${layout.marginPx}" data-columns="${layout.columns == ColumnMode.double ? 2 : 1}" data-top="${pageTopPx + layout.marginVPx}" data-bottom="${pageBottomPx + layout.marginVPx}">',
  );
  final head = RegExp(r'</head>', caseSensitive: false);
  dressed = head.hasMatch(dressed) ? dressed.replaceFirst(head, '$style</head>') : '$style$dressed';
  final body = RegExp(r'</body>', caseSensitive: false);
  dressed = body.hasMatch(dressed) ? dressed.replaceFirst(body, '$script</body>') : '$dressed$script';
  return dressed;
}

/// Inline script in XHTML is XML. `&&` and `<` must sit inside CDATA or the WebView stops at the first `&`.
String _scriptElement(String source) {
  final safe = source.replaceAll(']]>', ']]]]><![CDATA[>');
  return '<script id="epub-reader-script"><![CDATA[\n$safe\n]]></script>';
}

/// Blank band above the text. The temporary bookmark sits in it.
const pageTopPx = 24;
const pageBottomPx = 12;

/// The two round handles that move the ends of a selection.
const handlePx = 40;

String readerCss(PagePaint paint, ReaderLayout layout) {
  final size = layout.fontPx;
  final h2 = (size * 1.45).round();
  final h3 = (size * 1.25).round();
  final h4 = (size * 1.12).round();
  final note = (size * 0.9).round();
  return '''
html, body {
  margin: 0 !important;
  padding: 0 !important;
  height: 100% !important;
  width: 100% !important;
  max-width: 100% !important;
  overflow: hidden !important;
  background: ${paint.page} !important;
  color: ${paint.ink} !important;
}
#reader-viewport {
  width: 100vw;
  height: 100vh;
  overflow: hidden;
  background: ${paint.page};
  -webkit-user-select: none;
  user-select: none;
  -webkit-touch-callout: none;
}
#reader-viewport[data-writing="vertical"],
#reader-viewport[data-writing="vertical"] #reader-flow {
  writing-mode: vertical-rl;
}
#reader-flow, #reader-flow * {
  font-family: ${layout.fontFamily} !important;
  line-height: ${layout.lineHeight} !important;
}
#reader-flow p, #reader-flow li, #reader-flow span, #reader-flow a, #reader-flow div, #reader-flow blockquote {
  font-size: ${size}px !important;
}
#reader-flow h1, #reader-flow h2 { font-size: ${h2}px !important; }
#reader-flow h3 { font-size: ${h3}px !important; }
#reader-flow h4, #reader-flow h5, #reader-flow h6 { font-size: ${h4}px !important; }
#reader-flow .footnote, #reader-flow .footnote0 { font-size: ${note}px !important; }
#reader-flow, #reader-flow * {
  color: ${paint.ink} !important;
  background-color: transparent !important;
  border-color: ${paint.ink} !important;
}
#reader-flow a { text-decoration: underline !important; }
#reader-flow img, #reader-flow svg {
  max-width: 100% !important;
  max-height: calc(100vh - ${pageTopPx + pageBottomPx + layout.marginVPx * 2}px) !important;
  object-fit: contain !important;
  height: auto !important;
}
#reader-flow .marked, #reader-flow .marked * {
  text-decoration: underline !important;
  text-decoration-color: ${paint.accentCss} !important;
  text-decoration-thickness: 3px !important;
  text-underline-offset: 4px !important;
}
#reader-flow .found {
  outline: 2px solid ${paint.accentCss} !important;
}
#reader-flow .reading, #reader-flow .reading *,
#reader-flow .picked, #reader-flow .picked * {
  background-color: ${paint.accentCss} !important;
  color: ${paint.onAccentCss} !important;
}
#reader-flow .reading span.word, #reader-flow .reading span.word *,
#reader-flow span.word, #reader-flow span.word * {
  background-color: ${paint.wordCss} !important;
  color: ${paint.onWordCss} !important;
}
.reader-mask {
  position: fixed;
  top: 0;
  bottom: 0;
  display: none;
  background: ${paint.page};
  pointer-events: none;
  z-index: 5;
}
.reader-handle {
  position: fixed;
  display: none;
  box-sizing: border-box;
  width: ${handlePx}px;
  height: ${handlePx}px;
  border-radius: 50%;
  background: ${paint.accentCss};
  border: 3px solid ${paint.page};
  box-shadow: 0 0 0 2px ${paint.accentCss};
  z-index: 10;
  touch-action: none;
}
''';
}

String readerJs() => r'''
(function () {
  var viewport = document.getElementById('reader-viewport');
  var flow = document.getElementById('reader-flow');
  if (!viewport || !flow) return;
  var page = 0;
  var pages = 1;
  var sidPage = {};
  var pressing = false;
  var longOn = false;
  var moved = false;
  var timer = 0;
  var cornerTimer = 0;
  var downX = 0;
  var downY = 0;
  var lastCorner = '';
  var sidLast = {};
  var speaking = false;
  // A selection runs between two boundaries {s: sentence id, o: characters into it}. The end is exclusive.
  var selA = null;
  var selB = null;
  var fixed = null;
  var pressSid = -1;
  var grabX = 0;
  var grabY = 0;
  var handles = {start: makeHandle('start'), end: makeHandle('end')};
  // Vertical paging keeps whole lines on a page. Each page starts at a line's right edge and ends at the
  // left edge of its last whole line, in viewport coordinates with no transform.
  var vStarts = [];
  var vEnds = [];
  var masks = {left: makeMask(), right: makeMask()};

  function makeHandle(end) {
    var el = document.createElement('div');
    el.className = 'reader-handle';
    el.setAttribute('data-end', end);
    viewport.appendChild(el);
    return el;
  }

  function makeMask() {
    var el = document.createElement('div');
    el.className = 'reader-mask';
    viewport.appendChild(el);
    return el;
  }

  function mode() { return viewport.getAttribute('data-mode') || 'page'; }
  function vertical() { return viewport.getAttribute('data-writing') === 'vertical'; }
  function margin() { return parseInt(viewport.getAttribute('data-margin') || '0', 10) || 0; }
  function topBand() { return parseInt(viewport.getAttribute('data-top') || '12', 10) || 0; }
  function bottomBand() { return parseInt(viewport.getAttribute('data-bottom') || '12', 10) || 0; }
  function band() { return topBand() + bottomBand(); }
  function verticalPaged() { return vertical() && mode() !== 'scroll'; }
  // Two columns per page only for horizontal pages on a wide screen. Each column is half a page wide
  // with the same gap, so a page is still one screen width.
  function twoUp() {
    return viewport.getAttribute('data-columns') === '2' && !vertical() && mode() !== 'scroll' && width() > 800;
  }
  function columnWidth() {
    var m = margin();
    return twoUp() ? Math.max(40, Math.floor((width() - m * 4) / 2)) : Math.max(40, width() - m * 2);
  }
  function post(obj) {
    if (window.ReaderMsg && ReaderMsg.postMessage) ReaderMsg.postMessage(JSON.stringify(obj));
  }
  function width() { return viewport.clientWidth || window.innerWidth; }
  function height() { return viewport.clientHeight || window.innerHeight; }

  function fitMedia() {
    var limitW = columnWidth();
    var limitH = Math.max(40, height() - band());
    var nodes = flow.querySelectorAll('img, svg');
    for (var i = 0; i < nodes.length; i++) {
      var el = nodes[i];
      el.style.maxWidth = limitW + 'px';
      el.style.maxHeight = limitH + 'px';
      var tag = (el.tagName || '').toLowerCase();
      if (tag !== 'svg') {
        el.style.objectFit = 'contain';
        continue;
      }
      var attrW = el.getAttribute('width') || '';
      var attrH = el.getAttribute('height') || '';
      var vb = el.viewBox && el.viewBox.baseVal;
      var percent = attrW.indexOf('%') >= 0 || attrH.indexOf('%') >= 0;
      var oversized = !!(vb && (vb.width > limitW || vb.height > limitH));
      if (!(percent || oversized) || !vb || vb.width <= 0 || vb.height <= 0) continue;
      var w = limitW;
      var h = w * vb.height / vb.width;
      if (h > limitH) {
        h = limitH;
        w = h * vb.width / vb.height;
      }
      el.style.display = 'block';
      el.style.width = Math.max(1, Math.floor(w)) + 'px';
      el.style.height = Math.max(1, Math.floor(h)) + 'px';
    }
  }

  function sizeColumns() {
    var scrolling = mode() === 'scroll';
    var m = margin();
    var w = width();
    viewport.style.touchAction = scrolling ? (vertical() ? 'pan-x' : 'pan-y') : 'none';
    if (scrolling && vertical()) {
      viewport.style.overflowX = 'auto';
      viewport.style.overflowY = 'hidden';
    } else if (scrolling) {
      viewport.style.overflowX = 'hidden';
      viewport.style.overflowY = 'auto';
    } else {
      viewport.style.overflow = 'hidden';
    }
    flow.style.boxSizing = 'content-box';
    flow.style.marginTop = topBand() + 'px';
    flow.style.paddingTop = '0px';
    flow.style.paddingBottom = '0px';
    flow.style.paddingLeft = m + 'px';
    flow.style.paddingRight = m + 'px';
    if (vertical()) {
      flow.style.columnWidth = 'auto';
      flow.style.columnGap = '0px';
      flow.style.height = Math.max(40, height() - band()) + 'px';
      flow.style.width = 'max-content';
      fitMedia();
      return;
    }
    if (scrolling) {
      flow.style.columnWidth = 'auto';
      flow.style.columnGap = '0px';
      flow.style.height = 'auto';
      flow.style.transform = 'none';
      flow.style.width = 'auto';
      flow.style.paddingBottom = bottomBand() + 'px';
      fitMedia();
      return;
    }
    flow.style.width = 'auto';
    flow.style.height = Math.max(40, height() - band()) + 'px';
    flow.style.columnWidth = columnWidth() + 'px';
    flow.style.columnGap = (m * 2) + 'px';
    flow.style.columnFill = 'auto';
    fitMedia();
  }

  // Every line and image as [left, right], with no transform.
  function lineBoxes() {
    var out = [];
    var host = viewport.getBoundingClientRect();
    var walker = document.createTreeWalker(flow, NodeFilter.SHOW_TEXT);
    var range = document.createRange();
    while (walker.nextNode()) {
      var node = walker.currentNode;
      if (!node.data.trim()) continue;
      range.selectNodeContents(node);
      var rects = range.getClientRects();
      for (var i = 0; i < rects.length; i++) {
        if (rects[i].width > 0 && rects[i].height > 0) out.push([rects[i].left - host.left, rects[i].right - host.left]);
      }
    }
    var media = flow.querySelectorAll('img, svg');
    for (var j = 0; j < media.length; j++) {
      var r = media[j].getBoundingClientRect();
      if (r.width > 0 && r.height > 0) out.push([r.left - host.left, r.right - host.left]);
    }
    return out;
  }

  // Lines run right to left. A page takes lines until the next one would cross its left margin.
  function paginateVertical() {
    var boxes = lineBoxes();
    boxes.sort(function (a, b) { return b[1] - a[1]; });
    var lines = [];
    for (var i = 0; i < boxes.length; i++) {
      var box = boxes[i];
      var last = lines[lines.length - 1];
      if (last && box[1] > last[0] + 0.5) {
        if (box[0] < last[0]) last[0] = box[0];
      } else {
        lines.push([box[0], box[1]]);
      }
    }
    var right = width() - margin();
    var avail = Math.max(40, width() - margin() * 2);
    vStarts = [right];
    vEnds = [right];
    for (var j = 0; j < lines.length; j++) {
      var line = lines[j];
      var k = vStarts.length - 1;
      var fresh = vEnds[k] === vStarts[k];
      if (!fresh && line[0] < vStarts[k] - avail - 0.5) {
        vStarts.push(line[1]);
        vEnds.push(line[0]);
      } else {
        vEnds[k] = Math.min(vEnds[k], line[0]);
      }
    }
  }

  // Column k spans k * w + margin to (k + 1) * w - margin, so any x inside it rounds down to k.
  function columnAt(x, w) {
    var n = Math.floor((x + 1) / w);
    return n < 0 ? 0 : n;
  }

  function vPageAt(right) {
    var n = 0;
    for (var k = 0; k < vStarts.length; k++) if (right <= vStarts[k] + 0.5) n = k;
    return n;
  }

  // Covers the neighbouring pages' lines that show at the edges.
  function placeMasks() {
    if (!verticalPaged() || !vStarts.length) {
      masks.left.style.display = 'none';
      masks.right.style.display = 'none';
      return;
    }
    var w = width();
    var shift = (w - margin()) - vStarts[page];
    var leftEdge = Math.max(0, Math.floor(vEnds[page] + shift) - 1);
    masks.left.style.left = '0px';
    masks.left.style.width = leftEdge + 'px';
    masks.left.style.display = leftEdge > 0 ? 'block' : 'none';
    var rightEdge = Math.ceil(w - margin()) + 1;
    masks.right.style.left = rightEdge + 'px';
    masks.right.style.width = Math.max(0, w - rightEdge) + 'px';
    masks.right.style.display = rightEdge < w ? 'block' : 'none';
  }

  function pageFor(el, host, flowRect, w, h) {
    var rect = el.getBoundingClientRect();
    var n = 0;
    if (mode() === 'scroll') {
      n = vertical() ? Math.round(Math.abs(el.offsetLeft) / w) : Math.floor(el.offsetTop / h);
    } else if (vertical()) {
      n = vPageAt(rect.right - host.left);
    } else {
      n = columnAt(rect.left - host.left, w);
    }
    return n < 0 ? 0 : n;
  }

  function pageOfElement(el) {
    if (!el) return -1;
    var prev = flow.style.transform;
    flow.style.transform = 'none';
    var n = pageFor(el, viewport.getBoundingClientRect(), flow.getBoundingClientRect(), width(), height());
    flow.style.transform = prev;
    return Math.min(n, pages - 1);
  }

  function byId(id) {
    if (!id) return null;
    var el = document.getElementById(id);
    if (el) return el;
    var named = document.getElementsByName ? document.getElementsByName(id) : [];
    return named.length ? named[0] : null;
  }

  function indexPages() {
    sidPage = {};
    sidLast = {};
    var prev = flow.style.transform;
    flow.style.transform = 'none';
    if (verticalPaged()) paginateVertical();
    var nodes = flow.querySelectorAll('[data-sid]');
    var w = width();
    var h = height();
    var host = viewport.getBoundingClientRect();
    var flowRect = flow.getBoundingClientRect();
    var maxPage = 0;
    for (var i = 0; i < nodes.length; i++) {
      var el = nodes[i];
      var id = el.getAttribute('data-sid');
      var n = pageFor(el, host, flowRect, w, h);
      var last = n;
      var rects = mode() === 'scroll' ? [] : el.getClientRects();
      if (rects.length > 1) {
        var r = rects[rects.length - 1];
        last = Math.max(n, vertical() ? vPageAt(r.right - host.left) : columnAt(r.left - host.left, w));
      }
      if (sidPage[id] == null) sidPage[id] = n;
      sidLast[id] = Math.max(sidLast[id] || 0, last);
      if (last > maxPage) maxPage = last;
    }
    flow.style.transform = prev;
    if (mode() === 'scroll') {
      pages = vertical()
        ? Math.max(1, Math.ceil(flow.scrollWidth / w))
        : Math.max(1, Math.ceil(flow.scrollHeight / h));
    } else if (vertical()) {
      pages = Math.max(1, vStarts.length);
    } else {
      var byWidth = Math.max(1, Math.round(flow.scrollWidth / w));
      pages = Math.max(byWidth, maxPage + 1);
    }
  }

  function firstIdFrom(map) {
    var best = -1;
    var nodes = flow.querySelectorAll('[data-sid]');
    for (var i = 0; i < nodes.length; i++) {
      var id = parseInt(nodes[i].getAttribute('data-sid'), 10);
      if (map[String(id)] !== page) continue;
      if (best < 0 || id < best) best = id;
    }
    return best;
  }

  function apply() {
    if (mode() === 'scroll') {
      flow.style.transform = 'none';
      placeMasks();
      return;
    }
    var w = width();
    if (vertical()) {
      var start = vStarts[page] != null ? vStarts[page] : w - margin();
      flow.style.transform = 'translateX(' + ((w - margin()) - start) + 'px)';
    } else {
      flow.style.transform = 'translateX(' + (-page * w) + 'px)';
    }
    placeMasks();
  }

  function show(next) {
    if (next < 0) next = 0;
    if (next > pages - 1) next = pages - 1;
    page = next;
    if (mode() === 'scroll') {
      if (vertical()) viewport.scrollLeft = page * width();
      else viewport.scrollTop = page * height();
    } else {
      apply();
    }
    placeHandles();
    post({type: 'page', page: page, pages: pages, first: firstIdFrom(sidPage)});
  }

  function boot(keep) {
    var sid = keep ? firstIdFrom(sidPage) : -1;
    sizeColumns();
    indexPages();
    var stay = keep ? page : 0;
    if (sid >= 0 && sidPage[String(sid)] != null) stay = sidPage[String(sid)];
    if (stay > pages - 1) stay = pages - 1;
    if (stay < 0) stay = 0;
    page = stay;
    apply();
    var imgs = document.images;
    for (var i = 0; i < imgs.length; i++) {
      if (!imgs[i].complete) imgs[i].addEventListener('load', function () { boot(true); }, {once: true});
    }
    post({type: 'page', page: page, pages: pages, first: firstIdFrom(sidPage)});
  }

  function paint(className, a, b) {
    var old = document.querySelectorAll('.' + className);
    for (var i = 0; i < old.length; i++) old[i].classList.remove(className);
    if (a < 0 || b < 0) return;
    var lo = a < b ? a : b;
    var hi = a > b ? a : b;
    for (var id = lo; id <= hi; id++) {
      var nodes = document.querySelectorAll('[data-sid="' + id + '"]');
      for (var j = 0; j < nodes.length; j++) nodes[j].classList.add(className);
    }
  }

  // Text nodes of one sentence, in order. Wrapper spans inside it do not change the count.
  function textsOf(id) {
    var out = [];
    var nodes = flow.querySelectorAll('[data-sid="' + id + '"]');
    for (var i = 0; i < nodes.length; i++) {
      var walker = document.createTreeWalker(nodes[i], NodeFilter.SHOW_TEXT);
      while (walker.nextNode()) out.push(walker.currentNode);
    }
    return out;
  }

  function sidLength(id) {
    var texts = textsOf(id);
    var n = 0;
    for (var i = 0; i < texts.length; i++) n += texts[i].data.length;
    return n;
  }

  function posOf(node, offset) {
    var el = node.parentElement;
    var host = el && el.closest ? el.closest('[data-sid]') : null;
    if (!host || !flow.contains(host)) return null;
    var id = parseInt(host.getAttribute('data-sid'), 10);
    if (isNaN(id)) return null;
    var texts = textsOf(id);
    var before = 0;
    for (var i = 0; i < texts.length; i++) {
      if (texts[i] === node) return {s: id, o: before + offset};
      before += texts[i].data.length;
    }
    return null;
  }

  function locate(pos) {
    var texts = textsOf(pos.s);
    var left = pos.o;
    for (var i = 0; i < texts.length; i++) {
      var len = texts[i].data.length;
      if (left <= len || i === texts.length - 1) return [texts[i], Math.max(0, Math.min(left, len))];
      left -= len;
    }
    return null;
  }

  function cmp(a, b) { return a.s !== b.s ? a.s - b.s : a.o - b.o; }

  function rangeOf(a, b) {
    var from = locate(a);
    var to = locate(b);
    if (!from || !to) return null;
    var range = document.createRange();
    range.setStart(from[0], from[1]);
    range.setEnd(to[0], to[1]);
    return range;
  }

  // The boundary under the finger. Off the text, the nearest end of the sentence there.
  function caretAt(x, y, late) {
    var range = document.caretRangeFromPoint ? document.caretRangeFromPoint(x, y) : null;
    if (range && range.startContainer && range.startContainer.nodeType === 3) {
      var at = posOf(range.startContainer, range.startOffset);
      if (at) return at;
    }
    var id = sentenceAt(x, y);
    if (id < 0) return null;
    return late ? {s: id, o: sidLength(id)} : {s: id, o: 0};
  }

  function unwrap(cls) {
    var olds = flow.querySelectorAll('span.' + cls + '[data-wrap]');
    var parents = [];
    for (var i = 0; i < olds.length; i++) {
      var el = olds[i];
      var parent = el.parentNode;
      if (!parent) continue;
      while (el.firstChild) parent.insertBefore(el.firstChild, el);
      parent.removeChild(el);
      parents.push(parent);
    }
    for (var j = 0; j < parents.length; j++) parents[j].normalize();
  }

  // Wraps each text piece between two boundaries, so a range can start and end inside a sentence.
  function wrap(cls, a, b) {
    for (var id = a.s; id <= b.s; id++) {
      var texts = textsOf(id);
      var before = 0;
      for (var i = 0; i < texts.length; i++) {
        var node = texts[i];
        var len = node.data.length;
        var from = id === a.s ? a.o - before : 0;
        var to = id === b.s ? b.o - before : len;
        before += len;
        if (from < 0) from = 0;
        if (to > len) to = len;
        if (to <= from) continue;
        if (to < len) node.splitText(to);
        if (from > 0) node = node.splitText(from);
        var span = document.createElement('span');
        span.className = cls;
        span.setAttribute('data-wrap', '1');
        node.parentNode.insertBefore(span, node);
        span.appendChild(node);
      }
    }
  }

  function select(a, b) {
    if (cmp(a, b) > 0) {
      var t = a;
      a = b;
      b = t;
    }
    var range = rangeOf(a, b);
    var text = range ? range.toString() : '';
    if (!text.trim()) return;
    selA = a;
    selB = b;
    unwrap('picked');
    wrap('picked', a, b);
    placeHandles();
    post({type: 'select', start: [a.s, a.o], end: [b.s, b.o], text: text});
  }

  function selectSentence(id) {
    select({s: id, o: 0}, {s: id, o: sidLength(id)});
  }

  // Page offset of each character of the spoken text. The spoken text is the page text with runs of
  // spaces made one, U+3000 dropped, and the ends trimmed.
  function spokenMap(id) {
    var texts = textsOf(id);
    var at = [];
    var chars = [];
    var inSpace = false;
    var base = 0;
    for (var i = 0; i < texts.length; i++) {
      var data = texts[i].data;
      for (var j = 0; j < data.length; j++) {
        var c = data.charAt(j);
        var space = c === ' ' || c === '\t' || c === '\n' || c === '\r' || c === '\f';
        if (space && inSpace) continue;
        inSpace = space;
        if (c === '\u3000') continue;
        chars.push(space ? ' ' : c);
        at.push(base + j);
      }
      base += data.length;
    }
    var lead = 0;
    while (lead < chars.length && chars[lead] === ' ') lead++;
    return {at: at, lead: lead};
  }

  // Turns to the page of the spoken word, or scrolls it into view.
  function followWord() {
    var el = flow.querySelector('span.word[data-wrap]');
    if (!el) return page;
    if (mode() === 'scroll') {
      var r = el.getBoundingClientRect();
      if (vertical()) {
        if (r.left < 0 || r.right > width()) viewport.scrollLeft += r.right - (width() - margin());
      } else if (r.top < topBand() || r.bottom > height() - bottomBand()) {
        viewport.scrollTop += r.top - topBand();
      }
      return page;
    }
    var n = pageOfElement(el);
    if (n >= 0 && n !== page) show(n);
    return page;
  }

  function onScreen(r) {
    return r.width > 0 && r.height > 0 && r.right > 0 && r.left < width() && r.bottom > 0 && r.top < height();
  }

  // The first box of the selection, or its last one, if it is on this page.
  function endRect(last) {
    if (!selA || !selB) return null;
    var pieces = flow.querySelectorAll('span.picked[data-wrap]');
    var boxes = [];
    for (var i = 0; i < pieces.length; i++) {
      var rects = pieces[i].getClientRects();
      for (var j = 0; j < rects.length; j++) if (onScreen(rects[j])) boxes.push(rects[j]);
    }
    if (!boxes.length) return null;
    return last ? boxes[boxes.length - 1] : boxes[0];
  }

  // Where the handle points into the text.
  function tip(end, r) {
    if (vertical()) return end === 'start' ? [r.left + r.width / 2, r.top + 2] : [r.left + r.width / 2, r.bottom - 2];
    return end === 'start' ? [r.left + 2, r.top + r.height / 2] : [r.right - 2, r.top + r.height / 2];
  }

  function placeHandle(end) {
    var el = handles[end];
    var r = endRect(end === 'end');
    if (!r) {
      el.style.display = 'none';
      return;
    }
    var s = el.offsetWidth || 40;
    var x;
    var y;
    if (vertical()) {
      x = end === 'start' ? r.right : r.left - s;
      y = end === 'start' ? r.top - s : r.bottom;
    } else {
      x = end === 'start' ? r.left - s : r.right;
      y = end === 'start' ? r.top - s : r.bottom;
    }
    x = Math.max(0, Math.min(width() - s, x));
    y = Math.max(0, Math.min(height() - s, y));
    el.style.left = x + 'px';
    el.style.top = y + 'px';
    el.style.display = 'block';
  }

  function placeHandles() {
    placeHandle('start');
    placeHandle('end');
  }

  // Off during a drag, so the caret lookup sees the text under the handle's tip.
  function handlesTouchable(on) {
    handles.start.style.pointerEvents = on ? 'auto' : 'none';
    handles.end.style.pointerEvents = on ? 'auto' : 'none';
  }

  function sentenceAt(x, y) {
    var stack = document.elementsFromPoint ? document.elementsFromPoint(x, y) : [document.elementFromPoint(x, y)];
    for (var i = 0; i < stack.length; i++) {
      var el = stack[i];
      if (!el || (el.classList && el.classList.contains('reader-handle'))) continue;
      var hit = el.closest ? el.closest('[data-sid]') : null;
      if (!hit) continue;
      var id = parseInt(hit.getAttribute('data-sid'), 10);
      if (!isNaN(id)) return id;
    }
    return -1;
  }

  function isLetter(ch) { return /[A-Za-z]/.test(ch); }
  function isWord(ch) { return /[A-Za-z'\u2019\-]/.test(ch); }

  function englishAt(x, y) {
    if (!document.caretRangeFromPoint) return '';
    var range = document.caretRangeFromPoint(x, y);
    if (!range || !range.startContainer || range.startContainer.nodeType !== 3) return '';
    var text = range.startContainer.textContent || '';
    var i = range.startOffset;
    if (i >= text.length) i = text.length - 1;
    if (i < 0) return '';
    if (!isLetter(text.charAt(i))) {
      if (i > 0 && isLetter(text.charAt(i - 1))) i = i - 1;
      else return '';
    }
    var a = i;
    var b = i + 1;
    while (a > 0 && isWord(text.charAt(a - 1))) a = a - 1;
    while (b < text.length && isWord(text.charAt(b))) b = b + 1;
    var word = text.slice(a, b);
    return isLetter(word.charAt(0)) ? word : '';
  }

  function isNoteLink(link) {
    if (link.classList && link.classList.contains('ref')) return true;
    var type = link.getAttribute('epub:type') || '';
    return type.indexOf('noteref') >= 0 || (link.getAttribute('href') || '').indexOf('#') >= 0;
  }

  // Note numbers are small. Look a little around the finger for one.
  function linkAt(x, y) {
    var d = 12;
    var spots = [[0, 0], [0, -d], [0, d], [-d, 0], [d, 0], [-d, -d], [d, -d], [-d, d], [d, d]];
    for (var i = 0; i < spots.length; i++) {
      var el = document.elementFromPoint(x + spots[i][0], y + spots[i][1]);
      var link = el && el.closest ? el.closest('a[href]') : null;
      if (!link) continue;
      if (i > 0 && !isNoteLink(link)) continue;
      return link;
    }
    return null;
  }

  function zone(x) {
    var w = width();
    if (x < w / 3) return 'left';
    if (x > w * 2 / 3) return 'right';
    return 'center';
  }

  function corner(x, y) {
    var box = 64;
    if (x <= box && y <= box) return 'prev';
    if (x >= width() - box && y >= height() - box) return 'next';
    return '';
  }

  viewport.addEventListener('pointerdown', function (e) {
    if (e.button != null && e.button !== 0) return;
    pressing = true;
    longOn = false;
    moved = false;
    fixed = null;
    pressSid = -1;
    grabX = 0;
    grabY = 0;
    downX = e.clientX;
    downY = e.clientY;
    lastCorner = '';
    window.clearTimeout(timer);
    window.clearInterval(cornerTimer);
    var end = e.target && e.target.getAttribute ? e.target.getAttribute('data-end') : null;
    if (end && selA) {
      // Dragging one handle keeps the other end fixed.
      var r = endRect(end === 'end');
      if (r) {
        var t = tip(end, r);
        grabX = t[0] - e.clientX;
        grabY = t[1] - e.clientY;
      }
      longOn = true;
      fixed = end === 'start' ? selB : selA;
      handlesTouchable(false);
      return;
    }
    timer = window.setTimeout(function () {
      if (!pressing || moved) return;
      var word = englishAt(downX, downY);
      if (word) {
        longOn = true;
        post({type: 'lookup', word: word});
        return;
      }
      var id = sentenceAt(downX, downY);
      if (id < 0) return;
      longOn = true;
      pressSid = id;
      selectSentence(id);
    }, 450);
  });

  viewport.addEventListener('pointermove', function (e) {
    if (!pressing) return;
    if (!longOn) {
      if (Math.abs(e.clientX - downX) > 12 || Math.abs(e.clientY - downY) > 12) {
        moved = true;
        window.clearTimeout(timer);
      }
      return;
    }
    var hit = corner(e.clientX, e.clientY);
    if (hit) {
      if (hit !== lastCorner) {
        lastCorner = hit;
        window.clearInterval(cornerTimer);
        post({type: 'corner', dir: hit});
        cornerTimer = window.setInterval(function () { post({type: 'corner', dir: hit}); }, 700);
      }
      return;
    }
    lastCorner = '';
    window.clearInterval(cornerTimer);
    var x = e.clientX + grabX;
    var y = e.clientY + grabY;
    if (fixed) {
      var at = caretAt(x, y, cmp({s: sentenceAt(x, y), o: 0}, fixed) >= 0);
      if (!at || cmp(at, fixed) === 0) return;
      var lo = cmp(at, fixed) < 0 ? at : fixed;
      var hi = cmp(at, fixed) < 0 ? fixed : at;
      if (selA && selB && cmp(lo, selA) === 0 && cmp(hi, selB) === 0) return;
      select(lo, hi);
      return;
    }
    if (pressSid < 0) return;
    // A drag right after the long press keeps the whole first sentence and reaches out by character.
    var head = {s: pressSid, o: 0};
    var tail = {s: pressSid, o: sidLength(pressSid)};
    var spot = caretAt(x, y, sentenceAt(x, y) >= pressSid);
    if (!spot) return;
    var a = cmp(spot, head) < 0 ? spot : head;
    var b = cmp(spot, tail) > 0 ? spot : tail;
    if (selA && selB && cmp(a, selA) === 0 && cmp(b, selB) === 0) return;
    select(a, b);
  });

  function sendLink(link) {
    var href = link.getAttribute('href') || '';
    try { href = new URL(href, document.baseURI).href; } catch (err) {}
    post({type: 'link', href: href});
  }

  function endPress(x, y) {
    window.clearTimeout(timer);
    window.clearInterval(cornerTimer);
    if (!pressing) return;
    var wasLong = longOn;
    pressing = false;
    longOn = false;
    handlesTouchable(true);
    if (wasLong) {
      post({type: 'selectEnd'});
      return;
    }
    if (moved) {
      var dx = x - downX;
      var dy = y - downY;
      if (Math.abs(dx) >= 40 && Math.abs(dx) > Math.abs(dy) * 1.2) post({type: 'swipe', dir: dx < 0 ? 'left' : 'right'});
      return;
    }
    if (speaking) {
      // While speech is on, a tap reads the sentence under the finger. Only a direct hit on a link follows it.
      var hitEl = document.elementFromPoint(x, y);
      var direct = hitEl && hitEl.closest ? hitEl.closest('a[href]') : null;
      if (direct) {
        sendLink(direct);
        return;
      }
      var sid = sentenceAt(x, y);
      if (sid >= 0) {
        post({type: 'speakAt', sid: sid});
        return;
      }
      post({type: 'tap', zone: 'center'});
      return;
    }
    var link = linkAt(x, y);
    if (link) {
      sendLink(link);
      return;
    }
    post({type: 'tap', zone: zone(x)});
  }

  viewport.addEventListener('pointerup', function (e) { endPress(e.clientX, e.clientY); });
  viewport.addEventListener('pointercancel', function () {
    window.clearTimeout(timer);
    window.clearInterval(cornerTimer);
    pressing = false;
    longOn = false;
    handlesTouchable(true);
  });

  document.addEventListener('click', function (e) {
    var target = e.target;
    var link = target && target.closest ? target.closest('a') : null;
    if (link) e.preventDefault();
  }, true);

  var scrollTimer = 0;
  viewport.addEventListener('scroll', function () {
    if (mode() !== 'scroll') return;
    // The handles are fixed to the screen. The text moves under them.
    if (selA) placeHandles();
    window.clearTimeout(scrollTimer);
    scrollTimer = window.setTimeout(function () {
      var at = vertical() ? Math.abs(viewport.scrollLeft) / width() : viewport.scrollTop / height();
      var n = Math.max(0, Math.min(pages - 1, Math.round(at)));
      if (n === page) return;
      page = n;
      post({type: 'page', page: page, pages: pages, first: firstIdFrom(sidPage)});
    }, 300);
  });

  window.addEventListener('resize', function () { boot(true); });

  window.reader = {
    pages: function () { return pages; },
    boot: function (keep) { boot(!!keep); return page; },
    setPage: function (n) { show(n | 0); return page; },
    goSentence: function (id) {
      var n = sidPage[String(id)];
      if (n == null) {
        indexPages();
        n = sidPage[String(id)];
      }
      show(n == null ? 0 : n);
      return page;
    },
    pageOf: function (id) {
      var n = sidPage[String(id)];
      return n == null ? -1 : n;
    },
    // Stay on this page when any part of the sentence is on it.
    speakPage: function (id) {
      var n = sidPage[String(id)];
      if (n == null) return -1;
      var last = sidLast[String(id)];
      if (last != null && page >= n && page <= last) return page;
      return n;
    },
    setSpeaking: function (on) { speaking = !!on; },
    firstOnPage: function () { return firstIdFrom(sidPage); },
    pageOfAnchor: function (id) { return pageOfElement(byId(id)); },
    // [n] counts img and svg image elements in document order, as the images list in Dart does.
    pageOfImage: function (n) { return pageOfElement(flow.querySelectorAll('img, image')[n | 0]); },
    goImage: function (n) {
      var at = pageOfElement(flow.querySelectorAll('img, image')[n | 0]);
      if (at < 0) return -1;
      show(at);
      return page;
    },
    goAnchor: function (id) {
      var n = pageOfElement(byId(id));
      if (n < 0) return -1;
      show(n);
      return page;
    },
    found: function (id) { paint('found', id, id); },
    clearFound: function () { paint('found', -1, -1); },
    highlight: function (id) {
      unwrap('word');
      paint('reading', id, id);
    },
    clearHighlight: function () {
      unwrap('word');
      paint('reading', -1, -1);
    },
    // [start, end) counts characters of the spoken text of sentence [id].
    word: function (id, start, end) {
      unwrap('word');
      var map = spokenMap(id);
      var a = map.lead + start;
      var b = map.lead + end - 1;
      if (start < 0 || end <= start || b >= map.at.length) return page;
      wrap('word', {s: id, o: map.at[a]}, {s: id, o: map.at[b] + 1});
      return followWord();
    },
    clearSelect: function () {
      unwrap('picked');
      fixed = null;
      pressSid = -1;
      selA = null;
      selB = null;
      placeHandles();
    },
    // Each item is [start sentence, start offset, end sentence, end offset]. An end offset below 0 is the sentence end.
    marks: function (list) {
      unwrap('marked');
      for (var i = 0; i < list.length; i++) {
        var m = list[i];
        var b = {s: m[2], o: m[3] < 0 ? sidLength(m[2]) : m[3]};
        wrap('marked', {s: m[0], o: m[1]}, b);
      }
      placeHandles();
    }
  };
})();
''';
