from .models import CouponType, Coupon, Order, OrderStatus
def calc_coupon_discount(coupon, base):
  if not coupon: return 0
  if coupon.type==CouponType.PERCENT:
    pct=min(max(int(coupon.value),0),100)
    return (base*pct)//100
  return min(int(coupon.value), base)

def coupon_total_uses(coupon):
  return Order.objects.filter(coupon=coupon).exclude(status=OrderStatus.CANCELED).count()

def coupon_user_uses(coupon,user):
  return Order.objects.filter(user=user, coupon=coupon).exclude(status=OrderStatus.CANCELED).count()

def validate_coupon(code,user,base):
  code=(code or "").strip()
  if not code: return None,"کدی وارد نشده."
  try:
    c=Coupon.objects.get(code__iexact=code)
  except Coupon.DoesNotExist:
    return None,"کد نامعتبر است."
  if not c.is_valid_now(): return None,"کد فعال نیست یا تاریخ آن گذشته است."
  if base < c.min_amount: return None,"این کد برای این مبلغ قابل استفاده نیست."
  if c.max_uses and coupon_total_uses(c) >= c.max_uses: return None,"سقف استفاده پر شده."
  if c.max_uses_per_user and coupon_user_uses(c,user) >= c.max_uses_per_user: return None,"سقف استفاده شما پر شده."
  return c,""
