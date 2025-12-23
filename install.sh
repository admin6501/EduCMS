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
ADMIN_USER=""
ADMIN_PASS=""
ADMIN_PATH="admin"

DB_NAME="educms"
DB_USER=""
DB_PASS=""

RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BLUE=$'\033[34m'
CYAN=$'\033[36m'; BOLD=$'\033[1m'; RESET=$'\033[0m'

require_root(){ [[ $EUID -eq 0 ]] || { echo -e "${RED}ERROR:${RESET} Run with sudo."; exit 1; }; }
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
  echo -e "${BOLD}${CYAN}=== EduCMS FULL Installer ===${RESET}"
  echo -e "${CYAN}Log:${RESET} ${LOG_FILE}"
  echo

  DOMAIN="$(read_line "Domain (e.g. example.com): ")"
  LE_EMAIL="$(read_line "Email for Let's Encrypt: ")"

  ADMIN_PATH="$(read_line "Admin path (default: admin) e.g. myadmin: ")"
  [[ -z "${ADMIN_PATH:-}" ]] && ADMIN_PATH="admin"
  ADMIN_PATH="$(printf "%s" "$ADMIN_PATH" | sed 's#^/##;s#/$##')"
  [[ -z "${ADMIN_PATH:-}" ]] && ADMIN_PATH="admin"

  local tmpdb
  tmpdb="$(read_line "Database name [default: ${DB_NAME}]: ")"
  [[ -n "${tmpdb:-}" ]] && DB_NAME="$tmpdb"

  DB_USER="$(read_line "Database username: ")"
  DB_PASS="$(read_secret "Database password (hidden): ")"

  ADMIN_USER="$(read_line "Admin username: ")"
  ADMIN_PASS="$(read_secret "Admin password (hidden): ")"

  [[ -n "$DOMAIN" && -n "$LE_EMAIL" && -n "$DB_USER" && -n "$DB_PASS" && -n "$ADMIN_USER" && -n "$ADMIN_PASS" ]] \
    || { echo -e "${RED}ERROR:${RESET} Required input is empty."; exit 1; }

  ok "Inputs collected."
}

cleanup_existing_fresh_install(){
  step "Cleaning previous install (containers/volumes/app dir)..."
  if [[ -d "${APP_DIR}" && -f "${APP_DIR}/docker-compose.yml" ]]; then
    ( cd "${APP_DIR}" && docker compose down --remove-orphans --volumes ) || warn "docker compose down failed (ignored)."
  else
    warn "No existing docker-compose.yml found. Skipping compose down."
  fi
  rm -rf "${APP_DIR}" || { echo -e "${RED}ERROR:${RESET} Cannot remove ${APP_DIR}"; exit 1; }
  ok "Cleanup done."
}

