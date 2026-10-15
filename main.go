// reportmd は、Markdown の書きやすさのまま、大学のレポートに必要な組版を追加して
// PDF を出力するツール。仕様は docs/spec.md を参照。
package main

import (
	"os"

	"reportmd/internal/cli"
)

func main() {
	os.Exit(cli.Main(os.Args[1:]))
}
