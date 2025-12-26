from django.http import HttpResponseNotFound
from django.utils.deprecation import MiddlewareMixin
from django.core.cache import cache
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

class AdminAliasMiddleware(MiddlewareMixin):
  def process_request(self, request):
    admin_path=(_get_admin_path() or "admin").strip().strip("/") or "admin"
    ap=admin_path.lower()
    p=(request.path or "/"); pl=p.lower()
    if ap!="admin" and pl.startswith("/admin"):
      return HttpResponseNotFound("Not Found")
    if pl==f"/{ap}":
      request.path_info="/admin/"; return None
    pref=f"/{ap}/"
    if pl.startswith(pref):
      request.path_info="/admin/"+p[len(pref):]
    return None
