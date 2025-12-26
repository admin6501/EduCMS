from django.contrib.admin.views.decorators import staff_member_required
from django.contrib import messages
from django.shortcuts import render, redirect
from django.core.cache import cache
from .forms import AdminPathForm
from .models import SiteSetting

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
