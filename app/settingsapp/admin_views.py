from django.contrib.admin.views.decorators import staff_member_required
from django.contrib.auth import update_session_auth_hash
from django.contrib import messages
from django.shortcuts import render, redirect
from .forms import AdminAccountForm

@staff_member_required
def admin_account_in_admin(request):
  form = AdminAccountForm(request.POST or None, initial={"username": request.user.username})
  if request.method=="POST" and form.is_valid():
    u=request.user
    u.username=form.cleaned_data["username"]
    u.set_password(form.cleaned_data["password1"])
    u.save()
    update_session_auth_hash(request,u)
    messages.success(request,"نام کاربری/رمز ادمین تغییر کرد.")
    return redirect("/admin/")
  return render(request,"settings/admin_account.html",{"form":form})
