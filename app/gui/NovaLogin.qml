import QtQuick 2.9
import QtQuick.Controls 2.2
import QtQuick.Layouts 1.3
import QtQuick.Controls.Material 2.2

import NovaApi 1.0

// Nova Play: cuenta de novawebcolombia.com SIN salir de la app (18-nov-2026).
//   login      correo + contrasena (mostrar/ocultar, recordar correo y contrasena en el Administrador de credenciales de Windows)
//   twofactor  codigo de 6 digitos de la app autenticadora o un codigo de recuperacion
//   register   crear la cuenta (con la pregunta antibot) -> registered: «Revisa tu correo» + reenviar
//   forgot     recuperar la contrasena (con la pregunta antibot) -> forgotSent
Item {
    id: login

    readonly property color frost: "#EEF0FA"
    readonly property color mist: "#8D93B0"
    readonly property color bad: "#FF8A8A"
    readonly property color good: "#3EE08F"

    property string mode: "login"
    property bool busy: false
    property string error: ""
    property string info: ""
    // correo de la cuenta recien creada o del olvido (para «Reenviar» y para volver a entrar)
    property string pendingEmail: ""

    function go(m) {
        error = ""
        info = ""
        busy = false
        mode = m
        flick.contentY = 0
    }
    function apiError(status, body) {
        if (status === 429 && body && body.retryAfter) {
            var mins = Math.max(1, Math.round(body.retryAfter / 60))
            return qsTr("Demasiados intentos. Vuelve a intentarlo en %1 minutos.").arg(mins)
        }
        return NovaApi.describeError(status, body)
    }

    // ---------------------------------------------------------------- acciones
    function submitLogin() {
        if (busy) return
        if (mode === "twofactor") {
            if (codeField.text.trim().length < 6) return
            error = ""; busy = true
            NovaApi.loginTwoFactor(codeField.text, function(ok, need2fa, msg) {
                busy = false
                if (!ok) error = msg
            })
            return
        }
        if (emailField.text.trim().length < 4 || passwordField.text.length === 0) return
        error = ""; busy = true
        NovaApi.rememberEmail = rememberEmailBox.checked
        if (NovaApi.canRememberPassword) NovaApi.rememberPassword = rememberPasswordBox.checked
        NovaApi.login(emailField.text, passwordField.text, function(ok, need2fa, msg) {
            busy = false
            if (!ok) { error = msg; return }
            if (need2fa) { mode = "twofactor"; codeField.text = ""; codeField.forceActiveFocus() }
        })
    }

    function strength(pw) {
        var s = 0
        if (pw.length >= regCheck.passwordMinLength) s++
        if (pw.length >= regCheck.passwordMinLength + 4) s++
        if (/[a-z]/.test(pw) && /[A-Z]/.test(pw)) s++
        if (/[0-9]/.test(pw)) s++
        if (/[^A-Za-z0-9]/.test(pw)) s++
        return pw.length < regCheck.passwordMinLength ? Math.min(s, 1) : s
    }
    function registerProblem() {
        if (firstNameField.text.trim() === "" || lastNameField.text.trim() === "") return qsTr("Escribe tu nombre y tu apellido.")
        if (!/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(regEmailField.text.trim())) return qsTr("Escribe un correo válido.")
        if (regPasswordField.text.length < regCheck.passwordMinLength) return qsTr("La contraseña debe tener al menos %1 caracteres.").arg(regCheck.passwordMinLength)
        if (regPasswordField.text !== regConfirmField.text) return qsTr("Las contraseñas no coinciden.")
        if (!termsBox.checked) return qsTr("Debes aceptar los términos y la política de privacidad.")
        if (!adultBox.checked) return qsTr("Debes ser mayor de 18 años para crear tu cuenta.")
        if (!regCheck.ready) return qsTr("Responde la pregunta para confirmar que eres una persona.")
        return ""
    }
    function submitRegister() {
        if (busy) return
        var p = registerProblem()
        if (p) { error = p; return }
        error = ""; busy = true
        var body = {
            email: regEmailField.text.trim(), password: regPasswordField.text,
            firstName: firstNameField.text.trim(), lastName: lastNameField.text.trim(),
            accountType: "PERSON", acceptTerms: true, acceptPrivacy: true, isAdult: true,
            termsVersion: regCheck.termsVersion
        }
        if (phoneField.text.trim() !== "") body.phone = phoneField.text.trim()
        var hc = regCheck.fields()
        body.appChallengeToken = hc.appChallengeToken
        body.appChallengeAnswer = hc.appChallengeAnswer
        NovaApi.publicPost("/api/v1/auth/register", body, function(status, r) {
            busy = false
            regCheck.reload()
            if (status === 202 || status === 200 || status === 201) {
                pendingEmail = body.email
                emailField.text = body.email
                regPasswordField.text = ""; regConfirmField.text = ""
                go("registered")
                return
            }
            error = apiError(status, r)
        })
    }
    function submitResend() {
        if (busy || !resendCheck.ready) return
        error = ""; info = ""; busy = true
        var hc = resendCheck.fields()
        NovaApi.publicPost("/api/v1/auth/resend-verification", { email: pendingEmail, appChallengeToken: hc.appChallengeToken, appChallengeAnswer: hc.appChallengeAnswer }, function(status, r) {
            busy = false
            resendCheck.reload()
            if (status === 202 || status === 200) info = qsTr("Listo: te enviamos otro correo. Revisa también la carpeta de spam.")
            else error = apiError(status, r)
        })
    }
    function submitForgot() {
        if (busy) return
        var mail = forgotEmailField.text.trim()
        if (!/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(mail)) { error = qsTr("Escribe un correo válido."); return }
        if (!forgotCheck.ready) { error = qsTr("Responde la pregunta para confirmar que eres una persona."); return }
        error = ""; busy = true
        var hc = forgotCheck.fields()
        NovaApi.publicPost("/api/v1/auth/forgot-password", { email: mail, appChallengeToken: hc.appChallengeToken, appChallengeAnswer: hc.appChallengeAnswer }, function(status, r) {
            busy = false
            forgotCheck.reload()
            if (status === 202 || status === 200) { pendingEmail = mail; go("forgotSent"); return }
            error = apiError(status, r)
        })
    }

    Connections {
        target: NovaApi
        function onSessionChanged() {
            if (!NovaApi.loggedIn && (login.mode === "twofactor" || passwordField.text !== NovaApi.savedPassword(emailField.text))) {
                login.go("login")
                emailField.text = NovaApi.savedEmail || NovaApi.email
                passwordField.text = NovaApi.savedPassword(emailField.text)
            }
        }
    }

    Component.onCompleted: {
        emailField.text = NovaApi.savedEmail || NovaApi.email
        var pw = NovaApi.savedPassword(emailField.text)
        if (pw) passwordField.text = pw
    }

    // ---------------------------------------------------------------- tarjeta
    Flickable {
        id: flick
        anchors.fill: parent
        contentHeight: Math.max(height, card.height + 48)
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar { policy: flick.contentHeight > flick.height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff }

        Rectangle {
            id: card
            width: Math.min(login.mode === "register" ? 520 : 440, login.width - 48)
            height: col.implicitHeight + 64
            x: (flick.width - width) / 2
            y: Math.max(24, (flick.height - height) / 2)
            radius: 24
            color: "#E60D1022"
            border.color: "#14FFFFFF"
            border.width: 1

            ColumnLayout {
                id: col
                anchors.fill: parent
                anchors.margins: 32
                spacing: 12

                Image {
                    source: "qrc:/res/novaplay-logo.png"
                    fillMode: Image.PreserveAspectFit
                    Layout.preferredHeight: 34
                    Layout.preferredWidth: 220
                    Layout.alignment: Qt.AlignHCenter
                    mipmap: true
                }
                Label {
                    text: login.mode === "twofactor" ? qsTr("Verificación en dos pasos")
                        : login.mode === "register" ? qsTr("Crea tu cuenta")
                        : login.mode === "registered" ? qsTr("Revisa tu correo")
                        : login.mode === "forgot" ? qsTr("Recupera tu contraseña")
                        : login.mode === "forgotSent" ? qsTr("Te enviamos un correo")
                        : qsTr("Inicia sesión")
                    font.pointSize: 20
                    font.weight: Font.Bold
                    color: frost
                    Layout.alignment: Qt.AlignHCenter
                    Layout.topMargin: 10
                }
                Label {
                    text: login.mode === "twofactor" ? qsTr("Escribe el código de 6 dígitos de tu app de autenticación (o un código de recuperación).")
                        : login.mode === "register" ? qsTr("Es la misma cuenta de novawebcolombia.com: sirve para Nova Play, el panel y todos los servicios.")
                        : login.mode === "registered" ? qsTr("Te enviamos un enlace a %1. Ábrelo para confirmar tu cuenta (te pedirá la contraseña que acabas de crear) y vuelve aquí para entrar.").arg(login.pendingEmail)
                        : login.mode === "forgot" ? qsTr("Escribe el correo de tu cuenta y te enviaremos un enlace para crear una contraseña nueva.")
                        : login.mode === "forgotSent" ? qsTr("Si %1 tiene una cuenta, en unos minutos recibirás el enlace para crear una contraseña nueva. Revisa también la carpeta de spam.").arg(login.pendingEmail)
                        : qsTr("Usa tu cuenta de novawebcolombia.com.")
                    color: mist
                    wrapMode: Text.WordWrap
                    horizontalAlignment: Text.AlignHCenter
                    Layout.fillWidth: true
                }

                // ------------------------------------------------ iniciar sesion
                ColumnLayout {
                    visible: login.mode === "login"
                    spacing: 10
                    Layout.fillWidth: true
                    Layout.topMargin: 6
                    TextField {
                        id: emailField
                        placeholderText: qsTr("Correo")
                        inputMethodHints: Qt.ImhEmailCharactersOnly | Qt.ImhNoAutoUppercase
                        Layout.fillWidth: true
                        Keys.onReturnPressed: passwordField.forceActiveFocus()
                        Keys.onEnterPressed: passwordField.forceActiveFocus()
                        onEditingFinished: {
                            if (passwordField.text === "") {
                                var pw = NovaApi.savedPassword(text)
                                if (pw) passwordField.text = pw
                            }
                        }
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 6
                        TextField {
                            id: passwordField
                            placeholderText: qsTr("Contraseña")
                            echoMode: showPw.checked ? TextInput.Normal : TextInput.Password
                            Layout.fillWidth: true
                            Keys.onReturnPressed: login.submitLogin()
                            Keys.onEnterPressed: login.submitLogin()
                        }
                        ToolButton {
                            id: showPw
                            checkable: true
                            text: checked ? qsTr("Ocultar") : qsTr("Mostrar")
                            font.pointSize: 9
                        }
                    }
                    CheckBox {
                        id: rememberEmailBox
                        text: qsTr("Recordar mi correo")
                        checked: NovaApi.rememberEmail
                        onToggled: if (!checked) rememberPasswordBox.checked = false
                        Layout.topMargin: -4
                    }
                    CheckBox {
                        id: rememberPasswordBox
                        visible: NovaApi.canRememberPassword
                        text: qsTr("Recordar mi contraseña en este PC")
                        checked: NovaApi.rememberPassword
                        onToggled: if (checked) rememberEmailBox.checked = true
                        Layout.topMargin: -14
                        ToolTip.visible: hovered
                        ToolTip.delay: 600
                        ToolTip.text: qsTr("Se guarda cifrada en el Administrador de credenciales de Windows de tu usuario. No la actives en un PC compartido.")
                    }
                }

                // ------------------------------------------------ codigo de dos pasos
                TextField {
                    id: codeField
                    visible: login.mode === "twofactor"
                    placeholderText: qsTr("Código")
                    inputMethodHints: Qt.ImhDigitsOnly
                    Layout.fillWidth: true
                    Keys.onReturnPressed: login.submitLogin()
                    Keys.onEnterPressed: login.submitLogin()
                }

                // ------------------------------------------------ crear cuenta
                GridLayout {
                    visible: login.mode === "register"
                    columns: 2
                    columnSpacing: 10
                    rowSpacing: 8
                    Layout.fillWidth: true
                    Layout.topMargin: 6
                    TextField { id: firstNameField; placeholderText: qsTr("Nombre"); Layout.fillWidth: true; Keys.onReturnPressed: lastNameField.forceActiveFocus() }
                    TextField { id: lastNameField; placeholderText: qsTr("Apellido"); Layout.fillWidth: true; Keys.onReturnPressed: regEmailField.forceActiveFocus() }
                    TextField {
                        id: regEmailField
                        placeholderText: qsTr("Correo")
                        inputMethodHints: Qt.ImhEmailCharactersOnly | Qt.ImhNoAutoUppercase
                        Layout.columnSpan: 2
                        Layout.fillWidth: true
                        Keys.onReturnPressed: phoneField.forceActiveFocus()
                    }
                    TextField {
                        id: phoneField
                        placeholderText: qsTr("Celular (opcional)")
                        inputMethodHints: Qt.ImhDialableCharactersOnly
                        Layout.columnSpan: 2
                        Layout.fillWidth: true
                        Keys.onReturnPressed: regPasswordField.forceActiveFocus()
                    }
                    TextField {
                        id: regPasswordField
                        placeholderText: qsTr("Contraseña")
                        echoMode: showRegPw.checked ? TextInput.Normal : TextInput.Password
                        Layout.fillWidth: true
                        Keys.onReturnPressed: regConfirmField.forceActiveFocus()
                    }
                    TextField {
                        id: regConfirmField
                        placeholderText: qsTr("Repite la contraseña")
                        echoMode: showRegPw.checked ? TextInput.Normal : TextInput.Password
                        Layout.fillWidth: true
                        Keys.onReturnPressed: login.submitRegister()
                    }
                    // fuerza de la contrasena
                    ColumnLayout {
                        id: strengthBox
                        Layout.columnSpan: 2
                        Layout.fillWidth: true
                        spacing: 4
                        property int score: login.strength(regPasswordField.text)
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 4
                            Repeater {
                                model: 5
                                Rectangle {
                                    Layout.fillWidth: true
                                    height: 5
                                    radius: 3
                                    color: index < strengthBox.score ? (strengthBox.score <= 2 ? bad : strengthBox.score <= 3 ? "#FFC24A" : good) : "#22FFFFFF"
                                }
                            }
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            Label {
                                text: regPasswordField.text === "" ? qsTr("Mínimo %1 caracteres. Mezcla letras, números y símbolos.").arg(regCheck.passwordMinLength)
                                    : strengthBox.score <= 2 ? qsTr("Contraseña débil") : strengthBox.score <= 3 ? qsTr("Contraseña aceptable") : qsTr("Contraseña fuerte")
                                color: mist
                                font.pointSize: 9
                                Layout.fillWidth: true
                                wrapMode: Text.WordWrap
                            }
                            CheckBox { id: showRegPw; text: qsTr("Mostrar"); font.pointSize: 9 }
                        }
                        Label {
                            visible: regConfirmField.text !== "" && regConfirmField.text !== regPasswordField.text
                            text: qsTr("Las contraseñas no coinciden.")
                            color: bad
                            font.pointSize: 9
                        }
                    }
                    CheckBox {
                        id: termsBox
                        Layout.columnSpan: 2
                        Layout.fillWidth: true
                        contentItem: Label {
                            leftPadding: termsBox.indicator.width + termsBox.spacing
                            text: qsTr("Acepto los <a href='https://novawebcolombia.com/terminos'>términos y condiciones</a> y la <a href='https://novawebcolombia.com/privacidad'>política de privacidad y tratamiento de datos</a>.")
                            textFormat: Text.RichText
                            linkColor: "#B98AFF"
                            color: frost
                            wrapMode: Text.WordWrap
                            verticalAlignment: Text.AlignVCenter
                            onLinkActivated: Qt.openUrlExternally(link)
                        }
                    }
                    CheckBox {
                        id: adultBox
                        Layout.columnSpan: 2
                        text: qsTr("Soy mayor de 18 años")
                        Layout.topMargin: -10
                    }
                    NovaHumanCheck {
                        id: regCheck
                        Layout.columnSpan: 2
                        Layout.fillWidth: true
                        onSubmitRequested: login.submitRegister()
                    }
                }

                // ------------------------------------------------ cuenta creada: reenviar el correo
                ColumnLayout {
                    visible: login.mode === "registered"
                    Layout.fillWidth: true
                    spacing: 10
                    Label {
                        text: qsTr("¿No te llegó? Revisa la carpeta de spam o pide otro correo:")
                        color: mist
                        wrapMode: Text.WordWrap
                        Layout.fillWidth: true
                    }
                    NovaHumanCheck {
                        id: resendCheck
                        Layout.fillWidth: true
                        onSubmitRequested: login.submitResend()
                    }
                }

                // ------------------------------------------------ recuperar contrasena
                ColumnLayout {
                    visible: login.mode === "forgot"
                    Layout.fillWidth: true
                    spacing: 10
                    TextField {
                        id: forgotEmailField
                        placeholderText: qsTr("Correo")
                        inputMethodHints: Qt.ImhEmailCharactersOnly | Qt.ImhNoAutoUppercase
                        Layout.fillWidth: true
                    }
                    NovaHumanCheck {
                        id: forgotCheck
                        Layout.fillWidth: true
                        onSubmitRequested: login.submitForgot()
                    }
                }

                Label {
                    visible: login.error !== ""
                    text: login.error
                    color: bad
                    wrapMode: Text.WordWrap
                    Layout.fillWidth: true
                }
                Label {
                    visible: login.info !== ""
                    text: login.info
                    color: good
                    wrapMode: Text.WordWrap
                    Layout.fillWidth: true
                }

                NovaPrimaryButton {
                    id: mainButton
                    Layout.topMargin: 4
                    busy: login.busy
                    text: login.mode === "twofactor" ? qsTr("Verificar")
                        : login.mode === "register" ? qsTr("Crear mi cuenta")
                        : login.mode === "registered" ? qsTr("Reenviar el correo")
                        : login.mode === "forgot" ? qsTr("Enviar el enlace")
                        : login.mode === "forgotSent" ? qsTr("Volver a iniciar sesión")
                        : qsTr("Entrar")
                    enabled: !login.busy && (
                        login.mode === "twofactor" ? codeField.text.trim().length >= 6
                        : login.mode === "login" ? (emailField.text.trim().length > 3 && passwordField.text.length > 0)
                        : login.mode === "registered" ? resendCheck.ready
                        : true)
                    onClicked: {
                        if (login.mode === "register") login.submitRegister()
                        else if (login.mode === "registered") login.submitResend()
                        else if (login.mode === "forgot") login.submitForgot()
                        else if (login.mode === "forgotSent") login.go("login")
                        else login.submitLogin()
                    }
                }
                Label {
                    visible: login.busy
                    text: login.mode === "register" ? qsTr("Creando tu cuenta…")
                        : login.mode === "twofactor" ? qsTr("Verificando el código…")
                        : login.mode === "login" ? qsTr("Iniciando sesión…")
                        : qsTr("Enviando…")
                    color: mist
                    Layout.alignment: Qt.AlignHCenter
                }

                // ------------------------------------------------ enlaces
                RowLayout {
                    visible: login.mode === "login"
                    Layout.alignment: Qt.AlignHCenter
                    spacing: 18
                    Label {
                        text: "<a href='#'>" + qsTr("¿Olvidaste tu contraseña?") + "</a>"
                        textFormat: Text.RichText
                        linkColor: mist
                        onLinkActivated: { forgotEmailField.text = emailField.text; login.go("forgot") }
                    }
                    Label {
                        text: "<a href='#'>" + qsTr("Crear cuenta") + "</a>"
                        textFormat: Text.RichText
                        linkColor: "#B98AFF"
                        font.weight: Font.DemiBold
                        onLinkActivated: { regEmailField.text = emailField.text; login.go("register") }
                    }
                }
                Label {
                    visible: login.mode === "registered"
                    text: "<a href='#'>" + qsTr("Ya confirmé mi correo, entrar") + "</a>"
                    textFormat: Text.RichText
                    linkColor: "#B98AFF"
                    font.weight: Font.DemiBold
                    Layout.alignment: Qt.AlignHCenter
                    onLinkActivated: { emailField.text = login.pendingEmail; passwordField.text = ""; login.go("login"); passwordField.forceActiveFocus() }
                }
                Label {
                    visible: login.mode === "register"
                    text: "<a href='#'>" + qsTr("Ya tengo cuenta, iniciar sesión") + "</a>"
                    textFormat: Text.RichText
                    linkColor: mist
                    Layout.alignment: Qt.AlignHCenter
                    onLinkActivated: login.go("login")
                }
                Label {
                    visible: login.mode === "twofactor" || login.mode === "forgot"
                    text: "<a href='#'>" + qsTr("Volver") + "</a>"
                    textFormat: Text.RichText
                    linkColor: mist
                    Layout.alignment: Qt.AlignHCenter
                    onLinkActivated: login.go("login")
                }
            }
        }
    }
}
