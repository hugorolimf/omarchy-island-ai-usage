import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import "../io.github.hugorolimf.kit/ui"
import "Model.js" as Model
import "Strings.js" as Strings

Panel {
  id: root
  moduleName: "io.github.hugorolimf.agents"
  ipcTarget: "omarchy.agents"
  manageIpc: false

  // anatomy tokens: grey structure, colour only for state.
  readonly property color foreground: Anatomy.strong
  readonly property color urgent: Anatomy.red
  readonly property color dim: Anatomy.muted
  readonly property color surface: Anatomy.page
  readonly property color track: Anatomy.faint
  readonly property string fontFamily: Anatomy.sans

  readonly property var providers: usage.enabledProviders
  // The selection follows the provider, not the slot it happens to sit in: a
  // provider whose first scan lands while the panel is open would otherwise
  // shift the list underneath you and swap out what you were reading.
  property string selectedProviderId: ""
  readonly property int providerIndex: {
    for (var i = 0; i < providers.length; i++)
      if (providers[i].providerId === selectedProviderId) return i
    return 0
  }
  readonly property var provider: providers.length > 0 ? providers[providerIndex] : null

  property bool cursorActive: false

  // Countdowns and "updated" read this instead of Date.now() so the
  // panel keeps telling the truth while it sits open.
  property double nowMs: Date.now()

  readonly property var limits: limitWindows(provider)
  readonly property var models: modelRows(provider)
  readonly property var headline: bindingWindow(provider)
  readonly property var balance: provider ? (provider.balance || null) : null
  // A prepaid account runs low the way a subscription window fills up: the
  // last 10% of the funded credits lights the same alarm.
  readonly property bool balanceAlarming: !!balance && balance.funded > 0
    && balance.remaining / balance.funded <= 0.1
  readonly property bool alarming: (!!headline && headline.percent >= 0.9) || balanceAlarming

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }
  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  function selectProvider(index) {
    if (providers.length === 0) return
    var wrapped = ((index % providers.length) + providers.length) % providers.length
    selectedProviderId = providers[wrapped].providerId
  }

  function refreshNow() {
    usage.refreshAll(true)
  }

  function launchAgent() {
    if (root.bar) root.bar.run("omarchy-agent --pick")
    root.close()
  }

  // ---------------------------------------------------------------- limits
  //
  // Both providers report the same two shapes: a short rolling session window
  // and a long weekly one. Everything below normalizes them into one record so
  // the meters and the hero speak a single language.

  // Claude spells its windows out ("Session (5-hour)"), Codex abbreviates
  // them ("5h window", "30m window"). Both have to land on the same record.
  function windowIsLong(text) {
    return text.indexOf("week") >= 0 || text.indexOf("7-day") >= 0 || text.indexOf("seven") >= 0
      || text.indexOf("month") >= 0 || text.indexOf("30-day") >= 0
  }

  function windowSpanMs(label) {
    var text = String(label || "").toLowerCase()
    if (text.indexOf("month") >= 0 || text.indexOf("30-day") >= 0) return 30 * 24 * 3600 * 1000
    if (windowIsLong(text)) return 7 * 24 * 3600 * 1000
    var hours = text.match(/(\d+)\s*-?\s*h(?:our)?\b/)
    if (hours) return Number(hours[1]) * 3600 * 1000
    var minutes = text.match(/(\d+)\s*-?\s*m(?:in(?:ute)?s?)?\b/)
    if (minutes) return Number(minutes[1]) * 60 * 1000
    return 0
  }

  function windowTitle(label) {
    var text = String(label || "").toLowerCase()
    if (text.indexOf("month") >= 0) return "Monthly"
    if (windowIsLong(text)) return "Weekly"
    if (text.indexOf("session") >= 0 || windowSpanMs(label) > 0) return "Session"
    var plain = String(label || "").replace(/\s*\(.*\)\s*/, "").trim()
    return plain === "" ? "Limit" : plain
  }

  // A collector that already knows which window a limit belongs to says so,
  // and that beats reading it back out of the label: a model-scoped limit is
  // titled after its model, and a name like "Opus 5 (1M context)" would parse
  // as a one-minute window.
  function limitWindow(label, percent, resetAt, title) {
    var reset = new Date(String(resetAt || "")).getTime()
    var expired = isFinite(reset) && reset <= root.nowMs
    return {
      title: Model.windowTitle(String(title || "") !== "" ? String(title) : windowTitle(label), windowSpanMs(label)),
      percent: expired ? 0 : Number(percent),
      resetAt: expired ? "" : String(resetAt || "")
    }
  }

  function limitWindows(p) {
    if (!p) return []
    var out = []
    var list = p.limits || []
    for (var i = 0; i < list.length; i++) {
      var entry = list[i] || {}
      var percent = Number(entry.percent)
      if (percent >= 0) out.push(limitWindow(entry.label, percent, entry.resetsAt, entry.title))
    }
    return out
  }

  // The window that decides how much room is left — the fullest one, since
  // that is what stops the next prompt.
  function bindingWindow(p) {
    var windows = limitWindows(p)
    var best = null
    for (var i = 0; i < windows.length; i++) {
      if (!best || windows[i].percent > best.percent) best = windows[i]
    }
    return best
  }

  function resetMsFor(w) {
    if (!w || w.resetAt === "") return -1
    var ms = new Date(w.resetAt).getTime()
    return isFinite(ms) ? ms - root.nowMs : -1
  }

  function formatDuration(ms) {
    return Model.duration(ms)
  }

  // State tone of a window: amber from 70%, red from 90% (same as Island Bar).
  function limitColor(percent) {
    if (percent >= 0.9) return Anatomy.red
    if (percent >= 0.7) return Anatomy.amber
    return Anatomy.hi
  }

  // ---------------------------------------------------------------- balance
  //
  // Prepaid agents report a credit ledger instead of rate-limit windows: the
  // record's balance object carries remaining, funded, and spent amounts.

  function currencyPrefix(currency) {
    var code = String(currency || "USD").toUpperCase()
    if (code === "USD") return "$"
    if (code === "EUR") return "€"
    if (code === "GBP") return "£"
    return code + " "
  }

  function formatMoney(value, currency) {
    var amount = Number(value)
    if (!isFinite(amount)) amount = 0
    return currencyPrefix(currency) + amount.toFixed(2).replace(".", ",")
  }

  function balanceDetailText(b) {
    if (!b || !(b.funded > 0)) return ""
    var text = formatMoney(b.spent, b.currency) + Strings.T(" gastos de ") + formatMoney(b.funded, b.currency) + Strings.T(" depositados")
    if (b.estimated) text += Strings.T(" · estimativa")
    return text
  }

  // ---------------------------------------------------------------- content

  // The plan you pay for, under the name of the tool it pays for. Limits live
  // in their own section; the hero just says what this is.
  function heroMeta(p) {
    if (!p) return ""
    var ago = Model.updatedAgo(p.updatedAt, root.nowMs)
    var tail = ago === "" ? "" : Strings.T(" · atualizado ") + ago
    if (String(p.usageStatusText || "") !== "") return Model.text(p.usageStatusText) + tail
    var tier = String(p.tierLabel || "")
    if (tier === "") return "Assinatura" + tail
    return Model.text(tier.charAt(0).toUpperCase() + tier.slice(1)) + tail
  }

  // Local calendar date, recomputed from nowMs so a panel left open across
  // midnight moves the "Today" row with the clock.
  function todayDate() {
    var now = new Date(root.nowMs)
    return now.getFullYear()
      + "-" + String(now.getMonth() + 1).padStart(2, "0")
      + "-" + String(now.getDate()).padStart(2, "0")
  }

  function dayName(date) {
    return Model.dayShort(date)
  }

  function dayLabel(date, today) {
    if (today) return Strings.T("HOJE")
    return dayName(date)
  }

  function dayTooltip(day, today) {
    if (!day) return ""
    var label = today ? Strings.T("Hoje") : Model.dayLong(day.date)
    var text = label + " · " + usage.formatTokenCount(Number(day.messageCount || 0)) + " tokens"
    // Prompt and session counts only exist for today, so they ride along here
    // instead of taking a section of their own. Billing-API agents never
    // count prompts, and "0 prompts" would read as a quiet day, not a gap.
    if (today && provider && provider.hasPromptStats !== false)
      text += " · " + Model.plural(Number(provider.todayPrompts || 0), "prompt", "prompts") + " · "
        + Model.plural(Number(provider.todaySessions || 0), Strings.T("sessão"), Strings.T("sessões"))
    return text
  }

  function weekPeak(p) {
    var days = p ? (p.recentDays || []) : []
    var peak = 0
    for (var i = 0; i < days.length; i++) peak = Math.max(peak, Number(days[i].messageCount || 0))
    return peak
  }

  function modelRows(p) {
    var usageByModel = p ? (p.modelUsage || {}) : {}
    var rows = []
    for (var id in usageByModel) {
      var bucket = usageByModel[id] || {}
      var input = Number(bucket.inputTokens || 0)
      var output = Number(bucket.outputTokens || 0)
      var cacheRead = Number(bucket.cacheReadInputTokens || 0)
      var cacheWrite = Number(bucket.cacheCreationInputTokens || 0)
      rows.push({
        name: usage.friendlyModelName(id),
        total: input + output + cacheRead + cacheWrite,
        input: input,
        output: output,
        cacheRead: cacheRead,
        cacheWrite: cacheWrite
      })
    }
    rows.sort(function(a, b) { return b.total - a.total })
    return rows.slice(0, 4)
  }

  function modelTooltip(row) {
    if (!row) return ""
    return Strings.T("Entrada ") + usage.formatTokenCount(row.input)
      + Strings.T(" · saída ") + usage.formatTokenCount(row.output)
      + Strings.T(" · cache lido ") + usage.formatTokenCount(row.cacheRead)
      + Strings.T(" · cache gravado ") + usage.formatTokenCount(row.cacheWrite)
  }

  // Only speaks up when the numbers cover more than this machine.
  function footerText() {
    if (usage.syncStatusText !== "") return usage.syncStatusText
    if (provider && provider.syncEnabled && provider.syncDeviceCount > 0)
      return Strings.T("Somando ") + Model.plural(provider.syncDeviceCount, Strings.T("aparelho"), Strings.T("aparelhos"))
    return ""
  }

  // Agents that ship a white mark carry an `assets/<id>-light.svg` twin for
  // light surfaces; marks that work on both (Claude's brand-orange) ship one
  // file. The luminance check decides which candidate to try first.
  function colorChannelLuminance(value) {
    var channel = Number(value)
    if (!isFinite(channel)) return 0
    return channel <= 0.03928 ? channel / 12.92 : Math.pow((channel + 0.055) / 1.055, 2.4)
  }

  function colorLuminance(color) {
    return 0.2126 * colorChannelLuminance(color.r)
      + 0.7152 * colorChannelLuminance(color.g)
      + 0.0722 * colorChannelLuminance(color.b)
  }

  // Marks resolve by convention, so a new agent's data file needs nothing
  // from this panel: assets/<id>.svg if it ships one, the module's bar glyph
  // if it doesn't.
  function iconCandidatesForProvider(p, surfaceColor) {
    if (!p) return []
    var candidates = []
    if (colorLuminance(surfaceColor || Commons.Color.background) >= 0.5)
      candidates.push(Qt.resolvedUrl("assets/" + p.providerId + "-light.svg"))
    candidates.push(Qt.resolvedUrl("assets/" + p.providerId + ".svg"))
    return candidates
  }

  // Nothing to report, nothing in the bar: Bar.qml collapses a slot whose item
  // is invisible, so the icon appears the moment the first scan finds usage and
  // stays away entirely on a machine that has never run either CLI.
  visible: providers.length > 0
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onProviderIndexChanged: if (panelFlick) panelFlick.contentY = 0
  onOpenedChanged: if (opened) {
    cursorActive = false
    nowMs = Date.now()
    if (panelFlick) panelFlick.contentY = 0
    usage.refreshLimits()
    root.refreshAccounts()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Main {
    id: usage
    settings: root.settings
  }

  // --------------------------------------------------------------- accounts
  //
  // Saved Claude logins (accounts.py). The active one is the login Claude
  // Code itself uses, so its meters are the LIMITES above; the others list
  // under it with their last known limits, one click from taking its place.

  readonly property bool isClaude: !!provider && provider.providerId === "claude"
  readonly property string accountsScript: Qt.resolvedUrl("accounts.py").toString().replace(/^file:\/\//, "")
  property var claudeAccounts: []
  property string accountBusy: ""
  property string accountMessage: ""

  // Stroke icons this panel needs that the kit does not ship (24-unit grid).
  readonly property string iconPlus: "M12 5v14M5 12h14"
  readonly property string iconPerson: "M12 11.5a3.75 3.75 0 1 0 0-7.5 3.75 3.75 0 0 0 0 7.5zM4.5 20a7.5 7.5 0 0 1 15 0"

  function refreshAccounts() {
    if (!accountsStatus.running) accountsStatus.running = true
  }

  function runAccountAction(args, busyId) {
    if (accountsAction.running) return
    accountBusy = busyId
    accountMessage = ""
    accountsAction.command = ["python3", "-I", accountsScript].concat(args)
    accountsAction.running = true
  }

  function switchAccount(id) { runAccountAction(["switch", id], id) }
  function removeAccount(id) { runAccountAction(["remove", id], id) }

  function addAccount() {
    Quickshell.execDetached(["uwsm-app", "--", "xdg-terminal-exec", "--app-id=org.omarchy.terminal",
                             "--title=" + Strings.T("Adicionar conta do Claude"), "-e",
                             "python3", "-I", accountsScript, "add"])
    root.close()
  }

  // "Sessão 12% · Semanal 40%": a saved account's last reading, in the same
  // window names the meters above use.
  function accountSummary(account) {
    if (!account) return ""
    if (account.needsSignIn) return Strings.T("Entrar de novo")
    var parts = []
    if (account.active) parts.push(Strings.T("Ativa"))
    if (String(account.plan || "") !== "") parts.push(Model.text(account.plan))
    // The active account's meters are the LIMITES section right above.
    if (account.active) return parts.join(" · ")
    var windows = limitWindows({ limits: account.limits || [] })
    for (var i = 0; i < windows.length && i < 2; i++)
      parts.push(windows[i].title + " " + Math.round(windows[i].percent * 100) + "%")
    return parts.join(" · ")
  }

  function accountTooltip(account) {
    if (!account) return ""
    if (account.active) return Strings.T("Conta que o Claude usa agora, em qualquer terminal")
    var text = Strings.T("Usar esta conta")
    var ago = Model.updatedAgo(account.limitsAt, root.nowMs)
    if (ago !== "" && !account.needsSignIn) text += Strings.T(" · limites de ") + ago
    return text
  }

  // A login finished in the terminal, or a switch made elsewhere, shows up
  // while the panel is open.
  Timer {
    interval: 4000
    running: root.opened && root.isClaude
    repeat: true
    onTriggered: root.refreshAccounts()
  }

  Process {
    id: accountsStatus
    command: ["python3", "-I", root.accountsScript, "status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var data = JSON.parse(text)
          if (data && data.ok) root.claudeAccounts = data.accounts || []
        } catch (e) {}
      }
    }
  }

  Process {
    id: accountsAction
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var data = JSON.parse(text)
          root.accountMessage = data.ok ? "" : String(data.error || "")
        } catch (e) {}
      }
    }
    onExited: {
      root.accountBusy = ""
      root.refreshAccounts()
    }
  }

  // Cheap enough to keep running: it only re-evaluates text bindings, and a
  // stale "resets in 2h" on a panel that is open is worse than a timer.
  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refreshNow(); return "ok" }
    function next(): string { root.selectProvider(root.providerIndex + 1); return "ok" }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󱚣"
    active: root.alarming
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.launchAgent()
      else if (buttonCode === Qt.MiddleButton) root.selectProvider(root.providerIndex + 1)
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    // Taller than the control panels on purpose: this one is a dashboard, and
    // the whole point is reading limits and history without scrolling.
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) {
        if (dx !== 0) {
          root.cursorActive = true
          root.selectProvider(root.providerIndex + dx)
        }
        if (dy !== 0)
          panelFlick.contentY = root.clamp(panelFlick.contentY + dy * Style.space(56), 0,
                                           Math.max(0, panelFlick.contentHeight - panelFlick.height))
      }
      onActivateRequested: root.refreshNow()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) { if (t === "r" || t === "R") root.refreshNow() }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          // ---------- Hero: provider mark · name · plan · refresh / open ----------
          PanelHero {
            id: hero
            visible: !!root.provider
            width: parent.width
            title: root.provider ? root.provider.providerName : ""
            meta: root.heroMeta(root.provider)
            foreground: root.foreground
            fontFamily: root.fontFamily

            iconComponent: Component {
              Item {
                id: heroMark
                property var candidates: root.iconCandidatesForProvider(root.provider, root.surface)
                // Provider objects are rebuilt on every refresh, which churns the
                // array's identity without changing its content. Restart the fallback
                // walk only when the URLs change: re-pointing source at a URL whose
                // load already failed emits no statusChanged, so an identity-only
                // reset would strand the walker on a missing -light twin.
                property string candidatesKey: candidates.join("\n")
                property int candidateIndex: 0
                onCandidatesKeyChanged: candidateIndex = 0

                width: Style.font.display
                height: Style.font.display

                Image {
                  id: heroMarkImage
                  anchors.fill: parent
                  source: heroMark.candidateIndex < heroMark.candidates.length ? heroMark.candidates[heroMark.candidateIndex] : ""
                  sourceSize.width: Style.font.display * 2
                  sourceSize.height: Style.font.display * 2
                  fillMode: Image.PreserveAspectFit
                  // Advancing source from inside its own status change trips the
                  // binding-loop detector; defer the step one tick.
                  onStatusChanged: if (status === Image.Error && heroMark.candidateIndex < heroMark.candidates.length)
                    Qt.callLater(function() { heroMark.candidateIndex++ })
                }

                // No mark shipped: the anatomy sparkle (the bar's AI icon).
                AnatomyIcon {
                  anchors.centerIn: parent
                  visible: heroMarkImage.status !== Image.Ready
                  path: Anatomy.icons.sparkle
                  size: Style.font.display
                  strokeWidth: 1.3
                  color: Anatomy.hi
                }
              }
            }

            trailingControl: Component {
              Row {
                spacing: Style.space(2)

                PanelActionButton {
                  tooltipText: Strings.T("Atualizar agora (R)")
                  onClicked: root.refreshNow()

                  AnatomyIcon {
                    anchors.centerIn: parent
                    path: Anatomy.icons.refresh
                    size: Style.font.subtitle
                    color: usage.updating ? Anatomy.blue : Anatomy.hi

                    RotationAnimator on rotation {
                      running: usage.updating
                      from: 0; to: 360
                      duration: 900
                      loops: Animation.Infinite
                      // Finish the turn when the run ends so the icon rests upright.
                      alwaysRunToEnd: true
                    }
                  }
                }

                PanelActionButton {
                  tooltipText: Strings.T("Abrir um agente")
                  onClicked: root.launchAgent()

                  AnatomyIcon {
                    anchors.centerIn: parent
                    path: Anatomy.icons.terminal
                    size: Style.font.subtitle
                    color: Anatomy.hi
                  }
                }
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: root.providers.length === 0
            width: parent.width
            topPadding: Style.space(24)
            text: Strings.T("Nenhuma assinatura de IA encontrada.\nOs agentes aparecem aqui depois do primeiro uso.")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }

          // ---------- Provider switch (anatomy .seg) ----------
          Rectangle {
            visible: root.providers.length > 1
            width: parent.width
            implicitHeight: providerSwitch.implicitHeight + 4
            radius: Anatomy.rowRadius
            color: Anatomy.faint

            Row {
              id: providerSwitch
              x: 2
              y: 2
              width: parent.width - 4
              spacing: 2

              readonly property real cellWidth: root.providers.length > 0
                ? (width - spacing * (root.providers.length - 1)) / root.providers.length
                : 0

              Repeater {
                model: root.providers

                BorderSurface {
                  id: chip
                  required property var modelData
                  required property int index

                  readonly property bool isSelected: index === root.providerIndex
                  readonly property bool hasCursor: chipMouse.containsMouse || (root.cursorActive && isSelected)

                  width: providerSwitch.cellWidth
                  implicitHeight: chipLabel.implicitHeight + Style.space(12)
                  radius: Anatomy.chipRadius
                  color: isSelected ? Anatomy.card : (chipMouse.containsMouse ? Anatomy.hover : "transparent")
                  borderSpec: Border.none()
                  border.width: root.cursorActive && isSelected ? Anatomy.hairline : 0
                  border.color: Anatomy.selectedRim

                  Behavior on color { ColorAnimation { duration: Anatomy.fast; easing.type: Easing.Bezier; easing.bezierCurve: Anatomy.ease } }

                  AnatomyLift { visible: chip.isSelected; radius: chip.radius; depth: 3 }
                  AnatomyLift { visible: chip.isSelected; radius: chip.radius; inner: true }

                  Text {
                    id: chipLabel
                    textFormat: Text.PlainText
                    anchors.centerIn: parent
                    width: parent.width - Style.space(6)
                    horizontalAlignment: Text.AlignHCenter
                    elide: Text.ElideRight
                    text: chip.modelData.providerName
                    color: chip.isSelected || chip.hasCursor ? Anatomy.strong : Anatomy.muted
                    font.family: Anatomy.mono
                    font.pixelSize: Math.max(9, Style.font.caption)
                    font.weight: Font.Medium
                    font.letterSpacing: 0.5
                    font.capitalization: Font.AllUppercase
                  }

                  MouseArea {
                    id: chipMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                      root.cursorActive = true
                      root.selectProvider(chip.index)
                    }
                  }
                }
              }
            }
          }

          // ---------- Status ----------
          BorderSurface {
            visible: !!root.provider && String(root.provider.usageStatusText || "") !== ""
            width: parent.width
            implicitHeight: statusText.implicitHeight + Style.spacing.xl * 2
            color: Anatomy.urgentFill
            borderSpec: Border.none()
            border.width: Anatomy.hairline
            border.color: Anatomy.alpha(Anatomy.red, 0.35)
            radius: Anatomy.cardRadius

            Text {
              id: statusText
              textFormat: Text.PlainText
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(12)
              anchors.rightMargin: Style.space(12)
              text: root.provider ? Model.text(root.provider.authHelpText) : ""
              color: Anatomy.text
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }
          }

          // ---------- Balance / limits ----------
          PanelSeparator {
            visible: balanceSection.visible || limitsSection.visible
            foreground: root.foreground
          }

          Column {
            id: balanceSection
            visible: !!root.balance
            width: parent.width
            spacing: Style.space(10)

            // The meter shows what is left, not what is used: a prepaid
            // account drains toward empty rather than filling toward a cap.
            readonly property real ratio: root.balance && root.balance.funded > 0
              ? root.clamp(root.balance.remaining / root.balance.funded, 0, 1)
              : -1

            PanelSectionHeader {
              width: parent.width
              text: Strings.T("SALDO")
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Item {
              width: parent.width
              implicitHeight: Math.max(balanceLabel.implicitHeight, balanceValue.implicitHeight)

              Text {
                id: balanceLabel
                textFormat: Text.PlainText
                text: Strings.T("Créditos pré-pagos")
                color: Anatomy.text
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: balanceValue
                textFormat: Text.PlainText
                text: root.balance ? root.formatMoney(root.balance.remaining, root.balance.currency) : ""
                color: root.balanceAlarming ? Anatomy.red : Anatomy.strong
                font.family: Anatomy.mono
                font.pixelSize: Style.font.bodySmall
                font.weight: Font.Medium
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Meter {
              visible: balanceSection.ratio >= 0
              width: parent.width
              value: balanceSection.ratio
              fill: root.balanceAlarming ? Anatomy.red : Anatomy.hi
            }

            Text {
              textFormat: Text.PlainText
              visible: text !== ""
              width: parent.width
              text: root.balanceDetailText(root.balance)
              color: root.dim
              font.family: Anatomy.mono
              font.pixelSize: Style.font.caption
            }
          }

          Column {
            id: limitsSection
            visible: root.limits.length > 0
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: Strings.T("LIMITES")
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.limits

              LimitRow {
                required property var modelData
                width: limitsSection.width
                window: modelData
              }
            }
          }

          // ---------- Accounts (Claude) ----------
          PanelSeparator {
            visible: accountsSection.visible
            foreground: root.foreground
          }

          Column {
            id: accountsSection
            visible: root.isClaude
            width: parent.width
            spacing: Style.space(6)

            Item {
              width: parent.width
              implicitHeight: Math.max(accountsHeader.implicitHeight, addAccountButton.implicitHeight)

              PanelSectionHeader {
                id: accountsHeader
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: Strings.T("CONTAS")
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              // anatomy chip: mono caps label, washes on hover.
              BorderSurface {
                id: addAccountButton
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                implicitWidth: addAccountRow.implicitWidth + Style.space(14)
                implicitHeight: addAccountRow.implicitHeight + Style.space(8)
                radius: Anatomy.chipRadius
                color: addAccountMouse.containsMouse ? Anatomy.hover : Anatomy.faint
                borderSpec: Border.none()

                Behavior on color { ColorAnimation { duration: Anatomy.fast } }

                Row {
                  id: addAccountRow
                  anchors.centerIn: parent
                  spacing: Style.space(5)

                  AnatomyIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    path: root.iconPlus
                    size: Style.font.caption + 2
                    color: addAccountMouse.containsMouse ? Anatomy.strong : Anatomy.hi
                  }

                  Text {
                    textFormat: Text.PlainText
                    anchors.verticalCenter: parent.verticalCenter
                    text: Strings.T("Adicionar conta")
                    color: addAccountMouse.containsMouse ? Anatomy.strong : Anatomy.text
                    font.family: Anatomy.mono
                    font.pixelSize: Math.max(9, Style.font.caption)
                    font.weight: Font.Medium
                    font.letterSpacing: 0.5
                    font.capitalization: Font.AllUppercase
                  }
                }

                MouseArea {
                  id: addAccountMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.addAccount()
                }

                PanelToolTip {
                  visible: addAccountMouse.containsMouse
                  text: Strings.T("Entra com outra conta num terminal e guarda como secundária")
                  fontFamily: root.fontFamily
                }
              }
            }

            Repeater {
              model: root.claudeAccounts

              AccountRow {
                required property var modelData
                width: accountsSection.width
                account: modelData
              }
            }

            Text {
              textFormat: Text.PlainText
              visible: text !== ""
              width: parent.width
              text: root.accountMessage !== "" ? root.accountMessage
                : (root.claudeAccounts.length === 0 ? Strings.T("Nenhum login salvo ainda.") : "")
              color: root.accountMessage !== "" ? Anatomy.red : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }
          }

          // ---------- Usage ----------
          PanelSeparator {
            visible: usageSection.visible
            foreground: root.foreground
          }

          Column {
            id: usageSection
            visible: !!root.provider && root.provider.recentDays && root.provider.recentDays.length > 0
            width: parent.width
            spacing: Style.space(8)

            readonly property var days: root.provider ? (root.provider.recentDays || []) : []
            readonly property real peak: Math.max(1, root.weekPeak(root.provider))
            readonly property var todayEntry: {
              var key = root.todayDate()
              for (var i = 0; i < days.length; i++) if (String(days[i].date || "") === key) return days[i]
              return null
            }

            Item {
              width: parent.width
              implicitHeight: usageHeader.implicitHeight

              PanelSectionHeader {
                id: usageHeader
                anchors.left: parent.left
                text: Strings.T("TOKENS POR DIA")
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Text {
                textFormat: Text.PlainText
                visible: !!usageSection.todayEntry
                anchors.right: parent.right
                anchors.verticalCenter: usageHeader.verticalCenter
                text: Strings.T("hoje ") + usage.formatTokenCount(usageSection.todayEntry ? Number(usageSection.todayEntry.messageCount || 0) : 0)
                color: Anatomy.strong
                font.family: Anatomy.mono
                font.pixelSize: Style.font.bodySmall
                font.weight: Font.Medium
              }
            }

            // One bar per day, scaled to the busiest one; today in the
            // bright stroke tone. Hover a bar for its tokens (and, today,
            // prompts and sessions).
            Row {
              id: dayBars
              width: parent.width
              spacing: Style.space(4)

              readonly property real cellWidth: usageSection.days.length > 0
                ? (width - spacing * (usageSection.days.length - 1)) / usageSection.days.length
                : 0

              Repeater {
                model: usageSection.days

                DayBar {
                  required property var modelData
                  width: dayBars.cellWidth
                  day: modelData
                  ratio: Number(modelData.messageCount || 0) / usageSection.peak
                  // By date, not by position: the Claude stats-cache fallback can
                  // hand us a window that stops short of today.
                  today: String(modelData.date || "") === root.todayDate()
                }
              }
            }
          }

          // ---------- Models ----------
          PanelSeparator {
            visible: modelSection.visible
            foreground: root.foreground
          }

          Column {
            id: modelSection
            visible: root.models.length > 0
            width: parent.width
            spacing: Style.spacing.md

            PanelSectionHeader {
              width: parent.width
              text: Strings.T("TOKENS POR MODELO")
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.models

              ModelRow {
                required property var modelData
                width: modelSection.width
                row: modelData
                // Scaled to the heaviest model, so the top row is always full —
                // the same scale-to-peak the weekly chart uses for its busiest day.
                share: modelData.total / Math.max(1, root.models[0].total)
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: text !== ""
            width: parent.width
            topPadding: Style.space(2)
            text: root.footerText()
            color: root.dim
            font.family: Anatomy.mono
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
          }
        }
      }
    }
  }

  // A limit window: title on the left, "46% · zera em 2h 10min" on the
  // right, and the meter under them (amber from 70%, red from 90%).
  component LimitRow: Column {
    id: limitRow
    property var window: null

    readonly property real percent: window && window.percent >= 0 ? window.percent : -1

    spacing: Style.space(6)

    Item {
      width: parent.width
      implicitHeight: Math.max(limitLabel.implicitHeight, limitValue.implicitHeight)

      Text {
        id: limitLabel
        textFormat: Text.PlainText
        // A model-scoped window is titled after its model, and those names run
        // long enough to reach the percentage, so the title gives way first.
        text: limitRow.window ? limitRow.window.title : ""
        color: Anatomy.text
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
        anchors.left: parent.left
        anchors.right: limitValue.left
        anchors.rightMargin: Style.spacing.sm
        anchors.verticalCenter: parent.verticalCenter
      }

      Row {
        id: limitValue
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: 0

        Text {
          textFormat: Text.PlainText
          text: limitRow.percent >= 0 ? Math.round(limitRow.percent * 100) + "%" : "—"
          color: limitRow.percent >= 0.7 ? root.limitColor(limitRow.percent) : Anatomy.strong
          font.family: Anatomy.mono
          font.pixelSize: Style.font.bodySmall
          font.weight: Font.Medium
        }

        Text {
          textFormat: Text.PlainText
          text: {
            var remainingMs = root.resetMsFor(limitRow.window)
            return remainingMs > 0 ? Strings.T(" · zera em ") + root.formatDuration(remainingMs) : ""
          }
          color: Anatomy.muted
          font.family: Anatomy.mono
          font.pixelSize: Style.font.bodySmall
        }
      }
    }

    Meter {
      width: parent.width
      value: limitRow.percent
      fill: root.limitColor(limitRow.percent)
    }
  }

  // A saved login. The active one sits first in the blue "current" tint; a
  // secondary switches in on click, and offers USAR / forget on hover.
  component AccountRow: CursorSurface {
    id: accountRow
    property var account: null

    readonly property bool isActive: !!account && account.active === true
    readonly property bool busy: !!account && root.accountBusy === account.id
    readonly property bool hot: accountMouse.containsMouse || useButton.hovering || forgetButton._hot

    current: isActive
    hasCursor: hot && !isActive
    foreground: Anatomy.text
    implicitHeight: accountContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      id: accountMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: accountRow.isActive ? Qt.ArrowCursor : Qt.PointingHandCursor
      onClicked: if (!accountRow.isActive && !accountRow.busy) root.switchAccount(accountRow.account.id)
    }

    PanelToolTip {
      visible: accountMouse.containsMouse
      text: root.accountTooltip(accountRow.account)
      fontFamily: root.fontFamily
    }

    Item {
      id: accountContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(8)
      implicitHeight: Math.max(accountIcon.implicitHeight, accountInfo.implicitHeight, useButton.implicitHeight)

      AnatomyIcon {
        id: accountIcon
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        path: root.iconPerson
        size: Style.font.heading
        color: accountRow.isActive ? Anatomy.blue : Anatomy.hi
      }

      Column {
        id: accountInfo
        spacing: Style.space(1)
        anchors.left: accountIcon.right
        anchors.leftMargin: Style.space(10)
        anchors.right: actions.visible ? actions.left : parent.right
        anchors.rightMargin: actions.visible ? Style.space(8) : 0
        anchors.verticalCenter: parent.verticalCenter

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: accountRow.account ? (accountRow.account.name || accountRow.account.email) : ""
          color: accountRow.isActive || accountRow.hot ? Anatomy.strong : Anatomy.text
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.weight: accountRow.isActive ? Font.Medium : Font.Normal
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: (accountRow.busy ? (accountRow.isActive ? "" : Strings.T("Trocando…")) : root.accountSummary(accountRow.account)).toUpperCase()
          color: accountRow.account && accountRow.account.needsSignIn ? Anatomy.amber
            : (accountRow.isActive ? Anatomy.blue : Anatomy.muted)
          font.family: Anatomy.mono
          font.pixelSize: Style.font.caption
          font.letterSpacing: Anatomy.labelSpacing / 2
          elide: Text.ElideRight
        }
      }

      Row {
        id: actions
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(4)
        visible: !accountRow.isActive && !accountRow.busy && accountRow.hot

        BorderSurface {
          id: useButton
          property bool hovering: useMouse.containsMouse
          anchors.verticalCenter: parent.verticalCenter
          implicitWidth: useLabel.implicitWidth + Style.space(14)
          implicitHeight: useLabel.implicitHeight + Style.space(8)
          radius: Anatomy.chipRadius
          color: useMouse.containsMouse ? Anatomy.alpha(Anatomy.blue, 0.22) : Anatomy.faint
          borderSpec: Border.none()

          Text {
            id: useLabel
            textFormat: Text.PlainText
            anchors.centerIn: parent
            text: Strings.T("Usar")
            color: useMouse.containsMouse ? Anatomy.strong : Anatomy.text
            font.family: Anatomy.mono
            font.pixelSize: Math.max(9, Style.font.caption)
            font.weight: Font.Medium
            font.letterSpacing: 0.5
            font.capitalization: Font.AllUppercase
          }

          MouseArea {
            id: useMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.switchAccount(accountRow.account.id)
          }
        }

        PanelActionButton {
          id: forgetButton
          anchors.verticalCenter: parent.verticalCenter
          tooltipText: Strings.T("Esquecer este login")
          foreground: Anatomy.mid
          hoverColor: Anatomy.red
          fontFamily: Anatomy.sans
          onClicked: root.removeAccount(accountRow.account.id)

          AnatomyIcon {
            anchors.centerIn: parent
            path: Anatomy.icons.close
            size: Style.font.subtitle
            color: forgetButton._hot ? Anatomy.red : Anatomy.mid
          }
        }
      }
    }
  }

  // anatomy track: 4 px faint rail, fill in the stroke tone or a state colour.
  component Meter: Item {
    id: meter
    property real value: -1
    property color fill: Anatomy.hi

    implicitHeight: Anatomy.trackHeight

    Rectangle {
      id: meterTrack
      anchors.fill: parent
      radius: height / 2
      color: root.track
    }

    Rectangle {
      anchors.left: meterTrack.left
      anchors.verticalCenter: meterTrack.verticalCenter
      height: meterTrack.height
      radius: meterTrack.radius
      width: meterTrack.width * root.clamp(meter.value, 0, 1)
      color: meter.fill

      Behavior on width {
        NumberAnimation { duration: Anatomy.base; easing.type: Easing.Bezier; easing.bezierCurve: Anatomy.ease }
      }
      Behavior on color { ColorAnimation { duration: Anatomy.fast } }
    }
  }

  // One column of the week chart: the bar grows up from the baseline and
  // the day sits under it. Today is picked out in the bright tone so the
  // week reads as a run-up to right now.
  component DayBar: Item {
    id: dayBar
    property var day: null
    property real ratio: 0
    property bool today: false

    readonly property real barArea: Style.space(44)

    implicitHeight: barArea + Style.space(6) + dayLabel.implicitHeight

    Rectangle {
      anchors.bottom: parent.bottom
      anchors.bottomMargin: dayLabel.implicitHeight + Style.space(6)
      anchors.horizontalCenter: parent.horizontalCenter
      width: Math.min(parent.width, Style.space(26))
      height: Math.max(2, dayBar.barArea * root.clamp(dayBar.ratio, 0, 1))
      radius: 2
      color: dayHover.containsMouse ? Anatomy.strong : (dayBar.today ? Anatomy.hi : Anatomy.lo)

      Behavior on height {
        NumberAnimation { duration: Anatomy.base; easing.type: Easing.Bezier; easing.bezierCurve: Anatomy.ease }
      }
      Behavior on color { ColorAnimation { duration: Anatomy.fast } }
    }

    Text {
      id: dayLabel
      textFormat: Text.PlainText
      anchors.bottom: parent.bottom
      anchors.horizontalCenter: parent.horizontalCenter
      text: root.dayLabel(dayBar.day ? dayBar.day.date : "", dayBar.today)
      color: dayBar.today ? Anatomy.strong : Anatomy.muted
      font.family: Anatomy.mono
      font.pixelSize: Math.max(9, Style.font.caption - 1)
      font.weight: dayBar.today ? Font.DemiBold : Font.Normal
      font.letterSpacing: 0.5
    }

    MouseArea {
      id: dayHover
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
    }

    PanelToolTip {
      visible: dayHover.containsMouse
      text: root.dayTooltip(dayBar.day, dayBar.today)
      fontFamily: root.fontFamily
    }
  }

  // Model rows read as a table: the share bar fills the row behind the label
  // instead of stacking under it, which keeps the whole dashboard on one screen.
  component ModelRow: Item {
    id: modelRow
    property var row: null
    property real share: 0

    implicitHeight: modelName.implicitHeight + Style.spacing.lg

    Rectangle {
      anchors.fill: parent
      radius: Anatomy.rowRadius
      color: Qt.rgba(1, 1, 1, 0.03)
    }

    Rectangle {
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      width: parent.width * root.clamp(modelRow.share, 0, 1)
      radius: Anatomy.rowRadius
      color: modelHover.containsMouse ? Qt.rgba(1, 1, 1, 0.12) : Qt.rgba(1, 1, 1, 0.07)

      Behavior on width {
        NumberAnimation { duration: Anatomy.base; easing.type: Easing.Bezier; easing.bezierCurve: Anatomy.ease }
      }
      Behavior on color { ColorAnimation { duration: Anatomy.fast } }
    }

    Text {
      id: modelName
      textFormat: Text.PlainText
      text: modelRow.row ? modelRow.row.name : ""
      color: Anatomy.strong
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
      anchors.left: parent.left
      anchors.leftMargin: Style.space(8)
      anchors.right: modelTokens.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      id: modelTokens
      textFormat: Text.PlainText
      text: modelRow.row ? usage.formatTokenCount(modelRow.row.total) : ""
      color: Anatomy.text
      font.family: Anatomy.mono
      font.pixelSize: Style.font.bodySmall
      font.weight: Font.Medium
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
    }

    MouseArea {
      id: modelHover
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
    }

    PanelToolTip {
      visible: modelHover.containsMouse
      text: root.modelTooltip(modelRow.row)
      fontFamily: root.fontFamily
    }
  }
}
