import uuid
from django.db import models, transaction
from django.conf import settings
from django.utils import timezone
from django.db.models import F
from django.utils.translation import gettext_lazy as _
from courses.models import Course

class BankTransferSetting(models.Model):
  account_holder=models.CharField(max_length=120, blank=True)
  card_number=models.CharField(max_length=30, blank=True)
  note=models.TextField(blank=True)
  first_purchase_percent=models.PositiveIntegerField(default=0)
  first_purchase_amount=models.PositiveIntegerField(default=0)
  updated_at=models.DateTimeField(auto_now=True)
  class Meta:
    verbose_name=_("تنظیمات کارت‌به‌کارت"); verbose_name_plural=_("تنظیمات کارت‌به‌کارت")

class CouponType(models.TextChoices):
  PERCENT="percent",_("درصدی")
  AMOUNT="amount",_("مبلغی")

class Coupon(models.Model):
  code=models.CharField(max_length=40, unique=True)
  type=models.CharField(max_length=10, choices=CouponType.choices, default=CouponType.PERCENT)
  value=models.PositiveIntegerField()
  is_active=models.BooleanField(default=True)
  start_at=models.DateTimeField(blank=True, null=True)
  end_at=models.DateTimeField(blank=True, null=True)
  max_uses=models.PositiveIntegerField(default=0)
  max_uses_per_user=models.PositiveIntegerField(default=0)
  min_amount=models.PositiveIntegerField(default=0)
  def is_valid_now(self):
    now=timezone.now()
    if not self.is_active: return False
    if self.start_at and now<self.start_at: return False
    if self.end_at and now>self.end_at: return False
    return True
  class Meta:
    verbose_name=_("کد تخفیف"); verbose_name_plural=_("کدهای تخفیف")

class OrderStatus(models.TextChoices):
  PENDING_PAYMENT="pending_payment",_("در انتظار پرداخت")
  PENDING_VERIFY="pending_verify",_("در انتظار تایید")
  PAID="paid",_("پرداخت شده")
  REJECTED="rejected",_("رد شده")
  CANCELED="canceled",_("لغو شده")

class Order(models.Model):
  id=models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
  user=models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE)
  course=models.ForeignKey(Course, on_delete=models.PROTECT)
  amount=models.PositiveIntegerField()
  discount_amount=models.PositiveIntegerField(default=0)
  final_amount=models.PositiveIntegerField(default=0)
  coupon=models.ForeignKey(Coupon, on_delete=models.SET_NULL, null=True, blank=True)
  status=models.CharField(max_length=30, choices=OrderStatus.choices, default=OrderStatus.PENDING_PAYMENT)
  receipt_image=models.ImageField(upload_to="receipts/", blank=True, null=True)
  tracking_code=models.CharField(max_length=80, blank=True)
  note=models.TextField(blank=True)
  created_at=models.DateTimeField(auto_now_add=True)
  verified_at=models.DateTimeField(blank=True, null=True)
  class Meta:
    ordering=["-created_at"]; verbose_name=_("سفارش"); verbose_name_plural=_("سفارش‌ها")

class Wallet(models.Model):
  user=models.OneToOneField(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="wallet")
  balance=models.IntegerField(default=0)
  updated_at=models.DateTimeField(auto_now=True)
  class Meta:
    verbose_name=_("کیف پول"); verbose_name_plural=_("کیف پول‌ها")

class WalletTxnKind(models.TextChoices):
  TOPUP="topup",_("شارژ")
  ORDER_PAY="order_pay",_("پرداخت سفارش")
  REFUND="refund",_("بازگشت وجه")
  ADJUST="adjust",_("اصلاح")

class WalletTransaction(models.Model):
  id=models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
  wallet=models.ForeignKey(Wallet, on_delete=models.CASCADE, related_name="txns")
  kind=models.CharField(max_length=20, choices=WalletTxnKind.choices)
  amount=models.IntegerField()
  ref_order=models.ForeignKey(Order, on_delete=models.SET_NULL, null=True, blank=True, related_name="wallet_txns")
  description=models.CharField(max_length=250, blank=True)
  created_at=models.DateTimeField(auto_now_add=True)
  class Meta:
    ordering=["-created_at"]; verbose_name=_("تراکنش کیف پول"); verbose_name_plural=_("تراکنش‌های کیف پول")

class TopUpStatus(models.TextChoices):
  PENDING="pending",_("در انتظار بررسی")
  APPROVED="approved",_("تایید شده")
  REJECTED="rejected",_("رد شده")

class WalletTopUpRequest(models.Model):
  id=models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
  user=models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="topups")
  amount=models.PositiveIntegerField()
  receipt_image=models.ImageField(upload_to="wallet/topups/", blank=True, null=True)
  tracking_code=models.CharField(max_length=80, blank=True)
  note=models.TextField(blank=True)
  status=models.CharField(max_length=20, choices=TopUpStatus.choices, default=TopUpStatus.PENDING)
  created_at=models.DateTimeField(auto_now_add=True)
  reviewed_at=models.DateTimeField(blank=True, null=True)
  class Meta:
    ordering=["-created_at"]; verbose_name=_("درخواست شارژ"); verbose_name_plural=_("درخواست‌های شارژ")

class Invoice(models.Model):
  id=models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
  order=models.OneToOneField(Order, on_delete=models.CASCADE, related_name="invoice")
  number=models.CharField(max_length=30, unique=True, blank=True)
  issued_at=models.DateTimeField(default=timezone.now)
  billed_to=models.CharField(max_length=200, blank=True)
  billed_email=models.EmailField(blank=True)
  item_title=models.CharField(max_length=250)
  unit_price=models.PositiveIntegerField()
  discount=models.PositiveIntegerField(default=0)
  total=models.PositiveIntegerField(default=0)
  class Meta:
    ordering=["-issued_at"]; verbose_name=_("فاکتور"); verbose_name_plural=_("فاکتورها")
  def _gen(self):
    y=timezone.now().strftime("%Y")
    return f"INV-{y}-{uuid.uuid4().hex[:8].upper()}"
  def save(self,*a,**k):
    if not self.number: self.number=self._gen()
    if not self.total: self.total=max(int(self.unit_price)-int(self.discount or 0),0)
    super().save(*a,**k)

def wallet_apply(user, amount:int, kind:str, ref_order=None, description=""):
  with transaction.atomic():
    w,_ = Wallet.objects.select_for_update().get_or_create(user=user)
    w.balance = F("balance")+int(amount)
    w.save(update_fields=["balance"])
    w.refresh_from_db(fields=["balance"])
    WalletTransaction.objects.create(wallet=w, kind=kind, amount=int(amount), ref_order=ref_order, description=description)
    return w