.PHONY: kind minikube clean
kind:
	docker compose --project-directory kind -f kind/docker-compose.yml up -d

minikube:
	docker compose --project-directory minikube -f minikube/docker-compose.yml up -d

clean:
	docker compose --project-directory kind -f kind/docker-compose.yml down -v --remove-orphans
	docker compose --project-directory minikube -f minikube/docker-compose.yml down -v --remove-orphans
