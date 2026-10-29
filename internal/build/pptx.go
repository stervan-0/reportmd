package build

import (
	"archive/zip"
	"bytes"
	"fmt"
	"io"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"text/template"

	"reportmd/internal/config"
)

// PowerPoint（.pptx）は、Pandoc の標準の雛形のスライドマスターに、PowerPoint の設定（setting.pptx.json）の
// 題名と本文の書式を書き込んだ雛形（reference.pptx）を作り、Pandoc に --reference-doc で渡す。
// 題名の下の線は、題名のあるスライドにだけ引くので、生成したスライドに後から書き足す。

// referencePptxName は、作業ディレクトリに書く雛形の名前。
const referencePptxName = "reference.pptx"

// pptxMaster は、雛形のスライドマスター。
const pptxMaster = "ppt/slideMasters/slideMaster1.xml"

// emu は pt を PowerPoint の単位（1/12700 pt）にする。
func emu(pt float64) int { return int(math.Round(pt * 12700)) }

// pptxColor は、設定の色（"#1F3864" など）を PowerPoint の値（"1F3864"）にする。
func pptxColor(s string) string { return strings.ToUpper(strings.TrimPrefix(s, "#")) }

var (
	titleStyleXML = regexp.MustCompile(`(?s)<p:titleStyle>.*?</p:titleStyle>`)
	bodyStyleXML  = regexp.MustCompile(`(?s)<p:bodyStyle>.*?</p:bodyStyle>`)
	defRPrOpen    = regexp.MustCompile(`<a:defRPr sz="(\d+)"`)
	textFill      = regexp.MustCompile(`<a:solidFill>.*?</a:solidFill>`)
	majorFonts    = regexp.MustCompile(`<a:latin typeface="\+mj-lt"/><a:ea typeface="\+mj-ea"/>`)
)

// PptxMaster は、スライドマスターの題名（titleStyle）と本文（bodyStyle）の書式を、設定に合わせて書き換える。
// 題名：文字サイズ・色・太字・フォント。
// 本文：1段目を text.size にし、2段目からは標準の雛形の比率で小さくする。
func PptxMaster(master string, cfg *config.Config) string {
	title := fmt.Sprintf(`<a:defRPr sz="%d"`, int(math.Round(points(cfg.Slide.Title.Size)*100)))
	if cfg.Slide.Title.Bold {
		title += ` b="1"`
	}
	font := template.HTMLEscapeString(cfg.Slide.Title.Font)
	master = titleStyleXML.ReplaceAllStringFunc(master, func(s string) string {
		s = defRPrOpen.ReplaceAllLiteralString(s, title)
		s = textFill.ReplaceAllLiteralString(s, `<a:solidFill><a:srgbClr val="`+pptxColor(cfg.Slide.Title.Color)+`"/></a:solidFill>`)
		return majorFonts.ReplaceAllLiteralString(s, `<a:latin typeface="`+font+`"/><a:ea typeface="`+font+`"/>`)
	})
	// 標準の雛形の本文の1段目は 24pt
	scale := points(cfg.Slide.Text.Size) / 24
	return bodyStyleXML.ReplaceAllStringFunc(master, func(s string) string {
		return defRPrOpen.ReplaceAllStringFunc(s, func(m string) string {
			sz, _ := strconv.Atoi(defRPrOpen.FindStringSubmatch(m)[1])
			return fmt.Sprintf(`<a:defRPr sz="%d"`, int(math.Round(float64(sz)*scale/50))*50)
		})
	})
}

// ReferencePptx は、Pandoc の標準の雛形をもとに、設定を反映した雛形を作る。
func ReferencePptx(cfg *config.Config) ([]byte, error) {
	base, err := exec.Command("pandoc", "--print-default-data-file", "reference.pptx").Output()
	if err != nil {
		return nil, &Error{Message: fmt.Sprintf("Pandoc の標準の PowerPoint の雛形を読めません（%v）", err)}
	}
	reference, err := rewriteZip(base, func(name string, data []byte) []byte {
		if name == pptxMaster {
			return []byte(PptxMaster(string(data), cfg))
		}
		return data
	}, nil)
	if err != nil {
		return nil, &Error{Message: fmt.Sprintf("PowerPoint の雛形を作れません（%v）", err)}
	}
	return reference, nil
}

// writePptxFiles は、PowerPoint の出力に使う雛形（reference.pptx）を dir に書き出し、そのパスを paths に加える。
func writePptxFiles(dir string, cfg *config.Config, paths map[string]string) error {
	reference, err := ReferencePptx(cfg)
	if err != nil {
		return err
	}
	path := filepath.Join(dir, referencePptxName)
	if err := os.WriteFile(path, reference, 0o644); err != nil {
		return &Error{Message: fmt.Sprintf("一時ファイルを書き込めません（%v）", err)}
	}
	paths[referencePptxName] = path
	return nil
}

var (
	slideXML      = regexp.MustCompile(`^ppt/slides/slide\d+\.xml$`)
	titlePlace    = regexp.MustCompile(`(?s)<p:ph type="title"\s*/>.*?<a:off x="(\d+)" y="(\d+)"\s*/><a:ext cx="(\d+)" cy="(\d+)"\s*/>`)
	titleInSlide  = regexp.MustCompile(`<p:ph type="title"\s*/>`)
	ruleShapeName = "reportmd Title Rule"
)

// titleRule は、題名の枠（スライドマスターの題名のプレースホルダー）の下端に引く線の図形を返す。
// 枠が見つからなければ空。
func titleRule(master string, cfg *config.Config) string {
	width := cfg.Slide.RuleWidth()
	m := titlePlace.FindStringSubmatch(master)
	if width == "" || m == nil {
		return ""
	}
	x, y, cx, cy := m[1], m[2], m[3], m[4]
	bottom, _ := strconv.Atoi(y)
	h, _ := strconv.Atoi(cy)
	return fmt.Sprintf(`<p:cxnSp><p:nvCxnSpPr><p:cNvPr id="9999" name="%s"/><p:cNvCxnSpPr/><p:nvPr/></p:nvCxnSpPr>`+
		`<p:spPr><a:xfrm><a:off x="%s" y="%d"/><a:ext cx="%s" cy="0"/></a:xfrm><a:prstGeom prst="line"><a:avLst/></a:prstGeom>`+
		`<a:ln w="%d"><a:solidFill><a:srgbClr val="%s"/></a:solidFill></a:ln></p:spPr></p:cxnSp>`,
		ruleShapeName, x, bottom+h, cx, emu(lengthPoints(width)), pptxColor(cfg.Slide.Title.Color))
}

// fixPptx は、Pandoc が出力した PowerPoint の、題名のあるスライドに、題名の下の線を引く。
// 表紙や改ページのあとの（題名のない）スライドには引かない。
func fixPptx(path string, cfg *config.Config) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	master, err := zipFile(data, pptxMaster)
	if err != nil {
		return err
	}
	rule := titleRule(string(master), cfg)
	if rule == "" {
		return nil
	}
	out, err := rewriteZip(data, func(name string, content []byte) []byte {
		s := string(content)
		if !slideXML.MatchString(name) || !titleInSlide.MatchString(s) {
			return content
		}
		return []byte(strings.Replace(s, "</p:spTree>", rule+"</p:spTree>", 1))
	}, nil)
	if err != nil {
		return err
	}
	return os.WriteFile(path, out, 0o644)
}

// zipFile は、ZIP の中のファイル name の内容を返す。
func zipFile(data []byte, name string) ([]byte, error) {
	r, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		return nil, err
	}
	f, err := r.Open(name)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	return io.ReadAll(f)
}
