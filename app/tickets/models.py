import uuid
from django.db import models
from django.conf import settings
from django.utils.translation import gettext_lazy as _

class TicketStatus(models.TextChoices):
  OPEN="open",_("باز")
  ANSWERED="answered",_("پاسخ داده شده")
  CLOSED="closed",_("بسته")

class Ticket(models.Model):
  id=models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
  user=models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="tickets")
  subject=models.CharField(max_length=200)
  description=models.TextField()
  attachment=models.FileField(upload_to="tickets/", blank=True, null=True)
  status=models.CharField(max_length=20, choices=TicketStatus.choices, default=TicketStatus.OPEN)
  created_at=models.DateTimeField(auto_now_add=True)
  updated_at=models.DateTimeField(auto_now=True)
  class Meta:
    ordering=["-created_at"]; verbose_name=_("تیکت"); verbose_name_plural=_("تیکت‌ها")

class TicketReply(models.Model):
  id=models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
  ticket=models.ForeignKey(Ticket, on_delete=models.CASCADE, related_name="replies")
  user=models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE)
  message=models.TextField()
  attachment=models.FileField(upload_to="tickets/replies/", blank=True, null=True)
  created_at=models.DateTimeField(auto_now_add=True)
  class Meta:
    ordering=["created_at"]; verbose_name=_("پاسخ تیکت"); verbose_name_plural=_("پاسخ‌های تیکت")
