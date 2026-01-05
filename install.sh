#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

APP_DIR="/opt/educms"
ENV_FILE="${APP_DIR}/.env"
BACKUP_DIR="${APP_DIR}/backups"

DOMAIN=""; LE_EMAIL=""
DB_NAME="educms"; DB_USER=""; DB_PASS=""
ADMIN_USER=""; ADMIN_PASS=""; ADMIN_PATH="admin"

have_cmd(){ command -v "$1" >/dev/null 2>&1; }
die(){ echo "ERROR: $*" >&2; exit 1; }
require_root(){ [[ ${EUID:-1} -eq 0 ]] || die "Run with sudo/root"; }
require_tty(){ [[ -r /dev/tty && -w /dev/tty ]] || die "/dev/tty not accessible (run interactively)"; }

read_line(){ local p="$1" v=""; read -r -p "$p" v </dev/tty || true; printf "%s" "$(printf "%s" "${v:-}" | tr -d '\r\n')"; }
read_secret(){ local p="$1" v=""; read -r -s -p "$p" v </dev/tty || true; echo >&2; printf "%s" "$(printf "%s" "${v:-}" | tr -d '\r\n')"; }

validate_domain(){ [[ "${1:-}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]; }
validate_email(){ [[ "${1:-}" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; }
sanitize_admin_path(){
  local p="${1:-}"; p="$(printf "%s" "$p" | sed 's#^/##;s#/$##')"; [[ -z "$p" ]] && p="admin"
  [[ "$p" =~ ^[-A-Za-z0-9_]+$ ]] || die "Admin path invalid (allowed: A-Z a-z 0-9 _ -)"
  printf "%s" "$p"
}

install_base(){
  apt update
  apt install -y ca-certificates curl gnupg lsb-release openssl jq
}
install_docker(){
  if ! have_cmd docker; then
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
    apt update
    apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  else
    apt install -y docker-compose-plugin || true
  fi
  systemctl enable --now docker
}
install_certbot(){
  if ! have_cmd certbot; then
    apt update
    apt install -y certbot
  fi
}

collect_inputs(){
  echo "=== EduCMS Installer (Compact) ==="
  DOMAIN="$(read_line "Domain (e.g. example.com): ")"; validate_domain "$DOMAIN" || die "Invalid domain"
  LE_EMAIL="$(read_line "Email for Let's Encrypt: ")"; validate_email "$LE_EMAIL" || die "Invalid email"
  ADMIN_PATH="$(sanitize_admin_path "$(read_line "Admin path (default: admin): ")")"

  local t
  t="$(read_line "Database name [default: ${DB_NAME}]: ")"; [[ -n "${t:-}" ]] && DB_NAME="$t"
  DB_USER="$(read_line "Database username: ")"
  [[ -n "$DB_USER" ]] || die "Database username cannot be empty"
  DB_PASS="$(read_secret "Database password (hidden): ")"
  [[ -n "$DB_PASS" ]] || die "Database password cannot be empty"
  [[ ${#DB_PASS} -ge 4 ]] || die "Database password must be at least 4 characters"
  ADMIN_USER="$(read_line "Admin username: ")"
  [[ -n "$ADMIN_USER" ]] || die "Admin username cannot be empty"
  ADMIN_PASS="$(read_secret "Admin password (hidden): ")"
  [[ -n "$ADMIN_PASS" ]] || die "Admin password cannot be empty"
  [[ ${#ADMIN_PASS} -ge 4 ]] || die "Admin password must be at least 4 characters"
}

cleanup_old(){
  if [[ -d "$APP_DIR" && -f "$APP_DIR/docker-compose.yml" ]]; then
    (cd "$APP_DIR" && docker compose down --remove-orphans --volumes) || true
  fi
  rm -rf "$APP_DIR" || true
}

ensure_dirs(){
  mkdir -p "$APP_DIR" "$BACKUP_DIR"
  cd "$APP_DIR"
  mkdir -p app/{educms,accounts,courses,settingsapp,payments,tickets,dashboard} \
           app/templates/{accounts,courses,orders,tickets,settings,dashboard,wallet,invoices,partials} \
           app/static app/media app/staticfiles nginx certbot/www
}

write_env(){
  local secret; secret="$(openssl rand -hex 32)"
  cat > "$ENV_FILE" <<ENV
DOMAIN=${DOMAIN}
LE_EMAIL=${LE_EMAIL}
ADMIN_PATH=${ADMIN_PATH}

DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASS=${DB_PASS}

ADMIN_USER=${ADMIN_USER}
ADMIN_PASS=${ADMIN_PASS}

DJANGO_SECRET_KEY=${secret}
DJANGO_DEBUG=False
DJANGO_ALLOWED_HOSTS=${DOMAIN}
CSRF_TRUSTED_ORIGINS=https://${DOMAIN}
INITIAL_ADMIN_PATH=${ADMIN_PATH}
ENV
  chmod 600 "$ENV_FILE"
}

write_compose(){
  cat > docker-compose.yml <<'YML'
services:
  db:
    image: mysql:8.0
    command: --character-set-server=utf8mb4 --collation-server=utf8mb4_unicode_ci
    env_file: ./.env
    environment:
      MYSQL_DATABASE: ${DB_NAME}
      MYSQL_USER: ${DB_USER}
      MYSQL_PASSWORD: ${DB_PASS}
      MYSQL_ROOT_PASSWORD: ${DB_PASS}
    volumes: [db_data:/var/lib/mysql]
    restart: unless-stopped
    healthcheck:
      test: ["CMD-SHELL", "mysqladmin ping -h 127.0.0.1 -uroot -p$${MYSQL_ROOT_PASSWORD} --silent"]
      interval: 5s
      timeout: 3s
      retries: 40
      start_period: 20s

  web:
    build: ./app
    env_file: ./.env
    environment:
      DJANGO_SECRET_KEY: ${DJANGO_SECRET_KEY}
      DJANGO_DEBUG: ${DJANGO_DEBUG}
      DJANGO_ALLOWED_HOSTS: ${DJANGO_ALLOWED_HOSTS}
      CSRF_TRUSTED_ORIGINS: ${CSRF_TRUSTED_ORIGINS}
      DB_NAME: ${DB_NAME}
      DB_USER: ${DB_USER}
      DB_PASSWORD: ${DB_PASS}
      DB_HOST: db
      DB_PORT: "3306"
      ADMIN_USERNAME: ${ADMIN_USER}
      ADMIN_PASSWORD: ${ADMIN_PASS}
      ADMIN_EMAIL: ${LE_EMAIL}
      INITIAL_ADMIN_PATH: ${INITIAL_ADMIN_PATH}
    volumes:
      - ./app/media:/app/media
      - ./app/staticfiles:/app/staticfiles
    depends_on:
      db:
        condition: service_healthy
    restart: unless-stopped

  nginx:
    image: nginx:alpine
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - ./app/staticfiles:/var/www/static:ro
      - ./app/media:/var/www/media:ro
      - ./certbot/www:/var/www/certbot:ro
      - /etc/letsencrypt:/etc/letsencrypt:ro
    ports: ["80:80","443:443"]
    depends_on: [web]
    restart: unless-stopped

volumes: { db_data: {} }
YML
  docker compose -f docker-compose.yml config >/dev/null
}

write_nginx_http(){
  cat > nginx/nginx.conf <<NGINX
server {
  listen 80;
  server_name ${DOMAIN};

  location /.well-known/acme-challenge/ { root /var/www/certbot; }

  client_max_body_size 2000M;

  location /static/ { alias /var/www/static/; }
  location /media/  { alias /var/www/media/; }

  location / {
    proxy_pass http://web:8000;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
  }
}
NGINX
}

write_nginx_https(){
  cat > nginx/nginx.conf <<NGINX
server {
  listen 80;
  server_name ${DOMAIN};
  location /.well-known/acme-challenge/ { root /var/www/certbot; }
  location / { return 301 https://\$host\$request_uri; }
}

server {
  listen 443 ssl;
  http2 on;
  server_name ${DOMAIN};

  ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;

  ssl_session_timeout 1d;
  ssl_session_cache shared:SSL:10m;
  ssl_session_tickets off;
  ssl_protocols TLSv1.2 TLSv1.3;

  client_max_body_size 2000M;

  location /static/ { alias /var/www/static/; }
  location /media/  { alias /var/www/media/; }

  location / {
    proxy_pass http://web:8000;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
  }
}
NGINX
}

write_project(){
  cat > app/Dockerfile <<'DOCKER'
FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential gcc pkg-config gettext locales default-libmysqlclient-dev libmariadb-dev \
    && sed -i 's/^# *C.UTF-8 UTF-8/C.UTF-8 UTF-8/' /etc/locale.gen \
    && locale-gen \
    && rm -rf /var/lib/apt/lists/*
ENV LANG=C.UTF-8 LC_ALL=C.UTF-8
WORKDIR /app
COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt
COPY . /app
CMD ["/app/entrypoint.sh"]
DOCKER

  cat > app/requirements.txt <<'REQ'
Django>=5.0,<6.0
gunicorn>=21.2
mysqlclient>=2.2
Pillow>=10.0
qrcode>=7.4
jdatetime>=4.1
reportlab>=4.0
arabic-reshaper>=3.0
python-bidi>=0.4
pytz>=2024.1
requests>=2.31
REQ

  cat > app/manage.py <<'PY'
import os, sys
def main():
    os.environ.setdefault("DJANGO_SETTINGS_MODULE","educms.settings")
    from django.core.management import execute_from_command_line
    execute_from_command_line(sys.argv)
if __name__ == "__main__":
    main()
PY
  cat > app/educms/__init__.py <<'PY'
PY

  # ایجاد پوشه templatetags
  mkdir -p app/educms/templatetags
  cat > app/educms/templatetags/__init__.py <<'PY'
PY

  cat > app/educms/templatetags/jalali_tags.py <<'PY'
from django import template
from django.utils import timezone
from django.conf import settings
import jdatetime
import pytz

register = template.Library()

PERSIAN_MONTHS = [
    'فروردین', 'اردیبهشت', 'خرداد', 'تیر', 'مرداد', 'شهریور',
    'مهر', 'آبان', 'آذر', 'دی', 'بهمن', 'اسفند'
]

GREGORIAN_MONTHS = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December'
]

PERSIAN_WEEKDAYS = [
    'شنبه', 'یکشنبه', 'دوشنبه', 'سه‌شنبه', 'چهارشنبه', 'پنج‌شنبه', 'جمعه'
]

# تایم‌زون تهران
TEHRAN_TZ = pytz.timezone('Asia/Tehran')

def get_calendar_type():
    """دریافت نوع تقویم از تنظیمات سایت - بدون کش برای آپدیت فوری"""
    try:
        from settingsapp.models import SiteSetting
        setting = SiteSetting.objects.first()
        return setting.calendar_type if setting else 'jalali'
    except:
        return 'jalali'

def to_persian_num(num):
    """تبدیل اعداد انگلیسی به فارسی"""
    persian_digits = '۰۱۲۳۴۵۶۷۸۹'
    return ''.join(persian_digits[int(d)] if d.isdigit() else d for d in str(num))

def convert_to_tehran(value):
    """تبدیل زمان به تایم‌زون تهران"""
    if value is None:
        return None
    try:
        if timezone.is_aware(value):
            return value.astimezone(TEHRAN_TZ)
        else:
            # اگر naive است، فرض می‌کنیم UTC است
            return pytz.utc.localize(value).astimezone(TEHRAN_TZ)
    except:
        return value

def format_gregorian(value, fmt='date'):
    """فرمت میلادی"""
    if fmt == 'datetime':
        return f"{value.day} {GREGORIAN_MONTHS[value.month-1]} {value.year} - {value.hour:02d}:{value.minute:02d}"
    elif fmt == 'short':
        return f"{value.year}/{value.month:02d}/{value.day:02d}"
    elif fmt == 'time':
        return f"{value.hour:02d}:{value.minute:02d}"
    else:
        return f"{value.day} {GREGORIAN_MONTHS[value.month-1]} {value.year}"

def format_jalali(value, fmt='date'):
    """فرمت شمسی"""
    jdate = jdatetime.datetime.fromgregorian(datetime=value)
    if fmt == 'datetime':
        return to_persian_num(f"{jdate.day} {PERSIAN_MONTHS[jdate.month-1]} {jdate.year} - {jdate.hour:02d}:{jdate.minute:02d}")
    elif fmt == 'full':
        weekday = (jdate.weekday() + 2) % 7
        return to_persian_num(f"{PERSIAN_WEEKDAYS[weekday]} {jdate.day} {PERSIAN_MONTHS[jdate.month-1]} {jdate.year}")
    elif fmt == 'short':
        return to_persian_num(f"{jdate.year}/{jdate.month:02d}/{jdate.day:02d}")
    elif fmt == 'time':
        return to_persian_num(f"{jdate.hour:02d}:{jdate.minute:02d}")
    else:
        return to_persian_num(f"{jdate.day} {PERSIAN_MONTHS[jdate.month-1]} {jdate.year}")

@register.filter(name='smart_date')
def smart_date(value, fmt='date'):
    """تاریخ هوشمند - بر اساس تنظیمات سایت شمسی یا میلادی"""
    if not value:
        return ''
    try:
        value = convert_to_tehran(value)
        cal_type = get_calendar_type()
        if cal_type == 'gregorian':
            return format_gregorian(value, fmt)
        return format_jalali(value, fmt)
    except:
        return str(value)

@register.filter(name='jalali')
def jalali_date(value, fmt='date'):
    """تاریخ هوشمند - از تنظیمات سایت استفاده می‌کند"""
    return smart_date(value, fmt)

@register.filter(name='gregorian')
def gregorian_date(value, fmt='date'):
    """تاریخ میلادی (همیشه میلادی)"""
    if not value:
        return ''
    try:
        value = convert_to_tehran(value)
        return format_gregorian(value, fmt)
    except:
        return str(value)

@register.filter(name='jalali_short')
def jalali_short(value):
    return smart_date(value, 'short')

@register.filter(name='jalali_full')
def jalali_full(value):
    return smart_date(value, 'full')

@register.filter(name='jalali_datetime')
def jalali_datetime(value):
    return smart_date(value, 'datetime')

@register.simple_tag
def jalali_now(fmt='date'):
    """تاریخ و ساعت فعلی به وقت تهران بر اساس تنظیمات"""
    from datetime import datetime
    now = datetime.now(TEHRAN_TZ)
    return smart_date(now, fmt)

@register.simple_tag
def tehran_time():
    """ساعت فعلی تهران"""
    from datetime import datetime
    cal_type = get_calendar_type()
    now = datetime.now(TEHRAN_TZ)
    if cal_type == 'jalali':
        return to_persian_num(f"{now.hour:02d}:{now.minute:02d}")
    return f"{now.hour:02d}:{now.minute:02d}"

@register.simple_tag
def get_calendar_setting():
    """دریافت نوع تقویم جاری"""
    return get_calendar_type()
PY

  cat > app/accounts/__init__.py <<'PY'
PY
  cat > app/courses/__init__.py <<'PY'
PY
  cat > app/settingsapp/__init__.py <<'PY'
PY
  cat > app/payments/__init__.py <<'PY'
PY
  cat > app/tickets/__init__.py <<'PY'
PY
  cat > app/dashboard/__init__.py <<'PY'
PY
  cat > app/educms/wsgi.py <<'PY'
import os
from django.core.wsgi import get_wsgi_application
os.environ.setdefault("DJANGO_SETTINGS_MODULE","educms.settings")
application = get_wsgi_application()
PY

  cat > app/educms/settings.py <<'PY'
from pathlib import Path
import os

BASE_DIR = Path(__file__).resolve().parent.parent
SECRET_KEY = os.getenv("DJANGO_SECRET_KEY","dev-secret")
DEBUG = os.getenv("DJANGO_DEBUG","False").lower()=="true"
ALLOWED_HOSTS = [h.strip() for h in os.getenv("DJANGO_ALLOWED_HOSTS","localhost").split(",") if h.strip()]

INSTALLED_APPS = [
  "django.contrib.admin","django.contrib.auth","django.contrib.contenttypes","django.contrib.sessions",
  "django.contrib.messages","django.contrib.staticfiles",
  "educms",
  "accounts.apps.AccountsConfig",
  "courses.apps.CoursesConfig",
  "settingsapp.apps.SettingsappConfig",
  "payments.apps.PaymentsConfig",
  "tickets.apps.TicketsConfig",
  "dashboard.apps.DashboardConfig",
]

MIDDLEWARE = [
  "django.middleware.security.SecurityMiddleware",
  "django.contrib.sessions.middleware.SessionMiddleware",
  "django.middleware.locale.LocaleMiddleware",
  "settingsapp.middleware.IPSecurityMiddleware",
  "settingsapp.middleware.AdminAliasMiddleware",
  "django.middleware.common.CommonMiddleware",
  "django.middleware.csrf.CsrfViewMiddleware",
  "django.contrib.auth.middleware.AuthenticationMiddleware",
  "django.contrib.messages.middleware.MessageMiddleware",
  "django.middleware.clickjacking.XFrameOptionsMiddleware",
]

ROOT_URLCONF = "educms.urls"
TEMPLATES = [{
  "BACKEND":"django.template.backends.django.DjangoTemplates",
  "DIRS":[BASE_DIR/"templates"],
  "APP_DIRS":True,
  "OPTIONS":{"context_processors":[
    "django.template.context_processors.request",
    "django.contrib.auth.context_processors.auth",
    "django.contrib.messages.context_processors.messages",
    "settingsapp.context_processors.site_context",
  ]},
}]
WSGI_APPLICATION = "educms.wsgi.application"

DATABASES = {"default":{
  "ENGINE":"django.db.backends.mysql",
  "NAME":os.getenv("DB_NAME"),
  "USER":os.getenv("DB_USER"),
  "PASSWORD":os.getenv("DB_PASSWORD"),
  "HOST":os.getenv("DB_HOST","db"),
  "PORT":os.getenv("DB_PORT","3306"),
  "OPTIONS":{"charset":"utf8mb4"},
}}

AUTH_USER_MODEL = "accounts.User"

AUTHENTICATION_BACKENDS = ["accounts.backends.EmailOrUsernameBackend"]

LANGUAGE_CODE = "fa"
USE_I18N = True
LANGUAGES = [("fa","فارسی")]
TIME_ZONE = "Asia/Tehran"
USE_TZ = True

STATIC_URL = "/static/"
STATIC_ROOT = BASE_DIR/"staticfiles"
MEDIA_URL = "/media/"
MEDIA_ROOT = BASE_DIR/"media"

DEFAULT_AUTO_FIELD = "django.db.models.BigAutoField"

_csrf = os.getenv("CSRF_TRUSTED_ORIGINS","")
CSRF_TRUSTED_ORIGINS = [o.strip() for o in _csrf.split(",") if o.strip()]

LOGIN_URL = "/accounts/login/"
LOGIN_REDIRECT_URL = "/dashboard/"
LOGOUT_REDIRECT_URL = "/"

SECURE_PROXY_SSL_HEADER = ("HTTP_X_FORWARDED_PROTO","https")
CSRF_COOKIE_SECURE = True
SESSION_COOKIE_SECURE = True
SECURE_CONTENT_TYPE_NOSNIFF = True
SECURE_REFERRER_POLICY = "same-origin"
X_FRAME_OPTIONS = "SAMEORIGIN"
PY

  cat > app/educms/urls.py <<'PY'
from django.contrib import admin
from django.urls import path, include
from django.conf import settings
from django.conf.urls.static import static
from settingsapp.admin_views import admin_account_in_admin
from settingsapp.views import backup_management, backup_create, backup_download, backup_delete, backup_restore
from courses.views import CourseListView, CourseDetailView
from accounts.views import qr_public_profile

urlpatterns = [
  path("admin/account/", admin.site.admin_view(admin_account_in_admin), name="admin_account_in_admin"),
  path("admin/backup/", admin.site.admin_view(backup_management), name="backup_management"),
  path("admin/backup/create/", admin.site.admin_view(backup_create), name="backup_create"),
  path("admin/backup/download/<str:filename>/", admin.site.admin_view(backup_download), name="backup_download"),
  path("admin/backup/delete/<str:filename>/", admin.site.admin_view(backup_delete), name="backup_delete"),
  path("admin/backup/restore/<str:filename>/", admin.site.admin_view(backup_restore), name="backup_restore"),
  path("admin/", admin.site.urls),

  path("accounts/", include("accounts.urls")),
  path("orders/", include("payments.urls")),
  path("wallet/", include("payments.wallet_urls")),
  path("invoices/", include("payments.invoice_urls")),
  path("tickets/", include("tickets.urls")),
  path("panel/", include("settingsapp.urls")),
  path("dashboard/", include("dashboard.urls")),

  path("qr/<str:token>/", qr_public_profile, name="qr_public_profile"),
  path("", CourseListView.as_view(), name="home"),
  path("courses/<slug:slug>/", CourseDetailView.as_view(), name="course_detail"),
]
if settings.DEBUG:
  urlpatterns += static(settings.MEDIA_URL, document_root=settings.MEDIA_ROOT)
PY

  cat > app/accounts/apps.py <<'PY'
from django.apps import AppConfig
class AccountsConfig(AppConfig):
  default_auto_field="django.db.models.BigAutoField"
  name="accounts"
  verbose_name="کاربران"
PY
  cat > app/accounts/models.py <<'PY'
import uuid
from django.db import models
from django.utils.translation import gettext_lazy as _
from django.utils.text import slugify
from django.contrib.auth.models import AbstractUser
from django.contrib.auth.hashers import make_password, check_password

class User(AbstractUser):
  id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False, verbose_name=_("شناسه"))
  email = models.EmailField(_("ایمیل"), unique=True)
  username = models.CharField(_("نام کاربری"), max_length=150, unique=True, blank=True)

  def save(self, *args, **kwargs):
    if not (self.username or "").strip():
      local = (self.email or "user").split("@")[0].strip() or "user"
      base = slugify(local, allow_unicode=False) or "user"
      candidate = base
      i = 0
      while User.objects.filter(username__iexact=candidate).exclude(pk=self.pk).exists():
        i += 1
        candidate = f"{base}{i}"
        if i > 9999:
          candidate = f"{base}{uuid.uuid4().hex[:6]}"
          break
      self.username = candidate
    return super().save(*args, **kwargs)

  class Meta:
    verbose_name = _("کاربر")
    verbose_name_plural = _("کاربران")
class SecurityQuestion(models.Model):
  id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
  text = models.CharField(max_length=250, unique=True, verbose_name=_("متن سوال"))
  is_active = models.BooleanField(default=True, verbose_name=_("فعال"))
  order = models.PositiveIntegerField(default=0, verbose_name=_("ترتیب"))
  class Meta:
    ordering=["order","text"]; verbose_name=_("سوال امنیتی"); verbose_name_plural=_("سوالات امنیتی")
  def __str__(self): return self.text

class UserProfile(models.Model):
  id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
  user = models.OneToOneField("accounts.User", on_delete=models.CASCADE, related_name="profile", verbose_name=_("کاربر"))
  phone = models.CharField(max_length=30, blank=True, verbose_name=_("شماره تماس"))
  bio = models.TextField(blank=True, verbose_name=_("بیو"))
  q1 = models.ForeignKey(SecurityQuestion, on_delete=models.SET_NULL, null=True, blank=True, related_name="p_q1", verbose_name=_("سوال ۱"))
  q2 = models.ForeignKey(SecurityQuestion, on_delete=models.SET_NULL, null=True, blank=True, related_name="p_q2", verbose_name=_("سوال ۲"))
  a1_hash = models.CharField(max_length=200, blank=True, verbose_name=_("هش پاسخ ۱"))
  a2_hash = models.CharField(max_length=200, blank=True, verbose_name=_("هش پاسخ ۲"))
  extra_data = models.JSONField(default=dict, blank=True, verbose_name=_("داده‌های اضافی"))
  updated_at = models.DateTimeField(auto_now=True)
  
  # QR Code Settings
  qr_enabled = models.BooleanField(default=True, verbose_name=_("QR Code فعال"))
  qr_token = models.CharField(max_length=64, blank=True, unique=True, null=True, verbose_name=_("توکن QR"))
  qr_show_name = models.BooleanField(default=True, verbose_name=_("نمایش نام"))
  qr_show_email = models.BooleanField(default=True, verbose_name=_("نمایش ایمیل"))
  qr_show_join_date = models.BooleanField(default=True, verbose_name=_("نمایش تاریخ عضویت"))
  qr_show_courses = models.BooleanField(default=True, verbose_name=_("نمایش دوره‌ها"))
  qr_show_progress = models.BooleanField(default=True, verbose_name=_("نمایش پیشرفت"))
  qr_show_stats = models.BooleanField(default=True, verbose_name=_("نمایش آمار"))
  qr_admin_disabled = models.BooleanField(default=False, verbose_name=_("غیرفعال توسط ادمین"))
  
  # تنظیمات تیکت برای کاربر
  DEPT_CHOICE = (("default",_("پیش‌فرض سیستم")),("required",_("اجباری")),("optional",_("اختیاری")))
  ticket_department_mode = models.CharField(max_length=10, choices=DEPT_CHOICE, default="default", verbose_name=_("حالت دپارتمان تیکت"))

  class Meta:
    verbose_name=_("پروفایل"); verbose_name_plural=_("پروفایل‌ها")

  @staticmethod
  def _norm(s): return (s or "").strip().lower()
  
  def set_answer(self, a1):
    """Set single security answer"""
    a1n = self._norm(a1)
    self.a1_hash = make_password(a1n) if a1n else ""
    
  def check_answer(self, a1):
    """Check single security answer"""
    if not self.a1_hash: return False
    return check_password(self._norm(a1), self.a1_hash)
  
  # Legacy methods for backwards compatibility
  def set_answers(self,a1,a2=None):
    a1n=self._norm(a1); a2n=self._norm(a2) if a2 else ""
    self.a1_hash = make_password(a1n) if a1n else ""
    self.a2_hash = make_password(a2n) if a2n else ""
  def check_answers(self,a1,a2=None):
    if not self.a1_hash: return False
    return check_password(self._norm(a1), self.a1_hash)
PY
  cat > app/accounts/admin.py <<'PY'
from django.contrib import admin
from django.contrib.auth.admin import UserAdmin as BaseUserAdmin
from .models import User, UserProfile, SecurityQuestion
from settingsapp.date_utils import smart_format_datetime, smart_format_date

class UserProfileInline(admin.StackedInline):
    model = UserProfile
    extra = 0
    can_delete = False

@admin.register(User)
class UserAdmin(BaseUserAdmin):
    list_display = ("email","is_staff","is_superuser","is_active","date_joined_display")
    list_filter = ("is_staff","is_superuser","is_active","groups")
    search_fields = ("email","username")
    ordering = ("email",)
    inlines = [UserProfileInline]

    fieldsets = (
        (None, {"fields": ("email","password")}),
        ("اطلاعات پایه", {"fields": ("username","first_name","last_name","is_active")}),
        ("دسترسی‌ها", {"fields": ("is_staff","is_superuser","groups","user_permissions")}),
        ("زمان‌ها", {"fields": ("last_login","date_joined")}),
    )
    add_fieldsets = (
        (None, {"classes": ("wide",), "fields": ("email","username","password1","password2")}),
    )

    def date_joined_display(self, obj):
        return smart_format_datetime(obj.date_joined)
    date_joined_display.short_description = "تاریخ عضویت"
    date_joined_display.admin_order_field = "date_joined"

@admin.register(SecurityQuestion)
class SecurityQuestionAdmin(admin.ModelAdmin):
    list_display = ("id","text","is_active")
    list_filter = ("is_active",)
    search_fields = ("text",)

@admin.register(UserProfile)
class UserProfileAdmin(admin.ModelAdmin):
    list_display = ("user", "phone", "security_question", "has_answer", "qr_status", "ticket_dept_mode", "updated_at_display")
    list_select_related = ("user", "q1")
    search_fields = ("user__email", "user__username", "phone")
    readonly_fields = ("security_info_display", "extra_data_display", "qr_info_display")
    list_filter = ("qr_enabled", "qr_admin_disabled", "ticket_department_mode")
    actions = ["enable_qr_for_users", "disable_qr_for_users", "set_dept_required", "set_dept_optional", "set_dept_default"]
    
    fieldsets = (
        ("اطلاعات کاربر", {"fields": ("user", "phone", "bio")}),
        ("سوال امنیتی", {"fields": ("q1", "security_info_display")}),
        ("تنظیمات QR Code", {"fields": ("qr_admin_disabled", "qr_enabled", "qr_info_display")}),
        ("تنظیمات تیکت", {"fields": ("ticket_department_mode",), 
                         "description": "تنظیم اجباری/اختیاری بودن دپارتمان برای این کاربر"}),
        ("داده‌های اضافی", {"fields": ("extra_data_display",)}),
    )

    def updated_at_display(self, obj):
        return smart_format_datetime(obj.updated_at)
    updated_at_display.short_description = "آخرین به‌روزرسانی"
    updated_at_display.admin_order_field = "updated_at"

    def security_question(self, obj):
        return obj.q1.text if obj.q1 else "-"
    security_question.short_description = "سوال امنیتی"

    def has_answer(self, obj):
        return bool(obj.a1_hash)
    has_answer.boolean = True
    has_answer.short_description = "پاسخ تنظیم شده"

    def qr_status(self, obj):
        if obj.qr_admin_disabled:
            return "🚫 غیرفعال (ادمین)"
        elif obj.qr_enabled:
            return "✅ فعال"
        else:
            return "⬜ غیرفعال (کاربر)"
    qr_status.short_description = "وضعیت QR"

    def ticket_dept_mode(self, obj):
        modes = {"default": "⚙️ پیش‌فرض", "required": "✅ اجباری", "optional": "⬜ اختیاری"}
        return modes.get(obj.ticket_department_mode, obj.ticket_department_mode)
    ticket_dept_mode.short_description = "دپارتمان تیکت"

    def qr_info_display(self, obj):
        from django.utils.html import format_html
        html = "<div style='background:#f0fdf4;padding:10px;border-radius:5px;border:1px solid #bbf7d0;'>"
        html += f"<p><b>توکن:</b> <code>{obj.qr_token or 'ندارد'}</code></p>"
        html += f"<p><b>فعال توسط کاربر:</b> {'✅ بله' if obj.qr_enabled else '❌ خیر'}</p>"
        html += f"<p><b>غیرفعال توسط ادمین:</b> {'🚫 بله' if obj.qr_admin_disabled else '✅ خیر'}</p>"
        html += "<hr style='margin:10px 0;border-color:#bbf7d0;'>"
        html += f"<p><b>نمایش نام:</b> {'✓' if obj.qr_show_name else '✗'} | "
        html += f"<b>ایمیل:</b> {'✓' if obj.qr_show_email else '✗'} | "
        html += f"<b>تاریخ:</b> {'✓' if obj.qr_show_join_date else '✗'} | "
        html += f"<b>دوره‌ها:</b> {'✓' if obj.qr_show_courses else '✗'} | "
        html += f"<b>آمار:</b> {'✓' if obj.qr_show_stats else '✗'}</p>"
        html += "</div>"
        return format_html(html)
    qr_info_display.short_description = "اطلاعات QR Code"

    @admin.action(description="فعال کردن QR برای کاربران انتخاب شده")
    def enable_qr_for_users(self, request, queryset):
        queryset.update(qr_admin_disabled=False)
        self.message_user(request, f"QR Code برای {queryset.count()} کاربر فعال شد.")

    @admin.action(description="غیرفعال کردن QR برای کاربران انتخاب شده")
    def disable_qr_for_users(self, request, queryset):
        queryset.update(qr_admin_disabled=True)
        self.message_user(request, f"QR Code برای {queryset.count()} کاربر غیرفعال شد.")

    @admin.action(description="دپارتمان تیکت: اجباری")
    def set_dept_required(self, request, queryset):
        queryset.update(ticket_department_mode="required")
        self.message_user(request, f"دپارتمان برای {queryset.count()} کاربر اجباری شد.")

    @admin.action(description="دپارتمان تیکت: اختیاری")
    def set_dept_optional(self, request, queryset):
        queryset.update(ticket_department_mode="optional")
        self.message_user(request, f"دپارتمان برای {queryset.count()} کاربر اختیاری شد.")

    @admin.action(description="دپارتمان تیکت: پیش‌فرض سیستم")
    def set_dept_default(self, request, queryset):
        queryset.update(ticket_department_mode="default")
        self.message_user(request, f"دپارتمان برای {queryset.count()} کاربر به پیش‌فرض برگشت.")

    def security_info_display(self, obj):
        from django.utils.html import format_html
        html = "<div style='background:#f8f9fa;padding:10px;border-radius:5px;'>"
        
        if obj.q1:
            html += f"<p><b>سوال امنیتی:</b> {obj.q1.text}</p>"
            html += f"<p><b>وضعیت پاسخ:</b> {'✅ تنظیم شده (هش شده)' if obj.a1_hash else '❌ تنظیم نشده'}</p>"
        else:
            html += "<p><b>سوال امنیتی:</b> تنظیم نشده</p>"
            
        html += "<p style='color:#666;font-size:0.9em;margin-top:10px;'>⚠️ پاسخ امنیتی به صورت هش شده ذخیره می‌شود و قابل مشاهده نیست.</p>"
        html += "</div>"
        return format_html(html)
    security_info_display.short_description = "اطلاعات امنیتی"

    def has_extra_data(self, obj):
        try:
            return bool(obj.extra_data)
        except Exception:
            return False
    has_extra_data.boolean = True
    has_extra_data.short_description = "داده اضافی"

    def extra_data_display(self, obj):
        try:
            if not obj.extra_data:
                return "-"
            from django.utils.html import format_html
            lines = [f"<b>{k}:</b> {v}" for k, v in obj.extra_data.items()]
            return format_html("<br>".join(lines))
        except Exception:
            return "-"
    extra_data_display.short_description = "داده‌های اضافی"

PY
  cat > app/accounts/forms.py <<'PY'
from django import forms
from django.contrib.auth import get_user_model
from django.contrib.auth.forms import AuthenticationForm, UserCreationForm
from django.contrib.auth.hashers import make_password
from django.utils.translation import gettext_lazy as _

from .models import UserProfile, SecurityQuestion

User = get_user_model()

_INPUT = "w-full rounded-xl border border-slate-200 bg-white px-3 py-2 outline-none focus:ring-2 focus:ring-slate-300 dark:bg-slate-900 dark:border-slate-700 dark:focus:ring-slate-700"

def get_registration_fields():
    """Get active registration fields from database"""
    try:
        from settingsapp.models import RegistrationField
        return list(RegistrationField.objects.filter(is_active=True).order_by("order", "id"))
    except Exception:
        return []

def build_form_field(reg_field):
    """Build a Django form field from a RegistrationField model instance"""
    attrs = {"class": _INPUT}
    if reg_field.placeholder:
        attrs["placeholder"] = reg_field.placeholder
    if reg_field.field_type in ("email", "phone", "password", "text"):
        attrs["dir"] = "ltr"

    field_kwargs = {
        "label": reg_field.label,
        "required": reg_field.is_required,
        "help_text": reg_field.help_text or "",
    }

    if reg_field.field_type == "text":
        return forms.CharField(widget=forms.TextInput(attrs=attrs), **field_kwargs)
    elif reg_field.field_type == "email":
        attrs["autocomplete"] = "email"
        return forms.EmailField(widget=forms.EmailInput(attrs=attrs), **field_kwargs)
    elif reg_field.field_type == "phone":
        attrs["autocomplete"] = "tel"
        return forms.CharField(widget=forms.TextInput(attrs=attrs), **field_kwargs)
    elif reg_field.field_type == "textarea":
        attrs["rows"] = 3
        return forms.CharField(widget=forms.Textarea(attrs=attrs), **field_kwargs)
    elif reg_field.field_type == "select":
        choices = [("", _("انتخاب کنید"))] + [(c, c) for c in reg_field.get_choices_list()]
        return forms.ChoiceField(choices=choices, widget=forms.Select(attrs=attrs), **field_kwargs)
    elif reg_field.field_type == "checkbox":
        return forms.BooleanField(widget=forms.CheckboxInput(attrs={"class": "rounded"}), **field_kwargs)
    elif reg_field.field_type == "password":
        attrs["autocomplete"] = "new-password"
        return forms.CharField(widget=forms.PasswordInput(attrs=attrs), **field_kwargs)
    else:
        return forms.CharField(widget=forms.TextInput(attrs=attrs), **field_kwargs)

class LoginForm(AuthenticationForm):
    username = forms.CharField(
        label=_("ایمیل"),
        widget=forms.TextInput(attrs={"class": _INPUT, "autocomplete":"email", "dir":"ltr"})
    )
    password = forms.CharField(
        label=_("گذرواژه"),
        widget=forms.PasswordInput(attrs={"class": _INPUT, "autocomplete":"current-password", "dir":"ltr"})
    )

class RegisterForm(UserCreationForm):
    email = forms.EmailField(
        label=_("ایمیل"),
        widget=forms.EmailInput(attrs={"class": _INPUT, "autocomplete":"email", "dir":"ltr"})
    )

    security_question = forms.ModelChoiceField(
        queryset=SecurityQuestion.objects.none(),
        required=True,
        empty_label=_("انتخاب کنید"),
        label=_("سوال امنیتی"),
        widget=forms.Select(attrs={"class": _INPUT})
    )
    security_answer = forms.CharField(
        required=True,
        label=_("پاسخ سوال امنیتی"),
        widget=forms.PasswordInput(attrs={"class": _INPUT, "autocomplete":"off"})
    )

    password1 = forms.CharField(
        label=_("گذرواژه"),
        widget=forms.PasswordInput(attrs={"class": _INPUT, "autocomplete":"new-password", "dir":"ltr"})
    )
    password2 = forms.CharField(
        label=_("تکرار گذرواژه"),
        widget=forms.PasswordInput(attrs={"class": _INPUT, "autocomplete":"new-password", "dir":"ltr"})
    )

    class Meta:
        model = User
        fields = ("email",)

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._dynamic_fields = []

        # Set the queryset dynamically to avoid issues when table doesn't exist
        try:
            self.fields['security_question'].queryset = SecurityQuestion.objects.filter(is_active=True).order_by("order", "text")
        except Exception:
            pass

        # Add dynamic fields from RegistrationField model
        try:
            for reg_field in get_registration_fields():
                # Skip system fields that are already defined
                if reg_field.field_key in ("email", "password1", "password2", "security_question", "security_answer"):
                    continue
                field = build_form_field(reg_field)
                self.fields[f"custom_{reg_field.field_key}"] = field
                self._dynamic_fields.append(reg_field.field_key)
        except Exception:
            pass  # Database might not be ready during migrations

        # Reorder fields
        ordered = ["email", "security_question", "security_answer", "password1", "password2"]
        for key in self._dynamic_fields:
            ordered.append(f"custom_{key}")
        self.order_fields(ordered)

    def clean_email(self):
        e = (self.cleaned_data.get("email") or "").strip().lower()
        if not e:
            raise forms.ValidationError(_("ایمیل الزامی است."))
        if User.objects.filter(email__iexact=e).exists():
            raise forms.ValidationError(_("این ایمیل قبلاً ثبت شده است."))
        return e

    def clean_security_answer(self):
        a = (self.cleaned_data.get("security_answer") or "").strip()
        if len(a) < 2:
            raise forms.ValidationError(_("پاسخ کوتاه است."))
        return a

    def get_custom_field_data(self):
        """Return a dict of custom field values"""
        data = {}
        for key in self._dynamic_fields:
            field_name = f"custom_{key}"
            if field_name in self.cleaned_data:
                data[key] = self.cleaned_data[field_name]
        return data

    def save(self, commit=True):
        user = super().save(commit=False)
        user.email = (self.cleaned_data.get("email") or "").strip().lower()
        if commit:
            user.save()
            prof, _ = UserProfile.objects.get_or_create(user=user)
            prof.q1 = self.cleaned_data.get("security_question")
            ans = (self.cleaned_data.get("security_answer") or "").strip().lower()
            prof.a1_hash = make_password(ans)

            # Save custom fields to profile extra_data (safely)
            try:
                custom_data = self.get_custom_field_data()
                if custom_data and hasattr(prof, 'extra_data'):
                    prof.extra_data = custom_data
            except Exception:
                pass
            prof.save()
        return user

class ProfileForm(forms.Form):
    """Profile form that only shows custom registration fields"""

    def __init__(self, *args, profile=None, **kwargs):
        super().__init__(*args, **kwargs)
        self.profile = profile
        self._dynamic_fields = []

        # Only add dynamic fields that should show in profile (from RegistrationField)
        try:
            for reg_field in get_registration_fields():
                if not reg_field.show_in_profile:
                    continue
                # Skip system fields
                if reg_field.field_key in ("email", "password1", "password2", "security_question", "security_answer"):
                    continue
                field = build_form_field(reg_field)
                field_name = f"custom_{reg_field.field_key}"
                self.fields[field_name] = field
                self._dynamic_fields.append(reg_field.field_key)

                # Set initial value from profile extra_data
                if profile:
                    extra_data = getattr(profile, 'extra_data', None) or {}
                    if reg_field.field_key in extra_data:
                        self.initial[field_name] = extra_data[reg_field.field_key]
        except Exception:
            pass

    def get_custom_field_data(self):
        """Return a dict of custom field values"""
        data = {}
        for key in self._dynamic_fields:
            field_name = f"custom_{key}"
            if field_name in self.cleaned_data:
                data[key] = self.cleaned_data[field_name]
        return data

class SecurityQuestionsForm(forms.Form):
    q1 = forms.ModelChoiceField(
        queryset=SecurityQuestion.objects.none(),
        required=True,
        label=_("سوال امنیتی"),
        widget=forms.Select(attrs={"class": _INPUT})
    )
    a1 = forms.CharField(
        required=True,
        label=_("پاسخ سوال امنیتی"),
        widget=forms.PasswordInput(attrs={"class": _INPUT, "autocomplete": "off"})
    )

    def __init__(self, *args, user=None, **kwargs):
        super().__init__(*args, **kwargs)
        self.user = user
        # Set queryset dynamically
        try:
            qs = SecurityQuestion.objects.filter(is_active=True).order_by("order", "text")
            self.fields['q1'].queryset = qs
        except Exception:
            pass

    def clean(self):
        return super().clean()

class ResetStep1Form(forms.Form):
    identifier = forms.CharField(
        label=_("ایمیل یا نام کاربری"),
        widget=forms.TextInput(attrs={"class": _INPUT, "dir": "ltr", "autocomplete": "username"})
    )

class ResetStep2Form(forms.Form):
    a1 = forms.CharField(
        label=_("پاسخ سوال امنیتی"),
        widget=forms.PasswordInput(attrs={"class": _INPUT, "autocomplete": "off"})
    )
    new_password1 = forms.CharField(
        label=_("رمز جدید"),
        widget=forms.PasswordInput(attrs={"class": _INPUT, "autocomplete": "new-password", "dir": "ltr"})
    )
    new_password2 = forms.CharField(
        label=_("تکرار رمز جدید"),
        widget=forms.PasswordInput(attrs={"class": _INPUT, "autocomplete": "new-password", "dir": "ltr"})
    )

    def clean(self):
        c = super().clean()
        p1 = c.get("new_password1")
        p2 = c.get("new_password2")
        if p1 and p2 and p1 != p2:
            raise forms.ValidationError(_("رمزها یکسان نیستند."))
        return c
PY

  cat > app/accounts/backends.py <<'PY'
from django.contrib.auth.backends import ModelBackend
from django.contrib.auth import get_user_model
from django.db.models import Q

class EmailOrUsernameBackend(ModelBackend):
  """Authenticate with either username OR email in the same login field."""
  def authenticate(self, request, username=None, password=None, **kwargs):
    UserModel = get_user_model()
    identifier = (username or kwargs.get("email") or "").strip()
    if not identifier or not password:
      return None
    try:
      user = UserModel.objects.get(Q(username__iexact=identifier) | Q(email__iexact=identifier))
    except UserModel.DoesNotExist:
      UserModel().set_password(password)
      return None
    if user.check_password(password) and self.user_can_authenticate(user):
      return user
    return None
PY


  cat > app/accounts/views.py <<'PY'
from django.contrib.auth.views import LoginView, LogoutView
from django.views.generic import CreateView
from django.urls import reverse_lazy
from django.contrib import messages
from django.shortcuts import redirect, render
from django.contrib.auth.decorators import login_required
from django.contrib.auth import get_user_model
from .forms import RegisterForm, LoginForm, ProfileForm, SecurityQuestionsForm, ResetStep1Form, ResetStep2Form
from .models import UserProfile

User = get_user_model()

class SiteLoginView(LoginView):
  template_name="accounts/login.html"
  authentication_form=LoginForm

class SiteLogoutView(LogoutView):
  http_method_names=["post"]
  next_page="/"

class RegisterView(CreateView):
  form_class=RegisterForm
  template_name="accounts/register.html"
  success_url=reverse_lazy("dashboard_home")

  def form_valid(self, form):
    from django.contrib.auth import login
    response = super().form_valid(form)
    # Auto login after registration - specify backend
    login(self.request, self.object, backend='accounts.backends.EmailOrUsernameBackend')
    messages.success(self.request, "حساب کاربری شما با موفقیت ایجاد شد. خوش آمدید!")
    return response

@login_required
def profile_edit(request):
  # Check if profile editing is allowed
  allow_edit = True
  try:
    from settingsapp.models import SiteSetting
    site_setting = SiteSetting.objects.first()
    if site_setting:
      allow_edit = getattr(site_setting, 'allow_profile_edit', True)
  except Exception:
    pass

  profile, _ = UserProfile.objects.select_related("q1").get_or_create(user=request.user)

  if not allow_edit:
    return render(request, "accounts/profile.html", {"form": None, "profile": profile, "allow_edit": False})

  form = ProfileForm(request.POST or None, profile=profile)

  if request.method == "POST" and form.is_valid():
    # Save custom field data
    try:
      custom_data = form.get_custom_field_data()
      if custom_data:
        extra = getattr(profile, 'extra_data', None) or {}
        extra.update(custom_data)
        profile.extra_data = extra
        profile.save(update_fields=["extra_data"])
        messages.success(request, "پروفایل بروزرسانی شد.")
    except Exception:
      pass
    return redirect("profile_edit")

  return render(request, "accounts/profile.html", {"form": form, "profile": profile, "allow_edit": True})

@login_required
def security_questions(request):
  # Check if security questions editing is allowed
  allow_edit = True
  try:
    from settingsapp.models import SiteSetting
    site_setting = SiteSetting.objects.first()
    if site_setting:
      allow_edit = getattr(site_setting, 'allow_security_edit', True)
  except Exception:
    pass

  if not allow_edit:
    messages.error(request, "تغییر سوال امنیتی توسط مدیر غیرفعال شده است.")
    return render(request, "accounts/security_questions.html", {"form": None, "allow_edit": False})

  profile,_ = UserProfile.objects.get_or_create(user=request.user)
  init={}
  if profile.q1: init["q1"]=profile.q1
  form = SecurityQuestionsForm(request.POST or None, user=request.user, initial=init)
  if request.method=="POST" and form.is_valid():
    profile.q1=form.cleaned_data["q1"]
    profile.set_answer(form.cleaned_data["a1"])
    profile.save(update_fields=["q1","a1_hash"])
    messages.success(request,"سوال امنیتی بروزرسانی شد.")
    return redirect("security_questions")
  return render(request,"accounts/security_questions.html",{"form":form, "allow_edit": True})

def reset_step1(request):
  form=ResetStep1Form(request.POST or None)
  if request.method=="POST" and form.is_valid():
    ident=(form.cleaned_data["identifier"] or "").strip()
    user = User.objects.filter(username__iexact=ident).first() or User.objects.filter(email__iexact=ident).first()
    if not user:
      messages.error(request,"کاربر پیدا نشد.")
      return redirect("reset_step1")
    profile = UserProfile.objects.filter(user=user).select_related("q1").first()
    if not profile or not (profile.q1 and profile.a1_hash):
      messages.error(request,"برای این کاربر سوال امنیتی تنظیم نشده است.")
      return redirect("reset_step1")
    request.session["reset_user_id"]=str(user.id)
    return redirect("reset_step2")
  return render(request,"accounts/reset_step1.html",{"form":form})

def reset_step2(request):
  uid=request.session.get("reset_user_id")
  if not uid: return redirect("reset_step1")
  user=User.objects.filter(id=uid).first()
  if not user:
    request.session.pop("reset_user_id",None); return redirect("reset_step1")
  profile=UserProfile.objects.filter(user=user).select_related("q1").first()
  if not profile or not profile.q1:
    request.session.pop("reset_user_id",None); return redirect("reset_step1")
  form=ResetStep2Form(request.POST or None)
  if request.method=="POST" and form.is_valid():
    if not profile.check_answer(form.cleaned_data["a1"]):
      messages.error(request,"پاسخ صحیح نیست.")
      return redirect("reset_step2")
    user.set_password(form.cleaned_data["new_password1"]); user.save(update_fields=["password"])
    request.session.pop("reset_user_id",None)
    messages.success(request,"رمز تغییر کرد. وارد شوید.")
    return redirect("login")
  return render(request,"accounts/reset_step2.html",{"form":form,"q1":profile.q1.text,"username":user.username})

@login_required
def qr_settings(request):
  """تنظیمات QR Code کاربر"""
  # Check if QR feature is enabled globally
  try:
    from settingsapp.models import SiteSetting
    site_setting = SiteSetting.objects.first()
    if site_setting and not site_setting.qr_feature_enabled:
      messages.error(request, "قابلیت QR Code توسط مدیر غیرفعال شده است.")
      return redirect("dashboard_home")
  except Exception:
    pass

  profile, _ = UserProfile.objects.get_or_create(user=request.user)
  
  # Check if admin disabled for this user
  if profile.qr_admin_disabled:
    messages.error(request, "QR Code شما توسط مدیر غیرفعال شده است.")
    return redirect("dashboard_home")

  # Generate token if not exists
  if not profile.qr_token:
    import secrets
    profile.qr_token = secrets.token_urlsafe(32)
    profile.save(update_fields=["qr_token"])

  if request.method == "POST":
    profile.qr_enabled = request.POST.get("qr_enabled") == "on"
    profile.qr_show_name = request.POST.get("qr_show_name") == "on"
    profile.qr_show_email = request.POST.get("qr_show_email") == "on"
    profile.qr_show_join_date = request.POST.get("qr_show_join_date") == "on"
    profile.qr_show_courses = request.POST.get("qr_show_courses") == "on"
    profile.qr_show_progress = request.POST.get("qr_show_progress") == "on"
    profile.qr_show_stats = request.POST.get("qr_show_stats") == "on"
    profile.save(update_fields=["qr_enabled", "qr_show_name", "qr_show_email", "qr_show_join_date", "qr_show_courses", "qr_show_progress", "qr_show_stats"])
    messages.success(request, "تنظیمات QR Code ذخیره شد.")
    return redirect("qr_settings")

  # Generate QR URL
  qr_url = request.build_absolute_uri(f"/qr/{profile.qr_token}/")
  
  return render(request, "accounts/qr_settings.html", {"profile": profile, "qr_url": qr_url})

@login_required
def qr_regenerate(request):
  """بازسازی توکن QR Code"""
  if request.method == "POST":
    import secrets
    profile, _ = UserProfile.objects.get_or_create(user=request.user)
    profile.qr_token = secrets.token_urlsafe(32)
    profile.save(update_fields=["qr_token"])
    messages.success(request, "توکن QR Code جدید ساخته شد.")
  return redirect("qr_settings")

def qr_public_profile(request, token):
  """نمایش پروفایل عمومی از طریق QR"""
  from courses.models import Enrollment
  
  # Check if QR feature is enabled globally
  try:
    from settingsapp.models import SiteSetting
    site_setting = SiteSetting.objects.first()
    if site_setting and not site_setting.qr_feature_enabled:
      return render(request, "accounts/qr_disabled.html", {"message": "قابلیت QR Code غیرفعال است."})
  except Exception:
    pass

  try:
    profile = UserProfile.objects.select_related("user").get(qr_token=token)
  except UserProfile.DoesNotExist:
    return render(request, "accounts/qr_disabled.html", {"message": "لینک نامعتبر است."})

  # Check if disabled
  if not profile.qr_enabled or profile.qr_admin_disabled:
    return render(request, "accounts/qr_disabled.html", {"message": "این پروفایل غیرفعال است."})

  user = profile.user
  data = {"verified": True, "verified_at": profile.updated_at}

  if profile.qr_show_name:
    data["name"] = user.get_full_name() or user.username
  if profile.qr_show_email:
    data["email"] = user.email
  if profile.qr_show_join_date:
    data["join_date"] = user.date_joined

  enrollments = []
  total_courses = 0
  if profile.qr_show_courses or profile.qr_show_progress or profile.qr_show_stats:
    enrollments = Enrollment.objects.filter(user=user, is_active=True).select_related("course")
    total_courses = enrollments.count()

  if profile.qr_show_courses:
    data["courses"] = [{"title": e.course.title, "slug": e.course.slug} for e in enrollments]
  if profile.qr_show_stats:
    data["total_courses"] = total_courses

  return render(request, "accounts/qr_public.html", {"data": data, "profile": profile})

@login_required  
def qr_image(request):
  """Generate QR Code Image"""
  import qrcode
  import io
  from django.http import HttpResponse
  
  profile, _ = UserProfile.objects.get_or_create(user=request.user)
  if not profile.qr_token:
    import secrets
    profile.qr_token = secrets.token_urlsafe(32)
    profile.save(update_fields=["qr_token"])

  qr_url = request.build_absolute_uri(f"/qr/{profile.qr_token}/")
  
  qr = qrcode.QRCode(version=1, error_correction=qrcode.constants.ERROR_CORRECT_L, box_size=10, border=4)
  qr.add_data(qr_url)
  qr.make(fit=True)
  img = qr.make_image(fill_color="black", back_color="white")
  
  buffer = io.BytesIO()
  img.save(buffer, format="PNG")
  buffer.seek(0)
  
  return HttpResponse(buffer.getvalue(), content_type="image/png")
PY

  cat > app/accounts/urls.py <<'PY'
from django.urls import path
from .views import SiteLoginView, SiteLogoutView, RegisterView, profile_edit, security_questions, reset_step1, reset_step2, qr_settings, qr_regenerate, qr_public_profile, qr_image
urlpatterns=[
  path("login/", SiteLoginView.as_view(), name="login"),
  path("logout/", SiteLogoutView.as_view(), name="logout"),
  path("register/", RegisterView.as_view(), name="register"),
  path("profile/", profile_edit, name="profile_edit"),
  path("security/", security_questions, name="security_questions"),
  path("reset/", reset_step1, name="reset_step1"),
  path("reset/verify/", reset_step2, name="reset_step2"),
  path("qr/", qr_settings, name="qr_settings"),
  path("qr/regenerate/", qr_regenerate, name="qr_regenerate"),
  path("qr/image/", qr_image, name="qr_image"),
]
PY

  cat > app/settingsapp/apps.py <<'PY'
from django.apps import AppConfig

class SettingsappConfig(AppConfig):
  default_auto_field="django.db.models.BigAutoField"
  name="settingsapp"
  verbose_name="تنظیمات سایت"
  
  def ready(self):
    # ثبت سیگنال‌ها برای لاگ ورود
    from django.contrib.auth.signals import user_logged_in, user_login_failed
    from .signals import log_successful_login, log_failed_login
    
    user_logged_in.connect(log_successful_login)
    user_login_failed.connect(log_failed_login)
PY

  cat > app/settingsapp/signals.py <<'PY'
"""سیگنال‌های مربوط به امنیت و ورود"""

def log_successful_login(sender, request, user, **kwargs):
  """ثبت ورود موفق"""
  try:
    from .ip_security import record_login_attempt
    username = getattr(user, 'email', '') or getattr(user, 'username', '')
    record_login_attempt(request, username, is_successful=True)
  except Exception as e:
    print(f"Error logging successful login: {e}")

def log_failed_login(sender, credentials, request, **kwargs):
  """ثبت تلاش ناموفق ورود"""
  try:
    from .ip_security import record_login_attempt
    username = credentials.get('username', '') or credentials.get('email', '')
    record_login_attempt(request, username, is_successful=False)
  except Exception as e:
    print(f"Error logging failed login: {e}")
PY
  cat > app/settingsapp/models.py <<'PY'
from django.db import models
from django.utils.translation import gettext_lazy as _

class SiteSetting(models.Model):
  brand_name = models.CharField(max_length=120, default="EduCMS", verbose_name=_("نام برند"))
  logo = models.ImageField(upload_to="branding/", blank=True, null=True, verbose_name=_("لوگو"))
  favicon = models.ImageField(upload_to="branding/", blank=True, null=True, verbose_name=_("فاویکن"))
  THEME_MODE = (("light",_("روشن")),("dark",_("تاریک")),("system",_("سیستم")))
  default_theme = models.CharField(max_length=10, choices=THEME_MODE, default="system", verbose_name=_("تم پیش‌فرض"))
  CALENDAR_TYPE = (("jalali",_("شمسی")),("gregorian",_("میلادی")))
  calendar_type = models.CharField(max_length=10, choices=CALENDAR_TYPE, default="jalali", verbose_name=_("نوع تقویم"))
  footer_text = models.TextField(blank=True, verbose_name=_("متن فوتر"))
  admin_path = models.SlugField(max_length=50, default="admin", verbose_name=_("مسیر ادمین"))
  allow_profile_edit = models.BooleanField(default=True, verbose_name=_("اجازه ویرایش پروفایل توسط کاربران"))
  allow_security_edit = models.BooleanField(default=True, verbose_name=_("اجازه تغییر سوال امنیتی توسط کاربران"))
  qr_feature_enabled = models.BooleanField(default=True, verbose_name=_("قابلیت QR Code فعال"))
  ticket_department_required = models.BooleanField(default=True, verbose_name=_("انتخاب دپارتمان تیکت اجباری"))
  updated_at = models.DateTimeField(auto_now=True)
  class Meta:
    verbose_name=_("تنظیمات سایت"); verbose_name_plural=_("تنظیمات سایت")
  def __str__(self): return "Site Settings"
  def save(self, *args, **kwargs):
    from django.core.cache import cache
    cache.delete('site_calendar_type')
    return super().save(*args, **kwargs)

class RegistrationFieldType(models.TextChoices):
  TEXT = "text", _("متن کوتاه")
  EMAIL = "email", _("ایمیل")
  PHONE = "phone", _("شماره تلفن")
  TEXTAREA = "textarea", _("متن بلند")
  SELECT = "select", _("انتخابی")
  CHECKBOX = "checkbox", _("چک‌باکس")
  PASSWORD = "password", _("رمز عبور")

class RegistrationField(models.Model):
  field_key = models.SlugField(max_length=50, unique=True, verbose_name=_("کلید فیلد"))
  label = models.CharField(max_length=150, verbose_name=_("برچسب"))
  field_type = models.CharField(max_length=20, choices=RegistrationFieldType.choices, default=RegistrationFieldType.TEXT, verbose_name=_("نوع فیلد"))
  placeholder = models.CharField(max_length=200, blank=True, verbose_name=_("متن راهنما"))
  help_text = models.CharField(max_length=300, blank=True, verbose_name=_("متن کمکی"))
  choices = models.TextField(blank=True, verbose_name=_("گزینه‌ها"), help_text=_("هر گزینه در یک خط (فقط برای فیلد انتخابی)"))
  is_required = models.BooleanField(default=False, verbose_name=_("اجباری"))
  is_active = models.BooleanField(default=True, verbose_name=_("فعال"))
  is_system = models.BooleanField(default=False, verbose_name=_("فیلد سیستمی"), help_text=_("فیلدهای سیستمی قابل حذف یا غیرفعال‌سازی نیستند"))
  show_in_profile = models.BooleanField(default=True, verbose_name=_("نمایش در پروفایل"))
  order = models.PositiveIntegerField(default=0, verbose_name=_("ترتیب"))
  created_at = models.DateTimeField(auto_now_add=True)
  updated_at = models.DateTimeField(auto_now=True)

  class Meta:
    ordering = ["order", "id"]
    verbose_name = _("فیلد ثبت‌نام")
    verbose_name_plural = _("فیلدهای ثبت‌نام")

  def __str__(self):
    return f"{self.label} ({self.field_key})"

  def get_choices_list(self):
    if not self.choices:
      return []
    return [c.strip() for c in self.choices.strip().split("\n") if c.strip()]

  def save(self, *args, **kwargs):
    if self.is_system:
      self.is_active = True
    super().save(*args, **kwargs)

class TemplateText(models.Model):
  key=models.SlugField(max_length=150, unique=True)
  title=models.CharField(max_length=200)
  value=models.TextField(blank=True)
  hint=models.CharField(max_length=300, blank=True)
  updated_at=models.DateTimeField(auto_now=True)
  class Meta:
    ordering=["key"]; verbose_name="متن قالب"; verbose_name_plural="متن‌های قالب"
  def __str__(self): return self.key

class NavLink(models.Model):
  area = models.CharField(max_length=10, choices=(("header","هدر"),("footer","فوتر")), default="footer")
  title=models.CharField(max_length=120)
  url=models.CharField(max_length=300)
  order=models.PositiveIntegerField(default=0)
  is_active=models.BooleanField(default=True)
  class Meta:
    ordering=["area","order"]; verbose_name="لینک"; verbose_name_plural="لینک‌ها"
  def __str__(self): return f"{self.area}:{self.title}"

# ==================== IP SECURITY ====================

class IPSecuritySetting(models.Model):
  """تنظیمات امنیتی IP"""
  is_enabled = models.BooleanField(default=True, verbose_name=_("محدودیت IP فعال"))
  max_attempts = models.PositiveIntegerField(default=5, verbose_name=_("حداکثر تلاش ناموفق"))
  
  BLOCK_DURATION_TYPE = (
    ("minutes", _("دقیقه")),
    ("hours", _("ساعت")),
    ("today", _("تا پایان امروز")),
    ("forever", _("دائمی")),
  )
  block_duration_type = models.CharField(max_length=10, choices=BLOCK_DURATION_TYPE, default="minutes", verbose_name=_("نوع مدت زمان"))
  block_duration_value = models.PositiveIntegerField(default=30, verbose_name=_("مقدار زمان"), help_text=_("برای دقیقه و ساعت"))
  
  reset_attempts_after = models.PositiveIntegerField(default=60, verbose_name=_("پاک شدن تلاش‌ها بعد از (دقیقه)"), help_text=_("بعد از این زمان، شمارش تلاش‌های ناموفق ریست می‌شود"))
  
  updated_at = models.DateTimeField(auto_now=True)
  
  class Meta:
    verbose_name = _("تنظیمات امنیت IP")
    verbose_name_plural = _("تنظیمات امنیت IP")
  
  def __str__(self):
    return "تنظیمات امنیت IP"
  
  @classmethod
  def get_settings(cls):
    obj, _ = cls.objects.get_or_create(pk=1)
    return obj

class IPWhitelist(models.Model):
  """لیست سفید IP - این IP ها هیچوقت بلاک نمی‌شوند"""
  ip_address = models.GenericIPAddressField(unique=True, verbose_name=_("آدرس IP"))
  description = models.CharField(max_length=200, blank=True, verbose_name=_("توضیحات"))
  created_at = models.DateTimeField(auto_now_add=True, verbose_name=_("تاریخ ایجاد"))
  
  class Meta:
    verbose_name = _("IP مجاز (Whitelist)")
    verbose_name_plural = _("IP های مجاز (Whitelist)")
  
  def __str__(self):
    return f"{self.ip_address} - {self.description or 'بدون توضیح'}"

class IPBlockType(models.TextChoices):
  AUTO = "auto", _("خودکار (تلاش ناموفق)")
  MANUAL = "manual", _("دستی")

class IPBlacklist(models.Model):
  """لیست سیاه IP - IP های بلاک شده"""
  ip_address = models.GenericIPAddressField(verbose_name=_("آدرس IP"))
  block_type = models.CharField(max_length=10, choices=IPBlockType.choices, default=IPBlockType.AUTO, verbose_name=_("نوع بلاک"))
  reason = models.CharField(max_length=300, blank=True, verbose_name=_("دلیل"))
  is_permanent = models.BooleanField(default=False, verbose_name=_("دائمی"))
  blocked_at = models.DateTimeField(auto_now_add=True, verbose_name=_("زمان بلاک"))
  expires_at = models.DateTimeField(blank=True, null=True, verbose_name=_("تاریخ انقضا"))
  failed_attempts = models.PositiveIntegerField(default=0, verbose_name=_("تعداد تلاش ناموفق"))
  
  class Meta:
    verbose_name = _("IP بلاک شده")
    verbose_name_plural = _("IP های بلاک شده")
  
  def __str__(self):
    status = "دائمی" if self.is_permanent else f"تا {self.expires_at}"
    return f"{self.ip_address} ({status})"
  
  def is_active(self):
    """آیا بلاک هنوز فعال است؟"""
    if self.is_permanent:
      return True
    if self.expires_at:
      from django.utils import timezone
      return timezone.now() < self.expires_at
    return False
  is_active.boolean = True
  is_active.short_description = _("فعال")

class LoginAttempt(models.Model):
  """ثبت تلاش‌های ورود"""
  ip_address = models.GenericIPAddressField(verbose_name=_("آدرس IP"), db_index=True)
  username = models.CharField(max_length=150, blank=True, verbose_name=_("نام کاربری"))
  is_successful = models.BooleanField(default=False, verbose_name=_("موفق"))
  user_agent = models.TextField(blank=True, verbose_name=_("User Agent"))
  attempted_at = models.DateTimeField(auto_now_add=True, verbose_name=_("زمان تلاش"), db_index=True)
  
  class Meta:
    verbose_name = _("تلاش ورود")
    verbose_name_plural = _("تلاش‌های ورود")
    ordering = ["-attempted_at"]
  
  def __str__(self):
    status = "✓" if self.is_successful else "✗"
    return f"{self.ip_address} - {self.username} [{status}]"
PY
  # فایل کمکی برای تاریخ هوشمند در ادمین
  cat > app/settingsapp/date_utils.py <<'PY'
import jdatetime
import pytz
from django.utils import timezone

TEHRAN_TZ = pytz.timezone('Asia/Tehran')

PERSIAN_MONTHS = [
    'فروردین', 'اردیبهشت', 'خرداد', 'تیر', 'مرداد', 'شهریور',
    'مهر', 'آبان', 'آذر', 'دی', 'بهمن', 'اسفند'
]

GREGORIAN_MONTHS = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December'
]

def get_calendar_type():
    """دریافت نوع تقویم از تنظیمات سایت"""
    try:
        from settingsapp.models import SiteSetting
        setting = SiteSetting.objects.first()
        return setting.calendar_type if setting else 'jalali'
    except:
        return 'jalali'

def to_persian_num(num):
    """تبدیل اعداد انگلیسی به فارسی"""
    persian_digits = '۰۱۲۳۴۵۶۷۸۹'
    return ''.join(persian_digits[int(d)] if d.isdigit() else d for d in str(num))

def convert_to_tehran(value):
    """تبدیل زمان به تایم‌زون تهران"""
    if value is None:
        return None
    try:
        if timezone.is_aware(value):
            return value.astimezone(TEHRAN_TZ)
        else:
            return pytz.utc.localize(value).astimezone(TEHRAN_TZ)
    except:
        return value

def smart_format_datetime(value, include_time=True):
    """فرمت هوشمند تاریخ بر اساس تنظیمات سایت"""
    if not value:
        return "-"
    try:
        value = convert_to_tehran(value)
        cal_type = get_calendar_type()
        
        if cal_type == 'gregorian':
            if include_time:
                return f"{value.day} {GREGORIAN_MONTHS[value.month-1]} {value.year} - {value.hour:02d}:{value.minute:02d}"
            else:
                return f"{value.day} {GREGORIAN_MONTHS[value.month-1]} {value.year}"
        else:
            jdate = jdatetime.datetime.fromgregorian(datetime=value)
            if include_time:
                return to_persian_num(f"{jdate.day} {PERSIAN_MONTHS[jdate.month-1]} {jdate.year} - {jdate.hour:02d}:{jdate.minute:02d}")
            else:
                return to_persian_num(f"{jdate.day} {PERSIAN_MONTHS[jdate.month-1]} {jdate.year}")
    except:
        return str(value)

def smart_format_date(value):
    """فرمت هوشمند تاریخ بدون ساعت"""
    return smart_format_datetime(value, include_time=False)
PY

  cat > app/settingsapp/admin.py <<'PY'
from django.contrib import admin
from django.utils.html import format_html
from django.utils import timezone
from django.contrib import messages
from .date_utils import smart_format_datetime

# تنظیمات پایه ادمین
admin.site.site_header = "پنل مدیریت سایت"
admin.site.site_title = "پنل مدیریت"
admin.site.index_title = "خوش آمدید به پنل مدیریت"

from .models import SiteSetting, TemplateText, NavLink, IPSecuritySetting, IPWhitelist, IPBlacklist, LoginAttempt

@admin.register(SiteSetting)
class SiteSettingAdmin(admin.ModelAdmin):
    list_display = ("brand_name", "default_theme", "calendar_type", "qr_feature_enabled", "ticket_department_required", "updated_at_display")
    fieldsets = (
        ("برند", {"fields": ("brand_name", "logo", "favicon")}),
        ("تم و تقویم", {"fields": ("default_theme", "calendar_type")}),
        ("تنظیمات عمومی", {"fields": ("footer_text", "admin_path", "allow_profile_edit", "allow_security_edit")}),
        ("قابلیت‌ها", {"fields": ("qr_feature_enabled", "ticket_department_required"), 
                       "description": "فعال/غیرفعال کردن قابلیت‌های سایت"}),
    )
    
    def updated_at_display(self, obj):
        return smart_format_datetime(obj.updated_at)
    updated_at_display.short_description = "آخرین به‌روزرسانی"
    updated_at_display.admin_order_field = "updated_at"

@admin.register(TemplateText)
class TemplateTextAdmin(admin.ModelAdmin):
    list_display = ("key", "value")
    search_fields = ("key", "value")

@admin.register(NavLink)
class NavLinkAdmin(admin.ModelAdmin):
    list_display = ("title", "area", "url", "order", "is_active")
    list_filter = ("area", "is_active")
    ordering = ("area", "order")

# Register RegistrationField only if table exists
try:
    from .models import RegistrationField
    
    @admin.register(RegistrationField)
    class RegistrationFieldAdmin(admin.ModelAdmin):
        list_display = ("label", "field_key", "field_type", "order")
        search_fields = ("field_key", "label")
        ordering = ("order",)
except Exception:
    pass

# ==================== IP SECURITY ADMIN ====================

@admin.register(IPSecuritySetting)
class IPSecuritySettingAdmin(admin.ModelAdmin):
    list_display = ("__str__", "is_enabled_display", "max_attempts", "block_duration_display", "updated_at_display")
    
    fieldsets = (
        ("وضعیت", {
            "fields": ("is_enabled",),
            "description": "فعال یا غیرفعال کردن سیستم محدودیت IP"
        }),
        ("تنظیمات بلاک خودکار", {
            "fields": ("max_attempts", "reset_attempts_after"),
            "description": "تعداد تلاش ناموفق مجاز و زمان ریست شدن شمارش"
        }),
        ("مدت زمان بلاک", {
            "fields": ("block_duration_type", "block_duration_value"),
            "description": "مدت زمان بلاک شدن IP پس از تلاش‌های ناموفق"
        }),
    )
    
    def is_enabled_display(self, obj):
        if obj.is_enabled:
            return format_html('<span style="color:green;">✅ فعال</span>')
        return format_html('<span style="color:red;">❌ غیرفعال</span>')
    is_enabled_display.short_description = "وضعیت"
    
    def block_duration_display(self, obj):
        if obj.block_duration_type == "forever":
            return "دائمی"
        elif obj.block_duration_type == "today":
            return "تا پایان امروز"
        elif obj.block_duration_type == "hours":
            return f"{obj.block_duration_value} ساعت"
        else:
            return f"{obj.block_duration_value} دقیقه"
    block_duration_display.short_description = "مدت بلاک"
    
    def updated_at_display(self, obj):
        return smart_format_datetime(obj.updated_at)
    updated_at_display.short_description = "آخرین تغییر"

@admin.register(IPWhitelist)
class IPWhitelistAdmin(admin.ModelAdmin):
    list_display = ("ip_address", "description", "created_at_display")
    search_fields = ("ip_address", "description")
    ordering = ("ip_address",)
    
    fieldsets = (
        (None, {
            "fields": ("ip_address", "description"),
            "description": "IP هایی که در این لیست باشند هیچوقت بلاک نمی‌شوند. مناسب برای IP ادمین‌ها."
        }),
    )
    
    def created_at_display(self, obj):
        return smart_format_datetime(obj.created_at)
    created_at_display.short_description = "تاریخ ایجاد"

@admin.action(description="آنبلاک کردن IP های انتخاب شده")
def unblock_selected_ips(modeladmin, request, queryset):
    count = queryset.count()
    queryset.delete()
    messages.success(request, f"{count} آدرس IP آنبلاک شد.")

@admin.action(description="تبدیل به بلاک دائمی")
def make_permanent(modeladmin, request, queryset):
    queryset.update(is_permanent=True, expires_at=None)
    messages.success(request, f"{queryset.count()} آدرس IP به صورت دائمی بلاک شد.")

@admin.register(IPBlacklist)
class IPBlacklistAdmin(admin.ModelAdmin):
    list_display = ("ip_address", "block_type_display", "reason_short", "is_active_display", "blocked_at_display", "expires_at_display", "failed_attempts")
    list_filter = ("block_type", "is_permanent")
    search_fields = ("ip_address", "reason")
    ordering = ("-blocked_at",)
    actions = [unblock_selected_ips, make_permanent]
    
    fieldsets = (
        ("اطلاعات IP", {
            "fields": ("ip_address", "reason"),
        }),
        ("نوع بلاک", {
            "fields": ("block_type", "is_permanent", "expires_at"),
            "description": "برای بلاک دائمی، گزینه 'دائمی' را تیک بزنید. در غیر این صورت تاریخ انقضا را مشخص کنید."
        }),
    )
    
    def block_type_display(self, obj):
        if obj.block_type == "auto":
            return format_html('<span style="color:orange;">🤖 خودکار</span>')
        return format_html('<span style="color:purple;">👤 دستی</span>')
    block_type_display.short_description = "نوع"
    
    def reason_short(self, obj):
        if obj.reason:
            return obj.reason[:50] + "..." if len(obj.reason) > 50 else obj.reason
        return "-"
    reason_short.short_description = "دلیل"
    
    def is_active_display(self, obj):
        if obj.is_active():
            if obj.is_permanent:
                return format_html('<span style="color:red;">🔴 دائمی</span>')
            return format_html('<span style="color:orange;">🟠 فعال</span>')
        return format_html('<span style="color:green;">🟢 منقضی</span>')
    is_active_display.short_description = "وضعیت"
    
    def blocked_at_display(self, obj):
        return smart_format_datetime(obj.blocked_at)
    blocked_at_display.short_description = "زمان بلاک"
    blocked_at_display.admin_order_field = "blocked_at"
    
    def expires_at_display(self, obj):
        if obj.is_permanent:
            return format_html('<span style="color:red;">دائمی</span>')
        if obj.expires_at:
            return smart_format_datetime(obj.expires_at)
        return "-"
    expires_at_display.short_description = "انقضا"

@admin.action(description="پاکسازی لاگ‌های قدیمی‌تر از ۷ روز")
def cleanup_old_logs(modeladmin, request, queryset):
    from .ip_security import cleanup_old_attempts
    deleted, _ = cleanup_old_attempts(days=7)
    messages.success(request, f"{deleted} لاگ قدیمی پاک شد.")

@admin.register(LoginAttempt)
class LoginAttemptAdmin(admin.ModelAdmin):
    list_display = ("ip_address", "username", "is_successful_display", "attempted_at_display", "user_agent_short")
    list_filter = ("is_successful", "attempted_at")
    search_fields = ("ip_address", "username")
    ordering = ("-attempted_at",)
    readonly_fields = ("ip_address", "username", "is_successful", "user_agent", "attempted_at")
    actions = [cleanup_old_logs]
    
    def is_successful_display(self, obj):
        if obj.is_successful:
            return format_html('<span style="color:green;">✅ موفق</span>')
        return format_html('<span style="color:red;">❌ ناموفق</span>')
    is_successful_display.short_description = "وضعیت"
    
    def attempted_at_display(self, obj):
        return smart_format_datetime(obj.attempted_at)
    attempted_at_display.short_description = "زمان"
    attempted_at_display.admin_order_field = "attempted_at"
    
    def user_agent_short(self, obj):
        if obj.user_agent:
            return obj.user_agent[:60] + "..." if len(obj.user_agent) > 60 else obj.user_agent
        return "-"
    user_agent_short.short_description = "مرورگر"
    
    def has_add_permission(self, request):
        return False
    
    def has_change_permission(self, request, obj=None):
        return False
PY
  cat > app/settingsapp/context_processors.py <<'PY'
from .models import SiteSetting, TemplateText, NavLink
def site_context(request):
  try:
    s = SiteSetting.objects.first()
    texts = {t.key: t.value for t in TemplateText.objects.all()}
    header_links = list(NavLink.objects.filter(area="header", is_active=True).order_by("order"))
    footer_links = list(NavLink.objects.filter(area="footer", is_active=True).order_by("order"))
  except Exception:
    s = None
    texts = {}
    header_links = []
    footer_links = []
  return {"site_settings": s, "tpl": texts, "header_links": header_links, "footer_links": footer_links}
PY
  cat > app/settingsapp/forms.py <<'PY'
from django import forms
import re
_INPUT="w-full rounded-xl border border-slate-200 bg-white px-3 py-2 outline-none focus:ring-2 focus:ring-slate-300 dark:bg-slate-900 dark:border-slate-700 dark:focus:ring-slate-700"
class AdminPathForm(forms.Form):
  admin_path=forms.CharField(max_length=50, widget=forms.TextInput(attrs={"class":_INPUT,"dir":"ltr"}))
  def clean_admin_path(self):
    v=(self.cleaned_data.get("admin_path") or "").strip().strip("/") or "admin"
    if not re.fullmatch(r"[-A-Za-z0-9_]+", v):
      raise forms.ValidationError("مسیر نامعتبر است. فقط A-Z a-z 0-9 _ -")
    return v
class AdminAccountForm(forms.Form):
  username=forms.CharField(max_length=150, widget=forms.TextInput(attrs={"class":_INPUT}))
  password1=forms.CharField(widget=forms.PasswordInput(attrs={"class":_INPUT}))
  password2=forms.CharField(widget=forms.PasswordInput(attrs={"class":_INPUT}))
  def clean(self):
    c=super().clean()
    if c.get("password1")!=c.get("password2"):
      raise forms.ValidationError("رمزها یکسان نیستند.")
    return c
PY
  cat > app/settingsapp/views.py <<'PY'
from django.contrib.admin.views.decorators import staff_member_required
from django.contrib import messages
from django.shortcuts import render, redirect
from django.core.cache import cache
from .forms import AdminPathForm
from .models import SiteSetting
import os
import subprocess
import glob
from datetime import datetime

BACKUP_DIR = "/opt/educms/backups"

@staff_member_required
def admin_tools(request):
  """صفحه ابزارهای مدیریت"""
  return render(request, "settings/tools.html")

@staff_member_required
def admin_path_settings(request):
  s = SiteSetting.objects.first() or SiteSetting.objects.create()
  form = AdminPathForm(request.POST or None, initial={"admin_path": s.admin_path})
  if request.method=="POST" and form.is_valid():
    s.admin_path=form.cleaned_data["admin_path"]; s.save(update_fields=["admin_path"])
    cache.delete("site_admin_path")
    messages.success(request,f"مسیر ادمین تغییر کرد: /{s.admin_path}/")
    return redirect("admin_path_settings")
  return render(request,"settings/admin_path.html",{"form":form,"current":s.admin_path})

@staff_member_required
def backup_management(request):
  """مدیریت بکاپ و ریستور"""
  # Get list of backups
  backups = []
  if os.path.exists(BACKUP_DIR):
    sql_files = glob.glob(os.path.join(BACKUP_DIR, "*.sql"))
    for f in sql_files:
      stat = os.stat(f)
      backups.append({
        "name": os.path.basename(f),
        "path": f,
        "size": round(stat.st_size / 1024 / 1024, 2),  # MB
        "date": datetime.fromtimestamp(stat.st_mtime),
      })
    backups.sort(key=lambda x: x["date"], reverse=True)
  
  return render(request, "settings/backup.html", {"backups": backups})

@staff_member_required
def backup_create(request):
  """ایجاد بکاپ جدید"""
  if request.method == "POST":
    try:
      os.makedirs(BACKUP_DIR, exist_ok=True)
      ts = datetime.now().strftime("%Y%m%d-%H%M%S")
      db_name = os.getenv("DB_NAME", "educms")
      db_pass = os.getenv("DB_PASSWORD", "")
      backup_file = os.path.join(BACKUP_DIR, f"{db_name}-{ts}.sql")
      
      # Run mysqldump via docker compose
      cmd = f'cd /opt/educms && docker compose exec -T -e MYSQL_PWD="{db_pass}" db sh -lc "mysqldump -uroot --databases {db_name} --single-transaction --quick --routines --triggers --events --set-gtid-purged=OFF"'
      result = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=300)
      
      if result.returncode == 0:
        with open(backup_file, "w") as f:
          f.write(result.stdout)
        os.chmod(backup_file, 0o600)
        messages.success(request, f"بکاپ با موفقیت ایجاد شد: {os.path.basename(backup_file)}")
      else:
        messages.error(request, f"خطا در ایجاد بکاپ: {result.stderr}")
    except Exception as e:
      messages.error(request, f"خطا: {str(e)}")
  
  return redirect("backup_management")

@staff_member_required  
def backup_download(request, filename):
  """دانلود فایل بکاپ"""
  from django.http import FileResponse, Http404
  filepath = os.path.join(BACKUP_DIR, filename)
  if not os.path.exists(filepath) or ".." in filename:
    raise Http404("فایل یافت نشد")
  return FileResponse(open(filepath, "rb"), as_attachment=True, filename=filename)

@staff_member_required
def backup_delete(request, filename):
  """حذف فایل بکاپ"""
  if request.method == "POST":
    filepath = os.path.join(BACKUP_DIR, filename)
    if os.path.exists(filepath) and ".." not in filename:
      try:
        os.remove(filepath)
        messages.success(request, f"بکاپ حذف شد: {filename}")
      except Exception as e:
        messages.error(request, f"خطا در حذف: {str(e)}")
    else:
      messages.error(request, "فایل یافت نشد")
  return redirect("backup_management")

@staff_member_required
def backup_restore(request, filename):
  """ریستور از فایل بکاپ"""
  if request.method == "POST":
    filepath = os.path.join(BACKUP_DIR, filename)
    if not os.path.exists(filepath) or ".." in filename:
      messages.error(request, "فایل یافت نشد")
      return redirect("backup_management")
    
    confirm = request.POST.get("confirm", "")
    if confirm != "YES":
      messages.warning(request, "برای ریستور، YES را تایپ کنید")
      return redirect("backup_management")
    
    try:
      db_name = os.getenv("DB_NAME", "educms")
      db_pass = os.getenv("DB_PASSWORD", "")
      
      # Drop and recreate database, then restore
      cmd_drop = f'cd /opt/educms && docker compose exec -T -e MYSQL_PWD="{db_pass}" db sh -lc "mysql -uroot -e \'DROP DATABASE IF EXISTS \\`{db_name}\\`; CREATE DATABASE \\`{db_name}\\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;\'"'
      subprocess.run(cmd_drop, shell=True, check=True, timeout=60)
      
      cmd_restore = f'cd /opt/educms && docker compose exec -T -e MYSQL_PWD="{db_pass}" db sh -lc "mysql -uroot {db_name}" < "{filepath}"'
      result = subprocess.run(cmd_restore, shell=True, capture_output=True, text=True, timeout=300)
      
      if result.returncode == 0:
        messages.success(request, f"ریستور با موفقیت انجام شد از: {filename}")
      else:
        messages.error(request, f"خطا در ریستور: {result.stderr}")
    except Exception as e:
      messages.error(request, f"خطا: {str(e)}")
  
  return redirect("backup_management")
PY
  cat > app/settingsapp/urls.py <<'PY'
from django.urls import path
from .views import admin_path_settings, admin_tools, backup_management, backup_create, backup_download, backup_delete, backup_restore
urlpatterns=[
  path("tools/", admin_tools, name="admin_tools"),
  path("admin-path/", admin_path_settings, name="admin_path_settings"),
  path("backup/", backup_management, name="backup_management"),
  path("backup/create/", backup_create, name="backup_create"),
  path("backup/download/<str:filename>/", backup_download, name="backup_download"),
  path("backup/delete/<str:filename>/", backup_delete, name="backup_delete"),
  path("backup/restore/<str:filename>/", backup_restore, name="backup_restore"),
]
PY
  cat > app/settingsapp/admin_views.py <<'PY'
from django.contrib.admin.views.decorators import staff_member_required
from django.contrib.auth import update_session_auth_hash
from django.contrib import messages
from django.shortcuts import render, redirect
from .forms import AdminAccountForm

@staff_member_required
def admin_account_in_admin(request):
  form = AdminAccountForm(request.POST or None, initial={"username": request.user.username})
  if request.method=="POST" and form.is_valid():
    u=request.user
    u.username=form.cleaned_data["username"]
    u.set_password(form.cleaned_data["password1"])
    u.save()
    update_session_auth_hash(request,u)
    messages.success(request,"نام کاربری/رمز ادمین تغییر کرد.")
    return redirect("/admin/")
  return render(request,"settings/admin_account.html",{"form":form})
PY
  cat > app/settingsapp/middleware.py <<'PY'
from django.http import HttpResponseNotFound, HttpResponseForbidden
from django.utils.deprecation import MiddlewareMixin
from django.core.cache import cache
from django.utils import timezone
from datetime import timedelta
from .models import SiteSetting

def _get_admin_path():
  key="site_admin_path"
  try:
    v=cache.get(key)
    if v: return v
    s=SiteSetting.objects.first()
    v=(getattr(s,"admin_path",None) or "admin").strip().strip("/") or "admin"
    cache.set(key,v,60)
    return v
  except Exception:
    return "admin"

def get_client_ip(request):
  """دریافت IP واقعی کاربر"""
  x_forwarded_for = request.META.get('HTTP_X_FORWARDED_FOR')
  if x_forwarded_for:
    ip = x_forwarded_for.split(',')[0].strip()
  else:
    ip = request.META.get('REMOTE_ADDR', '127.0.0.1')
  return ip

class AdminAliasMiddleware(MiddlewareMixin):
  def process_request(self, request):
    admin_path=(_get_admin_path() or "admin").strip().strip("/") or "admin"
    ap=admin_path.lower()
    p=(request.path or "/"); pl=p.lower()
    # Block access to default /admin/ only if custom admin path is set
    if ap!="admin" and (pl.startswith("/admin/") or pl == "/admin"):
      return HttpResponseNotFound("Not Found")
    if pl==f"/{ap}" or pl==f"/{ap}/":
      request.path_info="/admin/"; return None
    pref=f"/{ap}/"
    if pl.startswith(pref):
      request.path_info="/admin/"+p[len(pref):]
    return None

class IPSecurityMiddleware(MiddlewareMixin):
  """Middleware برای بررسی محدودیت IP در پنل ادمین"""
  
  def process_request(self, request):
    # فقط برای صفحات ادمین چک کن
    admin_path = _get_admin_path()
    path = request.path.lower()
    
    # Check for exact admin paths
    if not (path.startswith('/admin/') or path == '/admin' or path.startswith(f'/{admin_path}/') or path == f'/{admin_path}'):
      return None
    
    try:
      from .models import IPSecuritySetting, IPWhitelist, IPBlacklist
      
      settings = IPSecuritySetting.get_settings()
      if not settings.is_enabled:
        return None
      
      ip = get_client_ip(request)
      
      # چک whitelist
      if IPWhitelist.objects.filter(ip_address=ip).exists():
        return None
      
      # چک blacklist
      now = timezone.now()
      blocked = IPBlacklist.objects.filter(ip_address=ip).first()
      
      if blocked:
        if blocked.is_permanent:
          return HttpResponseForbidden(self._blocked_response(ip, blocked, permanent=True))
        elif blocked.expires_at and blocked.expires_at > now:
          return HttpResponseForbidden(self._blocked_response(ip, blocked))
        else:
          # بلاک منقضی شده - حذف
          blocked.delete()
      
      return None
    except Exception:
      return None
  
  def _blocked_response(self, ip, blocked, permanent=False):
    from django.utils.html import format_html
    if permanent:
      msg = f"""
      <html dir="rtl">
      <head><meta charset="utf-8"><title>دسترسی مسدود</title></head>
      <body style="font-family: Tahoma; text-align: center; padding: 50px;">
        <h1 style="color: #dc2626;">🚫 دسترسی مسدود شد</h1>
        <p>آدرس IP شما (<code dir="ltr">{ip}</code>) به صورت دائمی مسدود شده است.</p>
        <p style="color: #666;">دلیل: {blocked.reason or 'نامشخص'}</p>
        <p>برای رفع مسدودیت با مدیر سایت تماس بگیرید.</p>
      </body>
      </html>
      """
    else:
      msg = f"""
      <html dir="rtl">
      <head><meta charset="utf-8"><title>دسترسی موقت مسدود</title></head>
      <body style="font-family: Tahoma; text-align: center; padding: 50px;">
        <h1 style="color: #dc2626;">⏳ دسترسی موقتاً مسدود شد</h1>
        <p>آدرس IP شما (<code dir="ltr">{ip}</code>) به دلیل تلاش‌های ناموفق ورود موقتاً مسدود شده است.</p>
        <p style="color: #666;">دلیل: {blocked.reason or 'تلاش‌های ناموفق متعدد'}</p>
        <p>تا زمان: <b>{blocked.expires_at.strftime('%Y-%m-%d %H:%M')}</b></p>
        <p>لطفاً بعداً تلاش کنید.</p>
      </body>
      </html>
      """
    return msg
PY

  cat > app/settingsapp/ip_security.py <<'PY'
"""توابع کمکی برای سیستم امنیت IP"""
from django.utils import timezone
from datetime import timedelta, datetime

def get_client_ip(request):
  """دریافت IP واقعی کاربر"""
  x_forwarded_for = request.META.get('HTTP_X_FORWARDED_FOR')
  if x_forwarded_for:
    ip = x_forwarded_for.split(',')[0].strip()
  else:
    ip = request.META.get('REMOTE_ADDR', '127.0.0.1')
  return ip

def record_login_attempt(request, username, is_successful):
  """ثبت تلاش ورود و بررسی نیاز به بلاک"""
  from .models import IPSecuritySetting, IPWhitelist, IPBlacklist, LoginAttempt, IPBlockType
  
  try:
    settings = IPSecuritySetting.get_settings()
    if not settings.is_enabled:
      return
    
    ip = get_client_ip(request)
    user_agent = request.META.get('HTTP_USER_AGENT', '')[:500]
    
    # ثبت تلاش
    LoginAttempt.objects.create(
      ip_address=ip,
      username=username or '',
      is_successful=is_successful,
      user_agent=user_agent,
    )
    
    # اگر موفق بود، نیازی به بررسی بلاک نیست
    if is_successful:
      return
    
    # چک whitelist
    if IPWhitelist.objects.filter(ip_address=ip).exists():
      return
    
    # شمارش تلاش‌های ناموفق اخیر
    reset_time = timezone.now() - timedelta(minutes=settings.reset_attempts_after)
    failed_count = LoginAttempt.objects.filter(
      ip_address=ip,
      is_successful=False,
      attempted_at__gte=reset_time
    ).count()
    
    # اگر از حد مجاز رد شده، بلاک کن
    if failed_count >= settings.max_attempts:
      block_ip_auto(ip, settings, failed_count)
  except Exception as e:
    print(f"Error in record_login_attempt: {e}")

def block_ip_auto(ip, settings, failed_count):
  """بلاک خودکار IP"""
  from .models import IPBlacklist, IPBlockType
  
  now = timezone.now()
  
  # محاسبه زمان انقضا
  if settings.block_duration_type == "forever":
    is_permanent = True
    expires_at = None
  elif settings.block_duration_type == "today":
    is_permanent = False
    # پایان امروز
    tomorrow = (now + timedelta(days=1)).replace(hour=0, minute=0, second=0, microsecond=0)
    expires_at = tomorrow
  elif settings.block_duration_type == "hours":
    is_permanent = False
    expires_at = now + timedelta(hours=settings.block_duration_value)
  else:  # minutes
    is_permanent = False
    expires_at = now + timedelta(minutes=settings.block_duration_value)
  
  # حذف بلاک‌های قبلی این IP
  IPBlacklist.objects.filter(ip_address=ip, block_type=IPBlockType.AUTO).delete()
  
  # ایجاد بلاک جدید
  IPBlacklist.objects.create(
    ip_address=ip,
    block_type=IPBlockType.AUTO,
    reason=f"بلاک خودکار - {failed_count} تلاش ناموفق ورود",
    is_permanent=is_permanent,
    expires_at=expires_at,
    failed_attempts=failed_count,
  )

def block_ip_manual(ip, reason="", is_permanent=False, duration_minutes=None, duration_hours=None, until_date=None):
  """بلاک دستی IP توسط ادمین"""
  from .models import IPBlacklist, IPBlockType
  
  now = timezone.now()
  
  if is_permanent:
    expires_at = None
  elif until_date:
    expires_at = until_date
  elif duration_hours:
    expires_at = now + timedelta(hours=duration_hours)
  elif duration_minutes:
    expires_at = now + timedelta(minutes=duration_minutes)
  else:
    expires_at = now + timedelta(hours=24)  # پیش‌فرض 24 ساعت
  
  # حذف بلاک‌های قبلی این IP
  IPBlacklist.objects.filter(ip_address=ip).delete()
  
  # ایجاد بلاک جدید
  return IPBlacklist.objects.create(
    ip_address=ip,
    block_type=IPBlockType.MANUAL,
    reason=reason or "بلاک دستی توسط مدیر",
    is_permanent=is_permanent,
    expires_at=expires_at,
  )

def unblock_ip(ip):
  """آنبلاک IP"""
  from .models import IPBlacklist
  return IPBlacklist.objects.filter(ip_address=ip).delete()

def is_ip_blocked(ip):
  """بررسی اینکه آیا IP بلاک شده است"""
  from .models import IPBlacklist, IPWhitelist
  
  # چک whitelist
  if IPWhitelist.objects.filter(ip_address=ip).exists():
    return False, None
  
  # چک blacklist
  now = timezone.now()
  blocked = IPBlacklist.objects.filter(ip_address=ip).first()
  
  if blocked:
    if blocked.is_permanent:
      return True, blocked
    elif blocked.expires_at and blocked.expires_at > now:
      return True, blocked
    else:
      # بلاک منقضی شده
      blocked.delete()
  
  return False, None

def cleanup_old_attempts(days=7):
  """پاکسازی لاگ‌های قدیمی تلاش ورود"""
  from .models import LoginAttempt
  cutoff = timezone.now() - timedelta(days=days)
  return LoginAttempt.objects.filter(attempted_at__lt=cutoff).delete()

def cleanup_expired_blocks():
  """پاکسازی بلاک‌های منقضی شده"""
  from .models import IPBlacklist
  now = timezone.now()
  return IPBlacklist.objects.filter(
    is_permanent=False,
    expires_at__lt=now
  ).delete()
PY

  cat > app/courses/apps.py <<'PY'
from django.apps import AppConfig
class CoursesConfig(AppConfig):
  default_auto_field="django.db.models.BigAutoField"
  name="courses"
  verbose_name="دوره‌ها"
PY
  cat > app/courses/models.py <<'PY'
import uuid
from django.db import models
from django.conf import settings
from django.utils.text import slugify
from django.utils.translation import gettext_lazy as _


class PublishStatus(models.TextChoices):
  DRAFT="draft",_("پیش‌نویس")
  PUBLISHED="published",_("منتشر شده")
  ARCHIVED="archived",_("آرشیو")


class CourseCategory(models.Model):
  title=models.CharField(max_length=200, verbose_name=_("عنوان"))
  slug=models.SlugField(max_length=220, unique=True, blank=True, verbose_name=_("اسلاگ"))
  is_active=models.BooleanField(default=True, verbose_name=_("فعال"))
  created_at=models.DateTimeField(auto_now_add=True, verbose_name=_("تاریخ ایجاد"))

  def save(self,*a,**k):
    if not self.slug:
      self.slug=slugify(self.title, allow_unicode=True)
    return super().save(*a,**k)

  def __str__(self): return self.title

  class Meta:
    verbose_name=_("دسته‌بندی دوره")
    verbose_name_plural=_("دسته‌بندی‌های دوره")
    ordering=["title"]


class Course(models.Model):
  id=models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
  owner=models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.PROTECT, verbose_name=_("مالک"))
  category=models.ForeignKey(CourseCategory, on_delete=models.SET_NULL, null=True, blank=True, related_name="courses", verbose_name=_("دسته‌بندی"))
  title=models.CharField(max_length=200, verbose_name=_("عنوان"))
  slug=models.SlugField(max_length=220, unique=True, blank=True)
  cover=models.ImageField(upload_to="courses/covers/", blank=True, null=True)
  summary=models.TextField(blank=True)
  description=models.TextField(blank=True)
  price_toman=models.PositiveIntegerField(default=0)
  is_free_for_all=models.BooleanField(default=False)
  status=models.CharField(max_length=20, choices=PublishStatus.choices, default=PublishStatus.DRAFT)
  updated_at=models.DateTimeField(auto_now=True)

  def save(self,*a,**k):
    if not self.slug: self.slug=slugify(self.title, allow_unicode=True)
    return super().save(*a,**k)

  def __str__(self): return self.title

  class Meta:
    verbose_name=_("دوره"); verbose_name_plural=_("دوره‌ها")


class Enrollment(models.Model):
  id=models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
  user=models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, verbose_name=_("کاربر"))
  course=models.ForeignKey(Course, on_delete=models.CASCADE, verbose_name=_("دوره"))
  is_active=models.BooleanField(default=True, verbose_name=_("فعال"))
  source=models.CharField(max_length=30, default="paid", verbose_name=_("منبع"))
  created_at=models.DateTimeField(auto_now_add=True, verbose_name=_("تاریخ ثبت"))

  class Meta:
    unique_together=[("user","course")]
    verbose_name=_("ثبت‌نام دوره")
    verbose_name_plural=_("ثبت‌نام‌های دوره")


class CourseGrant(models.Model):
  id=models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
  user=models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, verbose_name=_("کاربر"))
  course=models.ForeignKey(Course, on_delete=models.CASCADE, verbose_name=_("دوره"))
  is_active=models.BooleanField(default=True, verbose_name=_("فعال"))
  reason=models.CharField(max_length=200, blank=True, verbose_name=_("دلیل"))

  class Meta:
    unique_together=[("user","course")]
    verbose_name=_("دسترسی اهدایی")
    verbose_name_plural=_("دسترسی‌های اهدایی")


class CourseSection(models.Model):
  course=models.ForeignKey(Course, on_delete=models.CASCADE, related_name="sections", verbose_name=_("دوره"))
  title=models.CharField(max_length=200, verbose_name=_("عنوان سرفصل"))
  position=models.PositiveIntegerField(default=0, verbose_name=_("ترتیب"))
  created_at=models.DateTimeField(auto_now_add=True, verbose_name=_("تاریخ ایجاد"))

  def __str__(self): return f"{self.course} / {self.title}"

  class Meta:
    verbose_name=_("سرفصل")
    verbose_name_plural=_("سرفصل‌ها")
    ordering=["course_id","position","id"]


class Lesson(models.Model):
  course=models.ForeignKey(Course, on_delete=models.CASCADE, related_name="lessons", verbose_name=_("دوره"))
  section=models.ForeignKey(CourseSection, on_delete=models.SET_NULL, null=True, blank=True, related_name="lessons", verbose_name=_("سرفصل"))
  title=models.CharField(max_length=220, verbose_name=_("عنوان درس"))
  position=models.PositiveIntegerField(default=0, verbose_name=_("ترتیب"))
  is_free=models.BooleanField(default=False, verbose_name=_("رایگان"))
  content=models.TextField(blank=True, null=True, verbose_name=_("محتوا"))
  video=models.FileField(upload_to="lessons/videos/", blank=True, null=True, verbose_name=_("ویدیو"))
  created_at=models.DateTimeField(auto_now_add=True, verbose_name=_("تاریخ ایجاد"))

  def __str__(self): return f"{self.course} / {self.title}"

  class Meta:
    verbose_name=_("درس")
    verbose_name_plural=_("درس‌ها")
    ordering=["course_id","section_id","position","id"]
PY
  cat > app/courses/access.py <<'PY'
from .models import Enrollment, CourseGrant
def user_has_course_access(user, course):
  if course.is_free_for_all: return True
  if not user.is_authenticated: return False
  if Enrollment.objects.filter(user=user, course=course, is_active=True).exists(): return True
  if CourseGrant.objects.filter(user=user, course=course, is_active=True).exists(): return True
  return False
PY
  cat > app/courses/admin.py <<'PY'
from django.contrib import admin
from .models import (
    Course, Enrollment, CourseGrant,
    CourseCategory, CourseSection, Lesson
)
from settingsapp.date_utils import smart_format_datetime


@admin.register(CourseCategory)
class CourseCategoryAdmin(admin.ModelAdmin):
    list_display = ("title", "slug", "is_active", "created_at_display")
    list_filter = ("is_active",)
    search_fields = ("title", "slug")
    prepopulated_fields = {"slug": ("title",)}

    def created_at_display(self, obj):
        return smart_format_datetime(obj.created_at)
    created_at_display.short_description = "تاریخ ایجاد"
    created_at_display.admin_order_field = "created_at"


class CourseSectionInline(admin.TabularInline):
    model = CourseSection
    extra = 0
    fields = ("title", "position")
    ordering = ("position", "id")


class LessonInline(admin.TabularInline):
    model = Lesson
    extra = 0
    fields = ("title", "section", "position", "is_free")
    ordering = ("section_id", "position", "id")


@admin.register(Course)
class CourseAdmin(admin.ModelAdmin):
    list_display = ("title", "owner", "category", "price_toman", "status", "is_free_for_all", "updated_at_display")
    list_filter = ("status", "is_free_for_all", "category")
    search_fields = ("title", "slug", "owner__username")
    prepopulated_fields = {"slug": ("title",)}
    raw_id_fields = ("owner",)
    inlines = [CourseSectionInline, LessonInline]

    def updated_at_display(self, obj):
        return smart_format_datetime(obj.updated_at)
    updated_at_display.short_description = "آخرین به‌روزرسانی"
    updated_at_display.admin_order_field = "updated_at"


@admin.register(CourseSection)
class CourseSectionAdmin(admin.ModelAdmin):
    list_display = ("title", "course", "position", "created_at_display")
    list_filter = ("course",)
    search_fields = ("title", "course__title")
    ordering = ("course_id", "position", "id")

    def created_at_display(self, obj):
        return smart_format_datetime(obj.created_at)
    created_at_display.short_description = "تاریخ ایجاد"
    created_at_display.admin_order_field = "created_at"


@admin.register(Lesson)
class LessonAdmin(admin.ModelAdmin):
    list_display = ("title", "course", "section", "position", "is_free", "created_at_display")
    list_filter = ("course", "section", "is_free")
    search_fields = ("title", "course__title", "section__title")
    ordering = ("course_id", "section_id", "position", "id")

    def created_at_display(self, obj):
        return smart_format_datetime(obj.created_at)
    created_at_display.short_description = "تاریخ ایجاد"
    created_at_display.admin_order_field = "created_at"


@admin.register(Enrollment)
class EnrollmentAdmin(admin.ModelAdmin):
    list_display = ("user", "course", "is_active", "source", "created_at_display")
    list_filter = ("is_active", "source", "created_at")
    search_fields = ("user__username", "user__email", "course__title")
    raw_id_fields = ("user", "course")

    def created_at_display(self, obj):
        return smart_format_datetime(obj.created_at)
    created_at_display.short_description = "تاریخ ثبت‌نام"
    created_at_display.admin_order_field = "created_at"


@admin.register(CourseGrant)
class CourseGrantAdmin(admin.ModelAdmin):
    list_display = ("user", "course", "is_active", "reason")
    list_filter = ("is_active",)
    search_fields = ("user__username", "user__email", "course__title", "reason")
    raw_id_fields = ("user", "course")
PY
  cat > app/courses/urls.py <<'PY'
from django.urls import path
from . import views

app_name = 'courses'
urlpatterns = [
    path('', views.CourseListView.as_view(), name='list'),
    path('<slug:slug>/', views.CourseDetailView.as_view(), name='detail'),
]
PY
  cat > app/courses/views.py <<'PY'
from django.views.generic import ListView, DetailView
from .models import Course, PublishStatus
from .access import user_has_course_access

class CourseListView(ListView):
  template_name="courses/list.html"
  paginate_by=12
  def get_queryset(self):
    return Course.objects.filter(status=PublishStatus.PUBLISHED).order_by("-updated_at")

class CourseDetailView(DetailView):
  template_name="courses/detail.html"
  model=Course
  slug_field="slug"
  slug_url_kwarg="slug"
  def get_queryset(self):
    return Course.objects.filter(status=PublishStatus.PUBLISHED)
  def get_context_data(self,**k):
    ctx=super().get_context_data(**k)
    ctx["has_access"]=user_has_course_access(self.request.user, self.object)
    return ctx
PY

  cat > app/dashboard/apps.py <<'PY'
from django.apps import AppConfig
class DashboardConfig(AppConfig):
  default_auto_field="django.db.models.BigAutoField"
  name="dashboard"
  verbose_name="داشبورد"
PY
  cat > app/dashboard/views.py <<'PY'
from django.contrib.auth.decorators import login_required
from django.shortcuts import render
from courses.models import Enrollment
from payments.models import Order, Wallet
from tickets.models import Ticket

@login_required
def dashboard_home(request):
  enrollments = Enrollment.objects.filter(user=request.user, is_active=True).select_related("course").order_by("-created_at")[:12]
  orders = Order.objects.filter(user=request.user).select_related("course").order_by("-created_at")[:10]
  tickets = Ticket.objects.filter(user=request.user).order_by("-created_at")[:10]
  wallet,_ = Wallet.objects.get_or_create(user=request.user)
  return render(request,"dashboard/home.html",{"enrollments":enrollments,"orders":orders,"tickets":tickets,"wallet":wallet})
PY
  cat > app/dashboard/urls.py <<'PY'
from django.urls import path
from .views import dashboard_home
urlpatterns=[path("", dashboard_home, name="dashboard_home")]
PY

  cat > app/payments/apps.py <<'PY'
from django.apps import AppConfig
class PaymentsConfig(AppConfig):
  default_auto_field="django.db.models.BigAutoField"
  name="payments"
  verbose_name="پرداخت‌ها"
PY
  cat > app/payments/models.py <<'PY'
import uuid
from django.db import models, transaction
from django.conf import settings
from django.utils import timezone
from django.db.models import F
from django.utils.translation import gettext_lazy as _
from courses.models import Course

class BankTransferSetting(models.Model):
  account_holder=models.CharField(max_length=120, blank=True, verbose_name=_("نام صاحب حساب"))
  card_number=models.CharField(max_length=30, blank=True, verbose_name=_("شماره کارت"))
  sheba=models.CharField(max_length=30, blank=True, verbose_name=_("شماره شبا"))
  note=models.TextField(blank=True, verbose_name=_("توضیحات"))
  first_purchase_percent=models.PositiveIntegerField(default=0, verbose_name=_("درصد تخفیف خرید اول"))
  first_purchase_amount=models.PositiveIntegerField(default=0, verbose_name=_("مبلغ تخفیف خرید اول"))
  updated_at=models.DateTimeField(auto_now=True)
  class Meta:
    verbose_name=_("تنظیمات کارت‌به‌کارت"); verbose_name_plural=_("تنظیمات کارت‌به‌کارت")

class CouponType(models.TextChoices):
  PERCENT="percent",_("درصدی")
  AMOUNT="amount",_("مبلغی")

class Coupon(models.Model):
  code=models.CharField(max_length=40, unique=True)
  type=models.CharField(max_length=10, choices=CouponType.choices, default=CouponType.PERCENT)
  value=models.PositiveIntegerField()
  is_active=models.BooleanField(default=True)
  start_at=models.DateTimeField(blank=True, null=True)
  end_at=models.DateTimeField(blank=True, null=True)
  max_uses=models.PositiveIntegerField(default=0)
  max_uses_per_user=models.PositiveIntegerField(default=0)
  min_amount=models.PositiveIntegerField(default=0)
  def is_valid_now(self):
    now=timezone.now()
    if not self.is_active: return False
    if self.start_at and now<self.start_at: return False
    if self.end_at and now>self.end_at: return False
    return True
  class Meta:
    verbose_name=_("کد تخفیف"); verbose_name_plural=_("کدهای تخفیف")

class OrderStatus(models.TextChoices):
  PENDING_PAYMENT="pending_payment",_("در انتظار پرداخت")
  PENDING_VERIFY="pending_verify",_("در انتظار تایید")
  PAID="paid",_("پرداخت شده")
  REJECTED="rejected",_("رد شده")
  CANCELED="canceled",_("لغو شده")

class Order(models.Model):
  id=models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
  user=models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE)
  course=models.ForeignKey(Course, on_delete=models.PROTECT)
  amount=models.PositiveIntegerField()
  discount_amount=models.PositiveIntegerField(default=0)
  final_amount=models.PositiveIntegerField(default=0)
  coupon=models.ForeignKey(Coupon, on_delete=models.SET_NULL, null=True, blank=True)
  status=models.CharField(max_length=30, choices=OrderStatus.choices, default=OrderStatus.PENDING_PAYMENT)
  receipt_image=models.ImageField(upload_to="receipts/", blank=True, null=True)
  tracking_code=models.CharField(max_length=80, blank=True)
  note=models.TextField(blank=True)
  created_at=models.DateTimeField(auto_now_add=True)
  verified_at=models.DateTimeField(blank=True, null=True)
  class Meta:
    ordering=["-created_at"]; verbose_name=_("سفارش"); verbose_name_plural=_("سفارش‌ها")

class Wallet(models.Model):
  user=models.OneToOneField(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="wallet")
  balance=models.IntegerField(default=0)
  updated_at=models.DateTimeField(auto_now=True)
  class Meta:
    verbose_name=_("کیف پول"); verbose_name_plural=_("کیف پول‌ها")

class WalletTxnKind(models.TextChoices):
  TOPUP="topup",_("شارژ")
  ORDER_PAY="order_pay",_("پرداخت سفارش")
  REFUND="refund",_("بازگشت وجه")
  ADJUST="adjust",_("اصلاح")

class WalletTransaction(models.Model):
  id=models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
  wallet=models.ForeignKey(Wallet, on_delete=models.CASCADE, related_name="txns")
  kind=models.CharField(max_length=20, choices=WalletTxnKind.choices)
  amount=models.IntegerField()
  ref_order=models.ForeignKey(Order, on_delete=models.SET_NULL, null=True, blank=True, related_name="wallet_txns")
  description=models.CharField(max_length=250, blank=True)
  created_at=models.DateTimeField(auto_now_add=True)
  class Meta:
    ordering=["-created_at"]; verbose_name=_("تراکنش کیف پول"); verbose_name_plural=_("تراکنش‌های کیف پول")

class TopUpStatus(models.TextChoices):
  PENDING="pending",_("در انتظار بررسی")
  APPROVED="approved",_("تایید شده")
  REJECTED="rejected",_("رد شده")

class WalletTopUpRequest(models.Model):
  id=models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
  user=models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="topups", verbose_name=_("کاربر"))
  amount=models.PositiveIntegerField(verbose_name=_("مبلغ (تومان)"))
  receipt_image=models.ImageField(upload_to="wallet/topups/", blank=True, null=True, verbose_name=_("تصویر رسید"))
  tracking_code=models.CharField(max_length=80, blank=True, verbose_name=_("کد پیگیری"))
  note=models.TextField(blank=True, verbose_name=_("توضیحات"))
  status=models.CharField(max_length=20, choices=TopUpStatus.choices, default=TopUpStatus.PENDING, verbose_name=_("وضعیت"))
  created_at=models.DateTimeField(auto_now_add=True, verbose_name=_("تاریخ ثبت"))
  reviewed_at=models.DateTimeField(blank=True, null=True, verbose_name=_("تاریخ بررسی"))
  class Meta:
    ordering=["-created_at"]; verbose_name=_("درخواست شارژ"); verbose_name_plural=_("درخواست‌های شارژ")

class Invoice(models.Model):
  id=models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
  order=models.OneToOneField(Order, on_delete=models.CASCADE, related_name="invoice")
  number=models.CharField(max_length=30, unique=True, blank=True)
  issued_at=models.DateTimeField(default=timezone.now)
  billed_to=models.CharField(max_length=200, blank=True)
  billed_email=models.EmailField(blank=True)
  item_title=models.CharField(max_length=250)
  unit_price=models.PositiveIntegerField()
  discount=models.PositiveIntegerField(default=0)
  total=models.PositiveIntegerField(default=0)
  class Meta:
    ordering=["-issued_at"]; verbose_name=_("فاکتور"); verbose_name_plural=_("فاکتورها")
  def _gen(self):
    y=timezone.now().strftime("%Y")
    return f"INV-{y}-{uuid.uuid4().hex[:8].upper()}"
  def save(self,*a,**k):
    if not self.number: self.number=self._gen()
    if not self.total: self.total=max(int(self.unit_price)-int(self.discount or 0),0)
    super().save(*a,**k)

def wallet_apply(user, amount:int, kind:str, ref_order=None, description=""):
  with transaction.atomic():
    w,_ = Wallet.objects.select_for_update().get_or_create(user=user)
    w.balance = F("balance")+int(amount)
    w.save(update_fields=["balance"])
    w.refresh_from_db(fields=["balance"])
    WalletTransaction.objects.create(wallet=w, kind=kind, amount=int(amount), ref_order=ref_order, description=description)
    return w

class GatewayType(models.TextChoices):
  ZARINPAL="zarinpal",_("زرین‌پال")
  ZIBAL="zibal",_("زیبال")
  IDPAY="idpay",_("آقای پرداخت (IDPay)")

class PaymentGateway(models.Model):
  gateway_type=models.CharField(max_length=20, choices=GatewayType.choices, unique=True, verbose_name=_("نوع درگاه"))
  merchant_id=models.CharField(max_length=100, verbose_name=_("مرچنت کد"))
  is_active=models.BooleanField(default=False, verbose_name=_("فعال"))
  is_sandbox=models.BooleanField(default=False, verbose_name=_("حالت تست (Sandbox)"))
  priority=models.PositiveIntegerField(default=0, verbose_name=_("اولویت نمایش"), help_text=_("عدد کمتر = اولویت بالاتر"))
  description=models.CharField(max_length=200, blank=True, verbose_name=_("توضیحات"))
  created_at=models.DateTimeField(auto_now_add=True)
  updated_at=models.DateTimeField(auto_now=True)
  class Meta:
    ordering=["priority","gateway_type"]
    verbose_name=_("درگاه پرداخت"); verbose_name_plural=_("درگاه‌های پرداخت")
  def __str__(self): return self.get_gateway_type_display()

class OnlinePaymentStatus(models.TextChoices):
  PENDING="pending",_("در انتظار پرداخت")
  SUCCESS="success",_("موفق")
  FAILED="failed",_("ناموفق")
  CANCELED="canceled",_("لغو شده")

class OnlinePaymentType(models.TextChoices):
  ORDER="order",_("خرید دوره")
  WALLET="wallet",_("شارژ کیف پول")

class OnlinePayment(models.Model):
  id=models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
  user=models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="online_payments", verbose_name=_("کاربر"))
  gateway=models.ForeignKey(PaymentGateway, on_delete=models.PROTECT, verbose_name=_("درگاه"))
  payment_type=models.CharField(max_length=10, choices=OnlinePaymentType.choices, verbose_name=_("نوع پرداخت"))
  amount=models.PositiveIntegerField(verbose_name=_("مبلغ (تومان)"))
  order=models.ForeignKey(Order, on_delete=models.SET_NULL, null=True, blank=True, related_name="online_payments", verbose_name=_("سفارش"))
  authority=models.CharField(max_length=100, blank=True, verbose_name=_("کد پیگیری درگاه"))
  ref_id=models.CharField(max_length=100, blank=True, verbose_name=_("شماره مرجع"))
  status=models.CharField(max_length=20, choices=OnlinePaymentStatus.choices, default=OnlinePaymentStatus.PENDING, verbose_name=_("وضعیت"))
  gateway_response=models.JSONField(default=dict, blank=True, verbose_name=_("پاسخ درگاه"))
  created_at=models.DateTimeField(auto_now_add=True, verbose_name=_("تاریخ ایجاد"))
  paid_at=models.DateTimeField(blank=True, null=True, verbose_name=_("تاریخ پرداخت"))
  class Meta:
    ordering=["-created_at"]
    verbose_name=_("پرداخت آنلاین"); verbose_name_plural=_("پرداخت‌های آنلاین")
  def __str__(self): return f"{self.get_payment_type_display()} - {self.amount} تومان"
PY

  cat > app/payments/utils.py <<'PY'
from .models import CouponType, Coupon, Order, OrderStatus
def calc_coupon_discount(coupon, base):
  if not coupon: return 0
  if coupon.type==CouponType.PERCENT:
    pct=min(max(int(coupon.value),0),100)
    return (base*pct)//100
  return min(int(coupon.value), base)

def coupon_total_uses(coupon):
  return Order.objects.filter(coupon=coupon).exclude(status=OrderStatus.CANCELED).count()

def coupon_user_uses(coupon,user):
  return Order.objects.filter(user=user, coupon=coupon).exclude(status=OrderStatus.CANCELED).count()

def validate_coupon(code,user,base):
  code=(code or "").strip()
  if not code: return None,"کدی وارد نشده."
  try:
    c=Coupon.objects.get(code__iexact=code)
  except Coupon.DoesNotExist:
    return None,"کد نامعتبر است."
  if not c.is_valid_now(): return None,"کد فعال نیست یا تاریخ آن گذشته است."
  if base < c.min_amount: return None,"این کد برای این مبلغ قابل استفاده نیست."
  if c.max_uses and coupon_total_uses(c) >= c.max_uses: return None,"سقف استفاده پر شده."
  if c.max_uses_per_user and coupon_user_uses(c,user) >= c.max_uses_per_user: return None,"سقف استفاده شما پر شده."
  return c,""

import requests
import json

def get_active_gateways():
  """دریافت لیست درگاه‌های فعال"""
  from .models import PaymentGateway
  return list(PaymentGateway.objects.filter(is_active=True).order_by("priority"))

# ========== ZARINPAL ==========
def zarinpal_request(gateway, amount, callback_url, description, email="", mobile=""):
  """ایجاد درخواست پرداخت زرین‌پال"""
  if gateway.is_sandbox:
    url = "https://sandbox.zarinpal.com/pg/v4/payment/request.json"
  else:
    url = "https://payment.zarinpal.com/pg/v4/payment/request.json"
  
  data = {
    "merchant_id": gateway.merchant_id,
    "amount": int(amount) * 10,  # تبدیل تومان به ریال
    "callback_url": callback_url,
    "description": description,
  }
  if email: data["metadata"] = {"email": email}
  if mobile: data["metadata"] = data.get("metadata", {}); data["metadata"]["mobile"] = mobile
  
  try:
    resp = requests.post(url, json=data, timeout=30)
    result = resp.json()
    if result.get("data") and result["data"].get("authority"):
      return True, result["data"]["authority"], result
    return False, result.get("errors", {}).get("message", "خطا در ارتباط با زرین‌پال"), result
  except Exception as e:
    return False, str(e), {}

def zarinpal_redirect_url(gateway, authority):
  """ساخت URL ریدایرکت به درگاه زرین‌پال"""
  if gateway.is_sandbox:
    return f"https://sandbox.zarinpal.com/pg/StartPay/{authority}"
  return f"https://payment.zarinpal.com/pg/StartPay/{authority}"

def zarinpal_verify(gateway, authority, amount):
  """تایید پرداخت زرین‌پال"""
  if gateway.is_sandbox:
    url = "https://sandbox.zarinpal.com/pg/v4/payment/verify.json"
  else:
    url = "https://payment.zarinpal.com/pg/v4/payment/verify.json"
  
  data = {
    "merchant_id": gateway.merchant_id,
    "amount": int(amount) * 10,  # تبدیل تومان به ریال
    "authority": authority,
  }
  
  try:
    resp = requests.post(url, json=data, timeout=30)
    result = resp.json()
    if result.get("data") and result["data"].get("code") == 100:
      return True, str(result["data"].get("ref_id", "")), result
    elif result.get("data") and result["data"].get("code") == 101:
      return True, str(result["data"].get("ref_id", "")), result  # قبلا تایید شده
    return False, result.get("errors", {}).get("message", "خطا در تایید"), result
  except Exception as e:
    return False, str(e), {}

# ========== ZIBAL ==========
def zibal_request(gateway, amount, callback_url, description, mobile=""):
  """ایجاد درخواست پرداخت زیبال"""
  url = "https://gateway.zibal.ir/v1/request"
  
  data = {
    "merchant": gateway.merchant_id if not gateway.is_sandbox else "zibal",
    "amount": int(amount) * 10,  # تبدیل تومان به ریال
    "callbackUrl": callback_url,
    "description": description,
  }
  if mobile: data["mobile"] = mobile
  
  try:
    resp = requests.post(url, json=data, timeout=30)
    result = resp.json()
    if result.get("result") == 100 and result.get("trackId"):
      return True, str(result["trackId"]), result
    return False, result.get("message", "خطا در ارتباط با زیبال"), result
  except Exception as e:
    return False, str(e), {}

def zibal_redirect_url(gateway, track_id):
  """ساخت URL ریدایرکت به درگاه زیبال"""
  return f"https://gateway.zibal.ir/start/{track_id}"

def zibal_verify(gateway, track_id):
  """تایید پرداخت زیبال"""
  url = "https://gateway.zibal.ir/v1/verify"
  
  data = {
    "merchant": gateway.merchant_id if not gateway.is_sandbox else "zibal",
    "trackId": track_id,
  }
  
  try:
    resp = requests.post(url, json=data, timeout=30)
    result = resp.json()
    if result.get("result") == 100:
      return True, str(result.get("refNumber", "")), result
    return False, result.get("message", "خطا در تایید"), result
  except Exception as e:
    return False, str(e), {}

# ========== IDPAY (آقای پرداخت) ==========
def idpay_request(gateway, amount, callback_url, description, order_id, name="", email="", phone=""):
  """ایجاد درخواست پرداخت آقای پرداخت"""
  if gateway.is_sandbox:
    url = "https://api.idpay.ir/v1.1/payment"
    headers = {"X-API-KEY": gateway.merchant_id, "X-SANDBOX": "1", "Content-Type": "application/json"}
  else:
    url = "https://api.idpay.ir/v1.1/payment"
    headers = {"X-API-KEY": gateway.merchant_id, "Content-Type": "application/json"}
  
  data = {
    "order_id": str(order_id),
    "amount": int(amount) * 10,  # تبدیل تومان به ریال
    "callback": callback_url,
    "desc": description,
  }
  if name: data["name"] = name
  if email: data["mail"] = email
  if phone: data["phone"] = phone
  
  try:
    resp = requests.post(url, json=data, headers=headers, timeout=30)
    result = resp.json()
    if result.get("id") and result.get("link"):
      return True, result["id"], result
    return False, result.get("error_message", "خطا در ارتباط با آقای پرداخت"), result
  except Exception as e:
    return False, str(e), {}

def idpay_redirect_url(gateway, payment_id, link):
  """URL ریدایرکت آقای پرداخت (مستقیم از پاسخ API)"""
  return link

def idpay_verify(gateway, payment_id, order_id):
  """تایید پرداخت آقای پرداخت"""
  if gateway.is_sandbox:
    url = "https://api.idpay.ir/v1.1/payment/verify"
    headers = {"X-API-KEY": gateway.merchant_id, "X-SANDBOX": "1", "Content-Type": "application/json"}
  else:
    url = "https://api.idpay.ir/v1.1/payment/verify"
    headers = {"X-API-KEY": gateway.merchant_id, "Content-Type": "application/json"}
  
  data = {
    "id": payment_id,
    "order_id": str(order_id),
  }
  
  try:
    resp = requests.post(url, json=data, headers=headers, timeout=30)
    result = resp.json()
    if result.get("status") == 100:
      return True, str(result.get("track_id", "")), result
    elif result.get("status") == 101:
      return True, str(result.get("track_id", "")), result  # قبلا تایید شده
    return False, result.get("error_message", "خطا در تایید"), result
  except Exception as e:
    return False, str(e), {}
PY

  cat > app/payments/forms.py <<'PY'
from django import forms
from django.utils.translation import gettext_lazy as _
from .models import Order, WalletTopUpRequest
_INPUT="w-full rounded-xl border border-slate-200 bg-white px-3 py-2 outline-none focus:ring-2 focus:ring-slate-300 dark:bg-slate-900 dark:border-slate-700 dark:focus:ring-slate-700"

class ReceiptUploadForm(forms.ModelForm):
  class Meta:
    model=Order
    fields=("receipt_image","tracking_code","note")
    widgets={"tracking_code": forms.TextInput(attrs={"class":_INPUT,"dir":"ltr"}),
             "note": forms.Textarea(attrs={"class":_INPUT,"rows":3})}

class CouponApplyForm(forms.Form):
  coupon_code=forms.CharField(required=False, max_length=40, widget=forms.TextInput(attrs={"class":_INPUT,"dir":"ltr"}))

class WalletTopUpForm(forms.ModelForm):
  class Meta:
    model=WalletTopUpRequest
    fields=("amount","note","receipt_image","tracking_code")
    labels={
      "amount": _("مبلغ شارژ (تومان)"),
      "note": _("توضیحات (اختیاری)"),
      "receipt_image": _("تصویر رسید (اختیاری)"),
      "tracking_code": _("کد پیگیری (اختیاری)"),
    }
    help_texts={
      "amount": _("مبلغ مورد نظر برای شارژ کیف پول را به تومان وارد کنید."),
      "note": _("در صورت نیاز توضیحات خود را بنویسید."),
      "receipt_image": _("اگر کارت به کارت کرده‌اید، تصویر رسید را آپلود کنید."),
      "tracking_code": _("کد پیگیری یا شماره مرجع تراکنش بانکی"),
    }
    widgets={
      "amount": forms.NumberInput(attrs={"class":_INPUT,"dir":"ltr","placeholder":"مثال: 50000"}),
      "tracking_code": forms.TextInput(attrs={"class":_INPUT,"dir":"ltr","placeholder":"کد پیگیری بانکی"}),
      "note": forms.Textarea(attrs={"class":_INPUT,"rows":3,"placeholder":"توضیحات اضافی..."})
    }
PY

  cat > app/payments/views.py <<'PY'
from django.contrib.auth.decorators import login_required
from django.shortcuts import get_object_or_404, redirect, render
from django.contrib import messages
from django.utils import timezone
from django.db import transaction
from django.http import HttpResponse
from django.views.decorators.csrf import csrf_exempt
from courses.models import Course, PublishStatus, Enrollment
from courses.access import user_has_course_access
from .models import (BankTransferSetting, Order, OrderStatus, Wallet, WalletTopUpRequest, 
                     TopUpStatus, wallet_apply, Invoice, PaymentGateway, GatewayType, 
                     OnlinePayment, OnlinePaymentStatus, OnlinePaymentType)
from .forms import ReceiptUploadForm, CouponApplyForm, WalletTopUpForm
from .utils import (validate_coupon, calc_coupon_discount, get_active_gateways,
                    zarinpal_request, zarinpal_redirect_url, zarinpal_verify,
                    zibal_request, zibal_redirect_url, zibal_verify,
                    idpay_request, idpay_redirect_url, idpay_verify)

def ensure_invoice(order:Order):
  if hasattr(order,"invoice"): return order.invoice
  return Invoice.objects.create(
    order=order,
    billed_to=(order.user.get_full_name() or order.user.username),
    billed_email=(order.user.email or ""),
    item_title=f"خرید دوره: {order.course.title}",
    unit_price=order.amount, discount=order.discount_amount, total=order.final_amount,
  )

@login_required
def checkout(request, slug):
  course=get_object_or_404(Course, slug=slug, status=PublishStatus.PUBLISHED)
  if course.is_free_for_all:
    Enrollment.objects.get_or_create(user=request.user, course=course, defaults={"is_active":True,"source":"free_all"})
    return redirect("course_detail", slug=course.slug)
  if user_has_course_access(request.user, course):
    return redirect("course_detail", slug=course.slug)

  setting=BankTransferSetting.objects.first()
  order=Order.objects.filter(user=request.user, course=course).exclude(status__in=[OrderStatus.PAID,OrderStatus.CANCELED]).first()
  if not order:
    order=Order.objects.create(user=request.user, course=course, amount=course.price_toman, discount_amount=0, final_amount=course.price_toman, status=OrderStatus.PENDING_PAYMENT)

  base=order.amount
  first_paid = Order.objects.filter(user=request.user, status=OrderStatus.PAID).count()==0
  coupon_form=CouponApplyForm(request.POST or None)
  applied=None
  if request.method=="POST" and "apply_coupon" in request.POST:
    code=(request.POST.get("coupon_code","") or "").strip()
    if code:
      applied,msg = validate_coupon(code, request.user, base)
      messages.success(request,"کد اعمال شد.") if applied else messages.error(request,msg)

  discount=0; label=""
  if applied:
    discount=calc_coupon_discount(applied, base); label=f"کد: {applied.code}"
  elif first_paid and setting:
    pct=min(max(int(setting.first_purchase_percent or 0),0),100)
    discount=max((base*pct)//100, min(int(setting.first_purchase_amount or 0), base))
    if discount>0: label="تخفیف خرید اول"

  discount=min(discount, base)
  final=max(base-discount,0)
  order.coupon=applied; order.discount_amount=discount; order.final_amount=final
  order.save(update_fields=["coupon","discount_amount","final_amount"])

  wallet,_ = Wallet.objects.get_or_create(user=request.user)
  
  # دریافت درگاه‌های فعال
  active_gateways = get_active_gateways()

  if request.method=="POST" and "pay_wallet" in request.POST:
    if wallet.balance < final:
      messages.error(request,"موجودی کیف پول کافی نیست.")
    else:
      with transaction.atomic():
        o=Order.objects.select_for_update().get(id=order.id)
        if o.status in [OrderStatus.PAID,OrderStatus.CANCELED]:
          return redirect("orders_my")
        wallet_apply(request.user, -int(final), kind="order_pay", ref_order=o, description=f"پرداخت سفارش {o.id}")
        o.status=OrderStatus.PAID; o.verified_at=timezone.now()
        o.save(update_fields=["status","verified_at"])
        Enrollment.objects.get_or_create(user=request.user, course=course, defaults={"is_active":True,"source":"wallet"})
        ensure_invoice(o)
        messages.success(request,"پرداخت با کیف پول انجام شد.")
        return redirect("invoice_detail", order_id=o.id)

  return render(request,"orders/checkout.html",{
    "course":course,"setting":setting,"order":order,"coupon_form":coupon_form,
    "discount_label":label,"first_purchase_eligible":first_paid,"wallet":wallet,
    "active_gateways":active_gateways,
  })

@login_required
def upload_receipt(request, order_id):
  order=get_object_or_404(Order, id=order_id, user=request.user)
  if order.status in [OrderStatus.PAID,OrderStatus.CANCELED]:
    return redirect("orders_my")
  form=ReceiptUploadForm(request.POST or None, request.FILES or None, instance=order)
  if request.method=="POST" and form.is_valid():
    form.save()
    order.status=OrderStatus.PENDING_VERIFY
    order.save(update_fields=["status"])
    messages.success(request,"رسید ثبت شد و پس از بررسی فعال می‌شود.")
    return redirect("orders_my")
  return render(request,"orders/receipt.html",{"order":order,"form":form})

@login_required
def my_orders(request):
  orders=Order.objects.filter(user=request.user).select_related("course")
  return render(request,"orders/my.html",{"orders":orders})

@login_required
def cancel_order(request, order_id):
  o=get_object_or_404(Order, id=order_id, user=request.user)
  if o.status=="paid":
    messages.error(request,"سفارش پرداخت‌شده قابل لغو نیست.")
    return redirect("orders_my")
  if request.method=="POST":
    o.status=OrderStatus.CANCELED; o.save(update_fields=["status"])
    messages.success(request,"سفارش لغو شد.")
  return redirect("orders_my")

@login_required
def wallet_home(request):
  wallet,_=Wallet.objects.get_or_create(user=request.user)
  txns=wallet.txns.all()[:50]
  topups=WalletTopUpRequest.objects.filter(user=request.user).order_by("-created_at")[:20]
  return render(request,"wallet/home.html",{"wallet":wallet,"txns":txns,"topups":topups})

@login_required
def wallet_topup(request):
  form=WalletTopUpForm(request.POST or None, request.FILES or None)
  if request.method=="POST" and form.is_valid():
    t=form.save(commit=False); t.user=request.user; t.status=TopUpStatus.PENDING; t.save()
    messages.success(request,"درخواست شارژ با موفقیت ثبت شد. پس از بررسی، مبلغ به کیف پول شما اضافه می‌شود.")
    return redirect("wallet_home")
  bank_info = BankTransferSetting.objects.first()
  active_gateways = get_active_gateways()
  return render(request,"wallet/topup.html",{"form":form, "bank_info":bank_info, "active_gateways":active_gateways})

@login_required
def invoice_list(request):
  invs=Invoice.objects.filter(order__user=request.user).select_related("order","order__course").order_by("-issued_at")
  return render(request,"invoices/list.html",{"invoices":invs})

@login_required
def invoice_detail(request, order_id):
  inv=get_object_or_404(Invoice, order__id=order_id, order__user=request.user)
  return render(request,"invoices/detail.html",{"invoice":inv})

# ==================== ONLINE PAYMENT VIEWS ====================

@login_required
def pay_online_order(request, order_id, gateway_type):
  """شروع پرداخت آنلاین برای سفارش"""
  order = get_object_or_404(Order, id=order_id, user=request.user)
  if order.status in [OrderStatus.PAID, OrderStatus.CANCELED]:
    messages.error(request, "این سفارش قابل پرداخت نیست.")
    return redirect("orders_my")
  
  try:
    gateway = PaymentGateway.objects.get(gateway_type=gateway_type, is_active=True)
  except PaymentGateway.DoesNotExist:
    messages.error(request, "درگاه پرداخت یافت نشد یا غیرفعال است.")
    return redirect("checkout", slug=order.course.slug)
  
  amount = order.final_amount
  callback_url = request.build_absolute_uri(f"/orders/callback/{gateway_type}/")
  description = f"خرید دوره: {order.course.title}"
  
  # ایجاد رکورد پرداخت آنلاین
  online_payment = OnlinePayment.objects.create(
    user=request.user,
    gateway=gateway,
    payment_type=OnlinePaymentType.ORDER,
    amount=amount,
    order=order,
  )
  
  success = False
  authority = ""
  redirect_url = ""
  
  if gateway_type == GatewayType.ZARINPAL:
    success, authority, resp = zarinpal_request(gateway, amount, callback_url, description, request.user.email)
    if success:
      redirect_url = zarinpal_redirect_url(gateway, authority)
  elif gateway_type == GatewayType.ZIBAL:
    success, authority, resp = zibal_request(gateway, amount, callback_url, description)
    if success:
      redirect_url = zibal_redirect_url(gateway, authority)
  elif gateway_type == GatewayType.IDPAY:
    success, authority, resp = idpay_request(gateway, amount, callback_url, description, str(online_payment.id), 
                                              request.user.get_full_name(), request.user.email)
    if success:
      redirect_url = resp.get("link", "")
  
  if success:
    online_payment.authority = authority
    online_payment.gateway_response = resp
    online_payment.save()
    return redirect(redirect_url)
  else:
    online_payment.status = OnlinePaymentStatus.FAILED
    online_payment.gateway_response = {"error": authority}
    online_payment.save()
    messages.error(request, f"خطا در اتصال به درگاه: {authority}")
    return redirect("checkout", slug=order.course.slug)

@login_required
def pay_online_wallet(request, gateway_type):
  """شروع پرداخت آنلاین برای شارژ کیف پول"""
  amount = request.GET.get("amount") or request.POST.get("amount")
  if not amount:
    messages.error(request, "مبلغ مشخص نشده است.")
    return redirect("wallet_topup")
  
  try:
    amount = int(amount)
    if amount < 1000:
      messages.error(request, "حداقل مبلغ شارژ ۱۰۰۰ تومان است.")
      return redirect("wallet_topup")
  except:
    messages.error(request, "مبلغ نامعتبر است.")
    return redirect("wallet_topup")
  
  try:
    gateway = PaymentGateway.objects.get(gateway_type=gateway_type, is_active=True)
  except PaymentGateway.DoesNotExist:
    messages.error(request, "درگاه پرداخت یافت نشد یا غیرفعال است.")
    return redirect("wallet_topup")
  
  callback_url = request.build_absolute_uri(f"/wallet/callback/{gateway_type}/")
  description = f"شارژ کیف پول - {request.user.email}"
  
  # ایجاد رکورد پرداخت آنلاین
  online_payment = OnlinePayment.objects.create(
    user=request.user,
    gateway=gateway,
    payment_type=OnlinePaymentType.WALLET,
    amount=amount,
  )
  
  success = False
  authority = ""
  redirect_url = ""
  
  if gateway_type == GatewayType.ZARINPAL:
    success, authority, resp = zarinpal_request(gateway, amount, callback_url, description, request.user.email)
    if success:
      redirect_url = zarinpal_redirect_url(gateway, authority)
  elif gateway_type == GatewayType.ZIBAL:
    success, authority, resp = zibal_request(gateway, amount, callback_url, description)
    if success:
      redirect_url = zibal_redirect_url(gateway, authority)
  elif gateway_type == GatewayType.IDPAY:
    success, authority, resp = idpay_request(gateway, amount, callback_url, description, str(online_payment.id),
                                              request.user.get_full_name(), request.user.email)
    if success:
      redirect_url = resp.get("link", "")
  
  if success:
    online_payment.authority = authority
    online_payment.gateway_response = resp
    online_payment.save()
    return redirect(redirect_url)
  else:
    online_payment.status = OnlinePaymentStatus.FAILED
    online_payment.gateway_response = {"error": authority}
    online_payment.save()
    messages.error(request, f"خطا در اتصال به درگاه: {authority}")
    return redirect("wallet_topup")

@csrf_exempt
def payment_callback_order(request, gateway_type):
  """کال‌بک پرداخت سفارش"""
  if gateway_type == GatewayType.ZARINPAL:
    authority = request.GET.get("Authority", "")
    status = request.GET.get("Status", "")
    
    if status != "OK":
      messages.error(request, "پرداخت لغو شد یا ناموفق بود.")
      return redirect("orders_my")
    
    try:
      payment = OnlinePayment.objects.get(authority=authority, payment_type=OnlinePaymentType.ORDER)
    except OnlinePayment.DoesNotExist:
      messages.error(request, "تراکنش یافت نشد.")
      return redirect("orders_my")
    
    gateway = payment.gateway
    success, ref_id, resp = zarinpal_verify(gateway, authority, payment.amount)
    
  elif gateway_type == GatewayType.ZIBAL:
    track_id = request.GET.get("trackId", "")
    success_param = request.GET.get("success", "0")
    
    if success_param != "1":
      messages.error(request, "پرداخت لغو شد یا ناموفق بود.")
      return redirect("orders_my")
    
    try:
      payment = OnlinePayment.objects.get(authority=track_id, payment_type=OnlinePaymentType.ORDER)
    except OnlinePayment.DoesNotExist:
      messages.error(request, "تراکنش یافت نشد.")
      return redirect("orders_my")
    
    gateway = payment.gateway
    success, ref_id, resp = zibal_verify(gateway, track_id)
    
  elif gateway_type == GatewayType.IDPAY:
    payment_id = request.POST.get("id") or request.GET.get("id", "")
    order_id = request.POST.get("order_id") or request.GET.get("order_id", "")
    status = request.POST.get("status") or request.GET.get("status", "")
    
    if str(status) not in ["100", "101", "200"]:
      messages.error(request, "پرداخت لغو شد یا ناموفق بود.")
      return redirect("orders_my")
    
    try:
      payment = OnlinePayment.objects.get(id=order_id, payment_type=OnlinePaymentType.ORDER)
    except OnlinePayment.DoesNotExist:
      messages.error(request, "تراکنش یافت نشد.")
      return redirect("orders_my")
    
    gateway = payment.gateway
    success, ref_id, resp = idpay_verify(gateway, payment_id, order_id)
  else:
    messages.error(request, "درگاه نامعتبر.")
    return redirect("orders_my")
  
  payment.gateway_response = resp
  
  if success:
    payment.status = OnlinePaymentStatus.SUCCESS
    payment.ref_id = ref_id
    payment.paid_at = timezone.now()
    payment.save()
    
    # تکمیل سفارش
    order = payment.order
    if order and order.status != OrderStatus.PAID:
      with transaction.atomic():
        order.status = OrderStatus.PAID
        order.verified_at = timezone.now()
        order.tracking_code = ref_id
        order.save()
        Enrollment.objects.get_or_create(user=order.user, course=order.course, defaults={"is_active":True,"source":"online"})
        ensure_invoice(order)
      messages.success(request, f"پرداخت موفق! کد پیگیری: {ref_id}")
      return redirect("invoice_detail", order_id=order.id)
    else:
      messages.info(request, "این سفارش قبلا پرداخت شده بود.")
      return redirect("orders_my")
  else:
    payment.status = OnlinePaymentStatus.FAILED
    payment.save()
    messages.error(request, f"پرداخت ناموفق: {ref_id}")
    return redirect("orders_my")

@csrf_exempt
def payment_callback_wallet(request, gateway_type):
  """کال‌بک پرداخت شارژ کیف پول"""
  if gateway_type == GatewayType.ZARINPAL:
    authority = request.GET.get("Authority", "")
    status = request.GET.get("Status", "")
    
    if status != "OK":
      messages.error(request, "پرداخت لغو شد یا ناموفق بود.")
      return redirect("wallet_home")
    
    try:
      payment = OnlinePayment.objects.get(authority=authority, payment_type=OnlinePaymentType.WALLET)
    except OnlinePayment.DoesNotExist:
      messages.error(request, "تراکنش یافت نشد.")
      return redirect("wallet_home")
    
    gateway = payment.gateway
    success, ref_id, resp = zarinpal_verify(gateway, authority, payment.amount)
    
  elif gateway_type == GatewayType.ZIBAL:
    track_id = request.GET.get("trackId", "")
    success_param = request.GET.get("success", "0")
    
    if success_param != "1":
      messages.error(request, "پرداخت لغو شد یا ناموفق بود.")
      return redirect("wallet_home")
    
    try:
      payment = OnlinePayment.objects.get(authority=track_id, payment_type=OnlinePaymentType.WALLET)
    except OnlinePayment.DoesNotExist:
      messages.error(request, "تراکنش یافت نشد.")
      return redirect("wallet_home")
    
    gateway = payment.gateway
    success, ref_id, resp = zibal_verify(gateway, track_id)
    
  elif gateway_type == GatewayType.IDPAY:
    payment_id = request.POST.get("id") or request.GET.get("id", "")
    order_id = request.POST.get("order_id") or request.GET.get("order_id", "")
    status = request.POST.get("status") or request.GET.get("status", "")
    
    if str(status) not in ["100", "101", "200"]:
      messages.error(request, "پرداخت لغو شد یا ناموفق بود.")
      return redirect("wallet_home")
    
    try:
      payment = OnlinePayment.objects.get(id=order_id, payment_type=OnlinePaymentType.WALLET)
    except OnlinePayment.DoesNotExist:
      messages.error(request, "تراکنش یافت نشد.")
      return redirect("wallet_home")
    
    gateway = payment.gateway
    success, ref_id, resp = idpay_verify(gateway, payment_id, order_id)
  else:
    messages.error(request, "درگاه نامعتبر.")
    return redirect("wallet_home")
  
  payment.gateway_response = resp
  
  if success:
    payment.status = OnlinePaymentStatus.SUCCESS
    payment.ref_id = ref_id
    payment.paid_at = timezone.now()
    payment.save()
    
    # شارژ کیف پول
    wallet_apply(payment.user, payment.amount, kind="topup", description=f"شارژ آنلاین - کد: {ref_id}")
    messages.success(request, f"کیف پول شارژ شد! کد پیگیری: {ref_id}")
    return redirect("wallet_home")
  else:
    payment.status = OnlinePaymentStatus.FAILED
    payment.save()
    messages.error(request, f"پرداخت ناموفق: {ref_id}")
    return redirect("wallet_home")

@login_required
def invoice_pdf(request, order_id):
  """تولید PDF فاکتور"""
  from reportlab.lib.pagesizes import A4
  from reportlab.lib.units import cm
  from reportlab.lib.colors import HexColor
  from reportlab.pdfgen import canvas
  from reportlab.pdfbase import pdfmetrics
  from reportlab.pdfbase.ttfonts import TTFont
  import arabic_reshaper
  from bidi.algorithm import get_display
  import jdatetime
  import io
  import os

  inv = get_object_or_404(Invoice, order__id=order_id, order__user=request.user)
  
  # تنظیمات PDF
  buffer = io.BytesIO()
  p = canvas.Canvas(buffer, pagesize=A4)
  width, height = A4
  
  # رنگ‌ها
  primary = HexColor("#0f172a")
  secondary = HexColor("#64748b")
  accent = HexColor("#059669")
  light_bg = HexColor("#f8fafc")
  border = HexColor("#e2e8f0")
  
  # تابع برای متن فارسی
  def persian_text(text):
    try:
      reshaped = arabic_reshaper.reshape(str(text))
      return get_display(reshaped)
    except:
      return str(text)
  
  # تابع اعداد فارسی
  def persian_num(num):
    persian_digits = '۰۱۲۳۴۵۶۷۸۹'
    return ''.join(persian_digits[int(d)] if d.isdigit() else d for d in str(num))
  
  # تاریخ شمسی یا میلادی بر اساس تنظیمات
  from settingsapp.date_utils import get_calendar_type, convert_to_tehran, PERSIAN_MONTHS, GREGORIAN_MONTHS
  try:
    cal_type = get_calendar_type()
    tehran_dt = convert_to_tehran(inv.issued_at)
    if cal_type == 'gregorian':
      date_str = f"{tehran_dt.year}/{tehran_dt.month:02d}/{tehran_dt.day:02d}"
    else:
      jdate = jdatetime.datetime.fromgregorian(datetime=tehran_dt)
      date_str = persian_num(f"{jdate.year}/{jdate.month:02d}/{jdate.day:02d}")
  except:
    date_str = str(inv.issued_at.date())
  
  # هدر با گرادیان
  p.setFillColor(primary)
  p.rect(0, height - 3.5*cm, width, 3.5*cm, fill=1, stroke=0)
  
  # لوگو/عنوان
  p.setFillColor(HexColor("#ffffff"))
  p.setFont("Helvetica-Bold", 24)
  p.drawRightString(width - 1.5*cm, height - 1.8*cm, persian_text("فاکتور"))
  p.setFont("Helvetica", 11)
  p.drawRightString(width - 1.5*cm, height - 2.5*cm, persian_text("EduCMS"))
  
  # شماره فاکتور
  p.setFont("Helvetica-Bold", 12)
  p.drawString(1.5*cm, height - 1.8*cm, f"#{str(inv.order.id)[:8].upper()}")
  p.setFont("Helvetica", 10)
  p.drawString(1.5*cm, height - 2.5*cm, date_str)
  
  # اطلاعات خریدار
  y = height - 5*cm
  p.setFillColor(light_bg)
  p.roundRect(1.5*cm, y - 2.2*cm, width - 3*cm, 2.5*cm, 10, fill=1, stroke=0)
  
  p.setFillColor(primary)
  p.setFont("Helvetica-Bold", 11)
  p.drawRightString(width - 2*cm, y - 0.5*cm, persian_text("صورتحساب برای:"))
  
  p.setFont("Helvetica", 10)
  p.setFillColor(secondary)
  p.drawRightString(width - 2*cm, y - 1.1*cm, persian_text(inv.billed_to))
  p.drawRightString(width - 2*cm, y - 1.7*cm, inv.billed_email)
  
  # جدول آیتم‌ها
  y = height - 8.5*cm
  
  # هدر جدول
  p.setFillColor(primary)
  p.roundRect(1.5*cm, y - 0.8*cm, width - 3*cm, 1*cm, 5, fill=1, stroke=0)
  
  p.setFillColor(HexColor("#ffffff"))
  p.setFont("Helvetica-Bold", 10)
  p.drawRightString(width - 2*cm, y - 0.5*cm, persian_text("شرح"))
  p.drawString(5*cm, y - 0.5*cm, persian_text("مبلغ (تومان)"))
  
  # ردیف آیتم
  y -= 1.5*cm
  p.setFillColor(primary)
  p.setFont("Helvetica", 10)
  p.drawRightString(width - 2*cm, y, persian_text(inv.item_title))
  p.drawString(5*cm, y, persian_num(f"{inv.unit_price:,}"))
  
  # خط جدا کننده
  y -= 0.7*cm
  p.setStrokeColor(border)
  p.setLineWidth(1)
  p.line(1.5*cm, y, width - 1.5*cm, y)
  
  # جمع‌بندی
  y -= 1*cm
  p.setFont("Helvetica", 10)
  p.setFillColor(secondary)
  p.drawRightString(width - 6*cm, y, persian_text("جمع کل:"))
  p.drawString(2*cm, y, persian_num(f"{inv.unit_price:,}"))
  
  if inv.discount > 0:
    y -= 0.6*cm
    p.setFillColor(accent)
    p.drawRightString(width - 6*cm, y, persian_text("تخفیف:"))
    p.drawString(2*cm, y, persian_num(f"-{inv.discount:,}"))
  
  # مبلغ نهایی
  y -= 1*cm
  p.setFillColor(accent)
  p.roundRect(1.5*cm, y - 0.5*cm, width - 3*cm, 1.2*cm, 8, fill=1, stroke=0)
  
  p.setFillColor(HexColor("#ffffff"))
  p.setFont("Helvetica-Bold", 12)
  p.drawRightString(width - 2*cm, y, persian_text("مبلغ قابل پرداخت:"))
  p.setFont("Helvetica-Bold", 14)
  p.drawString(2*cm, y, persian_num(f"{inv.total:,}") + " " + persian_text("تومان"))
  
  # وضعیت پرداخت
  y -= 2*cm
  status_text = persian_text("پرداخت شده ✓") if inv.order.status == "paid" else persian_text("در انتظار پرداخت")
  status_color = accent if inv.order.status == "paid" else HexColor("#f59e0b")
  
  p.setFillColor(status_color)
  p.setFont("Helvetica-Bold", 11)
  p.drawCentredString(width/2, y, status_text)
  
  # فوتر
  p.setFillColor(secondary)
  p.setFont("Helvetica", 8)
  p.drawCentredString(width/2, 1.5*cm, persian_text("این فاکتور به صورت الکترونیکی صادر شده و معتبر است."))
  p.drawCentredString(width/2, 1*cm, f"Invoice ID: {inv.order.id}")
  
  p.showPage()
  p.save()
  
  buffer.seek(0)
  response = HttpResponse(buffer, content_type='application/pdf')
  response['Content-Disposition'] = f'attachment; filename="invoice-{str(inv.order.id)[:8]}.pdf"'
  return response
PY

  cat > app/payments/admin.py <<'PY'
from django.contrib import admin, messages
from django.utils import timezone
from django.utils.html import format_html
from django.db import transaction
from courses.models import Enrollment
from .models import (BankTransferSetting, Order, OrderStatus, Coupon, Wallet, WalletTransaction, 
                     WalletTopUpRequest, TopUpStatus, wallet_apply, Invoice, PaymentGateway, 
                     GatewayType, OnlinePayment, OnlinePaymentStatus)
from settingsapp.date_utils import smart_format_datetime

def ensure_invoice(order):
  if hasattr(order,"invoice"): return order.invoice
  return Invoice.objects.create(
    order=order,
    billed_to=(order.user.get_full_name() or order.user.username),
    billed_email=(order.user.email or ""),
    item_title=f"خرید دوره: {order.course.title}",
    unit_price=order.amount, discount=order.discount_amount, total=order.final_amount,
  )

@admin.action(description="تایید سفارش + فعال‌سازی دسترسی + صدور فاکتور")
def mark_paid(modeladmin, request, qs):
  now=timezone.now()
  with transaction.atomic():
    for o in qs.select_for_update():
      o.status=OrderStatus.PAID; o.verified_at=now
      o.save(update_fields=["status","verified_at"])
      Enrollment.objects.get_or_create(user=o.user, course=o.course, defaults={"is_active":True,"source":"paid"})
      ensure_invoice(o)

@admin.register(Order)
class OrderAdmin(admin.ModelAdmin):
  list_display=("id","user","course","final_amount","status","created_at_display")
  list_filter=("status","created_at")
  search_fields=("user__username","course__title","tracking_code","coupon__code")
  actions=[mark_paid]

  def created_at_display(self, obj):
      return smart_format_datetime(obj.created_at)
  created_at_display.short_description = "تاریخ ثبت"
  created_at_display.admin_order_field = "created_at"

@admin.action(description="تایید شارژ و اعمال به کیف پول")
def approve_topup(modeladmin, request, qs):
  now=timezone.now()
  with transaction.atomic():
    for t in qs.select_for_update():
      if t.status!=TopUpStatus.PENDING: continue
      t.status=TopUpStatus.APPROVED; t.reviewed_at=now
      t.save(update_fields=["status","reviewed_at"])
      wallet_apply(t.user, int(t.amount), kind="topup", description="شارژ تایید شده توسط ادمین")

@admin.action(description="رد شارژ")
def reject_topup(modeladmin, request, qs):
  now=timezone.now()
  for t in qs:
    if t.status==TopUpStatus.PENDING:
      t.status=TopUpStatus.REJECTED; t.reviewed_at=now
      t.save(update_fields=["status","reviewed_at"])

@admin.register(WalletTopUpRequest)
class WalletTopUpRequestAdmin(admin.ModelAdmin):
  list_display=("id","user","amount","status","created_at_display")
  list_filter=("status","created_at")
  search_fields=("user__username","tracking_code")
  actions=[approve_topup, reject_topup]

  def created_at_display(self, obj):
      return smart_format_datetime(obj.created_at)
  created_at_display.short_description = "تاریخ ثبت"
  created_at_display.admin_order_field = "created_at"

# ==================== PAYMENT GATEWAY ADMIN ====================

@admin.register(PaymentGateway)
class PaymentGatewayAdmin(admin.ModelAdmin):
  list_display = ("gateway_type_display", "merchant_preview", "is_active_display", "is_sandbox_display", "priority", "updated_at_display")
  list_filter = ("is_active", "is_sandbox", "gateway_type")
  list_editable = ("priority",)
  search_fields = ("merchant_id", "description")
  ordering = ("priority", "gateway_type")
  
  fieldsets = (
    ("نوع درگاه", {
      "fields": ("gateway_type",),
      "description": "نوع درگاه پرداخت را انتخاب کنید. هر درگاه فقط یکبار قابل اضافه شدن است."
    }),
    ("تنظیمات اتصال", {
      "fields": ("merchant_id", "is_sandbox"),
      "description": "مرچنت کد (یا API Key) درگاه را وارد کنید. حالت تست برای آزمایش بدون پرداخت واقعی است."
    }),
    ("وضعیت", {
      "fields": ("is_active", "priority", "description"),
      "description": "درگاه‌های فعال به کاربران نمایش داده می‌شوند. اولویت کمتر = نمایش بالاتر"
    }),
  )
  
  def gateway_type_display(self, obj):
    icons = {
      "zarinpal": "💛",
      "zibal": "💙", 
      "idpay": "💚",
    }
    icon = icons.get(obj.gateway_type, "💳")
    return f"{icon} {obj.get_gateway_type_display()}"
  gateway_type_display.short_description = "درگاه"
  gateway_type_display.admin_order_field = "gateway_type"
  
  def merchant_preview(self, obj):
    if obj.merchant_id:
      preview = obj.merchant_id[:8] + "..." if len(obj.merchant_id) > 12 else obj.merchant_id
      return format_html('<code dir="ltr">{}</code>', preview)
    return "-"
  merchant_preview.short_description = "مرچنت کد"
  
  def is_active_display(self, obj):
    if obj.is_active:
      return format_html('<span style="color:green;">✅ فعال</span>')
    return format_html('<span style="color:gray;">⬜ غیرفعال</span>')
  is_active_display.short_description = "وضعیت"
  is_active_display.admin_order_field = "is_active"
  
  def is_sandbox_display(self, obj):
    if obj.is_sandbox:
      return format_html('<span style="color:orange;">🔶 تست</span>')
    return format_html('<span style="color:blue;">🔷 واقعی</span>')
  is_sandbox_display.short_description = "محیط"
  is_sandbox_display.admin_order_field = "is_sandbox"
  
  def updated_at_display(self, obj):
    return smart_format_datetime(obj.updated_at)
  updated_at_display.short_description = "آخرین تغییر"
  updated_at_display.admin_order_field = "updated_at"

@admin.register(OnlinePayment)
class OnlinePaymentAdmin(admin.ModelAdmin):
  list_display = ("id_short", "user", "gateway", "payment_type", "amount", "status_display", "ref_id", "created_at_display")
  list_filter = ("status", "payment_type", "gateway__gateway_type", "created_at")
  search_fields = ("user__username", "user__email", "authority", "ref_id")
  readonly_fields = ("id", "user", "gateway", "payment_type", "amount", "order", "authority", "ref_id", "gateway_response", "created_at", "paid_at")
  ordering = ("-created_at",)
  
  def id_short(self, obj):
    return str(obj.id)[:8] + "..."
  id_short.short_description = "شناسه"
  
  def status_display(self, obj):
    colors = {
      "pending": "orange",
      "success": "green",
      "failed": "red",
      "canceled": "gray",
    }
    icons = {
      "pending": "⏳",
      "success": "✅",
      "failed": "❌",
      "canceled": "🚫",
    }
    color = colors.get(obj.status, "gray")
    icon = icons.get(obj.status, "")
    return format_html('<span style="color:{};">{} {}</span>', color, icon, obj.get_status_display())
  status_display.short_description = "وضعیت"
  status_display.admin_order_field = "status"
  
  def created_at_display(self, obj):
    return smart_format_datetime(obj.created_at)
  created_at_display.short_description = "تاریخ ایجاد"
  created_at_display.admin_order_field = "created_at"

admin.site.register(BankTransferSetting)
admin.site.register(Coupon)
admin.site.register(Wallet)
admin.site.register(WalletTransaction)
admin.site.register(Invoice)
PY

  cat > app/payments/urls.py <<'PY'
from django.urls import path
from .views import checkout, upload_receipt, my_orders, cancel_order, pay_online_order, payment_callback_order
urlpatterns=[
  path("checkout/<slug:slug>/", checkout, name="checkout"),
  path("receipt/<uuid:order_id>/", upload_receipt, name="upload_receipt"),
  path("my/", my_orders, name="orders_my"),
  path("cancel/<uuid:order_id>/", cancel_order, name="order_cancel"),
  path("pay/<uuid:order_id>/<str:gateway_type>/", pay_online_order, name="pay_online_order"),
  path("callback/<str:gateway_type>/", payment_callback_order, name="payment_callback_order"),
]
PY
  cat > app/payments/wallet_urls.py <<'PY'
from django.urls import path
from .views import wallet_home, wallet_topup, pay_online_wallet, payment_callback_wallet
urlpatterns=[
  path("", wallet_home, name="wallet_home"), 
  path("topup/", wallet_topup, name="wallet_topup"),
  path("pay/<str:gateway_type>/", pay_online_wallet, name="pay_online_wallet"),
  path("callback/<str:gateway_type>/", payment_callback_wallet, name="payment_callback_wallet"),
]
PY
  cat > app/payments/invoice_urls.py <<'PY'
from django.urls import path
from .views import invoice_list, invoice_detail, invoice_pdf
urlpatterns=[
  path("", invoice_list, name="invoice_list"), 
  path("<uuid:order_id>/", invoice_detail, name="invoice_detail"),
  path("<uuid:order_id>/pdf/", invoice_pdf, name="invoice_pdf"),
]
PY

  cat > app/tickets/apps.py <<'PY'
from django.apps import AppConfig
class TicketsConfig(AppConfig):
  default_auto_field="django.db.models.BigAutoField"
  name="tickets"
  verbose_name="تیکت‌ها"
PY
  cat > app/tickets/models.py <<'PY'
import uuid
from django.db import models
from django.conf import settings
from django.utils.translation import gettext_lazy as _

class Department(models.Model):
  id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
  name = models.CharField(max_length=100, verbose_name=_("نام دپارتمان"))
  description = models.TextField(blank=True, verbose_name=_("توضیحات"))
  is_active = models.BooleanField(default=True, verbose_name=_("فعال"))
  order = models.PositiveIntegerField(default=0, verbose_name=_("ترتیب"))
  created_at = models.DateTimeField(auto_now_add=True)
  
  class Meta:
    ordering = ["order", "name"]
    verbose_name = _("دپارتمان")
    verbose_name_plural = _("دپارتمان‌ها")
  
  def __str__(self):
    return self.name

class TicketStatus(models.TextChoices):
  OPEN="open",_("باز")
  ANSWERED="answered",_("پاسخ داده شده")
  CLOSED="closed",_("بسته")

class TicketPriority(models.TextChoices):
  LOW="low",_("کم")
  MEDIUM="medium",_("متوسط")
  HIGH="high",_("زیاد")

class Ticket(models.Model):
  id=models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
  user=models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="tickets")
  department=models.ForeignKey(Department, on_delete=models.PROTECT, related_name="tickets", verbose_name=_("دپارتمان"))
  subject=models.CharField(max_length=200, verbose_name=_("موضوع"))
  description=models.TextField(verbose_name=_("توضیحات"))
  attachment=models.FileField(upload_to="tickets/", blank=True, null=True, verbose_name=_("پیوست"))
  status=models.CharField(max_length=20, choices=TicketStatus.choices, default=TicketStatus.OPEN, verbose_name=_("وضعیت"))
  priority=models.CharField(max_length=20, choices=TicketPriority.choices, default=TicketPriority.MEDIUM, verbose_name=_("اولویت"))
  created_at=models.DateTimeField(auto_now_add=True)
  updated_at=models.DateTimeField(auto_now=True)
  class Meta:
    ordering=["-created_at"]; verbose_name=_("تیکت"); verbose_name_plural=_("تیکت‌ها")

class TicketReply(models.Model):
  id=models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
  ticket=models.ForeignKey(Ticket, on_delete=models.CASCADE, related_name="replies")
  user=models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE)
  message=models.TextField()
  attachment=models.FileField(upload_to="tickets/replies/", blank=True, null=True)
  created_at=models.DateTimeField(auto_now_add=True)
  class Meta:
    ordering=["created_at"]; verbose_name=_("پاسخ تیکت"); verbose_name_plural=_("پاسخ‌های تیکت")
PY
  cat > app/tickets/forms.py <<'PY'
from django import forms
from .models import Ticket, TicketReply, Department, TicketPriority

_INPUT = "w-full rounded-xl border border-slate-200 bg-white px-3 py-2 focus:outline-none focus:ring-2 focus:ring-slate-200 dark:bg-slate-900 dark:border-slate-700 dark:focus:ring-slate-700"
_SELECT = "w-full rounded-xl border border-slate-200 bg-white px-3 py-2.5 focus:outline-none focus:ring-2 focus:ring-slate-200 dark:bg-slate-900 dark:border-slate-700 dark:focus:ring-slate-700"

class TicketCreateForm(forms.ModelForm):
  department = forms.ModelChoiceField(
    queryset=Department.objects.filter(is_active=True),
    required=True,
    empty_label="-- انتخاب دپارتمان --",
    label="دپارتمان",
    widget=forms.Select(attrs={"class": _SELECT}),
    error_messages={"required": "لطفاً دپارتمان را انتخاب کنید"}
  )
  priority = forms.ChoiceField(
    choices=TicketPriority.choices,
    initial=TicketPriority.MEDIUM,
    label="اولویت",
    widget=forms.Select(attrs={"class": _SELECT})
  )
  
  class Meta:
    model = Ticket
    fields = ("department", "subject", "priority", "description", "attachment")
    labels = {
      "subject": "موضوع",
      "description": "متن پیام",
      "attachment": "پیوست",
    }
    widgets = {
      "subject": forms.TextInput(attrs={"class": _INPUT, "placeholder": "موضوع تیکت را وارد کنید"}),
      "description": forms.Textarea(attrs={"class": _INPUT, "rows": 5, "placeholder": "شرح مشکل یا درخواست خود را بنویسید"}),
    }

class TicketReplyForm(forms.ModelForm):
  class Meta:
    model = TicketReply
    fields = ("message", "attachment")
    labels = {
      "message": "پاسخ",
      "attachment": "پیوست",
    }
    widgets = {
      "message": forms.Textarea(attrs={"class": _INPUT, "rows": 4, "placeholder": "پاسخ خود را بنویسید"}),
    }

PY
  cat > app/tickets/views.py <<'PY'
from django.contrib.auth.decorators import login_required
from django.shortcuts import render, redirect, get_object_or_404
from django.contrib import messages
from .models import Ticket, TicketStatus
from .forms import TicketCreateForm, TicketReplyForm

@login_required
def ticket_list(request):
  tickets=Ticket.objects.filter(user=request.user).select_related("department")
  return render(request,"tickets/list.html",{"tickets":tickets})

@login_required
def ticket_create(request):
  form=TicketCreateForm(request.POST or None, request.FILES or None, user=request.user)
  if request.method=="POST" and form.is_valid():
    t=form.save(commit=False); t.user=request.user; t.status=TicketStatus.OPEN; t.save()
    messages.success(request,"تیکت ثبت شد.")
    return redirect("ticket_detail", ticket_id=t.id)
  return render(request,"tickets/create.html",{"form":form})

@login_required
def ticket_detail(request, ticket_id):
  ticket=get_object_or_404(Ticket, id=ticket_id, user=request.user)
  form=TicketReplyForm(request.POST or None, request.FILES or None)
  if request.method=="POST" and form.is_valid():
    r=form.save(commit=False); r.ticket=ticket; r.user=request.user; r.save()
    ticket.status=TicketStatus.OPEN; ticket.save(update_fields=["status"])
    messages.success(request,"پاسخ ثبت شد.")
    return redirect("ticket_detail", ticket_id=ticket.id)
  return render(request,"tickets/detail.html",{"ticket":ticket,"form":form})
PY
  cat > app/tickets/admin.py <<'PY'
from django.contrib import admin
from .models import Department, Ticket, TicketReply
from settingsapp.date_utils import smart_format_datetime

@admin.register(Department)
class DepartmentAdmin(admin.ModelAdmin):
  list_display = ("name", "is_active", "order", "ticket_count", "created_at_display")
  list_filter = ("is_active",)
  search_fields = ("name", "description")
  list_editable = ("is_active", "order")
  ordering = ("order", "name")
  
  def ticket_count(self, obj):
    return obj.tickets.count()
  ticket_count.short_description = "تعداد تیکت"

  def created_at_display(self, obj):
    return smart_format_datetime(obj.created_at)
  created_at_display.short_description = "تاریخ ایجاد"
  created_at_display.admin_order_field = "created_at"

class TicketReplyInline(admin.TabularInline):
  model = TicketReply
  extra = 0
  readonly_fields = ("created_at",)

@admin.register(Ticket)
class TicketAdmin(admin.ModelAdmin):
  list_display = ("id", "user", "department", "subject", "priority", "status", "created_at_display")
  list_filter = ("status", "priority", "department", "created_at")
  search_fields = ("user__username", "user__email", "subject", "description")
  list_editable = ("status", "priority")
  inlines = [TicketReplyInline]
  readonly_fields = ("created_at", "updated_at")
  
  fieldsets = (
    ("اطلاعات تیکت", {"fields": ("user", "department", "subject", "description", "attachment")}),
    ("وضعیت", {"fields": ("status", "priority")}),
    ("تاریخ‌ها", {"fields": ("created_at", "updated_at")}),
  )

  def created_at_display(self, obj):
    return smart_format_datetime(obj.created_at)
  created_at_display.short_description = "تاریخ ایجاد"
  created_at_display.admin_order_field = "created_at"

@admin.register(TicketReply)
class TicketReplyAdmin(admin.ModelAdmin):
  list_display = ("ticket", "user", "created_at_display")
  list_filter = ("created_at",)
  search_fields = ("ticket__subject", "user__username", "message")

  def created_at_display(self, obj):
    return smart_format_datetime(obj.created_at)
  created_at_display.short_description = "تاریخ ایجاد"
  created_at_display.admin_order_field = "created_at"
PY
  cat > app/tickets/urls.py <<'PY'
from django.urls import path
from .views import ticket_list, ticket_create, ticket_detail
urlpatterns=[path("",ticket_list,name="ticket_list"), path("new/",ticket_create,name="ticket_create"), path("<uuid:ticket_id>/",ticket_detail,name="ticket_detail")]
PY

  cat > app/templates/partials/form_errors.html <<'HTML'
{% if form.non_field_errors %}
  <div class="mb-3 rounded-xl border border-rose-200 bg-rose-50 p-3 text-sm text-rose-700 dark:border-rose-900/40 dark:bg-rose-950/40 dark:text-rose-200">
    {{ form.non_field_errors }}
  </div>
{% endif %}
HTML
  cat > app/templates/partials/field.html <<'HTML'
<div class="space-y-1">
  <label class="text-sm font-medium">{{ field.label }}</label>
  {{ field }}
  {% if field.help_text %}<div class="text-xs text-slate-500 dark:text-slate-300">{{ field.help_text }}</div>{% endif %}
  {% if field.errors %}<div class="text-xs text-rose-600 dark:text-rose-300">{{ field.errors }}</div>{% endif %}
</div>
HTML

  cat > app/templates/base.html <<'HTML'
{% load static jalali_tags %}
<!doctype html>
<html lang="fa" dir="rtl">
<head>
  <meta charset="utf-8"/>
  <meta name="viewport" content="width=device-width,initial-scale=1"/>
  <script src="https://cdn.tailwindcss.com"></script>
  {% if site_settings.favicon %}<link rel="icon" href="{{ site_settings.favicon.url }}">{% endif %}
  <title>{% block title %}{{ site_settings.brand_name|default:"EduCMS" }}{% endblock %}</title>
</head>
<body class="min-h-screen bg-gradient-to-b from-slate-50 to-white text-slate-900">
<header class="sticky top-0 z-30 border-b border-slate-200/70 bg-white/85 backdrop-blur">
  <div class="mx-auto max-w-6xl px-4 py-4 flex items-center justify-between gap-3">
    <a href="/" class="flex items-center gap-3">
      {% if site_settings.logo %}
        <img src="{{ site_settings.logo.url }}" class="h-9 w-auto" alt="{{ site_settings.brand_name }}">
      {% else %}
        <div class="h-9 w-9 rounded-2xl bg-slate-900"></div>
      {% endif %}
      <span class="font-extrabold text-xl tracking-tight">{{ site_settings.brand_name|default:"EduCMS" }}</span>
    </a>

    {% if user.is_authenticated %}
      {% if request.path|slice:":11" == "/dashboard/" or request.path|slice:":8" == "/wallet/" or request.path|slice:":10" == "/invoices/" or request.path|slice:":8" == "/orders/" or request.path|slice:":9" == "/tickets/" or request.path|slice:":18" == "/accounts/profile/" or request.path|slice:":19" == "/accounts/security/" %}
        <div class="relative">
          <button id="dashMenuBtn" type="button"
                  class="inline-flex items-center justify-center rounded-xl border border-slate-200 bg-white px-3 py-2 hover:bg-slate-50"
                  aria-expanded="false" aria-controls="dashMenu">
            <span class="sr-only">منو</span>
            <svg xmlns="http://www.w3.org/2000/svg" class="h-5 w-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
              <path stroke-linecap="round" stroke-linejoin="round" d="M4 6h16M4 12h16M4 18h16" />
            </svg>
          </button>

          <div id="dashMenu"
               class="absolute left-0 mt-2 w-72 overflow-hidden rounded-2xl border border-slate-200 bg-white shadow-lg
                      max-h-0 opacity-0 -translate-y-2 pointer-events-none transition-all duration-300 ease-out">
            <div class="p-2 text-sm">
              <a class="block rounded-xl px-3 py-2 hover:bg-slate-100" href="/dashboard/">داشبورد</a>
              <a class="block rounded-xl px-3 py-2 hover:bg-slate-100" href="/wallet/">کیف پول</a>
              <a class="block rounded-xl px-3 py-2 hover:bg-slate-100" href="/invoices/">فاکتورها</a>
              <a class="block rounded-xl px-3 py-2 hover:bg-slate-100" href="/orders/my/">سفارش‌ها</a>
              <a class="block rounded-xl px-3 py-2 hover:bg-slate-100" href="/tickets/">تیکت‌ها</a>
              <a class="block rounded-xl px-3 py-2 hover:bg-slate-100" href="/accounts/profile/">پروفایل</a>
              <a class="block rounded-xl px-3 py-2 hover:bg-slate-100" href="/accounts/security/">سوال امنیتی</a>
              <a class="block rounded-xl px-3 py-2 hover:bg-slate-100" href="/accounts/qr/">🔮 QR Code</a>

              <form method="post" action="/accounts/logout/" class="mt-1">{% csrf_token %}
                <button class="w-full rounded-xl border border-slate-200 px-3 py-2 text-right hover:bg-slate-50">خروج</button>
              </form>

              {% if user.is_staff %}
                <a class="mt-2 block rounded-xl border border-slate-200 px-3 py-2 hover:bg-slate-50"
                   href="/{{ site_settings.admin_path|default:'admin' }}/">ادمین</a>
              {% endif %}
            </div>
          </div>
        </div>
      {% endif %}

      {% if request.path|slice:":11" != "/dashboard/" and request.path|slice:":8" != "/wallet/" and request.path|slice:":10" != "/invoices/" and request.path|slice:":8" != "/orders/" and request.path|slice:":9" != "/tickets/" and request.path|slice:":18" != "/accounts/profile/" and request.path|slice:":19" != "/accounts/security/" %}
        <div class="flex items-center gap-2 text-sm">
          <a class="rounded-xl border border-slate-200 px-3 py-2 hover:bg-slate-50" href="/dashboard/">پنل کاربری</a>
          <form method="post" action="/accounts/logout/" class="inline">{% csrf_token %}
            <button class="rounded-xl border border-slate-200 px-3 py-2 hover:bg-slate-50">خروج</button>
          </form>
          {% if user.is_staff %}
            <a class="rounded-xl border border-slate-200 px-3 py-2 hover:bg-slate-50"
               href="/{{ site_settings.admin_path|default:'admin' }}/">ادمین</a>
          {% endif %}
        </div>
      {% endif %}
    {% endif %}

    {% if not user.is_authenticated %}
      <div class="flex items-center gap-2 text-sm">
        <a class="rounded-xl border border-slate-200 px-3 py-2 hover:bg-slate-50" href="/accounts/login/">ورود</a>
        <a class="rounded-xl bg-slate-900 px-3 py-2 text-white hover:opacity-95" href="/accounts/register/">ثبت‌نام</a>
      </div>
    {% endif %}

  </div>
</header>

<script>
(function(){
  var btn = document.getElementById('dashMenuBtn');
  var menu = document.getElementById('dashMenu');
  if(!btn || !menu) return;

  function closeMenu(){
    menu.classList.add('max-h-0','opacity-0','-translate-y-2','pointer-events-none');
    menu.classList.remove('max-h-[520px]','opacity-100','translate-y-0','pointer-events-auto');
    btn.setAttribute('aria-expanded','false');
  }
  function openMenu(){
    menu.classList.remove('max-h-0','opacity-0','-translate-y-2','pointer-events-none');
    menu.classList.add('max-h-[520px]','opacity-100','translate-y-0','pointer-events-auto');
    btn.setAttribute('aria-expanded','true');
  }
  function isOpen(){ return btn.getAttribute('aria-expanded') === 'true'; }

  btn.addEventListener('click', function(e){
    e.preventDefault();
    e.stopPropagation();
    isOpen() ? closeMenu() : openMenu();
  });

  document.addEventListener('click', function(e){
    if(isOpen() && !menu.contains(e.target) && !btn.contains(e.target)) closeMenu();
  });

  document.addEventListener('keydown', function(e){
    if(e.key === 'Escape') closeMenu();
  });
})();
</script>

<main class="mx-auto max-w-6xl px-4 py-8">
  {% if messages %}
    <div class="mb-5 space-y-2">
      {% for m in messages %}
        <div class="rounded-2xl border border-slate-200 bg-white p-3 text-sm">{{ m }}</div>
      {% endfor %}
    </div>
  {% endif %}
  {% block content %}{% endblock %}
</main>

<footer class="border-t border-slate-200/70 bg-white">
  <div class="mx-auto max-w-6xl px-4 py-8 text-sm text-slate-500">
    {{ site_settings.footer_text|default:"© تمامی حقوق محفوظ است." }}
  </div>
</footer>
</body>
</html>

HTML

  cat > app/templates/dashboard/home.html <<'HTML'
{% extends "base.html" %}
{% block title %}داشبورد{% endblock %}
{% block content %}
<div class="grid gap-4 lg:grid-cols-3">
  <div class="lg:col-span-2 space-y-4">
    <div class="rounded-2xl border border-slate-200 bg-white p-6 dark:border-slate-800 dark:bg-slate-950">
      <div class="flex items-center justify-between">
        <div>
          <h1 class="text-xl font-extrabold">داشبورد</h1>
          <div class="text-sm text-slate-500 dark:text-slate-300">موجودی کیف پول: <b>{{ wallet.balance }}</b> تومان</div>
        </div>
        <a class="rounded-xl border border-slate-200 px-4 py-2 hover:bg-slate-50 dark:border-slate-800 dark:hover:bg-slate-900" href="/">دوره‌ها</a>
      </div>
    </div>

    <div class="rounded-2xl border border-slate-200 bg-white p-6 dark:border-slate-800 dark:bg-slate-950">
      <h2 class="font-bold mb-3">آخرین سفارش‌ها</h2>
      <div class="space-y-2 text-sm">
        {% for o in orders %}
          <div class="rounded-xl border border-slate-200 p-3 dark:border-slate-800">
            <div class="flex items-center justify-between gap-3">
              <div class="font-semibold">{{ o.course.title }}</div>
              <div><b>{{ o.final_amount }}</b> تومان</div>
              <span class="rounded-xl px-3 py-1 text-xs bg-slate-200 text-slate-700 dark:bg-slate-800 dark:text-slate-200">{{ o.get_status_display }}</span>
            </div>
          </div>
        {% empty %}<div class="text-slate-500 dark:text-slate-300">سفارشی ندارید.</div>{% endfor %}
      </div>
    </div>
  </div>

  <aside class="space-y-4">
    <div class="rounded-2xl border border-slate-200 bg-white p-6 dark:border-slate-800 dark:bg-slate-950">
      <h3 class="font-bold mb-3">میانبر</h3>
      <div class="grid gap-2 text-sm">
        <a class="rounded-xl border border-slate-200 px-4 py-2 hover:bg-slate-50 dark:border-slate-800 dark:hover:bg-slate-900" href="/wallet/">کیف پول</a>
        <a class="rounded-xl border border-slate-200 px-4 py-2 hover:bg-slate-50 dark:border-slate-800 dark:hover:bg-slate-900" href="/invoices/">فاکتورها</a>
        <a class="rounded-xl border border-slate-200 px-4 py-2 hover:bg-slate-50 dark:border-slate-800 dark:hover:bg-slate-900" href="/accounts/security/">سوال امنیتی</a>
        <a class="rounded-xl border border-emerald-200 bg-emerald-50 px-4 py-2 hover:bg-emerald-100 dark:border-emerald-800 dark:bg-emerald-950 dark:hover:bg-emerald-900 font-medium text-emerald-700 dark:text-emerald-300" href="/accounts/qr/">🔮 QR Code من</a>
        {% if user.is_staff %}
        <a class="rounded-xl border border-orange-200 bg-orange-50 px-4 py-2 hover:bg-orange-100 dark:border-orange-800 dark:bg-orange-950 dark:hover:bg-orange-900 font-medium text-orange-700 dark:text-orange-300" href="/panel/tools/">🛠️ ابزارهای مدیریت</a>
        {% endif %}
      </div>
    </div>
    <div class="rounded-2xl border border-slate-200 bg-white p-6 dark:border-slate-800 dark:bg-slate-950">
      <h3 class="font-bold mb-3">تیکت‌ها</h3>
      <div class="space-y-2 text-sm">
        {% for t in tickets %}
          <a class="block rounded-xl border border-slate-200 px-4 py-2 hover:bg-slate-50 dark:border-slate-800 dark:hover:bg-slate-900" href="/tickets/{{ t.id }}/">{{ t.subject }}</a>
        {% empty %}<div class="text-slate-500 dark:text-slate-300">تیکتی ندارید.</div>{% endfor %}
      </div>
      <a class="mt-3 block rounded-xl bg-slate-900 px-4 py-2 text-center text-white hover:opacity-95 dark:bg-white dark:text-slate-900" href="/tickets/new/">ثبت تیکت</a>
    </div>
  </aside>
</div>
{% endblock %}
HTML

  cat > app/templates/courses/list.html <<'HTML'
{% extends "base.html" %}
{% block title %}دوره‌ها{% endblock %}
{% block content %}
<div class="mb-6 flex items-end justify-between gap-4">
  <div>
    <h1 class="text-2xl font-extrabold">{{ tpl.home_title|default:"دوره‌های آموزشی" }}</h1>
    <div class="text-sm text-slate-500 dark:text-slate-300">{{ tpl.home_subtitle|default:"جدیدترین دوره‌ها" }}</div>
  </div>
</div>

<div class="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
  {% for c in object_list %}
    <a href="/courses/{{ c.slug }}/" class="overflow-hidden rounded-2xl border border-slate-200 bg-white hover:shadow-sm dark:border-slate-800 dark:bg-slate-950">
      <div class="aspect-[16/9] bg-slate-100 dark:bg-slate-900">
        {% if c.cover %}<img class="h-full w-full object-cover" src="{{ c.cover.url }}" alt="{{ c.title }}">{% endif %}
      </div>
      <div class="p-4">
        <div class="font-bold">{{ c.title }}</div>
        <div class="mt-1 text-sm text-slate-600 dark:text-slate-300 line-clamp-2">{{ c.summary|default:"—" }}</div>
        <div class="mt-3 text-sm">
          {% if c.is_free_for_all or not c.price_toman %}
            <span class="rounded-xl bg-emerald-600 px-3 py-1 text-white">رایگان</span>
          {% else %}
            <span class="rounded-xl bg-slate-900 px-3 py-1 text-white dark:bg-white dark:text-slate-900">{{ c.price_toman }} تومان</span>
          {% endif %}
        </div>
      </div>
    </a>
  {% empty %}
    <div class="text-slate-500 dark:text-slate-300">{{ tpl.home_empty|default:"هنوز دوره‌ای منتشر نشده است." }}</div>
  {% endfor %}
</div>
{% endblock %}
HTML

  cat > app/templates/courses/detail.html <<'HTML'
{% extends "base.html" %}
{% block title %}{{ object.title }}{% endblock %}
{% block content %}
<div class="grid gap-6 lg:grid-cols-3">
  <div class="lg:col-span-2 space-y-4">
    <div class="rounded-2xl border border-slate-200 bg-white p-6 dark:border-slate-800 dark:bg-slate-950">
      <h1 class="text-2xl font-extrabold mb-2">{{ object.title }}</h1>
      <div class="text-slate-600 dark:text-slate-300">{{ object.description|linebreaks }}</div>
    </div>
  </div>
  <aside class="space-y-4">
    <div class="rounded-2xl border border-slate-200 bg-white p-6 dark:border-slate-800 dark:bg-slate-950">
      {% if has_access %}
        <div class="rounded-xl bg-emerald-600 px-4 py-2 text-white text-sm">دسترسی شما فعال است.</div>
      {% else %}
        {% if object.is_free_for_all or not object.price_toman %}
          <div class="rounded-xl bg-emerald-600 px-4 py-2 text-white text-sm">این دوره رایگان است.</div>
        {% else %}
          <div class="text-sm text-slate-500 dark:text-slate-300">قیمت</div>
          <div class="text-2xl font-extrabold mt-1">{{ object.price_toman }} تومان</div>
          <a class="mt-4 block rounded-xl bg-slate-900 px-4 py-2 text-center text-white hover:opacity-95 dark:bg-white dark:text-slate-900" href="/orders/checkout/{{ object.slug }}/">پرداخت</a>
          <div class="mt-2 text-xs text-slate-500 dark:text-slate-300">کارت‌به‌کارت یا کیف پول</div>
        {% endif %}
      {% endif %}
    </div>
  </aside>
</div>
{% endblock %}
HTML

  cat > app/templates/accounts/login.html <<'HTML'
{% extends "base.html" %}
{% block title %}ورود{% endblock %}
{% block content %}
<div class="mx-auto max-w-md rounded-2xl border border-slate-200 bg-white p-6 dark:border-slate-800 dark:bg-slate-950">
  <h1 class="text-xl font-bold mb-1">ورود</h1>
  <form method="post" class="space-y-4">{% csrf_token %}
    {% include "partials/form_errors.html" %}
    {% for field in form %}{% include "partials/field.html" with field=field %}{% endfor %}
    <button class="w-full rounded-xl bg-slate-900 px-4 py-2 text-white hover:opacity-95 dark:bg-white dark:text-slate-900">ورود</button>
  </form>
  <div class="mt-3 text-sm text-slate-500 dark:text-slate-300">رمز را فراموش کرده‌اید؟ <a class="underline" href="/accounts/reset/">بازیابی</a></div>
  <div class="mt-2 text-sm text-slate-500 dark:text-slate-300">حساب ندارید؟ <a class="underline" href="/accounts/register/">ثبت‌نام</a></div>
</div>
{% endblock %}
HTML
  cat > app/templates/accounts/register.html <<'HTML'
{% extends "base.html" %}
{% block title %}ثبت‌نام{% endblock %}
{% block content %}
<div class="mx-auto max-w-md rounded-2xl border border-slate-200 bg-white p-6 dark:border-slate-800 dark:bg-slate-950">
  <h1 class="text-xl font-bold mb-1">ثبت‌نام</h1>
  <form method="post" class="space-y-4">{% csrf_token %}
    {% include "partials/form_errors.html" %}
    {% for field in form %}{% include "partials/field.html" with field=field %}{% endfor %}
    <button class="w-full rounded-xl bg-slate-900 px-4 py-2 text-white hover:opacity-95 dark:bg-white dark:text-slate-900">ساخت حساب</button>
  </form>
  <div class="mt-2 text-sm text-slate-500 dark:text-slate-300">قبلاً ثبت‌نام کرده‌اید؟ <a class="underline" href="/accounts/login/">ورود</a></div>
</div>
{% endblock %}
HTML
  cat > app/templates/accounts/profile.html <<'HTML'
{% extends "base.html" %}
{% block title %}پروفایل{% endblock %}
{% block content %}
<div class="mx-auto max-w-2xl space-y-4">
  <div class="rounded-2xl border border-slate-200 bg-white p-6 dark:border-slate-800 dark:bg-slate-950">
    <h1 class="text-xl font-extrabold mb-4">پروفایل</h1>

    <!-- User info -->
    <div class="mb-4 p-3 rounded-xl bg-slate-50 dark:bg-slate-900">
      <div class="text-sm text-slate-500 dark:text-slate-400">ایمیل</div>
      <div class="font-medium" dir="ltr">{{ user.email }}</div>
    </div>

    {% if not allow_edit %}
      <div class="rounded-xl border border-amber-200 bg-amber-50 p-4 text-amber-800 dark:border-amber-900/40 dark:bg-amber-950/40 dark:text-amber-200">
        <p class="font-semibold">ویرایش پروفایل غیرفعال است</p>
        <p class="text-sm mt-1">ویرایش پروفایل توسط مدیر سایت غیرفعال شده است.</p>
      </div>
    {% elif form.fields %}
      <form method="post" class="space-y-4">{% csrf_token %}
        {% include "partials/form_errors.html" %}
        {% for field in form %}{% include "partials/field.html" with field=field %}{% endfor %}
        <button class="w-full rounded-xl bg-slate-900 px-4 py-2 text-white hover:opacity-95 dark:bg-white dark:text-slate-900">ذخیره</button>
      </form>
    {% else %}
      <div class="text-slate-500 dark:text-slate-400 text-sm">
        فیلد قابل ویرایشی وجود ندارد.
      </div>
    {% endif %}
  </div>

  <!-- Security Question Info -->
  <div class="rounded-2xl border border-slate-200 bg-white p-6 dark:border-slate-800 dark:bg-slate-950">
    <h2 class="text-lg font-bold mb-4">سوال امنیتی</h2>
    {% if profile.q1 %}
      <div class="rounded-xl border border-slate-200 p-3 dark:border-slate-700">
        <div class="text-slate-500 dark:text-slate-400 text-xs mb-1">سوال امنیتی شما</div>
        <div class="font-medium">{{ profile.q1.text }}</div>
        <div class="text-emerald-600 dark:text-emerald-400 text-xs mt-1">✓ پاسخ تنظیم شده</div>
      </div>
    {% else %}
      <div class="text-slate-500 dark:text-slate-400 text-sm">
        سوال امنیتی تنظیم نشده است. برای امنیت بیشتر، سوال امنیتی خود را تنظیم کنید.
      </div>
    {% endif %}
    <div class="mt-4">
      <a class="inline-block rounded-xl border border-slate-200 px-4 py-2 text-sm hover:bg-slate-50 dark:border-slate-700 dark:hover:bg-slate-900" href="/accounts/security/">مدیریت سوال امنیتی</a>
    </div>
  </div>
</div>
{% endblock %}
HTML
  cat > app/templates/accounts/security_questions.html <<'HTML'
{% extends "base.html" %}
{% block title %}سوال امنیتی{% endblock %}
{% block content %}
<div class="mx-auto max-w-2xl rounded-2xl border border-slate-200 bg-white p-6 dark:border-slate-800 dark:bg-slate-950">
  <h1 class="text-xl font-extrabold mb-4">سوال امنیتی</h1>

  {% if not allow_edit %}
    <div class="rounded-xl border border-amber-200 bg-amber-50 p-4 text-amber-800 dark:border-amber-900/40 dark:bg-amber-950/40 dark:text-amber-200">
      <p class="font-semibold">تغییر سوال امنیتی غیرفعال است</p>
      <p class="text-sm mt-1">تغییر سوال امنیتی توسط مدیر سایت غیرفعال شده است.</p>
    </div>
  {% else %}
    <p class="text-sm text-slate-500 dark:text-slate-400 mb-4">سوال امنیتی برای بازیابی رمز عبور استفاده می‌شود. لطفاً سوالی انتخاب کنید که پاسخ آن را فقط خودتان می‌دانید.</p>
    <form method="post" class="space-y-4">{% csrf_token %}
      {% include "partials/form_errors.html" %}
      {% for field in form %}{% include "partials/field.html" with field=field %}{% endfor %}
      <button class="w-full rounded-xl bg-slate-900 px-4 py-2 text-white hover:opacity-95 dark:bg-white dark:text-slate-900">ذخیره</button>
    </form>
  {% endif %}
</div>
{% endblock %}
HTML
  cat > app/templates/accounts/reset_step1.html <<'HTML'
{% extends "base.html" %}
{% block title %}بازیابی رمز{% endblock %}
{% block content %}
<div class="mx-auto max-w-md rounded-2xl border border-slate-200 bg-white p-6 dark:border-slate-800 dark:bg-slate-950">
  <h1 class="text-xl font-extrabold mb-4">بازیابی رمز عبور</h1>
  <form method="post" class="space-y-4">{% csrf_token %}
    {% include "partials/form_errors.html" %}
    {% for field in form %}{% include "partials/field.html" with field=field %}{% endfor %}
    <button class="w-full rounded-xl bg-slate-900 px-4 py-2 text-white hover:opacity-95 dark:bg-white dark:text-slate-900">ادامه</button>
  </form>
</div>
{% endblock %}
HTML
  cat > app/templates/accounts/reset_step2.html <<'HTML'
{% extends "base.html" %}
{% block title %}تایید سوال امنیتی{% endblock %}
{% block content %}
<div class="mx-auto max-w-md rounded-2xl border border-slate-200 bg-white p-6 dark:border-slate-800 dark:bg-slate-950">
  <h1 class="text-xl font-extrabold mb-4">تایید سوال امنیتی</h1>
  <div class="text-sm text-slate-500 dark:text-slate-300 mb-4">کاربر: <b dir="ltr">{{ username }}</b></div>
  <form method="post" class="space-y-4">{% csrf_token %}
    {% include "partials/form_errors.html" %}
    <div class="space-y-1">
      <div class="text-sm font-medium">{{ q1 }}</div>
      {{ form.a1 }}
    </div>
    {% include "partials/field.html" with field=form.new_password1 %}
    {% include "partials/field.html" with field=form.new_password2 %}
    <button class="w-full rounded-xl bg-slate-900 px-4 py-2 text-white hover:opacity-95 dark:bg-white dark:text-slate-900">تغییر رمز</button>
  </form>
</div>
{% endblock %}
HTML

  cat > app/templates/accounts/qr_settings.html <<'HTML'
{% extends "base.html" %}
{% block title %}تنظیمات QR Code{% endblock %}
{% block content %}
<div class="mx-auto max-w-2xl space-y-6">
  <div class="rounded-2xl border border-slate-200 bg-white p-6 dark:border-slate-800 dark:bg-slate-950">
    <h1 class="text-2xl font-extrabold mb-2">🔮 QR Code هوشمند</h1>
    <p class="text-sm text-slate-500 dark:text-slate-400">با اسکن این کد، پروفایل تحصیلی شما نمایش داده می‌شود.</p>
  </div>

  <div class="grid md:grid-cols-2 gap-6">
    <div class="rounded-2xl border border-slate-200 bg-white p-6 dark:border-slate-800 dark:bg-slate-950 text-center">
      {% if profile.qr_enabled %}
        <img src="/accounts/qr/image/" alt="QR Code" class="mx-auto w-48 h-48 rounded-xl border border-slate-200 dark:border-slate-700">
        <div class="mt-3 text-xs text-slate-500 dark:text-slate-400 break-all">{{ qr_url }}</div>
        <form method="post" action="/accounts/qr/regenerate/" class="mt-3">{% csrf_token %}
          <button class="text-sm text-rose-600 hover:underline">بازسازی توکن</button>
        </form>
      {% else %}
        <div class="w-48 h-48 mx-auto rounded-xl border-2 border-dashed border-slate-300 dark:border-slate-700 flex items-center justify-center">
          <span class="text-slate-400">غیرفعال</span>
        </div>
      {% endif %}
    </div>

    <form method="post" class="rounded-2xl border border-slate-200 bg-white p-6 dark:border-slate-800 dark:bg-slate-950 space-y-4">
      {% csrf_token %}
      <div class="font-bold mb-4">تنظیمات نمایش</div>
      
      <label class="flex items-center gap-3 cursor-pointer">
        <input type="checkbox" name="qr_enabled" {% if profile.qr_enabled %}checked{% endif %} class="w-5 h-5 rounded border-slate-300 text-emerald-600 focus:ring-emerald-500">
        <span class="font-medium">QR Code فعال باشد</span>
      </label>
      
      <hr class="border-slate-200 dark:border-slate-700">
      <div class="text-sm font-medium text-slate-500 dark:text-slate-400 mb-2">اطلاعات قابل نمایش:</div>
      
      <label class="flex items-center gap-3 cursor-pointer">
        <input type="checkbox" name="qr_show_name" {% if profile.qr_show_name %}checked{% endif %} class="w-4 h-4 rounded border-slate-300 text-slate-600 focus:ring-slate-500">
        <span>نام و نام خانوادگی</span>
      </label>
      
      <label class="flex items-center gap-3 cursor-pointer">
        <input type="checkbox" name="qr_show_email" {% if profile.qr_show_email %}checked{% endif %} class="w-4 h-4 rounded border-slate-300 text-slate-600 focus:ring-slate-500">
        <span>ایمیل</span>
      </label>
      
      <label class="flex items-center gap-3 cursor-pointer">
        <input type="checkbox" name="qr_show_join_date" {% if profile.qr_show_join_date %}checked{% endif %} class="w-4 h-4 rounded border-slate-300 text-slate-600 focus:ring-slate-500">
        <span>تاریخ عضویت</span>
      </label>
      
      <label class="flex items-center gap-3 cursor-pointer">
        <input type="checkbox" name="qr_show_courses" {% if profile.qr_show_courses %}checked{% endif %} class="w-4 h-4 rounded border-slate-300 text-slate-600 focus:ring-slate-500">
        <span>لیست دوره‌های گذرانده</span>
      </label>
      
      <label class="flex items-center gap-3 cursor-pointer">
        <input type="checkbox" name="qr_show_stats" {% if profile.qr_show_stats %}checked{% endif %} class="w-4 h-4 rounded border-slate-300 text-slate-600 focus:ring-slate-500">
        <span>آمار کلی (تعداد دوره‌ها)</span>
      </label>

      <button type="submit" class="w-full rounded-xl bg-slate-900 px-4 py-2.5 text-white font-medium hover:opacity-95 dark:bg-white dark:text-slate-900">
        ذخیره تنظیمات
      </button>
    </form>
  </div>
</div>
{% endblock %}
HTML

  cat > app/templates/accounts/qr_public.html <<'HTML'
{% extends "base.html" %}
{% load jalali_tags %}
{% block title %}پروفایل تایید شده{% endblock %}
{% block content %}
<div class="mx-auto max-w-lg">
  <div class="rounded-2xl border border-emerald-200 bg-gradient-to-br from-emerald-50 to-white p-6 dark:border-emerald-900 dark:from-emerald-950 dark:to-slate-950">
    <div class="flex items-center gap-3 mb-6">
      <div class="w-12 h-12 rounded-full bg-emerald-100 dark:bg-emerald-900 flex items-center justify-center">
        <svg class="w-6 h-6 text-emerald-600 dark:text-emerald-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"/>
        </svg>
      </div>
      <div>
        <div class="font-bold text-emerald-700 dark:text-emerald-400">پروفایل تایید شده ✓</div>
        <div class="text-xs text-emerald-600 dark:text-emerald-500">اصالت این پروفایل تایید شده است</div>
      </div>
    </div>

    <div class="space-y-4">
      {% if data.name %}
      <div class="flex justify-between items-center py-2 border-b border-emerald-100 dark:border-emerald-900">
        <span class="text-slate-500 dark:text-slate-400">نام</span>
        <span class="font-medium">{{ data.name }}</span>
      </div>
      {% endif %}
      
      {% if data.email %}
      <div class="flex justify-between items-center py-2 border-b border-emerald-100 dark:border-emerald-900">
        <span class="text-slate-500 dark:text-slate-400">ایمیل</span>
        <span class="font-medium" dir="ltr">{{ data.email }}</span>
      </div>
      {% endif %}
      
      {% if data.join_date %}
      <div class="flex justify-between items-center py-2 border-b border-emerald-100 dark:border-emerald-900">
        <span class="text-slate-500 dark:text-slate-400">عضویت از</span>
        <span class="font-medium">{{ data.join_date|jalali }}</span>
      </div>
      {% endif %}
      
      {% if data.total_courses %}
      <div class="flex justify-between items-center py-2 border-b border-emerald-100 dark:border-emerald-900">
        <span class="text-slate-500 dark:text-slate-400">تعداد دوره‌ها</span>
        <span class="font-bold text-lg text-emerald-600 dark:text-emerald-400">{{ data.total_courses }}</span>
      </div>
      {% endif %}
      
      {% if data.courses %}
      <div class="pt-2">
        <div class="text-sm font-medium text-slate-500 dark:text-slate-400 mb-3">دوره‌های گذرانده:</div>
        <div class="space-y-2">
          {% for course in data.courses %}
          <div class="rounded-xl bg-white dark:bg-slate-900 border border-emerald-100 dark:border-emerald-900 px-3 py-2 text-sm">
            {{ course.title }}
          </div>
          {% endfor %}
        </div>
      </div>
      {% endif %}
    </div>
    
    <div class="mt-6 pt-4 border-t border-emerald-100 dark:border-emerald-900 text-center text-xs text-emerald-600 dark:text-emerald-500">
      آخرین بروزرسانی: {{ data.verified_at|jalali_datetime }}
    </div>
  </div>
</div>
{% endblock %}
HTML

  cat > app/templates/accounts/qr_disabled.html <<'HTML'
{% extends "base.html" %}
{% block title %}غیرفعال{% endblock %}
{% block content %}
<div class="mx-auto max-w-md text-center py-12">
  <div class="w-20 h-20 mx-auto rounded-full bg-slate-100 dark:bg-slate-800 flex items-center justify-center mb-4">
    <svg class="w-10 h-10 text-slate-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M18.364 18.364A9 9 0 005.636 5.636m12.728 12.728A9 9 0 015.636 5.636m12.728 12.728L5.636 5.636"/>
    </svg>
  </div>
  <h1 class="text-xl font-bold mb-2">{{ message }}</h1>
  <p class="text-slate-500 dark:text-slate-400">این لینک در دسترس نیست.</p>
  <a href="/" class="inline-block mt-6 rounded-xl bg-slate-900 px-6 py-2 text-white hover:opacity-95 dark:bg-white dark:text-slate-900">بازگشت به خانه</a>
</div>
{% endblock %}
HTML

  cat > app/templates/orders/checkout.html <<'HTML'
{% extends "base.html" %}
{% block title %}پرداخت{% endblock %}
{% block content %}
<div class="mx-auto max-w-2xl space-y-4">
  <div class="rounded-2xl border border-slate-200 bg-white p-6 dark:border-slate-800 dark:bg-slate-950">
    <h1 class="text-xl font-bold">پرداخت</h1>
    <div class="text-sm text-slate-500 dark:text-slate-300">دوره: <b>{{ course.title }}</b></div>
  </div>

  <div class="rounded-2xl border border-slate-200 bg-white p-6 dark:border-slate-800 dark:bg-slate-950 space-y-4">
    <form method="post" class="space-y-3">{% csrf_token %}
      <div class="text-sm font-semibold">کد تخفیف</div>
      <div class="flex gap-2">
        <div class="flex-1">{{ coupon_form.coupon_code }}</div>
        <button name="apply_coupon" value="1" class="rounded-xl border border-slate-200 px-4 py-2 hover:bg-slate-50 dark:border-slate-700 dark:hover:bg-slate-900">اعمال</button>
      </div>
      <div class="text-xs text-slate-500 dark:text-slate-300">{% if first_purchase_eligible %}در صورت عدم وارد کردن کد، ممکن است تخفیف خرید اول اعمال شود.{% endif %}</div>
    </form>

    <div class="rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm dark:border-slate-800 dark:bg-slate-900/40">
      پایه: <b>{{ order.amount }}</b> | تخفیف: <b>{{ order.discount_amount }}</b> {% if discount_label %}({{ discount_label }}){% endif %} |
      نهایی: <b>{{ order.final_amount }}</b> تومان
    </div>

    <!-- درگاه‌های پرداخت آنلاین -->
    {% if active_gateways %}
    <div class="rounded-2xl border border-emerald-200 bg-emerald-50 p-4 dark:border-emerald-900/40 dark:bg-emerald-950/40">
      <div class="text-sm font-semibold text-emerald-800 dark:text-emerald-200 mb-3">💳 پرداخت آنلاین</div>
      <div class="grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
        {% for gw in active_gateways %}
        <a href="/orders/pay/{{ order.id }}/{{ gw.gateway_type }}/" 
           class="flex items-center justify-center gap-2 rounded-xl border border-emerald-300 bg-white px-4 py-3 text-sm font-medium text-emerald-700 hover:bg-emerald-100 transition-colors dark:border-emerald-800 dark:bg-emerald-900/40 dark:text-emerald-300 dark:hover:bg-emerald-900/60">
          {% if gw.gateway_type == "zarinpal" %}💛{% elif gw.gateway_type == "zibal" %}💙{% elif gw.gateway_type == "idpay" %}💚{% else %}💳{% endif %}
          {{ gw.get_gateway_type_display }}
          {% if gw.is_sandbox %}<span class="text-xs text-orange-500">(تست)</span>{% endif %}
        </a>
        {% endfor %}
      </div>
    </div>
    {% endif %}

    <div class="grid gap-3 md:grid-cols-2">
      <a class="rounded-xl bg-slate-900 px-4 py-2 text-center text-white hover:opacity-95 dark:bg-white dark:text-slate-900" href="/orders/receipt/{{ order.id }}/">آپلود رسید کارت‌به‌کارت</a>
      <div class="rounded-2xl border border-slate-200 p-4 dark:border-slate-800">
        <div class="text-sm font-semibold">پرداخت با کیف پول</div>
        <div class="text-sm text-slate-500 dark:text-slate-300 mt-1">موجودی: <b>{{ wallet.balance }}</b> تومان</div>
        <form method="post" class="mt-3">{% csrf_token %}
          <button name="pay_wallet" value="1" class="w-full rounded-xl bg-emerald-600 px-4 py-2 text-white hover:opacity-95">پرداخت با کیف پول</button>
        </form>
      </div>
    </div>

    {% if setting %}
    <div class="rounded-2xl border border-slate-200 p-4 text-sm dark:border-slate-800">
      <div class="font-semibold mb-1">اطلاعات کارت (کارت به کارت)</div>
      نام: <b>{{ setting.account_holder|default:"-" }}</b><br>
      کارت: <b dir="ltr">{{ setting.card_number|default:"-" }}</b>
      {% if setting.note %}<div class="mt-2 text-xs text-slate-500 dark:text-slate-300">{{ setting.note }}</div>{% endif %}
    </div>
    {% endif %}
  </div>
</div>
{% endblock %}
HTML

  cat > app/templates/orders/receipt.html <<'HTML'
{% extends "base.html" %}
{% block title %}آپلود رسید{% endblock %}
{% block content %}
<div class="mx-auto max-w-xl rounded-2xl border border-slate-200 bg-white p-6 dark:border-slate-800 dark:bg-slate-950">
  <h1 class="text-xl font-bold mb-1">آپلود رسید</h1>
  <div class="text-xs text-slate-500 dark:text-slate-300 mb-4">سفارش: <span dir="ltr">{{ order.id }}</span></div>
  <form method="post" enctype="multipart/form-data" class="space-y-4">{% csrf_token %}
    {% include "partials/form_errors.html" %}
    {% for field in form %}{% include "partials/field.html" with field=field %}{% endfor %}
    <button class="w-full rounded-xl bg-slate-900 px-4 py-2 text-white hover:opacity-95 dark:bg-white dark:text-slate-900">ثبت</button>
  </form>
</div>
{% endblock %}
HTML

  cat > app/templates/orders/my.html <<'HTML'
{% extends "base.html" %}
{% block title %}سفارش‌ها{% endblock %}
{% block content %}
<div class="mx-auto max-w-4xl rounded-2xl border border-slate-200 bg-white p-6 dark:border-slate-800 dark:bg-slate-950">
  <h1 class="text-xl font-extrabold mb-4">سفارش‌های من</h1>
  <div class="space-y-3 text-sm">
    {% for o in orders %}
      <div class="rounded-2xl border border-slate-200 p-4 dark:border-slate-800">
        <div class="flex flex-col gap-2 md:flex-row md:items-center md:justify-between">
          <div class="font-semibold">{{ o.course.title }}</div>
          <div><b>{{ o.final_amount }}</b> تومان</div>
          <div class="text-slate-500 dark:text-slate-300">{{ o.get_status_display }}</div>
        </div>
        <div class="mt-2 flex flex-wrap gap-2">
          {% if o.status == "paid" %}
            <a class="rounded-xl border border-slate-200 px-3 py-2 hover:bg-slate-50 dark:border-slate-800 dark:hover:bg-slate-900" href="/invoices/{{ o.id }}/">فاکتور</a>
          {% else %}
            <a class="rounded-xl border border-slate-200 px-3 py-2 hover:bg-slate-50 dark:border-slate-800 dark:hover:bg-slate-900" href="/orders/receipt/{{ o.id }}/">رسید</a>
          {% endif %}
          {% if o.status != "paid" and o.status != "canceled" %}
            <form method="post" action="/orders/cancel/{{ o.id }}/" class="inline">{% csrf_token %}
              <button class="rounded-xl border border-rose-200 px-3 py-2 text-rose-700 hover:bg-rose-50 dark:border-rose-900/40 dark:text-rose-200 dark:hover:bg-rose-950/30">لغو</button>
            </form>
          {% endif %}
        </div>
      </div>
    {% empty %}<div class="text-slate-500 dark:text-slate-300">سفارشی ندارید.</div>{% endfor %}
  </div>
</div>
{% endblock %}
HTML

  cat > app/templates/wallet/home.html <<'HTML'
{% extends "base.html" %}
{% load jalali_tags %}
{% block title %}کیف پول{% endblock %}
{% block content %}
<div class="mx-auto max-w-4xl space-y-4">
  <!-- Balance Card -->
  <div class="rounded-2xl border border-slate-200 bg-gradient-to-l from-emerald-50 to-white p-6 dark:border-slate-800 dark:from-emerald-950/30 dark:to-slate-950">
    <div class="flex items-center justify-between gap-3 flex-wrap">
      <div>
        <h1 class="text-xl font-extrabold mb-1">کیف پول</h1>
        <div class="text-2xl font-bold text-emerald-600 dark:text-emerald-400">
          {{ wallet.balance|default:0 }}
          <span class="text-sm font-normal text-slate-500 dark:text-slate-400">تومان</span>
        </div>
      </div>
      <a class="rounded-xl bg-emerald-600 px-5 py-2.5 text-white font-semibold hover:bg-emerald-700 transition-colors" href="/wallet/topup/">
        + درخواست شارژ
      </a>
    </div>
  </div>

  <div class="grid gap-4 lg:grid-cols-2">
    <!-- Transactions -->
    <div class="rounded-2xl border border-slate-200 bg-white p-6 dark:border-slate-800 dark:bg-slate-950">
      <h2 class="font-bold mb-3">تراکنش‌ها</h2>
      <div class="space-y-2 text-sm max-h-96 overflow-y-auto">
        {% for t in txns %}
          <div class="rounded-xl border border-slate-200 p-3 dark:border-slate-800">
            <div class="flex items-center justify-between">
              <div class="text-slate-600 dark:text-slate-300">{{ t.get_kind_display }}</div>
              <div class="font-bold {% if t.amount >= 0 %}text-emerald-600{% else %}text-rose-600{% endif %}">
                {% if t.amount >= 0 %}+{% endif %}{{ t.amount }} تومان
              </div>
            </div>
            {% if t.description %}
            <div class="text-xs text-slate-500 dark:text-slate-400 mt-1">{{ t.description }}</div>
            {% endif %}
            <div class="text-xs text-slate-400 dark:text-slate-500 mt-1">{{ t.created_at|jalali_datetime }}</div>
          </div>
        {% empty %}
          <div class="text-slate-500 dark:text-slate-400 text-center py-4">تراکنشی ندارید.</div>
        {% endfor %}
      </div>
    </div>

    <!-- Top-up Requests -->
    <div class="rounded-2xl border border-slate-200 bg-white p-6 dark:border-slate-800 dark:bg-slate-950">
      <h2 class="font-bold mb-3">درخواست‌های شارژ</h2>
      <div class="space-y-2 text-sm max-h-96 overflow-y-auto">
        {% for r in topups %}
          <div class="rounded-xl border border-slate-200 p-3 dark:border-slate-800">
            <div class="flex items-center justify-between">
              <div class="font-bold">{{ r.amount }} تومان</div>
              <div class="px-2 py-0.5 rounded-lg text-xs font-medium
                {% if r.status == 'approved' %}bg-emerald-100 text-emerald-700 dark:bg-emerald-900/40 dark:text-emerald-300
                {% elif r.status == 'rejected' %}bg-rose-100 text-rose-700 dark:bg-rose-900/40 dark:text-rose-300
                {% else %}bg-amber-100 text-amber-700 dark:bg-amber-900/40 dark:text-amber-300{% endif %}">
                {{ r.get_status_display }}
              </div>
            </div>
            {% if r.note %}
            <div class="text-xs text-slate-500 dark:text-slate-400 mt-1">{{ r.note|truncatechars:50 }}</div>
            {% endif %}
            <div class="text-xs text-slate-400 dark:text-slate-500 mt-1">{{ r.created_at|jalali_datetime }}</div>
          </div>
        {% empty %}
          <div class="text-slate-500 dark:text-slate-400 text-center py-4">درخواستی ندارید.</div>
        {% endfor %}
      </div>
    </div>
  </div>
</div>
{% endblock %}
HTML

  cat > app/templates/wallet/topup.html <<'HTML'
{% extends "base.html" %}
{% block title %}شارژ کیف پول{% endblock %}
{% block content %}
<div class="mx-auto max-w-xl space-y-4">
  <!-- Header -->
  <div class="rounded-2xl border border-slate-200 bg-white p-6 dark:border-slate-800 dark:bg-slate-950">
    <h1 class="text-xl font-extrabold mb-2">شارژ کیف پول</h1>
    <p class="text-sm text-slate-500 dark:text-slate-400">
      برای شارژ کیف پول، یکی از روش‌های زیر را انتخاب کنید.
    </p>
  </div>

  <!-- Online Payment Gateways -->
  {% if active_gateways %}
  <div class="rounded-2xl border border-emerald-200 bg-emerald-50 p-5 dark:border-emerald-900/40 dark:bg-emerald-950/40">
    <div class="text-sm font-semibold text-emerald-800 dark:text-emerald-200 mb-3">💳 شارژ آنلاین (فوری)</div>
    <form id="online-topup-form" class="space-y-3">
      <div class="space-y-1">
        <label class="block text-sm font-medium text-emerald-700 dark:text-emerald-300">مبلغ شارژ (تومان)</label>
        <input type="number" name="online_amount" id="online_amount" min="1000" step="1000" placeholder="مثال: 50000"
               class="w-full rounded-xl border border-emerald-300 bg-white px-3 py-2 text-sm outline-none focus:ring-2 focus:ring-emerald-400 dark:bg-emerald-900/40 dark:border-emerald-700 dark:text-white" dir="ltr">
        <p class="text-xs text-emerald-600 dark:text-emerald-400">حداقل ۱,۰۰۰ تومان</p>
      </div>
      <div class="grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
        {% for gw in active_gateways %}
        <a href="#" onclick="submitOnlineTopup('{{ gw.gateway_type }}'); return false;"
           class="flex items-center justify-center gap-2 rounded-xl border border-emerald-300 bg-white px-4 py-3 text-sm font-medium text-emerald-700 hover:bg-emerald-100 transition-colors dark:border-emerald-800 dark:bg-emerald-900/40 dark:text-emerald-300 dark:hover:bg-emerald-900/60">
          {% if gw.gateway_type == "zarinpal" %}💛{% elif gw.gateway_type == "zibal" %}💙{% elif gw.gateway_type == "idpay" %}💚{% else %}💳{% endif %}
          {{ gw.get_gateway_type_display }}
          {% if gw.is_sandbox %}<span class="text-xs text-orange-500">(تست)</span>{% endif %}
        </a>
        {% endfor %}
      </div>
    </form>
  </div>

  <script>
  function submitOnlineTopup(gatewayType) {
    var amount = document.getElementById('online_amount').value;
    if (!amount || parseInt(amount) < 1000) {
      alert('لطفاً مبلغ شارژ را وارد کنید (حداقل ۱۰۰۰ تومان)');
      return;
    }
    window.location.href = '/wallet/pay/' + gatewayType + '/?amount=' + amount;
  }
  </script>
  {% endif %}

  <!-- Bank Info -->
  {% if bank_info %}
  <div class="rounded-2xl border border-blue-200 bg-blue-50 p-4 dark:border-blue-900/40 dark:bg-blue-950/40">
    <div class="text-sm font-semibold text-blue-800 dark:text-blue-200 mb-2">🏦 کارت به کارت (دستی)</div>
    {% if bank_info.card_number %}
    <div class="text-sm text-blue-700 dark:text-blue-300 mb-1">
      <span class="font-medium">شماره کارت:</span>
      <span dir="ltr" class="font-mono">{{ bank_info.card_number }}</span>
    </div>
    {% endif %}
    {% if bank_info.account_holder %}
    <div class="text-sm text-blue-700 dark:text-blue-300 mb-1">
      <span class="font-medium">به نام:</span> {{ bank_info.account_holder }}
    </div>
    {% endif %}
    {% if bank_info.sheba %}
    <div class="text-sm text-blue-700 dark:text-blue-300">
      <span class="font-medium">شبا:</span>
      <span dir="ltr" class="font-mono text-xs">{{ bank_info.sheba }}</span>
    </div>
    {% endif %}
  </div>
  {% endif %}

  <!-- Manual Form -->
  <div class="rounded-2xl border border-slate-200 bg-white p-6 dark:border-slate-800 dark:bg-slate-950">
    <div class="text-sm font-semibold mb-4 text-slate-700 dark:text-slate-300">📝 درخواست شارژ دستی (پس از کارت به کارت)</div>
    <form method="post" enctype="multipart/form-data" class="space-y-5">{% csrf_token %}
      {% include "partials/form_errors.html" %}
      
      <!-- Amount Field - Highlighted -->
      <div class="space-y-1">
        <label for="{{ form.amount.id_for_label }}" class="block text-sm font-semibold">
          {{ form.amount.label }}
          <span class="text-red-500">*</span>
        </label>
        {{ form.amount }}
        {% if form.amount.help_text %}
        <p class="text-xs text-slate-500 dark:text-slate-400">{{ form.amount.help_text }}</p>
        {% endif %}
        {% if form.amount.errors %}
        <p class="text-xs text-red-500">{{ form.amount.errors.0 }}</p>
        {% endif %}
      </div>

      <!-- Note Field -->
      <div class="space-y-1">
        <label for="{{ form.note.id_for_label }}" class="block text-sm font-medium">
          {{ form.note.label }}
        </label>
        {{ form.note }}
        {% if form.note.help_text %}
        <p class="text-xs text-slate-500 dark:text-slate-400">{{ form.note.help_text }}</p>
        {% endif %}
      </div>

      <!-- Optional Fields Collapsible -->
      <details class="rounded-xl border border-slate-200 p-4 dark:border-slate-700">
        <summary class="cursor-pointer text-sm font-medium text-slate-600 dark:text-slate-300">
          اطلاعات پرداخت (اختیاری)
        </summary>
        <div class="mt-4 space-y-4">
          <!-- Receipt Image -->
          <div class="space-y-1">
            <label for="{{ form.receipt_image.id_for_label }}" class="block text-sm font-medium">
              {{ form.receipt_image.label }}
            </label>
            {{ form.receipt_image }}
            {% if form.receipt_image.help_text %}
            <p class="text-xs text-slate-500 dark:text-slate-400">{{ form.receipt_image.help_text }}</p>
            {% endif %}
          </div>

          <!-- Tracking Code -->
          <div class="space-y-1">
            <label for="{{ form.tracking_code.id_for_label }}" class="block text-sm font-medium">
              {{ form.tracking_code.label }}
            </label>
            {{ form.tracking_code }}
            {% if form.tracking_code.help_text %}
            <p class="text-xs text-slate-500 dark:text-slate-400">{{ form.tracking_code.help_text }}</p>
            {% endif %}
          </div>
        </div>
      </details>

      <button class="w-full rounded-xl bg-slate-700 px-4 py-3 text-white font-semibold hover:bg-slate-800 transition-colors">
        ثبت درخواست شارژ دستی
      </button>
    </form>
  </div>

  <!-- Back Link -->
  <div class="text-center">
    <a href="/wallet/" class="text-sm text-slate-500 hover:text-slate-700 dark:text-slate-400 dark:hover:text-slate-200">
      ← بازگشت به کیف پول
    </a>
  </div>
</div>
{% endblock %}
HTML

  cat > app/templates/invoices/list.html <<'HTML'
{% extends "base.html" %}
{% load jalali_tags %}
{% block title %}فاکتورها{% endblock %}
{% block content %}
<div class="mx-auto max-w-4xl rounded-2xl border border-slate-200 bg-white p-6 dark:border-slate-800 dark:bg-slate-950">
  <h1 class="text-xl font-extrabold mb-4">فاکتورهای من</h1>
  <div class="space-y-3 text-sm">
    {% for i in invoices %}
      <a class="block rounded-2xl border border-slate-200 p-4 hover:bg-slate-50 dark:border-slate-800 dark:hover:bg-slate-900" href="/invoices/{{ i.order.id }}/">
        <div class="flex items-center justify-between gap-3">
          <div dir="ltr" class="font-semibold">{{ i.number }}</div>
          <div><b>{{ i.total }}</b> تومان</div>
          <div class="text-slate-500 dark:text-slate-300">{{ i.issued_at|jalali_datetime }}</div>
        </div>
      </a>
    {% empty %}<div class="text-slate-500 dark:text-slate-300">فاکتوری ندارید.</div>{% endfor %}
  </div>
</div>
{% endblock %}
HTML

  cat > app/templates/invoices/detail.html <<'HTML'
{% extends "base.html" %}
{% load jalali_tags %}
{% block title %}فاکتور{% endblock %}
{% block content %}
<div class="mx-auto max-w-3xl space-y-4">
  <div class="rounded-2xl border border-slate-200 bg-white p-6 dark:border-slate-800 dark:bg-slate-950">
    <div class="flex items-center justify-between gap-3">
      <div>
        <h1 class="text-xl font-extrabold">فاکتور</h1>
        <div class="text-sm text-slate-500 dark:text-slate-300">شماره: <b dir="ltr">{{ invoice.number }}</b></div>
        <div class="text-sm text-slate-500 dark:text-slate-300">تاریخ: {{ invoice.issued_at|jalali_datetime }}</div>
      </div>
      <div class="flex items-center gap-2">
        <a class="rounded-xl border border-emerald-500 bg-emerald-50 px-4 py-2 text-emerald-700 hover:bg-emerald-100 dark:border-emerald-700 dark:bg-emerald-950 dark:text-emerald-300 dark:hover:bg-emerald-900 flex items-center gap-2" href="/invoices/{{ invoice.order.id }}/pdf/">
          <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 10v6m0 0l-3-3m3 3l3-3m2 8H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z"/></svg>
          دانلود PDF
        </a>
        <a class="rounded-xl border border-slate-200 px-4 py-2 hover:bg-slate-50 dark:border-slate-800 dark:hover:bg-slate-900" href="/invoices/">بازگشت</a>
      </div>
    </div>
  </div>
  
  <div class="rounded-2xl border border-slate-200 bg-white dark:border-slate-800 dark:bg-slate-950 overflow-hidden">
    <div class="bg-slate-900 text-white p-6 dark:bg-slate-800">
      <div class="flex items-center justify-between">
        <div>
          <div class="text-xl font-bold">{{ site_settings.brand_name|default:"EduCMS" }}</div>
        </div>
        <div class="text-left">
          <div class="text-sm opacity-75">فاکتور</div>
          <div class="font-mono text-lg">#{{ invoice.number }}</div>
        </div>
      </div>
    </div>
    
    <div class="p-6 space-y-6">
      <div class="grid md:grid-cols-2 gap-6">
        <div>
          <div class="text-xs text-slate-500 dark:text-slate-400 mb-1">صورتحساب برای:</div>
          <div class="font-semibold">{{ invoice.billed_to }}</div>
          <div class="text-sm text-slate-600 dark:text-slate-300">{{ invoice.billed_email }}</div>
        </div>
        <div class="text-left">
          <div class="text-xs text-slate-500 dark:text-slate-400 mb-1">تاریخ صدور:</div>
          <div class="font-semibold">{{ invoice.issued_at|jalali }}</div>
        </div>
      </div>
      
      <div class="border rounded-xl overflow-hidden dark:border-slate-700">
        <table class="w-full text-sm">
          <thead class="bg-slate-50 dark:bg-slate-800">
            <tr>
              <th class="text-right px-4 py-3 font-semibold">شرح</th>
              <th class="text-left px-4 py-3 font-semibold">مبلغ (تومان)</th>
            </tr>
          </thead>
          <tbody>
            <tr class="border-t dark:border-slate-700">
              <td class="px-4 py-3">{{ invoice.item_title }}</td>
              <td class="px-4 py-3 text-left font-mono">{{ invoice.unit_price|floatformat:0 }}</td>
            </tr>
          </tbody>
        </table>
      </div>
      
      <div class="flex justify-end">
        <div class="w-64 space-y-2 text-sm">
          <div class="flex justify-between py-1">
            <span class="text-slate-500 dark:text-slate-400">جمع کل:</span>
            <span class="font-mono">{{ invoice.unit_price|floatformat:0 }}</span>
          </div>
          {% if invoice.discount > 0 %}
          <div class="flex justify-between py-1 text-emerald-600 dark:text-emerald-400">
            <span>تخفیف:</span>
            <span class="font-mono">-{{ invoice.discount|floatformat:0 }}</span>
          </div>
          {% endif %}
          <div class="flex justify-between py-2 border-t dark:border-slate-700 font-bold text-lg">
            <span>مبلغ نهایی:</span>
            <span class="text-emerald-600 dark:text-emerald-400 font-mono">{{ invoice.total|floatformat:0 }} تومان</span>
          </div>
        </div>
      </div>
      
      <div class="text-center pt-4 border-t dark:border-slate-700">
        {% if invoice.order.status == 'paid' %}
          <span class="inline-flex items-center gap-2 px-4 py-2 rounded-full bg-emerald-100 text-emerald-700 dark:bg-emerald-900 dark:text-emerald-300 font-medium">
            <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>
            پرداخت شده
          </span>
        {% else %}
          <span class="inline-flex items-center gap-2 px-4 py-2 rounded-full bg-amber-100 text-amber-700 dark:bg-amber-900 dark:text-amber-300 font-medium">
            <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>
            در انتظار پرداخت
          </span>
        {% endif %}
      </div>
    </div>
  </div>
  
  <div class="text-center text-xs text-slate-400 dark:text-slate-500">
    این فاکتور به صورت الکترونیکی صادر شده و معتبر است.
  </div>
</div>
{% endblock %}
HTML

  cat > app/templates/tickets/list.html <<'HTML'
{% extends "base.html" %}
{% load jalali_tags %}
{% block title %}تیکت‌ها{% endblock %}
{% block content %}
<div class="mx-auto max-w-4xl space-y-4">
  <div class="rounded-2xl border border-slate-200 bg-white p-6 dark:border-slate-800 dark:bg-slate-950 flex items-center justify-between">
    <h1 class="text-xl font-extrabold">تیکت‌ها</h1>
    <a class="rounded-xl bg-slate-900 px-4 py-2 text-white hover:opacity-95 dark:bg-white dark:text-slate-900" href="/tickets/new/">ثبت تیکت</a>
  </div>
  <div class="rounded-2xl border border-slate-200 bg-white p-6 dark:border-slate-800 dark:bg-slate-950">
    <div class="space-y-3 text-sm">
      {% for t in tickets %}
        <a class="block rounded-2xl border border-slate-200 p-4 hover:bg-slate-50 dark:border-slate-800 dark:hover:bg-slate-900" href="/tickets/{{ t.id }}/">
          <div class="flex items-center justify-between mb-2">
            <div class="font-semibold">{{ t.subject }}</div>
            <div class="flex items-center gap-2">
              {% if t.priority == 'high' %}
                <span class="px-2 py-0.5 rounded-full text-xs bg-rose-100 text-rose-700 dark:bg-rose-900 dark:text-rose-300">فوری</span>
              {% elif t.priority == 'medium' %}
                <span class="px-2 py-0.5 rounded-full text-xs bg-amber-100 text-amber-700 dark:bg-amber-900 dark:text-amber-300">متوسط</span>
              {% else %}
                <span class="px-2 py-0.5 rounded-full text-xs bg-slate-100 text-slate-600 dark:bg-slate-800 dark:text-slate-400">عادی</span>
              {% endif %}
              <span class="px-2 py-0.5 rounded-full text-xs {% if t.status == 'open' %}bg-blue-100 text-blue-700 dark:bg-blue-900 dark:text-blue-300{% elif t.status == 'answered' %}bg-emerald-100 text-emerald-700 dark:bg-emerald-900 dark:text-emerald-300{% else %}bg-slate-100 text-slate-600 dark:bg-slate-800 dark:text-slate-400{% endif %}">{{ t.get_status_display }}</span>
            </div>
          </div>
          <div class="flex items-center gap-3 text-xs text-slate-500 dark:text-slate-400">
            {% if t.department %}<span>📁 {{ t.department.name }}</span>{% endif %}
            <span>{{ t.created_at|jalali_datetime }}</span>
          </div>
        </a>
      {% empty %}<div class="text-slate-500 dark:text-slate-300">تیکتی ندارید.</div>{% endfor %}
    </div>
  </div>
</div>
{% endblock %}
HTML

  cat > app/templates/tickets/create.html <<'HTML'
{% extends "base.html" %}
{% block title %}ثبت تیکت{% endblock %}
{% block content %}
<div class="mx-auto max-w-2xl rounded-2xl border border-slate-200 bg-white p-6 dark:border-slate-800 dark:bg-slate-950">
  <h1 class="text-xl font-extrabold mb-4">ثبت تیکت</h1>
  <form method="post" enctype="multipart/form-data" class="space-y-4">{% csrf_token %}
    {% include "partials/form_errors.html" %}
    {% for field in form %}{% include "partials/field.html" with field=field %}{% endfor %}
    <button class="rounded-xl bg-slate-900 px-4 py-2 text-white hover:opacity-95 dark:bg-white dark:text-slate-900">ثبت</button>
  </form>
</div>
{% endblock %}
HTML

  cat > app/templates/tickets/detail.html <<'HTML'
{% extends "base.html" %}
{% load jalali_tags %}
{% block title %}تیکت{% endblock %}
{% block content %}
<div class="mx-auto max-w-4xl space-y-4">
  <div class="rounded-2xl border border-slate-200 bg-white p-6 dark:border-slate-800 dark:bg-slate-950">
    <div class="flex items-center justify-between gap-3">
      <div>
        <h1 class="text-xl font-extrabold">{{ ticket.subject }}</h1>
        <div class="flex items-center gap-2 mt-1">
          {% if ticket.department %}
            <span class="text-xs px-2 py-0.5 rounded-full bg-slate-100 text-slate-600 dark:bg-slate-800 dark:text-slate-400">📁 {{ ticket.department.name }}</span>
          {% endif %}
          <span class="text-xs px-2 py-0.5 rounded-full {% if ticket.status == 'open' %}bg-blue-100 text-blue-700 dark:bg-blue-900 dark:text-blue-300{% elif ticket.status == 'answered' %}bg-emerald-100 text-emerald-700 dark:bg-emerald-900 dark:text-emerald-300{% else %}bg-slate-100 text-slate-600 dark:bg-slate-800 dark:text-slate-400{% endif %}">{{ ticket.get_status_display }}</span>
          {% if ticket.priority == 'high' %}
            <span class="text-xs px-2 py-0.5 rounded-full bg-rose-100 text-rose-700 dark:bg-rose-900 dark:text-rose-300">فوری</span>
          {% endif %}
        </div>
        <div class="text-xs text-slate-500 dark:text-slate-400 mt-2">{{ ticket.created_at|jalali_datetime }}</div>
      </div>
      <a class="rounded-xl border border-slate-200 px-4 py-2 hover:bg-slate-50 dark:border-slate-800 dark:hover:bg-slate-900" href="/tickets/">بازگشت</a>
    </div>
    <div class="mt-4 rounded-2xl border border-slate-200 bg-slate-50 p-4 dark:border-slate-800 dark:bg-slate-900/40 whitespace-pre-line">{{ ticket.description }}</div>
  </div>

  <div class="rounded-2xl border border-slate-200 bg-white p-6 dark:border-slate-800 dark:bg-slate-950">
    <h2 class="font-bold mb-3">پاسخ‌ها</h2>
    <div class="space-y-2 text-sm">
      {% for r in ticket.replies.all %}
        <div class="rounded-xl border border-slate-200 p-3 dark:border-slate-800 whitespace-pre-line">{{ r.message }}</div>
      {% empty %}<div class="text-slate-500 dark:text-slate-300">پاسخی ثبت نشده.</div>{% endfor %}
    </div>
    <hr class="my-5 border-slate-200 dark:border-slate-800">
    <h3 class="font-bold mb-3">ارسال پاسخ</h3>
    <form method="post" enctype="multipart/form-data" class="space-y-4">{% csrf_token %}
      {% include "partials/form_errors.html" %}
      {% for field in form %}{% include "partials/field.html" with field=field %}{% endfor %}
      <button class="rounded-xl bg-slate-900 px-4 py-2 text-white hover:opacity-95 dark:bg-white dark:text-slate-900">ارسال</button>
    </form>
  </div>
</div>
{% endblock %}
HTML

  cat > app/templates/settings/admin_path.html <<'HTML'
{% extends "base.html" %}
{% block title %}مسیر ادمین{% endblock %}
{% block content %}
<div class="mx-auto max-w-xl rounded-2xl border border-slate-200 bg-white p-6 dark:border-slate-800 dark:bg-slate-950">
  <h1 class="text-xl font-extrabold mb-2">تغییر مسیر ادمین</h1>
  <div class="text-sm text-slate-500 dark:text-slate-300 mb-4">مسیر فعلی: <b dir="ltr">/{{ current }}/</b></div>
  <form method="post" class="space-y-4">{% csrf_token %}
    {% include "partials/form_errors.html" %}
    {% for field in form %}{% include "partials/field.html" with field=field %}{% endfor %}
    <button class="rounded-xl bg-slate-900 px-4 py-2 text-white hover:opacity-95 dark:bg-white dark:text-slate-900">ذخیره</button>
  </form>
</div>
{% endblock %}
HTML

  cat > app/templates/settings/admin_account.html <<'HTML'
{% extends "admin/base_site.html" %}
{% block content %}
<div style="max-width:720px">
  <h1>تغییر نام کاربری و رمز ادمین</h1>
  <form method="post">{% csrf_token %}{{ form.as_p }}<button type="submit" class="default">ذخیره</button></form>
</div>
{% endblock %}
HTML

  cat > app/templates/settings/backup.html <<'HTML'
{% extends "admin/base_site.html" %}
{% load jalali_tags %}
{% block content %}
<style>
  .backup-container { max-width: 900px; font-family: Vazirmatn, sans-serif; }
  .backup-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 20px; }
  .backup-btn { background: #0c4a6e; color: white; padding: 10px 20px; border: none; border-radius: 8px; cursor: pointer; font-family: inherit; }
  .backup-btn:hover { background: #075985; }
  .backup-btn-danger { background: #dc2626; }
  .backup-btn-danger:hover { background: #b91c1c; }
  .backup-btn-success { background: #059669; }
  .backup-btn-success:hover { background: #047857; }
  .backup-table { width: 100%; border-collapse: collapse; background: white; border-radius: 12px; overflow: hidden; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }
  .backup-table th, .backup-table td { padding: 12px 16px; text-align: right; border-bottom: 1px solid #e5e7eb; }
  .backup-table th { background: #f8fafc; font-weight: 600; }
  .backup-table tr:last-child td { border-bottom: none; }
  .backup-actions { display: flex; gap: 8px; justify-content: flex-end; }
  .backup-actions form { display: inline; }
  .backup-small-btn { padding: 6px 12px; font-size: 12px; border-radius: 6px; }
  .backup-warning { background: #fef3c7; border: 1px solid #f59e0b; padding: 16px; border-radius: 8px; margin-bottom: 20px; }
  .backup-empty { text-align: center; padding: 40px; color: #6b7280; }
  .restore-confirm { display: inline-flex; gap: 4px; align-items: center; }
  .restore-input { padding: 6px 8px; border: 1px solid #d1d5db; border-radius: 4px; width: 60px; font-size: 12px; }
</style>
<div class="backup-container">
  <div class="backup-header">
    <h1 style="margin:0;">🗄️ مدیریت بکاپ</h1>
    <form method="post" action="{% url 'backup_create' %}">
      {% csrf_token %}
      <button type="submit" class="backup-btn backup-btn-success">+ ایجاد بکاپ جدید</button>
    </form>
  </div>

  <div class="backup-warning">
    ⚠️ <strong>هشدار:</strong> ریستور کردن بکاپ، تمام داده‌های فعلی را پاک می‌کند. قبل از ریستور، یک بکاپ جدید بگیرید.
  </div>

  {% if backups %}
  <table class="backup-table">
    <thead>
      <tr>
        <th>نام فایل</th>
        <th>حجم (MB)</th>
        <th>تاریخ</th>
        <th>عملیات</th>
      </tr>
    </thead>
    <tbody>
      {% for b in backups %}
      <tr>
        <td><code>{{ b.name }}</code></td>
        <td>{{ b.size }}</td>
        <td>{{ b.date|jalali_datetime }}</td>
        <td>
          <div class="backup-actions">
            <a href="{% url 'backup_download' b.name %}" class="backup-btn backup-small-btn">دانلود</a>
            
            <form method="post" action="{% url 'backup_restore' b.name %}" class="restore-confirm">
              {% csrf_token %}
              <input type="text" name="confirm" placeholder="YES" class="restore-input">
              <button type="submit" class="backup-btn backup-small-btn" onclick="return confirm('آیا مطمئنید؟ YES تایپ کرده‌اید؟');">ریستور</button>
            </form>
            
            <form method="post" action="{% url 'backup_delete' b.name %}" onsubmit="return confirm('آیا از حذف این بکاپ مطمئنید؟');">
              {% csrf_token %}
              <button type="submit" class="backup-btn backup-btn-danger backup-small-btn">حذف</button>
            </form>
          </div>
        </td>
      </tr>
      {% endfor %}
    </tbody>
  </table>
  {% else %}
  <div class="backup-empty">
    <p>هیچ بکاپی وجود ندارد.</p>
    <p>برای ایجاد بکاپ، روی دکمه "ایجاد بکاپ جدید" کلیک کنید.</p>
  </div>
  {% endif %}
</div>
{% endblock %}
HTML

  # صفحه ابزارهای مدیریت (جدا از admin اصلی)
  cat > app/templates/settings/tools.html <<'HTML'
{% extends "base.html" %}
{% block title %}ابزارهای مدیریت{% endblock %}
{% block content %}
<div class="mx-auto max-w-4xl">
  <div class="rounded-2xl border border-slate-200 bg-white p-6 dark:border-slate-800 dark:bg-slate-950 mb-6">
    <h1 class="text-2xl font-extrabold mb-2">🛠️ ابزارهای مدیریت</h1>
    <p class="text-slate-500 dark:text-slate-400">دسترسی سریع به ابزارهای مدیریتی سایت</p>
  </div>
  
  <div class="grid md:grid-cols-2 gap-4">
    <a href="/admin/" class="block rounded-2xl border border-slate-200 bg-white p-6 hover:border-slate-300 hover:shadow-md transition-all dark:border-slate-800 dark:bg-slate-950 dark:hover:border-slate-700">
      <div class="text-3xl mb-3">⚙️</div>
      <h3 class="font-bold text-lg mb-1">پنل ادمین Django</h3>
      <p class="text-sm text-slate-500 dark:text-slate-400">مدیریت کاربران، دوره‌ها، تنظیمات و...</p>
    </a>
    
    <a href="/admin/backup/" class="block rounded-2xl border border-emerald-200 bg-emerald-50 p-6 hover:border-emerald-300 hover:shadow-md transition-all dark:border-emerald-900 dark:bg-emerald-950 dark:hover:border-emerald-800">
      <div class="text-3xl mb-3">🗄️</div>
      <h3 class="font-bold text-lg mb-1 text-emerald-700 dark:text-emerald-300">مدیریت بکاپ</h3>
      <p class="text-sm text-emerald-600 dark:text-emerald-400">ایجاد، دانلود و بازیابی بکاپ دیتابیس</p>
    </a>
    
    <a href="/admin/account/" class="block rounded-2xl border border-blue-200 bg-blue-50 p-6 hover:border-blue-300 hover:shadow-md transition-all dark:border-blue-900 dark:bg-blue-950 dark:hover:border-blue-800">
      <div class="text-3xl mb-3">👤</div>
      <h3 class="font-bold text-lg mb-1 text-blue-700 dark:text-blue-300">تغییر رمز ادمین</h3>
      <p class="text-sm text-blue-600 dark:text-blue-400">تغییر نام کاربری و رمز عبور ادمین</p>
    </a>
    
    <a href="/panel/admin-path/" class="block rounded-2xl border border-purple-200 bg-purple-50 p-6 hover:border-purple-300 hover:shadow-md transition-all dark:border-purple-900 dark:bg-purple-950 dark:hover:border-purple-800">
      <div class="text-3xl mb-3">🔗</div>
      <h3 class="font-bold text-lg mb-1 text-purple-700 dark:text-purple-300">تغییر مسیر ادمین</h3>
      <p class="text-sm text-purple-600 dark:text-purple-400">تغییر آدرس دسترسی به پنل مدیریت</p>
    </a>
  </div>
</div>
{% endblock %}
HTML

  cat > app/entrypoint.sh <<'SH'
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

# If courses tables were created previously (but migrations weren't recorded), fake courses migrations to avoid 'already exists'
python - <<'PYCHECK'
import os, sys
import MySQLdb
cfg = {
    'host': os.getenv('DB_HOST', 'db'),
    'user': os.getenv('DB_USER'),
    'passwd': os.getenv('DB_PASSWORD'),
    'db': os.getenv('DB_NAME'),
    'port': int(os.getenv('DB_PORT', 3306))
}
try:
    conn = MySQLdb.connect(**cfg)
    cur = conn.cursor()
    cur.execute("SHOW TABLES LIKE 'courses_coursecategory'")
    sys.exit(0 if cur.fetchone() else 1)
except Exception:
    sys.exit(1)
PYCHECK


python manage.py migrate --noinput --fake-initial

echo "Fixing database schema (adding missing columns/tables)..."
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

def safe_exec(cursor, sql, msg=None):
    try:
        cursor.execute(sql)
        if msg:
            print(msg)
        return True
    except Exception as e:
        if msg:
            print(f"{msg} (skipped): {e}")
        return False

try:
    conn = MySQLdb.connect(**db_config)
    cursor = conn.cursor()

    # Add extra_data to accounts_userprofile
    if table_exists(cursor, 'accounts_userprofile'):
        if not column_exists(cursor, 'accounts_userprofile', 'extra_data'):
            safe_exec(cursor, "ALTER TABLE accounts_userprofile ADD COLUMN extra_data JSON DEFAULT NULL",
                      "Added extra_data column to accounts_userprofile")
        # Add QR Code fields
        if not column_exists(cursor, 'accounts_userprofile', 'qr_enabled'):
            safe_exec(cursor, "ALTER TABLE accounts_userprofile ADD COLUMN qr_enabled TINYINT(1) DEFAULT 1",
                      "Added qr_enabled column to accounts_userprofile")
        if not column_exists(cursor, 'accounts_userprofile', 'qr_token'):
            safe_exec(cursor, "ALTER TABLE accounts_userprofile ADD COLUMN qr_token VARCHAR(64) NULL UNIQUE",
                      "Added qr_token column to accounts_userprofile")
        if not column_exists(cursor, 'accounts_userprofile', 'qr_show_name'):
            safe_exec(cursor, "ALTER TABLE accounts_userprofile ADD COLUMN qr_show_name TINYINT(1) DEFAULT 1",
                      "Added qr_show_name column to accounts_userprofile")
        if not column_exists(cursor, 'accounts_userprofile', 'qr_show_email'):
            safe_exec(cursor, "ALTER TABLE accounts_userprofile ADD COLUMN qr_show_email TINYINT(1) DEFAULT 1",
                      "Added qr_show_email column to accounts_userprofile")
        if not column_exists(cursor, 'accounts_userprofile', 'qr_show_join_date'):
            safe_exec(cursor, "ALTER TABLE accounts_userprofile ADD COLUMN qr_show_join_date TINYINT(1) DEFAULT 1",
                      "Added qr_show_join_date column to accounts_userprofile")
        if not column_exists(cursor, 'accounts_userprofile', 'qr_show_courses'):
            safe_exec(cursor, "ALTER TABLE accounts_userprofile ADD COLUMN qr_show_courses TINYINT(1) DEFAULT 1",
                      "Added qr_show_courses column to accounts_userprofile")
        if not column_exists(cursor, 'accounts_userprofile', 'qr_show_progress'):
            safe_exec(cursor, "ALTER TABLE accounts_userprofile ADD COLUMN qr_show_progress TINYINT(1) DEFAULT 1",
                      "Added qr_show_progress column to accounts_userprofile")
        if not column_exists(cursor, 'accounts_userprofile', 'qr_show_stats'):
            safe_exec(cursor, "ALTER TABLE accounts_userprofile ADD COLUMN qr_show_stats TINYINT(1) DEFAULT 1",
                      "Added qr_show_stats column to accounts_userprofile")
        if not column_exists(cursor, 'accounts_userprofile', 'qr_admin_disabled'):
            safe_exec(cursor, "ALTER TABLE accounts_userprofile ADD COLUMN qr_admin_disabled TINYINT(1) DEFAULT 0",
                      "Added qr_admin_disabled column to accounts_userprofile")

    # Add allow_profile_edit / allow_security_edit / qr_feature_enabled to settingsapp_sitesetting
    if table_exists(cursor, 'settingsapp_sitesetting'):
        if not column_exists(cursor, 'settingsapp_sitesetting', 'allow_profile_edit'):
            safe_exec(cursor, "ALTER TABLE settingsapp_sitesetting ADD COLUMN allow_profile_edit TINYINT(1) DEFAULT 1",
                      "Added allow_profile_edit column to settingsapp_sitesetting")
        if not column_exists(cursor, 'settingsapp_sitesetting', 'allow_security_edit'):
            safe_exec(cursor, "ALTER TABLE settingsapp_sitesetting ADD COLUMN allow_security_edit TINYINT(1) DEFAULT 1",
                      "Added allow_security_edit column to settingsapp_sitesetting")
        if not column_exists(cursor, 'settingsapp_sitesetting', 'qr_feature_enabled'):
            safe_exec(cursor, "ALTER TABLE settingsapp_sitesetting ADD COLUMN qr_feature_enabled TINYINT(1) DEFAULT 1",
                      "Added qr_feature_enabled column to settingsapp_sitesetting")
        if not column_exists(cursor, 'settingsapp_sitesetting', 'ticket_department_required'):
            safe_exec(cursor, "ALTER TABLE settingsapp_sitesetting ADD COLUMN ticket_department_required TINYINT(1) DEFAULT 1",
                      "Added ticket_department_required column to settingsapp_sitesetting")
        if not column_exists(cursor, 'settingsapp_sitesetting', 'calendar_type'):
            safe_exec(cursor, "ALTER TABLE settingsapp_sitesetting ADD COLUMN calendar_type VARCHAR(10) NOT NULL DEFAULT 'jalali'",
                      "Added calendar_type column to settingsapp_sitesetting")

    # Add ticket_department_mode to accounts_userprofile
    if table_exists(cursor, 'accounts_userprofile'):
        if not column_exists(cursor, 'accounts_userprofile', 'ticket_department_mode'):
            safe_exec(cursor, "ALTER TABLE accounts_userprofile ADD COLUMN ticket_department_mode VARCHAR(10) NOT NULL DEFAULT 'default'",
                      "Added ticket_department_mode column to accounts_userprofile")

    # -------------------------
    # Tickets schema - Department and new fields
    # -------------------------
    if not table_exists(cursor, 'tickets_department'):
        safe_exec(cursor, '''
            CREATE TABLE tickets_department (
                id CHAR(36) PRIMARY KEY,
                name VARCHAR(100) NOT NULL,
                description TEXT,
                is_active TINYINT(1) NOT NULL DEFAULT 1,
                `order` INT UNSIGNED NOT NULL DEFAULT 0,
                created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
            ) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci
        ''', "Created tickets_department table")
        # Insert default departments
        import uuid
        safe_exec(cursor, f"INSERT INTO tickets_department (id, name, description, is_active, `order`) VALUES ('{uuid.uuid4()}', 'پشتیبانی فنی', 'مشکلات فنی و باگ‌ها', 1, 1)", "Added default department: پشتیبانی فنی")
        safe_exec(cursor, f"INSERT INTO tickets_department (id, name, description, is_active, `order`) VALUES ('{uuid.uuid4()}', 'مالی', 'سوالات مالی و پرداخت', 1, 2)", "Added default department: مالی")
        safe_exec(cursor, f"INSERT INTO tickets_department (id, name, description, is_active, `order`) VALUES ('{uuid.uuid4()}', 'پیشنهادات', 'پیشنهادات و انتقادات', 1, 3)", "Added default department: پیشنهادات")

    if table_exists(cursor, 'tickets_ticket'):
        if not column_exists(cursor, 'tickets_ticket', 'department_id'):
            safe_exec(cursor, "ALTER TABLE tickets_ticket ADD COLUMN department_id CHAR(36) NULL",
                      "Added department_id column to tickets_ticket")
            safe_exec(cursor, "ALTER TABLE tickets_ticket ADD CONSTRAINT fk_ticket_department FOREIGN KEY (department_id) REFERENCES tickets_department(id) ON DELETE SET NULL",
                      "Added foreign key for department_id")
        if not column_exists(cursor, 'tickets_ticket', 'priority'):
            safe_exec(cursor, "ALTER TABLE tickets_ticket ADD COLUMN priority VARCHAR(20) NOT NULL DEFAULT 'medium'",
                      "Added priority column to tickets_ticket")

    # Create settingsapp_registrationfield table if not exists
    if not table_exists(cursor, 'settingsapp_registrationfield'):
        safe_exec(cursor, '''
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
        ''', "Created settingsapp_registrationfield table")

    # -------------------------
    # Courses schema repair (no data loss)
    # -------------------------
    if not table_exists(cursor, 'courses_coursecategory'):
        safe_exec(cursor, '''
            CREATE TABLE courses_coursecategory (
                id BIGINT AUTO_INCREMENT PRIMARY KEY,
                title VARCHAR(200) NOT NULL,
                slug VARCHAR(220) NOT NULL UNIQUE,
                is_active TINYINT(1) NOT NULL DEFAULT 1,
                created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
                updated_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6)
            ) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci
        ''', "Created courses_coursecategory table")

    # Ensure expected columns exist on existing courses_coursecategory (no data loss)
    if table_exists(cursor, 'courses_coursecategory') and not column_exists(cursor, 'courses_coursecategory', 'created_at'):
        safe_exec(cursor, "ALTER TABLE courses_coursecategory ADD COLUMN created_at DATETIME(6) NULL",
                  "Added created_at to courses_coursecategory (nullable)")
        safe_exec(cursor, "UPDATE courses_coursecategory SET created_at = COALESCE(created_at, NOW(6))",
                  "Backfilled courses_coursecategory.created_at")
        safe_exec(cursor, "ALTER TABLE courses_coursecategory MODIFY COLUMN created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)",
                  "Hardened courses_coursecategory.created_at")
    if table_exists(cursor, 'courses_coursecategory') and not column_exists(cursor, 'courses_coursecategory', 'updated_at'):
        safe_exec(cursor, "ALTER TABLE courses_coursecategory ADD COLUMN updated_at DATETIME(6) NULL",
                  "Added updated_at to courses_coursecategory (nullable)")
        safe_exec(cursor, "UPDATE courses_coursecategory SET updated_at = COALESCE(updated_at, created_at, NOW(6))",
                  "Backfilled courses_coursecategory.updated_at")
        safe_exec(cursor, "ALTER TABLE courses_coursecategory MODIFY COLUMN updated_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6)",
                  "Hardened courses_coursecategory.updated_at")

    if table_exists(cursor, 'courses_course') and not column_exists(cursor, 'courses_course', 'category_id'):
        safe_exec(cursor, "ALTER TABLE courses_course ADD COLUMN category_id BIGINT NULL",
                  "Added category_id to courses_course")
        safe_exec(cursor, "CREATE INDEX courses_course_category_id_idx ON courses_course(category_id)",
                  "Added index on courses_course.category_id")
        safe_exec(cursor, '''
            ALTER TABLE courses_course
              ADD CONSTRAINT courses_course_category_id_fk
              FOREIGN KEY (category_id) REFERENCES courses_coursecategory(id)
              ON DELETE SET NULL
        ''', "Added FK for courses_course.category_id")

    course_id_type = None
    course_id_extra = ""
    if table_exists(cursor, 'courses_course'):
        cursor.execute("SHOW COLUMNS FROM courses_course LIKE 'id'")
        row = cursor.fetchone()
        if row:
            course_id_type = row[1]  # e.g. 'char(32)' or 'binary(16)'
            t = (course_id_type or '').lower()
            if t.startswith('char') or t.startswith('varchar'):
                course_id_extra = " CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"

    if course_id_type and not table_exists(cursor, 'courses_coursesection'):
        safe_exec(cursor, f'''
            CREATE TABLE courses_coursesection (
                id BIGINT AUTO_INCREMENT PRIMARY KEY,
                title VARCHAR(200) NOT NULL,
                position INT UNSIGNED NOT NULL DEFAULT 0,
                created_at DATETIME(6) NOT NULL,
                course_id {course_id_type}{course_id_extra} NOT NULL,
                KEY courses_coursesection_course_id_idx (course_id)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
        ''', "Created courses_coursesection table")
        safe_exec(cursor, '''
            ALTER TABLE courses_coursesection
              ADD CONSTRAINT courses_coursesection_course_id_fk
              FOREIGN KEY (course_id) REFERENCES courses_course(id)
              ON DELETE CASCADE
        ''', "Added FK for courses_coursesection.course_id")

    # Ensure expected columns exist on existing courses_coursesection (no data loss)
    if table_exists(cursor, 'courses_coursesection') and not column_exists(cursor, 'courses_coursesection', 'position'):
        safe_exec(cursor, "ALTER TABLE courses_coursesection ADD COLUMN position INT UNSIGNED NOT NULL DEFAULT 0",
                  "Added position to courses_coursesection")
    if table_exists(cursor, 'courses_coursesection') and not column_exists(cursor, 'courses_coursesection', 'created_at'):
        safe_exec(cursor, "ALTER TABLE courses_coursesection ADD COLUMN created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)",
                  "Added created_at to courses_coursesection")

    # Ensure expected columns exist on existing courses_lesson (no data loss)
    if table_exists(cursor, 'courses_lesson') and not column_exists(cursor, 'courses_lesson', 'position'):
        safe_exec(cursor, "ALTER TABLE courses_lesson ADD COLUMN position INT UNSIGNED NOT NULL DEFAULT 0",
                  "Added position to courses_lesson")
    if table_exists(cursor, 'courses_lesson') and not column_exists(cursor, 'courses_lesson', 'is_free'):
        safe_exec(cursor, "ALTER TABLE courses_lesson ADD COLUMN is_free TINYINT(1) NOT NULL DEFAULT 0",
                  "Added is_free to courses_lesson")
    if table_exists(cursor, 'courses_lesson') and not column_exists(cursor, 'courses_lesson', 'section_id'):
        safe_exec(cursor, "ALTER TABLE courses_lesson ADD COLUMN section_id BIGINT NULL",
                  "Added section_id to courses_lesson")
    if table_exists(cursor, 'courses_lesson') and not column_exists(cursor, 'courses_lesson', 'created_at'):
        safe_exec(cursor, "ALTER TABLE courses_lesson ADD COLUMN created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)",
                  "Added created_at to courses_lesson")

    if course_id_type and not table_exists(cursor, 'courses_lesson'):
        safe_exec(cursor, f'''
            CREATE TABLE courses_lesson (
                id BIGINT AUTO_INCREMENT PRIMARY KEY,
                title VARCHAR(220) NOT NULL,
                position INT UNSIGNED NOT NULL DEFAULT 0,
                is_free TINYINT(1) NOT NULL DEFAULT 0,
                content LONGTEXT NULL,
                video VARCHAR(255) NULL,
                created_at DATETIME(6) NOT NULL,
                course_id {course_id_type}{course_id_extra} NOT NULL,
                section_id BIGINT NULL,
                KEY courses_lesson_course_id_idx (course_id),
                KEY courses_lesson_section_id_idx (section_id)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
        ''', "Created courses_lesson table")
        safe_exec(cursor, '''
            ALTER TABLE courses_lesson
              ADD CONSTRAINT courses_lesson_course_id_fk
              FOREIGN KEY (course_id) REFERENCES courses_course(id)
              ON DELETE CASCADE
        ''', "Added FK for courses_lesson.course_id")
        safe_exec(cursor, '''
            ALTER TABLE courses_lesson
              ADD CONSTRAINT courses_lesson_section_id_fk
              FOREIGN KEY (section_id) REFERENCES courses_coursesection(id)
              ON DELETE SET NULL
        ''', "Added FK for courses_lesson.section_id")

    conn.commit()
    cursor.close()
    conn.close()
    print("Database schema fix completed.")
except Exception as e:
    print(f"Database schema fix error (may be ok): {e}")
PYFIX

echo "Creating Payment Gateway and IP Security tables..."
python manage.py shell <<'PYPAY'
import os
import MySQLdb

db_config = {
    'host': os.getenv('DB_HOST', 'db'),
    'user': os.getenv('DB_USER'),
    'passwd': os.getenv('DB_PASSWORD'),
    'db': os.getenv('DB_NAME'),
    'port': int(os.getenv('DB_PORT', 3306))
}

def table_exists(cursor, table):
    cursor.execute(f"SHOW TABLES LIKE '{table}'")
    return cursor.fetchone() is not None

def column_exists(cursor, table, column):
    cursor.execute(f"SHOW COLUMNS FROM {table} LIKE '{column}'")
    return cursor.fetchone() is not None

def safe_exec(cursor, sql, msg=None):
    try:
        cursor.execute(sql)
        if msg:
            print(msg)
        return True
    except Exception as e:
        if msg:
            print(f"{msg} (skipped): {e}")
        return False

try:
    conn = MySQLdb.connect(**db_config)
    cursor = conn.cursor()

    # ===== PAYMENT GATEWAY =====
    if not table_exists(cursor, 'payments_paymentgateway'):
        safe_exec(cursor, '''
            CREATE TABLE payments_paymentgateway (
                id BIGINT AUTO_INCREMENT PRIMARY KEY,
                gateway_type VARCHAR(20) NOT NULL UNIQUE,
                merchant_id VARCHAR(100) NOT NULL,
                is_active TINYINT(1) NOT NULL DEFAULT 0,
                is_sandbox TINYINT(1) NOT NULL DEFAULT 0,
                priority INT UNSIGNED NOT NULL DEFAULT 0,
                description VARCHAR(200) DEFAULT '',
                created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
                updated_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
        ''', "Created payments_paymentgateway table")
    conn.commit()

    # ===== ONLINE PAYMENT =====
    # Check if table exists with wrong schema and drop it
    if table_exists(cursor, 'payments_onlinepayment'):
        cursor.execute("SHOW COLUMNS FROM payments_onlinepayment LIKE 'user_id'")
        row = cursor.fetchone()
        if row:
            col_type = (row[1] or '').lower()
            # If user_id is NOT BIGINT, drop and recreate
            if 'bigint' not in col_type:
                print("Dropping payments_onlinepayment table (wrong user_id type, should be BIGINT)...")
                safe_exec(cursor, "DROP TABLE payments_onlinepayment", "Dropped payments_onlinepayment")
                conn.commit()
    
    if not table_exists(cursor, 'payments_onlinepayment'):
        safe_exec(cursor, '''
            CREATE TABLE payments_onlinepayment (
                id CHAR(36) PRIMARY KEY,
                user_id BIGINT NOT NULL,
                gateway_id BIGINT NOT NULL,
                payment_type VARCHAR(10) NOT NULL DEFAULT 'order',
                amount INT UNSIGNED NOT NULL DEFAULT 0,
                order_id CHAR(36) NULL,
                authority VARCHAR(100) DEFAULT '',
                ref_id VARCHAR(100) DEFAULT '',
                status VARCHAR(20) NOT NULL DEFAULT 'pending',
                gateway_response JSON DEFAULT NULL,
                created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
                paid_at DATETIME(6) NULL,
                KEY idx_onlinepayment_user (user_id),
                KEY idx_onlinepayment_gateway (gateway_id),
                KEY idx_onlinepayment_order (order_id),
                KEY idx_onlinepayment_authority (authority)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
        ''', "Created payments_onlinepayment table")
    conn.commit()

    # ===== IP SECURITY SETTING =====
    if not table_exists(cursor, 'settingsapp_ipsecuritysetting'):
        safe_exec(cursor, '''
            CREATE TABLE settingsapp_ipsecuritysetting (
                id BIGINT AUTO_INCREMENT PRIMARY KEY,
                is_enabled TINYINT(1) NOT NULL DEFAULT 1,
                max_attempts INT UNSIGNED NOT NULL DEFAULT 5,
                block_duration_type VARCHAR(10) NOT NULL DEFAULT 'minutes',
                block_duration_value INT UNSIGNED NOT NULL DEFAULT 30,
                reset_attempts_after INT UNSIGNED NOT NULL DEFAULT 60,
                updated_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
        ''', "Created settingsapp_ipsecuritysetting table")
        conn.commit()
        # Insert default setting
        safe_exec(cursor, '''
            INSERT INTO settingsapp_ipsecuritysetting (id, is_enabled, max_attempts, block_duration_type, block_duration_value, reset_attempts_after)
            VALUES (1, 1, 5, 'minutes', 30, 60)
        ''', "Inserted default IP security settings")
    conn.commit()

    # ===== IP WHITELIST =====
    if not table_exists(cursor, 'settingsapp_ipwhitelist'):
        safe_exec(cursor, '''
            CREATE TABLE settingsapp_ipwhitelist (
                id BIGINT AUTO_INCREMENT PRIMARY KEY,
                ip_address VARCHAR(39) NOT NULL UNIQUE,
                description VARCHAR(200) DEFAULT '',
                created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
        ''', "Created settingsapp_ipwhitelist table")
    conn.commit()

    # ===== IP BLACKLIST =====
    if not table_exists(cursor, 'settingsapp_ipblacklist'):
        safe_exec(cursor, '''
            CREATE TABLE settingsapp_ipblacklist (
                id BIGINT AUTO_INCREMENT PRIMARY KEY,
                ip_address VARCHAR(39) NOT NULL,
                block_type VARCHAR(10) NOT NULL DEFAULT 'auto',
                reason VARCHAR(300) DEFAULT '',
                is_permanent TINYINT(1) NOT NULL DEFAULT 0,
                blocked_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
                expires_at DATETIME(6) NULL,
                failed_attempts INT UNSIGNED NOT NULL DEFAULT 0,
                KEY idx_ipblacklist_ip (ip_address),
                KEY idx_ipblacklist_expires (expires_at)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
        ''', "Created settingsapp_ipblacklist table")
    conn.commit()

    # ===== LOGIN ATTEMPT =====
    if not table_exists(cursor, 'settingsapp_loginattempt'):
        safe_exec(cursor, '''
            CREATE TABLE settingsapp_loginattempt (
                id BIGINT AUTO_INCREMENT PRIMARY KEY,
                ip_address VARCHAR(39) NOT NULL,
                username VARCHAR(150) DEFAULT '',
                is_successful TINYINT(1) NOT NULL DEFAULT 0,
                user_agent TEXT,
                attempted_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
                KEY idx_loginattempt_ip (ip_address),
                KEY idx_loginattempt_at (attempted_at)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
        ''', "Created settingsapp_loginattempt table")
    conn.commit()

    cursor.close()
    conn.close()
    print("Payment Gateway and IP Security tables created successfully.")
except Exception as e:
    print(f"Payment/IP Security tables error (may be ok): {e}")
PYPAY

echo "Fixing BankTransferSetting schema..."
python manage.py shell <<'PYBANK'
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

def safe_exec(cursor, sql, msg=None):
    try:
        cursor.execute(sql)
        if msg:
            print(msg)
        return True
    except Exception as e:
        if msg:
            print(f"{msg} (skipped): {e}")
        return False

try:
    conn = MySQLdb.connect(**db_config)
    cursor = conn.cursor()

    # Add sheba column to BankTransferSetting if not exists
    if table_exists(cursor, 'payments_banktransfersetting'):
        if not column_exists(cursor, 'payments_banktransfersetting', 'sheba'):
            safe_exec(cursor, "ALTER TABLE payments_banktransfersetting ADD COLUMN sheba VARCHAR(30) DEFAULT ''",
                      "Added sheba column to payments_banktransfersetting")
    conn.commit()

    cursor.close()
    conn.close()
    print("BankTransferSetting schema fixed successfully.")
except Exception as e:
    print(f"BankTransferSetting fix error (may be ok): {e}")
PYBANK

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
SH
  chmod +x app/entrypoint.sh
}

issue_ssl(){
  install_certbot
  mkdir -p "${APP_DIR}/certbot/www"
  if [[ -d "/etc/letsencrypt/live/${DOMAIN}" ]]; then
    echo "SSL certificate exists, attempting renewal..."
    certbot renew --quiet || true
    return 0
  fi
  echo "Requesting new SSL certificate..."
  if certbot certonly --webroot -w "${APP_DIR}/certbot/www" -d "${DOMAIN}" --email "${LE_EMAIL}" --agree-tos --non-interactive; then
    echo "✅ SSL certificate obtained successfully."
  else
    echo "⚠️  Warning: Failed to obtain SSL certificate. Site will run with HTTP only."
    echo "    You can retry later with: certbot certonly --webroot -w ${APP_DIR}/certbot/www -d ${DOMAIN}"
  fi
}

ensure_cron(){
  # Using single-quoted heredoc to prevent variable expansion, then using sed to replace
  cat > /etc/cron.d/educms-certbot-renew <<'CRON'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
17 3 * * * root certbot renew --quiet && docker compose -f __APP_DIR__/docker-compose.yml restart nginx >/dev/null 2>&1 || true
CRON
  sed -i "s|__APP_DIR__|${APP_DIR}|g" /etc/cron.d/educms-certbot-renew
  chmod 644 /etc/cron.d/educms-certbot-renew
}

debug_django(){
  cd "$APP_DIR" || die "Cannot cd to $APP_DIR"
  echo "Running Django checks + template compile scan..."
  docker compose exec -T web python manage.py check || echo "Warning: Django check failed, continuing..."

  docker compose exec -T web bash -lc "python - <<'PY'
import os, sys
from pathlib import Path

os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'educms.settings')
import django
django.setup()

from django.template import Engine, TemplateSyntaxError

engine = Engine.get_default()
roots = [Path('/app/templates')]
for p in Path('/app').glob('*/templates'):
    roots.append(p)

bad=[]
for root in roots:
    if not root.exists():
        continue
    for f in root.rglob('*.html'):
        try:
            txt = f.read_text(encoding='utf-8', errors='ignore')
            # normalize accidental escapes, if any
            txt = txt.replace('{{%', '{%').replace('%}}', '%}')
            txt = txt.replace('{{{{', '{{').replace('}}}}', '}}')
            engine.from_string(txt)
        except TemplateSyntaxError as e:
            bad.append((str(f), str(e)))

if bad:
    print('TEMPLATE ERRORS:')
    for path, err in bad[:30]:
        print('---', path)
        print('    ', err)
    sys.exit(1)
print('OK: templates compile clean')
PY"

  docker compose exec -T web bash -lc "python -m compileall -q /app || true"
}


do_install(){
  require_root; require_tty
  collect_inputs
  install_base
  install_docker
  cleanup_old
  ensure_dirs
  write_env
  write_compose
  write_project

  cd "$APP_DIR" || die "Cannot cd to $APP_DIR"
  write_nginx_http
  echo "Building and starting containers..."
  docker compose up -d --build db web nginx
  
  # Wait for services to be ready
  echo "Waiting for services to initialize..."
  sleep 10
  
  issue_ssl
  write_nginx_https
  
  debug_django
  docker compose restart nginx
  ensure_cron

  echo ""
  echo "============================================"
  echo "✅ DONE - EduCMS installed successfully!"
  echo "============================================"
  echo "Site: https://${DOMAIN}"
  echo "Dashboard: https://${DOMAIN}/dashboard/"
  echo "Admin: https://${DOMAIN}/${ADMIN_PATH}/"
  echo "Wallet: https://${DOMAIN}/wallet/"
  echo "Invoices: https://${DOMAIN}/invoices/"
  echo "============================================"
}


do_patch(){
  require_root
  [[ -d "$APP_DIR" ]] || die "Not installed: $APP_DIR"
  [[ -f "$ENV_FILE" ]] || die ".env not found: $ENV_FILE"
  install_base
  install_docker
  ensure_dirs
  write_compose
  write_project
  cd "$APP_DIR" || die "Cannot cd to $APP_DIR"
  
  # Load env vars
  set -a; . "$ENV_FILE"; set +a
  
  echo "Building and starting containers..."
  docker compose up -d --build db web nginx
  
  # Wait for DB to be ready
  echo "Waiting for database to be ready..."
  local wait_count=0
  while ! docker compose exec -T db mysqladmin ping -h 127.0.0.1 -uroot -p"${DB_PASS}" --silent 2>/dev/null; do
    wait_count=$((wait_count + 1))
    if [[ $wait_count -gt 30 ]]; then
      echo "Warning: Database might not be ready, continuing anyway..."
      break
    fi
    echo "  Waiting... ($wait_count/30)"
    sleep 2
  done
  
  # Fix database tables for new features
  echo "Fixing database tables..."
  docker compose exec -T -e MYSQL_PWD="${DB_PASS}" db mysql -uroot "${DB_NAME}" <<'SQLFIX'
-- Drop and recreate payments_onlinepayment with correct schema
DROP TABLE IF EXISTS payments_onlinepayment;
CREATE TABLE payments_onlinepayment (
    id CHAR(36) PRIMARY KEY,
    user_id BIGINT NOT NULL,
    gateway_id BIGINT NOT NULL,
    payment_type VARCHAR(10) NOT NULL DEFAULT 'order',
    amount INT UNSIGNED NOT NULL DEFAULT 0,
    order_id CHAR(36) NULL,
    authority VARCHAR(100) DEFAULT '',
    ref_id VARCHAR(100) DEFAULT '',
    status VARCHAR(20) NOT NULL DEFAULT 'pending',
    gateway_response JSON DEFAULT NULL,
    created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    paid_at DATETIME(6) NULL,
    KEY idx_user (user_id),
    KEY idx_gateway (gateway_id),
    KEY idx_order (order_id),
    KEY idx_authority (authority)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Create payments_paymentgateway if not exists
CREATE TABLE IF NOT EXISTS payments_paymentgateway (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    gateway_type VARCHAR(20) NOT NULL UNIQUE,
    merchant_id VARCHAR(100) NOT NULL,
    is_active TINYINT(1) NOT NULL DEFAULT 0,
    is_sandbox TINYINT(1) NOT NULL DEFAULT 0,
    priority INT UNSIGNED NOT NULL DEFAULT 0,
    description VARCHAR(200) DEFAULT '',
    created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Create settingsapp_ipsecuritysetting if not exists
CREATE TABLE IF NOT EXISTS settingsapp_ipsecuritysetting (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    is_enabled TINYINT(1) NOT NULL DEFAULT 1,
    max_attempts INT UNSIGNED NOT NULL DEFAULT 5,
    block_duration_type VARCHAR(10) NOT NULL DEFAULT 'minutes',
    block_duration_value INT UNSIGNED NOT NULL DEFAULT 30,
    reset_attempts_after INT UNSIGNED NOT NULL DEFAULT 60,
    updated_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Insert default IP security settings if empty
INSERT IGNORE INTO settingsapp_ipsecuritysetting (id, is_enabled, max_attempts, block_duration_type, block_duration_value, reset_attempts_after)
VALUES (1, 1, 5, 'minutes', 30, 60);

-- Create settingsapp_ipwhitelist if not exists
CREATE TABLE IF NOT EXISTS settingsapp_ipwhitelist (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    ip_address VARCHAR(39) NOT NULL UNIQUE,
    description VARCHAR(200) DEFAULT '',
    created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Create settingsapp_ipblacklist if not exists
CREATE TABLE IF NOT EXISTS settingsapp_ipblacklist (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    ip_address VARCHAR(39) NOT NULL,
    block_type VARCHAR(10) NOT NULL DEFAULT 'auto',
    reason VARCHAR(300) DEFAULT '',
    is_permanent TINYINT(1) NOT NULL DEFAULT 0,
    blocked_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    expires_at DATETIME(6) NULL,
    failed_attempts INT UNSIGNED NOT NULL DEFAULT 0,
    KEY idx_ip (ip_address),
    KEY idx_expires (expires_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Create settingsapp_loginattempt if not exists
CREATE TABLE IF NOT EXISTS settingsapp_loginattempt (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    ip_address VARCHAR(39) NOT NULL,
    username VARCHAR(150) DEFAULT '',
    is_successful TINYINT(1) NOT NULL DEFAULT 0,
    user_agent TEXT,
    attempted_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    KEY idx_ip (ip_address),
    KEY idx_at (attempted_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Add sheba column to BankTransferSetting if not exists
SET @col_exists = (SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='payments_banktransfersetting' AND COLUMN_NAME='sheba');
SET @sql = IF(@col_exists = 0, 'ALTER TABLE payments_banktransfersetting ADD COLUMN sheba VARCHAR(30) DEFAULT ""', 'SELECT 1');
PREPARE stmt FROM @sql;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;
SQLFIX

  echo "Database tables fixed."
  
  if ! docker compose ps web | grep -q "Up"; then
    docker compose logs --tail=200 web || true
    die "web is not running"
  fi
  docker compose restart nginx || true
  debug_django
  echo "Patched and restarted."
}


do_start(){ 
  cd "$APP_DIR" || die "Cannot cd to $APP_DIR"
  echo "Starting containers..."
  if docker compose up -d >/dev/null 2>&1; then
    echo "✅ Started successfully."
  else
    echo "First attempt failed, retrying with verbose output..."
    docker compose up -d
    echo "Started."
  fi
}

do_stop(){ 
  cd "$APP_DIR" || die "Cannot cd to $APP_DIR"
  echo "Stopping containers..."
  docker compose down --remove-orphans || true
  echo "✅ Stopped successfully."
}
do_restart(){ 
  cd "$APP_DIR" || die "Cannot cd to $APP_DIR"
  echo "Restarting containers..."
  docker compose up -d --build
  echo "✅ Restarted successfully."
}

backup_db(){
  require_root
  [[ -f "$ENV_FILE" ]] || die ".env not found"
  set -a; . "$ENV_FILE"; set +a
  cd "$APP_DIR" || die "Cannot cd to $APP_DIR"
  mkdir -p "$BACKUP_DIR"
  echo "Starting database container if not running..."
  docker compose up -d db >/dev/null 2>&1 || true
  # Wait for DB to be ready
  sleep 3
  local ts file; ts="$(date +%Y%m%d-%H%M%S)"; file="${BACKUP_DIR}/${DB_NAME}-${ts}.sql"
  echo "Creating backup..."
  if docker compose exec -T -e MYSQL_PWD="${DB_PASS}" db sh -lc "mysqldump -uroot --databases \"${DB_NAME}\" --single-transaction --quick --routines --triggers --events --set-gtid-purged=OFF" > "$file"; then
    chmod 600 "$file"
    echo "✅ Backup created: $file"
  else
    rm -f "$file" 2>/dev/null || true
    die "Backup failed"
  fi
}

restore_db(){
  require_root; require_tty
  [[ -f "$ENV_FILE" ]] || die ".env not found"
  set -a; . "$ENV_FILE"; set +a
  cd "$APP_DIR" || die "Cannot cd to $APP_DIR"
  local sql_file="${1:-}"
  [[ -n "$sql_file" && -f "$sql_file" ]] || die "Provide existing .sql path."

  echo "WARNING: This will overwrite DB '${DB_NAME}' using: ${sql_file}"
  read -r -p "Type YES to continue: " ans </dev/tty || true
  [[ "${ans:-}" == "YES" ]] || { echo "Canceled."; return 0; }

  echo "Starting database container..."
  docker compose up -d db >/dev/null 2>&1 || true
  sleep 3
  echo "Dropping and recreating database..."
  if ! docker compose exec -T -e MYSQL_PWD="${DB_PASS}" db sh -lc "mysql -uroot -e 'DROP DATABASE IF EXISTS \`${DB_NAME}\`; CREATE DATABASE \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;'"; then
    die "Failed to recreate database"
  fi
  echo "Restoring from backup..."
  if ! docker compose exec -T -e MYSQL_PWD="${DB_PASS}" db sh -lc "mysql -uroot \"${DB_NAME}\"" < "${sql_file}"; then
    die "Restore failed"
  fi
  echo "Starting web and nginx containers..."
  docker compose up -d web nginx >/dev/null 2>&1 || true
  echo "✅ Restore completed successfully."
}

change_domain(){
  require_root; require_tty
  [[ -d "$APP_DIR" ]] || die "Not installed: $APP_DIR"
  [[ -f "$ENV_FILE" ]] || die ".env not found: $ENV_FILE"
  
  set -a; . "$ENV_FILE"; set +a
  local old_domain="$DOMAIN"
  
  echo "============================================"
  echo "        تغییر دامنه (بدون حذف داده)        "
  echo "============================================"
  echo "دامنه فعلی: ${DOMAIN}"
  echo ""
  
  local new_domain new_email
  new_domain="$(read_line "دامنه جدید (مثال: newdomain.com): ")"
  validate_domain "$new_domain" || die "دامنه نامعتبر است"
  
  # Check if new domain is same as old domain
  if [[ "$new_domain" == "$old_domain" ]]; then
    echo "دامنه جدید با دامنه فعلی یکسان است. تغییری اعمال نشد."
    return 0
  fi
  
  new_email="$(read_line "ایمیل برای Let's Encrypt [${LE_EMAIL}]: ")"
  [[ -z "$new_email" ]] && new_email="$LE_EMAIL"
  validate_email "$new_email" || die "ایمیل نامعتبر است"
  
  echo ""
  echo "دامنه جدید: $new_domain"
  echo "ایمیل: $new_email"
  read -r -p "برای ادامه YES تایپ کنید: " ans </dev/tty || true
  [[ "${ans:-}" == "YES" ]] || { echo "لغو شد."; return 0; }
  
  cd "$APP_DIR" || die "Cannot cd to $APP_DIR"
  
  # Stop web container first
  echo "توقف سرویس‌ها..."
  docker compose stop web nginx || true
  
  # Update .env file with new domain
  echo "بروزرسانی تنظیمات..."
  sed -i "s|^DOMAIN=.*|DOMAIN=${new_domain}|" "$ENV_FILE"
  sed -i "s|^LE_EMAIL=.*|LE_EMAIL=${new_email}|" "$ENV_FILE"
  sed -i "s|^DJANGO_ALLOWED_HOSTS=.*|DJANGO_ALLOWED_HOSTS=${new_domain},www.${new_domain},localhost,127.0.0.1|" "$ENV_FILE"
  sed -i "s|^CSRF_TRUSTED_ORIGINS=.*|CSRF_TRUSTED_ORIGINS=https://${new_domain},https://www.${new_domain}|" "$ENV_FILE"
  
  # Update global vars for nginx functions
  DOMAIN="$new_domain"
  LE_EMAIL="$new_email"
  
  # Update nginx config (HTTP first for SSL challenge)
  echo "بروزرسانی nginx..."
  write_nginx_http
  
  # Start nginx for SSL challenge
  docker compose up -d nginx
  echo "Waiting for nginx to start..."
  sleep 5
  
  # Get new SSL certificate
  echo "دریافت گواهی SSL برای دامنه جدید..."
  install_certbot
  
  mkdir -p "${APP_DIR}/certbot/www"
  
  if [[ -d "/etc/letsencrypt/live/${new_domain}" ]]; then
    echo "گواهی SSL موجود است، تمدید..."
    certbot renew --quiet || true
  else
    echo "دریافت گواهی SSL جدید..."
    certbot certonly --webroot -w "${APP_DIR}/certbot/www" -d "${new_domain}" --email "${new_email}" --agree-tos --non-interactive --force-renewal 2>/dev/null || {
      echo "⚠️  خطا در دریافت SSL. سایت با HTTP راه‌اندازی می‌شود."
      echo "    می‌توانید بعداً با certbot گواهی بگیرید."
      # Keep HTTP config and start services
      docker compose up -d web nginx
      echo ""
      echo "============================================"
      echo "تغییر دامنه انجام شد (بدون SSL)"
      echo "سایت: http://${new_domain}"
      echo "============================================"
      return 0
    }
  fi
  
  # Update nginx config to HTTPS
  echo "فعال‌سازی HTTPS..."
  write_nginx_https
  
  # Rebuild and restart web container to load new env vars
  echo "راه‌اندازی مجدد سرویس‌ها..."
  docker compose up -d --force-recreate web nginx
  
  echo ""
  echo "============================================"
  echo "✅ تغییر دامنه با موفقیت انجام شد!"
  echo ""
  echo "سایت: https://${new_domain}"
  echo "پنل ادمین: https://${new_domain}/${ADMIN_PATH}/"
  echo "============================================"
}

do_uninstall(){
  require_root; require_tty
  echo "============================================"
  echo "⚠️  WARNING: UNINSTALL"
  echo "============================================"
  echo "This will permanently remove:"
  echo "  - Application directory: ${APP_DIR}"
  echo "  - All Docker containers and volumes"
  echo "  - All database data"
  echo "============================================"
  read -r -p "Type YES to continue: " ans </dev/tty || true
  [[ "${ans:-}" == "YES" ]] || { echo "Canceled."; return 0; }
  
  echo "Stopping and removing containers..."
  if [[ -d "${APP_DIR}" && -f "${APP_DIR}/docker-compose.yml" ]]; then
    (cd "${APP_DIR}" && docker compose down --remove-orphans --volumes) || true
  fi
  
  echo "Removing application directory..."
  rm -rf "${APP_DIR}" || true
  
  echo "Removing cron job..."
  rm -f /etc/cron.d/educms-certbot-renew 2>/dev/null || true
  
  echo "✅ Uninstalled successfully."
}

menu_header(){
  clear || true
  echo "============================================"
  echo "            EduCMS Menu (Latest)            "
  echo "============================================"
  echo "Path: ${APP_DIR}"
  echo
}

menu_show(){
  echo "1) Install (نصب کامل)"
  echo "2) Patch (بروزرسانی کد)"
  echo "3) Start (استارت)"
  echo "4) Stop (توقف)"
  echo "5) Restart (ری‌استارت)"
  echo "6) Backup DB (.sql)"
  echo "7) Restore DB (.sql)"
  echo "8) Change Domain (تغییر دامنه)"
  echo "9) Uninstall (حذف کامل)"
  echo "0) Exit"
  echo
}

main(){
  require_root

  if [[ ${#} -gt 0 ]]; then
    case "${1:-}" in
      start) do_start ;;
      install) do_install ;;
      patch) do_patch ;;
      stop) do_stop ;;
      restart) do_restart ;;
      uninstall) do_uninstall ;;
      backup) backup_db ;;
      restore)
        [[ -n "${2:-}" ]] || die "Usage: $0 restore /path/to/file.sql"
        restore_db "${2}"
        ;;
      change-domain) change_domain ;;
      *) echo "Usage: $0 [install|start|patch|stop|restart|uninstall|backup|restore /path/file.sql|change-domain]" ; exit 1 ;;
    esac
    exit 0
  fi

  require_tty
  while true; do
    menu_header
    menu_show
    read -r -p "Select: " c </dev/tty || c=""
    case "${c:-}" in
1) do_install ;;
2) do_patch ;;
3) do_start ;;
4) do_stop ;;
5) do_restart ;;
6) backup_db ;;
7)
  p="$(read_line "Path to .sql file (e.g. /opt/educms/backups/file.sql): ")"
  restore_db "$p"
  ;;
8) change_domain ;;
9) do_uninstall ;;
0) echo "Bye." ; exit 0 ;;
*) echo "Invalid option." ;;
    esac
    read -r -p "Press Enter..." _ </dev/tty || true
  done
}

main "$@"
