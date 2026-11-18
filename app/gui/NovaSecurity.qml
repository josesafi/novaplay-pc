import QtQuick 2.9
import QtQuick.Controls 2.2
import QtQuick.Layouts 1.3
import QtQuick.Controls.Material 2.2

import NovaApi 1.0

// Nova Play: verificacion en dos pasos con una app autenticadora (Google Authenticator, Microsoft Authenticator, Authy…).
//   off    -> contrasena actual -> scan (QR + clave para copiar) -> codigo de 6 digitos -> codes (10 codigos de recuperacion)
//   on     -> desactivar con la contrasena y un codigo
Popup {
    id: sec
    modal: true
    focus: true
    x: parent ? (parent.width - width) / 2 : 0
    y: parent ? Math.max(20, (parent.height - height) / 2) : 0
    width: Math.min(520, (parent ? parent.width : 520) - 40)
    padding: 28
    closePolicy: busy ? Popup.NoAutoClose : (Popup.CloseOnEscape | Popup.CloseOnPressOutside)

    readonly property color frost: "#EEF0FA"
    readonly property color mist: "#8D93B0"
    readonly property color bad: "#FF8A8A"
    readonly property color good: "#3EE08F"

    property string step: "off"
    property bool busy: false
    property string error: ""
    property string secret: ""
    property string otpauth: ""
    property var qr: ({ size: 0 })
    property var codes: []
    property bool copied: false

    function reset() {
        step = NovaApi.twoFactorEnabled ? "on" : "off"
        busy = false; error = ""; secret = ""; otpauth = ""; qr = { size: 0 }; codes = []; copied = false
        pwField.text = ""; codeField.text = ""; offPwField.text = ""; offCodeField.text = ""
    }
    onAboutToShow: reset()
    function fail(status, body) { busy = false; error = NovaApi.describeError(status, body) }
    function groups(s) { return s.replace(/(.{4})/g, "$1 ").trim() }

    function startSetup() {
        if (busy || pwField.text === "") return
        error = ""; busy = true
        NovaApi.post("/api/v1/auth/2fa/setup", { password: pwField.text }, function(status, body) {
            if (status !== 200 || !body || !body.otpauthUrl) { fail(status, body); return }
            busy = false
            pwField.text = ""
            secret = body.secret
            otpauth = body.otpauthUrl
            qr = NovaApi.qrCode(otpauth)
            step = "scan"
            qrCanvas.requestPaint()
            codeField.forceActiveFocus()
        })
    }
    function enable() {
        var c = codeField.text.replace(/\s/g, "")
        if (busy || !/^[0-9]{6}$/.test(c)) return
        error = ""; busy = true
        NovaApi.post("/api/v1/auth/2fa/enable", { code: c }, function(status, body) {
            if (status !== 200 || !body || !body.recoveryCodes) { fail(status, body); return }
            busy = false
            codes = body.recoveryCodes
            step = "codes"
            NovaApi.refreshSession()
        })
    }
    function disable() {
        if (busy || offPwField.text === "" || offCodeField.text.trim().length < 6) return
        error = ""; busy = true
        NovaApi.post("/api/v1/auth/2fa/disable", { password: offPwField.text, code: offCodeField.text.replace(/\s/g, "") }, function(status, body) {
            if (status !== 200) { fail(status, body); return }
            busy = false
            NovaApi.refreshSession()
            step = "disabled"
        })
    }

    background: Rectangle {
        radius: 24
        color: "#F20D1022"
        border.color: "#26FFFFFF"
    }

    contentItem: ColumnLayout {
        spacing: 12

        Label {
            text: qsTr("Verificación en dos pasos")
            font.pointSize: 18
            font.weight: Font.Bold
            color: frost
        }
        Label {
            text: sec.step === "on" ? qsTr("Está ACTIVA: al iniciar sesión te pedimos un código de tu app autenticadora además de la contraseña.")
                : sec.step === "scan" ? qsTr("1. Abre tu app autenticadora (Google Authenticator, Microsoft Authenticator, Authy…) y escanea este código. 2. Escribe el código de 6 dígitos que te muestra.")
                : sec.step === "codes" ? qsTr("¡Listo! Guarda estos 10 códigos de recuperación en un lugar seguro. Cada uno sirve una sola vez para entrar si pierdes el celular. No los volverás a ver.")
                : sec.step === "disabled" ? qsTr("Desactivaste la verificación en dos pasos. Puedes volver a activarla cuando quieras.")
                : qsTr("Protege tu cuenta: además de la contraseña te pediremos un código que cambia cada 30 segundos en tu celular. Para empezar, escribe tu contraseña actual.")
            color: mist
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
        }

        // ------------------------------------------------ activar: contrasena
        RowLayout {
            visible: sec.step === "off"
            Layout.fillWidth: true
            TextField {
                id: pwField
                placeholderText: qsTr("Contraseña actual")
                echoMode: TextInput.Password
                Layout.fillWidth: true
                Keys.onReturnPressed: sec.startSetup()
                Keys.onEnterPressed: sec.startSetup()
            }
        }

        // ------------------------------------------------ activar: QR y codigo
        ColumnLayout {
            visible: sec.step === "scan"
            Layout.fillWidth: true
            spacing: 10
            Rectangle {
                Layout.alignment: Qt.AlignHCenter
                width: 220; height: 220
                radius: 14
                color: "#FFFFFF"
                Canvas {
                    id: qrCanvas
                    anchors.fill: parent
                    anchors.margins: 14
                    onPaint: {
                        var ctx = getContext("2d")
                        ctx.fillStyle = "#FFFFFF"
                        ctx.fillRect(0, 0, width, height)
                        var n = sec.qr.size || 0
                        if (!n) return
                        var cell = Math.floor(Math.min(width, height) / n)
                        var off = Math.floor((width - cell * n) / 2)
                        ctx.fillStyle = "#06070F"
                        for (var y = 0; y < n; y++)
                            for (var x = 0; x < n; x++)
                                if (sec.qr.modules[y * n + x]) ctx.fillRect(off + x * cell, off + y * cell, cell, cell)
                    }
                }
            }
            Label {
                text: qsTr("¿No puedes escanear? Escribe esta clave en la app:")
                color: mist
                font.pointSize: 9
                Layout.alignment: Qt.AlignHCenter
            }
            RowLayout {
                Layout.alignment: Qt.AlignHCenter
                Label {
                    text: sec.groups(sec.secret)
                    color: frost
                    font.family: "Consolas"
                    font.pointSize: 11
                }
                ToolButton {
                    text: sec.copied ? qsTr("Copiada") : qsTr("Copiar")
                    onClicked: { NovaApi.copyText(sec.secret); sec.copied = true }
                }
            }
            TextField {
                id: codeField
                placeholderText: qsTr("Código de 6 dígitos")
                inputMethodHints: Qt.ImhDigitsOnly
                maximumLength: 7
                Layout.fillWidth: true
                Keys.onReturnPressed: sec.enable()
                Keys.onEnterPressed: sec.enable()
            }
        }

        // ------------------------------------------------ codigos de recuperacion
        ColumnLayout {
            visible: sec.step === "codes"
            Layout.fillWidth: true
            spacing: 10
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: codesGrid.implicitHeight + 24
                radius: 12
                color: "#14FFFFFF"
                GridLayout {
                    id: codesGrid
                    anchors.fill: parent
                    anchors.margins: 12
                    columns: 2
                    rowSpacing: 6
                    columnSpacing: 20
                    Repeater {
                        model: sec.codes
                        Label {
                            text: modelData
                            color: frost
                            font.family: "Consolas"
                            font.pointSize: 11
                            Layout.alignment: Qt.AlignHCenter
                        }
                    }
                }
            }
            RowLayout {
                Layout.fillWidth: true
                Button {
                    text: sec.copied ? qsTr("Códigos copiados") : qsTr("Copiar los códigos")
                    flat: true
                    onClicked: { NovaApi.copyText(sec.codes.join("\n")); sec.copied = true }
                }
                Item { Layout.fillWidth: true }
                CheckBox { id: savedBox; text: qsTr("Ya los guardé") }
            }
        }

        // ------------------------------------------------ desactivar
        ColumnLayout {
            visible: sec.step === "on"
            Layout.fillWidth: true
            spacing: 8
            Label {
                text: qsTr("Para desactivarla escribe tu contraseña y un código de tu app (o un código de recuperación):")
                color: mist
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
            }
            TextField { id: offPwField; placeholderText: qsTr("Contraseña actual"); echoMode: TextInput.Password; Layout.fillWidth: true }
            TextField { id: offCodeField; placeholderText: qsTr("Código"); Layout.fillWidth: true; Keys.onReturnPressed: sec.disable(); Keys.onEnterPressed: sec.disable() }
        }

        Label {
            visible: sec.error !== ""
            text: sec.error
            color: bad
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
        }

        NovaPrimaryButton {
            busy: sec.busy
            text: sec.step === "off" ? qsTr("Continuar")
                : sec.step === "scan" ? qsTr("Activar")
                : sec.step === "codes" ? qsTr("Listo")
                : sec.step === "on" ? qsTr("Desactivar")
                : qsTr("Cerrar")
            enabled: !sec.busy && (sec.step === "off" ? pwField.text !== ""
                : sec.step === "scan" ? /^[0-9]{6}$/.test(codeField.text.replace(/\s/g, ""))
                : sec.step === "codes" ? savedBox.checked
                : sec.step === "on" ? (offPwField.text !== "" && offCodeField.text.trim().length >= 6)
                : true)
            onClicked: {
                if (sec.step === "off") sec.startSetup()
                else if (sec.step === "scan") sec.enable()
                else if (sec.step === "on") sec.disable()
                else sec.close()
            }
        }
        Label {
            visible: sec.busy
            text: sec.step === "off" ? qsTr("Preparando tu código…") : sec.step === "scan" ? qsTr("Activando…") : qsTr("Desactivando…")
            color: mist
            Layout.alignment: Qt.AlignHCenter
        }
        Label {
            visible: !sec.busy && sec.step !== "codes"
            text: "<a href='#'>" + qsTr("Cancelar") + "</a>"
            textFormat: Text.RichText
            linkColor: mist
            Layout.alignment: Qt.AlignHCenter
            onLinkActivated: sec.close()
        }
    }
}
