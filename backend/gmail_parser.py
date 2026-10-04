import html
import re
from typing import Any


def _html_image_text(match: re.Match[str]) -> str:
    tag = match.group(0)
    for attr in ('alt', 'title'):
        found = re.search(
            rf'''(?is)\b{attr}\s*=\s*["']([^"']+)["']''',
            tag,
        )
        if found:
            text = html.unescape(found.group(1)).strip()
            if text:
                return f'\n{text}\n'
    return ' '


def strip_html(value: str) -> str:
    # Product names in commerce emails are frequently present only as image
    # alt/title text. Preserve those labels before dropping the HTML tags.
    value = re.sub(r'(?is)<img\b[^>]*>', _html_image_text, value)
    value = re.sub(r'(?is)<(script|style).*?>.*?</\1>', ' ', value)
    value = re.sub(r'(?i)<br\s*/?>', '\n', value)
    value = re.sub(r'(?i)</(p|div|tr|td|th|li|h[1-6])>', '\n', value)
    value = re.sub(r'(?is)<[^>]+>', ' ', value)
    value = html.unescape(value).replace('\r', '')
    value = re.sub(r'[ \t]+', ' ', value)
    return re.sub(r'\n\s*\n+', '\n', value).strip()


def remote_images(html_parts: list[str]) -> list[str]:
    out: list[str] = []
    for source in html_parts:
        for match in re.findall(r'''(?is)<img[^>]+src=["']([^"']+)''', source):
            url = html.unescape(match.strip())
            if url.startswith('http') and url not in out:
                out.append(url)
    return out[:60]


def store_name(records: list[dict[str, Any]]) -> str:
    text = ' '.join(
        f"{r.get('from','')} {r.get('subject','')} {r.get('body','')[:2000]}"
        for r in records
    ).lower()
    stores = [
        ('Amazon', ['amazon.com', 'amazon shipping']),
        ('Walmart', ['walmart.com', 'walmart']),
        ('SHEIN', ['shein.com', 'shein']),
        ('Temu', ['temu.com', 'temu']),
        ('AliExpress', ['aliexpress.com', 'aliexpress']),
        ('Target', ['target.com']),
        ('Best Buy', ['bestbuy.com', 'best buy']),
        ('eBay', ['ebay.com']),
        ('Etsy', ['etsy.com']),
        ('Nike', ['nike.com']),
        ('Adidas', ['adidas.com']),
        ('Apple', ['apple.com']),
    ]
    for name, needles in stores:
        if any(x in text for x in needles):
            return name
    sender = str(records[-1].get('from') if records else '')
    m = re.match(r'\s*([^<]+?)\s*<', sender)
    if m:
        return m.group(1).strip().strip('"')
    m = re.search(r'@([A-Za-z0-9.-]+)', sender)
    return m.group(1).split('.')[0].title() if m else ''


def money_field(text: str, labels: list[str]) -> float:
    label = '|'.join(re.escape(x) for x in labels)
    patterns = [
        rf'(?im)(?:{label})\s*[:\-]?\s*(?:USD\s*)?\$\s*([0-9][0-9,]*\.?[0-9]{{0,2}})',
        rf'(?im)(?:{label})\s*[:\-]?\s*([0-9][0-9,]*\.[0-9]{{2}})\s*(?:USD)?',
    ]
    for pattern in patterns:
        matches = re.findall(pattern, text)
        if matches:
            try:
                return float(matches[-1].replace(',', ''))
            except ValueError:
                pass
    return 0.0


def tracking_numbers(text: str) -> list[str]:
    patterns = [
        r'\b1Z[A-Z0-9]{16}\b',
        r'\bTBA[A-Z0-9]{8,24}\b',
        r'\bSPX[A-Z0-9]{8,24}\b',
        r'\bGFUS\d{14}\b',
        r'\b(?:94|93|92|95)\d{18,22}\b',
        r'\b[A-Z]{2}\d{9}[A-Z]{2}\b',
    ]
    out: list[str] = []
    upper = text.upper().replace('-', '')
    for pattern in patterns:
        for match in re.findall(pattern, upper):
            value = str(match).strip()
            if value and value not in out:
                out.append(value)
    return out


