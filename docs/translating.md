# Translating Curator

Curator's interface is written in US English and translated with [Crowdin](https://crowdin.com).
The translations are gettext files in `app/assets/l10n/`:

| File | What it is |
| --- | --- |
| `curator.pot` | The template: every English text, with the source files using it (`#:`) |
| `zh-Hans.po`, `zh-Hant.po`, … | One language each, named by its locale (BCP 47) |

Each text is its own key: `msgid` is the English exactly as the interface shows it. A
`msgctxt` tells apart one English word that means two things (`page` / `Flags`: the Settings
page, not a note's flags). Keep every `{placeholder}`; where it goes is up to the language.
Text left untranslated shows in English.

## Terms

Use the same word for the same thing throughout.

| English | 简体中文 | 繁體中文 |
| --- | --- | --- |
| score | 乐谱 | 樂譜 |
| project | 项目 | 專案 |
| file | 文件 | 檔案 |
| video | 视频 | 影片 |
| audio | 音频 | 音訊 |
| lane | 轨道 | 軌道 |
| region | 区域 | 區域 |
| playhead | 播放头 | 播放磁頭 |
| bar | 小节 | 小節 |
| staff | 谱表 | 譜表 |
| staff space | 谱间距 | 譜間距 |
| engraving | 刻谱 | 刻譜 |
| anchor | 锚点 | 錨點 |
| warp | 跳转 | 跳轉 |
| tempo map | 速度图 | 速度圖 |
| caption | 字幕 | 字幕 |
| spacer | 间隔 | 間隔 |
| transition | 过渡 | 轉場 |
| condensing | 声部合并 | 聲部合併 |
| recording | 录音 | 錄音 |

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
(`zh-CN`, `zh-TW`) are written as `zh-Hans.po` and `zh-Hant.po` (`languages_mapping`). The first
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
is missing, or while Simplified or Traditional Chinese has an untranslated text.

## Adding a language

1. Add the language in Crowdin. When its translations arrive, its file is
   `app/assets/l10n/<code>.po` (a mapping in `crowdin.yml` if its code needs a variant).
2. Add it to `AppLanguage` (`app/lib/l10n/l10n.dart`) with its name in its own language and its
   locale, whose tag is the file's name: `french('Français', Locale('fr'))`.

The app reads every language's file as it starts. Material's own text (menus, the licence
page) comes from Flutter in the same locale.
