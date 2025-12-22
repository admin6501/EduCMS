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
  mkdir -p app/templates/{courses,accounts,orders,tickets,settings,admin,partials} app/static app/media nginx certbot/www certbot/conf
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
LOGIN_REDIRECT_URL = "/panel/"
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
from django.contrib.auth.models import AbstractUser
from django.db import models
from django.utils.translation import gettext_lazy as _

class User(AbstractUser):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False, verbose_name=_("شناسه"))
    email = models.EmailField(blank=True, null=True, verbose_name=_("ایمیل"))
    first_name = models.CharField(max_length=150, blank=True, verbose_name=_("نام"))
    last_name = models.CharField(max_length=150, blank=True, verbose_name=_("نام خانوادگی"))
    security_question = models.CharField(max_length=200, blank=True, verbose_name=_("سوال امنیتی"))
    security_answer = models.CharField(max_length=200, blank=True, verbose_name=_("پاسخ سوال امنیتی"))

    class Meta:
        verbose_name = _("کاربر")
        verbose_name_plural = _("کاربران")
PY

  cat > app/accounts/admin.py <<'PY'
from django.contrib import admin
from django.contrib.auth.admin import UserAdmin as BaseUserAdmin
from .models import User

@admin.register(User)
class UserAdmin(BaseUserAdmin):
    fieldsets = (
        (None, {"fields": ("username","password")}),
        ("اطلاعات شخصی", {"fields": ("first_name","last_name","email")}),
        ("امنیت", {"fields": ("security_question","security_answer")}),
        ("دسترسی‌ها", {"fields": ("is_active","is_staff","is_superuser","groups","user_permissions")}),
        ("تاریخ‌ها", {"fields": ("last_login","date_joined")}),
    )
    add_fieldsets = (
        (None, {"classes": ("wide",), "fields": ("username","email","password1","password2","is_staff","is_superuser")}),
    )
    list_display = ("username","email","is_staff","is_superuser","is_active")
    list_filter = ("is_staff","is_superuser","is_active","groups")
    search_fields = ("username","email","first_name","last_name")
    ordering = ("username",)
    filter_horizontal = ("groups","user_permissions")
PY

  cat > app/accounts/forms.py <<'PY'
from django import forms
from django.contrib.auth import get_user_model
from django.contrib.auth.forms import UserCreationForm
from django.utils.translation import gettext_lazy as _

User = get_user_model()

SECURITY_QUESTIONS = [
    "نام اولین معلم شما چه بود؟",
    "نام بهترین دوست دوران کودکی شما چیست؟",
    "نام خیابانی که در آن بزرگ شدید چیست؟",
    "نام اولین مدرسه شما چیست؟",
    "نام شهر تولد مادر شما چیست؟",
    "نام شهر تولد پدر شما چیست؟",
    "نام حیوان خانگی دوران کودکی شما چیست؟",
    "نام اولین کتابی که خواندید چیست؟",
    "نام اولین فیلمی که دیدید چیست؟",
    "نام اولین گوشی شما چه بود؟",
    "نام اولین شرکت/محل کار شما چیست؟",
    "رنگ مورد علاقه شما چیست؟",
    "غذای مورد علاقه شما چیست؟",
    "نام اولین بازی کامپیوتری/کنسول شما چیست؟",
    "نام اولین وبسایتی که زیاد استفاده می‌کردید چیست؟",
    "نام ورزش مورد علاقه شما چیست؟",
    "نام یک شخصیت تاریخی مورد علاقه شما چیست؟",
    "نام یک شخصیت کارتونی مورد علاقه شما چیست؟",
    "نام اولین استاد خصوصی شما چیست؟",
    "نام اولین همکلاسی نزدیک شما چیست؟",
    "نام روستای پدربزرگ شما چیست؟",
    "نام روستای مادربزرگ شما چیست؟",
    "نام اولین پروژه مدرسه‌ای شما چه بود؟",
    "نام اولین دوره آموزشی که شرکت کردید چیست؟",
    "نام اولین اپلیکیشنی که نصب کردید چیست؟",
    "نام اولین شبکه اجتماعی شما چیست؟",
    "نام تیم ورزشی محبوب شما چیست؟",
    "نام مدل ماشین رویایی شما چیست؟",
    "نام اولین سفر شما کجا بود؟",
    "نام اولین استاد دانشگاه شما چیست؟",
]

