# Translating Curator

Curator's interface is written in US English and translated with [Crowdin](https://crowdin.com).
The translations are gettext files in `app/assets/l10n/`:

| File | What it is |
| --- | --- |
| `curator.pot` | The template: every English text, with the source files using it (`#:`) |
| `zh-Hans.po`, `zh-Hant.po`, `ja.po`, … | One language each, named by its locale (BCP 47) |

Each text is its own key: `msgid` is the English exactly as the interface shows it. A
`msgctxt` tells apart one English word that means two things (`page` / `Flags`: the Settings
page, not a note's flags; `heading` / `Import`: what a group of settings is about, not the button; `lilypond` / `repeat`: the kind of word the LilyPond editor offers, in LilyPond's own terms). Keep every `{placeholder}`; where it goes is up to the language.
Text left untranslated shows in English.

## Terms

Use the same word for the same thing throughout.

| English | 简体中文 | 繁體中文 | 日本語 |
| --- | --- | --- | --- |
| score | 乐谱 | 樂譜 | 楽譜 |
| project | 项目 | 專案 | プロジェクト |
| file | 文件 | 檔案 | ファイル |
| video | 视频 | 影片 | ビデオ |
| audio | 音频 | 音訊 | オーディオ |
| lane | 轨道 | 軌道 | レーン |
| region | 区域 | 區域 | リージョン |
| playhead | 播放头 | 播放磁頭 | 再生ヘッド |
| bar | 小节 | 小節 | 小節 |
| staff | 谱表 | 譜表 | 譜表 |
| staff space | 谱间距 | 譜間距 | 譜線間隔 |
| engraving | 刻谱 | 刻譜 | 浄書 |
| anchor | 锚点 | 錨點 | アンカー |
| warp | 跳转 | 跳轉 | ワープ |
| tempo map | 速度图 | 速度圖 | テンポマップ |
| caption | 字幕 | 字幕 | 字幕 |
| chapter | 章节 | 章節 | チャプター |
| key (tonality) | 调性 | 調性 | 調 |
| spacer | 间隔 | 間隔 | スペーサー |
| transition | 过渡 | 轉場 | トランジション |
| condensing | 声部合并 | 聲部合併 | コンデンス |
| recording | 录音 | 錄音 | 録音 |

Upload this table to the Crowdin project as its glossary, so translators see it as they work.

## Crowdin

`crowdin.yml` (at the repository's root) says where the template is and where each language's
file goes. Set it up once with either:

- **The GitHub integration** (Crowdin ▸ Integrations ▸ GitHub): choose this repository and
  `main`, and point it at `crowdin.yml`. It uploads `curator.pot` whenever it changes on
  `main`, and opens a pull request (from `l10n_crowdin`) with the translations.
- **The CLI**: set `CROWDIN_PROJECT_ID` and `CROWDIN_PERSONAL_TOKEN`, then `crowdin upload
  sources` and `crowdin download`.

Create the project with English as its source language. Its Simplified and Traditional Chinese
(`zh-CN`, `zh-TW`) are written as `zh-Hans.po` and `zh-Hant.po`, and Japanese (`ja`) as `ja.po`
(`languages_mapping`, keyed by `locale_with_underscore`, the placeholder the file name uses). The first
time, upload the existing ones too (`crowdin upload translations`), so they aren't translated again.

## Adding text (developers)

Write the English in the code: `'Open Sample'.tr`, `'Bar {n}'.fill({'n': 12})`, or
`'Flags'.trIn('page')`. Then:

```bash
make l10n
```

This adds new texts to `curator.pot` and to each `.po` file (empty), refreshes the `#:`
references, and drops texts no longer in the template. Text translated other than as a literal
(an enum's label: `label.tr`) is added to `curator.pot` by hand. `make check` fails while a text
is missing, or while Simplified Chinese, Traditional Chinese or Japanese has an untranslated text.

## Adding a language

Add the language in Crowdin. When its translations arrive, its file is
`app/assets/l10n/<code>.po` (a mapping in `crowdin.yml` if its code needs a variant), and the
app lists it under Settings ▸ General ▸ Language once anything in it is translated: nothing in
the code changes. It is named in its own language from a table in `app/lib/l10n/l10n.dart`
(`_autonyms`), or by its file's `Language-Team` when it isn't there.

The app reads every language's file as it starts. Material's own text (menus, the licence
page) comes from Flutter in the same locale, or in English where Flutter hasn't it.
