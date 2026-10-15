package cli

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
)

// openCommand は、ファイルを既定のアプリで開くコマンドを返す。
// WSL では、Windows 側のアプリ（PDF ビューアなど）で開く。
func openCommand(path string) (*exec.Cmd, error) {
	switch runtime.GOOS {
	case "darwin":
		return exec.Command("open", path), nil
	case "windows":
		return exec.Command("cmd", "/c", "start", "", path), nil
	}
	if isWSL() {
		if _, err := exec.LookPath("wslview"); err == nil {
			return exec.Command("wslview", path), nil
		}
		if out, err := exec.Command("wslpath", "-w", path).Output(); err == nil {
			return exec.Command("explorer.exe", strings.TrimSpace(string(out))), nil
		}
	}
	if _, err := exec.LookPath("xdg-open"); err == nil {
		return exec.Command("xdg-open", path), nil
	}
	return nil, errors.New("ファイルを開くコマンド（xdg-open など）が見つかりません")
}

func isWSL() bool {
	data, err := os.ReadFile("/proc/version")
	return err == nil && strings.Contains(strings.ToLower(string(data)), "microsoft")
}

// openFile は、ファイルを既定のアプリで開く（終わるのを待たない）。
func openFile(path string) error {
	abs, err := filepath.Abs(path)
	if err != nil {
		return err
	}
	cmd, err := openCommand(abs)
	if err != nil {
		return err
	}
	return cmd.Start()
}