class RegisterForm(UserCreationForm):
    email = forms.EmailField(required=False, label=_("ایمیل (اختیاری)"))
    first_name = forms.CharField(required=False, label=_("نام"))
    last_name = forms.CharField(required=False, label=_("نام خانوادگی"))

    security_question = forms.ChoiceField(choices=[(q,q) for q in SECURITY_QUESTIONS], label=_("سوال امنیتی"))
    security_answer = forms.CharField(label=_("پاسخ سوال امنیتی"))

    password1 = forms.CharField(label=_("گذرواژه"), widget=forms.PasswordInput)
    password2 = forms.CharField(label=_("تکرار گذرواژه"), widget=forms.PasswordInput)

    class Meta:
        model = User
        fields = ("username","email","first_name","last_name","security_question","security_answer")
        labels = {"username": _("نام کاربری")}
PY

  cat > app/accounts/views.py <<'PY'
from django.contrib.auth.views import LoginView, LogoutView
from django.views.generic import CreateView, FormView
from django.urls import reverse_lazy
from django.contrib import messages
from django.contrib.auth import get_user_model
from django.contrib.auth.forms import SetPasswordForm
from django.shortcuts import redirect, render

from .forms import RegisterForm

User = get_user_model()

class SiteLoginView(LoginView):
    template_name = "accounts/login.html"

class SiteLogoutView(LogoutView):
    http_method_names = ["post"]
    next_page = "/"

class RegisterView(CreateView):
    form_class = RegisterForm
    template_name = "accounts/register.html"
    success_url = reverse_lazy("login")

class ForgotPasswordUsernameFormView(FormView):
    template_name = "accounts/forgot_username.html"
    success_url = reverse_lazy("forgot_question")

    def get_form_class(self):
        from django import forms
        class F(forms.Form):
            username = forms.CharField(label="نام کاربری")
        return F

    def form_valid(self, form):
        self.request.session["fp_username"] = form.cleaned_data["username"]
        return super().form_valid(form)

class ForgotPasswordQuestionFormView(FormView):
    template_name = "accounts/forgot_question.html"
    success_url = reverse_lazy("forgot_reset")

    def get_form_class(self):
        from django import forms
        class F(forms.Form):
            answer = forms.CharField(label="پاسخ سوال امنیتی")
        return F

    def dispatch(self, request, *args, **kwargs):
        u = request.session.get("fp_username")
        if not u:
            return redirect("forgot_username")
        return super().dispatch(request, *args, **kwargs)

    def get_context_data(self, **kwargs):
        ctx = super().get_context_data(**kwargs)
        username = self.request.session.get("fp_username")
        user = User.objects.filter(username=username).first()
        ctx["question"] = (getattr(user, "security_question", "") or "")
        return ctx

    def form_valid(self, form):
        username = self.request.session.get("fp_username")
        user = User.objects.filter(username=username).first()
        if not user:
            messages.error(self.request, "کاربر یافت نشد.")
            return redirect("forgot_username")
        if (form.cleaned_data["answer"] or "").strip() != (getattr(user, "security_answer", "") or "").strip():
            messages.error(self.request, "پاسخ نادرست است.")
            return redirect("forgot_question")
        self.request.session["fp_ok"] = True
        return super().form_valid(form)

def forgot_reset(request):
    username = request.session.get("fp_username")
    ok = request.session.get("fp_ok", False)
    user = User.objects.filter(username=username).first()
    if not (ok and user):
        return redirect("forgot_username")
    form = SetPasswordForm(user, request.POST or None)
    if request.method == "POST" and form.is_valid():
        form.save()
        request.session.pop("fp_username", None)
        request.session.pop("fp_ok", None)
        messages.success(request, "رمز عبور با موفقیت تغییر کرد. اکنون وارد شوید.")
        return redirect("login")
    return render(request, "accounts/forgot_reset.html", {"form": form})
