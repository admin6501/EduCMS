#!/usr/bin/env bash
set -Eeuo pipefail

LOG_FILE="/var/log/educms-install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

# Colors
RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BLUE=$'\033[34m'
CYAN=$'\033[36m'; BOLD=$'\033[1m'; RESET=$'\033[0m'

# -----------------------------
# Configuration (defaults)
# -----------------------------
APP_DIR="${APP_DIR:-/opt/educms}"
PROJECT_NAME="${PROJECT_NAME:-educms}"
DOMAIN="${DOMAIN:-localhost}"

ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@example.com}"
ADMIN_PASS="${ADMIN_PASS:-admin1234}"

DJANGO_DEBUG="${DJANGO_DEBUG:-0}"
TIMEZONE="${TIMEZONE:-Asia/Tehran}"

# Database defaults
POSTGRES_DB="${POSTGRES_DB:-educms}"
POSTGRES_USER="${POSTGRES_USER:-educms}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-educms}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"

# Nginx
NGINX_PORT="${NGINX_PORT:-80}"

# -----------------------------
# Helpers
# -----------------------------
log() { echo -e "${GREEN}[+]${RESET} $*"; }
info() { echo -e "${BLUE}[i]${RESET} $*"; }
warn() { echo -e "${YELLOW}[!]${RESET} $*"; }
err() { echo -e "${RED}[x]${RESET} $*" >&2; }
die() { err "$*"; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Command not found: $1"
}

confirm_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "Please run as root (sudo)."
  fi
}

detect_compose() {
  if docker compose version >/dev/null 2>&1; then
    echo "docker compose"
    return
  fi
  if command -v docker-compose >/dev/null 2>&1; then
    echo "docker-compose"
    return
  fi
  die "Neither 'docker compose' nor 'docker-compose' is available."
}

random_secret_key() {
  if command -v python3 >/dev/null 2>&1; then
    python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(48))
PY
  else
    date +%s | sha256sum | awk '{print $1}'
  fi
}

# -----------------------------
# System dependencies
# -----------------------------
install_deps() {
  log "Installing system dependencies"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends \
    ca-certificates curl wget git unzip \
    python3 python3-venv python3-pip \
    openssl \
    ufw \
    jq \
    || true

  if ! command -v docker >/dev/null 2>&1; then
    warn "Docker not found. Attempting to install docker (Ubuntu/Debian)."
    apt-get install -y docker.io || true
    systemctl enable --now docker || true
  fi

  if ! docker compose version >/dev/null 2>&1; then
    if ! command -v docker-compose >/dev/null 2>&1; then
      warn "Docker Compose not found. Attempting to install docker-compose plugin."
      apt-get install -y docker-compose-plugin || true
    fi
  fi
}

# -----------------------------
# Project writer
# -----------------------------
write_project() {
  local compose_cmd="$1"
  local secret_key="$2"

  log "Creating project directory structure in ${APP_DIR}"
  mkdir -p "${APP_DIR}"
  cd "${APP_DIR}"

  mkdir -p app
  mkdir -p nginx
  mkdir -p postgres
  mkdir -p app/static
  mkdir -p app/media
  mkdir -p app/templates
  mkdir -p app/settingsapp
  mkdir -p app/accounts
  mkdir -p app/courses
  mkdir -p app/payments
  mkdir -p app/tickets
  mkdir -p app/sessions

  # .env
  log "Writing .env"
  cat > .env <<ENV
PROJECT_NAME=${PROJECT_NAME}
DOMAIN=${DOMAIN}
DJANGO_SECRET_KEY=${secret_key}
DJANGO_DEBUG=${DJANGO_DEBUG}
TIMEZONE=${TIMEZONE}

POSTGRES_DB=${POSTGRES_DB}
POSTGRES_USER=${POSTGRES_USER}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
POSTGRES_PORT=${POSTGRES_PORT}

ADMIN_USER=${ADMIN_USER}
ADMIN_EMAIL=${ADMIN_EMAIL}
ADMIN_PASS=${ADMIN_PASS}
ENV

  # requirements
  log "Writing requirements"
  cat > app/requirements.txt <<'REQ'
Django>=4.2,<6.0
gunicorn>=22.0.0
psycopg2-binary>=2.9.9
Pillow>=10.0.0
whitenoise>=6.6.0
django-import-export>=3.3.8
REQ

  # manage.py
  cat > app/manage.py <<'PY'
#!/usr/bin/env python
import os
import sys

def main():
    os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'educms.settings')
    try:
        from django.core.management import execute_from_command_line
    except ImportError as exc:
        raise ImportError("Couldn't import Django.") from exc
    execute_from_command_line(sys.argv)

