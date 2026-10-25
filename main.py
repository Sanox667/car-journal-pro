import csv
import json
import math
import os
import re
import sqlite3
import urllib.parse
import urllib.request
from datetime import datetime
import flet as ft

# ================= ПУТЬ К БАЗЕ ДАННЫХ (ANDROID / ПК) =================
APP_DIR = os.getenv("FLET_APP_STORAGE_DATA") or os.path.abspath(".")
os.makedirs(APP_DIR, exist_ok=True)
DB_PATH = os.path.join(APP_DIR, "car_journal_pro_mobile.db")

CENTER_ALIGN = getattr(ft.alignment, "center", None) or ft.Alignment(0, 0)

# Базовые средние цены по популярным сетям АЗС
DEFAULT_PRICES = {
    "Лукойл": {"АИ-92": 56.20, "АИ-95": 61.80, "АИ-100": 82.50, "ДТ": 69.90, "Газ": 29.50},
    "Газпромнефть": {"АИ-92": 55.40, "АИ-95": 60.50, "АИ-100": 80.90, "ДТ": 68.80, "Газ": 28.90},
    "Роснефть": {"АИ-92": 55.10, "АИ-95": 60.10, "АИ-100": 79.80, "ДТ": 68.40, "Газ": 28.50},
    "Татнефть": {"АИ-92": 54.90, "АИ-95": 59.90, "АИ-100": 79.50, "ДТ": 68.20, "Газ": 28.00},
    "Нефтьмагистраль": {"АИ-92": 55.30, "АИ-95": 60.40, "АИ-100": 79.90, "ДТ": 68.50, "Газ": 28.80},
    "Teboil": {"АИ-92": 55.90, "АИ-95": 61.40, "АИ-100": 81.90, "ДТ": 69.50, "Газ": 29.20},
    "Средняя по региону": {"АИ-92": 55.50, "АИ-95": 60.60, "АИ-100": 80.50, "ДТ": 68.90, "Газ": 28.90},
}


# ================= БАЗА ДАННЫХ (SQLite3) =================
def init_db():
    with sqlite3.connect(DB_PATH) as conn:
        c = conn.cursor()
        c.execute("""
            CREATE TABLE IF NOT EXISTS settings (
                key TEXT PRIMARY KEY,
                value TEXT
            )
        """)
        c.execute("""
            CREATE TABLE IF NOT EXISTS cars (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT,
                service_interval INTEGER DEFAULT 10000,
                last_service_odo INTEGER DEFAULT 0
            )
        """)
        c.execute("""
            CREATE TABLE IF NOT EXISTS refuelings (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                car_id INTEGER,
                date TEXT,
                odometer INTEGER,
                liters REAL,
                cost REAL,
                is_full INTEGER DEFAULT 1,
                fuel_type TEXT DEFAULT 'АИ-95',
                mode TEXT DEFAULT 'Смешанный',
                station_name TEXT DEFAULT '',
                lat REAL DEFAULT 0.0,
                lon REAL DEFAULT 0.0,
                address TEXT DEFAULT ''
            )
        """)
        existing_cols = [row[1] for row in c.execute("PRAGMA table_info(refuelings)").fetchall()]
        for col_name, col_type in [
            ("station_name", "TEXT DEFAULT ''"),
            ("lat", "REAL DEFAULT 0.0"),
            ("lon", "REAL DEFAULT 0.0"),
            ("address", "TEXT DEFAULT ''"),
        ]:
            if col_name not in existing_cols:
                c.execute(f"ALTER TABLE refuelings ADD COLUMN {col_name} {col_type}")

        c.execute("""
            CREATE TABLE IF NOT EXISTS expenses (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                car_id INTEGER,
                date TEXT,
                category TEXT,
                cost REAL,
                comment TEXT
            )
        """)
        c.execute("""
            CREATE TABLE IF NOT EXISTS fuel_prices (
                station_brand TEXT,
                fuel_type TEXT,
                price REAL,
                PRIMARY KEY (station_brand, fuel_type)
            )
        """)
        for brand, fuels in DEFAULT_PRICES.items():
            for f_type, pr in fuels.items():
                c.execute(
                    "INSERT OR IGNORE INTO fuel_prices (station_brand, fuel_type, price) VALUES (?, ?, ?)",
                    (brand, f_type, pr),
                )
        conn.commit()


def get_fuel_price_db(station_brand: str, fuel_type: str) -> float:
    brand_key = "Средняя по региону"
    for known in DEFAULT_PRICES:
        if known.lower() in (station_brand or "").lower():
            brand_key = known
            break

    with sqlite3.connect(DB_PATH) as conn:
        row = conn.execute(
            "SELECT price FROM fuel_prices WHERE station_brand = ? AND fuel_type = ?",
            (brand_key, fuel_type),
        ).fetchone()
        if row:
            return row[0]
    return DEFAULT_PRICES["Средняя по региону"].get(fuel_type, 60.0)


def update_fuel_price_db(station_brand: str, fuel_type: str, price_per_liter: float):
    if price_per_liter <= 10 or price_per_liter > 250:
        return
    brand_key = "Средняя по региону"
    for known in DEFAULT_PRICES:
        if known.lower() in (station_brand or "").lower():
            brand_key = known
            break

    with sqlite3.connect(DB_PATH) as conn:
        conn.execute(
            "INSERT OR REPLACE INTO fuel_prices (station_brand, fuel_type, price) VALUES (?, ?, ?)",
            (brand_key, fuel_type, round(price_per_liter, 2)),
        )
        conn.commit()


# ================= ГЕОЛОКАЦИЯ И ПОИСК АЗС =================
def detect_brand_name(raw_name: str) -> str:
    low = (raw_name or "").lower()
    mapping = {
        "лукойл": "Лукойл",
        "lukoil": "Лукойл",
        "газпром": "Газпромнефть",
        "gazprom": "Газпромнефть",
        "роснефть": "Роснефть",
        "rosneft": "Роснефть",
        "татнефть": "Татнефть",
        "tatneft": "Татнефть",
        "нефтьмагистраль": "Нефтьмагистраль",
        "teboil": "Teboil",
        "тебойл": "Teboil",
    }
    for k, v in mapping.items():
        if k in low:
            return v
    return raw_name.strip() if raw_name.strip() else "Средняя по региону"


