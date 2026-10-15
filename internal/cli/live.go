package cli

import (
	"bufio"
	"crypto/sha256"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
	"sync"
)

// liveSource は、watch --stdin で受け取った、文書の保存されていない内容（エディタで編集中の内容）。
//
// 標準入力からは、次の形のメッセージを続けて受け取る（仕様 13.4）。
//
//	<バイト数>\n<内容>   … 文書の内容を、この内容に置き換える
//	-\n                  … 置き換えをやめて、ファイルの内容を使う（保存したとき・編集を取り消したとき）
type liveSource struct {
	mu    sync.Mutex
	text  []byte // nil なら、ファイルの内容を使う
	first chan struct{}
	once  sync.Once
}

// newLiveSource は、r からメッセージを読み始める。
func newLiveSource(r io.Reader) *liveSource {
	l := &liveSource{first: make(chan struct{})}
	go l.read(r)
	return l
}

func (l *liveSource) read(r io.Reader) {
	defer l.received() // 読み終えたら（標準入力が閉じられても）、最初のメッセージを待たない
	br := bufio.NewReader(r)
	for {
		header, err := br.ReadString('\n')
		if err != nil {
			return
		}
		header = strings.TrimSpace(header)
		var text []byte
		if header != "-" {
			n, err := strconv.Atoi(header)
			if err != nil || n < 0 {
				return // 形が違うメッセージ以降は読まない
			}
			text = make([]byte, n)
			if _, err := io.ReadFull(br, text); err != nil {
				return
			}
		}
		l.mu.Lock()
		l.text = text
		l.mu.Unlock()
		l.received()
	}
}

func (l *liveSource) received() {
	l.once.Do(func() { close(l.first) })
}

// waitFirst は、最初のメッセージを受け取るまで待つ（最初の生成から、編集中の内容を使うため）。
func (l *liveSource) waitFirst() {
	<-l.first
}

// get は、受け取った内容を返す。置き換えていなければ nil。
func (l *liveSource) get() []byte {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.text
}

// state は、文書の内容（置き換えた内容、なければファイルの内容）のハッシュ。監視で変更を見つけるのに使う。
func (l *liveSource) state(input string) string {
	text := l.get()
	if text == nil {
		data, err := os.ReadFile(input)
		if err != nil {
			return "missing"
		}
		text = data
	}
	return fmt.Sprintf("%x", sha256.Sum256(text))
}
