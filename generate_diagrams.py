import os
from PIL import Image, ImageDraw, ImageFont

os.makedirs("scratch", exist_ok=True)

def get_font(size, bold=False):
    try:
        font_name = "segoeuib.ttf" if bold else "segoeui.ttf"
        return ImageFont.truetype(font_name, size)
    except:
        try:
            font_name = "arialbd.ttf" if bold else "arial.ttf"
            return ImageFont.truetype(font_name, size)
        except:
            return ImageFont.load_default()

def draw_rounded_box(draw, xy, bg_color, border_color=None, border_width=2, radius=12):
    draw.rounded_rectangle(xy, radius=radius, fill=bg_color, outline=border_color, width=border_width)

def draw_arrow(draw, start, end, color=(148, 163, 184), width=3, arrow_size=10):
    draw.line([start, end], fill=color, width=width)
    x1, y1 = start
    x2, y2 = end
    if x1 == x2: # Vertical
        if y2 > y1:
            draw.polygon([(x2-arrow_size, y2-arrow_size), (x2+arrow_size, y2-arrow_size), (x2, y2)], fill=color)
        else:
            draw.polygon([(x2-arrow_size, y2+arrow_size), (x2+arrow_size, y2+arrow_size), (x2, y2)], fill=color)
    elif y1 == y2: # Horizontal
        if x2 > x1:
            draw.polygon([(x2-arrow_size, y2-arrow_size), (x2-arrow_size, y2+arrow_size), (x2, y2)], fill=color)
        else:
            draw.polygon([(x2+arrow_size, y2-arrow_size), (x2+arrow_size, y2+arrow_size), (x2, y2)], fill=color)

def generate_system_architecture():
    img = Image.new("RGBA", (1600, 900), (15, 23, 42, 255))
    draw = ImageDraw.Draw(img)
    
    font_title = get_font(32, bold=True)
    font_sub = get_font(18, bold=False)
    font_box_header = get_font(20, bold=True)
    font_box_body = get_font(15, bold=False)
    
    draw.text((60, 40), "Mobile ERP — Production System Architecture", fill=(248, 250, 252), font=font_title)
    draw.text((60, 85), "Fully Self-Hosted Stack on Single Debian VPS (38.47.191.226) with SSL Reverse Proxy", fill=(148, 163, 184), font=font_sub)
    
    # Column 1: Clients
    draw_rounded_box(draw, (60, 150, 340, 780), (30, 41, 59), (99, 102, 241), 2, 16)
    draw.text((80, 170), "CLIENT APPLICATIONS", fill=(129, 140, 248), font=font_box_header)
    
    clients = [
        ("Android Mobile App", "Flutter 3.x / Native APK\nBarcode Scan + Location"),
        ("Flutter Web App", "Nginx Served SPA Container\nHosted on port 8089"),
        ("Desktop Client", "Windows / macOS / Linux\nMulti-role dashboard")
    ]
    y_pos = 220
    for title, desc in clients:
        draw_rounded_box(draw, (80, y_pos, 320, y_pos + 150), (15, 23, 42), (71, 85, 105), 1, 10)
        draw.text((95, y_pos + 15), title, fill=(241, 245, 249), font=get_font(17, bold=True))
        draw.text((95, y_pos + 45), desc, fill=(148, 163, 184), font=font_box_body)
        y_pos += 180

    # Column 2: Reverse Proxy & Gateway
    draw_rounded_box(draw, (390, 150, 670, 780), (30, 41, 59), (59, 130, 246), 2, 16)
    draw.text((410, 170), "REVERSE PROXY & GATEWAY", fill=(96, 165, 250), font=font_box_header)
    
    proxy_boxes = [
        ("Nginx SSL Reverse Proxy", "mdhproduction.com (443)\nTLS Cert & Domain Routing"),
        ("Supabase Kong Gateway", "Port 8050 / 8000\nAPI Auth & Subpath Dispatcher"),
        ("Security & Auth Guard", "JWT Token Validation\nRate Limits & CORS Rules")
    ]
    y_pos = 220
    for title, desc in proxy_boxes:
        draw_rounded_box(draw, (410, y_pos, 650, y_pos + 150), (15, 23, 42), (71, 85, 105), 1, 10)
        draw.text((425, y_pos + 15), title, fill=(241, 245, 249), font=get_font(17, bold=True))
        draw.text((425, y_pos + 45), desc, fill=(148, 163, 184), font=font_box_body)
        y_pos += 180

    # Column 3: Self-Hosted Supabase Docker Stack
    draw_rounded_box(draw, (720, 150, 1180, 780), (30, 41, 59), (16, 185, 129), 2, 16)
    draw.text((740, 170), "SELF-HOSTED SUPABASE DOCKER STACK", fill=(52, 211, 153), font=font_box_header)
    
    baas_boxes = [
        ("PostgreSQL 15 Engine", "Multi-Tenant Schema, RLS Isolation,\nAtomic Stock RPC Functions"),
        ("PostgREST & Auth (GoTrue)", "Auto-generated REST APIs,\nRole-based JWT Session Tokens"),
        ("Edge Functions & PgNet", "Deno Serverless Functions,\nAsync Database HTTP Trigger Extensions"),
        ("Storage & Realtime Server", "Product Images, Receipts, Documents,\nLive WebSockets Sync")
    ]
    y_pos = 220
    for title, desc in baas_boxes:
        draw_rounded_box(draw, (740, y_pos, 1160, y_pos + 120), (15, 23, 42), (71, 85, 105), 1, 10)
        draw.text((755, y_pos + 15), title, fill=(241, 245, 249), font=get_font(17, bold=True))
        draw.text((755, y_pos + 45), desc, fill=(148, 163, 184), font=font_box_body)
        y_pos += 135

    # Column 4: External Integrations
    draw_rounded_box(draw, (1230, 150, 1540, 780), (30, 41, 59), (245, 158, 11), 2, 16)
    draw.text((1250, 170), "EXTERNAL INTEGRATIONS", fill=(251, 191, 36), font=font_box_header)
    
    ext_boxes = [
        ("Shopee Open Platform", "v2 Order & Payout API,\nAuto Stock Sync"),
        ("TikTok Shop API", "v2 Marketplace Orders,\nSettlement Sync"),
        ("QRIS Payment Gateway", "Dynamic QR Code Generation\nInstant Payment Callback"),
        ("OpenRouter AI Engine", "Smart Inventory Insights &\nDemand Forecasting")
    ]
    y_pos = 220
    for title, desc in ext_boxes:
        draw_rounded_box(draw, (1250, y_pos, 1520, y_pos + 120), (15, 23, 42), (71, 85, 105), 1, 10)
        draw.text((1265, y_pos + 15), title, fill=(241, 245, 249), font=get_font(17, bold=True))
        draw.text((1265, y_pos + 45), desc, fill=(148, 163, 184), font=font_box_body)
        y_pos += 135

    # Inter-column arrows
    draw_arrow(draw, (340, 465), (390, 465), (129, 140, 248), 3)
    draw_arrow(draw, (670, 465), (720, 465), (96, 165, 250), 3)
    draw_arrow(draw, (1180, 465), (1230, 465), (52, 211, 153), 3)
    
    img.save("scratch/system_architecture.png")
    print("Saved system_architecture.png")

