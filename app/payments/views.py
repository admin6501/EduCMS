from django.contrib.auth.decorators import login_required
from django.shortcuts import get_object_or_404, redirect, render
from django.contrib import messages
from django.utils import timezone
from django.db import transaction
from courses.models import Course, PublishStatus, Enrollment
from courses.access import user_has_course_access
from .models import BankTransferSetting, Order, OrderStatus, Wallet, WalletTopUpRequest, TopUpStatus, wallet_apply, Invoice
from .forms import ReceiptUploadForm, CouponApplyForm, WalletTopUpForm
from .utils import validate_coupon, calc_coupon_discount

def ensure_invoice(order:Order):
  if hasattr(order,"invoice"): return order.invoice
  return Invoice.objects.create(
    order=order,
    billed_to=(order.user.get_full_name() or order.user.username),
    billed_email=(order.user.email or ""),
    item_title=f"خرید دوره: {order.course.title}",
    unit_price=order.amount, discount=order.discount_amount, total=order.final_amount,
  )

@login_required
def checkout(request, slug):
  course=get_object_or_404(Course, slug=slug, status=PublishStatus.PUBLISHED)
  if course.is_free_for_all:
    Enrollment.objects.get_or_create(user=request.user, course=course, defaults={"is_active":True,"source":"free_all"})
    return redirect("course_detail", slug=course.slug)
  if user_has_course_access(request.user, course):
    return redirect("course_detail", slug=course.slug)

  setting=BankTransferSetting.objects.first()
  order=Order.objects.filter(user=request.user, course=course).exclude(status__in=[OrderStatus.PAID,OrderStatus.CANCELED]).first()
  if not order:
    order=Order.objects.create(user=request.user, course=course, amount=course.price_toman, discount_amount=0, final_amount=course.price_toman, status=OrderStatus.PENDING_PAYMENT)

  base=order.amount
  first_paid = Order.objects.filter(user=request.user, status=OrderStatus.PAID).count()==0
  coupon_form=CouponApplyForm(request.POST or None)
  applied=None
  if request.method=="POST" and "apply_coupon" in request.POST:
    code=(request.POST.get("coupon_code","") or "").strip()
    if code:
      applied,msg = validate_coupon(code, request.user, base)
      messages.success(request,"کد اعمال شد.") if applied else messages.error(request,msg)

  discount=0; label=""
  if applied:
    discount=calc_coupon_discount(applied, base); label=f"کد: {applied.code}"
  elif first_paid and setting:
    pct=min(max(int(setting.first_purchase_percent or 0),0),100)
    discount=max((base*pct)//100, min(int(setting.first_purchase_amount or 0), base))
    if discount>0: label="تخفیف خرید اول"

  discount=min(discount, base)
  final=max(base-discount,0)
  order.coupon=applied; order.discount_amount=discount; order.final_amount=final
  order.save(update_fields=["coupon","discount_amount","final_amount"])

  wallet,_ = Wallet.objects.get_or_create(user=request.user)

  if request.method=="POST" and "pay_wallet" in request.POST:
    if wallet.balance < final:
      messages.error(request,"موجودی کیف پول کافی نیست.")
    else:
      with transaction.atomic():
        o=Order.objects.select_for_update().get(id=order.id)
        if o.status in [OrderStatus.PAID,OrderStatus.CANCELED]:
          return redirect("orders_my")
        wallet_apply(request.user, -int(final), kind="order_pay", ref_order=o, description=f"پرداخت سفارش {o.id}")
        o.status=OrderStatus.PAID; o.verified_at=timezone.now()
        o.save(update_fields=["status","verified_at"])
        Enrollment.objects.get_or_create(user=request.user, course=course, defaults={"is_active":True,"source":"wallet"})
        ensure_invoice(o)
        messages.success(request,"پرداخت با کیف پول انجام شد.")
        return redirect("invoice_detail", order_id=o.id)

  return render(request,"orders/checkout.html",{
    "course":course,"setting":setting,"order":order,"coupon_form":coupon_form,
    "discount_label":label,"first_purchase_eligible":first_paid,"wallet":wallet,
  })

@login_required
def upload_receipt(request, order_id):
  order=get_object_or_404(Order, id=order_id, user=request.user)
  if order.status in [OrderStatus.PAID,OrderStatus.CANCELED]:
    return redirect("orders_my")
  form=ReceiptUploadForm(request.POST or None, request.FILES or None, instance=order)
  if request.method=="POST" and form.is_valid():
    form.save()
    order.status=OrderStatus.PENDING_VERIFY
    order.save(update_fields=["status"])
    messages.success(request,"رسید ثبت شد و پس از بررسی فعال می‌شود.")
    return redirect("orders_my")
  return render(request,"orders/receipt.html",{"order":order,"form":form})

@login_required
def my_orders(request):
  orders=Order.objects.filter(user=request.user).select_related("course")
  return render(request,"orders/my.html",{"orders":orders})

@login_required
def cancel_order(request, order_id):
  o=get_object_or_404(Order, id=order_id, user=request.user)
  if o.status=="paid":
    messages.error(request,"سفارش پرداخت‌شده قابل لغو نیست.")
    return redirect("orders_my")
  if request.method=="POST":
    o.status=OrderStatus.CANCELED; o.save(update_fields=["status"])
    messages.success(request,"سفارش لغو شد.")
  return redirect("orders_my")

@login_required
def wallet_home(request):
  wallet,_=Wallet.objects.get_or_create(user=request.user)
  txns=wallet.txns.all()[:50]
  topups=WalletTopUpRequest.objects.filter(user=request.user).order_by("-created_at")[:20]
  return render(request,"wallet/home.html",{"wallet":wallet,"txns":txns,"topups":topups})

@login_required
def wallet_topup(request):
  form=WalletTopUpForm(request.POST or None, request.FILES or None)
  if request.method=="POST" and form.is_valid():
    t=form.save(commit=False); t.user=request.user; t.status=TopUpStatus.PENDING; t.save()
    messages.success(request,"درخواست شارژ ثبت شد.")
    return redirect("wallet_home")
  return render(request,"wallet/topup.html",{"form":form})

@login_required
def invoice_list(request):
  invs=Invoice.objects.filter(order__user=request.user).select_related("order","order__course").order_by("-issued_at")
  return render(request,"invoices/list.html",{"invoices":invs})

@login_required
def invoice_detail(request, order_id):
  inv=get_object_or_404(Invoice, order__id=order_id, order__user=request.user)
  return render(request,"invoices/detail.html",{"invoice":inv})