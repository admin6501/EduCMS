#!/bin/bash
set -e

echo "=== EduCMS Entrypoint ==="

# Wait for database to be ready
echo "Waiting for database..."
max_attempts=30
attempt=1
while [ $attempt -le $max_attempts ]; do
    python -c "
import os, sys
import MySQLdb
try:
    MySQLdb.connect(
        host=os.getenv('DB_HOST', 'db'),
        user=os.getenv('DB_USER'),
        passwd=os.getenv('DB_PASSWORD'),
        db=os.getenv('DB_NAME'),
        port=int(os.getenv('DB_PORT', 3306))
    )
    print('Database is ready!')
    sys.exit(0)
except Exception as e:
    print(f'Database not ready: {e}')
    sys.exit(1)
" && break
    echo "Attempt $attempt/$max_attempts - Database not ready, waiting..."
    sleep 2
    attempt=$((attempt + 1))
done

if [ $attempt -gt $max_attempts ]; then
    echo "ERROR: Database not ready after $max_attempts attempts"
    exit 1
fi

echo "Running migrations..."
python manage.py makemigrations accounts settingsapp courses payments tickets dashboard --noinput || true
python manage.py migrate --noinput

echo "Fixing database schema (adding missing columns)..."
python manage.py shell <<'PYFIX'
import os
import MySQLdb

db_config = {
    'host': os.getenv('DB_HOST', 'db'),
    'user': os.getenv('DB_USER'),
    'passwd': os.getenv('DB_PASSWORD'),
    'db': os.getenv('DB_NAME'),
    'port': int(os.getenv('DB_PORT', 3306))
}

def column_exists(cursor, table, column):
    cursor.execute(f"SHOW COLUMNS FROM {table} LIKE '{column}'")
    return cursor.fetchone() is not None

def table_exists(cursor, table):
    cursor.execute(f"SHOW TABLES LIKE '{table}'")
    return cursor.fetchone() is not None

try:
    conn = MySQLdb.connect(**db_config)
    cursor = conn.cursor()

    # Add extra_data to accounts_userprofile
    if table_exists(cursor, 'accounts_userprofile'):
        if not column_exists(cursor, 'accounts_userprofile', 'extra_data'):
            cursor.execute("ALTER TABLE accounts_userprofile ADD COLUMN extra_data JSON DEFAULT NULL")
            print("Added extra_data column to accounts_userprofile")

    # Add allow_profile_edit to settingsapp_sitesetting
    if table_exists(cursor, 'settingsapp_sitesetting'):
        if not column_exists(cursor, 'settingsapp_sitesetting', 'allow_profile_edit'):
            cursor.execute("ALTER TABLE settingsapp_sitesetting ADD COLUMN allow_profile_edit TINYINT(1) DEFAULT 1")
            print("Added allow_profile_edit column to settingsapp_sitesetting")
        if not column_exists(cursor, 'settingsapp_sitesetting', 'allow_security_edit'):
            cursor.execute("ALTER TABLE settingsapp_sitesetting ADD COLUMN allow_security_edit TINYINT(1) DEFAULT 1")
            print("Added allow_security_edit column to settingsapp_sitesetting")

    # Create settingsapp_registrationfield table if not exists
    if not table_exists(cursor, 'settingsapp_registrationfield'):
        cursor.execute("""
            CREATE TABLE settingsapp_registrationfield (
                id BIGINT AUTO_INCREMENT PRIMARY KEY,
                field_key VARCHAR(50) UNIQUE NOT NULL,
                label VARCHAR(150) NOT NULL,
                field_type VARCHAR(20) NOT NULL DEFAULT 'text',
                placeholder VARCHAR(200) DEFAULT '',
                help_text VARCHAR(300) DEFAULT '',
                choices TEXT,
                is_required TINYINT(1) DEFAULT 0,
                is_active TINYINT(1) DEFAULT 1,
                is_system TINYINT(1) DEFAULT 0,
                show_in_profile TINYINT(1) DEFAULT 1,
                `order` INT UNSIGNED DEFAULT 0,
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                updated_at DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
            ) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci
        """)
        print("Created settingsapp_registrationfield table")

    conn.commit()
    cursor.close()
    conn.close()
    print("Database schema fix completed.")
except Exception as e:
    print(f"Database schema fix error (may be ok): {e}")
PYFIX

echo "Seeding database..."
python manage.py shell <<'PY'
import os
import traceback