PY

  cat > app/accounts/urls.py <<'PY'
from django.urls import path
from .views import SiteLoginView, SiteLogoutView, RegisterView, ForgotPasswordUsernameFormView, ForgotPasswordQuestionFormView, forgot_reset

urlpatterns = [
    path("login/", SiteLoginView.as_view(), name="login"),
    path("logout/", SiteLogoutView.as_view(), name="logout"),
    path("register/", RegisterView.as_view(), name="register"),

    path("forgot/", ForgotPasswordUsernameFormView.as_view(), name="forgot_username"),
    path("forgot/question/", ForgotPasswordQuestionFormView.as_view(), name="forgot_question"),
    path("forgot/reset/", forgot_reset, name="forgot_reset"),
]
PY

  cat > app/settingsapp/apps.py <<'PY'
from django.apps import AppConfig
class SettingsappConfig(AppConfig):
    default_auto_field = "django.db.models.BigAutoField"
    name = "settingsapp"
    verbose_name = "پنل کاربری"
PY

  cat > app/settingsapp/models.py <<'PY'
from django.db import models
from django.utils.translation import gettext_lazy as _

class SiteSetting(models.Model):
    brand_name = models.CharField(max_length=120, default="EduCMS", verbose_name=_("نام برند"))
    footer_text = models.TextField(blank=True, verbose_name=_("متن فوتر"))
    admin_path = models.SlugField(max_length=50, default="admin", verbose_name=_("مسیر پنل ادمین"))
    allow_profile_edit = models.BooleanField(default=True, verbose_name=_("اجازه ویرایش پروفایل توسط کاربر"))
    updated_at = models.DateTimeField(auto_now=True, verbose_name=_("آخرین بروزرسانی"))

    class Meta:
        verbose_name = _("تنظیمات سایت")
        verbose_name_plural = _("تنظیمات سایت")

    def __str__(self): return "Site Settings"

class TemplateText(models.Model):
    key = models.SlugField(max_length=150, unique=True, verbose_name=_("کلید"))
    title = models.CharField(max_length=200, verbose_name=_("عنوان"))
    value = models.TextField(blank=True, verbose_name=_("مقدار"))
    hint = models.CharField(max_length=300, blank=True, verbose_name=_("راهنما"))
    updated_at = models.DateTimeField(auto_now=True, verbose_name=_("آخرین بروزرسانی"))

    class Meta:
        ordering = ["key"]
        verbose_name = _("متن قالب")
        verbose_name_plural = _("متن‌های قالب")

    def __str__(self): return self.key
PY

  cat > app/settingsapp/admin.py <<'PY'
from django.contrib import admin
from .models import SiteSetting, TemplateText

admin.site.site_header = "پنل مدیریت"
admin.site.site_title = "پنل مدیریت"
admin.site.index_title = "مدیریت سایت"

@admin.register(SiteSetting)
class SiteSettingAdmin(admin.ModelAdmin):
    fieldsets = (
        ("General", {"fields": ("brand_name","footer_text")}),
        ("Admin", {"fields": ("admin_path",)}),
        ("User Panel", {"fields": ("allow_profile_edit",)}),
    )

@admin.register(TemplateText)
class TemplateTextAdmin(admin.ModelAdmin):
    list_display = ("key","title","updated_at")
    search_fields = ("key","title","value")
PY

  cat > app/settingsapp/context_processors.py <<'PY'
from .models import SiteSetting, TemplateText
def site_context(request):
    s = SiteSetting.objects.first()
    texts = {t.key: t.value for t in TemplateText.objects.all()}
    return {"site_settings": s, "tpl": texts}
PY

  cat > app/settingsapp/forms.py <<'PY'
from django import forms
from django.utils.translation import gettext_lazy as _