def generate_er_diagram():
    img = Image.new("RGBA", (1600, 900), (15, 23, 42, 255))
    draw = ImageDraw.Draw(img)
    
    font_title = get_font(32, bold=True)
    font_sub = get_font(18, bold=False)
    font_box_header = get_font(20, bold=True)
    font_box_body = get_font(14, bold=False)
    
    draw.text((60, 40), "Mobile ERP — Simplified Relational ER Diagram", fill=(248, 250, 252), font=font_title)
    draw.text((60, 85), "PostgreSQL Database Schema with Multi-Tenant RLS & Marketplace Mapping Entities", fill=(148, 163, 184), font=font_sub)

    tables = [
        ("tenants / clients", 80, 160, [
            "id (UUID, PK)",
            "name (VARCHAR)",
            "subscription_status",
            "created_at (TIMESTAMPTZ)"
        ], (99, 102, 241)),
        
        ("user_roles / permissions", 80, 480, [
            "id (UUID, PK)",
            "user_id (UUID, FK -> auth.users)",
            "tenant_id (UUID, FK -> tenants)",
            "role (enum: admin, staff, driver)",
            "permissions (JSONB)"
        ], (99, 102, 241)),
        
        ("stock_items (Master Inventory)", 540, 160, [
            "id (UUID, PK)",
            "tenant_id (UUID, FK -> tenants)",
            "sku_code (VARCHAR, UNIQUE)",
            "item_name (VARCHAR)",
            "current_stock (INT4)",
            "hpp_cogs (NUMERIC)",
            "selling_price (NUMERIC)"
        ], (16, 185, 129)),
        
        ("sku_mappings", 540, 520, [
            "id (UUID, PK)",
            "marketplace_account_id (FK)",
            "marketplace_sku (VARCHAR)",
            "local_stock_item_id (FK)",
            "mapping_multiplier (INT)"
        ], (245, 158, 11)),
        
        ("marketplace_accounts", 1020, 160, [
            "id (UUID, PK)",
            "tenant_id (UUID, FK)",
            "platform (enum: Shopee, TikTok)",
            "shop_id / shop_name",
            "access_token / refresh_token"
        ], (245, 158, 11)),

        ("orders & order_items", 1020, 480, [
            "id (UUID, PK)",
            "tenant_id (UUID, FK)",
            "marketplace_order_sn (VARCHAR)",
            "order_status (VARCHAR)",
            "total_amount (NUMERIC)",
            "payout_status (VARCHAR)"
        ], (59, 130, 246)),
        
        ("finance_payouts", 1020, 700, [
            "id (UUID, PK)",
            "order_id (UUID, FK -> orders)",
            "payout_amount (NUMERIC)",
            "escrow_release_date",
            "reconciliation_flag (BOOL)"
        ], (236, 72, 153))
    ]

    for title, x, y, fields, border_color in tables:
        draw_rounded_box(draw, (x, y, x + 380, y + 50 + len(fields) * 28), (30, 41, 59), border_color, 2, 12)
        draw.text((x + 15, y + 12), title, fill=(241, 245, 249), font=font_box_header)
        draw.line([(x + 10, y + 45), (x + 370, y + 45)], fill=border_color, width=1)
        fy = y + 55
        for field in fields:
            draw.text((x + 15, fy), "• " + field, fill=(226, 232, 240), font=font_box_body)
            fy += 26

    # Draw relationships
    draw_arrow(draw, (270, 310), (270, 480), (148, 163, 184), 2)
    draw_arrow(draw, (460, 240), (540, 240), (148, 163, 184), 2)
    draw_arrow(draw, (730, 440), (730, 520), (148, 163, 184), 2)
    draw_arrow(draw, (920, 280), (1020, 280), (148, 163, 184), 2)
    draw_arrow(draw, (1210, 330), (1210, 480), (148, 163, 184), 2)
    draw_arrow(draw, (1210, 640), (1210, 700), (148, 163, 184), 2)

    img.save("scratch/database_er_diagram.png")
    print("Saved database_er_diagram.png")

