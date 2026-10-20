import math
import struct
import zlib

def write_png(filename, width, height, rgba_data):
    def chunk(chunk_type, data):
        return (
            struct.pack('>I', len(data))
            + chunk_type
            + data
            + struct.pack('>I', zlib.crc32(chunk_type + data) & 0xFFFFFFFF)
        )

    raw_data = bytearray()
    for y in range(height):
        raw_data.append(0)  # Filter type 0 (None)
        raw_data.extend(rgba_data[y * width * 4 : (y + 1) * width * 4])

    compressed = zlib.compress(bytes(raw_data), 9)
    ihdr = struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0)

    png = (
        b'\x89PNG\r\n\x1a\n'
        + chunk(b'IHDR', ihdr)
        + chunk(b'IDAT', compressed)
        + chunk(b'IEND', b'')
    )
    with open(filename, 'wb') as f:
        f.write(png)

# Heroicon Lightning Bolt polygon in 24x24 viewBox:
# M13 10V3L4 14h7v7l9-11h-7z
POLY = [(13.0, 3.0), (4.0, 14.0), (11.0, 14.0), (11.0, 21.0), (20.0, 10.0), (13.0, 10.0)]

def point_in_poly(px, py, poly):
    inside = False
    n = len(poly)
    p1x, p1y = poly[0]
    for i in range(1, n + 1):
        p2x, p2y = poly[i % n]
        if py > min(p1y, p2y) and py <= max(p1y, p2y):
            if px <= max(p1x, p2x):
                if p1y != p2y:
                    xinters = (py - p1y) * (p2x - p1x) / (p2y - p1y) + p1x
                if p1x == p2x or px <= xinters:
                    inside = not inside
        p1x, p1y = p2x, p2y
    return inside

def generate_badge(size, filename):
    """
    Android Web Push badge specification:
    Alpha mask ONLY. Completely transparent background, pure white icon.
    """
    scale = (size * 0.72) / 18.0
    s_steps = 4  # 4x4 supersampling
    rgba = bytearray(size * size * 4)

    for y in range(size):
        for x in range(size):
            inside_count = 0
            for sy in range(s_steps):
                sample_y = y + (sy + 0.5) / s_steps
                gy = 12.0 + (sample_y - size / 2.0) / scale
                for sx in range(s_steps):
                    sample_x = x + (sx + 0.5) / s_steps
                    gx = 12.0 + (sample_x - size / 2.0) / scale
                    if point_in_poly(gx, gy, POLY):
                        inside_count += 1

            coverage = inside_count / (s_steps * s_steps)
            idx = (y * size + x) * 4
            if coverage > 0:
                alpha = int(round(coverage * 255))
                rgba[idx : idx + 4] = bytearray([255, 255, 255, alpha])
            else:
                rgba[idx : idx + 4] = bytearray([0, 0, 0, 0])

    write_png(filename, size, size, rgba)
    print(f"Generated badge: {filename} ({size}x{size})")

def generate_app_icon(size, filename):
    """
    Full-color PWA & Notification Icon:
    - Rich gradient background (Indigo-600 #4F46E5 to Indigo-950 #1E1B4B)
    - Electric amber lightning bolt with gradient & subtle shadow
    """
    scale = (size * 0.62) / 18.0
    s_steps = 4
    rgba = bytearray(size * size * 4)

    # Pre-render supersampled coverage
    for y in range(size):
        ny = y / float(size)
        for x in range(size):
            nx = x / float(size)
            idx = (y * size + x) * 4

            # Background gradient from top-left to bottom-right
            t = (nx + ny) / 2.0
            # Indigo-600 (79, 70, 229) to Indigo-950 (30, 27, 75)
            bg_r = int(79 * (1 - t) + 30 * t)
            bg_g = int(70 * (1 - t) + 27 * t)
            bg_b = int(229 * (1 - t) + 75 * t)

            inside_count = 0
            shadow_count = 0
            # Shadow offset in grid coordinates
            shadow_dy = 0.5
            shadow_dx = 0.2

            for sy in range(s_steps):
                sample_y = y + (sy + 0.5) / s_steps
                gy = 12.0 + (sample_y - size / 2.0) / scale
                for sx in range(s_steps):
                    sample_x = x + (sx + 0.5) / s_steps
                    gx = 12.0 + (sample_x - size / 2.0) / scale

                    if point_in_poly(gx, gy, POLY):
                        inside_count += 1
                    elif point_in_poly(gx - shadow_dx, gy - shadow_dy, POLY):
                        shadow_count += 1

            cov = inside_count / (s_steps * s_steps)
            shadow_cov = shadow_count / (s_steps * s_steps)

            if cov > 0:
                # Lightning bolt gradient: Amber-300 (252, 211, 77) to Orange-500 (249, 115, 22)
                bolt_t = max(0.0, min(1.0, (y / float(size) - 0.2) / 0.6))
                bolt_r = int(252 * (1 - bolt_t) + 249 * bolt_t)
                bolt_g = int(211 * (1 - bolt_t) + 115 * bolt_t)
                bolt_b = int(77 * (1 - bolt_t) + 22 * bolt_t)

                # Blend with background based on antialiasing coverage
                r = int(bolt_r * cov + bg_r * (1 - cov))
                g = int(bolt_g * cov + bg_g * (1 - cov))
                b = int(bolt_b * cov + bg_b * (1 - cov))
                rgba[idx : idx + 4] = bytearray([r, g, b, 255])
            elif shadow_cov > 0:
                # Soft shadow under bolt
                s_factor = 0.35 * shadow_cov
                r = int(bg_r * (1 - s_factor))
                g = int(bg_g * (1 - s_factor))
                b = int(bg_b * (1 - s_factor))
                rgba[idx : idx + 4] = bytearray([r, g, b, 255])
            else:
                rgba[idx : idx + 4] = bytearray([bg_r, bg_g, bg_b, 255])

    write_png(filename, size, size, rgba)
    print(f"Generated app icon: {filename} ({size}x{size})")

if __name__ == '__main__':
    generate_badge(72, 'priv/static/images/badge-72.png')
    generate_badge(96, 'priv/static/images/badge-96.png')
    generate_app_icon(192, 'priv/static/images/icon-192.png')
    generate_app_icon(512, 'priv/static/images/icon-512.png')