class ProfileForm(forms.Form):
    first_name = forms.CharField(required=False, label=_("نام"))
    last_name = forms.CharField(required=False, label=_("نام خانوادگی"))
    email = forms.EmailField(required=False, label=_("ایمیل"))

class ChangePasswordForm(forms.Form):
    old_password = forms.CharField(widget=forms.PasswordInput, label=_("رمز فعلی"))
    new_password1 = forms.CharField(widget=forms.PasswordInput, label=_("رمز جدید"))
    new_password2 = forms.CharField(widget=forms.PasswordInput, label=_("تکرار رمز جدید"))

    def clean(self):
        c = super().clean()
        if c.get("new_password1") != c.get("new_password2"):
            raise forms.ValidationError(_("رمز جدید و تکرار آن یکسان نیست."))
        return c
PY

  cat > app/settingsapp/views.py <<'PY'
from django.contrib.auth.decorators import login_required
from django.shortcuts import render, redirect
from django.contrib import messages

from .models import SiteSetting
from .forms import ProfileForm, ChangePasswordForm
from payments.models import Order
from tickets.models import Ticket

@login_required
def dashboard(request):
    orders = Order.objects.filter(user=request.user).order_by("-created_at")[:10]
    tickets = Ticket.objects.filter(user=request.user).order_by("-created_at")[:10]
    return render(request, "settings/dashboard.html", {"orders": orders, "tickets": tickets})

@login_required
def profile(request):
    s = SiteSetting.objects.first()
    allow = True if not s else bool(getattr(s, "allow_profile_edit", True))
    if not allow:
        messages.error(request, "ویرایش پروفایل توسط ادمین غیرفعال شده است.")
        return redirect("panel_dashboard")

    form = ProfileForm(request.POST or None, initial={
        "first_name": request.user.first_name,
        "last_name": request.user.last_name,
        "email": request.user.email,
    })
    if request.method == "POST" and form.is_valid():
        request.user.first_name = form.cleaned_data.get("first_name","")
        request.user.last_name = form.cleaned_data.get("last_name","")
        request.user.email = form.cleaned_data.get("email","")
        request.user.save()
        messages.success(request, "پروفایل ذخیره شد.")
        return redirect("panel_profile")
    return render(request, "settings/profile.html", {"form": form})

@login_required
def change_password(request):
    form = ChangePasswordForm(request.POST or None)
    if request.method == "POST" and form.is_valid():
        if not request.user.check_password(form.cleaned_data["old_password"]):
            messages.error(request, "رمز فعلی صحیح نیست.")
            return redirect("panel_password")
        request.user.set_password(form.cleaned_data["new_password1"])
        request.user.save()
        messages.success(request, "رمز عبور تغییر کرد. دوباره وارد شوید.")
        return redirect("/accounts/login/")
    return render(request, "settings/change_password.html", {"form": form})
PY

  cat > app/settingsapp/urls.py <<'PY'
from django.urls import path
from .views import dashboard, profile, change_password

urlpatterns = [
    path("", dashboard, name="panel_dashboard"),
    path("profile/", profile, name="panel_profile"),
    path("password/", change_password, name="panel_password"),
]
PY

  cat > app/settingsapp/admin_views.py <<'PY'
from django.contrib.admin.views.decorators import staff_member_required
from django.contrib.auth import update_session_auth_hash
from django.contrib import messages
from django.shortcuts import render, redirect
from django import forms

class AdminAccountForm(forms.Form):
    username = forms.CharField(max_length=150, label="نام کاربری جدید")
    password1 = forms.CharField(widget=forms.PasswordInput, label="رمز عبور جدید")
    password2 = forms.CharField(widget=forms.PasswordInput, label="تکرار رمز عبور جدید")

    def clean(self):
        c = super().clean()
        if c.get("password1") != c.get("password2"):
            raise forms.ValidationError("رمزها یکسان نیستند.")
        return c

