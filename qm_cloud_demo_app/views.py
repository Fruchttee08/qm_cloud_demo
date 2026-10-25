from django.shortcuts import render


def index(request):
    return render(request, 'qm_cloud_demo_app/index.html', {'content': 'Hallo aus der Django-App'})
