from django.urls import path

from . import views

urlpatterns = [
    path("plaintext", views.plaintext),
    path("json", views.json_small),
    path("json-large", views.json_large),
]