if __name__ == '__main__':
    main()
PY
  chmod +x app/manage.py

  # Django project
  mkdir -p app/educms
  cat > app/educms/__init__.py <<'PY'
PY

  cat > app/educms/asgi.py <<'PY'
import os
from django.core.asgi import get_asgi_application

os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'educms.settings')
application = get_asgi_application()
PY

  cat > app/educms/wsgi.py <<'PY'
import os
from django.core.wsgi import get_wsgi_application

os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'educms.settings')
application = get_wsgi_application()
PY

  # settings.py (project-specific)
  cat > app/educms/settings.py <<'PY'
from pathlib import Path
import os

BASE_DIR = Path(__file__).resolve().parent.parent

SECRET_KEY = os.environ.get("DJANGO_SECRET_KEY", "unsafe-secret")
DEBUG = os.environ.get("DJANGO_DEBUG", "0") == "1"

ALLOWED_HOSTS = ["*"]

INSTALLED_APPS = [
    "django.contrib.admin",
    "django.contrib.auth",
    "django.contrib.contenttypes",
    "django.contrib.sessions",
    "django.contrib.messages",
    "django.contrib.staticfiles",

    "import_export",

    "settingsapp",
    "accounts",
    "courses",
    "payments",
    "tickets",
    "sessions",
]

MIDDLEWARE = [
    "django.middleware.security.SecurityMiddleware",
    "whitenoise.middleware.WhiteNoiseMiddleware",
    "django.contrib.sessions.middleware.SessionMiddleware",
    "django.middleware.common.CommonMiddleware",
    "django.middleware.csrf.CsrfViewMiddleware",
    "django.contrib.auth.middleware.AuthenticationMiddleware",
    "django.contrib.messages.middleware.MessageMiddleware",
    "django.middleware.clickjacking.XFrameOptionsMiddleware",
]

ROOT_URLCONF = "educms.urls"

TEMPLATES = [
    {
        "BACKEND": "django.template.backends.django.DjangoTemplates",
        "DIRS": [BASE_DIR / "templates"],
        "APP_DIRS": True,
        "OPTIONS": {
            "context_processors": [
                "django.template.context_processors.debug",
                "django.template.context_processors.request",
                "django.contrib.auth.context_processors.auth",
                "django.contrib.messages.context_processors.messages",
                "settingsapp.context_processors.global_settings",
            ],
        },
    },
]

WSGI_APPLICATION = "educms.wsgi.application"

DATABASES = {
    "default": {
        "ENGINE": "django.db.backends.postgresql",
        "NAME": os.environ.get("POSTGRES_DB", "educms"),
        "USER": os.environ.get("POSTGRES_USER", "educms"),
        "PASSWORD": os.environ.get("POSTGRES_PASSWORD", "educms"),
        "HOST": os.environ.get("POSTGRES_HOST", "db"),
        "PORT": os.environ.get("POSTGRES_PORT", "5432"),
    }
}

AUTH_PASSWORD_VALIDATORS = [
    {"NAME": "django.contrib.auth.password_validation.UserAttributeSimilarityValidator"},
    {"NAME": "django.contrib.auth.password_validation.MinimumLengthValidator"},
    {"NAME": "django.contrib.auth.password_validation.CommonPasswordValidator"},
    {"NAME": "django.contrib.auth.password_validation.NumericPasswordValidator"},
]

