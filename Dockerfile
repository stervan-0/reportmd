# reportmd と、PDF の生成に必要なもの（Pandoc・XeLaTeX・既定のフォント）をまとめたイメージ。
#
#   docker build -t reportmd .
#   docker run --rm -it -v "$PWD:/work" reportmd build report.reportmd
#
# 使い方の詳細は README の「Docker で使う」を参照。

# 1. reportmd をビルドする（依存するモジュールはないので、go.sum はない）
FROM golang:1.24 AS build
WORKDIR /src
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o /reportmd .

# 2. 実行に使うイメージ（開発環境と同じ Ubuntu 24.04 の Pandoc・TeX Live を使う）
#    Pandoc のテンプレートが任意で読む upquote・xurl を含む texlive-latex-extra は、texlive-xetex の依存で入る。
FROM ubuntu:24.04
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      pandoc \
      texlive-xetex \
      texlive-latex-recommended \
      texlive-fonts-recommended \
      texlive-lang-cjk \
      texlive-lang-chinese \
      lmodern \
      fontconfig \
      fonts-ipaexfont \
      fonts-noto-cjk \
      tzdata \
 && rm -rf /var/lib/apt/lists/*
COPY --from=build /reportmd /usr/local/bin/reportmd

# 日本語のファイル名を扱えるようにする（ロケールがないと、Pandoc が日本語のパスのファイルを開けない）
ENV LANG=C.UTF-8
# 監視中の「[15:04:05] 変更を検出しました」などの時刻を日本時間にする（-e TZ=... で変えられる）
ENV TZ=Asia/Tokyo
# --user でホストの利用者として動かしても、TeX やフォントのキャッシュを書けるようにする
ENV HOME=/tmp
WORKDIR /work
ENTRYPOINT ["reportmd"]
