from django import forms
from django.utils.translation import gettext_lazy as _
from .models import Order, WalletTopUpRequest
_INPUT="w-full rounded-xl border border-slate-200 bg-white px-3 py-2 outline-none focus:ring-2 focus:ring-slate-300 dark:bg-slate-900 dark:border-slate-700 dark:focus:ring-slate-700"

class ReceiptUploadForm(forms.ModelForm):
  class Meta:
    model=Order
    fields=("receipt_image","tracking_code","note")
    widgets={"tracking_code": forms.TextInput(attrs={"class":_INPUT,"dir":"ltr"}),
             "note": forms.Textarea(attrs={"class":_INPUT,"rows":3})}

class CouponApplyForm(forms.Form):
  coupon_code=forms.CharField(required=False, max_length=40, widget=forms.TextInput(attrs={"class":_INPUT,"dir":"ltr"}))

class WalletTopUpForm(forms.ModelForm):
  class Meta:
    model=WalletTopUpRequest
    fields=("amount","note","receipt_image","tracking_code")
    labels={
      "amount": _("مبلغ شارژ (تومان)"),
      "note": _("توضیحات (اختیاری)"),
      "receipt_image": _("تصویر رسید (اختیاری)"),
      "tracking_code": _("کد پیگیری (اختیاری)"),
    }
    help_texts={
      "amount": _("مبلغ مورد نظر برای شارژ کیف پول را به تومان وارد کنید."),
      "note": _("در صورت نیاز توضیحات خود را بنویسید."),
      "receipt_image": _("اگر کارت به کارت کرده‌اید، تصویر رسید را آپلود کنید."),
      "tracking_code": _("کد پیگیری یا شماره مرجع تراکنش بانکی"),
    }
    widgets={
      "amount": forms.NumberInput(attrs={"class":_INPUT,"dir":"ltr","placeholder":"مثال: 50000"}),
      "tracking_code": forms.TextInput(attrs={"class":_INPUT,"dir":"ltr","placeholder":"کد پیگیری بانکی"}),
      "note": forms.Textarea(attrs={"class":_INPUT,"rows":3,"placeholder":"توضیحات اضافی..."})
    }
