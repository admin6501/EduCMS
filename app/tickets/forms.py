from django import forms
from .models import Ticket, TicketReply
_INPUT="w-full rounded-xl border border-slate-200 bg-white px-3 py-2 outline-none focus:ring-2 focus:ring-slate-300 dark:bg-slate-900 dark:border-slate-700 dark:focus:ring-slate-700"
class TicketCreateForm(forms.ModelForm):
  class Meta:
    model=Ticket
    fields=("subject","description","attachment")
    widgets={"subject": forms.TextInput(attrs={"class":_INPUT}),
             "description": forms.Textarea(attrs={"class":_INPUT,"rows":5})}
class TicketReplyForm(forms.ModelForm):
  class Meta:
    model=TicketReply
    fields=("message","attachment")
    widgets={"message": forms.Textarea(attrs={"class":_INPUT,"rows":4})}