LANGUAGE_CODE = "fa"
TIME_ZONE = os.environ.get("TIMEZONE", "Asia/Tehran")
USE_I18N = True
USE_TZ = True

STATIC_URL = "/static/"
STATIC_ROOT = BASE_DIR / "staticfiles"
STATICFILES_DIRS = [BASE_DIR / "static"]
STATICFILES_STORAGE = "whitenoise.storage.CompressedManifestStaticFilesStorage"

MEDIA_URL = "/media/"
MEDIA_ROOT = BASE_DIR / "media"

DEFAULT_AUTO_FIELD = "django.db.models.BigAutoField"
PY

  # urls.py
  cat > app/educms/urls.py <<'PY'
from django.contrib import admin
from django.urls import path, include

urlpatterns = [
    path("admin/", admin.site.urls),
    path("", include("courses.urls")),
    path("accounts/", include("accounts.urls")),
    path("payments/", include("payments.urls")),
    path("tickets/", include("tickets.urls")),
    path("sessions/", include("sessions.urls")),
]
PY

  # -----------------------------
  # settingsapp (global settings + context processor)
  # -----------------------------
  mkdir -p app/settingsapp/migrations
  cat > app/settingsapp/__init__.py <<'PY'
PY

  cat > app/settingsapp/apps.py <<'PY'
from django.apps import AppConfig

class SettingsappConfig(AppConfig):
    default_auto_field = "django.db.models.BigAutoField"
    name = "settingsapp"
PY

  cat > app/settingsapp/models.py <<'PY'
from django.db import models

class SiteSettings(models.Model):
    THEME_CHOICES = (
        ("light", "Light"),
        ("dark", "Dark"),
        ("system", "System"),
    )

    brand_name = models.CharField(max_length=120, default="EduCMS")
    tagline = models.CharField(max_length=200, blank=True, default="")
    footer_text = models.CharField(max_length=300, blank=True, default="© تمامی حقوق محفوظ است.")
    logo = models.ImageField(upload_to="logos/", blank=True, null=True)

    admin_path = models.CharField(max_length=50, default="admin")
    default_theme = models.CharField(max_length=10, choices=THEME_CHOICES, default="system")

    def __str__(self):
        return self.brand_name


class NavLink(models.Model):
    AREA_CHOICES = (
        ("header", "Header"),
        ("footer", "Footer"),
    )
    area = models.CharField(max_length=10, choices=AREA_CHOICES, default="header")
    title = models.CharField(max_length=100)
    url = models.CharField(max_length=300)
    order = models.PositiveIntegerField(default=0)

    class Meta:
        ordering = ["area", "order", "id"]

    def __str__(self):
        return f"{self.area}: {self.title}"
PY

  cat > app/settingsapp/admin.py <<'PY'
from django.contrib import admin
from import_export.admin import ImportExportModelAdmin
from .models import SiteSettings, NavLink

@admin.register(SiteSettings)
class SiteSettingsAdmin(ImportExportModelAdmin):
    list_display = ("brand_name", "admin_path", "default_theme")

@admin.register(NavLink)
class NavLinkAdmin(ImportExportModelAdmin):
    list_display = ("area", "title", "url", "order")
    list_filter = ("area",)
    search_fields = ("title", "url")
PY

  cat > app/settingsapp/context_processors.py <<'PY'
from .models import SiteSettings, NavLink

def global_settings(request):
    site_settings = SiteSettings.objects.first()
    header_links = NavLink.objects.filter(area="header")
    footer_links = NavLink.objects.filter(area="footer")
    # Provide a safe dict for templates that may expect "tpl" too
    tpl = {}
    return {
        "site_settings": site_settings,
        "header_links": header_links,
        "footer_links": footer_links,
        "tpl": tpl,
    }
