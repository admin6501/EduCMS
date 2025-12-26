from django.views.generic import ListView, DetailView
from .models import Course, PublishStatus
from .access import user_has_course_access

class CourseListView(ListView):
  template_name="courses/list.html"
  paginate_by=12
  def get_queryset(self):
    return Course.objects.filter(status=PublishStatus.PUBLISHED).order_by("-updated_at")

class CourseDetailView(DetailView):
  template_name="courses/detail.html"
  model=Course
  slug_field="slug"
  slug_url_kwarg="slug"
  def get_queryset(self):
    return Course.objects.filter(status=PublishStatus.PUBLISHED)
  def get_context_data(self,**k):
    ctx=super().get_context_data(**k)
    ctx["has_access"]=user_has_course_access(self.request.user, self.object)
    return ctx
