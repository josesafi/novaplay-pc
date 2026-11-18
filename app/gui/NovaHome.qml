import QtQuick 2.9
import QtQuick.Controls 2.2
import QtQuick.Layouts 1.3
import QtQuick.Controls.Material 2.2

import NovaApi 1.0
import ComputerManager 1.0
import ComputerModel 1.0

// Nova Play: pantalla principal propia. Sin sesion: iniciar sesion o crear la cuenta de novawebcolombia.com sin salir de la app
// (NovaLogin.qml; con verificacion en dos pasos si la tiene). Con sesion: saludo, saldo y tiempo de juego, y la consola del jugador con «Encender mi consola» / «Jugar».
Item {
    id: home
    objectName: qsTr("Nova Play")

    readonly property color night: "#06070F"
    readonly property color ink: "#0D1022"
    readonly property color frost: "#EEF0FA"
    readonly property color mist: "#8D93B0"
    readonly property color violet: "#9B4DFF"
    readonly property color electric: "#2E8BFF"
    readonly property color ok: "#3EE08F"
    readonly property color warn: "#FFC24A"

    // estado de la cuenta (respuesta de GET /accounts/:id/play)
    property string accountId: ""
    property var play: null
    property var myHost: null
    property bool loading: false
    property string loadError: ""
    property bool waking: false
    property string wakeError: ""
    // «Jugar» de un toque
    property bool connecting: false
    property string connectMsg: ""
    property string playHost: ""
    property int playPort: 47989
    property int pairIndex: -1

    ComputerModel { id: computerModel }
    Component.onCompleted: { computerModel.initialize(ComputerManager); NovaApi.refreshSession() }

    function failPlay(msg) {
        connecting = false
        wakeError = msg
    }
    function openApps(index) {
        connecting = false
        var component = Qt.createComponent("AppView.qml")
        var view = component.createObject(stackView, {"computerIndex": index, "objectName": computerModel.computerName(index)})
        stackView.push(view)
    }
    // agrega la consola por su direccion publica; la primera vez empareja este PC sin codigos (el codigo se registra en la cuenta
    // por la API y el agente de la consola lo confirma) y abre la lista de apps de la consola
    function startPlay() {
        var addr = myHost.publicHost || ""
        var colon = addr.lastIndexOf(":")
        playHost = colon > 0 && addr.indexOf(":") === colon ? addr.substring(0, colon) : addr
        playPort = colon > 0 && addr.indexOf(":") === colon ? parseInt(addr.substring(colon + 1)) : 47989
        wakeError = ""
        connecting = true
        connectMsg = qsTr("Conectando con tu consola…")
        ComputerManager.addNewHostManually(addr)
    }
    Connections {
        target: ComputerManager
        function onComputerAddCompleted(success, detectedPortBlocking) {
            if (!connecting) return
            if (!success) { failPlay(qsTr("No pudimos conectar con tu consola. Revisa tu internet e inténtalo de nuevo.")); return }
            var index = computerModel.findComputerByAddress(playHost, playPort)
            if (index < 0) { failPlay(qsTr("No encontramos tu consola. Inténtalo de nuevo.")); return }
            if (computerModel.isComputerPaired(index)) { openApps(index); return }
            connectMsg = qsTr("Preparando tu PC para jugar (solo la primera vez)…")
            var pin = computerModel.generatePinString()
            NovaApi.post("/api/v1/accounts/" + accountId + "/play/devices", { hostId: myHost.id, pin: pin, name: "Nova Play PC" }, function(status, body) {
                if (status !== 200 && status !== 201) {
                    failPlay((body && body.error && body.error.message) || (body && body.message) || qsTr("No se pudo preparar tu PC. Inténtalo de nuevo."))
                    return
                }
                pairIndex = index
                computerModel.pairComputer(index, pin)
            })
        }
    }
    Connections {
        target: computerModel
        function onPairingCompleted(error) {
            if (!connecting || pairIndex < 0) return
            var index = pairIndex
            pairIndex = -1
            if (error) failPlay(qsTr("No se pudo emparejar tu PC con la consola. Inténtalo de nuevo en un minuto."))
            else openApps(index)
        }
    }

    function money(minor) {
        var pesos = Math.max(0, Math.round((minor || 0) / 100))
        return "$ " + pesos.toString().replace(/\B(?=(\d{3})+(?!\d))/g, ".")
    }
    function hm(m) {
        m = Math.max(0, m || 0)
        return m >= 60 ? Math.floor(m / 60) + " h " + (m % 60) + " min" : m + " min"
    }
    function greeting() {
        var h = new Date().getHours()
        var n = NovaApi.firstName
        return (h < 12 ? qsTr("Buenos días") : h < 19 ? qsTr("Buenas tardes") : qsTr("Buenas noches")) + (n ? ", " + n : "")
    }
    // la consola del jugador: la de un dispositivo suyo ya emparejado; si no tiene, la primera disponible
    function pickHost(p) {
        if (!p || !p.hosts || !p.hosts.length) return null
        var devices = p.devices || []
        for (var i = 0; i < p.hosts.length; i++) {
            for (var j = 0; j < devices.length; j++) {
                if (devices[j].hostId === p.hosts[i].id && devices[j].status === "PAIRED") return p.hosts[i]
            }
        }
        for (var k = 0; k < p.hosts.length; k++) {
            var h = p.hosts[k]
            if ((h.online || h.asleep || h.starting) && h.busy < h.maxSessions) return h
        }
        return p.hosts[0]
    }
    function refresh() {
        if (!NovaApi.loggedIn) return
        if (!accountId) {
            loading = true
            NovaApi.get("/api/v1/accounts", function(status, body) {
                loading = false
                if (status === 200 && body && body.length) {
                    accountId = body[0].id
                    refresh()
                } else if (status !== 401) {
                    loadError = qsTr("No pudimos leer tu cuenta. Revisa tu internet.")
                }
            })
            return
        }
        NovaApi.get("/api/v1/accounts/" + accountId + "/play", function(status, body) {
            if (status === 200 && body) {
                play = body
                myHost = pickHost(body)
                loadError = ""
                if (myHost && myHost.online) waking = false
            } else if (status !== 401) {
                loadError = qsTr("No pudimos leer tu información de juego. Revisa tu internet.")
            }
        })
    }
    function wake() {
        if (!myHost) return
        waking = true
        wakeError = ""
        NovaApi.post("/api/v1/accounts/" + accountId + "/play/hosts/" + myHost.id + "/wake", {}, function(status, body) {
            if (status !== 200) {
                waking = false
                wakeError = (body && body.error && body.error.message) || (body && body.message) || qsTr("No se pudo encender. Inténtalo de nuevo.")
            }
            refresh()
        })
    }

    Timer {
        // mientras la consola enciende se pregunta cada 5 s; si no, cada 30 s
        interval: (waking || (myHost && myHost.starting)) ? 5000 : 30000
        running: NovaApi.loggedIn
        repeat: true
        triggeredOnStart: true
        onTriggered: refresh()
    }
    Connections {
        target: NovaApi
        function onSessionExpired() { accountId = ""; play = null; myHost = null }
    }

    // ------------------------------------------------------------------ inicio de sesion y crear cuenta (NovaLogin.qml)
    NovaLogin {
        anchors.fill: parent
        visible: !NovaApi.loggedIn
    }

    // verificacion en dos pasos (autenticador)
    NovaSecurity {
        id: securityPopup
        parent: home
    }

    // ------------------------------------------------------------------ inicio (con sesion)
    Flickable {
        anchors.fill: parent
        visible: NovaApi.loggedIn
        contentHeight: homeCol.implicitHeight + 80
        clip: true

        ColumnLayout {
            id: homeCol
            width: Math.min(1100, parent.width - 96)
            x: (parent.width - width) / 2
            y: 40
            spacing: 22

            Label {
                text: greeting()
                font.pointSize: 30
                font.weight: Font.Bold
                color: frost
            }
            Label {
                text: qsTr("Tu PC gamer en la nube, lista cuando la necesites.")
                color: mist
                font.pointSize: 13
                Layout.topMargin: -12
            }

            // saldo, tiempo de juego y paquete
            RowLayout {
                spacing: 14
                Layout.fillWidth: true
                Repeater {
                    model: play ? [
                        { k: qsTr("Saldo"), v: money(play.balanceMinor) },
                        { k: qsTr("Tiempo de juego disponible"), v: hm(play.minutesAffordable) },
                        { k: qsTr("Horas de paquete"), v: play.packageMinutesLeft > 0 ? hm(play.packageMinutesLeft) : qsTr("Sin paquete") }
                    ] : []
                    delegate: Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 92
                        radius: 18
                        color: "#B30D1022"
                        border.color: "#14FFFFFF"
                        Column {
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.left: parent.left
                            anchors.leftMargin: 20
                            spacing: 4
                            Label { text: modelData.k; color: mist; font.pointSize: 11 }
                            Label { text: modelData.v; color: frost; font.pointSize: 20; font.weight: Font.DemiBold }
                        }
                    }
                }
            }

            // la consola del jugador
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 260
                radius: 26
                color: "#B30D1022"
                border.color: "#14FFFFFF"
                visible: play !== null

                RowLayout {
                    anchors.fill: parent
                    anchors.margins: 30
                    spacing: 30

                    // el icono de Nova Play ya trae su cuadro oscuro redondeado: se muestra solo, sin otro marco alrededor
                    Image {
                        Layout.preferredWidth: 190
                        Layout.preferredHeight: 190
                        source: "qrc:/res/novaplay-n.png"
                        fillMode: Image.PreserveAspectFit
                        mipmap: true
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        Label {
                            text: myHost ? qsTr("Tu consola") : qsTr("Sin consola disponible")
                            color: mist
                            font.pointSize: 12
                        }
                        Label {
                            text: myHost ? myHost.name : qsTr("Nova Play")
                            color: frost
                            font.pointSize: 26
                            font.weight: Font.Bold
                        }
                        RowLayout {
                            spacing: 10
                            BusyIndicator {
                                visible: waking || connecting || (myHost && myHost.starting)
                                running: visible
                                Layout.preferredWidth: 28
                                Layout.preferredHeight: 28
                            }
                            Rectangle {
                                visible: !(waking || connecting || (myHost && myHost.starting))
                                width: 10; height: 10; radius: 5
                                color: myHost && myHost.online ? ok : myHost && myHost.asleep ? electric : mist
                            }
                            Label {
                                color: frost
                                font.pointSize: 13
                                text: !myHost ? qsTr("Escríbenos a soporte para asignarte una consola.")
                                     : connecting ? connectMsg
                                     : (waking || myHost.starting) ? qsTr("Encendiendo tu consola… estará lista en 20 a 30 segundos.")
                                     : myHost.online ? qsTr("Encendida y lista para jugar")
                                     : myHost.asleep ? qsTr("Apagada para ahorrar energía")
                                     : qsTr("Sin conexión en este momento")
                            }
                        }
                        Label {
                            visible: play && !play.canStart
                            text: qsTr("Necesitas tiempo de juego: recarga tu saldo o compra un paquete en novawebcolombia.com.")
                            color: warn
                            wrapMode: Text.WordWrap
                            Layout.fillWidth: true
                        }
                        Label {
                            visible: wakeError !== ""
                            text: wakeError
                            color: "#FF8A8A"
                            wrapMode: Text.WordWrap
                            Layout.fillWidth: true
                        }
                        RowLayout {
                            spacing: 12
                            Layout.topMargin: 8
                            Button {
                                id: playButton
                                text: myHost && myHost.online ? qsTr("Jugar") : qsTr("Encender mi consola")
                                enabled: !!myHost && play.canStart && !waking && !connecting && !myHost.starting && (myHost.online || myHost.asleep)
                                font.pointSize: 14
                                font.weight: Font.DemiBold
                                Layout.preferredHeight: 52
                                Layout.preferredWidth: 230
                                // diseno propio y fijo: morado de la marca con texto blanco (el tema de Windows lo pintaba blanco)
                                background: Rectangle {
                                    radius: height / 2
                                    color: !playButton.enabled ? "#3A2F5C" : playButton.down ? "#7F33E6" : playButton.hovered ? "#AE6BFF" : violet
                                    border.width: playButton.visualFocus ? 2 : 0
                                    border.color: "#FFFFFF"
                                }
                                contentItem: Label {
                                    text: playButton.text
                                    font: playButton.font
                                    color: playButton.enabled ? "#FFFFFF" : "#9A93B5"
                                    horizontalAlignment: Text.AlignHCenter
                                    verticalAlignment: Text.AlignVCenter
                                }
                                onClicked: {
                                    if (myHost.online) startPlay()
                                    else wake()
                                }
                            }
                            Button {
                                text: qsTr("Prueba de red")
                                flat: true
                                Layout.preferredHeight: 52
                                onClicked: {
                                    var addr = (myHost && myHost.publicHost) || ""
                                    var colon = addr.lastIndexOf(":")
                                    if (colon > 0 && addr.indexOf(":") === colon) addr = addr.substring(0, colon)
                                    stackView.push("qrc:/gui/NetTest.qml", addr ? {"host": addr} : {})
                                }
                            }
                            Button {
                                text: qsTr("Mis consolas")
                                flat: true
                                Layout.preferredHeight: 52
                                onClicked: navigateTo("qrc:/gui/PcView.qml", PcView)
                            }
                        }
                    }
                }
            }

            Label {
                visible: loadError !== ""
                text: loadError
                color: "#FF8A8A"
            }
            BusyIndicator {
                visible: loading && !play
                running: visible
                Layout.alignment: Qt.AlignHCenter
            }

            RowLayout {
                spacing: 18
                Layout.topMargin: 10
                Label {
                    text: NovaApi.email ? qsTr("Conectado como %1").arg(NovaApi.email) : ""
                    color: mist
                }
                Label {
                    text: NovaApi.twoFactorEnabled ? qsTr("Verificación en dos pasos: activa") : qsTr("Activar la verificación en dos pasos")
                    color: securityArea.containsMouse ? "#FFFFFF" : (NovaApi.twoFactorEnabled ? ok : "#B98AFF")
                    font.underline: securityArea.containsMouse
                    MouseArea {
                        id: securityArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: securityPopup.open()
                    }
                }
                Label {
                    text: qsTr("Cerrar sesión")
                    color: logoutArea.containsMouse ? "#FFFFFF" : "#B98AFF"
                    font.underline: logoutArea.containsMouse
                    MouseArea {
                        id: logoutArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: { NovaApi.logout(); accountId = ""; play = null; myHost = null }
                    }
                }
            }
        }
    }
}