PY

  cat > app/settingsapp/migrations/__init__.py <<'PY'
PY

  # -----------------------------
  # Minimal app scaffolds (accounts/courses/payments/tickets/sessions)
  # -----------------------------
  for a in accounts courses payments tickets sessions; do
    mkdir -p "app/${a}/migrations"
    cat > "app/${a}/__init__.py"<<'PY'
PY
    cat > "app/${a}/apps.py" <<PY
from django.apps import AppConfig

class ${a^}Config(AppConfig):
    default_auto_field = "django.db.models.BigAutoField"
    name = "${a}"
PY
    cat > "app/${a}/migrations/__init__.py"<<'PY'
PY
  done

  # accounts urls/views (minimal)
  cat > app/accounts/urls.py <<'PY'
from django.urls import path
from . import views

urlpatterns = [
    path("login/", views.login_view, name="login"),
    path("register/", views.register_view, name="register"),
    path("logout/", views.logout_view, name="logout"),
]
PY

  cat > app/accounts/views.py <<'PY'
from django.contrib.auth import authenticate, login, logout
from django.contrib.auth.models import User
from django.shortcuts import redirect, render
from django.views.decorators.http import require_http_methods

@require_http_methods(["GET","POST"])
def login_view(request):
    if request.method == "POST":
        u = request.POST.get("username","").strip()
        p = request.POST.get("password","").strip()
        user = authenticate(request, username=u, password=p)
        if user:
            login(request, user)
            return redirect("/")
        return render(request, "accounts/login.html", {"error":"نام کاربری یا رمز عبور اشتباه است."})
    return render(request, "accounts/login.html")

@require_http_methods(["GET","POST"])
def register_view(request):
    if request.method == "POST":
        u = request.POST.get("username","").strip()
        e = request.POST.get("email","").strip()
        p = request.POST.get("password","").strip()
        if not u or not p:
            return render(request, "accounts/register.html", {"error":"نام کاربری و رمز عبور الزامی است."})
        if User.objects.filter(username=u).exists():
            return render(request, "accounts/register.html", {"error":"این نام کاربری قبلاً ثبت شده است."})
        user = User.objects.create_user(username=u, email=e, password=p)
        login(request, user)
        return redirect("/")
    return render(request, "accounts/register.html")

@require_http_methods(["POST"])
def logout_view(request):
    logout(request)
    return redirect("/")
PY

  mkdir -p app/templates/accounts
  cat > app/templates/accounts/login.html <<'HTML'
{% extends "base.html" %}
{% block title %}ورود{% endblock %}
{% block content %}
<div class="max-w-md mx-auto rounded-2xl border border-slate-200 bg-white p-6 shadow-sm dark:border-slate-800 dark:bg-slate-950">
  <h1 class="text-xl font-bold mb-4">ورود</h1>
  {% if error %}<div class="mb-3 p-3 rounded-xl border border-red-200 bg-red-50 text-red-800 dark:border-red-900/40 dark:bg-red-950/30 dark:text-red-200">{{ error }}</div>{% endif %}
  <form method="post">
    {% csrf_token %}
    <label class="block text-sm mb-1">نام کاربری</label>
    <input name="username" class="w-full rounded-xl border px-3 py-2 mb-3 bg-white dark:bg-slate-950 dark:border-slate-800" />
    <label class="block text-sm mb-1">رمز عبور</label>
    <input type="password" name="password" class="w-full rounded-xl border px-3 py-2 mb-4 bg-white dark:bg-slate-950 dark:border-slate-800" />
    <button class="w-full rounded-xl bg-slate-900 px-4 py-2 font-semibold text-white hover:bg-slate-800 dark:bg-slate-100 dark:text-slate-950 dark:hover:bg-slate-200">ورود</button>
  </form>