@staff_member_required
def admin_account_in_admin(request):
    form = AdminAccountForm(request.POST or None, initial={"username": request.user.username})
    if request.method == "POST" and form.is_valid():
        u = request.user
        u.username = form.cleaned_data["username"]
        u.set_password(form.cleaned_data["password1"])
        u.save()
        update_session_auth_hash(request, u)
        messages.success(request, "نام کاربری و رمز عبور با موفقیت تغییر کرد.")
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
PY

  cat > app/courses/admin.py <<'PY'
from django.contrib import admin
from .models import Category, Course

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
    def get_queryset(self):
        return Course.objects.filter(status=PublishStatus.PUBLISHED).select_related("owner","category")
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
from django.conf import settings
from django.utils.translation import gettext_lazy as _

from courses.models import Course

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
    amount = models.PositiveIntegerField(default=0, verbose_name=_("مبلغ"))
    status = models.CharField(max_length=30, choices=OrderStatus.choices, default=OrderStatus.PENDING_PAYMENT, verbose_name=_("وضعیت"))
    created_at = models.DateTimeField(auto_now_add=True, verbose_name=_("ایجاد"))

    class Meta:
        ordering = ["-created_at"]
        verbose_name = _("سفارش")
        verbose_name_plural = _("سفارش‌ها")
PY

  cat > app/payments/admin.py <<'PY'
from django.contrib import admin
from .models import Order

@admin.register(Order)
class OrderAdmin(admin.ModelAdmin):
    list_display = ("id","user","course","amount","status","created_at")
    list_filter = ("status","created_at")
    search_fields = ("user__username","course__title")
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

class Ticket(models.Model):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    user = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="tickets", verbose_name=_("کاربر"))
    subject = models.CharField(max_length=200, verbose_name=_("موضوع"))
    description = models.TextField(verbose_name=_("توضیحات"))
    created_at = models.DateTimeField(auto_now_add=True, verbose_name=_("ایجاد"))

    class Meta:
        ordering = ["-created_at"]
        verbose_name = _("تیکت")
        verbose_name_plural = _("تیکت‌ها")

    def __str__(self): return self.subject
PY

  cat > app/tickets/admin.py <<'PY'
from django.contrib import admin
from .models import Ticket

@admin.register(Ticket)
class TicketAdmin(admin.ModelAdmin):
    list_display = ("id","user","subject","created_at")
    search_fields = ("user__username","subject","description")
PY

  cat > app/tickets/views.py <<'PY'
from django.contrib.auth.decorators import login_required
from django.shortcuts import render, redirect
from django.contrib import messages
from .models import Ticket
from django import forms

class TicketCreateForm(forms.ModelForm):
    class Meta:
        model = Ticket
        fields = ("subject","description")
        labels = {"subject": "موضوع", "description": "توضیحات"}

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
  <div class="max-w-6xl mx-auto px-4 py-4 flex items-center justify-between gap-4">
    <a href="/" class="flex items-center gap-3">
      <span class="font-extrabold text-xl tracking-tight">{{ site_settings.brand_name|default:"EduCMS" }}</span>
    </a>
    <div class="flex items-center gap-2 text-sm">
      {% if user.is_authenticated %}
        <a class="px-3 py-1 rounded-xl hover:underline" href="/panel/">پنل کاربری</a>
        <a class="px-3 py-1 rounded-xl hover:underline" href="/orders/my/">سفارش‌ها</a>
        <a class="px-3 py-1 rounded-xl hover:underline" href="/tickets/">تیکت‌ها</a>
        <form method="post" action="/accounts/logout/" class="inline">
          {% csrf_token %}
          <button type="submit" class="px-3 py-1 rounded-xl border">خروج</button>
        </form>
        {% if user.is_staff %}
          <a class="px-3 py-1 rounded-xl border" href="/{{ site_settings.admin_path|default:'admin' }}/">ادمین</a>
        {% endif %}
      {% else %}
        <a class="px-3 py-1 rounded-xl border" href="/accounts/login/">ورود</a>
        <a class="px-3 py-1 rounded-xl border" href="/accounts/register/">ثبت‌نام</a>
      {% endif %}
    </div>
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
  <div class="max-w-6xl mx-auto px-4 py-8 text-sm text-slate-500">
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
    <h1 class="text-2xl font-extrabold">{{ tpl.home_title|default:"دوره‌های آموزشی" }}</h1>
    <div class="text-sm text-slate-500">{{ tpl.home_subtitle|default:"جدیدترین دوره‌ها" }}</div>
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
      <div class="text-slate-600">{{ tpl.home_empty|default:"هنوز دوره‌ای منتشر نشده است." }}</div>
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
    <div class="text-slate-600 mb-2">{{ object.summary }}</div>
    <div class="text-sm text-slate-500 mb-4">دسته‌بندی: {{ object.category.title|default:"بدون دسته" }}</div>
    <div class="prose max-w-none mt-4">{{ object.description|linebreaks }}</div>
  </div>
{% endblock %}
HTML

  cat > app/templates/accounts/login.html <<'HTML'
{% extends "base.html" %}
{% block title %}ورود{% endblock %}
{% block content %}
<div class="max-w-md mx-auto bg-white rounded-2xl border p-6">
  <h1 class="text-xl font-bold mb-4">ورود</h1>
  <form method="post">{% csrf_token %}
    {{ form.as_p }}
    <button class="mt-3 w-full px-4 py-2 rounded-xl bg-slate-900 text-white">ورود</button>
  </form>
  <div class="mt-4 text-sm">
    <a class="underline" href="/accounts/forgot/">فراموشی رمز عبور</a>
  </div>
