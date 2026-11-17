import QtQuick 2.9
import QtQuick.Controls 2.2
import QtQuick.Layouts 1.3

import NetProbe 1.0
import StreamingPreferences 1.0

// Nova Play: «Prueba de red». Mide ancho de banda, perdida de paquetes, latencia y variacion contra el servidor de pruebas que esta
// junto a las consolas (backend/netprobe.cpp), dice si la red sirve para jugar y ofrece la calidad que conviene.
Item {
    id: page
    objectName: qsTr("Prueba de red")
    property string host: "103.212.83.177"

    readonly property color ink: "#0D1022"
    readonly property color frost: "#EEF0FA"
    readonly property color mist: "#8D93B0"
    readonly property color violet: "#9B4DFF"
    readonly property color lilac: "#B98AFF"
    readonly property color good: "#3EE08F"
    readonly property color fair: "#FFB547"
    readonly property color bad: "#FF6B6B"

    property var result: null
    property string error: ""
    property bool applied: false

    NetProbe {
        id: probe
        onFinished: function(r) { page.result = r }
        onFailed: function(msg) { page.error = msg }
    }
    function restart() { result = null; error = ""; applied = false; probe.start(host) }
    Component.onCompleted: restart()
    Component.onDestruction: probe.cancel()

    readonly property var steps: [qsTr("Latencia"), qsTr("Pérdida de paquetes"), qsTr("Ancho de banda")]
    function gradeHigh(v, req, rec) { return v >= rec ? 2 : v >= req ? 1 : 0 }
    function gradeLow(v, req, rec) { return v < rec ? 2 : v < req ? 1 : 0 }
    function gradeColor(g) { return g === 2 ? good : g === 1 ? fair : bad }
    readonly property int gBw: result ? gradeHigh(result.mbps, 15, 35) : 0
    readonly property int gLoss: result ? gradeLow(result.lossPct, 2.0, 1.0) : 0
    readonly property int gLat: result ? gradeLow(result.latencyMs, 80, 40) : 0
    readonly property int gJit: result ? gradeLow(result.jitterMs, 30, 10) : 0
    readonly property int worst: Math.min(gBw, gLoss, gLat, gJit)

    function reason() {
        if (worst === 2) return qsTr("Excelente conexión: disfruta tus juegos con la mejor calidad.")
        var s = []
        if (gBw < 2) s.push(gBw === 0 ? qsTr("La velocidad es muy baja.") : qsTr("La velocidad es justa: bajamos un poco la calidad."))
        if (gLoss < 2) s.push(qsTr("Se pierden paquetes: puede verse entrecortado."))
        if (gLat < 2) s.push(gLat === 0 ? qsTr("La demora (latencia) es alta: los controles responderán tarde.") : qsTr("La demora es algo alta para juegos rápidos."))
        if (gJit < 2) s.push(qsTr("La conexión es inestable."))
        if (worst < 2) s.push(qsTr("Si usas Wi-Fi, conéctate a la red de 5 GHz o usa un cable de red, y pausa las descargas en otros equipos."))
        return s.join(" ")
    }

    component Card: Rectangle {
        radius: 20
        color: "#B30D1022"
        border.color: "#1AFFFFFF"
        Layout.fillWidth: true
    }
    component Btn: Button {
        id: b
        property bool primary: false
        font.pointSize: 12
        font.weight: Font.DemiBold
        Layout.preferredHeight: 48
        background: Rectangle {
            radius: height / 2
            color: !b.primary ? (b.hovered ? "#1AFFFFFF" : "transparent") : !b.enabled ? "#3A2F5C" : b.down ? "#7F33E6" : b.hovered ? "#AE6BFF" : violet
            border.color: b.primary ? "transparent" : "#33FFFFFF"
        }
        contentItem: Label { text: b.text; font: b.font; color: b.enabled ? "#FFFFFF" : "#9A93B5"; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
    }

    ScrollView {
        anchors.fill: parent
        contentWidth: availableWidth
        ColumnLayout {
            width: Math.min(parent.width - 48, 620)
            x: (parent.width - width) / 2
            spacing: 14

            Item { Layout.preferredHeight: 12 }
            Label { text: qsTr("Prueba de red"); font.pointSize: 22; font.bold: true; color: frost }
            Label {
                text: qsTr("Medimos tu conexión con las consolas de Nova Play en Colombia, igual que viaja el video de tu juego.")
                color: mist; wrapMode: Text.WordWrap; Layout.fillWidth: true
            }

            // ---- midiendo
            Rectangle {
                visible: probe.running
                radius: 26
                Layout.fillWidth: true
                Layout.preferredHeight: liveCol.implicitHeight + 52
                border.color: "#339B4DFF"
                gradient: Gradient {
                    GradientStop { position: 0.0; color: "#2A1A5E" }
                    GradientStop { position: 0.6; color: "#141433" }
                    GradientStop { position: 1.0; color: ink }
                }
                ColumnLayout {
                    id: liveCol
                    anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                    anchors.margins: 26
                    spacing: 10
                    Label {
                        Layout.alignment: Qt.AlignHCenter
                        color: lilac; font.weight: Font.DemiBold
                        text: probe.phase === 0 ? qsTr("Midiendo la latencia") : probe.phase === 1 ? qsTr("Midiendo la pérdida de paquetes") : probe.phase === 2 ? qsTr("Midiendo el ancho de banda") : qsTr("Preparando la prueba…")
                    }
                    RowLayout {
                        Layout.alignment: Qt.AlignHCenter
                        Label {
                            text: probe.phase < 0 ? "—" : probe.phase === 1 ? probe.live.toFixed(1) : Math.round(probe.live)
                            font.pointSize: 44; font.bold: true; color: frost
                        }
                        Label {
                            text: probe.phase === 0 ? "ms" : probe.phase === 1 ? "%" : probe.phase === 2 ? "Mbps" : ""
                            font.pointSize: 14; color: mist; Layout.alignment: Qt.AlignBottom; Layout.bottomMargin: 10
                        }
                    }
                    ProgressBar { value: probe.progress; Layout.fillWidth: true }
                    Repeater {
                        model: steps
                        RowLayout {
                            spacing: 12
                            Rectangle { width: 10; height: 10; radius: 5; color: index < probe.phase ? good : index === probe.phase ? violet : "#33FFFFFF" }
                            Label {
                                text: modelData + (index === probe.phase ? "…" : index < probe.phase ? "  ✓" : "")
                                color: index <= probe.phase ? frost : mist
                                font.weight: index === probe.phase ? Font.DemiBold : Font.Normal
                            }
                        }
                    }
                }
            }
            Label {
                visible: probe.running
                text: qsTr("Tarda unos 15 segundos. Para que sea exacta, pausa las descargas y videos en tus otros equipos.")
                color: mist; wrapMode: Text.WordWrap; Layout.fillWidth: true; font.pointSize: 9
            }

            // ---- error
            Card {
                visible: !probe.running && error !== ""
                Layout.preferredHeight: errCol.implicitHeight + 36
                color: "#1EFF6B6B"; border.color: "#6EFF6B6B"
                ColumnLayout {
                    id: errCol
                    anchors.fill: parent; anchors.margins: 18
                    Label { text: qsTr("No se pudo hacer la prueba"); font.pointSize: 15; font.bold: true; color: frost }
                    Label { text: error; color: frost; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                }
            }

            // ---- resultado
            Card {
                visible: !probe.running && !!result
                Layout.preferredHeight: verdictCol.implicitHeight + 36
                color: Qt.rgba(gradeColor(worst).r, gradeColor(worst).g, gradeColor(worst).b, 0.12)
                border.color: Qt.rgba(gradeColor(worst).r, gradeColor(worst).g, gradeColor(worst).b, 0.45)
                ColumnLayout {
                    id: verdictCol
                    anchors.fill: parent; anchors.margins: 18
                    RowLayout {
                        spacing: 10
                        Rectangle { width: 12; height: 12; radius: 6; color: gradeColor(worst) }
                        Label {
                            text: worst === 2 ? qsTr("Tu red está lista para jugar") : worst === 1 ? qsTr("Tu red sirve para jugar") : qsTr("Tu red no alcanza para jugar bien")
                            font.pointSize: 15; font.bold: true; color: frost
                        }
                    }
                    Label { text: result ? reason() : ""; color: frost; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                }
            }
            Card {
                visible: !probe.running && !!result
                Layout.preferredHeight: qCol.implicitHeight + 32
                ColumnLayout {
                    id: qCol
                    anchors.fill: parent; anchors.margins: 16
                    Label { text: qsTr("CALIDAD RECOMENDADA"); color: mist; font.pointSize: 8; font.weight: Font.DemiBold }
                    Label {
                        property var q: result ? result.quality : null
                        text: q ? qsTr("%1p a %2 FPS · %3 Mbps").arg(q.height).arg(q.fps).arg(Math.round(q.kbps / 1000)) : qsTr("Sin calidad recomendada")
                        font.pointSize: 16; font.bold: true; color: frost
                    }
                    Btn {
                        visible: !!(result && result.quality)
                        primary: true
                        enabled: !applied
                        text: applied ? qsTr("Calidad aplicada  ✓") : qsTr("Usar esta calidad")
                        Layout.fillWidth: true
                        onClicked: {
                            var q = result.quality
                            StreamingPreferences.width = q.width
                            StreamingPreferences.height = q.height
                            StreamingPreferences.fps = q.fps
                            StreamingPreferences.bitrateKbps = q.kbps
                            StreamingPreferences.save()
                            applied = true
                        }
                    }
                }
            }
            Card {
                visible: !probe.running && !!result
                Layout.preferredHeight: detCol.implicitHeight + 36
                ColumnLayout {
                    id: detCol
                    anchors.fill: parent; anchors.margins: 18
                    spacing: 8
                    Label { text: qsTr("Detalles"); font.pointSize: 14; font.bold: true; color: frost }
                    Repeater {
                        model: result ? [
                            { t: qsTr("Ancho de banda (Mbps)"), m: result.mbps >= 100 ? "> 100" : String(Math.round(result.mbps)), g: gBw, req: "> 15", rec: "> 35" },
                            { t: qsTr("Pérdida de paquetes (%)"), m: result.lossPct.toFixed(1), g: gLoss, req: "< 2.0", rec: "< 1.0" },
                            { t: qsTr("Latencia (ms)"), m: String(Math.round(result.latencyMs)), g: gLat, req: "< 80", rec: "< 40" },
                            { t: qsTr("Variación (ms)"), m: String(Math.round(result.jitterMs)), g: gJit, req: "< 30", rec: "< 10" }
                        ] : []
                        ColumnLayout {
                            Layout.fillWidth: true
                            Layout.topMargin: 8
                            spacing: 6
                            Label { text: modelData.t; color: frost; font.weight: Font.DemiBold; font.pointSize: 11 }
                            RowLayout { Layout.fillWidth: true; Label { text: qsTr("Medido"); color: mist; Layout.fillWidth: true } Label { text: modelData.m; color: gradeColor(modelData.g); font.bold: true } }
                            RowLayout { Layout.fillWidth: true; Label { text: qsTr("Requerido"); color: mist; Layout.fillWidth: true } Label { text: modelData.req; color: frost } }
                            RowLayout { Layout.fillWidth: true; Label { text: qsTr("Recomendado"); color: mist; Layout.fillWidth: true } Label { text: modelData.rec; color: frost } }
                        }
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 10
                Btn { text: probe.running ? qsTr("Cancelar") : qsTr("Cerrar"); Layout.fillWidth: true; onClicked: { probe.cancel(); stackView.pop() } }
                Btn { visible: !probe.running; primary: true; text: qsTr("Inténtalo de nuevo"); Layout.fillWidth: true; Layout.preferredWidth: 2; onClicked: restart() }
            }
            Item { Layout.preferredHeight: 20 }
        }
    }
}
