#!/usr/bin/env bash
set -Eeuo pipefail

LOG_FILE="/var/log/educms-installer.log"
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1
trap 'echo "ERROR at line $LINENO (exit=$?). Log: '"$LOG_FILE"'" >&2' ERR

APP_DIR="/opt/educms"
ENV_FILE="${APP_DIR}/.env"
BACKUP_DIR="${APP_DIR}/backups"

DOMAIN=""
LE_EMAIL=""
ADMIN_EMAIL=""
ADMIN_PASS=""
ADMIN_PATH="admin"

DB_NAME="educms"
DB_USER=""
DB_PASS=""

RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BLUE=$'\033[34m'
CYAN=$'\033[36m'; BOLD=$'\033[1m'; RESET=$'\033[0m'

require_root(){ [[ $EUID -eq 0 ]] || { echo -e "${RED}ERROR:${RESET} Run with sudo/root."; exit 1; }; }
require_tty(){ [[ -r /dev/tty && -w /dev/tty ]] || { echo -e "${RED}ERROR:${RESET} /dev/tty not accessible. Run interactively."; exit 1; }; }
have_cmd(){ command -v "$1" >/dev/null 2>&1; }

step(){ echo -e "${BOLD}${BLUE}>>${RESET} $*"; }
ok(){ echo -e "${GREEN}OK:${RESET} $*"; }
warn(){ echo -e "${YELLOW}WARN:${RESET} $*"; }

trim_newlines(){ printf "%s" "${1:-}" | tr -d '\r\n'; }
read_line(){ local p="$1" v=""; read -r -p "$p" v </dev/tty || true; printf "%s" "$(trim_newlines "$v")"; }
read_secret(){ local p="$1" v=""; read -r -s -p "$p" v </dev/tty || true; echo >&2; printf "%s" "$(trim_newlines "$v")"; }

install_base_packages(){
  step "Installing base packages..."
  apt update
  apt install -y ca-certificates curl gnupg lsb-release openssl
  ok "Base packages ready."
}

install_docker() {
  step "Installing Docker (if needed)..."
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
  ok "Docker ready."
}

host_certbot_install_if_needed(){
  step "Installing certbot on host (if needed)..."
  if ! have_cmd certbot; then
    apt update
    apt install -y certbot
  fi
  ok "Certbot ready."
}

collect_inputs() {
  echo -e "${BOLD}${CYAN}=== EduCMS Installer ===${RESET}"
  echo -e "${CYAN}Log:${RESET} ${LOG_FILE}"
  echo

  DOMAIN="$(read_line "Domain (e.g. example.com): ")"
  LE_EMAIL="$(read_line "Email for Let's Encrypt: ")"

  ADMIN_PATH="$(read_line "Admin path (default: admin): ")"
  [[ -z "${ADMIN_PATH:-}" ]] && ADMIN_PATH="admin"
  ADMIN_PATH="$(printf "%s" "$ADMIN_PATH" | sed 's#^/##;s#/$##')"
  [[ -z "${ADMIN_PATH:-}" ]] && ADMIN_PATH="admin"

  local tmpdb
  tmpdb="$(read_line "Database name [default: ${DB_NAME}]: ")"
  [[ -n "${tmpdb:-}" ]] && DB_NAME="$tmpdb"

  DB_USER="$(read_line "Database username: ")"
  DB_PASS="$(read_secret "Database password (hidden): ")"

  ADMIN_EMAIL="$(read_line "Admin email (login): ")"
  ADMIN_PASS="$(read_secret "Admin password (hidden): ")"

  [[ -n "$DOMAIN" && -n "$LE_EMAIL" && -n "$DB_USER" && -n "$DB_PASS" && -n "$ADMIN_EMAIL" && -n "$ADMIN_PASS" ]] \
    || { echo -e "${RED}ERROR:${RESET} Required input is empty."; exit 1; }

  ok "Inputs collected."
}

cleanup_existing_fresh_install(){
  step "Checking previous install..."
  if [[ -d "${APP_DIR}" && -f "${APP_DIR}/docker-compose.yml" ]]; then
    warn "Existing install detected at ${APP_DIR}"
    echo
    echo "Choose cleanup mode:"
    echo "  1) Keep database volume (recommended if you want keep data)"
    echo "  2) Remove database volume too (FULL reset)"
    echo
    read -r -p "Select [1/2]: " mode </dev/tty || mode="1"
    if [[ "$mode" == "2" ]]; then
      step "Stopping and removing containers + volumes..."
      ( cd "${APP_DIR}" && docker compose down --remove-orphans --volumes ) || warn "compose down failed (ignored)."
    else
      step "Stopping containers (keeping volumes)..."
      ( cd "${APP_DIR}" && docker compose down --remove-orphans ) || warn "compose down failed (ignored)."
    fi
  fi

  step "Resetting app directory..."
  rm -rf "${APP_DIR}" || { echo -e "${RED}ERROR:${RESET} Cannot remove ${APP_DIR}"; exit 1; }
  ok "Cleanup done."
}

ensure_dirs(){
  step "Creating directories..."
  mkdir -p "${APP_DIR}" "${BACKUP_DIR}"
  cd "${APP_DIR}"
  mkdir -p app/templates/{accounts,courses,orders,tickets,settings,admin} app/static app/media nginx certbot/www certbot/conf
  ok "Directories created."
}

write_env(){
  step "Writing .env ..."
  local secret
  secret="$(openssl rand -hex 32)"

  : > "${ENV_FILE}"
  printf "DOMAIN=%s\n" "${DOMAIN}" >> "${ENV_FILE}"
  printf "LE_EMAIL=%s\n" "${LE_EMAIL}" >> "${ENV_FILE}"
  printf "ADMIN_PATH=%s\n" "${ADMIN_PATH}" >> "${ENV_FILE}"
  printf "\n" >> "${ENV_FILE}"
  printf "DB_NAME=%s\n" "${DB_NAME}" >> "${ENV_FILE}"
  printf "DB_USER=%s\n" "${DB_USER}" >> "${ENV_FILE}"
  printf "DB_PASS=%s\n" "${DB_PASS}" >> "${ENV_FILE}"
  printf "\n" >> "${ENV_FILE}"
  printf "ADMIN_EMAIL=%s\n" "${ADMIN_EMAIL}" >> "${ENV_FILE}"
  printf "ADMIN_PASS=%s\n" "${ADMIN_PASS}" >> "${ENV_FILE}"
  printf "\n" >> "${ENV_FILE}"
  printf "DJANGO_SECRET_KEY=%s\n" "${secret}" >> "${ENV_FILE}"
  printf "DJANGO_DEBUG=False\n" >> "${ENV_FILE}"
  printf "DJANGO_ALLOWED_HOSTS=%s\n" "${DOMAIN}" >> "${ENV_FILE}"
  printf "CSRF_TRUSTED_ORIGINS=https://%s\n" "${DOMAIN}" >> "${ENV_FILE}"
  printf "INITIAL_ADMIN_PATH=%s\n" "${ADMIN_PATH}" >> "${ENV_FILE}"

  chmod 600 "${ENV_FILE}"
  ok ".env created."
}

write_compose(){
  step "Writing docker-compose.yml ..."
  cat > docker-compose.yml <<'YML'
services:
  db:
    image: mysql:8.0
    command: --default-authentication-plugin=mysql_native_password --character-set-server=utf8mb4 --collation-server=utf8mb4_unicode_ci
    env_file: ./.env
    environment:
      MYSQL_DATABASE: ${DB_NAME}
      MYSQL_USER: ${DB_USER}
      MYSQL_PASSWORD: ${DB_PASS}
      MYSQL_ROOT_PASSWORD: ${DB_PASS}
    volumes:
      - db_data:/var/lib/mysql
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
      ADMIN_EMAIL: ${ADMIN_EMAIL}
      ADMIN_PASS: ${ADMIN_PASS}
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
    ports:
      - "80:80"
      - "443:443"
    depends_on:
      - web
    restart: unless-stopped

volumes:
  db_data:
YML
  docker compose -f docker-compose.yml config >/dev/null
  ok "docker-compose.yml valid."
}

write_nginx_http(){
  step "Writing nginx (HTTP) config..."
  cat > nginx/nginx.conf <<NGINX
server {
  listen 80;
  server_name ${DOMAIN};

  location /.well-known/acme-challenge/ { root /var/www/certbot; }

  location /static/ { alias /var/www/static/; }
  location /media/  { alias /var/www/media/; client_max_body_size 2000M; }

  location / {
    proxy_pass http://web:8000;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
  }
}
NGINX
  ok "nginx http config written."
}

