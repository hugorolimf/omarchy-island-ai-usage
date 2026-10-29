// Portuguese wording for the agents panel (English systems keep the
// collectors' own words). The collectors
// (omarchy-agent-usage-*) write English status, help and window labels into
// the usage records; they are translated here, at display time, so the
// records stay exactly what the collectors and other tools expect. Anything
// unknown is shown as written.

var english = typeof Qt !== "undefined" && Qt.locale ? Qt.locale().name.indexOf("pt") !== 0 : false

var exactTexts = {
  "Fireworks unavailable": "Fireworks indisponível",
  "Balance unavailable": "Saldo indisponível",
  "Codex unavailable": "Codex indisponível",
  "Codex limits unavailable": "Limites do Codex indisponíveis",
  "Claude limits unavailable": "Limites do Claude indisponíveis",
  "Waiting for auth": "Aguardando login",
  "Sign-in expired": "Login expirado",
  "Run `claude auth login` to restore authoritative usage.": "Rode `claude auth login` para voltar a ver o uso oficial.",
  "Run `codex login` to authenticate.": "Rode `codex login` para entrar.",
  "Set FIREWORKS_API_KEY, run `firectl set-api-key`, or sign in to Fireworks in opencode.":
    "Defina FIREWORKS_API_KEY, rode `firectl set-api-key` ou entre no Fireworks pelo opencode.",
  "codex not found in PATH": "codex não está no PATH",
  "Fireworks usage scan failed": "Falha ao ler o uso do Fireworks",
  "Couldn't reach Anthropic's usage endpoint. Retrying shortly. Local Claude Code stats are still shown.":
    "Não deu para falar com o serviço de uso da Anthropic. Nova tentativa em instantes. Os números locais do Claude Code continuam aqui.",
  "Anthropic's usage endpoint returned no limits. Local Claude Code stats are still shown.":
    "O serviço de uso da Anthropic não mandou limites. Os números locais do Claude Code continuam aqui.",
  "Prepaid": "Pré-pago",
  "Subscription": "Assinatura"
}

function text(raw) {
  var s = String(raw || "")
  if (s === "" || english) return s
  if (exactTexts[s] !== undefined) return exactTexts[s]

  var m = /^Anthropic's usage endpoint is rate limiting checks right now(?: \(retry after (\d+)s\))?\. Local Claude Code stats are still shown\.$/.exec(s)
  if (m) return "A Anthropic está limitando as consultas de uso agora"
    + (m[1] ? " (tente de novo em " + m[1] + " s)" : "")
    + ". Os números locais do Claude Code continuam aqui."
  m = /^Anthropic's usage endpoint returned status (\d+)\. Local Claude Code stats are still shown\.$/.exec(s)
  if (m) return "O serviço de uso da Anthropic respondeu com erro " + m[1] + ". Os números locais do Claude Code continuam aqui."
  m = /^Claude Code's saved sign-in expired( — showing the last known limits)?\. Start Claude Code, or run `claude auth login`, to refresh it\.$/.exec(s)
  if (m) return "O login salvo do Claude Code expirou" + (m[1] ? " (mostrando os últimos limites conhecidos)" : "")
    + ". Abra o Claude Code ou rode `claude auth login` para renovar."
  m = /^(.+) unavailable$/.exec(s)
  if (m) return m[1] + " indisponível"
  return s
}

// Window names. `span` is the window length in ms (0 when unknown).
function windowTitle(title, span) {
  var t = String(title || "")
  var hours = span > 0 && span < 24 * 3600 * 1000 ? Math.round(span / 3600000) : 0
  if (english) return t === "Session" && hours > 0 ? "Session (" + hours + " h)" : t
  if (t === "Monthly") return "Mês"
  if (t === "Weekly") return "Semana"
  if (t === "Session") return hours > 0 ? "Sessão (" + hours + " h)" : "Sessão"
  if (t === "Limit") return "Limite"
  // Model-scoped windows arrive as "<model> Weekly" / "<model> Session".
  var m = /^(.+) (Weekly|Session|Monthly)$/.exec(t)
  if (m) return m[1] + " · " + (m[2] === "Weekly" ? "semana" : m[2] === "Monthly" ? "mês" : "sessão")
  return t
}

// "2d 3h", "2h 10min", "5 min"; "agora" once the moment has passed.
function duration(ms) {
  if (!(ms > 0)) return english ? "now" : "agora"
  var minutes = Math.floor(ms / 60000)
  var hours = Math.floor(minutes / 60)
  var days = Math.floor(hours / 24)
  if (days > 0) return days + "d " + (hours % 24) + "h"
  if (hours > 0) return hours + "h " + (minutes % 60) + "min"
  return Math.max(1, minutes) + " min"
}

// "agora", "há 5 min", "há 2h 10min" for the record's updatedAt.
function updatedAgo(iso, nowMs) {
  var at = new Date(String(iso || "")).getTime()
  if (!isFinite(at)) return ""
  var ms = nowMs - at
  if (ms < 60000) return english ? "now" : "agora"
  return english ? duration(ms) + " ago" : "há " + duration(ms)
}

var shortDays = english ? ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"] : ["DOM", "SEG", "TER", "QUA", "QUI", "SEX", "SÁB"]
var longDays = english ? ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
  : ["domingo", "segunda", "terça", "quarta", "quinta", "sexta", "sábado"]

function dayShort(date) {
  var parsed = new Date(String(date || "") + "T00:00:00")
  if (isNaN(parsed.getTime())) return String(date || "")
  return shortDays[parsed.getDay()]
}

function dayLong(date) {
  var parsed = new Date(String(date || "") + "T00:00:00")
  if (isNaN(parsed.getTime())) return String(date || "")
  return english ? longDays[parsed.getDay()] + " " + (parsed.getMonth() + 1) + "/" + parsed.getDate()
    : longDays[parsed.getDay()] + " " + parsed.getDate() + "/" + (parsed.getMonth() + 1)
}

function plural(n, one, many) {
  return n + " " + (n === 1 ? one : many)
}

if (typeof module !== "undefined") {
  module.exports = {
    text: text,
    windowTitle: windowTitle,
    duration: duration,
    updatedAgo: updatedAgo,
    dayShort: dayShort,
    dayLong: dayLong,
    plural: plural
  }
}
