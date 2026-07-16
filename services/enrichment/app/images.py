import hashlib
from io import BytesIO

from PIL import Image, UnidentifiedImageError


class InvalidReceiptImage(ValueError):
    pass


def verify_webp(image_bytes: bytes, expected_sha256: str, expected_bytes: int, maximum_bytes: int) -> None:
    if not image_bytes or len(image_bytes) != expected_bytes or len(image_bytes) > maximum_bytes:
        raise InvalidReceiptImage("image_size_mismatch")
    if hashlib.sha256(image_bytes).hexdigest() != expected_sha256:
        raise InvalidReceiptImage("image_checksum_mismatch")
    try:
        with Image.open(BytesIO(image_bytes)) as image:
            if image.format != "WEBP":
                raise InvalidReceiptImage("image_format_not_webp")
            image.verify()
    except (UnidentifiedImageError, OSError) as error:
        raise InvalidReceiptImage("image_decode_failed") from error


def webp_to_png(image_bytes: bytes) -> bytes:
    try:
        with Image.open(BytesIO(image_bytes)) as image:
            image.load()
            converted = image.convert("RGB")
            output = BytesIO()
            converted.save(output, format="PNG", optimize=True)
            return output.getvalue()
    except (UnidentifiedImageError, OSError) as error:
        raise InvalidReceiptImage("image_conversion_failed") from error