</div>
{% endblock %}
HTML

  cat > app/templates/accounts/register.html <<'HTML'
{% extends "base.html" %}
{% block title %}ثبت‌نام{% endblock %}
{% block content %}
<div class="max-w-md mx-auto rounded-2xl border border-slate-200 bg-white p-6 shadow-sm dark:border-slate-800 dark:bg-slate-950">
  <h1 class="text-xl font-bold mb-4">ثبت‌نام</h1>
  {% if error %}<div class="mb-3 p-3 rounded-xl border border-red-200 bg-red-50 text-red-800 dark:border-red-900/40 dark:bg-red-950/30 dark:text-red-200">{{ error }}</div>{% endif %}
  <form method="post">
    {% csrf_token %}
    <label class="block text-sm mb-1">نام کاربری</label>
    <input name="username" class="w-full rounded-xl border px-3 py-2 mb-3 bg-white dark:bg-slate-950 dark:border-slate-800" />
    <label class="block text-sm mb-1">ایمیل (اختیاری)</label>
    <input name="email" class="w-full rounded-xl border px-3 py-2 mb-3 bg-white dark:bg-slate-950 dark:border-slate-800" />
    <label class="block text-sm mb-1">رمز عبور</label>
    <input type="password" name="password" class="w-full rounded-xl border px-3 py-2 mb-4 bg-white dark:bg-slate-950 dark:border-slate-800" />
    <button class="w-full rounded-xl bg-slate-900 px-4 py-2 font-semibold text-white hover:bg-slate-800 dark:bg-slate-100 dark:text-slate-950 dark:hover:bg-slate-200">ثبت‌نام</button>
  </form>
</div>
{% endblock %}
HTML

  # courses home
  cat > app/courses/urls.py <<'PY'
from django.urls import path
from . import views

urlpatterns = [
    path("", views.course_list, name="course_list"),
]
PY

  cat > app/courses/views.py <<'PY'
from django.shortcuts import render
from settingsapp.models import SiteSettings

def course_list(request):
    # Ensure settings row exists to avoid template errors
    if not SiteSettings.objects.exists():
        SiteSettings.objects.create()
    return render(request, "courses/course_list.html")
PY

  mkdir -p app/templates/courses
  cat > app/templates/courses/course_list.html <<'HTML'
{% extends "base.html" %}
{% block title %}{{ site_settings.brand_name|default:"EduCMS" }}{% endblock %}
{% block content %}
<div class="grid gap-6 md:grid-cols-2">
  <div class="rounded-2xl border border-slate-200 bg-white p-6 shadow-sm dark:border-slate-800 dark:bg-slate-950">
    <h1 class="text-xl font-bold mb-2">خوش آمدید</h1>
    <p class="text-slate-600 dark:text-slate-300">
      این صفحه نمونه است. از بالای صفحه می‌توانید تم روشن/تیره/سیستم را تغییر دهید.
    </p>
  </div>
  <div class="rounded-2xl border border-slate-200 bg-white p-6 shadow-sm dark:border-slate-800 dark:bg-slate-950">
    <h2 class="text-lg font-bold mb-2">راهنما</h2>
    <ul class="list-disc pr-5 space-y-2 text-slate-600 dark:text-slate-300">
      <li>برای تغییر تم از دکمه‌های بالای صفحه استفاده کنید.</li>
      <li>در پنل ادمین می‌توانید تنظیمات سایت را تغییر دهید.</li>
    </ul>
  </div>
</div>
{% endblock %}
HTML

  # payments/tickets/sessions minimal urls to avoid include errors
  cat > app/payments/urls.py <<'PY'
from django.urls import path
urlpatterns = []
PY
  cat > app/tickets/urls.py <<'PY'
from django.urls import path
urlpatterns = []
PY
  cat > app/sessions/urls.py <<'PY'