try:
    from django.contrib.auth import get_user_model
    from settingsapp.models import SiteSetting, TemplateText
    from payments.models import BankTransferSetting
    from accounts.models import SecurityQuestion, UserProfile

    User=get_user_model()
    admin_u=os.getenv("ADMIN_USERNAME")
    admin_p=os.getenv("ADMIN_PASSWORD")
    admin_e=os.getenv("ADMIN_EMAIL")
    initial_admin_path=os.getenv("INITIAL_ADMIN_PATH","admin") or "admin"

    u,_=User.objects.get_or_create(username=admin_u, defaults={"email": admin_e})
    u.is_staff=True; u.is_superuser=True; u.email=admin_e
    u.set_password(admin_p); u.save()
    UserProfile.objects.get_or_create(user=u)
    print("Admin user created/updated.")

    qs=[
        ("نام اولین معلم شما چه بود؟", 1),
        ("نام شهر محل تولد شما چیست؟", 2),
        ("نام بهترین دوست دوران کودکی شما چیست؟", 3),
        ("مدل اولین گوشی شما چه بود؟", 4),
        ("نام اولین حیوان خانگی شما چه بود؟", 5),
        ("نام مادربزرگ مادری شما چیست؟", 6),
        ("نام اولین مدرسه شما چه بود؟", 7),
        ("رنگ مورد علاقه شما در کودکی چه بود؟", 8),
        ("نام اولین خیابانی که در آن زندگی کردید چیست؟", 9),
        ("غذای مورد علاقه دوران کودکی شما چه بود؟", 10),
        ("نام بهترین دوست دوران دبیرستان شما چیست؟", 11),
        ("شغل رویایی دوران کودکی شما چه بود؟", 12),
        ("نام اولین فیلمی که در سینما دیدید چه بود؟", 13),
        ("نام اولین کتابی که خواندید چه بود؟", 14),
        ("تاریخ تولد پدر شما چیست؟", 15),
    ]
    for t,o in qs:
        SecurityQuestion.objects.get_or_create(text=t, defaults={"order":o,"is_active":True})
    print("Security questions seeded.")

    # Seed default registration fields (system fields that cannot be deleted)
    try:
        from settingsapp.models import RegistrationField
        default_fields = [
            {"field_key": "email", "label": "ایمیل", "field_type": "email", "is_required": True, "is_system": True, "order": 1, "show_in_profile": True},
            {"field_key": "security_question", "label": "سوال امنیتی", "field_type": "select", "is_required": True, "is_system": True, "order": 2, "show_in_profile": False},
            {"field_key": "security_answer", "label": "پاسخ سوال امنیتی", "field_type": "password", "is_required": True, "is_system": True, "order": 3, "show_in_profile": False},
            {"field_key": "password1", "label": "گذرواژه", "field_type": "password", "is_required": True, "is_system": True, "order": 4, "show_in_profile": False},
            {"field_key": "password2", "label": "تکرار گذرواژه", "field_type": "password", "is_required": True, "is_system": True, "order": 5, "show_in_profile": False},
        ]
        for f in default_fields:
            RegistrationField.objects.get_or_create(field_key=f["field_key"], defaults=f)
        print("Registration fields seeded.")
    except Exception as e:
        print(f"Registration fields seed skipped: {e}")

    s,_=SiteSetting.objects.get_or_create(id=1, defaults={"brand_name":"EduCMS","footer_text":"© تمامی حقوق محفوظ است.","default_theme":"system","admin_path":initial_admin_path})
    if not s.admin_path:
        s.admin_path=initial_admin_path; s.save(update_fields=["admin_path"])
    print("Site settings seeded.")

    BankTransferSetting.objects.get_or_create(id=1)
    TemplateText.objects.get_or_create(key="home_title", defaults={"title":"عنوان","value":"دوره‌های آموزشی"})
    TemplateText.objects.get_or_create(key="home_subtitle", defaults={"title":"زیرعنوان","value":"جدیدترین دوره‌ها"})
    TemplateText.objects.get_or_create(key="home_empty", defaults={"title":"بدون دوره","value":"هنوز دوره‌ای منتشر نشده است."})
    print("Template texts seeded.")
    print("=== Seed completed successfully ===")
except Exception as e:
    print(f"ERROR during seeding: {e}")
    traceback.print_exc()
PY

echo "Collecting static files..."
python manage.py collectstatic --noinput

echo "Starting Gunicorn..."
exec gunicorn educms.wsgi:application --bind 0.0.0.0:8000 --workers 3 --timeout 120 --access-logfile - --error-logfile -