def haversine_m(lat1: float, lon1: float, lat2: float, lon2: float) -> int:
    r = 6371000
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp = math.radians(lat2 - lat1)
    dl = math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return int(2 * r * math.atan2(math.sqrt(a), math.sqrt(1 - a)))


def fetch_ip_location() -> tuple[float, float, str]:
    req = urllib.request.Request(
        "http://ip-api.com/json/?fields=status,lat,lon,city,regionName&lang=ru",
        headers={"User-Agent": "CarJournalPro/1.0"},
    )
    with urllib.request.urlopen(req, timeout=5) as resp:
        data = json.loads(resp.read().decode("utf-8"))
        if data.get("status") == "success":
            city = data.get("city") or data.get("regionName") or ""
            return float(data["lat"]), float(data["lon"]), city
    raise RuntimeError("Не удалось получить координаты")


def find_nearest_gas_station(lat: float, lon: float) -> dict:
    station_brand = "Средняя по региону"
    distance_m = None
    address_str = f"{lat:.4f}, {lon:.4f}"

    try:
        overpass_query = f'[out:json][timeout:6];node["amenity"="fuel"](around:2500,{lat},{lon});out body;'
        url = "https://overpass-api.de/api/interpreter?data=" + urllib.parse.quote(overpass_query)
        req = urllib.request.Request(url, headers={"User-Agent": "CarJournalPro/1.0"})
        with urllib.request.urlopen(req, timeout=6) as resp:
            osm_data = json.loads(resp.read().decode("utf-8"))
            elements = osm_data.get("elements", [])
            if elements:
                elements.sort(key=lambda el: haversine_m(lat, lon, el.get("lat", lat), el.get("lon", lon)))
                nearest = elements[0]
                tags = nearest.get("tags", {})
                raw_station = tags.get("brand") or tags.get("name") or tags.get("operator") or "АЗС"
                station_brand = detect_brand_name(raw_station)
                distance_m = haversine_m(lat, lon, nearest.get("lat", lat), nearest.get("lon", lon))
                lat, lon = float(nearest.get("lat", lat)), float(nearest.get("lon", lon))
    except Exception:
        pass

    try:
        nom_url = f"https://nominatim.openstreetmap.org/reverse?format=json&lat={lat}&lon={lon}&zoom=18&accept-language=ru"
        req = urllib.request.Request(nom_url, headers={"User-Agent": "CarJournalPro/1.0"})
        with urllib.request.urlopen(req, timeout=5) as resp:
            nom_data = json.loads(resp.read().decode("utf-8"))
            addr = nom_data.get("address", {})
            city = addr.get("city") or addr.get("town") or addr.get("village") or addr.get("state") or ""
            road = addr.get("road") or ""
            house = addr.get("house_number") or ""
            parts = [p for p in [city, road, house] if p]
            if parts:
                address_str = ", ".join(parts)
            if station_brand == "Средняя по региону" and nom_data.get("name"):
                station_brand = detect_brand_name(nom_data.get("name"))
    except Exception:
        pass

    dist_suffix = f" ({distance_m} м)" if distance_m is not None else ""
    display_station = f"{station_brand}{dist_suffix}" if station_brand != "Средняя по региону" else "АЗС по геолокации"

    return {
        "brand": station_brand,
        "display_name": display_station,
        "address": address_str,
        "lat": lat,
        "lon": lon,
    }


def get_active_car() -> tuple[int, str, int, int]:
    with sqlite3.connect(DB_PATH) as conn:
        c = conn.cursor()
        c.execute("SELECT value FROM settings WHERE key = 'active_car_id'")
        row = c.fetchone()
        if row:
            c.execute(
                "SELECT id, name, service_interval, last_service_odo FROM cars WHERE id = ?",
                (int(row[0]),),
            )
            car = c.fetchone()
            if car:
                return car

        c.execute("SELECT id, name, service_interval, last_service_odo FROM cars LIMIT 1")
        car = c.fetchone()
        if not car:
            c.execute(
                "INSERT INTO cars (name, service_interval, last_service_odo) VALUES ('Моё авто', 10000, 0)"
            )
            car_id = c.lastrowid
            c.execute(
                "INSERT OR REPLACE INTO settings (key, value) VALUES ('active_car_id', ?)",
                (str(car_id),),
            )
            conn.commit()
            return (car_id, "Моё авто", 10000, 0)

        c.execute(
            "INSERT OR REPLACE INTO settings (key, value) VALUES ('active_car_id', ?)",
            (str(car[0]),),
        )
        conn.commit()
        return car


def set_active_car_db(car_id: int):
    with sqlite3.connect(DB_PATH) as conn:
        conn.execute(
            "INSERT OR REPLACE INTO settings (key, value) VALUES ('active_car_id', ?)",
            (str(car_id),),
        )
        conn.commit()


def get_all_cars_db():
    with sqlite3.connect(DB_PATH) as conn:
        return conn.execute(
            "SELECT id, name, service_interval, last_service_odo FROM cars ORDER BY id ASC"
        ).fetchall()


def add_car_db(name: str, interval: int) -> int:
    with sqlite3.connect(DB_PATH) as conn:
        c = conn.cursor()
        c.execute(
            "INSERT INTO cars (name, service_interval, last_service_odo) VALUES (?, ?, 0)",
            (name, interval),
        )
        car_id = c.lastrowid
        c.execute(
            "INSERT OR REPLACE INTO settings (key, value) VALUES ('active_car_id', ?)",
            (str(car_id),),
        )
        conn.commit()
        return car_id


def update_service_db(car_id: int, last_odo: int, interval: int):
    with sqlite3.connect(DB_PATH) as conn:
        conn.execute(
            "UPDATE cars SET last_service_odo = ?, service_interval = ? WHERE id = ?",
            (last_odo, interval, car_id),
        )
        conn.commit()


def get_last_refueling(car_id: int):
    with sqlite3.connect(DB_PATH) as conn:
        return conn.execute(
            "SELECT id, odometer, liters, cost, date, is_full FROM refuelings "
            "WHERE car_id = ? ORDER BY odometer DESC LIMIT 1",
            (car_id,),
        ).fetchone()


def get_all_refuelings(car_id: int):
    with sqlite3.connect(DB_PATH) as conn:
        return conn.execute(
            "SELECT id, date, odometer, liters, cost, is_full, fuel_type, mode, station_name, lat, lon, address "
            "FROM refuelings WHERE car_id = ? ORDER BY odometer ASC",
            (car_id,),
        ).fetchall()


