import QtQuick 2.9
import QtQuick.Controls 2.2
import QtQuick.Layouts 1.3
import QtQuick.Controls.Material 2.2

import NovaApi 1.0

// Nova Play: «¿Eres una persona?» de los formularios sin sesion (crear cuenta, recuperar contrasena, reenviar el correo).
// La API entrega una cuenta sencilla («¿Cuánto es 2 + 4?») firmada; cada pregunta sirve UNA vez, asi que despues de cada envio
// (salga bien o mal) quien la usa llama a reload().
ColumnLayout {
    id: hc
    spacing: 6

    property string token: ""
    property string question: ""
    property string termsVersion: ""
    property int passwordMinLength: 12
    property bool loading: false
    property string error: ""
    readonly property string answer: answerField.text.trim()
    readonly property bool ready: token !== "" && answer.length > 0
    signal submitRequested()

    function reload() {
        loading = true
        error = ""
        token = ""
        answerField.text = ""
        NovaApi.publicGet("/api/v1/auth/app-challenge", function(status, body) {
            loading = false
            if (status === 200 && body && body.token) {
                token = body.token
                question = body.question
                if (body.termsVersion) termsVersion = body.termsVersion
                if (body.passwordMinLength) passwordMinLength = body.passwordMinLength
            } else if (status === 429) {
                error = qsTr("Pediste muchas preguntas seguidas. Espera unos minutos e inténtalo de nuevo.")
            } else {
                error = qsTr("No pudimos preparar la pregunta. Revisa tu internet e inténtalo de nuevo.")
            }
        })
    }
    // los datos que van en el formulario
    function fields() { return { appChallengeToken: token, appChallengeAnswer: answer } }

    // se pide la pregunta cuando el formulario aparece (no al abrir la app)
    onVisibleChanged: if (visible && token === "" && !loading) reload()
    Component.onCompleted: if (visible) reload()

    Label {
        text: qsTr("Confirma que eres una persona")
        color: "#8D93B0"
        font.pointSize: 10
    }
    RowLayout {
        spacing: 10
        Layout.fillWidth: true
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 46
            radius: 12
            color: "#14FFFFFF"
            border.color: "#1FFFFFFF"
            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 14
                anchors.rightMargin: 8
                spacing: 8
                BusyIndicator {
                    visible: hc.loading
                    running: visible
                    Layout.preferredWidth: 24
                    Layout.preferredHeight: 24
                }
                Label {
                    text: hc.loading ? qsTr("Preparando la pregunta…") : (hc.question || "—")
                    color: "#EEF0FA"
                    font.pointSize: 12
                    font.weight: Font.DemiBold
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                }
                TextField {
                    id: answerField
                    enabled: hc.token !== ""
                    placeholderText: qsTr("Respuesta")
                    inputMethodHints: Qt.ImhDigitsOnly
                    maximumLength: 4
                    Layout.preferredWidth: 110
                    Keys.onReturnPressed: hc.submitRequested()
                    Keys.onEnterPressed: hc.submitRequested()
                }
            }
        }
        Button {
            text: qsTr("Otra pregunta")
            flat: true
            enabled: !hc.loading
            onClicked: hc.reload()
        }
    }
    Label {
        visible: hc.error !== ""
        text: hc.error
        color: "#FF8A8A"
        wrapMode: Text.WordWrap
        Layout.fillWidth: true
    }
}