write_nginx_https(){
  step "Writing nginx (HTTPS) config..."
  cat > nginx/nginx.conf <<NGINX
server {
  listen 80;
  server_name ${DOMAIN};

  location /.well-known/acme-challenge/ { root /var/www/certbot; }
  location / { return 301 https://\$host\$request_uri; }
}

server {
  listen 443 ssl;
  server_name ${DOMAIN};

  ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;

  location /static/ { alias /var/www/static/; }
  location /media/  { alias /var/www/media/; client_max_body_size 2000M; }

  location / {
    proxy_pass http://web:8000;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
  }
}
NGINX
  ok "nginx https config written."
}

write_project(){
  step "Writing project files..."
  cat > app/Dockerfile <<'DOCKER'
FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential gcc pkg-config gettext locales \
    default-libmysqlclient-dev libmariadb-dev \
    && sed -i 's/^# *fa_IR.UTF-8 UTF-8/fa_IR.UTF-8 UTF-8/' /etc/locale.gen \
    && locale-gen \
    && rm -rf /var/lib/apt/lists/*

ENV LANG=fa_IR.UTF-8
ENV LC_ALL=fa_IR.UTF-8

WORKDIR /app
COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt
COPY . /app
CMD ["/app/entrypoint.sh"]
DOCKER

  cat > app/requirements.txt <<'REQ'
Django>=5.0,<6.0
gunicorn>=23.0
mysqlclient>=2.2
Pillow>=10.0
REQ

  mkdir -p app/{educms,accounts,courses,settingsapp,payments,tickets}
  mkdir -p app/accounts/migrations app/courses/migrations app/settingsapp/migrations app/payments/migrations app/tickets/migrations
  touch app/educms/__init__.py app/accounts/__init__.py app/courses/__init__.py app/settingsapp/__init__.py app/payments/__init__.py app/tickets/__init__.py
  touch app/accounts/migrations/__init__.py app/courses/migrations/__init__.py app/settingsapp/migrations/__init__.py app/payments/migrations/__init__.py app/tickets/migrations/__init__.py

  cat > app/manage.py <<'PY'
#!/usr/bin/env python
import os, sys
def main():
    os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'educms.settings')
    from django.core.management import execute_from_command_line
    execute_from_command_line(sys.argv)
if __name__ == '__main__':
    main()
PY

  cat > app/educms/settings.py <<'PY'
from pathlib import Path
import os

BASE_DIR = Path(__file__).resolve().parent.parent

SECRET_KEY = os.getenv("DJANGO_SECRET_KEY", "dev-secret")
DEBUG = os.getenv("DJANGO_DEBUG", "False").lower() == "true"

ALLOWED_HOSTS = [h.strip() for h in os.getenv("DJANGO_ALLOWED_HOSTS", "localhost").split(",") if h.strip()]

INSTALLED_APPS = [
    "django.contrib.admin","django.contrib.auth","django.contrib.contenttypes","django.contrib.sessions",
    "django.contrib.messages","django.contrib.staticfiles",
    "accounts.apps.AccountsConfig",
    "courses.apps.CoursesConfig",
    "settingsapp.apps.SettingsappConfig",
    "payments.apps.PaymentsConfig",
    "tickets.apps.TicketsConfig",
]

MIDDLEWARE = [
    "django.middleware.security.SecurityMiddleware",
    "django.contrib.sessions.middleware.SessionMiddleware",
    "django.middleware.locale.LocaleMiddleware",
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

LANGUAGE_CODE = "fa"
USE_I18N = True
LANGUAGES = [("fa","فارسی"), ("en","English")]
TIME_ZONE = "Asia/Tehran"
USE_TZ = True

STATIC_URL = "/static/"
STATIC_ROOT = BASE_DIR / "staticfiles"
MEDIA_URL = "/media/"
MEDIA_ROOT = BASE_DIR / "media"

DEFAULT_AUTO_FIELD = "django.db.models.BigAutoField"

_csrf = os.getenv("CSRF_TRUSTED_ORIGINS","")
CSRF_TRUSTED_ORIGINS = [o.strip() for o in _csrf.split(",") if o.strip()]

LOGIN_URL = "/accounts/login/"
LOGIN_REDIRECT_URL = "/panel/"
LOGOUT_REDIRECT_URL = "/"
PY

  cat > app/educms/urls.py <<'PY'
from django.contrib import admin
from django.urls import path, include
from courses.views import CourseListView, CourseDetailView

urlpatterns = [
    path("admin/", admin.site.urls),
    path("accounts/", include("accounts.urls")),
    path("orders/", include("payments.urls")),
    path("tickets/", include("tickets.urls")),
    path("panel/", include("settingsapp.urls")),
    path("", CourseListView.as_view(), name="home"),
    path("courses/<slug:slug>/", CourseDetailView.as_view(), name="course_detail"),
]
PY

  cat > app/educms/wsgi.py <<'PY'
import os
from django.core.wsgi import get_wsgi_application
os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'educms.settings')
application = get_wsgi_application()
PY

  cat > app/accounts/apps.py <<'PY'
from django.apps import AppConfig
class AccountsConfig(AppConfig):
    default_auto_field = "django.db.models.BigAutoField"
    name = "accounts"
    verbose_name = "کاربران"
PY

  cat > app/accounts/models.py <<'PY'
import uuid
from django.db import models
from django.utils.translation import gettext_lazy as _
from django.contrib.auth.models import AbstractBaseUser, PermissionsMixin, BaseUserManager
from django.contrib.auth.hashers import make_password, check_password

class UserManager(BaseUserManager):
    def create_user(self, email, password=None, **extra):
        if not email:
            raise ValueError("email required")
        email = self.normalize_email(email)
        user = self.model(email=email, **extra)
        user.set_password(password)
        user.save(using=self._db)
        return user

    def create_superuser(self, email, password=None, **extra):
        extra.setdefault("is_staff", True)
        extra.setdefault("is_superuser", True)
        extra.setdefault("is_active", True)
        return self.create_user(email, password, **extra)

class User(AbstractBaseUser, PermissionsMixin):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False, verbose_name=_("شناسه"))
    email = models.EmailField(unique=True, verbose_name=_("ایمیل"))
    is_active = models.BooleanField(default=True, verbose_name=_("فعال"))
    is_staff = models.BooleanField(default=False, verbose_name=_("ادمین"))
    date_joined = models.DateTimeField(auto_now_add=True, verbose_name=_("تاریخ عضویت"))
    extra_data = models.JSONField(default=dict, blank=True, verbose_name=_("اطلاعات اضافی"))

    USERNAME_FIELD = "email"
    REQUIRED_FIELDS = []

    objects = UserManager()

    class Meta:
        verbose_name = _("کاربر")
        verbose_name_plural = _("کاربران")

    def __str__(self):
        return self.email

class SecurityQuestion(models.Model):
    text = models.CharField(max_length=300, unique=True, verbose_name=_("سوال"))
    is_active = models.BooleanField(default=True, verbose_name=_("فعال"))
    order = models.PositiveIntegerField(default=0, verbose_name=_("ترتیب"))
    class Meta:
        ordering = ["order","id"]
        verbose_name = _("سوال امنیتی")
        verbose_name_plural = _("سوال‌های امنیتی")
    def __str__(self): return self.text

class UserSecurityAnswer(models.Model):
    user = models.OneToOneField(User, on_delete=models.CASCADE, related_name="security", verbose_name=_("کاربر"))
    question = models.ForeignKey(SecurityQuestion, on_delete=models.PROTECT, verbose_name=_("سوال"))
    answer_hash = models.CharField(max_length=255, verbose_name=_("هش پاسخ"))
    updated_at = models.DateTimeField(auto_now=True, verbose_name=_("آخرین بروزرسانی"))

    class Meta:
        verbose_name = _("امنیت کاربر")
        verbose_name_plural = _("امنیت کاربران")

    def set_answer(self, raw_answer: str):
        self.answer_hash = make_password((raw_answer or "").strip())

    def verify_answer(self, raw_answer: str) -> bool:
        return check_password((raw_answer or "").strip(), self.answer_hash)

class RegistrationField(models.Model):
    TYPE_TEXT = "text"
    TYPE_EMAIL = "email"
    TYPE_NUMBER = "number"
    TYPE_TEXTAREA = "textarea"
    TYPE_DATE = "date"
    TYPE_SELECT = "select"
    FIELD_TYPES = (
        (TYPE_TEXT, _("متن")),
        (TYPE_EMAIL, _("ایمیل")),
        (TYPE_NUMBER, _("عدد")),
        (TYPE_TEXTAREA, _("متن چندخطی")),
        (TYPE_DATE, _("تاریخ")),
        (TYPE_SELECT, _("انتخابی")),
    )

    key = models.SlugField(max_length=60, unique=True, verbose_name=_("کلید"))
    label = models.CharField(max_length=120, verbose_name=_("نام فیلد"))
    field_type = models.CharField(max_length=20, choices=FIELD_TYPES, default=TYPE_TEXT, verbose_name=_("نوع"))
    required = models.BooleanField(default=True, verbose_name=_("اجباری"))
    is_active = models.BooleanField(default=True, verbose_name=_("فعال"))
    order = models.PositiveIntegerField(default=0, verbose_name=_("ترتیب"))
    is_system = models.BooleanField(default=False, verbose_name=_("سیستمی"))
    choices_text = models.TextField(blank=True, verbose_name=_("گزینه‌ها (هر خط یک گزینه)"))

    class Meta:
        ordering = ["order","id"]
        verbose_name = _("فیلد ثبت‌نام")
        verbose_name_plural = _("فیلدهای ثبت‌نام")

    def __str__(self):
        return f"{self.label} ({self.key})"
PY

  cat > app/accounts/admin.py <<'PY'
from django.contrib import admin
from django.contrib.auth.admin import UserAdmin as BaseUserAdmin
from django.utils.translation import gettext_lazy as _
from .models import User, SecurityQuestion, UserSecurityAnswer, RegistrationField

class UserSecurityInline(admin.StackedInline):
    model = UserSecurityAnswer
    extra = 0

@admin.register(User)
class UserAdmin(BaseUserAdmin):
    ordering = ("email",)
    list_display = ("email","is_staff","is_active","date_joined")
    list_filter = ("is_staff","is_active")
    search_fields = ("email",)
    fieldsets = (
        (None, {"fields": ("email","password")}),
        (_("Permissions"), {"fields": ("is_active","is_staff","is_superuser","groups","user_permissions")}),
        (_("Extra"), {"fields": ("extra_data",)}),
    )
    add_fieldsets = (
        (None, {"classes": ("wide",), "fields": ("email","password1","password2","is_staff","is_superuser","is_active")}),
    )
    filter_horizontal = ("groups","user_permissions")
    inlines = [UserSecurityInline]

@admin.register(SecurityQuestion)
class SecurityQuestionAdmin(admin.ModelAdmin):
    list_display = ("text","is_active","order")
    list_editable = ("is_active","order")
    search_fields = ("text",)

@admin.register(RegistrationField)
class RegistrationFieldAdmin(admin.ModelAdmin):
    list_display = ("label","key","field_type","required","is_active","order","is_system")
    list_editable = ("required","is_active","order")
    list_display_links = ("label",)
    search_fields = ("label","key")

    def has_delete_permission(self, request, obj=None):
        if obj and getattr(obj, "is_system", False):
            return False
        return super().has_delete_permission(request, obj=obj)

    def save_model(self, request, obj, form, change):
        if obj.is_system:
            obj.is_active = True
        super().save_model(request, obj, form, change)
PY

  cat > app/accounts/forms.py <<'PY'
from django import forms
from django.utils.translation import gettext_lazy as _
from django.contrib.auth import get_user_model
from .models import SecurityQuestion, RegistrationField
User = get_user_model()

def _choices_from_text(txt: str):
    out = []
    for line in (txt or "").splitlines():
        v = line.strip()
        if v:
            out.append((v, v))
    return out

class DynamicRegisterForm(forms.Form):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)

        fields = list(RegistrationField.objects.filter(is_active=True).order_by("order","id"))
        for f in fields:
            if f.key in self.fields:
                continue

            if f.field_type == RegistrationField.TYPE_EMAIL:
                self.fields[f.key] = forms.EmailField(label=f.label, required=f.required)
            elif f.field_type == RegistrationField.TYPE_NUMBER:
                self.fields[f.key] = forms.IntegerField(label=f.label, required=f.required)
            elif f.field_type == RegistrationField.TYPE_TEXTAREA:
                self.fields[f.key] = forms.CharField(label=f.label, required=f.required, widget=forms.Textarea(attrs={"rows": 4}))
            elif f.field_type == RegistrationField.TYPE_DATE:
                self.fields[f.key] = forms.DateField(label=f.label, required=f.required, widget=forms.DateInput(attrs={"type":"date"}))
            elif f.field_type == RegistrationField.TYPE_SELECT:
                self.fields[f.key] = forms.ChoiceField(label=f.label, required=f.required, choices=_choices_from_text(f.choices_text))
            else:
                self.fields[f.key] = forms.CharField(label=f.label, required=f.required)

        if "password1" in self.fields:
            self.fields["password1"].widget = forms.PasswordInput()
        if "password2" in self.fields:
            self.fields["password2"].widget = forms.PasswordInput()
        if "security_answer" in self.fields:
            self.fields["security_answer"].widget = forms.PasswordInput(render_value=True)

    def clean(self):
        c = super().clean()
        p1 = c.get("password1")
        p2 = c.get("password2")
        if p1 or p2:
            if p1 != p2:
                raise forms.ValidationError(_("گذرواژه و تکرار گذرواژه یکسان نیستند."))
            if p1 and len(p1) < 6:
                raise forms.ValidationError(_("گذرواژه باید حداقل ۶ کاراکتر باشد."))
        return c

class LoginForm(forms.Form):
    email = forms.EmailField(label=_("ایمیل"))
    password = forms.CharField(label=_("گذرواژه"), widget=forms.PasswordInput)

class ForgotPasswordStartForm(forms.Form):
    email = forms.EmailField(label=_("ایمیل"))

class ForgotPasswordResetForm(forms.Form):
    answer = forms.CharField(label=_("پاسخ سوال امنیتی"), widget=forms.PasswordInput)
    password1 = forms.CharField(label=_("گذرواژه جدید"), widget=forms.PasswordInput)
    password2 = forms.CharField(label=_("تکرار گذرواژه جدید"), widget=forms.PasswordInput)

    def clean(self):
        c = super().clean()
        if c.get("password1") != c.get("password2"):
            raise forms.ValidationError(_("گذرواژه‌ها یکسان نیستند."))
        if c.get("password1") and len(c.get("password1")) < 6:
            raise forms.ValidationError(_("گذرواژه باید حداقل ۶ کاراکتر باشد."))
        return c
PY

  cat > app/accounts/views.py <<'PY'
from django.contrib import messages
from django.contrib.auth import authenticate, login, logout, get_user_model
from django.shortcuts import render, redirect, get_object_or_404
from django.views.decorators.http import require_http_methods
from django.db import transaction

from settingsapp.models import SiteSetting
from .models import SecurityQuestion, UserSecurityAnswer, RegistrationField
from .forms import DynamicRegisterForm, LoginForm, ForgotPasswordStartForm, ForgotPasswordResetForm

User = get_user_model()

def _site():
    return SiteSetting.objects.first() or SiteSetting.objects.create()

@require_http_methods(["GET","POST"])
def register_view(request):
    form = DynamicRegisterForm(request.POST or None)
    if request.method == "POST" and form.is_valid():
        data = form.cleaned_data.copy()
        email = (data.get("email") or "").strip().lower()
        password = data.get("password1")
        q_id = data.get("security_question")
        ans = data.get("security_answer")

        if not email:
            messages.error(request, "ایمیل الزامی است.")
            return render(request, "accounts/register.html", {"form": form})

        if User.objects.filter(email=email).exists():
            messages.error(request, "این ایمیل قبلاً ثبت شده است.")
            return render(request, "accounts/register.html", {"form": form})

        with transaction.atomic():
            user = User.objects.create_user(email=email, password=password, is_active=True)
            extra = {}
            for k,v in data.items():
                if k in ("email","password1","password2","security_question","security_answer"):
                    continue
                extra[k] = v
            user.extra_data = extra
            user.save(update_fields=["extra_data"])

            question = get_object_or_404(SecurityQuestion, id=q_id, is_active=True)
            sec = UserSecurityAnswer.objects.create(user=user, question=question, answer_hash="x")
            sec.set_answer(ans or "")
            sec.save(update_fields=["answer_hash"])

        messages.success(request, "ثبت‌نام با موفقیت انجام شد. لطفاً وارد شوید.")
        return redirect("login")
    return render(request, "accounts/register.html", {"form": form})

@require_http_methods(["GET","POST"])
def login_view(request):
    form = LoginForm(request.POST or None)
    if request.method == "POST" and form.is_valid():
        email = form.cleaned_data["email"].strip().lower()
        password = form.cleaned_data["password"]
        user = authenticate(request, email=email, password=password)
        if user is None:
            messages.error(request, "اطلاعات ورود صحیح نیست.")
            return render(request, "accounts/login.html", {"form": form})
        login(request, user)
        return redirect("/panel/")
    return render(request, "accounts/login.html", {"form": form})

@require_http_methods(["POST"])
def logout_view(request):
    logout(request)
    return redirect("/")

@require_http_methods(["GET","POST"])
def forgot_start(request):
    form = ForgotPasswordStartForm(request.POST or None)
    if request.method == "POST" and form.is_valid():
        email = form.cleaned_data["email"].strip().lower()
        u = User.objects.filter(email=email).first()
        if not u or not hasattr(u, "security"):
            messages.error(request, "کاربری با این ایمیل یافت نشد.")
            return render(request, "accounts/forgot_start.html", {"form": form})
        request.session["fp_email"] = email
        return redirect("forgot_reset")
    return render(request, "accounts/forgot_start.html", {"form": form})

@require_http_methods(["GET","POST"])
def forgot_reset(request):
    email = request.session.get("fp_email")
    if not email:
        return redirect("forgot_start")
    u = User.objects.filter(email=email).first()
    if not u or not hasattr(u, "security"):
        messages.error(request, "اطلاعات کاربر معتبر نیست.")
        return redirect("forgot_start")

    sec = u.security
    form = ForgotPasswordResetForm(request.POST or None)
    if request.method == "POST" and form.is_valid():
        if not sec.verify_answer(form.cleaned_data["answer"]):
            messages.error(request, "پاسخ سوال امنیتی اشتباه است.")
            return render(request, "accounts/forgot_reset.html", {"form": form, "question": sec.question.text})

        u.set_password(form.cleaned_data["password1"])
        u.save(update_fields=["password"])
        request.session.pop("fp_email", None)
        messages.success(request, "گذرواژه با موفقیت تغییر کرد. وارد شوید.")
        return redirect("login")

    return render(request, "accounts/forgot_reset.html", {"form": form, "question": sec.question.text})

@require_http_methods(["GET","POST"])
def security_edit(request):
    if not request.user.is_authenticated:
        return redirect("login")
    s = _site()
    if not s.allow_users_edit_security:
        messages.error(request, "ویرایش سوال/پاسخ امنیتی برای کاربران غیرفعال است.")
        return redirect("/panel/")

    u = request.user
    sec = getattr(u, "security", None)
    questions = SecurityQuestion.objects.filter(is_active=True).order_by("order","id")

    if request.method == "POST":
        q_id = request.POST.get("security_question")
        ans = request.POST.get("security_answer","")
        q = questions.filter(id=q_id).first()
        if not q:
            messages.error(request, "سوال نامعتبر است.")
            return render(request, "accounts/security_edit.html", {"questions": questions, "current": sec})

        if not sec:
            sec = UserSecurityAnswer.objects.create(user=u, question=q, answer_hash="x")
        sec.question = q
        sec.set_answer(ans)
        sec.save(update_fields=["question","answer_hash"])
        messages.success(request, "بروزرسانی شد.")
        return redirect("security_edit")

    return render(request, "accounts/security_edit.html", {"questions": questions, "current": sec})
PY

  cat > app/accounts/urls.py <<'PY'
from django.urls import path
from .views import register_view, login_view, logout_view, forgot_start, forgot_reset, security_edit

urlpatterns = [
    path("register/", register_view, name="register"),
    path("login/", login_view, name="login"),
    path("logout/", logout_view, name="logout"),
    path("forgot/", forgot_start, name="forgot_start"),
    path("forgot/reset/", forgot_reset, name="forgot_reset"),
    path("security/", security_edit, name="security_edit"),
]
PY

  cat > app/accounts/backends.py <<'PY'
from django.contrib.auth.backends import ModelBackend
from django.contrib.auth import get_user_model
User = get_user_model()

class EmailBackend(ModelBackend):
    def authenticate(self, request, username=None, password=None, **kwargs):
        email = (kwargs.get("email") or username or "").strip().lower()
        if not email or password is None:
            return None
        user = User.objects.filter(email=email).first()
        if not user:
            return None
        if user.check_password(password) and self.user_can_authenticate(user):
            return user
        return None
PY

  cat > app/settingsapp/apps.py <<'PY'
from django.apps import AppConfig
class SettingsappConfig(AppConfig):
    default_auto_field = "django.db.models.BigAutoField"
    name = "settingsapp"
    verbose_name = "تنظیمات سایت"
PY

  cat > app/settingsapp/models.py <<'PY'
from django.db import models
from django.utils.translation import gettext_lazy as _

class SiteSetting(models.Model):
    brand_name = models.CharField(max_length=120, default="EduCMS", verbose_name=_("نام برند"))
    footer_text = models.TextField(blank=True, verbose_name=_("متن فوتر"))
    admin_path = models.SlugField(max_length=50, default="admin", verbose_name=_("مسیر پنل ادمین"))
    allow_profile_edit = models.BooleanField(default=True, verbose_name=_("اجازه ویرایش پروفایل توسط کاربر"))
    allow_users_edit_security = models.BooleanField(default=True, verbose_name=_("اجازه تغییر سوال/پاسخ امنیتی توسط کاربر"))
    updated_at = models.DateTimeField(auto_now=True, verbose_name=_("آخرین بروزرسانی"))

    class Meta:
        verbose_name = _("تنظیمات سایت")
        verbose_name_plural = _("تنظیمات سایت")

    def __str__(self): return "Site Settings"
PY

  cat > app/settingsapp/context_processors.py <<'PY'
from .models import SiteSetting
def site_context(request):
    s = SiteSetting.objects.first()
    return {"site_settings": s}
PY

  cat > app/settingsapp/middleware.py <<'PY'
from django.http import HttpResponseNotFound
from django.utils.deprecation import MiddlewareMixin
from django.core.cache import cache
from .models import SiteSetting

def _get_admin_path():
    key = "site_admin_path"
    v = cache.get(key)
    if v:
        return v
    s = SiteSetting.objects.first()
    v = (getattr(s, "admin_path", None) or "admin").strip().strip("/") or "admin"
    cache.set(key, v, 60)
    return v

class AdminAliasMiddleware(MiddlewareMixin):
    def process_request(self, request):
        admin_path = _get_admin_path() or "admin"

        if admin_path != "admin" and request.path.startswith("/admin"):
            return HttpResponseNotFound("Not Found")

        if request.path == f"/{admin_path}":
            request.path_info = "/admin/"
            return None

        prefix = f"/{admin_path}/"
        if admin_path != "admin" and request.path.startswith(prefix):
            tail = request.path[len(prefix):]
            request.path_info = "/admin/" + tail
            return None

        return None
PY

  cat > app/settingsapp/views.py <<'PY'
from django.contrib.auth.decorators import login_required
from django.contrib import messages
from django.shortcuts import render, redirect
from django.contrib.auth import update_session_auth_hash
from django.core.cache import cache

from .models import SiteSetting
from accounts.models import UserSecurityAnswer, SecurityQuestion
from accounts.forms import ForgotPasswordResetForm

@login_required
def panel_home(request):
    return render(request, "settings/panel_home.html")

@login_required
def profile_edit(request):
    s = SiteSetting.objects.first() or SiteSetting.objects.create()
    if not s.allow_profile_edit:
        messages.error(request, "ویرایش پروفایل غیرفعال است.")
        return redirect("panel_home")

    u = request.user
    if request.method == "POST":
        data = u.extra_data or {}
        for k,v in request.POST.items():
            if k.startswith("x_"):
                data[k[2:]] = v
        u.extra_data = data
        u.save(update_fields=["extra_data"])
        messages.success(request, "ذخیره شد.")
        return redirect("profile_edit")

    return render(request, "settings/profile_edit.html", {"extra": (request.user.extra_data or {})})

@login_required
def password_change(request):
    form = ForgotPasswordResetForm(request.POST or None)
    if request.method == "POST" and form.is_valid():
        request.user.set_password(form.cleaned_data["password1"])
        request.user.save(update_fields=["password"])
        update_session_auth_hash(request, request.user)
        messages.success(request, "گذرواژه تغییر کرد.")
        return redirect("password_change")
    return render(request, "settings/password_change.html", {"form": form})

@login_required
def admin_path_settings(request):
    if not request.user.is_staff:
        return redirect("panel_home")
    s = SiteSetting.objects.first() or SiteSetting.objects.create()
    if request.method == "POST":
        p = (request.POST.get("admin_path","") or "admin").strip().strip("/") or "admin"
        s.admin_path = p
        s.save(update_fields=["admin_path"])
        cache.delete("site_admin_path")
        messages.success(request, f"مسیر پنل ادمین تغییر کرد: /{p}/")
        return redirect("admin_path_settings")
    return render(request, "settings/admin_path.html", {"current": s.admin_path})

@login_required
def toggles_settings(request):
    if not request.user.is_staff:
        return redirect("panel_home")
    s = SiteSetting.objects.first() or SiteSetting.objects.create()
    if request.method == "POST":
        s.allow_profile_edit = (request.POST.get("allow_profile_edit") == "on")
        s.allow_users_edit_security = (request.POST.get("allow_users_edit_security") == "on")
        s.save(update_fields=["allow_profile_edit","allow_users_edit_security"])
        messages.success(request, "تنظیمات ذخیره شد.")
        return redirect("toggles_settings")
    return render(request, "settings/toggles.html", {"s": s})
PY

  cat > app/settingsapp/urls.py <<'PY'
from django.urls import path
from .views import panel_home, profile_edit, password_change, admin_path_settings, toggles_settings

urlpatterns = [
    path("", panel_home, name="panel_home"),
    path("profile/", profile_edit, name="profile_edit"),
    path("password/", password_change, name="password_change"),
    path("admin-path/", admin_path_settings, name="admin_path_settings"),
    path("toggles/", toggles_settings, name="toggles_settings"),
]
PY

  cat > app/settingsapp/admin.py <<'PY'
from django.contrib import admin
from .models import SiteSetting
@admin.register(SiteSetting)
class SiteSettingAdmin(admin.ModelAdmin):
    list_display = ("brand_name","admin_path","allow_profile_edit","allow_users_edit_security","updated_at")
    list_editable = ("admin_path","allow_profile_edit","allow_users_edit_security")
    list_display_links = ("brand_name",)
PY

  cat > app/courses/apps.py <<'PY'
from django.apps import AppConfig
class CoursesConfig(AppConfig):
    default_auto_field = "django.db.models.BigAutoField"
    name = "courses"
    verbose_name = "دوره‌ها"
PY

  cat > app/courses/models.py <<'PY'
import uuid
from django.db import models
from django.utils.text import slugify
from django.utils.translation import gettext_lazy as _
from django.conf import settings

class PublishStatus(models.TextChoices):
    DRAFT = "draft", _("پیش‌نویس")
    PUBLISHED = "published", _("منتشر شده")

class Category(models.Model):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    title = models.CharField(max_length=120, unique=True, verbose_name=_("عنوان"))
    slug = models.SlugField(max_length=140, unique=True, blank=True, verbose_name=_("اسلاگ"))
    def save(self,*a,**k):
        if not self.slug:
            self.slug = slugify(self.title, allow_unicode=True)
        return super().save(*a,**k)
    class Meta:
        verbose_name = _("دسته‌بندی")
        verbose_name_plural = _("دسته‌بندی‌ها")
    def __str__(self): return self.title

class Course(models.Model):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    owner = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.PROTECT, verbose_name=_("مالک"))
    category = models.ForeignKey(Category, on_delete=models.SET_NULL, null=True, blank=True, verbose_name=_("دسته‌بندی"))
    title = models.CharField(max_length=200, verbose_name=_("عنوان"))
    slug = models.SlugField(max_length=220, unique=True, blank=True, verbose_name=_("اسلاگ"))
    summary = models.TextField(blank=True, verbose_name=_("خلاصه"))
    description = models.TextField(blank=True, verbose_name=_("توضیحات"))
    price_toman = models.PositiveIntegerField(default=0, verbose_name=_("قیمت (تومان)"))
    is_free_for_all = models.BooleanField(default=False, verbose_name=_("رایگان برای همه"))
    status = models.CharField(max_length=20, choices=PublishStatus.choices, default=PublishStatus.DRAFT, verbose_name=_("وضعیت"))
    updated_at = models.DateTimeField(auto_now=True)
    def save(self,*a,**k):
        if not self.slug:
            self.slug = slugify(self.title, allow_unicode=True)
        return super().save(*a,**k)
    class Meta:
        verbose_name = _("دوره")
        verbose_name_plural = _("دوره‌ها")
    def __str__(self): return self.title

class Enrollment(models.Model):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    user = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, verbose_name=_("کاربر"))
    course = models.ForeignKey(Course, on_delete=models.CASCADE, verbose_name=_("دوره"))
    is_active = models.BooleanField(default=True, verbose_name=_("فعال"))
    class Meta:
        unique_together = [("user","course")]
        verbose_name = _("ثبت‌نام")
        verbose_name_plural = _("ثبت‌نام‌ها")
PY

  cat > app/courses/views.py <<'PY'
from django.views.generic import ListView, DetailView
from .models import Course, PublishStatus

class CourseListView(ListView):
    template_name = "courses/course_list.html"
    paginate_by = 12
    def get_queryset(self):
        return Course.objects.filter(status=PublishStatus.PUBLISHED).select_related("owner","category").order_by("-updated_at")

class CourseDetailView(DetailView):
    template_name = "courses/course_detail.html"
    model = Course
    slug_field = "slug"
    slug_url_kwarg = "slug"
PY

  cat > app/courses/admin.py <<'PY'
from django.contrib import admin
from .models import Category, Course, Enrollment
@admin.register(Category)
class CategoryAdmin(admin.ModelAdmin):
    list_display=("title","slug")
    search_fields=("title","slug")
@admin.register(Course)
class CourseAdmin(admin.ModelAdmin):
    list_display=("title","status","price_toman","is_free_for_all","updated_at")
    list_filter=("status","is_free_for_all")
    search_fields=("title","summary","description")
admin.site.register(Enrollment)
PY

  cat > app/payments/apps.py <<'PY'
from django.apps import AppConfig
class PaymentsConfig(AppConfig):
    default_auto_field = "django.db.models.BigAutoField"
    name = "payments"
    verbose_name = "سفارش‌ها"
PY

  cat > app/payments/models.py <<'PY'
import uuid
from django.db import models
from django.utils.translation import gettext_lazy as _
from django.conf import settings
from courses.models import Course

class OrderStatus(models.TextChoices):
    PENDING = "pending", _("در انتظار پرداخت")
    VERIFY = "verify", _("در انتظار تایید")
    PAID = "paid", _("پرداخت شده")
    REJECTED = "rejected", _("رد شده")

class Order(models.Model):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    user = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, verbose_name=_("کاربر"))
    course = models.ForeignKey(Course, on_delete=models.PROTECT, verbose_name=_("دوره"))
    amount = models.PositiveIntegerField(default=0, verbose_name=_("مبلغ"))
    status = models.CharField(max_length=20, choices=OrderStatus.choices, default=OrderStatus.PENDING, verbose_name=_("وضعیت"))
    receipt_image = models.ImageField(upload_to="receipts/", blank=True, null=True, verbose_name=_("رسید"))
    tracking_code = models.CharField(max_length=80, blank=True, verbose_name=_("کد پیگیری"))
    created_at = models.DateTimeField(auto_now_add=True)
    class Meta:
        ordering=["-created_at"]
        verbose_name=_("سفارش")
        verbose_name_plural=_("سفارش‌ها")
PY

  cat > app/payments/views.py <<'PY'
from django.contrib.auth.decorators import login_required
from django.shortcuts import render
from .models import Order

@login_required
def my_orders(request):
    orders = Order.objects.filter(user=request.user)
    return render(request, "orders/my_orders.html", {"orders": orders})
PY

  cat > app/payments/urls.py <<'PY'
from django.urls import path
from .views import my_orders
urlpatterns = [
    path("my/", my_orders, name="orders_my"),
]
PY

  cat > app/payments/admin.py <<'PY'
from django.contrib import admin
from .models import Order
@admin.register(Order)
class OrderAdmin(admin.ModelAdmin):
    list_display=("id","user","course","amount","status","created_at")
    list_filter=("status","created_at")
    search_fields=("user__email","course__title","tracking_code")
PY

  cat > app/tickets/apps.py <<'PY'
from django.apps import AppConfig
class TicketsConfig(AppConfig):
    default_auto_field = "django.db.models.BigAutoField"
    name = "tickets"
    verbose_name = "تیکت‌ها"
PY

  cat > app/tickets/models.py <<'PY'
import uuid
from django.db import models
from django.utils.translation import gettext_lazy as _
from django.conf import settings

class Ticket(models.Model):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    user = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, verbose_name=_("کاربر"))
    subject = models.CharField(max_length=200, verbose_name=_("موضوع"))
    description = models.TextField(verbose_name=_("توضیحات"))
    created_at = models.DateTimeField(auto_now_add=True)
    class Meta:
        ordering=["-created_at"]
        verbose_name=_("تیکت")
        verbose_name_plural=_("تیکت‌ها")
PY

  cat > app/tickets/forms.py <<'PY'
from django import forms
from .models import Ticket
from django.utils.translation import gettext_lazy as _
class TicketCreateForm(forms.ModelForm):
    class Meta:
        model = Ticket
        fields = ("subject","description")
        labels = {"subject": _("موضوع"), "description": _("توضیحات")}
PY

  cat > app/tickets/views.py <<'PY'
from django.contrib.auth.decorators import login_required
from django.shortcuts import render, redirect
from django.contrib import messages
from .models import Ticket
from .forms import TicketCreateForm

@login_required
def ticket_list(request):
    tickets = Ticket.objects.filter(user=request.user)
    return render(request, "tickets/list.html", {"tickets": tickets})

@login_required
def ticket_create(request):
    form = TicketCreateForm(request.POST or None)
    if request.method == "POST" and form.is_valid():
        t = form.save(commit=False)
        t.user = request.user
        t.save()
        messages.success(request, "تیکت ثبت شد.")
        return redirect("ticket_list")
    return render(request, "tickets/create.html", {"form": form})
PY

  cat > app/tickets/urls.py <<'PY'
from django.urls import path
from .views import ticket_list, ticket_create
urlpatterns = [
    path("", ticket_list, name="ticket_list"),
    path("new/", ticket_create, name="ticket_create"),
]
PY

  cat > app/tickets/admin.py <<'PY'
from django.contrib import admin
from .models import Ticket
@admin.register(Ticket)
class TicketAdmin(admin.ModelAdmin):
    list_display=("id","user","subject","created_at")
    search_fields=("user__email","subject","description")
PY

  cat > app/templates/base.html <<'HTML'
{% load static %}
<!doctype html>
<html lang="fa" dir="rtl">
<head>
  <meta charset="utf-8"/>
  <meta name="viewport" content="width=device-width,initial-scale=1"/>
  <script src="https://cdn.tailwindcss.com"></script>
  <title>{% block title %}{{ site_settings.brand_name|default:"EduCMS" }}{% endblock %}</title>
</head>
<body class="bg-slate-50 text-slate-900">
  <header class="sticky top-0 z-30 bg-white/90 backdrop-blur border-b">
    <div class="max-w-6xl mx-auto px-4 py-4 flex items-center justify-between gap-3">
      <a href="/" class="font-extrabold text-xl tracking-tight">{{ site_settings.brand_name|default:"EduCMS" }}</a>
      <nav class="flex items-center gap-2 text-sm">
        <a class="px-3 py-1 rounded-xl border hover:bg-slate-100" href="/">خانه</a>
        {% if user.is_authenticated %}
          <a class="px-3 py-1 rounded-xl border hover:bg-slate-100" href="/panel/">پنل کاربری</a>
          <a class="px-3 py-1 rounded-xl border hover:bg-slate-100" href="/orders/my/">سفارش‌ها</a>
          <a class="px-3 py-1 rounded-xl border hover:bg-slate-100" href="/tickets/">تیکت‌ها</a>
          {% if user.is_staff %}
            <a class="px-3 py-1 rounded-xl border hover:bg-slate-100" href="/{{ site_settings.admin_path|default:'admin' }}/">ادمین</a>
          {% endif %}
          <form method="post" action="/accounts/logout/" class="inline">{% csrf_token %}
            <button class="px-3 py-1 rounded-xl border hover:bg-slate-100" type="submit">خروج</button>
          </form>
        {% else %}
          <a class="px-3 py-1 rounded-xl border hover:bg-slate-100" href="/accounts/login/">ورود</a>
          <a class="px-3 py-1 rounded-xl border hover:bg-slate-100" href="/accounts/register/">ثبت‌نام</a>
        {% endif %}
      </nav>
    </div>
  </header>

  <main class="max-w-6xl mx-auto px-4 py-8">
    {% if messages %}
      <div class="mb-5 space-y-2">
        {% for m in messages %}
          <div class="p-3 rounded-xl border bg-white">{{ m }}</div>
        {% endfor %}
      </div>
    {% endif %}
    {% block content %}{% endblock %}
  </main>

  <footer class="border-t bg-white">
    <div class="max-w-6xl mx-auto px-4 py-6 text-sm text-slate-600">
      {{ site_settings.footer_text|default:"© تمامی حقوق محفوظ است." }}
    </div>
  </footer>
</body>
</html>
HTML

  cat > app/templates/courses/course_list.html <<'HTML'
{% extends "base.html" %}
{% block title %}دوره‌ها - {{ site_settings.brand_name|default:"EduCMS" }}{% endblock %}
{% block content %}
  <div class="flex items-end justify-between mb-6">
    <h1 class="text-2xl font-extrabold">دوره‌های آموزشی</h1>
    <div class="text-sm text-slate-500">لیست دوره‌ها</div>
  </div>

  <div class="grid sm:grid-cols-2 lg:grid-cols-3 gap-4">
    {% for c in object_list %}
      <a href="{% url 'course_detail' c.slug %}" class="bg-white rounded-2xl border hover:shadow-md transition p-4">
        <div class="font-bold text-lg mb-2">{{ c.title }}</div>
        <div class="text-sm text-slate-600 line-clamp-2">{{ c.summary|default:"—" }}</div>
        <div class="mt-4 text-xs text-slate-500 flex justify-between">
          <span>{{ c.category.title|default:"بدون دسته" }}</span>
          <span>{% if c.is_free_for_all %}رایگان{% elif c.price_toman %}{{ c.price_toman }} تومان{% else %}رایگان{% endif %}</span>
        </div>
      </a>
    {% empty %}
      <div class="text-slate-600">هنوز دوره‌ای منتشر نشده است.</div>
    {% endfor %}
  </div>
{% endblock %}
HTML

  cat > app/templates/courses/course_detail.html <<'HTML'
{% extends "base.html" %}
{% block title %}{{ object.title }} - {{ site_settings.brand_name|default:"EduCMS" }}{% endblock %}
{% block content %}
  <div class="bg-white rounded-2xl border p-6">
    <h1 class="text-2xl font-extrabold mb-2">{{ object.title }}</h1>
    <div class="text-slate-600 mb-3">{{ object.summary }}</div>
    <div class="text-sm text-slate-500 mb-5">دسته‌بندی: {{ object.category.title|default:"بدون دسته" }}</div>
    <div class="prose max-w-none">{{ object.description|linebreaks }}</div>
  </div>
{% endblock %}
HTML

  cat > app/templates/accounts/login.html <<'HTML'
{% extends "base.html" %}
{% block title %}ورود{% endblock %}
{% block content %}
<div class="max-w-md mx-auto bg-white rounded-2xl border p-6">
  <h1 class="text-xl font-extrabold mb-4">ورود</h1>
  <form method="post" class="space-y-3">{% csrf_token %}
    {{ form.as_p }}
    <button class="w-full px-4 py-2 rounded-xl bg-slate-900 text-white">ورود</button>
  </form>
  <div class="mt-4 text-sm text-slate-600">
    <a class="underline" href="/accounts/forgot/">فراموشی گذرواژه</a>
  </div>
</div>
{% endblock %}
HTML

  cat > app/templates/accounts/register.html <<'HTML'
{% extends "base.html" %}
{% block title %}ثبت‌نام{% endblock %}
{% block content %}
<div class="max-w-md mx-auto bg-white rounded-2xl border p-6">
  <h1 class="text-xl font-extrabold mb-4">ثبت‌نام</h1>
  <form method="post" class="space-y-3">{% csrf_token %}
    {{ form.as_p }}
    <button class="w-full px-4 py-2 rounded-xl bg-slate-900 text-white">ساخت حساب</button>
  </form>
</div>
{% endblock %}
HTML

  cat > app/templates/accounts/forgot_start.html <<'HTML'
{% extends "base.html" %}
{% block title %}فراموشی گذرواژه{% endblock %}
{% block content %}
<div class="max-w-md mx-auto bg-white rounded-2xl border p-6">
  <h1 class="text-xl font-extrabold mb-4">فراموشی گذرواژه</h1>
  <form method="post" class="space-y-3">{% csrf_token %}
    {{ form.as_p }}
    <button class="w-full px-4 py-2 rounded-xl bg-slate-900 text-white">ادامه</button>
  </form>
</div>
{% endblock %}
HTML

  cat > app/templates/accounts/forgot_reset.html <<'HTML'
{% extends "base.html" %}
{% block title %}بازیابی گذرواژه{% endblock %}
{% block content %}
<div class="max-w-md mx-auto bg-white rounded-2xl border p-6">
  <h1 class="text-xl font-extrabold mb-2">بازیابی گذرواژه</h1>
  <div class="text-sm text-slate-600 mb-4">سوال امنیتی: <b>{{ question }}</b></div>
  <form method="post" class="space-y-3">{% csrf_token %}
    {{ form.as_p }}
    <button class="w-full px-4 py-2 rounded-xl bg-slate-900 text-white">ثبت گذرواژه جدید</button>
  </form>
</div>
{% endblock %}
HTML

  cat > app/templates/accounts/security_edit.html <<'HTML'
{% extends "base.html" %}
{% block title %}امنیت حساب{% endblock %}
{% block content %}
<div class="max-w-md mx-auto bg-white rounded-2xl border p-6">
  <h1 class="text-xl font-extrabold mb-4">تغییر سوال/پاسخ امنیتی</h1>
  <form method="post" class="space-y-3">{% csrf_token %}
    <label class="block text-sm font-semibold">سوال امنیتی</label>
    <select name="security_question" class="w-full border rounded-xl p-2">
      {% for q in questions %}
        <option value="{{ q.id }}" {% if current and current.question_id == q.id %}selected{% endif %}>{{ q.text }}</option>
      {% endfor %}
    </select>
    <label class="block text-sm font-semibold">پاسخ</label>
    <input name="security_answer" type="password" class="w-full border rounded-xl p-2" required>
    <button class="w-full px-4 py-2 rounded-xl bg-slate-900 text-white">ذخیره</button>
  </form>
</div>
{% endblock %}
HTML

  cat > app/templates/orders/my_orders.html <<'HTML'
{% extends "base.html" %}
{% block title %}سفارش‌های من{% endblock %}
{% block content %}
<div class="max-w-4xl mx-auto bg-white rounded-2xl border p-6">
  <h1 class="text-xl font-extrabold mb-4">سفارش‌های من</h1>
  <div class="space-y-3">
    {% for o in orders %}
      <div class="p-4 rounded-xl border">
        <div class="text-sm">دوره: <b>{{ o.course.title }}</b></div>
        <div class="text-sm text-slate-600">مبلغ: {{ o.amount }} تومان</div>
        <div class="text-sm">وضعیت: <b>{{ o.get_status_display }}</b></div>
      </div>
    {% empty %}
      <div class="text-slate-600">سفارشی ندارید.</div>
    {% endfor %}
  </div>
</div>
{% endblock %}
HTML

  cat > app/templates/tickets/list.html <<'HTML'
{% extends "base.html" %}
{% block title %}تیکت‌ها{% endblock %}
{% block content %}
<div class="max-w-4xl mx-auto bg-white rounded-2xl border p-6">
  <div class="flex items-center justify-between mb-4">
    <h1 class="text-xl font-extrabold">تیکت‌های من</h1>
    <a class="px-4 py-2 rounded-xl bg-slate-900 text-white" href="/tickets/new/">ثبت تیکت</a>
  </div>
  <div class="space-y-3">
    {% for t in tickets %}
      <div class="p-4 rounded-xl border">
        <div class="font-semibold">{{ t.subject }}</div>
        <div class="text-sm text-slate-500">{{ t.created_at }}</div>
        <div class="mt-2 text-slate-700 whitespace-pre-line">{{ t.description }}</div>
      </div>
    {% empty %}
      <div class="text-slate-600">تیکتی ندارید.</div>
    {% endfor %}
  </div>
</div>
{% endblock %}
HTML

  cat > app/templates/tickets/create.html <<'HTML'
{% extends "base.html" %}
{% block title %}ثبت تیکت{% endblock %}
{% block content %}
<div class="max-w-2xl mx-auto bg-white rounded-2xl border p-6">
  <h1 class="text-xl font-extrabold mb-4">ثبت تیکت</h1>
  <form method="post" class="space-y-3">{% csrf_token %}
    {{ form.as_p }}
    <button class="w-full px-4 py-2 rounded-xl bg-slate-900 text-white">ثبت</button>
  </form>
</div>
{% endblock %}
HTML

  cat > app/templates/settings/panel_home.html <<'HTML'
{% extends "base.html" %}
{% block title %}پنل کاربری{% endblock %}
{% block content %}
<div class="max-w-4xl mx-auto bg-white rounded-2xl border p-6">
  <h1 class="text-xl font-extrabold mb-4">پنل کاربری</h1>
  <div class="grid sm:grid-cols-2 gap-3">
    <a class="p-4 rounded-2xl border hover:shadow-sm" href="/orders/my/">
      <div class="font-bold">سفارش‌ها</div>
      <div class="text-sm text-slate-600 mt-1">مشاهده سفارش‌های شما</div>
    </a>
    <a class="p-4 rounded-2xl border hover:shadow-sm" href="/tickets/">
      <div class="font-bold">تیکت‌ها</div>
      <div class="text-sm text-slate-600 mt-1">پشتیبانی و ارتباط</div>
    </a>
    <a class="p-4 rounded-2xl border hover:shadow-sm" href="/panel/profile/">
      <div class="font-bold">پروفایل</div>
      <div class="text-sm text-slate-600 mt-1">ویرایش اطلاعات</div>
    </a>
    <a class="p-4 rounded-2xl border hover:shadow-sm" href="/panel/password/">
      <div class="font-bold">تغییر گذرواژه</div>
      <div class="text-sm text-slate-600 mt-1">به‌روزرسانی امنیت</div>
    </a>
    <a class="p-4 rounded-2xl border hover:shadow-sm" href="/accounts/security/">
      <div class="font-bold">امنیت حساب</div>
      <div class="text-sm text-slate-600 mt-1">سوال و پاسخ امنیتی</div>
    </a>
    {% if user.is_staff %}
    <a class="p-4 rounded-2xl border hover:shadow-sm" href="/panel/admin-path/">
      <div class="font-bold">مسیر ادمین</div>
      <div class="text-sm text-slate-600 mt-1">تغییر مسیر پنل</div>
    </a>
    <a class="p-4 rounded-2xl border hover:shadow-sm" href="/panel/toggles/">
      <div class="font-bold">تنظیمات دسترسی‌ها</div>
      <div class="text-sm text-slate-600 mt-1">فعال/غیرفعال کردن امکانات</div>
    </a>
    {% endif %}
  </div>
</div>
{% endblock %}
HTML

  cat > app/templates/settings/profile_edit.html <<'HTML'
{% extends "base.html" %}
{% block title %}پروفایل{% endblock %}
{% block content %}
<div class="max-w-2xl mx-auto bg-white rounded-2xl border p-6">
  <h1 class="text-xl font-extrabold mb-4">پروفایل</h1>
  <form method="post" class="space-y-3">{% csrf_token %}
    <div class="text-sm text-slate-600">اطلاعات سفارشی (در صورت نیاز):</div>
    <input class="w-full border rounded-xl p-2" name="x_note" placeholder="یادداشت" value="{{ extra.note|default:'' }}">
    <button class="w-full px-4 py-2 rounded-xl bg-slate-900 text-white">ذخیره</button>
  </form>
</div>
{% endblock %}
HTML

  cat > app/templates/settings/password_change.html <<'HTML'
{% extends "base.html" %}
{% block title %}تغییر گذرواژه{% endblock %}
{% block content %}
<div class="max-w-md mx-auto bg-white rounded-2xl border p-6">
  <h1 class="text-xl font-extrabold mb-4">تغییر گذرواژه</h1>
  <form method="post" class="space-y-3">{% csrf_token %}
    {{ form.as_p }}
    <button class="w-full px-4 py-2 rounded-xl bg-slate-900 text-white">ذخیره</button>
  </form>
</div>
{% endblock %}
HTML

  cat > app/templates/settings/admin_path.html <<'HTML'
{% extends "base.html" %}
{% block title %}تغییر مسیر ادمین{% endblock %}
{% block content %}
<div class="max-w-md mx-auto bg-white rounded-2xl border p-6">
  <h1 class="text-xl font-extrabold mb-2">تغییر مسیر پنل ادمین</h1>
  <div class="text-sm text-slate-600 mb-4">مسیر فعلی: <b>/{{ current }}/</b></div>
  <form method="post" class="space-y-3">{% csrf_token %}
    <input class="w-full border rounded-xl p-2" name="admin_path" placeholder="مثلاً myadmin" required>
    <button class="w-full px-4 py-2 rounded-xl bg-slate-900 text-white">ذخیره</button>
  </form>
</div>
{% endblock %}
HTML

  cat > app/templates/settings/toggles.html <<'HTML'
{% extends "base.html" %}
{% block title %}تنظیمات دسترسی‌ها{% endblock %}
{% block content %}
<div class="max-w-md mx-auto bg-white rounded-2xl border p-6">
  <h1 class="text-xl font-extrabold mb-4">تنظیمات</h1>
  <form method="post" class="space-y-4">{% csrf_token %}
    <label class="flex items-center justify-between gap-3">
      <span class="text-sm font-semibold">اجازه ویرایش پروفایل توسط کاربر</span>
      <input type="checkbox" name="allow_profile_edit" {% if s.allow_profile_edit %}checked{% endif %}>
    </label>
    <label class="flex items-center justify-between gap-3">
      <span class="text-sm font-semibold">اجازه تغییر سوال/پاسخ امنیتی توسط کاربر</span>
      <input type="checkbox" name="allow_users_edit_security" {% if s.allow_users_edit_security %}checked{% endif %}>
    </label>
    <button class="w-full px-4 py-2 rounded-xl bg-slate-900 text-white">ذخیره</button>
  </form>
</div>
{% endblock %}
HTML

  mkdir -p app/templates/admin
  cat > app/templates/admin/base_site.html <<'HTML'
{% extends "admin/base.html" %}
{% load i18n %}
{% block extrahead %}
{{ block.super }}
<style>
  :root{ color-scheme: light dark; }
  body{ font-family: system-ui, -apple-system, Segoe UI, Roboto, Arial, sans-serif; }
  @media (prefers-color-scheme: dark){
    body{ background:#0b1220; }
  }
  .theme-toggle{
    display:inline-flex; gap:.5rem; align-items:center;
    padding:.35rem .6rem; border:1px solid rgba(120,120,120,.35); border-radius:999px;
    font-size:12px; cursor:pointer; user-select:none;
  }
</style>
<script>
(function(){
  function setMode(mode){
    document.documentElement.dataset.theme = mode;
    localStorage.setItem("admin_theme", mode);
    if(mode==="dark"){ document.documentElement.classList.add("admin-dark"); }
    else{ document.documentElement.classList.remove("admin-dark"); }
  }
  window.addEventListener("DOMContentLoaded", function(){
    var m = localStorage.getItem("admin_theme") || "system";
    if(m==="system"){
      var prefersDark = window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches;
      setMode(prefersDark ? "dark" : "light");
    } else {
      setMode(m);
    }
  });
  window.__toggleAdminTheme = function(){
    var cur = localStorage.getItem("admin_theme") || "system";
    var next = (cur==="dark") ? "light" : "dark";
    localStorage.setItem("admin_theme", next);
    setMode(next);
  }
})();
</script>
{% endblock %}

{% block branding %}
<h1 id="site-name">
  <a href="{% url 'admin:index' %}">پنل مدیریت</a>
  <span class="theme-toggle" onclick="__toggleAdminTheme()">تغییر تم</span>
</h1>
{% endblock %}
HTML

  cat > app/entrypoint.sh <<'SH'
#!/usr/bin/env sh
set -e

python -c "import os; print('Starting EduCMS...')"

python manage.py migrate --noinput || python manage.py migrate --fake-initial --noinput

python manage.py shell <<'PY'
import os
from django.contrib.auth import get_user_model
from settingsapp.models import SiteSetting
from accounts.models import SecurityQuestion, RegistrationField

User = get_user_model()

admin_email = (os.getenv("ADMIN_EMAIL") or "").strip().lower()
admin_pass = os.getenv("ADMIN_PASS") or ""
initial_admin_path = (os.getenv("INITIAL_ADMIN_PATH") or "admin").strip().strip("/") or "admin"

s, _ = SiteSetting.objects.get_or_create(id=1, defaults={
    "brand_name":"EduCMS",
    "footer_text":"© تمامی حقوق محفوظ است.",
    "admin_path": initial_admin_path,
    "allow_profile_edit": True,
    "allow_users_edit_security": True,
})
if not s.admin_path:
    s.admin_path = initial_admin_path
    s.save(update_fields=["admin_path"])

u = User.objects.filter(email=admin_email).first()
if not u:
    u = User.objects.create_superuser(email=admin_email, password=admin_pass)
else:
    u.is_staff = True
    u.is_superuser = True
    u.set_password(admin_pass)
    u.save(update_fields=["is_staff","is_superuser","password"])

sys_fields = [
  ("email","ایمیل","email", True),
  ("password1","گذرواژه","text", True),
  ("password2","تکرار گذرواژه","text", True),
  ("security_question","سوال امنیتی","select", True),
  ("security_answer","پاسخ سوال امنیتی","text", True),
]
for i,(key,label,ft,req) in enumerate(sys_fields, start=1):
    f, created = RegistrationField.objects.get_or_create(key=key, defaults={
        "label": label,
        "field_type": ft,
        "required": req,
        "is_active": True,
        "order": i,
        "is_system": True,
    })
    if not created:
        if f.is_system:
            f.is_active = True
        f.save()

if RegistrationField.objects.filter(key="security_question").exists():
    qf = RegistrationField.objects.get(key="security_question")
    qf.field_type = "select"
    qf.save(update_fields=["field_type"])

if SecurityQuestion.objects.count() == 0:
    questions = [
      "نام اولین معلم شما چه بود؟",
      "نام اولین مدرسه شما چیست؟",
      "نام بهترین دوست دوران کودکی شما چیست؟",
      "نام شهر محل تولد شما چیست؟",
      "نام خیابان دوران کودکی شما چیست؟",
      "نام اولین حیوان خانگی شما چیست؟",
      "غذای مورد علاقه شما چیست؟",
      "رنگ مورد علاقه شما چیست؟",
      "نام فیلم مورد علاقه شما چیست؟",
      "نام کتاب مورد علاقه شما چیست؟",
      "نام تیم ورزشی مورد علاقه شما چیست؟",
      "نام اولین شرکت محل کار شما چیست؟",
      "نام یکی از اقوام نزدیک شما چیست؟",
      "نام دبیرستان شما چیست؟",
      "نام دانشگاه شما چیست؟",
      "نام اولین گوشی شما چه بود؟",
      "نام یک مکان خاطره‌انگیز برای شما چیست؟",
      "اسم یک شخصیت تاریخی مورد علاقه شما چیست؟",
      "نام اولین برنامه‌ای که یاد گرفتید چیست؟",
      "نام اولین بازی رایانه‌ای شما چیست؟",
      "نام یک دوست قدیمی شما چیست؟",
      "نام یکی از مربیان شما چیست؟",
      "اسم یک شهر که دوست دارید سفر کنید چیست؟",
      "نام اولین برند لپ‌تاپ شما چیست؟",
      "اسم یک آهنگ خاطره‌انگیز برای شما چیست؟",
    ]
    for i,t in enumerate(questions, start=1):
        SecurityQuestion.objects.create(text=t, is_active=True, order=i)

print("Admin ready:", u.email)
print("Admin path:", s.admin_path)
PY

python manage.py collectstatic --noinput
exec gunicorn educms.wsgi:application --bind 0.0.0.0:8000 --workers 3 --timeout 60
SH
  chmod +x app/entrypoint.sh

  cat >> app/educms/settings.py <<'PY'

AUTHENTICATION_BACKENDS = [
    "accounts.backends.EmailBackend",
]
PY

  ok "Project written."
}

issue_ssl_on_host(){
  host_certbot_install_if_needed
  mkdir -p "${APP_DIR}/certbot/www"
  if [[ -d "/etc/letsencrypt/live/${DOMAIN}" ]]; then
    step "SSL exists. Renewing (quiet)..."
    certbot renew --quiet || true
    ok "SSL ok."
    return 0
  fi
  step "Issuing SSL for ${DOMAIN}..."
  certbot certonly --webroot -w "${APP_DIR}/certbot/www" -d "${DOMAIN}" --email "${LE_EMAIL}" --agree-tos --non-interactive
  ok "SSL issued."
}

up_with_ssl(){
  step "Starting stack (HTTP)..."
  cd "${APP_DIR}"
  write_nginx_http
  docker compose up -d --build db web nginx
  ok "Stack up (HTTP)."
  issue_ssl_on_host
  step "Switching nginx to HTTPS..."
  write_nginx_https
  docker compose restart nginx
  ok "HTTPS enabled."
}

load_env_or_fail(){
  [[ -f "${ENV_FILE}" ]] || { echo -e "${RED}ERROR:${RESET} ${ENV_FILE} not found."; exit 1; }
  set -a
  . "${ENV_FILE}"
  set +a
}

compose_cd_or_fail(){
  [[ -d "${APP_DIR}" ]] || { echo -e "${RED}ERROR:${RESET} ${APP_DIR} not found."; exit 1; }
  [[ -f "${APP_DIR}/docker-compose.yml" ]] || { echo -e "${RED}ERROR:${RESET} docker-compose.yml not found in ${APP_DIR}"; exit 1; }
  cd "${APP_DIR}"
}

backup_db(){
  require_root
  load_env_or_fail
  compose_cd_or_fail
  mkdir -p "${BACKUP_DIR}"
  docker compose up -d db >/dev/null

  local ts file
  ts="$(date +%Y%m%d-%H%M%S)"
  file="${BACKUP_DIR}/${DB_NAME}-${ts}.sql"

  step "Creating DB backup: ${file}"
  docker compose exec -T db sh -lc "mysqldump -uroot -p\"${DB_PASS}\" --databases \"${DB_NAME}\" --single-transaction --quick --routines --triggers --events --set-gtid-purged=OFF" > "${file}"
  chmod 600 "${file}"
  ok "Backup created: ${file}"
}

restore_db(){
  require_root
  load_env_or_fail
  compose_cd_or_fail
  local sql_file="${1:-}"
  [[ -n "$sql_file" && -f "$sql_file" ]] || { echo -e "${RED}ERROR:${RESET} Provide existing .sql path."; exit 1; }

  echo -e "${RED}${BOLD}WARNING:${RESET} This will overwrite DB '${DB_NAME}' using: ${sql_file}"
  read -r -p "Type YES to continue: " ans </dev/tty
  [[ "${ans:-}" == "YES" ]] || { warn "Canceled."; return 0; }

  docker compose up -d db >/dev/null
  step "Dropping & recreating DB..."
  docker compose exec -T db sh -lc "mysql -uroot -p\"${DB_PASS}\" -e 'DROP DATABASE IF EXISTS \`${DB_NAME}\`; CREATE DATABASE \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;'"
  step "Importing SQL..."
  docker compose exec -T db sh -lc "mysql -uroot -p\"${DB_PASS}\" \"${DB_NAME}\"" < "${sql_file}"
  docker compose up -d web nginx >/dev/null || true
  ok "Restore completed."
}

do_install(){
  require_root; require_tty
  collect_inputs
  install_base_packages
  install_docker
  cleanup_existing_fresh_install
  ensure_dirs
  write_env
  write_compose
  write_project
  up_with_ssl
  ok "DONE."
  echo "Site:      https://${DOMAIN}"
  echo "Admin:     https://${DOMAIN}/${ADMIN_PATH}/"
  echo "Login:     https://${DOMAIN}/accounts/login/"
  echo "Register:  https://${DOMAIN}/accounts/register/"
  echo "Panel:     https://${DOMAIN}/panel/"
  echo "Orders:    https://${DOMAIN}/orders/my/"
  echo "Tickets:   https://${DOMAIN}/tickets/"
}

do_stop(){ compose_cd_or_fail; docker compose down --remove-orphans || true; ok "Stopped."; }
do_start(){ compose_cd_or_fail; docker compose up -d --build; ok "Started."; }
do_restart(){ compose_cd_or_fail; docker compose restart; ok "Restarted."; }

do_uninstall(){
  require_root; require_tty
  warn "This removes ${APP_DIR} and docker volumes."
  read -r -p "Type YES to continue: " ans </dev/tty
  [[ "${ans:-}" == "YES" ]] || { warn "Canceled."; return 0; }
  if [[ -d "${APP_DIR}" && -f "${APP_DIR}/docker-compose.yml" ]]; then
    (cd "${APP_DIR}" && docker compose down --remove-orphans --volumes) || true
  fi
  rm -rf "${APP_DIR}" || true
  ok "Uninstalled."
}

menu_header(){
  clear || true
  echo -e "${BOLD}${CYAN}============================================${RESET}"
  echo -e "${BOLD}${CYAN}                 EduCMS Menu                ${RESET}"
  echo -e "${BOLD}${CYAN}============================================${RESET}"
  echo -e "${YELLOW}Path:${RESET} ${APP_DIR}"
  echo -e "${YELLOW}Log :${RESET} ${LOG_FILE}"
  echo
}

menu_show(){
  echo -e "${GREEN}1)${RESET} Install (نصب کامل)"
  echo -e "${GREEN}2)${RESET} Stop (توقف)"
  echo -e "${GREEN}3)${RESET} Start (شروع)"
  echo -e "${GREEN}4)${RESET} Restart (ری‌استارت)"
  echo -e "${GREEN}5)${RESET} Backup DB (.sql)"
  echo -e "${GREEN}6)${RESET} Restore DB (.sql)"
  echo -e "${GREEN}7)${RESET} Uninstall (حذف کامل)"
  echo -e "${GREEN}0)${RESET} Exit"
  echo
}

main(){
  require_root; require_tty
  while true; do
    menu_header
    menu_show
    read -r -p "Select: " c </dev/tty || c=""
    case "${c:-}" in
      1) do_install ;;
      2) do_stop ;;
      3) do_start ;;
      4) do_restart ;;
      5) backup_db ;;
      6)
        p="$(read_line "Path to .sql file (e.g. /opt/educms/backups/file.sql): ")"
        restore_db "$p"
        ;;
      7) do_uninstall ;;
      0) echo -e "${CYAN}Bye.${RESET}"; exit 0 ;;
      *) warn "Invalid option." ;;
    esac
    read -r -p "Press Enter..." _ </dev/tty || true
  done
}

main