ensure_dirs(){
  step "Creating directories..."
  mkdir -p "${APP_DIR}" "${BACKUP_DIR}"
  cd "${APP_DIR}"
  mkdir -p app/templates app/static app/media nginx certbot/www certbot/conf
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
  printf "ADMIN_USER=%s\n" "${ADMIN_USER}" >> "${ENV_FILE}"
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
gunicorn>=21.2
mysqlclient>=2.2
Pillow>=10.0
REQ

  mkdir -p app/{educms,accounts,courses,settingsapp,payments,tickets}
  touch app/educms/__init__.py app/accounts/__init__.py app/courses/__init__.py app/settingsapp/__init__.py app/payments/__init__.py app/tickets/__init__.py

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
LOGIN_REDIRECT_URL = "/"
LOGOUT_REDIRECT_URL = "/"
PY

  cat > app/educms/urls.py <<'PY'
from django.contrib import admin
from django.urls import path, include
from settingsapp.admin_views import admin_account_in_admin
from courses.views import CourseListView, CourseDetailView

urlpatterns = [
    path("admin/account/", admin.site.admin_view(admin_account_in_admin), name="admin_account_in_admin"),
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
from django.contrib.auth.models import AbstractBaseUser, PermissionsMixin, BaseUserManager
from django.utils.translation import gettext_lazy as _
from django.utils import timezone
from django.contrib.auth.hashers import check_password, make_password

class UserManager(BaseUserManager):
    def create_user(self, email, password=None, **extra):
        if not email:
            raise ValueError("Email is required")
        email = self.normalize_email(email)
        user = self.model(email=email, **extra)
        user.set_password(password)
        user.save(using=self._db)
        return user

    def create_superuser(self, email, password=None, **extra):
        extra.setdefault("is_staff", True)
        extra.setdefault("is_superuser", True)
        return self.create_user(email, password, **extra)

class User(AbstractBaseUser, PermissionsMixin):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False, verbose_name=_("شناسه"))
    email = models.EmailField(unique=True, verbose_name=_("ایمیل"))
    is_active = models.BooleanField(default=True, verbose_name=_("فعال"))
    is_staff = models.BooleanField(default=False, verbose_name=_("ادمین"))
    date_joined = models.DateTimeField(default=timezone.now, verbose_name=_("تاریخ عضویت"))

    objects = UserManager()

    USERNAME_FIELD = "email"
    REQUIRED_FIELDS = []

    class Meta:
        verbose_name = _("کاربر")
        verbose_name_plural = _("کاربران")

    def __str__(self):
        return self.email

class RegistrationField(models.Model):
    class FieldType(models.TextChoices):
        TEXT = "text", _("متن")
        EMAIL = "email", _("ایمیل")
        NUMBER = "number", _("عدد")
        TEL = "tel", _("تلفن")
        DATE = "date", _("تاریخ")
        TEXTAREA = "textarea", _("متن بلند")
        SELECT = "select", _("لیست انتخابی")
        CHECKBOX = "checkbox", _("چک‌باکس")

    key = models.SlugField(max_length=60, unique=True, verbose_name=_("کلید"))
    label = models.CharField(max_length=120, verbose_name=_("نام فیلد"))
    field_type = models.CharField(max_length=20, choices=FieldType.choices, default=FieldType.TEXT, verbose_name=_("نوع"))
    is_required = models.BooleanField(default=False, verbose_name=_("اجباری"))
    is_active = models.BooleanField(default=True, verbose_name=_("فعال"))
    order = models.PositiveIntegerField(default=0, verbose_name=_("ترتیب"))
    options = models.TextField(blank=True, verbose_name=_("گزینه‌ها (هر خط یک گزینه)"))
    class Meta:
        ordering = ["order","id"]
        verbose_name = _("فیلد ثبت‌نام")
        verbose_name_plural = _("فیلدهای ثبت‌نام")

    def __str__(self):
        return self.label

class RegistrationValue(models.Model):
    user = models.ForeignKey("accounts.User", on_delete=models.CASCADE, related_name="reg_values", verbose_name=_("کاربر"))
    field = models.ForeignKey("accounts.RegistrationField", on_delete=models.CASCADE, verbose_name=_("فیلد"))
    value = models.TextField(blank=True, verbose_name=_("مقدار"))
    class Meta:
        unique_together = [("user","field")]
        verbose_name = _("مقدار فیلد ثبت‌نام")
        verbose_name_plural = _("مقادیر فیلدهای ثبت‌نام")

class SecurityQuestion(models.Model):
    question = models.CharField(max_length=220, unique=True, verbose_name=_("سوال"))
    is_active = models.BooleanField(default=True, verbose_name=_("فعال"))
    order = models.PositiveIntegerField(default=0, verbose_name=_("ترتیب"))
    class Meta:
        ordering = ["order","id"]
        verbose_name = _("سوال امنیتی")
        verbose_name_plural = _("سوال‌های امنیتی")
    def __str__(self):
        return self.question

class SecurityPolicy(models.Model):
    allow_user_change_answer = models.BooleanField(default=True, verbose_name=_("اجازه تغییر پاسخ توسط کاربر"))
    allow_user_choose_question = models.BooleanField(default=True, verbose_name=_("اجازه انتخاب سوال توسط کاربر"))
    class Meta:
        verbose_name = _("سیاست سوال امنیتی")
        verbose_name_plural = _("سیاست سوال امنیتی")

class UserSecurityAnswer(models.Model):
    user = models.OneToOneField("accounts.User", on_delete=models.CASCADE, related_name="security_answer", verbose_name=_("کاربر"))
    question = models.ForeignKey("accounts.SecurityQuestion", on_delete=models.PROTECT, verbose_name=_("سوال"))
    answer_hash = models.CharField(max_length=200, verbose_name=_("هش پاسخ"))

    class Meta:
        verbose_name = _("پاسخ سوال امنیتی")
        verbose_name_plural = _("پاسخ‌های سوال امنیتی")

    def set_answer(self, raw: str):
        raw = (raw or "").strip()
        self.answer_hash = make_password(raw)

    def verify_answer(self, raw: str) -> bool:
        return check_password((raw or "").strip(), self.answer_hash or "")
PY

  cat > app/accounts/forms.py <<'PY'
from django import forms
from django.contrib.auth import get_user_model
from django.utils.translation import gettext_lazy as _
from .models import RegistrationField, RegistrationValue, SecurityQuestion, SecurityPolicy, UserSecurityAnswer

User = get_user_model()

class LoginForm(forms.Form):
    email = forms.EmailField(label=_("ایمیل"))
    password = forms.CharField(label=_("گذرواژه"), widget=forms.PasswordInput)

class RegisterForm(forms.Form):
    email = forms.EmailField(label=_("ایمیل"))
    password1 = forms.CharField(label=_("گذرواژه"), widget=forms.PasswordInput)
    password2 = forms.CharField(label=_("تکرار گذرواژه"), widget=forms.PasswordInput)

    security_question = forms.ModelChoiceField(
        queryset=SecurityQuestion.objects.filter(is_active=True).order_by("order","id"),
        label=_("سوال امنیتی"),
        required=True
    )
    security_answer = forms.CharField(label=_("پاسخ سوال امنیتی"), required=True)

    def __init__(self, *args, **kwargs):
        self.dynamic_fields = []
        super().__init__(*args, **kwargs)

        fields = RegistrationField.objects.filter(is_active=True).order_by("order","id")
        for f in fields:
            name = f"f_{f.key}"
            self.dynamic_fields.append((name, f))
            req = bool(f.is_required)

            if f.field_type == RegistrationField.FieldType.TEXTAREA:
                self.fields[name] = forms.CharField(label=f.label, required=req, widget=forms.Textarea(attrs={"rows":3}))
            elif f.field_type == RegistrationField.FieldType.EMAIL:
                self.fields[name] = forms.EmailField(label=f.label, required=req)
            elif f.field_type == RegistrationField.FieldType.NUMBER:
                self.fields[name] = forms.IntegerField(label=f.label, required=req)
            elif f.field_type == RegistrationField.FieldType.TEL:
                self.fields[name] = forms.CharField(label=f.label, required=req)
            elif f.field_type == RegistrationField.FieldType.DATE:
                self.fields[name] = forms.DateField(label=f.label, required=req, widget=forms.DateInput(attrs={"type":"date"}))
            elif f.field_type == RegistrationField.FieldType.SELECT:
                opts = [o.strip() for o in (f.options or "").splitlines() if o.strip()]
                self.fields[name] = forms.ChoiceField(label=f.label, required=req, choices=[(o,o) for o in opts])
            elif f.field_type == RegistrationField.FieldType.CHECKBOX:
                self.fields[name] = forms.BooleanField(label=f.label, required=req)
            else:
                self.fields[name] = forms.CharField(label=f.label, required=req)

        policy = SecurityPolicy.objects.first()
        if policy and not policy.allow_user_choose_question:
            self.fields["security_question"].disabled = True

    def clean(self):
        c = super().clean()
        if c.get("password1") != c.get("password2"):
            raise forms.ValidationError(_("رمزها یکسان نیستند."))
        return c

class ProfileForm(forms.Form):
    email = forms.EmailField(label=_("ایمیل"), disabled=True)

class ChangePasswordForm(forms.Form):
    old_password = forms.CharField(label=_("گذرواژه فعلی"), widget=forms.PasswordInput)
    new_password1 = forms.CharField(label=_("گذرواژه جدید"), widget=forms.PasswordInput)
    new_password2 = forms.CharField(label=_("تکرار گذرواژه جدید"), widget=forms.PasswordInput)

    def clean(self):
        c = super().clean()
        if c.get("new_password1") != c.get("new_password2"):
            raise forms.ValidationError(_("رمزهای جدید یکسان نیستند."))
        return c

class ForgotPasswordForm(forms.Form):
    email = forms.EmailField(label=_("ایمیل"))

class ResetWithSecurityAnswerForm(forms.Form):
    answer = forms.CharField(label=_("پاسخ سوال امنیتی"), required=True)
    new_password1 = forms.CharField(label=_("گذرواژه جدید"), widget=forms.PasswordInput)
    new_password2 = forms.CharField(label=_("تکرار گذرواژه جدید"), widget=forms.PasswordInput)

    def clean(self):
        c = super().clean()
        if c.get("new_password1") != c.get("new_password2"):
            raise forms.ValidationError(_("رمزها یکسان نیستند."))
        return c
PY

  cat > app/accounts/admin.py <<'PY'
from django.contrib import admin
from django.contrib.auth.admin import UserAdmin as BaseUserAdmin
from django.contrib.auth import get_user_model
from django.utils.translation import gettext_lazy as _
from .models import RegistrationField, RegistrationValue, SecurityQuestion, UserSecurityAnswer, SecurityPolicy

User = get_user_model()

@admin.register(User)
class UserAdmin(BaseUserAdmin):
    model = User
    ordering = ("email",)
    list_display = ("email","is_staff","is_superuser","is_active","date_joined")
    list_filter = ("is_staff","is_superuser","is_active")
    search_fields = ("email",)
    fieldsets = (
        (None, {"fields": ("email","password")}),
        (_("Permissions"), {"fields": ("is_active","is_staff","is_superuser","groups","user_permissions")}),
    )
    add_fieldsets = (
        (None, {"classes": ("wide",), "fields": ("email","password1","password2","is_staff","is_superuser","is_active")}),
    )

@admin.register(RegistrationField)
class RegistrationFieldAdmin(admin.ModelAdmin):
    list_display = ("label","key","field_type","is_required","is_active","order")
    list_display_links = ("label","key")
    list_editable = ("field_type","is_required","is_active","order")
    search_fields = ("label","key")
    list_filter = ("field_type","is_active","is_required")
    ordering = ("order","id")

@admin.register(RegistrationValue)
class RegistrationValueAdmin(admin.ModelAdmin):
    list_display = ("user","field","value")
    search_fields = ("user__email","field__label","value")
    list_filter = ("field",)

@admin.register(SecurityQuestion)
class SecurityQuestionAdmin(admin.ModelAdmin):
    list_display = ("question","is_active","order")
    list_display_links = ("question",)
    list_editable = ("is_active","order")
    search_fields = ("question",)

@admin.register(UserSecurityAnswer)
class UserSecurityAnswerAdmin(admin.ModelAdmin):
    list_display = ("user","question")
    search_fields = ("user__email","question__question")

@admin.register(SecurityPolicy)
class SecurityPolicyAdmin(admin.ModelAdmin):
    list_display = ("allow_user_change_answer","allow_user_choose_question",)
PY

  cat > app/accounts/views.py <<'PY'
from django.contrib import messages
from django.contrib.auth import authenticate, login, update_session_auth_hash
from django.contrib.auth.decorators import login_required
from django.shortcuts import render, redirect, get_object_or_404
from django.utils.translation import gettext_lazy as _
from django.contrib.auth import get_user_model

from .forms import LoginForm, RegisterForm, ProfileForm, ChangePasswordForm, ForgotPasswordForm, ResetWithSecurityAnswerForm
from .models import RegistrationValue, SecurityPolicy, UserSecurityAnswer

User = get_user_model()

def login_view(request):
    if request.user.is_authenticated:
        return redirect("/")
    form = LoginForm(request.POST or None)
    if request.method == "POST" and form.is_valid():
        email = form.cleaned_data["email"]
        password = form.cleaned_data["password"]
        user = authenticate(request, email=email, password=password)
        if user:
            login(request, user)
            return redirect("/")
        messages.error(request, _("ایمیل یا گذرواژه اشتباه است."))
    return render(request, "accounts/login.html", {"form": form})

def register_view(request):
    if request.user.is_authenticated:
        return redirect("/")
    form = RegisterForm(request.POST or None)
    if request.method == "POST" and form.is_valid():
        email = form.cleaned_data["email"].lower().strip()
        if User.objects.filter(email=email).exists():
            messages.error(request, _("این ایمیل قبلاً ثبت شده است."))
            return render(request, "accounts/register.html", {"form": form})

        user = User.objects.create_user(email=email, password=form.cleaned_data["password1"])
        for name, f in form.dynamic_fields:
            val = form.cleaned_data.get(name)
            RegistrationValue.objects.update_or_create(user=user, field=f, defaults={"value": str(val) if val is not None else ""})

        ua = UserSecurityAnswer.objects.create(user=user, question=form.cleaned_data["security_question"], answer_hash="")
        ua.set_answer(form.cleaned_data["security_answer"])
        ua.save(update_fields=["answer_hash"])

        messages.success(request, _("ثبت‌نام با موفقیت انجام شد."))
        return redirect("/accounts/login/")
    return render(request, "accounts/register.html", {"form": form})

@login_required
def panel_view(request):
    return render(request, "accounts/panel.html")

@login_required
def profile_view(request):
    form = ProfileForm(initial={"email": request.user.email})
    return render(request, "accounts/profile.html", {"form": form})

@login_required
def change_password_view(request):
    form = ChangePasswordForm(request.POST or None)
    if request.method == "POST" and form.is_valid():
        if not request.user.check_password(form.cleaned_data["old_password"]):
            messages.error(request, _("گذرواژه فعلی اشتباه است."))
        else:
            request.user.set_password(form.cleaned_data["new_password1"])
            request.user.save()
            update_session_auth_hash(request, request.user)
            messages.success(request, _("گذرواژه با موفقیت تغییر کرد."))
            return redirect("/panel/")
    return render(request, "accounts/change_password.html", {"form": form})

def forgot_password_view(request):
    form = ForgotPasswordForm(request.POST or None)
    if request.method == "POST" and form.is_valid():
        email = form.cleaned_data["email"].lower().strip()
        u = User.objects.filter(email=email).first()
        if not u:
            messages.error(request, _("کاربری با این ایمیل یافت نشد."))
            return render(request, "accounts/forgot.html", {"form": form})
        request.session["fp_user_id"] = str(u.id)
        return redirect("/accounts/reset-security/")
    return render(request, "accounts/forgot.html", {"form": form})

def reset_with_security_view(request):
    uid = request.session.get("fp_user_id")
    if not uid:
        return redirect("/accounts/forgot/")
    u = get_object_or_404(User, id=uid)
    ans = getattr(u, "security_answer", None)
    if not ans:
        messages.error(request, _("برای این کاربر سوال امنیتی تنظیم نشده است."))
        return redirect("/accounts/forgot/")

    policy = SecurityPolicy.objects.first()
    question = ans.question

    form = ResetWithSecurityAnswerForm(request.POST or None)
    if request.method == "POST" and form.is_valid():
        if not ans.verify_answer(form.cleaned_data["answer"]):
            messages.error(request, _("پاسخ سوال امنیتی اشتباه است."))
        else:
            u.set_password(form.cleaned_data["new_password1"])
            u.save()
            request.session.pop("fp_user_id", None)
            messages.success(request, _("گذرواژه با موفقیت تغییر کرد."))
            return redirect("/accounts/login/")

    return render(request, "accounts/reset_security.html", {"form": form, "question": question, "policy": policy})
PY

  cat > app/accounts/urls.py <<'PY'
from django.urls import path
from django.contrib.auth.views import LogoutView
from .views import login_view, register_view, panel_view, profile_view, change_password_view, forgot_password_view, reset_with_security_view

urlpatterns = [
    path("login/", login_view, name="login"),
    path("logout/", LogoutView.as_view(), name="logout"),
    path("register/", register_view, name="register"),
    path("forgot/", forgot_password_view, name="forgot"),
    path("reset-security/", reset_with_security_view, name="reset_security"),

    path("panel/", panel_view, name="panel"),
    path("profile/", profile_view, name="profile"),
    path("change-password/", change_password_view, name="change_password"),
]
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
    logo = models.ImageField(upload_to="branding/", blank=True, null=True, verbose_name=_("لوگو"))
    favicon = models.ImageField(upload_to="branding/", blank=True, null=True, verbose_name=_("فاویکن"))

    footer_text = models.TextField(blank=True, verbose_name=_("متن فوتر"))
    admin_path = models.SlugField(max_length=50, default="admin", verbose_name=_("مسیر پنل ادمین"))
    updated_at = models.DateTimeField(auto_now=True, verbose_name=_("آخرین بروزرسانی"))

    class Meta:
        verbose_name = _("تنظیمات سایت")
        verbose_name_plural = _("تنظیمات سایت")

    def __str__(self): return "Site Settings"
PY

  cat > app/settingsapp/admin.py <<'PY'
from django.contrib import admin
from .models import SiteSetting

admin.site.site_header = "پنل مدیریت"
admin.site.site_title = "پنل مدیریت"
admin.site.index_title = "مدیریت سایت"

@admin.register(SiteSetting)
class SiteSettingAdmin(admin.ModelAdmin):
    fieldsets = (
        ("Branding", {"fields": ("brand_name","logo","favicon")}),
        ("Footer", {"fields": ("footer_text",)}),
        ("Admin", {"fields": ("admin_path",)}),
    )
PY

  cat > app/settingsapp/context_processors.py <<'PY'
from .models import SiteSetting
def site_context(request):
    s = SiteSetting.objects.first()
    return {"site_settings": s}
PY

  cat > app/settingsapp/forms.py <<'PY'
from django import forms
from django.utils.translation import gettext_lazy as _
class AdminPathForm(forms.Form):
    admin_path = forms.SlugField(max_length=50, label=_("مسیر جدید پنل ادمین"))
PY

  cat > app/settingsapp/views.py <<'PY'
from django.contrib.admin.views.decorators import staff_member_required
from django.contrib import messages
from django.shortcuts import render, redirect
from django.core.cache import cache
from .forms import AdminPathForm
from .models import SiteSetting

@staff_member_required
def admin_path_settings(request):
    s = SiteSetting.objects.first() or SiteSetting.objects.create()
    form = AdminPathForm(request.POST or None, initial={"admin_path": getattr(s, "admin_path", "admin")})
    if request.method == "POST" and form.is_valid():
        s.admin_path = (form.cleaned_data["admin_path"] or "admin").strip().strip("/") or "admin"
        s.save(update_fields=["admin_path"])
        cache.delete("site_admin_path")
        messages.success(request, f"مسیر پنل ادمین تغییر کرد: /{s.admin_path}/")
        return redirect("admin_path_settings")
    return render(request, "settings/admin_path.html", {"form": form, "current": s.admin_path})
PY

  cat > app/settingsapp/urls.py <<'PY'
from django.urls import path
from .views import admin_path_settings
urlpatterns = [
    path("admin-path/", admin_path_settings, name="admin_path_settings"),
]
PY

  cat > app/settingsapp/admin_views.py <<'PY'
from django.contrib.admin.views.decorators import staff_member_required
from django.contrib.auth import update_session_auth_hash
from django.contrib import messages
from django.shortcuts import render, redirect
from django import forms
from django.utils.translation import gettext_lazy as _

class AdminAccountForm(forms.Form):
    email = forms.EmailField(label=_("ایمیل جدید"))
    password1 = forms.CharField(widget=forms.PasswordInput, label=_("رمز عبور جدید"))
    password2 = forms.CharField(widget=forms.PasswordInput, label=_("تکرار رمز عبور جدید"))

    def clean(self):
        c = super().clean()
        if c.get("password1") != c.get("password2"):
            raise forms.ValidationError(_("رمزها یکسان نیستند."))
        return c

@staff_member_required
def admin_account_in_admin(request):
    form = AdminAccountForm(request.POST or None, initial={"email": request.user.email})
    if request.method == "POST" and form.is_valid():
        u = request.user
        u.email = form.cleaned_data["email"].lower().strip()
        u.set_password(form.cleaned_data["password1"])
        u.save()
        update_session_auth_hash(request, u)
        messages.success(request, "ایمیل و رمز عبور با موفقیت تغییر کرد.")
        return redirect("/admin/")
    return render(request, "admin/admin_account.html", {"form": form})
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
from django.conf import settings
from django.utils.translation import gettext_lazy as _

class PublishStatus(models.TextChoices):
    DRAFT = "draft", _("پیش‌نویس")
    PUBLISHED = "published", _("منتشر شده")
    ARCHIVED = "archived", _("آرشیو")

class TimeStamped(models.Model):
    created_at = models.DateTimeField(auto_now_add=True, verbose_name=_("ایجاد"))
    updated_at = models.DateTimeField(auto_now=True, verbose_name=_("بروزرسانی"))
    class Meta: abstract = True

class Category(TimeStamped):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    title = models.CharField(max_length=120, unique=True, verbose_name=_("عنوان"))
    slug = models.SlugField(max_length=140, unique=True, blank=True, verbose_name=_("اسلاگ"))
    class Meta:
        verbose_name = _("دسته‌بندی")
        verbose_name_plural = _("دسته‌بندی‌ها")
    def save(self,*a,**k):
        if not self.slug:
            self.slug = slugify(self.title, allow_unicode=True)
        return super().save(*a,**k)
    def __str__(self): return self.title

class Course(TimeStamped):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    owner = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.PROTECT, related_name="owned_courses", verbose_name=_("مالک"))
    category = models.ForeignKey(Category, on_delete=models.SET_NULL, null=True, blank=True, verbose_name=_("دسته‌بندی"))

    title = models.CharField(max_length=200, verbose_name=_("عنوان"))
    slug = models.SlugField(max_length=220, unique=True, blank=True, verbose_name=_("اسلاگ"))
    cover = models.ImageField(upload_to="courses/covers/", blank=True, null=True, verbose_name=_("کاور"))
    summary = models.TextField(blank=True, verbose_name=_("خلاصه"))
    description = models.TextField(blank=True, verbose_name=_("توضیحات"))

    price_toman = models.PositiveIntegerField(default=0, verbose_name=_("قیمت (تومان)"))
    is_free_for_all = models.BooleanField(default=False, verbose_name=_("رایگان برای همه"))
    status = models.CharField(max_length=20, choices=PublishStatus.choices, default=PublishStatus.DRAFT, verbose_name=_("وضعیت"))

    class Meta:
        verbose_name = _("دوره")
        verbose_name_plural = _("دوره‌ها")

    def save(self,*a,**k):
        if not self.slug:
            self.slug = slugify(self.title, allow_unicode=True)
        return super().save(*a,**k)
    def __str__(self): return self.title

