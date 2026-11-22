# Embed Control

A page shown in an `<iframe>` of another site is played from that site, and tells it what
happens. The site sends the frame a message:

```js
const player = document.querySelector("iframe").contentWindow;
player.postMessage({ curator: "play" }, "*");
player.postMessage({ curator: "seek", value: 83 }, "*");
```

`curator` is one of `play`, `pause`, `toggle`, `seek` (seconds), `bar` ("12" or "12.3"),
`speed`, `recording` (a number from 0), `shows` ("views", "score", "midi" or "map") and `state`
(asks for the state). The page answers, and says whenever something changes:

```js
addEventListener("message", (event) => {
  if (event.data?.curator === "state") console.log(event.data.playing, event.data.time, event.data.bar);
});
```

A `state` message has `playing`, `time`, `duration`, `speed`, `recording`, `shows` and `bar`
(the bar's number); `{ curator: "ended" }` follows the page's end. While it plays, the time is
told four times a second.

Site, in Export to Web, is the one site that may play the page (`https://example.com`); `*`
lets any.