</div>
{% endblock %}
HTML

  cat > app/templates/accounts/register.html <<'HTML'
{% extends "base.html" %}
{% block title %}ثبت‌نام{% endblock %}
{% block content %}
<div class="max-w-md mx-auto bg-white rounded-2xl border p-6">
  <h1 class="text-xl font-bold mb-4">ثبت‌نام</h1>
  <form method="post">{% csrf_token %}
    {{ form.as_p }}
    <button class="mt-3 w-full px-4 py-2 rounded-xl bg-slate-900 text-white">ساخت حساب</button>
  </form>
</div>
{% endblock %}
HTML

  cat > app/templates/accounts/forgot_username.html <<'HTML'
{% extends "base.html" %}
{% block title %}فراموشی رمز{% endblock %}
{% block content %}
<div class="max-w-md mx-auto bg-white rounded-2xl border p-6">
  <h1 class="text-xl font-bold mb-4">فراموشی رمز عبور</h1>
  <form method="post">{% csrf_token %}
    {{ form.as_p }}
    <button class="mt-3 w-full px-4 py-2 rounded-xl bg-slate-900 text-white">ادامه</button>
  </form>
</div>
{% endblock %}
HTML

  cat > app/templates/accounts/forgot_question.html <<'HTML'
{% extends "base.html" %}
{% block title %}فراموشی رمز{% endblock %}
{% block content %}
<div class="max-w-md mx-auto bg-white rounded-2xl border p-6">
  <h1 class="text-xl font-bold mb-2">سوال امنیتی</h1>
  <div class="text-sm text-slate-600 mb-4">{{ question }}</div>
  <form method="post">{% csrf_token %}
    {{ form.as_p }}
    <button class="mt-3 w-full px-4 py-2 rounded-xl bg-slate-900 text-white">ادامه</button>
  </form>
</div>
{% endblock %}
HTML

  cat > app/templates/accounts/forgot_reset.html <<'HTML'
{% extends "base.html" %}
{% block title %}تغییر رمز{% endblock %}
{% block content %}
<div class="max-w-md mx-auto bg-white rounded-2xl border p-6">
  <h1 class="text-xl font-bold mb-4">تعیین رمز جدید</h1>
  <form method="post">{% csrf_token %}
    {{ form.as_p }}
    <button class="mt-3 w-full px-4 py-2 rounded-xl bg-slate-900 text-white">ذخیره</button>
  </form>
