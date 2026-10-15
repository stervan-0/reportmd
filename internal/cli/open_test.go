package cli

import (
	"os/exec"
	"testing"
)

func TestOpenCommand(t *testing.T) {
	cmd, err := openCommand("/tmp/a.pdf")
	if err != nil {
		if _, lookErr := exec.LookPath("xdg-open"); lookErr != nil && !isWSL() {
			t.Skip("ファイルを開くコマンドがない環境")
		}
		t.Fatal(err)
	}
	if len(cmd.Args) < 2 {
		t.Errorf("開くファイルを引数に渡す: %v", cmd.Args)
	}
}