class Section(TimeStamped):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    course = models.ForeignKey(Course, on_delete=models.CASCADE, related_name="sections", verbose_name=_("دوره"))
    title = models.CharField(max_length=200, verbose_name=_("عنوان"))
    order = models.PositiveIntegerField(default=0, verbose_name=_("ترتیب"))
    class Meta:
        ordering = ["order"]
        unique_together = [("course","order")]
        verbose_name = _("سرفصل")
        verbose_name_plural = _("سرفصل‌ها")

class Lesson(TimeStamped):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    section = models.ForeignKey(Section, on_delete=models.CASCADE, related_name="lessons", verbose_name=_("سرفصل"))
    title = models.CharField(max_length=200, verbose_name=_("عنوان"))
    order = models.PositiveIntegerField(default=0, verbose_name=_("ترتیب"))
    body = models.TextField(blank=True, verbose_name=_("متن"))
    video_file = models.FileField(upload_to="videos/", blank=True, null=True, verbose_name=_("فایل ویدیو"))
    video_url = models.URLField(blank=True, verbose_name=_("لینک ویدیو"))
    is_free_preview = models.BooleanField(default=False, verbose_name=_("پیش‌نمایش رایگان"))
    class Meta:
        ordering = ["order"]
        unique_together = [("section","order")]
        verbose_name = _("درس")
        verbose_name_plural = _("درس‌ها")

class Enrollment(TimeStamped):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    user = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="enrollments", verbose_name=_("کاربر"))
    course = models.ForeignKey(Course, on_delete=models.CASCADE, related_name="enrollments", verbose_name=_("دوره"))
    is_active = models.BooleanField(default=True, verbose_name=_("فعال"))
    source = models.CharField(max_length=30, default="paid", verbose_name=_("منبع"))
    class Meta:
        unique_together = [("user","course")]
        verbose_name = _("ثبت‌نام")
        verbose_name_plural = _("ثبت‌نام‌ها")