def add_refueling_db(
    car_id: int,
    odo: int,
    liters: float,
    cost: float,
    is_full: int,
    fuel: str,
    mode: str,
    station_name: str = "",
    lat: float = 0.0,
    lon: float = 0.0,
    address: str = "",
    custom_date: str = None,
):
    dt = custom_date or datetime.now().strftime("%Y-%m-%d %H:%M")
    with sqlite3.connect(DB_PATH) as conn:
        conn.execute(
            "INSERT INTO refuelings "
            "(car_id, date, odometer, liters, cost, is_full, fuel_type, mode, station_name, lat, lon, address) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (car_id, dt, odo, liters, cost, is_full, fuel, mode, station_name, lat, lon, address),
        )
        conn.commit()


def delete_refueling_db(rec_id: int):
    with sqlite3.connect(DB_PATH) as conn:
        conn.execute("DELETE FROM refuelings WHERE id = ?", (rec_id,))
        conn.commit()


def add_expense_db(car_id: int, category: str, cost: float, comment: str, custom_date: str = None):
    dt = custom_date or datetime.now().strftime("%Y-%m-%d %H:%M")
    with sqlite3.connect(DB_PATH) as conn:
        conn.execute(
            "INSERT INTO expenses (car_id, date, category, cost, comment) VALUES (?, ?, ?, ?, ?)",
            (car_id, dt, category, cost, comment),
        )
        conn.commit()


def get_all_expenses(car_id: int):
    with sqlite3.connect(DB_PATH) as conn:
        return conn.execute(
            "SELECT id, date, category, cost, comment FROM expenses WHERE car_id = ? ORDER BY id DESC",
            (car_id,),
        ).fetchall()


def delete_expense_db(exp_id: int):
    with sqlite3.connect(DB_PATH) as conn:
        conn.execute("DELETE FROM expenses WHERE id = ?", (exp_id,))
        conn.commit()


def clear_car_history_db(car_id: int):
    with sqlite3.connect(DB_PATH) as conn:
        conn.execute("DELETE FROM refuelings WHERE car_id = ?", (car_id,))
        conn.execute("DELETE FROM expenses WHERE car_id = ?", (car_id,))
        conn.commit()


def load_demo_data_db(car_id: int):
    clear_car_history_db(car_id)
    update_service_db(car_id, 140000, 10000)

    demo_refuels = [
        (143100, 40.0, 2420.0, 1, "АИ-95", "Смешанный", "Газпромнефть", 55.8941, 37.4432, "Химки, Ленинградское ш.", "2026-09-28 10:15"),
        (143600, 45.5, 2811.9, 1, "АИ-95", "Город", "Лукойл", 55.7558, 37.6173, "Москва, Олимпийский пр-т", "2026-10-05 18:40"),
        (144150, 37.4, 2247.7, 1, "АИ-95", "Трасса", "Роснефть", 55.9912, 37.2145, "Зеленоград, М-10", "2026-10-12 08:30"),
        (144680, 47.2, 2850.9, 1, "АИ-95", "Город", "Нефтьмагистраль", 55.6890, 37.8920, "Люберцы, Новорязанское ш.", "2026-10-18 09:15"),
        (145200, 42.5, 2571.2, 1, "АИ-95", "Смешанный", "Газпромнефть", 55.8941, 37.4432, "Химки, Ленинградское ш.", "2026-10-25 14:20"),
    ]
    for odo, lit, cost, is_f, fuel, mode, st, lat, lon, addr, dt in demo_refuels:
        add_refueling_db(car_id, odo, lit, cost, is_f, fuel, mode, st, lat, lon, addr, dt)

    demo_expenses = [
        ("🔧 ТО и Запчасти", 6800.0, "Масло ДВС и фильтры", "2026-10-01 12:00"),
        ("🚿 Мойка", 950.0, "Комплексная мойка кузова и салона", "2026-10-14 19:20"),
        ("📄 Страховка", 8400.0, "Полис ОСАГО", "2026-10-20 11:00"),
    ]
    for cat, cost, comm, dt in demo_expenses:
        add_expense_db(car_id, cat, cost, comm, dt)


def calculate_consumption_points(records: list) -> list[dict]:
    if len(records) < 2:
        return []

    points = []
    last_full_odo = records[0][2]
    acc_liters = 0.0
    acc_cost = 0.0

    for r in records[1:]:
        _, date_str, odo, liters, cost, is_full, fuel_type, mode, st_name, _, _, _ = r
        acc_liters += liters
        acc_cost += cost

        if is_full == 1 and odo > last_full_odo:
            dist = odo - last_full_odo
            cons = (acc_liters / dist) * 100
            points.append({
                "date": date_str,
                "odometer": odo,
                "distance": dist,
                "liters": acc_liters,
                "cost": acc_cost,
                "consumption": cons,
                "price_per_liter": cost / liters if liters else 0,
                "mode": mode,
                "fuel_type": fuel_type,
                "station": st_name,
            })
            last_full_odo = odo
            acc_liters = 0.0
            acc_cost = 0.0

    return points


def make_btn(text: str, on_click, bg_color="#2563EB", text_color="#FFFFFF", expand=False):
    return ft.Container(
        content=ft.Text(
            text,
            color=text_color,
            weight=ft.FontWeight.BOLD,
            size=12.5,
            text_align=ft.TextAlign.CENTER,
        ),
        bgcolor=bg_color,
        padding=ft.padding.symmetric(vertical=10, horizontal=12),
        border_radius=10,
        alignment=CENTER_ALIGN,
        on_click=on_click,
        expand=expand,
    )


