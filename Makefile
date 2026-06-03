.PHONY: fmt lint test build dev docker-build scan-secrets frontend-install

fmt:
	cargo fmt --all

lint:
	cargo check --workspace --all-targets --all-features
	cargo clippy --workspace --all-targets --all-features -- -D warnings
	npm --prefix web/admin-ui ci
	npm --prefix web/admin-ui run typecheck

test:
	cargo test --workspace --all-targets --all-features
	npm --prefix web/admin-ui ci
	npm --prefix web/admin-ui test
	npm --prefix web/admin-ui run build
	npm --prefix web/admin-ui run check:bundle

build:
	cargo build --workspace --all-targets --all-features
	npm --prefix web/admin-ui ci
	npm --prefix web/admin-ui run build
	npm --prefix web/admin-ui run check:bundle

frontend-install:
	npm --prefix web/admin-ui ci

dev:
	docker compose -f deploy/docker-compose/docker-compose.yml up --build

docker-build:
	docker build -f deploy/docker-compose/Dockerfile --build-arg BIN=ai-gateway .
	docker build -f deploy/docker-compose/Dockerfile --build-arg BIN=ai-control-plane .
	docker build -f deploy/docker-compose/Dockerfile --build-arg BIN=ai-worker .

scan-secrets:
	@rg -n "(sk-[A-Za-z0-9]{20,}|BEGIN PRIVATE KEY|Authorization: Bearer [A-Za-z0-9._-]{20,})" . -g "!target/**" -g "!**/node_modules/**" -g "!**/dist/**" -g "!dev_starter_unpacked/**" -g "!.docx_unpacked/**" -g "!scripts/scan_secrets.ps1" -g "!Makefile"; status=$$?; if [ $$status -eq 1 ]; then exit 0; fi; if [ $$status -ne 0 ]; then exit $$status; fi; exit 1
