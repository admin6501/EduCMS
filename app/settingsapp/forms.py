from django import forms
import re
_INPUT="w-full rounded-xl border border-slate-200 bg-white px-3 py-2 outline-none focus:ring-2 focus:ring-slate-300 dark:bg-slate-900 dark:border-slate-700 dark:focus:ring-slate-700"
class AdminPathForm(forms.Form):
  admin_path=forms.CharField(max_length=50, widget=forms.TextInput(attrs={"class":_INPUT,"dir":"ltr"}))
  def clean_admin_path(self):
    v=(self.cleaned_data.get("admin_path") or "").strip().strip("/") or "admin"
    if not re.fullmatch(r"[-A-Za-z0-9_]+", v):
      raise forms.ValidationError("مسیر نامعتبر است. فقط A-Z a-z 0-9 _ -")
    return v
class AdminAccountForm(forms.Form):
  username=forms.CharField(max_length=150, widget=forms.TextInput(attrs={"class":_INPUT}))
  password1=forms.CharField(widget=forms.PasswordInput(attrs={"class":_INPUT}))
  password2=forms.CharField(widget=forms.PasswordInput(attrs={"class":_INPUT}))
  def clean(self):
    c=super().clean()
    if c.get("password1")!=c.get("password2"):
      raise forms.ValidationError("رمزها یکسان نیستند.")
    return c
