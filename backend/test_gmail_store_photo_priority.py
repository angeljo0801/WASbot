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
          '_select_primary_product_photo_source', '_source_photo_fields',
          '_photo_merchant_from_verified_records'}
nodes = [n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name in wanted]
assert len(nodes) == 5
scope = {
    'Any': Any,
    'store_name': lambda rows: 'Amazon',  # Mimic misleading body-text detection.
    're': re,
    '_COURIER_SENDER': re.compile(r'(?i)(?:gofo|speedx|fedex|ontrac|ups\.com|usps|dhl)'),
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
merchant = scope['_photo_merchant_from_verified_records']

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
    # Real Sep 25 Temu email: delivery pictures AND the product in Package info.
    mail('temu-pod', 'Temu', 400, 'Your Temu order delivered notification',
         ['house.jpg', 'doorstep.jpg', 'tracking_label.jpg', 'shirt.jpg'],
         is_proof=True),
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


# SHEIN: choose only its pre-delivery email. Do not combine its watch with
# the dress/order confirmation or the newer promotional email.
primary, backup, rule = select(shein, 'SHEIN')
assert rule == 'shein_predelivery_first'
assert [m['id'] for m in primary] == ['shein-pre']
assert [m['id'] for m in backup] == ['shein-order', 'shein-newer']
assert fields(primary) == (['watch.jpg'], [])
assert all('porch.jpg' not in fields([m])[0] for m in backup)

# If no pre-delivery email exists, SHEIN uses its oldest email with images.
primary, backup, rule = select([m for m in shein if m['id'] != 'shein-pre'], 'SHEIN')
assert [m['id'] for m in primary] == ['shein-order']
assert [m['id'] for m in backup] == ['shein-newer']
assert fields(primary) == (['dress.jpg'], [])

# The latest Temu email is an official delivery confirmation. Unlike a GOFO
# courier notice, it INCLUDES the real shirt in its "Package info" section.
# Retain all photos within THIS ONE email, never photos from previous receipts.
primary, backup, rule = select(temu, 'Temu')
assert rule == 'temu_latest_first'
assert [m['id'] for m in primary] == ['temu-pod']
assert backup == [], 'Temu must not fall back to an old order email'
assert fields(primary) == (
    ['house.jpg', 'doorstep.jpg', 'tracking_label.jpg', 'shirt.jpg'], []
)

# Multiple photos in the one selected message are allowed, but the same
# photo in older emails must not cause them to be mixed together.
repeated = [
    mail('temu-two', 'Temu', 400, 'Your order details',
         ['latest_product.jpg', 'another.jpg']),
    *temu,
]
primary, backup, rule = select(repeated, 'Temu')
assert [m['id'] for m in primary] == ['temu-two']
assert backup == [], 'No older Temu email fallback'
assert fields(primary) == (['latest_product.jpg', 'another.jpg'], [])

# Do not replace a newer Temu email with an older one when its CDN is broken.
# The job handler will return zero prepared images, never silently use old ones.
assert backup == []
assert "and not str(result.get('photoSourceRule') or '').startswith('temu_')" in code

only_courier = [m for m in temu if m['id'] == 'carrier']
primary, backup, rule = select(only_courier, 'Temu')
assert primary == [] and backup == []
assert rule == 'temu_no_store_photo'

# A Temu sender with delivery pictures is NOT a courier notification.
primary, backup, rule = select([temu[2], temu[3]], 'Temu')
assert [m['id'] for m in primary] == ['temu-pod']
assert backup == []
assert fields(primary)[0][-1] == 'shirt.jpg'

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
# Alternate sender respects SHEIN's pre-delivery / oldest preference as well.
alias_new = mail('shein-alias-new', 'Order Updates', 900,
                 'SHEIN shipment notice', ['newer_alias.jpg'])
alias_pre = mail('shein-alias-pre', 'Order Updates', 800,
                 'Notificación previa a la entrega de Pedido de SHEIN',
                 ['watch_alias.jpg'])
primary, backup, rule = select([alternate, alias_new, alias_pre], 'SHEIN')
assert [m['id'] for m in primary] == ['shein-alias-pre']
assert [m['id'] for m in backup] == ['shein-alias', 'shein-alias-new']
assert fields(primary)[0] == ['watch_alias.jpg']
primary, backup, rule = select([alternate, alias_new], 'SHEIN')
assert [m['id'] for m in primary] == ['shein-alias']
assert [m['id'] for m in backup] == ['shein-alias-new']

alias_temu_early = mail('temu-alias-old', 'Order Updates', 100,
                        'Temu order', ['old_alias_temu.jpg'])
alias_temu_new = mail('temu-alias-new', 'Order Updates', 200,
                      'Temu shipped', ['new_alias_temu.jpg'])
primary, backup, rule = select([alias_temu_early, alias_temu_new], 'Temu')
assert [m['id'] for m in primary] == ['temu-alias-new']
assert backup == []

# The newest email may be an order update from an alternative Temu sender,
# even when earlier emails have a normal @temu.com domain.
mixed_newest = mail('temu-newest-alt', 'Order Updates', 900,
                    'Temu items in your order', ['correct_newest.jpg'])
primary, backup, rule = select([*temu, mixed_newest], 'Temu')
assert [m['id'] for m in primary] == ['temu-newest-alt']
assert backup == []
assert fields(primary)[0] == ['correct_newest.jpg']
assert rule == 'temu_latest_first'

# An even newer VERIFIED Temu email with NO images is authoritative.
# Never fall back to older purchase images, even if they are available.
temu_latest_no_images = mail(
    'temu-newest-without-images', 'Temu', 1500,
    'Your Temu order update', [],
)
primary, backup, rule = select([*temu, mixed_newest, temu_latest_no_images], 'Temu')
assert [m['id'] for m in primary] == ['temu-newest-without-images']
assert backup == []
assert fields(primary) == ([], [])
assert rule == 'temu_latest_first'

# A later courier notice cannot outrank the Temu delivery message.
courier_new = mail('courier-new', 'GOFO', 1200,
                   'Delivered - Temu order', ['front_porch.jpg'], is_proof=True)
primary, backup, rule = select([*temu, mixed_newest, courier_new], 'Temu')
assert [m['id'] for m in primary] == ['temu-newest-alt']
assert backup == []


# A Temu email might mention "Amazon" inside a promotional footer.
# Store identity must come from actual Temu sender or verified subject.
confirmed_temu = mail('new-temu', 'Temu', 1800, 'Temu order update',
                       ['temu_latest_item.jpg'])
confirmed_temu['body'] = 'Other brands include Amazon Walmart and SHEIN.'
assert merchant([confirmed_temu]) == 'Temu'
assert select([confirmed_temu], merchant([confirmed_temu]))[0][0]['id'] == 'new-temu'
alias_temu = mail('new-temu-alias', 'Order Updates', 1900,
                  'Temu order update', ['alias_item.jpg'])
alias_temu['body'] = 'Amazon Walmart footer'
assert merchant([alias_temu]) == 'Temu'
# Do not infer Temu only because a courier writes it in the delivery body.
carrier_brand = mail('courier-brand', 'GOFO', 2000, 'Delivered',
                     ['porch.jpg'], is_proof=True)
carrier_brand['body'] = 'Temu package delivered'
assert merchant([carrier_brand]) != 'Temu'

# Regression: marking every image inside a Temu delivery notice as courier
# proof would reject the purchased shirt even after selecting the right email.
assert "merchant.lower() != 'temu'" in code
assert "_COURIER_SENDER.search(str(row.get('from') or ''))" in code

# Do not accidentally accept another merchant or delivery-proof photo.
unrelated = mail('other', 'Order Updates', 705, 'Temu special offer', ['other.jpg'])
primary, _, rule = select([unrelated], 'SHEIN')
assert primary == [] and rule == 'shein_no_store_photo'
proof = mail('proof', 'Order Updates', 710, 'SHEIN delivery photo', ['porch.jpg'], is_proof=True)
primary, _, rule = select([proof], 'SHEIN')
assert primary == [] and rule == 'shein_no_store_photo'

assert "'photoSourceRule': photo_rule" in code
assert "'photoSearchScope': (" in code
assert "'single_priority_email'" in code
assert "'photoSourceMessageId':" in code
assert "[],  # Critical: NO older-email image fallback for Temu." in code

assert "'emailPhotoUrls': urls[:60]" in code
print('SHEIN prioritizes pre-delivery; Temu newest only with no older fallback, including alternate sender.')