</div>
{% endblock %}
HTML

  cat > app/templates/orders/my_orders.html <<'HTML'
{% extends "base.html" %}
{% block title %}سفارش‌های من{% endblock %}
{% block content %}
<div class="max-w-4xl mx-auto bg-white rounded-2xl border p-6">
  <h1 class="text-xl font-bold mb-4">سفارش‌های من</h1>
  <div class="space-y-3">
    {% for o in orders %}
      <div class="p-4 rounded-xl border">
        <div class="text-sm">دوره: <b>{{ o.course.title }}</b></div>
        <div class="text-sm">مبلغ: {{ o.amount }} تومان</div>
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
    <h1 class="text-xl font-bold">تیکت‌های من</h1>
    <a class="px-4 py-2 rounded-xl bg-slate-900 text-white" href="/tickets/new/">ثبت تیکت</a>
  </div>
  <div class="space-y-3">
    {% for t in tickets %}
      <div class="p-4 rounded-xl border">
        <div class="font-semibold">{{ t.subject }}</div>
        <div class="text-sm text-slate-500">{{ t.created_at }}</div>
        <div class="mt-2 text-sm text-slate-700 whitespace-pre-line">{{ t.description }}</div>
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
  <h1 class="text-xl font-bold mb-4">ثبت تیکت</h1>
  <form method="post">{% csrf_token %}
    {{ form.as_p }}
    <button class="mt-3 w-full px-4 py-2 rounded-xl bg-slate-900 text-white">ثبت</button>
  </form>
</div>
{% endblock %}
HTML

  cat > app/templates/settings/dashboard.html <<'HTML'
{% extends "base.html" %}
{% block title %}پنل کاربری{% endblock %}
{% block content %}
<div class="max-w-5xl mx-auto space-y-6">
  <div class="bg-white rounded-2xl border p-6">
    <h1 class="text-xl font-bold mb-2">پنل کاربری</h1>
    <div class="flex flex-wrap gap-2 text-sm">
      <a class="px-4 py-2 rounded-xl border" href="/panel/profile/">پروفایل</a>
      <a class="px-4 py-2 rounded-xl border" href="/panel/password/">تغییر رمز</a>
      <a class="px-4 py-2 rounded-xl border" href="/orders/my/">سفارش‌ها</a>
      <a class="px-4 py-2 rounded-xl border" href="/tickets/">تیکت‌ها</a>
    </div>
  </div>

  <div class="grid md:grid-cols-2 gap-4">
    <div class="bg-white rounded-2xl border p-6">
      <div class="font-bold mb-3">آخرین سفارش‌ها</div>
      <div class="space-y-2">
        {% for o in orders %}
          <div class="p-3 rounded-xl border text-sm">
            <div><b>{{ o.course.title }}</b></div>
            <div class="text-slate-500">{{ o.get_status_display }} — {{ o.created_at }}</div>
          </div>
        {% empty %}
          <div class="text-slate-600 text-sm">سفارشی ندارید.</div>
        {% endfor %}
      </div>
    </div>

    <div class="bg-white rounded-2xl border p-6">
      <div class="font-bold mb-3">آخرین تیکت‌ها</div>
      <div class="space-y-2">
        {% for t in tickets %}
          <div class="p-3 rounded-xl border text-sm">
            <div><b>{{ t.subject }}</b></div>
            <div class="text-slate-500">{{ t.created_at }}</div>
          </div>
        {% empty %}
          <div class="text-slate-600 text-sm">تیکتی ندارید.</div>
        {% endfor %}
      </div>
    </div>
  </div>
</div>
{% endblock %}
HTML

  cat > app/templates/settings/profile.html <<'HTML'
{% extends "base.html" %}
{% block title %}پروفایل{% endblock %}
{% block content %}
<div class="max-w-xl mx-auto bg-white rounded-2xl border p-6">
  <h1 class="text-xl font-bold mb-4">ویرایش پروفایل</h1>
  <form method="post">{% csrf_token %}
    {{ form.as_p }}
    <button class="mt-3 w-full px-4 py-2 rounded-xl bg-slate-900 text-white">ذخیره</button>
  </form>