from django.urls import path
urlpatterns = []
PY

  # -----------------------------
  # base.html (THEME FIX, compatible with project context)
  # -----------------------------
  log "Writing templates/base.html (theme fix)"
  cat > app/templates/base.html <<'HTML'
{% load static %}
<!doctype html>
<html lang="fa" dir="rtl">
<head>
  <meta charset="utf-8"/>
  <meta name="viewport" content="width=device-width,initial-scale=1"/>
  <meta name="color-scheme" content="light dark"/>

  <!-- Apply theme early to avoid flash and ensure dark mode works -->
  <script>
  (function () {
    const root = document.documentElement;

    function apply(mode) {
      root.classList.remove('dark');

      if (mode === 'light') return;

      if (mode === 'dark') {
        root.classList.add('dark');
        return;
      }

      // system
      const prefersDark = window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches;
      if (prefersDark) root.classList.add('dark');
    }

    const serverDefault = '{% if site_settings and site_settings.default_theme %}{{ site_settings.default_theme }}{% else %}system{% endif %}';
    const stored = localStorage.getItem('theme_mode');
    const initial = (stored === 'light' || stored === 'dark' || stored === 'system') ? stored : serverDefault;

    apply(initial);

    window.__setTheme = function (m) {
      if (m !== 'light' && m !== 'dark' && m !== 'system') return;
      localStorage.setItem('theme_mode', m);
      apply(m);
    };
  })();
  </script>

  <!-- Tailwind Play CDN (v4+) -->
  <script src="https://cdn.jsdelivr.net/npm/@tailwindcss/browser@4"></script>

  <!-- Enable class-based dark mode for Tailwind v4+ -->
  <style type="text/tailwindcss">
    @custom-variant dark (&:where(.dark, .dark *));
  </style>

  <title>{% block title %}{% if site_settings and site_settings.brand_name %}{{ site_settings.brand_name }}{% else %}EduCMS{% endif %}{% endblock %}</title>
</head>

