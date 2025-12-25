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