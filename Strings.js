.pragma library

// Texts of this panel: written in Portuguese, English for every other locale.
var english = Qt.locale().name.indexOf("pt") !== 0
var en = {
 " gastos de ": " spent of ",
 " depositados": " funded",
 " · estimativa": " · estimated",
 " · atualizado ": " · updated ",
 "HOJE": "TODAY",
 "Hoje": "Today",
 "sessão": "session",
 "sessões": "sessions",
 "Entrada ": "In ",
 " · saída ": " · out ",
 " · cache lido ": " · cache read ",
 " · cache gravado ": " · cache write ",
 "Somando ": "Adding up ",
 "aparelho": "device",
 "aparelhos": "devices",
 "Atualizar agora (R)": "Refresh now (R)",
 "Abrir um agente": "Open an agent",
 "Nenhuma assinatura de IA encontrada.\\nOs agentes aparecem aqui depois do primeiro uso.": "No AI coding subscriptions found.\\nAgents show up here once you've used them.",
 "SALDO": "BALANCE",
 "Créditos pré-pagos": "Prepaid credits",
 "LIMITES": "LIMITS",
 "TOKENS POR DIA": "TOKENS BY DAY",
 "hoje ": "today ",
 "TOKENS POR MODELO": "TOKENS BY MODEL",
 " · zera em ": " · resets in ",
 "Não deu para criar a pasta de sincronização": "Usage sync mkdir failed",
 "Não deu para ler a pasta de sincronização": "Usage sync scan failed",
 "Desconhecido": "Unknown",
 "CONTAS": "ACCOUNTS",
 "Adicionar conta": "Add account",
 "Adicionar conta do Claude": "Add a Claude account",
 "Entra com outra conta num terminal e guarda como secundária": "Signs in another account in a terminal and saves it as a secondary",
 "Nenhum login salvo ainda.": "No saved logins yet.",
 "Entrar de novo": "Sign in again",
 "Ativa": "Active",
 "Trocando…": "Switching…",
 "Usar": "Use",
 "Usar esta conta": "Use this account",
 " · limites de ": " · limits from ",
 "Conta que o Claude usa agora, em qualquer terminal": "The account Claude uses now, in every terminal",
 "Esquecer este login": "Forget this login"
}

function T(s) { return english && en[s] !== undefined ? en[s] : s }
