"""Regression tests for retailer-specific Gmail product photo email priority.

No Gmail credentials, private messages, or live requests needed.
"""
import ast
import re
from pathlib import Path
from typing import Any

code = Path(__file__).with_name('gmail_reconstruction.py').read_text(encoding='utf-8')
tree = ast.parse(code)
wanted = {'_shein_predelivery_notice', '_rank_product_photo_messages',
          '_select_primary_product_photo_source', '_source_photo_fields'}
nodes = [n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name in wanted]
assert len(nodes) == 4
scope = {
    'Any': Any,
    '_merchant_family': lambda sender: next(
        (x for x in ('shein', 'temu') if x in sender.lower()), ''
    ),
    '_delivery_proof_message': lambda row: (
        row.get('isProof') is True
    ),
}
exec(compile(ast.Module(body=nodes, type_ignores=[]), 'photo_priority', 'exec'), scope)
rank = scope['_rank_product_photo_messages']
select = scope['_select_primary_product_photo_source']
fields = scope['_source_photo_fields']
pre = scope['_shein_predelivery_notice']

def mail(key, shop, date, subject, images=None, is_proof=False):
    return {
        'id': key, 'accountId': 1, 'internalDate': date,
        'from': f'{shop} <support@{shop.lower()}.com>',
        'subject': subject,
        'remoteImages': images or [],
        'attachmentImages': [],
        'isProof': is_proof,
    }

shein = [
    mail('shein-order', 'SHEIN', 100, 'Order confirmation', ['dress.jpg']),
    mail('shein-pre', 'SHEIN', 200, 'Notificación previa a la entrega de Pedido de SHEIN', ['watch.jpg']),
    mail('shein-newer', 'SHEIN', 300, 'Order on its way', ['ad.jpg']),
    mail('courier', 'GOFO', 400, 'Delivered', ['porch.jpg'], is_proof=True),
]
assert pre(shein[1])
assert not pre(shein[0])
ranked, rule = rank(shein, 'SHEIN')
assert rule == 'shein_predelivery_first', rule
assert [x['id'] for x in ranked] == ['shein-pre', 'shein-order', 'shein-newer', 'courier']

# Without a pre-delivery message, the earliest SHEIN email has priority,
# but all verified product images are still available.
fallback = [x for x in shein if x['id'] != 'shein-pre']
ranked, rule = rank(fallback, 'SHEIN')
assert [x['id'] for x in ranked] == ['shein-order', 'shein-newer', 'courier']
assert rule == 'shein_predelivery_first'

temu = [
    mail('temu-old', 'Temu', 100, 'Order confirmed', ['older_product.jpg']),
    mail('temu-last', 'Temu', 300, 'Your order has shipped', ['latest_product.jpg']),
    mail('temu-pod', 'Temu', 400, 'Proof of delivery', ['house.jpg'], is_proof=True),
    mail('carrier', 'GOFO', 500, 'Delivered', ['address.jpg'], is_proof=True),
    mail('other-shop', 'SHEIN', 600, 'A different shop', ['unrelated.jpg']),
]
ranked, rule = rank(temu, 'Temu')
assert rule == 'temu_latest_first'
assert [x['id'] for x in ranked] == [
    'temu-last', 'temu-old', 'other-shop', 'carrier', 'temu-pod'
], [x['id'] for x in ranked]

# Unknown merchants preserve original (newest first) behavior.
ranked, rule = rank(shein, 'Amazon')
assert rule == 'recent_first'
assert [x['id'] for x in ranked] == [
    'courier', 'shein-newer', 'shein-pre', 'shein-order'
]

# One missing preferred image shouldn't block fallback to older valid mail.
ranked, rule = rank([x for x in temu if x['id'] != 'temu-last'], 'Temu')
assert ranked[0]['id'] == 'temu-old'


# Priority is not enough: only the CHOSEN email may supply photographs.
# All related messages remain useful for order metadata, but must NOT
# contribute their images to this list unless the source has zero usable media.
primary, backup, rule = select(shein, 'SHEIN')
assert rule == 'shein_predelivery_first'
assert [m['id'] for m in primary] == ['shein-pre']
assert [m['id'] for m in backup] == ['shein-order', 'shein-newer']
assert fields(primary) == (['watch.jpg'], []), fields(primary)

primary, backup, rule = select(temu, 'Temu')
assert rule == 'temu_latest_first'
assert [m['id'] for m in primary] == ['temu-last']
assert [m['id'] for m in backup] == ['temu-old']
assert fields(primary) == (['latest_product.jpg'], []), fields(primary)

# Never quietly use delivery-location images when no verified store email.
only_courier = [m for m in temu if m['id'] in ('temu-pod', 'carrier')]
primary, backup, rule = select(only_courier, 'Temu')
assert primary == [] and backup == []
assert rule == 'temu_no_store_photo'

# Unknown stores still use legacy source inclusion.
primary, backup, rule = select(shein, 'Amazon')
assert len(primary) == len(shein) and not backup

# Fallback order remains available if (and only if) the first email
# contains no usable images after thumbnailing/verification.
single, rest, _ = select([m for m in temu if m['id'] != 'temu-last'], 'Temu')
assert single[0]['id'] == 'temu-old' and rest == []

assert "'photoSourceRule': photo_rule" in code
assert "'_photoFallbackGroups': [" in code
assert "if result.get('found') and not result['emailPhotoCandidates']:" in code

assert "'emailPhotoUrls': urls[:60]" in code
print('SHEIN/Temu strict single-source photo isolation and backup checks passed.')