class CourseGrant(TimeStamped):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    user = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="course_grants", verbose_name=_("کاربر"))
    course = models.ForeignKey(Course, on_delete=models.CASCADE, related_name="grants", verbose_name=_("دوره"))
    is_active = models.BooleanField(default=True, verbose_name=_("فعال"))
    reason = models.CharField(max_length=200, blank=True, verbose_name=_("دلیل"))
    class Meta:
        unique_together = [("user","course")]
        verbose_name = _("دسترسی رایگان")
        verbose_name_plural = _("دسترسی‌های رایگان")
PY

  cat > app/courses/access.py <<'PY'
from .models import Enrollment, CourseGrant
def user_has_course_access(user, course) -> bool:
    if course.is_free_for_all:
        return True
    if not user.is_authenticated:
        return False
    if Enrollment.objects.filter(user=user, course=course, is_active=True).exists():
        return True
    if CourseGrant.objects.filter(user=user, course=course, is_active=True).exists():
        return True
    return False
PY

  cat > app/courses/admin.py <<'PY'
from django.contrib import admin
from .models import Category, Course, Section, Lesson, Enrollment, CourseGrant

class LessonInline(admin.TabularInline):
    model = Lesson
    extra = 0

class SectionInline(admin.TabularInline):
    model = Section
    extra = 0
    show_change_link = True

@admin.register(Category)
class CategoryAdmin(admin.ModelAdmin):
    list_display = ("title","slug","updated_at")
    search_fields = ("title","slug")
    prepopulated_fields = {"slug": ("title",)}

@admin.register(Course)
class CourseAdmin(admin.ModelAdmin):
    list_display = ("title","category","owner","status","price_toman","is_free_for_all","updated_at")
    list_filter = ("status","is_free_for_all","category")
    search_fields = ("title","summary","description")
    prepopulated_fields = {"slug": ("title",)}
    inlines = [SectionInline]

@admin.register(Section)
class SectionAdmin(admin.ModelAdmin):
    list_display = ("title","course","order")
    inlines = [LessonInline]

@admin.register(Lesson)
class LessonAdmin(admin.ModelAdmin):
    list_display = ("title","section","order","is_free_preview")
    search_fields = ("title","body","video_url")

admin.site.register(Enrollment)
admin.site.register(CourseGrant)
PY

  cat > app/courses/views.py <<'PY'
from django.views.generic import ListView, DetailView
from django.db.models import Prefetch
from .models import Course, PublishStatus, Section, Lesson
from .access import user_has_course_access

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
    def get_queryset(self):
        lessons_qs = Lesson.objects.order_by("order")
        sections_qs = Section.objects.prefetch_related(Prefetch("lessons", queryset=lessons_qs)).order_by("order")
        return Course.objects.filter(status=PublishStatus.PUBLISHED).prefetch_related(Prefetch("sections", queryset=sections_qs))
    def get_context_data(self, **kwargs):
        ctx = super().get_context_data(**kwargs)
        ctx["has_access"] = user_has_course_access(self.request.user, self.object)
        return ctx
PY

  cat > app/payments/apps.py <<'PY'
from django.apps import AppConfig
class PaymentsConfig(AppConfig):
    default_auto_field = "django.db.models.BigAutoField"
    name = "payments"
    verbose_name = "پرداخت‌ها و سفارش‌ها"
PY

  cat > app/payments/models.py <<'PY'
import uuid
from django.db import models
from django.conf import settings
from django.utils import timezone
from django.utils.translation import gettext_lazy as _
from courses.models import Course

class BankTransferSetting(models.Model):
    account_holder = models.CharField(max_length=120, blank=True, verbose_name=_("نام صاحب حساب"))
    card_number = models.CharField(max_length=30, blank=True, verbose_name=_("شماره کارت"))
    note = models.TextField(blank=True, verbose_name=_("توضیحات"))

    first_purchase_percent = models.PositiveIntegerField(default=0, verbose_name=_("تخفیف خرید اول (درصد)"))
    first_purchase_amount = models.PositiveIntegerField(default=0, verbose_name=_("تخفیف خرید اول (مبلغ تومان)"))

    updated_at = models.DateTimeField(auto_now=True, verbose_name=_("بروزرسانی"))
    class Meta:
        verbose_name = _("تنظیمات کارت‌به‌کارت")
        verbose_name_plural = _("تنظیمات کارت‌به‌کارت")
    def __str__(self): return "Bank Transfer Settings"

class CouponType(models.TextChoices):
    PERCENT = "percent", _("درصدی")
    AMOUNT = "amount", _("مبلغی")

class Coupon(models.Model):
    code = models.CharField(max_length=40, unique=True, verbose_name=_("کد"))
    type = models.CharField(max_length=10, choices=CouponType.choices, default=CouponType.PERCENT, verbose_name=_("نوع"))
    value = models.PositiveIntegerField(verbose_name=_("مقدار"))
    is_active = models.BooleanField(default=True, verbose_name=_("فعال"))

    start_at = models.DateTimeField(blank=True, null=True, verbose_name=_("شروع"))
    end_at = models.DateTimeField(blank=True, null=True, verbose_name=_("پایان"))

    max_uses = models.PositiveIntegerField(default=0, verbose_name=_("حداکثر استفاده (0=نامحدود)"))
    max_uses_per_user = models.PositiveIntegerField(default=0, verbose_name=_("حداکثر برای هر کاربر (0=نامحدود)"))
    min_amount = models.PositiveIntegerField(default=0, verbose_name=_("حداقل مبلغ سفارش"))

    class Meta:
        verbose_name = _("کد تخفیف")
        verbose_name_plural = _("کدهای تخفیف")

    def __str__(self): return self.code

    def is_valid_now(self):
        now = timezone.now()
        if not self.is_active:
            return False
        if self.start_at and now < self.start_at:
            return False
        if self.end_at and now > self.end_at:
            return False
        return True

class OrderStatus(models.TextChoices):
    PENDING_PAYMENT = "pending_payment", _("در انتظار پرداخت")
    PENDING_VERIFY = "pending_verify", _("در انتظار تایید")
    PAID = "paid", _("پرداخت شده")
    REJECTED = "rejected", _("رد شده")
    CANCELED = "canceled", _("لغو شده")

class Order(models.Model):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    user = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, verbose_name=_("کاربر"))
    course = models.ForeignKey(Course, on_delete=models.PROTECT, verbose_name=_("دوره"))

    amount = models.PositiveIntegerField(verbose_name=_("مبلغ پایه"))
    discount_amount = models.PositiveIntegerField(default=0, verbose_name=_("تخفیف"))
    final_amount = models.PositiveIntegerField(default=0, verbose_name=_("مبلغ نهایی"))

    coupon = models.ForeignKey(Coupon, on_delete=models.SET_NULL, null=True, blank=True, verbose_name=_("کوپن"))

    status = models.CharField(max_length=30, choices=OrderStatus.choices, default=OrderStatus.PENDING_PAYMENT, verbose_name=_("وضعیت"))

    receipt_image = models.ImageField(upload_to="receipts/", blank=True, null=True, verbose_name=_("رسید"))
    tracking_code = models.CharField(max_length=80, blank=True, verbose_name=_("کد پیگیری"))
    note = models.TextField(blank=True, verbose_name=_("یادداشت"))

    created_at = models.DateTimeField(auto_now_add=True, verbose_name=_("ایجاد"))
    verified_at = models.DateTimeField(blank=True, null=True, verbose_name=_("تایید"))

    class Meta:
        ordering = ["-created_at"]
        verbose_name = _("سفارش")
        verbose_name_plural = _("سفارش‌ها")
PY

  cat > app/payments/forms.py <<'PY'
from django import forms
from .models import Order
from django.utils.translation import gettext_lazy as _

class ReceiptUploadForm(forms.ModelForm):
    class Meta:
        model = Order
        fields = ("receipt_image", "tracking_code", "note")
        labels = {
            "receipt_image": _("تصویر رسید"),
            "tracking_code": _("کد پیگیری"),
            "note": _("توضیحات"),
        }

class CouponApplyForm(forms.Form):
    coupon_code = forms.CharField(required=False, max_length=40, label=_("کد تخفیف"))
PY

  cat > app/payments/utils.py <<'PY'
from .models import CouponType, Coupon, Order, OrderStatus

def calc_coupon_discount(coupon, base_amount):
    if not coupon:
        return 0
    if coupon.type == CouponType.PERCENT:
        pct = min(max(int(coupon.value), 0), 100)
        return (base_amount * pct) // 100
    return min(int(coupon.value), base_amount)

def coupon_user_uses(coupon, user):
    return Order.objects.filter(user=user, coupon=coupon).exclude(status=OrderStatus.CANCELED).count()

def coupon_total_uses(coupon):
    return Order.objects.filter(coupon=coupon).exclude(status=OrderStatus.CANCELED).count()

def validate_coupon(code, user, base_amount):
    code = (code or "").strip()
    if not code:
        return None, "کدی وارد نشده است."
    try:
        coupon = Coupon.objects.get(code__iexact=code)
    except Coupon.DoesNotExist:
        return None, "کد تخفیف نامعتبر است."

    if not coupon.is_valid_now():
        return None, "کد تخفیف فعال نیست یا تاریخ آن گذشته است."

    if base_amount < coupon.min_amount:
        return None, "این کد برای این مبلغ قابل استفاده نیست."

    if coupon.max_uses and coupon_total_uses(coupon) >= coupon.max_uses:
        return None, "سقف استفاده از این کد پر شده است."

    if coupon.max_uses_per_user and coupon_user_uses(coupon, user) >= coupon.max_uses_per_user:
        return None, "سقف استفاده شما از این کد پر شده است."

    return coupon, ""
PY

  cat > app/payments/views.py <<'PY'
