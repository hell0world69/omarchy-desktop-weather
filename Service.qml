import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons as Commons

// Desktop weather — a clock and weather card at the top center of every
// screen, on the Bottom layer so it sits on the wallpaper and under windows.
//
// Location is detected from the public IP address (ipinfo.io) on every
// refresh, so it follows the machine around. A location picked in the bar's
// weather popup (weather.json, owned by omarchy-weather-location) overrides
// detection. If detection fails before anything is known, Manila is used.
// Temperatures are always Celsius. Left click refreshes; drag to move.
//
// Each screen gets a transparent full-screen surface that takes input only
// over the card, and dragging moves the card within it. The position is kept in
// $XDG_STATE_HOME/omarchy/desktop-weather.json along with the screen size and
// shell text size it was dragged at; with none saved, or once the display
// scale or text size changes, the card sits at the top center.
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property real fallbackLatitude: 14.6042
  readonly property real fallbackLongitude: 120.9822
  readonly property string fallbackName: "Manila"
  readonly property int refreshMinutes: 15

  property real latitude: fallbackLatitude
  property real longitude: fallbackLongitude
  property string placeName: ""
  property bool manualLocation: false
  property bool locationKnown: false

  property date now: new Date()

  readonly property string statePath: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state")
    + "/omarchy/desktop-weather.json"
  // Card's top-left corner on screen; -1 means not placed yet (top center).
  property real posX: -1
  property real posY: -1
  // Screen size and text size the position was saved at; -1 means unknown.
  property real savedWidth: -1
  property real savedHeight: -1
  property int savedFontSize: -1
  // The shell's text size loads asynchronously at startup, so the saved
  // position isn't checked against it until things have settled.
  property bool settled: false

  Timer {
    interval: 2000
    running: true
    onTriggered: root.settled = true
  }

  function savePosition(width, height) {
    root.savedWidth = Math.round(width)
    root.savedHeight = Math.round(height)
    root.savedFontSize = Commons.Style.fontBaseSize
    stateFile.setText(JSON.stringify({
      x: Math.round(root.posX), y: Math.round(root.posY),
      width: root.savedWidth, height: root.savedHeight, fontSize: root.savedFontSize
    }) + "\n")
  }

  function resetPosition() {
    root.posX = -1
    root.posY = -1
    root.savedWidth = -1
    root.savedHeight = -1
    root.savedFontSize = -1
    stateFile.setText("{}\n")
  }

  property string temperature: ""
  property string feelsLike: ""
  property string highLow: ""
  property string humidity: ""
  property string condition: ""
  property string icon: ""
  property bool hasData: false
  // Next three days: [{ day: "Tue", icon: ..., high: "12", low: "6" }]
  property var forecast: []

  function glyph(cp) { return String.fromCodePoint(cp) }

  // Open-Meteo WMO weather code → [Nerd Font glyph, description].
  function describe(code, isDay) {
    var c = parseInt(code, 10)
    var night = Number(isDay) === 0
    if (c === 0) return [glyph(night ? 0xF0594 : 0xF0599), "Clear"]
    if (c === 1 || c === 2) return [glyph(night ? 0xF0F31 : 0xF0595), "Partly cloudy"]
    if (c === 3) return [glyph(0xF0590), "Overcast"]
    if (c === 45 || c === 48) return [glyph(0xF0591), "Fog"]
    if (c >= 51 && c <= 57) return [glyph(0xF0597), "Drizzle"]
    if (c === 61 || c === 63 || c === 80 || c === 81) return [glyph(0xF0597), "Rain"]
    if (c === 65 || c === 66 || c === 67 || c === 82) return [glyph(0xF0596), "Heavy rain"]
    if ((c >= 71 && c <= 77) || c === 85 || c === 86) return [glyph(0xF0598), "Snow"]
    if (c >= 95) return [glyph(0xF0593), "Thunderstorm"]
    return [glyph(0xF0590), "Cloudy"]
  }

  function round(v) {
    var n = parseFloat(v)
    return isNaN(n) ? "" : String(Math.round(n))
  }

  function refresh() {
    if (root.manualLocation) fetchWeather()
    else if (!locateProc.running) locateProc.running = true
  }

  function fetchWeather() {
    if (fetchProc.running) return
    var url = "https://api.open-meteo.com/v1/forecast"
      + "?latitude=" + encodeURIComponent(String(root.latitude))
      + "&longitude=" + encodeURIComponent(String(root.longitude))
      + "&current=temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,is_day"
      + "&daily=weather_code,temperature_2m_max,temperature_2m_min"
      + "&forecast_days=4&temperature_unit=celsius&timezone=auto"
    fetchProc.command = ["curl", "-fsS", "--max-time", "10", "--max-filesize", "65536", url]
    fetchProc.running = true
  }

  FileView {
    path: Quickshell.env("HOME") + "/.local/state/omarchy/settings/weather.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try {
        var data = JSON.parse(text())
        var lat = parseFloat(data.latitude)
        var lon = parseFloat(data.longitude)
        if (!isNaN(lat) && !isNaN(lon)) {
          root.latitude = lat
          root.longitude = lon
          root.placeName = typeof data.name === "string" && data.name.trim() !== ""
            ? data.name.trim().slice(0, 40) : ""
          root.manualLocation = true
          root.locationKnown = true
          root.refresh()
          return
        }
      } catch (e) {}
      root.manualLocation = false
    }
  }

  // IP geolocation. {"city": ..., "region": ..., "loc": "lat,lon"}
  Process {
    id: locateProc
    command: ["curl", "-fsS", "--max-time", "6", "--max-filesize", "16384", "https://ipinfo.io/json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var data = JSON.parse(String(text || ""))
          var parts = String(data.loc || "").split(",")
          var lat = parseFloat(parts[0])
          var lon = parseFloat(parts[1])
          if (!isNaN(lat) && !isNaN(lon) && Math.abs(lat) <= 90 && Math.abs(lon) <= 180) {
            root.latitude = lat
            root.longitude = lon
            root.placeName = typeof data.city === "string" ? data.city.trim().slice(0, 40) : ""
            root.locationKnown = true
          }
        } catch (e) {
          // Keep the last known location.
        }
        if (!root.locationKnown) root.placeName = root.fallbackName
        root.fetchWeather()
      }
    }
  }

  Process {
    id: fetchProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var data = JSON.parse(String(text || ""))
          var cur = data.current
          if (!cur || cur.temperature_2m === undefined) return
          var d = root.describe(cur.weather_code, cur.is_day)
          root.icon = d[0]
          root.condition = d[1]
          root.temperature = root.round(cur.temperature_2m)
          root.feelsLike = root.round(cur.apparent_temperature)
          root.humidity = root.round(cur.relative_humidity_2m)
          if (data.daily && data.daily.temperature_2m_max)
            root.highLow = "H " + root.round(data.daily.temperature_2m_max[0]) + "°  L "
              + root.round(data.daily.temperature_2m_min[0]) + "°"
          var days = []
          var daily = data.daily || {}
          for (var i = 1; daily.time && i < daily.time.length && days.length < 3; i++) {
            var date = new Date(String(daily.time[i]).slice(0, 10) + "T12:00:00")
            if (isNaN(date.getTime())) continue
            days.push({
              day: Qt.locale().toString(date, "ddd"),
              icon: root.describe(daily.weather_code ? daily.weather_code[i] : 3, 1)[0],
              high: root.round(daily.temperature_2m_max ? daily.temperature_2m_max[i] : ""),
              low: root.round(daily.temperature_2m_min ? daily.temperature_2m_min[i] : "")
            })
          }
          root.forecast = days
          root.hasData = true
        } catch (e) {
          // Keep the last good reading on screen.
        }
      }
    }
  }

  Timer {
    interval: root.refreshMinutes * 60 * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    interval: 1000
    running: true
    repeat: true
    onTriggered: root.now = new Date()
  }

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: {
      try {
        var data = JSON.parse(text())
        var x = parseFloat(data.x)
        var y = parseFloat(data.y)
        if (!isNaN(x) && !isNaN(y)) {
          root.savedWidth = parseFloat(data.width) || -1
          root.savedHeight = parseFloat(data.height) || -1
          root.savedFontSize = parseInt(data.fontSize) || -1
          root.posX = x
          root.posY = y
        }
      } catch (e) {}
    }
  }

  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: win
      required property var modelData
      screen: modelData

      function clamp(v, lo, hi) { return Math.max(lo, Math.min(v, Math.max(lo, hi))) }

      // A dragged position only holds at the scale and text size it was made
      // at; after either changes, the card goes back to the top center. The
      // screen's logical size is used because the window reports a placeholder
      // size until the compositor configures it.
      readonly property bool placementStale: root.settled && root.posX >= 0
        && (root.savedWidth !== Math.round(win.screen.width) || root.savedHeight !== Math.round(win.screen.height)
          || root.savedFontSize !== Commons.Style.fontBaseSize)
      onPlacementStaleChanged: if (placementStale) Qt.callLater(root.resetPosition)

      // Covers the whole screen and takes input only over the card, so a drag
      // moves the card inside the window in the same frame. Moving the window
      // itself waits on the compositor and makes the card jitter.
      color: "transparent"
      anchors { top: true; left: true; right: true; bottom: true }
      mask: Region { item: card }

      WlrLayershell.namespace: "omarchy-desktop-weather"
      WlrLayershell.layer: WlrLayer.Bottom
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      exclusionMode: ExclusionMode.Ignore

      Rectangle {
        id: card
        x: root.posX < 0 ? Math.max(0, (win.width - width) / 2) : win.clamp(root.posX, 0, win.width - width)
        y: root.posY < 0 ? 24 : win.clamp(root.posY, 0, win.height - height)
        implicitWidth: content.implicitWidth + 48
        implicitHeight: content.implicitHeight + 32
        radius: 16
        color: Qt.alpha(Commons.Color.background, 0.25)
        border.width: 1
        border.color: Qt.alpha(Commons.Color.foreground, 0.08)

        Row {
          id: content
          anchors.centerIn: parent
          spacing: 24

          Column {
            spacing: 2
            anchors.verticalCenter: parent.verticalCenter

            Text {
              textFormat: Text.PlainText
              text: Qt.formatDateTime(root.now, "HH:mm")
              color: Commons.Color.foreground
              font.family: Commons.Style.fontFamily
              font.pixelSize: 64
              font.weight: Font.Light
            }

            Text {
              textFormat: Text.PlainText
              text: Qt.locale().toString(root.now, "dddd, d MMMM yyyy")
              color: Commons.Color.foreground
              font.family: Commons.Style.fontFamily
              font.pixelSize: 14
            }
          }

          Rectangle {
            visible: root.hasData
            width: 1
            height: parent.height - 8
            anchors.verticalCenter: parent.verticalCenter
            color: Qt.alpha(Commons.Color.foreground, 0.15)
          }

          Column {
            visible: root.hasData
            spacing: 2
            anchors.verticalCenter: parent.verticalCenter

            Row {
              spacing: 12

              Text {
                textFormat: Text.PlainText
                text: root.icon
                color: Commons.Color.accent
                font.family: Commons.Style.fontFamily
                font.pixelSize: 52
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                textFormat: Text.PlainText
                text: root.temperature + "°C"
                color: Commons.Color.foreground
                font.family: Commons.Style.fontFamily
                font.pixelSize: 52
                font.weight: Font.Light
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Text {
              textFormat: Text.PlainText
              text: root.condition + (root.placeName ? "  ·  " + root.placeName : "")
              color: Commons.Color.foreground
              font.family: Commons.Style.fontFamily
              font.pixelSize: 14
            }

            Text {
              textFormat: Text.PlainText
              text: "Feels " + root.feelsLike + "°C   " + root.highLow + "   " + root.humidity + "%"
              color: Commons.Color.muted
              font.family: Commons.Style.fontFamily
              font.pixelSize: 12
            }
          }

          Rectangle {
            visible: root.forecast.length > 0
            width: 1
            height: parent.height - 8
            anchors.verticalCenter: parent.verticalCenter
            color: Qt.alpha(Commons.Color.foreground, 0.15)
          }

          Row {
            visible: root.forecast.length > 0
            spacing: 18
            anchors.verticalCenter: parent.verticalCenter

            Repeater {
              model: root.forecast

              Column {
                required property var modelData
                spacing: 4

                Text {
                  textFormat: Text.PlainText
                  text: modelData.day
                  color: Commons.Color.foreground
                  font.family: Commons.Style.fontFamily
                  font.pixelSize: 14
                  anchors.horizontalCenter: parent.horizontalCenter
                }

                Text {
                  textFormat: Text.PlainText
                  text: modelData.icon
                  color: Commons.Color.accent
                  font.family: Commons.Style.fontFamily
                  font.pixelSize: 30
                  anchors.horizontalCenter: parent.horizontalCenter
                }

                Text {
                  textFormat: Text.PlainText
                  text: modelData.high + "°"
                  color: Commons.Color.foreground
                  font.family: Commons.Style.fontFamily
                  font.pixelSize: 14
                  anchors.horizontalCenter: parent.horizontalCenter
                }

                Text {
                  textFormat: Text.PlainText
                  text: modelData.low + "°"
                  color: Commons.Color.muted
                  font.family: Commons.Style.fontFamily
                  font.pixelSize: 12
                  anchors.horizontalCenter: parent.horizontalCenter
                }
              }
            }
          }
        }

        // Positions are tracked in window coordinates, which stay fixed while
        // the card moves, so each move is measured from the press point.
        MouseArea {
          property point pressScene: Qt.point(0, 0)
          property point pressCard: Qt.point(0, 0)
          property bool dragged: false

          anchors.fill: parent
          cursorShape: pressed && dragged ? Qt.ClosedHandCursor : Qt.OpenHandCursor
          onPressed: function(mouse) {
            pressScene = mapToItem(null, mouse.x, mouse.y)
            pressCard = Qt.point(card.x, card.y)
            dragged = false
          }
          onPositionChanged: function(mouse) {
            var p = mapToItem(null, mouse.x, mouse.y)
            var dx = p.x - pressScene.x
            var dy = p.y - pressScene.y
            if (!dragged && Math.abs(dx) + Math.abs(dy) < 4) return
            dragged = true
            root.posX = win.clamp(pressCard.x + dx, 0, win.width - card.width)
            root.posY = win.clamp(pressCard.y + dy, 0, win.height - card.height)
          }
          onReleased: {
            if (dragged) root.savePosition(win.screen.width, win.screen.height)
            else root.refresh()
          }
        }
      }
    }
  }
}
