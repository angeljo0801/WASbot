import html
import re
from typing import Any


def strip_html(value: str) -> str:
    value = re.sub(r'(?is)<(script|style).*?>.*?</\1>', ' ', value)
    value = re.sub(r'(?i)<br\s*/?>', '\n', value)
    value = re.sub(r'(?i)</(p|div|tr|li|h[1-6])>', '\n', value)
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


def items(text: str) -> list[dict[str, Any]]:
    blocked = ('subtotal', 'tax', 'shipping', 'discount', 'total', 'payment', 'gift card', 'impuesto', 'envío')
    result: list[dict[str, Any]] = []
    seen: set[str] = set()
    for raw in text.splitlines():
        line = re.sub(r'\s+', ' ', raw).strip()
        if len(line) < 5 or len(line) > 220:
            continue
        if any(x in line.lower() for x in blocked):
            continue
        match = re.search(r'(.{3,160}?)\s+(?:USD\s*)?\$\s*([0-9][0-9,]*\.[0-9]{2})(?:\s*[x×]\s*(\d+))?\s*$', line)
        if not match:
            continue
        name = re.sub(r'\s+', ' ', match.group(1)).strip(' -:|•')
        key = name.lower()
        if len(name) < 3 or key in seen:
            continue
        try:
            price = float(match.group(2).replace(',', ''))
        except ValueError:
            continue
        if price <= 0:
            continue
        seen.add(key)
        result.append({
            'name': name,
            'price': price,
            'qty': int(match.group(3) or 1),
            'received': False,
        })
        if len(result) >= 80:
            break
    return result
