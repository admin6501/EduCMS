from django.contrib.auth.views import LoginView, LogoutView
from django.views.generic import CreateView
from django.urls import reverse_lazy
from django.contrib import messages
from django.shortcuts import redirect, render
from django.contrib.auth.decorators import login_required
from django.contrib.auth import get_user_model
from .forms import RegisterForm, LoginForm, ProfileForm, SecurityQuestionsForm, ResetStep1Form, ResetStep2Form
from .models import UserProfile

User = get_user_model()

class SiteLoginView(LoginView):
  template_name="accounts/login.html"
  authentication_form=LoginForm

class SiteLogoutView(LogoutView):
  http_method_names=["post"]
  next_page="/"

class RegisterView(CreateView):
  form_class=RegisterForm
  template_name="accounts/register.html"
  success_url=reverse_lazy("dashboard")

  def form_valid(self, form):
    from django.contrib.auth import login
    response = super().form_valid(form)
    # Auto login after registration - specify backend
    login(self.request, self.object, backend='accounts.backends.EmailOrUsernameBackend')
    messages.success(self.request, "حساب کاربری شما با موفقیت ایجاد شد. خوش آمدید!")
    return response

@login_required
def profile_edit(request):
  # Check if profile editing is allowed
  allow_edit = True
  try:
    from settingsapp.models import SiteSetting
    site_setting = SiteSetting.objects.first()
    if site_setting:
      allow_edit = getattr(site_setting, 'allow_profile_edit', True)
  except Exception:
    pass

  profile, _ = UserProfile.objects.select_related("q1").get_or_create(user=request.user)

  if not allow_edit:
    return render(request, "accounts/profile.html", {"form": None, "profile": profile, "allow_edit": False})

  form = ProfileForm(request.POST or None, profile=profile)

  if request.method == "POST" and form.is_valid():
    # Save custom field data
    try:
      custom_data = form.get_custom_field_data()
      if custom_data:
        extra = getattr(profile, 'extra_data', None) or {}
        extra.update(custom_data)
        profile.extra_data = extra
        profile.save(update_fields=["extra_data"])
        messages.success(request, "پروفایل بروزرسانی شد.")
    except Exception:
      pass
    return redirect("profile_edit")

  return render(request, "accounts/profile.html", {"form": form, "profile": profile, "allow_edit": True})

@login_required
def security_questions(request):
  # Check if security questions editing is allowed
  allow_edit = True
  try:
    from settingsapp.models import SiteSetting
    site_setting = SiteSetting.objects.first()
    if site_setting:
      allow_edit = getattr(site_setting, 'allow_security_edit', True)
  except Exception:
    pass

  if not allow_edit:
    messages.error(request, "تغییر سوال امنیتی توسط مدیر غیرفعال شده است.")
    return render(request, "accounts/security_questions.html", {"form": None, "allow_edit": False})

  profile,_ = UserProfile.objects.get_or_create(user=request.user)
  init={}
  if profile.q1: init["q1"]=profile.q1
  form = SecurityQuestionsForm(request.POST or None, user=request.user, initial=init)
  if request.method=="POST" and form.is_valid():
    profile.q1=form.cleaned_data["q1"]
    profile.set_answer(form.cleaned_data["a1"])
    profile.save(update_fields=["q1","a1_hash"])
    messages.success(request,"سوال امنیتی بروزرسانی شد.")
    return redirect("security_questions")
  return render(request,"accounts/security_questions.html",{"form":form, "allow_edit": True})

def reset_step1(request):
  form=ResetStep1Form(request.POST or None)
  if request.method=="POST" and form.is_valid():
    ident=(form.cleaned_data["identifier"] or "").strip()
    user = User.objects.filter(username__iexact=ident).first() or User.objects.filter(email__iexact=ident).first()
    if not user:
      messages.error(request,"کاربر پیدا نشد.")
      return redirect("reset_step1")
    profile = UserProfile.objects.filter(user=user).select_related("q1").first()
    if not profile or not (profile.q1 and profile.a1_hash):
      messages.error(request,"برای این کاربر سوال امنیتی تنظیم نشده است.")
      return redirect("reset_step1")
    request.session["reset_user_id"]=str(user.id)
    return redirect("reset_step2")
  return render(request,"accounts/reset_step1.html",{"form":form})

def reset_step2(request):
  uid=request.session.get("reset_user_id")
  if not uid: return redirect("reset_step1")
  user=User.objects.filter(id=uid).first()
  if not user:
    request.session.pop("reset_user_id",None); return redirect("reset_step1")
  profile=UserProfile.objects.filter(user=user).select_related("q1").first()
  if not profile or not profile.q1:
    request.session.pop("reset_user_id",None); return redirect("reset_step1")
  form=ResetStep2Form(request.POST or None)
  if request.method=="POST" and form.is_valid():
    if not profile.check_answer(form.cleaned_data["a1"]):
      messages.error(request,"پاسخ صحیح نیست.")
      return redirect("reset_step2")
    user.set_password(form.cleaned_data["new_password1"]); user.save(update_fields=["password"])
    request.session.pop("reset_user_id",None)
    messages.success(request,"رمز تغییر کرد. وارد شوید.")
    return redirect("login")
  return render(request,"accounts/reset_step2.html",{"form":form,"q1":profile.q1.text,"username":user.username})
