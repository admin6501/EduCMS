from django import forms
from django.contrib.auth import get_user_model
from django.contrib.auth.forms import AuthenticationForm, UserCreationForm
from django.contrib.auth.hashers import make_password
from django.utils.translation import gettext_lazy as _

from .models import UserProfile, SecurityQuestion

User = get_user_model()

_INPUT = "w-full rounded-xl border border-slate-200 bg-white px-3 py-2 outline-none focus:ring-2 focus:ring-slate-300 dark:bg-slate-900 dark:border-slate-700 dark:focus:ring-slate-700"

def get_registration_fields():
    """Get active registration fields from database"""
    try:
        from settingsapp.models import RegistrationField
        return list(RegistrationField.objects.filter(is_active=True).order_by("order", "id"))
    except Exception:
        return []

def build_form_field(reg_field):
    """Build a Django form field from a RegistrationField model instance"""
    attrs = {"class": _INPUT}
    if reg_field.placeholder:
        attrs["placeholder"] = reg_field.placeholder
    if reg_field.field_type in ("email", "phone", "password", "text"):
        attrs["dir"] = "ltr"

    field_kwargs = {
        "label": reg_field.label,
        "required": reg_field.is_required,
        "help_text": reg_field.help_text or "",
    }

    if reg_field.field_type == "text":
        return forms.CharField(widget=forms.TextInput(attrs=attrs), **field_kwargs)
    elif reg_field.field_type == "email":
        attrs["autocomplete"] = "email"
        return forms.EmailField(widget=forms.EmailInput(attrs=attrs), **field_kwargs)
    elif reg_field.field_type == "phone":
        attrs["autocomplete"] = "tel"
        return forms.CharField(widget=forms.TextInput(attrs=attrs), **field_kwargs)
    elif reg_field.field_type == "textarea":
        attrs["rows"] = 3
        return forms.CharField(widget=forms.Textarea(attrs=attrs), **field_kwargs)
    elif reg_field.field_type == "select":
        choices = [("", _("انتخاب کنید"))] + [(c, c) for c in reg_field.get_choices_list()]
        return forms.ChoiceField(choices=choices, widget=forms.Select(attrs=attrs), **field_kwargs)
    elif reg_field.field_type == "checkbox":
        return forms.BooleanField(widget=forms.CheckboxInput(attrs={"class": "rounded"}), **field_kwargs)
    elif reg_field.field_type == "password":
        attrs["autocomplete"] = "new-password"
        return forms.CharField(widget=forms.PasswordInput(attrs=attrs), **field_kwargs)
    else:
        return forms.CharField(widget=forms.TextInput(attrs=attrs), **field_kwargs)

class LoginForm(AuthenticationForm):
    username = forms.CharField(
        label=_("ایمیل"),
        widget=forms.TextInput(attrs={"class": _INPUT, "autocomplete":"email", "dir":"ltr"})
    )
    password = forms.CharField(
        label=_("گذرواژه"),
        widget=forms.PasswordInput(attrs={"class": _INPUT, "autocomplete":"current-password", "dir":"ltr"})
    )

class RegisterForm(UserCreationForm):
    email = forms.EmailField(
        label=_("ایمیل"),
        widget=forms.EmailInput(attrs={"class": _INPUT, "autocomplete":"email", "dir":"ltr"})
    )

    security_question = forms.ModelChoiceField(
        queryset=SecurityQuestion.objects.none(),
        required=True,
        empty_label=_("انتخاب کنید"),
        label=_("سوال امنیتی"),
        widget=forms.Select(attrs={"class": _INPUT})
    )
    security_answer = forms.CharField(
        required=True,
        label=_("پاسخ سوال امنیتی"),
        widget=forms.PasswordInput(attrs={"class": _INPUT, "autocomplete":"off"})
    )

    password1 = forms.CharField(
        label=_("گذرواژه"),
        widget=forms.PasswordInput(attrs={"class": _INPUT, "autocomplete":"new-password", "dir":"ltr"})
    )
    password2 = forms.CharField(
        label=_("تکرار گذرواژه"),
        widget=forms.PasswordInput(attrs={"class": _INPUT, "autocomplete":"new-password", "dir":"ltr"})
    )

    class Meta:
        model = User
        fields = ("email",)

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._dynamic_fields = []

        # Set the queryset dynamically to avoid issues when table doesn't exist
        try:
            self.fields['security_question'].queryset = SecurityQuestion.objects.filter(is_active=True).order_by("order", "text")
        except Exception:
            pass

        # Add dynamic fields from RegistrationField model
        try:
            for reg_field in get_registration_fields():
                # Skip system fields that are already defined
                if reg_field.field_key in ("email", "password1", "password2", "security_question", "security_answer"):
                    continue
                field = build_form_field(reg_field)
                self.fields[f"custom_{reg_field.field_key}"] = field
                self._dynamic_fields.append(reg_field.field_key)
        except Exception:
            pass  # Database might not be ready during migrations

        # Reorder fields
        ordered = ["email", "security_question", "security_answer", "password1", "password2"]
        for key in self._dynamic_fields:
            ordered.append(f"custom_{key}")
        self.order_fields(ordered)

    def clean_email(self):
        e = (self.cleaned_data.get("email") or "").strip().lower()
        if not e:
            raise forms.ValidationError(_("ایمیل الزامی است."))
        if User.objects.filter(email__iexact=e).exists():
            raise forms.ValidationError(_("این ایمیل قبلاً ثبت شده است."))
        return e

    def clean_security_answer(self):
        a = (self.cleaned_data.get("security_answer") or "").strip()
        if len(a) < 2:
            raise forms.ValidationError(_("پاسخ کوتاه است."))
        return a

    def get_custom_field_data(self):
        """Return a dict of custom field values"""
        data = {}
        for key in self._dynamic_fields:
            field_name = f"custom_{key}"
            if field_name in self.cleaned_data:
                data[key] = self.cleaned_data[field_name]
        return data

    def save(self, commit=True):
        user = super().save(commit=False)
        user.email = (self.cleaned_data.get("email") or "").strip().lower()
        if commit:
            user.save()
            prof, _ = UserProfile.objects.get_or_create(user=user)
            prof.q1 = self.cleaned_data.get("security_question")
            ans = (self.cleaned_data.get("security_answer") or "").strip().lower()
            prof.a1_hash = make_password(ans)

            # Save custom fields to profile extra_data (safely)
            try:
                custom_data = self.get_custom_field_data()
                if custom_data and hasattr(prof, 'extra_data'):
                    prof.extra_data = custom_data
            except Exception:
                pass
            prof.save()
        return user

