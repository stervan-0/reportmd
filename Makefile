VERSION := $(shell sed -n 's/^const Version = "\(.*\)"/\1/p' internal/cli/cli.go)
PREFIX ?= $(HOME)/.local
TARGETS := linux/amd64 linux/arm64 darwin/amd64 darwin/arm64 windows/amd64

.PHONY: build test install dist example clean

# 実行ファイル reportmd を作る
build:
	go build -o reportmd .

# 自動テスト（Pandoc・XeLaTeX がない環境では、それが必要なテストを飛ばす）
test:
	go vet ./...
	go test ./...

# $(PREFIX)/bin に入れる（既定は ~/.local/bin）
install: build
	install -d $(PREFIX)/bin
	install -m 755 reportmd $(PREFIX)/bin/reportmd

# 各 OS 向けの実行ファイルを dist/ に作る
dist:
	@for target in $(TARGETS); do \
		os=$${target%/*}; arch=$${target#*/}; ext=; \
		[ $$os = windows ] && ext=.exe; \
		echo "dist/reportmd-$(VERSION)-$$os-$$arch$$ext"; \
		CGO_ENABLED=0 GOOS=$$os GOARCH=$$arch go build -trimpath -ldflags "-s -w" \
			-o dist/reportmd-$(VERSION)-$$os-$$arch$$ext . || exit 1; \
	done

# サンプルの PDF を作る
example: build
	./reportmd build examples/report.rmd

clean:
	rm -rf reportmd dist examples/*.pdf