<body class="bg-slate-50 text-slate-900 dark:bg-slate-950 dark:text-slate-100">
  <div class="min-h-screen">
    <header class="sticky top-0 z-40 border-b border-slate-200/60 bg-white/80 backdrop-blur dark:border-slate-800/60 dark:bg-slate-950/70">
      <div class="mx-auto max-w-6xl px-4 py-3 flex items-center justify-between gap-3">
        <a href="/" class="flex items-center gap-3">
          {% if site_settings and site_settings.logo %}
            <img src="{{ site_settings.logo.url }}" class="h-9 w-auto" alt="{% if site_settings.brand_name %}{{ site_settings.brand_name }}{% else %}EduCMS{% endif %}"/>
          {% else %}
            <div class="h-9 w-9 rounded-xl bg-slate-900 dark:bg-slate-100"></div>
          {% endif %}

          <div class="leading-tight">
            <div class="font-bold">{% if site_settings and site_settings.brand_name %}{{ site_settings.brand_name }}{% else %}EduCMS{% endif %}</div>
            <div class="text-xs text-slate-500 dark:text-slate-400">{% if site_settings and site_settings.tagline %}{{ site_settings.tagline }}{% else %}سامانه آموزش{% endif %}</div>
          </div>
        </a>

        <nav class="hidden md:flex items-center gap-4 text-sm">
          {% if header_links %}
            {% for l in header_links %}
              <a class="hover:underline" href="{{ l.url }}">{{ l.title }}</a>
            {% endfor %}
          {% endif %}
        </nav>

        <div class="flex items-center gap-2">
          <div class="hidden sm:flex items-center gap-1 rounded-xl border border-slate-200 bg-white px-2 py-1 text-sm dark:border-slate-800 dark:bg-slate-950">
            <button type="button" class="rounded-lg px-2 py-1 hover:bg-slate-100 dark:hover:bg-slate-900" onclick="__setTheme('light')">روشن</button>
            <button type="button" class="rounded-lg px-2 py-1 hover:bg-slate-100 dark:hover:bg-slate-900" onclick="__setTheme('dark')">تیره</button>
            <button type="button" class="rounded-lg px-2 py-1 hover:bg-slate-100 dark:hover:bg-slate-900" onclick="__setTheme('system')">سیستم</button>
          </div>

          <a href="/{% if site_settings and site_settings.admin_path %}{{ site_settings.admin_path }}{% else %}admin{% endif %}/"
             class="rounded-xl bg-slate-900 px-3 py-2 text-sm font-semibold text-white hover:bg-slate-800 dark:bg-slate-100 dark:text-slate-950 dark:hover:bg-slate-200">
            پنل ادمین
          </a>

          {% if user.is_authenticated %}
            <form method="post" action="/accounts/logout/" class="inline">
              {% csrf_token %}
              <button type="submit" class="rounded-xl border border-slate-200 px-3 py-2 text-sm font-semibold hover:bg-slate-100 dark:border-slate-800 dark:hover:bg-slate-900">
                خروج
              </button>
            </form>
          {% else %}
            <a href="/accounts/login/" class="rounded-xl border border-slate-200 px-3 py-2 text-sm font-semibold hover:bg-slate-100 dark:border-slate-800 dark:hover:bg-slate-900">ورود</a>
            <a href="/accounts/register/" class="rounded-xl border border-slate-200 px-3 py-2 text-sm font-semibold hover:bg-slate-100 dark:border-slate-800 dark:hover:bg-slate-900">ثبت‌نام</a>
          {% endif %}
        </div>
      </div>
    </header>

    <main class="mx-auto max-w-6xl px-4 py-8">
      {% if messages %}
        <div class="space-y-2 mb-6">
          {% for message in messages %}
            <div class="rounded-xl border border-slate-200 bg-white px-4 py-3 text-sm dark:border-slate-800 dark:bg-slate-950">
              {{ message }}
            </div>
          {% endfor %}
        </div>
      {% endif %}

      {% block content %}{% endblock %}
    </main>

    <footer class="border-t border-slate-200/60 py-8 text-center text-xs text-slate-500 dark:border-slate-800/60 dark:text-slate-400">
      <div class="mx-auto max-w-6xl px-4">
        {% if site_settings and site_settings.footer_text %}
          {{ site_settings.footer_text }}
        {% else %}
          © تمامی حقوق محفوظ است.
        {% endif %}
      </div>

      {% if footer_links %}
        <div class="mx-auto max-w-6xl px-4 mt-4 flex flex-wrap justify-center gap-2">
          {% for l in footer_links %}
            <a class="px-3 py-1 rounded-xl border border-slate-200 hover:bg-slate-100 dark:border-slate-800 dark:hover:bg-slate-900" href="{{ l.url }}">{{ l.title }}</a>
          {% endfor %}
        </div>
      {% endif %}
    </footer>
  </div>
</body>
</html>
HTML

  # Dockerfile
  log "Writing Dockerfile"
  cat > app/Dockerfile <<'DOCKER'
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    libpq-dev \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt

COPY . /app
CMD ["gunicorn", "educms.wsgi:application", "--bind", "0.0.0.0:8000"]
DOCKER

  # entrypoint
  log "Writing entrypoint.sh"
  cat > app/entrypoint.sh <<'SH'
#!/usr/bin/env sh
set -e

python manage.py migrate --noinput
python manage.py collectstatic --noinput || true

python - <<'PY'
import os
import django

os.environ.setdefault("DJANGO_SETTINGS_MODULE", "educms.settings")
django.setup()

from django.contrib.auth import get_user_model
User = get_user_model()

username = os.environ.get("ADMIN_USER", "admin")
email = os.environ.get("ADMIN_EMAIL", "admin@example.com")
password = os.environ.get("ADMIN_PASS", "admin1234")

created = False
if not User.objects.filter(username=username).exists():
    User.objects.create_superuser(username=username, email=email, password=password)
    created = True

print(f"Admin ready: admin created= {created}")
print("Admin path: admin")
PY

exec "$@"
SH
  chmod +x app/entrypoint.sh

  # docker-compose
  log "Writing docker-compose.yml"
  cat > docker-compose.yml <<YML