class ProfileForm(forms.ModelForm):
    class Meta:
        model = User
        fields = ("first_name", "last_name", "email")
        widgets = {
            "first_name": forms.TextInput(attrs={"class": _INPUT}),
            "last_name": forms.TextInput(attrs={"class": _INPUT}),
            "email": forms.EmailInput(attrs={"class": _INPUT, "dir": "ltr"}),
        }

    def __init__(self, *args, profile=None, **kwargs):
        super().__init__(*args, **kwargs)
        self.profile = profile
        self._dynamic_fields = []

        # Add dynamic fields that should show in profile
        try:
            for reg_field in get_registration_fields():
                if not reg_field.show_in_profile:
                    continue
                if reg_field.field_key in ("email", "password1", "password2", "security_question", "security_answer"):
                    continue
                field = build_form_field(reg_field)
                field_name = f"custom_{reg_field.field_key}"
                self.fields[field_name] = field
                self._dynamic_fields.append(reg_field.field_key)

                # Set initial value from profile extra_data (safely)
                if profile:
                    extra_data = getattr(profile, 'extra_data', None) or {}
                    if reg_field.field_key in extra_data:
                        self.initial[field_name] = extra_data[reg_field.field_key]
        except Exception:
            pass

    def get_custom_field_data(self):
        """Return a dict of custom field values"""
        data = {}
        for key in self._dynamic_fields:
            field_name = f"custom_{key}"
            if field_name in self.cleaned_data:
                data[key] = self.cleaned_data[field_name]
        return data

class SecurityQuestionsForm(forms.Form):
    q1 = forms.ModelChoiceField(
        queryset=SecurityQuestion.objects.none(),
        required=True,
        label=_("سوال امنیتی"),
        widget=forms.Select(attrs={"class": _INPUT})
    )
    a1 = forms.CharField(
        required=True,
        label=_("پاسخ سوال امنیتی"),
        widget=forms.PasswordInput(attrs={"class": _INPUT, "autocomplete": "off"})
    )

    def __init__(self, *args, user=None, **kwargs):
        super().__init__(*args, **kwargs)
        self.user = user
        # Set queryset dynamically
        try:
            qs = SecurityQuestion.objects.filter(is_active=True).order_by("order", "text")
            self.fields['q1'].queryset = qs
        except Exception:
            pass

    def clean(self):
        return super().clean()

class ResetStep1Form(forms.Form):
    identifier = forms.CharField(
        label=_("ایمیل یا نام کاربری"),
        widget=forms.TextInput(attrs={"class": _INPUT, "dir": "ltr", "autocomplete": "username"})
    )

class ResetStep2Form(forms.Form):
    a1 = forms.CharField(
        label=_("پاسخ سوال امنیتی"),
        widget=forms.PasswordInput(attrs={"class": _INPUT, "autocomplete": "off"})
    )
    new_password1 = forms.CharField(
        label=_("رمز جدید"),
        widget=forms.PasswordInput(attrs={"class": _INPUT, "autocomplete": "new-password", "dir": "ltr"})
    )
    new_password2 = forms.CharField(
        label=_("تکرار رمز جدید"),
        widget=forms.PasswordInput(attrs={"class": _INPUT, "autocomplete": "new-password", "dir": "ltr"})
    )

    def clean(self):
        c = super().clean()
        p1 = c.get("new_password1")
        p2 = c.get("new_password2")
        if p1 and p2 and p1 != p2:
            raise forms.ValidationError(_("رمزها یکسان نیستند."))
        return c
