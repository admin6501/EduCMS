from django import forms
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
    fields=("amount","receipt_image","tracking_code","note")
    widgets={"amount": forms.NumberInput(attrs={"class":_INPUT,"dir":"ltr"}),
             "tracking_code": forms.TextInput(attrs={"class":_INPUT,"dir":"ltr"}),
             "note": forms.Textarea(attrs={"class":_INPUT,"rows":3})}