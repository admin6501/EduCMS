from django.contrib.auth.decorators import login_required
from django.shortcuts import render, redirect, get_object_or_404
from django.contrib import messages
from .models import Ticket, TicketStatus
from .forms import TicketCreateForm, TicketReplyForm

@login_required
def ticket_list(request):
  tickets=Ticket.objects.filter(user=request.user)
  return render(request,"tickets/list.html",{"tickets":tickets})

@login_required
def ticket_create(request):
  form=TicketCreateForm(request.POST or None, request.FILES or None)
  if request.method=="POST" and form.is_valid():
    t=form.save(commit=False); t.user=request.user; t.status=TicketStatus.OPEN; t.save()
    messages.success(request,"تیکت ثبت شد.")
    return redirect("ticket_detail", ticket_id=t.id)
  return render(request,"tickets/create.html",{"form":form})

@login_required
def ticket_detail(request, ticket_id):
  ticket=get_object_or_404(Ticket, id=ticket_id, user=request.user)
  form=TicketReplyForm(request.POST or None, request.FILES or None)
  if request.method=="POST" and form.is_valid():
    r=form.save(commit=False); r.ticket=ticket; r.user=request.user; r.save()
    ticket.status=TicketStatus.OPEN; ticket.save(update_fields=["status"])
    messages.success(request,"پاسخ ثبت شد.")
    return redirect("ticket_detail", ticket_id=ticket.id)
  return render(request,"tickets/detail.html",{"ticket":ticket,"form":form})
