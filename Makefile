.PHONY: build up down smoke test logs

build:
	docker compose build --no-cache

up:
	docker compose --compatibility up -d

down:
	docker compose down --remove-orphans

smoke:
	curl -fsS http://localhost:9999/ready

test:
	sh scripts/official-test.sh full

smoke:
	sh scripts/official-test.sh smoke

logs:
	docker compose logs -f --tail=100

docker/clean:
	docker compose down --remove-orphans --rmi all --volumes
	docker compose rm -f

build/push:
	docker compose push