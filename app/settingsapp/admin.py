from django.contrib import admin

admin.site.site_header="پنل مدیریت"
admin.site.site_title="پنل مدیریت"
admin.site.index_title="مدیریت سایت"

from .models import SiteSetting, TemplateText, NavLink

# Very simple admin for SiteSetting
@admin.register(SiteSetting)
class SiteSettingAdmin(admin.ModelAdmin):
    pass

admin.site.register(TemplateText)
admin.site.register(NavLink)

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