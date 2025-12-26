from .models import Enrollment, CourseGrant
def user_has_course_access(user, course):
  if course.is_free_for_all: return True
  if not user.is_authenticated: return False
  if Enrollment.objects.filter(user=user, course=course, is_active=True).exists(): return True
  if CourseGrant.objects.filter(user=user, course=course, is_active=True).exists(): return True
  return False