def carrier_for(tracking: str, text: str = '') -> str:
    t = re.sub(r'[^A-Z0-9]', '', tracking.upper())
    lower = text.lower()
    if t.startswith('1Z'):
        return 'UPS'
    if t.startswith('TBA'):
        return 'Amazon'
    if t.startswith('SPX') or 'speedx' in lower:
        return 'SpeedX'
    if t.startswith('GFUS') or re.search(r'\bgofo\b', lower):
        return 'GOFO'
    if re.fullmatch(r'(?:94|93|92|95)\d{18,22}', t):
        return 'USPS'
    if 'fedex' in lower:
        return 'FedEx'
    if 'ups' in lower:
        return 'UPS'
    if 'usps' in lower:
        return 'USPS'
    if 'dhl' in lower:
        return 'DHL'
    return 'Auto / Otro'


def order_number(text: str, preferred: str = '') -> str:
    if preferred.strip():
        return preferred.strip()
    for pattern in [
        r'(?im)\border(?:\s+number|\s+no\.?|\s+#|\s+id)?\s*[:#-]?\s*([A-Z0-9-]{5,40})',
        r'(?im)\bpedido(?:\s+n[uú]mero|\s+no\.?|\s+#)?\s*[:#-]?\s*([A-Z0-9-]{5,40})',
    ]:
        match = re.search(pattern, text)
        if match:
            return match.group(1).strip()
    return ''


def purchase_status(text: str) -> str:
    lower = text.lower()
    rules = [
        ('Cancelado', ['order canceled', 'order cancelled', 'pedido cancelado', 'refund issued']),
        ('Entregado', ['was delivered', 'has been delivered', 'delivered today', 'entregado']),
        ('Sale para entrega', ['out for delivery', 'sale para entrega']),
        ('En tránsito', ['in transit', 'on the way', 'has shipped', 'shipped', 'en camino', 'en tránsito']),
        ('Preparando envío', ['preparing to ship', 'preparing your order', 'getting your order ready']),
        ('Comprado', ['order confirmed', 'thanks for your order', 'order placed', 'pedido confirmado']),
    ]
    for status, needles in rules:
        if any(x in lower for x in needles):
            return status
    return 'Comprado'


def estimated_delivery(text: str) -> str:
    match = re.search(
        r'(?im)(?:estimated delivery|arriving|delivery date|entrega estimada|llega)\s*[:\-]?\s*([^\n]{3,45})',
        text,
    )
    return match.group(1).strip(' .') if match else ''


def ship_to(text: str) -> str:
    match = re.search(
        r'(?im)(?:ship to|shipping to|deliver to|entregar a|enviar a)\s*[:\-]?\s*([^\n]{2,80})',
        text,
    )
    return match.group(1).strip(' .') if match else ''


_PRICE = re.compile(
    r'(?i)(?:USD\s*)?\$\s*([0-9][0-9,]*\.[0-9]{2})|'
    r'\b([0-9][0-9,]*\.[0-9]{2})\s*USD\b'
)
_QTY = re.compile(
    r'(?i)(?:\bqty\.?|\bquantity|\bcantidad|\bquantit[yé])\s*[:#-]?\s*(\d{1,3})\b|'
    r'\b[x×]\s*(\d{1,3})\b|'
    r'\b(\d{1,3})\s*[x×]\b'
)


def _price(line: str) -> float:
    match = _PRICE.search(line)
    if not match:
        return 0.0
    raw = next((g for g in match.groups() if g), '')
    try:
        return float(raw.replace(',', ''))
    except ValueError:
        return 0.0


def _qty(line: str) -> int:
    match = _QTY.search(line)
    if not match:
        return 1
    raw = next((g for g in match.groups() if g), '1')
    try:
        value = int(raw)
    except ValueError:
        return 1
    return max(1, min(value, 999))


def _clean_item_name(value: str) -> str:
    value = _PRICE.sub(' ', value)
    value = _QTY.sub(' ', value)
    value = re.sub(
        r'(?i)\b(?:price|precio|unit price|item price|qty|quantity|cantidad)\s*[:#-]?\s*',
        ' ',
        value,
    )
    value = re.sub(r'\s+', ' ', value).strip(' -:|•·–—')
    return value


