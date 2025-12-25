from django.contrib import admin
from .models import Ticket, TicketReply
class TicketReplyInline(admin.TabularInline):
  model=TicketReply; extra=0
@admin.register(Ticket)
class TicketAdmin(admin.ModelAdmin):
  list_display=("id","user","subject","status","created_at")
  list_filter=("status","created_at")
  search_fields=("user__username","subject")
  inlines=[TicketReplyInline]
admin.site.register(TicketReply)