</div>
{% endblock %}
HTML

  cat > app/templates/settings/change_password.html <<'HTML'
{% extends "base.html" %}
{% block title %}تغییر رمز{% endblock %}
{% block content %}
<div class="max-w-xl mx-auto bg-white rounded-2xl border p-6">
  <h1 class="text-xl font-bold mb-4">تغییر رمز عبور</h1>
  <form method="post">{% csrf_token %}
    {{ form.as_p }}
    <button class="mt-3 w-full px-4 py-2 rounded-xl bg-slate-900 text-white">ذخیره</button>
  </form>
</div>
{% endblock %}
HTML

  cat > app/templates/admin/admin_account.html <<'HTML'
{% extends "admin/base_site.html" %}
{% block content %}
<div style="max-width:720px">
  <h1>تغییر نام کاربری و رمز عبور ادمین</h1>
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
python manage.py migrate --noinput

python manage.py shell <<'PY'
import os
from django.contrib.auth import get_user_model
from settingsapp.models import SiteSetting, TemplateText

User = get_user_model()
admin_u = os.getenv("ADMIN_USERNAME")
admin_p = os.getenv("ADMIN_PASSWORD")
admin_e = os.getenv("ADMIN_EMAIL")
initial_admin_path = os.getenv("INITIAL_ADMIN_PATH","admin") or "admin"

u, _ = User.objects.get_or_create(username=admin_u, defaults={"email": admin_e})
u.is_staff = True
u.is_superuser = True
u.email = admin_e
u.set_password(admin_p)
u.save()

s, _ = SiteSetting.objects.get_or_create(id=1, defaults={"brand_name":"EduCMS","footer_text":"© تمامی حقوق محفوظ است.","admin_path":initial_admin_path,"allow_profile_edit":True})
if not s.admin_path:
    s.admin_path = initial_admin_path
    s.save(update_fields=["admin_path"])

defaults = [
  ("home_title","عنوان صفحه اصلی","دوره‌های آموزشی"),
  ("home_subtitle","زیرعنوان صفحه اصلی","جدیدترین دوره‌ها"),
  ("home_empty","متن نبود دوره","هنوز دوره‌ای منتشر نشده است."),
]
for key,title,val in defaults:
    TemplateText.objects.get_or_create(key=key, defaults={"title":title,"value":val})

print("Admin ready:", u.username)
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
  echo "Panel:   https://${DOMAIN}/panel/"
  echo "Tickets: https://${DOMAIN}/tickets/"
  echo "Orders:  https://${DOMAIN}/orders/my/"
  echo "Admin Account (inside admin): /admin/account/"
}

do_stop(){
  compose_cd_or_fail
  docker compose stop || true
  ok "Stopped."
}

do_start(){
  compose_cd_or_fail
  docker compose up -d || true
  ok "Started."
}

do_restart(){
  compose_cd_or_fail
  docker compose up -d --build
  ok "Restarted."
}

do_update(){
  require_root; require_tty
  compose_cd_or_fail
  load_env_or_fail
  step "Updating project files (keeping .env, volumes, and data)..."
  mkdir -p "${APP_DIR}/app" "${APP_DIR}/nginx" "${APP_DIR}/certbot/www" "${APP_DIR}/certbot/conf" "${BACKUP_DIR}"
  write_project
  step "Rebuilding & starting web/nginx..."
  docker compose up -d --build web nginx
  ok "Updated."
}

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
  echo -e "${GREEN}6)${RESET} Uninstall (حذف کامل)"
  echo -e "${GREEN}7)${RESET} Restore DB (.sql)"
  echo -e "${GREEN}8)${RESET} Update (آپدیت برای نصب‌های قبلی)"
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
      6) do_uninstall ;;
      7)
        p="$(read_line "Path to .sql file (e.g. /opt/educms/backups/file.sql): ")"
        restore_db "$p"
        ;;
      8) do_update ;;
      0) echo -e "${CYAN}Bye.${RESET}"; exit 0 ;;
      *) warn "Invalid option." ;;
    esac
    read -r -p "Press Enter..." _ </dev/tty || true
  done
}

main
