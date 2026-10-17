"""Offline proof-of-delivery photo provenance regression tests.

Does not access Gmail or user data. Tests require both positive and
negative carrier/retailer examples.
"""
import ast
import re
from pathlib import Path

source = Path(__file__).with_name("gmail_reconstruction.py").read_text()
tree = ast.parse(source)
wanted = {"_delivery_proof_message", "_delivery_photo_urls"}
nodes = [x for x in tree.body if isinstance(x, ast.FunctionDef) and x.name in wanted]
assert len(nodes) == len(wanted)
scope = {
    "re": re,
    "_POD_WORDS": re.compile(
        r"(?i)(?:proof\s+of\s+delivery|delivery\s+(?:photos?|pictures?|images?)|"
        r"(?:photos?|pictures?|images?)\s+(?:of|from)\s+(?:your|the)\s+delivery|"
        r"(?:delivered|drop[- ]?off)\s+(?:photos?|pictures?|images?)|"
        r"fotos?\s+de\s+(?:la\s+)?entrega|prueba\s+de\s+entrega)"
    ),
    "_COURIER_SENDER": re.compile(r"(?i)(?:gofo|speedx|ontrac|lasership|fedex|ups\.com|usps|dhl|amazonlogistics|amazon\.shipping|shippingcarrier)"),
    "_DELIVERED_EVENT": re.compile(r"(?i)(?:delivered|entregado|delivery\s+complete|left\s+(?:at|on|by)|delivered\s+to\s+your\s+door)")
}
exec(compile(ast.Module(body=nodes, type_ignores=[]), "delivery", "exec"), scope)
evidence = scope["_delivery_photo_urls"]([
    {"subject": "Your package has been delivered", "from": "GOFO <info@gofoexpress.com>",
     "body": "Delivered successfully", "remoteImages": ["https://example.com/door.jpg", "https://example.com/porch.jpg"]},
    {"subject": "Your order has been delivered", "from": "Temu <temu@temuemail.com>",
     "body": "Order #12345", "remoteImages": ["https://example.com/watch.jpg"]},
    {"subject": "Your order is confirmed", "from": "SHEIN <support@shein.com>",
     "body": "Your photo from product listing", "remoteImages": ["https://example.com/dress.jpg"]},
    {"subject": "A photo of your delivery", "from": "Any Shipper <noreply@example.com>",
     "body": "Proof of delivery", "attachmentImages": [{"url": "/api/gmail/media/dropoff.jpg"}]},
    {"subject": "UPS: Your package is out for delivery", "from": "UPS <alerts@ups.com>",
     "body": "Not yet delivered", "remoteImages": ["https://example.com/arrival.jpg"]},
])
assert evidence == ["https://example.com/door.jpg", "https://example.com/porch.jpg", "/api/gmail/media/dropoff.jpg"], evidence
assert "deliveryProofHint" in source and "'deliveryPhotoUrls': _delivery_photo_urls(records)" in source
print("Delivery photo provenance checks passed.")
