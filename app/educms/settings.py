from pathlib import Path
import os

BASE_DIR = Path(__file__).resolve().parent.parent
SECRET_KEY = os.getenv("DJANGO_SECRET_KEY","dev-secret")
DEBUG = os.getenv("DJANGO_DEBUG","False").lower()=="true"
ALLOWED_HOSTS = [h.strip() for h in os.getenv("DJANGO_ALLOWED_HOSTS","localhost").split(",") if h.strip()]

INSTALLED_APPS = [
  "django.contrib.admin","django.contrib.auth","django.contrib.contenttypes","django.contrib.sessions",
  "django.contrib.messages","django.contrib.staticfiles",
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
