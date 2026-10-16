// Small presentational helpers shared by the grid cells. Kept in JS so the
// palette and the label mapping do not live inside the delegate.

var PALETTE = [
  "#6c78c8", "#c86c9a", "#5fae8b", "#c79a4e",
  "#8a6cc8", "#4ea4c7", "#c76c6c", "#7fa65a"
]

function _hash(text) {
  var h = 0
  for (var i = 0; i < text.length; i++) h = (h * 31 + text.charCodeAt(i)) % 997
  return h
}

// A stable colour per app name, so the same app keeps its tile colour.
function iconColor(name) {
  return PALETTE[_hash(String(name || "?")) % PALETTE.length]
}

function targetLabel(target) {
  var t = String(target || "git")
  if (t === "git") return "Git"
  if (t === "gdrive") return "Drive"
  if (t === "none") return "Off"
  return t
}
