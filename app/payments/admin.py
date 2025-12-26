from django.contrib import admin
from django.utils import timezone
from django.db import transaction
from courses.models import Enrollment
from .models import BankTransferSetting, Order, OrderStatus, Coupon, Wallet, WalletTransaction, WalletTopUpRequest, TopUpStatus, wallet_apply, Invoice

def ensure_invoice(order):
  if hasattr(order,"invoice"): return order.invoice
  return Invoice.objects.create(
    order=order,
    billed_to=(order.user.get_full_name() or order.user.username),
    billed_email=(order.user.email or ""),
    item_title=f"خرید دوره: {order.course.title}",
    unit_price=order.amount, discount=order.discount_amount, total=order.final_amount,
  )

@admin.action(description="تایید سفارش + فعال‌سازی دسترسی + صدور فاکتور")
def mark_paid(modeladmin, request, qs):
  now=timezone.now()
  with transaction.atomic():
    for o in qs.select_for_update():
      o.status=OrderStatus.PAID; o.verified_at=now
      o.save(update_fields=["status","verified_at"])
      Enrollment.objects.get_or_create(user=o.user, course=o.course, defaults={"is_active":True,"source":"paid"})
      ensure_invoice(o)

@admin.register(Order)
class OrderAdmin(admin.ModelAdmin):
  list_display=("id","user","course","final_amount","status","created_at")
  list_filter=("status","created_at")
  search_fields=("user__username","course__title","tracking_code","coupon__code")
  actions=[mark_paid]

@admin.action(description="تایید شارژ و اعمال به کیف پول")
def approve_topup(modeladmin, request, qs):
  now=timezone.now()
  with transaction.atomic():
    for t in qs.select_for_update():
      if t.status!=TopUpStatus.PENDING: continue
      t.status=TopUpStatus.APPROVED; t.reviewed_at=now
      t.save(update_fields=["status","reviewed_at"])
      wallet_apply(t.user, int(t.amount), kind="topup", description="شارژ تایید شده توسط ادمین")

@admin.action(description="رد شارژ")
def reject_topup(modeladmin, request, qs):
  now=timezone.now()
  for t in qs:
    if t.status==TopUpStatus.PENDING:
      t.status=TopUpStatus.REJECTED; t.reviewed_at=now
      t.save(update_fields=["status","reviewed_at"])

@admin.register(WalletTopUpRequest)
class WalletTopUpRequestAdmin(admin.ModelAdmin):
  list_display=("id","user","amount","status","created_at")
  list_filter=("status","created_at")
  search_fields=("user__username","tracking_code")
  actions=[approve_topup, reject_topup]

admin.site.register(BankTransferSetting)
admin.site.register(Coupon)
admin.site.register(Wallet)
admin.site.register(WalletTransaction)
admin.site.register(Invoice)
