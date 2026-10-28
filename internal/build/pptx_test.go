package build

import (
	"strings"
	"testing"

	"reportmd/internal/config"
)

// testMaster は、Pandoc の標準の雛形のスライドマスターから、書き換える部分を抜き出したもの。
const testMaster = `<p:sp><p:nvSpPr><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr><p:spPr><a:xfrm><a:off x="457200" y="205979"/><a:ext cx="8229600" cy="857250"/></a:xfrm></p:spPr></p:sp>` +
	`<p:txStyles><p:titleStyle><a:lvl1pPr algn="ctr"><a:defRPr sz="3300" kern="1200"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill>` +
	`<a:latin typeface="+mj-lt"/><a:ea typeface="+mj-ea"/><a:cs typeface="+mj-cs"/></a:defRPr></a:lvl1pPr></p:titleStyle>` +
	`<p:bodyStyle><a:lvl1pPr><a:defRPr sz="2400" kern="1200"/></a:lvl1pPr><a:lvl2pPr><a:defRPr sz="2100" kern="1200"/></a:lvl2pPr>` +
	`<a:lvl3pPr><a:defRPr sz="1800" kern="1200"/></a:lvl3pPr></p:bodyStyle>` +
	`<p:otherStyle><a:lvl1pPr><a:defRPr sz="1800"/></a:lvl1pPr></p:otherStyle></p:txStyles>`

func TestPptxMasterDefault(t *testing.T) {
	got := PptxMaster(testMaster, config.Default())
	for _, want := range []string{
		`<a:defRPr sz="3600" b="1" kern="1200"><a:solidFill><a:srgbClr val="1F3864"/></a:solidFill>`, // 題名は 36pt・太字・濃い紺
		`<a:latin typeface="IPAexGothic"/><a:ea typeface="IPAexGothic"/>`,                            // 見出しのフォント
		`<a:lvl1pPr><a:defRPr sz="2000"`,                                                             // 本文の1段目は 20pt
		`<a:lvl2pPr><a:defRPr sz="1750"`,                                                             // 2段目からは標準の比率（21/24）で小さくする
		`<a:lvl3pPr><a:defRPr sz="1500"`,
		`<p:otherStyle><a:lvl1pPr><a:defRPr sz="1800"/>`, // 題名・本文以外は変えない
	} {
		if !strings.Contains(got, want) {
			t.Errorf("%s がない:\n%s", want, got)
		}
	}
}

func TestPptxMasterCustom(t *testing.T) {
	cfg, err := config.New(map[string]any{
		"heading": map[string]any{"font": "A<B", "bold": false},
		"slide":   map[string]any{"title": map[string]any{"size": "28pt", "color": "#c00000"}, "text": map[string]any{"size": "18pt"}},
	}, "")
	if err != nil {
		t.Fatal(err)
	}
	got := PptxMaster(testMaster, cfg)
	for _, want := range []string{`<a:defRPr sz="2800" kern="1200"><a:solidFill><a:srgbClr val="C00000"/>`, `typeface="A&lt;B"`, `<a:lvl1pPr><a:defRPr sz="1800"`} {
		if !strings.Contains(got, want) {
			t.Errorf("%s がない:\n%s", want, got)
		}
	}
}

func TestTitleRule(t *testing.T) {
	// 題名の枠の下端（205979 + 857250）に、枠と同じ幅で、2pt（25400）の線を引く
	got := titleRule(testMaster, config.Default())
	for _, want := range []string{`<a:off x="457200" y="1063229"/><a:ext cx="8229600" cy="0"/>`, `<a:ln w="25400"><a:solidFill><a:srgbClr val="1F3864"/>`} {
		if !strings.Contains(got, want) {
			t.Errorf("%s がない: %s", want, got)
		}
	}
	cfg, err := config.New(map[string]any{"slide": map[string]any{"title": map[string]any{"rule": false}}}, "")
	if err != nil {
		t.Fatal(err)
	}
	if got := titleRule(testMaster, cfg); got != "" {
		t.Errorf("rule が false なら線を引かない: %s", got)
	}
}