def generate_data_flow_diagram():
    img = Image.new("RGBA", (1600, 900), (15, 23, 42, 255))
    draw = ImageDraw.Draw(img)
    
    font_title = get_font(32, bold=True)
    font_sub = get_font(18, bold=False)
    font_box_header = get_font(20, bold=True)
    font_box_body = get_font(14, bold=False)
    
    draw.text((60, 40), "Mobile ERP — Marketplace Order & Stock Sync Flow", fill=(248, 250, 252), font=font_title)
    draw.text((60, 85), "End-to-End Automated Data Flow from Shopee/TikTok Order Trigger to Database Stock Lock & Settlement Audit", fill=(148, 163, 184), font=font_sub)

    steps = [
        ("Step 1: Marketplace Event", "Shopee / TikTok Shop\nOrder Created / Webhook Trigger", (60, 250, 320, 450), (245, 158, 11)),
        ("Step 2: Sync Worker Processing", "Python Worker / PgNet Extension\nParses Payload & Validates HMAC", (380, 250, 640, 450), (59, 130, 246)),
        ("Step 3: SKU Mapping Lookup", "Queries sku_mappings Table\nTranslates Channel SKU -> Local Master SKU", (700, 250, 960, 450), (16, 185, 129)),
        ("Step 4: Atomic Stock RPC Call", "Invokes PostgreSQL RPC Function\nApplies Row Lock & Reduces Quantity", (1020, 250, 1280, 450), (99, 102, 241)),
        ("Step 5: Settlement & Finance Audit", "Populates finance_payouts Table\nUpdates App UI via Realtime WebSockets", (1340, 250, 1560, 450), (236, 72, 153))
    ]

    for title, desc, (x1, y1, x2, y2), border_color in steps:
        draw_rounded_box(draw, (x1, y1, x2, y2), (30, 41, 59), border_color, 2, 14)
        draw.text((x1 + 15, y1 + 20), title, fill=(241, 245, 249), font=font_box_header)
        draw.line([(x1 + 10, y1 + 55), (x2 - 10, y1 + 55)], fill=border_color, width=1)
        draw.text((x1 + 15, y1 + 75), desc, fill=(148, 163, 184), font=font_box_body)

    draw_arrow(draw, (320, 350), (380, 350), (148, 163, 184), 3)
    draw_arrow(draw, (640, 350), (700, 350), (148, 163, 184), 3)
    draw_arrow(draw, (960, 350), (1020, 350), (148, 163, 184), 3)
    draw_arrow(draw, (1280, 350), (1340, 350), (148, 163, 184), 3)

    draw_rounded_box(draw, (60, 530, 1560, 780), (30, 41, 59), (71, 85, 105), 1, 14)
    draw.text((90, 560), "Key Operational Benefits & System Guarantees:", fill=(129, 140, 248), font=font_box_header)
    bullets = [
        "1. Zero Race Conditions: PostgreSQL PL/pgSQL RPC transactions lock target stock rows atomically during high-volume sales.",
        "2. Multi-Store SKU Federation: One local Master SKU can map to multiple Shopee and TikTok store listings seamlessly.",
        "3. Automated Financial Reconciliation: Payout dates, escrow status, and commission fees are auto-audited against bank settlements."
    ]
    by = 610
    for b in bullets:
        draw.text((90, by), b, fill=(226, 232, 240), font=get_font(16, bold=False))
        by += 45

    img.save("scratch/data_flow_diagram.png")
    print("Saved data_flow_diagram.png")

if __name__ == "__main__":
    generate_system_architecture()
    generate_er_diagram()
    generate_data_flow_diagram()
