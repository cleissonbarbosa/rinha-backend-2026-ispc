.PHONY: build up down smoke test logs profile

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

profile:
	ENABLE_PROFILER=1 PROFILE=1 PROFILE_LOG_EVERY=$${PROFILE_LOG_EVERY:-5000} docker compose up -d --build
	sh scripts/official-test.sh full
	docker compose logs --tail=200 api1 api2

docker/clean:
	docker compose down --remove-orphans --rmi all --volumes
	docker compose rm -f

build/push:
	docker compose push