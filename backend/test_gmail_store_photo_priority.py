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


# Every verified email from the same order must supply eligible pictures.
# Merchant priority affects ORDER only, not completeness. Courier PODs and
# other shops are excluded even if their emails were searched.
all_rows, backup, rule = select(shein, 'SHEIN')
assert rule == 'shein_predelivery_first'
assert [m['id'] for m in all_rows] == ['shein-pre', 'shein-order', 'shein-newer']
assert backup == []
assert fields(all_rows) == (['watch.jpg', 'dress.jpg', 'ad.jpg'], [])

all_rows, backup, rule = select(temu, 'Temu')
assert rule == 'temu_latest_first'
assert [m['id'] for m in all_rows] == ['temu-last', 'temu-old']
assert backup == []
assert fields(all_rows) == (['latest_product.jpg', 'older_product.jpg'], [])

# Same photo repeated in multiple purchase mails is added just once.
repeated = [
    mail('temu-two', 'Temu', 400, 'Your order details', ['latest_product.jpg', 'another.jpg']),
    *temu,
]
selected, _, _ = select(repeated, 'Temu')
assert fields(selected) == (['latest_product.jpg', 'another.jpg', 'older_product.jpg'], [])

only_courier = [m for m in temu if m['id'] in ('temu-pod', 'carrier')]
primary, backup, rule = select(only_courier, 'Temu')
assert primary == [] and backup == []
assert rule == 'temu_no_store_photo'

other_rows, backup, rule = select(shein, 'Amazon')
assert [m['id'] for m in other_rows] == ['shein-newer', 'shein-pre', 'shein-order']
assert rule == 'all_verified_emails'

# Store mail via alternate sender still supplies product photos when the
# verified tracking/order subject identifies the retailer.
alternate = mail('shein-alias', 'Order Updates', 700,
                 'SHEIN order details for your shipment', ['watch_from_alias.jpg'])
primary, backup, rule = select([alternate], 'SHEIN')
assert [m['id'] for m in primary] == ['shein-alias']
assert rule == 'shein_subject_photo_fallback'
assert fields(primary)[0] == ['watch_from_alias.jpg']
# Do not accidentally accept another merchant or delivery-proof photo.
unrelated = mail('other', 'Order Updates', 705, 'Temu special offer', ['other.jpg'])
primary, _, rule = select([unrelated], 'SHEIN')
assert primary == [] and rule == 'shein_no_store_photo'
proof = mail('proof', 'Order Updates', 710, 'SHEIN delivery photo', ['porch.jpg'], is_proof=True)
primary, _, rule = select([proof], 'SHEIN')
assert primary == [] and rule == 'shein_no_store_photo'

assert "'photoSourceRule': photo_rule" in code

assert "'emailPhotoUrls': urls[:60]" in code
print('SHEIN/Temu all matched emails, safe sender selection and photo dedup passed.')
