VERSION := $(shell sed -n 's/^const Version = "\(.*\)"/\1/p' internal/cli/cli.go)
PREFIX ?= $(HOME)/.local
TARGETS := linux/amd64 linux/arm64 darwin/amd64 darwin/arm64 windows/amd64

.PHONY: build test install uninstall dist example vscode vscode-test clean

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
	@# インストール先が PATH に入っていなければ、使えるようにする方法を案内する
	@# （Ubuntu の ~/.profile は、ログインの時点で ~/.local/bin があるときだけ PATH に入れる）
	@case ":$$PATH:" in \
		*":$(PREFIX)/bin:"*) echo "reportmd をインストールしました。reportmd で使えます" ;; \
		*) echo ""; \
		   echo "reportmd をインストールしましたが、$(PREFIX)/bin が PATH に入っていません。"; \
		   echo "次のどちらかを実行すると、reportmd で使えるようになります:"; \
		   echo "  source ~/.profile     （またはターミナルを開き直す）"; \
		   echo "  echo 'export PATH=\"$(PREFIX)/bin:\$$PATH\"' >> ~/.bashrc && source ~/.bashrc" ;; \
	esac

# install で入れたものを取り除く（reportmd が置くファイルは実行ファイルだけ）。
# install と同じ PREFIX を指定する
uninstall:
	rm -f $(PREFIX)/bin/reportmd

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
	./reportmd build examples/report.reportmd

# VS Code 拡張機能（vscode/）を .vsix にまとめる（Node.js が必要）
vscode:
	cd vscode && npm run package

# VS Code 拡張機能のテスト（Node.js が必要）
vscode-test:
	cd vscode && npm install && npm test

clean:
	rm -rf reportmd dist examples/*.pdf vscode/*.vsix