from django.contrib.auth.decorators import login_required
from django.shortcuts import get_object_or_404, redirect, render
from django.contrib import messages

from courses.models import Course, PublishStatus, Enrollment
from courses.access import user_has_course_access
from .models import BankTransferSetting, Order, OrderStatus
from .forms import ReceiptUploadForm, CouponApplyForm
from .utils import validate_coupon, calc_coupon_discount

@login_required
def checkout(request, slug):
    course = get_object_or_404(Course, slug=slug, status=PublishStatus.PUBLISHED)

    if course.is_free_for_all:
        Enrollment.objects.get_or_create(user=request.user, course=course, defaults={"is_active": True, "source": "free_all"})
        return redirect("course_detail", slug=course.slug)

    if user_has_course_access(request.user, course):
        return redirect("course_detail", slug=course.slug)

    setting = BankTransferSetting.objects.first()

    order = Order.objects.filter(user=request.user, course=course).exclude(status__in=[OrderStatus.PAID, OrderStatus.CANCELED]).first()
    if not order:
        order = Order.objects.create(
            user=request.user, course=course, amount=course.price_toman, discount_amount=0, final_amount=course.price_toman,
            status=OrderStatus.PENDING_PAYMENT
        )

    base = order.amount

    first_paid_count = Order.objects.filter(user=request.user, status=OrderStatus.PAID).count()
    first_purchase_eligible = (first_paid_count == 0)

    coupon_form = CouponApplyForm(request.POST or None)
    applied_coupon = None

    if request.method == "POST":
        code = coupon_form.data.get("coupon_code", "")
        if code.strip():
            applied_coupon, msg = validate_coupon(code, request.user, base)
            if applied_coupon:
                messages.success(request, "کد تخفیف اعمال شد.")
            else:
                messages.error(request, msg)

    discount = 0
    discount_label = ""

    if applied_coupon:
        discount = calc_coupon_discount(applied_coupon, base)
        discount_label = f"کد تخفیف: {applied_coupon.code}"
    elif first_purchase_eligible and setting:
        pct = min(max(int(setting.first_purchase_percent or 0), 0), 100)
        pct_discount = (base * pct) // 100
        amt_discount = min(int(setting.first_purchase_amount or 0), base)
        discount = max(pct_discount, amt_discount)
        if discount > 0:
            discount_label = "تخفیف خرید اول"

    discount = min(discount, base)
    final_amount = max(base - discount, 0)

    order.coupon = applied_coupon
    order.discount_amount = discount
    order.final_amount = final_amount
    order.save(update_fields=["coupon", "discount_amount", "final_amount"])

    return render(request, "orders/checkout.html", {
        "course": course,
        "setting": setting,
        "order": order,
        "coupon_form": coupon_form,
        "discount_label": discount_label,
        "first_purchase_eligible": first_purchase_eligible,
    })

@login_required
def upload_receipt(request, order_id):
    order = get_object_or_404(Order, id=order_id, user=request.user)
    if order.status in [OrderStatus.PAID, OrderStatus.CANCELED]:
        return redirect("orders_my")

    if request.method == "POST":
        form = ReceiptUploadForm(request.POST, request.FILES, instance=order)
        if form.is_valid():
            form.save()
            order.status = OrderStatus.PENDING_VERIFY
            order.save(update_fields=["status"])
            messages.success(request, "رسید ثبت شد و پس از بررسی فعال می‌شود.")
            return redirect("orders_my")
    else:
        form = ReceiptUploadForm(instance=order)

    return render(request, "orders/upload_receipt.html", {"order": order, "form": form})

@login_required
def my_orders(request):
    orders = Order.objects.filter(user=request.user)
    return render(request, "orders/my_orders.html", {"orders": orders})
PY

  cat > app/payments/admin.py <<'PY'
from django.contrib import admin
from django.utils import timezone
from .models import BankTransferSetting, Order, OrderStatus, Coupon
from courses.models import Enrollment

@admin.action(description="تایید سفارش و فعال‌سازی دسترسی دوره")
def mark_paid_and_enroll(modeladmin, request, queryset):
    now = timezone.now()
    for o in queryset:
        o.status = OrderStatus.PAID
        o.verified_at = now
        o.save(update_fields=["status", "verified_at"])
        Enrollment.objects.get_or_create(user=o.user, course=o.course, defaults={"is_active": True, "source": "paid"})

@admin.register(Order)
class OrderAdmin(admin.ModelAdmin):
    list_display = ("id","user","course","amount","discount_amount","final_amount","status","created_at")
    list_filter = ("status","created_at")
    search_fields = ("user__email","course__title","tracking_code","coupon__code")
    actions = [mark_paid_and_enroll]

@admin.register(Coupon)
class CouponAdmin(admin.ModelAdmin):
    list_display = ("code","type","value","is_active","max_uses","max_uses_per_user","min_amount")
    list_filter = ("is_active","type")
    search_fields = ("code",)

admin.site.register(BankTransferSetting)
PY

  cat > app/payments/urls.py <<'PY'
from django.urls import path
from .views import checkout, upload_receipt, my_orders
urlpatterns = [
    path("checkout/<slug:slug>/", checkout, name="checkout"),
    path("receipt/<uuid:order_id>/", upload_receipt, name="upload_receipt"),
    path("my/", my_orders, name="orders_my"),
]
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
from django.conf import settings
from django.utils.translation import gettext_lazy as _

class TicketStatus(models.TextChoices):
    OPEN = "open", _("باز")
    ANSWERED = "answered", _("پاسخ داده شده")
    CLOSED = "closed", _("بسته")

class Ticket(models.Model):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    user = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="tickets", verbose_name=_("کاربر"))
    subject = models.CharField(max_length=200, verbose_name=_("موضوع"))
    description = models.TextField(verbose_name=_("توضیحات"))
    attachment = models.FileField(upload_to="tickets/", blank=True, null=True, verbose_name=_("پیوست"))
    status = models.CharField(max_length=20, choices=TicketStatus.choices, default=TicketStatus.OPEN, verbose_name=_("وضعیت"))
    created_at = models.DateTimeField(auto_now_add=True, verbose_name=_("ایجاد"))
    updated_at = models.DateTimeField(auto_now=True, verbose_name=_("بروزرسانی"))

    class Meta:
        ordering = ["-created_at"]
        verbose_name = _("تیکت")
        verbose_name_plural = _("تیکت‌ها")

    def __str__(self): return self.subject

class TicketReply(models.Model):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    ticket = models.ForeignKey(Ticket, on_delete=models.CASCADE, related_name="replies", verbose_name=_("تیکت"))
    user = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, verbose_name=_("ارسال کننده"))
    message = models.TextField(verbose_name=_("پیام"))
    attachment = models.FileField(upload_to="tickets/replies/", blank=True, null=True, verbose_name=_("پیوست"))
    created_at = models.DateTimeField(auto_now_add=True, verbose_name=_("ایجاد"))

    class Meta:
        ordering = ["created_at"]
        verbose_name = _("پاسخ تیکت")
        verbose_name_plural = _("پاسخ‌های تیکت")
PY

  cat > app/tickets/forms.py <<'PY'
from django import forms
from django.utils.translation import gettext_lazy as _
from .models import Ticket, TicketReply

class TicketCreateForm(forms.ModelForm):
    class Meta:
        model = Ticket
        fields = ("subject","description","attachment")
        labels = {"subject": _("موضوع"), "description": _("توضیحات"), "attachment": _("پیوست")}

class TicketReplyForm(forms.ModelForm):
    class Meta:
        model = TicketReply
        fields = ("message","attachment")
        labels = {"message": _("پیام"), "attachment": _("پیوست")}
PY

  cat > app/tickets/views.py <<'PY'
from django.contrib.auth.decorators import login_required
from django.shortcuts import render, redirect, get_object_or_404
from django.contrib import messages
from .models import Ticket, TicketReply, TicketStatus
from .forms import TicketCreateForm, TicketReplyForm

@login_required
def ticket_list(request):
    tickets = Ticket.objects.filter(user=request.user)
    return render(request, "tickets/list.html", {"tickets": tickets})

@login_required
def ticket_create(request):
    form = TicketCreateForm(request.POST or None, request.FILES or None)
    if request.method == "POST" and form.is_valid():
        t = form.save(commit=False)
        t.user = request.user
        t.status = TicketStatus.OPEN
        t.save()
        messages.success(request, "تیکت ثبت شد.")
        return redirect("ticket_detail", ticket_id=t.id)
    return render(request, "tickets/create.html", {"form": form})

@login_required
def ticket_detail(request, ticket_id):
    ticket = get_object_or_404(Ticket, id=ticket_id, user=request.user)
    form = TicketReplyForm(request.POST or None, request.FILES or None)
    if request.method == "POST" and form.is_valid():
        r = form.save(commit=False)
        r.ticket = ticket
        r.user = request.user
        r.save()
        ticket.status = TicketStatus.OPEN
        ticket.save(update_fields=["status"])
        messages.success(request, "پاسخ ثبت شد.")
        return redirect("ticket_detail", ticket_id=ticket.id)
    return render(request, "tickets/detail.html", {"ticket": ticket, "form": form})
PY

  cat > app/tickets/admin.py <<'PY'
from django.contrib import admin
from .models import Ticket, TicketReply

class TicketReplyInline(admin.TabularInline):
    model = TicketReply
    extra = 0

@admin.register(Ticket)
class TicketAdmin(admin.ModelAdmin):
    list_display = ("id","user","subject","status","created_at")
    list_filter = ("status","created_at")
    search_fields = ("user__email","subject","description")
    inlines = [TicketReplyInline]

admin.site.register(TicketReply)
PY

  cat > app/tickets/urls.py <<'PY'
