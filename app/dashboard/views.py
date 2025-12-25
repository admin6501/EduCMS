from django.contrib.auth.decorators import login_required
from django.shortcuts import render
from courses.models import Enrollment
from payments.models import Order, Wallet
from tickets.models import Ticket

@login_required
def dashboard_home(request):
  enrollments = Enrollment.objects.filter(user=request.user, is_active=True).select_related("course").order_by("-created_at")[:12]
  orders = Order.objects.filter(user=request.user).select_related("course").order_by("-created_at")[:10]
  tickets = Ticket.objects.filter(user=request.user).order_by("-created_at")[:10]
  wallet,_ = Wallet.objects.get_or_create(user=request.user)
  return render(request,"dashboard/home.html",{"enrollments":enrollments,"orders":orders,"tickets":tickets,"wallet":wallet})