#!/bin/sh
# Node.js のイメージの中で .vsix を作る（Node.js を入れていないコンピューターで使う）。
# vscode/ を /out に見せて実行すると、/out にできた .vsix だけを置く。
# node_modules などはコンテナの中に作るので、ホストの vscode/ には残らない。
#
#   docker run --rm -v "$PWD/vscode:/out" node:22 sh /out/scripts/package-in-docker.sh
set -eu

export HOME=/tmp
mkdir /tmp/build
# ホストの node_modules・media/pdfjs・作った .vsix は持ち込まない（中身が別の OS 向けのことがある）
tar -C /out --exclude=./node_modules --exclude=./media/pdfjs --exclude='./*.vsix' -cf - . | tar -C /tmp/build -xf -
cd /tmp/build
npm ci --no-audit --no-fund
npm run package
cp ./*.vsix /out/
# --user を付けずに動かしたとき（Linux）でも、ホストの利用者が消せるように、vscode/ と同じ持ち主にする
chown "$(stat -c %u:%g /out)" /out/*.vsix 2>/dev/null || true