from django.urls import path
from .views import ticket_list, ticket_create, ticket_detail
urlpatterns = [
    path("", ticket_list, name="ticket_list"),
    path("new/", ticket_create, name="ticket_create"),
    path("<uuid:ticket_id>/", ticket_detail, name="ticket_detail"),
]
PY

  cat > app/templates/_style.html <<'HTML'
<style>
  :root{
    --bg: #0b1220;
    --card: rgba(255,255,255,.06);
    --card2: rgba(255,255,255,.08);
    --border: rgba(255,255,255,.10);
    --text: rgba(255,255,255,.92);
    --muted: rgba(255,255,255,.68);
    --accent: #7c3aed;
    --accent2:#22c55e;
    --danger:#ef4444;
  }
  body{margin:0;font-family: ui-sans-serif,system-ui,-apple-system,Segoe UI,Roboto,Arial; background: radial-gradient(1200px 600px at 10% 10%, rgba(124,58,237,.25), transparent 55%), radial-gradient(1200px 600px at 90% 10%, rgba(34,197,94,.18), transparent 55%), radial-gradient(900px 500px at 50% 100%, rgba(59,130,246,.14), transparent 55%), var(--bg); color:var(--text);}
  a{color:inherit}
  .container{max-width:1100px;margin:0 auto;padding:18px}
  .nav{display:flex;gap:12px;align-items:center;justify-content:space-between;padding:14px 18px;border:1px solid var(--border);background:var(--card);border-radius:18px;backdrop-filter: blur(10px);}
  .brand{display:flex;align-items:center;gap:10px;text-decoration:none}
  .brand b{font-size:18px}
  .pill{border:1px solid var(--border);background:var(--card2);padding:9px 12px;border-radius:14px;text-decoration:none;display:inline-flex;gap:8px;align-items:center}
  .pill:hover{transform: translateY(-1px);transition:.15s ease}
  .grid{display:grid;gap:14px}
  @media(min-width:900px){.grid-3{grid-template-columns:repeat(3,1fr)}}
  @media(min-width:650px){.grid-2{grid-template-columns:repeat(2,1fr)}}
  .card{border:1px solid var(--border);background:var(--card);border-radius:18px;padding:16px}
  .card:hover{background:rgba(255,255,255,.075);transition:.15s ease}
  .h1{font-size:22px;font-weight:900;margin:0 0 8px}
  .muted{color:var(--muted)}
  .btn{cursor:pointer;border:1px solid var(--border);background:linear-gradient(180deg, rgba(124,58,237,.95), rgba(124,58,237,.72)); color:white; padding:10px 14px;border-radius:14px;font-weight:700}
  .btn2{cursor:pointer;border:1px solid var(--border);background:linear-gradient(180deg, rgba(34,197,94,.92), rgba(34,197,94,.70)); color:#04110a; padding:10px 14px;border-radius:14px;font-weight:800}
  .btnGhost{cursor:pointer;border:1px solid var(--border);background:var(--card2); color:var(--text); padding:10px 14px;border-radius:14px;font-weight:700}
  .btnDanger{cursor:pointer;border:1px solid rgba(239,68,68,.55);background:rgba(239,68,68,.18); color:#ffd6d6; padding:10px 14px;border-radius:14px;font-weight:800}
  input,select,textarea{width:100%;box-sizing:border-box;border:1px solid var(--border);background:rgba(0,0,0,.18);color:var(--text);padding:12px 12px;border-radius:14px;outline:none}
  input:focus,select:focus,textarea:focus{border-color:rgba(124,58,237,.7);box-shadow:0 0 0 4px rgba(124,58,237,.15)}
  label{display:block;margin:10px 0 6px;font-weight:700}
  .row{display:flex;gap:10px;flex-wrap:wrap;align-items:center}
  .row .grow{flex:1}
  .msgs{margin:14px 0;display:grid;gap:10px}
  .msg{border:1px solid var(--border);background:rgba(255,255,255,.07);padding:12px 14px;border-radius:14px}
  .footer{margin-top:18px;padding:18px;border:1px solid var(--border);border-radius:18px;background:var(--card);color:var(--muted);text-align:center}
  .badge{display:inline-flex;align-items:center;gap:8px;border:1px solid var(--border);background:rgba(0,0,0,.18);padding:6px 10px;border-radius:999px;color:var(--muted);font-size:12px}
</style>
HTML

  cat > app/templates/base.html <<'HTML'
{% load static %}
<!doctype html>
<html lang="fa" dir="rtl">
<head>
  <meta charset="utf-8"/>
  <meta name="viewport" content="width=device-width,initial-scale=1"/>
  <title>{% block title %}{{ site_settings.brand_name|default:"EduCMS" }}{% endblock %}</title>
  {% include "_style.html" %}
</head>
<body>
  <div class="container">
    <div class="nav">
      <a class="brand" href="/">
        <b>{{ site_settings.brand_name|default:"EduCMS" }}</b>
        <span class="badge">RTL • Responsive</span>
      </a>
      <div class="row">
        {% if user.is_authenticated %}
          <a class="pill" href="/accounts/panel/">پنل کاربری</a>
          <a class="pill" href="/orders/my/">سفارش‌ها</a>
          <a class="pill" href="/tickets/">تیکت‌ها</a>
          {% if user.is_staff %}
            <a class="pill" href="/{{ site_settings.admin_path|default:'admin' }}/">ادمین</a>
          {% endif %}
          <form method="post" action="/accounts/logout/" style="margin:0">
            {% csrf_token %}
            <button class="btnDanger" type="submit">خروج</button>
          </form>
        {% else %}
          <a class="pill" href="/accounts/login/">ورود</a>
          <a class="pill" href="/accounts/register/">ثبت‌نام</a>
        {% endif %}
      </div>
    </div>

    {% if messages %}
      <div class="msgs">
        {% for m in messages %}
          <div class="msg">{{ m }}</div>
        {% endfor %}
      </div>
    {% endif %}

    {% block content %}{% endblock %}

    <div class="footer">{{ site_settings.footer_text|default:"© تمامی حقوق محفوظ است." }}</div>
  </div>
</body>
</html>
HTML

  cat > app/templates/accounts/login.html <<'HTML'
{% extends "base.html" %}
{% block title %}ورود{% endblock %}
{% block content %}
  <div class="card" style="max-width:520px;margin:18px auto">
    <h1 class="h1">ورود</h1>
    <p class="muted" style="margin-top:0">برای ورود، ایمیل و گذرواژه را وارد کنید.</p>
    <form method="post">{% csrf_token %}
      <label for="id_email">ایمیل</label>
      {{ form.email }}
      <label for="id_password">گذرواژه</label>
      {{ form.password }}
      <div class="row" style="margin-top:14px">
        <button class="btn grow" type="submit">ورود</button>
        <a class="btnGhost" href="/accounts/forgot/">فراموشی رمز</a>
      </div>
    </form>
  </div>
{% endblock %}
HTML

  cat > app/templates/accounts/register.html <<'HTML'
{% extends "base.html" %}
{% block title %}ثبت‌نام{% endblock %}
{% block content %}
  <div class="card" style="max-width:700px;margin:18px auto">
    <h1 class="h1">ثبت‌نام</h1>
    <p class="muted" style="margin-top:0">حساب کاربری با ایمیل ساخته می‌شود. سایر فیلدها را ادمین می‌تواند از پنل مدیریت تغییر دهد.</p>
    <form method="post">{% csrf_token %}
      <div class="grid grid-2">
        <div>
          <label>ایمیل</label>
          {{ form.email }}
        </div>
        <div>
          <label>سوال امنیتی</label>
          {{ form.security_question }}
        </div>
        <div>
          <label>گذرواژه</label>
          {{ form.password1 }}
        </div>
        <div>
          <label>تکرار گذرواژه</label>
          {{ form.password2 }}
        </div>
      </div>

      <div style="margin-top:10px">
        <label>پاسخ سوال امنیتی</label>
        {{ form.security_answer }}
      </div>

      {% for name, f in form.dynamic_fields %}
        <div style="margin-top:10px">
          <label>{{ f.label }}</label>
          {{ form[name] }}
        </div>
      {% endfor %}

      <div class="row" style="margin-top:16px">
        <button class="btn2 grow" type="submit">ساخت حساب</button>
        <a class="btnGhost" href="/accounts/login/">ورود</a>
      </div>
    </form>
  </div>
{% endblock %}
HTML

  cat > app/templates/accounts/forgot.html <<'HTML'
{% extends "base.html" %}
{% block title %}فراموشی رمز{% endblock %}
{% block content %}
  <div class="card" style="max-width:520px;margin:18px auto">
    <h1 class="h1">فراموشی رمز</h1>
    <p class="muted" style="margin-top:0">ایمیل را وارد کنید تا مرحله سوال امنیتی نمایش داده شود.</p>
    <form method="post">{% csrf_token %}
      <label>ایمیل</label>
      {{ form.email }}
      <div style="margin-top:14px">
        <button class="btn grow" type="submit">ادامه</button>
      </div>
    </form>
  </div>
{% endblock %}
HTML

  cat > app/templates/accounts/reset_security.html <<'HTML'
{% extends "base.html" %}
{% block title %}بازنشانی رمز{% endblock %}
{% block content %}
  <div class="card" style="max-width:620px;margin:18px auto">
    <h1 class="h1">بازنشانی رمز با سوال امنیتی</h1>
    <div class="msg" style="margin:10px 0">
      <b>سوال:</b> {{ question.question }}
    </div>
    <form method="post">{% csrf_token %}
      <label>پاسخ</label>
      {{ form.answer }}
      <div class="grid grid-2" style="margin-top:10px">
        <div>
          <label>گذرواژه جدید</label>
          {{ form.new_password1 }}
        </div>
        <div>
          <label>تکرار گذرواژه جدید</label>
          {{ form.new_password2 }}
        </div>
      </div>
      <div style="margin-top:14px">
        <button class="btn2 grow" type="submit">تغییر گذرواژه</button>
      </div>
    </form>
  </div>
{% endblock %}
HTML

  cat > app/templates/accounts/panel.html <<'HTML'
{% extends "base.html" %}
{% block title %}پنل کاربری{% endblock %}
{% block content %}
  <div class="card" style="margin-top:18px">
    <h1 class="h1">پنل کاربری</h1>
    <p class="muted" style="margin-top:0">از اینجا می‌توانید سفارش‌ها، تیکت‌ها و تنظیمات حساب را مدیریت کنید.</p>
    <div class="grid grid-3" style="margin-top:12px">
      <a class="card" href="/orders/my/">
        <b>سفارش‌ها</b>
        <div class="muted">مشاهده سفارش‌ها و وضعیت پرداخت</div>
      </a>
      <a class="card" href="/tickets/">
        <b>تیکت‌ها</b>
        <div class="muted">ارسال و پیگیری تیکت‌ها</div>
      </a>
      <a class="card" href="/accounts/change-password/">
        <b>تغییر گذرواژه</b>
        <div class="muted">امنیت حساب را به‌روزرسانی کنید</div>
      </a>
    </div>
  </div>
{% endblock %}
HTML

  cat > app/templates/accounts/profile.html <<'HTML'
{% extends "base.html" %}
{% block title %}پروفایل{% endblock %}
{% block content %}
  <div class="card" style="max-width:640px;margin:18px auto">
    <h1 class="h1">پروفایل</h1>
    <form method="post">{% csrf_token %}
      <label>ایمیل</label>
      {{ form.email }}
      <div class="muted" style="margin-top:8px">در این نسخه ایمیل شناسه ورود است و از پنل مدیریت قابل تغییر است.</div>
    </form>
  </div>
{% endblock %}
HTML

  cat > app/templates/accounts/change_password.html <<'HTML'
{% extends "base.html" %}
{% block title %}تغییر گذرواژه{% endblock %}
{% block content %}
  <div class="card" style="max-width:640px;margin:18px auto">
    <h1 class="h1">تغییر گذرواژه</h1>
    <form method="post">{% csrf_token %}
      <label>گذرواژه فعلی</label>
      {{ form.old_password }}
      <div class="grid grid-2" style="margin-top:10px">
        <div>
          <label>گذرواژه جدید</label>
          {{ form.new_password1 }}
        </div>
        <div>
          <label>تکرار گذرواژه جدید</label>
          {{ form.new_password2 }}
        </div>
      </div>
      <div style="margin-top:14px">
        <button class="btn2 grow" type="submit">ذخیره</button>
      </div>
    </form>
  </div>
{% endblock %}
HTML

  cat > app/templates/courses/course_list.html <<'HTML'
{% extends "base.html" %}
{% block title %}دوره‌ها - {{ site_settings.brand_name|default:"EduCMS" }}{% endblock %}
{% block content %}
  <div class="card" style="margin-top:18px">
    <div class="row" style="justify-content:space-between">
      <div>
        <h1 class="h1">دوره‌های آموزشی</h1>
        <div class="muted">جدیدترین دوره‌های منتشر شده</div>
      </div>
      <div class="badge">Production Ready</div>
    </div>

    <div class="grid grid-3" style="margin-top:14px">
      {% for c in object_list %}
        <a href="{% url 'course_detail' c.slug %}" class="card" style="text-decoration:none">
          <div style="display:flex;justify-content:space-between;gap:10px;align-items:flex-start">
            <b style="font-size:16px">{{ c.title }}</b>
            <span class="badge">{% if c.is_free_for_all %}رایگان{% elif c.price_toman %}{{ c.price_toman }} تومان{% else %}رایگان{% endif %}</span>
          </div>
          <div class="muted" style="margin-top:8px;line-height:1.9">{{ c.summary|default:"—" }}</div>
          <div class="muted" style="margin-top:10px;font-size:12px">دسته‌بندی: {{ c.category.title|default:"بدون دسته" }}</div>
        </a>
      {% empty %}
        <div class="muted">هنوز دوره‌ای منتشر نشده است.</div>
      {% endfor %}
    </div>
  </div>
{% endblock %}
HTML

  cat > app/templates/courses/course_detail.html <<'HTML'
{% extends "base.html" %}
{% block title %}{{ object.title }} - {{ site_settings.brand_name|default:"EduCMS" }}{% endblock %}
{% block content %}
  <div class="card" style="margin-top:18px">
    <div class="row" style="justify-content:space-between;align-items:flex-start">
      <div class="grow">
        <h1 class="h1">{{ object.title }}</h1>
        <div class="muted" style="line-height:1.9">{{ object.summary }}</div>
        <div class="muted" style="margin-top:8px;font-size:12px">دسته‌بندی: {{ object.category.title|default:"بدون دسته" }}</div>
      </div>
      <div style="min-width:240px">
        {% if has_access %}
          <div class="msg"><b>دسترسی شما فعال است.</b></div>
        {% else %}
          {% if object.is_free_for_all %}
            <div class="msg"><b>این دوره برای همه رایگان است.</b></div>
          {% elif object.price_toman %}
            <a class="btn" style="display:block;text-align:center;text-decoration:none" href="/orders/checkout/{{ object.slug }}/">خرید کارت‌به‌کارت</a>
          {% else %}
            <div class="msg"><b>این دوره رایگان است.</b></div>
          {% endif %}
        {% endif %}
      </div>
    </div>

    <div class="msg" style="margin-top:14px;line-height:2">{{ object.description|linebreaks }}</div>

    <div style="margin-top:14px">
      <h2 class="h1" style="font-size:18px">سرفصل‌ها</h2>
      {% for s in object.sections.all %}
        <div class="card" style="margin-top:10px">
          <b>{{ s.title }}</b>
          <ul style="margin:10px 0 0; padding-right:18px; line-height:2">
            {% for l in s.lessons.all %}
              <li>
                {{ l.title }}
                {% if has_access or l.is_free_preview %}
                  {% if l.video_url %} — <a href="{{ l.video_url }}" target="_blank">لینک ویدیو</a>{% endif %}
                  {% if l.video_file %} — <a href="{{ l.video_file.url }}" target="_blank">مشاهده/دانلود</a>{% endif %}
                {% else %}
                  — <span class="muted">قفل است</span>
                {% endif %}
              </li>
            {% endfor %}
          </ul>
        </div>
      {% endfor %}
    </div>
  </div>
{% endblock %}
HTML

  cat > app/templates/orders/checkout.html <<'HTML'
{% extends "base.html" %}
{% block title %}پرداخت - {{ course.title }}{% endblock %}
{% block content %}
<div class="card" style="max-width:820px;margin:18px auto">
  <h1 class="h1">پرداخت کارت‌به‌کارت</h1>
  <div class="muted">دوره: {{ course.title }}</div>

  <form method="post" class="card" style="margin-top:12px">{% csrf_token %}
    <div class="row">
      <div class="grow">{{ coupon_form.coupon_code }}</div>
      <button class="btnGhost" type="submit">اعمال کد</button>
    </div>
    <div class="muted" style="margin-top:8px;font-size:12px">
      {% if first_purchase_eligible %}اگر کد تخفیف وارد نکنید، ممکن است تخفیف خرید اول به صورت خودکار اعمال شود.{% endif %}
    </div>
  </form>

  <div class="grid grid-2" style="margin-top:12px">
    <div class="card">
      <b>خلاصه پرداخت</b>
      <div class="muted" style="margin-top:8px">مبلغ پایه: <b>{{ order.amount }}</b> تومان</div>
      <div class="muted" style="margin-top:6px">تخفیف: <b>{{ order.discount_amount }}</b> تومان {% if discount_label %} ({{ discount_label }}){% endif %}</div>
      <div class="muted" style="margin-top:6px">مبلغ نهایی: <b>{{ order.final_amount }}</b> تومان</div>
    </div>
    <div class="card">
      <b>اطلاعات کارت</b>
      <div class="muted" style="margin-top:8px">نام صاحب حساب: <b>{{ setting.account_holder|default:"(تنظیم نشده)" }}</b></div>
      <div class="muted" style="margin-top:6px">شماره کارت: <b dir="ltr">{{ setting.card_number|default:"(تنظیم نشده)" }}</b></div>
      {% if setting.note %}<div class="muted" style="margin-top:6px">{{ setting.note }}</div>{% endif %}
    </div>
  </div>

  <div style="margin-top:12px">
    <a class="btn2" style="display:inline-block;text-decoration:none" href="/orders/receipt/{{ order.id }}/">آپلود رسید پرداخت</a>
  </div>
</div>
{% endblock %}
HTML

  cat > app/templates/orders/upload_receipt.html <<'HTML'
{% extends "base.html" %}
{% block title %}آپلود رسید{% endblock %}
{% block content %}
<div class="card" style="max-width:760px;margin:18px auto">
  <h1 class="h1">آپلود رسید</h1>
  <div class="muted">سفارش: {{ order.id }}</div>
  <form method="post" enctype="multipart/form-data" style="margin-top:12px">{% csrf_token %}
    {{ form.as_p }}
    <button class="btn2" type="submit">ثبت رسید</button>
  </form>
</div>
{% endblock %}
HTML

  cat > app/templates/orders/my_orders.html <<'HTML'
{% extends "base.html" %}
{% block title %}سفارش‌های من{% endblock %}
{% block content %}
<div class="card" style="margin-top:18px">
  <h1 class="h1">سفارش‌های من</h1>
  <div class="grid" style="margin-top:12px">
    {% for o in orders %}
      <div class="card">
        <div class="row" style="justify-content:space-between;align-items:flex-start">
          <div>
            <b>{{ o.course.title }}</b>
            <div class="muted" style="margin-top:6px">پایه: {{ o.amount }} | تخفیف: {{ o.discount_amount }} | نهایی: {{ o.final_amount }} تومان</div>
          </div>
          <span class="badge">{{ o.get_status_display }}</span>
        </div>
        {% if o.status != "paid" %}
          <a class="pill" style="margin-top:10px;display:inline-flex" href="/orders/receipt/{{ o.id }}/">آپلود/ویرایش رسید</a>
        {% endif %}
      </div>
    {% empty %}
      <div class="muted">سفارشی ندارید.</div>
    {% endfor %}
  </div>
</div>
{% endblock %}
HTML

  cat > app/templates/tickets/list.html <<'HTML'
{% extends "base.html" %}
{% block title %}تیکت‌ها{% endblock %}
{% block content %}
<div class="card" style="margin-top:18px">
  <div class="row" style="justify-content:space-between">
    <div>
      <h1 class="h1">تیکت‌های من</h1>
      <div class="muted">لیست تیکت‌های ثبت شده</div>
    </div>
    <a class="btn2" style="text-decoration:none" href="/tickets/new/">ثبت تیکت</a>
  </div>
  <div class="grid" style="margin-top:12px">
    {% for t in tickets %}
      <a class="card" style="text-decoration:none" href="/tickets/{{ t.id }}/">
        <b>{{ t.subject }}</b>
        <div class="muted" style="margin-top:6px">وضعیت: {{ t.get_status_display }} | {{ t.created_at }}</div>
      </a>
    {% empty %}
      <div class="muted">تیکتی ندارید.</div>
    {% endfor %}
  </div>
</div>
{% endblock %}
HTML

  cat > app/templates/tickets/create.html <<'HTML'
{% extends "base.html" %}
{% block title %}ثبت تیکت{% endblock %}
{% block content %}
<div class="card" style="max-width:820px;margin:18px auto">
  <h1 class="h1">ثبت تیکت</h1>
  <form method="post" enctype="multipart/form-data" style="margin-top:12px">{% csrf_token %}
    {{ form.as_p }}
    <button class="btn2" type="submit">ثبت</button>
  </form>
</div>
{% endblock %}
HTML

  cat > app/templates/tickets/detail.html <<'HTML'
{% extends "base.html" %}
{% block title %}جزئیات تیکت{% endblock %}
{% block content %}
<div class="card" style="margin-top:18px">
  <h1 class="h1">{{ ticket.subject }}</h1>
  <div class="muted">وضعیت: {{ ticket.get_status_display }}</div>
  <div class="msg" style="margin-top:10px;white-space:pre-line">{{ ticket.description }}</div>
  {% if ticket.attachment %}
    <a class="pill" href="{{ ticket.attachment.url }}" target="_blank">دانلود پیوست</a>
  {% endif %}

  <div style="margin-top:14px">
    <h2 class="h1" style="font-size:18px">پاسخ‌ها</h2>
    <div class="grid">
      {% for r in ticket.replies.all %}
        <div class="card">
          <div class="muted" style="font-size:12px">{{ r.created_at }}</div>
          <div style="white-space:pre-line;margin-top:6px">{{ r.message }}</div>
          {% if r.attachment %}
            <a class="pill" style="margin-top:8px;display:inline-flex" href="{{ r.attachment.url }}" target="_blank">دانلود پیوست</a>
          {% endif %}
        </div>
      {% empty %}
        <div class="muted">هنوز پاسخی ثبت نشده.</div>
      {% endfor %}
    </div>
  </div>

  <div class="card" style="margin-top:14px">
    <h3 class="h1" style="font-size:18px">ارسال پاسخ</h3>
    <form method="post" enctype="multipart/form-data">{% csrf_token %}
      {{ form.as_p }}
      <button class="btn2" type="submit">ارسال</button>
    </form>
  </div>
</div>
{% endblock %}
HTML

  cat > app/templates/settings/admin_path.html <<'HTML'
{% extends "base.html" %}
{% block title %}تغییر مسیر ادمین{% endblock %}
{% block content %}
<div class="card" style="max-width:680px;margin:18px auto">
  <h1 class="h1">تغییر مسیر پنل ادمین</h1>
  <div class="muted">مسیر فعلی: <b>/{{ current }}/</b></div>
  <form method="post" style="margin-top:12px">{% csrf_token %}
    {{ form.as_p }}
    <button class="btn2" type="submit">ذخیره</button>
  </form>
  <div class="muted" style="margin-top:10px;font-size:12px">بعد از تغییر مسیر، آدرس /admin/ دیگر کار نمی‌کند.</div>
</div>
{% endblock %}
HTML

  cat > app/templates/admin/admin_account.html <<'HTML'
{% extends "admin/base_site.html" %}
{% block content %}
<div style="max-width:720px">
  <h1>تغییر ایمیل و رمز عبور ادمین</h1>
  <form method="post">{% csrf_token %}
    {{ form.as_p }}
    <button type="submit" class="default">ذخیره</button>
  </form>
  <p style="margin-top:12px">بعد از ذخیره، همچنان داخل پنل می‌مانید.</p>
</div>
{% endblock %}
HTML

  cat > app/entrypoint.sh <<'SH'
#!/usr/bin/env sh
set -e
sleep 2

python manage.py makemigrations accounts settingsapp courses payments tickets
python manage.py migrate --noinput --fake-initial

python manage.py shell <<'PY'
import os
from django.contrib.auth import get_user_model
from settingsapp.models import SiteSetting
from payments.models import BankTransferSetting
from accounts.models import SecurityQuestion, SecurityPolicy

User = get_user_model()
admin_u = (os.getenv("ADMIN_USERNAME") or "").strip()
admin_p = (os.getenv("ADMIN_PASSWORD") or "").strip()
admin_e = (os.getenv("ADMIN_EMAIL") or "").strip().lower()
initial_admin_path = os.getenv("INITIAL_ADMIN_PATH","admin") or "admin"

if not admin_e:
    admin_e = admin_u if "@" in admin_u else "admin@example.com"
if not admin_u:
    admin_u = admin_e

u, created = User.objects.get_or_create(email=admin_e, defaults={})
u.is_staff = True
u.is_superuser = True
u.is_active = True
u.set_password(admin_p or "admin")
u.save()

s, _ = SiteSetting.objects.get_or_create(id=1, defaults={"brand_name":"EduCMS","footer_text":"© تمامی حقوق محفوظ است.","admin_path":initial_admin_path})
if not s.admin_path:
    s.admin_path = initial_admin_path
    s.save(update_fields=["admin_path"])

BankTransferSetting.objects.get_or_create(id=1)
SecurityPolicy.objects.get_or_create(id=1, defaults={"allow_user_change_answer": True, "allow_user_choose_question": True})

defaults = [
"نام اولین معلم شما چه بود؟",
"نام بهترین دوست دوران کودکی شما چیست؟",
"نام شهر محل تولد شما چیست؟",
"نام اولین مدرسه شما چیست؟",
"رنگ مورد علاقه شما چیست؟",
"نام حیوان خانگی (یا مورد علاقه) شما چیست؟",
"آخرین ۴ رقم شماره تلفن قدیمی شما چیست؟",
"نام خیابانی که در آن بزرگ شدید چیست؟",
"نام کتاب مورد علاقه شما چیست؟",
"نام فیلم مورد علاقه شما چیست؟",
"نام اولین مدیر مدرسه شما چیست؟",
"نام تیم ورزشی مورد علاقه شما چیست؟",
"نام اولین شرکت/محل کار شما چیست؟",
"نام یکی از معلمان محبوب شما چیست؟",
"بهترین درس دوران مدرسه شما چه بود؟",
"نام یک مکان خاطره‌انگیز برای شما چیست؟",
"نام اولین گوشی شما چه بود؟",
"چه غذایی را بیشتر دوست دارید؟",
"نام یک شخصیت الهام‌بخش برای شما چیست؟",
"نام یک بازی/سرگرمی محبوب شما چیست؟",
"نام یک شاعر/نویسنده مورد علاقه شما چیست؟",
"نام یک کشور مورد علاقه شما چیست؟",
"نام اولین همکلاسی نزدیک شما چیست؟",
"در کودکی دوست داشتید چه شغلی داشته باشید؟",
"نام اولین استاد/معلم آنلاین شما چیست؟",
]
for i,q in enumerate(defaults):
    SecurityQuestion.objects.get_or_create(question=q, defaults={"is_active": True, "order": i})

print("Admin ready:", u.email, "created=", created)
print("Admin path:", s.admin_path)
PY

python manage.py collectstatic --noinput
exec gunicorn educms.wsgi:application --bind 0.0.0.0:8000 --workers 3 --timeout 60
SH
  chmod +x app/entrypoint.sh

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
  echo "Site:    https://${DOMAIN}"
  echo "Admin:   https://${DOMAIN}/${ADMIN_PATH}/"
  echo "Panel:   https://${DOMAIN}/accounts/panel/"
  echo "Tickets: https://${DOMAIN}/tickets/"
  echo "Orders:  https://${DOMAIN}/orders/my/"
  echo "Admin Account (inside admin): /admin/account/"
  echo "Backup:  option 5 in menu (outputs .sql)"
}

do_stop(){ compose_cd_or_fail; docker compose down --remove-orphans || true; ok "Stopped."; }
do_start(){ compose_cd_or_fail; docker compose up -d --build; ok "Started."; }
do_restart(){ compose_cd_or_fail; docker compose up -d --build; ok "Restarted."; }
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