services:
  db:
    image: postgres:16
    environment:
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      TZ: ${TIMEZONE}
    volumes:
      - ./postgres:/var/lib/postgresql/data
    restart: unless-stopped

  web:
    build: ./app
    env_file:
      - .env
    environment:
      POSTGRES_HOST: db
      POSTGRES_PORT: ${POSTGRES_PORT}
    volumes:
      - ./app:/app
      - ./app/media:/app/media
    depends_on:
      - db
    command: ["sh", "-c", "/app/entrypoint.sh gunicorn educms.wsgi:application --bind 0.0.0.0:8000"]
    restart: unless-stopped

  nginx:
    image: nginx:1.27-alpine
    ports:
      - "${NGINX_PORT}:80"
    volumes:
      - ./nginx/default.conf:/etc/nginx/conf.d/default.conf:ro
      - ./app/staticfiles:/static:ro
      - ./app/media:/media:ro
    depends_on:
      - web
    restart: unless-stopped
YML

  # nginx conf
  log "Writing nginx/default.conf"
  cat > nginx/default.conf <<'NGINX'
server {
    listen 80;
    server_name _;

    client_max_body_size 25m;

    location /static/ {
        alias /static/;
        access_log off;
        expires 30d;
    }

    location /media/ {
        alias /media/;
        access_log off;
        expires 30d;
    }

    location / {
        proxy_pass http://web:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_redirect off;
    }
}
NGINX

  # migrations init files are already created above

  log "Project files written."
  info "Next: building containers."
  ${compose_cmd} build web
  ${compose_cmd} up -d

  log "Done."
  cat <<EOF

EduCMS has been installed.

URL:
  http://${DOMAIN}/

Admin:
  http://${DOMAIN}/admin/
  username: ${ADMIN_USER}
  email:    ${ADMIN_EMAIL}
  password: ${ADMIN_PASS}

Logs:
  ${LOG_FILE}

EOF
}

# -----------------------------
# Backup/Restore utilities (kept as in original flow)
# -----------------------------
backup_db() {
  local compose_cmd="$1"
  local out="${2:-/opt/educms/backup.sql}"
  log "Backing up database to: $out"
  ${compose_cmd} exec -T db pg_dump -U "${POSTGRES_USER}" "${POSTGRES_DB}" > "$out"
  log "Backup created: $out"
}

restore_db() {
  local compose_cmd="$1"
  local in="$2"
  [[ -f "$in" ]] || die "Backup file not found: $in"
  log "Restoring database from: $in"
  ${compose_cmd} exec -T db psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" < "$in"
  log "Restore completed."
}

menu() {
  echo
  echo -e "${BOLD}EduCMS Installer Menu${RESET}"
  echo "1) Install / Reinstall"
  echo "2) Backup DB"
  echo "3) Restore DB"
  echo "0) Exit"
  echo
}

main() {
  confirm_root
  install_deps

  need_cmd docker
  local compose_cmd
  compose_cmd="$(detect_compose)"
  log "Using compose: ${compose_cmd}"

  local secret_key
  secret_key="$(random_secret_key)"

  mkdir -p "${APP_DIR}"
  cd "${APP_DIR}"

  while true; do
    menu
    read -r -p "Select: " choice </dev/tty || true
    case "${choice:-}" in
      1)
        write_project "$compose_cmd" "$secret_key"
        ;;
      2)
        read -r -p "Backup path (default: ${APP_DIR}/backup.sql): " p </dev/tty || true
        backup_db "$compose_cmd" "${p:-${APP_DIR}/backup.sql}"
        ;;
      3)
        read -r -p "Restore from path: " p </dev/tty || true
        restore_db "$compose_cmd" "$p"
        ;;
      0)
        echo "Bye."
        exit 0
        ;;
      *)
        echo "Invalid."
        ;;
    esac
    read -r -p "Press Enter..." _ </dev/tty || true
  done
}

main