def main(page: ft.Page):
    init_db()

    page.title = "Бортовой Журнал PRO + GPS"
    page.bgcolor = "#0F172A"
    page.padding = 0

    try:
        page.window.width = 430
        page.window.height = 880
    except Exception:
        pass

    geolocator = None
    if hasattr(ft, "Geolocator"):
        try:
            geolocator = ft.Geolocator()
            page.overlay.append(geolocator)
        except Exception:
            geolocator = None

    state = {
        "tab_index": 0,
        "fuel_type": "АИ-95",
        "mode": "Смешанный",
        "is_full": True,
        "exp_category": "🔧 ТО и Запчасти",
        "station_brand": "Газпромнефть",
        "station_display": "Газпромнефть",
        "address": "Геолокация не запрошена",
        "lat": 0.0,
        "lon": 0.0,
        "odo_draft": "",
        "liters_draft": "",
    }

    banner_text = ft.Text("", color="#FFFFFF", size=13, weight=ft.FontWeight.W_500)
    banner_box = ft.Container(
        content=banner_text,
        bgcolor="#10B981",
        padding=ft.padding.symmetric(vertical=8, horizontal=14),
        border_radius=8,
        margin=ft.margin.only(left=12, right=12, top=6),
        visible=False,
    )

    def notify(msg: str, is_error: bool = False):
        banner_text.value = msg
        banner_box.bgcolor = "#EF4444" if is_error else "#10B981"
        banner_box.visible = True
        page.update()

    header_car_title = ft.Text("", size=17, weight=ft.FontWeight.BOLD, color="#F8FAFC")
    header_to_badge = ft.Text("", size=12, color="#10B981")

    header = ft.Container(
        bgcolor="#1E293B",
        padding=ft.padding.symmetric(vertical=14, horizontal=16),
        content=ft.Row(
            alignment=ft.MainAxisAlignment.SPACE_BETWEEN,
            controls=[
                ft.Column(spacing=2, controls=[header_car_title, header_to_badge]),
                make_btn("Сменить", lambda e: switch_tab(3), bg_color="#334155"),
            ],
        ),
    )

    body_scroll = ft.Column(
        expand=True,
        scroll=ft.ScrollMode.ADAPTIVE,
        spacing=12,
    )
    body_wrapper = ft.Container(
        expand=True,
        padding=ft.padding.symmetric(horizontal=12, vertical=8),
        content=body_scroll,
    )

    def update_header():
        car_id, car_name, interval, last_service_odo = get_active_car()
        last_ref = get_last_refueling(car_id)
        curr_odo = last_ref[1] if last_ref else 0

        header_car_title.value = f"{car_name} ({curr_odo:,} км)".replace(",", " ")
        if last_service_odo > 0:
            rem = (last_service_odo + interval) - curr_odo
            if rem <= 0:
                header_to_badge.value = f"🚨 Срок замены масла превышен на {abs(rem)} км!"
                header_to_badge.color = "#EF4444"
            elif rem <= 1000:
                header_to_badge.value = f"⚠️ Скоро замена масла: через {rem} км"
                header_to_badge.color = "#F59E0B"
            else:
                header_to_badge.value = f"До замены масла: {rem:,} км".replace(",", " ")
                header_to_badge.color = "#10B981"
        else:
            header_to_badge.value = "Интервал ТО не задан (см. вкладку Гараж/ТО)"
            header_to_badge.color = "#94A3B8"

    def build_refuel_tab():
        car_id, _, _, _ = get_active_car()
        last_ref = get_last_refueling(car_id)
        prev_odo_hint = f"Предыдущий: {last_ref[1]} км" if last_ref else "Первая запись"

        auto_price = get_fuel_price_db(state["station_brand"], state["fuel_type"])

        quick_tf = ft.TextField(
            hint_text=f"145200 42.5 (цена {auto_price:.2f} ₽ подставится сама)",
            color="#FFFFFF",
            bgcolor="#0F172A",
            border_color="#334155",
            text_size=13,
            expand=True,
        )

        def save_quick(e):
            nums = re.findall(r"\d+(?:\.\d+)?", (quick_tf.value or "").replace(",", "."))
            if len(nums) not in (2, 3):
                notify("⚠️ Введите: Пробег Литры (или Пробег Литры Сумма)", True)
                return
            odo = int(float(nums[0]))
            liters = float(nums[1])
            val = float(nums[2]) if len(nums) == 3 else auto_price

            if last_ref and odo <= last_ref[1]:
                notify(f"⚠️ Пробег ({odo}) должен быть больше предыдущего ({last_ref[1]})!", True)
                return

            cost = round(val * liters, 2) if val < 250 else round(val, 2)
            price_per_l = cost / liters if liters else auto_price
            update_fuel_price_db(state["station_brand"], state["fuel_type"], price_per_l)

            add_refueling_db(
                car_id,
                odo,
                liters,
                cost,
                1,
                state["fuel_type"],
                state["mode"],
                state["station_brand"],
                state["lat"],
                state["lon"],
                state["address"],
            )
            pts = calculate_consumption_points(get_all_refuelings(car_id))
            cons_txt = f" | Расход: {pts[-1]['consumption']:.2f} л/100км" if pts else ""
            notify(f"⚡ Записано ({state['station_brand']}): {odo} км, {liters} л, {cost:.0f} ₽{cons_txt}")
            render_current_tab()

        quick_card = ft.Container(
            bgcolor="#1E293B",
            padding=12,
            border_radius=12,
            content=ft.Column(
                spacing=6,
                controls=[
                    ft.Text(
                        "⚡ Быстрый ввод (можно без цены — тариф АЗС подставится сам)",
                        size=12,
                        color="#94A3B8",
                        weight=ft.FontWeight.BOLD,
                    ),
                    ft.Row(controls=[quick_tf, make_btn("Ок", save_quick, bg_color="#10B981")]),
                ],
            ),
        )

        odo_tf = ft.TextField(
            label=f"Пробег, км ({prev_odo_hint})",
            value=state["odo_draft"],
            keyboard_type=ft.KeyboardType.NUMBER,
            color="#FFFFFF",
            bgcolor="#0F172A",
            border_color="#334155",
            on_change=lambda e: state.update({"odo_draft": e.control.value}),
        )
        liters_tf = ft.TextField(
            label="Литры (напр. 42.5)",
            value=state["liters_draft"],
            keyboard_type=ft.KeyboardType.NUMBER,
            color="#FFFFFF",
            bgcolor="#0F172A",
            border_color="#334155",
            expand=True,
            on_change=lambda e: state.update({"liters_draft": e.control.value}),
        )
        cost_tf = ft.TextField(
            label=f"Цена 1 л / Сумма ({state['station_brand']})",
            value=f"{auto_price:.2f}",
            keyboard_type=ft.KeyboardType.NUMBER,
            color="#38BDF8",
            bgcolor="#0F172A",
            border_color="#2563EB",
            expand=True,
        )

        station_tf = ft.TextField(
            label="Название АЗС (определяется по GPS или вручную)",
            value=state["station_brand"],
            color="#FFFFFF",
            bgcolor="#0F172A",
            border_color="#334155",
            text_size=13,
            on_change=lambda e: state.update({"station_brand": e.control.value}),
        )

        geo_status_txt = ft.Text(
            f"📍 Адрес: {state['address']}"
            + (f" ({state['lat']:.4f}, {state['lon']:.4f})" if state["lat"] else ""),
            size=11.5,
            color="#10B981" if state["lat"] else "#94A3B8",
        )

        async def handle_gps_click(e):
            notify("📡 Определяем координаты и ищем ближайшую АЗС...")
            lat, lon = None, None

            if geolocator is not None:
                try:
                    pos = await geolocator.get_current_position_async()
                    if pos and getattr(pos, "latitude", None):
                        lat, lon = float(pos.latitude), float(pos.longitude)
                except Exception:
                    pass

            if lat is None or lon is None:
                try:
                    lat, lon, _ = fetch_ip_location()
                except Exception as ex:
                    notify(f"⚠️ Ошибка геолокации: {ex}", True)
                    return

            info = find_nearest_gas_station(lat, lon)
            state["station_brand"] = info["brand"]
            state["station_display"] = info["display_name"]
            state["address"] = info["address"]
            state["lat"] = info["lat"]
            state["lon"] = info["lon"]

            new_price = get_fuel_price_db(state["station_brand"], state["fuel_type"])
            notify(
                f"📍 Найдена АЗС: {info['display_name']} ({info['address']}) | "
                f"Цена {state['fuel_type']}: {new_price:.2f} ₽/л подставлена!"
            )
            render_current_tab()

        popular_brands = ["Лукойл", "Газпромнефть", "Роснефть", "Татнефть", "Нефтьмагистраль", "Teboil"]

        def select_brand_chip(b_name: str):
            state["station_brand"] = b_name
            pr = get_fuel_price_db(b_name, state["fuel_type"])
            notify(f"⛽ Выбрана сеть «{b_name}» — цена {state['fuel_type']} ({pr:.2f} ₽/л) подставлена!")
            render_current_tab()

        brand_rows = [
            ft.Row(
                spacing=6,
                controls=[
                    make_btn(
                        b,
                        lambda e, x=b: select_brand_chip(x),
                        bg_color="#059669" if state["station_brand"] == b else "#334155",
                        expand=True,
                    )
                    for b in popular_brands[:3]
                ],
            ),
            ft.Row(
                spacing=6,
                controls=[
                    make_btn(
                        b,
                        lambda e, x=b: select_brand_chip(x),
                        bg_color="#059669" if state["station_brand"] == b else "#334155",
                        expand=True,
                    )
                    for b in popular_brands[3:]
                ],
            ),
        ]

        geo_card = ft.Container(
            bgcolor="#1E293B",
            padding=12,
            border_radius=12,
            content=ft.Column(
                spacing=8,
                controls=[
                    ft.Text("📍 Геолокация и автоподстановка цен АЗС", size=14, weight=ft.FontWeight.BOLD, color="#F8FAFC"),
                    make_btn("📡 Найти ближайшую АЗС по GPS и подставить цену", handle_gps_click, bg_color="#10B981"),
                    geo_status_txt,
                    ft.Text("Или выберите сеть АЗС в 1 клик:", size=11.5, color="#94A3B8"),
                    *brand_rows,
                    station_tf,
                ],
            ),
        )

        full_switch = ft.Switch(
            label="Заправка до полного бака",
            value=state["is_full"],
            on_change=lambda e: state.update({"is_full": e.control.value}),
        )

        fuels = ["АИ-92", "АИ-95", "АИ-100", "ДТ", "Газ"]
        modes = ["Город", "Трасса", "Смешанный"]

        def select_fuel(f):
            state["fuel_type"] = f
            render_current_tab()

        def select_mode(m):
            state["mode"] = m
            render_current_tab()

        fuel_chips = ft.Row(
            spacing=6,
            controls=[
                make_btn(
                    f,
                    lambda e, x=f: select_fuel(x),
                    bg_color="#2563EB" if state["fuel_type"] == f else "#334155",
                    expand=True,
                )
                for f in fuels
            ],
        )

        mode_chips = ft.Row(
            spacing=6,
            controls=[
                make_btn(
                    m,
                    lambda e, x=m: select_mode(x),
                    bg_color="#2563EB" if state["mode"] == m else "#334155",
                    expand=True,
                )
                for m in modes
            ],
        )

        def save_full_form(e):
            try:
                odo = int((odo_tf.value or "").strip().replace(" ", ""))
                liters = float((liters_tf.value or "").strip().replace(",", "."))
                val = float((cost_tf.value or "").strip().replace(",", "."))
                if odo <= 0 or liters <= 0 or val <= 0:
                    raise ValueError
            except ValueError:
                notify("⚠️ Заполните пробег, литры и стоимость корректными числами!", True)
                return

            if last_ref and odo <= last_ref[1]:
                notify(f"⚠️ Новый пробег ({odo} км) должен быть больше предыдущего ({last_ref[1]} км)!", True)
                return

            total_cost = round(val * liters, 2) if val < 250 else round(val, 2)
            price_per_l = total_cost / liters if liters else val
            is_f = 1 if full_switch.value else 0
            st_brand = (station_tf.value or state["station_brand"]).strip()

            update_fuel_price_db(st_brand, state["fuel_type"], price_per_l)

            add_refueling_db(
                car_id,
                odo,
                liters,
                total_cost,
                is_f,
                state["fuel_type"],
                state["mode"],
                st_brand,
                state["lat"],
                state["lon"],
                state["address"],
            )
            state["odo_draft"] = ""
            state["liters_draft"] = ""

            records = get_all_refuelings(car_id)
            pts = calculate_consumption_points(records)

            if len(records) == 1:
                notify(f"✅ Первая заправка ({odo} км, {st_brand}) сохранена!")
            elif is_f == 0:
                notify("⏳ Частичная заправка сохранена!")
            elif pts:
                last_p = pts[-1]
                notify(f"✅ Сохранено ({st_brand})! +{last_p['distance']} км | Расход: {last_p['consumption']:.2f} л/100км")
            else:
                notify("✅ Заправка сохранена!")

            render_current_tab()

        form_card = ft.Container(
            bgcolor="#1E293B",
            padding=14,
            border_radius=12,
            content=ft.Column(
                spacing=10,
                controls=[
                    ft.Text("Новая заправка", size=16, weight=ft.FontWeight.BOLD, color="#F8FAFC"),
                    odo_tf,
                    ft.Row(controls=[liters_tf, cost_tf]),
                    ft.Text("Марка топлива:", size=11.5, color="#94A3B8"),
                    fuel_chips,
                    full_switch,
                    ft.Text("Режим езды:", size=11.5, color="#94A3B8"),
                    mode_chips,
                    make_btn("СОХРАНИТЬ ЗАПРАВКУ", save_full_form, bg_color="#2563EB"),
                ],
            ),
        )

        records = get_all_refuelings(car_id)
        history_items = []
        for r in reversed(records[-10:]):
            r_id, date_s, odo, lit, cost, is_f, f_type, mode, st_name, lat, lon, addr = r
            badge = "Полный" if is_f else "Частично"
            st_label = f"⛽ {st_name}" if st_name else "⛽ АЗС"
            geo_label = f" • 📍 {addr}" if addr and addr != "Геолокация не запрошена" else ""
            price_l = cost / lit if lit else 0

            history_items.append(
                ft.Container(
                    bgcolor="#1E293B",
                    padding=12,
                    border_radius=10,
                    content=ft.Row(
                        alignment=ft.MainAxisAlignment.SPACE_BETWEEN,
                        controls=[
                            ft.Column(
                                spacing=3,
                                expand=True,
                                controls=[
                                    ft.Text(
                                        f"{odo:,} км  •  {lit} л ({f_type})  •  {cost:.0f} ₽ ({price_l:.2f} ₽/л)".replace(",", " "),
                                        color="#F8FAFC",
                                        weight=ft.FontWeight.BOLD,
                                        size=13,
                                    ),
                                    ft.Text(f"{st_label}{geo_label}", color="#38BDF8", size=11.5),
                                    ft.Text(f"{date_s}  |  {mode}  |  {badge}", color="#94A3B8", size=11),
                                ],
                            ),
                            make_btn(
                                "×",
                                lambda e, x=r_id: (delete_refueling_db(x), notify("Запись удалена"), render_current_tab()),
                                bg_color="#334155",
                                text_color="#EF4444",
                            ),
                        ],
                    ),
                )
            )

        body_scroll.controls = [
            geo_card,
            quick_card,
            form_card,
            ft.Text("Последние заправки:", size=14, weight=ft.FontWeight.BOLD, color="#94A3B8"),
            *(history_items if history_items else [ft.Text("Записей пока нет.", color="#64748B", size=13)]),
        ]

    def build_expenses_tab():
        car_id, _, _, _ = get_active_car()
        categories = ["🔧 ТО и Запчасти", "🚿 Мойка", "📄 Страховка", "🅿️ Штрафы/Парковка", "📦 Прочее"]

        def select_cat(c):
            state["exp_category"] = c
            render_current_tab()

        cat_rows = [
            ft.Row(
                spacing=6,
                controls=[
                    make_btn(
                        c,
                        lambda e, x=c: select_cat(x),
                        bg_color="#2563EB" if state["exp_category"] == c else "#334155",
                        expand=True,
                    )
                    for c in categories[:3]
                ],
            ),
            ft.Row(
                spacing=6,
                controls=[
                    make_btn(
                        c,
                        lambda e, x=c: select_cat(x),
                        bg_color="#2563EB" if state["exp_category"] == c else "#334155",
                        expand=True,
                    )
                    for c in categories[3:]
                ],
            ),
        ]

        cost_tf = ft.TextField(label="Сумма расхода (₽)", keyboard_type=ft.KeyboardType.NUMBER, color="#FFFFFF", bgcolor="#0F172A", border_color="#334155")
        comm_tf = ft.TextField(label="Комментарий (напр. Замена колодок, ОСАГО)", color="#FFFFFF", bgcolor="#0F172A", border_color="#334155")

        def save_exp(e):
            try:
                cost = float((cost_tf.value or "").strip().replace(",", "."))
                if cost <= 0:
                    raise ValueError
            except ValueError:
                notify("⚠️ Введите корректную сумму расхода!", True)
                return

            comment = (comm_tf.value or "").strip() or "Без комментария"
            add_expense_db(car_id, state["exp_category"], cost, comment)
            notify(f"✅ Расход {cost:.0f} ₽ ({state['exp_category']}) добавлен!")
            render_current_tab()

        exp_list = get_all_expenses(car_id)
        exp_cards = []
        for ex in exp_list[:15]:
            ex_id, date_s, cat, cost, comm = ex
            exp_cards.append(
                ft.Container(
                    bgcolor="#1E293B",
                    padding=12,
                    border_radius=10,
                    content=ft.Row(
                        alignment=ft.MainAxisAlignment.SPACE_BETWEEN,
                        controls=[
                            ft.Column(
                                spacing=3,
                                controls=[
                                    ft.Text(f"{cat}: {cost:.0f} ₽", color="#F8FAFC", weight=ft.FontWeight.BOLD, size=13),
                                    ft.Text(f"{date_s[:10]}  •  {comm}", color="#94A3B8", size=11),
                                ],
                            ),
                            make_btn(
                                "×",
                                lambda e, x=ex_id: (delete_expense_db(x), notify("Расход удален"), render_current_tab()),
                                bg_color="#334155",
                                text_color="#EF4444",
                            ),
                        ],
                    ),
                )
            )

        body_scroll.controls = [
            ft.Container(
                bgcolor="#1E293B",
                padding=14,
                border_radius=12,
                content=ft.Column(
                    spacing=10,
                    controls=[
                        ft.Text("Добавить расход на автомобиль", size=16, weight=ft.FontWeight.BOLD, color="#F8FAFC"),
                        *cat_rows,
                        cost_tf,
                        comm_tf,
                        make_btn("СОХРАНИТЬ РАСХОД", save_exp, bg_color="#10B981"),
                    ],
                ),
            ),
            ft.Text("История расходов:", size=14, weight=ft.FontWeight.BOLD, color="#94A3B8"),
            *(exp_cards if exp_cards else [ft.Text("Дополнительных расходов пока нет.", color="#64748B", size=13)]),
        ]

    def build_stats_tab():
        car_id, car_name, _, _ = get_active_car()
        refuels = get_all_refuelings(car_id)
        expenses = get_all_expenses(car_id)
        points = calculate_consumption_points(refuels)

        total_liters = sum(r[3] for r in refuels)
        total_fuel_cost = sum(r[4] for r in refuels)
        total_extra_cost = sum(e[3] for e in expenses)
        grand_total = total_fuel_cost + total_extra_cost

        if len(refuels) >= 2 and points:
            total_dist = refuels[-1][2] - refuels[0][2]
            avg_cons = sum(p["liters"] for p in points) / sum(p["distance"] for p in points) * 100
            fuel_km_cost = (total_fuel_cost - refuels[0][4]) / total_dist if total_dist > 0 else 0
            tco_km_cost = ((total_fuel_cost - refuels[0][4]) + total_extra_cost) / total_dist if total_dist > 0 else 0
        else:
            total_dist = 0
            avg_cons = 0.0
            fuel_km_cost = 0.0
            tco_km_cost = 0.0

        def stat_box(title: str, val: str, color="#38BDF8"):
            return ft.Container(
                bgcolor="#1E293B",
                padding=14,
                border_radius=12,
                expand=True,
                content=ft.Column(
                    spacing=4,
                    controls=[
                        ft.Text(title, size=12, color="#94A3B8"),
                        ft.Text(val, size=18, weight=ft.FontWeight.BOLD, color=color),
                    ],
                ),
            )

        chart_rows = []
        if points:
            max_c = max(p["consumption"] for p in points) or 15.0
            for p in points[-8:]:
                ratio = min(p["consumption"] / (max_c * 1.15), 1.0)
                odo_fmt = f"{p['odometer']:,}".replace(",", " ")
                st_str = f" • {p['station']}" if p.get("station") else ""
                chart_rows.append(
                    ft.Column(
                        spacing=4,
                        controls=[
                            ft.Row(
                                alignment=ft.MainAxisAlignment.SPACE_BETWEEN,
                                controls=[
                                    ft.Text(f"{odo_fmt} км ({p['mode']}{st_str})", size=11.5, color="#CBD5E1"),
                                    ft.Text(f"{p['consumption']:.2f} л/100км ({p['price_per_liter']:.1f} ₽/л)", size=11.5, weight=ft.FontWeight.BOLD, color="#38BDF8"),
                                ],
                            ),
                            ft.ProgressBar(value=ratio, color="#3B82F6", bgcolor="#0F172A", height=8),
                        ],
                    )
                )
        else:
            chart_rows.append(ft.Text("Добавьте минимум 2 заправки до полного бака (или загрузите демо-данные).", color="#64748B", size=12))

        def export_csv_click(e):
            safe_name = re.sub(r"[^\w\-]", "_", car_name)
            csv_path = os.path.join(APP_DIR, f"report_{safe_name}.csv")
            with open(csv_path, "w", encoding="utf-8-sig", newline="") as f:
                w = csv.writer(f, delimiter=";")
                w.writerow(["ТИП", "ДАТА", "ПРОБЕГ", "ЛИТРЫ", "СУММА", "ТОПЛИВО/КАТЕГОРИЯ", "РЕЖИМ/КОММЕНТАРИЙ", "АЗС", "АДРЕС", "КООРДИНАТЫ"])
                for r in refuels:
                    coords = f"{r[9]:.5f}, {r[10]:.5f}" if r[9] else ""
                    w.writerow(["Заправка", r[1], r[2], r[3], r[4], r[6], r[7], r[8], r[11], coords])
                for ex in expenses:
                    w.writerow(["Расход", ex[1], "", "", ex[3], ex[2], ex[4], "", "", ""])
            notify(f"📥 Отчет сохранен: {csv_path}")

        dist_fmt = f"{total_dist:,} км".replace(",", " ")

        body_scroll.controls = [
            ft.Row(controls=[stat_box("Средний расход", f"{avg_cons:.2f} л/100км", "#F43F5E"), stat_box("Пробег по базе", dist_fmt, "#38BDF8")]),
            ft.Row(controls=[stat_box("1 км (только бензин)", f"{fuel_km_cost:.2f} ₽", "#10B981"), stat_box("1 км (полная ТСО)", f"{tco_km_cost:.2f} ₽", "#F59E0B")]),
            ft.Container(
                bgcolor="#1E293B",
                padding=14,
                border_radius=12,
                content=ft.Column(
                    spacing=6,
                    controls=[
                        ft.Text("Сводка затрат", size=15, weight=ft.FontWeight.BOLD, color="#F8FAFC"),
                        ft.Text(f"• Затраты на топливо: {total_fuel_cost:,.2f} ₽ ({total_liters:.1f} л)".replace(",", " "), color="#CBD5E1", size=13),
                        ft.Text(f"• Затраты на ТО, мойку и прочее: {total_extra_cost:,.2f} ₽".replace(",", " "), color="#CBD5E1", size=13),
                        ft.Text(f"• ИТОГО ПОТРАЧЕНО: {grand_total:,.2f} ₽".replace(",", " "), color="#10B981", weight=ft.FontWeight.BOLD, size=14),
                    ],
                ),
            ),
            ft.Container(
                bgcolor="#1E293B",
                padding=14,
                border_radius=12,
                content=ft.Column(
                    spacing=10,
                    controls=[
                        ft.Text("Динамика расхода и цены топлива по АЗС", size=15, weight=ft.FontWeight.BOLD, color="#F8FAFC"),
                        *chart_rows,
                    ],
                ),
            ),
            make_btn("Выгрузить историю в CSV (Excel)", export_csv_click, bg_color="#334155"),
        ]

    def build_garage_tab():
        car_id, car_name, interval, last_service_odo = get_active_car()
        last_ref = get_last_refueling(car_id)
        curr_odo = last_ref[1] if last_ref else 0

        passed = max(curr_odo - last_service_odo, 0) if last_service_odo > 0 else 0
        progress = min(passed / interval, 1.0) if interval > 0 and last_service_odo > 0 else 0.0

        srv_odo_tf = ft.TextField(label="Пробег последней замены (км)", value=str(last_service_odo or curr_odo), keyboard_type=ft.KeyboardType.NUMBER, color="#FFFFFF", bgcolor="#0F172A", border_color="#334155")
        srv_int_tf = ft.TextField(label="Интервал замены (км)", value=str(interval), keyboard_type=ft.KeyboardType.NUMBER, color="#FFFFFF", bgcolor="#0F172A", border_color="#334155")

        def save_service_settings(e):
            try:
                s_odo = int((srv_odo_tf.value or "").strip())
                s_int = int((srv_int_tf.value or "").strip())
                if s_int < 500:
                    raise ValueError
            except ValueError:
                notify("⚠️ Введите корректный пробег и интервал!", True)
                return
            update_service_db(car_id, s_odo, s_int)
            notify(f"✅ Параметры ТО обновлены!")
            render_current_tab()

        def oil_changed_now(e):
            if curr_odo == 0:
                notify("⚠️ Сначала добавьте заправку!", True)
                return
            update_service_db(car_id, curr_odo, interval)
            notify(f"✅ Замена масла записана на пробеге {curr_odo} км!")
            render_current_tab()

        all_cars = get_all_cars_db()
        car_buttons = []
        for c_id, c_name, c_int, _ in all_cars:
            is_act = c_id == car_id
            car_buttons.append(
                make_btn(
                    f"{'✓ ' if is_act else ''}{c_name} (ТО: {c_int} км)",
                    lambda e, x=c_id: (set_active_car_db(x), notify("Автомобиль переключен"), render_current_tab()),
                    bg_color="#2563EB" if is_act else "#334155",
                )
            )

        new_car_name = ft.TextField(label="Название нового авто", color="#FFFFFF", bgcolor="#0F172A", border_color="#334155")
        new_car_int = ft.TextField(label="Интервал ТО в км", value="10000", keyboard_type=ft.KeyboardType.NUMBER, color="#FFFFFF", bgcolor="#0F172A", border_color="#334155")

        def add_new_car_click(e):
            name = (new_car_name.value or "").strip()
            if not name:
                notify("⚠️ Введите название автомобиля!", True)
                return
            try:
                c_int = int((new_car_int.value or "10000").strip())
            except ValueError:
                c_int = 10000
            add_car_db(name, c_int)
            notify(f"🚘 Автомобиль «{name}» добавлен и выбран!")
            render_current_tab()

        body_scroll.controls = [
            ft.Container(
                bgcolor="#1E293B",
                padding=14,
                border_radius=12,
                content=ft.Column(
                    spacing=10,
                    controls=[
                        ft.Text(f"Контроль замены масла ({car_name})", size=15, weight=ft.FontWeight.BOLD, color="#F8FAFC"),
                        ft.Text(f"Пройдено после ТО: {passed:,} км из {interval:,} км".replace(",", " "), size=13, color="#CBD5E1"),
                        ft.ProgressBar(value=progress, color="#EF4444" if progress >= 0.9 else "#10B981", bgcolor="#0F172A", height=10),
                        make_btn(f"Я поменял масло сейчас ({curr_odo:,} км)".replace(",", " "), oil_changed_now, bg_color="#10B981"),
                        srv_odo_tf,
                        srv_int_tf,
                        make_btn("Обновить параметры ТО", save_service_settings, bg_color="#2563EB"),
                    ],
                ),
            ),
            ft.Container(
                bgcolor="#1E293B",
                padding=14,
                border_radius=12,
                content=ft.Column(
                    spacing=10,
                    controls=[
                        ft.Text("Мои автомобили (Гараж)", size=15, weight=ft.FontWeight.BOLD, color="#F8FAFC"),
                        *car_buttons,
                        ft.Divider(color="#334155"),
                        ft.Text("+ Добавить еще один автомобиль:", size=13, color="#94A3B8"),
                        new_car_name,
                        new_car_int,
                        make_btn("+ Добавить авто в гараж", add_new_car_click, bg_color="#334155"),
                    ],
                ),
            ),
            ft.Container(
                bgcolor="#1E293B",
                padding=14,
                border_radius=12,
                content=ft.Column(
                    spacing=8,
                    controls=[
                        ft.Text("Тестирование и управление базой", size=14, weight=ft.FontWeight.BOLD, color="#94A3B8"),
                        ft.Row(
                            spacing=8,
                            controls=[
                                make_btn(
                                    "🎲 Загрузить демо-данные",
                                    lambda e: (load_demo_data_db(car_id), notify("Демо-данные с геометками загружены!"), render_current_tab()),
                                    bg_color="#334155",
                                    expand=True,
                                ),
                                make_btn(
                                    "🗑 Очистить базу",
                                    lambda e: (clear_car_history_db(car_id), notify("История очищена"), render_current_tab()),
                                    bg_color="#334155",
                                    text_color="#EF4444",
                                    expand=True,
                                ),
                            ],
                        ),
                    ],
                ),
            ),
        ]

    nav_row = ft.Row(spacing=6, alignment=ft.MainAxisAlignment.SPACE_AROUND)
    nav_bar = ft.Container(
        bgcolor="#1E293B",
        padding=ft.padding.symmetric(vertical=8, horizontal=8),
        content=nav_row,
    )

    def switch_tab(idx: int):
        state["tab_index"] = idx
        banner_box.visible = False
        render_current_tab()

    def render_current_tab():
        update_header()
        idx = state["tab_index"]

        tabs_meta = [
            (0, "Заправки"),
            (1, "Расходы"),
            (2, "Аналитика"),
            (3, "Гараж/ТО"),
        ]
        nav_row.controls = [
            make_btn(
                title,
                lambda e, i=i: switch_tab(i),
                bg_color="#2563EB" if idx == i else "#0F172A",
                text_color="#FFFFFF" if idx == i else "#94A3B8",
                expand=True,
            )
            for i, title in tabs_meta
        ]

        if idx == 0:
            build_refuel_tab()
        elif idx == 1:
            build_expenses_tab()
        elif idx == 2:
            build_stats_tab()
        elif idx == 3:
            build_garage_tab()

        page.update()

    page.add(
        ft.Column(
            expand=True,
            spacing=0,
            controls=[
                header,
                banner_box,
                body_wrapper,
                nav_bar,
            ],
        )
    )
    render_current_tab()


if __name__ == "__main__":
    if hasattr(ft, "run") and callable(ft.run):
        ft.run(main)
    else:
        ft.app(target=main)
