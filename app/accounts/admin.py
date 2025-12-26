from django.contrib import admin
from django.contrib.auth.admin import UserAdmin as BaseUserAdmin
from .models import User, UserProfile, SecurityQuestion

class UserProfileInline(admin.StackedInline):
    model = UserProfile
    extra = 0
    can_delete = False

@admin.register(User)
class UserAdmin(BaseUserAdmin):
    list_display = ("email","is_staff","is_superuser","is_active","date_joined")
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

@admin.register(SecurityQuestion)
class SecurityQuestionAdmin(admin.ModelAdmin):
    list_display = ("id","text","is_active")
    list_filter = ("is_active",)
    search_fields = ("text",)

@admin.register(UserProfile)
class UserProfileAdmin(admin.ModelAdmin):
    list_display = ("user", "phone", "security_question", "has_answer", "updated_at")
    list_select_related = ("user", "q1")
    search_fields = ("user__email", "user__username", "phone")
    readonly_fields = ("security_info_display", "extra_data_display")
    
    fieldsets = (
        ("اطلاعات کاربر", {"fields": ("user", "phone", "bio")}),
        ("سوال امنیتی", {"fields": ("q1", "security_info_display")}),
        ("داده‌های اضافی", {"fields": ("extra_data_display",)}),
    )

    def security_question(self, obj):
        return obj.q1.text if obj.q1 else "-"
    security_question.short_description = "سوال امنیتی"

    def has_answer(self, obj):
        return bool(obj.a1_hash)
    has_answer.boolean = True
    has_answer.short_description = "پاسخ تنظیم شده"

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

