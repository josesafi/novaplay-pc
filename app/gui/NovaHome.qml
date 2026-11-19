import QtQuick 2.9
import QtQuick.Controls 2.2
import QtQuick.Layouts 1.3
import QtQuick.Controls.Material 2.2

import NovaApi 1.0
import ComputerManager 1.0
import ComputerModel 1.0
import AppModel 1.0
import SdlGamepadKeyNavigation 1.0

// Nova Play: pantalla principal propia. Sin sesion: iniciar sesion o crear la cuenta de novawebcolombia.com sin salir de la app
// (NovaLogin.qml; con verificacion en dos pasos si la tiene). Con sesion: saludo, saldo y tiempo de juego y el CATALOGO estilo GeForce NOW
// (19-nov-2026): tiendas y juegos con portada; un toque enciende la consola si hace falta, empareja y entra directo al juego, sin escritorio.
// Si la API no tiene catalogo (version vieja) se muestra la tarjeta de antes con «Jugar».
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
    // «Cerrar el juego» del panel «N» llama a la API con esta cuenta durante la transmision
    onAccountIdChanged: NovaApi.setPlayAccount(accountId)
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
    // catalogo (GET /play/catalog). catalogFailed = la API no lo tiene: se usa la tarjeta de antes
    property var catalog: null
    property bool catalogFailed: false
    property bool catalogAsked: false
    // juego en curso de abrir: la capa «Preparando …» se ve mientras pending no es null
    property var pending: null
    property var lastGame: null
    property string pendingStage: ""
    property string pendingError: ""
    property string pendingDetail: ""
    property double pendingSince: 0
    property var launchModel: null
    property int launchTries: 0

    ComputerModel { id: computerModel }
    Component.onCompleted: { computerModel.initialize(ComputerManager); NovaApi.refreshSession() }

    function failPlay(msg) {
        connecting = false
        if (pending) { showPendingError(msg, ""); return }
        wakeError = msg
    }
    // ---------------------------------------------------------------- catalogo: tocar un juego = jugar
    function storeItems() { return (catalog || []).filter(function(c) { return c.kind === "store" }) }
    function gameItems() { return (catalog || []).filter(function(c) { return c.kind !== "store" }) }
    function showPendingError(msg, detail) {
        connecting = false
        pendingStage = ""
        pendingError = msg
        pendingDetail = detail || ""
    }
    function closePending() { pending = null; pendingError = ""; pendingDetail = ""; pendingStage = ""; launchModel = null; launchTimer.stop() }
    function playGame(item) {
        if (!item || connecting || (pending && !pendingError)) return
        if (!myHost) { pending = item; showPendingError(qsTr("Todavía no tienes una consola asignada."), qsTr("Escríbenos a soporte y te la asignamos.")); return }
        if (play && !play.canStart) { pending = item; showPendingError(qsTr("Necesitas tiempo de juego para jugar."), qsTr("Recarga tu saldo o compra un paquete en novawebcolombia.com.")); return }
        pending = item
        lastGame = item
        pendingError = ""
        pendingDetail = ""
        pendingSince = Date.now()
        pendingStage = qsTr("Preparando %1…").arg(item.title)
        NovaApi.post("/api/v1/accounts/" + accountId + "/play/launch", { gameId: item.id }, function(status, body) {
            if (!pending || pending !== item) return
            if (status !== 200) {
                showPendingError(qsTr("No pudimos preparar %1.").arg(item.title), NovaApi.describeError(status, body))
                return
            }
            ensureOnline()
        })
    }
    function ensureOnline() {
        if (!pending || pendingError) return
        if (myHost.online) {
            pendingStage = qsTr("Conectando con tu consola…")
            startPlay()
            return
        }
        pendingStage = qsTr("Encendiendo tu consola… estará lista en 20 a 30 segundos.")
        if (myHost.asleep && !waking && !myHost.starting) wake()
    }
    // llego el estado de la consola mientras se esperaba para abrir un juego: seguir si ya esta lista
    function onHostUpdated() {
        if (!pending || pendingError || connecting || launchModel) return
        if (pendingStage.indexOf(qsTr("Preparando")) === 0) return   // todavia no responde «launch»
        if (myHost && myHost.online) {
            pendingStage = qsTr("Conectando con tu consola…")
            startPlay()
        } else if (Date.now() - pendingSince > 180000) {
            showPendingError(qsTr("Tu consola tarda más de lo normal en encender."), qsTr("Inténtalo de nuevo en un minuto."))
        }
    }
    // entra directo a la app «Nova Play» de la consola (sin la lista de apps de Moonlight); la consola abre el juego elegido
    function launchDirect(index) {
        pendingStage = qsTr("Abriendo %1…").arg(pending.title)
        launchModel = Qt.createQmlObject('import AppModel 1.0; AppModel {}', home, '')
        launchModel.initialize(ComputerManager, index, false)
        launchTries = 0
        launchTimer.start()
    }
    Timer {
        id: launchTimer
        interval: 1000
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            if (!pending || !launchModel) { stop(); return }
            var appIndex = launchModel.findAppIndexByName("Nova Play")
            if (appIndex < 0) {
                // la lista de apps de la consola llega unos segundos despues de emparejar
                if (++launchTries > 25) { stop(); showPendingError(qsTr("Tu consola no respondió a tiempo."), qsTr("Inténtalo de nuevo.")) }
                return
            }
            stop()
            var runningId = launchModel.getRunningAppId()
            var resume = runningId !== 0 && runningId === launchModel.getAppIdAt(appIndex)
            var item = pending
            var component = Qt.createComponent("StreamSegue.qml")
            var segue = component.createObject(stackView, {
                "appName": item.title,
                "session": launchModel.createSessionForApp(appIndex),
                "isResume": resume,
                "novaOnError": function(text) {
                    pending = item
                    showPendingError(qsTr("No pudimos abrir %1.").arg(item.title), qsTr("Revisa tu internet e inténtalo de nuevo.") + "\n\n" + text)
                }
            })
            // la capa se quita: al terminar la transmision se vuelve aqui, al catalogo
            pending = null
            pendingStage = ""
            launchModel = null
            stackView.push(segue)
        }
    }

    function openApps(index) {
        connecting = false
        if (pending) { launchDirect(index); return }
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
        if (!catalogAsked) {
            catalogAsked = true
            NovaApi.get("/api/v1/accounts/" + accountId + "/play/catalog", function(status, body) {
                if (status === 200 && body && body.items && body.items.length) catalog = body.items
                else if (status === 401) catalogAsked = false
                else catalogFailed = true
            })
        }
        NovaApi.get("/api/v1/accounts/" + accountId + "/play", function(status, body) {
            if (status === 200 && body) {
                play = body
                myHost = pickHost(body)
                loadError = ""
                if (myHost && myHost.online) waking = false
                onHostUpdated()
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
                if (pending) { showPendingError(qsTr("No pudimos encender tu consola."), wakeError); wakeError = "" }
            }
            refresh()
        })
    }

    Timer {
        // mientras la consola enciende (o se espera para abrir un juego) se pregunta cada 3-5 s; si no, cada 30 s
        interval: (pending && !pendingError) ? 3000 : (waking || (myHost && myHost.starting)) ? 5000 : 30000
        running: NovaApi.loggedIn
        repeat: true
        triggeredOnStart: true
        onTriggered: refresh()
    }
    Connections {
        target: NovaApi
        function onSessionExpired() { accountId = ""; play = null; myHost = null; catalog = null; catalogAsked = false; catalogFailed = false; closePending() }
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
        id: homeFlick
        anchors.fill: parent
        visible: NovaApi.loggedIn
        // el mando/teclado lleva la tarjeta elegida a la vista
        function ensureVisible(item) {
            var p = item.mapToItem(homeCol, 0, 0)
            if (p.y < contentY) contentY = Math.max(0, p.y - 20)
            else if (p.y + item.height > contentY + height) contentY = Math.min(contentHeight - height, p.y + item.height - height + 20)
        }
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
                        Layout.preferredHeight: catalog ? 74 : 92
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

            // ---------------------------------------------------------------- estado de la consola (una linea) y menu secundario
            RowLayout {
                visible: !!catalog
                Layout.fillWidth: true
                spacing: 10
                BusyIndicator {
                    visible: waking || (myHost && myHost.starting)
                    running: visible
                    Layout.preferredWidth: 22
                    Layout.preferredHeight: 22
                }
                Rectangle {
                    visible: !(waking || (myHost && myHost.starting))
                    width: 9; height: 9; radius: 5
                    color: myHost && myHost.online ? ok : myHost && myHost.asleep ? electric : mist
                }
                Label {
                    Layout.fillWidth: true
                    color: mist
                    font.pointSize: 11
                    elide: Text.ElideRight
                    text: !myHost ? qsTr("Sin consola asignada: escríbenos a soporte.")
                         : (waking || myHost.starting) ? qsTr("Tu consola %1 se está encendiendo…").arg(myHost.name)
                         : myHost.online ? qsTr("Tu consola %1 está lista. Elige un juego.").arg(myHost.name)
                         : myHost.asleep ? qsTr("Tu consola %1 está apagada: se enciende sola al elegir un juego.").arg(myHost.name)
                         : qsTr("Tu consola %1 no responde en este momento.").arg(myHost.name)
                }
                Label {
                    visible: play && !play.canStart
                    text: qsTr("Sin tiempo de juego: recarga en novawebcolombia.com")
                    color: warn
                    font.pointSize: 11
                }
                Button {
                    id: moreButton
                    text: qsTr("Más ▾")
                    flat: true
                    onClicked: moreMenu.open()
                    Menu {
                        id: moreMenu
                        y: moreButton.height
                        MenuItem {
                            text: qsTr("Prueba de red")
                            onTriggered: {
                                var addr = (myHost && myHost.publicHost) || ""
                                var colon = addr.lastIndexOf(":")
                                if (colon > 0 && addr.indexOf(":") === colon) addr = addr.substring(0, colon)
                                stackView.push("qrc:/gui/NetTest.qml", addr ? {"host": addr} : {})
                            }
                        }
                        MenuItem { text: qsTr("Mis consolas"); onTriggered: navigateTo("qrc:/gui/PcView.qml", PcView) }
                    }
                }
            }

            // ---------------------------------------------------------------- tus tiendas (Steam y Epic en modo consola)
            Label {
                visible: !!catalog
                text: qsTr("Tus tiendas")
                color: frost
                font.pointSize: 16
                font.weight: Font.DemiBold
                Layout.topMargin: 4
            }
            GridView {
                id: storesGrid
                visible: !!catalog
                Layout.fillWidth: true
                Layout.preferredHeight: 128
                interactive: false
                cellWidth: 336
                cellHeight: 128
                model: storeItems()
                focus: !!catalog
                keyNavigationEnabled: true
                currentIndex: 0
                Keys.onDownPressed: { gamesGrid.currentIndex = Math.min(gamesGrid.count - 1, currentIndex); gamesGrid.forceActiveFocus() }
                Keys.onReturnPressed: playGame(model[currentIndex])
                Keys.onEnterPressed: playGame(model[currentIndex])
                Keys.onSpacePressed: playGame(model[currentIndex])
                delegate: Item {
                    width: 320
                    height: 112
                    Rectangle {
                        id: storeTile
                        anchors.fill: parent
                        radius: 18
                        color: modelData.id === "epic" ? "#26262F" : "#15387A"
                        border.width: storesGrid.activeFocus && storesGrid.currentIndex === index ? 3 : storeMouse.containsMouse ? 2 : 1
                        border.color: storesGrid.activeFocus && storesGrid.currentIndex === index ? "#FFFFFF" : storeMouse.containsMouse ? violet : "#22FFFFFF"
                        scale: storesGrid.activeFocus && storesGrid.currentIndex === index ? 1.03 : 1
                        Behavior on scale { NumberAnimation { duration: 120 } }
                        Column {
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.left: parent.left
                            anchors.leftMargin: 22
                            spacing: 4
                            Label { text: modelData.title; color: "#FFFFFF"; font.pointSize: 19; font.weight: Font.Bold }
                            Label { text: modelData.desc; color: "#C7CDE8"; font.pointSize: 10; width: 270; elide: Text.ElideRight }
                        }
                    }
                    MouseArea {
                        id: storeMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onEntered: storesGrid.currentIndex = index
                        onClicked: { storesGrid.currentIndex = index; playGame(modelData) }
                    }
                }
            }

            // ---------------------------------------------------------------- juegos con portada
            Label {
                visible: !!catalog
                text: qsTr("Juegos")
                color: frost
                font.pointSize: 16
                font.weight: Font.DemiBold
                Layout.topMargin: 6
            }
            GridView {
                id: gamesGrid
                visible: !!catalog
                Layout.fillWidth: true
                property int columns: Math.max(1, Math.floor(width / cellWidth))
                Layout.preferredHeight: Math.ceil(count / columns) * cellHeight
                interactive: false
                cellWidth: 262
                cellHeight: 176
                model: gameItems()
                keyNavigationEnabled: true
                currentIndex: -1
                Keys.onUpPressed: {
                    if (currentIndex < columns) storesGrid.forceActiveFocus()
                    else moveCurrentIndexUp()
                }
                Keys.onReturnPressed: playGame(model[currentIndex])
                Keys.onEnterPressed: playGame(model[currentIndex])
                Keys.onSpacePressed: playGame(model[currentIndex])
                onCurrentIndexChanged: if (activeFocus && currentItem) homeFlick.ensureVisible(currentItem)
                delegate: Item {
                    width: 246
                    height: 162
                    property bool lit: (gamesGrid.activeFocus && gamesGrid.currentIndex === index) || gameMouse.containsMouse
                    Rectangle {
                        id: coverBox
                        width: parent.width
                        height: 115
                        radius: 14
                        color: "#141833"
                        clip: true
                        border.width: gamesGrid.activeFocus && gamesGrid.currentIndex === index ? 3 : gameMouse.containsMouse ? 2 : 0
                        border.color: gamesGrid.activeFocus && gamesGrid.currentIndex === index ? "#FFFFFF" : violet
                        scale: parent.lit ? 1.04 : 1
                        Behavior on scale { NumberAnimation { duration: 120 } }
                        // mientras carga (o si no carga) se ve el titulo
                        Label {
                            anchors.centerIn: parent
                            width: parent.width - 24
                            visible: cover.status !== Image.Ready
                            text: modelData.title
                            color: frost
                            font.pointSize: 14
                            font.weight: Font.DemiBold
                            horizontalAlignment: Text.AlignHCenter
                            wrapMode: Text.WordWrap
                        }
                        Image {
                            id: cover
                            anchors.fill: parent
                            anchors.margins: parent.border.width
                            source: modelData.cover || ""
                            fillMode: Image.PreserveAspectCrop
                            asynchronous: true
                            cache: true
                            smooth: true
                        }
                    }
                    Label {
                        anchors.top: coverBox.bottom
                        anchors.topMargin: 8
                        width: parent.width
                        text: modelData.title + (modelData.tag ? "  ·  " + modelData.tag : "")
                        color: parent.lit ? "#FFFFFF" : mist
                        font.pointSize: 11
                        elide: Text.ElideRight
                    }
                    MouseArea {
                        id: gameMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: { gamesGrid.currentIndex = index; playGame(modelData) }
                    }
                }
            }

            // la consola del jugador (solo si la API no tiene catalogo: version vieja)
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 260
                radius: 26
                color: "#B30D1022"
                border.color: "#14FFFFFF"
                visible: play !== null && catalogFailed

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
                        onClicked: { NovaApi.logout(); accountId = ""; play = null; myHost = null; catalog = null; catalogAsked = false; catalogFailed = false; closePending() }
                    }
                }
            }
        }
    }

    // ------------------------------------------------------------------ «Preparando …»: toda espera muestra rueda y estado
    Rectangle {
        id: pendingLayer
        anchors.fill: parent
        visible: NovaApi.loggedIn && pending !== null
        color: "#E606070F"
        z: 10
        focus: visible
        Keys.onEscapePressed: if (pendingError) closePending()
        Keys.onReturnPressed: if (pendingError && lastGame) { var g = lastGame; closePending(); playGame(g) }
        onVisibleChanged: if (visible) forceActiveFocus(); else storesGrid.forceActiveFocus()
        MouseArea { anchors.fill: parent }   // no deja tocar el catalogo debajo
        ColumnLayout {
            anchors.centerIn: parent
            width: Math.min(620, parent.width - 80)
            spacing: 18
            Image {
                Layout.alignment: Qt.AlignHCenter
                Layout.preferredWidth: 240
                Layout.preferredHeight: 112
                visible: pending && pending.kind !== "store" && !!pending.cover
                source: pending && pending.cover ? pending.cover : ""
                fillMode: Image.PreserveAspectCrop
            }
            BusyIndicator {
                Layout.alignment: Qt.AlignHCenter
                visible: !pendingError
                running: visible
                Layout.preferredWidth: 56
                Layout.preferredHeight: 56
            }
            Label {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                text: pendingError || pendingStage || (connecting ? connectMsg : "")
                color: pendingError ? "#FF9A9A" : frost
                font.pointSize: 20
                font.weight: Font.DemiBold
            }
            Label {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                visible: text !== ""
                text: pendingError ? pendingDetail : connecting ? connectMsg : qsTr("No cierres la app: en unos segundos estás jugando.")
                color: mist
                font.pointSize: 12
            }
            RowLayout {
                Layout.alignment: Qt.AlignHCenter
                spacing: 14
                visible: pendingError !== ""
                Button {
                    text: qsTr("Reintentar")
                    visible: !!lastGame && !!myHost && (!play || play.canStart)
                    font.pointSize: 13
                    onClicked: { var g = lastGame; closePending(); playGame(g) }
                }
                Button {
                    text: qsTr("Volver")
                    flat: true
                    font.pointSize: 13
                    onClicked: closePending()
                }
            }
        }
    }
}