def _looks_like_item_name(value: str) -> bool:
    line = _clean_item_name(value)
    lower = line.lower()
    if len(line) < 3 or len(line) > 180:
        return False
    if not re.search(r'[A-Za-zÀ-ÿ]', line):
        return False
    if re.fullmatch(r'[A-Z0-9-]{8,}', line):
        return False
    if re.search(r'https?://|www\.|unsubscribe|view in browser', lower):
        return False
    blocked_exact = {
        'subtotal', 'tax', 'sales tax', 'shipping', 'delivery', 'discount',
        'total', 'order total', 'grand total', 'payment', 'payment method',
        'gift card', 'impuesto', 'envío', 'envio', 'descuento', 'tracking',
        'track package', 'track your package', 'view order', 'view more',
        'ver pedido', 'ver más', 'ver mas', 'download app', 'google play',
        'app store', 'bonus points', 'order summary', 'resumen del pedido',
        'ships from', 'sold by', 'color', 'size', 'talla', 'quantity',
        'cantidad', 'qty', 'free shipping', 'returns', 'return policy',
    }
    if lower in blocked_exact:
        return False
    blocked_fragments = (
        'privacy policy', 'terms of use', 'customer service', 'contact us',
        'download our app', 'get the app', 'manage preferences', 'copyright',
        'all rights reserved', 'estimated delivery', 'delivery date',
        'order number', 'pedido número', 'pedido numero', 'tracking number',
        'shipping address', 'billing address', 'payment method',
    )
    if any(fragment in lower for fragment in blocked_fragments):
        return False
    return True


def items(text: str) -> list[dict[str, Any]]:
    # Commerce emails use many layouts. Some put product + price on one line,
    # others split name, quantity and price across adjacent table cells. Build
    # candidates from both forms and keep the maximum quantity seen so repeated
    # confirmation/shipping/delivery emails do not multiply the order quantity.
    lines = [re.sub(r'\s+', ' ', raw).strip() for raw in text.splitlines()]
    lines = [line for line in lines if line]
    found: dict[str, dict[str, Any]] = {}
    order: list[str] = []

    def add(name_raw: str, *, price: float = 0.0, qty: int = 1) -> None:
        name = _clean_item_name(name_raw)
        if not _looks_like_item_name(name):
            return
        key = re.sub(r'[^a-z0-9]+', ' ', name.lower()).strip()
        if not key:
            return
        if key not in found:
            found[key] = {
                'name': name,
                'price': round(max(0.0, price), 2),
                'qty': max(1, qty),
                'received': False,
                'source': 'gmail',
            }
            order.append(key)
        else:
            row = found[key]
            row['qty'] = max(int(row.get('qty') or 1), max(1, qty))
            if float(row.get('price') or 0) <= 0 and price > 0:
                row['price'] = round(price, 2)

    # Name/price/quantity on the same line.
    for line in lines:
        price = _price(line)
        if price > 0:
            candidate = _clean_item_name(line)
            if _looks_like_item_name(candidate):
                add(candidate, price=price, qty=_qty(line))

    # Quantity attached to a product name even when price is elsewhere/missing.
    for line in lines:
        if not _QTY.search(line):
            continue
        candidate = _clean_item_name(line)
        if _looks_like_item_name(candidate):
            add(candidate, price=_price(line), qty=_qty(line))

    # Split table cells: infer product name from nearby lines around a price or
    # quantity marker. This catches common Amazon/Walmart/SHEIN/Temu templates.
    for i, line in enumerate(lines):
        has_price = _price(line) > 0
        has_qty = bool(_QTY.search(line))
        if not has_price and not has_qty:
            continue
        price = _price(line)
        qty = _qty(line)
        candidates: list[str] = []
        for distance in (1, 2, 3):
            before = i - distance
            if before >= 0:
                candidates.append(lines[before])
        if i + 1 < len(lines):
            candidates.append(lines[i + 1])
        for candidate_line in candidates:
            candidate = _clean_item_name(candidate_line)
            if _looks_like_item_name(candidate):
                nearby = ' '.join(lines[max(0, i - 2): min(len(lines), i + 3)])
                add(candidate, price=price or _price(nearby), qty=max(qty, _qty(nearby)))
                break

    # Very common "2 x Product name" / "Product name x2" lines without a
    # price. Require the explicit quantity marker to keep false positives low.
    for line in lines:
        match = re.match(r'(?i)^\s*(\d{1,3})\s*[x×]\s+(.+)$', line)
        if match:
            add(match.group(2), qty=int(match.group(1)), price=_price(line))
            continue
        match = re.match(r'(?i)^(.+?)\s+[x×]\s*(\d{1,3})\s*$', line)
        if match:
            add(match.group(1), qty=int(match.group(2)), price=_price(line))

    return [found[key] for key in order[:80]]
